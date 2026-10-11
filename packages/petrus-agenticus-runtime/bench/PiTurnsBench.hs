-- | Whole Pi Turns over the committed fake SDKs; twins of the @pi-*-turn@
-- rows of @bench/python_bench.py@.
--
-- Each row runs real @node@ on the runtime's own helper, against the fake
-- SDK modules under @test/fixtures/pi@ (the reference tests' fakes,
-- extracted verbatim), with a fresh operation id every call:
--
-- * @pi-native-turn@: the native A2 adapter ('startPi'): open a Local Motus
--   territory, its Episode Attachment, the Hands gateway and a grant, then
--   start (custody materialization, the @pi_helper.mjs@ subprocess over
--   @framed_tool_sdk.mjs@: one @workspace_read@ through the gateway, the
--   session file and the candidate), wait (the session validation,
--   admission and the continuation and Turn stores), close, and settle.
-- * @pi-a5-turn@: the A5 application adapter ('startApplication') on a
--   @gondolin@ territory (a Local Motus provider whose leases report
--   @gondolin@, as the reference's tests do): @pi_application_helper.mjs@
--   over @application_coding.mjs@, @application_core_projection.mjs@ and
--   @application_ai.mjs@, one @workspace_read@ through the gateway, then
--   wait, close and settle.
-- * @pi-model-phase-turn@: one model-phase Activity
--   ('modelPhaseAdapterActivity'): custody materialization,
--   @pi_model_phase_helper.mjs@ over @model_phase_coding.mjs@ (one public
--   stream, five tool declarations), candidate validation, admission,
--   release and publication.
--
-- The custody is the reference tests' fake (one READ lease per Turn), the
-- same on both sides. The adapters' installation is assigned the way the
-- reference's tests assign it (@_installation@, @_node@, ...): the helpers
-- run for real, but no installed SDK is probed.
module PiTurnsBench (piTurnsBenchmarks) where

import Control.Exception (throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Activity (ActivityExecutionContext (..), ActivityInvocation (..), invocation)
import Petrus.Agenticus.Attachment.Binding (bindingExecution, motusBinding, openMotusBinding)
import Petrus.Agenticus.Attachment.Episode (episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor (..), DescriptorKind (..), capabilityDescriptor, descriptorIdentity)
import Petrus.Agenticus.Catalog.Resolution (mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody
  ( AdmissionResult (..)
  , AttachmentFence (..)
  , ConnectionStatus (..)
  , ConnectionView (..)
  , ReleaseResult (..)
  , mkConnectionIdentity
  )
import Petrus.Agenticus.Connection.Materialization (CleanupEvidence (..))
import Petrus.Agenticus.Hands.Contract (ToolMethod (..), allToolMethods)
import Petrus.Agenticus.Hands.Grants (CapabilityGrant (..), GrantSpec (..), grantSpec, openGrant)
import Petrus.Agenticus.Hands.Workspace (defaultCommandTimeout, newMotusWorkspaceAdapter, workspaceHandsAdapter)
import Petrus.Agenticus.Program.AgentNet (ModelSettlement (..), StopReason (..), loopStateToData, mkLoopState, modelPhaseActivity, modelSettlementFromData)
import Petrus.Agenticus.Runtime.Custody
import Petrus.Agenticus.Runtime.Installation (mkInstalledComponent, mkRuntimeInstallation)
import Petrus.Agenticus.Runtime.Pi.Internal
import Petrus.Agenticus.Runtime.Pi.Internal qualified as Pi
import Petrus.Agenticus.Runtime.PiApplication.Internal
import Petrus.Agenticus.Runtime.PiApplication.Internal qualified as App
import Petrus.Agenticus.Runtime.PiModelPhase
import Petrus.Agenticus.Runtime.Profiles (piApplicationA5Gondolin, piNativeA2Local)
import Petrus.Agenticus.Thread.Identity (mkEpisodeId, mkTurnId)
import Petrus.Json (Json (..))
import Petrus.Motus.Execution
  ( EnvironmentProvider (..)
  , attachmentId
  , attachmentInputDigest
  , attachmentLease
  , attachmentWorkspace
  , defaultSpec
  , identityLeaseId
  , identityOperationId
  , leaseCapabilities
  , leaseId
  , leaseOperationId
  , leaseState
  , mkEnvironmentLease
  , mkExecutionAttachment
  , mkLeaseIdentity
  )
import Petrus.Motus.Execution qualified as Execution
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import System.Directory (createDirectory, findExecutable, makeAbsolute)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import Test.Tasty.Bench
import TurnsBench (completed, counter, hostFencedEffect, ok, settled, verified)

-- | The fake SDKs' expected key.
piKey :: ByteString
piKey = "pi-key-canary-never-render"

-- | The reference tests' fake custody: one READ lease per Turn over a fixed
-- secret.
benchCustody :: ByteString -> HostConnectionCustody
benchCustody secret =
  HostConnectionCustody
    { materialize = \connection host mode ttl _ -> do
        now <- getMonotonicTime
        pure
          HostMaterialization
            { fence = AttachmentFence "credential" "lease" connection host 1 3 4
            , mode
            , expiresAt = now + ttl
            , home = ProviderHome {read = pure secret, replace = \_ -> pure ()}
            }
    , activate = \_ _ -> fail "activate"
    , admitResult = \fence operationId -> pure AdmissionResult {operationId, purpose = "result", attachmentId = fence.attachmentId}
    , checkpoint = \_ _ -> fail "checkpoint"
    , release = \m operationId ->
        pure
          ReleaseResult
            { operationId
            , cleanup =
                CleanupEvidence
                  { attachmentId = m.fence.attachmentId
                  , removed = True
                  , alreadyAbsent = False
                  , bytesOverwritten = toInteger (B.length secret)
                  , physicalErasureGuaranteed = False
                  , securityViolation = False
                  }
            }
    }

view :: Text -> ConnectionView
view provider = ConnectionView (ok (mkConnectionIdentity "connection" provider "account" "api-key")) StatusReady 3 4 Nothing

fixture :: FilePath -> IO FilePath
fixture name = makeAbsolute ("test" </> "fixtures" </> "pi" </> name)

-- | A Local Motus provider whose leases report @name@: the reference
-- tests' provider double for the split territories.
relabelled :: Text -> EnvironmentProvider -> EnvironmentProvider
relabelled name inner =
  inner
    { providerName = name
    , providerCreate = \operation spec -> rename <$> providerCreate inner operation spec
    , providerLookup = fmap (fmap rename) . providerLookup inner
    , providerAttach = \lease archive digest -> renameAttachment <$> providerAttach inner (restore lease) archive digest
    , providerExecute = \a command -> renameResult <$> providerExecute inner (restoreAttachment a) command
    , providerExport = providerExport inner . restoreAttachment
    , providerCancel = providerCancel inner . restore
    , providerReconcile = fmap renameReconcile . providerReconcile inner
    , providerDestroy = \lease -> do
        cleanup <- providerDestroy inner (restore lease)
        pure cleanup {Execution.cleanupIdentity = renameIdentity (Execution.cleanupIdentity cleanup)}
    , providerPrivateFiles = Nothing
    }
  where
    original = providerName inner
    relabel label lease = ok (mkEnvironmentLease (leaseOperationId lease) label (leaseId lease) (leaseCapabilities lease) (leaseState lease))
    rename = relabel name
    restore = relabel original
    renameAttachment a = ok (mkExecutionAttachment (attachmentId a) (rename (attachmentLease a)) (attachmentInputDigest a) (attachmentWorkspace a))
    restoreAttachment a = ok (mkExecutionAttachment (attachmentId a) (restore (attachmentLease a)) (attachmentInputDigest a) (attachmentWorkspace a))
    renameIdentity identity = ok (mkLeaseIdentity (identityOperationId identity) name (identityLeaseId identity))
    renameResult r =
      let p = Execution.resultProvenance r
       in ok
            ( Execution.mkCommandResult
                (Execution.resultReturncode r)
                (Execution.resultStdout r)
                (Execution.resultStderr r)
                (Execution.resultTimedOut r)
                (Execution.resultSuperseded r)
                (Execution.resultOutputTruncated r)
                (ok (Execution.mkExecutionProvenance (Execution.provenanceOperationId p) name (Execution.provenanceLeaseId p)))
            )
    renameReconcile r = case Execution.reconcileClassification r of
      Execution.ReconcileTerminal -> Execution.terminalResult (maybe (error "terminal without lease") rename (Execution.reconcileLease r)) (Execution.reconcileDetail r)
      Execution.ReconcileRetryable -> Execution.retryableResult (Execution.reconcileDetail r)
      Execution.ReconcileUncertain -> Execution.uncertainResult (rename <$> Execution.reconcileLease r) (Execution.reconcileDetail r)

-- ---------------------------------------------------------------------------
-- Native A2

piNativeTurn :: FilePath -> FilePath -> IO (IO ())
piNativeTurn node root = do
  let working = root </> "working"
      private = root </> "private"
  createDirectory working
  createDirectory private
  setFileMode private 0o700
  sdk <- fixture "framed_tool_sdk.mjs"
  helper <- piHelperPath
  values <- newIORef Map.empty
  let continuations =
        PiContinuationOperations
          { store = \operationId payload -> do
              let reference = "pi-continuation-" <> operationId
              modifyIORef' values (Map.insert reference payload)
              pure reference
          , load = \reference -> maybe (fail "no continuation") pure . Map.lookup reference =<< readIORef values
          }
      turns = PiTurnOperations {storeTurn = \operationId _ -> pure ("pi-turn-" <> operationId)}
  let component = ok (mkInstalledComponent "pi-coding-agent" piSdkVersion piSdkSource)
      prepare descriptor r =
        r
          { installation = Just (ok (mkRuntimeInstallation descriptor.identity 1 [component] "bench" "bench" Set.empty))
          , node = Just node
          , sdkEntrypoint = Just (T.pack sdk)
          , factory = Just (subprocessFactory helper)
          }
  adapter <-
    newPiRuntimeAdapterWith
      PiAdapterOptions {clock = getMonotonicTime, factory = Nothing, hooks = noHooks, prepare}
      (piRuntimeConfig "provider" "model" working private) {Pi.hostId = "host-1", Pi.credentialTtl = 10, Pi.wallTimeout = 30, Pi.cancellationGrace = 2}
      (piContinuationCodec continuations)
      turns
      (benchCustody piKey)
  let selected =
        ok . mkResolutionSnapshot 1 $
          [ piNativeA2Local
          , piConnectionCapabilities
          , piProgramCapabilities
          , piCollocatedHands
          , piLocalTerritory
          , piContinuationCapabilities
          , hostFencedEffect
          ]
  createDirectory (root </> "workspace")
  writeFile (root </> "workspace" </> "marker.txt") "marker"
  archive <- workspaceArchive (root </> "workspace")
  provider <- localProvider <$> newLocalProcessEnvironment
  next <- counter
  pure $ do
    n <- next
    binding <- openMotusBinding provider ("territory-" <> n) defaultSpec archive ("input-" <> n)
    now <- getMonotonicTime
    let episode = ok (mkEpisodeId ("episode-" <> n))
        deadline = now + 30
    attachment <- newEpisodeAttachment episode selected (motusBinding binding) ("attachment-" <> n) deadline episodeOptions
    execution <- bindingExecution binding
    workspace <- newMotusWorkspaceAdapter provider execution ["/bin/true"] defaultCommandTimeout
    gateway <- Episode.gateway attachment (workspaceHandsAdapter workspace) 256
    grant <-
      openGrant
        (Episode.grants attachment)
        (grantSpec allToolMethods deadline 16) {specWritablePaths = ["output.txt"], specAllowedArgv = [["/bin/true"]]}
    invocation' <-
      newPiRuntimeInvocation
        PiRuntimeInvocation
          { operationId = "operation-" <> n
          , episodeId = episode
          , turnId = ok (mkTurnId ("turn-" <> n))
          , prompt = "prompt"
          , connection = view "provider"
          , attachment
          , gateway
          , grantEpoch = grant.grantEpoch
          , continuation = Nothing
          }
    operation <- startPi adapter invocation'
    completed =<< waitPiOperation operation (Just 30)
    verified =<< closePiOperation operation
    settled attachment

-- ---------------------------------------------------------------------------
-- A5 application

piA5Turn :: FilePath -> FilePath -> IO (IO ())
piA5Turn node root = do
  let working = root </> "working"
      runtime = root </> "runtime"
  createDirectory working
  createDirectory runtime
  setFileMode runtime 0o700
  coding <- fixture "application_coding.mjs"
  core <- fixture "application_core_projection.mjs"
  ai <- fixture "application_ai.mjs"
  helper <- piApplicationHelperPath
  values <- newIORef Map.empty
  let continuations =
        PiApplicationContinuationOperations
          { store = \operationId payload -> do
              let reference = "pi-application-continuation-" <> operationId
              modifyIORef' values (Map.insert reference payload)
              pure reference
          , load = \reference -> maybe (fail "no continuation") pure . Map.lookup reference =<< readIORef values
          }
      turns = PiApplicationTurnOperations {storeTurn = \operationId _ -> pure ("pi-application-turn-" <> operationId)}
  let applicationComponent = ok (mkInstalledComponent "pi-agent-core" "0.83.0" "bench")
      prepare descriptor r =
        r
          { installation = Just (ok (mkRuntimeInstallation descriptor.identity 1 [applicationComponent] "bench" "bench" Set.empty))
          , node = Just node
          , coding = Just coding
          , core = Just core
          , ai = Just ai
          , factory = Just (applicationSubprocessFactory helper)
          }
  adapter <-
    newPiApplicationRuntimeAdapterWith
      ApplicationAdapterOptions {clock = getMonotonicTime, factory = Nothing, hooks = noApplicationHooks, prepare}
      (piApplicationRuntimeConfig "anthropic" "claude-sonnet-4-5" "gondolin" working runtime)
        { App.hostId = "host-1"
        , App.wallTimeout = 30
        , App.cancellationGrace = 2
        }
      (piApplicationContinuationCodec continuations)
      turns
      (applicationCustody (benchCustody "credential-canary"))
  let selected =
        ok . mkResolutionSnapshot 1 $
          [ piApplicationA5Gondolin
          , piApplicationConnectionCapabilities
          , piApplicationProgramCapabilities
          , piApplicationHands
          , capabilityDescriptor (descriptorIdentity KindTerritory "motus.gondolin" 1) ["territory.gondolin"] []
          , piApplicationContinuationCapabilities
          , hostFencedEffect
          ]
  createDirectory (root </> "workspace")
  writeFile (root </> "workspace" </> "message.txt") "before"
  archive <- workspaceArchive (root </> "workspace")
  next <- counter
  pure $ do
    n <- next
    -- One provider per Attachment, as in the reference's tests.
    provider <- relabelled "gondolin" . localProvider <$> newLocalProcessEnvironment
    binding <- openMotusBinding provider ("territory-" <> n) defaultSpec archive ("input-" <> n)
    now <- getMonotonicTime
    let episode = ok (mkEpisodeId ("episode-" <> n))
        deadline = now + 30
    attachment <- newEpisodeAttachment episode selected (motusBinding binding) ("attachment-" <> n) deadline episodeOptions
    execution <- bindingExecution binding
    workspace <- newMotusWorkspaceAdapter provider execution ["/bin/true"] defaultCommandTimeout
    gateway <- Episode.gateway attachment (workspaceHandsAdapter workspace) 256
    grant <- openGrant (Episode.grants attachment) (grantSpec [WorkspaceRead] deadline 8)
    invocation' <-
      newPiApplicationRuntimeInvocation
        PiApplicationRuntimeInvocation
          { operationId = "operation-" <> n
          , episodeId = episode
          , turnId = ok (mkTurnId ("turn-" <> n))
          , observation = "observation"
          , connection = view "anthropic"
          , attachment
          , gateway
          , grantEpoch = grant.grantEpoch
          , continuation = Nothing
          }
    operation <- startApplication adapter invocation'
    completed =<< waitApplicationOperation operation (Just 30)
    verified =<< closeApplicationOperation operation
    settled attachment

-- ---------------------------------------------------------------------------
-- Model phase

piModelPhaseTurn :: FilePath -> FilePath -> IO (IO ())
piModelPhaseTurn node root = do
  let runtime = root </> "runtime"
  createDirectory runtime
  setFileMode runtime 0o700
  coding <- fixture "model_phase_coding.mjs"
  published <- newIORef (0 :: Int)
  let operations =
        PiModelPhaseOperations
          { loadContinuation = \_ -> fail "no continuation"
          , publish = \operationId _ _ -> do
              modifyIORef' published (+ 1)
              either throwIO pure (mkPiModelPhasePublication ("output-" <> operationId) ("continuation-" <> operationId))
          }
  adapter <-
    newPiModelPhaseAdapter
      (piModelPhaseConfig "anthropic" "claude-sonnet-4-5" "host-1" runtime "episode" "turn") {timeout = 30}
      (view "anthropic")
      (piModelPhaseCustody (benchCustody "credential-canary"))
      operations
      node
      (Just coding)
      (Just subprocessPhaseFactory {isSubprocess = False})
  let state = ok (mkLoopState "episode" "turn" 1 4 0 8 Nothing Nothing 1 ["workspace_read", "workspace_test"] [])
      context =
        ActivityExecutionContext
          { attemptId = "attempt"
          , epoch = "epoch"
          , claimant = "claimant"
          , instance' = Nothing
          , latestDetails = pure Null
          , heartbeat = \_ -> pure Null
          }
  next <- counter
  pure $ do
    n <- next
    raw <- modelPhaseAdapterActivity adapter (invocation modelPhaseActivity (loopStateToData state)) {idempotency = Just ("operation-" <> n)} context
    settlement <- either throwIO pure (modelSettlementFromData raw)
    if settlement.stop == Stop then pure () else fail "model phase did not stop"

-- | The three rows, each over its own directory under @tmp@; none when
-- @node@ is not on @PATH@ (the reference's Pi helper tests need it too).
piTurnsBenchmarks :: FilePath -> IO [Benchmark]
piTurnsBenchmarks tmp =
  findExecutable "node" >>= \case
    Nothing -> fail "pi-*-turn benchmarks need node on PATH"
    Just node -> do
      let build name make = do
            let directory = tmp </> name
            createDirectory directory
            bench name . whnfIO <$> make node directory
      sequence
        [ build "pi-native-turn" piNativeTurn
        , build "pi-a5-turn" piA5Turn
        , build "pi-model-phase-turn" piModelPhaseTurn
        ]
