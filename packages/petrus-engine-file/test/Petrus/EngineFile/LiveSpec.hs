-- | The differential against a live petrus-engine (its environment,
-- @upstream/petrus-engine/.venv@, is provisioned on first use):
--
-- * the committed corpus is current: @reference.py@ reproduces every
--   recorded verdict;
-- * fresh seeded fuzz corpora (seeds 1 to 3 by default, or the
--   comma-separated @PETRUS_ENGINE_FILE_FUZZ_SEEDS@) agree case by case;
-- * corpora named in @PETRUS_ENGINE_FILE_CORPORA@ (comma-separated paths)
--   agree case by case;
-- * the pinned @net_file_schema.json@, which "Petrus.EngineFile.SchemaSpec"
--   checks this package against, is what @petrus-cli gen-json-schema@
--   generates from the pinned models.
module Petrus.EngineFile.LiveSpec (spec, referencePython, repoRoot) where

import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.EngineFile.Corpus
import Petrus.EngineFile.CorpusSpec (checkCase, corpusPath)
import Petrus.Json.Parse (parseJson, surrogateRefusingLoads)
import Petrus.Json.Value qualified as J
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo qualified as TestSupport
import System.Directory (makeAbsolute)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Hspec

-- | The repository root (petrus-test-support's, which fails loudly when
-- there is none).
repoRoot :: IO FilePath
repoRoot = TestSupport.repoRoot

-- | The pinned reference interpreter (@upstream/petrus-engine/.venv@,
-- provisioned by @scripts/upstream-python petrus-engine@ on first use) and
-- the repository root. Fails loudly, never skips, when the reference cannot
-- be provisioned.
referencePython :: IO (FilePath, FilePath)
referencePython = do
  python <- upstreamPythonExecutable "petrus-engine"
  root <- TestSupport.repoRoot
  pure (python, root)

withReference :: ((FilePath, FilePath) -> Expectation) -> Expectation
withReference body = referencePython >>= body

spec :: Spec
spec = describe "live differential against petrus-engine" $ do
  it "reproduces every committed verdict (the corpus is current)" $ withReference $ \(python, root) -> do
    corpus <- corpusPath >>= makeAbsolute
    cases <- readCorpus corpus
    (code, out, err) <-
      readProcessWithExitCode python [root </> script "reference.py", corpus] ""
    unless (code == ExitSuccess) $ expectationFailure ("reference.py failed: " <> err)
    let fresh = map parseLine (filter (not . null) (lines out))
    length fresh `shouldBe` length cases
    forM_ (zip cases fresh) $ \(c, (name, expect)) -> do
      name `shouldBe` c.name
      unless (expect == c.expect) $
        expectationFailure (T.unpack c.name <> ": the committed verdict is stale; rerun differential/corpus.py")

  seeds <- runIO (maybe ["1", "2", "3"] (splitOn ',') <$> lookupEnv "PETRUS_ENGINE_FILE_FUZZ_SEEDS")
  forM_ seeds $ \seed ->
    it ("agrees on 300 fresh fuzz cases with seed " <> seed) $ withReference $ \(python, root) ->
      withSystemTempDirectory "petrus-engine-file-fuzz" $ \dir -> do
        let out = dir </> "fuzz.json"
        (code, _, err) <-
          readProcessWithExitCode
            python
            [root </> script "corpus.py", "--fuzz-only", "--seed", seed, "--count", "300", "--out", out]
            ""
        unless (code == ExitSuccess) $ expectationFailure ("corpus.py failed: " <> err)
        readCorpus out >>= mapM_ checkCase

  it "net_file_schema.json is what petrus-cli gen-json-schema generates" $ withReference $ \(python, root) ->
    withSystemTempDirectory "petrus-engine-file-schema" $ \dir -> do
      let out = dir </> "net_file_schema.json"
      (code, _, err) <- readProcessWithExitCode python ["-m", "petrus.cli", "gen-json-schema", "-o", out] ""
      unless (code == ExitSuccess) $ expectationFailure ("gen-json-schema failed: " <> err)
      generated <- BS.readFile out
      committed <- BS.readFile (root </> "upstream" </> "petrus-engine" </> "src" </> "petrus" </> "net_file_schema.json")
      unless (generated == committed) $
        expectationFailure "upstream/petrus-engine/src/petrus/net_file_schema.json differs from what gen-json-schema generates at the pin"

  extra <- runIO (maybe [] (splitOn ',') <$> lookupEnv "PETRUS_ENGINE_FILE_CORPORA")
  forM_ extra $ \path -> do
    cases <- runIO (readCorpus path)
    describe path $ forM_ cases $ \c -> it (T.unpack c.name) (checkCase c)
  where
    script name = "packages" </> "petrus-engine-file" </> "differential" </> name
    splitOn ch = filter (not . null) . go
      where
        go s = case break (== ch) s of
          (a, []) -> [a]
          (a, _ : rest) -> a : go rest

-- | One @{"name", "expect"}@ line of @reference.py@.
parseLine :: String -> (Text, [Text])
parseLine line = fromMaybe (error ("bad reference line: " <> line)) $ do
  value <- either (const Nothing) Just (parseJson surrogateRefusingLoads (TE.encodeUtf8 (T.pack line)))
  J.String name <- J.lookupMember "name" value
  J.Array items <- J.lookupMember "expect" value
  expect <- traverse (\case J.String s -> Just s; _ -> Nothing) items
  pure (name, expect)
