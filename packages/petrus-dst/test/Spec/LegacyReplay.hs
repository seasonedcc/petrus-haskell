{-# LANGUAGE OverloadedRecordDot #-}

-- | @tests/dst/test_replay.py@: the strict @petrus-dst-scenario@ contract
-- and the CV19.DS1 replay route (@petrus-dst-world legacy-replay@, the
-- twin of @python -m tests.dst.replay@).
module Spec.LegacyReplay (spec) where

import Control.Exception (evaluate, try)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Petrus.Json (Json (..), parseJson, surrogateRefusingLoads)
import Petrus.Testing.Dst.Campaign.Support (ToolError (..), canonicalDumps)
import Petrus.Testing.Dst.LegacyReplay
import Spec.Support (fixturesDir, member, readJson)
import Spec.Tooling
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

fixture :: FilePath
fixture = fixturesDir </> "projection-crash-recovery-v1.json"

writeScenario :: FilePath -> Json -> IO FilePath
writeScenario dir value = do
  let file = dir </> "scenario.json"
  either (fail . T.unpack) (BS.writeFile file) (canonicalDumps value)
  pure file

-- | @_reverse_crash_restart@.
reverseCrashRestart :: Json -> Json
reverseCrashRestart value =
  let crash = member "event" (nth 3)
      restart = member "event" (nth 4)
      nth i = case member "schedule" value of
        Array steps -> steps !! i
        _ -> Null
   in editAt [K "schedule", I 4] (setMember "event" crash) (editAt [K "schedule", I 3] (setMember "event" restart) value)

mutations :: [(String, Json -> Json)]
mutations =
  [ ("unknown top-level field", setMember "unknown" (Bool True))
  , ("version 2", setMember "version" (Int 2))
  , ("other profile", setMember "profile" (String "other"))
  , ("boolean events limit", editAt [K "limits"] (setMember "events" (Bool True)))
  , ("zero actions per drive", editAt [K "limits"] (setMember "actions_per_drive" (Int 0)))
  , ("unknown event kind", editAt [K "schedule", I 0, K "event"] (setMember "kind" (String "surprise")))
  , ("unknown fault kind", editAt [K "schedule", I 2, K "faults", I 0] (setMember "kind" (String "surprise")))
  , ("fault at a disallowed cut", editAt [K "schedule", I 2, K "faults", I 0] (setMember "cut" (String "projection_committed")))
  , ("drive above its limit", editAt [K "schedule", I 0, K "event"] (setMember "max_actions" (Int 2)))
  , ("sparse position", editAt [K "schedule", I 4] (setMember "position" (Int 8)))
  , ("duplicate initial place", editAt [K "initial", K "marking"] appendFirst)
  , ("duplicate expected place", editAt [K "expected", K "snapshot", K "marking"] appendFirst)
  , ("restart before crash", reverseCrashRestart)
  ]
  where
    appendFirst = \case
      Array (x : xs) -> Array (x : xs <> [x])
      other -> other

spec :: Spec
spec = describe "test_replay.py (strict scenario contract and replay route)" $ do
  it "test_projection_crash_fixture_is_strict_portable_data" $ do
    scenario <- loadScenario fixture
    scenario.application.definitionDigest `shouldBe` applicationDigest
    scenario.origin.parentScenarioId `shouldBe` Nothing
    raw <- readJson fixture
    scenarioJson scenario `shouldBe` raw
    -- format, version, and profile are literals of the model.
    (member "format" raw, member "version" raw, member "profile" raw)
      `shouldBe` (String scenarioFormat, Int scenarioVersion, String scenarioProfile)

  it "test_projection_crash_fixture_replays_through_fresh_production_engines" $ do
    report <- loadScenario fixture >>= replayScenario
    report.historyFrontier `shouldBe` 9
    report.snapshot
      `shouldBe` Object
        [ ("marking", Array [Object [("place", String "done"), ("tokens", Array [Object [("color", String "Done"), ("data", Object [("value", Int 3)])]])]])
        , ("status", String "terminated")
        , ("watermark", Int 0)
        , ("in_flight", Array [])
        ]
    Object report.observations
      `shouldBe` Object
        [ ("prepared_before_crash", Int 1)
        , ("projected_before_crash", Int 1)
        , ("prepared_after_restart", Int 0)
        , ("projected_after_restart", Int 1)
        , ("dispatch_pending_after_restart", Int 0)
        ]
    report.checks `shouldBe` ["S1-replay-agreement", "S3-stable-invocation", "S4-terminal-before-projection"]

  it "test_replay_command_emits_one_strict_passing_result" $ do
    (code, out, err) <- runWorldCommand ["legacy-replay", fixture]
    (code', out', err') <- runWorldCommand ["legacy-replay", fixture]
    (code, code') `shouldBe` (ExitSuccess, ExitSuccess)
    err `shouldBe` ""
    out' `shouldBe` out
    err' `shouldBe` ""
    result <- either fail pure (parseJson surrogateRefusingLoads out)
    member "format" result `shouldBe` String "petrus-dst-replay-result"
    member "scenario_id" result `shouldBe` String "projection-crash-recovery-v1"
    member "outcome" result `shouldBe` String "pass"
    member "property" result `shouldBe` String "S4-terminal-before-projection"

  describe "test_unknown_non_strict_or_incoherent_artifacts_refuse" $
    forM_ mutations $ \(label, mutate) ->
      it label $ withSystemTempDirectory "petrus-dst-legacy-" $ \dir -> do
        value <- readJson fixture
        file <- writeScenario dir (mutate value)
        outcome <- try (loadScenario file >>= evaluate)
        case outcome of
          Left (ValidationError _) -> pure ()
          Right _ -> expectationFailure "the mutated scenario was admitted"

  it "test_duplicate_fields_and_nonfinite_numbers_refuse_before_validation" $
    withSystemTempDirectory "petrus-dst-legacy-" $ \dir -> do
      let duplicate = dir </> "duplicate.json"
          nonfinite = dir </> "nonfinite.json"
      BS.writeFile duplicate "{\"format\":\"petrus-dst-scenario\",\"format\":\"other\"}"
      BS.writeFile nonfinite "{\"value\":NaN}"
      loadScenario duplicate `shouldThrow` refusalContaining "duplicate JSON field"
      loadScenario nonfinite `shouldThrow` refusalContaining "non-finite JSON number"
  where
    refusalContaining needle (ToolError message) = needle `T.isInfixOf` message
