{-# LANGUAGE MagicHash #-}

-- | Internal helpers shared by the petrus-posix modules.
module Petrus.Posix.Internal
  ( withPath
  , openPath
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Internal (ByteString (BS), mallocByteString)
import Data.ByteString.Unsafe (unsafeUseAsCString)
import Data.Char (ord)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Word (Word8)
import Foreign.C.Error (eINTR, getErrno, throwErrnoPath)
import Foreign.C.String (CString, withCAString)
import Foreign.C.Types (CInt (..))
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Storable (pokeByteOff)
import GHC.Exts (isTrue#, reallyUnsafePtrEquality#)
import GHC.IO.Exception (IOErrorType (InvalidArgument))
import System.IO.Error (mkIOError)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Internals (withFilePath)
import System.Posix.Types (CMode (..), Fd (..), FileMode)

foreign import ccall safe "petrus_posix.h petrus_open" c_open :: CString -> CInt -> CMode -> IO CInt

-- | Marshal a path for a syscall with the file-system encoding. ASCII paths
-- (the common case) are copied in a single pass instead of going through
-- the general encoder, and the most recent one is remembered: callers that
-- reuse the same path value (a lock file, a database path) skip the copy.
-- A path with a NUL byte is refused (Python raises @ValueError: embedded
-- null byte@) rather than silently truncated.
withPath :: FilePath -> (CString -> IO a) -> IO a
withPath path action = do
  Encoded previous bytes <- readIORef recentPath
  -- The very same (immutable) String object as last time: its bytes are
  -- known. Pointer equality can only miss, never confuse two paths.
  if isTrue# (reallyUnsafePtrEquality# previous path)
    then unsafeUseAsCString bytes action
    else
      encodeAscii path >>= \case
        Ascii encoded -> do
          writeIORef recentPath (Encoded path encoded)
          unsafeUseAsCString encoded action
        Nul -> nulError
        General
          | '\0' `elem` path -> nulError
          | all (< '\x80') path -> withCAString path action
          | otherwise -> withFilePath path action
  where
    nulError = ioError (mkIOError InvalidArgument "embedded null byte" Nothing (Just path))

-- | A path value and its NUL-terminated ASCII bytes. The path field stays
-- lazy so it holds exactly the caller's pointer.
data Encoded = Encoded FilePath !ByteString

-- | 'withPath''s one-entry cache. unsafePerformIO (NOINLINE): a
-- process-wide memo of immutable values; any thread may hit or replace it.
recentPath :: IORef Encoded
recentPath = unsafePerformIO (newIORef (Encoded [] (BS.singleton 0)))
{-# NOINLINE recentPath #-}

data Ascii = Ascii !ByteString | Nul | General

-- | One pass over the path: its NUL-terminated bytes when it is ASCII and
-- shorter than 'asciiBuffer', 'Nul' when a NUL byte comes before any
-- non-ASCII character, 'General' otherwise.
encodeAscii :: FilePath -> IO Ascii
encodeAscii path = do
  buffer <- mallocByteString asciiBuffer
  withForeignPtr buffer $ \pointer ->
    let copy !n = \case
          [] -> pokeByteOff pointer n (0 :: Word8) >> pure (Ascii (BS buffer (n + 1)))
          c : rest
            | c == '\0' -> pure Nul
            | c >= '\x80' || n >= asciiBuffer - 1 -> pure General
            | otherwise -> pokeByteOff pointer n (fromIntegral (ord c) :: Word8) >> copy (n + 1) rest
     in copy 0 path

-- | Size of the single-pass buffer: @PATH_MAX@ on macOS; longer ASCII paths
-- take the two-pass route.
asciiBuffer :: Int
asciiBuffer = 1024

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
