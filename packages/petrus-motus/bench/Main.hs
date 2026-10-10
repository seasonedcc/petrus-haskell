-- | Local Dispatch benchmarks, the twins of @bench/python_bench.py@: the
-- same custody round trips (dispatch -> claim -> complete -> collect) over
-- a fresh SQLite file, under the database clock and under a provider clock,
-- so @bench/RESULTS.md@ can set the two side by side.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (forM_, when)
import Data.IORef
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
  , openLocalDispatch
  )
import Petrus.Motus.Dispatch.Local qualified as Local
import System.Directory (createDirectory, doesFileExist, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Tasty.Bench

roundTrips :: Int
roundTrips = 50

-- | The Python bench's @work(value)@.
work :: Int -> ActivityInvocation
work value =
  ActivityInvocation
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

-- | Create a fresh file (schema initialization) and discard it.
openFresh :: FilePath -> IO Int
openFresh path = do
  _ <- openLocalDispatch path "bench" defaultLocalDispatchOptions
  discard path
  pure 0

-- | 'roundTrip' while a co-resident connection (an application's own, say)
-- holds the file open, so closing each per-operation connection is never
-- the last close and never checkpoints the WAL.
heldRoundTrip :: Int -> FilePath -> IO Int
heldRoundTrip n path = do
  _ <- openLocalDispatch path "bench" defaultLocalDispatchOptions
  collected <- bracket (Sql.open (T.pack path)) Sql.close $ \held -> do
    Sql.exec held "SELECT count(*) FROM impetus_local_dispatch_tasks"
    cycles False n path
  discard path
  pure collected

-- | Over a fresh file: dispatch n occurrences, claim and complete each with
-- one worker, collect them all; answer how many outcomes were collected.
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
  dispatch <- openLocalDispatch path "bench" defaultLocalDispatchOptions {clock = source}
  forM_ [1 .. n] $ \occurrence -> Local.dispatch dispatch occurrence (work occurrence)
  worker <- Local.workerWith dispatch defaultLocalWorkerOptions {explicitClaimant = Just "bench-worker"}
  let drain = do
        Local.claim worker >>= \case
          Nothing -> pure ()
          Just attempt -> Local.complete worker attempt (Object [("ok", Bool True)]) >> drain
  drain
  length <$> Local.collect dispatch

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
  defaultMain
    [ bgroup
        "local"
        [ bench "open-fresh" $ whnfIO $ openFresh path
        , bench "roundtrip-1" $ whnfIO $ roundTrip False 1 path
        , bench "roundtrip-50-db-clock" $ whnfIO $ roundTrip False roundTrips path
        , bench "roundtrip-50-provider-clock" $ whnfIO $ roundTrip True roundTrips path
        , bench "roundtrip-50-held-open" $ whnfIO $ heldRoundTrip roundTrips path
        ]
    ]
  removeDirectoryRecursive dir
