-- | SQLite Engine benchmarks, the twins of @bench/python_bench.py@: the
-- order scenario of petrus-engine's benchmarks driven through
-- 'createEngine' / 'loadEngine' over a SQLite History (one fsynced
-- @BEGIN IMMEDIATE@ commit per History batch, the reference's
-- @synchronous = FULL@ WAL posture), and the fenced open/close round trip.
module Main (main) where

import Control.Monad (forM_, when)
import Data.IORef
import Petrus.Engine qualified as Engine
import Petrus.Engine.Scenario
import Petrus.Engine.Sqlite (createEngine, loadEngine)
import Petrus.Impetus.TestSupport (netOf)
import Petrus.Motus.Dispatch.Inline (inlineDispatch, newInlineDispatch)
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import System.Directory (createDirectory, doesFileExist, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Tasty (localOption)
import Test.Tasty.Bench

smallOrders, largeOrders :: Int
smallOrders = 3
largeOrders = 200

advanceUntilRest :: Engine.Engine -> IO ()
advanceUntilRest engine = do
  outcome <- Engine.advance engine
  if outcome.ready then advanceUntilRest engine else pure ()

-- | Create over a fresh file, deliver, drive to rest, close; the History
-- length.
orders :: FilePath -> Int -> IO Int
orders path n = do
  port <- orderActivities
  prepared <- newIORef 0
  engine <- createEngine path orderNet orderIdentity port (orderOptions prepared)
  deliverOrders engine n
  advanceUntilRest engine
  size <- length <$> Engine.records engine
  Engine.close engine
  pure size

-- | Remove a database and its WAL sidecars.
removeDatabase :: FilePath -> IO ()
removeDatabase path = forM_ ["", "-wal", "-shm"] $ \suffix -> do
  present <- doesFileExist (path <> suffix)
  when present (removeFile (path <> suffix))

scratchDirectory :: IO FilePath
scratchDirectory = do
  base <- getTemporaryDirectory
  (file, handle) <- openTempFile base "petrus-engine-sqlite-bench"
  hClose handle
  removeFile file
  createDirectory file
  pure file

main :: IO ()
main = do
  dir <- scratchDirectory
  let fresh = dir </> "fresh.sqlite3"
      existing = dir </> "existing.sqlite3"
      empty = dir </> "empty.sqlite3"
      emptyNet = netOf [] [] []
      noActivities = inlineDispatch <$> newInlineDispatch mempty
  loaded <- orders existing largeOrders
  small <- orders fresh smallOrders
  removeDatabase fresh
  noActivities >>= \port -> createEngine empty emptyNet "one" port Engine.defaultEngineOptions >>= Engine.close
  -- The result sizes python_bench.py prints, as a check that both sides time
  -- the same work.
  putStrLn ("sizes: orders-small-sqlite " <> show small <> ", orders-large-sqlite " <> show loaded)
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain . map (localOption WallTime) $
    [ bgroup
        "engine-sqlite"
        [ bench "orders-small-sqlite" $ whnfIO $ do
            size <- orders fresh smallOrders
            removeDatabase fresh
            pure size
        , bench "orders-large-sqlite" $ whnfIO $ do
            size <- orders fresh largeOrders
            removeDatabase fresh
            pure size
        , bench "load-sqlite" $ whnfIO $ do
            port <- orderActivities
            prepared <- newIORef 0
            engine <- loadEngine existing orderNet orderIdentity port (orderOptions prepared)
            _ <- Engine.advance engine
            size <- length <$> Engine.records engine
            Engine.close engine
            pure size
        , bench "open-close" $ whnfIO $ do
            port <- inMemoryDispatch <$> newInMemoryDispatch
            engine <- loadEngine empty emptyNet "one" port Engine.defaultEngineOptions
            size <- length <$> Engine.records engine
            Engine.close engine
            pure size
        ]
    ]
  removeDirectoryRecursive dir
