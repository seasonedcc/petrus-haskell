-- | The Python class and message the reference records for an exception.
--
-- Custody stores an exception failure as the reference spells it:
-- @type(error).__name__@ as the kind and @repr(error)@ (or @str(error)@) as
-- the error. Which Python class a Haskell exception stands for is one
-- explicit, total mapping ('pythonException'), not a Haskell type's name:
-- 'DispatchError' is the reference's @ValueError@, the built-in exception
-- types the port raises are declared here under the reference's names, and
-- any other exception falls back to its Haskell type constructor's name.
-- A package with exceptions of its own extends the mapping with 'Namer's
-- ('pythonExceptionWith').
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
  , pythonException
  , pythonExceptionWith
  , knownPythonException
  , Namer (..)
  , motusNames
  , pythonExceptionRepr
  , exceptionMessage
  ) where

import Control.Exception (Exception (..), SomeException (..), asyncExceptionFromException, asyncExceptionToException)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (tyConName, typeOf, typeRepTyCon)
import Database.SQLite3 (SQLError (..))
import Petrus.Json.PythonText (pythonStrRepr)
import Petrus.Motus.Dispatch (DispatchError (..))

-- ---------------------------------------------------------------------------
-- The reference's built-in exception types

-- | The reference's @ValueError@ (a refused argument).
newtype ValueError = ValueError Text deriving stock (Eq, Show)

instance Exception ValueError where displayException (ValueError m) = T.unpack m

-- | The reference's @RuntimeError@ (a lifecycle refusal, a cancelled
-- Activity).
newtype RuntimeError = RuntimeError Text deriving stock (Eq, Show)

instance Exception RuntimeError where displayException (RuntimeError m) = T.unpack m

-- | The reference's @LookupError@ (no Activity implementation).
newtype LookupError = LookupError Text deriving stock (Eq, Show)

instance Exception LookupError where displayException (LookupError m) = T.unpack m

-- | The reference's @TypeError@.
newtype TypeError = TypeError Text deriving stock (Eq, Show)

instance Exception TypeError where displayException (TypeError m) = T.unpack m

-- | The reference's @TimeoutError@.
newtype TimeoutError = TimeoutError Text deriving stock (Eq, Show)

instance Exception TimeoutError where displayException (TimeoutError m) = T.unpack m

-- | The reference's @OSError@.
newtype OSError = OSError Text deriving stock (Eq, Show)

instance Exception OSError where displayException (OSError m) = T.unpack m

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

-- | A Python exception as the reference records it: @type(error).__name__@
-- and @str(error)@.
data PythonException = PythonException
  { className :: Text
  , message :: Text
  }
  deriving stock (Eq, Show)

-- | How one Haskell exception type is spelled in Python.
data Namer = forall e. (Exception e) => Namer (e -> PythonException)

-- | The Python spelling of every exception this package raises.
motusNames :: [Namer]
motusNames =
  [ Namer (\(DispatchError m) -> PythonException "ValueError" m)
  , Namer (\(ValueError m) -> PythonException "ValueError" m)
  , Namer (\(RuntimeError m) -> PythonException "RuntimeError" m)
  , Namer (\(LookupError m) -> PythonException "LookupError" m)
  , Namer (\(TypeError m) -> PythonException "TypeError" m)
  , Namer (\(TimeoutError m) -> PythonException "TimeoutError" m)
  , Namer (\(OSError m) -> PythonException "OSError" m)
  , Namer (\(CancelledError m) -> PythonException "CancelledError" m)
  , -- The custody stores' own failures (busy, locked, I/O) are the ones
    -- @sqlite3@ raises as @OperationalError@; its text is SQLite's message.
    Namer (\(SQLError _ details _) -> PythonException "OperationalError" details)
  ]

-- | The spelling the given namers (then this package's) assign, if any.
knownPythonException :: [Namer] -> SomeException -> Maybe PythonException
knownPythonException extra e = listToMaybe (mapMaybe name (extra <> motusNames))
  where
    name (Namer f) = f <$> fromException e

-- | 'pythonException' with a package's own namers tried first.
pythonExceptionWith :: [Namer] -> SomeException -> PythonException
pythonExceptionWith extra e = fromMaybe (fallback e) (knownPythonException extra e)
  where
    fallback (SomeException inner) =
      PythonException (T.pack (tyConName (typeRepTyCon (typeOf inner)))) (exceptionMessage e)

-- | The Python class and message of any exception: the mapping above, or
-- the Haskell type constructor's name and the exception's text.
pythonException :: SomeException -> PythonException
pythonException = pythonExceptionWith []

-- | @repr(error)@ for an exception raised with its message as the one
-- argument: @Name('message')@, or @Name()@ when the message is empty.
pythonExceptionRepr :: PythonException -> Text
pythonExceptionRepr e = e.className <> "(" <> (if T.null e.message then "" else pythonStrRepr e.message) <> ")"

-- | The exception's message without a trailing call stack: the analogue of
-- @str(error)@.
exceptionMessage :: SomeException -> Text
exceptionMessage (SomeException e) = fst (T.breakOn "\nCallStack (from" (T.pack (displayException e)))
