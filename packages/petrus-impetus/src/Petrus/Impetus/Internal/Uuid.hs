-- | UUIDv7 hex identities (@uuid.uuid7().hex@): 48 bits of Unix
-- milliseconds, the version and variant bits, a 42-bit counter, and 32
-- random bits. Minted ids sort by creation time across a fleet — and,
-- as in the reference (RFC 9562 §6.2 Method 1), strictly within one process
-- even inside one millisecond: the counter advances by one per mint in the
-- same millisecond. The embedded wall clock is an opaque identity only and
-- never a semantic field.
module Petrus.Impetus.Internal.Uuid
  ( uuid7Hex
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.IO.Unsafe (unsafePerformIO)

-- | The process-wide last minted (timestamp, counter): the reference's
-- @_last_timestamp_v7@ / @_last_counter_v7@ globals.
lastMinted :: IORef (Maybe (Integer, Integer))
lastMinted = unsafePerformIO (newIORef Nothing)
{-# NOINLINE lastMinted #-}

-- | A fresh UUIDv7 as 32 lowercase hex digits.
uuid7Hex :: IO Text
uuid7Hex = do
  now <- getPOSIXTime
  random <- withBinaryFile "/dev/urandom" ReadMode (`BS.hGet` 14)
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
