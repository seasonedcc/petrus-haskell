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

import Data.Text (Text)
import Petrus.Fabric.Model (Envelope, Receipt, envelopeToData)
import Petrus.Impetus.Instance (PriorAcknowledgement (..))
import Petrus.Impetus.Instance.Firing (FiringOutcome (..))
import Petrus.Impetus.Petrinet (Token, token)

-- | @FABRIC_ENVELOPE@: the color of every Fabric token (§9.1).
fabricEnvelopeColor :: Text
fabricEnvelopeColor = "FabricEnvelope"

-- | What a delivery door answers: a firing outcome or a prior
-- acknowledgement, the only answers the bridge accepts (§9.3). The
-- reference checks the answer's type at run time and raises @TypeError@
-- for anything else; here a door cannot answer anything else, and a door
-- whose underlying call can produce another answer (the Engine's scoped
-- acknowledgement) refuses it itself, as 'InvalidType'.
data DoorAnswer
  = DoorFired FiringOutcome
  | DoorPrior PriorAcknowledgement
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
      let occurrence = case answer of
            DoorFired outcome -> outcome.occurrence
            DoorPrior prior -> prior.occurrence
      inbox.client.acknowledge e.sender e.deliveryId occurrence
