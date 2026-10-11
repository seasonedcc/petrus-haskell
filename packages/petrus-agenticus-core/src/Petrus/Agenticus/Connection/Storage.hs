{-# LANGUAGE RecordWildCards #-}

-- | Pluggable CAS storage and the private SQLite Agent Connection store
-- (@petrus.agenticus.connection.storage@).
--
-- The whole custody state is one immutable 'StorageSnapshot' published by
-- compare-and-swap on a revision.  'SqliteConnectionStorage' keeps it as a
-- single JSON payload row; the DDL text, the payload spelling
-- (@json.dumps(..., sort_keys=True, separators=(",", ":"), allow_nan=False)@
-- with its default @ensure_ascii=True@), and every validation message are
-- byte-identical to the reference, so either implementation can open the
-- other's store.
module Petrus.Agenticus.Connection.Storage
  ( -- * Stored values
    AuditValue (..)
  , AuditDetails
  , StoredHost (..)
  , StoredConnection (..)
  , StoredLease (..)
  , AuditRecord (..)
  , auditDetail
  , StorageSnapshot (..)
  , emptySnapshot
    -- * The storage boundary
  , ConnectionStorage (..)
    -- * SQLite storage
  , openSqliteConnectionStorage
  , openSqliteConnectionStorageWith
  , connectionCustodyDdl
    -- * Validation and the payload format
  , validateSnapshot
  , validateSnapshotIO
  , encodeSnapshot
  , decodeSnapshot
  , snapshotToJson
  , auditValueJson
  , storageError
  , storageSecurityError
  ) where

import Prelude hiding (sequence)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (SomeException, catch, evaluate, mask, onException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteArray.Encoding (Base (Base64), convertToBase)
import Data.Char (ord)
import System.IO.Unsafe (unsafePerformIO)
import System.Mem.StableName (StableName, makeStableName)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Sqlite
import Petrus.Agenticus.Internal.Validate (pyIsSpace, sha256Hex)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Directory (createDirectoryIfMissing, doesPathExist)
import System.FilePath (takeDirectory)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files
  ( fileMode
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , setFdMode
  , setFileMode
  )
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, openFd)

-- | A safe scalar audit value (@str | int | float | bool | None@).
data AuditValue
  = AuditNone
  | AuditStr Text
  | AuditInt Integer
  | AuditFloat Double
  | AuditBool Bool
  deriving stock (Eq, Show)

-- | Operation details, sorted by name.
type AuditDetails = [(Text, AuditValue)]

data StoredHost = StoredHost
  { hostId :: Text
  , enrollmentEpoch :: Integer
  , active :: Bool
  }
  deriving stock (Eq, Ord, Show)

data StoredConnection = StoredConnection
  { connectionId :: Text
  , provider :: Text
  , accountFingerprint :: Text
  , profile :: Text
  , status :: Text
  , authorityEpoch :: Integer
  , stateVersion :: Integer
  , encryptedState :: Maybe ByteString
  , stateDigest :: Maybe Text
  }
  deriving stock (Eq, Ord, Show)

data StoredLease = StoredLease
  { leaseId :: Text
  , attachmentId :: Text
  , connectionId :: Text
  , hostId :: Text
  , hostEpoch :: Integer
  , mode :: Text
  , authorityEpoch :: Integer
  , baseVersion :: Integer
  , expiresAt :: Double
  , activated :: Bool
  , released :: Bool
  , releaseReason :: Maybe Text
  }
  deriving stock (Eq, Ord, Show)

-- | One secret-free custody operation record outside canonical History.
data AuditRecord = AuditRecord
  { sequence :: Integer
  , operationId :: Text
  , eventKind :: Text
  , connectionId :: Maybe Text
  , hostId :: Maybe Text
  , leaseId :: Maybe Text
  , details :: AuditDetails
  }
  deriving stock (Eq, Show)

-- | @record.detail(name)@.
auditDetail :: Text -> AuditRecord -> Maybe AuditValue
auditDetail name record = lookup name (reverse record.details)

-- | One immutable complete custody state at a host-store CAS revision.
data StorageSnapshot = StorageSnapshot
  { revision :: Integer
  , hosts :: [StoredHost]
  , connections :: [StoredConnection]
  , leases :: [StoredLease]
  , audit :: [AuditRecord]
  }
  deriving stock (Eq, Show)

emptySnapshot :: StorageSnapshot
emptySnapshot = StorageSnapshot {revision = 0, hosts = [], connections = [], leases = [], audit = []}

-- | Host storage operations needed by the provider-neutral custody state
-- machine.
data ConnectionStorage = ConnectionStorage
  { load :: IO StorageSnapshot
  -- ^ Load one coherent immutable snapshot.
  , compareAndSwap :: Integer -> StorageSnapshot -> IO Bool
  -- ^ Publish the replacement only if the expected revision remains current.
  , close :: IO ()
  -- ^ Release host storage resources without changing custody state.
  }

storageError, storageSecurityError :: Text -> AgenticusError
storageError = AgenticusError StorageError
storageSecurityError = AgenticusError StorageSecurityError

-- ---------------------------------------------------------------------------
-- SQLite storage

-- | The table DDL exactly as the reference passes it to SQLite (which keeps
-- the text, minus @IF NOT EXISTS@, in @sqlite_master.sql@).
connectionCustodyDdl :: Text
connectionCustodyDdl =
  "\n\
  \            CREATE TABLE IF NOT EXISTS connection_custody (\n\
  \                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),\n\
  \                revision INTEGER NOT NULL,\n\
  \                payload TEXT NOT NULL\n\
  \            )\n\
  \            "

insertInitial, selectState, updateState :: Text
insertInitial = "INSERT OR IGNORE INTO connection_custody (singleton, revision, payload) VALUES (1, 0, ?)"
selectState = "SELECT revision, payload FROM connection_custody WHERE singleton = 1"
updateState =
  "\n\
  \                    UPDATE connection_custody SET revision = ?, payload = ?\n\
  \                    WHERE singleton = 1 AND revision = ?\n\
  \                    "

data Handle = Handle
  { database :: Database
  , decoded :: IORef (Maybe (Text, StorageSnapshot))
  -- ^ The last payload text this connection read or wrote, with its decoded
  -- snapshot.  Decoding is a pure function of the text, so a load that reads
  -- the identical text reuses the snapshot instead of parsing and validating
  -- it again; any other text is decoded as usual.
  }

-- | @SqliteConnectionStorage(path)@: SQLite CAS storage containing only
-- encrypted state and safe metadata, in a @0600@ file under a @0700@
-- non-symlink parent.
openSqliteConnectionStorage :: FilePath -> IO ConnectionStorage
openSqliteConnectionStorage = openSqliteConnectionStorageWith []

-- | 'openSqliteConnectionStorage', then the given statements (for example
-- @PRAGMA synchronous = OFF@) on the new connection.  For benchmarks that
-- separate CPU cost from fsync cost only; custody durability assumes the
-- reference's pragmas.
openSqliteConnectionStorageWith :: [Text] -> FilePath -> IO ConnectionStorage
openSqliteConnectionStorageWith tuning path = do
  preparePath path
  database <- openDatabase path
  handle <-
    ( do
        setFileMode path 0o600
        execute_ database "PRAGMA journal_mode = DELETE"
        execute_ database "PRAGMA synchronous = FULL"
        execute_ database "PRAGMA busy_timeout = 5000"
        mapM_ (execute_ database) tuning
        execute_ database connectionCustodyDdl
        runSql database insertInitial [SQLText (encodeSnapshotText emptySnapshot)]
        decoded <- newIORef Nothing
        pure Handle {database, decoded}
      )
      `onException` closeDatabase database
  lock <- newMVar (Just handle)
  pure
    ConnectionStorage
      { load = sqliteLoad lock
      , compareAndSwap = sqliteCompareAndSwap lock
      , close = sqliteClose lock
      }

sqliteLoad :: MVar (Maybe Handle) -> IO StorageSnapshot
sqliteLoad lock = do
  (row, decoded) <- withMVar lock $ \current -> do
    handle <- ensureOpen current
    row <- queryRow handle.database selectState []
    pure (row, handle.decoded)
  case row of
    Nothing -> throwIO (storageError "connection custody state is absent")
    Just [revisionValue, payloadValue] -> do
      let payload = payloadText payloadValue
      cached <- readIORef decoded
      snapshot <- case cached of
        Just (text, snapshot) | text == payload -> pure snapshot
        _ -> do
          snapshot <- either throwIO pure (decodeSnapshot payload)
          writeIORef decoded (Just (payload, snapshot))
          pure snapshot
      stored <- pythonInt revisionValue
      when (snapshot.revision /= stored) $
        throwIO (storageError "connection custody revision diverges from its payload")
      pure snapshot
    Just _ -> throwIO (storageError "connection custody state is absent")
  where
    -- @str(row[1])@: anything but TEXT spells something that is not a
    -- payload object, which decoding refuses.
    payloadText = \case
      SQLText text -> text
      _ -> ""

sqliteCompareAndSwap :: MVar (Maybe Handle) -> Integer -> StorageSnapshot -> IO Bool
sqliteCompareAndSwap lock expected replacement = do
  when (replacement.revision /= expected + 1) $
    throwIO (valueError "replacement revision must advance expected revision exactly once")
  -- Upstream validates here and again inside @_encode@; validation is pure,
  -- so once is equivalent.
  _ <- validateSnapshotIO replacement
  payload <- either throwIO pure (renderPayload replacement)
  withMVar lock $ \current -> do
    handle <- ensureOpen current
    execute_ handle.database "BEGIN IMMEDIATE"
    mask $ \restore -> do
      outcome <- try . restore $ do
        runSql handle.database updateState [SQLInteger (fromInteger replacement.revision), SQLText payload, SQLInteger (fromInteger expected)]
        updated <- changedRows handle.database
        if updated /= 1
          then rollback handle >> pure False
          else execute_ handle.database "COMMIT" >> pure True
      case outcome of
        Right published -> do
          -- The payload is the encoding of a valid snapshot, which decodes
          -- back to that snapshot.
          when published $ writeIORef handle.decoded (Just (payload, replacement))
          pure published
        Left (failure :: SomeException) -> do
          rollback handle `catch` \(_ :: SomeException) -> pure ()
          throwIO failure
  where
    rollback handle = do
      active <- inTransaction handle.database
      when active (execute_ handle.database "ROLLBACK")

-- | Closing twice is harmless, as with @sqlite3.Connection.close@.
sqliteClose :: MVar (Maybe Handle) -> IO ()
sqliteClose lock = modifyMVar_ lock $ \case
  Nothing -> pure Nothing
  Just handle -> do
    closeDatabase handle.database
    pure Nothing

-- | After 'close', every operation fails the way a closed @sqlite3@
-- connection does.
ensureOpen :: Maybe Handle -> IO Handle
ensureOpen = \case
  Just handle -> pure handle
  Nothing -> throwIO (AgenticusError (OtherError "ProgrammingError") "Cannot operate on a closed database.")

-- | @int(row[0])@.
pythonInt :: SQLData -> IO Integer
pythonInt = \case
  SQLInteger value -> pure (toInteger value)
  SQLFloat value -> pure (truncate value)
  SQLText text
    | Just value <- readInteger (T.strip text) -> pure value
    | otherwise -> throwIO (valueError ("invalid literal for int() with base 10: " <> T.pack (show text)))
  _ -> throwIO (typeError "int() argument must be a string, a bytes-like object or a real number, not 'NoneType'")
  where
    readInteger text = case reads (T.unpack text) of
      [(value, "")] -> Just value
      _ -> Nothing

preparePath :: FilePath -> IO ()
preparePath path = do
  prepareParent (takeDirectory path)
  linked <- isLink path
  when linked (throwIO (storageSecurityError "connection storage file must not be a symlink"))
  exists <- doesPathExist path
  unless exists (createPrivateFile path)
  assertPrivateFile path

prepareParent :: FilePath -> IO ()
prepareParent parent = do
  linked <- isLink parent
  when linked (throwIO (storageSecurityError "connection storage parent must not be a symlink"))
  exists <- doesPathExist parent
  unless exists $ do
    createDirectoryIfMissing True parent
    setFileMode parent 0o700
  metadata <- getSymbolicLinkStatus parent
  when (isSymbolicLink metadata) (throwIO (storageSecurityError "connection storage parent must not be a symlink"))
  unless (isDirectory metadata) (throwIO (storageSecurityError "connection storage parent must be a directory"))
  unless (fileMode metadata .&. 0o7777 == 0o700) $
    throwIO (storageSecurityError "connection storage parent must have mode 0700")

createPrivateFile :: FilePath -> IO ()
createPrivateFile path = do
  opened <- try (openFd path WriteOnly defaultFileFlags {exclusive = True, nofollow = True, creat = Just 0o600})
  case opened of
    Left failure
      | isAlreadyExistsError failure -> pure ()
      | otherwise -> throwIO failure
    Right descriptor -> setFdMode descriptor 0o600 `onException` closeFd descriptor >> closeFd descriptor

assertPrivateFile :: FilePath -> IO ()
assertPrivateFile path = do
  metadata <- getSymbolicLinkStatus path
  when (isSymbolicLink metadata) (throwIO (storageSecurityError "connection storage file must not be a symlink"))
  unless (isRegularFile metadata) (throwIO (storageSecurityError "connection storage path must be a regular file"))
  unless (fileMode metadata .&. 0o7777 == 0o600) $
    throwIO (storageSecurityError "connection storage file must have mode 0600")

isLink :: FilePath -> IO Bool
isLink path = do
  status <- try (getSymbolicLinkStatus path)
  case status of
    Left failure
      | isDoesNotExistError failure -> pure False
      | otherwise -> throwIO failure
    Right metadata -> pure (isSymbolicLink metadata)

-- ---------------------------------------------------------------------------
-- Validation

-- | Refuse host state that the custody writer could not have published.
validateSnapshot :: StorageSnapshot -> Either AgenticusError StorageSnapshot
validateSnapshot snapshot = do
  when (snapshot.revision < 0) $ Left (storageError "connection custody revision must be a nonnegative integer")
  when (snapshot.revision /= toInteger (length snapshot.audit)) $
    Left (storageError "connection custody revision must equal its operation count")
  validateHosts snapshot.hosts
  validateConnections snapshot.connections
  validateLeases snapshot
  validateAudit snapshot.audit
  pure snapshot

-- | 'validateSnapshot' in 'IO', throwing the refusal, and skipping the work
-- when given the very heap object it last accepted.  Validation is pure, so
-- the same object always gets the same verdict; this only spares the commit
-- loop from re-validating the snapshot the store just published (upstream
-- validates it in @compare_and_swap@ and again in the next @_load@).
validateSnapshotIO :: StorageSnapshot -> IO StorageSnapshot
validateSnapshotIO snapshot = do
  name <- makeStableName =<< evaluate snapshot
  known <- readIORef lastValidated
  if known == Just name
    then pure snapshot
    else do
      validated <- either throwIO pure (validateSnapshot snapshot)
      writeIORef lastValidated (Just name)
      pure validated

{-# NOINLINE lastValidated #-}
lastValidated :: IORef (Maybe (StableName StorageSnapshot))
lastValidated = unsafePerformIO (newIORef Nothing)

validateHosts :: [StoredHost] -> Either AgenticusError ()
validateHosts hosts = do
  unique [host.hostId | host <- hosts] "host identities"
  -- Identities are unique here, so upstream's whole-tuple ordering is the
  -- identity ordering (comparing values would also trip over a NaN expiry).
  when (outOfOrder (map (.hostId) hosts)) $ Left (storageError "connection custody hosts must be canonically ordered")
  forM_ hosts $ \host -> do
    storedText host.hostId "host identity"
    positiveInteger host.enrollmentEpoch "host enrollment epoch"

connectionStatuses :: [Text]
connectionStatuses = ["ready", "refreshing", "revoked", "erasure_pending", "reauthorization_required"]

validateConnections :: [StoredConnection] -> Either AgenticusError ()
validateConnections connections = do
  unique [connection.connectionId | connection <- connections] "connection identities"
  when (outOfOrder (map (.connectionId) connections)) $ Left (storageError "connections must be canonically ordered")
  forM_ connections $ \connection -> do
    storedText connection.connectionId "connection identity"
    storedText connection.provider "provider identity"
    storedText connection.accountFingerprint "account fingerprint"
    storedText connection.profile "connection profile"
    unless (connection.status `elem` connectionStatuses) $ Left (storageError "connection status is not supported")
    positiveInteger connection.authorityEpoch "connection authority epoch"
    positiveInteger connection.stateVersion "connection state version"
    validateCiphertext connection

validateCiphertext :: StoredConnection -> Either AgenticusError ()
validateCiphertext connection = do
  when (isNothing connection.encryptedState /= isNothing connection.stateDigest) $
    Left (storageError "encrypted connection state and digest must be present or absent together")
  case connection.encryptedState of
    Nothing ->
      unless (connection.status `elem` ["reauthorization_required", "revoked", "erasure_pending"]) $
        Left (storageError "materializable connection state may not omit encrypted state")
    Just encrypted -> do
      when (B.null encrypted) $ Left (storageError "encrypted connection state must be non-empty bytes")
      when (connection.stateDigest /= Just (sha256Hex encrypted)) $
        Left (storageError "encrypted connection state digest does not match its bytes")

validateLeases :: StorageSnapshot -> Either AgenticusError ()
validateLeases snapshot = do
  let leases = snapshot.leases
  unique [lease.leaseId | lease <- leases] "lease identities"
  unique [lease.attachmentId | lease <- leases] "attachment identities"
  when (outOfOrder (map (.leaseId) leases)) $ Left (storageError "materialization leases must be canonically ordered")
  let hosts = Map.fromList [(host.hostId, host) | host <- snapshot.hosts]
      connections = Map.fromList [(connection.connectionId, connection) | connection <- snapshot.connections]
  forM_ leases $ \lease -> do
    validateLeaseValue lease
    case (Map.lookup lease.hostId hosts, Map.lookup lease.connectionId connections) of
      (Just host, Just connection) -> unless lease.released (validateLiveLeaseAuthority lease host connection)
      _ -> Left (storageError "materialization lease references unknown authority")
  validateActiveLeaseSets leases snapshot.connections

validateLeaseValue :: StoredLease -> Either AgenticusError ()
validateLeaseValue lease = do
  storedText lease.leaseId "lease identity"
  storedText lease.attachmentId "attachment identity"
  storedText lease.connectionId "lease connection identity"
  storedText lease.hostId "lease host identity"
  unless (lease.mode `elem` ["read", "refresh"]) $ Left (storageError "materialization lease mode is not supported")
  positiveInteger lease.hostEpoch "lease host epoch"
  positiveInteger lease.authorityEpoch "lease authority epoch"
  positiveInteger lease.baseVersion "lease base version"
  unless (isFinite lease.expiresAt) $ Left (storageError "materialization lease expiry must be a finite number")
  when (lease.activated && lease.mode /= "refresh") $ Left (storageError "only refresh custody may be activated")
  when (lease.released /= isJust lease.releaseReason) $
    Left (storageError "released materialization lease must carry exactly one release reason")

validateLiveLeaseAuthority :: StoredLease -> StoredHost -> StoredConnection -> Either AgenticusError ()
validateLiveLeaseAuthority lease host connection = do
  when (not host.active || host.enrollmentEpoch /= lease.hostEpoch) $
    Left (storageError "active materialization lease references stale host authority")
  when (connection.authorityEpoch /= lease.authorityEpoch || connection.stateVersion /= lease.baseVersion) $
    Left (storageError "active materialization lease references stale connection authority")

validateActiveLeaseSets :: [StoredLease] -> [StoredConnection] -> Either AgenticusError ()
validateActiveLeaseSets leases connections = do
  let activeBy = Map.fromListWith (flip (<>)) [(lease.connectionId, [lease]) | lease <- leases, not lease.released]
  -- @{c.connection_id: c for c in connections}.items()@: first position,
  -- last value.
  forM_ (dictItems [(connection.connectionId, connection) | connection <- connections]) $ \(connectionId, connection) -> do
    let active = Map.findWithDefault [] connectionId activeBy
        refresh = [lease | lease <- active, lease.mode == "refresh"]
    when (not (null refresh) && (length refresh /= 1 || length active /= 1)) $
      Left (storageError "refresh custody must be the only active materialization")
    when (not (null refresh) && connection.status /= "refreshing") $
      Left (storageError "active refresh custody requires refreshing connection state")
    when (null refresh && connection.status == "refreshing") $
      Left (storageError "refreshing connection state requires active refresh custody")
    when (not (null active) && connection.status `notElem` ["ready", "refreshing"]) $
      Left (storageError "fail-closed connection state cannot retain active materializations")

validateAudit :: [AuditRecord] -> Either AgenticusError ()
validateAudit records = do
  unique [record.operationId | record <- records] "operation identities"
  forM_ (zip [1 ..] records) $ \(expected, record) -> do
    when (record.sequence /= expected) $
      Left (storageError "custody operation records must have dense canonical sequences")
    storedText record.operationId "operation identity"
    storedText record.eventKind "operation event kind"
    forM_ [record.connectionId, record.hostId, record.leaseId] $ \case
      Just identity -> storedText identity "operation subject identity"
      Nothing -> Right ()
    let names = map fst record.details
    when (names /= sort names) $ Left (storageError "operation details must be canonically ordered")
    unless (all (safeValue . snd) record.details) $
      Left (storageError "operation details must contain safe scalar values")

-- | Whether the (unique) identities are out of canonical order.
outOfOrder :: [Text] -> Bool
outOfOrder identities = identities /= sort identities

safeValue :: AuditValue -> Bool
safeValue = \case
  AuditFloat value -> isFinite value
  _ -> True

unique :: [Text] -> Text -> Either AgenticusError ()
unique values name =
  when (Set.size (Set.fromList values) /= length values) $ Left (storageError (name <> " must be unique"))

storedText :: Text -> Text -> Either AgenticusError ()
storedText value name =
  when (T.null value || T.dropAround pyIsSpace value /= value || T.any (\c -> ord c < 32) value) $
    Left (storageError (name <> " must be a non-empty trimmed string"))

positiveInteger :: Integer -> Text -> Either AgenticusError ()
positiveInteger value name = when (value <= 0) $ Left (storageError (name <> " must be a positive integer"))

isFinite :: Double -> Bool
isFinite value = not (isNaN value || isInfinite value)

-- | Python dict construction from pairs: first insertion position, last
-- value.
dictItems :: [(Text, a)] -> [(Text, a)]
dictItems pairs = [(key, latest Map.! key) | key <- order]
  where
    latest = Map.fromList pairs
    order = go Set.empty (map fst pairs)
    go _ [] = []
    go seen (key : rest)
      | key `Set.member` seen = go seen rest
      | otherwise = key : go (Set.insert key seen) rest

-- ---------------------------------------------------------------------------
-- Payload format

-- | The payload as a JSON value (before @json.dumps@), every object's
-- members already in @sort_keys@ order (code point order of unique keys).
snapshotToJson :: StorageSnapshot -> Json
snapshotToJson snapshot =
  Object
    [ ("audit", Array (map auditJson snapshot.audit))
    , ("connections", Array (map connectionJson snapshot.connections))
    , ("hosts", Array (map hostJson snapshot.hosts))
    , ("leases", Array (map leaseJson snapshot.leases))
    , ("revision", Int snapshot.revision)
    , ("schema_version", Int 1)
    ]
  where
    hostJson host =
      Object
        [ ("active", Bool host.active)
        , ("enrollment_epoch", Int host.enrollmentEpoch)
        , ("host_id", String host.hostId)
        ]
    connectionJson connection =
      Object
        [ ("account_fingerprint", String connection.accountFingerprint)
        , ("authority_epoch", Int connection.authorityEpoch)
        , ("connection_id", String connection.connectionId)
        , ("encrypted_state", maybe Null (String . base64Encode) connection.encryptedState)
        , ("profile", String connection.profile)
        , ("provider", String connection.provider)
        , ("state_digest", maybe Null String connection.stateDigest)
        , ("state_version", Int connection.stateVersion)
        , ("status", String connection.status)
        ]
    leaseJson lease =
      Object
        [ ("activated", Bool lease.activated)
        , ("attachment_id", String lease.attachmentId)
        , ("authority_epoch", Int lease.authorityEpoch)
        , ("base_version", Int lease.baseVersion)
        , ("connection_id", String lease.connectionId)
        , ("expires_at", Float lease.expiresAt)
        , ("host_epoch", Int lease.hostEpoch)
        , ("host_id", String lease.hostId)
        , ("lease_id", String lease.leaseId)
        , ("mode", String lease.mode)
        , ("release_reason", maybe Null String lease.releaseReason)
        , ("released", Bool lease.released)
        ]
    auditJson record =
      Object
        [ ("connection_id", maybe Null String record.connectionId)
        , ("details", Object (sortOn fst (dictItems [(name, auditValueJson value) | (name, value) <- record.details])))
        , ("event_kind", String record.eventKind)
        , ("host_id", maybe Null String record.hostId)
        , ("lease_id", maybe Null String record.leaseId)
        , ("operation_id", String record.operationId)
        , ("sequence", Int record.sequence)
        ]

auditValueJson :: AuditValue -> Json
auditValueJson = \case
  AuditNone -> Null
  AuditStr text -> String text
  AuditInt value -> Int value
  AuditFloat value -> Float value
  AuditBool value -> Bool value

-- | @json.dumps(..., sort_keys=True, separators=(",", ":"))@; the members
-- are emitted sorted by 'snapshotToJson', so the encoder need not sort.
payloadOptions :: J.EncodeOptions
payloadOptions =
  J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":", J.sortKeys = False, J.allowNan = False}

-- | @_encode@: validate, then spell the payload.
encodeSnapshot :: StorageSnapshot -> Either AgenticusError Text
encodeSnapshot snapshot = validateSnapshot snapshot >>= renderPayload

-- | Spell an already validated snapshot.
renderPayload :: StorageSnapshot -> Either AgenticusError Text
renderPayload snapshot = case J.dumpsText payloadOptions (snapshotToJson snapshot) of
  Right text -> Right text
  Left _ -> Left (valueError "Out of range float values are not JSON compliant")

encodeSnapshotText :: StorageSnapshot -> Text
encodeSnapshotText snapshot = either (error . show) id (encodeSnapshot snapshot)

-- | @_decode@: parse and validate a stored payload.  Every shape failure is
-- @StorageError("connection custody payload is invalid")@; a well-formed
-- payload that violates an invariant fails with that invariant's message.
decodeSnapshot :: Text -> Either AgenticusError StorageSnapshot
decodeSnapshot payload = case decodeShape payload of
  Nothing -> Left (storageError "connection custody payload is invalid")
  Just snapshot -> validateSnapshot snapshot

decodeShape :: Text -> Maybe StorageSnapshot
decodeShape payload = do
  root <- either (const Nothing) Just (J.parseJson J.pythonLoads (TE.encodeUtf8 payload))
  fields <- object root
  schema <- integer =<< key "schema_version" fields
  unless (schema == 1) Nothing
  revision <- integer =<< key "revision" fields
  hosts <- mapM host =<< array =<< key "hosts" fields
  connections <- mapM connection =<< array =<< key "connections" fields
  leases <- mapM lease =<< array =<< key "leases" fields
  audit <- mapM auditRecord =<< array =<< key "audit" fields
  pure StorageSnapshot {..}
  where
    host item = do
      fields <- object item
      hostId <- string =<< key "host_id" fields
      enrollmentEpoch <- integer =<< key "enrollment_epoch" fields
      active <- boolean =<< key "active" fields
      pure StoredHost {..}
    connection item = do
      fields <- object item
      encrypted <- key "encrypted_state" fields
      connectionId <- string =<< key "connection_id" fields
      provider <- string =<< key "provider" fields
      accountFingerprint <- string =<< key "account_fingerprint" fields
      profile <- string =<< key "profile" fields
      status <- string =<< key "status" fields
      authorityEpoch <- integer =<< key "authority_epoch" fields
      stateVersion <- integer =<< key "state_version" fields
      encryptedState <- case encrypted of
        Null -> pure Nothing
        other -> Just <$> (base64Decode =<< string other)
      stateDigest <- optionalString =<< key "state_digest" fields
      pure StoredConnection {..}
    lease item = do
      fields <- object item
      leaseId <- string =<< key "lease_id" fields
      attachmentId <- string =<< key "attachment_id" fields
      connectionId <- string =<< key "connection_id" fields
      hostId <- string =<< key "host_id" fields
      hostEpoch <- integer =<< key "host_epoch" fields
      mode <- string =<< key "mode" fields
      authorityEpoch <- integer =<< key "authority_epoch" fields
      baseVersion <- integer =<< key "base_version" fields
      expiresAt <- number =<< key "expires_at" fields
      activated <- boolean =<< key "activated" fields
      released <- boolean =<< key "released" fields
      releaseReason <- optionalString =<< key "release_reason" fields
      pure StoredLease {..}
    auditRecord item = do
      fields <- object item
      detailFields <- object =<< key "details" fields
      details <- sortOnName <$> mapM (\(name, value) -> (name,) <$> auditValue value) detailFields
      sequence <- integer =<< key "sequence" fields
      operationId <- string =<< key "operation_id" fields
      eventKind <- string =<< key "event_kind" fields
      connectionId <- optionalString =<< key "connection_id" fields
      hostId <- optionalString =<< key "host_id" fields
      leaseId <- optionalString =<< key "lease_id" fields
      pure AuditRecord {..}
    sortOnName = map snd . Map.toAscList . Map.fromList . map (\pair@(name, _) -> (name, pair))
    key name fields = lookup name fields
    object = \case
      Object members -> Just members
      _ -> Nothing
    array = \case
      Array items -> Just items
      _ -> Nothing
    string = \case
      String text -> Just text
      _ -> Nothing
    optionalString = \case
      Null -> Just Nothing
      String text -> Just (Just text)
      _ -> Nothing
    integer = \case
      Int value -> Just value
      _ -> Nothing
    boolean = \case
      Bool value -> Just value
      _ -> Nothing
    number = \case
      Int value
        | isFinite (fromInteger value) -> Just (fromInteger value)
      Float value
        | isFinite value -> Just value
      _ -> Nothing
    auditValue = \case
      Null -> Just AuditNone
      String text -> Just (AuditStr text)
      Int value -> Just (AuditInt value)
      Bool value -> Just (AuditBool value)
      Float value
        | isFinite value -> Just (AuditFloat value)
      _ -> Nothing

-- ---------------------------------------------------------------------------
-- Base64 (RFC 4648 standard alphabet, padded)

-- | @base64.b64encode(value).decode("ascii")@.
base64Encode :: ByteString -> Text
base64Encode bytes = TE.decodeLatin1 (convertToBase Base64 bytes)

-- | @base64.b64decode(value, validate=True)@ (CPython ≥ 3.11 strict mode):
-- ASCII only, the standard alphabet, complete quads, and at most two
-- trailing pad characters.  Unused trailing bits are ignored, as CPython
-- does.
base64Decode :: Text -> Maybe ByteString
base64Decode text
  | T.any (\c -> ord c > 127) text = Nothing
  | B.length raw `mod` 4 /= 0 = Nothing
  | B.any (== 61) body = Nothing
  | padding > 2 = Nothing
  | padding > 0 && B.length body `mod` 4 < 2 = Nothing
  | otherwise = B.pack <$> decodeBody (B.unpack body)
  where
    raw = TE.encodeUtf8 text
    body = B.dropWhileEnd (== 61) raw
    padding = B.length raw - B.length body
    value :: Word8 -> Maybe Int
    value w
      | w >= 65 && w <= 90 = Just (fromIntegral w - 65)
      | w >= 97 && w <= 122 = Just (fromIntegral w - 71)
      | w >= 48 && w <= 57 = Just (fromIntegral w + 4)
      | w == 43 = Just 62
      | w == 47 = Just 63
      | otherwise = Nothing
    decodeBody = \case
      [] -> Just []
      (a : b : c : d : rest) -> do
        [va, vb, vc, vd] <- mapM value [a, b, c, d]
        let n = (va `shiftL` 18) .|. (vb `shiftL` 12) .|. (vc `shiftL` 6) .|. vd
        (map fromIntegral [n `shiftR` 16 .&. 255, n `shiftR` 8 .&. 255, n .&. 255] <>) <$> decodeBody rest
      [a, b, c] -> do
        [va, vb, vc] <- mapM value [a, b, c]
        let n = (va `shiftL` 18) .|. (vb `shiftL` 12) .|. (vc `shiftL` 6)
        Just (map fromIntegral [n `shiftR` 16 .&. 255, n `shiftR` 8 .&. 255])
      [a, b] -> do
        [va, vb] <- mapM value [a, b]
        let n = (va `shiftL` 18) .|. (vb `shiftL` 12)
        Just [fromIntegral (n `shiftR` 16 .&. 255)]
      _ -> Nothing
