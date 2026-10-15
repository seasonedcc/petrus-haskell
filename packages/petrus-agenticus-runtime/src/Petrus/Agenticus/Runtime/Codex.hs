-- | The exact stock Codex A2 Local and A3 Gondolin runtime lanes
-- (@petrus.agenticus.runtime.codex@).
--
-- Codex owns the loop and the rollout format. Agenticus fences connection
-- custody and publishes only opaque rollout and output references; Motus
-- owns the process and the two provider-private file roots (@CODEX_HOME@
-- with @auth.json@, and the rollout transfer root).
--
-- The reference's two adapter classes are one 'CodexRuntimeAdapter' record
-- with a 'CodexLane': 'newCodexRuntimeAdapter' is @CodexRuntimeAdapter@
-- (A2, the @local-process@ provider) and 'newCodexGondolinRuntimeAdapter'
-- is @CodexGondolinRuntimeAdapter@ (A3, an exact Episode-bound Gondolin
-- lease, qualified per attachment by 'probeCodexGondolin'). The private
-- retained-home helper (@_HELPER_SOURCE@) ships verbatim as the data file
-- @codex_helper.py@ and is passed as a Motus command, as upstream does.
-- Connection custody is the record shared with the Pi host
-- ('HostConnectionCustody').
module Petrus.Agenticus.Runtime.Codex
  ( -- * Pins
    codexVersion
  , codexSourceCommit
  , codexNpmIntegrity
  , codexSource
  , codexGondolinVersion
  , codexGondolinSdkVersion
  , codexGondolinImageRef
  , codexGondolinBuildId
  , codexGondolinOciDigest
  , codexGondolinSource
    -- * Descriptors
  , codexContinuationDescriptor
  , codexProgram
  , codexProgramCapabilities
  , codexContinuationCapabilities
  , codexConnectionCapabilities
  , codexCollocatedHands
  , codexLocalTerritory
  , codexGondolinTerritory
  , maxPromptBytes
  , codexRequiredOptions
    -- * Pure protocol pieces
  , codexText
  , codexUuid
  , codexRolloutPath
  , finalText
  , codexHelperSource
  , codexHelperPath
  , parseHelper
  , Candidate (..)
  , parseJsonl
    -- * Continuations
  , CodexContinuationPayloadV1
  , mkCodexContinuationPayloadV1
  , CodexContinuationOperations (..)
  , CodexTurnOperations (..)
  , CodexContinuationCodec
  , codexContinuationCodec
  , codexCodecStore
  , codexCodecLoad
    -- * Configuration and invocations
  , CodexRuntimeConfig (..)
  , codexRuntimeConfig
  , newCodexRuntimeConfig
  , renderCodexRuntimeConfig
  , CodexRuntimeInvocation (..)
  , newCodexRuntimeInvocation
  , renderCodexRuntimeInvocation
    -- * Operations
  , CodexOperation
  , codexOperationId
  , waitCodexOperation
  , cancelCodexOperation
  , closeCodexOperation
  , codexRuntimeOperation
  , renderCodexOperation
    -- * Adapters
  , CodexLane (..)
  , CodexProbeHooks (..)
  , officialCodexProbeHooks
  , CodexAdapterOptions (..)
  , codexAdapterOptions
  , CodexRuntimeAdapter
  , newCodexRuntimeAdapter
  , newCodexGondolinRuntimeAdapter
  , codexAdapterLane
  , codexAdapterConfig
  , renderCodexRuntimeAdapter
  , codexExecutable
  , codexHelperExecutable
  , probeCodex
  , probeCodexGondolin
  , startCodex
  ) where

import Control.Concurrent.MVar
import Control.Exception (IOException, catch, fromException, mask_, throwIO, try)
import Control.Monad (forM_, unless, void, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, ord)
import Data.IORef
import Data.List (nub)
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
import Petrus.Agenticus.Attachment.Binding
  ( AttachmentBinding (..)
  , MotusAttachmentBinding
  , bindingExecute
  , bindingExecution
  , bindingLeaseIdentity
  , bindingProvider
  , withBindingOperation
  )
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
  , PublicationResult (..)
  , ReleaseResult (..)
  )
import Petrus.Agenticus.Connection.Materialization (CleanupEvidence (..))
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Exception
import Petrus.Json.Python (loadsUtf8, pythonStrRepr)
import Petrus.Agenticus.Internal.Validate (checkedText, encodeRefusal, pyIsSpace, sha256Hex, utf8Length)
import Petrus.Agenticus.Program.Descriptor
  ( AgentProgramDescriptor
  , ProgramOwnership (..)
  , agentProgramDescriptor
  , continuationRequirement
  )
import Petrus.Agenticus.Runtime.Custody
import Petrus.Agenticus.Runtime.Internal.Process (BoundedRun (..), ChildEnvironment (..), runBounded)
import Petrus.Agenticus.Runtime.Internal.HostSupport (observedPlatform, outputError, pyJsonLoadsBytes, pyStrip, sanitizeOutput)
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
import Petrus.Agenticus.Runtime.Profiles (codexA2Local, codexA3Gondolin)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement, mkRuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Continuation
  ( Continuation
  , ContinuationDescriptor
  , ContinuationState (..)
  , continuationDescriptor
  )
import Petrus.Agenticus.Thread.Identity (EpisodeId, LifecycleId (..), TurnId)
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Execution
  ( CommandSpec (..)
  , EnvironmentProvider (..)
  , LeaseIdentity
  , LeaseState (..)
  , PrivateFileRef
  , PrivateFileTransfer (..)
  , Seconds (..)
  , attachmentId
  , attachmentLease
  , capPrivateFileTransfer
  , commandSpec
  , leaseCapabilities
  , leaseProvider
  , leaseState
  , maxCommandOutputBytes
  , maxPrivateFileBytes
  , mkCommand
  , mkPrivateFile
  , privateCleanupVerified
  , privateFileContent
  , resultOutputTruncated
  , resultReturncode
  , resultStderr
  , resultStdout
  , resultSuperseded
  , resultTimedOut
  )
import System.Directory (findExecutable, makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)

-- ---------------------------------------------------------------------------
-- Pins

codexVersion, codexSourceCommit, codexNpmIntegrity, codexSource :: Text
codexVersion = "0.145.0"
codexSourceCommit = "1e85ca099e4265bf89f4016772d299816e231bb3"
codexNpmIntegrity = "sha512-/PSPSFujjjmiyVFvG2yu/grOFhsWdokTH8t2KGWhXSo/M5n/dIDsnbsnO82/7bLtIoDuzQf7ATBUMWqPWQINlQ=="
codexSource = "npm:@openai/codex@" <> codexVersion <> "#commit=" <> codexSourceCommit <> "#integrity=" <> codexNpmIntegrity

codexGondolinVersion, codexGondolinSdkVersion, codexGondolinImageRef, codexGondolinBuildId, codexGondolinOciDigest, codexGondolinSource :: Text
codexGondolinVersion = "0.146.0"
codexGondolinSdkVersion = "0.12.0"
codexGondolinImageRef = "petrus-cv10-agents:amp1785543452-codex01460-gondolin0120"
codexGondolinBuildId = "49aac5ff-ea3f-5f46-a67a-cdc613ac4827"
codexGondolinOciDigest = "sha256:9c7e769eb44f37b1e802c55dc43ee222e7b6c907fad3de8c01404a3b6c61124f"
codexGondolinSource = "gondolin:" <> codexGondolinImageRef <> "#build=" <> codexGondolinBuildId <> "#oci=" <> codexGondolinOciDigest

-- ---------------------------------------------------------------------------
-- Descriptors

programId, continuationId, connectionId', handsId, territoryId, gondolinTerritoryId :: DescriptorIdentity
programId = descriptorIdentity KindProgram "codex.provider-managed" 1
continuationId = descriptorIdentity KindContinuation "codex.native-rollout" 1
connectionId' = descriptorIdentity KindConnection "codex.file-auth" 1
handsId = descriptorIdentity KindHands "codex.collocated" 1
territoryId = descriptorIdentity KindTerritory "motus.local" 1
gondolinTerritoryId = descriptorIdentity KindTerritory "motus.gondolin" 1

codexContinuationDescriptor :: ContinuationDescriptor
codexContinuationDescriptor = continuationDescriptor continuationId programId

codexProgram :: AgentProgramDescriptor
codexProgram =
  agentProgramDescriptor
    programId
    ProviderOwned
    True
    [continuationRequirement continuationId programId]
    (Just continuationId)
    False
    False

codexProgramCapabilities
  , codexContinuationCapabilities
  , codexConnectionCapabilities
  , codexCollocatedHands
  , codexLocalTerritory
  , codexGondolinTerritory
    :: CapabilityDescriptor
codexProgramCapabilities = capabilityDescriptor programId ["program.provider-owned"] []
codexContinuationCapabilities = capabilityDescriptor continuationId ["continuation.codex-native"] []
codexConnectionCapabilities = capabilityDescriptor connectionId' ["connection.codex"] []
codexCollocatedHands = capabilityDescriptor handsId ["hands.collocated"] []
codexLocalTerritory = capabilityDescriptor territoryId [] []
codexGondolinTerritory = capabilityDescriptor gondolinTerritoryId [] []

maxPromptBytes :: Int
maxPromptBytes = 64 * 1024

-- | The @codex exec --help@ options the probe requires.
codexRequiredOptions :: [Text]
codexRequiredOptions =
  [ "--json"
  , "--color"
  , "--sandbox"
  , "--config"
  , "--skip-git-repo-check"
  , "--ignore-user-config"
  , "--ignore-rules"
  ]

-- ---------------------------------------------------------------------------
-- Pure protocol pieces

protocolError :: Text -> AgenticusError
protocolError = runtimeProtocolError

protocol :: Text -> IO a
protocol = throwIO . protocolError

-- | @_text(value, name, maximum)@.
codexText :: Text -> Int -> Text -> Either AgenticusError Text
codexText name maximum' = checkedText maximum' (valueError (name <> " must be bounded non-empty text"))

-- | @_uuid(value)@: @UUID(value)@ round-trips to exactly @value@, so only
-- the canonical lower-case hyphenated spelling passes.
codexUuid :: Text -> Either AgenticusError Text
codexUuid value = do
  _ <- codexText "Codex thread identity" 36 value
  if canonical value then Right value else Left (valueError "Codex thread identity must be a canonical UUID")
  where
    canonical v = case T.splitOn "-" v of
      [a, b, c, d, e] -> and (zipWith hexOf [8, 4, 4, 4, 12] [a, b, c, d, e])
      _ -> False
    hexOf n part = T.length part == n && T.all lowerHex part

lowerHex :: Char -> Bool
lowerHex c = isDigit c || (c >= 'a' && c <= 'f')

-- | @_rollout_path(value, thread_id)@: the @_ROLLOUT@ regular expression,
-- fully matched, with its thread group equal to the thread.
codexRolloutPath :: Text -> Text -> Either AgenticusError Text
codexRolloutPath value thread = do
  _ <- codexText "Codex rollout metadata" 256 value
  case rolloutThread value of
    Just found | found == thread -> Right value
    _ -> Left (valueError "Codex rollout metadata must be a safe provider-relative path for its thread")

-- | The thread group of a full @_ROLLOUT@ match.
rolloutThread :: Text -> Maybe Text
rolloutThread value = do
  rest0 <- T.stripPrefix "sessions/" value
  let (year, rest1) = T.splitAt 4 rest0
  ok (T.length year == 4 && T.all isDigit year)
  rest2 <- T.stripPrefix "/" rest1
  let (month, rest3) = T.splitAt 2 rest2
  ok (month `elem` [T.pack (pad m) | m <- [1 .. 12 :: Int]])
  rest4 <- T.stripPrefix "/" rest3
  let (day, rest5) = T.splitAt 2 rest4
  ok (day `elem` [T.pack (pad d) | d <- [1 .. 31 :: Int]])
  rest6 <- T.stripPrefix "/rollout-" rest5
  body <- T.stripSuffix ".jsonl" rest6
  -- @[A-Za-z0-9_.-]+-@ then a fixed-width thread: the thread is the last
  -- 36 characters, after a hyphen that ends a non-empty middle.
  ok (T.length body >= 38)
  let (front, thread) = T.splitAt (T.length body - 36) body
  middle <- T.stripSuffix "-" front
  ok (not (T.null middle) && T.all middleChar middle && uuidShaped thread)
  pure thread
  where
    ok condition = if condition then Just () else Nothing
    pad n = if n < 10 then '0' : show n else show n
    middleChar c = isAsciiUpper c || isAsciiLower c || isDigit c || c `elem` ("_.-" :: String)
    uuidShaped t = case T.splitOn "-" t of
      [a, b, c, d, e] -> and (zipWith (\n part -> T.length part == n && T.all lowerHex part) [8, 4, 4, 4, 12] [a, b, c, d, e])
      _ -> False

-- | @_final_text(value)@ for a string: ANSI escapes removed, control
-- characters replaced, bounded by the Motus output limit. A lone surrogate
-- raises @str.encode()@'s @UnicodeEncodeError@ ('sanitizeOutput').
finalText :: Text -> Either AgenticusError Text
finalText = first (outputError "agent-message-overflow") . sanitizeOutput keep maxCommandOutputBytes
  where
    keep c = c `elem` ("\n\r\t" :: String) || (ord c >= 32 && not (ord c >= 127 && ord c <= 159))

-- | The verbatim @_HELPER_SOURCE@.
codexHelperSource :: IO Text
codexHelperSource = codexHelperPath >>= fmap TE.decodeUtf8 . B.readFile

codexHelperPath :: IO FilePath
codexHelperPath = getDataFileName "data/codex_helper.py"

-- | @_parse_helper(stdout, collect=...)@: the collected @rollout_path@
-- value as the helper printed it ('Nothing' for @stage@ and @scrub@).
parseHelper :: ByteString -> Bool -> Either AgenticusError (Maybe Json)
parseHelper stdout collect = do
  when (B.length stdout > 512) $ Left (protocolError "helper-protocol")
  value <- either (const (Left (protocolError "helper-protocol"))) Right (pyJsonLoadsBytes stdout)
  let expected = Set.fromList (if collect then ["ok", "rollout_path"] else ["ok"])
  case value of
    Object members
      | Set.fromList (map fst members) == expected
      , lookup "ok" members `isExactly` Bool True ->
          Right (if collect then lookup "rollout_path" members else Nothing)
    _ -> Left (protocolError "helper-protocol")
  where
    isExactly (Just (Bool b)) (Bool expected') = b == expected'
    isExactly _ _ = False

-- | @_Candidate@: the provider thread, whether the Turn completed, and the
-- latest sanitized completed agent message.
data Candidate = Candidate
  { threadId :: Text
  , completed :: Bool
  , text :: Maybe Text
  }
  deriving stock (Eq)

-- | @text@ is @repr=False@ upstream.
instance Show Candidate where
  show c =
    "_Candidate(thread_id="
      <> T.unpack (pythonStrRepr c.threadId)
      <> ", completed="
      <> (if c.completed then "True" else "False")
      <> ")"

-- | @_parse_jsonl(raw, returncode)@: exact protocol admission. Protocol
-- failures are 'runtimeProtocolError' codes; an unhashable item @type@ is
-- the reference's uncaught @TypeError@.
parseJsonl :: ByteString -> Int -> Either AgenticusError Candidate
parseJsonl raw returncode = do
  let pieces = B.split 10 raw
      lines' = case reverse pieces of
        "" : rest | not (null pieces) -> reverse rest
        _ -> pieces
  when (null lines' || any B.null lines') $ malformed "malformed-jsonl"
  events <- mapM decodeLine lines'
  typed <- mapM eventType events
  unless (all (`elem` allowed) (map fst typed)) $ malformed "unknown-event"
  let count kind = length (filter ((== kind) . fst) typed)
      terminalKinds = ["turn.completed", "turn.failed"]
      terminals = length (filter ((`elem` terminalKinds) . fst) typed)
      kinds = map fst typed
  when
    ( count "thread.started" /= 1
        || count "turn.started" /= 1
        || terminals /= 1
        || take 1 kinds /= ["thread.started"]
        || take 1 (drop 1 kinds) /= ["turn.started"]
        || not (last kinds `elem` terminalKinds)
    )
    $ malformed "codex-lifecycle"
  let started = snd (head' typed)
      terminal = snd (last typed)
      terminalKind = fst (last typed)
  thread <- case member "thread_id" started of
    Just (String t) | Right v <- codexUuid t -> Right v
    _ -> malformed "malformed-thread-id"
  let isCompleted = terminalKind == "turn.completed"
  when ((isCompleted && returncode /= 0) || (not isCompleted && returncode /= 1)) $ malformed "exit-inconsistent"
  if isCompleted
    then case member "usage" terminal of
      Just (Object _) -> Right ()
      _ -> malformed "malformed-terminal"
    else case member "error" terminal of
      Just failure@(Object _) | Just (String _) <- member "message" failure -> Right ()
      _ -> malformed "malformed-terminal"
  latest <- walk (drop 2 (init typed)) Set.empty Nothing
  when (isCompleted && isNothing latest) $ malformed "missing-agent-message"
  pure (Candidate thread isCompleted latest)
  where
    malformed :: Text -> Either AgenticusError a
    malformed = Left . protocolError
    head' = \case
      x : _ -> x
      [] -> ("", Object [])
    -- @json.loads(line.decode("utf-8"))@: a lone surrogate escape is kept
    -- (WTF-8), as in the reference's @str@.
    decodeLine line = case TE.decodeUtf8' line of
      Left _ -> malformed "malformed-jsonl"
      Right _ -> either (const (malformed "malformed-jsonl")) Right (loadsUtf8 line)
    eventType event = case event of
      Object _ | Just (String t) <- member "type" event -> Right (t, event)
      _ -> malformed "malformed-jsonl"
    allowed :: [Text]
    allowed =
      [ "thread.started"
      , "turn.started"
      , "item.started"
      , "item.updated"
      , "item.completed"
      , "turn.completed"
      , "turn.failed"
      , "error"
      ]
    itemTypes :: [Text]
    itemTypes =
      [ "agent_message"
      , "reasoning"
      , "command_execution"
      , "file_change"
      , "mcp_tool_call"
      , "collab_tool_call"
      , "web_search"
      , "todo_list"
      , "error"
      ]
    walk :: [(Text, Json)] -> Set Text -> Maybe Text -> Either AgenticusError (Maybe Text)
    walk [] _ latest = Right latest
    walk ((kind, event) : rest) seen latest
      | kind == "error" = case member "message" event of
          Just (String _) -> walk rest seen latest
          _ -> malformed "malformed-error"
      | kind `notElem` ["item.started", "item.updated", "item.completed"] = malformed "codex-lifecycle"
      | otherwise = case member "item" event of
          Just item@(Object _)
            | Just (String identifier) <- member "id" item
            , not (T.null identifier) -> do
                itemType <- case member "type" item of
                  Just (String t) | t `elem` itemTypes -> Right t
                  Just (Array _) -> Left (typeError "cannot use 'list' as a set element (unhashable type: 'list')")
                  Just (Object _) -> Left (typeError "cannot use 'dict' as a set element (unhashable type: 'dict')")
                  _ -> malformed "malformed-item"
                if kind == "item.completed"
                  then do
                    when (identifier `Set.member` seen) $ malformed "duplicate-item-terminal"
                    latest' <-
                      if itemType == "agent_message"
                        then case member "text" item of
                          Just (String t) -> Just <$> finalText t
                          _ -> malformed "malformed-agent-message"
                        else Right latest
                    walk rest (Set.insert identifier seen) latest'
                  else walk rest seen latest
          _ -> malformed "malformed-item"

member :: Text -> Json -> Maybe Json
member name = \case
  Object members -> lookup name members
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Continuations

-- | One accepted native rollout behind a Codex Continuation.
data CodexContinuationPayloadV1 = CodexContinuationPayloadV1
  { _threadId :: Text
  , _rolloutPath :: Text
  , _rollout :: ByteString
  }
  deriving stock (Eq)

instance HasField "threadId" CodexContinuationPayloadV1 Text where
  getField r = r._threadId

instance HasField "rolloutPath" CodexContinuationPayloadV1 Text where
  getField r = r._rolloutPath

instance HasField "rollout" CodexContinuationPayloadV1 ByteString where
  getField r = r._rollout

-- | @rollout@ is @repr=False@ upstream.
instance Show CodexContinuationPayloadV1 where
  show p =
    "CodexContinuationPayloadV1(thread_id="
      <> T.unpack (pythonStrRepr p.threadId)
      <> ", rollout_path="
      <> T.unpack (pythonStrRepr p.rolloutPath)
      <> ", schema_version=1)"

mkCodexContinuationPayloadV1 :: Text -> Text -> ByteString -> Either AgenticusError CodexContinuationPayloadV1
mkCodexContinuationPayloadV1 thread path rollout' = do
  thread' <- codexUuid thread
  path' <- codexRolloutPath path thread'
  when (B.null rollout' || B.length rollout' > maxPrivateFileBytes) $
    Left (valueError "Codex rollout must be one non-empty bounded file")
  pure (CodexContinuationPayloadV1 thread' path' rollout')

data CodexContinuationOperations = CodexContinuationOperations
  { store :: Text -> CodexContinuationPayloadV1 -> IO Text
  , load :: Text -> IO CodexContinuationPayloadV1
  }

newtype CodexTurnOperations = CodexTurnOperations
  { storeTurn :: Text -> Text -> Text -> IO Text
  -- ^ operation, thread, final text
  }

newtype CodexContinuationCodec = CodexContinuationCodec CodexContinuationOperations

codexContinuationCodec :: CodexContinuationOperations -> CodexContinuationCodec
codexContinuationCodec = CodexContinuationCodec

codexCodecStore :: CodexContinuationCodec -> Text -> CodexContinuationPayloadV1 -> IO Text
codexCodecStore (CodexContinuationCodec operations) operationId payload = do
  operation <- throwLeft (codexText "Codex operation" 256 operationId)
  reference <- operations.store operation payload
  throwLeft (codexText "state reference" 512 reference)

codexCodecLoad :: CodexContinuationCodec -> Continuation -> IO CodexContinuationPayloadV1
codexCodecLoad (CodexContinuationCodec operations) continuation = do
  when (continuation.descriptor /= codexContinuationDescriptor) $
    throwIO (valueError "Codex Continuation does not match this runtime")
  operations.load continuation.stateReference

-- ---------------------------------------------------------------------------
-- Configuration

-- | @CodexRuntimeConfig@. Build one with 'codexRuntimeConfig' and validate
-- it with 'newCodexRuntimeConfig' (the reference's @__post_init__@).
data CodexRuntimeConfig = CodexRuntimeConfig
  { hostId :: Text
  , credentialTtl :: Double
  , commandTimeout :: Double
  , outputLimit :: Int
  , cancellationGrace :: Double
  }
  deriving stock (Eq)

instance Show CodexRuntimeConfig where
  show = T.unpack . renderCodexRuntimeConfig

-- | The reference's defaults for one enrolled host.
codexRuntimeConfig :: Text -> CodexRuntimeConfig
codexRuntimeConfig hostId = CodexRuntimeConfig hostId 300 300 maxCommandOutputBytes 10

renderCodexRuntimeConfig :: CodexRuntimeConfig -> Text
renderCodexRuntimeConfig c =
  "CodexRuntimeConfig(host_id="
    <> pythonStrRepr c.hostId
    <> ", credential_ttl="
    <> number c.credentialTtl
    <> ", command_timeout="
    <> number c.commandTimeout
    <> ", output_limit="
    <> T.pack (show c.outputLimit)
    <> ", cancellation_grace="
    <> number c.cancellationGrace
    <> ")"
  where
    number d = T.pack (J.pythonFloatRepr d)

newCodexRuntimeConfig :: CodexRuntimeConfig -> IO CodexRuntimeConfig
newCodexRuntimeConfig c = do
  hostId <- throwLeft (codexText "Codex enrolled host" 256 c.hostId)
  forM_ [(c.credentialTtl, "credential TTL"), (c.commandTimeout, "command timeout"), (c.cancellationGrace, "cancellation grace")] $
    \(value, name) ->
      when (isNaN value || isInfinite value || value <= 0) $
        throwIO (valueError ("Codex " <> name <> " must be positive and finite"))
  unless (c.outputLimit > 0 && c.outputLimit <= maxCommandOutputBytes) $
    throwIO (valueError "Codex output limit is outside the Motus command bound")
  pure (CodexRuntimeConfig hostId c.credentialTtl c.commandTimeout c.outputLimit c.cancellationGrace)

-- ---------------------------------------------------------------------------
-- Invocations

-- | One Codex Turn request. Build it with 'newCodexRuntimeInvocation',
-- which runs the reference's @__post_init__@ checks.
data CodexRuntimeInvocation = CodexRuntimeInvocation
  { operationId :: Text
  , episodeId :: EpisodeId
  , turnId :: TurnId
  , prompt :: Text
  , connection :: ConnectionView
  , attachment :: EpisodeAttachment
  , continuation :: Maybe Continuation
  }

instance Show CodexRuntimeInvocation where
  show = T.unpack . renderCodexRuntimeInvocation

-- | @repr(invocation)@: no prompt, attachment or continuation.
renderCodexRuntimeInvocation :: CodexRuntimeInvocation -> Text
renderCodexRuntimeInvocation i =
  "CodexRuntimeInvocation(operation_id="
    <> pythonStrRepr i.operationId
    <> ", episode_id=EpisodeId(value="
    <> pythonStrRepr (lifecycleIdText i.episodeId)
    <> "), turn_id=TurnId(value="
    <> pythonStrRepr (lifecycleIdText i.turnId)
    <> "), connection="
    <> T.pack (show i.connection)
    <> ")"

newCodexRuntimeInvocation :: CodexRuntimeInvocation -> IO CodexRuntimeInvocation
newCodexRuntimeInvocation i = do
  operationId <- throwLeft (codexText "Codex operation" 256 i.operationId)
  let promptRefusal = valueError "Codex prompt must be bounded non-empty text"
  when (T.null i.prompt) $ throwIO promptRefusal
  forM_ (encodeRefusal i.prompt) throwIO
  when (utf8Length i.prompt > maxPromptBytes || T.elem '\0' i.prompt) $ throwIO promptRefusal
  when (i.connection.status /= StatusReady) $ throwIO (valueError "Codex connection must be ready")
  when (i.connection.identity.provider /= "codex" || i.connection.identity.profile /= "file-auth") $
    throwIO (valueError "Codex invocation requires the Codex file-auth profile")
  when (Episode.episodeId i.attachment /= i.episodeId) $
    throwIO (valueError "Codex invocation requires its exact Episode Attachment")
  pure (CodexRuntimeInvocation operationId i.episodeId i.turnId i.prompt i.connection i.attachment i.continuation)

-- ---------------------------------------------------------------------------
-- Operations

-- | @_Key@: everything the operation identity covers.
data OperationKey = OperationKey
  { keyEpisode :: Text
  , keyTurn :: Text
  , keyPrompt :: Text
  , keyConnection :: Text
  , keyAuthorityEpoch :: Integer
  , keyStateVersion :: Integer
  , keyAttachment :: Text
  , keyAttachmentEpoch :: Integer
  , keyContinuationId :: Maybe Text
  , keyContinuationLineage :: Maybe Text
  , keyContinuationReferenceDigest :: Maybe Text
  , keyContinuationThread :: Maybe Text
  , keyContinuationPath :: Maybe Text
  , keyContinuationDigest :: Maybe Text
  }
  deriving stock (Eq)

-- | One started Codex Turn (@_CodexOperation@).
data CodexOperation = CodexOperation
  { owner :: CodexRuntimeAdapter
  , inv :: CodexRuntimeInvocation
  , binding :: MotusAttachmentBinding
  -- ^ The Motus binding 'validateAttachment' accepted at start.
  , key :: OperationKey
  , prior :: Maybe CodexContinuationPayloadV1
  , executable :: FilePath
  , executionPath :: Text
  , lifecycle :: Lifecycle
  }

-- | Handle identity (the reference compares with @is@).
instance Eq CodexOperation where
  a == b = a.lifecycle == b.lifecycle

instance Show CodexOperation where
  show = T.unpack . renderCodexOperation

-- | The reference keeps the default @object.__repr__@; this names only the
-- operation.
renderCodexOperation :: CodexOperation -> Text
renderCodexOperation o = "_CodexOperation(operation_id=" <> pythonStrRepr o.inv.operationId <> ")"

codexOperationId :: CodexOperation -> Text
codexOperationId o = o.inv.operationId

settle :: CodexRuntimeInvocation -> TurnOutcome -> Integer -> Text -> Maybe Text -> Maybe Text -> IO RuntimeTurnSettlement
settle inv outcome appends code output continuation =
  throwLeft (mkRuntimeTurnSettlement inv.episodeId inv.turnId outcome appends code output continuation)

-- | @_run@: borrow the whole territory operation for @_execute@.
runOperation :: CodexOperation -> IO ()
runOperation o = do
  outcome <- trySync (withBindingOperation o.binding (execute o))
  settled <- case outcome of
    Right value -> pure value
    Left e
      | Just (failure :: AgenticusError) <- fromException e
      , failure.errorClass `isSubclassOf` MotusBindingError -> do
          failed <- settle o.inv TurnFailed 0 "runtime-not-ready" Nothing Nothing
          pure (failed, RuntimeCleanupNotCreated)
      | otherwise -> do
          failed <- settle o.inv TurnFailed 0 "runtime-failed" Nothing Nothing
          pure (failed, RuntimeCleanupUnverified)
  Lifecycle.settle o.lifecycle (settle o.inv TurnCancelled 0 "cancelled" Nothing Nothing) settled

operationCurrent :: CodexOperation -> IO Bool
operationCurrent o = Lifecycle.current o.lifecycle

-- | @_claim_publication@.
claimPublication :: CodexOperation -> IO (Maybe Text)
claimPublication o = Lifecycle.claim o.lifecycle $ do
  now <- o.owner.clock
  pure (if now >= Episode.episodeDeadline o.inv.attachment then Just "deadline-exceeded" else Nothing)

-- | @wait(timeout)@.
waitCodexOperation :: CodexOperation -> Maybe Double -> IO RuntimeTurnSettlement
waitCodexOperation o = Lifecycle.waitSettled o.lifecycle

-- | @cancel(reason)@.
cancelCodexOperation :: CodexOperation -> Text -> IO CancellationDisposition
cancelCodexOperation o reason = do
  _ <- throwLeft (codexText "Codex cancellation reason" 256 reason)
  Lifecycle.requestCancel o.lifecycle $
    Episode.cancel o.inv.attachment reason `catch` \(e :: AgenticusError) ->
      unless (e.errorClass `isSubclassOf` EpisodeAttachmentError) (throwIO e)

-- | @close()@.
closeCodexOperation :: CodexOperation -> IO RuntimeOperationCleanup
closeCodexOperation o =
  Lifecycle.closeWith o.lifecycle o.owner.config.cancellationGrace (Lifecycle.settledEvidence o.lifecycle)

-- | The operation as the provider-neutral 'RuntimeOperation' record.
codexRuntimeOperation :: CodexOperation -> RuntimeOperation
codexRuntimeOperation o =
  RuntimeOperation
    { operationId = o.inv.operationId
    , wait = waitCodexOperation o
    , cancel = cancelCodexOperation o
    , close = closeCodexOperation o
    }

-- ---------------------------------------------------------------------------
-- The adapters

-- | Which reference class an adapter is.
data CodexLane
  = -- | @CodexRuntimeAdapter@: the A2 Local lane.
    CodexLocal
  | -- | @CodexGondolinRuntimeAdapter@: the A3 Gondolin lane.
    CodexGondolin
  deriving stock (Eq, Show)

-- | The probe's host environment: @shutil.which@ and the bounded
-- @subprocess.run(argv, capture_output=True, text=True, check=True,
-- timeout=10).stdout@ ('Nothing' for @OSError@ or @SubprocessError@).
data CodexProbeHooks = CodexProbeHooks
  { which :: String -> IO (Maybe FilePath)
  , run :: [String] -> IO (Maybe Text)
  }

officialCodexProbeHooks :: CodexProbeHooks
officialCodexProbeHooks =
  CodexProbeHooks
    { which = findExecutable
    , run = \case
        [] -> pure Nothing
        program : arguments -> do
          outcome <- try (runBounded (program : arguments) InheritEnvironment)
          case outcome of
            Right (Finished ExitSuccess output _) -> case TE.decodeUtf8' output of
              Right value -> pure (Just value)
              Left _ -> throwAgenticus (OtherError "UnicodeDecodeError") "'utf-8' codec can't decode the Codex probe output"
            Right _ -> pure Nothing
            Left (_ :: IOException) -> pure Nothing
    }

-- | The adapter's keyword arguments plus the reference's attributes that
-- tests override: @clock@, the probe environment, the Local helper's
-- interpreter (the reference uses @sys.executable@), the Gondolin guest's
-- helper interpreter, and a wrapper around @start@ (the reference's tests
-- assign @adapter.start@; the Gondolin Activity and runtime service call
-- through it).
data CodexAdapterOptions = CodexAdapterOptions
  { clock :: IO Double
  , hooks :: CodexProbeHooks
  , interpreter :: FilePath
  , guestInterpreter :: FilePath
  , startWrapper :: (CodexRuntimeInvocation -> IO CodexOperation) -> CodexRuntimeInvocation -> IO CodexOperation
  }

-- | The monotonic clock, the host's @PATH@, the absolute @python3@ on
-- @PATH@, the guest's @/usr/bin/python3@, and no start wrapper.
codexAdapterOptions :: IO CodexAdapterOptions
codexAdapterOptions = do
  python <- fromMaybe "/usr/bin/python3" <$> findExecutable "python3"
  pure
    CodexAdapterOptions
      { clock = getMonotonicTime
      , hooks = officialCodexProbeHooks
      , interpreter = python
      , guestInterpreter = "/usr/bin/python3"
      , startWrapper = id
      }

data Readiness = Readiness
  { installation :: Maybe RuntimeInstallation
  , readyExecutable :: Maybe FilePath
  , readyPath :: Maybe Text
  }

data CodexRuntimeAdapter = CodexRuntimeAdapter
  { lane :: CodexLane
  , config :: CodexRuntimeConfig
  , codec :: CodexContinuationCodec
  , turns :: CodexTurnOperations
  , custody :: HostConnectionCustody
  , clock :: IO Double
  , hooks :: CodexProbeHooks
  , helper :: FilePath
  , source :: Text
  , readiness :: MVar Readiness
  , operations :: MVar (Map Text CodexOperation)
  , qualified :: MVar (Set (LeaseIdentity, Text))
  , startWrapper :: (CodexRuntimeInvocation -> IO CodexOperation) -> CodexRuntimeInvocation -> IO CodexOperation
  }

guestExecutable, guestPath :: Text
guestExecutable = "/usr/local/bin/codex"
guestPath = "/usr/local/bin:/usr/bin:/bin"

-- | @CodexRuntimeAdapter(config, codec, turns, custody, clock=...)@.
newCodexRuntimeAdapter
  :: CodexRuntimeConfig -> CodexContinuationCodec -> CodexTurnOperations -> HostConnectionCustody -> CodexAdapterOptions -> IO CodexRuntimeAdapter
newCodexRuntimeAdapter config codec turns custody options = newAdapter CodexLocal options.interpreter config codec turns custody options

-- | @CodexGondolinRuntimeAdapter(config, codec, turns, custody, clock=...)@:
-- the guest helper is the options' guest interpreter.
newCodexGondolinRuntimeAdapter
  :: CodexRuntimeConfig -> CodexContinuationCodec -> CodexTurnOperations -> HostConnectionCustody -> CodexAdapterOptions -> IO CodexRuntimeAdapter
newCodexGondolinRuntimeAdapter config codec turns custody options = newAdapter CodexGondolin options.guestInterpreter config codec turns custody options

newAdapter
  :: CodexLane
  -> FilePath
  -> CodexRuntimeConfig
  -> CodexContinuationCodec
  -> CodexTurnOperations
  -> HostConnectionCustody
  -> CodexAdapterOptions
  -> IO CodexRuntimeAdapter
newAdapter lane helper config0 codec turns custody options = do
  config <- newCodexRuntimeConfig config0
  source <- codexHelperSource
  readiness <- newMVar (Readiness Nothing Nothing Nothing)
  operations <- newMVar Map.empty
  qualified <- newMVar Set.empty
  pure
    CodexRuntimeAdapter
      { lane
      , config
      , codec
      , turns
      , custody
      , clock = options.clock
      , hooks = options.hooks
      , helper
      , source
      , readiness
      , operations
      , qualified
      , startWrapper = options.startWrapper
      }

codexAdapterLane :: CodexRuntimeAdapter -> CodexLane
codexAdapterLane a = a.lane

codexAdapterConfig :: CodexRuntimeAdapter -> CodexRuntimeConfig
codexAdapterConfig a = a.config

-- | @adapter._executable@.
codexExecutable :: CodexRuntimeAdapter -> IO (Maybe FilePath)
codexExecutable a = (.readyExecutable) <$> readMVar a.readiness

-- | @adapter._helper_executable@.
codexHelperExecutable :: CodexRuntimeAdapter -> FilePath
codexHelperExecutable a = a.helper

-- | @repr(adapter)@.
renderCodexRuntimeAdapter :: CodexRuntimeAdapter -> IO Text
renderCodexRuntimeAdapter a = do
  ready <- isJust . (.installation) <$> readMVar a.readiness
  let name = case a.lane of
        CodexLocal -> "CodexRuntimeAdapter"
        CodexGondolin -> "CodexGondolinRuntimeAdapter"
  pure (name <> "(host_id=" <> pythonStrRepr a.config.hostId <> ", ready=" <> (if ready then "True" else "False") <> ")")

runtimeIdentity :: CodexRuntimeAdapter -> DescriptorIdentity
runtimeIdentity a = case a.lane of
  CodexLocal -> codexA2Local.identity
  CodexGondolin -> codexA3Gondolin.identity

territoryIdentity :: CodexRuntimeAdapter -> DescriptorIdentity
territoryIdentity a = case a.lane of
  CodexLocal -> territoryId
  CodexGondolin -> gondolinTerritoryId

runtimeProvider :: CodexRuntimeAdapter -> Text
runtimeProvider a = case a.lane of
  CodexLocal -> "local-process"
  CodexGondolin -> "gondolin"

-- | @_record(result, executable, execution_path)@.
record :: CodexRuntimeAdapter -> ProbeDisposition -> Maybe RuntimeInstallation -> [(Text, Text)] -> Maybe FilePath -> Maybe Text -> IO RuntimeProbeResult
record a disposition installation issues executable executionPath = do
  issues' <- throwLeft (traverse (\(c, component) -> mkProbeIssue c (Just component)) issues)
  result <- throwLeft (mkRuntimeProbeResult (runtimeIdentity a) disposition installation issues')
  modifyMVar_ a.readiness $ \_ ->
    let ready = if disposition == ProbeReady then installation else Nothing
     in pure (Readiness ready (if isJust ready then executable else Nothing) (if isJust ready then executionPath else Nothing))
  pure result

-- | @re.fullmatch(r"codex-cli ([^\s]+)", output)@.
cliVersion :: Text -> Text
cliVersion output = case T.stripPrefix "codex-cli " output of
  Just version | not (T.null version) && not (T.any pyIsSpace version) -> version
  _ -> "unparseable"

-- | @CodexRuntimeAdapter.probe()@: the exact client and its exec protocol.
probeCodex :: CodexRuntimeAdapter -> IO RuntimeProbeResult
probeCodex a = do
  executable <- a.hooks.which "codex"
  node <- a.hooks.which "node"
  case (executable, node) of
    (Nothing, _) -> record a ProbeNotInstalled Nothing [("client-not-installed", "codex")] Nothing Nothing
    (_, Nothing) -> record a ProbeNotInstalled Nothing [("client-not-installed", "node")] Nothing Nothing
    (Just found, Just foundNode) -> do
      executable' <- makeAbsolute found
      node' <- makeAbsolute foundNode
      outputs <- sequenceUntilFailure [[executable', "--version"], [executable', "exec", "--help"], [executable', "exec", "resume", "--help"]]
      case outputs of
        Just [versionOutput, helpText, resumeHelp] -> do
          let version = cliVersion (pyStrip versionOutput)
          (system, machine') <- observedPlatform
          component <- throwLeft (mkInstalledComponent "openai-codex" version codexSource)
          installation <-
            throwLeft $
              mkRuntimeInstallation
                (runtimeIdentity a)
                1
                [component]
                system
                machine'
                (Set.fromList ["runtime.cancel", "runtime.continue", "runtime.local", "runtime.provider-managed"])
          if
            | version /= codexVersion -> record a ProbeIncompatible (Just installation) [("version-mismatch", "codex")] Nothing Nothing
            | not (all (`T.isInfixOf` helpText) codexRequiredOptions) || not ("SESSION_ID" `T.isInfixOf` resumeHelp) ->
                record a ProbeUnavailable (Just installation) [("protocol-unavailable", "codex")] Nothing Nothing
            | otherwise -> do
                let executionPath = T.intercalate ":" (nub (map T.pack [takeDirectory executable', takeDirectory node', "/bin", "/usr/bin"]))
                record a ProbeReady (Just installation) [] (Just executable') (Just executionPath)
        _ -> record a ProbeUnavailable Nothing [("client-unavailable", "codex")] Nothing Nothing
  where
    sequenceUntilFailure = \case
      [] -> pure (Just [])
      argv : rest ->
        a.hooks.run argv >>= \case
          Nothing -> pure Nothing
          Just output -> fmap (output :) <$> sequenceUntilFailure rest

-- | @_validate_attachment(attachment)@.
validateAttachment :: CodexRuntimeAdapter -> EpisodeAttachment -> IO MotusAttachmentBinding
validateAttachment a attachment = do
  let snapshot = Episode.episodeSnapshot attachment
      expected =
        [ (KindRuntime, runtimeIdentity a)
        , (KindConnection, connectionId')
        , (KindProgram, programId)
        , (KindHands, handsId)
        , (KindTerritory, territoryIdentity a)
        , (KindContinuation, continuationId)
        ]
  when (any (\(k, v) -> fmap (.identity) (snapshotDescriptor k snapshot) /= Just v) expected) $
    protocol "resolution-mismatch"
  case snapshotDescriptor KindEffect snapshot of
    Just effect | "effect.host-fenced" `Set.member` effect.offers -> pure ()
    _ -> protocol "resolution-mismatch"
  motus <- maybe (protocol "attachment-binding-mismatch") pure (Episode.episodeBinding attachment).motus
  provider <- bindingProvider motus
  when (isNothing (providerPrivateFiles provider)) $ protocol "private-transfer-required"
  lease <- attachmentLease <$> bindingExecution motus
  unless
    ( leaseState lease == Ready
        && leaseProvider lease == runtimeProvider a
        && capPrivateFileTransfer `Set.member` leaseCapabilities lease
    )
    $ protocol "runtime-private-lease-required"
  pure motus

-- | @start(invocation)@ through any installed start wrapper.
startCodex :: CodexRuntimeAdapter -> CodexRuntimeInvocation -> IO CodexOperation
startCodex a = a.startWrapper (startDirect a)

startDirect :: CodexRuntimeAdapter -> CodexRuntimeInvocation -> IO CodexOperation
startDirect a inv0 = do
  inv <- newCodexRuntimeInvocation inv0
  when (a.lane == CodexGondolin) $ do
    motus <- maybe (protocol "attachment-binding-mismatch") pure (Episode.episodeBinding inv.attachment).motus
    execution <- bindingExecution motus
    known <- readMVar a.qualified
    unless ((bindingLeaseIdentity motus, attachmentId execution) `Set.member` known) $ protocol "territory-not-qualified"
  ready <- readMVar a.readiness
  case (ready.installation, ready.readyExecutable, ready.readyPath) of
    (Just _, Just _, Just _) -> pure ()
    _ -> protocol "runtime-not-ready"
  motus <- validateAttachment a inv.attachment
  forM_ inv.continuation $ \c ->
    when (c.state /= ContinuationInUse) $ protocol "continuation-not-claimed"
  prior <- traverse (codexCodecLoad a.codec) inv.continuation
  coords <- Episode.coordinates inv.attachment
  let key =
        OperationKey
          { keyEpisode = lifecycleIdText inv.episodeId
          , keyTurn = lifecycleIdText inv.turnId
          , keyPrompt = sha256Hex (TE.encodeUtf8 inv.prompt)
          , keyConnection = inv.connection.identity.connectionId
          , keyAuthorityEpoch = inv.connection.authorityEpoch
          , keyStateVersion = inv.connection.stateVersion
          , keyAttachment = coords.attachmentId
          , keyAttachmentEpoch = coords.attachmentEpoch
          , keyContinuationId = lifecycleIdText . (.id) <$> inv.continuation
          , keyContinuationLineage = lifecycleIdText . (.thread) <$> inv.continuation
          , keyContinuationReferenceDigest = sha256Hex . TE.encodeUtf8 . (.stateReference) <$> inv.continuation
          , keyContinuationThread = (.threadId) <$> prior
          , keyContinuationPath = (.rolloutPath) <$> prior
          , keyContinuationDigest = sha256Hex . (.rollout) <$> prior
          }
  mask_ $ do
    registered <- modifyMVar a.operations $ \known -> do
      current <- readMVar a.readiness
      (executable, executionPath) <- case (current.installation, current.readyExecutable, current.readyPath) of
        (Just _, Just e, Just p) -> pure (e, p)
        _ -> protocol "runtime-not-ready"
      case Map.lookup inv.operationId known of
        Just old
          | old.key /= key -> protocol "operation-conflict"
          | otherwise -> pure (known, Left old)
        Nothing -> do
          operation <- newOperation inv motus key prior executable executionPath
          pure (Map.insert inv.operationId operation known, Right operation)
    case registered of
      Left old -> pure old
      Right operation -> do
        Lifecycle.startWorker operation.lifecycle (runOperation operation)
        pure operation
  where
    newOperation inv motus key prior executable executionPath = do
      lifecycle <- newLifecycle (LifecycleTexts "Codex operation wait timeout must be positive and finite" "Codex runtime operation has not settled") inv.operationId
      pure
        CodexOperation
          { owner = a
          , inv
          , binding = motus
          , key
          , prior
          , executable
          , executionPath
          , lifecycle
          }

-- | The @PublicationResult | ReleaseResult@ cleanup gate.
connectionCleanupVerified :: Text -> Text -> Text -> CleanupEvidence -> Bool
connectionCleanupVerified expectedOperation attachmentId' operationId' cleanup' =
  operationId' == expectedOperation
    && cleanup'.attachmentId == attachmentId'
    && (cleanup'.removed || cleanup'.alreadyAbsent)
    && not cleanup'.securityViolation

data ExecState = ExecState
  { materialization :: Maybe HostMaterialization
  , authRef :: Maybe PrivateFileRef
  , rolloutRef :: Maybe PrivateFileRef
  , attempted :: Bool
  , connectionSettled :: Bool
  , connectionClean :: Bool
  , privateClean :: Bool
  , homeTouched :: Bool
  , homeScrubbed :: Bool
  }

-- | @_execute@: custody publication and cleanup precedence, explicit.
execute :: CodexOperation -> IO (RuntimeTurnSettlement, RuntimeCleanupDisposition)
execute o = do
  let a = o.owner
      config = a.config
      inv = o.inv
      prior = o.prior
      motus = o.binding
      deadline = Episode.episodeDeadline inv.attachment
      ids name = inv.operationId <> "." <> name
      current = operationCurrent o
      remaining = do
        now <- a.clock
        let value = deadline - now
        when (value <= 0) $ protocol "deadline-exceeded"
        pure (min value config.commandTimeout)
      commandIsCurrent = do
        live <- current
        now <- a.clock
        pure (live && now < deadline)
  provider <- bindingProvider motus
  transfer <- maybe (protocol "private-transfer-required") pure (providerPrivateFiles provider)
  state <- newIORef (ExecState Nothing Nothing Nothing False False False True False False)
  let modify' f = modifyIORef' state f
      helper mode values checkCurrent = do
        s <- readIORef state
        (auth, roll) <- case (s.authRef, s.rolloutRef) of
          (Just x, Just y) -> pure (x, y)
          _ -> throwAgenticus (OtherError "AssertionError") "helper requires both private roots"
        let interpreter = a.helper
        seconds <- if checkCurrent then remaining else pure (min config.commandTimeout config.cancellationGrace)
        command <-
          either throwIO pure $
            mkCommand
              (commandSpec ([T.pack interpreter, "-c", a.source, mode] <> values))
                { specTimeout = Just (FractionalSeconds seconds)
                , specOutputLimit = 512
                , specPrivateRoots = [("CODEX_HOME", auth), ("PETRUS_CODEX_ROLLOUT_ROOT", roll)]
                , specIsCurrent = if checkCurrent then Just commandIsCurrent else Nothing
                }
        r <- bindingExecute motus command
        when (resultReturncode r /= 0 || not (B.null (resultStderr r)) || resultTimedOut r || resultSuperseded r || resultOutputTruncated r) $
          protocol (mode <> "-failed")
        throwLeft (parseHelper (resultStdout r) (mode == "collect"))
      body = do
        live <- current
        unless live $ protocol "cancelled"
        ttl <- remaining
        modify' (\s -> s {attempted = True})
        materialization <-
          a.custody.materialize inv.connection.identity.connectionId config.hostId LeaseRefresh (min config.credentialTtl ttl) (ids "materialize")
        modify' (\s -> s {materialization = Just materialization})
        when (materialization.mode /= LeaseRefresh) $ protocol "custody-materialization-mismatch"
        let fence = materialization.fence
        when
          ( (fence.connectionId, fence.hostId, fence.authorityEpoch, fence.baseVersion)
              /= (inv.connection.identity.connectionId, config.hostId, inv.connection.authorityEpoch, inv.connection.stateVersion)
          )
          $ protocol "custody-state-mismatch"
        current >>= \l -> unless l (protocol "cancelled")
        a.custody.activate materialization (ids "activate")
        current >>= \l -> unless l (protocol "cancelled")
        authBytes <- materialization.home.read
        authFile <- either throwIO pure (mkPrivateFile "auth.json" authBytes)
        execution <- bindingExecution motus
        authReference <- transfer.importPrivateFile execution authFile
        modify' (\s -> s {authRef = Just authReference, privateClean = False})
        rolloutFile <- either throwIO pure (mkPrivateFile "rollout.jsonl" (maybe "" (.rollout) prior))
        execution' <- bindingExecution motus
        rolloutReference <- transfer.importPrivateFile execution' rolloutFile
        modify' (\s -> s {rolloutRef = Just rolloutReference})
        forM_ prior $ \p -> do
          modify' (\s -> s {homeTouched = True})
          void (helper "stage" [p.threadId, p.rolloutPath] True)
        let common =
              [ "--json"
              , "--color"
              , "never"
              , "--sandbox"
              , "read-only"
              , "--config"
              , "cli_auth_credentials_store=file"
              , "--skip-git-repo-check"
              , "--ignore-user-config"
              , "--ignore-rules"
              ]
            argv = [T.pack o.executable, "exec"] <> common <> maybe [] (\p -> ["resume", p.threadId]) prior <> ["--", inv.prompt]
        modify' (\s -> s {homeTouched = True})
        seconds <- remaining
        command <-
          either throwIO pure $
            mkCommand
              (commandSpec argv)
                { specEnvironment = [("LANG", "C.UTF-8"), ("NO_COLOR", "1"), ("PATH", o.executionPath)]
                , specTimeout = Just (FractionalSeconds seconds)
                , specOutputLimit = config.outputLimit
                , specPrivateRoots = [("CODEX_HOME", authReference)]
                , specIsCurrent = Just commandIsCurrent
                }
        r <- bindingExecute motus command
        when (resultTimedOut r) $ protocol "command-timeout"
        when (resultSuperseded r) $ protocol "command-superseded"
        when (resultOutputTruncated r) $ protocol "output-overflow"
        when (resultReturncode r < 0) $ protocol "command-signal"
        candidate <- throwLeft (parseJsonl (resultStdout r) (resultReturncode r))
        forM_ prior $ \p -> when (candidate.threadId /= p.threadId) $ protocol "continuation-thread-mismatch"
        collected <- helper "collect" [candidate.threadId] True
        modify' (\s -> s {homeScrubbed = True})
        path <- case collected of
          Just (String p) -> throwLeft (codexRolloutPath p candidate.threadId)
          Just _ -> throwIO (valueError "Codex rollout metadata must be bounded non-empty text")
          Nothing -> throwAgenticus (OtherError "AssertionError") "collect returned no rollout path"
        auth <- bindingExecution motus >>= \e -> privateFileContent <$> transfer.exportPrivateFile e authReference
        rolloutBytes <- bindingExecution motus >>= \e -> privateFileContent <$> transfer.exportPrivateFile e rolloutReference
        materialization.home.replace auth
        commandIsCurrent >>= \l -> unless l (protocol "command-superseded")
        payload <- throwLeft (mkCodexContinuationPayloadV1 candidate.threadId path rolloutBytes)
        continuation <- codexCodecStore a.codec inv.operationId payload
        output <-
          if candidate.completed
            then
              Just
                <$> ( a.turns.storeTurn inv.operationId candidate.threadId (fromMaybe "" candidate.text)
                        >>= throwLeft . codexText "Codex output reference" 512
                    )
            else pure Nothing
        forM_ [authReference, rolloutReference] $ \ref -> do
          e <- bindingExecution motus
          deleted <- transfer.deletePrivateFile e ref
          unless (privateCleanupVerified deleted) $ protocol "private-cleanup-uncertain"
        cleaned <- bindingExecution motus >>= transfer.cleanupPrivateFiles
        unless (privateCleanupVerified cleaned) $ protocol "private-cleanup-uncertain"
        modify' (\s -> s {privateClean = True})
        claimPublication o >>= maybe (pure ()) protocol
        admission <- a.custody.admitResult fence (ids "admit")
        when (admission.operationId /= ids "admit" || admission.purpose /= "result" || admission.attachmentId /= fence.attachmentId) $
          protocol "custody-admission-mismatch"
        publication <- a.custody.checkpoint materialization (ids "checkpoint")
        let clean = connectionCleanupVerified (ids "checkpoint") fence.attachmentId publication.operationId publication.cleanup
        modify' (\s -> s {connectionSettled = True, connectionClean = clean})
        unless clean $ protocol "connection-cleanup-uncertain"
        let published = publication.connection
        when
          ( published.identity /= inv.connection.identity
              || published.status /= StatusReady
              || published.authorityEpoch /= fence.authorityEpoch
              || published.stateVersion /= fence.baseVersion + 1
          )
          $ protocol "connection-publication-mismatch"
        if candidate.completed
          then settle inv TurnCompleted 1 "turn-completed" output (Just continuation)
          else settle inv TurnFailed 0 "provider-failed" Nothing (Just continuation)
  outcome <- trySync body
  -- finally
  s0 <- readIORef state
  unless s0.privateClean $ do
    let scrubbed0 = s0.homeScrubbed || not s0.homeTouched
    scrubbed <-
      if not scrubbed0 && s0.homeTouched && isJust s0.authRef && isJust s0.rolloutRef
        then either (const False) (const True) <$> trySync (helper "scrub" [] False)
        else pure scrubbed0
    cleaned <- trySync (bindingExecution motus >>= transfer.cleanupPrivateFiles)
    modify' (\s -> s {privateClean = either (const False) (\c -> scrubbed && privateCleanupVerified c) cleaned})
  s1 <- readIORef state
  case s1.materialization of
    Just materialization | not s1.connectionSettled -> do
      released <- trySync (a.custody.release materialization (ids "release"))
      case released of
        Right value ->
          modify' $ \s ->
            s
              { connectionSettled = True
              , connectionClean = connectionCleanupVerified (ids "release") materialization.fence.attachmentId value.operationId value.cleanup
              }
        Left _ -> modify' (\s -> s {connectionClean = False})
    _ -> pure ()
  final <- readIORef state
  let disposition
        | final.connectionClean && final.privateClean = RuntimeCleanupClean
        | not final.attempted && isNothing final.materialization && isNothing final.authRef && isNothing final.rolloutRef = RuntimeCleanupNotCreated
        | otherwise = RuntimeCleanupUnverified
  case outcome of
    Right settlement -> pure (settlement, disposition)
    Left e -> do
      let code = case fromException e of
            Just failure | Just c <- runtimeProtocolErrorCode failure -> c
            _ -> "runtime-failed"
      live <- current
      settlement <- if live then settle inv TurnFailed 0 code Nothing Nothing else settle inv TurnCancelled 0 "cancelled" Nothing Nothing
      pure (settlement, disposition)

-- ---------------------------------------------------------------------------
-- The Gondolin lane

-- | @_private_file_probe(binding, remaining)@: one private file in, changed
-- by a guest command, out, deleted, and the attachment's private files
-- cleaned, all inside one binding operation.
privateFileProbe :: CodexRuntimeAdapter -> MotusAttachmentBinding -> Double -> IO Bool
privateFileProbe a motus remaining = do
  outcome <- trySync . withBindingOperation motus $ do
    provider <- bindingProvider motus
    transfer <- maybe (throwAgenticus RuntimeError "private transfer required") pure (providerPrivateFiles provider)
    reference <- newIORef Nothing
    let interpreter = a.helper
    passed <- trySync $ do
      probeFile <- either throwIO pure (mkPrivateFile "probe" "agenticus-codex-a3-before")
      expected <- either throwIO pure (mkPrivateFile "probe" "agenticus-codex-a3-after")
      execution <- bindingExecution motus
      ref <- transfer.importPrivateFile execution probeFile
      writeIORef reference (Just ref)
      command <-
        either throwIO pure $
          mkCommand
            ( commandSpec
                [ T.pack interpreter
                , "-c"
                , "import os,pathlib,sys; p=pathlib.Path(os.environ['PETRUS_PROBE'])/'probe'; sys.exit(64) if p.read_bytes()!=b'agenticus-codex-a3-before' else p.write_bytes(b'agenticus-codex-a3-after')"
                ]
            )
              { specEnvironment = [("LANG", "C.UTF-8"), ("PATH", guestPath)]
              , specTimeout = Just (FractionalSeconds remaining)
              , specOutputLimit = 64
              , specPrivateRoots = [("PETRUS_PROBE", ref)]
              }
      r <- bindingExecute motus command
      if resultReturncode r == 0
        && B.null (resultStdout r)
        && B.null (resultStderr r)
        && not (resultTimedOut r)
        && not (resultSuperseded r)
        && not (resultOutputTruncated r)
        then (== expected) <$> (bindingExecution motus >>= \e -> transfer.exportPrivateFile e ref)
        else pure False
    ref <- readIORef reference
    deleted <- case ref of
      Nothing -> pure True
      Just r -> either (const False) privateCleanupVerified <$> trySync (bindingExecution motus >>= \e -> transfer.deletePrivateFile e r)
    cleaned <- either (const False) privateCleanupVerified <$> trySync (bindingExecution motus >>= transfer.cleanupPrivateFiles)
    pure (either (const False) id passed && deleted && cleaned)
  pure (either (const False) id outcome)

-- | @_credential_free_probe_command(binding, remaining, argv)@.
credentialFreeProbe :: MotusAttachmentBinding -> Double -> [Text] -> IO (Maybe Text)
credentialFreeProbe motus remaining argv = do
  outcome <- trySync $ do
    command <-
      either throwIO pure $
        mkCommand
          (commandSpec argv)
            { specEnvironment = [("LANG", "C.UTF-8"), ("NO_COLOR", "1"), ("PATH", guestPath)]
            , specTimeout = Just (FractionalSeconds remaining)
            , specOutputLimit = 128 * 1024
            }
    r <- bindingExecute motus command
    if resultReturncode r /= 0 || not (B.null (resultStderr r)) || resultTimedOut r || resultSuperseded r || resultOutputTruncated r
      then pure Nothing
      else pure (either (const Nothing) (Just . pyStrip) (TE.decodeUtf8' (resultStdout r)))
  pure (either (const Nothing) id outcome)

-- | @CodexGondolinRuntimeAdapter.probe(attachment)@: the exact
-- credential-free guest lease, qualified per attachment, before any
-- materialization.
probeCodexGondolin :: CodexRuntimeAdapter -> Maybe EpisodeAttachment -> IO RuntimeProbeResult
probeCodexGondolin a = \case
  Nothing -> record a ProbeUnavailable Nothing [("territory-probe-required", "gondolin")] Nothing Nothing
  Just attachment -> do
    motus <- validateAttachment a attachment
    execution <- bindingExecution motus
    let qualification = (bindingLeaseIdentity motus, attachmentId execution)
    modifyMVar_ a.qualified (pure . Set.delete qualification)
    now <- a.clock
    let remaining = min a.config.commandTimeout (Episode.episodeDeadline attachment - now)
    if remaining <= 0
      then record a ProbeUnavailable Nothing [("territory-unavailable", "gondolin")] Nothing Nothing
      else do
        privateOk <- privateFileProbe a motus remaining
        if not privateOk
          then record a ProbeUnavailable Nothing [("territory-probe-failed", "gondolin")] Nothing Nothing
          else do
            versionOutput <- credentialFreeProbe motus remaining [guestExecutable, "--version"]
            architecture0 <- credentialFreeProbe motus remaining ["/bin/uname", "-m"]
            case (versionOutput, architecture0) of
              (Just versionText, Just architectureText) -> do
                let version = cliVersion versionText
                    architecture = if architectureShaped architectureText then architectureText else "unparseable"
                component <- throwLeft (mkInstalledComponent "openai-codex" version codexGondolinSource)
                installation <-
                  throwLeft $
                    mkRuntimeInstallation
                      (runtimeIdentity a)
                      1
                      [component]
                      "linux"
                      architecture
                      (Set.fromList ["runtime.cancel", "runtime.continue", "runtime.gondolin", "runtime.provider-managed"])
                if version /= codexGondolinVersion || architecture /= "aarch64"
                  then
                    record
                      a
                      ProbeIncompatible
                      (Just installation)
                      [(if version /= codexGondolinVersion then "version-mismatch" else "platform-mismatch", "codex")]
                      Nothing
                      Nothing
                  else do
                    helpText <- credentialFreeProbe motus remaining [guestExecutable, "exec", "--help"]
                    resumeHelp <- credentialFreeProbe motus remaining [guestExecutable, "exec", "resume", "--help"]
                    case (helpText, resumeHelp) of
                      (Just h, Just rh)
                        | all (`T.isInfixOf` h) codexRequiredOptions && "SESSION_ID" `T.isInfixOf` rh -> do
                            result <- record a ProbeReady (Just installation) [] (Just (T.unpack guestExecutable)) (Just guestPath)
                            modifyMVar_ a.qualified (pure . Set.insert qualification)
                            pure result
                      _ -> record a ProbeUnavailable (Just installation) [("protocol-unavailable", "codex")] Nothing Nothing
              _ -> record a ProbeUnavailable Nothing [("client-unavailable", "codex")] Nothing Nothing
  where
    architectureShaped value =
      not (T.null value)
        && T.length value <= 64
        && T.all (\c -> isAsciiUpper c || isAsciiLower c || isDigit c || c `elem` ("_.-" :: String)) value
