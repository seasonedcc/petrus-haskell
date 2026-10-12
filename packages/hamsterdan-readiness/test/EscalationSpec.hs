-- | @tests/unit/readiness/net_v5/test_escalation_loop.py@ (23 functions,
-- 23 cases): the escalation loop.
module EscalationSpec (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import Harness
import Petrus.Json (Json (..))
import Test.Hspec

hold, gateHold :: [Text]
hold = ["rerun_gate"]
gateHold = ["git_gate"]

failWith :: H -> Integer -> Integer -> Text -> Text -> IO ()
failWith h runId attempt fingerprint headSha =
  seeRunWith h runArgs {runHead = headSha, runId, runAttempt = attempt, runConclusion = "failure", runFingerprint = fingerprint}

failRun :: H -> Integer -> Integer -> IO ()
failRun h runId attempt = failWith h runId attempt "fp1" "h1"

ladder :: H -> IO Json
ladder h = one h "esc.ladder"

-- | Operations the provider's push ledger holds (LANDED effects).
pushes :: H -> IO [Text]
pushes h = map (.op) . (.pushes) <$> worldOf h

-- | Every mutation round the loop ever opened.
pushRounds :: H -> IO [Json]
pushRounds h = factsOf h "mutation_pending"

humanPages :: H -> IO [Json]
humanPages h = factsOf h "human_needed"

headH1 :: Json
headH1 = obj [("head", str "h1"), ("base", str "b1"), ("mergeable", Bool True), ("policy", str "p1")]

runSeen :: Integer -> Integer -> Text -> Json
runSeen runId attempt fingerprint =
  obj [("head", str "h1"), ("run_id", int runId), ("attempt", int attempt), ("conclusion", str "failure"), ("fingerprint", str fingerprint)]

rung :: Integer -> Integer -> Json
rung runId attempt = obj [("state", str "done"), ("run_id", int runId), ("attempt", int attempt)]

reruns :: H -> IO [Text]
reruns h = (.reruns) <$> worldOf h

rerunLog :: H -> IO [(Text, Text)]
rerunLog h = (\w -> [e | e@("rerun", _) <- w.log]) <$> worldOf h

hasKey :: Text -> Json -> Bool
hasKey k v = k `elem` keys v

-- | A failing head whose rerun gate faulted (unknown terminal).
spawnFaulted :: IO H
spawnFaulted = do
  h <- spawn
  modifyWorld h (\w -> w {rerunsMode = Just "unknown"})
  seeHeadWith h "h1" headArgs {seenBase = "b1", seenPolicy = "p1"}
  failRun h 1 1
  pure h

providerHeld :: World -> World
providerHeld w = w {rerunsMode = Nothing, reruns = w.reruns ++ ["L1:fp1"]}

spec :: Spec
spec = describe "escalation loop" $ do
  describe "rerun rung" $ do
    it "first failure requests one rerun and holds the baton" $ do
      h <- spawnHeld
      deliverHeld h hold "on_head" "HeadSeen" headH1
      deliverHeld h hold "on_runs" "RunSeen" (runSeen 1 1 "fp1")
      [invocation] <- pendingAll h
      invocation.activity `shouldBe` "rerun_gate"
      tokens h "esc.ladder" `shouldReturn` []
      deliverHeld h hold "on_runs" "RunSeen" (runSeen 2 1 "fp2")
      (length <$> tokens h "esc.failures") `shouldReturn` 1
      (length <$> pendingAll h) `shouldReturn` 1
      releaseOne h "rerun_gate"
      reruns h `shouldReturn` ["L1:fp1", "L1:fp2"]
      ((`at` "reruns") <$> ladder h) `shouldReturn` obj [("L1:fp1", rung 2 1), ("L1:fp2", rung 2 1)]

    it "evidence arriving while the rerun is in flight cannot indict it" $ do
      h <- spawnHeld
      deliverHeld h hold "on_head" "HeadSeen" headH1
      deliverHeld h hold "on_runs" "RunSeen" (runSeen 1 1 "fp1")
      deliverHeld h hold "on_runs" "RunSeen" (runSeen 1 2 "fp1")
      (length <$> tokens h "esc.failures") `shouldReturn` 1
      releaseOne h "rerun_gate"
      ((`at` "reruns") <$> ladder h) `shouldReturn` obj [("L1:fp1", rung 1 2)]
      pushRounds h `shouldReturn` []
      deliverHeld h [] "on_runs" "RunSeen" (runSeen 1 3 "fp1")
      pushes h `shouldReturn` ["repair:L1:fp1"]

    it "landed rerun records the answered evidence on the rung" $ do
      h <- spawn
      seeHead h "h1"
      failRun h 7 2
      reruns h `shouldReturn` ["L1:fp1"]
      ((`at` "reruns") <$> ladder h) `shouldReturn` obj [("L1:fp1", rung 7 2)]

    it "budget is per lineage so new code earns a fresh rerun" $ do
      h <- spawn
      seeHead h "h1"
      failRun h 1 1
      seeHead h "h2"
      failWith h 2 1 "fp1" "h2"
      reruns h `shouldReturn` ["L1:fp1", "L2:fp1"]
      pushRounds h `shouldReturn` []

    it "confirmed own repair keeps the lineage and the burned rungs" $ do
      h <- spawn
      seeHead h "h1"
      failRun h 1 1
      failRun h 1 2
      pushes h `shouldReturn` ["repair:L1:fp1"]
      newHead <- (.branchHead) <$> worldOf h
      newHead `shouldBe` "h1+repair:L1:fp1"
      oneAt h "life.state" "expected" `shouldReturn` str newHead
      seeHead h newHead
      failWith h 2 1 "fp1" newHead
      reruns h `shouldReturn` ["L1:fp1"]
      pushes h `shouldReturn` ["repair:L1:fp1"]
      [page] <- humanPages h
      page `shouldBe` obj [("fingerprint", str "fp1"), ("head", str newHead)]

  describe "repair rung" $ do
    it "newer failing evidence after a landed rerun requests repair once" $ do
      h <- spawnHeld
      deliverHeld h gateHold "on_head" "HeadSeen" headH1
      forM_ [1, 2] $ \attempt -> deliverHeld h gateHold "on_runs" "RunSeen" (runSeen 1 attempt "fp1")
      [invocation] <- pendingWork h "git_gate"
      invocation.input `at` "work"
        `shouldBe` obj
          [ ("op", str "repair:L1:fp1")
          , ("op_key", str "push:repair:L1:fp1:h1:i1")
          , ("head", str "h1")
          , ("base", str "b1")
          , ("policy", str "p1")
          , ("incarnation", int 1)
          , ("lineage", str "L1")
          , ("kind", str "repair")
          , ("instruction", str "")
          , ("run_id", int 1)
          , ("attempt", int 2)
          ]
      ((`atPath` ["repairs", "L1:fp1", "state"]) <$> ladder h) `shouldReturn` str "pending"
      deliverHeld h gateHold "on_runs" "RunSeen" (runSeen 1 3 "fp1")
      (length <$> pendingWork h "git_gate") `shouldReturn` 1
      humanPages h `shouldReturn` []
      releaseOne h "git_gate"
      pushes h `shouldReturn` ["repair:L1:fp1"]

    it "landed repair then strictly newer failure pages the human" $ do
      h <- spawn
      seeHead h "h1"
      failRun h 1 1
      failRun h 1 2
      pushes h `shouldReturn` ["repair:L1:fp1"]
      ((`atPath` ["repairs", "L1:fp1", "state"]) <$> ladder h) `shouldReturn` str "done"
      humanPages h `shouldReturn` []
      failRun h 1 3
      [page] <- humanPages h
      page `shouldBe` obj [("fingerprint", str "fp1"), ("head", str "h1")]

    it "declined repair consumes the rung with a known terminal" $ do
      h <- spawn
      modifyWorld h (\w -> w {gitMode = Just "fault"})
      seeHead h "h1"
      failRun h 1 1
      failRun h 1 2
      ((`atPath` ["repairs", "L1:fp1", "state"]) <$> ladder h) `shouldReturn` str "fault"
      failWith h 2 1 "fp2" "h1"
      failWith h 2 2 "fp2" "h1"
      ((`atPath` ["repairs", "L1:fp2", "state"]) <$> ladder h) `shouldReturn` str "declined"
      failWith h 2 3 "fp2" "h1"
      (length <$> humanPages h) `shouldReturn` 1
      pushes h `shouldReturn` []

    it "moved repair refunds the budget and converges through ci" $ do
      h <- spawnHeld
      deliverHeld h gateHold "on_head" "HeadSeen" headH1
      forM_ [1, 2] $ \attempt -> deliverHeld h gateHold "on_runs" "RunSeen" (runSeen 1 attempt "fp1")
      modifyWorld h (\w -> w {baseHead = "b2"})
      releaseOne h "git_gate"
      (hasKey "L1:fp1" . (`at` "repairs") <$> ladder h) `shouldReturn` False
      oneAt h "ci.state" "parked" `shouldReturn` texts ["fp1"]
      pushes h `shouldReturn` []
      deliverHeld h [] "on_head" "HeadSeen" (obj [("head", str "h1"), ("base", str "b2"), ("mergeable", Bool True), ("policy", str "p1")])
      pushes h `shouldReturn` ["repair:L1:fp1"]
      entry <- (`atPath` ["repairs", "L1:fp1"]) <$> ladder h
      entry `at` "state" `shouldBe` str "done"
      entry `at` "base" `shouldBe` str "b2"

    it "faulted repair retains the entry for recovery-time echoes" $ do
      h <- spawn
      modifyWorld h (\w -> w {gitMode = Just "fault"})
      seeHeadWith h "h1" headArgs {seenBase = "b1", seenPolicy = "p1"}
      failRun h 1 1
      failRun h 1 2
      entry <- (`atPath` ["repairs", "L1:fp1"]) <$> ladder h
      entry `at` "state" `shouldBe` str "fault"
      (entry `at` "fp", entry `at` "head", entry `at` "base") `shouldBe` (str "fp1", str "h1", str "b1")
      (entry `at` "run_id", entry `at` "attempt") `shouldBe` (int 1, int 2)
      failRun h 1 3
      (length <$> humanPages h) `shouldReturn` 1
      pushes h `shouldReturn` []

    it "a settle the ladder never requested is inert" $ do
      h <- spawn
      seeHead h "h1"
      failRun h 1 1
      ladderBefore <- ladder h
      comment h "c1" "change"
      pushes h `shouldReturn` ["change"]
      ladder h `shouldReturn` ladderBefore

  describe "fault and recovery" $ do
    it "rerun fault is fail-closed and retains the exact request" $ do
      h <- spawnFaulted
      state <- ladder h
      state `at` "reruns" `shouldBe` obj [("L1:fp1", obj [("state", str "fault")])]
      state `atPath` ["rerun_faults", "L1:fp1"]
        `shouldBe` obj
          [ ("op", str "rerun:L1:fp1")
          , ("reason", str "unknown provider terminal")
          , ("fp", str "fp1")
          , ("head", str "h1")
          , ("base", str "b1")
          , ("policy", str "p1")
          , ("incarnation", int 1)
          , ("run_id", int 1)
          , ("attempt", int 1)
          , ("blocked", Null)
          ]
      reruns h `shouldReturn` []
      faults <- factsOf h "fault"
      faults `shouldNotBe` []
      take 1 [f `at` "where" | f <- faults] `shouldBe` [str "rerun"]

    it "a faulted rung never authorizes the repair rung" $ do
      h <- spawnFaulted
      failRun h 1 2
      pushRounds h `shouldReturn` []
      [page] <- humanPages h
      page `at` "why" `shouldBe` str "rerun-fault"

    it "recovery reissues the exact operation and lookup-first reconciles" $ do
      h <- spawnFaulted
      modifyWorld h providerHeld
      commentWith h "rec1" "recover_publication" "rerun:L1:fp1" True
      state <- ladder h
      state `at` "reruns" `shouldBe` obj [("L1:fp1", rung 1 1)]
      state `at` "rerun_faults" `shouldBe` obj []
      rerunLog h `shouldReturn` []

    it "recovery reissues when the provider never held it" $ do
      h <- spawnFaulted
      modifyWorld h (\w -> w {rerunsMode = Nothing})
      commentWith h "rec2" "recover_publication" "rerun:L1:fp1" True
      reruns h `shouldReturn` ["L1:fp1"]
      ((`atPath` ["reruns", "L1:fp1", "state"]) <$> ladder h) `shouldReturn` str "done"

    it "recovery replays evidence blocked by an already held rerun" $ do
      h <- spawnFaulted
      failRun h 1 2
      pushRounds h `shouldReturn` []
      modifyWorld h providerHeld
      commentWith h "rec3" "recover_publication" "rerun:L1:fp1" True
      state <- ladder h
      state `atPath` ["reruns", "L1:fp1"] `shouldBe` rung 1 1
      state `at` "rerun_faults" `shouldBe` obj []
      pushes h `shouldReturn` ["repair:L1:fp1"]
      rerunLog h `shouldReturn` []

    it "recovery that issues the rerun now absorbs older blocked evidence" $ do
      h <- spawnFaulted
      failRun h 1 2
      modifyWorld h (\w -> w {rerunsMode = Nothing})
      commentWith h "rec4" "recover_publication" "rerun:L1:fp1" True
      state <- ladder h
      reruns h `shouldReturn` ["L1:fp1"]
      state `atPath` ["reruns", "L1:fp1"] `shouldBe` rung 1 2
      pushes h `shouldReturn` []
      failRun h 1 3
      pushes h `shouldReturn` ["repair:L1:fp1"]

    it "evidence arriving while recovery is in flight cannot indict the fresh rerun" $ do
      h <- spawnHeld
      modifyWorld h (\w -> w {rerunsMode = Just "unknown"})
      deliverHeld h [] "on_head" "HeadSeen" headH1
      deliverHeld h [] "on_runs" "RunSeen" (runSeen 1 1 "fp1")
      ((`at` "reruns") <$> ladder h) `shouldReturn` obj [("L1:fp1", obj [("state", str "fault")])]
      modifyWorld h (\w -> w {rerunsMode = Nothing})
      commentHeldWith h hold "rec1" "recover_publication" "rerun:L1:fp1" True
      deliverHeld h hold "on_runs" "RunSeen" (runSeen 1 2 "fp1")
      (length <$> tokens h "esc.failures") `shouldReturn` 1
      releaseOne h "rerun_gate"
      ((`at` "reruns") <$> ladder h) `shouldReturn` obj [("L1:fp1", rung 1 2)]
      pushes h `shouldReturn` []
      deliverHeld h [] "on_runs" "RunSeen" (runSeen 1 3 "fp1")
      pushes h `shouldReturn` ["repair:L1:fp1"]

    it "a refaulted recovery round keeps the blocked evidence" $ do
      h <- spawnFaulted
      failRun h 1 2
      commentWith h "rec5" "recover_publication" "rerun:L1:fp1" True
      blocked <- (`atPath` ["rerun_faults", "L1:fp1", "blocked"]) <$> ladder h
      (blocked `at` "run_id", blocked `at` "attempt") `shouldBe` (int 1, int 2)
      modifyWorld h providerHeld
      commentWith h "rec6" "recover_publication" "rerun:L1:fp1" True
      pushes h `shouldReturn` ["repair:L1:fp1"]

    it "recovery for an unknown operation is inert" $ do
      h <- spawnFaulted
      ladderBefore <- ladder h
      commentWith h "rec7" "recover_publication" "rerun:L9:zz" True
      ladder h `shouldReturn` ladderBefore

    it "recovery routed to another loop is inert here" $ do
      h <- spawnFaulted
      ladderBefore <- ladder h
      commentWith h "rec8" "recover_publication" "push:zz:h1:i1" True
      ladder h `shouldReturn` ladderBefore

  describe "close" $ do
    it "a recovery that lost the race with close is never stranded" $ do
      h <- spawnHeld
      deliverHeld h hold "on_head" "HeadSeen" headH1
      deliverHeld h hold "on_runs" "RunSeen" (runSeen 1 1 "fp1")
      tokens h "esc.ladder" `shouldReturn` []
      commentHeldWith h hold "r1" "recover_publication" "rerun:fp1" True
      (length <$> tokens h "esc.recover") `shouldReturn` 1
      deliverHeld h hold "on_close" "CloseSeen" (obj [("reason", str "merged")])
      releaseOne h "rerun_gate"
      tokens h "esc.recover" `shouldReturn` []
      [ended] <- tokens h "esc.done"
      ended `at` "reason" `shouldBe` str "merged"
      tokens h "ci.echo" `shouldReturn` []

    it "close retires the ladder with its budgets" $ do
      h <- spawn
      seeHead h "h1"
      failRun h 1 1
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      ended <- one h "esc.done"
      ended `at` "reason" `shouldBe` str "merged"
      ended `at` "reruns" `shouldBe` obj [("L1:fp1", rung 1 1)]
      tokens h "esc.ladder" `shouldReturn` []
