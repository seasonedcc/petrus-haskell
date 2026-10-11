-- | CPython's @str@ semantics that more than one Hamsterdan subsystem
-- depends on: @str.isspace()@, @strip()@, @casefold()@, @isprintable()@,
-- @len(value.encode())@, @int(value, base)@ and @uuid.UUID@'s spelling,
-- @bytes.decode("utf-8")@'s refusal, and the uncaught CPython exception
-- ('PythonFault') those can raise.
--
-- Upstream these are the standard library, which every subsystem may use.
-- Here they live in the shared contracts package, so the agents, GitHub,
-- operator and CLI ports reach them without importing one another
-- (upstream @tests/test_architecture.py@, checked here by
-- @scripts/lint-hamsterdan-architecture@).
module Hamsterdan.PyText
  ( isSpace
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
  , utf8DecodeError
  , utf8EncodeError
  , PythonFault (..)
  , dumpsFault
  , raisingDumps
  ) where

import Control.Exception (Exception, throw)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (GeneralCategory (DecimalNumber), generalCategory, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Hamsterdan.PyLiteral.Printable (isPrintableNonAscii)
import Numeric (showHex)
import Petrus.Json (EncodeError (..), encodeErrorMessage)

-- | An exception the reference does not catch. It propagates to the caller
-- exactly where CPython's would, so a host can treat it the same way (for
-- example, as an HTTP 500, or by recording its class name).
data PythonFault = PythonFault
  { pythonClass :: Text
  , pythonDetail :: Text
  }
  deriving stock (Eq, Show)

instance Exception PythonFault

-- | The exception @json.dumps@ raises where the encoder refuses a value:
-- @RecursionError@ for one nested too deep, @ValueError@ otherwise (a
-- non-finite float under @allow_nan=False@, an integer past the digit
-- limit).
dumpsFault :: EncodeError -> PythonFault
dumpsFault refusal = PythonFault cls (T.pack (encodeErrorMessage refusal))
  where
    cls = case refusal of
      NestingTooDeep _ -> "RecursionError"
      _ -> "ValueError"

-- | A @json.dumps@ result, raising where the encoder refused: the
-- 'dumpsFault' of the refusal propagates as CPython's exception would.
raisingDumps :: Either EncodeError a -> a
raisingDumps = either (throw . dumpsFault) id

-- | @bytes.decode("utf-8")@ (strict): 'Nothing' when the bytes are UTF-8,
-- otherwise the @UnicodeDecodeError@'s @str()@ for the first undecodable
-- sequence, as CPython's decoder delimits it: a byte that cannot start a
-- sequence is an "invalid start byte"; otherwise the start byte and the
-- continuation bytes that were valid are an "invalid continuation byte"
-- when another byte follows them, and "unexpected end of data" when the
-- input ends.
utf8DecodeError :: ByteString -> Maybe Text
utf8DecodeError bytes = scan 0
  where
    size = BS.length bytes
    at = BS.index bytes
    scan i
      | i >= size = Nothing
      | at i < 0x80 = scan (i + 1)
      | otherwise = case sequenceOf (at i) of
          Nothing -> Just (failure i 1 "invalid start byte")
          Just (need, low, high) ->
            let valid = continuations (i + 1) need low high 0
             in if valid == need
                  then scan (i + 1 + need)
                  else
                    if i + 1 + valid >= size
                      then Just (failure i (1 + valid) "unexpected end of data")
                      else Just (failure i (1 + valid) "invalid continuation byte")
    -- The continuation bytes a start byte needs, and the range of the first.
    sequenceOf :: Word8 -> Maybe (Int, Word8, Word8)
    sequenceOf b
      | b >= 0xC2 && b <= 0xDF = Just (1, 0x80, 0xBF)
      | b == 0xE0 = Just (2, 0xA0, 0xBF)
      | b == 0xED = Just (2, 0x80, 0x9F)
      | b >= 0xE1 && b <= 0xEF = Just (2, 0x80, 0xBF)
      | b == 0xF0 = Just (3, 0x90, 0xBF)
      | b >= 0xF1 && b <= 0xF3 = Just (3, 0x80, 0xBF)
      | b == 0xF4 = Just (3, 0x80, 0x8F)
      | otherwise = Nothing
    continuations j need low high valid
      | valid == need || j >= size = valid
      | otherwise =
          let c = at j
              (lo, hi) = if valid == 0 then (low, high) else (0x80, 0xBF)
           in if c >= lo && c <= hi then continuations (j + 1) need low high (valid + 1) else valid
    failure :: Int -> Int -> Text -> Text
    failure start len reason
      | len == 1 = "'utf-8' codec can't decode byte 0x" <> hex2 (at start) <> " in position " <> tshow start <> ": " <> reason
      | otherwise = "'utf-8' codec can't decode bytes in position " <> tshow start <> "-" <> tshow (start + len - 1) <> ": " <> reason
    hex2 b = T.justifyRight 2 '0' (T.pack (showHex b ""))
    tshow = T.pack . show

-- | @value.encode()@ (strict UTF-8): 'Nothing' when it succeeds, otherwise
-- the @UnicodeEncodeError@'s @str()@ for the first run of surrogate code
-- points, as CPython words it (CPython's @sqlite3@ raises the same error
-- when it binds such a @str@).
--
-- A 'Text' holds a surrogate only in the WTF-8 form petrus-json's
-- @Petrus.Json.Wtf8@ gives a lone-surrogate escape the reader keeps
-- (CPython's @json.loads@ keeps it in a @str@); iterating such a 'Text'
-- yields the surrogate as one 'Char'. Every other 'Text' encodes.
utf8EncodeError :: Text -> Maybe Text
utf8EncodeError value
  | not (T.any isSurrogate value) = Nothing
  | otherwise = case break (isSurrogate . snd) (zip [0 :: Int ..] (T.unpack value)) of
      (_, []) -> Nothing
      (_, (start, first) : rest) ->
        let run = 1 + length (takeWhile (isSurrogate . snd) rest)
         in Just $
              if run == 1
                then "'utf-8' codec can't encode character '\\u" <> hex4 first <> "' in position " <> tshow start <> ": surrogates not allowed"
                else "'utf-8' codec can't encode characters in position " <> tshow start <> "-" <> tshow (start + run - 1) <> ": surrogates not allowed"
  where
    isSurrogate c = c >= '\xD800' && c <= '\xDFFF'
    hex4 c = T.pack (showHex (ord c) "")
    tshow = T.pack . show

-- | @str.isspace()@ for one character.
isSpace :: Char -> Bool
isSpace c =
  (c >= '\t' && c <= '\r')
    || (c >= '\x1c' && c <= ' ')
    || c == '\x85'
    || c == '\xa0'
    || c == '\x1680'
    || (c >= '\x2000' && c <= '\x200a')
    || c == '\x2028'
    || c == '\x2029'
    || c == '\x202f'
    || c == '\x205f'
    || c == '\x3000'

-- | @str.strip()@.
strip :: Text -> Text
strip = T.dropAround isSpace

-- | @str.lstrip()@.
lstrip :: Text -> Text
lstrip = T.dropWhile isSpace

-- | @str.casefold()@ (full case folding).
casefold :: Text -> Text
casefold = T.toCaseFold

-- | @str.upper()@ (full case mapping).
upper :: Text -> Text
upper = T.toUpper

-- | @str.isascii()@.
isAscii :: Text -> Bool
isAscii = T.all (< '\x80')

-- | @str.isprintable()@.
isPrintable :: Text -> Bool
isPrintable = T.all printable
  where
    printable c
      | c < '\x80' = c >= ' ' && c /= '\x7f'
      | otherwise = isPrintableNonAscii (ord c)

-- | @value.isascii() and value.isdecimal()@.
isAsciiDecimal :: Text -> Bool
isAsciiDecimal value = not (T.null value) && T.all (\c -> c >= '0' && c <= '9') value

-- | @len(value.encode())@.
utf8Length :: Text -> Int
utf8Length = BS.length . TE.encodeUtf8

-- | @int(value, base)@ for bases 10 and 16: surrounding whitespace, a sign,
-- the @0x@ prefix in base 16, Unicode decimal digits, and single
-- underscores between digits.
pyIntBase :: Int -> Text -> Maybe Integer
pyIntBase base input = do
  let trimmed = strip input
  (sign, unsigned) <- case T.uncons trimmed of
    Just ('-', rest) -> Just (negate, rest)
    Just ('+', rest) -> Just (id, rest)
    _ -> Just (id, trimmed)
  (afterPrefix, prefixed) <-
    if base == 16 && (T.isPrefixOf "0x" unsigned || T.isPrefixOf "0X" unsigned)
      then Just (T.drop 2 unsigned, True)
      else Just (unsigned, False)
  digits <- groups prefixed (T.unpack afterPrefix)
  if null digits then Nothing else Just (sign (foldl (\total d -> total * toInteger base + toInteger d) 0 digits))
  where
    -- Underscores may separate digits, and may follow a base prefix.
    groups prefixed = \case
      '_' : rest | prefixed -> body rest
      chars -> body chars
    body = \case
      [] -> Nothing
      chars -> go chars
    go = \case
      [] -> Just []
      c : '_' : rest -> case rest of
        next : _ | next /= '_' -> (:) <$> digit c <*> go rest
        _ -> Nothing
      c : rest -> (:) <$> digit c <*> go rest
    digit c
      | c >= '0' && c <= '9' = Just (ord c - ord '0')
      | base == 16 && c >= 'a' && c <= 'f' = Just (ord c - ord 'a' + 10)
      | base == 16 && c >= 'A' && c <= 'F' = Just (ord c - ord 'A' + 10)
      | c > '\x7f' && generalCategory c == DecimalNumber = Just (unicodeDigit c)
      | otherwise = Nothing
    unicodeDigit c = (ord c - runStart (ord c)) `mod` 10
    runStart n = if n > 0 && generalCategory (toEnum (n - 1)) == DecimalNumber then runStart (n - 1) else n

-- | @str(uuid.UUID(value))@: the canonical lowercase spelling, or 'Nothing'
-- where the constructor raises @ValueError@.
canonicalUuid :: Text -> Maybe Text
canonicalUuid value = do
  let hex = T.replace "-" "" (T.dropAround (\c -> c == '{' || c == '}') (T.replace "uuid:" "" (T.replace "urn:" "" value)))
  if T.length hex /= 32 then Nothing else Just ()
  number <- pyIntBase 16 hex
  if number < 0 || number >= 2 ^ (128 :: Int) then Nothing else Just ()
  let digits = T.justifyRight 32 '0' (T.pack (showHex number ""))
      part from size = T.take size (T.drop from digits)
  Just (T.intercalate "-" [part 0 8, part 8 4, part 12 4, part 16 4, part 20 12])
