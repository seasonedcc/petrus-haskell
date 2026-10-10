-- | The typed agent protocol: ported cases from tests/agentProtocol.test.ts
-- and tests/agentParseRegression.test.ts.
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

rejectsWith :: B.ByteString -> Text -> Expectation
rejectsWith b needle = case parsed b of
  Left e -> e `shouldSatisfy` (T.toLower needle `T.isInfixOf`) . T.toLower
  Right o -> expectationFailure ("accepted: " <> show (encodeJs (JsObj o)))

spec :: Spec
spec = do
  describe "parseAgentMessage" $ do
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

  describe "vocabulary" $ do
    it "names every request action and reads it back" $
      mapM_ (\a -> requestActionFromName (requestActionName a) `shouldBe` Just a) [minBound .. maxBound :: RequestAction]
    it "names every event and error code and reads them back" $ do
      mapM_ (\e -> eventNameFromText (eventNameText e) `shouldBe` Just e) [minBound .. maxBound :: EventName]
      mapM_ (\c -> errorCodeFromText (errorCodeText c) `shouldBe` Just c) [minBound .. maxBound :: ErrorCode]
