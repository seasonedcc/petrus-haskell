-- | Shared fixtures for the Absurd Engine specs: the purpose-built
-- topology net of the reference's @tests/absurd_support.py@ (source ingress
-- -> @spark_work@ on a queue-subscribing Worker -> human gate -> done), its
-- @fixture_db@ / @worker_factory@ fixtures and its driving helpers
-- (@open_session@, @advance_until_blocked@, @drive_until_rest@,
-- @effects_for@, @arm_kill_switch@).
--
-- Workers come in two kinds, chosen per spec:
--
-- * 'PythonWorker' — the reference's own process,
--   @python -m petrus.motus.worker --provider absurd --registry
--   tests.absurd_support:activities@, exactly as upstream starts it (killed
--   by exact PID);
-- * 'HaskellWorker' — an in-process lane over this port's
--   'AbsurdWorkerDispatch' running the same registry ('sparkWork', a
--   Haskell twin of @activities()@), with the reference Worker's claim
--   loop and its stdout events. Killing it stops its thread mid-Activity
--   and drops its connection without reporting, which is what a SIGKILL
--   leaves on the database: a live lease on a dead claimant.
module Petrus.Engine.Absurd.Support
  ( -- * The topology net
    inbox
  , worked
  , approvals
  , done
  , ingress
  , work
  , operator
  , approve
  , issueColor
  , approvalColor
  , capability
  , topologyNet
  , topologyHandlers

    -- * Fixtures
  , Fixture (..)
  , absurdEngineSpec
  , ensureFixtureTables
  , SessionOptions (..)
  , sessionOptions
  , openSession
  , openSessionOn
  , closeSession
  , engineOptionsFor
  , absurdOptionsFor
  , freshTopo
  , freshIssue

    -- * Driving
  , advanceUntilBlocked
  , driveUntilRest
  , driveUntilRestWithin

    -- * Probes
  , effectsFor
  , armKillSwitch
  , scalarText
  , rowsText
  , recordName
  , recordNames
  , isRequested
  , isCompleted
  , requestedOf
  , completedOf
  , doneTokens
  , issue
  , approval

    -- * Workers
  , WorkerKind (..)
  , WorkerOptions (..)
  , workerOptions
  , Worker
  , startWorker
  , awaitEvent
  , awaitEventWithin
  , tryAwaitEvent
  , killWorker
  , terminateWorker
  , waitWorker
  , workerAlive
  , sparkWork

    -- * Selectors
  , engineRuntimeMatching
  , engineValueMatching
  , engineAnyMatching
  ) where

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, killThread, threadDelay)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar
import Control.Exception (SomeAsyncException, SomeException, bracket, finally, fromException, mask_, throwIO, try)
import Control.Monad (forM_, forever, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Numeric (showHex)
import Petrus.Activity
  ( ActivityDeclaration
  , ActivityFailureFields (..)
  , ActivityInvocation (..)
  , activityFailure
  , defaultExecutionPolicy
  , executionPolicy
  , policyFields
  )
import Petrus.Cel.Impetus (celCompilers)
import Petrus.Engine (Engine, EngineError (..), engineErrorMessage)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Absurd
import Petrus.Engine.Provider (OpenMode (..))
import Petrus.HistoryStore.Postgres (ensureSchema)
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), handlerTokens)
import Petrus.Activity qualified as Activity
import Petrus.Impetus.History.Records
import Petrus.Impetus.Instance (ImplementationRef (..))
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..), dumps, defaultDumps, lookupMember, parseJson, pythonLoads)
import Petrus.Motus.Dispatch (ActivityAttempt (..), AttemptFailure (..), WorkerDispatch (..))
import Petrus.Motus.Dispatch.Absurd
  ( defaultAbsurdWorkerOptions
  , ensureAbsurdSchema
  , openAbsurdWorkerDispatch
  , toWorkerDispatch
  )
import Petrus.Motus.Dispatch.Absurd qualified as Absurd
import Petrus.Postgres (Connection, query, textParam)
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport (PostgresTarget (..), postgresSpec, pythonExecutable, upstreamPetrus)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hClose, hSetBinaryMode, hSetBuffering)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (sigKILL, sigTERM, signalProcess)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (..)
  , createProcess
  , getPid
  , getProcessExitCode
  , proc
  , waitForProcess
  )
import System.Timeout (timeout)
import Test.Hspec

-- ---------------------------------------------------------------------------
-- The topology net (tests/absurd_support.py)

path' :: Text -> NetPath
path' = either (error . T.unpack) id . netPath

inbox, worked, approvals, done, ingress, work, operator, approve :: NetPath
inbox = path' "inbox"
worked = path' "worked"
approvals = path' "approvals"
done = path' "done"
ingress = path' "ingress"
work = path' "work"
operator = path' "operator"
approve = path' "approve"

issueColor, approvalColor, capability :: Text
issueColor = "issue"
approvalColor = "approval"
capability = "sparks"

-- | @topology_net()@.
topologyNet :: Net
topologyNet =
  either (error . T.unpack) id $
    mkNet
      (netSpec [place inbox, place worked, place approvals, place done] [transition ingress, (transition work) {handler = Just (HandlerSymbol "spark_work")}, transition operator, transition approve] arcs')
        { completion = Just (CompletionCel (either (error . T.unpack) id (cel "size(done) != 0")))
        }
  where
    arcs' =
      [ colored ingress inbox issueColor
      , colored inbox work issueColor
      , colored work worked issueColor
      , colored operator approvals approvalColor
      , colored worked approve issueColor
      , colored approvals approve approvalColor
      , colored approve done issueColor
      ]
    colored from to c = withArcColor (Just c) (arc from to)

-- | @topology_handlers(attempts, project_poisoned)@: the @SparkWork@
-- handler. @prepare@ reads the issue token's data whole into the input,
-- resolves the declared attempts and keys idempotency by the issue id;
-- @project@ stamps the frozen result onto the issue (or, poisoned, fails
-- after the result froze).
topologyHandlers :: Integer -> Bool -> Map.Map ImplementationRef BoundHandler
topologyHandlers attempts poisoned =
  Map.fromList
    [ ( Symbol "spark_work"
      , ActivityBound
          ActivityHandler
            { prepare = \binding -> case bindingTokens binding of
                [held] -> do
                  policy <- executionPolicy (policyFields defaultExecutionPolicy) {Activity.attempts = attempts}
                  Right
                    ActivityInvocation
                      { activity = "spark_work"
                      , input = held.payload
                      , policy
                      , correlation = Nothing
                      , idempotency = Just ("effect-" <> idText held.payload)
                      }
                other -> Left ("ValueError('too many values to unpack (expected 1, got " <> T.pack (show (length other)) <> ")')")
            , project = \binding result ->
                if poisoned
                  then Left "ValueError('projection poisoned: fix the code and retry complete()')"
                  else case bindingTokens binding of
                    [held] -> Right (handlerTokens [(worked, [Token (Just issueColor) (withMember "spark" result held.payload)])])
                    _ -> Left "ValueError('too many values to unpack')"
            , projectFailure = Nothing
            }
      )
    ]
  where
    idText value = case lookupMember "id" value of
      Just (String s) -> s
      Just other -> either (const "?") TE.decodeUtf8 (dumps defaultDumps other)
      Nothing -> "None"

-- | @{**data, key: value}@.
withMember :: Text -> Json -> Json -> Json
withMember key value = \case
  Object members
    | any ((== key) . fst) members -> Object [(k, if k == key then value else v) | (k, v) <- members]
    | otherwise -> Object (members <> [(key, value)])
  _ -> Object [(key, value)]

-- | @Token(ISSUE, data)@.
issue :: Json -> Token
issue = Token (Just issueColor)

-- | @Token(APPROVAL, data)@.
approval :: Json -> Token
approval = Token (Just approvalColor)

-- ---------------------------------------------------------------------------
-- Fixtures

-- | One example's world: the scratch database, the Engines it opened (all
-- closed at teardown, as the reference's @_OPEN_ENGINES@), and the Workers
-- it started (all reaped at teardown).
data Fixture = Fixture
  { target :: PostgresTarget
  , dsn :: ByteString
  , engines :: IORef [Engine]
  , workers :: IORef [Worker]
  }

-- | @absurd_dsn@ + @fixture_db@: both schemas and the fixture tables are
-- provisioned once; per example the kill switch is reset and the
-- example's Engines and Workers are torn down afterwards. Pending without
-- @PETRUS_TEST_POSTGRES@.
absurdEngineSpec :: SpecWith Fixture -> Spec
absurdEngineSpec = postgresSpec . beforeAllWith prepare . aroundWith perExample
  where
    prepare target = do
      withAutocommit target.targetUrl $ \connection -> do
        ensureSchema connection
        ensureAbsurdSchema connection
        ensureFixtureTables connection
      pure target
    perExample action target = do
      withAutocommit target.targetUrl $ \connection -> do
        _ <- Pg.execute_ connection "DELETE FROM impetus_test.kill_switch" []
        void (Pg.execute_ connection "INSERT INTO impetus_test.kill_switch (armed) VALUES (FALSE)" [])
      engines' <- newIORef []
      workers' <- newIORef []
      let fixture = Fixture {target, dsn = target.targetUrl, engines = engines', workers = workers'}
      action fixture `finally` teardown fixture
    teardown fixture = do
      readIORef fixture.engines >>= mapM_ (try @SomeException . Engine.close)
      readIORef fixture.workers >>= mapM_ killWorker

withAutocommit :: ByteString -> (Connection -> IO a) -> IO a
withAutocommit url = bracket (Pg.connect url True) Pg.close

-- | @ensure_fixture_tables@.
ensureFixtureTables :: Connection -> IO ()
ensureFixtureTables connection =
  forM_
    [ "CREATE SCHEMA IF NOT EXISTS impetus_test"
    , "CREATE TABLE IF NOT EXISTS impetus_test.effects (idempotency text PRIMARY KEY)"
    , "CREATE TABLE IF NOT EXISTS impetus_test.kill_switch (armed boolean NOT NULL)"
    ]
    (\statement -> Pg.execute_ connection statement [])

-- | @open_session@'s keywords.
data SessionOptions = SessionOptions
  { load :: Bool
  , attempts :: Integer
  , projectPoisoned :: Bool
  , queue :: Text
  , activities :: [ActivityDeclaration]
  , defaultHeartbeatTimeout :: Integer
  }

-- | @open_session@'s defaults.
sessionOptions :: SessionOptions
sessionOptions =
  SessionOptions {load = False, attempts = 1, projectPoisoned = False, queue = capability, activities = [], defaultHeartbeatTimeout = 30}

-- | The Engine keywords of @open_session@.
engineOptionsFor :: SessionOptions -> Engine.EngineOptions
engineOptionsFor o =
  Engine.defaultEngineOptions
    { Engine.handlers = topologyHandlers o.attempts o.projectPoisoned
    , Engine.celCompilers = celCompilers
    , Engine.activities = o.activities
    , Engine.defaultHeartbeatTimeout = o.defaultHeartbeatTimeout
    }

-- | The provider keywords of @open_session@.
absurdOptionsFor :: SessionOptions -> AbsurdEngineOptions
absurdOptionsFor o = defaultAbsurdEngineOptions {pollInterval = 0.1, defaultQueue = o.queue}

-- | @open_session(dsn, instance, ...)@: fresh joined and listen
-- connections, the door, and the Engine registered for teardown.
openSession :: Fixture -> Text -> SessionOptions -> IO Engine
openSession fixture instanceId o = do
  joined <- Pg.connect fixture.dsn False
  listener <- Pg.connect fixture.dsn True
  openSessionOn fixture (absurdSession joined (Just listener)) instanceId o

-- | 'openSession' over a supplied session.
openSessionOn :: Fixture -> AbsurdSession -> Text -> SessionOptions -> IO Engine
openSessionOn fixture session instanceId o = do
  engine <- openAbsurdEngine session (if o.load then LoadInstance else CreateInstance) topologyNet instanceId (absurdOptionsFor o) (engineOptionsFor o)
  modifyIORef' fixture.engines (engine :)
  pure engine

-- | @close_session@.
closeSession :: Engine -> IO ()
closeSession = Engine.close

counter :: IORef Int
counter = unsafePerformIO (newIORef 0)
{-# NOINLINE counter #-}

fresh :: Text -> Int -> IO Text
fresh prefix width = do
  n <- atomicModifyIORef' counter (\c -> (c + 1, c))
  pid <- getProcessID
  now <- getMonotonicTime
  let hex = showHex (abs (round (now * 1e6) :: Integer) + toInteger n * 7919 + toInteger (fromEnum pid) * 104729) ""
  pure (prefix <> T.pack (reverse (take width (reverse ("0000000000" <> hex)))))

-- | @f"topo-{uuid4().hex[:10]}"@ (any prefix).
freshTopo :: Text -> IO Text
freshTopo prefix = fresh (prefix <> "-") 10

-- | @f"goose-{uuid4().hex[:6]}"@.
freshIssue :: IO Text
freshIssue = fresh "goose-" 8

-- ---------------------------------------------------------------------------
-- Driving

-- | @advance_until_blocked@: pump immediately ready one-action turns until
-- wait, sleep, or stop.
advanceUntilBlocked :: Engine -> IO Engine.DriveOutcome
advanceUntilBlocked engine = go []
  where
    go acc = do
      outcome <- Engine.advance engine
      let acc' = outcome.firings : acc
      if outcome.ready
        then go acc'
        else pure (Engine.DriveOutcome (concat (reverse acc')) outcome.waiting False outcome.nextMaturation)

-- | @drive_until_rest(session)@ (30 s).
driveUntilRest :: Engine -> IO ()
driveUntilRest = driveUntilRestWithin 30

-- | @drive_until_rest(session, deadline_seconds)@.
driveUntilRestWithin :: Double -> Engine -> IO ()
driveUntilRestWithin seconds engine = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop = do
        outcome <- advanceUntilBlocked engine
        when outcome.waiting $ do
          now <- getMonotonicTime
          when (now >= deadline) $ expectationFailure "timed out waiting on worker results"
          _ <- Engine.wait engine 1.0
          loop
  loop

-- ---------------------------------------------------------------------------
-- Probes

-- | @effects_for(dsn, issue_id)@.
effectsFor :: Fixture -> Text -> IO Int
effectsFor fixture issueId =
  withAutocommit fixture.dsn $ \probe -> do
    rows <- query probe "SELECT count(*) FROM impetus_test.effects WHERE idempotency = %s" [textParam ("effect-" <> issueId)]
    pure (case rows of [[Just n]] -> read (BC.unpack n); _ -> 0)

-- | @arm_kill_switch(dsn)@.
armKillSwitch :: Fixture -> IO ()
armKillSwitch fixture = withAutocommit fixture.dsn $ \probe -> void (Pg.execute_ probe "UPDATE impetus_test.kill_switch SET armed = TRUE" [])

-- | One row of one text column (or 'Nothing').
scalarText :: Fixture -> Pg.Sql -> [Pg.Param] -> IO (Maybe Text)
scalarText fixture statement params = withAutocommit fixture.dsn $ \probe ->
  query probe statement params >>= \case
    (Just v : _) : _ -> pure (Just (TE.decodeUtf8 v))
    _ -> pure Nothing

-- | Every row, every column as text (NULL as "None").
rowsText :: Fixture -> Pg.Sql -> [Pg.Param] -> IO [[Text]]
rowsText fixture statement params = withAutocommit fixture.dsn $ \probe ->
  map (map (maybe "None" TE.decodeUtf8)) <$> query probe statement params

-- | @[type(record).__name__ for record in records]@.
recordNames :: [Record] -> [Text]
recordNames = map recordName

isRequested, isCompleted :: Record -> Bool
isRequested = \case RActivityRequested _ -> True; _ -> False
isCompleted = \case RActivityCompleted _ -> True; _ -> False

requestedOf :: [Record] -> [ActivityRequested]
requestedOf recs = [r | RActivityRequested r <- recs]

completedOf :: [Record] -> [ActivityCompleted]
completedOf recs = [r | RActivityCompleted r <- recs]

-- | @session.marking.place(DONE)@.
doneTokens :: Engine -> IO [Token]
doneTokens engine = toList . placeTokens done <$> Engine.marking engine

-- ---------------------------------------------------------------------------
-- Workers

data WorkerKind = PythonWorker | HaskellWorker
  deriving stock (Eq, Show)

-- | @worker_factory(queues=..., claim_timeout=..., poll_interval=...,
-- worker_id=...)@.
data WorkerOptions = WorkerOptions
  { queues :: [Text]
  , claimTimeout :: Integer
  , pollInterval :: Double
  , workerId :: Maybe Text
  }

workerOptions :: WorkerOptions
workerOptions = WorkerOptions {queues = [capability], claimTimeout = 30, pollInterval = 0.1, workerId = Nothing}

-- | A started Worker of either kind.
data Worker
  = PyWorker Handle ProcessHandle (IORef [ByteString])
  | HsWorker HsLane

data HsLane = HsLane
  { thread :: ThreadId
  , events :: Chan Json
  , stopping :: IORef Bool
  , finished :: MVar ExitCode
  , custody :: Absurd.AbsurdWorkerDispatch
  }

-- | Start a Worker, barrier on its ready event, and register it for
-- teardown.
startWorker :: Fixture -> WorkerKind -> WorkerOptions -> IO Worker
startWorker fixture kind o = do
  worker <- case kind of
    PythonWorker -> startPython fixture o
    HaskellWorker -> startHaskell fixture o
  modifyIORef' fixture.workers (worker :)
  _ <- awaitEvent worker (\event -> lookupMember "ready" event == Just (Bool True))
  pure worker

startPython :: Fixture -> WorkerOptions -> IO Worker
startPython fixture o = do
  exe <- pythonExecutable
  root <- upstreamPetrus
  environment <- getEnvironment
  let dsnText = BC.unpack fixture.dsn
      arguments =
        ["-m", "petrus.motus.worker", "--provider", "absurd", "--dsn", dsnText, "--registry", "tests.absurd_support:activities", "--claim-timeout", show o.claimTimeout, "--poll-interval", show o.pollInterval]
          <> concat [["--queue", T.unpack q] | q <- o.queues]
          <> maybe [] (\w -> ["--worker-id", T.unpack w]) o.workerId
  (_, Just out, Just err, handle) <-
    createProcess
      (proc exe arguments)
        { cwd = Just root
        , env = Just (("IMPETUS_TEST_DSN", dsnText) : filter ((/= "IMPETUS_TEST_DSN") . fst) environment)
        , std_out = CreatePipe
        , std_err = CreatePipe
        }
  hSetBinaryMode out True
  hSetBuffering out LineBuffering
  diagnostics <- newIORef []
  -- Drain stderr so a chatty Worker never blocks on a full pipe; keep it
  -- for failure messages.
  _ <- forkIO (drainInto err diagnostics)
  pure (PyWorker out handle diagnostics)

drainInto :: Handle -> IORef [ByteString] -> IO ()
drainInto h sink = do
  r <- try @SomeException (BS.hGetSome h 4096)
  case r of
    Right chunk | not (BS.null chunk) -> modifyIORef' sink (chunk :) >> drainInto h sink
    _ -> hClose h

startHaskell :: Fixture -> WorkerOptions -> IO Worker
startHaskell fixture o = do
  custody <-
    openAbsurdWorkerDispatch
      fixture.dsn
      defaultAbsurdWorkerOptions {Absurd.queues = o.queues, Absurd.workerId = o.workerId, Absurd.claimTimeout = fromInteger o.claimTimeout}
  events <- newChan
  stopping <- newIORef False
  finished <- newEmptyMVar
  let w = toWorkerDispatch custody
      say = writeChan events
      label = maybe Null String o.workerId
      execute attempt = do
        outcome <- trySync (sparkWork fixture.dsn w attempt)
        reported <- trySync $ case outcome of
          Right (Right result) -> w.complete attempt result >> pure "completed"
          Right (Left failure) -> w.fail attempt failure >> pure "failed"
          Left raised -> w.fail attempt (FailureException raised) >> pure "failed"
        case reported of
          Left refused -> say (Object [("worker", label), ("refused", String attempt.attemptId), ("error", String (T.strip (T.pack (show refused))))])
          Right outcome' ->
            say (Object [("worker", label), ("processed", String attempt.attemptId), ("activity", String attempt.invocation.activity), ("outcome", String outcome')])
      drain =
        readIORef stopping >>= \case
          True -> pure ()
          False ->
            w.claim >>= \case
              Nothing -> pure ()
              Just attempt -> execute attempt >> drain
      loop = do
        drain
        stop <- readIORef stopping
        unless stop $ void (w.wait o.pollInterval) >> loop
  thread <- mask_ $ forkIOWithUnmask $ \unmask -> do
    r <- try @SomeException (unmask (say (Object [("ready", Bool True), ("worker", label)]) >> loop))
    _ <- try @SomeException (Absurd.close custody)
    putMVar finished (either (const (ExitFailure 1)) (const ExitSuccess) r)
  pure (HsWorker HsLane {thread, events, stopping, finished, custody})

-- | @try@ for synchronous exceptions only: a kill (an asynchronous
-- exception) must never be reported as the Activity's failure.
trySync :: IO a -> IO (Either SomeException a)
trySync action =
  try action >>= \case
    Left raised | Just (_ :: SomeAsyncException) <- fromException raised -> throwIO raised
    other -> pure other

-- | @await_event(process, predicate)@ (30 s).
awaitEvent :: Worker -> (Json -> Bool) -> IO Json
awaitEvent = awaitEventWithin 30

-- | @await_event(process, predicate, timeout)@: read the Worker's events
-- until one satisfies the predicate; on timeout the Worker is killed and
-- the example fails.
awaitEventWithin :: Double -> Worker -> (Json -> Bool) -> IO Json
awaitEventWithin seconds worker predicate =
  tryAwaitEvent seconds worker predicate >>= \case
    Right value -> pure value
    Left message -> expectationFailure message >> throwIO (userError message)

-- | 'awaitEventWithin' answering the barrier failure instead of failing
-- (the reference's @except AssertionError: pass@); the Worker is killed
-- on timeout all the same.
tryAwaitEvent :: Double -> Worker -> (Json -> Bool) -> IO (Either String Json)
tryAwaitEvent seconds worker predicate = do
  deadline <- (+ seconds) <$> getMonotonicTime
  seen <- newIORef []
  let loop = do
        now <- getMonotonicTime
        let remaining = max 0 (deadline - now)
        next <- timeout (round (remaining * 1e6)) (nextEvent worker)
        case next of
          Nothing -> do
            killWorker worker
            saw <- readIORef seen
            pure (Left ("worker barrier timeout; saw " <> show (reverse saw)))
          Just Nothing -> do
            saw <- readIORef seen
            diagnostics <- workerDiagnostics worker
            pure (Left ("worker exited early; saw " <> show (reverse saw) <> "; stderr " <> diagnostics))
          Just (Just (line, event)) -> do
            modifyIORef' seen (line :)
            case event of
              Just value | predicate value -> pure (Right value)
              _ -> loop
  loop

nextEvent :: Worker -> IO (Maybe (ByteString, Maybe Json))
nextEvent = \case
  PyWorker out _ _ -> do
    r <- try @SomeException (BC.hGetLine out)
    pure $ case r of
      Left _ -> Nothing
      Right line -> Just (line, either (const Nothing) Just (parseJson pythonLoads line))
  HsWorker lane -> do
    event <- readChan lane.events
    pure (Just (either (const "?") id (dumps defaultDumps event), Just event))

workerDiagnostics :: Worker -> IO String
workerDiagnostics = \case
  PyWorker _ _ sink -> BC.unpack . BS.concat . reverse <$> readIORef sink
  HsWorker _ -> pure ""

-- | @process.kill(); process.wait()@ — idempotent. A Python Worker gets
-- SIGKILL by exact PID; a Haskell lane's thread is stopped mid-Activity
-- and its connection dropped without any report.
killWorker :: Worker -> IO ()
killWorker = \case
  PyWorker _ handle _ ->
    getProcessExitCode handle >>= \case
      Just _ -> pure ()
      Nothing -> do
        getPid handle >>= mapM_ (\pid -> void (try @SomeException (signalProcess sigKILL pid)))
        void (waitForProcess handle)
  HsWorker lane -> do
    alive <- isEmptyMVar lane.finished
    when alive $ do
      killThread lane.thread
      _ <- try @SomeException (Absurd.workerConnection lane.custody >>= Pg.close)
      void (readMVar lane.finished)

-- | @process.send_signal(SIGTERM)@: drain, don't drop — the in-flight
-- Activity completes, then the Worker exits.
terminateWorker :: Worker -> IO ()
terminateWorker = \case
  PyWorker _ handle _ -> getPid handle >>= mapM_ (signalProcess sigTERM)
  HsWorker lane -> writeIORef lane.stopping True

-- | @process.wait(timeout)@.
waitWorker :: Double -> Worker -> IO (Maybe ExitCode)
waitWorker seconds = \case
  PyWorker _ handle _ -> timeout (round (seconds * 1e6)) (waitForProcess handle)
  HsWorker lane -> timeout (round (seconds * 1e6)) (readMVar lane.finished)

-- | @process.poll() is None@.
workerAlive :: Worker -> IO Bool
workerAlive = \case
  PyWorker _ handle _ -> (== Nothing) <$> getProcessExitCode handle
  HsWorker lane -> isEmptyMVar lane.finished

-- | The Haskell twin of @tests.absurd_support.activities()["spark_work"]@:
-- the Activity whose world is the fixture database. Its external effect is
-- idempotent by the invocation's idempotency identity; @nap@ holds the
-- delivery open; @boom@ raises before any effect (a @ValueError@, spelled
-- as the reference Worker spells an exception: retryable, its type name as
-- the kind); an armed kill switch blocks the first delivery forever after
-- the effect committed. @heartbeat-long@ and @checkpoint-crash@ are the
-- heartbeat and checkpoint modes.
sparkWork :: ByteString -> WorkerDispatch -> ActivityAttempt -> IO (Either AttemptFailure Json)
sparkWork dsnBytes w attempt = do
  let input = attempt.invocation.input
      member key = fromMaybe Null (lookupMember key input)
      textOf = \case
        String s -> s
        other -> either (const "") TE.decodeUtf8 (dumps defaultDumps other)
      truthy = \case
        Null -> False
        Bool b -> b
        Int n -> n /= 0
        String s -> not (T.null s)
        Array xs -> not (null xs)
        Object xs -> not (null xs)
        _ -> True
      barrier = case member "barrier" of
        String p | not (T.null p) -> Just (T.unpack p)
        _ -> Nothing
      mode = member "mode"
      continue = do
        bracket (Pg.connect dsnBytes True) Pg.close $ \connection -> do
          case member "nap" of
            nap | truthy nap -> threadDelay (round (napSeconds nap * 1e6))
            _ -> pure ()
          if truthy (member "boom")
            then pure (Left (valueError "boom requested"))
            else do
              _ <-
                Pg.execute_
                  connection
                  "INSERT INTO impetus_test.effects (idempotency) VALUES (%s) ON CONFLICT DO NOTHING"
                  [maybe Pg.nullParam textParam attempt.invocation.idempotency]
              took <- query connection "UPDATE impetus_test.kill_switch SET armed = FALSE WHERE armed RETURNING 1" []
              unless (null took) $ forever (threadDelay 1000000000)
              pure (Right (String ("sparked " <> textOf (member "id"))))
  case mode of
    String "heartbeat-long" -> do
      start <- getMonotonicTime
      let beat n = do
            now <- getMonotonicTime
            when (now < start + 2.5) $ do
              _ <- w.heartbeat attempt (Just (Object [("beats", Int n)]))
              threadDelay 200000
              beat (n + 1)
      beat 1
      continue
    String "checkpoint-crash" -> case attempt.latestDetails of
      Null -> do
        _ <- w.heartbeat attempt (Just (Object [("cursor", Int 7), ("first_claimant", String attempt.claimant)]))
        forM_ barrier $ \p -> writeJson p (Object [("claimant", String attempt.claimant)])
        forever (threadDelay 1000000000)
      details -> do
        forM_ barrier $ \p -> writeJson (resumedPath p) (Object [("claimant", String attempt.claimant), ("details", details)])
        pure (Right (String ("resumed " <> textOf (fromMaybe Null (lookupMember "cursor" details)))))
    _ -> continue
  where
    napSeconds = \case
      Int n -> fromInteger n
      Float n -> n
      String s -> read (T.unpack s)
      _ -> 0
    writeJson p value = BS.writeFile p (either (const "{}") id (dumps defaultDumps value))
    resumedPath p = case break (== '.') (reverse p) of
      (_, '.' : stem) -> reverse stem <> ".resumed"
      _ -> p <> ".resumed"
    valueError message =
      either
        (FailureMessage . const message)
        FailureClassified
        (activityFailure ActivityFailureFields {failureError = message, failureKind = "ValueError", failureDetails = Null, failureRetryable = True, failureRetryAfter = Nothing})

-- ---------------------------------------------------------------------------
-- Selectors

-- | @pytest.raises(RuntimeError, match=".*".join(pieces))@ on an Engine
-- refusal.
engineRuntimeMatching :: [Text] -> Selector EngineError
engineRuntimeMatching pieces = \case
  EngineRuntimeError m -> matchesInOrder pieces m
  _ -> False

-- | @pytest.raises(ValueError, match=...)@.
engineValueMatching :: [Text] -> Selector EngineError
engineValueMatching pieces = \case
  EngineValueError m -> matchesInOrder pieces m
  _ -> False

-- | Any Engine error whose message matches.
engineAnyMatching :: [Text] -> Selector EngineError
engineAnyMatching pieces e = matchesInOrder pieces (engineErrorMessage e)

matchesInOrder :: [Text] -> Text -> Bool
matchesInOrder [] _ = True
matchesInOrder (piece : rest) haystack = case T.breakOn piece haystack of
  (_, found)
    | T.null found && not (T.null piece) -> False
    | otherwise -> matchesInOrder rest (T.drop (T.length piece) found)
