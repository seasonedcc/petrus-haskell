-- | CPython's @str@ and @bytes@ semantics that more than one Hamsterdan
-- subsystem depends on: @str.isspace()@, @strip()@, @split()@,
-- @splitlines()@, @casefold()@, @isprintable()@, @repr()@,
-- @len(value.encode())@, @int(value, base)@, @uuid.UUID@'s spelling, and
-- strict UTF-8 @bytes.decode()@ and @str.encode()@ with the exception they
-- raise.
--
-- Upstream these are the standard library, which every subsystem may use.
-- Here they live in the shared contracts package, so the agents, GitHub,
-- operator and CLI ports reach them without importing one another
-- (upstream @tests/test_architecture.py@, checked here by
-- @scripts/lint-hamsterdan-architecture@). The predicates, the
-- @repr@ and the codecs are petrus-json's ("Petrus.Json.Python", generated
-- from and checked against CPython 3.14 / Unicode 16.0), under the names
-- the Hamsterdan ports read like the reference with.
module Hamsterdan.Python.Text
  ( -- * @str@
    isSpace
  , isAscii
  , isPrintable
  , isAsciiDecimal
  , strip
  , lstrip
  , rstrip
  , split
  , splitlines
  , casefold
  , upper
  , utf8Length
  , strRepr

    -- * @bytes@
  , splitlinesUtf8

    -- * @int()@ and @uuid.UUID@
  , intText
  , pyIntBase
  , canonicalUuid

    -- * Strict UTF-8
  , utf8Decode
  , utf8Encode
  , utf8DecodeError
  , utf8EncodeError
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BU
import Data.Char (ord)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Numeric (showHex)
import Petrus.Json.Limits (intStrDigitsError, maxIntStrDigits)
import Petrus.Json.Python
  ( PythonException
  , pythonError
  , isPythonPrintable
  , isPythonSpace
  , pythonDecimal
  , pythonLstrip
  , pythonRstrip
  , pythonSplit
  , pythonSplitlines
  , pythonStrRepr
  , pythonStrip
  , unicodeDecodeError
  , unicodeEncodeError
  , utf8DecodeError
  , utf8DecodeFailure
  , utf8EncodeError
  , utf8EncodeFailure
  )

-- | @str.isspace()@ for one character.
isSpace :: Char -> Bool
isSpace = isPythonSpace

-- | @str.isascii()@.
isAscii :: Text -> Bool
isAscii = T.all (< '\x80')

-- | @str.isprintable()@.
isPrintable :: Text -> Bool
isPrintable = T.all isPythonPrintable

-- | @value.isascii() and value.isdecimal()@.
isAsciiDecimal :: Text -> Bool
isAsciiDecimal value = not (T.null value) && T.all (\c -> c >= '0' && c <= '9') value

-- | @str.strip()@.
strip :: Text -> Text
strip = pythonStrip

-- | @str.lstrip()@.
lstrip :: Text -> Text
lstrip = pythonLstrip

-- | @str.rstrip()@.
rstrip :: Text -> Text
rstrip = pythonRstrip

-- | @str.split()@.
split :: Text -> [Text]
split = pythonSplit

-- | @str.splitlines()@.
splitlines :: Text -> [Text]
splitlines = pythonSplitlines

-- | @str.casefold()@ (full case folding).
casefold :: Text -> Text
casefold = T.toCaseFold

-- | @str.upper()@ (full case mapping).
upper :: Text -> Text
upper = T.toUpper

-- | @len(value.encode())@.
utf8Length :: Text -> Int
utf8Length = BS.length . TE.encodeUtf8

-- | @repr(value)@ of a @str@.
strRepr :: Text -> Text
strRepr = pythonStrRepr

-- | @str.splitlines()@ over UTF-8 text, on its bytes: the line breaks are
-- @\\n \\v \\f \\r \\x1c \\x1d \\x1e@ (one byte each), @\\x85@ (C2 85) and
-- @\\u2028 \\u2029@ (E2 80 A8, E2 80 A9), and @\\r\\n@ breaks once. In
-- UTF-8 those sequences only ever encode those code points, and a
-- one-byte boundary never occurs inside a longer sequence, so each line is
-- the encoding of the reference's line.
splitlinesUtf8 :: ByteString -> [ByteString]
splitlinesUtf8 bytes = go 0 0
  where
    size = BS.length bytes
    at i = BU.unsafeIndex bytes i
    candidate b = (b >= 0x0A && b <= 0x0D) || (b >= 0x1C && b <= 0x1E) || b == 0xC2 || b == 0xE2
    slice start end = BU.unsafeTake (end - start) (BU.unsafeDrop start bytes)
    -- @start@ begins the current line; @from@ is where to look for its end.
    go !start !from = case BS.findIndex candidate (BU.unsafeDrop from bytes) of
      Nothing -> [slice start size | size > start]
      Just offset ->
        let i = from + offset
         in case breakWidth i (at i) of
              0 -> go start (i + 1)
              width -> slice start i : go (i + width) (i + width)
    breakWidth i b
      | b == 0x0D = if i + 1 < size && at (i + 1) == 0x0A then 2 else 1
      | b == 0xC2 = if i + 1 < size && at (i + 1) == 0x85 then 2 else 0
      | b == 0xE2 = if i + 2 < size && at (i + 1) == 0x80 && (at (i + 2) == 0xA8 || at (i + 2) == 0xA9) then 3 else 0
      | otherwise = 1 :: Int

-- | @int(value)@ for a @str@: 'pyIntBase' 10, or the @ValueError@ CPython
-- raises: @invalid literal@ with the value's @repr@ cut to 200 characters
-- (@%.200R@), or, for a well-formed value of more than 4300 digits, the
-- conversion limit.
intText :: Text -> Either PythonException Integer
intText value = case pyIntBase 10 value of
  Nothing -> Left (pythonError "ValueError" ("invalid literal for int() with base 10: " <> T.take 200 (strRepr value)))
  Just number
    | digits > maxIntStrDigits -> Left (pythonError "ValueError" (T.pack (intStrDigitsError maxIntStrDigits digits)))
    | otherwise -> Right number
  where
    digits = T.length (T.filter (isJust . pythonDecimal) value)

-- | @int(value, base)@ for bases 10 and 16: surrounding whitespace, a sign,
-- the @0x@ prefix in base 16, Unicode decimal digits, and single
-- underscores between digits.
--
-- The whitespace is not @str.strip@'s: CPython maps non-ASCII whitespace
-- to a space and then skips C's @isspace@ set, so @\\x1c@–@\\x1f@ (which
-- @str.isspace@ accepts) are not stripped.
pyIntBase :: Int -> Text -> Maybe Integer
pyIntBase base input = do
  let trimmed = T.dropAround intSpace input
      intSpace c = if c < '\x80' then c `elem` (" \t\n\v\f\r" :: String) else isSpace c
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
      | base == 16 && c >= 'a' && c <= 'f' = Just (ord c - ord 'a' + 10)
      | base == 16 && c >= 'A' && c <= 'F' = Just (ord c - ord 'A' + 10)
      | otherwise = pythonDecimal c

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

-- | @value.decode()@ (strict UTF-8): the text, or the @UnicodeDecodeError@.
utf8Decode :: ByteString -> Either PythonException Text
utf8Decode bytes = case utf8DecodeFailure bytes of
  Nothing -> Right (TE.decodeUtf8 bytes)
  Just failure -> Left (unicodeDecodeError bytes failure)

-- | @value.encode()@ (strict UTF-8): the bytes, or the @UnicodeEncodeError@
-- for the first run of surrogates. A 'Text' holds a surrogate only in the
-- WTF-8 form petrus-json gives a lone surrogate CPython's @json.loads@
-- keeps in a @str@ ("Petrus.Json.Wtf8"); every other 'Text' encodes.
utf8Encode :: Text -> Either PythonException ByteString
utf8Encode text = case utf8EncodeFailure text of
  Nothing -> Right (TE.encodeUtf8 text)
  Just failure -> Left (unicodeEncodeError text failure)
