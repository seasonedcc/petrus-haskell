-- | Parity: @tests/petrus/impetus/petrinet/test_arc_filters.py@ (the
-- enabledness tests; the tests that fire live in "Petrus.Impetus.FiringSpec").
--
-- The reference drives these through @Instance@; here they run against the
-- kernel ('candidates', 'admitted') with the implementations an instance
-- would bind. CEL is a seam, never a kernel dependency: an inline filter is
-- bound by its 'Cel' key to a Haskell function that evaluates the same
-- expression. A raising filter returns 'Left' and surfaces as a
-- 'Diagnostic' instead of a Python warning.
module Petrus.Impetus.ArcFiltersSpec
  ( spec
  , invoice
  , big
  , small
  , isBig
  , celAmountAtLeast100
  ) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport
import Petrus.Json (Json (..))
import Test.Hspec hiding (pending)

invoice, big, small :: Token
invoice = tokD "Invoice" (obj [("number", Int 7)])
big = tokD "Payment" (obj [("amount", Int 150), ("currency", String "USD")])
small = tokD "Payment" (obj [("amount", Int 40), ("currency", String "EUR")])

-- | @is_big@: @token.data["amount"] >= 100@.
isBig :: Filter
isBig t = (>= 100) <$> numberField "amount" t

-- | The CEL seam's evaluation of @amount >= 100@ over a token's data fields
-- as bare variables; a token without the field is an evaluation error.
celAmountAtLeast100 :: Filter
celAmountAtLeast100 t = case t.payload of
  Object members -> case lookup "amount" members of
    Just (Int n) -> Right (n >= 100)
    _ -> Left "CelEvaluationError(\"undeclared reference to 'amount'\")"
  _ -> Left "CelEvaluationError(\"undeclared reference to 'amount'\")"

pending, cash, pay, out :: NetPath
pending = np "pending"
cash = np "cash"
pay = np "pay"
out = np "out"

-- | The colored consume net: a @Payment@-typed arc out of @pending@.
coloredNet :: Int -> Net
coloredNet w =
  netOf [place pending, place out] [transition cash] [withArcColor (Just "Payment") ((arc pending cash) {weight = w}), arc cash out]

namedNet :: Net
namedNet =
  netOf [place pending, place out] [transition pay] [withArcColor (Just "Payment") ((arc pending pay) {filter = Just (FilterSymbol "is_big")}), arc pay out]

parallelNet :: T.Text -> T.Text -> Net
parallelNet first' second' =
  netOf
    [place pending, place out]
    [transition pay]
    [(arc pending pay) {filter = Just (FilterSymbol first')}, (arc pending pay) {mode = Read, filter = Just (FilterSymbol second')}, arc pay out]

celNet :: T.Text -> Maybe Color -> Net
celNet expression c =
  netOf [place pending, place out] [transition pay] [withArcColor c ((arc pending pay) {filter = Just (FilterCel (unsafeCel expression))}), arc pay out]

byCel :: T.Text -> Filter -> Implementations
byCel expression f = Implementations (Map.fromList [(ByCel (unsafeCel expression), f)]) Map.empty

byUri :: [(NetUri, Filter)] -> Implementations
byUri pairs = Implementations (Map.fromList [(ByUri u, f) | (u, f) <- pairs]) Map.empty

inhibitedNet :: Net
inhibitedNet =
  netOf
    [place (np "blocker"), place (np "trigger"), place (np "done")]
    [transition (np "gate")]
    [ withArcColor (Just "Alarm") ((arc (np "blocker") (np "gate")) {mode = Inhibit, filter = Just (FilterSymbol "armed")})
    , arc (np "trigger") (np "gate")
    , arc (np "gate") (np "done")
    ]

armed :: Filter
armed t =
  field "armed" t >>= \case
    Bool b -> Right b
    other -> Left ("TypeError(" <> T.pack (show other) <> ")")

inhibitedBy :: [Token] -> [NetPath]
inhibitedBy blockerQueue =
  enabledTransitions inhibitedNet (markingFromList [(np "blocker", blockerQueue), (np "trigger", [black])]) (impls [("armed", armed)] [])

spec :: Spec
spec = describe "Petrinet arc filters" $ do
  describe "colored consume selection" $ do
    -- test_selects_the_first_matching_token_not_the_queue_front
    it "selects the first matching token, not the queue front" $ do
      bindings <- expectRight (candidates (coloredNet 1) (markingFromList [(pending, [invoice, big])]) noImplementations Nothing)
      map (.consumed) bindings `shouldBe` [[(pending, [big])]]
    -- test_no_matching_token_disables_the_transition
    it "is disabled without a matching token" $
      enabledTransitions (coloredNet 1) (markingFromList [(pending, [invoice])]) noImplementations `shouldBe` []
    -- test_weight_counts_admitted_tokens_only
    it "counts admitted tokens only toward the weight" $ do
      let other = tokD "Payment" (obj [("amount", Int 5), ("currency", String "USD")])
      bindings <- expectRight (candidates (coloredNet 2) (markingFromList [(pending, [big, invoice, other])]) noImplementations Nothing)
      map (.consumed) bindings `shouldBe` [[(pending, [big, other])]]
      enabledTransitions (coloredNet 2) (markingFromList [(pending, [big, invoice])]) noImplementations `shouldBe` []

  describe "named filter selection" $ do
    -- test_missing_filter_implementation_fails_at_construction: the kernel
    -- refuses a declared filter with no implementation (the reference's
    -- Instance validates the mapping up front; its kernel raises KeyError).
    it "refuses a declared filter without an implementation" $ do
      [uri] <- pure (map fst (filterDeclarations namedNet))
      candidates namedNet (markingFromList [(pending, [big])]) noImplementations Nothing
        `shouldBe` Left (MissingFilter (Just uri) (FilterSymbol "is_big"))
    -- test_exact_filter_uris_bind_same_named_declarations_independently
    it "binds same-named declarations independently by exact URI" $ do
      let net = parallelNet "choice" "choice"
      [first', second'] <- pure (map fst (filterDeclarations net))
      let implementations = byUri [(first', \t -> Right (t == big)), (second', \t -> Right (t == small))]
      bindings <- expectRight (candidates net (markingFromList [(pending, [small, big])]) implementations Nothing)
      map (.consumed) bindings `shouldBe` [[(pending, [big])]]
      map (.read) bindings `shouldBe` [[(pending, [small])]]
    -- test_bare_symbol_deliberately_shares_one_filter_implementation
    it "shares one implementation through a bare symbol" $ do
      bindings <- expectRight (candidates (parallelNet "choice" "choice") (markingFromList [(pending, [small, big])]) (impls [("choice", \t -> Right (t == big))] []) Nothing)
      map (.consumed) bindings `shouldBe` [[(pending, [big])]]
      map (.read) bindings `shouldBe` [[(pending, [big])]]
    -- test_exact_and_bare_filter_binding_is_ambiguous: see
    -- "Petrus.Impetus.FiringHistorySpec" (Instance construction validates
    -- the implementation mapping).

  describe "read and inhibit filters" $ do
    -- test_inhibit_gates_on_a_matching_token
    it "gates an inhibitor on a matching token" $
      inhibitedBy [tokD "Alarm" (obj [("armed", Bool True)])] `shouldBe` []
    -- test_inhibit_ignores_tokens_the_inscription_does_not_match
    it "ignores tokens the inhibitor inscription does not match" $ do
      inhibitedBy [tokD "Note" (obj [("armed", Bool True)])] `shouldBe` [np "gate"]
      inhibitedBy [tokD "Alarm" (obj [("armed", Bool False)])] `shouldBe` [np "gate"]
    -- test_typed_place_resolves_color_before_evaluating_an_uncolored_filtered_arc
    -- (the "consulted" log is a filter that errs on anything but BIG: a
    -- consultation would surface as a diagnostic)
    it "resolves a typed place's color before evaluating the filter" $ do
      let net =
            netOf
              [coloredPlace pending "Payment", place out]
              [transition pay]
              [(arc pending pay) {filter = Just (FilterSymbol "is_big")}, arc pay out]
          consulted = impls [("is_big", \t -> if t == big then isBig t else Left "consulted")] []
      [a] <- pure (inputs net pay)
      admitted a (tokD "Other" (obj [("amount", Int 100)])) consulted Nothing `shouldBe` Right (False, [])
      admitted a big consulted Nothing `shouldBe` Right (True, [])

  describe "CEL filter selection" $ do
    -- test_cel_composes_over_several_fields
    it "composes over several fields" $ do
      let expression = "amount >= 100 && currency == \"USD\""
          evaluate t = do
            amount <- numberField "amount" t
            currency <- field "currency" t
            Right (amount >= 100 && currency == String "USD")
      bindings <- expectRight (candidates (celNet expression (Just "Payment")) (markingFromList [(pending, [small, big])]) (byCel expression evaluate) Nothing)
      map bindingTokens bindings `shouldBe` [[big]]
    -- test_invalid_cel_fails_at_construction_and_never_evaluates and
    -- test_exact_override_of_inline_cel_filter_is_refused: see
    -- "Petrus.Impetus.FiringHistorySpec" (CEL compilation is the
    -- Instance-construction seam).
    -- test_empty_cel_expression_is_rejected
    it "rejects an empty expression" $
      cel "" `shouldFailWith` "Cel requires a non-empty expression string, got ''"
    -- test_cel_error_on_a_concrete_token_skips_it_not_the_scan
    it "skips a token the expression errs on, not the scan" $ do
      let expression = "amount >= 100"
      (bindings, diagnostics) <-
        expectRight (candidatesWithDiagnostics (celNet expression Nothing) (markingFromList [(pending, [black, big])]) (byCel expression celAmountAtLeast100) Nothing)
      map bindingTokens bindings `shouldBe` [[big]]
      [(d, t) | FilterEvaluationFailed d _ _ t <- diagnostics] `shouldBe` [(FilterCel (unsafeCel expression), black)]

  describe "filter evaluation errors" $ do
    let errorNet = netOf [place pending, place out] [transition pay] [(arc pending pay) {filter = Just (FilterSymbol "is_big")}, arc pay out]
        bigs = impls [("is_big", isBig)] []
    -- test_the_diagnostic_carries_filter_arc_token_and_error
    it "carries the filter, arc, token, and error in the diagnostic" $ do
      (_, diagnostics) <- expectRight (candidatesWithDiagnostics errorNet (markingFromList [(pending, [black])]) bigs Nothing)
      map renderDiagnostic diagnostics
        `shouldBe` [ "filter 'is_big' at NetUri('arc:/pending->/pay#filter') raised TypeError(\"'NoneType' object is not subscriptable\") evaluating Token.black(); token not admitted"
                   ]
    -- test_an_unreadable_token_does_not_mask_a_later_match
    it "does not let an unreadable token mask a later match" $ do
      (bindings, diagnostics) <- expectRight (candidatesWithDiagnostics errorNet (markingFromList [(pending, [black, big])]) bigs Nothing)
      length diagnostics `shouldBe` 1
      map (.consumed) bindings `shouldBe` [[(pending, [big])]]
    -- test_parallel_filter_warning_names_the_exact_occurrence_and_scan_continues
    it "names the exact occurrence of a parallel filter and continues the scan" $ do
      let net = parallelNet "first" "second"
      uris <- pure (map fst (filterDeclarations net))
      map netUriText uris `shouldBe` ["arc:/pending->/pay#filter:$0", "arc:/pending->/pay#filter:$1"]
      let raising t = (> 0) <$> numberField "amount" t
      (bindings, diagnostics) <- expectRight (candidatesWithDiagnostics net (markingFromList [(pending, [black, big])]) (byUri [(u, raising) | u <- uris]) Nothing)
      let rendered = map renderDiagnostic diagnostics
      [marker | marker <- ["#filter:$0", "#filter:$1"], any (marker `T.isInfixOf`) rendered] `shouldBe` ["#filter:$0", "#filter:$1"]
      map (.consumed) bindings `shouldBe` [[(pending, [big])]]
      map (.read) bindings `shouldBe` [[(pending, [big])]]
    -- test_inhibit_filter_error_means_no_match_and_does_not_block
    it "lets an inhibit filter error mean no match, with a diagnostic" $ do
      let net =
            netOf
              [place (np "blocker"), place (np "trigger"), place (np "done")]
              [transition (np "gate")]
              [(arc (np "blocker") (np "gate")) {mode = Inhibit, filter = Just (FilterSymbol "is_big")}, arc (np "trigger") (np "gate"), arc (np "gate") (np "done")]
      (bindings, diagnostics) <- expectRight (candidatesWithDiagnostics net (markingFromList [(np "blocker", [black]), (np "trigger", [black])]) bigs Nothing)
      map (.transition) bindings `shouldBe` [np "gate"]
      length diagnostics `shouldBe` 1

  describe "filter validation" $ do
    -- test_filter_on_an_output_arc_is_rejected
    it "rejects a filter on an output arc" $
      mkNet (netSpec [place (np "p")] [transition (np "t")] [arc (np "p") (np "t"), (arc (np "t") (np "p")) {filter = Just (FilterSymbol "is_big")}])
        `shouldFailWith` "filter on output arc t -> p: a filter is an input inscription"
    -- enforced by types: test_a_non_symbol_non_cel_filter_is_rejected_at_construction
    -- enforced by types: test_enabledness_with_filters_leaves_the_marking_untouched
    -- (candidates is a pure function of immutable values)
