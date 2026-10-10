-- | CPython's resource limits on JSON values, as Petrus observes them.
--
-- Two CPython limits are visible on Petrus wire surfaces:
--
-- * __Integer string conversion__ (CPython 3.11+, PEP 651 follow-up
--   @sys.set_int_max_str_digits@). Converting a decimal string of more than
--   4300 digits to @int@, or an @int@ of more than 4300 digits to a decimal
--   string, raises @ValueError@. @json.loads@ and @json.dumps@ go through
--   those conversions, and so does @int(text)@ in the observation history
--   query. The digit count excludes the sign and /includes/ leading zeros.
--
-- * __Nesting depth.__ CPython 3.14 bounds recursion in the C JSON scanner and
--   encoder by the C stack, not by a fixed count: on a 64-bit macOS build with
--   the default 8–16 MiB stacks, @json.loads@ raises @RecursionError@ from
--   about 116,000 nested containers and @json.dumps@ from about 104,000. The
--   exact figure depends on platform and thread stack size, so it is not a
--   contract. Haskell's stack grows on the heap and never overflows the way C
--   does; 'defaultNestingLimit' is a fixed bound below every CPython figure
--   measured, so that pathological input is refused rather than parsed into
--   values CPython could never have produced or written.
module Petrus.Json.Limits
  ( maxIntStrDigits
  , intStrDigitsError
  , intReprDigitsError
  , decimalInteger
  , defaultNestingLimit
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC

-- | CPython's default @sys.get_int_max_str_digits()@.
maxIntStrDigits :: Int
maxIntStrDigits = 4300

-- | The @ValueError@ text CPython raises when /parsing/ an integer of the given
-- digit count under the given limit (the @int(str)@ direction).
intStrDigitsError :: Int -> Int -> String
intStrDigitsError limit digits =
  "Exceeds the limit ("
    ++ show limit
    ++ " digits) for integer string conversion: value has "
    ++ show digits
    ++ " digits; use sys.set_int_max_str_digits() to increase the limit"

-- | The @ValueError@ text CPython raises when /printing/ an integer of more
-- than @limit@ digits (the @str(int)@ direction).
intReprDigitsError :: Int -> String
intReprDigitsError limit =
  "Exceeds the limit ("
    ++ show limit
    ++ " digits) for integer string conversion; use sys.set_int_max_str_digits() to increase the limit"

-- | CPython's @int(text)@ for a non-empty string of ASCII decimal digits,
-- including the 4300-digit limit (leading zeros count). Callers validate the
-- digit grammar first, as the reference does with a regular expression.
--
-- >>> decimalInteger "0042"
-- Right 42
decimalInteger :: ByteString -> Either String Integer
decimalInteger digits
  | BS.null digits || not (BC.all isDigit digits) = Left ("invalid literal for int() with base 10: '" ++ BC.unpack digits ++ "'")
  | BS.length digits > maxIntStrDigits = Left (intStrDigitsError maxIntStrDigits (BS.length digits))
  | otherwise = Right (BS.foldl' (\acc w -> acc * 10 + toInteger (w - 0x30)) 0 digits)
  where
    isDigit c = c >= '0' && c <= '9'

-- | The nesting bound 'Petrus.Json.Parse.pythonLoads' and
-- 'Petrus.Json.Encode.defaultDumps' apply: 100,000 nested arrays or objects.
defaultNestingLimit :: Int
defaultNestingLimit = 100000
