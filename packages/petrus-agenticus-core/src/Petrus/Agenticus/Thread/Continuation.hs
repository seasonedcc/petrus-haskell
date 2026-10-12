-- | Opaque Continuation custody and explicit Agent Program compatibility
-- (@petrus.agenticus.thread.continuation@).
module Petrus.Agenticus.Thread.Continuation
  ( -- * States
    ContinuationState (..)
  , continuationStateText
  , parseContinuationState
    -- * Descriptors
  , ContinuationDescriptor
  , mkContinuationDescriptor
  , continuationDescriptor
  , continuationDescriptorToData
  , continuationDescriptorFromData
    -- * Continuations
  , Continuation
  , mkContinuation
  , newContinuation
  , claimContinuation
  , retireContinuation
  , sameRevision
  , continuationToData
  , continuationFromData
    -- * Codecs
  , ContinuationCodec (..)
    -- * Compatibility
  , IncompatibleContinuationError (..)
  , incompatibleContinuationError
  , checkContinuationCompatibility
  , requireContinuationCompatible
  ) where

import Control.Exception (Exception)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Records (HasField (..))
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Catalog.Result
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Shape
import Petrus.Agenticus.Internal.Validate
import Petrus.Agenticus.Program.Descriptor
import Petrus.Agenticus.Thread.Identity
import Petrus.Json (Json (..))
import Prelude hiding (id)
import Prelude qualified

-- | Custody state of one immutable Continuation revision.
data ContinuationState
  = ContinuationAvailable
  | ContinuationInUse
  | ContinuationRetired
  deriving stock (Eq, Show, Enum, Bounded)

instance StrEnum ContinuationState where
  enumText = \case
    ContinuationAvailable -> "available"
    ContinuationInUse -> "in-use"
    ContinuationRetired -> "retired"

continuationStateText :: ContinuationState -> Text
continuationStateText = enumText

parseContinuationState :: Text -> Maybe ContinuationState
parseContinuationState = parseStrEnum

-- | The exact provider/program-specific contract behind opaque state.
data ContinuationDescriptor = ContinuationDescriptor
  { _identity :: DescriptorIdentity
  , _program :: DescriptorIdentity
  }
  deriving stock (Eq, Ord, Show)

instance HasField "identity" ContinuationDescriptor DescriptorIdentity where
  getField r = r._identity

instance HasField "program" ContinuationDescriptor DescriptorIdentity where
  getField r = r._program

mkContinuationDescriptor :: DescriptorIdentity -> DescriptorIdentity -> Either AgenticusError ContinuationDescriptor
mkContinuationDescriptor i p =
  ContinuationDescriptor
    <$> identityOfKind KindContinuation "Continuation descriptor identity" i
    <*> identityOfKind KindProgram "Continuation descriptor program" p

-- | 'mkContinuationDescriptor' for literals known to be valid.
continuationDescriptor :: DescriptorIdentity -> DescriptorIdentity -> ContinuationDescriptor
continuationDescriptor i p = either (error . T.unpack . errorMessage) Prelude.id (mkContinuationDescriptor i p)

continuationDescriptorToData :: ContinuationDescriptor -> Json
continuationDescriptorToData d =
  Object
    [ ("schema_version", Int 1)
    , ("identity", identityToData d.identity)
    , ("program", identityToData d.program)
    ]

continuationDescriptorFromData :: Json -> Either AgenticusError ContinuationDescriptor
continuationDescriptorFromData raw = do
  fields <-
    exactObject
      ["schema_version", "identity", "program"]
      (valueError "Continuation descriptor requires exact schema_version, identity, and program fields")
      raw
  requireSchemaVersion "Continuation descriptor" fields
  i <- identityFromData (member "identity" fields)
  p <- identityFromData (member "program" fields)
  mkContinuationDescriptor i p

-- | A lifecycle envelope around an opaque provider/program custody
-- reference.  'Show' never renders the reference (upstream's
-- @field(repr=False)@).
data Continuation = Continuation
  { _id :: ContinuationId
  , _thread :: ThreadId
  , _descriptor :: ContinuationDescriptor
  , _stateReference :: Text
  , _state :: ContinuationState
  }
  deriving stock (Eq)

instance HasField "id" Continuation ContinuationId where
  getField r = r._id

instance HasField "thread" Continuation ThreadId where
  getField r = r._thread

instance HasField "descriptor" Continuation ContinuationDescriptor where
  getField r = r._descriptor

instance HasField "stateReference" Continuation Text where
  getField r = r._stateReference

instance HasField "state" Continuation ContinuationState where
  getField r = r._state

instance Show Continuation where
  showsPrec d c =
    showParen (d > 10) $
      showString "Continuation {id = "
        . shows c.id
        . showString ", thread = "
        . shows c.thread
        . showString ", descriptor = "
        . shows c.descriptor
        . showString ", state = "
        . shows c.state
        . showString "}"

referenceMessage :: AgenticusError
referenceMessage =
  valueError "Continuation state_reference must be a non-empty, trimmed string of at most 256 UTF-8 bytes"

mkContinuation
  :: ContinuationId
  -> ThreadId
  -> ContinuationDescriptor
  -> Text
  -> ContinuationState
  -> Either AgenticusError Continuation
mkContinuation i t d ref s = (\checked -> Continuation i t d checked s) <$> checkedText maxTextBytes referenceMessage ref

-- | @Continuation(id, thread, descriptor, state_reference)@: an available
-- revision.
newContinuation :: ContinuationId -> ThreadId -> ContinuationDescriptor -> Text -> Either AgenticusError Continuation
newContinuation i t d ref = mkContinuation i t d ref ContinuationAvailable

claimContinuation :: Continuation -> Either AgenticusError Continuation
claimContinuation c
  | c.state == ContinuationAvailable = Right c {_state = ContinuationInUse}
  | otherwise =
      Left
        ( agenticusError
            ContinuationTransitionError
            ("cannot claim a Continuation in " <> enumText c.state <> " state")
        )

retireContinuation :: Continuation -> Continuation
retireContinuation c = c {_state = ContinuationRetired}

-- | Upstream @_same_continuation_revision@: equal up to custody state.
sameRevision :: Maybe Continuation -> Maybe Continuation -> Bool
sameRevision (Just a) (Just b) = a {_state = ContinuationAvailable} == b {_state = ContinuationAvailable}
sameRevision Nothing Nothing = True
sameRevision _ _ = False

continuationToData :: Continuation -> Json
continuationToData c =
  Object
    [ ("schema_version", Int 1)
    , ("id", lifecycleIdToData c.id)
    , ("thread", lifecycleIdToData c.thread)
    , ("descriptor", continuationDescriptorToData c.descriptor)
    , ("state_reference", String c.stateReference)
    , ("state", strEnumData c.state)
    ]

continuationFromData :: Json -> Either AgenticusError Continuation
continuationFromData raw = do
  fields <-
    exactObject
      ["schema_version", "id", "thread", "descriptor", "state_reference", "state"]
      (valueError "Continuation requires its exact versioned fields")
      raw
  requireSchemaVersion "Continuation" fields
  s <- maybe (Left (valueError "Continuation state is not supported")) Right (strEnumJson (member "state" fields))
  i <- lifecycleIdFromData (member "id" fields)
  t <- lifecycleIdFromData (member "thread" fields)
  d <- continuationDescriptorFromData (member "descriptor" fields)
  ref <- case member "state_reference" fields of
    String r -> Right r
    _ -> Left referenceMessage
  mkContinuation i t d ref s

-- | Resolve one profile-specific payload without exposing it to Thread
-- values.
data ContinuationCodec payload = ContinuationCodec
  { descriptor :: ContinuationDescriptor
  , load :: Continuation -> IO payload
  }

-- | Upstream @IncompatibleContinuation@: a typed refusal raised before a
-- Continuation is resolved or executed, carrying the exact
-- 'CompatibilityResult'.  'incompatibleContinuationError' gives the
-- 'AgenticusError' it surfaces as (class @IncompatibleContinuation@, the
-- upstream message).
newtype IncompatibleContinuationError = IncompatibleContinuationError
  { result :: CompatibilityResult
  }
  deriving stock (Eq, Show)

instance Exception IncompatibleContinuationError

incompatibleContinuationError :: IncompatibleContinuationError -> AgenticusError
incompatibleContinuationError e =
  agenticusError
    IncompatibleContinuation
    ("Continuation is incompatible with Agent Program: " <> T.intercalate ", " (map (.code) e.result.issues))

-- | Check only explicit descriptor-table entries; never translate state.
checkContinuationCompatibility :: AgentProgramDescriptor -> Maybe ContinuationDescriptor -> CompatibilityResult
checkContinuationCompatibility p = \case
  Nothing
    | p.acceptsFreshStart -> outcome []
    | otherwise -> outcome [compatibilityIssue "continuation-required" p.identity.name]
  Just c ->
    let matching = [r | r <- p.acceptedContinuations, r.identity == c.identity]
     in if null matching
          then outcome [compatibilityIssue "continuation-not-accepted" c.identity.name]
          else
            if any (\r -> r.program == c.program) matching
              then outcome []
              else outcome [compatibilityIssue "continuation-program-mismatch" c.program.name]
  where
    outcome issues = either (error . T.unpack . errorMessage) Prelude.id (mkCompatibilityResult (Just p.identity) issues)

requireContinuationCompatible
  :: AgentProgramDescriptor -> Maybe ContinuationDescriptor -> Either IncompatibleContinuationError ()
requireContinuationCompatible p c =
  let r = checkContinuationCompatibility p c
   in if compatible r then Right () else Left (IncompatibleContinuationError r)
