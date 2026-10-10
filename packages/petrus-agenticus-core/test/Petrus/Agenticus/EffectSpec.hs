-- | Ports of @tests/petrus/agenticus/effect/test_contract.py@ and
-- @test_provider_neutrality.py@, the docs/runtime.md §11 golden digests, and
-- the replay of @differential/effect_corpus.json@.
module Petrus.Agenticus.EffectSpec (spec) where

import Control.Exception (ErrorCall (..), throwIO, try)
import Control.Monad (forM_, when)
import Data.ByteString qualified as B
import Data.IORef
import Data.List (nubBy)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Agenticus.Effect.Gateway
import Petrus.Agenticus.Effect.Model
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Validate (canonicalBytes)
import Petrus.Agenticus.Support
import Petrus.Json (Json (..), lookupMember, parseJson, pythonLoads)
import Petrus.Json qualified as J
import Test.Hspec
import Test.QuickCheck

-- ---------------------------------------------------------------------------
-- Fixtures (the upstream module helpers)

payloadOf :: Json -> EffectPayload
payloadOf = expectRight . payloadFromJson

ready :: Json
ready = Object [("message", String "ready")]

proposalWith :: Json -> EffectProposal
proposalWith payload =
  expectRight $
    mkEffectProposal
      "proposal-7"
      "bulletin.publish"
      1
      (expectRight (digestPayloadJson payload))
      (expectRight (mkTargetIdentity "bulletin" "release-notes"))
      "bulletin.publish"

theProposal :: EffectProposal
theProposal = proposalWith ready

fenceWith :: EffectProposal -> (Text, Json) -> EffectFence
fenceWith p override =
  expectRight (fenceFromData (setMember (fst override) (snd override) (fenceToData (fenceFor p))))

fenceFor :: EffectProposal -> EffectFence
fenceFor p = expectRight (mkEffectFence p.proposalId p.digest 4 "revision-11" "episode-3" "attachment-8" 2)

receiptFor :: EffectProposal -> Json -> EffectReceipt
receiptFor p raw = expectRight (mkEffectReceipt p.proposalId p.digest p.payloadDigest p.target (expectRight (digestPayloadJson raw)))

defaultReceipt :: EffectProposal -> EffectReceipt
defaultReceipt p = receiptFor p (Object [("provider_record", String "record-1")])

withProposalId :: Text -> EffectReceipt -> EffectReceipt
withProposalId pid r = expectRight (mkEffectReceipt pid r.proposalDigest r.payloadDigest r.target r.receiptDigest)

approvalOf :: EffectProposal -> EffectFence -> EffectDecision
approvalOf p f = expectRight (approve p f)

dumped :: Json -> Text
dumped = either (error . show) id . J.dumpsText J.defaultDumps

-- | A provider failure carrying a canary message.
providerFailure :: Text -> IO a
providerFailure secret = throwIO (ErrorCall (T.unpack secret))

-- | @_ScriptedAdapter@ and @_Fences@.
data Script = Script
  { lookupCalls :: IORef Int
  , executeCalls :: IORef Int
  , fenceCalls :: IORef Int
  }

scripted :: [IO LookupResult] -> [IO EffectReceipt] -> IO (Script, EffectAdapter)
scripted lookups executions = do
  script <- Script <$> newIORef 0 <*> newIORef 0 <*> newIORef 0
  let next ref answers = do
        n <- readIORef ref
        writeIORef ref (n + 1)
        case drop n answers of
          answer : _ -> answer
          [] -> error "script exhausted"
      adapter =
        EffectAdapter
          { lookup = \_ -> next script.lookupCalls lookups
          , execute = \_ _ _ -> next script.executeCalls executions
          }
  pure (script, adapter)

countingFences :: Script -> IO EffectFence -> EffectFenceSource
countingFences script answer = EffectFenceSource (\_ -> modifyIORef' script.fenceCalls (+ 1) >> answer)

calls :: Script -> IO (Int, Int, Int)
calls script = (,,) <$> readIORef script.lookupCalls <*> readIORef script.executeCalls <*> readIORef script.fenceCalls

recoveryOf :: EffectDecision -> Maybe LookupDisposition
recoveryOf d = maybe (error "no evidence") (.recovery) d.evidence

-- ---------------------------------------------------------------------------
-- QuickCheck generators (hypothesis @_JSON@)

genText :: Int -> Gen Text
genText maxSize = do
  n <- chooseInt (0, maxSize)
  T.pack <$> vectorOf n arbitraryUnicodeChar

genJson :: Int -> Gen Json
genJson leaves
  | leaves <= 1 = scalar
  | otherwise =
      frequency
        [ (3, scalar)
        , (1, Array <$> (chooseInt (0, 5) >>= \n -> vectorOf n (genJson (leaves `div` 5))))
        , (1, genObject 5 (genJson (leaves `div` 5)))
        ]
  where
    scalar = oneof [pure Null, Bool <$> arbitrary, Int <$> arbitrary, String <$> genText 30]

genObject :: Int -> Gen Json -> Gen Json
genObject maxSize item = do
  n <- chooseInt (0, maxSize)
  members <- vectorOf n ((,) <$> genText 12 <*> item)
  -- Python dicts hold each key once.
  pure (Object (nubBy (\a b -> fst a == fst b) members))

-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "effect/test_contract.py" contractSpec
  describe "effect/test_provider_neutrality.py" neutralitySpec
  describe "effect golden vectors (docs/runtime.md §11)" goldenSpec
  describe "effect differential corpus" corpusSpec

contractSpec :: Spec
contractSpec = do
  it "test_proposal_and_fence_round_trip_as_exact_versioned_secret_free_data" $ do
    let secret = "SECRET-canary-not-for-evidence"
        payload = Object [("message", String "ready"), ("credential", String secret), ("labels", Array [String "release", String "green"])]
        p = proposalWith payload
        f = fenceFor p
    proposalToData p
      `shouldBe` Object
        [ ("schema_version", Int 1)
        , ("proposal_id", String "proposal-7")
        , ("effect_type", String "bulletin.publish")
        , ("effect_version", Int 1)
        , ("payload_digest", String p.payloadDigest)
        , ("target", Object [("target_type", String "bulletin"), ("target_id", String "release-notes")])
        , ("requested_authority_class", String "bulletin.publish")
        ]
    proposalFromData (proposalToData p) `shouldBe` Right p
    fenceFromData (fenceToData f) `shouldBe` Right f
    p.digest `shouldSatisfy` T.isPrefixOf "sha256:"
    dumped (proposalToData p) `shouldNotSatisfy` T.isInfixOf secret
    T.pack (show p) `shouldNotSatisfy` T.isInfixOf secret

  it "test_payload_digest_is_a_canonical_replay_identity" $
    withNumTests 60 $
      forAll (genObject 8 (genJson 20)) $ \payload ->
        let reordered = case payload of
              Object members -> Object (reverse members)
              other -> other
            replayed = either error id (parseJson pythonLoads (either (error . show) id (J.dumps J.compact payload)))
            p = proposalWith payload
         in digestPayloadJson payload === digestPayloadJson reordered
              .&&. digestPayloadJson payload === digestPayloadJson replayed
              .&&. Right p.digest === ((.digest) <$> proposalFromData (proposalToData p))
              -- The direct canonical writer agrees with petrus-json's.
              .&&. canonicalPayload (payloadOf payload) === canonicalBytes payload

  describe "test_payload_digest_rejects_non_strict_json_without_echoing_payload" $ do
    let refuses payload = case digestPayloadJson payload of
          Left e -> do
            e `shouldSatisfy` (\x -> x `isInstanceOf` TypeError || x `isInstanceOf` ValueError)
            e.errorMessage `shouldNotSatisfy` T.isInfixOf "not-an-object"
            e.errorMessage `shouldNotSatisfy` T.isInfixOf "non-string-key"
          Right digest -> expectationFailure ("accepted: " <> show digest)
    it "test_payload_digest_rejects_non_strict_json_without_echoing_payload[payload0]" $
      refuses (Array [String "not-an-object"])
    -- @{"tuple": (1, 2)}@ and @{1: "non-string-key"}@ cannot be written as
    -- 'Json': there is no tuple constructor and object keys are 'Text'.
    -- What remains checkable is that no payload type admits them.
    it "test_payload_digest_rejects_non_strict_json_without_echoing_payload[payload1]" $
      payloadValueToJson (PArray [PInt 1, PInt 2]) `shouldBe` Array [Int 1, Int 2]
    it "test_payload_digest_rejects_non_strict_json_without_echoing_payload[payload2]" $
      refuses (Object [("float", Float 1.25)])
    it "test_payload_digest_rejects_non_strict_json_without_echoing_payload[payload3]" $
      payloadToJson (payloadOf (Object [("1", String "non-string-key")])) `shouldBe` Object [("1", String "non-string-key")]

  describe "test_proposal_decoder_rejects_unknown_ambiguous_and_noncanonical_data" $ do
    let base = proposalToData theProposal
        target = maybe Null id (lookupMember "target" base)
        mutations =
          [ setMember "raw_payload" (Object [("secret", String "forbidden")]) base
          , setMember "schema_version" (Int 2) base
          , setMember "effect_version" (Bool True) base
          , setMember "payload_digest" (String "not-a-digest") base
          , setMember "target" (setMember "provider" (String "github") target) base
          ]
    forM_ (zip [0 :: Int ..] mutations) $ \(i, mutated) ->
      it ("test_proposal_decoder_rejects_unknown_ambiguous_and_noncanonical_data[<lambda>" <> show i <> "]") $
        proposalFromData mutated `shouldRaise` ValueError

  it "test_reject_and_approve_are_exactly_correlated_and_structurally_distinct" $ do
    let p = theProposal
        f = fenceFor p
        rejected = expectRight (reject p "host-policy-denied")
        approved = expectRight (approve p f)
    rejected.kind `shouldBe` DecisionReject
    rejected.reasonCode `shouldBe` Just "host-policy-denied"
    approved.kind `shouldBe` DecisionApprove
    approved.fence `shouldBe` Just f
    decisionFromData (decisionToData rejected) `shouldBe` Right rejected
    decisionFromData (decisionToData approved) `shouldBe` Right approved
    approve p (fenceWith p ("proposal_id", String "another-proposal")) `shouldRaiseMatching'` (ValueError, "proposal")

  it "test_receipt_lookup_evidence_and_decision_serialization_are_strict" $ do
    let p = theProposal
        f = fenceFor p
        r = defaultReceipt p
        lookupResult = LookupApplied r
        evidence = expectRight (mkEffectEvidence p.proposalId p.digest p.payloadDigest p.target f (Just Applied) (Just r.receiptDigest))
        decision = expectRight (mkEffectDecision DecisionAlreadyApplied p.proposalId p.digest (Just f) (Just evidence) Nothing)
    receiptFromData (receiptToData r) `shouldBe` Right r
    lookupFromData (lookupToData lookupResult) `shouldBe` Right lookupResult
    evidenceFromData (evidenceToData evidence) `shouldBe` Right evidence
    decisionFromData (decisionToData decision) `shouldBe` Right decision
    mkLookupResult Applied Nothing `shouldRaise` ValueError
    mkLookupResult SafeToRetry (Just r) `shouldRaise` ValueError
    let otherFence = fenceWith p ("proposal_id", String "another-proposal")
    mkEffectEvidence p.proposalId p.digest p.payloadDigest p.target otherFence (Just Applied) (Just r.receiptDigest)
      `shouldRaiseMatching'` (ValueError, "evidence fence")

  it "test_gateway_rejects_payload_or_approval_mismatch_before_provider_lookup" $ do
    let p = theProposal
        f = fenceFor p
    (script, adapter) <- scripted [pure LookupSafeToRetry] [pure (defaultReceipt p)]
    let gateway = effectGateway adapter (countingFences script (pure f))
    executeJson gateway p (Object [("message", String "changed")]) (approvalOf p f)
      `shouldRaiseMatchingIO` (ValueError, "payload digest")
    executeJson gateway p ready (expectRight (reject p "denied"))
      `shouldRaiseMatchingIO` (TypeError, "approved")
    (lookups, executions, _) <- calls script
    (lookups, executions) `shouldBe` (0, 0)

  it "test_gateway_never_blind_retries_an_uncertain_response_and_reports_safe_recovery" $ do
    let secret = "SECRET-provider-exception-canary"
        p = theProposal
        f = fenceFor p
    (script, adapter) <- scripted [pure LookupSafeToRetry, pure LookupSafeToRetry] [providerFailure secret]
    decision <- executeJson (effectGateway adapter (countingFences script (pure f))) p ready (approvalOf p f)
    decision.kind `shouldBe` DecisionIndeterminate
    recoveryOf decision `shouldBe` Just SafeToRetry
    (lookups, executions, _) <- calls script
    (lookups, executions) `shouldBe` (2, 1)
    T.pack (show decision) `shouldNotSatisfy` T.isInfixOf secret
    dumped (decisionToData decision) `shouldNotSatisfy` T.isInfixOf secret

  it "test_uncertain_response_is_reconciled_as_already_applied_with_exact_receipt" $ do
    let p = theProposal
        f = fenceFor p
        r = defaultReceipt p
    (script, adapter) <- scripted [pure LookupSafeToRetry, pure (LookupApplied r)] [throwAgenticus TimeoutError "response lost"]
    decision <- executeJson (effectGateway adapter (countingFences script (pure f))) p ready (approvalOf p f)
    decision.kind `shouldBe` DecisionAlreadyApplied
    ((.receiptDigest) <$> decision.evidence) `shouldBe` Just (Just r.receiptDigest)
    (_, executions, _) <- calls script
    executions `shouldBe` 1

  describe "test_lookup_dispositions_stop_before_fences_or_execution" $
    forM_ [(LookupSuperseded, DecisionSuperseded, "lookup0-superseded"), (LookupIndeterminate, DecisionIndeterminate, "lookup1-indeterminate")] $
      \(answer, kind, caseLabel) ->
        it ("test_lookup_dispositions_stop_before_fences_or_execution[" <> caseLabel <> "]") $ do
          let p = theProposal
          (script, adapter) <- scripted [pure answer] []
          decision <- executeJson (effectGateway adapter (countingFences script (pure (fenceFor p)))) p ready (approvalOf p (fenceFor p))
          decision.kind `shouldBe` kind
          (_, executions, fenceCount) <- calls script
          (fenceCount, executions) `shouldBe` (0, 0)

  describe "test_each_fence_is_refreshed_after_lookup_and_stale_state_never_executes" $
    forM_
      [ ("authority_epoch", Int 5, "authority_epoch-5")
      , ("target_head", String "revision-12", "target_head-revision-12")
      , ("proposal_digest", String ("sha256:" <> T.replicate 64 "0"), "proposal_digest-sha256:" <> replicate 64 '0')
      , ("episode_id", String "episode-4", "episode_id-episode-4")
      , ("attachment_id", String "attachment-9", "attachment_id-attachment-9")
      , ("attachment_epoch", Int 3, "attachment_epoch-3")
      ]
      $ \(fieldName, value, caseLabel) ->
        it ("test_each_fence_is_refreshed_after_lookup_and_stale_state_never_executes[" <> caseLabel <> "]") $ do
          let p = theProposal
              expected = fenceFor p
          (script, adapter) <- scripted [pure LookupSafeToRetry] []
          decision <-
            executeJson (effectGateway adapter (countingFences script (pure (fenceWith p (fieldName, value))))) p ready (approvalOf p expected)
          decision.kind `shouldBe` DecisionSuperseded
          recoveryOf decision `shouldBe` Just Superseded
          (lookups, executions, fenceCount) <- calls script
          (lookups, fenceCount, executions) `shouldBe` (1, 1, 0)

  it "test_uncorrelated_receipt_is_indeterminate_never_misreported_as_success" $ do
    let p = theProposal
        f = fenceFor p
        wrong = withProposalId "another-proposal" (defaultReceipt p)
    (script, adapter) <- scripted [pure LookupSafeToRetry, pure LookupSafeToRetry] [pure wrong]
    decision <- executeJson (effectGateway adapter (countingFences script (pure f))) p ready (approvalOf p f)
    decision.kind `shouldBe` DecisionIndeterminate
    decision.proposalId `shouldBe` p.proposalId
    ((.proposalId) <$> decision.evidence) `shouldBe` Just p.proposalId
    recoveryOf decision `shouldBe` Just SafeToRetry
    ((.receiptDigest) <$> decision.evidence) `shouldBe` Just Nothing
    (lookups, executions, _) <- calls script
    (lookups, executions) `shouldBe` (2, 1)

  describe "test_lookup_crash_or_uncorrelated_lookup_evidence_is_indeterminate_and_never_executes" $
    forM_
      [ ("lookup0", providerFailure "SECRET-lookup-crash")
      , ("lookup1", pure (LookupApplied (withProposalId "another-proposal" (defaultReceipt theProposal))))
      ]
      $ \(caseLabel, answer) ->
        it ("test_lookup_crash_or_uncorrelated_lookup_evidence_is_indeterminate_and_never_executes[" <> caseLabel <> "]") $ do
          let p = theProposal
              f = fenceFor p
          (script, adapter) <- scripted [answer] []
          decision <- executeJson (effectGateway adapter (countingFences script (pure f))) p ready (approvalOf p f)
          decision.kind `shouldBe` DecisionIndeterminate
          recoveryOf decision `shouldBe` Just Indeterminate
          (lookups, executions, fenceCount) <- calls script
          (lookups, executions, fenceCount) `shouldBe` (1, 0, 0)
          dumped (decisionToData decision) `shouldNotSatisfy` T.isInfixOf "SECRET"

  describe "test_fence_source_crash_malformed_answer_or_stale_proposal_remains_fail_closed" $
    -- "wrong-type": a fence source cannot return a non-fence here, so the
    -- malformed answer is a value that fails when forced.
    forM_
      [ ("raise", providerFailure "SECRET-fence-crash", DecisionIndeterminate, SafeToRetry)
      , ("wrong-type", pure (error "not-a-fence"), DecisionIndeterminate, SafeToRetry)
      , ("wrong-proposal", pure (fenceWith theProposal ("proposal_id", String "another-proposal")), DecisionSuperseded, Superseded)
      ]
      $ \(failure, answer, kind, recovery) ->
        it ("test_fence_source_crash_malformed_answer_or_stale_proposal_remains_fail_closed[" <> failure <> "-" <> T.unpack (decisionKindText kind) <> "-" <> T.unpack (dispositionText recovery) <> "]") $ do
          let p = theProposal
              f = fenceFor p
          (script, adapter) <- scripted [pure LookupSafeToRetry] []
          decision <- executeJson (effectGateway adapter (EffectFenceSource (const answer))) p ready (approvalOf p f)
          decision.kind `shouldBe` kind
          recoveryOf decision `shouldBe` Just recovery
          (lookups, executions, _) <- calls script
          (lookups, executions) `shouldBe` (1, 0)
          dumped (decisionToData decision) `shouldNotSatisfy` T.isInfixOf "SECRET"

  it "test_adapter_exceptions_and_raw_provider_evidence_are_digest_only" $ do
    let secret = "SECRET-raw-provider-canary"
        p = theProposal
        f = fenceFor p
        r = receiptFor p (Object [("raw", String secret)])
    (script, adapter) <- scripted [pure LookupSafeToRetry] [pure r]
    decision <- executeJson (effectGateway adapter (countingFences script (pure f))) p ready (approvalOf p f)
    decision.kind `shouldBe` DecisionExecute
    T.pack (show decision) `shouldNotSatisfy` T.isInfixOf secret
    dumped (decisionToData decision) `shouldNotSatisfy` T.isInfixOf secret

-- ---------------------------------------------------------------------------
-- Provider neutrality

neutralProposal :: Text -> TargetIdentity -> Text -> Json -> EffectProposal
neutralProposal effectType target authority payload =
  expectRight (mkEffectProposal "operation-42" effectType 1 (expectRight (digestPayloadJson payload)) target authority)

neutralFence :: EffectProposal -> EffectFence
neutralFence p = expectRight (mkEffectFence p.proposalId p.digest 7 "target-v3" "episode-5" "attachment-2" 1)

neutralReceipt :: EffectProposal -> Json -> EffectReceipt
neutralReceipt = receiptFor

payloadMember :: Text -> EffectPayload -> PayloadValue
payloadMember key (EffectPayload members) = Map.findWithDefault PNull key members

-- | An append-only message board with operation markers inside entries.
bulletinAdapter :: IORef [Text] -> IO (EffectAdapter, IO Int)
bulletinAdapter trace = do
  entries <- newIORef ([] :: [(Text, Text, Text, PayloadValue)])
  let lookupEntry p = do
        modifyIORef' trace (<> ["lookup"])
        found <- filter (\(_, operation, _, _) -> operation == p.proposalId) <$> readIORef entries
        pure $ case found of
          [] -> LookupSafeToRetry
          (entryId, _, digest, _) : _
            | digest /= p.payloadDigest -> LookupIndeterminate
            | otherwise -> LookupApplied (neutralReceipt p (Object [("entry", String entryId)]))
      executeEntry p payload _ = do
        modifyIORef' trace (<> ["execute"])
        n <- length <$> readIORef entries
        let entryId = "entry-" <> T.pack (show (n + 1))
        modifyIORef' entries (<> [(entryId, p.proposalId, p.payloadDigest, payloadMember "message" payload)])
        pure (neutralReceipt p (Object [("entry", String entryId)]))
  pure (EffectAdapter lookupEntry executeEntry, length <$> readIORef entries)

-- | A compare-and-swap deployment provider keyed by service and generation.
deploymentAdapter :: IORef [Text] -> IO (EffectAdapter, IORef (Map.Map Text (Text, Text, Integer, PayloadValue, PayloadValue)))
deploymentAdapter trace = do
  services <- newIORef Map.empty
  let lookupDeployment p = do
        modifyIORef' trace (<> ["lookup"])
        deployment <- Map.lookup p.target.targetId <$> readIORef services
        pure $ case deployment of
          Just (operation, digest, generation, _, _)
            | operation == p.proposalId ->
                if digest /= p.payloadDigest
                  then LookupIndeterminate
                  else LookupApplied (neutralReceipt p (Object [("generation", Int generation)]))
          _ -> LookupSafeToRetry
      executeDeployment p payload _ = do
        modifyIORef' trace (<> ["execute"])
        previous <- Map.lookup p.target.targetId <$> readIORef services
        let generation = maybe 0 (\(_, _, g, _, _) -> g) previous + 1
        modifyIORef' services
          (Map.insert p.target.targetId (p.proposalId, p.payloadDigest, generation, payloadMember "release" payload, payloadMember "regions" payload))
        pure (neutralReceipt p (Object [("generation", Int generation)]))
  pure (EffectAdapter lookupDeployment executeDeployment, services)

neutralitySpec :: Spec
neutralitySpec = do
  describe "test_two_provider_shapes_execute_once_and_replay_lookup_first" $ do
    let check :: Text -> (IORef [Text] -> IO (EffectAdapter, IO Int)) -> EffectProposal -> Json -> Spec
        check caseLabel build p payload =
          it ("test_two_provider_shapes_execute_once_and_replay_lookup_first[" <> T.unpack caseLabel <> "]") $ do
            trace <- newIORef []
            (adapter, effectCount) <- build trace
            let f = neutralFence p
                gateway = effectGateway adapter (EffectFenceSource (const (pure f)))
                approval = approvalOf p f
            executed <- executeJson gateway p payload approval
            replayed <- executeJson gateway p payload approval
            executed.kind `shouldBe` DecisionExecute
            replayed.kind `shouldBe` DecisionAlreadyApplied
            effectCount >>= (`shouldBe` 1)
            readIORef trace >>= (`shouldBe` ["lookup", "execute", "lookup"])
            forM_ [executed, replayed] $ \d -> do
              d.proposalId `shouldBe` p.proposalId
              d.proposalDigest `shouldBe` p.digest
              ((.payloadDigest) <$> d.evidence) `shouldBe` Just p.payloadDigest
              ((.target) <$> d.evidence) `shouldBe` Just p.target
        bulletinPayload = Object [("message", String "Version 1 is ready")]
        deploymentPayload =
          Object
            [ ("release", Object [("image", String "registry.invalid/app@sha256:abc")])
            , ("regions", Array [String "west", String "north"])
            ]
    check
      "BulletinAdapter-<lambda>-payload0-<lambda>"
      bulletinAdapter
      (neutralProposal "bulletin.publish" (expectRight (mkTargetIdentity "bulletin" "release-notes")) "communications.publish" bulletinPayload)
      bulletinPayload
    check
      "DeploymentAdapter-<lambda>-payload1-<lambda>"
      (\trace -> do (adapter, services) <- deploymentAdapter trace; pure (adapter, Map.size <$> readIORef services))
      (neutralProposal "deployment.rollout" (expectRight (mkTargetIdentity "service" "payments")) "deployment.production" deploymentPayload)
      deploymentPayload

  it "test_provider_side_compare_and_swap_race_resolves_superseded_without_second_effect" $ do
    let payload =
          Object
            [ ("release", Object [("image", String "registry.invalid/app@sha256:abc")])
            , ("regions", Array [String "west"])
            ]
        p = neutralProposal "deployment.rollout" (expectRight (mkTargetIdentity "service" "payments")) "deployment.production" payload
        f = neutralFence p
    trace <- newIORef []
    (base, services) <- deploymentAdapter trace
    raced <- newIORef False
    let racing =
          EffectAdapter
            { lookup = \candidate -> do
                hasRaced <- readIORef raced
                if hasRaced
                  then modifyIORef' trace (<> ["lookup"]) >> pure LookupSuperseded
                  else base.lookup candidate
            , execute = \_ _ _ -> do
                modifyIORef' trace (<> ["execute"])
                writeIORef raced True
                throwAgenticus RuntimeError "provider compare-and-swap rejected stale target head"
            }
    decision <- executeJson (effectGateway racing (EffectFenceSource (const (pure f)))) p payload (approvalOf p f)
    decision.kind `shouldBe` DecisionSuperseded
    readIORef trace >>= (`shouldBe` ["lookup", "execute", "lookup"])
    readIORef services >>= (`shouldBe` Map.empty)

-- ---------------------------------------------------------------------------
-- Golden vectors

goldenSpec :: Spec
goldenSpec = do
  it "digest_payload({\"message\": \"ready\"})" $ do
    canonicalPayload (payloadOf ready) `shouldBe` "{\"message\":\"ready\"}"
    digestPayloadJson ready `shouldBe` Right "sha256:50543babb442f1dc6879f51826e6e312d961860667eeb86c9a1fff542cc7e875"
  it "the test proposal's canonical bytes and digest" $ do
    canonicalBytes (proposalToData theProposal)
      `shouldBe` TE.encodeUtf8
        "{\"effect_type\":\"bulletin.publish\",\"effect_version\":1,\"payload_digest\":\"sha256:50543babb442f1dc6879f51826e6e312d961860667eeb86c9a1fff542cc7e875\",\"proposal_id\":\"proposal-7\",\"requested_authority_class\":\"bulletin.publish\",\"schema_version\":1,\"target\":{\"target_id\":\"release-notes\",\"target_type\":\"bulletin\"}}"
    theProposal.digest `shouldBe` "sha256:f1e336671ced6c810f32f34b25e5ce3733c2482eef2007753e2084c37a106318"
  it "non-ASCII stays raw UTF-8" $
    canonicalPayload (payloadOf (Object [("é", String "ü")])) `shouldBe` B.pack [0x7b, 0x22, 0xc3, 0xa9, 0x22, 0x3a, 0x22, 0xc3, 0xbc, 0x22, 0x7d]
  it "code and digest grammars" $ do
    map isCode ["a", "a1", "a.b-c_d9", "bulletin.publish"] `shouldBe` replicate 4 True
    map isCode ["", "A", "1a", "a.", "a..b", "a-", "a.B", "é"] `shouldBe` replicate 8 False
    isDigest ("sha256:" <> T.replicate 64 "a") `shouldBe` True
    map isDigest ["sha256:" <> T.replicate 64 "A", "sha256:" <> T.replicate 63 "a", "sha256:" <> T.replicate 65 "a", T.replicate 64 "a"]
      `shouldBe` replicate 4 False

-- ---------------------------------------------------------------------------
-- Differential corpus

field :: Text -> Json -> Json
field key value = maybe (error ("missing " <> T.unpack key)) id (lookupMember key value)

textField :: Text -> Json -> Text
textField key value = case field key value of
  String t -> t
  other -> error ("not text: " <> show other)

refusalOf :: AgenticusError -> Json
refusalOf e = Object [("class", String (errorClassName e.errorClass)), ("message", String e.errorMessage)]

-- | Each value type's decoder followed by its encoder.
decodeAs :: Text -> Json -> Either AgenticusError Json
decodeAs = \case
  "target" -> fmap targetToData . targetFromData
  "proposal" -> fmap proposalToData . proposalFromData
  "fence" -> fmap fenceToData . fenceFromData
  "receipt" -> fmap receiptToData . receiptFromData
  "lookup" -> fmap lookupToData . lookupFromData
  "evidence" -> fmap evidenceToData . evidenceFromData
  "decision" -> fmap decisionToData . decisionFromData
  other -> error ("unknown type " <> T.unpack other)

items :: Text -> Json -> [Json]
items key corpus = case field key corpus of
  Array xs -> xs
  _ -> error "not a list"

corpusSpec :: Spec
corpusSpec = do
  corpus <- runIO (loadJson "differential/effect_corpus.json")
  let golden = field "golden" corpus
  it "golden vectors match the reference" $ do
    digestPayloadJson ready `shouldBe` Right (textField "ready_digest" golden)
    proposalToData theProposal `shouldBe` field "proposal_data" golden
    TE.decodeUtf8 (canonicalBytes (proposalToData theProposal)) `shouldBe` textField "proposal_canonical" golden
    theProposal.digest `shouldBe` textField "proposal_digest" golden

  it "digest_payload: canonical bytes, digests and refusals" $
    forM_ (items "digests" corpus) $ \case_ -> do
      let payload = field "payload" case_
      case lookupMember "refusal" case_ of
        Just expected -> (refusalOf <$> either Just (const Nothing) (digestPayloadJson payload)) `shouldBe` Just expected
        Nothing -> do
          let strict = payloadOf payload
          TE.decodeUtf8 (canonicalPayload strict) `shouldBe` textField "canonical" case_
          digestPayload strict `shouldBe` textField "digest" case_

  it "EffectProposal.digest over generated proposals" $
    forM_ (items "proposal_digests" corpus) $ \case_ ->
      ((.digest) <$> proposalFromData (field "data" case_)) `shouldBe` Right (textField "digest" case_)

  it "from_data/to_data for every value type, mutation and cross-field shape" $
    forM_ (items "decode" corpus) $ \case_ -> do
      let outcome = decodeAs (textField "type" case_) (field "data" case_)
          observed = either (Left . refusalOf) (Right . dumped) outcome
          expected = case lookupMember "ok" case_ of
            Just (String bytes) -> Right bytes
            _ -> Left (field "refusal" case_)
      when (observed /= expected) $
        expectationFailure (show (textField "type" case_, dumped (field "data" case_), observed, expected))

  it "EffectGateway.execute over every reachable scripted path" $
    forM_ (items "gateway" corpus) $ \case_ -> do
      let (p, raw) = gatewayProposal (field "proposal" case_)
      trace <- newIORef []
      case lookupMember "refused" case_ of
        Just _ -> do
          let approval = expectRight (decisionFromData (field "approval" case_))
          outcome <- try (executeJson (scriptedGateway p (Object []) trace) p (field "payload" case_) approval)
          either (Just . refusalOf) (const Nothing) outcome `shouldBe` Just (field "refusal" case_)
        Nothing -> do
          decision <- executeJson (scriptedGateway p (field "steps" case_) trace) p raw (approvalOf p (fenceFor p))
          (case_, dumped (decisionToData decision)) `shouldBe` (case_, textField "decision" case_)
      observed <- readIORef trace
      Array (map String observed) `shouldBe` field "calls" case_

gatewayProposal :: Json -> (EffectProposal, Json)
gatewayProposal = \case
  Int 0 -> (theProposal, ready)
  Int 1 ->
    let payload =
          Object [("message", String "pronto 😀"), ("regions", Array [String "west", String "north"]), ("n", Int (10 ^ (20 :: Int)))]
     in ( expectRight
            ( mkEffectProposal
                "operação-42"
                "deployment.rollout"
                (10 ^ (12 :: Int))
                (expectRight (digestPayloadJson payload))
                (expectRight (mkTargetIdentity "service" "pagamentos-é"))
                "deployment.production"
            )
        , payload
        )
  other -> error ("unknown proposal " <> show other)

-- | The generator's @Script@: one adapter and fence source answering from
-- named steps and recording the provider call trace.
scriptedGateway :: EffectProposal -> Json -> IORef [Text] -> EffectGateway
scriptedGateway p steps trace =
  effectGateway
    EffectAdapter {lookup = lookupStep, execute = executeStep}
    (EffectFenceSource fenceStep)
  where
    step key = maybe "" (\case String t -> t; _ -> "") (lookupMember key steps)
    record name = modifyIORef' trace (<> [name])
    lookupStep _ = do
      earlier <- readIORef trace
      record "lookup"
      let name = step (if "lookup" `elem` earlier then "lookup2" else "lookup1")
      case name of
        "raise" -> providerFailure "SECRET-lookup-crash"
        "applied" -> pure (LookupApplied (defaultReceipt p))
        "applied-wrong" -> pure (LookupApplied (withProposalId "another-proposal" (defaultReceipt p)))
        "safe-to-retry" -> pure LookupSafeToRetry
        "superseded" -> pure LookupSuperseded
        "indeterminate" -> pure LookupIndeterminate
        other -> error ("unknown lookup step " <> T.unpack other)
    fenceStep _ = do
      record "current"
      case step "fence" of
        "raise" -> providerFailure "SECRET-fence-crash"
        "stale-authority" -> pure (fenceWith p ("authority_epoch", Int 5))
        "stale-head" -> pure (fenceWith p ("target_head", String "revision-12"))
        "wrong-proposal" -> pure (fenceWith p ("proposal_id", String "another-proposal"))
        _ -> pure (fenceFor p)
    executeStep _ payload _ = do
      record "execute"
      case step "execute" of
        "raise" -> throwAgenticus TimeoutError "SECRET-response-lost"
        "receipt-wrong" -> pure (withProposalId "another-proposal" (defaultReceipt p))
        _ -> pure (receiptFor p (Object [("executed", payloadToJson payload)]))

-- ---------------------------------------------------------------------------
-- Local assertion helpers

shouldRaiseMatching' :: (Show a) => Either AgenticusError a -> (ErrorClass, Text) -> Expectation
shouldRaiseMatching' outcome (cls, needle) = shouldRaiseMatching outcome cls needle

shouldRaiseMatchingIO :: IO a -> (ErrorClass, Text) -> Expectation
shouldRaiseMatchingIO action (cls, needle) = do
  outcome <- try action
  case outcome of
    Left e -> do
      e `shouldSatisfy` (`isInstanceOf` cls)
      e.errorMessage `shouldSatisfy` T.isInfixOf needle
    Right _ -> expectationFailure ("expected " <> show cls)
