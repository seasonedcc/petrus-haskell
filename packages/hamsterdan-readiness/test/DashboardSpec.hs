-- | @tests/unit/readiness/net_v5/test_dashboard_loop.py@ (16 functions,
-- 17 cases: the dormant-recovery test is parametrized over
-- retryable/blocked and unknown/faulted): the dashboard loop.
module DashboardSpec (spec) where

import Control.Monad (forM_)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Harness
import Petrus.Json (Json (..))
import Test.Hspec

memory :: H -> IO Json
memory h = one h "dash.memory"

board :: H -> IO [Text]
board h = (.dashboard) <$> worldOf h

upserts :: H -> IO [Text]
upserts h = (\w -> [d | ("dash", d) <- w.log]) <$> worldOf h

-- | EVERY upsert the gate ever saw — landed, blocked, or faulted.
attempts :: H -> IO [Json]
attempts h = map request . (.dashRequests) <$> worldOf h
  where
    request (entries, digest) = obj [("entries", texts entries), ("digest", str digest)]

seeHuman :: H -> IO ()
seeHuman h = deliver h "on_human" "HumanSeen" (obj [("approval", Bool True), ("changes_requested", Bool False), ("unresolved", int 0)])

seeChanges :: H -> IO ()
seeChanges h = deliver h "on_human" "HumanSeen" (obj [("approval", Bool False), ("changes_requested", Bool True), ("unresolved", int 1)])

items :: Json -> [Json]
items = \case
  Array xs -> xs
  _ -> []

textItems :: Json -> [Text]
textItems v = [t | String t <- items v]

textOf :: Json -> Text
textOf = \case
  String t -> t
  other -> error ("not text: " <> show other)

phaseTo :: Text -> World -> World
phaseTo phase w = w {authority = (w.authority) {phase}}

noFindings :: World -> World
noFindings w = w {agentFindings = Map.insert "h1" [] w.agentFindings}

headH1 :: Json
headH1 = obj [("head", str "h1"), ("base", str "b1"), ("mergeable", Bool True), ("policy", str "p1")]

spec :: Spec
spec = describe "dashboard loop" $ do
  describe "board" $ do
    it "facts land on the board as one projection" $ do
      h <- spawn
      seeHead h "h1"
      state <- memory h
      textItems (state `at` "entries") `shouldNotBe` []
      board h `shouldReturn` textItems (state `at` "entries")
      state `at` "digest" `shouldBe` state `at` "landed"
      state `at` "blocked" `shouldBe` obj []
      state `at` "faulted" `shouldBe` obj []

    it "a dormant board retains desired state and publishes after resume" $ do
      h <- spawn
      modifyWorld h (phaseTo "quiescent")
      seeHuman h
      deferred <- memory h
      textItems (deferred `at` "entries") `shouldNotBe` []
      deferred `at` "landed" `shouldBe` str ""
      deferred `at` "blocked" `shouldBe` obj []
      deferred `at` "faulted" `shouldBe` obj []
      board h `shouldReturn` []
      upserts h `shouldReturn` []
      modifyWorld h (phaseTo "running")
      seeChanges h
      landed <- memory h
      board h `shouldReturn` textItems (landed `at` "entries")
      landed `at` "digest" `shouldBe` landed `at` "landed"

    it "a healthy board preserves what landed while draft defers new state" $ do
      h <- spawn
      seeHead h "h1"
      shown <- board h
      landedDigest <- (`at` "landed") <$> memory h
      modifyWorld h (phaseTo "quiescent")
      seeHuman h
      deferred <- memory h
      board h `shouldReturn` shown
      deferred `at` "landed" `shouldBe` landedDigest
      deferred `at` "digest" `shouldNotBe` deferred `at` "landed"

    it "an identical consecutive fact republishes nothing" $ do
      h <- spawn
      seeHead h "h1"
      seeRunWith h runArgs {runId = 1, runConclusion = "success"}
      seen <- length <$> upserts h
      logged <- (`at` "entries") <$> memory h
      seeRunWith h runArgs {runId = 2, runConclusion = "success"}
      (length <$> upserts h) `shouldReturn` seen
      ((`at` "entries") <$> memory h) `shouldReturn` logged

    it "the board is serialized by the held baton" $ do
      h <- spawnHeld
      deliverHeld h ["dash_gate"] "on_head" "HeadSeen" headH1
      tokens h "dash.memory" `shouldReturn` []
      (length <$> pendingWork h "dash_gate") `shouldReturn` 1
      releaseOne h "dash_gate"
      state <- memory h
      state `at` "digest" `shouldBe` state `at` "landed"
      board h `shouldReturn` textItems (state `at` "entries")

  describe "blocked and recovery" $ do
    forM_ [("retryable", "blocked"), ("unknown", "faulted")] $ \(mode, held) ->
      it ("dormant recovery preserves exact custody until a running retry [" <> T.unpack mode <> "-" <> T.unpack held <> "]") $ do
        h <- spawn
        modifyWorld h (\w -> w {dashMode = Just mode})
        seeHead h "h1"
        retained <- (`at` held) <$> memory h
        modifyWorld h (\w -> phaseTo "quiescent" w {dashMode = Nothing})
        commentWith h "c1" "recover_publication" ("dash:" <> textOf (retained `at` "digest")) True
        deferred <- memory h
        deferred `at` held `shouldBe` retained
        deferred `at` (if held == "faulted" then "blocked" else "faulted") `shouldBe` obj []
        board h `shouldReturn` []
        modifyWorld h (phaseTo "running")
        commentWith h "c2" "recover_publication" ("dash:" <> textOf (retained `at` "digest")) True
        settled <- memory h
        settled `at` "blocked" `shouldBe` obj []
        settled `at` "faulted" `shouldBe` obj []
        board h `shouldReturn` textItems (settled `at` "entries")

    it "retryable exhaustion blocks and accumulates fail-closed" $ do
      h <- spawn
      modifyWorld h (\w -> noFindings w {dashMode = Just "retryable"})
      seeHead h "h1"
      seeRunWith h runArgs {runId = 1, runConclusion = "success"}
      seeHuman h
      state <- memory h
      keys (state `at` "blocked") `shouldNotBe` []
      state `at` "landed" `shouldBe` str ""
      let accumulated = textItems (state `at` "entries")
      length accumulated `shouldSatisfy` (>= 3)
      length (items (state `atPath` ["blocked", "entries"])) `shouldSatisfy` (< length accumulated)
      board h `shouldReturn` []
      let retained = state `at` "blocked"
      attemptCount <- length <$> attempts h
      ((.agentCalls) <$> worldOf h) `shouldReturn` 0
      modifyWorld h (\w -> w {dashMode = Nothing})
      commentWith h "c1" "recover_publication" ("dash:" <> textOf (retained `at` "digest")) True
      after' <- memory h
      after' `at` "blocked" `shouldBe` obj []
      after' `at` "faulted" `shouldBe` obj []
      seen <- attempts h
      seen !! attemptCount `shouldBe` retained
      textItems ((seen !! (attemptCount + 1)) `at` "entries") `shouldBe` accumulated
      shown <- board h
      take (length accumulated) shown `shouldBe` accumulated
      shown `shouldBe` textItems (after' `at` "entries")
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1

    it "unknown terminal retains exact effect and recovers once" $ do
      h <- spawn
      modifyWorld h (\w -> noFindings w {dashMode = Just "unknown"})
      seeHead h "h1"
      state <- memory h
      state `atPath` ["faulted", "reason"] `shouldBe` str "unknown provider terminal"
      let digest = textOf (state `atPath` ["faulted", "digest"])
          desired = textItems (state `at` "entries")
      digest `shouldNotBe` ""
      board h `shouldReturn` []
      ((.agentCalls) <$> worldOf h) `shouldReturn` 0
      modifyWorld h (\w -> w {dashMode = Nothing})
      commentWith h "c1" "recover_publication" ("dash:" <> digest) True
      after' <- memory h
      after' `at` "faulted" `shouldBe` obj []
      after' `at` "blocked" `shouldBe` obj []
      shown <- board h
      take (length desired) shown `shouldBe` desired
      shown `shouldBe` textItems (after' `at` "entries")
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      (length . filter (== digest) <$> upserts h) `shouldReturn` 1

    it "recovery reissues the exact request then self-heals" $ do
      h <- spawn
      modifyWorld h (\w -> noFindings w {dashMode = Just "unknown"})
      seeHead h "h1"
      state <- memory h
      let exact = state `at` "faulted"
          desiredBefore = textItems (state `at` "entries")
      items (exact `at` "entries") `shouldNotBe` []
      exact `at` "digest" `shouldNotBe` str ""
      length desiredBefore `shouldSatisfy` (> length (items (exact `at` "entries")))
      attemptCount <- length <$> attempts h
      ((.agentCalls) <$> worldOf h) `shouldReturn` 0
      modifyWorld h (\w -> w {dashMode = Nothing})
      commentWith h "c1" "recover_publication" ("dash:" <> textOf (exact `at` "digest")) True
      landed <- upserts h
      take 1 landed `shouldBe` [textOf (exact `at` "digest")]
      length (filter (== textOf (exact `at` "digest")) landed) `shouldBe` 1
      seen <- attempts h
      seen !! attemptCount `shouldBe` obj [("entries", exact `at` "entries"), ("digest", exact `at` "digest")]
      textItems ((seen !! (attemptCount + 1)) `at` "entries") `shouldBe` desiredBefore
      (take (length desiredBefore) <$> board h) `shouldReturn` desiredBefore
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1
      after' <- memory h
      after' `at` "faulted" `shouldBe` obj []
      after' `at` "blocked" `shouldBe` obj []
      after' `at` "digest" `shouldBe` after' `at` "landed"

    it "cyclic drift back to the retained digest still heals" $ do
      h <- spawn
      seeHead h "h1"
      modifyWorld h (\w -> w {dashMode = Just "unknown"})
      seeHuman h
      exact <- (`at` "faulted") <$> memory h
      exact `at` "digest" `shouldNotBe` str ""
      seeChanges h
      seeHuman h
      state <- memory h
      state `at` "digest" `shouldBe` exact `at` "digest"
      let desired = textItems (state `at` "entries")
      length desired `shouldSatisfy` (> length (items (exact `at` "entries")))
      modifyWorld h (\w -> w {dashMode = Nothing})
      commentWith h "c1" "recover_publication" ("dash:" <> textOf (exact `at` "digest")) True
      seen <- attempts h
      seen !! (length seen - 2) `shouldBe` obj [("entries", exact `at` "entries"), ("digest", exact `at` "digest")]
      last seen `shouldBe` obj [("entries", texts desired), ("digest", exact `at` "digest")]
      board h `shouldReturn` desired
      after' <- memory h
      after' `at` "faulted" `shouldBe` obj []
      after' `at` "blocked" `shouldBe` obj []
      after' `at` "digest" `shouldBe` after' `at` "landed"

    it "a wrong recovery op is inert" $ do
      h <- spawn
      modifyWorld h (\w -> w {dashMode = Just "unknown"})
      seeHead h "h1"
      held <- (`at` "faulted") <$> memory h
      modifyWorld h (\w -> w {dashMode = Nothing})
      commentWith h "c1" "recover_publication" "dash:not-the-digest" True
      ((`at` "faulted") <$> memory h) `shouldReturn` held
      board h `shouldReturn` []

    it "recovery with nothing held is inert" $ do
      h <- spawn
      seeHead h "h1"
      upsertsBefore <- length <$> upserts h
      commentWith h "c1" "recover_publication" "dash:anything" True
      state <- memory h
      state `at` "blocked" `shouldBe` obj []
      state `at` "faulted" `shouldBe` obj []
      (length <$> upserts h) `shouldReturn` upsertsBefore

  describe "close" $ do
    it "close retires the board with the final record" $ do
      h <- spawn
      seeHead h "h1"
      final <- textItems . (`at` "entries") <$> memory h
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      tokens h "dash.memory" `shouldReturn` []
      done <- one h "dash.done"
      done `at` "reason" `shouldBe` str "merged"
      take (length final) (textItems (done `at` "entries")) `shouldBe` final

    it "post-close mail is recorded, never published" $ do
      h <- spawn
      seeHead h "h1"
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      frozen <- board h
      recorded <- length . items . (`at` "entries") <$> one h "dash.done"
      modifyWorld h (\w -> w {commentsMode = Just "unknown"})
      comment h "c9" "status"
      board h `shouldReturn` frozen
      done <- one h "dash.done"
      length (items (done `at` "entries")) `shouldSatisfy` (> recorded)
      any (T.isPrefixOf "fault:") (textItems (done `at` "entries")) `shouldBe` True
      tokens h "dash.facts" `shouldReturn` []

    it "close waits for the in-flight upsert and settles once" $ do
      h <- spawnHeld
      deliverHeld h ["dash_gate"] "on_head" "HeadSeen" headH1
      deliverHeld h ["dash_gate"] "on_close" "CloseSeen" (obj [("reason", str "merged")])
      tokens h "dash.done" `shouldReturn` []
      releaseOne h "dash_gate"
      [done] <- tokens h "dash.done"
      done `at` "reason" `shouldBe` str "merged"
      tokens h "dash.memory" `shouldReturn` []
      tokens h "dash.facts" `shouldReturn` []
      tokens h "dash.heal" `shouldReturn` []
      board h >>= (`shouldNotBe` [])

    it "close racing the self-heal strands nothing" $ do
      h <- spawnHeld
      let hold = ["dash_gate"]
      modifyWorld h noFindings
      deliverHeld h hold "on_head" "HeadSeen" headH1
      releaseOne h "dash_gate"
      modifyWorld h (\w -> w {dashMode = Just "unknown"})
      deliverHeld h hold "on_human" "HumanSeen" (obj [("approval", Bool True), ("changes_requested", Bool False), ("unresolved", int 0)])
      releaseOne h "dash_gate"
      exact <- (`at` "faulted") <$> memory h
      exact `at` "digest" `shouldNotBe` str ""
      deliverHeld h hold "on_human" "HumanSeen" (obj [("approval", Bool False), ("changes_requested", Bool True), ("unresolved", int 1)])
      desired <- textItems . (`at` "entries") <$> memory h
      length desired `shouldSatisfy` (> length (items (exact `at` "entries")))
      modifyWorld h (\w -> w {dashMode = Nothing})
      commentHeldWith h hold "c1" "recover_publication" ("dash:" <> textOf (exact `at` "digest")) True
      deliverHeld h hold "on_close" "CloseSeen" (obj [("reason", str "closed")])
      tokens h "dash.done" `shouldReturn` []
      releaseOne h "dash_gate"
      [done] <- tokens h "dash.done"
      done `at` "reason" `shouldBe` str "closed"
      forM_ ["dash.memory", "dash.heal", "dash.pub_req", "dash.facts", "dash.recover"] $ \place ->
        tokens h place `shouldReturn` []
      seen <- attempts h
      seen `shouldContain` [obj [("entries", exact `at` "entries"), ("digest", exact `at` "digest")]]
      take (length desired) (textItems (done `at` "entries")) `shouldBe` desired
