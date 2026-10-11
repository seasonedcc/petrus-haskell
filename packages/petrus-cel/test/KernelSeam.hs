{-# LANGUAGE OverloadedRecordDot #-}

-- | The 26 upstream Instance tests that @petrus-impetus@ ports through a
-- test-local CEL stub (its PARITY.md: "ported via CEL stub"), rerun here
-- on the real compilers, 'Petrus.Cel.Impetus.celCompilers' (the audit's
-- IMP-5). The kernel ports test the kernel's half of the seam; these run
-- the same upstream bodies end to end, so the expressions are parsed,
-- scope-checked and evaluated by CEL itself, and every refusal and
-- diagnostic text is the real compiler's.
--
-- * @tests/petrus/impetus/instance/test_completion.py@:
--   @TestStatusResolution@ (5) and @TestCompletionValidation@ (2);
-- * @tests/petrus/impetus/instance/test_cel_guards.py@: routing (2),
--   correlation (1), mixed guards (3), validation (5) and evaluation
--   errors (2);
-- * @tests/petrus/impetus/instance/test_registrations.py@:
--   @TestAwaitingStatus@ (3);
-- * @tests/petrus/impetus/petrinet/test_arc_filters.py@:
--   @TestCelFilterSelection@ (3).
module KernelSeam
  ( spec
  ) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec hiding (pending)

import Petrus.Cel.Impetus (celCompilers)
import Petrus.Impetus.History (Record (..), TokensConsumed (..), replayMarking)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Json

-- ---------------------------------------------------------------------------
-- Helpers

np :: Text -> NetPath
np = either (error . T.unpack) id . netPath

tokD :: Text -> Json -> Token
tokD c = Token (Just c)

netOf :: HasCallStack => [Place] -> [Transition] -> [Arc] -> Net
netOf ps ts as = mustNet (netSpec ps ts as)

mustNet :: HasCallStack => NetSpec -> Net
mustNet = either (error . T.unpack) id . mkNet

expectRight :: (HasCallStack, Show e) => Either e a -> IO a
expectRight = \case
  Right a -> pure a
  Left e -> expectationFailure ("expected Right, got Left " <> show e) >> error "unreachable"

-- | The door is refused (@ValueError@) with exactly this message.
shouldRefuse :: HasCallStack => Either InstanceError a -> Text -> Expectation
shouldRefuse result message = case result of
  Left (Refused actual) -> actual `shouldBe` message
  Left other -> expectationFailure ("expected Refused, got " <> show other)
  Right _ -> expectationFailure "expected Refused, got Right"

-- | @Instance(net, ...)@ on the real CEL compilers.
withCel :: Net -> InstanceConfig -> IO (Either InstanceError Instance)
withCel net config = newInstance net config {celCompilers = celCompilers}

celInstance :: HasCallStack => Net -> InstanceConfig -> IO Instance
celInstance net config = withCel net config >>= expectRight

marked :: Marking -> InstanceConfig
marked m = defaultInstanceConfig {initialMarking = m}

celGuarded :: NetPath -> [GuardDeclaration] -> Transition
celGuarded p declarations = Transition p Nothing declarations []

celGuard :: Text -> GuardDeclaration
celGuard = GuardCel . unsafeCel

spec :: Spec
spec = describe "kernel CEL seam on real CEL (the CEL-stub ports, rerun)" $ do
  completionSpec
  guardsSpec
  registrationsSpec
  filterSpec

-- ---------------------------------------------------------------------------
-- tests/petrus/impetus/instance/test_completion.py

completionSpec :: Spec
completionSpec = describe "test_completion.py" $ do
  let pa = np "a"
      tt = np "t"
      pb = np "b"
      chain completion = mustNet (NetSpec [place pa, place pb] [transition tt] [arc pa tt, arc tt pb] completion Nothing)
      celChain = chain . Just . CompletionCel . unsafeCel
      oneBlack = markingFromList [(pa, [black])]
      judged net = celInstance net (marked oneBlack)
      seeded net = newInstance net (marked oneBlack) >>= expectRight
  describe "status resolution" $ do
    -- TestStatusResolution.test_completed_when_quiescent_and_the_condition_holds
    it "is completed when quiescent and the condition holds" $ do
      inst <- judged (celChain "size(b) == 1")
      _ <- run inst >>= expectRight
      status inst `shouldReturn` Completed
    -- TestStatusResolution.test_stuck_when_quiescent_and_the_condition_does_not_hold
    it "is stuck when quiescent and the condition does not hold" $ do
      inst <- judged (celChain "size(b) >= 2")
      _ <- run inst >>= expectRight
      status inst `shouldReturn` Stuck
    -- TestStatusResolution.test_running_while_enabled_even_when_the_condition_already_holds
    it "is running while enabled even when the condition already holds" $ do
      inst <- judged (celChain "size(a) == 1")
      status inst `shouldReturn` Running
    -- TestStatusResolution.test_the_condition_never_affects_enabledness_or_firing
    it "never affects enabledness or firing" $ do
      withCondition <- judged (celChain "size(b) == 1")
      neutral <- seeded (chain Nothing)
      judgedCandidates <- candidates withCondition
      candidates neutral `shouldReturn` judgedCandidates
      judgedRun <- run withCondition >>= expectRight
      neutralRun <- run neutral >>= expectRight
      map (.records) judgedRun `shouldBe` map (.records) neutralRun
    -- TestStatusResolution.test_status_is_a_pure_projection_of_the_marking
    it "is a pure projection of the marking" $ do
      inst <- judged (celChain "size(b) == 1")
      _ <- run inst >>= expectRight
      recorded <- Store.size (instanceHistory inst)
      sequence [status inst, status inst] `shouldReturn` [Completed, Completed]
      marking inst `shouldReturn` markingFromList [(pb, [black])]
      Store.size (instanceHistory inst) `shouldReturn` recorded
  describe "completion validation" $ do
    -- TestCompletionValidation.test_invalid_cel_fails_at_construction_and_never_evaluates
    it "fails at construction on invalid CEL and never evaluates" $ do
      result <- withCel (celChain "size(b) ==") defaultInstanceConfig
      result `shouldRefuse` "invalid CEL completion 'size(b) ==': size(b) ==\n        ^\n"
    -- TestCompletionValidation.test_unknown_place_reference_fails_at_construction
    it "fails at construction on an unknown place reference" $ do
      result <- withCel (celChain "size(doen) > 0") defaultInstanceConfig
      result `shouldRefuse` "CEL completion 'size(doen) > 0' references unknown place(s): ['doen']"

-- ---------------------------------------------------------------------------
-- tests/petrus/impetus/instance/test_cel_guards.py

payment :: Integer -> Token
payment amount = tokD "Payment" (Object [("amount", Int amount), ("currency", String "USD")])

guardsSpec :: Spec
guardsSpec = describe "test_cel_guards.py" $ do
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
        fresh = celInstance net (marked (markingFromList [(pending, [big, small])]))
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
            (marked (markingFromList [(config, [tokD "Config" (Object [("limit", Int limit)])]), (pending, [tokD "Payment" (Object [("amount", Int 150)])])]))
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
          celInstance
            ( netOf
                [place p, place out]
                [celGuarded t (map (GuardSymbol . fst) named ++ map celGuard expressions)]
                [arc p t, arc t out]
            )
            defaultInstanceConfig
              { initialMarking = markingFromList [(p, [tokD "X" (Object [("n", Int 7)])])]
              , guardImplementations = Map.fromList [(Symbol s, g) | (s, g) <- named]
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
      inst <- celInstance net (marked (markingFromList [(p, [tokD "X" (Object [("n", Int 7)])])]))
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
      result <- withCel (validated "p[0].data.amount >=" Nothing) defaultInstanceConfig
      result `shouldRefuse` "invalid CEL guard 'p[0].data.amount >=': p[0].data.amount >=\n                 ^\n"
    -- TestCelGuardValidation.test_a_place_not_feeding_the_transition_fails_at_construction
    it "fails at construction on a place not feeding the transition" $ do
      result <- withCel (validated "size(out) == 0" Nothing) defaultInstanceConfig
      result `shouldRefuse` "CEL guard 'size(out) == 0' on transition t references name(s) outside its consume/read input places ['p']: ['out']"
    -- TestCelGuardValidation.test_an_inhibit_only_place_is_outside_the_guard_scope
    it "keeps an inhibit-only place outside the guard scope" $ do
      result <- withCel (validated "size(q) == 0" (Just Inhibit)) defaultInstanceConfig
      result `shouldRefuse` "CEL guard 'size(q) == 0' on transition t references name(s) outside its consume/read input places ['p']: ['q']"
    -- TestCelGuardValidation.test_a_shared_expression_is_validated_against_each_declaring_transitions_scope
    it "validates a shared expression against each declaring transition's scope" $ do
      let t2 = np "t2"
          net =
            netOf
              [place p, place q, place out]
              [celGuarded t [celGuard "p[0].color == null"], celGuarded t2 [celGuard "p[0].color == null"]]
              [arc p t, arc t out, arc q t2, arc t2 out]
      result <- withCel net defaultInstanceConfig
      result `shouldRefuse` "CEL guard 'p[0].color == null' on transition t2 references name(s) outside its consume/read input places ['q']: ['p']"
    -- TestCelGuardValidation.test_a_read_place_is_inside_the_guard_scope
    it "keeps a read place inside the guard scope" $ do
      _ <- celInstance (validated "q[0].color == null" (Just Read)) defaultInstanceConfig
      pure ()

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
            (marked (markingFromList [(p, [black]), (q, [black])]))
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

-- ---------------------------------------------------------------------------
-- tests/petrus/impetus/instance/test_registrations.py

registrationsSpec :: Spec
registrationsSpec = describe "test_registrations.py" $ do
  let event = np "event"
      done = np "done"
      webhook = np "webhook"
      settle = np "settle"
      -- webhook (source) -> event -> settle -> done, declaring size(done) == 1
      webhookNet =
        mustNet
          NetSpec
            { places = [place event, place done]
            , transitions = [transition webhook, transition settle]
            , arcs = [arc webhook event, arc event settle, arc settle done]
            , completion = Just (CompletionCel (unsafeCel "size(done) == 1"))
            , name = Nothing
            }
      webhookInstance initial = celInstance webhookNet (marked initial)
  describe "awaiting status" $ do
    -- TestAwaitingStatus.test_completion_outranks_an_armed_registration
    it "ranks completion above an armed registration" $ do
      inst <- webhookInstance (markingFromList [(event, [black])])
      _ <- run inst >>= expectRight
      status inst `shouldReturn` Completed
    -- TestAwaitingStatus.test_awaiting_when_the_declared_condition_does_not_hold
    it "is awaiting when the declared condition does not hold" $ do
      inst <- webhookInstance emptyMarking
      status inst `shouldReturn` Awaiting
    -- TestAwaitingStatus.test_seal_flips_status_with_zero_net_activity
    it "flips status on seal with zero net activity" $ do
      inst <- webhookInstance emptyMarking
      prior <- marking inst
      status inst `shouldReturn` Awaiting
      seal inst webhook Nothing >>= expectRight
      status inst `shouldReturn` Stuck
      marking inst `shouldReturn` prior

-- ---------------------------------------------------------------------------
-- tests/petrus/impetus/petrinet/test_arc_filters.py

filterSpec :: Spec
filterSpec = describe "test_arc_filters.py" $
  describe "CEL filter selection" $ do
    let pending = np "pending"
        pay = np "pay"
        out = np "out"
        big = tokD "Payment" (Object [("amount", Int 150), ("currency", String "USD")])
        small = tokD "Payment" (Object [("amount", Int 40), ("currency", String "EUR")])
        celNet expression =
          netOf
            [place pending, place out]
            [transition pay]
            [withArcColor (Just "Payment") ((arc pending pay) {filter = Just (FilterCel (unsafeCel expression))}), arc pay out]
    -- TestCelFilterSelection.test_cel_selection_consumes_and_replays_like_any_other
    it "consumes and replays like any other selection" $ do
      inst <- celInstance (celNet "amount >= 100") (marked (markingFromList [(pending, [small, big])]))
      firing <-
        step inst Nothing >>= expectRight >>= \case
          Just firing -> pure firing
          Nothing -> expectationFailure "expected an enabled transition" >> error "unreachable"
      firing.consumed `shouldBe` [big]
      [r | r@(RTokensConsumed _) <- firing.records] `shouldBe` [RTokensConsumed (TokensConsumed pending [big] 1 [] Nothing 0)]
      live <- marking inst
      recorded <- Store.records (instanceHistory inst)
      replayMarking recorded `shouldBe` Right live
    -- TestCelFilterSelection.test_invalid_cel_fails_at_construction_and_never_evaluates
    it "invalid CEL fails at construction and never evaluates" $ do
      result <- withCel (celNet "amount >=") (marked (markingFromList [(pending, [big])]))
      result `shouldRefuse` "invalid CEL filter 'amount >=': amount >=\n       ^\n"
    -- TestCelFilterSelection.test_exact_override_of_inline_cel_filter_is_refused
    it "an exact override of an inline CEL filter is refused" $ do
      let net = netOf [place pending, place out] [transition pay] [(arc pending pay) {filter = Just (FilterCel (unsafeCel "true"))}, arc pay out]
      [uri] <- pure (map fst (filterDeclarations net))
      result <- withCel net defaultInstanceConfig {filterImplementations = Map.fromList [(Exact uri, const (Right True))]}
      result `shouldRefuse` "inline filter declaration arc:/pending->/pay#filter already supplies its Cel implementation"
