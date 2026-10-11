-- | The interoperable @fabric.send@ Activity profile (spec/fabric.md §11):
-- the reference demos' @SendActivity@ and the handlers' invocation shape,
-- so an Activity a Python Engine requested can be executed here, and the
-- reverse.
module Petrus.Fabric.Send
  ( sendActivityName
  , sendInvocation
  , sendActivity
  , sendResult
  ) where

import Control.Exception (throwIO)
import Data.Text (Text)
import Petrus.Activity
  ( ActivityInvocation (..)
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
-- 'FabricError's, which every dispatcher records under the Python class
-- the reference raises ("Petrus.Fabric.Error").
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
