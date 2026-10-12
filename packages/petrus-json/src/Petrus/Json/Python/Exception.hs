{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | A Python exception as a value: its class name and its positional
-- @args@, with CPython's @repr()@ and @str()@ of it.
--
-- This is the representation the Petrus and Hamsterdan ports use for an
-- exception the reference raises from Python code: the inline driver
-- records it as a firing failure (@Petrus.Impetus.Instance.FailureText@),
-- a Hamsterdan host raises it where the reference's exception propagates,
-- the Net-file loader refuses with it, and a pure fold returns it. Its
-- arguments are "Petrus.Json.Python.Object" values. It is rendered to text
-- only where the reference renders it.
--
-- One evaluator keeps a closed set instead: petrus-cel models the
-- exceptions celpy's evaluation raises and catches over its own @ExcClass@
-- (@Petrus.Cel.Python@), because celpy branches on the class itself (a
-- caught exception becomes a @CELEvalError@ holding @ex.__class__@, which
-- later comparisons and its qualified @repr@, such as @re2._re2.Error@,
-- read back).
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
  , PyObject (..)
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
import Petrus.Json.Limits (maxIntStrDigits)
import Petrus.Json.Python.Object (PyObject (..), failureArgumentText, pyRepr)
import Petrus.Json.Repr (pythonIntRepr, pythonTupleRepr)

-- | A Python exception as user code would raise it: its class name and its
-- positional @args@.
data PythonException = PythonException
  { name :: Text
  , args :: [PyObject]
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

-- | @repr(exception)@ as the reference's failure text spells it:
-- @Name(arg, ...)@, each argument by its @_failure_argument_text@
-- ('failureArgumentText'). An @OSError@ built from
-- @(errno, strerror, filename)@ keeps only @(errno, strerror)@ in its
-- @args@, as CPython does.
pythonExceptionRepr :: PythonException -> Text
pythonExceptionRepr e = e.name <> "(" <> T.intercalate ", " (map failureArgumentText shown) <> ")"
  where
    shown = case e.args of
      [errno@(PyInt _), strerror, _] | e.name `elem` osErrorClasses -> [errno, strerror]
      other -> other

-- | @str(exception)@: @BaseException.__str__@ (nothing for no argument,
-- @str(arg)@ for one, the @args@ tuple's @repr@ for more), with the
-- overrides of @KeyError@ (@repr(arg)@), of @OSError@ and its subclasses
-- built from @(errno, strerror[, filename])@ (@[Errno N] strerror@, then
-- @: repr(filename)@), and of
-- @UnicodeDecodeError@ and @UnicodeEncodeError@ (the codec's message). An
-- argument is spelled by its @repr@ here (@KeyError: slice(None, 20, None)@),
-- not by the failure text's marker, except an @int@ past CPython's
-- 4300-digit conversion limit, whose @repr@ raises.
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
    argRepr = \case
      huge@(PyInt i) | length (show (abs i)) > maxIntStrDigits -> failureArgumentText huge
      other -> pyRepr other
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
