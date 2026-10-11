-- | The one value every Hamsterdan port uses for a Python exception the
-- reference raises: petrus-json's 'PythonException' (its class name and
-- @args@), with CPython's @repr()@ and @str()@ of it.
--
-- A pure function returns it ('Either' 'PythonException'), an 'IO' action
-- throws it ('raise') exactly where CPython's exception would propagate,
-- and a host reads its class ('name') or prints @str(error)@
-- ('pythonExceptionStr'). It becomes text only where the reference
-- renders it (a firing's failure text is 'pythonFailureText').
module Hamsterdan.Python.Exception
  ( PythonException (..)
  , PythonArg (..)
  , pythonError
  , keyError
  , unicodeDecodeError
  , unicodeEncodeError
  , pythonExceptionRepr
  , pythonExceptionStr
  , pythonFailureText
  , raise
  , dumpsError
  , raisingDumps
  , osError
  , ioException
  ) where

import Control.Exception (IOException, throw, throwIO)
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
import System.IO.Error (isDoesNotExistError, isPermissionError)
import Petrus.Json (EncodeError (..), encodeErrorMessage)
import Petrus.Json.Python
  ( PythonArg (..)
  , PythonException (..)
  , pythonError
  , pythonExceptionRepr
  , pythonExceptionStr
  , pythonFailureText
  , pythonStrRepr
  , unicodeDecodeError
  , unicodeEncodeError
  )

-- | @KeyError(key)@ for a @str@ key (whose @str()@ is the key's @repr@).
keyError :: Text -> PythonException
keyError key = PythonException "KeyError" [PyStr key]

-- | @raise error@.
raise :: PythonException -> IO a
raise = throwIO

-- | The exception @json.dumps@ raises where the encoder refuses a value:
-- @RecursionError@ for one nested too deep, @ValueError@ otherwise (a
-- non-finite float under @allow_nan=False@, an integer past the digit
-- limit).
dumpsError :: EncodeError -> PythonException
dumpsError refusal = pythonError cls (T.pack (encodeErrorMessage refusal))
  where
    cls = case refusal of
      NestingTooDeep _ -> "RecursionError"
      _ -> "ValueError"

-- | A @json.dumps@ result, raising where the encoder refused: the
-- 'dumpsError' of the refusal propagates as CPython's exception would.
raisingDumps :: Either EncodeError a -> a
raisingDumps = either (throw . dumpsError) id

-- | The @OSError@ CPython raises for an errno on a path: the subclass the
-- errno selects (@FileNotFoundError@, @PermissionError@, ...) and its
-- @str()@, @[Errno n] strerror: 'path'@. It is held as a one-argument
-- exception, so its @str()@ is CPython's (its @repr()@ is not: CPython's
-- @args@ are the errno and the description).
osError :: Errno -> Text -> IO PythonException
osError errno@(Errno n) path = do
  description <- c_strerror n >>= peekCString
  pure (pythonError (errnoClass errno) ("[Errno " <> T.pack (show n) <> "] " <> T.pack description <> ": " <> pythonStrRepr path))

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

-- | CPython's @errno@-to-subclass table (PEP 3151).
errnoClass :: Errno -> Text
errnoClass errno
  | errno == eNOENT = "FileNotFoundError"
  | errno == eEXIST = "FileExistsError"
  | errno == eISDIR = "IsADirectoryError"
  | errno == eNOTDIR = "NotADirectoryError"
  | errno == eACCES || errno == ePERM = "PermissionError"
  | errno `elem` [eAGAIN, eALREADY, eWOULDBLOCK, eINPROGRESS] = "BlockingIOError"
  | errno == eCHILD = "ChildProcessError"
  | errno == ePIPE || errno == eSHUTDOWN = "BrokenPipeError"
  | errno == eCONNABORTED = "ConnectionAbortedError"
  | errno == eCONNREFUSED = "ConnectionRefusedError"
  | errno == eCONNRESET = "ConnectionResetError"
  | errno == eINTR = "InterruptedError"
  | errno == eSRCH = "ProcessLookupError"
  | errno == eTIMEDOUT = "TimeoutError"
  | otherwise = "OSError"

foreign import ccall unsafe "string.h strerror"
  c_strerror :: CInt -> IO CString
