-- | Live cross-language checks of the DST tooling routes against the
-- pinned reference: the same artifacts authored by both languages, each
-- language replaying the other's artifacts and failure bundles, the
-- legacy replay CLI byte for byte, and the campaign process runner's
-- reports side by side.
module Spec.ToolingInterop (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Petrus.Json (Json (..), parseJson, surrogateRefusingLoads)
import Petrus.Testing.Dst (AnyArtifact, DstFailure, encodeArtifact, failureMessage)
import Petrus.Testing.Dst.Engine.GeneratedRuntimeQualification
  ( buildBroadOnlyArtifact
  , buildLivelockFailureArtifact
  , buildMinimizedFairRegressionArtifact
  )
import Petrus.TestSupport.Python (PythonResult (..), runPython)
import Spec.Support (fixturesDir, member, memberList)
import Spec.Tooling (runWorldCommand)
import System.Directory (createDirectoryIfMissing, makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- | @python -m MODULE ARGS@ from the reference checkout.
pythonModule :: String -> [String] -> IO (ExitCode, ByteString, ByteString)
pythonModule moduleName arguments = do
  result <-
    runPython
      "import runpy, sys\nsys.path.insert(0, '')\nmodule = sys.argv[1]\nsys.argv = sys.argv[1:]\nrunpy.run_module(module, run_name='__main__', alter_sys=True)"
      (moduleName : arguments)
      ""
  pure (resultExit result, resultStdout result, resultStderr result)

succeeded :: String -> (ExitCode, ByteString, ByteString) -> IO ByteString
succeeded label (code, out, err) = do
  case code of
    ExitSuccess -> pure ()
    _ -> expectationFailure (label <> " failed:\n" <> BC.unpack out <> BC.unpack err)
  err `shouldBe` ""
  pure out

-- | The artifacts both languages author (name, Haskell builder).
authored :: FilePath -> [(String, IO (Either DstFailure AnyArtifact))]
authored dir =
  [ ("minimized", buildMinimizedFairRegressionArtifact (dir </> "minimized-history.jsonl") (dir </> "minimized-dispatch.db") False)
  , ("livelock", buildLivelockFailureArtifact (dir </> "livelock") False [])
  , ("broad", buildBroadOnlyArtifact (dir </> "broad-history.jsonl") (dir </> "broad-dispatch.db"))
  ]

pythonAuthoring :: String
pythonAuthoring =
  unlines
    [ "import sys"
    , "from pathlib import Path"
    , "from petrus.testing.dst import encode_artifact"
    , "from tests.dst.generated_runtime_qualification import ("
    , "    build_broad_only_artifact, build_livelock_failure_artifact, build_minimized_fair_regression_artifact)"
    , "root = Path(sys.argv[1])"
    , "root.mkdir(parents=True, exist_ok=True)"
    , "artifacts = {"
    , "    'minimized': build_minimized_fair_regression_artifact("
    , "        root / 'minimized-history.jsonl', root / 'minimized-dispatch.db', with_checker=False),"
    , "    'livelock': build_livelock_failure_artifact(root / 'livelock', retry=False, perturbations=()),"
    , "    'broad': build_broad_only_artifact(root / 'broad-history.jsonl', root / 'broad-dispatch.db'),"
    , "}"
    , "for name, artifact in artifacts.items():"
    , "    (root / f'{name}.json').write_bytes(encode_artifact(artifact) + b'\\n')"
    ]

-- | The campaign report members both runners must agree on.
reportSkeleton :: Json -> Json
reportSkeleton report =
  Object
    [ (k, member k report)
    | k <- ["bounds", "campaign_id", "deselected_profiles", "format", "outcome", "tier", "unmodeled_boundaries", "version"]
    ]

profileSkeleton :: Json -> Json
profileSkeleton p =
  Object
    [ (k, member k p)
    | k <- ["case_summaries_limit", "examples_target", "outcome", "profile", "profile_resource_limits", "seed", "stateful_steps_limit"]
    ]

keysOf :: Json -> [T.Text]
keysOf = \case
  Object members -> map fst members
  _ -> []

parse :: ByteString -> IO Json
parse = either fail pure . parseJson surrogateRefusingLoads

spec :: Spec
spec = describe "DST tooling interop with the reference" $ do
  it "both languages author the same generated-runtime artifacts and replay each other's byte for byte" $
    withSystemTempDirectory "petrus-dst-interop-" $ \scratch -> do
      dir <- makeAbsolute scratch
      let haskellDir = dir </> "haskell"
          pythonDir = dir </> "python"
      _ <- succeeded "python authoring" =<< runPythonScript pythonAuthoring [pythonDir]
      createDirectoryIfMissing True haskellDir
      forM_ (authored haskellDir) $ \(name, build) -> do
        artifact <- build >>= either (fail . T.unpack . failureMessage) pure
        bytes <- either (fail . T.unpack) pure (encodeArtifact artifact)
        let haskellFile = haskellDir </> name <> ".json"
            pythonFile = pythonDir </> name <> ".json"
        BS.writeFile haskellFile (bytes <> "\n")
        pythonBytes <- BS.readFile pythonFile
        pythonBytes `shouldBe` bytes <> "\n"
        -- Python replays the Haskell-authored artifact, and Haskell the
        -- Python-authored one, with identical result bytes.
        pythonReplay <- succeeded "python replay_world" =<< pythonModule "tests.dst.replay_world" [haskellFile]
        haskellReplay <- succeeded "petrus-dst-world replay" =<< runWorldCommand ["replay", pythonFile]
        haskellReplay `shouldBe` pythonReplay

  it "failure bundles retained by either language replay through the other" $
    withSystemTempDirectory "petrus-dst-interop-" $ \scratch -> do
      dir <- makeAbsolute scratch
      let haskellBundle = dir </> "haskell-bundle"
          pythonBundle = dir </> "python-bundle"
      _ <- succeeded "petrus-dst-world failure demonstrate" =<< runWorldCommand ["failure", "demonstrate", "--output", haskellBundle]
      _ <- succeeded "python failure demonstrate" =<< pythonModule "tests.dst.failure" ["demonstrate", "--output", pythonBundle]
      -- The retained artifacts are the same bytes.
      haskellArtifact <- BS.readFile (haskellBundle </> "scenario.json")
      BS.readFile (pythonBundle </> "scenario.json") `shouldReturn` haskellArtifact
      -- The manifests agree except for the runtime identity that made them.
      let withoutRuntime = \case
            Object members -> Object [(k, v) | (k, v) <- members, k /= "runtime"]
            other -> other
      haskellManifest <- BS.readFile (haskellBundle </> "manifest.json") >>= parse
      pythonManifest <- BS.readFile (pythonBundle </> "manifest.json") >>= parse
      withoutRuntime haskellManifest `shouldBe` withoutRuntime pythonManifest
      forM_ [haskellBundle, pythonBundle] $ \bundle -> do
        byPython <- succeeded "python failure replay" =<< pythonModule "tests.dst.failure" ["replay", bundle]
        byHaskell <- succeeded "petrus-dst-world failure replay" =<< runWorldCommand ["failure", "replay", bundle]
        byHaskell `shouldBe` byPython

  it "the legacy scenario replay CLI prints the reference's bytes" $ do
    fixture <- makeAbsolute (fixturesDir </> "projection-crash-recovery-v1.json")
    reference <- succeeded "python -m tests.dst.replay" =<< pythonModule "tests.dst.replay" [fixture]
    ours <- succeeded "petrus-dst-world legacy-replay" =<< runWorldCommand ["legacy-replay", fixture]
    ours `shouldBe` reference

  it "the campaign process runners report the same bounds, seeds, and verdicts" $
    withSystemTempDirectory "petrus-dst-interop-" $ \scratch -> do
      dir <- makeAbsolute scratch
      let arguments report = ["--tier", "ordinary", "--campaign-id", "interop-runtime-focused", "--profile", "runtime-focused", "--report", report]
      _ <- succeeded "python campaign" =<< pythonModule "tests.dst.campaign" (arguments (dir </> "python.json"))
      _ <- succeeded "petrus-dst-world campaign" =<< runWorldCommand ("campaign" : arguments (dir </> "haskell.json"))
      python <- BS.readFile (dir </> "python.json") >>= parse
      haskell <- BS.readFile (dir </> "haskell.json") >>= parse
      keysOf haskell `shouldBe` keysOf python
      reportSkeleton haskell `shouldBe` reportSkeleton python
      map profileSkeleton (memberList "profiles" haskell) `shouldBe` map profileSkeleton (memberList "profiles" python)
      map (keysOf . member "semantic_reach") (memberList "profiles" haskell)
        `shouldBe` map (keysOf . member "semantic_reach") (memberList "profiles" python)
  where
    runPythonScript script arguments = do
      result <- runPython (T.pack ("import sys\nsys.path.insert(0, '')\n" <> script)) arguments ""
      pure (resultExit result, resultStdout result, resultStderr result)
