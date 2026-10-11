-- | The reference's @*_manual_replay_route_is_deterministic@ tests (and
-- @test_failed_attempt_manual_replay_is_deterministic@): each runs the
-- replay command twice over a committed fixture and pins its output. Here
-- the command is @petrus-dst-world replay FIXTURE@, the twin of
-- @python -m tests.dst.replay_world FIXTURE@.
module Spec.ManualReplay (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import Petrus.Json (Json (..), lookupMember, parseJson, pythonLoads)
import Spec.Support (fixturesDir, member, readJson)
import Spec.Tooling (runWorldCommand)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

-- | What a case asserts beyond determinism, empty stderr, and its
-- scenario identity.
data Expect
  = -- | Version 2 result with this disposition (or none asserted).
    Current (Maybe Text)
  | -- | Version 2 failed attempt: disposition and failure kind.
    FailedAttempt Text
  | -- | The version 1 result format, without a failure member.
    Legacy

cases :: [(String, FilePath, Expect)]
cases =
  [ ("test_dispatch_refusal_manual_replay_route_is_deterministic", "dispatch-refusal-crash-recovery-world-v3.json", Current (Just "converged"))
  , ("test_history_ack_loss_manual_replay_route_is_deterministic", "history-ack-loss-recovery-world-v3.json", Current (Just "converged"))
  , ("test_lifecycle_manual_replay_route_is_deterministic", "lifecycle-reset-late-terminal-world-v3.json", Current (Just "quiescent"))
  , ("test_identified_delivery_manual_replay_route_is_deterministic", "identified-delivery-redelivery-world-v3.json", Current (Just "external_wait"))
  , ("test_delayed_terminal_manual_replay_route_is_deterministic", "delayed-terminal-recovery-world-v3.json", Current (Just "converged"))
  , ("test_resource_manual_replay_route_is_deterministic[green]", "resource-bounded-recovery-world-v4.json", Current (Just "converged"))
  , ("test_resource_manual_replay_route_is_deterministic[failure]", "history-record-budget-exhaustion-world-v4.json", Current (Just "budget_exhausted"))
  , ("test_lifecycle_cancellation_manual_replay_route_is_deterministic", "lifecycle-cancellation-refusal-world-v3.json", Current (Just "quiescent"))
  , ("test_seeded_manual_replay_route_is_deterministic", "seeded-projection-crash-recovery-world-v3.json", Current Nothing)
  , ("test_history_refusal_manual_replay_route_is_deterministic", "history-refusal-crash-recovery-world-v3.json", Current (Just "converged"))
  , ("test_legacy_manual_replay_route_is_deterministic", "projection-crash-recovery-world-v1.json", Legacy)
  , ("test_failed_attempt_manual_replay_is_deterministic[budget]", "action-budget-exhaustion-world-v2.json", FailedAttempt "budget_exhausted")
  , ("test_failed_attempt_manual_replay_is_deterministic[invariant]", "terminal-checker-failure-world-v2.json", FailedAttempt "invariant_failure")
  , ("test_timer_manual_replay_route_is_deterministic", "timer-crash-recovery-world-v3.json", Current (Just "converged"))
  , ("test_local_terminal_manual_replay_route_is_deterministic", "local-terminal-redelivery-world-v3.json", Current (Just "converged"))
  , ("test_retry_manual_replay_route_is_deterministic", "retry-crash-exhaustion-world-v3.json", Current (Just "quarantined"))
  , ("test_delayed_retry_manual_replay_route_is_deterministic", "delayed-retry-crash-recovery-world-v3.json", Current (Just "quarantined"))
  ]

spec :: Spec
spec = describe "manual replay routes (petrus-dst-world replay)" $
  forM_ cases $ \(name, file, expectation) -> it name $ do
    let fixture = fixturesDir </> file
    (code, first, firstErr) <- runWorldCommand ["replay", fixture]
    (code', second, secondErr) <- runWorldCommand ["replay", fixture]
    (code, code') `shouldBe` (ExitSuccess, ExitSuccess)
    (firstErr, secondErr) `shouldBe` ("", "")
    first `shouldBe` second
    result <- either fail pure (parseJson pythonLoads first)
    artifact <- readJson fixture
    member "scenario_id" result `shouldBe` member "scenario_id" artifact
    member "outcome" result `shouldBe` String "pass"
    case expectation of
      Current disposition -> do
        member "version" result `shouldBe` Int 2
        forM_ disposition $ \d -> member "disposition" result `shouldBe` String d
      FailedAttempt disposition -> do
        member "version" result `shouldBe` Int 2
        member "disposition" result `shouldBe` String disposition
        member "kind" (member "failure" result) `shouldBe` String disposition
      Legacy -> do
        member "format" result `shouldBe` String "petrus-dst-world-replay-result"
        lookupMember "failure" result `shouldBe` Nothing
