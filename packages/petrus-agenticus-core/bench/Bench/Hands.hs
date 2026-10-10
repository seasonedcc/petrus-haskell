-- | Hands benchmarks, the twins of @bench/python_hands.py@ (benchmark id
-- @agenticus-hands@).
--
-- Gateway overhead per call over an in-memory adapter that answers
-- immediately: a batch of 10 000 submissions with unique call ids (call
-- ledger and grant budget raised to fit), from one caller and from eight
-- concurrent callers, for @workspace_read@ and for @workspace_write@ (stage,
-- barrier-held postcheck and commit).  Each batch builds a fresh gateway;
-- divide the batch time by 10 000 for the per-call cost.  @parse@ times
-- 'parseToolRequest' alone on one request of each method.
module Bench.Hands (benchmarks) where

import Control.Concurrent.Async (forConcurrently_)
import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Hands.Contract
import Petrus.Agenticus.Hands.Gateway
import Petrus.Agenticus.Hands.Grants
import Petrus.Json (Json (..))
import Test.Tasty.Bench

batch :: Int
batch = 10000

envelope :: Text -> Text -> [(Text, Json)] -> Json
envelope call method params =
  Object
    [ ("version", Int 1)
    , ("call_id", String call)
    , ("episode_id", String "episode-1")
    , ("attachment_id", String "attachment-1")
    , ("attachment_epoch", Int 1)
    , ("grant_epoch", Int 1)
    , ("method", String method)
    , ("params", Object params)
    ]

samples :: [Json]
samples =
  [ envelope "call-1" "workspace_read" [("path", String "src/module/file.txt")]
  , envelope "call-1" "workspace_search" [("query", String "needle"), ("path", String "src")]
  , envelope "call-1" "workspace_shell" [("argv", Array [String "printf", String "ok"]), ("cwd", String ".")]
  , envelope "call-1" "workspace_write" [("path", String "out.txt"), ("content", String (T.replicate 256 "x"))]
  , envelope "call-1" "workspace_test" []
  ]

requests :: Text -> [(Text, Json)] -> [Json]
requests method params = [envelope ("call-" <> T.pack (show i)) method params | i <- [1 .. batch]]

readRequests, writeRequests :: [Json]
readRequests = requests "workspace_read" [("path", String "README.md")]
writeRequests = requests "workspace_write" [("path", String "out.txt"), ("content", String "safe")]

memoryAdapter :: HandsAdapter
memoryAdapter =
  HandsAdapter
    { read = \_ -> pure "safe"
    , search = \_ _ -> pure ["match"]
    , shell = \_ _ -> either (error . show) pure (mkShellOutcome 0 "ok" "" False)
    , stageWrite = \call path _ -> either (error . show) pure (mkStagedWrite call path (T.replicate 64 "d"))
    , commitWrite = \staged -> pure staged.digest
    , discardWrite = \_ -> pure ()
    , runTest = either (error . show) pure (mkTestOutcome True (T.replicate 64 "e"))
    , discardAllStages = pure 0
    }

freshGateway :: IO HandsGateway
freshGateway = do
  ledger <- newGrantLedger "attachment-1" 1
  _ <- openGrant ledger (grantSpec [WorkspaceRead, WorkspaceWrite] 1.0e12 (fromIntegral batch)) {specWritablePaths = ["out.txt"]}
  barrier' <- newBarrier
  let fence = CallFenceSource (pure (callFence True False 1.0e12))
  newHandsGateway (gatewayConfig "episode-1" memoryAdapter ledger fence barrier') {maxGatewayCalls = batch}

sequentially :: [Json] -> IO Int
sequentially payloads = do
  gw <- freshGateway
  forM_ payloads (submit gw)
  (.resultsAdmitted) <$> counters gw

concurrently :: Int -> [Json] -> IO Int
concurrently callers payloads = do
  gw <- freshGateway
  forConcurrently_ (chunks callers payloads) (mapM_ (submit gw))
  (.resultsAdmitted) <$> counters gw
  where
    chunks n xs = [[x | (i, x) <- zip [0 :: Int ..] xs, i `mod` n == k] | k <- [0 .. n - 1]]

benchmarks :: Benchmark
benchmarks =
  bgroup
    "hands"
    [ bench "parse-5-methods" (nf (map (either (const 0) (const (1 :: Int)) . parseToolRequest)) samples)
    , bench "gateway-read-10k-1-caller" (nfIO (sequentially readRequests))
    , bench "gateway-read-10k-8-callers" (nfIO (concurrently 8 readRequests))
    , bench "gateway-write-10k-1-caller" (nfIO (sequentially writeRequests))
    , bench "gateway-write-10k-8-callers" (nfIO (concurrently 8 writeRequests))
    ]
