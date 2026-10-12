{-# LANGUAGE CApiFFI #-}

-- | CPython's @uuid.uuid4()@ and @uuid.uuid7()@, with randomness from the
-- operating system's random source (@os.urandom@, here @getentropy@).
--
-- A version-4 UUID is 16 random bytes with the version-4 and RFC 4122
-- variant bits set, spelled as @str(uuid)@ or @uuid.hex@. A version-7 one
-- ('uuid7Hex') is 48 bits of Unix milliseconds, the version and variant
-- bits, a 42-bit counter, and 32 random bits.
module Petrus.Json.Python.Uuid
  ( uuid4
  , uuid4Hex
  , uuid7Hex
  , randomBytes
  , uuid4Text
  , uuid4HexText
  ) where

import Control.Monad (when)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Internal qualified as BSI
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word8)
import Foreign.C.Error (throwErrno)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr, plusPtr)
import Numeric (showHex)
import System.IO.Unsafe (unsafePerformIO)

foreign import capi unsafe "sys/random.h getentropy" c_getentropy :: Ptr Word8 -> CSize -> IO CInt

-- | @os.urandom(n)@: @n@ bytes from the operating system's random source.
randomBytes :: Int -> IO ByteString
randomBytes n = BSI.create n (fill n)
  where
    -- getentropy delivers at most 256 bytes per call.
    fill remaining buffer
      | remaining <= 0 = pure ()
      | otherwise = do
          let chunk = min 256 remaining
          rc <- c_getentropy buffer (fromIntegral chunk)
          when (rc /= 0) (throwErrno "getentropy")
          fill (remaining - chunk) (buffer `plusPtr` chunk)

-- | @str(uuid.uuid4())@: @xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx@.
uuid4 :: IO Text
uuid4 = uuid4Text <$> randomBytes 16

-- | @uuid.uuid4().hex@: the same 32 digits without dashes.
uuid4Hex :: IO Text
uuid4Hex = uuid4HexText <$> randomBytes 16

-- | The @str()@ of the version-4 UUID built from 16 random bytes.
uuid4Text :: ByteString -> Text
uuid4Text bytes =
  let hex = uuid4HexText bytes
   in T.intercalate "-" [T.take 8 hex, T.take 4 (T.drop 8 hex), T.take 4 (T.drop 12 hex), T.take 4 (T.drop 16 hex), T.drop 20 hex]

-- | The @.hex@ of the version-4 UUID built from 16 random bytes.
uuid4HexText :: ByteString -> Text
uuid4HexText bytes = T.pack (concatMap hex (zipWith adjust [0 :: Int ..] (BS.unpack (BS.take 16 bytes))))
  where
    adjust i b
      | i == 6 = (b .&. 0x0f) .|. 0x40
      | i == 8 = (b .&. 0x3f) .|. 0x80
      | otherwise = b
    digit n = "0123456789abcdef" !! fromIntegral n
    hex b = [digit (b `shiftR` 4), digit (b .&. 0x0f)]

-- | @uuid.uuid7().hex@: a fresh version-7 UUID as 32 lowercase hex digits.
-- Minted ids sort by creation time across a fleet and, as in the reference
-- (RFC 9562 §6.2 Method 1), strictly within one process even inside one
-- millisecond: the counter advances by one per mint in the same
-- millisecond. The embedded wall clock is an opaque identity only and never
-- a semantic field.
uuid7Hex :: IO Text
uuid7Hex = do
  now <- getPOSIXTime
  random <- randomBytes 14
  let nowMillis = floor (now * 1000) :: Integer
      bigEndian = foldl (\acc b -> acc `shiftL` 8 .|. toInteger b) 0 . BS.unpack
      -- @_uuid7_get_counter_and_tail@: a 42-bit counter with its MSB clear,
      -- and 32 random bits.
      seeded = bigEndian (BS.take 10 random)
      freshCounter = (seeded `shiftR` 32) .&. 0x1ffffffffff
      freshTail = seeded .&. 0xffffffff
      nextTail = bigEndian (BS.drop 10 random)
      mint = \case
        Just (lastMillis, lastCounter)
          | nowMillis <= lastMillis ->
              let millis = if nowMillis < lastMillis then lastMillis + 1 else nowMillis
                  counter = lastCounter + 1
               in if counter > 0x3ffffffffff
                    then (millis + 1, freshCounter, freshTail)
                    else (millis, counter, nextTail)
        _ -> (nowMillis, freshCounter, freshTail)
  (millis, counter, randomTail) <-
    atomicModifyIORef' lastMinted $ \previous ->
      let minted@(m, c, _) = mint previous in (Just (m, c), minted)
  let value =
        (millis .&. 0xffffffffffff) `shiftL` 80
          .|. (0x7 `shiftL` 76)
          .|. (((counter `shiftR` 30) .&. 0x0fff) `shiftL` 64)
          .|. (0x2 `shiftL` 62)
          .|. ((counter .&. 0x3fffffff) `shiftL` 32)
          .|. (randomTail .&. 0xffffffff)
      digits = showHex value ""
  pure (T.pack (replicate (32 - length digits) '0' ++ digits))

-- | The process-wide last minted (timestamp, counter): the reference's
-- @_last_timestamp_v7@ / @_last_counter_v7@ globals. unsafePerformIO
-- (NOINLINE): monotonic minting needs exactly one such state per process.
lastMinted :: IORef (Maybe (Integer, Integer))
lastMinted = unsafePerformIO (newIORef Nothing)
{-# NOINLINE lastMinted #-}
