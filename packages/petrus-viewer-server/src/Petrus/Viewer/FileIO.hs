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
--
-- Measured (bench/RESULTS.md, "Low-level code, measured"): with
-- @directory@'s @doesPathExist@ and @bytestring@'s @readFile@ instead,
-- resolve-ref served 0.80x the requests per second with 1 client and
-- 0.66x with 16, and fell behind Node's (0.94x and 0.78x).
module Petrus.Viewer.FileIO
  ( pathExists
  , readFileBytes
  ) where

import Control.Exception (finally, mask)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Internal qualified as BI
import Data.Word (Word8)
import Foreign.C.Error (eINTR, getErrno, throwErrnoPath)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CLong (..), CSize (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (peek)
import System.Posix.Internals (withFilePath)
import System.Posix.Types (CSsize (..))

foreign import ccall unsafe "petrus_open_read" c_openRead :: CString -> Ptr CLong -> IO CInt
foreign import capi unsafe "unistd.h read" c_read :: CInt -> Ptr Word8 -> CSize -> IO CSsize
foreign import capi unsafe "unistd.h close" c_close :: CInt -> IO CInt
foreign import capi unsafe "unistd.h access" c_access :: CString -> CInt -> IO CInt
-- A value import is a foreign call made wherever the value is used, and a
-- safe one unless marked @unsafe@: as a safe call, every 'pathExists' handed
-- the capability over and took it back (bench/RESULTS.md, "Where a request
-- spends its time on Linux").
foreign import capi unsafe "unistd.h value F_OK" fOk :: CInt

-- | @fs.existsSync@: @access(path, F_OK)@ succeeds (symlinks followed).
pathExists :: FilePath -> IO Bool
pathExists path = withFilePath path $ \p -> (== 0) <$> c_access p fOk

-- | The whole file. Errors are 'IOError's built from @errno@, with the
-- path, like 'System.IO.readFile'.
--
-- Like @readFileSync@: a regular file of known size is read up to that
-- size (fewer bytes if it shrinks, no more if it grows); anything else
-- (an empty or special file) is read in chunks until end of file.
readFileBytes :: FilePath -> IO ByteString
readFileBytes path = mask $ \restore -> do
  (fd, size) <- withFilePath path $ \p -> alloca $ \sizePtr -> do
    fd <- c_openRead p sizePtr
    if fd < 0 then throwErrnoPath "openFile" path else (fd,) <$> peek sizePtr
  restore
    ( if size > 0
        then BI.createAndTrim (fromIntegral size) $ \buf -> fill fd buf (fromIntegral size) 0
        else
          let go acc = do
                chunk <- BI.createAndTrim 16384 $ \buf -> fill fd buf 16384 0
                if B.length chunk < 16384
                  then pure (B.concat (reverse (chunk : acc)))
                  else go (chunk : acc)
           in go []
    )
    `finally` c_close fd
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
