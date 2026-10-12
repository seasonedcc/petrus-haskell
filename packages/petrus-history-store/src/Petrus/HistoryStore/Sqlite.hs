-- | The event History in a local SQLite file (the reference's
-- @petrus.impetus.history_store.sqlite@).
--
-- Many Instances' Histories may share one database. The store owns only the
-- @impetus_history_*@ namespace: schema version 1 is created in a new
-- database and otherwise validated, never migrated; other tables in the file
-- (Local Dispatch state, an application's own) are left alone.
--
-- = Format
--
-- The DDL ('historyDdl'), every statement, the connection PRAGMAs, and the
-- payload spelling are the reference's, byte for byte. Each row's @payload@
-- is @json.dumps(encode_record(record), allow_nan=False,
-- separators=(",", ":"))@ (compact, ASCII-escaped, member order kept); its
-- @event_id@ is @"<instance>:<position>"@; @record_type@ is the record's
-- class name and @occurrence@ its @occurrence@ field (or @NULL@). A Python
-- process and a Haskell process open, validate, load, and append to the
-- same file, and the reference validates this module's tables by their
-- @sqlite_master.sql@ text.
--
-- = Writes
--
-- One 'Petrus.Impetus.HistoryStore.extend' is one short @BEGIN IMMEDIATE@
-- transaction: the whole batch is encoded first (an unencodable record
-- refuses the batch before any IO), then each record is inserted at the
-- mirror's next position with @ON CONFLICT DO NOTHING@. A conflicting insert
-- is verified against the stored row with Python value equality: an equal
-- fact at the same event identity fills the position; an equal terminal held
-- at another position (the one-terminal indexes) is acknowledged and does
-- not enter the mirror; a different fact refuses the batch, which is rolled
-- back whole. The mirror grows only after @COMMIT@.
--
-- = Writers
--
-- The store is the unfenced low-level route: the database's unique
-- constraints are the cross-process backstop, not a coordination protocol.
-- Production hosts take the 'WriterFence' (re-exported here, from
-- "Petrus.Sqlite.WriterFence") before loading, as the SQLite Engine
-- provider (@petrus-engine-sqlite@) does.
module Petrus.HistoryStore.Sqlite
  ( -- * The store
    SqliteHistoryStore (..)
  , openSqliteHistoryStore
  , withSqliteHistoryStore
    -- * The format
  , historySchemaVersion
  , historyDdl
  , encodeRow
  , encodeRows
  , EncodedRow (..)
    -- * Errors
  , HistoryStoreError (..)
  , SqliteHistoryStoreFailure (..)
    -- * The writer fence
  , WriterFence
  , fenceLockPath
  , fenceDatabase
  , fenceInstance
  , FenceError (..)
  , fenceErrorMessage
  , writerFencePaths
  , acquireWriterFence
  , ensureWriterFence
  , releaseWriterFence
  , withWriterFence
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (Exception (..), bracket, mask, onException, throwIO, try)
import Control.Monad (foldM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Unsafe qualified as BU
import Data.Int (Int64)
import Data.List (intercalate)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Storable (pokeByteOff)
import GHC.ForeignPtr (unsafeWithForeignPtr)
import Petrus.HistoryStore.Internal (HistoryStoreError (..), decodeStored, pythonDiagnostic)
import Petrus.Impetus.History.Codec (encodeRecord, historyLoads)
import Petrus.Impetus.History.Records (Record, recordName, recordOccurrence, recordTerminalFamily, terminalFamilyNames)
import Petrus.Impetus.HistoryStore
import Petrus.Json (EncodeOptions (..), Json (..), compact, dumpsMany, encodeErrorMessage, jsonTypeName, lookupMember, parseJson)
import Petrus.Posix.Path (purePath)
import Petrus.Sqlite.Connection (Connection, SQLData (..))
import Petrus.Sqlite.Connection qualified as Sql
import Petrus.Sqlite.PythonRepr (pythonReprBytes, pythonReprFloat, pythonReprSqlData, pythonReprText)
import Petrus.Sqlite.Schema (normalizeDdl)
import Petrus.Sqlite.WriterFence
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

-- ---------------------------------------------------------------------------
-- The format

-- | @_SCHEMA_VERSION@: the only version this store creates and reads.
historySchemaVersion :: Int64
historySchemaVersion = 1

-- | @_DDL@, verbatim: the reference validates these objects by their stored
-- @sqlite_master.sql@ text, so they are created from the same strings.
historyDdl :: [Text]
historyDdl = [schemaTable, schemaRow, eventsTable, oneFiringTerminal, oneActivityTerminal]

schemaTable, schemaRow, eventsTable, oneFiringTerminal, oneActivityTerminal :: Text
schemaTable =
  "CREATE TABLE impetus_history_schema (\n\
  \    component TEXT PRIMARY KEY CHECK (component = 'history'),\n\
  \    version INTEGER NOT NULL\n\
  \)"
schemaRow = "INSERT INTO impetus_history_schema (component, version) VALUES ('history', 1)"
eventsTable =
  "CREATE TABLE impetus_history_events (\n\
  \    instance TEXT NOT NULL,\n\
  \    position INTEGER NOT NULL CHECK (position >= 0),\n\
  \    event_id TEXT NOT NULL UNIQUE,\n\
  \    record_type TEXT NOT NULL,\n\
  \    occurrence INTEGER,\n\
  \    payload TEXT NOT NULL,\n\
  \    recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),\n\
  \    PRIMARY KEY (instance, position)\n\
  \)"
oneFiringTerminal =
  "CREATE UNIQUE INDEX impetus_history_one_firing_terminal\n\
  \    ON impetus_history_events (instance, occurrence)\n\
  \    WHERE record_type IN ('FiringCompleted', 'FiringFailed')"
oneActivityTerminal =
  "CREATE UNIQUE INDEX impetus_history_one_activity_terminal\n\
  \    ON impetus_history_events (instance, occurrence)\n\
  \    WHERE record_type IN ('ActivityCompleted', 'ActivityFailed')"

-- | The DDL each stored object must match, by name.
expectedSql :: Map Text Text
expectedSql =
  Map.fromList
    [ ("impetus_history_schema", schemaTable)
    , ("impetus_history_events", eventsTable)
    , ("impetus_history_one_firing_terminal", oneFiringTerminal)
    , ("impetus_history_one_activity_terminal", oneActivityTerminal)
    ]

expectedObjects :: Map Text SQLData
expectedObjects =
  Map.fromList
    [ ("impetus_history_schema", SQLText "table")
    , ("impetus_history_events", SQLText "table")
    , ("impetus_history_one_firing_terminal", SQLText "index")
    , ("impetus_history_one_activity_terminal", SQLText "index")
    ]


-- | One record's row values, encoded before any IO.
data EncodedRow = EncodedRow
  { record :: Record
  , value :: ~Json
  -- ^ @encode_record(record)@, recomputed on demand: only a conflicting
  -- insert compares it, so a batch does not keep every record's tree alive.
  , recordType :: Text
  , occurrence :: SQLData
  -- ^ @encoded.get("occurrence")@: an integer or @NULL@.
  , payload :: ByteString
  -- ^ The compact, ASCII-escaped spelling.
  }

-- | The payload spelling: @json.dumps(..., allow_nan=False,
-- separators=(",", ":"))@, whose @ensure_ascii@ stays @True@.
payloadOptions :: EncodeOptions
payloadOptions = compact {ensureAscii = True}

-- | Encode one record's row, or the reference's refusal text.
encodeRow :: Record -> Either Text EncodedRow
encodeRow r = encodeRows [r] >>= \case
  [row] -> Right row
  _ -> Left "cannot durably encode: no row"

-- | Encode a batch's rows before any IO (@_commit@'s @batch = [...]@): the
-- first refused record's text, in batch order, or every row. The payloads
-- are slices of one buffer ('dumpsMany'): a batch's rows are written
-- together and dropped together.
encodeRows :: [Record] -> Either Text [EncodedRow]
encodeRows batch = case dumpsMany payloadOptions (map encodeRecord batch) of
  Left (index, problem) -> Left (refusal (batch !! index) problem)
  Right payloads -> Right (zipWith row batch payloads)
  where
    -- @encoded.get("occurrence")@ is the record's occurrence: every record
    -- that carries one encodes it under that key, as an integer or null.
    row r bytes = EncodedRow r (encodeRecord r) (recordName r) (maybe SQLNull (SQLInteger . fromIntegral) (recordOccurrence r)) bytes
    refusal r problem =
      "cannot durably encode "
        <> recordName r
        <> ": "
        <> T.pack (encodeErrorMessage problem)
        <> " — durable instants, token data, and activity input/result must be JSON-faithful values"

-- ---------------------------------------------------------------------------
-- Errors

-- | The store's failures that the reference raises as something other than
-- @ValueError@ (which is 'HistoryStoreError').
-- (An insert conflict no stored row explains is the kernel's
-- 'UnverifiableConflict'.)
data SqliteHistoryStoreFailure
  = -- | @sqlite3.ProgrammingError@: the store was used after 'close'.
    ClosedDatabase
  deriving stock (Eq, Show)

instance Exception SqliteHistoryStoreFailure where
  displayException ClosedDatabase = "Cannot operate on a closed database."

-- ---------------------------------------------------------------------------
-- The store

-- | An open store: the kernel's 'HistoryStore' over the file, and the
-- connection's 'close'.
data SqliteHistoryStore = SqliteHistoryStore
  { history :: HistoryStore
  , path :: FilePath
  -- ^ The path as given.
  , instanceId :: Text
  , close :: IO ()
  -- ^ Close the connection (idempotent). Later appends raise
  -- 'ClosedDatabase'; the loaded mirror stays readable.
  }

-- | @SqliteHistoryStore(path, instance)@: make the parent directory, connect,
-- refuse a foreign or unsupported schema before any PRAGMA touches the file,
-- configure the connection (WAL, @synchronous=FULL@, @busy_timeout=5000@,
-- @foreign_keys=ON@), create or validate the schema, and load the instance's
-- rows. Any failure closes the connection and propagates.
openSqliteHistoryStore :: FilePath -> Text -> IO SqliteHistoryStore
openSqliteHistoryStore path instanceId = do
  when (T.null instanceId) $
    throwIO (HistoryStoreError "SqliteHistoryStore requires a non-empty string instance id, got ''")
  createDirectoryIfMissing True (takeDirectory path)
  let shown = T.pack (purePath path)
  (connection, loaded) <- mask $ \restore -> do
    connection <- Sql.connect path 5000 Sql.Autocommit
    loaded <-
      restore
        ( do
            checkMetadata shown connection
            configure connection
            Sql.withImmediateTransaction connection (ensureSchema shown connection)
            loadRows shown instanceId connection
        )
        `onException` Sql.close connection
    pure (connection, loaded)
  guard' <- newMVar (Just connection)
  store <- mirroredHistoryStore BackendOwned loaded (commitBatch instanceId guard')
  pure
    SqliteHistoryStore
      { history = store
      , path
      , instanceId
      , close = modifyMVar_ guard' (\held -> Nothing <$ mapM_ Sql.close held)
      }

-- | Open, run, close.
withSqliteHistoryStore :: FilePath -> Text -> (SqliteHistoryStore -> IO a) -> IO a
withSqliteHistoryStore path instanceId = bracket (openSqliteHistoryStore path instanceId) (.close)

refuse :: Text -> IO a
refuse = throwIO . HistoryStoreError

-- | @SELECT name, type FROM sqlite_master WHERE name LIKE 'impetus_history_%'@
-- as a dictionary (@LIKE@'s @_@ is a wildcard and ASCII case is ignored, as
-- in the reference).
historyObjects :: Connection -> IO (Map Text SQLData)
historyObjects connection = do
  rows <- Sql.query connection "SELECT name, type FROM sqlite_master WHERE name LIKE 'impetus_history_%'" []
  pure (Map.fromList [(name, kind) | [SQLText name, kind] <- rows])

-- | The preflight (@_preflight_schema@): an empty namespace is fresh;
-- otherwise the version metadata must be exactly version 1.
checkMetadata :: Text -> Connection -> IO ()
checkMetadata shown connection = do
  objects <- historyObjects connection
  unless (Map.null objects) (checkVersion shown connection objects)

checkVersion :: Text -> Connection -> Map Text SQLData -> IO ()
checkVersion shown connection objects = do
  when (Map.lookup "impetus_history_schema" objects /= Just (SQLText "table")) $
    refuse (shown <> ": foreign or unversioned impetus_history schema; migration is not supported")
  columns <- columnNames connection "impetus_history_schema"
  when (columns /= [SQLText "component", SQLText "version"]) $
    refuse (shown <> ": foreign impetus_history schema metadata shape; migration is not supported")
  rows <- Sql.query connection "SELECT component, version FROM impetus_history_schema" []
  unless (supported rows) $
    refuse
      ( shown
          <> ": unsupported impetus_history schema metadata "
          <> T.pack (reprRows rows)
          <> "; this store reads version 1 only and does not migrate"
      )
  where
    -- @rows == [("history", 1)]@ under Python equality (1 == 1.0).
    supported = \case
      [[SQLText "history", SQLInteger 1]] -> True
      [[SQLText "history", SQLFloat 1]] -> True
      _ -> False

-- | @[row[1] for row in PRAGMA table_info(table)]@.
columnNames :: Connection -> Text -> IO [SQLData]
columnNames connection table = do
  rows <- Sql.query connection ("PRAGMA table_info(" <> table <> ")") []
  pure [name | _ : name : _ <- rows]

-- | @repr(rows)@ of a @fetchall()@ result: a list of tuples.
reprRows :: [[SQLData]] -> String
reprRows rows = "[" ++ intercalate ", " (map tuple rows) ++ "]"
  where
    tuple = \case
      [single] -> "(" ++ pythonReprSqlData single ++ ",)"
      values -> "(" ++ intercalate ", " (map pythonReprSqlData values) ++ ")"

-- | The reference's @_configure@: its PRAGMAs, with a refused WAL switch
-- reported as its @ValueError@.
configure :: Connection -> IO ()
configure connection =
  try (Sql.configure connection Sql.historyStoreProfile) >>= \case
    Right () -> pure ()
    Left (refusal :: Sql.WalRefused) -> refuse (T.pack (Sql.historyWalRefusal refusal))

-- | @_ensure_schema_locked@ (inside @BEGIN IMMEDIATE@): create the schema in
-- an empty namespace, or validate version, object set, DDL text, and event
-- columns.
ensureSchema :: Text -> Connection -> IO ()
ensureSchema shown connection = do
  objects <- historyObjects connection
  if Map.null objects
    then mapM_ (Sql.execute_ connection) historyDdl
    else do
      checkVersion shown connection objects
      when (objects /= expectedObjects) $
        refuse (shown <> ": corrupt or foreign impetus_history version 1 shape")
      rows <-
        Sql.query
          connection
          "SELECT name, sql FROM sqlite_master WHERE name IN (?, ?, ?, ?)"
          (map SQLText (Map.keys expectedSql))
      let actual = Map.fromList [(name, normalized sql) | [SQLText name, sql] <- rows]
          normalized = \case
            SQLText sql -> Just (normalizeDdl sql)
            _ -> Nothing
      when (actual /= Map.map (Just . normalizeDdl) expectedSql) $
        refuse (shown <> ": corrupt or foreign impetus_history version 1 DDL shape")
      columns <- columnNames connection "impetus_history_events"
      when (columns /= map SQLText ["instance", "position", "event_id", "record_type", "occurrence", "payload", "recorded_at"]) $
        refuse (shown <> ": corrupt or foreign impetus_history version 1 event shape")

-- | @_load@: every row of the instance in position order, dense from 0 with
-- matching event identities, each payload decoding as a record whose type
-- and occurrence match the indexing columns. All or nothing.
loadRows :: Text -> Text -> Connection -> IO (Seq Record)
loadRows shown instanceId connection = do
  rows <-
    Sql.query
      connection
      "SELECT position, event_id, record_type, occurrence, payload FROM impetus_history_events WHERE instance = ? ORDER BY position"
      [SQLText instanceId]
  -- a strict left fold: a long History must not build a deep stack
  let step !acc (expected, row) = (acc Seq.|>) <$> loadRow expected row
      loadRow :: Integer -> [SQLData] -> IO Record
      loadRow expected = \case
        [position, eventId, recordType, occurrence', payload'] -> do
          let expectedId = instanceId <> ":" <> T.pack (show expected)
          unless (sameInteger position expected && eventId == SQLText expectedId) $
            refuse
              ( shown
                  <> ": history for "
                  <> T.pack (pythonReprText instanceId)
                  <> " is non-dense or has corrupt event identity at position "
                  <> T.pack (show expected)
              )
          let undecodable :: Text -> IO a
              undecodable err = refuse ("event " <> expectedId <> " does not decode as an event history record: " <> err)
          json <- either undecodable pure (loadsColumn payload')
          record <- either undecodable pure (decodeStored json)
          -- @encoded.get("occurrence")@ on a list that @dict()@ converted
          case json of
            Object _ -> pure ()
            other -> refuse ("'" <> jsonTypeName other <> "' object has no attribute 'get'")
          unless (recordType == SQLText (recordName record) && sameOccurrence (lookupMember "occurrence" json) occurrence') $
            refuse ("event " <> expectedId <> " has corrupt indexing metadata")
          pure record
        _ -> refuse (shown <> ": unexpected impetus_history_events row shape")
  foldM step Seq.empty (zip [0 :: Integer ..] rows)

-- | @column == n@ for an integer @n@ under Python equality.
sameInteger :: SQLData -> Integer -> Bool
sameInteger value n = case value of
  SQLInteger m -> toInteger m == n
  SQLFloat d -> floatEqualsInteger d n
  _ -> False

floatEqualsInteger :: Double -> Integer -> Bool
floatEqualsInteger d n = not (isNaN d || isInfinite d) && fromIntegral (truncate d :: Integer) == d && truncate d == n

-- | @encoded.get("occurrence") == occurrence@ under Python equality.
sameOccurrence :: Maybe Json -> SQLData -> Bool
sameOccurrence encoded column = case (encoded, column) of
  (Nothing, SQLNull) -> True
  (Just Null, SQLNull) -> True
  (Just (Int n), _) -> sameInteger column n
  (Just (Bool b), _) -> sameInteger column (if b then 1 else 0)
  (Just (Float d), SQLFloat e) -> d == e
  (Just (Float d), SQLInteger m) -> floatEqualsInteger d (toInteger m)
  (Just (String s), SQLText t) -> s == t
  _ -> False

-- | @json.loads(column)@ of a stored payload, or CPython's message.
loadsColumn :: SQLData -> Either Text Json
loadsColumn = \case
  SQLText text -> loadsBytes (TE.encodeUtf8 text)
  SQLBlob bytes -> loadsBytes bytes
  SQLInteger _ -> notText "int"
  SQLFloat _ -> notText "float"
  SQLNull -> notText "NoneType"
  where
    notText kind = Left ("the JSON object must be str, bytes or bytearray, not " <> kind)
    loadsBytes bytes = case parseJson historyLoads bytes of
      Right json -> Right json
      Left fallback -> Left (pythonDiagnostic bytes (T.pack fallback))

-- | @str(value)@ of a column value interpolated into a message.
pythonStr :: SQLData -> Text
pythonStr = \case
  SQLText text -> text
  SQLInteger n -> T.pack (show n)
  SQLFloat d -> T.pack (pythonReprFloat d)
  SQLBlob bytes -> T.pack (pythonReprBytes bytes)
  SQLNull -> "None"

-- ---------------------------------------------------------------------------
-- Writes

insertStatement :: Text
insertStatement =
  "INSERT INTO impetus_history_events (instance, position, event_id, record_type, occurrence, payload) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING"

-- | @_commit@: encode the whole batch, then one @BEGIN IMMEDIATE@
-- transaction inserting each record from the mirror's next position.
--
-- Each insert binds its six values as they are: the instance and record
-- type from their 'Text's, the event identity written into one buffer the
-- batch reuses, and the payload from the batch's encoded bytes (ASCII, so
-- already the UTF-8 text the reference binds).
commitBatch :: Text -> MVar (Maybe Connection) -> Int -> [Record] -> IO [Admission]
commitBatch instanceId guard' start batch = do
  rows <- either refuse pure (encodeRows batch)
  withMVar guard' $ \case
    Nothing -> throwIO ClosedDatabase
    Just connection -> do
      withEventId <- eventIdWriter instanceId
      Sql.withImmediateTransaction connection $ do
        -- tail recursive: the admissions accumulate in reverse (a 20 000-row
        -- batch would otherwise build as deep a stack)
        let go !_ admitted [] = pure (reverse admitted)
            go position admitted (row : rest) = do
              changed <- withEventId position $ \eventId ->
                Sql.executeWith connection insertStatement $ \statement -> do
                  Sql.bindTextParam statement 1 instanceId
                  Sql.bindInt64Param statement 2 (fromIntegral position)
                  Sql.bindUtf8Param statement 3 eventId
                  Sql.bindTextParam statement 4 row.recordType
                  Sql.bindParam statement 5 row.occurrence
                  Sql.bindUtf8Param statement 6 row.payload
              entered <-
                if changed /= 0
                  then pure True
                  else verifyInsert connection instanceId (instanceId <> ":" <> T.pack (show position)) row
              if entered
                then go (position + 1) (Entered : admitted) rest
                else go position (AcknowledgedElsewhere : admitted) rest
        go start [] rows

-- | The event identities @"<instance>:<position>"@ of a batch, spelled into
-- one buffer: the instance prefix once, each position's digits in turn. The
-- bytes handed to the action are valid only during it (SQLite copies a
-- bound text).
eventIdWriter :: Text -> IO (Int -> (ByteString -> IO a) -> IO a)
eventIdWriter instanceId = do
  let prefix = TE.encodeUtf8 instanceId <> ":"
      prefixSize = BS.length prefix
  buffer <- BI.mallocByteString (prefixSize + 20)
  unsafeWithForeignPtr buffer $ \target -> BU.unsafeUseAsCString prefix $ \source -> copyBytes target (castPtr source) prefixSize
  pure $ \position action -> do
    digits <- unsafeWithForeignPtr buffer $ \target -> writeDecimal (target `plusPtr` prefixSize) position
    action (BI.BS buffer (prefixSize + digits))

-- | Write a non-negative 'Int' in decimal; answer the digit count.
writeDecimal :: Ptr Word8 -> Int -> IO Int
writeDecimal target value = fill (count 1 value - 1) value >> pure (count 1 value)
  where
    count !n v = if v < 10 then n else count (n + 1) (v `quot` 10)
    fill i v = do
      let (q, r) = v `quotRem` 10
      pokeByteOff target i (fromIntegral (0x30 + r) :: Word8)
      if q == 0 then pure () else fill (i - 1) q

-- | @_verify_conflict@: 'True' when an equal fact holds this event identity
-- (the record fills the position), 'False' when an equal terminal is held
-- elsewhere (acknowledged); a different fact refuses.
verifyInsert :: Connection -> Text -> Text -> EncodedRow -> IO Bool
verifyInsert connection instanceId eventId row = do
  stored <- Sql.queryFirst connection "SELECT record_type, payload FROM impetus_history_events WHERE event_id = ?" [SQLText eventId]
  case stored of
    Just [storedType, storedPayload] -> do
      json <- either refuse pure (loadsColumn storedPayload)
      if json == row.value
        then pure True
        else
          refuse
            ( "event "
                <> eventId
                <> " is already recorded as a different fact (stored "
                <> pythonStr storedType
                <> ", appending "
                <> row.recordType
                <> ")"
            )
    _ -> do
      terminal <- case terminalFamilyNames <$> recordTerminalFamily row.record of
        Nothing -> pure Nothing
        Just (a, b) ->
          Sql.queryFirst
            connection
            "SELECT event_id, record_type, payload FROM impetus_history_events WHERE instance = ? AND occurrence = ? AND record_type IN (?, ?)"
            [SQLText instanceId, row.occurrence, SQLText a, SQLText b]
      case terminal of
        Just [storedEvent, storedType, storedPayload] -> do
          json <- either refuse pure (loadsColumn storedPayload)
          if json == row.value
            then pure False
            else
              refuse
                ( "occurrence "
                    <> pythonStr row.occurrence
                    <> " of "
                    <> instanceId
                    <> " already holds its terminal fact ("
                    <> pythonStr storedType
                    <> ", event "
                    <> pythonStr storedEvent
                    <> "); refusing different "
                    <> row.recordType
                    <> " (event "
                    <> eventId
                    <> ")"
                )
        _ -> throwIO (UnverifiableConflict ("insert of event " <> eventId <> " conflicted but no stored row explains it"))
