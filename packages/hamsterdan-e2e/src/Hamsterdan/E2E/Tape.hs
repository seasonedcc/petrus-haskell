-- | The tier B tape (docs/hamsterdan.md §5.2): what one Hamsterdan host run
-- exchanged with the world, as the recording seams of
-- @python/host_seams.py@ wrote it. @python/tape.py@ documents the format;
-- this module reads it.
--
-- Records keep the member order of the values they carry (an agent's
-- findings reach History in that order), and 'Json' keeps it too.
module Hamsterdan.E2E.Tape
  ( Tape (..)
  , tapeFormat
  , readTape
  , member
  , text
  , integer
  , list
  , canonical
  , signedHeaders
  ) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.GitHub.Webhooks (sign)
import Petrus.Json (Json (..), canonicalText, parseJson, pythonLoads)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- | One tape directory.
data Tape = Tape
  { meta :: Json
  , github :: [Json]
  , steps :: [Json]
  , agents :: [Json]
  , publisher :: [Json]
  }

tapeFormat :: Text
tapeFormat = "hamsterdan-e2e-tape/1"

readTape :: FilePath -> IO Tape
readTape root = do
  meta <- BS.readFile (root </> "meta.json") >>= parsed (root </> "meta.json")
  unless (member "format" meta == String tapeFormat) $
    ioError (userError (root <> ": not a " <> T.unpack tapeFormat <> " tape"))
  Tape meta <$> records "github.jsonl" <*> records "steps.jsonl" <*> records "agents.jsonl" <*> records "publisher.jsonl"
  where
    records name = do
      let path = root </> name
      present <- doesFileExist path
      if present
        then BS.readFile path >>= mapM (parsed path) . filter (not . BC.all (== ' ')) . BC.lines
        else pure []
    parsed path bytes = either (\problem -> ioError (userError (path <> ": " <> problem))) pure (parseJson pythonLoads bytes)

member :: Text -> Json -> Json
member key = \case
  Object members -> maybe Null id (lookup key members)
  _ -> Null

text :: Json -> Text
text = \case
  String value -> value
  _ -> ""

integer :: Json -> Integer
integer = \case
  Int value -> value
  Float value -> round value
  _ -> 0

list :: Json -> [Json]
list = \case
  Array items -> items
  _ -> []

-- | @json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)@.
canonical :: Json -> Text
canonical = either (T.pack . show) id . canonicalText

-- | The recorded headers with a fresh signature, in their recorded order
-- (@tape.signed_headers@).
signedHeaders :: Text -> Json -> ByteString -> [(Text, Text)]
signedHeaders secret headers body =
  [ (name, value)
  | Array [String name, String value] <- list headers
  , T.toLower name /= "x-hub-signature-256"
  ]
    <> [("x-hub-signature-256", sign secret body)]
