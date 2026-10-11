-- | @tests/unit/readiness/test_payloads.py@ against this package's
-- 'Hamsterdan.Readiness.Payloads' (the @PydanticPayloadConverter@ port).
--
-- The module's 10 functions (12 cases) are ported in full against the
-- contracts in hamsterdan-contracts' CodecSpec. Here the 8 functions (9
-- cases) that exercise the converter itself run through 'decodeModel',
-- 'encodeModel', and 'pydanticPayloadConverter'; the two pure-contract
-- functions (field partition, concern projection) need no converter and
-- live only in CodecSpec. Two converter refusals the reference raises but
-- never tests (a non-mapping payload, a mistyped result) are pinned too.
module PayloadsSpec (spec) where

import Data.Either (isLeft)
import Data.Text qualified as T
import Hamsterdan.Contracts.Codec (Codec (..), Contract (..), DecodeError, colorOf, dump, modelOf, validate)
import Hamsterdan.Contracts.Readiness
import Hamsterdan.Contracts.ReadinessProjection (Concerns (..), projectReadiness)
import Hamsterdan.Readiness.Payloads (decodeModel, encodeModel, pydanticPayloadConverter)
import Petrus.Activity (PayloadConverter (..))
import Petrus.Json (Json (..))
import Test.Hspec
import Data.Bifunctor (first)
import Hamsterdan.Python (pythonFailureText)

members :: Json -> [(T.Text, Json)]
members = \case
  Object found -> found
  _ -> []

authorityPayload :: [(T.Text, Json)]
authorityPayload =
  [ ("repository_id", String "repo")
  , ("pr_number", Int 7)
  , ("epoch", Int 1)
  , ("head", String "head")
  , ("base_head", String "base")
  , ("strict_base", Bool True)
  , ("base_current", Bool True)
  ]

-- | @project_readiness(Authority("repo", 7, 1, "head", "base", True, True),
-- ActionsState(), ...)@ with every other concern at its defaults.
defaultSnapshot :: Either DecodeError ReadinessSnapshot
defaultSnapshot =
  fmap projectReadiness $
    Concerns
      <$> validate (Object authorityPayload)
      <*> none
      <*> none
      <*> none
      <*> none
      <*> none
      <*> none
      <*> none
      <*> none
 where
  none :: (Contract a) => Either DecodeError a
  none = validate (Object [])

spec :: Spec
spec = describe "payloads converter" $ do
  it "round trips a strict JSON workflow model" $ do
    value <-
      either (fail . show) pure $
        decodeModel @ActionsObservation
          (Object [("epoch", Int 1), ("head", String "head"), ("run_id", String "run"), ("attempt", Int 1), ("conclusion", String "success")])
    let converter = pydanticPayloadConverter (modelOf (contract @ActionsObservation))
        encoded = converter.encodePayload (encodeModel value)
    encoded `shouldBe` Right (dump value)
    (encoded >>= converter.decodePayload) `shouldBe` Right (dump value)
    (encoded >>= first pythonFailureText . decodeModel @ActionsObservation) `shouldBe` Right value

  it "admitted conversation forbids provider fields" $ do
    let value = AdmittedConversation "delivery" 1 2 "human" "OWNER" "status"
        payload = members (dump value)
    decodeModel @AdmittedConversation (Object payload) `shouldBe` Right value
    first pythonFailureText (decodeModel @AdmittedConversation (Object (payload <> [("actor_type", String "User")]))) `shouldBe` Left "ValidationError()"
    first pythonFailureText (decodeModel @AdmittedConversation (Object ([m | m@(k, _) <- payload, k /= "comment_id"] <> [("comment_id", String "1")])))
      `shouldBe` Left "ValidationError()"

  describe "rejects coercion and extra fields" $ do
    it "a string pr_number" $
      decodeModel @Authority (Object [(k, if k == "pr_number" then String "7" else v) | (k, v) <- authorityPayload]) `shouldSatisfy` isLeft
    it "an unknown member" $
      decodeModel @Authority (Object (authorityPayload <> [("unknown", Bool True)])) `shouldSatisfy` isLeft

  it "closed workflow vocabulary rejects an unknown actions state" $
    first pythonFailureText (decodeModel @ActionsState (Object [("actions", String "provider-private")])) `shouldBe` Left "ValidationError()"

  -- DIVERGENCES.md: the reference refuses @type(value) is not ChangeResult@.
  -- 'encodeModel' is typed, so a RepairResult cannot be encoded as a
  -- ChangeResult at all; the type-erased converter only sees JSON and
  -- accepts a RepairResult dump that is a valid ChangeResult payload.
  it "rejects a different nominal result contract (statically)" $ do
    repair <- either (fail . show) pure (decodeModel @RepairResult (Object [("epoch", Int 1), ("head", String "head"), ("ok", Bool True)]))
    colorOf repair `shouldBe` "RepairResult"
    codecName (contract @ChangeResult) `shouldBe` "ChangeResult"
    let converter = pydanticPayloadConverter (modelOf (contract @ChangeResult))
    converter.encodePayload (Object [("epoch", String "1")]) `shouldBe` Left "TypeError('Pydantic result must be ChangeResult')"
    (converter.encodePayload (encodeModel repair) >>= first pythonFailureText . decodeModel @ChangeResult) `shouldSatisfy` (not . isLeft)

  it "split tokens are strict and extra forbidden" $ do
    decodeModel @ActionsState (Object [("attempt", String "1")]) `shouldSatisfy` isLeft
    decodeModel @HumanState (Object [("unknown", Bool True)]) `shouldSatisfy` isLeft

  it "round trips a readiness snapshot" $ do
    snapshot <- either (fail . show) pure defaultSnapshot
    let converter = pydanticPayloadConverter (modelOf (contract @ReadinessSnapshot))
    (converter.encodePayload (encodeModel snapshot) >>= first pythonFailureText . decodeModel @ReadinessSnapshot) `shouldBe` Right snapshot

  it "round trips an immutable dashboard request" $ do
    snapshot <- either (fail . show) pure defaultSnapshot
    let request = DashboardPublicationRequest 1 "head" "dashboard:1" "base" "policy" snapshot
        converter = pydanticPayloadConverter (modelOf (contract @DashboardPublicationRequest))
    (converter.encodePayload (encodeModel request) >>= converter.decodePayload >>= first pythonFailureText . decodeModel @DashboardPublicationRequest)
      `shouldBe` Right request

  it "refuses a non-mapping payload with the reference's TypeError" $
    first pythonFailureText (decodeModel @Authority (Array [])) `shouldBe` Left "TypeError('Pydantic payload for Authority must be a mapping')"
