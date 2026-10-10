-- | The kernel ingress bridge (a port of @petrus.fabric.ingress@,
-- spec/fabric.md §9): drain a recipient's pending deliveries through a
-- delivery door — normally an Engine's @deliver@ — and acknowledge each
-- with the occurrence the door answered.
module Petrus.Fabric.Ingress
  ( fabricEnvelopeColor
  , DoorAnswer (..)
  , DeliveryDoor (..)
  , InboxClient (..)
  , FabricInbox (..)
  , drain
  , envelopeToken
  ) where

import Control.Exception (throwIO)
import Data.Text (Text)
import Petrus.Fabric.Error (FabricError (..))
import Petrus.Fabric.Model (Envelope, Receipt, envelopeToData)
import Petrus.Impetus.Instance (PriorAcknowledgement (..), ScopedDeliveryAcknowledgement)
import Petrus.Impetus.Instance.Firing (FiringOutcome (..))
import Petrus.Impetus.Petrinet (Token, token)

-- | @FABRIC_ENVELOPE@: the color of every Fabric token (§9.1).
fabricEnvelopeColor :: Text
fabricEnvelopeColor = "FabricEnvelope"

-- | What a delivery door answers. The bridge accepts only a firing outcome
-- or a prior acknowledgement; a scoped acknowledgement (or anything else a
-- door might produce) is the reference's @TypeError@ (§9.3).
data DoorAnswer
  = DoorFired FiringOutcome
  | DoorPrior PriorAcknowledgement
  | DoorScoped ScopedDeliveryAcknowledgement
  deriving stock (Eq, Show)

-- | @DeliveryDoor.deliver(source, tokens, identity=...)@.
newtype DeliveryDoor = DeliveryDoor {deliver :: Text -> [Token] -> Text -> IO DoorAnswer}

-- | The recipient side of a Fabric client.
data InboxClient = InboxClient
  { pending :: Int -> IO [Envelope]
  , acknowledge :: Text -> Text -> Int -> IO Receipt
  }

-- | @FabricInbox(client, delivery_door)@.
data FabricInbox = FabricInbox {client :: InboxClient, door :: DeliveryDoor}

-- | The single token a delivery enters the recipient's net as (§9.1).
envelopeToken :: Envelope -> Token
envelopeToken e = token fabricEnvelopeColor (envelopeToData e)

-- | @FabricInbox.drain(limit)@ (§9.2): deliver each pending envelope, in
-- order, then acknowledge it with the door's occurrence. A door failure
-- propagates; earlier acknowledgements stand and the rest stay pending.
drain :: FabricInbox -> Int -> IO [Receipt]
drain inbox limit = do
  envelopes <- inbox.client.pending limit
  mapM one envelopes
  where
    one e = do
      answer <- inbox.door.deliver e.source [envelopeToken e] e.ingressIdentity
      occurrence <- case answer of
        DoorFired outcome -> pure outcome.occurrence
        DoorPrior prior -> pure prior.occurrence
        DoorScoped _ -> throwIO (InvalidType "delivery door must return FiringOutcome or PriorAcknowledgement")
      inbox.client.acknowledge e.sender e.deliveryId occurrence
