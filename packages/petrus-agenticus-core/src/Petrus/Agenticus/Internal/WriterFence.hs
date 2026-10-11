-- | The owner-checked writer fence of the Agenticus SQLite ledgers.
--
-- Territory retention and the Pi operation ledger each guard their database
-- with @.<database>.writer.lock@ beside it: opened @O_RDWR | O_CREAT |
-- O_NOFOLLOW@ with mode @0600@, refused unless it is a regular mode-0600
-- file owned by the effective user, and held with a non-blocking BSD
-- @flock(LOCK_EX)@ for the ledger's lifetime. A second process (Python or
-- Haskell) on the same database is refused. The fence remembers the process
-- that took it: a forked child may neither use nor unlock it.
--
-- Only the refusal texts differ between the ledgers; 'FenceTexts' carries
-- them.
module Petrus.Agenticus.Internal.WriterFence
  ( FenceTexts (..)
  , WriterFence
  , openWriterFence
  , ensureFence
  , fenceHeld
  , closeFence
  ) where

import Control.Exception (IOException, catch, finally, mask, onException, try)
import Control.Monad (unless, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Petrus.Agenticus.Error
import Petrus.Posix.Flock (LockKind (..), tryLock, unlock)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as PIO
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd, ProcessID)
import System.Posix.User (getEffectiveUserID)

-- | The refusals of one ledger's fence.
data FenceTexts = FenceTexts
  { unavailable :: Maybe Text
  -- ^ @StorageSecurityError@ when the lock file cannot be opened; 'Nothing'
  -- lets the @OSError@ propagate.
  , notOwned :: Text
  -- ^ @StorageSecurityError@: not a regular mode-0600 file of this user.
  , live :: Text
  -- ^ @StorageError@: another writer holds the lock.
  , unlockable :: Text
  -- ^ @OSError@: @flock@ failed otherwise.
  , closed :: Text
  -- ^ @StorageError@ from 'ensureFence' after 'closeFence'.
  , forked :: Text
  -- ^ @StorageError@ from 'ensureFence' in a forked child.
  }

-- | A held fence.
data WriterFence = WriterFence
  { texts :: FenceTexts
  , owner :: ProcessID
  , descriptor :: IORef (Maybe Fd)
  }

-- | Take the fence of a database file.
openWriterFence :: FenceTexts -> FilePath -> IO WriterFence
openWriterFence texts database = do
  let fencePath = takeDirectory database </> ("." <> takeFileName database <> ".writer.lock")
  pid <- getProcessID
  mask $ \restore -> do
    let open = PIO.openFd fencePath PIO.ReadWrite PIO.defaultFileFlags {PIO.creat = Just 0o600, PIO.nofollow = True, PIO.cloexec = True}
    fd <- case texts.unavailable of
      Nothing -> open
      Just refusal -> try open >>= either (\(_ :: IOException) -> throwAgenticus StorageSecurityError refusal) pure
    ( restore $ do
        uid <- getEffectiveUserID
        status <- Files.getFdStatus fd
        unless
          ( Files.isRegularFile status
              && Files.fileMode status `Files.intersectFileModes` 0o7777 == 0o600
              && Files.fileOwner status == uid
          )
          $ throwAgenticus StorageSecurityError texts.notOwned
        held <- tryLock fd Exclusive `catch` \(_ :: IOException) -> throwAgenticus (OtherError "OSError") texts.unlockable
        unless held $ throwAgenticus StorageError texts.live
      )
      `onException` PIO.closeFd fd
    WriterFence texts pid <$> newIORef (Just fd)

-- | Refuse use after 'closeFence' or from a forked child.
ensureFence :: WriterFence -> IO ()
ensureFence f = do
  readIORef f.descriptor >>= \case
    Nothing -> throwAgenticus StorageError f.texts.closed
    Just _ -> pure ()
  pid <- getProcessID
  when (pid /= f.owner) $ throwAgenticus StorageError f.texts.forked

-- | Whether 'closeFence' has not run yet.
fenceHeld :: WriterFence -> IO Bool
fenceHeld f = isJust <$> readIORef f.descriptor

-- | Release the fence (idempotent). A forked child only closes its copy of
-- the descriptor; the owner unlocks first.
closeFence :: WriterFence -> IO ()
closeFence f = do
  current <- atomicModifyIORef' f.descriptor (Nothing,)
  case current of
    Nothing -> pure ()
    Just fd -> do
      pid <- getProcessID
      if pid == f.owner
        then (unlock fd `catch` \(_ :: IOException) -> pure ()) `finally` PIO.closeFd fd
        else PIO.closeFd fd
