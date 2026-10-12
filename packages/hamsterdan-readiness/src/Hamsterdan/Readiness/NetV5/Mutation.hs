-- | The mutation loop: every write to the branch goes through one baton
-- (@net_v5/mutation.py@).
--
-- Owns the MutState baton — the baton IS the one-at-a-time
-- serialization: @start@ consumes it into the round and only a terminal
-- fold returns it. A faulted round is FAIL-CLOSED until the human
-- recovers or the PR closes.
module Hamsterdan.Readiness.NetV5.Mutation
  ( gates
  , declare
  , wire
  , seed
  , idle
  , start
  , foldPushed
  , foldMoved
  , foldDeclined
  , foldFault
  , recover
  , end
  , drain
  , drainRecover
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Contracts.Codec (dump)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.Readiness.NetV5.Folding
import Hamsterdan.Readiness.NetV5.Py (spelling)
import Hamsterdan.Readiness.NetV5.Wiring
import Petrus.Impetus.Dsl (Author)
import Petrus.Impetus.Petrinet (NetPath, Token)

gates :: [(Text, (Text, [Text]))]
gates = [("mut.git_gate", ("git_gate", ["Pushed", "MovedM", "FaultM", "DeclinedM"]))]

idle :: MutState
idle =
  MutState
    { state = MutIdle
    , opKey = ""
    , op = ""
    , head = ""
    , base = ""
    , policy = ""
    , incarnation = 0
    , reason = ""
    , kind = ""
    , instruction = ""
    , runId = 0
    , attempt = 0
    }

-- | The escalation budget key for a repair op ('' for human ops).
budgetKey :: Text -> Text
budgetKey op = maybe "" id (T.stripPrefix "repair:" op)

-- | The budget lineage a pushed head inherits when confirmed.
lineageOf :: Text -> Text
lineageOf op = case budgetKey op of
  "" -> ""
  key -> fst (T.breakOn ":" key)

-- | The round's stable operation identity, from the REQUEST identity.
opKeyOf :: MutationRequest -> Text
opKeyOf req = "push:" <> req.rid <> ":" <> req.head <> ":i" <> T.pack (show req.incarnation)

settledOf :: Text -> Text -> SettledOutcome -> Integer -> MutationSettled
settledOf op opKey outcome incarnation =
  MutationSettled {op = op, opKey = opKey, outcome = outcome, incarnation = incarnation, fingerprint = budgetKey op}

settledFact :: MutationSettled -> MutationSettledFact
settledFact settled = MutationSettledFact {incarnation = settled.incarnation, body = settled}

settlement :: MutationSettled -> [Emit]
settlement settled =
  [emit "esc.settled" [settled], emit "ready.mutation_settled_facts" [fact], emit "dash.facts" [fact]]
  where
    fact = settledFact settled

start :: Fold
start b outs = do
  (req, st) <- values2 @MutationRequest @MutState b
  if st.state == MutFaulted
    then Right (route outs (emit "mut.state" [st] : settlement (settledOf req.op (opKeyOf req) OutcomeDeclined req.incarnation)))
    else do
      let work =
            MutWork
              { op = req.op
              , opKey = opKeyOf req
              , head = req.head
              , base = req.base
              , policy = req.policy
              , incarnation = req.incarnation
              , lineage = lineageOf req.op
              , kind = spelling req.kind
              , instruction = req.instruction
              , runId = req.runId
              , attempt = req.attempt
              }
          fact = MutationPendingFact {incarnation = req.incarnation, body = MutationPendingFactBody {op = req.op, opKey = work.opKey}}
      Right (route outs [emit "mut.work" [work], emit "ready.mutation_pending_facts" [fact], emit "dash.facts" [fact]])

foldPushed :: Fold
foldPushed b outs = do
  out <- values1 @Pushed b
  let note = ProvisionalHead {expected = out.newHead, fromHead = out.head, op = out.op, lineage = out.lineage}
  Right
    ( route
        outs
        (emit "mut.state" [idle] : emit "life.provisional" [note] : settlement (settledOf out.op out.opKey OutcomeLanded out.incarnation))
    )

foldMoved :: Fold
foldMoved b outs = do
  out <- values1 @MovedM b
  Right (route outs (emit "mut.state" [idle] : settlement (settledOf out.op out.opKey OutcomeMoved out.incarnation)))

foldDeclined :: Fold
foldDeclined b outs = do
  out <- values1 @DeclinedM b
  Right (route outs (emit "mut.state" [idle] : settlement (settledOf out.op out.opKey OutcomeDeclined out.incarnation)))

foldFault :: Fold
foldFault b outs = do
  out <- values1 @FaultM b
  let settled = settledOf out.op out.opKey OutcomeFaulted out.incarnation
      fact = FaultRaisedFact {body = BodyOperationFault OperationFaultBody {where_ = SiteMutation, op = out.opKey, reason = out.reason}}
      faulted =
        MutState
          { state = MutFaulted
          , opKey = out.opKey
          , op = out.op
          , head = out.head
          , base = out.base
          , policy = out.policy
          , incarnation = out.incarnation
          , reason = out.reason
          , kind = out.kind
          , instruction = out.instruction
          , runId = out.runId
          , attempt = out.attempt
          }
  Right
    ( route
        outs
        [ emit "mut.state" [faulted]
        , emit "esc.settled" [settled]
        , emit "ready.fault_raised_facts" [fact]
        , emit "dash.facts" [fact]
        ]
    )

recover :: Fold
recover b outs = do
  (fact, st) <- values2 @RecoverFact @MutState b
  if fact.target /= "mutation" || st.state /= MutFaulted || fact.op /= st.opKey
    then Right (route outs [emit "mut.state" [st]])
    else do
      let work =
            MutWork
              { op = st.op
              , opKey = st.opKey
              , head = st.head
              , base = st.base
              , policy = st.policy
              , incarnation = st.incarnation
              , lineage = lineageOf st.op
              , kind = st.kind
              , instruction = st.instruction
              , runId = st.runId
              , attempt = st.attempt
              }
          pending = MutationPendingFact {incarnation = st.incarnation, body = MutationPendingFactBody {op = st.op, opKey = st.opKey}}
          resolved = FaultClearedFact {body = FaultClearedFactBody {where_ = FaultMutation, op = st.opKey, status = FaultResolved}}
      Right
        ( route
            outs
            [ emit "mut.work" [work]
            , emit "ready.mutation_pending_facts" [pending]
            , emit "ready.fault_cleared_facts" [resolved]
            , ("dash.facts", [dump pending, dump resolved])
            ]
        )

end :: Fold
end b outs = do
  (close, st) <- values2 @CloseFact @MutState b
  Right (route outs [emit "mut.done" [MutEnded {state = spelling st.state, reason = close.reason}]])

drainRecover :: Fold
drainRecover b outs = do
  (_, ended) <- values2 @RecoverFact @MutEnded b
  Right (route outs [emit "mut.done" [ended]])

drain :: Fold
drain b outs = do
  (req, ended) <- values2 @MutationRequest @MutEnded b
  Right (route outs (emit "mut.done" [ended] : settlement (settledOf req.op (opKeyOf req) OutcomeDeclined req.incarnation)))

-- -- topology ------------------------------------------------------------

declare :: Author s ()
declare = do
  place "mut.requests" "MutationRequest"
  place "mut.closed" "CloseFact"
  place "mut.recover" "RecoverFact"
  place "mut.state" "MutState"
  place "mut.work" "MutWork"
  place "mut.pushed" "Pushed"
  place "mut.movedm" "MovedM"
  place "mut.faultm" "FaultM"
  place "mut.declinedm" "DeclinedM"
  place "mut.done" "MutEnded"

wire :: Author s ()
wire = do
  fold
    "mut.start"
    "_start"
    start
    ["mut.requests", "mut.state"]
    ["mut.state", "mut.work", "esc.settled", "ready.mutation_pending_facts", "ready.mutation_settled_facts", "dash.facts"]
  gate "mut.git_gate" "git_gate" ["mut.work"] ["mut.pushed", "mut.movedm", "mut.faultm", "mut.declinedm"]
  fold
    "mut.fold_pushed"
    "_fold_pushed"
    foldPushed
    ["mut.pushed"]
    ["mut.state", "life.provisional", "esc.settled", "ready.mutation_settled_facts", "dash.facts"]
  fold "mut.fold_moved" "_fold_moved" foldMoved ["mut.movedm"] ["mut.state", "esc.settled", "ready.mutation_settled_facts", "dash.facts"]
  fold "mut.fold_declined" "_fold_declined" foldDeclined ["mut.declinedm"] ["mut.state", "esc.settled", "ready.mutation_settled_facts", "dash.facts"]
  fold "mut.fold_fault" "_fold_fault" foldFault ["mut.faultm"] ["mut.state", "esc.settled", "ready.fault_raised_facts", "dash.facts"]
  fold
    "mut.recovery"
    "_recover"
    recover
    ["mut.recover", "mut.state"]
    ["mut.state", "mut.work", "ready.mutation_pending_facts", "ready.fault_cleared_facts", "dash.facts"]
  fold "mut.end" "_end" end ["mut.closed", "mut.state"] ["mut.done"]
  fold "mut.drain" "_drain" drain ["mut.requests", "mut.done"] ["mut.done", "esc.settled", "ready.mutation_settled_facts", "dash.facts"]
  fold "mut.drain_recover" "_drain_recover" drainRecover ["mut.recover", "mut.done"] ["mut.done"]

seed :: [(NetPath, [Token])]
seed = [("mut.state", [seedToken idle])]
