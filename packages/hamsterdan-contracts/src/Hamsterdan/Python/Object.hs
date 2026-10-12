{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The Python objects the exporter handles, and the built-in operations
-- the reference applies to them with CPython 3.14's semantics and
-- exception texts.
--
-- Every value the exporter reads (a History record, a binding, a SQLite
-- row) is untrusted data of any shape, and the reference reads it with
-- plain dynamic Python: @str()@, @int()@, @.get@, @[key]@, @==@,
-- truthiness, set membership, @json.loads@ and @json.dumps@. Where the
-- reference raises, these operations raise the same exception (a
-- 'PythonException' with the same class and @str()@), which the command
-- line prints as the last line of the reference's traceback ('errorLine').
--
-- The exporter and the operator both read untrusted values this way; the
-- model lives here, beside the rest of the CPython layer, so neither
-- depends on the other for it.
module Hamsterdan.Python.Object
  ( -- * Values
    PV (..)
  , typeName
  , fromJson
  , forceValue
  , toJson

    -- * Exceptions
  , PythonException (..)
  , pythonError
  , raise
  , raiseEither
  , typeError
  , valueError
  , keyError
  , errorLine
  , tracebackName

    -- * Built-ins
  , pyStr
  , pyRepr
  , bytesRepr
  , truthy
  , pyEq
  , pyInt
  , intText
  , pyLower
  , hashCheck
  , get
  , getKey
  , subscript
  , contains
  , iterateValue

    -- * JSON
  , loadsText
  , loadsValue
  , dumpsIndented
  , dumpsIndentedBytes
  , dumpsLine
  ) where

import Control.Exception (throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (find, sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Bifunctor (first)
import Data.Text.Encoding qualified as TE
import Hamsterdan.Python.Exception (PythonException (..), dumpsError, keyError, pythonError, pythonExceptionStr)
import Hamsterdan.Python.Text (strRepr)
import Hamsterdan.Python.Text qualified as Py
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumps)
import Petrus.Json.Python (loadsUtf8, pythonBytesRepr, pythonDoubleRepr)
import Petrus.Json.Python qualified as Python

-- ---------------------------------------------------------------------------
-- Values

-- | A Python object as the exporter meets it: what @json.loads@ builds and
-- what @sqlite3@ returns for a column. Dictionary keys are always @str@
-- (JSON object members and column names).
data PV
  = PNone
  | PBool Bool
  | PInt Integer
  | PFloat Double
  | PStr Text
  | PBytes ByteString
  | PList [PV]
  | PDict [(Text, PV)]
  deriving stock (Show)

-- | @type(value).__name__@.
typeName :: PV -> Text
typeName = \case
  PNone -> "NoneType"
  PBool _ -> "bool"
  PInt _ -> "int"
  PFloat _ -> "float"
  PStr _ -> "str"
  PBytes _ -> "bytes"
  PList _ -> "list"
  PDict _ -> "dict"

-- | The Python object @json.loads@ builds (a repeated member keeps its
-- first position and takes its last value: the parser has settled that).
fromJson :: Json -> PV
fromJson = \case
  Null -> PNone
  Bool b -> PBool b
  Int i -> PInt i
  Float d -> PFloat d
  String s -> PStr s
  Array items -> PList (map fromJson items)
  Object members -> PDict [(k, fromJson v) | (k, v) <- members]

-- | Evaluate a value completely.
forceValue :: PV -> ()
forceValue = \case
  PNone -> ()
  PBool b -> b `seq` ()
  PInt i -> i `seq` ()
  PFloat d -> d `seq` ()
  PStr s -> s `seq` ()
  PBytes b -> b `seq` ()
  PList items -> foldr (\v acc -> forceValue v `seq` acc) () items
  PDict members -> foldr (\(k, v) acc -> k `seq` forceValue v `seq` acc) () members

-- | The JSON @json.dumps@ writes for a value (@sort_keys@ when the flag is
-- set), or its @TypeError@ for the first value it cannot serialize in the
-- order the encoder visits them, with the notes CPython 3.14 attaches on
-- the way out (@when serializing dict item 'key'@, @... list item 3@).
toJson :: Bool -> PV -> Either PythonException Json
toJson sorted = \case
  PNone -> Right Null
  PBool b -> Right (Bool b)
  PInt i -> Right (Int i)
  PFloat d -> Right (Float d)
  PStr s -> Right (String s)
  PBytes _ -> Left (typeError "Object of type bytes is not JSON serializable")
  PList items -> Array <$> traverse (\(i, v) -> noted ("list item " <> T.pack (show i)) (toJson sorted v)) (zip [0 :: Int ..] items)
  PDict members -> do
    let visited = if sorted then sortOn fst members else members
    converted <- traverse (\(k, v) -> (k,) <$> noted ("dict item " <> strRepr k) (toJson sorted v)) visited
    -- Sorted or not, the members are in the order the encoder writes them.
    Right (Object converted)
  where
    -- CPython 3.14 attaches the place as a note, which the traceback
    -- prints on the lines after @str(error)@; it is carried there.
    noted place = first (\e -> pythonError e.name (pythonExceptionStr e <> "\nwhen serializing " <> place))

-- ---------------------------------------------------------------------------
-- Exceptions

-- | @raise error@.
raise :: PythonException -> IO a
raise = throwIO

raiseEither :: Either PythonException a -> IO a
raiseEither = either throwIO pure

typeError :: Text -> PythonException
typeError = pythonError "TypeError"

valueError :: Text -> PythonException
valueError = pythonError "ValueError"

-- | The class as a traceback qualifies it: the classes the exporter and
-- the operator raise from outside @builtins@ (@json.decoder@,
-- @sqlite3@, @shutil@, @subprocess@) by their module, a built-in by its
-- name.
tracebackName :: Text -> Text
tracebackName name = maybe name (<> ("." <> name)) (lookup name modules)
  where
    modules =
      [("JSONDecodeError", "json.decoder"), ("SameFileError", "shutil"), ("SpecialFileError", "shutil"), ("TimeoutExpired", "subprocess")]
        <> [(cls, "sqlite3") | cls <- ["DatabaseError", "DataError", "IntegrityError", "InterfaceError", "InternalError", "NotSupportedError", "OperationalError", "ProgrammingError"]]

-- | The last line of the traceback the reference prints for an uncaught
-- exception: the qualified class, then @str(error)@ when it is not empty.
errorLine :: PythonException -> Text
errorLine e
  | T.null message = tracebackName e.name
  | otherwise = tracebackName e.name <> ": " <> message
  where
    message = pythonExceptionStr e

-- ---------------------------------------------------------------------------
-- Built-ins

-- | @str(value)@.
pyStr :: PV -> Text
pyStr = \case
  PStr s -> s
  other -> pyRepr other

-- | @repr(value)@.
pyRepr :: PV -> Text
pyRepr = \case
  PNone -> "None"
  PBool True -> "True"
  PBool False -> "False"
  PInt i -> T.pack (show i)
  PFloat d -> pythonDoubleRepr d
  PStr s -> strRepr s
  PBytes b -> bytesRepr b
  PList items -> "[" <> T.intercalate ", " (map pyRepr items) <> "]"
  PDict members -> "{" <> T.intercalate ", " [strRepr k <> ": " <> pyRepr v | (k, v) <- members] <> "}"

-- | CPython's @repr(bytes)@.
bytesRepr :: ByteString -> Text
bytesRepr = pythonBytesRepr

-- | @bool(value)@.
truthy :: PV -> Bool
truthy = \case
  PNone -> False
  PBool b -> b
  PInt i -> i /= 0
  PFloat d -> d /= 0
  PStr s -> not (T.null s)
  PBytes b -> not (BS.null b)
  PList items -> not (null items)
  PDict members -> not (null members)

-- | @left == right@: numbers compare by value across @bool@, @int@ and
-- @float@; NaN equals nothing.
pyEq :: PV -> PV -> Bool
pyEq left right = case (numeric left, numeric right) of
  (Just a, Just b) -> a `numEq` b
  (Just _, Nothing) -> False
  (Nothing, Just _) -> False
  (Nothing, Nothing) -> case (left, right) of
    (PNone, PNone) -> True
    (PStr a, PStr b) -> a == b
    (PBytes a, PBytes b) -> a == b
    (PList as, PList bs) -> length as == length bs && and (zipWith pyEq as bs)
    (PDict as, PDict bs) ->
      length as == length bs && all (\(k, v) -> maybe False (pyEq v . snd) (find ((== k) . fst) bs)) as
    _ -> False
  where
    numeric = \case
      PBool b -> Just (Left (if b then 1 else 0))
      PInt i -> Just (Left i)
      PFloat d -> Just (Right d)
      _ -> Nothing
    numEq (Left a) (Left b) = a == b
    numEq (Right a) (Right b) = a == b
    numEq (Left a) (Right b) = intFloatEq a b
    numEq (Right a) (Left b) = intFloatEq b a
    intFloatEq i d = not (isNaN d || isInfinite d) && toRational d == fromInteger i

-- | @int(value)@.
pyInt :: PV -> Either PythonException Integer
pyInt = \case
  PBool b -> Right (if b then 1 else 0)
  PInt i -> Right i
  PFloat d
    | isNaN d -> Left (valueError "cannot convert float NaN to integer")
    | isInfinite d -> Left (pythonError "OverflowError" "cannot convert float infinity to integer")
    | otherwise -> Right (truncate d)
  PStr s -> intText s
  -- @bytes@ strip ASCII whitespace only, and hold ASCII digits only.
  PBytes b
    | BS.all (< 0x80) b
    , let digits = T.dropAround asciiSpace (TE.decodeLatin1 b)
    , not (T.any Py.isSpace digits)
    , Just _ <- Py.pyIntBase 10 digits ->
        intText digits
    | otherwise -> Left (invalidBytes b)
  other ->
    Left
      ( typeError
          ("int() argument must be a string, a bytes-like object or a real number, not " <> strRepr (typeName other))
      )
  where
    invalidBytes b = valueError ("invalid literal for int() with base 10: " <> bytesRepr b)
    asciiSpace c = c == ' ' || (c >= '\t' && c <= '\r')

-- | @int(text)@ for a @str@: surrounding whitespace, a sign, Unicode
-- decimal digits, single underscores between digits, and the 4300-digit
-- conversion limit.
intText :: Text -> Either PythonException Integer
intText = Py.intText

-- | @str.lower()@: full case mapping, with the final-sigma rule (CPython
-- 3.14's tables, petrus-json's 'Py.lower').
pyLower :: Text -> Text
pyLower = Py.lower

-- | Refuse an unhashable value as a set element or set probe.
hashCheck :: PV -> Either PythonException ()
hashCheck = \case
  PList _ -> unhashable "list"
  PDict _ -> unhashable "dict"
  _ -> Right ()
  where
    unhashable name = Left (typeError ("cannot use '" <> name <> "' as a set element (unhashable type: '" <> name <> "')"))

-- | @value.get(key)@ on what must be a dict.
get :: Text -> PV -> Either PythonException (Maybe PV)
get key = \case
  PDict members -> Right (lookup key members)
  other -> Left (pythonError "AttributeError" ("'" <> typeName other <> "' object has no attribute 'get'"))

-- | @key in dict@ / @dict.get(key)@ on a dict's members.
getKey :: Text -> [(Text, PV)] -> Maybe PV
getKey = lookup

-- | @dict[key]@.
subscript :: Text -> [(Text, PV)] -> Either PythonException PV
subscript key members = maybe (Left (keyError key)) Right (lookup key members)

contains :: Text -> [(Text, PV)] -> Bool
contains key members = any ((== key) . fst) members

-- | @list(value)@: the items a @for@ loop visits.
iterateValue :: PV -> Either PythonException [PV]
iterateValue = \case
  PList items -> Right items
  PStr s -> Right (map (PStr . T.singleton) (T.unpack s))
  PBytes b -> Right (map (PInt . fromIntegral) (BS.unpack b))
  PDict members -> Right (map (PStr . fst) members)
  other -> Left (typeError ("'" <> typeName other <> "' object is not iterable"))

-- ---------------------------------------------------------------------------
-- JSON

-- | @json.loads(text)@ for a @str@ given as its UTF-8 bytes.
loadsText :: ByteString -> Either PythonException PV
loadsText = loaded . loadsUtf8

-- | @json.loads(value)@ for any value: a @str@, @bytes@ decoded by
-- @json.detect_encoding@ (UTF-8, UTF-16 or UTF-32, with @surrogatepass@),
-- or the @TypeError@ for anything else.
loadsValue :: PV -> Either PythonException PV
loadsValue = \case
  PStr s -> loaded (Python.loadsText s)
  PBytes b -> loaded (Python.loadsBytes b)
  other -> Left (typeError ("the JSON object must be str, bytes or bytearray, not " <> typeName other))

-- | The object, or the exception. A lone surrogate stays in its @str@
-- (WTF-8, "Petrus.Json.Wtf8"), as in CPython.
loaded :: Either PythonException Json -> Either PythonException PV
loaded = fmap fromJson

-- | @json.dumps(value, indent=2, sort_keys=True)@ (@sorted@ is
-- @sort_keys@).
dumpsIndented :: Bool -> PV -> Either PythonException Text
dumpsIndented sorted value = TE.decodeUtf8 <$> dumpsIndentedBytes sorted value

-- | 'dumpsIndented', as its UTF-8 bytes.
dumpsIndentedBytes :: Bool -> PV -> Either PythonException ByteString
dumpsIndentedBytes sorted value = toJson sorted value >>= encode defaultDumps {indent = Just 2, sortKeys = sorted}

-- | @json.dumps(value, sort_keys=True)@.
dumpsLine :: PV -> Either PythonException ByteString
dumpsLine value = toJson True value >>= encode defaultDumps {sortKeys = True}

encode :: EncodeOptions -> Json -> Either PythonException ByteString
encode options json = first dumpsError (dumps options json)
