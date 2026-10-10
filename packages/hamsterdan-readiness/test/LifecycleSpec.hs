-- | @tests/unit/readiness/net_v5/test_lifecycle_loop.py@ (16 functions,
-- 16 cases): the lifecycle (admission) loop.
module LifecycleSpec (spec) where

import Control.Monad (forM_)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Harness
import Hamsterdan.Readiness.NetV5.Topology (buildNetV5)
import Petrus.Activity (ActivityInvocation (..))
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.Petrinet.Schema (Arc (..), arcModeText, netArcs, netPathText, netPlaceOrder, netTransitionOrder)
import Petrus.Json (Json (..))
import Test.Hspec

-- | A REAL landed repair: the first failing attempt burns the rerun, the
-- second opens escalation's repair rung, whose push lands and installs the
-- provisional expectation @h1+repair:L1:fp1@.
landRepair :: H -> IO ()
landRepair h =
  forM_ [1, 2] $ \attempt ->
    seeRunWith h runArgs {runAttempt = attempt, runConclusion = "failure", runFingerprint = "fp1"}

settleReminderClose :: H -> IO ()
settleReminderClose h = do
  arm <- one h "rem.commands"
  deliver
    h
    "on_timer_command_applied"
    "TimerCommandApplied"
    ( obj
        [ ("operation", arm `at` "operation")
        , ("result", obj [("kind", str "armed"), ("timer", arm `atPath` ["command", "timer"]), ("due_at", str "2026-08-16T00:00:00Z")])
        ]
    )
  cancel <- one h "rem.commands"
  deliver
    h
    "on_timer_command_applied"
    "TimerCommandApplied"
    ( obj
        [ ("operation", cancel `at` "operation")
        , ("result", obj [("kind", str "cancelled"), ("timer", cancel `atPath` ["command", "timer"])])
        ]
    )

built :: BuiltNet
built = either (const (error "buildNetV5 failed")) id buildNetV5

spec :: Spec
spec = describe "lifecycle loop" $ do
  describe "head admission" $ do
    it "first head admits as new with incarnation one" $ do
      h <- spawn
      seeHead h "h1"
      state <- one h "life.state"
      state `at` "phase" `shouldBe` str "running"
      state `at` "incarnation" `shouldBe` int 1
      state `at` "head" `shouldBe` str "h1"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      commentKeys h `shouldReturn` ["findings:h1:i1"]
      oneAt h "ci.state" "incarnation" `shouldReturn` int 1

    it "same head reobservation is absorbed" $ do
      h <- spawn
      seeHead h "h1"
      seeHead h "h1"
      oneAt h "life.state" "incarnation" `shouldReturn` int 1
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1

    it "base refresh keeps incarnation and mails refreshed" $ do
      h <- spawn
      seeHeadWith h "h1" headArgs {seenBase = "b1"}
      seeHeadWith h "h1" headArgs {seenBase = "b2"}
      state <- one h "life.state"
      state `at` "incarnation" `shouldBe` int 1
      state `at` "base" `shouldBe` str "b2"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      commentKeys h `shouldReturn` ["findings:h1:i1"]

    it "new head supersedes with fresh lineage" $ do
      h <- spawn
      seeHead h "h1"
      seeHead h "h2"
      state <- one h "life.state"
      state `at` "incarnation" `shouldBe` int 2
      state `at` "head" `shouldBe` str "h2"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 2
      (last <$> commentKeys h) `shouldReturn` "findings:h2:i2"
      oneAt h "ci.state" "lineage" `shouldReturn` str "L2"

    it "expected head admits as confirmed keeping lineage" $ do
      h <- spawn
      seeHead h "h1"
      landRepair h
      oneAt h "life.state" "expected" `shouldReturn` str "h1+repair:L1:fp1"
      seeHead h "h1+repair:L1:fp1"
      state <- one h "life.state"
      state `at` "incarnation" `shouldBe` int 2
      state `at` "expected" `shouldBe` str ""
      oneAt h "ci.state" "lineage" `shouldReturn` str "L1"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 2

  describe "dormancy" $ do
    it "draft quiesces and absorbs heads until resume" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_draft" "DraftSeen" (obj [])
      oneAt h "life.state" "phase" `shouldReturn` str "quiescent"
      seeHead h "h2"
      state <- one h "life.state"
      state `at` "phase" `shouldBe` str "quiescent"
      state `at` "head" `shouldBe` str "h2"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      deliver h "on_ready" "ReadySeen" (obj [])
      resumed <- one h "life.state"
      resumed `at` "phase" `shouldBe` str "running"
      resumed `at` "incarnation" `shouldBe` int 2
      ((.agentCalls) <$> worldOf h) `shouldReturn` 2
      (last <$> commentKeys h) `shouldReturn` "findings:h2:i2"

    it "ready without quiescence is absorbed" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_ready" "ReadySeen" (obj [])
      oneAt h "life.state" "incarnation" `shouldReturn` int 1

    it "resume clears a provisional expectation" $ do
      h <- spawn
      seeHead h "h1"
      landRepair h
      oneAt h "life.state" "expected" `shouldReturn` str "h1+repair:L1:fp1"
      deliver h "on_draft" "DraftSeen" (obj [])
      seeHead h "h1+repair:L1:fp1"
      deliver h "on_ready" "ReadySeen" (obj [])
      state <- one h "life.state"
      state `at` "phase" `shouldBe` str "running"
      state `at` "expected" `shouldBe` str ""
      state `at` "expected_op" `shouldBe` str ""
      state `at` "lineage" `shouldBe` str ""

  describe "close" $ do
    it "close goes terminal and fans out to every loop" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      oneAt h "life.state" "phase" `shouldReturn` str "terminal"
      forM_ ["ci.done", "esc.done", "review.done", "mut.done", "dash.done"] $ \place ->
        oneAt h place "reason" `shouldReturn` str "merged"
      settleReminderClose h
      oneAt h "rem.done" "reason" `shouldReturn` str "merged"
      oneAt h "ready.done" "reason" `shouldReturn` str "merged"

    it "terminal absorbs every later observation" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      seeHead h "h2"
      deliver h "on_close" "CloseSeen" (obj [("reason", str "closed")])
      state <- one h "life.state"
      state `at` "phase" `shouldBe` str "terminal"
      state `at` "head" `shouldBe` str "h1"
      (length <$> tokens h "review.done") `shouldReturn` 1

  describe "observation routing" $ do
    it "comment mails an intent carrying the authority claim" $ do
      h <- spawnHeld
      deliverHeld h ["git_gate"] "on_head" "HeadSeen" (obj [("head", str "h1"), ("base", str "b1"), ("mergeable", Bool True), ("policy", str "p1")])
      commentHeld h ["git_gate"] "c1" "change"
      [invocation] <- pendingWork h "git_gate"
      let work = invocation.input `at` "work"
      work `at` "op_key" `shouldBe` str "push:comment:c1:h1:i1"
      work `at` "head" `shouldBe` str "h1"
      work `at` "base" `shouldBe` str "b1"
      work `at` "policy" `shouldBe` str "p1"
      work `at` "incarnation" `shouldBe` int 1

    it "human review becomes a gate fact for ready and dash" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_human" "HumanSeen" (obj [("approval", Bool True), ("changes_requested", Bool False), ("unresolved", int 0)])
      facts <- factsOf h "human"
      last facts `at` "approval" `shouldBe` Bool True
      oneAt h "ready.snap" "approval" `shouldReturn` Bool True

    it "runs are mailed to ci only while running" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_runs" "RunSeen" (run 1 "failure" "fp1")
      oneAt h "ci.state" "fingerprint" `shouldReturn` str "fp1"
      deliver h "on_draft" "DraftSeen" (obj [])
      deliver h "on_runs" "RunSeen" (run 2 "success" "")
      oneAt h "ci.state" "status" `shouldReturn` str "failure"

    it "admission mails state facts to ready and dash" $ do
      h <- spawn
      seeHead h "h1"
      [fact] <- factsOf h "state"
      fact `at` "head" `shouldBe` str "h1"
      fact `at` "phase" `shouldBe` str "running"
      st <- one h "ready.snap"
      st `at` "head" `shouldBe` str "h1"
      st `at` "phase" `shouldBe` str "running"

  describe "census" $ do
    it "no guards, no reads, filters only on legacy migration, every place owned" $ do
      null built.guards `shouldBe` True
      let arcs = netArcs built.net
          spelled a = (netPathText a.source, arcModeText a.mode, netPathText a.target)
          exceptional = Set.fromList [spelled a | a <- arcs, arcModeText a.mode /= "consume"]
          mailboxes = ["state", "checks", "review", "findings", "human", "mutation_pending", "mutation_settled", "fault_raised", "fault_cleared"] :: [Text]
          points = ["authorize", "wake_deferred"] :: [Text]
          expected =
            Set.unions
              [ Set.fromList [("ready." <> m <> "_facts", "inhibit", "ready." <> t) | m <- mailboxes, t <- points]
              , Set.fromList [(s, "inhibit", "ready." <> t) | s <- ["ready.facts", "ready.closed"], t <- points]
              , Set.fromList [("ready.state_facts", "inhibit", "ready.fold_" <> m) | m <- mailboxes, m `notElem` ["state", "fault_raised", "fault_cleared"]]
              , Set.fromList
                  [ ("ready.mutation_pending_facts", "inhibit", "ready.fold_mutation_settled")
                  , ("ready.fault_cleared_facts", "inhibit", "ready.fold_fault_raised")
                  ]
              , Set.fromList [("ready.facts", "inhibit", "ready.migrate_" <> m) | m <- mailboxes, m `notElem` ["state", "fault_raised", "fault_cleared"]]
              , Set.fromList
                  [ ("ready.facts", "inhibit", "ready.migrate_mutation_settled")
                  , ("ready.facts", "inhibit", "ready.migrate_fault_raised")
                  ]
              , Set.fromList
                  [ ("startup.pending", "inhibit", t)
                  | t <- ["startup.absorb_update", "review.agent", "review.publish", "esc.rerun_gate", "mut.git_gate", "conv.reply", "rem.gate", "ready.gate"]
                  ]
              ]
      exceptional `shouldBe` expected
      let filteredArcs = [a | a <- arcs, Just _ <- [a.filter]]
          filtered = Set.fromList (map spelled filteredArcs)
      length filteredArcs `shouldBe` 17
      filtered
        `shouldBe` Set.difference
          ( Set.fromList
              ( [("ready.facts", "consume", "ready.migrate_" <> m) | m <- mailboxes]
                  ++ [("ready.facts", "inhibit", "ready.migrate_" <> m) | m <- mailboxes]
              )
          )
          (Set.fromList [("ready.facts", "inhibit", "ready.migrate_state"), ("ready.facts", "inhibit", "ready.migrate_fault_cleared")])
      forM_ (netPlaceOrder built.net) $ \place -> do
        let (owner, rest) = T.breakOn "." (netPathText place)
        (T.null owner || T.null rest) `shouldBe` False

    it "ingress doors are the only no-input transitions" $ do
      let arcs = netArcs built.net
          doors =
            Set.fromList
              [ netPathText t
              | t <- netTransitionOrder built.net
              , not (any (\a -> a.target == t) arcs)
              ]
      doors
        `shouldBe` Set.fromList
          [ "on_head"
          , "on_draft"
          , "on_ready"
          , "on_close"
          , "on_comment"
          , "on_human"
          , "on_runs"
          , "on_announce_wake"
          , "on_review_round_wake"
          , "on_timer"
          , "on_timer_command_applied"
          ]
  where
    run :: Integer -> Text -> Text -> Json
    run runId conclusion fingerprint =
      obj [("head", str "h1"), ("run_id", int runId), ("attempt", int 1), ("conclusion", str conclusion), ("fingerprint", str fingerprint)]
