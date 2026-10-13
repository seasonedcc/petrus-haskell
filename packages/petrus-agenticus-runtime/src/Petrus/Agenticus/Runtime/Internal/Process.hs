-- | The child processes the provider hosts start: private helpers (Pi, Pi
-- application, Pi model phase), sidecars (Amp, Claude, Codex), and bounded
-- probe commands.
--
-- Every child is started like @subprocess.Popen(..., close_fds=True,
-- start_new_session=True)@ with petrus-execution's @posix_spawn@
-- ("Petrus.Motus.Execution.Spawn"). A 'Helper' owns its stdout reader and stderr drainer as
-- 'Async's: closing the helper cancels them. Each host keeps only its own
-- framing and its order of closing steps on top.
module Petrus.Agenticus.Runtime.Internal.Process
  ( -- * Helpers
    HelperSpec (..)
  , privateEnvironment
  , Framing (..)
  , Helper (..)
  , spawnHelper
  , nextReceived
  , helperExited
    -- ** Closing
  , closeOnce
  , closeInput
  , stopReader
  , killGroup
  , awaitDrain
  , closeHelper
    -- * Processes
  , waitExit
  , exitInt
  , runBounded
  , removeRoot
  , splitLines
  , micros
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, poll, waitCatch, withAsync)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM
import Control.Exception (IOException, catch, mask, mask_, onException, try)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Maybe (isJust, isNothing)
import GHC.Clock (getMonotonicTime)
import Petrus.Motus.Execution.Spawn (spawnPiped)
import System.Directory (removeDirectoryRecursive)
import Petrus.Posix.Process (exitInt)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.IO (BufferMode (..), Handle, hClose, hSetBinaryMode, hSetBuffering)
import System.IO.Error (doesNotExistErrorType, isDoesNotExistError, mkIOError)
import System.Posix.Files qualified as Files
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Posix.User (getEffectiveUserID)
import System.Process (ProcessHandle, getPid, getProcessExitCode)
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Helpers

-- | How to start one child: the executable, its arguments, the working
-- directory, and an optional environment (inherited when absent).
data HelperSpec = HelperSpec
  { executable :: FilePath
  , arguments :: [String]
  , directory :: Maybe FilePath
  , environment :: Maybe [(String, String)]
  }

-- | The environment of a private Node helper: @HOME@ is its private root
-- and @PATH@ only the directory of its @node@.
privateEnvironment :: FilePath -> FilePath -> [(String, String)]
privateEnvironment home node =
  [ ("HOME", home)
  , ("PATH", takeDirectory node)
  , ("LANG", "C.UTF-8")
  , ("LC_ALL", "C.UTF-8")
  ]

-- | What the stdout reader puts on 'received': raw chunks, or complete
-- newline-terminated lines without their newline. 'Nothing' marks the end
-- of output.
data Framing = Chunks | Lines

-- | One running child in its own session, with binary handles and a
-- block-buffered stdin.
data Helper = Helper
  { process :: ProcessHandle
  , pid :: Maybe Int
  , input :: Handle
  , output :: Handle
  , errors :: Handle
  , received :: TQueue (Maybe ByteString)
  , reader :: Async ()
  , drainer :: Async ()
  , closed :: IORef Bool
  }

-- | Start the child, or 'Nothing' when it cannot be launched.
spawnHelper :: Framing -> HelperSpec -> IO (Maybe Helper)
spawnHelper framing spec = do
  spawned <- spawnPiped spec.executable spec.arguments spec.directory spec.environment
  forM spawned $ \(input, output, errors, process) -> do
    mapM_ (`hSetBinaryMode` True) [input, output, errors]
    hSetBuffering input (BlockBuffering Nothing)
    pid <- fmap fromIntegral <$> getPid process
    received <- newTQueueIO
    mask_ $ do
      drainer <- async (drain errors)
      reader <- async (readOutput output received B.empty) `onException` cancel drainer
      closed <- newIORef False
      pure Helper {process, pid, input, output, errors, received, reader, drainer, closed}
  where
    chunkOf h = B.hGetSome h 65536 `catch` \(_ :: IOException) -> pure B.empty
    drain h = do
      chunk <- chunkOf h
      unless (B.null chunk) (drain h)
    readOutput h queue pending = do
      chunk <- chunkOf h
      if B.null chunk
        then atomically (writeTQueue queue Nothing)
        else case framing of
          Chunks -> atomically (writeTQueue queue (Just chunk)) >> readOutput h queue pending
          Lines -> do
            let (complete, rest) = splitLines (pending <> chunk)
            atomically (mapM_ (writeTQueue queue . Just) complete)
            readOutput h queue rest

-- | The next item the reader received within @microseconds@: 'Nothing'
-- when none arrived in time.
nextReceived :: Helper -> Int -> IO (Maybe (Maybe ByteString))
nextReceived h microseconds = do
  delay <- registerDelay microseconds
  atomically $
    (Just <$> readTQueue h.received) `orElse` (readTVar delay >>= \expired -> if expired then pure Nothing else retry)

-- | @process.poll() is not None@.
helperExited :: Helper -> IO Bool
helperExited h = isJust <$> getProcessExitCode h.process

-- | Run the close steps once; a later (or concurrent) close reports only
-- whether the child has exited.
closeOnce :: Helper -> IO Bool -> IO Bool
closeOnce h steps = do
  already <- atomicModifyIORef' h.closed (True,)
  if already then helperExited h else steps

closeInput :: Helper -> IO ()
closeInput h = hClose h.input `catch` \(_ :: IOException) -> pure ()

-- | Stop the reader, then close stdout (a 'Handle' is locked while a thread
-- blocks reading it).
stopReader :: Helper -> IO ()
stopReader h = do
  cancel h.reader
  hClose h.output `catch` \(_ :: IOException) -> pure ()

-- | @SIGKILL@ the child's whole process group while it runs.
killGroup :: Helper -> IO ()
killGroup h = do
  running <- isNothing <$> getProcessExitCode h.process
  when running $ forM_ h.pid $ \n ->
    signalProcessGroup sigKILL (fromIntegral n) `catch` \(_ :: IOException) -> pure ()

-- | Wait up to @grace@ seconds for the stderr drain to reach the end,
-- cancel it otherwise, and close stderr; 'True' when it finished.
awaitDrain :: Helper -> Double -> IO Bool
awaitDrain h grace = do
  _ <- timeout (micros grace) (waitCatch h.drainer)
  drained <- isJust <$> poll h.drainer
  unless drained (cancel h.drainer)
  hClose h.errors `catch` \(_ :: IOException) -> pure ()
  pure drained

-- | Close a private helper: close its pipes, kill its whole process group,
-- and report whether it and its stderr drain are proven gone.
closeHelper :: Helper -> Double -> IO Bool
closeHelper h grace = closeOnce h $ do
  closeInput h
  stopReader h
  killGroup h
  waitExit h.process grace >>= \case
    Nothing -> pure False
    Just _ -> do
      drained <- awaitDrain h grace
      exited <- helperExited h
      pure (exited && drained)

-- ---------------------------------------------------------------------------
-- Processes

-- | @process.wait(timeout=seconds)@: 'Nothing' when it is still running.
waitExit :: ProcessHandle -> Double -> IO (Maybe ExitCode)
waitExit process seconds = do
  end <- (+ seconds) <$> getMonotonicTime
  let go =
        getProcessExitCode process >>= \case
          Just code -> pure (Just code)
          Nothing -> do
            now <- getMonotonicTime
            if now >= end then pure Nothing else threadDelay 2000 >> go
  go

-- | @subprocess.run(argv, env=environment, capture_output=True,
-- timeout=10)@: capture stdout and stderr as bytes. The child runs in its
-- own session with an empty stdin; its process group is killed when the
-- bound expires or the caller is interrupted. An executable that cannot be
-- started is an 'IOException'.
runBounded :: [String] -> Maybe [(String, String)] -> IO (Maybe (ExitCode, ByteString, ByteString))
runBounded argv environment = case argv of
  [] -> ioError (userError "empty argv")
  executable : arguments -> mask $ \restore -> do
    (input, output, errors, process) <-
      spawnPiped executable arguments Nothing environment
        >>= maybe (ioError (mkIOError doesNotExistErrorType "runBounded" Nothing (Just executable))) pure
    let stop = do
          running <- isNothing <$> getProcessExitCode process
          when running $
            getPid process >>= mapM_ (\n -> signalProcessGroup sigKILL n `catch` \(_ :: IOException) -> pure ())
          void (waitExit process 1)
          mapM_ (\h -> hClose h `catch` \(_ :: IOException) -> pure ()) [output, errors]
        capture =
          withAsync (B.hGetContents errors) $ \errorReader -> do
            out <- B.hGetContents output
            err <- Async.wait errorReader
            code <- waitExit process 10
            pure (out, err, code)
    hClose input `catch` \(_ :: IOException) -> pure ()
    finished <- restore (timeout (10 * 1000000) (try capture)) `onException` stop
    case finished of
      Just (Right (out, err, Just code)) -> pure (Just (code, out, err))
      Just (Left (_ :: IOException)) -> stop >> pure Nothing
      _ -> stop >> pure Nothing

-- | Remove an owned mode-0700 private root that still has the given
-- @(device, inode)@ identity; 'True' when it is proven absent.
removeRoot :: FilePath -> Maybe (Integer, Integer) -> IO Bool
removeRoot path identity = do
  status <- try (Files.getSymbolicLinkStatus path)
  case status of
    Left e
      | isDoesNotExistError e -> pure True
      | otherwise -> pure False
    Right metadata -> do
      uid <- getEffectiveUserID
      if not (Files.isDirectory metadata)
        || Files.isSymbolicLink metadata
        || Files.fileOwner metadata /= uid
        || Files.fileMode metadata .&. 0o7777 /= 0o700
        || identity /= Just (toInteger (Files.deviceID metadata), toInteger (Files.fileID metadata))
        then pure False
        else do
          removed <- try (removeDirectoryRecursive path)
          case removed of
            Left (_ :: IOException) -> pure False
            Right () -> not <$> pathPresent path
  where
    pathPresent p =
      (True <$ Files.getSymbolicLinkStatus p) `catch` \(_ :: IOException) -> pure False

-- | Split the complete newline-terminated lines off the front of a buffer.
splitLines :: ByteString -> ([ByteString], ByteString)
splitLines bytes = case BC.elemIndex '\n' bytes of
  Nothing -> ([], bytes)
  Just i ->
    let (rest', remaining) = splitLines (B.drop (i + 1) bytes)
     in (B.take i bytes : rest', remaining)

-- | Seconds to 'threadDelay' microseconds.
micros :: Double -> Int
micros seconds = max 0 (round (seconds * 1000000))
