{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The generated-schedule campaigns: the Hypothesis state machines of
-- @tests/dst/test_generated_delivery_world.py@ and
-- @tests/dst/test_generated_runtime_world.py@ (as Hedgehog state machines,
-- at the reference's ordinary settings), and @tests/dst/test_campaign.py@
-- (bounded campaign operation and reporting).
module Spec.Campaigns (spec) where

import Control.Exception (bracket_)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Hedgehog.Internal.Report (Report (..), Result (..))
import Petrus.Json (Json (..), parseJson, surrogateRefusingLoads)
import Petrus.Testing.Dst (decodeErrorMessage, loadArtifact)
import Petrus.Testing.Dst.Campaign
import Petrus.Testing.Dst.Campaign.Machines (checkCampaign, renderFailure)
import Petrus.Testing.Dst.Campaign.Support (ToolError (..))
import Spec.Support (fixturesDir, member, memberList)
import Spec.Tooling (worldExecutable)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

minimizedFixture :: FilePath
minimizedFixture = fixturesDir </> "generated-runtime-minimized-fair-regression-v4.json"

-- | Run one generated-schedule test at its campaign settings.
machine :: Text -> Expectation
machine name = do
  settings <- campaignSettings name
  report <- checkCampaign settings
  case report.reportStatus of
    OK -> pure ()
    _ -> renderFailure name report >>= expectationFailure

-- | @monkeypatch.setenv@ for the duration of an action.
withEnv :: [(String, String)] -> IO a -> IO a
withEnv pairs action = do
  previous <- mapM (\(k, _) -> (k,) <$> lookupEnv k) pairs
  bracket_
    (mapM_ (uncurry setEnv) pairs)
    (forM_ previous $ \(k, v) -> maybe (unsetEnv k) (setEnv k) v)
    action

refusing :: Text -> ToolError -> Bool
refusing needle (ToolError message) = needle `T.isInfixOf` message

zeroRepository :: IO Json
zeroRepository = pure (Object [("commit", String (T.replicate 40 "0")), ("dirty", Bool False)])

readReport :: FilePath -> IO Json
readReport file = BS.readFile file >>= either fail pure . parseJson surrogateRefusingLoads

spec :: Spec
spec = do
  describe "test_generated_delivery_world.py (generated identified-delivery schedules)" $ do
    it "test_broad_generated_delivery_schedules_replay_exactly" $ machine "delivery-broad"
    it "test_focused_generated_delivery_schedules_cover_high_value_boundaries_and_replay_exactly" $ machine "delivery-focused"
  describe "test_generated_runtime_world.py (generated cross-layer runtime schedules)" $ do
    it "test_focused_generated_runtime_schedules_replay_exactly" $ machine "runtime-focused"
    it "test_broad_generated_runtime_schedules_replay_exactly" $ machine "runtime-broad"

  describe "test_campaign.py (bounded campaign operation and reporting)" $ do
    it "test_campaign_tiers_are_bounded_and_profile_seeds_are_isolated" $ do
      [(p.name, (p.ordinaryExamples, p.ordinarySteps)) | p <- campaignProfiles]
        `shouldBe` [ ("delivery-broad", (30, 8))
                   , ("delivery-focused", (20, 6))
                   , ("runtime-broad", (16, 5))
                   , ("runtime-focused", (10, 4))
                   ]
      normal <- either (fail . T.unpack) pure (campaignSettingsFrom "runtime-focused" [(tierEnv, "ordinary")])
      (normal.maxExamples, normal.statefulStepCount, normal.derandomize) `shouldBe` (10, 4, True)
      scheduled <-
        either (fail . T.unpack) pure $
          campaignSettingsFrom
            "runtime-focused"
            [(tierEnv, "scheduled"), (casePathEnv, "/tmp/petrus-dst-campaign-test.jsonl"), (seedEnv, "19003")]
      (scheduled.maxExamples, scheduled.statefulStepCount, scheduled.derandomize) `shouldBe` (40, 6, False)
      let first = campaignSeed "2026-W34" "runtime-focused"
      first `shouldBe` campaignSeed "2026-W34" "runtime-focused"
      first `shouldNotBe` campaignSeed "2026-W35" "runtime-focused"
      length (nub [campaignSeed "2026-W34" p.name | p <- campaignProfiles]) `shouldBe` 4
      case campaignSettingsFrom "runtime-focused" [(tierEnv, "unbounded")] of
        Left message -> ("unknown DST campaign tier" `T.isInfixOf` message) `shouldBe` True
        Right _ -> expectationFailure "an unknown tier was admitted"

    it "test_campaign_case_summary_is_payload_free_and_bounded" $
      withSystemTempDirectory "petrus-dst-campaign-" $ \dir -> do
        let cases = dir </> "cases.jsonl"
        artifact <- loadArtifact minimizedFixture >>= either (fail . T.unpack . decodeErrorMessage) pure
        withEnv [(casePathEnv, cases), (seedEnv, "19003")] (recordCampaignCase "runtime-focused" artifact)
        encoded <- BS.readFile cases
        summary <- either fail pure (parseJson surrogateRefusingLoads encoded)
        fixtureBytes <- BS.readFile minimizedFixture
        member "campaign_profile" summary `shouldBe` String "runtime-focused"
        member "campaign_seed" summary `shouldBe` Int 19003
        member "artifact_bytes" summary `shouldBe` Int (toInteger (BS.length (fst (BS.spanEnd (== 10) fixtureBytes))))
        member "commands" summary
          `shouldBe` Array (map String ["engine.drive", "scope.open", "source.deliver", "worker.claim", "worker.complete"])
        member "disposition" summary `shouldBe` String "quiescent"
        member "profile_resource_limits" summary `shouldNotBe` Object []
        ("shrink-event-" `BS.isInfixOf` encoded) `shouldBe` False
        ("\"payload\"" `BS.isInfixOf` encoded) `shouldBe` False
        ("\"result\"" `BS.isInfixOf` encoded) `shouldBe` False

    it "test_ordinary_campaign_route_runs_pytest_and_retains_actual_reach" $
      withSystemTempDirectory "petrus-dst-campaign-" $ \dir -> do
        let reportPath = dir </> "campaign.json"
        runner <- worldExecutable >>= processRunner
        code <- runCampaign runner Ordinary "cv19-ts1-integration" ["runtime-focused"] reportPath
        report <- readReport reportPath
        code `shouldBe` 0
        member "format" report `shouldBe` String reportFormat
        member "version" report `shouldBe` Int reportVersion
        member "outcome" report `shouldBe` String "pass"
        member "tier" report `shouldBe` String "ordinary"
        member "deselected_profiles" report `shouldBe` Array (map String ["delivery-broad", "delivery-focused", "runtime-broad"])
        length (memberList "unmodeled_boundaries" report) `shouldBe` 5
        case member "commit" (member "repository" report) of
          String commit -> T.length commit `shouldBe` 40
          other -> expectationFailure (show other)
        case memberList "profiles" report of
          [result] -> do
            member "profile" result `shouldBe` String "runtime-focused"
            member "outcome" result `shouldBe` String "pass"
            let int key = case member key result of
                  Int n -> n
                  other -> error (show other)
            int "cases" `shouldSatisfy` (>= int "examples_target")
            int "cases" `shouldSatisfy` (<= int "case_summaries_limit")
            int "artifact_bytes_max" `shouldSatisfy` (\n -> n > 0 && n <= 4194304)
            let reach = member "semantic_reach" result
            memberList "commands" reach `shouldContain` [String "source.deliver"]
            memberList "crash_cuts" reach `shouldContain` [String "generated_dispatch_refused"]
            memberList "faults" reach `shouldContain` [String "dispatch.refuse@activity_requested"]
          other -> expectationFailure ("expected one profile, got " <> show (length other))

    it "test_campaign_refuses_invalid_selection_before_execution" $
      withSystemTempDirectory "petrus-dst-campaign-" $ \dir -> do
        let refusingRunner =
              CampaignRunner
                { runProfile = \_ -> fail "the campaign ran a child before refusing its selection"
                , repository = zeroRepository
                , summaryBytes = caseSummaryBytes
                }
        runCampaign refusingRunner Scheduled "cv19-empty" [] (dir </> "empty.json")
          `shouldThrow` refusing "at least one profile"
        runCampaign refusingRunner Scheduled "cv19-duplicate" ["runtime-focused", "runtime-focused"] (dir </> "duplicate.json")
          `shouldThrow` refusing "more than once"
        runCampaign refusingRunner Scheduled "cv19-unknown" ["unknown"] (dir </> "unknown.json")
          `shouldThrow` refusing "unknown DST campaign profile"

    it "test_campaign_timeout_is_a_visible_failure" $
      withSystemTempDirectory "petrus-dst-campaign-" $ \dir -> do
        let reportPath = dir </> "timeout.json"
            timingOut =
              CampaignRunner
                { runProfile = \_ -> pure (TimedOut "bounded stdout" "")
                , repository = zeroRepository
                , summaryBytes = caseSummaryBytes
                }
        code <- runCampaign timingOut Scheduled "cv19-timeout" ["runtime-focused"] reportPath
        report <- readReport reportPath
        result <- case memberList "profiles" report of
          r : _ -> pure r
          [] -> fail "no profiles"
        code `shouldBe` 1
        member "outcome" report `shouldBe` String "fail"
        member "outcome" result `shouldBe` String "timeout"
        member "failure" result `shouldBe` String "exceeded 120 seconds"

    it "test_campaign_case_log_overage_writes_a_failed_report" $
      withSystemTempDirectory "petrus-dst-campaign-" $ \dir -> do
        let reportPath = dir </> "case-overage.json"
            overflowing =
              CampaignRunner
                { runProfile = \run -> do
                    BS.writeFile run.casesPath (BS.replicate 401 120)
                    pure (Completed 0 "" "")
                , repository = zeroRepository
                , summaryBytes = 1
                }
        code <- runCampaign overflowing Scheduled "cv19-case-overage" ["runtime-focused"] reportPath
        report <- readReport reportPath
        result <- case memberList "profiles" report of
          r : _ -> pure r
          [] -> fail "no profiles"
        code `shouldBe` 1
        member "outcome" report `shouldBe` String "fail"
        member "outcome" result `shouldBe` String "case_budget_exhausted"
        member "failure" result `shouldBe` String "DST campaign case log has 401 bytes; limit is 400"
