-- | @tests/petrus/motus/worker/test_async_worker.py@: the asynchronous
-- Worker's concurrency, custody ownership, cancellation, and error
-- precedence contract. Python task cancellation is an asynchronous
-- exception thrown at the thread running 'runAsyncWorker' (or at an
-- Activity's helper thread).
module Petrus.Motus.AsyncWorkerSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad (forM_, unless, void, when)
import Data.IORef
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch hiding (WorkerDispatch (..))
import Petrus.Motus.Dispatch qualified as D
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Dispatch.LocalSupport (withScratch)
import Petrus.Motus.PythonException qualified as Python
import Petrus.Motus.Worker
import Petrus.Motus.Worker qualified as W
import Petrus.Motus.Worker.Cli
import Petrus.Motus.Internal.Argparse (ParseOutcome (..), parseArguments)
import Petrus.Motus.WorkerSupport
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Hspec hiding (context)

-- | The reference's @SharedProviders@: one provider per lane, recording
-- every thread that touched it.
data Shared = Shared
  { pool :: MVar [ActivityAttempt]
  , owners :: IORef (Map Int (Set ThreadId))
  , completed :: IORef [(ActivityAttempt, Json)]
  , closedCount :: IORef Int
  }

newShared :: [ActivityAttempt] -> IO Shared
newShared attempts = Shared <$> newMVar attempts <*> newIORef Map.empty <*> newIORef [] <*> newIORef 0

sharedFactory :: Shared -> IO D.WorkerDispatch
sharedFactory s = do
  owner <- myThreadId
  lane <- atomicModifyIORef' s.owners (\m -> (Map.insert (Map.size m) (Set.singleton owner) m, Map.size m))
  let touch = myThreadId >>= \t -> atomicModifyIORef' s.owners (\m -> (Map.adjust (Set.insert t) lane m, ()))
  pure
    D.WorkerDispatch
      { D.claim = touch >> modifyMVar s.pool (\case [] -> pure ([], Nothing); next : rest -> pure (rest, Just next))
      , D.heartbeat = \_ details -> touch >> pure (maybe Null id details)
      , D.complete = \attempt result -> touch >> atomicModifyIORef' s.completed (\c -> (c ++ [(attempt, result)], ()))
      , D.fail = \_ failure -> throwIO (userError (show failure))
      , D.wait = \_ -> touch >> pure False
      , D.close = touch >> atomicModifyIORef' s.closedCount (\n -> (n + 1, ()))
      }

-- | A provider that never has work.
idleProvider :: IORef (Maybe ThreadId) -> MVar () -> D.WorkerDispatch
idleProvider closer closed =
  D.WorkerDispatch
    { D.claim = pure Nothing
    , D.heartbeat = \_ details -> pure (maybe Null id details)
    , D.complete = \_ _ -> throwIO (userError "no Attempt")
    , D.fail = \_ _ -> throwIO (userError "no Attempt")
    , D.wait = \_ -> pure False
    , D.close = myThreadId >>= writeIORef closer . Just >> void (tryPutMVar closed ())
    }

-- | Native access whose every operation refuses unless overridden.
refusingAccess :: WorkerAccess
refusingAccess =
  WorkerAccess
    { ready = pure ()
    , claim = \_ -> throwIO (userError "unexpected claim")
    , heartbeat = \_ _ details -> pure (maybe Null id details)
    , complete = \_ _ _ -> throwIO (userError "unexpected complete")
    , fail = \_ _ failure -> throwIO (userError ("unexpected fail: " <> show failure))
    , wait = \_ _ -> pure False
    , close = pure ()
    }

-- | Run a Worker on its own thread; answer its thread and outcome.
start :: AsyncWorker -> Double -> IO (ThreadId, MVar (Either SomeException ()))
start worker poll = do
  done <- newEmptyMVar
  tid <- forkIO (try (runAsyncWorker worker poll) >>= putMVar done)
  pure (tid, done)

-- | Await a started Worker's outcome within a deadline.
finish :: Double -> MVar (Either SomeException ()) -> IO (Either SomeException ())
finish seconds done =
  timeout (round (seconds * 1000000)) (takeMVar done) >>= \case
    Nothing -> expectationFailure "the Worker did not finish" >> pure (Right ())
    Just outcome -> pure outcome

-- | Python's @task.cancel(message)@ followed by the reference tests' one
-- event-loop turn for the cancellation to be handled.
cancel :: ThreadId -> Text -> IO ()
cancel tid message = throwTo tid (CancelledError message) >> threadDelay 20000

isCancelled :: Either SomeException () -> Bool
isCancelled = \case
  Left err -> isJust (fromException err :: Maybe CancelledError)
  Right () -> False

raisedRuntime :: Text -> Either SomeException () -> Bool
raisedRuntime fragment = \case
  Left err -> case fromException err of
    Just (RuntimeError message) -> fragment `T.isInfixOf` message
    Nothing -> False
  Right () -> False

failureMessage :: AttemptFailure -> (Text, Text)
failureMessage = \case
  FailureException err -> let python = Python.pythonException err in (python.className, python.message)
  FailureMessage m -> ("str", m)
  FailureClassified f -> ("ActivityFailure", (failureFields f).failureError)

within :: Double -> IO a -> IO a
within seconds action =
  timeout (round (seconds * 1000000)) action >>= maybe (throwIO (userError "timed out")) pure

spec :: Spec
spec = do
  it "async decorator converts typed payload and json result" $ do
    -- The Activities component's typed definition is colourless: the same
    -- definition runs under either Worker.
    let declaration = either (error . T.unpack) id (activityDeclaration "io" Nothing)
        definition = defineActivity declaration ["item"] $ \arguments _ -> case lookup "item" arguments of
          Just (Object [("value", Int n)]) -> pure (Object [("value", Int (n + 1))])
          other -> error (show other)
        io inv context = callActivity definition inv context >>= either (throwIO . ValueError) pure
    s <- newShared [asyncAttempt 2]
    events <- newEventLog
    worker <- newAsyncWorker (sharedFactory s) (Map.fromList [("io", io)]) 1 (quietOptions events)
    (_, done) <- start worker 0
    within 2 (let loop = readIORef s.completed >>= \c -> when (null c) (threadDelay 1000 >> loop) in loop)
    stopAsyncWorker worker
    finish 2 done >>= (`shouldSatisfy` either (const False) (const True))
    map snd <$> readIORef s.completed `shouldReturn` [Object [("value", Int 3)]]

  it "raw coroutine function and async callable are context aware async activities" $ do
    -- One Activity type serves both Workers (no colour to reject).
    let raw _ context = pure (String context.attemptId)
    s <- newShared []
    events <- newEventLog
    void (newAsyncWorker (sharedFactory s) (Map.fromList [("raw", raw)]) 1 (quietOptions events))
    p <- sharedFactory s
    void (newWorker p (Map.fromList [("raw", raw)]) (quietOptions events))

  it "cli defaults to sync bridge and validates explicit native access" $ do
    let parse argv = case parseArguments (workerParser "petrus-worker") argv of
          Parsed parsed -> parseWorkerArguments Nothing parsed
          other -> error (show other)
        defaults = parse ["--provider", "local", "--path", "dispatch.db", "--registry", "fake:registry"]
    defaults.custodyAccess `shouldBe` SyncBridge
    defaults.maxOperationSockets `shouldBe` 8
    let invalid = parse ["--provider", "local", "--path", "dispatch.db", "--registry", "fake:registry", "--custody-access", "native-zeromq"]
    validateProviderArguments invalid `shouldBe` Left "native-zeromq custody access requires async execution with the zeromq provider"

  it "sync and async workers validate the registry before custody" $ do
    constructed <- newIORef False
    s <- newShared []
    events <- newEventLog
    let factory = writeIORef constructed True >> sharedFactory s
    newAsyncWorker factory (Map.fromList [("", \_ _ -> pure Null)]) 1 (quietOptions events)
      `shouldThrow` (\(ValueError m) -> m == "Worker activities must map non-empty string names to callables")
    readIORef constructed `shouldReturn` False

  it "async worker runs exact concurrency on event loop and owns providers by lane" $ do
    let concurrency = 3
    s <- newShared [asyncAttempt n | n <- [0 .. concurrency - 1]]
    entered <- newIORef (0 :: Int)
    peak <- newIORef (0 :: Int)
    activityThreads <- newIORef Set.empty
    allEntered <- newEmptyMVar
    release <- newEmptyMVar
    let io inv _ = do
          myThreadId >>= \t -> atomicModifyIORef' activityThreads (\ts -> (Set.insert t ts, ()))
          now <- atomicModifyIORef' entered (\n -> (n + 1, n + 1))
          atomicModifyIORef' peak (\p -> (max p now, ()))
          when (now == concurrency) $ putMVar allEntered ()
          readMVar release
          atomicModifyIORef' entered (\n -> (n - 1, ()))
          case inv.input of
            Object [("item", item)] -> pure item
            other -> pure other
    events <- newEventLog
    worker <- newAsyncWorker (sharedFactory s) (Map.fromList [("io", io)]) concurrency (quietOptions events)
    (_, done) <- start worker 0
    within 2 (takeMVar allEntered)
    stopAsyncWorker worker
    putMVar release ()
    finish 2 done >>= (`shouldSatisfy` either (const False) (const True))
    readIORef peak `shouldReturn` concurrency
    length <$> readIORef s.completed `shouldReturn` concurrency
    readIORef s.closedCount `shouldReturn` concurrency
    owners <- readIORef s.owners
    Map.size owners `shouldBe` concurrency
    all ((== 1) . Set.size) (Map.elems owners) `shouldBe` True
    activities <- readIORef activityThreads
    Set.null (Set.intersection activities (Set.unions (Map.elems owners))) `shouldBe` True
    label <- pure (asyncWorkerIdOf worker)
    take 1 <$> eventsOf events `shouldReturn` [Object [("ready", Bool True), ("worker", String label), ("concurrency", Int 3)]]

  it "async worker resolves scoped module and exposes instance context" $ do
    s <- newShared [asyncAttempt 1]
    observed <- newIORef []
    workerRef <- newEmptyMVar
    let scoped _ context = do
          modifyIORef' observed (++ [context.instance'])
          readMVar workerRef >>= stopAsyncWorker
          pure (Object [("instance", maybe Null String context.instance')])
        resolve inst activity = pure (if (inst, activity) == ("instance-1", "io") then Just scoped else Nothing)
    events <- newEventLog
    worker <- newAsyncWorker (sharedFactory s) Map.empty 1 (quietOptions events) {resolver = Just resolve}
    putMVar workerRef worker
    within 2 (runAsyncWorker worker 0)
    readIORef observed `shouldReturn` [Just "instance-1"]
    map snd <$> readIORef s.completed `shouldReturn` [Object [("instance", String "instance-1")]]

  it "native async access preserves scoped resolution" $ do
    claimed <- newIORef (Just (asyncAttempt 1))
    completed <- newIORef []
    workerRef <- newEmptyMVar
    let access =
          refusingAccess
            { claim = \_ -> atomicModifyIORef' claimed (\v -> (Nothing, v))
            , complete = \_ attempt result -> modifyIORef' completed (++ [(attempt, result)])
            }
        scoped _ context = do
          context.instance' `shouldBe` Just "instance-1"
          readMVar workerRef >>= stopAsyncWorker
          pure (String "scoped")
        resolve inst activity = pure (if (inst, activity) == ("instance-1", "io") then Just scoped else Nothing)
    events <- newEventLog
    worker <- asyncWorkerFromAccess (yield >> pure access) Map.empty 1 (quietOptions events) {resolver = Just resolve}
    putMVar workerRef worker
    within 2 (runAsyncWorker worker 0)
    readIORef completed `shouldReturn` [(asyncAttempt 1, String "scoped")]

  describe "async worker requires positive integer concurrency" $
    -- True and 1.5 are not Ints: the type refuses them.
    forM_ [0, -1] $ \concurrency -> it (show concurrency) $ do
      s <- newShared []
      events <- newEventLog
      newAsyncWorker (sharedFactory s) (Map.fromList [("work", \_ _ -> pure Null)]) concurrency (quietOptions events)
        `shouldThrow` (\(ValueError m) -> "positive integer" `T.isInfixOf` m)

  it "async worker closes initialized lanes after partial startup failure" $ do
    s <- newShared []
    constructions <- newIORef (0 :: Int)
    let factory = do
          n <- atomicModifyIORef' constructions (\c -> (c + 1, c + 1))
          when (n == 2) $ throwIO (RuntimeError "startup failed")
          sharedFactory s
    events <- newEventLog
    worker <- newAsyncWorker factory (Map.fromList [("work", \_ _ -> pure Null)]) 3 (quietOptions events)
    try (runAsyncWorker worker 0.25) >>= (`shouldSatisfy` raisedRuntime "startup failed")
    readIORef constructions `shouldReturn` 3
    readIORef s.closedCount `shouldReturn` 2

  it "caller cancellation drains claim acquired before return and then closes" $ do
    let attempt = asyncAttempt 1
    claimAcquired <- newEmptyMVar
    releaseClaim <- newEmptyMVar
    activityRan <- newEmptyMVar
    owner <- newIORef Nothing
    completers <- newIORef []
    completed <- newIORef []
    closed <- newEmptyMVar
    let provider =
          D.WorkerDispatch
            { D.claim = do
                myThreadId >>= writeIORef owner . Just
                void (tryPutMVar claimAcquired ())
                readMVar releaseClaim
                pure (Just attempt)
            , D.heartbeat = \_ details -> pure (maybe Null id details)
            , D.complete = \claimed result -> do
                myThreadId >>= \t -> modifyIORef' completers (t :)
                modifyIORef' completed (++ [(claimed, result)])
            , D.fail = \_ failure -> throwIO (userError (show failure))
            , D.wait = \_ -> pure False
            , D.close = myThreadId >>= \t -> modifyIORef' completers (t :) >> putMVar closed ()
            }
        work _ _ = putMVar activityRan () >> pure (String "done")
    events <- newEventLog
    worker <- newAsyncWorker (pure provider) (Map.fromList [("io", work)]) 1 (quietOptions events)
    (tid, done) <- start worker 0
    within 3 (takeMVar claimAcquired)
    cancel tid ""
    isEmptyMVar done `shouldReturn` True
    putMVar releaseClaim ()
    within 2 (takeMVar activityRan)
    finish 2 done >>= (`shouldSatisfy` isCancelled)
    isEmptyMVar closed `shouldReturn` False
    readIORef completed `shouldReturn` [(attempt, String "done")]
    lane <- readIORef owner
    readIORef completers >>= (`shouldSatisfy` all ((== lane) . Just))

  it "caller cancellation during blocked factory closes after startup settles" $ do
    factoryEntered <- newEmptyMVar
    releaseFactory <- newEmptyMVar
    closed <- newEmptyMVar
    owner <- newIORef Nothing
    closer <- newIORef Nothing
    let factory = do
          myThreadId >>= writeIORef owner . Just
          putMVar factoryEntered ()
          readMVar releaseFactory
          pure (idleProvider closer closed)
    events <- newEventLog
    worker <- newAsyncWorker factory (Map.fromList [("io", \_ _ -> pure Null)]) 1 (quietOptions events)
    (tid, done) <- start worker 0.25
    within 3 (takeMVar factoryEntered)
    cancel tid ""
    isEmptyMVar done `shouldReturn` True
    putMVar releaseFactory ()
    finish 2 done >>= (`shouldSatisfy` isCancelled)
    isEmptyMVar closed `shouldReturn` False
    ((==) <$> readIORef owner <*> readIORef closer) `shouldReturn` True

  it "partial thread start failure closes provider from every started lane" $ do
    initialized <- newEmptyMVar
    closed <- newEmptyMVar
    owner <- newIORef Nothing
    closer <- newIORef Nothing
    let factory = do
          myThreadId >>= writeIORef owner . Just
          void (tryPutMVar initialized ())
          pure (idleProvider closer closed)
        spawn number body
          | number == 1 = throwIO (RuntimeError "thread start failed")
          | otherwise = forkLane number body
    events <- newEventLog
    worker <- asyncWorkerFromAccess (syncBridgeAccess spawn factory 2) (Map.fromList [("io", \_ _ -> pure Null)]) 2 (quietOptions events)
    try (runAsyncWorker worker 0.25) >>= (`shouldSatisfy` raisedRuntime "thread start failed")
    isEmptyMVar initialized `shouldReturn` False
    isEmptyMVar closed `shouldReturn` False
    ((==) <$> readIORef owner <*> readIORef closer) `shouldReturn` True

  it "user activity cancelled error is reported as failure and provider closes" $ do
    let attempt = asyncAttempt 1
    claims <- newIORef (0 :: Int)
    failed <- newIORef []
    completed <- newIORef []
    closed <- newEmptyMVar
    workerRef <- newEmptyMVar
    let provider =
          D.WorkerDispatch
            { D.claim = atomicModifyIORef' claims (\n -> (n + 1, if n == 0 then Just attempt else Nothing))
            , D.heartbeat = \_ details -> pure (maybe Null id details)
            , D.complete = \a r -> modifyIORef' completed (++ [(a, r)])
            , D.fail = \a e -> modifyIORef' failed (++ [(a, e)])
            , D.wait = \_ -> pure False
            , D.close = putMVar closed ()
            }
        work _ _ = readMVar workerRef >>= stopAsyncWorker >> throwIO (CancelledError "user cancellation")
    events <- newEventLog
    worker <- newAsyncWorker (pure provider) (Map.fromList [("io", work)]) 1 (quietOptions events)
    putMVar workerRef worker
    within 2 (runAsyncWorker worker 0)
    readIORef completed `shouldReturn` []
    reports <- readIORef failed
    map fst reports `shouldBe` [attempt]
    map (failureMessage . snd) reports `shouldBe` [("RuntimeError", "Activity cancelled: user cancellation")]
    isEmptyMVar closed `shouldReturn` False

  it "cancelled running heartbeat failure keeps lane alive to fail attempt and close" $ do
    let attempt = asyncAttempt 1
    claimedRef <- newIORef False
    heartbeatEntered <- newEmptyMVar
    releaseHeartbeat <- newEmptyMVar
    failed <- newIORef []
    closed <- newEmptyMVar
    workerRef <- newEmptyMVar
    let provider =
          D.WorkerDispatch
            { D.claim = atomicModifyIORef' claimedRef (\c -> (True, if c then Nothing else Just attempt))
            , D.heartbeat = \_ _ -> do
                putMVar heartbeatEntered ()
                readMVar releaseHeartbeat
                throwIO (RuntimeError "heartbeat unavailable")
            , D.complete = \_ _ -> throwIO (userError "cancelled Activity must fail")
            , D.fail = \a e -> modifyIORef' failed (++ [(a, e)])
            , D.wait = \_ -> pure False
            , D.close = putMVar closed ()
            }
        work _ context = do
          outcome <- newEmptyMVar
          task <- forkIO (try (context.heartbeat (Just (Object [("cursor", Int 1)]))) >>= putMVar outcome)
          within 3 (takeMVar heartbeatEntered)
          readMVar workerRef >>= stopAsyncWorker
          void (forkIO (cancel task ""))
          threadDelay 20000
          putMVar releaseHeartbeat ()
          takeMVar outcome >>= either (\(e :: SomeException) -> throwIO e) pure
    events <- newEventLog
    worker <- newAsyncWorker (pure provider) (Map.fromList [("io", work)]) 1 (quietOptions events)
    putMVar workerRef worker
    within 3 (runAsyncWorker worker 0)
    reports <- readIORef failed
    map fst reports `shouldBe` [attempt]
    map (failureMessage . snd) reports `shouldBe` [("RuntimeError", "heartbeat unavailable")]
    isEmptyMVar closed `shouldReturn` False

  it "context close orders queued heartbeats before terminal without detached errors" $ do
    let attempt = asyncAttempt 1
    claimedRef <- newIORef False
    heartbeatEntered <- newEmptyMVar
    releaseHeartbeat <- newEmptyMVar
    providerHeartbeats <- newIORef []
    terminal <- newIORef []
    firstOutcome <- newEmptyMVar
    secondOutcome <- newEmptyMVar
    contextRef <- newEmptyMVar
    workerRef <- newEmptyMVar
    let provider =
          D.WorkerDispatch
            { D.claim = atomicModifyIORef' claimedRef (\c -> (True, if c then Nothing else Just attempt))
            , D.heartbeat = \claimed details -> do
                modifyIORef' providerHeartbeats (++ [(claimed, details)])
                void (tryPutMVar heartbeatEntered ())
                readMVar releaseHeartbeat
                pure (Object [("accepted", maybe Null id details)])
            , D.complete = \a r -> modifyIORef' terminal (++ [(a, r)])
            , D.fail = \_ e -> throwIO (userError (show e))
            , D.wait = \_ -> pure False
            , D.close = pure ()
            }
        work _ context = do
          putMVar contextRef context
          void (forkIO (try (context.heartbeat (Just (String "first"))) >>= putMVar firstOutcome))
          within 3 (takeMVar heartbeatEntered)
          secondStarted <- newEmptyMVar
          void (forkIO (putMVar secondStarted () >> try (context.heartbeat (Just (String "second"))) >>= putMVar secondOutcome))
          takeMVar secondStarted
          readMVar workerRef >>= stopAsyncWorker
          -- Returning starts context closure before the released provider
          -- result can wake either heartbeat (the reference's same-turn
          -- ordering; here, a release that lands after the return).
          void (forkIO (threadDelay 30000 >> putMVar releaseHeartbeat ()))
          pure (String "done")
    events <- newEventLog
    worker <- newAsyncWorker (pure provider) (Map.fromList [("io", work)]) 1 (quietOptions events)
    putMVar workerRef worker
    within 2 (runAsyncWorker worker 0)
    within 2 (takeMVar firstOutcome) >>= \case
      Right accepted -> accepted `shouldBe` Object [("accepted", String "first")]
      Left (e :: SomeException) -> expectationFailure (show e)
    within 2 (takeMVar secondOutcome) >>= \case
      Left (e :: SomeException) -> fromException e `shouldBe` Just (RuntimeError "Activity execution context is closed")
      Right value -> expectationFailure ("second heartbeat accepted: " <> show value)
    readIORef providerHeartbeats `shouldReturn` [(attempt, Just (String "first"))]
    readIORef terminal `shouldReturn` [(attempt, String "done")]
    context <- readMVar contextRef
    context.latestDetails `shouldReturn` Object [("accepted", String "first")]

  it "terminal failure stops all lanes drains sibling and closes every provider" $ do
    let attempts = [asyncAttempt 1, asyncAttempt 2]
    created <- newIORef (0 :: Int)
    claimCounts <- newIORef (Map.fromList [(0 :: Int, 0 :: Int), (1, 0)])
    entered <- newIORef (0 :: Int)
    bothEntered <- newEmptyMVar
    releaseSibling <- newEmptyMVar
    terminalFailed <- newEmptyMVar
    terminals <- newIORef []
    closes <- newIORef []
    let factory = do
          lane <- atomicModifyIORef' created (\n -> (n + 1, n))
          owner <- myThreadId
          pure
            D.WorkerDispatch
              { D.claim = do
                  n <- atomicModifyIORef' claimCounts (\m -> (Map.adjust (+ 1) lane m, m Map.! lane + 1))
                  pure (if n == 1 then Just (attempts !! lane) else Nothing)
              , D.heartbeat = \_ details -> pure (maybe Null id details)
              , D.complete = \claimed result -> do
                  atomicModifyIORef' terminals (\t -> (t ++ [(claimed, result)], ()))
                  when (lane == 0) $ putMVar terminalFailed () >> throwIO (RuntimeError "terminal failed")
              , D.fail = \_ e -> throwIO (userError (show e))
              , D.wait = \_ -> pure False
              , D.close = do
                  closer <- myThreadId
                  atomicModifyIORef' closes (\c -> (c ++ [(lane, closer == owner)], ()))
                  when (lane == 1) $ throwIO (RuntimeError "close failed")
              }
        work _ context = do
          n <- atomicModifyIORef' entered (\e -> (e + 1, e + 1))
          when (n == 2) $ putMVar bothEntered ()
          readMVar bothEntered
          when (context.attemptId == "attempt-2") $ readMVar releaseSibling
          pure (String context.attemptId)
    events <- newEventLog
    worker <- newAsyncWorker factory (Map.fromList [("io", work)]) 2 (quietOptions events)
    (_, done) <- start worker 0
    within 2 (readMVar bothEntered)
    within 3 (takeMVar terminalFailed)
    -- Let the terminal failure reach the coordinator before the sibling
    -- settles (the reference's event loop orders the two).
    within 2 (let loop = eventsOf events >>= \es -> unless (any isRefused es) (threadDelay 1000 >> loop) in loop)
    threadDelay 20000
    putMVar releaseSibling ()
    finish 2 done >>= (`shouldSatisfy` raisedRuntime "terminal failed")
    Map.elems <$> readIORef claimCounts `shouldReturn` [1, 1]
    sortOn ((.attemptId) . fst) <$> readIORef terminals `shouldReturn` [(asyncAttempt 1, String "attempt-1"), (asyncAttempt 2, String "attempt-2")]
    sort <$> readIORef closes `shouldReturn` [(0, True), (1, True)]

  it "real local async worker concurrently completes and preserves heartbeat details" $ withScratch $ \dir -> do
    let path = dir </> "dispatch.sqlite3"
    dispatch <- Local.openLocalDispatch path "async-local" Local.defaultLocalDispatchOptions {Local.defaultQueue = "io"}
    forM_ [0 .. 2 :: Integer] $ \n -> Local.dispatch dispatch (fromInteger n + 1) (invocation "io" (Object [("number", Int n)]))
    entered <- newIORef (0 :: Int)
    peak <- newIORef (0 :: Int)
    workerRef <- newEmptyMVar
    let io inv context = do
          now <- atomicModifyIORef' entered (\e -> (e + 1, e + 1))
          atomicModifyIORef' peak (\p -> (max p now, ()))
          let number = case inv.input of
                Object [("number", value)] -> value
                other -> other
          accepted <- context.heartbeat (Just (Object [("number", Array [number])]))
          threadDelay 20000
          atomicModifyIORef' entered (\e -> (e - 1, ()))
          when (number == Int 2) $ readMVar workerRef >>= stopAsyncWorker
          latest <- context.latestDetails
          pure (Object [("heartbeat", accepted), ("latest", latest)])
    events <- newEventLog
    worker <-
      newAsyncWorker
        (Local.toWorkerDispatch <$> Local.openLocalWorkerDispatch path Local.defaultLocalWorkerOptions {Local.workerQueues = ["io"]})
        (Map.fromList [("io", io)])
        3
        (quietOptions events) {W.workerId = Just "local-async"}
    putMVar workerRef worker
    within 5 (runAsyncWorker worker 0.01)
    readIORef peak `shouldReturn` 3
    collected <- sortOn fst <$> Local.collect dispatch
    collected
      `shouldBe` [ (fromInteger n + 1, Succeeded (Object [("heartbeat", details), ("latest", details)]))
                 | n <- [0 .. 2 :: Integer]
                 , let details = Object [("number", Array [Int n])]
                 ]

  it "native access factory repeated cancellation transfers ownership and closes once" $ do
    factoryEntered <- newEmptyMVar
    releaseFactory <- newEmptyMVar
    closed <- newIORef (0 :: Int)
    let factory = do
          putMVar factoryEntered ()
          readMVar releaseFactory
          pure refusingAccess {close = atomicModifyIORef' closed (\n -> (n + 1, ()))}
    events <- newEventLog
    worker <- asyncWorkerFromAccess factory (Map.fromList [("io", \_ _ -> throwIO (userError "no Attempt"))]) 1 (quietOptions events)
    (tid, done) <- start worker 0.25
    within 2 (takeMVar factoryEntered)
    cancel tid "first"
    yield
    cancel tid "second"
    putMVar releaseFactory ()
    finish 2 done >>= (`shouldSatisfy` isCancelled)
    readIORef closed `shouldReturn` 1

  it "owned provider failure that settles after cancellation wins" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    outcome <- newEmptyMVar
    let operation = putMVar entered () >> readMVar release >> throwIO (RuntimeError "custody uncertain")
    task <- forkIO (try (owned operation) >>= putMVar outcome)
    takeMVar entered
    cancel task ""
    putMVar release ()
    result <- within 2 (takeMVar outcome)
    (result :: Either SomeException ()) `shouldSatisfy` raisedRuntime "custody uncertain"

  it "terminal failure reaps blocked claim result without another claim" $ do
    let firstAttempt = asyncAttempt 1
        attempts = [firstAttempt, asyncAttempt 2]
    secondClaimEntered <- newEmptyMVar
    releaseSecondClaim <- newEmptyMVar
    releaseTerminal <- newEmptyMVar
    claims <- newIORef (0 :: Int)
    completed <- newIORef []
    closed <- newIORef (0 :: Int)
    let access =
          refusingAccess
            { claim = \_ -> do
                n <- atomicModifyIORef' claims (\c -> (c + 1, c + 1))
                case n of
                  1 -> pure (Just firstAttempt)
                  2 -> putMVar secondClaimEntered () >> readMVar releaseSecondClaim >> pure (Just (attempts !! 1))
                  _ -> throwIO (userError "a third claim must not be admitted")
            , complete = \_ attempt _ -> do
                atomicModifyIORef' completed (\c -> (c ++ [attempt], ()))
                when (attempt == firstAttempt) $ readMVar releaseTerminal >> throwIO (RuntimeError "terminal uncertain")
            , close = atomicModifyIORef' closed (\n -> (n + 1, ()))
            }
    events <- newEventLog
    worker <- asyncWorkerFromAccess (pure access) (Map.fromList [("io", \_ context -> pure (String context.attemptId))]) 3 (quietOptions events)
    (_, done) <- start worker 0
    within 2 (takeMVar secondClaimEntered)
    putMVar releaseTerminal ()
    -- Let the terminal failure settle before the blocked claim returns (the
    -- reference yields the event loop once).
    within 2 (let loop = eventsOf events >>= \es -> unless (any isRefused es) (threadDelay 1000 >> loop) in loop)
    threadDelay 50000
    putMVar releaseSecondClaim ()
    finish 2 done >>= (`shouldSatisfy` raisedRuntime "terminal uncertain")
    readIORef claims `shouldReturn` 2
    readIORef completed `shouldReturn` attempts
    readIORef closed `shouldReturn` 1

  it "repeated cancellation drains known claim activity terminal and blocked close once" $ do
    let attempt = asyncAttempt 1
    claimEntered <- newEmptyMVar
    releaseClaim <- newEmptyMVar
    activityEntered <- newEmptyMVar
    releaseActivity <- newEmptyMVar
    closeEntered <- newEmptyMVar
    releaseClose <- newEmptyMVar
    recordedEvents <- newIORef []
    claims <- newIORef (0 :: Int)
    closes <- newIORef (0 :: Int)
    let access =
          refusingAccess
            { claim = \_ -> do
                atomicModifyIORef' claims (\c -> (c + 1, ()))
                putMVar claimEntered ()
                readMVar releaseClaim
                pure (Just attempt)
            , complete = \_ claimed result -> modifyIORef' recordedEvents (++ [("terminal" :: Text, Just (claimed, result))])
            , close = do
                atomicModifyIORef' closes (\c -> (c + 1, ()))
                putMVar closeEntered ()
                readMVar releaseClose
                modifyIORef' recordedEvents (++ [("close", Nothing)])
            }
        work _ _ = putMVar activityEntered () >> readMVar releaseActivity >> pure (String "done")
    events <- newEventLog
    worker <- asyncWorkerFromAccess (pure access) (Map.fromList [("io", work)]) 1 (quietOptions events)
    (tid, done) <- start worker 0
    within 2 (takeMVar claimEntered)
    cancel tid "claim-1" >> cancel tid "claim-2"
    putMVar releaseClaim ()
    within 2 (takeMVar activityEntered)
    cancel tid "activity-1" >> cancel tid "activity-2"
    putMVar releaseActivity ()
    within 2 (takeMVar closeEntered)
    cancel tid "close-1" >> cancel tid "close-2"
    putMVar releaseClose ()
    finish 2 done >>= (`shouldSatisfy` isCancelled)
    readIORef claims `shouldReturn` 1
    readIORef closes `shouldReturn` 1
    readIORef recordedEvents `shouldReturn` [("terminal", Just (attempt, String "done")), ("close", Nothing)]

  it "repeated cancellation keeps terminal failure primary and retrieves factory failure" $ do
    let work _ _ = pure (String "done")
    -- The terminal case.
    entered <- newEmptyMVar
    release <- newEmptyMVar
    claimedRef <- newIORef False
    let access =
          refusingAccess
            { claim = \_ -> atomicModifyIORef' claimedRef (\c -> (True, if c then Nothing else Just (asyncAttempt 1)))
            , complete = \_ _ _ -> putMVar entered () >> readMVar release >> throwIO (RuntimeError "terminal failed")
            }
    events <- newEventLog
    terminalWorker <- asyncWorkerFromAccess (pure access) (Map.fromList [("io", work)]) 1 (quietOptions events)
    (tid, done) <- start terminalWorker 0
    within 2 (takeMVar entered)
    cancel tid "" >> cancel tid ""
    putMVar release ()
    finish 2 done >>= (`shouldSatisfy` raisedRuntime "terminal failed")
    -- The factory case.
    factoryEntered <- newEmptyMVar
    factoryRelease <- newEmptyMVar
    let factory = putMVar factoryEntered () >> readMVar factoryRelease >> throwIO (RuntimeError "factory failed")
    factoryWorker <- asyncWorkerFromAccess factory (Map.fromList [("io", work)]) 1 (quietOptions events)
    (tid', done') <- start factoryWorker 0.25
    within 2 (takeMVar factoryEntered)
    cancel tid' "" >> cancel tid' ""
    putMVar factoryRelease ()
    finish 2 done' >>= (`shouldSatisfy` raisedRuntime "factory failed")

  it "same turn terminal failures surface first created slot error" $ do
    -- Both terminal failures settle while the coordinator is blocked in a
    -- third slot's claim, so it reaps them in one turn; slot 1 fails first
    -- in wall-clock time, and the first-created slot's error still wins.
    let attempts = [asyncAttempt 1, asyncAttempt 2]
    claims <- newIORef (0 :: Int)
    slotZeroGo <- newEmptyMVar
    terminalsDone <- newEmptyMVar
    events <- newEventLog
    let refusedCount = length . filter isRefused <$> eventsOf events
        access =
          refusingAccess
            { claim = \_ -> do
                n <- atomicModifyIORef' claims (\c -> (c + 1, c))
                if n < 2
                  then pure (Just (attempts !! n))
                  else do
                    when (n == 2) $ do
                      within 3 (readMVar terminalsDone)
                      threadDelay 50000
                    pure Nothing
            , complete = \slot _ _ -> do
                when (slot == 0) $ readMVar slotZeroGo
                throwIO (RuntimeError ("slot " <> T.pack (show slot) <> " failed"))
            , wait = \_ _ -> pure False
            }
    _ <- forkIO $ do
      let waitFor k = let loop = refusedCount >>= \c -> unless (c >= k) (threadDelay 1000 >> loop) in loop
      waitFor 1
      putMVar slotZeroGo ()
      waitFor 2
      putMVar terminalsDone ()
    worker <- asyncWorkerFromAccess (pure access) (Map.fromList [("io", \_ _ -> pure Null)]) 3 (quietOptions events)
    within 5 (try (runAsyncWorker worker 0)) >>= (`shouldSatisfy` raisedRuntime "slot 0 failed")

  it "uncertain native claim stops admission and closes" $ do
    claims <- newIORef (0 :: Int)
    closed <- newIORef (0 :: Int)
    let access =
          refusingAccess
            { claim = \_ -> atomicModifyIORef' claims (\c -> (c + 1, ())) >> throwIO (RuntimeError "claim outcome uncertain")
            , wait = \_ _ -> throwIO (userError "uncertain claim must stop before wait")
            , close = atomicModifyIORef' closed (\c -> (c + 1, ()))
            }
    events <- newEventLog
    worker <- asyncWorkerFromAccess (pure access) (Map.fromList [("io", \_ _ -> throwIO (userError "no Attempt"))]) 4 (quietOptions events)
    try (runAsyncWorker worker 0.25) >>= (`shouldSatisfy` raisedRuntime "claim outcome uncertain")
    readIORef claims `shouldReturn` 1
    readIORef closed `shouldReturn` 1
  where
    isRefused = \case
      Object members -> isJust (lookup "refused" members)
      _ -> False
