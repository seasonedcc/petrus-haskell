{-# LANGUAGE OverloadedRecordDot #-}

-- | @tests/dst/test_failure.py@: CV19.DS4 failure retention, replay,
-- credential refusal, and promotion.
module Spec.Failure (spec) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..), parseJson, pythonLoads)
import Petrus.Testing.Dst (AnyArtifact, artifactFromJson, decodeErrorMessage, loadArtifact, toJson)
import Petrus.Testing.Dst.Campaign.Support (ToolError (..), canonicalDumps)
import Petrus.Testing.Dst.Failure
import Spec.Support (member, memberList)
import Spec.Tooling (editAt, Step (..), setMember, runWorldCommand)
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

type Demonstrated = (FilePath, Json)

-- | The module-scoped @demonstrated_bundle@ fixture.
withDemonstratedBundle :: ActionWith Demonstrated -> IO ()
withDemonstratedBundle action =
  withSystemTempDirectory "dst-failure" $ \dir -> do
    let bundle = dir </> "bundle"
    manifest <- demonstrateFailureBundle bundle
    action (bundle, manifest)

copyBundle :: FilePath -> FilePath -> IO ()
copyBundle from to = do
  createDirectory to
  names <- listDirectory from
  forM_ names $ \n -> copyFile (from </> n) (to </> n)

refusing :: Text -> ToolError -> Bool
refusing needle (ToolError message) = needle `T.isInfixOf` message

loadCurrent :: FilePath -> IO AnyArtifact
loadCurrent file = loadArtifact file >>= either (fail . T.unpack . decodeErrorMessage) pure

-- | @payload@ into the first @execute@ operation's command.
withPayload :: Json -> Json -> Json
withPayload payload value =
  case [i | (i, o) <- zip [0 ..] (memberList "operations" value), member "kind" o == String "execute"] of
    i : _ -> editAt [K "operations", I i, K "command"] (setMember "payload" payload) value
    [] -> value

spec :: Spec
spec = describe "test_failure.py (failure retention, replay, and promotion)" $ aroundAll withDemonstratedBundle $ do
  it "test_deliberate_failure_is_retained_replayed_and_promoted" $ \(bundle, manifest) -> do
    names <- listDirectory bundle
    sort names `shouldBe` ["manifest.json", "scenario.json"]
    let at path = foldl (flip member) manifest path
    at ["format"] `shouldBe` String bundleFormat
    at ["version"] `shouldBe` Int bundleVersion
    at ["property"] `shouldBe` String failureProperty
    at ["discovery_seed"] `shouldBe` Int 19003
    at ["artifact", "version"] `shouldBe` Int 4
    at ["artifact", "api"] `shouldBe` String "petrus.testing.dst/v4"
    at ["artifact", "disposition"] `shouldBe` String "budget_exhausted"
    at ["artifact", "failure", "kind"] `shouldBe` String "budget_exhausted"
    at ["shrink", "parent_operations"] `shouldBe` at ["shrink", "minimized_operations"]
    case (at ["shrink", "parent_prefix_operations"], at ["shrink", "minimized_prefix_operations"]) of
      (Int parent, Int minimized) -> parent `shouldSatisfy` (> minimized)
      other -> expectationFailure (show other)
    case (at ["shrink", "parent_bytes"], at ["shrink", "minimized_bytes"]) of
      (Int parent, Int minimized) -> parent `shouldSatisfy` (> minimized)
      other -> expectationFailure (show other)
    at ["shrink", "removed_retry"] `shouldBe` Bool True
    at ["shrink", "removed_perturbations"] `shouldBe` Array (map String ["observe", "crash_reload", "observe"])
    at ["replay", "cwd"] `shouldBe` String "repository-root"
    at ["replay", "command"] `shouldBe` Array (map String replayCommand)
    at ["promotion", "status"] `shouldBe` String "ordinary-green-regression"
    at ["promotion", "disposition"] `shouldBe` String "quiescent"
    memberList "checker_activations" (at ["semantic_coverage"]) `shouldNotBe` []
    sizes <- mapM (getFileSize . (bundle </>)) names
    sum sizes `shouldSatisfy` (<= defaultLimits.bundleBytes)

    encodedManifest <- BS.readFile (bundle </> "manifest.json")
    ("\"payload\"" `BS.isInfixOf` encodedManifest) `shouldBe` False
    ("\"result\"" `BS.isInfixOf` encodedManifest) `shouldBe` False
    ("shrinking-livelock-event" `BS.isInfixOf` encodedManifest) `shouldBe` False
    replayed <- replayFailureBundle bundle
    member "outcome" replayed `shouldBe` String "pass"
    member "failure_disposition" replayed `shouldBe` String "budget_exhausted"
    member "promotion_disposition" replayed `shouldBe` String "quiescent"

    (code, out, err) <- runWorldCommand ["failure", "replay", bundle]
    code `shouldBe` ExitSuccess
    err `shouldBe` ""
    parseJson pythonLoads out `shouldBe` Right replayed

  describe "test_failure_retention_refuses_credential_shaped_data_before_writing" $
    forM_
      [ (Object [("provider_password", String "not-retainable")], "credential-like field")
      , (Object [("message", String "failed at postgres://admin:password@provider.invalid/db")], "credential-like value")
      ]
      $ \(payload, match) ->
        it (T.unpack match) $ \(bundle, _) -> withSystemTempDirectory "dst-failure-unsafe" $ \dir -> do
          artifact <- loadCurrent (bundle </> "scenario.json")
          unsafe <- either (fail . T.unpack . decodeErrorMessage) pure (artifactFromJson (withPayload payload (toJson artifact)))
          let destination = dir </> "unsafe"
          retainFailureBundle destination unsafe artifact failureProperty False [] promotedFixture
            `shouldThrow` refusing match
          doesPathExist destination `shouldReturn` False

  it "test_failure_replay_refuses_tampering_and_extra_files" $ \(bundle, _) ->
    withSystemTempDirectory "dst-failure-tamper" $ \dir -> do
      let tampered = dir </> "tampered"
      copyBundle bundle tampered
      original <- BS.readFile (tampered </> "scenario.json")
      BS.writeFile (tampered </> "scenario.json") (original <> " ")
      replayFailureBundle tampered `shouldThrow` refusing "does not match its retained byte identity"

      let extra = dir </> "extra"
      copyBundle bundle extra
      writeFile (extra </> "provider-response.txt") "must not be retained"
      replayFailureBundle extra `shouldThrow` refusing "exactly manifest.json and scenario.json"

  it "test_failure_replay_refuses_manifest_mismatch_and_bundle_overage" $ \(bundle, _) ->
    withSystemTempDirectory "dst-failure-mismatch" $ \dir -> do
      let mismatched = dir </> "mismatched"
      copyBundle bundle mismatched
      raw <- BS.readFile (mismatched </> "manifest.json")
      manifest <- either fail pure (parseJson pythonLoads raw)
      let bumped = case member "discovery_seed" manifest of
            Int seed -> setMember "discovery_seed" (Int (seed + 1)) manifest
            other -> error (show other)
      encoded <- either (fail . T.unpack) pure (canonicalDumps bumped)
      BS.writeFile (mismatched </> "manifest.json") (encoded <> "\n")
      replayFailureBundle mismatched `shouldThrow` refusing "does not match its manifest expectations"

      replayFailureBundleWith defaultLimits {bundleBytes = 1} bundle `shouldThrow` refusing "bundle exceeds 1 bytes"

  it "test_failure_manifest_refuses_unknown_schema" $ \_ ->
    case validateManifest (Object [("format", String bundleFormat), ("version", Int 2)]) of
      Left _ -> pure ()
      Right _ -> expectationFailure "an unknown manifest schema was admitted"
