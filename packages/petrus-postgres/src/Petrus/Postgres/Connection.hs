-- | PostgreSQL connections with the psycopg 3 behavior upstream relies on.
--
-- = Two transaction modes
--
-- A connection opened with @autocommit = False@ is in /join mode/: the
-- first statement after the connection is idle opens a transaction
-- (@BEGIN ISOLATION LEVEL READ COMMITTED@ by default), later statements
-- join it, and the owner ends it with 'commit' or 'rollback' — how
-- upstream's Engine and Absurd Dispatch make a history append and a task
-- spawn commit or vanish together. A connection opened with
-- @autocommit = True@ runs each statement on its own, and 'withTransaction'
-- then /owns/ one transaction per batch (psycopg's
-- @connection.transaction()@). 'withTransaction' is upstream's
-- @_transaction()@ helper: own when autocommit, join otherwise.
--
-- = Statements
--
-- Statements are written with psycopg's @%s@ placeholders (see
-- "Petrus.Postgres.Param"). As in psycopg, a statement with parameters
-- uses the extended protocol (one statement), and a statement without
-- parameters uses the simple protocol, is sent exactly as written and may
-- hold several statements. Rows come back in PostgreSQL's text format;
-- "Petrus.Postgres.Value" decodes them.
--
-- Waiting for the server is interruptible: an asynchronous exception
-- (a timeout, a killed thread) cancels the running statement on the server
-- and leaves the connection usable.
module Petrus.Postgres.Connection
  ( -- * Connecting
    Connection
  , ConnectOptions (..)
  , defaultConnectOptions
  , Isolation (..)
  , connect
  , connectWith
  , close
  , withConnection
  , isClosed
  , isBroken
  , backendPid

    -- * Transaction state
  , TransactionStatus (..)
  , transactionStatus
  , autocommit
  , setAutocommit
  , commit
  , rollback
  , TransactionMode (..)
  , transactionMode
  , withTransaction

    -- * Statements
  , Result (..)
  , execute
  , execute_
  , executeResults
  , query
  , queryFirst

    -- * Errors
  , PostgresError (..)
  , ErrorClass (..)
  , errorClassForState
  , hasSqlState
  , lockNotAvailable
  , undefinedTable
  , uniqueViolation
  , serializationFailure
  , queryCanceled
  ) where

import Control.Concurrent.MVar (newMVar)
import Control.Exception (bracket, mask, onException, throwIO, try)
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import Data.IORef (atomicWriteIORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Database.PostgreSQL.LibPQ qualified as PQ
import Petrus.Postgres.Internal
import Petrus.Postgres.Param (Param, Sql)

-- | How to open a connection.
data ConnectOptions = ConnectOptions
  { autocommitMode :: Bool
  -- ^ psycopg's @autocommit@ argument.
  , isolationLevel :: Isolation
  -- ^ The level transactions start with ('ReadCommitted' by default).
  }
  deriving stock (Eq, Show)

-- | Join mode (@autocommit=False@), READ COMMITTED.
defaultConnectOptions :: ConnectOptions
defaultConnectOptions = ConnectOptions {autocommitMode = False, isolationLevel = ReadCommitted}

-- | @psycopg.connect(dsn, autocommit=...)@ with READ COMMITTED
-- transactions. The DSN is a libpq connection string (URI or
-- @key=value@).
connect :: ByteString -> Bool -> IO Connection
connect dsn mode = connectWith defaultConnectOptions {autocommitMode = mode} dsn

-- | Open a connection. Fails with an 'OperationalError' when the server
-- cannot be reached. The client encoding is set to UTF-8 when the server
-- chose another, and server notices are discarded (psycopg drops them when
-- no notice handler is installed).
connectWith :: ConnectOptions -> ByteString -> IO Connection
connectWith options dsn = do
  raw <- PQ.connectdb dsn
  status <- PQ.status raw
  unless (status == PQ.ConnectionOk) $ do
    failure <- connectionFailure raw "connection failed: "
    PQ.finish raw
    throwIO failure
  PQ.disableNoticeReporting raw
  encoding <- PQ.clientEncoding raw
  unless (encoding == "UTF8") $ do
    switched <- PQ.setClientEncoding raw "UTF8"
    unless switched $ do
      failure <- connectionFailure raw "cannot set client encoding to UTF8: "
      PQ.finish raw
      throwIO failure
  lock <- newMVar ()
  autocommitVar <- newIORef (autocommitMode options)
  closed <- newIORef False
  pure
    Connection
      { rawConnection = raw
      , connectionLock = lock
      , autocommitRef = autocommitVar
      , closedRef = closed
      , connectionIsolation = isolationLevel options
      }

-- | Close the connection (idempotent). An open transaction is discarded by
-- the server; session advisory locks are released.
close :: Connection -> IO ()
close connection = mask $ \_ -> do
  wasClosed <- readIORef (closedRef connection)
  unless wasClosed $ do
    atomicWriteIORef (closedRef connection) True
    PQ.finish (rawConnection connection)

-- | 'connect', run, 'close'.
withConnection :: ByteString -> Bool -> (Connection -> IO a) -> IO a
withConnection dsn mode = bracket (connect dsn mode) close

-- | psycopg's @connection.closed@.
isClosed :: Connection -> IO Bool
isClosed = readIORef . closedRef

-- | psycopg's @connection.broken@: the connection was lost without being
-- closed.
isBroken :: Connection -> IO Bool
isBroken connection = do
  closed <- readIORef (closedRef connection)
  if closed
    then pure False
    else (== PQ.ConnectionBad) <$> PQ.status (rawConnection connection)

-- | The server process ID (@connection.info.backend_pid@), the PID a
-- notification sent from this connection carries.
backendPid :: Connection -> IO Int
backendPid connection = withLockedConnection connection (fmap fromIntegral . PQ.backendPID)

-- | psycopg's @TransactionStatus@.
data TransactionStatus
  = -- | @IDLE@: no transaction open.
    Idle
  | -- | @ACTIVE@: a statement is running.
    Active
  | -- | @INTRANS@: inside a transaction block.
    InTransaction
  | -- | @INERROR@: inside a failed transaction block.
    InError
  | -- | @UNKNOWN@: the connection is bad.
    Unknown
  deriving stock (Eq, Show)

-- | @connection.info.transaction_status@.
transactionStatus :: Connection -> IO TransactionStatus
transactionStatus connection =
  readIORef (closedRef connection) >>= \case
    True -> pure Unknown
    False ->
      PQ.transactionStatus (rawConnection connection) >>= \case
        PQ.TransIdle -> pure Idle
        PQ.TransActive -> pure Active
        PQ.TransInTrans -> pure InTransaction
        PQ.TransInError -> pure InError
        PQ.TransUnknown -> pure Unknown

-- | @connection.autocommit@.
autocommit :: Connection -> IO Bool
autocommit = readIORef . autocommitRef

-- | Set @connection.autocommit@; refused, as psycopg refuses it, while a
-- transaction is open.
setAutocommit :: Connection -> Bool -> IO ()
setAutocommit connection mode = withLockedConnection connection $ \raw -> do
  status <- PQ.transactionStatus raw
  unless (status == PQ.TransIdle) $
    throwIO
      ( clientError
          ProgrammingError
          ("can't change 'autocommit' now: connection in transaction status " <> statusName status)
      )
  writeIORef (autocommitRef connection) mode
  where
    statusName = \case
      PQ.TransIdle -> "IDLE"
      PQ.TransActive -> "ACTIVE"
      PQ.TransInTrans -> "INTRANS"
      PQ.TransInError -> "INERROR"
      PQ.TransUnknown -> "UNKNOWN"

-- | @connection.commit()@: @COMMIT@ when a transaction is open, nothing
-- otherwise.
commit :: Connection -> IO ()
commit connection = endTransaction connection "COMMIT"

-- | @connection.rollback()@: @ROLLBACK@ when a transaction is open,
-- nothing otherwise.
rollback :: Connection -> IO ()
rollback connection = endTransaction connection "ROLLBACK"

endTransaction :: Connection -> ByteString -> IO ()
endTransaction connection command = withLockedConnection connection $ \raw -> do
  status <- PQ.transactionStatus raw
  unless (status == PQ.TransIdle) (runCommand raw command)

-- | Who ends the transaction a batch runs in.
data TransactionMode
  = -- | Autocommit connection: the batch owns its transaction.
    Owned
  | -- | Join-mode connection: the batch joins the caller's transaction and
    -- the caller commits.
    Joined
  deriving stock (Eq, Show)

-- | The mode 'withTransaction' uses on this connection.
transactionMode :: Connection -> IO TransactionMode
transactionMode connection = do
  mode <- autocommit connection
  pure (if mode then Owned else Joined)

-- | Upstream's @_transaction()@: on an autocommit connection, run the
-- action in one owned transaction (@BEGIN@ at the connection's isolation
-- level, @COMMIT@ on success, @ROLLBACK@ when the action throws, the
-- action's exception rethrown) — psycopg's @connection.transaction()@; on a
-- join-mode connection, just run the action inside the caller's
-- transaction. An autocommit connection that already has a transaction
-- open (a manual @BEGIN@) joins it too.
withTransaction :: Connection -> IO a -> IO a
withTransaction connection action = do
  mode <- autocommit connection
  if not mode
    then action
    else mask $ \restore -> do
      owned <- withLockedConnection connection $ \raw -> do
        status <- PQ.transactionStatus raw
        if status == PQ.TransIdle
          then True <$ runCommand raw (beginStatement (connectionIsolation connection))
          else pure False
      if not owned
        then restore action
        else do
          value <- restore action `onException` quietRollback
          withLockedConnection connection (\raw -> runCommand raw "COMMIT")
          pure value
  where
    quietRollback = void (try @PostgresError (endTransaction connection "ROLLBACK"))

-- | @connection.execute(sql, params).rowcount@.
execute :: Connection -> Sql -> [Param] -> IO Int
execute connection statement params = resultRowCount <$> executeResult connection statement params

-- | Run a statement, ignoring its result.
execute_ :: Connection -> Sql -> [Param] -> IO ()
execute_ connection statement params = void (executeResult connection statement params)

-- | Run a statement and return every result (several when a parameterless
-- statement holds several SQL statements; psycopg's @nextset()@).
executeResults :: Connection -> Sql -> [Param] -> IO [Result]
executeResults connection statement params =
  withLockedConnection connection $ \raw -> runStatement connection raw statement params

executeResult :: Connection -> Sql -> [Param] -> IO Result
executeResult connection statement params =
  executeResults connection statement params >>= \case
    first : _ -> pure first
    [] -> pure (Result [] [] (-1) "")

-- | @connection.execute(sql, params).fetchall()@.
query :: Connection -> Sql -> [Param] -> IO [[Maybe ByteString]]
query connection statement params = resultRows <$> executeResult connection statement params

-- | @connection.execute(sql, params).fetchone()@.
queryFirst :: Connection -> Sql -> [Param] -> IO (Maybe [Maybe ByteString])
queryFirst connection statement params =
  query connection statement params >>= \case
    row : _ -> pure (Just row)
    [] -> pure Nothing

-- | Whether the error carries the given SQLSTATE (psycopg's
-- @except psycopg.errors.LockNotAvailable@ is
-- @hasSqlState lockNotAvailable@).
hasSqlState :: Text -> PostgresError -> Bool
hasSqlState state failure = errorSqlState failure == Just state

-- | @55P03@, @psycopg.errors.LockNotAvailable@.
lockNotAvailable :: Text
lockNotAvailable = "55P03"

-- | @42P01@, @psycopg.errors.UndefinedTable@.
undefinedTable :: Text
undefinedTable = "42P01"

-- | @23505@, @psycopg.errors.UniqueViolation@.
uniqueViolation :: Text
uniqueViolation = "23505"

-- | @40001@, @psycopg.errors.SerializationFailure@.
serializationFailure :: Text
serializationFailure = "40001"

-- | @57014@, @psycopg.errors.QueryCanceled@.
queryCanceled :: Text
queryCanceled = "57014"
