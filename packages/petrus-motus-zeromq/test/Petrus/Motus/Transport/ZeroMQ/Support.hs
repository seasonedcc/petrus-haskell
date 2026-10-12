-- | Fixtures shared by the ZeroMQ transport specs: the reference test
-- module's @invocation@, @RunningServer@, @curve_certificates@,
-- @DelayedProvider@, and @_assert_task@, plus short scratch directories (an
-- @ipc://@ path must fit in 104 bytes on macOS), the re-executed server
-- processes, and the reference interpreter.
module Petrus.Motus.Transport.ZeroMQ.Support
  ( -- * Values
    invocationWith
  , invocation
  , policyOf
  , failureOf
  , obj
    -- * Local custody
  , localDispatch
  , localWorker
  , assertTask
  , rawDetails
  , occurrenceOf
    -- * Servers
  , RunningServer (..)
  , startRunning
  , closeRunning
  , withRunning
    -- * Certificates
  , Certificates (..)
  , curveCertificates
    -- * Fault injection
  , delayedProvider
  , countingProvider
    -- * Server processes
  , serverModeVariable
  , ServerProcess (..)
  , startServerProcess
  , killProcess
  , stopServerProcess
    -- * Raw sockets
  , withRawDealer
    -- * Files
  , withScratch
  , ipcEndpoint
  , waitForFile
    -- * Errors
  , valueErrorMatching
  , runtimeErrorMatching
  , notAcknowledged
  , uncertainMatching
  , matches
    -- * The reference
  , Python
  , withReference
  , runInterop
  , startInterop
  ) where

import Control.Concurrent
import Control.Exception (SomeException, bracket, mask_, throwIO, try)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (isPrefixOf, partition)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.SQLite3 (SQLData (..), StepResult (..))
import Database.SQLite3 qualified as Sql
import GHC.Clock (getMonotonicTime)
import Petrus.Activity hiding (invocation)
import Petrus.Json (Json (..), parseJson, surrogateRefusingLoads)
import Petrus.Motus.Dispatch (ActivityAttempt (..), WorkerDispatch (..))
import Petrus.Motus.Dispatch.Local (LocalDispatch, LocalDispatchOptions (..), LocalWorkerOptions (..), defaultLocalDispatchOptions, defaultLocalWorkerOptions, openLocalDispatch, openLocalWorkerDispatch)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Transport.ZeroMQ.Native qualified as N
import Petrus.TestSupport (valid)
import Petrus.TestSupport.Python (pythonExecutable)
import Petrus.TestSupport.Repo (upstreamPetrus)
import Petrus.Motus.Transport.ZeroMQ (ConnectionError (..), RuntimeError (..), ValueError (..), ZeroMQDispatchServer, createCertificates, serveForever, stopServer, waitReady)
import System.Directory (copyFile, createDirectory, doesFileExist, getTemporaryDirectory, makeAbsolute, removeDirectoryRecursive, removeFile)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (splitDirectories, (</>))
import System.IO (Handle, hClose, hGetLine, hSetBinaryMode, openTempFile)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Signals (signalProcess, sigKILL, sigTERM)
import System.Process
import System.Timeout (timeout)
import Test.Hspec hiding (context)

-- ---------------------------------------------------------------------------
-- Values

policyOf :: ExecutionPolicyFields -> ExecutionPolicy
policyOf = either (error . T.unpack) id . executionPolicy

-- | @invocation(*, attempts=2, heartbeat_timeout=2)@.
invocationWith :: Integer -> Integer -> ActivityInvocation
invocationWith attempts' heartbeat =
  valid . activityInvocation $
    ActivityInvocationFields
      { activity = "work"
      , input = Object [("nested", Array [Int 1, Object [("faithful", Bool True)]])]
      , policy = policyOf (policyFields defaultExecutionPolicy) {attempts = attempts', heartbeatTimeout = heartbeat}
      , correlation = Just "correlation"
      , idempotency = Just "idempotency"
      }

invocation :: ActivityInvocation
invocation = invocationWith 2 2

failureOf :: ActivityFailureFields -> ActivityFailure
failureOf = either (error . T.unpack) id . activityFailure

obj :: [(Text, Json)] -> Json
obj = Object

-- ---------------------------------------------------------------------------
-- Local custody

-- | @LocalDispatch(path, instance=..., activity_queues=...)@.
localDispatch :: FilePath -> Text -> [(Text, Text)] -> IO LocalDispatch
localDispatch path inst queues = mask_ $ do
  dispatch <- openLocalDispatch path inst defaultLocalDispatchOptions {activityQueues = queues}
  remember path (Local.closeLocalDispatch dispatch)
  pure dispatch

-- | @LocalWorkerDispatch(path, queues=queues, worker_id=worker_id)@.
localWorker :: FilePath -> [Text] -> Text -> IO WorkerDispatch
localWorker path queues worker = mask_ $ do
  opened' <- openLocalWorkerDispatch path defaultLocalWorkerOptions {workerQueues = queues, workerId = Just worker}
  remember path (Local.close opened')
  pure (Local.toWorkerDispatch opened')

-- | What 'localDispatch' and 'localWorker' opened, by path, with what closes
-- it, so that 'withScratch' closes it before removing the directory. The
-- reference's sessions and workers hold no connection between operations;
-- the port's keep a pool, and one left open closes it when the garbage
-- collector finalizes it. The last of those closes deletes the WAL file at
-- an arbitrary moment: during the scratch directory's removal, that removal
-- fails on the vanished file. Keyed by path, so examples running side by
-- side close only their own. unsafePerformIO (NOINLINE): one registry per
-- test process, reached from helpers that share no argument.
opened :: IORef [([FilePath], IO ())]
opened = unsafePerformIO (newIORef [])
{-# NOINLINE opened #-}

remember :: FilePath -> IO () -> IO ()
remember path closer = atomicModifyIORef' opened (\entries -> ((splitDirectories path, closer) : entries, ()))

-- | Close what was opened under the directory, most recent first.
closeOpenedIn :: FilePath -> IO ()
closeOpenedIn dir = do
  let inside (path, _) = splitDirectories dir `isPrefixOf` path
  mine <- atomicModifyIORef' opened (\entries -> let (here, elsewhere) = partition inside entries in (elsewhere, here))
  mapM_ snd mine

-- | @_assert_task(path, epoch=epoch)@: the only task row is at this epoch.
assertTask :: FilePath -> Integer -> IO ()
assertTask path epoch = do
  rows <-
    bracket (Sql.open (T.pack path)) Sql.close $ \db ->
      bracket (Sql.prepare db "SELECT epoch FROM impetus_local_dispatch_tasks") Sql.finalize $ \statement ->
        Sql.step statement >>= \case
          Row -> Just <$> Sql.columns statement
          Done -> pure Nothing
  unless (rows == Just [SQLInteger (fromInteger epoch)]) $
    expectationFailure ("unexpected task row " <> show rows)

-- | @SELECT details FROM impetus_local_dispatch_tasks WHERE occurrence=1@,
-- decoded.
rawDetails :: FilePath -> IO Json
rawDetails path =
  bracket (Sql.open (T.pack path)) Sql.close $ \db ->
    bracket (Sql.prepare db "SELECT details FROM impetus_local_dispatch_tasks WHERE occurrence=1") Sql.finalize $ \statement ->
      Sql.step statement >>= \case
        Row ->
          Sql.columns statement >>= \case
            [SQLText text] -> either fail pure (parseJson surrogateRefusingLoads (TE.encodeUtf8 text))
            other -> fail ("unexpected details " <> show other)
        Done -> fail "no task row"

-- | @json.loads(attempt.attempt_id)[1]@.
occurrenceOf :: ActivityAttempt -> Int
occurrenceOf attempt = case parseJson surrogateRefusingLoads (TE.encodeUtf8 attempt.attemptId) of
  Right (Array [_, Int o]) -> fromInteger o
  other -> error ("unexpected attempt id " <> show other)

-- ---------------------------------------------------------------------------
-- Servers

-- | @RunningServer(server)@: 'serveForever' on its own thread.
data RunningServer = RunningServer
  { server :: ZeroMQDispatchServer
  , finished :: MVar (Either SomeException ())
  , endpoint :: Text
  }

startRunning :: ZeroMQDispatchServer -> IO RunningServer
startRunning server = do
  finished <- newEmptyMVar
  _ <- forkIO (try (serveForever server) >>= putMVar finished)
  endpoint <- waitReady server 5
  pure RunningServer {server, finished, endpoint}

-- | @close()@: stop, join within 5 s, and re-raise the serving error.
closeRunning :: RunningServer -> IO ()
closeRunning running = do
  stopServer running.server
  timeout 5000000 (readMVar running.finished) >>= \case
    Nothing -> expectationFailure "the server thread did not stop"
    Just (Left e) -> throwIO e
    Just (Right ()) -> pure ()

withRunning :: IO ZeroMQDispatchServer -> (RunningServer -> IO a) -> IO a
withRunning make = bracket (make >>= startRunning) closeRunning

-- ---------------------------------------------------------------------------
-- Certificates

data Certificates = Certificates
  { serverPublic :: FilePath
  , serverSecret :: FilePath
  , clientSecret :: FilePath
  , strangerSecret :: FilePath
  , otherServerPublic :: FilePath
  , allowed :: FilePath
  }

-- | The @curve_certificates@ fixture.
curveCertificates :: FilePath -> IO Certificates
curveCertificates scratch = do
  let certificates = scratch </> "certificates"
      allowed = scratch </> "allowed"
  createDirectory certificates
  createDirectory allowed
  (serverPublic, serverSecret) <- createCertificates certificates "server"
  (clientPublic, clientSecret) <- createCertificates certificates "client"
  (_, strangerSecret) <- createCertificates certificates "stranger"
  (otherServerPublic, _) <- createCertificates certificates "other-server"
  copyFile clientPublic (allowed </> "client.key")
  pure Certificates {serverPublic, serverSecret, clientSecret, strangerSecret, otherServerPublic, allowed}

-- ---------------------------------------------------------------------------
-- Fault injection

-- | @DelayedProvider(provider, delays)@: each operation commits, then sleeps
-- the delay popped for its name (reply-loss windows after custody).
delayedProvider :: IORef (Map Text Double) -> WorkerDispatch -> WorkerDispatch
delayedProvider delays provider =
  WorkerDispatch
    { claim = provider.claim <* pause "claim"
    , heartbeat = \attempt details -> provider.heartbeat attempt details <* pause "heartbeat"
    , complete = \attempt result -> provider.complete attempt result <* pause "complete"
    , fail = \attempt failure -> provider.fail attempt failure <* pause "fail"
    , wait = provider.wait
    , close = provider.close
    }
  where
    pause key = do
      seconds <- atomicModifyIORef' delays (\m -> (Map.delete key m, Map.findWithDefault 0 key m))
      when (seconds > 0) $ threadDelay (round (seconds * 1000000))

-- | Count each operation's calls by name.
countingProvider :: IORef (Map Text Int) -> WorkerDispatch -> WorkerDispatch
countingProvider calls provider =
  WorkerDispatch
    { claim = count "claim" >> provider.claim
    , heartbeat = \attempt details -> count "heartbeat" >> provider.heartbeat attempt details
    , complete = \attempt result -> count "complete" >> provider.complete attempt result
    , fail = \attempt failure -> count "fail" >> provider.fail attempt failure
    , wait = provider.wait
    , close = provider.close
    }
  where
    count key = atomicModifyIORef' calls (\m -> (Map.insertWith (+) key 1 m, ()))

-- ---------------------------------------------------------------------------
-- Server processes

-- | Set to @server@ (the CLI, as @python -m petrus.motus.transport.zeromq@)
-- or @delayed@ (the reference's delayed-completion server script), the
-- suite's executable runs that process instead of the specs.
serverModeVariable :: String
serverModeVariable = "PETRUS_ZEROMQ_TEST_SERVER"

data ServerProcess = ServerProcess
  { handle :: ProcessHandle
  , readiness :: Json
  }

-- | Start a server process and read its readiness line: the suite itself
-- re-executed in a mode (@Left mode@), or the reference's module
-- (@Right python@).
startServerProcess :: Either String Python -> [String] -> IO ServerProcess
startServerProcess which arguments = do
  self <- getExecutablePath
  environment <- getEnvironment
  let process = case which of
        Left mode ->
          (proc self arguments) {env = Just ((serverModeVariable, mode) : filter ((/= serverModeVariable) . fst) environment)}
        Right (python, root) -> (proc python ("-m" : "petrus.motus.transport.zeromq" : arguments)) {cwd = Just root}
  (_, Just out, _, handle) <- createProcess process {std_out = CreatePipe}
  hSetBinaryMode out True
  line <- timeout 10000000 (hGetLine out)
  case line >>= either (const Nothing) Just . parseJson surrogateRefusingLoads . BC.pack of
    Just readiness -> pure ServerProcess {handle, readiness}
    Nothing -> do
      killProcess handle
      error ("the server process did not announce readiness: " <> show line)

-- | @process.kill(); process.communicate()@.
killProcess :: ProcessHandle -> IO ()
killProcess handle =
  getPid handle >>= \case
    Nothing -> pure ()
    Just pid -> do
      _ <- try @SomeException (signalProcess sigKILL pid)
      _ <- waitForProcess handle
      pure ()

-- | @process.terminate(); process.communicate()@: the exit status.
stopServerProcess :: ProcessHandle -> IO ExitCode
stopServerProcess handle =
  getPid handle >>= \case
    Nothing -> waitForProcess handle
    Just pid -> do
      _ <- try @SomeException (signalProcess sigTERM pid)
      timeout 10000000 (waitForProcess handle) >>= \case
        Just code -> pure code
        Nothing -> killProcess handle >> pure (ExitFailure (-9))

-- ---------------------------------------------------------------------------
-- Raw sockets

-- | A raw DEALER (@zmq.Context().socket(zmq.DEALER)@, linger 0): each
-- exchange sends the frames and answers the reply's frames (5 s at most).
withRawDealer :: Text -> (([ByteString] -> IO [ByteString]) -> IO a) -> IO a
withRawDealer endpoint body =
  bracket N.newContext N.terminateContext $ \context ->
    bracket (N.newSocket context N.Dealer) N.closeSocket $ \socket -> do
      N.setIntOption socket N.Linger 0
      N.connect socket endpoint
      body $ \frames -> do
        _ <- N.sendFrames socket frames Nothing
        N.receiveFrames socket (Just 5000000) >>= \case
          Just reply -> pure reply
          Nothing -> expectationFailure "no reply within 5 s" >> pure []

-- ---------------------------------------------------------------------------
-- Files

-- | A fresh, short scratch directory under the system temporary
-- directory, removed afterwards, once what 'localDispatch' and 'localWorker'
-- opened in it is closed.
withScratch :: (FilePath -> IO a) -> IO a
withScratch =
  bracket
    ( do
        base <- getTemporaryDirectory
        (path, h) <- openTempFile base "pzq"
        hClose h
        removeFile path
        createDirectory path
        pure path
    )
    (\dir -> closeOpenedIn dir >> removeDirectoryRecursive dir)

-- | @f"ipc://{tmp_path}/{name}"@.
ipcEndpoint :: FilePath -> String -> Text
ipcEndpoint scratch name = T.pack ("ipc://" <> scratch </> name)

-- | Poll for a file for up to the seconds.
waitForFile :: FilePath -> Double -> IO Bool
waitForFile path seconds = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop = do
        present <- doesFileExist path
        now <- getMonotonicTime
        if present then pure True else if now >= deadline then pure False else threadDelay 10000 >> loop
  loop

-- ---------------------------------------------------------------------------
-- Errors

matches :: Text -> Text -> Bool
matches fragment message = fragment `T.isInfixOf` message

-- | @pytest.raises(ValueError, match=...)@ (a literal fragment).
valueErrorMatching :: Text -> Selector ValueError
valueErrorMatching fragment (ValueError m) = matches fragment m

runtimeErrorMatching :: Text -> Selector RuntimeError
runtimeErrorMatching fragment (RuntimeError m) = matches fragment m

-- | @pytest.raises(ConnectionError, match="{operation}.*not acknowledged")@
-- against the synchronous client.
notAcknowledged :: Text -> Selector ConnectionError
notAcknowledged operation = \case
  NotAcknowledged m -> matches ("'" <> operation <> "'") m && matches "not acknowledged" m
  OperationUncertain _ -> False

-- | @pytest.raises(OperationUncertain, match=...)@.
uncertainMatching :: Text -> Selector ConnectionError
uncertainMatching fragment = \case
  OperationUncertain m -> matches fragment m
  NotAcknowledged _ -> False

-- ---------------------------------------------------------------------------
-- The reference

-- | The reference interpreter and the upstream root it runs in.
type Python = (FilePath, FilePath)

-- | Run the example against the pinned reference: its interpreter
-- (provisioned by @scripts/upstream-python@ on first use) and the upstream
-- root. Fails loudly, never skips, when the reference cannot be provisioned.
withReference :: (Python -> IO ()) -> IO ()
withReference body = do
  python <- pythonExecutable
  root <- upstreamPetrus
  body (python, root)

interopScript :: IO FilePath
interopScript = makeAbsolute ("test" </> "interop" </> "zeromq_interop.py")

-- | Start @zeromq_interop.py@ (cwd = the upstream root), stdout captured.
startInterop :: Python -> [String] -> IO (ProcessHandle, Handle)
startInterop (python, root) arguments = do
  script <- interopScript
  (_, Just out, _, handle) <- createProcess (proc python (script : arguments)) {cwd = Just root, std_out = CreatePipe}
  hSetBinaryMode out True
  pure (handle, out)

-- | Run @zeromq_interop.py@ to completion: its stdout as JSON.
runInterop :: Python -> [String] -> IO Json
runInterop python arguments = do
  (handle, out) <- startInterop python arguments
  bytes <- BS.hGetContents out
  waitForProcess handle >>= \case
    ExitSuccess -> pure ()
    ExitFailure n -> expectationFailure ("zeromq_interop.py " <> unwords arguments <> " exited " <> show n)
  either (\e -> error ("zeromq_interop.py printed invalid JSON: " <> e)) pure (parseJson surrogateRefusingLoads bytes)
