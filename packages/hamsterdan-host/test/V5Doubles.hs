-- | The @V5Provider@ GitHub double of @tests/integration/host/test_service.py@
-- (plus comment edits), the clear-review runner, and the host composition
-- over them: shared by the state interop tests and the benchmarks, the same
-- doubles @differential/state_reference.py@ and @bench/bench.py@ use.
module V5Doubles
  ( Provider (..)
  , newProvider
  , providerTransport
  , baseSha
  , pullRequest
  , noReviewThreads
  , newComment
  , editComment
  , doublesConfig
  , doubleClients
  , clearRunner
  , signedHeaders
  , activate
  ) where

import Control.Exception (throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Agents.Protocol (AgentRunner (..), Invocation (..), ReviewRequest (..), ReviewResult (..))
import Hamsterdan.GitHub.Config (AccountConfig (..), HostConfig (..), secret)
import Hamsterdan.GitHub.Models (Transport (..), WireResponse (..))
import Hamsterdan.GitHub.Webhooks (sign)
import Control.Monad (unless)
import Hamsterdan.GitHub.Routing qualified as Routing
import Hamsterdan.Host.Service (HostClients (..), HostService (..))
import Petrus.Impetus.Instance.FailureText (PythonException (..))
import Petrus.Json (Json (..))

-- | The provider's mutable state: the PR head, the calls it saw, and the
-- comments on the PR.
data Provider = Provider
  { head :: IORef Text
  , calls :: IORef [Json]
  , comments :: IORef [[(Text, Json)]]
  }

baseSha :: Text
baseSha = T.replicate 40 "b"

-- | PR 7 of @owner/one@: open, clean, at the given head.
pullRequest :: Text -> Json
pullRequest headSha =
  Object
    [ ("state", String "open")
    , ("draft", Bool False)
    , ("mergeable", Bool True)
    , ("mergeable_state", String "clean")
    , ("merged", Bool False)
    , ("html_url", String "https://example.test/owner/one/pull/7")
    , ("user", Object [("login", String "author")])
    , ("head", Object [("sha", String headSha), ("ref", String "feature"), ("repo", Object [("full_name", String "owner/one")])])
    , ("base", Object [("sha", String baseSha), ("ref", String "main")])
    ]

noReviewThreads :: Json
noReviewThreads =
  Object
    [ ( "data"
      , Object
          [ ( "repository"
            , Object
                [ ( "pullRequest"
                  , Object
                      [ ( "reviewThreads"
                        , Object
                            [ ("nodes", Array [])
                            , ("pageInfo", Object [("hasNextPage", Bool False), ("endCursor", Null)])
                            ]
                        )
                      ]
                  )
                ]
            )
          ]
      )
    ]

-- | The comment the App posts as comment number @identifier@.
newComment :: Integer -> [(Text, Json)] -> [(Text, Json)]
newComment identifier members =
  [ ("id", Int identifier)
  , ("html_url", String ("https://example.test/comments/" <> T.pack (show identifier)))
  , ("body", maybe (String "") id (lookup "body" members))
  , ("user", Object [("login", String "hamsterdan-test[bot]")])
  ]

-- | A comment after the App edits comment @identifier@.
editComment :: Json -> [(Text, Json)] -> [(Text, Json)] -> [(Text, Json)]
editComment identifier members comment
  | lookup "id" comment == Just identifier =
      [(k, if k == "body" then maybe (String "") id (lookup "body" members) else v) | (k, v) <- comment]
  | otherwise = comment

-- | @V5Provider@ of @state_reference.py@ (the @test_service.py@ double
-- plus comment edits).
providerTransport :: Provider -> Transport
providerTransport provider =
  Transport
    { request = \method path body -> do
        record [method, path]
        headSha <- readIORef provider.head
        answer headSha method path body
    , pages = \path -> do
        record ["PAGES", path]
        if path == "/repos/owner/one/issues/7/comments?per_page=100"
          then readIORef provider.comments
          else pure []
    }
  where
    record parts = modifyIORef' provider.calls (<> [Array (map String parts)])
    ok value = pure (WireResponse 200 value Nothing)
    answer headSha method path body = case (method, path) of
      ("GET", "/repos/owner/one/pulls/7") -> ok (pullRequest headSha)
      ("GET", "/repos/owner/one/git/ref/heads/main") -> ok (Object [("object", Object [("sha", String baseSha)])])
      ("GET", "/repos/owner/one/rules/branches/main") -> pure (WireResponse 404 (Object []) Nothing)
      ("GET", "/repos/owner/one/branches/main/protection") -> pure (WireResponse 404 (Object []) Nothing)
      ("GET", p)
        | p == "/repos/owner/one/compare/" <> baseSha <> "..." <> headSha ->
            ok (Object [("status", String "ahead"), ("behind_by", Int 0)])
      ("GET", "/repos/owner/one/pulls/7/requested_reviewers") -> ok (Object [("users", Array [])])
      ("GET", p)
        | "/repos/owner/one/actions/workflows/.github%2Fworkflows%2Fci.yml/runs?" `T.isPrefixOf` p ->
            ok (Object [("total_count", Int 0), ("workflow_runs", Array [])])
      ("POST", "/graphql") -> ok noReviewThreads
      ("POST", "/repos/owner/one/issues/7/comments")
        | Just members <- body -> do
            n <- length <$> readIORef provider.comments
            let comment = newComment (toInteger n + 1) members
            modifyIORef' provider.comments (<> [comment])
            pure (WireResponse 201 (Object comment) Nothing)
      ("PATCH", p)
        | Just identifierText <- T.stripPrefix "/repos/owner/one/issues/comments/" p
        , Just members <- body -> do
            let identifier = Int (read (T.unpack identifierText))
            modifyIORef' provider.comments (map (editComment identifier members))
            found <- find (\comment -> lookup "id" comment == Just identifier) <$> readIORef provider.comments
            case found of
              Just comment -> ok (Object comment)
              Nothing -> throwIO (PythonException "AssertionError" [])
      _ -> throwIO (PythonException "AssertionError" [])

newProvider :: Text -> [[(Text, Json)]] -> IO Provider
newProvider sha comments = Provider <$> newIORef sha <*> newIORef [] <*> newIORef comments

-- | @config(root)@ of @state_reference.py@ with the given App private key.
doublesConfig :: FilePath -> Text -> HostConfig
doublesConfig root key =
  HostConfig
    { appId = 17
    , appSlug = "hamsterdan-test"
    , clientId = "Iv1.client-secret-looking"
    , accounts = [AccountConfig 23 "Owner" [(31, "owner/one"), (32, "owner/two")]]
    , statePath = root
    , watchedAuthors = mempty
    , privateKey = secret key
    , webhookSecret = secret "hook-secret"
    }

-- | @Clients@: every installation client is the given transport.
doubleClients :: Transport -> HostClients
doubleClients transport =
  HostClients
    { registrationInventory = \_ -> throwIO (PythonException "AssertionError" [])
    , installation = \_ _ -> pure transport
    , close = pure ()
    }

-- | @V5Runner@: every review is clear; each review is recorded as
-- @[repository_url, head, operation, attempt]@.
clearRunner :: IORef [Json] -> AgentRunner
clearRunner reviews =
  AgentRunner
    { review = \url request inv -> do
        modifyIORef' reviews (<> [Array [String url, String request.head, String inv.operation, Int inv.attempt]])
        pure (ReviewResult request.repository request.pullRequest request.epoch request.head request.base "clear" [] [])
    , converse = \_ _ _ -> throwIO (PythonException "AttributeError" [])
    , code = \_ _ _ -> throwIO (PythonException "AttributeError" [])
    }

-- | @signed(body, delivery, event)@ plus @content-length@.
signedHeaders :: ByteString -> Text -> Text -> [(Text, Text)]
signedHeaders body delivery event =
  [ ("content-type", "application/json")
  , ("x-hub-signature-256", sign "hook-secret" body)
  , ("x-github-delivery", delivery)
  , ("x-github-event", event)
  , ("content-length", T.pack (show (BS.length body)))
  ]

-- | @activate_repositories(host, ((31, "owner/one"),))@.
activate :: HostService -> IO ()
activate host = do
  created <- Routing.installation host.registry (String "created") (Int 44) (Int 23)
  added <- Routing.repositories host.registry (String "added") (Int 44) (Int 23) [(Int 31, String "owner/one")]
  unless (created && added) $ throwIO (PythonException "AssertionError" [])
