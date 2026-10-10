{-# LANGUAGE BangPatterns #-}

-- | The JSON parser behind @FlatNetFile.model_validate_json@: a port of
-- jiter 0.14.0 (@JsonValue::parse(data, allow_inf_nan=true)@), which
-- pydantic-core 2.46 runs before validating.
--
-- It accepts and refuses the same documents, reports the same error at the
-- same byte offset, and builds the same values: object members stay in
-- document order with repeated keys kept, an integer of at most 18 digits
-- is an @Int@ and a longer one a @BigInt@ (the flag on 'VInt'), @NaN@,
-- @Infinity@ and @-Infinity@ are numbers, and nesting is limited to 200
-- non-empty containers.
module Petrus.EngineFile.Jiter
  ( JsonError (..)
  , JsonErrorType (..)
  , parseJson
  , errorMessage
  , errorDescription
  , linePosition
  ) where

import Control.Exception (Exception, evaluate, throw, try)
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Unsafe qualified as BU
import Data.Char (chr)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Petrus.EngineFile.Number (decimalToDouble)
import Petrus.EngineFile.Value (Value (..))
import System.IO.Unsafe (unsafeDupablePerformIO)

-- | jiter's @JsonErrorType@ (the variants @parse@ can raise).
data JsonErrorType
  = EofWhileParsingList
  | EofWhileParsingObject
  | EofWhileParsingString
  | EofWhileParsingValue
  | ExpectedColon
  | ExpectedListCommaOrEnd
  | ExpectedObjectCommaOrEnd
  | ExpectedSomeIdent
  | ExpectedSomeValue
  | InvalidEscape
  | InvalidNumber
  | NumberOutOfRange
  | InvalidUnicodeCodePoint
  | ControlCharacterWhileParsingString
  | KeyMustBeAString
  | LoneLeadingSurrogateInHexEscape
  | TrailingComma
  | TrailingCharacters
  | UnexpectedEndOfHexEscape
  | RecursionLimitExceeded
  deriving stock (Eq, Show)

-- | An error and the byte offset jiter reports it at.
data JsonError = JsonError !JsonErrorType !Int
  deriving stock (Eq, Show)

instance Exception JsonError

-- | jiter's @Display@ for the error type.
errorMessage :: JsonErrorType -> Text
errorMessage = \case
  EofWhileParsingList -> "EOF while parsing a list"
  EofWhileParsingObject -> "EOF while parsing an object"
  EofWhileParsingString -> "EOF while parsing a string"
  EofWhileParsingValue -> "EOF while parsing a value"
  ExpectedColon -> "expected `:`"
  ExpectedListCommaOrEnd -> "expected `,` or `]`"
  ExpectedObjectCommaOrEnd -> "expected `,` or `}`"
  ExpectedSomeIdent -> "expected ident"
  ExpectedSomeValue -> "expected value"
  InvalidEscape -> "invalid escape"
  InvalidNumber -> "invalid number"
  NumberOutOfRange -> "number out of range"
  InvalidUnicodeCodePoint -> "invalid unicode code point"
  ControlCharacterWhileParsingString -> "control character (\\u0000-\\u001F) found while parsing a string"
  KeyMustBeAString -> "key must be a string"
  LoneLeadingSurrogateInHexEscape -> "lone leading surrogate in hex escape"
  TrailingComma -> "trailing comma"
  TrailingCharacters -> "trailing characters"
  UnexpectedEndOfHexEscape -> "unexpected end of hex escape"
  RecursionLimitExceeded -> "recursion limit exceeded"

-- | @JsonError::description@: @"{message} at line L column C"@.
errorDescription :: ByteString -> JsonError -> Text
errorDescription input (JsonError kind offset) =
  let (line, column) = linePosition input offset
   in errorMessage kind <> " at line " <> T.pack (show line) <> " column " <> T.pack (show column)

-- | jiter's @LinePosition::find@, quirks included: an offset on a newline
-- reports column 0 of the next line, and an offset past the end reports
-- the length of the last line.
linePosition :: ByteString -> Int -> (Int, Int)
linePosition input target = go 0 1 0
  where
    len = BS.length input
    go !index !line !lineStart
      | index >= len = (line, max 0 (index - lineStart))
      | otherwise =
          let byte = BU.unsafeIndex input index
              (line', lineStart') = if byte == 10 then (line + 1, index + 1) else (line, lineStart)
           in if index == target
                then (line', index + 1 - lineStart')
                else go (index + 1) line' lineStart'

-- | Parse a whole document.
parseJson :: ByteString -> Either JsonError Value
parseJson input = unsafeDupablePerformIO (try (evaluate (parseDocument input)))

data R = R !Value {-# UNPACK #-} !Int

failAt :: JsonErrorType -> Int -> a
failAt kind offset = throw (JsonError kind offset)

recursionLimit :: Int
recursionLimit = 200

parseDocument :: ByteString -> Value
parseDocument input =
  let start = skipWs input 0
   in if start >= BS.length input
        then failAt EofWhileParsingValue start
        else case value input 0 (BU.unsafeIndex input start) start of
          R v end ->
            let end' = skipWs input end
             in if end' < BS.length input then failAt TrailingCharacters end' else v

skipWs :: ByteString -> Int -> Int
skipWs input = go
  where
    len = BS.length input
    go !i
      | i < len
      , let b = BU.unsafeIndex input i
      , b == 32 || b == 10 || b == 13 || b == 9 =
          go (i + 1)
      | otherwise = i

byteAt :: ByteString -> Int -> Maybe Word8
byteAt input i
  | i >= 0 && i < BS.length input = Just (BU.unsafeIndex input i)
  | otherwise = Nothing
{-# INLINE byteAt #-}

-- | One value starting at @index@ (whose byte is @peek@). @depth@ is the
-- number of enclosing non-empty containers (jiter's recursion stack plus
-- the current container).
value :: ByteString -> Int -> Word8 -> Int -> R
value input depth peek index = case peek of
  116 -> R (VBool True) (ident input index "rue")
  102 -> R (VBool False) (ident input index "alse")
  110 -> R VNull (ident input index "ull")
  34 -> case string input index of R s end -> R s end
  91 -> array input depth index
  123 -> object input depth index
  _ -> number input peek index

-- | @consume_ident@: the rest of a literal after its first byte.
ident :: ByteString -> Int -> ByteString -> Int
ident input index rest
  | BS.take size (BS.drop (index + 1) input) == rest = index + size + 1
  | otherwise = go (index + 1) 0
  where
    size = BS.length rest
    go !i !k
      | k >= size = failAt EofWhileParsingValue i
      | otherwise = case byteAt input i of
          Just b
            | b == BU.unsafeIndex rest k -> go (i + 1) (k + 1)
            | otherwise -> failAt ExpectedSomeIdent i
          Nothing -> failAt EofWhileParsingValue i

-- Containers ----------------------------------------------------------------

enter :: Int -> Int -> Int
enter depth index
  | depth + 1 > recursionLimit = failAt RecursionLimitExceeded index
  | otherwise = depth + 1
{-# INLINE enter #-}

array :: ByteString -> Int -> Int -> R
array input depth open =
  let first = skipWs input (open + 1)
   in case byteAt input first of
        Nothing -> failAt EofWhileParsingList first
        Just 93 -> R (VList []) (first + 1)
        Just b ->
          let depth' = if depth == 0 then 1 else enter depth first
           in items depth' b first []
  where
    items !depth' peek index acc = case value input depth' peek index of
      R v end ->
        let next = skipWs input end
         in case byteAt input next of
              Just 44 ->
                let after = skipWs input (next + 1)
                 in case byteAt input after of
                      Nothing -> failAt EofWhileParsingValue after
                      Just 93 -> failAt TrailingComma after
                      Just b -> items depth' b after (v : acc)
              Just 93 -> R (VList (reverse (v : acc))) (next + 1)
              Just _ -> failAt ExpectedListCommaOrEnd next
              Nothing -> failAt EofWhileParsingList next

object :: ByteString -> Int -> Int -> R
object input depth open =
  let first = skipWs input (open + 1)
   in case byteAt input first of
        Nothing -> failAt EofWhileParsingObject first
        Just 125 -> R (VDict []) (first + 1)
        Just 34 -> case key first of
          (k, valueAt, peek) ->
            let depth' = if depth == 0 then 1 else enter depth valueAt
             in members depth' k peek valueAt []
        Just _ -> failAt KeyMustBeAString first
  where
    key at = case string input at of
      R (VStr k) end ->
        let colon = skipWs input end
         in case byteAt input colon of
              Just 58 ->
                let valueAt = skipWs input (colon + 1)
                 in case byteAt input valueAt of
                      Just peek -> (k, valueAt, peek)
                      Nothing -> failAt EofWhileParsingValue valueAt
              Just _ -> failAt ExpectedColon colon
              Nothing -> failAt EofWhileParsingObject colon
      R _ _ -> error "string returned a non-string"
    members !depth' k peek index acc = case value input depth' peek index of
      R v end ->
        let next = skipWs input end
         in case byteAt input next of
              Just 44 ->
                let after = skipWs input (next + 1)
                 in case byteAt input after of
                      Just 34 -> case key after of
                        (k', valueAt, peek') -> members depth' k' peek' valueAt ((k, v) : acc)
                      Just 125 -> failAt TrailingComma after
                      Just _ -> failAt KeyMustBeAString after
                      Nothing -> failAt EofWhileParsingValue after
              Just 125 -> R (VDict (reverse ((k, v) : acc))) (next + 1)
              Just _ -> failAt ExpectedObjectCommaOrEnd next
              Nothing -> failAt EofWhileParsingObject next

-- Strings ---------------------------------------------------------------------

-- | A string whose opening quote is at @open@.
string :: ByteString -> Int -> R
string input open = scan start
  where
    start = open + 1
    len = BS.length input
    scan !i
      | i >= len = failAt EofWhileParsingString i
      | otherwise =
          let b = BU.unsafeIndex input i
           in if b == 34
                then R (VStr (toText input start (slice start i))) (i + 1)
                else
                  if b == 92
                    then escaped input start [slice start i] i
                    else if b < 32 then failAt ControlCharacterWhileParsingString i else scan (i + 1)
    slice from to = BU.unsafeTake (to - from) (BU.unsafeDrop from input)

-- | The tape path: @chunks@ (reversed) hold the decoded text so far and
-- @backslash@ is the offset of the escape being decoded.
escaped :: ByteString -> Int -> [ByteString] -> Int -> R
escaped input start = go
  where
    len = BS.length input
    go chunks backslash =
      let at = backslash + 1
       in case byteAt input at of
            Nothing -> failAt EofWhileParsingString at
            Just c -> case c of
              117 -> case unicodeEscape input at of
                (ch, lastHex) -> continue (encodeChar ch : chunks) (lastHex + 1)
              _ -> case simpleEscape c of
                Just w -> continue (BS.singleton w : chunks) (at + 1)
                Nothing -> failAt InvalidEscape at
    continue chunks from = scan from
      where
        scan !i
          | i >= len = failAt EofWhileParsingString i
          | otherwise =
              let b = BU.unsafeIndex input i
               in if b == 34
                    then
                      let bytes = BS.concat (reverse (slice from i : chunks))
                       in R (VStr (toText input start bytes)) (i + 1)
                    else
                      if b == 92
                        then go (slice from i : chunks) i
                        else if b < 32 then failAt ControlCharacterWhileParsingString i else scan (i + 1)
    slice from to = BU.unsafeTake (to - from) (BU.unsafeDrop from input)
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

-- | @parse_escape@: the character a @\\u@ escape (and a following low
-- surrogate escape) denotes, and the offset of its last hex digit.
unicodeEscape :: ByteString -> Int -> (Char, Int)
unicodeEscape input u = case hex4 input u of
  (n, index)
    | n >= 0xDC00 && n <= 0xDFFF -> failAt LoneLeadingSurrogateInHexEscape index
    | n >= 0xD800 && n <= 0xDBFF -> case (byteAt input (index + 1), byteAt input (index + 2)) of
        (Just 92, Just 117) -> case hex4 input (index + 2) of
          (n2, index2)
            | n2 >= 0xDC00 && n2 <= 0xDFFF ->
                (chr ((((n - 0xD800) `shiftL` 10) .|. (n2 - 0xDC00)) + 0x10000), index2)
            | otherwise -> failAt LoneLeadingSurrogateInHexEscape index2
        (Just 92, Just _) -> failAt UnexpectedEndOfHexEscape (index + 2)
        (Just _, Just _) -> failAt UnexpectedEndOfHexEscape (index + 1)
        (Just 92, Nothing) -> failAt EofWhileParsingString (BS.length input)
        (Nothing, _) -> failAt EofWhileParsingString (BS.length input)
        (Just _, Nothing) -> failAt UnexpectedEndOfHexEscape (index + 1)
    | otherwise -> (chr n, index)

-- | @parse_u4@: four hex digits after offset @index@.
hex4 :: ByteString -> Int -> (Int, Int)
hex4 input index
  | index + 5 > BS.length input = failAt EofWhileParsingString (BS.length input)
  | otherwise = go 0 1
  where
    go !n !k
      | k > 4 = (n, index + 4)
      | otherwise =
          let c = BU.unsafeIndex input (index + k)
              digit
                | c >= 48 && c <= 57 = fromIntegral c - 48
                | c >= 97 && c <= 102 = fromIntegral c - 87
                | c >= 65 && c <= 70 = fromIntegral c - 55
                | otherwise = failAt InvalidEscape (index + k)
           in go ((n `shiftL` 4) + digit) (k + 1)

-- | @to_str@: decode UTF-8, refusing an invalid sequence at the offset
-- jiter reports (one past the valid prefix, counted from the string start).
toText :: ByteString -> Int -> ByteString -> Text
toText _ start bytes = case TE.decodeUtf8' bytes of
  Right t -> t
  Left _ -> failAt InvalidUnicodeCodePoint (start + utf8ValidUpTo bytes + 1)

-- | The length of the longest valid UTF-8 prefix.
utf8ValidUpTo :: ByteString -> Int
utf8ValidUpTo bytes = go 0
  where
    len = BS.length bytes
    at i = if i < len then fromIntegral (BU.unsafeIndex bytes i) else (-1 :: Int)
    cont i = let c = at i in c >= 0x80 && c <= 0xBF
    go !i
      | i >= len = len
      | otherwise =
          let b = at i
           in if b < 0x80
                then go (i + 1)
                else
                  if b >= 0xC2 && b <= 0xDF && cont (i + 1)
                    then go (i + 2)
                    else
                      if b >= 0xE0 && b <= 0xEF && second3 b (at (i + 1)) && cont (i + 2)
                        then go (i + 3)
                        else
                          if b >= 0xF0 && b <= 0xF4 && second4 b (at (i + 1)) && cont (i + 2) && cont (i + 3)
                            then go (i + 4)
                            else i
    second3 b c
      | b == 0xE0 = c >= 0xA0 && c <= 0xBF
      | b == 0xED = c >= 0x80 && c <= 0x9F
      | otherwise = c >= 0x80 && c <= 0xBF
    second4 b c
      | b == 0xF0 = c >= 0x90 && c <= 0xBF
      | b == 0xF4 = c >= 0x80 && c <= 0x8F
      | otherwise = c >= 0x80 && c <= 0xBF

-- Numbers ---------------------------------------------------------------------

isDigitW :: Word8 -> Bool
isDigitW b = b >= 48 && b <= 57
{-# INLINE isDigitW #-}

-- | @NumberAny::decode@, with @take_value@'s remapping of errors for a
-- value that does not start like a number.
number :: ByteString -> Word8 -> Int -> R
number input peek start
  | peek == 78 = R (VFloat (0 / 0)) (ident input start "aN")
  | peek == 73 = R (VFloat (1 / 0)) (ident input start "nfinity")
  | peek == 45 = signed
  | isDigitW peek = unsigned False start
  | otherwise = failAt ExpectedSomeValue start
  where
    signed = case byteAt input (start + 1) of
      Nothing -> failAt EofWhileParsingValue (start + 1)
      Just 73 -> R (VFloat (-1 / 0)) (ident input (start + 1) "nfinity")
      Just b
        | isDigitW b -> unsigned True (start + 1)
        | otherwise -> failAt InvalidNumber (start + 1)
    len = BS.length input
    digitsFrom !i = if i < len && isDigitW (BU.unsafeIndex input i) then digitsFrom (i + 1) else i
    isFloatByte i = case byteAt input i of
      Just b -> b == 46 || b == 101 || b == 69
      Nothing -> False
    unsigned negative first
      | BU.unsafeIndex input first == 48 = case byteAt input (first + 1) of
          Just b
            | b == 46 || b == 101 || b == 69 -> float negative first
            | isDigitW b -> failAt InvalidNumber (first + 1)
          _ -> R (VInt 0 False) (first + 1)
      | otherwise =
          let end = digitsFrom first
              count = end - first
           in if count > 18 && end - start > 4300
                then failAt NumberOutOfRange (start + 4301)
                else
                  if isFloatByte end
                    then float negative first
                    else
                      let magnitude = readDigits first end
                       in R (VInt (if negative then negate magnitude else magnitude) (count > 18)) end
    readDigits from to
      | to - from <= 18 = toInteger (smallDigits from to 0)
      | otherwise = BS.foldl' (\acc w -> acc * 10 + toInteger (w - 48)) 0 (BU.unsafeTake (to - from) (BU.unsafeDrop from input))
    smallDigits :: Int -> Int -> Int -> Int
    smallDigits !i !to !acc
      | i >= to = acc
      | otherwise = smallDigits (i + 1) to (acc * 10 + fromIntegral (BU.unsafeIndex input i - 48))
    -- A float in JSON grammar; on a malformed tail, @NumberRange@'s error.
    float negative first =
      let intEnd = digitsFrom first
          (fracStart, fracEnd) = case byteAt input intEnd of
            Just 46 -> case byteAt input (intEnd + 1) of
              Just b | isDigitW b -> (intEnd + 1, digitsFrom (intEnd + 1))
              Just _ -> failAt InvalidNumber (intEnd + 1)
              Nothing -> failAt EofWhileParsingValue (intEnd + 1)
            _ -> (intEnd, intEnd)
          (expo, end) = case byteAt input fracEnd of
            Just b | b == 101 || b == 69 -> exponentPart (fracEnd + 1)
            _ -> (0, fracEnd)
          slice from to = BU.unsafeTake (to - from) (BU.unsafeDrop from input)
       in R (VFloat (decimalToDouble negative (slice first intEnd) (slice fracStart fracEnd) expo)) end
    exponentPart at =
      let (negativeExp, digitsAt) = case byteAt input at of
            Just 45 -> (True, at + 1)
            Just 43 -> (False, at + 1)
            Just b | isDigitW b -> (False, at)
            Just _ -> failAt InvalidNumber at
            Nothing -> failAt EofWhileParsingValue at
       in case byteAt input digitsAt of
            Just b
              | isDigitW b ->
                  let end = digitsFrom digitsAt
                      magnitude = clampExponent (BU.unsafeTake (end - digitsAt) (BU.unsafeDrop digitsAt input))
                   in (if negativeExp then negate magnitude else magnitude, end)
              | otherwise -> failAt InvalidNumber digitsAt
            Nothing -> failAt EofWhileParsingValue digitsAt

-- An exponent's value, saturated far beyond any finite double's range.
clampExponent :: ByteString -> Integer
clampExponent ds =
  let trimmed = BS.dropWhile (== 48) ds
   in if BS.length trimmed > 12
        then 10 ^ (12 :: Int)
        else BS.foldl' (\acc w -> acc * 10 + toInteger (w - 48)) 0 trimmed

