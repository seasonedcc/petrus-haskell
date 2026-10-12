-- | The Worker process entry point: argument parsing and validation
-- (@_cli.py@), its package-boundary contract
-- (@tests/project/test_package_boundaries.py@), the queue defaulting
-- (@test_worker_topology.py::TestActivityRegistry@), and the exact help,
-- usage-error, and refusal output and exit statuses against the pinned
-- reference.
module Petrus.Motus.WorkerCliSpec (spec) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Motus.Dispatch.LocalSupport (withReference, withScratch)
import Petrus.Argparse (Formatting (..), Outcome (..), parse, parser, pythonFloat, pythonInt)
import Petrus.Argparse.Parser (formatHelp, plainTheme)
import Petrus.Motus.Worker.Cli
import Petrus.Motus.WorkerSupport (workerModeVariable)
import System.Directory (doesFileExist)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process
import Test.Hspec

-- | The reference's own subprocess registry, importable from its root.
registry :: String
registry = "tests.petrus.motus.worker.test_worker_runtime:subprocess_activities"

referenceProg :: Text
referenceProg = "python -m petrus.motus.worker"

parseWorker :: [String] -> WorkerArguments
parseWorker argv = case parse Formatting {width = 78, theme = plainTheme} (workerParser "petrus-worker" Nothing) (map T.pack argv) of
  Parsed arguments -> arguments
  Exited status out err -> error (show (status, out, err))

-- | Run this test binary as the worker entry point (program name: the
-- reference's), answering exit status, stdout, and stderr.
runWorkerCli :: [(String, String)] -> [String] -> IO (ExitCode, String, String)
runWorkerCli extraEnvironment argv = do
  self <- getExecutablePath
  environment <- getEnvironment
  let cleaned = filter (\(k, _) -> k `notElem` (workerModeVariable : ambient ++ map fst extraEnvironment)) environment
  readCreateProcessWithExitCode
    (proc self (argv ++ ["+RTS", "-M2G", "-RTS"])) {env = Just ((workerModeVariable, "reference-prog") : extraEnvironment ++ cleaned)}
    ""

-- | The reference's module entry point, same arguments.
runReference :: (FilePath, FilePath) -> [(String, String)] -> [String] -> IO (ExitCode, String, String)
runReference (python, root) extraEnvironment argv = do
  environment <- getEnvironment
  let cleaned = filter (\(k, _) -> k `notElem` (ambient ++ map fst extraEnvironment)) environment
  readCreateProcessWithExitCode (proc python ("-m" : "petrus.motus.worker" : argv)) {cwd = Just root, env = Just (extraEnvironment ++ cleaned)} ""

-- | The variables of this environment that would change the output: the
-- tests set them explicitly.
ambient :: [String]
ambient = ["IMPETUS_DSN", "COLUMNS", "FORCE_COLOR", "NO_COLOR", "PYTHON_COLORS", "TERM"]

spec :: Spec
spec = do
  describe "test_package_boundaries.py" $
    it "worker package public contract and module cli" $ do
      let help = formatHelp Formatting {width = 78, theme = plainTheme} (parser (workerParser referenceProg Nothing))
      ("usage: " <> referenceProg) `T.isPrefixOf` help `shouldBe` True
      "--queue" `T.isInfixOf` help `shouldBe` True
      "zeromq" `T.isInfixOf` help `shouldBe` True
      "--capability" `T.isInfixOf` help `shouldBe` False

  describe "main defaults queue and preserves deduplicated flag order" $
    forM_ [([], ["default"]), (["--queue", "one", "--queue", "two", "--queue", "one"], ["one", "two"])] $ \(flags, expected) ->
      it (show flags) $
        subscribedQueues (parseWorker (["--provider", "absurd", "--dsn", "postgresql:///unused", "--registry", "fake:registry"] ++ flags))
          `shouldBe` (expected :: [Text])

  describe "provider argument validation" $ do
    let validate argv = validateProviderArguments (parseWorker argv)
    it "local requires a path and rejects a DSN, an endpoint, and certificates" $ do
      validate ["--provider", "local", "--registry", "a:b"]
        `shouldBe` Left "Local provider requires --path and rejects --dsn/$IMPETUS_DSN and --endpoint"
      validate ["--provider", "local", "--registry", "a:b", "--path", "p", "--endpoint", "ipc:///x"]
        `shouldBe` Left "Local provider requires --path and rejects --dsn/$IMPETUS_DSN and --endpoint"
      validate ["--provider", "local", "--registry", "a:b", "--path", "p", "--client-secret-certificate", "c"]
        `shouldBe` Left "Local provider rejects ZeroMQ CURVE certificates"
      validate ["--provider", "local", "--registry", "a:b", "--path", "p"] `shouldBe` Right ()
    it "absurd requires a DSN and rejects a path, an endpoint, and certificates" $ do
      validate ["--provider", "absurd", "--registry", "a:b"]
        `shouldBe` Left "Absurd provider requires --dsn (or $IMPETUS_DSN) and rejects --path and --endpoint"
      validate ["--provider", "absurd", "--registry", "a:b", "--dsn", "d", "--server-public-certificate", "s"]
        `shouldBe` Left "Absurd provider rejects ZeroMQ CURVE certificates"
    it "zeromq requires an endpoint and rejects a path and a DSN" $ do
      validate ["--provider", "zeromq", "--registry", "a:b", "--endpoint", "e", "--dsn", "d"]
        `shouldBe` Left "ZeroMQ provider requires --endpoint and rejects --path and --dsn/$IMPETUS_DSN"
      validate ["--provider", "zeromq", "--registry", "a:b", "--endpoint", "e"] `shouldBe` Right ()
    it "native access requires async zeromq and the socket bound requires native access" $ do
      validate ["--provider", "zeromq", "--registry", "a:b", "--endpoint", "e", "--custody-access", "native-zeromq"]
        `shouldBe` Left "native-zeromq custody access requires async execution with the zeromq provider"
      validate ["--provider", "zeromq", "--registry", "a:b", "--endpoint", "e", "--custody-access", "native-zeromq", "--execution-mode", "async"]
        `shouldBe` Right ()
      validate ["--provider", "zeromq", "--registry", "a:b", "--endpoint", "e", "--max-operation-sockets", "9"]
        `shouldBe` Left "--max-operation-sockets applies only to native-zeromq custody access"

  describe "argparse conversions" $ do
    it "spells int() and float() acceptance" $ do
      map pythonInt [" 7 ", "+3", "1_000", "-2", "1__0", "_1", "x", "1.5", ""] `shouldBe` [Just 7, Just 3, Just 1000, Just (-2), Nothing, Nothing, Nothing, Nothing, Nothing]
      map pythonFloat ["0.25", "1e3", ".5", "5.", "-inf", "1_0.5"] `shouldBe` [Just 0.25, Just 1000, Just 0.5, Just 5, Just (-1 / 0), Just 10.5]
      map pythonFloat ["x", "1e", "."] `shouldBe` [Nothing, Nothing, Nothing]

  describe "process entry point" $ do
    it "exits 1 with the refusal when the provider arguments are invalid, before building custody" $ withScratch $ \dir -> do
      let path = dir </> "never.db"
      (code, _, err) <- runWorkerCli [("IMPETUS_DSN", "postgresql:///x")] ["--provider", "local", "--path", path, "--registry", registry]
      code `shouldBe` ExitFailure 1
      err `shouldBe` "Local provider requires --path and rejects --dsn/$IMPETUS_DSN and --endpoint\n"
      doesFileExist path `shouldReturn` False
    it "exits 1 when the sync mode is given a concurrency" $ withScratch $ \dir -> do
      (code, _, err) <- runWorkerCli [] ["--provider", "local", "--path", dir </> "d.db", "--registry", "tests.petrus.motus.worker.test_worker_runtime:subprocess_activities", "--concurrency", "2"]
      (code, err) `shouldBe` (ExitFailure 1, "--concurrency applies only to --execution-mode async\n")
    it "exits 1 on a malformed registry spelling" $ do
      (code, _, err) <- runWorkerCli [] ["--provider", "local", "--path", "x.db", "--registry", "nocolon"]
      (code, err) `shouldBe` (ExitFailure 1, "--registry must be 'module:attribute', got 'nocolon'\n")

  describe "against the reference" $ do
    let comparedWith check extraEnvironment argv = withReference $ \python -> do
          ours <- runWorkerCli extraEnvironment argv
          theirs <- runReference python extraEnvironment argv
          ours `shouldBe` theirs
          ours `shouldSatisfy` check
        compareWith = comparedWith (const True)
        colored (_, out, err) = "\ESC[" `isInfixOf` (out <> err)
    it "help is byte-identical" $ comparedWith (not . colored) [] ["--help"]
    it "help wraps to COLUMNS as the reference's" $ compareWith [("COLUMNS", "52")] ["--help"]
    it "FORCE_COLOR colors the help and the usage error as the reference's" $ do
      comparedWith colored [("FORCE_COLOR", "1")] ["--help"]
      comparedWith colored [("FORCE_COLOR", "1")] ["--provider", "x"]
    it "NO_COLOR overrides FORCE_COLOR as in the reference" $
      comparedWith (not . colored) [("FORCE_COLOR", "1"), ("NO_COLOR", "1")] ["--help"]
    it "a missing required option is the same usage error" $ compareWith [] []
    it "an invalid choice is the same usage error" $ compareWith [] ["--provider", "x"]
    it "an invalid int is the same usage error" $ compareWith [] ["--provider", "local", "--registry", "a:b", "--concurrency", "x"]
    it "an ambiguous abbreviation is the same usage error" $ compareWith [] ["--provider", "local", "--registry", "a:b", "--c", "3"]
    it "a missing value is the same usage error" $ compareWith [] ["--provider", "local", "--registry"]
    it "an unrecognized argument is the same usage error" $ compareWith [] ["--provider", "local", "--registry", "a:b", "foo", "--bar"]
    it "an abbreviation and an equals value parse as the reference's" $
      compareWith [] ["--prov=zeromq", "--reg", registry, "--endpoint", "ipc:///x", "--path=p"]
    it "the provider refusal and the sync concurrency refusal match" $ do
      compareWith [("IMPETUS_DSN", "postgresql:///x")] ["--provider", "local", "--path", "p", "--registry", registry]
      compareWith [] ["--provider", "zeromq", "--endpoint", "ipc:///x", "--max-operation-sockets", "3", "--registry", registry]
