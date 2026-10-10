{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The toy World stories of @scripts/world_stories.py@, authored here with
-- the Haskell toys and compared with the Python-authored vectors: exact
-- artifact bytes, replay results, observations, and exception classes and
-- messages. Each story mirrors one Engine-independent test of the
-- reference's @tests/dst/test_world.py@.
module Spec.Stories (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World
import Spec.Support
import Test.Hspec
import Toy

stories :: IO Json
stories = readJson (dataFile "world-stories.json")

story :: Text -> IO Json
story name = member name <$> stories

-- | Run a computation inside the story, capturing its failure.
attempt :: WorldT IO g a -> WorldT IO g Json
attempt body = pyErrorOf <$> World.tryWorld body

queueReplay :: Queue -> [Checker] -> AnyArtifact -> IO Json
queueReplay q checkers artifact = replayJson <$> replay (registryOf [SomeProfile (queueProfile q)] checkers) artifact

fresh :: (Queue -> Profile IO ()) -> [Checker] -> AnyArtifact -> IO Json
fresh build checkers artifact = do
  q <- newQueue
  replayJson <$> replay (registryOf [SomeProfile (build q)] checkers) artifact

dispositionJson :: Maybe Disposition -> Json
dispositionJson = maybe Null (String . dispositionText)

spec :: Spec
spec = describe "toy World stories (Python-authored vectors)" $ do
  it "owns stable ids, total tie order, and logical time (stable-order)" $ do
    s <- story "stable-order"
    q <- newQueue
    (steps, observation, artifact) <- withToy (config (queueProfile q) (budget 4 2 1 5 0 1) [] Nothing) $ do
      t <- World.timeline
      first <- World.step
      second <- World.step
      observation <- Timeline.observe t "queue.state"
      Timeline.finish t Quiescent
      artifact <- World.artifact "stable-order-v1"
      pure ([first, second], observation, artifact)
    Array (map (toJson . OpExecute) steps) `shouldBeJson` member "steps" s
    toJson observation `shouldBeJson` member "observation" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh queueProfile [] artifact >>= (`shouldBeJson` member "replay" s)

  it "accounts for profile resources in version 4 and replays exactly (resource-v4)" $ do
    s <- story "resource-v4"
    q <- newQueue
    (artifact, entries) <- withToy (config (resourceQueueProfile q) (resourceBudget 2) [] Nothing) $ do
      t <- World.timeline
      _ <- World.step
      _ <- World.step
      _ <- Timeline.observe t "queue.state"
      Timeline.finish t Quiescent
      (,) <$> World.artifact "resource-bounded-queue-v4" <*> World.journal
    Array [String e.name | e <- entries, e.kind == JResource] `shouldBeJson` member "resources" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh resourceQueueProfile [] artifact >>= (`shouldBeJson` member "replay" s)

  it "retains the accepted operation which exceeds a profile resource (resource-exhaustion-v4)" $ do
    s <- story "resource-exhaustion-v4"
    q <- newQueue
    (refused, artifact) <- withToy (config (resourceQueueProfile q) (resourceBudget 1) [] Nothing) $ do
      _ <- World.step
      refused <- attempt World.step
      (refused,) <$> World.artifact "resource-budget-exhaustion-v4"
    refused `shouldBeJson` member "error" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh resourceQueueProfile [] artifact >>= (`shouldBeJson` member "replay" s)

  it "requires an exact stable resource key set (resource-keyset)" $ do
    s <- story "resource-keyset"
    q <- newQueue
    outcome <- startWorld (config (incompleteResourceProfile q) (resourceBudget 2) [] Nothing)
    outcome `shouldFailWith` member "error" s

  it "closes an installed generation when the initial checker refuses" $ do
    s <- story "constructor-checker-refusal"
    q <- newQueue
    outcome <- startWorld (config (queueProfile q) (budget 8 2 1 5 0 1) [rejectingChecker] Nothing)
    outcome `shouldFailWith` member "error" s
    closes <- queueCloses q
    Int (toInteger closes) `shouldBeJson` member "closes" s

  it "refuses every authored finish while work is scheduled" $ do
    s <- story "finish-pending"
    let cases = [(Converged, "converged"), (Quiescent, "quiescent"), (ExternalWait, "external_wait"), (Quarantined, "quarantined")]
    mapM_
      ( \(ending, key) -> do
          q <- newQueue
          refused <- withToy (config (queueProfile q) (budget 2 2 1 5 0 1) [] Nothing) $ do
            t <- World.timeline
            attempt (Timeline.finish t ending)
          refused `shouldBeJson` member key s
      )
      cases

  it "drains profile work in the fair phase without authored interference" $ do
    s <- story "fair-phase"
    q <- newQueue
    (errors, artifact) <- withToy (config (queueProfile q) (budget 8 2 1 5 0 1) [] Nothing) $ do
      t <- World.timeline
      _ <- World.step
      _ <- World.step
      Timeline.beginFair t
      errors <-
        sequence
          [ attempt (Timeline.command t "queue.record" (Object [("id", String "late")]))
          , attempt (Timeline.activateFault t (Timeline.fault "late" "cut"))
          , attempt (Timeline.crash t "cut")
          , attempt (Timeline.beginFair t)
          , attempt (Timeline.finish t ExternalWait)
          ]
      Timeline.finish t Quiescent
      (errors,) <$> World.artifact "fair-phase-v3"
    Array errors `shouldBeJson` member "errors" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh queueProfile [] artifact >>= (`shouldBeJson` member "replay" s)

  it "validates a fault through the profile when it is activated" $ do
    s <- story "fault-validation"
    q <- newQueue
    (refused, kinds) <- withToy (config (queueProfile q) (budget 2 2 1 5 0 1) [] Nothing) $ do
      t <- World.timeline
      refused <- attempt (Timeline.activateFault t (Timeline.fault "unsupported" "cut"))
      (refused,) . map operationKind <$> World.operations
    refused `shouldBeJson` member "error" s
    Array (map String kinds) `shouldBeJson` member "kinds" s

  it "ends action, timer, and logical-time budgets explicitly" $ do
    s <- story "action-timer-logical"
    q <- newQueue
    (action, artifact) <- withToy (config (queueProfile q) (budget 1 2 1 5 0 1) [] Nothing) $ do
      _ <- World.step
      action <- attempt World.step
      (action,) <$> World.artifact "budget-exhaustion"
    action `shouldBeJson` member "action" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh queueProfile [] artifact >>= (`shouldBeJson` member "replay" s)
    q2 <- newQueue
    timer <- withToy (config (queueProfile q2) (budget 1 2 0 5 0 1) [] Nothing) (attempt World.step)
    timer `shouldBeJson` member "timer" s
    q3 <- newQueue
    logical <- startWorld (config (queueProfile q3) (budget 1 2 1 4 0 1) [] Nothing)
    logical `shouldFailWith` member "logical" s
    closes <- queueCloses q3
    Int (toInteger closes) `shouldBeJson` member "logical_closes" s

  it "ends queue, reload, and artifact-byte budgets explicitly" $ do
    s <- story "queue-reload-bytes"
    q <- newQueue
    queued <- startWorld (config (queueProfile q) (budget 1 1 1 5 0 1) [] Nothing)
    queued `shouldFailWith` member "queued" s
    closes <- queueCloses q
    Int (toInteger closes) `shouldBeJson` member "queued_closes" s
    q2 <- newQueue
    reloads <- withToy (config (queueProfile q2) (budget 2 2 1 5 0 1) [] Nothing) $ do
      t <- World.timeline
      Timeline.crash t "cut"
      attempt World.restart
    reloads `shouldBeJson` member "reloads" s
    value <- readJson (fixturesDir <> "/projection-crash-recovery-world-v1.json")
    let shrunk = case value of
          Object members -> Object [(k, if k == "budget" then setBytes v else v) | (k, v) <- members]
          other -> other
        setBytes = \case
          Object members -> Object [(k, if k == "artifact_bytes" then Int 1 else v) | (k, v) <- members]
          other -> other
    case artifactFromJson shrunk of
      Left e -> expectationFailure (show e)
      Right artifact -> case encodeArtifact artifact of
        Left message -> Object [("message", String message), ("type", String "ValueError")] `shouldBeJson` member "artifact_bytes" s
        Right _ -> expectationFailure "the shrunk artifact encoded"

  it "replays an authored command's checker failure through its submit attempt" $ do
    s <- story "authored-checker-failure"
    q <- newQueue
    (refused, artifact) <- withToy (config (queueProfile q) (budget 4 2 1 5 0 1) [rejectBadValueChecker] Nothing) $ do
      t <- World.timeline
      _ <- World.step
      _ <- World.step
      refused <- attempt (Timeline.command t "queue.record" (Object [("id", String "bad")]))
      (refused,) <$> World.artifact "authored-checker-failure"
    refused `shouldBeJson` member "error" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh queueProfile [rejectBadValueChecker] artifact >>= (`shouldBeJson` member "replay" s)
    -- An accepted failed attempt is never applied twice.
    replayQueue <- newQueue
    passing <- queueReplay replayQueue [passingBadValueChecker] artifact
    passing `shouldBeJson` member "passing_replay" s
    values <- queueValues replayQueue
    Array (map String values) `shouldBeJson` member "passing_values" s

  it "does not reclassify profile and checker exceptions as World failures" $ do
    s <- story "not-reclassified"
    let state = do
          ending <- World.disposition
          kinds <- map operationKind <$> World.operations
          entries <- World.journal
          pure (Array [dispositionJson ending, Array (map String kinds), Array [String (journalKindText e.kind) | e <- entries]])
    q <- newQueue
    (profileRaised, profileState) <- withToy (config (raisingReservedExceptionProfile q) (budget 4 2 1 5 0 1) [] Nothing) $
      (,) <$> attempt World.step <*> state
    profileRaised `shouldBeJson` member "profile_error" s
    profileState `shouldBeJson` member "profile_state" s
    q2 <- newQueue
    (checkerError, checkerState) <-
      withToy (config (queueProfile q2) (budget 4 2 1 5 0 1) [raisingReservedExceptionChecker] Nothing) $
        (,) <$> attempt World.step <*> state
    checkerError `shouldBeJson` member "checker_error" s
    checkerState `shouldBeJson` member "checker_state" s

  it "refuses choices in an unseeded World" $ do
    s <- story "no-choices"
    q <- newQueue
    refused <- withToy (config (queueProfile q) (budget 2 2 1 5 0 1) [] Nothing) (attempt (World.chooseIndex WorkloadChoice 2))
    refused `shouldBeJson` member "error" s

  it "authors a seeded version-3 story with a crash, a stale timeline, and a reload" $ do
    s <- story "seeded-v3"
    q <- newQueue
    (index, identifier, applied, stale, generation, observation, artifact) <-
      withToy (config (queueProfile q) (budget 8 3 1 5 1 2) [] (Just 1729)) $ do
        t <- World.timeline
        index <- World.chooseIndex WorkloadChoice 10
        identifier <- World.chooseIdentifier "queue"
        applied <- Timeline.command t "queue.record" (Object [("id", String identifier), ("n", Int index)])
        _ <- World.step
        _ <- World.step
        Timeline.crash t "cut"
        stale <- attempt (Timeline.command t "queue.record" (Object [("id", String "stale")]))
        generation <- World.restart
        t2 <- World.timeline
        observation <- Timeline.observe t2 "queue.state"
        Timeline.finish t2 Quiescent
        artifact <- World.artifact "seeded-queue-v3"
        pure (index, identifier, applied, stale, generation, observation, artifact)
    Int index `shouldBeJson` member "index" s
    String identifier `shouldBeJson` member "identifier" s
    toJson applied `shouldBeJson` member "applied" s
    stale `shouldBeJson` member "stale" s
    Int generation `shouldBeJson` member "generation" s
    toJson observation `shouldBeJson` member "observation" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh queueProfile [] artifact >>= (`shouldBeJson` member "replay" s)

  it "authors a seeded version-4 story through run_until" $ do
    s <- story "seeded-v4"
    q <- newQueue
    (observation, artifact) <- withToy (config (resourceQueueProfile q) (budgetV4 (budget 8 2 1 5 0 4) 3) [] (Just 7)) $ do
      t <- World.timeline
      order <- World.chooseIndex EventOrderChoice 3
      faultPick <- World.chooseIndex FaultChoice 5
      observation <-
        Timeline.runUntilWith t "queue.state" (Object [("order", Int order), ("fault", Int faultPick)]) $ \o ->
          case o.value of
            Object [("values", Array vs)] -> length vs == 2
            _ -> False
      Timeline.finish t Converged
      (observation,) <$> World.artifact "seeded-queue-v4"
    toJson observation `shouldBeJson` member "observation" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh resourceQueueProfile [] artifact >>= (`shouldBeJson` member "replay" s)

  it "reports run_until's external wait with checkpoint diagnostics" $ do
    s <- story "run-until-failed"
    q <- newQueue
    (refused, ending, artifact) <- withToy (config (queueProfile q) (budget 8 2 1 5 0 4) [] Nothing) $ do
      t <- World.timeline
      refused <- attempt (Timeline.runUntil t "queue.state" (const False))
      ending <- World.disposition
      Timeline.finish t ExternalWait
      (refused,dispositionJson ending,) <$> World.artifact "run-until-external-wait"
    refused `shouldBeJson` member "error" s
    ending `shouldBeJson` member "disposition" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh queueProfile [] artifact >>= (`shouldBeJson` member "replay" s)

  it "ends the predicate-poll budget explicitly" $ do
    s <- story "poll-budget"
    q <- newQueue
    (refused, ending, artifact) <- withToy (config (queueProfile q) (budget 8 2 1 5 0 1) [] Nothing) $ do
      t <- World.timeline
      refused <- attempt (Timeline.runUntil t "queue.state" (const False))
      ending <- World.disposition
      (refused,dispositionJson ending,) <$> World.artifact "poll-budget-exhaustion"
    refused `shouldBeJson` member "error" s
    ending `shouldBeJson` member "disposition" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh queueProfile [] artifact >>= (`shouldBeJson` member "replay" s)

  it "activates, matches, and consumes faults through the scenario context" $ do
    s <- story "fault-story"
    q <- newQueue
    (wrong, steps, observation, artifact) <- withToy (config (faultQueueProfile q) (budget 8 3 2 6 0 1) [] Nothing) $ do
      t <- World.timeline
      Timeline.activateFault
        t
        Timeline.FaultSpec {name = "refuse-second", target = "queue.apply", occurrence = 2, disposition = Refuse, payload = Null}
      Timeline.activateFault
        t
        Timeline.FaultSpec
          {name = "duplicate-first", target = "queue.apply", occurrence = 1, disposition = Duplicate, payload = Object [("n", Int 1)]}
      wrong <- attempt (Timeline.activateFault t (Timeline.fault "elsewhere" "queue.other"))
      steps <- sequence [World.step, World.step, World.step]
      observation <- Timeline.observe t "queue.state"
      Timeline.finish t Quiescent
      artifact <- World.artifact "fault-queue-v3"
      pure (wrong, steps, observation, artifact)
    wrong `shouldBeJson` member "wrong" s
    Array (map (toJson . OpExecute) steps) `shouldBeJson` member "steps" s
    toJson observation `shouldBeJson` member "observation" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh faultQueueProfile [] artifact >>= (`shouldBeJson` member "replay" s)

  it "refuses misuse with the reference's exceptions" $ do
    s <- story "refusals"
    q <- newQueue
    (unknown, invalid, early, restartLive, late, twice, artifact) <-
      withToy (config (queueProfile q) (budget 4 2 1 5 0 1) [] Nothing) $ do
        t <- World.timeline
        unknown <- attempt (Timeline.observe t "nope")
        invalid <- attempt (Timeline.command t "other" (Object []))
        early <- attempt (World.artifact "too-early")
        restartLive <- attempt World.restart
        _ <- World.step
        _ <- World.step
        Timeline.finish t Quiescent
        late <- attempt (Timeline.command t "queue.record" (Object [("id", String "late")]))
        twice <- attempt (Timeline.finish t Quiescent)
        artifact <- World.artifact "refusals-v3"
        pure (unknown, invalid, early, restartLive, late, twice, artifact)
    unknown `shouldBeJson` member "unknown" s
    invalid `shouldBeJson` member "invalid" s
    early `shouldBeJson` member "early" s
    restartLive `shouldBeJson` member "restart_live" s
    late `shouldBeJson` member "late" s
    twice `shouldBeJson` member "twice" s
    artifactText artifact `shouldBe` memberText "artifact" s
    fresh queueProfile [] artifact >>= (`shouldBeJson` member "replay" s)
    (replayJson <$> replay (registryOf [] []) artifact) >>= (`shouldBeJson` member "missing_profile" s)
    q2 <- newQueue
    let registry = registryOf [SomeProfile (queueProfile q2)] [rejectingChecker]
    pyErrorOf (registerProfile (queueProfile q2) registry) `shouldBeJson` member "duplicate_profile" s
    pyErrorOf (registerChecker rejectingChecker registry) `shouldBeJson` member "duplicate_checker" s
    duplicated <- startWorld (config (queueProfile q2) (budget 4 2 1 5 0 1) [rejectingChecker, rejectingChecker] Nothing)
    duplicated `shouldFailWith` member "duplicate_world_checkers" s

  it "keeps the scenario context out of a profile's reach after the door returns" $ do
    -- The reference refuses re-entrant World calls from inside a profile
    -- door at run time; here a door cannot reach the World at all, because
    -- 'Scenario' exposes only the context services.
    q <- newQueue
    observed <- withToy (config (queueProfile q) (budget 4 2 1 5 0 1) [] Nothing) $ do
      _ <- World.step
      liftIO (queueValues q)
    observed `shouldBe` ["queue-00000001"]
