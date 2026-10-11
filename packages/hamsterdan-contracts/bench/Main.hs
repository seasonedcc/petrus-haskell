{-# LANGUAGE OverloadedRecordDot #-}

-- | Hot-path benchmarks for hamsterdan-contracts; bench.py runs the same
-- operations on the same inputs (bench/inputs.json) in the pinned Python.
--
-- > cabal bench hamsterdan-contracts
--
-- Results and the comparison with Python are in RESULTS.md.
module Main (main) where

import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Contracts.Codec (DecodeError, dump, validateJson)
import Hamsterdan.Contracts.ReadinessV5 qualified as V5
import Hamsterdan.PyLiteral (dictEntry, literalEval, sortedItemsDigest)
import Petrus.Json (Json (..), compact, dumps, parseJson, pythonLoads)
import Test.Tasty (localOption)
import Test.Tasty.Bench

main :: IO ()
main = do
  inputs <- BS.readFile "bench/inputs.json"
  (snapshotBytes, gateBytes, kind) <- case parseJson pythonLoads inputs of
    Right (Object members)
      | Just (String snapshotText) <- lookup "snapshot" members
      , Just (String gateText) <- lookup "gate_fact" members
      , Just (String kindText) <- lookup "entry_kind" members ->
          pure (TE.encodeUtf8 snapshotText, TE.encodeUtf8 gateText, kindText)
    _ -> fail "bench/inputs.json is malformed"
  snapshot <- either (fail . show) pure (validateJson snapshotBytes :: Either DecodeError V5.Snapshot)
  gate <- either (fail . show) pure (validateJson gateBytes :: Either DecodeError V5.GateFact)
  let body = gate.body
      entry = dictEntry kind body
      entryBody = snd (breakEntry entry)
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain . map (localOption WallTime) $
    [ bench "contract decode Snapshot (validate_json)" $ nf (either (const 0) (const (1 :: Int)) . (validateJson :: BS.ByteString -> Either DecodeError V5.Snapshot)) snapshotBytes
    , bench "contract encode Snapshot (dump + json.dumps)" $ nf (either (const BS.empty) id . dumps compact . dump) snapshot
    , bench "contract decode GateFact (validate_json)" $ nf (either (const 0) (const (1 :: Int)) . (validateJson :: BS.ByteString -> Either DecodeError V5.GateFact)) gateBytes
    , bench "contract encode GateFact (dump + json.dumps)" $ nf (either (const BS.empty) id . dumps compact . dump) gate
    , bench "literal print dashboard entry (f'{kind}:{body}')" $ nf (dictEntry kind) body
    , bench "literal print digest (sorted items repr)" $ nf (sortedItemsDigest kind) body
    , bench "literal parse dashboard entry (literal_eval)" $ nf (either (const 0) (const (1 :: Int)) . literalEval) entryBody
    ]
  where
    breakEntry :: Text -> (Text, Text)
    breakEntry entry = let (k, rest) = T.breakOn ":" entry in (k, T.drop 1 rest)
