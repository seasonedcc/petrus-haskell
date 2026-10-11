{-# LANGUAGE AllowAmbiguousTypes #-}

-- | The reminders actor loop and its durable Net↔host timer protocol
-- (@net_v5/reminders.py@).
--
-- Lifecycle mail changes the desired clock. The loop serializes that
-- intent through one persistent 'TimerCommand' token and does not consider
-- an arm or cancel settled until the host returns an identified
-- 'TimerCommandApplied'. Timer maturity is separately identified ingress.
-- Stale generations remain durable facts but can never authorize a nudge.
module Hamsterdan.Readiness.NetV5.Reminders
  ( gates
  , declare
  , wire
  , seed
  , cycle'
  , pause
  , commandApplied
  , mature
  , snooze
  , foldLanded
  , foldBlocked
  , foldFault
  , recover
  , end
  , drainTimer
  , drainCycle
  , drainPause
  , drainSnooze
  , drainRecover
  , drainAck
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Kind (Type)
import Data.Typeable (Typeable)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.Readiness.NetV5.Folding
import Hamsterdan.Readiness.NetV5.Py
import Hamsterdan.Readiness.NetV5.Wiring
import Petrus.Impetus.Dsl (Author)
import Petrus.Impetus.Petrinet (NetPath, Token)
import Petrus.Json (Json (..))

gates :: [(Text, (Text, [Text]))]
gates = [("rem.gate", ("reminder_gate", ["RemLanded", "RemBlocked", "RemFault"]))]

showT :: Integer -> Text
showT = T.pack . show

timerFor :: RemState -> Integer -> Integer -> Text -> ReminderTimer
timerFor st incarnation seq_ h =
  ReminderTimer
    { id = "timer:" <> st.subject <> ":i" <> showT incarnation <> ":s" <> showT seq_
    , incarnation = incarnation
    , sequence = seq_
    , head = h
    }

operationFor :: RemState -> (Text, Integer)
operationFor st = ("timer-command:" <> st.subject <> ":g" <> showT generation, generation)
  where
    generation = st.commandGeneration + 1

issueArm :: RemState -> ReminderTimer -> (RemState, TimerCommand)
issueArm st timer =
  ( st {clock = ClockArming ArmingReminderClock {timer = timer, operation = operation}, commandGeneration = generation} :: RemState
  , TimerCommand {operation = operation, command = CommandArm ArmReminder {timer = timer, delayS = st.delayS}}
  )
  where
    (operation, generation) = operationFor st

issueCancel :: RemState -> ReminderTimer -> Text -> (RemState, TimerCommand)
issueCancel st timer reason =
  ( st {clock = ClockCancelling CancellingReminderClock {timer = timer, operation = operation, reason = reason}, commandGeneration = generation}
      :: RemState
  , TimerCommand {operation = operation, command = CommandCancel CancelReminder {timer = timer, reason = reason}}
  )
  where
    (operation, generation) = operationFor st

noClock :: ReminderClock
noClock = ClockNone NoReminderClock

isNoClock :: ReminderClock -> Bool
isNoClock = \case
  ClockNone _ -> True
  _ -> False

settle :: RemState -> [Emit] -> [Emit]
settle st extra = case st.closing of
  Just reason | null st.pending && isNoClock st.clock -> extra ++ [emit "rem.done" [RemEnded {matured = st.matured, reason = reason}]]
  _ -> extra ++ [emit "rem.state" [st]]

withCommand :: RemState -> TimerCommand -> [Emit]
withCommand st command = [emit "rem.state" [st], emit "rem.commands" [command]]

keep :: RemState -> [Emit]
keep st = [emit "rem.state" [st]]

cycle' :: Fold
cycle' b outs = do
  (fact, st0) <- values2 @ReminderCycleStarted @RemState b
  if st0.closing /= Nothing || fact.incarnation <= st0.lifecycleIncarnation
    then Right (route outs (keep st0))
    else do
      let desired = timerFor st0 fact.incarnation 0 fact.head
          st =
            st0
              { lifecycleIncarnation = fact.incarnation
              , lifecycleHead = fact.head
              , lifecycleActive = True
              , desiredTimer = Just desired
              , delayS = fact.delayS
              }
              :: RemState
      Right $ route outs $ case st.clock of
        ClockArming _ -> keep st
        ClockCancelling _ -> keep st
        ClockArmed armed | armed.timer == desired -> keep st
        _ -> uncurry withCommand (issueArm st desired)

pause :: Fold
pause b outs = do
  (fact, st0) <- values2 @ReminderCyclePaused @RemState b
  if fact.incarnation < st0.lifecycleIncarnation || (fact.incarnation == st0.lifecycleIncarnation && not st0.lifecycleActive)
    then Right (route outs (keep st0))
    else do
      let st =
            st0 {lifecycleIncarnation = fact.incarnation, lifecycleHead = fact.head, lifecycleActive = False, desiredTimer = Nothing}
              :: RemState
      Right $ route outs $ case st.clock of
        ClockArmed armed -> uncurry withCommand (issueCancel st armed.timer fact.reason)
        ClockOverdue _ -> settle st {clock = noClock} []
        _ -> settle st []

commandTimer :: ReminderCommand -> ReminderTimer
commandTimer = \case
  CommandArm c -> c.timer
  CommandCancel c -> c.timer

resultTimer :: TimerResult -> ReminderTimer
resultTimer = \case
  ResultArmed r -> r.timer
  ResultCancelled r -> r.timer

commandApplied :: Fold
commandApplied b outs = do
  (ack, issued, st0) <- values3 @TimerCommandApplied @TimerCommand @RemState b
  let expectedTimer = commandTimer issued.command
      redrain = Right (route outs [emit "rem.state" [st0], emit "rem.commands" [issued]])
  if ack.operation /= issued.operation || resultTimer ack.result /= expectedTimer
    then redrain
    else case (issued.command, ack.result) of
      (CommandArm _, ResultArmed armed) -> do
        let st = st0 {clock = ClockArmed ArmedReminderClock {timer = armed.timer, dueAt = armed.dueAt}} :: RemState
        Right . route outs $
          if st.desiredTimer == Just armed.timer && st.closing == Nothing
            then keep st
            else uncurry withCommand $ case st.desiredTimer of
              Nothing -> issueCancel st armed.timer (maybe "draft" id st.closing)
              Just desired -> issueArm st desired
      (CommandCancel _, ResultCancelled _) -> do
        let st = st0 {clock = noClock} :: RemState
        Right . route outs $ case st.desiredTimer of
          Just desired | st.closing == Nothing -> uncurry withCommand (issueArm st desired)
          _ -> settle st []
      _ -> redrain

nextAfter :: RemState -> ReminderTimer -> (RemState, TimerCommand)
nextAfter st timer = issueArm st {desiredTimer = Just desired} desired
  where
    desired = timerFor st timer.incarnation (timer.sequence + 1) timer.head

requestNudge :: RemState -> Text -> (RemState, Maybe RemReq)
requestNudge st timerId
  | any (any ((== timerId) . fst)) [st.pending, st.blocked, st.faulted] = (st, Nothing)
  | otherwise = (st {pending = insert timerId (Bool True) st.pending} :: RemState, Just RemReq {timerId = timerId})

nudge :: RemState -> ReminderTimer -> [Emit]
nudge st0 timer = withCommand st command ++ [emit "rem.pub_req" [r] | Just r <- [request]]
  where
    (st1, request) = requestNudge st0 timer.id
    (st, command) = nextAfter st1 timer

mature :: Fold
mature b outs = do
  (due, st0) <- values2 @TimerDue @RemState b
  let st = st0 {matured = st0.matured ++ [due.timer.id]} :: RemState
      current = case st.clock of
        ClockArmed armed -> armed.timer == due.timer && armed.dueAt == due.dueAt && st.closing == Nothing
        _ -> False
      overdue = ClockOverdue OverdueReminderClock {timer = due.timer, dueAt = due.dueAt, maturedAt = due.maturedAt}
  Right . route outs $
    if not current
      then keep st
      else if st.snoozed then keep st {desiredTimer = Nothing, clock = overdue} else nudge st due.timer

snooze :: Fold
snooze b outs = do
  (fact, st0) <- values2 @SnoozeFact @RemState b
  Right . route outs $
    if fact.mode == ModeSnooze
      then keep st0 {snoozed = True}
      else
        let st = st0 {snoozed = False} :: RemState
         in case st.clock of
              ClockOverdue overdue | st.closing == Nothing -> nudge st overdue.timer
              _ -> keep st

foldLanded :: Fold
foldLanded b outs = do
  (out, st0) <- values2 @RemLanded @RemState b
  let st = st0 {pending = without out.timerId st0.pending, blocked = without out.timerId st0.blocked} :: RemState
      fact = GateFact {kind = "reminder", incarnation = 0, body = [("timer_id", String out.timerId)]}
  Right (route outs (settle st [emit "dash.facts" [fact]]))

foldBlocked :: Fold
foldBlocked b outs = do
  (out, st0) <- values2 @RemBlocked @RemState b
  Right (route outs (settle st0 {pending = without out.timerId st0.pending, blocked = insert out.timerId (Bool True) st0.blocked} []))

foldFault :: Fold
foldFault b outs = do
  (out, st0) <- values2 @RemFault @RemState b
  let st = st0 {pending = without out.timerId st0.pending, faulted = insert out.timerId (String out.reason) st0.faulted} :: RemState
      fact = GateFact {kind = "fault", incarnation = 0, body = [("where", String "reminder"), ("reason", String out.reason)]}
  Right (route outs (settle st [emit "dash.facts" [fact]]))

recover :: Fold
recover b outs = do
  (fact, st0) <- values2 @RecoverFact @RemState b
  case T.stripPrefix "reminder:" fact.op of
    Just timerId
      | fact.target == "reminder"
      , any ((== timerId) . fst) st0.blocked
      , st0.closing == Nothing -> do
          let st = st0 {pending = insert timerId (Bool True) st0.pending, blocked = without timerId st0.blocked} :: RemState
          Right (route outs [emit "rem.state" [st], emit "rem.pub_req" [RemReq {timerId = timerId}]])
    _ -> Right (route outs (keep st0))

end :: Fold
end b outs = do
  (close, st0) <- values2 @CloseFact @RemState b
  let st = st0 {closing = Just close.reason, desiredTimer = Nothing} :: RemState
  Right $ route outs $ case st.clock of
    ClockArmed armed -> uncurry withCommand (issueCancel st armed.timer close.reason)
    ClockOverdue _ -> settle st {clock = noClock} []
    _ -> settle st []

drainTimer :: Fold
drainTimer b outs = do
  (due, ended) <- values2 @TimerDue @RemEnded b
  Right (route outs [emit "rem.done" [ended {matured = ended.matured ++ [due.timer.id]} :: RemEnded]])

drainOf :: forall (a :: Type). (Typeable a) => Fold
drainOf b outs = do
  (_, ended) <- values2 @a @RemEnded b
  Right (route outs [emit "rem.done" [ended]])

drainCycle, drainPause, drainSnooze, drainRecover, drainAck :: Fold
drainCycle = drainOf @ReminderCycleStarted
drainPause = drainOf @ReminderCyclePaused
drainSnooze = drainOf @SnoozeFact
drainRecover = drainOf @RecoverFact
drainAck = drainOf @TimerCommandApplied

declare :: Author s ()
declare = do
  place "rem.cycles" "ReminderCycleStarted"
  place "rem.pauses" "ReminderCyclePaused"
  place "rem.timers" "TimerDue"
  place "rem.acks" "TimerCommandApplied"
  place "rem.commands" "TimerCommand"
  place "rem.snoozes" "SnoozeFact"
  place "rem.recover" "RecoverFact"
  place "rem.closed" "CloseFact"
  place "rem.state" "RemState"
  place "rem.pub_req" "RemReq"
  place "rem.rlanded" "RemLanded"
  place "rem.rblocked" "RemBlocked"
  place "rem.rfault" "RemFault"
  place "rem.done" "RemEnded"

wire :: Author s ()
wire = do
  door "on_timer" "rem.timers"
  door "on_timer_command_applied" "rem.acks"
  fold "rem.cycle" "_cycle" cycle' ["rem.cycles", "rem.state"] ["rem.state", "rem.commands"]
  fold "rem.pause" "_pause" pause ["rem.pauses", "rem.state"] ["rem.state", "rem.commands", "rem.done"]
  fold "rem.command_applied" "_command_applied" commandApplied ["rem.acks", "rem.commands", "rem.state"] ["rem.state", "rem.commands", "rem.done"]
  fold "rem.mature" "_mature" mature ["rem.timers", "rem.state"] ["rem.state", "rem.pub_req", "rem.commands"]
  fold "rem.snooze" "_snooze" snooze ["rem.snoozes", "rem.state"] ["rem.state", "rem.pub_req", "rem.commands"]
  gate "rem.gate" "reminder_gate" ["rem.pub_req"] ["rem.rlanded", "rem.rblocked", "rem.rfault"]
  fold "rem.fold_landed" "_fold_landed" foldLanded ["rem.rlanded", "rem.state"] ["rem.state", "dash.facts", "rem.done"]
  fold "rem.fold_blocked" "_fold_blocked" foldBlocked ["rem.rblocked", "rem.state"] ["rem.state", "rem.done"]
  fold "rem.fold_fault" "_fold_fault" foldFault ["rem.rfault", "rem.state"] ["rem.state", "dash.facts", "rem.done"]
  fold "rem.recovery" "_recover" recover ["rem.recover", "rem.state"] ["rem.state", "rem.pub_req"]
  fold "rem.end" "_end" end ["rem.closed", "rem.state"] ["rem.state", "rem.commands", "rem.done"]
  fold "rem.drain_timer" "_drain_timer" drainTimer ["rem.timers", "rem.done"] ["rem.done"]
  fold "rem.drain_cycle" "<lambda>" drainCycle ["rem.cycles", "rem.done"] ["rem.done"]
  fold "rem.drain_pause" "<lambda>" drainPause ["rem.pauses", "rem.done"] ["rem.done"]
  fold "rem.drain_snooze" "<lambda>" drainSnooze ["rem.snoozes", "rem.done"] ["rem.done"]
  fold "rem.drain_recover" "<lambda>" drainRecover ["rem.recover", "rem.done"] ["rem.done"]
  fold "rem.drain_ack" "<lambda>" drainAck ["rem.acks", "rem.done"] ["rem.done"]

seed :: Text -> [(NetPath, [Token])]
seed subject =
  [ ( "rem.state"
    , [ seedToken
          RemState
            { subject = subject
            , lifecycleIncarnation = 0
            , lifecycleHead = ""
            , lifecycleActive = False
            , desiredTimer = Nothing
            , clock = ClockNone NoReminderClock
            , commandGeneration = 0
            , delayS = 3 * 24 * 60 * 60
            , matured = []
            , snoozed = False
            , pending = []
            , blocked = []
            , faulted = []
            , closing = Nothing
            }
      ]
    )
  ]
