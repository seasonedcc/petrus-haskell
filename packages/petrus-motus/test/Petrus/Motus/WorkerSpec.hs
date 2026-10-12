-- | @tests/petrus/motus/worker/test_worker_runtime.py@: the synchronous
-- Worker contract and its Local integration. (The Engine-level byte-identical
-- history test lives with the Engine: petrus-engine's
-- @Petrus.Engine.WorkerTopologySpec@.)
module Petrus.Motus.WorkerSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad (void)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Foreign.C.Error (eNOENT, errnoToIOError)
import Petrus.Activity
import Petrus.Activity qualified as A
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch
import Petrus.Motus.Dispatch qualified as D
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Dispatch.LocalSupport (openScratchDispatch, openScratchWorker, withScratch)
import Petrus.Motus.PythonException (exceptionMessage)
import Petrus.Motus.PythonException qualified as Python
import Petrus.Motus.Worker
import Petrus.Motus.WorkerSupport
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
import Test.Hspec hiding (context)
import Petrus.TestSupport (valid)

policyWith :: (ExecutionPolicyFields -> ExecutionPolicyFields) -> ExecutionPolicy
policyWith tweak = either (error . T.unpack) id (executionPolicy (tweak (policyFields defaultExecutionPolicy)))

withPolicy :: (ExecutionPolicyFields -> ExecutionPolicyFields) -> ActivityInvocation -> ActivityInvocation
withPolicy tweak inv = valid (activityInvocation (invocationFields inv) {policy = policyWith tweak})

failureType :: AttemptFailure -> Text
failureType = \case
  FailureException err -> (Python.pythonException err).name
  FailureMessage _ -> "str"
  FailureClassified _ -> "ActivityFailure"

failureText :: AttemptFailure -> Text
failureText = \case
  FailureException err -> exceptionMessage err
  FailureMessage m -> m
  FailureClassified f -> (failureFields f).failureError

spec :: Spec
spec = do
  it "an exception is recorded as the Python exception it stands for" $ do
    let enoent = toException (errnoToIOError "open" eNOENT Nothing (Just "/tmp/x"))
        python = Python.pythonException
    Python.pythonExceptionRepr (python enoent) `shouldBe` "FileNotFoundError(2, 'No such file or directory')"
    Python.pythonExceptionStr (python enoent) `shouldBe` "[Errno 2] No such file or directory"
    Python.pythonExceptionRepr (python (toException (DispatchError "refused"))) `shouldBe` "ValueError('refused')"
    Python.pythonExceptionRepr (python (toException (LookupError ""))) `shouldBe` "LookupError()"

  it "worker dispatch is the exact runtime checkable worker surface" $ do
    -- The surface is a record of exactly the six custody operations; a value
    -- of it is a WorkerDispatch by construction.
    provider <- newStrictProvider []
    let surface = strictDispatch provider
    surface.claim `shouldReturn` Nothing
    surface.wait 0 `shouldReturn` False

  it "worker runs activity with exact attempt context and heartbeat then stops" $ do
    let claimed = providerAttempt "work" (Object [("cursor", Int 1)]) (Just "tenant-one")
    provider <- newStrictProvider [claimed]
    observed <- newIORef []
    workerRef <- newEmptyMVar
    events <- newEventLog
    let work _ context = do
          latest <- context.latestDetails
          writeIORef
            observed
            [ ("attempt_id", String context.attemptId)
            , ("epoch", String context.epoch)
            , ("claimant", String context.claimant)
            , ("instance", maybe Null String context.instance')
            , ("latest", latest)
            ]
          _ <- context.heartbeat (Just (Object [("cursor", Int 2)]))
          readMVar workerRef >>= stopWorker
          pure (Object [("ok", Bool True)])
    worker <- newWorker (strictDispatch provider) (Map.fromList [("work", work)]) (quietOptions events)
    putMVar workerRef worker
    runWorker worker 0
    readIORef observed
      `shouldReturn` [ ("attempt_id" :: Text, String claimed.attemptId)
                     , ("epoch", String claimed.epoch)
                     , ("claimant", String claimed.claimant)
                     , ("instance", String "tenant-one")
                     , ("latest", Object [("cursor", Int 1)])
                     ]
    readIORef provider.heartbeats `shouldReturn` [(claimed, Just (Object [("cursor", Int 2)]))]
    readIORef provider.completed `shouldReturn` [(claimed, Object [("ok", Bool True)])]
    readIORef provider.closed `shouldReturn` True
    label <- pure (workerIdOf worker)
    eventsOf events
      `shouldReturn` [ Object [("ready", Bool True), ("worker", String label)]
                     , Object [("worker", String label), ("processed", String "provider-attempt"), ("activity", String "work"), ("outcome", String "completed")]
                     ]

  it "missing activity and json unfaithful result report failure" $ do
    -- A Haskell Activity cannot return a non-JSON object (the reference's
    -- TypeError case); the JSON-unfaithful result left is a non-finite
    -- number, refused by json.dumps(allow_nan=False) with ValueError.
    provider <- newStrictProvider [providerAttempt "missing" Null Nothing, providerAttempt "bad" Null Nothing]
    events <- newEventLog
    worker <- newWorker (strictDispatch provider) (Map.fromList [("bad", \_ _ -> pure (Array [Float (0 / 0)]))]) (quietOptions events)
    runAvailable worker maxBound `shouldReturn` 2
    failures <- map snd <$> readIORef provider.failed
    map failureType failures `shouldBe` ["LookupError", "ValueError"]
    map failureText failures
      `shouldBe` [ "no activity implementation for 'missing': this worker implements ['bad']"
                 , "Out of range float values are not JSON compliant: nan"
                 ]

  it "scoped resolver refuses missing scope instead of falling back to default" $ do
    provider <- newStrictProvider [providerAttempt "work" Null Nothing]
    events <- newEventLog
    worker <-
      newWorker
        (strictDispatch provider)
        (Map.fromList [("work", \_ _ -> pure (String "wrong-default"))])
        (quietOptions events) {resolver = Just (\_ _ -> pure Nothing)}
    runAvailable worker 1 `shouldReturn` 1
    readIORef provider.completed `shouldReturn` []
    failures <- map snd <$> readIORef provider.failed
    map failureType failures `shouldBe` ["LookupError"]
    map failureText failures `shouldSatisfy` all ("requires an Activity Attempt instance" `T.isInfixOf`)

  it "local worker provider executes and engine collects" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    engine <- openScratchDispatch path "one" Local.defaultLocalDispatchOptions {Local.defaultQueue = "cpu"}
    Local.dispatch engine 1 (withPolicy (\p -> p {A.attempts = 1}) (valid (invocation "work" (Object [("value", Int 2)]))))
    provider <- openScratchWorker path Local.defaultLocalWorkerOptions {Local.workerQueues = ["cpu"], Local.workerId = Just "test"}
    events <- newEventLog
    worker <- newWorker (Local.toWorkerDispatch provider) (Map.fromList [("work", \inv _ -> pure inv.input)]) (quietOptions events)
    _ <- runAvailable worker maxBound
    Local.collect engine `shouldReturn` [(1, Succeeded (Object [("value", Int 2)]))]

  it "one worker resolves scoped and default modules for isolated instances" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    one <- openScratchDispatch path "one" Local.defaultLocalDispatchOptions
    two <- openScratchDispatch path "two" Local.defaultLocalDispatchOptions
    Local.dispatch one 1 (valid (invocation "publish" Null))
    Local.dispatch two 1 (valid (invocation "publish" Null))
    observed <- newIORef []
    let implementation label _ context = do
          modifyIORef' observed (++ [(label, context.instance')])
          pure (Object [("module", String label), ("instance", maybe Null String context.instance')])
        modules = Map.fromList [("one" :: Text, Map.fromList [("publish" :: Text, implementation "scoped")])]
    provider <- openScratchWorker path Local.defaultLocalWorkerOptions {Local.workerId = Just "shared"}
    events <- newEventLog
    worker <-
      newWorker
        (Local.toWorkerDispatch provider)
        (Map.fromList [("publish", implementation "default")])
        (quietOptions events) {resolver = Just (\inst activity -> pure (Map.lookup inst modules >>= Map.lookup activity))}
    runAvailable worker 2 `shouldReturn` 2
    readIORef observed `shouldReturn` [("scoped", Just "one"), ("default", Just "two")]
    Local.collect one `shouldReturn` [(1, Succeeded (Object [("module", String "scoped"), ("instance", String "one")]))]
    Local.collect one `shouldReturn` []
    Local.collect two `shouldReturn` [(1, Succeeded (Object [("module", String "default"), ("instance", String "two")]))]
    closeWorker worker

  it "reconstructed worker resolves delayed retry from durable instance scope" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.db"
    dispatch <- openScratchDispatch path "one" Local.defaultLocalDispatchOptions
    Local.dispatch dispatch 1 (withPolicy (\p -> p {A.attempts = 2, initialInterval = FloatNumber 0.02, heartbeatTimeout = 1}) (valid (invocation "publish" Null)))
    let resolver' inst activity = do
          (inst, activity) `shouldBe` ("one", "publish")
          pure . Just $ \_ context ->
            if context.epoch == "1"
              then activityError (ActivityFailureFields "transient" "ActivityError" Null True Nothing)
              else pure (Object [("instance", maybe Null String context.instance'), ("epoch", String context.epoch)])
        build label = do
          provider <- openScratchWorker path Local.defaultLocalWorkerOptions {Local.workerId = Just label}
          events <- newEventLog
          newWorker (Local.toWorkerDispatch provider) Map.empty (quietOptions events) {resolver = Just resolver'}
    first <- build "first"
    runAvailable first 1 `shouldReturn` 1
    closeWorker first
    Local.collect dispatch `shouldReturn` []
    threadDelay 30000
    replacement <- build "replacement"
    runAvailable replacement 1 `shouldReturn` 1
    closeWorker replacement
    Local.collect dispatch `shouldReturn` [(1, Succeeded (Object [("instance", String "one"), ("epoch", String "2")]))]

  it "bounded worker pump does not wait or close and refuses concurrent driving" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    provider <- newStrictProvider [providerAttempt "work" Null Nothing, providerAttempt "work" Null Nothing]
    events <- newEventLog
    let work _ _ = putMVar entered () >> readMVar release >> pure (String "done")
    worker <- newWorker (strictDispatch provider) (Map.fromList [("work", work)]) (quietOptions events)
    finished <- newEmptyMVar
    _ <- forkIO (runAvailable worker 1 >>= putMVar finished)
    takeMVar entered
    runAvailable worker 1 `shouldThrow` (\(RuntimeError m) -> "already being driven" `T.isInfixOf` m)
    putMVar release ()
    takeMVar finished `shouldReturn` 1
    length <$> readIORef provider.attempts `shouldReturn` 1
    readIORef provider.closed `shouldReturn` False
    closeWorker worker
    closeWorker worker
    readIORef provider.closed `shouldReturn` True

  it "worker close failure releases driver guard and leaves worker closed" $ do
    provider <- newStrictProvider [providerAttempt "work" Null Nothing]
    workerRef <- newEmptyMVar
    events <- newEventLog
    let refusing = (strictDispatch provider) {D.close = ioError (userError "close refused")}
        work _ _ = readMVar workerRef >>= stopWorker >> pure (String "done")
    worker <- newWorker refusing (Map.fromList [("work", work)]) (quietOptions events)
    putMVar workerRef worker
    runWorker worker 0 `shouldThrow` (\e -> "close refused" `T.isInfixOf` T.pack (show (e :: IOException)))
    runAvailable worker 0 `shouldThrow` (\(RuntimeError m) -> "closed" `T.isInfixOf` m)
    closeWorker worker

  it "killed local worker reassigns with recovered heartbeat details" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.sqlite3"
        barrier = dir </> "claimed"
    dispatch <- openScratchDispatch path "one" Local.defaultLocalDispatchOptions
    Local.dispatch
      dispatch
      1
      (withPolicy (\p -> p {A.attempts = 2, heartbeatTimeout = 1}) (valid (invocation "work" (Object [("mode", String "crash"), ("barrier", String (T.pack barrier))]))))
    bracket (startLocalWorker path) (stopProcess . fst) $ \(first, _) -> do
      waitForFile barrier first
      getPid first >>= maybe (pure ()) (signalProcess sigKILL)
      void (waitForProcess first)
      threadDelay 1050000
      bracket (startLocalWorker path) (stopProcess . fst) $ \_ -> do
        Local.waitForResults dispatch 10 `shouldReturn` True
        Local.collect dispatch `shouldReturn` [(1, Succeeded (Object [("cursor", Int 7)]))]

  it "sigterm drains the in flight local activity before worker exit" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.sqlite3"
        barrier = dir </> "running"
    dispatch <- openScratchDispatch path "one" Local.defaultLocalDispatchOptions
    Local.dispatch
      dispatch
      1
      (withPolicy (\p -> p {A.attempts = 1}) (valid (invocation "work" (Object [("mode", String "drain"), ("barrier", String (T.pack barrier))]))))
    bracket (startLocalWorker path) (stopProcess . fst) $ \(process, _) -> do
      waitForFile barrier process
      terminateProcess process
      waitForProcess process `shouldReturn` ExitSuccess
      Local.collect dispatch `shouldReturn` [(1, Succeeded (Object [("cursor", Null)]))]

  -- test_worker_topology.py's TestActivityRegistry case, over the strict
  -- provider instead of Absurd custody: the refusal is the Worker's own.
  -- The reference's other two cases (a non-string name, a non-callable
  -- implementation) are unrepresentable in a Map Text Activity.
  describe "worker refuses invalid activity registries" $ do
    let refuses registry message = do
          provider <- newStrictProvider []
          events <- newEventLog
          void (newWorker (strictDispatch provider) registry (quietOptions events))
            `shouldThrow` (\(ValueError m) -> m == message)
    it "{}" $ refuses Map.empty "Worker requires default Activities or a scoped resolver"
    it "{\"\": activity}" $ refuses (Map.fromList [("", \_ _ -> pure Null)]) "Worker activities must map non-empty string names to callables"
