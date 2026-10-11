-- | Pieces shared by the durable backends: the store's refusal type,
-- CPython's @json.loads@ diagnostic text, and the reference's
-- @decode_record(json.loads(...))@ over a stored payload.
--
-- Not a stable interface; the backends re-export what callers need.
module Petrus.HistoryStore.Internal
  ( HistoryStoreError (..)
  , pythonDiagnostic
  , decodeStored
  , pythonDict
  ) where

import Control.Exception (Exception (..))
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.History (Record)
import Petrus.Impetus.History.Codec (checkRecordHeader, decodeRecord)
import Petrus.Json (Json (..), jsonTypeName)
import Petrus.Json.Python.Decode (decodeUtf8Python)
import Petrus.Json.Python.Scanner (jsonDecodeError)

-- | A refusal by the store: the reference's @ValueError@ (an unencodable
-- record, an undecodable line or row, a conflicting fact, a refused
-- schema).
newtype HistoryStoreError = HistoryStoreError Text
  deriving stock (Eq, Show)

instance Exception HistoryStoreError where
  displayException (HistoryStoreError message) = T.unpack message

-- | CPython's @json.loads@ diagnostic for refused bytes (as @str@ after
-- decoding them as UTF-8). The 'Text' is the fallback when the CPython-exact
-- scanner accepts what the fast parser refused.
pythonDiagnostic :: ByteString -> Text -> Text
pythonDiagnostic bytes fallback = case decodeUtf8Python bytes of
  Left utf8Error -> utf8Error
  Right text -> fromMaybe fallback (jsonDecodeError text)

-- | The reference's @decode_record(payload)@ for a parsed stored payload.
-- @decode_record@ starts with @dict(payload)@, so a payload that is not a
-- JSON object is refused with @dict@'s own @TypeError@ / @ValueError@ text,
-- and a list of pairs (or of two-character strings) is converted to the
-- mapping @dict@ builds from it.
decodeStored :: Json -> Either Text Record
decodeStored payload = case payload of
  Object _ -> decodeRecord payload
  other -> do
    pairs <- pythonDict other
    case traverse textKey pairs of
      Just members -> decodeRecord (Object members)
      -- A key that is not a @str@: the discriminator and schema checks run
      -- first, then @Record(**data)@ refuses the keyword.
      Nothing -> do
        checkRecordHeader [(key, value) | (Right key, value) <- pairs, key `elem` ["record", "schema"]]
        Left "keywords must be strings"
  where
    textKey (key, value) = either (const Nothing) (\k -> Just (k, value)) key

-- | CPython's @dict(value)@ for a value that is not a JSON object: the
-- @TypeError@ / @ValueError@ text it raises, or the keys (a 'Text' for a
-- @str@ key, the 'Json' of any other hashable key) and values it builds, in
-- first-insertion order with the last value for a repeated key.
pythonDict :: Json -> Either Text [(Either Json Text, Json)]
pythonDict = \case
  Object members -> Right [(Right key, value) | (key, value) <- members]
  String text -> build [String (T.singleton c) | c <- T.unpack text]
  Array items -> build items
  other -> Left ("'" <> jsonTypeName other <> "' object is not iterable")
  where
    build items = foldl insert [] <$> traverse pair (zip [0 :: Int ..] items)
    pair (index, item) = case item of
      String text
        | T.length text == 2 -> Right (Right (T.take 1 text), String (T.drop 1 text))
        | otherwise -> wrongLength index (T.length text)
      Array [key, value] -> (,value) <$> hashable key
      Array items -> wrongLength index (length items)
      Object [(first, _), (second, _)] -> Right (Right first, String second)
      Object members -> wrongLength index (length members)
      _ -> Left "object is not iterable"
    wrongLength index size =
      Left ("dictionary update sequence element #" <> T.pack (show index) <> " has length " <> T.pack (show size) <> "; 2 is required")
    hashable = \case
      String key -> Right (Right key)
      unhashable@(Array _) -> Left (unhashableKey unhashable)
      unhashable@(Object _) -> Left (unhashableKey unhashable)
      key -> Right (Left key)
    unhashableKey value = "cannot use '" <> jsonTypeName value <> "' as a dict key (unhashable type: '" <> jsonTypeName value <> "')"
    insert built (key, value)
      | any (sameKey key . fst) built = [(k, if sameKey key k then value else v) | (k, v) <- built]
      | otherwise = built ++ [(key, value)]
    sameKey (Right a) (Right b) = a == b
    sameKey (Left a) (Left b) = a == b
    sameKey _ _ = False
