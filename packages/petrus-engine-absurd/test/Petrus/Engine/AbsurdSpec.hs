-- | Parity: the Engine-side tests of
-- @tests/petrus/motus/worker/test_worker_topology.py@ — a real one-Instance
-- Engine over PostgreSQL History plus Absurd Dispatch, against the
-- topology net of @tests/absurd_support.py@: @TestEndToEnd@ (1),
-- @TestLifecycleScopeCancellation@ (1), @TestWorkerKill@ (4),
-- @TestAuthorityKill@ (2) and @TestAbsurdProviderEngineConstruction@ (19);
-- 27 of the file's 40 cases. The other 13 (@TestActivityRegistry@ and
-- @TestDispatchDoorbell@) test the Worker process and its registry; they
-- are "Petrus.Engine.Absurd.WorkerTopologySpec".
--
-- Every example that runs a Worker runs twice: once against the
-- reference's own Worker process (@python -m petrus.motus.worker
-- --provider absurd@, as upstream starts it — a Haskell Engine with a
-- Python Worker), and once against this port's Worker process (this
-- suite's executable as 'workerMain' with the Absurd provider slot — a
-- Haskell Engine with a Haskell Worker), both killed by exact PID.
--
-- Without @PETRUS_TEST_POSTGRES@ every example is pending, saying so
-- (upstream's @postgres@ marker).
module Petrus.Engine.AbsurdSpec (spec) where

import Control.Monad (forM, forM_, void, when)
import Data.Foldable (toList)
import Data.IORef
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Petrus.Engine qualified as Engine
import Petrus.Engine.Absurd
import Petrus.Engine.Absurd.ConstructionSpec (constructionSpec, constructionWithWorkersSpec)
import Petrus.Engine.Absurd.Helpers
import Petrus.Engine.Absurd.Support
import Petrus.Engine.Provider (OpenMode (..))
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.History.Records
import Petrus.Impetus.Instance (FiringOccurrence (..), ScopeClosure (..), Status (..))
import Petrus.Impetus.Instance qualified as Instance
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..), lookupMember)
import Petrus.Motus.Dispatch.Absurd (Session (..))
import Petrus.Postgres (textParam)
import Petrus.Postgres qualified as Pg
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = absurdEngineSpec $ do
  forM_ [PythonWorker, HaskellWorker] $ \kind ->
    describe ("with a " <> workerLabel kind) $ do
      describe "TestEndToEnd" (endToEndSpec kind)
      describe "TestWorkerKill" (workerKillSpec kind)
      describe "TestAuthorityKill" (authorityKillSpec kind)
      describe "TestAbsurdProviderEngineConstruction (Worker-backed)" (constructionWithWorkersSpec kind)
  describe "TestLifecycleScopeCancellation" lifecycleSpec
  describe "TestAbsurdProviderEngineConstruction" constructionSpec

workerLabel :: WorkerKind -> String
workerLabel = \case
  PythonWorker -> "reference Worker process (python -m petrus.motus.worker)"
  HaskellWorker -> "Haskell Worker process (workerMain with the Absurd provider slot)"

startOn :: Fixture -> WorkerKind -> WorkerOptions -> IO Worker
startOn = startWorker

-- ---------------------------------------------------------------------------
-- TestEndToEnd

endToEndSpec :: WorkerKind -> SpecWith Fixture
endToEndSpec kind =
  it "the activity executes on the worker and completes through server-side projection" $ \fixture -> do
    worker <- startOn fixture kind workerOptions
    instanceId <- freshTopo "topo"
    issueId <- freshIssue
    session <- openSession fixture instanceId sessionOptions
    deliverIssue session issueId [] ("ingress-" <> issueId)
    driveUntilRest session
    deliverApproval session issueId
    driveUntilRest session

    doneTokens session `shouldReturn` [issue (data' [("id", String issueId), ("spark", String ("sparked " <> issueId))])]
    Engine.status session `shouldReturn` Completed
    void (awaitEvent worker completedEvent)
    effectsFor fixture issueId `shouldReturn` 1

    records <- freshRecords fixture instanceId
    Engine.records session `shouldReturn` records
    let requested = requestedOf records
        completed = completedOf records
    map (.activity) requested `shouldBe` ["spark_work"]
    [(r.occurrence, r.result) | r <- completed] `shouldBe` [((firstOne requested).occurrence, String ("sparked " <> issueId))]

-- ---------------------------------------------------------------------------
-- TestLifecycleScopeCancellation

lifecycleSpec :: SpecWith Fixture
lifecycleSpec =
  it "Engine close commits History, then the Absurd tombstone, and a restart repairs" $ \fixture -> do
    instanceId <- freshTopo "scope"
    issueId <- freshIssue
    session <- openSession fixture instanceId sessionOptions
    scope <- Engine.openScope session "pr-lifecycle"
    void (Engine.deliver session ingress [issue (data' [("id", String issueId)])] ("issue-" <> issueId) (Just (Instance.ScopeGeneration scope)))
    (.waiting) <$> advanceUntilBlocked session `shouldReturn` True
    request <- firstOne . requestedOf <$> Engine.records session

    closure <- Engine.closeScope session scope

    closure.cancelled `shouldBe` [request.occurrence]
    last <$> Engine.records session >>= \case
      RScopeClosed _ -> pure ()
      other -> expectationFailure ("expected a trailing ScopeClosed, got " <> show other)
    let key = keyFor instanceId request.occurrence
    scalarText fixture (sqlOf ["SELECT state FROM absurd.t_", capability, " WHERE idempotency_key = %s"]) [textParam key] `shouldReturn` Just "cancelled"
    closeSession session

    resumed <- openSession fixture instanceId sessionOptions {load = True}
    (.waiting) <$> Engine.advance resumed `shouldReturn` False
    scalarText fixture (sqlOf ["SELECT count(*) FROM absurd.t_", capability, " WHERE idempotency_key = %s"]) [textParam key] `shouldReturn` Just "1"

-- ---------------------------------------------------------------------------
-- TestWorkerKill

workerKillSpec :: WorkerKind -> SpecWith Fixture
workerKillSpec kind = do
  it "two workers do not replace a long activity that heartbeats" $ \fixture -> do
    first <- startOn fixture kind workerOptions {claimTimeout = 1, workerId = Just "heartbeat-a"}
    second <- startOn fixture kind workerOptions {claimTimeout = 1, workerId = Just "heartbeat-b"}
    instanceId <- freshTopo "topo"
    issueId <- freshIssue
    session <- openSession fixture instanceId sessionOptions {attempts = 2, activities = [declaration "spark_work" 1]}
    deliverIssue session issueId [("mode", String "heartbeat-long")] ("ingress-" <> issueId)
    driveUntilRest session

    completed <- fmap catMaybes . forM [first, second] $ \worker ->
      workerAlive worker >>= \case
        False -> pure Nothing
        True -> either (const Nothing) Just <$> tryAwaitEvent 1 worker (\event -> lookupMember "activity" event == Just (String "spark_work"))
    length (filter (outcomeIs "completed") completed) `shouldBe` 1
    effectsFor fixture issueId `shouldReturn` 1
    requested <- firstOne . requestedOf <$> Engine.records session
    scalarText
      fixture
      (sqlOf ["SELECT count(*) FROM absurd.r_", capability, " WHERE task_id = (SELECT task_id FROM absurd.t_", capability, " WHERE idempotency_key = %s)"])
      [textParam (keyFor instanceId requested.occurrence)]
      `shouldReturn` Just "1"

    encoded <- map encodeRecord <$> Engine.records session
    [lookupMember "record" payload | payload <- encoded]
      `shouldBe` map
        (Just . String)
        [ "InstanceCreated"
        , "DeliveryRegistrationOpened"
        , "DeliveryRegistrationOpened"
        , "ExternalEventDelivered"
        , "FiringBegun"
        , "TokensProduced"
        , "FiringCompleted"
        , "CandidateSelected"
        , "FiringBegun"
        , "TokensConsumed"
        , "ActivityRequested"
        , "ActivityCompleted"
        , "TokensProduced"
        , "FiringCompleted"
        ]
    let forbidden = ["attempt_id", "epoch", "claimant", "checkpoint", "heartbeat", "details"]
    forM_ encoded $ \payload -> case payload of
      Object members -> filter (`elem` forbidden) (map fst members) `shouldBe` []
      _ -> expectationFailure "a record payload is not an object"
    case [payload | payload <- encoded, lookupMember "record" payload == Just (String "ActivityRequested")] of
      [requestPayload] ->
        lookupMember "policy" requestPayload
          `shouldBe` Just
            ( Object
                [ ("attempts", Int 2)
                , ("heartbeat_timeout", Int 1)
                , ("initial_interval", Int 0)
                , ("coefficient", Int 2)
                , ("max_interval", Int 60)
                , ("jitter", Int 0)
                , ("start_to_close", Null)
                , ("schedule_to_close", Null)
                ]
            )
      other -> expectationFailure ("expected one ActivityRequested, got " <> show (length other))

  it "a replacement process receives durable details and resumes" $ \fixture ->
    withSystemTempDirectory "petrus-engine-absurd" $ \tmp -> do
      let barrier = tmp </> "checkpoint.json"
          resumedBarrier = tmp </> "checkpoint.resumed"
      first <- startOn fixture kind workerOptions {claimTimeout = 1, workerId = Just "checkpoint-a"}
      instanceId <- freshTopo "topo"
      issueId <- freshIssue
      session <- openSession fixture instanceId sessionOptions {attempts = 2, activities = [declaration "spark_work" 1]}
      deliverIssue session issueId [("mode", String "checkpoint-crash"), ("barrier", String (T.pack barrier))] ("ingress-" <> issueId)
      (.waiting) <$> advanceUntilBlocked session `shouldReturn` True
      waitFor 15 "first worker never persisted its checkpoint barrier" (doesFileExist barrier)
      firstDetails <- readJsonFile barrier
      killWorker first

      void (startOn fixture kind workerOptions {claimTimeout = 1, workerId = Just "checkpoint-b"})
      driveUntilRestWithin 30 session
      resumed <- readJsonFile resumedBarrier
      lookupMember "details" resumed `shouldBe` Just (Object [("cursor", Int 7), ("first_claimant", member "claimant" firstDetails)])
      member "claimant" resumed `shouldNotBe` member "claimant" firstDetails
      workedTokens <- toList . placeTokens worked <$> Engine.marking session
      map (lookupMember "spark" . (.payload)) (take 1 workedTokens) `shouldBe` [Just (String "resumed 7")]

  it "SIGKILL mid-activity redispatches on lease expiry with exactly one effect" $ \fixture -> do
    armKillSwitch fixture
    doomed <- startOn fixture kind workerOptions {claimTimeout = 1, workerId = Just "doomed"}
    instanceId <- freshTopo "topo"
    issueId <- freshIssue
    session <- openSession fixture instanceId sessionOptions {attempts = 2, defaultHeartbeatTimeout = 1}

    deliverIssue session issueId [] ("ingress-" <> issueId)
    (.waiting) <$> advanceUntilBlocked session `shouldReturn` True
    waitFor 15 "worker never reached the effect" ((/= 0) <$> effectsFor fixture issueId)
    recs <- Engine.records session
    requested <- case requestedOf recs of
      [r] -> pure r
      other -> expectationFailure ("expected one request, got " <> show (length other)) >> fail "unreachable"
    any isCompleted recs `shouldBe` False
    let key = keyFor instanceId requested.occurrence
    [[taskId, taskState, attempts]] <- rowsText fixture (sqlOf ["SELECT task_id, state, attempts FROM absurd.t_", capability, " WHERE idempotency_key = %s"]) [textParam key]
    (taskState, attempts) `shouldBe` ("running", "1")
    rowsText fixture (sqlOf ["SELECT attempt, state FROM absurd.r_", capability, " WHERE task_id = %s ORDER BY attempt"]) [textParam taskId]
      `shouldReturn` [["1", "running"]]
    killWorker doomed

    void (startOn fixture kind workerOptions {claimTimeout = 1, workerId = Just "successor"})
    driveUntilRestWithin 30 session
    deliverApproval session issueId
    driveUntilRest session

    Engine.status session `shouldReturn` Completed
    effectsFor fixture issueId `shouldReturn` 1
    completed <- completedOf <$> Engine.records session
    [(r.occurrence, r.result) | r <- completed] `shouldBe` [(requested.occurrence, String ("sparked " <> issueId))]
    rowsText fixture (sqlOf ["SELECT task_id, state, attempts FROM absurd.t_", capability, " WHERE idempotency_key = %s"]) [textParam key]
      `shouldReturn` [[taskId, "completed", "2"]]
    rowsText fixture (sqlOf ["SELECT attempt, state FROM absurd.r_", capability, " WHERE task_id = %s ORDER BY attempt"]) [textParam taskId]
      `shouldReturn` [["1", "failed"], ["2", "completed"]]
    finalTokens <- doneTokens session
    map (lookupMember "spark" . (.payload)) finalTokens `shouldBe` [Just (String ("sparked " <> issueId))]

  it "SIGTERM drains gracefully: the in-flight activity completes" $ \fixture -> do
    worker <- startOn fixture kind workerOptions {workerId = Just "drainer"}
    instanceId <- freshTopo "topo"
    issueId <- freshIssue
    session <- openSession fixture instanceId sessionOptions
    deliverIssue session issueId [("nap", Float 1.0)] ("ingress-" <> issueId)
    (.waiting) <$> advanceUntilBlocked session `shouldReturn` True
    waitFor 15 "worker never claimed" (not . null <$> rowsText fixture (sqlOf ["SELECT 1 FROM absurd.r_", capability, " WHERE state = 'running'"]) [])

    terminateWorker worker
    void (awaitEvent worker (outcomeIs "completed"))
    waitWorker 10 worker >>= \case
      Just code -> show code `shouldBe` "ExitSuccess"
      Nothing -> expectationFailure "the worker did not exit after draining"

    driveUntilRest session
    deliverApproval session issueId
    driveUntilRest session
    Engine.status session `shouldReturn` Completed

-- ---------------------------------------------------------------------------
-- TestAuthorityKill

authorityKillSpec :: WorkerKind -> SpecWith Fixture
authorityKillSpec kind = do
  it "killed after the dispatch commit, the authority resumes without a double spawn" $ \fixture -> do
    instanceId <- freshTopo "topo"
    issueId <- freshIssue
    first <- openSession fixture instanceId sessionOptions
    deliverIssue first issueId [] ("ingress-" <> issueId)
    (.waiting) <$> advanceUntilBlocked first `shouldReturn` True
    closeSession first

    second <- openSession fixture instanceId sessionOptions {load = True}
    outstanding <-
      Engine.inFlight second >>= \case
        [o] -> pure o
        other -> expectationFailure ("expected one outstanding occurrence, got " <> show (length other)) >> fail "unreachable"
    void (advanceUntilBlocked second)
    scalarText fixture (sqlOf ["SELECT count(*) FROM absurd.t_", capability, " WHERE idempotency_key = %s"]) [textParam (keyFor instanceId outstanding.occurrence)]
      `shouldReturn` Just "1"

    void (startOn fixture kind workerOptions)
    driveUntilRest second
    deliverApproval second issueId
    driveUntilRest second

    Engine.status second `shouldReturn` Completed
    length . completedOf <$> Engine.records second `shouldReturn` 1
    effectsFor fixture issueId `shouldReturn` 1

  it "a crash before the begin transaction commits leaves nothing anywhere" $ \fixture -> do
    instanceId <- freshTopo "topo"
    issueId <- freshIssue
    bootstrap <- openSession fixture instanceId sessionOptions
    deliverIssue bootstrap issueId [] ("ingress-" <> issueId)
    closeSession bootstrap
    provision <- Pg.connect fixture.dsn True
    void (Pg.execute_ provision "SELECT absurd.create_queue(%s)" [textParam capability]) `finallyClose` provision

    -- The authority stages the begin batch, the spawn and the doorbell in
    -- one open transaction, then dies before committing: its connection
    -- drops (closed without a commit) and the server aborts the whole
    -- staging. A real Engine stages it; its first commit point after the
    -- spawn closes the connection instead of committing (the load-time
    -- reconcile commit before it carries nothing).
    recordedBefore <- length <$> freshRecords fixture instanceId
    crashing <- Pg.connect fixture.dsn False
    crashingListener <- Pg.connect fixture.dsn True
    armed <- newIORef False
    staged <- newIORef False
    let own = absurdSession crashing (Just crashingListener)
        dying =
          own
            { commit =
                ((&&) <$> readIORef armed <*> readIORef staged) >>= \case
                  False -> own.commit
                  True -> Pg.close crashing >> ioError (userError "the authority died before its commit")
            , dispatchSession =
                own.dispatchSession
                  { run = \statement params -> do
                      when ("SELECT task_id, run_id, attempt, created FROM absurd.spawn_task" `T.isPrefixOf` Pg.sqlSource statement) $
                        writeIORef staged True
                      own.dispatchSession.run statement params
                  }
            }
    engine <- openAbsurdEngine dying LoadInstance topologyNet instanceId (absurdOptionsFor sessionOptions) (engineOptionsFor sessionOptions)
    writeIORef armed True
    advanceUntilBlocked engine `raisesMatching` ["the authority died before its commit"]
    readIORef staged `shouldReturn` True
    Engine.close engine

    rows <- scalarText fixture "SELECT count(*) FROM impetus.semantic_events WHERE net_instance_id = %s" [textParam instanceId]
    rows `shouldBe` Just (T.pack (show recordedBefore))
    staging <- freshRecords fixture instanceId
    any isRequested staging `shouldBe` False
    scalarText fixture (sqlOf ["SELECT count(*) FROM absurd.t_", capability, " WHERE idempotency_key LIKE %s"]) [textParam (instanceId <> ":occurrence-%")]
      `shouldReturn` Just "0"

    void (startOn fixture kind workerOptions)
    session <- openSession fixture instanceId sessionOptions {load = True}
    driveUntilRest session
    deliverApproval session issueId
    driveUntilRest session
    Engine.status session `shouldReturn` Completed
    effectsFor fixture issueId `shouldReturn` 1
