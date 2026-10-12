-- | The implementation of "Petrus.Agenticus.Runtime.PiApplication". Besides its public
-- interface it exports what the tests and the differential corpus reach:
-- adapter internals (the reference's private attributes, for tests).
--
-- Not a stable interface: other code imports "Petrus.Agenticus.Runtime.PiApplication".
module Petrus.Agenticus.Runtime.PiApplication.Internal
  ( -- * Pins
    piApplicationCodingAgentVersion
  , piApplicationAgentCoreVersion
  , piApplicationAiVersion
  , piApplicationSourceCommit
    -- * Descriptors
  , piApplicationContinuationDescriptor
  , piApplicationProgram
  , piApplicationProgramCapabilities
  , piApplicationContinuationCapabilities
  , piApplicationConnectionCapabilities
  , piApplicationHands
    -- * Payloads
  , applicationTranscript
  , PiApplicationContinuationPayloadV1
  , mkPiApplicationContinuationPayloadV1
  , PiApplicationStepPayloadV1
  , mkPiApplicationStepPayloadV1
  , applicationPayloadSchemaVersion
  , PiApplicationContinuationOperations (..)
  , PiApplicationTurnOperations (..)
  , PiApplicationContinuationCodec
  , piApplicationContinuationCodec
  , applicationCodecStore
  , applicationCodecLoad
    -- * Configuration and invocations
  , PiApplicationRuntimeConfig (..)
  , piApplicationRuntimeConfig
  , newPiApplicationRuntimeConfig
  , renderPiApplicationRuntimeConfig
  , PiApplicationRuntimeInvocation (..)
  , newPiApplicationRuntimeInvocation
  , renderPiApplicationRuntimeInvocation
    -- * Connection custody
  , PiApplicationConnectionCustody (..)
  , applicationCustody
    -- * Helper clients
  , ApplicationCandidate (..)
  , ApplicationClient (..)
  , ApplicationClientArgs (..)
  , ApplicationFactory (..)
  , applicationSubprocessFactory
  , ApplicationSubprocessOptions (..)
  , applicationSubprocessOptions
  , ApplicationSubprocessClient
  , newApplicationSubprocessClient
  , newApplicationSubprocessClientWith
  , applicationSubprocessClient
  , piApplicationHelperPath
    -- * Operations
  , PiApplicationOperation
  , applicationOperationId
  , waitApplicationOperation
  , cancelApplicationOperation
  , closeApplicationOperation
  , applicationRuntimeOperation
    -- * The adapter
  , PiApplicationRuntimeAdapter
  , newPiApplicationRuntimeAdapter
  , ApplicationAdapterOptions (..)
  , applicationAdapterOptions
  , newPiApplicationRuntimeAdapterWith
  , applicationAdapterConfig
  , applicationAdapterDescriptor
  , applicationAdapterTerritory
  , applicationAdapterProgram
  , applicationAdapterContinuationDescriptor
  , renderPiApplicationRuntimeAdapter
  , ApplicationProbePaths (..)
  , applicationProbePaths
  , probeApplication
  , startApplication
    -- * Adapter internals (the reference's private attributes, for tests)
  , ApplicationAdapterRuntime (..)
  , readApplicationAdapterRuntime
  , ApplicationAdapterHooks (..)
  , noApplicationHooks
  , applicationBindingCurrent
  , applicationWorkingBinding
  ) where

import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, catch, fromException, mask_, throwIO, try)
import Control.Monad (filterM, forM_, unless, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Char (isDigit, isHexDigit, isLower)
import Data.IORef
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import GHC.Records (HasField (..))
import Paths_petrus_agenticus_runtime (getDataFileName)
import Petrus.Agenticus.Attachment.Binding (AttachmentBinding (..), bindingExecution, bindingLeaseIdentity, bindingProvider)
import Petrus.Agenticus.Attachment.Episode (EpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor
  ( CapabilityDescriptor
  , DescriptorIdentity
  , DescriptorKind (..)
  , capabilityDescriptor
  , descriptorIdentity
  )
import Petrus.Agenticus.Catalog.Resolution (snapshotDescriptor)
import Petrus.Agenticus.Connection.Custody
  ( AdmissionResult (..)
  , AttachmentFence (..)
  , ConnectionStatus (..)
  , ConnectionView (..)
  , LeaseMode (..)
  , ReleaseResult (..)
  )
import Petrus.Agenticus.Connection.Materialization (CleanupEvidence (..))
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract
  ( RejectionCategory (..)
  , ToolMethod (..)
  , ToolResult
  , allToolMethods
  , mkToolError
  , mkToolResult
  , toolMethodText
  , toolResultToModelData
  )
import Petrus.Agenticus.Hands.Gateway (HandsGateway, gatewayAttachmentEpoch, gatewayAttachmentId, gatewayEpisodeId)
import Petrus.Agenticus.Hands.Gateway qualified as Gateway
import Petrus.Agenticus.Hands.Grants (currentGrant, permits)
import Petrus.Agenticus.Internal.Exception
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Agenticus.Internal.Validate (encodeRefusal, sha256Hex, utf8Length)
import Petrus.Agenticus.Program.Descriptor (AgentProgramDescriptor, ProgramOwnership (..), agentProgramDescriptor, continuationRequirement)
import Petrus.Agenticus.Runtime.Custody
import Petrus.Agenticus.Runtime.Internal.Process (HelperSpec (..), Helper (..), Framing (..), privateEnvironment, spawnHelper, nextReceived, helperExited, closeHelper, waitExit, exitInt, runBounded, removeRoot)
import Petrus.Agenticus.Runtime.Installation
  ( ProbeDisposition (..)
  , RuntimeInstallation
  , RuntimeProbeResult
  , mkInstalledComponent
  , mkProbeIssue
  , mkRuntimeInstallation
  , mkRuntimeProbeResult
  )
import Petrus.Agenticus.Runtime.Internal.Lifecycle (Lifecycle, LifecycleTexts (..), newLifecycle)
import Petrus.Agenticus.Runtime.Internal.Lifecycle qualified as Lifecycle
import Petrus.Agenticus.Runtime.Operation
  ( RuntimeCleanupDisposition (..)
  , RuntimeOperation (..)
  , RuntimeOperationCleanup
  , runtimeProtocolError
  , runtimeProtocolErrorCode
  )
import Petrus.Agenticus.Runtime.Pi.Internal
  ( b64Encode
  , compactBytes
  , frameBytes
  , piAiSource
  , piAiVersion
  , piApiKeyCatalog
  , piSdkSourceCommit
  , piText
  , pyB64DecodeText
  , strictFrameLoad
  , strictLoad
  )
import Petrus.Agenticus.Runtime.Profiles (piApplicationA5E2b, piApplicationA5Gondolin)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement, mkRuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Continuation (Continuation, ContinuationDescriptor, ContinuationState (..), continuationDescriptor)
import Petrus.Agenticus.Thread.Identity (EpisodeId, LifecycleId (..), TurnId)
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Execution
  ( EnvironmentProvider (..)
  , LeaseState (..)
  , attachmentLease
  , identityOperationId
  , leaseIdentity
  , leaseProvider
  , leaseState
  )
import System.Directory (canonicalizePath, doesDirectoryExist, doesPathExist, findExecutable, makeAbsolute, pathIsSymbolicLink)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hFlush)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files qualified as Files
import System.Posix.Unistd (SystemID (..), getSystemID)
import System.Posix.User (getEffectiveUserID)

-- ---------------------------------------------------------------------------
-- Pins and descriptors

piApplicationCodingAgentVersion, piApplicationAgentCoreVersion, piApplicationAiVersion, piApplicationSourceCommit :: Text
piApplicationCodingAgentVersion = "0.83.0"
piApplicationAgentCoreVersion = "0.83.0"
piApplicationAiVersion = "0.83.0"
piApplicationSourceCommit = piSdkSourceCommit

programId, continuationId, connectionId', handsId :: DescriptorIdentity
programId = descriptorIdentity KindProgram "pi.application-owned" 1
continuationId = descriptorIdentity KindContinuation "pi.application-owned" 1
connectionId' = descriptorIdentity KindConnection "pi.compatible-api-key" 1
handsId = descriptorIdentity KindHands "pi.capability-scoped" 1

piApplicationContinuationDescriptor :: ContinuationDescriptor
piApplicationContinuationDescriptor = continuationDescriptor continuationId programId

piApplicationProgram :: AgentProgramDescriptor
piApplicationProgram =
  agentProgramDescriptor
    programId
    HarnessOwned
    True
    [continuationRequirement continuationId programId]
    (Just continuationId)
    True
    True

piApplicationProgramCapabilities, piApplicationContinuationCapabilities, piApplicationConnectionCapabilities, piApplicationHands :: CapabilityDescriptor
piApplicationProgramCapabilities = capabilityDescriptor programId ["program.application-owned"] []
piApplicationContinuationCapabilities = capabilityDescriptor continuationId ["continuation.application-owned"] []
piApplicationConnectionCapabilities = capabilityDescriptor connectionId' ["connection.pi-compatible"] []
piApplicationHands = capabilityDescriptor handsId ["hands.capability-scoped"] []

maxObservation, maxKey, helperLimit :: Int
maxObservation = 64 * 1024
maxKey = 8192
helperLimit = 16 * 1024 * 1024

-- ---------------------------------------------------------------------------
-- Payloads

-- | @_transcript(value, maximum, messages)@: a bounded strict JSON array of
-- objects.
applicationTranscript :: ByteString -> Int -> Int -> Either AgenticusError ByteString
applicationTranscript value maximum' messages
  | B.length value > maximum' = Left (valueError "Pi application transcript exceeds its byte bound")
  | otherwise = case strictLoad value of
      Left () -> Left (valueError "Pi application transcript must be strict UTF-8 JSON")
      Right (Array items) | length items <= messages && all isObject items -> Right value
      Right _ -> Left (valueError "Pi application transcript must be a bounded message array")
  where
    isObject = \case
      Object _ -> True
      _ -> False

applicationPayloadSchemaVersion :: Integer
applicationPayloadSchemaVersion = 1

-- | One application-owned transcript revision. 'Show' renders no field.
data PiApplicationContinuationPayloadV1 = PiApplicationContinuationPayloadV1
  { _workingDirectoryBinding :: Text
  , _transcriptJson :: ByteString
  }
  deriving stock (Eq)

instance HasField "workingDirectoryBinding" PiApplicationContinuationPayloadV1 Text where
  getField r = r._workingDirectoryBinding

instance HasField "transcriptJson" PiApplicationContinuationPayloadV1 ByteString where
  getField r = r._transcriptJson

instance Show PiApplicationContinuationPayloadV1 where
  show _ = "PiApplicationContinuationPayloadV1(schema_version=1)"

mkPiApplicationContinuationPayloadV1 :: Text -> ByteString -> Either AgenticusError PiApplicationContinuationPayloadV1
mkPiApplicationContinuationPayloadV1 binding transcript = do
  unless (T.length binding == 64 && T.all (\c -> isHexDigit c && (isDigit c || isLower c)) binding) $
    Left (valueError "Pi application working-directory binding must be SHA-256")
  _ <- applicationTranscript transcript 4000000 10000
  pure (PiApplicationContinuationPayloadV1 binding transcript)

-- | One application step's public evidence. 'Show' renders only the profile.
data PiApplicationStepPayloadV1 = PiApplicationStepPayloadV1
  { _profile :: Text
  , _results :: [ToolResult]
  , _finalText :: Text
  }
  deriving stock (Eq)

instance HasField "profile" PiApplicationStepPayloadV1 Text where
  getField r = r._profile

instance HasField "results" PiApplicationStepPayloadV1 [ToolResult] where
  getField r = r._results

instance HasField "finalText" PiApplicationStepPayloadV1 Text where
  getField r = r._finalText

instance Show PiApplicationStepPayloadV1 where
  show p = "PiApplicationStepPayloadV1(profile=" <> T.unpack (pythonStrRepr p.profile) <> ", schema_version=1)"

mkPiApplicationStepPayloadV1 :: Text -> [ToolResult] -> Text -> Either AgenticusError PiApplicationStepPayloadV1
mkPiApplicationStepPayloadV1 profile results finalText = do
  unless (profile `elem` ["gondolin", "e2b"]) $ Left (valueError "Pi application step profile is unsupported")
  when (utf8Length finalText > 1000000) $ Left (valueError "Pi application final text exceeds its bound")
  pure PiApplicationStepPayloadV1 {_profile = profile, _results = results, _finalText = finalText}

-- | @PiApplicationContinuationOperations@.
data PiApplicationContinuationOperations = PiApplicationContinuationOperations
  { store :: Text -> PiApplicationContinuationPayloadV1 -> IO Text
  , load :: Text -> IO PiApplicationContinuationPayloadV1
  }

-- | @PiApplicationTurnOperations@.
newtype PiApplicationTurnOperations = PiApplicationTurnOperations
  { storeTurn :: Text -> PiApplicationStepPayloadV1 -> IO Text
  }

newtype PiApplicationContinuationCodec = PiApplicationContinuationCodec PiApplicationContinuationOperations

piApplicationContinuationCodec :: PiApplicationContinuationOperations -> PiApplicationContinuationCodec
piApplicationContinuationCodec = PiApplicationContinuationCodec

applicationCodecStore :: PiApplicationContinuationCodec -> Text -> PiApplicationContinuationPayloadV1 -> IO Text
applicationCodecStore (PiApplicationContinuationCodec operations) operationId payload = do
  operationId' <- throwLeft (piText "Pi application operation" 256 operationId)
  reference <- operations.store operationId' payload
  throwLeft (piText "state reference" 512 reference)

applicationCodecLoad :: PiApplicationContinuationCodec -> Continuation -> IO PiApplicationContinuationPayloadV1
applicationCodecLoad (PiApplicationContinuationCodec operations) continuation = do
  when (continuation.descriptor /= piApplicationContinuationDescriptor) $
    throwIO (valueError "Pi application Continuation does not match this runtime")
  operations.load continuation.stateReference

-- | @_working_binding(path)@.
applicationWorkingBinding :: FilePath -> Text
applicationWorkingBinding path = sha256Hex (TE.encodeUtf8 ("pi-application:" <> T.pack path))

-- ---------------------------------------------------------------------------
-- Configuration

-- | @PiApplicationRuntimeConfig@. Build one with 'piApplicationRuntimeConfig'
-- and validate it with 'newPiApplicationRuntimeConfig'.
data PiApplicationRuntimeConfig = PiApplicationRuntimeConfig
  { provider :: Text
  , model :: Text
  , profile :: Text
  , workingDirectory :: FilePath
  , runtimeRoot :: FilePath
  , hostId :: Text
  , credentialTtl :: Double
  , wallTimeout :: Double
  , cancellationGrace :: Double
  , maxMessages :: Int
  , maxTranscriptBytes :: Int
  , maxToolCalls :: Int
  , maxEvents :: Int
  , maxFrameBytes :: Int
  , maxOutputBytes :: Int
  }
  deriving stock (Eq)

instance Show PiApplicationRuntimeConfig where
  show = T.unpack . renderPiApplicationRuntimeConfig

-- | The reference's defaults.
piApplicationRuntimeConfig :: Text -> Text -> Text -> FilePath -> FilePath -> PiApplicationRuntimeConfig
piApplicationRuntimeConfig provider model profile workingDirectory runtimeRoot =
  PiApplicationRuntimeConfig
    { provider
    , model
    , profile
    , workingDirectory
    , runtimeRoot
    , hostId = "local"
    , credentialTtl = 315.0
    , wallTimeout = 300.0
    , cancellationGrace = 2.0
    , maxMessages = 10000
    , maxTranscriptBytes = 4000000
    , maxToolCalls = 256
    , maxEvents = 10000
    , maxFrameBytes = 16 * 1024 * 1024
    , maxOutputBytes = 1000000
    }

-- | @repr(config)@ without the two private paths.
renderPiApplicationRuntimeConfig :: PiApplicationRuntimeConfig -> Text
renderPiApplicationRuntimeConfig c =
  "PiApplicationRuntimeConfig(provider="
    <> pythonStrRepr c.provider
    <> ", model="
    <> pythonStrRepr c.model
    <> ", profile="
    <> pythonStrRepr c.profile
    <> ", host_id="
    <> pythonStrRepr c.hostId
    <> ", credential_ttl="
    <> T.pack (J.pythonFloatRepr c.credentialTtl)
    <> ", wall_timeout="
    <> T.pack (J.pythonFloatRepr c.wallTimeout)
    <> ", cancellation_grace="
    <> T.pack (J.pythonFloatRepr c.cancellationGrace)
    <> ", max_messages="
    <> int c.maxMessages
    <> ", max_transcript_bytes="
    <> int c.maxTranscriptBytes
    <> ", max_tool_calls="
    <> int c.maxToolCalls
    <> ", max_events="
    <> int c.maxEvents
    <> ", max_frame_bytes="
    <> int c.maxFrameBytes
    <> ", max_output_bytes="
    <> int c.maxOutputBytes
    <> ")"
  where
    int = T.pack . show

-- | Validate and normalize a configuration
-- (@PiApplicationRuntimeConfig.__post_init__@).
newPiApplicationRuntimeConfig :: PiApplicationRuntimeConfig -> IO PiApplicationRuntimeConfig
newPiApplicationRuntimeConfig c = do
  provider <- throwLeft (piText "Pi application provider" 256 c.provider)
  model <- throwLeft (piText "Pi application model" 256 c.model)
  hostId <- throwLeft (piText "Pi application host_id" 256 c.hostId)
  unless (c.profile `elem` ["gondolin", "e2b"]) $ throwIO (valueError "Pi application profile must be gondolin or e2b")
  unless ((provider, model) `elem` piApiKeyCatalog) $
    throwIO (valueError "Pi application provider/model is outside the direct API-key catalog")
  workingDirectory <- directory "working_directory" c.workingDirectory
  runtimeRoot <- directory "runtime_root" c.runtimeRoot
  uid <- getEffectiveUserID
  rootStatus <- Files.getFileStatus runtimeRoot
  when (Files.fileMode rootStatus .&. 0o7777 /= 0o700 || Files.fileOwner rootStatus /= uid) $
    throwIO (valueError "Pi application runtime_root must be owned mode-0700")
  forM_ [("credential_ttl", c.credentialTtl), ("wall_timeout", c.wallTimeout), ("cancellation_grace", c.cancellationGrace)] $
    \(name, value) ->
      when (isNaN value || isInfinite value || value <= 0) $
        throwIO (valueError ("Pi application " <> name <> " must be positive and finite"))
  forM_
    [ ("max_messages", c.maxMessages)
    , ("max_transcript_bytes", c.maxTranscriptBytes)
    , ("max_tool_calls", c.maxToolCalls)
    , ("max_events", c.maxEvents)
    , ("max_frame_bytes", c.maxFrameBytes)
    , ("max_output_bytes", c.maxOutputBytes)
    ]
    $ \(name, value) -> when (value <= 0) $ throwIO (valueError ("Pi application " <> name <> " must be positive"))
  let encodedTranscript = 4 * ((c.maxTranscriptBytes + 2) `div` 3)
  when (c.maxFrameBytes > helperLimit || c.maxFrameBytes < encodedTranscript + maxObservation + 128 * 1024) $
    throwIO (valueError "Pi application frame bound cannot carry its transcript")
  pure c {provider, model, hostId, workingDirectory, runtimeRoot}
  where
    directory name selected = do
      linked <- pathIsSymbolicLink selected `catch` \(_ :: IOException) -> pure False
      when linked $ throwIO (valueError ("Pi application " <> name <> " must be stable"))
      path <- canonicalizePath selected
      isDirectory <- doesDirectoryExist path
      unless isDirectory $ throwIO (valueError ("Pi application " <> name <> " must exist"))
      pure path

-- ---------------------------------------------------------------------------
-- Invocations

-- | One application step request. Build it with
-- 'newPiApplicationRuntimeInvocation', which runs the reference's
-- @__post_init__@ checks.
data PiApplicationRuntimeInvocation = PiApplicationRuntimeInvocation
  { operationId :: Text
  , episodeId :: EpisodeId
  , turnId :: TurnId
  , observation :: Text
  , connection :: ConnectionView
  , attachment :: EpisodeAttachment
  , gateway :: HandsGateway
  , grantEpoch :: Integer
  , continuation :: Maybe Continuation
  }

instance Show PiApplicationRuntimeInvocation where
  show = T.unpack . renderPiApplicationRuntimeInvocation

-- | @repr(invocation)@: no observation, attachment, gateway or continuation.
renderPiApplicationRuntimeInvocation :: PiApplicationRuntimeInvocation -> Text
renderPiApplicationRuntimeInvocation i =
  "PiApplicationRuntimeInvocation(operation_id="
    <> pythonStrRepr i.operationId
    <> ", episode_id=EpisodeId(value="
    <> pythonStrRepr (lifecycleIdText i.episodeId)
    <> "), turn_id=TurnId(value="
    <> pythonStrRepr (lifecycleIdText i.turnId)
    <> "), connection="
    <> T.pack (show i.connection)
    <> ", grant_epoch="
    <> T.pack (show i.grantEpoch)
    <> ")"

newPiApplicationRuntimeInvocation :: PiApplicationRuntimeInvocation -> IO PiApplicationRuntimeInvocation
newPiApplicationRuntimeInvocation i = do
  operationId <- throwLeft (piText "Pi application operation" 256 i.operationId)
  when (T.null i.observation || utf8Length i.observation > maxObservation || T.elem '\0' i.observation) $
    throwIO (valueError "Pi application observation must be bounded non-empty text")
  when (i.connection.status /= StatusReady) $ throwIO (valueError "Pi application invocation requires a ready connection")
  when (i.connection.identity.profile /= "api-key") $ throwIO (valueError "Pi application accepts only an api-key connection")
  when (Episode.episodeId i.attachment /= i.episodeId) $
    throwIO (valueError "Pi application invocation requires its exact attachment")
  c <- Episode.coordinates i.attachment
  when
    ( (gatewayEpisodeId i.gateway, gatewayAttachmentId i.gateway, gatewayAttachmentEpoch i.gateway)
        /= (c.episodeId, c.attachmentId, c.attachmentEpoch)
    )
    $ throwIO (valueError "Pi application gateway attachment mismatch")
  when (i.grantEpoch <= 0) $ throwIO (valueError "Pi application grant epoch must be positive")
  pure
    PiApplicationRuntimeInvocation
      { operationId
      , episodeId = i.episodeId
      , turnId = i.turnId
      , observation = i.observation
      , connection = i.connection
      , attachment = i.attachment
      , gateway = i.gateway
      , grantEpoch = i.grantEpoch
      , continuation = i.continuation
      }

-- ---------------------------------------------------------------------------
-- Connection custody

-- | @PiApplicationConnectionCustody@: materialize, admit and release only.
data PiApplicationConnectionCustody = PiApplicationConnectionCustody
  { materialize :: Text -> Text -> LeaseMode -> Double -> Text -> IO HostMaterialization
  -- ^ connection, host, mode, ttl, operation
  , admitResult :: AttachmentFence -> Text -> IO AdmissionResult
  , release :: HostMaterialization -> Text -> IO ReleaseResult
  }

-- | The application's view of the native Pi custody (and so of the real
-- 'Petrus.Agenticus.Connection.Custody.AgentConnectionCustody' through
-- 'Petrus.Agenticus.Runtime.Pi.hostConnectionCustody').
applicationCustody :: HostConnectionCustody -> PiApplicationConnectionCustody
applicationCustody custody =
  PiApplicationConnectionCustody
    { materialize = custody.materialize
    , admitResult = custody.admitResult
    , release = custody.release
    }

-- ---------------------------------------------------------------------------
-- Helper clients

-- | @_Candidate@: the final text, the combined transcript and the step's
-- tool results. 'Show' renders no field.
data ApplicationCandidate = ApplicationCandidate
  { text :: Text
  , transcript :: ByteString
  , results :: [ToolResult]
  }
  deriving stock (Eq)

instance Show ApplicationCandidate where
  show _ = "_Candidate()"

-- | @_Client@: run one step (gateway, invocation, current, monotonic
-- deadline) and close, reporting whether cleanup is proven.
data ApplicationClient = ApplicationClient
  { run :: HandsGateway -> PiApplicationRuntimeInvocation -> IO Bool -> Double -> IO ApplicationCandidate
  , close :: IO Bool
  }

-- | The keyword arguments of @_Factory.create@.
data ApplicationClientArgs = ApplicationClientArgs
  { node :: FilePath
  , codingEntrypoint :: FilePath
  , coreEntrypoint :: FilePath
  , aiEntrypoint :: FilePath
  , privateRoot :: FilePath
  , config :: PiApplicationRuntimeConfig
  , invocation :: PiApplicationRuntimeInvocation
  , prior :: Maybe PiApplicationContinuationPayloadV1
  , apiKey :: Text
  }

newtype ApplicationFactory = ApplicationFactory
  { create :: ApplicationClientArgs -> IO ApplicationClient
  }

-- | @_SubprocessFactory(helper)@.
applicationSubprocessFactory :: FilePath -> ApplicationFactory
applicationSubprocessFactory helper =
  ApplicationFactory (\args -> applicationSubprocessClient <$> newApplicationSubprocessClient helper args)

-- | The installed verbatim @pi_application_helper.mjs@.
piApplicationHelperPath :: IO FilePath
piApplicationHelperPath = getDataFileName "data/pi_application_helper.mjs" >>= makeAbsolute

-- | Knobs the reference reaches by monkeypatching.
newtype ApplicationSubprocessOptions = ApplicationSubprocessOptions
  { modelData :: ToolResult -> Json
  -- ^ @ToolResult.to_model_data@.
  }

applicationSubprocessOptions :: ApplicationSubprocessOptions
applicationSubprocessOptions = ApplicationSubprocessOptions {modelData = toolResultToModelData}

-- | @_SubprocessClient@: one private helper process.
data ApplicationSubprocessClient = ApplicationSubprocessClient
  { config :: PiApplicationRuntimeConfig
  , options :: ApplicationSubprocessOptions
  , helper :: Helper
  , start :: [(Text, Json)]
  , priorTranscript :: ByteString
  , writeAllowed :: Bool
  }

newApplicationSubprocessClient :: FilePath -> ApplicationClientArgs -> IO ApplicationSubprocessClient
newApplicationSubprocessClient = newApplicationSubprocessClientWith applicationSubprocessOptions

newApplicationSubprocessClientWith :: ApplicationSubprocessOptions -> FilePath -> ApplicationClientArgs -> IO ApplicationSubprocessClient
newApplicationSubprocessClientWith options helper args = do
  let command =
        HelperSpec
          { executable = args.node
          , arguments = [helper, args.codingEntrypoint, args.coreEntrypoint, args.aiEntrypoint]
          , directory = Nothing
          , environment = Just (privateEnvironment args.privateRoot args.node)
          }
  started <- spawnHelper Chunks command >>= maybe (throwIO (runtimeProtocolError "helper-launch-failed")) pure
  grant <- currentGrant (Episode.grants args.invocation.attachment)
  let writeAllowed = maybe False (`permits` WorkspaceWrite) grant
      priorTranscript = maybe "[]" (.transcriptJson) args.prior
      cfg = args.config
      start =
        [ ("type", String "start")
        , ("version", Int 1)
        , ("provider", String cfg.provider)
        , ("model", String cfg.model)
        , ("api_key", String args.apiKey)
        , ("cwd", String (T.pack cfg.workingDirectory))
        , ("observation", String args.invocation.observation)
        , ("transcript", String (b64Encode priorTranscript))
        , ("write_allowed", Bool writeAllowed)
        ,
          ( "limits"
          , Object
              [ ("frame", Int (toInteger cfg.maxFrameBytes))
              , ("output", Int (toInteger cfg.maxOutputBytes))
              , ("transcript", Int (toInteger cfg.maxTranscriptBytes))
              , ("messages", Int (toInteger cfg.maxMessages))
              , ("events", Int (toInteger cfg.maxEvents))
              , ("tools", Int (toInteger cfg.maxToolCalls))
              ]
          )
        ]
  pure
    ApplicationSubprocessClient
      { config = cfg
      , options
      , helper = started
      , start
      , priorTranscript
      , writeAllowed
      }

applicationSubprocessClient :: ApplicationSubprocessClient -> ApplicationClient
applicationSubprocessClient c = ApplicationClient {run = runApplicationSubprocess c, close = closeApplicationSubprocess c}

protocol :: Text -> IO a
protocol = throwIO . runtimeProtocolError

-- | A set-membership test over the value: CPython 3.14's @TypeError@ for a
-- list or a dict (which @_execute@ settles as @runtime-failed@), nothing
-- otherwise.
unhashable :: Json -> IO ()
unhashable = \case
  Array _ -> refuse "list"
  Object _ -> refuse "dict"
  _ -> pure ()
  where
    refuse name = throwAgenticus TypeError ("cannot use '" <> name <> "' as a set element (unhashable type: '" <> name <> "')")

-- | @_write@: every encoding, bound or pipe failure is @helper-pipe-failed@.
writeFrame :: ApplicationSubprocessClient -> Json -> IO ()
writeFrame c frame = do
  encoded <- either (const (protocol "helper-pipe-failed")) pure (frameBytes frame)
  when (B.length encoded > c.config.maxFrameBytes) $ protocol "helper-pipe-failed"
  written <- try (B.hPut c.helper.input encoded >> hFlush c.helper.input)
  case written of
    Right () -> pure ()
    Left (_ :: IOException) -> protocol "helper-pipe-failed"

data Loop = Loop
  { buffer :: ByteString
  , ready :: Bool
  , abortSent :: Bool
  , graceEnd :: Double
  , eof :: Bool
  , seen :: Set Text
  , events :: Int
  , tools :: Int
  , results :: [ToolResult]
  -- ^ Newest first.
  , terminal :: Maybe ApplicationCandidate
  }

-- | The reference's fail-closed protocol state machine.
runApplicationSubprocess
  :: ApplicationSubprocessClient -> HandsGateway -> PiApplicationRuntimeInvocation -> IO Bool -> Double -> IO ApplicationCandidate
runApplicationSubprocess c gateway' invocation current deadline = do
  writeFrame c (Object c.start)
  final <- loop (Loop B.empty False False 0 False Set.empty 0 0 [] Nothing)
  when final.abortSent $ stopped
  terminal <- case final.terminal of
    Just value | B.null final.buffer -> pure value
    _ -> protocol "terminal-missing"
  -- @self._process.wait(timeout=grace)@: a helper still running raises
  -- @TimeoutExpired@, which no @except@ here catches, so @_execute@ settles
  -- it as @runtime-failed@.
  exited <- waitExit c.helper.process cfg.cancellationGrace
  case exited of
    Just code | exitInt code == 0 -> pure terminal
    Just _ -> protocol "helper-exit-inconsistent"
    Nothing -> throwAgenticus (OtherError "TimeoutExpired") "helper did not exit within the cancellation grace"
  where
    cfg = c.config
    stopped :: IO a
    stopped = current >>= \live -> protocol (if not live then "cancelled" else "deadline-exceeded")
    loop s
      | isJust s.terminal = pure s
      | otherwise = do
          now <- getMonotonicTime
          live <- current
          s1 <-
            if (not live || now >= deadline) && not s.abortSent
              then do
                writeFrame c (Object [("type", String "abort")])
                pure s {abortSent = True, graceEnd = now + cfg.cancellationGrace}
              else pure s
          when (s1.abortSent && now >= s1.graceEnd) stopped
          exited <- helperExited c.helper
          if exited && s1.eof
            then pure s1
            else do
              next <- nextChunk
              case next of
                -- The reference breaks once the helper has exited and no
                -- output is pending.
                Nothing | exited -> pure s1
                Nothing -> loop s1
                Just Nothing -> loop s1 {eof = True}
                Just (Just chunk) -> do
                  let buffer = s1.buffer <> chunk
                  when (B.length buffer > cfg.maxFrameBytes) $ protocol "frame-overflow"
                  s2 <- frames s1 {buffer}
                  loop s2
    nextChunk = nextReceived c.helper 50000
    frames s = case B.elemIndex 10 s.buffer of
      Nothing -> pure s
      Just i -> do
        when (isJust s.terminal) $ protocol "frame-order"
        let raw = B.take i s.buffer
            rest = B.drop (i + 1) s.buffer
        fields <- case strictFrameLoad raw of
          Right (Object members) -> pure members
          _ -> protocol "malformed-frame"
        let events = s.events + 1
        when (events > cfg.maxEvents) $ protocol "event-overflow"
        s' <- frame s {buffer = rest, events} fields
        frames s'
    keys fields = sort (map fst fields)
    member name fields = fromMaybe Null (lookup name fields)
    frame s fields = do
      let kind = lookup "type" fields
      when (s.abortSent && kind /= Just (String "failed")) stopped
      -- @kind in {"tool_call", "guard_blocked"}@ cannot hash a list or a
      -- dict (the @"ready"@ comparison before it is just false).
      forM_ kind unhashable
      case kind of
        Just (String "ready") | not s.ready && keys fields == ["type"] -> pure s {ready = True}
        Just (String name) | name `elem` ["tool_call", "guard_blocked"] -> toolFrame s fields (name == "guard_blocked")
        Just (String "complete") -> do
          when (not s.ready || keys fields /= ["text", "transcript", "type"]) $ protocol "frame-order"
          case complete (member "text" fields) (member "transcript" fields) of
            Right (text, combined) -> pure s {terminal = Just (ApplicationCandidate text combined (reverse s.results))}
            Left () -> protocol "malformed-complete"
        Just (String "failed") | keys fields == ["code", "type"] -> do
          -- @frame.get("code") in {...}@ cannot hash a list or a dict.
          unhashable (member "code" fields)
          case member "code" fields of
            String code
              | code `elem` ["aborted", "provider-failed", "protocol-failed"] ->
                  if code == "aborted" && s.abortSent then stopped else protocol code
            _ -> protocol "frame-order"
        _ -> protocol "frame-order"
    toolFrame s fields blocked = do
      let identity = member "id" fields
          method = member "method" fields
          params = member "params" fields
      -- @len(identity.encode())@ raises outside any @try@, once the frame
      -- order and the identity's type have passed.
      case identity of
        String i
          | s.ready && keys fields == ["id", "method", "params", "type"] && not (T.null i)
          , Just refusal <- encodeRefusal i ->
              throwIO refusal
        _ -> pure ()
      -- @method not in _METHODS@ (a frozenset) raises @TypeError@ for a
      -- list or a dict, once every earlier operand of the @or@ is false.
      case identity of
        String i
          | s.ready
              && keys fields == ["id", "method", "params", "type"]
              && not (T.null i)
              && utf8Length i <= 128
              && not (i `Set.member` s.seen) ->
              unhashable method
        _ -> pure ()
      callId <- case (identity, method, params) of
        (String i, String m, Object _)
          | s.ready
              && keys fields == ["id", "method", "params", "type"]
              && not (T.null i)
              && utf8Length i <= 128
              && not (i `Set.member` s.seen)
              && m `elem` map toolMethodText allToolMethods ->
              pure i
        _ -> protocol "malformed-tool-call"
      let tools = s.tools + 1
      when (tools > cfg.maxToolCalls) $ protocol "tool-overflow"
      coords <- Episode.coordinates invocation.attachment
      result <-
        if blocked
          then do
            when (method /= String (toolMethodText WorkspaceWrite) || c.writeAllowed) $ protocol "malformed-tool-call"
            throwLeft $ do
              rejection <- mkToolError CategoryWrite "application guard blocked workspace write"
              mkToolResult callId coords.attachmentId coords.attachmentEpoch False Nothing (Just rejection)
          else
            Gateway.submit
              gateway'
              ( Object
                  [ ("version", Int 1)
                  , ("call_id", String callId)
                  , ("episode_id", String coords.episodeId)
                  , ("attachment_id", String coords.attachmentId)
                  , ("attachment_epoch", Int coords.attachmentEpoch)
                  , ("grant_epoch", Int invocation.grantEpoch)
                  , ("method", method)
                  , ("params", params)
                  ]
              )
      unless blocked $
        writeFrame c (Object [("type", String "tool_result"), ("id", String callId), ("result", c.options.modelData result)])
      pure s {tools, seen = Set.insert callId s.seen, results = result : s.results}
    -- The @complete@ member checks; 'Left' is the reference's
    -- @except ValueError, TypeError@.
    complete textValue transcriptValue = do
      text <- case textValue of
        String value | isNothing (encodeRefusal value) && utf8Length value <= cfg.maxOutputBytes -> Right value
        _ -> Left ()
      encoded <- case transcriptValue of
        String value -> Right value
        _ -> Left ()
      delta <- either (const (Left ())) Right (pyB64DecodeText encoded)
      when (b64Encode delta /= encoded) $ Left ()
      _ <- either (const (Left ())) Right (applicationTranscript delta cfg.maxTranscriptBytes cfg.maxMessages)
      priorMessages <- strictLoad c.priorTranscript
      deltaMessages <- strictLoad delta
      -- @json.dumps(..., ensure_ascii=False).encode()@: a message that holds
      -- a lone surrogate fails the encode.
      combined <- case (priorMessages, deltaMessages) of
        (Array p, Array d) -> either (const (Left ())) Right (compactBytes (Array (p <> d)))
        _ -> Left ()
      _ <- either (const (Left ())) Right (applicationTranscript combined cfg.maxTranscriptBytes cfg.maxMessages)
      pure (text, combined)

-- | Close pipes, kill the helper's whole process group, and report whether
-- the helper and its stderr drain are proven gone.
closeApplicationSubprocess :: ApplicationSubprocessClient -> IO Bool
closeApplicationSubprocess c = closeHelper c.helper c.config.cancellationGrace

-- ---------------------------------------------------------------------------
-- Operations

-- | One started application step (@_Operation@).
data PiApplicationOperation = PiApplicationOperation
  { adapter :: PiApplicationRuntimeAdapter
  , inv :: PiApplicationRuntimeInvocation
  , key :: Text
  , prior :: Maybe PiApplicationContinuationPayloadV1
  , factory :: ApplicationFactory
  , lifecycle :: Lifecycle
  }

instance Eq PiApplicationOperation where
  a == b = a.lifecycle == b.lifecycle

instance Show PiApplicationOperation where
  show o = "_Operation(operation_id=" <> T.unpack (pythonStrRepr o.inv.operationId) <> ")"

applicationOperationId :: PiApplicationOperation -> Text
applicationOperationId o = o.inv.operationId

runOperation :: PiApplicationOperation -> IO ()
runOperation o = do
  outcome <- try (executeOperation o.adapter o)
  settled <- case outcome of
    Right value -> pure value
    Left (_ :: SomeException) -> do
      failed <- settle o.inv TurnFailed 0 "runtime-failed" Nothing Nothing
      pure (failed, RuntimeCleanupUnverified)
  Lifecycle.settle o.lifecycle (settle o.inv TurnCancelled 0 "cancelled" Nothing Nothing) settled

operationCurrent :: PiApplicationOperation -> IO Bool
operationCurrent o = Lifecycle.current o.lifecycle

-- | The publication check after cancellation (@_publication_error@).
publicationError :: PiApplicationOperation -> IO (Maybe Text)
publicationError o = do
  grant <- currentGrant (Episode.grants o.inv.attachment)
  case grant of
    Just g | g.grantEpoch == o.inv.grantEpoch -> do
      now <- adapterNow o.adapter
      pure (if now >= min g.deadline (Episode.episodeDeadline o.inv.attachment) then Just "deadline-exceeded" else Nothing)
    _ -> pure (Just "grant-mismatch")

-- | @_Operation.claim@: the last cancellation point before publication.
claim :: PiApplicationOperation -> IO (Maybe Text)
claim o = do
  first <- Lifecycle.inspect o.lifecycle (publicationError o)
  case first of
    Just e -> pure (Just e)
    Nothing -> do
      current <- applicationBindingCurrent o.adapter o.inv
      Lifecycle.claim o.lifecycle $
        publicationError o >>= \case
          Just e -> pure (Just e)
          Nothing
            | not current -> pure (Just "runtime-territory-lease-required")
            | otherwise -> pure Nothing

-- | @wait(timeout)@.
waitApplicationOperation :: PiApplicationOperation -> Maybe Double -> IO RuntimeTurnSettlement
waitApplicationOperation o = Lifecycle.waitSettled o.lifecycle

-- | @cancel(reason)@.
cancelApplicationOperation :: PiApplicationOperation -> Text -> IO CancellationDisposition
cancelApplicationOperation o reason = do
  _ <- throwLeft (piText "Pi application cancellation reason" 256 reason)
  Lifecycle.requestCancel o.lifecycle $
    Episode.cancel o.inv.attachment reason `catch` rethrowAsync

-- | @close()@.
closeApplicationOperation :: PiApplicationOperation -> IO RuntimeOperationCleanup
closeApplicationOperation o = do
  let config = o.adapter.config
  Lifecycle.closeWith o.lifecycle (config.cancellationGrace * 2) (Lifecycle.settledEvidence o.lifecycle)

-- | The operation as the provider-neutral 'RuntimeOperation' record.
applicationRuntimeOperation :: PiApplicationOperation -> RuntimeOperation
applicationRuntimeOperation o =
  RuntimeOperation
    { operationId = o.inv.operationId
    , wait = waitApplicationOperation o
    , cancel = cancelApplicationOperation o
    , close = closeApplicationOperation o
    }

-- ---------------------------------------------------------------------------
-- The adapter

-- | The reference's mutable private attributes (@_installation@, @_node@,
-- @_coding@, @_core@, @_ai@, @_factory@), which its tests assign directly.
data ApplicationAdapterRuntime = ApplicationAdapterRuntime
  { installation :: Maybe RuntimeInstallation
  , node :: Maybe FilePath
  , coding :: Maybe FilePath
  , core :: Maybe FilePath
  , ai :: Maybe FilePath
  , factory :: Maybe ApplicationFactory
  , subprocessFactoryInstalled :: Bool
  -- ^ Whether 'factory' is the probe's own @_SubprocessFactory@.
  }

-- | Seams the reference's tests reach by monkeypatching.
newtype ApplicationAdapterHooks = ApplicationAdapterHooks
  { bindingCurrent :: Maybe ((PiApplicationRuntimeInvocation -> IO Bool) -> PiApplicationRuntimeInvocation -> IO Bool)
  -- ^ Wraps @_binding_current@.
  }

noApplicationHooks :: ApplicationAdapterHooks
noApplicationHooks = ApplicationAdapterHooks Nothing

data PiApplicationRuntimeAdapter = PiApplicationRuntimeAdapter
  { config :: PiApplicationRuntimeConfig
  , codec :: PiApplicationContinuationCodec
  , turns :: PiApplicationTurnOperations
  , custody :: PiApplicationConnectionCustody
  , clock :: IO Double
  , descriptor :: CapabilityDescriptor
  , territory :: DescriptorIdentity
  , runtime :: MVar ApplicationAdapterRuntime
  , operations :: MVar (Map Text PiApplicationOperation)
  , hooks :: ApplicationAdapterHooks
  }

-- | @PiApplicationRuntimeAdapter(config, codec, turns, custody, clock=...,
-- client_factory=...)@.
newPiApplicationRuntimeAdapter
  :: PiApplicationRuntimeConfig
  -> PiApplicationContinuationCodec
  -> PiApplicationTurnOperations
  -> PiApplicationConnectionCustody
  -> IO Double
  -> Maybe ApplicationFactory
  -> IO PiApplicationRuntimeAdapter
newPiApplicationRuntimeAdapter config codec turns custody clock factory =
  newPiApplicationRuntimeAdapterWith
    ApplicationAdapterOptions {clock, factory, hooks = noApplicationHooks, prepare = const id}
    config
    codec
    turns
    custody

-- | What the reference's tests assign on a built adapter (@_clock@, its
-- private hooks, @_installation@, @_node@, ...), fixed at construction.
data ApplicationAdapterOptions = ApplicationAdapterOptions
  { clock :: IO Double
  , factory :: Maybe ApplicationFactory
  , hooks :: ApplicationAdapterHooks
  , prepare :: CapabilityDescriptor -> ApplicationAdapterRuntime -> ApplicationAdapterRuntime
  -- ^ The readiness a probe would record, given the runtime descriptor.
  }

applicationAdapterOptions :: ApplicationAdapterOptions
applicationAdapterOptions =
  ApplicationAdapterOptions {clock = getMonotonicTime, factory = Nothing, hooks = noApplicationHooks, prepare = const id}

newPiApplicationRuntimeAdapterWith
  :: ApplicationAdapterOptions
  -> PiApplicationRuntimeConfig
  -> PiApplicationContinuationCodec
  -> PiApplicationTurnOperations
  -> PiApplicationConnectionCustody
  -> IO PiApplicationRuntimeAdapter
newPiApplicationRuntimeAdapterWith options config0 codec turns custody = do
  config <- newPiApplicationRuntimeConfig config0
  let descriptor = if config.profile == "gondolin" then piApplicationA5Gondolin else piApplicationA5E2b
  runtime <- newMVar (options.prepare descriptor (ApplicationAdapterRuntime Nothing Nothing Nothing Nothing Nothing options.factory False))
  operations <- newMVar Map.empty
  pure
    PiApplicationRuntimeAdapter
      { config
      , codec
      , turns
      , custody
      , clock = options.clock
      , descriptor
      , territory = descriptorIdentity KindTerritory ("motus." <> config.profile) 1
      , runtime
      , operations
      , hooks = options.hooks
      }

applicationAdapterConfig :: PiApplicationRuntimeAdapter -> PiApplicationRuntimeConfig
applicationAdapterConfig a = a.config

applicationAdapterDescriptor :: PiApplicationRuntimeAdapter -> CapabilityDescriptor
applicationAdapterDescriptor a = a.descriptor

applicationAdapterTerritory :: PiApplicationRuntimeAdapter -> DescriptorIdentity
applicationAdapterTerritory a = a.territory

applicationAdapterProgram :: PiApplicationRuntimeAdapter -> AgentProgramDescriptor
applicationAdapterProgram _ = piApplicationProgram

applicationAdapterContinuationDescriptor :: PiApplicationRuntimeAdapter -> ContinuationDescriptor
applicationAdapterContinuationDescriptor _ = piApplicationContinuationDescriptor

-- | @repr(adapter)@.
renderPiApplicationRuntimeAdapter :: PiApplicationRuntimeAdapter -> IO Text
renderPiApplicationRuntimeAdapter a = do
  let config = a.config
  ready <- isJust . (.installation) <$> readMVar a.runtime
  pure $
    "PiApplicationRuntimeAdapter(profile="
      <> pythonStrRepr config.profile
      <> ", provider="
      <> pythonStrRepr config.provider
      <> ", model="
      <> pythonStrRepr config.model
      <> ", ready="
      <> (if ready then "True" else "False")
      <> ")"

modifyApplicationAdapterRuntime :: PiApplicationRuntimeAdapter -> (ApplicationAdapterRuntime -> ApplicationAdapterRuntime) -> IO ()
modifyApplicationAdapterRuntime a f = modifyMVar_ a.runtime (pure . f)

readApplicationAdapterRuntime :: PiApplicationRuntimeAdapter -> IO ApplicationAdapterRuntime
readApplicationAdapterRuntime a = readMVar a.runtime

adapterNow :: PiApplicationRuntimeAdapter -> IO Double
adapterNow a = a.clock

-- | @probe(cli_path=..., node_path=..., package_root=...)@.
data ApplicationProbePaths = ApplicationProbePaths
  { cliPath :: Maybe FilePath
  , nodePath :: Maybe FilePath
  , packageRoot :: Maybe FilePath
  }

applicationProbePaths :: ApplicationProbePaths
applicationProbePaths = ApplicationProbePaths Nothing Nothing Nothing

-- | @probe(...)@: verify the exact pinned coding-agent, agent-core and ai
-- packages, Node 22.19 or later, and the helper's own @--probe@.
probeApplication :: PiApplicationRuntimeAdapter -> ApplicationProbePaths -> IO RuntimeProbeResult
probeApplication a paths = do
  cli <- maybe (findExecutable "pi") (pure . Just) paths.cliPath
  node <- maybe (findExecutable "node") (pure . Just) paths.nodePath
  case (cli, node) of
    (Just cli', Just node') -> do
      outcome <- try (probeInstalled a paths cli' node')
      case outcome of
        Right (installation, nodeReal, coding, core, ai, helper) -> do
          modifyApplicationAdapterRuntime a $ \r ->
            let installFactory = isNothing r.factory
             in r
                  { node = Just nodeReal
                  , coding = Just coding
                  , core = Just core
                  , ai = Just ai
                  , factory = if installFactory then Just (applicationSubprocessFactory helper) else r.factory
                  , subprocessFactoryInstalled = installFactory || r.subprocessFactoryInstalled
                  }
          record a =<< throwLeft (mkRuntimeProbeResult a.descriptor.identity ProbeReady (Just installation) [])
        Left (e :: SomeException) -> do
          rethrowAsync e
          issue <- throwLeft (mkProbeIssue "protocol-unavailable" (Just "pi-application"))
          record a =<< throwLeft (mkRuntimeProbeResult a.descriptor.identity ProbeUnavailable Nothing [issue])
    _ -> do
      issue <- throwLeft (mkProbeIssue (if isNothing cli then "client-not-installed" else "node-not-installed") (Just "pi-application"))
      record a =<< throwLeft (mkRuntimeProbeResult a.descriptor.identity ProbeNotInstalled Nothing [issue])

probeInstalled
  :: PiApplicationRuntimeAdapter
  -> ApplicationProbePaths
  -> FilePath
  -> FilePath
  -> IO (RuntimeInstallation, FilePath, FilePath, FilePath, FilePath, FilePath)
probeInstalled a paths cli node = do
  let invalid :: IO b
      invalid = throwIO (valueError "probe")
      strict path = doesPathExist path >>= \exists -> if exists then canonicalizePath path else invalid
      readJson path = B.readFile path >>= either (const invalid) pure . J.parseJson J.surrogateRefusingLoads
      field name = \case
        Object members -> fromMaybe Null (lookup name members)
        _ -> Null
      package root directory name version = do
        let candidates =
              [ root </> "node_modules" </> "@earendil-works" </> directory
              , root </> "@earendil-works" </> directory
              , root </> directory
              ]
        found <- filterM doesDirectoryExist candidates
        packageRoot <- case found of
          selected : _ -> pure selected
          [] -> invalid
        manifest <- readJson (packageRoot </> "package.json")
        when (field "name" manifest /= String name || field "version" manifest /= String version) invalid
        strict (packageRoot </> "dist/index.js")
  cliReal <- strict cli
  nodeReal <- strict node
  root <- maybe (pure (takeDirectory (takeDirectory cliReal))) strict paths.packageRoot
  expectedCli <- strict (root </> "dist/cli.js")
  when (cliReal /= expectedCli) invalid
  codingPackage <- readJson (root </> "package.json")
  when
    ( field "name" codingPackage /= String "@earendil-works/pi-coding-agent"
        || field "version" codingPackage /= String piApplicationCodingAgentVersion
    )
    invalid
  coding <- strict (root </> "dist/index.js")
  core <- package (root </> "node_modules") "pi-agent-core" "@earendil-works/pi-agent-core" piApplicationAgentCoreVersion
  ai <- package (root </> "node_modules") "pi-ai" "@earendil-works/pi-ai" piApplicationAiVersion
  when (field "bin" codingPackage `notElem` [Object [("pi", String "dist/cli.js")], String "dist/cli.js"]) invalid
  let dependencies = case field "dependencies" codingPackage of
        Null -> Object []
        value -> value
      pinned = map String ["0.83.0", "^0.83.0", "~0.83.0"]
  when
    ( field "@earendil-works/pi-agent-core" dependencies `notElem` pinned
        || field "@earendil-works/pi-ai" dependencies `notElem` pinned
    )
    invalid
  (versionCode, versionOut, _) <- runBounded [nodeReal, "--version"] Nothing >>= maybe invalid pure
  when (versionCode /= ExitSuccess) invalid
  let version = T.strip (TE.decodeUtf8With (\_ _ -> Just '\xfffd') versionOut)
  case T.splitOn "." <$> T.stripPrefix "v" version of
    Just parts@[_, _, _]
      | all (\p -> not (T.null p) && T.all isDigit p) parts
      , map (read . T.unpack) parts >= [22, 19, 0 :: Integer] ->
          pure ()
    _ -> invalid
  helper <- piApplicationHelperPath >>= strict
  catalog <-
    either (const invalid) pure $
      J.dumpsText J.defaultDumps (Array [Array [String p, String m] | (p, m) <- piApiKeyCatalog])
  (code, out, err) <-
    runBounded [nodeReal, helper, coding, core, ai, "--probe", T.unpack catalog] (Just (privateEnvironment "/dev/null" nodeReal))
      >>= maybe invalid pure
  when (code /= ExitSuccess || not (B.null err) || out /= "{\"type\":\"probe\",\"ok\":true}\n") invalid
  system <- getSystemID
  components <-
    throwLeft . sequence $
      [ mkInstalledComponent
          "pi-coding-agent"
          "0.83.0"
          ("npm:@earendil-works/pi-coding-agent@0.83.0#commit=" <> piApplicationSourceCommit)
      , mkInstalledComponent
          "pi-agent-core"
          "0.83.0"
          ("npm:@earendil-works/pi-agent-core@0.83.0#commit=" <> piApplicationSourceCommit)
      , mkInstalledComponent "pi-ai" piAiVersion piAiSource
      , mkInstalledComponent "node" (T.drop 1 version) ("executable:" <> T.pack nodeReal)
      ]
  installation <-
    throwLeft $
      mkRuntimeInstallation
        a.descriptor.identity
        1
        components
        (nonEmpty (T.toLower (T.pack (systemName system))))
        (nonEmpty (T.toLower (T.pack (machine system))))
        (Set.fromList ["runtime.cancel", "runtime.continue", "runtime.application-owned", "runtime.split"])
  pure (installation, nodeReal, coding, core, ai, helper)
  where
    nonEmpty value = if T.null value then "unknown" else value

-- | @_record@: keep the readiness that matches this probe verdict.
record :: PiApplicationRuntimeAdapter -> RuntimeProbeResult -> IO RuntimeProbeResult
record a result = do
  modifyApplicationAdapterRuntime a $ \r ->
    let installation = if result.disposition == ProbeReady then result.installation else Nothing
     in if isJust installation
          then r {installation, subprocessFactoryInstalled = r.subprocessFactoryInstalled}
          else
            r
              { installation = Nothing
              , node = Nothing
              , coding = Nothing
              , core = Nothing
              , ai = Nothing
              , factory = if r.subprocessFactoryInstalled then Nothing else r.factory
              , subprocessFactoryInstalled = False
              }
  pure result

-- | @start(invocation)@: the same handle for an identical redelivery.
startApplication :: PiApplicationRuntimeAdapter -> PiApplicationRuntimeInvocation -> IO PiApplicationOperation
startApplication a inv0 = do
  inv <- newPiApplicationRuntimeInvocation inv0
  validate a inv
  forM_ inv.continuation $ \c ->
    when (c.state /= ContinuationInUse) $ throwIO (runtimeProtocolError "continuation-not-claimed")
  prior <- traverse (applicationCodecLoad a.codec) inv.continuation
  let config = a.config
  let binding = applicationWorkingBinding config.workingDirectory
  forM_ prior $ \p ->
    when (p.workingDirectoryBinding /= binding) $ throwIO (runtimeProtocolError "continuation-project-mismatch")
  let transcript = maybe "[]" (.transcriptJson) prior
  _ <- throwLeft (applicationTranscript transcript config.maxTranscriptBytes config.maxMessages)
  coords <- Episode.coordinates inv.attachment
  grant <- currentGrant (Episode.grants inv.attachment) >>= maybe (throwAgenticus (OtherError "AssertionError") "") pure
  let methods = sort (map toolMethodText (Set.toList grant.capabilities))
      methodsRepr = case methods of
        [single] -> "(" <> pythonStrRepr single <> ",)"
        _ -> "(" <> T.intercalate ", " (map pythonStrRepr methods) <> ")"
      identity =
        "("
          <> T.intercalate
            ", "
            [ pythonStrRepr (lifecycleIdText inv.episodeId)
            , pythonStrRepr (lifecycleIdText inv.turnId)
            , pythonStrRepr (sha256Hex (TE.encodeUtf8 inv.observation))
            , pythonStrRepr (sha256Hex transcript)
            , pythonStrRepr inv.connection.identity.connectionId
            , pythonStrRepr inv.connection.identity.provider
            , pythonStrRepr inv.connection.identity.profile
            , T.pack (show inv.connection.authorityEpoch)
            , T.pack (show inv.connection.stateVersion)
            , pythonStrRepr coords.attachmentId
            , T.pack (show coords.attachmentEpoch)
            , T.pack (show inv.grantEpoch)
            , methodsRepr
            , pythonStrRepr config.profile
            , pythonStrRepr config.provider
            , pythonStrRepr config.model
            , pythonStrRepr binding
            ]
          <> ")"
      key = sha256Hex (TE.encodeUtf8 identity)
  mask_ $ do
    registered <- modifyMVar a.operations $ \known -> do
      r <- readMVar a.runtime
      factory <- case (r.installation, r.factory, r.node, r.coding, r.core, r.ai) of
        (Just _, Just factory, Just _, Just _, Just _, Just _) -> pure factory
        _ -> throwIO (runtimeProtocolError "runtime-not-ready")
      case Map.lookup inv.operationId known of
        Just old
          | old.key /= key -> throwIO (runtimeProtocolError "operation-conflict")
          | otherwise -> pure (known, Left old)
        Nothing -> do
          operation <- newOperation a inv key prior factory
          pure (Map.insert inv.operationId operation known, Right operation)
    case registered of
      Left old -> pure old
      Right operation -> do
        spawned <- try (Lifecycle.startWorker operation.lifecycle (runOperation operation))
        case spawned of
          Right () -> pure operation
          Left (e :: SomeException) -> do
            modifyMVar_ a.operations $ \known ->
              pure (if Map.lookup inv.operationId known == Just operation then Map.delete inv.operationId known else known)
            throwIO e

newOperation
  :: PiApplicationRuntimeAdapter
  -> PiApplicationRuntimeInvocation
  -> Text
  -> Maybe PiApplicationContinuationPayloadV1
  -> ApplicationFactory
  -> IO PiApplicationOperation
newOperation adapter inv key prior factory = do
  lifecycle <- newLifecycle (LifecycleTexts "Pi application wait timeout must be positive and finite" "Pi application operation has not settled") inv.operationId
  pure PiApplicationOperation {adapter, inv, key, prior, factory, lifecycle}

validate :: PiApplicationRuntimeAdapter -> PiApplicationRuntimeInvocation -> IO ()
validate a inv = do
  let config = a.config
  when (inv.connection.identity.provider /= config.provider) $ throwIO (runtimeProtocolError "connection-provider-mismatch")
  when (inv.connection.identity.profile /= "api-key") $ throwIO (runtimeProtocolError "connection-profile-mismatch")
  let expected =
        [ (KindRuntime, a.descriptor.identity)
        , (KindConnection, connectionId')
        , (KindProgram, programId)
        , (KindHands, handsId)
        , (KindTerritory, a.territory)
        , (KindContinuation, continuationId)
        ]
      snapshot = Episode.episodeSnapshot inv.attachment
  when (any (\(k, v) -> fmap (.identity) (snapshotDescriptor k snapshot) /= Just v) expected) $
    throwIO (runtimeProtocolError "resolution-mismatch")
  case snapshotDescriptor KindEffect snapshot of
    Just effect | "effect.host-fenced" `Set.member` effect.offers -> pure ()
    _ -> throwIO (runtimeProtocolError "resolution-mismatch")
  grant <- currentGrant (Episode.grants inv.attachment)
  case grant of
    Just g | g.grantEpoch == inv.grantEpoch -> pure ()
    _ -> throwIO (runtimeProtocolError "grant-mismatch")
  current <- applicationBindingCurrent a inv
  unless current $ throwIO (runtimeProtocolError "runtime-territory-lease-required")

-- | @_binding_current@ (through the test hook, when one is installed).
applicationBindingCurrent :: PiApplicationRuntimeAdapter -> PiApplicationRuntimeInvocation -> IO Bool
applicationBindingCurrent a inv = do
  let hooks = a.hooks
  maybe id id hooks.bindingCurrent (bindingCurrent a) inv

bindingCurrent :: PiApplicationRuntimeAdapter -> PiApplicationRuntimeInvocation -> IO Bool
bindingCurrent a inv = do
  let config = a.config
  case (Episode.episodeBinding inv.attachment).motus of
    Nothing -> pure False
    Just binding -> do
      execution <- bindingExecution binding
      let lease = attachmentLease execution
      if leaseState lease /= Ready || leaseProvider lease /= config.profile
        then pure False
        else do
          observed <- try $ do
            provider <- bindingProvider binding
            providerLookup provider (identityOperationId (bindingLeaseIdentity binding))
          case observed of
            Left (e :: SomeException) -> rethrowAsync e >> pure False
            Right Nothing -> pure False
            Right (Just found) ->
              pure
                ( leaseIdentity found == bindingLeaseIdentity binding
                    && leaseState found == Ready
                    && leaseProvider found == config.profile
                )

settle :: PiApplicationRuntimeInvocation -> TurnOutcome -> Integer -> Text -> Maybe Text -> Maybe Text -> IO RuntimeTurnSettlement
settle inv outcome appends code output continuation =
  throwLeft (mkRuntimeTurnSettlement inv.episodeId inv.turnId outcome appends code output continuation)

data Exec = Exec
  { materialization :: Maybe HostMaterialization
  , client :: Maybe ApplicationClient
  , root :: Maybe (FilePath, Maybe (Integer, Integer))
  , attempted :: Bool
  , clean :: Bool
  , outcome :: TurnOutcome
  , code :: Text
  , outputRef :: Maybe Text
  , continuationRef :: Maybe Text
  }

-- | @_execute@: authority, helper, claim, admission and publication, with
-- cleanup and release precedence kept explicit.
executeOperation :: PiApplicationRuntimeAdapter -> PiApplicationOperation -> IO (RuntimeTurnSettlement, RuntimeCleanupDisposition)
executeOperation a operation = do
  let config = a.config
  r <- readMVar a.runtime
  let inv = operation.inv
      ids name = inv.operationId <> "." <> name
  now0 <- adapterNow a
  monotonic0 <- getMonotonicTime
  let deadline = monotonic0 + min config.wallTimeout (max 0 (Episode.episodeDeadline inv.attachment - now0))
  state <- newIORef (Exec Nothing Nothing Nothing False True TurnFailed "runtime-failed" Nothing Nothing)
  let set f = modifyIORef' state f
      body = do
        live <- operationCurrent operation
        unless live $ protocol "cancelled"
        monotonic <- getMonotonicTime
        now <- adapterNow a
        when (deadline <= monotonic || now >= Episode.episodeDeadline inv.attachment) $ protocol "deadline-exceeded"
        set (\s -> s {attempted = True})
        ttlNow <- getMonotonicTime
        materialization <-
          a.custody.materialize
            inv.connection.identity.connectionId
            config.hostId
            LeaseRead
            (min config.credentialTtl (max 0.001 (deadline - ttlNow)))
            (ids "materialize")
        set (\s -> s {materialization = Just materialization})
        when (materialization.mode /= LeaseRead) $ protocol "custody-materialization-mismatch"
        let fence = materialization.fence
        when
          ( (fence.connectionId, fence.hostId, fence.authorityEpoch, fence.baseVersion)
              /= (inv.connection.identity.connectionId, config.hostId, inv.connection.authorityEpoch, inv.connection.stateVersion)
          )
          $ protocol "custody-state-mismatch"
        credential <- materialization.home.read
        when (B.null credential || B.length credential > maxKey) $ protocol "credential-invalid"
        apiKey <- case TE.decodeUtf8' credential of
          Right value | Right _ <- piText "Pi application credential" maxKey value -> pure value
          _ -> protocol "credential-invalid"
        rootPath <- createTempDirectory config.runtimeRoot "operation-"
        set (\s -> s {root = Just (rootPath, Nothing)})
        Files.setFileMode rootPath 0o700
        metadata <- Files.getSymbolicLinkStatus rootPath
        uid <- getEffectiveUserID
        when (not (Files.isDirectory metadata) || Files.fileMode metadata .&. 0o7777 /= 0o700 || Files.fileOwner metadata /= uid) $
          protocol "private-root-invalid"
        let identity = (toInteger (Files.deviceID metadata), toInteger (Files.fileID metadata))
        set (\s -> s {root = Just (rootPath, Just identity)})
        let required = maybe (throwIO (valueError "Pi application runtime is not ready")) pure
        node <- required r.node
        coding <- required r.coding
        core <- required r.core
        ai <- required r.ai
        client <-
          operation.factory.create
            ApplicationClientArgs
              { node
              , codingEntrypoint = coding
              , coreEntrypoint = core
              , aiEntrypoint = ai
              , privateRoot = rootPath
              , config
              , invocation = inv
              , prior = operation.prior
              , apiKey
              }
        set (\s -> s {client = Just client})
        candidate <- client.run inv.gateway inv (operationCurrent operation) deadline
        closedClean <- client.close
        set (\s -> s {client = Nothing, clean = closedClean && s.clean})
        removed <- removeRoot rootPath (Just identity)
        set (\s -> s {root = Nothing, clean = removed && s.clean})
        clean <- (.clean) <$> readIORef state
        unless clean $ protocol "private-cleanup-uncertain"
        claim operation >>= maybe (pure ()) protocol
        admission <- a.custody.admitResult fence (ids "admit")
        when (admission.operationId /= ids "admit" || admission.purpose /= "result" || admission.attachmentId /= fence.attachmentId) $
          protocol "custody-admission-mismatch"
        step <- throwLeft (mkPiApplicationStepPayloadV1 config.profile candidate.results candidate.text)
        output <- a.turns.storeTurn inv.operationId step >>= throwLeft . piText "Pi application output reference" 512
        set (\s -> s {outputRef = Just output})
        payload <- throwLeft (mkPiApplicationContinuationPayloadV1 (applicationWorkingBinding config.workingDirectory) candidate.transcript)
        continuationRef <- applicationCodecStore a.codec inv.operationId payload
        set (\s -> s {continuationRef = Just continuationRef, outcome = TurnCompleted, code = "turn-completed"})
  outcome <- try body
  case outcome of
    Right () -> pure ()
    Left (e :: SomeException)
      | isAsync e -> throwIO e
      | Just failure <- fromException e, Just code <- runtimeProtocolErrorCode failure -> do
          live <- operationCurrent operation
          let cancelled = not live || code == "cancelled"
          set (\s -> s {code = if cancelled then "cancelled" else code, outcome = if cancelled then TurnCancelled else TurnFailed})
      | otherwise -> do
          live <- operationCurrent operation
          set (\s -> s {code = if live then "runtime-failed" else "cancelled", outcome = if live then TurnFailed else TurnCancelled})
  -- finally
  s <- readIORef state
  forM_ s.client $ \client -> do
    -- As in the reference, a raising close escapes the remaining cleanup.
    closedClean <- client.close
    set (\x -> x {clean = closedClean && x.clean})
  forM_ s.root $ \(path, identity) -> do
    removed <- removeRoot path identity
    set (\x -> x {clean = removed && x.clean})
  forM_ s.materialization $ \materialization -> do
    verified <-
      (releaseVerified <$> a.custody.release materialization (ids "release") <*> pure (ids "release") <*> pure materialization.fence.attachmentId)
        `catch` \(e :: SomeException) -> rethrowAsync e >> pure False
    set (\x -> x {clean = verified && x.clean})
  final <- readIORef state
  if not final.clean
    then (,RuntimeCleanupUnverified) <$> settle inv TurnFailed 0 "cleanup-unverified" Nothing Nothing
    else do
      let completed = final.outcome == TurnCompleted
      settlement <-
        settle
          inv
          final.outcome
          (if completed then 1 else 0)
          final.code
          (if completed then final.outputRef else Nothing)
          (if completed then final.continuationRef else Nothing)
      pure (settlement, if final.attempted then RuntimeCleanupClean else RuntimeCleanupNotCreated)

releaseVerified :: ReleaseResult -> Text -> Text -> Bool
releaseVerified value operationId attachmentId =
  value.operationId == operationId
    && value.cleanup.attachmentId == attachmentId
    && (value.cleanup.removed || value.cleanup.alreadyAbsent)
    && not value.cleanup.securityViolation
