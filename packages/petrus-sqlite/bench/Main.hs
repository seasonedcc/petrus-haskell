-- | petrus-sqlite hot paths. Each benchmark has a same-named counterpart in
-- @bench/python_bench.py@ that times the upstream Python code path (the real
-- upstream functions where they exist); run both with
-- @scripts/bench petrus-sqlite@.
module Main (main) where

import Control.Exception (finally)
import Control.Monad (forM_, void)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Posix (realpath)
import Petrus.Sqlite
import System.Directory (getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import System.IO.Temp (createTempDirectory)
import Petrus.TestSupport.BenchTwin (twin)
import Test.Tasty (localOption, testGroup)
import Test.Tasty.Bench

eventsDdl :: Text
eventsDdl =
  "CREATE TABLE impetus_history_events (\n    instance TEXT NOT NULL,\n    position INTEGER NOT NULL CHECK (position >= 0),\n    event_id TEXT NOT NULL UNIQUE,\n    record_type TEXT NOT NULL,\n    occurrence INTEGER,\n    payload TEXT NOT NULL,\n    recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),\n    PRIMARY KEY (instance, position)\n)"

insertEvent :: Text
insertEvent =
  "INSERT INTO impetus_history_events (instance, position, event_id, record_type, occurrence, payload) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING"

-- | Calls per batch of the @tx@ rows, as python_bench.py's TX_COMMITS and
-- TX_BATCHES: about 0.2 s a batch on a quiet machine.
txCommits, txBatches :: Int
txCommits = 5000
txBatches = 500

main :: IO ()
main = do
  dir <- realpath =<< (getTemporaryDirectory >>= \tmp -> createTempDirectory tmp "petrus-sqlite-bench")
  let database = dir </> "bench.sqlite3"
      payload = T.replicate 20 "{\"k\":\"value\"},"
  connection <- open historyStoreProfile database
  execute_ connection eventsDdl
  withImmediateTransaction connection $
    forM_ [0 .. 999 :: Int] $ \position ->
      void (execute connection insertEvent (row "seed" position payload))
  next <- newIORef (0 :: Int)
  let fresh = atomicModifyIORef' next (\n -> (n + 1, n))
  flip finally (close connection >> removeDirectoryRecursive dir) $
    -- Wall-clock time for every benchmark, as the Python twins measure it
    -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
    -- time spent waiting on the kernel, servers and child processes.
    defaultMain . map (localOption WallTime) $
      [ bgroup
          "connect"
          [ bench "local-dispatch-profile" (whnfIO (open localDispatchProfile database >>= close))
          ]
      , -- Every call adds rows to one table, so the cost per commit grows
        -- with the calls before it, and every commit is an fsync. tasty-bench
        -- ran as many iterations as the noise demanded (at --stdev 5 on a
        -- noisy machine, a table about 20 times the twin's) and reported a
        -- mean that one slow file-system period moves. These rows use the
        -- twin's own protocol instead (Petrus.TestSupport.BenchTwin): one
        -- warm-up call, then 10 batches of exactly the same number of calls
        -- as python_bench.py's (TX_COMMITS, TX_BATCHES), median per call.
        -- Both sides make the same inserts and take the same statistic.
        testGroup
          "tx"
          [ twin "tx.immediate-insert-commit" Nothing txCommits $ do
              position <- fresh
              withImmediateTransaction connection (execute connection insertEvent (row "single" position payload))
          , twin "tx.immediate-insert-100" Nothing txBatches $ do
              base <- fresh
              withImmediateTransaction connection $
                forM_ [0 .. 99] $ \i -> execute connection insertEvent (row "batch" (base * 100 + i) payload)
          ]
      , bgroup
          "query"
          [ bench "select-by-key" (nfIO (length <$> query connection "SELECT payload FROM impetus_history_events WHERE instance = ? AND position = ?" [SQLText "seed", SQLInteger 500]))
          , bench "select-1000" (nfIO (length <$> query connection "SELECT position, event_id, record_type, occurrence, payload FROM impetus_history_events WHERE instance = ? ORDER BY position" [SQLText "seed"]))
          ]
      , bgroup
          "schema"
          [ bench "normalize-ddl" (nf normalizeDdl eventsDdl)
          ]
      , bgroup
          "fence"
          [ bench "acquire-release" (whnfIO (acquireWriterFence database "bench" >>= releaseWriterFence))
          ]
      ]
  where
    row instanceId position payload =
      [ SQLText instanceId
      , SQLInteger (fromIntegral position)
      , SQLText (instanceId <> ":" <> T.pack (show position))
      , SQLText "FiringStarted"
      , SQLInteger (fromIntegral position + 1)
      , SQLText payload
      ]
