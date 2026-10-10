-- | @tests/unit/readiness/net_v5/test_conversation_loop.py@ (21 functions,
-- 21 cases): the conversation loop.
module ConversationSpec (spec) where

import Data.List (sortOn)
import Data.Text (Text)
import Harness
import Petrus.Activity (ActivityInvocation (..))
import Petrus.Json (Json (..))
import Test.Hspec

memory :: H -> IO Json
memory h = one h "conv.memory"

replies :: World -> [Comment]
replies w = [c | c <- w.comments, c.kind == "reply"]

-- | @reply_texts(world)@, compared as a dict (order-insensitive).
replyTexts :: H -> IO [(Text, Json)]
replyTexts h = sortOn fst . map (\c -> (c.key, c.body)) . replies <$> worldOf h

replyText :: H -> Text -> IO Json
replyText h k = maybe (error ("no reply " <> show k)) id . lookup k <$> replyTexts h

nothingNew, cannotAct, closed :: Json
nothingNew = str "Nothing new to report \8212 the summary comment is current."
cannotAct = str "I can't act on that \8212 nothing in the workflow changed."
closed = str "This PR is closed \8212 nothing changes here anymore."

priorReply :: Json -> Comment
priorReply body = Comment {key = "reply:c1", kind = "reply", head = "", body}

headH1 :: Json
headH1 = obj [("head", str "h1"), ("base", str "b1"), ("mergeable", Bool True), ("policy", str "p1")]

spec :: Spec
spec = describe "conversation loop" $ do
  describe "classification" $ do
    it "a pure intent is answered and served once" $ do
      h <- spawn
      seeHead h "h1"
      comment h "c1" "status"
      replyTexts h `shouldReturn` [("reply:c1", nothingNew)]
      state <- memory h
      state `at` "served" `shouldBe` texts ["c1"]
      state `at` "pending" `shouldBe` obj []

    it "a duplicate comment identity is served once" $ do
      h <- spawn
      seeHead h "h1"
      comment h "c1" "status"
      comment h "c1" "status"
      (length . replies <$> worldOf h) `shouldReturn` 1
      ((`at` "served") <$> memory h) `shouldReturn` texts ["c1"]

    it "an unauthorized command routes no side effect" $ do
      h <- spawn
      seeHead h "h1"
      commentWith h "c1" "change" "" False
      ((.pushes) <$> worldOf h) `shouldReturn` []
      tokens h "mut.requests" `shouldReturn` []
      replyTexts h `shouldReturn` [("reply:c1", cannotAct)]

    it "an unknown kind gets the no-change reply" $ do
      h <- spawn
      seeHead h "h1"
      comment h "c1" "make-coffee"
      replyTexts h `shouldReturn` [("reply:c1", cannotAct)]

    it "a pure intent is answered even after close" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      comment h "c1" "reply"
      replyTexts h `shouldReturn` [("reply:c1", nothingNew)]

  describe "note intents" $ do
    it "dismiss routes the finding to review" $ do
      h <- spawn
      seeHead h "h1"
      commentWith h "c1" "dismiss" "f-h1" True
      replyText h "reply:c1" `shouldReturn` str "Noted \8212 that finding is dismissed."
      oneAt h "review.memory" "dismissed" `shouldReturn` texts ["f-h1"]

    it "snooze and resume mail reminders while defer disposes review finding" $ do
      h <- spawn
      seeHead h "h1"
      commentWith h "c1" "snooze" "t1" True
      commentWith h "c2" "resume" "t1" True
      commentWith h "c3" "defer" "t2" True
      oneAt h "rem.state" "snoozed" `shouldReturn` Bool False
      oneAt h "review.memory" "dismissed" `shouldReturn` texts ["t2"]

    it "a note intent in terminal phase is declined" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      commentWith h "c1" "dismiss" "f-h1" True
      replyText h "reply:c1" `shouldReturn` closed
      tokens h "review.dismiss" `shouldReturn` []

    it "recover publication routes by operation prefix" $ do
      h <- spawn
      modifyWorld h (\w -> w {commentsMode = Just "retryable"})
      seeHead h "h1"
      ((`atPath` ["pub", "phase"]) <$> memory' h) `shouldReturn` str "blocked"
      modifyWorld h (\w -> w {commentsMode = Nothing})
      commentWith h "c1" "recover_publication" "findings:h1:i1" True
      oneAt h "review.memory" "pub" `shouldReturn` obj [("phase", str "idle")]
      w <- worldOf h
      [c.key | c <- w.comments, c.kind == "findings"] `shouldBe` ["findings:h1:i1"]
      replyText h "reply:c1" `shouldReturn` str "On it \8212 I'm retrying that publication now."

    it "recover publication with an unknown prefix is declined" $ do
      h <- spawn
      seeHead h "h1"
      commentWith h "c1" "recover_publication" "bogus:xyz" True
      replyText h "reply:c1" `shouldReturn` str "I don't recognize that operation, so I can't recover it."

  describe "committing intents" $ do
    it "change mails a full claim under the comment identity" $ do
      h <- spawn
      seeHead h "h1"
      comment h "c1" "change"
      ((.pushes) <$> worldOf h) `shouldReturn` [Push {key = "push:comment:c1:h1:i1", op = "change", from = "h1", to = "h1+change"}]
      replyText h "reply:c1" `shouldReturn` str "On it \8212 I'm making that change and will push to this PR."

    it "a committing intent outside running is declined" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_draft" "DraftSeen" (obj [])
      comment h "c1" "change"
      ((.pushes) <$> worldOf h) `shouldReturn` []
      tokens h "mut.requests" `shouldReturn` []
      replyText h "reply:c1" `shouldReturn` str "This PR is a draft \8212 I hold changes until it's ready for review."

    it "a committing intent under a provisional head is declined" $ do
      h <- spawn
      seeHead h "h1"
      comment h "c1" "change"
      oneAt h "life.state" "expected" `shouldReturn` str "h1+change"
      comment h "c2" "update_base"
      replyText h "reply:c2" `shouldReturn` str "My own update is still landing \8212 ask again once it settles."
      (length . (.pushes) <$> worldOf h) `shouldReturn` 1
      seeHead h "h1+change"
      comment h "c3" "update_base"
      replyText h "reply:c3" `shouldReturn` str "On it \8212 I'm updating this branch from its base."
      (length . (.pushes) <$> worldOf h) `shouldReturn` 2

    it "a committing intent after close is declined" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      comment h "c1" "change"
      ((.pushes) <$> worldOf h) `shouldReturn` []
      replyText h "reply:c1" `shouldReturn` closed

  describe "reply gate" $ do
    it "lookup-first: a reply already held never posts twice" $ do
      h <- spawn
      seeHead h "h1"
      modifyWorld h (\w -> w {comments = w.comments ++ [priorReply nothingNew]})
      comment h "c1" "status"
      (length . replies <$> worldOf h) `shouldReturn` 1
      ((`at` "pending") <$> memory h) `shouldReturn` obj []

    it "retryable exhaustion blocks and retains the text" $ do
      h <- spawn
      seeHead h "h1"
      modifyWorld h (\w -> w {commentsMode = Just "retryable"})
      comment h "c1" "status"
      state <- memory h
      state `at` "blocked" `shouldBe` obj [("c1", nothingNew)]
      state `at` "pending" `shouldBe` obj []
      (replies <$> worldOf h) `shouldReturn` []
      modifyWorld h (\w -> w {commentsMode = Nothing})
      commentWith h "c2" "recover_publication" "reply:c1" True
      replyText h "reply:c1" `shouldReturn` nothingNew
      after' <- memory h
      after' `at` "blocked" `shouldBe` obj []
      after' `at` "pending" `shouldBe` obj []

    it "unknown terminal faults and recovery reconciles lookup-first" $ do
      h <- spawn
      seeHead h "h1"
      modifyWorld h (\w -> w {commentsMode = Just "unknown"})
      comment h "c1" "status"
      state <- memory h
      state `at` "faulted" `shouldBe` obj [("c1", obj [("text", nothingNew), ("reason", str "unknown provider terminal")])]
      [fault] <- factsOf h "fault"
      fault
        `shouldBe` obj
          [ ("where", str "conversation")
          , ("op", str "reply:c1")
          , ("status", str "faulted")
          , ("reason", str "unknown provider terminal")
          ]
      modifyWorld h (\w -> w {commentsMode = Nothing, comments = w.comments ++ [priorReply nothingNew]})
      commentWith h "c2" "recover_publication" "reply:c1" True
      (length . replies <$> worldOf h) `shouldReturn` 2
      ((`at` "faulted") <$> memory h) `shouldReturn` obj []
      resolutions <- factsOf h "fault"
      last resolutions `shouldBe` obj [("where", str "conversation"), ("op", str "reply:c1"), ("status", str "resolved")]

    it "recovery is single-flight per identity" $ do
      h <- spawnHeld
      deliverHeld h [] "on_head" "HeadSeen" headH1
      modifyWorld h (\w -> w {commentsMode = Just "unknown"})
      commentHeld h [] "c1" "status"
      (keys . (`at` "faulted") <$> memory h) >>= (`shouldContain` ["c1"])
      modifyWorld h (\w -> w {commentsMode = Nothing})
      commentHeldWith h ["reply_gate"] "r1" "recover_publication" "reply:c1" True
      commentHeldWith h ["reply_gate"] "r2" "recover_publication" "reply:c1" True
      reissues <- filter (\i -> i.input `atPath` ["work", "id"] == str "c1") <$> pendingWork h "reply_gate"
      length reissues `shouldBe` 1

    it "a reply identity collision with different text fails closed" $ do
      h <- spawn
      seeHead h "h1"
      modifyWorld h (\w -> w {comments = w.comments ++ [priorReply (str "something else")]})
      comment h "c1" "status"
      ((`atPath` ["faulted", "c1", "reason"]) <$> memory h) `shouldReturn` str "effect identity collision: reply:c1"
      replyText h "reply:c1" `shouldReturn` str "something else"

    it "recovery for an unknown reply is inert" $ do
      h <- spawn
      seeHead h "h1"
      beforeServed <- (`at` "served") <$> memory h
      commentWith h "c1" "recover_publication" "reply:zz" True
      state <- memory h
      state `at` "blocked" `shouldBe` obj []
      state `at` "faulted" `shouldBe` obj []
      state `at` "served" `shouldBe` arr (items beforeServed ++ [str "c1"])

    it "replies are concurrent per-id custody" $ do
      h <- spawnHeld
      deliverHeld h [] "on_head" "HeadSeen" headH1
      commentHeld h ["reply_gate"] "c1" "status"
      commentHeld h ["reply_gate"] "c2" "reply"
      ((`at` "pending") <$> memory h) `shouldReturn` obj [("c1", nothingNew), ("c2", nothingNew)]
      (length <$> pendingWork h "reply_gate") `shouldReturn` 2
  where
    memory' h = one h "review.memory"
    items = \case
      Array xs -> xs
      _ -> []
