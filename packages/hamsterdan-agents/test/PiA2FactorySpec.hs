-- | @tests/integration/host/test_pi_a2_factory.py@: the owned Pi A2
-- composition and the Petrus scripted runtime behind Hamsterdan's runner.
--
-- The crash test runs the reference's crash script under the pinned
-- upstream Python (Hamsterdan's own @PersistentKeyOperations@ and Petrus's
-- scripted runtime), then recovers the crashed state in Haskell: the
-- runtime-host store and the key directory cross the language boundary.
module PiA2FactorySpec (spec, packageFixture, scriptedConfig, trueCommand) where

import Control.Exception (throwIO)
import Control.Monad (when)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Python.Hashlib (sha256Hex)
import GHC.Clock (getMonotonicTime)
import Hamsterdan.Agents.Pi
import Hamsterdan.Agents.Pi.Doubles (piPackageFixture)
import Hamsterdan.Agents.Protocol
import Hamsterdan.Host.PiA2
import Petrus.Agenticus.Connection.Custody (mkConnectionIdentity)
import Petrus.Agenticus.Error (AgenticusError (..), ErrorClass (..), throwLeft)
import Petrus.Agenticus.Hands.Contract (ToolMethod (..))
import Petrus.Agenticus.Runtime.Installation (ProbeDisposition (..))
import Petrus.Agenticus.Runtime.Operation (cleanupVerified)
import Petrus.Agenticus.Runtime.Pi (piContinuationDescriptor)
import Petrus.Agenticus.Runtime.PiA2Host
import Petrus.Agenticus.Thread.Continuation (Continuation, ContinuationState (..), mkContinuation)
import Petrus.Agenticus.Thread.Identity (mkContinuationId, mkEpisodeId, mkThreadId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumpsText, parseJson, surrogateRefusingLoads)
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec

withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "pi-a2-factory"

-- | The reference's @/bin/true@, which macOS ships only as @/usr/bin/true@.
trueCommand :: IO Text
trueCommand = doesFileExist "/bin/true" >>= \exists -> pure (if exists then "/bin/true" else "/usr/bin/true")


readPolicy, codePolicy :: PiA2RuntimePolicy
readPolicy = either (error . show) id (mkPiA2RuntimePolicy [WorkspaceRead, WorkspaceSearch] [] 8 [])
codePolicy = either (error . show) id (mkPiA2RuntimePolicy [WorkspaceRead, WorkspaceSearch, WorkspaceWrite] [] 8 ["."])

-- | @_package(root)@: an installed Pi package and a probing node.
packageFixture :: FilePath -> IO (FilePath, FilePath, FilePath)
packageFixture = piPackageFixture

-- | @_config(root)@.
scriptedConfig :: FilePath -> IO PiA2RuntimeHostConfig
scriptedConfig root = do
  let working = root </> "working"
  createDirectoryIfMissing False working
  BS.writeFile (working </> "input.txt") "input"
  (cli, node, package) <- packageFixture root
  true <- trueCommand
  pure
    (piA2RuntimeHostConfig (root </> "state") working "anthropic" "claude-sonnet-4-5" "hamsterdan-test" (Set.fromList [minBound .. maxBound]))
      { allowedArgv = Set.fromList [[true]]
      , testCommand = [true]
      , maxToolCalls = 8
      , attachmentTimeout = 2
      , commandTimeout = 1
      , credentialTtl = 1
      , wallTimeout = 0.5
      , cancellationGrace = 0.05
      , cliPath = Just (T.pack cli)
      , nodePath = Just (T.pack node)
      , packageRoot = Just (T.pack package)
      }

directAuthority :: FilePath -> IO ScrubbedBytesSupplier -> IO PiA2DirectAuthority
directAuthority keysRoot supplier = do
  identity <- throwLeft (mkConnectionIdentity "direct" "anthropic" "synthetic" "api-key")
  keys <- persistentKeyOperations keysRoot
  supply <- supplier
  throwLeft (mkPiA2DirectAuthority identity keys supply)

type ScrubbedBytesSupplier = IO BA.ScrubbedBytes

oneShot :: IO BA.ScrubbedBytes -> IO ScrubbedBytesSupplier
oneShot = newOneShotApiKeySupplier

-- | A fresh erasable buffer per call (a shared one would be erased by the
-- first host that consumes it).
fresh :: ByteString -> IO BA.ScrubbedBytes
fresh value = BA.copy (BA.convert value :: BA.ScrubbedBytes) (\_ -> pure ())

-- | @_host(root, script, supplier)@.
scriptedHost :: FilePath -> [PiA2ScriptedTurn] -> IO ScrubbedBytesSupplier -> IO PiA2RuntimeHost
scriptedHost root script supplier = do
  authority <- directAuthority (root </> "keys") supplier
  config <- scriptedConfig root
  host <- composePiA2ScriptedRuntime config authority script getMonotonicTime
  readiness <- scriptedReadiness host
  readiness.ready `shouldBe` True
  pure host

-- | @_start(name, archive=..., prompt=..., continuation=..., policy=...)@.
startFor :: Text -> ByteString -> Text -> Maybe Continuation -> PiA2RuntimeStart
startFor name archive prompt continuation =
  PiA2RuntimeStart
    { operationId = name
    , episodeId = either (error . show) id (mkEpisodeId ("episode-" <> name))
    , turnId = either (error . show) id (mkTurnId ("turn-" <> name))
    , prompt
    , workspaceArchive = archive
    , workspaceDigest = sha256Hex archive
    , workspaceCorrelation = "synthetic:" <> name
    , policy = codePolicy
    , continuation
    }

-- | @_start(..., policy=selected)@.
withPolicy :: PiA2RuntimePolicy -> PiA2RuntimeStart -> PiA2RuntimeStart
withPolicy selected (PiA2RuntimeStart operationId episodeId turnId prompt archive digest correlation _ continuation) =
  PiA2RuntimeStart operationId episodeId turnId prompt archive digest correlation selected continuation

simpleStart :: Text -> ByteString -> PiA2RuntimeStart
simpleStart name archive = startFor name archive "prompt" Nothing

protocolFailure :: Text -> AgenticusError -> Bool
protocolFailure code e = e.errorClass == RuntimeProtocolError && code `T.isInfixOf` e.errorMessage

-- | @RunnerWorkspaces(archive)@.
runnerWorkspaces :: ByteString -> PiWorkspaceProvider
runnerWorkspaces archive =
  PiWorkspaceProvider $ \_ _ _ _ use ->
    use
      PreparedPiWorkspace
        { archive
        , digest = sha256Hex archive
        , correlation = "synthetic:runner"
        , policy = readPolicy
        , reconcile = \_ -> pure ("", [])
        }

reviewRequest :: ReviewRequest
reviewRequest =
  ReviewRequest
    { repository = "owner/repo"
    , pullRequest = 7
    , epoch = 2
    , head = T.replicate 40 "a"
    , base = T.replicate 40 "b"
    , diffPath = "diff.patch"
    , policy = []
    , reviewLenses = ["correctness"]
    , contextPaths = []
    , actionsEvidence = []
    , priorFindings = []
    , priorComments = []
    , priorReplies = []
    , appliedChanges = []
    }

clearOutput :: Text
clearOutput =
  either (error . show) id $
    dumpsText
      defaultDumps
      ( Object
          [ ("repository", String "owner/repo")
          , ("pull_request", Int 7)
          , ("epoch", Int 2)
          , ("head", String (T.replicate 40 "a"))
          , ("base", String (T.replicate 40 "b"))
          , ("status", String "clear")
          , ("findings", Array [])
          , ("lineage", Array [])
          ]
      )

runnerFor :: PiA2RuntimeHost -> ByteString -> IO AgentRunner
runnerFor host archive =
  either (throwIO . userError . T.unpack) (pure . piAgentRunner) (newPiNativeRunner (piA2Runtime host) (runnerWorkspaces archive) defaultPiRunnerOptions)

repositoryUrl :: Text
repositoryUrl = "https://example.invalid/owner/repo.git"

invocation :: Text -> Invocation
invocation operation = Invocation {operation, attempt = 1, isCurrent = Nothing}

lifecycleFailure :: AgentProtocolError -> Bool
lifecycleFailure e = e.resultCategory == Just RuntimeLifecycle

counting :: IORef Int -> ByteString -> IO BA.ScrubbedBytes
counting calls value = modifyIORef' calls (+ 1) >> fresh value

scriptedCall :: ToolMethod -> Text -> PiA2ScriptedCall
scriptedCall method params = either (error . show) id (mkPiA2ScriptedCall method params True)

spec :: Spec
spec = describe "tests/integration/host/test_pi_a2_factory.py" $ do
  it "test_production_owned_composition_uses_explicit_installed_package_without_authority" . withTmp $ \tmp -> do
    (cli, node, package) <- packageFixture tmp
    installation <-
      either (throwIO . userError . T.unpack) pure $
        mkPiA2InstallationConfig "anthropic" "claude-sonnet-4-5" "synthetic-direct-authority" cli node package
    host <- composeOwnedPiA2 (tmp </> "production") (Just installation)
    probe <- probeHost host
    probe.disposition `shouldBe` ProbeReady
    probe.runtime.name `shouldBe` "pi.native.a2.local"
    hostAuthorityRequested host `shouldReturn` False
    closeHost host `shouldReturn` True

  it "test_fresh_start_continuation_workspace_output_and_close" . withTmp $ \tmp -> do
    supplied <- fresh "fixture"
    host <-
      scriptedHost
        tmp
        [ (piA2ScriptedTurn "first") {calls = [scriptedCall WorkspaceWrite "{\"path\":\"output.txt\",\"content\":\"changed\"}"]}
        , (piA2ScriptedTurn "second") {calls = [scriptedCall WorkspaceRead "{\"path\":\"output.txt\"}"]}
        ]
        (oneShot (pure supplied))
    initial <- workspaceArchive (tmp </> "working")
    firstOperation <- startHost host (simpleStart "one" initial)
    first <- waitPiA2 firstOperation (Just 1)
    first.outcome `shouldBe` TurnCompleted
    loadOutput host (maybe "" id first.outputReference) `shouldReturn` "first"
    archived <- loadWorkspaceArchive host "one"
    BS.null archived `shouldBe` False
    reference <- maybe (throwIO (userError "no continuation")) pure first.continuationReference
    let continuation =
          either (error . show) id $
            mkContinuation
              (either (error . show) id (mkContinuationId "continuation-one"))
              (either (error . show) id (mkThreadId "thread-one"))
              piContinuationDescriptor
              reference
              ContinuationInUse
    second <- startHost host (startFor "two" archived "prompt" (Just continuation)) >>= (`waitPiA2` Just 1)
    loadOutput host (maybe "" id second.outputReference) `shouldReturn` "second"
    (second.continuationReference /= Nothing) `shouldBe` True
    BA.all (== 0) supplied `shouldBe` True
    cleanupVerified <$> closePiA2 firstOperation `shouldReturn` True
    closeHost host `shouldReturn` True
    closeHost host `shouldReturn` True

  it "test_terminal_replay_and_changed_work_conflict_use_no_authority" . withTmp $ \tmp -> do
    host <- scriptedHost tmp [piA2ScriptedTurn "answer"] (oneShot (fresh "fixture"))
    archive <- workspaceArchive (tmp </> "working")
    let start = simpleStart "stable" archive
    expected <- startHost host start >>= (`waitPiA2` Just 1)
    closeHost host `shouldReturn` True
    calls <- newIORef (0 :: Int)
    config <- scriptedConfig tmp
    authority <- directAuthority (tmp </> "replay-keys") (oneShot (counting calls "unused"))
    replay <- composePiA2ScriptedRuntime config authority [piA2ScriptedTurn "unused"] getMonotonicTime
    (startHost replay start >>= (`waitPiA2` Nothing)) `shouldReturn` expected
    startHost replay (startFor "stable" archive "changed" Nothing) `shouldThrow` protocolFailure "operation-conflict"
    createDirectory (tmp </> "changed-workspace")
    BS.writeFile (tmp </> "changed-workspace" </> "different.txt") "different"
    changedArchive <- workspaceArchive (tmp </> "changed-workspace")
    startHost replay (simpleStart "stable" changedArchive) `shouldThrow` protocolFailure "operation-conflict"
    startHost replay start {workspaceCorrelation = "synthetic:different-route"} `shouldThrow` protocolFailure "operation-conflict"
    startHost replay (withPolicy readPolicy start) `shouldThrow` protocolFailure "operation-conflict"
    readIORef calls `shouldReturn` 0
    closeHost replay `shouldReturn` True

  it "test_agent_runner_replays_closed_operation_without_probe_or_authority" . withTmp $ \tmp -> do
    original <- scriptedHost tmp [piA2ScriptedTurn clearOutput] (oneShot (fresh "fixture"))
    archive <- workspaceArchive (tmp </> "working")
    runner <- runnerFor original archive
    ((.status) <$> runner.review repositoryUrl reviewRequest (invocation "review:replay")) `shouldReturn` "clear"
    closeHost original `shouldReturn` True
    calls <- newIORef (0 :: Int)
    config <- scriptedConfig tmp
    authority <- directAuthority (tmp </> "replay-runner-keys") (oneShot (counting calls "unused"))
    replay <- composePiA2ScriptedRuntime config authority [piA2ScriptedTurn "unused"] getMonotonicTime
    replayRunner <- runnerFor replay archive
    ((.status) <$> replayRunner.review repositoryUrl reviewRequest (invocation "review:replay")) `shouldReturn` "clear"
    readIORef calls `shouldReturn` 0
    closeHost replay `shouldReturn` True

  it "test_agent_runner_refuses_legacy_prompt_reuse_without_new_authority_or_execution" . withTmp $ \tmp -> do
    calls <- newIORef (0 :: Int)
    host <- scriptedHost tmp [piA2ScriptedTurn clearOutput, piA2ScriptedTurn "must-not-run"] (oneShot (counting calls "fixture"))
    archive <- workspaceArchive (tmp </> "working")
    let logical = "review:legacy-prompt"
        operationId = piOperationId logical 1
        identity = sha256Hex (TE.encodeUtf8 operationId)
    current <- case encodePrompt ReviewKind repositoryUrl (AgentReview reviewRequest) of
      Right prompt -> either (throwIO . userError) pure (parseJson surrogateRefusingLoads (TE.encodeUtf8 prompt))
      Left failure -> throwIO (userError (show failure))
    let members = case current of
          Object fields -> fields
          _ -> []
        legacy =
          Object
            ( [(k, v) | (k, v) <- members, k `notElem` ["prompt_version", "response_contract"]]
                <> [ ("response", String "one JSON object matching the unchanged Hamsterdan result schema; no Markdown or prose")
                   , ("schema_version", Int 1)
                   ]
            )
    legacyPrompt <- either (throwIO . userError . show) pure (dumpsText defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True} legacy)
    seeded <-
      startHost
        host
        PiA2RuntimeStart
          { operationId
          , episodeId = either (error . show) id (mkEpisodeId ("episode-" <> identity))
          , turnId = either (error . show) id (mkTurnId ("turn-" <> identity))
          , prompt = legacyPrompt
          , workspaceArchive = archive
          , workspaceDigest = sha256Hex archive
          , workspaceCorrelation = "synthetic:runner"
          , policy = readPolicy
          , continuation = Nothing
          }
    ((.outcome) <$> waitPiA2 seeded (Just 1)) `shouldReturn` TurnCompleted
    cleanupVerified <$> closePiA2 seeded `shouldReturn` True
    readIORef calls `shouldReturn` 1
    runner <- runnerFor host archive
    runner.review repositoryUrl reviewRequest (invocation logical) `shouldThrow` lifecycleFailure
    readIORef calls `shouldReturn` 1
    closeHost host `shouldReturn` True

  it "test_agent_runner_defers_its_default_deadline_to_the_finite_a2_runtime" . withTmp $ \tmp -> do
    host <- scriptedHost tmp [(piA2ScriptedTurn "unused") {delaySeconds = 1}] (oneShot (fresh "fixture"))
    archive <- workspaceArchive (tmp </> "working")
    runner <- runnerFor host archive
    runner.review repositoryUrl reviewRequest (invocation "review:runtime-timeout")
      `shouldThrow` \e -> lifecycleFailure e && not e.timedOut
    closeHost host `shouldReturn` True

  it "test_cancellation_and_public_script_failure_fail_closed_with_cleanup_evidence" . withTmp $ \tmp -> do
    host <- scriptedHost (tmp </> "cancel") [(piA2ScriptedTurn "unused") {delaySeconds = 10}] (oneShot (fresh "fixture"))
    cancelArchive <- workspaceArchive (tmp </> "cancel" </> "working")
    operation <- startHost host (simpleStart "cancel" cancelArchive)
    cancelPiA2 operation "host-request" `shouldReturn` CancellationRequested
    ((.outcome) <$> waitPiA2 operation (Just 1)) `shouldReturn` TurnCancelled
    cleanupVerified <$> closePiA2 operation `shouldReturn` True
    closeHost host `shouldReturn` True
    closeHost host `shouldReturn` True
    failed <-
      scriptedHost
        (tmp </> "failure")
        [(piA2ScriptedTurn "") {failureCode = Just "scripted-failure", cleanupVerified = False}]
        (oneShot (fresh "fixture"))
    failureArchive <- workspaceArchive (tmp </> "failure" </> "working")
    replay <- startHost failed (simpleStart "failed" failureArchive)
    waitPiA2 replay Nothing `shouldThrow` protocolFailure "host-cleanup-uncertain"
    closeHost failed `shouldThrow` protocolFailure "host-cleanup-uncertain"

  it "test_restarted_executing_operation_is_indeterminate_without_authority" . withTmp $ \tmp -> do
    config <- scriptedConfig tmp
    true <- trueCommand
    python <- upstreamPythonExecutable "hamsterdan"
    let script = tmp </> "crash.py"
    BS.writeFile script crashScript
    (code, out, err) <-
      readCreateProcessWithExitCode
        ( proc
            python
            [ "-I"
            , script
            , config.stateRoot
            , config.workingDirectory
            , maybe "" T.unpack config.cliPath
            , maybe "" T.unpack config.nodePath
            , maybe "" T.unpack config.packageRoot
            , T.unpack true
            ]
        )
        ""
    when (code /= ExitSuccess) $ expectationFailure ("crash script failed: " <> out <> err)
    calls <- newIORef (0 :: Int)
    authority <- directAuthority (tmp </> "keys") (oneShot (counting calls "unused"))
    recovered <- composePiA2ScriptedRuntime config authority [piA2ScriptedTurn "unused"] getMonotonicTime
    map (.outcome) (hostRecoveredSettlements recovered) `shouldBe` [TurnIndeterminate]
    archive <- workspaceArchive (tmp </> "working")
    let crashedPolicy = either (error . show) id (mkPiA2RuntimePolicy [WorkspaceRead] [] 8 [])
    startHost recovered (withPolicy crashedPolicy (simpleStart "crashed" archive))
      `shouldThrow` protocolFailure "operation-indeterminate"
    readIORef calls `shouldReturn` 0
    closeHost recovered `shouldThrow` protocolFailure "host-cleanup-uncertain"

-- | The reference test's crash script, with the test command passed in
-- (macOS has no @/bin/true@).
crashScript :: ByteString
crashScript =
  TE.encodeUtf8 . T.unlines $
    [ "import os"
    , "import sys"
    , "from pathlib import Path"
    , "from hashlib import sha256"
    , "from petrus.agenticus.connection.custody import ConnectionIdentity"
    , "from petrus.agenticus.hands.contract import ToolMethod"
    , "from petrus.agenticus.runtime.pi_a2_host import PiA2DirectAuthority, PiA2RuntimeHostConfig, PiA2RuntimePolicy, PiA2RuntimeStart, PiA2ScriptedTurn, compose_pi_a2_scripted_runtime"
    , "from petrus.agenticus.thread.identity import EpisodeId, TurnId"
    , "from petrus.motus.execution.archive import workspace_archive"
    , "from hamsterdan.host.pi_a2 import PersistentKeyOperations"
    , ""
    , "root, working, cli, node, package = map(Path, sys.argv[1:6])"
    , "true = sys.argv[6]"
    , "config = PiA2RuntimeHostConfig("
    , "    state_root=root, working_directory=working, provider=\"anthropic\", model=\"claude-sonnet-4-5\","
    , "    host_id=\"hamsterdan-test\", capabilities=frozenset(ToolMethod),"
    , "    allowed_argv=frozenset({(true,)}), test_command=(true,), max_tool_calls=8,"
    , "    attachment_timeout=2, command_timeout=1, credential_ttl=1, wall_timeout=.5, cancellation_grace=.05,"
    , "    cli_path=str(cli), node_path=str(node), package_root=str(package),"
    , ")"
    , "authority = PiA2DirectAuthority("
    , "    ConnectionIdentity(\"direct\", \"anthropic\", \"synthetic\", \"api-key\"),"
    , "    PersistentKeyOperations(root.parent / \"keys\"), lambda: bytearray(b\"fixture\"),"
    , ")"
    , "host = compose_pi_a2_scripted_runtime("
    , "    config=config, authority=authority, script=(PiA2ScriptedTurn(\"unused\", delay_seconds=30),)"
    , ")"
    , "assert host.scripted_readiness().ready"
    , "archive = workspace_archive(working)"
    , "host.start(PiA2RuntimeStart("
    , "    \"crashed\", EpisodeId(\"episode-crashed\"), TurnId(\"turn-crashed\"), \"prompt\","
    , "    archive, sha256(archive).hexdigest(), \"synthetic:crashed\","
    , "    PiA2RuntimePolicy(frozenset({ToolMethod.WORKSPACE_READ}), max_tool_calls=8),"
    , "))"
    , "os._exit(0)"
    ]

