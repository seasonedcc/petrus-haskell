-- | The Python class and message the reference records for an exception.
--
-- Custody stores an exception failure as the reference spells it:
-- @type(error).__name__@ as the kind and @repr(error)@ (or @str(error)@) as
-- the error. Which Python exception a Haskell exception stands for is one
-- open mapping shared by every seam: an exception type that stands for a
-- Python exception declares it with an 'IsPythonException' instance and
-- joins petrus-json's 'SomePythonException' hierarchy (this module's
-- built-in types, 'DispatchError', Fabric's and the Absurd, ZeroMQ and
-- execution packages' errors); a Haskell exception with a Python
-- counterpart (an 'IOException', an 'ExitCode', ...) is named as
-- "Petrus.Telemetry.ErrorType" names it; any other exception falls back to
-- its Haskell type constructor's name ('pythonException'). The one foreign
-- exception the custody stores raise, @direct-sqlite@'s 'SQLError', is the
-- reference's @sqlite3.OperationalError@.
module Petrus.Motus.PythonException
  ( -- * The reference's built-in exception types
    ValueError (..)
  , RuntimeError (..)
  , LookupError (..)
  , TypeError (..)
  , TimeoutError (..)
  , OSError (..)
  , CancelledError (..)
    -- * Naming
  , PythonException (..)
  , PythonArg (..)
  , IsPythonException (..)
  , pythonException
  , knownPythonException
  , pythonExceptionRepr
  , pythonExceptionStr
  , exceptionMessage
  ) where

import Control.Applicative ((<|>))
import Control.Exception (Exception (..), SomeException (..), asyncExceptionFromException, asyncExceptionToException)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite3 (SQLError (..))
import Petrus.Json.Python.Exception
  ( IsPythonException (..)
  , PythonArg (..)
  , PythonException (..)
  , asPythonException
  , pythonExceptionFromException
  , pythonExceptionRepr
  , pythonExceptionStr
  , pythonExceptionToException
  , raised
  )
import Petrus.Telemetry.ErrorType (pythonExceptionOf)

-- ---------------------------------------------------------------------------
-- The reference's built-in exception types

-- | The reference's @ValueError@ (a refused argument).
newtype ValueError = ValueError Text deriving stock (Eq, Show)

instance Exception ValueError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException (ValueError m) = T.unpack m

instance IsPythonException ValueError where toPythonException (ValueError m) = raised "ValueError" m

-- | The reference's @RuntimeError@ (a lifecycle refusal, a cancelled
-- Activity).
newtype RuntimeError = RuntimeError Text deriving stock (Eq, Show)

instance Exception RuntimeError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException (RuntimeError m) = T.unpack m

instance IsPythonException RuntimeError where toPythonException (RuntimeError m) = raised "RuntimeError" m

-- | The reference's @LookupError@ (no Activity implementation).
newtype LookupError = LookupError Text deriving stock (Eq, Show)

instance Exception LookupError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException (LookupError m) = T.unpack m

instance IsPythonException LookupError where toPythonException (LookupError m) = raised "LookupError" m

-- | The reference's @TypeError@.
newtype TypeError = TypeError Text deriving stock (Eq, Show)

instance Exception TypeError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException (TypeError m) = T.unpack m

instance IsPythonException TypeError where toPythonException (TypeError m) = raised "TypeError" m

-- | The reference's @TimeoutError@.
newtype TimeoutError = TimeoutError Text deriving stock (Eq, Show)

instance Exception TimeoutError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException (TimeoutError m) = T.unpack m

instance IsPythonException TimeoutError where toPythonException (TimeoutError m) = raised "TimeoutError" m

-- | The reference's @OSError@.
newtype OSError = OSError Text deriving stock (Eq, Show)

instance Exception OSError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException (OSError m) = T.unpack m

instance IsPythonException OSError where toPythonException (OSError m) = raised "OSError" m

-- | The reference's @asyncio.CancelledError@ with a message, as an
-- asynchronous exception. An Activity of an @AsyncWorker@ that ends with any
-- asynchronous exception is reported as @RuntimeError("Activity cancelled:
-- <message>")@.
newtype CancelledError = CancelledError Text deriving stock (Eq, Show)

instance Exception CancelledError where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException
  displayException (CancelledError m) = T.unpack m

-- ---------------------------------------------------------------------------
-- Naming

-- | The Python exception the reference records for any exception: its own
-- declaration ('knownPythonException'), or "Petrus.Telemetry.ErrorType"'s
-- spelling (a Haskell exception with a Python counterpart by that class, any
-- other by its type constructor's name and its message).
pythonException :: SomeException -> PythonException
pythonException e = fromMaybe (pythonExceptionOf e) (knownPythonException e)

-- | The Python exception an exception declares it stands for (a member of
-- the 'IsPythonException' hierarchy), a 'CancelledError' (asynchronous, so
-- outside the hierarchy) as @CancelledError(message)@, or
-- @OperationalError@ for a SQLite failure (the custody stores' busy, locked
-- and I/O errors, which the reference's @sqlite3@ raises as
-- @OperationalError@ with SQLite's message).
knownPythonException :: SomeException -> Maybe PythonException
knownPythonException e = asPythonException e <|> cancelled <|> sqlite
  where
    cancelled = (\(CancelledError m) -> raised "CancelledError" m) <$> fromException e
    sqlite = (\(SQLError _ details _) -> raised "OperationalError" details) <$> fromException e

-- | The exception's message without a trailing call stack: the analogue of
-- @str(error)@.
exceptionMessage :: SomeException -> Text
exceptionMessage (SomeException e) = fst (T.breakOn "\nCallStack (from" (T.pack (displayException e)))
