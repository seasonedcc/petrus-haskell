{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | A Python exception as a value: its class name and its positional
-- @args@, with CPython's @repr()@ and @str()@ of it.
--
-- This is the one representation the Petrus and Hamsterdan ports use for
-- an exception the reference raises from Python code: the inline driver
-- records it as a firing failure (@Petrus.Impetus.Instance.FailureText@),
-- a Hamsterdan host raises it where the reference's exception propagates,
-- and a pure fold returns it. It is rendered to text only where the
-- reference renders it.
--
-- = Exceptions that stand for Python exceptions
--
-- Every port package raises its own refusals (a Fabric 'denied', a Motus
-- @DispatchError@, an execution provider's @ValueError@) as Haskell
-- exceptions. Each such type declares the Python exception it stands for by
-- an 'IsPythonException' instance and joins the 'SomePythonException'
-- hierarchy ('pythonExceptionToException', 'pythonExceptionFromException').
-- 'asPythonException' finds that spelling for any 'SomeException', so every
-- seam that records or reports an exception (a dispatcher's failure, a
-- span's @error_type@, a firing failure text) names a package's exception
-- as the reference names it, without a closed list of known types.
module Petrus.Json.Python.Exception
  ( PythonException (..)
  , PythonArg (..)
    -- * The Python exception hierarchy
  , IsPythonException (..)
  , SomePythonException (..)
  , pythonExceptionToException
  , pythonExceptionFromException
  , asPythonException
  , raised
  , pythonError
  , unicodeDecodeError
  , unicodeEncodeError
  , pythonArgRepr
  , pythonExceptionRepr
  , pythonExceptionStr
  , pythonFailureText
  ) where

import Control.DeepSeq (NFData (..))
import Control.Exception (Exception (..), SomeException)
import Data.Typeable (cast)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json.Python.Decode (CodecFailure (..), decodeFailureText, encodeFailureText)
import Petrus.Json.PythonText (pythonStrRepr)
import Petrus.Json.Repr (pythonBytesRepr, pythonDoubleRepr, pythonIntRepr, pythonTupleRepr)

-- | A Python exception as user code would raise it: its class name and its
-- positional @args@.
data PythonException = PythonException
  { name :: Text
  , args :: [PythonArg]
  }
  deriving stock (Eq, Show)

instance Exception PythonException where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException = T.unpack . pythonFailureText

instance IsPythonException PythonException where
  toPythonException = id

-- | A Haskell exception that stands for a Python exception: the class and
-- arguments the reference raises where the port raises this value.
class (Exception e) => IsPythonException e where
  toPythonException :: e -> PythonException

-- | The root of every exception that stands for a Python exception. A
-- member type's 'Exception' instance sets 'toException' to
-- 'pythonExceptionToException' and 'fromException' to
-- 'pythonExceptionFromException'; catching the type itself is unchanged.
data SomePythonException = forall e. (IsPythonException e) => SomePythonException e

instance Show SomePythonException where
  showsPrec d (SomePythonException e) = showsPrec d e

instance Exception SomePythonException where
  displayException (SomePythonException e) = displayException e

-- | 'toException' for a member of the hierarchy.
pythonExceptionToException :: (IsPythonException e) => e -> SomeException
pythonExceptionToException = toException . SomePythonException

-- | 'fromException' for a member of the hierarchy.
pythonExceptionFromException :: (IsPythonException e) => SomeException -> Maybe e
pythonExceptionFromException some = do
  SomePythonException e <- fromException some
  cast e

-- | The Python exception an exception stands for, when it is a member of
-- the hierarchy.
asPythonException :: SomeException -> Maybe PythonException
asPythonException some = (\(SomePythonException e) -> toPythonException e) <$> fromException some

-- | @Name(message)@ as the ports raise their own refusals: the message as
-- the one argument, or no argument when it is empty (@Name()@).
raised :: Text -> Text -> PythonException
raised className message = PythonException className [PyStr message | not (T.null message)]

instance NFData PythonException where
  rnf (PythonException className arguments) = rnf className `seq` rnf arguments

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
  | -- | @slice(start, stop, step)@: the key of the @KeyError@ slicing a
    -- @dict@ raises (@{}[:20]@).
    PySlice (Maybe Integer) (Maybe Integer) (Maybe Integer)
  deriving stock (Eq, Show)

instance NFData PythonArg where
  rnf = \case
    PyNone -> ()
    PyBool b -> rnf b
    PyInt i -> rnf i
    PyFloat d -> rnf d
    PyStr s -> rnf s
    PyBytes b -> rnf b
    PyObject m q -> rnf m `seq` rnf q
    PySlice a b c -> rnf a `seq` rnf b `seq` rnf c

-- | @Name(message)@: an exception raised with one string argument, the
-- shape of nearly every exception the ports raise.
pythonError :: Text -> Text -> PythonException
pythonError className message = PythonException className [PyStr message]

-- | @UnicodeDecodeError(encoding, object, start, end, reason)@ for the
-- bytes and the failure petrus-json's decoder reports.
unicodeDecodeError :: ByteString -> CodecFailure -> PythonException
unicodeDecodeError bytes failure =
  PythonException
    "UnicodeDecodeError"
    [PyStr failure.failureCodec, PyBytes bytes, PyInt (toInteger failure.failureStart), PyInt (toInteger failure.failureEnd), PyStr failure.failureReason]

-- | @UnicodeEncodeError(encoding, object, start, end, reason)@ for the text
-- and the failure petrus-json's encoder reports.
unicodeEncodeError :: Text -> CodecFailure -> PythonException
unicodeEncodeError text failure =
  PythonException
    "UnicodeEncodeError"
    [PyStr failure.failureCodec, PyStr text, PyInt (toInteger failure.failureStart), PyInt (toInteger failure.failureEnd), PyStr failure.failureReason]

-- | @repr(arg)@ as the reference's failure text spells it: @None@, @bool@,
-- @int@, @float@, @str@ and @bytes@ by their @repr@; an @int@ whose @repr@
-- passes CPython's 4300-digit conversion limit (which raises) and any other
-- object by the marker @<module.qualname>@ of its type.
pythonArgRepr :: PythonArg -> Text
pythonArgRepr = \case
  PyNone -> "None"
  PyBool True -> "True"
  PyBool False -> "False"
  PyInt i
    | length (show (abs i)) > 4300 -> "<builtins.int>"
    | otherwise -> pythonIntRepr i
  PyFloat d -> pythonDoubleRepr d
  PyStr s -> pythonStrRepr s
  PyBytes b -> pythonBytesRepr b
  PyObject modul qualname -> "<" <> modul <> "." <> qualname <> ">"
  PySlice {} -> "<builtins.slice>"

-- | @repr(exception)@: @Name(arg, ...)@. An @OSError@ built from
-- @(errno, strerror, filename)@ keeps only @(errno, strerror)@ in its
-- @args@, as CPython does.
pythonExceptionRepr :: PythonException -> Text
pythonExceptionRepr e = e.name <> "(" <> T.intercalate ", " (map pythonArgRepr shown) <> ")"
  where
    shown = case e.args of
      [errno@(PyInt _), strerror, _] | e.name `elem` osErrorClasses -> [errno, strerror]
      other -> other

-- | @str(exception)@: @BaseException.__str__@ (nothing for no argument,
-- @str(arg)@ for one, the @args@ tuple's @repr@ for more), with the
-- overrides of @KeyError@ (@repr(arg)@), of @OSError@ and its subclasses
-- built from @(errno, strerror[, filename])@ (@[Errno N] strerror@, then
-- @: repr(filename)@), and of
-- @UnicodeDecodeError@ and @UnicodeEncodeError@ (the codec's message). A
-- slice is spelled as its @repr@ here (@KeyError: slice(None, 20, None)@),
-- not by the failure text's marker.
pythonExceptionStr :: PythonException -> Text
pythonExceptionStr e = case (e.name, e.args) of
  (_, []) -> ""
  ("KeyError", [arg]) -> argRepr arg
  (cls, PyInt errno : strerror : filename)
    | cls `elem` osErrorClasses, length filename <= 1 ->
        "[Errno " <> pythonIntRepr errno <> "] " <> argStr strerror <> foldMap fileSuffix filename
  ("UnicodeDecodeError", [PyStr codec, PyBytes bytes, PyInt start, PyInt end, PyStr reason]) ->
    decodeFailureText bytes (CodecFailure codec (fromInteger start) (fromInteger end) reason)
  ("UnicodeEncodeError", [PyStr codec, PyStr text, PyInt start, PyInt end, PyStr reason]) ->
    encodeFailureText text (CodecFailure codec (fromInteger start) (fromInteger end) reason)
  (_, [arg]) -> argStr arg
  (_, many) -> pythonTupleRepr (map argRepr many)
  where
    -- @repr(arg)@ (a slice's @str@ is its @repr@), which the failure
    -- text's marker stands for.
    argRepr = \case
      PySlice start stop step -> "slice(" <> T.intercalate ", " (map (maybe "None" pythonIntRepr) [start, stop, step]) <> ")"
      other -> pythonArgRepr other
    argStr = \case
      PyStr s -> s
      other -> argRepr other
    fileSuffix = \case
      PyNone -> ""
      filename -> ": " <> argRepr filename

-- | @OSError@ and its built-in subclasses (an @OSError(errno, strerror)@
-- of any of them is spelled @[Errno N] strerror@).
osErrorClasses :: [Text]
osErrorClasses =
  [ "OSError", "IOError", "EnvironmentError", "BlockingIOError", "ChildProcessError", "ConnectionError"
  , "BrokenPipeError", "ConnectionAbortedError", "ConnectionRefusedError", "ConnectionResetError"
  , "FileExistsError", "FileNotFoundError", "InterruptedError", "IsADirectoryError", "NotADirectoryError"
  , "PermissionError", "ProcessLookupError", "TimeoutError"
  ]

-- | The reference's @firing_failure_text(error)@ for a Python exception:
-- its 'pythonExceptionRepr' bounded to 4096 characters, or @Exception@
-- when it has no class name.
pythonFailureText :: PythonException -> Text
pythonFailureText e
  | T.null e.name = "Exception"
  | otherwise = T.take 4096 (pythonExceptionRepr e)
