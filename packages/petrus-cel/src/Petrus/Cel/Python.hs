-- | The handful of CPython 3.14 primitives cel-python's observable behaviour
-- rests on beyond petrus-json's "Petrus.Json.Python" (which spells @repr@
-- of strings, bytes and floats): @int()@ and @float()@ string parsing, and
-- the numeric hash that decides which dictionary keys are ever compared.
module Petrus.Cel.Python
  ( -- * Parsing
    asciiTransform
  , parseIntDigits
  , parseFloatText
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

import Data.Char (chr, isAsciiLower, isAsciiUpper, isDigit, ord)
import Data.Ratio (denominator, numerator)
import Data.Text (Text)
import Data.Text qualified as T

import Petrus.Json.Limits (maxIntStrDigits)
import Petrus.Json.Python (isPythonSpace, parsePythonFloat, pythonDecimal)

-- | CPython's @_PyUnicode_TransformDecimalAndSpaceToASCII@: a code point
-- below @\x7f@ stays, any other that @str.isspace@ accepts becomes a
-- space, a Unicode decimal digit its ASCII digit, and anything else @?@ (so
-- it can never parse). ASCII stays first, so @\x1c@-@\x1f@ (which
-- @str.isspace@ accepts) are not turned into spaces and @int()@ refuses
-- them.
asciiTransform :: Text -> String
asciiTransform = map one . T.unpack
  where
    one c
      | c < '\x7f' = c
      | isPythonSpace c = ' '
      | Just d <- pythonDecimal c = chr (ord '0' + d)
      | otherwise = '?'

isAsciiSpace :: Char -> Bool
isAsciiSpace c = c `elem` (" \t\n\r\x0b\x0c" :: String)

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
          | base == 10 && length ds > maxIntStrDigits -> Left True
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

-- | CPython's @float()@ of a string (petrus-json's 'parsePythonFloat', the
-- one @float()@ emulation).
parseFloatText :: Text -> Maybe Double
parseFloatText = parsePythonFloat

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
