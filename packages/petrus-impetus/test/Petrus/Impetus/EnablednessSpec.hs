-- | Parity: @tests/petrus/impetus/petrinet/test_enabledness.py@, and the
-- enabledness halves of @test_arc_weights.py@, @test_read_arc.py@, and
-- @test_inhibitor_arc.py@ (their firing halves live in
-- "Petrus.Impetus.FiringSpec"; @test_arc_filters.py@ lives in
-- "Petrus.Impetus.ArcFiltersSpec").
module Petrus.Impetus.EnablednessSpec (spec) where

import Control.Monad.Trans.State.Strict (evalState, runState)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport
import Petrus.Json (Json (..))
import Test.Hspec hiding (pending)
import Test.QuickCheck

-- | Two transitions competing for @p@; @src@ is a source (no inputs).
competingNet :: Net
competingNet =
  netOf
    [place (np "p"), place (np "out")]
    [transition (np "t1"), transition (np "t2"), transition (np "src")]
    [arc (np "p") (np "t1"), arc (np "p") (np "t2"), arc (np "src") (np "out")]

plain :: Net -> Marking -> IO [Binding]
plain net marking = expectRight (candidates net marking noImplementations Nothing)

x, y :: Integer -> Token
x n = tokD "X" (obj [("n", Int n)])
y n = tokD "Y" (obj [("n", Int n)])

oddFilter :: Filter
oddFilter t = odd <$> numberField "n" t

-- | @offer(arc, marking, filters, anchors=...)@ with no filter identity.
offerOf :: Arc -> Marking -> Implementations -> Maybe (Map.Map NetPath (Seq.Seq Instant)) -> Either EnablednessError Offer
offerOf a marking implementations anchors = evalState (offer a marking implementations anchors Nothing) []

-- | Combinations count @C(n, k)@.
binomial :: Int -> Int -> Int
binomial n k
  | k < 0 || k > n = 0
  | otherwise = product [n - k + 1 .. n] `div` product [1 .. k]

newtype QueueColors = QueueColors [Token]
  deriving stock (Show)

instance Arbitrary QueueColors where
  arbitrary = do
    n <- chooseInt (0, 6)
    QueueColors <$> vectorOf n (elements [tok "X", tok "Y", tokD "X" (Int 1), black])

spec :: Spec
spec = describe "Petrinet.Enabledness" $ do
  describe "candidates" $ do
    -- test_source_transitions_are_excluded
    it "excludes source transitions" $ do
      bindings <- plain competingNet (markingFromList [(np "p", [black])])
      map (.transition) bindings `shouldNotContain` [np "src"]
    -- test_requires_available_tokens
    it "requires available tokens" $
      plain competingNet emptyMarking `shouldReturn` []
    -- test_order_is_stable_and_path_sorted
    it "orders candidates stably by path" $ do
      bindings <- plain competingNet (markingFromList [(np "p", [black])])
      map (.transition) bindings `shouldBe` [np "t1", np "t2"]
    -- test_public_candidates_keeps_named_filter_mapping_compatibility
    it "binds a named filter by its symbol" $ do
      let pending = np "pending"
          chooser = np "choose"
          accepted = tokD "Value" (obj [("accepted", Bool True)])
          rejected = tokD "Value" (obj [("accepted", Bool False)])
          net = netOf [place pending] [transition chooser] [(arc pending chooser) {filter = Just (FilterSymbol "accepted")}]
          acceptedFilter t =
            field "accepted" t >>= \case
              Bool b -> Right b
              other -> Left ("TypeError(" <> T.pack (show other) <> ")")
      bindings <- expectRight (candidates net (markingFromList [(pending, [rejected, accepted])]) (impls [("accepted", acceptedFilter)] []) Nothing)
      map (.consumed) bindings `shouldBe` [[(pending, [accepted])]]
    -- test_binding_records_the_tokens_it_would_consume
    it "records the tokens a binding would consume" $ do
      bindings <- plain competingNet (markingFromList [(np "p", [tok "X"])])
      map bindingTokens (take 1 bindings) `shouldBe` [[tok "X"]]
    -- test_delivered_tokens_join_the_binding_tokens
    it "lets delivered tokens join the binding tokens" $ do
      let t = tokD "WebhookEvent" (obj [("id", Int 1)])
      b <- expectRight (mkBinding (np "src") [] [] [t])
      bindingTokens b `shouldBe` [t]
      bindingPeeked b `shouldBe` [t]
      deliveredBinding (np "src") [t] `shouldBe` b
    -- test_a_delivered_binding_rejects_input_selections
    it "refuses a delivered binding that also selects" $ do
      let t = tok "X"
          message = "binding for src: a delivered binding is a source firing and selects nothing — it cannot also carry consumed or read selections"
      mkBinding (np "src") [(np "p", [t])] [] [t] `shouldFailWith` message
      mkBinding (np "src") [] [(np "p", [t])] [t] `shouldFailWith` message

  describe "multi-binding enumeration" $ do
    let p = np "p"
        q = np "q"
        t = np "t"
        out = np "out"
    -- test_a_transition_is_enabled_under_every_admissible_selection
    it "enables a transition under every admissible selection" $ do
      let net = netOf [place p, place out] [transition t] [arc p t, arc t out]
      bindings <- plain net (markingFromList [(p, [x 0, x 1])])
      map (.consumed) bindings `shouldBe` [[(p, [x 0])], [(p, [x 1])]]
    -- test_join_bindings_enumerate_input_arc_major_fifo_minor
    it "enumerates join bindings input-arc-major, FIFO-minor" $ do
      let net = netOf [place p, place q, place out] [transition t] [withArcColor (Just "X") (arc p t), withArcColor (Just "Y") (arc q t), arc t out]
      bindings <- plain net (markingFromList [(p, [x 0, x 1]), (q, [y 0, y 1])])
      map (.consumed) bindings
        `shouldBe` [ [(p, [x 0]), (q, [y 0])]
                   , [(p, [x 0]), (q, [y 1])]
                   , [(p, [x 1]), (q, [y 0])]
                   , [(p, [x 1]), (q, [y 1])]
                   ]
    -- test_a_weighted_arc_enumerates_admitted_combinations_in_order
    it "enumerates a weighted arc's admitted combinations in order" $ do
      let net = netOf [place p, place out] [transition t] [(arc p t) {weight = 2}, arc t out]
      bindings <- plain net (markingFromList [(p, [x 0, x 1, x 2])])
      map (.consumed) bindings `shouldBe` [[(p, [x 0, x 1])], [(p, [x 0, x 2])], [(p, [x 1, x 2])]]

    it "puts the head selection first and enumerates C(admitted, weight) bindings (property)" $
      property $ \(QueueColors queue) (weightChoice :: Int) ->
        let w = 1 + weightChoice `mod` 3
            a = withArcColor (Just "X") ((arc p t) {weight = w})
            net = netOf [place p, place out] [transition t] [a, arc t out]
            admittedCount = length [tk | tk <- queue, tk.color == Just "X"]
         in case (candidates net (markingFromList [(p, queue)]) noImplementations Nothing, selection a queue noImplementations) of
              (Right bindings, Right (headSelection, [])) ->
                length bindings === binomial admittedCount w
                  .&&. ( if admittedCount >= w
                           then map (.consumed) (take 1 bindings) === [[(p, headSelection)]]
                           else bindings === []
                       )
              other -> counterexample (show other) False

  describe "selection" $ do
    let p = np "p"
        t = np "t"
        odds = impls [("odd", oddFilter)] []
    -- test_selects_the_first_weight_admitted_tokens_in_queue_order
    it "selects the first weight admitted tokens in queue order" $
      selection (withArcColor (Just "X") ((arc p t) {weight = 2})) [y 9, x 1, x 2, x 3] noImplementations
        `shouldBe` Right ([x 1, x 2], [])
    -- test_an_untyped_unfiltered_arc_degenerates_to_the_queue_front
    it "degenerates to the queue front for an untyped unfiltered arc" $
      selection (arc p t) [y 9, x 1] noImplementations `shouldBe` Right ([y 9], [])
    -- test_admission_is_color_narrowed_by_filter
    it "narrows color admission by the filter" $
      selection (withArcColor (Just "X") ((arc p t) {filter = Just (FilterSymbol "odd")})) [y 9, x 1, x 2, x 3] odds
        `shouldBe` Right ([x 1], [])
    -- test_a_color_mismatch_never_reaches_the_filter ("no warning" = no diagnostic)
    it "never reaches the filter on a color mismatch" $
      admitted (withArcColor (Just "X") ((arc p t) {filter = Just (FilterSymbol "odd")})) (Token (Just "Y") Null) odds Nothing
        `shouldBe` Right (False, [])
    -- test_a_raising_filter_means_not_admitted_plus_diagnostic
    it "treats a raising filter as not admitted, with a diagnostic" $ do
      let a = (arc p t) {filter = Just (FilterSymbol "odd")}
      (ok, diagnostics) <- expectRight (admitted a black odds Nothing)
      ok `shouldBe` False
      diagnostics `shouldBe` [FilterEvaluationFailed (FilterSymbol "odd") Nothing "TypeError(\"'NoneType' object is not subscriptable\")" black]

  describe "offer" $ do
    let p = np "p"
        t = np "t"
    -- test_a_consume_arc_below_weight_vetoes
    it "vetoes for a consume arc below weight" $
      offerOf (withArcColor (Just "X") ((arc p t) {weight = 2})) (markingFromList [(p, [x 1])]) noImplementations Nothing
        `shouldBe` Right Veto
    -- test_an_inhibit_arc_at_weight_vetoes
    it "vetoes for an inhibit arc at weight" $
      offerOf ((arc p t) {mode = Inhibit}) (markingFromList [(p, [x 1])]) noImplementations Nothing
        `shouldBe` Right Veto
    -- test_an_inhibit_arc_below_weight_is_satisfied_contributing_nothing
    it "is satisfied for an inhibit arc below weight" $
      offerOf (withArcColor (Just "X") ((arc p t) {mode = Inhibit})) (markingFromList [(p, [tok "Y"])]) noImplementations Nothing
        `shouldBe` Right Satisfied
    -- test_alternatives_enumerate_admitted_combinations_head_first
    it "enumerates admitted combinations head first" $ do
      let a = withArcColor (Just "X") ((arc p t) {weight = 2})
      offerOf a (markingFromList [(p, [x 1, tok "Y", x 2, x 3])]) noImplementations Nothing
        `shouldBe` Right
          ( Alternatives
              a
              [ Alternative (p, [x 1, x 2]) []
              , Alternative (p, [x 1, x 3]) []
              , Alternative (p, [x 2, x 3]) []
              ]
          )
    -- test_admission_is_color_narrowed_by_filter
    it "narrows color admission by the filter" $ do
      let a = withArcColor (Just "X") ((arc p t) {filter = Just (FilterSymbol "odd")})
      offerOf a (markingFromList [(p, [x 1, x 2, x 3])]) (impls [("odd", oddFilter)] []) Nothing
        `shouldBe` Right (Alternatives a [Alternative (p, [x 1]) [], Alternative (p, [x 3]) []])
    -- test_anchors_ride_each_alternative_when_demanded
    it "threads anchors through each alternative when demanded" $ do
      let a = withArcColor (Just "X") (arc p t)
      offerOf a (markingFromList [(p, [tok "Y", x 1, x 2])]) noImplementations (Just (Map.fromList [(p, Seq.fromList [0, 4, 9])]))
        `shouldBe` Right (Alternatives a [Alternative (p, [x 1]) [4], Alternative (p, [x 2]) [9]])
    -- test_no_anchor_demand_threads_no_instants
    it "threads no instants without an anchor demand" $ do
      let a = arc p t
      offerOf a (markingFromList [(p, [x 1])]) noImplementations Nothing
        `shouldBe` Right (Alternatives a [Alternative (p, [x 1]) []])
    -- test_missing_or_misaligned_instants_fail_loud_when_demanded
    it "fails loud on missing or misaligned instants" $
      offerOf (withArcColor (Just "X") (arc p t)) (markingFromList [(p, [tok "Y", x 1])]) noImplementations (Just (Map.fromList [(p, Seq.fromList [0])]))
        `shouldBe` Left (MisalignedInstants t p 1 1)
    it "collects no diagnostics for an unfiltered offer" $ do
      let (_, diagnostics) = runState (offer (arc p t) (markingFromList [(p, [x 1])]) noImplementations Nothing Nothing) []
      diagnostics `shouldBe` []

  -- test_arc_weights.py (enabledness half)
  describe "weighted consume" $ do
    let src = np "src"
        pack = np "pack"
        dst = np "dst"
        net = netOf [place src, place dst] [transition pack] [(arc src pack) {weight = 2}, (arc pack dst) {weight = 2}]
    -- test_enabled_only_when_the_place_holds_at_least_the_weight
    it "is enabled only when the place holds at least the weight" $ do
      enabledTransitions net (fromCounts [(src, 1)]) noImplementations `shouldBe` []
      enabledTransitions net (fromCounts [(src, 2)]) noImplementations `shouldBe` [pack]

  -- test_inhibitor_arc.py (enabledness half)
  describe "inhibitor gating" $ do
    let blocker = np "blocker"
        trigger = np "trigger"
        drain = np "drain"
        gate = np "gate"
        net =
          netOf
            [place blocker, place trigger, place (np "drained"), place (np "gated_done")]
            [transition drain, transition gate]
            [ arc blocker drain
            , (arc blocker gate) {mode = Inhibit}
            , arc trigger gate
            , arc drain (np "drained")
            , arc gate (np "gated_done")
            ]
    -- test_inhibited_while_the_place_is_occupied
    it "is inhibited while the place is occupied" $
      enabledTransitions net (fromCounts [(blocker, 1), (trigger, 1)]) noImplementations `shouldBe` [drain]
    it "is enabled when the inhibiting place is empty" $
      enabledTransitions net (fromCounts [(trigger, 1)]) noImplementations `shouldBe` [gate]

  -- test_read_arc.py (enabledness half)
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
    -- test_read_arc_requires_a_matching_token_to_enable
    it "requires a matching token to enable" $
      enabledTransitions net (markingFromList [(trigger, [black])]) noImplementations `shouldBe` []
    -- test_read_selection_is_carried_in_the_binding
    it "carries the read selection in the binding" $ do
      bindings <- plain net (markingFromList [(config, [settings]), (trigger, [black])])
      map (.read) bindings `shouldBe` [[(config, [settings])]]
      map bindingTokens bindings `shouldBe` [[black]]
      map bindingPeeked bindings `shouldBe` [[black, settings]]

  describe "enabledTransitions" $
    it "lists each enabled transition once (property)" $
      property $ \(QueueColors queue) ->
        let ts = enabledTransitions competingNet (markingFromList [(np "p", queue)]) noImplementations
         in ts === nub ts .&&. ts === (if null queue then [] else [np "t1", np "t2"])
