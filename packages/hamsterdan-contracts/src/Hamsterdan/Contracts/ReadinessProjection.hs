{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The derived readiness view of @hamsterdan.contracts.readiness@:
-- @project_readiness@, @dashboard_projection_digest@, @workflow_wait@, and
-- @workflow_gates_ready@.
--
-- Python takes the nine concern tokens positionally and builds the snapshot
-- with @ReadinessSnapshot(**merged_dumps)@; here they travel as one
-- 'Concerns' record and the snapshot is built field by field, so the
-- compiler checks that the concern tokens partition the snapshot.
module Hamsterdan.Contracts.ReadinessProjection
  ( Concerns (..)
  , projectReadiness
  , dashboardProjectionDigest
  , workflowWait
  , workflowGatesReady
  ) where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString.Base16 qualified as Base16
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Hamsterdan.Contracts.Codec (Contract, dump, pythonDict)
import Hamsterdan.Contracts.Readiness
import Petrus.Json (EncodeOptions (..), Json (..), compact, dumps)

-- | The independently owned state a readiness snapshot merges.
data Concerns = Concerns
  { authority :: Authority
  , actions :: ActionsState
  , review :: ReviewState
  , human :: HumanState
  , mutation :: MutationState
  , findingPublication :: FindingPublicationState
  , conversationPublication :: ConversationPublicationState
  , dashboardPublication :: DashboardPublicationState
  , readinessPublication :: ReadinessPublicationState
  }
  deriving stock (Eq, Show)

-- | @project_readiness@: merge the concerns and derive the external wait.
projectReadiness :: Concerns -> ReadinessSnapshot
projectReadiness concerns = build (workflowWait (build ""))
  where
    a = concerns.authority
    act = concerns.actions
    rev = concerns.review
    hum = concerns.human
    mut = concerns.mutation
    fin = concerns.findingPublication
    con = concerns.conversationPublication
    dash = concerns.dashboardPublication
    ready = concerns.readinessPublication
    current =
      dashboardProjectionDigest concerns == dash.dashboardProjection
        && not dash.dashboardRequested
    build waitFor =
      ReadinessSnapshot
        { repositoryId = a.repositoryId
        , prNumber = a.prNumber
        , epoch = a.epoch
        , head = a.head
        , baseHead = a.baseHead
        , strictBase = a.strictBase
        , baseCurrent = a.baseCurrent
        , policyDigest = a.policyDigest
        , requiredChecks = a.requiredChecks
        , requiredApprovals = a.requiredApprovals
        , conversationResolution = a.conversationResolution
        , admissionRelation = a.admissionRelation
        , provisionalHead = mut.provisionalHead
        , actions = act.actions
        , runId = act.runId
        , attempt = act.attempt
        , rerunRequested = act.rerunRequested
        , rerunAttempt = act.rerunAttempt
        , fingerprint = act.fingerprint
        , repairLineage = mut.repairLineage
        , repairUsed = mut.repairUsed
        , repairFingerprint = mut.repairFingerprint
        , actionsObservation = act.actionsObservation
        , review = rev.review
        , findings = rev.findings
        , findingLineage = rev.findingLineage
        , findingsPublished = fin.findingsPublished
        , findingPublicationRequested = fin.findingPublicationRequested
        , observationSequence = hum.observationSequence
        , humanRequested = hum.humanRequested
        , humanApproved = hum.humanApproved
        , changesRequested = hum.changesRequested
        , unresolvedConversations = hum.unresolvedConversations
        , distinctReviewerRequired = hum.distinctReviewerRequired
        , distinctReviewerApproved = hum.distinctReviewerApproved
        , mergeable = hum.mergeable
        , conflict = hum.conflict
        , provisional = mut.provisional
        , changeInFlight = mut.changeInFlight
        , repairInFlight = mut.repairInFlight
        , repairRecoveryRequired = mut.repairRecoveryRequired
        , dashboardCurrent = current
        , dashboardProjection = dash.dashboardProjection
        , dashboardRequestedProjection = dash.dashboardRequestedProjection
        , dashboardRequested = dash.dashboardRequested
        , dashboardOperation = dash.dashboardOperation
        , dashboardFormat = dash.dashboardFormat
        , conversationRequested = con.conversationRequested
        , conversationOperation = con.conversationOperation
        , conversationCapabilityBlocking = con.conversationCapabilityBlocking
        , conversationPublicationFault = con.conversationPublicationFault
        , reviewOperation = rev.reviewOperation
        , reviewAttempts = rev.reviewAttempts
        , actionsOperation = act.actionsOperation
        , findingOperation = fin.findingOperation
        , mutationOperation = mut.mutationOperation
        , reminderSnoozed = hum.reminderSnoozed
        , reminderRecipient = hum.reminderRecipient
        , author = hum.author
        , actionsCapabilityBlocking = act.actionsCapabilityBlocking
        , humanCapabilityBlocking = hum.humanCapabilityBlocking
        , dashboardCapabilityBlocking = dash.dashboardCapabilityBlocking
        , dashboardPublicationFault = dash.dashboardPublicationFault
        , findingCapabilityBlocking = fin.findingCapabilityBlocking
        , readinessCapabilityBlocking = ready.readinessCapabilityBlocking
        , readinessPublicationFault = ready.readinessPublicationFault
        , readinessOperation = ready.readinessOperation
        , readinessRequested = ready.readinessRequested
        , announced = ready.announced
        , wait = waitFor
        }

-- | @dashboard_projection_digest@: SHA-256 (hex) of
-- @json.dumps(facts, sort_keys=True, separators=(",", ":"), ensure_ascii=False)@
-- over every concern's dumped members except the dashboard's own
-- bookkeeping.
dashboardProjectionDigest :: Concerns -> Text
dashboardProjectionDigest concerns =
  TE.decodeUtf8 (Base16.encode (SHA256.hash canonical))
  where
    facts =
      pythonDict
        [ member
        | member@(key, _) <-
            concat
              [ members concerns.authority
              , members concerns.actions
              , members concerns.review
              , members concerns.human
              , members concerns.mutation
              , members concerns.findingPublication
              , members concerns.conversationPublication
              , members concerns.dashboardPublication
              , members concerns.readinessPublication
              ]
        , key `notElem` excluded
        ]
    -- Dumped values are JSON-mode (non-finite floats already null), so
    -- allowing NaN never changes the spelling; it only makes encoding total.
    canonical = either (const mempty) id (dumps compact {sortKeys = True, allowNan = True} (Object facts))
    excluded =
      [ "observation_sequence"
      , "dashboard_projection"
      , "dashboard_requested_projection"
      , "dashboard_requested"
      , "dashboard_operation"
      , "dashboard_recovery"
      , "conversation_recovery"
      , "readiness_recovery"
      , "dashboard_format"
      ]

members :: (Contract a) => a -> [(Text, Json)]
members value = case dump value of
  Object found -> found
  _ -> []

-- | @workflow_wait@: the single highest-priority external wait.
workflowWait :: ReadinessSnapshot -> Text
workflowWait control
  | control.provisional = "verified head admission"
  | control.conflict = "conflict resolution"
  | control.changeInFlight = "change result"
  | control.repairInFlight = "repair result"
  | control.repairRecoveryRequired = "repair recovery"
  | control.actionsCapabilityBlocking = "Actions capability"
  | control.actions `notElem` [ActionsGreen, ActionsFlakyGreen] = case control.actions of
      ActionsFailed -> "same-head rerun"
      ActionsReproduced -> if control.repairUsed then "human repair authorization" else "repair"
      ActionsCapabilityUnavailable -> "Actions capability"
      _ -> "GitHub Actions"
  | control.review == ReviewPending = "coordinating agent review"
  | control.review == ReviewUnable = "coordinating review capability"
  | control.review == ReviewBlocking = "finding disposition or change"
  | not control.findingsPublished = "finding publication"
  | control.changesRequested = "requested changes"
  | control.unresolvedConversations /= 0 = "conversation resolution"
  | control.humanCapabilityBlocking = "human-review capability"
  | not control.humanApproved || (control.distinctReviewerRequired && not control.distinctReviewerApproved) = "human review"
  | control.strictBase && not control.baseCurrent = "base update"
  | not control.mergeable = "GitHub mergeability"
  | control.findingCapabilityBlocking = "finding publication capability"
  | control.dashboardPublicationFault = "dashboard publication fault"
  | control.dashboardCapabilityBlocking = "dashboard update capability"
  | control.conversationPublicationFault = "conversation publication fault"
  | control.conversationCapabilityBlocking = "conversation reply capability"
  | control.readinessPublicationFault = "readiness publication fault"
  | control.readinessCapabilityBlocking = "readiness publication capability"
  | otherwise = "terminal lifecycle"

-- | @workflow_gates_ready@: every gate that does not depend on publishing
-- the projection itself.
workflowGatesReady :: ReadinessSnapshot -> Bool
workflowGatesReady control =
  and
    [ control.actions `elem` [ActionsGreen, ActionsFlakyGreen]
    , findingsClear
    , control.findingsPublished
    , control.humanApproved
    , not control.changesRequested
    , control.unresolvedConversations == 0
    , not control.distinctReviewerRequired || control.distinctReviewerApproved
    , control.baseCurrent || not control.strictBase
    , control.mergeable
    , not control.conflict
    , not (control.provisional || control.changeInFlight || control.repairInFlight)
    , not control.actionsCapabilityBlocking
    , not control.humanCapabilityBlocking
    , not control.dashboardCapabilityBlocking
    , not control.dashboardPublicationFault
    , not control.findingCapabilityBlocking
    , not control.conversationCapabilityBlocking
    , not control.conversationPublicationFault
    , not control.readinessCapabilityBlocking
    , not control.readinessPublicationFault
    ]
  where
    findingsClear = control.review == ReviewClear && not (any openBlocking control.findings)
    openBlocking finding =
      let get key = lookup key (pythonDict finding)
       in maybe False truthy (get "blocking")
            && get "disposition" `elem` map (Just . String) ["new", "still_open"]

-- | Python truthiness of a JSON value.
truthy :: Json -> Bool
truthy = \case
  Null -> False
  Bool value -> value
  Int value -> value /= 0
  Float value -> value /= 0
  String value -> value /= ""
  Array values -> not (null values)
  Object found -> not (null found)
