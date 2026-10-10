-- | Parity: @tests/petrus/impetus/selection/test_selection.py@.
--
-- The reference's policy state is an untyped @object@; here each policy
-- names its state type ('RoundRobinState' is @Maybe Int@, the stateless
-- policies run at @()@ or at whatever state the test threads through). The
-- reference's spies count calls and log them; filters, rankers, and
-- strategies are pure functions here, so a strategy that must never be
-- consulted is one whose consultation would surface as a refusal.
module Petrus.Impetus.SelectionSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Petrus.Impetus.History
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Petrinet
import Petrus.Impetus.Selection
import Petrus.Impetus.TestSupport
import Test.Hspec
import Test.QuickCheck

-- | @_bindings(*names)@: one binding per transition, consuming nothing.
bindings :: [Text] -> [Binding]
bindings names = [Binding (np n) [] [] [] | n <- names]

propose' :: SelectionPolicy s -> [Binding] -> s -> Either Text (Maybe (SelectionProposal s))
propose' policy = policy.propose

ring :: SelectionPolicy RoundRobinState
ring = either (error . show) id (roundRobin [np "a", np "b", np "c"])

selected :: Text -> Int -> Record
selected t o = RCandidateSelected (CandidateSelected (np t) o 0)

begun :: Text -> Int -> Record
begun t o = RFiringBegun (FiringBegun (np t) o Nothing 0)

spec :: Spec
spec = describe "Selection" $ do
  -- test_first_proposes_immutably_and_empty_offer_bypasses_choice
  it "First proposes the head immutably and an empty offer bypasses choice" $ do
    let offered = bindings ["a", "b"]
    Just proposal <- expectRight (propose' first offered (Nothing :: Maybe Int))
    proposal.binding `shouldBe` offered !! 0
    proposal.priorState `shouldBe` Nothing
    proposal.nextState `shouldBe` Nothing
    propose' first [] (Nothing :: Maybe Int) `shouldBe` Right Nothing

  -- test_priority_is_stable_for_equal_and_unconfigured_transitions
  it "Priority is stable for equal and unconfigured transitions" $ do
    let offered = bindings ["a", "b", "c"]
    Just proposal <- expectRight (propose' (priority (Map.fromList [(np "b", 10), (np "c", 10)])) offered ())
    proposal.binding `shouldBe` offered !! 1

  -- test_round_robin_proposes_next_state_without_mutating_prior_state
  it "RoundRobin proposes the next state without mutating the prior state" $ do
    let offered = bindings ["a", "b", "c"]
    Just first' <- expectRight (propose' ring offered Nothing)
    again' <- expectRight (propose' ring offered Nothing)
    Just second <- expectRight (propose' ring offered first'.nextState)
    Just first' `shouldBe` again'
    first'.binding.transition `shouldBe` np "a"
    second.binding.transition `shouldBe` np "b"

  -- test_round_robin_validates_cursor_and_wraps_the_last_position_to_zero
  it "RoundRobin validates the cursor and wraps the last position to zero" $ do
    Just atZero <- expectRight (propose' ring (bindings ["a"]) (Just 0))
    Just proposal <- expectRight (propose' ring (bindings ["c"]) (Just 2))
    atZero.binding.transition `shouldBe` np "a"
    proposal.nextState `shouldBe` Just 0

  -- test_round_robin_rejects_invalid_cursor_state[-1], [3] (the [True] and
  -- ['1'] parameters are enforced by types: the cursor is an Int)
  it "RoundRobin rejects an invalid cursor state" $ do
    propose' ring (bindings ["a"]) (Just (-1)) `shouldFailWith` "invalid round-robin state: -1"
    propose' ring (bindings ["a"]) (Just 3) `shouldFailWith` "invalid round-robin state: 3"

  -- test_pipeline_filters_then_stably_ranks_then_runs_one_strategy
  it "the pipeline filters, then stably ranks, then runs one strategy" $ do
    -- The reference also logs the call order (every filter, then the
    -- rankers over the admitted bindings only); pure filters and rankers
    -- have no observable call order, so the result is what is asserted.
    let admits b = b.transition /= np "a"
        rank b = if b.transition == np "c" then 0 else 1 :: Int
        pipeline = selectionPipeline [admits] [ranker rank] first
    Just proposal <- expectRight (propose' pipeline (bindings ["a", "b", "c"]) ())
    proposal.binding.transition `shouldBe` np "c"
    propose' (selectionPipeline [const False] [] first) (bindings ["a"]) () `shouldBe` Right Nothing

  -- test_all_filtered_bypasses_strategy_and_custom_strategy_is_boundary_checked
  it "an all-filtered offer bypasses the strategy, and a custom strategy is boundary-checked" $ do
    let offered = bindings ["a", "b"]
        -- The Spy: a strategy answering a fixed proposal. A bypassed one
        -- refuses if consulted, which stands in for "calls == 0".
        spy :: Maybe (SelectionProposal (Maybe Text)) -> SelectionPolicy (Maybe Text)
        spy proposal = SelectionPolicy (\_ _ -> Right proposal) (\s _ -> Right s)
        bypassed :: SelectionPolicy (Maybe Text); bypassed = SelectionPolicy (\_ _ -> Left "the bypassed strategy was consulted") (\s _ -> Right s)
    propose' (selectionPipeline [const False] [] bypassed) offered Nothing `shouldBe` Right Nothing
    propose'
      (selectionPipeline [(== offered !! 0)] [] (spy (Just (SelectionProposal (offered !! 1) Nothing (Just "1")))))
      offered
      Nothing
      `shouldFailWith` "selection strategy proposed a binding outside the admitted candidates"
    propose' (selectionPipeline [] [] (spy (Just (SelectionProposal (offered !! 0) (Just "wrong") (Just "1"))))) offered Nothing
      `shouldFailWith` "selection strategy proposal does not carry the pipeline's prior state"

  -- test_multiple_filters_and_rankers_preserve_order_and_final_ties
  it "multiple filters and rankers preserve order and final ties" $ do
    -- The reference's call log (each filter in order, short-circuiting per
    -- binding) is unobservable for pure filters; the selected binding is
    -- what is asserted.
    let offered = bindings ["a", "b", "c", "d"]
        filterOne b = b.transition /= np "a"
        filterTwo _ = True
        pipeline =
          selectionPipeline
            [filterOne, filterTwo]
            [ranker (\b -> b.transition `elem` [np "b", np "c"]), ranker (const (0 :: Int))]
            first
    Just proposal <- expectRight (propose' pipeline offered ())
    proposal.binding `shouldBe` offered !! 3

  -- test_replay_folds_only_exact_committed_selection_pairs_and_spends_orphans
  it "replay folds only exact committed selection pairs and spends orphans" $ do
    policy <- expectRight (roundRobin [np "a", np "b"])
    history <- Store.inMemoryHistoryStore
    history.extend [selected "a" 1, begun "a" 1]
    Store.append history (selected "b" 2)
    state <- Store.records history >>= expectRight . foldHistory policy Nothing
    Just proposal <- expectRight (propose' policy (bindings ["a", "b"]) state)
    proposal.binding.transition `shouldBe` np "b"

  -- test_replay_threads_accumulated_policy_state_through_committed_pairs
  it "replay threads accumulated policy state through committed pairs" $ do
    -- TransitionTrail: only fold_committed matters; its propose is First's.
    let trail = SelectionPolicy first.propose (\s t -> Right (s ++ [t]))
        history = [selected "a" 1, begun "a" 1, selected "b" 2, begun "b" 2]
    foldHistory trail [] history `shouldBe` Right [np "a", np "b"]

  describe "test_replay_refuses_duplicate_or_mismatched_selection_lifecycle" $ do
    -- test_replay_refuses_duplicate_or_mismatched_selection_lifecycle[0]
    it "refuses a duplicate CandidateSelected" $
      foldHistory first () [selected "a" 1, selected "a" 1]
        `shouldFailWith` "selection replay divergence: duplicate CandidateSelected for occurrence 1"
    -- test_replay_refuses_duplicate_or_mismatched_selection_lifecycle[1]
    it "refuses a FiringBegun of another transition" $
      foldHistory first () [selected "a" 1, begun "b" 1]
        `shouldFailWith` "selection replay divergence: occurrence 1 selected a but began b"
    -- test_replay_refuses_duplicate_or_mismatched_selection_lifecycle[2]
    it "refuses a duplicate FiringBegun" $
      foldHistory first () [selected "a" 1, begun "a" 1, begun "a" 1]
        `shouldFailWith` "selection replay divergence: duplicate FiringBegun for occurrence 1"

  describe "properties" $ do
    -- Not upstream (no Hypothesis there): the round-robin fold over any
    -- committed trail lands where proposing from the last committed
    -- transition would, and First's fold is the identity.
    it "round-robin replay state is one past the last committed transition (property)" $
      property $ \(picks :: [Bool]) ->
        let names = [if p then "a" else "b" | p <- picks]
            policy = either (error . show) id (roundRobin [np "a", np "b"])
            history = concat [[selected n o, begun n o] | (n, o) <- zip names [1 ..]]
            expected = case reverse names of
              [] -> Nothing
              lastName : _ -> Just (if lastName == "a" then 1 else 0)
         in foldHistory policy Nothing history === Right expected
    it "First's fold over any committed trail leaves the state unchanged (property)" $
      property $ \(n :: Small Int) (state :: Int) ->
        let history = concat [[selected "a" o, begun "a" o] | o <- [1 .. getSmall n `mod` 20]]
         in foldHistory first state history === Right state
