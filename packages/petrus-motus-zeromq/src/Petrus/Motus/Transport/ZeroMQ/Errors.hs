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
  , zeromqPythonException
  ) where

import Control.Exception (Exception (..), SomeException)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Motus.PythonException
  ( Namer (..)
  , OSError (..)
  , PythonException (..)
  , RuntimeError (..)
  , TimeoutError (..)
  , TypeError (..)
  , ValueError (..)
  , pythonExceptionWith
  )
import Petrus.Motus.Transport.ZeroMQ.Native (ZmqError (..))

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

instance Exception ConnectionError where displayException = T.unpack . connectionMessage

connectionMessage :: ConnectionError -> Text
connectionMessage = \case
  NotAcknowledged m -> m
  OperationUncertain m -> m

-- | The server's private @_ProtocolError@: a request it refuses to
-- interpret (answered with error kind @protocol@).
newtype ProtocolError = ProtocolError Text deriving stock (Eq, Show)

instance Exception ProtocolError where displayException (ProtocolError m) = T.unpack m

-- | The Python class and message of any exception the transport sees: its
-- own exceptions by the reference's classes (@ConnectionError@,
-- @OperationUncertain@, @_ProtocolError@, @zmq.ZMQError@), then the Motus
-- mapping ('pythonExceptionWith').
zeromqPythonException :: SomeException -> PythonException
zeromqPythonException =
  pythonExceptionWith
    [ Namer $ \case
        NotAcknowledged m -> PythonException "ConnectionError" m
        OperationUncertain m -> PythonException "OperationUncertain" m
    , Namer (\(ProtocolError m) -> PythonException "_ProtocolError" m)
    , Namer (\(ZmqError _ _ m) -> PythonException "ZMQError" m)
    ]
