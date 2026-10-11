-- | The @petrus@ CLI: argument parsing, and a port of
-- tests/petrusCli.test.mjs against the built executable.
module CliSpec (spec) where

import Data.List (isInfixOf)
import Data.Text qualified as T
import Petrus.Viewer.Cli
import Petrus.Viewer.UiDir (locateUiDir, uiDirCandidates)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Hspec

start :: [String] -> Maybe CliArgs
start argv = case parseCliArgs argv of
  Start a -> Just a
  _ -> Nothing

-- | @petrus@ comes from the test suite's build-tool-depends (on PATH).
runExe :: [String] -> IO (ExitCode, String, String)
runExe args = readProcessWithExitCode "petrus" args ""

spec :: Spec
spec = do
  describe "parseCliArgs" $ do
    it "has bin/petrus.mjs semantics: --help wins, unknown dashes are ignored, last positional wins" $ do
      parseCliArgs ["a.json", "--help", "--bogus"] `shouldBe` ShowHelp
      parseCliArgs ["-h"] `shouldBe` ShowHelp
      fmap argFile (start ["--weird", "a.json", "b.json"]) `shouldBe` Just (Just "b.json")
      fmap argUrl (start ["https://github.com/o/r/blob/m/x.json"]) `shouldBe` Just (Just "https://github.com/o/r/blob/m/x.json")
      fmap argNoOpen (start ["--no-open"]) `shouldBe` Just True
    it "parses the server options" $ do
      let parsed = start ["--port", "0", "--strict-port", "--host=::", "--ui-dir", "dist", "--observation", "http://a", "--observation=http://b"]
      fmap argPort parsed `shouldBe` Just (Just 0)
      fmap argStrictPort parsed `shouldBe` Just True
      fmap argHost parsed `shouldBe` Just (Just "::")
      fmap argUiDir parsed `shouldBe` Just (Just "dist")
      fmap argObservation parsed `shouldBe` Just ["http://a", "http://b"]
      parseCliArgs ["--port", "70000"] `shouldBe` BadOption "invalid port: 70000"
      parseCliArgs ["--port"] `shouldBe` BadOption "option --port requires a value"
    it "keeps the upstream help text first" $
      T.lines helpText `shouldStartWith` ["Usage: petrus [options] [file | url]", "", "Options:", "  --no-open    Don't open the browser automatically"]

  describe "the UI directory found next to the executable" $ do
    it "looks in an installed share/ directory, then in the checkout's upstream/petrus-viewer/dist" $
      take 4 (uiDirCandidates ["/opt/p/bin"])
        `shouldBe` ["/opt/p/share/petrus-viewer/ui", "/opt/p/bin/upstream/petrus-viewer/dist", "/opt/p/upstream/petrus-viewer/dist", "/opt/upstream/petrus-viewer/dist"]
    it "finds the build whatever the working directory, and only a build" $ withSystemTempDirectory "petrus-ui-dir-" $ \tmp -> do
      let bin = tmp </> "repo" </> "dist-newstyle" </> "build" </> "x" </> "petrus"
          dist = tmp </> "repo" </> "upstream" </> "petrus-viewer" </> "dist"
          share = tmp </> "repo" </> "dist-newstyle" </> "build" </> "x" </> "share" </> "petrus-viewer" </> "ui"
      createDirectoryIfMissing True bin
      createDirectoryIfMissing True dist
      locateUiDir [bin] `shouldReturn` Nothing
      writeFile (dist </> "index.html") "<!doctype html>"
      locateUiDir [bin] `shouldReturn` Just dist
      createDirectoryIfMissing True share
      writeFile (share </> "index.html") "<!doctype html>"
      locateUiDir [bin] `shouldReturn` Just share

  describe "petrus executable (tests/petrusCli.test.mjs)" $ do
    it "--help prints usage and exits 0" $ do
      (code, out, _) <- runExe ["--help"]
      code `shouldBe` ExitSuccess
      out `shouldSatisfy` isInfixOf "Usage:"
      out `shouldSatisfy` isInfixOf "petrus"
    it "-h prints usage and exits 0" $ do
      (code, out, _) <- runExe ["-h"]
      code `shouldBe` ExitSuccess
      out `shouldSatisfy` isInfixOf "Usage:"
    it "nonexistent file exits with error" $ do
      (code, _, err) <- runExe ["/nonexistent/file.json"]
      code `shouldBe` ExitFailure 1
      err `shouldBe` "Error: file not found: /nonexistent/file.json\n"
    it "URL argument is detected as a URL, not a file path" $ do
      (code, _, err) <- runExe ["--no-open", "http://127.0.0.1:9/nonexistent/repo/main/file.json"]
      code `shouldBe` ExitFailure 1
      err `shouldNotSatisfy` isInfixOf "file not found"
      err `shouldSatisfy` isInfixOf "Error"
    it "--help mentions URL support" $ do
      (_, out, _) <- runExe ["--help"]
      out `shouldSatisfy` isInfixOf "https://"
