{-# LANGUAGE OverloadedRecordDot #-}

-- | A small, locked SQLite connection with the semantics of CPython's
-- @sqlite3@ module as Hamsterdan uses it: a five-second busy timeout,
-- scripts, parameterized statements, and @with connection:@ transactions
-- that commit on success and roll back on any exception. Binding a text
-- CPython cannot encode as UTF-8 raises its @UnicodeEncodeError@, and a text
-- or blob past @INT_MAX@ bytes its @OverflowError@, before the statement
-- runs, as CPython's @sqlite3@ does, and every SQLite failure
-- raises the 'PythonException' of the @sqlite3@ class CPython raises for
-- its result code (petrus-sqlite's 'pythonSqliteClass'), with SQLite's
-- message, so a stored or printed class name is the reference's.
module Hamsterdan.Sqlite
  ( Connection
  , SQLData (..)
  , open
  , close
  , script
  , query
  , execute
  , transaction
  , withLock
  , isDatabaseError
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (SomeException, catch, finally, fromException, mask, onException, throwIO, try)
import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Foreign (lengthWord8)
import Database.SQLite3 (Database, SQLData (..), Statement, StepResult (..))
import Database.SQLite3 qualified as S
import Hamsterdan.Python.Text (utf8Encode)
import Petrus.Json.Python (PythonException (..), pythonError)
import Petrus.Sqlite.Connection (SQLError (..), bindLength, pythonSqliteClass)

-- | A connection guarded by a lock (CPython's @threading.RLock@ around the
-- shared connection).
data Connection = Connection
  { database :: Database
  , lock :: MVar ()
  , closed :: IORef Bool
  , statements :: IORef (Map Text Statement)
  -- ^ Prepared statements by SQL text, reused as Python's @sqlite3@
  -- statement cache reuses them.
  }

-- | @sqlite3.connect(path)@.
open :: Text -> IO Connection
open path = translated $ do
  database <- S.open path
  -- CPython's default @timeout=5.0@.
  S.exec database "PRAGMA busy_timeout=5000"
  Connection database <$> newMVar () <*> newIORef False <*> newIORef Map.empty

-- | @connection.close()@; closing twice is harmless.
close :: Connection -> IO ()
close connection = withLock connection $ do
  done <- readIORef connection.closed
  if done
    then pure ()
    else do
      writeIORef connection.closed True
      cached <- readIORef connection.statements
      writeIORef connection.statements Map.empty
      translated $ do
        mapM_ S.finalize (Map.elems cached)
        S.close connection.database

-- | Hold the connection's lock.
withLock :: Connection -> IO a -> IO a
withLock connection action = withMVar connection.lock (const action)

-- | @executescript@: several statements, outside any transaction.
script :: Connection -> Text -> IO ()
script connection = translated . S.exec connection.database

-- | Run one statement and return its rows.
query :: Connection -> Text -> [SQLData] -> IO [[SQLData]]
query connection sql parameters = translated . withStatement connection sql $ \statement -> do
  let collect acc =
        S.step statement >>= \case
          Done -> pure (reverse acc)
          Row -> do
            row <- S.columns statement
            collect (row : acc)
  bindChecked statement parameters >> collect []

-- | Run one statement and return the number of rows it changed.
execute :: Connection -> Text -> [SQLData] -> IO Int
execute connection sql parameters = translated . withStatement connection sql $ \statement -> do
  bindChecked statement parameters
  void (S.step statement)
  S.changes connection.database

-- | Bind the parameters, refusing first, parameter by parameter, as
-- CPython's @sqlite3@ does: a text it cannot encode as UTF-8 (a surrogate a
-- JSON reader kept from an escape), and a text or a blob longer than
-- @INT_MAX@ bytes (petrus-sqlite's 'bindLength', the @OverflowError@ CPython
-- raises where SQLite's @int@ length would wrap). Both checks of a
-- parameter are one pure 'Either' (encoding first, then length, CPython's
-- order), raised once; petrus-sqlite's 'Petrus.Sqlite.Connection.checkBindLength'
-- is the length check alone, for its own bind loop in 'IO'.
bindChecked :: Statement -> [SQLData] -> IO ()
bindChecked statement parameters = do
  mapM_ (either throwIO pure . refusal) parameters
  S.bind statement parameters
  where
    refusal = \case
      SQLText value -> utf8Encode value >> void (bindLength "string" (lengthWord8 value))
      SQLBlob bytes -> void (bindLength "BLOB" (BS.length bytes))
      _ -> Right ()

-- | Run with a cached prepared statement for this SQL (preparing it on
-- first use). The statement is checked out of the cache while in use, so
-- concurrent callers never share one, and goes back reset and unbound.
withStatement :: Connection -> Text -> (Statement -> IO a) -> IO a
withStatement connection sql use = mask $ \restore -> do
  cached <- atomicModifyIORef' connection.statements (\m -> (Map.delete sql m, Map.lookup sql m))
  statement <- maybe (S.prepare connection.database sql) pure cached
  restore (use statement) `finally` checkIn statement
  where
    checkIn statement = do
      -- @reset@ reports the last step's error again; @step@ already raised it.
      _ <- try @SomeException (S.reset statement)
      _ <- try @SomeException (S.clearBindings statement)
      closed <- readIORef connection.closed
      displaced <-
        if closed
          then pure (Just statement)
          else atomicModifyIORef' connection.statements $ \m ->
            if Map.member sql m then (m, Just statement) else (Map.insert sql statement m, Nothing)
      mapM_ (try @SomeException . S.finalize) displaced

-- | @with connection:@: begin, run, commit; roll back if the action throws.
transaction :: Connection -> IO a -> IO a
transaction connection action = mask $ \restore -> do
  translated (S.exec connection.database "BEGIN")
  result <- restore action `onException` rollback
  translated (S.exec connection.database "COMMIT")
  pure result
  where
    rollback = do
      outcome <- try (S.exec connection.database "ROLLBACK")
      case outcome of
        Left (_ :: SomeException) -> pure ()
        Right () -> pure ()

-- | Raise a driver failure as the @sqlite3@ exception CPython raises for
-- it: @_pysqlite_seterror@'s class for the result code, with
-- @sqlite3_errmsg@ as its one argument.
translated :: IO a -> IO a
translated action =
  action `catch` \(failure :: SQLError) ->
    throwIO (pythonError (pythonSqliteClass failure.sqlError) failure.sqlErrorDetails)

-- | @except sqlite3.DatabaseError@: an exception of that class or one of
-- its subclasses (@InterfaceError@ and @MemoryError@ are not).
isDatabaseError :: SomeException -> Bool
isDatabaseError e = case fromException e of
  Just (PythonException name _) -> name `elem` databaseErrors
  Nothing -> False
  where
    databaseErrors = ["DatabaseError", "OperationalError", "IntegrityError", "DataError", "InternalError", "ProgrammingError", "NotSupportedError"] :: [Text]
