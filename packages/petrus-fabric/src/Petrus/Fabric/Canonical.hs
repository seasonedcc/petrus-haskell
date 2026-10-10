{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

-- | The canonical encoder (@_canonical(value)@, spec/fabric.md §3.3):
-- @json.dumps(value, allow_nan=False, ensure_ascii=False, sort_keys=True,
-- separators=(",", ":"))@.
--
-- This is a specialised fast path for the one spelling Fabric digests and
-- measures. It writes CPython's bytes, which the test suite checks against
-- CPython itself and against petrus-json's general encoder (@dumps compact
-- {sortKeys = True}@) on generated values. A value that encoder would refuse
-- (a non-finite float, an integer of 4300 or more digits, nesting deeper
-- than CPython's default limit) is answered 'Nothing' here, and
-- "Petrus.Fabric.Model.canonicalBytes" defers to the general encoder for its
-- exact refusal.
--
-- Floats are CPython's @float.__repr__@: the shortest decimal that reads back
-- as the same double, the one nearest the exact value among those, an exact
-- tie broken to even, and, when the binary significand is even, the rounding
-- interval's ends admitted (round-half-even parsing maps them back), so
-- @repr(1e23) == "1e+23"@ and @repr(2**-25) == "2.9802322387695312e-08"@.
-- That is exactly the reference Ryu algorithm (Ulf Adams, 2018) with
-- @acceptBounds = even@, ported below. GHC's 'floatToDigits' and
-- bytestring's Ryu both exclude the ends and break the tie upwards, so they
-- spell those two doubles @9.999999999999999e+22@ and
-- @2.9802322387695313e-08@. The digits are laid out as CPython does:
-- positional when the decimal point falls in [-4, 16), exponent form (at least
-- two exponent digits) otherwise.
module Petrus.Fabric.Canonical
  ( canonicalFast
  , stringBuilder
  , floatRepr
  ) where

import Control.Monad.ST (stToIO)
import Data.Array.Base (unsafeAt)
import Data.Array.Unboxed (UArray, listArray)
import Data.Bits (shiftL, shiftR, unsafeShiftL, unsafeShiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Builder.Prim qualified as BP
import Data.ByteString.Builder.Prim.Internal (boundedPrim)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Unsafe qualified as BU
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text.Array qualified as TA
import Data.Text.Internal qualified as TI
import Data.Word (Word16, Word32, Word8, byteSwap16, byteSwap32)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, minusPtr, plusPtr)
import Foreign.Storable (peekByteOff, pokeByteOff)
import GHC.ByteOrder (ByteOrder (..), targetByteOrder)
import GHC.Exts (Int (I#), Word (W#), timesWord2#)
import GHC.Float (castDoubleToWord64)
import GHC.Num.Integer (Integer (IS), integerLog2)
import System.IO.Unsafe (unsafeDupablePerformIO)
import Petrus.Json (Json (..))
import Petrus.Json.Limits (defaultNestingLimit, maxIntStrDigits)

-- | The canonical bytes, or 'Nothing' when the value must be refused.
--
-- One pass measures an upper bound of the output (exact except for numbers)
-- and checks the refusals; a second writes straight into a buffer of that
-- size.
canonicalFast :: Json -> Maybe ByteString
canonicalFast value
  | bound < 0 = Nothing
  | otherwise = Just $ unsafeDupablePerformIO $ do
      written <- BI.createUptoN bound (\start -> (`minusPtr` start) <$> write value start)
      -- Keep the slack of the number bounds out of long-lived values.
      pure (if 8 * (bound - BS.length written) > bound then BS.copy written else written)
  where
    bound = measure 0 value

-- | An upper bound of the encoded size, or a negative number for the
-- refusals of @json.dumps(..., allow_nan=False)@ with CPython's default
-- integer-digit and nesting limits.
measure :: Int -> Json -> Int
measure level = \case
  Null -> 4
  Bool True -> 4
  Bool False -> 5
  Int (IS _) -> 20
  Int i
    | abs i < intDigitBound -> length (show i)
    | otherwise -> -1
  Float d
    | isNaN d || isInfinite d -> -1
    | otherwise -> 24
  String s -> stringSize s
  Array [] -> 2
  Array items
    | level >= defaultNestingLimit -> -1
    | otherwise -> sizes items 1
  Object [] -> 2
  Object members
    | level >= defaultNestingLimit -> -1
    | otherwise -> membersSize members 1
  where
    sizes [] total = total
    sizes (item : rest) total = let size = measure (level + 1) item in if size < 0 then size else sizes rest (total + size + 1)
    membersSize [] total = total
    membersSize ((key, item) : rest) total =
      let size = measure (level + 1) item in if size < 0 then size else membersSize rest (total + stringSize key + size + 2)

intDigitBound :: Integer
intDigitBound = 10 ^ maxIntStrDigits
{-# NOINLINE intDigitBound #-}

write :: Json -> Ptr Word8 -> IO (Ptr Word8)
write value p = case value of
  Null -> word32 0x6e756c6c
  Bool True -> word32 0x74727565
  Bool False -> pokeByteOff p 4 (0x65 :: Word8) >> word32 0x66616c73 >> pure (p `plusPtr` 5)
  Int (IS n) -> writeInt (I# n) p
  Int i -> do
    let digits = BC.pack (show i)
    BU.unsafeUseAsCString digits (\source -> copyBytes p (castPtr source) (BS.length digits))
    pure (p `plusPtr` BS.length digits)
  Float d -> writeFloat d p
  String s -> writeString s p
  Array [] -> word16 0x5b5d
  Array (first : rest) -> do
    poke8 p 0 '['
    end <- write first (p `plusPtr` 1)
    items rest end
  Object [] -> word16 0x7b7d
  Object members -> case sortMembers members of
    (key, item) : rest -> do
      poke8 p 0 '{'
      end <- member key item (p `plusPtr` 1)
      others rest end
    [] -> word16 0x7b7d
  where
    word32 w = pokeByteOff p 0 (toBE32 w) >> pure (p `plusPtr` 4)
    word16 w = pokeByteOff p 0 (toBE16 w) >> pure (p `plusPtr` 2)
    items [] q = poke8 q 0 ']' >> pure (q `plusPtr` 1)
    items (item : rest) q = do
      poke8 q 0 ','
      end <- write item (q `plusPtr` 1)
      items rest end
    member key item q = do
      afterKey <- writeString key q
      poke8 afterKey 0 ':'
      write item (afterKey `plusPtr` 1)
    others [] q = poke8 q 0 '}' >> pure (q `plusPtr` 1)
    others ((key, item) : rest) q = do
      poke8 q 0 ','
      end <- member key item (q `plusPtr` 1)
      others rest end

writeInt :: Int -> Ptr Word8 -> IO (Ptr Word8)
writeInt n p
  | n < 0 = poke8 p 0 '-' >> unsigned (negate (fromIntegral n)) (p `plusPtr` 1)
  | otherwise = unsigned (fromIntegral n) p
  where
    unsigned magnitude q = do
      let end = q `plusPtr` digitCount magnitude
      writeDigits magnitude end
      pure end

-- | Members by key, stably (as @sorted(dict.items())@ on distinct keys).
-- Small objects take an insertion sort that costs one comparison per member
-- when they arrive in order.
sortMembers :: [(Text, Json)] -> [(Text, Json)]
sortMembers members
  | short (16 :: Int) members = reverse (foldl' (flip insert) [] members)
  | otherwise = sortBy (comparing fst) members
  where
    short _ [] = True
    short 0 _ = False
    short n (_ : rest) = short (n - 1) rest
    -- Into a descending list, after (in the final order) every equal key.
    insert x = \case
      y : ys | fst y > fst x -> y : insert x ys
      ys -> x : ys

-- | CPython's @py_encode_basestring@: quote, escape @"@, @\\@ and the
-- C0 controls, copy everything else as raw UTF-8. The escape test is on
-- UTF-8 bytes: every byte of a multi-byte sequence is at least 0x80, so it
-- never matches inside one.
stringBuilder :: Text -> B.Builder
stringBuilder text = BP.primBounded (boundedPrim (stringSize text) (\() -> writeString text)) ()

-- | The exact encoded size of a string.
stringSize :: Text -> Int
stringSize (TI.Text array offset len) = go offset (len + 2)
  where
    end = offset + len
    go i total
      | i >= end = total
      | otherwise = go (i + 1) (total + extra (TA.unsafeIndex array i))
    extra c
      | c >= 0x20 = if c == 0x22 || c == 0x5c then 1 else 0
      | c == 0x0a || c == 0x0d || c == 0x09 || c == 0x08 || c == 0x0c = 1
      | otherwise = 5

writeString :: Text -> Ptr Word8 -> IO (Ptr Word8)
writeString (TI.Text array offset len) p = do
  poke8 p 0 '"'
  end <-
    if plain offset
      then stToIO (TA.copyToPointer array offset (p `plusPtr` 1) len) >> pure (p `plusPtr` (len + 1))
      else escape offset (p `plusPtr` 1)
  poke8 end 0 '"'
  pure (end `plusPtr` 1)
  where
    stop = offset + len
    plain i
      | i >= stop = True
      | otherwise = let c = TA.unsafeIndex array i in c >= 0x20 && c /= 0x22 && c /= 0x5c && plain (i + 1)
    escape i q
      | i >= stop = pure q
      | otherwise = do
          let c = TA.unsafeIndex array i
          next <-
            if c >= 0x20 && c /= 0x22 && c /= 0x5c
              then pokeByteOff q 0 c >> pure (q `plusPtr` 1)
              else case c of
                0x22 -> two q '"'
                0x5c -> two q '\\'
                0x0a -> two q 'n'
                0x0d -> two q 'r'
                0x09 -> two q 't'
                0x08 -> two q 'b'
                0x0c -> two q 'f'
                _ -> do
                  poke8 q 0 '\\'
                  poke8 q 1 'u'
                  poke8 q 2 '0'
                  poke8 q 3 '0'
                  pokeByteOff q 4 (hexDigit (c `unsafeShiftR` 4))
                  pokeByteOff q 5 (hexDigit (c .&. 0x0f))
                  pure (q `plusPtr` 6)
          escape (i + 1) next
    two q c = poke8 q 0 '\\' >> poke8 q 1 c >> pure (q `plusPtr` 2)
    hexDigit :: Word8 -> Word8
    hexDigit h = if h < 10 then 0x30 + h else 0x57 + h

-- | CPython's @float.__repr__@ for a finite double.
floatRepr :: Double -> B.Builder
floatRepr = BP.primBounded (boundedPrim 24 writeFloat)

toBE32 :: Word32 -> Word32
toBE32 w = if targetByteOrder == LittleEndian then byteSwap32 w else w

toBE16 :: Word16 -> Word16
toBE16 w = if targetByteOrder == LittleEndian then byteSwap16 w else w

writeFloat :: Double -> Ptr Word8 -> IO (Ptr Word8)
writeFloat d start
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
