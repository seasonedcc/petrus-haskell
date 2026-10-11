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
-- non-empty containers. The parser is pure: no exception carries a
-- refusal (see 'Step').
module Petrus.EngineFile.Jiter
  ( JsonError (..)
  , JsonErrorType (..)
  , parseJson
  , errorMessage
  , errorDescription
  , linePosition
  ) where

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
import Petrus.Json.Python.Decode (CodecFailure (..), utf8DecodeFailure)

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
parseJson input
  | start >= BS.length input = Left (JsonError EofWhileParsingValue start)
  | otherwise = case value input 0 (BU.unsafeIndex input start) start of
      Failed kind offset -> Left (JsonError kind offset)
      Step v end ->
        let end' = skipWs input end
         in if end' < BS.length input then Left (JsonError TrailingCharacters end') else Right v
  where
    start = skipWs input 0

-- | A production's result and the offset just after it, or the error jiter
-- raises and the offset it reports. Pure, as petrus-json's parser is: each
-- production returns one and its caller continues or passes the failure
-- on, so the first error in document order is the one reported. (It times
-- the same as the exception-based scanner it replaced on the chain
-- benchmarks.)
data Step a
  = Step !a {-# UNPACK #-} !Int
  | Failed !JsonErrorType {-# UNPACK #-} !Int

recursionLimit :: Int
recursionLimit = 200

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

slice :: ByteString -> Int -> Int -> ByteString
slice input from to = BU.unsafeTake (to - from) (BU.unsafeDrop from input)
{-# INLINE slice #-}

-- | One value starting at @index@ (whose byte is @peek@). @depth@ is the
-- number of enclosing non-empty containers (jiter's recursion stack plus
-- the current container).
value :: ByteString -> Int -> Word8 -> Int -> Step Value
value input depth peek index = case peek of
  116 -> ident input index "rue" (VBool True)
  102 -> ident input index "alse" (VBool False)
  110 -> ident input index "ull" VNull
  34 -> case string input index of
    Step s end -> Step (VStr s) end
    Failed kind offset -> Failed kind offset
  91 -> array input depth index
  123 -> object input depth index
  _ -> number input peek index

-- | @consume_ident@: the rest of a literal after its first byte, which
-- spells @v@.
ident :: ByteString -> Int -> ByteString -> a -> Step a
ident input index rest v
  | BS.take size (BS.drop (index + 1) input) == rest = Step v (index + size + 1)
  | otherwise = go (index + 1) 0
  where
    size = BS.length rest
    go !i !k
      | k >= size = Failed EofWhileParsingValue i
      | otherwise = case byteAt input i of
          Just b
            | b == BU.unsafeIndex rest k -> go (i + 1) (k + 1)
            | otherwise -> Failed ExpectedSomeIdent i
          Nothing -> Failed EofWhileParsingValue i

-- Containers ----------------------------------------------------------------

-- | A non-empty container's first member is reached at @index@: one more
-- level, unless that passes jiter's limit.
enter :: Int -> Int -> (Int -> Step a) -> Step a
enter depth index continue
  | depth >= recursionLimit = Failed RecursionLimitExceeded index
  | otherwise = continue (depth + 1)
{-# INLINE enter #-}

array :: ByteString -> Int -> Int -> Step Value
array input depth open = case byteAt input first of
  Nothing -> Failed EofWhileParsingList first
  Just 93 -> Step (VList []) (first + 1)
  Just b -> enter depth first (\depth' -> items depth' b first [])
  where
    first = skipWs input (open + 1)
    items !depth' peek index acc = case value input depth' peek index of
      Failed kind offset -> Failed kind offset
      Step v end ->
        let next = skipWs input end
         in case byteAt input next of
              Just 44 ->
                let after = skipWs input (next + 1)
                 in case byteAt input after of
                      Nothing -> Failed EofWhileParsingValue after
                      Just 93 -> Failed TrailingComma after
                      Just b -> items depth' b after (v : acc)
              Just 93 -> Step (VList (reverse (v : acc))) (next + 1)
              Just _ -> Failed ExpectedListCommaOrEnd next
              Nothing -> Failed EofWhileParsingList next

-- | A member's key and the first byte of its value.
data Key = Key !Text {-# UNPACK #-} !Word8

object :: ByteString -> Int -> Int -> Step Value
object input depth open = case byteAt input first of
  Nothing -> Failed EofWhileParsingObject first
  Just 125 -> Step (VDict []) (first + 1)
  Just 34 -> case key first of
    Failed kind offset -> Failed kind offset
    Step (Key k peek) valueAt -> enter depth valueAt (\depth' -> members depth' k peek valueAt [])
  Just _ -> Failed KeyMustBeAString first
  where
    first = skipWs input (open + 1)
    -- The key at @at@ and its colon; the step ends at the value.
    key at = case string input at of
      Failed kind offset -> Failed kind offset
      Step k end ->
        let colon = skipWs input end
         in case byteAt input colon of
              Just 58 ->
                let valueAt = skipWs input (colon + 1)
                 in case byteAt input valueAt of
                      Just peek -> Step (Key k peek) valueAt
                      Nothing -> Failed EofWhileParsingValue valueAt
              Just _ -> Failed ExpectedColon colon
              Nothing -> Failed EofWhileParsingObject colon
    members !depth' k peek index acc = case value input depth' peek index of
      Failed kind offset -> Failed kind offset
      Step v end ->
        let next = skipWs input end
         in case byteAt input next of
              Just 44 ->
                let after = skipWs input (next + 1)
                 in case byteAt input after of
                      Just 34 -> case key after of
                        Failed kind offset -> Failed kind offset
                        Step (Key k' peek') valueAt -> members depth' k' peek' valueAt ((k, v) : acc)
                      Just 125 -> Failed TrailingComma after
                      Just _ -> Failed KeyMustBeAString after
                      Nothing -> Failed EofWhileParsingValue after
              Just 125 -> Step (VDict (reverse ((k, v) : acc))) (next + 1)
              Just _ -> Failed ExpectedObjectCommaOrEnd next
              Nothing -> Failed EofWhileParsingObject next

-- Strings ---------------------------------------------------------------------

-- | A string whose opening quote is at @open@.
string :: ByteString -> Int -> Step Text
string input open = scan start
  where
    start = open + 1
    len = BS.length input
    scan !i
      | i >= len = Failed EofWhileParsingString i
      | otherwise =
          let b = BU.unsafeIndex input i
           in if b == 34
                then toText start (slice input start i) (i + 1)
                else
                  if b == 92
                    then escaped input start [slice input start i] i
                    else if b < 32 then Failed ControlCharacterWhileParsingString i else scan (i + 1)

-- | The tape path: @chunks@ (reversed) hold the decoded text so far and
-- @backslash@ is the offset of the escape being decoded.
escaped :: ByteString -> Int -> [ByteString] -> Int -> Step Text
escaped input start = go
  where
    len = BS.length input
    go chunks backslash =
      let at = backslash + 1
       in case byteAt input at of
            Nothing -> Failed EofWhileParsingString at
            Just c -> case c of
              117 -> case unicodeEscape input at of
                Step ch lastHex -> continue (encodeChar ch : chunks) (lastHex + 1)
                Failed kind offset -> Failed kind offset
              _ -> case simpleEscape c of
                Just w -> continue (BS.singleton w : chunks) (at + 1)
                Nothing -> Failed InvalidEscape at
    continue chunks from = scan from
      where
        scan !i
          | i >= len = Failed EofWhileParsingString i
          | otherwise =
              let b = BU.unsafeIndex input i
               in if b == 34
                    then toText start (BS.concat (reverse (slice input from i : chunks))) (i + 1)
                    else
                      if b == 92
                        then go (slice input from i : chunks) i
                        else if b < 32 then Failed ControlCharacterWhileParsingString i else scan (i + 1)
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
-- surrogate escape) denotes; the step ends at its last hex digit.
unicodeEscape :: ByteString -> Int -> Step Char
unicodeEscape input u = case hex4 input u of
  Failed kind offset -> Failed kind offset
  Step n index
    | n >= 0xDC00 && n <= 0xDFFF -> Failed LoneLeadingSurrogateInHexEscape index
    | n >= 0xD800 && n <= 0xDBFF -> case (byteAt input (index + 1), byteAt input (index + 2)) of
        (Just 92, Just 117) -> case hex4 input (index + 2) of
          Failed kind offset -> Failed kind offset
          Step n2 index2
            | n2 >= 0xDC00 && n2 <= 0xDFFF ->
                Step (chr ((((n - 0xD800) `shiftL` 10) .|. (n2 - 0xDC00)) + 0x10000)) index2
            | otherwise -> Failed LoneLeadingSurrogateInHexEscape index2
        (Just 92, Just _) -> Failed UnexpectedEndOfHexEscape (index + 2)
        (Just _, Just _) -> Failed UnexpectedEndOfHexEscape (index + 1)
        (Just 92, Nothing) -> Failed EofWhileParsingString (BS.length input)
        (Nothing, _) -> Failed EofWhileParsingString (BS.length input)
        (Just _, Nothing) -> Failed UnexpectedEndOfHexEscape (index + 1)
    | otherwise -> Step (chr n) index

-- | @parse_u4@: four hex digits after offset @index@; the step ends at the
-- last.
hex4 :: ByteString -> Int -> Step Int
hex4 input index
  | index + 5 > BS.length input = Failed EofWhileParsingString (BS.length input)
  | otherwise = go 0 1
  where
    go !n !k
      | k > 4 = Step n (index + 4)
      | otherwise =
          let c = BU.unsafeIndex input (index + k)
           in case hexDigit c of
                Just digit -> go ((n `shiftL` 4) + digit) (k + 1)
                Nothing -> Failed InvalidEscape (index + k)
    hexDigit c
      | c >= 48 && c <= 57 = Just (fromIntegral c - 48)
      | c >= 97 && c <= 102 = Just (fromIntegral c - 87)
      | c >= 65 && c <= 70 = Just (fromIntegral c - 55)
      | otherwise = Nothing

-- | @to_str@: decode UTF-8, refusing an invalid sequence at the offset
-- jiter reports, one past its valid prefix (Rust's @valid_up_to@, where
-- CPython's decoder starts its error), counted from the string start.
toText :: Int -> ByteString -> Int -> Step Text
toText start bytes end = case TE.decodeUtf8' bytes of
  Right t -> Step t end
  Left _ -> Failed InvalidUnicodeCodePoint (start + maybe (BS.length bytes) (.failureStart) (utf8DecodeFailure bytes) + 1)

-- Numbers ---------------------------------------------------------------------

isDigitW :: Word8 -> Bool
isDigitW b = b >= 48 && b <= 57
{-# INLINE isDigitW #-}

-- | @NumberAny::decode@, with @take_value@'s remapping of errors for a
-- value that does not start like a number.
number :: ByteString -> Word8 -> Int -> Step Value
number input peek start
  | peek == 78 = ident input start "aN" (VFloat (0 / 0))
  | peek == 73 = ident input start "nfinity" (VFloat (1 / 0))
  | peek == 45 = signed
  | isDigitW peek = unsigned False start
  | otherwise = Failed ExpectedSomeValue start
  where
    signed = case byteAt input (start + 1) of
      Nothing -> Failed EofWhileParsingValue (start + 1)
      Just 73 -> ident input (start + 1) "nfinity" (VFloat (-1 / 0))
      Just b
        | isDigitW b -> unsigned True (start + 1)
        | otherwise -> Failed InvalidNumber (start + 1)
    len = BS.length input
    digitsFrom !i = if i < len && isDigitW (BU.unsafeIndex input i) then digitsFrom (i + 1) else i
    isFloatByte i = case byteAt input i of
      Just b -> b == 46 || b == 101 || b == 69
      Nothing -> False
    unsigned negative first
      | BU.unsafeIndex input first == 48 = case byteAt input (first + 1) of
          Just b
            | b == 46 || b == 101 || b == 69 -> float negative first
            | isDigitW b -> Failed InvalidNumber (first + 1)
          _ -> Step (VInt 0 False) (first + 1)
      | count > 18 && end - start > 4300 = Failed NumberOutOfRange (start + 4301)
      | isFloatByte end = float negative first
      | otherwise =
          let magnitude = readDigits first end
           in Step (VInt (if negative then negate magnitude else magnitude) (count > 18)) end
      where
        end = digitsFrom first
        count = end - first
    readDigits from to
      | to - from <= 18 = toInteger (smallDigits from to 0)
      | otherwise = BS.foldl' (\acc w -> acc * 10 + toInteger (w - 48)) 0 (slice input from to)
    smallDigits :: Int -> Int -> Int -> Int
    smallDigits !i !to !acc
      | i >= to = acc
      | otherwise = smallDigits (i + 1) to (acc * 10 + fromIntegral (BU.unsafeIndex input i - 48))
    -- A float in JSON grammar; on a malformed tail, @NumberRange@'s error.
    float negative first = case byteAt input intEnd of
      Just 46 -> case byteAt input (intEnd + 1) of
        Just b | isDigitW b -> withExponent (intEnd + 1) (digitsFrom (intEnd + 1))
        Just _ -> Failed InvalidNumber (intEnd + 1)
        Nothing -> Failed EofWhileParsingValue (intEnd + 1)
      _ -> withExponent intEnd intEnd
      where
        intEnd = digitsFrom first
        withExponent fracStart fracEnd = case byteAt input fracEnd of
          Just b | b == 101 || b == 69 -> case exponentPart (fracEnd + 1) of
            Step expo end -> done fracStart fracEnd expo end
            Failed kind offset -> Failed kind offset
          _ -> done fracStart fracEnd 0 fracEnd
        done fracStart fracEnd expo end =
          Step (VFloat (decimalToDouble negative (slice input first intEnd) (slice input fracStart fracEnd) expo)) end
    exponentPart at = case byteAt input at of
      Just 45 -> digits True (at + 1)
      Just 43 -> digits False (at + 1)
      Just b | isDigitW b -> digits False at
      Just _ -> Failed InvalidNumber at
      Nothing -> Failed EofWhileParsingValue at
      where
        digits negativeExp digitsAt = case byteAt input digitsAt of
          Just b
            | isDigitW b ->
                let end = digitsFrom digitsAt
                    magnitude = clampExponent (slice input digitsAt end)
                 in Step (if negativeExp then negate magnitude else magnitude) end
            | otherwise -> Failed InvalidNumber digitsAt
          Nothing -> Failed EofWhileParsingValue digitsAt

-- An exponent's value, saturated far beyond any finite double's range.
clampExponent :: ByteString -> Integer
clampExponent ds =
  let trimmed = BS.dropWhile (== 48) ds
   in if BS.length trimmed > 12
        then 10 ^ (12 :: Int)
        else BS.foldl' (\acc w -> acc * 10 + toInteger (w - 48)) 0 trimmed
