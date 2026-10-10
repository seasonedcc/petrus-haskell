-- | Durable, reconstructible wake hints for PR workflow Instances
-- (@host/runnable.py@).
--
-- One SQLite file (@runnable.sqlite3@) with the reference's exact DDL; a
-- damaged or incompatible file is quarantined to @runnable.sqlite3.corrupt@
-- and rebuilt empty, because the index is never canonical state.
module Hamsterdan.Host.Runnable
  ( RunnableIndex
  , openRunnableIndex
  , openRunnableIndexWith
  , wake
  , replaceTimer
  , cancelTimer
  , takeDue
  , takeDueAt
  , count
  , nextDue
  , close
  ) where

import Control.Exception (SomeException, mask, onException, throwIO, try)
import Control.Monad (unless, void, when)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Hamsterdan.GitHub.Python (utf8Length)
import Hamsterdan.GitHub.Sqlite (Connection, SQLData (..))
import Hamsterdan.GitHub.Sqlite qualified as Sql
import Petrus.Motus.Worker (RuntimeError (..), ValueError (..))
import System.Directory (removePathForcibly, renameFile)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)
import System.Posix.Directory qualified as PosixDir
import System.Posix.Files qualified as Posix

data RunnableIndex = RunnableIndex
  { connection :: Connection
  , clock :: IO Double
  }

identifier :: Text -> Int -> Text -> IO Text
identifier value maximum' label = do
  when (T.null value || utf8Length value > maximum') $
    throwIO (ValueError (label <> " must be a non-empty bounded identifier"))
  pure value

instant :: Double -> IO Double
instant value = do
  when (isNaN value || isInfinite value) $ throwIO (ValueError "due_at must be finite")
  pure value

-- | @RunnableIndex(path)@ with the wall clock.
openRunnableIndex :: FilePath -> IO RunnableIndex
openRunnableIndex path = openRunnableIndexWith path (realToFrac <$> getPOSIXTime)

-- | @RunnableIndex(path, clock=clock)@.
openRunnableIndexWith :: FilePath -> IO Double -> IO RunnableIndex
openRunnableIndexWith path clock = do
  createParents (takeDirectory path)
  exists <- doesFileExist path
  connection <-
    if exists
      then do
        candidate <- try @SomeException $ do
          db <- Sql.open (T.pack path)
          (validate db >> pure db) `onException` Sql.close db
        case candidate of
          Right db -> pure db
          Left _ -> do
            replaceDisposable path
            Sql.open (T.pack path)
      else Sql.open (T.pack path)
  Sql.script
    connection
    "PRAGMA journal_mode=WAL;\n\
    \CREATE TABLE IF NOT EXISTS wakes (\n\
    \  instance TEXT NOT NULL,\n\
    \  kind TEXT NOT NULL,\n\
    \  identity TEXT NOT NULL,\n\
    \  due_at REAL NOT NULL,\n\
    \  PRIMARY KEY(instance, kind, identity)\n\
    \);\n\
    \CREATE INDEX IF NOT EXISTS wakes_due ON wakes(due_at, instance);"
  pure RunnableIndex {connection, clock}
  where
    createParents directory = do
      exists <- doesDirExist directory
      unless exists $ do
        createDirectoryIfMissing True (takeDirectory directory)
        PosixDir.createDirectory directory 0o700
    doesDirExist directory = either (const False) Posix.isDirectory <$> try @SomeException (Posix.getFileStatus directory)

validate :: Connection -> IO ()
validate db = do
  check <- Sql.query db "PRAGMA quick_check" []
  unless (take 1 check == [[SQLText "ok"]]) $ throwIO (RuntimeError "RunnableIndex database is corrupt")
  objects <- Sql.query db "SELECT type,name,tbl_name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name" []
  unless (objects == [[SQLText "index", SQLText "wakes_due", SQLText "wakes"], [SQLText "table", SQLText "wakes", SQLText "wakes"]]) incompatible
  columns <- Sql.query db "PRAGMA table_info(wakes)" []
  unless
    ( columns
        == [ [SQLInteger 0, SQLText "instance", SQLText "TEXT", SQLInteger 1, SQLNull, SQLInteger 1]
           , [SQLInteger 1, SQLText "kind", SQLText "TEXT", SQLInteger 1, SQLNull, SQLInteger 2]
           , [SQLInteger 2, SQLText "identity", SQLText "TEXT", SQLInteger 1, SQLNull, SQLInteger 3]
           , [SQLInteger 3, SQLText "due_at", SQLText "REAL", SQLInteger 1, SQLNull, SQLInteger 0]
           ]
    )
    incompatible
  index <- Sql.query db "PRAGMA index_info(wakes_due)" []
  unless (index == [[SQLInteger 0, SQLInteger 3, SQLText "due_at"], [SQLInteger 1, SQLInteger 0, SQLText "instance"]]) incompatible
  where
    incompatible = throwIO (RuntimeError "RunnableIndex schema is incompatible")

replaceDisposable :: FilePath -> IO ()
replaceDisposable path = do
  removePathForcibly (path <> "-wal")
  removePathForcibly (path <> "-shm")
  renameFile path (path <> ".corrupt")

-- | @wake(instance, due_at, kind, identity)@: coalesce to the earliest.
wake :: RunnableIndex -> Text -> Double -> Text -> Text -> IO ()
wake index instance' dueAt kind identity = do
  i <- identifier instance' 256 "instance"
  k <- identifier kind 64 "reason kind"
  n <- identifier identity 256 "reason identity"
  d <- instant dueAt
  void $
    Sql.withLock index.connection $
      Sql.execute
        index.connection
        "INSERT INTO wakes(instance,kind,identity,due_at) VALUES(?,?,?,?) ON CONFLICT(instance,kind,identity) DO UPDATE SET due_at=MIN(due_at,excluded.due_at)"
        [SQLText i, SQLText k, SQLText n, SQLFloat d]

-- | @replace_timer(instance, due_at)@.
replaceTimer :: RunnableIndex -> Text -> Maybe Double -> IO ()
replaceTimer index instance' dueAt = do
  i <- identifier instance' 256 "instance"
  case dueAt of
    Nothing ->
      void . Sql.withLock index.connection $
        Sql.execute index.connection "DELETE FROM wakes WHERE instance=? AND kind='petri-timer'" [SQLText i]
    Just due -> do
      d <- instant due
      void . Sql.withLock index.connection $
        Sql.execute
          index.connection
          "INSERT INTO wakes(instance,kind,identity,due_at) VALUES(?,'petri-timer','next-maturation',?) ON CONFLICT(instance,kind,identity) DO UPDATE SET due_at=excluded.due_at"
          [SQLText i, SQLFloat d]

cancelTimer :: RunnableIndex -> Text -> IO ()
cancelTimer index instance' = replaceTimer index instance' Nothing

-- | @take_due(limit)@ at the index clock.
takeDue :: RunnableIndex -> Int -> IO [Text]
takeDue index limit = index.clock >>= takeDueAt index limit

-- | @take_due(limit, now=now)@.
takeDueAt :: RunnableIndex -> Int -> Double -> IO [Text]
takeDueAt index limit now = do
  let bounded = max 1 (min limit 1000)
  at <- instant now
  let db = index.connection
  Sql.withLock db $ mask $ \restore -> do
    Sql.script db "BEGIN IMMEDIATE"
    let body = do
          rows <-
            Sql.query
              db
              "SELECT instance,MIN(due_at) AS first_due FROM wakes WHERE due_at<=? GROUP BY instance ORDER BY first_due,instance LIMIT ?"
              [SQLFloat at, SQLInteger (fromIntegral bounded)]
          let instances = [t | SQLText t : _ <- rows]
          unless (null instances) $ do
            let placeholders = T.intercalate "," (map (const "?") instances)
            void $
              Sql.execute
                db
                ("DELETE FROM wakes WHERE due_at<=? AND instance IN (" <> placeholders <> ")")
                (SQLFloat at : map SQLText instances)
          Sql.script db "COMMIT"
          pure instances
    restore body `onException` (try @SomeException (Sql.script db "ROLLBACK") >> pure ())

count :: RunnableIndex -> IO Int
count index =
  Sql.withLock index.connection (Sql.query index.connection "SELECT COUNT(*) FROM wakes" []) >>= \case
    [[SQLInteger n]] -> pure (fromIntegral n)
    _ -> pure 0

-- | @next_due()@: the earliest wake without claiming it.
nextDue :: RunnableIndex -> IO (Maybe Double)
nextDue index =
  Sql.withLock index.connection (Sql.query index.connection "SELECT MIN(due_at) FROM wakes" []) >>= \case
    [[SQLFloat d]] -> pure (Just d)
    [[SQLInteger n]] -> pure (Just (fromIntegral n))
    _ -> pure Nothing

close :: RunnableIndex -> IO ()
close index = Sql.close index.connection
