{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE InterruptibleFFI #-}
{-# LANGUAGE MultiWayIf #-}

-- | BSD @flock(2)@ locks, interoperable with Python's @fcntl.flock@.
--
-- Every cross-process file lock upstream is @fcntl.flock@: the SQLite writer
-- fence, the ZeroMQ IPC endpoint lock, the Gondolin operation lock and the
-- agenticus ledgers' @.<db>.writer.lock@ files. A Haskell process taking the
-- same lock must use the same primitive. GHC's @hLock@ prefers Linux OFD
-- @fcntl@ locks and @unix@'s @setLock@ takes POSIX record locks; neither
-- excludes a @flock@ holder, so this module calls @flock(2)@ directly.
--
-- @flock@ locks belong to the open file description: they are released when
-- every descriptor sharing it is closed (including at process death), or by
-- an explicit 'unlock'.
module Petrus.Posix.Flock
  ( -- * Locking a descriptor
    LockKind (..)
  , tryLock
  , lock
  , unlock

    -- * Lock files
  , openLockFile
  , openLockFileWith
  , withLockFile
  , withRevalidatedLock
  ) where

import Control.Exception (bracket, bracketOnError, mask, onException)
import Control.Monad (unless)
import Data.Bits ((.|.))
import Foreign.C.Error (eACCES, eAGAIN, eINTR, eWOULDBLOCK, getErrno, throwErrno)
import Foreign.C.Types (CInt (..))
import Petrus.Posix.At (FileStat (..), Follow (..), fdStat, statAt)
import System.IO.Error (catchIOError, isDoesNotExistError)
import Petrus.Posix.Internal (openPath)
import System.Posix.IO (closeFd)
import System.Posix.Types (Fd (..), FileMode)

-- | Shared (@LOCK_SH@) or exclusive (@LOCK_EX@).
data LockKind = Shared | Exclusive
  deriving stock (Eq, Show)

foreign import capi interruptible "sys/file.h flock" c_flock :: CInt -> CInt -> IO CInt

-- Non-blocking requests and unlocks never wait, so they skip the safe-call
-- overhead.
foreign import capi unsafe "sys/file.h flock" c_flock_nb :: CInt -> CInt -> IO CInt

foreign import capi "sys/file.h value LOCK_SH" lockSh :: CInt

foreign import capi "sys/file.h value LOCK_EX" lockEx :: CInt

foreign import capi "sys/file.h value LOCK_NB" lockNb :: CInt

foreign import capi "sys/file.h value LOCK_UN" lockUn :: CInt

kindFlag :: LockKind -> CInt
kindFlag = \case
  Shared -> lockSh
  Exclusive -> lockEx

-- | @flock(fd, kind | LOCK_NB)@: 'True' when the lock was taken, 'False' when
-- another open file description holds a conflicting lock (@EWOULDBLOCK@,
-- which upstream also accepts as @EACCES@). Other errors are thrown.
tryLock :: Fd -> LockKind -> IO Bool
tryLock (Fd fd) kind = loop
  where
    loop = do
      result <- c_flock_nb fd (kindFlag kind + lockNb)
      if result == 0
        then pure True
        else do
          errno <- getErrno
          if
            | errno == eINTR -> loop
            | errno == eWOULDBLOCK || errno == eAGAIN || errno == eACCES -> pure False
            | otherwise -> throwErrno "flock"

-- | Blocking @flock(fd, kind)@, retried on @EINTR@ like Python's
-- @fcntl.flock@. The call is @interruptible@: an asynchronous exception (for
-- example from 'System.Timeout.timeout') aborts the wait.
lock :: Fd -> LockKind -> IO ()
lock (Fd fd) kind = loop
  where
    loop = do
      result <- c_flock fd (kindFlag kind)
      unless (result == 0) $ do
        errno <- getErrno
        if errno == eINTR then loop else throwErrno "flock"

-- | @flock(fd, LOCK_UN)@.
unlock :: Fd -> IO ()
unlock (Fd fd) = do
  result <- c_flock_nb fd lockUn
  unless (result == 0) (throwErrno "flock")

-- | Open (creating if needed) a lock file the way upstream does:
-- @os.open(path, O_RDWR | O_CREAT, 0o600)@, close-on-exec as every Python
-- descriptor is. The mode only applies when the file is created (and is
-- subject to the umask, as in Python).
openLockFile :: FilePath -> IO Fd
openLockFile path = openLockFileWith path 0o600

-- | 'openLockFile' with an explicit creation mode.
openLockFileWith :: FilePath -> FileMode -> IO Fd
openLockFileWith path mode = openPath "open" path (oRdwr .|. oCreat) mode

foreign import capi "fcntl.h value O_RDWR" oRdwr :: CInt

foreign import capi "fcntl.h value O_CREAT" oCreat :: CInt

-- | Open the lock file, take a blocking lock of the given kind, run the
-- action, then release by closing the descriptor.
withLockFile :: FilePath -> LockKind -> IO a -> IO a
withLockFile path kind action =
  bracket (openLockFile path) closeFd $ \fd -> lock fd kind >> action

-- | Gondolin's revalidating exclusive lock (@_locked@): open the lock file,
-- @flock(LOCK_EX)@ (blocking), then check that the locked descriptor's
-- @(st_dev, st_ino)@ still matches the path; if the file was unlinked or
-- replaced while waiting (a destroyer removed the directory), close and
-- retry. The lock is released by closing the descriptor when the action
-- finishes.
withRevalidatedLock :: FilePath -> FileMode -> IO a -> IO a
withRevalidatedLock path mode action = mask $ \restore -> do
  fd <- acquire restore
  (restore action `onException` closeFd fd) <* closeFd fd
  where
    acquire restore = do
      attempt <- bracketOnError (openLockFileWith path mode) closeFd $ \fd -> do
        restore (lock fd Exclusive)
        held <- fdStat fd
        current <- (Just <$> statAt Nothing path FollowLinks) `catchIOError` \err ->
          if isDoesNotExistError err then pure Nothing else ioError err
        case current of
          Just now | statDevice now == statDevice held && statInode now == statInode held -> pure (Just fd)
          _ -> closeFd fd >> pure Nothing
      maybe (acquire restore) pure attempt
