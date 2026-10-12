-- | Fixtures shared by the Worker specs: the reference tests' strict fake
-- provider, attempts, event capture, and the re-executed worker process.
module Petrus.Motus.WorkerSupport
  ( -- * Fake custody
    StrictProvider (..)
  , newStrictProvider
  , strictDispatch
  , providerAttempt
  , asyncAttempt
    -- * Output
  , EventLog
  , newEventLog
  , eventSink
  , eventsOf
  , quietOptions
    -- * Worker processes
  , workerModeVariable
  , subprocessRegistries
  , startLocalWorker
  , waitForFile
  , stopProcess
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import GHC.Clock (getMonotonicTime)
import Petrus.Activity
import Petrus.Json (Json (..), parseJson, surrogateRefusingLoads)
import Petrus.Motus.Dispatch
import Petrus.Motus.Worker
import System.Directory (doesFileExist)
import System.Environment (getEnvironment, getExecutablePath)
import System.IO (Handle, hGetLine, hSetBinaryMode)
import System.Process
import System.Timeout (timeout)
import Test.Hspec hiding (context)
import Petrus.TestSupport (valid)

-- | The reference's @StrictWorkerDispatch@: scripted attempts and recorded
-- custody calls.
data StrictProvider = StrictProvider
  { attempts :: IORef [ActivityAttempt]
  , completed :: IORef [(ActivityAttempt, Json)]
  , failed :: IORef [(ActivityAttempt, AttemptFailure)]
  , heartbeats :: IORef [(ActivityAttempt, Maybe Json)]
  , closed :: IORef Bool
  }

newStrictProvider :: [ActivityAttempt] -> IO StrictProvider
newStrictProvider scripted =
  StrictProvider <$> newIORef scripted <*> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef False

strictDispatch :: StrictProvider -> WorkerDispatch
strictDispatch p =
  WorkerDispatch
    { claim = atomicModifyIORef' p.attempts (\case [] -> ([], Nothing); next : rest -> (rest, Just next))
    , heartbeat = \attempt details -> do
        modifyIORef' p.heartbeats (++ [(attempt, details)])
        pure (maybe attempt.latestDetails id details)
    , complete = \attempt result -> modifyIORef' p.completed (++ [(attempt, result)])
    , fail = \attempt failure -> modifyIORef' p.failed (++ [(attempt, failure)])
    , wait = \_ -> pure False
    , close = writeIORef p.closed True
    }

-- | The runtime tests' @attempt(activity, *, details, instance)@.
providerAttempt :: Text -> Json -> Maybe Text -> ActivityAttempt
providerAttempt activity details inst =
  either (error . T.unpack) id $
    activityAttempt "provider-attempt" "provider-epoch" "provider-claimant" "cpu" (valid (invocation activity Null)) details inst

-- | The async tests' @_attempt(number)@.
asyncAttempt :: Int -> ActivityAttempt
asyncAttempt number =
  either (error . T.unpack) id $
    activityAttempt
      ("attempt-" <> tshow number)
      ("epoch-" <> tshow number)
      "claimant"
      "io"
      (valid (invocation "io" (Object [("item", Object [("value", Int (toInteger number))])])))
      Null
      (Just ("instance-" <> tshow number))

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | Captured Worker event lines.
newtype EventLog = EventLog (IORef [Json])

newEventLog :: IO EventLog
newEventLog = EventLog <$> newIORef []

eventSink :: EventLog -> Json -> IO ()
eventSink (EventLog ref) event = atomicModifyIORef' ref (\events -> (events ++ [event], ()))

eventsOf :: EventLog -> IO [Json]
eventsOf (EventLog ref) = readIORef ref

-- | Options whose event lines go to a log instead of stdout.
quietOptions :: EventLog -> WorkerOptions
quietOptions events = defaultWorkerOptions {output = eventSink events}

-- | Set in a re-executed test binary to make it a Local worker process.
workerModeVariable :: String
workerModeVariable = "PETRUS_MOTUS_TEST_WORKER"

-- | The reference's @subprocess_activities@: a crash mode that heartbeats
-- @{"cursor": 7}@ on its first epoch, signals, and hangs; a drain mode that
-- signals and runs a quarter second; both answer the recovered cursor.
subprocessRegistries :: Map Text (IO (Map Text Activity))
subprocessRegistries =
  Map.fromList [("tests.petrus.motus.worker.test_worker_runtime:subprocess_activities", pure (Map.fromList [("work", work)]))]
  where
    work inv context = do
      let field key = case inv.input of
            Object members -> lookup key members
            _ -> Nothing
          barrier = case field "barrier" of
            Just (String p) -> T.unpack p
            _ -> error "barrier"
          mode = field "mode"
      latest <- context.latestDetails
      when (mode == Just (String "crash") && latest == Null) $ do
        _ <- context.heartbeat (Just (Object [("cursor", Int 7)]))
        TIO.writeFile barrier "claimed"
        threadDelay 3600000000
      when (mode == Just (String "drain")) $ do
        TIO.writeFile barrier "running"
        threadDelay 250000
      now <- context.latestDetails
      pure $ Object [("cursor", case now of Object members -> maybe Null id (lookup "cursor" members); _ -> Null)]

-- | The reference's @_start_local_worker@: this test binary, re-executed as
-- a Local worker on the file, ready within ten seconds.
startLocalWorker :: FilePath -> IO (ProcessHandle, Handle)
startLocalWorker path = do
  self <- getExecutablePath
  environment <- getEnvironment
  (_, Just out, _, handle) <-
    createProcess
      (proc self ["--provider", "local", "--path", path, "--registry", "tests.petrus.motus.worker.test_worker_runtime:subprocess_activities", "--poll-interval", "0.02", "+RTS", "-M2G", "-RTS"])
        { std_out = CreatePipe
        , env = Just ((workerModeVariable, "1") : filter ((/= workerModeVariable) . fst) environment)
        }
  hSetBinaryMode out True
  line <- timeout 10000000 (hGetLine out)
  case line of
    Nothing -> stopProcess handle >> expectationFailure "Local Worker did not become ready"
    Just text -> case parseJson surrogateRefusingLoads (BS.pack (map (toEnum . fromEnum) text)) of
      Right (Object members) | lookup "ready" members == Just (Bool True) -> pure ()
      other -> stopProcess handle >> expectationFailure ("unexpected ready line: " <> show other)
  pure (handle, out)

-- | The reference's @_wait_for_file@.
waitForFile :: FilePath -> ProcessHandle -> IO ()
waitForFile path handle = do
  deadline <- (+ 10) <$> getMonotonicTime
  let loop = do
        present <- doesFileExist path
        unless present $ do
          exited <- getProcessExitCode handle
          unless (exited == Nothing) $ throwIO (userError "worker exited before the barrier")
          now <- getMonotonicTime
          when (now > deadline) $ throwIO (userError "barrier timed out")
          threadDelay 10000
          loop
  loop

-- | Kill a still-running worker process and reap it.
stopProcess :: ProcessHandle -> IO ()
stopProcess handle =
  getProcessExitCode handle >>= \case
    Nothing -> terminateProcess handle >> () <$ waitForProcess handle
    Just _ -> pure ()
