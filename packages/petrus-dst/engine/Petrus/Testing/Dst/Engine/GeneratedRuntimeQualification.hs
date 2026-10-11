{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Fair-liveness, shrinking, and semantic-coverage support for the
-- generated-runtime world: a port of the reference's
-- @tests/dst/generated_runtime_qualification.py@.
--
-- The reference's @LivelockMutationProfile@ is
-- 'Petrus.Testing.Dst.Engine.GeneratedRuntime.LivelockMutation', a variant
-- of the generated-runtime profile with its own identity.
module Petrus.Testing.Dst.Engine.GeneratedRuntimeQualification
  ( minimizedScenarioId
  , broadOnlyScenarioId
  , mutationScenarioId
  , discoverySeed
  , fairBudget
  , withActions
  , establishFairSpine
  , buildLivelockFailureArtifact
  , buildMinimizedFairRegressionArtifact
  , buildBroadOnlyArtifact
  , semanticCategories
  , semanticLabels
  , semanticCoverageReport
  ) where

import Control.Monad (when)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Common (ensure, listOf, member)
import Petrus.Testing.Dst.Engine.GeneratedRuntime
  ( GeneratedRuntimeProfile (..)
  , RuntimeGeneration
  , RuntimeVariant (..)
  , checkerIdentity
  , drainAll
  , generatedRuntimeChecker
  , generatedRuntimeProfileWith
  , maturationInstant
  , profileIdentity
  , scopeName
  , worldBudget
  )
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

minimizedScenarioId, broadOnlyScenarioId, mutationScenarioId :: Text
minimizedScenarioId = "generated-runtime-minimized-fair-regression-v4"
broadOnlyScenarioId = "generated-runtime-broad-retry-reset-v4"
mutationScenarioId = "generated-runtime-minimized-livelock-mutation-v4"

-- | @DISCOVERY_SEED@.
discoverySeed :: Integer
discoverySeed = 19003

-- | @FAIR_BUDGET@: the world budget with 28 actions and 1 MiB artifacts.
fairBudget :: SomeBudget
fairBudget = case withActions 28 worldBudget of
  SomeBudgetV4 b -> SomeBudgetV4 b {limits = b.limits {artifactBytes = 1048576}}
  other -> other

-- | @budget.model_copy(update={"actions": n})@.
withActions :: Integer -> SomeBudget -> SomeBudget
withActions n = \case
  SomeBudget b -> SomeBudget b {actions = n}
  SomeBudgetV4 b -> SomeBudgetV4 b {limits = b.limits {actions = n}}

requested :: Observation -> Int
requested o = length (listOf "requested_invocations" o.value)

-- | @establish_fair_spine@: reach a fault-free fair phase with only
-- profile-owned work retained.
establishFairSpine :: Text -> Integer -> Bool -> [Text] -> WorldT IO RuntimeGeneration ()
establishFairSpine identity value retry perturbations = do
  timeline <- World.timeline
  _ <- Timeline.command timeline "scope.open" (Object [("name", String scopeName)])
  _ <- Timeline.command timeline "source.deliver" (Object [("identity", String identity), ("value", Int value)])
  _ <- Timeline.runUntil timeline "generated-runtime-state" (\o -> requested o == 1)
  let perturb t = \case
        "observe" -> Timeline.observe t "generated-runtime-state" >> pure t
        "crash_reload" -> do
          Timeline.crash t "generated_fair_spine_cut"
          _ <- World.restart
          t' <- World.timeline
          drainCurrent
          pure t'
        other -> World.throwWorld (ContractViolation "ValueError" ("unknown fair-spine perturbation " <> pythonStrRepr other))
  timeline' <- foldlM' perturb timeline perturbations
  _ <- Timeline.command timeline' "worker.claim" (Object [])
  when retry $ do
    _ <- Timeline.command timeline' "worker.fail" (Object [("attempt", Int 1), ("error", String "generated fair retry")])
    _ <- Timeline.command timeline' "worker.claim" (Object [])
    pure ()
  _ <- Timeline.command timeline' "worker.complete" (Object [("result", Object [("value", Int value)])])
  _ <- Timeline.command timeline' "engine.drive" (Object [])
  Timeline.beginFair timeline'
  where
    foldlM' f z = \case
      [] -> pure z
      x : xs -> f z x >>= \z' -> foldlM' f z' xs
    -- @while world.pending() and world.pending()[0]["instant"] == world.instant@
    drainCurrent = do
      queued <- World.pending
      current <- World.currentInstant
      case queued of
        q : _ | member "instant" q == Int current -> World.step >> drainCurrent
        _ -> pure ()

-- | @build_livelock_failure_artifact@: one exact safety-green,
-- fair-liveness-failing mutation artifact.
buildLivelockFailureArtifact :: FilePath -> Bool -> [Text] -> IO (Either DstFailure AnyArtifact)
buildLivelockFailureArtifact root retry perturbations = do
  createDirectoryIfMissing True root
  p <- generatedRuntimeProfileWith LivelockMutation (root </> "history.jsonl") (root </> "dispatch.db")
  World.withWorld
    WorldConfig
      { profile = p.profile
      , budget = fairBudget
      , checkers = [generatedRuntimeChecker]
      , seed = Just discoverySeed
      , progress = Nothing
      }
    $ do
      establishFairSpine "shrinking-livelock-event" 0 retry perturbations
      outcome <- World.tryWorld drainAll
      case outcome of
        Left BudgetExhausted {} -> pure ()
        Left failure -> World.throwWorld failure
        Right () -> World.throwWorld (ContractViolation "AssertionError" "livelock mutation unexpectedly converged within its action budget")
      World.artifact mutationScenarioId

-- | @build_minimized_fair_regression_artifact@: the mutation's minimized
-- schedule through the unmutated profile.
buildMinimizedFairRegressionArtifact :: FilePath -> FilePath -> Bool -> IO (Either DstFailure AnyArtifact)
buildMinimizedFairRegressionArtifact historyPath dispatchPath withChecker = do
  p <- generatedRuntimeProfileWith Unmutated historyPath dispatchPath
  World.withWorld
    WorldConfig
      { profile = p.profile
      , budget = fairBudget
      , checkers = [generatedRuntimeChecker | withChecker]
      , seed = Just discoverySeed
      , progress = Nothing
      }
    $ do
      identity <- World.chooseIdentifier "shrink-event"
      timeline <- World.timeline
      _ <- Timeline.command timeline "scope.open" (Object [("name", String scopeName)])
      _ <- Timeline.command timeline "source.deliver" (Object [("identity", String identity), ("value", Int 0)])
      _ <- World.step
      _ <- Timeline.command timeline "worker.claim" (Object [])
      _ <- Timeline.command timeline "worker.complete" (Object [("result", Object [("value", Int 0)])])
      _ <- Timeline.command timeline "engine.drive" (Object [])
      Timeline.beginFair timeline
      drainAll
      Timeline.finish timeline Quiescent
      World.artifact minimizedScenarioId

-- | @build_broad_only_artifact@: the broad-only retry plus lifecycle-reset
-- terminal combination.
buildBroadOnlyArtifact :: FilePath -> FilePath -> IO (Either DstFailure AnyArtifact)
buildBroadOnlyArtifact historyPath dispatchPath = do
  p <- generatedRuntimeProfileWith Unmutated historyPath dispatchPath
  World.withWorld
    WorldConfig {profile = p.profile, budget = worldBudget, checkers = [generatedRuntimeChecker], seed = Nothing, progress = Nothing}
    $ do
      timeline <- World.timeline
      let scope = Object [("name", String scopeName)]
      _ <- Timeline.command timeline "scope.open" scope
      _ <- Timeline.command timeline "source.deliver" (Object [("identity", String "broad-only-event"), ("value", Int 3)])
      _ <- Timeline.runUntil timeline "generated-runtime-state" (\o -> requested o == 1)
      _ <- Timeline.command timeline "worker.claim" (Object [])
      _ <- Timeline.command timeline "worker.fail" (Object [("attempt", Int 1), ("error", String "broad-only retry")])
      retried <- Timeline.command timeline "worker.claim" (Object [])
      let occurrence = member "occurrence" (member "attempt" retried.value)
      _ <- Timeline.command timeline "scope.reset" scope
      _ <- Timeline.command timeline "worker.complete" (Object [("result", Object [("value", Int 3)])])
      _ <- Timeline.command timeline "engine.drive" (Object [])
      observed <- Timeline.observe timeline "generated-runtime-state"
      ensure (occurrence `elem` listOf "quarantined_occurrences" observed.value) "broad-only occurrence quarantined"
      drainAll
      Timeline.finish timeline ExternalWait
      World.artifact broadOnlyScenarioId

-- ---------------------------------------------------------------------------
-- Semantic coverage

-- | The categories of 'semanticLabels', in the reference's order.
semanticCategories :: [Text]
semanticCategories =
  [ "events"
  , "faults"
  , "boundaries"
  , "lifecycle"
  , "terminals"
  , "crash_cuts"
  , "recoveries"
  , "checker_activations"
  , "combinations"
  ]

data Walk = Walk
  { labels :: Map Text (Set Text)
  , retried :: [Json]
  , claimed :: Maybe Json
  , resetAfterClaim :: Bool
  , previousCrash :: Maybe Text
  }

-- | @semantic_labels@: semantic reach from normalized operations and
-- checker results.
semanticLabels :: AnyArtifact -> Map Text (Set Text)
semanticLabels artifact = checked.labels
  where
    value = toJson artifact
    start = Walk {labels = Map.fromList [(c, Set.empty) | c <- semanticCategories], retried = [], claimed = Nothing, resetAfterClaim = False, previousCrash = Nothing}
    walked = foldl' visit start (listOf "operations" value)
    checked = foldl' visitCheck walked (listOf "checks" (member "expected" value))
    add category label w = w {labels = Map.adjust (Set.insert label) category w.labels}
    text = \case
      String t -> t
      _ -> ""
    visit w operation = case text (member "kind" operation) of
      "activate_fault" ->
        let f = member "fault" operation
         in add "faults" (text (member "name" f) <> "@" <> text (member "target" f)) w
      "crash" ->
        let cut = text (member "cut" operation)
         in (add "crash_cuts" cut . add "lifecycle" "abrupt-crash" $ w) {previousCrash = Just cut}
      "restart" ->
        let w' = add "lifecycle" "fresh-load" w
         in case w.previousCrash of
              Just cut -> (add "recoveries" (cut <> "->fresh-load") w') {previousCrash = Nothing}
              Nothing -> w'
      "begin_fair" -> add "lifecycle" "fair-phase" w
      "finish" -> add "terminals" (text (member "disposition" operation)) w
      "execute" -> execute w operation
      _ -> w
    execute w0 operation =
      let name = text (member "name" (member "command" operation))
          result = member "result" operation
          w1 = add "boundaries" ("action:" <> text (member "disposition" result)) (add "events" name w0)
          w2 = if member "instant" operation == Int maturationInstant then add "boundaries" "logical-time:deadline" w1 else w1
       in case name of
            "scope.open" -> add "lifecycle" "scope-open" w2
            "scope.reset" -> (add "lifecycle" "scope-reset" w2) {resetAfterClaim = maybe False (const True) w2.claimed}
            "source.deliver" ->
              let sign = case member "value" (member "payload" (member "command" operation)) of
                    Int n | n < 0 -> "source-value:negative"
                    Int n | n > 0 -> "source-value:positive"
                    _ -> "source-value:zero"
               in add "boundaries" sign w2
            "worker.claim" ->
              let attempt = member "attempt" (member "value" result)
                  epoch = case member "epoch" attempt of
                    Int n -> n
                    _ -> 0
                  w3 = (add "boundaries" ("worker-epoch:" <> tshow epoch) w2) {claimed = Just (member "occurrence" attempt)}
               in if epoch > 1 then add "terminals" "retry-claimed" w3 else w3
            "worker.fail" -> case w2.claimed of
              Just occurrence -> (add "terminals" "retryable-failure" w2) {retried = occurrence : w2.retried}
              Nothing -> w2
            "worker.complete" ->
              let occurrence = member "occurrence" (member "report" (member "value" result))
                  w3 = add "terminals" "provider-completed" w2
                  w4 =
                    if occurrence `elem` w3.retried && w3.resetAfterClaim
                      then add "combinations" "retry-then-reset-before-terminal" w3
                      else w3
               in w4 {claimed = Nothing, resetAfterClaim = False}
            _ -> w2
    visitCheck w entry =
      let entryValue = member "value" entry
          state = member "value" (member "observation" entryValue)
          nonEmpty key = not (null (listOf key state))
          w1 = add "checker_activations" (text (member "trigger" entryValue)) w
          w2 = if nonEmpty "completed_occurrences" then add "terminals" "semantic-projection-completed" w1 else w1
          w3 = if nonEmpty "quarantined_occurrences" then add "terminals" "late-terminal-quarantined" w2 else w2
       in if nonEmpty "timer_maturations" then add "terminals" "timer-matured" w3 else w3

-- | @semantic_coverage_report(focused, broad)@: the retained semantic
-- coverage report, in the reference's key order.
semanticCoverageReport :: AnyArtifact -> AnyArtifact -> Json
semanticCoverageReport focused broad =
  Object
    [ ("format", String "petrus-dst-semantic-coverage")
    , ("version", Int 1)
    , ("profile", toJson profileIdentity)
    , ("checker", toJson checkerIdentity)
    , ("scenarios", Array [String (artifactScenarioId focused), String (artifactScenarioId broad)])
    ,
      ( "reached"
      , Object
          [ (category, Array (map String (Set.toAscList (Set.union (labelsOf focusedLabels category) (labelsOf broadLabels category)))))
          | category <- semanticCategories
          , category /= "combinations"
          ]
      )
    , ("broad_only", Array (map String (Set.toAscList (Set.difference (labelsOf broadLabels "combinations") (labelsOf focusedLabels "combinations")))))
    ,
      ( "unreachable"
      , Array
          [ reason "authored-external-wait-after-fair-begin" "World rejects this disposition after the fair declaration"
          , reason "stale-generation-authored-command" "generation revocation rejects the old Timeline before profile application"
          , reason "worker-attempt-epoch-three" "the profile's two-attempt policy and closed command schema refuse a third epoch"
          ]
      )
    ,
      ( "intentionally_ungenerated"
      , Array
          [ owner "conflicting-identified-redelivery" "retained DS2 identified-ingress profile"
          , owner "permanent-fault-during-fair-phase" "excluded by the CV19 fair-environment precondition"
          , owner "postgresql-absurd-transaction-boundaries" "CV19.DS4 production-boundary qualification"
          , owner "application-human-or-provider-prerequisite" "application scenario profile, not Petrus's generic profile"
          ]
      )
    ]
  where
    focusedLabels = semanticLabels focused
    broadLabels = semanticLabels broad
    labelsOf ls category = Map.findWithDefault Set.empty category ls
    reason dimension r = Object [("dimension", String dimension), ("reason", String r)]
    owner dimension o = Object [("dimension", String dimension), ("owner", String o)]

tshow :: (Show a) => a -> Text
tshow = T.pack . show
