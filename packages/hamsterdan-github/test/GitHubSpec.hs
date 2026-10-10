{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The port of @tests/unit/github_app/test_github.py@ (the gateway, the
-- comment publisher and the rerun broker over a fake 'Transport') and of
-- the auth and transport tests of @test_app_foundation.py@ (the whole
-- client stack over a mock network). The differential corpora exercise
-- the same code far more widely; these pin the reference's named
-- behaviors one by one.
module GitHubSpec (spec) where

import Control.Exception (ErrorCall (..), throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import AppFoundationSpec (environment, installationConfig)
import Corpus (canonical)
import Hamsterdan.GitHub.Auth (appEvents, appPermissions, githubAppClients, registrationInventory)
import Hamsterdan.GitHub.Client
import Hamsterdan.GitHub.Config (HostConfig, fromEnvironment)
import Hamsterdan.GitHub.Effects (CommentPublisher, CommentRerunBroker (..), EffectFault, Fence)
import Hamsterdan.GitHub.Effects qualified as E
import Hamsterdan.GitHub.Gateway (GitHubAuthority, RunResult (..))
import Hamsterdan.GitHub.Gateway qualified as G
import Hamsterdan.GitHub.Http (Exchange (..), HttpRequest (..), RawResponse (..), transportFailure)
import Hamsterdan.GitHub.Models
import Hamsterdan.GitHub.Transport qualified as Transport
import Petrus.Json (Json (..), defaultDumps, dumps, parseJson, pythonLoads)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec hiding (pending)

headSha, baseSha :: Text
headSha = T.replicate 40 "a"
baseSha = T.replicate 40 "b"

-- | JSON written with single quotes (no value here contains one).
j :: Text -> Json
j = either error id . parseJson pythonLoads . TE.encodeUtf8 . T.replace "'" "\""

members :: Json -> [(Text, Json)]
members = \case
  Object items -> items
  other -> error ("expected an object, got " <> show other)

at :: Text -> Json -> Maybe Json
at key = \case
  Object items -> lookup key items
  _ -> Nothing

-- * The fake transport

type Body = Maybe [(Text, Json)]

data Fake = Fake
  { responses :: IORef [((Text, Text), WireResponse)]
  , pageValues :: IORef [(Text, [[(Text, Json)]])]
  , calls :: IORef [(Text, Text, Body)]
  }

newFake :: IO Fake
newFake = Fake <$> newIORef [] <*> newIORef [] <*> newIORef []

respond :: Fake -> Text -> Text -> Int -> Json -> IO ()
respond fake method path status body = respondNext fake method path status body Nothing

respondNext :: Fake -> Text -> Text -> Int -> Json -> Maybe Text -> IO ()
respondNext fake method path status body next =
  modifyIORef' fake.responses (((method, path), WireResponse status body next) :)

setPages :: Fake -> Text -> [Json] -> IO ()
setPages fake path items = modifyIORef' fake.pageValues ((path, map members items) :)

record :: Fake -> Text -> Text -> Body -> IO ()
record fake method path body = modifyIORef' fake.calls (<> [(method, path, body)])

-- | @FakeTransport@; @override@ plays a subclass's @request@ (the call is
-- recorded first).
transportWith :: Fake -> (Text -> Text -> Body -> Maybe (IO WireResponse)) -> Transport
transportWith fake override =
  Transport
    { request = \method path body -> do
        record fake method path body
        case override method path body of
          Just answer -> answer
          Nothing ->
            readIORef fake.responses
              >>= maybe (throwIO (ErrorCall ("unexpected request " <> show (method, path)))) pure . lookup (method, path)
    , pages = \path -> do
        record fake "PAGES" path Nothing
        readIORef fake.pageValues
          >>= maybe (throwIO (ErrorCall ("unexpected pages " <> show path))) pure . lookup path
    }

transportOf :: Fake -> Transport
transportOf fake = transportWith fake (\_ _ _ -> Nothing)

callKinds :: Fake -> IO [Text]
callKinds fake = map (\(kind, _, _) -> kind) <$> readIORef fake.calls

posts :: Fake -> IO Int
posts fake = length . filter (== "POST") <$> callKinds fake

lastBody :: Fake -> IO Text
lastBody fake =
  readIORef fake.calls >>= \case
    [] -> pure ""
    items -> case last items of
      (_, _, Just body) | Just (String text) <- lookup "body" body -> pure text
      _ -> pure ""

authority :: Transport -> GitHubAuthority
authority transport = either (error . show) id (G.githubAuthority transport "owner/repo" 7 Nothing)

publisherWith :: Transport -> Fence -> Maybe EffectFault -> CommentPublisher
publisherWith transport fence fault =
  either (error . show) id (E.commentPublisher transport "owner/repo" 7 "hamsterdan[bot]" fence fault (\_ -> pure ()))

noFence :: Fence
noFence _ _ _ _ _ = pure ()

countingFence :: IORef Int -> Fence
countingFence counter _ _ _ _ _ = modifyIORef' counter (+ 1)

markerOf :: Text -> Text -> Text -> Text
markerOf kind operation head' = either (error . show) id (E.marker kind operation head')

comment :: Integer -> Text -> Text -> Json
comment identifier body login' =
  Object [("id", Int identifier), ("html_url", String "url"), ("body", String body), ("user", Object [("login", String login')])]

issueComments :: Text
issueComments = "/repos/owner/repo/issues/7/comments"

issuePages :: Text
issuePages = issueComments <> "?per_page=100"

pullJson :: Json
pullJson =
  j $
    "{'state':'open','draft':true,'head':{'sha':'"
      <> headSha
      <> "','ref':'topic','repo':{'full_name':'owner/repo'}},'base':{'sha':'"
      <> baseSha
      <> "','ref':'main'},'mergeable':true,'merged':false,'user':{'login':'author'}}"

runsPath :: Text
runsPath = "/repos/owner/repo/actions/workflows/ci.yml/runs?event=pull_request&head_sha=" <> headSha <> "&per_page=20"

wireRun :: Integer -> Integer -> Text -> Text -> Text -> Json
wireRun identifier attempt pulls status conclusion =
  j $
    "{'id':"
      <> tshow identifier
      <> ",'head_sha':'"
      <> headSha
      <> "','path':'.github/workflows/ci.yml','run_attempt':"
      <> tshow attempt
      <> ",'event':'pull_request','pull_requests':"
      <> pulls
      <> ",'status':'"
      <> status
      <> "','conclusion':'"
      <> conclusion
      <> "'}"

runsBody :: Integer -> [Json] -> Json
runsBody total runs = Object [("total_count", Int total), ("workflow_runs", Array runs)]

snapshot :: Integer -> Text -> Integer -> Text -> Maybe Text -> ActionsRunSnapshot
snapshot identifier head' attempt status conclusion = ActionsRunSnapshot identifier head' "ci.yml" attempt status conclusion []

tshow :: (Show a) => a -> Text
tshow = T.pack . show

boundaryMatching :: Text -> Selector GitHubBoundaryError
boundaryMatching fragment failure = fragment `T.isInfixOf` failure.message

rerunWorld :: Fake -> [Json] -> IO CommentRerunBroker
rerunWorld fake runs = do
  respond fake "GET" "/repos/owner/repo/pulls/7" 200 pullJson
  respond fake "GET" "/repos/owner/repo/git/ref/heads/main" 200 (j ("{'object':{'sha':'" <> baseSha <> "'}}"))
  respond fake "GET" runsPath 200 (runsBody (fromIntegral (length runs)) runs)
  setPages fake issuePages []
  let transport = transportOf fake
  pure (CommentRerunBroker (authority transport) (publisherWith transport noFence Nothing))

-- | @ThreadsTransport@: answers the review-threads query and records
-- resolutions.
threadsTransport :: Fake -> [Json] -> IORef [Text] -> Transport
threadsTransport fake threads resolved = transportWith fake $ \method path body -> case (method, path, body) of
  ("POST", "/graphql", Just payload)
    | Just (String query) <- lookup "query" payload
    , "resolveReviewThread" `T.isInfixOf` query -> Just $ do
        let threadId = case lookup "variables" payload >>= at "thread" of
              Just (String value) -> value
              _ -> ""
        modifyIORef' resolved (<> [threadId])
        pure (WireResponse 200 (j ("{'data':{'resolveReviewThread':{'thread':{'id':'" <> threadId <> "','isResolved':true}}}}")) Nothing)
    | otherwise ->
        Just . pure $
          WireResponse
            200
            ( Object
                [ ( "data"
                  , Object
                      [ ( "repository"
                        , Object
                            [ ( "pullRequest"
                              , Object
                                  [ ( "reviewThreads"
                                    , Object [("nodes", Array threads), ("pageInfo", j "{'hasNextPage':false,'endCursor':null}")]
                                    )
                                  ]
                              )
                            ]
                        )
                      ]
                  )
                ]
            )
            Nothing
  _ -> Nothing

thread :: Text -> Bool -> Maybe Bool -> Maybe Text -> Json
thread identifier resolved viewer markerHead =
  Object $
    [("id", String identifier), ("isResolved", Bool resolved)]
      <> case viewer of
        Nothing -> []
        Just authored ->
          let body = case markerHead of
                Just h -> "prose\n\n<!-- hamsterdan:finding operation=findings:" <> h <> ":i1:f1 head=" <> h <> " -->"
                Nothing -> "a plain reply"
           in [("comments", Object [("nodes", Array [Object [("viewerDidAuthor", Bool authored), ("body", String body)]])])]

-- * The mock network (the client stack tests)

type Handler = HttpRequest -> IO (Int, [(ByteString, ByteString)], ByteString)

mockExchange :: Handler -> Exchange
mockExchange handler = Exchange $ \request continue -> do
  (status, headers, body) <- handler request
  pending <- newIORef [body]
  continue
    RawResponse
      { status
      , headers = headers <> [("content-length", BS8.pack (show (BS.length body)))]
      , readChunk = atomicModifyIORef' pending (\case [] -> ([], ""); chunk : rest -> (rest, chunk))
      }

jsonReply :: Int -> Json -> IO (Int, [(ByteString, ByteString)], ByteString)
jsonReply status value = pure (status, [("content-type", "application/json")], either (error . show) id (dumps defaultDumps value))

pathOf :: HttpRequest -> Text
pathOf request = T.takeWhile (/= '?') request.target

queryOf :: HttpRequest -> Text
queryOf request = T.drop 1 (T.dropWhile (/= '?') request.target)

authorization :: HttpRequest -> Maybe Text
authorization request = lookup "authorization" request.headers

tokenReply :: Text -> Text -> IO (Int, [(ByteString, ByteString)], ByteString)
tokenReply token expires = jsonReply 201 (Object [("token", String token), ("expires_at", String expires)])

permissionsJson :: [(Text, Text)] -> Json
permissionsJson extra = Object [(k, String v) | (k, v) <- Map.toList (Map.fromList (appPermissions <> extra))]

appJson :: [(Text, Json)] -> Json
appJson changes =
  Object . Map.toList $
    Map.fromList changes
      `Map.union` Map.fromList
        [ ("id", Int 17)
        , ("client_id", String "Iv1.explicit")
        , ("slug", String "hamsterdan-test")
        , ("permissions", permissionsJson [("metadata", "read")])
        , ("events", Array (map String (sort appEvents)))
        ]

installationJson :: Integer -> Integer -> Text -> Json
installationJson identifier account login' =
  Object
    [ ("id", Int identifier)
    , ("account", Object [("id", Int account), ("login", String login')])
    , ("suspended_at", Null)
    , ("permissions", permissionsJson [("metadata", "read")])
    ]

repositoriesJson :: [(Json, Text)] -> Json
repositoriesJson items =
  Object
    [ ("total_count", Int (fromIntegral (length items)))
    , ("repositories", Array [Object [("id", identifier), ("full_name", String name)] | (identifier, name) <- items])
    ]

withConfig :: (HostConfig -> IO a) -> IO a
withConfig action = withSystemTempDirectory "github" $ \directory -> do
  key <- readFile "test/corpus/app-test-key.pem"
  environment directory key >>= fromEnvironment >>= action

optionsFor :: Handler -> ClientOptions
optionsFor handler = ClientOptions {exchange = mockExchange handler, clock = pure 1760000000, metadataHook = Nothing}

installation' :: AppClients -> Integer -> [Integer] -> GitHubClient
installation' clients identifier repositories = either (error . T.unpack) id (installationClient clients identifier repositories)

spec :: Spec
spec = do
  gatewaySpec
  publisherSpec
  brokerSpec
  clientSpec

gatewaySpec :: Spec
gatewaySpec = describe "GitHub gateway (test_github.py)" $ do
  it "binds before and after oids atomically in the GraphQL ref update" $ do
    let refTransport fake stale = transportWith fake $ \method path body -> Just $ do
          unless (method == "POST" && path == "/graphql") (throwIO (ErrorCall "not graphql"))
          count <- length <$> readIORef fake.calls
          if
            | count == 1 -> pure (WireResponse 200 (j "{'data':{'repository':{'id':'repository-node'}}}") Nothing)
            | stale -> pure (WireResponse 200 (j "{'data':{'updateRefs':null},'errors':[{'message':'stale'}]}") Nothing)
            | otherwise -> do
                let client = body >>= lookup "variables" >>= at "input" >>= at "clientMutationId"
                pure (WireResponse 200 (Object [("data", Object [("updateRefs", Object [("clientMutationId", maybe Null id client)])])]) Nothing)
    fake <- newFake
    (Transport.githubGraphQL (refTransport fake False)).compareAndSwapRef "owner/repo" "refs/heads/topic" headSha baseSha
    readIORef fake.calls >>= \case
      [(_, _, Just query), (_, _, Just mutation)] -> do
        sort (map fst query) `shouldBe` ["query", "variables"]
        fmap canonical (lookup "variables" query) `shouldBe` Just (canonical (j "{'owner':'owner','repository':'repo'}"))
        case lookup "query" mutation of
          Just (String text) -> text `shouldSatisfy` T.isInfixOf "updateRefs"
          other -> expectationFailure (show other)
        fmap canonical (lookup "variables" mutation >>= at "input" >>= at "refUpdates")
          `shouldBe` Just (canonical (j ("[{'name':'refs/heads/topic','beforeOid':'" <> headSha <> "','afterOid':'" <> baseSha <> "','force':false}]")))
      other -> expectationFailure (show other)
    stale <- newFake
    (Transport.githubGraphQL (refTransport stale True)).compareAndSwapRef "owner/repo" "refs/heads/topic" headSha baseSha
      `shouldThrow` boundaryMatching "exact ref compare-and-swap"

  it "resolves the current base ref instead of the stale PR base sha" $ do
    fake <- newFake
    let current = T.replicate 40 "c"
    respond fake "GET" "/repos/owner/repo/pulls/7" 200 pullJson
    respond fake "GET" "/repos/owner/repo/git/ref/heads/main" 200 (j ("{'object':{'type':'commit','sha':'" <> current <> "'}}"))
    value <- G.pullRequest (authority (transportOf fake))
    value.base `shouldBe` current

  it "selects the exact-head run, ignoring a closed historical run for a reused head" $ do
    fake <- newFake
    respond fake "GET" runsPath 200 (runsBody 2 [wireRun 2 3 "[]" "completed" "success", wireRun 1 1 "[{'number':7}]" "completed" "success"])
    selected <- G.selectRun (authority (transportOf fake)) "ci.yml" headSha
    selected `shouldBe` Just (snapshot 1 headSha 1 "completed" (Just "success"))

  it "requires complete, consistent object-collection pagination" $ do
    fake <- newFake
    let second = runsPath <> "&page=2"
        run = wireRun 1 1 "[{'number':7}]" "completed" "success"
    respondNext fake "GET" runsPath 200 (runsBody 1 []) (Just second)
    respond fake "GET" second 200 (runsBody 1 [run])
    selected <- G.selectRun (authority (transportOf fake)) "ci.yml" headSha
    fmap (.id) selected `shouldBe` Just 1
    respond fake "GET" second 200 (runsBody 2 [run])
    G.selectRun (authority (transportOf fake)) "ci.yml" headSha `shouldThrow` boundaryMatching "malformed"

  it "takes the branch's effective rules as the policy authority" $ do
    fake <- newFake
    respond fake "GET" "/repos/owner/repo/rules/branches/main" 200 $
      j
        "[{'type':'required_status_checks','parameters':{'strict_required_status_checks_policy':true,'required_status_checks':[{'context':'unit'}]}},\
        \{'type':'pull_request','parameters':{'required_approving_review_count':2,'required_review_thread_resolution':true}}]"
    value <- G.policy (authority (transportOf fake)) "main"
    (value.source, value.strict, value.requiredChecks, value.requiredApprovals, value.conversationResolution)
      `shouldBe` ("effective_rules", True, ["unit"], 2, True)
    T.length value.digest `shouldBe` 64

  it "keeps each reviewer's latest meaningful state and makes the thread capability explicit" $ do
    fake <- newFake
    respond fake "GET" "/repos/owner/repo/pulls/7/requested_reviewers" 200 (j "{'users':[{'login':'bob'}]}")
    setPages
      fake
      "/repos/owner/repo/pulls/7/reviews?per_page=100"
      [ j "{'id':1,'submitted_at':'1','user':{'login':'alice'},'state':'APPROVED'}"
      , j "{'id':2,'submitted_at':'2','user':{'login':'alice'},'state':'CHANGES_REQUESTED'}"
      ]
    review <- G.humanReview (authority (transportOf fake))
    review.requestedReviewers `shouldBe` ["bob"]
    review.changesRequested `shouldBe` ["alice"]
    review.unresolvedThreads `shouldBe` Nothing
    review.threadsCapability `shouldBe` "threads_unavailable"

  it "falls back to branch protection only on the effective endpoint's 404 and rejects malformed evidence" $ do
    fake <- newFake
    respond fake "GET" "/repos/owner/repo/rules/branches/topic%2Fbase" 404 (Object [])
    respond fake "GET" "/repos/owner/repo/branches/topic%2Fbase/protection" 200 $
      j
        "{'required_status_checks':{'strict':true,'contexts':['unit']},'required_pull_request_reviews':{'required_approving_review_count':1},\
        \'required_conversation_resolution':{'enabled':true}}"
    value <- G.policy (authority (transportOf fake)) "topic/base"
    value.source `shouldBe` "branch_protection"
    respond fake "GET" "/repos/owner/repo/rules/branches/main" 200 (j "[{'type':'required_status_checks','parameters':{'required_status_checks':[]}}]")
    G.policy (authority (transportOf fake)) "main" `shouldThrow` boundaryMatching "status policy"

  forM_ [("event", "push"), ("path", ".github/workflows/other.yml")] $ \(name, value) ->
    it ("rejects run evidence with the wrong " <> T.unpack name) $ do
      fake <- newFake
      let run = Object [(k, if k == name then String value else v) | (k, v) <- members (wireRun 1 1 "[{'number':7}]" "completed" "success")]
      respond fake "GET" runsPath 200 (runsBody 1 [run])
      G.selectRun (authority (transportOf fake)) "ci.yml" headSha `shouldThrow` boundaryMatching "outside the requested PR workflow"

  it "makes a missing required job an explicit failure" $ do
    fake <- newFake
    respond fake "GET" "/repos/owner/repo/actions/runs/5/attempts/2/jobs?per_page=100" 200 $
      j "{'total_count':1,'jobs':[{'id':8,'name':'lint','status':'completed','conclusion':'success'}]}"
    observed <- G.jobs (authority (transportOf fake)) (snapshot 5 headSha 2 "completed" (Just "success")) ["lint", "unit"]
    (G.runResult observed).conclusion `shouldBe` "failure"
    [job.name | job <- observed.jobs, job.required] `shouldBe` ["lint", "unit"]

  it "does not treat not-yet-created required jobs of an in-progress run as failures" $ do
    fake <- newFake
    respond fake "GET" "/repos/owner/repo/actions/runs/5/attempts/2/jobs?per_page=100" 200 $
      j "{'total_count':1,'jobs':[{'id':8,'name':'lint','status':'in_progress','conclusion':null}]}"
    observed <- G.jobs (authority (transportOf fake)) (snapshot 5 headSha 2 "in_progress" Nothing) ["lint", "unit"]
    (G.runResult observed).conclusion `shouldBe` "pending"

  it "counts only human unresolved threads" $ do
    fake <- newFake
    resolved <- newIORef []
    let transport =
          threadsTransport
            fake
            [ thread "human-open" False (Just False) (Just headSha)
            , thread "dan-open" False (Just True) (Just headSha)
            , thread "human-done" True (Just False) (Just headSha)
            , thread "authorless-open" False Nothing Nothing
            ]
            resolved
    respond fake "GET" "/repos/owner/repo/pulls/7/requested_reviewers" 200 (j "{'users':[]}")
    setPages fake "/repos/owner/repo/pulls/7/reviews?per_page=100" []
    let subject = either (error . show) id (G.githubAuthority transport "owner/repo" 7 (Just (Transport.githubGraphQL transport)))
    review <- G.humanReview subject
    (review.unresolvedThreads, review.threadsCapability) `shouldBe` (Just 2, "available")

  it "resolves only superseded app finding threads" $ do
    fake <- newFake
    resolved <- newIORef []
    let old = T.replicate 40 "c"
        transport =
          threadsTransport
            fake
            [ thread "dan-stale" False (Just True) (Just old)
            , thread "dan-current" False (Just True) (Just headSha)
            , thread "human-stale" False (Just False) (Just old)
            , thread "dan-settled" True (Just True) (Just old)
            , thread "dan-reply" False (Just True) Nothing
            ]
            resolved
        subject = either (error . show) id (G.githubAuthority transport "owner/repo" 7 (Just (Transport.githubGraphQL transport)))
    G.resolveStaleFindingThreads subject headSha `shouldReturn` 1
    readIORef resolved `shouldReturn` ["dan-stale"]

  it "is inert resolving stale threads without GraphQL" $ do
    fake <- newFake
    G.resolveStaleFindingThreads (authority (transportOf fake)) headSha `shouldReturn` 0

publisherSpec :: Spec
publisherSpec = describe "comment publisher (test_github.py)" $ do
  it "fences immediately before the dashboard create and does not append on a PATCH denial" $ do
    fake <- newFake
    events <- newIORef (0 :: Int)
    setPages fake issuePages []
    respond fake "POST" issueComments 201 (j "{'id':4,'html_url':'url','body':'x'}")
    let publisher = publisherWith (transportOf fake) (countingFence events) Nothing
    created <- E.dashboard publisher "dash-1" 3 headSha "body"
    created.status `shouldBe` "created"
    readIORef events `shouldReturn` 1
    ((\kinds -> drop (length kinds - 2) kinds) <$> callKinds fake) `shouldReturn` ["PAGES", "POST"]
    setPages fake issuePages [comment 4 "old\n\n<!-- hamsterdan:dashboard -->" "hamsterdan[bot]"]
    respond fake "PATCH" "/repos/owner/repo/issues/comments/4" 403 (j "{'message':'denied'}")
    result <- E.dashboard publisher "dash-2" 3 headSha "new"
    (result.status, result.capabilityAvailable) `shouldBe` ("capability_unavailable", False)
    kinds <- callKinds fake
    drop (length kinds - 2) kinds `shouldSatisfy` notElem "POST"

  it "recovers an uncertain successful comment write by looking it up first" $ do
    fake <- newFake
    fences <- newIORef 0
    setPages fake issuePages []
    let transport = transportWith fake $ \method path body ->
          if method == "POST" && path == issueComments
            then Just $ do
              let posted = maybe Null id (body >>= lookup "body")
              setPages fake issuePages [Object [("id", Int 8), ("html_url", String "url"), ("body", posted), ("user", j "{'login':'hamsterdan[bot]'}")]]
              pure (WireResponse 500 (j "{'message':'outcome unknown to caller'}") Nothing)
            else Nothing
    recovered <- E.immutable (publisherWith transport (countingFence fences) Nothing) "finding" "stable-operation" 1 headSha "Finding" Nothing []
    recovered.status `shouldBe` "existing"
    fmap (.id) recovered.reference `shouldBe` Just 8
    posts fake `shouldReturn` 1
    readIORef fences `shouldReturn` 1

  it "retries an immutable comment once after a proven pre-call failure" $ do
    fake <- newFake
    fences <- newIORef 0
    attempts <- newIORef (0 :: Int)
    setPages fake issuePages []
    let transport = transportWith fake $ \method path body ->
          if method == "POST" && path == issueComments
            then Just $ do
              modifyIORef' attempts (+ 1)
              attempt <- readIORef attempts
              when (attempt == 1) (throwIO (boundary "injected before call"))
              let item = Object [("id", Int 9), ("html_url", String "url"), ("body", maybe Null id (body >>= lookup "body")), ("user", j "{'login':'hamsterdan[bot]'}")]
              setPages fake issuePages [item]
              pure (WireResponse 201 item Nothing)
            else Nothing
    result <- E.immutable (publisherWith transport (countingFence fences) Nothing) "finding" "stable-operation" 1 headSha "Finding" Nothing []
    result.status `shouldBe` "created"
    readIORef attempts `shouldReturn` 2
    callKinds fake `shouldReturn` ["PAGES", "POST", "PAGES", "POST"]
    readIORef fences `shouldReturn` 2

  it "recovers an after-call fault by lookup without a second mutation" $ do
    fake <- newFake
    spent <- newIORef False
    setPages fake issuePages []
    let transport = transportWith fake $ \_ _ body -> Just $ do
          let item = Object [("id", Int 10), ("html_url", String "url"), ("body", maybe Null id (body >>= lookup "body")), ("user", j "{'login':'hamsterdan[bot]'}")]
          setPages fake issuePages [item]
          pure (WireResponse 201 item Nothing)
        fault phase _ _ _ _ = do
          already <- readIORef spent
          when (phase == "after_call" && not already) $ do
            writeIORef spent True
            throwIO (boundary "qualified ambiguous outcome")
    result <- E.immutable (publisherWith transport noFence (Just fault)) "finding" "stable-operation" 1 headSha "Finding" Nothing []
    result.status `shouldBe` "existing"
    posts fake `shouldReturn` 1

  it "looks up but does not retry a definitive comment rejection" $ do
    fake <- newFake
    fences <- newIORef 0
    setPages fake issuePages []
    respond fake "POST" issueComments 403 (j "{'message':'denied'}")
    result <- E.immutable (publisherWith (transportOf fake) (countingFence fences) Nothing) "readiness" "stable-operation" 1 headSha "Ready" Nothing []
    result.capabilityAvailable `shouldBe` False
    posts fake `shouldReturn` 1
    readIORef fences `shouldReturn` 1

  forM_ [(kind, status) | kind <- ["dashboard", "readiness"], status <- [422, 400]] $ \(kind, status) ->
    it ("makes a definite " <> show status <> " payload rejection of a " <> kind <> " non-retryable") $ do
      fake <- newFake
      setPages fake issuePages []
      respond fake "POST" issueComments status (j "{'message':'must not escape'}")
      let publisher = publisherWith (transportOf fake) noFence Nothing
          publish
            | kind == "dashboard" = E.dashboard publisher "stable-operation" 1 headSha "Dashboard"
            | otherwise = E.immutable publisher "readiness" "stable-operation" 1 headSha "Ready" Nothing []
      publish `shouldThrow` (\(PublicationRejected _) -> True)
      posts fake `shouldReturn` 1

  forM_ [(kind, status) | kind <- ["dashboard", "readiness"], status <- [429, 500, 503]] $ \(kind, status) ->
    it ("makes a transient " <> show status <> " for a " <> kind <> " a boundary failure") $ do
      fake <- newFake
      setPages fake issuePages []
      respond fake "POST" issueComments status (Object [])
      let publisher = publisherWith (transportOf fake) noFence Nothing
          publish
            | kind == "dashboard" = E.dashboard publisher "stable-operation" 1 headSha "Dashboard"
            | otherwise = E.immutable publisher "readiness" "stable-operation" 1 headSha "Ready" Nothing []
      publish `shouldThrow` boundaryMatching "did not prove"

  forM_
    [ (publication', body)
    | body <- ["[]", "{}", "{'id':null}", "{'id':'not-an-id'}"]
    , publication' <- ["immutable", "dashboard_create", "dashboard_update"]
    ]
    $ \(publication', body) ->
      it ("treats an expected status with the unusable reference " <> T.unpack body <> " as ambiguous (" <> publication' <> ")") $ do
        fake <- newFake
        let updating = publication' == "dashboard_update"
            method = if updating then "PATCH" else "POST"
            path = if updating then "/repos/owner/repo/issues/comments/4" else issueComments
        setPages fake issuePages [comment 4 "old\n\n<!-- hamsterdan:dashboard -->" "hamsterdan[bot]" | updating]
        respond fake method path (if updating then 200 else 201) (j body)
        let publisher = publisherWith (transportOf fake) noFence Nothing
            publish
              | publication' == "immutable" = E.immutable publisher "readiness" "stable-operation" 1 headSha "Ready" Nothing []
              | otherwise = E.dashboard publisher "stable-operation" 1 headSha "new"
        publish `shouldThrow` boundaryMatching "did not prove"
        (length . filter (== method) <$> callKinds fake) `shouldReturn` 1

  it "rejects a stable-operation payload collision on the initial lookup" $ do
    fake <- newFake
    setPages fake issuePages [comment 11 ("Different\n\n" <> markerOf "finding" "stable-operation" headSha) "hamsterdan[bot]"]
    E.immutable (publisherWith (transportOf fake) noFence Nothing) "finding" "stable-operation" 1 headSha "Finding" Nothing []
      `shouldThrow` (== PublicationCollision)
    posts fake `shouldReturn` 0

  it "reports absence, landing and collision from find without mutating" $ do
    fake <- newFake
    let publisher = publisherWith (transportOf fake) noFence Nothing
    setPages fake issuePages []
    E.findPublication publisher "finding" "stable-operation" headSha "Finding" [] `shouldReturn` Nothing
    setPages fake issuePages [comment 11 ("Finding\n\n" <> markerOf "finding" "stable-operation" headSha) "hamsterdan[bot]"]
    held' <- E.findPublication publisher "finding" "stable-operation" headSha "Finding" []
    fmap (.status) held' `shouldBe` Just "existing"
    (held' >>= (.reference)) `shouldBe` Just (CommentReference 11 "url")
    compatible <- E.findPublication publisher "finding" "stable-operation" headSha "Newer" ["Finding"]
    fmap (.status) compatible `shouldBe` Just "existing"
    E.findPublication publisher "finding" "stable-operation" headSha "Different" [] `shouldThrow` (== PublicationCollision)
    posts fake `shouldReturn` 0

  it "reconciles an operation-scoped publication across a head move without reposting" $ do
    fake <- newFake
    setPages fake issuePages [comment 12 ("the answer\n\n" <> markerOf "conversation" "reply:c1" headSha) "hamsterdan[bot]"]
    let publisher = publisherWith (transportOf fake) noFence Nothing
        noContext = throwIO (ErrorCall "write context must not be read for a held operation")
    recovered <- E.immutableOperation publisher "conversation" "reply:c1" "the answer" noContext []
    recovered.status `shouldBe` "existing"
    fmap (.id) recovered.reference `shouldBe` Just 12
    E.immutableOperation publisher "conversation" "reply:c1" "a different answer" noContext [] `shouldThrow` (== PublicationCollision)
    posts fake `shouldReturn` 0

  it "posts an operation-scoped publication under the current head when never held" $ do
    fake <- newFake
    fences <- newIORef 0
    setPages fake issuePages []
    respond fake "POST" issueComments 201 (j "{'id':13,'html_url':'url'}")
    result <- E.immutableOperation (publisherWith (transportOf fake) (countingFence fences) Nothing) "conversation" "reply:c1" "the answer" (pure (1, headSha)) []
    result.status `shouldBe` "created"
    lastBody fake >>= (`shouldSatisfy` T.isSuffixOf (markerOf "conversation" "reply:c1" headSha))
    readIORef fences `shouldReturn` 1

  it "reconciles an operation-scoped reminder by presence only across a head move" $ do
    fake <- newFake
    setPages fake issuePages [comment 14 ("an OLD nudge body\n\n" <> markerOf "reminder" "reminder:t1" headSha) "hamsterdan[bot]"]
    recovered <- E.reminderOperation (publisherWith (transportOf fake) noFence Nothing) "reminder:t1" (throwIO (ErrorCall "context read"))
    recovered.status `shouldBe` "existing"
    fmap (.id) recovered.reference `shouldBe` Just 14
    callKinds fake `shouldReturn` ["PAGES"]

  it "posts an operation-scoped reminder under the current head when never held" $ do
    fake <- newFake
    setPages fake issuePages []
    respond fake "POST" issueComments 201 (j "{'id':15,'html_url':'url'}")
    result <- E.reminderOperation (publisherWith (transportOf fake) noFence Nothing) "reminder:t1" (pure (1, headSha, Just "the-reviewer", "the-author"))
    result.status `shouldBe` "created"
    body <- lastBody fake
    body `shouldSatisfy` T.isInfixOf "@the-reviewer"
    body `shouldSatisfy` T.isSuffixOf (markerOf "reminder" "reminder:t1" headSha)

  it "stops after two fenced mutations with unproven outcomes" $ do
    fake <- newFake
    fences <- newIORef 0
    setPages fake issuePages []
    let transport = transportWith fake (\_ _ _ -> Just (throwIO (boundary "unproven")))
    E.immutable (publisherWith transport (countingFence fences) Nothing) "finding" "stable-operation" 1 headSha "Finding" Nothing []
      `shouldThrow` boundaryMatching "unproven"
    posts fake `shouldReturn` 2
    readIORef fences `shouldReturn` 2

  it "lets a stale recovery fence prevent a second comment mutation" $ do
    fake <- newFake
    fences <- newIORef (0 :: Int)
    setPages fake issuePages []
    let transport = transportWith fake (\_ _ _ -> Just (throwIO (boundary "unproven")))
        fence _ _ _ _ _ = do
          modifyIORef' fences (+ 1)
          count <- readIORef fences
          when (count == 2) (throwIO (ContractRefused "stale authority"))
    E.immutable (publisherWith transport fence Nothing) "finding" "stable-operation" 1 headSha "Finding" Nothing []
      `shouldThrow` (== ContractRefused "stale authority")
    posts fake `shouldReturn` 1

  it "requires the normalized exact bot login and the hamsterdan marker" $ do
    fake <- newFake
    let wanted = markerOf "finding" "operation" headSha
    setPages
      fake
      issuePages
      [ Object [("id", Int 1), ("body", String wanted), ("user", j "{'login':'other[bot]'}")]
      , Object [("id", Int 2), ("body", String ("<!-- impetus:finding operation=operation head=" <> headSha <> " -->")), ("user", j "{'login':'hamsterdan[bot]'}")]
      , Object [("id", Int 3), ("body", String ("body\n\n" <> wanted)), ("user", j "{'login':' HamsterDan[Bot] '}")]
      ]
    existing' <- E.immutable (publisherWith (transportOf fake) noFence Nothing) "finding" "operation" 1 headSha "body" Nothing []
    wanted `shouldSatisfy` T.isPrefixOf "<!-- hamsterdan:"
    existing'.status `shouldBe` "existing"
    fmap (.id) existing'.reference `shouldBe` Just 3
    posts fake `shouldReturn` 0

  it "does not take a legacy marker as a hamsterdan publication" $ do
    fake <- newFake
    setPages fake issuePages [Object [("id", Int 1), ("body", String "<!-- impetus:dashboard -->"), ("user", j "{'login':'hamsterdan[bot]'}")]]
    respond fake "POST" issueComments 201 (j "{'id':2,'html_url':'url'}")
    result <- E.dashboard (publisherWith (transportOf fake) noFence Nothing) "dashboard" 1 headSha "Hamsterdan readiness"
    result.status `shouldBe` "created"
    lastBody fake >>= (`shouldSatisfy` T.isInfixOf "<!-- hamsterdan:dashboard -->")

  it "mentions the configured reviewer in a reminder and never assigns" $ do
    fake <- newFake
    setPages
      fake
      issuePages
      [ Object
          [ ("id", Int 9)
          , ("html_url", String "https://github.invalid/pr/7#dashboard")
          , ("body", String "current\n\n<!-- hamsterdan:dashboard -->")
          , ("user", j "{'login':'hamsterdan[bot]'}")
          ]
      ]
    respond fake "POST" issueComments 201 (j "{'id':1,'html_url':'url'}")
    let publisher = publisherWith (transportOf fake) noFence Nothing
    _ <- E.reminder publisher "remind" 1 headSha (Just "reviewer") "author" Nothing
    body <- lastBody fake
    body `shouldSatisfy` T.isInfixOf "@reviewer, this PR and I have gotten to know each other quite well"
    body `shouldSatisfy` T.isInfixOf "Please review this PR"
    body `shouldSatisfy` T.isInfixOf "[See current readiness state.](https://github.invalid/pr/7#dashboard)"
    E.reviewerAssignmentAvailable publisher `shouldBe` False

  it "asks the author to assign a reviewer without inventing one" $ do
    fake <- newFake
    setPages fake issuePages []
    respond fake "POST" issueComments 201 (j "{'id':1,'html_url':'url'}")
    _ <- E.reminder (publisherWith (transportOf fake) noFence Nothing) "remind" 1 headSha Nothing "author" Nothing
    body <- lastBody fake
    body `shouldSatisfy` T.isInfixOf "@author, this PR and I have gotten to know each other quite well"
    body `shouldSatisfy` T.isInfixOf "Please assign a reviewer"

  it "uses distinct publication and authority operations for a finding" $ do
    fake <- newFake
    fences <- newIORef []
    setPages fake issuePages []
    respond fake "POST" issueComments 201 (j "{'id':1,'html_url':'url'}")
    let fence repository number epoch head' operation = modifyIORef' fences (<> [(repository, number, epoch, head', operation)])
    _ <- E.publishFinding (publisherWith (transportOf fake) fence Nothing) (finding "finding-activity:finding-id" "finding" "" 0) 3 headSha (Just "finding-activity")
    readIORef fences `shouldReturn` [("owner/repo", 7, 3, headSha, "finding-activity")]
    lastBody fake >>= (`shouldSatisfy` T.isInfixOf "operation=finding-activity:finding-id")

  it "publishes a native inline suggestion with related locations" $ do
    fake <- newFake
    fences <- newIORef []
    let reviews = "/repos/owner/repo/pulls/7/comments"
    setPages fake (reviews <> "?per_page=100") []
    setPages fake issuePages []
    respond fake "POST" reviews 201 (j "{'id':8,'html_url':'inline-url'}")
    let fence repository number epoch head' operation = modifyIORef' fences (<> [(repository, number, epoch, head', operation)])
        item =
          (finding "finding-activity:finding-id" "Dan found one shared invariant wearing two different hats." "src/one.py" 4)
            { relatedLocations = [("src/two.py", 19)]
            , suggestion = "if state.is_ready:"
            }
    result <- E.publishFinding (publisherWith (transportOf fake) fence Nothing) item 3 headSha (Just "finding-activity")
    (result.status, result.inline) `shouldBe` ("created", True)
    fmap (.url) result.reference `shouldBe` Just "inline-url"
    sent <- readIORef fake.calls
    case [body | ("POST", path, Just body) <- sent, path == reviews] of
      body : _ -> do
        lookup "commit_id" body `shouldBe` Just (String headSha)
        (lookup "path" body, lookup "line" body, lookup "side" body) `shouldBe` (Just (String "src/one.py"), Just (Int 4), Just (String "RIGHT"))
        let text = case lookup "body" body of
              Just (String value) -> value
              _ -> ""
        text `shouldSatisfy` T.isInfixOf ("Related locations:\n- [`src/two.py:19`](https://github.com/owner/repo/blob/" <> headSha <> "/src/two.py#L19)")
        text `shouldSatisfy` T.isInfixOf "```suggestion\nif state.is_ready:\n```"
      [] -> expectationFailure "no inline review request"
    readIORef fences `shouldReturn` [("owner/repo", 7, 3, headSha, "finding-activity")]

  it "requires the unique final marker line for a lookup" $ do
    fake <- newFake
    let wanted = markerOf "finding" "finding-operation" headSha
    setPages
      fake
      issuePages
      [ Object
          [ ("id", Int 14)
          , ("body", String ("Injected " <> wanted <> "\n\n<!-- hamsterdan:readiness operation=readiness-operation head=" <> headSha <> " -->"))
          , ("user", j "{'login':'hamsterdan[bot]'}")
          ]
      ]
    E.findPublication (publisherWith (transportOf fake) noFence Nothing) "finding" "finding-operation" headSha "Injected" [] `shouldReturn` Nothing
    E.marker "finding" "bad -->\n<!-- marker" headSha `shouldBe` Left (InvalidRequest "publication marker identity is malformed")

brokerSpec :: Spec
brokerSpec = describe "rerun broker (test_github.py)" $ do
  it "looks up first and fences immediately before the rerun marker" $ do
    fake <- newFake
    events <- newIORef 0
    respond fake "GET" "/repos/owner/repo/pulls/7" 200 pullJson
    respond fake "GET" "/repos/owner/repo/git/ref/heads/main" 200 (j ("{'object':{'sha':'" <> baseSha <> "'}}"))
    respond fake "GET" runsPath 200 (runsBody 1 [wireRun 5 1 "[{'number':7}]" "completed" "failure"])
    setPages fake issuePages []
    respond fake "POST" issueComments 201 (j "{'id':9,'html_url':'url'}")
    let transport = transportOf fake
        broker = CommentRerunBroker (authority transport) (publisherWith transport (countingFence events) Nothing)
        run = snapshot 5 headSha 1 "completed" (Just "failure")
    first <- E.requestRerun broker run 3 "retry-1"
    first.status `shouldBe` "requested"
    readIORef events `shouldReturn` 1
    (last <$> callKinds fake) `shouldReturn` "POST"
    setPages fake issuePages [comment 9 ("<!-- hamsterdan-rerun run=5 head=" <> headSha <> " operation=retry-1 -->") "hamsterdan[bot]"]
    again <- E.requestRerun broker run 3 "retry-1"
    again.status `shouldBe` "existing"
    readIORef events `shouldReturn` 1

  it "carries no currency requirement in the held lookup" $ do
    fake <- newFake
    setPages fake issuePages []
    let transport = transportOf fake
        broker = CommentRerunBroker (authority transport) (publisherWith transport noFence Nothing)
        rerun = "<!-- hamsterdan-rerun run=5 head=" <> headSha <> " operation=retry-1 -->"
    E.held broker 5 headSha "retry-1" `shouldReturn` Nothing
    setPages fake issuePages [comment 9 rerun "hamsterdan[bot]"]
    found <- E.held broker 5 headSha "retry-1"
    fmap (.status) found `shouldBe` Just "existing"
    sent <- readIORef fake.calls
    sent `shouldSatisfy` all (\(kind, path, _) -> kind == "PAGES" && issueComments `T.isPrefixOf` path)
    setPages fake issuePages [Object [("html_url", String "url"), ("body", String rerun), ("user", j "{'login':'hamsterdan[bot]'}")]]
    degraded <- E.held broker 5 headSha "retry-1"
    fmap (\r -> (r.status, isNothing r.reference)) degraded `shouldBe` Just ("existing", True)

  it "owns the final run read and the evidence cut" $ do
    fake <- newFake
    broker <- rerunWorld fake [wireRun 5 9 "[{'number':7}]" "completed" "failure", wireRun 7 1 "[{'number':7}]" "completed" "failure"]
    respond fake "POST" issueComments 201 (j "{'id':9,'html_url':'url'}")
    issued <- E.issue broker (snapshot 5 headSha 9 "completed" (Just "failure")) 3 "r-1"
    issued.result.status `shouldBe` "requested"
    (issued.cutRunId, issued.cutAttempt) `shouldBe` (7, 1)

  it "refuses before any effect when the head or the run moved" $ do
    fake <- newFake
    broker <- rerunWorld fake [wireRun 7 1 "[{'number':7}]" "completed" "failure"]
    let stale = snapshot 5 (T.replicate 40 "c") 1 "completed" (Just "failure")
    E.issue broker stale 3 "r-1" `shouldThrow` (\(RerunRefused _) -> True)
    E.issue broker (snapshot 5 headSha 1 "completed" (Just "failure")) 3 "r-1" `shouldThrow` (\(RerunRefused _) -> True)
    posts fake `shouldReturn` 0
    E.requestRerun broker stale 3 "r-1" `shouldThrow` boundaryMatching "does not belong"

  it "degrades a malformed 201 reference to none" $ do
    fake <- newFake
    broker <- rerunWorld fake [wireRun 5 1 "[{'number':7}]" "completed" "failure"]
    respond fake "POST" issueComments 201 (j "{'html_url':'url'}")
    issued <- E.issue broker (snapshot 5 headSha 1 "completed" (Just "failure")) 3 "r-1"
    (issued.result.status, issued.result.reference) `shouldBe` ("requested", Nothing)

clientSpec :: Spec
clientSpec = describe "GitHub App client stack (test_app_foundation.py)" $ do
  it "authenticates the App with a JWT, installations with a scoped token, and reports safe metadata" $ withConfig $ \config -> do
    seen <- newIORef []
    metadata <- newIORef []
    let handler request = do
          modifyIORef' seen (<> [request])
          if "/access_tokens" `T.isSuffixOf` pathOf request
            then tokenReply "installation-secret" "2099-01-01T00:00:00Z"
            else do
              (status, headers, body) <- jsonReply 200 (Object [])
              pure (status, headers <> [("x-github-request-id", "request"), ("x-ratelimit-remaining", "9"), ("x-ratelimit-reset", "10")], body)
    clients <- githubAppClients config (optionsFor handler) {metadataHook = Just (\m -> modifyIORef' metadata (<> [m]))}
    _ <- Transport.request (appClient clients) "GET" "/app" Nothing
    let first = installation' clients 44 [32, 31, 31]
    clientInstallation first `shouldBe` Just (44, Just [31, 32])
    clientInstallation first `shouldBe` clientInstallation (installation' clients 44 [31, 32])
    clientInstallation first `shouldNotBe` clientInstallation (installation' clients 44 [31])
    _ <- Transport.request first "GET" "/installation/repositories" Nothing
    requests <- readIORef seen
    case requests of
      firstRequest : _ -> fmap (T.isPrefixOf "Bearer ey") (authorization firstRequest) `shouldBe` Just True
      [] -> expectationFailure "no requests"
    authorization (last requests) `shouldBe` Just "token installation-secret"
    (last <$> readIORef metadata) `shouldReturn` RequestMetadata "GET" "/installation/repositories" (Just "request") (Just 9) (Just 10) 200
    (show <$> readIORef metadata) >>= (`shouldNotSatisfy` isInfixOf "installation-secret")

  it "validates the provider contract before returning the registration portfolio" $ withConfig $ \config -> do
    paths <- newIORef []
    let handler request = do
          modifyIORef' paths (<> [pathOf request])
          case pathOf request of
            path | "/access_tokens" `T.isSuffixOf` path -> tokenReply "installation-secret" "2099-01-01T00:00:00Z"
            "/app" -> jsonReply 200 (appJson [])
            "/app/installations" -> jsonReply 200 (Array [installationJson 44 23 "Owner"])
            "/installation/repositories" -> jsonReply 200 (repositoriesJson [(Int 31, "owner/one"), (Int 32, "owner/two")])
            other -> throwIO (ErrorCall (T.unpack other))
    clients <- githubAppClients config (optionsFor handler)
    RegistrationInventory installations <- registrationInventory clients config
    installations `shouldBe` [InstallationInventory 44 23 [(31, "owner/one"), (32, "owner/two")]]
    readIORef paths `shouldReturn` ["/app", "/app/installations", "/app/installations/44/access_tokens", "/installation/repositories"]

  it "validates multiple accounts before returning one snapshot" $ withSystemTempDirectory "github" $ \directory -> do
    key <- readFile "test/corpus/app-test-key.pem"
    values <- environment directory key
    multiple <- installationConfig (directory </> "multiple-installations.toml") True
    config <- fromEnvironment (Map.insert "HAMSTERDAN_GITHUB_INSTALLATIONS_FILE" multiple values)
    let handler request = case pathOf request of
          "/app" -> jsonReply 200 (appJson [])
          "/app/installations" -> jsonReply 200 (Array [installationJson 44 23 "Owner", installationJson 45 24 "Other-Owner"])
          path
            | "/access_tokens" `T.isSuffixOf` path ->
                tokenReply ("installation-" <> T.splitOn "/" path !! 3) "2099-01-01T00:00:00Z"
          _ -> case authorization request of
            Just "token installation-44" -> jsonReply 200 (repositoriesJson [(Int 31, "owner/one"), (Int 32, "owner/two")])
            Just "token installation-45" -> jsonReply 200 (repositoriesJson [(Int 33, "other-owner/three")])
            other -> throwIO (ErrorCall (show other))
    clients <- githubAppClients config (optionsFor handler)
    RegistrationInventory installations <- registrationInventory clients config
    installations
      `shouldBe` [ InstallationInventory 44 23 [(31, "owner/one"), (32, "owner/two")]
                 , InstallationInventory 45 24 [(33, "other-owner/three")]
                 ]

  let valid = [installationJson 44 23 "Owner"]
      suspensionless = Object [(k, v) | (k, v) <- members (installationJson 44 23 "Owner"), k /= "suspended_at"]
      bare account = Object [("id", Int 44), ("account", account), ("suspended_at", Null)]
  forM_
    [ ([("id", Int 18)], valid, "identity")
    , ([("client_id", String "wrong")], valid, "identity")
    , ([("slug", String "wrong")], valid, "identity")
    , ([("permissions", permissionsJson [("metadata", "read"), ("checks", "write")])], valid, "permissions")
    , ([("events", Array (map String (sort ("check_run" : appEvents))))], valid, "events")
    , ([], [], "missing or ambiguous")
    , ([], [bare (j "{'id':'23','login':'Owner'}")], "missing or ambiguous")
    , ([], [bare (j "{'id':23,'login':23}")], "missing or ambiguous")
    , ([], [suspensionless], "suspension evidence")
    , ([], [Object [("id", Int 44), ("account", j "{'id':23,'login':'Owner'}"), ("suspended_at", String "now")]], "suspended")
    , ([], [Object [(k, if k == "permissions" then permissionsJson [("metadata", "read"), ("pull_requests", "read")] else v) | (k, v) <- members (installationJson 44 23 "Owner")]], "installation permissions")
    ]
    $ \(changes, installations, message) ->
      it ("rejects an invalid App or installation before any token mint (" <> T.unpack message <> ", " <> show (map fst changes) <> ")") $ withConfig $ \config -> do
        minted <- newIORef (0 :: Int)
        let handler request = case pathOf request of
              path | "/access_tokens" `T.isSuffixOf` path -> modifyIORef' minted (+ 1) >> tokenReply "installation-secret" "2099-01-01T00:00:00Z"
              "/app" -> jsonReply 200 (appJson changes)
              "/app/installations" -> jsonReply 200 (Array installations)
              other -> throwIO (ErrorCall (T.unpack other))
        clients <- githubAppClients config (optionsFor handler)
        registrationInventory clients config `shouldThrow` (\(ContractRefused text) -> message `T.isInfixOf` text)
        readIORef minted `shouldReturn` 0

  forM_
    [ ([(Int 31, "owner/one"), (String "32", "owner/two")], "repository inventory is malformed")
    , ([(Int 31, "owner/one"), (Int 31, "owner/renamed")], "repository inventory is inconsistent")
    ]
    $ \(repositories, message) ->
      it ("rejects the whole portfolio: " <> T.unpack message) $ withConfig $ \config -> do
        let handler request = case pathOf request of
              path | "/access_tokens" `T.isSuffixOf` path -> tokenReply "installation-secret" "2099-01-01T00:00:00Z"
              "/app" -> jsonReply 200 (appJson [])
              "/app/installations" -> jsonReply 200 (Array [installationJson 44 23 "Owner"])
              _ -> jsonReply 200 (repositoriesJson repositories)
        clients <- githubAppClients config (optionsFor handler)
        registrationInventory clients config `shouldThrow` (\(ContractRefused text) -> message `T.isInfixOf` text)

  it "follows the provider's next link even after a short page" $ withConfig $ \config -> do
    queries <- newIORef []
    let handler request = case pathOf request of
          path | "/access_tokens" `T.isSuffixOf` path -> tokenReply "installation-secret" "2099-01-01T00:00:00Z"
          "/app" -> jsonReply 200 (appJson [])
          "/app/installations" -> do
            modifyIORef' queries (<> [queryOf request])
            if "page=" `T.isInfixOf` T.replace "per_page=" "" (queryOf request)
              then jsonReply 200 (Array [installationJson 44 23 "Owner"])
              else do
                (status, headers, body) <- jsonReply 200 (Array [])
                pure (status, headers <> [("link", "<https://api.github.com/app/installations?per_page=100&page=2>; rel=\"next\"")], body)
          _ -> jsonReply 200 (repositoriesJson [(Int 31, "owner/one"), (Int 32, "owner/two")])
    clients <- githubAppClients config (optionsFor handler)
    RegistrationInventory installations <- registrationInventory clients config
    map (.repositories) installations `shouldBe` [[(31, "owner/one"), (32, "owner/two")]]
    readIORef queries `shouldReturn` ["per_page=100", "per_page=100&page=2"]

  it "keeps the token out of a registration token-parse failure" $ withConfig $ \config -> do
    let token = "installation-token-must-not-escape"
        handler request = case pathOf request of
          path | "/access_tokens" `T.isSuffixOf` path -> tokenReply token "not-a-timestamp"
          "/app" -> jsonReply 200 (appJson [])
          _ -> jsonReply 200 (Array [installationJson 44 23 "Owner"])
    clients <- githubAppClients config (optionsFor handler)
    try (registrationInventory clients config) >>= \case
      Left (failure :: GitHubBoundaryError) -> do
        show failure `shouldNotSatisfy` isInfixOf (T.unpack token)
        show failure `shouldNotSatisfy` isInfixOf "installation-secret"
      Right value -> expectationFailure (show value)

  it "rejects a non-success even with valid-shaped App evidence" $ withConfig $ \config -> do
    clients <- githubAppClients config (optionsFor (\_ -> jsonReply 503 (appJson [])))
    registrationInventory clients config `shouldThrow` boundaryMatching "registration evidence is unavailable"

  forM_
    [ "[https://api.github.com/items?page=2]; rel=\"next\""
    , "<https://example.invalid/items?page=2>; rel=\"next\""
    , "<https://api.github.com/items?page=2>; rel=\"next\", <https://api.github.com/items?page=3>; rel=\"next\""
    ]
    $ \link ->
      it ("rejects the malformed, escaped or ambiguous next link " <> BS8.unpack link) $ withConfig $ \config -> do
        let handler _ = do
              (status, headers, body) <- jsonReply 200 (Object [])
              pure (status, headers <> [("link", link)], body)
        clients <- githubAppClients config (optionsFor handler)
        Transport.request (appClient clients) "GET" "/items" Nothing `shouldThrow` (\(_ :: GitHubBoundaryError) -> True)

  it "remints in a new client lifecycle (no host token cache)" $ withConfig $ \config -> do
    minted <- newIORef (0 :: Int)
    let handler request
          | "/access_tokens" `T.isSuffixOf` pathOf request = do
              modifyIORef' minted (+ 1)
              count <- readIORef minted
              tokenReply ("token-" <> tshow count) "2099-01-01T00:00:00Z"
          | otherwise = jsonReply 200 (Object [])
    forM_ [1 :: Int, 2] $ \_ -> do
      clients <- githubAppClients config (optionsFor handler)
      _ <- Transport.request (installation' clients 44 [31]) "GET" "/installation/repositories" Nothing
      pure ()
    readIORef minted `shouldReturn` 2

  it "remints an expired installation token" $ withConfig $ \config -> do
    minted <- newIORef (0 :: Int)
    used <- newIORef []
    let handler request
          | "/access_tokens" `T.isSuffixOf` pathOf request = do
              modifyIORef' minted (+ 1)
              count <- readIORef minted
              tokenReply ("token-" <> tshow count) (if count == 1 then "2000-01-01T00:00:00Z" else "2099-01-01T00:00:00Z")
          | otherwise = do
              modifyIORef' used (<> [authorization request])
              jsonReply 200 (Object [])
    clients <- githubAppClients config (optionsFor handler)
    let client = installation' clients 44 [31]
    forM_ [1 :: Int, 2] $ \_ -> Transport.request client "GET" "/installation/repositories" Nothing
    readIORef minted `shouldReturn` 2
    readIORef used `shouldReturn` [Just "token token-1", Just "token token-2"]

  it "drives the bounded gateway through an installation client" $ withConfig $ \config -> do
    let handler request
          | "/access_tokens" `T.isSuffixOf` pathOf request = tokenReply "installation-secret" "2099-01-01T00:00:00Z"
          | "/logs" `T.isSuffixOf` pathOf request = pure (200, [], "bounded log")
          | otherwise = do
              (status, headers, body) <- jsonReply 404 (j "{'message':'missing'}")
              pure (status, headers <> [("x-github-request-id", "request-404")], body)
    clients <- githubAppClients config (optionsFor handler)
    let client = installation' clients 44 [31]
    response <- Transport.request client "GET" "/repos/owner/one/missing" Nothing
    (response.status, response.body) `shouldBe` (404, j "{'message':'missing'}")
    Transport.download client "/repos/owner/one/actions/runs/1/logs" maxLogBytes `shouldReturn` "bounded log"

  it "reads a streamed body before the exchange releases it" $ withConfig $ \config -> do
    closed <- newIORef False
    let exchange' = Exchange $ \request continue -> do
          writeIORef closed False
          let body
                | "/access_tokens" `T.isSuffixOf` pathOf request = "{\"token\":\"installation-secret\",\"expires_at\":\"2099-01-01T00:00:00Z\"}"
                | otherwise = "{\"ok\":true}"
          pending <- newIORef [body]
          result <-
            continue
              RawResponse
                { status = 200
                , headers = []
                , readChunk = do
                    gone <- readIORef closed
                    when gone (throwIO (transportFailure "ReadError" "body read after client close"))
                    atomicModifyIORef' pending (\case [] -> ([], ""); chunk : rest -> (rest, chunk))
                }
          writeIORef closed True
          pure result
    clients <- githubAppClients config ClientOptions {exchange = exchange', clock = pure 1760000000, metadataHook = Nothing}
    forM_ [1 :: Int, 2] $ \_ -> do
      response <- Transport.request (installation' clients 44 [31]) "GET" "/repos/owner/one" Nothing
      (response.status, response.body) `shouldBe` (200, j "{'ok':true}")
