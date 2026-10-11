-- | @tests/unit/host/test_v5_ingress.py@: the @PrReadinessV5Application@
-- cases, against the real V5 topology and provider-backed gates.
module IngressApplicationSpec
  ( spec
  , World (..)
  , newWorld
  , worldAuthority
  , FakeRunner (..)
  , newRunner
  , reviewClear
  , objectRunner
  , openWorld
  , observationOf
  , pullWith
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM_, unless, when)
import Data.IORef
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite3 qualified as S
import Hamsterdan.Agents.Protocol
import Hamsterdan.Contracts.Codec (Object, dump, spelling)
import Hamsterdan.Contracts.Readiness (AdmittedConversation (..))
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.GitHub.Effects qualified as Effects
import Hamsterdan.GitHub.Gateway (GitHubAuthority (..))
import Hamsterdan.GitHub.Models
import Hamsterdan.GitHub.Webhooks (Observation (..))
import Hamsterdan.Host.GitPublish (PublicationAuthority (..))
import Hamsterdan.Host.Python (RuntimeError (..))
import Hamsterdan.Host.Runnable qualified as Runnable
import Hamsterdan.Host.V5.Application
import Hamsterdan.Host.V5.Claim (CurrentClaim (..))
import Hamsterdan.Host.V5.Ingress qualified as I
import Hamsterdan.Host.V5.Rerun (RerunBroker (..))
import Hamsterdan.Host.V5.Review (ReviewAuthority (..))
import Hamsterdan.Host.V5.Runtime (RuntimeHooks (..), defaultRuntimeHooks)
import Hamsterdan.Host.V5.Runtime qualified as Runtime
import Hamsterdan.Readiness.NetV5.Gating (GateDefinition (..))
import IngressSpec (FakeAuthority (..), fakeIngressAuthority, newDelivery, newFakeAuthority, subject)
import Petrus.Activity (ActivityDefinition (..), ActivityExecutionContext (..), declarationHeartbeatTimeout)
import Petrus.Activity.Number (Number (..))
import Petrus.Engine qualified as Engine
import Petrus.Impetus.History.Records
import Petrus.Impetus.Instance.FailureText (PythonException (..))
import Petrus.Impetus.Petrinet (Token (..), netPathText)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.Local qualified as Local
import System.Directory (removeFile)
import System.FilePath ((</>))
import System.Mem.StableName (makeStableName)
import Test.Hspec
import TestSupport

-- ---------------------------------------------------------------------------
-- The reference test's fakes

aaa :: Text
aaa = T.replicate 40 "a"

-- | The test's @Authority@ (provider reads) and @Transport@ (comments),
-- with seams for the instance patches the reference applies.
data World = World
  { fake :: FakeAuthority
  , comments :: IORef [Object]
  , requestHook :: IORef (Text -> Text -> Maybe Object -> IO WireResponse -> IO WireResponse)
  , pullHook :: IORef (IO PullRequestSnapshot -> IO PullRequestSnapshot)
  }

newWorld :: Bool -> Bool -> Bool -> IO World
newWorld draft closed merged =
  World
    <$> newFakeAuthority draft closed merged
    <*> newIORef []
    <*> newIORef (\_ _ _ real -> real)
    <*> newIORef id

assertion :: IO a
assertion = throwIO (PythonException "AssertionError" [])

-- | @Transport.request(method, path, body)@.
baseRequest :: World -> Text -> Text -> Maybe Object -> IO WireResponse
baseRequest w method path body = do
  text <- case body >>= lookup "body" of
    Just (String t) -> pure t
    _ -> assertion
  case method of
    "POST" -> do
      n <- length <$> readIORef w.comments
      let identifier = toInteger n + 1
          item =
            [ ("id", Int identifier)
            , ("html_url", String ("https://example.test/comments/" <> T.pack (show identifier)))
            , ("body", String text)
            , ("user", Object [("login", String "hamsterdan-test[bot]")])
            ]
      modifyIORef' w.comments (<> [item])
      pure (WireResponse 201 (Object item) Nothing)
    "PATCH" -> do
      let identifier = Int (read (T.unpack (T.takeWhileEnd (/= '/') path)))
      items <- readIORef w.comments
      case [item | item <- items, lookup "id" item == Just identifier] of
        item : _ -> do
          let updated = [(k, if k == "body" then String text else v) | (k, v) <- item]
          writeIORef w.comments [if lookup "id" i == Just identifier then updated else i | i <- items]
          pure (WireResponse 200 (Object updated) Nothing)
        [] -> throwIO (PythonException "StopIteration" [])
    _ -> assertion

worldTransport :: World -> Transport
worldTransport w =
  Transport
    { request = \method path body -> do
        hook <- readIORef w.requestHook
        hook method path body (baseRequest w method path body)
    , pages = \_ -> readIORef w.comments
    }

worldIngress :: World -> I.IngressAuthority
worldIngress w =
  let base = fakeIngressAuthority w.fake
   in I.IngressAuthority
        { pullRequest = readIORef w.pullHook >>= \hook -> hook base.pullRequest
        , policy = base.policy
        , baseCurrent = base.baseCurrent
        , humanReview = base.humanReview
        , workflowRuns = base.workflowRuns
        , actionsEvidence = base.actionsEvidence
        }

-- | The duck-typed authority as the application binds it. The fake has
-- no @resolve_stale_finding_threads@.
worldAuthority :: World -> ApplicationAuthority
worldAuthority w =
  let transport = worldTransport w
      gh = GitHubAuthority {transport, repository = "owner/repo", owner = "owner", name = "repo", prNumber = 7, graphql = Nothing}
      ingress = worldIngress w
   in ApplicationAuthority
        { repository = "owner/repo"
        , prNumber = 7
        , transport
        , ingress
        , review = ReviewAuthority {comments = pure [], selectRun = \_ _ -> pure Nothing}
        , rerunBroker = \publisher ->
            let broker = Effects.CommentRerunBroker gh publisher
             in RerunBroker {held = Effects.held broker, issue = \_ _ _ -> throwIO (PythonException "AssertionError" [])}
        , resolveStaleFindingThreads = Nothing
        , publication =
            PublicationAuthority
              { repository = "owner/repo"
              , pullRequest = ingress.pullRequest
              , createTree = \_ _ -> assertion
              , createCommit = \_ _ _ _ _ -> assertion
              , compareAndSwapRef = Nothing
              }
        }

-- | The test's @Runner@.
data FakeRunner = FakeRunner
  { conversationCalls :: IORef Int
  , agent :: AgentRunner
  }

reviewClear :: Text -> ReviewRequest -> Invocation -> IO ReviewResult
reviewClear _ request inv = do
  inv.attempt `shouldBe` 1
  forM_ inv.isCurrent (`shouldReturn` True)
  pure (ReviewResult request.repository request.pullRequest request.epoch request.head request.base "clear" [] [])

newRunner :: IO FakeRunner
newRunner = do
  calls <- newIORef 0
  pure
    FakeRunner
      { conversationCalls = calls
      , agent =
          AgentRunner
            { review = reviewClear
            , converse = \_ request inv -> do
                modifyIORef' calls (+ 1)
                inv.attempt `shouldBe` 1
                maybe (expectationFailure "is_current is required") (`shouldReturn` True) inv.isCurrent
                pure
                  ( ConversationResult
                      request.repository
                      request.pullRequest
                      request.epoch
                      request.head
                      request.base
                      [[("type", String "change"), ("arguments", Object [("request", String "rename the value")])]]
                  )
            , code = \_ _ _ -> attributeError
            }
      }
  where
    attributeError = throwIO (PythonException "AttributeError" [])

withReview :: AgentRunner -> (Text -> ReviewRequest -> Invocation -> IO ReviewResult) -> AgentRunner
withReview r review' = AgentRunner review' r.converse r.code

withConverse :: AgentRunner -> (Text -> ConversationRequest -> Invocation -> IO ConversationResult) -> AgentRunner
withConverse r converse' = AgentRunner r.review converse' r.code

-- | @object()@ as the runner: every capability is missing.
objectRunner :: AgentRunner
objectRunner =
  AgentRunner
    { review = \_ _ _ -> attributeError
    , converse = \_ _ _ -> attributeError
    , code = \_ _ _ -> attributeError
    }
  where
    attributeError = throwIO (PythonException "AttributeError" [])

openWorld :: FilePath -> World -> AgentRunner -> (ApplicationOptions -> ApplicationOptions) -> IO PrReadinessV5Application
openWorld tmp w runner = openSettling tmp w runner (\_ -> pure ())

openSettling :: FilePath -> World -> AgentRunner -> (Set.Set Text -> IO ()) -> (ApplicationOptions -> ApplicationOptions) -> IO PrReadinessV5Application
openSettling tmp w runner agentSettle tweak =
  openApplication
    (tmp </> "application")
    subject
    (worldAuthority w)
    runner
    (tweak (applicationOptions agentSettle "hamsterdan-test[bot]" "https://github.com/owner/repo.git" (tmp </> "webhooks.sqlite3")))

-- | @Observation(identity, event, action, 44, 23, 31, "owner/repo", 7)@.
observationOf :: Text -> Text -> Text -> Observation
observationOf identity event action =
  Observation identity event (String action) (Int 44) (Int 23) (Int 31) (String "owner/repo") (Int 7) Null Nothing Null Null Null Null [] 0

-- | @replace(pull, head=, base=, draft=, state=, closed=)@.
pullWith :: PullRequestSnapshot -> Text -> Text -> Bool -> Text -> Bool -> PullRequestSnapshot
pullWith p head' base' draft' state' closed' =
  PullRequestSnapshot
    p.repository
    p.number
    state'
    draft'
    head'
    base'
    p.headRef
    p.baseRef
    p.mergeable
    p.merged
    closed'
    p.author
    p.mergeableState
    p.url
    p.headRepository

modifyPull :: World -> (PullRequestSnapshot -> PullRequestSnapshot) -> IO ()
modifyPull w = modifyIORef' w.fake.pull

-- ---------------------------------------------------------------------------
-- Helpers

recordsOf :: PrReadinessV5Application -> IO [Record]
recordsOf app = applicationRuntime app >>= Runtime.records

delivered :: PrReadinessV5Application -> IO [ExternalEventDelivered]
delivered app = (\rs -> [r | RExternalEventDelivered r <- rs]) <$> recordsOf app

deliveredFrom :: Text -> PrReadinessV5Application -> IO [Text]
deliveredFrom source app = (\rs -> [r.identity | r <- rs, netPathText r.source == source]) <$> delivered app

place :: PrReadinessV5Application -> Text -> IO [Token]
place app name = applicationRuntime app >>= (`Runtime.markingPlace` name)

member :: Text -> Json -> Json
member key = \case
  Object ms -> maybe (error ("missing " <> T.unpack key)) id (lookup key ms)
  _ -> error "not an object"

data' :: Token -> Text -> Json
data' token key = member key token.payload

bodies :: World -> IO [Text]
bodies w = (\items -> [t | item <- items, Just (String t) <- [lookup "body" item]]) <$> readIORef w.comments

readinessCount :: World -> IO Int
readinessCount w = length . filter ("hamsterdan:readiness" `T.isInfixOf`) <$> bodies w

withDb :: FilePath -> (S.Database -> IO a) -> IO a
withDb path use = do
  db <- S.open (T.pack path)
  result <- use db
  S.close db
  pure result

query :: FilePath -> Text -> [S.SQLData] -> IO [[S.SQLData]]
query path sql params = withDb path $ \db -> do
  statement <- S.prepare db sql
  S.bind statement params
  let go acc =
        S.step statement >>= \case
          S.Done -> pure (reverse acc)
          S.Row -> S.columns statement >>= \row -> go (row : acc)
  result <- go []
  S.finalize statement
  pure result

execute :: FilePath -> Text -> [S.SQLData] -> IO ()
execute path sql params = () <$ query path sql params

inboxDdl :: Text
inboxDdl = "CREATE TABLE inbox (delivery_id TEXT PRIMARY KEY, status TEXT NOT NULL, observation TEXT NOT NULL)"

observationJson :: Text
observationJson = "{\"installation_id\": 44, \"repository_id\": 31, \"pull_request_number\": 7}"

insertInbox :: FilePath -> Text -> Text -> IO ()
insertInbox path identity status =
  execute path "INSERT INTO inbox VALUES (?, ?, ?)" [S.SQLText identity, S.SQLText status, S.SQLText observationJson]

-- | Create the inbox table and stage one pending delivery.
pendingInbox :: FilePath -> Text -> IO ()
pendingInbox path identity = do
  execute path inboxDdl []
  insertInbox path identity "pending"

terminalize :: FilePath -> Text -> IO ()
terminalize path identity = execute path "UPDATE inbox SET status='terminal' WHERE delivery_id=?" [S.SQLText identity]

setRuntimeHooks :: PrReadinessV5Application -> (RuntimeHooks -> RuntimeHooks) -> IO ()
setRuntimeHooks app f = do
  runtime <- applicationRuntime app
  modifyIORef' runtime.hooks f

setAppHooks :: PrReadinessV5Application -> (ApplicationHooks -> ApplicationHooks) -> IO ()
setAppHooks app f = modifyIORef' app.hooks f

headSeen :: Text -> HeadSeen
headSeen value = HeadSeen {head = value, base = T.replicate 40 "b", mergeable = True, policy = "policy-1", strictBase = True, baseCurrent = False}

reconciliationProjection :: [I.ProjectedEntry]
reconciliationProjection =
  [ I.projectedFrom "on_head" (headSeen aaa)
  , I.projectedFrom "on_ready" ReadySeen
  , I.projectedFrom "on_human" HumanSeen {approval = False, changesRequested = False, unresolved = 0}
  ]

projection :: Text -> [I.IngressEntry]
projection identity =
  [ I.ingressFrom "on_head" (headSeen aaa) ("github-delivery:" <> identity <> ":on_head")
  , I.ingressFrom "on_ready" ReadySeen ("github-delivery:" <> identity <> ":on_ready")
  , I.ingressFrom "on_human" HumanSeen {approval = False, changesRequested = False, unresolved = 0} ("github-delivery:" <> identity <> ":on_human")
  ]

firstEntry :: [a] -> a
firstEntry = \case
  x : _ -> x
  [] -> error "empty list"

withPayload :: I.IngressEntry -> Json -> I.IngressEntry
withPayload entry payload = I.IngressEntry entry.source entry.color payload entry.identity

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

conversationOf :: Text -> Text -> AdmittedConversation
conversationOf identity text = AdmittedConversation identity 19 5 "human" "MEMBER" text

lastPayload :: PrReadinessV5Application -> Text -> IO Json
lastPayload app identity = do
  Just manifest <- I.manifest app.ingress identity subject
  pure (last manifest.entries).payload

completedVariants :: Text -> [Record] -> [Json]
completedVariants transition rs =
  [member "$variant" r.result | RActivityCompleted r <- rs, netPathText r.transition == transition]

requestedWork :: Text -> [Record] -> [Json]
requestedWork transition rs = [member "work" r.input | RActivityRequested r <- rs, netPathText r.transition == transition]

-- | @_application_after_dashboard_custody_race(tmp_path, ...)@.
dashboardCustodyRace :: FilePath -> Bool -> IO (PrReadinessV5Application, World, FilePath, Text)
dashboardCustodyRace tmp terminalizeDuringClaim = do
  identity <- newDelivery
  blocker <- newDelivery
  let path = tmp </> "webhooks.sqlite3"
  w <- newWorld False False False
  runner <- newRunner
  app <- openWorld tmp w runner.agent id
  -- Establish startup and the clear review before approval triggers the
  -- dashboard/readiness race this fixture owns.
  approved <- readIORef w.fake.review
  writeIORef w.fake.review (HumanReviewSnapshot [] [] [] [] (Just 0) "available")
  opened <- newDelivery
  processObservation app (observationOf opened "pull_request" "opened") Nothing
  _ <- settle app
  writeIORef w.fake.review approved
  inserted <- newIORef False
  writeIORef w.requestHook $ \method _ body real -> do
    result <- real
    let text = case body >>= lookup "body" of
          Just (String t) -> t
          Just other -> T.pack (show other)
          Nothing -> ""
    already <- readIORef inserted
    when
      ( not already
          && method == "PATCH"
          && "hamsterdan:dashboard" `T.isInfixOf` text
          && "| Human review |" `T.isInfixOf` text
          && not ("no review yet" `T.isInfixOf` text)
      )
      $ do
        writeIORef inserted True
        execute path "CREATE TABLE IF NOT EXISTS inbox (delivery_id TEXT PRIMARY KEY, status TEXT NOT NULL, observation TEXT NOT NULL)" []
        insertInbox path blocker "pending"
    pure result
  when terminalizeDuringClaim $ do
    terminalized <- newIORef False
    setAppHooks app $ \h ->
      h
        { aroundUnstagedCustodyId = \_ real -> do
            outstanding <- real
            done <- readIORef terminalized
            case outstanding of
              Just p | not done -> do
                writeIORef terminalized True
                terminalize path p
              _ -> pure ()
            pure outstanding
        }
  processObservation app (observationOf identity "pull_request" "synchronize") Nothing
  _ <- settle app
  readIORef inserted `shouldReturn` True
  pure (app, w, path, blocker)

timerApplication :: FilePath -> IORef Integer -> World -> IO PrReadinessV5Application
timerApplication tmp clock w = do
  runner <- newRunner
  openWorld tmp w runner.agent $ \o -> o {reminderDelay = 10, timerClockUs = Just (readIORef clock)}

float :: Double -> Maybe Number
float = Just . FloatNumber

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "test_v5_ingress (application)" $ do
  it "test_v5_application_stages_grant_before_identified_delivery_and_replays_frozen_manifest" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    w <- newWorld False False False
    settled <- newIORef []
    app <- openSettling tmp w objectRunner (\ops -> modifyIORef' settled (<> [ops])) id
    let observation = observationOf identity "pull_request" "synchronize"
    observed <- newIORef []
    setRuntimeHooks app $ \h ->
      h {aroundDeliver = \_ real -> (I.claim app.ingress subject >>= \c -> modifyIORef' observed (<> [c])) >> real}
    processObservation app observation Nothing
    firstReads <- readIORef w.fake.pullCalls
    first <- recordsOf app
    modifyPull w (\p -> pullWith p (T.replicate 40 "c") p.base p.draft p.state p.closed)
    processObservation app observation Nothing
    claims <- readIORef observed
    claims `shouldSatisfy` (not . null)
    all (\c -> c.head == aaa && c.incarnation == 1) claims `shouldBe` True
    readIORef w.fake.pullCalls `shouldReturn` firstReads
    map (.identity) <$> delivered app
      `shouldReturn` ["github-delivery:" <> identity <> ":" <> s | s <- ["on_head", "on_ready", "on_human", "on_runs"]]
    recordsOf app `shouldReturn` first
    readIORef settled `shouldReturn` []
    closeApplication app

  forM_ [False, True] $ \pendingWebhook ->
    it ("test_repair_acknowledgement_lands_while_the_pushed_head_awaits_intake[" <> show pendingWebhook <> "]") . withTempRoot $ \tmp -> do
      w <- newWorld False False False
      let path = tmp </> "webhooks.sqlite3"
      app <- openWorld tmp w objectRunner id
      identity <- newDelivery
      _ <- I.stage app.ingress identity subject (projection identity)
      modifyPull w (\p -> pullWith p (T.replicate 40 "c") p.base p.draft p.state p.closed)
      when pendingWebhook $ newDelivery >>= pendingInbox path
      Just definition <- applicationActivity app "reply_gate"
      let work = ReplyReq {id = "comment-7", text = "I will repair the requested findings."}
          call = definition.activity.function [("work", dump work)] dummyContext
      result <- call
      member "$variant" result `shouldBe` String "Replied"
      result `shouldBe` Object [("$variant", String "Replied"), ("id", String work.id), ("text", String work.text)]
      length <$> readIORef w.comments `shouldReturn` 1
      call `shouldReturn` result
      length <$> readIORef w.comments `shouldReturn` 1
      closeApplication app

  it "test_v5_finding_publication_heartbeat_covers_the_transient_retry_pause" . withTempRoot $ \tmp -> do
    w <- newWorld False False False
    app <- openWorld tmp w objectRunner id
    Just definition <- applicationActivity app "publish_gate"
    declarationHeartbeatTimeout definition.activity.declaration `shouldBe` Just 360
    closeApplication app

  it "test_v5_application_reconciliation_is_stable_across_startup_and_periodic_reasons" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    w <- newWorld False False False
    app <- openWorld tmp w objectRunner id
    reconcile app "startup:44:31:7" `shouldReturn` True
    first <- recordsOf app
    reconcile app "periodic:44:31:7" `shouldReturn` True
    recordsOf app `shouldReturn` first
    let identities = [r.identity | RExternalEventDelivered r <- first]
    length identities `shouldBe` 4
    all (T.isPrefixOf ("host-reconcile:" <> subject <> ":1:")) identities `shouldBe` True
    query path "SELECT COUNT(*) FROM v5_reconciliation_manifests" [] `shouldReturn` [[S.SQLInteger 1]]
    query path "SELECT revision,source_kind FROM v5_authority_grants WHERE subject=?" [S.SQLText subject]
      `shouldReturn` [[S.SQLInteger 1, S.SQLText "host-reconcile"]]
    closeApplication app

  it "test_v5_application_replays_committed_reconciliation_before_reading_changed_provider_truth" . withTempRoot $ \tmp -> do
    w <- newWorld False False False
    app <- openWorld tmp w objectRunner id
    crashed <- newIORef False
    setRuntimeHooks app $ \h ->
      h
        { aroundDeliver = \_ real -> do
            already <- readIORef crashed
            if already
              then real
              else writeIORef crashed True >> throwIO (RuntimeError "crash after reconciliation commit")
        }
    reconcile app "startup" `shouldThrow` runtimeError "crash after reconciliation commit"
    writeIORef w.fake.review (HumanReviewSnapshot ["reviewer"] [] [] [] (Just 0) "available")
    reads' <- readIORef w.fake.pullCalls
    reconcile app "restart" `shouldReturn` True
    deliveries <- delivered app
    readIORef w.fake.pullCalls `shouldReturn` reads'
    length deliveries `shouldBe` 4
    [token] <- pure (deliveries !! 2).tokens
    data' token "approval" `shouldBe` Bool True
    reconcile app "periodic" `shouldReturn` True
    again <- delivered app
    length again `shouldBe` 8
    let sourceOf r = T.dropWhileEnd (/= ':') r.identity
        firstSources = Set.fromList (map sourceOf (take 4 again))
        secondSources = Set.fromList (map sourceOf (drop 4 again))
    (Set.size firstSources, Set.size secondSources) `shouldBe` (1, 1)
    firstSources `shouldNotBe` secondSources
    [later] <- pure (again !! 6).tokens
    data' later "approval" `shouldBe` Bool False
    closeApplication app

  it "test_v5_application_restart_replays_committed_reconciliation_without_provider_reads" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    store <- I.openIngressStore path
    Just committed <- I.stageReconciliation store subject reconciliationProjection
    I.close store
    w <- newWorld False False False
    modifyPull w (\p -> pullWith p (T.replicate 40 "c") p.base p.draft p.state p.closed)
    app <- openWorld tmp w objectRunner id
    reconcile app "restart" `shouldReturn` True
    readIORef w.fake.pullCalls `shouldReturn` 0
    map (.identity) <$> delivered app `shouldReturn` map (.identity) committed.entries
    closeApplication app

  it "test_reconciliation_folds_a_final_row_accepted_before_the_prior_host_crashed" . withTempRoot $ \tmp -> do
    w <- newWorld False False False
    app <- openWorld tmp w objectRunner id
    projected <- I.projectReconciliation app.normalizer
    Just committed <- I.stageReconciliation app.ingress subject projected
    runtime <- applicationRuntime app
    forM_ (init committed.entries) $ \entry -> Runtime.deliver runtime entry >> Runtime.foldIngress runtime entry
    let final = last committed.entries
        finalToken = Token (Just final.color) final.payload
    -- the process died after acceptance, before its fold
    _ <- Runtime.deliver runtime final
    Runtime.manifestAccepted runtime committed.entries `shouldReturn` True
    place app "life.runs" >>= (`shouldSatisfy` elem finalToken)
    setAppHooks app $ \h ->
      h
        { aroundProjectReconciliation = \real -> do
            place app "life.runs" >>= (`shouldSatisfy` notElem finalToken)
            real
        }
    reconcile app "restart" `shouldReturn` True
    closeApplication app

  it "test_v5_application_fails_closed_when_manifest_identity_conflicts_with_canonical_history" . withTempRoot $ \tmp -> do
    w <- newWorld False False False
    app <- openWorld tmp w objectRunner id
    projected <- I.projectReconciliation app.normalizer
    Just committed <- I.stageReconciliation app.ingress subject projected
    let conflicting = withPayload (firstEntry committed.entries) (dump (headSeen (T.replicate 40 "c")))
    runtime <- applicationRuntime app
    _ <- Runtime.deliver runtime conflicting
    forM_ (drop 1 committed.entries) (Runtime.deliver runtime)
    reconcile app "restart" `shouldThrow` runtimeError "conflicts with canonical History"
    closeApplication app

  it "test_v5_application_checks_later_history_conflicts_before_replaying_an_earlier_gap" . withTempRoot $ \tmp -> do
    w <- newWorld False False False
    app <- openWorld tmp w objectRunner id
    projected <- I.projectReconciliation app.normalizer
    Just committed <- I.stageReconciliation app.ingress subject projected
    runtime <- applicationRuntime app
    _ <- Runtime.deliver runtime (committed.entries !! 1)
    _ <-
      Runtime.deliver
        runtime
        (withPayload (committed.entries !! 2) (dump HumanSeen {approval = False, changesRequested = False, unresolved = 0}))
    forM_ (drop 3 committed.entries) (Runtime.deliver runtime)
    prior <- recordsOf app
    reconcile app "restart" `shouldThrow` runtimeError "conflicts with canonical History"
    recordsOf app `shouldReturn` prior
    closeApplication app

  it "test_v5_application_does_not_deliver_reconciliation_when_webhook_custody_commits_after_stage" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    w <- newWorld False False False
    app <- openWorld tmp w objectRunner id
    setAppHooks app $ \h ->
      h
        { aroundStageReconciliation = \_ _ real -> do
            manifest <- real
            newDelivery >>= pendingInbox path
            pure manifest
        }
    reconcile app "startup" `shouldReturn` False
    delivered app `shouldReturn` []
    closeApplication app

  it "test_v5_application_does_not_read_provider_while_webhook_custody_is_pending" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    w <- newWorld False False False
    app <- openWorld tmp w objectRunner id
    newDelivery >>= pendingInbox path
    reconcile app "startup" `shouldReturn` False
    readIORef w.fake.pullCalls `shouldReturn` 0
    delivered app `shouldReturn` []
    closeApplication app

  it "test_v5_application_does_not_stage_provider_projection_when_custody_arrives_during_read" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    w <- newWorld False False False
    app <- openWorld tmp w objectRunner id
    writeIORef w.pullHook $ \real -> do
      pull <- real
      newDelivery >>= pendingInbox path
      pure pull
    reconcile app "startup" `shouldReturn` False
    query path "SELECT COUNT(*) FROM v5_reconciliation_manifests" [] `shouldReturn` [[S.SQLInteger 0]]
    delivered app `shouldReturn` []
    closeApplication app

  it "test_current_claim_fails_closed_until_fresh_provider_lifecycle_is_in_the_host_grant" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    w <- newWorld False False False
    app <- openWorld tmp w objectRunner id
    processObservation app (observationOf identity "pull_request" "opened") Nothing
    modifyPull w (\p -> pullWith p p.head p.base True p.state p.closed)
    currentClaim app `shouldThrow` (\(e :: GitHubBoundaryError) -> "not staged" `T.isInfixOf` e.message)
    drafted <- newDelivery
    processObservation app (observationOf drafted "pull_request" "converted_to_draft") Nothing
    (.phase) <$> currentClaim app `shouldReturn` PhaseQuiescent
    closeApplication app

  it "test_v5_application_folds_draft_and_ready_in_the_host_grants_canonical_order" . withTempRoot $ \tmp -> do
    w <- newWorld True False False
    app <- openWorld tmp w objectRunner id
    drafted <- newDelivery
    processObservation app (observationOf drafted "pull_request" "opened") Nothing
    [life] <- place app "life.state"
    claim <- I.claim app.ingress subject
    (data' life "phase", data' life "incarnation", data' life "head")
      `shouldBe` (String (spelling claim.phase), Int claim.incarnation, String claim.head)
    (claim.phase, claim.incarnation, claim.head) `shouldBe` (PhaseQuiescent, 1, aaa)
    readIORef w.comments `shouldReturn` []
    modifyPull w (\p -> pullWith p p.head p.base False p.state p.closed)
    readied <- newDelivery
    processObservation app (observationOf readied "pull_request" "ready_for_review") Nothing
    [life'] <- place app "life.state"
    claim' <- I.claim app.ingress subject
    (data' life' "phase", data' life' "incarnation", data' life' "head")
      `shouldBe` (String (spelling claim'.phase), Int claim'.incarnation, String claim'.head)
    (claim'.phase, claim'.incarnation, claim'.head) `shouldBe` (PhaseRunning, 2, aaa)
    closeApplication app

  it "test_v5_application_drains_the_real_topology_against_provider_backed_gates" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    w <- newWorld False False False
    settled <- newIORef []
    runner <- newRunner
    app <- openSettling tmp w runner.agent (\ops -> modifyIORef' settled (<> [ops])) id
    processObservation app (observationOf identity "pull_request" "synchronize") Nothing
    outcome <- settle app
    [life] <- place app "life.state"
    [ready] <- place app "ready.snap"
    (data' life "incarnation", data' life "head") `shouldBe` (Int 1, String aaa)
    (data' ready "review", data' ready "checks") `shouldBe` (String "clear", String "success")
    outcome.ready `shouldBe` False
    any (not . Set.null) <$> readIORef settled `shouldReturn` True
    readinessCount w >>= (`shouldSatisfy` (> 0))
    closeApplication app

  it "test_v5_readiness_announcement_defers_behind_dashboard_webhook_custody_then_wakes" . withTempRoot $ \tmp -> do
    (app, w, path, blocker) <- dashboardCustodyRace tmp False
    rs <- recordsOf app
    [deferred] <- place app "ready.deferred"
    data' deferred "blocker" `shouldBe` String blocker
    completedVariants "ready.gate" rs `shouldSatisfy` elem (String "ADeferred")
    completedVariants "ready.gate" rs `shouldSatisfy` notElem (String "ABlocked")
    readinessCount w `shouldReturn` 0
    unrelated <- newDelivery
    insertInbox path unrelated "terminal"
    _ <- settle app
    place app "ready.deferred" >>= (`shouldSatisfy` (not . null))
    readinessCount w `shouldReturn` 0
    terminalize path blocker
    _ <- settle app
    place app "ready.deferred" `shouldReturn` []
    readinessCount w `shouldReturn` 1
    wakes <- deliveredFrom "on_announce_wake" app
    length wakes `shouldBe` 1
    wakes `shouldSatisfy` all (T.isPrefixOf "v5-announce-wake:")
    requests <- requestedWork "ready.gate" <$> recordsOf app
    length requests `shouldBe` 2
    (requests !! 0) `shouldBe` (requests !! 1)
    closeApplication app

  it "test_v5_readiness_wakes_after_the_exact_blocker_manifest_folds_before_inbox_ack" . withTempRoot $ \tmp -> do
    (app, w, _, blocker) <- dashboardCustodyRace tmp False
    processObservation app (observationOf blocker "pull_request" "synchronize") Nothing
    _ <- settle app
    place app "ready.deferred" `shouldReturn` []
    readinessCount w `shouldReturn` 1
    length <$> deliveredFrom "on_announce_wake" app `shouldReturn` 1
    closeApplication app

  it "test_v5_deferred_announcement_settles_old_authority_moved_before_fresh_request" . withTempRoot $ \tmp -> do
    (app, w, _, blocker) <- dashboardCustodyRace tmp False
    modifyPull w (\p -> pullWith p p.head (T.replicate 40 "c") p.draft p.state p.closed)
    modifyIORef' w.fake.repoPolicy (\p -> RepositoryPolicy p.strict p.updateRequired p.requiredChecks p.requiredApprovals p.conversationResolution p.source "policy-2")
    processObservation app (observationOf blocker "pull_request" "synchronize") Nothing
    _ <- settle app
    rs <- recordsOf app
    let requests = requestedWork "ready.gate" rs
    length requests `shouldBe` 3
    (requests !! 0) `shouldBe` (requests !! 1)
    (member "base" (requests !! 2), member "policy" (requests !! 2)) `shouldBe` (String (T.replicate 40 "c"), String "policy-2")
    completedVariants "ready.gate" rs `shouldBe` [String "ADeferred", String "AMoved", String "ALanded"]
    readinessCount w `shouldReturn` 1
    closeApplication app

  it "test_v5_readiness_wakes_when_custody_terminalizes_during_the_deferral_fold" . withTempRoot $ \tmp -> do
    (app, w, _, blocker) <- dashboardCustodyRace tmp True
    rs <- recordsOf app
    place app "ready.deferred" `shouldReturn` []
    let deferred =
          [ r.result
          | RActivityCompleted r <- rs
          , netPathText r.transition == "ready.gate"
          , member "$variant" r.result == String "ADeferred"
          ]
    map (member "blocker") deferred `shouldBe` [String blocker]
    readinessCount w `shouldReturn` 1
    length <$> deliveredFrom "on_announce_wake" app `shouldReturn` 1
    closeApplication app

  it "test_v5_announcement_wake_replays_after_restart_when_delivery_ack_is_lost" . withTempRoot $ \tmp -> do
    (first, w, path, blocker) <- dashboardCustodyRace tmp False
    closeApplication first
    terminalize path blocker
    let opened = newRunner >>= \runner -> openWorld tmp w runner.agent id
    second <- opened
    setRuntimeHooks second $ \h ->
      h {aroundAnnounceWake = \real -> real >> throwIO (RuntimeError "announcement wake acknowledgement lost")}
    settle second `shouldThrow` runtimeError "acknowledgement lost"
    closeApplication second
    third <- opened
    _ <- settle third
    readinessCount w `shouldReturn` 1
    wakes <- deliveredFrom "on_announce_wake" third
    length wakes `shouldBe` 1
    wakes `shouldSatisfy` all (T.isPrefixOf "v5-announce-wake:")
    closeApplication third

  it "test_v5_review_waits_for_custodied_authority_then_retries_without_losing_its_baton" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    blocker <- newDelivery
    let path = tmp </> "webhooks.sqlite3"
    reviewCalls <- newIORef []
    base <- newRunner
    let runner =
          withReview base.agent $
            ( \url request inv -> do
                modifyIORef' reviewCalls (<> [(inv.operation, inv.attempt)])
                maybe (expectationFailure "is_current is required") (`shouldReturn` True) inv.isCurrent
                reviewClear url request (Invocation inv.operation 1 inv.isCurrent)
            )
    w <- newWorld False False False
    app <- openWorld tmp w runner id
    processObservation app (observationOf identity "pull_request" "synchronize") Nothing
    pendingInbox path blocker
    _ <- settle app
    rs <- recordsOf app
    readIORef reviewCalls `shouldReturn` []
    [() | RActivityFailed _ <- rs] `shouldBe` []
    [() | RFiringFailed _ <- rs] `shouldBe` []
    [deferred] <- place app "review.deferred"
    data' deferred "blocker" `shouldBe` String blocker
    terminalize path blocker
    _ <- settle app
    readIORef reviewCalls `shouldReturn` [("review:" <> subject <> ":" <> aaa <> ":i1", 2)]
    place app "review.deferred" `shouldReturn` []
    [ready] <- place app "ready.snap"
    data' ready "review" `shouldBe` String "clear"
    closeApplication app

  it "test_v5_review_wake_replays_after_restart_when_delivery_ack_is_lost" . withTempRoot $ \tmp -> do
    let path = tmp </> "webhooks.sqlite3"
    blocker <- newDelivery
    reviewCalls <- newIORef []
    base <- newRunner
    let runner =
          withReview base.agent $
            ( \url request inv -> do
                modifyIORef' reviewCalls (<> [inv.attempt])
                maybe (expectationFailure "is_current is required") (`shouldReturn` True) inv.isCurrent
                reviewClear url request (Invocation inv.operation 1 inv.isCurrent)
            )
        opened = newWorld False False False >>= \w -> openWorld tmp w runner id
    first <- opened
    identity <- newDelivery
    processObservation first (observationOf identity "pull_request" "synchronize") Nothing
    pendingInbox path blocker
    _ <- settle first
    closeApplication first
    terminalize path blocker
    second <- opened
    setRuntimeHooks second $ \h ->
      h {aroundReviewWake = \real -> real >> throwIO (RuntimeError "review wake acknowledgement lost")}
    settle second `shouldThrow` runtimeError "acknowledgement lost"
    closeApplication second
    third <- opened
    _ <- settle third
    readIORef reviewCalls `shouldReturn` [2]
    wakes <- deliveredFrom "on_review_round_wake" third
    length wakes `shouldBe` 1
    wakes `shouldSatisfy` all (T.isPrefixOf "v5-review-wake:")
    closeApplication third

  forM_ [(False, "identity is malformed"), (True, "has no deferred round")] $ \(derivedIdentity, message) ->
    it ("test_v5_restart_fails_closed_on_malformed_review_wake_history[" <> show derivedIdentity <> "]") . withTempRoot $ \tmp -> do
      w <- newWorld False False False
      runner <- newRunner
      first <- openWorld tmp w runner.agent id
      runtime <- applicationRuntime first
      blocker <- newDelivery
      let wake = RoundWake {operation = "review:" <> subject <> ":" <> aaa <> ":i1", attempt = 1, blocker}
          identity = if derivedIdentity then Runtime.reviewWakeIdentity wake else "malformed-review-wake-identity"
      _ <- Runtime.deliverReviewWake runtime wake identity
      closeApplication first
      w' <- newWorld False False False
      openWorld tmp w' runner.agent id `shouldThrow` runtimeError message

  forM_ [(False, "identity is malformed"), (True, "has no deferred request")] $ \(derivedIdentity, message) ->
    it ("test_v5_restart_fails_closed_on_malformed_announcement_wake_history[" <> show derivedIdentity <> "]") . withTempRoot $ \tmp -> do
      w <- newWorld False False False
      runner <- newRunner
      first <- openWorld tmp w runner.agent id
      runtime <- applicationRuntime first
      blocker <- newDelivery
      let wake =
            AWake
              { op = "ready:" <> aaa <> ":i1"
              , incarnation = 1
              , head = aaa
              , base = T.replicate 40 "b"
              , policy = "policy-1"
              , strictBase = True
              , baseCurrent = True
              , blocker
              }
          identity = if derivedIdentity then Runtime.announceWakeIdentity wake else "malformed-announce-wake-identity"
      _ <- Runtime.deliverAnnounceWake runtime wake identity
      closeApplication first
      w' <- newWorld False False False
      openWorld tmp w' runner.agent id `shouldThrow` runtimeError message

  forM_ ["none", "queued", "published", "started"] $ \restartCut ->
    it ("test_initial_summary_lands_before_review_and_survives_restart[" <> restartCut <> "]") . withTempRoot $ \tmp -> do
      w <- newWorld False False False
      events <- newIORef []
      base <- newRunner
      let runner =
            withReview base.agent $
              ( \url request inv -> do
                  summaries <- filter ("<!-- hamsterdan:dashboard -->" `T.isInfixOf`) <$> bodies w
                  length summaries `shouldBe` 1
                  firstEntry summaries `shouldSatisfy` T.isInfixOf "reviewing"
                  modifyIORef' events (<> ["review started after summary" :: Text])
                  reviewClear url request inv
              )
          open' = openWorld tmp w runner $ \o -> o {dispatchPath = Just (tmp </> "activity-dispatch.sqlite3")}
      app0 <- open'
      opened <- newDelivery
      processObservation app0 (observationOf opened "pull_request" "opened") Nothing
      _ <- settle app0
      readIORef events `shouldReturn` []
      rs <- recordsOf app0
      [() | RActivityRequested r <- rs, r.activity == "review_agent"] `shouldBe` []
      app1 <-
        if restartCut == "queued"
          then do
            closeApplication app0
            a <- open'
            _ <- settle a
            readIORef events `shouldReturn` []
            pure a
          else pure app0
      runDurableActivities app1 1 `shouldReturn` 1
      app2 <-
        if restartCut == "published"
          then closeApplication app1 >> open'
          else pure app1
      _ <- settle app2
      readIORef events `shouldReturn` ["review started after summary"]
      app3 <-
        if restartCut == "started"
          then do
            closeApplication app2
            a <- open'
            _ <- settle a
            readIORef events `shouldReturn` ["review started after summary"]
            pure a
          else pure app2
      let loop :: Int -> IO ()
          loop 0 = expectationFailure "summary updates did not settle"
          loop n = do
            processed <- runDurableActivities app3 20
            _ <- settle app3
            unless (processed == 0) (loop (n - 1))
      loop 20
      summaries <- filter ("<!-- hamsterdan:dashboard -->" `T.isInfixOf`) <$> bodies w
      length summaries `shouldBe` 1
      firstEntry summaries `shouldSatisfy` T.isInfixOf "✅ clear"
      closeApplication app3

  it "test_v5_durable_publications_use_an_instance_queue_owned_by_the_application" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    w <- newWorld False False False
    runner <- newRunner
    let dispatchPath = tmp </> "activity-dispatch.sqlite3"
    app <- openWorld tmp w runner.agent $ \o -> o {dispatchPath = Just dispatchPath}
    processObservation app (observationOf identity "pull_request" "synchronize") Nothing
    _ <- settle app
    session <- Local.openLocalDispatch dispatchPath "inspector" Local.defaultLocalDispatchOptions
    production <- Local.worker session ["publication"] Nothing
    isJust <$> Local.claim production `shouldReturn` False
    runDurableActivities app 20 >>= (`shouldSatisfy` (> 0))
    _ <- settle app
    Local.close production
    closeApplication app

  it "test_v5_comment_classification_is_frozen_and_settled_only_after_manifest_commit" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    w <- newWorld False False False
    runner <- newRunner
    settled <- newIORef []
    app <- openSettling tmp w runner.agent (\ops -> modifyIORef' settled (<> [ops])) id
    let observation = observationOf identity "issue_comment" "created"
        conversation = conversationOf identity "please change it"
    processObservation app observation (Just conversation)
    processObservation app observation (Just conversation)
    lastPayload app identity
      `shouldReturn` Object [("id", String "19"), ("kind", String "change"), ("arg", String "rename the value"), ("authorized", Bool True)]
    let operation = "conversation:owner/repo:pr:7:delivery:" <> identity
    readIORef runner.conversationCalls `shouldReturn` 1
    readIORef settled `shouldReturn` [Set.singleton operation, Set.singleton operation]
    closeApplication app

  forM_
    [ "push:comment:5312521927:" <> aaa <> ":i1"
    , "findings:" <> aaa <> ":i1"
    , "rerun:L1:fingerprint"
    , "reminder:timer-1"
    , "reply:comment-1"
    , "dash:digest-1"
    , "ready:" <> aaa <> ":i1"
    ]
    $ \recoveryOperation ->
      it ("test_v5_publication_recovery_preserves_the_explicit_operation_at_ingress[" <> T.unpack recoveryOperation <> "]") . withTempRoot $ \tmp -> do
        identity <- newDelivery
        base <- newRunner
        let runner =
              withConverse base.agent $
                ( \_ request inv -> do
                    [declaration] <- pure [d | d <- request.allowedIntents, lookup "type" d == Just (String "recover_publication")]
                    Object declaration
                      `shouldBe` Object
                        [ ("type", String "recover_publication")
                        , ("mutation", Bool False)
                        , ("arguments", Array [String "operation"])
                        , ("requires_explicit", Bool True)
                        ]
                    inv.attempt `shouldBe` 1
                    maybe (expectationFailure "is_current is required") (`shouldReturn` True) inv.isCurrent
                    pure
                      ( ConversationResult
                          request.repository
                          request.pullRequest
                          request.epoch
                          request.head
                          request.base
                          [[("type", String "recover_publication"), ("arguments", Object [("operation", String recoveryOperation)])]]
                      )
                )
        w <- newWorld False False False
        app <- openWorld tmp w runner id
        processObservation
          app
          (observationOf identity "issue_comment" "created")
          (Just (conversationOf identity ("recover publication for `" <> recoveryOperation <> "`")))
        lastPayload app identity
          `shouldReturn` Object
            [("id", String "19"), ("kind", String "recover_publication"), ("arg", String recoveryOperation), ("authorized", Bool True)]
        closeApplication app

  forM_
    [ ([("operation", String "push:comment:1:head:i1")], "recover the publication")
    , ([("target", String "mutation"), ("operation", String "push:comment:1:head:i1")], "recover push:comment:1:head:i1")
    , ([("operation", String "push:bad operation")], "recover push:bad operation")
    , ([("operation", String (T.replicate 257 "p"))], "recover " <> T.replicate 257 "p")
    ]
    $ \(arguments, comment) ->
      it ("test_v5_publication_recovery_requires_one_bounded_verbatim_operation[" <> T.unpack (T.take 40 comment) <> "]") . withTempRoot $ \tmp -> do
        identity <- newDelivery
        base <- newRunner
        let runner =
              withConverse base.agent $
                ( \_ request _ ->
                    pure
                      ( ConversationResult
                          request.repository
                          request.pullRequest
                          request.epoch
                          request.head
                          request.base
                          [[("type", String "recover_publication"), ("arguments", Object arguments)]]
                      )
                )
        w <- newWorld False False False
        app <- openWorld tmp w runner id
        processObservation app (observationOf identity "issue_comment" "created") (Just (conversationOf identity comment))
        lastPayload app identity
          `shouldReturn` Object [("id", String "19"), ("kind", String ""), ("arg", String ""), ("authorized", Bool False)]
        closeApplication app

  it "test_comment_route_settlement_replays_after_crash_following_manifest_commit" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    w <- newWorld False False False
    runner <- newRunner
    let operation = "conversation:owner/repo:pr:7:delivery:" <> identity
    settlements <- newIORef (0 :: Int)
    let crashOnce operations = do
          operations `shouldBe` Set.singleton operation
          modifyIORef' settlements (+ 1)
          n <- readIORef settlements
          when (n == 1) $ throwIO (RuntimeError "crash after manifest commit")
    app <- openSettling tmp w runner.agent (crashOnce) id
    let observation = observationOf identity "issue_comment" "created"
        conversation = conversationOf identity "please change it"
    processObservation app observation (Just conversation) `shouldThrow` runtimeError "crash after manifest commit"
    processObservation app observation (Just conversation)
    readIORef runner.conversationCalls `shouldReturn` 1
    readIORef settlements `shouldReturn` 2
    closeApplication app

  it "test_ambiguous_petrus_delivery_reopens_history_before_exact_retry" . withTempRoot $ \tmp -> do
    identity <- newDelivery
    w <- newWorld False False False
    runner <- newRunner
    app <- openWorld tmp w runner.agent id
    let observation = observationOf identity "pull_request" "synchronize"
    runtime <- applicationRuntime app
    original <- Runtime.engine runtime >>= makeStableName
    setRuntimeHooks app $ \h -> h {aroundEngineDeliver = \real -> real >> throwIO (RuntimeError "acknowledgement lost")}
    processObservation app observation Nothing `shouldThrow` runtimeError "acknowledgement lost"
    reopened <- Runtime.engine runtime >>= makeStableName
    (reopened /= original) `shouldBe` True
    -- The patch belonged to the closed Engine.
    setRuntimeHooks app (const defaultRuntimeHooks)
    processObservation app observation Nothing
    map (.identity) <$> delivered app
      `shouldReturn` ["github-delivery:" <> identity <> ":" <> s | s <- ["on_head", "on_ready", "on_human", "on_runs"]]
    closeApplication app

  it "test_v5_settle_reaches_timer_fixed_point_and_returns_canonical_store_deadline" . withTempRoot $ \tmp -> do
    clock <- newIORef 1000000
    identity <- newDelivery
    w <- newWorld False False False
    app <- timerApplication tmp clock w
    processObservation app (observationOf identity "pull_request" "synchronize") Nothing
    armed <- settle app
    armed.nextMaturation `shouldBe` float 11.0
    applicationRuntime app >>= Runtime.timerCommand >>= (`shouldBe` Nothing)
    [state] <- place app "rem.state"
    member "kind" (data' state "clock") `shouldBe` String "armed"
    writeIORef clock 11000000
    rearmed <- settle app
    rearmed.nextMaturation `shouldBe` float 21.0
    [state'] <- place app "rem.state"
    data' state' "matured" `shouldBe` Array [String ("timer:" <> subject <> ":i1:s0")]
    deliveredFrom "on_timer" app `shouldReturn` ["v5-timer-due:timer:" <> subject <> ":i1:s0:11000000"]
    closeApplication app

  forM_ ["before_history", "after_history"] $ \cut ->
    it ("test_timer_ack_crash_cuts_replay_one_identity_and_original_deadline[" <> T.unpack cut <> "]") . withTempRoot $ \tmp -> do
      clock <- newIORef 1000000
      identity <- newDelivery
      w <- newWorld False False False
      first <- timerApplication tmp clock w
      processObservation first (observationOf identity "pull_request" "synchronize") Nothing
      runtime <- applicationRuntime first
      -- freeze the TimerCommand in canonical History
      _ <- Runtime.drain runtime 500
      setRuntimeHooks first $ \h ->
        h {aroundTimerAck = \real -> when (cut == "after_history") (() <$ real) >> throwIO (RuntimeError (cut <> " timer ack"))}
      settle first `shouldThrow` runtimeError cut
      closeApplication first
      second <- timerApplication tmp clock w
      outcome <- settle second
      outcome.nextMaturation `shouldBe` float 11.0
      deliveredFrom "on_timer_command_applied" second
        `shouldReturn` ["v5-timer-command-applied:timer-command:" <> subject <> ":g1"]
      closeApplication second

  it "test_timer_maturity_history_marker_crash_replays_without_duplicate_fact" . withTempRoot $ \tmp -> do
    clock <- newIORef 1000000
    identity <- newDelivery
    w <- newWorld False False False
    first <- timerApplication tmp clock w
    processObservation first (observationOf identity "pull_request" "synchronize") Nothing
    (.nextMaturation) <$> settle first `shouldReturn` float 11.0
    writeIORef clock 11000000
    setRuntimeHooks first $ \h -> h {aroundTimerDue = \real -> real >> throwIO (RuntimeError "maturity marker lost")}
    settle first `shouldThrow` runtimeError "maturity marker lost"
    closeApplication first
    second <- timerApplication tmp clock w
    (.nextMaturation) <$> settle second `shouldReturn` float 21.0
    deliveredFrom "on_timer" second `shouldReturn` ["v5-timer-due:timer:" <> subject <> ":i1:s0:11000000"]
    closeApplication second

  it "test_disposable_runnable_index_rebuilds_from_intact_timer_custody" . withTempRoot $ \tmp -> do
    clock <- newIORef 1000000
    identity <- newDelivery
    w <- newWorld False False False
    first <- timerApplication tmp clock w
    processObservation first (observationOf identity "pull_request" "synchronize") Nothing
    deadline <- (.nextMaturation) <$> settle first
    closeApplication first
    deadline `shouldBe` float 11.0
    let path = tmp </> "runnable.sqlite3"
        seconds = fmap (\case FloatNumber d -> d; IntNumber i -> fromInteger i)
    index <- Runnable.openRunnableIndex path
    Runnable.replaceTimer index subject (seconds deadline)
    Runnable.close index
    removeFile path
    second <- timerApplication tmp clock w
    rebuiltDeadline <- (.nextMaturation) <$> settle second
    rebuilt <- Runnable.openRunnableIndex path
    Runnable.replaceTimer rebuilt subject (seconds rebuiltDeadline)
    rebuiltDeadline `shouldBe` deadline
    Runnable.takeDueAt rebuilt 100 11.0 `shouldReturn` [subject]
    Runnable.close rebuilt
    closeApplication second

  it "test_v5_close_cancels_exact_host_timer_before_reminder_loop_retires" . withTempRoot $ \tmp -> do
    clock <- newIORef 1000000
    w <- newWorld False False False
    app <- timerApplication tmp clock w
    opened <- newDelivery
    processObservation app (observationOf opened "pull_request" "synchronize") Nothing
    (.nextMaturation) <$> settle app `shouldReturn` float 11.0
    modifyPull w (\p -> pullWith p p.head p.base p.draft "closed" True)
    closed <- newDelivery
    processObservation app (observationOf closed "pull_request" "closed") Nothing
    outcome <- settle app
    outcome.nextMaturation `shouldBe` Nothing
    place app "rem.state" `shouldReturn` []
    [done] <- place app "rem.done"
    data' done "reason" `shouldBe` String "closed"
    query (tmp </> "application" </> "timers.sqlite3") "SELECT state FROM v5_timers ORDER BY timer_id" []
      `shouldReturn` [[S.SQLText "cancelled"]]
    closeApplication app

  it "test_v5_comment_classification_reads_the_published_findings_and_board_facts" . withTempRoot $ \tmp -> do
    let reviewFinding =
          [ ("id", String "f-ttl-unit")
          , ("path", String "gate.py")
          , ("line", Int 10)
          , ("related_locations", Array [])
          , ("title", String "Interpret the lease TTL as seconds")
          , ("body", String "ttl_seconds is passed as minutes.")
          , ("severity", String "high")
          , ("confidence", Float 1.0)
          , ("evidence", String "timedelta(minutes=ttl_seconds)")
          , ("blocking", Bool True)
          , ("suggestion", String "")
          ]
    captured <- newIORef []
    base <- newRunner
    let runner =
          withConverse
            ( withReview base.agent $ \_ request _ ->
                pure (ReviewResult request.repository request.pullRequest request.epoch request.head request.base "blocking" [reviewFinding] [])
            )
            ( \url request inv -> do
                modifyIORef' captured (<> [request])
                base.agent.converse url request inv
            )
    w <- newWorld False False False
    app <- openWorld tmp w runner id
    opened <- newDelivery
    processObservation app (observationOf opened "pull_request" "opened") Nothing
    _ <- settle app
    identity <- newDelivery
    processObservation app (observationOf identity "issue_comment" "created") (Just (conversationOf identity "apply your suggested fixes"))
    [request] <- readIORef captured
    map Object request.findings `shouldBe` [Object reviewFinding]
    let kinds = [k | fact <- request.gates, Just (String k) <- [lookup "kind" fact]]
    Set.fromList ["state", "checks", "review", "findings"] `Set.isSubsetOf` Set.fromList kinds `shouldBe` True
    [findingsFact] <- pure [fact | fact <- request.gates, lookup "kind" fact == Just (String "findings")]
    let body = maybe Null id (lookup "body" findingsFact)
    (member "count" body, member "blocking" body) `shouldBe` (Int 1, Int 1)
    closeApplication app
