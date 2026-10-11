{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Hot-path benchmarks for hamsterdan-github; bench.py runs the same
-- operations on the same inputs (bench/inputs.json) in the pinned Python.
--
-- > cabal bench hamsterdan-github
--
-- Results and the comparison with Python are in RESULTS.md.
module Main (main) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.GitHub.Auth (githubAppClients)
import Hamsterdan.GitHub.Client (ClientOptions (..), installationClient)
import Hamsterdan.GitHub.Config (AccountConfig (..), HostConfig (..), secret)
import Hamsterdan.GitHub.Effects qualified as E
import Hamsterdan.GitHub.Gateway qualified as G
import Hamsterdan.GitHub.Http (Exchange (..), HttpRequest (..), RawResponse (..))
import Hamsterdan.GitHub.Jwt (appJwt, loadSigningKey)
import Hamsterdan.GitHub.Models
import Hamsterdan.GitHub.Transport qualified as Transport
import Hamsterdan.GitHub.Webhooks (Observation (..), Receipt (..), closeCustody, defaultCustodyOptions, dispositionName, encodeObservation, openCustody, parseObservation, receive, sign, verifier, verify, verifyWith)
import Numeric (showHex)
import Petrus.Json (Json (..), parseJson, pythonLoads)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (localOption)
import Test.Tasty.Bench

secretText :: Text
secretText = "bench-secret"

delivery :: Text
delivery = "3f0c1a52-4b7e-4c71-9a10-000000000001"

-- | Deeply evaluate a JSON value.
forceJson :: Json -> ()
forceJson = \case
  Array items -> foldr (seq . forceJson) () items
  Object members -> foldr (\(k, v) rest -> k `seq` forceJson v `seq` rest) () members
  other -> other `seq` ()

forceObservation :: Observation -> ()
forceObservation o =
  foldr
    seq
    ()
    [ forceJson o.action
    , forceJson o.installationId
    , forceJson o.accountId
    , forceJson o.repositoryId
    , forceJson o.repositoryFullName
    , forceJson o.pullRequestNumber
    , forceJson o.commentId
    , maybe () (`seq` ()) o.commentBody
    , forceJson o.actorId
    , forceJson o.actorLogin
    , forceJson o.actorType
    , forceJson o.authorAssociation
    , foldr (\(a, b) rest -> forceJson a `seq` forceJson b `seq` rest) () o.repositories
    ]

forceSnapshot :: PullRequestSnapshot -> ()
forceSnapshot s = foldr seq () [s.head `seq` (), s.base `seq` (), s.author `seq` (), forceJson s.mergeable, s.url `seq` ()]

-- | @str(uuid.UUID(int=n))@.
uuidOf :: Int -> Text
uuidOf n =
  let hex = T.justifyRight 32 '0' (T.pack (showHex n ""))
      (a, r1) = T.splitAt 8 hex
      (b, r2) = T.splitAt 4 r1
      (c, r3) = T.splitAt 4 r2
      (d, e) = T.splitAt 4 r3
   in T.intercalate "-" [a, b, c, d, e]

field :: Text -> Json -> Json
field key = \case
  Object members | Just value <- lookup key members -> value
  _ -> error ("bench/inputs.json: missing " <> T.unpack key)

textOf :: Json -> Text
textOf = \case
  String text -> text
  other -> error ("bench/inputs.json: expected text, got " <> show other)

objectOf :: Json -> [(Text, Json)]
objectOf = \case
  Object members -> members
  other -> error ("bench/inputs.json: expected an object, got " <> show other)

-- | A network that answers every token request and every GET with fixed
-- bodies, as the Python side's @httpx.MockTransport@ does.
benchExchange :: ByteString -> Exchange
benchExchange pullBody = Exchange $ \request continue -> do
  let (status, headers, body)
        | "/access_tokens" `T.isSuffixOf` request.target =
            (201, [("content-type", "application/json")], "{\"token\":\"ghs_bench\",\"expires_at\":\"2099-01-01T00:00:00Z\"}")
        | otherwise =
            ( 200
            , [("content-type", "application/json; charset=utf-8"), ("cache-control", "no-store"), ("x-github-request-id", "R")]
            , pullBody
            )
  pending <- newIORef [body]
  continue
    RawResponse
      { status
      , headers = headers <> [("content-length", BS8.pack (show (BS.length body)))]
      , readChunk = atomicModifyIORef' pending (\case [] -> ([], ""); chunk : rest -> (rest, chunk))
      }

main :: IO ()
main = withSystemTempDirectory "hamsterdan-bench" $ \state -> do
  inputs <- either fail pure . parseJson pythonLoads =<< BS.readFile "bench/inputs.json"
  key <- TE.decodeUtf8 <$> BS.readFile "test/corpus/app-test-key.pem"
  let webhookBody = TE.encodeUtf8 (textOf (field "webhook_body" inputs))
      pullBody = TE.encodeUtf8 (textOf (field "pull_body" inputs))
      pullValue = either error id (parseJson pythonLoads pullBody)
      comments = case field "comments" inputs of
        Array items -> map objectOf items
        _ -> error "bench/inputs.json: comments"
      headSha = textOf (field "head" inputs)
      signature = sign secretText webhookBody
      parsed = either (error . show) id (parseObservation delivery "issue_comment" webhookBody)
      keyed = verifier secretText
      signingKey = either (error . T.unpack) id (loadSigningKey key)
  custody <- openCustody (state <> "/inbox.db") secretText (defaultCustodyOptions (pure 1760000000))
  counter <- newIORef (0 :: Int)
  let receiveFresh = do
        n <- atomicModifyIORef' counter (\i -> (i + 1, i))
        receive
          custody
          [ ("content-length", T.pack (show (BS.length webhookBody)))
          , ("content-type", "application/json")
          , ("x-hub-signature-256", signature)
          , ("x-github-delivery", uuidOf n)
          , ("x-github-event", "issue_comment")
          ]
          webhookBody
  let config =
        HostConfig
          { appId = 17
          , appSlug = "hamster-dan"
          , clientId = "Iv1.bench"
          , accounts = [AccountConfig {accountId = 23, accountLogin = "Owner", repositories = [(31, "owner/one")]}]
          , statePath = state <> "/state.db"
          , watchedAuthors = Set.empty
          , privateKey = secret key
          , webhookSecret = secret secretText
          }
  clients <- githubAppClients config ClientOptions {exchange = benchExchange pullBody, clock = pure 1760000000, metadataHook = Nothing}
  let installation = either (error . T.unpack) id (installationClient clients 44 [31])
  _ <- Transport.request installation "GET" "/repos/owner/one/pulls/7" Nothing -- mint the token once
  let fake =
        Transport
          { request = \method path _ -> case (method, path) of
              ("GET", "/repos/owner/repo/pulls/7") -> pure (WireResponse 200 pullValue Nothing)
              ("GET", "/repos/owner/repo/git/ref/heads/main") ->
                pure (WireResponse 200 (Object [("object", Object [("sha", String (T.replicate 40 "b"))])]) Nothing)
              _ -> error ("unexpected " <> show (method, path))
          , pages = \path ->
              if path == "/repos/owner/repo/issues/7/comments?per_page=100"
                then pure comments
                else error ("unexpected pages " <> show path)
          }
      authority = either (error . show) id (G.githubAuthority fake "owner/repo" 7 Nothing)
      publisher = either (error . show) id (E.commentPublisher fake "owner/repo" 7 "hamster-dan[bot]" (\_ _ _ _ _ -> pure ()) Nothing (\_ -> pure ()))
      lastBody = "Finding 99: the dashboard and the gate disagree about readiness."
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain . map (localOption WallTime) $
    [ bench "webhook verify (HMAC-SHA256, 10 KB)" $ nf (verifyWith keyed webhookBody) signature
    , bench "webhook verify, key state per call" $ nf (verify secretText webhookBody) signature
    , bench "webhook parse (issue_comment, 10 KB)" $
        nf (either (const ()) forceObservation . parseObservation delivery "issue_comment") webhookBody
    , bench "observation encode (sorted JSON)" $ nf (either (const Nothing) Just . encodeObservation) parsed
    , bench "webhook receive (verify, parse, SQLite insert)" $ whnfIO (dispositionName . (.disposition) <$> receiveFresh)
    , bench "App JWT mint (RS256, PEM key)" $ nf (\pem -> either (const "") (\k -> either (const "") id (appJwt k "17" 1760000000)) (loadSigningKey pem)) key
    , bench "App JWT sign (RS256, parsed key)" $ nf (\now -> either (const "") id (appJwt signingKey "17" now)) 1760000000
    , bench "installation GET pull (cached token, mock network)" $
        whnfIO ((\response -> forceJson response.body `seq` response.status) <$> Transport.request installation "GET" "/repos/owner/one/pulls/7" Nothing)
    , bench "gateway pull_request snapshot" $ whnfIO (forceSnapshot <$> G.pullRequest authority)
    , bench "publisher lookup hit (100 comments)" $
        whnfIO ((.status) <$> E.immutable publisher "finding" "op-099" 1 headSha lastBody Nothing [])
    ]
  closeCustody custody
