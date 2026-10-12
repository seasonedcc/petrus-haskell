{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Cross-runtime replay of the reference's world fixtures through the real
-- Haskell Engine profiles (@packages/petrus-dst/engine@), and the authoring
-- halves of each @test_*_world.py@'s @is_exact_and_replayable@.
--
-- * Replay: each non-joined fixture replays through fresh profiles in a
--   fresh directory and must end with the reference's replay result bytes
--   (recorded in @test/data/transcripts.json@).
-- * Authoring: each Haskell story must author exactly the bytes the
--   reference's @build_*_artifact@ authors (recorded by
--   @scripts/engine_authored.py@ in @test/data/engine-authored.json@), and
--   the authored artifact must replay through fresh profiles with outcome
--   @pass@.
-- * Engine-profile world tests of @tests/dst/test_world.py@.
module Spec.EngineWorlds
  ( spec
  , ReplayCase (..)
  , replayCases
  , AuthorCase (..)
  , authorCases
  , replayFixture
  ) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Delayed qualified as Delayed
import Petrus.Testing.Dst.Engine.Delivery qualified as Delivery
import Petrus.Testing.Dst.Engine.GeneratedRuntime qualified as GeneratedRuntime
import Petrus.Testing.Dst.Engine.Lifecycle qualified as Lifecycle
import Petrus.Testing.Dst.Engine.Projection qualified as Projection
import Petrus.Testing.Dst.Engine.Retry qualified as Retry
import Petrus.Testing.Dst.Engine.Timer qualified as Timer
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World
import Spec.Support
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- | A registry of fresh profiles and checkers over one scratch directory.
type Fresh = FilePath -> IO (Registry IO)

-- | One reference fixture and the registry that replays it.
data ReplayCase = ReplayCase {file :: FilePath, registry :: Fresh}

-- | One reference builder, its Haskell twin, and the registry that replays
-- what it authors.
data AuthorCase = AuthorCase
  { builder :: Text
  , build :: FilePath -> IO (Either DstFailure AnyArtifact)
  , registry :: Fresh
  }

-- | Every profile and checker of @engine_world.py@ over one History path.
projectionRegistry :: Fresh
projectionRegistry dir = do
  let history = dir </> "history.jsonl"
  base <- Projection.engineProfile history
  resource <- Projection.resourceBoundedEngineProfile history
  refusal <- Projection.historyRefusalEngineProfile history
  ackLoss <- Projection.historyAckLossEngineProfile history
  dispatch <- Projection.dispatchRefusalEngineProfile history
  pure $
    registryOf
      [ SomeProfile base.profile
      , SomeProfile resource.profile
      , SomeProfile refusal.profile
      , SomeProfile ackLoss.profile
      , SomeProfile dispatch.profile
      ]
      [ Projection.engineHistoryChecker
      , Projection.commitAuthorityChecker
      , Projection.acceptedCommitAuthorityChecker
      , Projection.dispatchAuthorityChecker
      , Projection.terminalRefusalChecker
      ]

-- | The non-joined fixtures replayed through real profiles.
replayCases :: [ReplayCase]
replayCases =
  [ ReplayCase name projectionRegistry
  | name <-
      [ "projection-crash-recovery-world-v1.json"
      , "seeded-projection-crash-recovery-world-v3.json"
      , "terminal-checker-failure-world-v2.json"
      , "action-budget-exhaustion-world-v2.json"
      , "resource-bounded-recovery-world-v4.json"
      , "history-record-budget-exhaustion-world-v4.json"
      , "history-refusal-crash-recovery-world-v3.json"
      , "history-ack-loss-recovery-world-v3.json"
      , "dispatch-refusal-crash-recovery-world-v3.json"
      ]
  ]
    <> [ ReplayCase "delayed-terminal-recovery-world-v3.json" delayedRegistry
       , ReplayCase "identified-delivery-redelivery-world-v3.json" deliveryRegistry
       , ReplayCase "timer-crash-recovery-world-v3.json" timerRegistry
       , ReplayCase "lifecycle-reset-late-terminal-world-v3.json" lifecycleRegistry
       , ReplayCase "lifecycle-cancellation-refusal-world-v3.json" cancellationRegistry
       , ReplayCase "retry-crash-exhaustion-world-v3.json" retryRegistry
       , ReplayCase "delayed-retry-crash-recovery-world-v3.json" delayedRetryRegistry
       , ReplayCase "local-terminal-redelivery-world-v3.json" terminalRegistry
       , ReplayCase "generated-runtime-minimized-fair-regression-v4.json" generatedRuntimeRegistry
       ]

-- | The History and LocalDispatch database of a two-path world.
twoPaths :: FilePath -> (FilePath, FilePath)
twoPaths dir = (dir </> "history.jsonl", dir </> "dispatch.sqlite3")

retryRegistry :: Fresh
retryRegistry dir = do
  p <- uncurry Retry.retryEngineProfile (twoPaths dir)
  pure (registryOf [SomeProfile p.profile] [Retry.retryAuthorityChecker])

delayedRetryRegistry :: Fresh
delayedRetryRegistry dir = do
  p <- uncurry Retry.delayedRetryEngineProfile (twoPaths dir)
  pure (registryOf [SomeProfile p.profile] [Retry.delayedRetryAuthorityChecker])

terminalRegistry :: Fresh
terminalRegistry dir = do
  p <- uncurry Retry.terminalEngineProfile (twoPaths dir)
  pure (registryOf [SomeProfile p.profile] [Retry.terminalAuthorityChecker])

generatedRuntimeRegistry :: Fresh
generatedRuntimeRegistry dir = do
  p <- uncurry GeneratedRuntime.generatedRuntimeProfile (twoPaths dir)
  let checker = GeneratedRuntime.generatedRuntimeChecker
  pure (registryOf [SomeProfile p.profile] [checker])

twoHistories :: (FilePath -> FilePath -> IO (Either DstFailure AnyArtifact)) -> FilePath -> IO (Either DstFailure AnyArtifact)
twoHistories b = uncurry b . twoPaths

delayedRegistry :: Fresh
delayedRegistry dir = do
  p <- Delayed.delayedEngineProfile (dir </> "history.jsonl")
  pure (registryOf [SomeProfile p.engine.profile] [Delayed.delayedAuthorityChecker])

deliveryRegistry :: Fresh
deliveryRegistry dir = do
  p <- Delivery.deliveryEngineProfile (dir </> "history.jsonl")
  pure (registryOf [SomeProfile p.profile] [Delivery.deliveryAuthorityChecker])

lifecycleRegistry :: Fresh
lifecycleRegistry dir = do
  p <- Lifecycle.lifecycleEngineProfile (dir </> "history.jsonl")
  pure (registryOf [SomeProfile p.profile] [Lifecycle.lifecycleAuthorityChecker])

cancellationRegistry :: Fresh
cancellationRegistry dir = do
  p <- Lifecycle.lifecycleCancellationRefusalProfile (dir </> "history.jsonl")
  pure (registryOf [SomeProfile p.profile] [Lifecycle.cancellationAuthorityChecker])

timerRegistry :: Fresh
timerRegistry dir = do
  p <- Timer.timerEngineProfile (dir </> "history.jsonl")
  pure (registryOf [SomeProfile p.profile] [Timer.timerAuthorityChecker])

oneHistory :: (FilePath -> IO (Either DstFailure AnyArtifact)) -> FilePath -> IO (Either DstFailure AnyArtifact)
oneHistory b dir = b (dir </> "history.jsonl")

-- | The reference builders with Haskell twins.
authorCases :: [AuthorCase]
authorCases =
  [ AuthorCase "engine_world.build_projection_artifact" (oneHistory Projection.buildProjectionArtifact) projectionRegistry
  , AuthorCase "engine_world.build_seeded_projection_artifact" (oneHistory Projection.buildSeededProjectionArtifact) projectionRegistry
  , AuthorCase "engine_world.build_resource_bounded_artifact" (oneHistory Projection.buildResourceBoundedArtifact) projectionRegistry
  , AuthorCase
      "engine_world.build_resource_budget_failure_artifact"
      (oneHistory Projection.buildResourceBudgetFailureArtifact)
      projectionRegistry
  , AuthorCase "engine_world.build_history_refusal_artifact" (oneHistory Projection.buildHistoryRefusalArtifact) projectionRegistry
  , AuthorCase "engine_world.build_history_ack_loss_artifact" (oneHistory Projection.buildHistoryAckLossArtifact) projectionRegistry
  , AuthorCase "engine_world.build_dispatch_refusal_artifact" (oneHistory Projection.buildDispatchRefusalArtifact) projectionRegistry
  , AuthorCase "engine_world.build_invariant_failure_artifact" (oneHistory Projection.buildInvariantFailureArtifact) projectionRegistry
  , AuthorCase "engine_world.build_budget_failure_artifact" (oneHistory Projection.buildBudgetFailureArtifact) projectionRegistry
  , AuthorCase "delayed_world.build_delayed_artifact" (oneHistory Delayed.buildDelayedArtifact) delayedRegistry
  , AuthorCase "delivery_world.build_delivery_artifact" (oneHistory Delivery.buildDeliveryArtifact) deliveryRegistry
  , AuthorCase "timer_world.build_timer_artifact" (oneHistory Timer.buildTimerArtifact) timerRegistry
  , AuthorCase "lifecycle_world.build_lifecycle_artifact" (oneHistory Lifecycle.buildLifecycleArtifact) lifecycleRegistry
  , AuthorCase "lifecycle_world.build_lifecycle_cancellation_artifact" (oneHistory Lifecycle.buildLifecycleCancellationArtifact) cancellationRegistry
  , AuthorCase "retry_world.build_retry_artifact" (twoHistories Retry.buildRetryArtifact) retryRegistry
  , AuthorCase "retry_world.build_delayed_retry_artifact" (twoHistories Retry.buildDelayedRetryArtifact) delayedRetryRegistry
  , AuthorCase "retry_world.build_terminal_artifact" (twoHistories Retry.buildTerminalArtifact) terminalRegistry
  , AuthorCase
      "generated_runtime_world.build_generated_runtime_artifact"
      (twoHistories GeneratedRuntime.buildGeneratedRuntimeArtifact)
      generatedRuntimeRegistry
  ]

fixtureBytes :: FilePath -> IO BS.ByteString
fixtureBytes name = do
  bytes <- BS.readFile (fixturesDir </> name)
  pure (maybe bytes id (BS.stripSuffix "\n" bytes))

-- | Replay one fixture through fresh profiles in a fresh directory.
replayFixture :: ReplayCase -> IO (Either DstFailure AnyReplayResult)
replayFixture c = do
  bytes <- fixtureBytes c.file
  artifact <- either (fail . show) pure (decodeArtifact bytes)
  withSystemTempDirectory "petrus-dst-engine" $ \dir -> do
    reg <- c.registry dir
    replay reg artifact

expectedOutcomes :: IO [(Text, Json)]
expectedOutcomes = do
  vectors <- memberList "fixtures" <$> readJson (dataFile "transcripts.json")
  pure [(memberText "name" v, member "outcome" v) | v <- vectors]

authoredVectors :: IO [(Text, Text)]
authoredVectors = do
  vectors <- memberList "vectors" <$> readJson (dataFile "engine-authored.json")
  pure [(memberText "builder" v, memberText "artifact" v) | v <- vectors]

-- | The decoded replay result of a successful replay.
resultJson :: Either DstFailure AnyReplayResult -> Either Text Json
resultJson = \case
  Left failure -> Left (failureClass failure <> ": " <> failureMessage failure)
  Right result -> loadStrictJson (encodeReplayResult result)

spec :: Spec
spec = describe "Engine-backed worlds (real Haskell Engine profiles)" $ do
  describe "replay of the reference fixtures" $
    forM_ replayCases $ \c ->
      it c.file $ do
        expected <- expectedOutcomes
        outcome <- replayFixture c
        case lookup (T.pack c.file) expected of
          Nothing -> expectationFailure "fixture missing from transcripts.json"
          Just want -> canonText (replayJson outcome) `shouldBe` canonText want
  describe "authoring (is_exact_and_replayable)" $
    forM_ authorCases $ \c ->
      it (T.unpack c.builder) $ do
        vectors <- authoredVectors
        want <- maybe (fail "builder missing from engine-authored.json") pure (lookup c.builder vectors)
        authored <- withSystemTempDirectory "petrus-dst-engine" c.build
        artifact <- either (\f -> fail (T.unpack (failureClass f <> ": " <> failureMessage f))) pure authored
        encoded <- either (fail . T.unpack) pure (encodeArtifact artifact)
        BC.unpack encoded `shouldBe` T.unpack want
        replayed <- withSystemTempDirectory "petrus-dst-engine" $ \dir -> do
          reg <- c.registry dir
          replay reg artifact
        fmap (member "outcome") (resultJson replayed) `shouldBe` Right (String "pass")
  describe "the Engine-profile world (test_world.py)" $
    it "ends the predicate-poll budget explicitly" $
      withSystemTempDirectory "petrus-dst-engine" $ \dir -> do
        base <- Projection.engineProfile (dir </> "bounded-history.jsonl")
        let limits =
              Budget
                { actions = 3
                , queuedCommands = 2
                , timerAdvances = 0
                , logicalInstant = 0
                , reloads = 0
                , predicatePolls = 1
                , artifactBytes = 65536
                }
        (refused, ending) <- withToy (config base.profile (SomeBudget limits) [] Nothing) $ do
          t <- World.timeline
          refused <- World.tryWorld (Timeline.runUntil t "activity-requested" (const False))
          (refused,) <$> World.disposition
        case refused of
          Left failure -> do
            failureClass failure `shouldBe` "BudgetExhausted"
            T.unpack (failureMessage failure) `shouldContain` "predicate_polls"
          Right _ -> expectationFailure "run_until returned past an exhausted predicate-poll budget"
        ending `shouldBe` Just DBudgetExhausted
