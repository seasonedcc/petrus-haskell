-- | @tests/unit/readiness/net_v5/test_reminders_loop.py@ (20 functions,
-- 20 cases; the mail-ordering tests loop over both delivery orders inside
-- one case, as upstream does): the reminders loop.
module RemindersSpec (spec) where

import Control.Monad (forM_, when)
import Data.Text (Text)
import Data.Text qualified as T
import Harness
import Petrus.Json (Json (..))
import Test.Hspec

state :: H -> IO Json
state h = one h "rem.state"

nudges :: H -> IO [Text]
nudges h = (\w -> [c.key | c <- w.comments, c.kind == "reminder"]) <$> worldOf h

command :: H -> IO Json
command h = one h "rem.commands"

textOf :: Json -> Text
textOf = \case
  String t -> t
  other -> error ("not text: " <> show other)

dueOf :: Json -> Json
dueOf clock =
  obj [("timer", clock `at` "timer"), ("due_at", clock `at` "due_at"), ("matured_at", str "2026-08-16T00:00:01Z")]

-- | Mature the current timer (arming it first when needed).
mature :: H -> IO (Text, Json)
mature h = do
  kind <- (`atPath` ["clock", "kind"]) <$> state h
  when (kind == str "none") (seeHead h "h1")
  kind' <- (`atPath` ["clock", "kind"]) <$> state h
  when (kind' == str "arming") (() <$ acknowledgeArm h)
  due <- dueOf . (`at` "clock") <$> state h
  matureWith h due

matureWith :: H -> Json -> IO (Text, Json)
matureWith h due = do
  deliver h "on_timer" "TimerDue" due
  pure (textOf (due `atPath` ["timer", "id"]), due)

matureHeld :: H -> [Text] -> IO (Text, Json)
matureHeld h held = do
  kind <- (`atPath` ["clock", "kind"]) <$> state h
  when (kind == str "none") $
    deliverHeld h held "on_head" "HeadSeen" (obj [("head", str "h1"), ("base", str "b1"), ("mergeable", Bool True), ("policy", str "p1")])
  issued <- command h
  deliverHeld
    h
    held
    "on_timer_command_applied"
    "TimerCommandApplied"
    ( obj
        [ ("operation", issued `at` "operation")
        , ("result", obj [("kind", str "armed"), ("timer", issued `atPath` ["command", "timer"]), ("due_at", str "2026-08-16T00:00:00Z")])
        ]
    )
  due <- dueOf . (`at` "clock") <$> state h
  matureHeldWith h held due

matureHeldWith :: H -> [Text] -> Json -> IO (Text, Json)
matureHeldWith h held due = do
  deliverHeld h held "on_timer" "TimerDue" due
  pure (textOf (due `atPath` ["timer", "id"]), due)

acknowledgeArm :: H -> IO Json
acknowledgeArm h = acknowledgeArmAt h "2026-08-16T00:00:00Z"

acknowledgeArmAt :: H -> Text -> IO Json
acknowledgeArmAt h dueAt = do
  issued <- command h
  issued `atPath` ["command", "kind"] `shouldBe` str "arm"
  deliver
    h
    "on_timer_command_applied"
    "TimerCommandApplied"
    ( obj
        [ ("operation", issued `at` "operation")
        , ("result", obj [("kind", str "armed"), ("timer", issued `atPath` ["command", "timer"]), ("due_at", str dueAt)])
        ]
    )
  pure (issued `atPath` ["command", "timer"])

acknowledgeCancel :: H -> IO Json
acknowledgeCancel h = do
  issued <- command h
  issued `atPath` ["command", "kind"] `shouldBe` str "cancel"
  deliver
    h
    "on_timer_command_applied"
    "TimerCommandApplied"
    (obj [("operation", issued `at` "operation"), ("result", obj [("kind", str "cancelled"), ("timer", issued `atPath` ["command", "timer"])])])
  pure (issued `atPath` ["command", "timer"])

acknowledgeHeld :: H -> IO Json
acknowledgeHeld h = do
  issued <- command h
  let kind = issued `atPath` ["command", "kind"]
      timer = issued `atPath` ["command", "timer"]
      result =
        if kind == str "arm"
          then obj [("kind", str "armed"), ("timer", timer), ("due_at", str "2026-08-17T00:00:00Z")]
          else obj [("kind", str "cancelled"), ("timer", timer)]
  deliverHeld h [] "on_timer_command_applied" "TimerCommandApplied" (obj [("operation", issued `at` "operation"), ("result", result)])
  pure kind

cycle' :: Integer -> Text -> (Text, Text, Json)
cycle' incarnation headSha =
  ("rem.cycles", "ReminderCycleStarted", obj [("incarnation", int incarnation), ("head", str headSha), ("delay_s", int 259200)])

pause :: Integer -> Text -> (Text, Text, Json)
pause incarnation headSha =
  ("rem.pauses", "ReminderCyclePaused", obj [("incarnation", int incarnation), ("head", str headSha), ("reason", str "draft")])

spawnMail :: [(Text, Text, Json)] -> IO H
spawnMail mail = do
  h <- spawnWith "pr-v5" freshWorld mail
  drive h
  pure h

endsWith :: Text -> Json -> Bool
endsWith suffix = \case
  String t -> suffix `T.isSuffixOf` t
  _ -> False

commentsMode :: Maybe Text -> H -> IO ()
commentsMode mode h = modifyWorld h (\w -> w {commentsMode = mode})

spec :: Spec
spec = describe "reminders loop" $ do
  describe "timer commands" $ do
    it "new cycle issues one globally scoped arm and waits for ack" $ do
      h <- spawnWith "owner/repo#42" freshWorld []
      seeHead h "h1"
      command h
        `shouldReturn` obj
          [ ("operation", str "timer-command:test:owner/repo#42:g1")
          , ( "command"
            , obj
                [ ("kind", str "arm")
                , ("timer", obj [("id", str "timer:test:owner/repo#42:i1:s0"), ("incarnation", int 1), ("sequence", int 0), ("head", str "h1")])
                , ("delay_s", int 259200)
                ]
            )
          ]
      ((`atPath` ["clock", "kind"]) <$> state h) `shouldReturn` str "arming"
      timer <- acknowledgeArm h
      tokens h "rem.commands" `shouldReturn` []
      ((`at` "clock") <$> state h) `shouldReturn` obj [("kind", str "armed"), ("timer", timer), ("due_at", str "2026-08-16T00:00:00Z")]

    it "draft during unacknowledged arm cancels only after arm ack" $ do
      h <- spawnWith "owner/repo#42" freshWorld []
      seeHead h "h1"
      arm <- command h
      deliver h "on_draft" "DraftSeen" (obj [])
      command h `shouldReturn` arm
      ((`at` "desired_timer") <$> state h) `shouldReturn` Null
      timer <- acknowledgeArm h
      cancel <- command h
      cancel `at` "operation" `shouldBe` str "timer-command:test:owner/repo#42:g2"
      cancel `at` "command" `shouldBe` obj [("kind", str "cancel"), ("timer", timer), ("reason", str "draft")]

    it "defer is finding disposition, not timer duration" $ do
      h <- spawn
      seeHead h "h1"
      commentWith h "c1" "defer" "finding-7" True
      oneAt h "review.memory" "dismissed" `shouldReturn` texts ["finding-7"]
      ((`atPath` ["command", "kind"]) <$> command h) `shouldReturn` str "arm"

  describe "lifecycle mail ordering" $ do
    it "pause dominates start at the same incarnation" $
      forM_ [[cycle' 1 "h1", pause 1 "h1"], [pause 1 "h1", cycle' 1 "h1"]] $ \mail -> do
        h <- spawnMail mail
        st <- state h
        st `at` "lifecycle_incarnation" `shouldBe` int 1
        st `at` "lifecycle_active" `shouldBe` Bool False
        st `at` "desired_timer" `shouldBe` Null

    it "newer resume dominates an older pause in either mail order" $
      forM_ [[cycle' 2 "h2", pause 1 "h1"], [pause 1 "h1", cycle' 2 "h2"]] $ \mail -> do
        h <- spawnMail mail
        st <- state h
        (st `at` "lifecycle_incarnation", st `at` "lifecycle_head", st `at` "lifecycle_active") `shouldBe` (int 2, str "h2", Bool True)
        endsWith ":i2:s0" (st `atPath` ["desired_timer", "id"]) `shouldBe` True

    it "newest start wins and old command ack reconciles to it" $ do
      h <- spawnMail [cycle' 1 "h1", cycle' 2 "h2"]
      (endsWith ":i2:s0" . (`atPath` ["desired_timer", "id"]) <$> state h) `shouldReturn` True
      first <- command h
      _ <- acknowledgeArm h
      if first `atPath` ["command", "timer", "incarnation"] == int 1
        then ((`atPath` ["command", "timer", "incarnation"]) <$> command h) `shouldReturn` int 2
        else tokens h "rem.commands" `shouldReturn` []
      reversed' <- spawnMail [cycle' 2 "h2", cycle' 1 "h1"]
      (endsWith ":i2:s0" . (`atPath` ["desired_timer", "id"]) <$> state reversed') `shouldReturn` True
      ((`atPath` ["command", "timer", "incarnation"]) <$> command reversed') `shouldReturn` int 2

  describe "maturity" $ do
    it "a matured timer nudges exactly once" $ do
      h <- spawn
      (timerId, _) <- mature h
      st <- state h
      st `at` "matured" `shouldBe` texts [timerId]
      st `at` "pending" `shouldBe` obj []
      nudges h `shouldReturn` ["reminder:" <> timerId]
      projection h >>= (`shouldContain` [("reminder", obj [("timer_id", str timerId)])])

    it "a repeated maturity reconciles lookup-first" $ do
      h <- spawn
      (timerId, due) <- mature h
      _ <- matureWith h due
      ((`at` "matured") <$> state h) `shouldReturn` texts [timerId, timerId]
      nudges h `shouldReturn` ["reminder:" <> timerId]

    it "pending custody is single-flight and the baton stays available" $ do
      h <- spawnHeld
      let held = ["reminder_gate"]
      (timerId, due) <- matureHeld h held
      ((`at` "pending") <$> state h) `shouldReturn` obj [(timerId, Bool True)]
      _ <- matureHeldWith h held due
      commentHeldWith h held "c1" "snooze" "t1" True
      st <- state h
      st `at` "matured" `shouldBe` texts [timerId, timerId]
      st `at` "snoozed" `shouldBe` Bool True
      (length <$> pendingWork h "reminder_gate") `shouldReturn` 1
      releaseOne h "reminder_gate"
      ((`at` "pending") <$> state h) `shouldReturn` obj []
      nudges h `shouldReturn` ["reminder:" <> timerId]

  describe "snooze" $ do
    it "snooze suppresses the decision, never the fact" $ do
      h <- spawn
      commentWith h "c1" "snooze" "all" True
      (timer1, _) <- mature h
      ((`at` "matured") <$> state h) `shouldReturn` texts [timer1]
      nudges h `shouldReturn` []
      commentWith h "c2" "resume" "all" True
      nudges h `shouldReturn` ["reminder:" <> timer1]
      (timer2, _) <- mature h
      nudges h `shouldReturn` ["reminder:" <> timer1, "reminder:" <> timer2]
      ((`at` "matured") <$> state h) `shouldReturn` texts [timer1, timer2]

    it "defer does not change the reminder clock" $ do
      h <- spawn
      seeHead h "h1"
      commandBefore <- command h
      commentWith h "c1" "defer" "f-h1" True
      command h `shouldReturn` commandBefore
      ((`at` "snoozed") <$> state h) `shouldReturn` Bool False

  describe "blocked and recovery" $ do
    it "retryable exhaustion blocks and recovers under the same identity" $ do
      h <- spawn
      commentsMode (Just "retryable") h
      (timerId, _) <- mature h
      st <- state h
      st `at` "blocked" `shouldBe` obj [(timerId, Bool True)]
      st `at` "pending" `shouldBe` obj []
      nudges h `shouldReturn` []
      commentsMode Nothing h
      commentWith h "c1" "recover_publication" ("reminder:" <> timerId) True
      st' <- state h
      st' `at` "blocked" `shouldBe` obj []
      st' `at` "pending" `shouldBe` obj []
      nudges h `shouldReturn` ["reminder:" <> timerId]

    it "unknown terminal faults and never reopens by maturity" $ do
      h <- spawn
      commentsMode (Just "unknown") h
      (timer1, due1) <- mature h
      st <- state h
      st `at` "faulted" `shouldBe` obj [(timer1, str "unknown")]
      st `at` "pending" `shouldBe` obj []
      projection h >>= (`shouldContain` [("fault", obj [("where", str "reminder"), ("reason", str "unknown")])])
      commentsMode Nothing h
      (timer2, _) <- mature h
      ((`at` "faulted") <$> state h) `shouldReturn` obj [(timer1, str "unknown")]
      nudges h `shouldReturn` ["reminder:" <> timer2]
      _ <- matureWith h due1
      nudges h `shouldReturn` ["reminder:" <> timer2]

    it "recovery requires the exact operation syntax" $ do
      h <- spawn
      commentsMode (Just "retryable") h
      (timerId, _) <- mature h
      ((`at` "blocked") <$> state h) `shouldReturn` obj [(timerId, Bool True)]
      commentsMode Nothing h
      commentWith h "c1" "recover_publication" "reminder" True
      ((`at` "blocked") <$> state h) `shouldReturn` obj [(timerId, Bool True)]
      nudges h `shouldReturn` []
      commentWith h "c2" "recover_publication" ("reminder:" <> timerId) True
      ((`at` "blocked") <$> state h) `shouldReturn` obj []
      nudges h `shouldReturn` ["reminder:" <> timerId]

    it "recovery of a faulted timer is a blocked-only door" $ do
      h <- spawn
      commentsMode (Just "unknown") h
      (timerId, _) <- mature h
      commentsMode Nothing h
      commentWith h "c1" "recover_publication" ("reminder:" <> timerId) True
      ((`at` "faulted") <$> state h) `shouldReturn` obj [(timerId, str "unknown")]
      nudges h `shouldReturn` []

  describe "close" $ do
    it "close retires the loop with the maturity log" $ do
      h <- spawn
      (timerId, _) <- mature h
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      _ <- acknowledgeArm h
      _ <- acknowledgeCancel h
      tokens h "rem.state" `shouldReturn` []
      done <- one h "rem.done"
      done `at` "reason" `shouldBe` str "merged"
      done `at` "matured" `shouldBe` texts [timerId]

    it "close while a nudge is in flight settles exactly once" $ do
      h <- spawnHeld
      let held = ["reminder_gate"]
      (timerId, _) <- matureHeld h held
      deliverHeld h held "on_close" "CloseSeen" (obj [("reason", str "merged")])
      tokens h "rem.done" `shouldReturn` []
      ((`at` "closing") <$> state h) `shouldReturn` str "merged"
      releaseOne h "reminder_gate"
      acknowledgeHeld h `shouldReturn` str "arm"
      acknowledgeHeld h `shouldReturn` str "cancel"
      [done] <- tokens h "rem.done"
      done `at` "reason" `shouldBe` str "merged"
      tokens h "rem.state" `shouldReturn` []
      nudges h `shouldReturn` ["reminder:" <> timerId]

    it "close with an empty reason still settles a deferred close" $ do
      h <- spawnHeld
      let held = ["reminder_gate"]
      _ <- matureHeld h held
      deliverHeld h held "on_close" "CloseSeen" (obj [("reason", str "")])
      tokens h "rem.done" `shouldReturn` []
      releaseOne h "reminder_gate"
      acknowledgeHeld h `shouldReturn` str "arm"
      acknowledgeHeld h `shouldReturn` str "cancel"
      [done] <- tokens h "rem.done"
      done `at` "reason" `shouldBe` str ""
      tokens h "rem.state" `shouldReturn` []

    it "a matured timer after close is recorded, never nudged" $ do
      h <- spawn
      deliver h "on_close" "CloseSeen" (obj [("reason", str "closed")])
      let stale =
            obj
              [ ("timer", obj [("id", str "t9"), ("incarnation", int 9), ("sequence", int 0), ("head", str "stale")])
              , ("due_at", str "2026-08-16T00:00:00Z")
              , ("matured_at", str "2026-08-16T00:00:01Z")
              ]
      _ <- matureWith h stale
      oneAt h "rem.done" "matured" `shouldReturn` texts ["t9"]
      nudges h `shouldReturn` []
      tokens h "rem.timers" `shouldReturn` []

    it "late snoozes and recoveries after close are inert" $ do
      h <- spawn
      commentsMode (Just "retryable") h
      (timerId, _) <- mature h
      commentsMode Nothing h
      deliver h "on_close" "CloseSeen" (obj [("reason", str "closed")])
      _ <- acknowledgeArm h
      _ <- acknowledgeCancel h
      doneBefore <- one h "rem.done"
      commentWith h "c1" "snooze" "all" True
      commentWith h "c2" "recover_publication" ("reminder:" <> timerId) True
      one h "rem.done" `shouldReturn` doneBefore
      nudges h `shouldReturn` []
      tokens h "rem.snoozes" `shouldReturn` []
      tokens h "rem.recover" `shouldReturn` []
