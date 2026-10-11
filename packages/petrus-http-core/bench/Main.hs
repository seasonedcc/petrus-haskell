-- | petrus-http-core hot paths. Each benchmark has a same-named
-- counterpart in @bench/python_bench.py@ running CPython's
-- @http.server@; run both with @scripts/bench petrus-http-core@.
--
-- The round trips open a fresh loopback connection per request (one
-- request per connection, as both services work), send the request, and
-- read the response to the end, with each language's own client. The
-- client then closes with a reset (@SO_LINGER@ 0), which discards the
-- connection on both ends instead of leaving a @TIME_WAIT@ socket: tens of
-- thousands of round trips would otherwise exhaust the machine's ephemeral
-- ports. The server's side of each exchange is unchanged.
module Main (main) where

import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Time (getCurrentTime)
import Network.Socket
  ( Family (..)
  , ShutdownCmd (..)
  , SockAddr (..)
  , SocketOption (..)
  , SocketType (..)
  , StructLinger (..)
  , close
  , connect
  , defaultProtocol
  , setSockOpt
  , socket
  , tupleToHostAddress
  )
import Network.Socket qualified as Socket
import Network.Socket.ByteString (recv, sendAll)
import Petrus.Http.Core
import Test.Tasty (localOption)
import Test.Tasty.Bench

-- The observation server's snapshot response shape.
snapshotBody :: ByteString
snapshotBody = "{\"frontier\":42,\"marking\":[{\"place\":\"orders.received\",\"tokens\":[{\"color\":null,\"data\":{\"id\":7}}]}],\"protocol\":\"petrus.observation.v1\"}"

jsonHeaders :: Int -> [(ByteString, ByteString)]
jsonHeaders size =
  [ ("Content-Type", "application/json; charset=utf-8")
  , ("Content-Length", BC.pack (show size))
  , ("Cache-Control", "no-store")
  , ("Access-Control-Allow-Origin", "*")
  ]

handler :: Handler
handler request = case requestMethod request of
  "POST" -> do
    size <- maybe (pure "") (readBody request . read . BC.unpack) (requestHeader "Content-Length" request)
    let body = BC.pack (show (BS.length size))
    sendResponse request (response 200 (jsonHeaders (BS.length body)) body)
  _ -> sendResponse request (response 200 (jsonHeaders (BS.length snapshotBody)) snapshotBody)

getRequest :: ByteString
getRequest = "GET /v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1:8000\r\nUser-Agent: bench\r\nAccept: application/json\r\nConnection: close\r\n\r\n"

postRequest :: ByteString
postRequest =
  "POST /v1/simulations HTTP/1.1\r\nHost: 127.0.0.1:8000\r\nOrigin: http://localhost:5173\r\nContent-Type: application/json\r\nContent-Length: 1024\r\n\r\n"
    <> BC.replicate 1024 'x'

-- The request head a browser sends, for the parsing benchmark.
browserHead :: ByteString
browserHead =
  "Host: localhost:8000\r\nUser-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)\r\nAccept: application/json\r\nAccept-Language: en-US,en;q=0.9\r\nAccept-Encoding: gzip, deflate, br\r\nOrigin: http://localhost:5173\r\nConnection: keep-alive\r\nReferer: http://localhost:5173/\r\n\r\n"

browserLine :: ByteString
browserLine = "GET /v1/history?after=0&limit=100 HTTP/1.1\r\n"

roundtrip :: Int -> ByteString -> IO ByteString
roundtrip port request =
  bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
    setSockOpt sock Linger (StructLinger 1 0)
    connect sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
    sendAll sock request
    Socket.shutdown sock ShutdownSend
    let go chunks = do
          chunk <- recv sock 65536
          if BS.null chunk then pure (BS.concat (reverse chunks)) else go (chunk : chunks)
    go []

parseHead :: (ByteString, ByteString) -> Int
parseHead (line, block) = case parseRequestLine line of
  Just (Right parsed) -> BS.length (linePath parsed) + length (parseHeaderBlock block)
  _ -> -1

main :: IO ()
main =
  withRunningServer defaultServerConfig {serverHost = "127.0.0.1"} handler $ \server -> do
    port <- serverPort server
    -- Wall-clock time for every benchmark, as the Python twins measure it
    -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
    -- time spent waiting on the kernel, servers and child processes.
    defaultMain . map (localOption WallTime) $
      [ -- Each iteration is a new TCP connection through the kernel and the
        -- scheduler: allow a wider spread than the global --stdev.
        localOption (RelStDev 0.2) $
          bgroup
            "roundtrip"
            [ bench "get-snapshot" (nfIO (roundtrip port getRequest))
            , bench "post-1k" (nfIO (roundtrip port postRequest))
            , bench "refused-version" (nfIO (roundtrip port "GET / HTTP/2.0\r\n\r\n"))
            ]
      , bgroup
          "parse"
          [ bench "request-head" (nf parseHead (browserLine, browserHead))
          ]
      , bgroup
          "render"
          [ bench "send-error" (nfIO ((\now -> renderError defaultServerSoftware (httpDate now) "HTTP/1.1" "GET" 404 Nothing Nothing) <$> getCurrentTime))
          , bench "response" (nfIO ((\now -> renderResponse defaultServerSoftware (httpDate now) "HTTP/1.1" (response 200 (jsonHeaders (BS.length snapshotBody)) snapshotBody)) <$> getCurrentTime))
          ]
      ]
