-- | Petrus-owned composition for one Pi A2 Local host lifecycle
-- (@petrus.agenticus.runtime.pi_a2_host@).
--
-- The host owns Agent Connection custody, the Motus territory, the Episode
-- Attachment and Hands, native Continuation bodies, durable operation
-- recovery, and ordered teardown. The supported product surface is the
-- explicitly scripted runtime-conformance composition
-- ('composePiA2ScriptedRuntime'). Exact external Pi and provider execution
-- through 'composePiA2Runtime' remains experimental and qualification-only.
-- Probe and durable replay run before authority is requested.
--
-- The durable operation ledger is secret-free. Provider output and native Pi
-- session JSONL live in a separate private body store (@bodies.sqlite3@,
-- with the reference's exact @pi_a2_bodies@ table) and become loadable only
-- after aggregate runtime, Attachment, and territory cleanup is verified.
module Petrus.Agenticus.Runtime.PiA2Host
  ( -- * Configuration
    PiA2RuntimeHostConfig (..)
  , piA2RuntimeHostConfig
  , newPiA2RuntimeHostConfig
  , PiA2RuntimePolicy (capabilities, writablePaths, maxToolCalls, writableRoots)
  , mkPiA2RuntimePolicy
  , PiA2RuntimeStart (..)
  , newPiA2RuntimeStart
  , piA2DurableFingerprint
  , PiA2DirectAuthority (connection, keyOperations, supplyApiKey)
  , mkPiA2DirectAuthority
    -- * Scripted conformance
  , PiA2ScriptedCall (method, paramsJson, expectedOk)
  , mkPiA2ScriptedCall
  , PiA2ScriptedTurn (..)
  , piA2ScriptedTurn
  , mkPiA2ScriptedTurn
  , PiA2ScriptedReadiness (..)
  , scriptedSupportLabel
  , scriptedSession
  , piA2ScriptedFactory
    -- * Operations
  , PiA2Operation
  , piA2OperationId
  , piA2RuntimeOperation
  , waitPiA2
  , cancelPiA2
  , closePiA2
    -- * The host
  , PiA2RuntimeHost
  , composePiA2Runtime
  , composePiA2ScriptedRuntime
  , composePiA2RuntimeWith
  , composePiA2ScriptedClientRuntime
  , hostDescriptor
  , hostSnapshot
  , hostConfig
  , hostRecoveredSettlements
  , hostAuthorityRequested
  , probeHost
  , scriptedReadiness
  , startHost
  , loadOutput
  , loadWorkspaceArchive
  , acknowledgeHost
  , closeHost
    -- * Host internals (the reference's private attributes, for tests)
  , PiA2FactoryKind (..)
  , hostFactoryKind
  , hostProvider
  , hostAdapter
  , hostLedger
  , hostStorage
  , hostBodies
  , hostFingerprint
  , piA2TerritoryOperation
  , piA2AttachmentIdentity
  , PiA2HostHooks (..)
  , noPiA2HostHooks
  , setPiA2HostHooks
    -- * The body store
  , BodyStore
  , bodyTableSql
  , bodyStorePublish
  , bodyStoreVerified
  , bodyStoreClose
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception
  ( IOException
  , SomeAsyncException
  , SomeException
  , bracket
  , catch
  , finally
  , fromException
  , onException
  , throwIO
  , try
  )
import Control.Monad (forM, forM_, unless, void, when)
import Crypto.Random (getRandomBytes)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Char (isDigit)
import Data.IORef
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Unique (Unique, newUnique)
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding (AttachmentCoordinates (..), BindingSettlement (..), bindingExecution, motusBinding, openMotusBinding)
import Petrus.Agenticus.Attachment.Episode (AttachmentSettlement (..), EpisodeAttachment, EpisodeOptions (..), newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor
  ( CapabilityDescriptor (..)
  , DescriptorKind (..)
  , capabilityDescriptor
  , descriptorIdentity
  )
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot, mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody
  ( AgentConnectionCustody
  , ConnectionIdentity (..)
  , ConnectionStatus (..)
  , ConnectionView (..)
  , ErasureResult (..)
  , HostRemoval (..)
  , RevocationResult (..)
  , agentConnectionCustody
  , authorize
  , enrollHost
  , eraseOpaqueState
  , lookupConnection
  , opaqueStateFromBuffer
  , recover
  , removeHost
  , revoke
  , rotate
  )
import Petrus.Agenticus.Connection.Custody qualified as Custody
import Petrus.Agenticus.Connection.Key (KeyErasureEvidence (..), KeyOperations, ScrubbedBytes, eraseBuffer)
import Petrus.Agenticus.Connection.Materialization (CleanupSummary (..), newPrivateFileMaterializer)
import Petrus.Agenticus.Connection.Storage (ConnectionStorage (..), StorageSnapshot (..), StoredConnection (..), openSqliteConnectionStorage)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract (ToolMethod (..), ToolResult (..), toolMethodText)
import Petrus.Agenticus.Hands.Gateway qualified as Gateway
import Petrus.Agenticus.Hands.Grants (CapabilityGrant (..), GrantSpec (..), mkCapabilityGrant, openGrant)
import Petrus.Agenticus.Hands.Workspace (newMotusWorkspaceAdapter, stageDirectory, workspaceHandsAdapter)
import Petrus.Agenticus.Internal.Sqlite
import Petrus.Agenticus.Internal.Validate (sha256Hex, utf8Length)
import Petrus.Agenticus.Runtime.Installation (ProbeDisposition (..), RuntimeInstallation (..), RuntimeProbeResult (..))
import Petrus.Agenticus.Runtime.Operation
  ( RuntimeCleanupDisposition (..)
  , RuntimeOperation (..)
  , RuntimeOperationCleanup (..)
  , cleanupVerified
  , mkRuntimeOperationCleanup
  , runtimeProtocolError
  , runtimeProtocolErrorCode
  )
import Petrus.Agenticus.Runtime.Pi
  ( PiCandidate (..)
  , PiContinuationOperations (..)
  , PiContinuationPayloadV1 (sessionId, sessionJsonl, workingDirectoryBinding)
  , PiHelperArgs (..)
  , PiHelperClient (..)
  , PiHelperFactory (..)
  , PiHelperResult (..)
  , PiRuntimeAdapter
  , PiRuntimeConfig (..)
  , PiRuntimeInvocation (..)
  , PiTurnOperations (..)
  , ProbePaths (..)
  , adapterConfig
  , enableScriptedConformance
  , micros
  , mkPiContinuationPayloadV1
  , newPiRuntimeAdapter
  , piApiKeyCatalog
  , piCollocatedHands
  , piConnectionCapabilities
  , piConnectionCustody
  , piContinuationCapabilities
  , piContinuationCodec
  , piContinuationDescriptor
  , piDurableWorkFingerprint
  , piLocalTerritory
  , piProgramCapabilities
  , piRuntimeConfig
  , piRuntimeOperation
  , piText
  , probe
  , receiptPi
  , startPi
  )
import Petrus.Agenticus.Runtime.PiRecovery
  ( PiOperationPhase (..)
  , PiOperationRecord (..)
  , SqlitePiOperationLedger
  , ledgerAcknowledge
  , ledgerAdmit
  , ledgerClose
  , ledgerLookup
  , ledgerRecords
  , ledgerRecover
  , ledgerSettle
  , ledgerUpgradeCleanup
  , openSqlitePiOperationLedger
  , recordCleanupEvidence
  , recordSettlement
  )
import Petrus.Agenticus.Runtime.Profiles (piNativeA2Local)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..), mkRuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Continuation (Continuation (..), ContinuationState (..))
import Petrus.Agenticus.Thread.Identity (EpisodeId, TurnId)
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Execution
  ( Capability
  , EnvironmentProvider (..)
  , ExecutionError
  , capCommandCancellation
  , capExplicitEnvironment
  , capPrivateFileTransfer
  , capProcessGroup
  , capWorkspace
  , cleanupVerified
  , mkEnvironmentSpec
  )
import Petrus.Motus.Execution qualified as Motus
import Petrus.Motus.Execution.Archive (validateWorkspaceArchive)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesDirectoryExist, doesPathExist, listDirectory)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Directory qualified as Dir
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as PIO
import System.Posix.Types (FileMode)
import System.Posix.User (getEffectiveUserID)

-- ---------------------------------------------------------------------------
-- Constants

maxPromptBytes, maxKeyBytes, fingerprintSchemaVersion :: Int
maxPromptBytes = 64 * 1024
maxKeyBytes = 8192
fingerprintSchemaVersion = 2

-- | @_SCRIPTED_SUPPORT_LABEL@.
scriptedSupportLabel :: Text
scriptedSupportLabel = "Pi A2 Local host lifecycle \x2014 scripted runtime conformance"

-- | @_SCRIPTED_SESSION@: the session identity of a fresh scripted turn.
scriptedSession :: Text
scriptedSession = "00000000-0000-4000-8000-000000000001"

requiredInstallationCapabilities :: Set Text
requiredInstallationCapabilities =
  Set.fromList ["runtime.cancel", "runtime.continue", "runtime.harness-owned", "runtime.local"]

requiredEnvironmentCapabilities :: Set Capability
requiredEnvironmentCapabilities =
  Set.fromList [capCommandCancellation, capExplicitEnvironment, capPrivateFileTransfer, capProcessGroup, capWorkspace]

controlRoots :: [Text]
controlRoots = [".git", stageDirectory]

effect :: CapabilityDescriptor
effect = capabilityDescriptor (descriptorIdentity KindEffect "host.fenced" 1) ["effect.host-fenced"] []

-- | @_SNAPSHOT@.
hostSnapshot :: ResolutionSnapshot
hostSnapshot =
  either (error . show) id $
    mkResolutionSnapshot
      1
      [ piNativeA2Local
      , piConnectionCapabilities
      , piProgramCapabilities
      , piCollocatedHands
      , piLocalTerritory
      , piContinuationCapabilities
      , effect
      ]

hostDescriptor :: CapabilityDescriptor
hostDescriptor = piNativeA2Local

-- ---------------------------------------------------------------------------
-- Validation helpers

rpe :: Text -> IO a
rpe = throwIO . runtimeProtocolError

-- | @_positive(value, name)@.
positive :: Text -> Double -> IO Double
positive name value
  | isNaN value || isInfinite value || value <= 0 = throwIO (valueError (name <> " must be positive and finite"))
  | otherwise = pure value

-- | @_digest(value, name)@.
digestText :: Text -> Text -> Either AgenticusError Text
digestText name value
  | T.length value == 64 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) value = Right value
  | otherwise = Left (valueError (name <> " must be a lowercase SHA-256 digest"))

security :: Text -> IO a
security = throwAgenticus StorageSecurityError

isLink :: FilePath -> IO Bool
isLink target =
  (Files.isSymbolicLink <$> Files.getSymbolicLinkStatus target) `catch` \(_ :: IOException) -> pure False

permissionBits :: Files.FileStatus -> FileMode
permissionBits status = Files.fileMode status `Files.intersectFileModes` 0o7777

ownedDirectory :: Files.FileStatus -> IO Bool
ownedDirectory status = do
  uid <- getEffectiveUserID
  pure (Files.isDirectory status && permissionBits status == 0o700 && Files.fileOwner status == uid)

-- | @_private_root(path)@.
privateRoot :: FilePath -> IO FilePath
privateRoot selected = do
  isLink selected >>= \linked -> when linked $ security "Pi A2 state root must not be a symlink"
  exists <- doesPathExist selected
  unless exists $ do
    createDirectoryIfMissing True (takeDirectory selected)
    Dir.createDirectory selected 0o700
    Files.setFileMode selected 0o700
  resolved <- canonicalizePath selected
  status <- Files.getSymbolicLinkStatus resolved
  valid <- ownedDirectory status
  unless valid $ security "Pi A2 state root must be an owned mode-0700 directory"
  pure resolved

-- | @_private_subdirectory(root, name)@.
privateSubdirectory :: FilePath -> Text -> IO FilePath
privateSubdirectory root name = do
  let selected = root </> T.unpack name
  isLink selected >>= \linked -> when linked $ security ("Pi A2 " <> name <> " root must not be a symlink")
  exists <- doesPathExist selected
  unless exists $ Dir.createDirectory selected 0o700
  status <- Files.getSymbolicLinkStatus selected
  valid <- ownedDirectory status
  unless valid $ security ("Pi A2 " <> name <> " root must be an owned mode-0700 directory")
  pure selected

trySync :: IO a -> IO (Either SomeException a)
trySync action =
  try action >>= \case
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    other -> pure other

-- ---------------------------------------------------------------------------
-- Configuration

-- | @PiA2RuntimeHostConfig@: one explicit, finite, direct-API-key Pi A2
-- Local host profile. Build it with 'piA2RuntimeHostConfig' and validate it
-- with 'newPiA2RuntimeHostConfig' (the reference's @__post_init__@).
--
-- 'workingDirectory' is stable native helper/session metadata. Episode
-- workspace custody comes only from each 'PiA2RuntimeStart' archive.
data PiA2RuntimeHostConfig = PiA2RuntimeHostConfig
  { stateRoot :: FilePath
  , workingDirectory :: FilePath
  , provider :: Text
  , model :: Text
  , hostId :: Text
  , capabilities :: Set ToolMethod
  , allowedArgv :: Set [Text]
  , testCommand :: [Text]
  , maxToolCalls :: Int
  , attachmentTimeout :: Double
  , commandTimeout :: Double
  , credentialTtl :: Double
  , wallTimeout :: Double
  , cancellationGrace :: Double
  , cliPath :: Maybe Text
  , nodePath :: Maybe Text
  , packageRoot :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | The reference's defaults: state root, working directory, provider,
-- model, host and capabilities.
piA2RuntimeHostConfig :: FilePath -> FilePath -> Text -> Text -> Text -> Set ToolMethod -> PiA2RuntimeHostConfig
piA2RuntimeHostConfig stateRoot workingDirectory provider model hostId capabilities =
  PiA2RuntimeHostConfig
    { stateRoot
    , workingDirectory
    , provider
    , model
    , hostId
    , capabilities
    , allowedArgv = Set.empty
    , testCommand = ["/bin/true"]
    , maxToolCalls = 16
    , attachmentTimeout = 960.0
    , commandTimeout = 60.0
    , credentialTtl = 1020.0
    , wallTimeout = 900.0
    , cancellationGrace = 5.0
    , cliPath = Nothing
    , nodePath = Nothing
    , packageRoot = Nothing
    }

newPiA2RuntimeHostConfig :: PiA2RuntimeHostConfig -> IO PiA2RuntimeHostConfig
newPiA2RuntimeHostConfig c = do
  provider <- throwLeft (piText "Pi A2 provider" 256 c.provider)
  model <- throwLeft (piText "Pi A2 model" 256 c.model)
  hostId <- throwLeft (piText "Pi A2 host" 256 c.hostId)
  when (lookup provider piApiKeyCatalog /= Just model) $
    throwIO (valueError "Pi A2 host requires an exact direct API-key provider/model pair")
  isLink c.workingDirectory >>= \linked -> when linked $ throwIO (valueError "Pi A2 working directory must be stable")
  working <- canonicalizePath c.workingDirectory
  isDirectory <- doesDirectoryExist working
  unless isDirectory $ throwIO (valueError "Pi A2 working directory must be an existing directory")
  when (Set.null c.capabilities) $ throwIO (typeError "Pi A2 capabilities must contain exact ToolMethod values")
  when (c.maxToolCalls <= 0) $ throwIO (valueError "Pi A2 max_tool_calls must be positive")
  attachmentTimeout <- positive "Pi A2 attachment_timeout" c.attachmentTimeout
  commandTimeout <- positive "Pi A2 command_timeout" c.commandTimeout
  credentialTtl <- positive "Pi A2 credential_ttl" c.credentialTtl
  wallTimeout <- positive "Pi A2 wall_timeout" c.wallTimeout
  cancellationGrace <- positive "Pi A2 cancellation_grace" c.cancellationGrace
  when (attachmentTimeout <= wallTimeout + cancellationGrace) $
    throwIO (valueError "Pi A2 attachment timeout must exceed the runtime and cancellation bounds")
  when (null c.testCommand || any T.null c.testCommand) $ throwIO (valueError "Pi A2 test command must be non-empty")
  -- Reuse the canonical grant validators before any Episode exists.
  normalized <-
    throwLeft
      ( mkCapabilityGrant
          "configuration"
          1
          1
          (Set.toList c.capabilities)
          []
          (Set.toList c.allowedArgv)
          1.0
          (toInteger c.maxToolCalls)
          []
          []
      )
  cliPath <- traverse (throwLeft . piText "Pi A2 cli_path" 4096) c.cliPath
  nodePath <- traverse (throwLeft . piText "Pi A2 node_path" 4096) c.nodePath
  packageRoot <- traverse (throwLeft . piText "Pi A2 package_root" 4096) c.packageRoot
  pure
    PiA2RuntimeHostConfig
      { stateRoot = c.stateRoot
      , workingDirectory = working
      , provider
      , model
      , hostId
      , capabilities = c.capabilities
      , allowedArgv = normalized.allowedArgv
      , testCommand = c.testCommand
      , maxToolCalls = c.maxToolCalls
      , attachmentTimeout
      , commandTimeout
      , credentialTtl
      , wallTimeout
      , cancellationGrace
      , cliPath
      , nodePath
      , packageRoot
      }

-- | @PiA2RuntimePolicy@: one operation's exact attachment-scoped Hands
-- authority. Built only through 'mkPiA2RuntimePolicy'.
data PiA2RuntimePolicy = PiA2RuntimePolicy
  { capabilities :: Set ToolMethod
  , writablePaths :: Set Text
  , maxToolCalls :: Int
  , writableRoots :: Set Text
  }
  deriving stock (Eq, Show)

-- | @PiA2RuntimePolicy(capabilities, writable_paths, max_tool_calls,
-- writable_roots)@.
mkPiA2RuntimePolicy :: [ToolMethod] -> [Text] -> Int -> [Text] -> Either AgenticusError PiA2RuntimePolicy
mkPiA2RuntimePolicy caps paths maxCalls roots = do
  when (null caps) $ Left (typeError "Pi A2 operation capabilities must contain exact ToolMethod values")
  normalized <-
    mkCapabilityGrant "operation-policy" 1 1 caps paths [] 1.0 (toInteger maxCalls) roots controlRoots
  let scoped = Set.union normalized.writablePaths normalized.writableRoots
  when (not (Set.null scoped) && WorkspaceWrite `notElem` caps) $
    Left (valueError "Pi A2 writable paths and roots require workspace-write capability")
  when (any (\path -> T.takeWhile (/= '/') path `elem` controlRoots) (Set.toList scoped)) $
    Left (valueError "Pi A2 writable policy must exclude workspace control roots")
  pure
    PiA2RuntimePolicy
      { capabilities = Set.fromList caps
      , writablePaths = normalized.writablePaths
      , maxToolCalls = maxCalls
      , writableRoots = normalized.writableRoots
      }

-- | @PiA2RuntimeStart@: stable work identity, exact workspace, and bounded
-- policy for one Pi operation. Validate it with 'newPiA2RuntimeStart'.
data PiA2RuntimeStart = PiA2RuntimeStart
  { operationId :: Text
  , episodeId :: EpisodeId
  , turnId :: TurnId
  , prompt :: Text
  , workspaceArchive :: ByteString
  , workspaceDigest :: Text
  , workspaceCorrelation :: Text
  , policy :: PiA2RuntimePolicy
  , continuation :: Maybe Continuation
  }

newPiA2RuntimeStart :: PiA2RuntimeStart -> IO PiA2RuntimeStart
newPiA2RuntimeStart s = do
  operationId <- throwLeft (piText "Pi A2 operation" 256 s.operationId)
  when (T.null s.prompt || T.elem '\0' s.prompt || utf8Length s.prompt > maxPromptBytes) $
    throwIO (valueError "Pi A2 prompt must be bounded non-empty text")
  digest <- throwLeft (digestText "Pi A2 workspace digest" s.workspaceDigest)
  when (sha256Hex s.workspaceArchive /= digest) $ throwIO (valueError "Pi A2 workspace archive does not match its digest")
  -- Motus raises its own ValueError kind; the reference raises ValueError.
  validateWorkspaceArchive False controlRoots s.workspaceArchive `catch` \(e :: ExecutionError) ->
    if Motus.errorKind e == Motus.ValueError then throwIO (valueError (Motus.errorMessage e)) else throwIO e
  correlation <- throwLeft (piText "Pi A2 workspace correlation" 512 s.workspaceCorrelation)
  forM_ s.continuation $ \c ->
    when (c.descriptor /= piContinuationDescriptor || c.state /= ContinuationInUse) $
      throwIO (valueError "Pi A2 continuation must be the claimed native Pi Continuation")
  pure
    PiA2RuntimeStart
      { operationId
      , episodeId = s.episodeId
      , turnId = s.turnId
      , prompt = s.prompt
      , workspaceArchive = s.workspaceArchive
      , workspaceDigest = digest
      , workspaceCorrelation = correlation
      , policy = s.policy
      , continuation = s.continuation
      }

-- | @_pi_a2_durable_fingerprint(config, start, inner)@: bind prospective Pi
-- work to exact workspace content and effective policy.
piA2DurableFingerprint :: PiA2RuntimeHostConfig -> PiA2RuntimeStart -> Text -> Either AgenticusError Text
piA2DurableFingerprint config start inner = do
  pi' <- digestText "Pi A2 inner fingerprint" inner
  let policy = start.policy
      strings = Array . map String
      identity =
        Object
          [ ("schema_version", Int (toInteger fingerprintSchemaVersion))
          , ("pi", String pi')
          , ("workspace", Object [("digest", String start.workspaceDigest), ("correlation", String start.workspaceCorrelation)])
          ,
            ( "policy"
            , Object
                [ ("capabilities", strings (sort (map toolMethodText (Set.toList policy.capabilities))))
                , ("writable_paths", strings (Set.toAscList policy.writablePaths))
                , ("writable_roots", strings (Set.toAscList policy.writableRoots))
                , ("denied_writable_roots", strings controlRoots)
                ,
                  ( "allowed_argv"
                  , if WorkspaceShell `Set.member` policy.capabilities
                      then Array (map strings (Set.toAscList config.allowedArgv))
                      else Array []
                  )
                , ("test_command", if WorkspaceTest `Set.member` policy.capabilities then strings config.testCommand else Null)
                , ("max_tool_calls", Int (toInteger policy.maxToolCalls))
                ]
            )
          ]
      options = J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":", J.sortKeys = True, J.allowNan = False}
  encoded <- either (const (Left (valueError "Out of range float values are not JSON compliant"))) Right (J.dumps options identity)
  pure (sha256Hex encoded)

-- | @PiA2DirectAuthority@: host-owned direct API-key authority supplied at
-- most once per composer. The supplier returns an erasable buffer, which the
-- host zeroes after copying it into custody.
data PiA2DirectAuthority = PiA2DirectAuthority
  { connection :: ConnectionIdentity
  , keyOperations :: KeyOperations
  , supplyApiKey :: IO ScrubbedBytes
  }

mkPiA2DirectAuthority :: ConnectionIdentity -> KeyOperations -> IO ScrubbedBytes -> Either AgenticusError PiA2DirectAuthority
mkPiA2DirectAuthority connection keyOperations supplyApiKey
  | connection.profile /= "api-key" = Left (valueError "Pi A2 authority requires a direct API-key ConnectionIdentity")
  | otherwise = Right PiA2DirectAuthority {connection, keyOperations, supplyApiKey}

-- ---------------------------------------------------------------------------
-- Scripted conformance

-- | @PiA2ScriptedCall@: one finite Hands request in a scripted turn.
data PiA2ScriptedCall = PiA2ScriptedCall
  { method :: ToolMethod
  , paramsJson :: Text
  , expectedOk :: Bool
  }
  deriving stock (Eq, Show)

parseParams :: Text -> Either () Json
parseParams = either (const (Left ())) Right . J.parseJson J.pythonLoads . TE.encodeUtf8

mkPiA2ScriptedCall :: ToolMethod -> Text -> Bool -> Either AgenticusError PiA2ScriptedCall
mkPiA2ScriptedCall method paramsJson expectedOk = do
  params <- either (const (Left (valueError "scripted Pi call params must be JSON"))) Right (parseParams paramsJson)
  case params of
    Object _ | utf8Length paramsJson <= 8192 -> Right PiA2ScriptedCall {method, paramsJson, expectedOk}
    _ -> Left (valueError "scripted Pi call params must be a bounded JSON object")

-- | @PiA2ScriptedTurn@: finite data interpreted by Petrus's credential-free
-- scripted client. Validate it with 'mkPiA2ScriptedTurn'.
data PiA2ScriptedTurn = PiA2ScriptedTurn
  { outputText :: Text
  , calls :: [PiA2ScriptedCall]
  , delaySeconds :: Double
  , cleanupVerified :: Bool
  , failureCode :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | @PiA2ScriptedTurn(output_text)@ with the reference's defaults.
piA2ScriptedTurn :: Text -> PiA2ScriptedTurn
piA2ScriptedTurn outputText = PiA2ScriptedTurn {outputText, calls = [], delaySeconds = 0, cleanupVerified = True, failureCode = Nothing}

mkPiA2ScriptedTurn :: PiA2ScriptedTurn -> Either AgenticusError PiA2ScriptedTurn
mkPiA2ScriptedTurn t = do
  when (utf8Length t.outputText > 1000000) $ Left (valueError "scripted Pi output must be bounded text")
  when (length t.calls > 256) $ Left (typeError "scripted Pi calls must be finite PiA2ScriptedCall values")
  when (isNaN t.delaySeconds || isInfinite t.delaySeconds || t.delaySeconds < 0 || t.delaySeconds > 60) $
    Left (valueError "scripted Pi delay must be finite and at most 60 seconds")
  forM_ t.failureCode (piText "scripted Pi failure code" 256)
  pure t

-- | @PiA2ScriptedReadiness@: readiness for the Petrus-owned script
-- interpreter, not a Pi installation.
data PiA2ScriptedReadiness = PiA2ScriptedReadiness
  { supportLabel :: Text
  , ready :: Bool
  }
  deriving stock (Eq, Show)

-- | @_ScriptedClient(turn, prior)@.
scriptedClient :: PiA2ScriptedTurn -> Maybe PiContinuationPayloadV1 -> PiHelperClient
scriptedClient turn prior = PiHelperClient {run, close = pure turn.cleanupVerified}
  where
    run gw inv current deadline = do
      now <- getMonotonicTime
      let stop = min deadline (now + turn.delaySeconds)
          pause = do
            t <- getMonotonicTime
            when (t < stop) $ do
              live <- current
              unless live $ rpe "cancelled"
              threadDelay (micros (min 0.01 (stop - t)))
              pause
      pause
      forM_ turn.failureCode rpe
      coords <- Episode.coordinates inv.attachment
      forM_ (zip [0 :: Int ..] turn.calls) $ \(index, call) -> do
        params <- either (const (throwIO (valueError "scripted Pi call params must be JSON"))) pure (parseParams call.paramsJson)
        result <-
          Gateway.submit
            gw
            ( Object
                [ ("version", Int 1)
                , ("call_id", String ("scripted-" <> T.pack (show index)))
                , ("episode_id", String coords.episodeId)
                , ("attachment_id", String coords.attachmentId)
                , ("attachment_epoch", Int coords.attachmentEpoch)
                , ("grant_epoch", Int inv.grantEpoch)
                , ("method", String (toolMethodText call.method))
                , ("params", params)
                ]
            )
        when (result.ok /= call.expectedOk) $ rpe "script-expectation-failed"
      let session = maybe scriptedSession (.sessionId) prior
      header <- maybe (jsonLine [("type", String "session"), ("version", Int 3), ("id", String session)]) (pure . (.sessionJsonl)) prior
      message <- jsonLine [("type", String "message"), ("body", String turn.outputText)]
      pure
        PiHelperResult
          { candidate = Just PiCandidate {sessionId = session, text = turn.outputText, sessionJsonl = header <> message}
          , nativeAuth = Nothing
          , code = "turn-completed"
          }
    jsonLine fields =
      either (const (throwIO (valueError "scripted Pi line is not JSON"))) (pure . (<> "\n")) $
        J.dumps J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"} (Object fields)

-- | @_ScriptedFactory(script)@: one scripted turn per created client.
piA2ScriptedFactory :: [PiA2ScriptedTurn] -> IO PiHelperFactory
piA2ScriptedFactory script = do
  remaining <- newMVar script
  pure $
    PiHelperFactory $ \args -> do
      next <- modifyMVar remaining $ \case
        [] -> pure ([], Nothing)
        turn : rest -> pure (rest, Just turn)
      maybe (rpe "script-exhausted") (\turn -> pure (scriptedClient turn args.prior)) next

-- ---------------------------------------------------------------------------
-- The body store

-- | @_BodyStore@: private staged bodies committed atomically with aggregate
-- cleanup proof.
data BodyStore = BodyStore
  { path :: FilePath
  , database :: Database
  , lock :: MVar ()
  , stagedOutputs :: IORef (Map Text (Text, Text))
  , stagedContinuations :: IORef (Map Text (Text, PiContinuationPayloadV1))
  , closedRef :: IORef Bool
  }

-- | The reference's exact @CREATE TABLE@ text, whitespace included.
bodyTableSql :: Text
bodyTableSql =
  T.intercalate
    "\n"
    [ "CREATE TABLE IF NOT EXISTS pi_a2_bodies ("
    , "                operation_id TEXT PRIMARY KEY,"
    , "                output_reference TEXT, output_text TEXT,"
    , "                continuation_reference TEXT, session_id TEXT,"
    , "                working_binding TEXT, session_jsonl BLOB,"
    , "                workspace_archive BLOB NOT NULL, workspace_digest TEXT NOT NULL,"
    , "                aggregate_verified INTEGER NOT NULL CHECK (aggregate_verified IN (0, 1)))"
    ]

publishSql, rowSql, insertSql, continuationSql, outputSql, archiveSql, digestSql, verifiedSql :: Text
publishSql =
  "UPDATE pi_a2_bodies SET aggregate_verified = 1\n                       WHERE operation_id = ? AND aggregate_verified = 0"
rowSql = "SELECT * FROM pi_a2_bodies WHERE operation_id = ?"
insertSql = "INSERT INTO pi_a2_bodies VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
continuationSql =
  "SELECT session_id, working_binding, session_jsonl FROM pi_a2_bodies\n                   WHERE continuation_reference = ? AND aggregate_verified = 1"
outputSql =
  "SELECT output_text FROM pi_a2_bodies\n                   WHERE output_reference = ? AND aggregate_verified = 1"
archiveSql =
  "SELECT workspace_archive, workspace_digest FROM pi_a2_bodies\n                   WHERE operation_id = ? AND aggregate_verified = 1"
digestSql =
  "SELECT workspace_digest FROM pi_a2_bodies\n                   WHERE continuation_reference = ? AND aggregate_verified = 1"
verifiedSql = "SELECT 1 FROM pi_a2_bodies WHERE operation_id = ? AND aggregate_verified = 1"

openBodyStore :: FilePath -> IO BodyStore
openBodyStore path = do
  prepareBodyPath path
  database <- openDatabase path
  ( do
      setBusyTimeout database 5000
      Files.setFileMode path 0o600
      execute_ database "PRAGMA journal_mode = DELETE"
      execute_ database "PRAGMA synchronous = FULL"
      execute_ database bodyTableSql
      lock <- newMVar ()
      stagedOutputs <- newIORef Map.empty
      stagedContinuations <- newIORef Map.empty
      closedRef <- newIORef False
      pure BodyStore {path, database, lock, stagedOutputs, stagedContinuations, closedRef}
    )
    `onException` closeDatabase database

-- | @_prepare_path@.
prepareBodyPath :: FilePath -> IO ()
prepareBodyPath path = do
  let parent = takeDirectory path
  isLink parent >>= \linked -> when linked $ security "Pi A2 body-store parent must not be a symlink"
  parentOk <- Files.getSymbolicLinkStatus parent >>= ownedDirectory
  unless parentOk $ security "Pi A2 body-store parent must be an owned mode-0700 directory"
  isLink path >>= \linked -> when linked $ security "Pi A2 body-store file must not be a symlink"
  exists <- doesPathExist path
  unless exists $ do
    fd <- PIO.openFd path PIO.WriteOnly PIO.defaultFileFlags {PIO.creat = Just 0o600, PIO.exclusive = True, PIO.nofollow = True}
    PIO.closeFd fd
  status <- Files.getSymbolicLinkStatus path
  uid <- getEffectiveUserID
  unless (Files.isRegularFile status && permissionBits status == 0o600 && Files.fileOwner status == uid) $
    security "Pi A2 body-store file must be owned regular mode-0600"

withBodies :: BodyStore -> IO a -> IO a
withBodies bs action = withMVar bs.lock $ \_ -> do
  isClosed <- readIORef bs.closedRef
  when isClosed $ rpe "host-closed"
  action

selectRow :: BodyStore -> Text -> [SqlValue] -> IO (Maybe [SqlValue])
selectRow bs sql parameters = bracket (prepareStatement bs.database sql) finalizeStatement (`queryRow` parameters)

execute :: BodyStore -> Text -> [SqlValue] -> IO ()
execute bs sql parameters = bracket (prepareStatement bs.database sql) finalizeStatement (`runStatement` parameters)

immediate :: BodyStore -> IO a -> IO a
immediate bs action = do
  execute_ bs.database "BEGIN IMMEDIATE"
  (action <* execute_ bs.database "COMMIT") `onException` do
    active <- inTransaction bs.database
    when active $ execute_ bs.database "ROLLBACK"

bodyOperation :: Text -> IO Text
bodyOperation = throwLeft . piText "Pi A2 body operation" 256

-- | @store_turn(operation_id, final_text)@.
bodyStoreTurn :: BodyStore -> Text -> Text -> IO Text
bodyStoreTurn bs operationId0 finalText = do
  operationId <- bodyOperation operationId0
  let reference = "pi-a2-output-" <> sha256Hex (TE.encodeUtf8 (operationId <> "\0" <> finalText))
  withBodies bs $ do
    previous <- Map.lookup operationId <$> readIORef bs.stagedOutputs
    when (maybe False (/= (reference, finalText)) previous) $ rpe "operation-conflict"
    modifyIORef' bs.stagedOutputs (Map.insert operationId (reference, finalText))
  pure reference

-- | @store(operation_id, payload)@.
bodyStoreContinuation :: BodyStore -> Text -> PiContinuationPayloadV1 -> IO Text
bodyStoreContinuation bs operationId0 payload = do
  operationId <- bodyOperation operationId0
  let digest =
        sha256Hex
          ( TE.encodeUtf8 operationId
              <> "\0"
              <> TE.encodeUtf8 payload.sessionId
              <> "\0"
              <> TE.encodeUtf8 payload.workingDirectoryBinding
              <> "\0"
              <> payload.sessionJsonl
          )
      reference = "pi-a2-continuation-" <> digest
  withBodies bs $ do
    previous <- Map.lookup operationId <$> readIORef bs.stagedContinuations
    when (maybe False (/= (reference, payload)) previous) $ rpe "operation-conflict"
    modifyIORef' bs.stagedContinuations (Map.insert operationId (reference, payload))
  pure reference

-- | @commit(operation_id, settlement, archive)@.
bodyStoreCommit :: BodyStore -> Text -> RuntimeTurnSettlement -> ByteString -> IO ()
bodyStoreCommit bs operationId0 settlement archive = do
  operationId <- bodyOperation operationId0
  withBodies bs $ do
    output <- Map.lookup operationId <$> readIORef bs.stagedOutputs
    continuation <- Map.lookup operationId <$> readIORef bs.stagedContinuations
    if settlement.outcome == TurnCompleted
      then do
        when (isNothing output || isNothing continuation) $ rpe "body-publication-incomplete"
        when ((settlement.outputReference, settlement.continuationReference) /= (fst <$> output, fst <$> continuation)) $
          rpe "body-publication-mismatch"
      else
        when (isJust output || isJust continuation || isJust settlement.outputReference || isJust settlement.continuationReference) $
          rpe "body-publication-mismatch"
    row <- selectRow bs rowSql [SQLText operationId]
    let text = maybe SQLNull SQLText
        values =
          [ SQLText operationId
          , text (fst <$> output)
          , text (snd <$> output)
          , text (fst <$> continuation)
          , text ((.sessionId) . snd <$> continuation)
          , text ((.workingDirectoryBinding) . snd <$> continuation)
          , maybe SQLNull (SQLBlob . (.sessionJsonl) . snd) continuation
          , SQLBlob archive
          , SQLText (sha256Hex archive)
          , SQLInteger 0
          ]
    case row of
      Just existing -> when (take 9 existing /= take 9 values) $ rpe "operation-conflict"
      Nothing -> immediate bs (execute bs insertSql values)
    discardUnlocked bs operationId

-- | @publish(operation_id)@: mark the committed bodies loadable.
bodyStorePublish :: BodyStore -> Text -> IO ()
bodyStorePublish bs operationId0 = do
  operationId <- bodyOperation operationId0
  withBodies bs $
    immediate bs $ do
      execute bs publishSql [SQLText operationId]
      changed <- changedRows bs.database
      when (changed == 0) $ do
        verified <- verifiedUnlocked bs operationId
        unless verified $ rpe "body-publication-incomplete"

-- | @discard_staged(operation_id)@.
bodyStoreDiscard :: BodyStore -> Text -> IO ()
bodyStoreDiscard bs operationId = withMVar bs.lock $ \_ -> discardUnlocked bs operationId

discardUnlocked :: BodyStore -> Text -> IO ()
discardUnlocked bs operationId = do
  modifyIORef' bs.stagedOutputs (Map.delete operationId)
  modifyIORef' bs.stagedContinuations (Map.delete operationId)

columnText :: SqlValue -> Text
columnText = \case
  SQLText t -> t
  SQLInteger n -> T.pack (show n)
  SQLFloat x -> T.pack (show x)
  SQLBlob b -> TE.decodeUtf8Lenient b
  SQLNull -> "None"

columnBytes :: SqlValue -> IO ByteString
columnBytes = \case
  SQLBlob b -> pure b
  _ -> throwIO (typeError "Pi A2 body column is not bytes")

-- | @load(state_reference)@.
bodyStoreLoad :: BodyStore -> Text -> IO PiContinuationPayloadV1
bodyStoreLoad bs reference0 = do
  reference <- throwLeft (piText "Pi A2 continuation reference" 512 reference0)
  row <- withBodies bs (selectRow bs continuationSql [SQLText reference])
  case row of
    Just [session, binding, body] | SQLNull `notElem` [session, binding, body] -> do
      bytes <- columnBytes body
      throwLeft (mkPiContinuationPayloadV1 (columnText session) (columnText binding) bytes)
    _ -> rpe "continuation-absent"

-- | @load_output(reference)@.
bodyStoreLoadOutput :: BodyStore -> Text -> IO Text
bodyStoreLoadOutput bs reference0 = do
  reference <- throwLeft (piText "Pi A2 output reference" 512 reference0)
  row <- withBodies bs (selectRow bs outputSql [SQLText reference])
  case row of
    Just (value : _) | value /= SQLNull -> pure (columnText value)
    _ -> rpe "output-absent"

-- | @load_workspace_archive(operation_id)@.
bodyStoreLoadArchive :: BodyStore -> Text -> IO ByteString
bodyStoreLoadArchive bs operationId0 = do
  operationId <- bodyOperation operationId0
  row <- withBodies bs (selectRow bs archiveSql [SQLText operationId])
  case row of
    Just [archive, digest] -> do
      bytes <- columnBytes archive
      when (sha256Hex bytes /= columnText digest) $ rpe "workspace-archive-corrupt"
      pure bytes
    _ -> rpe "workspace-archive-absent"

-- | @continuation_workspace_digest(reference)@.
bodyStoreContinuationDigest :: BodyStore -> Text -> IO Text
bodyStoreContinuationDigest bs reference0 = do
  reference <- throwLeft (piText "Pi A2 continuation reference" 512 reference0)
  row <- withBodies bs (selectRow bs digestSql [SQLText reference])
  case row of
    Just (value : _) -> either (const (rpe "workspace-archive-corrupt")) pure (digestText "Pi A2 stored workspace digest" (columnText value))
    _ -> rpe "continuation-absent"

-- | @verified(operation_id)@.
bodyStoreVerified :: BodyStore -> Text -> IO Bool
bodyStoreVerified bs operationId = withBodies bs (verifiedUnlocked bs operationId)

verifiedUnlocked :: BodyStore -> Text -> IO Bool
verifiedUnlocked bs operationId = isJust <$> selectRow bs verifiedSql [SQLText operationId]

bodyStoreClose :: BodyStore -> IO ()
bodyStoreClose bs = withMVar bs.lock $ \_ -> do
  wasClosed <- readIORef bs.closedRef
  unless wasClosed $ do
    writeIORef bs.stagedOutputs Map.empty
    writeIORef bs.stagedContinuations Map.empty
    closeDatabase bs.database
    writeIORef bs.closedRef True

-- ---------------------------------------------------------------------------
-- Operations

-- | A started (or replayed) host operation. Two values are equal exactly
-- when they are the same handle (the reference's @is@).
data PiA2Operation = PiA2Operation
  { token :: Unique
  , runtime :: RuntimeOperation
  }

instance Eq PiA2Operation where
  a == b = a.token == b.token

piA2OperationId :: PiA2Operation -> Text
piA2OperationId o = o.runtime.operationId

piA2RuntimeOperation :: PiA2Operation -> RuntimeOperation
piA2RuntimeOperation o = o.runtime

waitPiA2 :: PiA2Operation -> Maybe Double -> IO RuntimeTurnSettlement
waitPiA2 o = o.runtime.wait

cancelPiA2 :: PiA2Operation -> Text -> IO CancellationDisposition
cancelPiA2 o = o.runtime.cancel

closePiA2 :: PiA2Operation -> IO RuntimeOperationCleanup
closePiA2 o = o.runtime.close

-- | @_ReplayOperation(record)@.
replayOperation :: PiOperationRecord -> IO PiA2Operation
replayOperation record = do
  closedCleanup <- newTVarIO Nothing
  token <- newUnique
  let wait bound = do
        forM_ bound (positive "Pi A2 wait timeout")
        isClosed <- isJust <$> readTVarIO closedCleanup
        when isClosed $ rpe "operation-closed"
        throwLeft (recordSettlement record)
      cancel reason = do
        _ <- throwLeft (piText "Pi A2 cancellation reason" 256 reason)
        pure CancellationTooLate
      close = do
        evidence <- throwLeft (recordCleanupEvidence record)
        atomically $
          readTVar closedCleanup >>= \case
            Just earlier -> pure earlier
            Nothing -> writeTVar closedCleanup (Just evidence) >> pure evidence
  pure PiA2Operation {token, runtime = RuntimeOperation {operationId = record.operationId, wait, cancel, close}}

-- | @_HostOperation@.
data HostOperation = HostOperation
  { host :: PiA2RuntimeHost
  , inner :: RuntimeOperation
  , attachment :: EpisodeAttachment
  , territoryOperationId :: Text
  , settlement :: TVar (Maybe RuntimeTurnSettlement)
  , cleanup :: TVar (Maybe RuntimeOperationCleanup)
  , failure :: TVar (Maybe AgenticusError)
  , finalizing :: TVar Bool
  }

newHostOperation :: PiA2RuntimeHost -> RuntimeOperation -> EpisodeAttachment -> Text -> IO PiA2Operation
newHostOperation host inner attachment territoryOperationId = do
  settlement <- newTVarIO Nothing
  cleanup <- newTVarIO Nothing
  failure <- newTVarIO Nothing
  finalizing <- newTVarIO False
  token <- newUnique
  let o = HostOperation {host, inner, attachment, territoryOperationId, settlement, cleanup, failure, finalizing}
  pure
    PiA2Operation
      { token
      , runtime =
          RuntimeOperation
            { operationId = inner.operationId
            , wait = hostWait o
            , cancel = inner.cancel
            , close = hostClose o
            }
      }

hostWait :: HostOperation -> Maybe Double -> IO RuntimeTurnSettlement
hostWait o bound = do
  current <- atomically ((,,) <$> readTVar o.cleanup <*> readTVar o.settlement <*> readTVar o.failure)
  case current of
    (Just _, _, _) -> rpe "operation-closed"
    (_, Just s, _) -> pure s
    (_, _, Just e) -> throwIO e
    _ -> do
      result <- o.inner.wait bound
      claimed <- claimFinalization o
      unless claimed $ rpe "operation-closed"
      finalizeOwned o result `finally` releaseFinalization o

hostClose :: HostOperation -> IO RuntimeOperationCleanup
hostClose o = do
  claimed <- claimFinalization o
  if not claimed
    then readTVarIO o.cleanup >>= maybe (rpe "operation-closed") pure
    else
      ( do
          let host = o.host
          known <- receiptPi host.adapter o.inner.operationId
          receipt <- case known of
            Just s -> pure (Just s)
            Nothing -> do
              _ <- o.inner.cancel "host-close"
              waited <- try (o.inner.wait (Just (host.config.cancellationGrace * 2)))
              case waited of
                Right s -> pure (Just s)
                Left (e :: AgenticusError)
                  | e.errorClass `elem` [TimeoutError, RuntimeProtocolError] -> receiptPi host.adapter o.inner.operationId
                  | otherwise -> throwIO e
          case receipt of
            Just s -> void (try @AgenticusError (finalizeOwned o s))
            Nothing -> finalizeIndeterminateOwned o
          readTVarIO o.cleanup >>= maybe (rpe "operation-closed") pure
      )
        `finally` releaseFinalization o

claimFinalization :: HostOperation -> IO Bool
claimFinalization o = atomically $ do
  busy <- readTVar o.finalizing
  when busy retry
  done <- isJust <$> readTVar o.cleanup
  if done then pure False else writeTVar o.finalizing True >> pure True

releaseFinalization :: HostOperation -> IO ()
releaseFinalization o = atomically (writeTVar o.finalizing False)

aggregateClean :: HostOperation -> RuntimeOperationCleanup -> AttachmentSettlement -> IO Bool
aggregateClean o innerCleanup attached = do
  lease <- providerLookup o.host.provider o.territoryOperationId
  pure (Petrus.Agenticus.Runtime.Operation.cleanupVerified innerCleanup && attached.settlement.verified && isNothing lease)

-- | @_finalize_owned(result)@.
finalizeOwned :: HostOperation -> RuntimeTurnSettlement -> IO RuntimeTurnSettlement
finalizeOwned o result = flip finally (operationFinished o.host o.inner.operationId) $ do
  let host = o.host
      operationId = o.inner.operationId
  outcome <- try $ do
    innerCleanup <- o.inner.close
    attached <- Episode.settle o.attachment (host.config.cancellationGrace * 2)
    verified <- aggregateClean o innerCleanup attached
    unless verified $ rpe "host-cleanup-uncertain"
    bodyStoreCommit host.bodies operationId result attached.archive
    _ <- ledgerSettle host.ledger operationId result
    evidence <-
      throwLeft (mkRuntimeOperationCleanup operationId innerCleanup.disposition innerCleanup.code innerCleanup.physicalErasureGuaranteed)
    _ <- ledgerUpgradeCleanup host.ledger operationId evidence
    publishBodies host operationId
    atomically $ do
      writeTVar o.settlement (Just result)
      writeTVar o.cleanup (Just evidence)
    pure result
  case outcome of
    Right value -> pure value
    Left (raised :: SomeException) -> do
      let error' = case fromException raised of
            Just e | isJust (runtimeProtocolErrorCode e) -> e
            _ -> runtimeProtocolError "host-cleanup-uncertain"
      bodyStoreDiscard host.bodies operationId
      turn <- operationTurn host operationId
      _ <- trySync $ do
        indeterminate <-
          throwLeft (mkRuntimeTurnSettlement (Episode.episodeId o.attachment) turn TurnIndeterminate 0 "host-cleanup-uncertain" Nothing Nothing)
        ledgerSettle host.ledger operationId indeterminate
      evidence <- throwLeft (mkRuntimeOperationCleanup operationId RuntimeCleanupUnverified "cleanup-uncertain" False)
      atomically $ do
        writeTVar o.failure (Just error')
        writeTVar o.cleanup (Just evidence)
      case fromException raised of
        Just (_ :: SomeAsyncException) -> throwIO raised
        Nothing -> throwIO error'

-- | @_finalize_indeterminate_owned()@.
finalizeIndeterminateOwned :: HostOperation -> IO ()
finalizeIndeterminateOwned o = do
  let host = o.host
      operationId = o.inner.operationId
  innerCleanup <-
    trySync o.inner.close >>= \case
      Right value -> pure value
      Left _ -> throwLeft (mkRuntimeOperationCleanup operationId RuntimeCleanupUnverified "cleanup-uncertain" False)
  clean0 <-
    trySync (Episode.settle o.attachment (host.config.cancellationGrace * 2) >>= aggregateClean o innerCleanup)
      >>= either (const (pure False)) pure
  record <- ledgerLookup host.ledger operationId >>= maybe (rpe "operation-absent") pure
  settled <- trySync $ do
    indeterminate <- throwLeft (mkRuntimeTurnSettlement record.episodeId record.turnId TurnIndeterminate 0 "close-indeterminate" Nothing Nothing)
    ledgerSettle host.ledger operationId indeterminate
  let clean = clean0 && either (const False) (const True) settled
      disposition = if clean then RuntimeCleanupClean else RuntimeCleanupUnverified
  evidence0 <- throwLeft (mkRuntimeOperationCleanup operationId disposition (if clean then "client-closed" else "cleanup-uncertain") False)
  evidence <-
    if clean
      then
        trySync (ledgerUpgradeCleanup host.ledger operationId evidence0) >>= \case
          Right _ -> pure evidence0
          Left _ -> throwLeft (mkRuntimeOperationCleanup operationId RuntimeCleanupUnverified "cleanup-uncertain" False)
      else pure evidence0
  atomically (writeTVar o.cleanup (Just evidence))
  bodyStoreDiscard host.bodies operationId
  operationFinished host operationId

-- ---------------------------------------------------------------------------
-- The host

-- | Which client factory the adapter was composed with (the reference's
-- tests inspect @type(host._adapter._factory)@).
data PiA2FactoryKind = NoClientFactory | ScriptedClientFactory | InjectedClientFactory
  deriving stock (Eq, Show)

-- | Seams the reference's tests reach by monkeypatching.
newtype PiA2HostHooks = PiA2HostHooks
  { publishBodies :: Maybe (Text -> IO ())
  -- ^ Replaces @host._bodies.publish@.
  }

noPiA2HostHooks :: PiA2HostHooks
noPiA2HostHooks = PiA2HostHooks Nothing

data HostState = HostState
  { probed :: Maybe RuntimeProbeResult
  , scriptedReady :: Bool
  , authorityRequested :: Bool
  , authorityReady :: Bool
  , closed :: Bool
  , closeError :: Maybe AgenticusError
  , active :: Map Text PiA2Operation
  , turns :: Map Text TurnId
  , territories :: Map Text Text
  }

-- | @_PiA2RuntimeHost@: one owned Pi A2 Local host lifecycle with
-- replay-before-authority.
data PiA2RuntimeHost = PiA2RuntimeHost
  { config :: PiA2RuntimeHostConfig
  , authority :: PiA2DirectAuthority
  , root :: FilePath
  , storage :: ConnectionStorage
  , custody :: AgentConnectionCustody
  , bodies :: BodyStore
  , ledger :: SqlitePiOperationLedger
  , adapter :: PiRuntimeAdapter
  , provider :: EnvironmentProvider
  , clock :: IO Double
  , recovered :: [RuntimeTurnSettlement]
  , scriptedConformance :: Bool
  , factoryKind :: PiA2FactoryKind
  , lifecycle :: Text
  , lock :: MVar ()
  , lifecycleLock :: MVar ()
  , state :: IORef HostState
  , hooks :: IORef PiA2HostHooks
  }

hostConfig :: PiA2RuntimeHost -> PiA2RuntimeHostConfig
hostConfig h = h.config

hostRecoveredSettlements :: PiA2RuntimeHost -> [RuntimeTurnSettlement]
hostRecoveredSettlements h = h.recovered

hostFactoryKind :: PiA2RuntimeHost -> PiA2FactoryKind
hostFactoryKind h = h.factoryKind

hostProvider :: PiA2RuntimeHost -> EnvironmentProvider
hostProvider h = h.provider

hostAdapter :: PiA2RuntimeHost -> PiRuntimeAdapter
hostAdapter h = h.adapter

hostLedger :: PiA2RuntimeHost -> SqlitePiOperationLedger
hostLedger h = h.ledger

hostStorage :: PiA2RuntimeHost -> ConnectionStorage
hostStorage h = h.storage

hostBodies :: PiA2RuntimeHost -> BodyStore
hostBodies h = h.bodies

setPiA2HostHooks :: PiA2RuntimeHost -> PiA2HostHooks -> IO ()
setPiA2HostHooks h = writeIORef h.hooks

publishBodies :: PiA2RuntimeHost -> Text -> IO ()
publishBodies h operationId = do
  hooks <- readIORef h.hooks
  maybe (bodyStorePublish h.bodies) id hooks.publishBodies operationId

withHostLock :: PiA2RuntimeHost -> IO a -> IO a
withHostLock h action = withMVar h.lock (const action)

ensureOpen :: PiA2RuntimeHost -> IO ()
ensureOpen h = do
  st <- readIORef h.state
  when st.closed $ rpe "host-closed"

lifecycleOperation :: PiA2RuntimeHost -> Text -> Text
lifecycleOperation h purpose = "pi-a2-" <> h.lifecycle <> "-" <> purpose

-- | @_territory_operation(operation_id)@.
piA2TerritoryOperation :: Text -> Text
piA2TerritoryOperation operationId = "pi-a2-territory-" <> sha256Hex (TE.encodeUtf8 operationId)

-- | @_attachment_identity(operation_id)@.
piA2AttachmentIdentity :: Text -> Text
piA2AttachmentIdentity operationId = "pi-a2-attachment-" <> sha256Hex (TE.encodeUtf8 operationId)

operationFinished :: PiA2RuntimeHost -> Text -> IO ()
operationFinished h operationId = withHostLock h (modifyIORef' h.state (\s -> s {active = Map.delete operationId s.active}))

operationTurn :: PiA2RuntimeHost -> Text -> IO TurnId
operationTurn h operationId = do
  known <- withHostLock h (Map.lookup operationId . (.turns) <$> readIORef h.state)
  case known of
    Just turn -> pure turn
    Nothing -> (.turnId) <$> (ledgerLookup h.ledger operationId >>= maybe (rpe "operation-absent") pure)

-- | @authority_requested@.
hostAuthorityRequested :: PiA2RuntimeHost -> IO Bool
hostAuthorityRequested h = withHostLock h ((.authorityRequested) <$> readIORef h.state)

newHost
  :: PiA2RuntimeHostConfig
  -> PiA2DirectAuthority
  -> FilePath
  -> ConnectionStorage
  -> AgentConnectionCustody
  -> BodyStore
  -> SqlitePiOperationLedger
  -> PiRuntimeAdapter
  -> EnvironmentProvider
  -> IO Double
  -> Bool
  -> PiA2FactoryKind
  -> IO PiA2RuntimeHost
newHost config authority root storage custody bodies ledger adapter provider clock scriptedConformance factoryKind = do
  lifecycle <- TE.decodeUtf8 . convertToBase Base16 <$> (getRandomBytes 16 :: IO ByteString)
  records <- ledgerRecover ledger
  recovered <- traverse (throwLeft . recordSettlement) records
  lock <- newMVar ()
  lifecycleLock <- newMVar ()
  state <- newIORef (HostState Nothing False False False False Nothing Map.empty Map.empty Map.empty)
  hooks <- newIORef noPiA2HostHooks
  let h =
        PiA2RuntimeHost
          { config
          , authority
          , root
          , storage
          , custody
          , bodies
          , ledger
          , adapter
          , provider
          , clock
          , recovered
          , scriptedConformance
          , factoryKind
          , lifecycle
          , lock
          , lifecycleLock
          , state
          , hooks
          }
  _ <- recover custody (lifecycleOperation h "recover")
  enrollHost custody config.hostId (lifecycleOperation h "enroll")
  pure h

-- | @probe()@: authority-free probing of the exact external installation.
probeHost :: PiA2RuntimeHost -> IO RuntimeProbeResult
probeHost h = withHostLock h $ do
  ensureOpen h
  when h.scriptedConformance $ rpe "scripted-readiness-only"
  let path = fmap T.unpack
  result <-
    probe
      h.adapter
      ProbePaths
        { cliPath = path h.config.cliPath
        , nodePath = path h.config.nodePath
        , packageRoot = path h.config.packageRoot
        , ccPatchRoot = Nothing
        }
  modifyIORef' h.state (\s -> s {probed = Just result})
  pure result

-- | @scripted_readiness()@: ready only Petrus's script interpreter without
-- probing Pi or authority.
scriptedReadiness :: PiA2RuntimeHost -> IO PiA2ScriptedReadiness
scriptedReadiness h = withHostLock h $ do
  ensureOpen h
  unless h.scriptedConformance $ rpe "scripted-readiness-unavailable"
  enableScriptedConformance h.adapter
  modifyIORef' h.state (\s -> s {scriptedReady = True})
  pure PiA2ScriptedReadiness {supportLabel = scriptedSupportLabel, ready = True}

-- | @_fingerprint(start)@.
hostFingerprint :: PiA2RuntimeHost -> PiA2RuntimeStart -> IO Text
hostFingerprint h start = do
  config <- adapterConfig h.adapter
  inner <- throwLeft (piDurableWorkFingerprint config start.episodeId start.turnId start.prompt h.authority.connection start.continuation)
  throwLeft (piA2DurableFingerprint h.config start inner)

-- | @start(start)@: replay, admission, authority, territory and the inner
-- Pi operation, in that order.
startHost :: PiA2RuntimeHost -> PiA2RuntimeStart -> IO PiA2Operation
startHost h start0 = withMVar h.lifecycleLock $ \_ -> do
  start <- newPiA2RuntimeStart start0
  fingerprint <- hostFingerprint h start
  admitted <- withHostLock h $ do
    ensureOpen h
    existing <- ledgerLookup h.ledger start.operationId
    case existing of
      Just record -> do
        when (record.fingerprint /= fingerprint) $ rpe "operation-conflict"
        live <- Map.lookup start.operationId . (.active) <$> readIORef h.state
        case live of
          Just operation -> pure (Just operation)
          Nothing
            | record.phase == PhaseSettled -> do
                verified <- bodyStoreVerified h.bodies start.operationId
                if record.cleanup `elem` [RuntimeCleanupClean, RuntimeCleanupNotCreated] && verified
                  then Just <$> replayOperation record
                  else rpe "operation-indeterminate"
            | otherwise -> rpe "operation-indeterminate"
      Nothing -> do
        when
          ( not (start.policy.capabilities `Set.isSubsetOf` h.config.capabilities)
              || start.policy.maxToolCalls > h.config.maxToolCalls
          )
          $ rpe "operation-policy-exceeds-host"
        forM_ start.continuation $ \c -> do
          stored <- bodyStoreContinuationDigest h.bodies c.stateReference
          when (stored /= start.workspaceDigest) $ rpe "operation-conflict"
        requireReady h
        record <- ledgerAdmit h.ledger start.operationId fingerprint start.episodeId start.turnId
        when (record.fingerprint /= fingerprint) $ rpe "operation-conflict"
        modifyIORef' h.state (\s -> s {turns = Map.insert start.operationId start.turnId s.turns})
        pure Nothing
  maybe (launch h start) pure admitted

launch :: PiA2RuntimeHost -> PiA2RuntimeStart -> IO PiA2Operation
launch h start = do
  attached <- newIORef Nothing
  let territory = piA2TerritoryOperation start.operationId
      base = start.workspaceArchive
  outcome <- try $ do
    connection <- hostConnection h
    spec <- either throwIO pure (mkEnvironmentSpec Nothing (Set.toList requiredEnvironmentCapabilities))
    binding <- openMotusBinding h.provider territory spec base start.workspaceDigest
    now <- h.clock
    attachment <-
      newEpisodeAttachment
        start.episodeId
        hostSnapshot
        (motusBinding binding)
        (piA2AttachmentIdentity start.operationId)
        (now + h.config.attachmentTimeout)
        EpisodeOptions {attachmentEpoch = 1, admission = Nothing, target = Nothing, clock = h.clock}
    writeIORef attached (Just attachment)
    execution <- bindingExecution binding
    workspace <- newMotusWorkspaceAdapter h.provider execution h.config.testCommand h.config.commandTimeout
    gw <- Episode.gateway attachment (workspaceHandsAdapter workspace) 256
    grant <-
      openGrant
        (Episode.grants attachment)
        GrantSpec
          { specCapabilities = Set.toList start.policy.capabilities
          , specWritablePaths = Set.toList start.policy.writablePaths
          , specWritableRoots = Set.toList start.policy.writableRoots
          , specDeniedWritableRoots = controlRoots
          , specAllowedArgv = Set.toList h.config.allowedArgv
          , specDeadline = Episode.episodeDeadline attachment
          , specMaxCalls = toInteger start.policy.maxToolCalls
          }
    operation <-
      startPi
        h.adapter
        PiRuntimeInvocation
          { operationId = start.operationId
          , episodeId = start.episodeId
          , turnId = start.turnId
          , prompt = start.prompt
          , connection
          , attachment
          , gateway = gw
          , grantEpoch = grant.grantEpoch
          , continuation = start.continuation
          }
    hosted <- newHostOperation h (piRuntimeOperation operation) attachment territory
    withHostLock h $
      modifyIORef' h.state $ \s ->
        s {active = Map.insert start.operationId hosted s.active, territories = Map.insert start.operationId territory s.territories}
    pure hosted
  case outcome of
    Right operation -> pure operation
    Left (raised :: SomeException) -> do
      attachment <- readIORef attached
      (clean0, archive) <- rollbackAttachment h attachment territory base
      settlement <-
        throwLeft
          ( mkRuntimeTurnSettlement
              start.episodeId
              start.turnId
              (if clean0 then TurnFailed else TurnIndeterminate)
              0
              (if clean0 then "runtime-start-failed" else "host-cleanup-uncertain")
              Nothing
              Nothing
          )
      clean <-
        if not clean0
          then pure False
          else
            fmap (either (const False) (const True)) . trySync $ do
              bodyStoreCommit h.bodies start.operationId settlement archive
              _ <- ledgerSettle h.ledger start.operationId settlement
              notCreated <- throwLeft (mkRuntimeOperationCleanup start.operationId RuntimeCleanupNotCreated "client-not-created" False)
              _ <- ledgerUpgradeCleanup h.ledger start.operationId notCreated
              publishBodies h start.operationId
      unless clean $ void (trySync (ledgerSettle h.ledger start.operationId settlement))
      case fromException raised of
        Just (e :: AgenticusError) | isJust (runtimeProtocolErrorCode e) -> throwIO e
        _ -> case fromException raised of
          Just (_ :: SomeAsyncException) -> throwIO raised
          Nothing -> rpe (if clean then "runtime-start-failed" else "host-cleanup-uncertain")

-- | @_rollback_attachment(attachment, territory_operation_id, base_archive)@.
rollbackAttachment :: PiA2RuntimeHost -> Maybe EpisodeAttachment -> Text -> ByteString -> IO (Bool, ByteString)
rollbackAttachment h attachment territory base =
  fmap (either (const (False, B.empty)) id) . trySync $ case attachment of
    Just a -> do
      settled <- Episode.settle a (h.config.cancellationGrace * 2)
      lease <- providerLookup h.provider territory
      pure (settled.settlement.verified && isNothing lease, settled.archive)
    Nothing ->
      providerLookup h.provider territory >>= \case
        Nothing -> pure (True, base)
        Just lease -> do
          cleanup <- providerDestroy h.provider lease
          remaining <- providerLookup h.provider territory
          pure (Petrus.Motus.Execution.cleanupVerified cleanup && isNothing remaining, base)

-- | @_connection()@: the one-shot host authority.
hostConnection :: PiA2RuntimeHost -> IO ConnectionView
hostConnection h = withHostLock h $ do
  let identity = h.authority.connection
  current <-
    (Just <$> lookupConnection h.custody identity.connectionId) `catch` \(e :: AgenticusError) ->
      if e.errorClass `isSubclassOf` CustodyError then pure Nothing else throwIO e
  st <- readIORef h.state
  let readyView = case current of
        Just view | view.status == StatusReady -> Just view
        _ -> Nothing
  forM_ readyView $ \view -> when (view.identity /= identity) $ rpe "connection-identity-mismatch"
  case readyView of
    Just view | st.authorityReady -> pure view
    _ -> do
      when st.authorityRequested $ rpe "authority-unavailable"
      modifyIORef' h.state (\s -> s {authorityRequested = True})
      supplied <- h.authority.supplyApiKey
      when (BA.null supplied || BA.length supplied > maxKeyBytes) $ do
        eraseBuffer supplied
        rpe "credential-invalid"
      copy <- BA.copy supplied (const (pure ()))
      opaque <- opaqueStateFromBuffer copy
      eraseBuffer supplied
      flip finally (eraseOpaqueState opaque) $ do
        view <- case readyView of
          Just ready' -> rotate h.custody ready'.identity.connectionId opaque (lifecycleOperation h "rotate")
          Nothing -> authorize h.custody identity opaque (lifecycleOperation h "authorize")
        modifyIORef' h.state (\s -> s {authorityReady = True})
        pure view

-- | @_require_ready()@.
requireReady :: PiA2RuntimeHost -> IO ()
requireReady h = do
  st <- readIORef h.state
  if h.scriptedConformance
    then unless st.scriptedReady $ rpe "runtime-not-ready"
    else case st.probed of
      Just result
        | result.disposition == ProbeReady
        , Just installation <- result.installation -> do
            let expected = piNativeA2Local.identity
            when
              ( result.runtime /= expected
                  || installation.runtime /= expected
                  || installation.adapterContractVersion /= 1
                  || not (requiredInstallationCapabilities `Set.isSubsetOf` installation.capabilities)
              )
              $ rpe "runtime-incompatible"
      _ -> rpe "runtime-not-ready"

-- | @load_output(reference)@.
loadOutput :: PiA2RuntimeHost -> Text -> IO Text
loadOutput h reference = withHostLock h (ensureOpen h) >> bodyStoreLoadOutput h.bodies reference

-- | @load_workspace_archive(operation_id)@.
loadWorkspaceArchive :: PiA2RuntimeHost -> Text -> IO ByteString
loadWorkspaceArchive h operationId = withHostLock h (ensureOpen h) >> bodyStoreLoadArchive h.bodies operationId

-- | @acknowledge(operation_id)@.
acknowledgeHost :: PiA2RuntimeHost -> Text -> IO PiOperationRecord
acknowledgeHost h operationId = withHostLock h (ensureOpen h) >> ledgerAcknowledge h.ledger operationId

-- | @close()@: ordered, best-effort teardown that proves aggregate cleanup
-- or fails with @host-cleanup-uncertain@ (and keeps failing).
closeHost :: PiA2RuntimeHost -> IO Bool
closeHost h = withMVar h.lifecycleLock $ \_ -> do
  begun <- withHostLock h $ do
    st <- readIORef h.state
    if st.closed
      then pure (Left st.closeError)
      else do
        writeIORef h.state st {closed = True}
        pure (Right (Map.elems st.active))
  case begun of
    Left (Just e) -> throwIO e
    Left Nothing -> pure True
    Right operations -> do
      cleanRef <- newIORef True
      let checked action = trySync action >>= \result -> modifyIORef' cleanRef (&& either (const False) id result)
      forM_ operations $ \operation -> checked (Petrus.Agenticus.Runtime.Operation.cleanupVerified <$> closePiA2 operation)
      checked $ do
        records <- ledgerRecords h.ledger
        and <$> forM records (fmap Petrus.Agenticus.Runtime.Operation.cleanupVerified . throwLeft . recordCleanupEvidence)
      territories <- withHostLock h (Map.elems . (.territories) <$> readIORef h.state)
      forM_ territories $ \territory -> checked (isNothing <$> providerLookup h.provider territory)
      checked $ do
        removal <- removeHost h.custody h.config.hostId (lifecycleOperation h "remove")
        pure (removal.cleanup.unresolved == 0)
      requiresErasure <-
        trySync (storedConnectionRequiresErasure h) >>= \case
          Right value -> pure value
          Left _ -> modifyIORef' cleanRef (const False) >> pure False
      when requiresErasure $ checked $ do
        let connectionId = h.authority.connection.connectionId
        revoked <- revoke h.custody connectionId (lifecycleOperation h "revoke")
        erased <- Custody.erase h.custody connectionId (lifecycleOperation h "erase")
        pure
          ( revoked.cleanup.unresolved == 0
              && erased.cleanup.unresolved == 0
              && erased.keyErasure.erased
              && erased.connection.status == StatusReauthorizationRequired
          )
      forM_ ["materializations", "runtime"] $ \name ->
        try (listDirectory (h.root </> name)) >>= \case
          Right entries -> modifyIORef' cleanRef (&& null entries)
          Left e
            | isDoesNotExistError e -> pure ()
            | otherwise -> modifyIORef' cleanRef (const False)
      checked (bodyStoreClose h.bodies >> pure True)
      checked (ledgerClose h.ledger >> pure True)
      checked (h.storage.close >> pure True)
      clean <- readIORef cleanRef
      failure <- withHostLock h $ do
        unless clean $ modifyIORef' h.state (\s -> s {closeError = Just (runtimeProtocolError "host-cleanup-uncertain")})
        (.closeError) <$> readIORef h.state
      maybe (pure True) throwIO failure

storedConnectionRequiresErasure :: PiA2RuntimeHost -> IO Bool
storedConnectionRequiresErasure h = do
  snapshot <- h.storage.load
  pure $ case [c | c <- snapshot.connections, c.connectionId == h.authority.connection.connectionId] of
    stored : _ -> stored.status /= "reauthorization_required"
    [] -> False

-- ---------------------------------------------------------------------------
-- Composition

-- | @compose_pi_a2_runtime(config=, authority=, clock=)@: the
-- external-qualification host with exact owned collaborators.
composePiA2Runtime :: PiA2RuntimeHostConfig -> PiA2DirectAuthority -> IO Double -> IO PiA2RuntimeHost
composePiA2Runtime config authority clock = do
  provider <- localProvider <$> newLocalProcessEnvironment
  composePiA2RuntimeWith config authority provider clock Nothing

-- | @_compose_pi_a2_runtime(...)@: collaborator-aware construction for
-- bounded failure injection.
composePiA2RuntimeWith
  :: PiA2RuntimeHostConfig -> PiA2DirectAuthority -> EnvironmentProvider -> IO Double -> Maybe PiHelperFactory -> IO PiA2RuntimeHost
composePiA2RuntimeWith config authority provider clock factory =
  compose config authority provider clock factory False (maybe NoClientFactory (const InjectedClientFactory) factory)

compose
  :: PiA2RuntimeHostConfig
  -> PiA2DirectAuthority
  -> EnvironmentProvider
  -> IO Double
  -> Maybe PiHelperFactory
  -> Bool
  -> PiA2FactoryKind
  -> IO PiA2RuntimeHost
compose config0 authority provider clock factory scripted kind = do
  config <- newPiA2RuntimeHostConfig config0
  when (authority.connection.provider /= config.provider) $
    throwIO (valueError "Pi A2 authority provider must match the configured provider")
  when (providerName provider /= "local-process") $ throwIO (valueError "Pi A2 host supports only the Local Motus provider")
  unless (requiredEnvironmentCapabilities `Set.isSubsetOf` providerCapabilities provider) $
    throwIO (valueError "Pi A2 Local provider lacks required capabilities")
  root <- privateRoot config.stateRoot
  runtimeRoot <- privateSubdirectory root "runtime"
  opened <- newIORef []
  let owned closer = modifyIORef' opened (closer :)
  ( do
      storage <- openSqliteConnectionStorage (root </> "connection.sqlite3")
      owned storage.close
      materializer <- newPrivateFileMaterializer (root </> "materializations")
      let custody = agentConnectionCustody storage authority.keyOperations materializer clock
      bodies <- openBodyStore (root </> "bodies.sqlite3")
      owned (bodyStoreClose bodies)
      ledger <- openSqlitePiOperationLedger (root </> "operations.sqlite3")
      owned (ledgerClose ledger)
      piCustody <- piConnectionCustody custody
      let defaults = piRuntimeConfig config.provider config.model config.workingDirectory runtimeRoot
      adapter <-
        newPiRuntimeAdapter
          PiRuntimeConfig
            { provider = config.provider
            , model = config.model
            , workingDirectory = config.workingDirectory
            , runtimeRoot
            , hostId = config.hostId
            , ccPatch = False
            , credentialTtl = config.credentialTtl
            , wallTimeout = config.wallTimeout
            , cancellationGrace = config.cancellationGrace
            , maxEvents = defaults.maxEvents
            , maxToolCalls = defaults.maxToolCalls
            , maxFrameBytes = defaults.maxFrameBytes
            , maxOutputBytes = defaults.maxOutputBytes
            , maxSessionBytes = defaults.maxSessionBytes
            , maxAuthBytes = defaults.maxAuthBytes
            , territoryProfile = "local"
            }
          (piContinuationCodec PiContinuationOperations {store = bodyStoreContinuation bodies, load = bodyStoreLoad bodies})
          PiTurnOperations {storeTurn = bodyStoreTurn bodies}
          piCustody
          clock
          factory
      newHost config authority root storage custody bodies ledger adapter provider clock scripted kind
    )
    `onException` (readIORef opened >>= mapM_ (void . trySync))

-- | @compose_pi_a2_scripted_runtime(config=, authority=, script=, clock=)@:
-- the supported credential-free scripted host lifecycle.
--
-- This public seam qualifies Petrus-owned Pi A2 Local composition and
-- lifecycle only. It neither probes nor claims an external Pi, model, or
-- provider installation. Callers supply only finite immutable script data;
-- Petrus owns the interpreter and the exact local process environment.
composePiA2ScriptedRuntime :: PiA2RuntimeHostConfig -> PiA2DirectAuthority -> [PiA2ScriptedTurn] -> IO Double -> IO PiA2RuntimeHost
composePiA2ScriptedRuntime config authority script clock = do
  when (null script) $ throwIO (typeError "scripted Pi conformance requires finite PiA2ScriptedTurn data")
  turns <- traverse (throwLeft . mkPiA2ScriptedTurn) script
  factory <- piA2ScriptedFactory turns
  provider <- localProvider <$> newLocalProcessEnvironment
  compose config authority provider clock (Just factory) True ScriptedClientFactory

-- | @_compose_pi_a2_scripted_client_runtime(...)@: the internal
-- conformance harness for exercising host failure boundaries.
composePiA2ScriptedClientRuntime
  :: PiA2RuntimeHostConfig -> PiA2DirectAuthority -> PiHelperFactory -> Maybe EnvironmentProvider -> IO Double -> IO PiA2RuntimeHost
composePiA2ScriptedClientRuntime config authority factory provider clock = do
  selected <- maybe (localProvider <$> newLocalProcessEnvironment) pure provider
  compose config authority selected clock (Just factory) True InjectedClientFactory
