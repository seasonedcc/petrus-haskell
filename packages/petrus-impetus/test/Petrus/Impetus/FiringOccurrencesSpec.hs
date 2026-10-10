-- | Parity: @tests/petrus/impetus/instance/test_firing_occurrences.py@ — the
-- durable firing-occurrence seam: 'begin', 'complete', 'failFiring', and the
-- inline drivers ('step', 'completeDelivery') over it.
--
-- A Python handler that raises is a Haskell 'Handler' returning 'Left' with
-- the reference's recorded spelling (@RuntimeError('...')@): the Instance
-- records that text verbatim on @FiringFailed@ and answers 'HandlerRaised'.
-- A Python @ValueError@ refusal is 'Refused' with the same message, and the
-- inline driver records it as @ValueError('...')@, as the reference does.
module Petrus.Impetus.FiringOccurrencesSpec (spec) where

import Data.Foldable (toList)
import Data.Text (Text)
import Petrus.Impetus.Binding
import Petrus.Impetus.History
import Petrus.Impetus.Instance
import Petrus.Impetus.InstanceSupport
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Petrus.Json (Json (..))
import Test.Hspec

pa, pb, tt :: NetPath
pa = np "a"
pb = np "b"
tt = np "t"

-- | a -> t -> b, optionally with a user handler symbol on t.
lineNet :: Maybe Text -> Net
lineNet symbol = netOf [place pa, place pb] [(transition tt) {handler = HandlerSymbol <$> symbol}] [arc pa tt, arc tt pb]

isActivityRecord :: Record -> Bool
isActivityRecord = \case
  RActivityRequested _ -> True
  RActivityCompleted _ -> True
  _ -> False

spec :: Spec
spec = describe "Instance firing occurrences" $ do
  describe "begin" $ do
    -- TestBegin.test_begin_accounts_tokens_and_records_the_occurrence
    it "accounts tokens and records the occurrence" $ do
      let token' = tok "X"
      inst <- seededWith (lineNet Nothing) defaultInstanceConfig {initialMarking = markingFromList [(pa, [token'])], constructionInstant = 3}
      o <- beginOne inst
      marking inst `shouldReturn` emptyMarking
      historyOf inst
        `shouldReturn` [ RInstanceCreated (InstanceCreated (instanceIdentity inst) Nothing 3)
                       , RTokensInitialized (TokensInitialized pa [token'] 3 [] Nothing)
                       , RCandidateSelected (CandidateSelected tt 1 3)
                       , RFiringBegun (FiringBegun tt 1 Nothing 3)
                       , RTokensConsumed (TokensConsumed pa [token'] 1 [] Nothing 3)
                       ]
      o.occurrence `shouldBe` 1
      o.binding.transition `shouldBe` tt
      inFlight inst `shouldReturn` [o]
    -- TestBegin.test_occurrence_ids_are_minted_monotonically
    it "mints occurrence ids monotonically" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X", tok "X"])])
      first' <- beginOne inst
      second' <- beginOne inst
      (first'.occurrence, second'.occurrence) `shouldBe` (1, 2)
      inFlight inst `shouldReturn` [first', second']
    -- TestBegin.test_an_in_flight_occurrence_keeps_the_instance_running
    it "keeps the instance running while an occurrence is in flight" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X"])])
      _ <- beginOne inst
      isQuiescent inst `shouldReturn` False
      status inst `shouldReturn` Running
    -- TestBegin.test_begin_rejects_a_delivered_binding
    it "rejects a delivered binding" $ do
      let source = np "src"
      inst <- seeded (netOf [place pb] [transition source] [arc source pb]) emptyMarking
      result <- begin inst (deliveredBinding source [tok "X"]) Nothing
      result `shouldRefuse` "cannot begin firing src: a source transition is never scheduled — it fires only through accept_delivery()"
    -- TestBegin.test_begin_rejects_a_source_transition
    it "rejects a source transition" $ do
      let source = np "src"
      inst <- seeded (netOf [place pb] [transition source] [arc source pb]) emptyMarking
      recorded <- historyLength inst
      result <- begin inst (selectionBinding source [] []) Nothing
      result `shouldRefuse` "cannot begin firing src: a source transition is never scheduled — it fires only through accept_delivery()"
      historyLength inst `shouldReturn` recorded
    -- TestBegin.test_begin_rejects_a_foreign_transition
    it "rejects a foreign transition" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X"])])
      result <- begin inst (selectionBinding (np "elsewhere") [] []) Nothing
      result `shouldRefuse` "cannot begin firing elsewhere: not a transition of this net"
    -- TestBegin.test_begin_rejects_a_hand_built_binding_missing_its_consume_selection
    it "rejects a hand-built binding missing its consume selection" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X"])])
      recorded <- historyLength inst
      result <- begin inst (selectionBinding tt [] []) Nothing
      result
        `shouldRefuse` "cannot begin firing t: its consume selections do not match the transition's consume arcs — a live begin takes one consume selection per arc, in input-arc order, weight tokens each"
      historyLength inst `shouldReturn` recorded
    -- TestBegin.test_begin_rejects_a_hand_built_binding_missing_its_read_selection
    it "rejects a hand-built binding missing its read selection" $ do
      let gate = np "gate"
          net = netOf [place pa, place gate, place pb] [transition tt] [arc pa tt, (arc gate tt) {mode = Read}, arc tt pb]
      inst <- seeded net (markingFromList [(pa, [tok "X"]), (gate, [tok "Y"])])
      recorded <- historyLength inst
      result <- begin inst (selectionBinding tt [(pa, [tok "X"])] []) Nothing
      result
        `shouldRefuse` "cannot begin firing t: its read selections do not match the transition's read arcs — a live begin takes one read selection per arc, in input-arc order, weight tokens each"
      historyLength inst `shouldReturn` recorded
    -- TestBegin.test_begin_with_a_stale_selection_appends_nothing
    it "appends nothing for a stale selection" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X", tok "Y"])])
      binding : _ <- candidates inst
      _ <- begin inst binding Nothing >>= expectRight
      result <- begin inst binding Nothing
      result `shouldRefuse` "cannot begin firing t: stale selection — cannot consume Token('X', None) from a: token not present"
      historyLength inst `shouldReturn` 5
      length <$> inFlight inst `shouldReturn` 1
      [fresh] <- candidates inst
      o <- begin inst fresh Nothing >>= expectRight
      o.occurrence `shouldBe` 2

  describe "complete" $ do
    -- TestComplete.test_complete_deposits_per_arc_contract_and_ends_the_occurrence
    it "deposits per the arc contract and ends the occurrence" $ do
      let token' = tok "X"
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [token'])])
      o <- beginOne inst
      firing <- complete inst o (Just (handlerTokens [(pb, [token'])])) Nothing >>= expectRight
      marking inst `shouldReturn` markingFromList [(pb, [token'])]
      inFlight inst `shouldReturn` []
      firing.occurrence `shouldBe` o.occurrence
      firing.produced `shouldBe` [(pb, token')]
      records <- historyOf inst
      drop (length records - 2) records
        `shouldBe` [ RTokensProduced (TokensProduced pb [token'] 1 [] Nothing 0)
                   , RFiringCompleted (FiringCompleted tt 1 0)
                   ]
    -- TestComplete.test_a_user_handled_firing_is_a_pure_projection_recording_movements_only
    it "records a user-handled firing as a pure projection, movements only" $ do
      let stray = tok "Y"
          price _ _ = Right (handlerTokens [(pb, [tok "X"]), (np "nowhere", [stray])])
      inst <-
        seededWith
          (lineNet (Just "price"))
          defaultInstanceConfig {initialMarking = markingFromList [(pa, [tok "X"])], handlerImplementations = symbolHandlers [("price", price)]}
      o <- beginOne inst
      _ <- complete inst o (Just (handlerTokens [(pb, [tok "X"]), (np "nowhere", [stray])])) Nothing >>= expectRight
      filter isActivityRecord <$> historyOf inst `shouldReturn` []
      marking inst `shouldReturn` markingFromList [(pb, [tok "X"])]
    -- TestComplete.test_a_passthrough_firing_records_no_activity_records
    it "records no activity records for a passthrough firing" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X"])])
      o <- beginOne inst
      _ <- complete inst o (Just (handlerTokens [(pb, [tok "X"])])) Nothing >>= expectRight
      filter isActivityRecord <$> historyOf inst `shouldReturn` []
    -- TestComplete.test_complete_rejects_an_occurrence_this_instance_never_began
    it "rejects an occurrence this instance never began" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X"])])
      other <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X"])])
      foreign' <- beginOne other
      result <- complete inst foreign' (Just (handlerTokens [])) Nothing
      result `shouldRefuse` "cannot complete firing occurrence 1 (t): this instance never began it"
    -- TestComplete.test_complete_rejects_an_already_ended_occurrence
    it "rejects an already ended occurrence" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X"])])
      o <- beginOne inst
      _ <- complete inst o (Just (handlerTokens [])) Nothing >>= expectRight
      result <- complete inst o (Just (handlerTokens [])) Nothing
      result `shouldRefuse` "cannot complete firing occurrence 1 (t): not in flight — this instance's occurrence 1 already ended"

  describe "fail" $ do
    -- TestFail.test_fail_records_the_terminal_failure_and_nothing_else
    it "records the terminal failure and nothing else" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X"])])
      o <- beginOne inst
      failFiring inst o (FailureText "TimeoutError('no quote')") Nothing >>= expectRight
      records <- historyOf inst
      last records `shouldBe` RFiringFailed (FiringFailed tt "TimeoutError('no quote')" 1 0)
      marking inst `shouldReturn` emptyMarking
      inFlight inst `shouldReturn` []
    -- TestFail.test_a_failed_occurrence_no_longer_blocks_quiescence
    it "no longer blocks quiescence once failed" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X"])])
      o <- beginOne inst
      failFiring inst o (FailureText "boom") Nothing >>= expectRight
      isQuiescent inst `shouldReturn` True
      status inst `shouldReturn` Terminated
    -- TestFail.test_fail_discriminates_misuse_like_complete
    it "discriminates misuse like complete" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X"])])
      o <- beginOne inst
      failFiring inst o (FailureText "boom") Nothing >>= expectRight
      result <- failFiring inst o (FailureText "boom") Nothing
      result `shouldRefuse` "cannot fail firing occurrence 1 (t): not in flight — this instance's occurrence 1 already ended"

  describe "step through the seam" $ do
    -- TestStepThroughTheSeam.test_step_is_one_occurrence_begun_and_completed
    it "is one occurrence begun and completed" $ do
      let token' = tok "X"
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [token'])])
      Just firing <- step inst (Just 7) >>= expectRight
      firing.occurrence `shouldBe` 1
      historyOf inst
        `shouldReturn` [ RInstanceCreated (InstanceCreated (instanceIdentity inst) Nothing 0)
                       , RTokensInitialized (TokensInitialized pa [token'] 0 [] Nothing)
                       , RCandidateSelected (CandidateSelected tt 1 7)
                       , RFiringBegun (FiringBegun tt 1 Nothing 7)
                       , RTokensConsumed (TokensConsumed pa [token'] 1 [] Nothing 7)
                       , RTokensProduced (TokensProduced pb [token'] 1 [] Nothing 7)
                       , RFiringCompleted (FiringCompleted tt 1 7)
                       ]
    -- TestStepThroughTheSeam.test_step_with_a_user_handler_records_the_pure_projection_lifecycle
    it "records the pure projection lifecycle for a user handler" $ do
      inst <-
        seededWith
          (lineNet (Just "price"))
          defaultInstanceConfig
            { initialMarking = markingFromList [(pa, [tok "X"])]
            , handlerImplementations = symbolHandlers [("price", \_ _ -> Right (handlerTokens [(pb, [tok "Y"])]))]
            }
      _ <- step inst Nothing >>= expectRight
      map recordName <$> historyOf inst
        `shouldReturn` [ "InstanceCreated"
                       , "TokensInitialized"
                       , "CandidateSelected"
                       , "FiringBegun"
                       , "TokensConsumed"
                       , "TokensProduced"
                       , "FiringCompleted"
                       ]
    -- TestStepThroughTheSeam.test_a_raising_handler_records_the_failure_and_propagates
    it "records a raising handler's failure and propagates" $ do
      inst <-
        seededWith
          (lineNet (Just "price"))
          defaultInstanceConfig
            { initialMarking = markingFromList [(pa, [tok "X"])]
            , handlerImplementations = symbolHandlers [("price", \_ _ -> Left "RuntimeError('quote service down')")]
            }
      raised <- step inst Nothing >>= expectHandlerRaised
      raised `shouldBe` "RuntimeError('quote service down')"
      records <- historyOf inst
      last records `shouldBe` RFiringFailed (FiringFailed tt "RuntimeError('quote service down')" 1 0)
      marking inst `shouldReturn` emptyMarking
      inFlight inst `shouldReturn` []
    -- TestStepThroughTheSeam.test_a_result_the_commit_rejects_records_the_failure_and_propagates
    it "records the failure of a result the commit rejects and propagates" $ do
      let message =
            "cannot complete firing occurrence 1 (t): delivery-registration effect on transition t: it has input arcs — only a source transition has delivery registrations"
      inst <-
        seededWith
          (lineNet (Just "hook"))
          defaultInstanceConfig
            { initialMarking = markingFromList [(pa, [tok "X"])]
            , handlerImplementations = symbolHandlers [("hook", \_ _ -> Right (HandlerResult [] [] [DeliveryRegistration tt "nope"]))]
            }
      result <- step inst Nothing
      result `shouldRefuse` message
      records <- historyOf inst
      last records `shouldBe` RFiringFailed (FiringFailed tt ("ValueError('" <> message <> "')") 1 0)
      inFlight inst `shouldReturn` []

  describe "deliver through the seam" $ do
    let src = np "src"
        out = np "out"
        sourceNet symbol = netOf [place out] [(transition src) {handler = HandlerSymbol <$> symbol}] [arc src out]
    -- TestDeliverThroughTheSeam.test_delivery_records_carry_one_occurrence
    it "carries one occurrence on every delivery record" $ do
      let token' = tok "X"
      inst <- seeded (sourceNet Nothing) emptyMarking
      DeliveryAccepted accepted <- acceptDelivery inst src [token'] "source-event" Nothing (Just 5) >>= expectRight
      firing <- completeDelivery inst accepted (Just 5) >>= expectRight
      firing.occurrence `shouldBe` 1
      records <- historyOf inst
      drop (length records - 4) records
        `shouldBe` [ RExternalEventDelivered (ExternalEventDelivered src [token'] "source-event" 1 Nothing 5)
                   , RFiringBegun (FiringBegun src 1 Nothing 5)
                   , RTokensProduced (TokensProduced out [token'] 1 [] Nothing 5)
                   , RFiringCompleted (FiringCompleted src 1 5)
                   ]
    -- TestDeliverThroughTheSeam.test_a_handled_delivery_is_a_local_atomic_projection
    it "projects a handled delivery locally and atomically" $ do
      inst <-
        seededWith
          (sourceNet (Just "ingest"))
          defaultInstanceConfig {handlerImplementations = symbolHandlers [("ingest", \_ _ -> Right (handlerTokens [(out, [tok "X"])]))]}
      DeliveryAccepted accepted <- acceptDelivery inst src [tok "Raw"] "handled-event" Nothing Nothing >>= expectRight
      _ <- completeDelivery inst accepted Nothing >>= expectRight
      filter isActivityRecord <$> historyOf inst `shouldReturn` []
      marking inst `shouldReturn` markingFromList [(out, [tok "X"])]

  describe "value aliasing" $ do
    -- TestValueAliasingPinnedInvariant.test_value_aliasing_is_a_pinned_invariant_selections_are_by_value_not_position
    it "pins value aliasing: selections are by value, not position" $ do
      let dup = tokD "X" (obj [("n", Int 1)])
          other = tok "Y"
          net = netOf [place pa, place pb] [transition tt] [(arc pa tt) {weight = 2}, arc tt pb]
      inst <- seeded net (markingFromList [(pa, [dup, dup, other])])
      bindings <- candidates inst
      length bindings `shouldBe` 3
      bindings !! 1 `shouldBe` bindings !! 2
      fmap (toList . queueInstants) (removeTokens [dup] (queueFromPairs [(dup, 1), (dup, 2)])) `shouldBe` Right [Just 2]
      first' <- begin inst (bindings !! 1) Nothing >>= expectRight
      marking inst `shouldReturn` markingFromList [(pa, [dup])]
      result <- begin inst (bindings !! 2) Nothing
      result `shouldRefuse` "cannot begin firing t: stale selection — cannot consume Token('Y', None) from a: token not present"
      inFlight inst `shouldReturn` [first']

  describe "replay with occurrences" $ do
    -- TestReplayWithOccurrences.test_replay_of_an_in_flight_tail_leaves_tokens_consumed
    it "replays an in-flight tail with its tokens consumed" $ do
      inst <- seeded (lineNet Nothing) (markingFromList [(pa, [tok "X"])])
      _ <- beginOne inst
      records <- historyOf inst
      replayMarking records `shouldBe` Right emptyMarking
      live <- marking inst
      replayMarking records `shouldBe` Right live
