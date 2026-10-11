-- | Bounded public-Pi one-model-phase Activity adapter
-- (@petrus.agenticus.runtime.pi_model_phase@).
--
-- The adapter is the Agent-as-a-Net @model_phase@ Activity for one direct
-- API-key provider. Each call materializes one read-only credential lease,
-- runs the verbatim @pi_model_phase_helper.mjs@ once under the system
-- @node@ in a private mode-0700 root (one @start@ frame in, one terminal
-- frame out, tools declared but never executed), validates the exact public
-- assistant message and transcript extension, admits the result through the
-- connection fence, releases the lease, and only then publishes the private
-- assistant and Continuation payloads.
--
-- The reference's structural protocols (Continuation storage, custody,
-- helper clients and factories) are records of operations here.
module Petrus.Agenticus.Runtime.PiModelPhase
  ( -- * Bounds
    maxTranscriptBytes
  , maxOutputBytes
  , maxMessages
  , maxFrameBytes
    -- * Payloads and publications
  , PiModelPhaseContinuationPayloadV1 (transcriptJson)
  , mkPiModelPhaseContinuationPayloadV1
  , PiModelPhaseOutputPayloadV1 (assistantJson)
  , mkPiModelPhaseOutputPayloadV1
  , payloadSchemaVersion
  , PiModelPhasePublication (outputReference, continuationReference)
  , mkPiModelPhasePublication
  , PiModelPhaseOperations (..)
  , PiModelPhaseCustody (..)
  , piModelPhaseCustody
    -- * Configuration
  , PiModelPhaseConfig (..)
  , piModelPhaseConfig
  , newPiModelPhaseConfig
    -- * Helper clients
  , PhaseCandidate (..)
  , PhaseClient (..)
  , PhaseClientArgs (..)
  , PhaseFactory (..)
  , subprocessPhaseFactory
  , PhaseSubprocessClient
  , newPhaseSubprocessClient
  , phaseSubprocessClient
  , phaseSubprocessExited
  , piModelPhaseHelperPath
    -- * The adapter
  , PiModelPhaseAdapter
  , newPiModelPhaseAdapter
  , modelPhaseAdapterActivity
  , probeModelPhase
  , modelPhaseNode
  , setModelPhaseNode
  , setModelPhaseSdkEntrypoint
  , setModelPhaseFactory
  , modifyModelPhaseConfig
    -- * Pure validation (the reference's private functions, for tests)
  , validateCandidate
  , priorCalls
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (unless, void, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Char (isDigit)
import Data.IORef
import Data.List (sort)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Paths_petrus_agenticus_runtime (getDataFileName)
import Petrus.Activity (ActivityExecutionContext (..), ActivityInvocation (..))
import Petrus.Agenticus.Connection.Custody
  ( AdmissionResult (..)
  , AttachmentFence (..)
  , ConnectionIdentity (..)
  , ConnectionStatus (..)
  , ConnectionView (..)
  , LeaseMode (..)
  , ReleaseResult (..)
  )
import Petrus.Agenticus.Connection.Materialization (CleanupEvidence (..))
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Exception
import Petrus.Agenticus.Internal.Validate (hasControlOrDel, isTrimmed, sha256Hex, utf8Length)
import Petrus.Agenticus.Program.AgentNet
  ( LoopState (..)
  , ModelResult (..)
  , Proposal (..)
  , StopReason
  , loopStateFromData
  , maxProposals
  , mkModelSettlement
  , mkProposal
  , modelPhaseActivity
  , modelResultToModelData
  , modelSettlementToData
  , parseStopReason
  )
import Petrus.Agenticus.Runtime.Custody
import Petrus.Agenticus.Runtime.Internal.Process (HelperSpec (..), Helper (..), Framing (..), privateEnvironment, spawnHelper, nextReceived, helperExited, closeOnce, closeInput, stopReader, killGroup, awaitDrain, waitExit, exitInt, runBounded, removeRoot)
import Petrus.Agenticus.Runtime.Operation (runtimeProtocolError)
import Petrus.Agenticus.Runtime.Pi
  ( b64Encode
  , piAiVersion
  , piApiKeyCatalog
  , piSdkVersion
  , pyB64DecodeText
  , strictLoad
  )
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Directory
  ( canonicalizePath
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , makeAbsolute
  , pathIsSymbolicLink
  )
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, (</>))
import System.IO (hFlush)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files qualified as Files
import System.Posix.User (getEffectiveUserID)

-- ---------------------------------------------------------------------------
-- Bounds

maxTranscriptBytes, maxOutputBytes, maxMessages, maxFrameBytes :: Int
maxTranscriptBytes = 4000000
maxOutputBytes = 1000000
maxMessages = 10000
maxFrameBytes = 16 * 1024 * 1024

maxText, maxPrompt, maxRef, maxKey :: Int
maxText = 256
maxPrompt = 64 * 1024
maxRef = 512
maxKey = 8192

limits :: Json
limits =
  Object
    [ ("frame", Int (toInteger maxFrameBytes))
    , ("output", Int (toInteger maxOutputBytes))
    , ("transcript", Int (toInteger maxTranscriptBytes))
    , ("messages", Int (toInteger maxMessages))
    ]

protocol :: Text -> IO a
protocol = throwIO . runtimeProtocolError

-- | @_text(value, label, maximum)@.
phaseText :: Text -> Int -> Text -> Either AgenticusError Text
phaseText label bound value
  | T.null value || not (isTrimmed value) || utf8Length value > bound || hasControlOrDel value =
      Left (valueError ("Pi model phase " <> label <> " is invalid"))
  | otherwise = Right value

-- | @_prompt(value, label)@.
phasePrompt :: Text -> Text -> Either AgenticusError Text
phasePrompt label value
  | T.null value || utf8Length value > maxPrompt || T.any (== '\0') value =
      Left (valueError ("Pi model phase " <> label <> " is invalid"))
  | otherwise = Right value

-- | @_strict(raw)@: strict UTF-8 JSON without constants or duplicate names.
strict :: ByteString -> Maybe Json
strict = either (const Nothing) Just . strictLoad

-- | @_payload(value, maximum, label)@.
payload :: ByteString -> Int -> Text -> Either AgenticusError ByteString
payload value bound label = do
  let invalid :: Either AgenticusError a
      invalid = Left (valueError ("Pi model phase " <> label <> " is invalid"))
  when (B.null value || B.length value > bound) invalid
  decoded <- maybe invalid Right (strict value)
  case label of
    "transcript" -> case decoded of
      Array xs | length xs <= maxMessages && all isObject xs -> Right value
      _ -> invalid
    "assistant" -> if isObject decoded then Right value else invalid
    _ -> Right value

isObject :: Json -> Bool
isObject = \case
  Object _ -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- Payloads and publications

-- | The private transcript a Continuation reference names.
newtype PiModelPhaseContinuationPayloadV1 = PiModelPhaseContinuationPayloadV1 {transcriptJson :: ByteString}
  deriving stock (Eq)

instance Show PiModelPhaseContinuationPayloadV1 where
  show _ = "PiModelPhaseContinuationPayloadV1(schema_version=1)"

mkPiModelPhaseContinuationPayloadV1 :: ByteString -> Either AgenticusError PiModelPhaseContinuationPayloadV1
mkPiModelPhaseContinuationPayloadV1 value =
  PiModelPhaseContinuationPayloadV1 <$> payload value maxTranscriptBytes "transcript"

-- | The private assistant message an output reference names.
newtype PiModelPhaseOutputPayloadV1 = PiModelPhaseOutputPayloadV1 {assistantJson :: ByteString}
  deriving stock (Eq)

instance Show PiModelPhaseOutputPayloadV1 where
  show _ = "PiModelPhaseOutputPayloadV1(schema_version=1)"

mkPiModelPhaseOutputPayloadV1 :: ByteString -> Either AgenticusError PiModelPhaseOutputPayloadV1
mkPiModelPhaseOutputPayloadV1 value = PiModelPhaseOutputPayloadV1 <$> payload value maxOutputBytes "assistant"

-- | Both payloads' @schema_version@.
payloadSchemaVersion :: Integer
payloadSchemaVersion = 1

data PiModelPhasePublication = PiModelPhasePublication
  { outputReference :: Text
  , continuationReference :: Text
  }
  deriving stock (Eq, Show)

mkPiModelPhasePublication :: Text -> Text -> Either AgenticusError PiModelPhasePublication
mkPiModelPhasePublication output continuation =
  PiModelPhasePublication
    <$> phaseText "output reference" maxRef output
    <*> phaseText "Continuation reference" maxRef continuation

-- | @PiModelPhaseOperations@: atomically load private Continuations and
-- publish one complete phase.
data PiModelPhaseOperations = PiModelPhaseOperations
  { loadContinuation :: Text -> IO PiModelPhaseContinuationPayloadV1
  , publish :: Text -> PiModelPhaseOutputPayloadV1 -> PiModelPhaseContinuationPayloadV1 -> IO PiModelPhasePublication
  }

-- | @PiModelPhaseCustody@: the custody operations one phase needs.
data PiModelPhaseCustody = PiModelPhaseCustody
  { materialize :: Text -> Text -> LeaseMode -> Double -> Text -> IO HostMaterialization
  -- ^ connection, host, mode, ttl, operation
  , admitResult :: AttachmentFence -> Text -> IO AdmissionResult
  , release :: HostMaterialization -> Text -> IO ReleaseResult
  }

-- | The Pi runtime's custody (for example the real 'AgentConnectionCustody'
-- through 'Pi.hostConnectionCustody') as model-phase custody.
piModelPhaseCustody :: HostConnectionCustody -> PiModelPhaseCustody
piModelPhaseCustody c =
  PiModelPhaseCustody {materialize = c.materialize, admitResult = c.admitResult, release = c.release}

-- ---------------------------------------------------------------------------
-- Configuration

data PiModelPhaseConfig = PiModelPhaseConfig
  { provider :: Text
  , model :: Text
  , hostId :: Text
  , runtimeRoot :: FilePath
  , episodeId :: Text
  , turnId :: Text
  , systemPrompt :: Text
  , observation :: Text
  , timeout :: Double
  }
  deriving stock (Eq, Show)

-- | @PiModelPhaseConfig(provider, model, host_id, runtime_root, episode_id,
-- turn_id)@ with the reference's defaults, before validation.
piModelPhaseConfig :: Text -> Text -> Text -> FilePath -> Text -> Text -> PiModelPhaseConfig
piModelPhaseConfig provider model hostId runtimeRoot episodeId turnId =
  PiModelPhaseConfig
    { provider
    , model
    , hostId
    , runtimeRoot
    , episodeId
    , turnId
    , systemPrompt = "You are an Agenticus workspace agent. Use only supplied tools."
    , observation = "Continue."
    , timeout = 120
    }

-- | @PiModelPhaseConfig.__post_init__@: validate, and resolve the runtime
-- root.
newPiModelPhaseConfig :: PiModelPhaseConfig -> IO PiModelPhaseConfig
newPiModelPhaseConfig c = do
  provider <- throwLeft (phaseText "provider" maxText c.provider)
  model <- throwLeft (phaseText "model" maxText c.model)
  hostId <- throwLeft (phaseText "host_id" maxText c.hostId)
  episodeId <- throwLeft (phaseText "episode_id" maxText c.episodeId)
  turnId <- throwLeft (phaseText "turn_id" maxText c.turnId)
  systemPrompt <- throwLeft (phasePrompt "system_prompt" c.systemPrompt)
  observation <- throwLeft (phasePrompt "observation" c.observation)
  unless ((provider, model) `elem` piApiKeyCatalog) $
    throwIO (valueError "Pi model phase provider/model is outside the direct API-key catalog")
  when (isNaN c.timeout || isInfinite c.timeout || c.timeout <= 0) $
    throwIO (valueError "Pi model phase timeout must be positive and finite")
  linked <- pathIsSymbolicLink c.runtimeRoot `catch` \(_ :: IOException) -> pure False
  when linked $ throwIO (valueError "Pi model phase runtime_root must be stable")
  root <- canonicalizePath c.runtimeRoot
  status <- try (Files.getFileStatus root)
  uid <- getEffectiveUserID
  case status of
    Right s
      | Files.isDirectory s && Files.fileOwner s == uid && Files.fileMode s .&. 0o7777 == 0o700 -> pure ()
    Right _ -> throwIO (valueError "Pi model phase runtime_root must be owned mode-0700")
    Left (_ :: IOException) -> throwIO (valueError "Pi model phase runtime_root must be owned mode-0700")
  pure c {provider, model, hostId, runtimeRoot = root, episodeId, turnId, systemPrompt, observation}

-- ---------------------------------------------------------------------------
-- Helper clients

-- | @_Candidate@: the helper's base64-decoded assistant and transcript.
data PhaseCandidate = PhaseCandidate
  { assistant :: ByteString
  , transcript :: ByteString
  }
  deriving stock (Eq, Show)

-- | @_Client@: run one @start@ frame, then prove the helper gone.
data PhaseClient = PhaseClient
  { run :: Json -> Double -> IO () -> IO PhaseCandidate
  -- ^ frame, timeout, heartbeat
  , close :: IO Bool
  }

-- | @_Factory.create(node=..., helper=..., entrypoint=..., private_root=...)@.
data PhaseClientArgs = PhaseClientArgs
  { node :: FilePath
  , helper :: FilePath
  , entrypoint :: FilePath
  , privateRoot :: FilePath
  }
  deriving stock (Eq, Show)

-- | @_Factory@. 'isSubprocess' marks the reference's own
-- @_SubprocessFactory@, which requires a successful 'probeModelPhase'.
data PhaseFactory = PhaseFactory
  { create :: PhaseClientArgs -> IO PhaseClient
  , isSubprocess :: Bool
  }

subprocessPhaseFactory :: PhaseFactory
subprocessPhaseFactory =
  PhaseFactory
    { create = \args -> phaseSubprocessClient <$> newPhaseSubprocessClient args.node args.helper args.entrypoint args.privateRoot
    , isSubprocess = True
    }

piModelPhaseHelperPath :: IO FilePath
piModelPhaseHelperPath = getDataFileName "data/pi_model_phase_helper.mjs" >>= makeAbsolute

-- | @_SubprocessClient@: one helper process in its own session.
data PhaseSubprocessClient = PhaseSubprocessClient
  { helper :: Helper
  , writer :: IORef (Maybe ThreadId)
  }

newPhaseSubprocessClient :: FilePath -> FilePath -> FilePath -> FilePath -> IO PhaseSubprocessClient
newPhaseSubprocessClient node helper entrypoint privateRoot = do
  unless (isAbsolute node) $ protocol "runtime-not-ready"
  let command = HelperSpec {executable = node, arguments = [helper, entrypoint], directory = Nothing, environment = Just (privateEnvironment privateRoot node)}
  started <- spawnHelper Chunks command >>= maybe (protocol "helper-launch-failed") pure
  PhaseSubprocessClient started <$> newIORef Nothing

phaseSubprocessClient :: PhaseSubprocessClient -> PhaseClient
phaseSubprocessClient c = PhaseClient {run = runPhase c, close = closePhase c}

-- | @client.process.poll() is not None@.
phaseSubprocessExited :: PhaseSubprocessClient -> IO Bool
phaseSubprocessExited c = helperExited c.helper

-- | The reference's framed exchange: write the whole frame, read until the
-- helper closes stdout, heartbeating and honouring the wall deadline.
runPhase :: PhaseSubprocessClient -> Json -> Double -> IO () -> IO PhaseCandidate
runPhase c frame wall heartbeat = do
  raw <- case J.dumps J.compact frame of
    Left _ -> throwIO (valueError "Out of range float values are not JSON compliant")
    Right encoded -> pure (encoded <> "\n")
  when (B.length raw > maxFrameBytes) $ protocol "frame-overflow"
  written <- newTVarIO False
  writerThread <-
    forkIO $
      ((B.hPut c.helper.input raw >> hFlush c.helper.input) `catch` \(_ :: IOException) -> pure ())
        `finally` (closeInput c.helper >> atomically (writeTVar written True))
  writeIORef c.writer (Just writerThread)
  start <- getMonotonicTime
  let deadline = start + wall
      interval = min 5 (wall / 2)
      loop buffer outputOpen heartbeatAt = do
        inputOpen <- not <$> readTVarIO written
        if not inputOpen && not outputOpen
          then pure buffer
          else do
            now <- getMonotonicTime
            when (now >= deadline) $ protocol "deadline-exceeded"
            heartbeatAt' <-
              if now >= heartbeatAt
                then do
                  beat <- try heartbeat
                  case beat of
                    Left (e :: SomeException)
                      | isAsync e -> throwIO e
                      | otherwise -> protocol "activity-stale"
                    Right () -> (+ interval) <$> getMonotonicTime
                else pure heartbeatAt
            next <- if outputOpen then nextChunk else Nothing <$ pollDelay
            (buffer', outputOpen') <- case next of
              Nothing -> pure (buffer, outputOpen)
              Just Nothing -> pure (buffer, False)
              Just (Just chunk) -> do
                let grown = buffer <> chunk
                when (B.length grown > maxFrameBytes) $ protocol "frame-overflow"
                pure (grown, True)
            exited <- helperExited c.helper
            stillWriting <- not <$> readTVarIO written
            when (exited && stillWriting) $ stopWriter c >> atomically (writeTVar written True)
            loop buffer' outputOpen' heartbeatAt'
  buffer <- loop B.empty True (start + interval)
  returncode <- waitExit c.helper.process 0.1 >>= maybe (throwIO (agenticusError (OtherError "TimeoutExpired") "helper did not exit")) pure
  when (BC.count '\n' buffer /= 1 || BC.last buffer /= '\n') $ protocol "helper-protocol"
  answer <- maybe (protocol "malformed-frame") pure (strict (B.init buffer))
  members <- case answer of
    Object ms -> pure ms
    _ -> protocol "helper-protocol"
  let keys = sort (map fst members)
      field name = fromMaybe Null (lookup name members)
  when (keys == ["code", "type"] && field "type" == String "failed") $ do
    case field "code" of
      String code
        | exitInt returncode /= 0 && code `elem` ["provider-failed", "protocol-failed"] -> protocol code
      _ -> protocol "helper-protocol"
  when (returncode /= ExitSuccess || keys /= ["assistant", "transcript", "type"] || field "type" /= String "complete") $
    protocol "helper-protocol"
  PhaseCandidate
    <$> decodeMember (field "assistant") maxOutputBytes "assistant"
    <*> decodeMember (field "transcript") maxTranscriptBytes "transcript"
  where
    nextChunk = nextReceived c.helper 20000
    pollDelay = do
      delay <- registerDelay 20000
      atomically (readTVar delay >>= check)

-- | @_decode(value, maximum, label)@.
decodeMember :: Json -> Int -> Text -> IO ByteString
decodeMember value bound label = case value of
  String encoded -> case pyB64DecodeText encoded of
    Right body
      | b64Encode body == encoded -> either (const (protocol "malformed-complete")) pure (payload body bound label)
    _ -> protocol "malformed-complete"
  _ -> protocol "malformed-complete"

stopWriter :: PhaseSubprocessClient -> IO ()
stopWriter c = do
  readIORef c.writer >>= mapM_ killThread
  closeInput c.helper

-- | Kill the helper's process group and report whether it and its stderr
-- drain are proven gone.
closePhase :: PhaseSubprocessClient -> IO Bool
closePhase c = closeOnce c.helper $ do
  killGroup c.helper
  exited <- waitExit c.helper.process 1
  stopWriter c
  stopReader c.helper
  case exited of
    Nothing -> pure False
    Just _ -> awaitDrain c.helper 1

-- ---------------------------------------------------------------------------
-- The adapter

data PiModelPhaseAdapter = PiModelPhaseAdapter
  { config :: IORef PiModelPhaseConfig
  , connection :: ConnectionView
  , custody :: PiModelPhaseCustody
  , operations :: PiModelPhaseOperations
  , node :: IORef FilePath
  , sdkEntrypoint :: IORef (Maybe FilePath)
  , factory :: IORef PhaseFactory
  , probed :: IORef Bool
  }

-- | @PiModelPhaseAdapter(config, connection, custody, operations, node=...,
-- sdk_entrypoint=..., client_factory=...)@; 'Nothing' factory is the
-- subprocess factory.
newPiModelPhaseAdapter
  :: PiModelPhaseConfig
  -> ConnectionView
  -> PiModelPhaseCustody
  -> PiModelPhaseOperations
  -> FilePath
  -> Maybe FilePath
  -> Maybe PhaseFactory
  -> IO PiModelPhaseAdapter
newPiModelPhaseAdapter config' connection custody operations node' sdk factory' = do
  config'' <- newPiModelPhaseConfig config'
  when (connection.status /= StatusReady || connection.identity.profile /= "api-key") $
    throwIO (valueError "Pi model phase requires a ready api-key connection")
  when (connection.identity.provider /= config''.provider) $
    throwIO (valueError "Pi model phase connection provider mismatch")
  config <- newIORef config''
  node <- newIORef node'
  sdkEntrypoint <- newIORef sdk
  factory <- newIORef (fromMaybe subprocessPhaseFactory factory')
  probed <- newIORef False
  pure PiModelPhaseAdapter {config, connection, custody, operations, node, sdkEntrypoint, factory, probed}

modelPhaseNode :: PiModelPhaseAdapter -> IO FilePath
modelPhaseNode a = readIORef a.node

setModelPhaseNode :: PiModelPhaseAdapter -> FilePath -> IO ()
setModelPhaseNode a = writeIORef a.node

setModelPhaseSdkEntrypoint :: PiModelPhaseAdapter -> Maybe FilePath -> IO ()
setModelPhaseSdkEntrypoint a = writeIORef a.sdkEntrypoint

setModelPhaseFactory :: PiModelPhaseAdapter -> PhaseFactory -> IO ()
setModelPhaseFactory a = writeIORef a.factory

-- | The reference's @object.__setattr__(adapter.config, ...)@.
modifyModelPhaseConfig :: PiModelPhaseAdapter -> (PiModelPhaseConfig -> PiModelPhaseConfig) -> IO ()
modifyModelPhaseConfig a = modifyIORef' a.config

-- | @probe(package_root)@: the exact pinned packages, Node 22.19 or later,
-- and the helper's own @--probe@.
probeModelPhase :: PiModelPhaseAdapter -> FilePath -> IO Bool
probeModelPhase a packageRoot = do
  writeIORef a.probed False
  outcome <- try $ do
    configured <- readIORef a.node
    found <-
      if '/' `elem` configured
        then do
          exists <- doesFileExist configured
          executable <- if exists then Files.fileAccess configured False False True else pure False
          pure (if executable then Just configured else Nothing)
        else findExecutable configured
    case found of
      Nothing -> pure False
      Just nodePath -> do
        nodeReal <- strictPath nodePath
        root <- strictPath packageRoot
        package <- readJson (root </> "package.json")
        ai <- readJson (root </> "node_modules/@earendil-works/pi-ai/package.json")
        (versionCode, versionOut, _) <- runBounded [nodeReal, "--version"] Nothing >>= maybe invalid pure
        when (versionCode /= ExitSuccess) invalid
        entry <- strictPath (root </> "dist/index.js")
        helper <- piModelPhaseHelperPath >>= strictPath
        let version = T.strip (TE.decodeUtf8With (\_ _ -> Just '\xfffd') versionOut)
            numbers = case T.splitOn "." <$> T.stripPrefix "v" version of
              Just parts@[_, _, _] | all (\p -> not (T.null p) && T.all isDigit p) parts -> Just (map (read . T.unpack) parts :: [Integer])
              _ -> Nothing
        if field "name" package /= String "@earendil-works/pi-coding-agent"
          || field "version" package /= String piSdkVersion
          || field "name" ai /= String "@earendil-works/pi-ai"
          || field "version" ai /= String piAiVersion
          || maybe True (< [22, 19, 0]) numbers
          then pure False
          else do
            (code, out, err) <- runBounded [nodeReal, helper, entry, "--probe"] (Just (privateEnvironment "/dev/null" nodeReal)) >>= maybe invalid pure
            if code /= ExitSuccess || not (B.null err) || out /= "{\"type\":\"probe\",\"ok\":true}\n"
              then pure False
              else do
                writeIORef a.node nodeReal
                writeIORef a.sdkEntrypoint (Just entry)
                writeIORef a.probed True
                pure True
  case outcome of
    Right value -> pure value
    Left (e :: SomeException)
      | isAsync e -> throwIO e
      | otherwise -> pure False
  where
    invalid :: IO a
    invalid = throwIO (valueError "probe")
    strictPath path = do
      exists <- doesFileExist path
      directory <- doesDirectoryExist path
      if exists || directory then canonicalizePath path else invalid
    readJson path = B.readFile path >>= either (const invalid) pure . J.parseJson J.pythonLoads
    field name = \case
      Object members -> fromMaybe Null (lookup name members)
      _ -> Null

-- | @adapter(invocation, context=context)@: the @model_phase@ Activity.
modelPhaseAdapterActivity :: PiModelPhaseAdapter -> ActivityInvocation -> ActivityExecutionContext -> IO Json
modelPhaseAdapterActivity a invocation context = do
  when (invocation.activity /= modelPhaseActivity) $ protocol "activity-mismatch"
  state <- either (const (protocol "input-invalid")) pure (loopStateFromData invocation.input)
  cfg <- readIORef a.config
  when ((state.episodeId, state.turnId) /= (cfg.episodeId, cfg.turnId)) $ protocol "state-mismatch"
  operation <-
    either (const (protocol "runtime-not-ready")) pure $
      phaseText "operation" maxText (fromMaybe context.attemptId (invocation.idempotency >>= \i -> if T.null i then Nothing else Just i))
  sdk <- readIORef a.sdkEntrypoint
  factory <- readIORef a.factory
  probed <- readIORef a.probed
  node <- readIORef a.node
  case sdk of
    Nothing -> protocol "runtime-not-ready"
    Just entry ->
      when (factory.isSubprocess && (not probed || not (isAbsolute node) || not (isAbsolute entry))) $
        protocol "runtime-not-ready"
  when (state.phase > 1 && isNothing state.continuationRef) $ protocol "continuation-required"
  when (state.phase == 1 && not (null state.results)) $ protocol "result-mismatch"
  loaded <- try $ case state.continuationRef of
    Nothing -> pure "[]"
    Just reference -> do
      checked <- throwLeft (phaseText "reference" maxRef reference)
      (.transcriptJson) <$> a.operations.loadContinuation checked
  prior <- case loaded of
    Right value -> pure value
    Left (e :: SomeException)
      | isAsync e -> throwIO e
      | otherwise -> protocol "continuation-load-failed"
  unless (null state.results) $ do
    calls <- either throwIO pure (priorCalls prior)
    when (map (.id) state.results /= map fst calls) $ protocol "result-mismatch"
  let heartbeat = void (context.heartbeat (Just (Object [("phase", String "model")])))
  claimed <- try heartbeat
  case claimed of
    Left (e :: SomeException)
      | isAsync e -> throwIO e
      | otherwise -> protocol "activity-stale"
    Right () -> pure ()
  execute a cfg state operation prior heartbeat

execute :: PiModelPhaseAdapter -> PiModelPhaseConfig -> LoopState -> Text -> ByteString -> IO () -> IO Json
execute a cfg state operation prior heartbeat = do
  materializationRef <- newIORef Nothing
  clientRef <- newIORef Nothing
  rootRef <- newIORef Nothing
  cleanRef <- newIORef True
  let ids x = operation <> "." <> x
      andClean ok = modifyIORef' cleanRef (&& ok)
      body = do
        materialization <- a.custody.materialize a.connection.identity.connectionId cfg.hostId LeaseRead cfg.timeout (ids "materialize")
        writeIORef materializationRef (Just materialization)
        when (materialization.mode /= LeaseRead) $ protocol "custody-materialization-mismatch"
        let fence = materialization.fence
        when
          ( (fence.connectionId, fence.hostId, fence.authorityEpoch, fence.baseVersion)
              /= (a.connection.identity.connectionId, cfg.hostId, a.connection.authorityEpoch, a.connection.stateVersion)
          )
          $ protocol "custody-state-mismatch"
        credential <- materialization.home.read
        key <- case TE.decodeUtf8' credential of
          Right decoded | Right checked <- phaseText "credential" maxKey decoded -> pure checked
          _ -> protocol "credential-invalid"
        root <- createTempDirectory cfg.runtimeRoot "phase-"
        writeIORef rootRef (Just (root, Nothing))
        Files.setFileMode root 0o700
        metadata <- Files.getSymbolicLinkStatus root
        uid <- getEffectiveUserID
        when (Files.fileOwner metadata /= uid || Files.fileMode metadata .&. 0o7777 /= 0o700 || Files.isSymbolicLink metadata) $
          protocol "private-root-invalid"
        let identity = (toInteger (Files.deviceID metadata), toInteger (Files.fileID metadata))
        writeIORef rootRef (Just (root, Just identity))
        calls <- if null state.results then pure [] else either throwIO pure (priorCalls prior)
        let results =
              [ Object [("id", String r.id), ("method", String method), ("result", modelResultToModelData r)]
              | (r, (_, method)) <- zip state.results calls
              ]
            frame =
              Object
                [ ("type", String "start")
                , ("version", Int 1)
                , ("provider", String cfg.provider)
                , ("model", String cfg.model)
                , ("api_key", String key)
                , ("system", String cfg.systemPrompt)
                , ("observation", if state.phase == 1 then String cfg.observation else Null)
                , ("transcript", String (b64Encode prior))
                , ("results", Array results)
                , ("limits", limits)
                ]
        when (length results /= length state.results) $ throwIO (valueError "zip() arguments have different lengths")
        node <- readIORef a.node
        entry <- fromMaybe "" <$> readIORef a.sdkEntrypoint
        helper <- piModelPhaseHelperPath
        factory <- readIORef a.factory
        client <- factory.create PhaseClientArgs {node, helper, entrypoint = entry, privateRoot = root}
        writeIORef clientRef (Just client)
        candidate <- client.run frame cfg.timeout heartbeat
        client.close >>= andClean
        writeIORef clientRef Nothing
        removeRoot root (Just identity) >>= andClean
        writeIORef rootRef Nothing
        clean <- readIORef cleanRef
        unless clean $ protocol "cleanup-unverified"
        (assistant, transcript, proposals, stop) <-
          either throwIO pure (validateCandidate prior candidate state cfg.observation cfg.provider cfg.model)
        admission <- a.custody.admitResult fence (ids "admit")
        when ((admission.operationId, admission.attachmentId, admission.purpose) /= (ids "admit", fence.attachmentId, "result")) $
          protocol "custody-admission-mismatch"
        -- Release authority before publishing either private value.
        released <- a.custody.release materialization (ids "release")
        writeIORef materializationRef Nothing
        unless (releaseVerified released (ids "release") fence.attachmentId) $ protocol "cleanup-unverified"
        output <- throwLeft (mkPiModelPhaseOutputPayloadV1 assistant)
        continuation <- throwLeft (mkPiModelPhaseContinuationPayloadV1 transcript)
        publication <- a.operations.publish operation output continuation
        settlement <-
          throwLeft
            ( mkModelSettlement
                state
                stop
                (sha256Hex assistant)
                publication.outputReference
                publication.continuationReference
                proposals
            )
        pure (modelSettlementToData settlement)
  outcome <- try body
  -- The reference's @finally@: close, remove and release whatever is left.
  readIORef clientRef >>= mapM_ (\client -> safely client.close >>= andClean)
  readIORef rootRef >>= mapM_ (\(root, identity) -> safely (removeRoot root identity) >>= andClean)
  readIORef materializationRef >>= mapM_ (\materialization -> do
    verified <- safely (releaseVerified <$> a.custody.release materialization (ids "release") <*> pure (ids "release") <*> pure materialization.fence.attachmentId)
    andClean verified)
  clean <- readIORef cleanRef
  case outcome of
    Left (e :: SomeException)
      | isAsync e -> throwIO e
    _ | not clean -> protocol "cleanup-unverified"
    Right value -> pure value
    Left e
      | Just (agenticus :: AgenticusError) <- fromException e, agenticus.errorClass == RuntimeProtocolError -> throwIO agenticus
      | otherwise -> protocol "runtime-failed"
  where
    safely action =
      try action >>= \case
        Right value -> pure value
        Left (e :: SomeException)
          | isAsync e -> throwIO e
          | otherwise -> pure False

-- | @_release_verified(value, operation, attachment)@.
releaseVerified :: ReleaseResult -> Text -> Text -> Bool
releaseVerified value operation attachment =
  value.operationId == operation
    && value.cleanup.attachmentId == attachment
    && (value.cleanup.removed || value.cleanup.alreadyAbsent)
    && not value.cleanup.securityViolation

-- ---------------------------------------------------------------------------
-- Candidate validation

member :: Text -> [(Text, Json)] -> Maybe Json
member = lookup

isText :: Maybe Json -> Bool
isText = \case
  Just (String _) -> True
  _ -> False

isNumber :: Json -> Bool
isNumber = \case
  Int _ -> True
  Float x -> not (isNaN x || isInfinite x)
  _ -> False

-- | @_prior_calls(prior)@: the final assistant message's tool calls, as
-- @(id, name)@ pairs in order.
priorCalls :: ByteString -> Either AgenticusError [(Text, Text)]
priorCalls prior = do
  let mismatch = Left (runtimeProtocolError "result-mismatch")
  messages <- case strict prior of
    Just (Array xs) -> Right xs
    _ -> Left (valueError "Pi model phase transcript is invalid")
  final <- case reverse messages of
    Object members : _
      | member "role" members == Just (String "assistant")
      , Just (Array content) <- member "content" members ->
          Right content
    _ -> mismatch
  let calls = [members | Object members <- final, member "type" members == Just (String "toolCall")]
  mapM
    ( \call -> case (member "id" call, member "name" call, member "arguments" call) of
        (Just (String i), Just (String n), Just (Object _)) | isJust (member "type" call) -> Right (i, n)
        _ -> mismatch
    )
    calls

-- | @_validate_candidate(prior, candidate, state, observation, provider,
-- model)@: the exact public assistant message, the exact transcript
-- extension, the stop reason and the proposals in source order.
validateCandidate
  :: ByteString
  -> PhaseCandidate
  -> LoopState
  -> Text
  -> Text
  -> Text
  -> Either AgenticusError (ByteString, ByteString, [Proposal], StopReason)
validateCandidate prior candidate state observation provider model = do
  let malformed = Left (runtimeProtocolError "malformed-complete")
      proposalError = Left (runtimeProtocolError "malformed-proposal")
  (assistant, transcript) <-
    either (const malformed) Right $ do
      a <- payload candidate.assistant maxOutputBytes "assistant"
      t <- payload candidate.transcript maxTranscriptBytes "transcript"
      pure (fromMaybe Null (strict a), fromMaybe Null (strict t))
  old <- case strict prior of
    Just (Array xs) -> Right xs
    _ -> Left (valueError "Pi model phase transcript is invalid")
  toolResults <-
    if null state.results
      then Right []
      else do
        calls <- priorCalls prior
        when (length calls /= length state.results) $ Left (runtimeProtocolError "result-mismatch")
        mapM
          ( \(r, (identity, method)) -> do
              when (r.id /= identity) $ Left (runtimeProtocolError "result-mismatch")
              resultText <- either (const (Left (valueError "Out of range float values are not JSON compliant"))) Right (J.dumpsText modelDataOptions (modelResultToModelData r))
              Right $
                Object
                  [ ("role", String "toolResult")
                  , ("toolCallId", String r.id)
                  , ("toolName", String method)
                  , ("content", Array [Object [("type", String "text"), ("text", String resultText)]])
                  , ("isError", Bool (not r.ok))
                  , ("timestamp", Int 0)
                  ]
          )
          (zip state.results calls)
  let observed =
        [ Object [("role", String "user"), ("content", Array [Object [("type", String "text"), ("text", String observation)]]), ("timestamp", Int 0)]
        | state.phase == 1
        ]
      expected = old <> observed <> toolResults <> [assistant]
  case transcript of
    Array items | items == expected && last items == assistant -> Right ()
    _ -> Left (runtimeProtocolError "transcript-mismatch")
  members <- case assistant of
    Object ms -> Right ms
    _ -> malformed
  let keys = Set.fromList (map fst members)
      required = Set.fromList ["role", "content", "api", "provider", "model", "usage", "stopReason", "timestamp"]
      optional = Set.fromList ["responseModel", "responseId", "diagnostics", "errorMessage", "rawStopReason"]
  content <- case member "content" members of
    Just (Array xs) -> Right xs
    _ -> malformed
  when
    ( member "role" members /= Just (String "assistant")
        || not (required `Set.isSubsetOf` keys)
        || not (Set.null (keys `Set.difference` required `Set.difference` optional))
        || member "provider" members /= Just (String provider)
        || member "model" members /= Just (String model)
        || not (assistantMetadata members)
    )
    malformed
  stop <- either (const malformed) Right (parseStopReason (fromMaybe Null (member "stopReason" members)))
  proposals <-
    fmap concat . mapM
      ( \block -> do
          unless (contentBlock block) malformed
          case block of
            Object b | member "type" b == Just (String "toolCall") -> do
              let blockKeys = Set.fromList (map fst b)
              case (member "id" b, member "name" b, member "arguments" b) of
                (Just (String i), Just (String n), Just arguments@(Object _))
                  | blockKeys `Set.isSubsetOf` Set.fromList ["type", "id", "name", "arguments", "thoughtSignature"]
                  , maybe True (\case String _ -> True; _ -> False) (member "thoughtSignature" b) ->
                      either (const proposalError) (Right . pure) (mkProposal i n arguments)
                _ -> proposalError
            _ -> Right []
      )
      $ content
  when (toInteger (length proposals) > maxProposals) $ Left (runtimeProtocolError "proposal-overflow")
  when (Set.size (Set.fromList (map (.id) proposals)) /= length proposals) proposalError
  pure (candidate.assistant, candidate.transcript, proposals, stop)
  where
    modelDataOptions = J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"}

-- | @_assistant_metadata(value)@.
assistantMetadata :: [(Text, Json)] -> Bool
assistantMetadata value =
  usageMetadata (member "usage" value)
    && maybe False isNumber (member "timestamp" value)
    && all (\name -> case member name value of Just (String t) -> isRightText t; _ -> False) ["api", "provider", "model"]
    && all (\name -> maybe True (isText . Just) (member name value)) ["responseModel", "responseId", "errorMessage", "rawStopReason"]
    && maybe True (\case Array _ -> True; _ -> False) (member "diagnostics" value)
  where
    isRightText t = either (const False) (const True) (phaseText "assistant" maxText t)

-- | @_usage_metadata(usage)@.
usageMetadata :: Maybe Json -> Bool
usageMetadata = \case
  Just (Object usage) ->
    let keys = Set.fromList (map fst usage)
        allowed = Set.fromList ["input", "output", "cacheRead", "cacheWrite", "cacheWrite1h", "reasoning", "totalTokens", "cost"]
        required = Set.fromList ["input", "output", "cacheRead", "cacheWrite", "totalTokens", "cost"]
     in keys `Set.isSubsetOf` allowed
          && required `Set.isSubsetOf` keys
          && case member "cost" usage of
            Just (Object cost)
              | Set.fromList (map fst cost) == Set.fromList ["input", "output", "cacheRead", "cacheWrite", "total"] ->
                  all nonNegative ([v | (k, v) <- usage, k /= "cost"] <> map snd cost)
            _ -> False
  _ -> False
  where
    nonNegative v = isNumber v && case v of
      Int n -> n >= 0
      Float x -> x >= 0
      _ -> False

-- | @_content_block(value)@.
contentBlock :: Json -> Bool
contentBlock = \case
  Object block -> case member "type" block of
    Just (String "text") ->
      keysWithin block ["type", "text", "textSignature"]
        && isText (member "text" block)
        && maybe True (isText . Just) (member "textSignature" block)
    Just (String "thinking") ->
      keysWithin block ["type", "thinking", "thinkingSignature", "redacted"]
        && isText (member "thinking" block)
        && maybe True (isText . Just) (member "thinkingSignature" block)
        && maybe True (\case Bool _ -> True; _ -> False) (member "redacted" block)
    Just (String "toolCall") -> True
    _ -> False
  _ -> False
  where
    keysWithin block allowed = all ((`elem` (allowed :: [Text])) . fst) block
