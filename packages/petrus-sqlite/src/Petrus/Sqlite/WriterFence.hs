-- | The SQLite Engine's writer fence (@_WriterFence@ in
-- @petrus.impetus.history_store.sqlite@).
--
-- One canonical writer per Instance per database file: before loading
-- History, the Engine takes a non-blocking BSD @flock@ on
--
-- > <database.parent>/.impetus-sqlite-locks/<sha256(str(database))>.<sha256(instance)>.lock
--
-- where @database = Path(path).expanduser().resolve()@. The directory is
-- created with mode @0700@ and the lock file with @0600@. Because the path
-- derivation and the lock primitive are identical, a Haskell Engine and a
-- Python Engine on the same database and Instance exclude each other.
module Petrus.Sqlite.WriterFence
  ( WriterFence
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

import Control.Exception (Exception, bracket, mask_, onException, throwIO)
import Control.Monad (unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.Bits (shiftR, (.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Posix (LockKind (..), closeFd, expandAndResolve, makeDirectories, openLockFile, tryLock, unlock)
import Petrus.Sqlite.PythonRepr (pythonReprText)
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd, ProcessID)

-- | A held fence.
data WriterFence = WriterFence
  { fenceLockPath :: FilePath
  -- ^ The lock file.
  , fenceDatabase :: FilePath
  -- ^ @str(Path(path).expanduser().resolve())@.
  , fenceInstance :: Text
  , fenceOwner :: ProcessID
  , fenceDescriptor :: IORef (Maybe Fd)
  }

-- | The fence's refusals, with upstream's messages ('fenceErrorMessage').
data FenceError
  = -- | @ValueError@: the instance id is empty.
    EmptyInstance
  | -- | @RuntimeError@: another process (Python or Haskell) holds the fence.
    SecondWriter Text FilePath
  | -- | @RuntimeError@: the fence was used from a forked child.
    InheritedAcrossFork
  deriving stock (Eq, Show)

instance Exception FenceError

-- | Upstream's exception text for each refusal.
fenceErrorMessage :: FenceError -> String
fenceErrorMessage = \case
  EmptyInstance -> "SQLite Engine requires a non-empty string instance id, got ''"
  SecondWriter instanceId database ->
    "refusing second canonical writer for Instance " ++ pythonReprText instanceId ++ " in SQLite database " ++ database
  InheritedAcrossFork -> "an Engine inherited across fork cannot be observed or driven; open a fresh Engine"

sha256Hex :: ByteString -> String
sha256Hex = BS.foldr (\w rest -> hexDigit (w `shiftR` 4) : hexDigit (w .&. 15) : rest) [] . SHA256.hash
  where
    hexDigit n = BC.index "0123456789abcdef" (fromIntegral n)

-- | The resolved database path and the lock-file path for a database and
-- Instance (no file-system changes besides resolving).
writerFencePaths :: FilePath -> Text -> IO (FilePath, FilePath)
writerFencePaths path instanceId = do
  database <- expandAndResolve path
  let identity = sha256Hex (TE.encodeUtf8 instanceId)
      databaseId = sha256Hex (TE.encodeUtf8 (T.pack database))
  pure (database, lockDirectoryOf database ++ "/" ++ databaseId ++ "." ++ identity ++ ".lock")

-- @database.parent / ".impetus-sqlite-locks"@ for a resolved (absolute,
-- normalized) path.
lockDirectoryOf :: FilePath -> FilePath
lockDirectoryOf database = case parent of
  "/" -> "/.impetus-sqlite-locks"
  _ -> parent ++ "/.impetus-sqlite-locks"
  where
    parent = case [i | (i, '/') <- zip [0 :: Int ..] database] of
      [] -> "/"
      indices -> let p = take (last indices) database in if null p then "/" else p

-- | Take the fence, refusing with 'SecondWriter' when it is held elsewhere.
acquireWriterFence :: FilePath -> Text -> IO WriterFence
acquireWriterFence path instanceId = do
  when (T.null instanceId) (throwIO EmptyInstance)

  (database, lockPath) <- writerFencePaths path instanceId
  makeDirectories (lockDirectoryOf database) 0o700
  owner <- getProcessID
  mask_ $ do
    fd <- openLockFile lockPath
    held <- tryLock fd Exclusive `onException` closeFd fd
    unless held $ do
      closeFd fd
      throwIO (SecondWriter instanceId database)
    descriptor <- newIORef (Just fd)
    pure (WriterFence lockPath database instanceId owner descriptor)

-- | @ensure()@: refuse use from a process other than the one that took the
-- fence.
ensureWriterFence :: WriterFence -> IO ()
ensureWriterFence fence = do
  pid <- getProcessID
  unless (pid == fenceOwner fence) (throwIO InheritedAcrossFork)

-- | @close()@: unlock and close; idempotent.
releaseWriterFence :: WriterFence -> IO ()
releaseWriterFence fence = mask_ $ do
  descriptor <- atomicModifyIORef' (fenceDescriptor fence) (Nothing,)
  case descriptor of
    Nothing -> pure ()
    Just fd -> do
      pid <- getProcessID
      if pid == fenceOwner fence
        then unlock fd `onException` closeFd fd >> closeFd fd
        else closeFd fd

-- | Hold the fence for the duration of an action.
withWriterFence :: FilePath -> Text -> (WriterFence -> IO a) -> IO a
withWriterFence path instanceId = bracket (acquireWriterFence path instanceId) releaseWriterFence
