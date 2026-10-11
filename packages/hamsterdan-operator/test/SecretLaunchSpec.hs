-- | @tests/unit/host/test_secret_launch.py@, case for case (same names),
-- against this repository's copy of @scripts/with-runtime-secrets@ (byte
-- for byte the reference's; ContainerSpec checks that). The fake @op@ and
-- the application child are modes of this test binary ("Fakes"); the child
-- reads the host configuration with hamsterdan-github's
-- @Hamsterdan.GitHub.Config.fromEnvironment@ and checks the Pi installation
-- variables @PiA2InstallationConfig.from_environment@ reads.
module SecretLaunchSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Monad (filterM, forM_, when)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fakes (wrapperScript)
import Petrus.Json (Json (..), defaultDumps, dumps)
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory (createDirectoryIfMissing, doesFileExist, findExecutable)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process.Typed
import System.Timeout (timeout)
import Test.Hspec

required :: [Text]
required =
  [ "HAMSTERDAN_GITHUB_APP_ID"
  , "HAMSTERDAN_GITHUB_APP_SLUG"
  , "HAMSTERDAN_GITHUB_CLIENT_ID"
  , "HAMSTERDAN_GITHUB_PRIVATE_KEY"
  , "HAMSTERDAN_GITHUB_WEBHOOK_SECRET"
  , "HAMSTERDAN_PI_API_KEY"
  ]

pem :: Text
pem = "-----BEGIN PRIVATE KEY-----\nfixture-only\n-----END PRIVATE KEY-----\n"

data Launch = Launch {missing :: Maybe Text, denied :: Bool, unusableHome :: Bool}

defaults :: Launch
defaults = Launch Nothing False False

data Result = Result {code :: ExitCode, out :: Text, err :: Text}

-- | @launch(tmp_path, missing=..., denied=..., unusable_home=...)@, under
-- the given bash, or through the script's own @#!/usr/bin/env bash@.
launch :: Maybe FilePath -> FilePath -> Launch -> IO Result
launch bash tmp options = do
  createDirectoryIfMissing True tmp
  root <- repoRoot
  binary <- getExecutablePath
  let source =
        filter
          ((/= options.missing) . Just . fst)
          [ ("HAMSTERDAN_GITHUB_APP_ID", "17")
          , ("HAMSTERDAN_GITHUB_APP_SLUG", "hamsterdan-test")
          , ("HAMSTERDAN_GITHUB_CLIENT_ID", "Iv1.explicit")
          , ("HAMSTERDAN_GITHUB_PRIVATE_KEY", pem)
          , ("HAMSTERDAN_GITHUB_WEBHOOK_SECRET", "current-webhook-secret")
          , ("HAMSTERDAN_PI_API_KEY", "current-api-key-canary")
          ]
      sourcePath = tmp </> "source.json"
      fakeOp = tmp </> "op"
      installations = tmp </> "installations.toml"
  BS.writeFile sourcePath (either (error . show) id (dumps defaultDumps (Object [(k, String v) | (k, v) <- source])))
  writeFile fakeOp (wrapperScript binary ["--fake-op"])
  setFileMode fakeOp 0o700
  BS.writeFile installations "[[accounts]]\nid=23\nlogin=\"owner\"\nrepositories=[\"31:owner/repo\"]\n"
  ambient <- getEnvironment
  when options.unusableHome $ writeFile (tmp </> "home") "home is unavailable"
  let overrides =
        [(T.unpack name, "stale-secret-canary") | name <- required]
          <> [ ("HAMSTERDAN_GITHUB_PRIVATE_KEY_FILE", "/stale/key")
             , ("HAMSTERDAN_PI_API_KEY_FILE", "/stale/key")
             , ("HAMSTERDAN_ENVIRONMENT_ID", replicate 26 'a')
             , ("HAMSTERDAN_OP_COMMAND", fakeOp)
             , ("OP_SA_HAMSTERDAN_DEV", "loader-only-canary")
             , ("OP_SA_HAMSTERDAN_OPS", "must-not-inherit")
             , ("OP_SERVICE_ACCOUNT_TOKEN", "unrelated-loader-must-not-win")
             , ("OPENAI_API_KEY", "must-not-inherit")
             , ("GH_TOKEN", "must-not-inherit")
             , ("HAMSTERDAN_GITHUB_INSTALLATIONS_FILE", installations)
             , ("HAMSTERDAN_STATE_PATH", tmp </> "state")
             , ("HAMSTERDAN_PI_PROVIDER", "openai")
             , ("HAMSTERDAN_PI_MODEL", "gpt-5.6-sol")
             , ("HAMSTERDAN_PI_CLI_PATH", tmp </> "cli")
             , ("HAMSTERDAN_PI_NODE_PATH", tmp </> "node")
             , ("HAMSTERDAN_PI_PACKAGE_ROOT", tmp </> "package")
             , ("TEST_SOURCE", sourcePath)
             , ("TEST_FETCH_COUNTER", tmp </> "fetch-count")
             , ("TEST_DENIED", if options.denied then "1" else "0")
             , ("HOME", tmp </> "home")
             ]
          <> [("OP_CONFIG_DIR", tmp </> "temporary-cli-config") | options.unusableHome]
      environment =
        Map.toList
          ( Map.union
              (Map.fromList overrides)
              (foldr Map.delete (Map.fromList ambient) ["HAMSTERDAN_OP_TOKEN_FILE", "OP_CONFIG_DIR"])
          )
      config =
        setWorkingDir root
          . setEnv environment
          . setStdin nullStream
          $ let script = root </> "scripts" </> "with-runtime-secrets"
             in maybe (proc script [binary, "--launch-child"]) (\b -> proc b [script, binary, "--launch-child"]) bash
  finished <- timeout 10000000 (readProcess config)
  case finished of
    Nothing -> fail "with-runtime-secrets timed out"
    Just (status, stdout', stderr') ->
      pure Result {code = status, out = decode stdout', err = decode stderr'}
  where
    decode = TE.decodeUtf8 . BL.toStrict

-- | Bash before 4.4 cannot expand the launcher's empty @op_config@ array
-- under @set -u@ (macOS ships 3.2), so a start without @OP_CONFIG_DIR@
-- needs a newer bash; the reference test fails the same way there.
-- Production images run bash 5. These examples run the launcher under the
-- first bash of at least 4.4 among @$PETRUS_BASH@ (which, when set, must be
-- one), @bash@ on the PATH, and Homebrew's (@/opt/homebrew/bin/bash@,
-- @/usr/local/bin/bash@), and fail when there is none.
withModernBash :: (FilePath -> IO ()) -> IO ()
withModernBash action =
  lookupEnv "PETRUS_BASH" >>= \case
    Just override -> do
      modern <- isModernBash override
      if modern
        then action override
        else expectationFailure ("PETRUS_BASH=" <> override <> " is not a bash of version 4.4 or later")
    Nothing -> do
      onPath <- findExecutable "bash"
      found <- filterM isModernBash (maybe id (:) onPath ["/opt/homebrew/bin/bash", "/usr/local/bin/bash"])
      case found of
        bash : _ -> action bash
        [] ->
          expectationFailure
            "scripts/with-runtime-secrets needs bash 4.4 or later, and none was found (macOS ships 3.2): \
            \install one (Homebrew: brew install bash) or set PETRUS_BASH to its path; see docs/reproducing.md"

isModernBash :: FilePath -> IO Bool
isModernBash path = do
  present <- doesFileExist path
  if not present
    then pure False
    else do
      answer <- try (readProcessStdout (proc path ["-c", "echo $((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1]))"]))
      pure $ case answer of
        Right (ExitSuccess, version) -> maybe False (>= (404 :: Int)) (readMaybeInt (BL.toStrict version))
        Right _ -> False
        Left (_ :: SomeException) -> False
  where
    readMaybeInt bytes = case reads (T.unpack (T.strip (TE.decodeUtf8 bytes))) of
      [(n, "")] -> Just n
      _ -> Nothing

spec :: Spec
spec = describe "tests/unit/host/test_secret_launch.py" do
  it "test_launcher_refreshes_multiline_values_and_excludes_bootstrap_from_application" $ withModernBash \bash ->
    withSystemTempDirectory "secret-launch" \tmp -> do
      result <- launch (Just bash) (tmp </> "case") defaults
      (result.code, result.err) `shouldBe` (ExitSuccess, "")
      result.out `shouldBe` "current credentials accepted\n"

  it "test_each_application_start_fetches_current_environment" $ withModernBash \bash ->
    withSystemTempDirectory "secret-launch" \tmp -> do
      first <- launch (Just bash) (tmp </> "case") defaults
      second <- launch (Just bash) (tmp </> "case") defaults
      (first.code, second.code) `shouldBe` (ExitSuccess, ExitSuccess)
      BS.readFile (tmp </> "case" </> "fetch-count") `shouldReturn` "2"

  it "test_temporary_cli_configuration_allows_start_without_a_writable_home" do
    withSystemTempDirectory "secret-launch" \tmp -> do
      result <- launch Nothing (tmp </> "case") defaults {unusableHome = True}
      (result.code, result.err) `shouldBe` (ExitSuccess, "")
      result.out `shouldBe` "current credentials accepted\n"

  describe "test_missing_environment_variable_cannot_fall_back_to_ambient_authority" do
    forM_ required \name ->
      it (T.unpack name) $ withModernBash \bash ->
        withSystemTempDirectory "secret-launch" \tmp -> do
          result <- launch (Just bash) (tmp </> "case") defaults {missing = Just name}
          result.code `shouldNotBe` ExitSuccess
          result.out `shouldBe` ""
          result.err `shouldNotSatisfy` T.isInfixOf "stale-secret-canary"

  it "test_retrieval_failure_prevents_application_start" $ withModernBash \bash ->
    withSystemTempDirectory "secret-launch" \tmp -> do
      result <- launch (Just bash) (tmp </> "case") defaults {denied = True}
      result.code `shouldBe` ExitFailure 23
      (result.out, result.err) `shouldBe` ("", "")
