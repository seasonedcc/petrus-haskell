-- | Provider-, harness-, and Net-owned Agent Program descriptors
-- (@petrus.agenticus.program.descriptor@).
module Petrus.Agenticus.Program.Descriptor
  ( -- * Ownership
    ProgramOwnership (..)
  , ownershipText
  , parseOwnership
  , allOwnerships
    -- * Continuation requirements
  , ContinuationRequirement
  , mkContinuationRequirement
  , continuationRequirement
  , continuationRequirementToData
  , continuationRequirementFromData
    -- * Descriptors
  , AgentProgramDescriptor
  , mkAgentProgramDescriptor
  , agentProgramDescriptor
  , simpleProgram
  , programToData
  , programFromData
  ) where

import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Records (HasField (..))
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Shape
import Petrus.Agenticus.Internal.Validate
import Petrus.Json (Json (..))

-- | The component that owns progression of an Agent Program.
data ProgramOwnership
  = ProviderOwned
  | HarnessOwned
  | NetOwned
  deriving stock (Eq, Show, Enum, Bounded)

instance StrEnum ProgramOwnership where
  enumText = \case
    ProviderOwned -> "provider-owned"
    HarnessOwned -> "harness-owned"
    NetOwned -> "net-owned"

ownershipText :: ProgramOwnership -> Text
ownershipText = enumText

parseOwnership :: Text -> Maybe ProgramOwnership
parseOwnership = parseStrEnum

-- | In declaration order (@tuple(ProgramOwnership)@).
allOwnerships :: [ProgramOwnership]
allOwnerships = [minBound .. maxBound]

-- | One exact Continuation identity and the program that produced it.
-- Ordered like the @order=True@ dataclass: by identity, then program.
data ContinuationRequirement = ContinuationRequirement
  { _identity :: DescriptorIdentity
  , _program :: DescriptorIdentity
  }
  deriving stock (Eq, Ord, Show)

instance HasField "identity" ContinuationRequirement DescriptorIdentity where
  getField r = r._identity

instance HasField "program" ContinuationRequirement DescriptorIdentity where
  getField r = r._program

mkContinuationRequirement :: DescriptorIdentity -> DescriptorIdentity -> Either AgenticusError ContinuationRequirement
mkContinuationRequirement i p =
  ContinuationRequirement
    <$> identityOfKind KindContinuation "continuation requirement identity" i
    <*> identityOfKind KindProgram "continuation requirement program" p

-- | 'mkContinuationRequirement' for literals known to be valid.
continuationRequirement :: DescriptorIdentity -> DescriptorIdentity -> ContinuationRequirement
continuationRequirement i p = either (error . T.unpack . errorMessage) id (mkContinuationRequirement i p)

continuationRequirementToData :: ContinuationRequirement -> Json
continuationRequirementToData r =
  Object [("identity", identityToData r.identity), ("program", identityToData r.program)]

continuationRequirementFromData :: Json -> Either AgenticusError ContinuationRequirement
continuationRequirementFromData raw = do
  fields <-
    exactObject
      ["identity", "program"]
      (valueError "continuation requirement requires exact identity and program fields")
      raw
  i <- identityFromData (member "identity" fields)
  p <- identityFromData (member "program" fields)
  mkContinuationRequirement i p

-- | Stable ownership and Continuation contract for one Agent Program.
-- @acceptedContinuations@ is unique and sorted.
data AgentProgramDescriptor = AgentProgramDescriptor
  { _identity :: DescriptorIdentity
  , _ownership :: ProgramOwnership
  , _acceptsFreshStart :: Bool
  , _acceptedContinuations :: [ContinuationRequirement]
  , _producedContinuation :: Maybe DescriptorIdentity
  , _ownsSteering :: Bool
  , _ownsEvaluation :: Bool
  }
  deriving stock (Eq, Show)

instance HasField "identity" AgentProgramDescriptor DescriptorIdentity where
  getField r = r._identity

instance HasField "ownership" AgentProgramDescriptor ProgramOwnership where
  getField r = r._ownership

instance HasField "acceptsFreshStart" AgentProgramDescriptor Bool where
  getField r = r._acceptsFreshStart

instance HasField "acceptedContinuations" AgentProgramDescriptor [ContinuationRequirement] where
  getField r = r._acceptedContinuations

instance HasField "producedContinuation" AgentProgramDescriptor (Maybe DescriptorIdentity) where
  getField r = r._producedContinuation

instance HasField "ownsSteering" AgentProgramDescriptor Bool where
  getField r = r._ownsSteering

instance HasField "ownsEvaluation" AgentProgramDescriptor Bool where
  getField r = r._ownsEvaluation

-- | @AgentProgramDescriptor(identity, ownership, accepts_fresh_start,
-- accepted_continuations, produced_continuation, owns_steering,
-- owns_evaluation)@.
mkAgentProgramDescriptor
  :: DescriptorIdentity
  -> ProgramOwnership
  -> Bool
  -> [ContinuationRequirement]
  -> Maybe DescriptorIdentity
  -> Bool
  -> Bool
  -> Either AgenticusError AgentProgramDescriptor
mkAgentProgramDescriptor i o fresh accepted produced steering evaluation = do
  _ <- identityOfKind KindProgram "Agent Program identity" i
  require (not (hasDuplicates accepted)) (valueError "accepted_continuations must not contain duplicates")
  _ <- traverse (identityOfKind KindContinuation "produced_continuation") produced
  pure
    AgentProgramDescriptor
      { _identity = i
      , _ownership = o
      , _acceptsFreshStart = fresh
      , _acceptedContinuations = sort accepted
      , _producedContinuation = produced
      , _ownsSteering = steering
      , _ownsEvaluation = evaluation
      }

-- | 'mkAgentProgramDescriptor' for literals known to be valid.
agentProgramDescriptor
  :: DescriptorIdentity
  -> ProgramOwnership
  -> Bool
  -> [ContinuationRequirement]
  -> Maybe DescriptorIdentity
  -> Bool
  -> Bool
  -> AgentProgramDescriptor
agentProgramDescriptor i o fresh accepted produced steering evaluation =
  either (error . T.unpack . errorMessage) id $
    mkAgentProgramDescriptor i o fresh accepted produced steering evaluation

-- | @AgentProgramDescriptor(identity=..., ownership=...)@ with every default:
-- accepts a fresh start, accepts and produces no Continuation, owns neither
-- steering nor evaluation.
simpleProgram :: DescriptorIdentity -> ProgramOwnership -> Either AgenticusError AgentProgramDescriptor
simpleProgram i o = mkAgentProgramDescriptor i o True [] Nothing False False

programToData :: AgentProgramDescriptor -> Json
programToData d =
  Object
    [ ("schema_version", Int 1)
    , ("identity", identityToData d.identity)
    , ("ownership", strEnumData d.ownership)
    , ("accepts_fresh_start", Bool d.acceptsFreshStart)
    , ("accepted_continuations", Array (map continuationRequirementToData d.acceptedContinuations))
    , ("produced_continuation", maybe Null identityToData d.producedContinuation)
    , ("owns_steering", Bool d.ownsSteering)
    , ("owns_evaluation", Bool d.ownsEvaluation)
    ]

boolean :: Text -> Json -> Either AgenticusError Bool
boolean label = \case
  Bool b -> Right b
  _ -> Left (typeError (label <> " must be a boolean"))

programFromData :: Json -> Either AgenticusError AgentProgramDescriptor
programFromData raw = do
  fields <-
    exactObject
      [ "schema_version"
      , "identity"
      , "ownership"
      , "accepts_fresh_start"
      , "accepted_continuations"
      , "produced_continuation"
      , "owns_steering"
      , "owns_evaluation"
      ]
      (valueError "Agent Program descriptor requires its exact versioned fields")
      raw
  requireSchemaVersion "Agent Program descriptor" fields
  o <- maybe (Left (valueError "Agent Program ownership is not supported")) Right (strEnumJson (member "ownership" fields))
  accepted <- case member "accepted_continuations" fields of
    Array items -> Right items
    _ -> Left (typeError "accepted_continuations must be a JSON array")
  i <- identityFromData (member "identity" fields)
  fresh <- boolean "accepts_fresh_start" (member "accepts_fresh_start" fields)
  requirements <- traverse continuationRequirementFromData accepted
  produced <- case member "produced_continuation" fields of
    Null -> Right Nothing
    other -> Just <$> identityFromData other
  steering <- boolean "owns_steering" (member "owns_steering" fields)
  evaluation <- boolean "owns_evaluation" (member "owns_evaluation" fields)
  mkAgentProgramDescriptor i o fresh requirements produced steering evaluation
