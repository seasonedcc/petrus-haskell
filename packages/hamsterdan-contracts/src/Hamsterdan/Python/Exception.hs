-- | The one value every Hamsterdan port uses for a Python exception the
-- reference raises: petrus-json's 'PythonException' (its class name and
-- @args@), with CPython's @repr()@ and @str()@ of it.
--
-- A pure function returns it ('Either' 'PythonException'), an 'IO' action
-- throws it ('raise') exactly where CPython's exception would propagate,
-- and a host reads its class ('name') or prints @str(error)@
-- ('pythonExceptionStr'). It becomes text only where the reference
-- renders it (a firing's failure text is 'pythonFailureText').
module Hamsterdan.Python.Exception
  ( PythonException (..)
  , PythonArg (..)
  , pythonError
  , keyError
  , unicodeDecodeError
  , unicodeEncodeError
  , pythonExceptionRepr
  , pythonExceptionStr
  , pythonFailureText
  , raise
  , dumpsError
  , raisingDumps
  ) where

import Control.Exception (throw, throwIO)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (EncodeError (..), encodeErrorMessage)
import Petrus.Json.Python
  ( PythonArg (..)
  , PythonException (..)
  , pythonError
  , pythonExceptionRepr
  , pythonExceptionStr
  , pythonFailureText
  , unicodeDecodeError
  , unicodeEncodeError
  )

-- | @KeyError(key)@ for a @str@ key (whose @str()@ is the key's @repr@).
keyError :: Text -> PythonException
keyError key = PythonException "KeyError" [PyStr key]

-- | @raise error@.
raise :: PythonException -> IO a
raise = throwIO

-- | The exception @json.dumps@ raises where the encoder refuses a value:
-- @RecursionError@ for one nested too deep, @ValueError@ otherwise (a
-- non-finite float under @allow_nan=False@, an integer past the digit
-- limit).
dumpsError :: EncodeError -> PythonException
dumpsError refusal = pythonError cls (T.pack (encodeErrorMessage refusal))
  where
    cls = case refusal of
      NestingTooDeep _ -> "RecursionError"
      _ -> "ValueError"

-- | A @json.dumps@ result, raising where the encoder refused: the
-- 'dumpsError' of the refusal propagates as CPython's exception would.
raisingDumps :: Either EncodeError a -> a
raisingDumps = either (throw . dumpsError) id
