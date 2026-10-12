-- | The CPython operations the operator applies to provider JSON and
-- command output, beyond those "Hamsterdan.Python.Object" already spells:
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
  , urlQuote
  , shlexQuote
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
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Python.Exception (PyObject (..), PythonException (..), dumpsError, keyError, pythonError)
import Hamsterdan.Python.Object (PV (..), hashCheck, loadsValue, pyEq, toJson, typeName)
import Hamsterdan.Python.Text qualified as Py
import Hamsterdan.Python.Url qualified as Url
import Petrus.EngineFile.PyText (decodeText)
import Petrus.Json (defaultDumps, dumps)

-- | @value.get(key, default)@ on what must be a dict.
getOr :: Text -> PV -> PV -> Either PythonException PV
getOr key fallback = \case
  PDict members -> Right (maybe fallback id (lookup key members))
  other -> Left (pythonError "AttributeError" ("'" <> typeName other <> "' object has no attribute 'get'"))

-- | @value.get(key)@ ('PNone' when absent).
getMaybe :: Text -> PV -> Either PythonException PV
getMaybe key = getOr key PNone

-- | @value[key]@ for a @str@ key.
subscriptKey :: Text -> PV -> Either PythonException PV
subscriptKey key = \case
  PDict members -> maybe (Left (keyError key)) Right (lookup key members)
  PStr _ -> Left (pythonError "TypeError" "string indices must be integers, not 'str'")
  PList _ -> Left (pythonError "TypeError" "list indices must be integers or slices, not str")
  other -> Left (pythonError "TypeError" ("'" <> typeName other <> "' object is not subscriptable"))

-- | The items @for item in value[:n]@ visits.
sliceItems :: Int -> PV -> Either PythonException [PV]
sliceItems n = \case
  PList items -> Right (take n items)
  PStr s -> Right (map (PStr . T.singleton) (T.unpack (T.take n s)))
  PDict _ -> Left (PythonException "KeyError" [PySlice Nothing (Just (toInteger n)) Nothing])
  other -> Left (pythonError "TypeError" ("'" <> typeName other <> "' object is not subscriptable"))

-- | @value in {a, b, ...}@: an unhashable probe raises; otherwise equality
-- as @==@ decides (so @1 in {True}@).
inSet :: PV -> [PV] -> Either PythonException Bool
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

-- | @urllib.parse.quote(text, safe="")@.
urlQuote :: Text -> Text
urlQuote = Url.quote ""

-- | @shlex.quote(text)@.
shlexQuote :: Text -> Text
shlexQuote s
  | T.null s = "''"
  | T.all safe s = s
  | otherwise = "'" <> T.replace "'" "'\"'\"'" s <> "'"
  where
    safe c = c < '\x80' && (isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("_@%+=:,./-" :: String))


-- | What @subprocess.run(..., text=True)@ makes of captured bytes: strict
-- UTF-8 and universal newlines, or its @UnicodeDecodeError@.
decodeOutput :: ByteString -> Either PythonException Text
decodeOutput bytes = TE.decodeUtf8 <$> decodeText bytes

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
    Raised PythonException

-- | @json.loads(text)@ for a @str@ or @bytes@ value.
loadsJson :: PV -> JsonOutcome
loadsJson value = case loadsValue value of
  Right loaded -> Loaded loaded
  Left e
    | e.name == "JSONDecodeError" -> Malformed
    | otherwise -> Raised e

-- | @json.dumps(value)@ (unsorted, default separators).
dumpsPlain :: PV -> Either PythonException Text
dumpsPlain value = do
  json <- toJson False value
  either (Left . dumpsError) (Right . TE.decodeUtf8) (dumps defaultDumps json)
