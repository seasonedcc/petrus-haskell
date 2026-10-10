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
import Test.Tasty.Bench

eventsDdl :: Text
eventsDdl =
  "CREATE TABLE impetus_history_events (\n    instance TEXT NOT NULL,\n    position INTEGER NOT NULL CHECK (position >= 0),\n    event_id TEXT NOT NULL UNIQUE,\n    record_type TEXT NOT NULL,\n    occurrence INTEGER,\n    payload TEXT NOT NULL,\n    recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),\n    PRIMARY KEY (instance, position)\n)"

insertEvent :: Text
insertEvent =
  "INSERT INTO impetus_history_events (instance, position, event_id, record_type, occurrence, payload) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING"

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
    defaultMain
      [ bgroup
          "connect"
          [ bench "local-dispatch-profile" (whnfIO (open localDispatchProfile database >>= close))
          ]
      , bgroup
          "tx"
          [ bench "immediate-insert-commit" $ whnfIO $ do
              position <- fresh
              withImmediateTransaction connection (execute connection insertEvent (row "single" position payload))
          , bench "immediate-insert-100" $ whnfIO $ do
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
