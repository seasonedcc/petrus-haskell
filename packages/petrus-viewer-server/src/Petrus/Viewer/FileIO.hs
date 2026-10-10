{-# LANGUAGE CApiFFI #-}

-- | Synchronous file access for the request handlers, like Node's
-- @fs.existsSync@ and @fs.readFileSync@.
--
-- The calls are @unsafe@ foreign calls: they keep the capability for the
-- few microseconds they take, where a safe call would hand the capability
-- to another OS thread and take it back afterwards (two thread switches per
-- call, which dominated the endpoints' cost under concurrent load). The
-- price is the same as Node's: a path that blocks on open (a FIFO, a hung
-- network mount) stalls the capability, as @readFileSync@ stalls Node's
-- event loop.
module Petrus.Viewer.FileIO
  ( pathExists
  , readFileBytes
  ) where

import Control.Exception (bracket)
import Data.Bits ((.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Internal qualified as BI
import Data.Word (Word8)
import Foreign.C.Error (eINTR, getErrno, throwErrnoPath)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr, plusPtr)
import System.Posix.Internals (withFilePath)
import System.Posix.Types (COff (..), CSsize (..))

foreign import capi unsafe "fcntl.h open" c_open :: CString -> CInt -> IO CInt
foreign import capi unsafe "unistd.h read" c_read :: CInt -> Ptr Word8 -> CSize -> IO CSsize
foreign import capi unsafe "unistd.h close" c_close :: CInt -> IO CInt
foreign import capi unsafe "unistd.h lseek" c_lseek :: CInt -> COff -> CInt -> IO COff
foreign import capi unsafe "unistd.h access" c_access :: CString -> CInt -> IO CInt
foreign import capi "fcntl.h value O_RDONLY" oRdonly :: CInt
foreign import capi "fcntl.h value O_CLOEXEC" oCloexec :: CInt
foreign import capi "unistd.h value F_OK" fOk :: CInt
foreign import capi "unistd.h value SEEK_SET" seekSet :: CInt
foreign import capi "unistd.h value SEEK_END" seekEnd :: CInt

-- | @fs.existsSync@: @access(path, F_OK)@ succeeds (symlinks followed).
pathExists :: FilePath -> IO Bool
pathExists path = withFilePath path $ \p -> (== 0) <$> c_access p fOk

-- | The whole file. Errors are 'IOError's built from @errno@, with the
-- path, like 'System.IO.readFile'.
readFileBytes :: FilePath -> IO ByteString
readFileBytes path =
  bracket
    (withFilePath path $ \p -> retryPath "openFile" path (c_open p (oRdonly .|. oCloexec)))
    c_close
    $ \fd -> do
      -- the size is a hint (a file can change, and devices report 0)
      end <- c_lseek fd 0 seekEnd
      _ <- c_lseek fd 0 seekSet
      let hint = if end > 0 then fromIntegral end + 1 else 16384
          readChunk n = BI.createAndTrim n $ \buf -> fill fd buf n 0
          go acc n = do
            chunk <- readChunk n
            if B.length chunk < n
              then pure (B.concat (reverse (chunk : acc)))
              else go (chunk : acc) (max 16384 n)
      go [] hint
  where
    -- read until the buffer is full or end of file
    fill fd buf n off
      | off >= n = pure off
      | otherwise = do
          r <- retryPath "hGetContents" path (c_read fd (buf `plusPtr` off) (fromIntegral (n - off)))
          if r == 0 then pure off else fill fd buf n (off + fromIntegral r)

-- | Run a call that returns -1 on failure, retrying on @EINTR@ and
-- throwing the @errno@ error (with the path) otherwise.
retryPath :: (Eq a, Num a) => String -> FilePath -> IO a -> IO a
retryPath loc path act = do
  r <- act
  if r /= -1
    then pure r
    else do
      e <- getErrno
      if e == eINTR then retryPath loc path act else throwErrnoPath loc path
