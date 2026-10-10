-- | A serializer that reproduces CPython's @json.dumps@ byte for byte.
--
-- Every Petrus wire format is defined by the reference implementation's
-- @json.dumps@ call (canonical Net definitions, golden traces, history
-- payload spellings, identity digests), so this module mirrors the encoder in
-- CPython's @Lib/json/encoder.py@: separators, indentation, key sorting,
-- ASCII escaping, and @float.__repr__@ number spelling.
--
-- It also applies CPython's resource limits ("Petrus.Json.Limits"): an
-- integer of more than 4300 digits is refused ('IntegerTooLarge', as
-- @int.__repr__@ refuses it), and so is a value nested deeper than
-- 'nestingLimit'.
module Petrus.Json.Encode
  ( EncodeOptions (..)
  , defaultDumps
  , indented
  , compact
  , canonicalText
  , dumps
  , dumpsBuilder
  , dumpsText
  , pythonFloatRepr
  , EncodeError (..)
  , encodeErrorMessage
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Char (intToDigit, ord)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Numeric (floatToDigits, showHex)
import Petrus.Json.Limits (defaultNestingLimit, intReprDigitsError, maxIntStrDigits)
import Petrus.Json.Value

-- | The subset of @json.dumps@ keyword arguments Petrus uses.
data EncodeOptions = EncodeOptions
  { indent :: Maybe Int
  -- ^ @indent=@; 'Nothing' writes a single line.
  , itemSeparator :: Maybe Text
  -- ^ @separators=(item, _)@; 'Nothing' uses CPython's default for the indent.
  , keySeparator :: Text
  , sortKeys :: Bool
  , ensureAscii :: Bool
  , allowNan :: Bool
  , reprDigitLimit :: Maybe Int
  -- ^ Refuse integers with more decimal digits (sign excluded) than this;
  -- CPython's default is 4300.
  , nestingLimit :: Maybe Int
  -- ^ Refuse values with more nested non-empty arrays and objects than this
  -- (CPython's encoder writes @[]@ and @{}@ without recursing).
  }
  deriving stock (Eq, Show)

-- | @json.dumps(value)@.
defaultDumps :: EncodeOptions
defaultDumps =
  EncodeOptions
    { indent = Nothing
    , itemSeparator = Nothing
    , keySeparator = ": "
    , sortKeys = False
    , ensureAscii = True
    , allowNan = True
    , reprDigitLimit = Just maxIntStrDigits
    , nestingLimit = Just defaultNestingLimit
    }

-- | @json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2)@, the
-- reference writer for Net definitions, Net documents, and golden traces.
indented :: EncodeOptions
indented = defaultDumps {indent = Just 2, ensureAscii = False, allowNan = False}

-- | @json.dumps(value, allow_nan=False, ensure_ascii=False, separators=(",", ":"))@.
compact :: EncodeOptions
compact = defaultDumps {itemSeparator = Just ",", keySeparator = ":", ensureAscii = False, allowNan = False}

-- | @json.dumps(value, allow_nan=False, ensure_ascii=False, sort_keys=True,
-- separators=(",", ":"))@: the reference's deterministic, type-sensitive
-- spelling used for conflict judgments.
canonicalText :: Json -> Either EncodeError Text
canonicalText = dumpsText compact {sortKeys = True}

-- | A value @json.dumps@ refuses.
data EncodeError
  = -- | NaN or an infinity under @allow_nan=False@.
    NonFiniteNumber Double
  | -- | An integer with more decimal digits than the limit (which it carries).
    IntegerTooLarge Int
  | -- | A value nested deeper than the limit (which it carries).
    NestingTooDeep Int
  deriving stock (Eq, Show)

-- | The text of the exception CPython raises for the same refusal (for
-- 'NestingTooDeep', a fixed-depth analogue of CPython's stack-dependent
-- @RecursionError@).
--
-- >>> encodeErrorMessage (NonFiniteNumber (-1 / 0))
-- "Out of range float values are not JSON compliant: -inf"
encodeErrorMessage :: EncodeError -> String
encodeErrorMessage = \case
  NonFiniteNumber d
    | isNaN d -> "Out of range float values are not JSON compliant: nan"
    | d > 0 -> "Out of range float values are not JSON compliant: inf"
    | otherwise -> "Out of range float values are not JSON compliant: -inf"
  IntegerTooLarge limit -> intReprDigitsError limit
  NestingTooDeep limit -> "maximum nesting depth (" ++ show limit ++ ") exceeded while encoding a JSON object"

-- | Serialize to UTF-8 bytes.
dumps :: EncodeOptions -> Json -> Either EncodeError BS.ByteString
dumps options value = BL.toStrict . B.toLazyByteString <$> dumpsBuilder options value

-- | Serialize to text.
dumpsText :: EncodeOptions -> Json -> Either EncodeError Text
dumpsText options value = TE.decodeUtf8 <$> dumps options value

-- | Serialize to a builder.
dumpsBuilder :: EncodeOptions -> Json -> Either EncodeError B.Builder
dumpsBuilder options = go 0
  where
    itemSep = case (itemSeparator options, indent options) of
      (Just separator, _) -> separator
      (Nothing, Just _) -> ","
      (Nothing, Nothing) -> ", "
    keySep = TE.encodeUtf8Builder (keySeparator options)
    itemSepB = TE.encodeUtf8Builder itemSep
    newline level = case indent options of
      Nothing -> Nothing
      Just width -> Just (B.char7 '\n' <> B.string7 (replicate (width * level) ' '))

    go :: Int -> Json -> Either EncodeError B.Builder
    go level = \case
      Null -> Right (B.string7 "null")
      Bool True -> Right (B.string7 "true")
      Bool False -> Right (B.string7 "false")
      Int i -> intB i
      Float d -> floatB d
      String s -> Right (stringB (ensureAscii options) s)
      Array [] -> Right (B.string7 "[]")
      Array items -> deeper level (container '[' ']' level (map (go (level + 1)) items))
      Object [] -> Right (B.string7 "{}")
      Object members -> deeper level $
        let ordered = if sortKeys options then sortOn fst members else members
            member (key, value) = do
              encoded <- go (level + 1) value
              Right (stringB (ensureAscii options) key <> keySep <> encoded)
         in container '{' '}' level (map member ordered)

    container open close level encodedItems = do
      items <- sequence encodedItems
      let inner = newline (level + 1)
          outer = newline level
          separator = itemSepB <> maybe mempty id inner
          body = mconcat (intersperseB separator items)
      Right (B.char7 open <> maybe mempty id inner <> body <> maybe mempty id outer <> B.char7 close)

    deeper level encoded = case nestingLimit options of
      Just limit | level >= limit -> Left (NestingTooDeep limit)
      _ -> encoded

    intB i = case reprDigitLimit options of
      Just limit | tooManyDigits limit i -> Left (IntegerTooLarge limit)
      _ -> Right (B.integerDec i)

    tooManyDigits limit i
      | limit == maxIntStrDigits = abs i >= intDigitBound
      | otherwise = abs i >= 10 ^ max 0 limit

    floatB d
      | isNaN d = nonFinite "NaN"
      | isInfinite d = nonFinite (if d > 0 then "Infinity" else "-Infinity")
      | otherwise = Right (B.string7 (pythonFloatRepr d))
      where
        nonFinite spelling
          | allowNan options = Right (B.string7 spelling)
          | otherwise = Left (NonFiniteNumber d)

intersperseB :: B.Builder -> [B.Builder] -> [B.Builder]
intersperseB _ [] = []
intersperseB separator (first : rest) = first : concatMap (\item -> [separator, item]) rest

-- | CPython's JSON string encoding (@py_encode_basestring@ /
-- @py_encode_basestring_ascii@).
stringB :: Bool -> Text -> B.Builder
stringB asciiOnly text = B.char7 '"' <> T.foldr (\c rest -> escape c <> rest) mempty text <> B.char7 '"'
  where
    escape c = case c of
      '"' -> B.string7 "\\\""
      '\\' -> B.string7 "\\\\"
      '\n' -> B.string7 "\\n"
      '\r' -> B.string7 "\\r"
      '\t' -> B.string7 "\\t"
      '\b' -> B.string7 "\\b"
      '\f' -> B.string7 "\\f"
      _
        | ord c < 0x20 -> unicodeEscape (ord c)
        | asciiOnly && ord c > 0x7e -> asciiEscape (ord c)
        | otherwise -> B.charUtf8 c
    asciiEscape n
      | n > 0xFFFF =
          let v = n - 0x10000
           in unicodeEscape (0xD800 + (v `div` 0x400)) <> unicodeEscape (0xDC00 + (v `mod` 0x400))
      | otherwise = unicodeEscape n
    unicodeEscape n = B.string7 "\\u" <> B.string7 (pad4 (showHex n ""))
    pad4 digits = replicate (4 - length digits) '0' ++ digits

-- | CPython's @float.__repr__@ for a finite double: the shortest digits that
-- round-trip, in positional form when the decimal exponent is in
-- @[-4, 16)@ and in exponent form otherwise.
pythonFloatRepr :: Double -> String
pythonFloatRepr d
  | d == 0 = if isNegativeZero d then "-0.0" else "0.0"
  | d < 0 = '-' : pythonFloatRepr (negate d)
  | otherwise =
      let (digits, decpt) = floatToDigits 10 d
          ds = map intToDigit digits
       in if decpt <= -4 || decpt > 16
            then scientific ds (decpt - 1)
            else positional ds decpt
  where
    scientific ds expo =
      let mantissa = case ds of
            [single] -> [single]
            first : rest -> first : '.' : rest
            [] -> "0"
          sign = if expo < 0 then '-' else '+'
          magnitude = show (abs expo)
       in mantissa ++ "e" ++ [sign] ++ (if length magnitude < 2 then '0' : magnitude else magnitude)
    positional ds decpt
      | decpt <= 0 = "0." ++ replicate (negate decpt) '0' ++ ds
      | decpt >= length ds = ds ++ replicate (decpt - length ds) '0' ++ ".0"
      | otherwise = let (whole, fraction) = splitAt decpt ds in whole ++ "." ++ fraction

-- | The smallest integer with more than 'maxIntStrDigits' digits.
intDigitBound :: Integer
intDigitBound = 10 ^ maxIntStrDigits
{-# NOINLINE intDigitBound #-}
