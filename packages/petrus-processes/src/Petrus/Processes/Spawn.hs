-- | Spawn ports and the @process.spawn@ Activity (a port of
-- @petrus.processes.spawn@, spec/processes.md §11, §13).
module Petrus.Processes.Spawn
  ( spawnActivityName
  , SpawnRegistry (..)
  , ProcessProvisioner (..)
  , spawnActivity
  , spawnInvocation
  , spawnIdempotency
  ) where

import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.Text (Text)
import Petrus.Activity (ActivityInvocation (..), defaultExecutionPolicy)
import Petrus.Fabric.Error
import Petrus.Fabric.Model
import Petrus.Json (Json)
import Petrus.Processes.Model

-- | @SPAWN_ACTIVITY@.
spawnActivityName :: Text
spawnActivityName = "process.spawn"

-- | @SpawnRegistry@: the lineage registry port (§12.3).
data SpawnRegistry = SpawnRegistry
  { claim :: SpawnSpec -> IO SpawnClaim
  , childOf :: Text -> Text -> IO (Maybe Lineage)
  , childrenOf :: Text -> IO [Lineage]
  , parentOf :: Text -> IO (Maybe Lineage)
  }

-- | @ProcessProvisioner@ (§13.1): ensure returns nothing — no live host or
-- credential crosses back.
newtype ProcessProvisioner = ProcessProvisioner {ensure :: Provisioning -> IO ()}

-- | @spawn_idempotency(parent, spawn_id)@: @process.spawn:@ + the child
-- identity (§11.1).
spawnIdempotency :: Text -> Text -> Either FabricError Text
spawnIdempotency parent spawnId = ("process.spawn:" <>) <$> childIdentity parent spawnId

-- | The invocation a spawning handler's @prepare@ returns (the reference
-- demo's @SpawnHandler@): the spec JSON, correlated by @spawn_id@.
spawnInvocation :: SpawnSpec -> ActivityInvocation
spawnInvocation spec =
  ActivityInvocation
    { activity = spawnActivityName
    , input = spawnSpecToData spec
    , policy = defaultExecutionPolicy
    , correlation = Just spec.spawnId
    , idempotency = Just ("process.spawn:" <> spec.child)
    }

-- | @SpawnActivity(registry, provisioner)(invocation)@ (§11.2): claim
-- durably, then ensure, then answer the SpawnOutcome JSON. Refusals are
-- 'FabricError's; wrap the executor in 'Petrus.Fabric.Send.asPythonFailure'
-- to record them as the reference's dispatchers do.
spawnActivity :: SpawnRegistry -> ProcessProvisioner -> ActivityInvocation -> IO Json
spawnActivity registry provisioner inv = do
  unless (inv.activity == spawnActivityName) $
    throwIO (InvalidValue "SpawnActivity only implements 'process.spawn'")
  spec <- orThrow (spawnSpecFromData inv.input)
  expected <- orThrow (spawnIdempotency spec.parent spec.spawnId)
  unless (inv.idempotency == Just expected) $
    throwIO (InvalidValue "process.spawn idempotency must identify the parent and spawn_id")
  claimed <- registry.claim spec
  unless ((claimed.parent, claimed.spawnId, claimed.child) == (spec.parent, spec.spawnId, spec.child)) $
    throwIO (InvalidValue "spawn registry returned a claim for a different identity")
  ep <- orThrow (endpoint claimed.child spec.source spec.capabilities)
  provision <-
    orThrow (provisioning spec.parent spec.spawnId claimed.child spec.processKind ep spec.config spec.replyRoute)
  provisioner.ensure provision
  outcome <- orThrow (spawnOutcome spec.parent spec.spawnId claimed.child ep claimed.priorClaim)
  pure (spawnOutcomeToData outcome)
