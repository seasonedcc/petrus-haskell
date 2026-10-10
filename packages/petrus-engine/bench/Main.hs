-- | Engine benchmarks, the twins of @bench/python_bench.py@: the same order
-- scenario (identified deliveries, a pure validation, an inline Activity
-- charge, a delayed settlement) and the same passthrough chain, driven end
-- to end by one-action 'Engine.advance' turns, so @bench/RESULTS.md@ can set
-- the two side by side.
module Main (main) where

import Data.IORef
import Petrus.Engine qualified as Engine
import Petrus.Engine.Scenario
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.HistoryStore (HistoryStore, inMemoryHistoryStore)
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Tasty.Bench

smallOrders, largeOrders, chainLength, chainTokens :: Int
smallOrders = 3
largeOrders = 200
chainLength = 20
chainTokens = 50

advanceUntilRest :: Engine.Engine -> IO ()
advanceUntilRest engine = do
  outcome <- Engine.advance engine
  if outcome.ready then advanceUntilRest engine else pure ()

orders :: IO HistoryStore -> Int -> IO Int
orders history n = do
  store <- history
  port <- orderActivities
  prepared <- newIORef 0
  engine <- Engine.create orderNet orderIdentity store port (orderOptions prepared)
  deliverOrders engine n
  advanceUntilRest engine
  size <- length <$> Engine.records engine
  Engine.close engine
  pure size

chain :: IO Int
chain = do
  store <- inMemoryHistoryStore
  port <- inMemoryDispatch <$> newInMemoryDispatch
  engine <- Engine.create (chainNet chainLength) "chain" store port Engine.defaultEngineOptions {Engine.marking = chainMarking chainTokens}
  advanceUntilRest engine
  size <- length <$> Engine.records engine
  Engine.close engine
  pure size

scratchDirectory :: IO FilePath
scratchDirectory = do
  base <- getTemporaryDirectory
  (file, handle) <- openTempFile base "petrus-engine-bench"
  hClose handle
  removeFile file
  createDirectory file
  pure file

main :: IO ()
main = do
  dir <- scratchDirectory
  let fresh = dir </> "fresh.jsonl"
      existing = dir </> "existing.jsonl"
  loaded <- orders (openJsonlHistoryStore existing) largeOrders
  -- The result sizes python_bench.py prints, as a check that both sides time
  -- the same work.
  small <- orders inMemoryHistoryStore smallOrders
  chained <- chain
  putStrLn ("sizes: orders-small " <> show small <> ", orders-large " <> show loaded <> ", chain " <> show chained)
  defaultMain
    [ bgroup
        "engine"
        [ bench "orders-small" $ whnfIO $ orders inMemoryHistoryStore smallOrders
        , bench "orders-large" $ whnfIO $ orders inMemoryHistoryStore largeOrders
        , bench "orders-large-jsonl" $ whnfIO $ do
            size <- orders (openJsonlHistoryStore fresh) largeOrders
            removeFile fresh
            pure size
        , bench "chain" $ whnfIO chain
        , bench "load-jsonl" $ whnfIO $ do
            store <- openJsonlHistoryStore existing
            port <- orderActivities
            prepared <- newIORef 0
            engine <- Engine.load orderNet orderIdentity store port (orderOptions prepared)
            _ <- Engine.advance engine
            size <- length <$> Engine.records engine
            Engine.close engine
            pure size
        ]
    ]
  removeDirectoryRecursive dir
