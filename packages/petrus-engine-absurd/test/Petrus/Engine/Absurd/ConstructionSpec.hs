-- | @TestAbsurdProviderEngineConstruction@ of
-- @tests/petrus/motus/worker/test_worker_topology.py@ (19 tests), plus the
-- one refusal upstream checks only in the provider's source (the listen
-- connection must not be the joined connection).
module Petrus.Engine.Absurd.ConstructionSpec (constructionSpec, constructionWithWorkersSpec) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM_, unless, void)
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.IORef
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation (..), ExecutionPolicyFields (..), policyFields)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Absurd
import Petrus.Engine.Absurd.Helpers
import Petrus.Engine.Absurd.Support
import Petrus.HistoryStore.Postgres (openPostgresHistoryStore)
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.Instance (FiringOccurrence (..), Status (..))
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..), lookupMember, parseJson, pythonLoads)
import Petrus.Motus.Dispatch.Absurd (Session (..))
import Petrus.Postgres (isClosed, textParam)
import Petrus.Postgres qualified as Pg
import Test.Hspec

constructionSpec :: SpecWith Fixture
constructionSpec = do
  it "resolves the default and the declared timeout into History and Dispatch" $ \fixture -> do
    -- Python also mutates the declaration list after construction to show
    -- the inputs are snapshotted; Haskell values are immutable, so only
    -- the resolution is checked.
    instanceId <- freshTopo "topo"
    session <- openSession fixture instanceId sessionOptions {activities = [declaration "other" 9], defaultHeartbeatTimeout = 4}
    void (Engine.deliver session ingress [issue (data' [("id", String "default")])] "ingress-default" Nothing)
    (.waiting) <$> advanceUntilBlocked session `shouldReturn` True
    requested <- firstOne . requestedOf <$> Engine.records session
    (policyFields requested.policy).heartbeatTimeout `shouldBe` 4
    params <- scalarText fixture (sqlOf ["SELECT params FROM absurd.t_", capability, " WHERE idempotency_key = %s"]) [textParam (keyFor instanceId requested.occurrence)]
    let parsed = params >>= either (const Nothing) Just . parseJson pythonLoads . BC.pack . T.unpack
    (parsed >>= lookupMember "policy" >>= lookupMember "heartbeat_timeout") `shouldBe` Just (Int 4)
    closeSession session

    overrideInstance <- freshTopo "topo"
    overridden <- openSession fixture overrideInstance sessionOptions {activities = [declaration "spark_work" 7], defaultHeartbeatTimeout = 4}
    void (Engine.deliver overridden ingress [issue (data' [("id", String "override")])] "ingress-override" Nothing)
    (.waiting) <$> advanceUntilBlocked overridden `shouldReturn` True
    overriddenRequest <- firstOne . requestedOf <$> Engine.records overridden
    (policyFields overriddenRequest.policy).heartbeatTimeout `shouldBe` 7
    closeSession overridden

  it "a load under a changed timeout keeps the recorded in-flight invocation without re-prepare" $ \fixture -> do
    instanceId <- freshTopo "topo"
    first <- openSession fixture instanceId sessionOptions {activities = [declaration "spark_work" 6], defaultHeartbeatTimeout = 3}
    void (Engine.deliver first ingress [issue (data' [("id", String "frozen")])] "ingress-frozen" Nothing)
    (.waiting) <$> advanceUntilBlocked first `shouldReturn` True
    original <- (.invocation) . firstOne <$> Engine.inFlight first
    fmap (\i -> (policyFields i.policy).heartbeatTimeout) original `shouldBe` Just 6
    closeSession first

    loaded <- openSession fixture instanceId sessionOptions {load = True, activities = [declaration "spark_work" 60], defaultHeartbeatTimeout = 30}
    reloaded <- (.invocation) . firstOne <$> Engine.inFlight loaded
    reloaded `shouldBe` original
    fmap (\i -> (policyFields i.policy).heartbeatTimeout) reloaded `shouldBe` Just 6
    closeSession loaded

  it "the provider returns the plain Engine, with only the universal doors" $ \fixture -> do
    -- Python checks the class's public names and @type(engine) is Engine@;
    -- the door's result type is the plain 'Engine', from which no provider
    -- operation (queue_for, the adapter) is reachable. One live read shows
    -- the value is a working Engine.
    instanceId <- freshTopo "topo"
    engine <- openSession fixture instanceId sessionOptions
    recordNames . take 1 <$> Engine.records engine `shouldReturn` ["InstanceCreated"]
    closeSession engine

  it "create and load are explicit, and close appends no semantic fact" $ \fixture -> do
    instanceId <- freshTopo "topo"
    openSession fixture instanceId sessionOptions {load = True} `raisesMatching` ["does not exist"]

    created <- openSession fixture instanceId sessionOptions
    records <- Engine.records created
    closeSession created
    loaded <- openSession fixture instanceId sessionOptions {load = True}
    Engine.records loaded `shouldReturn` records
    closeSession loaded

    openSession fixture instanceId sessionOptions `raisesMatching` ["already exists"]

    (joined, listener) <- connections fixture
    createEngine joined (Just listener) topologyNet instanceId defaultAbsurdEngineOptions (engineOptionsFor sessionOptions) `raisesMatching` ["already exists"]
    isClosed joined `shouldReturn` True
    isClosed listener `shouldReturn` True

    retried <- openSession fixture instanceId sessionOptions {load = True}
    Engine.records retried `shouldReturn` records
    closeSession retried

  it "an invalid provider option closes both connections" $ \fixture -> do
    -- Python's unknown keyword (a TypeError) cannot be written against a
    -- typed options record. An invalid provider option value is refused at
    -- the same point (once the fence is held and History loaded), with the
    -- same fate: both connections closed.
    (joined, listener) <- connections fixture
    instanceId <- freshTopo "topo"
    createEngine joined (Just listener) topologyNet instanceId defaultAbsurdEngineOptions {defaultQueue = "not a queue"} (engineOptionsFor sessionOptions)
      `raisesMatching` ["queue"]
    isClosed joined `shouldReturn` True
    isClosed listener `shouldReturn` True

  it "a wrong-autocommit listener leaves create empty and retriable" $ \fixture -> do
    instanceId <- freshTopo "topo"
    joined <- Pg.connect fixture.dsn False
    wrongListener <- Pg.connect fixture.dsn False
    createEngine joined (Just wrongListener) topologyNet instanceId defaultAbsurdEngineOptions Engine.defaultEngineOptions
      `shouldThrow` engineValueMatching ["autocommit=True"]
    freshRecords fixture instanceId `shouldReturn` []
    retry <- openSession fixture instanceId sessionOptions
    take 1 <$> Engine.records retry >>= \case
      [RInstanceCreated created] -> created.instanceId `shouldBe` instanceId
      other -> expectationFailure ("expected InstanceCreated first, got " <> show other)
    closeSession retry

  it "load refuses a recorded identity that differs from the storage key" $ \fixture -> do
    instanceId <- freshTopo "topo"
    connection <- Pg.connect fixture.dsn True
    ( do
        store <- openPostgresHistoryStore connection instanceId
        store.extend
          ( RInstanceCreated (InstanceCreated "different-instance" Nothing 0)
              : [ RDeliveryRegistrationOpened (DeliveryRegistrationOpened source "default" Nothing 0)
                | source <- [ingress, operator]
                ]
          )
      )
      `finallyClose` connection
    openSession fixture instanceId sessionOptions {load = True} `raisesMatching` ["storage key and recorded identity must match exactly"]

  it "two Engines keep independent Instance views" $ \fixture -> do
    leftId <- freshTopo "left"
    rightId <- freshTopo "right"
    left <- openSession fixture leftId sessionOptions
    right <- openSession fixture rightId sessionOptions
    void (Engine.deliver left ingress [issue (data' [("id", String "left")])] "ingress-left" Nothing)
    leftMarking <- Engine.marking left
    rightMarking <- Engine.marking right
    leftMarking `shouldNotBe` rightMarking
    leftRecords <- Engine.records left
    rightRecords <- Engine.records right
    leftRecords `shouldNotBe` rightRecords
    closeSession left
    closeSession right

  it "load refuses incompatible canonical data" $ \fixture -> do
    instanceId <- freshTopo "bad"
    connection <- Pg.connect fixture.dsn True
    void
      ( Pg.execute_
          connection
          "INSERT INTO impetus.semantic_events (event_id, net_instance_id, record_type, payload) VALUES (%s, %s, %s, %s::jsonb)"
          [textParam (instanceId <> ":0"), textParam instanceId, textParam "FutureRecord", textParam "{\"schema\": 999, \"type\": \"FutureRecord\"}"]
      )
      `finallyClose` connection
    outcome <- try @SomeException (openSession fixture instanceId sessionOptions {load = True})
    case outcome of
      Right _ -> expectationFailure "an incompatible History must be refused"
      Left e -> T.pack (displayException e) `shouldSatisfy` (\m -> any (`T.isInfixOf` m) ["decode", "schema", "record"])

  it "the session requires a join-mode connection" $ \fixture -> do
    autocommitConnection <- Pg.connect fixture.dsn True
    instanceId <- freshTopo "topo"
    createEngine autocommitConnection (Just autocommitConnection) topologyNet instanceId defaultAbsurdEngineOptions Engine.defaultEngineOptions
      `shouldThrow` engineValueMatching ["autocommit=False"]
    isClosed autocommitConnection `shouldReturn` True

  it "the session requires a dedicated listen connection" $ \fixture -> do
    joined <- Pg.connect fixture.dsn False
    instanceId <- freshTopo "topo"
    createEngine joined Nothing topologyNet instanceId defaultAbsurdEngineOptions Engine.defaultEngineOptions
      `shouldThrow` engineValueMatching ["dedicated autocommit listen connection"]
    isClosed joined `shouldReturn` True

  it "the listen connection must not be the joined connection (beyond upstream's tests)" $ \fixture -> do
    joined <- Pg.connect fixture.dsn False
    instanceId <- freshTopo "topo"
    createEngine joined (Just joined) topologyNet instanceId defaultAbsurdEngineOptions Engine.defaultEngineOptions
      `shouldThrow` engineValueMatching ["listen connection to be dedicated, not the joined connection"]
    isClosed joined `shouldReturn` True

  it "close is idempotent, and every door and observation refuses after close" $ \fixture -> do
    instanceId <- freshTopo "topo"
    session <- openSession fixture instanceId sessionOptions
    closeSession session
    Engine.close session
    forM_ (doors session 0) $ \door -> door `shouldThrow` engineRuntimeMatching ["Engine is closed"]

  it "a second live authority for one Instance is fenced out" $ \fixture -> do
    instanceId <- freshTopo "topo"
    first <- openSession fixture instanceId sessionOptions
    (secondConnection, secondListener) <- connections fixture
    loadEngine secondConnection (Just secondListener) topologyNet instanceId defaultAbsurdEngineOptions (engineOptionsFor sessionOptions)
      `raisesMatching` ["already held", "second canonical writer"]
    isClosed secondConnection `shouldReturn` True
    isClosed secondListener `shouldReturn` True
    closeSession first
    resumed <- openSession fixture instanceId sessionOptions {load = True}
    closeSession resumed

  it "the session hands out no writer and its accessors are read-only (enforced by the types)" $ \(_ :: Fixture) ->
    -- Python asserts no coordinator/adapter/instance attribute and that
    -- assigning an accessor raises; 'Engine' is abstract and its reads are
    -- functions, so neither can be written.
    pure () :: IO ()

  it "a joined Dispatch failure rolls back the selection before a fresh load" $ \fixture -> do
    instanceId <- freshTopo "topo"
    issueId <- freshIssue
    (joined, listener) <- connections fixture
    failing <- newIORef False
    let own = absurdSession joined (Just listener)
        session =
          own
            { dispatchSession =
                own.dispatchSession
                  { run = \statement params ->
                      readIORef failing >>= \case
                        True | "absurd.spawn_task" `T.isInfixOf` Pg.sqlSource statement -> ioError (userError "dispatch failed after joined begin")
                        _ -> own.dispatchSession.run statement params
                  }
            }
    engine <- openSessionOn fixture session instanceId sessionOptions
    deliverIssue engine issueId [] ("ingress-" <> issueId)
    writeIORef failing True
    advanceUntilBlocked engine `raisesMatching` ["dispatch failed after joined begin"]

    -- Poison releases authority immediately, before the old host closes,
    -- so a fresh load is the available coherent continuation.
    resumed <- openSession fixture instanceId sessionOptions {load = True}
    any (\case RCandidateSelected _ -> True; _ -> False) <$> Engine.records resumed `shouldReturn` False
    (toList . placeTokens ingress <$> Engine.marking resumed) `shouldReturn` []
    length <$> Engine.inFlight resumed `shouldReturn` 0
    Engine.close engine
    isClosed joined `shouldReturn` True
    isClosed listener `shouldReturn` True
    closeSession resumed

  it "real recovery lock contention poisons, preserves the old custody, creates no target, and releases the fence" $ \fixture -> do
    old <- T.replace "-" "_" <$> freshTopo "old"
    target <- T.replace "-" "_" <$> freshTopo "target"
    instanceId <- freshTopo "contention"
    first <- openSession fixture instanceId sessionOptions {queue = old}
    issueId <- freshIssue
    deliverIssue first issueId [] "ingress-recovery"
    (.waiting) <$> advanceUntilBlocked first `shouldReturn` True
    outstanding <-
      Engine.inFlight first >>= \case
        [o] -> pure o
        other -> expectationFailure ("expected one outstanding occurrence, got " <> show (length other)) >> ioError (userError "unreachable")
    closeSession first
    let key = keyFor instanceId outstanding.occurrence

    locker <- Pg.connect fixture.dsn False
    ( do
        void (Pg.query locker (sqlOf ["SELECT 1 FROM absurd.r_", old, " FOR UPDATE"]) [])
        recovering <- openSession fixture instanceId sessionOptions {load = True, queue = target}
        Engine.advance recovering `raisesMatching` ["currently locked"]
        Engine.advance recovering `raisesMatching` ["fresh Engine.load"]
        closeSession recovering
      )
      `finallyClose` locker

    scalarText fixture (sqlOf ["SELECT state FROM absurd.t_", old, " WHERE idempotency_key = %s"]) [textParam key] `shouldReturn` Just "pending"
    targetExists <- scalarText fixture "SELECT 1 FROM absurd.list_queues() WHERE queue_name = %s" [textParam target]
    unless (isNothing targetExists) $
      scalarText fixture (sqlOf ["SELECT count(*) FROM absurd.t_", target, " WHERE idempotency_key = %s"]) [textParam key] `shouldReturn` Just "0"

    resumed <- openSession fixture instanceId sessionOptions {load = True, queue = target}
    (.waiting) <$> advanceUntilBlocked resumed `shouldReturn` True
    Engine.inFlight resumed `shouldReturn` [outstanding]
    scalarText fixture (sqlOf ["SELECT state FROM absurd.t_", old, " WHERE idempotency_key = %s"]) [textParam key] `shouldReturn` Just "cancelled"
    scalarText fixture (sqlOf ["SELECT state FROM absurd.t_", target, " WHERE idempotency_key = %s"]) [textParam key] `shouldReturn` Just "pending"
    closeSession resumed

constructionWithWorkersSpec :: WorkerKind -> SpecWith Fixture
constructionWithWorkersSpec kind = do
  it "a projection crash never rolls back the frozen result" $ \fixture -> do
    void (startWorker fixture kind workerOptions)
    instanceId <- freshTopo "topo"
    issueId <- freshIssue
    session <- openSession fixture instanceId sessionOptions {projectPoisoned = True}
    deliverIssue session issueId [] ("ingress-" <> issueId)
    driveUntilRest session `raisesMatching` ["projection poisoned"]

    records <- freshRecords fixture instanceId
    let completed = completedOf records
    length completed `shouldBe` 1
    let workOccurrence = (firstOne completed).occurrence
        ended =
          [ name
          | record <- records
          , let name = recordName record
          , name `elem` ["FiringCompleted", "FiringFailed", "ActivityFailed"]
          , occurrenceOf record == Just workOccurrence
          ]
    ended `shouldBe` []

    -- Fix the code, resume fresh: reconcile's projection-pending leg
    -- completes by projection alone.
    second <- openSession fixture instanceId sessionOptions {load = True}
    awaiting <-
      Engine.inFlight second >>= \case
        [p] -> pure p
        other -> expectationFailure ("expected one pending projection, got " <> show (length other)) >> ioError (userError "unreachable")
    driveUntilRest second
    deliverApproval second issueId
    driveUntilRest second
    Engine.status second `shouldReturn` Completed
    effectsFor fixture issueId `shouldReturn` 1
    scalarText fixture (sqlOf ["SELECT attempts FROM absurd.t_", capability, " WHERE idempotency_key = %s"]) [textParam (keyFor instanceId awaiting.occurrence)]
      `shouldReturn` Just "1"

  it "a terminal Activity failure halts loud with its facts durable" $ \fixture -> do
    void (startWorker fixture kind workerOptions)
    instanceId <- freshTopo "topo"
    issueId <- freshIssue
    session <- openSession fixture instanceId sessionOptions
    deliverIssue session issueId [("boom", Bool True)] ("ingress-" <> issueId)
    driveUntilRest session `shouldThrow` engineRuntimeMatching ["failed terminally", "boom requested"]

    names <- recordNames <$> freshRecords fixture instanceId
    length (filter (== "ActivityFailed") names) `shouldBe` 1
    length (filter (== "FiringFailed") names) `shouldBe` 1
    effectsFor fixture issueId `shouldReturn` 0

  it "a failed door poisons the session whole" $ \fixture -> do
    void (startWorker fixture kind workerOptions)
    instanceId <- freshTopo "topo"
    session <- openSession fixture instanceId sessionOptions
    issueId <- freshIssue
    deliverIssue session issueId [("boom", Bool True)] "ingress-failure"
    driveUntilRest session `shouldThrow` engineRuntimeMatching ["failed terminally"]
    forM_ (doors session 0.1) $ \door -> door `shouldThrow` engineRuntimeMatching ["fresh Engine.load"]
