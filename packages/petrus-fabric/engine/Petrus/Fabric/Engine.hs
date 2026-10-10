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
engineDoor :: Engine -> DeliveryDoor
engineDoor engine = DeliveryDoor $ \source tokens identity -> do
  path <- either (throwIO . InvalidValue) pure (netPath source)
  Engine.deliver engine path tokens identity Nothing >>= \case
    Delivered outcome -> pure (DoorFired outcome)
    DeliveredPrior prior -> pure (DoorPrior prior)
    DeliveredScoped scoped -> pure (DoorScoped scoped)

-- | @FabricInbox(client, engine)@.
engineInbox :: InboxClient -> Engine -> FabricInbox
engineInbox client engine = FabricInbox {client, door = engineDoor engine}
