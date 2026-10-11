-- | The FastAPI cases of @tests/integration/host/test_service.py@ against
-- the warp ingress ("Hamsterdan.Host.Api"), plus a differential check of
-- the whole HTTP surface against the pinned reference served by uvicorn
-- (@differential/api_reference.py@): every request below gets the same
-- status line, headers in the same order (only the @date@ value may
-- differ) and body bytes from both servers.
module ApiSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Api (hostServerApplication, hostSettings, withHostServer, withLifespan)
import Hamsterdan.Host.Python (RuntimeError (..))
import Hamsterdan.Host.Service
import Hamsterdan.Host.Service qualified as Host
import IngressSpec (newDelivery)
import Petrus.Json (Json (..), LoneSurrogates (..), ParseOptions (..), parseJson, pythonLoads)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import RawHttp
import ServiceSupport
import System.FilePath ((</>))
import System.IO (hGetLine)
import System.Process.Typed
import System.Timeout (timeout)
import Test.Hspec
import TestSupport (runtimeError, withTempRoot)

-- | @TestClient(create_app(host, reconcile_startup=...))@ entered: the
-- lifespan around a live warp server on an ephemeral port, serving what
-- 'serve' serves, the way it serves it ('withHostServer').
withClient :: HostService -> Bool -> (Int -> IO a) -> IO a
withClient host reconcileStartup action =
  withLifespan host reconcileStartup $
    withHostServer hostSettings (hostServerApplication host) action

post :: Int -> ByteString -> [(Text, Text)] -> IO RawResponse
post port payload headers =
  parseResponse <$> exchange port (rawRequest "POST" "/github/webhooks" (wire headers) payload)
  where
    wire pairs = [(TE.encodeUtf8 n, TE.encodeUtf8 v) | (n, v) <- pairs, n /= "content-length"]

get :: Int -> ByteString -> IO RawResponse
get port target = parseResponse <$> exchange port (rawRequest "GET" target [] "")

jsonBody :: RawResponse -> Json
jsonBody response = either error id (parseJson pythonLoads response.body)

spec :: Spec
spec = do
  describe "tests/integration/host/test_service.py (FastAPI)" $ do
    it "test_fastapi_accepts_durably_before_work_deduplicates_and_has_sanitized_health" . withTempRoot $ \tmp -> do
      h <- harness tmp defaults
      delivery <- newDelivery
      withClient h.host False $ \port -> do
        threadDelay 20000
        response <- post port envelope (signed envelope delivery "pull_request")
        response.status `shouldBe` 202
        jsonBody response
          `shouldBe` Object [("custody", String "durable"), ("delivery_id", String delivery), ("disposition", String "accepted")]
        Custody.status h.host.custody delivery `shouldReturn` Just Custody.InboxPending
        made h >>= (`shouldBe` 0) . length
        duplicate <- post port envelope (signed envelope delivery "pull_request")
        duplicate.status `shouldBe` 202
        lookupKey "disposition" (jsonBody duplicate) `shouldBe` Just (String "duplicate")
        healthz <- get port "/healthz"
        healthz.status `shouldBe` 200
        forM_ ["hook-secret", "private-key-secret", "client-secret", "comment"] $ \secret ->
          (secret `BS.isInfixOf` healthz.body) `shouldBe` False
        Custody.pending h.host.custody 100 Nothing >>= \case
          item : _ -> Host.process h.host item
          [] -> expectationFailure "no pending delivery"
        apps <- made h
        length apps `shouldBe` 1
        forM_ apps $ \app -> readIORef app.reconciles `shouldReturn` ["github-delivery:" <> delivery]

    it "test_fastapi_startup_reconciliation_failure_still_closes_owned_service" . withTempRoot $ \tmp -> do
      h <- harness tmp defaults
      modifyIORef' h.host.hooks $ \hooks ->
        hooks {reconcileRegistrationOverride = Just (throwIO (RuntimeError "synthetic startup failure"))}
      withClient h.host True (\_ -> throwIO (userError "failed startup must not enter the application lifespan"))
        `shouldThrow` runtimeError "synthetic startup failure"
      readIORef h.clients.closed `shouldReturn` 1

    describe "test_fastapi_rejects_malformed_signature_body_or_header" $ do
      let cases :: [(String, ByteString, Maybe [(Text, Text)])]
          cases =
            [ ("{}", "{}", Just [("content-type", "application/json")])
            , ("not-json", "not-json", Nothing)
            , ("envelope, text/plain", envelope, Just [("content-type", "text/plain")])
            ]
      forM_ cases $ \(label, payload, overrides) ->
        it label . withTempRoot $ \tmp -> do
          h <- harness tmp defaults
          delivery <- newDelivery
          let base = signed payload delivery "pull_request"
              merged = case overrides of
                Nothing -> base
                Just extra -> [(n, maybe v id (lookup n extra)) | (n, v) <- base]
              actual = if payload == "{}" then filter ((/= "x-hub-signature-256") . fst) merged else merged
          withClient h.host False $ \port -> do
            response <- post port payload actual
            response.status `shouldBe` 400

    it "test_worker_failure_remains_primary_and_lifespan_closes_resources_once" . withTempRoot $ \tmp -> do
      h <- harness tmp defaults
      _ <- application h.host 44 31 7
      modifyIORef' h.host.hooks $ \hooks -> hooks {workerOverride = Just (throwIO (RuntimeError "worker failed"))}
      withClient h.host False (\_ -> threadDelay 20000)
        `shouldThrow` runtimeError "worker failed"
      readIORef h.clients.closed `shouldReturn` 1
      apps <- made h
      length apps `shouldBe` 1
      forM_ apps $ \app -> readIORef app.closed `shouldReturn` 1

  -- CPython's json.loads keeps a lone surrogate escape in a str, and so does
  -- the provider path (Hamsterdan.Python.loads). The
  -- webhook corpus checks the stored bytes against the reference; the
  -- surface below checks both answers against uvicorn.
  describe "lone surrogate escapes in a webhook payload" $ do
    it "accepts one outside a comment body (202) and keeps it in the observation" . withTempRoot $ \tmp -> do
      h <- harness tmp defaults
      delivery <- newDelivery
      withClient h.host False $ \port -> do
        response <- post port surrogateAction (signed surrogateAction delivery "pull_request")
        response.status `shouldBe` 202
        lookupKey "disposition" (jsonBody response) `shouldBe` Just (String "accepted")
        Custody.status h.host.custody delivery `shouldReturn` Just Custody.InboxPending
        -- Read back from the inbox, where it was stored escaped.
        Custody.pending h.host.custody 100 Nothing >>= \case
          [item] -> item.action `shouldBe` loneSurrogate
          other -> expectationFailure ("expected one pending delivery, got " <> show other)

    it "refuses one in a comment body (400), as len(text.encode()) raises" . withTempRoot $ \tmp -> do
      h <- harness tmp defaults
      delivery <- newDelivery
      withClient h.host False $ \port -> do
        response <- post port surrogateComment (signed surrogateComment delivery "issue_comment")
        response.status `shouldBe` 400
        jsonBody response `shouldBe` Object [("detail", String "webhook envelope is malformed")]
        Custody.status h.host.custody delivery `shouldReturn` Nothing

  describe "the HTTP surface against the reference (uvicorn)" $
    it "answers every request with the reference's status line, headers and body" . withTempRoot $ \tmp -> do
      let referenceRoot = tmp </> "reference"
          hostRoot = tmp </> "host"
      h <- harness hostRoot defaults
      withReferenceServer referenceRoot $ \referencePort ->
        withClient h.host False $ \hostPort ->
          forM_ surface $ \(label, request) -> do
            reference <- parseResponse . comparable <$> exchange referencePort request
            ours <- parseResponse . comparable <$> exchange hostPort request
            let expected = unordered reference
                actual = unordered ours
            unless (actual == expected) $
              expectationFailure (label <> "\n  reference: " <> show expected <> "\n  host:      " <> show actual)

-- | @allow@ with its methods sorted: Starlette joins a set, whose order
-- varies with the reference process's string hashing.
unordered :: RawResponse -> RawResponse
unordered response =
  response {headers = [(n, if n == "allow" then BS.intercalate ", " (sort (BS.split 44 (BC.filter (/= ' ') v))) else v) | (n, v) <- response.headers]}

lookupKey :: Text -> Json -> Maybe Json
lookupKey key = \case
  Object members -> lookup key members
  _ -> Nothing

-- | Run the reference server over a fresh state root until the action
-- returns, then stop it (SIGTERM to its exact process) and wait for it.
withReferenceServer :: FilePath -> (Int -> IO a) -> IO a
withReferenceServer root action = do
  executable <- upstreamPythonExecutable "hamsterdan"
  repo <- repoRoot
  let script = repo </> "packages" </> "hamsterdan-host" </> "differential" </> "api_reference.py"
      config = setStdin nullStream (setStdout createPipe (proc executable ["-I", "-B", script, root]))
  withProcessTerm config $ \server -> do
    line <- timeout 60000000 (hGetLine (getStdout server))
    case fmap words line of
      Just ["listening", port] -> action (read port)
      _ -> throwIO (userError ("the reference server did not start: " <> show line))

-- | The requests compared against the reference, in order (the webhook
-- deliveries build on one another: the second is a duplicate).
surface :: [(String, ByteString)]
surface =
  [ ("GET /healthz", plain "GET" "/healthz")
  , ("GET /healthz over HTTP/1.0", "GET /healthz HTTP/1.0\r\nhost: testserver\r\n\r\n")
  , ("GET /healthz kept alive, then closed", "GET /healthz HTTP/1.1\r\nhost: testserver\r\n\r\nGET /nope HTTP/1.1\r\nhost: testserver\r\nconnection: Keep-Alive, CLOSE\r\n\r\n")
  , ("HEAD /healthz", plain "HEAD" "/healthz")
  , ("POST /healthz", rawRequest "POST" "/healthz" [] "")
  , ("GET /healthz/", plain "GET" "/healthz/")
  , ("GET /healthz/?a=b%20c", plain "GET" "/healthz/?a=b%20c")
  , ("GET /health%7A", plain "GET" "/health%7A")
  , ("GET /", plain "GET" "/")
  , ("GET /nope", plain "GET" "/nope")
  , ("GET /nope/", plain "GET" "/nope/")
  , ("GET /openapi.json", plain "GET" "/openapi.json")
  , ("HEAD /openapi.json", plain "HEAD" "/openapi.json")
  , ("HEAD /docs", plain "HEAD" "/docs")
  , ("HEAD /docs/", plain "HEAD" "/docs/")
  , ("HEAD /nope", plain "HEAD" "/nope")
  , ("DELETE /redoc", plain "DELETE" "/redoc")
  , ("OPTIONS /healthz", plain "OPTIONS" "/healthz")
  , ("GET /HEALTHZ", plain "GET" "/HEALTHZ")
  , ("GET //healthz", plain "GET" "//healthz")
  , ("GET /healthz//", plain "GET" "/healthz//")
  , ("GET /healthz?x=1", plain "GET" "/healthz?x=1")
  , ("GET /caf%C3%A9/", plain "GET" "/caf%C3%A9/")
  , ("GET /docs", plain "GET" "/docs")
  , ("GET /docs/", plain "GET" "/docs/")
  , ("GET /redoc", plain "GET" "/redoc")
  , ("GET /docs/oauth2-redirect", plain "GET" "/docs/oauth2-redirect")
  , ("POST /docs", rawRequest "POST" "/docs" [] "")
  , ("GET /github/webhooks", plain "GET" "/github/webhooks")
  , ("PUT /github/webhooks", rawRequest "PUT" "/github/webhooks" [] "")
  , ("POST /github/webhooks/", webhook "/github/webhooks/" (signedWire envelope fixedDelivery "pull_request"))
  , ("POST accepted", webhook "/github/webhooks" (signedWire envelope fixedDelivery "pull_request"))
  , ("POST duplicate", webhook "/github/webhooks" (signedWire envelope fixedDelivery "pull_request"))
  , ("POST bad signature", webhookWith envelope (replace "x-hub-signature-256" "sha256=00" (signedWire envelope otherDelivery "pull_request")))
  , ("POST missing signature", webhookWith "{}" (filter ((/= "x-hub-signature-256") . fst) (signedWire "{}" otherDelivery "pull_request")))
  , ("POST not-json", webhookWith "not-json" (signedWire "not-json" otherDelivery "pull_request"))
  , ("POST text/plain", webhookWith envelope (replace "content-type" "text/plain" (signedWire envelope otherDelivery "pull_request")))
  , ("POST missing delivery", webhookWith envelope (filter ((/= "x-github-delivery") . fst) (signedWire envelope otherDelivery "pull_request")))
  , ("POST malformed delivery", webhookWith envelope (replace "x-github-delivery" "not-a-uuid" (signedWire envelope otherDelivery "pull_request")))
  , ("POST unknown event", webhookWith envelope (signedWire envelope otherDelivery "fork"))
  , ("POST non-ASCII detail", webhookWith envelope (replace "x-github-event" "\233v\233nement" (signedWire envelope otherDelivery "pull_request")))
  , ("POST at the body bound", webhookWith atBound (signedWire atBound otherDelivery "pull_request"))
  , ("POST lone surrogate", webhookWith surrogateAction (signedWire surrogateAction surrogateDelivery "pull_request"))
  , ("POST lone surrogate in a comment body", webhookWith surrogateComment (signedWire surrogateComment otherDelivery "issue_comment"))
  , ("POST over the body bound", webhookWith (BS.replicate 1048577 32) [])
  ]
  where
    plain method target = rawRequest method target [] ""
    webhook target headers = rawRequest "POST" target headers envelope
    webhookWith payload headers = rawRequest "POST" "/github/webhooks" headers payload
    atBound = BS.replicate 1048576 32
    replace name value =map (\(n, v) -> if n == name then (n, value) else (n, v))

fixedDelivery, otherDelivery, surrogateDelivery :: Text
fixedDelivery = "6f1e8a5c-0d3b-4c1e-9a7e-2b4d6c8e0f12"
otherDelivery = "0b9c4d2e-7a1f-4e3b-8c5d-9e2f1a3b4c5d"
surrogateDelivery = "5d800000-0000-4000-8000-000000000001"

-- | A @pull_request@ envelope whose action is the escape @"\\ud800"@.
surrogateAction :: ByteString
surrogateAction = BC.pack "{\"action\": \"\\ud800\", \"installation\": {\"id\": 44, \"account\": {\"id\": 23}}, \"repository\": {\"id\": 31, \"full_name\": \"owner/one\"}, \"pull_request\": {\"number\": 7}}"

-- | An @issue_comment@ envelope whose body holds the escape @"\\ud800"@.
surrogateComment :: ByteString
surrogateComment = commentEnvelope "9" "@hamster-dan \\ud800 why"

-- | The string CPython's @json.loads@ makes of @"\\ud800"@.
loneSurrogate :: Json
loneSurrogate = either error id (parseJson pythonLoads {loneSurrogates = KeepLoneSurrogates} (BC.pack "\"\\ud800\""))

signedWire :: ByteString -> Text -> Text -> [(ByteString, ByteString)]
signedWire payload delivery event =
  [(TE.encodeUtf8 n, BC.pack (T.unpack v)) | (n, v) <- signed payload delivery event, n /= "content-length"]
