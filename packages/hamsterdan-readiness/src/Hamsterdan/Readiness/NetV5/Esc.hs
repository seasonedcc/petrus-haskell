-- | The escalation loop: the ladder — rerun once, then repair once, per
-- fingerprint PER LINEAGE, then surface for the human (@net_v5/esc.py@).
--
-- Owns the Ladder baton. A rerun round HOLDS the baton: @decide@ consumes
-- it into the RerunReq's @mem@ and the terminal folds recreate it. Moved
-- burns no budget and echoes a recheck to CI. A faulted rerun is
-- FAIL-CLOSED; the recovery door reissues the EXACT retained request.
module Hamsterdan.Readiness.NetV5.Esc
  ( gates
  , declare
  , wire
  , seed
  , decide
  , recover
  , foldRerunLanded
  , foldRerunMoved
  , foldRerunFault
  , foldSettled
  , end
  , drainRecover
  ) where

import Data.Text (Text)
import Hamsterdan.Contracts.Codec (Object, dump)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.Readiness.NetV5.Folding
import Hamsterdan.Readiness.NetV5.Py
import Hamsterdan.Readiness.NetV5.Wiring
import Petrus.Impetus.Dsl (Author)
import Petrus.Impetus.Petrinet (NetPath, Token)
import Petrus.Json (Json (..))

gates :: [(Text, (Text, [Text]))]
gates = [("esc.rerun_gate", ("rerun_gate", ["RerunLanded", "RerunMoved", "RerunFault"]))]

objectOf :: Json -> Object
objectOf = \case
  Object members -> members
  _ -> []

keepLadder :: Ladder -> [Emit]
keepLadder ladder = [emit "esc.ladder" [ladder]]

-- -- folds ---------------------------------------------------------------

decide :: Fold
decide b outs = do
  (failure, ladder) <- values2 @ChecksFailure @Ladder b
  case ladder.closing of
    Just _ -> Right (route outs (keepLadder ladder))
    Nothing -> do
      let fp = failure.fingerprint
          key = failure.lineage <> ":" <> fp
          evidence = [Int failure.runId, Int failure.attempt]
          rung = maybe Null id (lookup key ladder.reruns)
      if isNone rung
        then do
          let req =
                RerunReq
                  { fingerprint = key
                  , fp = fp
                  , op = "rerun:" <> key
                  , head = failure.head
                  , base = failure.base
                  , policy = failure.policy
                  , incarnation = failure.incarnation
                  , runId = failure.runId
                  , attempt = failure.attempt
                  , mem = objectOf (dump ladder)
                  }
          Right (route outs [emit "esc.rerun_req" [req]])
        else do
          rungState <- getItem rung "state"
          if rungState == String "fault"
            then do
              held <- maybe (Left (keyError key)) Right (lookup key ladder.rerunFaults)
              blocked <- get (Object held) "blocked"
              newer <-
                if isNone blocked
                  then Right True
                  else do
                    r <- getItem blocked "run_id"
                    a <- getItem blocked "attempt"
                    tupleCompare Gt evidence [r, a]
              ladder' <-
                if newer
                  then do
                    let retained = insert "blocked" (dump failure) held
                    vupdate ladder [("rerun_faults", Object (insert key (Object retained) [(k, Object v) | (k, v) <- ladder.rerunFaults]))]
                  else Right ladder
              let fact =
                    GateFact
                      { kind = "human_needed"
                      , incarnation = failure.incarnation
                      , body = [("fingerprint", String fp), ("head", String failure.head), ("why", String "rerun-fault")]
                      }
              Right (route outs [emit "esc.ladder" [ladder'], emit "dash.facts" [fact]])
            else do
              rr <- getItem rung "run_id"
              ra <- getItem rung "attempt"
              answered <- tupleCompare Le evidence [rr, ra]
              if answered
                then Right (route outs (keepLadder ladder))
                else do
                  let entry = maybe Null id (lookup key ladder.repairs)
                  if isNone entry
                    then do
                      let pending =
                            Object
                              [ ("state", String "pending")
                              , ("fp", String fp)
                              , ("head", String failure.head)
                              , ("base", String failure.base)
                              , ("policy", String failure.policy)
                              , ("incarnation", Int failure.incarnation)
                              , ("run_id", Int failure.runId)
                              , ("attempt", Int failure.attempt)
                              ]
                      held <- vupdate ladder [("repairs", Object (insert key pending ladder.repairs))]
                      let req =
                            MutationRequest
                              { op = "repair:" <> key
                              , rid = "repair:" <> key
                              , head = failure.head
                              , base = failure.base
                              , policy = failure.policy
                              , incarnation = failure.incarnation
                              , source = "escalation"
                              , kind = KindRepair
                              , instruction = ""
                              , runId = failure.runId
                              , attempt = failure.attempt
                              }
                      Right (route outs [emit "esc.ladder" [held], emit "mut.requests" [req]])
                    else do
                      entryState <- getItem entry "state"
                      if entryState == String "pending"
                        then Right (route outs (keepLadder ladder))
                        else do
                          er <- getItem entry "run_id"
                          ea <- getItem entry "attempt"
                          repaired <- tupleCompare Le evidence [er, ea]
                          if repaired
                            then Right (route outs (keepLadder ladder))
                            else do
                              let fact =
                                    GateFact
                                      { kind = "human_needed"
                                      , incarnation = failure.incarnation
                                      , body = [("fingerprint", String fp), ("head", String failure.head)]
                                      }
                              Right (route outs [emit "esc.ladder" [ladder], emit "dash.facts" [fact]])

-- | The recovery door (A2): a faulted RERUN is reissued as ONE fresh
-- occurrence under the SAME operation identity.
recover :: Fold
recover b outs = do
  (fact, ladder) <- values2 @RecoverFact @Ladder b
  let faults = ladder.rerunFaults
      findKey = \case
        [] -> Right Nothing
        (k, v) : rest -> do
          op <- getItem (Object v) "op"
          if op == String fact.op then Right (Just k) else findKey rest
  key <- findKey faults
  let inert = Right (route outs (keepLadder ladder))
  if ladder.closing /= Nothing || fact.target /= "esc"
    then inert
    else case key of
      Nothing -> inert
      Just k -> do
        rung <- getOr (Object ladder.reruns) k (Object [])
        st <- get rung "state"
        if st /= String "fault"
          then inert
          else do
            held <- maybe (Left (keyError k)) (Right . Object) (lookup k faults)
            cleared <- vupdate ladder [("reruns", Object (without k ladder.reruns))]
            args <- traverse (\name -> (name,) <$> getItem held name) ["fp", "op", "head", "base", "policy", "incarnation", "run_id", "attempt"]
            req <- construct @RerunReq (("fingerprint", String k) : args ++ [("mem", dump cleared)])
            Right (route outs [emit "esc.rerun_req" [req]])

resolvedRerun :: Json -> Py FaultClearedFact
resolvedRerun held = do
  op <- getItem held "op" >>= strictText
  Right FaultClearedFact {body = FaultClearedFactBody {where_ = FaultRerun, op = op, status = FaultResolved}}

foldRerunLanded :: Fold
foldRerunLanded b outs = do
  out <- values1 @RerunLanded b
  mem <- revive @Ladder (Object out.mem)
  let key = out.fingerprint
      held = lookup key mem.rerunFaults
      faults = without key mem.rerunFaults
  blocked <- maybe (Right Null) (\h -> get (Object h) "blocked") held
  watermark <-
    if out.disposition == DispositionRequested
      then do
        w1 <- pyMax2 [Int out.runId, Int out.attempt] [Int out.cutRunId, Int out.cutAttempt]
        if isNone blocked
          then Right w1
          else do
            r <- getItem blocked "run_id"
            a <- getItem blocked "attempt"
            pyMax2 w1 [r, a]
      else Right [Int out.runId, Int out.attempt]
  (w0, w1) <- case watermark of
    [x, y] -> Right (x, y)
    _ -> Left validationError
  let rung = Object [("state", String "done"), ("run_id", w0), ("attempt", w1)]
  ladder <-
    vupdate
      mem
      [ ("reruns", Object (insert key rung mem.reruns))
      , ("rerun_faults", Object [(k, Object v) | (k, v) <- faults])
      ]
  resolved <- case held of
    Nothing -> Right []
    Just h -> do
      fact <- resolvedRerun (Object h)
      Right [emit "ready.fault_cleared_facts" [fact], emit "dash.facts" [fact]]
  replay <-
    if not (isNone blocked) && out.disposition == DispositionExisting
      then do
        failure <- revive @ChecksFailure blocked
        Right [emit "esc.failures" [failure]]
      else Right []
  Right (route outs (emit "esc.ladder" [ladder] : resolved ++ replay))

foldRerunMoved :: Fold
foldRerunMoved b outs = do
  out <- values1 @RerunMoved b
  mem <- revive @Ladder (Object out.mem)
  let echo = EscMoved {fp = out.fp, head = out.head, base = out.base, policy = out.policy, incarnation = out.incarnation}
  case lookup out.fingerprint mem.rerunFaults of
    Nothing -> Right (route outs [emit "ci.echo" [echo], emit "esc.ladder" [mem]])
    Just h -> do
      mem' <- vupdate mem [("rerun_faults", Object [(k, Object v) | (k, v) <- without out.fingerprint mem.rerunFaults])]
      fact <- resolvedRerun (Object h)
      Right
        ( route
            outs
            [ emit "ci.echo" [echo]
            , emit "ready.fault_cleared_facts" [fact]
            , emit "dash.facts" [fact]
            , emit "esc.ladder" [mem']
            ]
        )

foldRerunFault :: Fold
foldRerunFault b outs = do
  out <- values1 @RerunFault b
  mem <- revive @Ladder (Object out.mem)
  blocked <- get (Object (maybe [] id (lookup out.fingerprint mem.rerunFaults))) "blocked"
  let retained =
        Object
          [ ("op", String out.op)
          , ("reason", String out.reason)
          , ("fp", String out.fp)
          , ("head", String out.head)
          , ("base", String out.base)
          , ("policy", String out.policy)
          , ("incarnation", Int out.incarnation)
          , ("run_id", Int out.runId)
          , ("attempt", Int out.attempt)
          , ("blocked", blocked)
          ]
  ladder <-
    vupdate
      mem
      [ ("reruns", Object (insert out.fingerprint (Object [("state", String "fault")]) mem.reruns))
      , ("rerun_faults", Object (insert out.fingerprint retained [(k, Object v) | (k, v) <- mem.rerunFaults]))
      ]
  let fact = FaultRaisedFact {body = BodyOperationFault OperationFaultBody {where_ = SiteRerun, op = out.op, reason = out.reason}}
  Right (route outs [emit "esc.ladder" [ladder], emit "ready.fault_raised_facts" [fact], emit "dash.facts" [fact]])

pendingRepairs :: Object -> Py Bool
pendingRepairs = \case
  [] -> Right False
  (_, entry) : rest -> do
    st <- getItem entry "state"
    if st == String "pending" then Right True else pendingRepairs rest

retire :: Ladder -> Object -> Text -> [Emit]
retire ladder repairs reason = [emit "esc.done" [LadderEnded {reruns = ladder.reruns, repairs = repairs, reason = reason}]]

-- | @ladder.closing is not None and not _pending_repairs(repairs)@: the
-- closing reason when the ladder retires now.
retiring :: Ladder -> Object -> Py (Maybe Text)
retiring ladder repairs = case ladder.closing of
  Nothing -> Right Nothing
  Just reason -> do
    pendingLeft <- pendingRepairs repairs
    Right (if pendingLeft then Nothing else Just reason)

drainRecover :: Fold
drainRecover b outs = do
  (_, ended) <- values2 @RecoverFact @LadderEnded b
  Right (route outs [emit "esc.done" [ended]])

foldSettled :: Fold
foldSettled b outs = do
  (settled, ladder) <- values2 @MutationSettled @Ladder b
  let key = settled.fingerprint
  case lookup key ladder.repairs of
    Just entry | key /= "", settled.op == "repair:" <> key -> do
      let stamped s = do
            merged <- merge entry [("state", String s)]
            Right (insert key merged ladder.repairs)
          finish repairs = do
            closing <- retiring ladder repairs
            case closing of
              Just reason -> Right (route outs (retire ladder repairs reason))
              Nothing -> do
                updated <- vupdate ladder [("repairs", Object repairs)]
                Right (route outs [emit "esc.ladder" [updated]])
      case settled.outcome of
        OutcomeLanded -> stamped "done" >>= finish
        OutcomeDeclined -> stamped "declined" >>= finish
        OutcomeMoved -> do
          let repairs = without key ladder.repairs
          closing <- retiring ladder repairs
          case closing of
            Just reason -> Right (route outs (retire ladder repairs reason))
            Nothing -> do
              args <- traverse (\name -> (name,) <$> getItem entry name) ["fp", "head", "base", "policy", "incarnation"]
              echo <- construct @EscMoved args
              updated <- vupdate ladder [("repairs", Object repairs)]
              Right (route outs [emit "esc.ladder" [updated], emit "ci.echo" [echo]])
        OutcomeFaulted -> stamped "fault" >>= finish
    _ -> Right (route outs (keepLadder ladder))

end :: Fold
end b outs = do
  (close, ladder) <- values2 @CloseFact @Ladder b
  pendingLeft <- pendingRepairs ladder.repairs
  if pendingLeft
    then do
      closing <- vupdate ladder [("closing", String close.reason)]
      Right (route outs (keepLadder closing))
    else
      Right (route outs [emit "esc.done" [LadderEnded {reruns = ladder.reruns, repairs = ladder.repairs, reason = close.reason}]])

-- -- topology ------------------------------------------------------------

declare :: Author s ()
declare = do
  place "esc.failures" "ChecksFailure"
  place "esc.closed" "CloseFact"
  place "esc.recover" "RecoverFact"
  place "esc.settled" "MutationSettled"
  place "esc.ladder" "Ladder"
  place "esc.rerun_req" "RerunReq"
  place "esc.rerun_landed" "RerunLanded"
  place "esc.rerun_moved" "RerunMoved"
  place "esc.rerun_fault" "RerunFault"
  place "esc.done" "LadderEnded"

wire :: Author s ()
wire = do
  fold "esc.decide" "_decide" decide ["esc.failures", "esc.ladder"] ["esc.ladder", "esc.rerun_req", "mut.requests", "dash.facts"]
  gate "esc.rerun_gate" "rerun_gate" ["esc.rerun_req"] ["esc.rerun_landed", "esc.rerun_moved", "esc.rerun_fault"]
  fold
    "esc.fold_rerun_landed"
    "_fold_rerun_landed"
    foldRerunLanded
    ["esc.rerun_landed"]
    ["esc.ladder", "esc.failures", "ready.fault_cleared_facts", "dash.facts"]
  fold
    "esc.fold_rerun_moved"
    "_fold_rerun_moved"
    foldRerunMoved
    ["esc.rerun_moved"]
    ["esc.ladder", "ci.echo", "ready.fault_cleared_facts", "dash.facts"]
  fold "esc.fold_rerun_fault" "_fold_rerun_fault" foldRerunFault ["esc.rerun_fault"] ["esc.ladder", "ready.fault_raised_facts", "dash.facts"]
  fold "esc.fold_settled" "_fold_settled" foldSettled ["esc.settled", "esc.ladder"] ["esc.ladder", "ci.echo", "esc.done"]
  fold "esc.recovery" "_recover" recover ["esc.recover", "esc.ladder"] ["esc.ladder", "esc.rerun_req"]
  fold "esc.end" "_end" end ["esc.closed", "esc.ladder"] ["esc.done", "esc.ladder"]
  fold "esc.drain_recover" "_drain_recover" drainRecover ["esc.recover", "esc.done"] ["esc.done"]

seed :: [(NetPath, [Token])]
seed = [("esc.ladder", [seedToken Ladder {reruns = [], repairs = [], rerunFaults = [], closing = Nothing}])]
