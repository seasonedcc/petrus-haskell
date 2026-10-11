{-# LANGUAGE CApiFFI #-}

-- | CPython's @uuid.uuid4()@: 16 bytes from the operating system's random
-- source (@os.urandom@, here @getentropy@), the version-4 and RFC 4122
-- variant bits set, spelled as @str(uuid)@ or @uuid.hex@.
module Petrus.Json.Python.Uuid
  ( uuid4
  , uuid4Hex
  , randomBytes
  , uuid4Text
  , uuid4HexText
  ) where

import Control.Monad (when)
import Data.Bits (shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Internal qualified as BSI
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import Foreign.C.Error (throwErrno)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr, plusPtr)

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
