-- | @tests/unit/readiness/net_v5/test_board.py@ (22 functions, 22 cases):
-- what a human must learn from the summary board.
module BoardSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.PyLiteral (PyValue (..), repr)
import Hamsterdan.Readiness.NetV5.Board (gateFacts, renderBoard)
import Test.Hspec

headSha, baseSha, policySha :: Text
headSha = "3ff7d1067d8437340e39d2ad38c06ab4631a7c4f"
baseSha = "a83e9223f7ffc6b0af919b0b8261fa2578261b41"
policySha = "196b38f86f32afff0e606bcb9a3e36647bc0bdd1b82a3818fe412c38a2ccc25b"

short :: Text -> Text
short = T.take 7

-- | @f"{kind}:{body}"@ for a dict body.
entry :: Text -> [(Text, PyValue)] -> Text
entry kind body = kind <> ":" <> repr (PyDict [(PyStr k, v) | (k, v) <- body])

s :: Text -> PyValue
s = PyStr

-- | @state(**overrides)@: dict.update keeps the original key order.
state :: [(Text, PyValue)] -> Text
state overrides =
  entry "state" [(k, maybe v id (lookup k overrides)) | (k, v) <- defaults]
 where
  defaults =
    [ ("phase", s "running")
    , ("head", s headSha)
    , ("base", s baseSha)
    , ("mergeable", PyBool True)
    , ("policy", s policySha)
    , ("strict_base", PyBool True)
    , ("base_current", PyBool True)
    ]

human :: Bool -> Bool -> Integer -> Text
human approval changes unresolved =
  entry "human" [("approval", PyBool approval), ("changes_requested", PyBool changes), ("unresolved", PyInt unresolved)]

noHuman :: Text
noHuman = human False False 0

checks :: Text -> Text
checks status = entry "checks" [("status", s status)]

render :: [Text] -> IO Text
render entries = either (fail . T.unpack) pure (renderBoard entries)

row :: Text -> Text -> IO Text
row board gate = case filter (T.isPrefixOf ("| " <> gate <> " |")) (T.lines board) of
  [line] -> pure line
  other -> fail ("expected one row, got " <> show other)

contains :: Text -> Text -> Expectation
contains board needle = board `shouldSatisfy` T.isInfixOf needle

lacks :: Text -> Text -> Expectation
lacks board needle = board `shouldNotSatisfy` T.isInfixOf needle

fault :: [(Text, PyValue)] -> Text
fault = entry "fault"

faulted, resolved :: Text
faulted = fault [("where", s "review"), ("op", s "op-1"), ("status", s "faulted"), ("reason", s "timeout")]
resolved = fault [("where", s "review"), ("op", s "op-1"), ("status", s "resolved")]

humanNeeded :: Text
humanNeeded = entry "human_needed" [("fingerprint", s "deadbeef99"), ("head", s headSha)]

pendingPush, settledPush :: Text
pendingPush = entry "mutation_pending" [("op", s "repair"), ("op_key", s "k1")]
settledPush = entry "mutation_settled" [("op", s "repair"), ("op_key", s "k1")]

kindsOf :: [Text] -> IO [(Text, [(PyValue, PyValue)])]
kindsOf entries = either (fail . T.unpack) pure (gateFacts entries)

spec :: Spec
spec = describe "board" $ do
  describe "verdict boundaries" $ do
    it "a just opened pr shows nothing started and no actor" $ do
      board <- render [state []]
      board `contains` ("⏳ waiting on CI for `" <> short headSha <> "`")
      board `contains` "Nothing for you to do"
      row board "CI checks" `shouldReturn` "| CI checks | ⏳ not started |"

    it "running ci folds transient states into one waiting row" $ do
      board <- render [state [], noHuman, checks "pending", checks "queued", checks "in_progress"]
      board `contains` "⏳ waiting on CI"
      row board "CI checks" `shouldReturn` "| CI checks | ⏳ in progress |"
      board `lacks` "queued"

    it "a ci failure names the author as next actor" $ do
      board <- render [state [], checks "failure"]
      board `contains` ("❌ CI failed for `" <> short headSha <> "`")
      board `contains` "**Author:**"
      row board "CI checks" `shouldReturn` "| CI checks | ❌ failing |"

    it "blocking findings outrank green checks" $ do
      board <-
        render
          [ state []
          , checks "success"
          , entry "findings" [("head", s headSha), ("blocking", PyInt 2), ("count", PyInt 3)]
          , entry "review" [("head", s headSha), ("status", s "blocking")]
          ]
      board `contains` "❌ 2 blocking finding(s) of 3"
      row board "Dan's review" `shouldReturn` "| Dan's review | ❌ blocking · 2 blocking of 3 finding(s) |"

    it "requested changes hand the turn to the author" $ do
      board <- render [state [], checks "success", human False True 2]
      board `contains` "waiting on author — a reviewer requested changes"
      row board "Human review" `shouldReturn` "| Human review | ❌ changes requested · 2 unresolved thread(s) |"

    it "unresolved threads alone wait on humans" $ do
      board <- render [state [], checks "success", human True False 1]
      board `contains` "waiting on humans — 1 unresolved review thread(s)"

    it "a stale base asks the author to update the branch" $ do
      board <- render [state [("base_current", PyBool False)], checks "success"]
      board `contains` ("⚠️ base is stale — the target branch moved past `" <> short baseSha <> "`")
      row board "Base" `shouldReturn` ("| Base | ⚠️ behind `" <> short baseSha <> "` |")

    it "a merge conflict asks the author to resolve" $ do
      board <- render [state [("mergeable", PyBool False)], checks "success"]
      board `contains` "❌ merge conflict"
      row board "Conflicts" `shouldReturn` "| Conflicts | ❌ merge conflict |"

    it "all clear points at the advisory and never announces" $ do
      board <-
        render
          [ state []
          , human True False 0
          , checks "success"
          , entry "findings" [("head", s headSha), ("blocking", PyInt 0), ("count", PyInt 0)]
          , entry "review" [("head", s headSha), ("status", s "clear")]
          , entry "announced" [("head", s headSha)]
          ]
      board `contains` ("✅ all gates clear for `" <> short headSha <> "` — see the readiness advisory. Merging stays yours.")
      T.replace "readiness advisory" "" (T.toCaseFold board) `lacks` "ready"
      row board "Dan's review" `shouldReturn` "| Dan's review | ✅ clear · 0 findings |"

    it "a draft pr reads paused" $ do
      board <- render [state [("phase", s "quiescent")]]
      board `contains` "paused — draft PR"

    it "a closed pr reads frozen" $ do
      board <- render [state [("phase", s "terminal")]]
      board `contains` "closed — this board is frozen."

  describe "attention states" $ do
    it "a raised fault offers the recovery ask" $ do
      board <- render [state [], faulted]
      board `contains` "⚠️ needs attention — operation `op-1` faulted: timeout"
      T.toCaseFold board `contains` "ask me to recover it"

    it "a cleared fault leaves no attention row" $ do
      board <- render [state [], faulted, resolved]
      board `lacks` "faulted"

    it "exhausted reruns escalate to a human" $ do
      board <- render [state [], checks "failure", humanNeeded]
      board `contains` "**A human needs to look.**"

    it "fresh ci evidence retires the escalation" $ do
      board <- render [state [], checks "failure", humanNeeded, checks "success"]
      board `lacks` "human needs to look"

    it "a push in flight reads working" $ do
      board <- render [state [], pendingPush]
      board `contains` "🔧 working — I'm pushing an update"

    it "a settled push clears the working state" $ do
      board <- render [state [], pendingPush, settledPush]
      board `lacks` "pushing an update"

    it "an unparseable entry surfaces instead of wedging the board" $ do
      board <- render [state [], "garbage-without-structure"]
      board `contains` "⚠️ unrecognized: `garbage-without-structure`"
      board `contains` "| CI checks |"

  describe "gate facts" $ do
    it "the latest fact per concern wins" $ do
      facts <- kindsOf [state [], checks "pending", checks "success", human True False 0]
      map fst facts `shouldBe` ["state", "checks", "human"]
      lookup "checks" facts `shouldBe` Just [(s "status", s "success")]

    it "an open fault reaches the agent with its recovery identity" $ do
      facts <- kindsOf [state [], faulted]
      [(lookup (s "op") body, lookup (s "reason") body) | ("fault", body) <- facts]
        `shouldBe` [(Just (s "op-1"), Just (s "timeout"))]

    it "a resolved fault never reaches the agent" $ do
      facts <- kindsOf [state [], faulted, resolved]
      [() | ("fault", _) <- facts] `shouldBe` []

    it "a settled push never reaches the agent" $ do
      facts <- kindsOf [state [], pendingPush, settledPush]
      [() | ("mutation_pending", _) <- facts] `shouldBe` []
