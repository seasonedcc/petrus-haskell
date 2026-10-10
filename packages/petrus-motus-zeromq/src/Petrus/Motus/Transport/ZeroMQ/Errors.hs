-- | The exceptions the transport throws, named after the reference's
-- built-in exception types so that a Worker reports them with the same
-- @kind@ and a caller can catch them by the same categories.
module Petrus.Motus.Transport.ZeroMQ.Errors
  ( ValueError (..)
  , RuntimeError (..)
  , TypeError (..)
  , TimeoutError (..)
  , ConnectionError (..)
  , connectionMessage
  , ProtocolError (..)
  ) where

import Control.Exception (Exception (..))
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Motus.Worker (RuntimeError (..), ValueError (..))

-- | The reference's @TypeError@ (only one is observable on the wire: a
-- failure whose @retryable@ is not a boolean, which the reference's server
-- answers as a @service@ error).
newtype TypeError = TypeError Text deriving stock (Eq, Show)

instance Exception TypeError where displayException (TypeError m) = T.unpack m

-- | The reference's @TimeoutError@ (a server that did not become ready).
newtype TimeoutError = TimeoutError Text deriving stock (Eq, Show)

instance Exception TimeoutError where displayException (TimeoutError m) = T.unpack m

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
