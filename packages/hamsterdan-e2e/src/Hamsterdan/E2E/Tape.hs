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
  , TapeError (..)
  , TapeValue (..)
  , field
  , optionalField
  , refused
  , member
  , canonical
  , signedHeaders
  ) where

import Control.Exception (Exception (..), throwIO)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.GitHub.Webhooks (sign)
import Petrus.Json (Json (..), canonicalText, lookupMember, parseJson, pythonLoads)
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
  unless (lookupMember "format" meta == Just (String tapeFormat)) $
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

-- | A tape record the replay cannot read: a member it must have is
-- missing (Python's @record["name"]@ raises @KeyError@), or a member
-- holds a value the replay cannot take. Within a step it fails that
-- step, as an exception in the reference's step does.
data TapeError
  = MissingMember Text Json
  | RefusedValue Text Json
  deriving stock (Show)

instance Exception TapeError where
  displayException = \case
    MissingMember key record -> "tape record without " <> show key <> ": " <> T.unpack (canonical record)
    RefusedValue key value -> "tape member " <> show key <> " holds " <> T.unpack (canonical value)

-- | A value a tape member holds, as the reference's replay takes it.
class TapeValue a where
  fromTape :: Json -> Maybe a

instance TapeValue Json where
  fromTape = Just

instance TapeValue Text where
  fromTape = \case
    String value -> Just value
    _ -> Nothing

instance TapeValue Integer where
  fromTape = \case
    Int value -> Just value
    _ -> Nothing

-- | @float(value)@ of a JSON number.
instance TapeValue Double where
  fromTape = \case
    Int value -> Just (fromInteger value)
    Float value -> Just value
    _ -> Nothing

instance TapeValue Bool where
  fromTape = \case
    Bool value -> Just value
    _ -> Nothing

-- | @None@ or a value.
instance (TapeValue a) => TapeValue (Maybe a) where
  fromTape = \case
    Null -> Just Nothing
    value -> Just <$> fromTape value

instance (TapeValue a) => TapeValue [a] where
  fromTape = \case
    Array items -> mapM fromTape items
    _ -> Nothing

-- | A pair unpacked from a two-item array (@for a, b in items@).
instance (TapeValue a, TapeValue b) => TapeValue (a, b) where
  fromTape = \case
    Array [a, b] -> (,) <$> fromTape a <*> fromTape b
    _ -> Nothing

-- | A triple unpacked from a three-item array.
instance (TapeValue a, TapeValue b, TapeValue c) => TapeValue (a, b, c) where
  fromTape = \case
    Array [a, b, c] -> (,,) <$> fromTape a <*> fromTape b <*> fromTape c
    _ -> Nothing

-- | @record[key]@: the member, or a 'TapeError'.
field :: (TapeValue a) => Text -> Json -> IO a
field key record = maybe (throwIO (MissingMember key record)) (taken key) (lookupMember key record)

-- | @record.get(key)@: 'Nothing' when the member is missing.
optionalField :: (TapeValue a) => Text -> Json -> IO (Maybe a)
optionalField key record = traverse (taken key) (lookupMember key record)

taken :: (TapeValue a) => Text -> Json -> IO a
taken key value = maybe (refused key value) pure (fromTape value)

-- | Refuse a member's value.
refused :: Text -> Json -> IO a
refused key value = throwIO (RefusedValue key value)

-- | A member of a JSON value, 'Null' when it has none: for reports the
-- reference built, whose members are compared whole.
member :: Text -> Json -> Json
member key = maybe Null id . lookupMember key

-- | @json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)@.
canonical :: Json -> Text
canonical = either (T.pack . show) id . canonicalText

-- | The recorded headers with a fresh signature, in their recorded order
-- (@tape.signed_headers@).
signedHeaders :: Text -> [(Text, Text)] -> ByteString -> [(Text, Text)]
signedHeaders secret headers body =
  [header | header@(name, _) <- headers, T.toLower name /= "x-hub-signature-256"]
    <> [("x-hub-signature-256", sign secret body)]
