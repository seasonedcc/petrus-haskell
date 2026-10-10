-- | Parity: @tests/petrus/impetus/instance/test_instance_identity.py@ — the
-- instance identity fact: every History opens with @InstanceCreated@ (the
-- minted or supplied id and the net's optional name), and 'resume' derives
-- identity from that record, never from a re-supplied argument.
module Petrus.Impetus.InstanceIdentitySpec (spec) where

import Data.Text (Text)
import Petrus.Impetus.History
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.InstanceSupport
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Test.Hspec

pa, pb, tt :: NetPath
pa = np "a"
pb = np "b"
tt = np "t"

namedSpec :: Maybe Text -> NetSpec
namedSpec = NetSpec [place pa, place pb] [transition tt] [arc pa tt, arc tt pb] Nothing

namedNet :: Maybe Text -> Net
namedNet = mustNet . namedSpec

-- | A run instance over a one-token line net.
ranOver :: Net -> InstanceConfig -> IO Instance
ranOver net cfg = do
  inst <- seededWith net cfg {initialMarking = markingFromList [(pa, [tok "X"])]}
  _ <- run inst >>= expectRight
  pure inst

spec :: Spec
spec = describe "Instance identity" $ do
  describe "net name" $ do
    -- TestNetName.test_the_definition_name_is_optional_and_descriptive
    it "is optional and descriptive" $ do
      netName (namedNet Nothing) `shouldBe` Nothing
      netName (namedNet (Just "order-fulfillment")) `shouldBe` Just "order-fulfillment"
    -- TestNetName.test_an_empty_or_non_string_name_is_refused (the
    -- non-string half is enforced by types: a name is 'Text')
    it "refuses an empty name" $
      either Left (const (Right ())) (mkNet (namedSpec (Just ""))) `shouldFailWith` "net name must be a non-empty string, got ''"

  describe "identity is recorded first" $ do
    -- TestIdentityIsRecordedFirst.test_construction_records_the_identity_fact_before_anything
    it "records the identity fact before anything" $ do
      inst <-
        seededWith
          (namedNet (Just "order-fulfillment"))
          defaultInstanceConfig
            { initialMarking = markingFromList [(pa, [tok "X"])]
            , constructionInstant = 5
            , suppliedIdentity = Just "order-7"
            }
      take 1 <$> historyOf inst `shouldReturn` [RInstanceCreated (InstanceCreated "order-7" (Just "order-fulfillment") 5)]
    -- TestIdentityIsRecordedFirst.test_an_unsupplied_id_is_minted_unique_and_creation_ordered
    it "mints an unsupplied id unique and creation-ordered" $ do
      first' <- seeded (namedNet Nothing) emptyMarking
      second' <- seeded (namedNet Nothing) emptyMarking
      instanceIdentity first' < instanceIdentity second' `shouldBe` True
      take 1 <$> historyOf first' `shouldReturn` [RInstanceCreated (InstanceCreated (instanceIdentity first') Nothing 0)]
    -- TestIdentityIsRecordedFirst.test_an_unnamed_net_records_no_name
    it "records no name for an unnamed net" $ do
      inst <- seededWith (namedNet Nothing) defaultInstanceConfig {suppliedIdentity = Just "order-7"}
      take 1 <$> historyOf inst `shouldReturn` [RInstanceCreated (InstanceCreated "order-7" Nothing 0)]

  describe "resume derives identity" $ do
    -- TestResumeDerivesIdentity.test_resume_reads_the_recorded_identity_back
    it "reads the recorded identity back" $ do
      inst <- ranOver (namedNet (Just "order-fulfillment")) defaultInstanceConfig {suppliedIdentity = Just "order-7"}
      resumed <- resume (namedNet (Just "order-fulfillment")) (instanceHistory inst) defaultInstanceConfig >>= expectRight
      instanceIdentity resumed `shouldBe` "order-7"
    -- TestResumeDerivesIdentity.test_identity_survives_a_crash_that_a_resupplied_argument_would_not
    it "keeps a minted identity across resume with no argument" $ do
      inst <- ranOver (namedNet Nothing) defaultInstanceConfig
      resumed <- resume (namedNet Nothing) (instanceHistory inst) defaultInstanceConfig >>= expectRight
      instanceIdentity resumed `shouldBe` instanceIdentity inst
    -- TestResumeDerivesIdentity.test_a_trace_without_identity_is_replay_divergence
    it "refuses a trace without identity as replay divergence" $ do
      inst <- ranOver (namedNet Nothing) defaultInstanceConfig
      malformed <- Store.inMemoryHistoryStore
      historyOf inst >>= malformed.extend . drop 1
      result <- resume (namedNet Nothing) malformed defaultInstanceConfig
      result `shouldRefuse` "replay divergence: the construction batch requires InstanceCreated as its first record"
    -- TestResumeDerivesIdentity.test_a_recorded_name_disagreeing_with_the_supplied_net_is_a_foreign_trace
    it "refuses a recorded name disagreeing with the supplied net as a foreign trace" $ do
      inst <- ranOver (namedNet (Just "order-fulfillment")) defaultInstanceConfig
      result <- resume (namedNet (Just "billing")) (instanceHistory inst) defaultInstanceConfig
      result
        `shouldRefuse` "cannot resume: the history records net name 'order-fulfillment' but the supplied net is named 'billing' — a foreign trace"
    -- TestResumeDerivesIdentity.test_an_unnamed_resupplied_net_accepts_a_named_trace
    it "accepts a named trace for an unnamed re-supplied net" $ do
      inst <- ranOver (namedNet (Just "order-fulfillment")) defaultInstanceConfig
      resumed <- resume (namedNet Nothing) (instanceHistory inst) defaultInstanceConfig >>= expectRight
      instanceIdentity resumed `shouldBe` instanceIdentity inst

  describe "identity folds" $ do
    -- TestIdentityFolds.test_a_mid_trace_identity_fact_is_replay_divergence
    it "refuses a mid-trace identity fact as replay divergence" $ do
      inst <- ranOver (namedNet Nothing) defaultInstanceConfig
      corrupted <- Store.inMemoryHistoryStore
      historyOf inst >>= \records -> corrupted.extend (records ++ [RInstanceCreated (InstanceCreated "intruder" Nothing 0)])
      folded <- replayInstanceIdentity <$> Store.records corrupted
      either Left (const (Right ())) folded
        `shouldFailWith` "replay divergence: InstanceCreated at position 7: the single writer records identity as the first record, exactly once"
    -- TestIdentityFolds.test_the_identity_fact_is_occurrence_less_by_classification
    it "classifies the identity fact as occurrence-less" $ do
      history <- Store.inMemoryHistoryStore
      Store.append history (RInstanceCreated (InstanceCreated "order-7" Nothing 0))
      replayNextOccurrence <$> Store.records history `shouldReturn` 1
