{-# LANGUAGE OverloadedRecordDot #-}

-- | The Python class name the reference reports for a failure
-- (@type(error).__name__@), for the Haskell exceptions that have a Python
-- counterpart.
--
-- A span's @error_type@ and the runtime's failure texts use this vocabulary,
-- so a mixed Python/Haskell deployment's dashboards see one spelling:
--
-- * an 'IOException' carrying an @errno@ is the 'OSError' subclass CPython
--   picks for that @errno@ (@FileNotFoundError@ for @ENOENT@,
--   @PermissionError@ for @EACCES@, ...; petrus-json's
--   "Petrus.Json.Python.OsError"), and @OSError@ without one;
-- * 'UserInterrupt' is @KeyboardInterrupt@, @async@'s @AsyncCancelled@ is
--   asyncio's @CancelledError@;
-- * 'DivideByZero' is @ZeroDivisionError@, 'Overflow' is @OverflowError@;
-- * an 'ExitCode' is @SystemExit@.
--
-- An exception that stands for a Python exception (a member of petrus-json's
-- 'SomePythonException' hierarchy: a package's own refusals, a
-- 'PythonException' value) is named by its declared class first. Callers
-- that raise other exceptions in the reference's vocabulary (the Engine's
-- @ValueError@/@TypeError@/@RuntimeError@, a handler's recorded failure)
-- name them through 'withSpanClassifying' ("Petrus.Telemetry"). Any other
-- Haskell exception has no Python class and is named by its 'Typeable' type
-- constructor (@ErrorCall@).
--
-- 'pythonExceptionOf' is the one total mapping: the class and the @args@ the
-- reference's exception carries, which every seam that records an
-- exception renders (@repr@, @str@) as the reference does.
module Petrus.Telemetry.ErrorType
  ( pythonExceptionOf
  , pythonErrorType
  , haskellTypeName
  ) where

import Control.Exception
  ( ArithException (..)
  , AsyncException (..)
  , Exception (..)
  , SomeAsyncException (..)
  , SomeException (..)
  )
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (Typeable, tyConModule, tyConName, typeOf, typeRepTyCon)
import GHC.IO.Exception (IOException (..))
import Petrus.Json.Python.Exception (PyObject (..), PythonException (..), asPythonException)
import Petrus.Json.Python.OsError (ioExceptionClass)
import System.Exit (ExitCode (..))

-- | The Python exception an exception stands for, as the reference would
-- raise it: a member of the 'SomePythonException' hierarchy by its own
-- declaration; a Haskell exception with a Python counterpart by that class
-- with the arguments the reference's exception carries (an @errno@-carrying
-- 'IOException' is @FileNotFoundError(2, 'No such file or directory')@,
-- 'UserInterrupt' is @KeyboardInterrupt()@); any other by its 'Typeable'
-- name with its message (without a GHC call stack) as the one string
-- argument, none when the message is empty.
pythonExceptionOf :: SomeException -> PythonException
pythonExceptionOf some = case asPythonException some of
  Just python -> python
  Nothing -> PythonException {name = builtinName some, args = builtinArgs}
  where
    message = case some of SomeException e -> fst (T.breakOn "\nCallStack (from" (T.pack (displayException e)))
    stringArg text = [PyStr text | not (T.null text)]
    builtinArgs
      | Just (io :: IOException) <- fromException some = case ioe_errno io of
          Just errno -> [PyInt (toInteger errno), PyStr (T.pack (ioe_description io))]
          Nothing -> stringArg (T.pack (ioe_description io))
      | Just UserInterrupt <- fromException some = []
      | Just DivideByZero <- fromException some = [PyStr "division by zero"]
      | Just code <- fromException some = [PyInt (exitStatus code)]
      | Just (SomeAsyncException _) <- fromException some, builtinName some == "CancelledError" = []
      | otherwise = stringArg message
    exitStatus = \case
      ExitSuccess -> 0
      ExitFailure n -> toInteger n

-- | The Python class name of an exception, as the reference would report
-- it: the class 'pythonExceptionOf' names.
pythonErrorType :: SomeException -> Text
pythonErrorType some = case asPythonException some of
  Just python -> python.name
  Nothing -> builtinName some

-- | The class of an exception outside the hierarchy: see the module header.
builtinName :: SomeException -> Text
builtinName some
  | Just (io :: IOException) <- fromException some = ioExceptionClass io
  | Just UserInterrupt <- fromException some = "KeyboardInterrupt"
  | Just DivideByZero <- fromException some = "ZeroDivisionError"
  | Just Overflow <- fromException some = "OverflowError"
  | Just (_ :: ExitCode) <- fromException some = "SystemExit"
  | Just (SomeAsyncException inner) <- fromException some = asyncName inner
  | SomeException e <- some = haskellTypeName e
  where
    asyncName inner
      | tyConName tc == "AsyncCancelled" && "Control.Concurrent.Async" `T.isPrefixOf` T.pack (tyConModule tc) = "CancelledError"
      | otherwise = haskellTypeName inner
      where
        tc = typeRepTyCon (typeOf inner)

-- | The 'Typeable' type constructor's name: what a Haskell exception with no
-- Python counterpart is called.
haskellTypeName :: (Typeable e) => e -> Text
haskellTypeName = T.pack . tyConName . typeRepTyCon . typeOf
