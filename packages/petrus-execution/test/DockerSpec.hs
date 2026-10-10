-- | Docker provider.  Every upstream Docker test runs against the committed
-- fake CLI (@test/fixtures/fake_docker.py@); with @PETRUS_TEST_DOCKER=1@
-- the shared ones also run against the real @docker@ CLI.
module DockerSpec (spec, realDockerEnabled) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, finally, throwIO, try)
import Control.Monad (forM_)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..), lookupMember, parseJson, pythonLoads)
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, workspaceArchive)
import Petrus.Motus.Execution.Artifacts
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import Petrus.Motus.Execution.Providers.Docker
import Support
import System.Directory (createDirectory, doesDirectoryExist, makeAbsolute)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.Posix.Process (getProcessID)
import System.Process (readProcessWithExitCode)
import Test.Hspec

postgresImage :: Text
postgresImage = "postgres:17.5-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa"

realDockerEnabled :: IO Bool
realDockerEnabled = (== Just "1") <$> lookupEnv "PETRUS_TEST_DOCKER"

data Backend = Backend
  { backendExecutable :: FilePath
  , backendImage :: Text
  }

rightOr :: (Show e) => Either e a -> a
rightOr = either (error . show) id

cmd :: [Text] -> Command
cmd argv = rightOr (mkCommand (commandSpec argv))

cmdWith :: [Text] -> (CommandSpec -> CommandSpec) -> Command
cmdWith argv f = rightOr (mkCommand (f (commandSpec argv)))

imageSpec :: Text -> [Capability] -> EnvironmentSpec
imageSpec image capabilities = rightOr (mkEnvironmentSpec (Just image) capabilities)

newProvider :: Backend -> IO (DockerEnvironment, EnvironmentProvider)
newProvider backend = do
  env <- newDockerEnvironmentWith defaultDockerConfig {dockerExecutable = backendExecutable backend}
  pure (env, dockerProvider env)

cli :: Backend -> [String] -> IO String
cli backend args = do
  (code, out, err) <- readProcessWithExitCode (backendExecutable backend) args ""
  case code of
    ExitSuccess -> pure out
    ExitFailure n -> fail ("docker " <> unwords args <> " failed (" <> show n <> "): " <> err)

attachDir :: EnvironmentProvider -> EnvironmentLease -> FilePath -> Text -> IO ExecutionAttachment
attachDir provider lease directory digest = do
  archive <- workspaceArchive directory
  providerAttach provider lease archive digest

-- | Run with a fresh fake-docker state directory.
withFakeDocker :: (Backend -> IO a) -> IO a
withFakeDocker action = withTempDir $ \tmp -> do
  executable <- makeAbsolute "test/fixtures/fake_docker.py"
  bracket
    (setEnv "DOCKER_FAKE_STATE" (tmp <> "/docker-state"))
    (const (mapM_ unsetEnv ["DOCKER_FAKE_STATE", "DOCKER_FAKE_FAIL", "DOCKER_FAKE_RM_NOOP", "DOCKER_FAKE_BIND", "DOCKER_FAKE_LOG", "DOCKER_FAKE_RUN_UNLABELED"]))
    (const (action (Backend executable "fake/image:1")))

withRealDocker :: (Backend -> IO a) -> IO a
withRealDocker action = do
  image <- fromMaybe postgresImage . fmap T.pack <$> lookupEnv "PETRUS_TEST_DOCKER_IMAGE"
  action (Backend "docker" image)

uniqueSuffix :: FilePath -> Text
uniqueSuffix seed = T.take 16 (T.pack (show (hash (BC.pack seed) :: Digest SHA256)))

spec :: Spec
spec = do
  describe "docker provider (fake CLI)" $ do
    sharedSpec withFakeDocker
    fakeOnlySpec
  describe "docker provider (real CLI, PETRUS_TEST_DOCKER=1)" $ do
    enabled <- runIO realDockerEnabled
    if enabled
      then sharedSpec withRealDocker
      else it "runs the shared Docker tests against a real daemon" $
        pendingWith "skipped: set PETRUS_TEST_DOCKER=1 (and optionally PETRUS_TEST_DOCKER_IMAGE) to run against a real Docker daemon"

sharedSpec :: ((Backend -> IO ()) -> IO ()) -> Spec
sharedSpec withBackend = do
  it "test_provider_neutral_lifecycle_and_environment_custody[docker]" $ withBackend $ \backend -> withTempDir $ \tmp -> do
    (_, provider) <- newProvider backend
    pid <- getProcessID
    lease <-
      providerCreate provider ("cv10-lifecycle-" <> uniqueSuffix tmp <> "-" <> T.pack (show pid)) $
        imageSpec (backendImage backend) [capContainer, capExplicitEnvironment]
    ( do
        let source = tmp <> "/source"
        createDirectory source
        attachment <- attachDir provider lease source "input-digest"
        bracket (setEnv "GITHUB_TOKEN" "should-never-cross-the-door") (const (unsetEnv "GITHUB_TOKEN")) $ \_ -> do
          leaseState lease `shouldBe` Ready
          providerLookup provider (leaseOperationId lease) `shouldReturn` Just lease
          result <-
            providerExecute provider attachment $
              cmdWith
                ["/bin/sh", "-c", "printf '%s|%s' \"$ALLOWED\" \"${GITHUB_TOKEN-unset}\" > result; cat result"]
                (\c -> c {specEnvironment = [("ALLOWED", "yes")]})
          resultReturncode result `shouldBe` 0
          resultStdout result `shouldBe` "yes|unset"
          provenanceOperationId (resultProvenance result) `shouldBe` leaseOperationId lease
          let restored = tmp <> "/restored"
          exported <- providerExport provider attachment
          extractWorkspaceArchive exported restored
          B.readFile (restored <> "/result") `shouldReturn` "yes|unset"
          superseded <-
            providerExecute provider attachment (cmdWith ["/bin/sh", "-c", "exit 99"] (\c -> c {specIsCurrent = Just (pure False)}))
          resultSuperseded superseded `shouldBe` True
          timedOut <- providerExecute provider attachment (cmdWith ["/bin/sh", "-c", "sleep 10"] (\c -> c {specTimeout = Just 0.1}))
          resultTimedOut timedOut `shouldBe` True
      )
      `finally` providerDestroy provider lease
    _ <- providerDestroy provider lease
    providerLookup provider (leaseOperationId lease) `shouldReturn` Nothing

  it "test_docker_lookup_first_survives_adapter_recreation_and_is_unique" $ withBackend $ \backend -> withTempDir $ \tmp -> do
    pid <- getProcessID
    let operation = "cv10-recreate-" <> uniqueSuffix tmp <> "-" <> T.pack (show pid)
        same = imageSpec (backendImage backend) []
    (_, first) <- newProvider backend
    lease <- providerCreate first operation same
    ( do
        (_, recreated) <- newProvider backend
        providerCreate recreated operation same `shouldReturn` lease
        attachment <- attachDir recreated lease tmp "digest"
        (resultReturncode <$> providerExecute recreated attachment (cmd ["/bin/sh", "-c", "printf recreated > state"])) `shouldReturn` 0
        errorMatching (providerCreate recreated operation (imageSpec "materially-different" [])) ValueError "collides"
        found <- words <$> cli backend ["ps", "-aq", "--filter", "label=run.petrus.operation=" <> T.unpack operation]
        found `shouldBe` [T.unpack (leaseId lease)]
        info <- cli backend ["inspect", T.unpack (leaseId lease)]
        bindMounts info `shouldBe` 0
        _ <- cli backend ["stop", T.unpack (leaseId lease)]
        (reconcileClassification <$> providerReconcile recreated operation) `shouldReturn` ReconcileTerminal
        errorMatching (providerCreate recreated operation same) RuntimeError "terminal prior territory"
      )
      `finally` providerDestroy first lease

  it "test_docker_public_lifecycle_is_lookup_first_and_cleanup_is_identity_correlated" $ withBackend $ \backend -> withTempDir $ \tmp -> do
    (_, provider) <- newProvider backend
    let operation = "cv16-docker-" <> uniqueSuffix tmp
        wanted = imageSpec (backendImage backend) [capContainer, capTerritoryCancellation]
    lease <- providerCreate provider operation wanted
    outcome <- try $ do
      (_, other) <- newProvider backend
      (leaseIdentity <$> providerCreate other operation wanted) `shouldReturn` leaseIdentity lease
      let stale = rightOr (mkEnvironmentLease operation (leaseProvider lease) "different-container" (leaseCapabilities lease) (leaseState lease))
      (cleanupDisposition <$> providerDestroy provider stale) `shouldReturn` Unverified
      (fmap leaseIdentity <$> providerLookup provider operation) `shouldReturn` Just (leaseIdentity lease)
      attachment <- attachDir provider lease tmp "input-digest"
      result <- providerExecute provider attachment (cmd ["/bin/sh", "-c", "printf docker > result"])
      resultReturncode result `shouldBe` 0
      provenanceIdentity (resultProvenance result) `shouldBe` leaseIdentity lease
    cleanup <- providerDestroy provider lease
    either (throwIO :: SomeException -> IO ()) pure outcome
    cleanupDisposition cleanup `shouldBe` Clean
    cleanupVerified cleanup `shouldBe` True
    providerLookup provider operation `shouldReturn` Nothing
    (reconcileClassification <$> providerReconcile provider operation) `shouldReturn` ReconcileRetryable

  it "cancel kills the territory and the lease becomes terminal" $ withBackend $ \backend -> withTempDir $ \tmp -> do
    (_, provider) <- newProvider backend
    let operation = "cv16-cancel-" <> uniqueSuffix tmp
    lease <- providerCreate provider operation (imageSpec (backendImage backend) [])
    ( do
        providerCancel provider lease "operator"
        waitFor ((== Just Terminal) . fmap leaseState <$> providerLookup provider operation)
        (reconcileClassification <$> providerReconcile provider operation) `shouldReturn` ReconcileTerminal
        attachDir provider lease tmp "digest"
          `shouldThrowMessage` (ValueError, "attachment lease is not a current ready Docker territory")
      )
      `finally` providerDestroy provider lease

  it "test_cross_provider_workspace_handoff_has_no_shared_path" $ withBackend $ \backend -> withTempDir $ \tmp -> do
    pid <- T.pack . show <$> getProcessID
    let source = tmp <> "/source"
    createDirectory source
    B.writeFile (source <> "/history") "source"
    initial <- workspaceArchive source
    local <- localProvider <$> newLocalProcessEnvironment
    localLease <- providerCreate local ("handoff-local-" <> uniqueSuffix tmp <> "-" <> pid) (rightOr (mkEnvironmentSpec Nothing []))
    localAttachment <- providerAttach local localLease initial "source"
    _ <- providerExecute local localAttachment (cmd ["/bin/sh", "-c", "printf -- '-local' >> history"])
    let localWorkspace = attachmentWorkspace localAttachment
    store <- newArtifactStore (tmp <> "/store")
    exported <- providerExport local localAttachment
    ref <-
      putArtifact store exported "application/x-tar" "handoff" $
        ProducerCorrelation (leaseOperationId localLease) (leaseProvider localLease) (leaseId localLease)
    _ <- providerDestroy local localLease
    doesDirectoryExist localWorkspace `shouldReturn` False

    (_, docker) <- newProvider backend
    dockerLease <- providerCreate docker ("handoff-docker-" <> uniqueSuffix tmp <> "-" <> pid) (imageSpec (backendImage backend) [])
    final <-
      ( do
          payload <- readArtifact store ref
          dockerAttachment <- providerAttach docker dockerLease payload (artifactDigest ref)
          attachmentWorkspace dockerAttachment `shouldNotBe` localWorkspace
          result <- providerExecute docker dockerAttachment (cmd ["/bin/sh", "-c", "cat history; printf -- '-docker' >> history"])
          resultStdout result `shouldBe` "source-local"
          archive <- providerExport docker dockerAttachment
          info <- cli backend ["inspect", T.unpack (leaseId dockerLease)]
          bindMounts info `shouldBe` 0
          pure archive
      )
        `finally` providerDestroy docker dockerLease
    providerLookup docker (leaseOperationId dockerLease) `shouldReturn` Nothing
    let restored = tmp <> "/restored"
    extractWorkspaceArchive final restored
    B.readFile (restored <> "/history") `shouldReturn` "source-local-docker"

waitFor :: IO Bool -> IO ()
waitFor condition = go (50 :: Int)
  where
    go 0 = expectationFailure "condition never became true"
    go n = condition >>= \ok -> if ok then pure () else threadDelay 100000 >> go (n - 1)

bindMounts :: String -> Int
bindMounts info = case parseJson pythonLoads (BC.pack info) of
  Right (Array (item : _)) -> case lookupMember "Mounts" item of
    Just (Array mounts) -> length [() | m <- mounts, lookupMember "Type" m == Just (String "bind")]
    _ -> 0
  _ -> error "unexpected inspect output"

fakeOnlySpec :: Spec
fakeOnlySpec = do
  it "test_docker_command_credentials_are_not_exposed_in_host_argv" $ withFakeDocker $ \backend -> withTempDir $ \tmp -> do
    (_, provider) <- newProvider backend
    lease <- providerCreate provider "operation" (imageSpec (backendImage backend) [])
    attachment <- attachDir provider lease tmp "digest"
    let logPath = tmp <> "/docker.log"
    result <-
      bracket
        (setEnv "GITHUB_TOKEN" "host-authority" >> setEnv "DOCKER_FAKE_LOG" logPath)
        (const (unsetEnv "GITHUB_TOKEN" >> unsetEnv "DOCKER_FAKE_LOG"))
        ( const $
            providerExecute provider attachment $
              cmdWith ["agent", "run"] (\c -> c {specEnvironment = [("OPENROUTER_API_KEY", "agent-secret"), ("SAFE", "value")]})
        )
    -- "agent" does not exist on the host: the fake's exec fails, but the
    -- host-side invocation is what this test inspects.
    resultReturncode result `shouldNotBe` 0
    entries <- map (rightOr . parseJson pythonLoads) . BC.lines <$> B.readFile logPath
    let execs = [e | e <- entries, argvOf e `startsWith` ["exec", "--workdir"]]
    case execs of
      [entry] -> do
        let argv = argvOf entry
            environment = envOf entry
        any (T.isInfixOf "agent-secret") argv `shouldBe` False
        lookup "OPENROUTER_API_KEY" environment `shouldBe` Just "agent-secret"
        lookup "GITHUB_TOKEN" environment `shouldBe` Nothing
        length (filter (== "OPENROUTER_API_KEY") argv) `shouldBe` 1
        argv
          `shouldBe` [ "exec", "--workdir", "/workspace", "--env", "OPENROUTER_API_KEY", "--env", "SAFE", leaseId lease
                     , "sh", "-c", "exec env -i OPENROUTER_API_KEY=\"${OPENROUTER_API_KEY}\" SAFE=\"${SAFE}\" \"$@\""
                     , "petrus-command", "agent", "run"
                     ]
      other -> expectationFailure ("expected one exec invocation, got " <> show (length other))
    _ <- providerDestroy provider lease
    pure ()

  it "passes no environment names through an empty wrapper" $ withFakeDocker $ \backend -> withTempDir $ \tmp -> do
    (_, provider) <- newProvider backend
    lease <- providerCreate provider "empty-env" (imageSpec (backendImage backend) [])
    attachment <- attachDir provider lease tmp "digest"
    result <- providerExecute provider attachment (cmd ["/bin/sh", "-c", "env | grep -v '^PWD=' | grep -v '^SHLVL=' | grep -v '^_=' ; true"])
    resultStdout result `shouldBe` ""
    _ <- providerDestroy provider lease
    pure ()

  it "test_noncapable_providers_reject_private_roots_before_lookup_or_allocation (docker)" $ do
    env <- newDockerEnvironmentWith defaultDockerConfig {dockerExecutable = "/nonexistent/docker"}
    let provenance = rightOr (mkExecutionProvenance "operation" "docker" "lease")
        reference = rightOr (mkPrivateFileRef "file" "auth.json" "attachment" provenance)
        lease = rightOr (mkEnvironmentLease "operation" "docker" "lease" Set.empty Ready)
        attachment = rightOr (mkExecutionAttachment "attachment" lease "digest" "/workspace")
        command = cmdWith ["true"] (\c -> c {specPrivateRoots = [("CODEX_HOME", reference)]})
    providerExecute (dockerProvider env) attachment command
      `shouldThrowMessage` (ValueError, "Docker does not support the private-file-transfer capability")

  it "test_destroy_never_verifies_absence_for_a_foreign_provider (docker)" $ do
    env <- newDockerEnvironmentWith defaultDockerConfig {dockerExecutable = "/nonexistent/docker"}
    let foreignLease = rightOr (mkEnvironmentLease "foreign-cleanup" "foreign-provider" "foreign-lease" Set.empty Ready)
    result <- providerDestroy (dockerProvider env) foreignLease
    cleanupDisposition result `shouldBe` Unverified
    cleanupVerified result `shouldBe` False

  it "rejects images-less specs, unsupported capabilities, and unsafe ids before any CLI call" $ do
    env <- newDockerEnvironmentWith defaultDockerConfig {dockerExecutable = "/nonexistent/docker"}
    let provider = dockerProvider env
    providerCreate provider "op" defaultSpec `shouldThrowMessage` (ValueError, "Docker requires an image")
    providerCreate provider "op" (imageSpec "x" [capVm])
      `shouldThrowMessage` (ValueError, "unsupported capabilities: ['vm']")
    providerLookup provider "bad id" `shouldThrowMessage` (ValueError, "operation id must be a safe non-empty provider label")

  it "reports a missing CLI as an uncertain reconciliation" $ do
    env <- newDockerEnvironmentWith defaultDockerConfig {dockerExecutable = "petrus-no-such-docker"}
    result <- providerReconcile (dockerProvider env) "op"
    reconcileClassification result `shouldBe` ReconcileUncertain
    reconcileDetail result `shouldBe` "[Errno 2] No such file or directory: 'petrus-no-such-docker'"
    let lease = rightOr (mkEnvironmentLease "op" "docker" "c" dockerCapabilities Ready)
    (cleanupDetail <$> providerDestroy (dockerProvider env) lease) `shouldReturn` "Docker lookup failed before destroy"
    providerCancel (dockerProvider env) lease "ignored" `shouldReturn` ()

  it "classifies CLI failures and residue during destroy" $ withFakeDocker $ \backend -> do
    (_, provider) <- newProvider backend
    lease <- providerCreate provider "faults" (imageSpec (backendImage backend) [])
    setEnv "DOCKER_FAKE_RM_NOOP" "1"
    (cleanupDetail <$> providerDestroy provider lease) `shouldReturn` "Docker container remains after destroy"
    unsetEnv "DOCKER_FAKE_RM_NOOP"
    -- ps calls so far: create (2), destroy (2); fail from the next-but-one.
    setEnv "DOCKER_FAKE_FAIL" "ps:6"
    (cleanupDetail <$> providerDestroy provider lease) `shouldReturn` "Docker cleanup could not be independently verified"
    unsetEnv "DOCKER_FAKE_FAIL"
    providerLookup provider "faults" `shouldReturn` Nothing
    setEnv "DOCKER_FAKE_FAIL" "ps:1"
    reconciled <- providerReconcile provider "faults"
    reconcileClassification reconciled `shouldBe` ReconcileUncertain
    reconcileDetail reconciled `shouldSatisfy` T.isPrefixOf "Command '('docker', 'ps', '--all', '--quiet', '--filter', 'label=run.petrus.operation=faults')' returned non-zero exit status 1."
    unsetEnv "DOCKER_FAKE_FAIL"

  it "refuses bind-mounted, duplicated, and unobservable containers" $ withFakeDocker $ \backend -> do
    (_, provider) <- newProvider backend
    setEnv "DOCKER_FAKE_BIND" "1"
    providerCreate provider "bound" (imageSpec (backendImage backend) [])
      `shouldThrowMessage` (RuntimeError, "execution container unexpectedly has a bind mount")
    unsetEnv "DOCKER_FAKE_BIND"
    forM_ [1 :: Int, 2] $ \_ ->
      cli backend ["run", "--detach", "--label", "run.petrus.operation=twice", "img", "-c", "true"]
    providerLookup provider "twice" `shouldThrowMessage` (RuntimeError, "operation 'twice' resolves to multiple containers")
    setEnv "DOCKER_FAKE_RUN_UNLABELED" "1"
    providerCreate provider "hidden" (imageSpec (backendImage backend) [])
      `shouldThrowMessage` (RuntimeError, "created Docker lease could not be looked up")
    unsetEnv "DOCKER_FAKE_RUN_UNLABELED"

  it "exports a normalized archive of the container workspace" $ withFakeDocker $ \backend -> withTempDir $ \tmp -> do
    (_, provider) <- newProvider backend
    lease <- providerCreate provider "export" (imageSpec (backendImage backend) [])
    let source = tmp <> "/source"
    createDirectory source
    B.writeFile (source <> "/a.txt") "a"
    attachment <- attachDir provider lease source "digest"
    _ <- providerExecute provider attachment (cmd ["/bin/sh", "-c", "mkdir sub && printf b > sub/b.txt"])
    exported <- providerExport provider attachment
    let restored = tmp <> "/restored"
    extractWorkspaceArchive exported restored
    B.readFile (restored <> "/sub/b.txt") `shouldReturn` "b"
    roundTrip <- workspaceArchive restored
    roundTrip `shouldBe` exported
    _ <- providerDestroy provider lease
    pure ()
  where
    argvOf entry = case lookupMember "argv" entry of
      Just (Array items) -> [t | String t <- items]
      _ -> []
    envOf entry = case lookupMember "env" entry of
      Just (Object members) -> [(k, v) | (k, String v) <- members]
      _ -> []
    startsWith xs prefix = take (length prefix) xs == prefix
