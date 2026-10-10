-- | Parity: @tests/petrus/impetus/instance/test_firing.py@ — routing, the
-- default passthrough, the conservative scheduler, and the begin/end firing
-- lifecycle.
--
-- The reference's @_fire@ drives the two history-independent Petrinet
-- transforms ('beginFiring', a handler, 'completeFiring'); 'fire' here is
-- the same composition. The reference's Instance-layer record-authoring
-- helpers (@instance.begin_firing@ / @instance.complete_firing@) are not
-- exported by the Haskell port — the 'begin' and 'complete' doors author the
-- same records inline — so their two contract tests are asserted through
-- the doors instead (and listed as not at parity in the ledger).
module Petrus.Impetus.InstanceFiringSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Petrus.Impetus.Binding
import Petrus.Impetus.History.Records
import Petrus.Impetus.Instance qualified as I
import Petrus.Impetus.InstanceSupport
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Petrus.Json (Json (..))
import Test.Hspec

-- | The reference's @_fire@: begin, run the handler over the transition's
-- output arcs, complete.
fire :: HasCallStack => Net -> Marking -> Binding -> Handler -> IO (Marking, [BeginEffect], [ProducedTokens])
fire net m binding handler = do
  (effects, begun) <- expectRight (beginFiring m binding)
  projected <- expectRight (handler binding (outputs net binding.transition))
  let (produced, final) = completeFiring net begun binding.transition projected.tokens
  pure (final, effects, produced)

a, b, c, t :: NetPath
a = np "a"
b = np "b"
c = np "c"
t = np "t"

lineNet :: Net
lineNet = netOf [place a, place b] [transition t] [arc a t, arc t b]

forkNet :: Net
forkNet = netOf [place a, place b, place c] [transition t] [arc a t, arc t b, arc t c]

-- | The single candidate of a marking.
onlyCandidate :: HasCallStack => Net -> Marking -> IO Binding
onlyCandidate net m =
  expectRight (candidates net m noImplementations Nothing) >>= \case
    [one] -> pure one
    other -> expectationFailure ("expected exactly one candidate, got " <> show other) >> error "unreachable"

tokensTo :: [(NetPath, [Token])] -> Handler
tokensTo produced _ _ = Right (handlerTokens produced)

spec :: Spec
spec = describe "Instance firing" $ do
  describe "route" $ do
    -- TestRoute.test_each_token_goes_to_every_admitting_arc_order_preserved
    it "sends each token to every admitting arc, order preserved" $ do
      let x1 = tokD "X" (obj [("n", Int 1)])
          x2 = tokD "X" (obj [("n", Int 2)])
          y = tok "Y"
          typed = withArcColor (Just "X") (arc t b)
          untyped = arc t c
      route [x1, y, x2] [typed, untyped] `shouldBe` [(b, [x1, x2]), (c, [x1, y, x2])]
    -- TestRoute.test_two_arcs_to_one_target_concatenate_in_arc_order
    it "concatenates two arcs to one target in arc order" $ do
      let x = tok "X"
          y = tok "Y"
      route [y, x] [withArcColor (Just "X") (arc t b), withArcColor (Just "Y") (arc t b)] `shouldBe` [(b, [x, y])]
    -- TestRoute.test_unrouted_tokens_drop_silently
    it "drops unrouted tokens silently" $
      route [tok "X"] [withArcColor (Just "Y") (arc t b)] `shouldBe` []

  describe "passthrough" $ do
    -- TestPassthrough.test_forwards_each_token_through_every_admitting_output_arc
    it "forwards each token through every admitting output arc" $ do
      let token' = tok "X"
          binding = selectionBinding t [(a, [token'])] []
          typed = withArcColor (Just "X") (arc t b)
          untyped = arc t c
          other = withArcColor (Just "Y") (arc t (np "d"))
      passthrough binding [typed, untyped, other] `shouldBe` Right (handlerTokens [(b, [token']), (c, [token'])])
    -- TestPassthrough.test_forwards_only_consumed_selections
    it "forwards only consumed selections" $
      passthrough (selectionBinding t [] [(a, [tok "X"])]) [arc t b] `shouldBe` Right (handlerTokens [])
    -- TestPassthrough.test_a_transition_with_no_output_arcs_is_a_sink
    it "treats a transition with no output arcs as a sink" $
      passthrough (selectionBinding t [(a, [black])] []) [] `shouldBe` Right (handlerTokens [])
    -- TestPassthrough.test_forwards_delivered_tokens_of_a_source_firing
    it "forwards the delivered tokens of a source firing" $
      passthrough (deliveredBinding t [tok "X"]) [arc t b] `shouldBe` Right (handlerTokens [(b, [tok "X"])])

  describe "selectConservative" $ do
    -- TestSelectConservative.test_picks_the_first_binding
    it "picks the first binding" $ do
      let bindings = [selectionBinding (np "t1") [] [], selectionBinding (np "t2") [] []]
      I.selectConservative bindings `shouldBe` Just (selectionBinding (np "t1") [] [])
    -- TestSelectConservative.test_returns_none_when_empty
    it "returns Nothing when empty" $
      I.selectConservative [] `shouldBe` Nothing

  describe "begin/end firing" $ do
    -- TestBeginEndFiring.test_petrinet_source_binding_begins_with_no_movement_effects
    it "begins a source binding with no movement effects" $
      beginFiring emptyMarking (deliveredBinding (np "source") [tok "event"]) `shouldBe` Right ([], emptyMarking)
    -- TestBeginEndFiring.test_petrinet_consume_precedes_read_and_same_token_fails_loud
    it "consumes before reading, so reading the consumed token fails loud" $ do
      let shared = np "shared"
          binding = Binding t [(shared, [tok "X"])] [(shared, [tok "X"])] []
      beginFiring (markingFromList [(shared, [tok "X"])]) binding
        `shouldFailWith` "cannot read Token('X', None) from shared: token not present"
    -- TestBeginEndFiring.test_instance_begin_firing_retains_its_record_authoring_contract
    -- (not at parity: the helper is not exported; the begin door authors the
    -- same FiringBegun + TokensConsumed batch at the effective instant)
    it "authors the begin records through the begin door" $ do
      let token' = tok "X"
      inst <- seeded lineNet (markingFromList [(a, [token'])])
      [binding] <- I.candidates inst
      o <- I.begin inst binding (Just 11) >>= expectRight
      I.marking inst `shouldReturn` emptyMarking
      o.records
        `shouldBe` [ RFiringBegun (FiringBegun t 1 Nothing 11)
                   , RTokensConsumed (TokensConsumed a [token'] 1 [] Nothing 11)
                   ]
    -- TestBeginEndFiring.test_instance_complete_firing_retains_its_outcome_and_registration_contract
    -- (not at parity: the helper is not exported; the complete door authors
    -- produces, registration closes, opens, then FiringCompleted — here
    -- closing the source's armed "default" key, since the door validates
    -- each effect against the armed registrations)
    it "authors the completion records through the complete door" $ do
      let token' = tok "X"
          source = np "source"
          net = netOf [place a, place b] [transition t, transition source] [arc a t, arc t b, arc source b]
          closeDefault = DeliveryRegistration source "default"
          openNew = DeliveryRegistration source "new"
      inst <- seeded net (markingFromList [(a, [token'])])
      o <- beginOne inst
      outcome <- I.complete inst o (Just (HandlerResult [(b, [token'])] [openNew] [closeDefault])) (Just 12) >>= expectRight
      I.marking inst `shouldReturn` markingFromList [(b, [token'])]
      let appended =
            [ RTokensProduced (TokensProduced b [token'] 1 [] Nothing 12)
            , RDeliveryRegistrationClosed (DeliveryRegistrationClosed source "default" (Just 1) 12)
            , RDeliveryRegistrationOpened (DeliveryRegistrationOpened source "new" (Just 1) 12)
            , RFiringCompleted (FiringCompleted t 1 12)
            ]
      outcome.consumed `shouldBe` [token']
      outcome.produced `shouldBe` [(b, token')]
      outcome.records `shouldBe` o.records ++ appended
      I.armed inst `shouldReturn` Map.fromList [(source, Set.fromList ["new"])]
    -- TestBeginEndFiring.test_begin_consumes_and_end_produces
    it "consumes at begin and produces at end" $ do
      let token' = tok "X"
          m = markingFromList [(a, [token'])]
      binding <- onlyCandidate lineNet m
      (final, effects, produced) <- fire lineNet m binding passthrough
      final `shouldBe` markingFromList [(b, [token'])]
      effects `shouldBe` [ConsumedTokens a [token']]
      produced `shouldBe` [ProducedTokens b [token']]
    -- TestBeginEndFiring.test_returns_movements_in_lifecycle_order
    it "returns movements in lifecycle order" $ do
      let token' = tok "X"
          m = markingFromList [(a, [token'])]
      binding <- onlyCandidate lineNet m
      (_, begun, completed) <- fire lineNet m binding passthrough
      begun `shouldBe` [ConsumedTokens a [token']]
      completed `shouldBe` [ProducedTokens b [token']]
    -- TestBeginEndFiring.test_begin_fails_loud_on_a_stale_selection_before_any_record_matters
    it "fails loud on a stale selection before any record matters" $ do
      binding <- onlyCandidate lineNet (markingFromList [(a, [tok "X"])])
      beginFiring emptyMarking binding `shouldFailWith` "cannot consume Token('X', None) from a: token not present"
    -- TestBeginEndFiring.test_begin_records_read_selections_after_the_consumes_in_input_arc_order
    it "records read selections after the consumes, in input-arc order" $ do
      let gate = np "gate"
          settings = tokD "Config" (obj [("mode", String "strict")])
          net = netOf [place a, place gate, place b] [transition t] [arc a t, (arc gate t) {mode = Read}, arc t b]
          m = markingFromList [(a, [black]), (gate, [settings])]
      binding <- onlyCandidate net m
      (effects, final) <- expectRight (beginFiring m binding)
      effects `shouldBe` [ConsumedTokens a [black], ReadTokens gate [settings]]
      final `shouldBe` markingFromList [(gate, [settings])]
    -- TestBeginEndFiring.test_a_stale_read_selection_cannot_begin
    it "refuses a stale read selection" $ do
      let gate = np "gate"
          net = netOf [place a, place gate, place b] [transition t] [arc a t, (arc gate t) {mode = Read}, arc t b]
      binding <- onlyCandidate net (markingFromList [(a, [black]), (gate, [tok "Config"])])
      beginFiring (markingFromList [(a, [black])]) binding
        `shouldFailWith` "cannot read Token('Config', None) from gate: token not present"
    -- TestBeginEndFiring.test_a_user_handlers_projection_records_movements_only
    it "records only movements for a user handler's projection" $ do
      let m = markingFromList [(a, [tok "X"])]
      binding <- onlyCandidate lineNet m
      (final, begun, completed) <- fire lineNet m binding (tokensTo [(b, [tok "Y"]), (np "nowhere", [tok "Z"])])
      final `shouldBe` markingFromList [(b, [tok "Y"])]
      begun `shouldBe` [ConsumedTokens a [tok "X"]]
      completed `shouldBe` [ProducedTokens b [tok "Y"]]
    -- TestBeginEndFiring.test_fans_one_token_out_to_every_output_place
    it "fans one token out to every output place" $ do
      let token' = tok "X"
          m = markingFromList [(a, [token'])]
      binding <- onlyCandidate forkNet m
      (final, _, produced) <- fire forkNet m binding passthrough
      final `shouldBe` markingFromList [(b, [token']), (c, [token'])]
      produced `shouldBe` [ProducedTokens b [token'], ProducedTokens c [token']]
    -- TestBeginEndFiring.test_registration_effects_are_not_part_of_the_petrinet_transform
    it "keeps registration effects out of the Petrinet transform" $ do
      let src = np "src"
          net = netOf [place a, place b] [(transition t) {handler = Just (HandlerSymbol "h")}, transition src] [arc a t, arc t b, arc src b]
          m = markingFromList [(a, [tok "X"])]
          result = HandlerResult [(b, [tok "Y"])] [DeliveryRegistration src "new"] [DeliveryRegistration src "old"]
      binding <- onlyCandidate net m
      (_, begun) <- expectRight (beginFiring m binding)
      fst (completeFiring net begun binding.transition result.tokens) `shouldBe` [ProducedTokens b [tok "Y"]]
    -- TestBeginEndFiring.test_deposits_the_supplied_handler_tokens
    it "deposits the supplied handler tokens" $ do
      let m = markingFromList [(a, [tok "X"])]
      binding <- onlyCandidate lineNet m
      (final, _, produced) <- fire lineNet m binding (tokensTo [(b, [tok "Y"])])
      final `shouldBe` markingFromList [(b, [tok "Y"])]
      produced `shouldBe` [ProducedTokens b [tok "Y"]]
    -- TestBeginEndFiring.test_handler_destination_keys_may_be_plain_strings:
    -- enforced by types (a destination is a NetPath; there is no second
    -- spelling to normalize).
    -- TestBeginEndFiring.test_destination_keys_resolving_to_one_place_coalesce_into_one_record
    it "coalesces destination entries naming one place into one record" $ do
      let m = markingFromList [(a, [tok "X"])]
      binding <- onlyCandidate lineNet m
      (_, _, produced) <- fire lineNet m binding (tokensTo [(b, [tok "Y"]), (b, [tok "Z"])])
      produced `shouldBe` [ProducedTokens b [tok "Y", tok "Z"]]
