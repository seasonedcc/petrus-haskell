{-# LANGUAGE RecordWildCards #-}

-- | The fakes of @tests/integration/host/test_service.py@: the GitHub
-- clients, the recording application, the V5 provider, and the helpers
-- that sign, stage, and inspect custodied deliveries.
module ServiceSupport
  ( -- * Clients
    FakeClients (..)
  , newFakeClients
  , hostClientsOf
  , registrationClients

    -- * The recording application
  , FakeApp (..)
  , fakeSettle
  , fakeFactory
  , fakeHostApplication
  , made

    -- * The service
  , Harness (..)
  , HarnessOptions (..)
  , defaults
  , harness
  , hostConfig
  , activateRepositories
  , bindApplication
  , suspend

    -- * Observations and deliveries
  , observationAt
  , observationOf
  , commentOf
  , envelope
  , envelopeAt
  , signed
  , receiveSigned
  , commentEnvelope

    -- * The inbox
  , sqlRows
  , sqlExec
  , insertPending
  , inboxReason

    -- * The V5 provider
  , V5Provider (..)
  , newV5Provider
  , providerTransport
  , v5Runner

    -- * Activities
  , dummyContext
  , invocationOf
  , assertionError
  ) where

import Control.Exception (SomeException, bracket, throwIO)
import Control.Monad (forM_, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.SQLite3 qualified as S
import Hamsterdan.Agents.Protocol (AgentRunner (..))
import Hamsterdan.Contracts.Readiness (AdmittedConversation (..))
import Hamsterdan.GitHub.Config (AccountConfig (..), HostConfig (..), secret)
import Hamsterdan.GitHub.Gateway (GitHubAuthority (..))
import Hamsterdan.GitHub.Models
import Hamsterdan.GitHub.Routing qualified as Routing
import Hamsterdan.GitHub.Webhooks (Observation (..), Receipt, encodeObservation, observation, sign)
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Binding (ensureInstanceBinding)
import Hamsterdan.Host.Python (RuntimeError (..))
import Hamsterdan.Host.Service
import Hamsterdan.Host.V5.Application (ApplicationOptions (..))
import Hamsterdan.Readiness.NetV5.Gating (GateDefinition)
import IngressApplicationSpec (reviewClear)
import Petrus.Activity (ActivityExecutionContext (..), ActivityInvocation, invocation)
import Petrus.TestSupport (valid)
import Petrus.Impetus.Instance.FailureText (PythonException (..))
import Petrus.Json (Json (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath (splitDirectories)

-- ---------------------------------------------------------------------------
-- Clients

-- | @Clients@: the operation client records its requests; registration
-- inventory is configured per test.
data FakeClients = FakeClients
  { operationCalls :: IORef [(Integer, [Integer])]
  , operationRequests :: IORef [(Text, Text)]
  , registration :: IORef (Maybe (Either SomeException RegistrationInventory))
  , closed :: IORef Int
  , operationTransport :: IORef (Maybe Transport)
  -- ^ When set, the installation client answers with this transport.
  }

newFakeClients :: IO FakeClients
newFakeClients = FakeClients <$> newIORef [] <*> newIORef [] <*> newIORef Nothing <*> newIORef 0 <*> newIORef Nothing

registrationClients :: [(Integer, Text)] -> IO FakeClients
registrationClients repositories = do
  clients <- newFakeClients
  writeIORef clients.registration (Just (Right (RegistrationInventory [InstallationInventory 44 23 repositories])))
  pure clients

-- | The default operation client: every request answers @{}@.
recordingTransport :: FakeClients -> Transport
recordingTransport clients =
  Transport
    { request = \method path _ -> do
        modifyIORef' clients.operationRequests (<> [(method, path)])
        pure (WireResponse 200 (Object []) Nothing)
    , pages = \path -> do
        modifyIORef' clients.operationRequests (<> [("PAGES", path)])
        pure []
    }

hostClientsOf :: FakeClients -> HostClients
hostClientsOf clients =
  HostClients
    { registrationInventory = \_ ->
        readIORef clients.registration >>= \case
          Nothing -> throwIO (PythonException "AssertionError" [])
          Just (Left failure) -> throwIO failure
          Just (Right inventory) -> pure inventory
    , installation = \installationId repositoryIds -> do
        modifyIORef' clients.operationCalls (<> [(installationId, repositoryIds)])
        maybe (recordingTransport clients) id <$> readIORef clients.operationTransport
    , close = modifyIORef' clients.closed (+ 1)
    }

-- ---------------------------------------------------------------------------
-- The recording application

-- | @Application@: what the factory received, what the host asked of it,
-- and per-method overrides (the reference's subclasses).
data FakeApp = FakeApp
  { root :: FilePath
  , instanceId :: Text
  , authority :: GitHubAuthority
  , runner :: AgentRunner
  , options :: ApplicationOptions
  , fails :: Bool
  , reconciles :: IORef [Text]
  , observations :: IORef [Observation]
  , durableRuns :: IORef Int
  , comments :: IORef [AdmittedConversation]
  , closed :: IORef Int
  , settlements :: IORef Int
  , onSettle :: IORef (IO ())
  , onReconcile :: IORef (Text -> IO Bool)
  , onProcess :: IORef (Observation -> Maybe AdmittedConversation -> IO ())
  , onRunDurable :: IORef (Int -> IO Int)
  , onStop :: IORef (IO ())
  , onClose :: IORef (IO ())
  , onActivity :: IORef (Text -> IO (Maybe GateDefinition))
  }

secretFailure :: IO a
secretFailure = throwIO (RuntimeError "provider secret must not escape")

-- | @self.settle()@ through any override.
fakeSettle :: FakeApp -> IO ()
fakeSettle app = do
  modifyIORef' app.settlements (+ 1)
  readIORef app.onSettle >>= id

newFakeApp :: FilePath -> Text -> GitHubAuthority -> AgentRunner -> ApplicationOptions -> Bool -> IO FakeApp
newFakeApp root instanceId authority runner options fails = do
  reconciles <- newIORef []
  observations <- newIORef []
  durableRuns <- newIORef 0
  comments <- newIORef []
  closed <- newIORef 0
  settlements <- newIORef 0
  onSettle <- newIORef (pure ())
  onReconcile <- newIORef (\_ -> pure True)
  onProcess <- newIORef (\_ _ -> pure ())
  onRunDurable <- newIORef (\_ -> pure 0)
  onStop <- newIORef (pure ())
  onClose <- newIORef (pure ())
  onActivity <- newIORef (\_ -> throwIO (PythonException "AttributeError" []))
  let app = FakeApp {..}
  writeIORef onReconcile $ \reason -> do
    modifyIORef' reconciles (<> [reason])
    when fails secretFailure
    pure True
  writeIORef onProcess $ \item conversation -> do
    fakeSettle app
    modifyIORef' observations (<> [item])
    modifyIORef' reconciles (<> ["github-delivery:" <> item.deliveryId])
    when fails secretFailure
    forM_ conversation $ \c -> modifyIORef' comments (<> [c])
  writeIORef onRunDurable $ \_ -> do
    modifyIORef' durableRuns (+ 1)
    pure 0
  writeIORef onClose (modifyIORef' closed (+ 1))
  pure app

-- | The host protocol over the recording application.
fakeHostApplication :: FakeApp -> HostApplication
fakeHostApplication app =
  HostApplication
    { processObservation = \item conversation -> readIORef app.onProcess >>= \f -> f item conversation
    , reconcile = \reason -> readIORef app.onReconcile >>= \f -> f reason
    , settle = Nothing <$ fakeSettle app
    , activity = \name -> readIORef app.onActivity >>= \f -> f name
    , hasUnresolvedPublication = pure False
    , runDurableActivities = \limit -> readIORef app.onRunDurable >>= \f -> f limit
    , stopDurableActivities = readIORef app.onStop >>= id
    , detachedState = pure Null
    , close = readIORef app.onClose >>= id
    , v5 = Nothing
    }

-- | A factory appending each application to a list; the predicate on the
-- number already made selects @fail=True@, and the customization stands
-- for the reference's subclasses.
fakeFactory :: IORef [FakeApp] -> (Int -> Bool) -> (FakeApp -> IO ()) -> ApplicationFactory
fakeFactory list failing customize root instanceId authority runner options = do
  count <- length <$> readIORef list
  app <- newFakeApp root instanceId authority runner options (failing count)
  customize app
  modifyIORef' list (<> [app])
  pure (fakeHostApplication app)

made :: Harness -> IO [FakeApp]
made h = readIORef h.apps

-- ---------------------------------------------------------------------------
-- The service

data Harness = Harness
  { host :: HostService
  , apps :: IORef [FakeApp]
  , clients :: FakeClients
  }

data HarnessOptions = HarnessOptions
  { failing :: Int -> Bool
  , customize :: FakeApp -> IO ()
  , watchedAuthors :: Set Text
  , transportFactory :: Maybe (Transport -> Transport)
  , configure :: ServiceOptions -> ServiceOptions
  , givenClients :: Maybe FakeClients
  , factory :: Maybe ApplicationFactory
  , reconcileRegistry :: Bool
  , repositories :: [(Integer, Text)]
  }

defaults :: HarnessOptions
defaults =
  HarnessOptions
    { failing = const False
    , customize = \_ -> pure ()
    , watchedAuthors = Set.empty
    , transportFactory = Nothing
    , configure = id
    , givenClients = Nothing
    , factory = Nothing
    , reconcileRegistry = True
    , repositories = [(31, "owner/one"), (32, "owner/two")]
    }

objectRunner :: AgentRunner
objectRunner =
  AgentRunner
    { review = \_ _ _ -> attributeError
    , converse = \_ _ _ -> attributeError
    , code = \_ _ _ -> attributeError
    }
  where
    attributeError = throwIO (PythonException "AttributeError" [])

hostConfig :: FilePath -> [(Integer, Text)] -> Set Text -> HostConfig
hostConfig root repositories watchedAuthors =
  HostConfig
    { appId = 17
    , appSlug = "hamsterdan-test"
    , clientId = "Iv1.client-secret-looking"
    , accounts = [AccountConfig 23 "Owner" repositories]
    , statePath = root
    , watchedAuthors
    , privateKey = secret "private-key-secret"
    , webhookSecret = secret "hook-secret"
    }

-- | @service(root, ...)@: the host over recording fakes, with installation
-- 44 reconciled for both repositories (unless disabled).
harness :: FilePath -> HarnessOptions -> IO Harness
harness root given = do
  apps <- newIORef []
  clients <- maybe newFakeClients pure given.givenClients
  let factory = maybe (fakeFactory apps given.failing given.customize) id given.factory
      options =
        given.configure
          (serviceOptions objectRunner noAgentCustody)
            { clients = Just (hostClientsOf clients)
            , applicationFactory = factory
            , transportFactory = given.transportFactory
            }
  host <- openHostService (hostConfig root given.repositories given.watchedAuthors) options
  when given.reconcileRegistry $
    () <$ Routing.reconcile host.registry [InstallationInventory 44 23 [(31, "owner/one"), (32, "owner/two")]]
  pure Harness {host, apps, clients}

-- | @activate_repositories(host, repositories)@.
activateRepositories :: HostService -> [(Integer, Text)] -> IO ()
activateRepositories host repositories = do
  created <- Routing.installation host.registry (String "created") (Int 44) (Int 23)
  added <- Routing.repositories host.registry (String "added") (Int 44) (Int 23) [(Int i, String n) | (i, n) <- repositories]
  when (not created || not added) $ throwIO (PythonException "AssertionError" [])

-- | @bind_application(root, repository)@ plus an empty History.
bindApplication :: FilePath -> Text -> IO ()
bindApplication root repository = do
  (i, r, p) <- case map read (reverse (take 3 (reverse (splitDirectories root)))) :: [Integer] of
    [a, b, c] -> pure (a, b, c)
    _ -> assertionError
  createDirectoryIfMissing True root
  _ <- ensureInstanceBinding root ("github:" <> tshow i <> ":" <> tshow r <> ":pr:" <> tshow p) repository p
  BS.writeFile (root <> "/history.jsonl") ""

suspend :: HostService -> IO ()
suspend host = () <$ Routing.installation host.registry (String "suspend") (Int 44) (Int 23)

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- Observations and deliveries

-- | @observation(delivery, repository, pr)@.
observationAt :: Text -> Integer -> Integer -> Observation
observationAt delivery repository pr =
  (observation delivery "pull_request")
    { action = String "synchronize"
    , installationId = Int 44
    , accountId = Int 23
    , repositoryId = Int repository
    , repositoryFullName = String (if repository == 31 then "owner/one" else "owner/two")
    , pullRequestNumber = Int pr
    }

observationOf :: Text -> Observation
observationOf delivery = observationAt delivery 31 7

-- | An @issue_comment@ observation on PR 7 from a given actor.
commentOf :: Text -> Text -> Text -> Text -> Observation
commentOf delivery body login association =
  (observationOf delivery)
    { event = "issue_comment"
    , action = String "created"
    , commentBody = Just body
    , actorLogin = String login
    , actorType = String "User"
    , authorAssociation = String association
    }

envelope :: ByteString
envelope = envelopeAt 31 7

envelopeAt :: Integer -> Integer -> ByteString
envelopeAt repository pr =
  TE.encodeUtf8 $
    "{\"action\": \"synchronize\", \"installation\": {\"id\": 44, \"account\": {\"id\": 23}}, \"repository\": {\"id\": "
      <> tshow repository
      <> ", \"full_name\": \"owner/one\"}, \"pull_request\": {\"number\": "
      <> tshow pr
      <> "}}"

-- | An @issue_comment@ envelope on PR 7.
commentEnvelope :: Text -> Text -> ByteString
commentEnvelope commentId body =
  TE.encodeUtf8 $
    "{\"action\": \"created\", \"installation\": {\"id\": 44, \"account\": {\"id\": 23}}, \"repository\": {\"id\": 31, \"full_name\": \"owner/one\"}, \"issue\": {\"number\": 7, \"pull_request\": {\"url\": \"https://api.github.test/pulls/7\"}}, \"comment\": {\"id\": "
      <> commentId
      <> ", \"body\": \""
      <> body
      <> "\", \"author_association\": \"MEMBER\", \"user\": {\"id\": 5, \"login\": \"human\", \"type\": \"User\"}}}"

-- | @signed(body, delivery, event)@ plus @content-length@.
signed :: ByteString -> Text -> Text -> [(Text, Text)]
signed body delivery event =
  [ ("content-type", "application/json")
  , ("x-hub-signature-256", sign "hook-secret" body)
  , ("x-github-delivery", delivery)
  , ("x-github-event", event)
  , ("content-length", tshow (BS.length body))
  ]

receiveSigned :: HostService -> ByteString -> Text -> Text -> IO Receipt
receiveSigned host body delivery event = Custody.receive host.custody (signed body delivery event) body

-- ---------------------------------------------------------------------------
-- The inbox

sqlRows :: FilePath -> Text -> [S.SQLData] -> IO [[S.SQLData]]
sqlRows path sql params =
  bracket (S.open (T.pack path)) S.close $ \db -> do
    S.exec db "PRAGMA busy_timeout=5000"
    bracket (S.prepare db sql) S.finalize $ \statement -> do
      S.bind statement params
      let collect = S.step statement >>= \case
            S.Row -> (:) <$> S.columns statement <*> collect
            S.Done -> pure []
      collect

sqlExec :: FilePath -> Text -> [S.SQLData] -> IO ()
sqlExec path sql params = () <$ sqlRows path sql params

-- | @INSERT INTO inbox(delivery_id,event,observation,status)
-- VALUES(?,?,?,'pending')@ for many observations, in one transaction.
insertPending :: FilePath -> [(Text, Observation)] -> IO ()
insertPending path items =
  bracket (S.open (T.pack path)) S.close $ \db -> do
    S.exec db "PRAGMA busy_timeout=5000"
    S.exec db "BEGIN"
    bracket (S.prepare db "INSERT INTO inbox(delivery_id,event,observation,status) VALUES(?,?,?,'pending')") S.finalize $ \statement ->
      forM_ items $ \(delivery, item) -> do
        S.reset statement
        S.bind statement [S.SQLText delivery, S.SQLText item.event, S.SQLText (either (error . show) id (encodeObservation item))]
        _ <- S.step statement
        pure ()
    S.exec db "COMMIT"

inboxReason :: FilePath -> Text -> IO (Maybe Text)
inboxReason root delivery =
  sqlRows (root <> "/webhooks.sqlite3") "SELECT reason FROM inbox WHERE delivery_id=?" [S.SQLText delivery] >>= \case
    [[S.SQLText reason]] -> pure (Just reason)
    _ -> pure Nothing

-- ---------------------------------------------------------------------------
-- The V5 provider

-- | @V5Provider@: an open, clean PR 7 on @owner/one@.
data V5Provider = V5Provider
  { head :: IORef Text
  , base :: Text
  , calls :: IORef [(Text, Text)]
  , comments :: IORef [[(Text, Json)]]
  , requestHook :: IORef (Text -> Text -> IO ())
  }

newV5Provider :: IO V5Provider
newV5Provider =
  V5Provider
    <$> newIORef (T.replicate 40 "a")
    <*> pure (T.replicate 40 "b")
    <*> newIORef []
    <*> newIORef []
    <*> newIORef (\_ _ -> pure ())

providerTransport :: V5Provider -> Transport
providerTransport provider =
  Transport
    { request = \method path body -> do
        hook <- readIORef provider.requestHook
        hook method path
        respond method path body
    , pages = \path -> do
        modifyIORef' provider.calls (<> [("PAGES", path)])
        if path == "/repos/owner/one/issues/7/comments?per_page=100"
          then readIORef provider.comments
          else pure []
    }
  where
    ok = pure . (\v -> WireResponse 200 v Nothing)
    respond method path body = do
      modifyIORef' provider.calls (<> [(method, path)])
      headSha <- readIORef provider.head
      let baseSha = provider.base
      case (method, path) of
        ("GET", "/repos/owner/one/pulls/7") ->
          ok $
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
        ("POST", "/graphql") ->
          ok $
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
        ("POST", "/repos/owner/one/issues/7/comments")
          | Just members <- body -> do
              n <- length <$> readIORef provider.comments
              let identifier = toInteger n + 1
                  comment =
                    [ ("id", Int identifier)
                    , ("html_url", String ("https://example.test/comments/" <> tshow identifier))
                    , ("body", maybe (String "") id (lookup "body" members))
                    , ("user", Object [("login", String "hamsterdan-test[bot]")])
                    ]
              modifyIORef' provider.comments (<> [comment])
              pure (WireResponse 201 (Object comment) Nothing)
        _ -> throwIO (PythonException "AssertionError" [])

-- | @V5Runner@: every review is clear.
v5Runner :: AgentRunner
v5Runner = objectRunner {review = reviewClear}

-- ---------------------------------------------------------------------------
-- Activities

dummyContext :: ActivityExecutionContext
dummyContext =
  ActivityExecutionContext
    { attemptId = "test"
    , epoch = "1"
    , claimant = "test"
    , instance' = Nothing
    , latestDetails = pure Null
    , heartbeat = \_ -> pure Null
    }

invocationOf :: Text -> Json -> ActivityInvocation
invocationOf name input = valid (invocation name input)

assertionError :: IO a
assertionError = throwIO (PythonException "AssertionError" [])
