-- | @tests/integration/testing/test_readiness_world.py@: the deterministic
-- readiness World over the real V5 host and Petrus DST.
module ReadinessWorldSpec
  ( spec
  , withRoot
  , replayed
  , isInvariantViolation
  , isBudgetExhausted
  , setPath
  , PathKey (..)
  , items
  , lastFailure
  ) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, when)
import Data.IORef
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Host.Python (RuntimeError (..))
import Hamsterdan.Host.Service (ServiceHooks (..), defaultServiceHooks)
import Hamsterdan.Testing.Readiness (dump)
import Hamsterdan.Testing.World hiding (PullRequest (..))
import Hamsterdan.Testing.World.Contract
import Hamsterdan.Testing.World.Provider (Truth (..), initialAuthority, newContextHolder, newTruth, observation, pyException, request, setAuthority)
import Hamsterdan.Testing.World.Provider qualified as Provider
import Hamsterdan.Testing.World.Scenarios (cleanGreen, drain, green, limited, moved, setPr)
import Hamsterdan.GitHub.Models (WireResponse (..))
import Hamsterdan.Testing.Readiness (AuthorityClaim (..))
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
  ( ActionDisposition (..)
  , AnyArtifact (..)
  , AnyReplayResult (..)
  , ApplyResult (..)
  , BudgetFailure (..)
  , BudgetV4 (..)
  , CheckResult (..)
  , Disposition (..)
  , DstFailure (..)
  , ExpandedOperation (..)
  , FailureDetail (..)
  , FailureOperation (..)
  , JournalEntry (..)
  , JournalKind (..)
  , Observation (..)
  , OperationAttempt (..)
  , ProfileError (..)
  , ReplayResult (..)
  , ResourceUsage (..)
  , ScenarioArtifactV4 (..)
  , apiCompatibility
  , artifactVersion
  , canonicalBytes
  , toJson
  )
import Petrus.Testing.Dst.World qualified as World
import System.Directory (canonicalizePath)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec hiding (pending)

spec :: Spec
spec = describe "tests/integration/testing/test_readiness_world.py" $ do
  it "test_profile_and_checker_compatibility_identities_are_stable" $ do
    apiCompatibility `shouldBe` "petrus.testing.dst/v4"
    defaultBudget.profileResources `shouldBe` Map.fromList profileResourceLimits
    toJson profileIdentity
      `shouldBe` Object
        [ ("name", String "hamsterdan.readiness.v5-world")
        , ("version", Int 2)
        , ("digest", String "sha256:937b60ac87644fd2d97c5c4c529e760a254293ac49cc633c741f0226a2e92e5d")
        ]
    toJson checkerIdentity
      `shouldBe` Object
        [ ("name", String "hamsterdan.readiness.independent-model")
        , ("version", Int 4)
        , ("digest", String "sha256:05134192a4e6df87fada8cb73c5f67d85ebff6eb94c70f247258a2b51a434f9a")
        ]

  it "test_profile_resources_are_detached_complete_and_survive_generation_drop" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    setPr t moved "active"
    samples <- filter (\e -> e.kind == JResource) <$> inWorld rw World.journal
    samples `shouldNotBe` []
    forM_ samples $ \e -> keysOf (e.value .: "usage") `shouldBe` Map.keysSet defaultBudget.profileResources
    (head' samples).value .: "usage" .: "retained.profile.dropped_generations" `shouldBe` Int 0

    crash t "resource-accounting-generation-drop"
    dropped <- profileResourceUsage rw.profile Nothing
    Map.keysSet dropped.values `shouldBe` Map.keysSet defaultBudget.profileResources
    Map.lookup "retained.provider.authorities" dropped.values `shouldBe` Just 2
    Map.findWithDefault 0 "retained.host.sqlite_rows" dropped.values `shouldSatisfy` (> 0)
    Map.lookup "retained.profile.dropped_generations" dropped.values `shouldBe` Just 1
    Map.lookup "pending.profile.proposals" dropped.values `shouldBe` Just 0
    afterDrop <-
      filter (\e -> e.kind == JResource && e.name == "crash:resource-accounting-generation-drop")
        <$> inWorld rw World.journal
    case afterDrop of
      [entry] -> do
        entry.generation `shouldBe` Nothing
        entry.value .: "usage" `shouldBe` toJson dropped .: "values"
      other -> expectationFailure ("expected one drop sample, got " <> show (length other))
    closeWorld rw

  it "test_profile_resource_exhaustion_retains_and_replays_the_exact_failed_attempt" $ withRoot $ \root -> do
    rw <- newReadinessWorld (root </> "live") (limited "retained.provider.authorities" 1) Nothing
    t <- timeline rw
    setPr t moved "active" `shouldThrow` budgetExhausted "profile_resources:retained.provider.authorities"
    a <- artifact rw "readiness-profile-resource-exhaustion-v4"
    closeWorld rw
    artifactVersion a `shouldBe` 4
    failure <- lastFailure a
    failure.acceptedOperations `shouldBe` 1
    case failure.failure of
      FBudget b -> b.bound `shouldBe` "profile_resources:retained.provider.authorities"
      other -> expectationFailure ("not a budget failure: " <> show other)
    result <- replayed a (root </> "replay")
    result.disposition `shouldBe` DBudgetExhausted
    result.failure `shouldBe` Just failure.failure

  it "test_dropped_generation_resource_exhaustion_replays_the_crash_attempt" $ withRoot $ \root -> do
    rw <- newReadinessWorld (root </> "live") (limited "retained.profile.dropped_generations" 0) Nothing
    t <- timeline rw
    crash t "dropped-generation-resource-bound" `shouldThrow` budgetExhausted "profile_resources:retained.profile.dropped_generations"
    a <- artifact rw "readiness-dropped-generation-resource-exhaustion-v4"
    closeWorld rw
    failure <- lastFailure a
    case failure.attempt of
      ACrash _ -> pure ()
      other -> expectationFailure ("not a crash attempt: " <> show other)
    failure.acceptedOperations `shouldBe` 1
    case failure.failure of
      FBudget b -> b.bound `shouldBe` "profile_resources:retained.profile.dropped_generations"
      other -> expectationFailure ("not a budget failure: " <> show other)
    result <- replayed a (root </> "replay")
    result.disposition `shouldBe` DBudgetExhausted
    result.failure `shouldBe` Just failure.failure

  it "test_world_refuses_unknown_commands_and_undeclared_provider_calls" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    command t "readiness.unknown" (Object []) `shouldThrow` profileRaised "ValueError" "unknown readiness command"
    setCi t headSha ["build", "build"] [("build", "success")] `shouldThrow` profileRaised "ValueError" "required_checks must be unique"
    faultEffect t "undeclared" "before_acceptance" 1 `shouldThrow` profileRaised "ValueError" "unsupported readiness effect target"
    holder <- newContextHolder
    try (request rw.profile.truth holder "DELETE" "/repos/owner/repo/pulls/7" Nothing) >>= \case
      Left (e :: SomeException) -> e `shouldSatisfy` pyMatches "AssertionError" "undeclared provider request"
      Right _ -> expectationFailure "an undeclared provider request was served"
    closeWorld rw

  it "test_real_host_recovers_one_ambiguous_readiness_effect_after_crash_and_exact_replay" $ withRoot $ \root -> do
    rw <- newReadinessWorld (root </> "live") defaultBudget Nothing
    t <- timeline rw
    delivery <- cleanGreen t True
    accepted <- runUntil t "readiness effect accepted" (\s -> s .: "provider" .: "response_losses" == Array [String "readiness"])
    let acceptedState = accepted.value
    acceptedState .: "custody" .: delivery `shouldBe` String "terminal"
    acceptedState .: "provider" .: "accepted_by_kind" .: "readiness" `shouldBe` Int 1
    intAt (acceptedState .: "motus" .: "terminals") `shouldSatisfy` (>= 1)
    acceptedState .: "facts" .: "admitted_observations" `shouldBe` Array [String ("github-delivery:" <> delivery)]

    let stale = t
    crash t "after_readiness_terminal_before_projection"
    droppedGenerationsAlive rw.profile `shouldReturn` 0
    observe stale `shouldThrow` isStale
    pending stale `shouldThrow` isStale
    step stale `shouldThrow` isStale

    t2 <- restart rw
    pending stale `shouldThrow` isStale
    step stale `shouldThrow` isStale
    final <- converge t2
    final.value .: "expected" .: "ready" `shouldBe` Bool True
    final.value .: "actual" .: "readiness_published" `shouldBe` Bool True
    final.value .: "provider" .: "accepted_by_kind" .: "readiness" `shouldBe` Int 1
    intAt (final.value .: "provider" .: "lookup_recoveries") `shouldSatisfy` (>= 1)
    final.value .: "custody" .: delivery `shouldBe` String "terminal"

    a <- artifact rw "hamsterdan-readiness-ambiguity-restart-v1"
    entries <- length <$> inWorld rw World.journal
    retained <- either (fail . T.unpack) pure (canonicalBytes (toJson a))
    show retained `shouldNotSatisfy` isInfixOf "readiness-world-private-key"
    show retained `shouldNotSatisfy` isInfixOf "readiness-world-webhook-secret"
    final.value .: "bounds" .: "limits" `shouldBe` Object [(k, Int v) | (k, v) <- profileResourceLimits]
    forM_ (members (final.value .: "bounds" .: "usage")) $ \(k, v) ->
      intAt v `shouldSatisfy` (<= Map.findWithDefault 0 k (Map.fromList profileResourceLimits))
    closeWorld rw

    result <- replayed a (root </> "replay")
    result.disposition `shouldBe` DConverged
    result.operations `shouldBe` toInteger (length (operationsOf a))
    result.journalEntries `shouldBe` toInteger entries

  it "test_real_host_recovers_one_ambiguous_reminder_after_timer_maturity_and_crash" $ withRoot $ \root -> do
    rw <- newReadinessWorld (root </> "live") defaultBudget Nothing
    t <- timeline rw
    _ <- cleanGreen t False
    drain t
    let timerId = "timer:github:44:31:pr:7:i1:s0"
    armed <- (.value) <$> observe t
    armed .: "facts" .: "timers" `shouldBe` Array [timerFact timerId "scheduled"]
    armed .: "timer_custody"
      `shouldBe` Object
        [ ( "operations"
          , Array
              [ Object
                  [ ("identity", String "timer-command:github:44:31:pr:7:g1")
                  , ("generation", Int 1)
                  , ("applied_at", Int 0)
                  , ("acknowledged", Bool True)
                  ]
              ]
          )
        ,
          ( "timers"
          , Array
              [ Object
                  [ ("identity", String timerId)
                  , ("incarnation", Int 1)
                  , ("sequence", Int 0)
                  , ("head", String headSha)
                  , ("due_at", Int reminderDelay)
                  , ("state", String "armed")
                  , ("matured_at", Null)
                  , ("maturity_delivered", Bool False)
                  ]
              ]
          )
        ]

    loseEffectResponse t "reminder"
    _ <- advanceTime t reminderDelay
    accepted <- runUntil t "reminder effect accepted" (\s -> s .: "provider" .: "response_losses" == Array [String "reminder"])
    accepted.value .: "provider" .: "accepted_by_kind" .: "reminder" `shouldBe` Int 1

    crash t "after_reminder_acceptance_before_projection"
    t2 <- restart rw
    final <- converge t2
    final.value .: "facts" .: "timers"
      `shouldBe` Array [timerFact timerId "acknowledged", timerFact "timer:github:44:31:pr:7:i1:s1" "scheduled"]
    final.value .: "expected" .: "ready" `shouldBe` Bool True
    final.value .: "actual" .: "readiness_published" `shouldBe` Bool True
    final.value .: "provider" .: "accepted_by_kind" .: "reminder" `shouldBe` Int 1
    intAt (final.value .: "provider" .: "lookup_recoveries") `shouldSatisfy` (>= 1)
    map (.: "state") (items (final.value .: "timer_custody" .: "timers")) `shouldBe` [String "matured", String "armed"]

    a <- artifact rw "hamsterdan-readiness-reminder-ambiguity-restart-v1"
    closeWorld rw
    result <- replayed a (root </> "replay")
    result.disposition `shouldBe` DConverged
    result.operations `shouldBe` toInteger (length (operationsOf a))

  it "test_real_v5_recovers_one_ambiguous_authorized_git_publication_after_crash" $ withRoot $ \root -> do
    rw <- newReadinessWorld (root </> "live") defaultBudget Nothing
    t <- timeline rw
    _ <- cleanGreen t False
    drain t
    _ <- setHumanComment t 501 "change" "author"
    delivery <- emitWebhook t "issue_comment" "created"
    _ <- setAgentTerminal t ("conversation:owner/repo:pr:7:delivery:" <> delivery) "conversation_change" "changed" 1
    let publicationOperation = "push:comment:501:" <> headSha <> ":i1"
    _ <- setAgentTerminal t ("mutation:owner/repo:pr:7:" <> publicationOperation) "coding" "changed" 1
    faultGitPublication t publicationOperation "ref_cas" 1
    _ <- deliverWebhook t delivery
    accepted <- runUntil t "Git ref update accepted without a response" (\s -> length (items (s .: "provider" .: "git_publications")) == 1)
    let publication = head' (items (accepted.value .: "provider" .: "git_publications"))
        newHead = textAt (publication .: "result_head")
    publication .: "operation" `shouldBe` String publicationOperation
    publication .: "response_lost" `shouldBe` Bool True

    crash t "after_git_ref_acceptance_before_recovery"
    t2 <- restart rw
    drain t2
    green t2 newHead
    _ <- emitWebhook t2 "pull_request" "synchronize" >>= deliverWebhook t2
    drain t2
    _ <- setHumanComment t2 502 ("recover:" <> publicationOperation) "author"
    recoveryDelivery <- emitWebhook t2 "issue_comment" "created"
    _ <- setAgentTerminal t2 ("conversation:owner/repo:pr:7:delivery:" <> recoveryDelivery) "conversation_recover" "clear" 1
    _ <- deliverWebhook t2 recoveryDelivery
    final <- converge t2

    final.value .: "expected" .: "violations" `shouldBe` Array []
    final.value .: "expected" .: "ready" `shouldBe` Bool True
    final.value .: "actual" .: "readiness_published" `shouldBe` Bool True
    let recovery = "github-delivery:" <> recoveryDelivery
    final.value .: "provider" .: "git_publications"
      `shouldBe` Array [mergeObject publication [("recovered", Bool True), ("recovery_identity", String recovery)]]
    intAt (final.value .: "provider" .: "git_reconciliations") `shouldSatisfy` (>= 3)
    map (.: "variant") (items (final.value .: "git_custody" .: "terminals")) `shouldBe` [String "FaultM", String "Pushed"]
    final.value .: "provider" .: "admitted_recoveries"
      `shouldBe` Array [Object [("operation", String publicationOperation), ("identity", String recovery)]]

    sequenceNow <- observationAt rw
    let unauthorized = setPath [Key "provider", Key "admitted_recoveries"] (Array []) final.value
    case checkReadiness (sequenceNow unauthorized) of
      Right r -> do
        r.passed `shouldBe` False
        r.detail .: "git_custody_parity" `shouldBe` Bool False
        head' (items (r.detail .: "git_custody_mismatches")) .: "field" `shouldBe` String "recovery_authorization"
      Left e -> expectationFailure (show e)
    let wrongHead = setPath [Key "git_custody", Key "terminals", Index (-1), Key "result_head"] (String (T.replicate 40 "d")) final.value
    case checkReadiness (sequenceNow wrongHead) of
      Right r -> do
        r.passed `shouldBe` False
        any (\m -> m .: "field" == String "terminal_result_head") (items (r.detail .: "git_custody_mismatches")) `shouldBe` True
      Left e -> expectationFailure (show e)

    a <- artifact rw "hamsterdan-v5-git-ambiguity-restart-v1"
    closeWorld rw
    result <- replayed a (root </> "replay")
    result.disposition `shouldBe` DConverged
    result.operations `shouldBe` toInteger (length (operationsOf a))

  it "test_checker_rejects_timer_custody_that_differs_from_independent_schedule" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    _ <- cleanGreen t False
    drain t
    state <- (.value) <$> observe t
    at <- observationAt rw
    let corrupted = setPath [Key "timer_custody", Key "timers", Index 0, Key "head"] (String moved) state
    case checkReadiness (at corrupted) of
      Right r -> do
        r.passed `shouldBe` False
        r.detail .: "timer_custody_parity" `shouldBe` Bool False
        r.detail .: "timer_custody_mismatches"
          `shouldBe` Array
            [ Object
                [ ("identity", String "timer:github:44:31:pr:7:i1:s0")
                , ("field", String "head")
                , ("expected", String headSha)
                , ("observed", String moved)
                ]
            ]
      Left e -> expectationFailure (show e)
    closeWorld rw

  it "test_checker_rejects_timer_maturity_before_the_independent_deadline" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    _ <- cleanGreen t False
    drain t
    _ <- advanceTime t reminderDelay
    settled <- converge t
    at <- observationAt rw
    let corrupted = setPath [Key "timer_custody", Key "timers", Index 0, Key "matured_at"] (Int (reminderDelay - 1)) settled.value
    case checkReadiness (at corrupted) of
      Right r -> do
        r.passed `shouldBe` False
        r.detail .: "timer_custody_parity" `shouldBe` Bool False
        r.detail .: "timer_custody_mismatches"
          `shouldBe` Array
            [ Object
                [ ("identity", String "timer:github:44:31:pr:7:i1:s0")
                , ("field", String "matured_at")
                , ("expected", Int reminderDelay)
                , ("observed", Int (reminderDelay - 1))
                ]
            ]
      Left e -> expectationFailure (show e)
    closeWorld rw

  it "test_provider_head_movement_allows_projection_lag_without_retroactive_effect_failure" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    _ <- cleanGreen t False
    drain t
    earlier <- (.value) <$> observe t
    earlier .: "expected" .: "ready" `shouldBe` Bool True
    earlier .: "actual" .: "readiness_published" `shouldBe` Bool True
    setPr t moved "active"
    later <- (.value) <$> observe t
    later .: "expected" .: "blockers" `shouldBe` Array [String "current_authority_admission"]
    later .: "expected" .: "violations" `shouldBe` Array []
    later .: "actual" .: "readiness_published" `shouldBe` Bool False
    later .: "host" .: "snapshot" .: "head" `shouldBe` String headSha
    closeWorld rw

  it "test_provider_effect_retains_authored_full_authority_when_same_head_authority_moves" $ do
    truth <- newTruth
    let authored = initialAuthority
        operation = "ready:" <> headSha <> ":i1"
        acceptedUnder = authored {base = T.replicate 40 "d", policy = "policy:changed"}
    Provider.bindEffectAuthority truth "readiness" operation authored
    setAuthority truth acceptedUnder
    holder <- newContextHolder
    response <-
      request truth holder "POST" "/repos/owner/repo/issues/7/comments" . Just $
        Object [("body", String ("readiness\n\n<!-- hamsterdan:readiness operation=" <> operation <> " head=" <> headSha <> " -->"))]
    response.status `shouldBe` 201
    current <- readIORef truth
    case items (observation current .: "effects") of
      [effect] -> do
        effect .: "authority" `shouldBe` dump authored
        effect .: "provider_authority_at_acceptance" `shouldBe` dump acceptedUnder
      other -> expectationFailure ("expected one effect, got " <> show (length other))

  it "test_delayed_old_delivery_admits_current_provider_authority_at_custody_execution" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    setPr t headSha "active"
    green t headSha
    delayed <- emitWebhook t "pull_request" "synchronize"
    setPr t moved "active"
    green t moved
    _ <- deliverWebhook t delayed
    drain t
    state <- (.value) <$> observe t
    state .: "facts" .: "authority" .: "admitted" .: "head" `shouldBe` String moved
    state .: "host" .: "snapshot" .: "head" `shouldBe` String moved
    state .: "expected" .: "ready" `shouldBe` Bool True
    state .: "expected" .: "violations" `shouldBe` Array []
    closeWorld rw

  it "test_checker_rejects_stale_snapshot_even_when_old_and_current_heads_are_ready" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    _ <- cleanGreen t False
    drain t
    setPr t moved "active"
    green t moved
    _ <- emitWebhook t "pull_request" "synchronize" >>= deliverWebhook t
    drain t
    state <- (.value) <$> observe t
    at <- observationAt rw
    let stale = setPath [Key "host", Key "snapshot", Key "head"] (String headSha) state
    case checkReadiness (at stale) of
      Right r -> do
        r.passed `shouldBe` False
        r.detail .: "ready_parity" `shouldBe` Bool True
        r.detail .: "snapshot_parity" `shouldBe` Bool False
      Left e -> expectationFailure (show e)
    closeWorld rw

  it "test_fair_phase_refuses_new_external_events" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    beginFair t
    setCi t headSha ["build"] [("build", "success")] `shouldThrow` \case
      DstError message -> "fair phase" `T.isInfixOf` message
      _ -> False
    closeWorld rw

  it "test_duplicate_delivery_is_one_independent_admission_and_logical_time_is_explicit" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    result <- advanceTime t 7
    result.value `shouldBe` Object [("target", Int 7)]
    inWorld rw World.currentInstant `shouldReturn` 7
    delivery <- cleanGreen t False
    let drainWorld = do
          remaining <- inWorld rw World.pendingCount
          when (remaining > 0) (inWorld rw World.step >> drainWorld)
    drainWorld
    duplicate <- deliverWebhook t delivery
    state <- (.value) <$> observe t
    duplicate.disposition `shouldBe` Idempotent
    state .: "provider" .: "accepted_by_kind" .: "readiness" `shouldBe` Int 1
    state .: "facts" .: "admitted_observations" `shouldBe` Array [String ("github-delivery:" <> delivery)]
    state .: "custody" .: delivery `shouldBe` String "terminal"
    closeWorld rw

  it "test_identical_webhook_emission_remains_idempotent_after_logical_time_moves" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    delivery <- emitWebhook t "issue_comment" "created"
    _ <- advanceTime t 7
    let fixture = "issue_comment:created"
    repeated <-
      command t "readiness.github.webhook.emit" $
        Object
          [ ("subject", String subject)
          , ("delivery", String delivery)
          , ("event", String "issue_comment")
          , ("fixture", String fixture)
          , ("digest", String (strictDigest (Object [("event", String "issue_comment"), ("fixture", String fixture)])))
          ]
    repeated.disposition `shouldBe` Idempotent
    current <- readIORef rw.profile.truth
    Map.size current.emittedDeliveries `shouldBe` 1
    closeWorld rw

  it "test_unexpected_retained_custody_cannot_be_normalized_as_success" $ withRoot $ \root -> do
    failed <- newIORef False
    let failOnce _ _ real = do
          already <- atomicModifyIORef' failed (True,)
          if already then real else throwIO (RuntimeError "simulated unexpected posture failure")
        prepare p = writeIORef p.hostHooks (Just defaultServiceHooks {aroundRecordPosture = failOnce})
    rw <- newReadinessWorldWith root defaultBudget Nothing prepare readinessChecker
    t <- timeline rw
    delivery <- cleanGreen t False
    inWorld rw World.step `shouldThrow` invariantViolation "independent-model"
    current <- readIORef rw.profile.truth
    length current.admitted `shouldBe` 0
    current.custodyActions
      `shouldBe` [ Object
                     [ ("expected", Object [("delivery", String delivery), ("disposition", String "completed")])
                     , ("observed", Object [("delivery", String delivery), ("disposition", String "retained")])
                     ]
                 ]
    entries <- inWorld rw World.journal
    case drop (length entries - 2) entries of
      [check, failure] -> do
        check.kind `shouldBe` JCheck
        check.value .: "result" .: "detail" .: "custody_action_mismatches" `shouldBe` Array current.custodyActions
        failure.kind `shouldBe` JFailure
        failure.value .: "failure" .: "kind" `shouldBe` String "invariant_failure"
      _ -> expectationFailure "the journal has fewer than two entries"
    closeWorld rw

  it "test_terminally_disposed_custody_cannot_be_normalized_as_semantic_admission" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    _ <- cleanGreen t False
    let drainWorld = do
          remaining <- inWorld rw World.pendingCount
          when (remaining > 0) (inWorld rw World.step >> drainWorld)
    drainWorld
    delivery <- emitWebhook t "issue_comment" "created"
    _ <- deliverWebhook t delivery
    inWorld rw World.step `shouldThrow` invariantViolation "independent-model"
    current <- readIORef rw.profile.truth
    last' current.custodyActions
      `shouldBe` Object
        [ ("expected", Object [("delivery", String delivery), ("disposition", String "completed")])
        , ("observed", Object [("delivery", String delivery), ("disposition", String "disposed")])
        ]
    a <- artifact rw "disposed-custody-invariant-v3"
    closeWorld rw
    failure <- lastFailure a
    failure.attempt `shouldBe` AStep
    failure.acceptedOperations `shouldBe` 1
    case failure.failure of
      FInvariant _ -> pure ()
      other -> expectationFailure ("not an invariant failure: " <> show other)
    result <- replayed a (root </> "replay")
    result.disposition `shouldBe` DInvariantFailure
    case result.failure of
      Just (FInvariant _) -> pure ()
      other -> expectationFailure ("replay failure is not an invariant failure: " <> show other)

-- ---------------------------------------------------------------------------
-- Helpers

withRoot :: (FilePath -> IO a) -> IO a
withRoot use = withSystemTempDirectory "hamsterdan-world" (\dir -> canonicalizePath dir >>= use)

-- | @replay_readiness(artifact, root)@, which must pass.
replayed :: AnyArtifact -> FilePath -> IO ReplayResult
replayed a root =
  replayReadiness a root >>= \case
    Right (ReplayV2 result) -> pure result
    Right other -> fail ("unexpected replay result version: " <> show other)
    Left failure -> fail ("replay refused: " <> show failure)

operationsOf :: AnyArtifact -> [ExpandedOperation]
operationsOf = \case
  ArtifactV4 a -> a.operations
  _ -> []

-- | The artifact's last operation, which must be a failure.
lastFailure :: AnyArtifact -> IO FailureOperation
lastFailure a = case reverse (operationsOf a) of
  Failed failure : _ -> pure failure
  _ -> fail "the artifact's last operation is not a failure"

-- | @Observation(name="readiness.state", value=…, instant=world.instant,
-- generation=world.generation, sequence=0)@.
observationAt :: ReadinessWorld -> IO (Json -> Observation)
observationAt rw = do
  instantNow <- inWorld rw World.currentInstant
  generationNow <- inWorld rw World.generation
  pure (\value -> Observation {name = "readiness.state", value, instant = instantNow, generation = maybe 0 id generationNow, sequence = 0})

isStale :: DstFailure -> Bool
isStale = \case
  StaleGeneration _ -> True
  _ -> False

isInvariantViolation, isBudgetExhausted :: DstFailure -> Bool
isInvariantViolation = \case
  InvariantViolation _ -> True
  _ -> False
isBudgetExhausted = \case
  BudgetExhausted _ _ -> True
  _ -> False

budgetExhausted :: Text -> DstFailure -> Bool
budgetExhausted bound = \case
  BudgetExhausted b _ -> b == bound
  _ -> False

invariantViolation :: Text -> DstFailure -> Bool
invariantViolation fragment = \case
  InvariantViolation message -> fragment `T.isInfixOf` message
  _ -> False

profileRaised :: Text -> Text -> DstFailure -> Bool
profileRaised cls fragment = \case
  ProfileRaised (ProfileError c message) -> c == cls && fragment `T.isInfixOf` message
  _ -> False

pyMatches :: Text -> Text -> SomeException -> Bool
pyMatches cls fragment e = let (c, message) = pyException e in c == cls && fragment `T.isInfixOf` message

timerFact :: Text -> Text -> Json
timerFact identity status = Object [("identity", String identity), ("status", String status), ("blocks_readiness", Bool False)]

members :: Json -> [(Text, Json)]
members = \case
  Object xs -> xs
  _ -> []

keysOf :: Json -> Set.Set Text
keysOf = Set.fromList . map fst . members

items :: Json -> [Json]
items = \case
  Array xs -> xs
  _ -> []

intAt :: Json -> Integer
intAt = \case
  Int i -> i
  _ -> 0

textAt :: Json -> Text
textAt = \case
  String s -> s
  _ -> ""

head' :: [a] -> a
head' = \case
  x : _ -> x
  [] -> error "empty list"

last' :: [Json] -> Json
last' = \case
  [] -> Null
  xs -> last xs

-- | @value | changes@ for JSON objects.
mergeObject :: Json -> [(Text, Json)] -> Json
mergeObject value changes = case value of
  Object xs -> Object ([(k, maybe v id (lookup k changes)) | (k, v) <- xs] <> [(k, v) | (k, v) <- changes, k `notElem` map fst xs])
  other -> other

data PathKey = Key Text | Index Int

-- | Replace the value at a path (a negative index counts from the end).
setPath :: [PathKey] -> Json -> Json -> Json
setPath path new value = case (path, value) of
  ([], _) -> new
  (Key k : rest, Object xs) -> Object [(k', if k' == k then setPath rest new v else v) | (k', v) <- xs]
  (Index i : rest, Array xs) ->
    let position = if i < 0 then length xs + i else i
     in Array [if n == position then setPath rest new v else v | (n, v) <- zip [0 ..] xs]
  _ -> value
