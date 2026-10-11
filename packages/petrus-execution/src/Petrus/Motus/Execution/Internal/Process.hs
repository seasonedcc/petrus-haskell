{-# LANGUAGE CApiFFI #-}

-- | Child processes with bounded output capture, and the upstream
-- @_collect@ / @_result@ polling loop.
--
-- Upstream reads every byte a command writes into memory and slices the
-- result afterwards.  Here each stream retains at most the command's output
-- limit while still counting every byte, which yields byte-identical results
-- (@stdout[:limit]@, @stderr[:limit - len(stdout)]@, and the
-- @len(stdout) + len(stderr) > limit@ truncation flag) in bounded memory.
--
-- Children are started with @posix_spawn@ (@cbits/petrus_spawn.c@), not the
-- @process@ package: with @close_fds@ that package forks and closes every
-- descriptor up to @RLIMIT_NOFILE@ (about 0.1 s per spawn at macOS's
-- 1 048 576), whereas CPython closes only open descriptors.
module Petrus.Motus.Execution.Internal.Process
  ( -- * Children
    Child
  , childPid
  , StdioFd (..)
  , spawnChild
  , childExitCode
  , signalChild
    -- * Captured commands
  , SpawnSpec (..)
  , spawnSpec
  , Running
  , runningPid
  , spawnCaptured
  , pollExit
  , waitExitWithin
  , Captured (..)
  , communicateWithin
  , communicate
  , observedTotal
  , collect
  , boundedResult
  , resolveExecutable
  , runCaptured
  , RunOutcome (..)
  ) where

import Control.Concurrent (forkIO, rtsSupportsBoundThreads, threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (SomeException, catch, finally, mask, onException, try)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Foreign.C.Error (Errno (..), eCHILD)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (withArray0)
import Foreign.Marshal.Utils (fromBool, maybeWith, withMany)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek)
import GHC.Clock (getMonotonicTime)
import GHC.Foreign qualified as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import GHC.IO.Exception (IOException (..))
import Petrus.Motus.Execution (Command, commandIsCurrent, commandOutputLimit, commandTimeout, secondsToDouble)
import Petrus.Motus.Execution.Error
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hSetBinaryMode)
import System.Posix.Files (fileAccess, getFileStatus, isDirectory)
import System.Posix.IO (FdOption (CloseOnExec), closeFd, createPipe, fdToHandle, setFdOption)
import System.Posix.Process (ProcessStatus (..), getProcessStatus)
import System.Posix.Signals (Signal, sigKILL, signalProcess)
import System.Posix.Types (CPid (..), Fd (..))
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Children

-- | A spawned child.  Its status is reaped at most once and cached, and it
-- is only signalled while unreaped, so a recycled pid is never signalled.
data Child = Child
  { childPid :: CPid
  , childStatus :: MVar (Maybe Int)
  , childExited :: TVar Bool
  -- ^ Set once the child has exited (still unreaped) or cannot be waited
  -- for; see 'exitSignal'.
  , childWatched :: IORef Bool
  -- ^ Whether 'exitSignal' has started its watcher.
  }

-- | Where a child's standard descriptor comes from.
data StdioFd = InheritFd | UseFd Fd

foreign import capi safe "petrus_posix.h petrus_wait_exited"
  c_waitExited :: CPid -> IO CInt

foreign import capi safe "petrus_posix.h petrus_spawn"
  c_spawn :: CString -> Ptr CString -> Ptr CString -> CString -> CInt -> CInt -> CInt -> CInt -> Ptr CPid -> IO CInt

-- | @Popen(argv, cwd=..., env=..., start_new_session=..., close_fds=True)@
-- with the given stdin, stdout and stderr.  Failures raise 'OSError' with
-- CPython's message for the executable.
spawnChild :: [String] -> Maybe FilePath -> Maybe [(String, String)] -> Bool -> (StdioFd, StdioFd, StdioFd) -> IO Child
spawnChild argv cwd environment newSession (input, output, errors) = case argv of
  [] -> throwExecution ValueError "empty argv"
  executable : _ -> do
    encoding <- getFileSystemEncoding
    let withText = GHC.withCString encoding
        withEnvironment action = case environment of
          Nothing -> action nullPtr
          Just pairs -> withMany withText [key <> "=" <> value | (key, value) <- pairs] (\entries -> withArray0 nullPtr entries action)
    status <-
      withText executable $ \file ->
        withMany withText argv $ \arguments ->
          withArray0 nullPtr arguments $ \argumentsPtr ->
            withEnvironment $ \environmentPtr ->
              maybeWith withText cwd $ \cwdPtr ->
                alloca $ \pidPtr -> do
                  code <-
                    c_spawn file argumentsPtr environmentPtr cwdPtr (fromBool newSession) (raw input) (raw output) (raw errors) pidPtr
                  if code == 0 then Right <$> peek pidPtr else pure (Left code)
    case status of
      Left code -> throwExecution OSError (T.pack (pythonErrnoMessage code (Just executable)))
      Right pid -> Child pid <$> newMVar Nothing <*> newTVarIO False <*> newIORef False
  where
    raw = \case
      InheritFd -> -1
      UseFd (Fd fd) -> fd

-- | @Popen.poll()@ on a 'Child': the Python return code (@-signal@ when
-- signalled), reaping at most once.
childExitCode :: Child -> IO (Maybe Int)
childExitCode child = modifyMVar (childStatus child) $ \case
  done@(Just _) -> pure (done, done)
  Nothing -> do
    -- Popen._internal_poll: a child that cannot be waited for (ECHILD,
    -- already reaped elsewhere) is dead with return code 0.
    status <-
      getProcessStatus False False (childPid child) `catch` \(failure :: IOError) ->
        if fmap Errno (ioe_errno failure) == Just eCHILD then pure (Just (Exited ExitSuccess)) else ioError failure
    let code =
          status >>= \case
            Exited ExitSuccess -> Just 0
            Exited (ExitFailure n) -> Just n
            Terminated signal _ -> Just (negate (fromIntegral signal))
            Stopped _ -> Nothing
    pure (code, code)

-- | A variable that turns 'True' once the child has exited, so a waiter can
-- block instead of polling.  The first call starts one watcher thread whose
-- safe foreign call blocks in @waitid(WNOWAIT)@: it observes the exit without
-- reaping, so 'childExitCode' still reaps exactly once and 'signalChild'
-- never targets a recycled pid.  It also turns 'True' when the child cannot
-- be waited for (already reaped).  Only for the threaded RTS, where a blocked
-- safe call holds one OS thread rather than the whole program.
exitSignal :: Child -> IO (TVar Bool)
exitSignal child = do
  watching <- atomicModifyIORef' (childWatched child) (True,)
  unless watching $
    () <$ forkIO (c_waitExited (childPid child) >> atomically (writeTVar (childExited child) True))
  pure (childExited child)

-- | @Popen.send_signal@: a no-op once the child has been reaped.
signalChild :: Child -> Signal -> IO ()
signalChild child signal = withMVar (childStatus child) $ \case
  Just _ -> pure ()
  Nothing -> signalProcess signal (childPid child)

-- | A pipe whose ends are both close-on-exec: @(read, write)@.
pipeCloexec :: IO (Fd, Fd)
pipeCloexec = do
  (readEnd, writeEnd) <- createPipe
  setFdOption readEnd CloseOnExec True
  setFdOption writeEnd CloseOnExec True
  pure (readEnd, writeEnd)

-- ---------------------------------------------------------------------------
-- Captured commands

data SpawnSpec = SpawnSpec
  { spawnArgv :: [String]
  -- ^ argv; the first element must already be an executable path.
  , spawnCwd :: Maybe FilePath
  , spawnEnv :: Maybe [(String, String)]
  , spawnNewSession :: Bool
  , spawnStdin :: Maybe ByteString
  -- ^ 'Nothing' inherits stdin; 'Just' feeds these bytes then closes it.
  , spawnRetain :: Int
  -- ^ Bytes retained per output stream.
  }

spawnSpec :: [String] -> SpawnSpec
spawnSpec argv = SpawnSpec argv Nothing Nothing False Nothing maxBound

data Stream = Stream
  { streamChunks :: IORef [ByteString]
  , streamRetained :: IORef Int
  , streamTotal :: IORef Int
  , streamDone :: TVar Bool
  }

data Running = Running
  { runningChild :: Child
  , runningOut :: Stream
  , runningErr :: Stream
  , runningInputDone :: TVar Bool
  , runningExit :: IORef (Maybe Int)
  }

newStream :: IO Stream
newStream = Stream <$> newIORef [] <*> newIORef 0 <*> newIORef 0 <*> newTVarIO False

drain :: Int -> Handle -> Stream -> IO ()
drain retain handle stream = do
  hSetBinaryMode handle True
  let loop = do
        chunk <- B.hGetSome handle 65536
        unless (B.null chunk) $ do
          kept <- readIORef (streamRetained stream)
          let room = max 0 (retain - kept)
              piece = B.take room chunk
          unless (B.null piece) $ do
            modifyIORef' (streamChunks stream) (piece :)
            writeIORef (streamRetained stream) (kept + B.length piece)
          atomicModifyIORef' (streamTotal stream) (\n -> (n + B.length chunk, ()))
          loop
  (loop `catch` \(_ :: IOError) -> pure ())
    `finally` (hClose handle `catch` \(_ :: IOError) -> pure ())
    `finally` atomically (writeTVar (streamDone stream) True)

-- | Start a child with piped stdout/stderr (and stdin when given).
spawnCaptured :: SpawnSpec -> IO Running
spawnCaptured spec = mask $ \restore -> do
    let closeAll = mapM_ (\fd -> closeFd fd `catch` \(_ :: IOError) -> pure ())
    (outRead, outWrite) <- pipeCloexec
    (errRead, errWrite) <- pipeCloexec `onException` closeAll [outRead, outWrite]
    inputPipe <- case spawnStdin spec of
      Nothing -> pure Nothing
      Just _ -> Just <$> pipeCloexec `onException` closeAll [outRead, outWrite, errRead, errWrite]
    let parentEnds = [outRead, errRead] <> maybe [] (pure . snd) inputPipe
        childEnds = [outWrite, errWrite] <> maybe [] (pure . fst) inputPipe
    child <-
      spawnChild
        (spawnArgv spec)
        (spawnCwd spec)
        (spawnEnv spec)
        (spawnNewSession spec)
        (maybe InheritFd (UseFd . fst) inputPipe, UseFd outWrite, UseFd errWrite)
        `finally` closeAll childEnds
        `onException` closeAll parentEnds
    out <- fdToHandle outRead
    err <- fdToHandle errRead
    input <- traverse (fdToHandle . snd) inputPipe
    stdoutStream <- newStream
    stderrStream <- newStream
    inputDone <- newTVarIO True
    _ <- forkIO (restore (drain (spawnRetain spec) out stdoutStream))
    _ <- forkIO (restore (drain (spawnRetain spec) err stderrStream))
    case (input, spawnStdin spec) of
      (Just inputHandle, Just bytes) -> do
        atomically (writeTVar inputDone False)
        _ <-
          forkIO $
            restore
              ( (hSetBinaryMode inputHandle True >> B.hPut inputHandle bytes)
                  `catch` (\(_ :: IOError) -> pure ())
              )
              `finally` (hClose inputHandle `catch` \(_ :: IOError) -> pure ())
              `finally` atomically (writeTVar inputDone True)
        pure ()
      _ -> pure ()
    exitRef <- newIORef Nothing
    pure (Running child stdoutStream stderrStream inputDone exitRef)

-- | The child's pid (its process group too when started in a new session).
runningPid :: Running -> CPid
runningPid = childPid . runningChild

-- | @Popen.poll()@: the Python return code (@-signal@ when signalled).
pollExit :: Running -> IO (Maybe Int)
pollExit running =
  readIORef (runningExit running) >>= \case
    Just code -> pure (Just code)
    Nothing -> do
      code <- childExitCode (runningChild running)
      forM_ code (writeIORef (runningExit running) . Just)
      pure code

-- | @Popen.wait(timeout)@ without raising: 'Nothing' when still running.
--
-- On the threaded RTS this blocks until the child exits ('exitSignal') or
-- the limit passes, then reaps it; elsewhere it polls with CPython's
-- back-off (0.5 ms doubling to 50 ms).
waitExitWithin :: Running -> Maybe Double -> IO (Maybe Int)
waitExitWithin running limit
  | rtsSupportsBoundThreads =
      pollExit running >>= \case
        Just code -> pure (Just code)
        Nothing -> do
          start <- getMonotonicTime
          exited <- exitSignal (runningChild running)
          let arrival = atomically (readTVar exited >>= check)
          arrived <- case limit of
            Nothing -> True <$ arrival
            Just seconds
              | seconds > 0 -> isJust <$> timeout (max 1 (round (min seconds 1.0e9 * 1e6))) arrival
              | otherwise -> pure False
          code <- pollExit running
          case code of
            Nothing | arrived -> do
              -- Exited but not yet reapable: finish with the poll loop.
              now <- getMonotonicTime
              waitExitPolling running (fmap (\seconds -> max 0 (seconds - (now - start))) limit)
            _ -> pure code
  | otherwise = waitExitPolling running limit

-- | 'waitExitWithin' by polling: CPython's @Popen._wait@ loop.
waitExitPolling :: Running -> Maybe Double -> IO (Maybe Int)
waitExitPolling running limit = do
  start <- getMonotonicTime
  let loop delay =
        pollExit running >>= \case
          Just code -> pure (Just code)
          Nothing -> do
            now <- getMonotonicTime
            case limit of
              Just seconds | now - start >= seconds -> pure Nothing
              _ -> do
                let remaining = maybe delay (\seconds -> max 0 (seconds - (now - start))) limit
                threadDelay (max 1 (round (1e6 * min delay remaining)))
                loop (min 0.05 (delay * 2))
  loop 0.0005

data Captured = Captured
  { capturedStdout :: ByteString
  , capturedStderr :: ByteString
  , capturedTotal :: Int
  }

streamBytes :: Stream -> IO ByteString
streamBytes stream = B.concat . reverse <$> readIORef (streamChunks stream)

-- | Bytes observed so far on both streams (upstream's partial
-- @TimeoutExpired@ output length).
observedTotal :: Running -> IO Int
observedTotal running = (+) <$> readIORef (streamTotal (runningOut running)) <*> readIORef (streamTotal (runningErr running))

captured :: Running -> IO Captured
captured running =
  Captured
    <$> streamBytes (runningOut running)
    <*> streamBytes (runningErr running)
    <*> observedTotal running

-- | @Popen.communicate(timeout)@: wait for EOF on every pipe and for exit.
communicateWithin :: Running -> Double -> IO (Maybe Captured)
communicateWithin running seconds = do
  start <- getMonotonicTime
  pipesClosed <-
    timeout (max 1 (round (seconds * 1e6))) (atomically allPipesDone) >>= \case
      Just () -> pure True
      Nothing -> pure False
  if not pipesClosed
    then pure Nothing
    else do
      now <- getMonotonicTime
      waitExitWithin running (Just (max 0 (seconds - (now - start)))) >>= \case
        Nothing -> pure Nothing
        Just _ -> Just <$> captured running
  where
    allPipesDone = do
      outDone <- readTVar (streamDone (runningOut running))
      errDone <- readTVar (streamDone (runningErr running))
      inputDone <- readTVar (runningInputDone running)
      check (outDone && errDone && inputDone)

communicate :: Running -> IO Captured
communicate running = do
  atomically $ do
    outDone <- readTVar (streamDone (runningOut running))
    errDone <- readTVar (streamDone (runningErr running))
    inputDone <- readTVar (runningInputDone running)
    check (outDone && errDone && inputDone)
  _ <- waitExitWithin running Nothing
  captured running

-- | Upstream @_collect@: poll in ticks of at most 50 ms; supersession,
-- timeout, or output overflow terminate the command, escalating to kill
-- after half a second.  Returns the capture plus @(timed_out, superseded,
-- output_truncated)@.
collect :: Running -> Command -> IO () -> IO () -> IO (Captured, Bool, Bool, Bool)
collect running command terminate kill = do
  start <- getMonotonicTime
  let deadline = fmap ((start +) . secondsToDouble) (commandTimeout command)
      loop = do
        now <- getMonotonicTime
        let wait = maybe 0.05 (\d -> max 0.001 (min 0.05 (d - now))) deadline
        communicateWithin running wait >>= \case
          Just done -> pure (done, False, False, False)
          Nothing -> do
            total <- observedTotal running
            let truncated = total > commandOutputLimit command
            superseded <- case commandIsCurrent command of
              Nothing -> pure False
              Just isCurrent ->
                (not <$> isCurrent) `onException` (kill >> communicate running)
            later <- getMonotonicTime
            let timedOut = maybe False (later >=) deadline
            if not (superseded || timedOut || truncated)
              then loop
              else do
                terminate
                result <-
                  communicateWithin running 0.5 >>= \case
                    Just done -> pure done
                    Nothing -> kill >> communicate running
                pure (result, timedOut, superseded, truncated)
  loop

-- | Upstream @_result@ slicing.
boundedResult :: Int -> Bool -> Captured -> (ByteString, ByteString, Bool)
boundedResult limit overflow capture =
  let out = B.take limit (capturedStdout capture)
      err = B.take (max 0 (limit - B.length out)) (capturedStderr capture)
   in (out, err, overflow || capturedTotal capture > limit)

-- | Resolve @argv[0]@ the way @subprocess.Popen@ does for an explicit
-- environment: names containing a slash are used as given, others are
-- searched in the environment's @PATH@ (or @os.defpath@).
resolveExecutable :: [(Text, Text)] -> Text -> IO FilePath
resolveExecutable environment name
  | T.any (== '/') name = pure (T.unpack name)
  | otherwise = do
      let path = fromMaybe "/bin:/usr/bin" (lookup "PATH" environment)
          directories = map (\d -> if T.null d then "." else d) (T.splitOn ":" path)
      found <- firstExecutable [T.unpack (d <> "/" <> name) | d <- directories]
      case found of
        Just candidate -> pure candidate
        Nothing -> throwExecution OSError (T.pack (pythonErrnoMessage 2 (Just (T.unpack name))))
  where
    firstExecutable [] = pure Nothing
    firstExecutable (candidate : rest) = do
      usable <- try (do status <- getFileStatus candidate; ok <- fileAccess candidate False False True; pure (ok && not (isDirectory status)))
      case usable of
        Right True -> pure (Just candidate)
        Right False -> firstExecutable rest
        Left (_ :: SomeException) -> firstExecutable rest

data RunOutcome = RunOutcome
  { outcomeCode :: Int
  , outcomeStdout :: ByteString
  , outcomeStderr :: ByteString
  }

-- | @subprocess.run(argv, capture_output=True, input=..., timeout=...)@.
-- On timeout the child is killed and 'TimeoutError' is raised.
runCaptured :: SpawnSpec -> Double -> IO RunOutcome
runCaptured spec seconds = do
  running <- spawnCaptured spec
  communicateWithin running seconds >>= \case
    Just done -> finish running done
    Nothing -> do
      code <- pollExit running
      when (isNothing code) (signalChild (runningChild running) sigKILL)
      _ <- communicate running
      throwExecution
        TimeoutError
        ( "Command "
            <> T.pack (show (spawnArgv spec))
            <> " timed out after "
            <> T.pack (show seconds)
            <> " seconds"
        )
  where
    finish running done = do
      code <- fromMaybe 0 <$> pollExit running
      pure (RunOutcome code (capturedStdout done) (capturedStderr done))
