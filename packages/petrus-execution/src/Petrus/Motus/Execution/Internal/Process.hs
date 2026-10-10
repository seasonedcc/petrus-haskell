-- | Child processes with bounded output capture, and the upstream
-- @_collect@ / @_result@ polling loop.
--
-- Upstream reads every byte a command writes into memory and slices the
-- result afterwards.  Here each stream retains at most the command's output
-- limit while still counting every byte, which yields byte-identical results
-- (@stdout[:limit]@, @stderr[:limit - len(stdout)]@, and the
-- @len(stdout) + len(stderr) > limit@ truncation flag) in bounded memory.
module Petrus.Motus.Execution.Internal.Process
  ( SpawnSpec (..)
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

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeException, catch, finally, mask, onException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Motus.Execution (Command, commandIsCurrent, commandOutputLimit, commandTimeout, secondsToDouble)
import Petrus.Motus.Execution.Error
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hSetBinaryMode)
import System.Posix.Files (fileAccess, getFileStatus, isDirectory)
import System.Posix.Types (CPid)
import System.Process
import System.Timeout (timeout)

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
  { runningHandle :: ProcessHandle
  , runningPid :: CPid
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
spawnCaptured spec = case spawnArgv spec of
  [] -> throwExecution ValueError "empty argv"
  executable : arguments -> mask $ \restore -> do
    let process =
          (proc executable arguments)
            { cwd = spawnCwd spec
            , env = spawnEnv spec
            , std_in = maybe Inherit (const CreatePipe) (spawnStdin spec)
            , std_out = CreatePipe
            , std_err = CreatePipe
            , close_fds = True
            , new_session = spawnNewSession spec
            }
    created <- try (createProcess process)
    (input, out, err, handle) <- case created of
      Left (failure :: IOError) -> throwIO (osErrorFromIO failure)
      Right (input, Just out, Just err, handle) -> pure (input, out, err, handle)
      Right _ -> throwExecution OSError "process pipes were not created"
    pid <- fromMaybe 0 <$> getPid handle
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
    pure (Running handle pid stdoutStream stderrStream inputDone exitRef)

-- | @Popen.poll()@: the Python return code (@-signal@ when signalled).
pollExit :: Running -> IO (Maybe Int)
pollExit running =
  readIORef (runningExit running) >>= \case
    Just code -> pure (Just code)
    Nothing -> do
      status <- getProcessExitCode (runningHandle running)
      let code = fmap (\case ExitSuccess -> 0; ExitFailure n -> n) status
      forM_ code (writeIORef (runningExit running) . Just)
      pure code

-- | @Popen.wait(timeout)@ without raising: 'Nothing' when still running.
waitExitWithin :: Running -> Maybe Double -> IO (Maybe Int)
waitExitWithin running limit = do
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
      when (code == Nothing) (terminateProcess (runningHandle running))
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
