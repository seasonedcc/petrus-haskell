-- | UUIDv7 hex identities (@uuid.uuid7().hex@): 48 bits of Unix
-- milliseconds, the version and variant bits, and random bits. Minted ids
-- sort by creation time across a fleet; the embedded wall clock is an opaque
-- identity only and never a semantic field.
module Petrus.Impetus.Internal.Uuid
  ( uuid7Hex
  ) where

import Data.Bits (shiftL, (.&.), (.|.))
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)
import System.IO (IOMode (ReadMode), withBinaryFile)

-- | A fresh UUIDv7 as 32 lowercase hex digits.
uuid7Hex :: IO Text
uuid7Hex = do
  now <- getPOSIXTime
  random <- withBinaryFile "/dev/urandom" ReadMode (`BS.hGet` 10)
  let millis = floor (now * 1000) :: Integer
      bytes = map toInteger (BS.unpack random)
      randA = (bytes !! 0 `shiftL` 8 .|. bytes !! 1) .&. 0x0fff
      randB = foldl (\acc b -> acc `shiftL` 8 .|. b) 0 (drop 2 bytes) .&. 0x3fffffffffffffff
      value =
        (millis .&. 0xffffffffffff) `shiftL` 80
          .|. (0x7 `shiftL` 76)
          .|. (randA `shiftL` 64)
          .|. (0x2 `shiftL` 62)
          .|. randB
      digits = showHex value ""
  pure (T.pack (replicate (32 - length digits) '0' ++ digits))
