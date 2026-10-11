-- | The typed agent protocol: the cases of tests/agentProtocol.test.ts and
-- tests/agentParseRegression.test.ts that exercise the parser and the
-- constructors (18 of 19). The other one, @selectedEdgeToRef@, maps the
-- browser's selection state to a reference; it lives with the UI, which
-- stays TypeScript, and has no counterpart here.
--
-- The upstream files themselves also run, verbatim, against this parser:
-- the @protocol@ suite of @upstream-tests/run.mjs@ answers their
-- @parseAgentMessage@ calls through @petrus-viewer-oracle@.
module ProtocolSpec (spec) where

import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Viewer.Agent.Protocol
import Petrus.Viewer.Json
import Test.Hspec

parsed :: B.ByteString -> Either Text JsObject
parsed b = case parseJs b of
  Left e -> Left (T.pack e)
  Right v -> messageObject <$> parseAgentMessage v

-- | Parse and project one field of the normalized message.
fieldOf :: Text -> B.ByteString -> Either Text (Maybe JsValue)
fieldOf k b = lookupKey k <$> parsed b

-- | Serialize a message and parse it back: the same message, wire object
-- included (upstream: @deepEqual(parseAgentMessage(JSON.parse(serialize(m))), m)@).
roundTrips :: AgentMessage -> Expectation
roundTrips m = parseAgentMessageBytes (encodeJs (JsObj (messageObject m))) `shouldBe` Right m

-- | createProtocolFixtures(): one message per major browser-sidecar capability.
protocolFixtures :: [AgentMessage]
protocolFixtures =
  [ createRequest "req-handshake" AgentHandshake (o [("clientRole", str "sidecar"), ("supportedVersions", arr [int protocolVersion])])
  , createRequest "req-document" DocumentInspect (o [("includeSchema", JsBool True), ("includeViewState", JsBool True), ("includeRuntime", JsBool True)])
  , createRequest "req-preview" MutationPreview $
      o
        [ ("baseRevision", str "rev-1")
        , ("operations", arr [obj [("kind", str "add-place"), ("nodeId", str "p1"), ("position", obj [("x", int 120), ("y", int 80)]), ("initialTokens", int 1)]])
        ]
  , createRequest "req-sim" SimulationCommand (o [("kind", str "fire-transition"), ("transitionId", str "t1")])
  , createRequest "req-trace" TraceImport (o [("source", str "temporal"), ("workflowId", str "workflow-123"), ("runId", str "run-456")])
  , createEvent AgentReady $
      o [("sessionId", str "session-1"), ("mode", str "edit"), ("capabilities", arr (map str ["inspect-document", "preview-mutations", "subscriptions"]))]
  ]

o :: [(Text, JsValue)] -> JsObject
o kvs = objectFromList [(jsString k, v) | (k, v) <- kvs]

rejectsWith :: B.ByteString -> Text -> Expectation
rejectsWith b needle = case parsed b of
  Left e -> e `shouldSatisfy` (T.toLower needle `T.isInfixOf`) . T.toLower
  Right m -> expectationFailure ("accepted: " <> show (encodeJs (JsObj m)))

spec :: Spec
spec = do
  describe "parseAgentMessage" $ do
    it "parses the protocol fixtures for the major browser-sidecar capability shapes" $ do
      let reparsed = mapM (parseAgentMessageBytes . encodeJs . JsObj . messageObject) protocolFixtures
          discriminant = \case
            MsgRequest r -> ("request", requestActionName (requestAction r))
            MsgResponse r -> ("response", requestActionName (responseAction r))
            MsgEvent e -> ("event", eventNameText (eventName e))
      fmap (map discriminant) reparsed
        `shouldBe` Right
          [ ("request", "agent.handshake")
          , ("request", "document.inspect")
          , ("request", "mutation.preview")
          , ("request", "simulation.command")
          , ("request", "trace.import")
          , ("event", "agent.ready") :: (Text, Text)
          ]
      reparsed `shouldBe` Right protocolFixtures

    it "round-trips a request, a success response and an error response through JSON" $ do
      roundTrips (createRequest "req-1" SubscriptionOpen (o [("channel", str "canvas")]))
      roundTrips (createSuccessResponse "req-1" SubscriptionOpen (o [("subscriptionId", str "sub-1"), ("channel", str "canvas"), ("revision", str "rev-1")]))
      roundTrips (createErrorResponse "req-1" SubscriptionOpen (AgentError InvalidPayload "channel is missing" Nothing))

    it "round-trips document.open requests through JSON" $
      roundTrips (createRequest "req-open" DocumentOpen (o [("content", str "{\"net\":\"opened-net\"}"), ("filePath", str "/tmp/opened-net.json")]))

    it "round-trips constructed requests and responses" $ do
      let req = createRequest "req-1" SubscriptionOpen (objectFromList [(jsString "channel", str "canvas")])
          bytes = encodeJs (JsObj (messageObject req))
      fmap (encodeJs . JsObj) (parsed bytes) `shouldBe` Right bytes
      let ok = createSuccessResponse "req-1" SubscriptionOpen (objectFromList [(jsString "subscriptionId", str "sub-1"), (jsString "channel", str "canvas"), (jsString "revision", str "rev-1")])
          okBytes = encodeJs (JsObj (messageObject ok))
      fmap (encodeJs . JsObj) (parsed okBytes) `shouldBe` Right okBytes

    it "parses a request object with extra clientId field" $ do
      let b = "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"request\",\"requestId\":\"r\",\"action\":\"document.inspect\",\"params\":{},\"clientId\":\"3\"}"
      fieldOf "action" b `shouldBe` Right (Just (str "document.inspect"))

    it "throws on string input" $
      "\"hello\"" `rejectsWith` "Agent message must be an object"

    it "normalizes legacy protocolVersion and action aliases" $ do
      let legacy a p = "{\"protocol\":\"petrus-agent\",\"protocolVersion\":1,\"kind\":\"request\",\"requestId\":\"r\",\"action\":\"" <> a <> "\",\"params\":" <> p <> "}"
      fieldOf "action" (legacy "runtime.command" "{\"kind\":\"step-forward\"}") `shouldBe` Right (Just (str "simulation.command"))
      fieldOf "version" (legacy "runtime.command" "{\"kind\":\"step-forward\"}") `shouldBe` Right (Just (int 1))
      fieldOf "action" (legacy "net.inspect" "{}") `shouldBe` Right (Just (str "document.inspect"))
      fieldOf "action" (legacy "runtime.inspect" "{}") `shouldBe` Right (Just (str "simulation.inspect"))
      fieldOf "action" (legacy "temporal.import" "{\"source\":\"temporal\"}") `shouldBe` Right (Just (str "trace.import"))

    it "normalizes legacy event aliases" $ do
      let ev e p = "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"event\",\"event\":\"" <> e <> "\",\"payload\":" <> p <> "}"
      fieldOf "event" (ev "bridge.connected" "{\"sessionId\":\"s1\",\"mode\":\"edit\",\"capabilities\":[]}") `shouldBe` Right (Just (str "agent.ready"))
      fieldOf "event" (ev "document.updated" "{\"revision\":\"rev-1\",\"mode\":\"edit\",\"reason\":\"load\"}") `shouldBe` Right (Just (str "document.changed"))
      fieldOf "event" (ev "runtime.updated" "{\"revision\":\"rev-1\",\"mode\":\"edit\",\"currentStateIndex\":0}") `shouldBe` Right (Just (str "simulation.changed"))

    it "accepts handshakes with skewed versions and rejects other requests" $ do
      fieldOf "version" "{\"protocol\":\"petrus-agent\",\"version\":99,\"kind\":\"request\",\"requestId\":\"r\",\"action\":\"agent.handshake\",\"params\":{\"clientRole\":\"sidecar\",\"supportedVersions\":[1,99]}}"
        `shouldBe` Right (Just (int 99))
      fieldOf "version" "{\"protocol\":\"petrus-agent\",\"version\":99,\"kind\":\"response\",\"requestId\":\"r\",\"action\":\"agent.handshake\",\"ok\":true,\"result\":{\"sessionId\":\"s1\",\"mode\":\"edit\",\"capabilities\":[]}}"
        `shouldBe` Right (Just (int 99))
      "{\"protocol\":\"petrus-agent\",\"version\":99,\"kind\":\"request\",\"requestId\":\"r\",\"action\":\"document.inspect\",\"params\":{}}"
        `rejectsWith` "Unsupported agent version"

    it "rejects invalid discriminants and malformed payloads" $ do
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"request\",\"requestId\":\"r\",\"action\":\"mutation.preview\",\"params\":{\"operations\":[{\"kind\":\"explode-net\"}]}}"
        `rejectsWith` "Unknown mutation operation kind"
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"request\",\"requestId\":\"r\",\"action\":\"subscription.open\",\"params\":{\"channel\":\"telepathy\"}}"
        `rejectsWith` "Unsupported subscription channel"
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"response\",\"requestId\":\"r\",\"action\":\"document.inspect\",\"ok\":true}"
        `rejectsWith` "must include a result payload"

    it "rejects malformed success results and event payloads" $ do
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"response\",\"requestId\":\"r\",\"action\":\"mutation.apply\",\"ok\":true,\"result\":{\"previewId\":\"p1\"}}"
        `rejectsWith` "revision"
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"response\",\"requestId\":\"r\",\"action\":\"agent.handshake\",\"ok\":true,\"result\":{\"mode\":\"edit\",\"capabilities\":[]}}"
        `rejectsWith` "sessionId"
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"event\",\"event\":\"document.changed\",\"payload\":{\"mode\":\"edit\",\"reason\":\"load\"}}"
        `rejectsWith` "revision"
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"event\",\"event\":\"simulation.changed\",\"payload\":{\"revision\":\"rev-1\",\"currentStateIndex\":0}}"
        `rejectsWith` "mode"
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"response\",\"requestId\":\"r\",\"action\":\"mutation.preview\",\"ok\":true,\"result\":{\"previewId\":\"p1\",\"summary\":\"ok\",\"baseRevision\":\"rev-1\",\"mode\":\"edit\",\"operations\":[]}}"
        `rejectsWith` "warnings"
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"response\",\"requestId\":\"r\",\"action\":\"simulation.inspect\",\"ok\":true,\"result\":{\"revision\":\"rev-1\",\"mode\":\"edit\"}}"
        `rejectsWith` "state"
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"response\",\"requestId\":\"r\",\"action\":\"trace.import\",\"ok\":true,\"result\":{\"source\":\"temporal\",\"revision\":\"rev-1\",\"importedStates\":5}}"
        `rejectsWith` "mode"

    it "rejects Infinity in numeric fields" $
      -- 1e400 is how JSON spells JavaScript's Infinity (JSON.parse reads it so)
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"request\",\"requestId\":\"r\",\"action\":\"mutation.preview\",\"params\":{\"operations\":[{\"kind\":\"add-place\",\"nodeId\":\"p1\",\"position\":{\"x\":1e400,\"y\":0}}]}}"
        `rejectsWith` "add-place position must be numeric: x"

    it "rejects unknown error codes" $
      "{\"protocol\":\"petrus-agent\",\"version\":1,\"kind\":\"response\",\"requestId\":\"r\",\"action\":\"document.inspect\",\"ok\":false,\"error\":{\"code\":\"teapot\",\"message\":\"I am a teapot\"}}"
        `rejectsWith` "Unknown agent error code"

    it "keeps named event payloads for subscriptions and live updates" $ do
      let payload = o [("revision", str "rev-2"), ("mode", str "live"), ("currentStateIndex", int 4)]
          event = createEvent SimulationChanged payload
      roundTrips event
      case parseAgentMessageBytes (encodeJs (JsObj (messageObject event))) of
        Right (MsgEvent e) -> (eventName e, eventPayload e) `shouldBe` (SimulationChanged, payload)
        other -> expectationFailure ("not an event: " <> show other)

  describe "vocabulary" $ do
    it "names every request action and reads it back" $
      mapM_ (\a -> requestActionFromName (requestActionName a) `shouldBe` Just a) [minBound .. maxBound :: RequestAction]
    it "names every event and error code and reads them back" $ do
      mapM_ (\e -> eventNameFromText (eventNameText e) `shouldBe` Just e) [minBound .. maxBound :: EventName]
      mapM_ (\c -> errorCodeFromText (errorCodeText c) `shouldBe` Just c) [minBound .. maxBound :: ErrorCode]
