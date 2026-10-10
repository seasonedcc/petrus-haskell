{-# LANGUAGE DataKinds #-}

-- | Strict, transport-neutral process lifecycle values (a port of
-- @petrus.processes.model@, spec/processes.md §9–§12).
--
-- As in "Petrus.Fabric.Model", each value is built only by its validating
-- constructor and read through record dot syntax.
module Petrus.Processes.Model
  ( childIdentity
    -- * SpawnSpec (§9)
  , SpawnSpec
  , spawnSpec
  , spawnSpecToData
  , spawnSpecFromData
    -- * Provisioning (§13.1)
  , Provisioning
  , provisioning
    -- * SpawnClaim (§12.3)
  , SpawnClaim
  , spawnClaim
    -- * SpawnOutcome (§11.3)
  , SpawnOutcome
  , spawnOutcome
  , spawnOutcomeToData
  , spawnOutcomeFromData
    -- * Lineage (§12.3)
  , Lineage
  , lineage
  ) where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Records (HasField (..))
import Petrus.Fabric.Error
import Petrus.Fabric.Model
import Petrus.Json (Json (..))

-- | @child_identity(parent, spawn_id)@ (§10): @process-v1-@ and the SHA-256
-- hex of @impetus-process-child\\0@ followed by the canonical
-- @{"version":1,"parent":…,"spawn_id":…}@.
childIdentity :: Text -> Text -> Either FabricError Text
childIdentity parent spawnId = do
  parent' <- fabricText "parent" parent
  spawnId' <- fabricText "spawn_id" spawnId
  identity <- canonicalBytes (Object [("version", Int 1), ("parent", String parent'), ("spawn_id", String spawnId')])
  pure ("process-v1-" <> sha256Hex (BS.append "impetus-process-child\0" identity))

-- @_mapping(value, name)@: an object, detached.
mapping :: Text -> Json -> Either FabricError Json
mapping name value = jsonObject name value >> jsonCopy name value

textMember :: Text -> Json -> Either FabricError Text
textMember name = \case
  String s -> fabricText name s
  _ -> Left (InvalidValue (name <> " must be a non-empty string of at most 1024 UTF-8 bytes"))

versionOne :: Text -> Json -> Either FabricError ()
versionOne message = \case
  Int 1 -> Right ()
  _ -> Left (InvalidValue message)

-- ---------------------------------------------------------------------------
-- SpawnSpec

-- | What a parent asks to spawn (§9).
data SpawnSpec = SpawnSpec
  { ssParent :: Text
  , ssSpawnId :: Text
  , ssProcessKind :: Text
  , ssSource :: Text
  , ssCapabilities :: Json
  , ssConfig :: Json
  , ssReplyRoute :: Maybe ReplyRoute
  , ssChild :: ~Text
  , ssDigest :: ~Text
  }

instance Eq SpawnSpec where
  a == b =
    (a.ssParent, a.ssSpawnId, a.ssProcessKind, a.ssSource, a.ssReplyRoute)
      == (b.ssParent, b.ssSpawnId, b.ssProcessKind, b.ssSource, b.ssReplyRoute)
      && a.ssCapabilities == b.ssCapabilities
      && a.ssConfig == b.ssConfig

instance Show SpawnSpec where
  showsPrec d s = showParen (d > 10) (showString "SpawnSpec " . showsPrec 11 (spawnSpecToData s))

instance HasField "parent" SpawnSpec Text where getField s = s.ssParent
instance HasField "spawnId" SpawnSpec Text where getField s = s.ssSpawnId
instance HasField "processKind" SpawnSpec Text where getField s = s.ssProcessKind
instance HasField "source" SpawnSpec Text where getField s = s.ssSource
instance HasField "capabilities" SpawnSpec Json where getField s = s.ssCapabilities
instance HasField "config" SpawnSpec Json where getField s = s.ssConfig
instance HasField "replyRoute" SpawnSpec (Maybe ReplyRoute) where getField s = s.ssReplyRoute
-- | @child_identity(parent, spawn_id)@.
instance HasField "child" SpawnSpec Text where getField s = s.ssChild
-- | SHA-256 hex of the canonical spec JSON.
instance HasField "digest" SpawnSpec Text where getField s = s.ssDigest

-- | @SpawnSpec(parent, spawn_id, process_kind, source, capabilities, config,
-- reply_route)@.
spawnSpec :: Text -> Text -> Text -> Text -> Json -> Json -> Maybe ReplyRoute -> Either FabricError SpawnSpec
spawnSpec parent spawnId processKind source capabilities config route = do
  parent' <- fabricText "parent" parent
  spawnId' <- fabricText "spawn_id" spawnId
  processKind' <- fabricText "process_kind" processKind
  source' <- fabricText "source" source
  capabilities' <- mapping "capabilities" capabilities
  config' <- mapping "config" config
  case route of
    Just r | r.instanceId /= parent' -> Left (InvalidValue "spawn reply_route must belong to the parent process")
    _ -> Right ()
  child <- childIdentity parent' spawnId'
  let built = SpawnSpec parent' spawnId' processKind' source' capabilities' config' route child (specDigest built)
  pure built

specDigest :: SpawnSpec -> Text
specDigest s = either (error . show) sha256Hex (canonicalBytes (spawnSpecToData s))

spawnSpecToData :: SpawnSpec -> Json
spawnSpecToData s =
  Object
    [ ("version", Int 1)
    , ("parent", String s.ssParent)
    , ("spawn_id", String s.ssSpawnId)
    , ("process_kind", String s.ssProcessKind)
    , ("source", String s.ssSource)
    , ("capabilities", s.ssCapabilities)
    , ("config", s.ssConfig)
    , ("reply_route", maybe Null replyRouteToData s.ssReplyRoute)
    ]

spawnSpecFromData :: Json -> Either FabricError SpawnSpec
spawnSpecFromData value = do
  let message = "spawn spec requires exact version-1 fields"
  m <-
    exactObject
      ["version", "parent", "spawn_id", "process_kind", "source", "capabilities", "config", "reply_route"]
      message
      value
  versionOne message (m Map.! "version")
  _ <- jsonObject "capabilities" (m Map.! "capabilities")
  _ <- jsonObject "config" (m Map.! "config")
  parent <- textMember "parent" (m Map.! "parent")
  spawnId <- textMember "spawn_id" (m Map.! "spawn_id")
  processKind <- textMember "process_kind" (m Map.! "process_kind")
  source <- textMember "source" (m Map.! "source")
  route <- case m Map.! "reply_route" of
    Null -> Right Nothing
    other -> Just <$> replyRouteFromData other
  spawnSpec parent spawnId processKind source (m Map.! "capabilities") (m Map.! "config") route

-- ---------------------------------------------------------------------------
-- Provisioning

-- | What a provisioner is asked to ensure (§13.1). It carries no
-- credential.
data Provisioning = Provisioning
  { prParent :: Text
  , prSpawnId :: Text
  , prChild :: Text
  , prProcessKind :: Text
  , prEndpoint :: Endpoint
  , prConfig :: Json
  , prReplyRoute :: Maybe ReplyRoute
  }
  deriving stock (Eq, Show)

instance HasField "parent" Provisioning Text where getField p = p.prParent
instance HasField "spawnId" Provisioning Text where getField p = p.prSpawnId
instance HasField "child" Provisioning Text where getField p = p.prChild
instance HasField "processKind" Provisioning Text where getField p = p.prProcessKind
instance HasField "endpoint" Provisioning Endpoint where getField p = p.prEndpoint
instance HasField "config" Provisioning Json where getField p = p.prConfig
instance HasField "replyRoute" Provisioning (Maybe ReplyRoute) where getField p = p.prReplyRoute

provisioning :: Text -> Text -> Text -> Text -> Endpoint -> Json -> Maybe ReplyRoute -> Either FabricError Provisioning
provisioning parent spawnId child processKind ep config route = do
  parent' <- fabricText "parent" parent
  spawnId' <- fabricText "spawn_id" spawnId
  child' <- fabricText "child" child
  processKind' <- fabricText "process_kind" processKind
  expected <- childIdentity parent' spawnId'
  if child' /= expected
    then Left (InvalidValue "provisioning child must match its parent-scoped spawn identity")
    else Right ()
  if ep.recipient /= child'
    then Left (InvalidValue "provisioning endpoint recipient must be the child process")
    else Right ()
  config' <- case config of
    Object _ -> mapping "config" config
    _ -> Left (InvalidType "config must be a JSON object")
  case route of
    Just r | r.instanceId /= parent' -> Left (InvalidValue "provisioning reply_route must belong to the parent process")
    _ -> Right ()
  pure (Provisioning parent' spawnId' child' processKind' ep config' route)

-- ---------------------------------------------------------------------------
-- SpawnClaim

-- | A registry claim (§12.3).
data SpawnClaim = SpawnClaim {scParent :: Text, scSpawnId :: Text, scChild :: Text, scPriorClaim :: Bool}
  deriving stock (Eq, Show)

instance HasField "parent" SpawnClaim Text where getField c = c.scParent
instance HasField "spawnId" SpawnClaim Text where getField c = c.scSpawnId
instance HasField "child" SpawnClaim Text where getField c = c.scChild
instance HasField "priorClaim" SpawnClaim Bool where getField c = c.scPriorClaim
instance HasField "lineage" SpawnClaim Lineage where
  getField c = Lineage c.scParent c.scSpawnId c.scChild

spawnClaim :: Text -> Text -> Text -> Bool -> Either FabricError SpawnClaim
spawnClaim parent spawnId child prior = do
  (parent', spawnId', child') <- identified "spawn claim child must match its parent-scoped spawn identity" parent spawnId child
  pure (SpawnClaim parent' spawnId' child' prior)

identified :: Text -> Text -> Text -> Text -> Either FabricError (Text, Text, Text)
identified message parent spawnId child = do
  parent' <- fabricText "parent" parent
  spawnId' <- fabricText "spawn_id" spawnId
  child' <- fabricText "child" child
  expected <- childIdentity parent' spawnId'
  if child' /= expected then Left (InvalidValue message) else Right (parent', spawnId', child')

-- ---------------------------------------------------------------------------
-- SpawnOutcome

-- | The @process.spawn@ Activity result (§11.3).
data SpawnOutcome = SpawnOutcome
  { soParent :: Text
  , soSpawnId :: Text
  , soChild :: Text
  , soEndpoint :: Endpoint
  , soPriorClaim :: Bool
  }
  deriving stock (Eq, Show)

instance HasField "parent" SpawnOutcome Text where getField o = o.soParent
instance HasField "spawnId" SpawnOutcome Text where getField o = o.soSpawnId
instance HasField "child" SpawnOutcome Text where getField o = o.soChild
instance HasField "endpoint" SpawnOutcome Endpoint where getField o = o.soEndpoint
instance HasField "priorClaim" SpawnOutcome Bool where getField o = o.soPriorClaim

spawnOutcome :: Text -> Text -> Text -> Endpoint -> Bool -> Either FabricError SpawnOutcome
spawnOutcome parent spawnId child ep prior = do
  (parent', spawnId', child') <- identified "spawn outcome child must match its parent-scoped spawn identity" parent spawnId child
  if ep.recipient /= child'
    then Left (InvalidValue "spawn outcome endpoint must address the child process")
    else Right (SpawnOutcome parent' spawnId' child' ep prior)

spawnOutcomeToData :: SpawnOutcome -> Json
spawnOutcomeToData o =
  Object
    [ ("version", Int 1)
    , ("parent", String o.soParent)
    , ("spawn_id", String o.soSpawnId)
    , ("child", String o.soChild)
    , ("endpoint", endpointToData o.soEndpoint)
    , ("prior_claim", Bool o.soPriorClaim)
    ]

spawnOutcomeFromData :: Json -> Either FabricError SpawnOutcome
spawnOutcomeFromData value = do
  let message = "spawn outcome requires exact version-1 fields"
  m <- exactObject ["version", "parent", "spawn_id", "child", "endpoint", "prior_claim"] message value
  versionOne message (m Map.! "version")
  prior <- case m Map.! "prior_claim" of
    Bool b -> Right b
    _ -> Left (InvalidType "prior_claim must be bool")
  parent <- textMember "parent" (m Map.! "parent")
  spawnId <- textMember "spawn_id" (m Map.! "spawn_id")
  child <- textMember "child" (m Map.! "child")
  ep <- endpointFromData (m Map.! "endpoint")
  spawnOutcome parent spawnId child ep prior

-- ---------------------------------------------------------------------------
-- Lineage

-- | One parent-to-child lineage fact (§12.3).
data Lineage = Lineage {lnParent :: Text, lnSpawnId :: Text, lnChild :: Text}
  deriving stock (Eq, Ord, Show)

instance HasField "parent" Lineage Text where getField l = l.lnParent
instance HasField "spawnId" Lineage Text where getField l = l.lnSpawnId
instance HasField "child" Lineage Text where getField l = l.lnChild

lineage :: Text -> Text -> Text -> Either FabricError Lineage
lineage parent spawnId child = do
  (parent', spawnId', child') <- identified "lineage child must match its parent-scoped spawn identity" parent spawnId child
  pure (Lineage parent' spawnId' child')
