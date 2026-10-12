-- | Shared helpers for the differential corpora the pinned Python produced
-- (scripts/gen_*_corpus.py).
module Corpus
  ( readCorpus
  , readCorpusFile
  , member
  , text
  , array
  , integer
  , spelled
  , expectNone
  ) where

import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Petrus.Json (Json (..), compact, dumps, parseJson, surrogateRefusingLoads)
import Test.Hspec

-- | The rows of a JSONL corpus.
readCorpus :: FilePath -> IO [Json]
readCorpus path = do
  bytes <- readCorpusFile path
  traverse row (filter (not . BS.null) (BS8.split '\n' bytes))
  where
    row line = either (fail . ("corpus row: " <>)) pure (parseJson surrogateRefusingLoads line)

readCorpusFile :: FilePath -> IO BS.ByteString
readCorpusFile path = BS.readFile ("test/corpus/" <> path)

member :: Text -> Json -> Maybe Json
member key = \case
  Object members -> lookup key members
  _ -> Nothing

text :: Text -> Json -> Text
text key value = case member key value of
  Just (String found) -> found
  other -> error ("corpus: missing text " <> show key <> ": " <> show other)

array :: Text -> Json -> [Json]
array key value = case member key value of
  Just (Array items) -> items
  other -> error ("corpus: missing array " <> show key <> ": " <> show other)

integer :: Text -> Json -> Integer
integer key value = case member key value of
  Just (Int i) -> i
  other -> error ("corpus: missing integer " <> show key <> ": " <> show other)

-- | The compact, order-preserving spelling of a value: comparisons through
-- it are byte-exact (unlike 'Json''s Python equality).
spelled :: Json -> Text
spelled value = either (const "<unencodable>") TE.decodeUtf8 (dumps compact value)

-- Mismatches are collected and the first few reported, so one failing
-- behavior does not drown the report.
expectNone :: [String] -> Expectation
expectNone mismatches =
  unless (null mismatches) $
    expectationFailure (show (length mismatches) <> " mismatches, first:\n" <> unlines (take 8 mismatches))
