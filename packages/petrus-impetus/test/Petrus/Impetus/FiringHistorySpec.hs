-- | Parity: the History and Instance halves of
-- @tests/petrus/impetus/petrinet/test_read_arc.py@ and
-- @tests/petrus/impetus/petrinet/test_arc_filters.py@ that
-- "Petrus.Impetus.FiringSpec" and "Petrus.Impetus.ArcFiltersSpec" could not
-- translate against the bare kernel: the records a firing appends, replay
-- of the recorded movements, and the Instance's construction-time binding
-- of filter implementations.
--
-- These fire through the Instance exactly as the reference does
-- ('newInstance', 'begin', 'step', 'run'). Inline CEL is a separate
-- package: a test-local 'CelCompilers' recognises the exact expressions
-- these tests use (and refuses the invalid one with the CEL package's
-- message).
module Petrus.Impetus.FiringHistorySpec (spec) where

import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Petrus.Impetus.ArcFiltersSpec (big, celAmountAtLeast100, invoice, isBig, small)
import Petrus.Impetus.History
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Binding
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Petrus.Json (Json (..))
import Test.Hspec hiding (pending)

expectOk :: (HasCallStack, Show e) => IO (Either e a) -> IO a
expectOk action = action >>= expectRight

instanceOf :: HasCallStack => Net -> InstanceConfig -> IO Instance
instanceOf net cfg = expectOk (newInstance net cfg)

recordsOf :: Instance -> IO [Record]
recordsOf = Store.records . instanceHistory

-- | One inline step; the net must have an enabled transition.
stepOnce :: HasCallStack => Instance -> IO FiringOutcome
stepOnce inst =
  expectOk (step inst Nothing) >>= \case
    Just firing -> pure firing
    Nothing -> expectationFailure "expected an enabled transition" >> error "unreachable"

-- | @replay_marking(instance.history) == instance.marking@.
replaysToLive :: HasCallStack => Instance -> Expectation
replaysToLive inst = do
  live <- marking inst
  recorded <- recordsOf inst
  replayMarking recorded `shouldBe` Right live

-- | The CEL stub: the expressions these tests spell, compiled to the
-- Haskell evaluation the CEL package would produce.
celStub :: CelCompilers
celStub =
  noCelCompilers
    { compileFilter = \expression -> case celExpression expression of
        "amount >= 100" -> Right celAmountAtLeast100
        "true" -> Right (const (Right True))
        "amount >=" -> Left "invalid CEL filter 'amount >=': amount >=\n       ^\n"
        other -> Left ("the CEL stub does not know " <> other)
    }

spec :: Spec
spec = describe "Petrinet.Firing through the Instance" $ do
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
        seeded = instanceOf net defaultInstanceConfig {initialMarking = markingFromList [(config, [settings]), (trigger, [black])]}
        a = np "a"
        t = np "t"
        overlapNet = netOf [place a, place (np "b")] [transition t] [arc a t, (arc a t) {mode = Read}, arc t (np "b")]
        lastThree xs = drop (length xs - 3) xs

    -- TestReadArc.test_begin_records_the_read_selection_in_the_begin_batch
    it "begin records the read selection in the begin batch" $ do
      inst <- seeded
      (b : _) <- candidates inst
      occurrence <- expectOk (begin inst b (Just 1))
      recorded <- recordsOf inst
      lastThree recorded
        `shouldBe` [ RFiringBegun (FiringBegun process 1 Nothing 1)
                   , RTokensConsumed (TokensConsumed trigger [black] 1 [] Nothing 1)
                   , RTokensRead (TokensRead config [settings] 1 [] Nothing 1)
                   ]
      occurrence.records `shouldBe` lastThree recorded

    -- TestReadArc.test_a_binding_that_consumes_its_own_read_token_cannot_begin
    it "a binding that consumes its own read token cannot begin" $ do
      inst <- instanceOf overlapNet defaultInstanceConfig {initialMarking = markingFromList [(a, [tok "X"])]}
      [b] <- candidates inst
      before' <- Store.size (instanceHistory inst)
      Left (Refused message) <- begin inst b Nothing
      message `shouldBe` "cannot begin firing t: stale selection — cannot read Token('X', None) from a: token not present"
      Store.size (instanceHistory inst) `shouldReturn` before'

    -- TestReadArc.test_the_read_validates_against_the_surviving_token
    it "the read validates against the surviving token" $ do
      inst <- instanceOf overlapNet defaultInstanceConfig {initialMarking = markingFromList [(a, [tok "X", tok "X"])]}
      (b : _) <- candidates inst
      _ <- expectOk (begin inst b (Just 1))
      recorded <- recordsOf inst
      lastThree recorded
        `shouldBe` [ RFiringBegun (FiringBegun t 1 Nothing 1)
                   , RTokensConsumed (TokensConsumed a [tok "X"] 1 [] Nothing 1)
                   , RTokensRead (TokensRead a [tok "X"] 1 [] Nothing 1)
                   ]
      marking inst `shouldReturn` markingFromList [(a, [tok "X"])]

    -- TestReadArc.test_tokens_read_is_replay_inert_for_the_marking
    it "TokensRead is replay-inert for the marking" $ do
      inst <- seeded
      _ <- stepOnce inst
      recorded <- recordsOf inst
      [() | RTokensRead _ <- recorded] `shouldNotBe` []
      replaysToLive inst
      fmap (toList . placeTokens config) (replayMarking recorded) `shouldBe` Right [settings]

  describe "colored consume selection" $ do
    let pending = np "pending"
        cash = np "cash"
        out = np "out"
        net = netOf [place pending, place out] [transition cash] [withArcColor (Just "Payment") (arc pending cash), arc cash out]

    -- TestColoredConsumeSelection.test_movement_records_carry_the_selected_token_and_replay
    it "movement records carry the selected token, and replay" $ do
      inst <- instanceOf net defaultInstanceConfig {initialMarking = markingFromList [(pending, [invoice, big])]}
      firing <- stepOnce inst
      firing.records
        `shouldBe` [ RFiringBegun (FiringBegun cash 1 Nothing 0)
                   , RTokensConsumed (TokensConsumed pending [big] 1 [] Nothing 0)
                   , RTokensProduced (TokensProduced out [big] 1 [] Nothing 0)
                   , RFiringCompleted (FiringCompleted cash 1 0)
                   ]
      firing.consumed `shouldBe` [big]
      firing.produced `shouldBe` [(out, big)]
      replaysToLive inst

  describe "named filter selection" $ do
    let pending = np "pending"
        pay = np "pay"
        out = np "out"
        net = netOf [place pending, place out] [transition pay] [withArcColor (Just "Payment") ((arc pending pay) {filter = Just (FilterSymbol "is_big")}), arc pay out]
        bigs = Map.fromList [(Symbol "is_big", isBig)]

    -- TestNamedFilterSelection.test_movement_records_carry_the_filter_selected_token_and_replay
    it "movement records carry the filter-selected token, and replay" $ do
      inst <- instanceOf net defaultInstanceConfig {initialMarking = markingFromList [(pending, [small, big])], filterImplementations = bigs}
      firing <- stepOnce inst
      firing.records
        `shouldBe` [ RFiringBegun (FiringBegun pay 1 Nothing 0)
                   , RTokensConsumed (TokensConsumed pending [big] 1 [] Nothing 0)
                   , RTokensProduced (TokensProduced out [big] 1 [] Nothing 0)
                   , RFiringCompleted (FiringCompleted pay 1 0)
                   ]
      firing.consumed `shouldBe` [big]
      firing.produced `shouldBe` [(out, big)]
      replaysToLive inst

    -- TestNamedFilterSelection.test_missing_filter_implementation_fails_at_construction
    -- (the Instance half; the kernel half is in ArcFiltersSpec)
    it "a missing filter implementation fails at construction" $ do
      Left (Refused message) <- newInstance net defaultInstanceConfig
      message `shouldBe` "filter declaration(s) with no implementation: [\"'is_big' (arc:/pending->/pay#filter)\"]"

    -- TestNamedFilterSelection.test_exact_and_bare_filter_binding_is_ambiguous
    it "an exact and a bare filter binding is ambiguous" $ do
      [uri] <- pure (map fst (filterDeclarations net))
      Left (Refused message) <-
        newInstance net defaultInstanceConfig {filterImplementations = Map.fromList [(Symbol "is_big", isBig), (Exact uri, isBig)]}
      message `shouldBe` "filter declaration arc:/pending->/pay#filter has both an exact implementation and local symbol 'is_big'"

  describe "CEL filter selection" $ do
    let pending = np "pending"
        pay = np "pay"
        out = np "out"
        celNet expression = netOf [place pending, place out] [transition pay] [withArcColor (Just "Payment") ((arc pending pay) {filter = Just (FilterCel (unsafeCel expression))}), arc pay out]

    -- TestCelFilterSelection.test_cel_selection_consumes_and_replays_like_any_other
    it "consumes and replays like any other selection" $ do
      inst <-
        instanceOf
          (celNet "amount >= 100")
          defaultInstanceConfig {initialMarking = markingFromList [(pending, [small, big])], celCompilers = celStub}
      firing <- stepOnce inst
      firing.consumed `shouldBe` [big]
      [r | r@(RTokensConsumed _) <- firing.records] `shouldBe` [RTokensConsumed (TokensConsumed pending [big] 1 [] Nothing 0)]
      replaysToLive inst

    -- TestCelFilterSelection.test_invalid_cel_fails_at_construction_and_never_evaluates
    it "invalid CEL fails at construction and never evaluates" $ do
      Left (Refused message) <-
        newInstance
          (celNet "amount >=")
          defaultInstanceConfig {initialMarking = markingFromList [(pending, [big])], celCompilers = celStub}
      message `shouldBe` "invalid CEL filter 'amount >=': amount >=\n       ^\n"

    -- TestCelFilterSelection.test_exact_override_of_inline_cel_filter_is_refused
    it "an exact override of an inline CEL filter is refused" $ do
      let net = netOf [place pending, place out] [transition pay] [(arc pending pay) {filter = Just (FilterCel (unsafeCel "true"))}, arc pay out]
      [uri] <- pure (map fst (filterDeclarations net))
      Left (Refused message) <-
        newInstance net defaultInstanceConfig {filterImplementations = Map.fromList [(Exact uri, const (Right True))], celCompilers = celStub}
      message `shouldBe` "inline filter declaration arc:/pending->/pay#filter already supplies its Cel implementation"
