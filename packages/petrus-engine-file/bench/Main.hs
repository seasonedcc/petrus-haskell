-- | fileVersion 2 benchmarks, the twins of @bench/python_bench.py@: the same
-- input texts, byte for byte (both sides print their sizes), and the same
-- steps.
--
-- * @parse@: 'fromJson' (@FlatNetFile.model_validate_json@);
-- * @to_json@: 'toJson' on the parsed file (@file.to_json()@);
-- * @format@: 'reformatContent' with indent 2 and max-inline 120
--   (@reformat_content@, the @petrus-format-json@ transform);
-- * @load@: 'loadFile' and 'toSchema' from files on disk
--   (@FlatNet.from_filename(path).to_schema()@).
module Main (main) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (intercalate)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.EngineFile
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (localOption)
import Test.Tasty.Bench

-- | @chain_text(n, name)@.
chainText :: Int -> String -> ByteString
chainText n name =
  TE.encodeUtf8 . T.pack $
    "{\"net\": \""
      <> name
      <> "\", \"places\": {"
      <> places
      <> "}, \"transitions\": {"
      <> transitions
      <> "}, \"arcs\": ["
      <> intercalate ", " (concatMap arcs [0 .. n - 1])
      <> "], \"viewState\": {\"layout\": {"
      <> layout
      <> "}, \"zoom\": 1.0, \"pan\": [0, 0]}}"
  where
    places =
      intercalate ", " [if i == 0 then "\"p0\": {\"initial\": 1}" else "\"p" <> show i <> "\": {\"label\": \"Place " <> show i <> "\"}" | i <- [0 .. n]]
    transitions =
      intercalate
        ", "
        [ "\"t" <> show i <> "\": " <> (if i `mod` 5 == 0 then "{\"handler\": \"step\", \"delay\": 30}" else "{\"handler\": \"step\"}")
        | i <- [0 .. n - 1]
        ]
    arcs i =
      ["{\"source\": \"p" <> show i <> "\", \"target\": \"t" <> show i <> "\"}"]
        <> [ if i `mod` 3 == 0
               then "{\"target\": \"p" <> show (i + 1) <> "\", \"source\": \"t" <> show i <> "\", \"weight\": 2}"
               else "{\"source\": \"t" <> show i <> "\", \"target\": \"p" <> show (i + 1) <> "\"}"
           ]
        <> ["{\"source\": \"p0\", \"target\": \"t" <> show i <> "\", \"kind\": \"read\"}" | i `mod` 7 == 3]
    layout =
      intercalate ", " $
        ["\"p" <> show i <> "\": [" <> show (i * 150) <> ".0, 50.0]" | i <- [0 .. n]]
          <> ["\"t" <> show i <> "\": [" <> show (i * 150 + 75) <> ".5, 150.0]" | i <- [0 .. n - 1]]

-- | @mounted_text(k)@.
mountedText :: Int -> ByteString
mountedText k =
  TE.encodeUtf8 . T.pack $
    "{\"net\": \"root\", \"refs\": {"
      <> intercalate ", " ["\"u" <> show i <> "\": {\"ref\": \"unit.json\"}" | i <- [0 .. k - 1]]
      <> "}, \"places\": {\"hub\": {\"initial\": 1}}, \"transitions\": {"
      <> intercalate ", " ["\"feed" <> show i <> "\": {}" | i <- [0 .. k - 1]]
      <> "}, \"arcs\": ["
      <> intercalate
        ", "
        [ "{\"source\": \"hub\", \"target\": \"feed" <> show i <> "\"}, {\"source\": \"feed" <> show i <> "\", \"target\": \"u" <> show i <> ".p0\"}"
        | i <- [0 .. k - 1]
        ]
      <> "]}"

orFail :: (Show e) => Either e a -> a
orFail = either (error . show) id

load :: FilePath -> IO FlatSchema
load path = orFail . (>>= toSchema) <$> loadFile (T.pack path)

chainSizes, mountedSizes :: [Int]
chainSizes = [10, 1000, 10000]
mountedSizes = [10, 100, 1000]

main :: IO ()
main = withSystemTempDirectory "petrus-engine-file-bench" $ \dir -> do
  BS.writeFile (dir </> "unit.json") (chainText 10 "unit")
  forM_ chainSizes $ \n -> do
    let text = chainText n "chain"
    BS.writeFile (dir </> ("chain-" <> show n <> ".json")) text
    let out = orFail (fromJson text >>= toJsonBytes defaultIndent defaultMaxInline)
    putStrLn ("chain-" <> show n <> ": " <> show (BS.length text) <> " bytes in, " <> show (BS.length out) <> " bytes out")
  forM_ mountedSizes $ \k -> do
    let text = mountedText k
    BS.writeFile (dir </> ("mounted-" <> show k <> ".json")) text
    schema <- load (dir </> ("mounted-" <> show k <> ".json"))
    putStrLn ("mounted-" <> show k <> ": " <> show (BS.length text) <> " bytes in, " <> show (length schema.arcs) <> " arcs")
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain . map (localOption WallTime) $
    [ env (pure (chainText n "chain")) $ \text ->
        bgroup
          ("chain-" <> show n)
          [ bench "parse" (nf (orFail . fromJson) text)
          , env (pure (orFail (fromJson text))) $ \parsed ->
              bench "to_json" (nf (orFail . toJson defaultIndent defaultMaxInline) parsed)
          , bench "format" (nf (orFail . reformatContent 2 formatMaxInline) text)
          , bench "load" (nfIO (load (dir </> ("chain-" <> show n <> ".json"))))
          ]
    | n <- chainSizes
    ]
      <> [ bgroup ("mounted-" <> show k) [bench "load" (nfIO (load (dir </> ("mounted-" <> show k <> ".json"))))]
         | k <- mountedSizes
         ]
