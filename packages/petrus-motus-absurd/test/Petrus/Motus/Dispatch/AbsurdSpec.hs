-- | Parity: @tests/petrus/motus/dispatch/test_absurd_adapter.py@ (78 test
-- functions, 103 cases; see PARITY.md for the per-test map). Every example
-- that needs PostgreSQL runs against one scratch database with the pinned
-- Absurd schema ("Petrus.Motus.Dispatch.Absurd.Support"); without
-- @PETRUS_TEST_POSTGRES@ they are pending, saying so (upstream's
-- @postgres@ marker).
module Petrus.Motus.Dispatch.AbsurdSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, finally, throwIO, try)
import Control.Monad (forM, forM_, replicateM, void, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.IORef
import Data.List (sortOn)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Activity hiding (ActivityExecutionContext (..))
import Prelude hiding (fail)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch
  ( ActivityOutcome (..)
  , AttemptFailure (..)
  , CancellationDisposition (..)
  , DispatchError
  , cancellationInstruction
  , isCancellable
  )
import Petrus.Motus.Dispatch qualified as Port
import Petrus.Motus.Dispatch.Absurd
import Petrus.Motus.Dispatch.Absurd.Support
import Petrus.Postgres (Connection, PostgresError, intParam, query, textParam)
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport (PostgresTarget (..), upstreamPath, withScratchDatabase)
import Test.Hspec hiding (after, before, pending)

spec :: Spec
spec = do
  scopeSpec
  describe "TestSchemaPin" schemaPinSpec
  describe "TestQueueMapping" queueMappingSpec
  describe "TestInvocationWire" invocationWireSpec
  absurdSpec $ do
    laneSpec
    describe "TestDispatch" dispatchSpec
    describe "TestCollect" collectSpec
    describe "TestLookupFirstRedispatch" lookupFirstSpec
    describe "TestWaitForResults" waitSpec
    describe "TestAdapterShape" shapeSpec
    describe "TestGuardedAttemptDispatch" guardedSpec

-- ---------------------------------------------------------------------------
-- Publication identity scope

scopeSpec :: Spec
scopeSpec = describe "publication identity scope" $ do
  forM_ [":occurrence-1", "instance:occurrence-0", "instance:occurrence-01", "instance:occurrence-١"] $ \key ->
    it ("rejects the noncanonical publication identity " <> show key) $
      instanceFromKey (Just key) `shouldSatisfy` either (T.isInfixOf "publication identity") (const False)
  it "recovers an instance with occurrence text inside it" $
    instanceFromKey (Just "tenant:occurrence-segment:occurrence-17") `shouldBe` Right (Just "tenant:occurrence-segment")
  forM_ [Nothing, Just "", Just "foreign-task-key"] $ \key ->
    it ("leaves the foreign task key " <> show key <> " unscoped for default workers") $
      instanceFromKey key `shouldBe` Right Nothing

-- ---------------------------------------------------------------------------
-- TestSchemaPin

schemaPinSpec :: Spec
schemaPinSpec = do
  it "the vendored schema matches the triple pin (and the reference's vendored bytes)" $ do
    let digest = TE.decodeLatin1 (Base16.encode (SHA256.hash vendoredSchema))
    digest `shouldBe` absurdSqlSha256
    reference <- upstreamPath ("src/petrus/motus/dispatch/absurd_schema/absurd-" <> T.unpack absurdVersion <> ".sql") >>= BS.readFile
    vendoredSchema `shouldBe` reference
    onDisk <- BS.readFile "absurd_schema/absurd-0.4.0.sql"
    onDisk `shouldBe` reference
  absurdSpec $ do
    it "ensure is idempotent by version on a provisioned database" $ \target ->
      withObserver target $ \observer -> do
        ensureAbsurdSchema observer
        scalar observer "SELECT absurd.get_schema_version()" [] `shouldReturn` Just absurdVersion
    it "a tampered vendored copy is refused before any apply" $ \target ->
      withScratchDatabase target.adminUrl $ \scratch ->
        withConn scratch True $ \c -> do
          ensureAbsurdSchemaWith (vendoredSchema <> " ") c `shouldThrow` runtimeMatching ["hash mismatch"]
          scalar c "SELECT 1 FROM pg_namespace WHERE nspname = 'absurd'" [] `shouldReturn` Nothing
    it "a foreign absurd schema with no version answer is refused" $ \target ->
      withScratchDatabase target.adminUrl $ \scratch ->
        withConn scratch True $ \c -> do
          Pg.execute_ c "CREATE SCHEMA absurd" []
          ensureAbsurdSchema c `shouldThrow` runtimeMatching ["get_schema_version"]
    it "a drifted version is refused as a deliberate re-pin" $ \target ->
      withScratchDatabase target.adminUrl $ \scratch ->
        withConn scratch True $ \c -> do
          Pg.execute_ c "CREATE SCHEMA absurd" []
          Pg.execute_ c "CREATE FUNCTION absurd.get_schema_version() RETURNS text LANGUAGE sql AS $$ SELECT '9.9.9' $$" []
          ensureAbsurdSchema c `shouldThrow` runtimeMatching ["'9.9.9'", "deliberate act"]
    it "a tampered copy is refused even when already provisioned" $ \target ->
      withObserver target $ \observer ->
        ensureAbsurdSchemaWith (BS.drop 1 vendoredSchema) observer `shouldThrow` runtimeMatching ["hash mismatch"]
    it "ensure provisions an empty database to the pinned version" $ \target ->
      withScratchDatabase target.adminUrl $ \scratch ->
        withConn scratch True $ \c -> do
          ensureAbsurdSchema c
          scalar c "SELECT absurd.get_schema_version()" [] `shouldReturn` Just absurdVersion

-- ---------------------------------------------------------------------------
-- TestQueueMapping

queueMappingSpec :: Spec
queueMappingSpec = do
  absurdSpec $ do
    it "default and exact activity override" $ \target ->
      withObserver target $ \observer -> do
        adapter <- absurdDispatch observer "routing" defaultAbsurdDispatchOptions {defaultQueue = "private", activityQueues = [("transcribe", "gpu")]}
        queueFor adapter "ordinary" `shouldBe` Right "private"
        queueFor adapter "transcribe" `shouldBe` Right "gpu"
    it "activity queue overrides are snapshotted at adapter construction" $ \target ->
      withObserver target $ \observer -> do
        -- Haskell values are immutable: the snapshot is structural. The
        -- reference's mutation of its routes dict has no analogue; the
        -- routing outcome is pinned.
        adapter <- absurdDispatch observer "routing" defaultAbsurdDispatchOptions {activityQueues = [("transcribe", "gpu")]}
        queueFor adapter "transcribe" `shouldBe` Right "gpu"
        queueFor adapter "new" `shouldBe` Right "default"
  it "a capability that cannot be a queue name is refused loud" $
    forM_ ["Agentic", "0day", "a-b", "", T.replicate 58 "x"] $ \bad ->
      validateQueue bad `shouldSatisfy` either (matchesInOrder ["queue", "invalid"]) (const False)

-- ---------------------------------------------------------------------------
-- TestInvocationWire

invocationWireSpec :: Spec
invocationWireSpec = do
  it "the invocation crosses the queue whole and round-trips value-equal" $ do
    let policy = either (error . T.unpack) id (executionPolicy (policyFields defaultExecutionPolicy) {attempts = 4})
        original =
          ActivityInvocation
            { activity = "implement_issue"
            , input = Object [("id", String "goose"), ("n", Int 3)]
            , policy
            , correlation = Just "corr-1"
            , idempotency = Just "effect-goose"
            }
    decodeInvocation (encodeInvocation original) `shouldBe` Right original
  it "the derived None identities survive the wire" $ do
    let original = invocation "check_issue" (String "goose")
    decodeInvocation (encodeInvocation original) `shouldBe` Right original
  it "a foreign payload is refused loud" $
    decodeInvocation (Object [("task", String "nope")]) `shouldSatisfy` refusedAsInvocation
  it "the decode is strict field by field" $ do
    let wire = case encodeInvocation (invocation "check_issue" (String "goose")) of
          Object members -> members
          _ -> []
        with' key value = Object [(k, if k == key then value else v) | (k, v) <- wire]
        rejections =
          [ Object (wire <> [("extra", Int 1)])
          , Object [(k, v) | (k, v) <- wire, k /= "idempotency"]
          , with' "policy" (Object [("attempts", String "3")])
          , with' "policy" (Object [("attempts", Bool True)])
          , with' "policy" (Object [("attempts", Int 1), ("backoff", Int 2)])
          , with' "policy" (Array [Int 1])
          , with' "correlation" (Int 7)
          , String "not-a-mapping"
          ]
    forM_ rejections $ \payload -> decodeInvocation payload `shouldSatisfy` refusedAsInvocation
  where
    refusedAsInvocation = either (T.isInfixOf "does not decode as an activity invocation") (const False)

-- ---------------------------------------------------------------------------
-- The reference's AsyncWorker lane test, as concurrent Worker-facing lanes

laneSpec :: SpecWith PostgresTarget
laneSpec =
  it "distinct Absurd lane claimants claim, heartbeat and terminate concurrently, scoped to the instance" $ \target ->
    withAuthority target $ \authority -> do
      queue <- freshQueue
      instanceId <- freshName "scope-"
      adapter <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queue}
      forM_ [1 .. 3 :: Int] $ \n -> invocationFor 1 (Int (toInteger n)) >>= dispatch adapter n
      Pg.commit authority
      admitted <- newIORef []
      scopes <- newIORef []
      claimants <- newIORef []
      gate <- newEmptyMVar
      doneVars <- forM [1 .. 3 :: Int] $ \_ -> do
        finished <- newEmptyMVar
        _ <- forkIO $ do
          result <- try @SomeException $ do
            lane <- openAbsurdWorkerDispatch (dsnOf target) defaultAbsurdWorkerOptions {queues = [queue], workerId = Just "async-absurd"}
            ( do
                let w = toWorkerDispatch lane
                attempt <- waitClaim w
                let payload = case attempt.invocation.input of
                      Object [("payload", p)] -> p
                      other -> other
                atomicModifyIORef' admitted (\xs -> (payload : xs, ()))
                atomicModifyIORef' scopes (\xs -> (attempt.instance' : xs, ()))
                atomicModifyIORef' claimants (\xs -> (attempt.claimant : xs, ()))
                details <- w.heartbeat attempt (Just (Object [("payload", payload)]))
                readMVar gate
                w.complete attempt details
              )
              `finally` close lane
          putMVar finished result
        pure finished
      waitUntil 5 ((== 3) . length <$> readIORef admitted)
      putMVar gate ()
      results <- mapM takeMVar doneVars
      forM_ results (either throwIO pure)
      sortOn canonicalJson <$> readIORef admitted `shouldReturn` [Int 1, Int 2, Int 3]
      readIORef scopes `shouldReturn` replicate 3 (Just instanceId)
      lanes <- readIORef claimants
      length (dedupe lanes) `shouldBe` 3
      collected <- collect adapter
      sortOn' fst collected `shouldBe` [(n, Succeeded (Object [("payload", Int (toInteger n))])) | n <- [1 .. 3]]
  where
    waitClaim w = do
      deadline <- (+ 5) <$> getMonotonicTime
      let loop =
            w.claim >>= \case
              Just attempt -> pure attempt
              Nothing -> do
                now <- getMonotonicTime
                when (now > deadline) (expectationFailure "no claim within 5 s")
                threadDelay 10000
                loop
      loop
    dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

sortOn' :: (Ord b) => (a -> b) -> [a] -> [a]
sortOn' f = map snd . sortPairs . map (\x -> (f x, x))
  where
    sortPairs = foldr insert' []
    insert' x [] = [x]
    insert' x (y : ys) = if fst x <= fst y then x : y : ys else y : insert' x ys

waitUntil :: Double -> IO Bool -> IO ()
waitUntil seconds condition = do
  deadline <- (+ seconds) <$> getMonotonicTime
  let loop = do
        ok <- condition
        if ok
          then pure ()
          else do
            now <- getMonotonicTime
            when (now > deadline) (expectationFailure "condition not reached in time")
            threadDelay 10000
            loop
  loop

-- ---------------------------------------------------------------------------
-- TestDispatch

instruction :: Int -> ActivityInvocation -> Int -> Port.CancellationInstruction
instruction occurrence inv position = either (error . T.unpack) id (cancellationInstruction occurrence inv position)

dispatchSpec :: SpecWith PostgresTarget
dispatchSpec = do
  it "pending and missing publication cancel to durable tombstones" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      pending <- invocationFor 1 (String "pending")
      absent <- invocationFor 1 (String "absent")
      dispatch adapter 1 pending
      cancel adapter (instruction 1 pending 11) `shouldReturn` Retired
      cancel adapter (instruction 2 absent 12) `shouldReturn` Retired
      Pg.commit authority
      map (\(_, s, _) -> s) <$> taskRows observer queue adapter 1 `shouldReturn` ["cancelled"]
      map (\(_, s, _) -> s) <$> taskRows observer queue adapter 2 `shouldReturn` ["cancelled"]
      query observer "SELECT * FROM absurd.claim_task(%s, %s, 30, 1)" [textParam queue, textParam "worker"] `shouldReturn` []
      repaired <- absurdDispatch authority adapter.instance' defaultAbsurdDispatchOptions {defaultQueue = queue}
      cancel repaired (instruction 1 pending 11) `shouldReturn` Acknowledged
      Pg.commit authority

  it "claimed cancellation fences heartbeat and terminal report" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      call <- invocationFor 1 (String "running")
      publish adapter authority 1 call
      worker <- openAbsurdWorkerDispatch (dsnOf target) defaultAbsurdWorkerOptions {queues = [queue], workerId = Just "worker"}
      ( do
          Just attempt <- claim worker
          cancel adapter (instruction 1 call 11) `shouldReturn` Fenced
          Pg.commit authority
          heartbeat worker attempt Nothing `shouldThrow` runtimeMatching ["stale Activity Attempt"]
          complete worker attempt (Object [("effect", String "ambiguous")]) `shouldThrow` runtimeMatching ["stale Activity Attempt"]
          map (\(_, s, _) -> s) <$> taskRows observer queue adapter 1 `shouldReturn` ["cancelled"]
        )
        `finally` close worker

  it "a terminal before cancellation remains collectable" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      call <- invocationFor 1 (String "done")
      publish adapter authority 1 call
      (run, _, _) <- claimOne observer queue "test-claimer" 30
      completeRaw observer queue run (Object [("done", Bool True)])
      cancel adapter (instruction 1 call 11) `shouldReturn` Terminal
      Pg.commit authority
      collect adapter `shouldReturn` [(1, Succeeded (Object [("done", Bool True)]))]

  it "a second dispatch of one occurrence never double-enqueues" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      inv <- invocationFor 1 Null
      publish adapter authority 7 inv
      publish adapter authority 7 inv
      length <$> taskRows observer queue adapter 7 `shouldReturn` 1

  it "a redispatch with a conflicting invocation is refused" $ \target ->
    withAuthority target $ \authority -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      original <- invocationFor 1 (Object [("version", Int 1)])
      publish adapter authority 7 original
      dispatch adapter 7 (invocation "different_activity" (Object [("version", Int 2)]))
        `shouldThrow` valueMatching ["publication conflict"]

  it "a redispatch normalizes a legacy two-field policy before comparison" $ \target ->
    withAuthority target $ \authority -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      inv <- invocationFor 1 Null
      publish adapter authority 7 inv
      Pg.execute_
        authority
        (Pg.sql ("UPDATE absurd.t_" <> queue <> " SET params = jsonb_set(params, '{policy}', %s)"))
        [either (error . show) id (Pg.jsonbParam (Object [("attempts", Int 1), ("heartbeat_timeout", Int 30)]))]
      dispatch adapter 7 inv

  forM_ ["start_to_close", "schedule_to_close"] $ \field ->
    it ("the pinned provider refuses the " <> T.unpack field <> " deadline it cannot enforce exactly") $ \target ->
      withAuthority target $ \authority -> do
        queue <- freshQueue
        adapter <- adapterOver authority queue
        let base = policyFields defaultExecutionPolicy
            fields
              | field == "start_to_close" = base {startToClose = Just (IntNumber 10)}
              | otherwise = base {scheduleToClose = Just (IntNumber 10)}
            policy = either (error . T.unpack) id (executionPolicy fields)
        dispatch adapter 1 (invocation "probe_activity" Null) {policy}
          `shouldThrow` valueMatching ["does not support start_to_close or schedule_to_close"]

  it "the doorbell and the spawn ride the open transaction" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> withObserver target $ \listener -> do
      queue <- freshQueue
      Pg.execute_ observer "SELECT absurd.create_queue(%s)" [textParam queue]
      Pg.listen listener dispatchChannel
      adapter <- adapterOver authority queue
      invocationFor 1 Null >>= dispatch adapter 1
      Pg.waitForNotification listener 0.2 `shouldReturn` Nothing
      scalar observer (Pg.sql ("SELECT count(*) FROM absurd.t_" <> queue)) [] `shouldReturn` Just "0"
      Pg.commit authority
      note <- Pg.waitForNotification listener 5
      fmap (\n -> (Pg.notificationChannel n, Pg.notificationPayload n)) note `shouldBe` Just (dispatchChannel, queue)
      scalar observer (Pg.sql ("SELECT count(*) FROM absurd.t_" <> queue <> " WHERE state = 'pending'")) [] `shouldReturn` Just "1"

  it "a rollback vanishes the spawn and the doorbell together" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> withObserver target $ \listener -> do
      queue <- freshQueue
      Pg.listen listener dispatchChannel
      adapter <- adapterOver authority queue
      invocationFor 1 Null >>= dispatch adapter 1
      Pg.rollback authority
      Pg.waitForNotification listener 0.3 `shouldReturn` Nothing
      tables <- scalar observer "SELECT count(*) FROM pg_tables WHERE schemaname = 'absurd' AND tablename = %s" [textParam ("t_" <> queue)]
      when (tables /= Just "0") $
        scalar observer (Pg.sql ("SELECT count(*) FROM absurd.t_" <> queue)) [] `shouldReturn` Just "0"

  it "the task payload is the serialized invocation" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      inv <- invocationFor 1 (Object [("k", Array [Int 1, Int 2])])
      publish adapter authority 3 inv
      [[Just name, Just params]] <- rowsOf observer (Pg.sql ("SELECT task_name, params FROM absurd.t_" <> queue)) []
      name `shouldBe` inv.activity
      decodeInvocation (jsonOf params) `shouldBe` Right inv

  it "the policy maps to max_attempts with immediate retry" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      invocationFor 3 Null >>= publish adapter authority 4
      [[Just maxAttempts, Just strategy]] <- rowsOf observer (Pg.sql ("SELECT max_attempts, retry_strategy FROM absurd.t_" <> queue)) []
      maxAttempts `shouldBe` "3"
      jsonOf strategy `shouldBe` Object [("kind", String "none")]

-- ---------------------------------------------------------------------------
-- TestCollect

collectSpec :: SpecWith PostgresTarget
collectSpec = do
  it "collect returns results in completion order and drains" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      invocationFor 1 (String "first-dispatched") >>= publish adapter authority 1
      invocationFor 1 (String "second-dispatched") >>= publish adapter authority 2
      (run1, _, _) <- claimOne observer queue "test-claimer" 30
      (run2, _, _) <- claimOne observer queue "test-claimer" 30
      completeRaw observer queue run2 (Object [("answer", Int 2)])
      completeRaw observer queue run1 (Object [("answer", Int 1)])
      collect adapter `shouldReturn` [(2, Succeeded (Object [("answer", Int 2)])), (1, Succeeded (Object [("answer", Int 1)]))]
      collect adapter `shouldReturn` []

  it "policy exhaustion surfaces as an Activity failure" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      invocationFor 2 Null >>= publish adapter authority 1
      (run1, _, attempt1) <- claimOne observer queue "test-claimer" 30
      failRaw observer queue run1 "SparkError" "no fuel"
      (run2, _, attempt2) <- claimOne observer queue "test-claimer" 30
      failRaw observer queue run2 "SparkError" "still no fuel"
      (attempt1, attempt2) `shouldBe` (1, 2)
      collect adapter `shouldReturn` [(1, Failed (either (error . T.unpack) id (simpleFailure "SparkError: still no fuel")))]

  it "a surviving failure is not a terminal outcome" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      invocationFor 2 Null >>= publish adapter authority 1
      (run1, _, _) <- claimOne observer queue "test-claimer" 30
      failRaw observer queue run1 "SparkError" "first spark fizzled"
      collect adapter `shouldReturn` []

  it "a cancelled task is refused loud, never folded" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      invocationFor 1 Null >>= publish adapter authority 1
      Just taskId' <- scalar observer (Pg.sql ("SELECT task_id FROM absurd.t_" <> queue)) []
      Pg.execute_ observer "SELECT absurd.cancel_task(%s, %s)" [textParam queue, textParam taskId']
      collect adapter `shouldThrow` runtimeMatching ["cancelled"]

-- ---------------------------------------------------------------------------
-- TestLookupFirstRedispatch

keyOf :: Text -> Text
keyOf instanceId = publicationKey instanceId 1

stateOf :: Connection -> Text -> Text -> IO (Maybe Text)
stateOf observer queue key = fmap (\(s, _, _) -> s) <$> queueState observer queue key

lookupFirstSpec :: SpecWith PostgresTarget
lookupFirstSpec = do
  it "a provider-valid unconfigured queue does not break normal dispatch" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      Pg.execute_ observer "SELECT absurd.create_queue(%s)" [textParam "GPU-jobs"]
      queue <- freshQueue
      adapter <- adapterOver authority queue
      invocationFor 1 Null >>= publish adapter authority 1
      map (\(_, s, _) -> s) <$> taskRows observer queue adapter 1 `shouldReturn` ["pending"]

  it "matching pending custody on a provider-valid unconfigured queue transfers" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      let old = "GPU-jobs"
      queueTarget <- freshName "target_"
      instanceId <- freshName "quoted-"
      Pg.execute_ observer "SELECT absurd.create_queue(%s)" [textParam old]
      spawnRaw observer old probe (Object [("idempotency_key", String (keyOf instanceId))])
      resumed <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueTarget}
      publish resumed authority 1 probe
      stateOf observer old (keyOf instanceId) `shouldReturn` Just "cancelled"
      stateOf observer queueTarget (keyOf instanceId) `shouldReturn` Just "pending"

  forM_ [("completed", "GPU-done"), ("failed", "GPU-failed")] $ \(terminal, old) ->
    it ("matching " <> terminal <> " custody on a provider-valid unconfigured queue dispatches, collects and waits") $ \target ->
      withAuthority target $ \authority -> withObserver target $ \observer -> do
        queueTarget <- freshName "target_"
        instanceId <- freshName "quoted-"
        Pg.execute_ observer "SELECT absurd.create_queue(%s)" [textParam old]
        spawnRaw observer old probe (Object [("idempotency_key", String (keyOf instanceId)), ("max_attempts", Int 1)])
        (run, _, _) <- claimOne observer old "test-claimer" 30
        expected <-
          if terminal == "completed"
            then completeRaw observer old run (String "quoted done") >> pure (Succeeded (String "quoted done"))
            else failRaw observer old run "Quoted" "failed" >> pure (Failed (either (error . T.unpack) id (simpleFailure "Quoted: failed")))
        resumed <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueTarget}
        publish resumed authority 1 probe
        waitForResults resumed 0 `shouldReturn` True
        collect resumed `shouldReturn` [(1, expected)]

  it "a live task is left alone" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      inv <- invocationFor 1 Null
      publish adapter authority 1 inv
      resumed <- absurdDispatch authority adapter.instance' defaultAbsurdDispatchOptions {defaultQueue = queue}
      publish resumed authority 1 inv
      map (\(_, s, a) -> (s, a)) <$> taskRows observer queue adapter 1 `shouldReturn` [("pending", 1)]

  it "a completed task is collected, not re-invoked" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      inv <- invocationFor 1 Null
      publish adapter authority 1 inv
      (run, _, _) <- claimOne observer queue "test-claimer" 30
      completeRaw observer queue run (String "already done")
      resumed <- absurdDispatch authority adapter.instance' defaultAbsurdDispatchOptions {defaultQueue = queue}
      publish resumed authority 1 inv
      collect resumed `shouldReturn` [(1, Succeeded (String "already done"))]
      length <$> taskRows observer queue adapter 1 `shouldReturn` 1

  it "an absent task is respawned under the same identity" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      inv <- invocationFor 1 Null
      publish adapter authority 1 inv
      Pg.execute_ observer (Pg.sql ("DELETE FROM absurd.r_" <> queue)) []
      Pg.execute_ observer (Pg.sql ("DELETE FROM absurd.t_" <> queue)) []
      resumed <- absurdDispatch authority adapter.instance' defaultAbsurdDispatchOptions {defaultQueue = queue}
      publish resumed authority 1 inv
      map (\(_, s, _) -> s) <$> taskRows observer queue adapter 1 `shouldReturn` ["pending"]

  it "a never-started pending custody moves atomically to the new route" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "move-"
      first' <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish first' authority 1 probe
      resumed <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
      publish resumed authority 1 probe
      stateOf observer old (keyOf instanceId) `shouldReturn` Just "cancelled"
      stateOf observer new (keyOf instanceId) `shouldReturn` Just "pending"
      Just (queue, taskId') <- dispatchedTask resumed 1
      queue `shouldBe` new
      (_, claimed, _) <- claimOne observer new "test-claimer" 30
      claimed `shouldBe` taskId'

  it "a route back to a cancelled tombstone refuses without cancelling live custody" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queueA <- freshName "a_"
      queueB <- freshName "b_"
      instanceId <- freshName "routeback-"
      a1 <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueA}
      publish a1 authority 1 probe
      b <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueB}
      publish b authority 1 probe
      routeBack <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueA}
      dispatch routeBack 1 probe `shouldThrow` runtimeMatching ["target queue", "cancelled tombstone"]
      Pg.rollback authority
      stateOf observer queueB (keyOf instanceId) `shouldReturn` Just "pending"
      assertNoTargetTask observer queueA (keyOf instanceId)

  it "cancelled history elsewhere allows a fresh target without a tombstone" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      old <- freshName "old_"
      fresh <- freshName "fresh_"
      instanceId <- freshName "history-"
      first' <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish first' authority 1 probe
      Just taskId' <- scalar observer (Pg.sql ("SELECT task_id FROM absurd." <> Pg.quoteIdentifier ("t_" <> old))) []
      Pg.execute_ observer "SELECT absurd.cancel_task(%s, %s)" [textParam old, textParam taskId']
      resumed <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = fresh}
      publish resumed authority 1 probe
      fmap fst <$> dispatchedTask resumed 1 `shouldReturn` Just fresh

  it "all cancelled route A to B to A refuses without guessing custody" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queueA <- freshName "a_"
      queueB <- freshName "b_"
      instanceId <- freshName "all-cancelled-back-"
      let key = keyOf instanceId
      a1 <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueA}
      publish a1 authority 1 probe
      b <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueB}
      publish b authority 1 probe
      Just taskB <- scalar observer (Pg.sql ("SELECT task_id FROM absurd." <> Pg.quoteIdentifier ("t_" <> queueB) <> " WHERE idempotency_key = %s")) [textParam key]
      Pg.execute_ observer "SELECT absurd.cancel_task(%s, %s)" [textParam queueB, textParam taskB]
      routeBack <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueA}
      dispatch routeBack 1 probe `shouldThrow` runtimeMatching ["target queue", "cancelled tombstone"]
      Pg.rollback authority
      mapM (\q -> stateOf observer q key) [queueA, queueB] `shouldReturn` [Just "cancelled", Just "cancelled"]
      live <- forM [queueA, queueB] $ \q ->
        scalar observer (Pg.sql ("SELECT count(*) FROM absurd." <> Pg.quoteIdentifier ("t_" <> q) <> " WHERE idempotency_key = %s AND state != 'cancelled'")) [textParam key]
      live `shouldBe` [Just "0", Just "0"]
      dispatchedTask routeBack 1 `shouldReturn` Nothing

  it "a cross-queue transfer refuses autocommit before cancellation" $ \target ->
    withObserver target $ \observer -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "autocommit-"
      withAuthority target $ \joined -> do
        a <- absurdDispatch joined instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
        publish a joined 1 probe
      auto <- absurdDispatch observer instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
      dispatch auto 1 probe `shouldThrow` runtimeMatching ["autocommit mode"]
      stateOf observer old (keyOf instanceId) `shouldReturn` Just "pending"
      queueExists observer new `shouldReturn` False

  it "started custody is never cancelled or duplicated" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "started-"
      first' <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish first' authority 1 probe
      void (claimOne observer old "test-claimer" 30)
      resumed <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
      dispatch resumed 1 probe `shouldThrow` runtimeMatching ["never-started task may move"]
      Pg.rollback authority
      stateOf observer old (keyOf instanceId) `shouldReturn` Just "running"
      queueExists observer new `shouldReturn` False
      assertNoTargetTask observer new (keyOf instanceId)

  it "a prior started task forced back to pending is refused" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "forced-"
      let key = keyOf instanceId
      a <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish a authority 1 probe
      void (claimOne observer old "test-claimer" 30)
      Just (_, _, Just runId') <- queueState observer old key
      Pg.execute_ observer (Pg.sql ("UPDATE absurd." <> Pg.quoteIdentifier ("t_" <> old) <> " SET state = 'pending' WHERE idempotency_key = %s")) [textParam key]
      Pg.execute_ observer (Pg.sql ("UPDATE absurd." <> Pg.quoteIdentifier ("r_" <> old) <> " SET state = 'pending' WHERE run_id = %s")) [textParam runId']
      b <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
      dispatch b 1 probe `shouldThrow` runtimeMatching ["never-started task may move"]
      Pg.rollback authority
      assertNoTargetTask observer new key

  it "terminal custody reconciles on its old queue" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "terminal-"
      first' <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish first' authority 1 probe
      (run, _, _) <- claimOne observer old "test-claimer" 30
      completeRaw observer old run (String "done")
      resumed <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
      publish resumed authority 1 probe
      collect resumed `shouldReturn` [(1, Succeeded (String "done"))]
      fmap fst <$> dispatchedTask resumed 1 `shouldReturn` Just old

  forM_ ["completed", "failed"] $ \terminal ->
    it ("terminal (" <> terminal <> ") custody survives route A to B to A") $ \target ->
      withAuthority target $ \authority -> withObserver target $ \observer -> do
        queueA <- freshName "a_"
        queueB <- freshName "b_"
        instanceId <- freshName "terminal-back-"
        a1 <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueA}
        publish a1 authority 1 probe
        b <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueB}
        publish b authority 1 probe
        (run, _, _) <- claimOne observer queueB "test-claimer" 30
        expected <-
          if terminal == "completed"
            then completeRaw observer queueB run (String "done on b") >> pure (Succeeded (String "done on b"))
            else failRaw observer queueB run "Broken" "on b" >> pure (Failed (either (error . T.unpack) id (simpleFailure "Broken: on b")))
        routeBack <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueA}
        publish routeBack authority 1 probe
        fmap fst <$> dispatchedTask routeBack 1 `shouldReturn` Just queueB
        collect routeBack `shouldReturn` [(1, expected)]

  forM_ ["missing", "invalid"] $ \broken ->
    it ("a malformed (" <> broken <> ") terminal last attempt is refused without a target") $ \target ->
      withAuthority target $ \authority -> withObserver target $ \observer -> do
        old <- freshName "old_"
        queueTarget <- freshName "target_"
        instanceId <- freshName "broken-run-"
        let key = keyOf instanceId
        a <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
        publish a authority 1 probe
        (run, _, _) <- claimOne observer old "test-claimer" 30
        completeRaw observer old run (String "done")
        if broken == "missing"
          then Pg.execute_ observer (Pg.sql ("UPDATE absurd." <> Pg.quoteIdentifier ("t_" <> old) <> " SET last_attempt_run = NULL WHERE idempotency_key = %s")) [textParam key]
          else Pg.execute_ observer (Pg.sql ("UPDATE absurd." <> Pg.quoteIdentifier ("r_" <> old) <> " SET state = 'failed' WHERE run_id = %s")) [textParam run]
        b <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueTarget}
        dispatch b 1 probe `shouldThrow` runtimeMatching ["terminal state is invalid"]
        Pg.rollback authority
        queueExists observer queueTarget `shouldReturn` False

  forM_ ["sleeping", "running"] $ \state ->
    it ("non-pending (" <> T.unpack state <> ") custody is never moved") $ \target ->
      withAuthority target $ \authority -> withObserver target $ \observer -> do
        old <- freshName "old_"
        new <- freshName "new_"
        instanceId <- freshName "state-"
        let key = keyOf instanceId
        a <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
        publish a authority 1 probe
        Just (_, _, Just runId') <- queueState observer old key
        Pg.execute_ observer (Pg.sql ("UPDATE absurd." <> Pg.quoteIdentifier ("t_" <> old) <> " SET state = %s, first_started_at = now() WHERE idempotency_key = %s")) [textParam state, textParam key]
        Pg.execute_ observer (Pg.sql ("UPDATE absurd." <> Pg.quoteIdentifier ("r_" <> old) <> " SET state = %s WHERE run_id = %s")) [textParam state, textParam runId']
        b <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
        dispatch b 1 probe `shouldThrow` runtimeMatching ["never-started task may move"]
        Pg.rollback authority
        stateOf observer old key `shouldReturn` Just state
        assertNoTargetTask observer new key

  it "ambiguous custody refuses without changes" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      [one, two, queueTarget] <- replicateM 3 freshQueue
      instanceId <- freshName "duplicate-"
      let key = keyOf instanceId
      forM_ [one, two] $ \q -> do
        Pg.execute_ observer "SELECT absurd.create_queue(%s)" [textParam q]
        spawnRaw observer q probe (Object [("idempotency_key", String key)])
      a <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = queueTarget}
      dispatch a 1 probe `shouldThrow` runtimeMatching ["ambiguous", "2 live tasks"]
      Pg.rollback authority
      mapM (\q -> stateOf observer q key) [one, two] `shouldReturn` [Just "pending", Just "pending"]
      assertNoTargetTask observer queueTarget key

  it "a locked run refuses, bounded, without touching the task" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "locked-"
      let key = keyOf instanceId
      a <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish a authority 1 probe
      Just (_, _, Just runId') <- queueState observer old key
      withAuthority target $ \locker -> do
        void (query locker (Pg.sql ("SELECT 1 FROM absurd." <> Pg.quoteIdentifier ("r_" <> old) <> " WHERE run_id = %s FOR UPDATE")) [textParam runId'])
        b <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
        dispatch b 1 probe `shouldThrow` runtimeMatching ["currently locked"]
        Pg.rollback authority
      stateOf observer old key `shouldReturn` Just "pending"
      assertNoTargetTask observer new key

  it "an adversarial task-first lock refuses without deadlock" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "tasklock-"
      let key = keyOf instanceId
      a <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish a authority 1 probe
      withAuthority target $ \locker -> do
        void (query locker (Pg.sql ("SELECT 1 FROM absurd." <> Pg.quoteIdentifier ("t_" <> old) <> " WHERE idempotency_key = %s FOR UPDATE")) [textParam key])
        Pg.execute_ authority "SET LOCAL statement_timeout = '5s'" []
        b <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
        dispatch b 1 probe `shouldThrow` runtimeMatching ["currently locked"]
        Pg.rollback authority
      stateOf observer old key `shouldReturn` Just "pending"
      assertNoTargetTask observer new key

  it "an exception after cancel and before spawn rolls back the joined transaction and its notify" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> withObserver target $ \listener -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "rollback-"
      let key = keyOf instanceId
      a <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish a authority 1 probe
      Pg.listen listener dispatchChannel
      let plain = sessionOf authority
          failing =
            plain
              { run = \statement params ->
                  if Pg.sqlSource statement == "SELECT absurd.create_queue(%s)" && params == [textParam new]
                    then throwIO (userError "injected after cancel")
                    else plain.run statement params
              }
      b <- absurdDispatchOver failing instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
      dispatch b 1 probe `shouldThrow` (\e -> "injected after cancel" `T.isInfixOf` T.pack (show (e :: IOError)))
      Pg.rollback authority
      stateOf observer old key `shouldReturn` Just "pending"
      assertNoTargetTask observer new key
      Pg.waitForNotification listener 0.3 `shouldReturn` Nothing

  it "a reroute preserves the old and new idempotency key exactly" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "identity-"
      a <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish a authority 1 probe
      b <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
      publish b authority 1 probe
      oldKey <- scalar observer (Pg.sql ("SELECT idempotency_key FROM absurd." <> Pg.quoteIdentifier ("t_" <> old))) []
      newKey <- scalar observer (Pg.sql ("SELECT idempotency_key FROM absurd." <> Pg.quoteIdentifier ("t_" <> new))) []
      (oldKey, newKey) `shouldBe` (Just (keyOf instanceId), Just (keyOf instanceId))

  it "a real claim_task race: recovery wins" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "claim-race-"
      a <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish a authority 1 probe
      adapter <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
      dispatch adapter 1 probe -- row locks held through cancel + replacement spawn
      started <- newEmptyMVar
      result <- newEmptyMVar
      _ <- forkIO $ do
        r <- try @SomeException $ withObserver target $ \claimant -> do
          putMVar started ()
          query claimant "SELECT * FROM absurd.claim_task(%s, %s, %s, 1)" [textParam old, textParam "racer", intParam 30]
        putMVar result r
      takeMVar started
      -- claim_task's SKIP LOCKED posture returns no claim while recovery
      -- still holds the cancelled source rows and the uncommitted spawn.
      raced <- takeMVar result
      either throwIO pure raced `shouldReturn` []
      Pg.commit authority
      stateOf observer new (keyOf instanceId) `shouldReturn` Just "pending"
      (_, claimedTarget, _) <- claimOne observer new "target-claimer" 30
      fmap snd <$> dispatchedTask adapter 1 `shouldReturn` Just claimedTarget

  it "a real claim_task race: the claim wins" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "claim-first-"
      let key = keyOf instanceId
      a <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish a authority 1 probe
      claimed <- newEmptyMVar
      commitClaim <- newEmptyMVar
      finished <- newEmptyMVar
      _ <- forkIO $ do
        r <- try @SomeException $ withAuthority target $ \claimant -> do
          void (claimOne claimant old "race-winner" 30)
          putMVar claimed ()
          takeMVar commitClaim
          Pg.commit claimant
        putMVar finished r
      takeMVar claimed
      ( do
          b <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
          dispatch b 1 probe `shouldThrow` runtimeMatching ["currently locked"]
          Pg.rollback authority
        )
        `finally` putMVar commitClaim ()
      takeMVar finished >>= either throwIO pure
      stateOf observer old key `shouldReturn` Just "running"
      assertNoTargetTask observer new key

  it "concurrent recovery serializes to exactly one target custodian" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      old <- freshName "old_"
      new <- freshName "new_"
      instanceId <- freshName "race-"
      let key = keyOf instanceId
      a <- absurdDispatch authority instanceId defaultAbsurdDispatchOptions {defaultQueue = old}
      publish a authority 1 probe
      barrier <- newBarrier 3
      results <- forM [1 .. 2 :: Int] $ \_ -> do
        done <- newEmptyMVar
        _ <- forkIO $ do
          r <- try @SomeException $ withAuthority target $ \joined -> do
            Pg.execute_ joined "SET LOCAL statement_timeout = '5s'" []
            awaitBarrier barrier
            b <- absurdDispatch joined instanceId defaultAbsurdDispatchOptions {defaultQueue = new}
            publish b joined 1 probe
          putMVar done r
        pure done
      awaitBarrier barrier
      forM_ results (\done -> takeMVar done >>= either throwIO pure)
      stateOf observer old key `shouldReturn` Just "cancelled"
      stateOf observer new key `shouldReturn` Just "pending"
      scalar observer (Pg.sql ("SELECT count(*) FROM absurd." <> Pg.quoteIdentifier ("t_" <> new) <> " WHERE idempotency_key = %s")) [textParam key]
        `shouldReturn` Just "1"

data Barrier = Barrier Int (MVar Int) (MVar ())

newBarrier :: Int -> IO Barrier
newBarrier n = Barrier n <$> newMVar 0 <*> newEmptyMVar

awaitBarrier :: Barrier -> IO ()
awaitBarrier (Barrier n arrived gate) = do
  count' <- modifyMVar arrived (\c -> pure (c + 1, c + 1))
  when (count' == n) (putMVar gate ())
  readMVar gate

-- ---------------------------------------------------------------------------
-- TestWaitForResults

waitSpec :: SpecWith PostgresTarget
waitSpec = do
  it "a timeout with nothing terminal is an honest False" $ \target ->
    withAuthority target $ \authority -> do
      queue <- freshQueue
      adapter <- adapterWith authority defaultAbsurdDispatchOptions {defaultQueue = queue, pollInterval = 0.05}
      invocationFor 1 Null >>= publish adapter authority 1
      waitForResults adapter 0.2 `shouldReturn` False

  it "the poll safety net finds a result with the doorbell suppressed" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> withObserver target $ \listen' -> do
      queue <- freshQueue
      adapter <- adapterWith authority defaultAbsurdDispatchOptions {defaultQueue = queue, pollInterval = 0.1, listen = Just listen'}
      invocationFor 1 Null >>= publish adapter authority 1
      (run, _, _) <- claimOne observer queue "test-claimer" 30
      completeRaw observer queue run (String "quietly done")
      waitForResults adapter 5 `shouldReturn` True
      collect adapter `shouldReturn` [(1, Succeeded (String "quietly done"))]

  it "the doorbell wakes the wait well under the poll interval" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> withObserver target $ \listen' -> do
      queue <- freshQueue
      adapter <- adapterWith authority defaultAbsurdDispatchOptions {defaultQueue = queue, pollInterval = 30, listen = Just listen'}
      invocationFor 1 Null >>= publish adapter authority 1
      (run, _, _) <- claimOne observer queue "test-claimer" 30
      ready <- newBarrier 2
      done <- newEmptyMVar
      started <- getMonotonicTime
      _ <- forkIO $ do
        r <- try @SomeException $ do
          awaitBarrier ready
          threadDelay 200000
          withObserver target $ \worker -> do
            completeRaw worker queue run (String "rung in")
            Pg.execute_ worker "SELECT pg_notify(%s, %s)" [textParam resultsChannel, textParam queue]
        putMVar done r
      awaitBarrier ready
      waitForResults adapter 10 `shouldReturn` True
      takeMVar done >>= either throwIO pure
      elapsed <- subtract started <$> getMonotonicTime
      elapsed `shouldSatisfy` (< 5)

-- ---------------------------------------------------------------------------
-- TestAdapterShape

shapeSpec :: SpecWith PostgresTarget
shapeSpec = do
  it "AbsurdDispatch structurally satisfies the Engine-facing Dispatch (with cancellation)" $ \target ->
    withObserver target $ \observer -> do
      adapter <- adapterOver observer "default"
      isCancellable (toDispatch adapter) `shouldBe` True
  it "the listen connection must be autocommit" $ \target ->
    withObserver target $ \observer -> withAuthority target $ \authority ->
      void (absurdDispatch observer "x" defaultAbsurdDispatchOptions {listen = Just authority})
        `shouldThrow` valueMatching ["listen connection must be autocommit"]
  it "the instance id must be a non-empty string" $ \target ->
    withObserver target $ \observer ->
      void (absurdDispatch observer "" defaultAbsurdDispatchOptions) `shouldThrow` valueMatching ["non-empty string instance"]

-- ---------------------------------------------------------------------------
-- TestGuardedAttemptDispatch

spawnFor :: Connection -> Text -> Integer -> IO ()
spawnFor authority queue heartbeatTimeout = do
  adapter <- adapterOver authority queue
  let policy = either (error . T.unpack) id (executionPolicy (policyFields defaultExecutionPolicy) {attempts = 2, heartbeatTimeout = heartbeatTimeout})
  publish adapter authority 1 (invocation "probe_activity" (Object [])) {policy}

guarded :: Connection -> Text -> IO GuardedDispatch
guarded connection name = guardedDispatch (sessionOf connection) (Just name)

claimNow :: GuardedDispatch -> Text -> Int -> IO (ClaimedTask, Json)
claimNow g queue timeout =
  guardedClaim g queue timeout >>= \case
    Just delivery -> pure delivery
    Nothing -> expectationFailure "nothing claimable" >> error "unreachable"

awaitClaim :: GuardedDispatch -> Text -> IO (ClaimedTask, Json)
awaitClaim g queue = do
  deadline <- (+ 10) <$> getMonotonicTime
  let loop =
        guardedClaim g queue 30 >>= \case
          Just delivery -> pure delivery
          Nothing -> do
            now <- getMonotonicTime
            when (now > deadline) (expectationFailure "replacement Attempt did not become claimable")
            threadDelay 100000
            loop
  loop

failure' :: Text -> Text -> Json -> Bool -> Maybe Number -> ActivityFailure
failure' message kind details retryable retryAfter =
  either (error . T.unpack) id (activityFailure (ActivityFailureFields message kind details retryable retryAfter))

expiresAt :: Connection -> Text -> Text -> IO (Maybe Text)
expiresAt observer queue run = scalar observer (Pg.sql ("SELECT claim_expires_at FROM absurd.r_" <> queue <> " WHERE run_id = %s")) [textParam run]

guardedSpec :: SpecWith PostgresTarget
guardedSpec = do
  it "a heartbeat extends and atomically snapshots the latest details" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      spawnFor authority queue 5
      g <- guarded authority "boot-a"
      (task, prior) <- claimNow g queue 1
      prior `shouldBe` Null
      before <- scalar observer (Pg.sql ("SELECT extract(epoch FROM claim_expires_at) FROM absurd.r_" <> queue <> " WHERE run_id = %s")) [textParam task.runId]
      let supplied = Object [("offset", Array [Int 1])]
      guardedHeartbeat g queue task.taskId task.runId 5 (Just supplied) `shouldReturn` supplied
      after <- scalar observer (Pg.sql ("SELECT extract(epoch FROM claim_expires_at) FROM absurd.r_" <> queue <> " WHERE run_id = %s")) [textParam task.runId]
      (read . T.unpack <$> after :: Maybe Double) `shouldSatisfy` (>= (read . T.unpack <$> before))
      guardedHeartbeat g queue task.taskId task.runId 5 Nothing `shouldReturn` supplied

  it "a non-retryable classified failure terminalizes and round-trips exactly" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      let policy = either (error . T.unpack) id (executionPolicy (policyFields defaultExecutionPolicy) {attempts = 4})
      publish adapter authority 1 (invocation "probe_activity" Null) {policy}
      g <- guarded authority "worker"
      (task, _) <- claimNow g queue 30
      let failure = failure' "invalid" "InvalidRequest" (Object [("field", String "name")]) False (Just (IntNumber 9))
      guardedTerminal g queue task.taskId task.runId (ReportFailure (FailureClassified failure))
      rowsOf observer (Pg.sql ("SELECT state,max_attempts FROM absurd.t_" <> queue)) [] `shouldReturn` [[Just "failed", Just "1"]]
      collect adapter `shouldReturn` [(1, Failed failure)]

  it "a duplicate completion acknowledges and conflicts are refused" $ \target ->
    withAuthority target $ \authority -> do
      queue <- freshQueue
      spawnFor authority queue 2
      g <- guarded authority "worker"
      (task, _) <- claimNow g queue 30
      let ok = Object [("ok", Bool True)]
      guardedTerminal g queue task.taskId task.runId (ReportResult ok)
      guardedTerminal g queue task.taskId task.runId (ReportResult ok)
      guardedTerminal g queue task.taskId task.runId (ReportResult (Object [("ok", Bool False)]))
        `shouldThrow` valueMatching ["conflicting terminal report"]
      guardedTerminal g queue task.taskId task.runId (ReportFailure (FailureMessage "late"))
        `shouldThrow` valueMatching ["conflicting terminal report"]

  it "nested boolean and integer success results conflict" $ \target ->
    withAuthority target $ \authority -> do
      queue <- freshQueue
      spawnFor authority queue 2
      g <- guarded authority "worker"
      (task, _) <- claimNow g queue 30
      guardedTerminal g queue task.taskId task.runId (ReportResult (Object [("nested", Array [Bool True])]))
      guardedTerminal g queue task.taskId task.runId (ReportResult (Object [("nested", Array [Int 1])]))
        `shouldThrow` valueMatching ["conflicting terminal report"]

  forM_ [False, True] $ \retryable ->
    it ("a duplicate classified failure (retryable=" <> show retryable <> ") acknowledges after terminal or retry advance") $ \target ->
      withAuthority target $ \authority -> do
        queue <- freshQueue
        spawnFor authority queue 2
        g <- guarded authority "worker"
        (task, _) <- claimNow g queue 30
        let failure = failure' "down" "Unavailable" (Object [("zone", Int 1)]) retryable Nothing
        guardedTerminal g queue task.taskId task.runId (ReportFailure (FailureClassified failure))
        guardedTerminal g queue task.taskId task.runId (ReportFailure (FailureClassified failure))
        guardedTerminal g queue task.taskId task.runId (ReportFailure (FailureClassified (failure' "different" "Unavailable" Null retryable Nothing)))
          `shouldThrow` valueMatching ["conflicting terminal report"]

  it "nested boolean and integer failure details conflict" $ \target ->
    withAuthority target $ \authority -> do
      queue <- freshQueue
      spawnFor authority queue 2
      g <- guarded authority "worker"
      (task, _) <- claimNow g queue 30
      guardedTerminal g queue task.taskId task.runId (ReportFailure (FailureClassified (failure' "down" "ActivityError" (Object [("nested", Array [Bool True])]) False Nothing)))
      guardedTerminal g queue task.taskId task.runId (ReportFailure (FailureClassified (failure' "down" "ActivityError" (Object [("nested", Array [Int 1])]) False Nothing)))
        `shouldThrow` valueMatching ["conflicting terminal report"]

  it "retry_after is a floor over policy backoff on provider time" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      adapter <- adapterOver authority queue
      let policy =
            either (error . T.unpack) id $
              executionPolicy (policyFields defaultExecutionPolicy) {attempts = 2, initialInterval = IntNumber 1, maxInterval = IntNumber 60}
      publish adapter authority 1 (invocation "probe_activity" Null) {policy}
      g <- guarded authority "worker"
      (task, _) <- claimNow g queue 30
      Just before <- scalar observer "SELECT extract(epoch FROM absurd.current_time())" []
      guardedTerminal g queue task.taskId task.runId (ReportFailure (FailureClassified (failure' "later" "Unavailable" Null True (Just (IntNumber 30)))))
      [[Just state, Just available]] <-
        rowsOf observer (Pg.sql ("SELECT state, extract(epoch FROM available_at) FROM absurd.r_" <> queue <> " ORDER BY attempt DESC LIMIT 1")) []
      state `shouldBe` "sleeping"
      (read (T.unpack available) - read (T.unpack before) :: Double) `shouldSatisfy` (>= 29)

  it "a stale claimant, epoch and terminal are fenced" $ \target ->
    withAuthority target $ \authority -> do
      queue <- freshQueue
      spawnFor authority queue 1
      original <- guarded authority "boot-a"
      (task, _) <- claimNow original queue 30
      impostor <- guarded authority "boot-b"
      guardedHeartbeat impostor queue task.taskId task.runId 1 Nothing `shouldThrow` runtimeMatching ["stale Activity Attempt"]
      threadDelay 1100000
      replacement <- guarded authority "boot-b"
      (newer, _) <- awaitClaim replacement queue
      newer.taskId `shouldBe` task.taskId
      newer.runId `shouldNotBe` task.runId
      guardedHeartbeat original queue task.taskId task.runId 1 Nothing `shouldThrow` runtimeMatching ["stale Activity Attempt"]
      guardedTerminal original queue task.taskId task.runId (ReportResult (Object [])) `shouldThrow` runtimeMatching ["stale Activity Attempt"]

  it "a replacement receives the latest details" $ \target ->
    withAuthority target $ \authority -> do
      queue <- freshQueue
      spawnFor authority queue 1
      first' <- guarded authority "boot-a"
      (task, _) <- claimNow first' queue 30
      void (guardedHeartbeat first' queue task.taskId task.runId 1 (Just (Object [("cursor", Int 7)])))
      threadDelay 1100000
      replacement <- guarded authority "boot-b"
      (newer, details) <- awaitClaim replacement queue
      newer.taskId `shouldBe` task.taskId
      details `shouldBe` Object [("cursor", Int 7)]

  it "the same worker reconnects its transport with the same claimant and guard" $ \target ->
    withAuthority target $ \authority -> do
      queue <- freshQueue
      spawnFor authority queue 5
      connection <- Pg.connect (dsnOf target) False
      facade <- reconnectableGuardedDispatch (dsnOf target) connection "worker-incarnation-a"
      ( do
          Just (task, _) <- reconnectableClaim facade queue 30
          firstTransport <- reconnectableConnection facade
          Pg.close firstTransport
          reconnectableHeartbeat facade queue task.taskId task.runId 5 (Just (Object [("cursor", Int 1)]))
            `shouldReturn` Object [("cursor", Int 1)]
          current <- reconnectableConnection facade
          Pg.isClosed current `shouldReturn` False
          reconnectableClaimant facade `shouldReturn` "worker-incarnation-a"
          ((.claimant) <$> reconnectableGuard facade) `shouldReturn` "worker-incarnation-a"
          restarted <- guarded authority "worker-incarnation-b"
          guardedHeartbeat restarted queue task.taskId task.runId 5 Nothing `shouldThrow` runtimeMatching ["stale Activity Attempt"]
          Pg.isClosed firstTransport `shouldReturn` True
        )
        `finally` reconnectableClose facade
      reconnectableConnection facade >>= Pg.isClosed >>= (`shouldBe` True)

  it "details and lease roll back together when the commit fails after the checkpoint write" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      spawnFor authority queue 30
      baseline <- guarded authority "atomic-writer"
      (task, _) <- claimNow baseline queue 30
      void (guardedHeartbeat baseline queue task.taskId task.runId 30 (Just (Object [("cursor", Int 1)])))
      previous <- expiresAt observer queue task.runId
      withAuthority target $ \injectedConnection -> do
        wrote <- newIORef False
        let plain = sessionOf injectedConnection
            injected =
              plain
                { run = \statement params -> do
                    rows' <- plain.run statement params
                    when ("set_task_checkpoint_state" `T.isInfixOf` Pg.sqlSource statement) (writeIORef wrote True)
                    pure rows'
                , commit = do
                    w <- readIORef wrote
                    if w then throwIO (userError "injected after checkpoint write") else plain.commit
                }
        g <- guardedDispatch injected (Just "atomic-writer")
        guardedHeartbeat g queue task.taskId task.runId 300 (Just (Object [("cursor", Int 2)]))
          `shouldThrow` (\e -> "injected after checkpoint write" `T.isInfixOf` T.pack (show (e :: IOError)))
      expiresAt observer queue task.runId `shouldReturn` previous
      check <- guarded authority "atomic-writer"
      latestDetails check queue task.taskId `shouldReturn` Object [("cursor", Int 1)]

  forM_ ["claimant", "expired", "replaced", "terminal"] $ \cause ->
    forM_ ["heartbeat", "details", "success", "failure"] $ \operation ->
      it ("every attempt operation rejects every stale custody cause: " <> operation <> " / " <> cause) $ \target ->
        withAuthority target $ \authority -> withObserver target $ \observer -> do
          queue <- freshQueue
          spawnFor authority queue 30
          owner <- guarded authority "owner"
          (task, _) <- claimNow owner queue 30
          actor <-
            if cause == "claimant"
              then guarded authority "impostor"
              else do
                if cause == "terminal"
                  then Pg.execute_ observer (Pg.sql ("UPDATE absurd.r_" <> queue <> " SET state = 'completed' WHERE run_id = %s")) [textParam task.runId]
                  else do
                    Pg.execute_
                      observer
                      (Pg.sql ("UPDATE absurd.r_" <> queue <> " SET claim_expires_at = absurd.current_time() - interval '1 second' WHERE run_id = %s"))
                      [textParam task.runId]
                    when (cause == "replaced") $ do
                      newer <-
                        scalar
                          observer
                          ( Pg.sql
                              ( "UPDATE absurd.r_"
                                  <> queue
                                  <> " SET run_id = gen_random_uuid(), claimed_by = 'replacement', "
                                  <> "claim_expires_at = absurd.current_time() + interval '30 seconds' WHERE run_id = %s RETURNING run_id"
                              )
                          )
                          [textParam task.runId]
                      newer `shouldNotBe` Just task.runId
                pure owner
          let call = case operation of
                "heartbeat" -> void (guardedHeartbeat actor queue task.taskId task.runId 30 Nothing)
                "details" -> void (guardedHeartbeat actor queue task.taskId task.runId 30 (Just (Object [("cursor", Int 2)])))
                "success" -> guardedTerminal actor queue task.taskId task.runId (ReportResult (Object [("ok", Bool True)]))
                _ -> guardedTerminal actor queue task.taskId task.runId (ReportFailure (FailureMessage "failed"))
          call `shouldThrow` runtimeMatching ["stale Activity Attempt"]

  it "an explicit null is durable and invalid details fail before lease renewal" $ \target ->
    withAuthority target $ \authority -> withObserver target $ \observer -> do
      queue <- freshQueue
      spawnFor authority queue 30
      g <- guarded authority "owner"
      (task, _) <- claimNow g queue 30
      before <- expiresAt observer queue task.runId
      guardedHeartbeat g queue task.taskId task.runId 300 (Just (Object [("bad", Float (0 / 0))]))
        `shouldThrow` (\(e :: DispatchError) -> matchesInOrder ["heartbeat details"] (T.pack (show e)))
      expiresAt observer queue task.runId `shouldReturn` before
      guardedHeartbeat g queue task.taskId task.runId 30 (Just Null) `shouldReturn` Null
      latestDetails g queue task.taskId `shouldReturn` Null
      rows' <-
        rowsOf
          observer
          ( Pg.sql
              ( "SELECT checkpoint_name, state, state IS NULL, jsonb_typeof(state), status, owner_run_id "
                  <> "FROM absurd.c_"
                  <> queue
                  <> " WHERE task_id = %s AND checkpoint_name = %s"
              )
          )
          [textParam task.taskId, textParam "__impetus_latest_activity_details_v1"]
      rows' `shouldBe` [[Just "__impetus_latest_activity_details_v1", Just "null", Just "f", Just "null", Just "committed", Just task.runId]]

-- Silence unused-binding warnings for helpers kept for symmetry.
_unused :: (Maybe PostgresError, Bool, Bool)
_unused = (Nothing, isJust (Nothing :: Maybe ()), isNothing (Nothing :: Maybe ()))
