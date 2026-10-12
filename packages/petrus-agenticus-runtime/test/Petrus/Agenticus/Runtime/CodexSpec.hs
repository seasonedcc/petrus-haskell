-- | @tests/petrus/agenticus/runtime/test_codex.py@: the exact Codex A2 Local
-- and A3 Gondolin lanes, one example per reference test (parametrized
-- cases keep pytest's ids), plus the verbatim checks and the cross-language
-- interop examples at the end.
--
-- The reference's fakes are records here: @Continuations@, @Turns@ and
-- @Custody@ (a 'HostConnectionCustody'); @RecordingLocal@,
-- @UncertainCleanupLocal@ and its provider monkeypatching are one 'Hooked'
-- wrapper over a real Motus provider; the monkeypatched @shutil.which@ and
-- @subprocess.run@ are 'CodexProbeHooks'; an assigned @adapter.start@ is
-- the rig's 'wrapStart' switch, read by the adapter's start wrapper. The fake @codex@ CLI and fake Gondolin SDK are the
-- reference's own, rendered by @test/fixtures/codex/extract.py@. The
-- replacement Worker is this test binary re-executed in Worker mode
-- ('codexWorkerVariable').
module Petrus.Agenticus.Runtime.CodexSpec (spec, codexWorkerVariable, codexWorkerRegistries) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, bracket, finally, throwIO, try)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (isInfixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBytes
import Petrus.Activity (ActivityExecutionContext (..), ActivityInvocation, ExecutionPolicyFields (..), defaultExecutionPolicy, executionPolicy, policyFields)
import Petrus.Activity qualified as Activity
import Petrus.Agenticus.Attachment.Binding
  ( AttachmentBinding (..)
  , MotusAttachmentBinding
  , bindingCleanupResult
  , bindingLeaseIdentity
  , motusBinding
  , openMotusBinding
  , withBindingOperation
  )
import Petrus.Agenticus.Attachment.Episode (EpisodeAttachment, episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Attachment.Retention (TerritoryCustodyPhase (..), closeTerritoryCustody, lookupCustody, openTerritoryCustodyWith, reclaim, retire)
import Petrus.Agenticus.Attachment.Retention qualified as Retention
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor, DescriptorKind (..), capabilityDescriptor, descriptorIdentity)
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot, mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody
  ( AdmissionResult (..)
  , AttachmentFence (..)
  , ConnectionStatus (..)
  , ConnectionView (..)
  , LeaseMode (..)
  , Materialization (..)
  , PublicationResult (..)
  , ReleaseResult (..)
  , agentConnectionCustody
  , authorize
  , closeCustody
  , enrollHost
  , lookupConnection
  , mkConnectionIdentity
  , newOpaqueState
  )
import Petrus.Agenticus.Connection.Custody qualified as Custody
import Petrus.Agenticus.Connection.Materialization (CleanupEvidence (..), newPrivateFileMaterializer, readMaterialized)
import Petrus.Agenticus.Connection.Storage (openSqliteConnectionStorage)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Sqlite qualified as Sql
import Petrus.Agenticus.Internal.Validate (sha256Hex)
import Petrus.Agenticus.Program.Descriptor (ProgramOwnership (..))
import Petrus.Agenticus.Runtime.Codex
import Petrus.Agenticus.Runtime.CodexGondolin
import Petrus.Agenticus.Runtime.Custody
import Petrus.Agenticus.Runtime.Installation (ProbeDisposition (..))
import Petrus.Agenticus.Runtime.Operation (RuntimeCleanupDisposition (..), cleanupVerified)
import Petrus.Agenticus.Runtime.PiSupport (aesKeys)
import Petrus.Agenticus.Runtime.Profiles (codexA2Local, codexA3Gondolin)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Continuation (Continuation, ContinuationState (..), continuationToData, mkContinuation)
import Petrus.Agenticus.Thread.Identity (LifecycleId (..), lifecycleIdToData, mkContinuationId, mkEpisodeId, mkThreadId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Dispatch (ActivityOutcome (..))
import Petrus.Motus.Dispatch.Inline (Activity, newInlineDispatch, runInline)
import Petrus.Motus.Dispatch.Local (closeLocalDispatch, collect, defaultLocalDispatchOptions, openLocalDispatch, waitForResults)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Execution
  ( CleanupDisposition (..)
  , CleanupResult (..)
  , Command
  , EnvironmentProvider (..)
  , ExecutionAttachment
  , LeaseIdentity (..)
  , PrivateFile
  , PrivateFileCleanupResult (..)
  , PrivateFileRef
  , PrivateFileTransfer (..)
  , capMicrovm
  , capPrivateFileTransfer
  , capVm
  , commandArgv
  , mkEnvironmentSpec
  , leaseIdentity
  , maxPrivateFileBytes
  )
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, workspaceArchive)
import Petrus.Motus.Execution.Providers.Gondolin (GondolinConfig (..), gondolinConfig, gondolinLookup, gondolinProvider, newGondolinEnvironment)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import Petrus.TestSupport.Python (PythonResult (..), pythonExecutable, runPython)
import Petrus.TestSupport.Repo (upstreamPetrus)
import System.Directory (makeAbsolute, createDirectory, createDirectoryIfMissing, doesFileExist, doesPathExist, listDirectory, removeFile)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, hGetLine, hSetBinaryMode)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, fileMode, getFileStatus, fileID, deviceID, setFileMode)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
import System.Timeout (timeout)
import Test.Hspec hiding (context)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

thread', otherThread, rolloutPath', promptCanary :: Text
thread' = "11111111-1111-4111-8111-111111111111"
otherThread = "22222222-2222-4222-8222-222222222222"
rolloutPath' = "sessions/2026/08/03/rollout-2026-08-03T00-00-00-" <> thread' <> ".jsonl"
promptCanary = "prompt-canary-never-render"

authCanary, rolloutCanary :: ByteString
authCanary = "opaque-auth-canary"
rolloutCanary = "opaque-rollout-canary"

hostFencedEffect :: CapabilityDescriptor
hostFencedEffect = capabilityDescriptor (descriptorIdentity KindEffect "host.fenced" 1) ["effect.host-fenced"] []

withTemp :: (FilePath -> IO a) -> IO a
withTemp = withSystemTempDirectory "petrus-codex"

raisesWith :: ErrorClass -> Text -> IO a -> Expectation
raisesWith cls fragment action =
  try action >>= \case
    Left (e :: AgenticusError) -> do
      (e.errorClass, e.errorClass `isSubclassOf` cls) `shouldBe` (e.errorClass, True)
      (e.errorMessage, fragment `T.isInfixOf` e.errorMessage) `shouldBe` (e.errorMessage, True)
    Right _ -> expectationFailure ("expected " <> show cls <> " containing " <> show fragment)

protocolRaises :: Text -> IO a -> Expectation
protocolRaises = raisesWith RuntimeProtocolError

leftWith :: Text -> Either AgenticusError a -> Expectation
leftWith fragment = \case
  Left e -> (e.errorMessage, fragment `T.isInfixOf` e.errorMessage) `shouldBe` (e.errorMessage, True)
  Right _ -> expectationFailure ("expected an error containing " <> show fragment)

waitUntil :: Double -> IO Bool -> IO ()
waitUntil seconds condition = do
  done <- timeout (round (seconds * 1000000)) loop
  maybe (expectationFailure "condition did not hold in time") pure done
  where
    loop = condition >>= \held -> unless held (threadDelay 10000 >> loop)

-- ---------------------------------------------------------------------------
-- Continuations, turns and custody

data Continuations = Continuations
  { values :: IORef (Map Text CodexContinuationPayloadV1)
  , gate :: Maybe (MVar (), MVar ())
  -- ^ @BlockingContinuations@: entered, release.
  }

newContinuations :: IO Continuations
newContinuations = (`Continuations` Nothing) <$> newIORef Map.empty

blockingContinuations :: IO Continuations
blockingContinuations = do
  values <- newIORef Map.empty
  entered <- newEmptyMVar
  release <- newEmptyMVar
  pure Continuations {values, gate = Just (entered, release)}

continuationOperations :: Continuations -> CodexContinuationOperations
continuationOperations c =
  CodexContinuationOperations
    { store = \operationId payload -> do
        forM_ c.gate $ \(entered, release) -> do
          void (tryPutMVar entered ())
          released <- timeout 5000000 (readMVar release)
          when (isNothing released) $ throwAgenticus (OtherError "AssertionError") "release"
        let reference = "codex-continuation-" <> operationId
        existing <- Map.lookup reference <$> readIORef c.values
        case existing of
          Just e | e /= payload -> throwAgenticus RuntimeError "conflicting Continuation payload"
          _ -> modifyIORef' c.values (Map.insert reference payload)
        pure reference
    , load = \reference -> Map.lookup reference <$> readIORef c.values >>= maybe (throwAgenticus KeyError reference) pure
    }

loadPayload :: Continuations -> Text -> IO CodexContinuationPayloadV1
loadPayload c reference = (continuationOperations c).load reference

newtype Turns = Turns {values :: IORef (Map Text (Text, Text))}

newTurns :: IO Turns
newTurns = Turns <$> newIORef Map.empty

turnOperations :: Turns -> CodexTurnOperations
turnOperations t = CodexTurnOperations $ \operationId thread text -> do
  let reference = "codex-turn-" <> operationId
  existing <- Map.lookup reference <$> readIORef t.values
  case existing of
    Just e | e /= (thread, text) -> throwAgenticus RuntimeError "conflicting Turn payload"
    _ -> modifyIORef' t.values (Map.insert reference (thread, text))
  pure reference

data Custody = Custody
  { authorityEpoch :: IORef Integer
  , stateVersion :: IORef Integer
  , auth :: IORef ByteString
  , records :: IORef [(Text, Text)]
  , mismatchedFence :: IORef Bool
  , checkpointCleanupUncertain :: IORef Bool
  , publication :: Maybe (MVar (), MVar ())
  -- ^ @PublishingCustody@: entered, release.
  }

newCustody :: IO Custody
newCustody = custodyWith Nothing

publishingCustody :: IO Custody
publishingCustody = do
  entered <- newEmptyMVar
  release <- newEmptyMVar
  custodyWith (Just (entered, release))

custodyWith :: Maybe (MVar (), MVar ()) -> IO Custody
custodyWith publication = do
  authorityEpoch <- newIORef 3
  stateVersion <- newIORef 4
  auth <- newIORef authCanary
  records <- newIORef []
  mismatchedFence <- newIORef False
  checkpointCleanupUncertain <- newIORef False
  pure Custody {authorityEpoch, stateVersion, auth, records, mismatchedFence, checkpointCleanupUncertain, publication}

custodyView :: Custody -> IO ConnectionView
custodyView c = do
  authority <- readIORef c.authorityEpoch
  version <- readIORef c.stateVersion
  pure (ConnectionView (ok (mkConnectionIdentity "codex-connection" "codex" "safe-account" "file-auth")) StatusReady authority version Nothing)

kinds :: Custody -> IO [Text]
kinds c = map fst <$> readIORef c.records

custodyOperations :: Custody -> HostConnectionCustody
custodyOperations c =
  HostConnectionCustody
    { materialize = \connection host mode ttl operationId -> do
        unless (connection == "codex-connection" && host == "host-1" && mode == LeaseRefresh && ttl > 0) $
          throwAgenticus (OtherError "AssertionError") "materialize"
        record "materialize" operationId
        version <- readIORef c.stateVersion
        authority <- readIORef c.authorityEpoch
        mismatched <- readIORef c.mismatchedFence
        home <- readIORef c.auth >>= newIORef
        now <- getMonotonicTime
        pure
          HostMaterialization
            { fence =
                AttachmentFence
                  ("connection-attachment-" <> T.pack (show version))
                  ("connection-lease-" <> T.pack (show version))
                  connection
                  host
                  1
                  (authority + if mismatched then 1 else 0)
                  version
            , mode
            , expiresAt = now + ttl
            , home =
                ProviderHome
                  { read = readIORef home
                  , replace = \value -> do
                      when (B.null value) $ throwAgenticus ValueError "empty auth state"
                      writeIORef home value
                  }
            }
    , activate = \_ operationId -> record "activate" operationId
    , admitResult = \fence operationId -> do
        forM_ c.publication $ \(entered, release) -> do
          void (tryPutMVar entered ())
          released <- timeout 5000000 (readMVar release)
          when (isNothing released) $ throwAgenticus (OtherError "AssertionError") "publication release"
        authority <- readIORef c.authorityEpoch
        version <- readIORef c.stateVersion
        unless (fence.authorityEpoch == authority && fence.baseVersion == version) $
          throwAgenticus (OtherError "AssertionError") "admit"
        record "admit" operationId
        pure AdmissionResult {operationId, purpose = "result", attachmentId = fence.attachmentId}
    , checkpoint = \m operationId -> do
        record "checkpoint" operationId
        value <- m.home.read
        writeIORef c.auth value
        modifyIORef' c.stateVersion (+ 1)
        uncertain <- readIORef c.checkpointCleanupUncertain
        view <- custodyView c
        pure
          PublicationResult
            { operationId
            , connection = view
            , cleanup = CleanupEvidence m.fence.attachmentId True False (toInteger (B.length value)) False uncertain
            }
    , release = \m operationId -> do
        record "release" operationId
        value <- m.home.read
        pure ReleaseResult {operationId, cleanup = CleanupEvidence m.fence.attachmentId True False (toInteger (B.length value)) False False}
    }
  where
    record kind operationId = modifyIORef' c.records (<> [(kind, operationId)])

-- | @ActivityContext(stale=...)@, counting heartbeats.
activityContext :: Bool -> IO (ActivityExecutionContext, IORef Int)
activityContext stale = do
  calls <- newIORef (0 :: Int)
  latest <- newIORef Null
  pure
    ( ActivityExecutionContext
        { attemptId = "activity-attempt"
        , epoch = "1"
        , claimant = "host"
        , instance' = Nothing
        , latestDetails = readIORef latest
        , heartbeat = \details -> do
            modifyIORef' calls (+ 1)
            when stale $ throwAgenticus RuntimeError "stale activity"
            let value = fromMaybe Null details
            writeIORef latest value
            pure value
        }
    , calls
    )

-- ---------------------------------------------------------------------------
-- Providers

-- | @RecordingLocal@ / @UncertainCleanupLocal@ and the reference's
-- provider monkeypatching: every command is recorded and each private-file
-- operation (and the workspace export) can be wrapped after the fact.
data Hooked = Hooked
  { provider :: EnvironmentProvider
  , commands :: IORef [Command]
  , importWrap :: IORef ((ExecutionAttachment -> PrivateFile -> IO PrivateFileRef) -> ExecutionAttachment -> PrivateFile -> IO PrivateFileRef)
  , exportWrap :: IORef ((ExecutionAttachment -> PrivateFileRef -> IO PrivateFile) -> ExecutionAttachment -> PrivateFileRef -> IO PrivateFile)
  , deleteWrap :: IORef ((ExecutionAttachment -> PrivateFileRef -> IO PrivateFileCleanupResult) -> ExecutionAttachment -> PrivateFileRef -> IO PrivateFileCleanupResult)
  , cleanupWrap :: IORef ((ExecutionAttachment -> IO PrivateFileCleanupResult) -> ExecutionAttachment -> IO PrivateFileCleanupResult)
  , workspaceExportWrap :: IORef ((ExecutionAttachment -> IO ByteString) -> ExecutionAttachment -> IO ByteString)
  }

hooked :: EnvironmentProvider -> IO Hooked
hooked inner = do
  commands <- newIORef []
  importWrap <- newIORef id
  exportWrap <- newIORef id
  deleteWrap <- newIORef id
  cleanupWrap <- newIORef id
  workspaceExportWrap <- newIORef id
  let transfer = fromMaybe (error "private transfer") (providerPrivateFiles inner)
      provider =
        inner
          { providerExecute = \attachment command -> do
              modifyIORef' commands (<> [command])
              providerExecute inner attachment command
          , providerExport = \attachment -> readIORef workspaceExportWrap >>= \w -> w (providerExport inner) attachment
          , providerPrivateFiles =
              Just
                PrivateFileTransfer
                  { importPrivateFile = \a f -> readIORef importWrap >>= \w -> w transfer.importPrivateFile a f
                  , exportPrivateFile = \a r -> readIORef exportWrap >>= \w -> w transfer.exportPrivateFile a r
                  , deletePrivateFile = \a r -> readIORef deleteWrap >>= \w -> w transfer.deletePrivateFile a r
                  , cleanupPrivateFiles = \a -> readIORef cleanupWrap >>= \w -> w transfer.cleanupPrivateFiles a
                  }
          }
  pure Hooked {provider, commands, importWrap, exportWrap, deleteWrap, cleanupWrap, workspaceExportWrap}

recordingLocal :: IO Hooked
recordingLocal = newLocalProcessEnvironment >>= hooked . localProvider

uncertainCleanupLocal :: IO Hooked
uncertainCleanupLocal = do
  h <- recordingLocal
  writeIORef h.cleanupWrap (\original a -> (\r -> r {privateCleanupDisposition = Unverified}) <$> original a)
  pure h

argvs :: Hooked -> IO [[Text]]
argvs h = map commandArgv <$> readIORef h.commands

-- ---------------------------------------------------------------------------
-- Fixtures

fixturePath :: FilePath -> FilePath
fixturePath name = "test" </> "fixtures" </> "codex" </> name

-- | @fake_codex(tmp_path, version)@.
fakeCodex :: FilePath -> Text -> IO FilePath
fakeCodex root version = do
  python <- pythonExecutable
  template <- TE.decodeUtf8 <$> B.readFile (fixturePath "fake_codex.py")
  let executable = root </> "codex"
  B.writeFile executable (TE.encodeUtf8 (T.replace "__VERSION__" version (T.replace "__PYTHON__" (T.pack python) template)))
  setFileMode executable 0o755
  pure executable

jsonPath :: FilePath -> Text
jsonPath = TE.decodeUtf8 . ok . jsonBytes . String . T.pack

-- | @fake_gondolin_sdk(tmp_path, executable)@.
fakeGondolinSdk :: FilePath -> FilePath -> IO FilePath
fakeGondolinSdk root executable = do
  let architecture = root </> "fake-uname"
      started = root </> "fake-codex-command-started"
      sdk = root </> "fake-gondolin-codex.mjs"
  writeFile architecture "#!/bin/sh\nprintf aarch64\n"
  setFileMode architecture 0o755
  template <- TE.decodeUtf8 <$> B.readFile (fixturePath "fake_gondolin_codex.mjs")
  let rendered =
        T.replace "__STARTED__" (jsonPath started) $
          T.replace "__UNAME__" (jsonPath architecture) $
            T.replace "__CODEX__" (jsonPath executable) template
  B.writeFile sdk (TE.encodeUtf8 rendered)
  pure sdk

snapshot :: CapabilityDescriptor -> ResolutionSnapshot
snapshot runtime =
  ok . mkResolutionSnapshot 1 $
    [ runtime
    , codexConnectionCapabilities
    , codexProgramCapabilities
    , codexCollocatedHands
    , codexLocalTerritory
    , codexContinuationCapabilities
    , hostFencedEffect
    ]

gondolinSnapshot :: ResolutionSnapshot
gondolinSnapshot =
  ok . mkResolutionSnapshot 1 $
    [ codexA3Gondolin
    , codexConnectionCapabilities
    , codexProgramCapabilities
    , codexCollocatedHands
    , codexGondolinTerritory
    , codexContinuationCapabilities
    , hostFencedEffect
    ]

config :: Double -> Int -> CodexRuntimeConfig
config commandTimeout outputLimit =
  (codexRuntimeConfig "host-1") {credentialTtl = 2, commandTimeout, outputLimit, cancellationGrace = 1}

gondolinRuntimeConfig :: CodexRuntimeConfig
gondolinRuntimeConfig = (codexRuntimeConfig "host-1") {credentialTtl = 10, commandTimeout = 10, cancellationGrace = 2}

-- | The probe environment with an assignable @shutil.which@ and
-- @subprocess.run@.
data ProbeEnvironment = ProbeEnvironment
  { whichRef :: IORef (String -> IO (Maybe FilePath))
  , runRef :: IORef ([String] -> IO (Maybe Text))
  , hooks :: CodexProbeHooks
  }

probeEnvironment :: Maybe FilePath -> IO ProbeEnvironment
probeEnvironment executable = do
  whichRef <- newIORef (\_ -> pure executable)
  runRef <- newIORef officialCodexProbeHooks.run
  let hooks =
        CodexProbeHooks
          { which = \name -> readIORef whichRef >>= ($ name)
          , run = \argv -> readIORef runRef >>= ($ argv)
          }
  pure ProbeEnvironment {whichRef, runRef, hooks}

adapterOptions :: CodexProbeHooks -> IO CodexAdapterOptions
adapterOptions hooks = do
  python <- pythonExecutable
  pure CodexAdapterOptions {clock = getMonotonicTime, hooks, interpreter = python, guestInterpreter = "/usr/bin/python3", startWrapper = id}

data Rig = Rig
  { adapter :: CodexRuntimeAdapter
  , executable :: FilePath
  , continuations :: Continuations
  , turns :: Turns
  , custody :: Custody
  , root :: FilePath
  , probing :: ProbeEnvironment
  }

data RigOptions = RigOptions
  { optTimeout :: Double
  , optOutputLimit :: Int
  , optContinuations :: Maybe Continuations
  , optCustody :: Maybe Custody
  }

rigOptions :: RigOptions
rigOptions = RigOptions 2 1000000 Nothing Nothing

-- | @make_rig(tmp_path, monkeypatch, ...)@.
makeRig :: FilePath -> RigOptions -> IO Rig
makeRig root o = do
  executable <- fakeCodex root codexVersion
  continuations <- maybe newContinuations pure o.optContinuations
  turns <- newTurns
  custody <- maybe newCustody pure o.optCustody
  probing <- probeEnvironment (Just executable)
  options <- adapterOptions probing.hooks
  adapter <-
    newCodexRuntimeAdapter
      (config o.optTimeout o.optOutputLimit)
      (codexContinuationCodec (continuationOperations continuations))
      (turnOperations turns)
      (custodyOperations custody)
      options
  probe <- probeCodex adapter
  probe.disposition `shouldBe` ProbeReady
  pure Rig {adapter, executable, continuations, turns, custody, root, probing}

data Invoked = Invoked
  { invocation :: CodexRuntimeInvocation
  , attachment :: EpisodeAttachment
  , territory :: Hooked
  }

data InvocationOptions = InvocationOptions
  { invContinuation :: Maybe Continuation
  , invSelected :: Maybe ResolutionSnapshot
  , invProvider :: Maybe Hooked
  , invDeadline :: Maybe Double
  }

invocationOptions :: InvocationOptions
invocationOptions = InvocationOptions Nothing Nothing Nothing Nothing

-- | @rig.invocation(operation_id, prompt, ...)@.
invoke :: Rig -> Text -> Text -> InvocationOptions -> IO Invoked
invoke rig operationId prompt o = do
  territory <- maybe recordingLocal pure o.invProvider
  let episode = ok (mkEpisodeId (T.replace "operation" "episode" operationId))
      source = rig.root </> T.unpack ("workspace-" <> operationId)
  createDirectory source
  archive <- workspaceArchive source
  binding <-
    openMotusBinding
      territory.provider
      ("territory-" <> operationId)
      (ok (mkEnvironmentSpec Nothing [capPrivateFileTransfer]))
      archive
      ("input-" <> operationId)
  now <- getMonotonicTime
  attachment <-
    newEpisodeAttachment
      episode
      (fromMaybe (snapshot codexA2Local) o.invSelected)
      (motusBinding binding)
      ("agenticus-attachment-" <> operationId)
      (fromMaybe (now + 5) o.invDeadline)
      episodeOptions
  view <- custodyView rig.custody
  invocation <-
    newCodexRuntimeInvocation
      CodexRuntimeInvocation
        { operationId
        , episodeId = episode
        , turnId = ok (mkTurnId ("turn-" <> operationId))
        , prompt
        , connection = view
        , attachment
        , continuation = o.invContinuation
        }
  pure Invoked {invocation, attachment, territory}

-- | @continuation(reference)@.
continuationFor :: Text -> Continuation
continuationFor reference = continuationWith ("continuation-" <> reference) reference ContinuationInUse

continuationWith :: Text -> Text -> ContinuationState -> Continuation
continuationWith identifier reference state =
  ok
    ( mkContinuation
        (ok (mkContinuationId identifier))
        (ok (mkThreadId "agenticus-thread"))
        codexContinuationDescriptor
        reference
        state
    )

withPrompt :: CodexRuntimeInvocation -> Text -> CodexRuntimeInvocation
withPrompt i prompt = CodexRuntimeInvocation i.operationId i.episodeId i.turnId prompt i.connection i.attachment i.continuation

withConnection :: CodexRuntimeInvocation -> ConnectionView -> CodexRuntimeInvocation
withConnection i connection = CodexRuntimeInvocation i.operationId i.episodeId i.turnId i.prompt connection i.attachment i.continuation

withContinuation :: CodexRuntimeInvocation -> Maybe Continuation -> CodexRuntimeInvocation
withContinuation i = CodexRuntimeInvocation i.operationId i.episodeId i.turnId i.prompt i.connection i.attachment

-- | @settle_attachment(attachment)@.
settleAttachment :: EpisodeAttachment -> Expectation
settleAttachment a = do
  settled <- Episode.settle a 1
  settled.settlement.verified `shouldBe` True
  (authCanary `B.isInfixOf` settled.archive) `shouldBe` False
  (rolloutCanary `B.isInfixOf` settled.archive) `shouldBe` False

startWait :: Rig -> CodexRuntimeInvocation -> IO (CodexOperation, RuntimeTurnSettlement)
startWait rig inv = do
  operation <- startCodex rig.adapter inv
  result <- waitCodexOperation operation (Just 5)
  pure (operation, result)

codexCommands :: Rig -> Hooked -> IO [[Text]]
codexCommands rig h = filter ((== [T.pack rig.executable]) . take 1) <$> argvs h

closeVerified :: CodexOperation -> Expectation
closeVerified operation = cleanupVerified <$> closeCodexOperation operation `shouldReturn` True

-- | @gondolin_invocation(tmp_path, provider, custody, operation_id, prompt)@.
gondolinInvocation :: FilePath -> EnvironmentProvider -> Custody -> Text -> Text -> Maybe Continuation -> IO (CodexRuntimeInvocation, EpisodeAttachment, MotusAttachmentBinding)
gondolinInvocation root provider custody operationId prompt continuation = do
  let source = root </> T.unpack ("gondolin-workspace-" <> operationId)
  createDirectory source
  writeFile (source </> "public-input.txt") "public-workspace-canary"
  archive <- workspaceArchive source
  binding <-
    openMotusBinding
      provider
      ("territory-" <> operationId)
      (ok (mkEnvironmentSpec (Just "fake-image") [capVm, capMicrovm, capPrivateFileTransfer]))
      archive
      ("input-" <> operationId)
  let episode = ok (mkEpisodeId (T.replace "operation" "episode" operationId))
  now <- getMonotonicTime
  attachment <- newEpisodeAttachment episode gondolinSnapshot (motusBinding binding) ("agenticus-attachment-" <> operationId) (now + 15) episodeOptions
  view <- custodyView custody
  invocation <-
    newCodexRuntimeInvocation
      CodexRuntimeInvocation
        { operationId
        , episodeId = episode
        , turnId = ok (mkTurnId ("turn-" <> operationId))
        , prompt
        , connection = view
        , attachment
        , continuation
        }
  pure (invocation, attachment, binding)

-- | @gondolin_activity_input(attachment, custody, prompt, turn_id=...)@.
gondolinActivityInput :: EpisodeAttachment -> Custody -> Text -> Text -> Maybe Continuation -> IO Json
gondolinActivityInput attachment custody prompt turnId continuation = do
  coordinates <- Episode.coordinates attachment
  view <- custodyView custody
  pure $
    Object
      [ ("version", Int 1)
      , ("episode_id", lifecycleIdToData (Episode.episodeId attachment))
      , ("turn_id", String turnId)
      , ("prompt", String prompt)
      , ("attachment_id", String coordinates.attachmentId)
      , ("attachment_epoch", Int coordinates.attachmentEpoch)
      , ("connection_id", String view.identity.connectionId)
      , ("authority_epoch", Int view.authorityEpoch)
      , ("state_version", Int view.stateVersion)
      , ("continuation", maybe Null continuationToData continuation)
      ]

data GondolinRig = GondolinRig
  { adapter :: CodexRuntimeAdapter
  , gondolinRoot :: FilePath
  , territory :: Hooked
  , sdk :: FilePath
  , continuations :: Continuations
  , turns :: Turns
  , custody :: Custody
  , lookupLease :: Text -> IO (Maybe LeaseIdentity)
  , wrapStart :: IORef StartWrapper
  -- ^ The test's switch for the adapter's start wrapper.
  }

type StartWrapper = (CodexRuntimeInvocation -> IO CodexOperation) -> CodexRuntimeInvocation -> IO CodexOperation

-- | The reference's recurring Gondolin setup: the fake guest @codex@ at
-- @version@, its fake SDK, one provider root, and an A3 adapter.
gondolinRig :: FilePath -> FilePath -> Text -> IO GondolinRig
gondolinRig = gondolinRigWith id

gondolinRigWith :: (CodexAdapterOptions -> CodexAdapterOptions) -> FilePath -> FilePath -> Text -> IO GondolinRig
gondolinRigWith adjust tmp rootName version = do
  executable <- fakeCodex tmp version
  sdk <- fakeGondolinSdk tmp executable
  let root = tmp </> rootName
  environment <- newGondolinEnvironment root (gondolinConfig (T.pack sdk)) {gondolinLeaseTtl = 30}
  territory <- hooked (gondolinProvider environment)
  continuations <- newContinuations
  turns <- newTurns
  custody <- newCustody
  probing <- probeEnvironment Nothing
  options <- adapterOptions probing.hooks
  wrapStart <- newIORef id
  adapter <-
    newCodexGondolinRuntimeAdapter
      gondolinRuntimeConfig
      (codexContinuationCodec (continuationOperations continuations))
      (turnOperations turns)
      (custodyOperations custody)
      (adjust options {startWrapper = \original runtime -> readIORef wrapStart >>= \wrapper -> wrapper original runtime})
  let lookupLease operation = fmap leaseIdentity <$> gondolinLookup environment operation
  pure GondolinRig {adapter, gondolinRoot = root, territory, sdk, continuations, turns, custody, lookupLease, wrapStart}

gondolinProviderAt :: FilePath -> FilePath -> IO EnvironmentProvider
gondolinProviderAt root sdk = gondolinProvider <$> newGondolinEnvironment root (gondolinConfig (T.pack sdk)) {gondolinLeaseTtl = 30}

retryPolicy :: Integer -> Integer -> ExecutionPolicyFields
retryPolicy attempts heartbeatTimeout = (policyFields defaultExecutionPolicy) {attempts, heartbeatTimeout}

activityInvocation :: Text -> Json -> Maybe Text -> ExecutionPolicyFields -> ActivityInvocation
activityInvocation activity input idempotency fields =
  ok (Activity.activityInvocation (Activity.ActivityInvocationFields activity input (ok (executionPolicy fields)) Nothing idempotency))

-- ---------------------------------------------------------------------------
-- Worker mode

-- | Set to re-execute this test binary as a Local Worker.
codexWorkerVariable :: String
codexWorkerVariable = "PETRUS_CODEX_TEST_WORKER"

-- | @tests.petrus.agenticus.runtime.codex_worker_support:activities@.
codexWorkerRegistries :: Map Text (IO (Map Text Activity))
codexWorkerRegistries =
  Map.fromList [("tests.petrus.agenticus.runtime.codex_worker_support:activities", pure (Map.fromList [(serviceActivity, activity)]))]
  where
    activity invocation context = do
      result <- codexGondolinActivityClient invocation context
      marker <- lookup "PETRUS_CODEX_GONDOLIN_WITHHOLD" <$> getEnvironment
      case marker of
        Just path | not (null path) -> do
          present <- doesFileExist path
          unless present $ do
            writeFile path ""
            threadDelay 3600000000
        _ -> pure ()
      pure result

-- | @_start_codex_worker(path, environment)@ over this test binary.
startCodexWorker :: FilePath -> [(String, String)] -> IO ProcessHandle
startCodexWorker path extra = do
  self <- getExecutablePath
  environment <- getEnvironment
  let keys = codexWorkerVariable : map fst extra
  (_, Just out, _, handle) <-
    createProcess
      ( proc
          self
          [ "--provider"
          , "local"
          , "--path"
          , path
          , "--registry"
          , "tests.petrus.agenticus.runtime.codex_worker_support:activities"
          , "--poll-interval"
          , "0.02"
          , "+RTS"
          , "-M2G"
          , "-RTS"
          ]
      )
        { std_out = CreatePipe
        , env = Just ((codexWorkerVariable, "1") : extra <> filter ((`notElem` keys) . fst) environment)
        }
  awaitReady handle out
  pure handle

-- | The reference's own Worker (@python -m petrus.motus.worker@) with the
-- reference's registry, from the pinned upstream checkout.
startPythonWorker :: FilePath -> [(String, String)] -> IO ProcessHandle
startPythonWorker path extra = do
  python <- pythonExecutable
  upstream <- upstreamPetrus
  environment <- getEnvironment
  let keys = map fst extra
  (_, Just out, _, handle) <-
    createProcess
      ( proc
          python
          [ "-B"
          , "-m"
          , "petrus.motus.worker"
          , "--provider"
          , "local"
          , "--path"
          , path
          , "--registry"
          , "tests.petrus.agenticus.runtime.codex_worker_support:activities"
          , "--poll-interval"
          , "0.02"
          ]
      )
        { std_out = CreatePipe
        , cwd = Just upstream
        , env = Just (extra <> filter ((`notElem` keys) . fst) environment)
        }
  awaitReady handle out
  pure handle

awaitReady :: ProcessHandle -> Handle -> IO ()
awaitReady handle out = do
  hSetBinaryMode out True
  line <- timeout 10000000 (hGetLine out)
  case line of
    Just text | Right (Object members) <- J.parseJson J.surrogateRefusingLoads (BC.pack text), lookup "ready" members == Just (Bool True) -> pure ()
    other -> killProcess handle >> expectationFailure ("Codex Local Worker did not become ready: " <> show other)

-- | Kill one worker this test started, by its exact PID.
killProcess :: ProcessHandle -> IO ()
killProcess handle = do
  running <- getProcessExitCode handle
  when (isNothing running) $ getPid handle >>= mapM_ (signalProcess sigKILL)
  void (timeout 5000000 (waitForProcess handle))

-- ---------------------------------------------------------------------------
-- Socket helpers

-- | One request frame in, one reply (up to 4096 bytes) out.
exchange :: FilePath -> ByteString -> IO Json
exchange endpoint frame =
  bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \client -> do
    Socket.connect client (Socket.SockAddrUnix endpoint)
    SocketBytes.sendAll client frame
    reply <- SocketBytes.recv client 4096
    pure (ok (J.parseJson J.surrogateRefusingLoads reply))

errorReply :: Text -> Json
errorReply code = Object [("ok", Bool False), ("error", String code)]

-- | @one_response(endpoint, response, delay=...)@: a one-shot server; the
-- returned action waits for it to finish.
oneResponse :: FilePath -> ByteString -> Double -> IO (IO Bool)
oneResponse endpoint response delay = do
  ready <- newEmptyMVar
  done <- newEmptyMVar
  void . forkIO . (`finally` putMVar done ()) $
    bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \server -> do
      Socket.bind server (Socket.SockAddrUnix endpoint)
      Socket.listen server 1
      putMVar ready ()
      bracket (fst <$> Socket.accept server) Socket.close $ \connection -> do
        let receive received = unless ("\n" `B.isInfixOf` received) $ SocketBytes.recv connection 4096 >>= \chunk -> unless (B.null chunk) (receive (received <> chunk))
        receive B.empty
        threadDelay (round (delay * 1000000))
        SocketBytes.sendAll connection response
  void (timeout 10000000 (takeMVar ready))
  pure (isJust <$> timeout 10000000 (takeMVar done))

-- ---------------------------------------------------------------------------
-- The helper

helperEnvironment :: FilePath -> FilePath -> IO [(String, String)]
helperEnvironment home transfer = do
  environment <- getEnvironment
  pure (("CODEX_HOME", home) : ("PETRUS_CODEX_ROLLOUT_ROOT", transfer) : filter ((`notElem` ["CODEX_HOME", "PETRUS_CODEX_ROLLOUT_ROOT"]) . fst) environment)

-- | @subprocess.run((sys.executable, "-c", _HELPER_SOURCE, *args), env=...)@.
runHelper :: FilePath -> FilePath -> [String] -> IO (ExitCode, ByteString, ByteString)
runHelper home transfer arguments = do
  python <- pythonExecutable
  source <- codexHelperSource
  environment <- helperEnvironment home transfer
  (_, Just out, Just err, handle) <-
    createProcess (proc python (["-c", T.unpack source] <> arguments)) {std_out = CreatePipe, std_err = CreatePipe, env = Just environment}
  stdout' <- B.hGetContents out
  stderr' <- B.hGetContents err
  code <- waitForProcess handle
  pure (code, stdout', stderr')

-- | @private_roots(tmp_path)@.
privateRoots :: FilePath -> IO (FilePath, FilePath)
privateRoots tmp = do
  let home = tmp </> "home"
      transfer = tmp </> "transfer"
  createDirectory home
  setFileMode home 0o700
  createDirectory transfer
  setFileMode transfer 0o700
  B.writeFile (home </> "auth.json") authCanary
  B.writeFile (transfer </> "rollout.jsonl") rolloutCanary
  setFileMode (home </> "auth.json") 0o600
  setFileMode (transfer </> "rollout.jsonl") 0o600
  pure (home, transfer)

events :: [Json] -> ByteString
events = B.intercalate "\n" . map (ok . J.dumps J.defaultDumps)

obj :: [(Text, Json)] -> Json
obj = Object

started', turnStarted :: Json
started' = obj [("type", String "thread.started"), ("thread_id", String thread')]
turnStarted = obj [("type", String "turn.started")]

failedTerminal, completedTerminal :: Json
failedTerminal = obj [("type", String "turn.failed"), ("error", obj [("message", String "safe")])]
completedTerminal = obj [("type", String "turn.completed"), ("usage", obj [])]

itemCompleted :: Text -> Text -> Json
itemCompleted identifier text = obj [("type", String "item.completed"), ("item", obj [("id", String identifier), ("type", String "agent_message"), ("text", String text)])]

-- ---------------------------------------------------------------------------
-- The suite

spec :: Spec
spec = describe "test_codex" $ do
  valueSpecs
  helperSpecs
  probeSpecs
  turnSpecs
  gondolinSpecs
  serviceSpecs
  verbatimSpecs

valueSpecs :: Spec
valueSpecs = do
  it "test_exact_descriptors_and_opaque_values_hide_provider_bodies" $ do
    let payload = ok (mkCodexContinuationPayloadV1 thread' rolloutPath' rolloutCanary)
    codexProgram.acceptsFreshStart `shouldBe` True
    codexProgram.ownership `shouldBe` ProviderOwned
    codexProgram.producedContinuation `shouldBe` Just (descriptorIdentity KindContinuation "codex.native-rollout" 1)
    ("schema_version=1" `isInfixOf` show payload) `shouldBe` True
    (BC.unpack rolloutCanary `isInfixOf` show payload) `shouldBe` False
    codexVersion `shouldBe` "0.145.0"
    codexSourceCommit `shouldBe` "1e85ca099e4265bf89f4016772d299816e231bb3"
    ("sha512-" `T.isPrefixOf` codexNpmIntegrity) `shouldBe` True
    codexA2Local.identity.name `shouldBe` "codex.a2.local"
    -- @__all__@: the Gondolin Activity name and adapter are not exported
    -- by the public Codex module (they live in CodexGondolin).
    exports <- fst . T.breakOn "\n  ) where" . snd . T.breakOn "( -- * Pins" . TE.decodeUtf8 <$> B.readFile ("src" </> "Petrus" </> "Agenticus" </> "Runtime" </> "Codex.hs")
    ("startCodex" `T.isInfixOf` exports, "parseJsonl" `T.isInfixOf` exports) `shouldBe` (True, True)
    ("codexGondolinActivity" `T.isInfixOf` exports, "CodexGondolinActivityAdapter" `T.isInfixOf` exports) `shouldBe` (False, False)
    leftWith "safe provider-relative" (mkCodexContinuationPayloadV1 thread' "../rollout.jsonl" rolloutCanary)
    leftWith "bounded file" (mkCodexContinuationPayloadV1 thread' rolloutPath' "")
    leftWith "bounded file" (mkCodexContinuationPayloadV1 thread' rolloutPath' (B.replicate (maxPrivateFileBytes + 1) 120))

  it "test_invocation_hides_prompt_and_requires_exact_file_auth_profile" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    invoked <- invoke rig "operation-values" promptCanary invocationOptions
    (promptCanary `T.isInfixOf` renderCodexRuntimeInvocation invoked.invocation) `shouldBe` False
    let current = invoked.invocation.connection
        wrong = ConnectionView (ok (mkConnectionIdentity "codex-connection" "codex" "safe-account" "ambient")) current.status current.authorityEpoch current.stateVersion current.stateDigest
    raisesWith ValueError "file-auth" (newCodexRuntimeInvocation (withConnection invoked.invocation wrong))
    settleAttachment invoked.attachment

  forM_
    [ ("events0-0-codex-lifecycle", [started'], 0, "codex-lifecycle")
    , ("events1-0-exit-inconsistent", [started', turnStarted, failedTerminal], 0, "exit-inconsistent")
    , ("events2-0-missing-agent-message", [started', turnStarted, completedTerminal], 0, "missing-agent-message")
    , ("events3-1-codex-lifecycle", [turnStarted, started', failedTerminal], 1, "codex-lifecycle")
    ]
    $ \(identifier, values, returncode, code) ->
      it ("test_jsonl_protocol_fails_closed[" <> identifier <> "]") $
        leftWith code (parseJsonl (events values) returncode)

  it "test_jsonl_uses_latest_sanitized_completed_agent_message" $ do
    let raw =
          events
            [ started'
            , turnStarted
            , itemCompleted "message-1" "first"
            , itemCompleted "message-2" "\x1b[31mlast\x1b[0m\x00"
            , obj [("type", String "turn.completed"), ("usage", obj [("provider", String "not retained")])]
            ]
        candidate = ok (parseJsonl raw 0)
    (candidate.threadId, candidate.completed, candidate.text) `shouldBe` (thread', True, Just "last\xfffd")
    ("provider" `isInfixOf` show candidate) `shouldBe` False

  forM_
    [ ("middle0-unknown-event", [obj [("type", String "protocol.drift")]], "unknown-event")
    , ("middle1-malformed-error", [obj [("type", String "error"), ("message", Int 7)]], "malformed-error")
    , ("middle2-malformed-item", [obj [("type", String "item.completed"), ("item", obj [("type", String "agent_message"), ("text", String "missing-id")])]], "malformed-item")
    , ("middle3-duplicate-item-terminal", [itemCompleted "same" "one", itemCompleted "same" "two"], "duplicate-item-terminal")
    ]
    $ \(identifier, middle, code) ->
      it ("test_jsonl_rejects_protocol_drift_and_malformed_items[" <> identifier <> "]") $
        leftWith code (parseJsonl (events ([started', turnStarted] <> middle <> [completedTerminal])) 0)

helperSpecs :: Spec
helperSpecs = do
  it "test_private_helper_stages_collects_and_scrubs_one_rollout" $ withTemp $ \tmp -> do
    (home, transfer) <- privateRoots tmp
    (code, out, err) <- runHelper home transfer ["stage", T.unpack thread', T.unpack rolloutPath']
    code `shouldBe` ExitSuccess
    (parseHelper out False, err) `shouldBe` (Right Nothing, "")
    let providerRollout = home </> T.unpack rolloutPath'
    B.writeFile providerRollout (rolloutCanary <> "-updated")
    setFileMode providerRollout 0o644
    B.writeFile (home </> "state_5.sqlite") "provider-state"
    (collected, collectedOut, collectedErr) <- runHelper home transfer ["collect", T.unpack thread']
    collected `shouldBe` ExitSuccess
    parseHelper collectedOut True `shouldBe` Right (Just (String rolloutPath'))
    (BC.pack tmp `B.isInfixOf` (collectedOut <> collectedErr)) `shouldBe` False
    B.readFile (transfer </> "rollout.jsonl") `shouldReturn` (rolloutCanary <> "-updated")
    listDirectory home `shouldReturn` ["auth.json"]

  it "test_helper_rejects_foreign_thread_symlinks_and_oversize_rollout" $ withTemp $ \tmp -> do
    (home, transfer) <- privateRoots tmp
    let refused arguments = runHelper home transfer arguments `shouldReturn` (ExitFailure 64, "", "")
    refused ["stage", T.unpack thread', T.unpack (T.replace thread' otherThread rolloutPath')]
    removeFile (transfer </> "rollout.jsonl")
    createSymbolicLink (home </> "auth.json") (transfer </> "rollout.jsonl")
    refused ["stage", T.unpack thread', T.unpack rolloutPath']
    removeFile (transfer </> "rollout.jsonl")
    B.writeFile (transfer </> "rollout.jsonl") (B.replicate (maxPrivateFileBytes + 1) 120)
    setFileMode (transfer </> "rollout.jsonl") 0o600
    refused ["stage", T.unpack thread', T.unpack rolloutPath']
    B.writeFile (transfer </> "rollout.jsonl") rolloutCanary
    setFileMode (transfer </> "rollout.jsonl") 0o600
    (code, _, err) <- runHelper home transfer ["stage", T.unpack thread', T.unpack rolloutPath']
    (code, err) `shouldBe` (ExitSuccess, "")
    let foreignPath = home </> T.unpack (T.replace thread' otherThread rolloutPath')
    createDirectoryIfMissing True (home </> "sessions" </> "2026" </> "08" </> "03")
    B.writeFile foreignPath rolloutCanary
    refused ["collect", T.unpack thread']

  it "test_scrub_removes_but_reports_symlink_invariant_violation" $ withTemp $ \tmp -> do
    (home, transfer) <- privateRoots tmp
    let victim = tmp </> "victim"
    B.writeFile victim "victim"
    createSymbolicLink victim (home </> "foreign")
    runHelper home transfer ["scrub"] `shouldReturn` (ExitFailure 64, "", "")
    B.readFile victim `shouldReturn` "victim"
    listDirectory home `shouldReturn` ["auth.json"]

probeSpecs :: Spec
probeSpecs = do
  it "test_probe_freezes_exact_installation_and_resolved_executable" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    result <- probeCodex rig.adapter
    result.disposition `shouldBe` ProbeReady
    codexExecutable rig.adapter `shouldReturn` Just rig.executable
    case result.installation of
      Just installation -> map (.version) installation.components `shouldBe` [codexVersion]
      Nothing -> expectationFailure "no installation"

  it "test_probe_reports_absence_version_drift_and_protocol_drift" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    writeIORef rig.probing.whichRef (\_ -> pure Nothing)
    (.disposition) <$> probeCodex rig.adapter `shouldReturn` ProbeNotInstalled
    writeIORef rig.probing.whichRef (\_ -> pure (Just "/qualified/codex"))
    writeIORef rig.probing.runRef $ \argv ->
      pure . Just $
        if take 1 (reverse argv) == ["--version"]
          then "codex-cli 0.146.0\n"
          else "SESSION_ID --json --color --sandbox --skip-git-repo-check --ignore-user-config"
    (.disposition) <$> probeCodex rig.adapter `shouldReturn` ProbeIncompatible
    writeIORef rig.probing.runRef $ \argv ->
      pure . Just $ if take 1 (reverse argv) == ["--version"] then "codex-cli 0.145.0\n" else "SESSION_ID --json"
    (.disposition) <$> probeCodex rig.adapter `shouldReturn` ProbeUnavailable
    codexExecutable rig.adapter `shouldReturn` Nothing

turnSpecs :: Spec
turnSpecs = do
  it "test_snapshot_mismatch_rejects_before_connection_materialization" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    let wrongRuntime = capabilityDescriptor (descriptorIdentity KindRuntime "wrong.runtime" 1) [] []
    invoked <- invoke rig "operation-snapshot" "first" invocationOptions {invSelected = Just (snapshot wrongRuntime)}
    protocolRaises "resolution-mismatch" (startCodex rig.adapter invoked.invocation)
    readIORef rig.custody.records `shouldReturn` []
    settleAttachment invoked.attachment

  it "test_fresh_turn_uses_real_local_private_roots_and_publication_order" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    invoked <- invoke rig "operation-first" "first" invocationOptions
    (operation, result) <- startWait rig invoked.invocation
    (result.outcome, result.acceptedAppends, result.terminationCode) `shouldBe` (TurnCompleted, 1, "turn-completed")
    result.outputReference `shouldBe` Just "codex-turn-operation-first"
    result.continuationReference `shouldBe` Just "codex-continuation-operation-first"
    payload <- loadPayload rig.continuations "codex-continuation-operation-first"
    (payload.threadId, payload.rolloutPath) `shouldBe` (thread', rolloutPath')
    ("first" `B.isInfixOf` payload.rollout, authCanary `B.isInfixOf` payload.rollout) `shouldBe` (True, False)
    Map.lookup "codex-turn-operation-first" <$> readIORef rig.turns.values `shouldReturn` Just (thread', "answer:first")
    readIORef rig.custody.auth `shouldReturn` (authCanary <> "|refreshed")
    kinds rig.custody `shouldReturn` ["materialize", "activate", "admit", "checkpoint"]
    commands <- codexCommands rig invoked.territory
    length commands `shouldBe` 1
    let argv = concat commands
    take 2 argv `shouldBe` [T.pack rig.executable, "exec"]
    drop (length argv - 2) argv `shouldBe` ["--", "first"]
    ("--ephemeral" `elem` argv, "resume" `elem` argv) `shouldBe` (False, False)
    (length (filter (== "--json") argv), length (filter (== "--ignore-rules") argv)) `shouldBe` (1, 1)
    take 1 (drop 1 (dropWhile (/= "--config") argv)) `shouldBe` ["cli_auth_credentials_store=file"]
    (TE.decodeUtf8 authCanary `T.isInfixOf` renderCodexOperation operation) `shouldBe` False
    rendered <- renderCodexRuntimeAdapter rig.adapter
    (promptCanary `T.isInfixOf` rendered) `shouldBe` False
    (.disposition) <$> closeCodexOperation operation `shouldReturn` RuntimeCleanupClean
    protocolRaises "operation-closed" (waitCodexOperation operation Nothing)
    settleAttachment invoked.attachment

  it "test_hyphen_prefixed_prompt_cannot_be_reparsed_as_a_codex_option" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    let prompt = "--dangerously-bypass-approvals-and-sandbox"
    invoked <- invoke rig "operation-option-prompt" prompt invocationOptions
    (operation, result) <- startWait rig invoked.invocation
    result.outcome `shouldBe` TurnCompleted
    commands <- codexCommands rig invoked.territory
    map (\argv -> drop (length argv - 2) argv) (take 1 commands) `shouldBe` [["--", prompt]]
    closeVerified operation
    settleAttachment invoked.attachment

  it "test_native_rollout_continues_in_replacement_local_attachment" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    first <- invoke rig "operation-one" "first" invocationOptions
    (firstOperation, firstResult) <- startWait rig first.invocation
    closeVerified firstOperation
    settleAttachment first.attachment
    second <- invoke rig "operation-two" "second" invocationOptions {invContinuation = Just (continuationFor (fromMaybe "" firstResult.continuationReference))}
    (secondOperation, secondResult) <- startWait rig second.invocation
    secondResult.outcome `shouldBe` TurnCompleted
    Map.lookup (fromMaybe "" secondResult.outputReference) <$> readIORef rig.turns.values `shouldReturn` Just (thread', "resumed:first:second")
    payload <- loadPayload rig.continuations (fromMaybe "" secondResult.continuationReference)
    (payload.threadId, "first" `B.isInfixOf` payload.rollout, "second" `B.isInfixOf` payload.rollout) `shouldBe` (thread', True, True)
    commands <- codexCommands rig second.territory
    let argv = concat (take 1 commands)
    (take 1 (drop 1 (dropWhile (/= "resume") argv)), drop (length argv - 1) argv) `shouldBe` ([thread'], ["second"])
    closeVerified secondOperation
    settleAttachment second.attachment

  it "test_provider_failure_checkpoints_auth_and_returns_native_continuation" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    invoked <- invoke rig "operation-provider-failure" "provider-failure" invocationOptions
    (operation, result) <- startWait rig invoked.invocation
    (result.outcome, result.acceptedAppends, result.terminationCode) `shouldBe` (TurnFailed, 0, "provider-failed")
    (result.outputReference, isJust result.continuationReference) `shouldBe` (Nothing, True)
    (\ks -> drop (length ks - 2) ks) <$> kinds rig.custody `shouldReturn` ["admit", "checkpoint"]
    closeVerified operation
    settleAttachment invoked.attachment

  forM_
    [ ("timeout", 2, 1000000, "command-timeout")
    , ("command-signal", 2, 1000000, "command-signal")
    , ("output-overflow", 2, 512, "output-overflow")
    , ("malformed-jsonl", 2, 1000000, "malformed-jsonl")
    , ("oversize-rollout", 2, 1000000, "collect-failed")
    ]
    $ \(prompt, limit, outputLimit, code) ->
      it ("test_ambiguous_or_malformed_turn_releases_without_publication[" <> T.unpack prompt <> "-2-" <> show outputLimit <> "-" <> T.unpack code <> "]") $
        withTemp $ \tmp -> do
          rig <- makeRig tmp rigOptions {optTimeout = limit, optOutputLimit = outputLimit}
          invoked <- invoke rig ("operation-" <> prompt) prompt invocationOptions
          (operation, result) <- startWait rig invoked.invocation
          (result.outcome, result.terminationCode) `shouldBe` (TurnFailed, code)
          (result.outputReference, result.continuationReference) `shouldBe` (Nothing, Nothing)
          recorded <- kinds rig.custody
          ("checkpoint" `elem` recorded, drop (length recorded - 1) recorded) `shouldBe` (False, ["release"])
          (.disposition) <$> closeCodexOperation operation `shouldReturn` RuntimeCleanupClean
          settleAttachment invoked.attachment

  it "test_cancellation_wins_before_candidate_publication" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions {optTimeout = 5}
    invoked <- invoke rig "operation-cancel" "cancel-me" invocationOptions
    operation <- startCodex rig.adapter invoked.invocation
    deadline <- (+ 2) <$> getMonotonicTime
    let poll = do
          seen <- not . null <$> codexCommands rig invoked.territory
          now <- getMonotonicTime
          unless (seen || now >= deadline) (threadDelay 10000 >> poll)
    poll
    cancelCodexOperation operation "navigator-cancelled" `shouldReturn` CancellationRequested
    cancelCodexOperation operation "navigator-cancelled" `shouldReturn` CancellationAlreadyRequested
    result <- waitCodexOperation operation (Just 5)
    (result.outcome, result.terminationCode) `shouldBe` (TurnCancelled, "cancelled")
    (result.outputReference, result.continuationReference) `shouldBe` (Nothing, Nothing)
    (\ks -> drop (length ks - 1) ks) <$> kinds rig.custody `shouldReturn` ["release"]
    cancelCodexOperation operation "late" `shouldReturn` CancellationTooLate
    closeVerified operation
    settleAttachment invoked.attachment

  it "test_cancellation_wins_while_candidate_bodies_are_still_being_stored" $ withTemp $ \tmp -> do
    continuations <- blockingContinuations
    rig <- makeRig tmp rigOptions {optContinuations = Just continuations}
    invoked <- invoke rig "operation-cancel-before-publish" "first" invocationOptions
    operation <- startCodex rig.adapter invoked.invocation
    let (entered, release) = fromMaybe (error "gate") continuations.gate
    timeout 5000000 (readMVar entered) `shouldReturn` Just ()
    cancelCodexOperation operation "cancel-before-publication" `shouldReturn` CancellationRequested
    putMVar release ()
    result <- waitCodexOperation operation (Just 5)
    result.outcome `shouldBe` TurnCancelled
    (result.outputReference, result.continuationReference) `shouldBe` (Nothing, Nothing)
    recorded <- kinds rig.custody
    ("checkpoint" `elem` recorded, drop (length recorded - 1) recorded) `shouldBe` (False, ["release"])
    closeVerified operation
    settleAttachment invoked.attachment

  it "test_publication_claim_makes_later_cancellation_too_late" $ withTemp $ \tmp -> do
    custody <- publishingCustody
    rig <- makeRig tmp rigOptions {optCustody = Just custody}
    invoked <- invoke rig "operation-publishing" "first" invocationOptions
    operation <- startCodex rig.adapter invoked.invocation
    let (entered, release) = fromMaybe (error "gate") custody.publication
    timeout 5000000 (readMVar entered) `shouldReturn` Just ()
    cancelCodexOperation operation "late-publication-race" `shouldReturn` CancellationTooLate
    putMVar release ()
    (.outcome) <$> waitCodexOperation operation (Just 5) `shouldReturn` TurnCompleted
    (\ks -> drop (length ks - 2) ks) <$> kinds custody `shouldReturn` ["admit", "checkpoint"]
    closeVerified operation
    settleAttachment invoked.attachment

  it "test_lookup_first_duplicate_and_changed_request_conflict" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    invoked <- invoke rig "operation-dedup" "first" invocationOptions
    (operation, result) <- startWait rig invoked.invocation
    again <- startCodex rig.adapter invoked.invocation
    (again == operation) `shouldBe` True
    protocolRaises "operation-conflict" (startCodex rig.adapter (withPrompt invoked.invocation "changed"))
    length <$> codexCommands rig invoked.territory `shouldReturn` 1
    result.outcome `shouldBe` TurnCompleted
    closeVerified operation
    settleAttachment invoked.attachment

  it "test_operation_identity_includes_the_exact_claimed_continuation_envelope" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    modifyIORef' rig.continuations.values (Map.insert "same-body" (ok (mkCodexContinuationPayloadV1 thread' rolloutPath' rolloutCanary)))
    let claimed = continuationFor "same-body"
        available = continuationWith "continuation-same-body" "same-body" ContinuationAvailable
    invoked <- invoke rig "operation-continuation-identity" "second" invocationOptions {invContinuation = Just available}
    protocolRaises "continuation-not-claimed" (startCodex rig.adapter invoked.invocation)
    operation <- startCodex rig.adapter (withContinuation invoked.invocation (Just claimed))
    (.outcome) <$> waitCodexOperation operation (Just 5) `shouldReturn` TurnCompleted
    let changedIdentity = continuationWith "continuation-other" "same-body" ContinuationInUse
    protocolRaises "operation-conflict" (startCodex rig.adapter (withContinuation invoked.invocation (Just changedIdentity)))
    closeVerified operation
    settleAttachment invoked.attachment

  it "test_real_connection_custody_and_local_motus_route_refresh_and_cleanup" $ withTemp $ \tmp -> do
    let installation = tmp </> "installation"
    createDirectory installation
    setFileMode installation 0o700
    storage <- openSqliteConnectionStorage (installation </> "connections.sqlite3")
    keys <- aesKeys
    let materializedRoot = installation </> "materialized"
    materializer <- newPrivateFileMaterializer materializedRoot
    let custody = agentConnectionCustody storage keys materializer getMonotonicTime
    enrollHost custody "host-1" "enroll-codex-host"
    state <- newOpaqueState authCanary
    _ <- authorize custody (ok (mkConnectionIdentity "codex-real" "codex" "safe-account" "file-auth")) state "authorize-codex"
    executable <- fakeCodex tmp codexVersion
    continuations <- newContinuations
    turns <- newTurns
    probing <- probeEnvironment (Just executable)
    options <- adapterOptions probing.hooks
    operations <- hostConnectionCustody custody
    adapter <-
      newCodexRuntimeAdapter
        (codexRuntimeConfig "host-1") {credentialTtl = 2, commandTimeout = 2, cancellationGrace = 1}
        (codexContinuationCodec (continuationOperations continuations))
        (turnOperations turns)
        operations
        options
    (.disposition) <$> probeCodex adapter `shouldReturn` ProbeReady
    provider <- recordingLocal
    let source = tmp </> "real-workspace"
    createDirectory source
    archive <- workspaceArchive source
    binding <-
      openMotusBinding provider.provider "territory-real-custody" (ok (mkEnvironmentSpec Nothing [capPrivateFileTransfer])) archive "input-real-custody"
    now <- getMonotonicTime
    attachment <-
      newEpisodeAttachment (ok (mkEpisodeId "episode-real-custody")) (snapshot codexA2Local) (motusBinding binding) "agenticus-attachment-real-custody" (now + 5) episodeOptions
    view <- lookupConnection custody "codex-real"
    invocation <-
      newCodexRuntimeInvocation
        CodexRuntimeInvocation
          { operationId = "operation-real-custody"
          , episodeId = Episode.episodeId attachment
          , turnId = ok (mkTurnId "turn-real-custody")
          , prompt = "first"
          , connection = view
          , attachment
          , continuation = Nothing
          }
    operation <- startCodex adapter invocation
    (.outcome) <$> waitCodexOperation operation (Just 5) `shouldReturn` TurnCompleted
    closeVerified operation
    (.stateVersion) <$> lookupConnection custody "codex-real" `shouldReturn` 2
    listDirectory materializedRoot `shouldReturn` []
    verification <- Custody.materialize custody "codex-real" "host-1" LeaseRead 2 "verify-codex-refresh"
    readMaterialized verification.home `shouldReturn` (authCanary <> "|refreshed")
    released <- Custody.release custody verification "release-codex-verification"
    released.cleanup.removed `shouldBe` True
    listDirectory materializedRoot `shouldReturn` []
    settleAttachment attachment
    closeCustody custody

  it "test_stale_connection_fence_releases_before_provider_execution" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    writeIORef rig.custody.mismatchedFence True
    invoked <- invoke rig "operation-stale" "first" invocationOptions
    (operation, result) <- startWait rig invoked.invocation
    (result.outcome, result.terminationCode) `shouldBe` (TurnFailed, "custody-state-mismatch")
    codexCommands rig invoked.territory `shouldReturn` []
    kinds rig.custody `shouldReturn` ["materialize", "release"]
    closeVerified operation
    settleAttachment invoked.attachment

  it "test_connection_cleanup_uncertainty_blocks_candidate_result" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    writeIORef rig.custody.checkpointCleanupUncertain True
    invoked <- invoke rig "operation-connection-cleanup" "first" invocationOptions
    (operation, result) <- startWait rig invoked.invocation
    (result.outcome, result.terminationCode) `shouldBe` (TurnFailed, "connection-cleanup-uncertain")
    (result.outputReference, result.continuationReference) `shouldBe` (Nothing, Nothing)
    (.disposition) <$> closeCodexOperation operation `shouldReturn` RuntimeCleanupUnverified
    settleAttachment invoked.attachment

  it "test_private_cleanup_uncertainty_blocks_candidate_result" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    provider <- uncertainCleanupLocal
    invoked <- invoke rig "operation-private-cleanup" "first" invocationOptions {invProvider = Just provider}
    (operation, result) <- startWait rig invoked.invocation
    (result.outcome, result.terminationCode) `shouldBe` (TurnFailed, "private-cleanup-uncertain")
    (.disposition) <$> closeCodexOperation operation `shouldReturn` RuntimeCleanupUnverified
    settleAttachment invoked.attachment

  it "test_expired_deadline_creates_no_connection_or_runtime_state" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    now <- getMonotonicTime
    invoked <- invoke rig "operation-expired" "first" invocationOptions {invDeadline = Just (now - 1)}
    (operation, result) <- startWait rig invoked.invocation
    (result.outcome, result.terminationCode) `shouldBe` (TurnFailed, "deadline-exceeded")
    readIORef rig.custody.records `shouldReturn` []
    readIORef invoked.territory.commands >>= (`shouldBe` 0) . length
    (.disposition) <$> closeCodexOperation operation `shouldReturn` RuntimeCleanupNotCreated
    settleAttachment invoked.attachment

  it "test_codex_runtime_import_has_no_optional_provider_dependency" $ do
    -- The Haskell analogue of the import blocker: the library links no
    -- optional provider SDK package (openai, docker, e2b, gondolin).
    cabal <- TE.decodeUtf8 <$> B.readFile "petrus-agenticus-runtime.cabal"
    let library = T.takeWhile (/= '\n') . snd . T.breakOn "build-depends:" . snd . T.breakOn "\nlibrary" $ cabal
        section = fst (T.breakOn "\ntest-suite" (snd (T.breakOn "\nlibrary" cabal)))
    T.null library `shouldBe` False
    forM_ ["openai", "docker", "e2b", "gondolin"] $ \blocked ->
      (blocked, (", " <> blocked) `T.isInfixOf` section) `shouldBe` (blocked, False)

gondolinSpecs :: Spec
gondolinSpecs = do
  it "test_gondolin_lane_reuses_one_episode_territory_across_replacement_operation_and_resume" $ withTemp $ \tmp -> do
    codexGondolinSdkVersion `shouldBe` "0.12.0"
    g <- gondolinRig tmp "gondolin" codexGondolinVersion
    (.disposition) <$> probeCodexGondolin g.adapter Nothing `shouldReturn` ProbeUnavailable
    (failed, attachment, binding) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-failed" "provider-failure" Nothing
    let territory = bindingLeaseIdentity binding
    recreated <- newGondolinEnvironment g.gondolinRoot (gondolinConfig (T.pack g.sdk)) {gondolinLeaseTtl = 30}
    fmap leaseIdentity <$> gondolinLookup recreated territory.identityOperationId `shouldReturn` Just territory
    length <$> listDirectory g.gondolinRoot `shouldReturn` 1
    protocolRaises "territory-not-qualified" (startCodex g.adapter failed)
    probe <- probeCodexGondolin g.adapter (Just attachment)
    probe.disposition `shouldBe` ProbeReady
    case probe.installation of
      Nothing -> expectationFailure "no installation"
      Just installation -> do
        installation.runtime `shouldBe` codexA3Gondolin.identity
        (installation.platform, installation.architecture) `shouldBe` ("linux", "aarch64")
        case installation.components of
          [component] -> do
            component.version `shouldBe` codexGondolinVersion
            forM_ [codexGondolinImageRef, codexGondolinBuildId, codexGondolinOciDigest] $ \pin ->
              (pin `T.isInfixOf` component.sourceIdentity) `shouldBe` True
          _ -> expectationFailure "one component"
    failedOperation <- startCodex g.adapter failed
    failedResult <- waitCodexOperation failedOperation (Just 10)
    (failedResult.outcome, failedResult.terminationCode) `shouldBe` (TurnFailed, "provider-failed")
    (failedResult.outputReference, isJust failedResult.continuationReference) `shouldBe` (Nothing, True)
    closeVerified failedOperation
    failedPayload <- loadPayload g.continuations (fromMaybe "" failedResult.continuationReference)
    bindingLeaseIdentity binding `shouldBe` territory
    view <- custodyView g.custody
    let next operationId turn prompt reference =
          newCodexRuntimeInvocation
            CodexRuntimeInvocation
              { operationId
              , episodeId = Episode.episodeId attachment
              , turnId = ok (mkTurnId turn)
              , prompt
              , connection = view
              , attachment
              , continuation = Just (continuationFor reference)
              }
    first <- next "operation-gondolin-replacement" "turn-gondolin-replacement" "first" (fromMaybe "" failedResult.continuationReference)
    firstOperation <- startCodex g.adapter first
    firstResult <- waitCodexOperation firstOperation (Just 10)
    (firstResult.outcome, firstResult.acceptedAppends) `shouldBe` (TurnCompleted, 1)
    closeVerified firstOperation
    firstPayload <- loadPayload g.continuations (fromMaybe "" firstResult.continuationReference)
    Map.lookup (fromMaybe "" firstResult.outputReference) <$> readIORef g.turns.values `shouldReturn` Just (thread', "answer:first")
    firstPayload.threadId `shouldBe` failedPayload.threadId
    (failedPayload.rollout `B.isInfixOf` firstPayload.rollout, "first" `B.isInfixOf` firstPayload.rollout) `shouldBe` (True, True)
    view' <- custodyView g.custody
    second <-
      newCodexRuntimeInvocation
        CodexRuntimeInvocation
          { operationId = "operation-gondolin-phase-two"
          , episodeId = Episode.episodeId attachment
          , turnId = ok (mkTurnId "turn-gondolin-phase-two")
          , prompt = "second"
          , connection = view'
          , attachment
          , continuation = Just (continuationFor (fromMaybe "" firstResult.continuationReference))
          }
    secondOperation <- startCodex g.adapter second
    secondResult <- waitCodexOperation secondOperation (Just 10)
    secondResult.outcome `shouldBe` TurnCompleted
    closeVerified secondOperation
    secondPayload <- loadPayload g.continuations (fromMaybe "" secondResult.continuationReference)
    secondPayload.threadId `shouldBe` firstPayload.threadId
    (firstPayload.rollout `B.isInfixOf` secondPayload.rollout, "second" `B.isInfixOf` secondPayload.rollout) `shouldBe` (True, True)
    Map.lookup (fromMaybe "" secondResult.outputReference) <$> readIORef g.turns.values `shouldReturn` Just (thread', "resumed:first:second")
    settled <- Episode.settle attachment 2
    settled.settlement.verified `shouldBe` True
    let restored = tmp </> "gondolin-settled-workspace"
    extractWorkspaceArchive settled.archive restored
    readFile (restored </> "public-input.txt") `shouldReturn` "public-workspace-canary"
    (authCanary `B.isInfixOf` settled.archive) `shouldBe` False
    forM_ [failedPayload, firstPayload, secondPayload] $ \p -> (p.rollout `B.isInfixOf` settled.archive) `shouldBe` False
    cleanup <- bindingCleanupResult binding
    fmap (\c -> (c.cleanupIdentity, c.cleanupDisposition)) cleanup `shouldBe` Just (territory, Clean)
    gondolinLookup recreated territory.identityOperationId >>= (`shouldBe` True) . isNothing
    listDirectory g.gondolinRoot `shouldReturn` []

  it "test_gondolin_episode_releases_to_reconstructed_host_custody_then_reclaims_exact_lease" $ withTemp $ \tmp -> do
    g <- gondolinRig tmp "gondolin-retained" codexGondolinVersion
    (first, attachment, binding) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-retained" "first" Nothing
    (.disposition) <$> probeCodexGondolin g.adapter (Just attachment) `shouldReturn` ProbeReady
    firstOperation <- startCodex g.adapter first
    firstResult <- waitCodexOperation firstOperation (Just 10)
    firstResult.outcome `shouldBe` TurnCompleted
    closeVerified firstOperation
    let territory = bindingLeaseIdentity binding
        ledgerPath = tmp </> "territory-custody" </> "custody.db"
    custody <- openTerritoryCustodyWith ledgerPath (pure 10)
    released <- Retention.release custody "retained-codex" "host-1" attachment 100 2
    released.territory `shouldBe` territory
    (authCanary `B.isInfixOf` released.archive) `shouldBe` False
    payload <- loadPayload g.continuations (fromMaybe "" firstResult.continuationReference)
    (payload.rollout `B.isInfixOf` released.archive) `shouldBe` False
    g.lookupLease territory.identityOperationId `shouldReturn` Just territory
    length <$> listDirectory g.gondolinRoot `shouldReturn` 1
    closeTerritoryCustody custody
    reconstructedProvider <- gondolinProviderAt g.gondolinRoot g.sdk
    reconstructed <- openTerritoryCustodyWith ledgerPath (pure 20)
    now <- getMonotonicTime
    reclaimed <-
      reclaim reconstructed "retained-codex" "host-1" reconstructedProvider (ok (mkEpisodeId "episode-gondolin-reclaimed")) gondolinSnapshot "agenticus-attachment-gondolin-reclaimed" (now + 15) Nothing Nothing
    reclaimedBinding <- maybe (fail "motus binding") pure (Episode.episodeBinding reclaimed).motus
    bindingLeaseIdentity reclaimedBinding `shouldBe` territory
    previous <- Episode.coordinates attachment
    current <- Episode.coordinates reclaimed
    current.attachmentEpoch `shouldBe` previous.attachmentEpoch + 1
    fmap (.phase) <$> lookupCustody reconstructed "retained-codex" `shouldReturn` Just Attached
    g.lookupLease territory.identityOperationId `shouldReturn` Just territory
    length <$> listDirectory g.gondolinRoot `shouldReturn` 1
    (.disposition) <$> probeCodexGondolin g.adapter (Just reclaimed) `shouldReturn` ProbeReady
    view <- custodyView g.custody
    second <-
      newCodexRuntimeInvocation
        CodexRuntimeInvocation
          { operationId = "operation-gondolin-reclaimed-runtime"
          , episodeId = Episode.episodeId reclaimed
          , turnId = ok (mkTurnId "turn-gondolin-reclaimed-runtime")
          , prompt = "second"
          , connection = view
          , attachment = reclaimed
          , continuation = Just (continuationFor (fromMaybe "" firstResult.continuationReference))
          }
    secondOperation <- startCodex g.adapter second
    (.outcome) <$> waitCodexOperation secondOperation (Just 10) `shouldReturn` TurnCompleted
    closeVerified secondOperation
    _ <- Retention.release reconstructed "retained-codex" "host-1" reclaimed 110 2
    retired <- retire reconstructed "retained-codex" "host-1" reconstructedProvider
    retired.phase `shouldBe` Retired
    g.lookupLease territory.identityOperationId `shouldReturn` Nothing
    listDirectory g.gondolinRoot `shouldReturn` []
    closeTerritoryCustody reconstructed

  it "test_gondolin_retained_lease_is_reclaimed_and_released_by_a_replacement_host_process" $ withTemp $ \tmp -> do
    -- The replacement host process is the reference itself: the pinned
    -- Python reclaims and re-releases the lease from this Haskell-written
    -- retention ledger and Gondolin registry.
    g <- gondolinRig tmp "gondolin-process-retained" codexGondolinVersion
    (_, attachment, binding) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-process-retained" "unused" Nothing
    let territory = bindingLeaseIdentity binding
        ledgerPath = tmp </> "process-territory-custody" </> "custody.db"
        resultPath = tmp </> "replacement-result.json"
    custody <- openTerritoryCustodyWith ledgerPath (pure 10)
    _ <- Retention.release custody "process-retained" "host-1" attachment 100 2
    closeTerritoryCustody custody
    result <- runPython replacementHostScript [g.gondolinRoot, g.sdk, ledgerPath, resultPath] ""
    (result.resultExit, result.resultStderr) `shouldBe` (ExitSuccess, "")
    written <- ok . J.parseJson J.surrogateRefusingLoads <$> B.readFile resultPath
    let field name = case written of
          Object members -> fromMaybe Null (lookup name members)
          _ -> Null
    (field "operation_id", field "provider", field "lease_id")
      `shouldBe` (String territory.identityOperationId, String territory.identityProvider, String territory.identityLeaseId)
    coordinates <- Episode.coordinates attachment
    field "epoch" `shouldBe` Int (coordinates.attachmentEpoch + 1)
    (field "execution_attachment" /= Null && field "execution_attachment" /= String "") `shouldBe` True
    length <$> listDirectory g.gondolinRoot `shouldReturn` 1
    recovered <- openTerritoryCustodyWith ledgerPath (pure 30)
    record <- lookupCustody recovered "process-retained"
    fmap (\r -> (r.phase, r.generation)) record `shouldBe` Just (Retained, 2)
    (.phase) <$> retire recovered "process-retained" "host-1" g.territory.provider `shouldReturn` Retired
    g.lookupLease territory.identityOperationId `shouldReturn` Nothing
    listDirectory g.gondolinRoot `shouldReturn` []
    closeTerritoryCustody recovered

  it "test_gondolin_activity_inline_retry_keeps_host_owned_episode_territory" $ withTemp $ \tmp -> do
    g <- gondolinRig tmp "gondolin-activity" codexGondolinVersion
    (_, attachment, binding) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-activity-episode" "unused" Nothing
    (.disposition) <$> probeCodexGondolin g.adapter (Just attachment) `shouldReturn` ProbeReady
    view <- custodyView g.custody
    activity <- newCodexGondolinActivityAdapter g.adapter view attachment
    attempts <- newIORef []
    writeIORef g.wrapStart $ \original runtime -> do
      coordinates <- Episode.coordinates runtime.attachment
      modifyIORef' attempts (<> [(runtime.operationId, coordinates.attachmentId, (bindingLeaseIdentity binding).identityLeaseId)])
      attempted <- length <$> readIORef attempts
      when (attempted == 1) $ throwIO (runtimeProtocolErrorFor "runtime-not-ready")
      original runtime
    contexts <- newIORef []
    let recording invocation context = do
          modifyIORef' contexts (<> [(context.attemptId, context.epoch)])
          runCodexGondolinActivityAdapter activity invocation context
    input <- gondolinActivityInput attachment g.custody "first" "turn-gondolin-activity" Nothing
    dispatch <- newInlineDispatch (Map.fromList [(codexGondolinActivity, recording)])
    result <- runInline dispatch (activityInvocation codexGondolinActivity input (Just "operation-gondolin-activity-runtime") (retryPolicy 2 30))
    readIORef contexts `shouldReturn` [("inline-1", "1"), ("inline-2", "2")]
    recorded <- readIORef attempts
    (length recorded, Set.size (Set.fromList recorded)) `shouldBe` (2, 1)
    result `shouldBe` expectedResult "operation-gondolin-activity-runtime" (lifecycleIdText (Episode.episodeId attachment)) "turn-gondolin-activity"
    map (\(_, _, lease) -> lease) (take 1 recorded) `shouldBe` [(bindingLeaseIdentity binding).identityLeaseId]
    (.settlement.verified) <$> Episode.settle attachment 2 `shouldReturn` True
    listDirectory g.gondolinRoot `shouldReturn` []

  it "test_gondolin_runtime_service_replays_terminal_to_replacement_local_worker" $ withTemp $ \tmp ->
    replacementWorker tmp startCodexWorker

  it "test_gondolin_activity_refuses_unfenced_or_stale_requests_before_runtime_start" $ withTemp $ \tmp -> do
    g <- gondolinRig tmp "gondolin-activity-fences" codexGondolinVersion
    (_, attachment, _) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-activity-fences" "unused" Nothing
    view <- custodyView g.custody
    activity <- newCodexGondolinActivityAdapter g.adapter view attachment
    value <- gondolinActivityInput attachment g.custody "first" "turn-gondolin-fences" Nothing
    writeIORef g.wrapStart $ \_ _ -> expectationFailure "stale request started runtime work" >> fail "started"
    let with field replacement = case value of
          Object members -> Object [(k, if k == field then replacement else v) | (k, v) <- members]
          other -> other
        call name input idempotency stale = do
          (context, _) <- activityContext stale
          runCodexGondolinActivityAdapter activity (activityInvocation name input idempotency (policyFields defaultExecutionPolicy)) context
    protocolRaises "idempotency-required" (call codexGondolinActivity value Nothing False)
    protocolRaises "input-invalid" (call codexGondolinActivity (with "attachment_epoch" (Int 2)) (Just "operation-stale-fence") False)
    -- @EqualityString@ cannot cross a JSON boundary; its plain value is
    -- the foreign attachment it names.
    protocolRaises "input-invalid" (call codexGondolinActivity (with "attachment_id" (String "wrong-attachment")) (Just "operation-equality-fence") False)
    protocolRaises "activity-mismatch" (call "wrong-activity" value (Just "operation-equality-activity") False)
    forM_
      [ ("version", Bool True)
      , ("attachment_epoch", Float 1.0)
      , ("authority_epoch", Bool True)
      , ("state_version", Float (1 / 0))
      , ("prompt", Null)
      , ("continuation", Array [])
      ]
      $ \(field, invalid) ->
        protocolRaises "input-invalid" (call codexGondolinActivity (with field invalid) (Just ("operation-invalid-" <> field)) False)
    protocolRaises "activity-stale" (call codexGondolinActivity value (Just "operation-stale-context") True)
    writeIORef g.wrapStart $ \_ _ -> throwAgenticus RuntimeError (TE.decodeUtf8 authCanary)
    redacted <- try (call codexGondolinActivity value (Just "operation-redacted-admission") False)
    case redacted of
      Left (e :: AgenticusError) -> do
        e.errorMessage `shouldBe` "runtime protocol error: runtime-admission-failed"
        (TE.decodeUtf8 authCanary `T.isInfixOf` T.pack (show e)) `shouldBe` False
      Right _ -> expectationFailure "expected runtime-admission-failed"
    readIORef g.custody.records `shouldReturn` []
    (.settlement.verified) <$> Episode.settle attachment 2 `shouldReturn` True
    listDirectory g.gondolinRoot `shouldReturn` []

  it "test_gondolin_lane_rejects_guest_version_drift_before_materialization" $ withTemp $ \tmp -> do
    g <- gondolinRig tmp "gondolin-drift" codexVersion
    (invocation, attachment, _) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-drift" "never-run" Nothing
    probe <- probeCodexGondolin g.adapter (Just attachment)
    probe.disposition `shouldBe` ProbeIncompatible
    fmap (map (.version) . (.components)) probe.installation `shouldBe` Just [codexVersion]
    readIORef g.custody.records `shouldReturn` []
    protocolRaises "territory-not-qualified" (startCodex g.adapter invocation)
    (.settlement.verified) <$> Episode.settle attachment 2 `shouldReturn` True

  it "test_gondolin_lane_requires_its_exact_guest_helper_before_materialization" $ withTemp $ \tmp -> do
    g <- gondolinRigWith (\o -> o {guestInterpreter = "/missing/petrus-python3"}) tmp "gondolin-helper" codexGondolinVersion
    (invocation, attachment, _) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-helper" "never-run" Nothing
    probe <- probeCodexGondolin g.adapter (Just attachment)
    probe.disposition `shouldBe` ProbeUnavailable
    map (.code) (take 1 probe.issues) `shouldBe` ["territory-probe-failed"]
    readIORef g.custody.records `shouldReturn` []
    protocolRaises "territory-not-qualified" (startCodex g.adapter invocation)
    (.settlement.verified) <$> Episode.settle attachment 2 `shouldReturn` True

  forM_ ["import", "export", "delete", "cleanup"] $ \failedPhase ->
    it ("test_gondolin_lane_private_probe_failure_cleans_and_never_qualifies_or_materializes[" <> T.unpack failedPhase <> "]") $ withTemp $ \tmp -> do
      g <- gondolinRig tmp ("gondolin-" <> T.unpack failedPhase) codexGondolinVersion
      (invocation, attachment, _) <- gondolinInvocation tmp g.territory.provider g.custody ("operation-gondolin-" <> failedPhase) "never-run" Nothing
      let failing :: IO a
          failing = throwAgenticus RuntimeError "private probe failed"
      case failedPhase of
        "import" -> writeIORef g.territory.importWrap (\_ _ _ -> failing)
        "export" -> writeIORef g.territory.exportWrap (\_ _ _ -> failing)
        "delete" -> writeIORef g.territory.deleteWrap (\original a r -> (\x -> x {privateCleanupDisposition = Unverified}) <$> original a r)
        _ -> pure ()
      cleanupCalls <- newIORef (0 :: Int)
      writeIORef g.territory.cleanupWrap $ \original a -> do
        modifyIORef' cleanupCalls (+ 1)
        result <- original a
        pure (if failedPhase == "cleanup" then result {privateCleanupDisposition = Unverified} else result)
      probe <- probeCodexGondolin g.adapter (Just attachment)
      probe.disposition `shouldBe` ProbeUnavailable
      map (.code) (take 1 probe.issues) `shouldBe` ["territory-probe-failed"]
      readIORef cleanupCalls `shouldReturn` 1
      readIORef g.custody.records `shouldReturn` []
      protocolRaises "territory-not-qualified" (startCodex g.adapter invocation)
      (.settlement.verified) <$> Episode.settle attachment 2 `shouldReturn` True

  it "test_gondolin_private_probe_cleanup_drains_before_host_retention_export" $ withTemp $ \tmp -> do
    g <- gondolinRig tmp "gondolin-probe-release" codexGondolinVersion
    (_, attachment, binding) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-probe-release" "never-run" Nothing
    entered <- newEmptyMVar
    finish <- newEmptyMVar
    exported <- newIORef False
    writeIORef g.territory.cleanupWrap $ \original a -> do
      void (tryPutMVar entered ())
      -- Upstream waits 2 s and 1 s below; the port allows 20 s and 10 s so a
      -- loaded machine cannot fail it. Only the bounds change.
      finished <- timeout 20000000 (readMVar finish)
      when (isNothing finished) $ throwAgenticus (OtherError "AssertionError") "finish"
      original a
    writeIORef g.territory.workspaceExportWrap $ \original a -> writeIORef exported True >> original a
    custody <- openTerritoryCustodyWith (tmp </> "probe-custody" </> "custody.db") (pure 10)
    probing <- newEmptyMVar
    void (forkIO (try @SomeException (probeCodexGondolin g.adapter (Just attachment)) >>= putMVar probing))
    timeout 10000000 (readMVar entered) `shouldReturn` Just ()
    releasing <- newEmptyMVar
    void (forkIO (try @SomeException (Retention.release custody "custody-probe" "host-1" attachment 50 2) >>= putMVar releasing))
    deadline <- (+ 10) <$> getMonotonicTime
    let observe = do
          admitted <- try (withBindingOperation binding (pure ()))
          case admitted of
            Left (e :: AgenticusError) | e.errorClass == MotusBindingError -> pure True
            _ -> do
              now <- getMonotonicTime
              if now >= deadline then pure False else threadDelay 1000 >> observe
    observe `shouldReturn` True
    isEmptyMVar releasing `shouldReturn` True
    readIORef exported `shouldReturn` False
    putMVar finish ()
    probed <- timeout 5000000 (takeMVar probing)
    fmap (either (const False) (const True)) probed `shouldBe` Just True
    released <- timeout 5000000 (takeMVar releasing)
    readIORef exported `shouldReturn` True
    fmap (.phase) <$> lookupCustody custody "custody-probe" `shouldReturn` Just Retained
    (.phase) <$> retire custody "custody-probe" "host-1" g.territory.provider `shouldReturn` Retired
    closeTerritoryCustody custody
    case released of
      Just (Right value) -> value.territory `shouldBe` bindingLeaseIdentity binding
      other -> expectationFailure ("release failed: " <> show (fmap (either show (const "")) other))

  it "test_gondolin_lane_failed_reprobe_revokes_only_that_exact_attachment" $ withTemp $ \tmp -> do
    g <- gondolinRig tmp "gondolin-reprobe" codexGondolinVersion
    (first, firstAttachment, _) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-reprobe-first" "never-run" Nothing
    (.disposition) <$> probeCodexGondolin g.adapter (Just firstAttachment) `shouldReturn` ProbeReady
    writeIORef g.territory.importWrap (\_ _ _ -> throwAgenticus RuntimeError "private probe failed")
    (.disposition) <$> probeCodexGondolin g.adapter (Just firstAttachment) `shouldReturn` ProbeUnavailable
    writeIORef g.territory.importWrap id
    (_, secondAttachment, _) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-reprobe-second" "never-run" Nothing
    (.disposition) <$> probeCodexGondolin g.adapter (Just secondAttachment) `shouldReturn` ProbeReady
    protocolRaises "territory-not-qualified" (startCodex g.adapter first)
    readIORef g.custody.records `shouldReturn` []
    (.settlement.verified) <$> Episode.settle firstAttachment 2 `shouldReturn` True
    (.settlement.verified) <$> Episode.settle secondAttachment 2 `shouldReturn` True

  it "test_gondolin_lane_cancellation_closes_the_vm_discards_output_and_still_settles" $ withTemp $ \tmp -> do
    g <- gondolinRig tmp "gondolin-cancel" codexGondolinVersion
    (invocation, attachment, _) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-cancel" "cancel-me" Nothing
    (.disposition) <$> probeCodexGondolin g.adapter (Just attachment) `shouldReturn` ProbeReady
    operation <- startCodex g.adapter invocation
    let started = tmp </> "fake-codex-command-started"
    waitUntil 5 (doesFileExist started)
    cancelCodexOperation operation "navigator-cancelled" `shouldReturn` CancellationRequested
    result <- waitCodexOperation operation (Just 10)
    (result.outcome, result.acceptedAppends) `shouldBe` (TurnCancelled, 0)
    (result.outputReference, result.continuationReference) `shouldBe` (Nothing, Nothing)
    (.disposition) <$> closeCodexOperation operation `shouldReturn` RuntimeCleanupUnverified
    (.settlement.verified) <$> Episode.settle attachment 2 `shouldReturn` True
    Map.null <$> readIORef g.continuations.values `shouldReturn` True
    Map.null <$> readIORef g.turns.values `shouldReturn` True
    listDirectory g.gondolinRoot `shouldReturn` []

runtimeProtocolErrorFor :: Text -> AgenticusError
runtimeProtocolErrorFor code = AgenticusError RuntimeProtocolError ("runtime protocol error: " <> code)

expectedResult :: Text -> Text -> Text -> Json
expectedResult operationId episode turn =
  Object
    [ ("version", Int 1)
    , ("operation_id", String operationId)
    , ("episode_id", String episode)
    , ("turn_id", String turn)
    , ("outcome", String "completed")
    , ("accepted_appends", Int 1)
    , ("termination_code", String "turn-completed")
    , ("output_reference", String ("codex-turn-" <> operationId))
    , ("continuation_reference", String ("codex-continuation-" <> operationId))
    , ("cleanup", Object [("disposition", String "clean"), ("code", String "client-closed")])
    ]

-- | The replacement host process of
-- @test_gondolin_retained_lease_is_reclaimed_and_released_by_a_replacement_host_process@,
-- verbatim.
replacementHostScript :: Text
replacementHostScript =
  "\n\
  \import json, sys\n\
  \from pathlib import Path\n\
  \from petrus.agenticus.attachment._retention import SqliteTerritoryCustody\n\
  \from petrus.agenticus.catalog.descriptor import CapabilityDescriptor, DescriptorIdentity, DescriptorKind\n\
  \from petrus.agenticus.catalog.resolution import ResolutionSnapshot\n\
  \from petrus.agenticus.thread.identity import EpisodeId\n\
  \from petrus.motus.execution.gondolin import GondolinEnvironment\n\
  \\n\
  \root, sdk, ledger, output = map(Path, sys.argv[1:])\n\
  \snapshot = ResolutionSnapshot(1, tuple(\n\
  \    CapabilityDescriptor(DescriptorIdentity(kind, f'{kind.value}-replacement', 1), frozenset(), ())\n\
  \    for kind in (DescriptorKind.RUNTIME, DescriptorKind.HANDS, DescriptorKind.TERRITORY)\n\
  \))\n\
  \provider = GondolinEnvironment(root, sdk_module=str(sdk), lease_ttl=30)\n\
  \custody = SqliteTerritoryCustody(ledger, clock=lambda: 20)\n\
  \attachment = custody.reclaim(\n\
  \    'process-retained', 'host-1', provider,\n\
  \    episode_id=EpisodeId('episode-replacement-process'), snapshot=snapshot,\n\
  \    attachment_id='attachment-replacement-process', deadline=100,\n\
  \)\n\
  \identity = attachment.binding.lease_identity\n\
  \epoch = attachment.epoch\n\
  \execution_attachment = attachment.binding.execution.attachment_id\n\
  \custody.release('process-retained', 'host-1', attachment, retain_until=100, drain_timeout=2)\n\
  \custody.close()\n\
  \output.write_text(json.dumps({\n\
  \    'operation_id': identity.operation_id, 'provider': identity.provider,\n\
  \    'lease_id': identity.lease_id, 'epoch': epoch,\n\
  \    'execution_attachment': execution_attachment,\n\
  \}))\n"

-- | The body of
-- @test_gondolin_runtime_service_replays_terminal_to_replacement_local_worker@
-- over a Worker launcher (this binary, or the reference's own Worker).
replacementWorker :: FilePath -> (FilePath -> [(String, String)] -> IO ProcessHandle) -> Expectation
replacementWorker tmp launch = do
  g <- gondolinRig tmp "gondolin-worker" codexGondolinVersion
  (_, attachment, binding) <- gondolinInvocation tmp g.territory.provider g.custody "operation-gondolin-worker-episode" "unused" Nothing
  (.disposition) <$> probeCodexGondolin g.adapter (Just attachment) `shouldReturn` ProbeReady
  let territory = bindingLeaseIdentity binding
  coordinates <- Episode.coordinates attachment
  starts <- newIORef []
  writeIORef g.wrapStart $ \original runtime -> do
    c <- Episode.coordinates runtime.attachment
    modifyIORef' starts (<> [(runtime.operationId, c.attachmentId, territory.identityLeaseId)])
    original runtime
  let endpoint = tmp </> "runtime.sock"
      ledger = tmp </> "runtime-ledger.db"
      token = "worker-token-" <> T.replicate 32 "w"
  view <- custodyView g.custody
  service <- newCodexGondolinRuntimeService endpoint ledger token g.adapter view attachment
  startCodexGondolinRuntimeService service
  let dispatchPath = tmp </> "dispatch.db"
      operationId = "operation-gondolin-worker-runtime"
      withheld = tmp </> "reply-withheld"
      environment =
        [ ("PETRUS_CODEX_GONDOLIN_ENDPOINT", endpoint)
        , ("PETRUS_CODEX_GONDOLIN_TOKEN", T.unpack token)
        , ("PETRUS_CODEX_GONDOLIN_WITHHOLD", withheld)
        ]
  dispatch <- openLocalDispatch dispatchPath "codex-worker" defaultLocalDispatchOptions
  input <- gondolinActivityInput attachment g.custody "first" "turn-gondolin-worker" Nothing
  Local.dispatch dispatch 1 (activityInvocation serviceActivity input (Just operationId) (retryPolicy 2 1))
  workers <- newIORef []
  flip finally (readIORef workers >>= mapM_ killProcess >> closeLocalDispatch dispatch >> closeCodexGondolinRuntimeService service) $ do
    first <- launch dispatchPath environment
    modifyIORef' workers (first :)
    deadline <- (+ 15) <$> getMonotonicTime
    let terminalRow =
          bracket (Sql.openDatabase ledger) Sql.closeDatabase $ \db ->
            Sql.queryRow db "SELECT terminal FROM operations WHERE operation_id=? AND phase='terminal'" [Sql.SQLText operationId]
        poll = do
          terminal <- terminalRow
          marker <- doesFileExist withheld
          exited <- getProcessExitCode first
          exited `shouldBe` Nothing
          now <- getMonotonicTime
          if (isJust terminal && marker) || now >= deadline then pure (isJust terminal && marker) else threadDelay 20000 >> poll
    poll `shouldReturn` True
    killProcess first
    threadDelay 1050000
    replacement <- launch dispatchPath environment
    modifyIORef' workers (replacement :)
    waitForResults dispatch 10 `shouldReturn` True
    collected <- collect dispatch
    collected `shouldBe` [(1, Succeeded (expectedResult operationId (lifecycleIdText (Episode.episodeId attachment)) "turn-gondolin-worker"))]
    readIORef starts `shouldReturn` [(operationId, coordinates.attachmentId, territory.identityLeaseId)]
    Episode.coordinates attachment `shouldReturn` coordinates
    bindingLeaseIdentity binding `shouldBe` territory
    g.lookupLease territory.identityOperationId `shouldReturn` Just territory
    length <$> listDirectory g.gondolinRoot `shouldReturn` 1
  settled <- Episode.settle attachment 2
  settled.settlement.verified `shouldBe` True
  let restored = tmp </> "worker-settled-workspace"
  extractWorkspaceArchive settled.archive restored
  readFile (restored </> "public-input.txt") `shouldReturn` "public-workspace-canary"
  cleanup <- bindingCleanupResult binding
  fmap (.cleanupIdentity) cleanup `shouldBe` Just territory
  g.lookupLease territory.identityOperationId `shouldReturn` Nothing
  listDirectory g.gondolinRoot `shouldReturn` []

serviceSpecs :: Spec
serviceSpecs = do
  it "test_gondolin_runtime_service_fences_frames_conflicts_restart_and_redacts" $ withTemp $ \tmp -> do
    g <- gondolinRig tmp "gondolin-service-fences" codexGondolinVersion
    (_, attachment, _) <- gondolinInvocation tmp g.territory.provider g.custody "operation-service-fences" "unused" Nothing
    view <- custodyView g.custody
    let endpoint = tmp </> "fence.sock"
        ledger = tmp </> "fence.db"
        token = T.replicate 32 "t"
        newService = newCodexGondolinRuntimeService endpoint ledger token g.adapter view attachment
        frame value = ok (jsonBytes value)
        request' tokenValue operationId input =
          Object [("version", Int 1), ("token", String tokenValue), ("operation_id", String operationId), ("input", input)]
    service <- newService
    startCodexGondolinRuntimeService service
    status <- getFileStatus endpoint
    (fileMode status `mod` 0o1000) `shouldBe` 0o600
    let identity = (deviceID status, fileID status)
    raisesWith RuntimeError "runtime-service-owned" newService
    (\s -> (deviceID s, fileID s)) <$> getFileStatus endpoint `shouldReturn` identity
    count ledger `shouldReturn` 0
    value <- gondolinActivityInput attachment g.custody "first" "turn-service-fences" Nothing
    exchange endpoint (frame (request' (T.replicate 32 "x") "unauthorized" value) <> "\n") `shouldReturn` errorReply "unauthorized"
    exchange endpoint "{\"version\":1, \"token\":\"bad\"}\n" `shouldReturn` errorReply "request-invalid"
    -- A @"\\ud800"@ escape survives @json.loads@: a token holding it fails
    -- @supplied.isascii()@ (unauthorized), and an operation id or prompt
    -- holding it makes the invocation's @len(value.encode())@ raise inside
    -- @_runtime_invocation@'s @except Exception@ (request-invalid).
    let surrogate prefix = J.fromCodePoints (prefix <> "\xd800")
        promptInput prompt = case value of
          Object members -> Object [(k, if k == "prompt" then String prompt else v) | (k, v) <- members]
          other -> other
    exchange endpoint (frame (request' (surrogate (T.unpack (T.drop 1 token))) "surrogate" value) <> "\n") `shouldReturn` errorReply "unauthorized"
    exchange endpoint (frame (request' token (surrogate "op") value) <> "\n") `shouldReturn` errorReply "request-invalid"
    exchange endpoint (frame (request' token "surrogate" (promptInput (surrogate "prompt"))) <> "\n") `shouldReturn` errorReply "request-invalid"
    exchange endpoint (B.replicate (maxRequest + 1) 120) `shouldReturn` errorReply "frame-too-large"
    writeIORef g.wrapStart $ \_ _ -> throwAgenticus RuntimeError (TE.decodeUtf8 authCanary)
    first <- exchange endpoint (frame (request' token "same" value) <> "\n")
    first `shouldBe` errorReply "runtime-failed"
    let changed = case value of
          Object members -> Object [(k, if k == "prompt" then String "changed" else v) | (k, v) <- members]
          other -> other
    exchange endpoint (frame (request' token "same" changed) <> "\n") `shouldReturn` errorReply "operation-conflict"
    closeCodexGondolinRuntimeService service

    let canonicalRequest = frame (Object [("version", Int 1), ("operation_id", String "interrupted"), ("input", value)])
    withDatabase ledger $ \db ->
      run db
        "INSERT INTO operations(operation_id,request_fingerprint,phase,episode_id,turn_id) VALUES(?,?,'executing',?,?)"
        [Sql.SQLText "interrupted", Sql.SQLText (sha256Hex canonicalRequest), Sql.SQLText (lifecycleIdText (Episode.episodeId attachment)), Sql.SQLText "turn-service-fences"]
    restarted <- newService
    startCodexGondolinRuntimeService restarted
    (exchange endpoint (frame (request' token "interrupted" value) <> "\n") `shouldReturn` errorReply "operation-indeterminate")
      `finally` closeCodexGondolinRuntimeService restarted

    entered <- newEmptyMVar
    release <- newEmptyMVar
    writeIORef g.wrapStart $ \_ _ -> do
      putMVar entered ()
      released <- timeout 10000000 (readMVar release)
      when (isNothing released) $ throwAgenticus (OtherError "AssertionError") "release"
      throwAgenticus RuntimeError "bounded failure"
    active <- newService
    startCodexGondolinRuntimeService active
    responses <- newEmptyMVar
    void (forkIO (try @SomeException (exchange endpoint (frame (request' token "active" value) <> "\n")) >>= putMVar responses))
    timeout 10000000 (takeMVar entered) `shouldReturn` Just ()
    raisesWith RuntimeError "runtime-service-quiescence-failed" (closeCodexGondolinRuntimeService active)
    doesPathExist endpoint `shouldReturn` True
    raisesWith RuntimeError "runtime-service-owned" newService
    putMVar release ()
    answered <- timeout 10000000 (takeMVar responses)
    fmap (either (const Null) id) answered `shouldBe` Just (errorReply "runtime-failed")
    closeCodexGondolinRuntimeService active
    doesPathExist endpoint `shouldReturn` False

    let foreignDirectory = tmp </> "foreign-service"
        foreignLedger = foreignDirectory </> "ledger.db"
    createDirectory foreignDirectory
    setFileMode foreignDirectory 0o700
    withDatabase foreignLedger $ \db -> do
      Sql.execute_ db "CREATE TABLE operations (operation_id TEXT PRIMARY KEY)"
      Sql.execute_ db "PRAGMA user_version=1"
    setFileMode foreignLedger 0o600
    raisesWith RuntimeError "runtime-service-storage-failed" $
      newCodexGondolinRuntimeService (foreignDirectory </> "runtime.sock") foreignLedger token g.adapter view attachment

    let escaped = tmp </> "escaped-ledger.db"
        dangling = tmp </> "dangling-service"
    createDirectory dangling
    setFileMode dangling 0o700
    createSymbolicLink escaped (dangling </> "ledger.db")
    raisesWith RuntimeError "runtime-service-storage-failed" $
      newCodexGondolinRuntimeService (dangling </> "runtime.sock") (dangling </> "ledger.db") token g.adapter view attachment
    doesPathExist escaped `shouldReturn` False

    let corrupt = tmp </> "corrupt-service"
    corruptService <- newCodexGondolinRuntimeService (corrupt </> "runtime.sock") (corrupt </> "ledger.db") token g.adapter view attachment
    closeCodexGondolinRuntimeService corruptService
    withDatabase (corrupt </> "ledger.db") $ \db -> do
      Sql.execute_ db "PRAGMA ignore_check_constraints=ON"
      run db
        "INSERT INTO operations(operation_id,request_fingerprint,phase,episode_id,turn_id) VALUES(?,?,'executing',?,?)"
        [Sql.SQLText "corrupt", Sql.SQLText (T.replicate 64 "z"), Sql.SQLText (lifecycleIdText (Episode.episodeId attachment)), Sql.SQLText "turn-service-fences"]
    raisesWith RuntimeError "runtime-service-storage-failed" $
      newCodexGondolinRuntimeService (corrupt </> "runtime.sock") (corrupt </> "ledger.db") token g.adapter view attachment
    (.settlement.verified) <$> Episode.settle attachment 2 `shouldReturn` True
    listDirectory g.gondolinRoot `shouldReturn` []

  it "test_gondolin_runtime_activity_client_renews_custody_and_rejects_malformed_terminal" $ withTemp $ \tmp -> do
    endpointRef <- newIORef (tmp </> "absent.sock")
    let token = T.replicate 32 "t"
        environment name
          | name == endpointVariable = Just . T.pack <$> readIORef endpointRef
          | name == tokenVariable = pure (Just token)
          | otherwise = pure Nothing
        client = codexGondolinActivityClientWith environment
        invocation =
          activityInvocation
            serviceActivity
            (Object [("episode_id", String "episode-client-boundary"), ("turn_id", String "turn-client-boundary")])
            (Just "operation-client-boundary")
            (retryPolicy 2 1)
    (stale, _) <- activityContext True
    protocolRaises "activity-stale" (client invocation stale)

    let delayedEndpoint = tmp </> "delayed.sock"
    delayed <- oneResponse delayedEndpoint (ok (jsonBytes (errorReply "runtime-failed")) <> "\n") 0.6
    writeIORef endpointRef delayedEndpoint
    (context, calls) <- activityContext False
    protocolRaises "runtime-failed" (client invocation context)
    delayed `shouldReturn` True
    (>= 3) <$> readIORef calls `shouldReturn` True

    let malformedEndpoint = tmp </> "malformed.sock"
    malformed <- oneResponse malformedEndpoint (ok (jsonBytes (Object [("ok", Bool True), ("result", Object [])]))  <> "\n") 0
    writeIORef endpointRef malformedEndpoint
    (fresh, _) <- activityContext False
    protocolRaises "runtime-service-failed" (client invocation fresh)
    malformed `shouldReturn` True

    let recursiveEndpoint = tmp </> "recursive.sock"
    recursive <- oneResponse recursiveEndpoint (B.replicate 1100 91 <> "0" <> B.replicate 1100 93 <> "\n") 0
    writeIORef endpointRef recursiveEndpoint
    (again, _) <- activityContext False
    protocolRaises "runtime-service-failed" (client invocation again)
    recursive `shouldReturn` True

-- ---------------------------------------------------------------------------
-- Verbatim pieces and interop

withDatabase :: FilePath -> (Sql.Database -> IO a) -> IO a
withDatabase path = bracket (Sql.openDatabase path) Sql.closeDatabase

run :: Sql.Database -> Text -> [Sql.SqlValue] -> IO ()
run = Sql.runSql

count :: FilePath -> IO Integer
count ledger = withDatabase ledger $ \db ->
  Sql.queryRow db "SELECT COUNT(*) FROM operations" [] >>= \case
    Just [Sql.SQLInteger n] -> pure (toInteger n)
    other -> fail ("count: " <> show other)

pythonOut :: Text -> [String] -> IO ByteString
pythonOut code arguments = do
  result <- runPython code arguments ""
  (result.resultExit, result.resultStderr) `shouldBe` (ExitSuccess, "")
  pure result.resultStdout

verbatimSpecs :: Spec
verbatimSpecs = describe "verbatim and interop" $ do
  it "ships the reference's exact _HELPER_SOURCE" $ do
    reference <- pythonOut "import sys\nfrom petrus.agenticus.runtime import codex\nsys.stdout.buffer.write(codex._HELPER_SOURCE.encode())" []
    shipped <- codexHelperSource
    TE.encodeUtf8 shipped `shouldBe` reference

  it "ships the reference's exact fake codex and fake Gondolin SDK" $ withTemp $ \tmp -> do
    upstream <- upstreamPetrus
    script <- (</> fixturePath "extract.py") <$> getCurrentDirectory'
    _ <- pythonOut "import runpy, sys\nsys.argv = sys.argv[1:]\nrunpy.run_path(sys.argv[0], run_name='__main__')" [script, tmp]
    forM_ ["fake_codex.py", "fake_gondolin_codex.mjs"] $ \name -> do
      regenerated <- B.readFile (tmp </> name)
      committed <- B.readFile (fixturePath name)
      (name, regenerated == committed) `shouldBe` (name, True)
    void (pure upstream)

  it "keeps the reference's exact runtime service DDL and error set" $ do
    out <- pythonOut "import json, sys\nfrom petrus.agenticus.runtime import _codex_gondolin_service as s\nsys.stdout.write(json.dumps([s._DDL, sorted(s._ERRORS), s._ACTIVITY, s._ENDPOINT_ENV, s._TOKEN_ENV, s._MAX_REQUEST, s._MAX_RESPONSE]))" []
    ok (J.parseJson J.surrogateRefusingLoads out)
      `shouldBe` Array
        [ String serviceDdl
        , Array (map String (Set.toAscList (Set.fromList terminalErrors)))
        , String serviceActivity
        , String (T.pack endpointVariable)
        , String (T.pack tokenVariable)
        , Int (toInteger maxRequest)
        , Int (toInteger maxResponse)
        ]

  it "interop: the reference validates a Haskell runtime ledger and its terminals, and the reverse" $ withTemp $ \tmp -> do
    g <- gondolinRig tmp "gondolin-ledger-interop" codexGondolinVersion
    (_, attachment, _) <- gondolinInvocation tmp g.territory.provider g.custody "operation-ledger-interop" "unused" Nothing
    view <- custodyView g.custody
    let endpoint = tmp </> "s" </> "r.sock"
        ledger = tmp </> "s" </> "ledger.db"
        token = T.replicate 32 "t"
    service <- newCodexGondolinRuntimeService endpoint ledger token g.adapter view attachment
    startCodexGondolinRuntimeService service
    value <- gondolinActivityInput attachment g.custody "first" "turn-ledger-interop" Nothing
    writeIORef g.wrapStart $ \_ _ -> throwAgenticus RuntimeError "bounded failure"
    let request' operationId = ok (jsonBytes (Object [("version", Int 1), ("token", String token), ("operation_id", String operationId), ("input", value)])) <> "\n"
    exchange endpoint (request' "interop-failed") `shouldReturn` errorReply "runtime-failed"
    closeCodexGondolinRuntimeService service
    let episode = lifecycleIdText (Episode.episodeId attachment)
        terminal = ok (jsonBytes (Object [("ok", Bool True), ("result", expectedResult "interop-success" episode "turn-ledger-interop")]))
        fingerprint = sha256Hex (ok (jsonBytes (Object [("version", Int 1), ("operation_id", String "interop-success"), ("input", value)])))
    withDatabase ledger $ \db ->
      run db "INSERT INTO operations VALUES(?,?,'terminal',?,?,?)" [Sql.SQLText "interop-success", Sql.SQLText fingerprint, Sql.SQLBlob terminal, Sql.SQLText episode, Sql.SQLText "turn-ledger-interop"]
    -- The reference opens, validates and replays this Haskell ledger.
    out <-
      pythonOut
        "import json, sqlite3, sys\n\
        \from petrus.agenticus.runtime._codex_gondolin_service import _CodexGondolinRuntimeService as S, _parse_terminal\n\
        \from petrus.agenticus.thread.identity import EpisodeId, TurnId\n\
        \db = sqlite3.connect(sys.argv[1])\n\
        \S._validate_ledger(db)\n\
        \rows = db.execute('SELECT operation_id, terminal, episode_id, turn_id FROM operations ORDER BY operation_id').fetchall()\n\
        \print(json.dumps([[o, _parse_terminal(bytes(t) + b'\\n', operation_id=o, episode_id=EpisodeId(e), turn_id=TurnId(u))] for o, t, e, u in rows]))\n"
        [ledger]
    ok (J.parseJson J.surrogateRefusingLoads out)
      `shouldBe` Array
        [ Array [String "interop-failed", errorReply "runtime-failed"]
        , Array [String "interop-success", ok (J.parseJson J.surrogateRefusingLoads terminal)]
        ]
    -- A ledger the reference wrote is admitted here.
    let pythonState = tmp </> "p"
    _ <-
      pythonOut
        "import os, sqlite3, sys\n\
        \from pathlib import Path\n\
        \from petrus.agenticus.runtime import _codex_gondolin_service as s\n\
        \state = Path(sys.argv[1]); state.mkdir(mode=0o700)\n\
        \ledger = state / 'ledger.db'\n\
        \os.close(os.open(ledger, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))\n\
        \db = sqlite3.connect(ledger)\n\
        \db.execute('PRAGMA journal_mode=WAL')\n\
        \db.execute(s._DDL)\n\
        \db.execute('PRAGMA user_version=1')\n\
        \db.execute('INSERT INTO operations VALUES(?,?,?,?,?,?)', ('python-success', sys.argv[3], 'terminal', bytes.fromhex(sys.argv[2]), sys.argv[4], 'turn-ledger-interop'))\n\
        \db.execute('INSERT INTO operations VALUES(?,?,?,NULL,?,?)', ('python-executing', sys.argv[3], 'executing', sys.argv[4], 'turn-ledger-interop'))\n\
        \db.commit()\n\
        \s._CodexGondolinRuntimeService._validate_ledger(db)\n\
        \db.close()\n"
        [pythonState, BC.unpack (hex' (ok (jsonBytes (Object [("ok", Bool True), ("result", expectedResult "python-success" episode "turn-ledger-interop")])))), T.unpack fingerprint, T.unpack episode]
    pythonService <- newCodexGondolinRuntimeService (pythonState </> "r.sock") (pythonState </> "ledger.db") token g.adapter view attachment
    closeCodexGondolinRuntimeService pythonService
    withDatabase (pythonState </> "ledger.db") $ \db ->
      Sql.queryRow db "SELECT terminal FROM operations WHERE operation_id='python-executing'" [] `shouldReturn` Just [Sql.SQLBlob (ok (jsonBytes (errorReply "operation-indeterminate")))]
    (.settlement.verified) <$> Episode.settle attachment 2 `shouldReturn` True

  it "interop: the reference's Activity client and Worker replay through the Haskell runtime service" $ withTemp $ \tmp ->
    replacementWorker tmp startPythonWorker
  where
    getCurrentDirectory' = makeAbsolute "."
    hex' = BC.pack . concatMap (\w -> let s = "0123456789abcdef" in [s !! fromIntegral (w `div` 16), s !! fromIntegral (w `mod` 16)]) . B.unpack
