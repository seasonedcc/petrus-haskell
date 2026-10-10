-- | A small pool of open connections to one database file, for stores whose
-- operations each run on a connection of their own (Local Dispatch).
--
-- Upstream opens a new connection for every such operation. Closing it is
-- cheap while another connection to the file is still open. When it is the
-- last connection to the file, though, SQLite checkpoints the WAL into the
-- database and deletes it, which costs several fsyncs. A pool keeps a few
-- connections open between operations, so the per-operation close is never
-- the last one, and a connection's PRAGMAs and prepared statements are not
-- redone for every operation. Each operation still has a connection to
-- itself and runs the same statements and transactions on it.
--
-- A pool is an owned resource: 'closePool' (or 'withPool') closes its idle
-- connections, and the last of those closes checkpoints the WAL as before.
-- A pool that becomes unreachable without being closed closes its idle
-- connections when the garbage collector finalizes it.
--
-- A pooled connection is reused only while the path still names the file
-- it was opened on (same device and inode), so a database that is deleted or
-- replaced is reopened, as a fresh connection per operation would be.
module Petrus.Sqlite.Pool
  ( Pool
  , poolPath
  , newPool
  , closePool
  , withPool
  , withPooledConnection
  ) where

import Control.Exception (SomeException, bracket, catch, fromException, mask, onException, throwIO, try)
import Control.Monad (unless, void)
import Data.IORef (IORef, atomicModifyIORef', mkWeakIORef, newIORef)
import Data.Maybe (isJust)
import Database.SQLite3 (SQLError)
import Petrus.Sqlite.Connection (Connection, close, inTransaction)
import System.Posix.Files (deviceID, fileID, getFileStatus)
import System.Posix.Types (DeviceID, FileID)

-- | Open connections to one file, at most a fixed number of them idle.
data Pool = Pool
  { poolPath :: FilePath
  -- ^ The path the pool's connections are opened on.
  , poolOpener :: IO Connection
  , poolCapacity :: Int
  , poolState :: IORef State
  }

data State = State
  { stateIdle :: [Idle]
  , stateClosed :: Bool
  }

-- | An idle connection and the identity of the file it was opened on.
data Idle = Idle
  { idleConnection :: Connection
  , idleFile :: Maybe (DeviceID, FileID)
  }

-- | A pool that keeps at most @capacity@ idle connections to the path,
-- opening new ones with the action, which must open that path and fully
-- configure the connection. Nothing is opened until first use.
newPool :: Int -> FilePath -> IO Connection -> IO Pool
newPool capacity path opener = do
  ref <- newIORef (State [] False)
  _ <- mkWeakIORef ref (drainIdle ref >>= mapM_ closeQuietly)
  pure (Pool path opener capacity ref)

-- | Close the idle connections. Connections in use close when their
-- operation ends, and later operations each open and close a connection of
-- their own. Closing twice is harmless. The first failure to close is
-- rethrown once every idle connection has been closed.
closePool :: Pool -> IO ()
closePool pool = do
  entries <- drainIdle (poolState pool)
  results <- mapM (try @SomeException . close . idleConnection) entries
  case [e | Left e <- results] of
    failure : _ -> throwIO failure
    [] -> pure ()

-- | 'newPool', run the action, 'closePool'.
withPool :: Int -> FilePath -> IO Connection -> (Pool -> IO a) -> IO a
withPool capacity path opener = bracket (newPool capacity path opener) closePool

drainIdle :: IORef State -> IO [Idle]
drainIdle ref = atomicModifyIORef' ref (\s -> (State [] True, stateIdle s))

-- | Run the action with a connection of its own: an idle one when the path
-- still names its file, otherwise a new one.
--
-- Afterwards the connection goes back to the pool, unless the pool is
-- closed or full, a transaction is still open on it, or the action failed
-- with a SQLite error. Otherwise it is closed.
withPooledConnection :: Pool -> (Connection -> IO a) -> IO a
withPooledConnection pool action = mask $ \restore -> do
  entry <- acquire pool
  result <-
    restore (action (idleConnection entry)) `catch` \(failure :: SomeException) -> do
      let sqlite = isJust (fromException failure :: Maybe SQLError)
      if sqlite then closeQuietly entry else void (try @SomeException (release pool entry))
      throwIO failure
  release pool entry
  pure result

acquire :: Pool -> IO Idle
acquire pool =
  atomicModifyIORef' (poolState pool) pop >>= \case
    Nothing -> fresh
    Just entry -> do
      current <- fileIdentity (poolPath pool)
      if isJust current && current == idleFile entry
        then pure entry
        else closeQuietly entry >> acquire pool
  where
    pop s = case stateIdle s of
      entry : rest -> (s {stateIdle = rest}, Just entry)
      [] -> (s, Nothing)
    fresh = do
      opened <- poolOpener pool
      file <- fileIdentity (poolPath pool) `onException` closeQuietly (Idle opened Nothing)
      pure (Idle opened file)

-- | Return a connection to the pool, or close it when it cannot be reused.
release :: Pool -> Idle -> IO ()
release pool entry = do
  open' <- inTransaction (idleConnection entry) `catch` \(_ :: SomeException) -> pure True
  kept <-
    if open' || not (isJust (idleFile entry))
      then pure False
      else atomicModifyIORef' (poolState pool) $ \s ->
        if stateClosed s || length (stateIdle s) >= poolCapacity pool
          then (s, False)
          else (s {stateIdle = entry : stateIdle s}, True)
  unless kept (close (idleConnection entry))

closeQuietly :: Idle -> IO ()
closeQuietly entry = void (try @SomeException (close (idleConnection entry)))

-- | The device and inode the path names now, if it names a file.
-- An in-memory or temporary database (@:memory:@, the empty path) is never
-- the file at its path, so its connections are never reused.
fileIdentity :: FilePath -> IO (Maybe (DeviceID, FileID))
fileIdentity path
  | path `elem` ["", ":memory:"] = pure Nothing
  | otherwise =
      (Just . (\status -> (deviceID status, fileID status)) <$> getFileStatus path)
        `catch` \(_ :: IOError) -> pure Nothing
