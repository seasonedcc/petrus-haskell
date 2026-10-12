-- | An Engine as a Fabric delivery door (spec/fabric.md §9): the reference
-- passes @engine@ itself as @FabricInbox.delivery_door@.
module Petrus.Fabric.Engine
  ( engineDoor
  , engineInbox
  ) where

import Control.Exception (throwIO)
import Petrus.Engine (Delivered (..), Engine)
import Petrus.Engine qualified as Engine
import Petrus.Fabric.Error (FabricError (..))
import Petrus.Fabric.Ingress
import Petrus.Impetus.Petrinet (netPath)

-- | @engine.deliver(source, tokens, identity=...)@ with no lifecycle scope.
-- A scoped acknowledgement is refused here with the reference bridge's
-- @TypeError@ ('InvalidType'), before anything is acknowledged.
engineDoor :: Engine -> DeliveryDoor
engineDoor engine = DeliveryDoor $ \source tokens identity -> do
  path <- either (throwIO . InvalidValue) pure (netPath source)
  Engine.deliver engine path tokens identity Nothing >>= \case
    Delivered outcome -> pure (DoorFired outcome)
    DeliveredPrior prior -> pure (DoorPrior prior)
    DeliveredScoped _ -> throwIO (InvalidType "delivery door must return FiringOutcome or PriorAcknowledgement")

-- | @FabricInbox(client, engine)@.
engineInbox :: InboxClient -> Engine -> FabricInbox
engineInbox client engine = FabricInbox {client, door = engineDoor engine}
