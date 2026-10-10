-- | The agent relay at @/ws/agent@: port of tests/bridgeVitePlugin.test.mjs
-- plus the routing function on its own.
module RelaySpec (spec) where

import Data.ByteString.Lazy qualified as BL
import Data.Maybe (isJust)
import Petrus.Viewer.Json
import Petrus.Viewer.Relay
import Petrus.Viewer.Server (ServerHandle (..))
import Test.Hspec
import TestSupport

routed :: RelayKind -> BL.ByteString -> Maybe BL.ByteString
routed k raw = either (const Nothing) (fmap routedBytes . relayMessage k (jsString "7")) (parseJ raw)

agent :: (Int -> IO a) -> IO a
agent act = withViewer id (act . handlePort)

connect :: Int -> (WsClient -> JsValue -> IO a) -> IO a
connect port act = withWs port "/ws/agent" $ \c -> recvJson c >>= act c

spec :: Spec
spec = do
  describe "relayMessage" $ do
    it "stamps the sender id, overwriting a spoofed one in place" $ do
      routed AgentRelay "{\"action\":\"x\"}" `shouldBe` Just "{\"action\":\"x\",\"clientId\":\"7\"}"
      routed AgentRelay "{\"clientId\":\"fake\",\"a\":1}" `shouldBe` Just "{\"clientId\":\"7\",\"a\":1}"
      routed CollabRelay "{\"type\":\"cursor\"}" `shouldBe` Just "{\"type\":\"cursor\",\"peerId\":\"7\"}"
    it "re-serializes with JSON.stringify semantics" $
      routed AgentRelay "{ \"b\" : 1.50, \"1\": [1e21, \"\\u00e9\"] }" `shouldBe` Just "{\"1\":[1e+21,\"\xc3\xa9\"],\"b\":1.5,\"clientId\":\"7\"}"
    it "drops what Node drops: non-objects on the agent relay, primitives on collab" $ do
      routed AgentRelay "[1,2]" `shouldBe` Nothing
      routed AgentRelay "42" `shouldBe` Nothing
      routed AgentRelay "null" `shouldBe` Nothing
      routed CollabRelay "null" `shouldBe` Nothing
      routed CollabRelay "\"s\"" `shouldBe` Nothing
    it "relays arrays on collab unchanged (the id property is not serialized)" $
      routed CollabRelay "[1, {\"a\":2}]" `shouldBe` Just "[1,{\"a\":2}]"
    it "marks targeted messages" $ do
      let r = either (const Nothing) (relayMessage AgentRelay (jsString "7")) (parseJ "{\"targetClientId\":\"2\"}")
      fmap routedTargeted r `shouldBe` Just True
      fmap (isJust . routedTarget) r `shouldBe` Just True

  describe "/ws/agent (tests/bridgeVitePlugin.test.mjs)" $ do
    it "sends welcome with clientId on connect" $ agent $ \port ->
      connect port $ \_ welcome -> do
        textField "type" welcome `shouldBe` Just "welcome"
        textField "clientId" welcome `shouldSatisfy` isJust

    it "relays messages between clients" $ agent $ \port ->
      connect port $ \c1 w1 -> connect port $ \c2 _ -> do
        _ <- drainFor 50 c1
        _ <- drainFor 50 c2
        sendText c1 "{\"action\":\"test.ping\"}"
        m <- recvJson c2
        textField "action" m `shouldBe` Just "test.ping"
        textField "clientId" m `shouldBe` textField "clientId" w1

    it "supports targeted messages" $ agent $ \port ->
      connect port $ \c1 _ -> connect port $ \c2 w2 -> connect port $ \c3 _ -> do
        mapM_ (drainFor 50) [c1, c2, c3]
        let target = maybe "" (encodeJsLazy . JsStr . jsString) (textField "clientId" w2)
        sendText c1 ("{\"action\":\"targeted\",\"targetClientId\":" <> target <> "}")
        m <- recvJson c2
        textField "action" m `shouldBe` Just "targeted"
        others <- drainFor 100 c3
        filter ((== Just "targeted") . textField "action") others `shouldBe` []

    it "overwrites spoofed clientId" $ agent $ \port ->
      connect port $ \c1 w1 -> connect port $ \c2 _ -> do
        _ <- drainFor 50 c1
        _ <- drainFor 50 c2
        sendText c1 "{\"action\":\"spoof\",\"clientId\":\"fake\"}"
        m <- recvJson c2
        textField "clientId" m `shouldBe` textField "clientId" w1

    it "ignores non-object JSON" $ agent $ \port ->
      connect port $ \c1 _ -> do
        mapM_ (sendText c1) ["42", "null", "[1,2]", "not json"]
        connect port $ \_ w2 -> textField "type" w2 `shouldBe` Just "welcome"

    it "broadcasts client_count on join and leave + client_count on close" $ agent $ \port ->
      connect port $ \c1 _ -> do
        first <- recvJson c1
        textField "type" first `shouldBe` Just "client_count"
        field "count" first `shouldBe` Just (int 1)
        leaverId <- connect port $ \c2 w2 -> do
          joined <- recvJson c1
          field "count" joined `shouldBe` Just (int 2)
          closeWs c2
          pure (textField "clientId" w2)
        leave <- recvJson c1
        textField "type" leave `shouldBe` Just "leave"
        textField "clientId" leave `shouldBe` leaverId
        count <- recvJson c1
        field "count" count `shouldBe` Just (int 1)

    it "delivers the newcomer's welcome before any count" $ agent $ \port ->
      connect port $ \_ welcome -> textField "type" welcome `shouldBe` Just "welcome"
