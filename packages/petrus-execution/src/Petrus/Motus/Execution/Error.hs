-- | The one exception type every execution operation raises.
--
-- Upstream Python signals failures with built-in exception classes whose
-- messages are part of the observable contract (tests match on them).  The
-- Haskell port keeps those messages byte-for-byte and records the Python
-- class as an 'ErrorKind', so callers can branch on the same distinctions
-- without string matching.
--
-- An 'ExecutionError' stands for that Python exception wherever it is
-- recorded ('IsPythonException'): a Worker running an Activity that fails
-- with one records the class and @repr@/@str@ the reference records.
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

import Control.Exception (Exception (..), throwIO)
import Data.Char (chr, isDigit, isHexDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Foreign.C.Error (Errno (..), errnoToIOError)
import Foreign.C.Types (CInt)
import GHC.IO.Exception (IOException (..))
import Numeric (readHex)
import Data.ByteString.Char8 qualified as BC
import Petrus.Json.Python (fsDecode, pythonStringRepr)
import Petrus.Json.Python.Exception
  ( IsPythonException (..)
  , PythonArg (..)
  , PythonException (..)
  , pythonExceptionFromException
  , pythonExceptionToException
  , raised
  )
import Petrus.Telemetry.ErrorType (oserrorSubclass)

-- | The Python exception class an upstream failure surfaces as.
data ErrorKind
  = ValueError
  | TypeError
  | RuntimeError
  | ConnectionError
  | -- | @tarfile.TarError@ and its subclasses, named by the subclass
    -- (@ReadError@, @OutsideDestinationError@, ...; 'errorMessage' is
    -- @str(e)@).
    TarError Text
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

instance Exception ExecutionError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException

-- | The class the kind names, raised with the message: @str(e)@ of an
-- @OSError@ built from @(errno, strerror[, filename])@ (CPython's
-- @[Errno N] strerror: 'path'@) is that @OSError@ subclass with those
-- arguments, and @str(e)@ of a @KeyError@ is the @repr@ of its key.
instance IsPythonException ExecutionError where
  toPythonException (ExecutionError kind message) = case kind of
    ValueError -> raised "ValueError" message
    TypeError -> raised "TypeError" message
    RuntimeError -> raised "RuntimeError" message
    ConnectionError -> raised "ConnectionError" message
    TarError cls -> raised cls message
    OSError -> maybe (raised "OSError" message) osException (errnoParts message)
    KeyError -> PythonException "KeyError" [maybe (keyArg message) PyStr (unreprStr message)]
    TimeoutError -> raised "TimeoutError" message
    OtherError cls -> raised cls message
    where
      osException (errno, strerror, filename) =
        PythonException (oserrorSubclass (Errno errno)) ([PyInt (toInteger errno), PyStr strerror] <> map PyStr filename)
      keyArg text = either (const (PyStr text)) (\(n, rest) -> if T.null rest then PyInt n else PyStr text) (TR.signed TR.decimal text)

-- | @[Errno N] strerror@ with an optional @: repr(filename)@, as
-- 'pythonErrnoMessage' renders it.
errnoParts :: Text -> Maybe (CInt, Text, [Text])
errnoParts message = do
  rest <- T.stripPrefix "[Errno " message
  let (digits, afterDigits) = T.span isDigit rest
  (errno, _) <- either (const Nothing) Just (TR.decimal digits)
  body <- T.stripPrefix "] " afterDigits
  let strerror = T.pack (ioe_description (errnoToIOError "" (Errno errno) Nothing Nothing))
  suffix <- T.stripPrefix strerror body
  if T.null suffix
    then Just (errno, strerror, [])
    else do
      quoted <- T.stripPrefix ": " suffix
      filename <- unreprStr quoted
      Just (errno, strerror, [filename])

-- | The text a Python @repr(str)@ spells, if the given text is one.
unreprStr :: Text -> Maybe Text
unreprStr text = do
  (quote, rest) <- T.uncons text
  if quote /= '\'' && quote /= '"' then Nothing else T.pack <$> go quote (T.unpack rest)
  where
    go quote = \case
      [c] | c == quote -> Just []
      '\\' : escaped -> case escaped of
        't' : more -> ('\t' :) <$> go quote more
        'n' : more -> ('\n' :) <$> go quote more
        'r' : more -> ('\r' :) <$> go quote more
        'x' : more -> hex 2 quote more
        'u' : more -> hex 4 quote more
        'U' : more -> hex 8 quote more
        c : more | c == quote || c == '\\' -> (c :) <$> go quote more
        _ -> Nothing
      c : more | c /= quote -> (c :) <$> go quote more
      _ -> Nothing
    hex width quote chars = case splitAt width chars of
      (digits, more) | length digits == width, all isHexDigit digits, [(n, "")] <- readHex digits, n <= 0x10FFFF ->
        (chr n :) <$> go quote more
      _ -> Nothing

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

