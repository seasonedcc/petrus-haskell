-- | The Worker topology at process grain
-- (@tests/petrus/motus/worker/test_worker_topology.py@) over the substrate
-- this repository has: an Engine over JSONL History and the durable Local
-- SQLite Dispatch, served by real Worker processes (this suite re-executed
-- as @python -m petrus.motus.worker --provider local@).
--
-- The reference's file runs the same topology over PostgreSQL History and
-- Absurd Dispatch. All of its 40 cases are ported over that substrate in
-- petrus-engine-absurd ("Petrus.Engine.AbsurdSpec" for the Engine side,
-- "Petrus.Engine.Absurd.WorkerTopologySpec" for the Worker process and its
-- registry), each Worker-backed case against both the reference's Worker
-- process and a Haskell one (the Worker entry point with the
-- 'ProviderPlugins' Absurd slot); they live there because the Absurd
-- Engine depends on this package. The cases here keep the reference's
-- shape: the Activity executes out of process and completes through the
-- Engine's projection; a Worker SIGKILLed mid-Activity is replaced after
-- lease expiry with exactly one effect; SIGTERM drains the in-flight
-- Activity; an unregistered Activity fails loud.
--
-- Cross-implementation: the Engine and the Worker take turns (lock-step),
-- so the History is deterministic, and every pairing of a Haskell or
-- reference Engine with a Haskell or reference Worker writes the same
-- bytes.
module Petrus.Engine.WorkerTopologySpec
  ( spec
  , workerModeVariable
  , topologyRegistries
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, finally, try)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Activity (ActivityFailureFields (..), failureFields, ActivityInvocation, ActivityInvocationFields (..), ExecutionPolicyFields (..), activityInvocation, defaultExecutionPolicy, executionPolicy, invocation, policyFields)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Scenario
import Petrus.Engine.TestSupport (advanceUntilRest, inlineOf)
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.HistoryStore.Support (withReference, runPython, withScratch)
import Petrus.Impetus.History.Records (ActivityCompleted (..), ActivityRequested (..), Record (..))
import Petrus.Impetus.Instance (Status (Awaiting))
import Petrus.Json (Json (..), lookupMember, parseJson, pythonLoads)
import Petrus.Motus.Dispatch (ActivityOutcome (..))
import Petrus.Motus.Dispatch.Inline (Activity)
import Petrus.Motus.Dispatch.Local (defaultLocalDispatchOptions, defaultLocalWorkerOptions, openLocalWorkerDispatch, toDispatch)
import Petrus.Motus.Dispatch.LocalSupport (closingScratch, openScratchDispatch)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Worker (WorkerOptions (..), closeWorker, defaultWorkerOptions, newWorker, runAvailable)
import System.Directory (doesFileExist, makeAbsolute, removeFile)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, hClose, hGetLine, hIsEOF, hPutStrLn, hFlush, hSetBinaryMode)
import System.Posix.Signals (sigKILL, sigTERM, signalProcess)
import System.Process
import System.Timeout (timeout)
import Test.Hspec
import Petrus.TestSupport (valid)

-- ---------------------------------------------------------------------------
-- Worker processes

-- | Set, the suite's executable is the Worker process entry point over
-- 'topologyRegistries'.
workerModeVariable :: String
workerModeVariable = "PETRUS_ENGINE_TEST_WORKER"

controlVariable :: String
controlVariable = "PETRUS_TOPOLOGY_CONTROL"

-- | The registries a Worker process can load: @charge_card@ steered by
-- files in the control directory, and a registry without it.
topologyRegistries :: Map Text (IO (Map Text Activity))
topologyRegistries =
  Map.fromList
    [ ( "tests.worker_topology:activities"
      , do
          control <- maybe (fail (controlVariable <> " is unset")) pure =<< lookupEnv controlVariable
          pure (Map.fromList [("charge_card", controlledCharge control)])
      )
    , ("tests.worker_topology:misrouted", pure (Map.fromList [("other", \_ _ -> pure Null)]))
    ]

-- | @charge_card@ with the reference fixture's controls: every execution is
-- logged; the effect (one file per order) is idempotent; @nap@ marks the
-- start and runs a second; @hang@ marks the window after the effect and
-- blocks before reporting terminal (the armed kill switch).
controlledCharge :: FilePath -> Activity
controlledCharge control inv _ = do
  let orderId = case lookupMember "id" inv.input of
        Just (String t) -> T.unpack t
        _ -> "unknown"
      effect = control </> ("effect-" <> orderId)
  appendFile (control </> "executions") (orderId <> "\n")
  present <- doesFileExist effect
  unless present $ writeFile effect "committed"
  nap <- doesFileExist (control </> "nap")
  when nap $ writeFile (control </> "started") orderId >> threadDelay 1000000
  hang <- doesFileExist (control </> "hang")
  when hang $ writeFile (control </> "hanging") orderId >> threadDelay 3600000000
  pure (chargeReceipt inv)

data WorkerProcess = WorkerProcess {handle :: ProcessHandle, out :: Handle}

-- | The reference's @worker_factory@: a real Worker process, barriered on
-- its ready line.
startWorker :: FilePath -> FilePath -> Text -> Text -> IO WorkerProcess
startWorker db control registry workerId = do
  self <- getExecutablePath
  environment <- getEnvironment
  let arguments =
        ["--provider", "local", "--path", db, "--registry", T.unpack registry, "--poll-interval", "0.05", "--worker-id", T.unpack workerId, "+RTS", "-M2G", "-RTS"]
      variables = [(workerModeVariable, "1"), (controlVariable, control)]
  (_, Just out, _, handle) <-
    createProcess
      (proc self arguments)
        { std_out = CreatePipe
        , env = Just (variables ++ filter ((`notElem` map fst variables) . fst) environment)
        }
  hSetBinaryMode out True
  let process = WorkerProcess handle out
  void (awaitEvent process (\event -> lookupMember "ready" event == Just (Bool True)))
  pure process

-- | The reference's @await_event@: read the Worker's event lines until one
-- satisfies the predicate (30 s at most).
awaitEvent :: WorkerProcess -> (Json -> Bool) -> IO Json
awaitEvent process predicate = do
  deadline <- (+ 30) <$> getMonotonicTime
  let loop seen = do
        now <- getMonotonicTime
        when (now >= deadline) $ expectationFailure ("worker barrier timeout; saw " <> show (reverse seen))
        line <- timeout (round ((deadline - now) * 1000000)) $ do
          eof <- hIsEOF process.out
          if eof then pure Nothing else Just <$> hGetLine process.out
        case line of
          Nothing -> expectationFailure ("worker barrier timeout or exit; saw " <> show (reverse seen)) >> pure Null
          Just Nothing -> expectationFailure ("worker exited early; saw " <> show (reverse seen)) >> pure Null
          Just (Just text) -> case parseJson pythonLoads (BC.pack text) of
            Right event | predicate event -> pure event
            _ -> loop (text : seen)
  loop []

signalWorker :: WorkerProcess -> (ProcessHandle -> IO ()) -> IO ()
signalWorker process send = send process.handle

kill :: ProcessHandle -> IO ()
kill handle =
  getPid handle >>= \case
    Nothing -> pure ()
    Just pid -> void (try @SomeException (signalProcess sigKILL pid)) >> void (waitForProcess handle)

terminate :: ProcessHandle -> IO ()
terminate handle = getPid handle >>= mapM_ (void . try @SomeException . signalProcess sigTERM)

-- | Reap every Worker the example started.
withWorkers :: (IORef [WorkerProcess] -> IO a) -> IO a
withWorkers = bracket (newIORef []) (\started -> readIORef started >>= mapM_ (\p -> kill p.handle >> hClose p.out))

spawnWorker :: IORef [WorkerProcess] -> FilePath -> FilePath -> Text -> Text -> IO WorkerProcess
spawnWorker started db control registry workerId = do
  process <- startWorker db control registry workerId
  modifyIORef' started (process :)
  pure process

-- ---------------------------------------------------------------------------
-- Engines

-- | An Engine over JSONL History and Local Dispatch running the order
-- scenario, the charge's invocation adjusted.
orderEngine :: FilePath -> (ActivityInvocation -> ActivityInvocation) -> Integer -> IO Engine.Engine
orderEngine dir adjust heartbeat = do
  prepared <- newIORef 0
  store <- openJsonlHistoryStore (dir </> "history.jsonl")
  port <- toDispatch <$> openScratchDispatch (dir </> "dispatch.db") orderIdentity defaultLocalDispatchOptions
  Engine.create orderNet orderIdentity store port (orderOptionsWith adjust prepared) {Engine.defaultHeartbeatTimeout = heartbeat}

-- | The reference's @drive_until_rest@: pump ready turns and provider waits
-- until nothing is outstanding.
driveUntilRest :: Engine.Engine -> Double -> IO ()
driveUntilRest engine seconds = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop = do
        outcome <- advanceUntilRest engine
        when outcome.waiting $ do
          now <- getMonotonicTime
          when (now >= deadline) $ expectationFailure "timed out waiting on worker results"
          void (Engine.wait engine 0.1)
          loop
  loop

requested :: [Record] -> [ActivityRequested]
requested records = [r | RActivityRequested r <- records]

completed :: [Record] -> [ActivityCompleted]
completed records = [r | RActivityCompleted r <- records]

-- | Attempts 2 and a one-second lease, as the reference's kill test.
leased :: ActivityInvocation -> ActivityInvocation
leased inv =
  valid . activityInvocation $
    ActivityInvocationFields
      inv.activity
      inv.input
      (either (error . T.unpack) id (executionPolicy (policyFields inv.policy) {attempts = 2, heartbeatTimeout = 1}))
      inv.correlation
      inv.idempotency

lineCount :: FilePath -> IO Int
lineCount path = do
  present <- doesFileExist path
  if present then length . BC.lines <$> BS.readFile path else pure 0

waitForFile :: FilePath -> Double -> IO ()
waitForFile path seconds = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop = do
        present <- doesFileExist path
        now <- getMonotonicTime
        unless present $
          if now >= deadline then expectationFailure ("never appeared: " <> path) else threadDelay 20000 >> loop
  loop

-- ---------------------------------------------------------------------------
-- Lock-step

data Implementation = Haskell | Reference deriving stock (Eq, Show)

script :: FilePath
script = "test/interop/worker_topology_interop.py"

-- | Drain Local Dispatch with a Worker of either implementation.
drainWith :: Maybe (FilePath, FilePath) -> Implementation -> FilePath -> IO ()
drainWith python implementation db = case (implementation, python) of
  (Haskell, _) -> do
    custody <- openLocalWorkerDispatch db defaultLocalWorkerOptions {Local.workerId = Just "haskell-drain"}
    worker <-
      newWorker
        (Local.toWorkerDispatch custody)
        (Map.fromList [("charge_card", \inv _ -> pure (chargeReceipt inv))])
        defaultWorkerOptions {output = \_ -> pure ()}
    void (runAvailable worker 100)
    closeWorker worker
  (Reference, Just reference) -> void (runPython reference script ["drain", db])
  (Reference, Nothing) -> expectationFailure "the reference is not synced"

-- | The lock-step scenario with the given Engine and Worker; answers the
-- History's bytes.
lockStep :: Maybe (FilePath, FilePath) -> FilePath -> Implementation -> Implementation -> IO BS.ByteString
lockStep python dir engineSide workerSide = closingScratch dir $ do
  let path = dir </> "history.jsonl"
      db = dir </> "dispatch.db"
      drain = drainWith python workerSide db
  case (engineSide, python) of
    (Haskell, _) -> do
      engine <- orderEngine dir id 30
      deliverOrders engine 3
      let loop = do
            outcome <- advanceUntilRest engine
            when outcome.waiting (drain >> loop)
      loop
      Engine.close engine
    (Reference, Just (interpreter, root)) -> do
      scriptPath <- makeAbsolute script
      (Just input, Just output, _, handle) <-
        createProcess (proc interpreter [scriptPath, "engine", path, db]) {cwd = Just root, std_in = CreatePipe, std_out = CreatePipe}
      let loop =
            hGetLine output >>= \case
              "blocked" -> drain >> hPutStrLn input "drained" >> hFlush input >> loop
              "rest" -> pure ()
              other -> expectationFailure ("unexpected engine line " <> show other)
      loop `finally` (hClose input >> hClose output)
      waitForProcess handle `shouldReturn` ExitSuccess
    (Reference, Nothing) -> expectationFailure "the reference is not synced"
  BS.readFile path

-- ---------------------------------------------------------------------------
-- Spec

spec :: Spec
spec = describe "test_worker_topology.py (Local Dispatch topology)" $ do
  it "the activity executes on the worker and completes through server side projection" $ withScratch $ \dir -> closingScratch dir $ withWorkers $ \started -> do
    let control = dir
    worker <- spawnWorker started (dir </> "dispatch.db") control "tests.worker_topology:activities" "remote"
    engine <- orderEngine dir id 30
    deliverOrders engine 3
    driveUntilRest engine 30
    Engine.marking engine `shouldReturn` settledMarking 3
    Engine.status engine `shouldReturn` Awaiting -- at rest; the order net's source stays open
    forM_ [1 .. 3 :: Int] $ \_ ->
      awaitEvent worker (\event -> lookupMember "activity" event == Just (String "charge_card") && lookupMember "outcome" event == Just (String "completed"))
    records <- Engine.records engine
    map (.activity) (requested records) `shouldBe` replicate 3 "charge_card"
    map (\r -> (r.occurrence, r.result)) (completed records)
      `shouldBe` [ (r.occurrence, chargeReceipt (valid (invocation "charge_card" r.input))) | r <- requested records]
    forM_ ["o-1", "o-2", "o-3"] $ \orderId -> doesFileExist (dir </> ("effect-" <> orderId)) `shouldReturn` True
    lineCount (dir </> "executions") `shouldReturn` 3
    -- The History is Engine-authored only: a fresh load reads the same
    -- records the live Engine holds.
    Engine.close engine
    prepared <- newIORef 0
    store <- openJsonlHistoryStore (dir </> "history.jsonl")
    port <- toDispatch <$> openScratchDispatch (dir </> "dispatch.db") orderIdentity defaultLocalDispatchOptions
    reloaded <- Engine.load orderNet orderIdentity store port (orderOptions prepared)
    Engine.records reloaded `shouldReturn` records
    Engine.close reloaded

  it "sigkill mid activity redispatches on lease expiry with exactly one effect" $ withScratch $ \dir -> closingScratch dir $ withWorkers $ \started -> do
    let db = dir </> "dispatch.db"
    writeFile (dir </> "hang") "armed"
    doomed <- spawnWorker started db dir "tests.worker_topology:activities" "doomed"
    engine <- orderEngine dir leased 1
    deliverOrders engine 1
    outcome <- advanceUntilRest engine
    outcome.waiting `shouldBe` True
    -- The effect commit is the in-the-window barrier.
    waitForFile (dir </> "hanging") 15
    records <- Engine.records engine
    length (requested records) `shouldBe` 1
    completed records `shouldSatisfy` null
    kill doomed.handle
    removeFile (dir </> "hang")
    void (spawnWorker started db dir "tests.worker_topology:activities" "successor")
    driveUntilRest engine 30
    Engine.marking engine `shouldReturn` settledMarking 1
    Engine.status engine `shouldReturn` Awaiting -- at rest; the order net's source stays open
    lineCount (dir </> "executions") `shouldReturn` 2 -- redelivered once
    doesFileExist (dir </> "effect-o-1") `shouldReturn` True -- and never doubled
    final <- Engine.records engine
    map (\r -> r.result) (completed final) `shouldBe` [chargeReceipt (valid (invocation "charge_card" (Object [("id", String "o-1"), ("cents", Int 100)])))]
    Engine.close engine

  it "sigterm drains gracefully: the in-flight activity completes" $ withScratch $ \dir -> closingScratch dir $ withWorkers $ \started -> do
    writeFile (dir </> "nap") "1.0"
    worker <- spawnWorker started (dir </> "dispatch.db") dir "tests.worker_topology:activities" "drainer"
    engine <- orderEngine dir id 30
    deliverOrders engine 1
    outcome <- advanceUntilRest engine
    outcome.waiting `shouldBe` True
    waitForFile (dir </> "started") 15
    signalWorker worker terminate -- mid-nap: drain, don't drop
    void (awaitEvent worker (\event -> lookupMember "outcome" event == Just (String "completed")))
    timeout 10000000 (waitForProcess worker.handle) `shouldReturn` Just ExitSuccess
    driveUntilRest engine 30
    Engine.marking engine `shouldReturn` settledMarking 1
    Engine.status engine `shouldReturn` Awaiting -- at rest; the order net's source stays open
    Engine.close engine

  it "the worker refuses an unregistered activity" $ withScratch $ \dir -> closingScratch dir $ withWorkers $ \started -> do
    let db = dir </> "dispatch.db"
    worker <- spawnWorker started db dir "tests.worker_topology:misrouted" "mixed"
    dispatch <- openScratchDispatch db "misrouted" defaultLocalDispatchOptions
    Local.dispatch dispatch 1 (valid (activityInvocation (ActivityInvocationFields "not_registered" (Object [("id", String "mix")]) defaultExecutionPolicy Nothing (Just "effect-mix"))))
    void (awaitEvent worker (\event -> lookupMember "outcome" event == Just (String "failed")))
    Local.collect dispatch >>= \case
      [(1, Failed f)] -> (failureFields f).failureError `shouldSatisfy` T.isInfixOf "no activity implementation"
      other -> expectationFailure ("unexpected outcomes " <> show other)

  -- test_worker_runtime.py's Engine-level case. The reference runs it over
  -- tests.absurd_support's topology net; the order net carries the same
  -- property: changing only the custody topology (inline, or Local custody
  -- drained by a Worker) does not change a sequential canonical trace.
  it "controlled sequential local execution is byte identical to inline history (test_worker_runtime.py)" $ withScratch $ \dir -> closingScratch dir $ do
    let arrangement name dispatch drain = do
          prepared <- newIORef 0
          store <- openJsonlHistoryStore (dir </> (name <> ".jsonl"))
          engine <- Engine.create orderNet orderIdentity store dispatch (orderOptions prepared)
          deliverOrders engine 1
          void (advanceUntilRest engine)
          drain
          void (advanceUntilRest engine)
          marking <- Engine.marking engine
          Engine.close engine
          history <- BS.readFile (dir </> (name <> ".jsonl"))
          pure (history, marking)
    -- Local custody stores a result as canonical JSON (sorted keys), as the
    -- reference's does, while inline custody hands the object over as
    -- built; the reference's case returns a string, so the inline receipt
    -- here is built with its keys already in canonical order.
    let canonicalReceipt inv = case chargeReceipt inv of
          Object members -> Object (sortOn fst members)
          other -> other
    inline <- inlineOf [("charge_card", \inv _ -> pure (canonicalReceipt inv))] >>= \dispatch -> arrangement "inline" dispatch (pure ())
    let db = dir </> "dispatch.db"
    local <- do
      dispatch <- toDispatch <$> openScratchDispatch db orderIdentity defaultLocalDispatchOptions
      arrangement "local" dispatch (drainWith Nothing Haskell db)
    snd local `shouldBe` settledMarking 1
    local `shouldBe` inline

  describe "lock-step Engine and Worker pairings write byte-identical History" $
    forM_ [(Haskell, Reference), (Reference, Haskell), (Reference, Reference)] $ \(engineSide, workerSide) ->
      it (show engineSide <> " Engine, " <> show workerSide <> " Worker") $ withReference $ \python -> withScratch $ \dir -> do
        ours <- lockStep Nothing (dir </> "") Haskell Haskell
        theirs <- withScratch $ \other -> lockStep (Just python) other engineSide workerSide
        theirs `shouldBe` ours
        -- The reference loads it to the settled marking.
        inspected <- runPython python "test/interop/engine_interop.py" ["inspect", dir </> "history.jsonl"]
        takeWhile (/= '\n') inspected
          `shouldBe` "{\"done\": [[\"Settled\", {\"id\": \"o-1\", \"status\": \"captured\"}], [\"Settled\", {\"id\": \"o-2\", \"status\": \"captured\"}], [\"Settled\", {\"id\": \"o-3\", \"status\": \"captured\"}]]}"
