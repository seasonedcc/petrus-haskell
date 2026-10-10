{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The strict value model of @petrus.testing.dst@ (API v4) and its
-- @petrus-dst-world@ artifacts, versions 1 to 4.
--
-- Every type mirrors one pydantic model of the reference module
-- (@src/petrus/testing/dst.py@ at the pin). 'ToJson' renders the model's
-- @model_dump(mode="json")@, with members in the reference's field order;
-- encoding with sorted keys then gives the reference's canonical bytes.
-- 'Eq' instances use CPython value equality for embedded JSON
-- (@1 == 1.0 == True@), which is what pydantic model equality does, so replay
-- comparisons agree with the reference.
module Petrus.Testing.Dst.Types
  ( -- * Identities and limits
    legacyApiCompatibility
  , previousApiCompatibility
  , seededApiCompatibility
  , apiCompatibility
  , artifactFormat
  , resultFormat
  , resultVersion
  , maxArtifactBytes
  , maxPortableInteger
  , isName
  , isDigest
  , isEntrypoint

    -- * Enumerations
  , Disposition (..)
  , dispositionText
  , dispositionFromText
  , AuthoredDisposition (..)
  , authoredDisposition
  , authoredDispositionText
  , authoredFromDisposition
  , ActionDisposition (..)
  , actionDispositionText
  , FaultDisposition (..)
  , faultDispositionText
  , CommandSource (..)
  , commandSourceText
  , JournalKind (..)
  , journalKindText

    -- * Components
  , IdentityKind (..)
  , Identity (..)
  , ProfileIdentity
  , CheckerIdentity
  , IdentityKey
  , identityKey
  , identityStr

    -- * Commands, faults, budgets
  , Command (..)
  , Fault (..)
  , Budget (..)
  , BudgetV4 (..)
  , SomeBudget (..)
  , budgetLimits
  , budgetArtifactBytes
  , ResourceUsage (..)
  , ScheduledCommand (..)
  , ApplyResult (..)
  , GenerationStart (..)
  , ObservationRequest (..)
  , Observation (..)
  , CheckResult (..)
  , ChoiceProvenance (..)

    -- * Attempts and operations
  , OperationAttempt (..)
  , SubmitAttempt (..)
  , FaultAttempt (..)
  , ObserveAttempt (..)
  , CrashAttempt (..)
  , FairAttempt (..)
  , FinishAttempt (..)
  , ProcessAttempt (..)
  , FailureDetail (..)
  , BudgetFailure (..)
  , InvariantFailure (..)
  , failureKind
  , AcceptedOperation (..)
  , ExecuteOperation (..)
  , FaultOperation (..)
  , ObserveOperation (..)
  , CrashOperation (..)
  , RestartOperation (..)
  , FairOperation (..)
  , FinishOperation (..)
  , FailureOperation (..)
  , ExpandedOperation (..)
  , operationPosition
  , operationKind
  , JournalEntry (..)

    -- * Artifacts and replay results
  , ScenarioExpectedV1 (..)
  , ScenarioExpected (..)
  , ScenarioArtifactV1 (..)
  , ScenarioArtifactV2 (..)
  , ScenarioArtifactV3 (..)
  , ScenarioArtifactV4 (..)
  , AnyArtifact (..)
  , artifactVersion
  , artifactScenarioId
  , artifactProfile
  , artifactCheckers
  , artifactBudget
  , artifactOperations
  , artifactExpectedDisposition
  , artifactExpectedFailure
  , artifactExpectedChecks
  , artifactJournalDigest
  , ReplayResultV1 (..)
  , ReplayResult (..)
  , AnyReplayResult (..)

    -- * Rendering
  , ToJson (..)
  , ToPy (..)
  , obj
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Testing.Dst.PyRepr

-- ---------------------------------------------------------------------------
-- Identities and limits

legacyApiCompatibility, previousApiCompatibility, seededApiCompatibility, apiCompatibility :: Text
legacyApiCompatibility = "petrus.testing.dst/v1"
previousApiCompatibility = "petrus.testing.dst/v2"
seededApiCompatibility = "petrus.testing.dst/v3"
apiCompatibility = "petrus.testing.dst/v4"

artifactFormat, resultFormat :: Text
artifactFormat = "petrus-dst-world"
resultFormat = "petrus-dst-world-replay-result"

resultVersion :: Integer
resultVersion = 2

-- | @MAX_ARTIFACT_BYTES@.
maxArtifactBytes :: Integer
maxArtifactBytes = 4194304

-- | @2^53 - 1@, the largest JSON-portable integer.
maxPortableInteger :: Integer
maxPortableInteger = 2 ^ (53 :: Int) - 1

-- | @^[A-Za-z][A-Za-z0-9_.:-]*$@.
isName :: Text -> Bool
isName t = case T.uncons t of
  Just (c, rest) -> isAsciiAlpha c && T.all nameChar rest
  Nothing -> False
  where
    nameChar c = isAsciiAlpha c || isDigit c || c `elem` ("_.:-" :: String)

-- | @^sha256:[0-9a-f]{64}$@.
isDigest :: Text -> Bool
isDigest t = case T.stripPrefix "sha256:" t of
  Just hex -> T.length hex == 64 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) hex
  Nothing -> False

-- | @^[A-Za-z_][A-Za-z0-9_.]*:[A-Za-z_][A-Za-z0-9_]*$@.
isEntrypoint :: Text -> Bool
isEntrypoint t = case T.breakOn ":" t of
  (modulePart, rest) | Just function <- T.stripPrefix ":" rest -> identifier "." modulePart && identifier "" function
  _ -> False
  where
    identifier extra s = case T.uncons s of
      Just (c, cs) -> (isAsciiAlpha c || c == '_') && T.all (\x -> isAsciiAlpha x || isDigit x || x == '_' || x `elem` (extra :: String)) cs
      Nothing -> False

isAsciiAlpha :: Char -> Bool
isAsciiAlpha c = isAsciiLower c || isAsciiUpper c

-- ---------------------------------------------------------------------------
-- Enumerations

-- | Explicit ending classifications for a bounded world run.
data Disposition
  = DConverged
  | DQuiescent
  | DExternalWait
  | DBudgetExhausted
  | DInvariantFailure
  | DQuarantined
  deriving stock (Eq, Ord, Show, Enum, Bounded)

dispositionText :: Disposition -> Text
dispositionText = \case
  DConverged -> "converged"
  DQuiescent -> "quiescent"
  DExternalWait -> "external_wait"
  DBudgetExhausted -> "budget_exhausted"
  DInvariantFailure -> "invariant_failure"
  DQuarantined -> "quarantined"

dispositionFromText :: Text -> Maybe Disposition
dispositionFromText t = lookup t [(dispositionText d, d) | d <- [minBound .. maxBound]]

-- | The four endings an author may choose; the other two are reserved for
-- interpreter failures. The reference refuses the reserved ones at run time
-- with a @ValueError@; here they cannot be expressed.
data AuthoredDisposition = Converged | Quiescent | ExternalWait | Quarantined
  deriving stock (Eq, Ord, Show, Enum, Bounded)

authoredDisposition :: AuthoredDisposition -> Disposition
authoredDisposition = \case
  Converged -> DConverged
  Quiescent -> DQuiescent
  ExternalWait -> DExternalWait
  Quarantined -> DQuarantined

authoredDispositionText :: AuthoredDisposition -> Text
authoredDispositionText = dispositionText . authoredDisposition

authoredFromDisposition :: Disposition -> Maybe AuthoredDisposition
authoredFromDisposition = \case
  DConverged -> Just Converged
  DQuiescent -> Just Quiescent
  DExternalWait -> Just ExternalWait
  DQuarantined -> Just Quarantined
  _ -> Nothing

-- | Outcome of one accepted interpreter command.
data ActionDisposition = Applied | Idempotent | RefusedExpected | ActionQuarantined
  deriving stock (Eq, Ord, Show, Enum, Bounded)

actionDispositionText :: ActionDisposition -> Text
actionDispositionText = \case
  Applied -> "applied"
  Idempotent -> "idempotent"
  RefusedExpected -> "refused_expected"
  ActionQuarantined -> "quarantined"

-- | Generic fault behavior named by a profile-owned cut.
data FaultDisposition = Refuse | Raise | Delay | DropFault | Duplicate
  deriving stock (Eq, Ord, Show, Enum, Bounded)

faultDispositionText :: FaultDisposition -> Text
faultDispositionText = \case
  Refuse -> "refuse"
  Raise -> "raise"
  Delay -> "delay"
  DropFault -> "drop"
  Duplicate -> "duplicate"

data CommandSource = Authored | ProfileSource
  deriving stock (Eq, Ord, Show, Enum, Bounded)

commandSourceText :: CommandSource -> Text
commandSourceText = \case
  Authored -> "authored"
  ProfileSource -> "profile"

data JournalKind
  = JCreated
  | JLoaded
  | JCommand
  | JFault
  | JObservation
  | JCheck
  | JCrash
  | JFair
  | JFinish
  | JBudget
  | JFailure
  | JResource
  deriving stock (Eq, Ord, Show, Enum, Bounded)

journalKindText :: JournalKind -> Text
journalKindText = \case
  JCreated -> "created"
  JLoaded -> "loaded"
  JCommand -> "command"
  JFault -> "fault"
  JObservation -> "observation"
  JCheck -> "check"
  JCrash -> "crash"
  JFair -> "fair"
  JFinish -> "finish"
  JBudget -> "budget"
  JFailure -> "failure"
  JResource -> "resource"

-- ---------------------------------------------------------------------------
-- Identities

data IdentityKind = ProfileKind | CheckerKind

-- | Exact identity and implementation pin for one replay component
-- (@ComponentIdentity@). The kind index keeps profile and checker
-- identities apart, as the reference's two subclasses do.
data Identity (k :: IdentityKind) = Identity
  { name :: Text
  , version :: Integer
  , digest :: Text
  }
  deriving stock (Eq, Ord, Show)

type ProfileIdentity = Identity 'ProfileKind

type CheckerIdentity = Identity 'CheckerKind

-- | The registry key @(name, version, digest)@.
type IdentityKey = (Text, Integer, Text)

identityKey :: Identity k -> IdentityKey
identityKey i = (i.name, i.version, i.digest)

-- | Pydantic's @str()@ of an identity: @name='x' version=1 digest='sha256:…'@.
identityStr :: Identity k -> Text
identityStr i =
  "name=" <> pyStrRepr i.name <> " version=" <> T.pack (show i.version) <> " digest=" <> pyStrRepr i.digest

-- ---------------------------------------------------------------------------
-- Commands, faults, budgets

-- | One normalized application command for an exact profile.
data Command = Command
  { profile :: ProfileIdentity
  , name :: Text
  , payload :: Json
  }
  deriving stock (Eq, Show)

-- | One occurrence-addressed fault at a profile-owned semantic cut.
data Fault = Fault
  { profile :: ProfileIdentity
  , name :: Text
  , target :: Text
  , occurrence :: Integer
  , disposition :: FaultDisposition
  , payload :: Json
  }
  deriving stock (Eq, Show)

-- | Generic World limits shared by the version 1 through 3 contracts.
data Budget = Budget
  { actions :: Integer
  , queuedCommands :: Integer
  , timerAdvances :: Integer
  , logicalInstant :: Integer
  , reloads :: Integer
  , predicatePolls :: Integer
  , artifactBytes :: Integer
  }
  deriving stock (Eq, Show)

-- | Version-4 limits including profile-defined retained and pending
-- resources. On the wire the 'Budget' fields and @profile_resources@ are
-- siblings.
data BudgetV4 = BudgetV4
  { limits :: Budget
  , profileResources :: Map Text Integer
  }
  deriving stock (Eq, Show)

-- | @Budget | BudgetV4@. A World with a 'BudgetV4' authors version-4
-- artifacts and samples profile resources; otherwise it authors version 3.
data SomeBudget = SomeBudget Budget | SomeBudgetV4 BudgetV4
  deriving stock (Eq, Show)

budgetLimits :: SomeBudget -> Budget
budgetLimits = \case
  SomeBudget b -> b
  SomeBudgetV4 b -> b.limits

budgetArtifactBytes :: SomeBudget -> Integer
budgetArtifactBytes b = (budgetLimits b).artifactBytes

-- | One detached, side-effect-free sample of profile-owned resource gauges.
newtype ResourceUsage = ResourceUsage {values :: Map Text Integer}
  deriving stock (Eq, Show)

-- | Detached future work proposed to, but never scheduled by, a profile.
data ScheduledCommand = ScheduledCommand
  { instant :: Integer
  , command :: Command
  }
  deriving stock (Eq, Show)

-- | Detached result of one profile command.
data ApplyResult = ApplyResult
  { disposition :: ActionDisposition
  , value :: Json
  , scheduled :: [ScheduledCommand]
  }
  deriving stock (Eq, Show)

-- | One opaque generation plus work disclosed by create/load.
data GenerationStart g = GenerationStart
  { generation :: g
  , scheduled :: [ScheduledCommand]
  }
  deriving stock (Functor)

-- | A closed profile observation name and strict parameters.
data ObservationRequest = ObservationRequest
  { name :: Text
  , payload :: Json
  }
  deriving stock (Eq, Show)

-- | One detached observation at an exact World boundary.
data Observation = Observation
  { name :: Text
  , value :: Json
  , instant :: Integer
  , generation :: Integer
  , sequence :: Integer
  }
  deriving stock (Eq, Show)

-- | Detached verdict returned by one checker invocation.
data CheckResult = CheckResult
  { passed :: Bool
  , detail :: Json
  }
  deriving stock (Eq, Show)

-- | Seed metadata for discovery; expanded operations remain authoritative.
-- The algorithm is always @sha256-counter-v1@.
data ChoiceProvenance = ChoiceProvenance
  { seed :: Integer
  , draws :: Map Text Integer
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Attempts

data SubmitAttempt = SubmitAttempt {generation :: Integer, command :: Command}
  deriving stock (Eq, Show)

data FaultAttempt = FaultAttempt {generation :: Integer, fault :: Fault}
  deriving stock (Eq, Show)

data ObserveAttempt = ObserveAttempt {generation :: Integer, request :: ObservationRequest, poll :: Bool}
  deriving stock (Eq, Show)

data CrashAttempt = CrashAttempt {generation :: Integer, cut :: Text}
  deriving stock (Eq, Show)

newtype FairAttempt = FairAttempt {generation :: Integer}
  deriving stock (Eq, Show)

data FinishAttempt = FinishAttempt {generation :: Integer, disposition :: AuthoredDisposition}
  deriving stock (Eq, Show)

-- | The normalized World attempt a 'FailureOperation' retains.
data OperationAttempt
  = ASubmit SubmitAttempt
  | AStep
  | AFault FaultAttempt
  | AObserve ObserveAttempt
  | ACrash CrashAttempt
  | ARestart
  | AFair FairAttempt
  | AFinish FinishAttempt
  deriving stock (Eq, Show)

-- | Every attempt the process runner acknowledges, including the
-- runner-only @construct@ and @close@.
data ProcessAttempt
  = WorldAttempt OperationAttempt
  | AConstruct
  | AClose Integer
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Failures and operations

data BudgetFailure = BudgetFailure {bound :: Text, limit :: Integer, error :: Text}
  deriving stock (Eq, Show)

newtype InvariantFailure = InvariantFailure {error :: Text}
  deriving stock (Eq, Show)

data FailureDetail = FBudget BudgetFailure | FInvariant InvariantFailure
  deriving stock (Eq, Show)

-- | The ending disposition a failure detail implies.
failureKind :: FailureDetail -> Disposition
failureKind = \case
  FBudget _ -> DBudgetExhausted
  FInvariant _ -> DInvariantFailure

data ExecuteOperation = ExecuteOperation
  { position :: Integer
  , source :: CommandSource
  , queueOrder :: Integer
  , instant :: Integer
  , generation :: Integer
  , command :: Command
  , result :: ApplyResult
  }
  deriving stock (Eq, Show)

data FaultOperation = FaultOperation
  { position :: Integer
  , instant :: Integer
  , generation :: Integer
  , fault :: Fault
  }
  deriving stock (Eq, Show)

data ObserveOperation = ObserveOperation
  { position :: Integer
  , poll :: Bool
  , observation :: Observation
  , request :: ObservationRequest
  }
  deriving stock (Eq, Show)

data CrashOperation = CrashOperation
  { position :: Integer
  , instant :: Integer
  , generation :: Integer
  , cut :: Text
  , discardedCommands :: Integer
  }
  deriving stock (Eq, Show)

data RestartOperation = RestartOperation
  { position :: Integer
  , instant :: Integer
  , generation :: Integer
  }
  deriving stock (Eq, Show)

data FairOperation = FairOperation
  { position :: Integer
  , instant :: Integer
  , generation :: Integer
  }
  deriving stock (Eq, Show)

data FinishOperation = FinishOperation
  { position :: Integer
  , instant :: Integer
  , generation :: Integer
  , disposition :: AuthoredDisposition
  }
  deriving stock (Eq, Show)

data FailureOperation = FailureOperation
  { position :: Integer
  , instant :: Integer
  , generation :: Maybe Integer
  , acceptedOperations :: Integer
  , attempt :: OperationAttempt
  , failure :: FailureDetail
  }
  deriving stock (Eq, Show)

-- | The version-1 operation union (@ExpandedOperationV1@): every operation
-- an attempt can accept.
data AcceptedOperation
  = OpExecute ExecuteOperation
  | OpFault FaultOperation
  | OpObserve ObserveOperation
  | OpCrash CrashOperation
  | OpRestart RestartOperation
  | OpFair FairOperation
  | OpFinish FinishOperation
  deriving stock (Eq, Show)

-- | The version 2 to 4 operation union: accepted operations plus the
-- terminal failure operation. Version-1 artifacts hold 'AcceptedOperation'
-- values only, so a failure operation in a v1 artifact is unrepresentable.
data ExpandedOperation
  = Accepted AcceptedOperation
  | Failed FailureOperation
  deriving stock (Eq, Show)

operationPosition :: ExpandedOperation -> Integer
operationPosition = \case
  Accepted (OpExecute o) -> o.position
  Accepted (OpFault o) -> o.position
  Accepted (OpObserve o) -> o.position
  Accepted (OpCrash o) -> o.position
  Accepted (OpRestart o) -> o.position
  Accepted (OpFair o) -> o.position
  Accepted (OpFinish o) -> o.position
  Failed o -> o.position

-- | The operation's @kind@ discriminator.
operationKind :: ExpandedOperation -> Text
operationKind = \case
  Accepted (OpExecute _) -> "execute"
  Accepted (OpFault _) -> "activate_fault"
  Accepted (OpObserve _) -> "observe"
  Accepted (OpCrash _) -> "crash"
  Accepted (OpRestart _) -> "restart"
  Accepted (OpFair _) -> "begin_fair"
  Accepted (OpFinish _) -> "finish"
  Failed _ -> "failure"

-- | One deterministic diagnostic fact emitted by the interpreter.
data JournalEntry = JournalEntry
  { position :: Integer
  , instant :: Integer
  , generation :: Maybe Integer
  , kind :: JournalKind
  , name :: Text
  , value :: Json
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Artifacts

data ScenarioExpectedV1 = ScenarioExpectedV1
  { disposition :: AuthoredDisposition
  , checks :: [JournalEntry]
  , journalDigest :: Text
  }
  deriving stock (Eq, Show)

data ScenarioExpected = ScenarioExpected
  { disposition :: Disposition
  , failure :: Maybe FailureDetail
  , checks :: [JournalEntry]
  , journalDigest :: Text
  }
  deriving stock (Eq, Show)

-- | Legacy strict expanded operations and exact expected authored outcome.
data ScenarioArtifactV1 = ScenarioArtifactV1
  { scenarioId :: Text
  , profile :: ProfileIdentity
  , checkers :: [CheckerIdentity]
  , budget :: Budget
  , operations :: [AcceptedOperation]
  , expected :: ScenarioExpectedV1
  }
  deriving stock (Eq, Show)

-- | Legacy version-2 artifact with exact terminal failure retention.
data ScenarioArtifactV2 = ScenarioArtifactV2
  { scenarioId :: Text
  , profile :: ProfileIdentity
  , checkers :: [CheckerIdentity]
  , budget :: Budget
  , operations :: [ExpandedOperation]
  , expected :: ScenarioExpected
  }
  deriving stock (Eq, Show)

-- | Version-3 artifact with seeded discovery provenance.
data ScenarioArtifactV3 = ScenarioArtifactV3
  { scenarioId :: Text
  , profile :: ProfileIdentity
  , checkers :: [CheckerIdentity]
  , budget :: Budget
  , operations :: [ExpandedOperation]
  , expected :: ScenarioExpected
  , origin :: Maybe ChoiceProvenance
  }
  deriving stock (Eq, Show)

-- | The current artifact (@ScenarioArtifact@) with deterministic
-- profile-resource accounting.
data ScenarioArtifactV4 = ScenarioArtifactV4
  { scenarioId :: Text
  , profile :: ProfileIdentity
  , checkers :: [CheckerIdentity]
  , budget :: BudgetV4
  , operations :: [ExpandedOperation]
  , expected :: ScenarioExpected
  , origin :: Maybe ChoiceProvenance
  }
  deriving stock (Eq, Show)

-- | @AnyScenarioArtifact@.
data AnyArtifact
  = ArtifactV1 ScenarioArtifactV1
  | ArtifactV2 ScenarioArtifactV2
  | ArtifactV3 ScenarioArtifactV3
  | ArtifactV4 ScenarioArtifactV4
  deriving stock (Eq, Show)

artifactVersion :: AnyArtifact -> Integer
artifactVersion = \case
  ArtifactV1 _ -> 1
  ArtifactV2 _ -> 2
  ArtifactV3 _ -> 3
  ArtifactV4 _ -> 4

artifactScenarioId :: AnyArtifact -> Text
artifactScenarioId = \case
  ArtifactV1 a -> a.scenarioId
  ArtifactV2 a -> a.scenarioId
  ArtifactV3 a -> a.scenarioId
  ArtifactV4 a -> a.scenarioId

artifactProfile :: AnyArtifact -> ProfileIdentity
artifactProfile = \case
  ArtifactV1 a -> a.profile
  ArtifactV2 a -> a.profile
  ArtifactV3 a -> a.profile
  ArtifactV4 a -> a.profile

artifactCheckers :: AnyArtifact -> [CheckerIdentity]
artifactCheckers = \case
  ArtifactV1 a -> a.checkers
  ArtifactV2 a -> a.checkers
  ArtifactV3 a -> a.checkers
  ArtifactV4 a -> a.checkers

artifactBudget :: AnyArtifact -> SomeBudget
artifactBudget = \case
  ArtifactV1 a -> SomeBudget a.budget
  ArtifactV2 a -> SomeBudget a.budget
  ArtifactV3 a -> SomeBudget a.budget
  ArtifactV4 a -> SomeBudgetV4 a.budget

artifactOperations :: AnyArtifact -> [ExpandedOperation]
artifactOperations = \case
  ArtifactV1 a -> map Accepted a.operations
  ArtifactV2 a -> a.operations
  ArtifactV3 a -> a.operations
  ArtifactV4 a -> a.operations

artifactExpectedDisposition :: AnyArtifact -> Disposition
artifactExpectedDisposition = \case
  ArtifactV1 a -> authoredDisposition a.expected.disposition
  ArtifactV2 a -> a.expected.disposition
  ArtifactV3 a -> a.expected.disposition
  ArtifactV4 a -> a.expected.disposition

artifactExpectedFailure :: AnyArtifact -> Maybe FailureDetail
artifactExpectedFailure = \case
  ArtifactV1 _ -> Nothing
  ArtifactV2 a -> a.expected.failure
  ArtifactV3 a -> a.expected.failure
  ArtifactV4 a -> a.expected.failure

artifactExpectedChecks :: AnyArtifact -> [JournalEntry]
artifactExpectedChecks = \case
  ArtifactV1 a -> a.expected.checks
  ArtifactV2 a -> a.expected.checks
  ArtifactV3 a -> a.expected.checks
  ArtifactV4 a -> a.expected.checks

artifactJournalDigest :: AnyArtifact -> Text
artifactJournalDigest = \case
  ArtifactV1 a -> a.expected.journalDigest
  ArtifactV2 a -> a.expected.journalDigest
  ArtifactV3 a -> a.expected.journalDigest
  ArtifactV4 a -> a.expected.journalDigest

-- | Replay result for a version-1 artifact.
data ReplayResultV1 = ReplayResultV1
  { scenarioId :: Text
  , disposition :: AuthoredDisposition
  , operations :: Integer
  , journalEntries :: Integer
  , journalDigest :: Text
  }
  deriving stock (Eq, Show)

-- | Replay result (version 2) for artifacts of versions 2 to 4.
data ReplayResult = ReplayResult
  { scenarioId :: Text
  , disposition :: Disposition
  , failure :: Maybe FailureDetail
  , operations :: Integer
  , journalEntries :: Integer
  , journalDigest :: Text
  }
  deriving stock (Eq, Show)

data AnyReplayResult = ReplayV1 ReplayResultV1 | ReplayV2 ReplayResult
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Rendering: model_dump(mode="json")

-- | A model's @model_dump(mode="json")@.
class ToJson a where
  toJson :: a -> Json

obj :: [(Text, Json)] -> Json
obj = Object

str :: Text -> Json
str = String

int :: Integer -> Json
int = Int

maybeJson :: (a -> Json) -> Maybe a -> Json
maybeJson = maybe Null

intMap :: Map Text Integer -> Json
intMap m = Object [(k, Int v) | (k, v) <- Map.toList m]

instance ToJson (Identity k) where
  toJson i = obj [("name", str i.name), ("version", int i.version), ("digest", str i.digest)]

instance ToJson Command where
  toJson c = obj [("profile", toJson c.profile), ("name", str c.name), ("payload", c.payload)]

instance ToJson Fault where
  toJson f =
    obj
      [ ("profile", toJson f.profile)
      , ("name", str f.name)
      , ("target", str f.target)
      , ("occurrence", int f.occurrence)
      , ("disposition", str (faultDispositionText f.disposition))
      , ("payload", f.payload)
      ]

budgetMembers :: Budget -> [(Text, Json)]
budgetMembers b =
  [ ("actions", int b.actions)
  , ("queued_commands", int b.queuedCommands)
  , ("timer_advances", int b.timerAdvances)
  , ("logical_instant", int b.logicalInstant)
  , ("reloads", int b.reloads)
  , ("predicate_polls", int b.predicatePolls)
  , ("artifact_bytes", int b.artifactBytes)
  ]

instance ToJson Budget where
  toJson = obj . budgetMembers

instance ToJson BudgetV4 where
  toJson b = obj (budgetMembers b.limits ++ [("profile_resources", intMap b.profileResources)])

instance ToJson SomeBudget where
  toJson = \case
    SomeBudget b -> toJson b
    SomeBudgetV4 b -> toJson b

instance ToJson ResourceUsage where
  toJson u = obj [("values", intMap u.values)]

instance ToJson ScheduledCommand where
  toJson s = obj [("instant", int s.instant), ("command", toJson s.command)]

instance ToJson ApplyResult where
  toJson r =
    obj
      [ ("disposition", str (actionDispositionText r.disposition))
      , ("value", r.value)
      , ("scheduled", Array (map toJson r.scheduled))
      ]

instance ToJson ObservationRequest where
  toJson r = obj [("name", str r.name), ("payload", r.payload)]

instance ToJson Observation where
  toJson o =
    obj
      [ ("name", str o.name)
      , ("value", o.value)
      , ("instant", int o.instant)
      , ("generation", int o.generation)
      , ("sequence", int o.sequence)
      ]

instance ToJson CheckResult where
  toJson r = obj [("passed", Bool r.passed), ("detail", r.detail)]

instance ToJson ChoiceProvenance where
  toJson p = obj [("algorithm", str "sha256-counter-v1"), ("seed", int p.seed), ("draws", intMap p.draws)]

instance ToJson OperationAttempt where
  toJson = \case
    ASubmit a -> obj [("kind", str "submit"), ("generation", int a.generation), ("command", toJson a.command)]
    AStep -> obj [("kind", str "step")]
    AFault a -> obj [("kind", str "activate_fault"), ("generation", int a.generation), ("fault", toJson a.fault)]
    AObserve a ->
      obj
        [ ("kind", str "observe")
        , ("generation", int a.generation)
        , ("request", toJson a.request)
        , ("poll", Bool a.poll)
        ]
    ACrash a -> obj [("kind", str "crash"), ("generation", int a.generation), ("cut", str a.cut)]
    ARestart -> obj [("kind", str "restart")]
    AFair a -> obj [("kind", str "begin_fair"), ("generation", int a.generation)]
    AFinish a ->
      obj
        [ ("kind", str "finish")
        , ("generation", int a.generation)
        , ("disposition", str (authoredDispositionText a.disposition))
        ]

instance ToJson ProcessAttempt where
  toJson = \case
    WorldAttempt a -> toJson a
    AConstruct -> obj [("kind", str "construct")]
    AClose g -> obj [("kind", str "close"), ("generation", int g)]

instance ToJson FailureDetail where
  toJson = \case
    FBudget f ->
      obj [("kind", str "budget_exhausted"), ("bound", str f.bound), ("limit", int f.limit), ("error", str f.error)]
    FInvariant f -> obj [("kind", str "invariant_failure"), ("error", str f.error)]

instance ToJson AcceptedOperation where
  toJson = \case
    OpExecute o ->
      obj
        [ ("kind", str "execute")
        , ("position", int o.position)
        , ("source", str (commandSourceText o.source))
        , ("queue_order", int o.queueOrder)
        , ("instant", int o.instant)
        , ("generation", int o.generation)
        , ("command", toJson o.command)
        , ("result", toJson o.result)
        ]
    OpFault o ->
      obj
        [ ("kind", str "activate_fault")
        , ("position", int o.position)
        , ("instant", int o.instant)
        , ("generation", int o.generation)
        , ("fault", toJson o.fault)
        ]
    OpObserve o ->
      obj
        [ ("kind", str "observe")
        , ("position", int o.position)
        , ("poll", Bool o.poll)
        , ("observation", toJson o.observation)
        , ("request", toJson o.request)
        ]
    OpCrash o ->
      obj
        [ ("kind", str "crash")
        , ("position", int o.position)
        , ("instant", int o.instant)
        , ("generation", int o.generation)
        , ("cut", str o.cut)
        , ("discarded_commands", int o.discardedCommands)
        ]
    OpRestart o ->
      obj
        [ ("kind", str "restart")
        , ("position", int o.position)
        , ("instant", int o.instant)
        , ("generation", int o.generation)
        ]
    OpFair o ->
      obj
        [ ("kind", str "begin_fair")
        , ("position", int o.position)
        , ("instant", int o.instant)
        , ("generation", int o.generation)
        ]
    OpFinish o ->
      obj
        [ ("kind", str "finish")
        , ("position", int o.position)
        , ("instant", int o.instant)
        , ("generation", int o.generation)
        , ("disposition", str (authoredDispositionText o.disposition))
        ]

instance ToJson FailureOperation where
  toJson o =
    obj
      [ ("kind", str "failure")
      , ("position", int o.position)
      , ("instant", int o.instant)
      , ("generation", maybeJson int o.generation)
      , ("accepted_operations", int o.acceptedOperations)
      , ("attempt", toJson o.attempt)
      , ("failure", toJson o.failure)
      ]

instance ToJson ExpandedOperation where
  toJson = \case
    Accepted o -> toJson o
    Failed o -> toJson o

instance ToJson JournalEntry where
  toJson e =
    obj
      [ ("position", int e.position)
      , ("instant", int e.instant)
      , ("generation", maybeJson int e.generation)
      , ("kind", str (journalKindText e.kind))
      , ("name", str e.name)
      , ("value", e.value)
      ]

instance ToJson ScenarioExpectedV1 where
  toJson e =
    obj
      [ ("disposition", str (authoredDispositionText e.disposition))
      , ("checks", Array (map toJson e.checks))
      , ("journal_digest", str e.journalDigest)
      ]

instance ToJson ScenarioExpected where
  toJson e =
    obj
      [ ("disposition", str (dispositionText e.disposition))
      , ("failure", maybeJson toJson e.failure)
      , ("checks", Array (map toJson e.checks))
      , ("journal_digest", str e.journalDigest)
      ]

instance ToJson AnyArtifact where
  toJson = \case
    ArtifactV1 a ->
      obj
        [ ("format", str artifactFormat)
        , ("version", int 1)
        , ("api", str legacyApiCompatibility)
        , ("scenario_id", str a.scenarioId)
        , ("profile", toJson a.profile)
        , ("checkers", Array (map toJson a.checkers))
        , ("budget", toJson a.budget)
        , ("operations", Array (map toJson a.operations))
        , ("expected", toJson a.expected)
        ]
    ArtifactV2 a ->
      obj
        ( common a.scenarioId a.profile a.checkers (toJson a.budget) a.operations a.expected
            ++ [("version", int 2), ("api", str previousApiCompatibility)]
        )
    ArtifactV3 a ->
      obj
        ( common a.scenarioId a.profile a.checkers (toJson a.budget) a.operations a.expected
            ++ [("version", int 3), ("api", str seededApiCompatibility), ("origin", maybeJson toJson a.origin)]
        )
    ArtifactV4 a ->
      obj
        ( common a.scenarioId a.profile a.checkers (toJson a.budget) a.operations a.expected
            ++ [("version", int 4), ("api", str apiCompatibility), ("origin", maybeJson toJson a.origin)]
        )
    where
      common sid prof checks budget ops expected =
        [ ("format", str artifactFormat)
        , ("scenario_id", str sid)
        , ("profile", toJson prof)
        , ("checkers", Array (map toJson checks))
        , ("budget", budget)
        , ("operations", Array (map toJson ops))
        , ("expected", toJson expected)
        ]

instance ToJson AnyReplayResult where
  toJson = \case
    ReplayV1 r ->
      obj
        [ ("format", str resultFormat)
        , ("version", int 1)
        , ("scenario_id", str r.scenarioId)
        , ("outcome", str "pass")
        , ("disposition", str (authoredDispositionText r.disposition))
        , ("operations", int r.operations)
        , ("journal_entries", int r.journalEntries)
        , ("journal_digest", str r.journalDigest)
        ]
    ReplayV2 r ->
      obj
        [ ("format", str resultFormat)
        , ("version", int resultVersion)
        , ("scenario_id", str r.scenarioId)
        , ("outcome", str "pass")
        , ("disposition", str (dispositionText r.disposition))
        , ("failure", maybeJson toJson r.failure)
        , ("operations", int r.operations)
        , ("journal_entries", int r.journalEntries)
        , ("journal_digest", str r.journalDigest)
        ]

-- ---------------------------------------------------------------------------
-- Rendering: pydantic repr (diagnostics only)

-- | The pydantic @repr()@ of a model, used in diagnostic messages.
class ToPy a where
  toPy :: a -> PyObj

pyStr :: Text -> PyObj
pyStr = PyStr

pyInt :: Integer -> PyObj
pyInt = PyInt

pyJson :: Json -> PyObj
pyJson = jsonToPy

instance ToPy (Identity 'ProfileKind) where
  toPy i = PyModel "ProfileIdentity" (identityFields i)

instance ToPy (Identity 'CheckerKind) where
  toPy i = PyModel "CheckerIdentity" (identityFields i)

identityFields :: Identity k -> [(Text, PyObj)]
identityFields i = [("name", pyStr i.name), ("version", pyInt i.version), ("digest", pyStr i.digest)]

instance ToPy Command where
  toPy c = PyModel "Command" [("profile", toPy c.profile), ("name", pyStr c.name), ("payload", pyJson c.payload)]

instance ToPy Fault where
  toPy f =
    PyModel
      "Fault"
      [ ("profile", toPy f.profile)
      , ("name", pyStr f.name)
      , ("target", pyStr f.target)
      , ("occurrence", pyInt f.occurrence)
      , ("disposition", pyStr (faultDispositionText f.disposition))
      , ("payload", pyJson f.payload)
      ]

instance ToPy ScheduledCommand where
  toPy s = PyModel "ScheduledCommand" [("instant", pyInt s.instant), ("command", toPy s.command)]

instance ToPy ApplyResult where
  toPy r =
    PyModel
      "ApplyResult"
      [ ("disposition", pyStr (actionDispositionText r.disposition))
      , ("value", pyJson r.value)
      , ("scheduled", PyList (map toPy r.scheduled))
      ]

instance ToPy ObservationRequest where
  toPy r = PyModel "ObservationRequest" [("name", pyStr r.name), ("payload", pyJson r.payload)]

instance ToPy Observation where
  toPy o =
    PyModel
      "Observation"
      [ ("name", pyStr o.name)
      , ("value", pyJson o.value)
      , ("instant", pyInt o.instant)
      , ("generation", pyInt o.generation)
      , ("sequence", pyInt o.sequence)
      ]

instance ToPy OperationAttempt where
  toPy = \case
    ASubmit a ->
      PyModel "SubmitAttempt" [("kind", pyStr "submit"), ("generation", pyInt a.generation), ("command", toPy a.command)]
    AStep -> PyModel "StepAttempt" [("kind", pyStr "step")]
    AFault a ->
      PyModel "FaultAttempt" [("kind", pyStr "activate_fault"), ("generation", pyInt a.generation), ("fault", toPy a.fault)]
    AObserve a ->
      PyModel
        "ObserveAttempt"
        [ ("kind", pyStr "observe")
        , ("generation", pyInt a.generation)
        , ("request", toPy a.request)
        , ("poll", PyBool a.poll)
        ]
    ACrash a -> PyModel "CrashAttempt" [("kind", pyStr "crash"), ("generation", pyInt a.generation), ("cut", pyStr a.cut)]
    ARestart -> PyModel "RestartAttempt" [("kind", pyStr "restart")]
    AFair a -> PyModel "FairAttempt" [("kind", pyStr "begin_fair"), ("generation", pyInt a.generation)]
    AFinish a ->
      PyModel
        "FinishAttempt"
        [ ("kind", pyStr "finish")
        , ("generation", pyInt a.generation)
        , ("disposition", pyStr (authoredDispositionText a.disposition))
        ]

instance ToPy FailureDetail where
  toPy = \case
    FBudget f ->
      PyModel
        "BudgetFailure"
        [("kind", pyStr "budget_exhausted"), ("bound", pyStr f.bound), ("limit", pyInt f.limit), ("error", pyStr f.error)]
    FInvariant f -> PyModel "InvariantFailure" [("kind", pyStr "invariant_failure"), ("error", pyStr f.error)]

instance ToPy ExpandedOperation where
  toPy = \case
    Accepted (OpExecute o) ->
      PyModel
        "ExecuteOperation"
        [ ("kind", pyStr "execute")
        , ("position", pyInt o.position)
        , ("source", pyStr (commandSourceText o.source))
        , ("queue_order", pyInt o.queueOrder)
        , ("instant", pyInt o.instant)
        , ("generation", pyInt o.generation)
        , ("command", toPy o.command)
        , ("result", toPy o.result)
        ]
    Accepted (OpFault o) ->
      PyModel
        "FaultOperation"
        [ ("kind", pyStr "activate_fault")
        , ("position", pyInt o.position)
        , ("instant", pyInt o.instant)
        , ("generation", pyInt o.generation)
        , ("fault", toPy o.fault)
        ]
    Accepted (OpObserve o) ->
      PyModel
        "ObserveOperation"
        [ ("kind", pyStr "observe")
        , ("position", pyInt o.position)
        , ("poll", PyBool o.poll)
        , ("observation", toPy o.observation)
        , ("request", toPy o.request)
        ]
    Accepted (OpCrash o) ->
      PyModel
        "CrashOperation"
        [ ("kind", pyStr "crash")
        , ("position", pyInt o.position)
        , ("instant", pyInt o.instant)
        , ("generation", pyInt o.generation)
        , ("cut", pyStr o.cut)
        , ("discarded_commands", pyInt o.discardedCommands)
        ]
    Accepted (OpRestart o) -> lifecycle "RestartOperation" "restart" o.position o.instant o.generation
    Accepted (OpFair o) -> lifecycle "FairOperation" "begin_fair" o.position o.instant o.generation
    Accepted (OpFinish o) ->
      PyModel
        "FinishOperation"
        [ ("kind", pyStr "finish")
        , ("position", pyInt o.position)
        , ("instant", pyInt o.instant)
        , ("generation", pyInt o.generation)
        , ("disposition", pyStr (authoredDispositionText o.disposition))
        ]
    Failed o ->
      PyModel
        "FailureOperation"
        [ ("kind", pyStr "failure")
        , ("position", pyInt o.position)
        , ("instant", pyInt o.instant)
        , ("generation", maybe PyNone pyInt o.generation)
        , ("accepted_operations", pyInt o.acceptedOperations)
        , ("attempt", toPy o.attempt)
        , ("failure", toPy o.failure)
        ]
    where
      lifecycle cls kind position instant generation =
        PyModel
          cls
          [ ("kind", pyStr kind)
          , ("position", pyInt position)
          , ("instant", pyInt instant)
          , ("generation", pyInt generation)
          ]
