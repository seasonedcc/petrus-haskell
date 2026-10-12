-- | Starting a child process the way CPython's @subprocess.Popen@ does, for
-- callers outside this package that talk to the child over pipes.
--
-- The reference's Agenticus hosts start their helpers and sidecars with
-- @Popen(..., stdin=PIPE, stdout=PIPE, stderr=PIPE, close_fds=True,
-- start_new_session=True)@. The port starts them with this package's
-- @posix_spawn@, which keeps only stdio open as CPython does, where the
-- @process@ package forks and closes every descriptor up to
-- @RLIMIT_NOFILE@ for @close_fds@: about 0.1 s per spawn at macOS's
-- 1 048 576, where CPython closes only the open ones. The capture loops stay
-- in the private "Petrus.Motus.Execution.Internal.Process".
module Petrus.Motus.Execution.Spawn
  ( spawnPiped
  ) where

import Control.Exception (IOException, catch, finally, mask_, onException, try)
import GHC.IO.Device (IODeviceType (Stream))
import GHC.IO.FD qualified as FD
import GHC.IO.Handle.FD (mkHandleFromFD)
import Petrus.Motus.Execution.Error (ExecutionError)
import Petrus.Motus.Execution.Internal.Process (StdioFd (..), childPid, spawnChild)
import System.IO (Handle, IOMode (..))
import System.Posix.IO (FdOption (CloseOnExec), closeFd, createPipe, setFdOption)
import System.Posix.Types (Fd (..))
import System.Process (ProcessHandle)
import System.Process.Internals (mkProcessHandle)

-- | @subprocess.Popen([executable, *arguments], stdin=PIPE, stdout=PIPE,
-- stderr=PIPE, cwd=directory, env=environment, start_new_session=True)@
-- (@close_fds=True@ by default): the child's stdin, stdout and stderr
-- handles and its process, or 'Nothing' when it cannot be started.
spawnPiped :: FilePath -> [String] -> Maybe FilePath -> Maybe [(String, String)] -> IO (Maybe (Handle, Handle, Handle, ProcessHandle))
spawnPiped executable arguments directory environment =
  mask_ (start `catch` \(_ :: IOException) -> pure Nothing)
  where
    quietly = mapM_ (\fd -> closeFd fd `catch` \(_ :: IOException) -> pure ())
    pipe = do
      (readEnd, writeEnd) <- createPipe
      (readEnd, writeEnd) <$ (setFdOption readEnd CloseOnExec True >> setFdOption writeEnd CloseOnExec True)
        `onException` quietly [readEnd, writeEnd]
    start = do
      (inRead, inWrite) <- pipe
      (outRead, outWrite) <- pipe `onException` quietly [inRead, inWrite]
      (errRead, errWrite) <- pipe `onException` quietly [inRead, inWrite, outRead, outWrite]
      let parentEnds = [inWrite, outRead, errRead]
      spawned <-
        try (spawnChild (executable : arguments) directory environment True (UseFd inRead, UseFd outWrite, UseFd errWrite))
          `finally` quietly [inRead, outWrite, errWrite]
      case spawned of
        Left (_ :: ExecutionError) -> Nothing <$ quietly parentEnds
        Right child -> do
          process <- mkProcessHandle (childPid child) False
          handles <-
            ((,,) <$> pipeHandle inWrite WriteMode <*> pipeHandle outRead ReadMode <*> pipeHandle errRead ReadMode)
              `onException` quietly parentEnds
          pure (Just (case handles of (i, o, e) -> (i, o, e, process)))
    -- As the process package makes its pipe handles: non-blocking, so
    -- reads and writes wait in the IO manager. A blocking descriptor would
    -- cost a readiness poll and a safe foreign call per read or write, and
    -- a reader blocked in that call cannot be killed until it returns.
    pipeHandle (Fd fd) mode = do
      (device, _) <- FD.mkFD fd mode (Just (Stream, 0, 0)) False False
      nonBlocking <- FD.setNonBlockingMode device True
      mkHandleFromFD nonBlocking Stream ("fd:" <> show fd) mode False Nothing
