-- | Shared helpers for the differential corpora the pinned Python produced
-- (see @scripts/@).
module Corpus
  ( readCorpus
  , member
  , field
  , textOf
  , intOf
  , listOf
  , boolOf
  , canonical
  , expectNone
  , Mismatches
  , check
  , checkJson
  ) where

import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (IORef, modifyIORef')
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumps, parseJson, pythonJsonLoads)
import Test.Hspec (Expectation, expectationFailure)

-- | The rows of a JSONL corpus under @test/corpus@.
readCorpus :: FilePath -> IO [Json]
readCorpus path = do
  bytes <- BS.readFile ("test/corpus/" <> path)
  traverse row (filter (not . BS.null) (BS8.split '\n' bytes))
  where
    -- The rows are CPython's @json.dumps@ output, so a lone surrogate the
    -- reference held in a @str@ appears escaped; keep it, as @json.loads@ does.
    row line = either (fail . ("corpus row: " <>)) pure (parseJson pythonJsonLoads line)

member :: Text -> Json -> Maybe Json
member key = \case
  Object members -> lookup key members
  _ -> Nothing

-- | A member that must be present.
field :: Text -> Json -> Json
field key value = maybe (error ("corpus: missing " <> show key)) id (member key value)

textOf :: Json -> Text
textOf = \case
  String s -> s
  other -> error ("corpus: expected text, got " <> show other)

intOf :: Json -> Integer
intOf = \case
  Int i -> i
  other -> error ("corpus: expected an integer, got " <> show other)

boolOf :: Json -> Bool
boolOf = \case
  Bool b -> b
  other -> error ("corpus: expected a boolean, got " <> show other)

listOf :: Json -> [Json]
listOf = \case
  Array items -> items
  Null -> []
  other -> error ("corpus: expected a list, got " <> show other)

-- | A type- and order-insensitive-for-objects spelling for comparisons:
-- @json.dumps(value, sort_keys=True)@.
canonical :: Json -> Text
canonical value = either (T.pack . show) TE.decodeUtf8 (dumps defaultDumps {sortKeys = True} value)

type Mismatches = IORef [String]

-- | Record a mismatch unless the two spellings agree.
check :: (Eq a, Show a) => Mismatches -> String -> a -> a -> IO ()
check mismatches context expected actual =
  unless (expected == actual) $
    modifyIORef' mismatches ((context <> "\n  expected: " <> show expected <> "\n  actual:   " <> show actual) :)

-- | Record a mismatch unless the two values spell the same JSON.
checkJson :: Mismatches -> String -> Json -> Json -> IO ()
checkJson mismatches context expected actual = check mismatches context (canonical expected) (canonical actual)

-- | Report the first few mismatches, if any.
expectNone :: [String] -> Expectation
expectNone mismatches =
  unless (null mismatches) $
    expectationFailure (show (length mismatches) <> " mismatches, first:\n" <> unlines (take 6 (reverse mismatches)))
