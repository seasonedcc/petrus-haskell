{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Ports of upstream tests/unit/readiness/test_payloads.py plus codec
-- properties the upstream relies on implicitly.
module CodecSpec (spec) where

import Data.Either (isLeft)
import Data.List (sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Hamsterdan.Contracts.Codec
import Hamsterdan.Contracts.Readiness
import Hamsterdan.Contracts.ReadinessProjection
import Hamsterdan.Contracts.ReadinessV5 qualified as V5
import Petrus.Json (Json (..), compact, dumps)
import Test.Hspec

obj :: Json -> [(Text, Json)]
obj = \case
  Object members -> members
  _ -> []

-- Decode a contract from a Python-style payload dict.
decodeAs :: (Contract a) => [(Text, Json)] -> Either DecodeError a
decodeAs = validate . Object

authority :: Authority
authority =
  Authority
    { repositoryId = "repo"
    , prNumber = 7
    , epoch = 1
    , head = "head"
    , baseHead = "base"
    , strictBase = True
    , baseCurrent = True
    , policyDigest = ""
    , requiredChecks = []
    , requiredApprovals = 0
    , conversationResolution = False
    , admissionRelation = AdmissionNew
    }

-- Python's no-argument constructors, via the declared defaults.
defaults :: (Contract a) => Either DecodeError a
defaults = decodeAs []

defaultConcerns :: Either DecodeError Concerns
defaultConcerns =
  Concerns authority <$> defaults <*> defaults <*> defaults <*> defaults <*> defaults <*> defaults <*> defaults <*> defaults

spec :: Spec
spec = describe "contracts (test_payloads.py)" $ do
  it "round trips a strict JSON workflow model (test_converter_round_trips_strict_json_workflow_model)" $ do
    let value =
          settleObservation
            ActionsObservation
              { epoch = 1
              , head = "head"
              , runId = "run"
              , attempt = 1
              , conclusion = ConclusionSuccess
              , fingerprint = ""
              , capabilityAvailable = True
              , observation = ""
              , operation = ""
              , baseHead = ""
              , policyDigest = ""
              }
        encoded = dump value
    value.observation `shouldBe` "run:1:success"
    validate encoded `shouldBe` Right value
    lookup "observation" (obj encoded) `shouldBe` Just (String "run:1:success")

  it "refuses provider fields and coercion on AdmittedConversation (test_admitted_conversation_...)" $ do
    let value = AdmittedConversation "delivery" 1 2 "human" "OWNER" "status"
        payload = obj (dump value)
    (decodeAs payload :: Either DecodeError AdmittedConversation) `shouldBe` Right value
    (decodeAs (payload <> [("actor_type", String "User")]) :: Either DecodeError AdmittedConversation) `shouldSatisfy` isLeft
    (decodeAs ([(k, v) | (k, v) <- payload, k /= "comment_id"] <> [("comment_id", String "1")]) :: Either DecodeError AdmittedConversation)
      `shouldSatisfy` isLeft

  it "rejects coercion and extra fields on Authority (test_converter_rejects_coercion_and_extra_fields)" $ do
    let base =
          [ ("repository_id", String "repo")
          , ("epoch", Int 1)
          , ("head", String "h")
          , ("base_head", String "b")
          , ("strict_base", Bool True)
          , ("base_current", Bool True)
          ]
    (decodeAs (("pr_number", String "7") : base) :: Either DecodeError Authority) `shouldSatisfy` isLeft
    (decodeAs (("pr_number", Int 7) : ("unknown", Bool True) : base) :: Either DecodeError Authority) `shouldSatisfy` isLeft
    (decodeAs (("pr_number", Int 7) : base) :: Either DecodeError Authority) `shouldSatisfy` (not . isLeft)

  it "rejects an unknown actions state (test_closed_workflow_vocabulary_rejects_unknown_actions_state)" $
    (decodeAs [("actions", String "provider-private")] :: Either DecodeError ActionsState) `shouldSatisfy` isLeft

  it "keeps result contracts nominal (test_converter_rejects_a_different_nominal_result_contract)" $ do
    -- RepairResult and ChangeResult are distinct Haskell types, so encoding
    -- one as the other does not type-check; what remains observable is
    -- that each carries its own color.
    repair <- either (fail . show) pure (decodeAs [("epoch", Int 1), ("head", String "head"), ("ok", Bool True)] :: Either DecodeError RepairResult)
    colorOf repair `shouldBe` "RepairResult"
    codecName (contract @ChangeResult) `shouldBe` "ChangeResult"

  it "partitions snapshot fields among the concern tokens (test_readiness_state_tokens_partition_snapshot_fields)" $ do
    let fieldSets =
          map
            Set.fromList
            [ codecFields (contract @Authority)
            , codecFields (contract @ActionsState)
            , codecFields (contract @ReviewState)
            , codecFields (contract @HumanState)
            , codecFields (contract @MutationState)
            , codecFields (contract @FindingPublicationState)
            , codecFields (contract @ConversationPublicationState)
            , codecFields (contract @DashboardPublicationState)
            , codecFields (contract @ReadinessPublicationState)
            ]
        internal = Set.fromList ["conversation_recovery", "dashboard_recovery", "readiness_recovery"]
        pairs = [(a, b) | (i, a) <- zip [0 :: Int ..] fieldSets, (j, b) <- zip [0 ..] fieldSets, i < j]
    all (\(a, b) -> Set.disjoint a b) pairs `shouldBe` True
    Set.unions fieldSets `Set.union` Set.fromList ["dashboard_current", "wait"] `Set.difference` internal
      `shouldBe` Set.fromList (codecFields (contract @ReadinessSnapshot))

  describe "projects concern tokens to derived snapshots (test_concern_tokens_project_to_derived_snapshots)" $ do
    let check concerns = do
          let projected = projectReadiness concerns
              internal = ["conversation_recovery", "dashboard_recovery", "readiness_recovery"]
              tokenMembers =
                concat
                  [ obj (dump concerns.authority)
                  , obj (dump concerns.actions)
                  , obj (dump concerns.review)
                  , obj (dump concerns.human)
                  , obj (dump concerns.mutation)
                  , obj (dump concerns.findingPublication)
                  , obj (dump concerns.conversationPublication)
                  , obj (dump concerns.dashboardPublication)
                  , obj (dump concerns.readinessPublication)
                  ]
              expected =
                [(k, v) | (k, v) <- tokenMembers, k `notElem` internal]
                  <> [("dashboard_current", Bool projected.dashboardCurrent), ("wait", String projected.wait)]
          sortOnKey (obj (dump projected)) `shouldBe` sortOnKey expected
    it "default concerns" $ either (fail . show) check defaultConcerns
    it "a green, clear, approved head" $ do
      Concerns _ _ _ _ mutation _ conversation dashboard readiness <- either (fail . show) pure defaultConcerns
      actions <- either (fail . show) pure (decodeAs [("actions", String "green"), ("run_id", String "run"), ("attempt", Int 2)])
      review <- either (fail . show) pure (decodeAs [("review", String "clear"), ("findings", Array [Object [("id", String "f1"), ("blocking", Bool False)]])])
      human <- either (fail . show) pure (decodeAs [("human_requested", Bool True), ("human_approved", Bool True), ("mergeable", Bool True), ("author", String "octocat")])
      findings <- either (fail . show) pure (decodeAs [("findings_published", Bool True)])
      let authority3 =
            Authority
              { repositoryId = "repo"
              , prNumber = 7
              , epoch = 3
              , head = "head-3"
              , baseHead = "base-2"
              , strictBase = True
              , baseCurrent = False
              , policyDigest = "policy"
              , requiredChecks = ["test"]
              , requiredApprovals = 2
              , conversationResolution = False
              , admissionRelation = AdmissionNew
              }
      check (Concerns authority3 actions review human mutation findings conversation dashboard readiness)

  it "refuses coercion and unknown fields on split tokens (test_split_tokens_are_strict_and_extra_forbidden)" $ do
    (decodeAs [("attempt", String "1")] :: Either DecodeError ActionsState) `shouldSatisfy` isLeft
    (decodeAs [("unknown", Bool True)] :: Either DecodeError HumanState) `shouldSatisfy` isLeft

  it "round trips a readiness snapshot (test_converter_round_trips_readiness_snapshot)" $ do
    concerns <- either (fail . show) pure defaultConcerns
    let snapshot = projectReadiness concerns
    validate (dump snapshot) `shouldBe` Right snapshot

  it "round trips an immutable dashboard request (test_converter_round_trips_immutable_dashboard_request)" $ do
    concerns <- either (fail . show) pure defaultConcerns
    let request = DashboardPublicationRequest 1 "head" "dashboard:1" "base" "policy" (projectReadiness concerns)
    validate (dump request) `shouldBe` Right request

  describe "codec behaviors" $ do
    it "dumps every field, defaults included, in declaration order" $ do
      seen <- either (fail . show) pure (decodeAs [("policy", String "p"), ("mergeable", Bool True), ("base", String "b"), ("head", String "h")] :: Either DecodeError V5.HeadSeen)
      dumps compact (dump seen)
        `shouldBe` Right "{\"head\":\"h\",\"base\":\"b\",\"mergeable\":true,\"policy\":\"p\",\"strict_base\":true,\"base_current\":false}"
    it "puts a typed fact's constant kind last" $ do
      let fact = V5.FindingsFact 2 (V5.FindingsFactBody "h" 1 3)
      dumps compact (dump fact) `shouldBe` Right "{\"incarnation\":2,\"body\":{\"head\":\"h\",\"blocking\":1,\"count\":3},\"kind\":\"findings\"}"
    it "admits Literal[0] by Python equality, as pydantic does" $ do
      let body = Object [("where", String "rerun"), ("op", String "o"), ("status", String "resolved")]
          fact value = validate (Object [("incarnation", value), ("body", body)]) :: Either DecodeError V5.FaultClearedFact
      map (isLeft . fact) [Int 0, Bool False, Float 0, Float (-0), Bool True, Float 0.5, String "0", Null]
        `shouldBe` [False, False, False, False, True, True, True, True]
    it "dumps non-finite floats in untyped members as null" $ do
      let fact = V5.GateFact "k" 1 [("a", Float (1 / 0)), ("b", Array [Float (0 / 0)])]
      dumps compact (dump fact) `shouldBe` Right "{\"kind\":\"k\",\"incarnation\":1,\"body\":{\"a\":null,\"b\":[null]}}"
    it "names every model after its pydantic class" $ do
      colorOf (V5.CloseSeen "r") `shouldBe` "CloseSeen"
      colorOf V5.DraftSeen `shouldBe` "DraftSeen"

sortOnKey :: [(Text, Json)] -> [(Text, Json)]
sortOnKey = sortOn fst
