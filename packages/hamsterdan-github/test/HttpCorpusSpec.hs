{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Replays @test/corpus/http.jsonl@ (scripts/gen_http_corpus.py): the
-- whole client stack (App JWT, installation-token minting and caching, the
-- HTTP cache, httpx's request and response handling, the bounded
-- transport and the registration check) over a scripted exchange with a
-- frozen clock. Every wire request must match the reference byte for byte
-- (method, URL, ordered headers, body), and every step must reach the
-- reference's outcome and metadata observations.
module HttpCorpusSpec (spec) where

import Control.Exception (Exception, SomeException, fromException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.Maybe (isJust)
import System.Environment (lookupEnv)
import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Corpus
import Hamsterdan.GitHub.Auth (githubAppClients, registrationInventory)
import Hamsterdan.GitHub.Client
import Hamsterdan.GitHub.Config (AccountConfig (..), HostConfig (..), secret)
import Hamsterdan.GitHub.Http (Exchange (..), HttpRequest (..), RawResponse (..), transportFailure)
import Hamsterdan.GitHub.Models
import Hamsterdan.GitHub.Python (PythonFault (..))
import Hamsterdan.GitHub.Transport qualified as Transport
import Petrus.Json (Json (..))
import Test.Hspec (Spec, describe, it, runIO)

spec :: Spec
spec = describe "HTTP client corpus" $ do
  rows <- runIO (readCorpus "http.jsonl")
  key <- runIO (TE.decodeUtf8 <$> BS.readFile "test/corpus/app-test-key.pem")
  it ("reproduces every wire request, outcome and observation (" <> show (length rows) <> " rows)") $ do
    mismatches <- newIORef []
    only <- lookupEnv "HTTP_CORPUS_ROW"
    forM_ (zip [0 :: Int ..] rows) $ \(index, row) ->
      when (maybe True ((== index) . read) only) $
        replay (isJust only) mismatches key ("row #" <> show index) row
    readIORef mismatches >>= expectNone

newtype Diverged = Diverged String
  deriving stock (Show)

instance Exception Diverged

latin1 :: Text -> BS.ByteString
latin1 = BS.pack . map (fromIntegral . fromEnum) . T.unpack

-- | The scripted network: each request must be the next recorded one.
scriptedExchange :: Bool -> IORef [Json] -> Exchange
scriptedExchange trace exchanges = Exchange $ \request continue -> do
  when trace $ putStrLn ("  request " <> show (request.method, request.url, request.headers))
  remaining <- readIORef exchanges
  (recorded, rest) <- case remaining of
    item : rest -> pure (item, rest)
    [] -> throwIO (Diverged ("unexpected request " <> show request))
  writeIORef exchanges rest
  let expected = field "request" recorded
      expectedHeaders = [(textOf k, textOf v) | Array [k, v] <- listOf (field "headers" expected)]
  unless (textOf (field "method" expected) == request.method && textOf (field "url" expected) == request.url) $
    throwIO (Diverged ("request line\n  expected " <> show (field "method" expected, field "url" expected) <> "\n  actual   " <> show (request.method, request.url)))
  unless (expectedHeaders == request.headers) $
    throwIO (Diverged ("request headers of " <> T.unpack request.url <> "\n  expected " <> show expectedHeaders <> "\n  actual   " <> show request.headers))
  unless (bodyMatches (field "body" expected) request.body) $
    throwIO (Diverged ("request body of " <> T.unpack request.url <> "\n  expected " <> show (field "body" expected) <> "\n  actual   " <> show request.body))
  case member "raise" recorded of
    Just (String name) -> throwIO (transportFailure name "scripted network failure")
    _ -> do
      let response = field "response" recorded
          chunks = filter (not . BS.null) (map chunkBytes (listOf (field "chunks" response)))
          failure = case field "failure" response of
            String message -> Just message
            _ -> Nothing
      pending <- newIORef chunks
      continue
        RawResponse
          { status = fromInteger (intOf (field "status" response))
          , headers = [(latin1 (textOf k), latin1 (textOf v)) | Array [k, v] <- listOf (field "headers" response)]
          , readChunk = do
              queued <- readIORef pending
              case queued of
                chunk : more -> writeIORef pending more >> pure chunk
                [] -> maybe (pure BS.empty) (throwIO . transportFailure "ReadError") failure
          }

bodyMatches :: Json -> BS.ByteString -> Bool
bodyMatches spec' actual = case member "b64" spec' of
  Just (String encoded) -> B64.decode (TE.encodeUtf8 encoded) == Right actual
  _ ->
    intOf (field "length" spec') == toInteger (BS.length actual)
      && textOf (field "sha256" spec') == T.pack (show (hashWith SHA256 actual))

chunkBytes :: Json -> BS.ByteString
chunkBytes spec' = case member "b64" spec' of
  Just (String encoded) -> either error id (B64.decode (TE.encodeUtf8 encoded))
  _ -> BS.replicate (fromInteger (intOf (field "length" spec'))) (fromInteger (intOf (field "fill" spec')))

-- | @{"repeat": text, "count": n}@ spells @text * n@.
expand :: Json -> Json
expand = \case
  Object [("repeat", String text), ("count", Int n)] -> String (T.replicate (fromInteger n) text)
  Object members -> Object [(k, expand v) | (k, v) <- members]
  Array items -> Array (map expand items)
  other -> other

-- | Replay one row; @trace@ prints every request and step outcome (set
-- @HTTP_CORPUS_ROW@ to a row index to trace that row alone).
replay :: Bool -> Mismatches -> Text -> String -> Json -> IO ()
replay trace mismatches key context row = do
  clock <- newIORef (number (field "start" row))
  exchanges <- newIORef (listOf (field "exchanges" row))
  observations <- newIORef []
  let options =
        ClientOptions
          { exchange = scriptedExchange trace exchanges
          , clock = readIORef clock
          , metadataHook = if boolOf (field "hook" row) then Just (\m -> modifyIORef' observations (m :)) else Nothing
          }
      config =
        HostConfig
          { appId = 17
          , appSlug = "hamster-dan"
          , clientId = "Iv1.corpus"
          , accounts = [AccountConfig {accountId = 23, accountLogin = "Owner", repositories = [(31, "owner/one")]}]
          , statePath = "/nonexistent/state"
          , watchedAuthors = Set.empty
          , privateKey = secret key
          , webhookSecret = secret "corpus-secret"
          }
  clients <- githubAppClients config options
  let steps = zip3 [0 :: Int ..] (listOf (field "steps" row)) (listOf (field "results" row))
  outcome <- try $ forM_ steps $ \(index, step, result) -> case textOf (field "op" step) of
    "clock" -> modifyIORef' clock (+ number (field "advance" step))
    _ -> do
      before <- length <$> readIORef exchanges
      writeIORef observations []
      actual <- try (runStep clients config step)
      after <- length <$> readIORef exchanges
      seen <- reverse <$> readIORef observations
      let where' = context <> " step " <> show index <> " " <> T.unpack (canonical step)
      when trace $ putStrLn (where' <> "\n  -> " <> T.unpack (actualOutcome actual))
      case actual of
        Left e | Just (Diverged detail) <- fromException e -> throwIO (Diverged (where' <> ": " <> detail))
        _ -> pure ()
      check mismatches (where' <> " outcome") (expectedOutcome result) (actualOutcome actual)
      check mismatches (where' <> " exchanges") (intOf (field "exchanges" result)) (toInteger (before - after))
      checkJson mismatches (where' <> " observations") (field "observations" result) (Array (map observationJson seen))
  case outcome of
    Left (Diverged detail) -> check mismatches (context <> " diverged") "" detail
    Right () -> do
      remaining <- readIORef exchanges
      check mismatches (context <> " unconsumed exchanges") 0 (length remaining)

number :: Json -> Double
number = \case
  Int n -> fromInteger n
  Float d -> d
  other -> error ("corpus: expected a number, got " <> show other)

observationJson :: RequestMetadata -> Json
observationJson m =
  Object
    [ ("method", String m.method)
    , ("path", String m.path)
    , ("request_id", maybe Null String m.requestId)
    , ("rate_limit_remaining", maybe Null Int m.rateLimitRemaining)
    , ("rate_limit_reset", maybe Null Int m.rateLimitReset)
    , ("status", Int (toInteger m.status))
    ]

clientOf :: AppClients -> Json -> GitHubClient
clientOf clients = \case
  Array [String "app"] -> appClient clients
  Array [String "installation", Int installation, Array ids] ->
    either (error . T.unpack) id (installationClient clients installation (map intOf ids))
  Array [String "inventory", Int installation] -> either (error . T.unpack) id (inventoryClient clients installation)
  other -> error ("corpus: client " <> show other)

runStep :: AppClients -> HostConfig -> Json -> IO Json
runStep clients config step = case textOf (field "op" step) of
  "registration" -> do
    RegistrationInventory installations <- registrationInventory clients config
    pure $
      Array
        [ Object
            [ ("installation_id", Int item.installationId)
            , ("account_id", Int item.accountId)
            , ("repositories", Array [Array [Int i, String n] | (i, n) <- item.repositories])
            ]
        | item <- installations
        ]
  "request" -> do
    let body = case expand (field "body" step) of
          Object members -> Just members
          _ -> Nothing
    response <- Transport.request client (textOf (field "method" step)) (textOf (field "path" step)) body
    pure (Object [("status", Int (toInteger response.status)), ("body", response.body), ("next_path", maybe Null String response.nextPath)])
  "download" -> do
    bytes <- Transport.download client (textOf (field "path" step)) (fromInteger (intOf (field "limit" step)))
    pure (Object [("length", Int (toInteger (BS.length bytes))), ("b64", String (TE.decodeUtf8 (B64.encode (BS.take 4096 bytes))))])
  "pages" -> Array . map Object <$> Transport.pages client (textOf (field "path" step))
  other -> error ("corpus: op " <> show other)
  where
    client = clientOf clients (field "client" step)

-- | The recorded outcome; the messages of CPython faults are not compared.
expectedOutcome :: Json -> Text
expectedOutcome result = canonical $ case member "error" result of
  Just failure
    | textOf (field "class" failure) `notElem` ["GitHubBoundaryError", "RuntimeError"] ->
        Object [("error", Object [("class", field "class" failure)])]
    | otherwise -> Object [("error", failure)]
  Nothing -> Object [("ok", field "ok" result)]

actualOutcome :: Either SomeException Json -> Text
actualOutcome = \case
  Right value -> canonical (Object [("ok", value)])
  Left e
    | Just (failure :: GitHubBoundaryError) <- fromException e ->
        canonical $
          Object
            [ ( "error"
              , Object
                  [ ("class", String "GitHubBoundaryError")
                  , ("message", String failure.message)
                  , ("failure_class", String (failureClassName failure.failureClass))
                  , ("provider_status", maybe Null (Int . toInteger) failure.providerStatus)
                  , ("provider_detail", String failure.providerDetail)
                  ]
              )
            ]
    | Just (ContractRefused message) <- fromException e ->
        canonical (Object [("error", Object [("class", String "RuntimeError"), ("message", String message)])])
    | Just (PythonFault cls _) <- fromException e -> canonical (Object [("error", Object [("class", String cls)])])
    | otherwise -> canonical (Object [("error", Object [("class", String "HaskellException"), ("detail", String (T.pack (show e)))])])
