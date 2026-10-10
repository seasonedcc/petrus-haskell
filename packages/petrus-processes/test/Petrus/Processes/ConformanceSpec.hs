-- | spec/processes-conformance.md, the unit and database checks (P-001 …
-- P-031, P-039 … P-074), each written once against the conformance protocol
-- and run against both the Haskell port and the pinned Python reference.
-- The engine checks are in "Petrus.Processes.DemoSpec", the interop checks
-- in "Petrus.Processes.InteropSpec".
module Petrus.Processes.ConformanceSpec
  ( spec
  , haskell
  , specArgs
  , spec15
  , child1
  , dataArgs
  , spawnInvocation
  , requestData
  ) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (forM_, void)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Fabric.Conformance.Haskell (fabricOps)
import Petrus.Fabric.Conformance.Impl
import Petrus.Fabric.Conformance.Setup
import Petrus.Fabric.Error (Category (..), categoryText)
import Petrus.Json (Json (..), typeExactEq)
import Petrus.Postgres (textParam)
import Petrus.Processes.Conformance.Haskell (processOps)
import Petrus.TestSupport (PostgresTarget (..))
import Test.Hspec

-- | The Haskell port (Fabric and processes operations) behind the protocol.
haskell :: Launcher
haskell = haskellLauncher (\h -> [fabricOps h, processOps h])

spec :: Spec
spec = describe "Process lifecycle conformance (spec/processes-conformance.md)" $ do
  describe "Haskell port" (checks haskell)
  describe "Python reference" (checks pythonLauncher)

checks :: Launcher -> Spec
checks l = do
  unitGroup l unitChecks
  dbGroup l dbChecks

-- ---------------------------------------------------------------------------
-- Fixtures

shouldBeJson :: Json -> Json -> Expectation
shouldBeJson actual expected =
  if typeExactEq actual expected
    then pure ()
    else expectationFailure ("expected " <> showJson expected <> "\n but got " <> showJson actual)

-- | test_processes' @spec(...)@ arguments.
specArgs :: [(Text, Json)] -> [(Text, Json)]
specArgs overrides = withArgs base overrides
  where
    parent = maybe "parent" id (lookup "parent" overrides)
    base =
      [ ("parent", parent)
      , ("spawn_id", "spawn-1")
      , ("process_kind", "analysis-agent")
      , ("source", "calls")
      , ("capabilities", js "{\"protocol\":\"call-v1\",\"features\":[\"reply\"]}")
      , ("config", js "{\"model\":\"deterministic\",\"tools\":[\"read\"]}")
      , ("reply_route", Array [parent, "replies"])
      ]

-- | The §15 worked example's spec.
spec15 :: [(Text, Json)]
spec15 =
  [ ("parent", "parent")
  , ("spawn_id", "spawn-1")
  , ("process_kind", "analysis-agent")
  , ("source", "calls")
  , ("capabilities", js "{\"protocol\":\"call-v1\"}")
  , ("config", js "{\"role\":\"agent\"}")
  , ("reply_route", Array ["parent", "replies"])
  ]

child1 :: Text
child1 = "process-v1-d2404af783c2bf50f6456e89c63e58067a6205fb5e23d3de79a411921c64ecad"

specData :: Impl -> [(Text, Json)] -> IO Json
specData i overrides = member "data" <$> ok i "spawn_spec" (specArgs overrides)

requestData :: Impl -> Text -> Json -> IO Json
requestData i callId input = ok i "call_request" [("call_id", String callId), ("operation", "answer"), ("input", input)]

-- | A request envelope's data: sender, recipient, source, reply route.
requestFrom :: Impl -> Text -> Text -> Text -> IO Json
requestFrom i sender recipient callId = do
  request <- requestData i callId (js "{\"question\":42}")
  ok i "request_envelope" [("request", request), ("sender", String sender), ("recipient", String recipient), ("source", "calls"), ("reply_route", Array [String sender, "replies"])]

-- | test_processes' @call_request()@ envelope data.
callRequestEnvelope :: Impl -> IO Json
callRequestEnvelope i = member "data" <$> requestFrom i "parent" "child" "call-1"

resultFor :: Impl -> Json -> Text -> Text -> Json -> [(Text, Json)] -> IO Answer
resultFor i request sender callId result extra = do
  value <- ok i "call_result" [("call_id", String callId), ("result", result)]
  answerOf i "result_envelope" ([("request", request), ("result", value), ("sender", String sender)] <> extra)

errorFor :: Impl -> Json -> Text -> Text -> [(Text, Json)] -> IO Answer
errorFor i request sender callId extra = do
  value <- ok i "call_error" [("call_id", String callId), ("code", "delegated-refusal"), ("message", "child refused delegated work")]
  answerOf i "error_envelope" ([("request", request), ("error", value), ("sender", String sender)] <> extra)

okAnswer :: Answer -> IO Json
okAnswer = \case
  Ok v -> pure v
  other -> expectationFailure ("expected a value, got " <> show other) >> pure Null

refusedAnswer :: Category -> Text -> Answer -> Expectation
refusedAnswer category fragment = \case
  Err c _ message | c == category && (fragment `T.isInfixOf` message || T.null message) -> pure ()
  other -> expectationFailure ("expected " <> show (categoryText category) <> " containing " <> show fragment <> ", got " <> show other)

-- | An envelope data value built directly (fabric "envelope").
rawEnvelope :: Impl -> [(Text, Json)] -> IO Json
rawEnvelope i fields = member "data" <$> ok i "envelope" fields

replyAnswer :: Impl -> Json -> Json -> IO Answer
replyAnswer i e request = answerOf i "reply_from_envelope" [("envelope", e), ("request", request)]

spawnInvocation :: Impl -> [(Text, Json)] -> IO Json
spawnInvocation i overrides = do
  value <- ok i "spawn_spec" overrides
  let d = member "data" value
  idempotency <- ok i "spawn_idempotency" [("parent", member "parent" d), ("spawn_id", member "spawn_id" d)]
  pure (obj [("activity", "process.spawn"), ("input", d), ("idempotency", idempotency)])

attemptsOf :: Json -> [Json]
attemptsOf value = case member "attempts" value of
  Array xs -> xs
  _ -> []

arrayOf :: Json -> [Json]
arrayOf = \case
  Array xs -> xs
  _ -> []

attemptError :: Json -> Text
attemptError attempt = memberText "message" (member "error" attempt)

-- ---------------------------------------------------------------------------
-- A … G: values and the Activity

unitChecks :: SpecWith Impl
unitChecks = do
  describe "A Call payloads" $ do
    it "P-001 a CallRequest encodes exactly and round-trips" $ \i -> do
      d <- requestData i "call-1" (js "{\"nested\":[1]}")
      showJson d `shouldBe` "{\"version\":1,\"kind\":\"process.call.request\",\"call_id\":\"call-1\",\"operation\":\"answer\",\"input\":{\"nested\":[1]}}"
      ok i "call_request_from_data" [("data", d)] >>= (`shouldBeJson` d)
    it "P-002 input is detached and must be an object" $ \i -> do
      answer <- ok i "call_request_detached" []
      member "input" answer `shouldBeJson` js "{\"nested\":[1]}"
      member "mutable" answer `shouldBeJson` Bool False
      forM_ [Array [], String "x", Null] $ \bad ->
        refused Invalid i "call_request" [("call_id", "call-1"), ("operation", "answer"), ("input", bad)]
    it "P-003 request decoding is exact" $ \i -> do
      d <- requestData i "call-1" (js "{}")
      refusedWith Invalid "exact version-1" i "call_request_from_data" [("data", setMember "provider" "claude" d)]
      void (refused Invalid i "call_request_from_data" [("data", dropMember "operation" d)])
      forM_ [Int 2, Float 1, Bool True] $ \v -> refused Invalid i "call_request_from_data" [("data", setMember "version" v d)]
      void (refused Invalid i "call_request_from_data" [("data", setMember "kind" "process.call.result" d)])
    it "P-004 any strict JSON result round-trips" $ \i -> do
      forM_ [js "[1,{\"ok\":true}]", Null, Int 3, String "s", Float 1.5, Bool True, js "{\"answer\":42}"] $ \result -> do
        d <- ok i "call_result" [("call_id", "call-1"), ("result", result)]
        member "result" d `shouldBeJson` result
        ok i "call_result_from_data" [("data", d)] >>= (`shouldBeJson` d)
      refusedWith Invalid "strict JSON" i "call_result" [("call_id", "call-1"), ("result", Float (1 / 0))]
    it "P-005 CallError details default to null and are always emitted" $ \i -> do
      bare <- ok i "call_error" [("call_id", "call-1"), ("code", "refused"), ("message", "no")]
      member "details" bare `shouldBeJson` Null
      full <- ok i "call_error" [("call_id", "call-1"), ("code", "refused"), ("message", "no"), ("details", js "{\"retry\":false}")]
      ok i "call_error_from_data" [("data", full)] >>= (`shouldBeJson` full)
      forM_ [("code", ""), ("code", Int 3), ("message", ""), ("message", Bool True)] $ \(k, v) ->
        refused Invalid i "call_error" (withArgs [("call_id", "call-1"), ("code", "refused"), ("message", "no")] [(k, v)])
    it "P-006 kinds are exact and each decoder refuses the others" $ \i -> do
      request <- requestData i "call-1" (js "{}")
      result <- ok i "call_result" [("call_id", "call-1"), ("result", Null)]
      failure <- ok i "call_error" [("call_id", "call-1"), ("code", "c"), ("message", "m")]
      map (memberText "kind") [request, result, failure] `shouldBe` ["process.call.request", "process.call.result", "process.call.error"]
      forM_ [("call_request_from_data", [result, failure]), ("call_result_from_data", [request, failure]), ("call_error_from_data", [request, result])] $ \(op, others) ->
        forM_ others $ \other -> refused Invalid i op [("data", other)]

  describe "B Call envelopes and identities" $ do
    it "P-007 the default request delivery id" $ \i -> do
      forM_
        [ ("call-1", "process-call-v1-request-5d7963c4f471e142f5a72214a9666fb164718f9ba1066a7862ac1c5041887940")
        , ("c-é", "process-call-v1-request-5024ad417352781fc1bbf47e59357db7908dd4f9607f6eac499c85323e237a5f")
        ]
        $ \(callId, expected) -> do
          e <- requestFrom i "caller" "callee" callId
          memberText "delivery_id" (member "data" e) `shouldBe` expected
    it "P-008 a request is correlated by call id and replies to its sender" $ \i -> do
      e <- callRequestEnvelope i
      memberText "correlation" e `shouldBe` "call-1"
      request <- requestData i "call-1" (js "{}")
      refusedWith Invalid "belong to the sender" i "request_envelope" [("request", request), ("sender", "parent"), ("recipient", "child"), ("source", "calls"), ("reply_route", Array ["other", "replies"])]
    it "P-009 the §8 request digest" $ \i -> do
      e <- requestFrom i "caller" "callee" "call-1"
      memberText "digest" e `shouldBe` "e838ab15859a2bcadbb3d2c17fe2fcf8a7b0a5e62a0dcf3b8e2b969b1120990e"
    it "P-010 the default reply delivery id" $ \i -> do
      request <- member "data" <$> requestFrom i "caller" "callee" "call-1"
      e <- resultFor i request "callee" "call-1" (js "{\"answer\":42}") [] >>= okAnswer
      memberText "delivery_id" (member "data" e) `shouldBe` "process-call-v1-reply-cc2a24e1ad965ab6d3ed917d5d448e43f5246556a710a74a57ee205ade2e2b6c"
      accented <- member "data" <$> requestFrom i "é" "callee" "c-é"
      r <- resultFor i accented "callee" "c-é" Null [] >>= okAnswer
      memberText "delivery_id" (member "data" r) `shouldBe` "process-call-v1-reply-58993fa106ffeef14b0dbb8c0f753da1e4c4005f60905ef78a5fb28b18f02e6f"
    it "P-011 the result envelope's addressing and the §8 digest" $ \i -> do
      request <- member "data" <$> requestFrom i "caller" "callee" "call-1"
      e <- resultFor i request "callee" "call-1" (js "{\"answer\":42}") [] >>= okAnswer
      memberText "canonical" e
        `shouldBe` "{\"correlation\":\"call-1\",\"delivery_id\":\"process-call-v1-reply-cc2a24e1ad965ab6d3ed917d5d448e43f5246556a710a74a57ee205ade2e2b6c\",\"payload\":{\"call_id\":\"call-1\",\"kind\":\"process.call.result\",\"result\":{\"answer\":42},\"version\":1},\"recipient\":\"caller\",\"reply_route\":null,\"sender\":\"callee\",\"source\":\"replies\",\"version\":1}"
      memberText "digest" e `shouldBe` "df7373fce36bfb17631813b24e8eda8885fed4f4b3510d18ac8cd66c54054b6f"
      fixture <- callRequestEnvelope i
      r <- resultFor i fixture "child" "call-1" Null [] >>= okAnswer
      (memberText "recipient" (member "data" r), memberText "source" (member "data" r)) `shouldBe` ("parent", "replies")
      member "reply_route" (member "data" r) `shouldBeJson` Null
    it "P-012 result and error share a delivery id; the §8 error digest" $ \i -> do
      request <- member "data" <$> requestFrom i "caller" "callee" "call-1"
      r <- resultFor i request "callee" "call-1" (js "{\"answer\":42}") [] >>= okAnswer
      e <- errorFor i request "callee" "call-1" [] >>= okAnswer
      memberText "delivery_id" (member "data" e) `shouldBe` memberText "delivery_id" (member "data" r)
      memberText "digest" e `shouldNotBe` memberText "digest" r
      memberText "digest" e `shouldBe` "a92c1070ced3ce5f8fab94c9b774cd3924a4d369fa506fb51fe9a93f6fbecd22"
    it "P-013 a result for another call id is refused" $ \i -> do
      request <- callRequestEnvelope i
      resultFor i request "child" "other" Null [] >>= refusedAnswer Invalid "correlate"
    it "P-014 a result from someone other than the callee is refused" $ \i -> do
      request <- callRequestEnvelope i
      resultFor i request "other-child" "call-1" Null [] >>= refusedAnswer Invalid "correlate"
    it "P-015 a result for a malformed request is refused" $ \i -> do
      request <- callRequestEnvelope i
      malformed <- rawEnvelope i (dataArgs (setMember "correlation" "other" request))
      resultFor i malformed "child" "other" Null [] >>= refusedAnswer Invalid "correlation"
    it "P-016 an explicit delivery id overrides each default" $ \i -> do
      request <- requestData i "call-1" (js "{}")
      e <- ok i "request_envelope" [("request", request), ("sender", "parent"), ("recipient", "child"), ("source", "calls"), ("reply_route", Array ["parent", "replies"]), ("delivery_id", "custom-request")]
      memberText "delivery_id" (member "data" e) `shouldBe` "custom-request"
      fixture <- callRequestEnvelope i
      r <- resultFor i fixture "child" "call-1" Null [("delivery_id", "custom-result")] >>= okAnswer
      memberText "delivery_id" (member "data" r) `shouldBe` "custom-result"
      f <- errorFor i fixture "child" "call-1" [("delivery_id", "custom-error")] >>= okAnswer
      memberText "delivery_id" (member "data" f) `shouldBe` "custom-error"

  describe "C Call validation" $ do
    it "P-017 a request whose correlation differs from its call id is refused" $ \i -> do
      request <- callRequestEnvelope i
      refused Invalid i "request_from_envelope" [("envelope", setMember "correlation" "other" request)] >>= \_ -> pure ()
      ok i "request_from_envelope" [("envelope", request)] >>= (`shouldBeJson` member "payload" request)
    it "P-018 a request without a reply route is refused" $ \i -> do
      request <- callRequestEnvelope i
      void (refused Invalid i "request_from_envelope" [("envelope", setMember "reply_route" Null request)])
    it "P-019 a request replying to someone else is refused" $ \i -> do
      request <- callRequestEnvelope i
      void (refused Invalid i "request_from_envelope" [("envelope", setMember "reply_route" (obj [("instance_id", "other"), ("source", "replies")]) request)])
    it "P-020 valid replies decode to results and errors" $ \i -> do
      request <- callRequestEnvelope i
      r <- resultFor i request "child" "call-1" (js "{\"answer\":42}") [] >>= okAnswer
      e <- errorFor i request "child" "call-1" [] >>= okAnswer
      decodedResult <- replyAnswer i (member "data" r) request >>= okAnswer
      memberText "kind" decodedResult `shouldBe` "result"
      member "result" (member "data" decodedResult) `shouldBeJson` js "{\"answer\":42}"
      decodedError <- replyAnswer i (member "data" e) request >>= okAnswer
      memberText "kind" decodedError `shouldBe` "error"
      memberText "message" (member "data" decodedError) `shouldBe` "child refused delegated work"
    describe "reply refusals" $ do
      let base i = do
            request <- callRequestEnvelope i
            r <- resultFor i request "child" "call-1" Null [] >>= okAnswer
            pure (request, member "data" r)
      it "P-021 a reply payload of another kind is refused" $ \i -> do
        (request, r) <- base i
        replyAnswer i (setMember "payload" (member "payload" request) r) request >>= refusedAnswer Invalid ""
      it "P-022 a reply whose correlation differs from its payload is refused" $ \i -> do
        (request, r) <- base i
        replyAnswer i (setMember "correlation" "other" r) request >>= refusedAnswer Invalid "correlation"
      it "P-023 a reply for another call id is refused" $ \i -> do
        (request, r) <- base i
        other <- ok i "call_result" [("call_id", "call-2"), ("result", Null)]
        replyAnswer i (setMember "payload" other (setMember "correlation" "call-2" r)) request >>= refusedAnswer Invalid ""
      it "P-024 a reply from a sibling is refused" $ \i -> do
        (request, r) <- base i
        replyAnswer i (setMember "sender" "sibling" r) request >>= refusedAnswer Invalid "request callee"
      it "P-025 a reply to another recipient or on another source is refused" $ \i -> do
        (request, r) <- base i
        replyAnswer i (setMember "recipient" "other" r) request >>= refusedAnswer Invalid ""
        replyAnswer i (setMember "source" "elsewhere" r) request >>= refusedAnswer Invalid ""
      it "P-026 a reply carrying a reply route is refused" $ \i -> do
        (request, r) <- base i
        replyAnswer i (setMember "reply_route" (obj [("instance_id", "child"), ("source", "x")]) r) request >>= refusedAnswer Invalid ""
      it "P-027 a custom reply delivery id is not checked" $ \i -> do
        (request, r) <- base i
        decoded <- replyAnswer i (setMember "delivery_id" "anything-custom" r) request >>= okAnswer
        memberText "kind" decoded `shouldBe` "result"

  describe "F Spawn values" $ do
    it "P-039 SpawnSpec JSON is exact, round-trips and is detached" $ \i -> do
      value <- ok i "spawn_spec" (specArgs [])
      let d = member "data" value
      Set.fromList (keysOf d) `shouldBe` Set.fromList ["version", "parent", "spawn_id", "process_kind", "source", "capabilities", "config", "reply_route"]
      member "version" d `shouldBeJson` Int 1
      back <- ok i "spawn_spec_from_data" [("data", d)]
      member "data" back `shouldBeJson` d
      memberText "digest" back `shouldBe` memberText "digest" value
      detached <- ok i "spawn_spec_detached" [("spec", obj (specArgs []))]
      member "config" detached `shouldBeJson` js "{\"nested\":[1]}"
      member "mutable" detached `shouldBeJson` Bool False
    it "P-040 the digest covers every member" $ \i -> do
      original <- memberText "digest" <$> ok i "spawn_spec" (specArgs [])
      forM_
        [ [("config", js "{\"nested\":[2]}")]
        , [("source", "other")]
        , [("capabilities", js "{\"protocol\":\"call-v2\"}")]
        , [("process_kind", "other-kind")]
        , [("reply_route", Null)]
        ]
        $ \changes -> (memberText "digest" <$> ok i "spawn_spec" (specArgs changes)) >>= (`shouldNotBe` original)
    it "P-041 an extra member is refused" $ \i -> do
      d <- specData i []
      refusedWith Invalid "exact version-1" i "spawn_spec_from_data" [("data", setMember "credential" "forbidden-field" d)]
    it "P-042 a NaN in config is refused" $ \i ->
      refusedWith Invalid "strict JSON" i "spawn_spec" (specArgs [("config", obj [("bad", Float (0 / 0))])])
    it "P-043 a reply route owned by someone else is refused" $ \i ->
      refusedWith Invalid "belong to the parent" i "spawn_spec" (specArgs [("reply_route", Array ["someone-else", "replies"])])
    it "P-044 capabilities and config are objects; version is integer 1" $ \i -> do
      forM_ [("capabilities", Array []), ("config", Array []), ("config", Null)] $ \(k, v) ->
        refused Invalid i "spawn_spec" (specArgs [(k, v)])
      d <- specData i []
      forM_ [Int 2, Float 1, Bool True] $ \v -> refused Invalid i "spawn_spec_from_data" [("data", setMember "version" v d)]
    it "P-045 the §15 canonical bytes and digest" $ \i -> do
      value <- ok i "spawn_spec" spec15
      memberText "canonical" value
        `shouldBe` "{\"capabilities\":{\"protocol\":\"call-v1\"},\"config\":{\"role\":\"agent\"},\"parent\":\"parent\",\"process_kind\":\"analysis-agent\",\"reply_route\":{\"instance_id\":\"parent\",\"source\":\"replies\"},\"source\":\"calls\",\"spawn_id\":\"spawn-1\",\"version\":1}"
      memberText "digest" value `shouldBe` "8b6ffab905673be4a0de33b1ea8b3c9e3715412694f21fa6051633fd63cea3c2"
      memberText "child" value `shouldBe` child1
    it "P-046 child identity vectors" $ \i -> do
      ok i "child_identity" [("parent", "parent"), ("spawn_id", "spawn-1")] >>= (`shouldBeJson` String child1)
      ok i "child_identity" [("parent", "pai/é"), ("spawn_id", "spawn\n\x1F600")]
        >>= (`shouldBeJson` String "process-v1-46c4213496ebb26fcfad46ad7d181d60377de58df89d012d08235b2c94e6df64")
    it "P-047 the child identity is parent-scoped, not spec-scoped" $ \i -> do
      base <- memberText "child" <$> ok i "spawn_spec" (specArgs [])
      other <- memberText "child" <$> ok i "spawn_spec" (specArgs [("process_kind", "other")])
      other `shouldBe` base
      ok i "child_identity" [("parent", "parent-2"), ("spawn_id", "spawn-1")] >>= (`shouldNotBe` String base)
      ok i "child_identity" [("parent", "parent"), ("spawn_id", "spawn-2")] >>= (`shouldNotBe` String base)
      T.isPrefixOf "process-v1-" base `shouldBe` True
      T.length base `shouldBe` 75
    it "P-048 spawn idempotency" $ \i ->
      ok i "spawn_idempotency" [("parent", "parent"), ("spawn_id", "spawn-1")] >>= (`shouldBeJson` String ("process.spawn:" <> child1))
    it "P-049 SpawnOutcome is exact and identity-checked" $ \i -> do
      let ep = obj [("recipient", String child1), ("source", "calls"), ("capabilities", js "{\"protocol\":\"call-v1\"}")]
          args = [("parent", "parent"), ("spawn_id", "spawn-1"), ("child", String child1), ("endpoint", ep), ("prior_claim", Bool False)]
      d <- ok i "spawn_outcome" args
      ok i "spawn_outcome_from_data" [("data", d)] >>= (`shouldBeJson` d)
      refusedWith Invalid "exact version-1" i "spawn_outcome_from_data" [("data", setMember "credential" "not-public" d)]
      void (refused Invalid i "spawn_outcome_from_data" [("data", setMember "prior_claim" (Int 1) d)])
      refusedWith Invalid "address the child" i "spawn_outcome" (withArgs args [("endpoint", setMember "recipient" "wrong" ep)])
      void (refused Invalid i "spawn_outcome" (withArgs args [("child", "wrong")]))
    it "P-050 Provisioning, SpawnClaim and Lineage are parent-scoped" $ \i -> do
      let ep = obj [("recipient", String child1), ("source", "calls"), ("capabilities", obj [])]
          prov = [("parent", "parent"), ("spawn_id", "spawn-1"), ("child", String child1), ("process_kind", "analysis-agent"), ("endpoint", ep), ("config", obj []), ("reply_route", Array ["parent", "replies"])]
      made <- ok i "provisioning" prov
      memberText "child" made `shouldBe` child1
      refusedWith Invalid "parent-scoped" i "provisioning" (withArgs prov [("child", "wrong"), ("endpoint", setMember "recipient" "wrong" ep)])
      void (refused Invalid i "provisioning" (withArgs prov [("endpoint", setMember "recipient" "wrong" ep)]))
      refusedWith Invalid "parent-scoped" i "spawn_claim" [("parent", "parent"), ("spawn_id", "spawn-1"), ("child", "wrong"), ("prior_claim", Bool False)]
      refusedWith Invalid "parent-scoped" i "lineage" [("parent", "parent"), ("spawn_id", "spawn-1"), ("child", "wrong")]
      ok i "lineage" [("parent", "parent"), ("spawn_id", "spawn-1"), ("child", String child1)] >>= (`shouldBeJson` Array ["parent", "spawn-1", String child1])

  describe "G The process.spawn Activity" $ do
    let fake i invocation registry provisioner times =
          ok i "fake_spawn" [("invocation", invocation), ("registry", registry), ("provisioner", provisioner), ("times", Int times)]
    it "P-051 another activity name is refused" $ \i -> do
      d <- specData i []
      answer <- fake i (obj [("activity", "other"), ("input", d)]) "memory" "record" 1
      map attemptError (attemptsOf answer) `shouldSatisfy` all (T.isInfixOf "only implements")
    it "P-052 a wrong idempotency is refused" $ \i -> do
      d <- specData i []
      answer <- fake i (obj [("activity", "process.spawn"), ("input", d), ("idempotency", "wrong")]) "memory" "record" 1
      map attemptError (attemptsOf answer) `shouldSatisfy` all (T.isInfixOf "idempotency")
    it "P-053 a claim for another identity is refused before provisioning" $ \i -> do
      invocation <- spawnInvocation i (specArgs [])
      answer <- fake i invocation "wrong" "record" 1
      map attemptError (attemptsOf answer) `shouldSatisfy` all (T.isInfixOf "different identity")
      member "events" answer `shouldBeJson` Array ["claim"]
      member "provisionings" answer `shouldBeJson` Array []
    it "P-054 claim precedes ensure, and an exact retry re-ensures" $ \i -> do
      invocation <- spawnInvocation i (specArgs [])
      answer <- fake i invocation "memory" "record" 2
      member "events" answer `shouldBeJson` Array ["claim", "ensure", "claim", "ensure"]
      let outcomes = map (member "ok") (attemptsOf answer)
      map (member "prior_claim") outcomes `shouldSatisfy` \ps -> length ps == 2 && and (zipWith typeExactEq ps [Bool False, Bool True])
      map (memberText "child") outcomes `shouldBe` [child1, child1]
    it "P-055 a provisioner returning a value is refused" $ \i -> do
      invocation <- spawnInvocation i (specArgs [])
      answer <- answerOf i "fake_spawn" [("invocation", invocation), ("registry", "memory"), ("provisioner", "live"), ("times", Int 1)]
      if i.isHaskell
        then refusedAnswer Invalid "type-enforced" answer
        else do
          value <- okAnswer answer
          map attemptError (attemptsOf value) `shouldSatisfy` all (T.isInfixOf "never a live host or credential")
    it "P-056 the provisioner receives the endpoint, config and route, never a credential" $ \i -> do
      invocation <- spawnInvocation i (specArgs [])
      answer <- fake i invocation "memory" "record" 1
      case arrayOf (member "provisionings" answer) of
        [p] -> do
          member "has_credential" p `shouldBeJson` Bool False
          member "endpoint" p `shouldBeJson` obj [("recipient", String child1), ("source", "calls"), ("capabilities", js "{\"protocol\":\"call-v1\",\"features\":[\"reply\"]}")]
          member "config" p `shouldBeJson` js "{\"model\":\"deterministic\",\"tools\":[\"read\"]}"
          member "reply_route" p `shouldBeJson` obj [("instance_id", "parent"), ("source", "replies")]
        other -> expectationFailure (show other)
    it "P-058 the first outcome is the §15 bytes; the retry differs only in prior_claim" $ \i -> do
      invocation <- spawnInvocation i spec15
      answer <- fake i invocation "memory" "record" 2
      let expected prior =
            "{\"version\":1,\"parent\":\"parent\",\"spawn_id\":\"spawn-1\",\"child\":\"" <> T.unpack child1 <> "\",\"endpoint\":{\"recipient\":\""
              <> T.unpack child1
              <> "\",\"source\":\"calls\",\"capabilities\":{\"protocol\":\"call-v1\"}},\"prior_claim\":"
              <> prior
              <> "}"
      map (showJson . member "ok") (attemptsOf answer) `shouldBe` [expected "false", expected "true"]

-- | Envelope data as the fabric "envelope" operation's arguments.
dataArgs :: Json -> [(Text, Json)]
dataArgs d =
  [ (k, if k == "reply_route" then routeArg v else v)
  | (k, v) <- case d of
      Object ms -> ms
      _ -> []
  , k /= "version"
  ]
  where
    routeArg = \case
      Object ms -> Array [maybe Null id (lookup "instance_id" ms), maybe Null id (lookup "source" ms)]
      other -> other

textOf :: Json -> Text
textOf = \case
  String t -> t
  other -> T.pack (show other)

keysOf :: Json -> [Text]
keysOf = \case
  Object ms -> map fst ms
  _ -> []

setMember :: Text -> Json -> Json -> Json
setMember key value = \case
  Object ms -> Object ([(k, v) | (k, v) <- ms, k /= key] <> [(key, value)])
  other -> other

dropMember :: Text -> Json -> Json
dropMember key = \case
  Object ms -> Object [(k, v) | (k, v) <- ms, k /= key]
  other -> other

-- ---------------------------------------------------------------------------
-- D, G, H, I: against PostgreSQL

-- | test_processes' @lifecycle@ fixture: both schemas, parent registered,
-- its registry.
data Lifecycle = Lifecycle {env :: Env, credential :: Text, registry :: Json}

withLifecycle :: Ctx -> (Lifecycle -> IO a) -> IO a
withLifecycle ctx k = withEnv ctx $ \env -> do
  _ <- ok ctx.impl "ensure_lifecycle_schema" [("conn", env.conn)]
  credential <- issued ctx
  _ <- ok ctx.impl "register" [("conn", env.conn), ("instance", "parent"), ("credential", String credential)]
  registry <- ok ctx.impl "registry" [("conn", env.conn), ("parent", "parent"), ("credential", String credential)]
  k (Lifecycle env credential registry)

issued :: Ctx -> IO Text
issued ctx =
  ok ctx.impl "issue_credential" [] >>= \case
    String c -> pure c
    other -> expectationFailure (showJson other) >> pure ""

registered :: Ctx -> Env -> Text -> IO Json
registered ctx env name = do
  credential <- issued ctx
  _ <- ok ctx.impl "register" [("conn", env.conn), ("instance", String name), ("credential", String credential)]
  ok ctx.impl "client" [("conn", env.conn), ("instance", String name), ("credential", String credential)]

submitData :: Ctx -> Json -> Json -> IO Answer
submitData ctx client e = answerOf ctx.impl "submit" [("client", client), ("envelope", obj (dataArgs e))]

dsnOf :: Ctx -> Json
dsnOf ctx = String (TE.decodeUtf8 ctx.target.targetUrl)

lifecycleNamespaces :: Env -> IO Int
lifecycleNamespaces env = count env.admin "SELECT count(*) FROM pg_namespace WHERE nspname = 'impetus_lifecycle'" []

dbChecks :: SpecWith Ctx
dbChecks = do
  describe "D Call identity over Fabric (test_processes::test_call_result_and_error_share_fabric_conflict_identity)" $ do
    let setup ctx env = do
          caller <- registered ctx env "caller"
          callee <- registered ctx env "callee"
          second <- registered ctx env "second-caller"
          forM_ [caller, second] $ \c -> do
            _ <- ok ctx.impl "expose" [("client", c), ("source", "replies")]
            ok ctx.impl "grant" [("client", c), ("sender", "callee"), ("source", "replies")]
          _ <- ok ctx.impl "expose" [("client", callee), ("source", "calls")]
          forM_ ["caller", "second-caller"] $ \s -> ok ctx.impl "grant" [("client", callee), ("sender", s), ("source", "calls")]
          pure (caller, callee, second)
        terminal ctx sender = do
          request <- requestData ctx.impl "terminal-call" (obj [])
          member "data" <$> ok ctx.impl "request_envelope" [("request", request), ("sender", String sender), ("recipient", "callee"), ("source", "calls"), ("reply_route", Array [String sender, "replies"])]
    it "P-028 a result then an error for one request conflict" $ \ctx -> withEnv ctx $ \env -> do
      (_, callee, _) <- setup ctx env
      request <- terminal ctx "caller"
      r <- resultFor ctx.impl request "callee" "terminal-call" (js "{\"ok\":true}") [] >>= okAnswer
      e <- errorFor ctx.impl request "callee" "terminal-call" [] >>= okAnswer
      submitData ctx callee (member "data" r) >>= okAnswer >>= (`shouldBeJson` Bool False) . member "duplicate"
      submitData ctx callee (member "data" e) >>= refusedAnswer ConflictCategory "identity conflict"
    it "P-029 one call id from two callers gives two reply identities" $ \ctx -> withEnv ctx $ \env -> do
      (_, callee, _) <- setup ctx env
      first <- terminal ctx "caller" >>= \q -> resultFor ctx.impl q "callee" "terminal-call" (js "{\"ok\":true}") [] >>= okAnswer
      second <- terminal ctx "second-caller" >>= \q -> resultFor ctx.impl q "callee" "terminal-call" (js "{\"ok\":true}") [] >>= okAnswer
      memberText "delivery_id" (member "data" first) `shouldNotBe` memberText "delivery_id" (member "data" second)
      forM_ [first, second] $ \r -> submitData ctx callee (member "data" r) >>= okAnswer >>= (`shouldBeJson` Bool False) . member "duplicate"
    it "P-030 reusing a call id with other content conflicts" $ \ctx -> withEnv ctx $ \env -> do
      (caller, _, _) <- setup ctx env
      request <- terminal ctx "caller"
      submitData ctx caller request >>= okAnswer >>= (`shouldBeJson` Bool False) . member "duplicate"
      changedInput <- requestData ctx.impl "terminal-call" (obj [("q", Int 1)])
      changed <- member "data" <$> ok ctx.impl "request_envelope" [("request", changedInput), ("sender", "caller"), ("recipient", "callee"), ("source", "calls"), ("reply_route", Array ["caller", "replies"])]
      submitData ctx caller changed >>= refusedAnswer ConflictCategory ""
      otherOp <- ok ctx.impl "call_request" [("call_id", "terminal-call"), ("operation", "other"), ("input", obj [])]
      changedOp <- member "data" <$> ok ctx.impl "request_envelope" [("request", otherOp), ("sender", "caller"), ("recipient", "callee"), ("source", "calls"), ("reply_route", Array ["caller", "replies"])]
      submitData ctx caller changedOp >>= refusedAnswer ConflictCategory ""
      submitData ctx caller (setMember "recipient" "second-caller" request) >>= refusedAnswer ConflictCategory ""
    it "P-031 an exact reply retransmission is a duplicate" $ \ctx -> withEnv ctx $ \env -> do
      (_, callee, _) <- setup ctx env
      request <- terminal ctx "caller"
      r <- resultFor ctx.impl request "callee" "terminal-call" (js "{\"ok\":true}") [] >>= okAnswer
      _ <- submitData ctx callee (member "data" r) >>= okAnswer
      submitData ctx callee (member "data" r) >>= okAnswer >>= (`shouldBeJson` Bool True) . member "duplicate"

  describe "G The process.spawn Activity against the registry" $
    it "P-057 a failed ensure after the claim retries the same claim" $ \ctx -> withLifecycle ctx $ \lc -> do
      invocation <- spawnInvocation ctx.impl (specArgs [])
      answer <- ok ctx.impl "spawn" [("registry", lc.registry), ("invocation", invocation), ("provisioner", "fail-first"), ("times", Int 2)]
      case attemptsOf answer of
        [first, second] -> do
          attemptError first `shouldSatisfy` T.isInfixOf "lost after claim"
          member "prior_claim" (member "ok" second) `shouldBeJson` Bool True
        other -> expectationFailure (show other)
      map (memberText "child") (arrayOf (member "provisionings" answer)) `shouldBe` [child1, child1]

  describe "H Lineage registry storage" $ do
    it "P-059 the spawns table's columns and constraints" $ \ctx -> withLifecycle ctx $ \lc -> do
      rowsOf lc.env.admin "SELECT column_name::text FROM information_schema.columns WHERE table_schema = 'impetus_lifecycle' AND table_name = 'spawns' ORDER BY ordinal_position" []
        `shouldReturn` map (\c -> [Just c]) ["parent", "spawn_id", "child", "spec_digest", "created_at"]
      rowsOf lc.env.admin "SELECT conname::text, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'impetus_lifecycle.spawns'::regclass ORDER BY 1" []
        `shouldReturn` [[Just "spawns_child_key", Just "UNIQUE (child)"], [Just "spawns_pkey", Just "PRIMARY KEY (parent, spawn_id)"]]
    it "P-060 an unversioned spawns table is refused" $ \ctx -> withBare ctx $ \env -> do
      exec env.admin "CREATE SCHEMA impetus_lifecycle" []
      exec env.admin "CREATE TABLE impetus_lifecycle.spawns (unknown text)" []
      refusedWith SchemaRefusedCategory "refusing" ctx.impl "ensure_lifecycle_schema" [("conn", env.conn)]
    it "P-061 a mismatched version is refused and reported" $ \ctx -> withLifecycle ctx $ \lc -> do
      exec lc.env.admin "UPDATE impetus_lifecycle.schema_metadata SET version = 999 WHERE component = 'lifecycle'" []
      refusedWith SchemaRefusedCategory "999" ctx.impl "ensure_lifecycle_schema" [("conn", lc.env.conn)]
    it "P-062 provisioning never commits the caller's transaction" $ \ctx -> withBare ctx $ \env -> do
      joined <- connectImpl ctx False
      _ <- ok ctx.impl "ensure_lifecycle_schema" [("conn", joined)]
      lifecycleNamespaces env `shouldReturn` 0
      _ <- ok ctx.impl "rollback" [("conn", joined)]
      lifecycleNamespaces env `shouldReturn` 0
      void (ok ctx.impl "close" [("conn", joined)])
    it "P-063 provisioning is idempotent; schema_metadata is ('lifecycle', 1)" $ \ctx -> withLifecycle ctx $ \lc -> do
      _ <- ok ctx.impl "ensure_lifecycle_schema" [("conn", lc.env.conn)]
      _ <- ok ctx.impl "ensure_lifecycle_schema" [("conn", lc.env.conn)]
      rowsOf lc.env.admin "SELECT component, version::text FROM impetus_lifecycle.schema_metadata" [] `shouldReturn` [[Just "lifecycle", Just "1"]]
    it "P-064 a registry needs an autocommit connection" $ \ctx -> withLifecycle ctx $ \lc -> do
      joined <- connectImpl ctx False
      refusedWith Invalid "autocommit" ctx.impl "registry" [("conn", joined), ("parent", "parent"), ("credential", String lc.credential)]
      void (ok ctx.impl "close" [("conn", joined)])
    it "P-065 a wrong credential is denied on claim" $ \ctx -> withLifecycle ctx $ \lc -> do
      wrong <- issued ctx
      registry <- ok ctx.impl "registry" [("conn", lc.env.conn), ("parent", "parent"), ("credential", String wrong)]
      d <- specData ctx.impl []
      refusedWith DeniedCategory "lifecycle authentication" ctx.impl "claim" [("registry", registry), ("spec", d)]
      count lc.env.admin "SELECT count(*) FROM impetus_lifecycle.spawns" [] `shouldReturn` 0
    it "P-066 claiming another parent's spec is denied" $ \ctx -> withLifecycle ctx $ \lc -> do
      d <- specData ctx.impl [("parent", "other")]
      refusedWith DeniedCategory "authenticated registry" ctx.impl "claim" [("registry", lc.registry), ("spec", d)]
    it "P-067 the first claim is fresh, the second prior; one row" $ \ctx -> withLifecycle ctx $ \lc -> do
      value <- ok ctx.impl "spawn_spec" (specArgs [])
      ok ctx.impl "claim" [("registry", lc.registry), ("spec", member "data" value)] >>= (`shouldBeJson` Array ["parent", "spawn-1", String child1, Bool False])
      ok ctx.impl "claim" [("registry", lc.registry), ("spec", member "data" value)] >>= (`shouldBeJson` Array ["parent", "spawn-1", String child1, Bool True])
      rowsOf lc.env.admin "SELECT parent, spawn_id, child, spec_digest FROM impetus_lifecycle.spawns" []
        `shouldReturn` [[Just "parent", Just "spawn-1", Just child1, Just (memberText "digest" value)]]
    it "P-068 a changed claim conflicts" $ \ctx -> withLifecycle ctx $ \lc -> do
      d <- specData ctx.impl []
      _ <- ok ctx.impl "claim" [("registry", lc.registry), ("spec", d)]
      changed <- specData ctx.impl [("config", obj [("changed", Bool True)])]
      refusedWith ConflictCategory "content changed" ctx.impl "claim" [("registry", lc.registry), ("spec", changed)]
      count lc.env.admin "SELECT count(*) FROM impetus_lifecycle.spawns" [] `shouldReturn` 1
    it "P-069 lineage queries answer the claim" $ \ctx -> withLifecycle ctx $ \lc -> do
      d <- specData ctx.impl []
      _ <- ok ctx.impl "claim" [("registry", lc.registry), ("spec", d)]
      let fact = Array ["parent", "spawn-1", String child1]
      ok ctx.impl "child_of" [("registry", lc.registry), ("parent", "parent"), ("spawn_id", "spawn-1")] >>= (`shouldBeJson` fact)
      ok ctx.impl "parent_of" [("registry", lc.registry), ("child", String child1)] >>= (`shouldBeJson` fact)
      ok ctx.impl "children_of" [("registry", lc.registry), ("parent", "parent")] >>= (`shouldBeJson` Array [fact])
    it "P-070 lineage queries are parent-bound" $ \ctx -> withLifecycle ctx $ \lc -> do
      d <- specData ctx.impl []
      _ <- ok ctx.impl "claim" [("registry", lc.registry), ("spec", d)]
      credential <- issued ctx
      _ <- ok ctx.impl "register" [("conn", lc.env.conn), ("instance", "other"), ("credential", String credential)]
      other <- ok ctx.impl "registry" [("conn", lc.env.conn), ("parent", "other"), ("credential", String credential)]
      refusedWith DeniedCategory "parent must match" ctx.impl "child_of" [("registry", other), ("parent", "parent"), ("spawn_id", "spawn-1")]
      refusedWith DeniedCategory "does not belong" ctx.impl "parent_of" [("registry", other), ("child", String child1)]
      ok ctx.impl "parent_of" [("registry", other), ("child", "process-v1-unknown")] >>= (`shouldBeJson` Null)
    it "P-071 concurrent exact claims converge on one row" $ \ctx -> withLifecycle ctx $ \lc -> do
      d <- specData ctx.impl []
      let claimOn impl = do
            handle <- ok impl "connect" [("dsn", dsnOf ctx), ("autocommit", Bool True)]
            registry <- ok impl "registry" [("conn", handle), ("parent", "parent"), ("credential", String lc.credential)]
            answer <- ok impl "claim" [("registry", registry), ("spec", d)]
            _ <- impl.call "close" [("conn", handle)]
            pure answer
      (a, b) <- case ctx.launcher of
        Launcher with -> with $ \other -> concurrently (claimOn ctx.impl) (claimOn other)
      Set.fromList [showJson (claimPrior a), showJson (claimPrior b)] `shouldBe` Set.fromList ["false", "true"]
      Set.fromList [showJson (claimChild a), showJson (claimChild b)] `shouldBe` Set.fromList [showJson (String child1)]
      count lc.env.admin "SELECT count(*) FROM impetus_lifecycle.spawns" [] `shouldReturn` 1
    it "P-072 the claim is committed before provisioning" $ \ctx -> withLifecycle ctx $ \lc -> do
      invocation <- spawnInvocation ctx.impl (specArgs [])
      answer <- ok ctx.impl "spawn" [("registry", lc.registry), ("invocation", invocation), ("provisioner", "observe"), ("options", obj [("dsn", dsnOf ctx)])]
      map (member "claim_visible") (arrayOf (member "provisionings" answer)) `shouldSatisfy` \vs -> length vs == 1 && all (`typeExactEq` Int 1) vs

  describe "I Provisioner postconditions" $ do
    let key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" :: Text
        referenceSpawn ctx lc times = do
          invocation <- spawnInvocation ctx.impl spec15
          ok
            ctx.impl
            "spawn"
            [ ("registry", lc.registry)
            , ("invocation", invocation)
            , ("provisioner", "reference")
            , ("options", obj [("dsn", dsnOf ctx), ("parent_credential", String lc.credential), ("workspace_key", String key)])
            , ("times", Int times)
            ]
        fabricRows lc =
          concat
            <$> mapM
              (\q -> rowsOf lc.env.admin q [])
              [ "SELECT 'process', instance_id, credential_digest FROM impetus_fabric.processes ORDER BY 2"
              , "SELECT 'exposed', instance_id, source FROM impetus_fabric.exposed_sources ORDER BY 2, 3"
              , "SELECT 'offer', instance_id, source, service, capabilities::text FROM impetus_fabric.service_offers ORDER BY 2, 3, 4"
              , "SELECT 'grant', sender, recipient, source FROM impetus_fabric.delivery_grants ORDER BY 2, 3, 4"
              ]
    it "P-073 the reference profile registers, exposes, offers and grants" $ \ctx -> withLifecycle ctx $ \lc -> do
      answer <- referenceSpawn ctx lc 1
      map (member "ok") (attemptsOf answer) `shouldSatisfy` all (\o -> memberText "child" o == child1)
      count lc.env.admin "SELECT count(*) FROM impetus_fabric.processes WHERE instance_id = %s" [textParam child1] `shouldReturn` 1
      rowsOf lc.env.admin "SELECT instance_id, source FROM impetus_fabric.exposed_sources ORDER BY 1, 2" []
        `shouldReturn` [[Just "parent", Just "replies"], [Just child1, Just "calls"]]
      rowsOf lc.env.admin "SELECT instance_id, source, service, capabilities::text FROM impetus_fabric.service_offers" []
        `shouldReturn` [[Just child1, Just "calls", Just "analysis-agent", Just "{\"protocol\": \"call-v1\"}"]]
      rowsOf lc.env.admin "SELECT sender, recipient, source FROM impetus_fabric.delivery_grants ORDER BY 1" []
        `shouldReturn` [[Just "parent", Just child1, Just "calls"], [Just child1, Just "parent", Just "replies"]]
    it "P-074 re-ensuring converges with a deterministic child credential" $ \ctx -> withLifecycle ctx $ \lc -> do
      _ <- referenceSpawn ctx lc 1
      once <- fabricRows lc
      again <- referenceSpawn ctx lc 2
      map (member "prior_claim" . member "ok") (attemptsOf again) `shouldSatisfy` all (`typeExactEq` Bool True)
      fabricRows lc `shouldReturn` once
      credential <- ok ctx.impl "child_credential" [("workspace_key", String key), ("child", String child1)]
      count
        lc.env.admin
        "SELECT count(*) FROM impetus_fabric.processes WHERE instance_id = %s AND credential_digest = encode(sha256(convert_to(%s, 'UTF8')), 'hex')"
        [textParam child1, textParam (textOf credential)]
        `shouldReturn` 1
  where
    claimPrior = \case
      Array [_, _, _, p] -> p
      other -> other
    claimChild = \case
      Array [_, _, c, _] -> c
      other -> other
