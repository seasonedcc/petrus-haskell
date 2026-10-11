-- | ECMAScript number semantics for JSON numbers.
--
-- The viewer's Node backend parses every relayed message with @JSON.parse@
-- and re-serializes it with @JSON.stringify@, so a number on the wire is
-- always printed by ECMAScript's @Number::toString@ applied to the IEEE-754
-- double nearest to the literal. This module reproduces that mapping exactly:
--
-- * 'canonicalLiteral' turns a JSON number literal into the bytes Node would
--   print for it, without converting to a 'Double' whenever the literal has at
--   most 15 significant digits (every such decimal round-trips through a
--   double, so its shortest representation is its own digits);
-- * 'formatDouble' prints an arbitrary 'Double' the way @JSON.stringify@ does
--   (non-finite values print as @null@).
module Petrus.Viewer.Json.Number
  ( canonicalLiteral
  , formatDouble
  , formatDoubleBuilder
  , literalValue
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Char8 qualified as BC
import Data.Ratio ((%))
import Data.Word (Word8)
import Petrus.Json.Float (shortestDigits)

-- | The canonical (Node @JSON.stringify@) spelling of a grammar-valid JSON
-- number literal, together with its (lazily computed) double value.
canonicalLiteral :: ByteString -> (ByteString, Double)
canonicalLiteral lit
  | isShortInteger lit =
      ( if lit == "-0" then "0" else lit
      , literalValue lit
      )
  | otherwise =
      let neg = B.take 1 lit == "-"
          body = if neg then B.drop 1 lit else lit
          (intPart, rest1) = B.span isDigit body
          (fracPart, rest2) =
            if B.take 1 rest1 == "."
              then B.span isDigit (B.drop 1 rest1)
              else ("", rest1)
          expo = parseExponent rest2
          allDigits = intPart <> fracPart
          leading = B.length (B.takeWhile (== 0x30) allDigits)
          trimmedLead = B.drop leading allDigits
          sig = B.dropWhileEnd (== 0x30) trimmedLead
          k = B.length sig
          n = toInteger (B.length intPart) + expo - toInteger leading
       in if B.null sig
            then ("0", if neg then -0.0 else 0)
            else
              if k <= 15 && n > -300 && n < 300
                then (signed neg (formatDigits sig (fromInteger n)), literalValue lit)
                else let d = literalValue lit in (formatDouble d, d)
  where
    signed True b = "-" <> b
    signed False b = b

isShortInteger :: ByteString -> Bool
isShortInteger lit =
  let body = if B.take 1 lit == "-" then B.drop 1 lit else lit
   in not (B.null body) && B.length body <= 15 && B.all isDigit body

isDigit :: Word8 -> Bool
isDigit w = w >= 0x30 && w <= 0x39
{-# INLINE isDigit #-}

parseExponent :: ByteString -> Integer
parseExponent b
  | B.null b = 0
  | otherwise =
      let rest = B.drop 1 b -- 'e' or 'E'
          (sgn, ds) = case B.uncons rest of
            Just (0x2d, t) -> (-1, t)
            Just (0x2b, t) -> (1, t)
            _ -> (1, rest)
       in sgn * digitsToInteger ds

digitsToInteger :: ByteString -> Integer
digitsToInteger = B.foldl' (\acc w -> acc * 10 + toInteger (w - 0x30)) 0

-- | The IEEE-754 double nearest to a grammar-valid JSON number literal
-- (ties to even), as @JSON.parse@ computes it.
literalValue :: ByteString -> Double
literalValue lit =
  let neg = B.take 1 lit == "-"
      body = if neg then B.drop 1 lit else lit
      (intPart, rest1) = B.span isDigit body
      (fracPart, rest2) =
        if B.take 1 rest1 == "."
          then B.span isDigit (B.drop 1 rest1)
          else ("", rest1)
      expo = parseExponent rest2
      allDigits = B.dropWhile (== 0x30) (intPart <> fracPart)
      mantissa = digitsToInteger allDigits
      scale = expo - toInteger (B.length fracPart)
      -- position of the leading significant digit, used to cut off absurd
      -- exponents before building huge rationals
      magnitude = toInteger (B.length allDigits) + scale
      v
        | mantissa == 0 = 0
        | magnitude > 330 = 1 / 0
        | magnitude < -360 = 0
        | scale >= 0 = fromRational ((mantissa * 10 ^ scale) % 1)
        | otherwise = fromRational (mantissa % (10 ^ negate scale))
   in if neg then negate v else v

-- | @JSON.stringify@ of a double: ECMAScript @Number::toString@ for finite
-- values, @null@ for NaN and infinities.
formatDouble :: Double -> ByteString
formatDouble d
  | isNaN d || isInfinite d = "null"
  | d == 0 = "0"
  | d < 0 = "-" <> positive (negate d)
  | otherwise = positive d
  where
    -- The shortest digits nearest the value, ties to even, with the rounding
    -- interval's ends admitted for an even significand: ECMAScript's choice
    -- (and CPython's), so 1e23 prints as @1e+23@. 'Numeric.floatToDigits'
    -- excludes the ends and would print @9.999999999999999e+22@.
    positive x =
      let (output, e) = shortestDigits x
          digits = BC.pack (show output)
       in formatDigits (B.dropWhileEnd (== 0x30) digits) (B.length digits + e)

formatDoubleBuilder :: Double -> BB.Builder
formatDoubleBuilder = BB.byteString . formatDouble

-- | ECMAScript Number::toString (radix 10) step 5-10 given the significant
-- digits @s@ (no leading or trailing zeros) and the decimal point position
-- @n@, such that the value is @0.s * 10^n@.
formatDigits :: ByteString -> Int -> ByteString
formatDigits s n
  | k <= n && n <= 21 = s <> BC.replicate (n - k) '0'
  | 0 < n && n <= 21 = B.take n s <> "." <> B.drop n s
  | -6 < n && n <= 0 = "0." <> BC.replicate (negate n) '0' <> s
  | otherwise =
      let e = n - 1
          expPart = (if e >= 0 then "e+" else "e-") <> BC.pack (show (abs e))
       in if k == 1
            then s <> expPart
            else B.take 1 s <> "." <> B.drop 1 s <> expPart
  where
    k = B.length s
