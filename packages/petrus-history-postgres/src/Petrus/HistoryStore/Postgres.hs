-- | The event History persisted in PostgreSQL (the reference's
-- @petrus.impetus.history_store.postgres@): the @impetus.semantic_events@
-- table, one net instance's history per @net_instance_id@, many instances
-- side by side in the one table.
--
-- = Schema
--
-- 'ensureSchema' provisions the table and its three indexes with the
-- reference's DDL, statement for statement and byte for byte
-- ('schemaStatements'): idempotent @IF NOT EXISTS@ DDL, no version table, no
-- shape checks. Opening a store never provisions anything; over a database
-- without the table it refuses, naming @ensure_schema@.
--
-- = Two transaction modes
--
-- The store writes through the caller's 'Connection' and follows its mode
-- ("Petrus.Postgres.Connection"):
--
-- * __Autocommit__ ('BackendOwned'): each batch runs in one transaction the
--   store owns — whole or not at all.
-- * __Join mode__ ('JoinedTransaction', @autocommit=False@): each batch
--   joins the caller's open transaction and the caller commits. Rows are
--   invisible to other sessions until then, and the in-memory mirror
--   follows the transaction's view. A rollback — or a refused append, which
--   leaves the batch's earlier inserts in the transaction: roll back, never
--   commit around it — retracts facts that live state already advanced on,
--   so the caller discards the store /and/ every Instance or Engine built
--   over it, and resumes from a fresh load. The Engine providers
--   (@petrus-engine-postgres@) enforce exactly that.
--
-- = Writes
--
-- The whole batch is encoded before the connection sees anything: a
-- non-finite number (or an integer CPython would not print) refuses the
-- batch with the reference's @cannot durably encode …@ text. Each record is
-- then inserted at event identity @"{instance}:{position}"@ — @position@
-- the durable position it fills, starting at the mirror's length — with a
-- target-less @ON CONFLICT DO NOTHING@. A conflicting insert re-reads the
-- stored row and compares payloads with Python value equality:
--
-- * equal at the same event identity: the record fills its position;
-- * equal at another position (the one-terminal partial indexes): it is
--   acknowledged there, enters neither the mirror nor the position
--   sequence;
-- * different: refused ('HistoryStoreError'), naming the event;
-- * no row explains the conflict: 'UnverifiableConflict'.
--
-- The re-reads rely on READ COMMITTED, which "Petrus.Postgres.Connection"
-- opens every transaction with.
--
-- = Reads
--
-- The instance's rows load once, in @sequence@ order; @payload@ is read in
-- PostgreSQL's text form and parsed with CPython @json.loads@ semantics, so
-- @jsonb@'s normalization (member order, @1e16@ read back as an integer)
-- reaches the codec exactly as psycopg hands it to the reference.
module Petrus.HistoryStore.Postgres
  ( -- * The schema
    ensureSchema
  , schemaStatements

    -- * The store
  , openPostgresHistoryStore
  , openPostgresHistoryStoreWith
  , PostgresHistoryOptions (..)
  , defaultPostgresHistoryOptions
  , loadPostgresHistory

    -- * Statements
  , loadStatement
  , insertStatement
  , identityStatement
  , terminalStatement

    -- * The format
  , eventId
  , encodePayload

    -- * Errors
  , HistoryStoreError (..)
  , UnverifiableConflict (..)
  ) where

import Control.Exception (throwIO, try)
import Control.Monad (forM, forM_, when)
import Data.ByteString (ByteString)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.HistoryStore (HistoryStoreError (..))
import Petrus.Impetus.History.Codec (decodeRecord, encodeRecord)
import Petrus.Impetus.History.Records (Record, recordName, recordOccurrence, recordTerminalFamily, terminalFamilyNames)
import Petrus.Impetus.HistoryStore
  ( Admission (..)
  , CommitMode (..)
  , HistoryStore (..)
  , UnverifiableConflict (..)
  , mirroredHistoryStore
  )
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumps, encodeErrorMessage, parseJson, surrogateRefusingLoads)
import Petrus.Json.Repr (pythonReprText)
import Petrus.Postgres
  ( Connection
  , Param (..)
  , ParamFormat (..)
  , PostgresError
  , Sql
  , TransactionMode (..)
  , execute
  , execute_
  , hasSqlState
  , intParam
  , nullParam
  , oidUnknown
  , query
  , queryFirst
  , textArrayParam
  , textParam
  , transactionMode
  , undefinedTable
  , sql
  , withTransaction
  )
import Petrus.Telemetry (EventSink, emit, getLogger)
import Petrus.Telemetry qualified as Telemetry

-- ---------------------------------------------------------------------------
-- Errors

-- | An insert conflicted and no stored row explains it (the reference's
-- @RuntimeError@): the conflict cannot be verified, so it is never
-- acknowledged.

-- ---------------------------------------------------------------------------
-- The schema

-- | The reference's @_DDL@, exactly: one statement per element, each sent
-- as written (the simple protocol, as psycopg sends a parameterless
-- statement).
schemaStatements :: [Text]
schemaStatements =
  [ "CREATE SCHEMA IF NOT EXISTS impetus"
  , "\n    CREATE TABLE IF NOT EXISTS impetus.semantic_events (\n        sequence bigserial PRIMARY KEY,\n        event_id text UNIQUE NOT NULL,\n        net_instance_id text NOT NULL,\n        record_type text NOT NULL,\n        occurrence bigint,\n        payload jsonb NOT NULL,\n        recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()\n    )\n    "
  , "\n    CREATE INDEX IF NOT EXISTS semantic_events_by_instance\n        ON impetus.semantic_events (net_instance_id, sequence)\n    "
  , "\n    CREATE UNIQUE INDEX IF NOT EXISTS semantic_events_one_terminal_per_firing_occurrence\n        ON impetus.semantic_events (net_instance_id, occurrence)\n        WHERE record_type IN ('FiringCompleted', 'FiringFailed')\n    "
  , "\n    CREATE UNIQUE INDEX IF NOT EXISTS semantic_events_one_terminal_activity_fact\n        ON impetus.semantic_events (net_instance_id, occurrence)\n        WHERE record_type IN ('ActivityCompleted', 'ActivityFailed')\n    "
  ]

-- | @ensure_schema(connection)@: provision the schema, idempotently. On an
-- autocommit connection each statement applies at once; in join mode the
-- DDL joins the caller's transaction (PostgreSQL DDL is transactional) and
-- the caller commits.
ensureSchema :: Connection -> IO ()
ensureSchema connection = forM_ ddl $ \statement -> execute_ connection statement []

ddl :: [Sql]
ddl = map sql schemaStatements

-- ---------------------------------------------------------------------------
-- Statements

-- | The load.
loadStatement :: Sql
loadStatement = "SELECT event_id, payload FROM impetus.semantic_events WHERE net_instance_id = %s ORDER BY sequence"

-- | The insert (a target-less upsert that absorbs a conflict on any unique
-- index without aborting the transaction).
insertStatement :: Sql
insertStatement =
  "INSERT INTO impetus.semantic_events (event_id, net_instance_id, record_type, occurrence, payload) VALUES (%s, %s, %s, %s, %s::jsonb) ON CONFLICT DO NOTHING"

-- | The verify-by-identity re-read.
identityStatement :: Sql
identityStatement = "SELECT record_type, payload FROM impetus.semantic_events WHERE event_id = %s"

-- | The verify-by-terminal re-read.
terminalStatement :: Sql
terminalStatement =
  "SELECT event_id, record_type, payload FROM impetus.semantic_events WHERE net_instance_id = %s AND occurrence = %s AND record_type = ANY(%s)"

-- ---------------------------------------------------------------------------
-- The format

-- | The writer-derived event identity, @f"{instance}:{position}"@.
eventId :: Text -> Int -> Text
eventId instanceId position = instanceId <> ":" <> T.pack (show position)

-- | @json.dumps(encode_record(record), allow_nan=False)@ (the payload
-- parameter, cast @::jsonb@ by the server), or the reference's refusal.
encodePayload :: Record -> Either Text ByteString
encodePayload record = case dumps defaultDumps {allowNan = False} (encodeRecord record) of
  Right bytes -> Right bytes
  Left problem ->
    Left
      ( "cannot durably encode "
          <> recordName record
          <> ": "
          <> T.pack (encodeErrorMessage problem)
          <> " — durable instants, token data, and activity input/result must be JSON-faithful values"
      )

-- | One encoded event of a batch.
data Encoded = Encoded
  { record :: Record
  , recordType :: Text
  , occurrence :: Maybe Int
  , payload :: ByteString
  }

encodeEvent :: Record -> Either Text Encoded
encodeEvent r = do
  bytes <- encodePayload r
  Right Encoded {record = r, recordType = recordName r, occurrence = recordOccurrence r, payload = bytes}

-- ---------------------------------------------------------------------------
-- Options

-- | Store options.
newtype PostgresHistoryOptions = PostgresHistoryOptions
  { telemetry :: Maybe EventSink
  -- ^ Where the @postgres_commit@ events go ('Nothing': the routed default).
  }

-- | The reference's posture.
defaultPostgresHistoryOptions :: PostgresHistoryOptions
defaultPostgresHistoryOptions = PostgresHistoryOptions {telemetry = Nothing}

-- ---------------------------------------------------------------------------
-- Loading

-- | Load one instance's records in @sequence@ order (inside the caller's
-- transaction in join mode). Refuses without the schema, naming
-- @ensure_schema@, and on a row that does not decode, naming its event.
loadPostgresHistory :: Connection -> Text -> IO (Seq Record)
loadPostgresHistory connection instanceId = do
  rows <-
    try (query connection loadStatement [textParam instanceId]) >>= \case
      Right rows -> pure rows
      Left (failure :: PostgresError)
        | hasSqlState undefinedTable failure ->
            throwIO
              ( HistoryStoreError
                  "impetus.semantic_events does not exist on this connection's database: provision it with petrus.impetus.history_store.postgres.ensure_schema(connection) — a deliberate act, never implied by construction"
              )
        | otherwise -> throwIO failure
  decoded <- forM rows $ \case
    [Just event, Just bytes] -> either (throwIO . HistoryStoreError . undecodable event) pure (decodeRow bytes)
    other -> throwIO (HistoryStoreError ("unexpected semantic_events row shape: " <> T.pack (show other)))
  pure (Seq.fromList decoded)
  where
    undecodable event problem =
      "event " <> TE.decodeUtf8Lenient event <> " does not decode as an event history record: " <> problem
    decodeRow bytes = either (Left . T.pack) Right (parseJson surrogateRefusingLoads bytes) >>= decodeRecord

-- ---------------------------------------------------------------------------
-- The store

-- | @PostgresHistoryStore(connection, instance)@: load the instance's
-- records and write every batch through the connection — an owned
-- transaction per batch on an autocommit connection, the caller's
-- transaction in join mode.
openPostgresHistoryStore :: Connection -> Text -> IO HistoryStore
openPostgresHistoryStore = openPostgresHistoryStoreWith defaultPostgresHistoryOptions

-- | 'openPostgresHistoryStore' with options.
openPostgresHistoryStoreWith :: PostgresHistoryOptions -> Connection -> Text -> IO HistoryStore
openPostgresHistoryStoreWith options connection instanceId = do
  Telemetry.validateTelemetryEnvironment
  when (T.null instanceId) $
    throwIO
      ( HistoryStoreError
          ("PostgresHistoryStore requires a non-empty string instance id, got " <> T.pack (pythonReprText instanceId))
      )
  loaded <- loadPostgresHistory connection instanceId
  commitMode <-
    transactionMode connection >>= \case
      Owned -> pure BackendOwned
      Joined -> pure JoinedTransaction
  let logger = getLogger "impetus" options.telemetry
  mirroredHistoryStore commitMode loaded $ \position batch -> do
    started <- Telemetry.monotonicClock
    encoded <- either (throwIO . HistoryStoreError) pure (traverse encodeEvent batch)
    admissions <- withTransaction connection (insertBatch connection instanceId position encoded)
    elapsed <- Telemetry.elapsedMs Telemetry.monotonicClock started
    emit
      logger
      "postgres_commit"
      [ ("records", Int (fromIntegral (length batch)))
      , ("entered", Int (fromIntegral (length (filter (== Entered) admissions))))
      , ("elapsed_ms", Int elapsed)
      ]
    pure admissions

-- | Insert the batch from the given position: the running position
-- advances only when a row lands or the value-equal row already sits at
-- it, so an acknowledged-elsewhere terminal consumes neither a position nor
-- a mirror slot.
insertBatch :: Connection -> Text -> Int -> [Encoded] -> IO [Admission]
insertBatch connection instanceId = go []
  where
    go acc _ [] = pure (reverse acc)
    go acc position (event : rest) = do
      let identity = eventId instanceId position
      inserted <-
        execute
          connection
          insertStatement
          [ textParam identity
          , textParam instanceId
          , textParam event.recordType
          , maybe nullParam (intParam . fromIntegral) event.occurrence
          , Param oidUnknown (Just event.payload) TextFormat
          ]
      admission <-
        if inserted /= 0
          then pure Entered
          else verifyConflict connection instanceId identity event
      case admission of
        Entered -> go (Entered : acc) (position + 1) rest
        AcknowledgedElsewhere -> go (AcknowledgedElsewhere : acc) position rest

-- | The verify-on-conflict acceptance: the event identity first (a retry or
-- a lockstep twin), then the terminal fact the record's family permits once
-- per occurrence.
verifyConflict :: Connection -> Text -> Text -> Encoded -> IO Admission
verifyConflict connection instanceId identity event = do
  let appending = encodeRecord event.record
  stored <- queryFirst connection identityStatement [textParam identity]
  case stored of
    Just [Just storedType, Just storedPayload] -> do
      value <- storedJson storedPayload
      if value == appending
        then pure Entered
        else
          throwIO
            ( HistoryStoreError
                ( "event "
                    <> identity
                    <> " is already recorded as a different fact: refusing to overwrite an appended fact (stored "
                    <> TE.decodeUtf8Lenient storedType
                    <> ", appending "
                    <> event.recordType
                    <> ")"
                )
            )
    _ -> do
      terminal <- case terminalFamilyNames <$> recordTerminalFamily event.record of
        Nothing -> pure Nothing
        Just (completed, failed) ->
          queryFirst
            connection
            terminalStatement
            [textParam instanceId, maybe nullParam (intParam . fromIntegral) event.occurrence, textArrayParam [completed, failed]]
      case terminal of
        Just [Just storedEvent, Just storedType, Just storedPayload] -> do
          value <- storedJson storedPayload
          if value == appending
            then pure AcknowledgedElsewhere
            else
              throwIO
                ( HistoryStoreError
                    ( "occurrence "
                        <> maybe "None" (T.pack . show) event.occurrence
                        <> " of "
                        <> instanceId
                        <> " already holds its terminal fact ("
                        <> TE.decodeUtf8Lenient storedType
                        <> ", event "
                        <> TE.decodeUtf8Lenient storedEvent
                        <> "): refusing a different "
                        <> event.recordType
                        <> " (event "
                        <> identity
                        <> ") — an operational conflict, not a redelivery"
                    )
                )
        _ ->
          throwIO
            ( UnverifiableConflict
                ( "insert of event "
                    <> identity
                    <> " ("
                    <> event.recordType
                    <> ") conflicted, but no stored row explains it: cannot verify the conflict, refusing to acknowledge"
                )
            )
  where
    storedJson bytes = either (throwIO . HistoryStoreError . T.pack) pure (parseJson surrogateRefusingLoads bytes)
