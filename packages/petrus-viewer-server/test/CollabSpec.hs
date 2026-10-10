-- | The collaboration relay (server/collab.mjs semantics), served in process
-- at @/collab-ws@: port of tests/collab-server.test.mjs.
module CollabSpec (spec) where

import Data.Maybe (isJust)
import Petrus.Viewer.Json
import Petrus.Viewer.Server (ServerHandle (..))
import Test.Hspec
import TestSupport

collab :: (Int -> IO a) -> IO a
collab act = withViewer id (act . handlePort)

peer :: Int -> (WsClient -> JsValue -> IO a) -> IO a
peer port act = withWs port "/collab-ws" $ \c -> recvJson c >>= act c

spec :: Spec
spec = describe "/collab-ws (tests/collab-server.test.mjs)" $ do
  it "relay server sends welcome + peer_count on connect" $ collab $ \port ->
    peer port $ \c welcome -> do
      textField "type" welcome `shouldBe` Just "welcome"
      textField "peerId" welcome `shouldSatisfy` isJust
      count <- recvJson c
      textField "type" count `shouldBe` Just "peer_count"
      field "count" count `shouldBe` Just (int 1)

  it "relay server broadcasts cursor to other clients" $ collab $ \port ->
    peer port $ \c1 w1 -> peer port $ \c2 _ -> do
      _ <- drainFor 100 c1
      _ <- drainFor 100 c2
      sendText c1 "{\"type\":\"cursor\",\"x\":42,\"y\":84,\"userName\":\"Alice\"}"
      m <- recvJson c2
      textField "type" m `shouldBe` Just "cursor"
      field "x" m `shouldBe` Just (int 42)
      field "y" m `shouldBe` Just (int 84)
      textField "userName" m `shouldBe` Just "Alice"
      textField "peerId" m `shouldBe` textField "peerId" w1

  it "relay server does not echo back to sender" $ collab $ \port ->
    peer port $ \c1 _ -> do
      _ <- drainFor 100 c1
      sendText c1 "{\"type\":\"cursor\",\"x\":1,\"y\":2}"
      recvWithin 200 c1 >>= (`shouldBe` Nothing)

  it "relay server sends leave + updated peer_count when client disconnects" $ collab $ \port ->
    peer port $ \c2 _ -> do
      leaverId <- peer port $ \c1 w1 -> do
        _ <- drainFor 100 c2
        closeWs c1
        pure (textField "peerId" w1)
      leave <- recvJson c2
      textField "type" leave `shouldBe` Just "leave"
      textField "peerId" leave `shouldBe` leaverId
      count <- recvJson c2
      textField "type" count `shouldBe` Just "peer_count"
      field "count" count `shouldBe` Just (int 1)

  it "relay server broadcasts schema snapshots to other clients" $ collab $ \port ->
    peer port $ \c1 _ -> peer port $ \c2 _ -> do
      _ <- drainFor 100 c1
      _ <- drainFor 100 c2
      sendText c1 "{\"type\":\"schema\",\"netSchema\":{\"name\":\"test\",\"places\":{},\"transitions\":{},\"arcs\":[],\"subnets\":{}},\"viewState\":{\"layout\":{\"p1\":[10,20]}}}"
      m <- recvJson c2
      textField "type" m `shouldBe` Just "schema"
      (field "netSchema" m >>= textField "name") `shouldBe` Just "test"
      (field "viewState" m >>= field "layout" >>= field "p1") `shouldBe` Just (arr [int 10, int 20])
      textField "peerId" m `shouldSatisfy` isJust

  it "peer_count updates correctly as clients join and leave" $ collab $ \port ->
    peer port $ \c1 _ -> do
      pc1 <- recvJson c1
      field "count" pc1 `shouldBe` Just (int 1)
      peer port $ \c2 _ -> do
        pc2 <- recvJson c2
        field "count" pc2 `shouldBe` Just (int 2)
        peer port $ \c3 _ -> do
          pc3 <- recvJson c3
          field "count" pc3 `shouldBe` Just (int 3)
          _ <- drainFor 100 c1
          _ <- drainFor 100 c2
          closeWs c3
        msgs <- drainFor 300 c1
        map (textField "type") msgs `shouldBe` [Just "leave", Just "peer_count"]
        field "count" (last msgs) `shouldBe` Just (int 2)
