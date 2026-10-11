{-# LANGUAGE RecordWildCards #-}

-- | The exact Amp A1 provider-managed runtime lane
-- (@petrus.agenticus.runtime.amp@).
--
-- Amp owns its agent loop, thread service, tools and Orb placement.
-- Agenticus owns only the Episode/Turn lifecycle candidate, the logical
-- connection fence, the provider-managed attachment, and opaque
-- Continuation and output custody references.
--
-- Upstream's @sdk_execute@ is an async iterator of SDK events; here it is
-- an 'AmpExecute' returning an 'AmpEventStream' of pulls plus the two
-- finalizers upstream calls (@athrow(CancelledError())@ and @aclose()@).
-- The official execute ('officialExecute') hosts the Python SDK in the
-- @amp_sidecar.py@ data file; the probe's monkeypatch points are the
-- fields of 'AmpProbeHooks'.
module Petrus.Agenticus.Runtime.Amp
  ( -- * Pins
    ampSdkVersion
  , ampCliVersion
  , ampSdkSource
  , ampCliSource
    -- * Descriptors
  , ampContinuationDescriptor
  , ampProgram
  , ampProgramCapabilities
  , ampContinuationCapabilities
  , ampConnectionCapabilities
  , ampProviderManagedHands
  , ampProviderManagedTerritory
    -- * Continuations
  , AmpContinuationPayloadV1
  , payloadThreadId
  , payloadSchemaVersion
  , mkAmpContinuationPayloadV1
  , ampPayloadToData
  , ampPayloadFromData
  , AmpContinuationOperations (..)
  , AmpTurnOperations (..)
  , AmpContinuationCodec
  , ampContinuationCodec
  , ampCodecStore
  , ampCodecLoad
    -- * Configuration and invocations
  , AmpRuntimeConfig (..)
  , ampRuntimeConfig
  , newAmpRuntimeConfig
  , AmpRuntimeInvocation (..)
  , newAmpRuntimeInvocation
  , renderAmpRuntimeInvocation
    -- * SDK streams
  , AmpEvent (..)
  , AmpRaise (..)
  , jsonEvent
  , AmpEventStream (..)
  , AmpExecute
  , AmpSidecar (..)
  , SidecarPool
  , newSidecarPool
  , closeSidecarPool
  , withSidecarPool
  , defaultSidecarPool
  , sidecarPoolPids
  , ampSidecar
  , ampSidecarPath
  , officialExecute
    -- * The provider-managed binding
  , AmpProviderManagedBinding
  , newAmpProviderManagedBinding
  , ampAttachmentBinding
  , ampBindingKind
    -- * Operations
  , AmpOperation
  , ampOperationId
  , ampRuntimeOperation
  , waitAmpOperation
  , cancelAmpOperation
  , closeAmpOperation
    -- * The adapter
  , AmpProbeHooks (..)
  , officialProbeHooks
  , resolveAmpCli
  , AmpAdapterOptions (..)
  , ampAdapterOptions
  , AmpRuntimeAdapter
  , newAmpRuntimeAdapter
  , renderAmpRuntimeAdapter
  , probeAmp
  , startAmp
    -- * Pure protocol pieces (exposed for the differential corpus)
  , ampBoundedText
  , ampThreadId
  , safeFinalText
  , executionOptions
  , AmpCandidate (..)
  , admitEvents
  ) where

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, threadDelay, throwTo)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception
  ( Exception
  , IOException
  , SomeException
  , catch
  , finally
  , fromException
  , mask_
  , onException
  , throwIO
  , try
  )
import Control.Monad (forM_, unless, void, when)
import Data.ByteString qualified as B
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, ord)
import Data.IORef
import Data.List (isSuffixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Unique (Unique, newUnique)
import GHC.Clock (getMonotonicTime)
import Paths_petrus_agenticus_runtime (getDataFileName)
import Petrus.Agenticus.Attachment.Binding (AttachmentBinding (..), AttachmentCoordinates (..), BindingSettlement, mkBindingSettlement)
import Petrus.Agenticus.Attachment.Episode (EpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor
  ( CapabilityDescriptor (..)
  , DescriptorIdentity (..)
  , DescriptorKind (..)
  , capabilityDescriptor
  , descriptorIdentity
  )
import Petrus.Agenticus.Catalog.Resolution (snapshotDescriptor)
import Petrus.Agenticus.Connection.Custody (ConnectionIdentity (..), ConnectionStatus (..), ConnectionView (..))
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Exception
import Petrus.Agenticus.Internal.PyRepr (pyStrRepr)
import Petrus.Agenticus.Internal.Validate (isBoundedText, sha256Hex, utf8Length)
import Petrus.Agenticus.Program.Descriptor
  ( AgentProgramDescriptor
  , ProgramOwnership (..)
  , agentProgramDescriptor
  , continuationRequirement
  )
import Petrus.Agenticus.Runtime.HostSupport
import Petrus.Agenticus.Runtime.Installation
  ( ProbeDisposition (..)
  , RuntimeInstallation
  , RuntimeProbeResult (..)
  , mkInstalledComponent
  , mkProbeIssue
  , mkRuntimeInstallation
  , mkRuntimeProbeResult
  )
import Petrus.Agenticus.Runtime.Internal.Lifecycle (Lifecycle, LifecycleTexts (..), newLifecycle)
import Petrus.Agenticus.Runtime.Internal.Lifecycle qualified as Lifecycle
import Petrus.Agenticus.Runtime.Internal.Process (runBounded, micros)
import Petrus.Agenticus.Runtime.Operation
  ( RuntimeCleanupDisposition (..)
  , RuntimeOperation (..)
  , RuntimeOperationCleanup
  , cleanupVerified
  , runtimeProtocolError
  , runtimeProtocolErrorCode
  )
import Petrus.Agenticus.Runtime.Profiles (ampA1)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement, mkRuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Continuation (Continuation (..), ContinuationDescriptor, continuationDescriptor)
import Petrus.Agenticus.Thread.Identity (EpisodeId, LifecycleId (..), TurnId)
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Directory (doesFileExist, executable, findExecutable, getHomeDirectory, getPermissions)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Pins

ampSdkVersion, ampCliVersion, ampSdkSource, ampCliSource :: Text
ampSdkVersion = "0.1.20260729121202"
ampCliVersion = "0.0.1785733786-gde6a10"
ampSdkSource = "pypi:amp-sdk==0.1.20260729121202#sha256=83d0f4805ddfa836c690419a88f4fd35f1505e03dd772e0831d802db42ca33d7"
ampCliSource =
  "npm:@ampcode/cli@0.0.1785733786-gde6a10#sha512="
    <> "oqErM5EQmPmQ2yzoRk/vbWRvvkcRMDV8IjJniLFCFldTlDzq8KDHq43XBo3ktDqy6bV09aWrkwIo4zs1DrRGrA=="

-- ---------------------------------------------------------------------------
-- Descriptors

programId, continuationId, connectionId', handsId, territoryId :: DescriptorIdentity
programId = descriptorIdentity KindProgram "amp.provider-managed" 1
continuationId = descriptorIdentity KindContinuation "amp.native" 1
connectionId' = descriptorIdentity KindConnection "amp.platform-managed" 1
handsId = descriptorIdentity KindHands "amp.provider-managed" 1
territoryId = descriptorIdentity KindTerritory "amp.provider-managed" 1

ampContinuationDescriptor :: ContinuationDescriptor
ampContinuationDescriptor = continuationDescriptor continuationId programId

ampProgram :: AgentProgramDescriptor
ampProgram =
  agentProgramDescriptor
    programId
    ProviderOwned
    True
    [continuationRequirement continuationId programId]
    (Just continuationId)
    False
    False

ampProgramCapabilities
  , ampContinuationCapabilities
  , ampConnectionCapabilities
  , ampProviderManagedHands
  , ampProviderManagedTerritory
    :: CapabilityDescriptor
ampProgramCapabilities = capabilityDescriptor programId ["program.provider-owned"] []
ampContinuationCapabilities = capabilityDescriptor continuationId ["continuation.amp-native"] []
ampConnectionCapabilities = capabilityDescriptor connectionId' ["connection.amp"] []
ampProviderManagedHands = capabilityDescriptor handsId ["hands.provider-managed"] []
ampProviderManagedTerritory = capabilityDescriptor territoryId [] []

-- ---------------------------------------------------------------------------
-- Validation

maxOperationId, maxProject, maxPrompt, maxReference :: Int
maxOperationId = 256
maxProject = 512
maxPrompt = 64 * 1024
maxReference = 512

-- | @_bounded_text(value, name, maximum)@.
ampBoundedText :: Text -> Int -> Text -> Either AgenticusError Text
ampBoundedText name maximum' value
  | isBoundedText maximum' value = Right value
  | otherwise = Left (valueError (name <> " must be bounded non-empty text"))

operationIdText :: Text -> Either AgenticusError Text
operationIdText = ampBoundedText "Amp operation identity" maxOperationId

-- | @_thread_id(value)@: @T-[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+@.
ampThreadId :: Text -> Either AgenticusError Text
ampThreadId value = do
  _ <- ampBoundedText "Amp thread identity" 128 value
  case T.stripPrefix "T-" value of
    Just rest
      | parts@(_ : _ : _) <- T.splitOn "-" rest
      , all (\p -> not (T.null p) && T.all alnum p) parts ->
          Right value
    _ -> Left (valueError "Amp thread identity must be a T-prefixed provider thread ID")
  where
    alnum c = isAsciiLower c || isAsciiUpper c || isDigit c

opaqueReference :: Text -> Text -> Either AgenticusError Text
opaqueReference name = ampBoundedText name maxReference

positiveNumber :: Text -> Double -> Either AgenticusError Double
positiveNumber name value
  | isNaN value || isInfinite value || value <= 0 = Left (valueError (name <> " must be a positive finite number"))
  | otherwise = Right value

-- | @_safe_final_text(value, maximum)@ for a string value.
safeFinalText :: Int -> Text -> Either Text Text
safeFinalText maximum' value
  | utf8Length sanitized > maximum' = Left "output-overflow"
  | otherwise = Right sanitized
  where
    sanitized = T.map safe (stripAnsi value)
    safe c
      | c `elem` ("\n\r\t" :: String) || (ord c >= 32 && ord c /= 127) = c
      | otherwise = '\xfffd'

-- ---------------------------------------------------------------------------
-- Continuations

-- | The provider thread identity behind one Amp-native Continuation.
newtype AmpContinuationPayloadV1 = AmpContinuationPayloadV1 Text
  deriving stock (Eq, Ord)

-- | The thread identity is opaque provider state: 'Show' names the type
-- only, as a Continuation never renders its reference.
instance Show AmpContinuationPayloadV1 where
  show (AmpContinuationPayloadV1 t) = "AmpContinuationPayloadV1(thread_id=" <> T.unpack (pyStrRepr t) <> ", schema_version=1)"

payloadThreadId :: AmpContinuationPayloadV1 -> Text
payloadThreadId (AmpContinuationPayloadV1 t) = t

payloadSchemaVersion :: AmpContinuationPayloadV1 -> Integer
payloadSchemaVersion _ = 1

mkAmpContinuationPayloadV1 :: Text -> Either AgenticusError AmpContinuationPayloadV1
mkAmpContinuationPayloadV1 t = AmpContinuationPayloadV1 <$> ampThreadId t

-- | @to_data()@.
ampPayloadToData :: AmpContinuationPayloadV1 -> Json
ampPayloadToData (AmpContinuationPayloadV1 t) = Object [("schema_version", Int 1), ("thread_id", String t)]

-- | @AmpContinuationPayloadV1.from_data(data)@.
ampPayloadFromData :: Json -> Either AgenticusError AmpContinuationPayloadV1
ampPayloadFromData = \case
  Object members
    | Set.fromList (map fst members) == Set.fromList ["schema_version", "thread_id"] -> do
        -- The last spelling of a duplicated key wins, as in a dict.
        let field name = fromMaybe Null (lookup name (reverse members))
        case field "schema_version" of
          Int 1 -> pure ()
          _ -> Left (valueError "Amp Continuation schema_version must be integer 1")
        case field "thread_id" of
          String t -> mkAmpContinuationPayloadV1 t
          _ -> Left (valueError "Amp thread identity must be bounded non-empty text")
  _ -> Left (valueError "Amp Continuation payload requires exact versioned fields")

-- | Installation-owned immutable custody for Amp Continuation payloads.
data AmpContinuationOperations = AmpContinuationOperations
  { store :: Text -> AmpContinuationPayloadV1 -> IO Text
  , load :: Text -> IO AmpContinuationPayloadV1
  }

-- | Immutable custody for one complete accepted Amp runtime Turn batch.
newtype AmpTurnOperations = AmpTurnOperations
  { storeTurn :: Text -> Text -> Text -> IO Text
  }

-- | Resolve only exact Amp-native references through their owning custody.
newtype AmpContinuationCodec = AmpContinuationCodec AmpContinuationOperations

ampContinuationCodec :: AmpContinuationOperations -> AmpContinuationCodec
ampContinuationCodec = AmpContinuationCodec

ampCodecStore :: AmpContinuationCodec -> Text -> AmpContinuationPayloadV1 -> IO Text
ampCodecStore (AmpContinuationCodec operations) operationId payload = do
  operation <- throwLeft (operationIdText operationId)
  reference <- operations.store operation payload
  throwLeft (opaqueReference "Amp Continuation state reference" reference)

ampCodecLoad :: AmpContinuationCodec -> Continuation -> IO AmpContinuationPayloadV1
ampCodecLoad (AmpContinuationCodec operations) continuation = do
  when (continuation.descriptor /= ampContinuationDescriptor) $
    throwAgenticus ValueError "Amp Continuation descriptor does not match the Amp runtime"
  operations.load continuation.stateReference

-- ---------------------------------------------------------------------------
-- Configuration and invocations

-- | One exact qualified A1 installation and provider execution policy.
data AmpRuntimeConfig = AmpRuntimeConfig
  { project :: Text
  , mode :: Text
  , visibility :: Text
  , noArchiveAfterExecute :: Bool
  , sdkVersion :: Text
  , cliVersion :: Text
  , maxEvents :: Int
  , maxEventBytes :: Int
  , maxTotalEventBytes :: Int
  , maxFinalTextBytes :: Int
  , cancellationGrace :: Double
  }
  deriving stock (Eq, Show)

-- | @AmpRuntimeConfig(project)@ with every default, unvalidated.
ampRuntimeConfig :: Text -> AmpRuntimeConfig
ampRuntimeConfig project =
  AmpRuntimeConfig
    { project
    , mode = "medium"
    , visibility = "private"
    , noArchiveAfterExecute = False
    , sdkVersion = ampSdkVersion
    , cliVersion = ampCliVersion
    , maxEvents = 10000
    , maxEventBytes = 1000000
    , maxTotalEventBytes = 4000000
    , maxFinalTextBytes = 1000000
    , cancellationGrace = 10
    }

-- | @AmpRuntimeConfig.__post_init__@.
newAmpRuntimeConfig :: AmpRuntimeConfig -> Either AgenticusError AmpRuntimeConfig
newAmpRuntimeConfig c = do
  _ <- ampBoundedText "Amp project" maxProject c.project
  unless (c.mode `elem` ["low", "medium", "high", "ultra"]) $
    Left (valueError "Amp A1 mode must be one exact built-in mode")
  unless (c.visibility `elem` ["private", "unlisted", "workspace", "group"]) $
    Left (valueError "Amp A1 visibility is not supported")
  when (c.sdkVersion /= ampSdkVersion || c.cliVersion /= ampCliVersion) $
    Left (valueError "Amp A1 requires the exact qualified SDK and CLI pair")
  forM_
    [ (c.maxEvents, "max_events")
    , (c.maxEventBytes, "max_event_bytes")
    , (c.maxTotalEventBytes, "max_total_event_bytes")
    , (c.maxFinalTextBytes, "max_final_text_bytes")
    ]
    $ \(value, name) -> when (value <= 0) $ Left (valueError ("Amp " <> name <> " must be a positive integer"))
  _ <- positiveNumber "Amp cancellation grace" c.cancellationGrace
  pure c

-- | One provider-managed Amp Turn request with no model-provider authority.
--
-- The invocation also carries the 'AmpProviderManagedBinding' its
-- attachment was built over (see @divergences/amp.md@).
data AmpRuntimeInvocation = AmpRuntimeInvocation
  { operationId :: Text
  , episodeId :: EpisodeId
  , turnId :: TurnId
  , prompt :: Text
  , connection :: ConnectionView
  , attachment :: EpisodeAttachment
  , binding :: AmpProviderManagedBinding
  , continuation :: Maybe Continuation
  }

-- | The dataclass @repr@: the prompt, attachment and continuation are
-- hidden.
renderAmpRuntimeInvocation :: AmpRuntimeInvocation -> Text
renderAmpRuntimeInvocation i =
  "AmpRuntimeInvocation(operation_id="
    <> pyStrRepr i.operationId
    <> ", episode_id=EpisodeId(value="
    <> pyStrRepr (lifecycleIdText i.episodeId)
    <> "), turn_id=TurnId(value="
    <> pyStrRepr (lifecycleIdText i.turnId)
    <> "), connection="
    <> T.pack (show i.connection)
    <> ")"

-- | @AmpRuntimeInvocation.__post_init__@.
newAmpRuntimeInvocation
  :: Text
  -> EpisodeId
  -> TurnId
  -> Text
  -> ConnectionView
  -> EpisodeAttachment
  -> AmpProviderManagedBinding
  -> Maybe Continuation
  -> Either AgenticusError AmpRuntimeInvocation
newAmpRuntimeInvocation operationId episodeId turnId prompt connection attachment binding continuation = do
  _ <- operationIdText operationId
  when (T.null prompt || utf8Length prompt > maxPrompt) $
    Left (valueError "Amp prompt must be bounded non-empty text")
  when (connection.status /= StatusReady) $
    Left (valueError "Amp platform-managed connection must be ready")
  when (connection.identity.provider /= "amp" || connection.identity.profile /= "platform-managed") $
    Left (valueError "Amp invocation requires the platform-managed Amp connection profile")
  when (Episode.episodeId attachment /= episodeId) $
    Left (valueError "Amp invocation Episode and attachment must match")
  pure AmpRuntimeInvocation {..}

-- ---------------------------------------------------------------------------
-- SDK streams

-- | An exception raised while upstream's adapter reads an event (computing
-- @_event_size@ or reading one @_event_value@ attribute), by how @_run@
-- settles it: a @TimeoutError@ is @deadline-exceeded@, a @CancelledError@
-- is a cancelled Turn, anything else is @client-failed@.
data AmpRaise = AmpRaiseFailed | AmpRaiseTimeout | AmpRaiseCancelled
  deriving stock (Eq, Show)

instance Exception AmpRaise

-- | One SDK event as upstream's adapter sees it: the attributes it reads
-- (@_event_value@) and its encoded size (@_event_size@; 'Nothing' when the
-- event cannot be measured, @malformed-event@). Either can be an exception
-- the read raises, which upstream sees only when it gets that far.
data AmpEvent = AmpEvent
  { values :: [(Text, Either AmpRaise Json)]
  , encodedSize :: Either AmpRaise (Maybe Int)
  }
  deriving stock (Show)

-- | An event whose @model_dump_json()@ is
-- @json.dumps(values, separators=(",", ":"))@, like the reference's test
-- @Event@.
jsonEvent :: [(Text, Json)] -> AmpEvent
jsonEvent members =
  AmpEvent
    [(name, Right value) | (name, value) <- members]
    (Right (either (const Nothing) (Just . B.length) (J.dumps J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"} (Object members))))

-- | Why admission stopped: a protocol code or a raised exception.
data AmpStop = AmpProtocol Text | AmpRaised AmpRaise

eventValue :: AmpEvent -> Text -> Either AmpStop Json
eventValue event name = case lookup name event.values of
  Nothing -> Right Null
  Just (Right value) -> Right value
  Just (Left raised) -> Left (AmpRaised raised)

-- | One started SDK stream: pull the next event ('Nothing' at the end),
-- inject a cancellation (@athrow(asyncio.CancelledError())@), and close it
-- (@aclose()@).
data AmpEventStream = AmpEventStream
  { next :: IO (Maybe AmpEvent)
  , abort :: IO ()
  , close :: IO ()
  }

-- | @sdk_execute(prompt, options)@.
type AmpExecute = Text -> [(Text, Json)] -> IO AmpEventStream

-- | Where the Python SDK sidecar runs: the interpreter, extra @sys.path@
-- entries searched first, and how long a cancelled stream may take to
-- finalize.
data AmpSidecar = AmpSidecar
  { python :: FilePath
  , searchPath :: [FilePath]
  , grace :: Double
  , pool :: SidecarPool
  -- ^ The pool whose shared sidecar hosts the streams.
  }

-- | @python3@ from @PATH@, the interpreter's own @sys.path@, over the
-- 'defaultSidecarPool'.
ampSidecar :: AmpSidecar
ampSidecar = AmpSidecar "python3" [] 10 defaultSidecarPool

ampSidecarPath :: IO FilePath
ampSidecarPath = getDataFileName "data/amp_sidecar.py"

sidecarCommand :: AmpSidecar -> String -> IO HelperSpec
sidecarCommand s mode = do
  script <- ampSidecarPath
  pure (HelperSpec s.python (["-I", "-B", script, mode] <> s.searchPath) Nothing Nothing)

data SidecarFailure = SidecarFailure Text
  deriving stock (Show)

instance Exception SidecarFailure

-- | @_official_execute@: @execute(prompt, AmpOptions(**options))@ on a
-- channel of the shared sidecar. The first pull is requested together with
-- the stream, as upstream starts iterating right after @execute@ returns.
officialExecute :: AmpSidecar -> AmpExecute
officialExecute s prompt options = do
  command <- sidecarCommand s "serve"
  c <- openSidecarChannel s.pool command >>= maybe (throwIO (SidecarFailure "launch")) pure
  let request = Object [("prompt", String prompt), ("options", Object options)]
      failStart = void (channelClose c s.grace) >> throwIO (SidecarFailure "start")
  sent <- channelSend c request
  requested <- if sent then channelSend c (String "next") else pure False
  channelReceive c >>= \case
    Just (Object [("started", Bool True)]) -> pure ()
    _ -> failStart
  prefetched <- newIORef requested
  aborted <- newIORef False
  -- Set when the sidecar reports the SDK generator closed: its finalizers
  -- run no SDK code, and the sidecar has already ended the channel.
  finished <- newIORef False
  let pull = do
        ahead <- atomicModifyIORef' prefetched (False,)
        unless ahead (void (channelSend c (String "next")))
        frame <- channelReceive c
        case frame of
          Just (Object members) | lookup "finished" members == Just (Bool True) -> writeIORef finished True
          _ -> pure ()
        case frame of
          Just (Object [("event", Object fields)])
            | Just (Object members) <- lookup "values" fields ->
                pure . Just $ AmpEvent (map (fmap value) members) (maybe (Right Nothing) size (lookup "size" fields))
          Just (Object members)
            | Just (Bool True) <- lookup "end" members -> pure Nothing
            | Just (String "timeout") <- lookup "error" members -> throwIO AmpRaiseTimeout
            | Just (String "cancelled") <- lookup "error" members -> throwIO AmpRaiseCancelled
          _ -> throwIO (SidecarFailure "stream")
      size = \case
        Int n | n >= 0 -> Right (Just (fromInteger n))
        Object [("raised", String kind)] -> Left (raise kind)
        _ -> Right Nothing
      -- A value the sidecar cannot represent arrives as
      -- @{"opaque": type, "hashable": bool}@, which equals no string or
      -- boolean the admission compares against.
      value = \case
        Object [("raised", String kind)] -> Left (raise kind)
        other -> Right other
      raise = \case
        "timeout" -> AmpRaiseTimeout
        "cancelled" -> AmpRaiseCancelled
        _ -> AmpRaiseFailed
      cancelStream = do
        first <- atomicModifyIORef' aborted (True,)
        done <- readIORef finished
        unless (first || done) $ do
          _ <- channelSend c (String "abort")
          void (timeout (micros s.grace) (awaitFrame "aborted"))
      awaitFrame name =
        channelReceive c >>= \case
          Nothing -> pure ()
          Just (Object [(key, Bool True)]) | key == name -> pure ()
          Just _ -> awaitFrame name
      closeStream = do
        done <- readIORef finished
        unless done $ do
          _ <- channelSend c (String "close")
          void (timeout (micros s.grace) (awaitFrame "closed"))
        void (channelAwaitEnd c s.grace)
  pure AmpEventStream {next = pull, abort = cancelStream, close = closeStream}

-- ---------------------------------------------------------------------------
-- Stream admission

-- | One admitted terminal (@_Candidate@).
data AmpCandidate = AmpCandidate
  { outcome :: TurnOutcome
  , acceptedAppends :: Integer
  , terminationCode :: Text
  , threadId :: Maybe Text
  , finalText :: Maybe Text
  , providerTerminal :: Bool
  }
  deriving stock (Eq, Show)

data Admission = Admission
  { count :: Int
  , total :: Int
  , thread :: Maybe Text
  , terminal :: Maybe AmpCandidate
  }

-- | @_read_stream@'s per-event step: the next state, or why it stopped.
-- Attributes are read in upstream's order, so an attribute that raises
-- matters only where upstream reads it.
admitStep :: AmpRuntimeConfig -> Maybe Text -> Admission -> AmpEvent -> Either AmpStop Admission
admitStep config continuationThread state event = do
  let count' = state.count + 1
  when (count' > config.maxEvents) $ protocol "event-count-overflow"
  size <- either (Left . AmpRaised) (maybe (protocol "malformed-event") Right) event.encodedSize
  when (size > config.maxEventBytes) $ protocol "event-overflow"
  let total' = state.total + size
  when (total' > config.maxTotalEventBytes) $ protocol "event-total-overflow"
  when (isJust state.terminal) $ protocol "duplicate-terminal"
  if count' == 1
    then do
      thread <- admitInitial
      pure state {count = count', total = total', thread = Just thread}
    else do
      terminal <- admitLater state.thread
      pure state {count = count', total = total', terminal}
  where
    protocol :: Text -> Either AmpStop a
    protocol = Left . AmpProtocol
    read' = eventValue event
    admitInitial = do
      kind <- read' "type"
      when (kind /= String "system") $ protocol "missing-system-init"
      subtype <- read' "subtype"
      when (subtype /= String "init") $ protocol "missing-system-init"
      thread <-
        read' "session_id" >>= \case
          String t | Right _ <- ampThreadId t -> Right t
          _ -> protocol "malformed-thread-id"
      when (maybe False (/= thread) continuationThread) $ protocol "continuation-thread-mismatch"
      pure thread
    admitLater = \case
      Nothing -> protocol "missing-system-init"
      Just thread -> do
        session <- read' "session_id"
        when (session /= String thread) $ protocol "event-thread-mismatch"
        read' "type" >>= \case
          String t | t `elem` ["assistant", "user"] -> pure Nothing
          String "result" -> Just <$> admitTerminal thread
          -- @event_type in {...}@ raises TypeError on an unhashable
          -- value, which @_run@ settles as client-failed.
          value | unhashable value -> Left (AmpRaised AmpRaiseFailed)
          _ -> protocol "unknown-event"
    admitTerminal thread = do
      isError <- read' "is_error"
      subtype <- read' "subtype"
      case (isError, subtype) of
        (Bool False, String "success") -> do
          text <-
            read' "result" >>= \case
              String value -> either (Left . AmpProtocol) Right (safeFinalText config.maxFinalTextBytes value)
              _ -> protocol "malformed-result"
          pure (AmpCandidate TurnCompleted 1 "turn-completed" (Just thread) (Just text) True)
        (Bool True, String code)
          | code `elem` ["error_during_execution", "error_max_turns"] ->
              let code' = if code == "error_max_turns" then "provider-max-turns" else "provider-failed"
               in pure (AmpCandidate TurnFailed 0 code' (Just thread) Nothing True)
        (Bool True, value) | unhashable value -> Left (AmpRaised AmpRaiseFailed)
        _ -> protocol "malformed-terminal"
    -- A JSON list or object (a Python list or dict), or an opaque sidecar
    -- value whose type has no @__hash__@.
    unhashable = \case
      Array _ -> True
      Object members -> lookup "hashable" members /= Just (Bool True) || isNothing (lookup "opaque" members)
      _ -> False

-- | The termination code a stopped admission settles with.
stopCode :: AmpStop -> Text
stopCode = \case
  AmpProtocol code -> code
  AmpRaised AmpRaiseFailed -> "client-failed"
  AmpRaised AmpRaiseTimeout -> "deadline-exceeded"
  AmpRaised AmpRaiseCancelled -> "cancelled"

-- | @_read_stream@ over a complete event list (the corpus's pure view).
admitEvents :: AmpRuntimeConfig -> Maybe Text -> [AmpEvent] -> Either Text AmpCandidate
admitEvents config continuationThread = go (Admission 0 0 Nothing Nothing)
  where
    go state = \case
      [] -> maybe (Left "terminal-result-missing") Right state.terminal
      event : rest -> either (Left . stopCode) (`go` rest) (admitStep config continuationThread state event)

-- | @_execution_options()@, in the reference's member order.
executionOptions :: AmpRuntimeConfig -> Maybe Text -> [(Text, Json)]
executionOptions config continuationThread =
  [ ("executor", String "orb")
  , ("project", String config.project)
  , ("mode", String config.mode)
  , ("visibility", String config.visibility)
  , ("no_archive_after_execute", Bool config.noArchiveAfterExecute)
  ]
    <> [("continue_thread", String t) | Just t <- [continuationThread]]

-- ---------------------------------------------------------------------------
-- The provider-managed binding

ampBindingKind :: Text
ampBindingKind = "amp-provider-managed"

-- | DS6 binding for one Amp-owned thread/Orb lifecycle, never a Motus
-- lease.
data AmpProviderManagedBinding = AmpProviderManagedBinding
  { state :: MVar (Maybe (Unique, RuntimeOperation), Maybe Text)
  }

newAmpProviderManagedBinding :: IO AmpProviderManagedBinding
newAmpProviderManagedBinding = AmpProviderManagedBinding <$> newMVar (Nothing, Nothing)

-- | @bind(operation)@.
bindAmp :: AmpProviderManagedBinding -> Unique -> RuntimeOperation -> IO ()
bindAmp b token operation = do
  reason <- modifyMVar b.state $ \(current, reason) -> case current of
    Just (existing, _) | existing /= token -> throwIO (runtimeProtocolError "binding-conflict")
    _ -> pure ((Just (token, operation), reason), reason)
  forM_ reason (void . operation.cancel)

-- | The binding as the provider-neutral 'AttachmentBinding' record.
ampAttachmentBinding :: AmpProviderManagedBinding -> AttachmentBinding
ampAttachmentBinding b =
  AttachmentBinding
    { kind = ampBindingKind
    , cancel = \reason -> do
        reason' <- throwLeft (ampBoundedText "Amp cancellation reason" 256 reason)
        operation <- modifyMVar b.state $ \(current, existing) ->
          pure ((current, Just (fromMaybe reason' existing)), snd <$> current)
        forM_ operation $ \o -> void (o.cancel reason')
    , exportArchive = pure ""
    , settle = settleAmp b
    , motus = Nothing
    }

settleAmp :: AmpProviderManagedBinding -> IO BindingSettlement
settleAmp b = do
  (current, _) <- readMVar b.state
  case current of
    Nothing -> throwLeft (mkBindingSettlement ampBindingKind "not-created" True "")
    Just (_, operation) -> do
      cleanup <- operation.close
      if cleanupVerified cleanup
        then throwLeft (mkBindingSettlement ampBindingKind "client-closed" True "")
        else throwLeft (mkBindingSettlement ampBindingKind "unverified" False "")

-- ---------------------------------------------------------------------------
-- Operations

data OperationKey = OperationKey
  { episodeId :: Text
  , turnId :: Text
  , promptDigest :: Text
  , connectionId :: Text
  , authorityEpoch :: Integer
  , attachmentId :: Text
  , attachmentEpoch :: Integer
  , continuationThreadId :: Maybe Text
  }
  deriving stock (Eq)

-- | Why the consumer thread was interrupted.
data Interrupt = Cancelled | DeadlineExceeded
  deriving stock (Show)

instance Exception Interrupt

-- | One started Amp Turn (@_AmpRuntimeOperation@).
data AmpOperation = AmpOperation
  { invocation :: AmpRuntimeInvocation
  , key :: OperationKey
  , config :: AmpRuntimeConfig
  , codec :: AmpContinuationCodec
  , turns :: AmpTurnOperations
  , execute :: AmpExecute
  , continuationThread :: Maybe Text
  , clock :: IO Double
  , token :: Unique
  , lifecycle :: Lifecycle
  , sdkStarted :: TVar Bool
  , providerTerminal :: TVar Bool
  , consumer :: TVar (Maybe ThreadId)
  , interrupted :: TVar Bool
  }

ampOperationId :: AmpOperation -> Text
ampOperationId o = o.invocation.operationId

guarded :: AmpOperation -> IO a -> IO a
guarded o = Lifecycle.guarded o.lifecycle

settlement :: AmpOperation -> TurnOutcome -> Integer -> Text -> Maybe Text -> Maybe Text -> IO RuntimeTurnSettlement
settlement o outcome appends code out cont =
  throwLeft (mkRuntimeTurnSettlement o.invocation.episodeId o.invocation.turnId outcome appends code out cont)

-- | Interrupt the consumer once (cancellation or the deadline), without
-- blocking the caller.
interrupt :: AmpOperation -> Interrupt -> IO ()
interrupt o reason = do
  target <- atomically $ do
    done <- readTVar o.interrupted
    thread <- readTVar o.consumer
    case thread of
      Just t | not done -> writeTVar o.interrupted True >> pure (Just t)
      _ -> pure Nothing
  forM_ target $ \t -> void (forkIO (throwTo t reason))

startOperation :: AmpOperation -> IO ()
startOperation o = Lifecycle.startWorker o.lifecycle (runWorker o)

runWorker :: AmpOperation -> IO ()
runWorker o = do
  cancelledEarly <- Lifecycle.cancelRequested o.lifecycle
  outcome <-
    if cancelledEarly
      then settlement o TurnCancelled 0 "cancelled" Nothing Nothing
      else runBody o
  Lifecycle.settleAs o.lifecycle outcome

runBody :: AmpOperation -> IO RuntimeTurnSettlement
runBody o = do
  now <- o.clock
  let remaining = Episode.episodeDeadline o.invocation.attachment - now
  if remaining <= 0
    then settlement o TurnFailed 0 "deadline-exceeded" Nothing Nothing
    else do
      done <- newEmptyMVar
      guarded o . mask_ $ do
        thread <- forkIOWithUnmask $ \unmask -> try (unmask (consume o)) >>= putMVar done
        atomically (writeTVar o.consumer (Just thread))
      requested <- Lifecycle.cancelRequested o.lifecycle
      when requested (interrupt o Cancelled)
      consumed <-
        withAsync (threadDelay (micros remaining) >> interrupt o DeadlineExceeded) (const (takeMVar done))
          `finally` atomically (writeTVar o.consumer Nothing)
      case consumed of
        Right candidate -> do
          atomically (writeTVar o.providerTerminal candidate.providerTerminal)
          published <- try (publish o candidate)
          either (classify o) pure published
        Left e -> classify o e

classify :: AmpOperation -> SomeException -> IO RuntimeTurnSettlement
classify o e = case fromException e of
  Just Cancelled -> failed TurnCancelled "cancelled"
  Just DeadlineExceeded -> failed TurnFailed "deadline-exceeded"
  Nothing -> case fromException e of
    Just AmpRaiseCancelled -> failed TurnCancelled "cancelled"
    Just AmpRaiseTimeout -> failed TurnFailed "deadline-exceeded"
    Just AmpRaiseFailed -> failed TurnFailed "client-failed"
    Nothing -> case fromException e of
      Just (a :: AgenticusError)
        | a `isInstanceOf` TimeoutError -> failed TurnFailed "deadline-exceeded"
        | Just code <- runtimeProtocolErrorCode a -> failed TurnFailed code
      _ -> failed TurnFailed "client-failed"
  where
    failed outcome code = settlement o outcome 0 code Nothing Nothing

consume :: AmpOperation -> IO AmpCandidate
consume o = do
  let options = executionOptions o.config o.continuationThread
  atomically (writeTVar o.sdkStarted True)
  stream <- o.execute o.invocation.prompt options
  (readStream stream `onException` quietly stream.abort) `finally` quietly stream.close
  where
    quietly action = action `catch` \(_ :: SomeException) -> pure ()
    readStream stream = go (Admission 0 0 Nothing Nothing)
      where
        go state =
          stream.next >>= \case
            Nothing -> maybe (throwIO (runtimeProtocolError "terminal-result-missing")) pure state.terminal
            Just event -> case admitStep o.config o.continuationThread state event of
              Left (AmpProtocol code) -> throwIO (runtimeProtocolError code)
              Left (AmpRaised raised) -> throwIO raised
              Right state' -> go state'

publish :: AmpOperation -> AmpCandidate -> IO RuntimeTurnSettlement
publish o candidate = do
  continuationReference <- case candidate.threadId of
    Nothing -> pure Nothing
    Just thread -> do
      payload <- throwLeft (mkAmpContinuationPayloadV1 thread)
      Just <$> ampCodecStore o.codec (ampOperationId o) payload
  outputReference <- case candidate.finalText of
    Nothing -> pure Nothing
    Just text -> do
      reference <- o.turns.storeTurn (ampOperationId o) (fromMaybe "" candidate.threadId) text
      Just <$> throwLeft (opaqueReference "Amp Turn output reference" reference)
  settlement o candidate.outcome candidate.acceptedAppends candidate.terminationCode outputReference continuationReference

-- | @wait(timeout)@.
waitAmpOperation :: AmpOperation -> Maybe Double -> IO RuntimeTurnSettlement
waitAmpOperation o = Lifecycle.waitSettled o.lifecycle

-- | @cancel(reason)@.
cancelAmpOperation :: AmpOperation -> Text -> IO CancellationDisposition
cancelAmpOperation o reason = do
  _ <- throwLeft (ampBoundedText "Amp cancellation reason" 256 reason)
  Lifecycle.requestCancel o.lifecycle (interrupt o Cancelled)

-- | @close()@.
closeAmpOperation :: AmpOperation -> IO RuntimeOperationCleanup
closeAmpOperation o = Lifecycle.closeWith o.lifecycle o.config.cancellationGrace $ \absent -> do
  terminal <- readTVarIO o.providerTerminal
  started <- readTVarIO o.sdkStarted
  pure $
    if
      | not absent -> (RuntimeCleanupUnverified, "client-cleanup-uncertain")
      | terminal -> (RuntimeCleanupClean, "client-closed")
      | not started -> (RuntimeCleanupNotCreated, "client-not-created")
      | otherwise -> (RuntimeCleanupUnverified, "provider-state-uncertain")

-- | The operation as the provider-neutral 'RuntimeOperation' record.
ampRuntimeOperation :: AmpOperation -> RuntimeOperation
ampRuntimeOperation o =
  RuntimeOperation
    { operationId = ampOperationId o
    , wait = waitAmpOperation o
    , cancel = cancelAmpOperation o
    , close = closeAmpOperation o
    }

-- ---------------------------------------------------------------------------
-- The adapter

-- | The probe's environment: upstream's @_resolve_amp_cli@,
-- @importlib.metadata.version("amp-sdk")@ ('Nothing' for
-- @PackageNotFoundError@), @subprocess.run(argv, check=True, timeout=10)@
-- returning stdout (throwing 'IOException' for @OSError@ and
-- @SubprocessError@), and the SDK half of @_protocol_ready@.
data AmpProbeHooks = AmpProbeHooks
  { resolveCli :: IO (Maybe [FilePath])
  , installedSdkVersion :: IO (Maybe Text)
  , runCli :: [FilePath] -> IO Text
  , sdkProtocolReady :: IO Bool
  }

-- | The real probe environment, with the SDK reached through the sidecar.
officialProbeHooks :: AmpSidecar -> AmpProbeHooks
officialProbeHooks s =
  AmpProbeHooks
    { resolveCli = resolveAmpCli
    , installedSdkVersion =
        query "version" >>= \case
          Just (Object [("version", String v)]) -> pure (Just v)
          _ -> pure Nothing
    , runCli = \case
        [] -> throwIO (userError "empty argv")
        executable' : arguments ->
          runBounded (executable' : arguments) Nothing >>= \case
            Just (ExitSuccess, out, _) -> pure (TE.decodeUtf8With (\_ _ -> Just '\xfffd') out)
            _ -> throwIO (userError "command failed")
    , sdkProtocolReady =
        query "protocol" >>= \case
          Just (Object [("ready", Bool ready)]) -> pure ready
          _ -> pure False
    }
  where
    query mode = do
      command <- sidecarCommand s mode
      runSidecarOnce command 10 >>= \case
        Just (ExitSuccess, [value]) -> pure (Just value)
        _ -> pure Nothing

-- | @_resolve_amp_cli()@: the SDK's higher-priority CLI discovery.
resolveAmpCli :: IO (Maybe [FilePath])
resolveAmpCli = do
  explicit <- lookupEnv "AMP_CLI_PATH"
  explicitFile <- maybe (pure False) doesFileExist (nonEmpty explicit)
  case nonEmpty explicit of
    Just path | explicitFile -> pure (Just (if ".js" `isSuffixOf` path then ["node", path] else [path]))
    _ -> do
      home <- getHomeDirectory
      ampHome <- maybe (home </> ".amp") id . nonEmpty <$> lookupEnv "AMP_HOME"
      let candidates = [ampHome </> "sdk" </> "bin" </> "amp", ampHome </> "bin" </> "amp", home </> ".local" </> "bin" </> "amp"]
      found <- firstExecutable candidates
      case found of
        Just path -> pure (Just [path])
        Nothing -> fmap pure <$> findExecutable "amp"
  where
    nonEmpty = \case
      Just value | not (null value) -> Just value
      _ -> Nothing
    firstExecutable = \case
      [] -> pure Nothing
      path : rest -> do
        isFile <- doesFileExist path
        runnable <- if isFile then executable <$> getPermissions path else pure False
        if runnable then pure (Just path) else firstExecutable rest

-- | The adapter's keyword arguments: @sdk_execute@, @clock@, and the probe
-- environment.
data AmpAdapterOptions = AmpAdapterOptions
  { sdkExecute :: AmpExecute
  , clock :: IO Double
  , hooks :: AmpProbeHooks
  }

-- | The official SDK through the default sidecar and the monotonic clock.
ampAdapterOptions :: AmpAdapterOptions
ampAdapterOptions = AmpAdapterOptions (officialExecute ampSidecar) getMonotonicTime (officialProbeHooks ampSidecar)

-- | One concrete adapter for the exact Amp A1 Orb-backed profile.
data AmpRuntimeAdapter = AmpRuntimeAdapter
  { config :: AmpRuntimeConfig
  , codec :: AmpContinuationCodec
  , turns :: AmpTurnOperations
  , options :: AmpAdapterOptions
  , installation :: IORef (Maybe RuntimeInstallation)
  , operations :: MVar (Map Text AmpOperation)
  }

newAmpRuntimeAdapter :: AmpRuntimeConfig -> AmpContinuationCodec -> AmpTurnOperations -> AmpAdapterOptions -> IO AmpRuntimeAdapter
newAmpRuntimeAdapter config codec turns options = do
  config' <- throwLeft (newAmpRuntimeConfig config)
  AmpRuntimeAdapter config' codec turns options <$> newIORef Nothing <*> newMVar Map.empty

-- | @repr(adapter)@.
renderAmpRuntimeAdapter :: AmpRuntimeAdapter -> IO Text
renderAmpRuntimeAdapter a = do
  ready <- isJust <$> readIORef a.installation
  pure $
    "AmpRuntimeAdapter(project="
      <> pyStrRepr a.config.project
      <> ", mode="
      <> pyStrRepr a.config.mode
      <> ", ready="
      <> (if ready then "True" else "False")
      <> ")"

-- | @probe()@: the exact SDK/CLI pair without model use or connection
-- materialization.
probeAmp :: AmpRuntimeAdapter -> IO RuntimeProbeResult
probeAmp a = do
  let hooks = a.options.hooks
      identity = ampA1.identity
      verdict disposition installation issues = do
        issues' <- throwLeft (traverse (\(c, comp) -> mkProbeIssue c (Just comp)) issues)
        result <- throwLeft (mkRuntimeProbeResult identity disposition installation issues')
        writeIORef a.installation (if disposition == ProbeReady then installation else Nothing)
        pure result
  hooks.resolveCli >>= \case
    Nothing -> verdict ProbeNotInstalled Nothing [("client-not-installed", "amp-cli")]
    Just cli ->
      hooks.installedSdkVersion >>= \case
        Nothing -> verdict ProbeNotInstalled Nothing [("sdk-not-installed", "amp-sdk")]
        Just sdk ->
          try (pyFirstWord <$> hooks.runCli (cli <> ["--version"])) >>= \case
            Left (_ :: IOException) -> verdict ProbeUnavailable Nothing [("client-unavailable", "amp-cli")]
            Right version -> do
              installation <- observedInstallation version sdk
              let issues =
                    [("version-mismatch", "amp-cli") | version /= a.config.cliVersion]
                      <> [("version-mismatch", "amp-sdk") | sdk /= a.config.sdkVersion]
              if
                | not (null issues) -> verdict ProbeIncompatible (Just installation) issues
                | otherwise -> do
                    ready <- protocolReady hooks cli
                    if ready
                      then verdict ProbeReady (Just installation) []
                      else verdict ProbeUnavailable (Just installation) [("protocol-unavailable", "amp-sdk")]

observedInstallation :: Text -> Text -> IO RuntimeInstallation
observedInstallation cliVersion' sdkVersion' = do
  (system, machine') <- observedPlatform
  components <-
    throwLeft . sequence $
      [ mkInstalledComponent "amp-cli" (if T.null cliVersion' then "unparseable" else cliVersion') ampCliSource
      , mkInstalledComponent "amp-sdk" sdkVersion' ampSdkSource
      ]
  throwLeft $
    mkRuntimeInstallation
      ampA1.identity
      1
      components
      system
      machine'
      (Set.fromList ["runtime.cancel", "runtime.continue", "runtime.orb", "runtime.provider-managed"])

-- | @_protocol_ready(cli)@: any failure is a plain no.
protocolReady :: AmpProbeHooks -> [FilePath] -> IO Bool
protocolReady hooks cli =
  ( do
      help <- hooks.runCli (cli <> ["--help"])
      if all (`T.isInfixOf` help) ["--orb-execute", "--project", "--stream-json"]
        then hooks.sdkProtocolReady
        else pure False
  )
    `catch` \(e :: SomeException) -> if isAsync e then throwIO e else pure False

-- | @start(invocation)@: the same handle for an identical redelivery.
startAmp :: AmpRuntimeAdapter -> AmpRuntimeInvocation -> IO AmpOperation
startAmp a inv = do
  ready <- isJust <$> readIORef a.installation
  unless ready $ throwIO (runtimeProtocolError "runtime-not-ready")
  validateSnapshot inv.attachment
  when ((Episode.episodeBinding inv.attachment).kind /= ampBindingKind) $
    throwIO (runtimeProtocolError "attachment-binding-mismatch")
  continuationThread <- traverse (fmap payloadThreadId . ampCodecLoad a.codec) inv.continuation
  coordinates <- Episode.coordinates inv.attachment
  let key =
        OperationKey
          { episodeId = lifecycleIdText inv.episodeId
          , turnId = lifecycleIdText inv.turnId
          , promptDigest = sha256Hex (TE.encodeUtf8 inv.prompt)
          , connectionId = inv.connection.identity.connectionId
          , authorityEpoch = inv.connection.authorityEpoch
          , attachmentId = coordinates.attachmentId
          , attachmentEpoch = coordinates.attachmentEpoch
          , continuationThreadId = continuationThread
          }
  (operation, fresh) <- modifyMVar a.operations $ \known -> case Map.lookup inv.operationId known of
    Just existing
      | existing.key /= key -> throwIO (runtimeProtocolError "operation-conflict")
      | otherwise -> pure (known, (existing, False))
    Nothing -> do
      operation <- newOperation a inv key continuationThread
      pure (Map.insert inv.operationId operation known, (operation, True))
  if not fresh
    then bindAmp inv.binding operation.token (ampRuntimeOperation operation) >> pure operation
    else do
      ( bindAmp inv.binding operation.token (ampRuntimeOperation operation)
          >> startOperation operation
        )
        `onException` modifyMVar_ a.operations (pure . Map.delete inv.operationId)
      pure operation

newOperation :: AmpRuntimeAdapter -> AmpRuntimeInvocation -> OperationKey -> Maybe Text -> IO AmpOperation
newOperation a inv key continuationThread = do
  token <- newUnique
  lifecycle <- newLifecycle (LifecycleTexts "Amp operation wait timeout must be a positive finite number" "Amp runtime operation has not settled") inv.operationId
  sdkStarted <- newTVarIO False
  providerTerminal <- newTVarIO False
  consumer <- newTVarIO Nothing
  interrupted <- newTVarIO False
  pure
    AmpOperation
      { invocation = inv
      , key
      , config = a.config
      , codec = a.codec
      , turns = a.turns
      , execute = a.options.sdkExecute
      , continuationThread
      , clock = a.options.clock
      , ..
      }

-- | @_validate_snapshot@.
validateSnapshot :: EpisodeAttachment -> IO ()
validateSnapshot attachment = do
  let snapshot = Episode.episodeSnapshot attachment
      expected =
        [ (KindRuntime, ampA1.identity)
        , (KindConnection, connectionId')
        , (KindProgram, programId)
        , (KindHands, handsId)
        , (KindTerritory, territoryId)
        , (KindContinuation, continuationId)
        ]
  when (any (\(k, v) -> fmap (.identity) (snapshotDescriptor k snapshot) /= Just v) expected) $
    throwIO (runtimeProtocolError "resolution-mismatch")
  case snapshotDescriptor KindEffect snapshot of
    Just effect | "effect.host-fenced" `Set.member` effect.offers -> pure ()
    _ -> throwIO (runtimeProtocolError "resolution-mismatch")
