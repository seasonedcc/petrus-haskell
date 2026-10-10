{-# LANGUAGE BangPatterns #-}

-- | The parser behind the formatter and in-memory sources: CPython 3.14's
-- @json.loads@ on a @str@ (the C scanner in @Modules/_json.c@ and the
-- wrapper in @Lib/json/decoder.py@).
--
-- It accepts and refuses the same documents with the same
-- @JSONDecodeError@ message and position (in code points), and builds the
-- same Python objects: a repeated key keeps its first position and takes
-- its last value, integers are unbounded (but limited to 4300 digits, as
-- @int()@ is), and @NaN@, @Infinity@ and @-Infinity@ are floats.
--
-- One divergence (see DIVERGENCES.md): CPython builds a @str@ holding a
-- lone surrogate from an unpaired @\\uD800@-style escape, which 'Text'
-- cannot hold; such a document is refused with 'LoneSurrogate' once it has
-- otherwise parsed.
module Petrus.EngineFile.PyJson
  ( PyJsonError (..)
  , pyLoads
  , renderPyJsonError
  , pyJsonErrorClass
  ) where

import Control.Exception (Exception, evaluate, throw, try)
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Unsafe qualified as BU
import Data.Char (chr)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Petrus.EngineFile.Number (decimalToDouble)
import Petrus.EngineFile.Value (Value (..))
import Petrus.Json.Limits (intStrDigitsError, maxIntStrDigits)
import System.IO.Unsafe (unsafeDupablePerformIO)

-- | Why @json.loads@ refused a document.
data PyJsonError
  = -- | @JSONDecodeError(msg, doc, pos)@ with @pos@ a code point offset,
    -- already rendered as @"msg: line L column C (char P)"@.
    DecodeError Text
  | -- | @ValueError@ from @int()@ on an integer of too many digits.
    IntegerTooLong Int
  | -- | A lone surrogate in a string (a divergence; see the module notes).
    LoneSurrogate
  deriving stock (Eq, Show)

-- | The exception class the reference raises.
pyJsonErrorClass :: PyJsonError -> Text
pyJsonErrorClass = \case
  DecodeError _ -> "JSONDecodeError"
  IntegerTooLong _ -> "ValueError"
  LoneSurrogate -> "UnsupportedLoneSurrogate"

-- | @str(exception)@.
renderPyJsonError :: PyJsonError -> Text
renderPyJsonError = \case
  DecodeError text -> text
  IntegerTooLong digits -> T.pack (intStrDigitsError maxIntStrDigits digits)
  LoneSurrogate -> "a string holds a lone surrogate, which this implementation cannot represent"

data Failure = Failure Text Int | TooLong Int
  deriving stock (Show)

instance Exception Failure

-- | @json.loads(text)@ for UTF-8 encoded text.
pyLoads :: ByteString -> Either PyJsonError Value
pyLoads input
  | BS.isPrefixOf "\xEF\xBB\xBF" input = Left (decodeError input "Unexpected UTF-8 BOM (decode using utf-8-sig)" 0)
  | otherwise = case unsafeDupablePerformIO (try (evaluate (document input))) of
      Right (R v _ lone) -> if lone then Left LoneSurrogate else Right v
      Left (Failure msg offset) -> Left (decodeError input msg offset)
      Left (TooLong digits) -> Left (IntegerTooLong digits)

decodeError :: ByteString -> Text -> Int -> PyJsonError
decodeError input msg offset =
  let prefix = BS.take offset input
      pos = charCount prefix
      line = BS.count 10 prefix + 1
      column = case BS.elemIndexEnd 10 prefix of
        Nothing -> pos + 1
        Just nl -> pos - charCount (BS.take nl prefix)
   in DecodeError (msg <> ": line " <> tshow line <> " column " <> tshow column <> " (char " <> tshow pos <> ")")
  where
    tshow = T.pack . show
    charCount = BS.foldl' (\n w -> if w >= 0x80 && w < 0xC0 then n else n + 1) 0

data R = R !Value {-# UNPACK #-} !Int !Bool

failAt :: Text -> Int -> a
failAt msg offset = throw (Failure msg offset)

isWs :: Word8 -> Bool
isWs b = b == 32 || b == 9 || b == 10 || b == 13
{-# INLINE isWs #-}

skipWs :: ByteString -> Int -> Int
skipWs input = go
  where
    len = BS.length input
    go !i = if i < len && isWs (BU.unsafeIndex input i) then go (i + 1) else i

byteAt :: ByteString -> Int -> Maybe Word8
byteAt input i
  | i >= 0 && i < BS.length input = Just (BU.unsafeIndex input i)
  | otherwise = Nothing
{-# INLINE byteAt #-}

document :: ByteString -> R
document input = case scanOnce input (skipWs input 0) of
  R v end lone ->
    let end' = skipWs input end
     in if end' /= BS.length input then failAt "Extra data" end' else R v end' lone

expectingValue :: Int -> a
expectingValue = failAt "Expecting value"

matches :: ByteString -> Int -> ByteString -> Bool
matches input at literal = BS.take (BS.length literal) (BS.drop at input) == literal

scanOnce :: ByteString -> Int -> R
scanOnce input idx = case byteAt input idx of
  Nothing -> expectingValue idx
  Just c -> case c of
    34 -> scanString input (idx + 1)
    123 -> object input (idx + 1)
    91 -> array input (idx + 1)
    110 | matches input (idx + 1) "ull" -> R VNull (idx + 4) False
    116 | matches input (idx + 1) "rue" -> R (VBool True) (idx + 4) False
    102 | matches input (idx + 1) "alse" -> R (VBool False) (idx + 5) False
    78 | matches input (idx + 1) "aN" -> R (VFloat (0 / 0)) (idx + 3) False
    73 | matches input (idx + 1) "nfinity" -> R (VFloat (1 / 0)) (idx + 8) False
    45 | matches input (idx + 1) "Infinity" -> R (VFloat (-1 / 0)) (idx + 9) False
    _ -> matchNumber input idx

object :: ByteString -> Int -> R
object input open =
  let first = skipWs input open
   in if byteAt input first == Just 125 then R (VDict []) (first + 1) False else members first [] False
  where
    members idx acc !lone =
      if byteAt input idx /= Just 34
        then failAt "Expecting property name enclosed in double quotes" idx
        else case scanString input (idx + 1) of
          R (VStr key) afterKey keyLone ->
            let colon = skipWs input afterKey
             in if byteAt input colon /= Just 58
                  then failAt "Expecting ':' delimiter" colon
                  else case scanOnce input (skipWs input (colon + 1)) of
                    R v afterValue valueLone ->
                      let next = skipWs input afterValue
                          acc' = (key, v) : acc
                          lone' = lone || keyLone || valueLone
                       in case byteAt input next of
                            Just 125 -> R (VDict (dedupe (reverse acc'))) (next + 1) lone'
                            Just 44 ->
                              let after = skipWs input (next + 1)
                               in if byteAt input after == Just 125
                                    then failAt "Illegal trailing comma before end of object" next
                                    else members after acc' lone'
                            _ -> failAt "Expecting ',' delimiter" next
          R _ _ _ -> error "scanString returned a non-string"

-- | @PyDict_SetItem@ in order: first position, last value.
dedupe :: [(Text, Value)] -> [(Text, Value)]
dedupe members = case members of
  [] -> members
  [_] -> members
  _
    | Map.size lastValue == length members -> members
    | otherwise -> go Map.empty members
  where
    lastValue = Map.fromList members
    go _ [] = []
    go seen ((k, _) : rest)
      | Map.member k seen = go seen rest
      | otherwise = (k, lastValue Map.! k) : go (Map.insert k () seen) rest

array :: ByteString -> Int -> R
array input open =
  let first = skipWs input open
   in if byteAt input first == Just 93 then R (VList []) (first + 1) False else items first [] False
  where
    items idx acc !lone = case scanOnce input idx of
      R v afterValue valueLone ->
        let next = skipWs input afterValue
            acc' = v : acc
            lone' = lone || valueLone
         in case byteAt input next of
              Just 93 -> R (VList (reverse acc')) (next + 1) lone'
              Just 44 ->
                let after = skipWs input (next + 1)
                 in if byteAt input after == Just 93
                      then failAt "Illegal trailing comma before end of array" next
                      else items after acc' lone'
              _ -> failAt "Expecting ',' delimiter" next

-- | @scanstring_unicode@ (strict): the string whose first character is at
-- @start@ (one past the opening quote).
scanString :: ByteString -> Int -> R
scanString input start = plain start
  where
    len = BS.length input
    begin = start - 1
    unterminated :: a
    unterminated = failAt "Unterminated string starting at" begin
    plain !i
      | i >= len = unterminated
      | otherwise =
          let b = BU.unsafeIndex input i
           in if b == 34
                then R (VStr (TE.decodeUtf8 (slice start i))) (i + 1) False
                else
                  if b == 92
                    then chunked [slice start i] False i
                    else if b <= 0x1F then failAt "Invalid control character at" i else plain (i + 1)
    slice from to = BU.unsafeTake (to - from) (BU.unsafeDrop from input)
    -- @backslash@ is the offset of a backslash; @chunks@ (reversed) hold
    -- the UTF-8 decoded so far.
    chunked chunks !lone backslash =
      let next = backslash + 1
       in if next >= len
            then unterminated
            else case BU.unsafeIndex input next of
              117 -> unicode chunks lone next
              c -> case simpleEscape c of
                Just w -> resume (BS.singleton w : chunks) lone (next + 1)
                Nothing -> failAt "Invalid \\escape" backslash
    resume chunks !lone from = go from
      where
        go !i
          | i >= len = unterminated
          | otherwise =
              let b = BU.unsafeIndex input i
               in if b == 34
                    then R (VStr (TE.decodeUtf8 (BS.concat (reverse (slice from i : chunks))))) (i + 1) lone
                    else
                      if b == 92
                        then chunked (slice from i : chunks) lone i
                        else if b <= 0x1F then failAt "Invalid control character at" i else go (i + 1)
    -- @u@ is the offset of the @u@.
    unicode chunks lone u =
      let end = u + 5
       in if end >= len
            then failAt "Invalid \\uXXXX escape" u
            else
              let c = hex4 (u + 1) u
               in if c >= 0xD800 && c <= 0xDBFF && end + 6 < len && BU.unsafeIndex input end == 92 && BU.unsafeIndex input (end + 1) == 117
                    then
                      let c2 = hex4 (end + 2) (end + 1)
                       in if c2 >= 0xDC00 && c2 <= 0xDFFF
                            then
                              let joined = 0x10000 + (((c - 0xD800) `shiftL` 10) .|. (c2 - 0xDC00))
                               in resume (encodeChar (chr joined) : chunks) lone (end + 6)
                            else resume (encodeChar '\xFFFD' : chunks) True end
                    else
                      if c >= 0xD800 && c <= 0xDFFF
                        then resume (encodeChar '\xFFFD' : chunks) True end
                        else resume (encodeChar (chr c) : chunks) lone end
    -- Four hex digits from @from@; an error is reported at @errorAt@.
    hex4 from errorAt = go 0 from
      where
        go !n !i
          | i >= from + 4 = n
          | otherwise =
              let d = BU.unsafeIndex input i
                  v
                    | d >= 48 && d <= 57 = fromIntegral d - 48
                    | d >= 97 && d <= 102 = fromIntegral d - 87
                    | d >= 65 && d <= 70 = fromIntegral d - 55
                    | otherwise = failAt "Invalid \\uXXXX escape" errorAt
               in go ((n `shiftL` 4) .|. v) (i + 1)
    simpleEscape = \case
      34 -> Just 34
      92 -> Just 92
      47 -> Just 47
      98 -> Just 8
      102 -> Just 12
      110 -> Just 10
      114 -> Just 13
      116 -> Just 9
      _ -> Nothing

encodeChar :: Char -> ByteString
encodeChar = BL.toStrict . B.toLazyByteString . B.charUtf8

-- | @_match_number_unicode@.
matchNumber :: ByteString -> Int -> R
matchNumber input start =
  let endIdx = BS.length input - 1
      at i = BU.unsafeIndex input i
      isDigit w = w >= 48 && w <= 57
      digitsFrom !i = if i <= endIdx && isDigit (at i) then digitsFrom (i + 1) else i
      afterSign
        | at start == 45 = if start + 1 > endIdx then expectingValue start else start + 1
        | otherwise = start
      intEnd
        | at afterSign >= 49 && at afterSign <= 57 = digitsFrom (afterSign + 1)
        | at afterSign == 48 = afterSign + 1
        | otherwise = expectingValue start
      (fracEnd, hasFrac)
        | intEnd < endIdx && at intEnd == 46 && isDigit (at (intEnd + 1)) = (digitsFrom (intEnd + 2), True)
        | otherwise = (intEnd, False)
      (end, hasExp)
        | fracEnd < endIdx && (at fracEnd == 101 || at fracEnd == 69) =
            let afterE = fracEnd + 1
                digitsAt = if afterE < endIdx && (at afterE == 45 || at afterE == 43) then afterE + 1 else afterE
                expEnd = digitsFrom digitsAt
             in if isDigit (at (expEnd - 1)) then (expEnd, True) else (fracEnd, False)
        | otherwise = (fracEnd, False)
      negative = afterSign /= start
      slice from to = BU.unsafeTake (to - from) (BU.unsafeDrop from input)
   in if hasFrac || hasExp
        then
          let fracDigits = if hasFrac then slice (intEnd + 1) fracEnd else BS.empty
              expo
                | hasExp =
                    let afterE = fracEnd + 1
                        (sign, digitsAt) = case at afterE of
                          45 -> (-1, afterE + 1)
                          43 -> (1, afterE + 1)
                          _ -> (1, afterE)
                     in sign * clampExponent (slice digitsAt end)
                | otherwise = 0
           in R (VFloat (decimalToDouble negative (slice afterSign intEnd) fracDigits expo)) end False
        else
          let digits = slice afterSign intEnd
           in if BS.length digits > maxIntStrDigits
                then throw (TooLong (BS.length digits))
                else
                  let magnitude = BS.foldl' (\acc w -> acc * 10 + toInteger (w - 48)) 0 digits
                   in R (VInt (if negative then negate magnitude else magnitude) False) intEnd False

clampExponent :: ByteString -> Integer
clampExponent ds =
  let trimmed = BS.dropWhile (== 48) ds
   in if BS.length trimmed > 12
        then 10 ^ (12 :: Int)
        else BS.foldl' (\acc w -> acc * 10 + toInteger (w - 48)) 0 trimmed
