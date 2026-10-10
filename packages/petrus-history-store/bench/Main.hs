-- | History store benchmarks, the twins of @bench/python_bench.py@: the same
-- 20 002-record History (a drained 4 000-token FIFO), so @bench/RESULTS.md@
-- can set the two side by side.
--
-- Workloads: JSONL append (one batch, and one record per append), JSONL
-- load (decode every line into the mirror), JSONL resume (load plus the
-- Instance's validating replay), and the in-memory store's appends and
-- reads. Two Haskell-only diagnostic rows split the JSONL write and read
-- into their in-memory halves (no file IO).
module Main (main) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Sequence qualified as Seq
import Petrus.HistoryStore.Jsonl (decodeLines, encodePayload)
import Data.Text qualified as T
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.History (Record)
import Petrus.Impetus.HistoryStore (HistoryStore (..), inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Tasty.Bench

historyFifoTokens, perRecordAppends :: Int
historyFifoTokens = 4000
perRecordAppends = 2000

path :: String -> NetPath
path = either (error . T.unpack) id . netPath . T.pack

item :: Int -> Token
item n = Token (Just "Item") (Object [("seq", Int (fromIntegral n))])

fifo :: Int -> (Net, Marking)
fifo tokens =
  ( either (error . T.unpack) id $
      mkNet (netSpec [place queue, place (path "taken")] [transition (path "take")] [arc queue (path "take"), arc (path "take") (path "taken")])
  , markingFromList [(queue, map item [0 .. tokens - 1])]
  )
  where
    queue = path "queue"

drained :: IO [Record]
drained = do
  let (net, initial) = fifo historyFifoTokens
  inst <- newInstance net defaultInstanceConfig {initialMarking = initial, suppliedIdentity = Just "bench"} >>= either (error . show) pure
  _ <- run inst >>= either (error . show) pure
  Store.records (instanceHistory inst)

scratchDirectory :: IO FilePath
scratchDirectory = do
  base <- getTemporaryDirectory
  (file, handle) <- openTempFile base "petrus-history-store-bench"
  hClose handle
  removeFile file
  createDirectory file
  pure file

main :: IO ()
main = do
  history <- drained
  dir <- scratchDirectory
  let existing = dir </> "existing.jsonl"
      fresh = dir </> "fresh.jsonl"
      (net, _) = fifo historyFifoTokens
  openJsonlHistoryStore existing >>= \s -> s.extend history
  memory <- inMemoryHistoryStore
  memory.extend history
  loaded <- openJsonlHistoryStore existing
  content <- BS.readFile existing
  let firstRecords = take perRecordAppends history
  defaultMain
    [ bgroup
        "jsonl"
        [ bench "append-one-batch" $ whnfIO $ do
            store <- openJsonlHistoryStore fresh
            store.extend history
            n <- store.count
            removeFile fresh
            pure n
        , bench "append-per-record" $ whnfIO $ do
            store <- openJsonlHistoryStore fresh
            forM_ firstRecords (Store.append store)
            n <- store.count
            removeFile fresh
            pure n
        , bench "load" $ whnfIO $ openJsonlHistoryStore existing >>= \s -> s.count
        , bench "resume" $ whnfIO $ do
            store <- openJsonlHistoryStore existing
            inst <- resume net store defaultInstanceConfig >>= either (error . show) pure
            length . markingToList <$> marking inst
        ]
    , bgroup
        "diagnostic"
        [ bench "encode-payload" $ nf (fmap BS.length . encodePayload) history
        , bench "decode-lines" $ whnf (either (error . T.unpack) Seq.length . decodeLines "x") content
        ]
    , bgroup
        "store"
        [ bench "in-memory-append" $ whnfIO $ do
            store <- inMemoryHistoryStore
            forM_ history (Store.append store)
            store.count
        , bench "in-memory-records" $ whnfIO $ Seq.length <$> memory.snapshot
        , bench "jsonl-records" $ whnfIO $ Seq.length <$> loaded.snapshot
        , bench "in-memory-iterate" $ whnfIO $ foldl' (\n _ -> n + 1) (0 :: Int) <$> memory.snapshot
        , bench "in-memory-records-list" $ whnfIO $ length <$> Store.records memory
        ]
    ]
  removeDirectoryRecursive dir
