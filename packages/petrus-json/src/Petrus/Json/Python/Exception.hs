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
module Petrus.Json.Python.Exception
  ( PythonException (..)
  , PythonArg (..)
  , pythonError
  , unicodeDecodeError
  , unicodeEncodeError
  , pythonArgRepr
  , pythonExceptionRepr
  , pythonExceptionStr
  , pythonFailureText
  ) where

import Control.DeepSeq (NFData (..))
import Control.Exception (Exception (..))
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
  displayException = T.unpack . pythonFailureText

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

-- | @repr(exception)@: @Name(arg, ...)@.
pythonExceptionRepr :: PythonException -> Text
pythonExceptionRepr e = e.name <> "(" <> T.intercalate ", " (map pythonArgRepr e.args) <> ")"

-- | @str(exception)@: @BaseException.__str__@ (nothing for no argument,
-- @str(arg)@ for one, the @args@ tuple's @repr@ for more), with the
-- overrides of @KeyError@ (@repr(arg)@) and of @UnicodeDecodeError@ and
-- @UnicodeEncodeError@ (the codec's message).
pythonExceptionStr :: PythonException -> Text
pythonExceptionStr e = case (e.name, e.args) of
  (_, []) -> ""
  ("KeyError", [arg]) -> pythonArgRepr arg
  ("UnicodeDecodeError", [PyStr codec, PyBytes bytes, PyInt start, PyInt end, PyStr reason]) ->
    decodeFailureText bytes (CodecFailure codec (fromInteger start) (fromInteger end) reason)
  ("UnicodeEncodeError", [PyStr codec, PyStr text, PyInt start, PyInt end, PyStr reason]) ->
    encodeFailureText text (CodecFailure codec (fromInteger start) (fromInteger end) reason)
  (_, [PyStr s]) -> s
  (_, [arg]) -> pythonArgRepr arg
  (_, many) -> pythonTupleRepr (map pythonArgRepr many)

-- | The reference's @firing_failure_text(error)@ for a Python exception:
-- its 'pythonExceptionRepr' bounded to 4096 characters, or @Exception@
-- when it has no class name.
pythonFailureText :: PythonException -> Text
pythonFailureText e
  | T.null e.name = "Exception"
  | otherwise = T.take 4096 (pythonExceptionRepr e)
