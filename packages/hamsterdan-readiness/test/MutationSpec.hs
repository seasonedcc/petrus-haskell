-- | @tests/unit/readiness/net_v5/test_mutation_loop.py@ (32 functions,
-- 32 cases): the mutation loop.
module MutationSpec (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import Harness
import Petrus.Activity (ActivityInvocation (..))
import Petrus.Json (Json (..))
import Test.Hspec

hold :: [Text]
hold = ["git_gate"]

seeHeadHeld :: H -> [Text] -> IO ()
seeHeadHeld h held =
  deliverHeld h held "on_head" "HeadSeen" (obj [("head", str "h1"), ("base", str "b1"), ("mergeable", Bool True), ("policy", str "p1")])

settledFacts, pendingFacts :: H -> IO [Json]
settledFacts h = factsOf h "mutation_settled"
pendingFacts h = factsOf h "mutation_pending"

outcomes :: H -> IO [Json]
outcomes h = map (`at` "outcome") <$> settledFacts h

lastSettled :: H -> IO Json
lastSettled h = last <$> settledFacts h

pushes :: H -> IO [(Text, Text)]
pushes h = (\w -> [e | e@("push", _) <- w.log]) <$> worldOf h

failing :: Integer -> Json
failing attempt =
  obj [("head", str "h1"), ("run_id", int 1), ("attempt", int attempt), ("conclusion", str "failure"), ("fingerprint", str "fp1")]

repairHeld :: H -> IO ()
repairHeld h = forM_ [1, 2] $ \attempt -> deliverHeld h hold "on_runs" "RunSeen" (failing attempt)

gitWork :: H -> IO Json
gitWork h =
  pendingWork h "git_gate" >>= \case
    [invocation] -> pure (invocation.input `at` "work")
    other -> fail ("expected one git_gate invocation, got " <> show (length other))

settled :: Text -> Text -> Text -> Integer -> Text -> Json
settled op key outcome incarnation fingerprint =
  obj [("op", str op), ("op_key", str key), ("outcome", str outcome), ("incarnation", int incarnation), ("fingerprint", str fingerprint)]

gitMode :: Maybe Text -> H -> IO ()
gitMode mode h = modifyWorld h (\w -> w {gitMode = mode})

opKey :: Text
opKey = "push:comment:c1:h1:i1"

-- | A push whose terminal is unknown (never proven landed).
spawnFaulted :: IO H
spawnFaulted = do
  h <- spawn
  gitMode (Just "fault") h
  seeHead h "h1"
  comment h "c1" "change"
  pure h

-- | The PRODUCT recovery door.
recover :: H -> Text -> Text -> IO ()
recover h op cid = commentWith h cid "recover_publication" op True

spec :: Spec
spec = describe "mutation loop" $ do
  describe "landed push" $ do
    it "a comment pushes under the comment's stable identity" $ do
      h <- spawn
      seeHead h "h1"
      comment h "c1" "change"
      w <- worldOf h
      w.branchHead `shouldBe` "h1+change"
      w.pushes `shouldBe` [Push {key = opKey, op = "change", from = "h1", to = "h1+change"}]
      oneAt h "mut.state" "state" `shouldReturn` str "idle"
      pendingFacts h `shouldReturn` [obj [("op", str "change"), ("op_key", str opKey)]]
      settledFacts h `shouldReturn` [settled "change" opKey "landed" 1 ""]

    it "a landed human push notes the provisional head with lifecycle" $ do
      h <- spawn
      seeHead h "h1"
      comment h "c1" "change"
      state <- one h "life.state"
      state `at` "expected" `shouldBe` str "h1+change"
      state `at` "expected_op" `shouldBe` str "change"
      state `at` "lineage" `shouldBe` str ""

    it "a landed repair notes the provisional head with its lineage" $ do
      h <- spawn
      seeHead h "h1"
      forM_ [1, 2] $ \attempt ->
        seeRunWith h runArgs {runAttempt = attempt, runConclusion = "failure", runFingerprint = "fp1"}
      state <- one h "life.state"
      state `at` "expected" `shouldBe` str "h1+repair:L1:fp1"
      state `at` "expected_op" `shouldBe` str "repair:L1:fp1"
      state `at` "lineage" `shouldBe` str "L1"
      ((`at` "fingerprint") <$> lastSettled h) `shouldReturn` str "L1:fp1"

    it "the baton serializes requests one at a time" $ do
      h <- spawnHeld
      seeHeadHeld h []
      commentHeld h hold "c1" "change"
      work <- gitWork h
      work `at` "op_key" `shouldBe` str opKey
      tokens h "mut.state" `shouldReturn` []
      commentHeld h hold "c2" "update_base"
      (length <$> tokens h "mut.requests") `shouldReturn` 1
      (length <$> pendingWork h "git_gate") `shouldReturn` 1
      releaseOne h "git_gate"
      pump h
      outcomes h `shouldReturn` [str "landed", str "moved"]
      pushes h `shouldReturn` [("push", opKey)]

    it "two distinct requests of the same kind never share an identity" $ do
      h <- spawnHeld
      seeHeadHeld h []
      commentHeld h hold "c1" "change"
      commentHeld h hold "c2" "change"
      releaseOne h "git_gate"
      pump h
      pushes h `shouldReturn` [("push", opKey)]
      outcomes h `shouldReturn` [str "landed", str "moved"]

  describe "authority fencing" $ do
    it "cas conflict: a stale head claim classifies moved" $ do
      h <- spawnHeld
      seeHeadHeld h []
      commentHeld h hold "c1" "change"
      modifyWorld h (\w -> w {branchHead = "h2"})
      releaseOne h "git_gate"
      pushes h `shouldReturn` []
      settledFacts h `shouldReturn` [settled "change" opKey "moved" 1 ""]
      oneAt h "mut.state" "state" `shouldReturn` str "idle"

    it "a moved base is fenced by the fresh read, not the cas" $ do
      h <- spawn
      seeHeadWith h "h1" headArgs {seenBase = "b1"}
      modifyWorld h (\w -> w {baseHead = "b2"})
      comment h "c1" "change"
      pushes h `shouldReturn` []
      ((`at` "outcome") <$> lastSettled h) `shouldReturn` str "moved"

    it "a grant moved to quiescent in flight refuses the push" $ do
      h <- spawnHeld
      seeHeadHeld h []
      commentHeld h hold "c1" "change"
      deliverHeld h hold "on_draft" "DraftSeen" (obj [])
      releaseOne h "git_gate"
      pushes h `shouldReturn` []
      ((`at` "outcome") <$> lastSettled h) `shouldReturn` str "moved"

    it "a previous incarnation's claim is fenced by the grant" $ do
      h <- spawnHeld
      seeHeadHeld h []
      commentHeld h hold "c1" "change"
      deliverHeld h hold "on_draft" "DraftSeen" (obj [])
      deliverHeld h hold "on_ready" "ReadySeen" (obj [])
      releaseOne h "git_gate"
      pushes h `shouldReturn` []
      ((`at` "outcome") <$> lastSettled h) `shouldReturn` str "moved"
      commentHeld h [] "c2" "change"
      pushes h `shouldReturn` [("push", "push:comment:c2:h1:i2")]

  describe "lookup-first" $
    it "an already landed operation reconciles without a second push" $ do
      h <- spawn
      seeHead h "h1"
      modifyWorld h (\w -> w {pushes = w.pushes ++ [Push {key = opKey, op = "change", from = "h1", to = "h1+change"}], branchHead = "h1+change"})
      comment h "c1" "change"
      pushes h `shouldReturn` []
      ((`at` "outcome") <$> lastSettled h) `shouldReturn` str "landed"
      oneAt h "life.state" "expected" `shouldReturn` str "h1+change"

  describe "fault and recovery" $ do
    it "a fault retains the exact operation fail-closed" $ do
      h <- spawnFaulted
      one h "mut.state"
        `shouldReturn` obj
          [ ("state", str "faulted")
          , ("op_key", str opKey)
          , ("op", str "change")
          , ("head", str "h1")
          , ("base", str "b1")
          , ("policy", str "p1")
          , ("incarnation", int 1)
          , ("reason", str "unknown provider terminal")
          , ("kind", str "change")
          , ("instruction", str "")
          , ("run_id", int 0)
          , ("attempt", int 0)
          ]
      faults <- factsOf h "fault"
      last faults `shouldBe` obj [("where", str "mutation"), ("op", str opKey), ("reason", str "unknown provider terminal")]
      oneAt h "ready.snap" "faults" `shouldReturn` obj [("mutation:" <> opKey, str "unknown provider terminal")]

    it "further requests are declined before any gate attempt" $ do
      h <- spawnFaulted
      gitMode Nothing h
      comment h "c2" "update_base"
      pushes h `shouldReturn` []
      lastSettled h `shouldReturn` settled "update_base" "push:comment:c2:h1:i1" "declined" 1 ""
      oneAt h "mut.state" "state" `shouldReturn` str "faulted"

    it "recovery reissues when the provider never held it" $ do
      h <- spawnFaulted
      gitMode Nothing h
      recover h opKey "r1"
      pushes h `shouldReturn` [("push", opKey)]
      oneAt h "mut.state" "state" `shouldReturn` str "idle"
      ((`at` "outcome") <$> lastSettled h) `shouldReturn` str "landed"
      oneAt h "life.state" "expected" `shouldReturn` str "h1+change"

    it "recovery after a crash reconciles lookup-first" $ do
      h <- spawn
      gitMode (Just "crash") h
      seeHead h "h1"
      comment h "c1" "change"
      oneAt h "mut.state" "state" `shouldReturn` str "faulted"
      (length <$> pushes h) `shouldReturn` 1
      gitMode Nothing h
      recover h opKey "r1"
      (length <$> pushes h) `shouldReturn` 1
      oneAt h "mut.state" "state" `shouldReturn` str "idle"
      ((`at` "outcome") <$> lastSettled h) `shouldReturn` str "landed"
      oneAt h "life.state" "expected" `shouldReturn` str "h1+change"

    it "a late recovery note cannot wedge lifecycle" $ do
      h <- spawn
      gitMode (Just "crash") h
      seeHead h "h1"
      comment h "c1" "change"
      oneAt h "mut.state" "state" `shouldReturn` str "faulted"
      seeHead h "h1+change"
      oneAt h "life.state" "incarnation" `shouldReturn` int 2
      gitMode Nothing h
      recover h opKey "r1"
      (length <$> pushes h) `shouldReturn` 1
      oneAt h "mut.state" "state" `shouldReturn` str "idle"
      oneAt h "life.state" "expected" `shouldReturn` str ""
      seeHead h "h3"
      oneAt h "life.state" "incarnation" `shouldReturn` int 3

    it "recovery for another loop or operation is inert" $ do
      h <- spawnFaulted
      stateBefore <- one h "mut.state"
      recover h "rerun:fp1" "r1"
      recover h "push:other:h1:i1" "r2"
      one h "mut.state" `shouldReturn` stateBefore

    it "recovery while idle is inert" $ do
      h <- spawn
      seeHead h "h1"
      recover h opKey "r1"
      oneAt h "mut.state" "state" `shouldReturn` str "idle"
      pushes h `shouldReturn` []

  describe "close" $ do
    it "close retires the baton with its state" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      one h "mut.done" `shouldReturn` obj [("state", str "idle"), ("reason", str "merged")]

    it "close while a push is in flight waits for the terminal" $ do
      h <- spawnHeld
      seeHeadHeld h []
      commentHeld h hold "c1" "change"
      deliverHeld h hold "on_close" "CloseSeen" (obj [("reason", str "merged")])
      tokens h "mut.done" `shouldReturn` []
      releaseOne h "git_gate"
      pushes h `shouldReturn` []
      one h "mut.done" `shouldReturn` obj [("state", str "idle"), ("reason", str "merged")]

    it "a request that lost the race with close settles declined" $ do
      h <- spawnHeld
      seeHeadHeld h []
      commentHeld h hold "c1" "change"
      commentHeld h hold "c2" "change"
      deliverHeld h hold "on_close" "CloseSeen" (obj [("reason", str "merged")])
      releaseOne h "git_gate"
      pushes h `shouldReturn` []
      tokens h "mut.requests" `shouldReturn` []
      outcomes h `shouldReturn` [str "moved", str "declined"]
      one h "mut.done" `shouldReturn` obj [("state", str "idle"), ("reason", str "merged")]

    it "a recovery that lost the race with close is never stranded" $ do
      h <- spawnHeld
      seeHeadHeld h []
      commentHeld h hold "c1" "change"
      tokens h "mut.state" `shouldReturn` []
      commentHeldWith h hold "r1" "recover_publication" opKey True
      (length <$> tokens h "mut.recover") `shouldReturn` 1
      deliverHeld h hold "on_close" "CloseSeen" (obj [("reason", str "merged")])
      releaseOne h "git_gate"
      tokens h "mut.recover" `shouldReturn` []
      oneAt h "mut.done" "reason" `shouldReturn` str "merged"

    it "close waits for a pending repair settlement" $ do
      h <- spawnHeld
      seeHeadHeld h hold
      repairHeld h
      work <- gitWork h
      work `at` "op" `shouldBe` str "repair:L1:fp1"
      deliverHeld h hold "on_close" "CloseSeen" (obj [("reason", str "closed")])
      tokens h "esc.done" `shouldReturn` []
      releaseOne h "git_gate"
      [ended] <- tokens h "esc.done"
      ended `at` "reason" `shouldBe` str "closed"
      ended `at` "repairs" `shouldBe` obj []
      tokens h "esc.settled" `shouldReturn` []
      tokens h "esc.ladder" `shouldReturn` []
      oneAt h "mut.done" "reason" `shouldReturn` str "closed"

    it "close with an empty reason still retires a waiting ladder" $ do
      h <- spawnHeld
      seeHeadHeld h hold
      repairHeld h
      deliverHeld h hold "on_close" "CloseSeen" (obj [("reason", str "")])
      releaseOne h "git_gate"
      [ended] <- tokens h "esc.done"
      ended `at` "reason" `shouldBe` str ""
      tokens h "esc.ladder" `shouldReturn` []

  describe "mutation payload" $ do
    it "a change comment carries its instruction to the gate" $ do
      h <- spawnHeld
      seeHeadHeld h []
      commentHeldWith h hold "c1" "change" "rename the config key" True
      work <- gitWork h
      work `at` "kind" `shouldBe` str "change"
      work `at` "instruction" `shouldBe` str "rename the config key"
      (work `at` "run_id", work `at` "attempt") `shouldBe` (int 0, int 0)

    it "a repair carries its evidence identity to the gate" $ do
      h <- spawnHeld
      seeHeadHeld h []
      repairHeld h
      work <- gitWork h
      work `at` "kind" `shouldBe` str "repair"
      work `at` "instruction" `shouldBe` str ""
      (work `at` "run_id", work `at` "attempt") `shouldBe` (int 1, int 2)

    it "a faulted round retains the instruction for exact reissue" $ do
      h <- spawnHeld
      gitMode (Just "fault") h
      seeHeadHeld h []
      commentHeldWith h hold "c1" "change" "rename the config key" True
      releaseOne h "git_gate"
      pump h
      state <- one h "mut.state"
      state `at` "state" `shouldBe` str "faulted"
      state `at` "kind" `shouldBe` str "change"
      state `at` "instruction" `shouldBe` str "rename the config key"
      gitMode Nothing h
      commentHeldWith h hold "r1" "recover_publication" opKey True
      work <- gitWork h
      work `at` "instruction" `shouldBe` str "rename the config key"

    it "recovery reissues the exact work byte for byte" $ do
      h <- spawnHeld
      gitMode (Just "fault") h
      seeHeadHeld h []
      commentHeldWith h hold "c1" "change" "rename the config key" True
      original <- gitWork h
      releaseOne h "git_gate"
      pump h
      gitMode Nothing h
      commentHeldWith h hold "r1" "recover_publication" opKey True
      second <- gitWork h
      second `shouldBe` original

    it "recovery reissues the exact repair work byte for byte" $ do
      h <- spawnHeld
      gitMode (Just "fault") h
      seeHeadHeld h []
      repairHeld h
      original <- gitWork h
      (original `at` "kind", original `at` "run_id", original `at` "attempt") `shouldBe` (str "repair", int 1, int 2)
      releaseOne h "git_gate"
      pump h
      gitMode Nothing h
      let key = case original `at` "op_key" of
            String k -> k
            other -> error (show other)
      commentHeldWith h hold "r1" "recover_publication" key True
      second <- gitWork h
      second `shouldBe` original

  describe "declined" $ do
    it "agent unable settles declined and returns the baton" $ do
      h <- spawn
      gitMode (Just "unable") h
      seeHead h "h1"
      comment h "c1" "change"
      pushes h `shouldReturn` []
      lastSettled h `shouldReturn` settled "change" opKey "declined" 1 ""
      oneAt h "mut.state" "state" `shouldReturn` str "idle"

    it "a declined round does not block the next request" $ do
      h <- spawn
      gitMode (Just "unable") h
      seeHead h "h1"
      comment h "c1" "change"
      gitMode Nothing h
      comment h "c2" "update_base"
      outcomes h `shouldReturn` [str "declined", str "landed"]
      pushes h `shouldReturn` [("push", "push:comment:c2:h1:i1")]

    it "a declined repair consumes the rung" $ do
      h <- spawn
      gitMode (Just "unable") h
      seeHead h "h1"
      forM_ [1, 2] $ \attempt ->
        seeRunWith h runArgs {runAttempt = attempt, runConclusion = "failure", runFingerprint = "fp1"}
      ((`at` "outcome") <$> lastSettled h) `shouldReturn` str "declined"
      seeRunWith h runArgs {runId = 2, runConclusion = "failure", runFingerprint = "fp1"}
      needed <- factsOf h "human_needed"
      needed `shouldNotBe` []
      last needed `at` "fingerprint" `shouldBe` str "fp1"

    it "close before the gate starts classifies moved, not declined" $ do
      h <- spawnHeld
      gitMode (Just "unable") h
      seeHeadHeld h []
      commentHeld h hold "c1" "change"
      deliverHeld h hold "on_close" "CloseSeen" (obj [("reason", str "closed")])
      releaseOne h "git_gate"
      pump h
      ((`at` "outcome") <$> lastSettled h) `shouldReturn` str "moved"
      [ended] <- tokens h "mut.done"
      ended `at` "state" `shouldBe` str "idle"
