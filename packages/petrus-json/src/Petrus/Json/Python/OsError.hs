{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE CPP #-}

-- | CPython's @OSError@: the subclass an @errno@ selects (PEP 3151), the
-- @strerror@ text, and the exception CPython raises for a failed system
-- call on a path.
module Petrus.Json.Python.OsError
  ( errnoClass
  , ioExceptionClass
  , strerror
  , osError
  , ioException
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Foreign.C.Error
  ( Errno (..)
  , eACCES
  , eAGAIN
  , eALREADY
  , eCHILD
  , eCONNABORTED
  , eCONNREFUSED
  , eCONNRESET
  , eEXIST
  , eINPROGRESS
  , eINTR
  , eISDIR
  , eNOENT
  , eNOTDIR
  , ePERM
  , ePIPE
  , eSHUTDOWN
  , eSRCH
  , eTIMEDOUT
  , eWOULDBLOCK
  )
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..))
import GHC.IO.Exception (IOErrorType (..), IOException (..))
import Petrus.Json.Python.Exception (PythonException (..), pythonError)
import Petrus.Json.Python.Object (PyObject (..))
import System.IO.Error (isDoesNotExistError, isPermissionError)

-- | CPython's @OSError(errno, ...)@ subclass for an @errno@
-- (@Objects/exceptions.c@, @_PyExc_InitState@'s table), @OSError@ for any
-- other.
errnoClass :: Errno -> Text
errnoClass errno
  | errno `elem` [eAGAIN, eALREADY, eWOULDBLOCK, eINPROGRESS] = "BlockingIOError"
  | errno == eCHILD = "ChildProcessError"
  | errno `elem` [ePIPE, eSHUTDOWN] = "BrokenPipeError"
  | errno == eCONNABORTED = "ConnectionAbortedError"
  | errno == eCONNREFUSED = "ConnectionRefusedError"
  | errno == eCONNRESET = "ConnectionResetError"
  | errno == eEXIST = "FileExistsError"
  | errno == eNOENT = "FileNotFoundError"
  | errno == eISDIR = "IsADirectoryError"
  | errno == eNOTDIR = "NotADirectoryError"
  | errno == eINTR = "InterruptedError"
  | errno `elem` [eACCES, ePERM] || Just errno == eNOTCAPABLE = "PermissionError"
  | errno == eSRCH = "ProcessLookupError"
  | errno == eTIMEDOUT = "TimeoutError"
  | otherwise = "OSError"

-- | @ENOTCAPABLE@ where the platform defines it (CPython maps it to
-- @PermissionError@ since 3.13).
eNOTCAPABLE :: Maybe Errno
#if defined(darwin_HOST_OS) || defined(freebsd_HOST_OS)
eNOTCAPABLE = Just (Errno c_ENOTCAPABLE)

foreign import capi "errno.h value ENOTCAPABLE" c_ENOTCAPABLE :: CInt
#else
eNOTCAPABLE = Nothing
#endif

-- | The class of the @OSError@ CPython raises where GHC raises an
-- 'IOException': 'errnoClass' of its @errno@, @OSError@ without one.
ioExceptionClass :: IOException -> Text
ioExceptionClass e = maybe "OSError" (errnoClass . Errno) (ioe_errno e)

-- | @os.strerror(errno)@.
strerror :: Errno -> IO Text
strerror (Errno n) = T.pack <$> (c_strerror n >>= peekCString)

foreign import ccall unsafe "string.h strerror"
  c_strerror :: CInt -> IO CString

-- | The @OSError@ CPython raises for an @errno@ on a path:
-- @Subclass(errno, strerror, path)@, the subclass the errno selects
-- ('errnoClass'), whose @str()@ is @[Errno n] strerror: 'path'@.
osError :: Errno -> Text -> IO PythonException
osError errno@(Errno n) path = do
  description <- strerror errno
  pure (PythonException (errnoClass errno) [PyInt (toInteger n), PyStr description, PyStr path])

-- | 'osError' for a failed system call on a path, by its errno. GHC
-- raises a few without one: a missing file, a refused permission, and
-- opening a directory as a file (@InappropriateType@), which are the
-- errnos the call failed with; any other keeps GHC's description.
ioException :: Text -> IOException -> IO PythonException
ioException path e = case ioe_errno e of
  Just n -> osError (Errno n) path
  Nothing
    | isDoesNotExistError e -> osError eNOENT path
    | isPermissionError e -> osError eACCES path
    | ioe_type e == InappropriateType -> osError eISDIR path
    | otherwise -> pure (pythonError "OSError" (T.pack (show e)))
