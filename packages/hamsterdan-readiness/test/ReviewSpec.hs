-- | @tests/unit/readiness/net_v5/test_review_loop.py@ (33 functions, 36
-- cases: the seed-subject refusal is parametrized over four subjects):
-- the review loop.
module ReviewSpec (spec) where

import Control.Monad (forM_)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Harness
import Hamsterdan.Readiness.NetV5.Review (liveFindings)
import Hamsterdan.Readiness.NetV5.Topology (seedMarking)
import Petrus.Activity (ActivityInvocation (..))
import Petrus.Json (Json (..))
import Test.Hspec
import Hamsterdan.Python (pythonFailureText)

holdAgent, holdPublish :: [Text]
holdAgent = ["review_agent"]
holdPublish = ["publish_gate"]

findingH1 :: Json
findingH1 = obj [("id", str "f-h1"), ("note", str "finding:h1"), ("blocking", Bool True)]

memory :: H -> IO Json
memory h = one h "review.memory"

findingsFacts, reviewFacts :: H -> IO [Json]
findingsFacts h = factsOf h "findings"
reviewFacts h = factsOf h "review"

findingsComments :: H -> IO [Comment]
findingsComments h = (\w -> [c | c <- w.comments, c.kind == "findings"]) <$> worldOf h

commentKeys' :: H -> IO [Text]
commentKeys' h = map (.key) <$> findingsComments h

headSeen :: Text -> Text -> Json
headSeen headSha base = obj [("head", str headSha), ("base", str base), ("mergeable", Bool True), ("policy", str "p1")]

items :: Json -> [Json]
items = \case
  Array xs -> xs
  _ -> []

ids :: Json -> [Json]
ids v = map (`at` "id") (items v)

commentsMode :: Maybe Text -> H -> IO ()
commentsMode mode h = modifyWorld h (\w -> w {commentsMode = mode})

agentMode :: Maybe Text -> H -> IO ()
agentMode mode h = modifyWorld h (\w -> w {agentMode = mode})

recover :: H -> Text -> Text -> IO ()
recover h cid op = commentWith h cid "recover_publication" op True

wake :: H -> Json -> IO ()
wake h deferred =
  deliver
    h
    "on_review_round_wake"
    "RoundWake"
    (obj [("operation", deferred `at` "operation"), ("attempt", deferred `at` "attempt"), ("blocker", deferred `at` "blocker")])

spec :: Spec
spec = describe "review loop" $ do
  describe "agent round" $ do
    it "first head opens one round and lands one publication" $ do
      h <- spawn
      seeHead h "h1"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      commentKeys' h `shouldReturn` ["findings:h1:i1"]
      (map (.body) <$> findingsComments h) `shouldReturn` [arr [findingH1]]
      state <- memory h
      state `at` "reviewed" `shouldBe` texts ["h1"]
      (state `at` "head", state `at` "incarnation") `shouldBe` (str "h1", int 1)
      state `at` "status" `shouldBe` str "blocking"
      state `at` "findings" `shouldBe` arr [findingH1]
      state `at` "lineage" `shouldBe` arr [obj [("finding_id", str "f-h1"), ("state", str "new"), ("supersedes", Null)]]
      state `at` "provisional" `shouldBe` arr []
      state `at` "pub" `shouldBe` obj [("phase", str "idle")]
      (last <$> findingsFacts h) `shouldReturn` obj [("head", str "h1"), ("blocking", int 1), ("count", int 1)]
      oneAt h "ready.snap" "findings_blocking" `shouldReturn` int 1

    it "empty review settles through publication without a finding comment" $ do
      h <- spawn
      modifyWorld h (\w -> w {agentFindings = Map.insert "h1" [] w.agentFindings})
      seeHead h "h1"
      findingsComments h `shouldReturn` []
      ((.commentAttempts) <$> worldOf h) `shouldReturn` 1
      state <- memory h
      state `at` "reviewed" `shouldBe` texts ["h1"]
      state `at` "findings" `shouldBe` arr []
      (last <$> findingsFacts h) `shouldReturn` obj [("head", str "h1"), ("blocking", int 0), ("count", int 0)]

    it "dismissed findings are filtered before publication" $ do
      h <- spawn
      commentWith h "dis1" "dismiss" "f-h1" True
      seeHead h "h1"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      findingsComments h `shouldReturn` []
      state <- memory h
      state `at` "reviewed" `shouldBe` texts ["h1"]
      state `at` "dismissed" `shouldBe` texts ["f-h1"]
      state `at` "findings" `shouldBe` arr [findingH1]
      state `at` "lineage" `shouldBe` arr [obj [("finding_id", str "f-h1"), ("state", str "new"), ("supersedes", Null)]]
      state `at` "status" `shouldBe` str "clear"

    it "agent sees only its work token" $ do
      h <- spawnHeld
      deliverHeld h holdAgent "on_head" "HeadSeen" (headSeen "h1" "b1")
      [invocation] <- pendingWork h "review_agent"
      keys invocation.input `shouldBe` ["work"]
      let work = invocation.input `at` "work"
      keys work `shouldMatchList` ["operation", "head", "base", "policy", "incarnation", "prior_findings", "prior_lineage", "mem", "attempt"]
      work `at` "operation" `shouldBe` str "review:test:pr-v5:h1:i1"
      work `at` "attempt" `shouldBe` int 1
      work `at` "prior_findings" `shouldBe` arr []
      work `at` "prior_lineage" `shouldBe` arr []
      releaseOne h "review_agent"
      ((`at` "reviewed") <$> memory h) `shouldReturn` texts ["h1"]

    it "clean agent inability fails closed without an effect fault" $ do
      h <- spawn
      agentMode (Just "unable") h
      seeHead h "h1"
      state <- memory h
      state `at` "reviewed" `shouldBe` texts ["h1"]
      state `at` "status" `shouldBe` str "unable"
      findingsComments h `shouldReturn` []
      (last <$> reviewFacts h) `shouldReturn` obj [("head", str "h1"), ("status", str "unable"), ("category", str "unable")]
      factsOf h "fault" `shouldReturn` []
      oneAt h "ready.snap" "review" `shouldReturn` str "unable"

    it "custody deferral holds the round silently until its identified wake" $ do
      h <- spawn
      agentMode (Just "deferred") h
      seeHead h "h1"
      [deferred] <- tokens h "review.deferred"
      deferred `at` "attempt" `shouldBe` int 1
      reviewFacts h `shouldReturn` []
      oneAt h "ready.snap" "review" `shouldReturn` str "pending"
      (any (T.isPrefixOf "review:") . (.dashboard) <$> worldOf h) `shouldReturn` False
      agentMode Nothing h
      wake h deferred
      ((.agentCalls) <$> worldOf h) `shouldReturn` 2
      tokens h "review.deferred" `shouldReturn` []
      (last <$> reviewFacts h) `shouldReturn` obj [("head", str "h1"), ("status", str "blocking")]

    it "publication custody deferral resumes without another agent round" $ do
      h <- spawn
      modifyWorld h (\w -> w {publicationBlocker = Just "9adff0dc-4784-4eed-9c78-047d6952efed"})
      seeHead h "h1"
      [deferred] <- tokens h "review.publication_deferred"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      findingsComments h `shouldReturn` []
      modifyWorld h (\w -> w {publicationBlocker = Nothing})
      wake h deferred
      tokens h "review.publication_deferred" `shouldReturn` []
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      commentKeys' h `shouldReturn` ["findings:h1:i1"]
      (last <$> reviewFacts h) `shouldReturn` obj [("head", str "h1"), ("status", str "blocking")]

    it "draft movement before agent custody is inert until ready opens the current round" $ do
      h <- spawnHeld
      deliverHeld h holdAgent "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h holdAgent "on_draft" "DraftSeen" (obj [])
      releaseOne h "review_agent"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 0
      reviewFacts h `shouldReturn` []
      ((`at` "status") <$> memory h) `shouldReturn` str "pending"
      deliverHeld h [] "on_ready" "ReadySeen" (obj [])
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      (last <$> reviewFacts h) `shouldReturn` obj [("head", str "h1"), ("status", str "blocking")]
      (any (\f -> lookup' "status" f == Just (str "unable")) <$> reviewFacts h) `shouldReturn` False

  describe "publication" $ do
    it "lookup-first reconciles an already landed publication" $ do
      h <- spawn
      modifyWorld h (\w -> w {comments = w.comments ++ [Comment {key = "findings:h1:i1", kind = "findings", head = "h1", body = arr [findingH1]}]})
      seeHead h "h1"
      commentKeys' h `shouldReturn` ["findings:h1:i1"]
      ((\w -> [e | e@("comment", _) <- w.log]) <$> worldOf h) `shouldReturn` []
      ((`at` "reviewed") <$> memory h) `shouldReturn` texts ["h1"]

    it "effect identity collision fails closed" $ do
      h <- spawn
      modifyWorld h (\w -> w {comments = w.comments ++ [Comment {key = "findings:h1:i1", kind = "findings", head = "h1", body = arr [obj [("id", str "x")]]}]})
      seeHead h "h1"
      state <- memory h
      state `atPath` ["pub", "phase"] `shouldBe` str "faulted"
      textOf (state `atPath` ["pub", "reason"]) `shouldSatisfy` T.isInfixOf "collision"
      state `atPath` ["pub", "op"] `shouldBe` str "findings:h1:i1"
      state `at` "reviewed" `shouldBe` texts ["h1"]
      [fault] <- factsOf h "fault"
      fault `at` "where" `shouldBe` str "review"
      fault `at` "op" `shouldBe` str "findings:h1:i1"
      fault `at` "status" `shouldBe` str "faulted"

    it "retryable exhaustion blocks and recovery reissues the same operation" $ do
      h <- spawn
      commentsMode (Just "retryable") h
      seeHead h "h1"
      state <- memory h
      state `atPath` ["pub", "phase"] `shouldBe` str "blocked"
      state `atPath` ["pub", "op"] `shouldBe` str "findings:h1:i1"
      state `atPath` ["pub", "failure_class"] `shouldBe` str "transport_ambiguity"
      state `atPath` ["pub", "provider_status"] `shouldBe` Null
      state `atPath` ["pub", "provider_detail"] `shouldBe` str "none"
      ((.commentAttempts) <$> worldOf h) `shouldReturn` 3
      state `at` "reviewed" `shouldBe` texts ["h1"]
      ((`at` "blocking") . last <$> findingsFacts h) `shouldReturn` int 1
      commentsMode Nothing h
      recover h "rec1" "findings:h1:i1"
      commentKeys' h `shouldReturn` ["findings:h1:i1"]
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      after' <- memory h
      after' `at` "pub" `shouldBe` obj [("phase", str "idle")]
      after' `at` "reviewed" `shouldBe` texts ["h1"]

    it "unknown terminal faults closed and recovery reissues" $ do
      h <- spawn
      commentsMode (Just "unknown") h
      seeHead h "h1"
      state <- memory h
      state `atPath` ["pub", "phase"] `shouldBe` str "faulted"
      state `atPath` ["pub", "findings"] `shouldBe` arr [findingH1]
      findingsComments h `shouldReturn` []
      commentsMode Nothing h
      recover h "rec2" "findings:h1:i1"
      commentKeys' h `shouldReturn` ["findings:h1:i1"]
      after' <- memory h
      after' `at` "pub" `shouldBe` obj [("phase", str "idle")]
      keys (after' `at` "pub") `shouldNotContain` ["reason"]
      after' `at` "reviewed" `shouldBe` texts ["h1"]

    it "fault recovery emits an operation-keyed resolution" $ do
      h <- spawn
      commentsMode (Just "unknown") h
      seeHead h "h1"
      commentsMode Nothing h
      recover h "rec3" "findings:h1:i1"
      (last <$> factsOf h "fault") `shouldReturn` obj [("where", str "review"), ("op", str "findings:h1:i1"), ("status", str "resolved")]
      oneAt h "ready.snap" "faults" `shouldReturn` obj []
      commentKeys' h `shouldReturn` ["findings:h1:i1"]

    it "recovery for another loop or operation is inert" $ do
      h <- spawn
      commentsMode (Just "retryable") h
      seeHead h "h1"
      commentsMode Nothing h
      recover h "rec4" "rerun:L1:fp1"
      recover h "rec5" "findings:h9:i9"
      ((`atPath` ["pub", "phase"]) <$> memory h) `shouldReturn` str "blocked"
      findingsComments h `shouldReturn` []
      ((.commentAttempts) <$> worldOf h) `shouldReturn` 3

  describe "authority movement" $ do
    it "moved publication feeds provisionals into the superseding round" $ do
      h <- spawnHeld
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h2" "b1")
      findingsComments h `shouldReturn` []
      releaseOne h "publish_gate"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 2
      commentKeys' h `shouldReturn` ["findings:h2:i2"]
      [posted] <- (.comments) <$> worldOf h
      ids posted.body `shouldBe` [str "f-h1", str "f-h2"]
      state <- memory h
      state `at` "reviewed" `shouldBe` texts ["h1", "h2"]
      state `at` "provisional" `shouldBe` arr []

    it "superseding round uses agent lineage instead of concatenating provisionals" $ do
      h <- spawnHeld
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h1" "b1")
      let fh2 = obj [("id", str "f-h2"), ("note", str "finding:h2"), ("blocking", Bool False)]
          lineage =
            arr
              [ obj [("finding_id", str "f-h1"), ("state", str "resolved"), ("supersedes", Null)]
              , obj [("finding_id", str "f-h2"), ("state", str "new"), ("supersedes", Null)]
              ]
      modifyWorld h (\w -> w {agentResults = Map.insert "h2" (arr [fh2], lineage) w.agentResults})
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h2" "b1")
      releaseOne h "publish_gate"
      commentKeys' h `shouldReturn` ["findings:h2:i2"]
      (map (.body) <$> findingsComments h) `shouldReturn` [arr [fh2]]
      state <- memory h
      state `at` "findings" `shouldBe` arr [fh2]
      state `at` "lineage" `shouldBe` lineage
      state `at` "status" `shouldBe` str "clear"

    it "refresh after superseding agent inability emits no uncategorized unable fact" $ do
      h <- spawnHeld
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h1" "b1")
      agentMode (Just "unable") h
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h2" "b1")
      releaseOne h "publish_gate"
      ((`at` "status") <$> memory h) `shouldReturn` str "unable"
      ((`at` "provisional") <$> memory h) `shouldReturn` arr [findingH1]
      (last <$> reviewFacts h) `shouldReturn` obj [("head", str "h2"), ("status", str "unable"), ("category", str "unable")]
      deliverHeld h [] "on_head" "HeadSeen" (headSeen "h2" "b2")
      unable <- filter (\f -> f `at` "status" == str "unable") <$> reviewFacts h
      unable `shouldBe` [obj [("head", str "h2"), ("status", str "unable"), ("category", str "unable")]]
      oneAt h "ready.snap" "review" `shouldReturn` str "unable"
      commentKeys' h `shouldReturn` ["findings:h2:i2"]

    it "base refresh republishes provisionals without a new agent round" $ do
      h <- spawnHeld
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h1" "b2")
      releaseOne h "publish_gate"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      commentKeys' h `shouldReturn` ["findings:h1:i1"]
      state <- memory h
      state `at` "reviewed" `shouldBe` texts ["h1"]
      state `at` "provisional" `shouldBe` arr []
      state `at` "pub" `shouldBe` obj [("phase", str "idle")]

    it "a blocked publication holds exclusive custody of its findings" $ do
      h <- spawnHeld
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h2" "b1")
      completeOne h "publish_gate"
      pumpHolding h holdPublish
      commentsMode (Just "retryable") h
      releaseOne h "publish_gate"
      state <- memory h
      state `atPath` ["pub", "phase"] `shouldBe` str "blocked"
      ids (state `atPath` ["pub", "findings"]) `shouldBe` [str "f-h1", str "f-h2"]
      state `at` "provisional" `shouldBe` arr []
      commentsMode Nothing h
      deliverHeld h [] "on_head" "HeadSeen" (headSeen "h2" "b2")
      findingsComments h `shouldReturn` []
      ((`atPath` ["pub", "phase"]) <$> memory h) `shouldReturn` str "blocked"
      commentHeldWith h [] "rec1" "recover_publication" "findings:h2:i2" True
      recovered <- memory h
      recovered `at` "pub" `shouldBe` obj [("phase", str "idle")]
      ids (recovered `at` "provisional") `shouldBe` [str "f-h1", str "f-h2"]
      deliverHeld h [] "on_head" "HeadSeen" (headSeen "h2" "b3")
      commentKeys' h `shouldReturn` ["findings:h2:i2"]
      (map (ids . (.body)) <$> findingsComments h) `shouldReturn` [[str "f-h1", str "f-h2"]]
      ((.agentCalls) <$> worldOf h) `shouldReturn` 2

    it "refresh with nothing provisional republishes nothing" $ do
      h <- spawn
      seeHeadWith h "h1" headArgs {seenBase = "b1"}
      seeHeadWith h "h1" headArgs {seenBase = "b2"}
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      commentKeys' h `shouldReturn` ["findings:h1:i1"]

    it "dismissed provisional findings never republish" $ do
      h <- spawnHeld
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h holdPublish "on_draft" "DraftSeen" (obj [])
      releaseOne h "publish_gate"
      ((`at` "provisional") <$> memory h) `shouldReturn` arr [findingH1]
      commentHeldWith h [] "dis1" "dismiss" "f-h1" True
      deliverHeld h [] "on_ready" "ReadySeen" (obj [])
      ((.agentCalls) <$> worldOf h) `shouldReturn` 2
      findingsComments h `shouldReturn` []
      ((`at` "reviewed") <$> memory h) `shouldReturn` texts ["h1"]

  describe "dismissal and close" $ do
    it "a dismiss that lost the race with close is never stranded" $ do
      h <- spawnHeld
      deliverHeld h holdPublish "on_head" "HeadSeen" (headSeen "h1" "b1")
      tokens h "review.memory" `shouldReturn` []
      commentHeldWith h holdPublish "d1" "dismiss" "f-h1" True
      (length <$> tokens h "review.dismiss") `shouldReturn` 1
      deliverHeld h holdPublish "on_close" "CloseSeen" (obj [("reason", str "merged")])
      releaseOne h "publish_gate"
      tokens h "review.dismiss" `shouldReturn` []
      [ended] <- tokens h "review.done"
      ended `at` "reason" `shouldBe` str "merged"

    it "dismissal cancels a retained blocked operation" $ do
      h <- spawn
      commentsMode (Just "retryable") h
      seeHead h "h1"
      ((`atPath` ["pub", "phase"]) <$> memory h) `shouldReturn` str "blocked"
      commentWith h "dis2" "dismiss" "f-h1" True
      state <- memory h
      state `atPath` ["pub", "phase"] `shouldBe` str "cancelled"
      state `atPath` ["pub", "op"] `shouldBe` str "findings:h1:i1"
      commentsMode Nothing h
      recover h "rec5" "findings:h1:i1"
      findingsComments h `shouldReturn` []
      ((.commentAttempts) <$> worldOf h) `shouldReturn` 3
      ((`atPath` ["pub", "phase"]) <$> memory h) `shouldReturn` str "cancelled"

    it "dismissal cancels a faulted operation and clears its fault" $ do
      h <- spawn
      commentsMode (Just "unknown") h
      seeHead h "h1"
      commentWith h "dis3" "dismiss" "f-h1" True
      ((`atPath` ["pub", "phase"]) <$> memory h) `shouldReturn` str "cancelled"
      (last <$> factsOf h "fault") `shouldReturn` obj [("where", str "review"), ("op", str "findings:h1:i1"), ("status", str "cancelled")]
      oneAt h "ready.snap" "faults" `shouldReturn` obj []
      oneAt h "ready.snap" "review" `shouldReturn` str "clear"
      (last <$> reviewFacts h) `shouldReturn` obj [("head", str "h1"), ("status", str "clear")]
      commentsMode Nothing h
      recover h "rec6" "findings:h1:i1"
      findingsComments h `shouldReturn` []

    it "dismissal recounts blocking findings for readiness" $ do
      h <- spawn
      seeHead h "h1"
      ((`at` "blocking") . last <$> findingsFacts h) `shouldReturn` int 1
      commentWith h "dis4" "dismiss" "f-h1" True
      fact <- last <$> findingsFacts h
      fact `at` "blocking" `shouldBe` int 0
      fact `at` "count" `shouldBe` int 1
      (last <$> reviewFacts h) `shouldReturn` obj [("head", str "h1"), ("status", str "clear")]

    it "dismissal after an unable round cannot reopen readiness" $ do
      h <- spawn
      seeHead h "h1"
      agentMode (Just "unable") h
      deliver h "on_draft" "DraftSeen" (obj [])
      deliver h "on_ready" "ReadySeen" (obj [])
      ((`at` "status") <$> memory h) `shouldReturn` str "unable"
      oneAt h "ready.snap" "review" `shouldReturn` str "unable"
      commentWith h "dis-unable" "dismiss" "f-h1" True
      ((`at` "status") <$> memory h) `shouldReturn` str "unable"
      oneAt h "ready.snap" "review" `shouldReturn` str "unable"

    it "predismissal of an unknown finding emits no current review evidence" $ do
      h <- spawn
      countsBefore <- (,) <$> (length <$> findingsFacts h) <*> (length <$> reviewFacts h)
      commentWith h "future" "dismiss" "not-yet-seen" True
      ((,) <$> (length <$> findingsFacts h) <*> (length <$> reviewFacts h)) `shouldReturn` countsBefore
      ((`at` "dismissed") <$> memory h) `shouldReturn` texts ["not-yet-seen"]

    it "resume after landing reviews again without duplicating reviewed" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_draft" "DraftSeen" (obj [])
      deliver h "on_ready" "ReadySeen" (obj [])
      ((.agentCalls) <$> worldOf h) `shouldReturn` 2
      commentKeys' h `shouldReturn` ["findings:h1:i1", "findings:h1:i2"]
      ((`at` "reviewed") <$> memory h) `shouldReturn` texts ["h1"]

    it "close retires the loop with its terminal record" $ do
      h <- spawn
      commentsMode (Just "retryable") h
      seeHead h "h1"
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      [done] <- tokens h "review.done"
      done `shouldBe` obj [("reviewed", texts ["h1"]), ("pub_phase", str "blocked"), ("reason", str "merged")]
      tokens h "review.memory" `shouldReturn` []

    it "close while the agent is in flight settles cleanly" $ do
      h <- spawnHeld
      deliverHeld h holdAgent "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h holdAgent "on_close" "CloseSeen" (obj [("reason", str "closed")])
      releaseOne h "review_agent"
      ((.agentCalls) <$> worldOf h) `shouldReturn` 0
      findingsComments h `shouldReturn` []
      [done] <- tokens h "review.done"
      done `at` "reason" `shouldBe` str "closed"
      done `at` "reviewed" `shouldBe` arr []
      tokens h "review.memory" `shouldReturn` []

  describe "seed refuses a noncanonical global subject" $
    forM_ ["", "bad\nsubject", "\233", T.replicate 901 "x"] $ \subject ->
      it (show (T.take 20 subject)) $
        case seedMarking subject of
          Left message -> T.unpack (pythonFailureText message) `shouldContain` "subject"
          Right _ -> expectationFailure "seed_marking accepted the subject"

  describe "live findings" $ do
    it "the open set is the last round minus dismissals" $
      liveFindings
        ( obj
            [ ("findings", arr [obj [("id", str "f01"), ("title", str "ttl"), ("blocking", Bool True)], obj [("id", str "f02"), ("title", str "approvals"), ("blocking", Bool True)]])
            , ("dismissed", texts ["f01"])
            ]
        )
        `shouldBe` Right [obj [("id", str "f02"), ("title", str "approvals"), ("blocking", Bool True)]]

    it "a memory without rounds yields an empty context" $
      liveFindings (obj []) `shouldBe` Right []
  where
    lookup' k = \case
      Object members -> lookup k members
      _ -> Nothing
    textOf = \case
      String t -> t
      other -> error (show other)
