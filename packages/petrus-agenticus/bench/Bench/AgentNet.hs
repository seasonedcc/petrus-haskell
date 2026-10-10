-- | Agent-as-a-Net benchmarks, the twins of @bench/python_agent_net.py@.
--
-- * @run-4-phases-6-tools@: create an Engine over 'agentNet' with an
--   in-memory History and inline dispatch, then drive it to the @done@
--   token. Model phases 1..3 each propose two @workspace_read@ calls (all
--   succeed); phase 4 stops. That is 4 model Activities, 6 Hands Activities
--   and 1 terminal record.
-- * @loop-state-roundtrip-16@: @LoopState.from_data(json.loads(json.dumps(
--   state.to_data())))@ for a state carrying 16 results.
module Bench.AgentNet (benchmarks, checkWorkload) where

import Control.Exception (throwIO)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation (..))
import Petrus.Agenticus.Program.AgentNet
import Petrus.Engine qualified as Engine
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Dispatch.Inline (inlineDispatch, newInlineDispatch)
import Test.Tasty.Bench

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

digest :: T.Text
digest = T.replicate 64 "a"

initial :: LoopState
initial = ok (mkLoopState "episode-1" "turn-1" 1 4 0 8 Nothing Nothing 7 ["workspace_read"] [])

proposalsFor :: Integer -> [Proposal]
proposalsFor ph
  | ph <= 3 = [ok (mkProposal i "workspace_read" (Object [("path", String (i <> ".txt"))])) | k <- [1, 2 :: Int], let i = "call-" <> T.pack (show ph) <> "-" <> T.pack (show k)]
  | otherwise = []

-- | One full scripted run; returns the number of History records.
runOnce :: IO Int
runOnce = do
  let model inv _ = do
        current <- either throwIO pure (loopStateFromData inv.input)
        let ps = proposalsFor current.phase
            stop = if null ps then Stop else ToolUse
            suffix = T.pack (show current.phase)
        either throwIO (pure . modelSettlementToData) $
          mkModelSettlement current stop digest ("output-" <> suffix) ("continuation-" <> suffix) ps
      tool inv _ = do
        let identity = case inv.input of
              Object fields | Just (Object item) <- lookup "proposal" fields, Just (String i) <- lookup "id" item -> i
              _ -> error "malformed hands input"
        result <- either throwIO pure (mkModelResult identity True (Object [("value", String identity)]) Nothing)
        pure (Object [("version", Int 1), ("result", modelResultToData result)])
  store <- inMemoryHistoryStore
  port <- inlineDispatch <$> newInlineDispatch (Map.fromList [(modelPhaseActivity, model), (handsActivity, tool)])
  engine <-
    Engine.create
      agentNet
      "scripted-agent"
      store
      port
      (agentNetOptions Engine.defaultEngineOptions {Engine.marking = initialMarking initial})
  let loop = do
        outcome <- Engine.advance engine
        if outcome.ready then loop else pure ()
  loop
  n <- length <$> Engine.records engine
  Engine.close engine
  pure n

richState :: LoopState
richState =
  ok $
    mkLoopState "episode-1" "turn-1" 3 16 16 64 (Just "output-2") (Just "continuation-2") 7 ["workspace_read", "workspace_write"] $
      [ ok (mkModelResult i True (Object [("value", String i)]) Nothing)
      | k <- [1 .. 16 :: Int]
      , let i = "call-" <> T.pack (show k)
      ]

roundtrip :: LoopState -> LoopState
roundtrip s =
  let bytes = ok (J.dumps J.defaultDumps (loopStateToData s))
   in ok (loopStateFromData (ok (J.parseJson J.pythonLoads bytes)))

-- | Both twins must do the same work: the reference run ends with 122
-- History records.
checkWorkload :: IO ()
checkWorkload = do
  n <- runOnce
  if n == 122 then pure () else error ("agent-net workload drifted: " <> show n <> " records, expected 122")

benchmarks :: Benchmark
benchmarks =
  bgroup
    "agent-net"
    [ bench "run-4-phases-6-tools" (whnfIO runOnce)
    , bench "loop-state-roundtrip-16" (whnf (\s -> (roundtrip s).phase) richState)
    ]
