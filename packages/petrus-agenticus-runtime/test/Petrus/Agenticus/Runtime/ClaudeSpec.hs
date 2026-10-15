-- | @tests/petrus/agenticus/runtime/test_claude.py@: the exact Claude A2
-- Local runtime lane, one example per reference test (parametrized cases
-- keep pytest's ids).
--
-- The reference's @Client@ / @Factory@ fakes are 'ClaudeClient' /
-- 'ClaudeClientFactory' records here; its monkeypatched
-- @importlib.metadata.version@ and @importlib.import_module@ are
-- 'ClaudeProbeHooks'; its @ToolSdk@ is a capturing 'ClaudeSdk'. The
-- reference's @_OfficialClient.disconnect@ lives in the sidecar, so its test
-- drives @claude_sidecar.py@ against the fake @claude_agent_sdk@ in
-- @test/fixtures/claude@. A last group (not in the reference) runs whole
-- turns through that sidecar.
module Petrus.Agenticus.Runtime.ClaudeSpec (spec) where

import Control.Concurrent.MVar
import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, catch, finally, throwIO, try)
import Control.Monad (forM, forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding (bindingExecution, motusBinding, openMotusBinding)
import Petrus.Agenticus.Attachment.Episode (EpisodeAttachment, episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor, DescriptorKind (..), capabilityDescriptor, descriptorIdentity)
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot, mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody
  ( AdmissionResult (..)
  , AttachmentFence (..)
  , ConnectionStatus (..)
  , ConnectionView (..)
  , LeaseMode (..)
  , ReleaseResult (..)
  , mkConnectionIdentity
  )
import Petrus.Agenticus.Connection.Materialization (CleanupEvidence (..))
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract (allToolMethods)
import Petrus.Agenticus.Hands.Gateway (GatewayCounters (..), counters)
import Petrus.Agenticus.Hands.Grants (GrantSpec (..), grantSpec, openGrant)
import Petrus.Agenticus.Hands.Workspace (defaultCommandTimeout, newMotusWorkspaceAdapter, workspaceHandsAdapter)
import Petrus.Agenticus.Program.Descriptor (ProgramOwnership (..))
import Petrus.Agenticus.Runtime.Claude
import Petrus.Agenticus.Runtime.Custody
import Petrus.Agenticus.Runtime.Installation (ProbeDisposition (..), mkInstalledComponent, mkRuntimeInstallation)
import Petrus.Agenticus.Runtime.Operation (RuntimeCleanupDisposition (..), cleanupVerified)
import Petrus.Agenticus.Runtime.PiSupport (Territory (..), newTerritory)
import Petrus.Agenticus.Runtime.Profiles (claudeA2Local)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Continuation (Continuation, ContinuationState (..), mkContinuation)
import Petrus.Agenticus.Thread.Identity (mkContinuationId, mkEpisodeId, mkThreadId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Execution (defaultSpec)
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.TestSupport.Python (pythonExecutable)
import System.Directory (createDirectory, doesFileExist, listDirectory, makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Test.Hspec

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

session', otherSession, projectKey', promptCanary, transcriptCanary :: Text
session' = "11111111-1111-4111-8111-111111111111"
otherSession = "22222222-2222-4222-8222-222222222222"
projectKey' = "-tmp-agenticus-claude-project"
promptCanary = "prompt-canary-never-render"
transcriptCanary = "transcript-canary-never-render"

authCanary :: ByteString
authCanary = "sk-ant-api03-secret-canary-never-render"

hostFencedEffect :: CapabilityDescriptor
hostFencedEffect = capabilityDescriptor (descriptorIdentity KindEffect "host.fenced" 1) ["effect.host-fenced"] []

-- | @transcript(*entries)@.
transcript :: [Json] -> ByteString
transcript entries = ok (encodeTranscript 10000 4000000 (Array entries))

decoded :: ByteString -> [Json]
decoded = ok . decodeTranscript 10000 4000000

member :: Text -> Json -> Json
member name = \case
  Object members -> fromMaybe Null (lookup name (reverse members))
  _ -> Null

-- ---------------------------------------------------------------------------
-- Continuations, turns and custody

data Continuations = Continuations {values :: IORef (Map Text ClaudeContinuationPayloadV1), failing :: Bool}

newContinuations :: Bool -> IO Continuations
newContinuations failing = (`Continuations` failing) <$> newIORef Map.empty

continuationOperations :: Continuations -> ClaudeContinuationOperations
continuationOperations c =
  ClaudeContinuationOperations
    { store = \operationId payload -> do
        when c.failing $ throwAgenticus RuntimeError "continuation canary"
        let reference = "claude-continuation-" <> operationId
        existing <- Map.lookup reference <$> readIORef c.values
        case existing of
          Just e | e /= payload -> throwAgenticus RuntimeError "conflicting Continuation"
          _ -> modifyIORef' c.values (Map.insert reference payload)
        pure reference
    , load = \reference -> Map.lookup reference <$> readIORef c.values >>= maybe (throwAgenticus KeyError reference) pure
    }

newtype Turns = Turns {values :: IORef (Map Text Text)}

turnOperations :: Turns -> ClaudeTurnOperations
turnOperations t = ClaudeTurnOperations $ \operationId text -> do
  let reference = "claude-turn-" <> operationId
  existing <- Map.lookup reference <$> readIORef t.values
  case existing of
    Just e | e /= text -> throwAgenticus RuntimeError "conflicting Turn"
    _ -> modifyIORef' t.values (Map.insert reference text)
  pure reference

data Custody = Custody
  { records :: IORef [(Text, Text)]
  , foreignFence :: Bool
  , releaseUncertain :: Bool
  , beforeAdmit :: IO ()
  }

custody :: IO Custody
custody = do
  records <- newIORef []
  pure Custody {records, foreignFence = False, releaseUncertain = False, beforeAdmit = pure ()}

view :: ConnectionView
view = ConnectionView (ok (mkConnectionIdentity "claude-connection" "claude" "safe-account" "api-key")) StatusReady 3 4 Nothing

custodyOperations :: Custody -> HostConnectionCustody
custodyOperations c =
  HostConnectionCustody
    { materialize = \connection host mode ttl operationId -> do
        unless (connection == "claude-connection" && host == "host-1" && mode == LeaseRead && ttl > 0) $
          throwAgenticus (OtherError "AssertionError") "materialize"
        record "materialize" operationId
        now <- getMonotonicTime
        pure
          HostMaterialization
            { fence = AttachmentFence "connection-attachment" "connection-lease" connection host 1 (3 + if c.foreignFence then 1 else 0) 4
            , mode
            , expiresAt = now + ttl
            , home = ProviderHome {read = pure authCanary, replace = \_ -> pure ()}
            }
    , activate = \_ _ -> throwAgenticus (OtherError "AssertionError") "activate"
    , admitResult = \fence operationId -> do
        c.beforeAdmit
        record "admit" operationId
        pure AdmissionResult {operationId, purpose = "result", attachmentId = fence.attachmentId}
    , checkpoint = \_ _ -> throwAgenticus (OtherError "AssertionError") "checkpoint"
    , release = \m operationId -> do
        record "release" operationId
        pure
          ReleaseResult
            { operationId
            , cleanup =
                CleanupEvidence
                  { attachmentId = m.fence.attachmentId
                  , removed = True
                  , alreadyAbsent = False
                  , bytesOverwritten = toInteger (B.length authCanary)
                  , physicalErasureGuaranteed = False
                  , securityViolation = c.releaseUncertain
                  }
            }
    }
  where
    record kind operationId = modifyIORef' c.records (<> [(kind, operationId)])

kinds :: Custody -> IO [Text]
kinds c = map fst <$> readIORef c.records

-- ---------------------------------------------------------------------------
-- The client fake

data ClientPlan = ClientPlan
  { session :: Text
  , planSubtype :: Text
  , planIsError :: Bool
  , planTerminalReason :: Maybe Text
  , planText :: Maybe Text
  , connectError :: Bool
  , queryError :: Bool
  , disconnectError :: Bool
  , noResult :: Bool
  , multipleResults :: Bool
  , mirrorError :: Bool
  , block :: Bool
  , releaseOnInterrupt :: Bool
  , eventSize :: Int
  , transcriptText :: Text
  , storeFailure :: Bool
  , disconnectText :: Maybe Text
  }

clientPlan :: ClientPlan
clientPlan =
  ClientPlan
    { session = session'
    , planSubtype = "success"
    , planIsError = False
    , planTerminalReason = Just "completed"
    , planText = Just "answer"
    , connectError = False
    , queryError = False
    , disconnectError = False
    , noResult = False
    , multipleResults = False
    , mirrorError = False
    , block = False
    , releaseOnInterrupt = True
    , eventSize = 64
    , transcriptText = transcriptCanary
    , storeFailure = False
    , disconnectText = Nothing
    }

data FakeClient = FakeClient
  { clientOptions :: ClaudeOptions
  , disconnected :: IORef Bool
  , interrupts :: IORef Int
  , loaded :: IORef (Maybe [Json])
  , queryStarted :: MVar ()
  }

storeKey :: Text -> Json
storeKey s = Object [("project_key", String projectKey'), ("session_id", String s)]

fakeClient :: ClaudeOptions -> ClientPlan -> IO (FakeClient, ClaudeClient)
fakeClient options plan = do
  disconnected <- newIORef False
  interrupts <- newIORef (0 :: Int)
  loaded <- newIORef Nothing
  queryStarted <- newEmptyMVar
  gate <- newEmptyMVar
  started <- newIORef False
  let store = options.sessionStore
      result =
        MessageResult
          ( ClaudeResult
              (String plan.planSubtype)
              (Bool plan.planIsError)
              (String plan.session)
              (maybe Null String plan.planTerminalReason)
              (maybe Null String plan.planText)
              plan.eventSize
          )
      messages =
        [MessageEvent plan.eventSize]
          <> [MessageMirrorError plan.eventSize | plan.mirrorError]
          <> (if plan.noResult then [] else [result] <> [result | plan.multipleResults])
      client =
        ClaudeClient
          { connect = do
              when plan.connectError $ throwAgenticus RuntimeError "connect canary"
              case lookup "resume" options.values of
                Just (String resume) -> storeLoad store (storeKey resume) >>= writeIORef loaded
                _ -> pure ()
          , query = \_ -> do
              void (tryPutMVar queryStarted ())
              when plan.queryError $ throwAgenticus RuntimeError "query canary"
              n <- maybe 0 length <$> readIORef loaded
              let body = if plan.storeFailure then T.replicate 10000 "x" else plan.transcriptText
                  entry = Object [("type", String "assistant"), ("uuid", String ("entry-" <> T.pack (show n))), ("body", String body)]
              storeAppend store (storeKey plan.session) (Array [entry]) `catch` \(_ :: AgenticusError) -> pure ()
          , receiveResponse = do
              remaining <- newIORef messages
              pure $ do
                first <- not <$> atomicModifyIORef' started (True,)
                when (first && plan.block) (readMVar gate)
                atomicModifyIORef' remaining $ \case
                  [] -> ([], Nothing)
                  m : rest -> (rest, Just m)
          , interrupt = do
              modifyIORef' interrupts (+ 1)
              when plan.releaseOnInterrupt $ void (tryPutMVar gate ())
          , disconnect = do
              forM_ plan.disconnectText $ \final ->
                storeAppend
                  store
                  (storeKey plan.session)
                  (Array [Object [("type", String "assistant"), ("uuid", String "disconnect-entry"), ("body", String final)]])
              writeIORef disconnected True
              void (tryPutMVar gate ())
              when plan.disconnectError $ throwAgenticus RuntimeError "disconnect canary"
          , release = pure True
          }
  pure (FakeClient {clientOptions = options, disconnected, interrupts, loaded, queryStarted}, client)

data Factory = Factory {plans :: IORef [ClientPlan], clients :: IORef [FakeClient]}

newFactory :: [ClientPlan] -> IO Factory
newFactory plans = Factory <$> newIORef plans <*> newIORef []

factoryRecord :: Factory -> ClaudeClientFactory
factoryRecord f = ClaudeClientFactory $ \options _gateway _invocation -> do
  plan <- atomicModifyIORef' f.plans $ \case
    [] -> ([], clientPlan)
    p : rest -> (rest, p)
  (fake, client) <- fakeClient options plan
  modifyIORef' f.clients (<> [fake])
  pure client

clientAt :: Factory -> Int -> IO FakeClient
clientAt f i = (!! i) <$> readIORef f.clients

-- ---------------------------------------------------------------------------
-- Rigs

snapshot :: CapabilityDescriptor -> ResolutionSnapshot
snapshot runtime =
  ok . mkResolutionSnapshot 1 $
    [ runtime
    , claudeConnectionCapabilities
    , claudeProgramCapabilities
    , claudeCollocatedHands
    , claudeLocalTerritory
    , claudeContinuationCapabilities
    , hostFencedEffect
    ]

data RigOptions = RigOptions
  { optPlans :: [ClientPlan]
  , optCustody :: Maybe Custody
  , optFailing :: Bool
  , optWall :: Double
  , optGrace :: Double
  , optMaxMessageBytes :: Int
  , optMaxTranscriptBytes :: Int
  , optFactory :: Maybe ClaudeClientFactory
  }

rigOptions :: RigOptions
rigOptions = RigOptions [] Nothing False 2 0.1 1000000 4000000 Nothing

data Rig = Rig
  { adapter :: ClaudeRuntimeAdapter
  , continuations :: Continuations
  , turns :: Turns
  , custodyFake :: Custody
  , factory :: Factory
  , root :: FilePath
  , runtimeRoot :: FilePath
  }

absentHooks :: ClaudeProbeHooks
absentHooks =
  ClaudeProbeHooks
    { installedSdkVersion = pure Nothing
    , importSdk = pure Nothing
    , sdk = ClaudeSdk (\_ -> throwAgenticus RuntimeError "no SDK")
    }

-- | @make_rig(tmp_path, ...)@: an adapter assigned the qualified
-- installation and @/qualified/claude@.
makeRig :: FilePath -> RigOptions -> IO Rig
makeRig root o = do
  let working = root </> "project"
      runtimeRoot = root </> "runtime"
  createDirectory working
  createDirectory runtimeRoot
  setFileMode runtimeRoot 0o700
  continuations <- newContinuations o.optFailing
  turns <- Turns <$> newIORef Map.empty
  custodyFake <- maybe custody pure o.optCustody
  factory <- newFactory o.optPlans
  let component = ok (mkInstalledComponent "claude" claudeCodeVersion "test:claude")
  adapter <-
    newClaudeRuntimeAdapter
      (claudeRuntimeConfig "claude-sonnet-4-5" working runtimeRoot)
        { hostId = "host-1"
        , credentialTtl = 2
        , wallTimeout = o.optWall
        , cancellationGrace = o.optGrace
        , disconnectTimeout = 25
        , maxMessageBytes = o.optMaxMessageBytes
        , maxTranscriptBytes = o.optMaxTranscriptBytes
        }
      (claudeContinuationCodec (continuationOperations continuations))
      (turnOperations turns)
      (custodyOperations custodyFake)
      ClaudeAdapterOptions
        { clock = getMonotonicTime
        , clientFactory = GivenFactory (fromMaybe (factoryRecord factory) o.optFactory)
        , hooks = absentHooks
        , interpreter = "/usr/bin/python3"
        , ready = ReadyWith (ok (mkRuntimeInstallation claudeA2Local.identity 1 [component] "test" "test" Set.empty), "/qualified/claude")
        }
  pure Rig {adapter, continuations, turns, custodyFake, factory, root, runtimeRoot}

data Invoked = Invoked
  { invocation :: ClaudeRuntimeInvocation
  , attachment :: EpisodeAttachment
  , territory :: Territory
  }

data InvocationOptions = InvocationOptions
  { invPrompt :: Text
  , invContinuation :: Maybe Continuation
  , invSelected :: Maybe ResolutionSnapshot
  }

invocationOptions :: InvocationOptions
invocationOptions = InvocationOptions promptCanary Nothing Nothing

-- | @rig.invocation(operation_id, ...)@.
invoke :: Rig -> Text -> InvocationOptions -> IO Invoked
invoke rig operationId o = do
  territory <- newTerritory "local-process"
  let source = rig.root </> T.unpack ("workspace-" <> operationId)
  createDirectory source
  writeFile (source </> "marker.txt") "workspace-marker"
  archive <- workspaceArchive source
  binding <- openMotusBinding territory.provider ("territory-" <> operationId) defaultSpec archive ("input-" <> operationId)
  let episode = ok (mkEpisodeId (T.replace "operation" "episode" operationId))
  now <- getMonotonicTime
  let deadline = now + 5
  attachment <-
    newEpisodeAttachment episode (fromMaybe (snapshot claudeA2Local) o.invSelected) (motusBinding binding) ("attachment-" <> operationId) deadline episodeOptions
  execution <- bindingExecution binding
  workspace <- newMotusWorkspaceAdapter territory.provider execution ["/bin/true"] defaultCommandTimeout
  gateway <- Episode.gateway attachment (workspaceHandsAdapter workspace) 256
  grant <-
    openGrant
      (Episode.grants attachment)
      (grantSpec allToolMethods deadline 16) {specWritablePaths = ["output.txt"], specAllowedArgv = [["/bin/true"]]}
  invocation <-
    newClaudeRuntimeInvocation
      ClaudeRuntimeInvocation
        { operationId
        , episodeId = episode
        , turnId = ok (mkTurnId ("turn-" <> operationId))
        , prompt = o.invPrompt
        , connection = view
        , attachment
        , gateway
        , grantEpoch = grant.grantEpoch
        , continuation = o.invContinuation
        }
  pure Invoked {invocation, attachment, territory}

continuationFor :: Text -> Continuation
continuationFor reference =
  ok
    ( mkContinuation
        (ok (mkContinuationId ("continuation-" <> reference)))
        (ok (mkThreadId "agenticus-thread"))
        claudeContinuationDescriptor
        reference
        ContinuationInUse
    )

-- | @settle_attachment(attachment)@.
settleAttachment :: EpisodeAttachment -> Expectation
settleAttachment a = do
  settled <- Episode.settle a 1
  settled.settlement.verified `shouldBe` True
  (authCanary `B.isInfixOf` settled.archive) `shouldBe` False

run :: Rig -> Text -> InvocationOptions -> IO (Invoked, ClaudeOperation, RuntimeTurnSettlement)
run rig name o = do
  invoked <- invoke rig name o
  operation <- startClaude rig.adapter invoked.invocation
  result <- waitClaudeOperation operation (Just 3)
  pure (invoked, operation, result)

protocolCode :: Text -> IO a -> Expectation
protocolCode code action =
  try action >>= \case
    Left (e :: AgenticusError) -> e.errorMessage `shouldBe` ("runtime protocol error: " <> code)
    Right _ -> expectationFailure ("expected " <> T.unpack code)

raisesWith :: ErrorClass -> Text -> IO a -> Expectation
raisesWith cls fragment action =
  try action >>= \case
    Left (e :: AgenticusError) -> do
      e.errorClass `shouldBe` cls
      (e.errorMessage, fragment `T.isInfixOf` e.errorMessage) `shouldBe` (e.errorMessage, True)
    Right _ -> expectationFailure ("expected " <> show cls)

noValues :: Rig -> Expectation
noValues rig = do
  Map.null <$> readIORef rig.turns.values `shouldReturn` True
  Map.null <$> readIORef rig.continuations.values `shouldReturn` True

emptyRuntimeRoot :: Rig -> Expectation
emptyRuntimeRoot rig = listDirectory rig.runtimeRoot `shouldReturn` []

waitFlag :: MVar () -> Double -> IO Bool
waitFlag flag seconds = isJust <$> timeout (round (seconds * 1000000)) (readMVar flag)

waitFor :: Double -> IO Bool -> IO Bool
waitFor seconds predicate = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop = do
        held <- predicate
        now <- getMonotonicTime
        if held || now >= deadline then pure held else timeout 10000 (newEmptyMVar >>= takeMVar :: IO ()) >> loop
  loop

withTemp :: (FilePath -> IO a) -> IO a
withTemp = withSystemTempDirectory "petrus-claude"

-- ---------------------------------------------------------------------------
-- Probe fakes

-- | @probe_sdk(tmp_path, protocol=...)@ as the import's surface.
probeSurface :: FilePath -> Bool -> ClaudeSdkSurface
probeSurface root protocol =
  ClaudeSdkSurface
    { file = Just (root </> "sdk" </> "__init__.py")
    , attributes = Set.fromList [a | a <- claudeRequiredAttributes, protocol || a /= "HookMatcher"]
    , parameters = Set.fromList claudeOptionFields
    }

probeHooks :: Maybe Text -> Maybe ClaudeSdkSurface -> ClaudeProbeHooks
probeHooks version surface = absentHooks {installedSdkVersion = pure version, importSdk = pure surface}

-- | @fake_cli(tmp_path, version)@.
fakeCli :: FilePath -> Text -> IO FilePath
fakeCli root version = do
  let executable = root </> "claude"
  writeFile executable ("#!/bin/sh\necho '" <> T.unpack version <> " (Claude Code)'\n")
  setFileMode executable 0o755
  pure executable

-- | @probe_rig(tmp_path)@ with the given probe environment.
probeRig :: FilePath -> ClaudeProbeHooks -> IO (Rig, ClaudeRuntimeAdapter)
probeRig root hooks = do
  rig <- makeRig root rigOptions
  let config = claudeAdapterConfig rig.adapter
  adapter <-
    newClaudeRuntimeAdapter
      config
      (claudeContinuationCodec (continuationOperations rig.continuations))
      (turnOperations rig.turns)
      (custodyOperations rig.custodyFake)
      ClaudeAdapterOptions {clock = getMonotonicTime, clientFactory = ProbedFactory, hooks, interpreter = "/usr/bin/python3", ready = Unprobed}
  pure (rig, adapter)

-- ---------------------------------------------------------------------------
-- The official sidecar

fixtureSidecar :: IO ClaudeSidecar
fixtureSidecar = do
  python <- pythonExecutable
  root <- makeAbsolute ("test" </> "fixtures" </> "claude")
  pure claudeSidecar {python, searchPath = [root], grace = 10}

-- | A bare client through the sidecar with only @cwd@ set.
sidecarClient :: FilePath -> IO ClaudeClient
sidecarClient cwd = do
  sidecar <- fixtureSidecar
  store <- newSessionStore 10 4000 Nothing Nothing
  (sidecarSdk sidecar).newClient
    ClaudeSdkRequest
      { options = ClaudeOptions {values = [("cwd", String (T.pack cwd))], sessionStore = store, stderr = DiscardProviderStderr}
      , serverName = "petrus_hands"
      , tools = []
      , preToolUse = \_ -> pure Null
      }

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "test_claude" $ do
  it "test_exact_descriptors_and_opaque_values_hide_provider_bodies" $ withTemp $ \tmp -> do
    let payload = ok (mkClaudeContinuationPayloadV1 session' (T.replicate 64 "d") projectKey' (transcript [Object [("type", String "assistant"), ("body", String transcriptCanary)]]))
        runtimeRoot = tmp </> "private"
    createDirectory runtimeRoot
    setFileMode runtimeRoot 0o700
    config <- newClaudeRuntimeConfig (claudeRuntimeConfig "claude-sonnet-4-5" tmp runtimeRoot)
    claudeProgram.acceptsFreshStart `shouldBe` True
    claudeProgram.ownership `shouldBe` ProviderOwned
    claudeProgram.producedContinuation `shouldBe` Just claudeContinuationDescriptor.identity
    claudeA2Local.identity.name `shouldBe` "claude.a2.local"
    claudeSdkVersion `shouldBe` "0.2.128"
    claudeCodeVersion `shouldBe` "2.1.220"
    claudeSdkSourceCommit `shouldBe` "ec776735b0eb8a8286827a005b35be1782e1940c"
    claudeCodeDistributionCommit `shouldBe` "7ef6eec9d9ba84ea6f233f26c45f1df5c5991843"
    let rendered = T.pack (show payload) <> T.pack (show config)
    forM_ [session', projectKey', transcriptCanary, T.pack tmp] $ \canary ->
      (canary, canary `T.isInfixOf` rendered) `shouldBe` (canary, False)

  forM_ ["AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "", "not-a-uuid"] $ \s ->
    it ("test_continuation_rejects_noncanonical_session[" <> T.unpack s <> "]") $
      raisesWith ValueError "Claude session identity" $
        throwLeft (mkClaudeContinuationPayloadV1 s (T.replicate 64 "d") projectKey' (transcript [Object [("type", String "assistant")]]))

  it "test_session_store_empty_append_and_unknown_load_are_protocol_noops" $ do
    store <- newSessionStore 3 1024 Nothing Nothing
    let key = storeKey session'
    storeAppend store key (Array [])
    storeLoad store key `shouldReturn` Nothing
    storeLoad store (storeKey otherSession) `shouldReturn` Nothing
    storeFailed store `shouldReturn` False

  it "test_session_store_deduplicates_uuid_and_rejects_conflict" $ do
    store <- newSessionStore 3 1024 Nothing Nothing
    let key = storeKey session'
        entry body = Object [("type", String "assistant"), ("uuid", String "same"), ("body", String body)]
    storeAppend store key (Array [entry "one"])
    storeAppend store key (Array [entry "one"])
    (project, body) <- storeSnapshot store session'
    project `shouldBe` projectKey'
    length (ok (decodeTranscript 3 1024 body)) `shouldBe` 1
    raisesWith RuntimeError "session-store-failed" (storeAppend store key (Array [entry "two"]))
    storeFailed store `shouldReturn` True

  it "test_official_client_requires_child_and_resume_temp_absence" $ withTemp $ \tmp -> do
    clean <- sidecarClient tmp
    (do clean.connect; clean.query "clean"; clean.disconnect) `finally` void clean.release
    uncertain <- sidecarClient tmp
    (do uncertain.connect; uncertain.query "unclean"; protocolCode "client-cleanup-uncertain" uncertain.disconnect)
      `finally` void uncertain.release

  it "test_probe_reports_absent_sdk_before_materialization" $ withTemp $ \tmp -> do
    (_, adapter) <- probeRig tmp (probeHooks Nothing Nothing)
    cli <- fakeCli tmp claudeCodeVersion
    result <- probeClaude adapter (Just cli)
    result.disposition `shouldBe` ProbeNotInstalled

  forM_ [("0.2.127", claudeCodeVersion, "0.2.127-2.1.220-incompatible"), (claudeSdkVersion, "2.1.219", "0.2.128-2.1.219-incompatible")] $
    \(sdkVersion, cliVersion, label) ->
      it ("test_probe_rejects_version_drift[" <> label <> "]") $ withTemp $ \tmp -> do
        (rig, adapter) <- probeRig tmp (probeHooks (Just sdkVersion) (Just (probeSurface tmp True)))
        cli <- fakeCli tmp cliVersion
        result <- probeClaude adapter (Just cli)
        result.disposition `shouldBe` ProbeIncompatible
        isJust result.installation `shouldBe` True
        readIORef rig.custodyFake.records `shouldReturn` []

  it "test_probe_requires_exact_public_protocol" $ withTemp $ \tmp -> do
    (_, adapter) <- probeRig tmp (probeHooks (Just claudeSdkVersion) (Just (probeSurface tmp False)))
    cli <- fakeCli tmp claudeCodeVersion
    result <- probeClaude adapter (Just cli)
    result.disposition `shouldBe` ProbeUnavailable

  it "test_probe_records_exact_ready_installation" $ withTemp $ \tmp -> do
    (_, adapter) <- probeRig tmp (probeHooks (Just claudeSdkVersion) (Just (probeSurface tmp True)))
    cli <- fakeCli tmp claudeCodeVersion
    result <- probeClaude adapter (Just cli)
    result.disposition `shouldBe` ProbeReady
    fmap (map (.version) . (.components)) result.installation `shouldBe` Just [claudeSdkVersion, claudeCodeVersion]
    fmap (.capabilities) result.installation
      `shouldBe` Just (Set.fromList ["runtime.cancel", "runtime.continue", "runtime.local", "runtime.provider-managed"])

  it "test_fresh_turn_is_one_append_with_isolated_options_and_ordered_custody" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    (invoked, operation, result) <- run rig "operation-first" invocationOptions
    (result.outcome, result.acceptedAppends) `shouldBe` (TurnCompleted, 1)
    result.outputReference `shouldBe` Just "claude-turn-operation-first"
    result.continuationReference `shouldBe` Just "claude-continuation-operation-first"
    readIORef rig.custodyFake.records
      `shouldReturn` [("materialize", "operation-first.materialize"), ("admit", "operation-first.admit"), ("release", "operation-first.release")]
    options <- (.clientOptions) <$> clientAt rig.factory 0
    let option name = fromMaybe (String "<absent>") (lookup name options.values)
        tools = Array (map String claudeTools)
    (option "tools", option "allowed_tools") `shouldBe` (tools, tools)
    (option "strict_mcp_config", option "setting_sources") `shouldBe` (Bool True, Array [])
    (option "skills", option "plugins", option "agents") `shouldBe` (Array [], Array [], Object [])
    (option "permission_mode", option "fallback_model") `shouldBe` (String "dontAsk", Null)
    (option "resume", option "session_store_flush") `shouldBe` (Null, String "eager")
    options.stderr `shouldBe` DiscardProviderStderr
    case option "cli_path" of
      String path -> takeFileName (T.unpack path) `shouldBe` "claude-launcher"
      other -> expectationFailure (show other)
    let environment = option "env"
    member "ANTHROPIC_API_KEY" environment `shouldBe` String (TE.decodeUtf8 authCanary)
    forM_ claudeAuthEnvironment $ \(name, _) -> (name, member name environment) `shouldBe` (name, String "")
    emptyRuntimeRoot rig
    payload <- (Map.! "claude-continuation-operation-first") <$> readIORef rig.continuations.values
    (payload.sessionId, payload.projectKey) `shouldBe` (session', projectKey')
    ((.disposition) <$> closeClaudeOperation operation) `shouldReturn` RuntimeCleanupClean
    settleAttachment invoked.attachment

  it "test_cli_wrapper_drops_ambient_environment_before_provider_exec" $ withTemp $ \tmp -> do
    python <- pythonExecutable
    let target = tmp </> "target"
        output = tmp </> "names.json"
        root = tmp </> "private"
    writeFile target ("#!" <> python <> " -I\nimport json, os, sys\nopen(sys.argv[1], 'w').write(json.dumps(sorted(os.environ)))\n")
    setFileMode target 0o700
    createDirectory root
    setFileMode root 0o700
    wrapper <- installCliWrapper python root target
    let environment =
          [ ("ANTHROPIC_API_KEY", "synthetic-key")
          , ("CLAUDE_CONFIG_DIR", root)
          , ("AMBIENT_AUTH_CANARY", "must-not-cross")
          , ("PYTHONPATH", tmp </> "ambient-python")
          ]
    (code, _, err) <- readCreateProcessWithExitCode (proc wrapper [output]) {env = Just environment} ""
    (code, err) `shouldBe` (ExitSuccess, "")
    names <- B.readFile output
    let found = case ok (J.parseJson J.surrogateRefusingLoads names) of
          Array values -> Set.fromList [n | String n <- values]
          _ -> Set.empty
    Set.fromList ["ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR", "HOME", "PATH", "LANG", "LC_ALL"] `Set.isSubsetOf` found `shouldBe` True
    (Set.member "AMBIENT_AUTH_CANARY" found, Set.member "PYTHONPATH" found) `shouldBe` (False, False)

  it "test_multiline_prompt_and_unicode_result_are_preserved_without_controls" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions {optPlans = [clientPlan {planText = Just "\ESC[31mOl\225 \128075\ESC[0m\NUL"}]}
    (invoked, _, result) <- run rig "operation-unicode" invocationOptions {invPrompt = "first line\n\tsecond line"}
    result.outcome `shouldBe` TurnCompleted
    Map.lookup "claude-turn-operation-unicode" <$> readIORef rig.turns.values `shouldReturn` Just "Ol\225 \128075\65533"
    settleAttachment invoked.attachment

  forM_ [("", ""), ("nul\NULprompt", "nul\\x00prompt"), (T.replicate (maxPromptBytes + 1) "x", "x*65537")] $
    \(invalid, label) ->
      it ("test_invalid_prompt_rejects_before_materialization[" <> T.unpack label <> "]") $ withTemp $ \tmp -> do
        rig <- makeRig tmp rigOptions
        invoked <- invoke rig "operation-invalid-prompt" invocationOptions
        raisesWith ValueError "Claude prompt" (newClaudeRuntimeInvocation invoked.invocation {prompt = invalid})
        readIORef rig.custodyFake.records `shouldReturn` []
        settleAttachment invoked.attachment

  it "test_native_continuation_resumes_only_accepted_transcript" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions {optPlans = [clientPlan {planText = Just "first"}, clientPlan {planText = Just "second", transcriptText = "second-entry"}]}
    (firstInvoked, _, first) <- run rig "operation-first" invocationOptions
    reference <- maybe (fail "no continuation") pure first.continuationReference
    firstPayload <- (Map.! reference) <$> readIORef rig.continuations.values
    settleAttachment firstInvoked.attachment
    (secondInvoked, _, second) <- run rig "operation-second" invocationOptions {invContinuation = Just (continuationFor reference)}
    second.outcome `shouldBe` TurnCompleted
    secondClient <- clientAt rig.factory 1
    lookup "resume" secondClient.clientOptions.values `shouldBe` Just (String session')
    readIORef secondClient.loaded `shouldReturn` Just (decoded firstPayload.transcript)
    secondReference <- maybe (fail "no continuation") pure second.continuationReference
    secondPayload <- (Map.! secondReference) <$> readIORef rig.continuations.values
    let entries = decoded secondPayload.transcript
    (length entries, member "body" (last entries)) `shouldBe` (2, String "second-entry")
    settleAttachment secondInvoked.attachment

  it "test_disconnect_final_flush_is_included_before_continuation_publication" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions {optPlans = [clientPlan {disconnectText = Just "final-flush"}]}
    (invoked, _, result) <- run rig "operation-final-flush" invocationOptions
    reference <- maybe (fail "no continuation") pure result.continuationReference
    payload <- (Map.! reference) <$> readIORef rig.continuations.values
    let entries = decoded payload.transcript
    (member "body" (last entries), length entries) `shouldBe` (String "final-flush", 2)
    client <- clientAt rig.factory 0
    readIORef client.disconnected `shouldReturn` True
    settleAttachment invoked.attachment

  forM_
    ( zip
        [0 :: Int ..]
        [ clientPlan {planIsError = True}
        , clientPlan {planSubtype = "error_max_turns", planIsError = True, planTerminalReason = Just "max_turns"}
        , clientPlan {planSubtype = "error_max_budget_usd", planIsError = True, planTerminalReason = Just "completed"}
        , clientPlan {planTerminalReason = Just "aborted_tools"}
        ]
    )
    $ \(index, plan) ->
      it ("test_provider_terminal_failures_never_append[plan" <> show index <> "]") $ withTemp $ \tmp -> do
        rig <- makeRig tmp rigOptions {optPlans = [plan]}
        (invoked, _, result) <- run rig "operation-failed" invocationOptions
        (result.outcome, result.acceptedAppends) `shouldBe` (TurnFailed, 0)
        result.terminationCode `shouldBe` "provider-failed"
        noValues rig
        kinds rig.custodyFake `shouldReturn` ["materialize", "release"]
        settleAttachment invoked.attachment

  forM_
    ( zip
        [0 :: Int ..]
        [ (clientPlan {noResult = True}, "result-cardinality")
        , (clientPlan {multipleResults = True}, "result-cardinality")
        , (clientPlan {mirrorError = True}, "session-store-failed")
        , (clientPlan {storeFailure = True}, "session-store-failed")
        , (clientPlan {eventSize = 1000}, "message-overflow")
        ]
    )
    $ \(index, (plan, code)) ->
      it ("test_malformed_or_incomplete_streams_fail_closed[plan" <> show index <> "-" <> T.unpack code <> "]") $ withTemp $ \tmp -> do
        rig <-
          makeRig
            tmp
            rigOptions { optPlans = [plan]
              , optMaxMessageBytes = if plan.eventSize > 128 then 128 else 1000000
              , optMaxTranscriptBytes = if plan.storeFailure then 512 else 4000000
              }
        (invoked, _, result) <- run rig "operation-malformed" invocationOptions
        (result.outcome, result.terminationCode) `shouldBe` (TurnFailed, code)
        noValues rig
        kinds rig.custodyFake `shouldReturn` ["materialize", "release"]
        settleAttachment invoked.attachment

  it "test_snapshot_and_grant_mismatch_reject_before_materialization" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    let foreignRuntime = capabilityDescriptor (descriptorIdentity KindRuntime "foreign" 1) [] []
    invoked <- invoke rig "operation-foreign" invocationOptions {invSelected = Just (snapshot foreignRuntime)}
    protocolCode "resolution-mismatch" (startClaude rig.adapter invoked.invocation)
    readIORef rig.custodyFake.records `shouldReturn` []
    settleAttachment invoked.attachment

  it "test_stale_local_lease_rejects_before_authority_materialization" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    invoked <- invoke rig "operation-stale-local" invocationOptions
    writeIORef invoked.territory.lookupOverride (Just (\_ -> pure Nothing))
    protocolCode "runtime-local-lease-required" (startClaude rig.adapter invoked.invocation)
    readIORef rig.custodyFake.records `shouldReturn` []
    writeIORef invoked.territory.lookupOverride Nothing
    settleAttachment invoked.attachment

  it "test_stale_continuation_project_rejects_before_materialization" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    let payload = ok (mkClaudeContinuationPayloadV1 session' (T.replicate 64 "f") projectKey' (transcript [Object [("type", String "assistant")]]))
    modifyIORef' rig.continuations.values (Map.insert "foreign-project" payload)
    invoked <- invoke rig "operation-resume" invocationOptions {invContinuation = Just (continuationFor "foreign-project")}
    protocolCode "continuation-project-mismatch" (startClaude rig.adapter invoked.invocation)
    readIORef rig.custodyFake.records `shouldReturn` []
    settleAttachment invoked.attachment

  forM_
    ( zip
        [0 :: Int ..]
        [ (clientPlan {connectError = True}, "provider-failed")
        , (clientPlan {queryError = True}, "provider-failed")
        , (clientPlan {disconnectError = True}, "cleanup-unverified")
        ]
    )
    $ \(index, (plan, expected)) ->
      it ("test_client_failures_clean_or_report_uncertainty[plan" <> show index <> "-" <> T.unpack expected <> "]") $ withTemp $ \tmp -> do
        rig <- makeRig tmp rigOptions {optPlans = [plan]}
        (invoked, operation, result) <- run rig "operation-client-failure" invocationOptions
        (result.outcome, result.terminationCode) `shouldBe` (TurnFailed, expected)
        emptyRuntimeRoot rig
        (cleanupVerified <$> closeClaudeOperation operation) `shouldReturn` (expected /= "cleanup-unverified")
        settleAttachment invoked.attachment

  it "test_stale_connection_fence_releases_without_client_start" $ withTemp $ \tmp -> do
    fake <- custody
    rig <- makeRig tmp rigOptions {optCustody = Just fake {foreignFence = True}}
    (invoked, _, result) <- run rig "operation-stale" invocationOptions
    result.terminationCode `shouldBe` "custody-state-mismatch"
    readIORef rig.factory.clients >>= (`shouldBe` 0) . length
    kinds rig.custodyFake `shouldReturn` ["materialize", "release"]
    settleAttachment invoked.attachment

  it "test_release_uncertainty_downgrades_completed_candidate" $ withTemp $ \tmp -> do
    fake <- custody
    rig <- makeRig tmp rigOptions {optCustody = Just fake {releaseUncertain = True}}
    (invoked, operation, result) <- run rig "operation-uncertain" invocationOptions
    (result.outcome, result.terminationCode, result.acceptedAppends) `shouldBe` (TurnFailed, "cleanup-unverified", 0)
    ((.disposition) <$> closeClaudeOperation operation) `shouldReturn` RuntimeCleanupUnverified
    settleAttachment invoked.attachment

  it "test_cancel_interrupts_and_drains_without_publication" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions {optPlans = [clientPlan {block = True}]}
    invoked <- invoke rig "operation-cancel" invocationOptions
    operation <- startClaude rig.adapter invoked.invocation
    waitFor 2 (not . null <$> readIORef rig.factory.clients) `shouldReturn` True
    client <- clientAt rig.factory 0
    waitFlag client.queryStarted 2 `shouldReturn` True
    cancelClaudeOperation operation "navigator-cancel" `shouldReturn` CancellationRequested
    cancelClaudeOperation operation "navigator-cancel" `shouldReturn` CancellationAlreadyRequested
    result <- waitClaudeOperation operation (Just 3)
    (result.outcome, result.acceptedAppends) `shouldBe` (TurnCancelled, 0)
    (>= 1) <$> readIORef client.interrupts `shouldReturn` True
    noValues rig
    (cleanupVerified <$> closeClaudeOperation operation) `shouldReturn` True
    settleAttachment invoked.attachment

  it "test_response_timeout_interrupts_then_fails_after_bounded_grace" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions {optPlans = [clientPlan {block = True, releaseOnInterrupt = False}], optWall = 0.1, optGrace = 0.05}
    (invoked, operation, result) <- run rig "operation-timeout" invocationOptions
    (result.outcome, result.terminationCode) `shouldBe` (TurnFailed, "deadline-exceeded")
    client <- clientAt rig.factory 0
    readIORef client.interrupts `shouldReturn` 1
    (cleanupVerified <$> closeClaudeOperation operation) `shouldReturn` True
    settleAttachment invoked.attachment

  it "test_response_completing_after_timeout_interrupt_never_publishes" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions {optPlans = [clientPlan {block = True, releaseOnInterrupt = True}], optWall = 0.1, optGrace = 0.2}
    (invoked, _, result) <- run rig "operation-late-result" invocationOptions
    (result.outcome, result.terminationCode) `shouldBe` (TurnFailed, "deadline-exceeded")
    (result.acceptedAppends, result.outputReference, result.continuationReference) `shouldBe` (0, Nothing, Nothing)
    noValues rig
    settleAttachment invoked.attachment

  it "test_candidate_store_failure_returns_no_public_references" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions {optFailing = True}
    (invoked, _, result) <- run rig "operation-store-failure" invocationOptions
    (result.outcome, result.acceptedAppends) `shouldBe` (TurnFailed, 0)
    (result.outputReference, result.continuationReference) `shouldBe` (Nothing, Nothing)
    settleAttachment invoked.attachment

  it "test_result_first_and_publication_claim_make_cancellation_too_late" $ withTemp $ \tmp -> do
    entered <- newEmptyMVar
    resume <- newEmptyMVar
    fake <- custody
    let blocking = fake {beforeAdmit = void (tryPutMVar entered ()) >> void (timeout 5000000 (readMVar resume))}
    rig <- makeRig tmp rigOptions {optCustody = Just blocking}
    invoked <- invoke rig "operation-publication" invocationOptions
    operation <- startClaude rig.adapter invoked.invocation
    waitFlag entered 2 `shouldReturn` True
    cancelClaudeOperation operation "too-late" `shouldReturn` CancellationTooLate
    putMVar resume ()
    result <- waitClaudeOperation operation (Just 3)
    result.outcome `shouldBe` TurnCompleted
    cancelClaudeOperation operation "after-result" `shouldReturn` CancellationTooLate
    settleAttachment invoked.attachment

  it "test_operation_redelivery_is_idempotent_and_conflicts_fail" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions {optPlans = [clientPlan {block = True}]}
    invoked <- invoke rig "operation-duplicate" invocationOptions
    first <- startClaude rig.adapter invoked.invocation
    again <- startClaude rig.adapter invoked.invocation
    (again == first) `shouldBe` True
    protocolCode "operation-conflict" (startClaude rig.adapter invoked.invocation {prompt = "different prompt"})
    void (cancelClaudeOperation first "finish-test")
    void (waitClaudeOperation first (Just 3))
    settleAttachment invoked.attachment

  it "test_output_and_authority_canaries_never_render_or_log" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions {optPlans = [clientPlan {planText = Just "answer", transcriptText = transcriptCanary}]}
    (invoked, operation, result) <- run rig "operation-canary" invocationOptions
    adapterText <- renderClaudeRuntimeAdapter rig.adapter
    cleanup <- closeClaudeOperation operation
    let rendered = adapterText <> renderClaudeRuntimeInvocation invoked.invocation <> renderClaudeOperation operation <> T.pack (show result) <> T.pack (show cleanup)
    forM_ [TE.decodeUtf8 authCanary, promptCanary, transcriptCanary, session'] $ \canary ->
      (canary, canary `T.isInfixOf` rendered) `shouldBe` (canary, False)
    settleAttachment invoked.attachment

  it "test_official_mcp_bridge_denies_unknown_and_uses_provider_tool_identity" $ withTemp $ \tmp -> do
    rig <- makeRig tmp rigOptions
    invoked <- invoke rig "operation-tools" invocationOptions
    captured <- newIORef Nothing
    let capturing = ClaudeSdk $ \request -> do
          writeIORef captured (Just request)
          pure (ClaudeClient (pure ()) (\_ -> pure ()) (pure (pure Nothing)) (pure ()) (pure ()) (pure True))
    store <- newSessionStore 10 4000 Nothing Nothing
    _ <- (officialFactory capturing).create (ClaudeOptions [] store DiscardProviderStderr) invoked.invocation.gateway invoked.invocation
    request <- readIORef captured >>= maybe (fail "no client") pure
    let decision value = member "permissionDecision" (member "hookSpecificOutput" value)
        input = Object [("path", String "marker.txt")]
        hookData name call extra = Object ([("tool_name", String name), ("tool_use_id", String call), ("tool_input", input)] <> extra)
    request.serverName `shouldBe` "petrus_hands"
    decision <$> request.preToolUse (hookData "Read" "foreign-call" []) `shouldReturn` String "deny"
    decision <$> request.preToolUse (hookData "mcp__petrus_hands__workspace_read" "subagent-call" [("agent_id", String "foreign-agent")])
      `shouldReturn` String "deny"
    decision <$> request.preToolUse (hookData "mcp__petrus_hands__workspace_read" "provider-tool-call" []) `shouldReturn` String "allow"
    readTool <- case [t | t <- request.tools, t.name == "workspace_read"] of
      t : _ -> pure t
      [] -> fail "no workspace_read tool"
    response <- readTool.handler input
    body <- case member "content" response of
      Array (first : _) | String text <- member "text" first -> pure (ok (J.parseJson J.surrogateRefusingLoads (TE.encodeUtf8 text)))
      other -> fail (show other)
    (member "ok" body, member "call_id" body) `shouldBe` (Bool True, String "provider-tool-call")
    ((.adapterEntries) <$> counters invoked.invocation.gateway) `shouldReturn` 1
    settleAttachment invoked.attachment

  it "test_runtime_module_import_has_no_optional_sdk_dependency" $ withTemp $ \tmp -> do
    -- No SDK is linked: the official hooks name an interpreter that does not
    -- exist, and building the adapter and descriptors never runs it.
    let absent = claudeSidecar {python = "/nonexistent/python"}
        working = tmp </> "project"
        runtimeRoot = tmp </> "runtime"
    createDirectory working
    createDirectory runtimeRoot
    setFileMode runtimeRoot 0o700
    continuations <- newContinuations False
    turns <- Turns <$> newIORef Map.empty
    fake <- custody
    options <- claudeAdapterOptions
    adapter <-
      newClaudeRuntimeAdapter
        (claudeRuntimeConfig "claude-sonnet-4-5" working runtimeRoot)
        (claudeContinuationCodec (continuationOperations continuations))
        (turnOperations turns)
        (custodyOperations fake)
        options {hooks = officialClaudeProbeHooks absent}
    renderClaudeRuntimeAdapter adapter `shouldReturn` "ClaudeRuntimeAdapter(model='claude-sonnet-4-5', ready=False)"
    claudeProgram.identity `shouldBe` claudeProgramCapabilities.identity

  describe "official sidecar (not in the reference)" $ do
    it "probes the fake SDK, its version and bundled CLI READY" $ withTemp $ \tmp -> do
      sidecar <- fixtureSidecar
      (_, adapter) <- probeRig tmp (officialClaudeProbeHooks sidecar)
      result <- probeClaude adapter Nothing
      result.disposition `shouldBe` ProbeReady
      fmap (map (.version) . (.components)) result.installation `shouldBe` Just [claudeSdkVersion, claudeCodeVersion]
      createDirectory (tmp </> "absent")
      absent <- probeRig (tmp </> "absent") (officialClaudeProbeHooks sidecar {searchPath = ["/nonexistent"]})
      (.disposition) <$> probeClaude (snd absent) Nothing `shouldReturn` ProbeNotInstalled

    it "starts a turn only once a READY probe supplies the official factory" $ withTemp $ \tmp -> do
      sidecar <- fixtureSidecar
      (rig, adapter) <- probeRig tmp (officialClaudeProbeHooks sidecar)
      invoked <- invoke rig "operation-probed" invocationOptions
      protocolCode "runtime-not-ready" (startClaude adapter invoked.invocation)
      (.disposition) <$> probeClaude adapter Nothing `shouldReturn` ProbeReady
      operation <- startClaude adapter invoked.invocation
      result <- waitClaudeOperation operation (Just 60)
      (result.outcome, result.terminationCode) `shouldBe` (TurnCompleted, "turn-completed")
      ((.disposition) <$> closeClaudeOperation operation) `shouldReturn` RuntimeCleanupClean
      emptyRuntimeRoot rig
      settleAttachment invoked.attachment

    it "runs a fresh and a resumed turn through the official client" $ withTemp $ \tmp -> do
      sidecar <- fixtureSidecar
      rig <- makeRig tmp rigOptions {optFactory = Just (officialFactory (sidecarSdk sidecar))}
      (firstInvoked, operation, first) <- run' rig "operation-first" invocationOptions
      (first.outcome, first.terminationCode) `shouldBe` (TurnCompleted, "turn-completed")
      text <- Map.lookup "claude-turn-operation-first" <$> readIORef rig.turns.values
      fmap (T.isPrefixOf "read:") text `shouldBe` Just True
      fmap (T.isInfixOf "workspace-marker") text `shouldBe` Just True
      fmap (T.isInfixOf "\"call_id\":\"toolu_read\"") text `shouldBe` Just True
      kinds rig.custodyFake `shouldReturn` ["materialize", "admit", "release"]
      emptyRuntimeRoot rig
      ((.disposition) <$> closeClaudeOperation operation) `shouldReturn` RuntimeCleanupClean
      reference <- maybe (fail "no continuation") pure first.continuationReference
      firstPayload <- (Map.! reference) <$> readIORef rig.continuations.values
      length (decoded firstPayload.transcript) `shouldBe` 2
      settleAttachment firstInvoked.attachment
      (secondInvoked, _, second) <- run' rig "operation-second" invocationOptions {invContinuation = Just (continuationFor reference)}
      second.outcome `shouldBe` TurnCompleted
      secondReference <- maybe (fail "no continuation") pure second.continuationReference
      secondPayload <- (Map.! secondReference) <$> readIORef rig.continuations.values
      map (member "uuid") (decoded secondPayload.transcript)
        `shouldBe` map String ["user-0", "assistant-0", "user-2", "assistant-2"]
      settleAttachment secondInvoked.attachment

    it "interrupts a blocked official response on cancel" $ withTemp $ \tmp -> do
      sidecar <- fixtureSidecar
      rig <- makeRig tmp rigOptions {optFactory = Just (officialFactory (sidecarSdk sidecar)), optWall = 30, optGrace = 5}
      invoked <- invoke rig "operation-block" invocationOptions {invPrompt = "block"}
      operation <- startClaude rig.adapter invoked.invocation
      -- Let the sidecar start the client and deliver system/init.
      void (timeout 1000000 (newEmptyMVar >>= takeMVar :: IO ()))
      cancelClaudeOperation operation "stop" `shouldReturn` CancellationRequested
      result <- waitClaudeOperation operation (Just 30)
      (result.outcome, result.acceptedAppends) `shouldBe` (TurnCancelled, 0)
      (cleanupVerified <$> closeClaudeOperation operation) `shouldReturn` True
      emptyRuntimeRoot rig
      settleAttachment invoked.attachment

    it "reports an official client whose child survives disconnect as unverified" $ withTemp $ \tmp -> do
      sidecar <- fixtureSidecar
      rig <- makeRig tmp rigOptions {optFactory = Just (officialFactory (sidecarSdk sidecar))}
      (invoked, operation, result) <- run' rig "operation-unclean" invocationOptions {invPrompt = "unclean"}
      (result.outcome, result.terminationCode) `shouldBe` (TurnFailed, "cleanup-unverified")
      ((.disposition) <$> closeClaudeOperation operation) `shouldReturn` RuntimeCleanupUnverified
      noValues rig
      settleAttachment invoked.attachment

  -- divergences/claude-a2.md item 1: every client of a pool shares one
  -- sidecar process, which upstream (one interpreter, no sidecar) has no
  -- counterpart of. Each test runs its own pool.
  describe "shared sidecar: many clients on one process (not in the reference)" $ do
    let pooled pool = (\s -> s {pool}) <$> fixtureSidecar
        officialRig tmp sidecar wall grace =
          makeRig tmp rigOptions {optFactory = Just (officialFactory (sidecarSdk sidecar)), optWall = wall, optGrace = grace}

    it "runs concurrent turns on one sidecar, each settling on its own" $ withTemp $ \tmp ->
      withSidecarPool 5 $ \pool -> do
        sidecar <- pooled pool
        rig <- officialRig tmp sidecar 30 5
        blocked <- invoke rig "operation-blocked" invocationOptions {invPrompt = "block"}
        blockedOperation <- startClaude rig.adapter blocked.invocation
        -- Three turns run to completion while a fourth blocks mid-turn.
        finished <-
          concurrentlyAll
            [ run' rig ("operation-" <> name) invocationOptions {invPrompt = "prompt-" <> name}
            | name <- ["a", "b", "c"]
            ]
        forM_ finished $ \(invoked, operation, result) -> do
          (result.outcome, result.terminationCode) `shouldBe` (TurnCompleted, "turn-completed")
          ((.disposition) <$> closeClaudeOperation operation) `shouldReturn` RuntimeCleanupClean
          settleAttachment invoked.attachment
        stored <- readIORef rig.turns.values
        Map.keys stored `shouldMatchList` ["claude-turn-operation-" <> name | name <- ["a", "b", "c"]]
        forM_ (Map.elems stored) (`shouldSatisfy` T.isPrefixOf "read:")
        -- Each client saw its own prompt in its own session-store mirror.
        continuations <- readIORef rig.continuations.values
        forM_ ["a", "b", "c"] $ \name -> do
          let payload = continuations Map.! ("claude-continuation-operation-" <> name)
          map (member "message") (take 1 (decoded payload.transcript)) `shouldBe` [String ("prompt-" <> name)]
        cancelClaudeOperation blockedOperation "stop" `shouldReturn` CancellationRequested
        result <- waitClaudeOperation blockedOperation (Just 30)
        (result.outcome, result.acceptedAppends) `shouldBe` (TurnCancelled, 0)
        (cleanupVerified <$> closeClaudeOperation blockedOperation) `shouldReturn` True
        settleAttachment blocked.attachment
        emptyRuntimeRoot rig
        length <$> sidecarPoolPids pool `shouldReturn` 1

    it "settles every turn of a sidecar that dies mid-turn, and the next turn respawns it" $ withTemp $ \tmp ->
      withSidecarPool 5 $ \pool -> do
        sidecar <- pooled pool
        rig <- officialRig tmp sidecar 30 5
        -- A client waiting mid-response, past every cancellation.
        let marker = tmp </> "waiting"
        blocked <- invoke rig "operation-blocked" invocationOptions {invPrompt = T.pack ("stuck:" <> marker)}
        blockedOperation <- startClaude rig.adapter blocked.invocation
        awaitFile marker
        original <- sidecarPoolPids pool
        length original `shouldBe` 1
        -- The SDK crashes the sidecar process under one client: both that
        -- turn and the other client's settle as upstream settles a client
        -- that failed and whose disconnect cannot be confirmed.
        -- Both settle at once: a call on a channel whose sidecar is gone
        -- fails immediately rather than waiting out the disconnect timeout
        -- (25 s here).
        died <- invoke rig "operation-die" invocationOptions {invPrompt = "die"}
        diedResult <- startClaude rig.adapter died.invocation >>= (`waitClaudeOperation` Just 10)
        (diedResult.outcome, diedResult.terminationCode) `shouldBe` (TurnFailed, "cleanup-unverified")
        blockedResult <- waitClaudeOperation blockedOperation (Just 10)
        (blockedResult.outcome, blockedResult.terminationCode) `shouldBe` (TurnFailed, "cleanup-unverified")
        ((.disposition) <$> closeClaudeOperation blockedOperation) `shouldReturn` RuntimeCleanupUnverified
        noValues rig
        mapM_ (settleAttachment . (.attachment)) [died, blocked]
        -- The next client starts a new sidecar.
        (next, _, nextResult) <- run' rig "operation-next" invocationOptions
        (nextResult.outcome, nextResult.terminationCode) `shouldBe` (TurnCompleted, "turn-completed")
        settleAttachment next.attachment
        respawned <- sidecarPoolPids pool
        (length respawned, any (`elem` original) respawned) `shouldBe` (1, False)

    it "reports a client stuck past the release grace as unverified while the others proceed" $ withTemp $ \tmp ->
      withSidecarPool 2 $ \pool -> do
        sidecar <- (\s -> s {grace = 2}) <$> pooled pool
        rig <- officialRig tmp sidecar 30 0.5
        let marker = tmp </> "stuck"
        stuck <- invoke rig "operation-stuck" invocationOptions {invPrompt = T.pack ("stuck:" <> marker)}
        stuckOperation <- startClaude rig.adapter stuck.invocation
        awaitFile marker
        cancelClaudeOperation stuckOperation "stop" `shouldReturn` CancellationRequested
        -- While the stuck client's teardown hangs in the sidecar, another
        -- client on the same sidecar runs a whole turn.
        (other, _, otherResult) <- run' rig "operation-other" invocationOptions
        (otherResult.outcome, otherResult.terminationCode) `shouldBe` (TurnCompleted, "turn-completed")
        settleAttachment other.attachment
        stuckResult <- waitClaudeOperation stuckOperation (Just 30)
        -- A cancelled operation settles cancelled whatever its cleanup
        -- (upstream's @_Operation._run@); the cleanup is what records that
        -- the client's release could not be verified.
        (stuckResult.outcome, stuckResult.terminationCode) `shouldBe` (TurnCancelled, "cancelled")
        ((.disposition) <$> closeClaudeOperation stuckOperation) `shouldReturn` RuntimeCleanupUnverified
        settleAttachment stuck.attachment
        -- Closing the pool ends the sidecar although a teardown is stuck in
        -- it: past the pool's grace, it is killed.
        timeout 10000000 (closeSidecarPool pool 2) `shouldReturn` Just ()
        sidecarPoolPids pool `shouldReturn` []
  where
    run' rig name o = do
      invoked <- invoke rig name o
      operation <- startClaude rig.adapter invoked.invocation
      result <- waitClaudeOperation operation (Just 60)
      pure (invoked, operation, result)

-- | Run the actions on their own threads and collect their results in
-- order, rethrowing the first failure.
concurrentlyAll :: [IO a] -> IO [a]
concurrentlyAll actions = do
  boxes <- forM actions $ \action -> do
    box <- newEmptyMVar
    _ <- forkIO (try action >>= putMVar box)
    pure box
  forM boxes $ \box -> takeMVar box >>= either (\(e :: SomeException) -> throwIO e) pure

-- | Wait (up to ten seconds) until a fake SDK has touched @path@.
awaitFile :: FilePath -> IO ()
awaitFile path = go (200 :: Int)
  where
    go 0 = expectationFailure ("never touched: " <> path)
    go n = doesFileExist path >>= \found -> unless found (threadDelay 50000 >> go (n - 1))
