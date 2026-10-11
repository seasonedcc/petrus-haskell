-- | Parity: @tests/petrus/impetus/instance/test_runtime.py@ — the
-- integration path (step -> history -> status) and live state answered from
-- the pair-queues without re-folding History.
--
-- The reference counts full iterations of its store (@__iter__@); a fold
-- over a Haskell 'HistoryStore' reads its 'snapshot', so the counting store
-- here wraps the in-memory store and counts 'snapshot' reads.
module Petrus.Impetus.RuntimeSpec (spec) where

import Data.IORef
import Petrus.Impetus.History
import Petrus.Json (Json (..))
import Petrus.Impetus.HistoryStore (HistoryStore (..), inMemoryHistoryStore)
import Petrus.Impetus.Instance
import Petrus.Impetus.InstanceSupport
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Test.Hspec

pa, pb, pc, tt :: NetPath
pa = np "a"
pb = np "b"
pc = np "c"
tt = np "t"

-- | a -> t -> {b, c}: one token fans out to two output places.
forkNet :: Net
forkNet = netOf [place pa, place pb, place pc] [transition tt] [arc pa tt, arc tt pb, arc tt pc]

-- | @_CountingHistory@: an in-memory store that counts full reads.
countingHistory :: IO (HistoryStore, IORef Int)
countingHistory = do
  inner <- inMemoryHistoryStore
  folds <- newIORef (0 :: Int)
  let counted = modifyIORef' folds (+ 1) >> inner.snapshot
  pure (HistoryStore counted inner.count inner.extend inner.mode, folds)

spec :: Spec
spec = describe "Instance runtime" $ do
  describe "the integration path" $ do
    -- TestInstance.test_step_fans_out_and_reports_what_landed_where
    it "fans out on step and reports what landed where" $ do
      let token' = tok "X"
      inst <- seeded forkNet (markingFromList [(pa, [token'])])
      Just firing <- step inst Nothing >>= expectRight
      firing.produced `shouldBe` [(pb, token'), (pc, token')]
      marking inst `shouldReturn` markingFromList [(pb, [token']), (pc, [token'])]
    -- TestInstance.test_runs_to_quiescence_and_reports_terminated
    it "runs to quiescence and reports terminated" $ do
      inst <- seeded forkNet (markingFromList [(pa, [black])])
      _ <- run inst >>= expectRight
      isQuiescent inst `shouldReturn` True
      status inst `shouldReturn` Terminated
    -- TestInstance.test_step_records_the_selection_before_the_firing_lifecycle
    it "records the selection before the firing lifecycle" $ do
      let token' = tok "X"
      inst <- seeded forkNet (markingFromList [(pa, [token'])])
      Just firing <- step inst Nothing >>= expectRight
      historyOf inst
        `shouldReturn` ( [ RInstanceCreated (InstanceCreated (instanceIdentity inst) Nothing 0)
                         , RTokensInitialized (TokensInitialized pa [token'] 0 [] Nothing)
                         , RCandidateSelected (CandidateSelected tt 1 0)
                         ]
                           ++ firing.records
                       )
    -- TestInstance.test_history_replays_to_the_live_marking
    it "replays History to the live marking" $ do
      inst <- seeded forkNet (markingFromList [(pa, [tok "X"])])
      _ <- run inst >>= expectRight
      records <- historyOf inst
      live <- marking inst
      replayMarking records `shouldBe` Right live

  describe "live state is not refolded" $ do
    -- TestLiveStateIsNotRefolded.test_candidates_answer_from_live_state_without_refolding_history
    it "answers candidates from live state without refolding History" $ do
      let net = netOf [place pa, place pb] [Transition tt Nothing [] [Delay 5]] [arc pa tt, arc tt pb]
      (history, folds) <- countingHistory
      inst <- seededWith net defaultInstanceConfig {initialMarking = markingFromList [(pa, [black])], historyStore = Just history}
      writeIORef folds 0
      _ <- candidates inst
      _ <- nextMaturation inst
      _ <- wake inst 5 >>= expectRight
      _ <- step inst Nothing >>= expectRight
      readIORef folds `shouldReturn` 0

  -- Beyond upstream (spec/net-schema.md, Places: "A typed place's initial
  -- marking MUST contain only its declared color; validation rejects a
  -- mismatch before recording initial History"). Upstream checks it only
  -- through Engine load; the messages are the reference's.
  describe "typed-place initial marking" $ do
    let typed = netOf [coloredPlace pa "Order", place pb] [transition tt] [arc pa tt, arc tt pb]
        construct tokens = do
          (history, _) <- countingHistory
          result <- newInstance typed defaultInstanceConfig {initialMarking = markingFromList [(pa, tokens)], historyStore = Just history}
          recorded <- length <$> history.snapshot
          pure (either (Left . renderInstanceError) (const (Right ())) result, recorded)
    it "refuses a token of another color before recording anything" $ do
      (result, recorded) <- construct [tokD "Order" (Int 1), tokD "Wrong" (Object [("x", Int 1)])]
      result `shouldFailWith` "initial marking for place a requires color 'Order', got 'Wrong' on Token('Wrong', {'x': 1})"
      recorded `shouldBe` 0
    it "refuses a black token before recording anything" $ do
      (result, recorded) <- construct [black]
      result `shouldFailWith` "initial marking for place a requires color 'Order', got None on Token.black()"
      recorded `shouldBe` 0
