-- | The text an inline driver records as @FiringFailed.error@ for an
-- exception raised by user code: the reference's @firing_failure_text@.
--
-- The reference spells an exception as @Name(arg, ...)@: its class name and
-- each of its @args@, where @None@, @bool@, @int@, @float@, @str@, and
-- @bytes@ arguments are spelled by their @repr@ and any other argument as
-- @<module.qualname>@ of its type. The text is bounded to 4096 characters,
-- and an exception with no usable class name is spelled @Exception@.
--
-- A Haskell exception has no @args@. One with a Python counterpart (an
-- 'IOException', 'UserInterrupt', 'DivideByZero', an 'ExitCode') is spelled
-- with that Python class and the arguments the reference's exception carries.
-- Any other is spelled @Name()@ when its message is empty and
-- @Name('message')@ otherwise, where @Name@ is its 'Typeable' name and the
-- message is its 'displayException' text without a GHC call stack: exactly
-- what the reference records for a Python exception of that class raised
-- with no argument or with that one string. A handler that
-- needs any other Python spelling throws a 'PythonException', whose text is
-- the reference's for every argument shape, or an exception of its own type
-- with an 'IsPythonException' instance. 'PythonException' and
-- 'pythonFailureText' are petrus-json's ("Petrus.Json.Python.Exception"),
-- the representation every port shares.
module Petrus.Impetus.Instance.FailureText
  ( PythonException (..)
  , PyObject (..)
  , pythonFailureText
  , exceptionFailureText
  ) where

import Control.Exception (SomeException)
import Data.Text (Text)
import Petrus.Json.Python.Exception (PyObject (..), PythonException (..), pythonFailureText)
import Petrus.Telemetry.ErrorType (pythonExceptionOf)

-- | The recorded text of any exception user code threw
-- ('pythonExceptionOf'): the reference's spelling for an exception that
-- stands for a Python exception (a 'PythonException', a package's own
-- refusal); for a Haskell exception with a Python
-- counterpart ("Petrus.Telemetry.ErrorType") the Python class with the
-- arguments the reference's exception carries (an @errno@-carrying
-- 'IOException' is @FileNotFoundError(2, 'No such file or directory')@,
-- 'UserInterrupt' is @KeyboardInterrupt()@); for any other Haskell exception
-- its 'Typeable' name with its message as the one string argument (none when
-- the message is empty).
exceptionFailureText :: SomeException -> Text
exceptionFailureText = pythonFailureText . pythonExceptionOf
