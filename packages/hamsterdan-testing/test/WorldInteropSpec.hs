-- | World artifacts against the reference (@differential/world_reference.py@).
--
-- Each named scenario ("Hamsterdan.Testing.World.Scenarios") is authored
-- through the reference's @ReadinessWorld@ and through the Haskell World.
-- The two artifacts must be the same bytes, and each replays in the other
-- language with the same replay-result bytes (canonical JSON).
module WorldInteropSpec (spec) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T
import Hamsterdan.Testing.World (replayReadiness)
import Hamsterdan.Testing.World.Coverage (CoverageRun (..), collectReadinessCoverage, encodeReadinessCoverage)
import Hamsterdan.Testing.World.Scenarios (Scenario (..), authorScenario, scenarios)
import Petrus.Json (Json, defaultDumps, dumpsText, parseJson, pythonLoads)
import Petrus.Json.Encode (EncodeOptions (..))
import Petrus.Testing.Dst (AnyReplayResult (..), decodeArtifact, encodeReplayResult)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory (canonicalizePath, createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process.Typed (byteStringInput, proc, readProcess, setStdin)
import Test.Hspec

-- | What the reference produced for one scenario: its artifact and the
-- replay result of that artifact in the reference.
data Reference = Reference
  { artifact :: ByteString
  , replayed :: ByteString
  , coverage :: ByteString
  }

spec :: Spec
spec = describe "World interop against the reference" $
  mapM_ scenarioSpec scenarios

scenarioSpec :: Scenario -> Spec
scenarioSpec s = describe (T.unpack s.name) . beforeAll (referenceRun s) $ do
  it "the Haskell World authors the reference's artifact bytes" $ \expected -> withRoot $ \root -> do
    authored <- authorScenario s root
    sameBytes (T.unpack s.name <> ".artifact") expected.artifact authored
  it "the reference's artifact replays in Haskell with the reference's result bytes" $ \expected -> withRoot $ \root -> do
    result <- haskellReplay expected.artifact root
    sameBytes (T.unpack s.name <> ".replay") expected.replayed result
  it "the reference's artifact has the reference's coverage report bytes" $ \expected -> withRoot $ \root -> do
    report <- haskellCoverage expected.artifact root
    sameBytes (T.unpack s.name <> ".coverage") expected.coverage report
  it "the Haskell artifact replays in the reference with the Haskell result bytes" $ \_ -> withRoot $ \root -> do
    authored <- authorScenario s (root </> "author")
    ours <- haskellReplay authored (root </> "haskell-replay")
    theirs <- reference ["replay", root </> "reference-replay"] authored
    sameBytes (T.unpack s.name <> ".cross-replay") ours theirs

withRoot :: (FilePath -> IO a) -> IO a
withRoot use = withSystemTempDirectory "hamsterdan-world" (\dir -> canonicalizePath dir >>= use)

referenceRun :: Scenario -> IO Reference
referenceRun s = withRoot $ \root -> do
  authored <- reference ["author", T.unpack s.name, root </> "author"] ""
  result <- reference ["replay", root </> "replay"] authored
  report <- reference ["coverage", root </> "coverage"] authored
  pure Reference {artifact = authored, replayed = result, coverage = report}

haskellReplay :: ByteString -> FilePath -> IO ByteString
haskellReplay bytes root = case decodeArtifact bytes of
  Left problem -> expectationFailure ("the artifact does not decode: " <> show problem) >> pure ""
  Right decoded ->
    replayReadiness decoded root >>= \case
      Left failure -> expectationFailure ("replay refused: " <> show failure) >> pure ""
      Right result -> pure (encodeReplayResult result)

-- | @collect_readiness_coverage@ over the artifact and its Haskell replay.
haskellCoverage :: ByteString -> FilePath -> IO ByteString
haskellCoverage bytes root = case decodeArtifact bytes of
  Left problem -> expectationFailure ("the artifact does not decode: " <> show problem) >> pure ""
  Right decoded ->
    replayReadiness decoded root >>= \case
      Right (ReplayV2 result) -> case collectReadinessCoverage [CoverageRun decoded (Just result)] of
        Right report -> pure (encodeReadinessCoverage report)
        Left problem -> expectationFailure ("coverage refused: " <> show problem) >> pure ""
      other -> expectationFailure ("replay refused: " <> show other) >> pure ""

reference :: [String] -> ByteString -> IO ByteString
reference arguments input = do
  executable <- upstreamPythonExecutable "hamsterdan"
  repo <- repoRoot
  let script = repo </> "packages" </> "hamsterdan-testing" </> "differential" </> "world_reference.py"
      config = setStdin (byteStringInput (BL.fromStrict input)) (proc executable (["-I", "-B", script] <> arguments))
  (status, out, err) <- readProcess config
  unless (status == ExitSuccess) $
    expectationFailure ("the reference World driver failed: " <> BC.unpack (BL.toStrict err))
  pure (BL.toStrict out)

-- | Equal bytes. A difference is reported as the first differing lines of
-- the indented JSON; with @HAMSTERDAN_WORLD_DIFF@ set, both documents are
-- also written there.
sameBytes :: String -> ByteString -> ByteString -> IO ()
sameBytes label expected actual = unless (expected == actual) $ do
  lookupEnv "HAMSTERDAN_WORLD_DIFF" >>= mapM_ (\dir -> do
    createDirectoryIfMissing True dir
    BS.writeFile (dir </> (label <> ".reference.json")) expected
    BS.writeFile (dir </> (label <> ".haskell.json")) actual)
  let lined bytes = case parseJson pythonLoads bytes of
        Right (value :: Json) -> either (const [T.pack (BC.unpack bytes)]) T.lines (dumpsText defaultDumps {sortKeys = True, indent = Just 1, ensureAscii = False} value)
        Left _ -> [T.pack (BC.unpack bytes)]
      left = lined expected
      right = lined actual
      width = max (length left) (length right)
      pad xs = map Just xs <> replicate (width - length xs) Nothing
      differing = [(n, a, b) | (n, a, b) <- zip3 [1 :: Int ..] (pad left) (pad right), a /= b]
  expectationFailure
    ( label
        <> " differs from the reference at "
        <> show (length differing)
        <> " lines; first:\n"
        <> unlines [show n <> "\n  reference: " <> show a <> "\n  haskell:   " <> show b | (n, a, b) <- take 8 differing]
    )
