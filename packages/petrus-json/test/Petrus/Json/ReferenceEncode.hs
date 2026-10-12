-- | The @Data.ByteString.Builder@ encoder petrus-json shipped beside its
-- direct writer until the direct writer became the only one (the builder
-- could not keep up with CPython's C encoder; bench/RESULTS.md, "The direct
-- writer"), kept as a test oracle: the property tests in @test/Main.hs@
-- require 'Petrus.Json.dumps' to spell the same bytes and refuse the same
-- first value under every option set.
module Petrus.Json.ReferenceEncode (referenceDumps, referenceDumpsBytes, floatReprBuilder) where

import Control.Exception (Exception, evaluate, throw, try)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Builder.Prim qualified as BP
import Data.ByteString.Builder.Prim.Internal (boundedPrim)
import Data.ByteString.Lazy qualified as BL
import Data.Char (ord)
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Num (Integer (IS))
import Numeric (showHex)
import Petrus.Json.Encode (EncodeError (..), EncodeOptions (..))
import Petrus.Json.Float (maxFloatReprLength, writeFloatRepr)
import Petrus.Json.Limits (maxIntStrDigits)
import Petrus.Json.Value
import System.IO.Unsafe (unsafePerformIO)

-- | 'referenceDumps' run to bytes, with the writer's refusals caught.
referenceDumpsBytes :: EncodeOptions -> Json -> Either EncodeError BS.ByteString
referenceDumpsBytes options value = case referenceDumps options value of
  Left problem -> Left problem
  Right builder ->
    unsafePerformIO $
      either (\(Refused problem) -> Left problem) Right
        <$> try (evaluate (BL.toStrict (B.toLazyByteString builder)))

-- | A refusal met by the writer.
newtype Refused = Refused EncodeError
  deriving stock (Show)

instance Exception Refused

-- | CPython's @float.__repr__@ as a builder.
floatReprBuilder :: Double -> B.Builder
floatReprBuilder = BP.primBounded (boundedPrim maxFloatReprLength writeFloatRepr)

-- | Serialize to a builder.
--
-- A lazy builder cannot take back what it has written, so refusals are
-- decided up front here: a cheap scan in document order settles the common
-- case, and only a refused value pays for the search in writer order (which
-- sorts keys under 'sortKeys').
referenceDumps :: EncodeOptions -> Json -> Either EncodeError B.Builder
referenceDumps options value
  | checked options, not (clean 0 value), Just problem <- firstProblem options 0 value = Left problem
  | otherwise = Right (writer options value)
  where
    clean :: Int -> Json -> Bool
    clean level = \case
      Float d -> allowNan options || not (isNaN d || isInfinite d)
      Int i -> maybe True (\limit -> not (tooManyDigits limit i)) (reprDigitLimit options)
      Array items@(_ : _) -> shallow level && all (clean (level + 1)) items
      Object members@(_ : _) -> shallow level && all (clean (level + 1) . snd) members
      _ -> True
    shallow level = maybe True (level <) (nestingLimit options)

-- | The first value the options refuse, in writer order: a container before
-- its items, keys sorted under 'sortKeys'.
firstProblem :: EncodeOptions -> Int -> Json -> Maybe EncodeError
firstProblem options = search
  where
    search level = \case
      Float d | not (allowNan options), isNaN d || isInfinite d -> Just (NonFiniteNumber d)
      Int i | Just limit <- reprDigitLimit options, tooManyDigits limit i -> Just (IntegerTooLarge limit)
      Array items@(_ : _) -> deeper level (firstJust (map (search (level + 1)) items))
      Object members@(_ : _) -> deeper level (firstJust (map (search (level + 1) . snd) (ordered options members)))
      _ -> Nothing
    deeper level rest = case nestingLimit options of
      Just limit | level >= limit -> Just (NestingTooDeep limit)
      _ -> rest
    firstJust = \case
      [] -> Nothing
      Just problem : _ -> Just problem
      Nothing : rest -> firstJust rest

-- | Whether the options refuse anything at all.
checked :: EncodeOptions -> Bool
checked options = not (allowNan options) || hasLimit (reprDigitLimit options) || hasLimit (nestingLimit options)
  where
    hasLimit = maybe False (const True)

-- | Whether an integer has more decimal digits than the limit.
tooManyDigits :: Int -> Integer -> Bool
tooManyDigits limit i
  | IS _ <- i, limit >= 19 = False
  | limit == maxIntStrDigits = abs i >= intDigitBound
  | otherwise = abs i >= 10 ^ max 0 limit

ordered :: EncodeOptions -> [(Text, Json)] -> [(Text, Json)]
ordered options members = if sortKeys options then sortBy (comparing fst) members else members

-- | The writer: a plain 'B.Builder' fold with no 'Either' threaded through
-- it. It throws 'Refused' (caught by 'referenceDumpsBytes') at the first value the
-- options refuse, in writer order: a container before its items, keys
-- sorted under 'sortKeys'.
writer :: EncodeOptions -> Json -> B.Builder
writer options = go 0
  where
    refuse = throw . Refused
    digitLimit = reprDigitLimit options
    depthLimit = nestingLimit options
    enter level = case depthLimit of
      Just limit | level >= limit -> refuse (NestingTooDeep limit)
      _ -> ()
    itemSep = case (itemSeparator options, indent options) of
      (Just separator, _) -> separator
      (Nothing, Just _) -> ","
      (Nothing, Nothing) -> ", "
    keySep = TE.encodeUtf8Builder (keySeparator options)
    itemSepB = TE.encodeUtf8Builder itemSep
    newline level = case indent options of
      Nothing -> mempty
      Just width -> B.char7 '\n' <> B.string7 (replicate (width * level) ' ')
    string = stringB (ensureAscii options)

    go :: Int -> Json -> B.Builder
    go level = \case
      Null -> B.string7 "null"
      Bool True -> B.string7 "true"
      Bool False -> B.string7 "false"
      Int i
        | Just limit <- digitLimit, tooManyDigits limit i -> refuse (IntegerTooLarge limit)
        | otherwise -> B.integerDec i
      Float d
        | not (allowNan options), isNaN d || isInfinite d -> refuse (NonFiniteNumber d)
        | otherwise -> floatB d
      String s -> string s
      Array [] -> B.string7 "[]"
      Array items -> enter level `seq` container '[' ']' level (go (level + 1)) items
      Object [] -> B.string7 "{}"
      Object members ->
        let member (key, v) = string key <> keySep <> go (level + 1) v
         in enter level `seq` container '{' '}' level member (ordered options members)

    container :: Char -> Char -> Int -> (a -> B.Builder) -> [a] -> B.Builder
    container open close level item items =
      let inner = newline (level + 1)
          separator = itemSepB <> inner
          body = case items of
            [] -> mempty
            first : rest -> item first <> foldr (\next more -> separator <> item next <> more) mempty rest
       in B.char7 open <> inner <> body <> newline level <> B.char7 close

    -- Non-finite values reach here only when 'allowNan' admits them.
    floatB d
      | isNaN d = B.string7 "NaN"
      | isInfinite d = B.string7 (if d > 0 then "Infinity" else "-Infinity")
      | otherwise = floatReprBuilder d

-- | CPython's JSON string encoding (@py_encode_basestring@ /
-- @py_encode_basestring_ascii@).
stringB :: Bool -> Text -> B.Builder
stringB asciiOnly text = B.char7 '"' <> chunks text <> B.char7 '"'
  where
    -- Runs of characters that need no escape are copied as one UTF-8 slice;
    -- only the characters between runs go through 'escape'. The output is
    -- the same as escaping character by character, several times faster.
    plain c = c >= ' ' && c /= '"' && c /= '\\' && (not asciiOnly || c <= '~')
    chunks t
      | T.null t = mempty
      | otherwise =
          let (run, rest) = T.span plain t
           in TE.encodeUtf8Builder run <> case T.uncons rest of
                Nothing -> mempty
                Just (c, rest') -> escape c <> chunks rest'
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

-- | The smallest integer with more than 'maxIntStrDigits' digits.
intDigitBound :: Integer
intDigitBound = 10 ^ maxIntStrDigits
{-# NOINLINE intDigitBound #-}
