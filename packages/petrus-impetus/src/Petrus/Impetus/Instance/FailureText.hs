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
-- the reference's for every argument shape.
module Petrus.Impetus.Instance.FailureText
  ( PythonException (..)
  , PythonArg (..)
  , pythonFailureText
  , exceptionFailureText
  ) where

import Control.Exception (ArithException (..), AsyncException (..), Exception (..), SomeAsyncException (..), SomeException (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import Numeric (showHex)
import Petrus.Json (pythonFloatRepr)
import Petrus.Json.PythonText (pythonStrRepr)
import GHC.IO.Exception (IOException (..))
import Petrus.Telemetry.ErrorType (pythonErrorType)
import System.Exit (ExitCode (..))

-- | A Python exception as user code would raise it: its class name and its
-- positional @args@.
data PythonException = PythonException
  { name :: Text
  , args :: [PythonArg]
  }
  deriving stock (Eq, Show)

instance Exception PythonException where
  displayException = T.unpack . pythonFailureText

-- | One exception argument, by the Python type the reference distinguishes.
data PythonArg
  = PyNone
  | PyBool Bool
  | PyInt Integer
  | PyFloat Double
  | PyStr Text
  | PyBytes ByteString
  | -- | Any other value: its type's @__module__@ and @__qualname__@ (an
    -- instance of a @str@ or @int@ subclass is one of these too).
    PyObject Text Text
  deriving stock (Eq, Show)

-- | @firing_failure_text(error)@ for a Python exception.
pythonFailureText :: PythonException -> Text
pythonFailureText e
  | T.null e.name = "Exception"
  | otherwise = T.take 4096 (e.name <> "(" <> T.intercalate ", " (map argument e.args) <> ")")

argument :: PythonArg -> Text
argument = \case
  PyNone -> "None"
  PyBool True -> "True"
  PyBool False -> "False"
  -- @repr@ of an int over CPython's 4300-digit conversion limit raises, and
  -- the reference then falls back to the type marker.
  PyInt i
    | length (show (abs i)) > 4300 -> "<builtins.int>"
    | otherwise -> T.pack (show i)
  PyFloat d
    | isNaN d -> "nan"
    | isInfinite d -> if d > 0 then "inf" else "-inf"
    | otherwise -> T.pack (pythonFloatRepr d)
  PyStr s -> pythonStrRepr s
  PyBytes b -> bytesRepr b
  PyObject modul qualname -> "<" <> modul <> "." <> qualname <> ">"

-- | CPython's @repr(bytes)@.
bytesRepr :: ByteString -> Text
bytesRepr bytes = "b" <> T.singleton quote <> T.concat (map escape (BS.unpack bytes)) <> T.singleton quote
  where
    quote = if BS.elem 0x27 bytes && not (BS.elem 0x22 bytes) then '"' else '\''
    escape :: Word8 -> Text
    escape w
      | w == fromIntegral (fromEnum quote) || w == 0x5C = T.pack ['\\', toEnum (fromIntegral w)]
      | w == 0x09 = "\\t"
      | w == 0x0A = "\\n"
      | w == 0x0D = "\\r"
      | w < 0x20 || w >= 0x7F = "\\x" <> T.justifyRight 2 '0' (T.pack (showHex w ""))
      | otherwise = T.singleton (toEnum (fromIntegral w))

-- | The recorded text of any exception user code threw: the reference's
-- spelling for a 'PythonException'; for a Haskell exception with a Python
-- counterpart ("Petrus.Telemetry.ErrorType") the Python class with the
-- arguments the reference's exception carries (an @errno@-carrying
-- 'IOException' is @FileNotFoundError(2, 'No such file or directory')@,
-- 'UserInterrupt' is @KeyboardInterrupt()@); for any other Haskell exception
-- its 'Typeable' name with its message as the one string argument (none when
-- the message is empty).
exceptionFailureText :: SomeException -> Text
exceptionFailureText some = case fromException some of
  Just python -> pythonFailureText python
  Nothing -> pythonFailureText PythonException {name = pythonErrorType some, args = pythonArgs}
  where
    message = case some of SomeException e -> fst (T.breakOn "\nCallStack (from" (T.pack (displayException e)))
    stringArg text = [PyStr text | not (T.null text)]
    pythonArgs
      | Just (io :: IOException) <- fromException some = case ioe_errno io of
          Just errno -> [PyInt (toInteger errno), PyStr (T.pack (ioe_description io))]
          Nothing -> stringArg (T.pack (ioe_description io))
      | Just UserInterrupt <- fromException some = []
      | Just DivideByZero <- fromException some = [PyStr "division by zero"]
      | Just code <- fromException some = [PyInt (exitStatus code)]
      | Just (SomeAsyncException _) <- fromException some, pythonErrorType some == "CancelledError" = []
      | otherwise = stringArg message
    exitStatus = \case
      ExitSuccess -> 0
      ExitFailure n -> toInteger n
