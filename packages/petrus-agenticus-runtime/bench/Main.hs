-- | Local Agent-as-a-Net runner hot paths; the twin of @bench/python_runner.py@.
--
-- * @runner-3-phases-3-reads@: create a runner in a fresh directory, then
--   drain it to its terminal. Model phases 1 and 2 each propose
--   @workspace_read@ calls (two, then one) and phase 3 stops. Every
--   projection is saved through the atomic JSON repository and every
--   History record goes to @history.jsonl@.
-- * @projection-roundtrip@: @AgentNetThreadProjection.from_data(json.loads(text))@
--   and back to compact sorted JSON, over that run's final @thread.json@.
--
-- It also runs the Pi rows ("PiBench", "PiA2Bench"; @bench/results-pi.md@),
-- the hosts' protocol rows ("HostsBench"; @bench/results-hosts.md@) and the
-- whole Codex, Claude and Amp Turns ("TurnsBench", the twin of
-- @bench/python_bench.py@; @bench/results-hosts.md@). Every row measures
-- wall-clock time.
module Main (main) where

import Control.Exception (finally, throwIO)
import Control.Monad (void)
import Data.ByteString qualified as B
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityExecutionContext (..), ActivityInvocation (..))
import Petrus.Agenticus.Attachment.Binding
import Petrus.Agenticus.Attachment.Episode
import Petrus.Agenticus.Catalog.Descriptor (capabilityDescriptor)
import Petrus.Agenticus.Catalog.Resolution (mkResolutionSnapshot)
import Petrus.Agenticus.Hands.Contract (ToolMethod (..), capabilityScopedHands)
import Petrus.Agenticus.Hands.Gateway (HandsAdapter (..), StagedWrite (..), mkShellOutcome, mkStagedWrite, mkTestOutcome)
import Petrus.Agenticus.Hands.Grants (GrantSpec (..), grantSpec, openGrant)
import Petrus.Agenticus.Program.AgentNet
import Petrus.Agenticus.Runtime.AgentNetRunner
import Petrus.Agenticus.Runtime.Profiles (TerritoryProfile (..), agentAsNetA5Local, territoryIdentity)
import Petrus.Agenticus.Thread.Identity (mkEpisodeId, mkThreadId)
import Petrus.Agenticus.Thread.Lifecycle (newThread)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import HostsBench (hostsBenchmarks)
import PiA2Bench (piA2Benchmarks)
import PiBench (piBenchmarks)
import TurnsBench (turnsBenchmarks)
import Test.Tasty (localOption)
import Test.Tasty.Bench

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

binding :: AttachmentBinding
binding =
  AttachmentBinding
    { kind = "local-runner"
    , cancel = \_ -> pure ()
    , exportArchive = pure "archive"
    , settle = either throwIO pure (mkBindingSettlement "local-runner" "clean" True "")
    , motus = Nothing
    }

adapter :: HandsAdapter
adapter =
  HandsAdapter
    { read = \_ -> pure "safe"
    , search = \_ _ -> pure ["match"]
    , shell = \_ _ -> either throwIO pure (mkShellOutcome 0 "safe" "" False)
    , stageWrite = \call path' _ -> either throwIO pure (mkStagedWrite call path' (T.replicate 64 "b"))
    , commitWrite = \staged -> pure staged.digest
    , discardWrite = \_ -> pure ()
    , runTest = either throwIO pure (mkTestOutcome True (T.replicate 64 "c"))
    , discardAllStages = pure 0
    }

readCall :: Text -> Text -> Proposal
readCall callId path' = ok (mkProposal callId "workspace_read" (Object [("path", String path')]))

plans :: [(StopReason, [Proposal])]
plans =
  [ (ToolUse, [readCall "read-1" "README.md", readCall "read-2" "src/main.py"])
  , (ToolUse, [readCall "read-3" "docs/x.md"])
  , (Stop, [])
  ]

model :: IO (ActivityInvocation -> ActivityExecutionContext -> IO Json)
model = do
  remaining <- newIORef plans
  pure $ \invocation ctx -> do
    state' <- either throwIO pure (loopStateFromData invocation.input)
    void (ctx.heartbeat (Just (Object [("phase", String "model")])))
    (stop, proposals) <- atomicModifyIORef' remaining (\case x : xs -> (xs, x); [] -> ([], error "StopIteration"))
    let suffix = T.pack (show state'.phase)
    either throwIO (pure . modelSettlementToData) $
      mkModelSettlement state' stop (T.replicate 64 "a") ("output-" <> suffix) ("continuation-" <> suffix) proposals

-- | One full run; returns the final @thread.json@ bytes.
runOnce :: IO B.ByteString
runOnce = withSystemTempDirectory "runner-bench" $ \tmp -> do
  let snapshot =
        ok $
          mkResolutionSnapshot
            1
            [agentAsNetA5Local, capabilityScopedHands, capabilityDescriptor (territoryIdentity Local) [] []]
  current <-
    newEpisodeAttachment (ok (mkEpisodeId "episode-1")) snapshot binding "attachment-1" 100 episodeOptions {clock = pure 1}
  void $
    openGrant
      (grants current)
      (grantSpec [WorkspaceRead] 90 8) {specWritablePaths = ["out.txt"], specAllowedArgv = [["printf", "ok"]]}
  let initial = ok (mkLoopState "episode-1" "turn-1" 1 3 0 8 Nothing Nothing 1 ["workspace_read"] [])
  m <- model
  runner <- createRunner tmp "agent-net-1" (ok (newThread (ok (mkThreadId "thread-1")) Nothing)) initial current m adapter
  projection <- drain runner 256
  closeRunner runner
  if projectionSettled projection then B.readFile (tmp </> "thread.json") else fail "run did not settle"

roundtrip :: B.ByteString -> B.ByteString
roundtrip bytes =
  ok
    ( J.dumps
        J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":", J.sortKeys = True, J.allowNan = False}
        (projectionToData (ok (projectionFromData (ok (J.parseJson J.pythonLoads bytes)))))
    )

main :: IO ()
main = withSystemTempDirectory "pi-bench" $ \tmp -> do
  final <- runOnce
  pi' <- piBenchmarks tmp
  (a2, closeA2) <- piA2Benchmarks (tmp </> "a2")
  turns <- turnsBenchmarks tmp
  defaultMain
    ( map (localOption WallTime) $
      [ bench "runner-3-phases-3-reads" (whnfIO runOnce)
      , bench "projection-roundtrip" (nf roundtrip final)
      ]
        <> pi'
        <> a2
        <> hostsBenchmarks
        <> turns
    )
    `finally` closeA2
