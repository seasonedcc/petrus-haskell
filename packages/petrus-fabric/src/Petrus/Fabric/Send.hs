-- | The interoperable @fabric.send@ Activity profile (spec/fabric.md §11):
-- the reference demos' @SendActivity@ and the handlers' invocation shape,
-- so an Activity a Python Engine requested can be executed here, and the
-- reverse.
module Petrus.Fabric.Send
  ( sendActivityName
  , sendInvocation
  , sendActivity
  , sendResult
  , pythonActivityError
  , asPythonFailure
  ) where

import Control.Exception (catch, throwIO)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
  ( ActivityError (..)
  , ActivityFailureFields (..)
  , ActivityInvocation (..)
  , activityFailure
  , defaultExecutionPolicy
  )
import Petrus.Fabric.Error
import Petrus.Fabric.Model
import Petrus.Json (Json (..))

-- | @"fabric.send"@.
sendActivityName :: Text
sendActivityName = "fabric.send"

-- | The invocation a sending handler's @prepare@ returns: the envelope JSON
-- as input, its correlation, and its ingress identity as idempotency.
sendInvocation :: Envelope -> ActivityInvocation
sendInvocation e =
  ActivityInvocation
    { activity = sendActivityName
    , input = envelopeToData e
    , policy = defaultExecutionPolicy
    , correlation = Just e.correlation
    , idempotency = Just e.ingressIdentity
    }

-- | The exact result object (§11).
sendResult :: Envelope -> Submission -> Json
sendResult e submission =
  Object
    [ ("state", String (deliveryStateText submission.state))
    , ("duplicate", Bool submission.duplicate)
    , ("delivery_id", String submission.deliveryId)
    , ("correlation", String e.correlation)
    ]

-- | Execute a @fabric.send@ invocation with the given submit (a client bound
-- to the envelope's sender): decode the envelope strictly, refuse an
-- idempotency other than its ingress identity, submit. Refusals are
-- 'FabricError's; an inline registry wraps the executor in
-- 'asPythonFailure' to record them as the reference's dispatchers do.
sendActivity :: (Envelope -> IO Submission) -> ActivityInvocation -> IO Json
sendActivity submitTo inv = do
  e <- orThrow (envelopeFromData inv.input)
  if inv.idempotency /= Just e.ingressIdentity
    then
      throwIO
        ( InvalidValue
            ( "fabric.send invocation idempotency "
                <> maybe "None" pyRepr inv.idempotency
                <> " does not match envelope identity "
                <> pyRepr e.ingressIdentity
            )
        )
    else sendResult e <$> submitTo e

-- | The failure an inline dispatcher records for a Python exception: kind =
-- the class name, error = the message, retryable.
pythonActivityError :: FabricError -> ActivityError
pythonActivityError err =
  let message = errorMessage err
      fields =
        ActivityFailureFields
          { failureError = if T.null message then pythonExceptionName err else T.take 4096 message
          , failureKind = pythonExceptionName err
          , failureDetails = Null
          , failureRetryable = True
          , failureRetryAfter = Nothing
          }
   in -- 'error': these fields always validate (non-empty kind and error,
      -- bounded length, no details).
      either (error . T.unpack) ActivityError (activityFailure fields)

-- | Rethrow a 'FabricError' as 'pythonActivityError'.
asPythonFailure :: IO a -> IO a
asPythonFailure action = action `catch` (throwIO . pythonActivityError)
