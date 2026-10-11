-- | The CPython operations the operator applies to provider JSON and
-- command output, beyond those "Hamsterdan.Export.Python" already spells:
-- @dict.get(key, default)@, @value[key]@, @value[:n]@, set membership,
-- @urllib.parse.quote@, @shlex.quote@, and text-mode decoding.
module Hamsterdan.Operator.Python
  ( getOr
  , getMaybe
  , subscriptKey
  , sliceItems
  , inSet
  , isDict
  , isList
  , isStr
  , isInt
  , isBool
  , dictKeys
  , urlQuote
  , shlexQuote
  , listRepr
  , decodeOutput
  , pyStrip
  , pyCasefold
  , pyUpper
  , pyIsSpace
  , loadsJson
  , JsonOutcome (..)
  , dumpsPlain
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr, isAsciiLower, isAsciiUpper, isDigit, toUpper)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Export.Python (PV (..), PyError (..), hashCheck, loadsText, loadsValue, pyEq, toJson, typeName)
import Hamsterdan.GitHub.Python qualified as Py
import Hamsterdan.Operator.FastJson (fastLoads)
import Hamsterdan.PyLiteral (strRepr)
import Numeric (showHex)
import Petrus.EngineFile.PyText (decodeText)
import Petrus.EngineFile.Validate (PyException (..))
import Petrus.Json (EncodeError (..), defaultDumps, dumps, encodeErrorMessage)

-- | @value.get(key, default)@ on what must be a dict.
getOr :: Text -> PV -> PV -> Either PyError PV
getOr key fallback = \case
  PDict members -> Right (maybe fallback id (lookup key members))
  other -> Left (PyError "AttributeError" ("'" <> typeName other <> "' object has no attribute 'get'"))

-- | @value.get(key)@ ('PNone' when absent).
getMaybe :: Text -> PV -> Either PyError PV
getMaybe key = getOr key PNone

-- | @value[key]@ for a @str@ key.
subscriptKey :: Text -> PV -> Either PyError PV
subscriptKey key = \case
  PDict members -> maybe (Left (PyError "KeyError" (strRepr key))) Right (lookup key members)
  PStr _ -> Left (PyError "TypeError" "string indices must be integers, not 'str'")
  PList _ -> Left (PyError "TypeError" "list indices must be integers or slices, not str")
  other -> Left (PyError "TypeError" ("'" <> typeName other <> "' object is not subscriptable"))

-- | The items @for item in value[:n]@ visits.
sliceItems :: Int -> PV -> Either PyError [PV]
sliceItems n = \case
  PList items -> Right (take n items)
  PStr s -> Right (map (PStr . T.singleton) (T.unpack (T.take n s)))
  PDict _ -> Left (PyError "KeyError" ("slice(None, " <> T.pack (show n) <> ", None)"))
  other -> Left (PyError "TypeError" ("'" <> typeName other <> "' object is not subscriptable"))

-- | @value in {a, b, ...}@: an unhashable probe raises; otherwise equality
-- as @==@ decides (so @1 in {True}@).
inSet :: PV -> [PV] -> Either PyError Bool
inSet value members = do
  hashCheck value
  Right (any (pyEq value) members)

isDict, isList, isStr, isInt, isBool :: PV -> Bool
isDict = \case PDict _ -> True; _ -> False
isList = \case PList _ -> True; _ -> False
isStr = \case PStr _ -> True; _ -> False
-- | @type(value) is int@.
isInt = \case PInt _ -> True; _ -> False
isBool = \case PBool _ -> True; _ -> False

dictKeys :: PV -> [Text]
dictKeys = \case
  PDict members -> map fst members
  _ -> []

-- | @urllib.parse.quote(text, safe="")@.
urlQuote :: Text -> Text
urlQuote = T.concat . map escape . BS.unpack . TE.encodeUtf8
  where
    escape w
      | unreserved (chr (fromIntegral w)) = T.singleton (chr (fromIntegral w))
      | otherwise = "%" <> T.justifyRight 2 '0' (T.map toUpper (T.pack (showHex w "")))
    unreserved c = c < '\x80' && (isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("_.-~" :: String))

-- | @shlex.quote(text)@.
shlexQuote :: Text -> Text
shlexQuote s
  | T.null s = "''"
  | T.all safe s = s
  | otherwise = "'" <> T.replace "'" "'\"'\"'" s <> "'"
  where
    safe c = c < '\x80' && (isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("_@%+=:,./-" :: String))

-- | @repr(list_of_str)@.
listRepr :: [Text] -> Text
listRepr items = "[" <> T.intercalate ", " (map strRepr items) <> "]"

-- | What @subprocess.run(..., text=True)@ makes of captured bytes: strict
-- UTF-8 and universal newlines, or its @UnicodeDecodeError@.
decodeOutput :: ByteString -> Either PyError Text
decodeOutput bytes = case decodeText bytes of
  Left (PyException name text) -> Left (PyError name text)
  Right decoded -> Right (TE.decodeUtf8 decoded)

pyStrip :: Text -> Text
pyStrip = Py.strip

pyCasefold :: Text -> Text
pyCasefold = Py.casefold

pyUpper :: Text -> Text
pyUpper = Py.upper

pyIsSpace :: Char -> Bool
pyIsSpace = Py.isSpace

-- | How @json.loads@ ended.
data JsonOutcome
  = Loaded PV
  | -- | @json.JSONDecodeError@.
    Malformed
  | -- | Any other exception (it propagates).
    Raised PyError

-- | @json.loads(text)@ for a @str@ or @bytes@ value.
loadsJson :: PV -> JsonOutcome
loadsJson value = case (case value of PStr s -> loadsStr s; _ -> loadsValue value) of
  Right loaded -> Loaded loaded
  Left e
    | e.cls == "json.decoder.JSONDecodeError" -> Malformed
    | otherwise -> Raised e

-- | @json.loads@ of a @str@: the fast path when the document is in its
-- subset, the reference loader otherwise.
loadsStr :: Text -> Either PyError PV
loadsStr text = maybe (loadsText (TE.encodeUtf8 text)) Right (fastLoads text)

-- | @json.dumps(value)@ (unsorted, default separators).
dumpsPlain :: PV -> Either PyError Text
dumpsPlain value = do
  json <- toJson False value
  either (Left . refusal) (Right . TE.decodeUtf8) (dumps defaultDumps json)
  where
    refusal e = case e of
      NestingTooDeep _ -> PyError "RecursionError" (T.pack (encodeErrorMessage e))
      _ -> PyError "ValueError" (T.pack (encodeErrorMessage e))
