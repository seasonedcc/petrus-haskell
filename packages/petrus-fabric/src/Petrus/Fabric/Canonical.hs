{-# LANGUAGE MagicHash #-}

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
-- Floats are CPython's @float.__repr__@, written by petrus-json's shared
-- "Petrus.Json.Float" (a port of the reference Ryu algorithm with CPython's
-- rounding rules), so this encoder and every other float path spell the
-- same bytes.
module Petrus.Fabric.Canonical
  ( canonicalFast
  , stringBuilder
  ) where

import Control.Monad.ST (stToIO)
import Data.Bits (unsafeShiftR, (.&.))
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
import Foreign.Storable (pokeByteOff)
import GHC.ByteOrder (ByteOrder (..), targetByteOrder)
import GHC.Exts (Int (I#))
import GHC.Num.Integer (Integer (IS))
import System.IO.Unsafe (unsafeDupablePerformIO)
import Petrus.Json (Json (..))
import Petrus.Json.Float (maxFloatReprLength, writeFloatRepr)
import Petrus.Json.Limits (defaultNestingLimit, maxIntStrDigits)

-- | The canonical bytes, or 'Nothing' when the value must be refused.
--
-- One pass measures an upper bound of the output (exact except for numbers)
-- and checks the refusals; a second writes straight into a buffer of that
-- size. unsafeDupablePerformIO: the writer touches only the buffer this
-- call allocates.
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
    | otherwise -> maxFloatReprLength
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
  Float d -> writeFloatRepr d p
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
      let end = q `plusPtr` digitCount 1 magnitude
      writeDigits magnitude end
      pure end
    -- Every digit of a machine word (up to 20).
    digitCount :: Int -> Word -> Int
    digitCount count v = if v < 10 then count else digitCount (count + 1) (v `quot` 10)

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

toBE32 :: Word32 -> Word32
toBE32 w = if targetByteOrder == LittleEndian then byteSwap32 w else w

toBE16 :: Word16 -> Word16
toBE16 w = if targetByteOrder == LittleEndian then byteSwap16 w else w

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

