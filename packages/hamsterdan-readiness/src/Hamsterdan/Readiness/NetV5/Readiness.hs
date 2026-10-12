{-# LANGUAGE AllowAmbiguousTypes #-}

-- | The readiness loop: the all-gates advisory projection and announce
-- (@net_v5/readiness.py@).
--
-- Owns the Snapshot baton — the sole readiness projection — and consumes
-- each sibling-mailed decision fact through its own typed mailbox. It
-- never merges; it announces exactly once per incarnation on the
-- not-ready → ready edge, through an authority-fenced gate under the
-- stable identity @ready:{head}:i{n}@. The ready edge is a two-step
-- decision: the fold that sees it emits a REVOCABLE candidate, and a
-- separate @authorize@ fold — inhibited while any typed sibling mailbox
-- holds an unfolded fact — re-derives the whole decision from the
-- caught-up snapshot before minting the announce request.
module Hamsterdan.Readiness.NetV5.Readiness
  ( gates
  , declare
  , wire
  , seed
  , ready
  , announceViable
  , authorize
  , applyState
  , applyChecks
  , applyReview
  , applyFindings
  , applyHuman
  , applyMutationPending
  , applyMutationSettled
  , foldState
  , foldChecks
  , foldReview
  , foldFindings
  , foldHuman
  , foldMutationPending
  , foldMutationSettled
  , foldFaultRaised
  , foldFaultCleared
  , migrateState
  , migrateChecks
  , migrateReview
  , migrateFindings
  , migrateHuman
  , migrateMutationPending
  , migrateMutationSettled
  , migrateFaultRaised
  , migrateFaultCleared
  , foldALanded
  , foldADeferred
  , wakeDeferred
  , foldABlocked
  , foldAMoved
  , foldAFault
  , recover
  , end
  , drainState
  , drainChecks
  , drainReview
  , drainFindings
  , drainHuman
  , drainMutationPending
  , drainMutationSettled
  , drainFaultRaised
  , drainFaultCleared
  , drainRecover
  , drainCandidate
  , drainWake
  ) where

import Control.Monad (forM_, guard, void)
import Data.Kind (Type)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (Typeable)
import Hamsterdan.Contracts.Codec (Contract, dump)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.Readiness.NetV5.Folding
import Hamsterdan.Readiness.NetV5.Py
import Hamsterdan.Readiness.NetV5.Wiring
import Petrus.Impetus.Dsl (ArcSpec (..), Author, arc, configure, handler, p, t, (~>))
import Petrus.Impetus.Petrinet (NetPath, Token)
import Petrus.Json (Json (..))

gates :: [(Text, (Text, [Text]))]
gates = [("ready.gate", ("announce_gate", ["ALanded", "ADeferred", "ABlocked", "AMoved", "AFault"]))]

-- -- folds ---------------------------------------------------------------

ready :: Snapshot -> Bool
ready snap =
  snap.phase == "running"
    && snap.checks == "success"
    && snap.review == ReviewClear
    && snap.findingsBlocking == 0
    && snap.approval
    && not snap.changesRequested
    && snap.unresolved == 0
    && snap.mergeable
    && (not snap.strictBase || snap.baseCurrent)
    && null snap.pending
    && null snap.faults

announceViable :: Snapshot -> Bool
announceViable snap =
  ready snap
    && snap.incarnation `notElem` snap.announced
    && null snap.announcing
    && null snap.blocked
    && snap.closing == Nothing

-- | Re-evaluate the announce decision for the CURRENT snapshot: a
-- REVOCABLE candidate, never the request itself.
announceOpen :: Snapshot -> Py [Emit]
announceOpen snap
  | announceViable snap && not snap.candidate = do
      let held = snap {candidate = True} :: Snapshot
      Right [emit "ready.snap" [held], emit "ready.candidate" [AnnounceCandidate {incarnation = snap.incarnation, head = snap.head}]]
  | otherwise = Right [emit "ready.snap" [snap]]

authorize :: Fold
authorize b outs = do
  (_, snap0) <- values2 @AnnounceCandidate @Snapshot b
  let snap = snap0 {candidate = False} :: Snapshot
  if not (announceViable snap)
    then Right (route outs [emit "ready.snap" [snap]])
    else do
      let req =
            AnnounceReq
              { op = "ready:" <> snap.head <> ":i" <> showT snap.incarnation
              , incarnation = snap.incarnation
              , head = snap.head
              , base = snap.base
              , policy = snap.policy
              , strictBase = snap.strictBase
              , baseCurrent = snap.baseCurrent
              }
      let announcing = dumpObject req
      Right (route outs [emit "ready.snap" [snap {announcing = announcing} :: Snapshot], emit "ready.announce_req" [req]])

showT :: Integer -> Text
showT = T.pack . show

-- | A1.4: only global facts (incarnation 0) or current facts apply.
current :: Snapshot -> Integer -> Bool
current snap incarnation = incarnation == 0 || incarnation == snap.incarnation

-- | Fold a lifecycle fact: a stale incarnation leaves the snapshot alone;
-- a newer one resets the per-incarnation decisions first.
applyState :: Snapshot -> StateFact -> Maybe Snapshot
applyState snap0 fact
  | fact.incarnation < snap0.incarnation = Nothing
  | otherwise =
      Just
        ( snap
            { phase = spelling body.phase
            , head = body.head
            , base = body.base
            , mergeable = body.mergeable
            , policy = body.policy
            , strictBase = body.strictBase
            , baseCurrent = body.baseCurrent
            }
            :: Snapshot
        )
  where
    body = fact.body
    snap
      | fact.incarnation /= snap0.incarnation =
          snap0 {incarnation = fact.incarnation, checks = "pending", review = ReviewPending, findingsBlocking = 0, pending = []}
            :: Snapshot
      | otherwise = snap0

-- | A fact's update applies only when the fact is global or current.
applyWhenCurrent :: Snapshot -> Integer -> (Snapshot -> Snapshot) -> Maybe Snapshot
applyWhenCurrent snap incarnation change = change snap <$ guard (current snap incarnation)

applyChecks :: Snapshot -> ChecksFact -> Maybe Snapshot
applyChecks snap fact = applyWhenCurrent snap fact.incarnation (\s -> s {checks = spelling fact.body.status} :: Snapshot)

reviewStatus :: ReviewFactBody -> ReviewStatus
reviewStatus = \case
  BodyReviewStatus body -> body.status
  BodyReviewUnable _ -> ReviewUnable

applyReview :: Snapshot -> ReviewFact -> Maybe Snapshot
applyReview snap fact = applyWhenCurrent snap fact.incarnation (\s -> s {review = reviewStatus fact.body} :: Snapshot)

applyFindings :: Snapshot -> FindingsFact -> Maybe Snapshot
applyFindings snap fact = applyWhenCurrent snap fact.incarnation (\s -> s {findingsBlocking = fact.body.blocking} :: Snapshot)

applyHuman :: Snapshot -> HumanFact -> Maybe Snapshot
applyHuman snap fact =
  applyWhenCurrent
    snap
    fact.incarnation
    (\s -> s {approval = fact.body.approval, changesRequested = fact.body.changesRequested, unresolved = fact.body.unresolved} :: Snapshot)

applyMutationPending :: Snapshot -> MutationPendingFact -> Maybe Snapshot
applyMutationPending snap fact =
  applyWhenCurrent snap fact.incarnation (\s -> s {pending = snap.pending ++ [fact.body.opKey]} :: Snapshot)

applyMutationSettled :: Snapshot -> MutationSettledFact -> Maybe Snapshot
applyMutationSettled snap fact =
  applyWhenCurrent snap fact.incarnation (\s -> s {pending = filter (/= fact.body.opKey) snap.pending} :: Snapshot)

raisedKey :: FaultRaisedFactBody -> (Text, Text)
raisedKey = \case
  BodyPublicationFault body -> ("review:" <> body.op, body.reason)
  BodyOperationFault body -> (spelling body.where_ <> ":" <> body.op, body.reason)

applyFaultRaised :: Snapshot -> FaultRaisedFact -> Maybe Snapshot
applyFaultRaised snap fact =
  let (key, reason) = raisedKey fact.body
   in Just (snap {faults = insert key (String reason) snap.faults} :: Snapshot)

applyFaultCleared :: Snapshot -> FaultClearedFact -> Maybe Snapshot
applyFaultCleared snap fact =
  let key = spelling fact.body.where_ <> ":" <> fact.body.op
   in Just (snap {faults = without key snap.faults} :: Snapshot)

foldWith :: forall (f :: Type). (Typeable f) => (Snapshot -> f -> Maybe Snapshot) -> Fold
foldWith apply b outs = do
  (fact, snap) <- values2 @f @Snapshot b
  case apply snap fact of
    Nothing -> Right (route outs [emit "ready.snap" [snap]])
    Just updated -> route outs <$> announceOpen updated

foldState, foldChecks, foldReview, foldFindings, foldHuman :: Fold
foldState = foldWith applyState
foldChecks = foldWith applyChecks
foldReview = foldWith applyReview
foldFindings = foldWith applyFindings
foldHuman = foldWith applyHuman

foldMutationPending, foldMutationSettled, foldFaultRaised, foldFaultCleared :: Fold
foldMutationPending = foldWith applyMutationPending
foldMutationSettled = foldWith applyMutationSettled
foldFaultRaised = foldWith applyFaultRaised
foldFaultCleared = foldWith applyFaultCleared

-- | Convert one pre-specialization envelope without deciding its kind.
migrateLegacy :: forall (f :: Type). (Contract f) => Text -> Fold
migrateLegacy mailbox b outs = do
  fact <- values1 @GateFact b
  revived <- revive @f (dump fact)
  Right (route outs [emit mailbox [revived]])

migrateState, migrateChecks, migrateReview, migrateFindings, migrateHuman :: Fold
migrateState = migrateLegacy @StateFact "ready.state_facts"
migrateChecks = migrateLegacy @ChecksFact "ready.checks_facts"
migrateReview = migrateLegacy @ReviewFact "ready.review_facts"
migrateFindings = migrateLegacy @FindingsFact "ready.findings_facts"
migrateHuman = migrateLegacy @HumanFact "ready.human_facts"

migrateMutationPending, migrateMutationSettled, migrateFaultRaised, migrateFaultCleared :: Fold
migrateMutationPending = migrateLegacy @MutationPendingFact "ready.mutation_pending_facts"
migrateMutationSettled = migrateLegacy @MutationSettledFact "ready.mutation_settled_facts"
migrateFaultRaised = migrateLegacy @FaultRaisedFact "ready.fault_raised_facts"
migrateFaultCleared = migrateLegacy @FaultClearedFact "ready.fault_cleared_facts"

ended :: Snapshot -> ReadyEnded
ended snap = ReadyEnded {announced = snap.announced, faults = snap.faults, reason = fromMaybe "" snap.closing}

-- | After an announce terminal folds: finish a deferred close (A3),
-- otherwise re-evaluate the current snapshot.
settle :: Snapshot -> [Emit] -> Py [Emit]
settle snap extra = case snap.closing of
  Just _ -> Right (extra ++ [emit "ready.done" [ended snap]])
  Nothing -> (extra ++) <$> announceOpen snap

foldALanded :: Fold
foldALanded b outs = do
  (out, snap0) <- values2 @ALanded @Snapshot b
  let snap = snap0 {announced = snap0.announced ++ [out.incarnation], announcing = []} :: Snapshot
  let fact = GateFact {kind = "announced", incarnation = out.incarnation, body = [("head", String out.head)]}
  route outs <$> settle snap [emit "dash.facts" [fact]]

requestOfDeferred :: ADeferred -> AnnounceReq
requestOfDeferred value =
  AnnounceReq
    { op = value.op
    , incarnation = value.incarnation
    , head = value.head
    , base = value.base
    , policy = value.policy
    , strictBase = value.strictBase
    , baseCurrent = value.baseCurrent
    }

foldADeferred :: Fold
foldADeferred b outs = do
  (out, snap) <- values2 @ADeferred @Snapshot b
  if Object snap.announcing /= dump (requestOfDeferred out)
    then Left (valueError "V5 deferred announcement differs from its in-flight request")
    else Right (route outs [emit "ready.snap" [snap], emit "ready.deferred" [out]])

wakeDeferred :: Fold
wakeDeferred b outs = do
  (deferred, wake, snap0) <- values3 @ADeferred @AWake @Snapshot b
  if dump deferred /= dump wake || Object snap0.announcing /= dump (requestOfDeferred deferred)
    then Left (valueError "V5 announcement wake differs from its deferred request")
    else do
      let snap = snap0 {announcing = []} :: Snapshot
      if not (announceViable snap)
        then route outs <$> settle snap []
        else do
          let req = requestOfDeferred deferred
          let announcing = dumpObject req
          Right (route outs [emit "ready.snap" [snap {announcing = announcing} :: Snapshot], emit "ready.announce_req" [req]])

foldABlocked :: Fold
foldABlocked b outs = do
  (_, snap0) <- values2 @ABlocked @Snapshot b
  let snap = snap0 {announcing = [], blocked = snap0.announcing} :: Snapshot
  case snap.closing of
    Just _ -> Right (route outs [emit "ready.done" [ended snap]])
    Nothing -> Right (route outs [emit "ready.snap" [snap]])

foldAMoved :: Fold
foldAMoved b outs = do
  (out, snap0) <- values2 @AMoved @Snapshot b
  let snap = snap0 {announcing = []} :: Snapshot
  case snap.closing of
    Just _ -> Right (route outs [emit "ready.done" [ended snap]])
    Nothing
      | (snap.head, snap.base, snap.policy, snap.incarnation, snap.phase)
          == (out.observedHead, out.observedBase, out.observedPolicy, out.observedIncarnation, out.observedPhase) ->
          route outs <$> announceOpen snap
      | otherwise -> Right (route outs [emit "ready.snap" [snap]])

foldAFault :: Fold
foldAFault b outs = do
  (out, snap0) <- values2 @AFault @Snapshot b
  let snap = snap0 {announcing = [], faults = insert ("announce:" <> out.op) (String out.reason) snap0.faults} :: Snapshot
      fact =
        GateFact
          { kind = "fault"
          , incarnation = 0
          , body =
              [ ("where", String "announce")
              , ("op", String out.op)
              , ("status", String "faulted")
              , ("reason", String out.reason)
              ]
          }
  route outs <$> settle snap [emit "dash.facts" [fact]]

recover :: Fold
recover b outs = do
  (fact, snap0) <- values2 @RecoverFact @Snapshot b
  if fact.target /= "readiness"
    || null snap0.blocked
    || Just (String fact.op) /= lookup "op" snap0.blocked
    || snap0.closing /= Nothing
    then Right (route outs [emit "ready.snap" [snap0]])
    else do
      req <- revive @AnnounceReq (Object snap0.blocked)
      let snap = snap0 {announcing = snap0.blocked, blocked = []} :: Snapshot
      Right (route outs [emit "ready.snap" [snap], emit "ready.announce_req" [req]])

end :: Fold
end b outs = do
  (close, snap0) <- values2 @CloseFact @Snapshot b
  let snap = snap0 {closing = Just close.reason} :: Snapshot
  if not (null snap.announcing)
    then Right (route outs [emit "ready.snap" [snap]])
    else Right (route outs [emit "ready.done" [ended snap]])

drainOf :: forall (f :: Type). (Typeable f) => Fold
drainOf b outs = do
  (_, done) <- values2 @f @ReadyEnded b
  Right (route outs [emit "ready.done" [done]])

drainState, drainChecks, drainReview, drainFindings, drainHuman :: Fold
drainState = drainOf @StateFact
drainChecks = drainOf @ChecksFact
drainReview = drainOf @ReviewFact
drainFindings = drainOf @FindingsFact
drainHuman = drainOf @HumanFact

drainMutationPending, drainMutationSettled, drainFaultRaised, drainFaultCleared :: Fold
drainMutationPending = drainOf @MutationPendingFact
drainMutationSettled = drainOf @MutationSettledFact
drainFaultRaised = drainOf @FaultRaisedFact
drainFaultCleared = drainOf @FaultClearedFact

drainRecover, drainCandidate, drainWake :: Fold
drainRecover = drainOf @RecoverFact
drainCandidate = drainOf @AnnounceCandidate
drainWake = drainOf @AWake

-- -- topology ------------------------------------------------------------

declare :: Author s ()
declare = do
  -- Input-only compatibility place: interrupted histories created before
  -- the typed-mailbox promotion may retain a token at this exact path.
  place "ready.facts" "GateFact"
  place "ready.state_facts" "StateFact"
  place "ready.checks_facts" "ChecksFact"
  place "ready.review_facts" "ReviewFact"
  place "ready.findings_facts" "FindingsFact"
  place "ready.human_facts" "HumanFact"
  place "ready.mutation_pending_facts" "MutationPendingFact"
  place "ready.mutation_settled_facts" "MutationSettledFact"
  place "ready.fault_raised_facts" "FaultRaisedFact"
  place "ready.fault_cleared_facts" "FaultClearedFact"
  place "ready.closed" "CloseFact"
  place "ready.recover" "RecoverFact"
  place "ready.wakes" "AWake"
  place "ready.snap" "Snapshot"
  place "ready.candidate" "AnnounceCandidate"
  place "ready.announce_req" "AnnounceReq"
  place "ready.alanded" "ALanded"
  place "ready.adeferred" "ADeferred"
  place "ready.deferred" "ADeferred"
  place "ready.ablocked" "ABlocked"
  place "ready.amoved" "AMoved"
  place "ready.afault" "AFault"
  place "ready.done" "ReadyEnded"

legacyState, legacyFaultCleared :: Text
legacyState = "kind == \"state\""
legacyFaultCleared =
  "kind == \"fault\" && has(body.status) && (body.status == \"resolved\" || body.status == \"cancelled\")"

-- | @ready.p.facts >> arc(filter=Cel(...)) >> ready.t.<name>(...) >> mailbox@.
migration :: Text -> Text -> Fold -> Text -> Text -> Author s ()
migration path name implementation expression mailbox = do
  source <- p "ready.facts"
  node <- t path >>= configure [handler (foldHandler name implementation)]
  target <- p mailbox
  void (source ~> arc {arcFilter = Just (celFilter expression)} ~> node ~> target)

factMailboxes :: [Text]
factMailboxes =
  [ "ready.facts"
  , "ready.state_facts"
  , "ready.checks_facts"
  , "ready.review_facts"
  , "ready.findings_facts"
  , "ready.human_facts"
  , "ready.mutation_pending_facts"
  , "ready.mutation_settled_facts"
  , "ready.fault_raised_facts"
  , "ready.fault_cleared_facts"
  ]

wire :: Author s ()
wire = do
  door "on_announce_wake" "ready.wakes"
  migration "ready.migrate_state" "_migrate_state" migrateState legacyState "ready.state_facts"
  migration "ready.migrate_checks" "_migrate_checks" migrateChecks "kind == \"checks\"" "ready.checks_facts"
  migration "ready.migrate_review" "_migrate_review" migrateReview "kind == \"review\"" "ready.review_facts"
  migration "ready.migrate_findings" "_migrate_findings" migrateFindings "kind == \"findings\"" "ready.findings_facts"
  migration "ready.migrate_human" "_migrate_human" migrateHuman "kind == \"human\"" "ready.human_facts"
  migration
    "ready.migrate_mutation_pending"
    "_migrate_mutation_pending"
    migrateMutationPending
    "kind == \"mutation_pending\""
    "ready.mutation_pending_facts"
  migration
    "ready.migrate_mutation_settled"
    "_migrate_mutation_settled"
    migrateMutationSettled
    "kind == \"mutation_settled\""
    "ready.mutation_settled_facts"
  migration
    "ready.migrate_fault_raised"
    "_migrate_fault_raised"
    migrateFaultRaised
    "kind == \"fault\" && (!has(body.status) || body.status == \"faulted\")"
    "ready.fault_raised_facts"
  migration
    "ready.migrate_fault_cleared"
    "_migrate_fault_cleared"
    migrateFaultCleared
    legacyFaultCleared
    "ready.fault_cleared_facts"
  forM_
    [ "ready.migrate_checks"
    , "ready.migrate_review"
    , "ready.migrate_findings"
    , "ready.migrate_human"
    , "ready.migrate_mutation_pending"
    , "ready.migrate_mutation_settled"
    ]
    (inhibitFiltered "ready.facts" legacyState)
  inhibitFiltered "ready.facts" "kind == \"mutation_pending\"" "ready.migrate_mutation_settled"
  inhibitFiltered "ready.facts" legacyFaultCleared "ready.migrate_fault_raised"
  let snapFold path name implementation mailbox =
        fold path name implementation [mailbox, "ready.snap"] ["ready.snap", "ready.candidate"]
  snapFold "ready.fold_state" "_fold_state" foldState "ready.state_facts"
  snapFold "ready.fold_checks" "_fold_checks" foldChecks "ready.checks_facts"
  snapFold "ready.fold_review" "_fold_review" foldReview "ready.review_facts"
  snapFold "ready.fold_findings" "_fold_findings" foldFindings "ready.findings_facts"
  snapFold "ready.fold_human" "_fold_human" foldHuman "ready.human_facts"
  snapFold "ready.fold_mutation_pending" "_fold_mutation_pending" foldMutationPending "ready.mutation_pending_facts"
  snapFold "ready.fold_mutation_settled" "_fold_mutation_settled" foldMutationSettled "ready.mutation_settled_facts"
  snapFold "ready.fold_fault_raised" "_fold_fault_raised" foldFaultRaised "ready.fault_raised_facts"
  snapFold "ready.fold_fault_cleared" "_fold_fault_cleared" foldFaultCleared "ready.fault_cleared_facts"
  -- Authority facts fold before incarnation-scoped evidence.
  forM_
    [ "ready.fold_checks"
    , "ready.fold_review"
    , "ready.fold_findings"
    , "ready.fold_human"
    , "ready.fold_mutation_pending"
    , "ready.fold_mutation_settled"
    ]
    (inhibit "ready.state_facts")
  inhibit "ready.mutation_pending_facts" "ready.fold_mutation_settled"
  inhibit "ready.fault_cleared_facts" "ready.fold_fault_raised"
  fold "ready.authorize" "_authorize" authorize ["ready.candidate", "ready.snap"] ["ready.snap", "ready.announce_req"]
  forM_ factMailboxes (`inhibit` "ready.authorize")
  inhibit "ready.closed" "ready.authorize"
  gate
    "ready.gate"
    "announce_gate"
    ["ready.announce_req"]
    ["ready.alanded", "ready.adeferred", "ready.ablocked", "ready.amoved", "ready.afault"]
  fold "ready.fold_adeferred" "_fold_adeferred" foldADeferred ["ready.adeferred", "ready.snap"] ["ready.deferred", "ready.snap"]
  fold
    "ready.wake_deferred"
    "_wake_deferred"
    wakeDeferred
    ["ready.deferred", "ready.wakes", "ready.snap"]
    ["ready.snap", "ready.done", "ready.announce_req"]
  forM_ factMailboxes (`inhibit` "ready.wake_deferred")
  inhibit "ready.closed" "ready.wake_deferred"
  fold
    "ready.fold_alanded"
    "_fold_alanded"
    foldALanded
    ["ready.alanded", "ready.snap"]
    ["ready.snap", "dash.facts", "ready.done", "ready.candidate"]
  fold "ready.fold_ablocked" "_fold_ablocked" foldABlocked ["ready.ablocked", "ready.snap"] ["ready.snap", "ready.done"]
  fold
    "ready.fold_amoved"
    "_fold_amoved"
    foldAMoved
    ["ready.amoved", "ready.snap"]
    ["ready.snap", "ready.done", "ready.candidate"]
  fold
    "ready.fold_afault"
    "_fold_afault"
    foldAFault
    ["ready.afault", "ready.snap"]
    ["ready.snap", "dash.facts", "ready.done", "ready.candidate"]
  fold "ready.recovery" "_recover" recover ["ready.recover", "ready.snap"] ["ready.snap", "ready.announce_req"]
  fold "ready.end" "_end" end ["ready.closed", "ready.snap"] ["ready.snap", "ready.done"]
  let drain path name implementation mailbox = fold path name implementation [mailbox, "ready.done"] ["ready.done"]
  drain "ready.drain_state" "_drain_state" drainState "ready.state_facts"
  drain "ready.drain_checks" "_drain_checks" drainChecks "ready.checks_facts"
  drain "ready.drain_review" "_drain_review" drainReview "ready.review_facts"
  drain "ready.drain_findings" "_drain_findings" drainFindings "ready.findings_facts"
  drain "ready.drain_human" "_drain_human" drainHuman "ready.human_facts"
  drain "ready.drain_mutation_pending" "_drain_mutation_pending" drainMutationPending "ready.mutation_pending_facts"
  drain "ready.drain_mutation_settled" "_drain_mutation_settled" drainMutationSettled "ready.mutation_settled_facts"
  drain "ready.drain_fault_raised" "_drain_fault_raised" drainFaultRaised "ready.fault_raised_facts"
  drain "ready.drain_fault_cleared" "_drain_fault_cleared" drainFaultCleared "ready.fault_cleared_facts"
  drain "ready.drain_recover" "_drain_recover" drainRecover "ready.recover"
  drain "ready.drain_candidate" "_drain_candidate" drainCandidate "ready.candidate"
  drain "ready.drain_wake" "_drain_wake" drainWake "ready.wakes"

seed :: [(NetPath, [Token])]
seed =
  [ ( "ready.snap"
    , [ seedToken
          Snapshot
            { incarnation = 0
            , phase = ""
            , head = ""
            , base = ""
            , policy = ""
            , mergeable = False
            , checks = "pending"
            , review = ReviewPending
            , findingsBlocking = 0
            , approval = False
            , changesRequested = False
            , unresolved = 0
            , pending = []
            , faults = []
            , announced = []
            , candidate = False
            , announcing = []
            , blocked = []
            , strictBase = True
            , baseCurrent = False
            , closing = Nothing
            }
      ]
    )
  ]
