-- | The one exception type every execution operation raises.
--
-- Upstream Python signals failures with built-in exception classes whose
-- messages are part of the observable contract (tests match on them).  The
-- Haskell port keeps those messages byte-for-byte and records the Python
-- class as an 'ErrorKind', so callers can branch on the same distinctions
-- without string matching.
module Petrus.Motus.Execution.Error
  ( ErrorKind (..)
  , ExecutionError (..)
  , executionError
  , throwExecution
  , valueError
  , typeError
  , runtimeError
  , osErrorFromIO
  , osErrorFromRawIO
  , pythonErrnoMessage
  ) where

import Control.Exception (Exception, throwIO)
import Data.Text (Text)
import Data.Text qualified as T
import Foreign.C.Error (Errno (..), errnoToIOError)
import Foreign.C.Types (CInt)
import GHC.IO.Exception (IOException (..))
import Data.ByteString.Char8 qualified as BC
import Petrus.Json.Python (fsDecode, pythonStringRepr)

-- | The Python exception class an upstream failure surfaces as.
data ErrorKind
  = ValueError
  | TypeError
  | RuntimeError
  | ConnectionError
  | -- | @tarfile.TarError@ and its subclasses ('errorMessage' is @str(e)@).
    TarError
  | -- | @OSError@ and its subclasses (@FileNotFoundError@, ...).
    OSError
  | KeyError
  | TimeoutError
  | -- | Any other Python class, named verbatim (e.g. @IndexError@).
    OtherError Text
  deriving stock (Eq, Ord, Show)

data ExecutionError = ExecutionError
  { errorKind :: ErrorKind
  , errorMessage :: Text
  }
  deriving stock (Eq, Show)

instance Exception ExecutionError

executionError :: ErrorKind -> Text -> ExecutionError
executionError = ExecutionError

throwExecution :: ErrorKind -> Text -> IO a
throwExecution kind message = throwIO (ExecutionError kind message)

valueError :: Text -> ExecutionError
valueError = ExecutionError ValueError

typeError :: Text -> ExecutionError
typeError = ExecutionError TypeError

runtimeError :: Text -> ExecutionError
runtimeError = ExecutionError RuntimeError

-- | Render an 'IOException' the way CPython renders the matching
-- @OSError@: @[Errno N] strerror: 'path'@.
osErrorFromIO :: IOException -> ExecutionError
osErrorFromIO e = ExecutionError OSError (T.pack rendered)
  where
    rendered = case ioe_errno e of
      Just errno -> pythonErrnoMessage errno (ioe_filename e)
      Nothing -> ioe_description e

-- | Like 'osErrorFromIO' for exceptions raised by the @unix@ package's
-- 'RawFilePath' API, whose file names carry one 'Char' per raw byte.
osErrorFromRawIO :: IOException -> ExecutionError
osErrorFromRawIO e = ExecutionError OSError (T.pack rendered)
  where
    rendered = case ioe_errno e of
      Just errno -> pythonErrnoMessage errno (fmap (T.unpack . fsDecode . BC.pack) (ioe_filename e))
      Nothing -> ioe_description e

-- | @[Errno N] strerror: 'path'@ with CPython's strerror text.
pythonErrnoMessage :: CInt -> Maybe String -> String
pythonErrnoMessage errno path =
  "[Errno " <> show errno <> "] " <> strerror <> maybe "" (\p -> ": " <> T.unpack (pythonStringRepr p)) path
  where
    strerror = ioe_description (errnoToIOError "" (Errno errno) Nothing Nothing)

