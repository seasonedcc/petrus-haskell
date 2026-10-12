-- | @getaddrinfo@ error codes.
--
-- The @network@ package raises a failed @getaddrinfo@ as an 'IOError'
-- whose description is @gai_strerror(code)@ and drops the code, which
-- @socket.gaierror@ shows (@[Errno 8] nodename nor servname provided, or not
-- known@). 'gaiErrorCode' recovers it.
module Petrus.Posix.Netdb
  ( gaiErrorCode
  ) where

import Data.List (find)
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Array (peekArray0)
import Foreign.Ptr (Ptr)

foreign import ccall unsafe "petrus_posix.h petrus_gai_codes" c_gai_codes :: IO (Ptr CInt)

foreign import ccall unsafe "netdb.h gai_strerror" c_gai_strerror :: CInt -> IO CString

-- | The @EAI_*@ code this system's @gai_strerror@ describes with the given
-- message, if any.
gaiErrorCode :: String -> IO (Maybe Int)
gaiErrorCode message = do
  codes <- peekArray0 0 =<< c_gai_codes
  described <- traverse (\code -> (,) code <$> (peekCString =<< c_gai_strerror code)) codes
  pure (fromIntegral . fst <$> find ((== message) . snd) described)
