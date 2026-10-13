-- | @tests/integration/host/test_qualification_setup_local.py@, case for
-- case (same names): the atomic push against a real local bare remote, the
-- setup orchestration with real fences, and the operator route with a fake
-- setup runner.
module QualificationSetupLocalSpec (spec) where

import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, void)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Python.Object (PyObject (..), pythonError)
import Hamsterdan.Host.PublicationQualification
import Hamsterdan.Operator (SetupCompleted (..), qualificationSetup)
import Support (at, encoded)
import System.Directory (canonicalizePath, doesPathExist)
import System.Environment (lookupEnv, unsetEnv)
import System.Environment qualified as Environment
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Directory (createDirectory)
import System.Posix.Files (setFileMode)
import System.Process.Typed
import Test.Hspec

firstOf :: [Text] -> Text
firstOf = \case
  first : _ -> first
  [] -> ""

remote :: Text
remote = "https://github.com/example/private-fixture.git"

-- | @git(cwd, *arguments)@: run, require success, strip stdout.
git :: FilePath -> [String] -> IO Text
git cwd arguments = do
  (code, out, err) <- readProcess (setWorkingDir cwd (proc "git" arguments))
  case code of
    ExitSuccess -> pure (T.strip (TE.decodeUtf8 (BL.toStrict out)))
    _ -> fail ("git " <> unwords arguments <> ": " <> BC.unpack (BL.toStrict err))

-- | @fixture(tmp_path)@: a work tree with a base commit and a head commit.
fixture :: FilePath -> IO (FilePath, Text, Text)
fixture tmp = do
  let work = tmp </> "work"
  createDirectory work 0o755
  void (git work ["init", "--quiet", "--initial-branch=main"])
  void (git work ["config", "user.name", "Qualification"])
  void (git work ["config", "user.email", "qualification@invalid"])
  writeFile (work </> "base") "base\n"
  void (git work ["add", "base"])
  void (git work ["commit", "--quiet", "-m", "base"])
  base <- git work ["rev-parse", "HEAD"]
  writeFile (work </> "head") "head\n"
  void (git work ["add", "head"])
  void (git work ["commit", "--quiet", "-m", "head"])
  head' <- git work ["rev-parse", "HEAD"]
  pure (work, base, head')

-- | Run the admitted command against the local bare remote instead.
localAdapter :: FilePath -> FilePath -> [Text] -> IO Int
localAdapter work bare command = do
  let local = map T.unpack (take 3 command) <> [bare] <> map T.unpack (drop 4 command)
  code <- runProcess (setStdout nullStream (setStderr nullStream (setWorkingDir work (proc (concat (take 1 local)) (drop 1 local)))))
  pure case code of
    ExitSuccess -> 0
    ExitFailure n -> n

custody :: FilePath -> String -> IO FilePath
custody tmp name = do
  let path = tmp </> name
  createDirectory path 0o700
  setFileMode path 0o700
  pure path

-- | @setup_orchestration(tmp_path, **overrides)@.
data Overrides = Overrides
  { overrideIdentity :: Maybe (IO Bool)
  , overrideRunner :: Maybe ([Text] -> IO Int)
  , overrideReadback :: Maybe (IO Bool)
  , overrideCleanup :: Maybe (IO Bool)
  }

noOverrides :: Overrides
noOverrides = Overrides Nothing Nothing Nothing Nothing

setupOrchestration :: FilePath -> Overrides -> IO (SetupQualificationResult, [Text], FilePath)
setupOrchestration tmp overrides = do
  directory <- custody tmp "orchestration-custody"
  calls <- newIORef []
  let record name = modifyIORef' calls (<> [name]) >> pure True
      orRecord name = maybe (record name) id
  outcome <-
    qualifySetup
      SetupSequence
        { onIdentity = orRecord "identity" overrides.overrideIdentity
        , onTarget = record "target"
        , onPrePush = record "pre_push"
        , pusher = atomicSetupPush (directory </> "spent")
        , remote
        , base = T.replicate 40 "a"
        , head = T.replicate 40 "b"
        , runner = maybe (\_ -> modifyIORef' calls (<> ["push"]) >> pure 0) id overrides.overrideRunner
        , onReadback = orRecord "readback" overrides.overrideReadback
        , onPullRequest = record "pull_request"
        , onCurrentCas = record "current_cas"
        , onStaleCas = record "stale_cas"
        , onCleanup = orRecord "cleanup" overrides.overrideCleanup
        }
  recorded <- readIORef calls
  pure (outcome, recorded, directory </> "spent")

timeoutExpired :: Text -> IO a
timeoutExpired detail = throwIO (pythonError "TimeoutExpired" detail)

-- | Set environment variables for the action, restoring them afterwards
-- (@monkeypatch.setenv@).
withEnvironment :: [(String, String)] -> IO a -> IO a
withEnvironment settings action =
  bracket (mapM (\(k, _) -> (k,) <$> lookupEnv k) settings) restore \_ -> mapM_ (uncurry Environment.setEnv) settings >> action
  where
    restore = mapM_ \(k, previous) -> maybe (unsetEnv k) (Environment.setEnv k) previous

spec :: Spec
spec = describe "tests/integration/host/test_qualification_setup_local.py" do
  it "test_actual_local_atomic_push_preserves_admitted_command_and_restart_fence" do
    withSystemTempDirectory "qualification-local" \tmp -> do
      (work, base, head') <- fixture tmp
      let bare = tmp </> "remote.git"
      void (git tmp ["init", "--bare", "--quiet", bare])
      parent <- custody tmp "custody"
      let marker = parent </> "spent"
      admitted <- newIORef []
      let adapter command = modifyIORef' admitted (<> [command]) >> localAdapter work bare command
      outcome <- push (atomicSetupPush marker) remote base head' adapter
      outcome.commandSucceeded `shouldBe` True
      readIORef admitted
        `shouldReturn` [["git", "push", "--atomic", remote, base <> ":refs/heads/main", head' <> ":refs/heads/hamsterdan/ds11-live-v4"]]
      git tmp ["--git-dir", bare, "rev-parse", "refs/heads/main"] `shouldReturn` base
      git tmp ["--git-dir", bare, "rev-parse", "refs/heads/hamsterdan/ds11-live-v4"] `shouldReturn` head'
      doesPathExist marker `shouldReturn` True

      replay <- push (atomicSetupPush marker) remote base head' adapter
      replay.category `shouldBe` Just AlreadySpent
      length <$> readIORef admitted `shouldReturn` 1
      doesPathExist marker `shouldReturn` True

  it "test_actual_local_atomic_rejection_creates_neither_requested_ref" do
    withSystemTempDirectory "qualification-local" \tmp -> do
      (work, base, head') <- fixture tmp
      let bare = tmp </> "remote.git"
      void (git tmp ["init", "--bare", "--quiet", bare])
      void (git work ["push", bare, T.unpack head' <> ":refs/heads/main"])
      parent <- custody tmp "custody"
      outcome <- push (atomicSetupPush (parent </> "spent")) remote base head' (localAdapter work bare)
      outcome.category `shouldBe` Just PushUnconfirmed
      git tmp ["--git-dir", bare, "rev-parse", "refs/heads/main"] `shouldReturn` head'
      code <-
        runProcess
          (setStdout nullStream (setStderr nullStream (proc "git" ["--git-dir", bare, "rev-parse", "--verify", "refs/heads/hamsterdan/ds11-live-v4"])))
      code `shouldNotBe` ExitSuccess

  it "test_timeout_before_spend_suppresses_push_readback_pr_and_cas" do
    withSystemTempDirectory "qualification-local" \tmp -> do
      let coordinate = "owner/private-timeout-coordinate"
      (outcome, calls, marker) <-
        setupOrchestration
          tmp
          noOverrides {overrideIdentity = Just (timeoutExpired ("Command 'gh api /repos/" <> coordinate <> "' timed out after 30 seconds: secret-canary"))}
      calls `shouldBe` ["cleanup"]
      doesPathExist marker `shouldReturn` False
      outcome.firstCausePhase `shouldBe` Just Identity
      outcome.firstCauseCategory `shouldBe` Just BoundaryUnavailable
      encoded (setupSanitized outcome) `shouldNotSatisfy` T.isInfixOf coordinate
      encoded (setupSanitized outcome) `shouldNotSatisfy` T.isInfixOf "secret-canary"

  it "test_timeout_after_spend_reads_back_once_never_retries_and_preserves_marker" do
    withSystemTempDirectory "qualification-local" \tmp -> do
      attempts <- newIORef (0 :: Int)
      readbacks <- newIORef (0 :: Int)
      (outcome, calls, marker) <-
        setupOrchestration
          tmp
          noOverrides
            { overrideRunner = Just \_ -> modifyIORef' attempts (+ 1) >> timeoutExpired "secret-canary coordinate-canary"
            , overrideReadback = Just (modifyIORef' readbacks (+ 1) >> pure False)
            }
      (,) <$> readIORef attempts <*> readIORef readbacks `shouldReturn` (1, 1)
      calls `shouldBe` ["identity", "target", "pre_push", "cleanup"]
      doesPathExist marker `shouldReturn` True
      outcome.firstCausePhase `shouldBe` Just Push
      outcome.firstCauseCategory `shouldBe` Just BoundaryUnavailable
      (outcome.pullRequest, outcome.currentCas, outcome.staleCas) `shouldBe` (Nothing, Nothing, Nothing)
      forM_ ["secret-canary", "coordinate-canary"] \canary -> encoded (setupSanitized outcome) `shouldNotSatisfy` T.isInfixOf canary

  it "test_exact_readback_admits_read_only_pr_current_and_stale_cas_in_order" do
    withSystemTempDirectory "qualification-local" \tmp -> do
      (outcome, calls, marker) <- setupOrchestration tmp noOverrides
      calls `shouldBe` ["identity", "target", "pre_push", "push", "readback", "pull_request", "current_cas", "stale_cas", "cleanup"]
      doesPathExist marker `shouldReturn` True
      setupAccepted outcome `shouldBe` True
      fmap (.confirmed) outcome.currentCas `shouldBe` Just True
      fmap (.confirmed) outcome.staleCas `shouldBe` Just True

  it "test_cleanup_uncertainty_does_not_replace_push_first_cause" do
    withSystemTempDirectory "qualification-local" \tmp -> do
      (outcome, _, _) <-
        setupOrchestration tmp noOverrides {overrideRunner = Just (\_ -> pure 1), overrideReadback = Just (pure False), overrideCleanup = Just (pure False)}
      outcome.firstCausePhase `shouldBe` Just Push
      outcome.firstCauseCategory `shouldBe` Just PushUnconfirmed
      outcome.cleanup.confirmed `shouldBe` False
      outcome.cleanup.category `shouldBe` Just ObservationUnconfirmed

  it "test_operator_route_isolates_environment_erases_private_material_and_retains_only_closed_evidence" do
    withSystemTempDirectory "qualification-local" \scratch -> do
      -- pytest's tmp_path is already resolved; the route requires the
      -- marker's parent to be its own resolved path.
      tmp <- canonicalizePath scratch
      directory <- custody tmp "custody"
      -- The route resolves gh on PATH before anything runs; the setup
      -- runner is fake, so a stand-in executable is all it needs.
      tools <- custody tmp "tools"
      writeFile (tools </> "gh") "#!/bin/sh\nexit 1\n"
      setFileMode (tools </> "gh") 0o700
      ambientPath <- maybe "/usr/bin:/bin" id <$> lookupEnv "PATH"
      let credential = directory </> "credential"
          targetFile = directory </> "target"
          marker = directory </> "spent"
          secret = "credential-secret-canary"
          coordinate = "owner/private-coordinate-canary"
          base = T.replicate 40 "a"
          head' = T.replicate 40 "b"
      BS.writeFile credential (TE.encodeUtf8 secret)
      BS.writeFile targetFile (TE.encodeUtf8 ("{\"repository\": \"" <> coordinate <> "\", \"account_id\": 7, \"repository_id\": 11}"))
      setFileMode credential 0o600
      setFileMode targetFile 0o600
      environments <- newIORef []
      commands <- newIORef []
      remoteState <- newIORef ([] :: [(Text, Text)])
      let fakeRunner command _cwd environment input = do
            modifyIORef' commands (<> [command])
            modifyIORef' environments (<> [environment])
            let stderr' = TE.encodeUtf8 (secret <> ":" <> coordinate <> ":private-diagnostic")
                executable = takeFileName (T.unpack (firstOf command))
                respond out = pure SetupCompleted {returncode = 0, stdout = out, stderr = stderr'}
            if input /= Nothing then fail "input bytes" else pure ()
            if lookup "GH_TOKEN" environment /= Just secret then fail "GH_TOKEN" else pure ()
            observed <- readIORef commands
            case () of
              _
                | executable == "gh" && drop 1 command == ["api", "/user"] -> respond "{\"id\":7}"
                | executable == "gh" && drop 1 command == ["api", "/repos/" <> coordinate] ->
                    respond
                      ( TE.encodeUtf8
                          ( "{\"full_name\": \""
                              <> coordinate
                              <> "\", \"id\": 11, \"private\": false, \"archived\": false, \"disabled\": false, \"size\": 0, \"default_branch\": \"main\", \"permissions\": {\"push\": true}}"
                          )
                      )
                | executable /= "git" -> fail ("unexpected " <> show command)
                | "rev-parse" `elem` command -> do
                    let value = if length (filter ("rev-parse" `elem`) observed) == 1 then base else head'
                    respond (TE.encodeUtf8 (value <> "\n"))
                | "ls-remote" `elem` command -> do
                    state <- readIORef remoteState
                    let names = drop 3 (dropWhile (/= "ls-remote") command)
                        output = if null names then state else [(n, v) | (n, v) <- state, n `elem` names]
                    respond (TE.encodeUtf8 (T.concat [v <> "\t" <> n <> "\n" | (n, v) <- output]))
                | otherwise -> do
                    if "push" `elem` command
                      then modifyIORef' remoteState (const [("refs/heads/main", base), ("refs/heads/hamsterdan/ds11-live-v4", head')])
                      else pure ()
                    respond "private-stdout-canary"
      result <-
        withEnvironment
          [ ("PATH", tools <> ":" <> ambientPath)
          , ("GH_TOKEN", "ambient-gh-token-canary")
          , ("GITHUB_TOKEN", "ambient-github-token-canary")
          , ("GIT_TRACE", "1")
          , ("GIT_CONFIG_GLOBAL", "/private/ambient-config")
          ]
          (qualificationSetup fakeRunner credential targetFile marker)
      let retained = encoded result
      case at "ok" result of
        PyBool True -> pure ()
        other -> expectationFailure ("ok: " <> show other <> " " <> T.unpack retained)
      doesPathExist marker `shouldReturn` True
      doesPathExist credential `shouldReturn` False
      doesPathExist targetFile `shouldReturn` False
      observedEnvironments <- readIORef environments
      let roots = [takeDirectory (T.unpack home) | environment <- observedEnvironments, Just home <- [lookup "HOME" environment]]
      roots `shouldNotBe` []
      forM_ roots \root -> doesPathExist root `shouldReturn` False
      forM_ observedEnvironments \environment -> do
        forM_ ["GITHUB_TOKEN", "GIT_TRACE", "GIT_CONFIG_COUNT"] \forbidden -> lookup forbidden environment `shouldBe` Nothing
        lookup "GIT_TERMINAL_PROMPT" environment `shouldBe` Just "0"
      observedCommands <- readIORef commands
      any (\command -> take 2 (drop 1 command) == ["auth", "login"]) observedCommands `shouldBe` False
      let gitCommands = [command | command <- observedCommands, takeFileName (T.unpack (firstOf command)) == "git"]
      gitCommands `shouldNotBe` []
      forM_ gitCommands \command -> do
        command `shouldSatisfy` elem "credential.helper="
        command `shouldSatisfy` elem "core.hooksPath=/dev/null"
        command `shouldSatisfy` elem "http.followRedirects=false"
      forM_ [secret, coordinate, "private-diagnostic", "private-stdout-canary", "ambient-gh-token-canary"] \canary ->
        retained `shouldNotSatisfy` T.isInfixOf canary
