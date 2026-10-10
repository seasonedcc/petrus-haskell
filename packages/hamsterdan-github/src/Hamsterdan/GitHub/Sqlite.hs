{-# LANGUAGE OverloadedRecordDot #-}

-- | A small, locked SQLite connection with the semantics of CPython's
-- @sqlite3@ module as Hamsterdan uses it: a five-second busy timeout,
-- scripts, parameterized statements, and @with connection:@ transactions
-- that commit on success and roll back on any exception.
module Hamsterdan.GitHub.Sqlite
  ( Connection
  , SQLData (..)
  , open
  , close
  , script
  , query
  , execute
  , transaction
  , withLock
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (SomeException, finally, mask, onException, try)
import Control.Monad (void)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Database.SQLite3 (Database, SQLData (..), StepResult (..))
import Database.SQLite3 qualified as S

-- | A connection guarded by a lock (CPython's @threading.RLock@ around the
-- shared connection).
data Connection = Connection
  { database :: Database
  , lock :: MVar ()
  , closed :: IORef Bool
  }

-- | @sqlite3.connect(path)@.
open :: Text -> IO Connection
open path = do
  database <- S.open path
  -- CPython's default @timeout=5.0@.
  S.exec database "PRAGMA busy_timeout=5000"
  Connection database <$> newMVar () <*> newIORef False

-- | @connection.close()@; closing twice is harmless.
close :: Connection -> IO ()
close connection = withLock connection $ do
  done <- readIORef connection.closed
  if done
    then pure ()
    else do
      writeIORef connection.closed True
      S.close connection.database

-- | Hold the connection's lock.
withLock :: Connection -> IO a -> IO a
withLock connection action = withMVar connection.lock (const action)

-- | @executescript@: several statements, outside any transaction.
script :: Connection -> Text -> IO ()
script connection = S.exec connection.database

-- | Run one statement and return its rows.
query :: Connection -> Text -> [SQLData] -> IO [[SQLData]]
query connection sql parameters = do
  statement <- S.prepare connection.database sql
  let collect acc =
        S.step statement >>= \case
          Done -> pure (reverse acc)
          Row -> do
            row <- S.columns statement
            collect (row : acc)
  (S.bind statement parameters >> collect []) `finally` S.finalize statement

-- | Run one statement and return the number of rows it changed.
execute :: Connection -> Text -> [SQLData] -> IO Int
execute connection sql parameters = do
  statement <- S.prepare connection.database sql
  let run = do
        S.bind statement parameters
        void (S.step statement)
        S.changes connection.database
  run `finally` S.finalize statement

-- | @with connection:@: begin, run, commit; roll back if the action throws.
transaction :: Connection -> IO a -> IO a
transaction connection action = mask $ \restore -> do
  S.exec connection.database "BEGIN"
  result <- restore action `onException` rollback
  S.exec connection.database "COMMIT"
  pure result
  where
    rollback = do
      outcome <- try (S.exec connection.database "ROLLBACK")
      case outcome of
        Left (_ :: SomeException) -> pure ()
        Right () -> pure ()
