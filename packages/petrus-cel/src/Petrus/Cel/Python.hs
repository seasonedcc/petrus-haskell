-- | The handful of CPython 3.14 primitives cel-python's observable behaviour
-- rests on: @repr@ of strings, bytes, and floats; @int()@ and @float()@
-- string parsing; and the numeric hash that decides which dictionary keys
-- are ever compared.
module Petrus.Cel.Python
  ( -- * repr
    strRepr
  , bytesRepr
  , floatRepr
    -- * Parsing
  , asciiTransform
  , parseIntDigits
  , parseFloatText
  , intMaxStrDigits
    -- * Hashing
  , hashInteger
  , hashRational
  , hashDouble
    -- * Exceptions
  , ExcClass (..)
  , excClassName
  , excClassRepr
  , isValueError
  , PyErr (..)
    -- * Number formatting
  , roundHalfEven
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr, isAsciiLower, isAsciiUpper, isDigit, ord, toLower)
import Data.Ratio (denominator, numerator)
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)

import Petrus.Cel.Unicode (isPythonPrintable, isPythonSpace, pythonDecimal)
import Petrus.Json.Encode (pythonFloatRepr)

-- | CPython's @repr()@ of a @str@.
strRepr :: Text -> Text
strRepr s = T.pack (quote : concatMap escape (T.unpack s) <> [quote])
  where
    quote = if T.any (== '\'') s && not (T.any (== '"') s) then '"' else '\''
    escape c
      | c == quote || c == '\\' = ['\\', c]
      | c == '\t' = "\\t"
      | c == '\n' = "\\n"
      | c == '\r' = "\\r"
      | c < ' ' || c == '\x7f' = hexEscape 'x' 2 (ord c)
      | c < '\x7f' = [c]
      | isPythonPrintable c = [c]
      | ord c <= 0xff = hexEscape 'x' 2 (ord c)
      | ord c <= 0xffff = hexEscape 'u' 4 (ord c)
      | otherwise = hexEscape 'U' 8 (ord c)

hexEscape :: Char -> Int -> Int -> String
hexEscape tag width n =
  let digits = showHex n ""
   in '\\' : tag : replicate (width - length digits) '0' <> digits

-- | CPython's @repr()@ of a @bytes@ object.
bytesRepr :: ByteString -> Text
bytesRepr b = T.pack ('b' : quote : concatMap escape (BS.unpack b) <> [quote])
  where
    hasSingle = BS.elem 0x27 b
    hasDouble = BS.elem 0x22 b
    quote = if hasSingle && not hasDouble then '"' else '\''
    escape w
      | c == quote || c == '\\' = ['\\', c]
      | c == '\t' = "\\t"
      | c == '\n' = "\\n"
      | c == '\r' = "\\r"
      | w < 0x20 || w >= 0x7f = hexEscape 'x' 2 (fromIntegral w)
      | otherwise = [c]
      where
        c = chr (fromIntegral w)

-- | CPython's @repr()@ of a @float@ (shortest round-tripping digits).
floatRepr :: Double -> Text
floatRepr d
  | isNaN d = "nan"
  | isInfinite d = if d > 0 then "inf" else "-inf"
  | otherwise = T.pack (pythonFloatRepr d)

-- | CPython's @_PyUnicode_TransformDecimalAndSpaceToASCII@: Unicode
-- whitespace becomes a space, Unicode decimal digits become ASCII digits,
-- and any other non-ASCII character becomes @?@ (so it can never parse).
asciiTransform :: Text -> String
asciiTransform = map one . T.unpack
  where
    one c
      | isPythonSpace c = ' '
      | Just d <- pythonDecimal c = chr (ord '0' + d)
      | ord c < 128 = c
      | otherwise = '?'

isAsciiSpace :: Char -> Bool
isAsciiSpace c = c `elem` (" \t\n\r\x0b\x0c" :: String)

-- | The default @sys.get_int_max_str_digits()@.
intMaxStrDigits :: Int
intMaxStrDigits = 4300

-- | CPython's @PyLong_FromString@ for an explicit base (8, 10, or 16) over an
-- already ASCII-transformed string: surrounding whitespace, a sign, the base
-- prefix (@0x@/@0o@) with one optional underscore after it, and digits with
-- single underscores between them. @Left True@ reports the 4300-digit limit.
parseIntDigits :: Int -> String -> Either Bool Integer
parseIntDigits base input =
  let trimmed = dropWhileEnd' isAsciiSpace (dropWhile isAsciiSpace input)
      (negative, unsigned) = case trimmed of
        '+' : rest -> (False, rest)
        '-' : rest -> (True, rest)
        rest -> (False, rest)
      (prefixed, body) = case unsigned of
        '0' : x : rest
          | base == 16 && (x == 'x' || x == 'X') -> (True, rest)
          | base == 8 && (x == 'o' || x == 'O') -> (True, rest)
        rest -> (False, rest)
      body' = case body of
        '_' : rest | prefixed -> rest
        rest -> rest
   in case digitsOf body' of
        Nothing -> Left False
        Just ds
          | base == 10 && length ds > intMaxStrDigits -> Left True
          | otherwise ->
              let v = foldl (\acc d -> acc * fromIntegral base + fromIntegral d) 0 ds
               in Right (if negative then negate v else v)
  where
    digitOf c
      | isDigit c = Just (ord c - ord '0')
      | isAsciiLower c = Just (ord c - ord 'a' + 10)
      | isAsciiUpper c = Just (ord c - ord 'A' + 10)
      | otherwise = Nothing
    valid c = maybe False (< base) (digitOf c)
    digitsOf s = case s of
      [] -> Nothing
      c : _ | not (valid c) -> Nothing
      _ -> go s
    go = \case
      [] -> Just []
      '_' : c : rest | valid c -> go (c : rest)
      c : rest | valid c, Just d <- digitOf c -> (d :) <$> go rest
      _ -> Nothing

dropWhileEnd' :: (a -> Bool) -> [a] -> [a]
dropWhileEnd' p = reverse . dropWhile p . reverse

-- | CPython's @float()@ of a string: surrounding whitespace, underscores only
-- between digits, @inf@/@infinity@/@nan@ in any case, and a correctly
-- rounded decimal otherwise.
parseFloatText :: Text -> Maybe Double
parseFloatText text = parseFloatAscii (asciiTransform text)

parseFloatAscii :: String -> Maybe Double
parseFloatAscii input = do
  let trimmed = dropWhileEnd' isAsciiSpace (dropWhile isAsciiSpace input)
  cleaned <- underscores trimmed
  let (negative, unsigned) = case cleaned of
        '+' : rest -> (False, rest)
        '-' : rest -> (True, rest)
        rest -> (False, rest)
      signed v = if negative then negate v else v
  signed <$> case map toLower unsigned of
    "inf" -> Just (1 / 0)
    "infinity" -> Just (1 / 0)
    "nan" -> Just (0 / 0)
    _ -> decimal unsigned
  where
    underscores s = go Nothing s
      where
        go _ [] = Just []
        go prev ('_' : rest) = case (prev, rest) of
          (Just p, n : _) | isDigit p && isDigit n -> go Nothing rest
          _ -> Nothing
        go _ (c : rest) = (c :) <$> go (Just c) rest
    decimal s = do
      let (intPart, afterInt) = span isDigit s
      (fracPart, afterFrac) <- case afterInt of
        '.' : rest -> Just (span isDigit rest)
        rest -> Just ("", rest)
      if null intPart && null fracPart then Nothing else Just ()
      expPart <- case afterFrac of
        [] -> Just 0
        e : rest | e == 'e' || e == 'E' -> case rest of
          '+' : ds | not (null ds), all isDigit ds -> Just (read ds)
          '-' : ds | not (null ds), all isDigit ds -> Just (negate (read ds))
          ds | not (null ds), all isDigit ds -> Just (read ds)
          _ -> Nothing
        _ -> Nothing
      let digits = dropWhile (== '0') (intPart <> fracPart)
          mantissa = if null digits then 0 else read digits :: Integer
          exponent' = (expPart :: Integer) - fromIntegral (length fracPart)
      pure (scaled mantissa exponent')
    scaled 0 _ = 0
    scaled m e
      | e + fromIntegral (length (show m)) > 400 = 1 / 0
      | e + fromIntegral (length (show m)) < -400 = 0
      | e >= 0 = fromRational (fromIntegral (m * 10 ^ e))
      | otherwise = fromRational (fromIntegral m / fromIntegral (10 ^ negate e :: Integer))

-- | The modulus of CPython's numeric hash, @2**61 - 1@.
hashModulus :: Integer
hashModulus = 2 ^ (61 :: Int) - 1

-- | CPython's @hash()@ of an integer.
hashInteger :: Integer -> Integer
hashInteger n =
  let h = (abs n `mod` hashModulus) * signum n
   in if h == -1 then -2 else h

-- | CPython's @hash()@ of an exact rational number (the numeric tower's
-- shared definition: equal numbers hash equally across int and float).
hashRational :: Rational -> Integer
hashRational r =
  let p = numerator r
      q = denominator r
      inv = powMod (q `mod` hashModulus) (hashModulus - 2)
      h = ((abs p `mod` hashModulus) * inv) `mod` hashModulus
      signed = if p < 0 then negate h else h
   in if signed == -1 then -2 else signed
  where
    powMod _ 0 = 1
    powMod b e
      | even e = let x = powMod b (e `div` 2) in (x * x) `mod` hashModulus
      | otherwise = (b * powMod b (e - 1)) `mod` hashModulus

-- | CPython's @hash()@ of a float; 'Nothing' for NaN (hashed by identity).
hashDouble :: Double -> Maybe Integer
hashDouble d
  | isNaN d = Nothing
  | isInfinite d = Just (if d > 0 then 314159 else -314159)
  | otherwise = Just (hashRational (toRational d))

-- | The Python exception classes cel-python's behaviour can surface.
data ExcClass
  = TypeError
  | ValueError
  | KeyError
  | IndexError
  | ZeroDivisionError
  | OverflowError
  | AttributeError
  | AssertionError
  | UnicodeDecodeError
  | RecursionError
  | MemoryError
  | UnicodeEncodeError
  | -- | @celpy.evaluation.CELSyntaxError@
    CELSyntaxError
  | -- | @pendulum.parsing.exceptions.ParserError@ (a 'ValueError')
    ParserError
  | -- | @re2._re2.Error@ (google-re2's @re2.error@)
    Re2Error
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The class's @__name__@.
excClassName :: ExcClass -> Text
excClassName = \case
  TypeError -> "TypeError"
  ValueError -> "ValueError"
  KeyError -> "KeyError"
  IndexError -> "IndexError"
  ZeroDivisionError -> "ZeroDivisionError"
  OverflowError -> "OverflowError"
  AttributeError -> "AttributeError"
  AssertionError -> "AssertionError"
  UnicodeDecodeError -> "UnicodeDecodeError"
  RecursionError -> "RecursionError"
  MemoryError -> "MemoryError"
  UnicodeEncodeError -> "UnicodeEncodeError"
  CELSyntaxError -> "CELSyntaxError"
  ParserError -> "ParserError"
  Re2Error -> "Error"

-- | The class's @repr()@, e.g. @<class 'TypeError'>@.
excClassRepr :: ExcClass -> Text
excClassRepr cls = "<class '" <> qualified <> "'>"
  where
    qualified = case cls of
      CELSyntaxError -> "celpy.evaluation.CELSyntaxError"
      ParserError -> "pendulum.parsing.exceptions.ParserError"
      Re2Error -> "re2._re2.Error"
      _ -> excClassName cls

-- | Does an @except ValueError@ clause catch this class?
isValueError :: ExcClass -> Bool
isValueError = (`elem` [ValueError, UnicodeDecodeError, UnicodeEncodeError, ParserError])

-- | A raised Python exception whose only argument is a message.
data PyErr = PyErr ExcClass Text
  deriving stock (Eq, Show)

-- | Round a rational to the nearest integer, ties to even (Python's
-- @round()@ and the @datetime@ module's rounding).
roundHalfEven :: Rational -> Integer
roundHalfEven = round
