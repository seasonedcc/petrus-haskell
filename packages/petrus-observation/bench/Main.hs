-- | Observation benchmarks, the twins of @bench/python_bench.py@: the same
-- loop net, markings, and History lengths, so @bench/RESULTS.md@ can set the
-- two side by side.
--
-- The workload is a two-place loop (@a -> t1 -> b -> t2 -> a@) holding M
-- tokens, stepped until its History holds at least N records. Each row
-- times one Engine read door's work: 'capture' of the Instance and its
-- History, then the pure projection, forced to the last node. Before the
-- timings the program prints one SHA-256 per measured output (compact,
-- key-sorted, ASCII JSON); @python_bench.py@ prints the same digests, which
-- is how the two sides are seen to produce the same values.
module Main (main) where

import Control.Monad (forM, forM_)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.Instance hiding (candidates, marking)
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Json
import Petrus.Observation
import Test.Tasty.Bench

data Workload = Workload {records :: Int, tokens :: Int}

label :: Workload -> String
label w = "N=" <> show w.records <> " M=" <> show w.tokens

path :: String -> NetPath
path = either (error . T.unpack) id . netPath . T.pack

loopNet :: Net
loopNet =
  either (error . T.unpack) id $
    mkNet
      ( netSpec
          [place (path "a"), place (path "b")]
          [transition (path "t1"), transition (path "t2")]
          [arc (path "a") (path "t1"), arc (path "t1") (path "b"), arc (path "b") (path "t2"), arc (path "t2") (path "a")]
      )

item :: Int -> Token
item n = Token (Just "Item") (Object [("i", Int (fromIntegral n)), ("label", String (T.pack ("token-" <> show n)))])

-- | The loop Instance with M tokens, stepped until N records.
built :: Workload -> IO Instance
built w = do
  inst <-
    either (fail . T.unpack . renderInstanceError) pure
      =<< newInstance loopNet defaultInstanceConfig {initialMarking = markingFromList [(path "a", map item [0 .. w.tokens - 1])], suppliedIdentity = Just "bench"}
  let drive = do
        count <- (instanceHistory inst).count
        if count >= w.records
          then pure ()
          else step inst Nothing >>= either (fail . T.unpack . renderInstanceError) (const drive)
  drive
  pure inst

orFail :: Either ObservationError Json -> Json
orFail = either (error . T.unpack . observationErrorText) id

-- | Every page of the captured History, 1 000 records at a time.
scan :: Observation -> [Json]
scan o = go 0
  where
    frontier = fromIntegral (Seq.length o.records)
    go after
      | after >= frontier = []
      | otherwise = orFail (historyPage o.observed.identity o.records after 1000) : go (after + 1000)

-- | Force every node; the node count.
forceJson :: Json -> Int
forceJson = \case
  Object ms -> foldl' (\n (k, v) -> k `seq` n + forceJson v) 1 ms
  Array xs -> foldl' (\n v -> n + forceJson v) 1 xs
  String t -> t `seq` 1
  Int i -> i `seq` 1
  Float d -> d `seq` 1
  Bool x -> x `seq` 1
  Null -> 1

digest :: Json -> String
digest value = case dumps compact {sortKeys = True, ensureAscii = True} value of
  Right bytes -> BC.unpack (hex (SHA256.hash bytes))
  Left e -> error (show e)
  where
    hex = BS.concatMap (\x -> BC.pack (pad (showHex' x)))
    pad s = replicate (2 - length s) '0' <> s
    showHex' x = let (q, r) = x `divMod` 16 in [digit q | q > 0] <> [digit r]
    digit d = "0123456789abcdef" !! fromIntegral d

snapshotWorkloads, documentWorkloads, historyWorkloads :: [Workload]
snapshotWorkloads = [Workload n m | n <- [1000, 10000], m <- [10, 1000]]
documentWorkloads = [Workload 1000 10, Workload 10000 10, Workload 1000 1000]
historyWorkloads = [Workload 1000 10, Workload 10000 10]

main :: IO ()
main = do
  snapshots <- forM snapshotWorkloads $ \w -> (,) w <$> built w
  documents <- forM documentWorkloads $ \w -> (,) w <$> built w
  histories <- forM historyWorkloads $ \w -> (,) w <$> built w
  forM_ snapshots $ \(w, inst) -> do
    o <- capture inst
    putStrLn ("digest snapshot " <> label w <> " frontier=" <> show (Seq.length o.records) <> " " <> digest (orFail (snapshot o)))
  forM_ histories $ \(w, inst) -> do
    o <- capture inst
    putStrLn ("digest history_page(0,1000) " <> label w <> " " <> digest (orFail (historyPage o.observed.identity o.records 0 1000)))
    putStrLn ("digest full_scan " <> label w <> " pages=" <> show (length (scan o)) <> " " <> digest (Array (scan o)))
  forM_ documents $ \(w, inst) -> do
    o <- capture inst
    putStrLn ("digest net_document " <> label w <> " " <> digest (orFail (netDocument o)))
  defaultMain
    [ bgroup "snapshot" [bench (label w) (nfIO (forceJson . orFail . snapshot <$> capture inst)) | (w, inst) <- snapshots]
    , bgroup
        "history_page(0,1000)"
        [bench (label w) (nfIO ((\o -> forceJson (orFail (historyPage o.observed.identity o.records 0 1000))) <$> capture inst)) | (w, inst) <- histories]
    , bgroup "full-scan" [bench (label w) (nfIO (sum . map forceJson . scan <$> capture inst)) | (w, inst) <- histories]
    , bgroup "net_document" [bench (label w) (nfIO (forceJson . orFail . netDocument <$> capture inst)) | (w, inst) <- documents]
    ]
