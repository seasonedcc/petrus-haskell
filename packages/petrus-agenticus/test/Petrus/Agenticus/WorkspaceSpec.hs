-- | Port of @tests/petrus/agenticus/hands/test_workspace.py@, plus the
-- differential replay of @differential/workspace_corpus.json@.
module Petrus.Agenticus.WorkspaceSpec (spec) where

import Control.Exception (SomeException, bracket, finally, throwIO, try)
import Control.Monad (forM_)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Char (digitToInt)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Agenticus.Attachment.Binding
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Gateway (ShellOutcome (..), StagedWrite (..), TestOutcome (..))
import Petrus.Agenticus.Hands.Workspace
import Petrus.Agenticus.Hands.Workspace qualified as Workspace
import Petrus.Agenticus.TestSupport
import Petrus.Json (Json (..))
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Providers.Docker (defaultDockerConfig, dockerExecutable, dockerProvider, newDockerEnvironmentWith)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import System.Directory (createDirectory, makeAbsolute)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "petrus-agenticus-workspace"

postgresImage :: Text
postgresImage = "postgres:17.5-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa"

-- | A local attachment over @source@, destroyed (and verified) afterwards.
withLocal :: Text -> FilePath -> (EnvironmentProvider -> ExecutionAttachment -> IO ()) -> IO ()
withLocal operation source action = do
  provider <- localProvider <$> newLocalProcessEnvironment
  lease <- providerCreate provider operation defaultSpec
  archive <- workspaceArchive source
  attachment <- providerAttach provider lease archive "input"
  action provider attachment `finally` do
    cleanup <- providerDestroy provider lease
    cleanupVerified cleanup `shouldBe` True

spec :: Spec
spec = do
  describe "hands/test_workspace.py" upstream
  describe "differential/workspace_corpus.json" differential

upstream :: Spec
upstream = do
  it "test_local_workspace_adapter_runs_complete_public_motus_route" $ withTmp $ \tmp -> do
    let source = tmp </> "source"
    createDirectory source
    writeFile (source </> "input.txt") ("needle\n" <> replicate (maxReadBytes + 10) 'x')
    withLocal "ds6-workspace-local" source $ \provider attachment -> do
      adapter <- newMotusWorkspaceAdapter provider attachment ["/bin/sh", "-c", "test -f output.txt"] defaultCommandTimeout
      content <- workspaceRead adapter "input.txt"
      (T.length content <= maxReadBytes) `shouldBe` True
      matches <- workspaceSearch adapter "needle" "."
      case matches of
        first : _ -> ("needle" `T.isSuffixOf` first) `shouldBe` True
        [] -> expectationFailure "search found nothing"
      shell <- workspaceShell adapter ["/bin/sh", "-c", "printf ok"] "."
      (shell.returncode, shell.stdout, shell.stderr) `shouldBe` (0, "ok", "")
      staged <- workspaceStageWrite adapter "call" "output.txt" "written"
      outstandingStages adapter `shouldReturn` 1
      workspaceCommitWrite adapter staged `shouldReturn` staged.digest
      outstandingStages adapter `shouldReturn` 0
      ((.passed) <$> workspaceRunTest adapter) `shouldReturn` True
      discarded <- workspaceStageWrite adapter "discard" "unused.txt" "secret"
      workspaceDiscardWrite adapter discarded
      outstandingStages adapter `shouldReturn` 0
      _ <- workspaceStageWrite adapter "cleanup" "unused.txt" "secret"
      workspaceDiscardAllStages adapter `shouldReturn` 1

  it "test_binary_output_preserves_the_public_utf8_byte_bound" $ withTmp $ \tmp -> do
    let source = tmp </> "source"
    createDirectory source
    B.writeFile (source </> "binary") (B.replicate (maxReadBytes + 10) 0xff)
    withLocal "ds6-workspace-binary" source $ \provider attachment -> do
      adapter <- newMotusWorkspaceAdapter provider attachment ["/bin/true"] defaultCommandTimeout
      content <- workspaceRead adapter "binary"
      (B.length (TE.encodeUtf8 content) <= maxReadBytes) `shouldBe` True
      shell <- workspaceShell adapter ["/bin/sh", "-c", "head -c " <> T.pack (show maxStreamBytes) <> " binary"] "."
      (B.length (TE.encodeUtf8 shell.stdout) <= maxStreamBytes && shell.truncated) `shouldBe` True

  describe "test_docker_workspace_adapter_and_binding_run_the_same_public_hands_route" $ do
    it "[fake docker CLI]" $ withTmp $ \tmp -> do
      executable <- makeAbsolute "../petrus-execution/test/fixtures/fake_docker.py"
      bracket
        (setEnv "DOCKER_FAKE_STATE" (tmp </> "docker-state"))
        (const (unsetEnv "DOCKER_FAKE_STATE"))
        (const (dockerRoute executable "fake/image:1" tmp))
    enabled <- runIO ((== Just "1") <$> lookupEnv "PETRUS_TEST_DOCKER")
    it "[real docker, PETRUS_TEST_DOCKER=1]" $
      if enabled
        then withTmp $ \tmp -> do
          image <- maybe postgresImage T.pack <$> lookupEnv "PETRUS_TEST_DOCKER_IMAGE"
          dockerRoute "docker" image tmp
        else pendingWith "skipped: set PETRUS_TEST_DOCKER=1 to run against a real Docker daemon"

  it "constructor refusals" $ withTmp $ \tmp -> do
    let source = tmp </> "source"
    createDirectory source
    withLocal "ds6-workspace-refusals" source $ \provider attachment -> do
      newMotusWorkspaceAdapter provider attachment [] 1 `shouldThrowAgenticus` "test_command must be a non-empty tuple"
      newMotusWorkspaceAdapter provider attachment ["/bin/true", ""] 1 `shouldThrowAgenticus` "test_command must be a non-empty tuple"
      forM_ [0, -1, 0 / 0, 1 / 0] $ \bad ->
        newMotusWorkspaceAdapter provider attachment ["/bin/true"] bad `shouldThrowAgenticus` "command_timeout must be a positive finite number"
      adapter <- newMotusWorkspaceAdapter provider attachment ["/bin/true"] 1
      workspaceRead adapter "missing" `shouldThrowAgenticus` "workspace read failed"
      workspaceSearch adapter "absent" "." `shouldReturn` []
      workspaceShell adapter ["/bin/true"] "/absolute" `shouldThrowAgenticus` "territory command failed"
      workspaceShell adapter ["/bin/sh", "-c", "sleep 5"] "." `shouldThrowAgenticus` "did not complete currently"
      other <- newMotusWorkspaceAdapter provider attachment ["/bin/true"] 1
      staged <- workspaceStageWrite adapter "call" "out.txt" "x"
      workspaceCommitWrite other staged `shouldThrowAgenticus` "stage token is not registered with this adapter"
      workspaceDiscardWrite adapter staged
      workspaceDiscardWrite adapter staged `shouldThrowAgenticus` "stage token is not registered with this adapter"

shouldThrowAgenticus :: IO a -> Text -> Expectation
shouldThrowAgenticus action fragment = do
  outcome <- try action
  case outcome of
    Left (e :: AgenticusError) -> (fragment `T.isInfixOf` e.errorMessage) `shouldBe` True
    Right _ -> expectationFailure ("expected a refusal containing " <> show fragment)

dockerRoute :: FilePath -> Text -> FilePath -> IO ()
dockerRoute executable image tmp = do
  let source = tmp </> "source"
  createDirectory source
  writeFile (source </> "input.txt") "needle\n"
  env <- newDockerEnvironmentWith defaultDockerConfig {dockerExecutable = executable}
  let provider = dockerProvider env
      operation = "ds6-docker-" <> T.take 16 (T.pack (show (hash (BC.pack tmp) :: Digest SHA256)))
      envSpec = either (error . show) id (mkEnvironmentSpec (Just image) [capContainer, capWorkspace])
  archive <- workspaceArchive source
  binding <- openMotusBinding provider operation envSpec archive "input"
  attachment <- bindingExecution binding
  outcome <- try $ do
    adapter <- newMotusWorkspaceAdapter provider attachment ["/bin/sh", "-c", "test -f output.txt"] defaultCommandTimeout
    workspaceRead adapter "input.txt" `shouldReturn` "needle\n"
    matches <- workspaceSearch adapter "needle" "."
    null matches `shouldBe` False
    ((.stdout) <$> workspaceShell adapter ["/bin/sh", "-c", "printf docker"] ".") `shouldReturn` "docker"
    staged <- workspaceStageWrite adapter "docker-call" "output.txt" "written"
    workspaceCommitWrite adapter staged `shouldReturn` staged.digest
    ((.passed) <$> workspaceRunTest adapter) `shouldReturn` True
    exported <- bindingExportArchive binding
    B.null exported `shouldBe` False
  settlement <- bindingSettle binding
  either (\(e :: SomeException) -> throwIO e) pure outcome
  settlement.verified `shouldBe` True

differential :: Spec
differential = do
  corpus <- runIO (loadJson "differential/workspace_corpus.json")
  it "constants match the reference" $ do
    let constants = member "constants" corpus
    member "STAGE_DIRECTORY" constants `shouldBe` String stageDirectory
    member "MAX_READ_BYTES" constants `shouldBe` Int (toInteger maxReadBytes)
    member "MAX_SEARCH_MATCHES" constants `shouldBe` Int (toInteger maxSearchMatches)
    member "MAX_SEARCH_MATCH_CHARS" constants `shouldBe` Int (toInteger maxSearchMatchChars)
    member "MAX_STREAM_BYTES" constants `shouldBe` Int (toInteger maxStreamBytes)
    member "COMMAND_OUTPUT_LIMIT" constants `shouldBe` Int (toInteger Workspace.commandOutputLimit)
  it "search projection matches the reference" $ do
    let cases = arrayItems (member "search_lines" corpus)
    (length cases > 100) `shouldBe` True
    forM_ cases $ \entry -> do
      let expected = [t | String t <- arrayItems (member "lines" entry)]
      searchLines (unhex (memberText "hex" entry)) `shouldBe` expected
  it "stage names and digests match the reference" $
    forM_ (arrayItems (member "stage_names" corpus)) $ \entry -> do
      let callId = memberText "call_id" entry
      stageName callId `shouldBe` memberText "name" entry
      T.pack (show (hash (TE.encodeUtf8 callId) :: Digest SHA256)) `shouldBe` memberText "digest" entry

arrayItems :: Json -> [Json]
arrayItems = \case
  Array items -> items
  other -> error ("expected an array, got " <> show other)

unhex :: Text -> B.ByteString
unhex = B.pack . go . T.unpack
  where
    go (a : b : rest) = fromIntegral (digitToInt a * 16 + digitToInt b) : go rest
    go _ = []
