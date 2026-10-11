-- | The Python objects the exporter handles, and the built-in operations
-- the reference applies to them with CPython 3.14's semantics and
-- exception texts.
--
-- Every value the exporter reads (a History record, a binding, a SQLite
-- row) is untrusted data of any shape, and the reference reads it with
-- plain dynamic Python: @str()@, @int()@, @.get@, @[key]@, @==@,
-- truthiness, set membership, @json.loads@ and @json.dumps@. Where the
-- reference raises, these operations raise the same exception class with
-- the same text ('PyError'), which the command line prints as the last
-- line of the reference's traceback.
module Hamsterdan.Export.Python
  ( -- * Values
    PV (..)
  , typeName
  , fromValue
  , toJson

    -- * Exceptions
  , PyError (..)
  , raise
  , raiseEither
  , typeError
  , valueError
  , keyError
  , errorLine

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
  , dumpsLine
  ) where

import Control.Exception (Exception, throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (GeneralCategory (..), chr, generalCategory, isLowerCase, isUpperCase, ord)
import Data.List (find, sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Hamsterdan.GitHub.Python qualified as Py
import Hamsterdan.PyLiteral (strRepr)
import Numeric (showHex)
import Petrus.EngineFile.PyJson (PyJsonError (..), pyLoads, renderPyJsonError)
import Petrus.EngineFile.PyText (decodeText)
import Petrus.EngineFile.Validate (PyException (..))
import Petrus.EngineFile.Value (Value (..), pyDict)
import Petrus.Json (EncodeError (..), EncodeOptions (..), Json (..), defaultDumps, dumpsText, encodeErrorMessage, pythonFloatRepr)
import Petrus.Json.Limits (intStrDigitsError, maxIntStrDigits)

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

-- | The Python object @json.loads@ builds from a parsed value (a repeated
-- member keeps its first position and takes its last value).
fromValue :: Value -> PV
fromValue = \case
  VNull -> PNone
  VBool b -> PBool b
  VInt i _ -> PInt i
  VFloat d -> PFloat d
  VStr s -> PStr s
  VList items -> PList (map fromValue items)
  VDict members -> PDict [(k, fromValue v) | (k, v) <- pyDict members]

-- | The JSON @json.dumps@ writes for a value (@sort_keys@ when the flag is
-- set), or its @TypeError@ for the first value it cannot serialize in the
-- order the encoder visits them, with the notes CPython 3.14 attaches on
-- the way out (@when serializing dict item 'key'@, @... list item 3@).
toJson :: Bool -> PV -> Either PyError Json
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
    -- The encoder writes the sorted order; the value keeps its own.
    Right (Object (if sorted then [(k, v) | (k, _) <- members, Just v <- [lookup k converted]] else converted))
  where
    noted place = either (\(PyError name text) -> Left (PyError name (text <> "\nwhen serializing " <> place))) Right

-- ---------------------------------------------------------------------------
-- Exceptions

-- | A Python exception: the class name as a traceback prints it
-- (@KeyError@, @sqlite3.OperationalError@, @json.decoder.JSONDecodeError@)
-- and @str(exception)@.
data PyError = PyError {cls :: Text, message :: Text}
  deriving stock (Eq, Show)

instance Exception PyError

raise :: PyError -> IO a
raise = throwIO

raiseEither :: Either PyError a -> IO a
raiseEither = either throwIO pure

typeError :: Text -> PyError
typeError = PyError "TypeError"

valueError :: Text -> PyError
valueError = PyError "ValueError"

-- | @KeyError(key)@, whose @str@ is the key's @repr@.
keyError :: Text -> PyError
keyError key = PyError "KeyError" (strRepr key)

-- | The last line of the traceback the reference prints for an uncaught
-- exception.
errorLine :: PyError -> Text
errorLine e = if T.null e.message then e.cls else e.cls <> ": " <> e.message

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
  PFloat d -> floatRepr d
  PStr s -> strRepr s
  PBytes b -> bytesRepr b
  PList items -> "[" <> T.intercalate ", " (map pyRepr items) <> "]"
  PDict members -> "{" <> T.intercalate ", " [strRepr k <> ": " <> pyRepr v | (k, v) <- members] <> "}"

floatRepr :: Double -> Text
floatRepr d
  | isNaN d = "nan"
  | isInfinite d = if d > 0 then "inf" else "-inf"
  | otherwise = T.pack (pythonFloatRepr d)

-- | CPython's @repr(bytes)@.
bytesRepr :: ByteString -> Text
bytesRepr bytes = "b" <> T.singleton quote <> T.concat (map escape (BS.unpack bytes)) <> T.singleton quote
  where
    quote = if BS.elem 39 bytes && not (BS.elem 34 bytes) then '"' else '\''
    escape :: Word8 -> Text
    escape w
      | w == 92 = "\\\\"
      | w == fromIntegral (ord quote) = "\\" <> T.singleton quote
      | w == 9 = "\\t"
      | w == 10 = "\\n"
      | w == 13 = "\\r"
      | w < 32 || w >= 127 = "\\x" <> T.justifyRight 2 '0' (T.pack (showHex w ""))
      | otherwise = T.singleton (chr (fromIntegral w))

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
pyInt :: PV -> Either PyError Integer
pyInt = \case
  PBool b -> Right (if b then 1 else 0)
  PInt i -> Right i
  PFloat d
    | isNaN d -> Left (valueError "cannot convert float NaN to integer")
    | isInfinite d -> Left (PyError "OverflowError" "cannot convert float infinity to integer")
    | otherwise -> Right (truncate d)
  PStr s -> intText s
  PBytes b ->
    let asText = T.pack (map (chr . fromIntegral) (BS.unpack b))
     in if BS.all (< 0x80) b
          then either (const (Left (invalidBytes b))) Right (intDigits (T.unpack (T.dropAround asciiSpace asText)))
          else Left (invalidBytes b)
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
intText :: Text -> Either PyError Integer
intText s = either (const (Left invalid)) Right (intDigits (map ascii (T.unpack (Py.strip s))))
  where
    invalid = valueError ("invalid literal for int() with base 10: " <> strRepr s)
    ascii c
      | c < '\x80' = c
      | generalCategory c == DecimalNumber = chr (ord '0' + decimalValue c)
      | otherwise = c
    -- Unicode lays decimal digits out in runs that start at zero.
    decimalValue c = run 0 c `mod` 10
    run :: Int -> Char -> Int
    run n ch = if ch > '\0' && generalCategory (pred ch) == DecimalNumber then run (n + 1) (pred ch) else n

-- | Parse an ASCII signed decimal; 'Left' with the limit error when it is
-- well formed but too long, 'Left' with an empty text when malformed.
intDigits :: String -> Either PyError Integer
intDigits input = do
  let (negative, unsigned) = case input of
        '-' : rest -> (True, rest)
        '+' : rest -> (False, rest)
        _ -> (False, input)
  digits <- groups unsigned
  if length digits > maxIntStrDigits
    then Left (valueError (T.pack (intStrDigitsError maxIntStrDigits (length digits))))
    else
      let value = foldl (\total d -> total * 10 + toInteger (ord d - ord '0')) 0 digits
       in Right (if negative then negate value else value)
  where
    malformed = Left (PyError "" "")
    isDigit c = c >= '0' && c <= '9'
    groups = \case
      [] -> malformed
      c : rest | isDigit c -> (c :) <$> after rest
      _ -> malformed
    after = \case
      [] -> Right []
      '_' : c : rest | isDigit c -> (c :) <$> after rest
      c : rest | isDigit c -> (c :) <$> after rest
      _ -> malformed

-- | @str.lower()@: full case mapping, with the final-sigma rule.
pyLower :: Text -> Text
pyLower text
  | T.all (\c -> c < '\x80') text = T.toLower text
  | otherwise = T.concat (zipWith lowerAt [0 ..] chars)
  where
    chars = T.unpack text
    count = length chars
    lowerAt :: Int -> Char -> Text
    lowerAt i c
      | c == '\x3A3' = T.singleton (if finalSigma i then '\x3C2' else '\x3C3')
      | otherwise = T.toLower (T.singleton c)
    finalSigma i =
      let before = dropWhile caseIgnorable (reverse (take i chars))
          after' = dropWhile caseIgnorable (drop (i + 1) chars)
       in case before of
            c : _
              | cased c -> i + 1 >= count || case after' of
                  [] -> True
                  d : _ -> not (cased d)
            _ -> False
    cased c = isUpperCase c || isLowerCase c || generalCategory c == TitlecaseLetter
    caseIgnorable c =
      generalCategory c `elem` [NonSpacingMark, EnclosingMark, Format, ModifierLetter, ModifierSymbol]
        || c `elem` ("'.:\xB7\x387\x55F\x5F4\x2018\x2019\x2024\x2027\xFE13\xFE52\xFE55\xFF07\xFF0E\xFF1A" :: String)

-- | Refuse an unhashable value as a set element or set probe.
hashCheck :: PV -> Either PyError ()
hashCheck = \case
  PList _ -> unhashable "list"
  PDict _ -> unhashable "dict"
  _ -> Right ()
  where
    unhashable name = Left (typeError ("cannot use '" <> name <> "' as a set element (unhashable type: '" <> name <> "')"))

-- | @value.get(key)@ on what must be a dict.
get :: Text -> PV -> Either PyError (Maybe PV)
get key = \case
  PDict members -> Right (lookup key members)
  other -> Left (PyError "AttributeError" ("'" <> typeName other <> "' object has no attribute 'get'"))

-- | @key in dict@ / @dict.get(key)@ on a dict's members.
getKey :: Text -> [(Text, PV)] -> Maybe PV
getKey = lookup

-- | @dict[key]@.
subscript :: Text -> [(Text, PV)] -> Either PyError PV
subscript key members = maybe (Left (keyError key)) Right (lookup key members)

contains :: Text -> [(Text, PV)] -> Bool
contains key members = any ((== key) . fst) members

-- | @list(value)@: the items a @for@ loop visits.
iterateValue :: PV -> Either PyError [PV]
iterateValue = \case
  PList items -> Right items
  PStr s -> Right (map (PStr . T.singleton) (T.unpack s))
  PBytes b -> Right (map (PInt . fromIntegral) (BS.unpack b))
  PDict members -> Right (map (PStr . fst) members)
  other -> Left (typeError ("'" <> typeName other <> "' object is not iterable"))

-- ---------------------------------------------------------------------------
-- JSON

-- | @json.loads(text)@ for a @str@ given as its UTF-8 bytes.
loadsText :: ByteString -> Either PyError PV
loadsText bytes = case pyLoads bytes of
  Right value -> Right (fromValue value)
  Left e@(DecodeError _) -> Left (PyError "json.decoder.JSONDecodeError" (renderPyJsonError e))
  Left e@(IntegerTooLong _) -> Left (valueError (renderPyJsonError e))
  Left e@LoneSurrogate -> Left (PyError "UnsupportedLoneSurrogate" (renderPyJsonError e))

-- | @json.loads(value)@ for any value: a @str@, @bytes@ decoded by
-- @json.detect_encoding@, or the @TypeError@ for anything else.
loadsValue :: PV -> Either PyError PV
loadsValue = \case
  PStr s -> loadsText (TE.encodeUtf8 s)
  PBytes b
    | BS.isPrefixOf "\xEF\xBB\xBF" b -> utf8 (BS.drop 3 b)
    | otherwise -> case detected b of
        Nothing -> utf8 b
        Just encoding ->
          Left
            ( PyError
                "UnsupportedJsonEncoding"
                ("json.loads would decode these bytes as " <> encoding <> ", which this implementation does not")
            )
  other -> Left (typeError ("the JSON object must be str, bytes or bytearray, not " <> typeName other))
  where
    utf8 bytes = case decodeText bytes of
      Left (PyException name text) -> Left (PyError name text)
      Right _ -> loadsText bytes
    detected bytes
      | any (`BS.isPrefixOf` bytes) ["\x00\x00\xFE\xFF", "\xFF\xFE\x00\x00"] = Just "utf-32"
      | any (`BS.isPrefixOf` bytes) ["\xFE\xFF", "\xFF\xFE"] = Just "utf-16"
      | BS.length bytes >= 4 =
          if BS.index bytes 0 == 0
            then Just (if BS.index bytes 1 /= 0 then "utf-16-be" else "utf-32-be")
            else
              if BS.index bytes 1 == 0
                then Just (if BS.index bytes 2 /= 0 || BS.index bytes 3 /= 0 then "utf-16-le" else "utf-32-le")
                else Nothing
      | BS.length bytes == 2 =
          if BS.index bytes 0 == 0 then Just "utf-16-be" else if BS.index bytes 1 == 0 then Just "utf-16-le" else Nothing
      | otherwise = Nothing

-- | @json.dumps(value, indent=2, sort_keys=True)@ (@sorted@ is
-- @sort_keys@).
dumpsIndented :: Bool -> PV -> Either PyError Text
dumpsIndented sorted value = toJson sorted value >>= encode defaultDumps {indent = Just 2, sortKeys = sorted}

-- | @json.dumps(value, sort_keys=True)@.
dumpsLine :: PV -> Either PyError Text
dumpsLine value = toJson True value >>= encode defaultDumps {sortKeys = True}

encode :: EncodeOptions -> Json -> Either PyError Text
encode options json = either (Left . refusal) Right (dumpsText options json)
  where
    refusal e = case e of
      NestingTooDeep _ -> PyError "RecursionError" (T.pack (encodeErrorMessage e))
      _ -> PyError "ValueError" (T.pack (encodeErrorMessage e))
