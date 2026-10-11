-- | petrus-json against CPython's C-accelerated @json@ on realistic Petrus
-- documents (@bench/fixtures/@, written by @bench/make_fixtures.py@). Each
-- benchmark has a same-named twin in @bench/python_bench.py@; run both with
-- @scripts/bench petrus-json@ or interleave them with
-- @scripts/bench-compare petrus-json N@.
--
-- Every row starts from bytes and ends in bytes or a fully evaluated value,
-- as the Python twin does (@json.loads(bytes)@, @json.dumps(…).encode()@),
-- with the options the upstream call site passes.
module Main (main) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Petrus.Json
import System.Directory (doesDirectoryExist, getCurrentDirectory, makeAbsolute)
import System.FilePath (takeDirectory, (</>))
import Test.Tasty (localOption)
import Test.Tasty.Bench

-- | The fixtures directory, found from the repository root upward of the
-- working directory.
fixtures :: IO FilePath
fixtures = getCurrentDirectory >>= makeAbsolute >>= go
  where
    go dir = do
      let candidate = dir </> "packages" </> "petrus-json" </> "bench" </> "fixtures"
      found <- doesDirectoryExist candidate
      if found
        then pure candidate
        else if takeDirectory dir == dir then fail "petrus-json bench fixtures not found" else go (takeDirectory dir)

-- | Touch every node, so a lazily built value cannot flatter the parser.
size :: Json -> Int
size = \case
  Null -> 1
  Bool b -> b `seq` 1
  Int i -> i `seq` 1
  Float d -> d `seq` 1
  String s -> T.length s `seq` 1
  Array items -> foldl' (\n item -> n + size item) 1 items
  Object members -> foldl' (\n (key, item) -> key `seq` n + size item) 1 members

parseAll :: ParseOptions -> [BS.ByteString] -> Int
parseAll options = foldl' (\n line -> either error ((n +) . size) (parseJson options line)) 0

dumpAll :: EncodeOptions -> [Json] -> Int
dumpAll options = foldl' (\n value -> either (error . show) ((n +) . BS.length) (dumps options value)) 0

-- | @json.dumps(value, allow_nan=False)@: the JSONL History writer.
historyWriter :: EncodeOptions
historyWriter = defaultDumps {allowNan = False}

-- | @separators=(",", ":"), sort_keys=True, allow_nan=False@ (ASCII): the
-- Thread repository's writer.
threadWriter :: EncodeOptions
threadWriter = defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True, allowNan = False}

-- | @object_pairs_hook@ refusing duplicates, @parse_constant@ refusing: the
-- Net document reader.
documentReader :: ParseOptions
documentReader = pythonLoads {duplicateMembers = RejectDuplicates, allowNonFiniteConstants = False}

main :: IO ()
main = do
  dir <- fixtures
  history <- filter (not . BS.null) . BC.lines <$> BS.readFile (dir </> "history.jsonl")
  document <- BS.readFile (dir </> "net-document.json")
  threads <- filter (not . BS.null) . BC.lines <$> BS.readFile (dir </> "threads.jsonl")
  let records = map (either error id . parseJson pythonLoads) history
      documentValue = either error id (parseJson pythonLoads document)
      threadValues = map (either error id . parseJson pythonLoads) threads
  sum (map size records) `seq` size documentValue `seq` sum (map size threadValues) `seq` pure ()
  -- Wall-clock time, as the Python twin measures it (time.perf_counter_ns).
  defaultMain . map (localOption WallTime) $
    [ bgroup
        "history"
        [ bench "loads" (whnf (parseAll pythonLoads) history)
        , bench "dumps" (whnf (dumpAll historyWriter) records)
        , bench "dumps-canonical" (whnf (dumpAll compact {sortKeys = True}) records)
        ]
    , bgroup
        "net-document"
        [ bench "loads" (whnf (parseAll pythonLoads) [document])
        , bench "loads-strict" (whnf (parseAll documentReader) [document])
        , bench "dumps" (whnf (dumpAll indented) [documentValue])
        ]
    , bgroup
        "thread"
        [ bench "loads" (whnf (parseAll pythonLoads) threads)
        , bench "dumps" (whnf (dumpAll threadWriter) threadValues)
        ]
    ]
