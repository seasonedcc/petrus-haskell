-- | Parity: the Worker-side tests of
-- @tests/petrus/motus/worker/test_worker_topology.py@, the ones about the
-- Worker process and its registry over Absurd custody:
-- @TestActivityRegistry@ (7 tests, 11 cases) and @TestDispatchDoorbell@
-- (2 tests). The Engine-side tests of the same file are
-- "Petrus.Engine.AbsurdSpec".
--
-- The process-grain cases run twice: against the reference's own Worker
-- process and against this port's Worker process (this suite's
-- executable as the Worker entry point, through the
-- "Petrus.Motus.Worker.Cli" 'ProviderPlugins' Absurd slot).
--
-- Without @PETRUS_TEST_POSTGRES@ every example is pending, saying so.
module Petrus.Engine.Absurd.WorkerTopologySpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, bracket, throwIO, try)
import Control.Monad (forM_, void)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Activity (ActivityInvocation, ActivityInvocationFields (..), activityInvocation, defaultExecutionPolicy)
import Petrus.TestSupport (valid)
import Petrus.Engine.Absurd.Helpers
import Petrus.Engine.Absurd.Support
import Petrus.Json (Json (..), lookupMember, parseJson, surrogateRefusingLoads)
import Petrus.Motus.Dispatch.Absurd
  ( defaultAbsurdDispatchOptions
  , defaultAbsurdWorkerOptions
  , encodeInvocation
  , openAbsurdWorkerDispatch
  , toWorkerDispatch
  , workerQueues
  )
import Petrus.Motus.Dispatch.Absurd qualified as Absurd
import Petrus.Motus.Worker (closeWorker, defaultWorkerOptions, newWorker)
import Petrus.Motus.Worker qualified as Worker
import Petrus.Motus.Worker.Cli (ProviderPlugins (..), noPlugins, workerMainWith)
import Petrus.Postgres (jsonbParam, textParam)
import Petrus.Postgres qualified as Pg
import Test.Hspec

spec :: Spec
spec = absurdEngineSpec $ do
  describe "TestActivityRegistry" registrySpec
  forM_ [PythonWorker, HaskellWorker] $ \kind ->
    describe ("with a " <> label kind) $ do
      describe "TestActivityRegistry (process grain)" (unregisteredSpec kind)
      describe "TestDispatchDoorbell" (doorbellSpec kind)

label :: WorkerKind -> String
label = \case
  PythonWorker -> "reference Worker process (python -m petrus.motus.worker)"
  HaskellWorker -> "Haskell Worker process (workerMain with the Absurd provider slot)"

quiet :: Worker.WorkerOptions
quiet = defaultWorkerOptions {Worker.output = \_ -> pure ()}

echo :: Worker.Activity
echo inv _ = pure inv.input

openOn :: Fixture -> [Text] -> IO Absurd.AbsurdWorkerDispatch
openOn fixture subscription = openAbsurdWorkerDispatch fixture.dsn defaultAbsurdWorkerOptions {Absurd.queues = subscription}

jsonb :: Json -> Pg.Param
jsonb = either (error . show) id . jsonbParam

-- | A raw @absurd.spawn_task(queue, name, params, options)@: no adapter,
-- so no doorbell.
spawnRaw :: Fixture -> Text -> ActivityInvocation -> Json -> IO ()
spawnRaw fixture queue inv options =
  bracket (Pg.connect fixture.dsn True) Pg.close $ \connection ->
    void $
      Pg.execute_
        connection
        "SELECT absurd.spawn_task(%s, %s, %s, %s)"
        [textParam queue, textParam inv.activity, jsonb (encodeInvocation inv), jsonb options]

invocationOf :: Text -> Text -> Text -> ActivityInvocation
invocationOf activity identifier idempotency =
  valid . activityInvocation $
    ActivityInvocationFields
      { activity
      , input = Object [("id", String identifier)]
      , policy = defaultExecutionPolicy
      , correlation = Nothing
      , idempotency = Just idempotency
      }

-- | The fake provider of @test_main_defaults_queue...@ observes the
-- subscription and stops the entry point (the reference fakes the Worker
-- class to the same end).
newtype Observed = Observed [Text] deriving stock (Show)

instance Exception Observed

-- ---------------------------------------------------------------------------
-- TestActivityRegistry

registrySpec :: SpecWith Fixture
registrySpec = do
  it "the claimant is reused by one process definition and new for a new one" $ \fixture -> do
    processProvider <- openOn fixture [capability]
    first <- newWorker (toWorkerDispatch processProvider) (Map.fromList [("spark_work", echo)]) quiet
    let sameProcessReconnectClaimant = processProvider.claimant
    restartedProvider <- openOn fixture [capability]
    second <- newWorker (toWorkerDispatch restartedProvider) (Map.fromList [("spark_work", echo)]) quiet
    processProvider.claimant `shouldBe` sameProcessReconnectClaimant
    restartedProvider.claimant `shouldNotBe` processProvider.claimant
    closeWorker first
    closeWorker second

  it "the Worker snapshots its queue sequence" $ \fixture -> do
    provider <- openOn fixture [capability]
    worker <- newWorker (toWorkerDispatch provider) (Map.fromList [("spark_work", echo)]) quiet
    workerQueues provider `shouldBe` [capability]
    closeWorker worker

  describe "the Worker refuses invalid Activity registries" $ do
    it "{} (no Activities and no resolver)" $ \fixture -> do
      provider <- openOn fixture [capability]
      newWorker (toWorkerDispatch provider) Map.empty quiet `raisesMatching` ["default Activities or a scoped resolver"]
      Absurd.close provider
    it "{'': ...} (an empty name)" $ \fixture -> do
      provider <- openOn fixture [capability]
      newWorker (toWorkerDispatch provider) (Map.fromList [("", \_ _ -> pure Null)]) quiet
        `raisesMatching` ["map non-empty string names to callables"]
      Absurd.close provider

  it "the Worker refuses an empty queue subscription" $ \fixture ->
    openOn fixture [] `raisesMatching` ["at least one queue"]

  describe "main defaults the queue and preserves deduplicated flag order" $
    forM_
      [ ([], ["default"])
      , (["--queue", "one", "--queue", "two", "--queue", "one"], ["one", "two"])
      ]
      $ \(flags, expected) ->
        it (show flags) $ \(_ :: Fixture) -> do
          let plugins = noPlugins {absurd = Just (\_ queues -> throwIO (Observed queues))}
              registries = Map.fromList [("fake:registry", pure (Map.fromList [("work", \_ _ -> pure Null)]))]
          outcome <-
            try @Observed $
              workerMainWith
                "python -m petrus.motus.worker"
                registries
                plugins
                (["--provider", "absurd", "--dsn", "postgresql:///unused", "--registry", "fake:registry"] <> flags)
                Nothing
          case outcome of
            Left (Observed queues) -> queues `shouldBe` expected
            Right () -> expectationFailure "the provider factory was never called"

-- | @test_the_worker_refuses_an_unregistered_activity@.
unregisteredSpec :: WorkerKind -> SpecWith Fixture
unregisteredSpec kind =
  it "the Worker refuses an unregistered Activity" $ \fixture -> do
    queue <- fresh "capmix_" 8
    worker <- startWorker fixture kind workerOptions {queues = [queue], pollInterval = 0.1}
    identifier <- fresh "mix-" 6
    idempotency <- fresh "effect-mix-" 6
    spawnRaw fixture queue (invocationOf "not_registered" identifier idempotency) (Object [("max_attempts", Int 1)])
    void (awaitEventWithin 10 worker (outcomeIs "failed"))
    rows <-
      rowsText
        fixture
        (sqlOf ["SELECT t.state, r.failure_reason::text FROM absurd.t_", queue, " t JOIN absurd.r_", queue, " r ON r.run_id = t.last_attempt_run"])
        []
    case rows of
      [[state, reason]] -> do
        state `shouldBe` "failed"
        case parseReason reason of
          Just (String message) -> message `shouldSatisfy` T.isInfixOf "no activity implementation"
          other -> expectationFailure ("unexpected failure_reason " <> show other)
      other -> expectationFailure ("unexpected rows " <> show other)
  where
    parseReason reason = either (const Nothing) (lookupMember "message") (parseJson surrogateRefusingLoads (TE.encodeUtf8 reason))

-- ---------------------------------------------------------------------------
-- TestDispatchDoorbell

doorbellSpec :: WorkerKind -> SpecWith Fixture
doorbellSpec kind = do
  it "the doorbell wakes a Worker whose poll could not have" $ \fixture -> do
    -- The Worker's poll floor is 30 s; a task processed within seconds is
    -- explicable only by the dispatch doorbell.
    bellQueue <- fresh "bell_" 8
    worker <- startWorker fixture kind workerOptions {queues = [bellQueue], pollInterval = 30}
    threadDelay 500000 -- let the empty first drain settle onto the LISTEN wait
    instance' <- freshTopo "topo"
    identifier <- fresh "bell-" 6
    idempotency <- fresh "effect-bell-" 6
    bracket (Pg.connect fixture.dsn False) Pg.close $ \authority -> do
      adapter <- Absurd.absurdDispatch authority instance' defaultAbsurdDispatchOptions {Absurd.defaultQueue = bellQueue}
      Absurd.dispatch adapter 1 (invocationOf "spark_work" identifier idempotency)
      started <- getMonotonicTime
      Pg.commit authority -- the bell rings here
      void (awaitEventWithin 10 worker (outcomeIs "completed"))
      elapsed <- subtract started <$> getMonotonicTime
      elapsed `shouldSatisfy` (< 8) -- well under the 30 s poll floor

  it "with the doorbell suppressed, the poll safety net still dispatches" $ \fixture -> do
    -- No NOTIFY is ever sent (a raw spawn_task, no adapter): the Worker's
    -- poll interval alone finds the work.
    pollQueue <- fresh "poll_" 8
    worker <- startWorker fixture kind workerOptions {queues = [pollQueue], pollInterval = 0.5}
    threadDelay 300000
    identifier <- fresh "poll-" 6
    idempotency <- fresh "effect-poll-" 6
    spawnRaw fixture pollQueue (invocationOf "spark_work" identifier idempotency) (Object [])
    void (awaitEventWithin 10 worker (outcomeIs "completed"))
