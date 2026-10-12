-- | CPython 3.14's string predicates, the @str@ methods built on them, and
-- @repr(str)@, exact for every code point.
--
-- The Petrus reference embeds @repr@ of strings in many error and
-- diagnostic texts, and @repr@ escapes exactly the characters for which
-- @str.isprintable@ is false; @str.strip@, @str.split@ and
-- @str.splitlines@ decide by @str.isspace@ and the line-boundary set, and
-- @int()@ reads every Unicode decimal digit. GHC's "Data.Char" follows the
-- Unicode version GHC ships (15.1 for GHC 9.10) and its 'Data.Char.isPrint'
-- admits the space separators, so neither can stand in for CPython's
-- predicates. The tables in "Petrus.Json.PythonText.Tables" are generated
-- from the pinned interpreter (CPython 3.14, Unicode 16.0) by
-- @gen/gen_python_tables.py@; the test suite checks 'isPythonPrintable' on
-- every code point 0..0x10FFFF against the committed vector
-- @test/python-printable.txt@, and every predicate on every code point
-- against the live interpreter.
--
-- This is the one home of these predicates: every Petrus and Hamsterdan
-- package imports them from here (or from the "Petrus.Json.Python"
-- umbrella) rather than keeping a table of its own.
module Petrus.Json.PythonText
  ( -- * Predicates
    isPythonPrintable
  , isPythonSpace
  , isPythonLineBreak
  , pythonDecimal
  , isPythonNumberSpace
    -- * @int()@ and @float()@
  , parsePythonInt
  , pythonInt
  , parsePythonFloat
    -- * @str@ methods
  , pythonStrip
  , pythonLstrip
  , pythonRstrip
  , pythonSplit
  , pythonSplitlines
  , pythonIsPrintableText
    -- * @repr(str)@
  , pythonStrRepr
  , pythonStringRepr
  ) where

import Data.Char (ord)
import Data.IntMap.Strict qualified as IntMap
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Array qualified as TA
import Data.Text.Internal qualified as TI
import Numeric (showHex)
import Petrus.Json.Limits (maxIntStrDigits)
import Petrus.Json.PythonText.Tables (decimalRuns, lineBreakRanges, printableRanges, spaceRanges)

rangeMap :: [(Int, Int)] -> IntMap.IntMap Int
rangeMap = IntMap.fromList

inRanges :: IntMap.IntMap Int -> Int -> Bool
inRanges ranges n = case IntMap.lookupLE n ranges of
  Just (_, high) -> n <= high
  Nothing -> False
{-# INLINE inRanges #-}

printable :: IntMap.IntMap Int
printable = rangeMap printableRanges
{-# NOINLINE printable #-}

spaces :: IntMap.IntMap Int
spaces = rangeMap spaceRanges
{-# NOINLINE spaces #-}

lineBreaks :: IntMap.IntMap Int
lineBreaks = rangeMap lineBreakRanges
{-# NOINLINE lineBreaks #-}

decimals :: IntMap.IntMap (Int, Int)
decimals = IntMap.fromList [(low, (count, first)) | (low, count, first) <- decimalRuns]
{-# NOINLINE decimals #-}

-- | CPython's @str.isprintable@ for one code point (a lone surrogate is never
-- printable).
isPythonPrintable :: Char -> Bool
isPythonPrintable c
  | n < 0x7F = n >= 0x20
  | n < 0xA1 = False
  | otherwise = inRanges printable n
  where
    n = ord c

-- | CPython's @str.isspace@ for one code point.
isPythonSpace :: Char -> Bool
isPythonSpace c
  | n < 0x80 = n == 0x20 || (n >= 0x09 && n <= 0x0D) || (n >= 0x1C && n <= 0x1F)
  | otherwise = inRanges spaces n
  where
    n = ord c

-- | Whether @str.splitlines@ breaks at this code point (@\\r\\n@ counts as
-- one boundary; see 'pythonSplitlines').
isPythonLineBreak :: Char -> Bool
isPythonLineBreak c = inRanges lineBreaks (ord c)

-- | CPython's @unicodedata.decimal@: the value of a decimal digit, which is
-- what @int()@ and @float()@ accept for each digit of their argument.
pythonDecimal :: Char -> Maybe Int
pythonDecimal c
  | n >= 0x30 && n <= 0x39 = Just (n - 0x30)
  | n < 0x660 = Nothing
  | otherwise = case IntMap.lookupLE n decimals of
      Just (low, (count, first)) | n < low + count -> Just (first + n - low)
      _ -> Nothing
  where
    n = ord c

-- | The whitespace @int()@ and @float()@ skip around a @str@ argument.
-- CPython turns each non-ASCII code point that @str.isspace@ accepts into a
-- space and then skips C's @isspace@ set, so @\\x1c@–@\\x1f@, which
-- @str.isspace@ accepts, are not skipped.
isPythonNumberSpace :: Char -> Bool
isPythonNumberSpace c
  | c < '\x80' = c == ' ' || (c >= '\t' && c <= '\r')
  | otherwise = isPythonSpace c

-- | CPython's @int(text, base)@ for a @str@ and a base from 2 to 36:
-- 'Nothing' where it raises @ValueError@. It skips 'isPythonNumberSpace'
-- around an optional sign, admits the base's prefix (@0x@, @0o@, @0b@,
-- either case), any Unicode decimal digit and ASCII letters as digits, and
-- single underscores between digits or after the prefix. The 4300-digit
-- conversion limit is the caller's.
parsePythonInt :: Int -> Text -> Maybe Integer
parsePythonInt base input = do
  let trimmed = T.dropAround isPythonNumberSpace input
  (sign, unsigned) <- case T.uncons trimmed of
    Just ('-', rest) -> Just (negate, rest)
    Just ('+', rest) -> Just (id, rest)
    _ -> Just (id, trimmed)
  let (body, prefixed) = case T.unpack (T.toLower (T.take 2 unsigned)) of
        ['0', p] | Just base == lookup p [('x', 16), ('o', 8), ('b', 2)] -> (T.drop 2 unsigned, True)
        _ -> (unsigned, False)
  digits <- case T.unpack body of
    '_' : rest | prefixed -> grouped rest
    chars -> grouped chars
  Just (sign (foldl (\total d -> total * toInteger base + toInteger d) 0 digits))
  where
    -- At least one digit; an underscore only between two digits.
    grouped [] = Nothing
    grouped chars = go chars
    go [] = Just []
    go (c : '_' : rest@(next : _)) | next /= '_' = (:) <$> digit c <*> go rest
    go (_ : '_' : _) = Nothing
    go (c : rest) = (:) <$> digit c <*> go rest
    digit c = valueOf c >>= \value -> if value < base then Just value else Nothing
    valueOf c
      | c >= 'a' && c <= 'z' = Just (ord c - ord 'a' + 10)
      | c >= 'A' && c <= 'Z' = Just (ord c - ord 'A' + 10)
      | otherwise = pythonDecimal c

-- | CPython's @int(text)@ for a @str@ (base 10), with its 4300-digit
-- conversion limit (leading zeros count): 'Nothing' where it raises
-- @ValueError@.
pythonInt :: Text -> Maybe Integer
pythonInt text = do
  value <- parsePythonInt 10 text
  if T.length (T.filter (isJust . pythonDecimal) text) > maxIntStrDigits then Nothing else Just value

-- | CPython's @float(text)@ for a @str@: 'Nothing' where it raises
-- @ValueError@ (@could not convert string to float@).
--
-- CPython first applies @_PyUnicode_TransformDecimalAndSpaceToASCII@: a
-- non-ASCII code point that @str.isspace@ accepts becomes a space, a
-- Unicode decimal digit ('pythonDecimal') its ASCII digit, and anything
-- else non-ASCII (@\\x7f@ included) a character no spelling admits. It then
-- skips C's @isspace@ set at both ends ('isPythonNumberSpace': so
-- @\\x1c@-@\\x1f@, which @str.isspace@ accepts, are refused) and reads an
-- optional sign, then @inf@, @infinity@ or @nan@ in any ASCII case, or a
-- decimal with an optional fraction and exponent, single underscores only
-- between two digits. The decimal is rounded to the nearest double, ties
-- to even (GHC's 'fromRational' rounds as @strtod@ does).
parsePythonFloat :: Text -> Maybe Double
parsePythonFloat input = do
  ascii <- traverse toAscii (T.unpack (T.dropAround isPythonNumberSpace input))
  cleaned <- underscores Nothing ascii
  let (negative, unsigned) = case cleaned of
        '+' : rest -> (False, rest)
        '-' : rest -> (True, rest)
        rest -> (False, rest)
  magnitude <- case map asciiLower unsigned of
    "inf" -> Just (1 / 0)
    "infinity" -> Just (1 / 0)
    "nan" -> Just (0 / 0)
    _ -> decimal unsigned
  pure (if negative then negate magnitude else magnitude)
  where
    toAscii c
      | c < '\x7f' = Just c
      | isPythonSpace c = Just ' '
      | otherwise = (\d -> toEnum (ord '0' + d)) <$> pythonDecimal c
    asciiLower c = if c >= 'A' && c <= 'Z' then toEnum (ord c + 32) else c
    digit c = c >= '0' && c <= '9'
    -- Drop each underscore that sits between two digits; refuse any other.
    underscores _ [] = Just []
    underscores previous ('_' : rest) = case (previous, rest) of
      (Just p, n : _) | digit p && digit n -> underscores Nothing rest
      _ -> Nothing
    underscores _ (c : rest) = (c :) <$> underscores (Just c) rest
    decimal text = do
      let (whole, afterWhole) = span digit text
          (fraction, afterFraction) = case afterWhole of
            '.' : rest -> span digit rest
            rest -> ("", rest)
      if null whole && null fraction then Nothing else Just ()
      exponent' <- case afterFraction of
        [] -> Just 0
        e : rest | e == 'e' || e == 'E' -> case rest of
          '+' : ds | not (null ds), all digit ds -> Just (read ds)
          '-' : ds | not (null ds), all digit ds -> Just (negate (read ds))
          ds | not (null ds), all digit ds -> Just (read ds)
          _ -> Nothing
        _ -> Nothing
      let significant = dropWhile (== '0') (whole <> fraction)
          mantissa = if null significant then 0 else read significant :: Integer
          scale = (exponent' :: Integer) - toInteger (length fraction)
          magnitude = scale + toInteger (length significant)
      pure (scaled mantissa scale magnitude)
    scaled :: Integer -> Integer -> Integer -> Double
    scaled mantissa scale magnitude
      | mantissa == 0 = 0
      -- Past every double's decimal exponent: no need to build the
      -- (possibly enormous) exact value.
      | magnitude > 400 = 1 / 0
      | magnitude < -400 = 0
      | scale >= 0 = fromRational (fromInteger (mantissa * 10 ^ scale))
      | otherwise = fromRational (fromInteger mantissa / fromInteger (10 ^ negate scale))

-- | @str.strip()@ (no argument): drop CPython whitespace at both ends.
pythonStrip :: Text -> Text
pythonStrip = T.dropAround isPythonSpace

-- | @str.lstrip()@ (no argument).
pythonLstrip :: Text -> Text
pythonLstrip = T.dropWhile isPythonSpace

-- | @str.rstrip()@ (no argument).
pythonRstrip :: Text -> Text
pythonRstrip = T.dropWhileEnd isPythonSpace

-- | @str.split()@ (no argument): the runs of non-whitespace.
pythonSplit :: Text -> [Text]
pythonSplit = filter (not . T.null) . T.split isPythonSpace

-- | @str.splitlines()@: every line boundary CPython recognises, with
-- @\\r\\n@ as one boundary and no trailing empty line.
pythonSplitlines :: Text -> [Text]
pythonSplitlines text
  | T.null text = []
  | otherwise =
      let (line, rest) = T.break isPythonLineBreak text
       in line : case T.uncons rest of
            Nothing -> []
            Just ('\r', more) | Just ('\n', after) <- T.uncons more -> pythonSplitlines after
            Just (_, more) -> pythonSplitlines more

-- | @str.isprintable()@ of a whole string (true for the empty string).
pythonIsPrintableText :: Text -> Bool
pythonIsPrintableText = T.all isPythonPrintable

-- | CPython's @repr(str)@: single quotes unless the text holds a single
-- quote and no double quote; the backslash, the chosen quote, @\\t@,
-- @\\n@ and @\\r@ escaped; every other character that is not printable
-- ('isPythonPrintable') as @\\xhh@, @\\uhhhh@ or @\\Uhhhhhhhh@.
--
-- The output is the text's printable runs, sliced (not copied character
-- by character), around the escapes, joined once; printable ASCII without
-- quotes or backslashes, the common case, is decided on the UTF-8 bytes.
pythonStrRepr :: Text -> Text
pythonStrRepr value
  | simpleAscii value = T.concat ["'", value, "'"]
  | T.all plain value = T.concat [quoteText, value, quoteText]
  | otherwise = T.concat (quoteText : runs value)
  where
    doubleQuoted = T.any (== '\'') value && not (T.any (== '"') value)
    quote = if doubleQuoted then '"' else '\''
    quoteText = T.singleton quote
    plain c = c /= quote && c /= '\\' && isPythonPrintable c
    runs remaining =
      let (run, after) = T.span plain remaining
       in run : case T.uncons after of
            Nothing -> [quoteText]
            Just (c, more) -> T.pack (escapeChar quote c) : runs more

-- | Whether a text is printable ASCII without quotes or backslashes (its
-- @repr@ is the text in single quotes), tested on the UTF-8 bytes.
simpleAscii :: Text -> Bool
simpleAscii (TI.Text array offset size) = go offset
  where
    end = offset + size
    go i
      | i >= end = True
      | otherwise =
          let w = TA.unsafeIndex array i
           in w >= 0x20 && w < 0x7F && w /= 0x27 && w /= 0x22 && w /= 0x5C && go (i + 1)

-- | CPython's @repr(str)@ over code points, which may include lone
-- surrogates (a 'Text' cannot hold them, but a scanned JSON key or a
-- @surrogateescape@-decoded file name can).
pythonStringRepr :: String -> Text
pythonStringRepr chars = T.pack ([quote] ++ concatMap (escapeChar quote) chars ++ [quote])
  where
    quote = if '\'' `elem` chars && '"' `notElem` chars then '"' else '\''

-- | One character as @repr(str)@ writes it inside the given quote.
escapeChar :: Char -> Char -> String
escapeChar quote c
  | c == quote || c == '\\' = ['\\', c]
  | c == '\t' = "\\t"
  | c == '\n' = "\\n"
  | c == '\r' = "\\r"
  | isPythonPrintable c = [c]
  | ord c < 0x100 = "\\x" ++ pad 2 (ord c)
  | ord c < 0x10000 = "\\u" ++ pad 4 (ord c)
  | otherwise = "\\U" ++ pad 8 (ord c)
  where
    pad width n = let digits = showHex n "" in replicate (width - length digits) '0' ++ digits
