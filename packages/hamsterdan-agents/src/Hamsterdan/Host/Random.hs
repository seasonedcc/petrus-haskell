-- | @os.urandom(n)@: bytes from the system CSPRNG with one @getentropy(2)@
-- call per 256 bytes, as CPython reads them.
--
-- crypton's @getRandomBytes@ in 'IO' opens @/dev/random@ and
-- @/dev/urandom@ on every call; on the sealed-key path (a fresh nonce per
-- seal) that cost more than the sealing itself.
module Hamsterdan.Host.Random (urandom) where

import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString.Internal qualified as BSI
import Data.Word (Word8)
import Foreign.C.Error (throwErrno)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr, plusPtr)

foreign import ccall unsafe "getentropy" c_getentropy :: Ptr Word8 -> CSize -> IO CInt

-- | @os.urandom(n)@.
urandom :: Int -> IO ByteString
urandom n = BSI.create (max 0 n) (fill (max 0 n))
  where
    fill remaining pointer
      | remaining <= 0 = pure ()
      | otherwise = do
          let chunk = min 256 remaining
          status <- c_getentropy pointer (fromIntegral chunk)
          when (status /= 0) $ throwErrno "getentropy"
          fill (remaining - chunk) (pointer `plusPtr` chunk)
