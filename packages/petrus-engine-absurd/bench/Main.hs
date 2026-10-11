-- | Absurd Engine benchmarks, the twins of @bench/python_bench.py@ (same
-- names, same net, same doors), against a scratch database created on the
-- server named by PETRUS_TEST_POSTGRES (with the History and Absurd
-- schemas) and dropped afterwards. Both rows are measured in wall-clock
-- time: the work is mostly server round trips, which CPU time would not
-- count.
--
-- * @engine.create-close@: @create_engine@ over fresh joined and listen
--   connections for a fresh Instance of the reference's topology net
--   (@tests/absurd_support.py@): the fence, the empty History load, the
--   construction commit, the LISTEN; then @close@.
-- * @roundtrip.issue-to-completion@: one Instance's whole life with an
--   in-process Absurd Worker: create the Engine, deliver an issue, advance
--   until blocked (the begin batch, the spawn and the doorbell commit
--   together), the Worker claims @spark_work@ and completes it, the Engine
--   drives until rest (collects the result and projects it), the approval
--   arrives, the Engine drives to completion, and closes.
--
-- Every 256 Instances the round trip's queue retires: a fresh queue and
-- Worker take over and the old queue is dropped, so the queue's tables
-- stay bounded (Absurd's claim sweeps scan them) on both sides alike; that
-- cost is amortized into the figure on both sides.
module Main (main) where

import Control.Exception (finally)
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Engine (Engine)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Absurd (absurdSession, openAbsurdEngine)
import Petrus.Engine.Absurd.Support
import Petrus.Engine.Provider (OpenMode (..))
import Petrus.HistoryStore.Postgres (ensureSchema)
import Petrus.Impetus.Instance (Status (..))
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.Absurd (AbsurdWorkerDispatch, defaultAbsurdWorkerOptions, ensureAbsurdSchema, openAbsurdWorkerDispatch)
import Petrus.Motus.Dispatch.Absurd qualified as Absurd
import Petrus.Postgres qualified as Pg
import Petrus.TestSupport (PostgresTarget (..), withScratchDatabase)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Test.Tasty (localOption)
import Test.Tasty.Bench

rotation :: Int
rotation = 256

main :: IO ()
main =
  lookupEnv "PETRUS_TEST_POSTGRES" >>= \case
    Just url | not (null url) -> withScratchDatabase (BC.pack url) (run' . (.targetUrl))
    _ -> hPutStrLn stderr "PETRUS_TEST_POSTGRES is unset: the petrus-engine-absurd benchmarks need a server" >> exitFailure

-- | The round trip's queue and the Worker subscribed to it.
data Lane = Lane {laneQueue :: Text, worker :: AbsurdWorkerDispatch, served :: Int}

run' :: ByteString -> IO ()
run' url = do
  admin <- Pg.connect url True
  ensureSchema admin
  ensureAbsurdSchema admin
  counter <- newIORef (0 :: Int)
  let next = atomicModifyIORef' counter (\c -> (c + 1, c))
      open :: Text -> Text -> IO Engine
      open onQueue prefix = do
        n <- next
        joined <- Pg.connect url False
        listener <- Pg.connect url True
        let options = sessionOptions {queue = onQueue}
        openAbsurdEngine
          (absurdSession joined (Just listener))
          CreateInstance
          topologyNet
          (prefix <> T.pack (show n))
          (absurdOptionsFor options)
          (engineOptionsFor options)
      openLane = do
        n <- next
        let laneQueue = "bench_" <> T.pack (show n)
        void (Pg.execute_ admin "SELECT absurd.create_queue(%s)" [Pg.textParam laneQueue])
        worker <- openAbsurdWorkerDispatch url defaultAbsurdWorkerOptions {Absurd.queues = [laneQueue]}
        pure Lane {laneQueue, worker, served = 0}
      closeLane lane = do
        Absurd.close lane.worker
        void (Pg.execute_ admin "SELECT absurd.drop_queue(%s)" [Pg.textParam lane.laneQueue])
  lanes <- openLane >>= newIORef
  let createClose = open capability "create-" >>= Engine.close
      roundTrip = do
        lane <- readIORef lanes
        lane' <- if lane.served >= rotation then closeLane lane >> openLane else pure lane
        writeIORef lanes lane' {served = lane'.served + 1}
        engine <- open lane'.laneQueue "trip-"
        flip finally (Engine.close engine) $ do
          n <- next
          let issueId = "goose-" <> T.pack (show n)
          void (Engine.deliver engine ingress [issue (Object [("id", String issueId)])] ("ingress-" <> issueId) Nothing)
          void (advanceUntilBlocked engine)
          Absurd.claim lane'.worker >>= \case
            Nothing -> fail "the worker found no task"
            Just attempt -> Absurd.complete lane'.worker attempt (String ("sparked " <> issueId))
          driveUntilRest engine
          void (Engine.deliver engine operator [approval (Object [("id", String issueId)])] ("approval-" <> issueId) Nothing)
          driveUntilRest engine
          status <- Engine.status engine
          unless (status == Completed) $ fail ("the Instance did not complete: " <> show status)
  flip finally (readIORef lanes >>= closeLane >> Pg.close admin) $
    defaultMain
      [ localOption WallTime $ bgroup "engine" [bench "create-close" (whnfIO createClose)]
      , localOption WallTime $ bgroup "roundtrip" [bench "issue-to-completion" (whnfIO roundTrip)]
      ]
