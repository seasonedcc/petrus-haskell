{-# LANGUAGE OverloadedRecordDot #-}

-- | Port of @tests/petrus/engine/test_observation_http.py@ (7 tests, 19
-- items), over real HTTP against the Haskell server. Each example names
-- the upstream test it ports.
module UpstreamSpec (spec) where

import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Network.Socket (Family (..), SockAddr (..), SocketType (..), close, connect, defaultProtocol, socket, tupleToHostAddress)
import Network.Socket.ByteString (sendAll)
import Petrus.Engine (EngineError (..))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Set qualified as Set
import GHC.Conc (listThreads)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Provider (EngineResources (..), OpenMode (..), defaultResources, openEngine)
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.Petrinet (Token (..), markingFromList)
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumps, lookupMember, parseJson, strictLoads)
import Petrus.Observation.Engine qualified as Observe
import Petrus.Observation.Http
import Support
import Test.Hspec

decode :: HasCallStack => ByteString -> Json
decode bytes = either (error . ("invalid JSON: " <>)) id (parseJson strictLoads bytes)

errorCode :: Reply -> Maybe Json
errorCode reply = lookupMember "error" (decode (replyBody reply)) >>= lookupMember "code"

spec :: Spec
spec = do
  upstreamSpec
  profileSpec

upstreamSpec :: Spec
upstreamSpec = describe "test_observation_http.py" $ do
  it "test_factory_binds_without_starting_a_hidden_thread" $ do
    engine <- makeEngine
    threadsBefore <- Set.fromList <$> listThreads
    server <- createObservationServer engine "127.0.0.1" 0
    threadsAfter <- Set.fromList <$> listThreads
    serverClose server
    Engine.close engine
    threadsAfter `shouldBe` threadsBefore

  it "test_snapshot_document_history_and_required_http_headers_are_exact" $ do
    engine <- makeEngine
    expectedSnapshot <- Observe.snapshot engine
    expectedDocument <- Observe.netDocument engine
    expectedHistory <- Observe.historyPage engine 0 100
    withObservation engine $ \port -> do
      reply <- request port "GET" "/v1/snapshot"
      (replyStatus reply, decode (replyBody reply)) `shouldBe` (200, expectedSnapshot)
      header "Content-Type" reply `shouldBe` Just "application/json; charset=utf-8"
      header "Cache-Control" reply `shouldBe` Just "no-store"
      header "Access-Control-Allow-Origin" reply `shouldBe` Just "*"
      header "Access-Control-Allow-Methods" reply `shouldBe` Just "GET, OPTIONS"
      header "Access-Control-Allow-Headers" reply `shouldBe` Just "Content-Type"
      let encoded = either (error . show) id (dumps defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True, allowNan = False} (decode (replyBody reply)))
      header "Content-Length" reply `shouldBe` Just (BC.pack (show (BC.length encoded)))
      document <- request port "GET" "/v1/document"
      (replyStatus document, decode (replyBody document)) `shouldBe` (200, expectedDocument)
      history <- request port "GET" "/v1/history?after=0&limit=100"
      (replyStatus history, decode (replyBody history)) `shouldBe` (200, expectedHistory)
    Engine.close engine

  describe "test_history_query_grammar_is_exact" $
    forM_
      [ ""
      , "after=0"
      , "limit=1"
      , "after=0&after=1&limit=1"
      , "after=0&limit=1&extra=1"
      , "after=&limit=1"
      , "after=+1&limit=1"
      , "after=%201&limit=1"
      , "after=-1&limit=1"
      , "after=1.0&limit=1"
      , "after=0&limit=" <> BC.pack (show (maxHistoryPageLimit + 1))
      ]
      $ \query -> it (show query) $ do
        engine <- makeEngine
        withObservation engine $ \port -> do
          reply <- request port "GET" ("/v1/history?" <> query)
          replyStatus reply `shouldBe` 400
          errorCode reply `shouldBe` Just (String "invalid_request")
        Engine.close engine

  it "test_future_cursor_is_a_protocol_400" $ do
    engine <- makeEngine
    withObservation engine $ \port -> do
      reply <- request port "GET" "/v1/history?after=999&limit=1"
      (replyStatus reply, errorCode reply) `shouldBe` (400, Just (String "invalid_request"))
    Engine.close engine

  describe "test_mutation_methods_are_405_and_never_reach_engine" $
    forM_ ["POST", "PUT", "DELETE"] $ \method -> it (BC.unpack method) $ do
      engine <- makeEngine
      pageBefore <- Observe.historyPage engine 0 100
      withObservation engine $ \port -> do
        reply <- request port method "/v1/snapshot"
        (replyStatus reply, header "Allow" reply, errorCode reply)
          `shouldBe` (405, Just "GET, OPTIONS", Just (String "method_not_allowed"))
        Observe.historyPage engine 0 100 `shouldReturn` pageBefore
      Engine.close engine

  it "test_unknown_route_options_and_closed_engine" $ do
    engine <- makeEngine
    withObservation engine $ \port -> do
      replyStatus <$> request port "GET" "/unknown" `shouldReturn` 404
      options <- request port "OPTIONS" "/v1/snapshot"
      (replyStatus options, replyBody options, header "Allow" options) `shouldBe` (204, "", Just "GET, OPTIONS")
      header "Access-Control-Allow-Origin" options `shouldBe` Just "*"
      Engine.close engine
      closed <- request port "GET" "/v1/snapshot"
      (replyStatus closed, decode (replyBody closed))
        `shouldBe` (503, Object [("error", Object [("code", String "engine_unavailable"), ("message", String "Engine is unavailable")])])

  it "test_transport_shutdown_does_not_close_engine_and_engine_keeps_executing" $ do
    engine <- makeEngine
    withObservation engine $ \port ->
      replyStatus <$> request port "GET" "/v1/snapshot" `shouldReturn` 200
    outcome <- Engine.advance engine
    outcome.ready `shouldBe` True
    current <- Observe.snapshot engine
    (lookupMember "current" current >>= lookupMember "marking" >>= firstItem >>= lookupMember "place")
      `shouldBe` Just (String "b")
    Engine.close engine
  where
    firstItem = \case
      Array (x : _) -> Just x
      _ -> Nothing

-- | The transport profile in @spec/observation-protocol-v1.md@, beyond
-- what the upstream tests check.
profileSpec :: Spec
profileSpec = describe "spec/observation-protocol-v1.md, HTTP transport profile" $ do
  it "a disconnected requester does not affect Engine execution" $ do
    engine <- makeEngine
    withObservation engine $ \port -> do
      forM_ [1 :: Int .. 50] $ \_ ->
        bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
          connect sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
          sendAll sock "GET /v1/document HTTP/1.0\r\n\r\n"
      replyStatus <$> request port "GET" "/v1/snapshot" `shouldReturn` 200
      outcome <- Engine.advance engine
      outcome.ready `shouldBe` True
      replyStatus <$> request port "GET" "/v1/history?after=0&limit=1000" `shouldReturn` 200
    Engine.close engine
  it "a poisoned Engine is a 503 on every read door, as a closed one is" $ do
    -- The poisoning of test_observation.py's
    -- test_joined_commit_failure_poisons_observation_and_hides_uncommitted_frontier:
    -- a commit hook that refuses once armed.
    store <- inMemoryHistoryStore
    dispatch <- inMemoryDispatch <$> newInMemoryDispatch
    refusing <- newIORef False
    let commitHook = readIORef refusing >>= \armed -> when armed (throwIO (EngineRuntimeError "commit refused"))
        options = Engine.defaultEngineOptions {Engine.marking = markingFromList [(a, [Token (Just "value") (Object [("n", Int 1)])])]}
    engine <- openEngine CreateInstance observationNet "http-poison" store dispatch options defaultResources {commit = Just commitHook}
    withObservation engine $ \port -> do
      replyStatus <$> request port "GET" "/v1/snapshot" `shouldReturn` 200
      writeIORef refusing True
      Engine.advance engine `shouldThrow` \case
        EngineRuntimeError message -> message == "commit refused"
        _ -> False
      forM_ ["/v1/snapshot", "/v1/document", "/v1/history?after=0&limit=1"] $ \target -> do
        reply <- request port "GET" target
        (replyStatus reply, replyBody reply)
          `shouldBe` (503, "{\"error\":{\"code\":\"engine_unavailable\",\"message\":\"Engine is unavailable\"}}")
    Engine.close engine
  it "unexpected failures are generic 500 responses without exception details" $ do
    let secret = ObservationDoors (throwIO (userError "secret detail")) (throwIO (EngineTypeError "secret detail")) (\_ _ -> throwIO (EngineHandlerFailed "secret detail"))
    withObservationDoors secret $ \port ->
      forM_ ["/v1/snapshot", "/v1/document", "/v1/history?after=0&limit=1"] $ \target -> do
        reply <- request port "GET" target
        (replyStatus reply, replyBody reply)
          `shouldBe` (500, "{\"error\":{\"code\":\"internal_error\",\"message\":\"internal server error\"}}")
  it "errors have the strict shape and JSON is compact, sorted and exactly sized" $ do
    engine <- makeEngine
    withObservation engine $ \port -> do
      reply <- request port "GET" "/v1/history?after=0&limit=x"
      replyBody reply
        `shouldBe` "{\"error\":{\"code\":\"invalid_request\",\"message\":\"history query parameter limit must be a non-empty unsigned decimal integer\"}}"
      header "Content-Length" reply `shouldBe` Just (BC.pack (show (BC.length (replyBody reply))))
    Engine.close engine
