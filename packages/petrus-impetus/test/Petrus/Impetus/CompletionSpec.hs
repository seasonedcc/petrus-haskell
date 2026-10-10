-- | Parity: @tests/petrus/impetus/instance/test_completion.py@ — the
-- completion condition, the done judgment of 'status'.
--
-- Inline CEL conditions compile through "Petrus.Impetus.CelStub" (CEL is a
-- separate package in the Haskell port). The reference's
-- @CompletionEvaluationWarning@ is the diagnostic 'statusWithDiagnostics'
-- returns. The CEL-environment cases (how places and tokens appear to an
-- expression) and the macro-variable analysis are the CEL package's and
-- not at parity; non-symbol completions and unencodable token data are
-- enforced by types.
module Petrus.Impetus.CompletionSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Petrus.Impetus.CelStub (celStub)
import Petrus.Impetus.Instance
import Petrus.Impetus.InstanceSupport
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Test.Hspec

pa, tt, pb :: NetPath
pa = np "a"
tt = np "t"
pb = np "b"

-- | a -> t -> b, with the completion condition under test.
chain :: Maybe CompletionDeclaration -> Net
chain completion = mustNet (NetSpec [place pa, place pb] [transition tt] [arc pa tt, arc tt pb] completion Nothing)

celChain :: Text -> Net
celChain = chain . Just . CompletionCel . unsafeCel

-- | @Instance(chain(...), marking)@ with the CEL stub.
judged :: HasCallStack => Net -> Marking -> IO Instance
judged net m = seededWith net defaultInstanceConfig {initialMarking = m, celCompilers = celStub}

oneBlack :: Marking
oneBlack = markingFromList [(pa, [black])]

spec :: Spec
spec = describe "Instance completion" $ do
  describe "status resolution" $ do
    -- TestStatusResolution.test_completed_when_quiescent_and_the_condition_holds
    it "is completed when quiescent and the condition holds" $ do
      inst <- judged (celChain "size(b) == 1") oneBlack
      _ <- run inst >>= expectRight
      status inst `shouldReturn` Completed
    -- TestStatusResolution.test_stuck_when_quiescent_and_the_condition_does_not_hold
    it "is stuck when quiescent and the condition does not hold" $ do
      inst <- judged (celChain "size(b) >= 2") oneBlack
      _ <- run inst >>= expectRight
      status inst `shouldReturn` Stuck
    -- TestStatusResolution.test_terminated_stays_the_neutral_collapse_without_a_declaration
    it "stays the neutral terminated without a declaration" $ do
      inst <- seeded (chain Nothing) oneBlack
      _ <- run inst >>= expectRight
      status inst `shouldReturn` Terminated
    -- TestStatusResolution.test_running_while_enabled_even_when_the_condition_already_holds
    it "is running while enabled even when the condition already holds" $ do
      inst <- judged (celChain "size(a) == 1") oneBlack
      status inst `shouldReturn` Running
    -- TestStatusResolution.test_the_condition_never_affects_enabledness_or_firing
    it "never affects enabledness or firing" $ do
      withCondition <- judged (celChain "size(b) == 1") oneBlack
      neutral <- seeded (chain Nothing) oneBlack
      judgedCandidates <- candidates withCondition
      candidates neutral `shouldReturn` judgedCandidates
      judgedRun <- run withCondition >>= expectRight
      neutralRun <- run neutral >>= expectRight
      map (.records) judgedRun `shouldBe` map (.records) neutralRun
    -- TestStatusResolution.test_status_is_a_pure_projection_of_the_marking
    it "is a pure projection of the marking" $ do
      inst <- judged (celChain "size(b) == 1") oneBlack
      _ <- run inst >>= expectRight
      recorded <- historyLength inst
      sequence [status inst, status inst] `shouldReturn` [Completed, Completed]
      marking inst `shouldReturn` markingFromList [(pb, [black])]
      historyLength inst `shouldReturn` recorded

  -- TestCelEnvironment.test_place_variables_bind_token_color_and_data,
  -- TestCelEnvironment.test_a_black_token_reads_as_null_color_and_data,
  -- TestCelEnvironment.test_an_empty_place_binds_to_the_empty_list:
  -- not at parity — the expression environment is the CEL package's.

  describe "named completion" $ do
    -- TestNamedCompletion.test_named_symbol_binds_and_sees_the_marking
    it "binds a named symbol that sees the marking" $ do
      inst <-
        seededWith
          (chain (Just (CompletionSymbol "allSettled")))
          defaultInstanceConfig
            { initialMarking = oneBlack
            , completionImplementations = Map.fromList [("allSettled", \m -> Right (not (null (placeTokens pb m))))]
            }
      _ <- run inst >>= expectRight
      status inst `shouldReturn` Completed
    -- TestNamedCompletion.test_missing_implementation_fails_at_construction
    it "fails at construction on a missing implementation" $ do
      result <- newInstance (chain (Just (CompletionSymbol "allSettled"))) defaultInstanceConfig
      result `shouldRefuse` "completion symbol with no implementation: 'allSettled'"

  describe "completion validation" $ do
    -- TestCompletionValidation.test_invalid_cel_fails_at_construction_and_never_evaluates
    it "fails at construction on invalid CEL and never evaluates" $ do
      result <- newInstance (celChain "size(b) ==") defaultInstanceConfig {celCompilers = celStub}
      result `shouldRefuse` "invalid CEL completion 'size(b) ==': size(b) ==\n        ^\n"
    -- TestCompletionValidation.test_unknown_place_reference_fails_at_construction
    it "fails at construction on an unknown place reference" $ do
      result <- newInstance (celChain "size(doen) > 0") defaultInstanceConfig {celCompilers = celStub}
      result `shouldRefuse` "CEL completion 'size(doen) > 0' references unknown place(s): ['doen']"
    -- TestCompletionValidation.test_macro_bound_variables_are_not_place_references:
    -- not at parity — the free-variable analysis is the CEL package's.
    -- TestCompletionValidation.test_a_non_symbol_non_cel_completion_is_rejected_at_build:
    -- enforced by types ('CompletionDeclaration' has only the two encodings).

  describe "completion evaluation errors" $ do
    -- TestCompletionEvaluationErrors.test_a_raising_condition_reads_as_stuck_with_a_diagnostic
    it "reads a raising condition as stuck, with a diagnostic" $ do
      inst <-
        seededWith
          (chain (Just (CompletionSymbol "allSettled")))
          defaultInstanceConfig
            { initialMarking = oneBlack
            , completionImplementations = Map.fromList [("allSettled", const (Left "RuntimeError('boom')"))]
            }
      _ <- run inst >>= expectRight
      statusWithDiagnostics inst
        `shouldReturn` (Stuck, ["completion condition 'allSettled' raised RuntimeError('boom') evaluating Marking({b: 1}); read as not holding"])
    -- TestCompletionEvaluationErrors.test_unencodable_token_data_reads_as_stuck_with_a_diagnostic:
    -- enforced by types (token data is 'Json', always encodable).
