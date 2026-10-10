{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

-- | CPython's @float.__repr__@, the one float spelling every Petrus wire
-- format uses (@json.dumps@, @repr@, @str@).
--
-- The digits are the shortest decimal that reads back as the same double,
-- the one nearest the exact value among those, an exact tie broken to even,
-- and, when the binary significand is even, the rounding interval's ends
-- admitted (round-half-even parsing maps them back), so
-- @repr(1e23) == "1e+23"@ and @repr(2**-25) == "2.9802322387695312e-08"@.
-- That is exactly the reference Ryu algorithm (Ulf Adams, 2018) with
-- @acceptBounds = even@, ported below. GHC's 'Numeric.floatToDigits' and
-- bytestring's Ryu both exclude the ends and break the tie upwards, so they
-- spell those two doubles @9.999999999999999e+22@ and
-- @2.9802322387695313e-08@.
--
-- The digits are laid out as CPython does: positional when the decimal
-- point falls in [-4, 16), exponent form (at least two exponent digits)
-- otherwise.
module Petrus.Json.Float
  ( pythonFloatRepr
  , pythonFloatReprBytes
  , floatReprBuilder
  , writeFloatRepr
  , maxFloatReprLength
  ) where

import Data.Array.Base (unsafeAt)
import Data.Array.Unboxed (UArray, listArray)
import Data.Bits (shiftL, shiftR, unsafeShiftL, unsafeShiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString.Builder qualified as B
import Data.ByteString.Builder.Prim qualified as BP
import Data.ByteString.Builder.Prim.Internal (boundedPrim)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Internal qualified as BI
import Data.Word (Word8)
import Foreign.Ptr (Ptr, minusPtr, plusPtr)
import Foreign.Storable (peekByteOff, pokeByteOff)
import GHC.Exts (Word (W#), timesWord2#)
import GHC.Float (castDoubleToWord64)
import GHC.Num.Integer (integerLog2)

-- | CPython's @float.__repr__@ for a finite double.
pythonFloatRepr :: Double -> String
pythonFloatRepr = BC.unpack . pythonFloatReprBytes

-- | 'pythonFloatRepr' as ASCII bytes.
pythonFloatReprBytes :: Double -> ByteString
pythonFloatReprBytes d = BI.unsafeCreateUptoN maxFloatReprLength (\p -> (`minusPtr` p) <$> writeFloatRepr d p)

-- | 'pythonFloatRepr' as a builder.
floatReprBuilder :: Double -> B.Builder
floatReprBuilder = BP.primBounded (boundedPrim maxFloatReprLength writeFloatRepr)
{-# INLINE floatReprBuilder #-}

-- | The longest spelling 'writeFloatRepr' writes
-- (@-2.2250738585072014e-308@).
maxFloatReprLength :: Int
maxFloatReprLength = 24

-- | Write 'pythonFloatRepr' of a finite double at a pointer with room for
-- 'maxFloatReprLength' bytes; answer the pointer after it.
writeFloatRepr :: Double -> Ptr Word8 -> IO (Ptr Word8)
writeFloatRepr d start
  | d == 0 = if isNegativeZero d then ascii start "-0.0" else ascii start "0.0"
  | d < 0 = poke8 start 0 '-' >> positive (start `plusPtr` 1)
  | otherwise = positive start
  where
    bits = castDoubleToWord64 d
    (output, e10) = decimal (fromIntegral (bits .&. 0xFFFFFFFFFFFFF)) (fromIntegral ((bits `unsafeShiftR` 52) .&. 0x7FF))
    n = digitCount output
    decpt = e10 + n
    positive p
      | decpt <= -4 || decpt > 16 = do
          writeDigits output (p `plusPtr` (n + 1))
          lead <- peekByteOff p 1 :: IO Word8
          pokeByteOff p 0 lead
          q <-
            if n > 1
              then poke8 p 1 '.' >> pure (p `plusPtr` (n + 1))
              else pure (p `plusPtr` 1)
          let x = decpt - 1
              magnitude = abs x
          poke8 q 0 'e'
          poke8 q 1 (if x < 0 then '-' else '+')
          if magnitude >= 100
            then writeDigits (fromIntegral magnitude) (q `plusPtr` 5) >> pure (q `plusPtr` 5)
            else do
              pokeByteOff q 2 (fromIntegral (0x30 + magnitude `quot` 10) :: Word8)
              pokeByteOff q 3 (fromIntegral (0x30 + magnitude `rem` 10) :: Word8)
              pure (q `plusPtr` 4)
      | decpt <= 0 = do
          poke8 p 0 '0'
          poke8 p 1 '.'
          mapM_ (\i -> poke8 p (2 + i) '0') [0 .. negate decpt - 1]
          let q = p `plusPtr` (2 - decpt + n)
          writeDigits output q
          pure q
      | decpt >= n = do
          writeDigits output (p `plusPtr` n)
          mapM_ (\i -> poke8 p (n + i) '0') [0 .. decpt - n - 1]
          poke8 p decpt '.'
          poke8 p (decpt + 1) '0'
          pure (p `plusPtr` (decpt + 2))
      | otherwise = do
          writeDigits output (p `plusPtr` (n + 1))
          mapM_ (\i -> peekByteOff p (i + 1) >>= \c -> pokeByteOff p i (c :: Word8)) [0 .. decpt - 1]
          poke8 p decpt '.'
          pure (p `plusPtr` (n + 1))

-- | The decimal digits of a positive number, ending just before the pointer.
writeDigits :: Word -> Ptr Word8 -> IO ()
writeDigits value end = go value (-1)
  where
    go v i = do
      let (q, r) = v `quotRem` 10
      pokeByteOff end i (fromIntegral (0x30 + r) :: Word8)
      if q == 0 then pure () else go q (i - 1)

poke8 :: Ptr Word8 -> Int -> Char -> IO ()
poke8 p i c = pokeByteOff p i (fromIntegral (fromEnum c) :: Word8)
{-# INLINE poke8 #-}

ascii :: Ptr Word8 -> String -> IO (Ptr Word8)
ascii p s = do
  mapM_ (\(i, c) -> poke8 p i c) (zip [0 ..] s)
  pure (p `plusPtr` length s)

-- | The number of decimal digits of a Ryu output (at most 17).
digitCount :: Word -> Int
digitCount v = go 1 10
  where
    go n bound
      | n >= 17 || v < bound = n
      | otherwise = go (n + 1) (bound * 10)

-- | Ryu's @d2d@ (reference d2s.c, @acceptBounds = even@), with its
-- small-integer shortcut: the shortest digits as @(output, exponent)@,
-- @output * 10^exponent@, for an IEEE significand field and biased exponent
-- of a positive finite double.
decimal :: Word -> Int -> (Word, Int)
decimal ieeeMantissa ieeeExponent
  | ieeeExponent /= 0
  , let e2 = ieeeExponent - 1075
  , e2 <= 0
  , e2 >= -52
  , let m2 = (1 `unsafeShiftL` 52) .|. ieeeMantissa
  , m2 .&. ((1 `unsafeShiftL` negate e2) - 1) == 0 =
      stripZeros (m2 `unsafeShiftR` negate e2) 0
  | otherwise = ryu ieeeMantissa ieeeExponent
  where
    stripZeros v e = let (q, r) = v `quotRem` 10 in if r == 0 then stripZeros q (e + 1) else (v, e)

ryu :: Word -> Int -> (Word, Int)
ryu ieeeMantissa ieeeExponent = (output, e10 + removed)
  where
    (e2, m2)
      | ieeeExponent == 0 = (1 - 1023 - 52 - 2, ieeeMantissa)
      | otherwise = (ieeeExponent - 1023 - 52 - 2, (1 `unsafeShiftL` 52) .|. ieeeMantissa)
    acceptBounds = m2 .&. 1 == 0
    mv = 4 * m2
    mmShift = if ieeeMantissa /= 0 || ieeeExponent <= 1 then 1 else 0
    -- Step 3: the interval in a decimal power base.
    (vr0, vp0, vm0, e10, vmTrailing0, vrTrailing0)
      | e2 >= 0 =
          let q = log10Pow2 e2 - (if e2 > 3 then 1 else 0)
              k = pow5InvBitcount + pow5bits q - 1
              i = negate e2 + q + k
              (lo, hi) = (unsafeAt pow5InvSplit (2 * q), unsafeAt pow5InvSplit (2 * q + 1))
              vr = mulShift64 mv lo hi i
              vp = mulShift64 (mv + 2) lo hi i
              vm = mulShift64 (mv - 1 - mmShift) lo hi i
           in if q <= 21
                then
                  if mv `rem` 5 == 0
                    then (vr, vp, vm, q, False, multipleOfPowerOf5 mv q)
                    else
                      if acceptBounds
                        then (vr, vp, vm, q, multipleOfPowerOf5 (mv - 1 - mmShift) q, False)
                        else (vr, vp - (if multipleOfPowerOf5 (mv + 2) q then 1 else 0), vm, q, False, False)
                else (vr, vp, vm, q, False, False)
      | otherwise =
          let q = log10Pow5 (negate e2) - (if negate e2 > 1 then 1 else 0)
              i = negate e2 - q
              k = pow5bits i - pow5Bitcount
              j = q - k
              (lo, hi) = (unsafeAt pow5Split (2 * i), unsafeAt pow5Split (2 * i + 1))
              vr = mulShift64 mv lo hi j
              vp = mulShift64 (mv + 2) lo hi j
              vm = mulShift64 (mv - 1 - mmShift) lo hi j
           in if q <= 1
                then
                  if acceptBounds
                    then (vr, vp, vm, q + e2, mmShift == 1, True)
                    else (vr, vp - 1, vm, q + e2, False, True)
                else (vr, vp, vm, q + e2, False, q < 63 && mv .&. ((1 `unsafeShiftL` q) - 1) == 0)
    -- Step 4: the shortest representation in the interval.
    (output, removed)
      | vmTrailing0 || vrTrailing0 = general vr0 vp0 vm0 vmTrailing0 vrTrailing0 0 0
      | otherwise = common
    general vr vp vm vmTrailing vrTrailing lastRemoved count
      | vp `quot` 10 > vm `quot` 10 =
          general (vr `quot` 10) (vp `quot` 10) (vm `quot` 10) (vmTrailing && vm `rem` 10 == 0) (vrTrailing && lastRemoved == 0) (vr `rem` 10) (count + 1)
      | vmTrailing = trailing vr vp vm vrTrailing lastRemoved count
      | otherwise = finish vr vm vmTrailing vrTrailing lastRemoved count
    trailing vr vp vm vrTrailing lastRemoved count
      | vm `rem` 10 == 0 = trailing (vr `quot` 10) (vp `quot` 10) (vm `quot` 10) (vrTrailing && lastRemoved == 0) (vr `rem` 10) (count + 1)
      | otherwise = finish vr vm True vrTrailing lastRemoved count
    finish vr vm vmTrailing vrTrailing lastRemoved count =
      let lastDigit = if vrTrailing && lastRemoved == 5 && even vr then 4 else lastRemoved
          up = (vr == vm && (not acceptBounds || not vmTrailing)) || lastDigit >= (5 :: Word)
       in (vr + (if up then 1 else 0), count)
    common =
      let (vr1, vp1, vm1, up1, count1)
            | vp0 `quot` 100 > vm0 `quot` 100 = (vr0 `quot` 100, vp0 `quot` 100, vm0 `quot` 100, vr0 `rem` 100 >= 50, 2)
            | otherwise = (vr0, vp0, vm0, False, 0 :: Int)
          go vr vp vm up count
            | vp `quot` 10 > vm `quot` 10 = go (vr `quot` 10) (vp `quot` 10) (vm `quot` 10) (vr `rem` 10 >= 5) (count + 1)
            | otherwise = (vr + (if vr == vm || up then 1 else 0), count)
       in go vr1 vp1 vm1 up1 count1

pow5InvBitcount, pow5Bitcount :: Int
pow5InvBitcount = 125
pow5Bitcount = 125

pow5bits :: Int -> Int
pow5bits e = ((e * 1217359) `shiftR` 19) + 1

log10Pow2 :: Int -> Int
log10Pow2 e = (e * 78913) `shiftR` 18

log10Pow5 :: Int -> Int
log10Pow5 e = (e * 732923) `shiftR` 20

multipleOfPowerOf5 :: Word -> Int -> Bool
multipleOfPowerOf5 value p = go value 0 >= p
  where
    go v count = if v `rem` 5 == 0 then go (v `quot` 5) (count + 1) else count :: Int

-- | @(m * (hi * 2^64 + lo)) >> j@ for @64 < j < 128@.
mulShift64 :: Word -> Word -> Word -> Int -> Word
mulShift64 m lo hi j =
  let (high1, low1) = umul128 m hi
      (high0, _) = umul128 m lo
      total = high0 + low1
      high = if total < high0 then high1 + 1 else high1
      dist = j - 64
   in (high `unsafeShiftL` (64 - dist)) .|. (total `unsafeShiftR` dist)
{-# INLINE mulShift64 #-}

umul128 :: Word -> Word -> (Word, Word)
umul128 (W# a) (W# b) = case timesWord2# a b of (# high, low #) -> (W# high, W# low)
{-# INLINE umul128 #-}

-- | @5^i@ to 125 bits, as (low, high) word pairs (@DOUBLE_POW5_SPLIT@).
pow5Split :: UArray Int Word
pow5Split = listArray (0, 2 * 326 - 1) (concatMap (halves . top) [0 .. 325 :: Int])
  where
    top i =
      let power = 5 ^ i :: Integer
          size = fromIntegral (integerLog2 power) + 1 :: Int
       in if size >= pow5Bitcount then power `shiftR` (size - pow5Bitcount) else power `shiftL` (pow5Bitcount - size)
{-# NOINLINE pow5Split #-}

-- | @floor(2^(bitlength(5^q) - 1 + 125) / 5^q) + 1@ (@DOUBLE_POW5_INV_SPLIT@).
pow5InvSplit :: UArray Int Word
pow5InvSplit = listArray (0, 2 * 342 - 1) (concatMap (halves . inverse) [0 .. 341 :: Int])
  where
    inverse q =
      let power = 5 ^ q :: Integer
          size = fromIntegral (integerLog2 power) + 1 :: Int
       in (1 `shiftL` (size - 1 + pow5InvBitcount)) `div` power + 1
{-# NOINLINE pow5InvSplit #-}

halves :: Integer -> [Word]
halves value = [fromInteger value, fromInteger (value `shiftR` 64)]
