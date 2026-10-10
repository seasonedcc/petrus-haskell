-- | Provider-neutral component identities and capability descriptors
-- (@petrus.agenticus.catalog.descriptor@).
module Petrus.Agenticus.Catalog.Descriptor
  ( -- * Kinds
    DescriptorKind (..)
  , allKinds
  , kindText
  , parseKind
    -- * Identities
  , DescriptorIdentity (kind, name, contractVersion)
  , mkDescriptorIdentity
  , descriptorIdentity
  , identityToData
  , identityFromData
    -- * Requirements
  , CompatibilityRequirement (kind, name, contractVersion, capabilities)
  , mkCompatibilityRequirement
  , requirementToData
  , requirementFromData
    -- * Descriptors
  , CapabilityDescriptor (identity, offers, requires)
  , mkCapabilityDescriptor
  , capabilityDescriptor
  , descriptorToData
  , descriptorFromData
    -- * Shared decoding helpers
  , schemaVersion
  , checkCapabilities
  ) where

import Data.List (sortOn)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Validate
import Petrus.Json (Json (..))

schemaVersion :: Integer
schemaVersion = 1

-- | The exact component kinds a host may register with Catalog.
data DescriptorKind
  = KindConnection
  | KindProgram
  | KindRuntime
  | KindHands
  | KindTerritory
  | KindContinuation
  | KindEffect
  deriving stock (Eq, Show, Enum, Bounded)

-- | Python @StrEnum@ ordering: by value.
instance Ord DescriptorKind where
  compare a b = compare (kindText a) (kindText b)

-- | In declaration order (Python's @for kind in DescriptorKind@).
allKinds :: [DescriptorKind]
allKinds = [minBound .. maxBound]

kindText :: DescriptorKind -> Text
kindText = \case
  KindConnection -> "connection"
  KindProgram -> "program"
  KindRuntime -> "runtime"
  KindHands -> "hands"
  KindTerritory -> "territory"
  KindContinuation -> "continuation"
  KindEffect -> "effect"

parseKind :: Text -> Maybe DescriptorKind
parseKind t = lookup t [(kindText k, k) | k <- allKinds]

nameMessage :: Text -> Text
nameMessage label = label <> " must be a non-empty, trimmed string of at most 256 UTF-8 bytes"

positiveVersion :: Text -> Integer -> Either AgenticusError Integer
positiveVersion label v
  | v > 0 = Right v
  | otherwise = Left (valueError (label <> " must be a positive integer"))

positiveVersionJson :: Text -> Json -> Either AgenticusError Integer
positiveVersionJson label = \case
  Int v -> positiveVersion label v
  _ -> Left (valueError (label <> " must be a positive integer"))

textJson :: Text -> Json -> Either AgenticusError Text
textJson label = \case
  String t -> boundedText (nameMessage label) t
  _ -> Left (valueError (nameMessage label))

-- | Stable identity and contract version for one registered component.
-- Ordered like the frozen dataclass: by kind value, name, then version.
data DescriptorIdentity = DescriptorIdentity
  { kind :: DescriptorKind
  , name :: Text
  , contractVersion :: Integer
  }
  deriving stock (Eq, Ord, Show)

mkDescriptorIdentity :: DescriptorKind -> Text -> Integer -> Either AgenticusError DescriptorIdentity
mkDescriptorIdentity k n v =
  DescriptorIdentity k
    <$> boundedText (nameMessage "descriptor name") n
    <*> positiveVersion "descriptor contract_version" v

-- | 'mkDescriptorIdentity' for literals known to be valid; a programming
-- error otherwise.
descriptorIdentity :: DescriptorKind -> Text -> Integer -> DescriptorIdentity
descriptorIdentity k n v = either (error . T.unpack . errorMessage) id (mkDescriptorIdentity k n v)

identityToData :: DescriptorIdentity -> Json
identityToData i =
  Object
    [ ("kind", String (kindText i.kind))
    , ("name", String i.name)
    , ("contract_version", Int i.contractVersion)
    ]

identityFromData :: Json -> Either AgenticusError DescriptorIdentity
identityFromData raw = do
  fields <-
    exactObject
      ["kind", "name", "contract_version"]
      (valueError "descriptor identity requires exact kind, name, and contract_version fields")
      raw
  k <- case member "kind" fields of
    String t | Just k <- parseKind t -> Right k
    _ -> Left (valueError "descriptor identity kind is not supported")
  n <- textJson "descriptor name" (member "name" fields)
  v <- positiveVersionJson "descriptor contract_version" (member "contract_version" fields)
  pure (DescriptorIdentity k n v)

-- | @_capabilities@ for already-typed text.
checkCapabilities :: Text -> [Text] -> Either AgenticusError (Set Text)
checkCapabilities label =
  capabilitySet (nameMessage (label <> " item")) (label <> " must not contain duplicate capability keys")

-- | @_capabilities@ for a decoded JSON array.
capabilitiesJson :: Text -> [Json] -> Either AgenticusError (Set Text)
capabilitiesJson label items = do
  texts <- traverse (textJson (label <> " item")) items
  checkCapabilities label texts

-- | One exact-kind requirement with opaque capability keys.
data CompatibilityRequirement = CompatibilityRequirement
  { kind :: DescriptorKind
  , name :: Maybe Text
  , contractVersion :: Integer
  , capabilities :: Set Text
  }
  deriving stock (Eq, Show)

mkCompatibilityRequirement
  :: DescriptorKind -> Maybe Text -> Integer -> [Text] -> Either AgenticusError CompatibilityRequirement
mkCompatibilityRequirement k n v caps =
  CompatibilityRequirement k
    <$> traverse (boundedText (nameMessage "requirement name")) n
    <*> positiveVersion "requirement contract_version" v
    <*> checkCapabilities "requirement capabilities" caps

requirementToData :: CompatibilityRequirement -> Json
requirementToData r =
  Object
    [ ("kind", String (kindText r.kind))
    , ("name", maybe Null String r.name)
    , ("contract_version", Int r.contractVersion)
    , ("capabilities", Array (map String (Set.toAscList r.capabilities)))
    ]

requirementFromData :: Json -> Either AgenticusError CompatibilityRequirement
requirementFromData raw = do
  fields <-
    exactObject
      ["kind", "name", "contract_version", "capabilities"]
      (valueError "compatibility requirement requires exact kind, name, contract_version, and capabilities fields")
      raw
  n <- case member "name" fields of
    Null -> Right Nothing
    other -> Just <$> textJson "requirement name" other
  caps <- case member "capabilities" fields of
    Array items -> Right items
    _ -> Left (typeError "requirement capabilities must be a JSON array")
  k <- case member "kind" fields of
    String t | Just k <- parseKind t -> Right k
    _ -> Left (valueError "requirement kind is not supported")
  v <- positiveVersionJson "requirement contract_version" (member "contract_version" fields)
  CompatibilityRequirement k n v <$> capabilitiesJson "requirement capabilities" caps

requirementKey :: CompatibilityRequirement -> (Text, Text, Integer, [Text])
requirementKey r = (kindText r.kind, maybe "" id r.name, r.contractVersion, Set.toAscList r.capabilities)

-- | One registration envelope with opaque offers and typed requirements.
-- @requires@ is stored in canonical order.
data CapabilityDescriptor = CapabilityDescriptor
  { identity :: DescriptorIdentity
  , offers :: Set Text
  , requires :: [CompatibilityRequirement]
  }
  deriving stock (Eq, Show)

mkCapabilityDescriptor
  :: DescriptorIdentity -> [Text] -> [CompatibilityRequirement] -> Either AgenticusError CapabilityDescriptor
mkCapabilityDescriptor i offered reqs = do
  checked <- checkCapabilities "descriptor offers" offered
  build i checked reqs

build :: DescriptorIdentity -> Set Text -> [CompatibilityRequirement] -> Either AgenticusError CapabilityDescriptor
build i offered reqs
  | hasDuplicateRequirements reqs = Left (valueError "descriptor requires must not contain duplicate requirements")
  | otherwise = Right (CapabilityDescriptor i offered (sortOn requirementKey reqs))
  where
    hasDuplicateRequirements xs = hasDuplicates (map requirementKeyFull xs)
    requirementKeyFull r = (kindText r.kind, r.name, r.contractVersion, Set.toAscList r.capabilities)

-- | 'mkCapabilityDescriptor' for literals known to be valid.
capabilityDescriptor :: DescriptorIdentity -> [Text] -> [CompatibilityRequirement] -> CapabilityDescriptor
capabilityDescriptor i offered reqs = either (error . T.unpack . errorMessage) id (mkCapabilityDescriptor i offered reqs)

descriptorToData :: CapabilityDescriptor -> Json
descriptorToData d =
  Object
    [ ("schema_version", Int schemaVersion)
    , ("identity", identityToData d.identity)
    , ("offers", Array (map String (Set.toAscList d.offers)))
    , ("requires", Array (map requirementToData d.requires))
    ]

descriptorFromData :: Json -> Either AgenticusError CapabilityDescriptor
descriptorFromData raw = do
  fields <-
    exactObject
      ["schema_version", "identity", "offers", "requires"]
      (valueError "capability descriptor requires exact schema_version, identity, offers, and requires fields")
      raw
  case member "schema_version" fields of
    Int v | v == schemaVersion -> Right ()
    _ -> Left (valueError "capability descriptor schema_version must be integer 1")
  (offered, reqs) <- case (member "offers" fields, member "requires" fields) of
    (Array o, Array r) -> Right (o, r)
    _ -> Left (typeError "capability descriptor offers and requires must be JSON arrays")
  i <- identityFromData (member "identity" fields)
  offerSet <- capabilitiesJson "descriptor offers" offered
  requirements <- traverse requirementFromData reqs
  build i offerSet requirements
