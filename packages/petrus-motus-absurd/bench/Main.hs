-- | Absurd Dispatch benchmarks, the twins of @bench/python_bench.py@ (same
-- names, same invocations, same doors), against a scratch database created
-- on the server named by PETRUS_TEST_POSTGRES (with the pinned Absurd
-- schema) and dropped afterwards. Every PostgreSQL row is measured in
-- wall-clock time: the work is mostly server round trips, which CPU time
-- would not count.
--
-- * @wire.encode-decode@: one invocation to its task payload and back,
--   strictly decoded (pure).
-- * @calibration.select-1@: one @SELECT 1@ round trip on an autocommit
--   connection: the floor every PostgreSQL row is built from.
-- * @dispatch.spawn-commit@: one fresh occurrence through
--   @AbsurdDispatch.dispatch@ on a join-mode connection (the keyed
--   @absurd.spawn_task@ and the @impetus_dispatch@ doorbell), then the
--   commit.
-- * @roundtrip.dispatch-claim-complete-collect@: one occurrence's whole
--   custody cycle: dispatch and commit, an @AbsurdWorkerDispatch@ claims
--   it and reports the result (with the @impetus_results@ doorbell), and
--   the authority collects the outcome and commits.
--
-- Every 256 dispatches a row's lane retires ('Lane'): a fresh queue, a
-- fresh adapter on a fresh Instance and, for the round trip, a fresh
-- Worker take over and the old queue is dropped, so the adapter's
-- per-occurrence state and the queue's tables stay bounded on both sides
-- alike; that cost is amortized into the figures on both sides.
module Main (main) where

import Control.Exception (finally)
import Control.Monad (void, when, (>=>))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation (..), defaultExecutionPolicy)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (ActivityAttempt (..))
import Petrus.Motus.Dispatch.Absurd
  ( AbsurdDispatch
  , AbsurdDispatchOptions (..)
  , AbsurdWorkerDispatch
  , AbsurdWorkerOptions (..)
  , decodeInvocation
  , defaultAbsurdDispatchOptions
  , defaultAbsurdWorkerOptions
  , encodeInvocation
  , ensureAbsurdSchema
  , openAbsurdWorkerDispatch
  )
import Petrus.Motus.Dispatch.Absurd qualified as Absurd
import Petrus.Postgres (Connection)
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport (PostgresTarget (..), withScratchDatabase)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Test.Tasty (localOption)
import Test.Tasty.Bench

rotation :: Int
rotation = 256

invocationFor :: Int -> ActivityInvocation
invocationFor n =
  ActivityInvocation
    { activity = "bench_work"
    , input = Object [("n", Int (toInteger n)), ("label", String "a benchmark payload")]
    , policy = defaultExecutionPolicy
    , correlation = Nothing
    , idempotency = Just ("effect-" <> T.pack (show n))
    }

main :: IO ()
main =
  lookupEnv "PETRUS_TEST_POSTGRES" >>= \case
    Just url | not (null url) -> withScratchDatabase (BC.pack url) (run' . (.targetUrl))
    _ -> hPutStrLn stderr "PETRUS_TEST_POSTGRES is unset: the petrus-motus-absurd benchmarks need a server" >> exitFailure

-- | One lane: a fresh queue, a join-mode authority connection with the
-- adapter over it (a fresh Instance), and, for the round trip, a Worker
-- subscribed to that queue. A lane retires after 'rotation' dispatches and
-- its queue is dropped: Absurd's claim sweeps scan the queue's task table,
-- so an ever-growing queue would make every row depend on how many
-- iterations the harness chose to run.
data Lane = Lane
  { queue :: Text
  , connection :: Connection
  , adapter :: AbsurdDispatch
  , worker :: Maybe AbsurdWorkerDispatch
  , dispatched :: Int
  }

run' :: ByteString -> IO ()
run' url = do
  admin <- Pg.connect url True
  ensureAbsurdSchema admin
  counter <- newIORef (0 :: Int)
  let next = atomicModifyIORef' counter (\c -> (c + 1, c))
      openLane withWorker = do
        n <- next
        let queue = "bench_" <> T.pack (show n)
        void (Pg.execute_ admin "SELECT absurd.create_queue(%s)" [Pg.textParam queue])
        connection <- Pg.connect url False
        adapter <- Absurd.absurdDispatch connection ("bench-" <> T.pack (show n)) defaultAbsurdDispatchOptions {defaultQueue = queue}
        worker <-
          if withWorker
            then Just <$> openAbsurdWorkerDispatch url defaultAbsurdWorkerOptions {queues = [queue]}
            else pure Nothing
        pure Lane {queue, connection, adapter, worker, dispatched = 0}
      closeLane lane = do
        mapM_ Absurd.close lane.worker
        Pg.close lane.connection
        void (Pg.execute_ admin "SELECT absurd.drop_queue(%s)" [Pg.textParam lane.queue])
  spawner <- openLane False >>= newIORef
  tripper <- openLane True >>= newIORef
  let dispatchOne withWorker ref = do
        lane <- readIORef ref
        lane' <-
          if lane.dispatched >= rotation
            then closeLane lane >> openLane withWorker
            else pure lane
        n <- next
        Absurd.dispatch lane'.adapter (lane'.dispatched + 1) (invocationFor n)
        Pg.commit lane'.connection
        writeIORef ref lane' {dispatched = lane'.dispatched + 1}
        pure lane'
      roundTrip = do
        lane <- dispatchOne True tripper
        worker <- maybe (fail "the round-trip lane has no worker") pure lane.worker
        Absurd.claim worker >>= \case
          Nothing -> fail "the worker found no task"
          Just attempt -> Absurd.complete worker attempt (String ("done " <> attempt.invocation.activity))
        let collectOne = do
              outcomes <- Absurd.collect lane.adapter
              Pg.commit lane.connection
              when (null outcomes) collectOne
        collectOne
      wire = either (error . T.unpack) id . decodeInvocation . encodeInvocation
  flip finally (mapM_ (readIORef >=> closeLane) [spawner, tripper] >> Pg.close admin) $
    -- Wall-clock time for every benchmark, as the Python twins measure it
    -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
    -- time spent waiting on the kernel, servers and child processes.
    defaultMain . map (localOption WallTime) $
      [ bgroup "wire" [bench "encode-decode" (nf (\n -> (wire (invocationFor n)).idempotency) 7)]
      , bgroup "calibration" [bench "select-1" (whnfIO (void (Pg.execute_ admin "SELECT 1" [])))]
      , bgroup "dispatch" [bench "spawn-commit" (whnfIO (void (dispatchOne False spawner)))]
      , bgroup "roundtrip" [bench "dispatch-claim-complete-collect" (whnfIO roundTrip)]
      ]
