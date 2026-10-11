-- | The qualified Codex Gondolin lane's Activity boundary: the host-local
-- Activity custody adapter (@codex._CodexGondolinActivityAdapter@) and the
-- private host-local process bridge
-- (@petrus.agenticus.runtime._codex_gondolin_service@): its canonical
-- terminal wire value, the Unix-socket runtime service behind one
-- process-safe fence and SQLite replay ledger, and the reconstructible
-- Worker-side Activity client.
--
-- Only versioned data crosses either boundary. Every frame is the
-- reference's @_json_bytes@ spelling (sorted keys, compact separators,
-- ASCII), and the ledger is the reference's exact table, so a Python
-- client, service, or ledger reader interoperates with these.
module Petrus.Agenticus.Runtime.CodexGondolin
  ( -- * Constants
    codexGondolinActivity
  , serviceActivity
  , endpointVariable
  , tokenVariable
  , maxRequest
  , maxResponse
  , serviceDdl
  , terminalErrors
    -- * Wire values
  , jsonBytes
  , terminalError
  , parseTerminal
    -- * The host-local Activity adapter
  , CodexGondolinActivityAdapter
  , newCodexGondolinActivityAdapter
  , runCodexGondolinActivityAdapter
    -- * The runtime service
  , CodexGondolinRuntimeService
  , newCodexGondolinRuntimeService
  , startCodexGondolinRuntimeService
  , closeCodexGondolinRuntimeService
    -- * The Worker-side Activity client
  , codexGondolinActivityClient
  , codexGondolinActivityClientWith
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (IOException, SomeAsyncException, SomeException, bracket, finally, fromException, onException, throwIO, try)
import Control.Monad (forM_, unless, void, when)
import Data.Bits (xor, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Char (isAscii)
import Data.IORef
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Foreign.C.Types (CInt (..))
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBytes
import Petrus.Activity (ActivityExecutionContext (..), ActivityInvocation (..), ExecutionPolicyFields (..), policyFields)
import Petrus.Agenticus.Attachment.Binding (AttachmentCoordinates (..))
import Petrus.Agenticus.Attachment.Episode (EpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Connection.Custody (ConnectionIdentity (..), ConnectionStatus (..), ConnectionView (..))
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Sqlite qualified as Sql
import Petrus.Agenticus.Internal.Validate (sha256Hex)
import Petrus.Agenticus.Runtime.Codex
  ( CodexLane (..)
  , CodexRuntimeAdapter
  , CodexRuntimeInvocation (..)
  , closeCodexOperation
  , codexAdapterLane
  , codexOperationId
  , newCodexRuntimeInvocation
  , startCodex
  , waitCodexOperation
  )
import Petrus.Agenticus.Runtime.HostSupport (pyJsonLoadsBytes)
import Petrus.Agenticus.Runtime.Operation
  ( RuntimeCleanupDisposition
  , RuntimeOperationCleanup (..)
  , cleanupDispositionText
  , mkRuntimeOperationCleanup
  , runtimeProtocolError
  , runtimeProtocolErrorCode
  )
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..), mkRuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Continuation (continuationFromData)
import Petrus.Agenticus.Thread.Identity (EpisodeId, LifecycleId (..), TurnId, lifecycleIdFromData, lifecycleIdToData)
import Petrus.Agenticus.Thread.Lifecycle (StrEnum (..), TurnOutcome)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Directory (createDirectoryIfMissing, pathIsSymbolicLink)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Directory qualified as PosixDirectory
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as PosixIO
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd (..), ProcessID)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Constants

-- | @codex._CODEX_GONDOLIN_ACTIVITY@: the host-local Activity name.
codexGondolinActivity :: Text
codexGondolinActivity = "petrus.agenticus.codex.gondolin"

-- | @_ACTIVITY@: the reconstructible Worker-side Activity name.
serviceActivity :: Text
serviceActivity = "agenticus.codex.a3.gondolin"

endpointVariable, tokenVariable :: String
endpointVariable = "PETRUS_CODEX_GONDOLIN_ENDPOINT"
tokenVariable = "PETRUS_CODEX_GONDOLIN_TOKEN"

maxRequest, maxResponse :: Int
maxRequest = 64 * 1024
maxResponse = 16 * 1024

frameTimeout, closeTimeout :: Double
frameTimeout = 1.0
closeTimeout = 2.0

schemaVersion :: Integer
schemaVersion = 1

-- | @_DDL@, byte for byte.
serviceDdl :: Text
serviceDdl =
  "CREATE TABLE operations (\n\
  \ operation_id TEXT PRIMARY KEY NOT NULL,\n\
  \ request_fingerprint TEXT NOT NULL\n\
  \  CHECK(length(request_fingerprint)=64 AND request_fingerprint NOT GLOB '*[^0-9a-f]*'),\n\
  \ phase TEXT NOT NULL CHECK(phase IN ('executing','terminal')),\n\
  \ terminal BLOB,\n\
  \ episode_id TEXT NOT NULL, turn_id TEXT NOT NULL,\n\
  \ CHECK((phase='executing' AND terminal IS NULL) OR (phase='terminal' AND terminal IS NOT NULL)))"

-- | @_ERRORS@.
terminalErrors :: [Text]
terminalErrors =
  [ "unauthorized"
  , "frame-too-large"
  , "request-invalid"
  , "operation-conflict"
  , "operation-indeterminate"
  , "runtime-failed"
  ]

terminalResultFields :: [Text]
terminalResultFields =
  [ "version"
  , "operation_id"
  , "episode_id"
  , "turn_id"
  , "outcome"
  , "accepted_appends"
  , "termination_code"
  , "output_reference"
  , "continuation_reference"
  , "cleanup"
  ]

inputFields :: [Text]
inputFields =
  [ "version"
  , "episode_id"
  , "turn_id"
  , "prompt"
  , "attachment_id"
  , "attachment_epoch"
  , "connection_id"
  , "authority_epoch"
  , "state_version"
  , "continuation"
  ]

-- ---------------------------------------------------------------------------
-- Wire values

-- | @_json_bytes(value)@: @json.dumps(value, sort_keys=True,
-- separators=(",", ":"), ensure_ascii=True)@. 'Left' where the reference
-- raises (an integer past CPython's digit limit, or nesting past its
-- recursion limit).
jsonBytes :: Json -> Either Text ByteString
jsonBytes value = either (Left . T.pack . show) Right (J.dumps options value)
  where
    options = J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":", J.sortKeys = True}

-- | @_terminal_error(code)@.
terminalError :: Text -> Json
terminalError code = Object [("ok", Bool False), ("error", String code)]

encodedTerminal :: Json -> ByteString
encodedTerminal value = either (const fallback) id (jsonBytes value)
  where
    fallback = "{\"error\":\"runtime-failed\",\"ok\":false}"

keysOf :: Json -> Set.Set Text
keysOf = \case
  Object members -> Set.fromList (map fst members)
  _ -> Set.empty

member :: Text -> Json -> Maybe Json
member name = \case
  Object members -> lookup name members
  _ -> Nothing

boundedString :: Bool -> Maybe Json -> Bool
boundedString nullable = \case
  Just Null -> nullable
  Just (String s) -> not (T.null s) && T.length s <= 4096
  _ -> False

-- | @_parse_terminal(encoded, operation_id=..., episode_id=..., turn_id=...)@:
-- the one closed, canonical terminal wire value. 'Left' carries the
-- reference's @ValueError@ message.
parseTerminal :: ByteString -> Maybe Text -> Maybe EpisodeId -> Maybe TurnId -> Either Text Json
parseTerminal encoded operationId episodeId turnId = do
  unless ("\n" `B.isSuffixOf` encoded && B.count 10 encoded == 1 && B.length encoded <= maxResponse) $
    Left "terminal frame shape"
  value <- maybe (Left "terminal JSON") Right (pyJsonLoadsBytes (B.init encoded))
  canonical <- either (const (Left "terminal canonical form")) (Right . (<> "\n")) (jsonBytes value)
  case value of
    Object _ | canonical == encoded -> pure ()
    _ -> Left "terminal canonical form"
  if member "ok" value == Just (Bool False)
    then case member "error" value of
      Just (String code)
        | keysOf value == Set.fromList ["ok", "error"]
        , code `elem` terminalErrors ->
            pure value
      _ -> Left "terminal error"
    else do
      result <- case member "result" value of
        Just r@(Object _)
          | member "ok" value == Just (Bool True)
          , keysOf value == Set.fromList ["ok", "result"] ->
              Right r
        _ -> Left "terminal envelope"
      cleanup <- case member "cleanup" result of
        Just c@(Object _)
          | keysOf result == Set.fromList terminalResultFields
          , keysOf c == Set.fromList ["disposition", "code"] ->
              Right c
        _ -> Left "terminal result shape"
      unless (member "version" result == Just (Int 1)) $ Left "terminal version"
      unless (all (boundedString False . (`member` result)) ["operation_id", "episode_id", "turn_id", "termination_code"]) $
        Left "terminal identity"
      unless (all (boundedString True . (`member` result)) ["output_reference", "continuation_reference"]) $
        Left "terminal references"
      appends <- case member "accepted_appends" result of
        Just (Int n) | n == 0 || n == 1 -> Right n
        _ -> Left "terminal appends"
      let domain = either (const (Left "terminal domain")) Right
          text name = case member name result of
            Just (String s) -> Right s
            _ -> Left (valueError name)
          optionalText name = case member name result of
            Just (String s) -> Right (Just s)
            _ -> Right Nothing
      settlement <- domain $ do
        episode <- lifecycleIdFromData (maybeNull (member "episode_id" result))
        turn <- lifecycleIdFromData (maybeNull (member "turn_id" result))
        outcome <- enumFrom' "outcome" (member "outcome" result)
        code <- text "termination_code"
        output <- optionalText "output_reference"
        continuation <- optionalText "continuation_reference"
        mkRuntimeTurnSettlement episode turn outcome appends code output continuation
      _ <- domain $ do
        operation <- text "operation_id"
        disposition <- dispositionFrom (member "disposition" cleanup)
        code <- case member "code" cleanup of
          Just (String s) -> Right s
          _ -> Left (typeError "cleanup code")
        mkRuntimeOperationCleanup operation disposition code False
      unless (boundedString False (member "code" cleanup)) $ Left "terminal cleanup"
      forM_ operationId $ \expected ->
        when (member "operation_id" result /= Just (String expected)) $ Left "terminal operation correlation"
      forM_ episodeId $ \expected ->
        when (settlement.episodeId /= expected) $ Left "terminal episode correlation"
      forM_ turnId $ \expected ->
        when (settlement.turnId /= expected) $ Left "terminal turn correlation"
      pure value
  where
    maybeNull = maybe Null id
    enumFrom' :: Text -> Maybe Json -> Either AgenticusError TurnOutcome
    enumFrom' name = \case
      Just (String s) | Just found <- lookup s [(enumText o, o) | o <- [minBound .. maxBound]] -> Right found
      _ -> Left (valueError ("invalid " <> name))
    dispositionFrom :: Maybe Json -> Either AgenticusError RuntimeCleanupDisposition
    dispositionFrom = \case
      Just (String s) | Just found <- lookup s [(cleanupDispositionText d, d) | d <- [minBound .. maxBound]] -> Right found
      _ -> Left (valueError "invalid cleanup disposition")

-- ---------------------------------------------------------------------------
-- Shared admission

isSync :: SomeException -> Bool
isSync e = isNothing (fromException e :: Maybe SomeAsyncException)

trySync :: IO a -> IO (Either SomeException a)
trySync action =
  try action >>= \case
    Left e | not (isSync e) -> throwIO e
    other -> pure other

protocol :: Text -> IO a
protocol = throwIO . runtimeProtocolError

-- | @_runtime_invocation@: the versioned input for one exact host-owned
-- Attachment and connection. @strict@ adds the service's explicit string
-- checks (the Activity adapter leaves them to the invocation's own
-- validation).
runtimeInvocation :: Bool -> ConnectionView -> EpisodeAttachment -> Text -> Json -> IO CodexRuntimeInvocation
runtimeInvocation strict connection attachment operationId value = do
  let invalid = throwIO (valueError "invalid Codex Gondolin input")
      field name = maybe Null id (member name value)
  case value of
    Object _ | keysOf value == Set.fromList inputFields -> pure ()
    _ -> invalid
  unless (field "version" == Int 1 && isInt (field "version")) invalid
  when (strict && not (isString (field "prompt"))) invalid
  when strict $ forM_ ["attachment_id", "connection_id"] $ \name -> unless (isString (field name)) invalid
  forM_ ["attachment_epoch", "authority_epoch", "state_version"] $ \name -> case field name of
    Int n | n > 0 -> pure ()
    _ -> invalid
  episode <- throwLeft (lifecycleIdFromData (field "episode_id"))
  turn <- throwLeft (lifecycleIdFromData (field "turn_id"))
  continuation <- case field "continuation" of
    Null -> pure Nothing
    raw -> Just <$> throwLeft (continuationFromData raw)
  coordinates <- Episode.coordinates attachment
  when
    ( episode /= Episode.episodeId attachment
        || field "attachment_id" /= String coordinates.attachmentId
        || field "attachment_epoch" /= Int coordinates.attachmentEpoch
        || field "connection_id" /= String connection.identity.connectionId
        || field "authority_epoch" /= Int connection.authorityEpoch
        || field "state_version" /= Int connection.stateVersion
    )
    invalid
  prompt <- case field "prompt" of
    String p -> pure p
    _ -> invalid
  newCodexRuntimeInvocation
    CodexRuntimeInvocation
      { operationId
      , episodeId = episode
      , turnId = turn
      , prompt
      , connection
      , attachment
      , continuation
      }
  where
    isInt = \case
      Int _ -> True
      _ -> False
    isString = \case
      String _ -> True
      _ -> False

-- | The terminal result object for one settled operation.
resultData :: Text -> RuntimeTurnSettlement -> RuntimeOperationCleanup -> Json
resultData operationId result cleanup =
  Object
    [ ("version", Int 1)
    , ("operation_id", String operationId)
    , ("episode_id", lifecycleIdToData result.episodeId)
    , ("turn_id", lifecycleIdToData result.turnId)
    , ("outcome", String (enumText result.outcome))
    , ("accepted_appends", Int result.acceptedAppends)
    , ("termination_code", String result.terminationCode)
    , ("output_reference", maybe Null String result.outputReference)
    , ("continuation_reference", maybe Null String result.continuationReference)
    , ("cleanup", Object [("disposition", String (cleanupDispositionText cleanup.disposition)), ("code", String cleanup.code)])
    ]

-- ---------------------------------------------------------------------------
-- The host-local Activity adapter

-- | @_CodexGondolinActivityAdapter@: host-local Motus Activity custody for
-- one exact Episode-bound Codex lane. The connection, Attachment, provider
-- and qualified runtime remain host-owned collaborators.
data CodexGondolinActivityAdapter = CodexGondolinActivityAdapter
  { adapter :: CodexRuntimeAdapter
  , connection :: ConnectionView
  , attachment :: EpisodeAttachment
  }

newCodexGondolinActivityAdapter :: CodexRuntimeAdapter -> ConnectionView -> EpisodeAttachment -> IO CodexGondolinActivityAdapter
newCodexGondolinActivityAdapter adapter connection attachment = do
  when (codexAdapterLane adapter /= CodexGondolin) $
    throwIO (typeError "Codex Gondolin Activity requires its exact runtime adapter")
  when (connection.status /= StatusReady) $
    throwIO (valueError "Codex Gondolin Activity requires one ready connection view")
  pure CodexGondolinActivityAdapter {adapter, connection, attachment}

-- | @adapter(invocation, context=context)@.
runCodexGondolinActivityAdapter :: CodexGondolinActivityAdapter -> ActivityInvocation -> ActivityExecutionContext -> IO Json
runCodexGondolinActivityAdapter a invocation context = do
  when (invocation.activity /= codexGondolinActivity) $ protocol "activity-mismatch"
  operationId <- maybe (protocol "idempotency-required") pure invocation.idempotency
  runtime <-
    trySync (runtimeInvocation False a.connection a.attachment operationId invocation.input)
      >>= either (const (protocol "input-invalid")) pure
  trySync (context.heartbeat (Just (Object [("phase", String "runtime")])))
    >>= either (const (protocol "activity-stale")) (const (pure ()))
  operation <-
    trySync (startCodex a.adapter runtime) >>= \case
      Right operation -> pure operation
      Left e
        | Just failure <- fromException e
        , isJust (runtimeProtocolErrorCode failure) ->
            throwIO failure
        | otherwise -> protocol "runtime-admission-failed"
  result <- waitCodexOperation operation Nothing
  cleanup <- closeCodexOperation operation
  pure (resultData (codexOperationId operation) result cleanup)

-- ---------------------------------------------------------------------------
-- The runtime service

foreign import ccall unsafe "sys/file.h flock" c_flock :: CInt -> CInt -> IO CInt

lockEx, lockNb, lockUn :: CInt
lockEx = 2
lockNb = 4
lockUn = 8

-- | @_CodexGondolinRuntimeService@: borrow one pre-provisioned Attachment
-- behind one process-safe service fence.
data CodexGondolinRuntimeService = CodexGondolinRuntimeService
  { endpoint :: FilePath
  , ledger :: FilePath
  , token :: Text
  , adapter :: CodexRuntimeAdapter
  , connection :: ConnectionView
  , attachment :: EpisodeAttachment
  , stop :: TVar Bool
  , executionLock :: MVar ()
  , server :: IORef (Maybe Socket.Socket)
  , serving :: IORef (Maybe (TVar Bool))
  , lockFile :: IORef (Maybe Fd)
  , pid :: ProcessID
  }

serviceError :: Text -> IO a
serviceError = throwAgenticus RuntimeError

-- | @_CodexGondolinRuntimeService(endpoint, ledger, token, adapter,
-- connection, attachment)@: validate, take the state directory's fence, and
-- open (or create) the replay ledger, turning every interrupted operation
-- into @operation-indeterminate@.
newCodexGondolinRuntimeService
  :: FilePath -> FilePath -> Text -> CodexRuntimeAdapter -> ConnectionView -> EpisodeAttachment -> IO CodexGondolinRuntimeService
newCodexGondolinRuntimeService endpoint ledger token adapter connection attachment = do
  when (codexAdapterLane adapter /= CodexGondolin) $
    throwIO (typeError "service requires the exact Codex Gondolin runtime adapter")
  when (connection.status /= StatusReady) $ throwIO (valueError "service requires one ready connection")
  unless (T.length token >= 32 && T.length token <= 256 && T.all printableAscii token) $
    throwIO (valueError "service token must contain 32..256 printable ASCII characters")
  when (pathParent endpoint /= pathParent ledger) $
    throwIO (valueError "service endpoint and ledger require one state directory")
  stop <- newTVarIO False
  executionLock <- newMVar ()
  server <- newIORef Nothing
  serving <- newIORef Nothing
  lockFile <- newIORef Nothing
  pid <- getProcessID
  let service = CodexGondolinRuntimeService {endpoint, ledger, token, adapter, connection, attachment, stop, executionLock, server, serving, lockFile, pid}
  acquireFence service
  initializeLedger service `onException` releaseFence service
  pure service

printableAscii :: Char -> Bool
printableAscii c = c >= ' ' && c <= '~'

-- | @Path(value).parent@, lexically.
pathParent :: FilePath -> FilePath
pathParent path = case takeDirectory (stripTrailing path) of
  "" -> "."
  parent -> parent
  where
    stripTrailing p = case reverse p of
      '/' : rest@(_ : _) -> stripTrailing (reverse rest)
      _ -> p

acquireFence :: CodexGondolinRuntimeService -> IO ()
acquireFence s = do
  let state = takeDirectory s.endpoint
      invalid = serviceError "runtime-service-state-invalid"
  symlink <- either (\(_ :: IOException) -> False) id <$> try (pathIsSymbolicLink state)
  when symlink invalid
  makeStateDirectory state
  status <- Files.getSymbolicLinkStatus state
  euid <- getEffectiveUserID
  unless (Files.isDirectory status && mode status == 0o700 && Files.fileOwner status == euid) invalid
  descriptor <-
    PosixIO.openFd
      (state <> "/.service.lock")
      PosixIO.ReadWrite
      PosixIO.defaultFileFlags {PosixIO.creat = Just 0o600, PosixIO.nofollow = True, PosixIO.cloexec = True}
  lockStatus <- Files.getFdStatus descriptor
  unless (Files.isRegularFile lockStatus && mode lockStatus == 0o600 && Files.fileOwner lockStatus == euid) $ do
    PosixIO.closeFd descriptor
    invalid
  let Fd raw = descriptor
  locked <- c_flock raw (lockEx .|. lockNb)
  when (locked /= 0) $ do
    PosixIO.closeFd descriptor
    serviceError "runtime-service-owned"
  writeIORef s.lockFile (Just descriptor)
  where
    mode status = Files.fileMode status `mod` 0o10000
    -- @state.mkdir(parents=True, mode=0o700, exist_ok=True)@.
    makeStateDirectory state = do
      createDirectoryIfMissing True (pathParent state)
      created <- try (PosixDirectory.createDirectory state 0o700)
      case created of
        Right () -> pure ()
        Left (e :: IOException) -> do
          exists <- either (\(_ :: IOException) -> False) Files.isDirectory <$> try (Files.getFileStatus state)
          unless exists (throwIO e)

releaseFence :: CodexGondolinRuntimeService -> IO ()
releaseFence s =
  readIORef s.lockFile >>= \case
    Nothing -> pure ()
    Just descriptor -> do
      current <- getProcessID
      let Fd raw = descriptor
      when (current == s.pid) $ void (c_flock raw lockUn)
      PosixIO.closeFd descriptor
      writeIORef s.lockFile Nothing

ensureOwner :: CodexGondolinRuntimeService -> IO ()
ensureOwner s = do
  current <- getProcessID
  held <- readIORef s.lockFile
  when (current /= s.pid || isNothing held) $ serviceError "runtime-service-owner-invalid"

-- | @_connect_db()@: one WAL, synchronous-FULL connection with a two-second
-- busy timeout.
withLedger :: CodexGondolinRuntimeService -> (Sql.Database -> IO a) -> IO a
withLedger s action =
  bracket (Sql.openDatabase s.ledger) Sql.closeDatabase $ \db -> do
    Sql.setBusyTimeout db 2000
    mode <- scalar db "PRAGMA journal_mode=WAL" []
    unless (mode == Just (Sql.SQLText "wal")) $ serviceError "runtime-service-storage-failed"
    Sql.execute_ db "PRAGMA synchronous=FULL"
    action db

scalar :: Sql.Database -> Text -> [Sql.SqlValue] -> IO (Maybe Sql.SqlValue)
scalar db sql parameters =
  bracket (Sql.prepareStatement db sql) Sql.finalizeStatement $ \statement ->
    Sql.queryRow statement parameters >>= \case
      Just (value : _) -> pure (Just value)
      _ -> pure Nothing

rows :: Sql.Database -> Text -> [Sql.SqlValue] -> IO [[Sql.SqlValue]]
rows db sql parameters = bracket (Sql.prepareStatement db sql) Sql.finalizeStatement (`Sql.queryRows` parameters)

run :: Sql.Database -> Text -> [Sql.SqlValue] -> IO ()
run db sql parameters = bracket (Sql.prepareStatement db sql) Sql.finalizeStatement (`Sql.runStatement` parameters)

initializeLedger :: CodexGondolinRuntimeService -> IO ()
initializeLedger s = do
  outcome <- trySync $ do
    euid <- getEffectiveUserID
    existing <- try (Files.getSymbolicLinkStatus s.ledger)
    created <- case existing of
      Right status -> do
        unless (Files.isRegularFile status && Files.fileMode status `mod` 0o10000 == 0o600 && Files.fileOwner status == euid) $
          serviceError "ledger"
        pure False
      Left e
        | isDoesNotExistError e -> do
            descriptor <-
              PosixIO.openFd
                s.ledger
                PosixIO.WriteOnly
                PosixIO.defaultFileFlags {PosixIO.creat = Just 0o600, PosixIO.exclusive = True, PosixIO.nofollow = True, PosixIO.cloexec = True}
            PosixIO.closeFd descriptor
            pure True
        | otherwise -> throwIO e
    withLedger s $ \db -> do
      quick <- scalar db "PRAGMA quick_check" []
      unless (quick == Just (Sql.SQLText "ok")) $ serviceError "ledger"
      when created $ do
        Sql.execute_ db serviceDdl
        Sql.execute_ db ("PRAGMA user_version=" <> T.pack (show schemaVersion))
      validateLedger db
      indeterminate <- either (const (serviceError "ledger")) pure (jsonBytes (terminalError "operation-indeterminate"))
      run db "UPDATE operations SET phase='terminal', terminal=? WHERE phase='executing'" [Sql.SQLBlob indeterminate]
  case outcome of
    Right () -> pure ()
    Left _ -> serviceError "runtime-service-storage-failed"

-- | @_validate_ledger(db)@.
validateLedger :: Sql.Database -> IO ()
validateLedger db = do
  let invalid = serviceError "ledger"
  columns <- rows db "PRAGMA table_info(operations)" []
  let shaped = [(name, kind, notnull, pk) | [_, name, kind, notnull, _, pk] <- columns]
      expected =
        [ (text "operation_id", text "TEXT", Sql.SQLInteger 1, Sql.SQLInteger 1)
        , (text "request_fingerprint", text "TEXT", Sql.SQLInteger 1, Sql.SQLInteger 0)
        , (text "phase", text "TEXT", Sql.SQLInteger 1, Sql.SQLInteger 0)
        , (text "terminal", text "BLOB", Sql.SQLInteger 0, Sql.SQLInteger 0)
        , (text "episode_id", text "TEXT", Sql.SQLInteger 1, Sql.SQLInteger 0)
        , (text "turn_id", text "TEXT", Sql.SQLInteger 1, Sql.SQLInteger 0)
        ]
      text = Sql.SQLText
  stored <- scalar db "SELECT sql FROM sqlite_master WHERE type='table' AND name='operations'" []
  version <- scalar db "PRAGMA user_version" []
  unless
    ( version == Just (Sql.SQLInteger (fromInteger schemaVersion))
        && length shaped == length columns
        && shaped == expected
        && fmap normalizeStored stored == Just (Just (normalize serviceDdl))
    )
    invalid
  operations <- rows db "SELECT operation_id,request_fingerprint,phase,terminal,episode_id,turn_id FROM operations" []
  forM_ operations $ \case
    [Sql.SQLText operation, Sql.SQLText fingerprint, Sql.SQLText phase, terminal, Sql.SQLText episode, Sql.SQLText turn]
      | not (any T.null [operation, fingerprint, phase, episode, turn])
      , T.length fingerprint == 64
      , T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) fingerprint -> do
          parsedEpisode <- throwLeft (lifecycleIdFromData (String episode))
          parsedTurn <- throwLeft (lifecycleIdFromData (String turn))
          case (phase, terminal) of
            ("terminal", Sql.SQLBlob body) ->
              either (const invalid) (const (pure ())) $
                parseTerminal (body <> "\n") (Just operation) (Just parsedEpisode) (Just parsedTurn)
            ("executing", Sql.SQLNull) -> pure ()
            _ -> invalid
    _ -> invalid
  where
    normalizeStored = \case
      Sql.SQLText sql -> Just (normalize sql)
      _ -> Nothing
    -- @re.sub(r"\s+", " ", value.strip()).lower()@.
    normalize = T.toLower . T.unwords . T.words . T.strip

-- | @start()@: bind the owner-only endpoint and serve one request at a
-- time.
startCodexGondolinRuntimeService :: CodexGondolinRuntimeService -> IO ()
startCodexGondolinRuntimeService s = do
  ensureOwner s
  started <- isJust <$> readIORef s.serving
  when started $ serviceError "service already started"
  existing <- try (Files.getSymbolicLinkStatus s.endpoint)
  case existing of
    Left (e :: IOException)
      | isDoesNotExistError e -> pure ()
      | otherwise -> throwIO e
    Right status -> do
      unless (Files.isSocket status) $ serviceError "runtime-service-endpoint-invalid"
      Files.removeLink s.endpoint
  socket <- Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol
  ( do
      Socket.bind socket (Socket.SockAddrUnix s.endpoint)
      Files.setFileMode s.endpoint 0o600
      Socket.listen socket 8
    )
    `onException` Socket.close socket
  writeIORef s.server (Just socket)
  done <- newTVarIO False
  writeIORef s.serving (Just done)
  void (forkIO (serve s socket `finally` atomically (writeTVar done True)))

-- | @close()@: stop serving, wait for the in-flight request, remove the
-- endpoint, and release the fence.
closeCodexGondolinRuntimeService :: CodexGondolinRuntimeService -> IO ()
closeCodexGondolinRuntimeService s = do
  ensureOwner s
  atomically (writeTVar s.stop True)
  readIORef s.server >>= mapM_ (\socket -> void (try @IOException (Socket.close socket)))
  writeIORef s.server Nothing
  readIORef s.serving >>= \case
    Nothing -> pure ()
    Just done -> do
      finished <- timeout (round (closeTimeout * 1000000)) (atomically (readTVar done >>= check))
      when (isNothing finished) $ serviceError "runtime-service-quiescence-failed"
  existing <- try (Files.getSymbolicLinkStatus s.endpoint)
  case existing of
    Right status | Files.isSocket status -> Files.removeLink s.endpoint
    Right _ -> pure ()
    Left (e :: IOException)
      | isDoesNotExistError e -> pure ()
      | otherwise -> throwIO e
  releaseFence s

serve :: CodexGondolinRuntimeService -> Socket.Socket -> IO ()
serve s socket = loop
  where
    loop = do
      stopped <- readTVarIO s.stop
      unless stopped $ do
        accepted <- try (timeout 100000 (Socket.accept socket))
        case accepted of
          Right (Just (client, _)) -> handle s client
          Right Nothing -> pure ()
          Left (_ :: IOException) -> void (timeout 100000 (atomically (readTVar s.stop >>= check)))
        loop

-- | @_handle(client)@: one bounded frame in, one canonical terminal out.
handle :: CodexGondolinRuntimeService -> Socket.Socket -> IO ()
handle s client = flip finally (void (try @IOException (Socket.close client))) $ do
  received <- trySync (readFrame B.empty)
  response <- case received of
    Right Nothing -> pure (terminalError "request-invalid")
    Right (Just frame)
      | B.length frame > maxRequest -> pure (terminalError "frame-too-large")
      | not ("\n" `B.isSuffixOf` frame) || B.count 10 frame /= 1 -> pure (terminalError "request-invalid")
      | otherwise ->
          trySync (request s (B.init frame)) >>= \case
            Right value -> pure value
            Left e
              | Just (_ :: IOException) <- fromException e -> pure (terminalError "request-invalid")
              | otherwise -> pure (terminalError "runtime-failed")
    Left e
      | Just (_ :: IOException) <- fromException e -> pure (terminalError "request-invalid")
      | otherwise -> pure (terminalError "runtime-failed")
  let encoded = encodedTerminal response <> "\n"
      checked = either (const (encodedTerminal (terminalError "runtime-failed") <> "\n")) (const encoded) (parseTerminal encoded Nothing Nothing Nothing)
  void (try @IOException (SocketBytes.sendAll client checked))
  where
    -- 'Nothing' is a receive timeout (@TimeoutError@).
    readFrame frame
      | "\n" `B.isInfixOf` frame || B.length frame > maxRequest = pure (Just frame)
      | otherwise =
          timeout (round (frameTimeout * 1000000)) (SocketBytes.recv client (min 4096 (maxRequest + 1 - B.length frame))) >>= \case
            Nothing -> pure Nothing
            Just chunk
              | B.null chunk -> pure (Just frame)
              | otherwise -> readFrame (frame <> chunk)

-- | @hmac.compare_digest@ over two ASCII strings.
constantTimeEqual :: Text -> Text -> Bool
constantTimeEqual a b =
  B.length x == B.length y && foldl' (\acc (p, q) -> acc .|. xor p q) 0 (B.zip x y) == 0
  where
    x = TE.encodeUtf8 a
    y = TE.encodeUtf8 b

-- | @_request(frame)@: one bounded admission door, then lookup-first replay.
request :: CodexGondolinRuntimeService -> ByteString -> IO Json
request s frame = do
  let canonical = do
        value <- pyJsonLoadsBytes frame
        encoded <- either (const Nothing) Just (jsonBytes value)
        pure (value, encoded)
  case canonical of
    Nothing -> pure (terminalError "request-invalid")
    Just (value, encoded)
      | encoded /= frame || not (isObject value) || keysOf value /= Set.fromList ["version", "token", "operation_id", "input"] ->
          pure (terminalError "request-invalid")
      | otherwise -> case member "token" value of
          Just (String supplied)
            | T.all isAscii supplied && T.length supplied <= 256 && constantTimeEqual supplied s.token ->
                admitted value
          _ -> pure (terminalError "unauthorized")
  where
    isObject = \case
      Object _ -> True
      _ -> False
    admitted value = case (member "version" value, member "operation_id" value) of
      (Just (Int 1), Just (String operationId))
        | not (T.null operationId) && T.length operationId <= 256 -> do
            let input = maybe Null id (member "input" value)
            case jsonBytes (Object [("version", Int 1), ("operation_id", String operationId), ("input", input)]) of
              Left _ -> pure (terminalError "request-invalid")
              Right body -> do
                let fingerprint = sha256Hex body
                trySync (runtimeInvocation True s.connection s.attachment operationId input) >>= \case
                  Left _ -> pure (terminalError "request-invalid")
                  Right invocation -> withMVar s.executionLock (const (replayOrExecute operationId fingerprint invocation))
      _ -> pure (terminalError "request-invalid")
    replayOrExecute operationId fingerprint invocation = do
      looked <- trySync . withLedger s $ \db -> do
        row <-
          bracket (Sql.prepareStatement db "SELECT request_fingerprint,phase,terminal FROM operations WHERE operation_id=?") Sql.finalizeStatement $
            (`Sql.queryRow` [Sql.SQLText operationId])
        case row of
          Just [stored, phase, terminal]
            | stored /= Sql.SQLText fingerprint -> pure (Left (terminalError "operation-conflict"))
            | phase /= Sql.SQLText "terminal" -> pure (Left (terminalError "operation-indeterminate"))
            | Sql.SQLBlob body <- terminal ->
                either (const (serviceError "ledger")) (pure . Left) $
                  parseTerminal (body <> "\n") (Just operationId) (Just invocation.episodeId) (Just invocation.turnId)
            | otherwise -> serviceError "ledger"
          Just _ -> serviceError "ledger"
          Nothing -> do
            run
              db
              "INSERT INTO operations VALUES(?,?,'executing',NULL,?,?)"
              [ Sql.SQLText operationId
              , Sql.SQLText fingerprint
              , Sql.SQLText (lifecycleIdText invocation.episodeId)
              , Sql.SQLText (lifecycleIdText invocation.turnId)
              ]
            pure (Right ())
      case looked of
        Left _ -> pure (terminalError "runtime-failed")
        Right (Left replayed) -> pure replayed
        Right (Right ()) -> do
          terminal <- execute s invocation
          stored <- trySync $ do
            encoded <- either (const (serviceError "ledger")) pure (jsonBytes terminal)
            either (const (serviceError "ledger")) (const (pure ())) $
              parseTerminal (encoded <> "\n") (Just operationId) (Just invocation.episodeId) (Just invocation.turnId)
            withLedger s $ \db -> do
              run db "UPDATE operations SET phase='terminal',terminal=? WHERE operation_id=? AND phase='executing'" [Sql.SQLBlob encoded, Sql.SQLText operationId]
              changed <- Sql.changedRows db
              when (changed /= 1) $ serviceError "ledger"
          pure (either (const (terminalError "runtime-failed")) (const terminal) stored)

-- | @_execute(invocation)@: start, wait, and close one runtime operation;
-- any failure is the redacted @runtime-failed@ terminal.
execute :: CodexGondolinRuntimeService -> CodexRuntimeInvocation -> IO Json
execute s invocation = do
  started <- newIORef Nothing
  closed <- newIORef False
  outcome <- trySync $ do
    operation <- startCodex s.adapter invocation
    writeIORef started (Just operation)
    result <- waitCodexOperation operation Nothing
    cleanup <- closeCodexOperation operation
    writeIORef closed True
    let terminal = Object [("ok", Bool True), ("result", resultData (codexOperationId operation) result cleanup)]
    encoded <- either (const (serviceError "terminal")) pure (jsonBytes terminal)
    either (const (serviceError "terminal")) pure $
      parseTerminal (encoded <> "\n") (Just invocation.operationId) (Just invocation.episodeId) (Just invocation.turnId)
  wasClosed <- readIORef closed
  unless wasClosed $ readIORef started >>= mapM_ (void . trySync . closeCodexOperation)
  pure (either (const (terminalError "runtime-failed")) id outcome)

-- ---------------------------------------------------------------------------
-- The Worker-side Activity client

-- | @_CodexGondolinActivityClient()(invocation, context=context)@, reading
-- the endpoint and token from the process environment.
codexGondolinActivityClient :: ActivityInvocation -> ActivityExecutionContext -> IO Json
codexGondolinActivityClient = codexGondolinActivityClientWith (fmap (fmap T.pack) . lookupEnv)

-- | The client over an explicit environment lookup.
codexGondolinActivityClientWith :: (String -> IO (Maybe Text)) -> ActivityInvocation -> ActivityExecutionContext -> IO Json
codexGondolinActivityClientWith environment invocation context = do
  when (invocation.activity /= serviceActivity) $ protocol "activity-mismatch"
  operationId <- maybe (protocol "idempotency-required") pure invocation.idempotency
  endpoint <- environment endpointVariable
  token <- environment tokenVariable
  (path, secret) <- case (endpoint, token) of
    (Just e, Just t)
      | not (T.null e) && T.length t >= 32 && T.length t <= 256 && T.all printableAscii t -> pure (T.unpack e, t)
    _ -> protocol "runtime-service-unavailable"
  let heartbeat = trySync (context.heartbeat (Just (Object [("phase", String "runtime")]))) >>= either (const (protocol "activity-stale")) (const (pure ()))
  heartbeat
  (expectedEpisode, expectedTurn, encoded) <-
    either (const (protocol "input-invalid")) pure $ do
      expectedEpisode <- case member "episode_id" invocation.input of
        Just raw -> either (Left . (.errorMessage)) Right (lifecycleIdFromData raw)
        Nothing -> Left "input"
      expectedTurn <- case member "turn_id" invocation.input of
        Just raw -> either (Left . (.errorMessage)) Right (lifecycleIdFromData raw)
        Nothing -> Left "input"
      body <-
        jsonBytes
          ( Object
              [ ("version", Int 1)
              , ("token", String secret)
              , ("operation_id", String operationId)
              , ("input", invocation.input)
              ]
          )
      pure (expectedEpisode :: EpisodeId, expectedTurn :: TurnId, body <> "\n")
  when (B.length encoded > maxRequest) $ protocol "request-too-large"
  let interval = min 0.25 (fromInteger (policyFields invocation.policy).heartbeatTimeout / 3) :: Double
      micros = max 1 (round (interval * 1000000))
  exchanged <- trySync $
    bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \client -> do
      connected <- timeout micros (Socket.connect client (Socket.SockAddrUnix path))
      when (isNothing connected) $ throwIO (userError "connect timed out")
      sent <- timeout (max micros 1000000) (SocketBytes.sendAll client encoded)
      when (isNothing sent) $ throwIO (userError "send timed out")
      let receive response
            | "\n" `B.isInfixOf` response || B.length response > maxResponse = pure response
            | otherwise =
                timeout micros (SocketBytes.recv client (min 4096 (maxResponse + 1 - B.length response))) >>= \case
                  Nothing -> heartbeat >> receive response
                  Just chunk
                    | B.null chunk -> pure response
                    | otherwise -> receive (response <> chunk)
      receive B.empty
  response <- case exchanged of
    Right value -> pure value
    Left e
      | Just failure <- fromException e
      , isJust (runtimeProtocolErrorCode failure) ->
          throwIO failure
      | otherwise -> protocol "runtime-service-unavailable"
  value <-
    either (const (protocol "runtime-service-failed")) pure $
      parseTerminal response (Just operationId) (Just expectedEpisode) (Just expectedTurn)
  case (member "ok" value, member "error" value, member "result" value) of
    (Just (Bool True), _, Just result) -> pure result
    (_, Just (String code), _) -> protocol code
    _ -> protocol "runtime-service-failed"

