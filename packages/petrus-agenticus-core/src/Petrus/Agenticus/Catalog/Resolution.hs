-- | Host-local registration and deterministic Agenticus compatibility
-- resolution (@petrus.agenticus.catalog.resolution@).
--
-- The registry is a pure 'CatalogState' with total transition functions;
-- 'Catalog' is a thread-safe mutable cell over it with the upstream method
-- surface.  Resolution is pure over a captured state, so snapshots can never
-- observe later registrations.
module Petrus.Agenticus.Catalog.Resolution
  ( -- * Issue vocabulary
    CompatibilityIssueCode (..)
  , issueCodeText
    -- * Values
  , CatalogEntry (..)
  , ResolutionRequest
  , mkResolutionRequest
  , ResolutionSnapshot
  , mkResolutionSnapshot
  , snapshotDescriptor
  , snapshotToData
  , snapshotFromData
  , Resolution
  , resolutionCompatible
  , incompatibilities
    -- * Pure registry
  , CatalogState
  , emptyCatalogState
  , stateRevision
  , registerState
  , enableState
  , disableState
  , inspectState
  , resolveState
    -- * Mutable registry
  , Catalog
  , newCatalog
  , catalogRevisionIO
  , register
  , enable
  , disable
  , inspect
  , resolve
  ) where

import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Records (HasField (..))
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Catalog.Result
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Validate
import Petrus.Json (Json (..))

-- | The complete incompatibility vocabulary emitted by Catalog.
data CompatibilityIssueCode
  = NotRegistered
  | NotEnabled
  | MissingSelection
  | SelectionNotRegistered
  | SelectionNotEnabled
  | NameMismatch
  | VersionMismatch
  | MissingCapability
  deriving stock (Eq, Ord, Show, Enum, Bounded)

issueCodeText :: CompatibilityIssueCode -> Text
issueCodeText = \case
  NotRegistered -> "not-registered"
  NotEnabled -> "not-enabled"
  MissingSelection -> "missing-selection"
  SelectionNotRegistered -> "selection-not-registered"
  SelectionNotEnabled -> "selection-not-enabled"
  NameMismatch -> "name-mismatch"
  VersionMismatch -> "version-mismatch"
  MissingCapability -> "missing-capability"

-- | One immutable inspection view of a host registration.
data CatalogEntry = CatalogEntry
  { descriptor :: CapabilityDescriptor
  , enabled :: Bool
  }
  deriving stock (Eq, Show)

identityKey :: DescriptorIdentity -> (Text, Text, Integer)
identityKey i = (kindText i.kind, i.name, i.contractVersion)

-- | Exact component selections for one prospective Episode: at most one per
-- kind, always naming the runtime, stored in canonical order.
newtype ResolutionRequest = ResolutionRequest {_selections :: [DescriptorIdentity]}
  deriving stock (Eq, Show)

instance HasField "selections" ResolutionRequest [DescriptorIdentity] where
  getField r = r._selections

mkResolutionRequest :: [DescriptorIdentity] -> Either AgenticusError ResolutionRequest
mkResolutionRequest picks
  | hasDuplicates picks =
      Left (AgenticusError DuplicateSelectionError "resolution selections must not contain a duplicate exact identity")
  | hasDuplicates kinds =
      Left (AgenticusError AmbiguousSelectionError "resolution selections must contain at most one identity of each kind")
  | KindRuntime `notElem` kinds =
      Left (AgenticusError SelectionError "resolution selections must contain one exact runtime identity")
  | otherwise = Right (ResolutionRequest (sortOn identityKey picks))
  where
    kinds = map (.kind) picks

-- | The immutable, portable descriptor plan captured for one resolved Episode.
data ResolutionSnapshot = ResolutionSnapshot
  { _catalogRevision :: Integer
  , _descriptors :: [CapabilityDescriptor]
  }
  deriving stock (Eq, Show)

instance HasField "catalogRevision" ResolutionSnapshot Integer where
  getField r = r._catalogRevision

instance HasField "descriptors" ResolutionSnapshot [CapabilityDescriptor] where
  getField r = r._descriptors

mkResolutionSnapshot :: Integer -> [CapabilityDescriptor] -> Either AgenticusError ResolutionSnapshot
mkResolutionSnapshot revision ds
  | revision < 0 = Left (valueError "resolution catalog_revision must be a non-negative integer")
  | hasDuplicates identities =
      Left (valueError "resolution snapshot must not contain duplicate descriptor identities")
  | hasDuplicates kinds = Left (valueError "resolution snapshot must contain at most one descriptor of each kind")
  | KindRuntime `notElem` kinds = Left (valueError "resolution snapshot must contain one runtime descriptor")
  | otherwise = Right (ResolutionSnapshot revision (sortOn (identityKey . (.identity)) ds))
  where
    identities = map (.identity) ds
    kinds = map (.kind) identities

-- | The selected descriptor of a kind, if the Episode has one.
snapshotDescriptor :: DescriptorKind -> ResolutionSnapshot -> Maybe CapabilityDescriptor
snapshotDescriptor k s = case filter (\d -> d.identity.kind == k) s.descriptors of
  d : _ -> Just d
  [] -> Nothing

snapshotToData :: ResolutionSnapshot -> Json
snapshotToData s =
  Object
    [ ("schema_version", Int 1)
    , ("catalog_revision", Int s.catalogRevision)
    , ("descriptors", Array (map descriptorToData s.descriptors))
    ]

snapshotFromData :: Json -> Either AgenticusError ResolutionSnapshot
snapshotFromData raw = do
  fields <-
    exactObject
      ["schema_version", "catalog_revision", "descriptors"]
      (valueError "resolution snapshot requires exact schema_version, catalog_revision, and descriptors fields")
      raw
  case member "schema_version" fields of
    Int 1 -> Right ()
    _ -> Left (valueError "resolution snapshot schema_version must be integer 1")
  revision <- case member "catalog_revision" fields of
    Int r | r >= 0 -> Right r
    _ -> Left (valueError "resolution snapshot catalog_revision must be a non-negative integer")
  items <- case member "descriptors" fields of
    Array xs -> Right xs
    _ -> Left (typeError "resolution snapshot descriptors must be a JSON array")
  ds <- traverse descriptorFromData items
  mkResolutionSnapshot revision ds

-- | One deterministic plan or its complete candidate-local incompatibilities.
-- The snapshot exists exactly when every candidate is compatible.
data Resolution = Resolution
  { _request :: ResolutionRequest
  , _results :: [CompatibilityResult]
  , _snapshot :: Maybe ResolutionSnapshot
  }
  deriving stock (Eq, Show)

instance HasField "request" Resolution ResolutionRequest where
  getField r = r._request

instance HasField "results" Resolution [CompatibilityResult] where
  getField r = r._results

instance HasField "snapshot" Resolution (Maybe ResolutionSnapshot) where
  getField r = r._snapshot

resolutionCompatible :: Resolution -> Bool
resolutionCompatible r = r.snapshot /= Nothing

incompatibilities :: Resolution -> [CompatibilityResult]
incompatibilities r = filter (not . null . (.issues)) r.results

-- ---------------------------------------------------------------------------
-- Pure registry

data CatalogState = CatalogState
  { entries :: Map DescriptorIdentity CatalogEntry
  , revision :: Integer
  }

emptyCatalogState :: CatalogState
emptyCatalogState = CatalogState Map.empty 0

stateRevision :: CatalogState -> Integer
stateRevision s = s.revision

-- | Register one disabled descriptor, refusing duplicate or conflicting
-- identity.
registerState :: CapabilityDescriptor -> CatalogState -> Either AgenticusError CatalogState
registerState d s = do
  refuseImpossibleRequirements d
  case Map.lookup d.identity s.entries of
    Just existing
      | existing.descriptor == d ->
          Left (AgenticusError DuplicateRegistrationError ("descriptor is already registered: " <> d.identity.name))
      | otherwise ->
          Left
            ( AgenticusError
                AmbiguousRegistrationError
                ("descriptor identity has conflicting registration envelopes: " <> d.identity.name)
            )
    Nothing -> Right (CatalogState (Map.insert d.identity (CatalogEntry d False) s.entries) (s.revision + 1))

setEnabled :: Bool -> DescriptorIdentity -> CatalogState -> Either AgenticusError CatalogState
setEnabled flag i s = case Map.lookup i s.entries of
  Nothing -> Left (AgenticusError UnknownRegistrationError ("descriptor is not registered: " <> i.name))
  Just entry
    | entry.enabled == flag -> Right s
    | otherwise -> Right (CatalogState (Map.insert i entry {enabled = flag} s.entries) (s.revision + 1))

enableState, disableState :: DescriptorIdentity -> CatalogState -> Either AgenticusError CatalogState
enableState = setEnabled True
disableState = setEnabled False

inspectState :: CatalogState -> [CatalogEntry]
inspectState s = map snd (sortOn (identityKey . fst) (Map.toList s.entries))

refuseImpossibleRequirements :: CapabilityDescriptor -> Either AgenticusError ()
refuseImpossibleRequirements d = mapM_ check allKinds
  where
    check k = do
      let reqs = filter (\r -> r.kind == k) d.requires
          versions = Set.fromList (map (.contractVersion) reqs)
          names = Set.fromList [n | Just n <- map (.name) reqs]
      require
        (Set.size versions <= 1)
        ( AgenticusError
            AmbiguousRegistrationError
            ("descriptor has conflicting " <> kindText k <> " requirement contract versions: " <> d.identity.name)
        )
      require
        (Set.size names <= 1)
        ( AgenticusError
            AmbiguousRegistrationError
            ("descriptor has conflicting " <> kindText k <> " requirement names: " <> d.identity.name)
        )

-- | Validate exactly the request and return every incompatibility found.
resolveState :: ResolutionRequest -> CatalogState -> Resolution
resolveState req s =
  let picked = Map.fromList [(i.kind, i) | i <- req.selections]
      rs = map (checkCandidate picked s.entries) req.selections
      snap
        | all compatible rs =
            either (const Nothing) Just $
              mkResolutionSnapshot s.revision [e.descriptor | i <- req.selections, Just e <- [Map.lookup i s.entries]]
        | otherwise = Nothing
   in Resolution req rs snap

mkIssue :: CompatibilityIssueCode -> Text -> CompatibilityIssue
mkIssue c = compatibilityIssue (issueCodeText c)

checkCandidate
  :: Map DescriptorKind DescriptorIdentity -> Map DescriptorIdentity CatalogEntry -> DescriptorIdentity -> CompatibilityResult
checkCandidate picked es i =
  let found = case Map.lookup i es of
        Nothing -> Set.singleton (mkIssue NotRegistered i.name)
        Just entry ->
          Set.unions
            ( (if entry.enabled then Set.empty else Set.singleton (mkIssue NotEnabled i.name))
                : map (requirementIssues picked es) entry.descriptor.requires
            )
   in either (error . T.unpack . errorMessage) id (mkCompatibilityResult (Just i) (Set.toList found))

requirementIssues
  :: Map DescriptorKind DescriptorIdentity
  -> Map DescriptorIdentity CatalogEntry
  -> CompatibilityRequirement
  -> Set.Set CompatibilityIssue
requirementIssues picked es r = case Map.lookup r.kind picked of
  Nothing -> Set.singleton (mkIssue MissingSelection (kindText r.kind))
  Just selected ->
    let nameIssue = case r.name of
          Just n | selected.name /= n -> [mkIssue NameMismatch n]
          _ -> []
        versionIssue =
          [ mkIssue VersionMismatch (kindText r.kind <> "@" <> T.pack (show r.contractVersion))
          | selected.contractVersion /= r.contractVersion
          ]
        base = Set.fromList (nameIssue <> versionIssue)
     in case Map.lookup selected es of
          Nothing -> Set.insert (mkIssue SelectionNotRegistered selected.name) base
          Just entry ->
            Set.unions
              [ base
              , if entry.enabled then Set.empty else Set.singleton (mkIssue SelectionNotEnabled selected.name)
              , Set.map (mkIssue MissingCapability) (r.capabilities `Set.difference` entry.descriptor.offers)
              ]

-- ---------------------------------------------------------------------------
-- Mutable registry

-- | A mutable host-local registry whose successful resolutions are immutable.
-- Registration never enables a descriptor.
newtype Catalog = Catalog (IORef CatalogState)

newCatalog :: IO Catalog
newCatalog = Catalog <$> newIORef emptyCatalogState

catalogRevisionIO :: Catalog -> IO Integer
catalogRevisionIO (Catalog ref) = stateRevision <$> readIORef ref

transition :: Catalog -> (CatalogState -> Either AgenticusError CatalogState) -> IO ()
transition (Catalog ref) f = do
  outcome <- atomicModifyIORef' ref $ \s -> case f s of
    Left e -> (s, Left e)
    Right s' -> (s', Right ())
  throwLeft outcome

register :: Catalog -> CapabilityDescriptor -> IO ()
register c d = transition c (registerState d)

enable :: Catalog -> DescriptorIdentity -> IO ()
enable c i = transition c (enableState i)

disable :: Catalog -> DescriptorIdentity -> IO ()
disable c i = transition c (disableState i)

inspect :: Catalog -> IO [CatalogEntry]
inspect (Catalog ref) = inspectState <$> readIORef ref

-- | Resolution copies the registry state atomically, then computes outside
-- any lock, like upstream.
resolve :: Catalog -> ResolutionRequest -> IO Resolution
resolve (Catalog ref) req = resolveState req <$> readIORef ref
