-- | Local Dispatch and Worker benchmarks, the twins of
-- @bench/python_bench.py@: the same custody round trips (dispatch -> claim
-- -> complete -> collect) over a fresh SQLite file, under the database clock
-- and under a provider clock; the synchronous Worker draining Local
-- custody; and both Workers' runtime overhead and concurrency over
-- in-memory custody, so @bench/RESULTS.md@ can set the two side by side.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, finally)
import Control.Monad (forM, forM_, void, when)
import Data.IORef
import Data.List (sort)
import GHC.Clock (getMonotonicTime)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Database.SQLite3 qualified as Sql
import Petrus.Activity
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.Local
  ( LocalDispatchClock (..)
  , LocalDispatchOptions (..)
  , LocalWorkerOptions (..)
  , defaultLocalDispatchOptions
  , defaultLocalWorkerOptions
  , withLocalDispatch
  )
import Petrus.Motus.Dispatch (ActivityAttempt, WorkerDispatch (..), activityAttempt)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Worker
  ( WorkerOptions (..)
  , closeWorker
  , defaultWorkerOptions
  , newAsyncWorker
  , newWorker
  , runAsyncWorker
  , runAvailable
  , stopAsyncWorker
  )
import System.Directory (createDirectory, doesFileExist, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Petrus.TestSupport.BenchTwin (twin)
import Test.Tasty (localOption)
import Test.Tasty.Bench
import Text.Printf (printf)

roundTrips :: Int
roundTrips = 50

-- | The Python bench's @work(value)@.
work :: Int -> ActivityInvocation
work value =
  either (error . T.unpack) id . activityInvocation $
    ActivityInvocationFields
      { activity = "work"
      , input = Object [("value", Int (toInteger value))]
      , policy = either (error . T.unpack) id (executionPolicy (policyFields defaultExecutionPolicy) {attempts = 2, heartbeatTimeout = 30})
      , correlation = Just "correlation"
      , idempotency = Just "idempotency"
      }

-- | Remove the database and its WAL side files.
discard :: FilePath -> IO ()
discard path = forM_ ["", "-wal", "-shm"] $ \suffix -> do
  present <- doesFileExist (path <> suffix)
  when present (removeFile (path <> suffix))

-- | Create a fresh file (schema initialization), close the session, and
-- discard the file.
openFresh :: FilePath -> IO Int
openFresh path = do
  withLocalDispatch path "bench" defaultLocalDispatchOptions (\_ -> pure ())
  discard path
  pure 0

-- | 'roundTrip' while a co-resident connection (an application's own, say)
-- holds the file open, so no close during the round trips is the last close
-- and none checkpoints the WAL.
heldRoundTrip :: Int -> FilePath -> IO Int
heldRoundTrip n path = do
  withLocalDispatch path "bench" defaultLocalDispatchOptions (\_ -> pure ())
  collected <- bracket (Sql.open (T.pack path)) Sql.close $ \held -> do
    Sql.exec held "SELECT count(*) FROM impetus_local_dispatch_tasks"
    cycles False n path
  discard path
  pure collected

-- | Over a fresh file: dispatch n occurrences, claim and complete each with
-- one worker, collect them all, and close the session; answer how many
-- outcomes were collected.
roundTrip :: Bool -> Int -> FilePath -> IO Int
roundTrip provider n path = do
  collected <- cycles provider n path
  discard path
  pure collected

cycles :: Bool -> Int -> FilePath -> IO Int
cycles provider n path = do
  source <-
    if provider
      then do
        at <- newIORef (1000 :: Integer)
        pure (Just (LocalDispatchClock (atomicModifyIORef' at (\t -> (t + 1, t)))))
      else pure Nothing
  withLocalDispatch path "bench" defaultLocalDispatchOptions {clock = source} $ \dispatch -> do
    forM_ [1 .. n] $ \occurrence -> Local.dispatch dispatch occurrence (work occurrence)
    worker <- Local.workerWith dispatch defaultLocalWorkerOptions {explicitClaimant = Just "bench-worker"}
    let drain = do
          Local.claim worker >>= \case
            Nothing -> pure ()
            Just attempt -> Local.complete worker attempt (Object [("ok", Bool True)]) >> drain
    drain
    length <$> Local.collect dispatch

-- ---------------------------------------------------------------------------
-- Workers

quiet :: WorkerOptions
quiet = defaultWorkerOptions {output = \_ -> pure ()}

-- | The Worker's own Local round trips: dispatch n, a Worker over a
-- 'Local.LocalWorkerDispatch' runs every available Attempt, collect. With
-- @held@, a co-resident connection holds the file open, as in the
-- reference bench's held-open row.
workerLocal :: Bool -> Int -> FilePath -> IO Int
workerLocal held n path = do
  collected <- withLocalDispatch path "bench" defaultLocalDispatchOptions $ \dispatch -> do
    let body = do
          forM_ [1 .. n] $ \occurrence -> Local.dispatch dispatch occurrence (work occurrence)
          custody <- Local.workerWith dispatch defaultLocalWorkerOptions {explicitClaimant = Just "bench-worker"}
          worker <- newWorker (Local.toWorkerDispatch custody) (Map.fromList [("work", \_ _ -> pure (Object [("ok", Bool True)]))]) quiet
          void (runAvailable worker (2 * n))
          closeWorker worker
          length <$> Local.collect dispatch
    if held
      then bracket (Sql.open (T.pack path)) Sql.close $ \connection -> do
        Sql.exec connection "SELECT count(*) FROM impetus_local_dispatch_tasks"
        body
      else body
  discard path
  pure collected

-- | n ready-made Attempts of @work@.
readyAttempts :: Int -> [ActivityAttempt]
readyAttempts n =
  [ either (error . T.unpack) id (activityAttempt ("a" <> T.pack (show i)) "1" "bench" "default" (work i) Null Nothing)
  | i <- [1 .. n]
  ]

-- | In-memory custody over a shared pool: claim pops (and runs the action
-- once the pool is empty), complete counts.
memoryProvider :: IORef [ActivityAttempt] -> IORef Int -> IO () -> WorkerDispatch
memoryProvider pool done onEmpty =
  WorkerDispatch
    { claim =
        atomicModifyIORef' pool (\case [] -> ([], Nothing); next : rest -> (rest, Just next)) >>= \case
          Nothing -> onEmpty >> pure Nothing
          found -> pure found
    , heartbeat = \_ details -> pure (maybe Null id details)
    , complete = \_ _ -> atomicModifyIORef' done (\k -> (k + 1, ()))
    , fail = \_ _ -> error "unexpected failure"
    , wait = \_ -> pure False
    , close = pure ()
    }

-- | The synchronous Worker over in-memory custody: its per-Attempt runtime
-- cost (claim, resolve, execute, normalize, complete).
workerMemory :: Int -> IO Int
workerMemory n = do
  pool <- newIORef (readyAttempts n)
  done <- newIORef 0
  worker <- newWorker (memoryProvider pool done (pure ())) (Map.fromList [("work", \_ _ -> pure (Object [("ok", Bool True)]))]) quiet
  void (runAvailable worker (n + 1))
  closeWorker worker
  readIORef done

-- | The AsyncWorker over in-memory custody (the sync bridge: a lane thread
-- per slot), the Activity sleeping the microseconds; it stops once the pool
-- is empty and its admitted Activities drain.
asyncMemory :: Int -> Int -> Int -> IO Int
asyncMemory concurrency micros n = do
  pool <- newIORef (readyAttempts n)
  done <- newIORef 0
  stopper <- newIORef (pure ())
  let activity _ _ = do
        when (micros > 0) $ threadDelay micros
        pure (Object [("ok", Bool True)])
  worker <-
    newAsyncWorker
      (pure (memoryProvider pool done (readIORef stopper >>= id)))
      (Map.fromList [("work", activity)])
      concurrency
      quiet
  writeIORef stopper (stopAsyncWorker worker)
  runAsyncWorker worker 0.001
  readIORef done

-- | Print the median wall time of the runs after one warm-up, in the
-- Python bench's format.
medianTimed :: String -> Int -> IO Int -> IO ()
medianTimed name repeats action = do
  size <- action
  samples <- forM [1 .. repeats] $ \_ -> do
    start <- getMonotonicTime
    void action
    end <- getMonotonicTime
    pure (end - start)
  let sorted = sort samples
      middle = repeats `div` 2
      median = if even repeats then (sorted !! (middle - 1) + sorted !! middle) / 2 else sorted !! middle
  printf "%-42s %12.3f ms   (size %d, n=%d)\n" name (median * 1000) size repeats

scratchDirectory :: IO FilePath
scratchDirectory = do
  base <- getTemporaryDirectory
  (file, handle) <- openTempFile base "petrus-motus-bench"
  hClose handle
  removeFile file
  createDirectory file
  pure file

main :: IO ()
main = do
  dir <- scratchDirectory
  let path = dir </> "dispatch.db"
  -- The result sizes python_bench.py prints, as a check that both sides time
  -- the same work.
  database <- roundTrip False roundTrips path
  provided <- roundTrip True roundTrips path
  held <- heldRoundTrip roundTrips path
  putStrLn ("sizes: roundtrip-db-clock " <> show database <> ", roundtrip-provider-clock " <> show provided <> ", roundtrip-held-open " <> show held)
  workerSizes <- sequence [workerLocal False roundTrips path, workerLocal True roundTrips path, workerMemory 1000, asyncMemory 8 0 1000]
  putStrLn ("sizes: worker " <> show workerSizes)
  -- Sleep-bound rows: tasty-bench's doubling estimator does not settle on
  -- timer-driven work, so these are medians of 10 runs after a warm-up,
  -- exactly as python_bench.py measures. They run after the tasty rows, as
  -- the twin runs them after its Local rows: seconds of 1 ms sleeps leave
  -- the machine idle-clocked, and a short row timed right after them (the
  -- twin-protocol open-fresh, 21 calls) measured that, at 2.5 times its
  -- figure, instead of the code.
  let sleepRows = forM_ [1, 8, 64] $ \c -> medianTimed ("async-worker/sleep-1ms-200-c" <> show c) 10 (asyncMemory c 1000 200)
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  flip finally (sleepRows >> removeDirectoryRecursive dir) . defaultMain . map (localOption WallTime) $
    [ bgroup
        "local"
        [ -- Schema initialization is fsync-bound (eight syncs per open on
          -- both sides, strace-counted), and tasty-bench's mean takes in
          -- every slow file-system period that the twin's median of 20
          -- leaves out. So this row is timed as python_bench.py times it
          -- (Petrus.TestSupport.BenchTwin): one warm-up call, then the
          -- median of 20 single calls.
          twin "local.open-fresh" (Just 20) 1 (openFresh path)
        , bench "roundtrip-1" $ whnfIO $ roundTrip False 1 path
        , bench "roundtrip-50-db-clock" $ whnfIO $ roundTrip False roundTrips path
        , bench "roundtrip-50-provider-clock" $ whnfIO $ roundTrip True roundTrips path
        , bench "roundtrip-50-held-open" $ whnfIO $ heldRoundTrip roundTrips path
        ]
    , bgroup
        "worker"
        [ bench "local-50" $ whnfIO $ workerLocal False roundTrips path
        , bench "local-50-held-open" $ whnfIO $ workerLocal True roundTrips path
        , bench "memory-1000" $ whnfIO $ workerMemory 1000
        ]
    , bgroup
        "async-worker"
        [ bench ("memory-1000-c" <> show c) (whnfIO (asyncMemory c 0 1000)) | c <- [1, 8, 64]
        ]
    ]
