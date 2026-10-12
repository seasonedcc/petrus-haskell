-- | @tests/integration/testing/test_readiness_coverage.py@: semantic
-- coverage accounting over readiness World artifacts.
module ReadinessCoverageSpec (spec) where

import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Testing.World hiding (PullRequest (..))
import Hamsterdan.Testing.World.Contract (PythonException, classAndStr, defaultBudget)
import Hamsterdan.Testing.World.Coverage
import Hamsterdan.Testing.World.Scenarios (cleanGreen, drain)
import Petrus.Json (Json (..), defaultDumps, dumps)
import Petrus.Testing.Dst
  ( AnyArtifact (..)
  , CheckResult (..)
  , Checker (..)
  , Disposition (..)
  , DstFailure (..)
  , Observation (..)
  , ReplayResult (..)
  , ScenarioArtifactV4 (..)
  , ScenarioExpected (..)
  , pureCheck
  )
import ReadinessWorldSpec (PathKey (..), replayed, setPath, withRoot)
import System.FilePath ((</>))
import Test.Hspec hiding (pending)

-- | The module fixture @duplicate_delivery_run@.
duplicateDeliveryRun :: IO CoverageRun
duplicateDeliveryRun = withRoot $ \root -> do
  rw <- newReadinessWorld (root </> "live") defaultBudget Nothing
  t <- timeline rw
  delivery <- cleanGreen t False
  drain t
  _ <- deliverWebhook t delivery
  _ <- converge t
  a <- artifact rw "coverage-duplicate-delivery-v1"
  closeWorld rw
  result <- replayed a (root </> "replay")
  pure CoverageRun {artifact = a, replay = Just result}

spec :: Spec
spec = describe "tests/integration/testing/test_readiness_coverage.py" $ do
  beforeAll duplicateDeliveryRun $ do
    it "test_coverage_requires_adapter_checker_and_observed_outcome" $ \run -> do
      report <- collected [run]
      let dimension name = head' [d | d <- report.dimensions, d.name == name]
          duplicate = dimension "duplicate_delivery"
          timer = dimension "timer_lifecycle"
      duplicate.status `shouldBe` "covered"
      (head' duplicate.evidence).adapters `shouldBe` ["webhook.redelivery"]
      (head' duplicate.evidence).checkers `shouldBe` ["readiness.no_duplicate_effect"]
      (head' duplicate.evidence).outcomes `shouldBe` ["webhook.duplicate"]
      timer.status `shouldBe` "uncovered"
      (head' timer.evidence).adapters `shouldBe` []
      (head' timer.evidence).checkers `shouldBe` ["readiness.timer_custody"]
      (head' timer.evidence).outcomes `shouldBe` ["timer.armed"]
      (dimension "fair_convergence").status `shouldBe` "covered"
      (dimension "checker_activation").status `shouldBe` "covered"
      (dimension "exact_replay").status `shouldBe` "covered"
      (dimension "ci_rerun_repair").status `shouldBe` "blocked"
      (dimension "agent_terminal_fault_cuts").status `shouldBe` "blocked"
      (dimension "stale_rate_limited_reads").status `shouldBe` "blocked"
      (dimension "history_dispatch_fault_cuts").status `shouldBe` "blocked"

    it "test_coverage_is_deterministic_strict_json" $ \first -> do
      let second = renamed "coverage-duplicate-delivery-copy-v1" first
      forward <- collected [first, second]
      reverse' <- collected [second, first]
      let encoded = encodeReadinessCoverage forward
      encoded `shouldBe` encodeReadinessCoverage reverse'
      loadReadinessCoverage encoded `shouldBe` Right forward
      encoded `shouldNotSatisfy` BS.isInfixOf "readiness-world-private-key"
      encoded `shouldNotSatisfy` BS.isInfixOf "readiness-world-webhook-secret"

    it "test_coverage_rejects_unknown_contradictory_and_over_budget_evidence" $ \run -> do
      report <- collected [run]
      let dumped = coverageJson report
          dimensionIndex name = head' [i | (i, d) <- zip [0 ..] report.dimensions, d.name == name]
          unknown =
            setPath
              [Key "dimensions", Index (dimensionIndex "duplicate_delivery"), Key "evidence", Index 0, Key "adapters"]
              (Array [String "webhook.unknown"])
              dumped
      loadReadinessCoverage (encodePlain unknown) `shouldSatisfy` validationError ""
      let contradictory = setPath [Key "dimensions", Index (dimensionIndex "timer_lifecycle"), Key "status"] (String "covered") dumped
      loadReadinessCoverage (encodePlain contradictory) `shouldSatisfy` validationError "covered dimension requires complete scenario evidence"
      let extra = case dumped of
            Object members -> Object (members <> [("percentage", Int 100)])
            other -> other
      loadReadinessCoverage (encodePlain extra) `shouldSatisfy` validationError ""
      let runs = [renamed ("coverage-copy-" <> T.pack (show i)) run | i <- [0 .. 16 :: Int]]
      collectReadinessCoverage runs `shouldSatisfy` valueError "at most 16 scenario runs"

    it "test_coverage_rejects_replay_or_scenario_identity_contradictions" $ \run -> do
      let quiescent = fmap (\(ReplayResult sid _ f o j g) -> ReplayResult sid DQuiescent f o j g) run.replay
      collectReadinessCoverage [CoverageRun run.artifact quiescent] `shouldSatisfy` valueError "replay disposition does not match"
      let changed = case run.artifact of
            ArtifactV4 (ScenarioArtifactV4 sid p c b o (ScenarioExpected d f k _) g) ->
              ArtifactV4 (ScenarioArtifactV4 sid p c b o (ScenarioExpected d f k ("sha256:" <> T.replicate 64 "0")) g)
            other -> other
      collectReadinessCoverage [run, CoverageRun changed run.replay] `shouldSatisfy` valueError "scenario identity is contradictory"

  it "test_failed_boundary_cannot_borrow_an_earlier_checker_witness" $ withRoot $ \root -> do
    let failDuplicate observation = do
          result <- checkReadiness observation
          let attempts = observation.value .: "bounds" .: "usage" .: "retained.provider.delivery_attempts"
          if (case attempts of Int n -> n >= 2; _ -> False)
            then Right CheckResult {passed = False, detail = Object [("forced", String "duplicate boundary failure")]}
            else Right result
    rw <- newReadinessWorldWith (root </> "live") defaultBudget Nothing (const (pure ())) readinessChecker {check = pureCheck failDuplicate}
    t <- timeline rw
    delivery <- cleanGreen t False
    drain t
    deliverWebhook t delivery `shouldThrow` independentModel
    a <- artifact rw "coverage-failed-duplicate-boundary-v1"
    closeWorld rw
    report <- collected [CoverageRun a Nothing]
    (head' [d | d <- report.dimensions, d.name == "duplicate_delivery"]).status `shouldBe` "uncovered"

collected :: [CoverageRun] -> IO CoverageReport
collected runs = either (fail . show) pure (collectReadinessCoverage runs)

-- | @model_copy(update={"scenario_id": …})@ of the artifact and its replay.
renamed :: Text -> CoverageRun -> CoverageRun
renamed scenarioId run =
  CoverageRun
    { artifact = case run.artifact of
        ArtifactV4 (ScenarioArtifactV4 _ p c b o e g) -> ArtifactV4 (ScenarioArtifactV4 scenarioId p c b o e g)
        other -> other
    , replay = fmap (\(ReplayResult _ d f o j g) -> ReplayResult scenarioId d f o j g) run.replay
    }

-- | @json.dumps(value).encode()@ (any spelling the loader must accept).
encodePlain :: Json -> BS.ByteString
encodePlain = either (error . show) id . dumps defaultDumps

validationError :: Text -> Either PythonException CoverageReport -> Bool
validationError fragment = \case
  Left e -> let (cls, message) = classAndStr e in cls == "ValidationError" && fragment `T.isInfixOf` message
  Right _ -> False

valueError :: Text -> Either PythonException CoverageReport -> Bool
valueError fragment = \case
  Left e -> let (cls, message) = classAndStr e in cls == "ValueError" && fragment `T.isInfixOf` message
  Right _ -> False

-- | @pytest.raises(InvariantViolation, match="independent-model")@.
independentModel :: DstFailure -> Bool
independentModel = \case
  InvariantViolation message -> "independent-model" `T.isInfixOf` message
  _ -> False

head' :: [a] -> a
head' = \case
  x : _ -> x
  [] -> error "empty list"
