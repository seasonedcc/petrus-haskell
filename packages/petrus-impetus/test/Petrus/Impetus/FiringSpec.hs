-- | Parity: the firing halves of
-- @tests/petrus/impetus/petrinet/test_arc_weights.py@,
-- @tests/petrus/impetus/petrinet/test_inhibitor_arc.py@,
-- @tests/petrus/impetus/petrinet/test_read_arc.py@, and
-- @tests/petrus/impetus/petrinet/test_arc_filters.py@.
--
-- The reference fires through @Instance.step()@ / @Instance.run()@: the
-- conservative scheduler takes the head candidate, @begin_firing@ applies
-- it, the default passthrough handler @route@s the binding's tokens through
-- the output arcs, and @complete_firing@ deposits them. 'stepNet' and
-- 'runNet' compose exactly those kernel transforms. History records
-- (@FiringBegun@, @TokensConsumed@, ...) and @replay_marking@ are not
-- ported yet; the movement effects 'beginFiring' and 'completeFiring'
-- return are the kernel half of those records and are asserted instead.
module Petrus.Impetus.FiringSpec (spec) where

import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Petrus.Impetus.ArcFiltersSpec (big, celAmountAtLeast100, invoice, isBig, small)
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport
import Petrus.Json (Json (..))
import Test.Hspec hiding (pending)
import Test.QuickCheck

step :: HasCallStack => Net -> Implementations -> Marking -> IO Fired
step net implementations marking =
  expectRight (stepNet net implementations marking) >>= \case
    Just fired -> pure fired
    Nothing -> expectationFailure "expected an enabled transition" >> error "unreachable"

runTo :: HasCallStack => Net -> Implementations -> Marking -> IO Marking
runTo net implementations marking = expectRight (runNet net implementations marking)

spec :: Spec
spec = describe "Petrinet.Firing" $ do
  describe "weighted consume" $ do
    let src = np "src"
        pack = np "pack"
        dst = np "dst"
        -- output weight is ignored
        net = netOf [place src, place dst] [transition pack] [(arc src pack) {weight = 2}, (arc pack dst) {weight = 2}]
    -- test_firing_consumes_exactly_the_weight
    it "consumes exactly the weight" $ do
      fired <- step net noImplementations (fromCounts [(src, 3)])
      toList (placeTokens src fired.after) `shouldBe` [black]
    -- test_deposits_one_token_per_consumed_token_never_merged
    it "deposits one token per consumed token, never merged" $ do
      fired <- step net noImplementations (fromCounts [(src, 3)])
      toList (placeTokens dst fired.after) `shouldBe` [black, black]
    -- test_strands_the_remainder_and_terminates
    it "strands the remainder and terminates" $ do
      final <- runTo net noImplementations (fromCounts [(src, 3)])
      enabledTransitions net final noImplementations `shouldBe` []
      final `shouldBe` markingFromList [(src, [black]), (dst, [black, black])]

  describe "inhibitor gating" $ do
    let blocker = np "blocker"
        trigger = np "trigger"
        drain = np "drain"
        gate = np "gate"
        drained = np "drained"
        gated = np "gated_done"
        net =
          netOf
            [place blocker, place trigger, place drained, place gated]
            [transition drain, transition gate]
            [arc blocker drain, (arc blocker gate) {mode = Inhibit}, arc trigger gate, arc drain drained, arc gate gated]
        seeded = fromCounts [(blocker, 1), (trigger, 1)]
    -- test_becomes_enabled_once_the_inhibiting_place_drains
    it "becomes enabled once the inhibiting place drains" $ do
      fired <- step net noImplementations seeded
      fired.binding.transition `shouldBe` drain
      enabledTransitions net fired.after noImplementations `shouldBe` [gate]
    -- test_full_sequence_drains_then_gates_to_termination
    it "drains, then gates, to termination" $ do
      final <- runTo net noImplementations seeded
      enabledTransitions net final noImplementations `shouldBe` []
      final `shouldBe` markingFromList [(drained, [black]), (gated, [black])]

  describe "read arcs" $ do
    let config = np "config"
        trigger = np "trigger"
        process = np "process"
        done = np "done"
        settings = tokD "Config" (obj [("mode", String "strict")])
        net =
          netOf
            [place config, place trigger, place done]
            [transition process]
            [(arc config process) {mode = Read}, arc trigger process, arc process done]
        seeded = markingFromList [(config, [settings]), (trigger, [black])]
        a = np "a"
        t = np "t"
        overlapNet = netOf [place a, place (np "b")] [transition t] [arc a t, (arc a t) {mode = Read}, arc t (np "b")]
    -- test_read_token_is_peeked_not_consumed
    it "peeks the read token instead of consuming it" $ do
      fired <- step net noImplementations seeded
      toList (placeTokens config fired.after) `shouldBe` [settings]
    -- test_read_contributes_nothing_to_output
    it "contributes nothing to output" $ do
      fired <- step net noImplementations seeded
      toList (placeTokens done fired.after) `shouldBe` [black]
    -- test_begin_records_the_read_selection_in_the_begin_batch (the begin
    -- effects; FiringBegun and occurrence numbering are History's)
    it "begins with the consumes, then the read selection" $ do
      [b] <- expectRight (candidates net seeded noImplementations Nothing)
      (effects, _) <- expectRight (beginFiring seeded b)
      effects `shouldBe` [ConsumedTokens trigger [black], ReadTokens config [settings]]
    -- test_a_binding_that_consumes_its_own_read_token_cannot_begin
    it "refuses to begin a binding that consumes its own read token" $ do
      [b] <- expectRight (candidates overlapNet (markingFromList [(a, [tok "X"])]) noImplementations Nothing)
      beginFiring (markingFromList [(a, [tok "X"])]) b
        `shouldFailWith` "cannot read Token('X', None) from a: token not present"
    -- test_the_read_validates_against_the_surviving_token
    it "validates the read against the surviving token" $ do
      let marking = markingFromList [(a, [tok "X", tok "X"])]
      (b : _) <- expectRight (candidates overlapNet marking noImplementations Nothing)
      (effects, begun) <- expectRight (beginFiring marking b)
      effects `shouldBe` [ConsumedTokens a [tok "X"], ReadTokens a [tok "X"]]
      begun `shouldBe` markingFromList [(a, [tok "X"])]
    -- not translated: test_tokens_read_is_replay_inert_for_the_marking
    -- (needs History and replay_marking, which are not ported yet).

  describe "colored consume selection" $ do
    let pending = np "pending"
        cash = np "cash"
        out = np "out"
        net = netOf [place pending, place out] [transition cash] [withArcColor (Just "Payment") (arc pending cash), arc cash out]
    -- test_fire_consumes_the_selected_token_mid_queue
    it "consumes the selected token mid-queue" $ do
      fired <- step net noImplementations (markingFromList [(pending, [invoice, big])])
      fired.after `shouldBe` markingFromList [(pending, [invoice]), (out, [big])]
    -- test_movement_records_carry_the_selected_token_and_replay (movement
    -- effects; the replay half needs History)
    it "carries the selected token through the movement effects" $ do
      fired <- step net noImplementations (markingFromList [(pending, [invoice, big])])
      fired.begun `shouldBe` [ConsumedTokens pending [big]]
      fired.produced `shouldBe` [ProducedTokens out [big]]
      bindingTokens fired.binding `shouldBe` [big]

  describe "named filter selection" $ do
    let pending = np "pending"
        pay = np "pay"
        out = np "out"
        net = netOf [place pending, place out] [transition pay] [withArcColor (Just "Payment") ((arc pending pay) {filter = Just (FilterSymbol "is_big")}), arc pay out]
        bigs = impls [("is_big", isBig)] []
    -- test_filter_narrows_which_tokens_the_arc_admits
    it "narrows which tokens the arc admits" $
      runTo net bigs (markingFromList [(pending, [small, big])]) `shouldReturn` markingFromList [(pending, [small]), (out, [big])]
    -- test_movement_records_carry_the_filter_selected_token_and_replay
    it "carries the filter-selected token through the movement effects" $ do
      fired <- step net bigs (markingFromList [(pending, [small, big])])
      fired.begun `shouldBe` [ConsumedTokens pending [big]]
      fired.produced `shouldBe` [ProducedTokens out [big]]
      bindingTokens fired.binding `shouldBe` [big]

  describe "read arc filters" $ do
    let config = np "config"
        pending = np "pending"
        approve = np "approve"
        out = np "out"
        usdConfig = tokD "Config" (obj [("currency", String "USD"), ("limit", Int 500)])
        eurConfig = tokD "Config" (obj [("currency", String "EUR"), ("limit", Int 100)])
        net =
          netOf
            [place config, place pending, place out]
            [transition approve]
            [(arc config approve) {mode = Read, filter = Just (FilterSymbol "usd")}, arc pending approve, arc approve out]
        usd = impls [("usd", \t -> (== String "USD") <$> field "currency" t)] []
        marking = markingFromList [(config, [eurConfig, usdConfig]), (pending, [big])]
    -- test_read_arc_filter_selects_the_matching_token_and_leaves_it_in_place
    it "selects the matching token and leaves it in place" $ do
      bindings <- expectRight (candidates net marking usd Nothing)
      map (.read) bindings `shouldBe` [[(config, [usdConfig])]]
      fired <- step net usd marking
      toList (placeTokens config fired.after) `shouldBe` [eurConfig, usdConfig]

  describe "CEL filter selection" $ do
    let pending = np "pending"
        pay = np "pay"
        out = np "out"
        expression = "amount >= 100"
        net = netOf [place pending, place out] [transition pay] [withArcColor (Just "Payment") ((arc pending pay) {filter = Just (FilterCel (unsafeCel expression))}), arc pay out]
        compiled = Implementations (Map.fromList [(ByCel (unsafeCel expression), celAmountAtLeast100)]) Map.empty
    -- test_cel_filter_selects_by_bare_data_fields
    it "selects by bare data fields" $
      runTo net compiled (markingFromList [(pending, [small, big])]) `shouldReturn` markingFromList [(pending, [small]), (out, [big])]
    -- test_cel_selection_consumes_and_replays_like_any_other (movement
    -- effects; the replay half needs History)
    it "consumes like any other selection" $ do
      fired <- step net compiled (markingFromList [(pending, [small, big])])
      bindingTokens fired.binding `shouldBe` [big]
      fired.begun `shouldBe` [ConsumedTokens pending [big]]

  describe "movement primitives" $ do
    let t = np "t"
        a = np "a"
        b = np "b"
        typed = netOf [place (np "in"), place a, place b] [transition t] [arc (np "in") t, withArcColor (Just "X") (arc t a), arc t b]
    it "routes each token to every admitting output arc, dropping the rest" $
      route [tok "X", tok "Y"] (outputs typed t) `shouldBe` [(a, [tok "X"]), (b, [tok "X", tok "Y"])]
    it "coalesces repeated destinations and drops what no output arc admits" $ do
      let (effects, marking) = completeFiring typed emptyMarking t [(a, [tok "Y"]), (b, [black]), (a, [tok "X"])]
      effects `shouldBe` [ProducedTokens a [tok "X"], ProducedTokens b [black]]
      marking `shouldBe` markingFromList [(a, [tok "X"]), (b, [black])]
    it "refuses to begin a consume of an absent token" $
      beginFiring emptyMarking (selectionBinding t [(np "in", [black])] [])
        `shouldFailWith` "cannot consume Token.black() from in: token not present"
    it "routes in token order per target, keeping only admitted tokens (property)" $
      property $ \(colors :: [Bool]) ->
        let tokens = [if c then tok "X" else tok "Y" | c <- colors]
            routed = route tokens (outputs typed t)
         in (lookup a routed, lookup b routed)
              === ( if or colors then Just [tk | tk <- tokens, tk == tok "X"] else Nothing
                  , if null tokens then Nothing else Just tokens
                  )
