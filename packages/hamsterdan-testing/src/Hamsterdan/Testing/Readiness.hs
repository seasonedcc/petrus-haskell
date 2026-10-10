{-# LANGUAGE NamedFieldPuns #-}

-- | Independent expected-readiness model for deterministic simulation
-- (@hamsterdan/testing/readiness.py@).
--
-- This module deliberately knows only normalized external facts. It does
-- not import either readiness topology, Petrus, or the host projections
-- being judged: its only dependency beyond the base libraries is the
-- strict pydantic-faithful codec of hamsterdan-contracts, so a value
-- dumps and loads exactly as the reference's @StrictValue@.
--
-- The reference's frozen pydantic dataclasses validate on construction.
-- Haskell records do not, so every @__post_init__@ rule lives in the
-- codec: 'load' (and 'checked', which re-validates a constructed value)
-- refuse exactly what the reference's constructor refuses. 'evaluate' and
-- 'evaluateLiveness' are total over any value.
module Hamsterdan.Testing.Readiness
  ( -- * Vocabularies
    Lifecycle (..)
  , CheckStatus (..)
  , CiRecovery (..)
  , ReviewStatus (..)
  , FindingDisposition (..)
  , MutationStatus (..)
  , ChangeIntent (..)
  , EffectKind (..)
  , EffectStatus (..)
  , TimerStatus (..)
  , ReadinessDisposition (..)
  , LivenessDisposition (..)
  , Spelled (..)

    -- * Facts
  , AuthorityClaim (..)
  , AuthorityFacts (..)
  , CheckFacts (..)
  , CiFacts (..)
  , ciFacts
  , Finding (..)
  , ReviewFacts (..)
  , reviewFacts
  , HumanFacts (..)
  , humanFacts
  , ChangeAuthorization (..)
  , MutationFacts (..)
  , mutationFacts
  , EffectObligation (..)
  , effectObligation
  , TimerObligation (..)
  , timerObligation
  , ReadinessFacts (..)
  , readinessFacts
  , ReadinessExpectation (..)
  , FairEnvironment (..)
  , declared

    -- * Strict values
  , dump
  , load
  , loadJson
  , checked

    -- * The model
  , evaluate
  , evaluateLiveness
  ) where

import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Contracts.Codec
  ( Codec
  , Contract (..)
  , bool
  , dump
  , enum
  , field
  , fieldDefault
  , integer
  , list
  , nullable
  , record
  , refine
  , renderDecodeError
  , text
  , validate
  , validateJson
  )
import Petrus.Json (Json)

-- ---------------------------------------------------------------------------
-- Vocabularies (the reference's @Literal[...]@ aliases)

-- | The exact @Literal@ spelling of a vocabulary member.
class (Bounded a, Enum a) => Spelled a where
  spell :: a -> Text

vocabulary :: (Spelled a) => Text -> Codec a
vocabulary name = enum name spell

data Lifecycle = Active | Draft | Merged | Closed
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled Lifecycle where
  spell = \case
    Active -> "active"
    Draft -> "draft"
    Merged -> "merged"
    Closed -> "closed"

data CheckStatus = Queued | Running | Success | Failure | Canceled | Unavailable
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled CheckStatus where
  spell = \case
    Queued -> "queued"
    Running -> "running"
    Success -> "success"
    Failure -> "failure"
    Canceled -> "canceled"
    Unavailable -> "unavailable"

data CiRecovery = RecoveryNone | RecoveryAutomatic | RecoveryHumanAuthorization | RecoveryBlocked
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled CiRecovery where
  spell = \case
    RecoveryNone -> "none"
    RecoveryAutomatic -> "automatic"
    RecoveryHumanAuthorization -> "human_authorization"
    RecoveryBlocked -> "blocked"

data ReviewStatus = ReviewPending | ReviewClear | ReviewBlocking | ReviewUnable
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled ReviewStatus where
  spell = \case
    ReviewPending -> "pending"
    ReviewClear -> "clear"
    ReviewBlocking -> "blocking"
    ReviewUnable -> "unable"

data FindingDisposition = FindingOpen | FindingDismissed | FindingResolved
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled FindingDisposition where
  spell = \case
    FindingOpen -> "open"
    FindingDismissed -> "dismissed"
    FindingResolved -> "resolved"

data MutationStatus
  = MutationIdle
  | MutationRequested
  | MutationInFlight
  | MutationAcceptedPendingAdmission
  | MutationAmbiguous
  | MutationBlocked
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled MutationStatus where
  spell = \case
    MutationIdle -> "idle"
    MutationRequested -> "requested"
    MutationInFlight -> "in_flight"
    MutationAcceptedPendingAdmission -> "accepted_pending_admission"
    MutationAmbiguous -> "ambiguous"
    MutationBlocked -> "blocked"

data ChangeIntent = IntentChange | IntentRepair
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled ChangeIntent where
  spell = \case
    IntentChange -> "change"
    IntentRepair -> "repair"

data EffectKind
  = EffectDashboard
  | EffectFindings
  | EffectConversation
  | EffectReminder
  | EffectReadiness
  | EffectRerun
  | EffectGitMutation
  | EffectAgentReview
  | EffectCoding
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled EffectKind where
  spell = \case
    EffectDashboard -> "dashboard"
    EffectFindings -> "findings"
    EffectConversation -> "conversation"
    EffectReminder -> "reminder"
    EffectReadiness -> "readiness"
    EffectRerun -> "rerun"
    EffectGitMutation -> "git_mutation"
    EffectAgentReview -> "agent_review"
    EffectCoding -> "coding"

data EffectStatus
  = EffectRequested
  | EffectAccepted
  | EffectAmbiguous
  | EffectBlocked
  | EffectRejected
  | EffectSettled
  | EffectCanceled
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled EffectStatus where
  spell = \case
    EffectRequested -> "requested"
    EffectAccepted -> "accepted"
    EffectAmbiguous -> "ambiguous"
    EffectBlocked -> "blocked"
    EffectRejected -> "rejected"
    EffectSettled -> "settled"
    EffectCanceled -> "canceled"

data TimerStatus = TimerScheduled | TimerDue | TimerAcknowledged | TimerCanceled
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled TimerStatus where
  spell = \case
    TimerScheduled -> "scheduled"
    TimerDue -> "due"
    TimerAcknowledged -> "acknowledged"
    TimerCanceled -> "canceled"

data ReadinessDisposition = Ready | Progressing | HumanWait | ExternalWait | Terminal | Quarantined
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled ReadinessDisposition where
  spell = \case
    Ready -> "ready"
    Progressing -> "progressing"
    HumanWait -> "human_wait"
    ExternalWait -> "external_wait"
    Terminal -> "terminal"
    Quarantined -> "quarantined"

data LivenessDisposition = NotApplicable | InProgress | Converged | Livelock
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Spelled LivenessDisposition where
  spell = \case
    NotApplicable -> "not_applicable"
    InProgress -> "in_progress"
    Converged -> "converged"
    Livelock -> "livelock"

-- ---------------------------------------------------------------------------
-- Facts

-- | One normalized provider or admitted authority snapshot.
data AuthorityClaim = AuthorityClaim
  { installation :: Integer
  , repository :: Integer
  , pullRequest :: Integer
  , head :: Text
  , base :: Text
  , policy :: Text
  , lifecycle :: Lifecycle
  , strictBase :: Bool
  , baseCurrent :: Bool
  , mergeable :: Bool
  }
  deriving stock (Eq, Ord, Show)

instance Contract AuthorityClaim where
  contract =
    refine check . record "AuthorityClaim" $
      AuthorityClaim
        <$> field "installation" (.installation) integer
        <*> field "repository" (.repository) integer
        <*> field "pull_request" (.pullRequest) integer
        <*> field "head" (.head) text
        <*> field "base" (.base) text
        <*> field "policy" (.policy) text
        <*> field "lifecycle" (.lifecycle) (vocabulary "Lifecycle")
        <*> field "strict_base" (.strictBase) bool
        <*> field "base_current" (.baseCurrent) bool
        <*> field "mergeable" (.mergeable) bool
   where
    check c
      | minimum [c.installation, c.repository, c.pullRequest] <= 0 = Left "authority identities must be positive"
      | otherwise = Right c

-- | Current provider truth beside the latest admitted generation.
data AuthorityFacts = AuthorityFacts
  { generation :: Integer
  , admitted :: Maybe AuthorityClaim
  , provider :: AuthorityClaim
  }
  deriving stock (Eq, Show)

instance Contract AuthorityFacts where
  contract =
    refine check . record "AuthorityFacts" $
      AuthorityFacts
        <$> field "generation" (.generation) integer
        <*> field "admitted" (.admitted) (nullable contract)
        <*> field "provider" (.provider) contract
   where
    check f
      | f.generation < 0 || isNothing f.admitted /= (f.generation == 0) = Left "generation zero must have no admitted authority"
      | otherwise = Right f

-- | Latest provider truth for one policy-required CI check.
data CheckFacts = CheckFacts
  { name :: Text
  , status :: CheckStatus
  }
  deriving stock (Eq, Show)

instance Contract CheckFacts where
  contract =
    record "CheckFacts" $
      CheckFacts
        <$> field "name" (.name) text
        <*> field "status" (.status) (vocabulary "CheckStatus")

data CiFacts = CiFacts
  { head :: Text
  , requiredChecks :: [Text]
  , checks :: [CheckFacts]
  , recovery :: CiRecovery
  }
  deriving stock (Eq, Show)

-- | @CiFacts()@.
ciFacts :: CiFacts
ciFacts = CiFacts {head = "", requiredChecks = [], checks = [], recovery = RecoveryNone}

instance Contract CiFacts where
  contract =
    record "CiFacts" $
      CiFacts
        <$> fieldDefault "head" (.head) "" text
        <*> fieldDefault "required_checks" (.requiredChecks) [] (list text)
        <*> fieldDefault "checks" (.checks) [] (list contract)
        <*> fieldDefault "recovery" (.recovery) RecoveryNone (vocabulary "CiRecovery")

data Finding = Finding
  { identity :: Text
  , blocking :: Bool
  , disposition :: FindingDisposition
  }
  deriving stock (Eq, Show)

instance Contract Finding where
  contract =
    record "Finding" $
      Finding
        <$> field "identity" (.identity) text
        <*> field "blocking" (.blocking) bool
        <*> field "disposition" (.disposition) (vocabulary "FindingDisposition")

data ReviewFacts = ReviewFacts
  { head :: Text
  , status :: ReviewStatus
  , findings :: [Finding]
  }
  deriving stock (Eq, Show)

-- | @ReviewFacts()@.
reviewFacts :: ReviewFacts
reviewFacts = ReviewFacts {head = "", status = ReviewPending, findings = []}

instance Contract ReviewFacts where
  contract =
    record "ReviewFacts" $
      ReviewFacts
        <$> fieldDefault "head" (.head) "" text
        <*> fieldDefault "status" (.status) ReviewPending (vocabulary "ReviewStatus")
        <*> fieldDefault "findings" (.findings) [] (list contract)

data HumanFacts = HumanFacts
  { approvals :: Integer
  , requiredApprovals :: Integer
  , changesRequested :: Bool
  , unresolvedConversations :: Integer
  , distinctReviewerRequired :: Bool
  , distinctReviewerApproved :: Bool
  }
  deriving stock (Eq, Show)

-- | @HumanFacts()@.
humanFacts :: HumanFacts
humanFacts =
  HumanFacts
    { approvals = 0
    , requiredApprovals = 0
    , changesRequested = False
    , unresolvedConversations = 0
    , distinctReviewerRequired = False
    , distinctReviewerApproved = False
    }

instance Contract HumanFacts where
  contract =
    refine check . record "HumanFacts" $
      HumanFacts
        <$> fieldDefault "approvals" (.approvals) 0 integer
        <*> fieldDefault "required_approvals" (.requiredApprovals) 0 integer
        <*> fieldDefault "changes_requested" (.changesRequested) False bool
        <*> fieldDefault "unresolved_conversations" (.unresolvedConversations) 0 integer
        <*> fieldDefault "distinct_reviewer_required" (.distinctReviewerRequired) False bool
        <*> fieldDefault "distinct_reviewer_approved" (.distinctReviewerApproved) False bool
   where
    check h
      | minimum [h.approvals, h.requiredApprovals, h.unresolvedConversations] < 0 = Left "human fact counts cannot be negative"
      | otherwise = Right h

-- | One admitted human grant for an exact operation and authority.
data ChangeAuthorization = ChangeAuthorization
  { identity :: Text
  , operation :: Text
  , authority :: AuthorityClaim
  , intent :: ChangeIntent
  , intentDigest :: Text
  }
  deriving stock (Eq, Show)

instance Contract ChangeAuthorization where
  contract =
    record "ChangeAuthorization" $
      ChangeAuthorization
        <$> field "identity" (.identity) text
        <*> field "operation" (.operation) text
        <*> field "authority" (.authority) contract
        <*> field "intent" (.intent) (vocabulary "ChangeIntent")
        <*> field "intent_digest" (.intentDigest) text

data MutationFacts = MutationFacts
  { status :: MutationStatus
  , operation :: Text
  , head :: Text
  , resultHead :: Text
  , authorization :: Maybe ChangeAuthorization
  }
  deriving stock (Eq, Show)

-- | @MutationFacts()@.
mutationFacts :: MutationFacts
mutationFacts = MutationFacts {status = MutationIdle, operation = "", head = "", resultHead = "", authorization = Nothing}

instance Contract MutationFacts where
  contract =
    refine check . record "MutationFacts" $
      MutationFacts
        <$> fieldDefault "status" (.status) MutationIdle (vocabulary "MutationStatus")
        <*> fieldDefault "operation" (.operation) "" text
        <*> fieldDefault "head" (.head) "" text
        <*> fieldDefault "result_head" (.resultHead) "" text
        <*> fieldDefault "authorization" (.authorization) Nothing (nullable contract)
   where
    check m
      | m.status /= MutationIdle && (T.null m.operation || T.null m.head) = Left "active mutation facts require an operation and head"
      | not (T.null m.resultHead) && m.status `notElem` [MutationAcceptedPendingAdmission, MutationAmbiguous] =
          Left "only an accepted or ambiguous mutation may declare a result head"
      | otherwise = Right m

data EffectObligation = EffectObligation
  { kind :: EffectKind
  , operation :: Text
  , authority :: AuthorityClaim
  , contentDigest :: Text
  , status :: EffectStatus
  , providerAuthorityAtAcceptance :: Maybe AuthorityClaim
  , authorization :: Maybe Text
  , blocksReadiness :: Bool
  }
  deriving stock (Eq, Show)

-- | @EffectObligation(kind, operation, authority, content_digest, status)@
-- with the reference's defaults for the rest.
effectObligation :: EffectKind -> Text -> AuthorityClaim -> Text -> EffectStatus -> EffectObligation
effectObligation kind operation authority digest status =
  EffectObligation
    { kind
    , operation
    , authority
    , contentDigest = digest
    , status
    , providerAuthorityAtAcceptance = Nothing
    , authorization = Nothing
    , blocksReadiness = True
    }

instance Contract EffectObligation where
  contract =
    refine check . record "EffectObligation" $
      EffectObligation
        <$> field "kind" (.kind) (vocabulary "EffectKind")
        <*> field "operation" (.operation) text
        <*> field "authority" (.authority) contract
        <*> field "content_digest" (.contentDigest) text
        <*> field "status" (.status) (vocabulary "EffectStatus")
        <*> fieldDefault "provider_authority_at_acceptance" (.providerAuthorityAtAcceptance) Nothing (nullable contract)
        <*> fieldDefault "authorization" (.authorization) Nothing (nullable text)
        <*> fieldDefault "blocks_readiness" (.blocksReadiness) True bool
   where
    check e
      | e.status `elem` [EffectAccepted, EffectSettled] && isNothing e.providerAuthorityAtAcceptance =
          Left "accepted effects require provider authority at acceptance"
      | otherwise = Right e

data TimerObligation = TimerObligation
  { identity :: Text
  , status :: TimerStatus
  , blocksReadiness :: Bool
  }
  deriving stock (Eq, Show)

-- | @TimerObligation(identity, status)@.
timerObligation :: Text -> TimerStatus -> TimerObligation
timerObligation identity status = TimerObligation {identity, status, blocksReadiness = False}

instance Contract TimerObligation where
  contract =
    record "TimerObligation" $
      TimerObligation
        <$> field "identity" (.identity) text
        <*> field "status" (.status) (vocabulary "TimerStatus")
        <*> fieldDefault "blocks_readiness" (.blocksReadiness) False bool

-- | Topology-neutral facts from authored world truth and admitted events.
data ReadinessFacts = ReadinessFacts
  { subject :: Text
  , authority :: AuthorityFacts
  , admittedObservations :: [Text]
  , ci :: CiFacts
  , review :: ReviewFacts
  , human :: HumanFacts
  , mutation :: MutationFacts
  , effects :: [EffectObligation]
  , timers :: [TimerObligation]
  }
  deriving stock (Eq, Show)

-- | @ReadinessFacts(subject, authority)@ with every default.
readinessFacts :: Text -> AuthorityFacts -> ReadinessFacts
readinessFacts subject authority =
  ReadinessFacts
    { subject
    , authority
    , admittedObservations = []
    , ci = ciFacts
    , review = reviewFacts
    , human = humanFacts
    , mutation = mutationFacts
    , effects = []
    , timers = []
    }

instance Contract ReadinessFacts where
  contract =
    refine check . record "ReadinessFacts" $
      ReadinessFacts
        <$> field "subject" (.subject) text
        <*> field "authority" (.authority) contract
        <*> fieldDefault "admitted_observations" (.admittedObservations) [] (list text)
        <*> fieldDefault "ci" (.ci) ciFacts contract
        <*> fieldDefault "review" (.review) reviewFacts contract
        <*> fieldDefault "human" (.human) humanFacts contract
        <*> fieldDefault "mutation" (.mutation) mutationFacts contract
        <*> fieldDefault "effects" (.effects) [] (list contract)
        <*> fieldDefault "timers" (.timers) [] (list contract)
   where
    check f
      | f.subject /= expected = Left "readiness subject must match provider authority"
      | Just a <- f.authority.admitted, pr a /= pr provider = Left "admitted and provider authority must describe one pull request"
      | otherwise = Right f
     where
      provider = f.authority.provider
      expected = "github:" <> num provider.installation <> ":" <> num provider.repository <> ":pr:" <> num provider.pullRequest
      pr c = (c.installation, c.repository, c.pullRequest)
      num = T.pack . show

data ReadinessExpectation = ReadinessExpectation
  { subject :: Text
  , generation :: Integer
  , ready :: Bool
  , disposition :: ReadinessDisposition
  , blockers :: [Text]
  , violations :: [Text]
  }
  deriving stock (Eq, Show)

instance Contract ReadinessExpectation where
  contract =
    record "ReadinessExpectation" $
      ReadinessExpectation
        <$> field "subject" (.subject) text
        <*> field "generation" (.generation) integer
        <*> field "ready" (.ready) bool
        <*> field "disposition" (.disposition) (vocabulary "ReadinessDisposition")
        <*> field "blockers" (.blockers) (list text)
        <*> field "violations" (.violations) (list text)

-- | Conditions under which exhausted progress is a runtime liveness bug.
data FairEnvironment = FairEnvironment
  { generatedFaultsStopped :: Bool
  , authorityStable :: Bool
  , workersAvailable :: Bool
  , logicalTimeAdvances :: Bool
  , durableStoresReadable :: Bool
  }
  deriving stock (Eq, Show)

instance Contract FairEnvironment where
  contract =
    record "FairEnvironment" $
      FairEnvironment
        <$> field "generated_faults_stopped" (.generatedFaultsStopped) bool
        <*> field "authority_stable" (.authorityStable) bool
        <*> field "workers_available" (.workersAvailable) bool
        <*> field "logical_time_advances" (.logicalTimeAdvances) bool
        <*> field "durable_stores_readable" (.durableStoresReadable) bool

-- | @FairEnvironment.declared@.
declared :: FairEnvironment -> Bool
declared e = and [e.generatedFaultsStopped, e.authorityStable, e.workersAvailable, e.logicalTimeAdvances, e.durableStoresReadable]

-- ---------------------------------------------------------------------------
-- Strict values

-- | @StrictValue.load(encoded)@: strict JSON validation, construction rules
-- included. The refusal is the codec's rendered error.
load :: (Contract a) => ByteString -> Either Text a
load = either (Left . renderDecodeError) Right . validateJson

-- | 'load' from an already parsed JSON value.
loadJson :: (Contract a) => Json -> Either Text a
loadJson = either (Left . renderDecodeError) Right . validate

-- | The reference's constructor: a Haskell-built value, accepted exactly
-- when the reference would have constructed it.
checked :: (Contract a) => a -> Either Text a
checked = loadJson . dump

-- ---------------------------------------------------------------------------
-- The model (@ReadinessModel@)

-- | @ReadinessModel().evaluate(facts)@.
evaluate :: ReadinessFacts -> ReadinessExpectation
evaluate facts =
  ReadinessExpectation
    { subject = facts.subject
    , generation = facts.authority.generation
    , ready = disposition == Ready
    , disposition
    , blockers = found
    , violations = broken
    }
 where
  found = blockersOf facts
  broken = violationsOf facts found
  disposition = dispositionOf facts found broken

blockersOf :: ReadinessFacts -> [Text]
blockersOf facts = case authorityBoundary facts.authority of
  Just boundary -> boundary
  Nothing -> case facts.authority.admitted of
    Nothing -> ["current_authority_admission"]
    Just admitted ->
      authorityGateBlockers admitted
        <> ciBlockers facts.ci admitted.head
        <> reviewBlockers facts.review admitted.head
        <> humanBlockers facts.human
        <> workBlockers facts

authorityBoundary :: AuthorityFacts -> Maybe [Text]
authorityBoundary authority = case authority.admitted of
  Just admitted
    | admitted == authority.provider -> case admitted.lifecycle of
        Merged -> Just []
        Closed -> Just []
        Draft -> Just ["pull_request_draft"]
        Active -> Nothing
  _ -> Just ["current_authority_admission"]

authorityGateBlockers :: AuthorityClaim -> [Text]
authorityGateBlockers admitted =
  ["current_base" | admitted.strictBase && not admitted.baseCurrent] <> ["mergeability" | not admitted.mergeable]

ciBlockers :: CiFacts -> Text -> [Text]
ciBlockers ci currentHead
  | ci.head /= currentHead = ["current_ci_evidence"]
  | otherwise = concatMap blocker ci.requiredChecks
 where
  -- @{check.name: check.status for check in ci.checks}@: the last wins.
  statuses = Map.fromList [(check.name, check.status) | check <- ci.checks]
  blocker name = case Map.lookup name statuses of
    Nothing -> ["required_ci_missing:" <> name]
    Just Failure
      | ci.recovery == RecoveryHumanAuthorization -> ["ci_repair_authorization:" <> name]
      | otherwise -> ["ci_failed:" <> name]
    Just Unavailable -> ["ci_capability:" <> name]
    Just Canceled -> ["ci_capability:" <> name]
    Just Success -> []
    Just _ -> ["ci_terminal:" <> name]

reviewBlockers :: ReviewFacts -> Text -> [Text]
reviewBlockers review currentHead
  | review.head /= currentHead = ["current_review_evidence"]
  | review.status == ReviewPending = ["review_pending"]
  | review.status == ReviewUnable = ["review_capability"]
  | review.status == ReviewBlocking || any (\f -> f.blocking && f.disposition == FindingOpen) review.findings = ["blocking_findings"]
  | otherwise = []

humanBlockers :: HumanFacts -> [Text]
humanBlockers human =
  ["changes_requested" | human.changesRequested]
    <> ["unresolved_conversations" | human.unresolvedConversations /= 0]
    <> [ "human_approval"
       | human.approvals < human.requiredApprovals || (human.distinctReviewerRequired && not human.distinctReviewerApproved)
       ]

workBlockers :: ReadinessFacts -> [Text]
workBlockers facts =
  mutationBlocker facts.mutation.status
    <> [ "effect_" <> spell effect.status <> ":" <> effect.operation
       | effect <- facts.effects
       , effect.blocksReadiness
       , effect.status `notElem` [EffectSettled, EffectCanceled]
       ]
    <> [ "timer_" <> spell timer.status <> ":" <> timer.identity
       | timer <- facts.timers
       , timer.blocksReadiness
       , timer.status `notElem` [TimerAcknowledged, TimerCanceled]
       ]
 where
  mutationBlocker = \case
    MutationIdle -> []
    MutationRequested -> ["mutation_requested"]
    MutationInFlight -> ["mutation_in_flight"]
    MutationAcceptedPendingAdmission -> ["mutation_admission"]
    MutationAmbiguous -> ["mutation_ambiguous"]
    MutationBlocked -> ["mutation_blocked"]

violationsOf :: ReadinessFacts -> [Text] -> [Text]
violationsOf facts found = admissionViolations facts <> changeAuthorizationViolations facts <> effectViolations facts found

admissionViolations :: ReadinessFacts -> [Text]
admissionViolations facts =
  [ "duplicate_admission:" <> identity
  | (identity, count) <- Map.toAscList (Map.fromListWith (+) [(o, 1 :: Int) | o <- facts.admittedObservations])
  , count > 1
  ]

changeAuthorizationViolations :: ReadinessFacts -> [Text]
changeAuthorizationViolations facts
  | mutation.status == MutationIdle && null changeEffects = []
  | otherwise = ["unauthorized_change:" <> operation | operation <- Set.toAscList operations, not (authorized operation)]
 where
  mutation = facts.mutation
  changeEffects =
    [ effect
    | effect <- facts.effects
    , effect.kind `elem` [EffectCoding, EffectGitMutation]
    , effect.status /= EffectCanceled
    ]
  operations =
    Set.fromList (map (.operation) changeEffects)
      <> (if mutation.status /= MutationIdle then Set.singleton mutation.operation else Set.empty)
  current = facts.authority.provider
  authorityIsAdmitted = facts.authority.admitted == Just current
  authorized operation = case mutation.authorization of
    Nothing -> False
    Just grant ->
      let boundEffects = [effect | effect <- changeEffects, effect.operation == operation]
          selfPush =
            mutation.operation == operation
              && mutation.status `elem` [MutationAcceptedPendingAdmission, MutationAmbiguous]
              && mutation.resultHead == current.head
              && (facts.authority.admitted == Just grant.authority || facts.authority.admitted == Just current)
              && sameAuthorityExceptHead grant.authority current
       in grant.operation == operation
            && grant.identity `elem` facts.admittedObservations
            && grant.authority.lifecycle == Active
            && ((grant.authority == current && authorityIsAdmitted) || selfPush)
            && all (\effect -> effect.authority == grant.authority && effect.authorization == Just grant.identity) boundEffects
            && (mutation.status == MutationIdle || mutation.operation /= operation || mutation.head == grant.authority.head)

sameAuthorityExceptHead :: AuthorityClaim -> AuthorityClaim -> Bool
sameAuthorityExceptHead left right = withoutHead left == withoutHead right
 where
  withoutHead c = (c.installation, c.repository, c.pullRequest, c.base, c.policy, c.lifecycle, c.strictBase, c.baseCurrent, c.mergeable)

effectViolations :: ReadinessFacts -> [Text] -> [Text]
effectViolations facts found = collisions <> stale <> readiness
 where
  digests = Map.fromListWith Set.union [(effect.operation, Set.singleton effect.contentDigest) | effect <- facts.effects]
  collisions = ["effect_identity_collision:" <> operation | (operation, values) <- Map.toAscList digests, Set.size values > 1]
  stale =
    [ "stale_effect_settled:" <> effect.operation
    | effect <- facts.effects
    , effect.kind `notElem` [EffectDashboard, EffectConversation, EffectReminder]
    , Just accepted <- [effect.providerAuthorityAtAcceptance]
    , effect.authority /= accepted
    ]
  gateBlockers = [b | b <- found, not ("effect_" `T.isPrefixOf` b || "timer_" `T.isPrefixOf` b)]
  readiness =
    concat
      [ ["readiness_published_outside_active_lifecycle:" <> effect.operation | effect.authority.lifecycle /= Active]
          <> [ "readiness_published_with_closed_gates:" <> effect.operation
             | (facts.authority.admitted == Just facts.authority.provider || Just effect.authority /= effect.providerAuthorityAtAcceptance)
                 && effect.providerAuthorityAtAcceptance == Just facts.authority.provider
                 && not (null gateBlockers)
             ]
      | effect <- facts.effects
      , effect.kind == EffectReadiness
      , effect.status `elem` [EffectAccepted, EffectSettled]
      ]

dispositionOf :: ReadinessFacts -> [Text] -> [Text] -> ReadinessDisposition
dispositionOf facts found broken
  | not (null broken) = Quarantined
  | Just admitted <- facts.authority.admitted, admitted.lifecycle `elem` [Merged, Closed] = Terminal
  | null found = Ready
  | any ("effect_rejected:" `T.isPrefixOf`) found = Quarantined
  | any (`elem` humanBlocking) found || any ("ci_repair_authorization:" `T.isPrefixOf`) found = HumanWait
  | any (`elem` externalBlocking) found || any (\b -> any (`T.isPrefixOf` b) externalPrefixes) found = ExternalWait
  | otherwise = Progressing
 where
  humanBlocking = ["pull_request_draft", "blocking_findings", "changes_requested", "unresolved_conversations", "human_approval"]
  externalBlocking = ["current_base", "mergeability", "review_capability"]
  externalPrefixes = ["required_ci_missing:", "ci_terminal:", "ci_capability:", "effect_blocked:", "timer_scheduled:"]

-- | @evaluate_liveness(expectation, environment, budget_exhausted=...)@:
-- classify bounded convergence without blaming an unfair environment.
evaluateLiveness :: ReadinessExpectation -> FairEnvironment -> Bool -> LivenessDisposition
evaluateLiveness expectation environment budgetExhausted
  | not (declared environment) || expectation.disposition `elem` [HumanWait, ExternalWait] = NotApplicable
  | expectation.disposition `elem` [Ready, Terminal, Quarantined] = Converged
  | budgetExhausted = Livelock
  | otherwise = InProgress
