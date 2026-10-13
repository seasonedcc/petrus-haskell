-- | Port of @tests/petrus/engine/test_simulation_http.py@ (24 tests, 71
-- items), then the profile's remaining conformance points
-- (@spec/simulation-http-v1.md@). Each example names the upstream test it
-- ports. Upstream replaces @simulation_http.simulate@; these substitute the
-- configuration's 'runner'. Requests are written as urllib writes them
-- (@request@) or raw (@raw@, half-closed after sending, as upstream).
module HttpSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, bracket, throwIO, try)
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.Socket (Family (..), SockAddr (..), Socket, SocketType (..), close, connect, defaultProtocol, socket, tupleToHostAddress)
import Network.Socket.ByteString (recv, sendAll)
import Petrus.Impetus.Dsl (BuiltNet)
import Petrus.Impetus.Petrinet (Marking)
import Petrus.Json
import Petrus.Observation qualified as Observation
import Petrus.Simulation (SimulationError (..), simulate, simulationProfile)
import Petrus.Simulation.Http
import Petrus.Simulation.Http qualified as Http
import Support
import System.Timeout (timeout)
import Test.Hspec

type Runner = BuiltNet -> Marking -> Int -> IO (Either SimulationError ByteString)

built :: BuiltNet
built = fst buildScenario

config :: SimulationServerConfig
config = simulationServerConfig "127.0.0.1" 0 origin

withRunner :: Runner -> SimulationServerConfig
withRunner runner = config {Http.runner = runner}

-- | @serving()@
serving :: SimulationServerConfig -> (SimulationServer -> Int -> IO a) -> IO a
serving settings action = withSimulationServer settings built $ \server -> serverPort (simulationHttp server) >>= action server

-- | A runner that may be replaced while the server runs (upstream
-- monkeypatches between requests).
switchable :: Runner -> IO (IORef Runner, Runner)
switchable initial = do
  current <- newIORef initial
  pure (current, \b m n -> readIORef current >>= \r -> r b m n)

stub :: ByteString -> Runner
stub payload _ _ _ = pure (Right payload)

-- | @lambda *args: pytest.fail("simulate reached")@: records the call.
forbidden :: IO (IORef Bool, Runner)
forbidden = do
  reached <- newIORef False
  pure (reached, \_ _ _ -> writeIORef reached True >> throwIO (userError "simulate reached"))

-- | @request(url, method=…, body=…, origin=…)@ as urllib sends it.
request :: Int -> ByteString -> ByteString -> Maybe ByteString -> Text -> IO Reply
request port method target body requestOrigin =
  parseReply
    <$> exchange
      port
      ( method
          <> " "
          <> target
          <> " HTTP/1.1\r\nAccept-Encoding: identity\r\n"
          <> maybe "" (\b -> "Content-Length: " <> BC.pack (show (BS.length b)) <> "\r\n") body
          <> "Host: 127.0.0.1:"
          <> BC.pack (show port)
          <> "\r\nUser-Agent: Python-urllib/3.12\r\nOrigin: "
          <> TE.encodeUtf8 requestOrigin
          <> "\r\n"
          <> maybe "" (const "Content-Type: application/json\r\n") body
          <> "Connection: close\r\n\r\n"
          <> fromMaybe "" body
      )

get :: Int -> ByteString -> IO Reply
get port target = request port "GET" target Nothing origin

post :: Int -> ByteString -> IO Reply
post port body = request port "POST" simulationPath (Just body) origin

raw :: Int -> ByteString -> IO ByteString
raw = exchange

rawParts :: Int -> ByteString -> IO Reply
rawParts port payload = parseReply <$> raw port payload

definitionOf :: SimulationServer -> Json
definitionOf server = fromMaybe Null (lookupMember "definition" (simulationServerProfile server))

encode :: Json -> ByteString
encode = either (error . show) id . dumps compact

-- | @post_body(server, marking, definition=…)@
postBody :: SimulationServer -> Json -> Maybe Json -> ByteString
postBody server marking definition =
  encode
    ( Object
        [ ("expected_definition", fromMaybe (definitionOf server) definition)
        , ("initial_marking", marking)
        , ("max_actions", Int 1)
        ]
    )

-- | @raw_post(server, body, extra=…)@
rawPost :: ByteString -> ByteString -> ByteString
rawPost body extra =
  "POST /v1/simulations HTTP/1.1\r\nHost: test\r\nOrigin: "
    <> TE.encodeUtf8 origin
    <> "\r\nContent-Type: application/json\r\nContent-Length: "
    <> BC.pack (show (BS.length body))
    <> "\r\n"
    <> extra
    <> "\r\n"
    <> body

decoded :: HasCallStack => Reply -> Json
decoded reply = either (error . ("not strict JSON: " <>)) id (parseJson strictLoads reply.body)

errorCode :: Reply -> Json
errorCode reply = fromMaybe Null (lookupMember "error" (decoded reply) >>= lookupMember "code")

keys :: Json -> [Text]
keys = \case
  Object members -> map fst members
  _ -> []

originBytes :: ByteString
originBytes = TE.encodeUtf8 origin

methodNotAllowed :: ByteString
methodNotAllowed = "{\"error\":{\"code\":\"method_not_allowed\",\"message\":\"method not allowed\"}}"

-- | A client that sends and then neither reads nor closes until released.
withSilentClient :: Int -> ByteString -> (Socket -> IO a) -> IO a
withSilentClient port bytes action =
  bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
    connect sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
    sendAll sock bytes
    action sock

-- | Wait for an MVar at most @seconds@.
within :: Double -> MVar a -> IO (Maybe a)
within seconds = timeout (round (seconds * 1000000)) . readMVar

forked :: IO a -> IO (MVar a)
forked action = do
  done <- newEmptyMVar
  void (forkIO (action >>= putMVar done))
  pure done

-- | A server served in a thread, for tests that drive shutdown themselves.
started :: SimulationServerConfig -> IO (SimulationServer, Int, MVar ())
started settings = do
  server <- createSimulationServerWith settings built
  port <- serverPort (simulationHttp server)
  serving' <- forked (serveForever (simulationHttp server))
  pure (server, port, serving')

spec :: Spec
spec = do
  upstreamSpec
  conformanceSpec

upstreamSpec :: Spec
upstreamSpec = describe "test_simulation_http.py" $ do
  it "test_profile_fixture_and_factory_admission_precede_bind_and_engine" $ do
    expected <- specPath "spec/observation/simulation-service-profile-v1.json" >>= BS.readFile
    simulationProfile built `shouldBe` Right (either error id (parseJson strictLoads expected))
    (reached, runner) <- forbidden
    server <- createSimulationServerWith (withRunner runner) built
    closeSimulationServer server
    readIORef reached `shouldReturn` False

  it "test_profile_routes_cors_options_and_origin_are_exact" $
    serving config $ \server port -> do
      reply <- get port profilePath
      (reply.status, decoded reply) `shouldBe` (200, simulationServerProfile server)
      header "Access-Control-Allow-Origin" reply `shouldBe` Just originBytes
      header "Vary" reply `shouldBe` Just "Origin"
      options <- request port "OPTIONS" profilePath Nothing origin
      (options.status, options.body, header "Allow" options) `shouldBe` (204, "", Just "GET, OPTIONS")
      header "Access-Control-Allow-Methods" options `shouldBe` Just "GET, OPTIONS"
      ((.status) <$> get port simulationPath) `shouldReturn` 405
      ((.status) <$> get port "/unknown") `shouldReturn` 404
      ((.status) <$> get port "/v1/simulation-profile?x=1") `shouldReturn` 400
      ((.status) <$> request port "GET" profilePath Nothing "http://other.test") `shouldReturn` 403

  it "test_profile_property_is_detached_and_head_and_extension_methods_have_no_body" $
    serving config $ \server port -> do
      -- the profile is an immutable value: no copy can change what is served
      ((.body) <$> get port profilePath) `shouldReturn` simulationServerProfileBytes server
      forM_ ["HEAD", "TRACE", "FROBNICATE"] $ \method -> do
        response <- raw port (method <> " /v1/simulation-profile HTTP/1.1\r\nHost: test\r\nOrigin: " <> originBytes <> "\r\n\r\n")
        let (headers, rest) = BS.breakSubstring "\r\n\r\n" response
        (" 405 " `BS.isInfixOf` headers) `shouldBe` True
        BS.drop 4 rest `shouldBe` (if method == "HEAD" then "" else methodNotAllowed)

  it "test_success_is_exact_direct_simulate_bytes" $
    serving config $ \server port -> do
      let (_, marking) = buildScenario
      direct <- simulate built marking 32 >>= either (fail . show) pure
      let projected = either (error . show) id (Observation.marking marking)
          payload = encode (Object [("expected_definition", definitionOf server), ("initial_marking", projected), ("max_actions", Int 32)])
      reply <- post port payload
      (reply.status, reply.body) `shouldBe` (200, direct)

  describe "test_strict_json_schema_types_and_definition_mismatch" $
    forM_
      [ ("{", 400)
      , ("{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":NaN}", 400)
      , ("{\"expected_definition\":{},\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1}", 400)
      , ("{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":true}", 400)
      , ("{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1}", 409)
      ]
      $ \(body, status) -> it (BC.unpack body) $
        serving config $ \_ port -> do
          reply <- post port body
          reply.status `shouldBe` status
          keys (decoded reply) `shouldBe` ["error"]

  describe "test_nested_non_strict_json_is_400_before_simulation" $
    forM_ ["{\"nested\":{\"x\":1,\"x\":2}}", "{\"nested\":1e400}", "{\"nested\":\"\\ud800\"}"] $ \bad -> it (BC.unpack bad) $ do
      (reached, runner) <- forbidden
      serving (withRunner runner) $ \_ port ->
        ((.status) <$> post port ("{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1,\"extra\":" <> bad <> "}"))
          `shouldReturn` 400
      readIORef reached `shouldReturn` False

  describe "test_expected_definition_must_be_exact_object" $
    forM_ ["1", "1.0", "true"] $ \expected -> it (BC.unpack expected) $
      serving config $ \_ port ->
        ((.status) <$> post port ("{\"expected_definition\": " <> expected <> ", \"initial_marking\": [], \"max_actions\": 1}"))
          `shouldReturn` 400

  it "test_foreign_place_is_structural_and_unexpected_producer_failure_does_not_leak" $ do
    (current, runner) <- switchable simulate
    serving (withRunner runner) $ \server port -> do
      let foreignPlace = Array [Object [("place", String "foreign"), ("tokens", Array [Object [("color", Null), ("data", Null)]])]]
      ((.status) <$> post port (postBody server foreignPlace Nothing)) `shouldReturn` 422
      writeIORef current (\_ _ _ -> throwIO (userError "secret"))
      reply <- post port (postBody server (Array []) Nothing)
      (reply.status, reply.body) `shouldBe` (500, "{\"error\":{\"code\":\"internal_error\",\"message\":\"internal server error\"}}")

  describe "test_raw_framing_refusals" $
    forM_
      [ ("", " 415 ")
      , ("Content-Type: application/json\r\n", " 411 ")
      , ("Content-Type: application/json\r\nContent-Length: 1, 2\r\n", " 411 ")
      , ("Content-Type: application/json\r\nContent-Length: 999999999999999999999999\r\n", " 413 ")
      , ("Content-Type: application/json\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n", " 415 ")
      , ("Content-Type: application/json\r\nContent-Length: 0\r\nContent-Encoding: gzip\r\n", " 415 ")
      , ("Content-Type: application/json\r\nContent-Type: application/json\r\nContent-Length: 0\r\n", " 415 ")
      , ("Content-Type: application/json\r\nContent-Length: 0\r\nExpect: 100-continue\r\n", " 400 ")
      ]
      $ \(headers, status) -> it (show headers) $
        serving config $ \_ port -> do
          response <- raw port ("POST /v1/simulations HTTP/1.1\r\nHost: test\r\nOrigin: " <> originBytes <> "\r\n" <> headers <> "\r\n")
          (status `BS.isInfixOf` fst (BS.breakSubstring "\r\n" response)) `shouldBe` True

  describe "test_allowed_origin_is_one_exact_absolute_web_origin" $
    forM_ ["*", "null", "file://host", "https://example.test/path", "relative"] refusesOrigin

  it "test_one_slot_refuses_overlap_then_releases_after_success_and_profile_error" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    calls <- newIORef (0 :: Int)
    let held _ _ _ = do
          modifyIORef' calls (+ 1)
          void (tryPutMVar entered ())
          released <- within 2 release
          maybe (throwIO (userError "release timed out")) (const (pure (Right "{}"))) released
    (current, runner) <- switchable held
    serving (withRunner runner) $ \server port -> do
      let body = postBody server (Array []) Nothing
      first <- forked (post port body)
      within 2 entered `shouldReturn` Just ()
      reply <- post port body
      calls' <- readIORef calls
      (reply.status, reply.body, calls')
        `shouldBe` (429, "{\"error\":{\"code\":\"simulation_busy\",\"message\":\"another simulation is running\"}}", 1)
      putMVar release ()
      firstReply <- within 2 first
      ((\r -> (r.status, r.body)) <$> firstReply) `shouldBe` Just (200, "{}")
      ((.status) <$> post port body) `shouldReturn` 200
      readIORef calls `shouldReturn` 2
      writeIORef current (\_ _ _ -> pure (Left (ProfileError "x")))
      rejected <- post port body
      (rejected.status, rejected.body) `shouldBe` (422, "{\"error\":{\"code\":\"simulation_rejected\",\"message\":\"simulation was rejected\"}}")
      writeIORef current (stub "{}")
      ((.status) <$> post port body) `shouldReturn` 200

  it "test_slot_is_released_before_response_write" $ do
    -- Upstream checks the slot from inside _respond. Here the response is
    -- 16 MiB and its client never reads, so its write cannot finish while
    -- a second simulation is admitted (a slot held through the write would
    -- answer 429).
    let large = BS.replicate (16 * 1024 * 1024) 0x20
    serving (withRunner (stub large)) $ \server port -> do
      withSilentClient port (rawPost (postBody server (Array []) Nothing) "") $ \_ -> do
        threadDelay 200000
        second <- rawParts port (rawPost (postBody server (Array []) Nothing) "")
        (second.status, BS.length second.body) `shouldBe` (200, BS.length large)
    serving (withRunner (stub "{}")) $ \server port -> do
      -- upstream's shape: the first client closes without reading
      withSilentClient port (rawPost (postBody server (Array []) Nothing) "") (const (pure ()))
      ((.status) <$> rawParts port (rawPost (postBody server (Array []) Nothing) "")) `shouldReturn` 200

  it "test_shutdown_and_close_wait_for_active_simulation" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    let held _ _ _ = do
          void (tryPutMVar entered ())
          released <- within 3 release
          maybe (throwIO (userError "release timed out")) (const (pure (Right "{}"))) released
    (server, port, serving') <- started (withRunner held)
    client <- forked (raw port (rawPost (postBody server (Array []) Nothing) ""))
    within 2 entered `shouldReturn` Just ()
    closed <- forked (shutdownSimulationServer server >> closeSimulationServer server)
    within 0.2 closed `shouldReturn` Nothing
    putMVar release ()
    within 3 closed `shouldReturn` Just ()
    response <- within 3 client
    (BS.isPrefixOf "HTTP/1.0 200 OK" <$> response) `shouldBe` Just True
    within 3 serving' `shouldReturn` Just ()

  it "test_partial_body_times_out_without_simulation_or_close_deadlock" $ do
    (reached, runner) <- forbidden
    (server, port, serving') <- started (withRunner runner) {connectionTimeout = Just 0.1}
    response <-
      raw port $
        "POST /v1/simulations HTTP/1.1\r\nHost: test\r\nOrigin: "
          <> originBytes
          <> "\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{"
    (" 400 " `BS.isInfixOf` fst (BS.breakSubstring "\r\n" response)) `shouldBe` True
    shutdownSimulationServer server
    closed <- forked (closeSimulationServer server)
    within 2 closed `shouldReturn` Just ()
    within 2 serving' `shouldReturn` Just ()
    readIORef reached `shouldReturn` False

  describe "test_content_length_lexemes_have_exact_errors" $
    forM_
      [ ("+1", 411, "length_required")
      , ("-1", 411, "length_required")
      , ("1 0", 411, "length_required")
      , ("1 ", 411, "length_required")
      , ("1, 1", 411, "length_required")
      , ("1048577", 413, "payload_too_large")
      , ("999999999999999999999999999", 413, "payload_too_large")
      ]
      $ \(length', status, code) -> it (show length') $
        serving config $ \_ port -> do
          reply <-
            rawParts port $
              "POST /v1/simulations HTTP/1.1\r\nHost: test\r\nOrigin: "
                <> originBytes
                <> "\r\nContent-Type: application/json\r\nContent-Length:"
                <> length'
                <> "\r\n\r\n"
          (reply.status, errorCode reply) `shouldBe` (status, String code)

  it "test_duplicate_headers_targets_short_body_and_pipeline_are_closed_exactly" $
    serving config $ \_ port -> do
      let o = originBytes
          cases =
            [ ("GET /v1/simulation-profile HTTP/1.1\r\nHost: test\r\nOrigin: " <> o <> "\r\nOrigin: " <> o <> "\r\n\r\n", 403, "origin_not_allowed")
            , ( "POST /v1/simulations HTTP/1.1\r\nHost: test\r\nOrigin: " <> o <> "\r\nContent-Type: application/json\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n"
              , 411
              , "length_required"
              )
            , ( "POST /v1/simulations HTTP/1.1\r\nHost: test\r\nOrigin: " <> o <> "\r\nContent-Type: application/json\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n"
              , 415
              , "unsupported_media_type"
              )
            , ( "POST /v1/simulations HTTP/1.1\r\nHost: test\r\nOrigin: " <> o <> "\r\nContent-Type: application/json\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n"
              , 415
              , "unsupported_media_type"
              )
            , ( "POST /v1/simulations HTTP/1.1\r\nHost: test\r\nOrigin: " <> o <> "\r\nContent-Type: application/json\r\nContent-Length: 1\r\nExpect: x\r\n\r\nx"
              , 400
              , "invalid_request"
              )
            , ("GET http://test/v1/simulation-profile HTTP/1.1\r\nHost: test\r\nOrigin: " <> o <> "\r\n\r\n", 400, "invalid_request")
            , ("GET http://[x]/v1/simulation-profile HTTP/1.1\r\nHost: test\r\nOrigin: " <> o <> "\r\n\r\n", 400, "invalid_request")
            , ("GET //v1/simulation-profile HTTP/1.1\r\nHost: test\r\nOrigin: " <> o <> "\r\n\r\n", 400, "invalid_request")
            , ("GET /v1/simulation-profile#x HTTP/1.1\r\nHost: test\r\nOrigin: " <> o <> "\r\n\r\n", 400, "invalid_request")
            ]
      forM_ cases $ \(payload, status, code) -> do
        reply <- rawParts port payload
        (payload, reply.status, errorCode reply) `shouldBe` (payload, status, String code)
      short <- rawParts port (rawPost "{" "Content-Length: 2\r\n")
      (short.status, errorCode short) `shouldBe` (411, String "length_required")
      pipeline <-
        raw port $
          "GET /v1/simulation-profile HTTP/1.1\r\nHost: test\r\nOrigin: "
            <> o
            <> "\r\n\r\nGET /v1/simulation-profile HTTP/1.1\r\nHost: test\r\nOrigin: "
            <> o
            <> "\r\n\r\n"
      count "HTTP/1.0 200 OK" pipeline `shouldBe` 1

  it "test_short_body_is_exact_400" $
    serving config $ \_ port -> do
      reply <-
        rawParts port $
          "POST /v1/simulations HTTP/1.1\r\nHost: test\r\nOrigin: " <> originBytes <> "\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{"
      (reply.status, errorCode reply) `shouldBe` (400, String "invalid_request")

  describe "test_malformed_color_is_400_before_simulation" $
    forM_ [Int 1, String ""] $ \color -> it (show color) $ do
      (reached, runner) <- forbidden
      serving (withRunner runner) $ \server port -> do
        let marking = Array [Object [("place", String "pending"), ("tokens", Array [Object [("color", color), ("data", Object [("priority", Int 1)])]])]]
        reply <- post port (postBody server marking Nothing)
        (reply.status, errorCode reply) `shouldBe` (400, String "invalid_request")
      readIORef reached `shouldReturn` False

  it "test_typed_color_mismatch_and_runner_resource_rejection_are_422" $ do
    (current, runner) <- switchable simulate
    serving (withRunner runner) $ \server port -> do
      let mismatch = Array [Object [("place", String "pending"), ("tokens", Array [Object [("color", String "Other"), ("data", Object [("priority", Int 1)])]])]]
      ((.status) <$> post port (postBody server mismatch Nothing)) `shouldReturn` 422
      writeIORef current (\_ _ _ -> pure (Left (ProfileError "resource")))
      reply <- post port (postBody server (Array []) Nothing)
      (reply.status, errorCode reply) `shouldBe` (422, String "simulation_rejected")

  describe "test_nested_definition_number_type_mismatch_is_409_before_engine_or_simulate" $
    forM_ [Float 1.0, Bool True] $ \replacement -> it (show replacement) $ do
      (reached, runner) <- forbidden
      serving (withRunner runner) $ \server port -> do
        let definition = setFirstArcWeight replacement (definitionOf server)
        reply <- post port (postBody server (Array []) (Just definition))
        (reply.status, errorCode reply) `shouldBe` (409, String "definition_mismatch")
      readIORef reached `shouldReturn` False

  describe "test_strict_value_failures_are_exact_400_before_simulate" $
    forM_
      [ "\xff"
      , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1,\"x\":{\"a\":1,\"a\":2}}"
      , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":1e400}"
      , "{\"expected_definition\":{},\"initial_marking\":[],\"max_actions\":\"\\ud800\"}"
      , BC.replicate 1200 '[' <> "0" <> BC.replicate 1200 ']'
      ]
      $ \body -> it (take 60 (show body)) $ do
        (reached, runner) <- forbidden
        serving (withRunner runner) $ \_ port -> do
          reply <- post port body
          (reply.status, errorCode reply) `shouldBe` (400, String "invalid_request")
        readIORef reached `shouldReturn` False

  it "test_head_and_all_extension_methods_have_exact_405_headers_cors_and_body_rules" $
    serving config $ \_ port ->
      forM_ ["HEAD", "TRACE", "CONNECT", "FROBNICATE"] $ \method -> do
        reply <- rawParts port (method <> " /v1/simulation-profile HTTP/1.1\r\nHost: test\r\nOrigin: " <> originBytes <> "\r\n\r\n")
        (reply.status, header "Allow" reply, header "Access-Control-Allow-Origin" reply) `shouldBe` (405, Just "GET, OPTIONS", Just originBytes)
        header "Content-Length" reply `shouldBe` Just (BC.pack (show (BS.length methodNotAllowed)))
        header "Access-Control-Allow-Credentials" reply `shouldBe` Nothing
        reply.body `shouldBe` (if method == "HEAD" then "" else methodNotAllowed)

  describe "test_allowed_origin_rejects_ambiguous_or_invalid_authorities" $
    forM_
      [ "http://"
      , "http:///"
      , "http://:80"
      , "http://host:"
      , "http://host:0"
      , "http://host:65536"
      , "http://host:abc"
      , "http://user@host"
      , "http://user:pass@host"
      , "http://host "
      , "http://host\x00"
      , "http://host\\evil"
      , "http://host,evil"
      , "http://%65xample.test"
      , "http://host/"
      , "http://host?"
      , "http://host#"
      ]
      refusesOrigin

  it "test_profile_copies_cannot_mutate_get_or_post_definition_compare" $
    serving (withRunner (stub "{}")) $ \server port -> do
      let original = simulationServerProfile server
          -- a changed copy is a different value; the server's is untouched
          changed = setFirstArcWeight (Int 99) (definitionOf server)
      (changed /= definitionOf server) `shouldBe` True
      (decoded <$> get port profilePath) `shouldReturn` original
      ((.status) <$> post port (postBody server (Array []) (lookupMember "definition" original))) `shouldReturn` 200
  where
    refusesOrigin candidate = it (show candidate) $ do
      validateOrigin candidate `shouldSatisfy` either ("allowed_origin" `T.isInfixOf`) (const False)
      outcome <- try (createSimulationServer built "127.0.0.1" 0 candidate)
      case outcome of
        Left (OriginRefused message) -> T.unpack message `shouldContain` "allowed_origin"
        Left other -> expectationFailure ("refused otherwise: " <> show other)
        Right server -> closeSimulationServer server >> expectationFailure "created"

-- | The profile's points the upstream tests leave implicit.
conformanceSpec :: Spec
conformanceSpec = describe "spec/simulation-http-v1.md" $ do
  it "serves the exact profile fixture (format, version, profile, definition, bounds)" $
    serving config $ \_ port -> do
      fixture <- specPath "spec/observation/simulation-service-profile-v1.json" >>= BS.readFile
      reply <- get port profilePath
      decoded reply `shouldBe` either error id (parseJson strictLoads fixture)
      header "Content-Type" reply `shouldBe` Just "application/json; charset=utf-8"
      header "Cache-Control" reply `shouldBe` Just "no-store"

  it "answers a simulation with one Net document and no credentials header" $
    serving config $ \server port -> do
      let (_, marking) = buildScenario
          projected = either (error . show) id (Observation.marking marking)
      reply <- post port (encode (Object [("expected_definition", definitionOf server), ("initial_marking", projected), ("max_actions", Int 4)]))
      reply.status `shouldBe` 200
      lookupMember "format" (decoded reply) `shouldBe` Just (String "petrus-net-document")
      (header "Vary" reply, header "Access-Control-Allow-Credentials" reply) `shouldBe` (Just "Origin", Nothing)
      header "Access-Control-Allow-Origin" reply `shouldBe` Just originBytes

  it "refuses a simulation admitted after shutdown began with 503 server_shutting_down" $ do
    (reached, runner) <- forbidden
    (server, port, serving') <- started (withRunner runner)
    let body = postBody server (Array []) Nothing
        (head', _) = BS.splitAt (BS.length (rawPost body "") - BS.length body) (rawPost body "")
    reply <- withSilentClient port head' $ \sock -> do
      -- the connection is accepted and its handler is reading the body
      threadDelay 200000
      shutdownSimulationServer server
      sendAll sock body
      response <- forked (exchangeRest sock)
      within 3 response
    (\r -> (r.status, r.body)) . parseReply <$> reply
      `shouldBe` Just (503, "{\"error\":{\"code\":\"server_shutting_down\",\"message\":\"server is shutting down\"}}")
    closeSimulationServer server
    within 2 serving' `shouldReturn` Just ()
    readIORef reached `shouldReturn` False

  it "does not cancel admitted work when the client disconnects, and frees the slot after" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    finished <- newEmptyMVar
    let held _ _ _ = do
          void (tryPutMVar entered ())
          released <- within 3 release
          void (tryPutMVar finished ())
          maybe (throwIO (userError "release timed out")) (const (pure (Right "{}"))) released
    serving (withRunner held) $ \server port -> do
      let body = postBody server (Array []) Nothing
      withSilentClient port (rawPost body "") (const (within 2 entered `shouldReturn` Just ()))
      ((.status) <$> post port body) `shouldReturn` 429
      putMVar release ()
      within 2 finished `shouldReturn` Just ()
      let poll attempts = do
            reply <- post port body
            if reply.status == 429 && attempts > (0 :: Int) then threadDelay 20000 >> poll (attempts - 1) else pure reply.status
      poll 100 `shouldReturn` 200

  it "bounds a response write to a client that never reads by the five-second connection timeout" $ do
    -- BaseHTTPRequestHandler's settimeout(5) bounds the response's sendall
    -- as it bounds a read: the handler gives up on the write after five
    -- seconds, so a close waiting for it returns then, not before and not
    -- never.
    returned <- newEmptyMVar
    let large = BS.replicate (32 * 1024 * 1024) 0x20
        runner _ _ _ = tryPutMVar returned () >> pure (Right large)
    (server, port, serving') <- started (withRunner runner)
    withSilentClient port (rawPost (postBody server (Array []) Nothing) "") $ \_ -> do
      within 2 returned `shouldReturn` Just ()
      shutdownSimulationServer server
      closed <- forked (closeSimulationServer server)
      within 3 closed `shouldReturn` Nothing
      within 4 closed `shouldReturn` Just ()
    within 2 serving' `shouldReturn` Just ()

  it "writes every error as compact sorted strict JSON with exactly code and message" $
    serving config $ \_ port ->
      forM_
        [ get port "/unknown"
        , get port simulationPath
        , request port "GET" profilePath Nothing "http://other.test"
        , post port "{"
        , rawParts port (rawPost "" "Content-Length: 0\r\n")
        ]
        $ \action -> do
          reply <- action
          case decoded reply of
            value@(Object [("error", Object [("code", String _), ("message", String _)])]) ->
              Right reply.body `shouldBe` (TE.encodeUtf8 <$> either (Left . show) Right (canonicalText value))
            other -> expectationFailure ("not an error object: " <> show other)

-- | Half-close and read the rest of a response.
exchangeRest :: Socket -> IO ByteString
exchangeRest sock = do
  result <- try (go [])
  pure (either (\(_ :: SomeException) -> "") id result)
  where
    go chunks = do
      chunk <- recv sock 65536
      if BS.null chunk then pure (BS.concat (reverse chunks)) else go (chunk : chunks)

count :: ByteString -> ByteString -> Int
count needle haystack = case BS.breakSubstring needle haystack of
  (_, rest)
    | BS.null rest -> 0
    | otherwise -> 1 + count needle (BS.drop (BS.length needle) rest)

-- | @definition["arcs"][0]["weight"] = replacement@
setFirstArcWeight :: Json -> Json -> Json
setFirstArcWeight replacement = \case
  Object members -> Object [(k, if k == "arcs" then arcs v else v) | (k, v) <- members]
  other -> other
  where
    arcs = \case
      Array (Object first : rest) -> Array (Object [(k, if k == "weight" then replacement else v) | (k, v) <- first] : rest)
      other -> other
