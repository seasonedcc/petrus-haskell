{-# LANGUAGE AllowAmbiguousTypes #-}

-- | @tests/unit/readiness/net_v5/test_readiness_loop.py@ (38 functions,
-- 38 cases): the readiness loop.
module ReadinessSpec (spec) where

import Control.Monad (forM_)
import Data.Maybe (fromMaybe)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Harness
import Hamsterdan.Contracts.Codec (Contract, dump, renderDecodeError, validate)
import Hamsterdan.Contracts.ReadinessV5 qualified as C
import Hamsterdan.Readiness.NetV5.Readiness (applyMutationPending, applyMutationSettled, applyState)
import Hamsterdan.Readiness.NetV5.Topology (buildNetV5)
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.Petrinet.Schema (Arc (..), Place (..), arcModeText, netArcs, netPathText, netPlaces, netTransitionOrder)
import Petrus.Json (Json (..))
import Test.Hspec

blocker :: Text
blocker = "2c60edc8-6ba8-4cd7-bd89-e1638d70329d"

snap :: H -> IO Json
snap h = one h "ready.snap"

announcements :: H -> IO [Text]
announcements h = (\w -> [c.key | c <- w.comments, c.kind == "ready"]) <$> worldOf h

seeHuman :: H -> Bool -> Bool -> Integer -> IO ()
seeHuman h approval changes unresolved =
  deliver h "on_human" "HumanSeen" (obj [("approval", Bool approval), ("changes_requested", Bool changes), ("unresolved", int unresolved)])

approve :: H -> IO ()
approve h = seeHuman h True False 0

noFindings :: Text -> H -> IO ()
noFindings headSha h = modifyWorld h (\w -> w {agentFindings = Map.insert headSha [] w.agentFindings})

goReady :: H -> IO ()
goReady h = do
  noFindings "h1" h
  seeHead h "h1"
  seeRun h
  approve h

runOf :: Text -> Integer -> RunArgs
runOf headSha rid = runArgs {runHead = headSha, runId = rid}

headSeen :: Text -> Text -> Json
headSeen headSha base = obj [("head", str headSha), ("base", str base), ("mergeable", Bool True), ("policy", str "p1")]

runSeen :: Text -> Integer -> Json
runSeen headSha rid = obj [("head", str headSha), ("run_id", int rid), ("attempt", int 1), ("conclusion", str "success"), ("fingerprint", str "")]

commentSeen :: Text -> Text -> Json
commentSeen cid kind = obj [("id", str cid), ("kind", str kind), ("arg", str ""), ("authorized", Bool True)]

humanSeen :: Json
humanSeen = obj [("approval", Bool True), ("changes_requested", Bool False), ("unresolved", int 0)]

-- | @Model(**fields)@: validate through the contract, as Python constructs.
model :: forall a. (Contract a) => Json -> a
model raw = either (error . T.unpack . renderDecodeError) id (validate @a raw)

-- | @Model(**fields).dump()@.
dumped :: forall a. (Contract a) => Json -> Json
dumped = dump . model @a

-- | @AWake(**deferred).dump()@.
awake :: Json -> Json
awake = dumped @C.AWake

faultKeys :: Text -> Json -> [Text]
faultKeys prefix state = filter (T.isPrefixOf prefix) (keys (state `at` "faults"))

baseSnapshot :: C.Snapshot
baseSnapshot =
  model @C.Snapshot $
    obj
      [ ("incarnation", int 1)
      , ("phase", str "running")
      , ("head", str "h1")
      , ("base", str "b1")
      , ("policy", str "p1")
      , ("mergeable", Bool True)
      , ("checks", str "success")
      , ("review", str "clear")
      , ("findings_blocking", int 0)
      , ("approval", Bool True)
      , ("changes_requested", Bool False)
      , ("unresolved", int 0)
      , ("pending", arr [])
      , ("faults", obj [])
      , ("announced", arr [])
      , ("candidate", Bool False)
      , ("announcing", obj [])
      , ("blocked", obj [])
      , ("strict_base", Bool True)
      , ("base_current", Bool True)
      , ("closing", Null)
      ]

keyA, keyB :: Text
keyA = "push:comment:c1:h1:i1"
keyB = "push:comment:c2:h1:i1"

pendingFact :: Integer -> Text -> C.MutationPendingFact
pendingFact inc key = model (obj [("incarnation", int inc), ("body", obj [("op", str "change"), ("op_key", str key)])])

settledFact :: Integer -> Text -> Text -> C.MutationSettledFact
settledFact inc key outcome =
  model
    ( obj
        [ ("incarnation", int inc)
        , ("body", obj [("op", str "change"), ("op_key", str key), ("outcome", str outcome), ("fingerprint", str ""), ("incarnation", int inc)])
        ]
    )

data Apply = Pending C.MutationPendingFact | Settled C.MutationSettledFact

applyOne :: C.Snapshot -> Apply -> C.Snapshot
applyOne s step = fromMaybe s applied
 where
  applied = case step of
    Pending fact -> applyMutationPending s fact
    Settled fact -> applyMutationSettled s fact

built :: BuiltNet
built = either (error . show) id buildNetV5

spec :: Spec
spec = describe "readiness loop" $ do
  it "readiness fact kinds are explicit topology" $ do
    let net = built.net
        places = Map.fromList [(netPathText path, pl.color) | (path, pl) <- Map.toList (netPlaces net)]
        transitions = map netPathText (netTransitionOrder net)
        arcs = netArcs net
        factColors =
          [ ("state", "StateFact")
          , ("checks", "ChecksFact")
          , ("review", "ReviewFact")
          , ("findings", "FindingsFact")
          , ("human", "HumanFact")
          , ("mutation_pending", "MutationPendingFact")
          , ("mutation_settled", "MutationSettledFact")
          , ("fault_raised", "FaultRaisedFact")
          , ("fault_cleared", "FaultClearedFact")
          ]
    Map.member "ready.facts" places `shouldBe` True
    any (\a -> netPathText a.target == "ready.facts") arcs `shouldBe` False
    forM_ factColors $ \(kind, color) -> do
      let mailbox = "ready." <> kind <> "_facts"
          foldT = "ready.fold_" <> kind
      Map.lookup mailbox places `shouldBe` Just (Just color)
      transitions `shouldContain` [foldT]
      transitions `shouldContain` ["ready.migrate_" <> kind]
      any (\a -> netPathText a.source == mailbox && netPathText a.target == foldT && arcModeText a.mode == "consume") arcs
        `shouldBe` True

  it "legacy gate fact mailbox migrates every supported kind" $ do
    let fact kind inc body = ("ready.facts", "GateFact", dumped @C.GateFact (obj [("kind", str kind), ("incarnation", int inc), ("body", obj body)]))
        legacy =
          [ fact "state" 1 [("phase", str "running"), ("head", str "h1"), ("base", str "b1"), ("mergeable", Bool True), ("policy", str "p1"), ("strict_base", Bool True), ("base_current", Bool True)]
          , fact "checks" 1 [("status", str "success")]
          , fact "review" 1 [("head", str "h1"), ("status", str "clear")]
          , fact "findings" 1 [("head", str "h1"), ("blocking", int 0), ("count", int 0)]
          , fact "human" 1 [("approval", Bool True), ("changes_requested", Bool False), ("unresolved", int 0)]
          , fact "mutation_pending" 1 [("op", str "change"), ("op_key", str "mutation-a")]
          , fact "mutation_settled" 1 [("op", str "change"), ("op_key", str "mutation-a"), ("outcome", str "landed"), ("incarnation", int 1), ("fingerprint", str "")]
          , fact "fault" 0 [("where", str "mutation"), ("op", str "fault-a"), ("reason", str "unknown")]
          , fact "fault" 0 [("where", str "mutation"), ("op", str "fault-b"), ("status", str "resolved")]
          ]
    h <- spawnWith "pr-v5" freshWorld legacy
    drive h
    state <- snap h
    state `at` "incarnation" `shouldBe` int 1
    state `at` "checks" `shouldBe` str "success"
    state `at` "review" `shouldBe` str "clear"
    state `at` "findings_blocking" `shouldBe` int 0
    state `at` "approval" `shouldBe` Bool True
    state `at` "pending" `shouldBe` arr []
    state `at` "faults" `shouldBe` obj [("mutation:fault-a", str "unknown")]
    tokens h "ready.facts" `shouldReturn` []

  describe "announce" $ do
    it "announces exactly once when every gate passes" $ do
      h <- spawn
      goReady h
      announcements h `shouldReturn` ["ready:h1:i1"]
      st <- snap h
      st `at` "announced" `shouldBe` arr [int 1]
      st `at` "announcing" `shouldBe` obj []

    it "no announce before every predicate component" $ do
      h <- spawn
      noFindings "h1" h
      seeHead h "h1"
      announcements h `shouldReturn` []
      seeRun h
      announcements h `shouldReturn` []
      approve h
      announcements h `shouldReturn` ["ready:h1:i1"]

    it "blocking findings hold readiness until dismissed" $ do
      h <- spawn
      seeHead h "h1"
      seeRun h
      approve h
      announcements h `shouldReturn` []
      ((`at` "findings_blocking") <$> snap h) `shouldReturn` int 1
      commentWith h "c1" "dismiss" "f-h1" True
      ((`at` "findings_blocking") <$> snap h) `shouldReturn` int 0
      announcements h `shouldReturn` ["ready:h1:i1"]

    it "agent inability stays not ready after every other gate passes" $ do
      h <- spawn
      modifyWorld h (\w -> w {agentMode = Just "unable"})
      seeHead h "h1"
      seeRun h
      approve h
      ((`at` "review") <$> snap h) `shouldReturn` str "unable"
      announcements h `shouldReturn` []

    it "unstaged custody wakes the exact announcement without human recovery" $ do
      h <- spawn
      modifyWorld h (\w -> w {announceBlocker = Just blocker})
      goReady h
      [deferred] <- tokens h "ready.deferred"
      deferred
        `shouldBe` obj
          [ ("op", str "ready:h1:i1")
          , ("incarnation", int 1)
          , ("head", str "h1")
          , ("base", str "b1")
          , ("policy", str "p1")
          , ("strict_base", Bool True)
          , ("base_current", Bool True)
          , ("blocker", str blocker)
          ]
      ((`at` "announcing") <$> snap h) `shouldReturn` without ["blocker"] deferred
      announcements h `shouldReturn` []
      modifyWorld h (\w -> w {announceBlocker = Nothing})
      deliver h "on_announce_wake" "AWake" (awake deferred)
      tokens h "ready.deferred" `shouldReturn` []
      announcements h `shouldReturn` ["ready:h1:i1"]
      ((`at` "announced") <$> snap h) `shouldReturn` arr [int 1]

    it "mutation pending fact wins before a deferred announcement wakes" $ do
      h <- spawn
      modifyWorld h (\w -> w {announceBlocker = Just blocker})
      goReady h
      [deferred] <- tokens h "ready.deferred"
      modifyWorld h (\w -> w {gitMode = Just "fault"})
      comment h "c1" "change"
      ((`at` "pending") <$> snap h) `shouldReturn` texts ["push:comment:c1:h1:i1"]
      modifyWorld h (\w -> w {announceBlocker = Nothing})
      deliver h "on_announce_wake" "AWake" (awake deferred)
      announcements h `shouldReturn` []
      ((`at` "announcing") <$> snap h) `shouldReturn` obj []
      tokens h "ready.deferred" `shouldReturn` []

    it "changes requested and unresolved hold readiness" $ do
      h <- spawn
      noFindings "h1" h
      seeHead h "h1"
      seeRun h
      seeHuman h True True 0
      announcements h `shouldReturn` []
      seeHuman h True False 2
      announcements h `shouldReturn` []
      approve h
      announcements h `shouldReturn` ["ready:h1:i1"]

    it "unmergeable holds readiness" $ do
      h <- spawn
      noFindings "h1" h
      seeHeadWith h "h1" headArgs {seenMergeable = False}
      seeRun h
      approve h
      announcements h `shouldReturn` []
      seeHeadWith h "h1" headArgs {seenMergeable = True}
      announcements h `shouldReturn` ["ready:h1:i1"]

    it "strict stale base holds readiness until current" $ do
      h <- spawn
      noFindings "h1" h
      seeHeadWith h "h1" headArgs {seenStrictBase = True, seenBaseCurrent = False}
      seeRun h
      approve h
      announcements h `shouldReturn` []
      ((`at` "base_current") <$> snap h) `shouldReturn` Bool False
      seeHeadWith h "h1" headArgs {seenStrictBase = True, seenBaseCurrent = True}
      announcements h `shouldReturn` ["ready:h1:i1"]
      ((.agentCalls) <$> worldOf h) `shouldReturn` 1

    it "non strict policy does not require current base" $ do
      h <- spawn
      noFindings "h1" h
      seeHeadWith h "h1" headArgs {seenStrictBase = False, seenBaseCurrent = False}
      seeRun h
      approve h
      announcements h `shouldReturn` ["ready:h1:i1"]

    it "retained state without base evidence fails closed" $ do
      let retained =
            model @C.StateFact
              (obj [("incarnation", int 1), ("body", obj [("phase", str "running"), ("head", str "h1"), ("base", str "b1"), ("mergeable", Bool True), ("policy", str "p1")])])
      case applyState baseSnapshot retained of
        Just applied -> do
          applied.strictBase `shouldBe` True
          applied.baseCurrent `shouldBe` False
        other -> expectationFailure (show other)

    it "repeated ready preserving facts never reannounce" $ do
      h <- spawn
      goReady h
      approve h
      seeRunWith h (runOf "h1" 1)
      announcements h `shouldReturn` ["ready:h1:i1"]
      ((`at` "announced") <$> snap h) `shouldReturn` arr [int 1]

    it "pending mutation holds readiness until settled" $ do
      h <- spawnHeld
      noFindings "h1" h
      let hold = ["git_gate"]
      deliverHeld h hold "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h hold "on_runs" "RunSeen" (runSeen "h1" 1)
      deliverHeld h hold "on_comment" "CommentSeen" (commentSeen "c1" "change")
      deliverHeld h hold "on_human" "HumanSeen" humanSeen
      ((`at` "pending") <$> snap h) `shouldReturn` texts ["push:comment:c1:h1:i1"]
      announcements h `shouldReturn` []
      releaseOne h "git_gate"
      ((`at` "pending") <$> snap h) `shouldReturn` arr []
      announcements h `shouldReturn` []

    it "a queued second mutation never slips a false announce" $ do
      h <- spawnHeld
      noFindings "h1" h
      let hold = ["git_gate"]
      deliverHeld h hold "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h hold "on_runs" "RunSeen" (runSeen "h1" 1)
      deliverHeld h hold "on_comment" "CommentSeen" (commentSeen "c1" "change")
      deliverHeld h hold "on_human" "HumanSeen" humanSeen
      deliverHeld h hold "on_head" "HeadSeen" (headSeen "h1" "b2")
      deliverHeld h hold "on_comment" "CommentSeen" (commentSeen "c2" "change")
      modifyWorld h (\w -> w {gitMode = Just "fault"})
      releaseOne h "git_gate"
      pump h
      st <- snap h
      faultKeys "mutation:" st `shouldSatisfy` (not . null)
      announcements h `shouldReturn` []

  describe "settlement identity" $ do
    it "an old settlement cannot clear a newer same kind round" $ do
      let pendingA = Pending (pendingFact 1 keyA)
          pendingB = Pending (pendingFact 1 keyB)
          settledA = Settled (settledFact 1 keyA "moved")
      forM_ [[pendingA, settledA, pendingB], [pendingA, pendingB, settledA]] $ \order ->
        (foldl applyOne baseSnapshot order).pending `shouldBe` [keyB]

    it "the pending gate holds on identity not display" $ do
      let afterPending = applyMutationPending baseSnapshot (pendingFact 1 keyA)
      (.pending) <$> afterPending `shouldBe` Just [keyA]
      case afterPending of
        Just s -> (.pending) <$> applyMutationSettled s (settledFact 1 keyA "landed") `shouldBe` Just []
        other -> expectationFailure (show other)

    it "same drive pending folds before its settlement" $ do
      h <-
        spawnWith
          "pr-v5"
          freshWorld
          [ ("ready.mutation_pending_facts", "MutationPendingFact", dump (pendingFact 0 keyA))
          , ("ready.mutation_settled_facts", "MutationSettledFact", dump (settledFact 0 keyA "landed"))
          ]
      drive h
      ((`at` "pending") <$> snap h) `shouldReturn` arr []

    it "same drive recovery resolution folds before a refault" $ do
      let cleared = dumped @C.FaultClearedFact (obj [("incarnation", int 0), ("body", obj [("where", str "mutation"), ("op", str keyA), ("status", str "resolved")])])
          raised = dumped @C.FaultRaisedFact (obj [("incarnation", int 0), ("body", obj [("where", str "mutation"), ("op", str keyA), ("reason", str "still unknown")])])
      h <-
        spawnWith
          "pr-v5"
          freshWorld
          [ ("ready.fault_cleared_facts", "FaultClearedFact", cleared)
          , ("ready.fault_raised_facts", "FaultRaisedFact", raised)
          ]
      drive h
      ((`at` "faults") <$> snap h) `shouldReturn` obj [("mutation:" <> keyA, str "still unknown")]

  describe "incarnations" $ do
    it "draft resume announces again under the new incarnation" $ do
      h <- spawn
      goReady h
      deliver h "on_draft" "DraftSeen" (obj [])
      ((`at` "phase") <$> snap h) `shouldReturn` str "quiescent"
      deliver h "on_ready" "ReadySeen" (obj [])
      st <- snap h
      st `at` "incarnation" `shouldBe` int 2
      st `at` "checks" `shouldBe` str "pending"
      st `at` "approval" `shouldBe` Bool True
      seeRunWith h (runOf "h1" 2)
      announcements h `shouldReturn` ["ready:h1:i1", "ready:h1:i2"]

    it "a new head resets the per incarnation gates" $ do
      h <- spawn
      goReady h
      noFindings "h2" h
      seeHead h "h2"
      st <- snap h
      st `at` "incarnation" `shouldBe` int 2
      st `at` "head" `shouldBe` str "h2"
      st `at` "checks" `shouldBe` str "pending"
      announcements h `shouldReturn` ["ready:h1:i1"]
      seeRunWith h (runOf "h2" 2)
      announcements h `shouldReturn` ["ready:h1:i1", "ready:h2:i2"]

    it "a mismatched incarnation settle is inert" $ do
      h <- spawnHeld
      noFindings "h1" h
      noFindings "h2" h
      let hold = ["git_gate"]
      deliverHeld h hold "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h hold "on_comment" "CommentSeen" (commentSeen "c1" "change")
      ((`at` "pending") <$> snap h) `shouldReturn` texts ["push:comment:c1:h1:i1"]
      deliverHeld h hold "on_head" "HeadSeen" (headSeen "h2" "b1")
      ((`at` "pending") <$> snap h) `shouldReturn` arr []
      releaseOne h "git_gate"
      st <- snap h
      st `at` "pending" `shouldBe` arr []
      st `at` "incarnation" `shouldBe` int 2

  describe "blocked recovery" $ do
    it "a blocked announce recovers under the same identity" $ do
      h <- spawn
      noFindings "h1" h
      seeHead h "h1"
      seeRun h
      modifyWorld h (\w -> w {commentsMode = Just "retryable"})
      approve h
      st <- snap h
      st `atPath` ["blocked", "op"] `shouldBe` str "ready:h1:i1"
      st `at` "announcing" `shouldBe` obj []
      announcements h `shouldReturn` []
      modifyWorld h (\w -> w {commentsMode = Nothing})
      commentWith h "c1" "recover_publication" "ready:h1:i1" True
      announcements h `shouldReturn` ["ready:h1:i1"]
      st' <- snap h
      st' `at` "blocked" `shouldBe` obj []
      st' `at` "announced" `shouldBe` arr [int 1]

    it "recovery with the wrong operation is inert" $ do
      h <- spawn
      noFindings "h1" h
      seeHead h "h1"
      seeRun h
      modifyWorld h (\w -> w {commentsMode = Just "retryable"})
      approve h
      modifyWorld h (\w -> w {commentsMode = Nothing})
      commentWith h "c1" "recover_publication" "ready:h9:i9" True
      announcements h `shouldReturn` []
      ((`atPath` ["blocked", "op"]) <$> snap h) `shouldReturn` str "ready:h1:i1"

    it "a faulted announce is fail closed and never reissued" $ do
      h <- spawn
      noFindings "h1" h
      seeHead h "h1"
      seeRun h
      modifyWorld h (\w -> w {commentsMode = Just "unknown"})
      approve h
      ((`at` "faults") <$> snap h) `shouldReturn` obj [("announce:ready:h1:i1", str "unknown provider terminal")]
      modifyWorld h (\w -> w {commentsMode = Nothing})
      commentWith h "c1" "recover_publication" "ready:h1:i1" True
      announcements h `shouldReturn` []
      ((`at` "faults") <$> snap h) `shouldNotReturn` obj []

  describe "moved authority" $ do
    it "deferred retry settles moved when provider authority changed before its wake" $ do
      h <- spawn
      modifyWorld h (\w -> w {announceBlocker = Just blocker})
      goReady h
      [deferred] <- tokens h "ready.deferred"
      modifyWorld h $ \w ->
        w
          { announceBlocker = Nothing
          , branchHead = "h2"
          , authority = Authority {phase = "running", incarnation = 2, head = "h2", base = "b1", policy = "p1"}
          }
      deliver h "on_announce_wake" "AWake" (awake deferred)
      announcements h `shouldReturn` []
      tokens h "ready.deferred" `shouldReturn` []
      ((`at` "announcing") <$> snap h) `shouldReturn` obj []
      ((`at` "blocked") <$> snap h) `shouldReturn` obj []

    it "moved with the displacing observation unfolded parks" $ do
      h <- spawnHeld
      noFindings "h1" h
      noFindings "h2" h
      let hold = ["announce_gate"]
      deliverHeld h hold "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h hold "on_runs" "RunSeen" (runSeen "h1" 1)
      deliverHeld h hold "on_human" "HumanSeen" humanSeen
      ((`atPath` ["announcing", "op"]) <$> snap h) `shouldReturn` str "ready:h1:i1"
      modifyWorld h (\w -> w {branchHead = "h2"})
      releaseOne h "announce_gate"
      ((`at` "announcing") <$> snap h) `shouldReturn` obj []
      announcements h `shouldReturn` []
      deliverHeld h [] "on_head" "HeadSeen" (headSeen "h2" "b1")
      deliverHeld h [] "on_runs" "RunSeen" (runSeen "h2" 2)
      announcements h `shouldReturn` ["ready:h2:i2"]

    it "moved with the displacing observation folded reevaluates" $ do
      h <- spawnHeld
      noFindings "h1" h
      let hold = ["announce_gate"]
      deliverHeld h hold "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h hold "on_runs" "RunSeen" (runSeen "h1" 1)
      deliverHeld h hold "on_human" "HumanSeen" humanSeen
      deliverHeld h hold "on_draft" "DraftSeen" (obj [])
      deliverHeld h hold "on_ready" "ReadySeen" (obj [])
      ((`at` "incarnation") <$> snap h) `shouldReturn` int 2
      releaseOne h "announce_gate"
      pump h
      announcements h `shouldReturn` []
      deliverHeld h [] "on_runs" "RunSeen" (runSeen "h1" 2)
      announcements h `shouldReturn` ["ready:h1:i2"]
      ((`at` "announced") <$> snap h) `shouldReturn` arr [int 2]

  describe "fault ledger" $ do
    it "a review fault fail closes and its recovery resolves" $ do
      h <- spawn
      modifyWorld h (\w -> w {commentsMode = Just "unknown"})
      seeHead h "h1"
      [key] <- faultKeys "review:" <$> snap h
      modifyWorld h (\w -> w {commentsMode = Nothing})
      commentWith h "c1" "recover_publication" (T.drop (T.length "review:") key) True
      ((`at` "faults") <$> snap h) `shouldReturn` obj []

    it "a mutation fault fail closes and its recovery resolves" $ do
      h <- spawn
      noFindings "h1" h
      seeHead h "h1"
      modifyWorld h (\w -> w {gitMode = Just "fault"})
      comment h "c1" "change"
      st <- snap h
      [key] <- pure (faultKeys "mutation:" st)
      st `at` "pending" `shouldBe` texts ["push:comment:c1:h1:i1"]
      modifyWorld h (\w -> w {gitMode = Nothing})
      commentWith h "c2" "recover_publication" (T.drop (T.length "mutation:") key) True
      st' <- snap h
      st' `at` "faults" `shouldBe` obj []
      st' `at` "pending" `shouldBe` arr []

    it "a rerun fault fail closes and its recovery resolves" $ do
      h <- spawn
      noFindings "h1" h
      seeHead h "h1"
      modifyWorld h (\w -> w {rerunsMode = Just "unknown"})
      seeRunWith h runArgs {runConclusion = "failure", runFingerprint = "fp1"}
      [key] <- faultKeys "rerun:" <$> snap h
      modifyWorld h (\w -> w {rerunsMode = Nothing})
      commentWith h "c1" "recover_publication" (T.drop (T.length "rerun:") key) True
      ((`at` "faults") <$> snap h) `shouldReturn` obj []

    it "a moved rerun recovery resolves instead of stranding" $ do
      h <- spawn
      noFindings "h1" h
      seeHead h "h1"
      modifyWorld h (\w -> w {rerunsMode = Just "unknown"})
      seeRunWith h runArgs {runConclusion = "failure", runFingerprint = "fp1"}
      [key] <- faultKeys "rerun:" <$> snap h
      modifyWorld h (\w -> w {rerunsMode = Nothing})
      seeHeadWith h "h1" headArgs {seenBase = "b2"}
      seeRunWith h runArgs {runId = 2, runConclusion = "success"}
      commentWith h "c1" "recover_publication" (T.drop (T.length "rerun:") key) True
      ((`at` "faults") <$> snap h) `shouldReturn` obj []
      ((.reruns) <$> worldOf h) `shouldReturn` []

  describe "close" $ do
    it "close retires the loop with the reason" $ do
      h <- spawn
      goReady h
      deliver h "on_close" "CloseSeen" (obj [("reason", str "merged")])
      tokens h "ready.snap" `shouldReturn` []
      done <- one h "ready.done"
      done `at` "reason" `shouldBe` str "merged"
      done `at` "announced" `shouldBe` arr [int 1]

    it "an empty close reason still closes" $ do
      h <- spawn
      deliver h "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliver h "on_close" "CloseSeen" (obj [("reason", str "")])
      tokens h "ready.snap" `shouldReturn` []
      ((`at` "reason") <$> one h "ready.done") `shouldReturn` str ""

    it "close defers while the announce terminal is outstanding" $ do
      h <- spawnHeld
      noFindings "h1" h
      let hold = ["announce_gate"]
      deliverHeld h hold "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliverHeld h hold "on_runs" "RunSeen" (runSeen "h1" 1)
      deliverHeld h hold "on_human" "HumanSeen" humanSeen
      deliverHeld h hold "on_close" "CloseSeen" (obj [("reason", str "merged")])
      ((`at` "closing") <$> snap h) `shouldReturn` str "merged"
      tokens h "ready.done" `shouldReturn` []
      releaseOne h "announce_gate"
      pump h
      tokens h "ready.snap" `shouldReturn` []
      ((`at` "reason") <$> one h "ready.done") `shouldReturn` str "merged"

    it "close waits through deferred announcement then retires without posting" $ do
      h <- spawn
      modifyWorld h (\w -> w {announceBlocker = Just blocker})
      goReady h
      [deferred] <- tokens h "ready.deferred"
      deliver h "on_close" "CloseSeen" (obj [("reason", str "closed")])
      ((`at` "closing") <$> snap h) `shouldReturn` str "closed"
      tokens h "ready.done" `shouldReturn` []
      modifyWorld h (\w -> w {announceBlocker = Nothing})
      deliver h "on_announce_wake" "AWake" (awake deferred)
      tokens h "ready.snap" `shouldReturn` []
      tokens h "ready.deferred" `shouldReturn` []
      ((`at` "reason") <$> one h "ready.done") `shouldReturn` str "closed"
      announcements h `shouldReturn` []

    it "post close mail drains and never strands" $ do
      h <- spawn
      deliver h "on_head" "HeadSeen" (headSeen "h1" "b1")
      deliver h "on_close" "CloseSeen" (obj [("reason", str "closed")])
      comment h "c1" "change"
      commentWith h "c2" "recover_publication" "ready:h1:i1" True
      forM_ ["state", "checks", "review", "findings", "human", "mutation_pending", "mutation_settled", "fault_raised", "fault_cleared"] $ \mailbox ->
        tokens h ("ready." <> mailbox <> "_facts") `shouldReturn` []
      tokens h "ready.recover" `shouldReturn` []
      ((`at` "reason") <$> one h "ready.done") `shouldReturn` str "closed"
