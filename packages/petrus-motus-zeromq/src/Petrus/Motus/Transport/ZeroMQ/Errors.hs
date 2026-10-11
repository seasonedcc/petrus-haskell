-- | The exceptions the transport throws, named after the reference's
-- built-in exception types so that a Worker reports them with the same
-- @kind@ and a caller can catch them by the same categories.
module Petrus.Motus.Transport.ZeroMQ.Errors
  ( ValueError (..)
  , RuntimeError (..)
  , TypeError (..)
  , TimeoutError (..)
  , OSError (..)
  , ConnectionError (..)
  , connectionMessage
  , ProtocolError (..)
  ) where

import Control.Exception (Exception (..))
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json.Python.Exception (IsPythonException (..), pythonExceptionFromException, pythonExceptionToException, raised)
import Petrus.Motus.PythonException
  ( OSError (..)
  , RuntimeError (..)
  , TimeoutError (..)
  , TypeError (..)
  , ValueError (..)
  )

-- | The reference's @ConnectionError@ and its @OperationUncertain@
-- subclass: a custody operation was sent but its definitive response was
-- lost. Catching 'ConnectionError' catches both, as in the reference.
data ConnectionError
  = -- | @ConnectionError@: the synchronous client's unacknowledged request.
    NotAcknowledged Text
  | -- | @OperationUncertain@: the asynchronous access's lost response or
    -- cancellation after sending.
    OperationUncertain Text
  deriving stock (Eq, Show)

instance Exception ConnectionError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException = T.unpack . connectionMessage

instance IsPythonException ConnectionError where
  toPythonException = \case
    NotAcknowledged m -> raised "ConnectionError" m
    OperationUncertain m -> raised "OperationUncertain" m

connectionMessage :: ConnectionError -> Text
connectionMessage = \case
  NotAcknowledged m -> m
  OperationUncertain m -> m

-- | The server's private @_ProtocolError@: a request it refuses to
-- interpret (answered with error kind @protocol@).
newtype ProtocolError = ProtocolError Text deriving stock (Eq, Show)

instance Exception ProtocolError where
  toException = pythonExceptionToException
  fromException = pythonExceptionFromException
  displayException (ProtocolError m) = T.unpack m

instance IsPythonException ProtocolError where
  toPythonException (ProtocolError m) = raised "_ProtocolError" m
