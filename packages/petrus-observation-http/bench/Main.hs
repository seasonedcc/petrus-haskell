-- | petrus-observation-http benchmarks.
--
-- @cabal bench petrus-observation-http@ runs the tasty-bench rows, each
-- with a same-named counterpart in @bench/python_bench.py@ (run both with
-- @scripts/bench petrus-observation-http@): one round trip per iteration on
-- a fresh loopback connection, with each language's own client, against
-- the "busy" Engine below.
--
-- @cabal bench petrus-observation-http --benchmark-options load@ runs the
-- interleaved load comparison ("Load"): one Haskell client drives this
-- server and the upstream server (@test/reference_observation.py busy@)
-- with identical requests, after checking that both answer each request
-- with the same bytes.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (forM_, replicateM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Load (Scenario (Scenario), Target (Target), runLoad)
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
import Petrus.Engine (Engine)
import Petrus.Engine qualified as Engine
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.Petrinet (NetSpec (..), Token (..), arc, markingFromList, mkNet, netSpec, place, transition)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.TestSupport.Python (readLine, withPython)
import Petrus.TestSupport.Repo (repoRoot)
import Support (a, exchange, move, normalize, withObservation)
import System.Environment (getArgs)
import Test.Tasty (localOption)
import Test.Tasty.Bench

-- | The upstream test's Net with its move looping back to @a@, advanced
-- 100 times: 201 History records (@reference_observation.py busy@).
busyEngine :: IO Engine
busyEngine = do
  store <- inMemoryHistoryStore
  port <- inMemoryDispatch <$> newInMemoryDispatch
  let net = either (error . T.unpack) id (mkNet (netSpec [place a] [transition move] [arc a move, arc move a]) {name = Just "http-observation"})
  engine <-
    Engine.create
      net
      "http-instance"
      store
      port
      Engine.defaultEngineOptions {Engine.marking = markingFromList [(a, [Token (Just "value") (Object [("n", Int 1)])])]}
  replicateM_ 100 (Engine.advance engine)
  pure engine

get :: ByteString -> ByteString
get target = "GET " <> target <> " HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://localhost:5173\r\nAccept: application/json\r\n\r\n"

snapshot, document, history, refused :: ByteString
snapshot = get "/v1/snapshot"
document = get "/v1/document"
history = get "/v1/history?after=0&limit=100"
refused = "POST /v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"

roundtrip :: Int -> ByteString -> IO ByteString
roundtrip port bytes =
  bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
    setSockOpt sock Linger (StructLinger 1 0)
    connect sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
    sendAll sock bytes
    Socket.shutdown sock ShutdownSend
    let go chunks = do
          chunk <- recv sock 65536
          if BS.null chunk then pure (BS.concat (reverse chunks)) else go (chunk : chunks)
    go []

main :: IO ()
main = do
  args <- getArgs
  engine <- busyEngine
  withObservation engine $ \port -> case args of
    "load" : rest -> load (case rest of [n] -> read n; _ -> 5) port
    _ ->
      -- Wall-clock time for every benchmark, as the Python twins measure it
      -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
      -- time spent waiting on the kernel, servers and child processes.
      defaultMain . map (localOption WallTime) $
        [ -- each iteration is a new TCP connection through the kernel and
          -- the scheduler: allow a wider spread than the global --stdev
          localOption (RelStDev 0.2) $
            bgroup
              "roundtrip"
              [ bench "snapshot" (nfIO (roundtrip port snapshot))
              , bench "document" (nfIO (roundtrip port document))
              , bench "history-100" (nfIO (roundtrip port history))
              , bench "refused-405" (nfIO (roundtrip port refused))
              ]
        ]
  Engine.close engine

load :: Int -> Int -> IO ()
load repetitions haskell = do
  root <- repoRoot
  script <- T.pack <$> readFile (root <> "/packages/petrus-observation-http/test/reference_observation.py")
  withPython script ["busy"] $ \process -> do
    python <- read . BC.unpack <$> readLine process
    -- both servers answer every request with the same bytes
    forM_ [snapshot, document, history, refused] $ \bytes -> do
      ours <- normalize <$> exchange haskell bytes
      theirs <- normalize <$> exchange python bytes
      unless (ours == theirs && not (BS.null ours)) $ fail ("the servers differ on " <> show bytes)
    let ok = BS.isPrefixOf "HTTP/1.0 200 "
        scenarios =
          [ Scenario "snapshot" snapshot 1 2000 ok
          , Scenario "snapshot" snapshot 4 4000 ok
          , Scenario "document (201 records)" document 1 1000 ok
          , Scenario "document (201 records)" document 4 2000 ok
          , Scenario "history after=0 limit=100" history 1 1000 ok
          , Scenario "history after=0 limit=100" history 4 2000 ok
          , Scenario "refused POST (405)" refused 1 2000 (BS.isPrefixOf "HTTP/1.0 405 ")
          ]
    runLoad repetitions (Target "haskell" haskell) (Target "python" python) scenarios
