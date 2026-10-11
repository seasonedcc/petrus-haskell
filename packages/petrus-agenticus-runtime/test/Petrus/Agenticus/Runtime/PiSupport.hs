-- | Fixtures shared by the Pi specs: the reference's @Continuations@,
-- @Turns@, @Home@, @Custody@, @Keys@, @Plan@, @Client@, @Factory@,
-- @snapshot@ and @Rig@ from @tests/petrus/agenticus/runtime/test_pi.py@.
--
-- The reference renames a @LocalProcessEnvironment@ to @gondolin@ or @e2b@
-- by assigning attributes on the provider and on its live leases. Here
-- 'Territory' wraps the local provider and renames every lease, execution
-- attachment, provenance and cleanup it returns. Its 'drift' and
-- 'lookupOverride' cells stand in for the reference's
-- @object.__setattr__(lease, "provider", ...)@ and its
-- @monkeypatch.setattr(provider, "lookup", ...)@.
module Petrus.Agenticus.Runtime.PiSupport
  ( -- * Constants
    sessionId
  , otherSession
  , key
  , auth
  , refreshedAuth
  , openaiAuth
  , refreshedOpenaiAuth
  , prompt
  , sessionCanary
  , effect
  , session
  , ok
    -- * Fakes
  , Continuations (..)
  , newContinuations
  , continuationOperations
  , Turns (..)
  , newTurns
  , turnOperations
  , FakeCustody (..)
  , newFakeCustody
  , custodyView
  , custodyOperations
  , recordedKinds
  , Plan (..)
  , plan
  , Client (..)
  , Factory (..)
  , newFactory
  , factoryRecord
  , aesKeys
    -- * Territories
  , Territory (..)
  , newTerritory
    -- * Rigs
  , snapshotFor
  , RigOptions (..)
  , rigOptions
  , Rig (..)
  , newRig
  , InvocationOptions (..)
  , invocationOptions
  , Invoked (..)
  , invoke
  , invocation
  , claimed
  , rebuild
  , rigConfig
  , runtimeRootEntries
    -- * Assertions
  , raises
  , raisesValueLike
  , waitUntil
  , fixture
  , withTemp
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Exception (throwIO, try)
import Control.Monad (unless, when)
import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (AEADMode (..), AuthTag (..), aeadInit, aeadSimpleDecrypt, aeadSimpleEncrypt, cipherInit)
import Crypto.Error (throwCryptoErrorIO)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding (MotusAttachmentBinding, bindingExecution, motusBinding, openMotusBinding)
import Petrus.Agenticus.Attachment.Episode (EpisodeAttachment, episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor (..), DescriptorKind (..), capabilityDescriptor, descriptorIdentity)
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot, mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody
  ( AdmissionResult (..)
  , AttachmentFence (..)
  , ConnectionStatus (..)
  , ConnectionView (..)
  , LeaseMode (..)
  , PublicationResult (..)
  , ReleaseResult (..)
  , mkConnectionIdentity
  )
import Petrus.Agenticus.Connection.Key (KeyErasureEvidence, KeyOperations (..), authenticatedData, mkKeyErasureEvidence)
import Petrus.Agenticus.Connection.Materialization (CleanupEvidence (..))
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract (ToolMethod (..), allToolMethods)
import Petrus.Agenticus.Hands.Grants (CapabilityGrant (..), GrantSpec (..), grantSpec, openGrant)
import Petrus.Agenticus.Hands.Workspace (defaultCommandTimeout, newMotusWorkspaceAdapter, workspaceHandsAdapter)
import Petrus.Agenticus.Runtime.Custody
import Petrus.Agenticus.Runtime.Installation (mkInstalledComponent, mkRuntimeInstallation)
import Petrus.Agenticus.Runtime.Operation (runtimeProtocolError)
import Petrus.Agenticus.Runtime.Pi
import Petrus.Agenticus.Runtime.Profiles (piNativeA2Local, piNativeA4E2b, piNativeA4Gondolin)
import Petrus.Agenticus.Thread.Continuation (Continuation, ContinuationState (..), mkContinuation)
import Petrus.Agenticus.Thread.Identity (mkContinuationId, mkEpisodeId, mkThreadId, mkTurnId)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Execution hiding (ErrorKind (..))
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import System.Directory (createDirectory, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)
import Test.Hspec

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

-- ---------------------------------------------------------------------------
-- Constants

sessionId, otherSession, prompt, sessionCanary :: Text
sessionId = "11111111-1111-4111-8111-111111111111"
otherSession = "22222222-2222-4222-8222-222222222222"
prompt = "pi-prompt-canary-never-render"
sessionCanary = "pi-session-canary-never-render"

key, auth, refreshedAuth, openaiAuth, refreshedOpenaiAuth :: ByteString
key = "pi-key-canary-never-render"
auth = "{\"anthropic\":{\"type\":\"oauth\",\"access\":\"pi-access-canary\",\"refresh\":\"pi-refresh-canary\",\"expires\":1}}"
refreshedAuth = "{\"anthropic\":{\"type\":\"oauth\",\"access\":\"pi-access-next\",\"refresh\":\"pi-refresh-next\",\"expires\":2}}"
openaiAuth =
  "{\"openai-codex\":{\"type\":\"oauth\",\"access\":\"pi-openai-access-canary\",\"refresh\":\"pi-openai-refresh-canary\",\"expires\":1,\"accountId\":\"pi-openai-account-canary\"}}"
refreshedOpenaiAuth =
  "{\"openai-codex\":{\"type\":\"oauth\",\"access\":\"pi-openai-access-next\",\"refresh\":\"pi-openai-refresh-next\",\"expires\":2,\"accountId\":\"pi-openai-account-next\"}}"

effect :: CapabilityDescriptor
effect = capabilityDescriptor (descriptorIdentity KindEffect "host.fenced" 1) ["effect.host-fenced"] []

-- | @session(identity, *entries)@: compact JSONL with a version-3 header.
session :: Text -> [Json] -> ByteString
session identity entries =
  B.concat
    [ ok (J.dumps options value) <> "\n"
    | value <- Object [("type", String "session"), ("version", Int 3), ("id", String identity)] : entries
    ]
  where
    options = J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":", J.allowNan = False}

-- ---------------------------------------------------------------------------
-- Continuations and turns

data Continuations = Continuations
  { values :: IORef (Map Text PiContinuationPayloadV1)
  , failing :: IORef Bool
  }

newContinuations :: IO Continuations
newContinuations = Continuations <$> newIORef Map.empty <*> newIORef False

continuationOperations :: Continuations -> PiContinuationOperations
continuationOperations c =
  PiContinuationOperations
    { store = \operationId payload -> do
        broken <- readIORef c.failing
        when broken $ throwAgenticus RuntimeError "store failed"
        let reference = "pi-continuation-" <> operationId
        known <- readIORef c.values
        case Map.lookup reference known of
          Just existing | existing /= payload -> throwAgenticus RuntimeError "conflict"
          _ -> modifyIORef' c.values (Map.insert reference payload)
        pure reference
    , load = \reference ->
        Map.lookup reference <$> readIORef c.values
          >>= maybe (throwAgenticus KeyError (T.pack (show reference))) pure
    }

data Turns = Turns
  { values :: IORef (Map Text Text)
  , failing :: IORef Bool
  }

newTurns :: IO Turns
newTurns = Turns <$> newIORef Map.empty <*> newIORef False

turnOperations :: Turns -> PiTurnOperations
turnOperations t =
  PiTurnOperations
    { storeTurn = \operationId text -> do
        broken <- readIORef t.failing
        when broken $ throwAgenticus RuntimeError "store failed"
        let reference = "pi-turn-" <> operationId
        modifyIORef' t.values (Map.insert reference text)
        pure reference
    }

-- ---------------------------------------------------------------------------
-- Custody

data FakeCustody = FakeCustody
  { records :: IORef [(Text, Text)]
  , uncertain :: IORef Bool
  , checkpointFail :: IORef Bool
  , profile :: Text
  , provider :: Text
  , home :: IORef ByteString
  , stateVersion :: IORef Integer
  , beforeAdmit :: IORef (IO ())
  -- ^ The reference's stalled @admit_result@ monkeypatch.
  , checkpointOverride :: IORef (Maybe (HostMaterialization -> Text -> IO PublicationResult))
  -- ^ The reference's replaced @checkpoint@.
  }

newFakeCustody :: Text -> Text -> IO FakeCustody
newFakeCustody profile provider = do
  records <- newIORef []
  uncertain <- newIORef False
  checkpointFail <- newIORef False
  home <- newIORef (if profile == "api-key" then key else if provider == "openai-codex" then openaiAuth else auth)
  stateVersion <- newIORef 4
  beforeAdmit <- newIORef (pure ())
  checkpointOverride <- newIORef Nothing
  pure FakeCustody {records, uncertain, checkpointFail, profile, provider, home, stateVersion, beforeAdmit, checkpointOverride}

custodyView :: FakeCustody -> IO ConnectionView
custodyView c = do
  version <- readIORef c.stateVersion
  pure
    ConnectionView
      { identity = ok (mkConnectionIdentity "connection" c.provider "account" c.profile)
      , status = StatusReady
      , authorityEpoch = 3
      , stateVersion = version
      , stateDigest = Nothing
      }

record :: FakeCustody -> Text -> Text -> IO ()
record c kind operationId = modifyIORef' c.records (<> [(kind, operationId)])

recordedKinds :: FakeCustody -> IO [Text]
recordedKinds c = map fst <$> readIORef c.records

assertTrue :: Bool -> IO ()
assertTrue condition = unless condition (throwAgenticus (OtherError "AssertionError") "")

custodyOperations :: FakeCustody -> HostConnectionCustody
custodyOperations c =
  HostConnectionCustody
    { materialize = \connection host mode ttl operationId -> do
        let expected = if c.profile == "api-key" then LeaseRead else LeaseRefresh
        assertTrue ((connection, host, mode) == ("connection", "host", expected))
        record c "materialize" operationId
        version <- readIORef c.stateVersion
        now <- getMonotonicTime
        pure
          HostMaterialization
            { fence = AttachmentFence "credential" "lease" connection host 1 3 version
            , mode
            , expiresAt = now + ttl
            , home = ProviderHome {read = readIORef c.home, replace = writeIORef c.home}
            }
    , activate = \m operationId -> do
        assertTrue (m.mode == LeaseRefresh)
        record c "activate" operationId
    , admitResult = \fence operationId -> do
        join' (readIORef c.beforeAdmit)
        record c "admit" operationId
        pure AdmissionResult {operationId, purpose = "result", attachmentId = fence.attachmentId}
    , checkpoint = \m operationId ->
        readIORef c.checkpointOverride >>= \case
          Just replaced -> replaced m operationId
          Nothing -> do
            assertTrue (m.mode == LeaseRefresh)
            record c "checkpoint" operationId
            broken <- readIORef c.checkpointFail
            when broken $ throwAgenticus RuntimeError "checkpoint failed"
            modifyIORef' c.stateVersion (+ 1)
            view <- custodyView c
            size <- B.length <$> readIORef c.home
            pure PublicationResult {operationId, connection = view, cleanup = evidence m.fence.attachmentId size False}
    , release = \m operationId -> do
        record c "release" operationId
        size <- B.length <$> readIORef c.home
        violation <- readIORef c.uncertain
        pure ReleaseResult {operationId, cleanup = evidence m.fence.attachmentId size violation}
    }
  where
    join' action = action >>= id
    evidence attachmentId size violation =
      CleanupEvidence
        { attachmentId
        , removed = True
        , alreadyAbsent = False
        , bytesOverwritten = toInteger size
        , physicalErasureGuaranteed = False
        , securityViolation = violation
        }

-- | The reference's AES-GCM @Keys@ with a counter nonce.
aesKeys :: IO KeyOperations
aesKeys = do
  nonce <- newIORef (0 :: Integer)
  cipher :: AES256 <- throwCryptoErrorIO (cipherInit (B.replicate 32 107))
  let encodeNonce n = B.pack [fromIntegral (n `div` (256 ^ i) `mod` 256) | i <- [11, 10 .. 0 :: Int]]
  pure
    KeyOperations
      { seal = \ctx plaintext -> do
          n <- atomicModifyIORef' nonce (\x -> (x + 1, x + 1))
          let iv = encodeNonce n
          aead <- throwCryptoErrorIO (aeadInit AEAD_GCM cipher iv)
          let (AuthTag tag, ciphertext) = aeadSimpleEncrypt aead (authenticatedData ctx) (BA.convert plaintext :: ByteString) 16
          pure (iv <> ciphertext <> BA.convert tag)
      , open = \ctx sealed -> do
          let (iv, rest) = B.splitAt 12 sealed
              (ciphertext, tag) = B.splitAt (B.length rest - 16) rest
          aead <- throwCryptoErrorIO (aeadInit AEAD_GCM cipher iv)
          case aeadSimpleDecrypt aead (authenticatedData ctx) ciphertext (AuthTag (BA.convert tag)) of
            Just plaintext -> pure (BA.convert plaintext)
            Nothing -> throwAgenticus (OtherError "InvalidTag") ""
      , erase = \connectionId -> either throwIO pure (mkKeyErasureEvidence connectionId True) :: IO KeyErasureEvidence
      }

-- ---------------------------------------------------------------------------
-- Scripted helper clients

data Plan = Plan
  { planError :: Maybe Text
  , planProviderFailed :: Bool
  , planBlock :: Bool
  , planClean :: Bool
  , planIdentity :: Text
  , planText :: Text
  , planRefreshed :: Maybe ByteString
  , planOmitAuth :: Bool
  }

plan :: Plan
plan = Plan Nothing False False True sessionId "answer" Nothing False

data Client = Client
  { plan :: Plan
  , entered :: MVar ()
  , prior :: Maybe PiContinuationPayloadV1
  , nativeAuth :: Maybe ByteString
  }

runClient :: Client -> IO () -> PiHelperClient
runClient c afterRun =
  PiHelperClient
    { run = \_ _ current deadline -> do
        _ <- tryPutMVar c.entered ()
        let spin = do
              live <- current
              now <- getMonotonicTime
              when (c.plan.planBlock && live && now < deadline) (threadDelay 5000 >> spin)
        spin
        mapM_ (throwIO . runtimeProtocolError) c.plan.planError
        live <- current
        unless live $ throwIO (runtimeProtocolError "cancelled")
        now <- getMonotonicTime
        when (now >= deadline) $ throwIO (runtimeProtocolError "deadline-exceeded")
        let rotated = fromMaybe (if c.nativeAuth == Just openaiAuth then refreshedOpenaiAuth else refreshedAuth) c.plan.planRefreshed
        result <-
          if c.plan.planProviderFailed
            then pure (PiHelperResult Nothing (Just rotated) "provider-failed")
            else do
              let message = ok (J.dumps J.defaultDumps (Object [("type", String "message"), ("body", String sessionCanary)]))
                  body = maybe (session c.plan.planIdentity []) (.sessionJsonl) c.prior <> message <> "\n"
                  candidate = PiCandidate c.plan.planIdentity c.plan.planText body
                  returned = if c.nativeAuth /= Nothing && not c.plan.planOmitAuth then Just rotated else Nothing
              pure (PiHelperResult (Just candidate) returned "turn-completed")
        afterRun
        pure result
    , close = pure c.plan.planClean
    }

data Factory = Factory
  { plans :: IORef [Plan]
  , calls :: IORef [PiHelperArgs]
  , clients :: IORef [Client]
  , failCreate :: IORef Bool
  , afterRun :: IORef (IO ())
  -- ^ The reference's wrapped @Client.run@.
  }

newFactory :: [Plan] -> IO Factory
newFactory plans' =
  Factory
    <$> newIORef (if null plans' then [plan] else plans')
    <*> newIORef []
    <*> newIORef []
    <*> newIORef False
    <*> newIORef (pure ())

factoryRecord :: Factory -> PiHelperFactory
factoryRecord f = PiHelperFactory $ \args -> do
  broken <- readIORef f.failCreate
  when broken $ throwAgenticus RuntimeError "spawn failed"
  modifyIORef' f.calls (<> [args])
  next <- atomicModifyIORef' f.plans $ \case
    p : rest -> (rest, p)
    [] -> ([], error "IndexError: pop from empty list")
  entered <- newEmptyMVar
  let client = Client {plan = next, entered, prior = args.prior, nativeAuth = args.nativeAuth}
  modifyIORef' f.clients (<> [client])
  hook <- readIORef f.afterRun
  pure (runClient client hook)

-- ---------------------------------------------------------------------------
-- Territories

data Territory = Territory
  { provider :: EnvironmentProvider
  , drift :: IORef (Maybe Text)
  -- ^ A provider name the looked-up lease reports instead of the territory.
  , lookupOverride :: IORef (Maybe (Text -> IO (Maybe EnvironmentLease)))
  }

-- | A local process provider whose every lease reports @name@.
newTerritory :: Text -> IO Territory
newTerritory name = do
  inner <- localProvider <$> newLocalProcessEnvironment
  drift <- newIORef Nothing
  lookupOverride <- newIORef Nothing
  let original = providerName inner
      relabel label lease =
        ok (mkEnvironmentLease (leaseOperationId lease) label (leaseId lease) (leaseCapabilities lease) (leaseState lease))
      rename = relabel name
      restore = relabel original
      renameAttachment a = ok (mkExecutionAttachment (attachmentId a) (rename (attachmentLease a)) (attachmentInputDigest a) (attachmentWorkspace a))
      restoreAttachment a = ok (mkExecutionAttachment (attachmentId a) (restore (attachmentLease a)) (attachmentInputDigest a) (attachmentWorkspace a))
      renameIdentity identity = ok (mkLeaseIdentity (identityOperationId identity) name (identityLeaseId identity))
      renameResult r =
        let p = resultProvenance r
         in ok
              ( mkCommandResult
                  (resultReturncode r)
                  (resultStdout r)
                  (resultStderr r)
                  (resultTimedOut r)
                  (resultSuperseded r)
                  (resultOutputTruncated r)
                  (ok (mkExecutionProvenance (provenanceOperationId p) name (provenanceLeaseId p)))
              )
      renameReconcile r = case reconcileClassification r of
        ReconcileTerminal -> terminalResult (maybe (error "terminal without lease") rename (reconcileLease r)) (reconcileDetail r)
        ReconcileRetryable -> retryableResult (reconcileDetail r)
        ReconcileUncertain -> uncertainResult (rename <$> reconcileLease r) (reconcileDetail r)
      provider =
        inner
          { providerName = name
          , providerCreate = \operation spec -> rename <$> providerCreate inner operation spec
          , providerLookup = \operation ->
              readIORef lookupOverride >>= \case
                Just replaced -> replaced operation
                Nothing -> do
                  label <- fromMaybe name <$> readIORef drift
                  fmap (relabel label) <$> providerLookup inner operation
          , providerAttach = \lease archive digest -> renameAttachment <$> providerAttach inner (restore lease) archive digest
          , providerExecute = \a command -> renameResult <$> providerExecute inner (restoreAttachment a) command
          , providerExport = providerExport inner . restoreAttachment
          , providerCancel = providerCancel inner . restore
          , providerReconcile = fmap renameReconcile . providerReconcile inner
          , providerDestroy = \lease -> do
              cleanup <- providerDestroy inner (restore lease)
              pure cleanup {cleanupIdentity = renameIdentity (cleanupIdentity cleanup)}
          , providerPrivateFiles = Nothing
          }
  pure Territory {provider, drift, lookupOverride}

-- ---------------------------------------------------------------------------
-- Rigs

-- | @snapshot(runtime=None, connection=..., territory_profile=...)@.
snapshotFor :: Maybe CapabilityDescriptor -> CapabilityDescriptor -> Text -> ResolutionSnapshot
snapshotFor runtime connection territoryProfile =
  ok . mkResolutionSnapshot 1 $
    [ fromMaybe profileRuntime runtime
    , connection
    , piProgramCapabilities
    , if territoryProfile == "local" then piCollocatedHands else piCapabilityScopedHands
    , territory
    , piContinuationCapabilities
    , effect
    ]
  where
    (profileRuntime, territory) = case territoryProfile of
      "gondolin" -> (piNativeA4Gondolin, piGondolinTerritory)
      "e2b" -> (piNativeA4E2b, piE2bTerritory)
      _ -> (piNativeA2Local, piLocalTerritory)

data RigOptions = RigOptions
  { optPlans :: [Plan]
  , optWallTimeout :: Double
  , optProfile :: Text
  , optProvider :: Maybe Text
  , optTerritory :: Text
  , optPredecessor :: Maybe Rig
  }

rigOptions :: RigOptions
rigOptions = RigOptions [] 2 "api-key" Nothing "local" Nothing

data Rig = Rig
  { root :: FilePath
  , profile :: Text
  , territoryProfile :: Text
  , connection :: CapabilityDescriptor
  , continuations :: Continuations
  , turns :: Turns
  , custody :: FakeCustody
  , factory :: Factory
  , adapter :: PiRuntimeAdapter
  , working :: FilePath
  }

newRig :: FilePath -> RigOptions -> IO Rig
newRig root o = do
  createDirectoryIfMissing' root
  let private = root </> "private"
  working <- case o.optPredecessor of
    Nothing -> let w = root </> "working" in createDirectory w >> pure w
    Just previous -> pure previous.working
  createDirectory private
  setFileMode private 0o700
  let selectedProvider = fromMaybe (if o.optProfile == "api-key" then "provider" else "anthropic") o.optProvider
      catalog = if o.optProfile == "cc-patch-subscription" then piCcPatchSubscriptionCatalog else piSubscriptionCatalog
      selectedModel = if o.optProfile == "api-key" then "model" else fromMaybe "" (lookup selectedProvider catalog)
      connection = case o.optProfile of
        "subscription" -> piSubscriptionConnectionCapabilities
        "cc-patch-subscription" -> piCcPatchConnectionCapabilities
        _ -> piConnectionCapabilities
  continuations <- maybe newContinuations (pure . (.continuations)) o.optPredecessor
  turns <- maybe newTurns (pure . (.turns)) o.optPredecessor
  custody <- maybe (newFakeCustody o.optProfile selectedProvider) (pure . (.custody)) o.optPredecessor
  factory <- newFactory o.optPlans
  let config =
        (piRuntimeConfig selectedProvider selectedModel working private)
          { hostId = "host"
          , ccPatch = o.optProfile == "cc-patch-subscription"
          , credentialTtl = 10
          , wallTimeout = o.optWallTimeout
          , cancellationGrace = 0.05
          , territoryProfile = o.optTerritory
          }
  adapter <-
    newPiRuntimeAdapter
      config
      (piContinuationCodec (continuationOperations continuations))
      (turnOperations turns)
      (custodyOperations custody)
      getMonotonicTime
      (Just (factoryRecord factory))
  let identity = (adapterDescriptor adapter).identity
      component = ok (mkInstalledComponent "pi-coding-agent" piSdkVersion piSdkSource)
      installation = ok (mkRuntimeInstallation identity 1 [component] "test" "test" Set.empty)
  modifyAdapterRuntime adapter $ \r ->
    r
      { installation = Just installation
      , node = Just "/fake/node"
      , sdkEntrypoint = Just "/fake/pi/index.js"
      , ccPatchEntrypoint = if o.optProfile == "cc-patch-subscription" then Just "/fake/pi-cc-patch/index.ts" else Nothing
      }
  pure
    Rig
      { root
      , profile = o.optProfile
      , territoryProfile = o.optTerritory
      , connection
      , continuations
      , turns
      , custody
      , factory
      , adapter
      , working
      }
  where
    createDirectoryIfMissing' path = do
      exists <- try (createDirectory path)
      case exists of
        Left (_ :: IOError) -> pure ()
        Right () -> pure ()

rigConfig :: Rig -> IO PiRuntimeConfig
rigConfig r = adapterConfig r.adapter

runtimeRootEntries :: Rig -> IO [FilePath]
runtimeRootEntries r = rigConfig r >>= listDirectory . (.runtimeRoot)

data InvocationOptions = InvocationOptions
  { invContinuation :: Maybe Continuation
  , invSelected :: Maybe ResolutionSnapshot
  , invDeadline :: Maybe Double
  , invCapabilities :: Maybe [ToolMethod]
  , invMaxCalls :: Integer
  }

invocationOptions :: InvocationOptions
invocationOptions = InvocationOptions Nothing Nothing Nothing Nothing 16

data Invoked = Invoked
  { invocation :: PiRuntimeInvocation
  , attachment :: EpisodeAttachment
  , territory :: Territory
  , binding :: MotusAttachmentBinding
  }

-- | @rig.invocation(name, ...)@.
invoke :: Rig -> Text -> InvocationOptions -> IO Invoked
invoke rig name o = do
  territory <- newTerritory (if rig.territoryProfile == "local" then "local-process" else rig.territoryProfile)
  let source = rig.root </> T.unpack ("source-" <> name)
  createDirectory source
  writeFile (source </> "marker.txt") "marker"
  archive <- workspaceArchive source
  binding <- openMotusBinding territory.provider ("territory-" <> name) defaultSpec archive name
  let episode = ok (mkEpisodeId ("episode-" <> name))
  now <- getMonotonicTime
  let deadline' = fromMaybe (now + (if rig.profile /= "api-key" then 20 else 5)) o.invDeadline
      selected = fromMaybe (snapshotFor Nothing rig.connection rig.territoryProfile) o.invSelected
  attachment <- newEpisodeAttachment episode selected (motusBinding binding) ("attachment-" <> name) deadline' episodeOptions
  execution <- bindingExecution binding
  workspace <- newMotusWorkspaceAdapter territory.provider execution ["/bin/true"] defaultCommandTimeout
  gw <- Episode.gateway attachment (workspaceHandsAdapter workspace) 256
  let admitted = fromMaybe allToolMethods o.invCapabilities
  grant <-
    openGrant
      (Episode.grants attachment)
      (grantSpec admitted deadline' o.invMaxCalls)
        { specWritablePaths = ["output.txt" | WorkspaceWrite `elem` admitted]
        , specAllowedArgv = [["/bin/true"] | WorkspaceShell `elem` admitted]
        }
  view <- custodyView rig.custody
  inv <-
    newPiRuntimeInvocation
      PiRuntimeInvocation
        { operationId = name
        , episodeId = episode
        , turnId = ok (mkTurnId ("turn-" <> name))
        , prompt
        , connection = view
        , attachment
        , gateway = gw
        , grantEpoch = grant.grantEpoch
        , continuation = o.invContinuation
        }
  pure Invoked {invocation = inv, attachment, territory, binding}

invocation :: Rig -> Text -> IO PiRuntimeInvocation
invocation rig name = (.invocation) <$> invoke rig name invocationOptions

-- | @claimed(reference)@.
claimed :: Text -> Continuation
claimed reference =
  ok
    ( mkContinuation
        (ok (mkContinuationId ("id-" <> reference)))
        (ok (mkThreadId "thread"))
        piContinuationDescriptor
        reference
        ContinuationInUse
    )

-- | @dataclasses.replace(invocation, ...)@ through one transformation of a
-- copy, without re-running validation.
rebuild :: PiRuntimeInvocation -> (PiRuntimeInvocation -> PiRuntimeInvocation) -> PiRuntimeInvocation
rebuild i f = f i

-- ---------------------------------------------------------------------------
-- Assertions

raises :: IO a -> ErrorClass -> Text -> Expectation
raises action cls fragment =
  try action >>= \case
    Left (e :: AgenticusError) -> do
      (e.errorClass, e.errorClass `isSubclassOf` cls) `shouldBe` (e.errorClass, True)
      (e.errorMessage, fragment `T.isInfixOf` e.errorMessage) `shouldBe` (e.errorMessage, True)
    Right _ -> expectationFailure ("expected " <> show cls <> " containing " <> show fragment)

-- | @pytest.raises(ValueError)@, counting the @ValueError@ subclasses the
-- port names verbatim (@binascii.Error@, @UnicodeDecodeError@).
raisesValueLike :: Either AgenticusError a -> Expectation
raisesValueLike = \case
  Left e ->
    (e.errorClass, e.errorClass `isSubclassOf` ValueError || e.errorClass `elem` [OtherError "Error", OtherError "UnicodeDecodeError"])
      `shouldBe` (e.errorClass, True)
  Right _ -> expectationFailure "expected a ValueError"

-- | Poll until the condition holds, failing after @seconds@.
waitUntil :: Double -> IO Bool -> IO ()
waitUntil seconds condition = do
  done <- timeout (round (seconds * 1000000)) loop
  maybe (expectationFailure "condition did not hold in time") pure done
  where
    loop = condition >>= \held -> unless held (threadDelay 1000 >> loop)

-- | A JavaScript fixture extracted verbatim from the reference test.
fixture :: FilePath -> IO Text
fixture name = TE.decodeUtf8 <$> B.readFile ("test" </> "fixtures" </> "pi" </> name)

withTemp :: (FilePath -> IO a) -> IO a
withTemp = withSystemTempDirectory "petrus-pi"
