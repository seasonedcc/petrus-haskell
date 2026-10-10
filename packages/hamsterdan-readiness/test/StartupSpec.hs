-- | @tests/unit/readiness/net_v5/test_startup.py@ (5 functions, 7 cases):
-- initial summary setup precedes effects without joining the update loop.
module StartupSpec (spec) where

import Control.Monad (forM_)
import Data.Set qualified as Set
import Harness
import Petrus.Json (Json (..))
import Test.Hspec

spec :: Spec
spec = describe "startup" $ do
  it "summary is the only activity until initial publication succeeds" $ do
    h <- spawnHeld
    let hold = ["dash_gate"]
    deliverHeld h hold "on_head" "HeadSeen" (obj [("head", str "h1"), ("base", str "b1"), ("mergeable", Bool True), ("policy", str "p1")])
    commentHeld h hold "question" "status"
    commentHeldWith h hold "repair" "change" "repair the code" True
    deliverHeld
      h
      hold
      "on_runs"
      "RunSeen"
      (obj [("head", str "h1"), ("run_id", int 1), ("attempt", int 1), ("conclusion", str "failure"), ("fingerprint", str "fp1")])
    requested h `shouldReturn` ["dash_gate"]
    w0 <- worldOf h
    w0.agentCalls `shouldBe` 0
    w0.comments `shouldBe` []
    w0.pushes `shouldBe` []
    w0.reruns `shouldBe` []

    releaseOne h "dash_gate"

    w <- worldOf h
    w.dashboard `shouldNotBe` []
    activities <- Set.fromList <$> requested h
    Set.fromList ["review_agent", "reply_gate", "git_gate", "rerun_gate"] `shouldSatisfy` (`Set.isSubsetOf` activities)
    w.pushes `shouldNotBe` []
    w.comments `shouldNotBe` []
    tokens h "startup.pending" `shouldReturn` []
    tokens h "startup.published" `shouldReturn` []

  forM_ ["retryable", "unknown"] $ \failure -> do
    it ("failed initial summary recovers before queued work starts [" <> show failure <> "]") $ do
      h <- spawn
      modifyWorld h (\w -> w {dashMode = Just failure})
      seeHead h "h1"
      comment h "question" "status"
      w0 <- worldOf h
      w0.agentCalls `shouldBe` 0
      w0.comments `shouldBe` []
      memory <- one h "dash.memory"
      let retained = if keys (memory `at` "blocked") /= [] then memory `at` "blocked" else memory `at` "faulted"
      tokens h "startup.pending" >>= (`shouldNotBe` [])

      modifyWorld h (\w -> w {dashMode = Nothing})
      let digest = case retained `at` "digest" of String d -> d; other -> error (show other)
      commentWith h "recover" "recover_publication" ("dash:" <> digest) True

      w <- worldOf h
      w.dashboard `shouldNotBe` []
      w.agentCalls `shouldBe` 1
      tokens h "startup.pending" `shouldReturn` []

    it ("later summary failure does not suspend reviews or replies [" <> show failure <> "]") $ do
      h <- spawn
      seeHead h "h1"
      initialBoard <- (.dashboard) <$> worldOf h
      modifyWorld h (\w -> w {dashMode = Just failure})

      seeHead h "h2"
      comment h "question" "status"

      w <- worldOf h
      w.dashboard `shouldBe` initialBoard
      w.agentCalls `shouldBe` 2
      any (\c -> c.key == "reply:question") w.comments `shouldBe` True
      tokens h "startup.pending" `shouldReturn` []

  it "close while initial summary is in flight never starts the agent" $ do
    h <- spawnHeld
    deliverHeld h ["dash_gate"] "on_head" "HeadSeen" (obj [("head", str "h1"), ("base", str "b1"), ("mergeable", Bool True), ("policy", str "p1")])
    deliverHeld h ["dash_gate"] "on_close" "CloseSeen" (obj [("reason", str "closed")])

    releaseOne h "dash_gate"

    ((.agentCalls) <$> worldOf h) `shouldReturn` 0
    ((`at` "reason") <$> one h "review.done") `shouldReturn` str "closed"

  it "initial draft defers startup until the PR is ready" $ do
    h <- spawn
    deliver h "on_draft" "DraftSeen" (obj [])
    seeHead h "h1"
    ((.dashboard) <$> worldOf h) `shouldReturn` []
    ((.agentCalls) <$> worldOf h) `shouldReturn` 0
    tokens h "startup.pending" >>= (`shouldNotBe` [])

    deliver h "on_ready" "ReadySeen" (obj [])

    ((.dashboard) <$> worldOf h) >>= (`shouldNotBe` [])
    ((.agentCalls) <$> worldOf h) `shouldReturn` 1
    tokens h "startup.pending" `shouldReturn` []
