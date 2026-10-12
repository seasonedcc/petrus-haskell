-- | The authenticated PostgreSQL spawn-lineage registry (a port of
-- @petrus.processes.postgres@, spec/processes.md §12), and the reference
-- provisioning profile of §13.2.
module Petrus.Processes.Postgres
  ( -- * Schema (§12.1–§12.2)
    ensureLifecycleSchema
  , lifecycleDdl
    -- * The registry (§12.3)
  , PostgresSpawnRegistry
  , postgresSpawnRegistry
  , registryParent
  , claim
  , childOf
  , childrenOf
  , parentOf
  , spawnRegistry
    -- * The reference provisioning profile (§13.2)
  , referenceProvisioner
  , hmacChildCredential
  ) where

import Control.Exception (catch, throwIO)
import Control.Monad (forM, unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString.Base64.URL qualified as Base64
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Fabric.Error
import Petrus.Fabric.Model
import Petrus.Fabric.Postgres (PostgresFabric, postgresFabric)
import Petrus.Fabric.Postgres qualified as Fabric
import Petrus.Json (Json (..))
import Petrus.Postgres
  ( Connection
  , Sql
  , autocommit
  , column
  , decodeInt
  , decodeText
  , execute
  , execute_
  , intParam
  , query
  , queryFirst
  , textParam
  , withConnection
  )
import Petrus.Processes.Model
import Petrus.Processes.Spawn (ProcessProvisioner (..), SpawnRegistry (..))
import Petrus.Telemetry (emit, getLogger)
import Petrus.Telemetry qualified as Telemetry

log' :: Telemetry.TelemetryLogger
log' = getLogger "impetus" Nothing

-- | @_DDL@, verbatim (§12.1).
lifecycleDdl :: [Sql]
lifecycleDdl =
  [ "CREATE SCHEMA IF NOT EXISTS impetus_lifecycle"
  , "CREATE TABLE IF NOT EXISTS impetus_lifecycle.schema_metadata (component text PRIMARY KEY, version integer NOT NULL)"
  , "CREATE TABLE IF NOT EXISTS impetus_lifecycle.spawns (\n        parent text NOT NULL, spawn_id text NOT NULL, child text NOT NULL UNIQUE,\n        spec_digest text NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),\n        PRIMARY KEY (parent, spawn_id))"
  ]

-- | @ensure_lifecycle_schema(connection)@ (§12.2): provision without
-- committing the caller's transaction; refuse an unversioned @spawns@
-- table or any version other than 1.
ensureLifecycleSchema :: Connection -> IO ()
ensureLifecycleSchema connection = do
  exists <- queryFirst connection "SELECT 1 FROM pg_namespace WHERE nspname = 'impetus_lifecycle'" []
  case exists of
    Nothing -> pure ()
    Just _ -> do
      metadata <- queryFirst connection "SELECT to_regclass('impetus_lifecycle.schema_metadata')" []
      when (absent metadata) $ do
        known <- queryFirst connection "SELECT to_regclass('impetus_lifecycle.spawns')" []
        unless (absent known) $
          throwIO
            (SchemaRefused "the impetus_lifecycle schema contains an unversioned spawns table: refusing unknown shape")
  mapM_ (\statement -> execute_ connection statement []) lifecycleDdl
  execute_
    connection
    "INSERT INTO impetus_lifecycle.schema_metadata (component, version)\n        VALUES ('lifecycle', %s) ON CONFLICT DO NOTHING"
    [intParam 1]
  row <- queryFirst connection "SELECT version FROM impetus_lifecycle.schema_metadata WHERE component = 'lifecycle'" []
  let found = case row of
        Just [Just v] -> either (const Nothing) Just (decodeInt v)
        _ -> Nothing
  unless (found == Just 1) $
    throwIO
      ( SchemaRefused
          ( "the database speaks impetus_lifecycle schema version "
              <> maybe "None" (T.pack . show) found
              <> ", but this runtime requires version 1; migrate deliberately"
          )
      )
  where
    absent = maybe True (all (== Nothing))

-- | @PostgresSpawnRegistry(connection, parent, credential)@: bound to one
-- parent; every claim is committed before it returns, so the connection
-- must be autocommit.
data PostgresSpawnRegistry = PostgresSpawnRegistry
  { connection :: Connection
  , parent :: Text
  , fabric :: PostgresFabric
  }

postgresSpawnRegistry :: Connection -> Text -> Text -> IO PostgresSpawnRegistry
postgresSpawnRegistry connection parent' credential = do
  Telemetry.validateTelemetryEnvironment
  mode <- autocommit connection
  unless mode $ throwIO (InvalidValue "PostgresSpawnRegistry requires an autocommit connection")
  parent <- orThrow (fabricText "parent" parent')
  PostgresSpawnRegistry connection parent <$> postgresFabric connection parent credential

registryParent :: PostgresSpawnRegistry -> Text
registryParent registry = registry.parent

auth :: PostgresSpawnRegistry -> IO ()
auth registry =
  Fabric.authenticate registry.fabric `catch` \case
    Denied _ -> do
      emit log' "lifecycle_denied" [("operation", String "authenticate"), ("instance", String registry.parent)]
      throwIO (Denied ("lifecycle authentication failed for " <> pyRepr registry.parent))
    other -> throwIO other

authBound :: PostgresSpawnRegistry -> Text -> IO ()
authBound registry parent = do
  unless (parent == registry.parent) $ throwIO (Denied "lineage parent must match the authenticated registry")
  auth registry

-- | @claim(spec)@: insert-or-verify the lineage row; @prior_claim@ is whether
-- the row already existed.
claim :: PostgresSpawnRegistry -> SpawnSpec -> IO SpawnClaim
claim registry spec = do
  unless (spec.parent == registry.parent) $ throwIO (Denied "spawn parent must match the authenticated registry")
  auth registry
  inserted <-
    execute
      registry.connection
      "INSERT INTO impetus_lifecycle.spawns (parent, spawn_id, child, spec_digest) VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING"
      [textParam spec.parent, textParam spec.spawnId, textParam spec.child, textParam spec.digest]
  row <-
    queryFirst
      registry.connection
      "SELECT child, spec_digest FROM impetus_lifecycle.spawns WHERE parent = %s AND spawn_id = %s"
      [textParam spec.parent, textParam spec.spawnId]
  let stored = case row of
        Just [Just c, Just d] -> Just (TE.decodeUtf8 c, TE.decodeUtf8 d)
        _ -> Nothing
  unless (stored == Just (spec.child, spec.digest)) $ do
    emit
      log'
      "lifecycle_conflict"
      [("operation", String "spawn"), ("parent", String spec.parent), ("spawn_id", String spec.spawnId)]
    throwIO
      ( Conflict
          ("spawn identity conflict for (" <> pyRepr spec.parent <> ", " <> pyRepr spec.spawnId <> "): content changed")
      )
  let prior = inserted == 0
  emit
    log'
    "lifecycle_claimed"
    [ ("parent", String spec.parent)
    , ("spawn_id", String spec.spawnId)
    , ("child", String spec.child)
    , ("prior_claim", Bool prior)
    ]
  orThrow (spawnClaim spec.parent spec.spawnId spec.child prior)

-- | @child_of(parent, spawn_id)@.
childOf :: PostgresSpawnRegistry -> Text -> Text -> IO (Maybe Lineage)
childOf registry parent' spawnId' = do
  parent <- orThrow (fabricText "parent" parent')
  spawnId <- orThrow (fabricText "spawn_id" spawnId')
  authBound registry parent
  row <-
    queryFirst
      registry.connection
      "SELECT child FROM impetus_lifecycle.spawns WHERE parent = %s AND spawn_id = %s"
      [textParam parent, textParam spawnId]
  case row of
    Just [Just child] -> Just <$> orThrow (lineage parent spawnId (TE.decodeUtf8 child))
    _ -> pure Nothing

-- | @children_of(parent)@, ordered by @spawn_id@.
childrenOf :: PostgresSpawnRegistry -> Text -> IO [Lineage]
childrenOf registry parent' = do
  parent <- orThrow (fabricText "parent" parent')
  authBound registry parent
  rows <-
    query
      registry.connection
      "SELECT spawn_id, child FROM impetus_lifecycle.spawns WHERE parent = %s ORDER BY spawn_id"
      [textParam parent]
  forM rows $ \case
    [s, c] -> do
      (spawnId, child) <- either (throwIO . userError) pure ((,) <$> column decodeText s <*> column decodeText c)
      orThrow (lineage parent spawnId child)
    other -> throwIO (userError ("unexpected impetus_lifecycle row: " <> show other))

-- | @parent_of(child)@: absent for an unknown child, denied for another
-- parent's.
parentOf :: PostgresSpawnRegistry -> Text -> IO (Maybe Lineage)
parentOf registry child' = do
  child <- orThrow (fabricText "child" child')
  auth registry
  row <-
    queryFirst
      registry.connection
      "SELECT parent, spawn_id FROM impetus_lifecycle.spawns WHERE child = %s"
      [textParam child]
  case row of
    Just [Just p, Just s] -> do
      let parent = TE.decodeUtf8 p
      unless (parent == registry.parent) $ throwIO (Denied "child does not belong to the authenticated parent")
      Just <$> orThrow (lineage parent (TE.decodeUtf8 s) child)
    _ -> pure Nothing

-- | The registry as the 'SpawnRegistry' port.
spawnRegistry :: PostgresSpawnRegistry -> SpawnRegistry
spawnRegistry registry =
  SpawnRegistry
    { claim = claim registry
    , childOf = childOf registry
    , childrenOf = childrenOf registry
    , parentOf = parentOf registry
    }

-- | The reference demo's child credential: padded base64url of
-- HMAC-SHA256(workspace key, child) — deterministic, so a retried @ensure@
-- re-registers with the identical credential (§13.2).
hmacChildCredential :: ByteString -> Text -> Text
hmacChildCredential key child = TE.decodeLatin1 (Base64.encode (SHA256.hmac key (TE.encodeUtf8 child)))

-- | The reference provisioning profile (§13.2) over a fresh autocommit
-- connection per @ensure@: register the child, expose its endpoint source,
-- offer it under the process kind, grant the parent; and when there is a
-- reply route, expose it on the parent and grant the child.
referenceProvisioner :: ByteString -> Text -> (Text -> Text) -> ProcessProvisioner
referenceProvisioner dsn parentCredential childCredential =
  ProcessProvisioner $ \p -> withConnection dsn True $ \connection -> do
    let credential = childCredential p.child
    Fabric.registerProcess connection p.child credential
    child <- postgresFabric connection p.child credential
    Fabric.exposeSource child p.endpoint.source
    Fabric.offerService child p.endpoint.source p.processKind p.endpoint.capabilities
    Fabric.grant child p.parent p.endpoint.source
    case p.replyRoute of
      Nothing -> pure ()
      Just route -> do
        parentClient <- postgresFabric connection p.parent parentCredential
        Fabric.exposeSource parentClient route.source
        Fabric.grant parentClient p.child route.source
