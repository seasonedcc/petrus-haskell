{-# LANGUAGE ScopedTypeVariables #-}

-- | The provider-neutral Activity Worker runtime (a port of
-- @petrus.motus.worker@).
--
-- A Worker claims fenced 'ActivityAttempt's from a custody provider, runs
-- the registered Activity for each, and reports exactly one terminal per
-- Attempt. It is Petri-agnostic: it knows Activities, Attempts, and the
-- 'WorkerDispatch' custody surface, nothing else.
--
-- = Two front doors, one Activity type
--
-- * 'Worker' is the reference's synchronous @Worker@: one Activity at a
--   time on the calling thread, a driving guard that refuses concurrent
--   driving, a bounded pump ('runAvailable') that never waits or closes,
--   and a terminal refusal that is reported and swallowed.
-- * 'AsyncWorker' is the reference's @AsyncWorker@: exactly @concurrency@
--   Activities in flight, sequential claims into the lowest free slot,
--   custody operations that always reach a definite result ('owned'), and a
--   terminal refusal that stops the whole Worker. Custody comes either from
--   the sync bridge ('syncBridgeAccess': one dedicated thread per slot, each
--   owning the provider its factory built) or from a native 'WorkerAccess'
--   (the ZeroMQ transport's).
--
-- Haskell has no function colours, so both take the same 'Activity'; the
-- reference's sync/async registry checks have nothing to check.
--
-- = Cancellation
--
-- 'runAsyncWorker' absorbs asynchronous exceptions thrown at its caller the
-- way the reference's @run@ absorbs @CancelledError@: the first one stops
-- admission, a claim in progress is still executed and terminalized,
-- running Activities drain, custody closes, and only then is the remembered
-- exception rethrown. A Worker error that happens meanwhile wins over it.
--
-- = Output
--
-- Supervisors barrier on the reference's stdout lines (CPython default
-- @json.dumps@ spelling, members in the reference's order). They go through
-- 'WorkerOptions.output', which defaults to 'stdoutEvents'.
module Petrus.Motus.Worker
  ( -- * Activities
    Activity
  , Resolver
  , WorkerOptions (..)
  , defaultWorkerOptions
  , stdoutEvents
  , normalizeResult
    -- * Synchronous Worker
  , Worker
  , newWorker
  , workerIdOf
  , runWorker
  , runAvailable
  , closeWorker
  , stopWorker
    -- * Asynchronous Worker
  , WorkerAccess (..)
  , AsyncWorker
  , newAsyncWorker
  , asyncWorkerFromAccess
  , asyncWorkerIdOf
  , runAsyncWorker
  , stopAsyncWorker
    -- ** The sync bridge
  , LaneSpawner
  , forkLane
  , syncBridgeAccess
    -- ** Custody atomicity
  , owned
    -- * Errors (the reference's built-in exception types)
  , ValueError (..)
  , RuntimeError (..)
  , LookupError (..)
  , CancelledError (..)
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM, unless, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.IORef
import Data.List (insert)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Json
import Petrus.Motus.Dispatch
import Petrus.Motus.Dispatch.Inline (Activity)
import Petrus.Motus.PythonException (exceptionMessage)
import Petrus.Json.Python (pythonStrListRepr, pythonStrRepr)
import Petrus.Motus.PythonException (CancelledError (..), LookupError (..), RuntimeError (..), ValueError (..))
import Petrus.Telemetry (TelemetryLogger, getLogger, maxRssMb, spanSet, withSpan)
import Petrus.Telemetry qualified as Telemetry
import System.IO (hFlush, stdout)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Process (getProcessID)

-- ---------------------------------------------------------------------------
-- Options

-- | A scoped resolver: @(instance, activity name)@ to an implementation, or
-- 'Nothing' to fall back to the default registry.
type Resolver = Text -> Text -> IO (Maybe Activity)

-- | What both Workers take besides custody and the default registry.
data WorkerOptions = WorkerOptions
  { resolver :: Maybe Resolver
  , workerId :: Maybe Text
  -- ^ The operational label; defaults to @worker-<pid>@ (@async-worker-<pid>@).
  , output :: Json -> IO ()
  -- ^ Where the supervisor-facing event lines go.
  }

-- | No resolver, the default label, 'stdoutEvents'.
defaultWorkerOptions :: WorkerOptions
defaultWorkerOptions = WorkerOptions {resolver = Nothing, workerId = Nothing, output = stdoutEvents}

-- | Serializes 'stdoutEvents' lines across workers. unsafePerformIO
-- (NOINLINE): the process has one stdout, so its lock is process-wide.
stdoutLock :: MVar ()
stdoutLock = unsafePerformIO (newMVar ())
{-# NOINLINE stdoutLock #-}

-- | @print(json.dumps(event), flush=True)@: one line per event, CPython's
-- default spelling, never interleaved.
stdoutEvents :: Json -> IO ()
stdoutEvents event = case dumps defaultDumps event of
  Left _ -> pure ()
  Right bytes -> withMVar stdoutLock $ \_ -> BS.hPut stdout (bytes <> BS8.singleton '\n') >> hFlush stdout

-- | @json.loads(json.dumps(result, allow_nan=False))@: a non-finite number
-- (or an integer past CPython's digit limit) is refused with the
-- reference's @ValueError@ text.
normalizeResult :: Json -> IO Json
normalizeResult result = case dumps defaultDumps {allowNan = False} result of
  Left problem -> throwIO (ValueError (T.pack (encodeErrorMessage problem)))
  Right bytes -> either (throwIO . ValueError . T.pack) pure (parseJson surrogateRefusingLoads bytes)

validateRegistry :: Map Text Activity -> Maybe Resolver -> Text -> IO (Map Text Activity)
validateRegistry activities resolver' emptyMessage = do
  when (any T.null (Map.keys activities)) $
    throwIO (ValueError "Worker activities must map non-empty string names to callables")
  when (Map.null activities && not (isJust resolver')) $ throwIO (ValueError emptyMessage)
  pure activities

resolveActivity :: Map Text Activity -> Maybe Resolver -> ActivityAttempt -> IO Activity
resolveActivity activities resolver' attempt = do
  scoped <- case resolver' of
    Nothing -> pure Nothing
    Just resolve -> case attempt.instance' of
      Nothing -> throwIO (LookupError "Worker scoped resolver requires an Activity Attempt instance")
      Just inst -> resolve inst attempt.invocation.activity
  case scoped <|> Map.lookup attempt.invocation.activity activities of
    Just implementation -> pure implementation
    Nothing ->
      throwIO
        ( LookupError
            ( "no activity implementation for "
                <> pythonStrRepr attempt.invocation.activity
                <> ": this worker implements "
                <> pythonStrListRepr (Map.keys activities)
            )
        )

-- | What the provider is told about a failed Activity: an 'ActivityError'
-- is unwrapped to its failure, anything else is handed over for the
-- provider to classify.
failureReport :: SomeException -> AttemptFailure
failureReport err = case fromException err of
  Just (ActivityError failure) -> FailureClassified failure
  Nothing -> FailureException err

impetus :: TelemetryLogger
impetus = getLogger "impetus" Nothing

activitySpanFields :: Text -> ActivityAttempt -> [(Text, Json)]
activitySpanFields label attempt =
  [ ("worker", String label)
  , ("queue", String attempt.queue)
  , ("activity", String attempt.invocation.activity)
  , ("attempt", String attempt.attemptId)
  , ("epoch", String attempt.epoch)
  , ("claimant", String attempt.claimant)
  ]

refusedLine :: Text -> ActivityAttempt -> SomeException -> Json
refusedLine label attempt refused =
  Object [("worker", String label), ("refused", String attempt.attemptId), ("error", String (T.strip (exceptionMessage refused)))]

processedLine :: Text -> ActivityAttempt -> Text -> Json
processedLine label attempt outcome =
  Object
    [ ("worker", String label)
    , ("processed", String attempt.attemptId)
    , ("activity", String attempt.invocation.activity)
    , ("outcome", String outcome)
    ]

isAsyncException :: SomeException -> Bool
isAsyncException err = isJust (fromException err :: Maybe SomeAsyncException)

defaultLabel :: Text -> IO Text
defaultLabel prefix = (\pid -> prefix <> T.pack (show pid)) <$> getProcessID

-- ---------------------------------------------------------------------------
-- Synchronous Worker

-- | Runs registered Activities one at a time over a 'WorkerDispatch'.
data Worker = Worker
  { provider :: WorkerDispatch
  , activities :: Map Text Activity
  , resolver :: Maybe Resolver
  , label :: Text
  , output :: Json -> IO ()
  , stopping :: IORef Bool
  , driving :: MVar ()
  , closed :: IORef Bool
  }

-- | Validate as the reference's constructor does: names are non-empty, and
-- an empty registry needs a resolver.
newWorker :: WorkerDispatch -> Map Text Activity -> WorkerOptions -> IO Worker
newWorker provider activities options = do
  Telemetry.validateTelemetryEnvironment
  registry <- validateRegistry activities options.resolver "Worker requires default Activities or a scoped resolver"
  label <- maybe (defaultLabel "worker-") pure options.workerId
  Worker provider registry options.resolver label options.output <$> newIORef False <*> newMVar () <*> newIORef False

-- | The Worker's operational label.
workerIdOf :: Worker -> Text
workerIdOf w = w.label

-- | Stop new claims; an Activity already running still terminalizes.
stopWorker :: Worker -> IO ()
stopWorker w = atomicWriteIORef w.stopping True

-- | Claim and execute until stopped, waiting @poll interval@ seconds on the
-- provider when nothing is claimable; then close custody. Errors from
-- @claim@ and @wait@ propagate (custody still closes).
runWorker :: Worker -> Double -> IO ()
runWorker w pollInterval = do
  when (pollInterval < 0) $ throwIO (ValueError "Worker poll interval must be non-negative")
  startDriving w
  let body = do
        Telemetry.emit impetus "worker_started" [("worker", String w.label), ("concurrency", Int 1)]
        w.output (Object [("ready", Bool True), ("worker", String w.label)])
        let loop = do
              stopped <- readIORef w.stopping
              unless stopped $ do
                _ <- drain w Nothing
                stoppedNow <- readIORef w.stopping
                unless stoppedNow (void (w.provider.wait pollInterval))
                loop
        loop
  body `finally` (closeOnce w `finally` (putMVar w.driving () >> Telemetry.emit impetus "worker_stopped" [("worker", String w.label), ("concurrency", Int 1)]))

-- | Execute at most @limit@ immediately claimable Attempts without waiting
-- or closing custody; answer how many ran.
runAvailable :: Worker -> Int -> IO Int
runAvailable w limit = do
  when (limit < 0) $ throwIO (ValueError "Worker run_available limit must be a non-negative integer")
  startDriving w
  drain w (Just limit) `finally` putMVar w.driving ()

-- | Close custody once; no further driving is permitted. A failing close
-- still leaves the Worker closed.
closeWorker :: Worker -> IO ()
closeWorker w =
  tryTakeMVar w.driving >>= \case
    Nothing -> throwIO (RuntimeError "Worker is already being driven")
    Just () -> closeOnce w `finally` putMVar w.driving ()

startDriving :: Worker -> IO ()
startDriving w =
  tryTakeMVar w.driving >>= \case
    Nothing -> throwIO (RuntimeError "Worker is already being driven")
    Just () -> do
      isClosed <- readIORef w.closed
      when isClosed $ putMVar w.driving () >> throwIO (RuntimeError "Worker is closed")

closeOnce :: Worker -> IO ()
closeOnce w = do
  isClosed <- readIORef w.closed
  unless isClosed $ writeIORef w.closed True >> w.provider.close

drain :: Worker -> Maybe Int -> IO Int
drain w limit = go 0
  where
    go processed = do
      stopped <- readIORef w.stopping
      if stopped || maybe False (processed >=) limit
        then pure processed
        else
          w.provider.claim >>= \case
            Nothing -> pure processed
            Just attempt -> execute w attempt >> go (processed + 1)

execute :: Worker -> ActivityAttempt -> IO ()
execute w attempt = withSpan impetus "worker_activity" (activitySpanFields w.label attempt) $ \span' -> do
  let inv = attempt.invocation
  outcome <- try $ do
    implementation <- resolveActivity w.activities w.resolver attempt
    latest <- newIORef attempt.latestDetails
    let context =
          ActivityExecutionContext
            { attemptId = attempt.attemptId
            , epoch = attempt.epoch
            , claimant = attempt.claimant
            , instance' = attempt.instance'
            , latestDetails = readIORef latest
            , heartbeat = \details -> do
                accepted <- w.provider.heartbeat attempt details
                writeIORef latest accepted
                pure accepted
            }
    implementation inv context >>= normalizeResult
  outcome' <- case outcome of
    Left err | isAsyncException err -> throwIO err
    other -> pure other
  reported <- try $ case outcome' of
    Right result -> w.provider.complete attempt result
    Left err -> w.provider.fail attempt (failureReport err)
  case reported of
    Left (refused :: SomeException)
      | isAsyncException refused -> throwIO refused
      | otherwise -> do
          w.output (refusedLine w.label attempt refused)
          spanSet span' [("outcome", String "refused")]
    Right () -> do
      let outcomeText = either (const "failed") (const "completed") outcome'
      rss <- maxRssMb
      spanSet span' [("outcome", String outcomeText), ("max_rss_mb", Float rss)]
      w.output (processedLine w.label attempt outcomeText)

-- ---------------------------------------------------------------------------
-- Custody atomicity

-- | Run an action on its own thread and wait for it, absorbing asynchronous
-- exceptions thrown at the waiter (each is reported to the callback); answer
-- the action's outcome and the first absorbed exception.
absorbing :: (SomeException -> IO ()) -> IO a -> IO (Either SomeException a, Maybe SomeException)
absorbing onCancel action = mask_ $ do
  done <- newEmptyMVar
  _ <- forkIOWithUnmask (\unmask -> try (unmask action) >>= putMVar done)
  let loop first =
        try (takeMVar done) >>= \case
          Right outcome -> pure (outcome, first)
          Left (cancelled :: SomeAsyncException) -> do
            let err = toException cancelled
            onCancel err
            loop (first <|> Just err)
  loop Nothing

-- | The reference's @_owned@: let a custody operation reach a definite
-- result even if its caller is cancelled. The operation's own error wins;
-- otherwise the first absorbed cancellation is rethrown after it settles.
owned :: IO a -> IO a
owned action =
  absorbing (const (pure ())) action >>= \case
    (Left err, _) -> throwIO err
    (Right _, Just cancelled) -> throwIO cancelled
    (Right value, Nothing) -> pure value

-- ---------------------------------------------------------------------------
-- Asynchronous Worker

-- | Slot-addressed custody for an 'AsyncWorker' (the reference's private
-- @_AsyncWorkerAccess@). Slots are @0 .. concurrency - 1@; every operation of
-- one slot is issued sequentially.
data WorkerAccess = WorkerAccess
  { ready :: IO ()
  , claim :: Int -> IO (Maybe ActivityAttempt)
  , heartbeat :: Int -> ActivityAttempt -> Maybe Json -> IO Json
  , complete :: Int -> ActivityAttempt -> Json -> IO ()
  , fail :: Int -> ActivityAttempt -> AttemptFailure -> IO ()
  , wait :: Int -> Double -> IO Bool
  , close :: IO ()
  }

-- | Runs Activities with bounded concurrency over slot-addressed custody.
data AsyncWorker = AsyncWorker
  { acquire :: IO WorkerAccess
  , activities :: Map Text Activity
  , resolver :: Maybe Resolver
  , concurrency :: Int
  , label :: Text
  , output :: Json -> IO ()
  , stopping :: IORef Bool
  }

-- | The reference's @AsyncWorker(provider_factory, ...)@: the sync bridge,
-- one dedicated thread per slot, each building its own provider.
newAsyncWorker :: IO WorkerDispatch -> Map Text Activity -> Int -> WorkerOptions -> IO AsyncWorker
newAsyncWorker factory activities concurrency options = do
  Telemetry.validateTelemetryEnvironment
  when (concurrency <= 0) $ throwIO (ValueError "AsyncWorker concurrency must be a positive integer")
  asyncWorkerFromAccess (syncBridgeAccess forkLane factory concurrency) activities concurrency options

-- | The reference's @AsyncWorker._from_async_access@: native custody,
-- acquired when the Worker runs.
asyncWorkerFromAccess :: IO WorkerAccess -> Map Text Activity -> Int -> WorkerOptions -> IO AsyncWorker
asyncWorkerFromAccess acquire activities concurrency options = do
  Telemetry.validateTelemetryEnvironment
  when (concurrency <= 0) $ throwIO (ValueError "AsyncWorker concurrency must be a positive integer")
  registry <- validateRegistry activities options.resolver "AsyncWorker requires default Activities or a scoped resolver"
  label <- maybe (defaultLabel "async-worker-") pure options.workerId
  AsyncWorker acquire registry options.resolver concurrency label options.output <$> newIORef False

-- | The Worker's operational label.
asyncWorkerIdOf :: AsyncWorker -> Text
asyncWorkerIdOf w = w.label

-- | Stop new admission; claims in progress and admitted Activities drain.
stopAsyncWorker :: AsyncWorker -> IO ()
stopAsyncWorker w = atomicWriteIORef w.stopping True

-- | Acquire custody, make it ready, run the admission loop until stopped,
-- drain, and close custody. The first error wins; an asynchronous exception
-- thrown at the caller stops the Worker and is rethrown once it has drained
-- and closed (unless an error happened, which is rethrown instead).
runAsyncWorker :: AsyncWorker -> Double -> IO ()
runAsyncWorker w pollInterval = do
  when (pollInterval < 0) $ throwIO (ValueError "AsyncWorker poll interval must be non-negative")
  cancelled <- newIORef False
  (outcome, absorbed) <- absorbing (\_ -> atomicWriteIORef cancelled True >> stopAsyncWorker w) (lifecycle w pollInterval cancelled)
  case (outcome, absorbed) of
    (Left err, _) -> throwIO err
    (Right (), Just err) -> throwIO err
    (Right (), Nothing) -> pure ()

lifecycle :: AsyncWorker -> Double -> IORef Bool -> IO ()
lifecycle w pollInterval cancelled = do
  let fields = [("worker", String w.label), ("concurrency", Int (toInteger w.concurrency))]
  Telemetry.emit impetus "worker_started" fields
  firstError <- newIORef (Nothing :: Maybe SomeException)
  let remember err = atomicModifyIORef' firstError (\current -> (current <|> Just err, ()))
      guarded action = try action >>= either (\err -> remember err >> stopAsyncWorker w) pure
  acquired <- try w.acquire
  case acquired of
    Left err -> remember err
    Right access -> do
      isCancelled <- readIORef cancelled
      unless isCancelled $ guarded $ do
        access.ready
        afterReady <- readIORef cancelled
        unless afterReady $ do
          w.output (Object [("ready", Bool True), ("worker", String w.label), ("concurrency", Int (toInteger w.concurrency))])
          coordinate w access pollInterval
      try access.close >>= either remember pure
  Telemetry.emit impetus "worker_stopped" fields
  readIORef firstError >>= maybe (pure ()) throwIO

-- | An admitted Activity: its slot and its eventual outcome.
data Task = Task {slot :: Int, outcome :: TMVar (Either SomeException ())}

-- | The admission loop: sequential claims into the lowest free slot, one
-- task per Attempt; a task error stops admission, drains the others, and is
-- rethrown (the first in creation order among those found done together).
coordinate :: AsyncWorker -> WorkerAccess -> Double -> IO ()
coordinate w access pollInterval = do
  active <- newIORef ([] :: [Task])
  freeRef <- newIORef [0 .. w.concurrency - 1]
  let stopped = readIORef w.stopping
      settle = do
        tasks <- readIORef active
        finished <- atomically (forM tasks (\task -> (,) task <$> tryReadTMVar task.outcome))
        let go [] = pure ()
            go ((task, result) : rest) = case result of
              Nothing -> go rest
              Just outcome -> do
                modifyIORef' active (filter (\other -> other.outcome /= task.outcome))
                either throwIO (const (modifyIORef' freeRef (insert task.slot))) outcome
                go rest
        go finished
      awaitAny = do
        tasks <- readIORef active
        atomically $ do
          results <- mapM (tryReadTMVar . (.outcome)) tasks
          unless (any isJust results) retry
      loop = do
        isStopped <- stopped
        unless isStopped $ do
          settle
          free <- readIORef freeRef
          case free of
            [] -> awaitAny >> settle >> loop
            slot : rest -> do
              writeIORef freeRef rest
              claimed <- owned (access.claim slot)
              case claimed of
                Just attempt -> do
                  task <- spawnTask slot attempt
                  modifyIORef' active (++ [task])
                  settle
                Nothing -> do
                  modifyIORef' freeRef (slot :)
                  settle
                  stillRunning <- not <$> stopped
                  when stillRunning (void (owned (access.wait slot pollInterval)))
              loop
      spawnTask slot attempt = do
        result <- newEmptyTMVarIO
        _ <- mask_ (forkIOWithUnmask (\unmask -> try (unmask (executeAsync w access slot attempt)) >>= atomically . putTMVar result))
        pure (Task slot result)
      drainAll = do
        tasks <- readIORef active
        atomically (mapM (readTMVar . (.outcome)) tasks)
  ( do
      loop
      results <- drainAll
      case [err | Left err <- results] of
        err : _ -> throwIO err
        [] -> pure ()
    )
    `onException` (stopAsyncWorker w >> void drainAll)

-- | The per-slot execution context: heartbeats are serialized and closed
-- before the terminal report.
data SlotContext = SlotContext
  { lock :: MVar ()
  , closing :: IORef Bool
  , open :: IORef Bool
  , latest :: IORef Json
  }

executeAsync :: AsyncWorker -> WorkerAccess -> Int -> ActivityAttempt -> IO ()
executeAsync w access slot attempt = withSpan impetus "worker_activity" (activitySpanFields w.label attempt) $ \span' -> do
  let inv = attempt.invocation
  state <- SlotContext <$> newMVar () <*> newIORef False <*> newIORef True <*> newIORef attempt.latestDetails
  let heartbeat details = do
        detached <- case details of
          Nothing -> pure Nothing
          Just value -> either dispatchError (pure . Just) (snapshotHeartbeatDetails value)
        withMVar state.lock $ \_ -> do
          isOpen <- readIORef state.open
          isClosing <- readIORef state.closing
          when (not isOpen || isClosing) $ throwIO (RuntimeError "Activity execution context is closed")
          accepted <- owned (access.heartbeat slot attempt detached)
          writeIORef state.latest accepted
          pure accepted
      context =
        ActivityExecutionContext
          { attemptId = attempt.attemptId
          , epoch = attempt.epoch
          , claimant = attempt.claimant
          , instance' = attempt.instance'
          , latestDetails = readIORef state.latest
          , heartbeat
          }
      closeContext = do
        writeIORef state.closing True
        withMVar state.lock (\_ -> writeIORef state.open False)
  outcome <-
    ( try (resolveActivity w.activities w.resolver attempt >>= \implementation -> implementation inv context >>= normalizeResult)
        >>= \case
          Left err
            | isAsyncException err ->
                pure (Left (toException (RuntimeError ("Activity cancelled: " <> cancelledMessage err))))
          other -> pure other
    )
      `finally` closeContext
  reported <- try $ case outcome of
    Right result -> owned (access.complete slot attempt result)
    Left err -> owned (access.fail slot attempt (failureReport err))
  case reported of
    Left (refused :: SomeException) -> do
      unless (isAsyncException refused) $ do
        w.output (refusedLine w.label attempt refused)
        spanSet span' [("outcome", String "refused")]
      throwIO refused
    Right () -> do
      let outcomeText = either (const "failed") (const "completed") outcome
      rss <- maxRssMb
      spanSet span' [("outcome", String outcomeText), ("max_rss_mb", Float rss)]
      w.output (processedLine w.label attempt outcomeText)

cancelledMessage :: SomeException -> Text
cancelledMessage err = case fromException err of
  Just (CancelledError message) -> message
  Nothing -> exceptionMessage err

-- ---------------------------------------------------------------------------
-- The sync bridge

-- | Start one lane's thread (given its slot number and body). The default,
-- 'forkLane', forks a thread; a failure to start is reported as the
-- reference reports a failed @Thread.start@.
type LaneSpawner = Int -> IO () -> IO ()

-- | Fork the lane's body on its own thread.
forkLane :: LaneSpawner
forkLane _ body = void (forkIO body)

-- | One slot's lane. A slot's calls are sequential, so its mailbox holds
-- one call at a time ('Nothing' ends the lane).
data Lane = Lane
  { number :: Int
  , mailbox :: MVar (Maybe (WorkerDispatch -> IO ()))
  , readiness :: MVar (Either SomeException ())
  , finished :: MVar ()
  }

newLane :: Int -> IO Lane
newLane number = Lane number <$> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar

-- | The lane's body: build the provider on this thread, then serve calls
-- until the end sentinel.
ownLane :: IO WorkerDispatch -> Lane -> IO ()
ownLane factory lane = flip finally (putMVar lane.finished ()) $ do
  built <- try factory
  case built of
    Left err -> putMVar lane.readiness (Left err)
    Right provider -> do
      putMVar lane.readiness (Right ())
      let serve =
            takeMVar lane.mailbox >>= \case
              Nothing -> pure ()
              Just call -> call provider >> serve
      serve

laneCall :: Lane -> (WorkerDispatch -> IO a) -> IO a
laneCall lane operation = do
  result <- newEmptyMVar
  putMVar lane.mailbox (Just (\provider -> try (operation provider) >>= putMVar result))
  takeMVar result >>= either (\(err :: SomeException) -> throwIO err) pure

laneClose :: Lane -> IO ()
laneClose lane = do
  alive <- isEmptyMVar lane.finished
  when alive $ laneCall lane (.close) `finally` (putMVar lane.mailbox Nothing >> readMVar lane.finished)

-- | Run actions concurrently and collect each outcome, in order.
concurrently' :: [IO ()] -> IO [Either SomeException ()]
concurrently' actions = do
  vars <- forM actions $ \action -> do
    var <- newEmptyMVar
    _ <- mask_ (forkIOWithUnmask (\unmask -> try (unmask action) >>= putMVar var))
    pure var
  mapM readMVar vars

-- | The reference's @_SynchronousWorkerAccess@: @concurrency@ lanes, each a
-- dedicated thread owning the provider the factory builds on it; slot @n@'s
-- calls all run on lane @n@'s thread. 'ready' starts the lanes in order and
-- waits for every factory; on any failure it closes the lanes that did
-- initialize and rethrows the first error (a start failure before a factory
-- failure).
syncBridgeAccess :: LaneSpawner -> IO WorkerDispatch -> Int -> IO WorkerAccess
syncBridgeAccess spawn factory concurrency = do
  lanes <- mapM newLane [0 .. concurrency - 1]
  initialized <- newIORef []
  let bySlot = Map.fromList [(l.number, l) | l <- lanes]
      -- The worker hands out slots from [0 .. concurrency - 1] only.
      call :: Int -> (WorkerDispatch -> IO a) -> IO a
      call slot operation = case Map.lookup slot bySlot of
        Just l -> laneCall l operation
        Nothing -> throwIO (RuntimeError ("no sync bridge lane for slot " <> T.pack (show slot)))
      start = do
        let launch [] = pure ([], Nothing)
            launch (next : rest) =
              try (spawn next.number (ownLane factory next)) >>= \case
                Left err -> pure ([], Just err)
                Right () -> do
                  (started, failure) <- launch rest
                  pure (next : started, failure)
        (started, startError) <- launch lanes
        results <- forM started (\l -> (,) l <$> readMVar l.readiness)
        let ok = [l | (l, Right ()) <- results]
            startupError = case [err | (_, Left err) <- results] of
              err : _ -> Just err
              [] -> Nothing
        case startError <|> startupError of
          Nothing -> writeIORef initialized ok
          Just err -> do
            _ <- concurrently' (map laneClose ok)
            throwIO err
  pure
    WorkerAccess
      { ready = start
      , claim = \slot -> call slot (.claim)
      , heartbeat = \slot attempt details -> call slot (\p -> p.heartbeat attempt details)
      , complete = \slot attempt result -> call slot (\p -> p.complete attempt result)
      , fail = \slot attempt failure -> call slot (\p -> p.fail attempt failure)
      , wait = \slot timeout -> call slot (\p -> p.wait timeout)
      , close = do
          ls <- readIORef initialized
          results <- concurrently' (map laneClose ls)
          case [err | Left err <- results] of
            err : _ -> throwIO err
            [] -> pure ()
      }
