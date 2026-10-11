-- | The exact Claude A2 Local runtime (@petrus.agenticus.runtime.claude@).
--
-- The Claude Agent SDK owns the agent loop and drives the bundled Claude
-- Code CLI; Agenticus owns the connection lease, the private mode-0700
-- operation root, the closed @mcp__petrus_hands__*@ tool surface (answered
-- by the Episode's 'HandsGateway'), the bounded main-transcript mirror
-- behind the native Continuation, and publication.
--
-- The reference's client and factory protocols are records here
-- ('ClaudeClient', 'ClaudeClientFactory'). @_OfficialFactory@ is
-- 'officialFactory' over a 'ClaudeSdk' record: the PreToolUse hook, the
-- pending-call correlation and the tool handlers stay in Haskell. The real
-- SDK is reached through the @claude_sidecar.py@ data file ('sidecarSdk'),
-- which calls those hooks, handlers and the 'SessionStore' back over its
-- JSON-lines pipe, so every persisted transcript byte is produced here.
-- Connection custody is the record shared with the Pi host
-- ('PiConnectionCustody').
module Petrus.Agenticus.Runtime.Claude
  ( -- * Pins
    claudeSdkVersion
  , claudeSdkSourceCommit
  , claudeCodeVersion
  , claudeCodeDistributionCommit
  , claudeSdkSource
  , claudeCodeSource
    -- * Descriptors
  , claudeContinuationDescriptor
  , claudeProgram
  , claudeProgramCapabilities
  , claudeContinuationCapabilities
  , claudeConnectionCapabilities
  , claudeCollocatedHands
  , claudeLocalTerritory
  , claudeTools
  , claudeAuthEnvironment
  , claudeRequiredAttributes
  , claudeOptionFields
  , maxPromptBytes
    -- * Pure protocol pieces
  , claudeText
  , claudeUuid
  , jsonEntries
  , encodeTranscript
  , decodeTranscript
  , canonicalInput
  , sanitize
  , projectBinding
  , firstVersion
  , pyTruthy
  , cliWrapperSource
  , installCliWrapper
    -- * Continuations
  , ClaudeContinuationPayloadV1 (sessionId, projectBinding, projectKey, transcript)
  , mkClaudeContinuationPayloadV1
  , ClaudeContinuationOperations (..)
  , ClaudeTurnOperations (..)
  , ClaudeContinuationCodec
  , claudeContinuationCodec
  , claudeCodecStore
  , claudeCodecLoad
    -- * The session store
  , SessionStore
  , newSessionStore
  , storeAppend
  , storeLoad
  , storeSeed
  , storeSnapshot
  , storeFailed
    -- * Configuration and invocations
  , ClaudeRuntimeConfig (..)
  , claudeRuntimeConfig
  , newClaudeRuntimeConfig
  , renderClaudeRuntimeConfig
  , ClaudeRuntimeInvocation (..)
  , newClaudeRuntimeInvocation
  , renderClaudeRuntimeInvocation
    -- * Clients
  , ClaudeResult (..)
  , ClaudeMessage (..)
  , ClaudeOptions (..)
  , StderrPolicy (..)
  , ClaudeClient (..)
  , ClaudeClientFactory (..)
  , ClaudeTool (..)
  , ClaudeSdkRequest (..)
  , ClaudeSdk (..)
  , officialFactory
  , ClaudeSidecar (..)
  , SidecarPool
  , newSidecarPool
  , closeSidecarPool
  , withSidecarPool
  , defaultSidecarPool
  , sidecarPoolPids
  , claudeSidecar
  , claudeSidecarPath
  , sidecarSdk
    -- * Operations
  , ClaudeOperation
  , claudeOperationId
  , claudeRuntimeOperation
  , waitClaudeOperation
  , cancelClaudeOperation
  , closeClaudeOperation
  , renderClaudeOperation
    -- * The adapter
  , ClaudeSdkSurface (..)
  , ClaudeProbeHooks (..)
  , officialClaudeProbeHooks
  , ClaudeAdapterOptions (..)
  , claudeAdapterOptions
  , ClaudeRuntimeAdapter
  , newClaudeRuntimeAdapter
  , renderClaudeRuntimeAdapter
  , claudeAdapterConfig
  , setClaudeReady
  , probeClaude
  , startClaude
  ) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception
  ( IOException
  , SomeException
  , catch
  , finally
  , fromException
  , mask
  , mask_
  , onException
  , throwIO
  , try
  )
import Control.Monad (forM_, unless, void, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Char (isDigit, isHexDigit, isLower)
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Paths_petrus_agenticus_runtime (getDataFileName)
import Petrus.Agenticus.Attachment.Binding
  ( AttachmentBinding (..)
  , AttachmentCoordinates (..)
  , bindingExecution
  , bindingLeaseIdentity
  , bindingProvider
  )
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
import Petrus.Agenticus.Hands.Contract (ToolResult (..), allToolMethods, toolMethodText, toolResultToData)
import Petrus.Agenticus.Hands.Gateway (HandsGateway, gatewayAttachmentEpoch, gatewayAttachmentId, gatewayEpisodeId)
import Petrus.Agenticus.Hands.Gateway qualified as Gateway
import Petrus.Agenticus.Hands.Grants (CapabilityGrant (..), currentGrant)
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
import Petrus.Agenticus.Runtime.Operation
  ( RuntimeCleanupDisposition (..)
  , RuntimeOperation (..)
  , RuntimeOperationCleanup
  , mkRuntimeOperationCleanup
  , runtimeProtocolError
  , runtimeProtocolErrorCode
  )
import Petrus.Agenticus.Runtime.Pi (PiConnectionCustody (..), PiHome (..), PiMaterialization (..), canonicalUuid, micros, piToolSchemas, runBounded)
import Petrus.Agenticus.Runtime.Profiles (claudeA2Local)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..), mkRuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Continuation
  ( Continuation (..)
  , ContinuationDescriptor
  , ContinuationState (..)
  , continuationDescriptor
  )
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
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, findExecutable, makeAbsolute, pathIsSymbolicLink, removeDirectoryRecursive)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, hFlush)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as PosixIO
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Process (proc)
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Pins

claudeSdkVersion, claudeSdkSourceCommit, claudeCodeVersion, claudeCodeDistributionCommit :: Text
claudeSdkVersion = "0.2.128"
claudeSdkSourceCommit = "ec776735b0eb8a8286827a005b35be1782e1940c"
claudeCodeVersion = "2.1.220"
claudeCodeDistributionCommit = "7ef6eec9d9ba84ea6f233f26c45f1df5c5991843"

claudeSdkSource, claudeCodeSource :: Text
claudeSdkSource = "pypi:claude-agent-sdk==" <> claudeSdkVersion <> "#commit=" <> claudeSdkSourceCommit
claudeCodeSource = "bundled:claude-code==" <> claudeCodeVersion <> "#commit=" <> claudeCodeDistributionCommit

-- ---------------------------------------------------------------------------
-- Descriptors

programId, continuationId, connectionId', handsId, territoryId :: DescriptorIdentity
programId = descriptorIdentity KindProgram "claude.provider-managed" 1
continuationId = descriptorIdentity KindContinuation "claude.native" 1
connectionId' = descriptorIdentity KindConnection "claude.api-key" 1
handsId = descriptorIdentity KindHands "claude.collocated" 1
territoryId = descriptorIdentity KindTerritory "motus.local" 1

claudeContinuationDescriptor :: ContinuationDescriptor
claudeContinuationDescriptor = continuationDescriptor continuationId programId

claudeProgram :: AgentProgramDescriptor
claudeProgram =
  agentProgramDescriptor
    programId
    ProviderOwned
    True
    [continuationRequirement continuationId programId]
    (Just continuationId)
    False
    False

claudeProgramCapabilities
  , claudeContinuationCapabilities
  , claudeConnectionCapabilities
  , claudeCollocatedHands
  , claudeLocalTerritory
    :: CapabilityDescriptor
claudeProgramCapabilities = capabilityDescriptor programId ["program.provider-owned"] []
claudeContinuationCapabilities = capabilityDescriptor continuationId ["continuation.claude-native"] []
claudeConnectionCapabilities = capabilityDescriptor connectionId' ["connection.claude"] []
claudeCollocatedHands = capabilityDescriptor handsId ["hands.collocated"] []
claudeLocalTerritory = capabilityDescriptor territoryId [] []

-- | @_TOOLS@.
claudeTools :: [Text]
claudeTools = ["mcp__petrus_hands__" <> toolMethodText m | m <- allToolMethods]

-- | @_AUTH_ENVIRONMENT@: every ambient provider authority blanked.
claudeAuthEnvironment :: [(Text, Text)]
claudeAuthEnvironment =
  [ (name, "")
  | name <-
      [ "ANTHROPIC_AUTH_TOKEN"
      , "ANTHROPIC_BASE_URL"
      , "ANTHROPIC_MODEL"
      , "CLAUDE_CODE_OAUTH_TOKEN"
      , "CLAUDE_CODE_USE_BEDROCK"
      , "CLAUDE_CODE_USE_FOUNDRY"
      , "CLAUDE_CODE_USE_VERTEX"
      , "AWS_ACCESS_KEY_ID"
      , "AWS_CONTAINER_CREDENTIALS_FULL_URI"
      , "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"
      , "AWS_PROFILE"
      , "AWS_SECRET_ACCESS_KEY"
      , "AWS_SESSION_TOKEN"
      , "AWS_WEB_IDENTITY_TOKEN_FILE"
      , "AZURE_CLIENT_ID"
      , "AZURE_CLIENT_SECRET"
      , "AZURE_TENANT_ID"
      , "GOOGLE_APPLICATION_CREDENTIALS"
      , "GOOGLE_CLOUD_PROJECT"
      ]
  ]

-- | The SDK attributes the probe requires.
claudeRequiredAttributes :: [Text]
claudeRequiredAttributes =
  [ "ClaudeSDKClient"
  , "ClaudeAgentOptions"
  , "ResultMessage"
  , "MirrorErrorMessage"
  , "UserMessage"
  , "AssistantMessage"
  , "SystemMessage"
  , "StreamEvent"
  , "RateLimitEvent"
  , "SessionStore"
  , "tool"
  , "create_sdk_mcp_server"
  , "HookMatcher"
  ]

-- | The @ClaudeAgentOptions@ parameters the probe requires.
claudeOptionFields :: [Text]
claudeOptionFields =
  [ "tools"
  , "allowed_tools"
  , "mcp_servers"
  , "strict_mcp_config"
  , "permission_mode"
  , "resume"
  , "session_store"
  , "session_store_flush"
  , "setting_sources"
  , "skills"
  , "plugins"
  , "agents"
  , "model"
  , "fallback_model"
  , "cwd"
  , "cli_path"
  , "env"
  , "max_turns"
  , "max_budget_usd"
  , "max_buffer_size"
  , "hooks"
  , "stderr"
  ]

maxPromptBytes, maxTranscriptEntries, maxTranscriptBytes :: Int
maxPromptBytes = 64 * 1024
maxTranscriptEntries = 10000
maxTranscriptBytes = 4000000

minDisconnectTimeout :: Double
minDisconnectTimeout = 25

-- ---------------------------------------------------------------------------
-- Pure protocol pieces

-- | @_text(value, name, maximum)@.
claudeText :: Text -> Int -> Text -> Either AgenticusError Text
claudeText name maximum' value
  | isBoundedText maximum' value = Right value
  | otherwise = Left (valueError (name <> " must be bounded non-empty text"))

-- | @_uuid(value)@.
claudeUuid :: Text -> Either AgenticusError Text
claudeUuid value = do
  _ <- claudeText "Claude session identity" 36 value
  if canonicalUuid value then Right value else Left (valueError "Claude session identity must be a canonical UUID")

-- | @json.loads(json.dumps(value, sort_keys=True))@: every object's members
-- in code-point order, a repeated member keeping its last value.
sortedDeep :: Json -> Json
sortedDeep = \case
  Object members -> Object (Map.toAscList (Map.fromList [(k, sortedDeep v) | (k, v) <- members]))
  Array values -> Array (map sortedDeep values)
  other -> other

-- | @json.dumps(value, separators=(",", ":"), ensure_ascii=False,
-- allow_nan=False, sort_keys=True).encode()@.
canonicalBytes :: Json -> Either J.EncodeError ByteString
canonicalBytes = J.dumps J.compact {J.sortKeys = True}

-- | @_json_entries(value, maximum_entries, maximum_total)@: the entries as
-- @json.loads@ returns them, with their canonical bytes.
jsonEntries :: Int -> Int -> Json -> Either AgenticusError ([Json], ByteString)
jsonEntries maximumEntries maximumTotal = \case
  Array values
    | not (null values) && length values <= maximumEntries -> do
        let copied = map sortedDeep values
        encoded <- either (const (Left (valueError "Claude transcript must contain strict JSON entries"))) Right (canonicalBytes (Array copied))
        when (B.length encoded > maximumTotal || any (not . isObject) copied) $
          Left (valueError "Claude transcript exceeds its entry or total bound")
        pure (copied, encoded)
  _ -> Left (valueError "Claude transcript must be one bounded non-empty entry batch")
  where
    isObject = \case
      Object _ -> True
      _ -> False

-- | @_encode_transcript(value, maximum_entries, maximum_total)@.
encodeTranscript :: Int -> Int -> Json -> Either AgenticusError ByteString
encodeTranscript maximumEntries maximumTotal value = snd <$> jsonEntries maximumEntries maximumTotal value

-- | @_decode_transcript(value, maximum_entries, maximum_total)@.
decodeTranscript :: Int -> Int -> ByteString -> Either AgenticusError [Json]
decodeTranscript maximumEntries maximumTotal value = do
  when (B.null value || B.length value > maximumTotal) $
    Left (valueError "Claude transcript must be non-empty bounded opaque bytes")
  decoded <- maybe (Left (valueError "Claude transcript must be strict JSON bytes")) Right (pyJsonLoadsBytes value)
  (entries, encoded) <- jsonEntries maximumEntries maximumTotal decoded
  when (encoded /= value) $ Left (valueError "Claude transcript bytes must use the canonical immutable encoding")
  pure entries

-- | @_canonical_input(value)@.
canonicalInput :: Json -> Either AgenticusError ByteString
canonicalInput = \case
  value@(Object _) -> do
    encoded <-
      either (const (Left (valueError "Claude tool input must be strict JSON"))) Right $
        J.dumps J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":", J.sortKeys = True, J.allowNan = False} value
    when (B.length encoded > 8192) $ Left (valueError "Claude tool input exceeds its protocol bound")
    pure encoded
  _ -> Left (valueError "Claude tool input must be a JSON object")

-- | @_sanitize(value, maximum)@ for a string result: the overflow code on
-- the left.
sanitize :: Int -> Text -> Either Text Text
sanitize maximum' value
  | utf8Length sanitized > maximum' = Left "result-overflow"
  | otherwise = Right sanitized
  where
    sanitized = T.map safe (stripAnsi value)
    safe c
      | c `elem` ("\n\r\t" :: String) || (c >= ' ' && not (c >= '\x7f' && c <= '\x9f')) = c
      | otherwise = '\xfffd'

-- | @_project_binding(path)@.
projectBinding :: FilePath -> Text
projectBinding path = sha256Hex (TE.encodeUtf8 (T.pack path))

-- | @re.search(r"(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])", output)@.
firstVersion :: Text -> Maybe Text
firstVersion = go False . T.unpack
  where
    go _ [] = Nothing
    go afterDigit input@(c : rest)
      | isDigit c && not afterDigit = case version input of
          Just found -> Just (T.pack found)
          Nothing -> go True rest
      | otherwise = go (isDigit c) rest
    version input = do
      let (a, r1) = span isDigit input
      r1' <- dot r1
      let (b, r2) = span isDigit r1'
      r2' <- dot r2
      let (c, r3) = span isDigit r2'
      if null a || null b || null c
        then Nothing
        else case r3 of
          d : _ | isDigit d -> Nothing
          _ -> Just (a <> "." <> b <> "." <> c)
    dot = \case
      '.' : rest -> Just rest
      _ -> Nothing

-- | Python truthiness of a JSON value.
pyTruthy :: Json -> Bool
pyTruthy = \case
  Null -> False
  Bool b -> b
  Int i -> i /= 0
  Float d -> d /= 0
  String t -> not (T.null t)
  Array values -> not (null values)
  Object members -> not (null members)

-- | A Python number as the reference's defaults spell it: whole values as
-- integers.
pyNumber :: Double -> Text
pyNumber d
  | isWhole d = T.pack (show (round d :: Integer))
  | otherwise = T.pack (J.pythonFloatRepr d)

numberJson :: Double -> Json
numberJson d
  | isWhole d = Int (round d)
  | otherwise = Float d

isWhole :: Double -> Bool
isWhole d = not (isNaN d || isInfinite d) && abs d < 1e16 && fromInteger (round d) == d

-- ---------------------------------------------------------------------------
-- Continuations

-- | One accepted Claude main transcript behind a native Continuation.
data ClaudeContinuationPayloadV1 = ClaudeContinuationPayloadV1
  { sessionId :: Text
  , projectBinding :: Text
  , projectKey :: Text
  , transcript :: ByteString
  }
  deriving stock (Eq)

-- | Every field is @repr=False@ upstream.
instance Show ClaudeContinuationPayloadV1 where
  show _ = "ClaudeContinuationPayloadV1(schema_version=1)"

mkClaudeContinuationPayloadV1 :: Text -> Text -> Text -> ByteString -> Either AgenticusError ClaudeContinuationPayloadV1
mkClaudeContinuationPayloadV1 session binding key transcript' = do
  session' <- claudeUuid session
  binding' <- claudeText "Claude project binding" 64 binding
  unless (T.length binding' == 64 && T.all (\c -> isDigit c || (isHexDigit c && isLower c)) binding') $
    Left (valueError "Claude project binding must be a SHA-256 digest")
  key' <- claudeText "Claude project key" 512 key
  _ <- decodeTranscript maxTranscriptEntries maxTranscriptBytes transcript'
  pure (ClaudeContinuationPayloadV1 session' binding' key' transcript')

data ClaudeContinuationOperations = ClaudeContinuationOperations
  { store :: Text -> ClaudeContinuationPayloadV1 -> IO Text
  , load :: Text -> IO ClaudeContinuationPayloadV1
  }

newtype ClaudeTurnOperations = ClaudeTurnOperations
  { storeTurn :: Text -> Text -> IO Text
  }

newtype ClaudeContinuationCodec = ClaudeContinuationCodec ClaudeContinuationOperations

claudeContinuationCodec :: ClaudeContinuationOperations -> ClaudeContinuationCodec
claudeContinuationCodec = ClaudeContinuationCodec

claudeCodecStore :: ClaudeContinuationCodec -> Text -> ClaudeContinuationPayloadV1 -> IO Text
claudeCodecStore (ClaudeContinuationCodec operations) operationId payload = do
  operation <- throwLeft (claudeText "Claude operation" 256 operationId)
  reference <- operations.store operation payload
  throwLeft (claudeText "state reference" 512 reference)

claudeCodecLoad :: ClaudeContinuationCodec -> Continuation -> IO ClaudeContinuationPayloadV1
claudeCodecLoad (ClaudeContinuationCodec operations) continuation = do
  when (continuation.descriptor /= claudeContinuationDescriptor) $
    throwIO (valueError "Claude Continuation does not match this runtime")
  operations.load continuation.stateReference

-- ---------------------------------------------------------------------------
-- The session store

data StoreState = StoreState
  { entries :: [Json]
  , uuids :: Map Text Json
  , projectKey :: Maybe Text
  , sessionId :: Maybe Text
  }

-- | @_SessionStore@: the bounded main-transcript mirror the SDK writes
-- through.
data SessionStore = SessionStore
  { maxEntries :: Int
  , maxTotal :: Int
  , lock :: MVar ()
  , state :: IORef StoreState
  , failed :: IORef Bool
  }

newSessionStore :: Int -> Int -> Maybe Text -> Maybe Text -> IO SessionStore
newSessionStore maxEntries maxTotal key session =
  SessionStore maxEntries maxTotal <$> newMVar () <*> newIORef (StoreState [] Map.empty key session) <*> newIORef False

-- | The store's @failed@ flag.
storeFailed :: SessionStore -> IO Bool
storeFailed s = readIORef s.failed

-- | @_validate_key(key)@.
validateKey :: Json -> Either AgenticusError (Text, Text)
validateKey = \case
  Object members
    | Set.fromList (map fst members) == Set.fromList ["project_key", "session_id"] -> do
        let field name = fromMaybe Null (lookup name (reverse members))
        key <- case field "project_key" of
          String t -> claudeText "Claude session project key" 512 t
          _ -> Left (valueError "Claude session project key must be bounded non-empty text")
        session <- case field "session_id" of
          String t -> claudeUuid t
          _ -> Left (valueError "Claude session identity must be bounded non-empty text")
        pure (key, session)
  _ -> Left (valueError "")

-- | @append(key, entries)@: any refusal marks the store failed and raises
-- @RuntimeError("session-store-failed")@.
storeAppend :: SessionStore -> Json -> Json -> IO ()
storeAppend s key incoming =
  try body >>= \case
    Right () -> pure ()
    Left (e :: SomeException)
      | isAsync e -> throwIO e
      | otherwise -> do
          writeIORef s.failed True
          throwAgenticus RuntimeError "session-store-failed"
  where
    body = do
      (project, session) <- throwLeft (validateKey key)
      values <- case incoming of
        Array values -> pure values
        _ -> throwIO (valueError "")
      unless (null values) . withMVar s.lock $ \() -> do
        st0 <- readIORef s.state
        -- The first identities stick even when the rest of the batch fails.
        let st = StoreState st0.entries st0.uuids (Just (fromMaybe project st0.projectKey)) (Just (fromMaybe session st0.sessionId))
        writeIORef s.state st
        when (Just project /= st.projectKey || Just session /= st.sessionId) $ throwIO (valueError "")
        (checked, _) <- throwLeft (jsonEntries s.maxEntries s.maxTotal incoming)
        (candidate, uuids') <- either (const (throwIO (valueError ""))) pure (foldEntries (Seq.fromList st.entries, st.uuids) checked)
        (final, _) <- throwLeft (jsonEntries s.maxEntries s.maxTotal (Array (toList candidate)))
        writeIORef s.state st {entries = final, uuids = uuids'}
    foldEntries acc [] = Right acc
    foldEntries (candidate, uuids') (entry : rest) = case member "uuid" entry of
      Nothing -> foldEntries (candidate Seq.|> entry, uuids') rest
      Just Null -> foldEntries (candidate Seq.|> entry, uuids') rest
      Just (String identity) -> case Map.lookup identity uuids' of
        Just prior
          | prior /= entry -> Left ()
          | otherwise -> foldEntries (candidate, uuids') rest
        Nothing -> foldEntries (candidate Seq.|> entry, Map.insert identity entry uuids') rest
      Just _ -> Left ()

-- | @load(key)@: the mirrored entries, or 'Nothing' for a foreign key or an
-- empty mirror.
storeLoad :: SessionStore -> Json -> IO (Maybe [Json])
storeLoad s key = case validateKey key of
  Left _ -> pure Nothing
  Right (project, session) -> do
    st <- readIORef s.state
    if Just project /= st.projectKey || Just session /= st.sessionId
      then pure Nothing
      else withMVar s.lock $ \() -> do
        current <- readIORef s.state
        pure (if null current.entries then Nothing else Just current.entries)

-- | @seed(transcript)@: install the accepted prior transcript.
storeSeed :: SessionStore -> ByteString -> IO ()
storeSeed s value = do
  st <- readIORef s.state
  unless (null st.entries) conflict
  when (isNothing st.projectKey || isNothing st.sessionId) conflict
  checked <- either (const conflict) pure (decodeTranscript s.maxEntries s.maxTotal value)
  writeIORef s.state st {entries = checked}
  forM_ checked $ \entry -> case member "uuid" entry of
    Just (String identity) -> do
      current <- readIORef s.state
      case Map.lookup identity current.uuids of
        Just prior | prior /= entry -> conflict
        _ -> writeIORef s.state current {uuids = Map.insert identity entry current.uuids}
    _ -> pure ()
  where
    conflict :: IO a
    conflict = throwIO (runtimeProtocolError "session-store-conflict")

-- | @snapshot(session_id)@: the project key and canonical transcript bytes.
storeSnapshot :: SessionStore -> Text -> IO (Text, ByteString)
storeSnapshot s session = do
  broken <- readIORef s.failed
  st <- readIORef s.state
  case st.projectKey of
    Just project
      | not broken && st.sessionId == Just session && not (null st.entries) -> do
          bytes <- either (const (throwIO (runtimeProtocolError "session-store-failed"))) pure (encodeTranscript s.maxEntries s.maxTotal (Array st.entries))
          pure (project, bytes)
    _ -> throwIO (runtimeProtocolError "session-store-failed")

member :: Text -> Json -> Maybe Json
member name = \case
  Object members -> lookup name (reverse members)
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Configuration

-- | @ClaudeRuntimeConfig@. Build one with 'claudeRuntimeConfig' and
-- validate it with 'newClaudeRuntimeConfig' (the reference's
-- @__post_init__@).
data ClaudeRuntimeConfig = ClaudeRuntimeConfig
  { model :: Text
  , workingDirectory :: FilePath
  , runtimeRoot :: FilePath
  , hostId :: Text
  , credentialTtl :: Double
  , maxTurns :: Int
  , maxBudgetUsd :: Double
  , wallTimeout :: Double
  , cancellationGrace :: Double
  , disconnectTimeout :: Double
  , maxMessages :: Int
  , maxMessageBytes :: Int
  , maxTranscriptBytes :: Int
  , sdkVersion :: Text
  , cliVersion :: Text
  }
  deriving stock (Eq)

instance Show ClaudeRuntimeConfig where
  show = T.unpack . renderClaudeRuntimeConfig

-- | The reference's defaults.
claudeRuntimeConfig :: Text -> FilePath -> FilePath -> ClaudeRuntimeConfig
claudeRuntimeConfig model workingDirectory runtimeRoot =
  ClaudeRuntimeConfig
    { model
    , workingDirectory
    , runtimeRoot
    , hostId = "local"
    , credentialTtl = 300
    , maxTurns = 32
    , maxBudgetUsd = 10
    , wallTimeout = 300
    , cancellationGrace = 10
    , disconnectTimeout = minDisconnectTimeout
    , maxMessages = 10000
    , maxMessageBytes = 1000000
    , maxTranscriptBytes = 4000000
    , sdkVersion = claudeSdkVersion
    , cliVersion = claudeCodeVersion
    }

-- | @repr(config)@ without the two private paths.
renderClaudeRuntimeConfig :: ClaudeRuntimeConfig -> Text
renderClaudeRuntimeConfig c =
  "ClaudeRuntimeConfig(model="
    <> pyStrRepr c.model
    <> ", host_id="
    <> pyStrRepr c.hostId
    <> ", credential_ttl="
    <> pyNumber c.credentialTtl
    <> ", max_turns="
    <> int c.maxTurns
    <> ", max_budget_usd="
    <> pyNumber c.maxBudgetUsd
    <> ", wall_timeout="
    <> pyNumber c.wallTimeout
    <> ", cancellation_grace="
    <> pyNumber c.cancellationGrace
    <> ", disconnect_timeout="
    <> pyNumber c.disconnectTimeout
    <> ", max_messages="
    <> int c.maxMessages
    <> ", max_message_bytes="
    <> int c.maxMessageBytes
    <> ", max_transcript_bytes="
    <> int c.maxTranscriptBytes
    <> ", sdk_version="
    <> pyStrRepr c.sdkVersion
    <> ", cli_version="
    <> pyStrRepr c.cliVersion
    <> ")"
  where
    int = T.pack . show

-- | Validate and normalize a configuration.
newClaudeRuntimeConfig :: ClaudeRuntimeConfig -> IO ClaudeRuntimeConfig
newClaudeRuntimeConfig c = do
  model <- throwLeft (claudeText "Claude model" 256 c.model)
  hostId <- throwLeft (claudeText "Claude host" 256 c.hostId)
  workingDirectory <- directory "working_directory" c.workingDirectory
  runtimeRoot <- directory "runtime_root" c.runtimeRoot
  uid <- getEffectiveUserID
  rootStatus <- Files.getFileStatus runtimeRoot
  when (Files.fileMode rootStatus .&. 0o777 /= 0o700 || Files.fileOwner rootStatus /= uid) $
    throwIO (valueError "Claude runtime_root must be an owned mode-0700 directory")
  forM_ [("max_turns", c.maxTurns), ("max_messages", c.maxMessages), ("max_message_bytes", c.maxMessageBytes), ("max_transcript_bytes", c.maxTranscriptBytes)] $
    \(name, value) -> when (value <= 0) $ throwIO (valueError ("Claude " <> name <> " must be positive"))
  forM_
    [ ("credential_ttl", c.credentialTtl, 0)
    , ("max_budget_usd", c.maxBudgetUsd, 0)
    , ("wall_timeout", c.wallTimeout, 0)
    , ("cancellation_grace", c.cancellationGrace, 0)
    , ("disconnect_timeout", c.disconnectTimeout, minDisconnectTimeout)
    ]
    $ \(name, value, minimum') -> do
      when (isNaN value || isInfinite value || value <= 0) $ throwIO (valueError ("Claude " <> name <> " must be positive"))
      when (value < minimum') $ throwIO (valueError ("Claude " <> name <> " must satisfy the pinned SDK cleanup bound"))
  when (c.sdkVersion /= claudeSdkVersion || c.cliVersion /= claudeCodeVersion) $
    throwIO (valueError "Claude requires the exact qualified SDK and CLI pair")
  pure c {model, hostId, workingDirectory, runtimeRoot}
  where
    directory name selected = do
      linked <- pathIsSymbolicLink selected `catch` \(_ :: IOException) -> pure False
      when linked $ throwIO (valueError ("Claude " <> name <> " must be an existing stable directory"))
      path <- canonicalizePath selected
      isDirectory <- doesDirectoryExist path
      unless isDirectory $ throwIO (valueError ("Claude " <> name <> " must be an existing stable directory"))
      pure path

-- ---------------------------------------------------------------------------
-- Invocations

-- | One Claude Turn request. Build it with 'newClaudeRuntimeInvocation',
-- which runs the reference's @__post_init__@ checks.
data ClaudeRuntimeInvocation = ClaudeRuntimeInvocation
  { operationId :: Text
  , episodeId :: EpisodeId
  , turnId :: TurnId
  , prompt :: Text
  , connection :: ConnectionView
  , attachment :: EpisodeAttachment
  , gateway :: HandsGateway
  , grantEpoch :: Integer
  , continuation :: Maybe Continuation
  }

instance Show ClaudeRuntimeInvocation where
  show = T.unpack . renderClaudeRuntimeInvocation

-- | @repr(invocation)@: no prompt, attachment, gateway or continuation.
renderClaudeRuntimeInvocation :: ClaudeRuntimeInvocation -> Text
renderClaudeRuntimeInvocation i =
  "ClaudeRuntimeInvocation(operation_id="
    <> pyStrRepr i.operationId
    <> ", episode_id=EpisodeId(value="
    <> pyStrRepr (lifecycleIdText i.episodeId)
    <> "), turn_id=TurnId(value="
    <> pyStrRepr (lifecycleIdText i.turnId)
    <> "), connection="
    <> T.pack (show i.connection)
    <> ", grant_epoch="
    <> T.pack (show i.grantEpoch)
    <> ")"

newClaudeRuntimeInvocation :: ClaudeRuntimeInvocation -> IO ClaudeRuntimeInvocation
newClaudeRuntimeInvocation i = do
  operationId <- throwLeft (claudeText "Claude operation" 256 i.operationId)
  when (T.null i.prompt || utf8Length i.prompt > maxPromptBytes || T.elem '\0' i.prompt) $
    throwIO (valueError "Claude prompt must be bounded non-empty text")
  when
    ( i.connection.status /= StatusReady
        || i.connection.identity.provider /= "claude"
        || i.connection.identity.profile /= "api-key"
    )
    $ throwIO (valueError "Claude invocation requires the ready Claude api-key profile")
  when (Episode.episodeId i.attachment /= i.episodeId) $
    throwIO (valueError "Claude invocation requires its exact Episode Attachment")
  c <- Episode.coordinates i.attachment
  when
    ( (gatewayEpisodeId i.gateway, gatewayAttachmentId i.gateway, gatewayAttachmentEpoch i.gateway)
        /= (c.episodeId, c.attachmentId, c.attachmentEpoch)
    )
    $ throwIO (valueError "Claude gateway does not match the attachment epoch")
  when (i.grantEpoch <= 0) $ throwIO (valueError "Claude grant epoch must be positive")
  pure (ClaudeRuntimeInvocation operationId i.episodeId i.turnId i.prompt i.connection i.attachment i.gateway i.grantEpoch i.continuation)

-- ---------------------------------------------------------------------------
-- Clients

-- | @_Result@: the one terminal SDK result, with its values as the SDK
-- reported them.
data ClaudeResult = ClaudeResult
  { subtype :: Json
  , isError :: Json
  , sessionId :: Json
  , terminalReason :: Json
  , text :: Json
  , encodedSize :: Int
  }
  deriving stock (Eq, Show)

-- | One classified SDK message (@_Result@, @_MirrorError@, @_Event@), each
-- with its canonical encoded size.
data ClaudeMessage
  = MessageResult ClaudeResult
  | MessageMirrorError Int
  | MessageEvent Int
  deriving stock (Eq, Show)

messageSize :: ClaudeMessage -> Int
messageSize = \case
  MessageResult r -> r.encodedSize
  MessageMirrorError size -> size
  MessageEvent size -> size

-- | @options["stderr"]@: the reference always passes
-- @_discard_provider_stderr@.
data StderrPolicy = DiscardProviderStderr
  deriving stock (Eq, Show)

-- | The SDK options the adapter builds: every JSON-representable option in
-- the reference's order, plus the session store and stderr policy.
data ClaudeOptions = ClaudeOptions
  { values :: [(Text, Json)]
  , sessionStore :: SessionStore
  , stderr :: StderrPolicy
  }

-- | @_Client@. 'receiveResponse' starts one response iteration and returns
-- its @__anext__@ ('Nothing' at the end). 'release' frees whatever process
-- hosts the client after the last 'disconnect' (the reference relies on
-- garbage collection); 'False' when that is not proven.
data ClaudeClient = ClaudeClient
  { connect :: IO ()
  , query :: Text -> IO ()
  , receiveResponse :: IO (IO (Maybe ClaudeMessage))
  , interrupt :: IO ()
  , disconnect :: IO ()
  , release :: IO Bool
  }

-- | @_ClientFactory@.
newtype ClaudeClientFactory = ClaudeClientFactory
  { create :: ClaudeOptions -> HandsGateway -> ClaudeRuntimeInvocation -> IO ClaudeClient
  }

-- | One @sdk.tool(name, description, schema)(handler)@ registration.
data ClaudeTool = ClaudeTool
  { name :: Text
  , description :: Text
  , schema :: Json
  , handler :: Json -> IO Json
  }

-- | Everything @_OfficialFactory.create@ hands the SDK: the options, the
-- in-process MCP server's tools, and the PreToolUse hook.
data ClaudeSdkRequest = ClaudeSdkRequest
  { options :: ClaudeOptions
  , serverName :: Text
  , tools :: [ClaudeTool]
  , preToolUse :: Json -> IO Json
  }

-- | The SDK surface @_OfficialFactory@ drives:
-- @ClaudeSDKClient(options=ClaudeAgentOptions(**options))@ wrapped by
-- @_OfficialClient@.
newtype ClaudeSdk = ClaudeSdk
  { newClient :: ClaudeSdkRequest -> IO ClaudeClient
  }

-- | @_OfficialFactory(sdk)@.
officialFactory :: ClaudeSdk -> ClaudeClientFactory
officialFactory sdk = ClaudeClientFactory $ \options gateway invocation -> do
  pending <- newMVar (Map.empty :: Map (Text, ByteString) (Seq Text))
  let hookOutput fields = Object [("hookSpecificOutput", Object (("hookEventName", String "PreToolUse") : fields))]
      deny = hookOutput [("permissionDecision", String "deny"), ("permissionDecisionReason", String "unsupported-tool")]
      allow = hookOutput [("permissionDecision", String "allow")]
      admitted data' = do
        name <- case member "tool_name" data' of
          Just (String n) | n `elem` claudeTools -> Right n
          _ -> Left ()
        call <- case member "tool_use_id" data' of
          Just (String c) -> Right c
          _ -> Left ()
        when (isJust (member "agent_id" data') || isJust (member "agent_type" data')) (Left ())
        arguments <- case member "tool_input" data' of
          Just value@(Object _) -> Right value
          _ -> Left ()
        call' <- either (const (Left ())) Right (claudeText "Claude tool call identity" 256 call)
        encoded <- either (const (Left ())) Right (canonicalInput arguments)
        pure ((name, encoded), call')
      hook data' = case admitted data' of
        Left () -> pure deny
        Right (correlation, call) -> do
          modifyMVar_ pending (pure . Map.insertWith (\new old -> old <> new) correlation (Seq.singleton call))
          pure allow
      unsupported = Object [("content", Array [Object [("type", String "text"), ("text", String "unsupported-tool")]]), ("is_error", Bool True)]
      handler fullName method arguments = do
        let correlation = either (const Nothing) (\encoded -> Just (fullName, encoded)) (canonicalInput arguments)
        call <- modifyMVar pending $ \known -> case correlation of
          Just k | Just (c Seq.:<| rest) <- Map.lookup k known ->
            pure (if Seq.null rest then Map.delete k known else Map.insert k rest known, Just c)
          _ -> pure (known, Nothing)
        case call of
          Nothing -> pure unsupported
          Just c -> do
            coords <- Episode.coordinates invocation.attachment
            result <-
              Gateway.submit
                gateway
                ( Object
                    [ ("version", Int 1)
                    , ("call_id", String c)
                    , ("episode_id", String coords.episodeId)
                    , ("attachment_id", String coords.attachmentId)
                    , ("attachment_epoch", Int coords.attachmentEpoch)
                    , ("grant_epoch", Int invocation.grantEpoch)
                    , ("method", String (toolMethodText method))
                    , ("params", arguments)
                    ]
                )
            body <-
              either (const (throwIO (valueError "Out of range float values are not JSON compliant"))) pure $
                J.dumps J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"} (toolResultToData result)
            pure
              ( Object
                  [ ("content", Array [Object [("type", String "text"), ("text", String (TE.decodeUtf8 body))]])
                  , ("is_error", Bool (not result.ok))
                  ]
              )
      tools =
        [ ClaudeTool
            { name = toolMethodText method
            , description = "Agenticus workspace capability"
            , schema = fromMaybe (Object []) (lookup method piToolSchemas)
            , handler = handler fullName method
            }
        | (fullName, method) <- zip claudeTools allToolMethods
        ]
  sdk.newClient ClaudeSdkRequest {options, serverName = "petrus_hands", tools, preToolUse = hook}

-- ---------------------------------------------------------------------------
-- The official SDK sidecar

-- | How to run @claude_sidecar.py@: the interpreter, extra @sys.path@
-- entries, the grace for each bounded sidecar step, and the pool whose
-- shared sidecar hosts the clients.
data ClaudeSidecar = ClaudeSidecar
  { python :: FilePath
  , searchPath :: [FilePath]
  , grace :: Double
  , pool :: SidecarPool
  }

-- | @python3@ from @PATH@, over the 'defaultSidecarPool'.
claudeSidecar :: ClaudeSidecar
claudeSidecar = ClaudeSidecar "python3" [] 10 defaultSidecarPool

claudeSidecarPath :: IO FilePath
claudeSidecarPath = getDataFileName "data/claude_sidecar.py"

sidecarCommand :: ClaudeSidecar -> String -> IO SidecarCommand
sidecarCommand s mode = do
  script <- claudeSidecarPath
  pure (SidecarCommand s.python (["-I", "-B", script, mode] <> s.searchPath) Nothing Nothing)

-- | The real SDK behind 'ClaudeSdk': one channel of the shared sidecar per
-- client, which builds the official client and forwards the hook, tool and
-- session-store calls back here.
sidecarSdk :: ClaudeSidecar -> ClaudeSdk
sidecarSdk config = ClaudeSdk $ \request -> do
  command <- sidecarCommand config "serve"
  s <- openSidecarChannel config.pool command >>= maybe (throwAgenticus RuntimeError "Claude SDK sidecar did not start") pure
  let initial =
        Object
          [ ("options", Object request.options.values)
          , ("server", String request.serverName)
          , ("tools", Array [Object [("name", String t.name), ("description", String t.description), ("schema", t.schema)] | t <- request.tools])
          ]
  sent <- channelSend s initial
  ready <- if sent then channelReceiveWithin s config.grace else pure Nothing
  case ready of
    Just frame | member "ready" frame == Just (Bool True) -> pure ()
    _ -> do
      void (channelClose s config.grace)
      throwAgenticus RuntimeError "Claude SDK client could not be created"
  writeLock <- newMVar ()
  -- The calls awaiting their answer; 'Nothing' once the channel has
  -- ended, when every call fails at once (the sidecar died, or the
  -- channel's teardown is finished).
  pending <- newMVar (Just Map.empty :: Maybe (Map Integer (MVar (Maybe Json))))
  counter <- newIORef (0 :: Integer)
  let send frame = withMVar writeLock (const (void (channelSend s frame)))
      answer k = \case
        Right value -> send (Object [("reply", Int k), ("value", value)])
        Left code -> send (Object [("reply", Int k), ("error", String code)])
      serveCall k frame = do
        outcome <- try $ case member "method" frame of
          Just (String "hook") -> request.preToolUse (fromMaybe Null (member "data" frame))
          Just (String "tool") -> case member "index" frame of
            Just (Int index) | index >= 0, (t : _) <- drop (fromInteger index) request.tools -> t.handler (fromMaybe Null (member "arguments" frame))
            _ -> throwAgenticus RuntimeError "unknown tool"
          Just (String "append") -> do
            storeAppend request.options.sessionStore (fromMaybe Null (member "key" frame)) (fromMaybe Null (member "entries" frame))
            pure Null
          Just (String "load") -> maybe Null Array <$> storeLoad request.options.sessionStore (fromMaybe Null (member "key" frame))
          _ -> throwAgenticus RuntimeError "unknown call"
        case outcome of
          Right value -> answer k (Right value)
          Left (e :: SomeException)
            | isAsync e -> throwIO e
            | otherwise -> answer k (Left (maybe "failed" (\(failure :: AgenticusError) -> failure.errorMessage) (fromException e)))
      failAll = modifyMVar_ pending $ \known -> do
        forM_ (fromMaybe Map.empty known) (`tryPutMVar` Nothing)
        pure Nothing
      dispatch =
        channelReceive s >>= \case
          Nothing -> failAll
          Just frame -> do
            case (member "done" frame, member "call" frame) of
              (Just (Int n), _) -> withMVar pending $ \known -> forM_ (known >>= Map.lookup n) (\box -> void (tryPutMVar box (Just frame)))
              (_, Just (Int k)) -> void (forkIO (serveCall k frame))
              _ -> pure ()
            dispatch
  dispatcher <- forkIO (dispatch `finally` failAll)
  let call :: Text -> [(Text, Json)] -> IO Json
      call op fields = do
        n <- atomicModifyIORef' counter (\i -> (i + 1, i + 1))
        box <- newEmptyMVar
        modifyMVar_ pending $ \case
          Just known -> pure (Just (Map.insert n box known))
          Nothing -> putMVar box Nothing >> pure Nothing
        reply <-
          ( do
              send (Object (("op", String op) : ("id", Int n) : fields))
              takeMVar box
          )
            `onException` ( do
                              modifyMVar_ pending (pure . fmap (Map.delete n))
                              send (Object [("op", String "cancel"), ("id", Int 0), ("target", Int n)])
                          )
        modifyMVar_ pending (pure . fmap (Map.delete n))
        case reply of
          Nothing -> throwAgenticus RuntimeError "Claude SDK sidecar exited"
          Just frame -> case (member "value" frame, member "error" frame) of
            (Just value, _) -> pure value
            (_, Just (String "protocol")) -> case member "code" frame of
              Just (String code) -> throwIO (runtimeProtocolError code)
              _ -> throwAgenticus RuntimeError "Claude SDK call failed"
            (_, Just (String "timeout")) -> throwAgenticus TimeoutError "Claude SDK call timed out"
            _ -> throwAgenticus RuntimeError "Claude SDK call failed"
      decodeMessage = \case
        Null -> pure Nothing
        frame -> case (member "kind" frame, member "size" frame) of
          (Just (String "result"), Just (Int size)) ->
            let field name = fromMaybe Null (member name frame)
             in pure (Just (MessageResult (ClaudeResult (field "subtype") (field "is_error") (field "session_id") (field "terminal_reason") (field "result") (fromInteger size))))
          (Just (String "mirror"), Just (Int size)) -> pure (Just (MessageMirrorError (fromInteger size)))
          (Just (String "event"), Just (Int size)) -> pure (Just (MessageEvent (fromInteger size)))
          _ -> throwIO (runtimeProtocolError "malformed-message")
  pure
    ClaudeClient
      { connect = void (call "connect" [])
      , query = \p -> void (call "query" [("prompt", String p)])
      , receiveResponse = do
          -- @receive_response()@ only creates the async generator (no SDK
          -- code runs until the first pull), so its acknowledgement is not
          -- awaited: the sidecar runs the channel's frames in order.
          n <- atomicModifyIORef' counter (\i -> (i + 1, i + 1))
          send (Object [("op", String "receive"), ("id", Int n)])
          pure (call "next" [] >>= decodeMessage)
      , interrupt = void (call "interrupt" [])
      , disconnect = void (call "disconnect" [])
      , release = do
          clean <- channelClose s config.grace
          killThread dispatcher
          pure clean
      }

-- ---------------------------------------------------------------------------
-- Operations

-- | One started Claude Turn (@_Operation@).
data ClaudeOperation = ClaudeOperation
  { adapter :: ClaudeRuntimeAdapter
  , inv :: ClaudeRuntimeInvocation
  , key :: Text
  , prior :: Maybe ClaudeContinuationPayloadV1
  , factory :: ClaudeClientFactory
  , monitor :: MVar ()
  , cancelled :: TVar Bool
  , publishing :: TVar Bool
  , result :: TVar (Maybe RuntimeTurnSettlement)
  , cleanupDisposition :: TVar RuntimeCleanupDisposition
  , cleanup :: TVar (Maybe RuntimeOperationCleanup)
  , finished :: TVar Bool
  }

instance Eq ClaudeOperation where
  a == b = a.result == b.result

instance Show ClaudeOperation where
  show = T.unpack . renderClaudeOperation

renderClaudeOperation :: ClaudeOperation -> Text
renderClaudeOperation o = "_Operation(operation_id=" <> pyStrRepr o.inv.operationId <> ")"

claudeOperationId :: ClaudeOperation -> Text
claudeOperationId o = o.inv.operationId

guarded :: ClaudeOperation -> IO a -> IO a
guarded o action = withMVar o.monitor (const action)

operationCurrent :: ClaudeOperation -> IO Bool
operationCurrent o = not <$> readTVarIO o.cancelled

runOperation :: ClaudeOperation -> IO ()
runOperation o = do
  outcome <- try (execute o.adapter o)
  (settlement, disposition) <- case outcome of
    Right value -> pure value
    Left (_ :: SomeException) -> do
      failed <- settle o.inv TurnFailed 0 "runtime-failed" Nothing Nothing
      pure (failed, RuntimeCleanupUnverified)
  guarded o $ do
    wasCancelled <- readTVarIO o.cancelled
    settlement' <-
      if wasCancelled && settlement.outcome /= TurnCancelled
        then settle o.inv TurnCancelled 0 "cancelled" Nothing Nothing
        else pure settlement
    atomically $ do
      writeTVar o.result (Just settlement')
      writeTVar o.cleanupDisposition disposition

-- | @_Operation.claim@: the last cancellation point before publication.
claim :: ClaudeOperation -> IO (Maybe Text)
claim o = guarded o $ do
  wasCancelled <- readTVarIO o.cancelled
  if wasCancelled
    then pure (Just "cancelled")
    else do
      grant <- currentGrant (Episode.grants o.inv.attachment)
      case grant of
        Just g | g.grantEpoch == o.inv.grantEpoch -> do
          now <- o.adapter.clock
          if now >= min (Episode.episodeDeadline o.inv.attachment) g.deadline
            then pure (Just "deadline-exceeded")
            else do
              current <- leaseObserved (Episode.episodeBinding o.inv.attachment)
              if current
                then atomically (writeTVar o.publishing True) >> pure Nothing
                else pure (Just "runtime-local-lease-required")
        _ -> pure (Just "grant-mismatch")

-- | Whether the binding's lease is still the exact ready lease its
-- provider reports.
leaseObserved :: AttachmentBinding -> IO Bool
leaseObserved binding = case binding.motus of
  Nothing -> pure False
  Just motus -> do
    observed <- try $ do
      provider <- bindingProvider motus
      providerLookup provider (identityOperationId (bindingLeaseIdentity motus))
    case observed of
      Left (e :: SomeException) -> if isAsync e then throwIO e else pure False
      Right Nothing -> pure False
      Right (Just found) -> pure (leaseIdentity found == bindingLeaseIdentity motus && leaseState found == Ready)

-- | @wait(timeout)@.
waitClaudeOperation :: ClaudeOperation -> Maybe Double -> IO RuntimeTurnSettlement
waitClaudeOperation o bound = do
  forM_ bound $ \t ->
    when (isNaN t || isInfinite t || t <= 0) $ throwIO (valueError "Claude operation wait timeout must be positive and finite")
  closedAlready <- isJust <$> readTVarIO o.cleanup
  when closedAlready $ throwIO (runtimeProtocolError "operation-closed")
  expired <- case bound of
    Nothing -> newTVarIO False
    Just t -> registerDelay (micros t)
  settled <-
    atomically $
      (readTVar o.result >>= maybe retry (pure . Just))
        `orElse` (readTVar expired >>= \e -> if e then pure Nothing else retry)
  maybe (throwAgenticus TimeoutError "Claude operation has not settled") pure settled

-- | @cancel(reason)@.
cancelClaudeOperation :: ClaudeOperation -> Text -> IO CancellationDisposition
cancelClaudeOperation o reason = do
  _ <- throwLeft (claudeText "Claude cancellation reason" 256 reason)
  disposition <- guarded o $ do
    settled <- isJust <$> readTVarIO o.result
    publishing <- readTVarIO o.publishing
    wasCancelled <- readTVarIO o.cancelled
    if
      | settled || publishing -> pure CancellationTooLate
      | wasCancelled -> pure CancellationAlreadyRequested
      | otherwise -> atomically (writeTVar o.cancelled True) >> pure CancellationRequested
  when (disposition == CancellationRequested) $
    Episode.cancel o.inv.attachment reason `catch` \(e :: SomeException) -> when (isAsync e) (throwIO e)
  pure disposition

-- | @close()@.
closeClaudeOperation :: ClaudeOperation -> IO RuntimeOperationCleanup
closeClaudeOperation o = do
  existing <- guarded o $ do
    existing <- readTVarIO o.cleanup
    settled <- isJust <$> readTVarIO o.result
    wasCancelled <- readTVarIO o.cancelled
    when (isNothing existing && not settled && not wasCancelled) $ throwIO (runtimeProtocolError "operation-active")
    pure existing
  case existing of
    Just evidence -> pure evidence
    Nothing -> do
      let config = o.adapter.config
      _ <- timeout (micros (config.disconnectTimeout + config.cancellationGrace)) (atomically (readTVar o.finished >>= check))
      done <- readTVarIO o.finished
      disposition <- if done then readTVarIO o.cleanupDisposition else pure RuntimeCleanupUnverified
      let code = case disposition of
            RuntimeCleanupNotCreated -> "client-not-created"
            RuntimeCleanupClean -> "client-closed"
            RuntimeCleanupUnverified -> "cleanup-uncertain"
      evidence <- throwLeft (mkRuntimeOperationCleanup o.inv.operationId disposition code False)
      atomically $
        readTVar o.cleanup >>= \case
          Just earlier -> pure earlier
          Nothing -> writeTVar o.cleanup (Just evidence) >> pure evidence

-- | The operation as the provider-neutral 'RuntimeOperation' record.
claudeRuntimeOperation :: ClaudeOperation -> RuntimeOperation
claudeRuntimeOperation o =
  RuntimeOperation
    { operationId = o.inv.operationId
    , wait = waitClaudeOperation o
    , cancel = cancelClaudeOperation o
    , close = closeClaudeOperation o
    }

-- ---------------------------------------------------------------------------
-- The adapter

-- | What @importlib.import_module("claude_agent_sdk")@ exposes to the probe:
-- its @__file__@, which required attributes it has, and the
-- @ClaudeAgentOptions@ signature's parameters.
data ClaudeSdkSurface = ClaudeSdkSurface
  { file :: Maybe FilePath
  , attributes :: Set Text
  , parameters :: Set Text
  }

-- | The probe's environment: @importlib.metadata.version("claude-agent-sdk")@
-- ('Nothing' for @PackageNotFoundError@), the SDK import ('Nothing' when it
-- raises), and the SDK the ready probe wraps in 'officialFactory'.
data ClaudeProbeHooks = ClaudeProbeHooks
  { installedSdkVersion :: IO (Maybe Text)
  , importSdk :: IO (Maybe ClaudeSdkSurface)
  , sdk :: ClaudeSdk
  }

-- | The official environment through the sidecar.
officialClaudeProbeHooks :: ClaudeSidecar -> ClaudeProbeHooks
officialClaudeProbeHooks s =
  ClaudeProbeHooks
    { installedSdkVersion =
        once "version" >>= \case
          Just frame | Just (String v) <- member "version" frame -> pure (Just v)
          _ -> pure Nothing
    , importSdk =
        once "probe" >>= \case
          Just frame | Just surface@(Object _) <- member "surface" frame -> do
            let texts name = case member name surface of
                  Just (Array values) -> Set.fromList [t | String t <- values]
                  _ -> Set.empty
                file = case member "file" surface of
                  Just (String path) -> Just (T.unpack path)
                  _ -> Nothing
            pure (Just (ClaudeSdkSurface file (texts "attributes") (texts "parameters")))
          _ -> pure Nothing
    , sdk = sidecarSdk s
    }
  where
    once mode = do
      command <- sidecarCommand s mode
      runSidecarOnce command 10 >>= \case
        Just (ExitSuccess, [value]) -> pure (Just value)
        _ -> pure Nothing

-- | The adapter's keyword arguments: @clock@, @client_factory@, the probe
-- environment, and the interpreter the private CLI launcher runs under
-- (the reference uses @sys.executable@).
data ClaudeAdapterOptions = ClaudeAdapterOptions
  { clock :: IO Double
  , clientFactory :: Maybe ClaudeClientFactory
  , hooks :: ClaudeProbeHooks
  , interpreter :: FilePath
  }

-- | The monotonic clock, the official sidecar, and the absolute @python3@
-- on @PATH@.
claudeAdapterOptions :: IO ClaudeAdapterOptions
claudeAdapterOptions = do
  python <- fromMaybe "/usr/bin/python3" <$> findExecutable "python3"
  pure (ClaudeAdapterOptions getMonotonicTime Nothing (officialClaudeProbeHooks claudeSidecar) python)

data Readiness = Readiness
  { installation :: Maybe RuntimeInstallation
  , cli :: Maybe FilePath
  , factory :: Maybe ClaudeClientFactory
  }

data ClaudeRuntimeAdapter = ClaudeRuntimeAdapter
  { config :: ClaudeRuntimeConfig
  , codec :: ClaudeContinuationCodec
  , turns :: ClaudeTurnOperations
  , custody :: PiConnectionCustody
  , clock :: IO Double
  , hooks :: ClaudeProbeHooks
  , interpreter :: FilePath
  , readiness :: MVar Readiness
  , operations :: MVar (Map Text ClaudeOperation)
  }

-- | @ClaudeRuntimeAdapter(config, codec, turns, custody, clock=...,
-- client_factory=...)@.
newClaudeRuntimeAdapter
  :: ClaudeRuntimeConfig -> ClaudeContinuationCodec -> ClaudeTurnOperations -> PiConnectionCustody -> ClaudeAdapterOptions -> IO ClaudeRuntimeAdapter
newClaudeRuntimeAdapter config0 codec turns custody options = do
  config <- newClaudeRuntimeConfig config0
  readiness <- newMVar (Readiness Nothing Nothing options.clientFactory)
  operations <- newMVar Map.empty
  pure
    ClaudeRuntimeAdapter
      { config
      , codec
      , turns
      , custody
      , clock = options.clock
      , hooks = options.hooks
      , interpreter = options.interpreter
      , readiness
      , operations
      }

claudeAdapterConfig :: ClaudeRuntimeAdapter -> ClaudeRuntimeConfig
claudeAdapterConfig a = a.config

-- | Assign @adapter._installation@ and @adapter._cli@.
setClaudeReady :: ClaudeRuntimeAdapter -> Maybe RuntimeInstallation -> Maybe FilePath -> IO ()
setClaudeReady a installation cli = modifyMVar_ a.readiness (\r -> pure r {installation, cli})

-- | @repr(adapter)@.
renderClaudeRuntimeAdapter :: ClaudeRuntimeAdapter -> IO Text
renderClaudeRuntimeAdapter a = do
  ready <- isJust . (.installation) <$> readMVar a.readiness
  pure ("ClaudeRuntimeAdapter(model=" <> pyStrRepr a.config.model <> ", ready=" <> (if ready then "True" else "False") <> ")")

-- | @probe(cli_path=...)@: the exact SDK/CLI pair and the SDK's public
-- protocol, without materialization or model use.
probeClaude :: ClaudeRuntimeAdapter -> Maybe FilePath -> IO RuntimeProbeResult
probeClaude a cliPath = do
  let identity = claudeA2Local.identity
      verdict disposition installation issues cli factory = do
        issues' <- throwLeft (traverse (\(c, comp) -> mkProbeIssue c (Just comp)) issues)
        result <- throwLeft (mkRuntimeProbeResult identity disposition installation issues')
        modifyMVar_ a.readiness $ \r ->
          let ready = if disposition == ProbeReady then installation else Nothing
           in pure r {installation = ready, cli = if isJust ready then cli else Nothing, factory = maybe r.factory Just factory}
        pure result
  a.hooks.installedSdkVersion >>= \case
    Nothing -> verdict ProbeNotInstalled Nothing [("sdk-not-installed", "claude-agent-sdk")] Nothing Nothing
    Just version ->
      a.hooks.importSdk >>= \case
        Nothing -> verdict ProbeUnavailable Nothing [("sdk-unavailable", "claude-agent-sdk")] Nothing Nothing
        Just surface -> do
          selected <- case cliPath of
            Just path | not (null path) -> pure (Just path)
            _ ->
              bundledCli surface.file >>= \case
                Just path -> pure (Just path)
                Nothing -> findExecutable "claude"
          case selected of
            Nothing -> verdict ProbeNotInstalled Nothing [("client-not-installed", "claude")] Nothing Nothing
            Just cli ->
              runVersion cli >>= \case
                Nothing -> verdict ProbeUnavailable Nothing [("client-unavailable", "claude")] Nothing Nothing
                Just output -> do
                  let cliVersion' = fromMaybe "unparseable" (firstVersion (pyStrip output))
                  (system, machine') <- observedPlatform
                  components <-
                    throwLeft . sequence $
                      [ mkInstalledComponent "claude-agent-sdk" version claudeSdkSource
                      , mkInstalledComponent "claude-code" cliVersion' claudeCodeSource
                      ]
                  installation <-
                    throwLeft $
                      mkRuntimeInstallation
                        identity
                        1
                        components
                        system
                        machine'
                        (Set.fromList ["runtime.cancel", "runtime.continue", "runtime.local", "runtime.provider-managed"])
                  if
                    | version /= claudeSdkVersion || cliVersion' /= claudeCodeVersion ->
                        verdict ProbeIncompatible (Just installation) [("version-mismatch", "claude")] Nothing Nothing
                    | not (all (`Set.member` surface.attributes) claudeRequiredAttributes)
                        || not (Set.fromList claudeOptionFields `Set.isSubsetOf` surface.parameters) ->
                        verdict ProbeUnavailable (Just installation) [("protocol-unavailable", "claude-agent-sdk")] Nothing Nothing
                    | otherwise -> do
                        absolute <- makeAbsolute cli
                        verdict ProbeReady (Just installation) [] (Just absolute) (Just (officialFactory a.hooks.sdk))
  where
    runVersion cli = do
      outcome <- try (runBounded (proc cli ["--version"]))
      case outcome of
        Right (Just (ExitSuccess, output, _)) -> case TE.decodeUtf8' output of
          Right text -> pure (Just text)
          Left _ -> throwAgenticus (OtherError "UnicodeDecodeError") "'utf-8' codec can't decode the Claude version output"
        Right _ -> pure Nothing
        Left (_ :: IOException) -> pure Nothing

-- | @_bundled_cli(sdk)@.
bundledCli :: Maybe FilePath -> IO (Maybe FilePath)
bundledCli = \case
  Nothing -> pure Nothing
  Just source -> do
    found <- try $ do
      root <- takeDirectory <$> canonicalizePath source
      firstFile [root </> "_bundled" </> "claude", root </> "_bundled" </> "claude.exe"]
    pure $ case found of
      Right value -> value
      Left (_ :: IOException) -> Nothing
  where
    firstFile = \case
      [] -> pure Nothing
      path : rest -> doesFileExist path >>= \isFile -> if isFile then pure (Just path) else firstFile rest

-- | @start(invocation)@: the same handle for an identical redelivery.
startClaude :: ClaudeRuntimeAdapter -> ClaudeRuntimeInvocation -> IO ClaudeOperation
startClaude a inv0 = do
  inv <- newClaudeRuntimeInvocation inv0
  ready <- readMVar a.readiness
  factory <- case (ready.installation, ready.cli, ready.factory) of
    (Just _, Just _, Just factory) -> pure factory
    _ -> throwIO (runtimeProtocolError "runtime-not-ready")
  validate inv
  forM_ inv.continuation $ \c ->
    when (c.state /= ContinuationInUse) $ throwIO (runtimeProtocolError "continuation-not-claimed")
  prior <- traverse (claudeCodecLoad a.codec) inv.continuation
  forM_ prior $ \p ->
    when (p.projectBinding /= projectBinding a.config.workingDirectory) $
      throwIO (runtimeProtocolError "continuation-project-mismatch")
  coords <- Episode.coordinates inv.attachment
  let text = pyStrRepr
      number = T.pack . show
      optional f = maybe "None" f
      identity =
        "("
          <> T.intercalate
            ", "
            [ text (lifecycleIdText inv.episodeId)
            , text (lifecycleIdText inv.turnId)
            , text (sha256Hex (TE.encodeUtf8 inv.prompt))
            , text inv.connection.identity.connectionId
            , number inv.connection.authorityEpoch
            , number inv.connection.stateVersion
            , text coords.attachmentId
            , number coords.attachmentEpoch
            , number inv.grantEpoch
            , text a.config.model
            , optional (text . lifecycleIdText . (.id)) inv.continuation
            , optional (text . lifecycleIdText . (.thread)) inv.continuation
            , optional (text . sha256Hex . TE.encodeUtf8 . (.stateReference)) inv.continuation
            , optional (text . (.sessionId)) prior
            , optional (text . sha256Hex . (.transcript)) prior
            ]
          <> ")"
      key = sha256Hex (TE.encodeUtf8 identity)
  mask_ $ do
    registered <- modifyMVar a.operations $ \known -> case Map.lookup inv.operationId known of
      Just old
        | old.key /= key -> throwIO (runtimeProtocolError "operation-conflict")
        | otherwise -> pure (known, Left old)
      Nothing -> do
        operation <- newOperation inv key prior factory
        pure (Map.insert inv.operationId operation known, Right operation)
    case registered of
      Left old -> pure old
      Right operation -> do
        void (forkIO (runOperation operation `finally` atomically (writeTVar operation.finished True)))
        pure operation
  where
    newOperation inv key prior factory = do
      monitor <- newMVar ()
      cancelled <- newTVarIO False
      publishing <- newTVarIO False
      result <- newTVarIO Nothing
      cleanupDisposition <- newTVarIO RuntimeCleanupUnverified
      cleanup <- newTVarIO Nothing
      finished <- newTVarIO False
      pure ClaudeOperation {adapter = a, inv, key, prior, factory, monitor, cancelled, publishing, result, cleanupDisposition, cleanup, finished}
    validate inv = do
      let expected =
            [ (KindRuntime, claudeA2Local.identity)
            , (KindConnection, connectionId')
            , (KindProgram, programId)
            , (KindHands, handsId)
            , (KindTerritory, territoryId)
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
      let binding = Episode.episodeBinding inv.attachment
      local <- case binding.motus of
        Nothing -> pure False
        Just motus -> do
          lease <- attachmentLease <$> bindingExecution motus
          pure (leaseState lease == Ready && leaseProvider lease == "local-process")
      current <- if local then leaseObserved binding else pure False
      unless current $ throwIO (runtimeProtocolError "runtime-local-lease-required")

settle :: ClaudeRuntimeInvocation -> TurnOutcome -> Integer -> Text -> Maybe Text -> Maybe Text -> IO RuntimeTurnSettlement
settle inv outcome appends code output continuation =
  throwLeft (mkRuntimeTurnSettlement inv.episodeId inv.turnId outcome appends code output continuation)

data Exec = Exec
  { materialization :: Maybe PiMaterialization
  , client :: Maybe ClaudeClient
  , created :: Maybe ClaudeClient
  , root :: Maybe (FilePath, Maybe (Integer, Integer))
  , attempted :: Bool
  , clean :: Bool
  , outcome :: TurnOutcome
  , code :: Text
  , outputRef :: Maybe Text
  , continuationRef :: Maybe Text
  }

protocol :: Text -> IO a
protocol = throwIO . runtimeProtocolError

-- | @asyncio.wait_for(action, seconds)@.
within :: Double -> IO a -> IO a
within seconds action =
  timeout (micros seconds) action >>= maybe (throwAgenticus TimeoutError "Claude SDK call timed out") pure

-- | @_execute@: authority, private root, client, drain, claim, admission and
-- publication, with cleanup and release precedence kept explicit.
execute :: ClaudeRuntimeAdapter -> ClaudeOperation -> IO (RuntimeTurnSettlement, RuntimeCleanupDisposition)
execute a operation = do
  let config = a.config
      inv = operation.inv
      prior = operation.prior
      ids name = inv.operationId <> "." <> name
  store <- newSessionStore config.maxMessages config.maxTranscriptBytes ((.projectKey) <$> prior) ((.sessionId) <$> prior)
  started <- getMonotonicTime
  now0 <- a.clock
  let hardDeadline = started + min config.wallTimeout (max 0 (Episode.episodeDeadline inv.attachment - now0))
      remaining = do
        now <- getMonotonicTime
        let value = hardDeadline - now
        when (value <= 0) $ protocol "deadline-exceeded"
        pure value
      live = do
        current <- operationCurrent operation
        unless current $ protocol "cancelled"
  state <- newIORef (Exec Nothing Nothing Nothing Nothing False True TurnFailed "runtime-failed" Nothing Nothing)
  let set f = modifyIORef' state f
      body = do
        forM_ prior $ \p -> storeSeed store p.transcript
        live
        ttl <- min config.credentialTtl <$> remaining
        set (\s -> s {attempted = True})
        materialization <- a.custody.materialize inv.connection.identity.connectionId config.hostId LeaseRead ttl (ids "materialize")
        set (\s -> s {materialization = Just materialization})
        when (materialization.mode /= LeaseRead) $ protocol "custody-materialization-mismatch"
        let fence = materialization.fence
        when
          ( (fence.connectionId, fence.hostId, fence.authorityEpoch, fence.baseVersion)
              /= (inv.connection.identity.connectionId, config.hostId, inv.connection.authorityEpoch, inv.connection.stateVersion)
          )
          $ protocol "custody-state-mismatch"
        live
        credential <- materialization.home.read
        when (B.null credential || B.length credential > 8192) $ protocol "credential-invalid"
        apiKey <- case TE.decodeUtf8' credential of
          Right value | isBoundedText 8192 value -> pure value
          _ -> protocol "credential-invalid"
        rootPath <- createTempDirectory config.runtimeRoot "operation-"
        set (\s -> s {root = Just (rootPath, Nothing)})
        Files.setFileMode rootPath 0o700
        metadata <- Files.getSymbolicLinkStatus rootPath
        uid <- getEffectiveUserID
        when (not (Files.isDirectory metadata) || Files.fileMode metadata .&. 0o777 /= 0o700 || Files.fileOwner metadata /= uid) $
          protocol "private-root-invalid"
        set (\s -> s {root = Just (rootPath, Just (toInteger (Files.deviceID metadata), toInteger (Files.fileID metadata)))})
        cli <- (.cli) <$> readMVar a.readiness >>= maybe (protocol "runtime-not-ready") pure
        wrapper <- installCliWrapper a.interpreter rootPath cli
        let environment = claudeAuthEnvironment <> [("ANTHROPIC_API_KEY", apiKey), ("CLAUDE_CONFIG_DIR", T.pack rootPath)]
            options =
              ClaudeOptions
                { values =
                    [ ("tools", Array (map String claudeTools))
                    , ("allowed_tools", Array (map String claudeTools))
                    , ("strict_mcp_config", Bool True)
                    , ("permission_mode", String "dontAsk")
                    , ("setting_sources", Array [])
                    , ("skills", Array [])
                    , ("plugins", Array [])
                    , ("agents", Object [])
                    , ("model", String config.model)
                    , ("fallback_model", Null)
                    , ("cwd", String (T.pack config.workingDirectory))
                    , ("cli_path", String (T.pack wrapper))
                    , ("env", Object [(k, String v) | (k, v) <- environment])
                    , ("max_turns", Int (toInteger config.maxTurns))
                    , ("max_budget_usd", numberJson config.maxBudgetUsd)
                    , ("max_buffer_size", Int (toInteger config.maxMessageBytes))
                    , ("session_store_flush", String "eager")
                    , ("resume", maybe Null (String . (.sessionId)) prior)
                    ]
                , sessionStore = store
                , stderr = DiscardProviderStderr
                }
        client <- operation.factory.create options inv.gateway inv
        set (\s -> s {client = Just client, created = Just client})
        remaining >>= \r -> within r client.connect
        live
        remaining >>= \r -> within r (client.query inv.prompt)
        events <- drain config operation client hardDeadline
        within config.disconnectTimeout client.disconnect
        set (\s -> s {client = Nothing})
        broken <- storeFailed store
        let results = [r | MessageResult r <- events]
            mirror = not (null [() | MessageMirrorError _ <- events])
        when (mirror || broken) $ protocol "session-store-failed"
        result <- case results of
          [single] -> pure single
          _ -> protocol "result-cardinality"
        session <- case result.sessionId of
          String value -> throwLeft (claudeUuid value)
          _ -> throwIO (valueError "Claude session identity must be bounded non-empty text")
        forM_ prior $ \p -> when (session /= p.sessionId) $ protocol "session-mismatch"
        (projectKey, transcript) <- storeSnapshot store session
        live
        if result.subtype /= String "success" || pyTruthy result.isError || result.terminalReason /= String "completed"
          then set (\s -> s {code = "provider-failed"})
          else do
            claim operation >>= maybe (pure ()) protocol
            admission <- a.custody.admitResult fence (ids "admit")
            when (admission.operationId /= ids "admit" || admission.purpose /= "result" || admission.attachmentId /= fence.attachmentId) $
              protocol "custody-admission-mismatch"
            text <- case result.text of
              String value -> either protocol pure (sanitize config.maxMessageBytes value)
              _ -> protocol "malformed-result"
            output <- a.turns.storeTurn inv.operationId text >>= throwLeft . claudeText "Claude output reference" 512
            payload <- throwLeft (mkClaudeContinuationPayloadV1 session (projectBinding config.workingDirectory) projectKey transcript)
            continuation <- claudeCodecStore a.codec inv.operationId payload
            set (\s -> s {outputRef = Just output, continuationRef = Just continuation, outcome = TurnCompleted, code = "turn-completed"})
  outcome <- try body
  escaped <- case outcome of
    Right () -> pure Nothing
    Left (e :: SomeException)
      | isAsync e -> pure (Just e)
      | otherwise -> do
          current <- operationCurrent operation
          let agenticus = fromException e :: Maybe AgenticusError
              code
                | Just failure <- agenticus, Just c <- runtimeProtocolErrorCode failure = c
                | Just failure <- agenticus, failure.errorClass == TimeoutError = "deadline-exceeded"
                | otherwise = "provider-failed"
              cancelled = not current || code == "cancelled"
          set (\s -> s {code = if cancelled then "cancelled" else code, outcome = if cancelled then TurnCancelled else TurnFailed})
          pure Nothing
  -- finally
  s <- readIORef state
  forM_ s.client $ \client -> do
    disconnected <- try (within config.disconnectTimeout client.disconnect)
    case disconnected of
      Right () -> pure ()
      Left (e :: SomeException) -> if isAsync e then throwIO e else set (\x -> x {clean = False})
  forM_ s.created $ \client -> do
    released <- client.release `catch` \(e :: SomeException) -> if isAsync e then throwIO e else pure False
    set (\x -> x {clean = released && x.clean})
  forM_ s.root $ \(path, identity) -> do
    removed <- removePrivateRoot path identity
    set (\x -> x {clean = removed && x.clean})
  forM_ s.materialization $ \materialization -> do
    verified <-
      (releaseVerified <$> a.custody.release materialization (ids "release") <*> pure (ids "release") <*> pure materialization.fence.attachmentId)
        `catch` \(e :: SomeException) -> if isAsync e then throwIO e else pure False
    set (\x -> x {clean = verified && x.clean})
  forM_ escaped throwIO
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
          final.outputRef
          final.continuationRef
      pure (settlement, if final.attempted then RuntimeCleanupClean else RuntimeCleanupNotCreated)

-- | @_drain@: receive in its own thread while polling cancellation and the
-- hard deadline every 50 ms; interrupt once, then bound the interrupt's
-- grace.
drain :: ClaudeRuntimeConfig -> ClaudeOperation -> ClaudeClient -> Double -> IO [ClaudeMessage]
drain config operation client hardDeadline = do
  events <- newIORef (Seq.empty :: Seq ClaudeMessage, 0 :: Int)
  done <- newEmptyTMVarIO
  let receive = do
        next <- client.receiveResponse
        let loop =
              next >>= \case
                Nothing -> pure ()
                Just message -> do
                  let size = messageSize message
                  when (size < 0) $ protocol "malformed-message"
                  when (size > config.maxMessageBytes) $ protocol "message-overflow"
                  (seen, total) <- readIORef events
                  let total' = total + size
                  when (Seq.length seen >= config.maxMessages || total' > config.maxTranscriptBytes) $ protocol "message-overflow"
                  writeIORef events (seen Seq.|> message, total')
                  loop
        loop
  task <- mask $ \restore -> forkIO (try (restore receive) >>= atomically . putTMVar done)
  let poll stop interrupted grace = do
        finished <- atomically (tryReadTMVar done)
        case finished of
          Just outcome -> do
            either (throwIO :: SomeException -> IO ()) pure outcome
            forM_ stop protocol
            toList . fst <$> readIORef events
          Nothing -> do
            now <- getMonotonicTime
            stop' <- case stop of
              Just c -> pure (Just c)
              Nothing -> do
                current <- operationCurrent operation
                pure $
                  if
                    | not current -> Just "cancelled"
                    | now >= hardDeadline -> Just "deadline-exceeded"
                    | otherwise -> Nothing
            (interrupted', grace') <-
              if isJust stop' && not interrupted
                then do
                  box <- newEmptyMVar
                  -- @asyncio.shield@: a timed-out interrupt keeps running.
                  _ <- forkIO (try client.interrupt >>= putMVar box)
                  answered <- timeout (micros config.cancellationGrace) (takeMVar box)
                  case answered of
                    Just (Right ()) -> pure ()
                    Just (Left (e :: SomeException)) | isAsync e -> throwIO e
                    _ -> protocol "interrupt-failed"
                  t <- getMonotonicTime
                  pure (True, Just (t + config.cancellationGrace))
                else pure (interrupted, grace)
            now' <- getMonotonicTime
            forM_ grace' $ \g -> when (now' >= g) $ protocol (fromMaybe "deadline-exceeded" stop')
            let bound = case (stop', grace') of
                  (Nothing, _) -> min 0.05 (max 0.001 (hardDeadline - now'))
                  (Just _, Just g) -> min 0.05 (max 0.001 (g - now'))
                  _ -> 0.05
            _ <- timeout (micros bound) (atomically (readTMVar done))
            poll stop' interrupted' grace'
  poll Nothing False Nothing `finally` do
    stillRunning <- atomically (isEmptyTMVar done)
    when stillRunning $ do
      killThread task
      void (atomically (readTMVar done))

releaseVerified :: ReleaseResult -> Text -> Text -> Bool
releaseVerified value operationId attachmentId =
  value.operationId == operationId
    && value.cleanup.attachmentId == attachmentId
    && (value.cleanup.removed || value.cleanup.alreadyAbsent)
    && not value.cleanup.securityViolation

-- | @_remove_private_root(path, identity)@: an absent identity skips only
-- the device/inode check.
removePrivateRoot :: FilePath -> Maybe (Integer, Integer) -> IO Bool
removePrivateRoot path identity = do
  status <- try (Files.getSymbolicLinkStatus path)
  case status of
    Left e
      | isDoesNotExistError e -> pure True
      | otherwise -> pure False
    Right metadata -> do
      uid <- getEffectiveUserID
      if Files.isSymbolicLink metadata
        || not (Files.isDirectory metadata)
        || Files.fileOwner metadata /= uid
        || Files.fileMode metadata .&. 0o777 /= 0o700
        || maybe False (/= (toInteger (Files.deviceID metadata), toInteger (Files.fileID metadata))) identity
        then pure False
        else do
          removed <- try (removeDirectoryRecursive path)
          case removed of
            Left (_ :: IOException) -> pure False
            Right () -> not <$> present
  where
    present = (True <$ Files.getSymbolicLinkStatus path) `catch` \(_ :: IOException) -> pure False

-- | The @claude-launcher@ source @_install_cli_wrapper@ writes, with the
-- interpreter given explicitly.
cliWrapperSource :: FilePath -> FilePath -> FilePath -> Text
cliWrapperSource python root cli =
  T.unlines
    [ "#!" <> T.pack python <> " -I"
    , "import os"
    , "import sys"
    , ""
    , "source = os.environ"
    , "home = source.get(\"CLAUDE_CONFIG_DIR\", " <> pyStrRepr (T.pack root) <> ")"
    , "environment = {"
    , "    \"HOME\": home,"
    , "    \"PATH\": os.defpath,"
    , "    \"LANG\": \"C.UTF-8\","
    , "    \"LC_ALL\": \"C.UTF-8\","
    , "}"
    , "for name in ("
    , "    \"ANTHROPIC_API_KEY\","
    , "    \"CLAUDE_CONFIG_DIR\","
    , "    \"CLAUDE_CODE_ENTRYPOINT\","
    , "    \"CLAUDE_AGENT_SDK_VERSION\","
    , "):"
    , "    if name in source:"
    , "        environment[name] = source[name]"
    , "target = " <> pyStrRepr (T.pack cli)
    , "os.execve(target, [target, *sys.argv[1:]], environment)"
    ]

-- | @_install_cli_wrapper(root, cli)@: an exclusive, no-follow, owned
-- mode-0700 launcher that drops the ambient environment before exec.
installCliWrapper :: FilePath -> FilePath -> FilePath -> IO FilePath
installCliWrapper python root cli = do
  let path = root </> "claude-launcher"
      source = TE.encodeUtf8 (cliWrapperSource python root cli)
  fd <-
    PosixIO.openFd
      path
      PosixIO.WriteOnly
      PosixIO.defaultFileFlags {PosixIO.creat = Just 0o700, PosixIO.exclusive = True, PosixIO.nofollow = True}
  handle <- PosixIO.fdToHandle fd
  ( do
      B.hPut handle source
      hFlush handle
      fileSynchronise fd
      metadata <- Files.getFdStatus fd
      uid <- getEffectiveUserID
      when
        ( not (Files.isRegularFile metadata)
            || Files.fileOwner metadata /= uid
            || Files.linkCount metadata /= 1
            || Files.fileMode metadata .&. 0o777 /= 0o700
        )
        $ protocol "private-root-invalid"
    )
    `finally` hClose handle
  pure path
