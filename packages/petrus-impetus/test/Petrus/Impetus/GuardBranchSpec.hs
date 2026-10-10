-- | Parity: @tests/petrus/impetus/instance/test_guard_branch.py@ — named
-- guards on an Instance: declaration binding, the @guard_branch@ fixture's
-- complementary routing, full-binding correlation, conjunction, and
-- evaluation errors.
--
-- The reference surfaces a raising guard as a @GuardEvaluationWarning@; the
-- Instance returns it explicitly from 'candidatesWithDiagnostics', so each
-- @pytest.warns@ becomes an assertion on the returned diagnostics.
module Petrus.Impetus.GuardBranchSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Petrus.Impetus.Instance
import Petrus.Impetus.InstanceSupport
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Petrus.Json (Json (..))
import Test.Hspec hiding (pending)

-- | @binding.peeked[0].data["amount"]@ compared against a bound.
peekedAmount :: (Integer -> Bool) -> Guard
peekedAmount holds binding = case bindingPeeked binding of
  t : _ -> holds <$> numberField "amount" t
  [] -> Left "IndexError('tuple index out of range')"

amountGte100, amountLt100 :: Guard
amountGte100 = peekedAmount (>= 100)
amountLt100 = peekedAmount (< 100)

guarded :: NetPath -> [GuardDeclaration] -> Transition
guarded p declarations = Transition p Nothing declarations []

payment :: Integer -> Token
payment amount = tokD "Payment" (obj [("amount", Int amount), ("currency", String "USD")])

transitionsOf :: [Binding] -> [NetPath]
transitionsOf = map (.transition)

spec :: Spec
spec = describe "Instance guards" $ do
  describe "guard declaration bindings" $ do
    let pending = np "pending"
        left = np "left"
        right = np "right"
        net declaration = netOf [place pending] [guarded left [declaration], guarded right [declaration]] [arc pending left, arc pending right]
        shared = net (GuardSymbol "shared")
        firstUri p = case guardUris shared p of
          uri : _ -> uri
          [] -> error "transition declares no guard"
    -- TestGuardDeclarationBindings.test_exact_declaration_uris_bind_same_named_guards_independently
    it "binds same-named guards independently by exact declaration URI" $ do
      inst <-
        seededWith
          shared
          defaultInstanceConfig
            { initialMarking = markingFromList [(pending, [black])]
            , guardImplementations = Map.fromList [(Exact (firstUri left), const (Right True)), (Exact (firstUri right), const (Right False))]
            }
      transitionsOf <$> candidates inst `shouldReturn` [left]
    -- TestGuardDeclarationBindings.test_local_symbol_deliberately_shares_one_guard
    it "shares one guard through the local symbol" $ do
      inst <-
        seededWith
          shared
          defaultInstanceConfig {initialMarking = markingFromList [(pending, [black])], guardImplementations = symbolGuards [("shared", const (Right True))]}
      transitionsOf <$> candidates inst `shouldReturn` [left, right]
    -- TestGuardDeclarationBindings.test_exact_and_local_binding_for_one_guard_is_ambiguous
    it "refuses an exact and a local binding for one guard as ambiguous" $ do
      result <-
        newInstance
          shared
          defaultInstanceConfig
            { guardImplementations = Map.fromList [(Symbol "shared", const (Right True)), (Exact (firstUri left), const (Right False))]
            }
      result `shouldRefuse` "guard declaration transition:/left#guard:shared has both an exact implementation and local symbol 'shared'"
    -- TestGuardDeclarationBindings.test_anonymous_guard_requires_its_exact_declaration_uri
    it "requires the exact declaration URI for an anonymous guard" $ do
      result <- newInstance (net (GuardAnonymous anonymous)) defaultInstanceConfig
      result `shouldRefuse` "guard declaration(s) with no implementation: ['transition:/left#guard:$0', 'transition:/right#guard:$0']"

  describe "guard branch" $ do
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
            [guarded accept [GuardSymbol "amount_gte_100"], guarded reject [GuardSymbol "amount_lt_100"]]
            [arc pending accept, arc pending reject, arc accept accepted, arc reject rejected]
        fresh =
          seededWith
            net
            defaultInstanceConfig
              { initialMarking = markingFromList [(pending, [big, small])]
              , guardImplementations = symbolGuards [("amount_gte_100", amountGte100), ("amount_lt_100", amountLt100)]
              }
    -- TestGuardBranch.test_a_guard_failed_head_does_not_mask_a_deeper_admissible_selection
    it "does not let a guard-failed head mask a deeper admissible selection" $ do
      enabled <- fresh >>= candidates
      [(x.transition, bindingTokens x) | x <- enabled] `shouldBe` [(accept, [big]), (reject, [small])]
    -- TestGuardBranch.test_each_token_routes_by_its_own_guard
    it "routes each token by its own guard" $ do
      inst <- fresh
      _ <- run inst >>= expectRight
      marking inst `shouldReturn` markingFromList [(accepted, [big]), (rejected, [small])]
    -- TestGuardBranch.test_missing_guard_implementation_fails_at_construction
    it "fails at construction on a missing guard implementation" $ do
      result <- newInstance net defaultInstanceConfig {guardImplementations = symbolGuards [("amount_gte_100", amountGte100)]}
      result `shouldRefuse` "guard declaration(s) with no implementation: ['amount_lt_100']"

  describe "guards see the full binding" $ do
    let config = np "config"
        pending = np "pending"
        approve = np "approve"
        out = np "out"
        paid = tokD "Payment" (obj [("amount", Int 150)])
        -- @within_limit@: the consumed payment within the read config's limit.
        withinLimit :: Guard
        withinLimit binding = case (binding.read, bindingTokens binding) of
          ([(_, [cfg])], [p]) -> (<=) <$> numberField "amount" p <*> numberField "limit" cfg
          _ -> Left "ValueError('not enough values to unpack')"
        limited :: Integer -> IO Instance
        limited limit =
          seededWith
            ( netOf
                [place config, place pending, place out]
                [guarded approve [GuardSymbol "within_limit"]]
                [(arc config approve) {mode = Read}, arc pending approve, arc approve out]
            )
            defaultInstanceConfig
              { initialMarking = markingFromList [(config, [tokD "Config" (obj [("limit", Int limit)])]), (pending, [paid])]
              , guardImplementations = symbolGuards [("within_limit", withinLimit)]
              }
    -- TestGuardsSeeTheFullBinding.test_guard_correlates_consumed_and_read_tokens
    it "correlates consumed and read tokens" $ do
      (limited 200 >>= enabledTransitions) `shouldReturn` [approve]
      (limited 100 >>= enabledTransitions) `shouldReturn` []
    -- TestGuardsSeeTheFullBinding.test_peeked_is_consumed_then_read_selections
    it "peeks consumed selections, then read selections" $ do
      [binding] <- limited 200 >>= candidates
      bindingPeeked binding `shouldBe` [paid, tokD "Config" (obj [("limit", Int 200)])]

  describe "guard composition" $ do
    let p = np "p"
        t = np "t"
        out = np "out"
        composed :: [(Text, Guard)] -> IO Instance
        composed named =
          seededWith
            (netOf [place p, place out] [guarded t (map (GuardSymbol . fst) named)] [arc p t, arc t out])
            defaultInstanceConfig {initialMarking = markingFromList [(p, [tok "X"])], guardImplementations = symbolGuards named}
        truthy = const (Right True)
        falsy = const (Right False)
    -- TestGuardComposition.test_all_guards_must_hold
    it "requires all guards to hold" $ do
      (composed [("a", truthy), ("b", truthy)] >>= enabledTransitions) `shouldReturn` [t]
      (composed [("a", truthy), ("b", falsy)] >>= enabledTransitions) `shouldReturn` []

  describe "guard evaluation errors" $ do
    let p = np "p"
        q = np "q"
        guardedT = np "guarded"
        plain = np "plain"
        out = np "out"
        needsAmount = peekedAmount (>= 100)
        fresh =
          seededWith
            ( netOf
                [place p, place q, place out]
                [guarded guardedT [GuardSymbol "needs_amount"], transition plain]
                [arc p guardedT, arc q plain, arc guardedT out, arc plain out]
            )
            defaultInstanceConfig
              { initialMarking = markingFromList [(p, [black]), (q, [black])]
              , guardImplementations = symbolGuards [("needs_amount", needsAmount)]
              }
    -- TestGuardEvaluationErrors.test_raising_guard_skips_the_binding_and_enablement_continues
    it "skips the binding of a raising guard and enablement continues" $ do
      (enabled, diagnostics) <- fresh >>= candidatesWithDiagnostics
      length diagnostics `shouldBe` 1
      transitionsOf enabled `shouldBe` [plain]
    -- TestGuardEvaluationErrors.test_an_unreadable_token_does_not_mask_a_deeper_valid_binding
    it "does not let an unreadable token mask a deeper valid binding" $ do
      let paid = tokD "Payment" (obj [("amount", Int 150)])
      inst <-
        seededWith
          (netOf [place p, place out] [guarded guardedT [GuardSymbol "needs_amount"]] [arc p guardedT, arc guardedT out])
          defaultInstanceConfig
            { initialMarking = markingFromList [(p, [black, paid])]
            , guardImplementations = symbolGuards [("needs_amount", needsAmount)]
            }
      ([binding], diagnostics) <- candidatesWithDiagnostics inst
      length diagnostics `shouldBe` 1
      bindingTokens binding `shouldBe` [paid]
    -- TestGuardEvaluationErrors.test_the_diagnostic_carries_guard_transition_error_and_token
    it "carries the guard, transition, error, and token in the diagnostic" $ do
      (_, diagnostics) <- fresh >>= candidatesWithDiagnostics
      map renderDiagnostic diagnostics
        `shouldBe` [ "guard 'needs_amount' at NetUri('transition:/guarded#guard:needs_amount') on transition guarded raised TypeError(\"'NoneType' object is not subscriptable\") over peeked tokens (Token.black(),); binding skipped"
                   ]
