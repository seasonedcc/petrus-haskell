-- | The few CPython semantics the GitHub boundary depends on.
--
-- Hamsterdan inspects provider JSON with @dict.get@, truthiness, @str()@,
-- @str.strip()@, @str.casefold()@, @isprintable()@ and friends. These
-- functions spell those operations over 'Json' and 'Text' so the ports read
-- like the reference and decide exactly as it does.
module Hamsterdan.GitHub.Python
  ( -- * Failures CPython would raise
    PyFailure (..)
  , PyClass (..)
  , pyClassName
  , PythonFault (..)

    -- * Provider JSON
  , get
  , getOr
  , orEmpty
  , truthy
  , isDict
  , isList
  , isStr
  , isInt
  , isBool
  , str
  , intOf
  , subscript
  , iterate'
  , pyEqText
  , hashable
  , loadsBytes
  , providerLoads
  , JsonLoadError (..)

    -- * Text
  , isSpace
  , strip
  , lstrip
  , casefold
  , upper
  , isAscii
  , isPrintable
  , isAsciiDecimal
  , utf8Length
  , pyIntBase
  , canonicalUuid
  ) where

import Control.Exception (SomeException, evaluate, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Hamsterdan.PyLiteral (fromJson, repr)
import Hamsterdan.PyText
import Petrus.Json (Json (..), ParseOptions, parseJson, pythonFloatRepr, pythonLoads)
import System.IO.Unsafe (unsafePerformIO)

-- | The CPython exception classes the reference's provider inspection can
-- raise.
data PyClass
  = TypeError
  | KeyError
  | ValueError
  | AttributeError
  | OverflowError
  | IndexError
  deriving stock (Eq, Show)

pyClassName :: PyClass -> Text
pyClassName = T.pack . show

-- | A CPython exception: its class and a short description.
data PyFailure = PyFailure PyClass Text
  deriving stock (Eq, Show)

-- | @value.get(key)@: 'Null' when absent; an 'AttributeError' when the value
-- is not a dict.
get :: Text -> Json -> Either PyFailure Json
get key = \case
  Object members -> Right (maybe Null id (lookup key members))
  other -> Left (PyFailure AttributeError ("'" <> typeName other <> "' object has no attribute 'get'"))

-- | @value.get(key, default)@.
getOr :: Text -> Json -> Json -> Either PyFailure Json
getOr key fallback = \case
  Object members -> Right (maybe fallback id (lookup key members))
  other -> Left (PyFailure AttributeError ("'" <> typeName other <> "' object has no attribute 'get'"))

-- | @value or {}@.
orEmpty :: Json -> Json
orEmpty value = if truthy value then value else Object []

-- | Python truthiness.
truthy :: Json -> Bool
truthy = \case
  Null -> False
  Bool b -> b
  Int i -> i /= 0
  Float d -> d /= 0
  String s -> not (T.null s)
  Array items -> not (null items)
  Object members -> not (null members)

isDict, isList, isStr, isInt, isBool :: Json -> Bool
isDict = \case Object _ -> True; _ -> False
isList = \case Array _ -> True; _ -> False
isStr = \case String _ -> True; _ -> False
-- | @type(value) is int@ (booleans excluded).
isInt = \case Int _ -> True; _ -> False
isBool = \case Bool _ -> True; _ -> False

-- | @str(value)@.
str :: Json -> Text
str = \case
  String s -> s
  Null -> "None"
  Bool True -> "True"
  Bool False -> "False"
  Int i -> T.pack (show i)
  Float d
    | isNaN d -> "nan"
    | isInfinite d -> if d > 0 then "inf" else "-inf"
    | otherwise -> T.pack (pythonFloatRepr d)
  other -> repr (fromJson other)

-- | @int(value)@.
intOf :: Json -> Either PyFailure Integer
intOf = \case
  Int i -> Right i
  Bool b -> Right (if b then 1 else 0)
  Float d
    | isNaN d -> Left (PyFailure ValueError "cannot convert float NaN to integer")
    | isInfinite d -> Left (PyFailure OverflowError "cannot convert float infinity to integer")
    | otherwise -> Right (truncate d)
  String s -> maybe (Left (PyFailure ValueError "invalid literal for int() with base 10")) Right (pyIntBase 10 s)
  other -> Left (PyFailure TypeError ("int() argument must be a string, a bytes-like object or a real number, not '" <> typeName other <> "'"))

-- | @value[index]@ for a non-negative integer index.
subscript :: Int -> Json -> Either PyFailure Json
subscript index = \case
  Array items -> case drop index items of
    item : _ -> Right item
    [] -> Left (PyFailure IndexError "list index out of range")
  String s -> case T.uncons (T.drop index s) of
    Just (c, _) -> Right (String (T.singleton c))
    Nothing -> Left (PyFailure IndexError "string index out of range")
  Object _ -> Left (PyFailure KeyError (T.pack (show index)))
  other -> Left (PyFailure TypeError ("'" <> typeName other <> "' object is not subscriptable"))

-- | @for item in value@.
iterate' :: Json -> Either PyFailure [Json]
iterate' = \case
  Array items -> Right items
  String s -> Right (map (String . T.singleton) (T.unpack s))
  Object members -> Right (map (String . fst) members)
  other -> Left (PyFailure TypeError ("'" <> typeName other <> "' object is not iterable"))

-- | @value == "text"@.
pyEqText :: Json -> Text -> Bool
pyEqText value text = case value of
  String s -> s == text
  _ -> False

-- | Whether CPython can hash the value (lists and dicts cannot).
hashable :: Json -> Bool
hashable = \case
  Array _ -> False
  Object _ -> False
  _ -> True

typeName :: Json -> Text
typeName = \case
  Null -> "NoneType"
  Bool _ -> "bool"
  Int _ -> "int"
  Float _ -> "float"
  String _ -> "str"
  Array _ -> "list"
  Object _ -> "dict"

-- | Why @json.loads(bytes)@ refused a document.
data JsonLoadError
  = -- | @UnicodeDecodeError@.
    UndecodableText
  | -- | @json.JSONDecodeError@.
    MalformedJson String
  | -- | @ValueError@ from an integer longer than 4300 digits.
    IntegerTooLong
  deriving stock (Eq, Show)

-- | The options every provider document (webhook payloads, and the
-- observations the inbox stores from them) is parsed with: CPython's
-- @json.loads@.
--
-- CPython keeps a lone surrogate escape (@"\\ud800"@) in a @str@. Once
-- petrus-json can keep one too (as a WTF-8 'Text', audit IMP-2), setting
-- its @loneSurrogates = KeepLoneSurrogates@ here is the one change the
-- provider path needs: the comment-body bound and every SQLite bind
-- already raise CPython's @UnicodeEncodeError@ on such a 'Text'
-- ('Hamsterdan.PyText.utf8EncodeError'), and the stored observation is
-- written with @ensure_ascii@, which escapes it again. Until then such
-- documents are refused as 'MalformedJson' (see DIVERGENCES.md).
providerLoads :: ParseOptions
providerLoads = pythonLoads

-- | @json.loads(raw)@ for bytes: detect UTF-8, UTF-16 or UTF-32 as CPython
-- does, decode, and parse with CPython's defaults (including the 4300-digit
-- integer limit), as 'providerLoads'.
loadsBytes :: ByteString -> Either JsonLoadError Json
loadsBytes raw = do
  utf8 <- case detectEncoding raw of
    Utf8 -> valid raw
    Utf8Sig -> valid (BS.drop 3 raw)
    Other decode -> maybe (Left UndecodableText) (Right . TE.encodeUtf8) (decodeStrictly decode raw)
  value <- either (Left . MalformedJson) Right (parseJson providerLoads utf8)
  if tooLong value then Left IntegerTooLong else Right value
  where
    valid bytes = either (const (Left UndecodableText)) (const (Right bytes)) (TE.decodeUtf8' bytes)
    tooLong = \case
      Int i -> abs i >= 10 ^ (4300 :: Int)
      Array items -> any tooLong items
      Object members -> any (tooLong . snd) members
      _ -> False

data Encoding = Utf8 | Utf8Sig | Other (TEE.OnDecodeError -> ByteString -> Text)

-- | @json.detect_encoding@.
detectEncoding :: ByteString -> Encoding
detectEncoding b
  | prefix [0x00, 0x00, 0xFE, 0xFF] = Other utf32be
  | prefix [0xFF, 0xFE, 0x00, 0x00] = Other (\h -> utf32le h . BS.drop 4)
  | prefix [0xFE, 0xFF] = Other (\h -> TE.decodeUtf16BEWith h . BS.drop 2)
  | prefix [0xFF, 0xFE] = Other (\h -> TE.decodeUtf16LEWith h . BS.drop 2)
  | prefix [0xEF, 0xBB, 0xBF] = Utf8Sig
  | BS.length b >= 4 =
      if
        | BS.index b 0 == 0 -> if BS.index b 1 /= 0 then Other TE.decodeUtf16BEWith else Other utf32be
        | BS.index b 1 == 0 -> if BS.index b 2 /= 0 || BS.index b 3 /= 0 then Other TE.decodeUtf16LEWith else Other utf32le
        | otherwise -> Utf8
  | BS.length b == 2 =
      if
        | BS.index b 0 == 0 -> Other TE.decodeUtf16BEWith
        | BS.index b 1 == 0 -> Other TE.decodeUtf16LEWith
        | otherwise -> Utf8
  | otherwise = Utf8
  where
    prefix bytes = BS.pack bytes `BS.isPrefixOf` b
    -- The "utf-32" codec with a big-endian BOM drops it.
    utf32be h bytes = TE.decodeUtf32BEWith h (if BS.pack [0x00, 0x00, 0xFE, 0xFF] `BS.isPrefixOf` bytes then BS.drop 4 bytes else bytes)
    utf32le = TE.decodeUtf32LEWith

decodeStrictly :: (TEE.OnDecodeError -> ByteString -> Text) -> ByteString -> Maybe Text
decodeStrictly decode bytes = unsafePerformIO $ do
  result <- try (evaluate (let text = decode TEE.strictDecode bytes in T.length text `seq` text))
  pure $ case result of
    Left (_ :: SomeException) -> Nothing
    Right text -> Just text
{-# NOINLINE decodeStrictly #-}
