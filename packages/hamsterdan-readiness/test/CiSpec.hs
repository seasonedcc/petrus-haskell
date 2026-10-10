-- | @tests/unit/readiness/net_v5/test_ci_loop.py@ (21 functions, 21
-- cases): the CI loop.
module CiSpec (spec) where

import Data.Text (Text)
import Harness
import Petrus.Activity (ActivityInvocation (..))
import Petrus.Json (Json (..))
import Test.Hspec

hold :: [Text]
hold = ["rerun_gate"]

failures :: H -> IO [Json]
failures h = tokens h "esc.failures"

headSeen :: Text -> Text -> Text -> Bool -> Json
headSeen headSha base policy mergeable =
  obj [("head", str headSha), ("base", str base), ("mergeable", Bool mergeable), ("policy", str policy)]

runSeen :: Integer -> Integer -> Text -> Text -> Json
runSeen runId attempt conclusion fingerprint =
  obj [("head", str "h1"), ("run_id", int runId), ("attempt", int attempt), ("conclusion", str conclusion), ("fingerprint", str fingerprint)]

-- | A failing head whose rerun escalation is HELD in flight.
heldFailure :: Text -> Text -> Text -> IO H
heldFailure headSha base policy = do
  h <- spawnHeld
  deliverHeld h hold "on_head" "HeadSeen" (headSeen headSha base policy True)
  deliverHeld
    h
    hold
    "on_runs"
    "RunSeen"
    (obj [("head", str headSha), ("run_id", int 1), ("attempt", int 1), ("conclusion", str "failure"), ("fingerprint", str "fp1")])
  pure h

heldFailure' :: IO H
heldFailure' = heldFailure "h1" "b1" "p1"

-- | The base moves at the provider BEFORE its webhook arrives.
moveBase :: Text -> World -> World
moveBase b w = w {baseHead = b, authority = (w.authority) {base = b}}

run :: H -> Integer -> Integer -> Text -> Text -> IO ()
run h runId attempt conclusion fingerprint =
  seeRunWith h runArgs {runId, runAttempt = attempt, runConclusion = conclusion, runFingerprint = fingerprint}

spec :: Spec
spec = describe "ci loop" $ do
  describe "admission" $ do
    it "first head seeds pending with fresh lineage" $ do
      h <- spawn
      seeHead h "h1"
      state <- one h "ci.state"
      state `at` "head" `shouldBe` str "h1"
      state `at` "lineage" `shouldBe` str "L1"
      state `at` "status" `shouldBe` str "pending"
      state `at` "best" `shouldBe` arr []
      facts <- factsOf h "checks"
      last facts `at` "status" `shouldBe` str "pending"
      oneAt h "ready.snap" "checks" `shouldReturn` str "pending"

    it "superseded head resets evidence and budget lineage" $ do
      h <- spawn
      seeHead h "h1"
      run h 1 1 "failure" "fp1"
      seeHead h "h2"
      state <- one h "ci.state"
      state `at` "head" `shouldBe` str "h2"
      state `at` "lineage" `shouldBe` str "L2"
      state `at` "status" `shouldBe` str "pending"
      state `at` "best" `shouldBe` arr []
      state `at` "fingerprint" `shouldBe` str ""

    it "resume keeps the budget lineage" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_draft" "DraftSeen" (obj [])
      deliver h "on_ready" "ReadySeen" (obj [])
      state <- one h "ci.state"
      state `at` "incarnation" `shouldBe` int 2
      state `at` "lineage" `shouldBe` str "L1"

    it "base refresh adopts authority without churning evidence" $ do
      h <- spawn
      seeHeadWith h "h1" headArgs {seenBase = "b1"}
      run h 1 1 "failure" "fp1"
      checksBefore <- factsOf h "checks"
      seeHeadWith h "h1" headArgs {seenBase = "b2"}
      state <- one h "ci.state"
      state `at` "base" `shouldBe` str "b2"
      state `at` "status" `shouldBe` str "failure"
      state `at` "best" `shouldBe` arr [int 1, int 1]
      checksAfter <- factsOf h "checks"
      length checksAfter `shouldBe` length checksBefore

  describe "assessment" $ do
    it "newest exact head run wins" $ do
      h <- spawn
      seeHead h "h1"
      run h 1 1 "failure" "fp1"
      run h 2 1 "success" ""
      state <- one h "ci.state"
      state `at` "status" `shouldBe` str "success"
      state `at` "best" `shouldBe` arr [int 2, int 1]

    it "run for another head is inert" $ do
      h <- spawn
      seeHead h "h1"
      seeRunWith h runArgs {runHead = "h0", runId = 9, runConclusion = "failure", runFingerprint = "fpX"}
      oneAt h "ci.state" "status" `shouldReturn` str "pending"
      failures h `shouldReturn` []

    it "older run is inert" $ do
      h <- spawn
      seeHead h "h1"
      run h 2 1 "success" ""
      run h 1 1 "failure" "fp1"
      oneAt h "ci.state" "status" `shouldReturn` str "success"
      failures h `shouldReturn` []

    it "same run id higher attempt wins" $ do
      h <- spawn
      seeHead h "h1"
      run h 1 1 "failure" "fp1"
      run h 1 2 "success" ""
      state <- one h "ci.state"
      state `at` "status" `shouldBe` str "success"
      state `at` "best" `shouldBe` arr [int 1, int 2]

    it "same identity progresses from in_progress to failure" $ do
      h <- spawn
      seeHead h "h1"
      run h 1 1 "in_progress" ""
      oneAt h "ci.state" "status" `shouldReturn` str "in_progress"
      run h 1 1 "failure" "fp1"
      oneAt h "ci.state" "status" `shouldReturn` str "failure"
      ((.reruns) <$> worldOf h) `shouldReturn` ["L1:fp1"]

    it "same identity advances from queued to in_progress" $ do
      h <- spawn
      seeHead h "h1"
      run h 1 1 "queued" ""
      run h 1 1 "in_progress" ""
      oneAt h "ci.state" "status" `shouldReturn` str "in_progress"

    it "same identity never steps back from in_progress to queued" $ do
      h <- spawn
      seeHead h "h1"
      run h 1 1 "in_progress" ""
      run h 1 1 "queued" ""
      oneAt h "ci.state" "status" `shouldReturn` str "in_progress"

    it "same identity never regresses from terminal to nonterminal" $ do
      h <- spawn
      seeHead h "h1"
      run h 1 1 "success" ""
      run h 1 1 "in_progress" ""
      oneAt h "ci.state" "status" `shouldReturn` str "success"

    it "equal run evidence is inert and mails no duplicate" $ do
      h <- heldFailure'
      deliverHeld h hold "on_runs" "RunSeen" (runSeen 1 1 "failure" "fp1")
      failures h `shouldReturn` []
      (length <$> pendingAll h) `shouldReturn` 1

    it "failure mails escalation with lineage and authority" $ do
      h <- heldFailure "h1" "b1" "p1"
      [invocation] <- pendingAll h
      invocation.activity `shouldBe` "rerun_gate"
      let claim = invocation.input `at` "work"
      claim `at` "mem" `shouldBe` obj [("reruns", obj []), ("repairs", obj []), ("rerun_faults", obj []), ("closing", Null)]
      without ["mem"] claim
        `shouldBe` obj
          [ ("fingerprint", str "L1:fp1")
          , ("fp", str "fp1")
          , ("op", str "rerun:L1:fp1")
          , ("head", str "h1")
          , ("base", str "b1")
          , ("policy", str "p1")
          , ("incarnation", int 1)
          , ("run_id", int 1)
          , ("attempt", int 1)
          ]

  describe "escalation echo" $ do
    it "moved gate echo of the current tuple parks the fingerprint" $ do
      h <- heldFailure'
      modifyWorld h (moveBase "b2")
      releaseOne h "rerun_gate"
      oneAt h "ci.state" "parked" `shouldReturn` arr [str "fp1"]
      pendingAll h `shouldReturn` []
      oneAt h "esc.ladder" "reruns" `shouldReturn` obj []

    it "refresh reissues a parked escalation under the fresh base" $ do
      h <- heldFailure'
      modifyWorld h (moveBase "b2")
      releaseOne h "rerun_gate"
      deliverHeld h [] "on_head" "HeadSeen" (headSeen "h1" "b2" "p1" True)
      oneAt h "ci.state" "parked" `shouldReturn` arr []
      ((.reruns) <$> worldOf h) `shouldReturn` ["L1:fp1"]
      ((`atPath` ["L1:fp1", "state"]) <$> oneAt h "esc.ladder" "reruns") `shouldReturn` str "done"

    it "echo of a stale tuple reissues under the current authority" $ do
      h <- heldFailure'
      deliverHeld h hold "on_head" "HeadSeen" (headSeen "h1" "b2" "p1" True)
      releaseOne h "rerun_gate"
      oneAt h "ci.state" "parked" `shouldReturn` arr []
      ((.reruns) <$> worldOf h) `shouldReturn` ["L1:fp1"]
      ((`atPath` ["L1:fp1", "state"]) <$> oneAt h "esc.ladder" "reruns") `shouldReturn` str "done"

    it "mergeable-only refresh preserves parked and mails nothing" $ do
      h <- heldFailure'
      modifyWorld h (\w -> w {prState = "draft", authority = (w.authority) {phase = "quiescent"}})
      releaseOne h "rerun_gate"
      oneAt h "ci.state" "parked" `shouldReturn` arr [str "fp1"]
      deliverHeld h [] "on_head" "HeadSeen" (headSeen "h1" "b1" "p1" False)
      oneAt h "ci.state" "parked" `shouldReturn` arr [str "fp1"]
      failures h `shouldReturn` []
      pendingAll h `shouldReturn` []
      oneAt h "esc.ladder" "reruns" `shouldReturn` obj []

    it "stale incarnation echo reissues once and the duplicate is absorbed" $ do
      h <- heldFailure'
      deliverHeld h hold "on_draft" "DraftSeen" (obj [])
      deliverHeld h hold "on_ready" "ReadySeen" (obj [])
      deliverHeld h hold "on_runs" "RunSeen" (runSeen 1 1 "failure" "fp1")
      releaseOne h "rerun_gate"
      state <- one h "ci.state"
      state `at` "parked" `shouldBe` arr []
      state `at` "incarnation" `shouldBe` int 2
      ((.reruns) <$> worldOf h) `shouldReturn` ["L1:fp1"]
      ladder <- one h "esc.ladder"
      ladder `atPath` ["reruns", "L1:fp1"] `shouldBe` obj [("state", str "done"), ("run_id", int 1), ("attempt", int 1)]
      ladder `at` "repairs" `shouldBe` obj []
      tokens h "mut.requests" `shouldReturn` []

    it "echo after the failure is gone is inert" $ do
      h <- heldFailure'
      deliverHeld h hold "on_runs" "RunSeen" (runSeen 2 1 "success" "")
      modifyWorld h (moveBase "b2")
      releaseOne h "rerun_gate"
      oneAt h "ci.state" "parked" `shouldReturn` arr []
      failures h `shouldReturn` []
      ((.reruns) <$> worldOf h) `shouldReturn` []
      oneAt h "esc.ladder" "reruns" `shouldReturn` obj []

  describe "close" $
    it "close records the final verdict and retires the baton" $ do
      h <- spawn
      seeHead h "h1"
      run h 1 1 "failure" "fp1"
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      one h "ci.done" `shouldReturn` obj [("status", str "failure"), ("reason", str "merged")]
      tokens h "ci.state" `shouldReturn` []
