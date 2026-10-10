-- | Internal helpers shared by the petrus-posix modules.
module Petrus.Posix.Internal
  ( withPath
  , openPath
  ) where

import Foreign.C.Error (eINTR, getErrno, throwErrnoPath)
import Foreign.C.String (CString, withCAString)
import Foreign.C.Types (CInt (..))
import GHC.IO.Exception (IOErrorType (InvalidArgument))
import System.IO.Error (mkIOError)
import System.Posix.Internals (withFilePath)
import System.Posix.Types (CMode (..), Fd (..), FileMode)

foreign import ccall safe "petrus_posix.h petrus_open" c_open :: CString -> CInt -> CMode -> IO CInt

-- | Marshal a path for a syscall with the file-system encoding. ASCII paths
-- (the common case) take a direct copy instead of the general encoder. A
-- path with a NUL byte is refused (Python raises @ValueError: embedded null
-- byte@) rather than silently truncated.
withPath :: FilePath -> (CString -> IO a) -> IO a
withPath path
  | '\0' `elem` path = const (ioError (mkIOError InvalidArgument "embedded null byte" Nothing (Just path)))
  | all (< '\x80') path = withCAString path
  | otherwise = withFilePath path

-- | @os.open(path, flags | O_CLOEXEC, mode)@, retried on @EINTR@.
openPath :: String -> FilePath -> CInt -> FileMode -> IO Fd
openPath location path flags mode = withPath path go
  where
    go cpath = do
      fd <- c_open cpath flags mode
      if fd >= 0
        then pure (Fd fd)
        else do
          errno <- getErrno
          if errno == eINTR then go cpath else throwErrnoPath location path
