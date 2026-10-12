{-# LANGUAGE OverloadedRecordDot #-}

-- | @tests/dst/test_generated_runtime_qualification.py@: fair-liveness,
-- shrinking, and semantic-coverage qualification (CV19.DS3).
module Spec.Qualification (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.List (nub)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..), parseJson, surrogateRefusingLoads)
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.GeneratedRuntime
  ( GeneratedRuntimeProfile (..)
  , RuntimeVariant (..)
  , StoryOptions (..)
  , buildGeneratedRuntimeArtifactWith
  , defaultStoryOptions
  , generatedRuntimeChecker
  , generatedRuntimeProfile
  , generatedRuntimeProfileWith
  , scopeName
  , worldBudget
  )
import Petrus.Testing.Dst.Engine.GeneratedRuntime qualified as GeneratedRuntime
import Petrus.Testing.Dst.Engine.GeneratedRuntimeQualification
import Petrus.Testing.Dst.Failure (findLivelockMinimum)
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World
import Spec.Support (config, fixturesDir, member, memberList, readJson, registryOf)
import Spec.Tooling (runWorldCommand)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

minimizedFixture, coverageFixture :: FilePath
minimizedFixture = fixturesDir </> "generated-runtime-minimized-fair-regression-v4.json"
coverageFixture = fixturesDir </> "generated-runtime-semantic-coverage-v1.json"

built :: IO (Either DstFailure AnyArtifact) -> IO AnyArtifact
built action = action >>= either (\f -> fail (T.unpack (failureClass f <> ": " <> failureMessage f))) pure

replayedJson :: Registry IO -> AnyArtifact -> IO Json
replayedJson registry artifact = replay registry artifact >>= either (\f -> fail (T.unpack (failureMessage f))) (pure . toJson)

expected :: Text -> AnyArtifact -> Json
expected key artifact = member key (member "expected" (toJson artifact))

operations :: AnyArtifact -> [Json]
operations = memberList "operations" . toJson

fairPosition :: AnyArtifact -> Json
fairPosition artifact = case [member "position" o | o <- operations artifact, member "kind" o == String "begin_fair"] of
  p : _ -> p
  [] -> Null

passedChecks :: AnyArtifact -> Bool
passedChecks artifact =
  and [member "passed" (member "result" (member "value" entry)) == Bool True | entry <- memberListOf (expected "checks" artifact)]

memberListOf :: Json -> [Json]
memberListOf = \case
  Array xs -> xs
  _ -> []

runtimeRegistry :: RuntimeVariant -> FilePath -> String -> Bool -> IO (Registry IO)
runtimeRegistry variant dir prefix withChecker = do
  p <- generatedRuntimeProfileWith variant (dir </> prefix <> "-history.jsonl") (dir </> prefix <> "-dispatch.db")
  pure (registryOf [SomeProfile p.profile] [generatedRuntimeChecker | withChecker])

spec :: Spec
spec = describe "test_generated_runtime_qualification.py (fair liveness, shrinking, semantic coverage)" $ do
  it "test_fair_phase_converges_and_minimized_regression_replays_exactly" $
    withSystemTempDirectory "petrus-dst-qualification-" $ \dir -> do
      checked <- built (buildMinimizedFairRegressionArtifact (dir </> "author-history.jsonl") (dir </> "author-dispatch.db") True)
      artifact <- built (buildMinimizedFairRegressionArtifact (dir </> "fixture-history.jsonl") (dir </> "fixture-dispatch.db") False)
      let value = toJson artifact
      member "scenario_id" value `shouldBe` String minimizedScenarioId
      expected "disposition" artifact `shouldBe` String "quiescent"
      member "seed" (member "origin" value) `shouldBe` Int discoverySeed
      member "draws" (member "origin" value) `shouldBe` Object [("identifier:shrink-event", Int 1)]
      any ((== String "begin_fair") . member "kind") (operations artifact) `shouldBe` True
      operations checked `shouldBe` operations artifact
      memberListOf (expected "checks" checked) `shouldNotBe` []
      passedChecks checked `shouldBe` True
      let finalState = member "value" (member "observation" (member "value" (last (memberListOf (expected "checks" checked)))))
          completedTransitions = Set.fromList [t | e <- memberList "firing_completed" finalState, String t <- [member "transition" e]]
      member "status" finalState `shouldBe` String "awaiting"
      member "live_in_flight" finalState `shouldBe` Array []
      Set.fromList ["work", "release" :: Text] `Set.isSubsetOf` completedTransitions `shouldBe` True
      fixtureBytes <- BS.readFile minimizedFixture
      encodeArtifact artifact `shouldBe` Right (BC.dropWhileEnd (== '\n') fixtureBytes)

      registry <- runtimeRegistry Unmutated dir "replay" False
      result <- replayedJson registry artifact
      member "outcome" result `shouldBe` String "pass"
      member "disposition" result `shouldBe` String "quiescent"
      member "journal_digest" result `shouldBe` expected "journal_digest" artifact

      (code, out, err) <- runWorldCommand ["replay", minimizedFixture]
      code `shouldBe` ExitSuccess
      err `shouldBe` ""
      manual <- either fail pure (parseJson surrogateRefusingLoads out)
      member "scenario_id" manual `shouldBe` String minimizedScenarioId
      member "outcome" manual `shouldBe` String "pass"
      member "disposition" manual `shouldBe` String "quiescent"

  it "test_external_wait_and_inadequate_fair_declaration_remain_distinct" $
    withSystemTempDirectory "petrus-dst-qualification-" $ \dir -> do
      waiting <- generatedRuntimeProfile (dir </> "wait-history.jsonl") (dir </> "wait-dispatch.db")
      external <- World.withWorld (config waiting.profile worldBudget [] Nothing) $ do
        t <- World.timeline
        _ <- Timeline.command t "scope.open" (Object [("name", String scopeName)])
        World.tryWorld (Timeline.runUntil t "generated-runtime-state" (const False))
      case external of
        Right (Left (RunUntilFailed r)) -> do
          r.disposition `shouldBe` DExternalWait
          r.pending `shouldBe` []
        other -> expectationFailure ("expected RunUntilFailed, got " <> show (fmap (const ()) <$> other))

      inadequate <- generatedRuntimeProfile (dir </> "fair-history.jsonl") (dir </> "fair-dispatch.db")
      outcome <- World.withWorld (config inadequate.profile worldBudget [] Nothing) $ do
        t <- World.timeline
        _ <- Timeline.command t "scope.open" (Object [("name", String scopeName)])
        Timeline.beginFair t
        stalled <- World.tryWorld (Timeline.runUntil t "generated-runtime-state" (const False))
        finished <- World.tryWorld (Timeline.finish t ExternalWait)
        pure (stalled, finished)
      case outcome of
        Right (Left (RunUntilFailed r), Left refusal) -> do
          r.disposition `shouldBe` DExternalWait
          r.pending `shouldBe` []
          failureClass refusal `shouldBe` "DstError"
          ("active DST fair phase" `T.isInfixOf` failureMessage refusal) `shouldBe` True
        _ -> expectationFailure "expected a stalled fair phase and a refused external-wait finish"

  it "test_fair_budget_exhaustion_is_exact_without_becoming_livelock" $
    withSystemTempDirectory "petrus-dst-qualification-" $ \dir -> do
      p <- generatedRuntimeProfile (dir </> "author-history.jsonl") (dir </> "author-dispatch.db")
      outcome <- World.withWorld (config p.profile (withActions 9 fairBudget) [generatedRuntimeChecker] Nothing) $ do
        establishFairSpine "bounded-fair-event" 0 False []
        exhausted <- World.tryWorld World.step
        artifact <- World.artifact "generated-runtime-fair-budget-exhaustion-v4"
        pure (exhausted, artifact)
      (exhausted, artifact) <- either (fail . T.unpack . failureMessage) pure outcome
      case exhausted of
        Left (BudgetExhausted bound _) -> bound `shouldBe` "actions"
        _ -> expectationFailure "expected the fair phase to exhaust its action budget"
      let ops = operations artifact
          failureOp = last ops
      member "kind" failureOp `shouldBe` String "failure"
      member "kind" (member "failure" failureOp) `shouldBe` String "budget_exhausted"
      member "bound" (member "failure" failureOp) `shouldBe` String "actions"
      member "accepted_operations" failureOp `shouldBe` Int 0
      member "kind" (last (init ops)) `shouldBe` String "begin_fair"

      registry <- runtimeRegistry Unmutated dir "replay" True
      result <- replayedJson registry artifact
      member "disposition" result `shouldBe` String "budget_exhausted"
      member "failure" result `shouldBe` expected "failure" artifact

  it "test_hypothesis_shrinks_safety_preserving_livelock_and_failure_replays" $
    withSystemTempDirectory "petrus-dst-qualification-" $ \dir -> do
      unreduced <- built (buildLivelockFailureArtifact (dir </> "unreduced") True ["observe", "crash_reload", "observe"])
      minimized <- findLivelockMinimum dir "search"
      minimized `shouldBe` (False, [])
      artifact <- built (buildLivelockFailureArtifact (dir </> "minimized") (fst minimized) (snd minimized))
      case (fairPosition artifact, fairPosition unreduced) of
        (Int m, Int u) -> m `shouldSatisfy` (< u)
        other -> expectationFailure ("no fair-phase positions: " <> show other)
      (BS.length <$> encodeArtifact artifact) `shouldSatisfy` (\a -> a < (BS.length <$> encodeArtifact unreduced))
      expected "disposition" artifact `shouldBe` String "budget_exhausted"
      expected "failure" artifact `shouldNotBe` Null
      passedChecks artifact `shouldBe` True

      let drives =
            [ o
            | o <- operations artifact
            , member "kind" o == String "execute"
            , member "name" (member "command" o) == String "engine.drive"
            ]
          stalled = drop (length drives - 3) drives
      length stalled `shouldBe` 3
      length (nub [member "instant" o | o <- stalled]) `shouldBe` 1
      length (nub [member "frontier" (member "value" (member "result" o)) | o <- stalled]) `shouldBe` 1

      registry <- runtimeRegistry LivelockMutation dir "mutation-replay" True
      result <- replayedJson registry artifact
      member "outcome" result `shouldBe` String "pass"
      member "disposition" result `shouldBe` String "budget_exhausted"
      member "failure" result `shouldBe` expected "failure" artifact
      member "journal_digest" result `shouldBe` expected "journal_digest" artifact

  it "test_semantic_coverage_reports_broad_only_and_excluded_dimensions" $
    withSystemTempDirectory "petrus-dst-qualification-" $ \dir -> do
      focused <-
        built
          ( buildGeneratedRuntimeArtifactWith
              defaultStoryOptions {firstValue = -3, secondValue = 0}
              (dir </> "focused-history.jsonl")
              (dir </> "focused-dispatch.db")
          )
      broad <- built (buildBroadOnlyArtifact (dir </> "broad-history.jsonl") (dir </> "broad-dispatch.db"))
      let report = semanticCoverageReport focused broad
      member "scenario_id" (toJson focused) `shouldBe` String GeneratedRuntime.scenarioId
      member "scenario_id" (toJson broad) `shouldBe` String broadOnlyScenarioId
      reference <- readJson coverageFixture
      report `shouldBe` reference
      member "broad_only" report `shouldBe` Array [String "retry-then-reset-before-terminal"]
      member "boundaries" (member "reached" report)
        `shouldBe` Array
          ( map
              String
              [ "action:applied"
              , "action:idempotent"
              , "action:refused_expected"
              , "logical-time:deadline"
              , "source-value:negative"
              , "source-value:positive"
              , "source-value:zero"
              , "worker-epoch:1"
              , "worker-epoch:2"
              ]
          )
      length (memberList "unreachable" report) `shouldBe` 3
      length (memberList "intentionally_ungenerated" report) `shouldBe` 4

      registry <- runtimeRegistry Unmutated dir "broad-replay" True
      result <- replayedJson registry broad
      member "outcome" result `shouldBe` String "pass"
      member "disposition" result `shouldBe` String "external_wait"
