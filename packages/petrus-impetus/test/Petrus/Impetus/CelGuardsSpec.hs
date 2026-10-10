-- | Parity: @tests/petrus/impetus/instance/test_cel_guards.py@ — inline CEL
-- guards on an Instance.
--
-- CEL is a separate package in the Haskell port: every Instance here is
-- built with "Petrus.Impetus.CelStub", which recognises exactly this file's
-- expressions and answers with the reference adapter's messages. What is
-- under test is the kernel's half of the seam — each inline guard compiled
-- per declaration with its transition's consume/read input places as scope,
-- a compiler refusal failing construction verbatim, compiled guards keyed
-- by declaration identity and composed with named ones, and an evaluation
-- error skipping the binding with a diagnostic. The one case that tests the
-- CEL adapter's own name analysis (macro-bound variables) is not at parity.
module Petrus.Impetus.CelGuardsSpec (spec) where

import Data.Text (Text)
import Petrus.Impetus.CelStub (celStub)
import Petrus.Impetus.Instance
import Petrus.Impetus.InstanceSupport
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Petrus.Json (Json (..))
import Test.Hspec hiding (pending)

celGuarded :: NetPath -> [GuardDeclaration] -> Transition
celGuarded p declarations = Transition p Nothing declarations []

celGuard :: Text -> GuardDeclaration
celGuard = GuardCel . unsafeCel

-- | @Instance(net, marking)@ with the CEL stub as the compiler seam.
withCel :: Net -> Marking -> IO (Either InstanceError Instance)
withCel net m = newInstance net defaultInstanceConfig {initialMarking = m, celCompilers = celStub}

celInstance :: HasCallStack => Net -> Marking -> IO Instance
celInstance net m = withCel net m >>= expectRight

payment :: Integer -> Token
payment amount = tokD "Payment" (obj [("amount", Int amount), ("currency", String "USD")])

spec :: Spec
spec = describe "Instance CEL guards" $ do
  describe "CEL guard routing" $ do
    let pending = np "pending"
        accept = np "accept"
        reject = np "reject"
        accepted = np "accepted"
        rejected = np "rejected"
        big = payment 150
        small = payment 40
        net =
          netOf
            [place pending, place accepted, place rejected]
            [ celGuarded accept [celGuard "pending[0].data.amount >= 100"]
            , celGuarded reject [celGuard "pending[0].data.amount < 100"]
            ]
            [arc pending accept, arc pending reject, arc accept accepted, arc reject rejected]
        fresh = celInstance net (markingFromList [(pending, [big, small])])
    -- TestCelGuardRouting.test_a_cel_guard_failed_head_does_not_mask_a_deeper_admissible_selection
    it "does not let a CEL-guard-failed head mask a deeper admissible selection" $ do
      enabled <- fresh >>= candidates
      [(x.transition, bindingTokens x) | x <- enabled] `shouldBe` [(accept, [big]), (reject, [small])]
    -- TestCelGuardRouting.test_each_token_routes_by_its_own_cel_guard
    it "routes each token by its own CEL guard" $ do
      inst <- fresh
      _ <- run inst >>= expectRight
      marking inst `shouldReturn` markingFromList [(accepted, [big]), (rejected, [small])]

  describe "CEL guard correlation" $ do
    let config = np "config"
        pending = np "pending"
        approve = np "approve"
        out = np "out"
        limited :: Integer -> IO Instance
        limited limit =
          celInstance
            ( netOf
                [place config, place pending, place out]
                [celGuarded approve [celGuard "pending[0].data.amount <= config[0].data.limit"]]
                [(arc config approve) {mode = Read}, arc pending approve, arc approve out]
            )
            (markingFromList [(config, [tokD "Config" (obj [("limit", Int limit)])]), (pending, [tokD "Payment" (obj [("amount", Int 150)])])])
    -- TestCelGuardCorrelation.test_cel_guard_correlates_consumed_and_read_tokens
    it "correlates consumed and read tokens" $ do
      (limited 200 >>= enabledTransitions) `shouldReturn` [approve]
      (limited 100 >>= enabledTransitions) `shouldReturn` []

  describe "mixed guards" $ do
    let p = np "p"
        t = np "t"
        out = np "out"
        mixed :: [Text] -> [(Text, Guard)] -> IO Instance
        mixed expressions named =
          seededWith
            ( netOf
                [place p, place out]
                [celGuarded t (map (GuardSymbol . fst) named ++ map celGuard expressions)]
                [arc p t, arc t out]
            )
            defaultInstanceConfig
              { initialMarking = markingFromList [(p, [tokD "X" (obj [("n", Int 7)])])]
              , guardImplementations = symbolGuards named
              , celCompilers = celStub
              }
        truthy = const (Right True)
        falsy = const (Right False)
    -- TestMixedGuards.test_named_and_cel_guards_compose_as_conjunction
    it "composes named and CEL guards as conjunction" $ do
      (mixed ["p[0].data.n > 0"] [("check", truthy)] >>= enabledTransitions) `shouldReturn` [t]
      (mixed ["p[0].data.n > 9"] [("check", truthy)] >>= enabledTransitions) `shouldReturn` []
      (mixed ["p[0].data.n > 0"] [("check", falsy)] >>= enabledTransitions) `shouldReturn` []
    -- TestMixedGuards.test_two_cel_guards_compose_as_conjunction
    it "composes two CEL guards as conjunction" $ do
      (mixed ["p[0].data.n > 0", "p[0].data.n < 9"] [] >>= enabledTransitions) `shouldReturn` [t]
      (mixed ["p[0].data.n > 0", "p[0].data.n > 9"] [] >>= enabledTransitions) `shouldReturn` []
    -- TestMixedGuards.test_transitions_sharing_an_expression_share_one_sound_implementation
    it "lets transitions sharing an expression each enable off their own binding" $ do
      let t2 = np "t2"
          net =
            netOf
              [place p, place out]
              [celGuarded t [celGuard "p[0].data.n > 0"], celGuarded t2 [celGuard "p[0].data.n > 0"]]
              [arc p t, arc t out, arc p t2, arc t2 out]
      inst <- celInstance net (markingFromList [(p, [tokD "X" (obj [("n", Int 7)])])])
      enabledTransitions inst `shouldReturn` [t, t2]

  describe "CEL guard validation" $ do
    let p = np "p"
        q = np "q"
        t = np "t"
        out = np "out"
        validated :: Text -> Maybe ArcMode -> Net
        validated expression qMode =
          netOf
            [place p, place q, place out]
            [celGuarded t [celGuard expression]]
            ([arc p t, arc t out] ++ [(arc q t) {mode = m} | Just m <- [qMode]])
    -- TestCelGuardValidation.test_invalid_cel_fails_at_construction_and_never_evaluates
    it "fails at construction on invalid CEL and never evaluates" $ do
      result <- withCel (validated "p[0].data.amount >=" Nothing) emptyMarking
      result `shouldRefuse` "invalid CEL guard 'p[0].data.amount >=': p[0].data.amount >=\n                 ^\n"
    -- TestCelGuardValidation.test_a_place_not_feeding_the_transition_fails_at_construction
    it "fails at construction on a place not feeding the transition" $ do
      result <- withCel (validated "size(out) == 0" Nothing) emptyMarking
      result `shouldRefuse` "CEL guard 'size(out) == 0' on transition t references name(s) outside its consume/read input places ['p']: ['out']"
    -- TestCelGuardValidation.test_an_inhibit_only_place_is_outside_the_guard_scope
    it "keeps an inhibit-only place outside the guard scope" $ do
      result <- withCel (validated "size(q) == 0" (Just Inhibit)) emptyMarking
      result `shouldRefuse` "CEL guard 'size(q) == 0' on transition t references name(s) outside its consume/read input places ['p']: ['q']"
    -- TestCelGuardValidation.test_a_shared_expression_is_validated_against_each_declaring_transitions_scope
    it "validates a shared expression against each declaring transition's scope" $ do
      let t2 = np "t2"
          net =
            netOf
              [place p, place q, place out]
              [celGuarded t [celGuard "p[0].color == null"], celGuarded t2 [celGuard "p[0].color == null"]]
              [arc p t, arc t out, arc q t2, arc t2 out]
      result <- withCel net emptyMarking
      result `shouldRefuse` "CEL guard 'p[0].color == null' on transition t2 references name(s) outside its consume/read input places ['q']: ['p']"
    -- TestCelGuardValidation.test_a_read_place_is_inside_the_guard_scope
    it "keeps a read place inside the guard scope" $ do
      _ <- celInstance (validated "q[0].color == null" (Just Read)) emptyMarking
      pure ()
    -- TestCelGuardValidation.test_macro_bound_variables_are_not_place_references:
    -- not at parity — the free-variable analysis is the CEL package's.
    -- TestCelGuardValidation.test_a_non_symbol_non_cel_guard_is_rejected_at_declaration:
    -- enforced by types ('GuardDeclaration' has only the three encodings).

  describe "CEL guard evaluation errors" $ do
    let p = np "p"
        q = np "q"
        guardedT = np "guarded"
        plain = np "plain"
        out = np "out"
        fresh =
          celInstance
            ( netOf
                [place p, place q, place out]
                [celGuarded guardedT [celGuard "p[0].data.amount >= 100"], transition plain]
                [arc p guardedT, arc q plain, arc guardedT out, arc plain out]
            )
            (markingFromList [(p, [black]), (q, [black])])
    -- TestCelGuardEvaluationErrors.test_a_raising_cel_guard_skips_the_binding_and_enablement_continues
    it "skips the binding of a raising CEL guard and enablement continues" $ do
      (enabled, diagnostics) <- fresh >>= candidatesWithDiagnostics
      length diagnostics `shouldBe` 1
      map (.transition) enabled `shouldBe` [plain]
    -- TestCelGuardEvaluationErrors.test_the_diagnostic_carries_expression_transition_error_and_tokens
    it "carries the expression, transition, error, and tokens in the diagnostic" $ do
      (_, diagnostics) <- fresh >>= candidatesWithDiagnostics
      map renderDiagnostic diagnostics
        `shouldBe` [ "guard Cel(expression='p[0].data.amount >= 100') at NetUri('transition:/guarded#guard:$0') on transition guarded raised CELEvalError(*(\"None with type: '<class 'NoneType'>' does not support field selection\", <class 'TypeError'>, None), tree='p[0].data.amount') over peeked tokens (Token.black(),); binding skipped"
                   ]
