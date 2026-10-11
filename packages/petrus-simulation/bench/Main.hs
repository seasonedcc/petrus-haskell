-- | petrus-simulation benchmarks.
--
-- @cabal bench petrus-simulation@ runs the tasty-bench rows, each with a
-- same-named counterpart in @bench/python_bench.py@ (run both with
-- @scripts/bench petrus-simulation@):
--
-- * @simulate.*@ time 'simulate' itself on scenarios across the profile:
--   the owner fixture, a long run, a run whose result is refused only after
--   it is serialized, a scan-heavy run, large payloads, and an admission
--   refusal;
-- * @http.*@ time one round trip on a fresh loopback connection to the
--   service, with each language's own client.
--
-- @cabal bench petrus-simulation --benchmark-options load@ runs the
-- interleaved load comparison ("Load"): one Haskell client drives this
-- service and the upstream one (@test/reference_simulation.py real@) with
-- identical requests, after checking that both answer each request with
-- the same bytes.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
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
import Petrus.Impetus.Dsl (BuiltNet)
import Petrus.Impetus.Petrinet
import Petrus.Json
import Petrus.Observation qualified as Observation
import Petrus.Simulation (simulate, simulationProfile)
import Petrus.Simulation.Http
import Petrus.TestSupport.Python (readLine, withPython)
import Petrus.TestSupport.Repo (repoRoot)
import Support (a, buildScenario, builtOf, exchange, netOf, normalize, origin, t)
import System.Environment (getArgs)
import Test.Tasty (localOption)
import Test.Tasty.Bench

blacks :: Int -> [Token]
blacks n = replicate n (Token Nothing Null)

paths :: Text -> Int -> [NetPath]
paths prefix n = [either (error . T.unpack) id (netPath (prefix <> T.pack (show i))) | i <- [0 .. n - 1]]

-- | @a → t → a@
loop :: BuiltNet
loop = builtOf (netOf (netSpec [place a] [transition t] [arc a t, arc t a]))

-- | 20 transitions consuming from and producing to @a@.
scan :: BuiltNet
scan = builtOf (netOf (netSpec [place a] (map transition ts) ([arc a p | p <- ts] ++ [arc p a | p <- ts])))
  where
    ts = paths "t" 20

-- | 20 transitions consuming from @a@ (no outputs).
scanSinks :: BuiltNet
scanSinks = builtOf (netOf (netSpec [place a] (map transition ts) [arc a p | p <- ts]))
  where
    ts = paths "t" 20

rest :: BuiltNet
rest = builtOf (netOf (netSpec [place a] [] []))

fire :: BuiltNet
fire = builtOf (netOf (netSpec [place a, place "b"] [transition t] [arc a t, arc t "b"]))

text :: Int -> Json
text n = String (T.replicate n "x")

run :: BuiltNet -> Marking -> Int -> IO Int
run built marking n = either (const 0) BS.length <$> simulate built marking n

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

originBytes :: ByteString
originBytes = BC.pack (T.unpack origin)

profileRequest, optionsRequest, invalidRequest, fixtureRequest :: ByteString
profileRequest = "GET /v1/simulation-profile HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: " <> originBytes <> "\r\n\r\n"
optionsRequest = "OPTIONS /v1/simulations HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: " <> originBytes <> "\r\n\r\n"
invalidRequest = post "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":true}"
fixtureRequest = post (either (error . show) id (dumps compact body))
  where
    (built, marking) = buildScenario
    definition = either (error . show) id (simulationProfile built) `member` "definition"
    body =
      Object
        [ ("expected_definition", definition)
        , ("initial_marking", either (error . show) id (Observation.marking marking))
        , ("max_actions", Int 32)
        ]
    member value key = maybe (error "no member") id (lookupMember key value)

post :: ByteString -> ByteString
post body =
  "POST /v1/simulations HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: "
    <> originBytes
    <> "\r\nContent-Type: application/json\r\nContent-Length: "
    <> BC.pack (show (BS.length body))
    <> "\r\n\r\n"
    <> body

main :: IO ()
main = do
  args <- getArgs
  let (built, marking) = buildScenario
  withSimulationServer (simulationServerConfig "127.0.0.1" 0 origin) built $ \server -> do
    port <- serverPort (simulationHttp server)
    case args of
      "load" : more -> load (case more of [n] -> read n; _ -> 5) port
      _ ->
        -- Wall-clock time for every benchmark, as the Python twins measure it
        -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
        -- time spent waiting on the kernel, servers and child processes.
        defaultMain . map (localOption WallTime) $
          [ bgroup
              "simulate"
              [ bench "fixture-32" (nfIO (run built marking 32))
              , bench "loop-24x256" (nfIO (run loop (markingFromList [(a, blacks 24)]) 256))
              , bench "loop-512x256-oversized" (nfIO (run loop (markingFromList [(a, blacks 512)]) 256))
              , bench "scan-480x16" (nfIO (run scan (markingFromList [(a, blacks 480)]) 16))
              , bench "payload-990k-rest" (nfIO (run rest (markingFromList [(a, [Token (Just "X") (text 990000)])]) 1))
              , bench "payload-400k-fire" (nfIO (run fire (markingFromList [(a, [Token (Just "X") (text 400000)])]) 1))
              , bench "refused-scan-bound" (nfIO (run scanSinks (markingFromList [(a, blacks 512)]) 1))
              ]
          , localOption (RelStDev 0.2) $
              bgroup
                "http"
                [ bench "profile" (nfIO (roundtrip port profileRequest))
                , bench "options" (nfIO (roundtrip port optionsRequest))
                , bench "invalid-400" (nfIO (roundtrip port invalidRequest))
                , bench "simulate-fixture-32" (nfIO (roundtrip port fixtureRequest))
                ]
          ]

load :: Int -> Int -> IO ()
load repetitions haskell = do
  root <- repoRoot
  script <- T.pack <$> readFile (root <> "/packages/petrus-simulation/test/reference_simulation.py")
  withPython script ["real"] $ \process -> do
    python <- read . BC.unpack <$> readLine process
    -- both services answer every request with the same bytes
    forM_ [profileRequest, optionsRequest, invalidRequest, fixtureRequest] $ \bytes -> do
      ours <- normalize <$> exchange haskell bytes
      theirs <- normalize <$> exchange python bytes
      unless (ours == theirs && not (BS.null ours)) $ fail ("the services differ on " <> show bytes)
    let status code = BS.isPrefixOf ("HTTP/1.0 " <> code <> " ")
        scenarios =
          [ Scenario "GET profile" profileRequest 1 2000 (status "200")
          , Scenario "GET profile" profileRequest 4 4000 (status "200")
          , Scenario "OPTIONS preflight" optionsRequest 1 2000 (status "204")
          , Scenario "POST invalid body (400)" invalidRequest 1 2000 (status "400")
          , Scenario "POST invalid body (400)" invalidRequest 4 4000 (status "400")
          , Scenario "POST fixture, 32 actions" fixtureRequest 1 500 (status "200")
          ]
    runLoad repetitions (Target "haskell" haskell) (Target "python" python) scenarios
