{-# LANGUAGE MultiWayIf #-}

-- | CPython's text decoding and @json.loads@ scanner, error for error.
--
-- The Net-definition and Net-document wire formats are defined by the
-- reference's strict parsers, and their refusal messages embed CPython's
-- own diagnostics: @bytes.decode("utf-8")@'s 'UnicodeDecodeError' text and
-- @json.loads@'s 'JSONDecodeError' text (with line, column, and character
-- offset). The reference also hooks the scanner (@object_pairs_hook@,
-- @parse_int@, @parse_float@, @parse_constant@), and the /order/ in which
-- those hooks fire decides which refusal a malformed document gets: a number
-- hook fires when its token is scanned, the pairs hook when its object
-- closes. "Petrus.Json"'s parser admits the same documents but reports its
-- own messages and refuses lone surrogate escapes eagerly, so this module
-- mirrors CPython's C scanner (@Modules/_json.c@) and UTF-8 decoder
-- (@Objects/stringlib/codecs.h@) instead.
--
-- Strings are scanned as 'String' so that a lone surrogate escape (which
-- CPython decodes into a @str@ and the reference refuses only afterwards, in
-- traversal order) survives until the caller's own admission pass.
module Petrus.Impetus.Internal.PyJson
  ( -- * UTF-8
    decodeUtf8Python
    -- * Scanning
  , Raw (..)
  , Hooks (..)
  , ScanError (..)
  , loads
  , decodeErrorText
  , defaultInt
  , defaultFloat
  , isSurrogate
  , rawText
  ) where

import Data.Bits ((.&.), (.|.), shiftL)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr, isDigit, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Numeric (showHex)

-- ---------------------------------------------------------------------------
-- UTF-8

-- | @payload.decode("utf-8", errors="strict")@: the decoded text, or the
-- 'UnicodeDecodeError' message CPython reports for the first malformed
-- sequence.
decodeUtf8Python :: ByteString -> Either Text Text
decodeUtf8Python bytes = case TE.decodeUtf8' bytes of
  Right text -> Right text
  Left _ -> Left (firstUtf8Error bytes)

-- The first error, classified exactly as CPython's decoder classifies it.
firstUtf8Error :: ByteString -> Text
firstUtf8Error bytes = go 0
  where
    n = BS.length bytes
    at i = BS.index bytes i
    cont w = w .&. 0xC0 == 0x80
    go i
      | i >= n = "'utf-8' codec can't decode bytes: no error found"
      | otherwise =
          let b = at i
              remaining = n - i
           in if
                | b < 0x80 -> go (i + 1)
                | b < 0xC2 -> invalidStart i
                | b < 0xE0 ->
                    if
                      | remaining < 2 -> endOfData i
                      | not (cont (at (i + 1))) -> invalid i 1
                      | otherwise -> go (i + 2)
                | b < 0xF0 ->
                    if remaining < 3
                      then
                        if remaining >= 2 && badSecond3 b (at (i + 1))
                          then invalid i 1
                          else endOfData i
                      else
                        if
                          | badSecond3 b (at (i + 1)) -> invalid i 1
                          | not (cont (at (i + 2))) -> invalid i 2
                          | otherwise -> go (i + 3)
                | b < 0xF5 ->
                    if remaining < 4
                      then
                        if
                          | remaining >= 2 && badSecond4 b (at (i + 1)) -> invalid i 1
                          | remaining >= 3 && not (cont (at (i + 2))) -> invalid i 2
                          | otherwise -> endOfData i
                      else
                        if
                          | badSecond4 b (at (i + 1)) -> invalid i 1
                          | not (cont (at (i + 2))) -> invalid i 2
                          | not (cont (at (i + 3))) -> invalid i 3
                          | otherwise -> go (i + 4)
                | otherwise -> invalidStart i
    badSecond3 b w = not (cont w) || (if w < 0xA0 then b == 0xE0 else b == 0xED)
    badSecond4 b w = not (cont w) || (if w < 0x90 then b == 0xF0 else b == 0xF4)
    invalidStart i = message i (i + 1) "invalid start byte"
    invalid i len = message i (i + len) "invalid continuation byte"
    endOfData i = message i n "unexpected end of data"
    message start end reason
      | end - start == 1 =
          "'utf-8' codec can't decode byte 0x"
            <> hex2 (at start)
            <> " in position "
            <> tshow start
            <> ": "
            <> reason
      | otherwise =
          "'utf-8' codec can't decode bytes in position "
            <> tshow start
            <> "-"
            <> tshow (end - 1)
            <> ": "
            <> reason

hex2 :: Word8 -> Text
hex2 w = let digits = showHex w "" in T.pack (replicate (2 - length digits) '0' ++ digits)

tshow :: Show a => a -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- Scanning

-- | A scanned JSON value. Strings are code-point sequences that may hold
-- lone surrogates, exactly as CPython's @str@ can.
data Raw
  = RNull
  | RBool Bool
  | RInt Integer
  | RFloat Double
  | RStr String
  | RList [Raw]
  | -- | Members in document order.
    RDict [(String, Raw)]
  deriving stock (Show)

-- | A string's text. Only call this on strings already admitted as Unicode
-- scalar values ('Data.Text.Text' cannot hold a surrogate).
rawText :: String -> Text
rawText = T.pack

-- | Whether a code point is a UTF-16 surrogate.
isSurrogate :: Char -> Bool
isSurrogate c = ord c >= 0xD800 && ord c <= 0xDFFF

-- | The scanner's hooks, each failing with the caller's error type.
data Hooks e = Hooks
  { parseInt :: String -> Either e Integer
  -- ^ @parse_int@, given the integer token.
  , parseFloat :: String -> Either e Double
  -- ^ @parse_float@, given the token with a fraction or exponent.
  , parseConstant :: String -> Either e Raw
  -- ^ @parse_constant@, given @NaN@, @Infinity@, or @-Infinity@.
  , objectPairs :: [(String, Raw)] -> Either e ()
  -- ^ @object_pairs_hook@, called when an object closes.
  }

-- | Why scanning stopped.
data ScanError e
  = -- | A 'JSONDecodeError': the bare message and its character offset.
    DecodeError Text Int
  | -- | A hook refused a token or an object.
    HookError e

-- | @json.loads(text, ...)@ with the given hooks.
loads :: Hooks e -> Text -> Either (ScanError e) Raw
loads hooks text = case T.unpack text of
  '\xFEFF' : _ -> Left (DecodeError "Unexpected UTF-8 BOM (decode using utf-8-sig)" 0)
  chars -> do
    let (start, rest) = skipWs 0 chars
    (value, end, remaining) <- scanOnce hooks start rest
    let (end', remaining') = skipWs end remaining
    case remaining' of
      [] -> Right value
      _ -> Left (DecodeError "Extra data" end')

-- | CPython's 'JSONDecodeError' text: the message with its line, column, and
-- character offset in the document.
decodeErrorText :: Text -> Text -> Int -> Text
decodeErrorText document message position =
  let before = T.take position document
      line = T.count "\n" before + 1
      column = case T.breakOnEnd "\n" before of
        (prefix, _)
          | T.null prefix -> position + 1
          | otherwise -> position - (T.length prefix - 1)
   in message <> ": line " <> tshow line <> " column " <> tshow column <> " (char " <> tshow position <> ")"

isWs :: Char -> Bool
isWs c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

skipWs :: Int -> String -> (Int, String)
skipWs i = \case
  c : rest | isWs c -> skipWs (i + 1) rest
  rest -> (i, rest)

type Scan e a = Either (ScanError e) a

-- | @scan_once@: one value at a position. A missing value is CPython's
-- @StopIteration@, reported as "Expecting value" at the value's position.
scanOnce :: Hooks e -> Int -> String -> Scan e (Raw, Int, String)
scanOnce hooks i input = case input of
  [] -> stop
  '"' : rest -> do
    (value, end, rest') <- scanString (i + 1) rest
    Right (RStr value, end, rest')
  '{' : rest -> parseObject hooks (i + 1) rest
  '[' : rest -> parseArray hooks (i + 1) rest
  'n' : 'u' : 'l' : 'l' : rest -> Right (RNull, i + 4, rest)
  't' : 'r' : 'u' : 'e' : rest -> Right (RBool True, i + 4, rest)
  'f' : 'a' : 'l' : 's' : 'e' : rest -> Right (RBool False, i + 5, rest)
  'N' : 'a' : 'N' : rest -> constant "NaN" 3 rest
  'I' : 'n' : 'f' : 'i' : 'n' : 'i' : 't' : 'y' : rest -> constant "Infinity" 8 rest
  '-' : 'I' : 'n' : 'f' : 'i' : 'n' : 'i' : 't' : 'y' : rest -> constant "-Infinity" 9 rest
  _ -> matchNumber hooks i input
  where
    stop = Left (DecodeError "Expecting value" i)
    constant spelling width rest = case hooks.parseConstant spelling of
      Left e -> Left (HookError e)
      Right value -> Right (value, i + width, rest)

-- | @_match_number_unicode@: CPython's number grammar
-- @-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?@, dispatched to the integer
-- or float hook.
matchNumber :: Hooks e -> Int -> String -> Scan e (Raw, Int, String)
matchNumber hooks start input = do
  let (sign, afterSign) = case input of
        '-' : rest -> ("-", rest)
        rest -> ("", rest)
  (whole, afterWhole) <- case afterSign of
    '0' : rest -> Right ("0", rest)
    c : rest | c >= '1' && c <= '9' -> let (more, rest') = span isDigit rest in Right (c : more, rest')
    _ -> Left (DecodeError "Expecting value" start)
  let (fraction, afterFraction) = case afterWhole of
        '.' : d : rest | isDigit d -> let (more, rest') = span isDigit rest in ('.' : d : more, rest')
        rest -> ("", rest)
      (exponent', afterExponent) = case afterFraction of
        e : rest
          | e == 'e' || e == 'E' ->
              let (signPart, unsigned) = case rest of
                    s : more | s == '+' || s == '-' -> ([s], more)
                    more -> ("", more)
                  (digits, rest') = span isDigit unsigned
               in if null digits then ("", afterFraction) else (e : signPart ++ digits, rest')
        _ -> ("", afterFraction)
      token = sign ++ whole ++ fraction ++ exponent'
      end = start + length token
  if null fraction && null exponent'
    then case hooks.parseInt token of
      Left e -> Left (HookError e)
      Right value -> Right (RInt value, end, afterExponent)
    else case hooks.parseFloat token of
      Left e -> Left (HookError e)
      Right value -> Right (RFloat value, end, afterExponent)

-- | @scanstring_unicode@ in strict mode, starting just after the opening
-- quote at @start - 1@.
scanString :: Int -> String -> Scan e (String, Int, String)
scanString start = go start []
  where
    begin = start - 1
    unterminated = Left (DecodeError "Unterminated string starting at" begin)
    go i acc = \case
      [] -> unterminated
      '"' : rest -> Right (reverse acc, i + 1, rest)
      '\\' : rest -> escape i acc rest
      c : rest
        | c <= '\x1f' -> Left (DecodeError "Invalid control character at" i)
        | otherwise -> go (i + 1) (c : acc) rest
    -- @i@ is the backslash's position; @rest@ follows it.
    escape i acc = \case
      [] -> unterminated
      'u' : rest -> unicodeEscape i acc rest
      c : rest -> case simple c of
        Just decoded -> go (i + 2) (decoded : acc) rest
        Nothing -> Left (DecodeError "Invalid \\escape" i)
    simple = \case
      '"' -> Just '"'
      '\\' -> Just '\\'
      '/' -> Just '/'
      'b' -> Just '\b'
      'f' -> Just '\f'
      'n' -> Just '\n'
      'r' -> Just '\r'
      't' -> Just '\t'
      _ -> Nothing
    -- CPython needs four hex digits /and/ one more character after them.
    unicodeEscape i acc rest
      | length (take 5 rest) < 5 = Left (DecodeError "Invalid \\uXXXX escape" (i + 1))
      | otherwise = case hex4 (take 4 rest) of
          Nothing -> Left (DecodeError "Invalid \\uXXXX escape" (i + 1))
          Just high -> do
            let afterFirst = drop 4 rest
            if high >= 0xD800 && high <= 0xDBFF && length (take 7 afterFirst) == 7
              then case afterFirst of
                '\\' : 'u' : more -> case hex4 (take 4 more) of
                  Nothing -> Left (DecodeError "Invalid \\uXXXX escape" (i + 7))
                  Just low
                    | low >= 0xDC00 && low <= 0xDFFF ->
                        let joined = 0x10000 + ((high - 0xD800) `shiftL` 10) .|. (low - 0xDC00)
                         in go (i + 12) (chr joined : acc) (drop 4 more)
                    | otherwise -> go (i + 6) (chr high : acc) afterFirst
                _ -> go (i + 6) (chr high : acc) afterFirst
              else go (i + 6) (chr high : acc) afterFirst
    hex4 :: String -> Maybe Int
    hex4 digits = foldl (\acc d -> (\a v -> a * 16 + v) <$> acc <*> hexValue d) (Just 0) digits
    hexValue d
      | d >= '0' && d <= '9' = Just (ord d - ord '0')
      | d >= 'a' && d <= 'f' = Just (ord d - ord 'a' + 10)
      | d >= 'A' && d <= 'F' = Just (ord d - ord 'A' + 10)
      | otherwise = Nothing

-- | @_parse_object_unicode@, starting just after the opening brace.
parseObject :: Hooks e -> Int -> String -> Scan e (Raw, Int, String)
parseObject hooks start input =
  let (i, rest) = skipWs start input
   in case rest of
        '}' : after -> close [] (i + 1) after
        _ -> member [] i rest
  where
    member acc i = \case
      '"' : rest -> do
        (key, afterKey, rest') <- scanString (i + 1) rest
        let (colonAt, beforeColon) = skipWs afterKey rest'
        case beforeColon of
          ':' : afterColon -> do
            let (valueAt, valueInput) = skipWs (colonAt + 1) afterColon
            (value, afterValue, rest'') <- scanOnce hooks valueAt valueInput
            let acc' = (key, value) : acc
                (j, next) = skipWs afterValue rest''
            case next of
              '}' : after -> close (reverse acc') (j + 1) after
              ',' : after ->
                let (k, following) = skipWs (j + 1) after
                 in case following of
                      '}' : _ -> Left (DecodeError "Illegal trailing comma before end of object" j)
                      _ -> member acc' k following
              _ -> Left (DecodeError "Expecting ',' delimiter" j)
          _ -> Left (DecodeError "Expecting ':' delimiter" colonAt)
      _ -> Left (DecodeError "Expecting property name enclosed in double quotes" i)
    close pairs end after = case hooks.objectPairs pairs of
      Left e -> Left (HookError e)
      Right () -> Right (RDict pairs, end, after)

-- | @_parse_array_unicode@, starting just after the opening bracket.
parseArray :: Hooks e -> Int -> String -> Scan e (Raw, Int, String)
parseArray hooks start input =
  let (i, rest) = skipWs start input
   in case rest of
        ']' : after -> Right (RList [], i + 1, after)
        _ -> item [] i rest
  where
    item acc i input' = do
      (value, afterValue, rest) <- scanOnce hooks i input'
      let acc' = value : acc
          (j, next) = skipWs afterValue rest
      case next of
        ']' : after -> Right (RList (reverse acc'), j + 1, after)
        ',' : after ->
          let (k, following) = skipWs (j + 1) after
           in case following of
                ']' : _ -> Left (DecodeError "Illegal trailing comma before end of array" j)
                _ -> item acc' k following
        _ -> Left (DecodeError "Expecting ',' delimiter" j)

-- | CPython's @int(token)@: refuses more than 4300 digits (the default
-- @sys.get_int_max_str_digits()@) with CPython's 'ValueError' text.
defaultInt :: String -> Either Text Integer
defaultInt token =
  let digits = length (filter isDigit token)
   in if digits > 4300
        then
          Left
            ( "Exceeds the limit (4300 digits) for integer string conversion: value has "
                <> tshow digits
                <> " digits; use sys.set_int_max_str_digits() to increase the limit"
            )
        else Right (read token)

-- | CPython's @float(token)@ for a JSON number token: correctly rounded,
-- overflowing to infinity rather than failing.
defaultFloat :: String -> Double
defaultFloat token =
  let negative = take 1 token == "-"
      unsigned = if negative then drop 1 token else token
      (mantissa, exponentPart) = break (\c -> c == 'e' || c == 'E') unsigned
      (whole, fractionWithDot) = break (== '.') mantissa
      fraction = drop 1 fractionWithDot
      digits = dropWhile (== '0') (whole ++ fraction)
      expo = case exponentPart of
        [] -> 0
        _ : rest -> readSigned rest
      scale = expo - toInteger (length fraction)
      magnitude
        | null digits = 0
        | toInteger (length digits) + scale > 400 = 1 / 0
        | toInteger (length digits) + scale < -400 = 0
        | otherwise = fromRational (fromInteger (read digits) * (10 ^^ scale)) :: Double
   in if negative then negate magnitude else magnitude
  where
    readSigned :: String -> Integer
    readSigned = \case
      '+' : rest -> read rest
      '-' : rest -> negate (read rest)
      rest -> read rest
