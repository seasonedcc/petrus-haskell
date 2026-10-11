-- | @tests/integration/host/test_service.py@: the host composition, the
-- custody worker, the scheduler, and the real V5 application behind it.
-- The FastAPI cases are in "ApiSpec" and the operator inspection cases in
-- "CliSpec".
module ServiceSpec (spec, SimulatedProcessDeath (..)) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (Exception (..), SomeException, throwIO, try)
import Control.Monad (forM_, replicateM, unless, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite3 qualified as S
import Hamsterdan.Agents.Protocol (AgentProtocolError (..), AgentRunner (..), Invocation (..))
import Hamsterdan.Contracts.Codec (dump)
import Hamsterdan.Contracts.Readiness (AdmittedConversation (..))
import Hamsterdan.Contracts.ReadinessV5 qualified as C
import Hamsterdan.GitHub.Config (botLogin)
import Hamsterdan.GitHub.Gateway (GitHubAuthority (..))
import Hamsterdan.GitHub.Models (Transport (..))
import Hamsterdan.GitHub.Routing qualified as Routing
import Hamsterdan.GitHub.Webhooks (Disposition (..), ErrorClass (..), Observation (..), Receipt (..))
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Binding (InstanceBinding (..), Topology (..), readInstanceBinding)
import Hamsterdan.Host.Python (RuntimeError (..), ValueError (..), baseExceptionFromException, baseExceptionToException, dumpsSortedText)
import Hamsterdan.Host.Runnable qualified as Runnable
import Hamsterdan.Host.Service
import Hamsterdan.Host.Service qualified as Host
import Hamsterdan.Host.V5.Application (ApplicationOptions (..), applicationRuntime, currentClaim)
import Hamsterdan.Host.V5.Claim (CurrentClaim (..))
import Hamsterdan.Host.V5.Runtime (asActivity, gateImplementation, hostGateDefinition)
import Hamsterdan.Host.V5.Runtime qualified as Runtime
import Hamsterdan.Readiness.NetV5.Gating (GateDefinition (..))
import IngressSpec (newDelivery)
import IngressApplicationSpec (reviewClear)
import Petrus.Activity
import Petrus.Impetus.History.Records (ExternalEventDelivered (..), Record (..))
import Petrus.Json (Json (..), parseJson, pythonLoads)
import Petrus.Motus.Dispatch (ActivityOutcome (..))
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Worker (WorkerOptions (..), closeWorker, defaultWorkerOptions, newWorker, runAvailable)
import ServiceSupport
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Hspec
import TestSupport (runtimeError, withTempRoot)
import TestUpdates

-- | @class SimulatedProcessDeath(BaseException)@.
data SimulatedProcessDeath = SimulatedProcessDeath
  deriving stock (Eq, Show)

instance Exception SimulatedProcessDeath where
  toException = baseExceptionToException
  fromException = baseExceptionFromException

instance7 :: Text
instance7 = "github:44:31:pr:7"

key7 :: InstanceKey
key7 = InstanceKey 44 31 7

pendingNow :: HostService -> IO [Observation]
pendingNow host = Custody.pending host.custody 100 Nothing

firstPending :: HostService -> IO Observation
firstPending host =
  pendingNow host >>= \case
    item : _ -> pure item
    [] -> expectationFailure "no pending delivery" >> error "unreachable"

statusOf :: HostService -> Text -> IO (Maybe Text)
statusOf host = Custody.status host.custody

webhooks :: FilePath -> FilePath
webhooks root = root </> "webhooks.sqlite3"

app0 :: Harness -> IO FakeApp
app0 h =
  made h >>= \case
    app : _ -> pure app
    [] -> expectationFailure "no application was made" >> error "unreachable"

appAt :: Harness -> Int -> IO FakeApp
appAt h n = (!! n) <$> made h

setHooks :: HostService -> (ServiceHooks -> ServiceHooks) -> IO ()
setHooks host = modifyIORef' host.hooks

bound :: FilePath -> Integer -> Integer -> IO FilePath
bound tmp repository pr = do
  let root = tmp </> "applications" </> "44" </> show repository </> show pr
  bindApplication root (if repository == 999 then "owner/inactive" else "owner/one")
  pure root

gate :: Text -> [Text] -> ([(Text, Json)] -> ActivityExecutionContext -> IO Json) -> GateDefinition
gate name parameters function =
  case activityDeclaration name Nothing of
    Right declaration -> GateDefinition (defineActivity declaration parameters function) [] []
    Left problem -> error (T.unpack problem)

activityFailureOf :: ActivityError -> ActivityFailureFields
activityFailureOf (ActivityError failure) = failureFields failure

-- | The identities of a History's @ExternalEventDelivered@ records, from
-- the file.
historyDeliveries :: FilePath -> IO [(Text, Text)]
historyDeliveries path = do
  content <- BS.readFile path
  pure
    [ (identity, source)
    | line <- BC.lines content
    , Right (Object members) <- [parseJson pythonLoads line]
    , lookup "record" members == Just (String "ExternalEventDelivered")
    , Just (String identity) <- [lookup "identity" members]
    , let source = case lookup "source" members of
            Just (String s) -> s
            _ -> ""
    ]

loadedV5 :: HostService -> IO [Text]
loadedV5 host =
  loadedApplication host key7 >>= \case
    Just HostApplication {v5 = Just app} -> do
      records <- applicationRuntime app >>= Runtime.records
      pure [r.identity | RExternalEventDelivered r <- records]
    _ -> expectationFailure "no V5 application is loaded" >> pure []

reminders :: V5Provider -> IO Int
reminders provider = do
  items <- readIORef provider.comments
  pure (length [() | item <- items, Just (String body) <- [lookup "body" item], "hamsterdan:reminder" `T.isInfixOf` body])

inboxRow :: FilePath -> Text -> IO [[S.SQLData]]
inboxRow root delivery = sqlRows (webhooks root) "SELECT status,attempts,reason,error_class FROM inbox WHERE delivery_id=?" [S.SQLText delivery]

grants :: FilePath -> Text -> IO [[S.SQLData]]
grants root columns = sqlRows (webhooks root) ("SELECT " <> columns <> " FROM v5_authority_grants WHERE subject='github:44:31:pr:7'") []

v5Harness :: FilePath -> V5Provider -> AgentRunner -> (ServiceOptions -> ServiceOptions) -> IO Harness
v5Harness tmp provider runner configure = do
  clients <- newFakeClients
  writeIORef clients.operationTransport (Just (providerTransport provider))
  h <-
    harness
      tmp
      defaults
        { givenClients = Just clients
        , factory = Just v5ApplicationFactory
        , reconcileRegistry = False
        , configure = configure . withRunner runner
        }
  activateRepositories h.host [(31, "owner/one")]
  pure h

wait1 :: MVar () -> IO Bool
wait1 signal = isJust <$> timeout 1000000 (readMVar signal)

spec :: Spec
spec = describe "tests/integration/host/test_service.py" $ do
  it "test_agent_route_is_claimed_from_explicit_execution_identity_before_start" . withTempRoot $ \tmp -> do
    events <- newIORef []
    let runner =
          v5Runner
            { review = \_ _ inv -> do
                modifyIORef' events (<> ["start:" <> inv.operation <> ":" <> T.pack (show inv.attempt)])
                pure (error "the routed runner's result is opaque here")
            }
        agents = noAgentCustody {claim = \op -> modifyIORef' events (<> ["claim:" <> op])}
    h <- harness tmp defaults {reconcileRegistry = False, configure = withAgents agents . withRunner runner}
    activateRepositories h.host [(31, "owner/one")]
    _ <- application h.host 44 31 7
    app <- app0 h
    let opaque = error "the review request is opaque here"
    void (app.runner.review "repository" opaque (Invocation "review:one" 1 Nothing))
    void (app.runner.review "repository" opaque (Invocation "review:one" 2 Nothing))
    readIORef events `shouldReturn` ["claim:review:one", "start:review:one:1", "claim:review:one", "start:review:one:2"]

  it "test_application_identity_roots_and_operation_clients_are_exact" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    forM_ [observationOf "a", observationOf "b", observationAt "c" 32 7, observationAt "d" 31 8] (Host.process h.host)
    apps <- made h
    length apps `shouldBe` 3
    first <- app0 h
    first.root `shouldBe` tmp </> "applications/44/31/7"
    first.instanceId `shouldBe` instance7
    map snd <$> readIORef h.clients.operationCalls `shouldReturn` [[31], [32], [31]]
    isJust first.authority.graphql `shouldBe` True
    isNothing first.options.publicationFault `shouldBe` True
    Host.close h.host
    forM_ apps $ \app -> readIORef app.closed `shouldReturn` 1
    readIORef h.clients.closed `shouldReturn` 1

  it "test_application_protocol_receives_the_full_custodied_observation" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    let item = (observationOf "full-observation") {event = "check_run", action = String "completed"}
    Host.process h.host item
    app <- app0 h
    readIORef app.observations `shouldReturn` [item]
    readIORef app.reconciles `shouldReturn` ["github-delivery:full-observation"]
    app.options.custodyPath `shouldBe` webhooks tmp
    Host.close h.host

  it "test_pump_prioritizes_pending_authority_custody_before_durable_activities" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    _ <- application h.host 44 31 7
    app <- app0 h
    events <- newIORef []
    let record event = modifyIORef' events (<> [event])
    setHooks h.host $ \hooks ->
      hooks
        { projectPendingOverride = Just (record "project" >> pure 1)
        , runDueOverride = Just (record "apply" >> pure 1)
        }
    writeIORef app.onRunDurable (\limit -> record ("activities:" <> T.pack (show limit)) >> pure 0)
    void (pump h.host 7)
    readIORef events `shouldReturn` ["project", "apply", "activities:7"]
    Host.close h.host

  it "test_pump_does_not_claim_application_queue_while_that_pr_has_pending_custody" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    _ <- application h.host 44 31 7
    _ <- application h.host 44 31 8
    [app, unrelated] <- made h
    identity <- newDelivery
    void (receiveSigned h.host envelope identity "pull_request")
    sqlExec (webhooks tmp) "UPDATE inbox SET next_attempt_at=9999999999 WHERE delivery_id=?" [S.SQLText identity]
    void (pump h.host 20)
    readIORef app.durableRuns `shouldReturn` 0
    readIORef unrelated.durableRuns `shouldReturn` 1
    Custody.acknowledge h.host.custody identity "processed"
    void (pump h.host 20)
    readIORef app.durableRuns `shouldReturn` 1
    readIORef unrelated.durableRuns `shouldReturn` 2
    Host.close h.host

  it "test_qualification_fault_is_exact_one_shot_and_disabled_by_default" $ do
    (isNothing <$> qualificationFaultFromEnvironment Nothing) `shouldReturn` True
    let raw = "{\"repository\": \"owner/one\", \"pull_request\": 7, \"boundary\": \"agent\", \"phase\": \"timed_out\", \"kind\": \"review\", \"operation\": \"next\"}"
    Just fault <- qualificationFaultFromEnvironment (Just raw)
    faultAgent fault "OWNER/ONE" 7 "review" "review:one" `shouldThrow` (\(e :: AgentProtocolError) -> e.timedOut)
    spentOperation fault `shouldReturn` Just "review:one"
    faultAgent fault "owner/one" 7 "review" "review:two"

  describe "test_qualification_fault_configuration_rejects_mismatched_shapes" $
    forM_
      [ ("phase", String "after_call")
      , ("boundary", String "comment")
      , ("operation", String "")
      , ("extra", Bool True)
      ]
      $ \(name, value) -> it (T.unpack ("[" <> name <> "]")) $ do
        let base =
              [ ("repository", String "owner/one")
              , ("pull_request", Int 7)
              , ("boundary", String "agent")
              , ("phase", String "timed_out")
              , ("kind", String "review")
              , ("operation", String "review:one")
              ]
            changed = if isJust (lookup name base) then [(k, if k == name then value else v) | (k, v) <- base] else base <> [(name, value)]
        qualificationFaultFromEnvironment (Just (dumpsSortedText (Object changed)))
          `shouldThrow` (\(ValueError m) -> m == "qualification fault configuration is malformed")

  it "test_inactive_routes_and_non_actionable_comments_are_terminal_without_application" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    let comment delivery body login association =
          (commentOf delivery body login association)
    forM_
      [ observationAt "missing" 999 7
      , (observationOf "bot")
          { event = "issue_comment"
          , action = String "created"
          , commentBody = Just "@hamsterdan-test explain the blockers"
          , actorLogin = String (botLogin h.host.config)
          }
      , comment "untrusted" "@hamsterdan-test explain the blockers" "x" "NONE"
      , comment "retired-slash-command" "/hamsterdan status" "x" "OWNER"
      , comment "mention-lookalike" "@hamsterdan explain the blockers" "x" "OWNER"
      , comment "unaddressed" "hello" "x" "OWNER"
      ]
      (Host.process h.host)
    suspend h.host
    Host.process h.host (observationOf "suspended")
    void (Routing.installation h.host.registry (String "deleted") (Int 44) (Int 23))
    Host.process h.host (observationOf "removed")
    (null <$> made h) `shouldReturn` True

  it "test_malformed_authenticated_comment_is_terminal_without_retry_loop_or_application" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    delivery <- newDelivery
    void (receiveSigned h.host (commentEnvelope "\"9\"" "@hamsterdan-test help") delivery "issue_comment")
    firstPending h.host >>= Host.process h.host
    statusOf h.host delivery `shouldReturn` Just "terminal"
    (null <$> made h) `shouldReturn` True
    Host.close h.host

  it "test_addressed_trusted_human_comment_is_routed" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    Host.process h.host (identifiedComment (commentOf "comment" "@hamsterdan-test help" "human" "MEMBER"))
    apps <- made h
    length apps `shouldBe` 1
    app <- app0 h
    [conversation] <- readIORef app.comments
    conversation.commentId `shouldBe` 9
    conversation.text `shouldBe` "help"
    readIORef app.reconciles `shouldReturn` ["github-delivery:comment"]

  let watchNarrowed tmp watched = do
        provider <- newV5Provider
        h <- harness tmp defaults {watchedAuthors = Set.fromList watched, transportFactory = Just (const (providerTransport provider))}
        pure (h, provider)

  it "test_unwatched_author_pr_is_terminal_without_journey_and_decides_once" . withTempRoot $ \tmp -> do
    (h, provider) <- watchNarrowed tmp ["someone-else"]
    deliveries <- replicateM 2 newDelivery
    forM_ deliveries $ \delivery -> do
      void (receiveSigned h.host envelope delivery "pull_request")
      firstPending h.host >>= Host.process h.host
      statusOf h.host delivery `shouldReturn` Just "terminal"
      inboxReason tmp delivery `shouldReturn` Just "author not watched"
    (null <$> made h) `shouldReturn` True
    readIORef provider.comments `shouldReturn` []
    (length . filter (== ("GET", "/repos/owner/one/pulls/7")) <$> readIORef provider.calls) `shouldReturn` 1
    Host.close h.host

  it "test_watched_author_pr_starts_the_journey" . withTempRoot $ \tmp -> do
    (h, _) <- watchNarrowed tmp ["author"]
    delivery <- newDelivery
    void (receiveSigned h.host envelope delivery "pull_request")
    firstPending h.host >>= Host.process h.host
    statusOf h.host delivery `shouldReturn` Just "terminal"
    app <- app0 h
    (map (.deliveryId) <$> readIORef app.observations) `shouldReturn` [delivery]
    Host.close h.host

  it "test_trusted_mention_opts_an_unwatched_pr_in_for_its_lifetime" . withTempRoot $ \tmp -> do
    (h, provider) <- watchNarrowed tmp ["someone-else"]
    Host.process h.host (identifiedComment (commentOf "summon" "@hamsterdan-test help" "human" "MEMBER"))
    Host.process h.host (observationOf "follow-up")
    (length <$> made h) `shouldReturn` 1
    app <- app0 h
    (map (.deliveryId) <$> readIORef app.observations) `shouldReturn` ["summon", "follow-up"]
    readIORef provider.calls `shouldReturn` []
    Host.close h.host

  it "test_bound_instance_keeps_its_journey_when_watching_narrows" . withTempRoot $ \tmp -> do
    void (bound tmp 31 7)
    (h, provider) <- watchNarrowed tmp ["someone-else"]
    Host.process h.host (observationOf "existing")
    app <- app0 h
    (map (.deliveryId) <$> readIORef app.observations) `shouldReturn` ["existing"]
    readIORef provider.calls `shouldReturn` []
    Host.close h.host

  it "test_delivery_remains_pending_when_post_activation_settlement_fails" . withTempRoot $ \tmp -> do
    let failSecond app = writeIORef app.onSettle $ do
          n <- readIORef app.settlements
          when (n == 2) $ throwIO (RuntimeError "settlement failed")
    h <- harness tmp defaults {customize = failSecond}
    delivery <- newDelivery
    void (receiveSigned h.host envelope delivery "pull_request")
    firstPending h.host >>= Host.process h.host
    app <- app0 h
    readIORef app.reconciles `shouldReturn` ["github-delivery:" <> delivery]
    statusOf h.host delivery `shouldReturn` Just "pending"
    Host.close h.host

  it "test_delivery_factory_failure_is_recorded_for_durable_retry" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults {factory = Just (\_ _ _ _ _ -> throwIO (RuntimeError "application open failed"))}
    delivery <- newDelivery
    void (receiveSigned h.host envelope delivery "pull_request")
    firstPending h.host >>= Host.process h.host
    [[S.SQLInteger attempts, nextAttempt]] <- sqlRows (webhooks tmp) "SELECT attempts,next_attempt_at FROM inbox WHERE delivery_id=?" [S.SQLText delivery]
    attempts `shouldBe` 1
    case nextAttempt of
      S.SQLFloat at -> at `shouldSatisfy` (> 0)
      S.SQLInteger at -> at `shouldSatisfy` (> 0)
      other -> expectationFailure (show other)
    statusOf h.host delivery `shouldReturn` Just "pending"
    Host.close h.host

  it "test_delivery_is_acknowledged_only_after_runnable_posture_succeeds" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    delivery <- newDelivery
    void (receiveSigned h.host envelope delivery "pull_request")
    observed <- newIORef []
    setHooks h.host $ \hooks ->
      hooks {aroundRecordPosture = \_ _ real -> (statusOf h.host delivery >>= \s -> modifyIORef' observed (<> [s])) >> real}
    firstPending h.host >>= Host.process h.host
    readIORef observed `shouldReturn` [Just "pending"]
    statusOf h.host delivery `shouldReturn` Just "terminal"
    Host.close h.host

  it "test_delivery_remains_pending_when_runnable_posture_fails" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    delivery <- newDelivery
    void (receiveSigned h.host envelope delivery "pull_request")
    setHooks h.host $ \hooks -> hooks {aroundRecordPosture = \_ _ _ -> throwIO (RuntimeError "posture failed")}
    firstPending h.host >>= Host.process h.host
    statusOf h.host delivery `shouldReturn` Just "pending"
    Host.close h.host

  it "test_retry_does_not_block_later_delivery_and_new_process_resumes_same_custody" . withTempRoot $ \tmp -> do
    first <- harness tmp defaults {failing = const True}
    forM_ [7, 8] $ \pr -> do
      delivery <- newDelivery
      void (receiveSigned first.host (envelopeAt 31 pr) delivery "pull_request")
    items <- pendingNow first.host
    length items `shouldBe` 2
    Host.process first.host (items !! 0)
    -- A separate PR is still attempted despite the first delivery remaining pending.
    Host.process first.host (items !! 1)
    pendingNow first.host `shouldReturn` []
    Host.close first.host
    second <- harness tmp defaults
    sqlExec (webhooks tmp) "UPDATE inbox SET next_attempt_at=0" []
    pendingNow second.host >>= mapM_ (Host.process second.host)
    pendingNow second.host `shouldReturn` []
    (length <$> made second) `shouldReturn` 2
    Host.close second.host

  it "test_same_subject_delivery_waits_behind_an_earlier_deferred_failure" . withTempRoot $ \tmp -> do
    seen <- newIORef []
    let failFirst app = do
          base <- readIORef app.onProcess
          writeIORef app.onProcess $ \item conversation -> do
            modifyIORef' seen (<> [item.deliveryId])
            count <- length <$> readIORef seen
            when (count == 1) $ throwIO (RuntimeError "first delivery failed")
            base item conversation
    h <- harness tmp defaults {customize = failFirst}
    deliveries <- replicateM 2 newDelivery
    forM_ deliveries $ \identity -> receiveSigned h.host (envelopeAt 31 7) identity "pull_request"
    activateInstance h.host instance7 Nothing Nothing `shouldThrow` runtimeError "first delivery failed"
    -- Even an explicitly supplied later observation must respect the
    -- custodied row-order fence rather than bypassing subject loading.
    firstPending h.host >>= Host.process h.host
    readIORef seen `shouldReturn` take 1 deliveries
    rows <- sqlRows (webhooks tmp) "SELECT delivery_id,attempts FROM inbox WHERE delivery_id IN (?,?) ORDER BY rowid" (map S.SQLText deliveries)
    rows `shouldBe` [[S.SQLText (deliveries !! 0), S.SQLInteger 1], [S.SQLText (deliveries !! 1), S.SQLInteger 0]]
    Custody.pending h.host.custody 100 (Just key7) `shouldReturn` []
    Host.close h.host

  it "test_periodic_sweep_reopens_active_and_inactive_bound_instances" . withTempRoot $ \tmp -> do
    forM_ [(31, 7), (31, 8), (999, 9)] $ \(repository, pr) -> bound tmp repository pr
    h <- harness tmp defaults
    sweep h.host "startup" `shouldReturn` 3
    apps <- made h
    map (.instanceId) apps `shouldBe` ["github:44:31:pr:7", "github:44:31:pr:8", "github:44:999:pr:9"]
    mapM (readIORef . (.reconciles)) apps `shouldReturn` [["startup:44:31:7"], ["startup:44:31:8"], []]
    sweep h.host "periodic" `shouldReturn` 3
    mapM (readIORef . (.reconciles)) apps
      `shouldReturn` [["startup:44:31:7", "periodic:44:31:7"], ["startup:44:31:8", "periodic:44:31:8"], []]

  it "test_startup_sweep_applies_pending_comment_without_duplicate_provider_reconciliation" . withTempRoot $ \tmp -> do
    void (bound tmp 31 7)
    h <- harness tmp defaults
    delivery <- newDelivery
    void (receiveSigned h.host (commentEnvelope "9" "@hamsterdan-test help") delivery "issue_comment")
    sweep h.host "startup" `shouldReturn` 1
    (length <$> made h) `shouldReturn` 1
    app <- app0 h
    readIORef app.reconciles `shouldReturn` ["github-delivery:" <> delivery]
    (length <$> readIORef app.comments) `shouldReturn` 1
    statusOf h.host delivery `shouldReturn` Just "terminal"
    Host.close h.host

  it "test_startup_sweep_finds_instance_comment_beyond_global_pending_batch" . withTempRoot $ \tmp -> do
    void (bound tmp 31 7)
    h <- harness tmp defaults
    unrelated <- replicateM 1000 $ do
      row <- newDelivery
      inner <- newDelivery
      pure (row, observationAt inner 32 8)
    insertPending (webhooks tmp) unrelated
    delivery <- newDelivery
    void (receiveSigned h.host (commentEnvelope "9" "@hamsterdan-test help") delivery "issue_comment")
    sweep h.host "startup" `shouldReturn` 1
    app <- app0 h
    readIORef app.reconciles `shouldReturn` ["github-delivery:" <> delivery]
    (length <$> readIORef app.comments) `shouldReturn` 1
    statusOf h.host delivery `shouldReturn` Just "terminal"
    Host.close h.host

  it "test_sweep_does_not_reconcile_while_addressed_comment_retry_is_deferred" . withTempRoot $ \tmp -> do
    void (bound tmp 31 7)
    h <- harness tmp defaults
    delivery <- newDelivery
    let item = commentOf delivery "@hamsterdan-test help" "human" "MEMBER"
    insertPending (webhooks tmp) [(delivery, item)]
    Custody.retry h.host.custody delivery (ErrorClass "RuntimeError")
    sweep h.host "startup" `shouldReturn` 1
    (length <$> made h) `shouldReturn` 1
    app <- app0 h
    readIORef app.reconciles `shouldReturn` []
    (length <$> readIORef app.comments) `shouldReturn` 0
    statusOf h.host delivery `shouldReturn` Just "pending"
    Host.close h.host

  it "test_sweep_waits_for_actionable_comment_beyond_same_instance_batch" . withTempRoot $ \tmp -> do
    void (bound tmp 31 7)
    h <- harness tmp defaults
    items <- replicateM 1000 $ do
      delivery <- newDelivery
      pure (delivery, commentOf delivery "not addressed" "human" "MEMBER")
    target <- newDelivery
    insertPending (webhooks tmp) (items <> [(target, commentOf target "@hamsterdan-test help" "human" "MEMBER")])
    sweep h.host "startup" `shouldReturn` 1
    app <- app0 h
    readIORef app.reconciles `shouldReturn` []
    statusOf h.host target `shouldReturn` Just "pending"
    sweep h.host "periodic" `shouldReturn` 1
    readIORef app.reconciles `shouldReturn` ["github-delivery:" <> target]
    (length <$> readIORef app.comments) `shouldReturn` 1
    statusOf h.host target `shouldReturn` Just "terminal"
    Host.close h.host

  it "test_scoped_resolver_reconstructs_persisted_application_and_rejects_non_durable_names" . withTempRoot $ \tmp -> do
    void (bound tmp 31 7)
    calls <- newIORef []
    let resolvable app = writeIORef app.onActivity $ \name -> do
          modifyIORef' calls (<> [name])
          pure (Just (gate name [] (\_ _ -> pure (Object [("activity", String name)]))))
    h <- harness tmp defaults {customize = resolvable}
    resolved <- resolveActivity h.host instance7 "dash_gate"
    isJust resolved `shouldBe` True
    (Map.member key7 <$> readIORef h.host.loaded) `shouldReturn` True
    readIORef calls `shouldReturn` ["dash_gate"]
    (isNothing <$> resolveActivity h.host instance7 "review") `shouldReturn` True
    (isJust <$> resolveActivity h.host "not-a-pr-instance" "dash_gate") `shouldReturn` True
    Host.close h.host

  it "test_v5_revoked_route_settles_instance_queue_as_typed_blocked_without_provider_calls" . withTempRoot $ \tmp -> do
    providerCalls <- newIORef []
    let reached :: Text -> IO a
        reached call = modifyIORef' providerCalls (<> [call]) >> assertionError
        definition name implementation = either (error . T.unpack) id (hostGateDefinition name Nothing implementation)
        definitions =
          Map.fromList
            [ ("reply_gate", definition "reply_gate" (gateImplementation @C.ReplyReq (\work -> reached ("reply:" <> work.id))))
            , ("dash_gate", definition "dash_gate" (gateImplementation @C.DashReq (\work -> reached ("dash:" <> work.digest))))
            , ("announce_gate", definition "announce_gate" (gateImplementation @C.AnnounceReq (\work -> reached ("announce:" <> work.op))))
            ]
        works =
          [ ("reply_gate", dump (C.ReplyReq {id = "comment-7", text = "safe reply"}))
          , ("dash_gate", dump (C.DashReq ["one"] "d1" ["one", "two"] "d2" "" [] []))
          , ("announce_gate", dump (C.AnnounceReq "ready:h1:i3" 3 "h1" "b1" "p1" True False))
          ]
        variant name value = case value of
          Object members -> Object (("$variant", String name) : members)
          other -> other
        blocked =
          [ variant "ReplyBlocked" (dump (C.ReplyBlocked {id = "comment-7", text = "safe reply"}))
          , variant "DashBlocked" (dump (C.DashBlocked ["one"] "d1" ["one", "two"] "d2"))
          , variant "ABlocked" (dump (C.ABlocked 3 "h1" "b1" "p1"))
          ]
    h <- harness tmp defaults
    _ <- application h.host 44 31 7
    app <- app0 h
    isJust app.options.durableActivityResolver `shouldBe` True
    let queue = Runtime.durableQueue instance7
        dispatchPath = tmp </> "activity-dispatch.sqlite3"
    sender <-
      Local.openLocalDispatch
        dispatchPath
        instance7
        Local.defaultLocalDispatchOptions {Local.activityQueues = [(name, queue) | name <- Map.keys definitions]}
    forM_ (zip [1 ..] works) $ \(occurrence, (name, work)) ->
      Local.dispatch sender occurrence (invocationOf name (Object [("work", work)]))
    inspector <- Local.openLocalDispatch dispatchPath "unrelated-inspector" Local.defaultLocalDispatchOptions
    unrelated <- Local.worker inspector ["publication"] Nothing
    (isNothing <$> Local.claim unrelated) `shouldReturn` True
    Local.close unrelated
    Local.closeLocalDispatch inspector
    suspend h.host
    session <- Local.openLocalDispatch dispatchPath "v5-worker" Local.defaultLocalDispatchOptions
    provider <- Local.worker session [queue] Nothing
    worker' <-
      newWorker
        (Local.toWorkerDispatch provider)
        (Map.map asActivity definitions)
        defaultWorkerOptions {resolver = Just (\attemptInstance name -> guardDurableActivity h.host attemptInstance name (definitions Map.! name))}
    runAvailable worker' 10 `shouldReturn` 3
    results <- Map.fromList <$> Local.collect sender
    readIORef providerCalls `shouldReturn` []
    forM_ (zip3 [1 ..] works blocked) $ \(occurrence, _, expected) ->
      Map.lookup occurrence results `shouldBe` Just (Succeeded expected)
    closeWorker worker'
    Local.closeLocalDispatch session
    Local.closeLocalDispatch sender
    Host.close h.host

  it "test_v5_shutdown_during_first_attempt_prevents_a_second_instance_queue_claim" . withTempRoot $ \tmp -> do
    started <- newEmptyMVar
    release <- newEmptyMVar
    claims <- newIORef (0 :: Int)
    stopped <- newIORef False
    let stoppable app = do
          writeIORef app.onRunDurable $ \limit -> do
            limit `shouldSatisfy` (>= 2)
            modifyIORef' claims (+ 1)
            void (tryPutMVar started ())
            wait1 release `shouldReturn` True
            halted <- readIORef stopped
            unless halted $ modifyIORef' claims (+ 1)
            readIORef claims
          writeIORef app.onStop (writeIORef stopped True)
    h <- harness tmp defaults {customize = stoppable}
    _ <- application h.host 44 31 7
    done <- newEmptyMVar
    _ <- forkIO (try @SomeException (pump h.host 20) >> putMVar done ())
    wait1 started `shouldReturn` True
    stop h.host
    putMVar release ()
    wait1 done `shouldReturn` True
    readIORef claims `shouldReturn` 1
    Host.close h.host

  it "test_default_composition_opens_the_real_v5_application_and_labeled_history" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults {factory = Just v5ApplicationFactory, reconcileRegistry = False}
    activateRepositories h.host [(31, "owner/one")]
    app <- application h.host 44 31 7
    isJust app.v5 `shouldBe` True
    subjectState h.host 44 31 7 `shouldReturn` Just (Object [("ready", Null), ("snapshot", Null)])
    binding <- readInstanceBinding (tmp </> "applications/44/31/7/binding.json")
    binding.topology `shouldBe` V5
    binding.legacy `shouldBe` False
    doesFileExist (tmp </> "applications/44/31/7/history.jsonl") `shouldReturn` True
    Host.close h.host

  it "test_selected_v5_routes_custodied_webhook_into_identified_history_before_acknowledgement" . withTempRoot $ \tmp -> do
    provider <- newV5Provider
    h <- v5Harness tmp provider v5Runner id
    delivery <- newDelivery
    receipt <- receiveSigned h.host envelope delivery "pull_request"
    receipt.disposition `shouldBe` Accepted
    statusOf h.host delivery `shouldReturn` Just "pending"
    acknowledgedAfter <- newIORef []
    setHooks h.host $ \hooks ->
      hooks
        { aroundAcknowledgeObservation = \_ _ real -> do
            accepted <- loadedV5 h.host
            modifyIORef' acknowledgedAfter (<> [accepted])
            real
        }
    firstPending h.host >>= Host.process h.host
    Just HostApplication {v5 = Just app} <- loadedApplication h.host key7
    current <- currentClaim app
    headSha <- readIORef provider.head
    subjectState h.host 44 31 7
      `shouldReturn` Just
        ( Object
            [ ("ready", Null)
            ,
              ( "snapshot"
              , Object
                  [ ("phase", String "running")
                  , ("incarnation", Int 1)
                  , ("head", String headSha)
                  , ("base_head", String provider.base)
                  , ("policy_digest", String current.policy)
                  ]
              )
            ]
        )
    let expected = ["github-delivery:" <> delivery <> ":" <> door | door <- ["on_head", "on_ready", "on_human"]]
    [accepted] <- readIORef acknowledgedAfter
    take 3 accepted `shouldBe` expected
    any ("v5-timer-command-applied:" `T.isPrefixOf`) accepted `shouldBe` True
    statusOf h.host delivery `shouldReturn` Just "terminal"
    grants tmp "revision,source_kind,source_id" `shouldReturn` [[S.SQLInteger 1, S.SQLText "github-delivery", S.SQLText delivery]]
    Host.close h.host

  it "test_selected_v5_stages_authority_that_arrives_during_normalization_before_review" . withTempRoot $ \tmp -> do
    second <- newDelivery
    let secondBody =
          "{\"action\": \"requested\", \"installation\": {\"id\": 44, \"account\": {\"id\": 23}}, \"repository\": {\"id\": 31, \"full_name\": \"owner/one\"}, \"workflow_run\": {\"pull_requests\": [{\"number\": 7}]}}"
    reviewCalls <- newIORef []
    let counting = v5Runner {review = \url request inv -> modifyIORef' reviewCalls (<> [(inv.operation, inv.attempt)]) >> reviewClear url request inv}
    provider <- newV5Provider
    h <- v5Harness tmp provider counting id
    arrived <- newIORef False
    writeIORef provider.requestHook $ \method path -> do
      already <- readIORef arrived
      when (not already && method == "GET" && path == "/repos/owner/one/pulls/7") $ do
        writeIORef arrived True
        receipt <- receiveSigned h.host secondBody second "workflow_run"
        receipt.disposition `shouldBe` Accepted
    first <- newDelivery
    void (receiveSigned h.host envelope first "pull_request")
    firstPending h.host >>= Host.process h.host
    readIORef reviewCalls `shouldReturn` []
    void (pump h.host 20)
    headSha <- readIORef provider.head
    readIORef reviewCalls `shouldReturn` [("review:github:44:31:pr:7:" <> headSha <> ":i1", 1)]
    statusOf h.host first `shouldReturn` Just "terminal"
    statusOf h.host second `shouldReturn` Just "terminal"
    grants tmp "revision,source_id" `shouldReturn` [[S.SQLInteger 2, S.SQLText second]]
    Host.close h.host

  it "test_selected_v5_restart_replays_settled_webhook_after_death_before_acknowledgement" . withTempRoot $ \tmp -> do
    runnerCalls <- newIORef []
    let counting = v5Runner {review = \url request inv -> modifyIORef' runnerCalls (<> [(inv.operation, inv.attempt)]) >> reviewClear url request inv}
    provider <- newV5Provider
    first <- v5Harness tmp provider counting id
    delivery <- newDelivery
    receipt <- receiveSigned first.host envelope delivery "pull_request"
    receipt.disposition `shouldBe` Accepted
    postures <- newIORef (0 :: Int)
    crash <- newIORef []
    setHooks first.host $ \hooks ->
      hooks
        { aroundRecordPosture = \_ _ real -> real >> modifyIORef' postures (+ 1)
        , aroundAcknowledgeObservation = \item _ _ -> do
            count <- readIORef postures
            status' <- statusOf first.host item.deliveryId
            hints <- Runnable.count first.host.runnable
            modifyIORef' crash (<> [(item.deliveryId, count, status', hints)])
            throwIO SimulatedProcessDeath
        }
    (firstPending first.host >>= Host.process first.host) `shouldThrow` (== SimulatedProcessDeath)
    let history = tmp </> "applications/44/31/7/history.jsonl"
    beforeRestart <- BS.readFile history
    identities <- map fst <$> historyDeliveries history
    let expected = ["github-delivery:" <> delivery <> ":" <> door | door <- ["on_head", "on_ready", "on_human"]]
    readIORef crash `shouldReturn` [(delivery, 1, Just "pending", 1)]
    readIORef runnerCalls `shouldReturn` []
    forM_ expected $ \identity -> length (filter (== identity) identities) `shouldBe` 1
    any ("host-reconcile:" `T.isPrefixOf`) identities `shouldBe` False
    let untouched = [[S.SQLText "pending", S.SQLInteger 0, S.SQLNull, S.SQLNull]]
    inboxRow tmp delivery `shouldReturn` untouched
    grants tmp "revision,source_kind,source_id" `shouldReturn` [[S.SQLInteger 1, S.SQLText "github-delivery", S.SQLText delivery]]
    providerCalls <- readIORef provider.calls
    Host.close first.host
    inboxRow tmp delivery `shouldReturn` untouched
    readIORef runnerCalls `shouldReturn` []
    readIORef provider.calls `shouldReturn` providerCalls
    BS.readFile history `shouldReturn` beforeRestart
    writeIORef provider.head (T.replicate 40 "c")
    second <- v5Harness tmp provider counting id
    sweep second.host "startup" `shouldReturn` 1
    statusOf second.host delivery `shouldReturn` Just "terminal"
    readIORef runnerCalls `shouldReturn` []
    readIORef provider.calls `shouldReturn` providerCalls
    BS.readFile history `shouldReturn` beforeRestart
    Runnable.count second.host.runnable `shouldReturn` 1
    inboxRow tmp delivery `shouldReturn` [[S.SQLText "terminal", S.SQLInteger 0, S.SQLText "processed", S.SQLNull]]
    grants tmp "revision,source_kind,source_id" `shouldReturn` [[S.SQLInteger 1, S.SQLText "github-delivery", S.SQLText delivery]]
    Host.close second.host

  it "test_selected_v5_sweep_reconciliation_reuses_unchanged_identity_and_advances_changed_truth" . withTempRoot $ \tmp -> do
    provider <- newV5Provider
    h <- v5Harness tmp provider v5Runner id
    _ <- application h.host 44 31 7
    let reconciled = fmap (filter ("host-reconcile:" `T.isPrefixOf`)) . loadedV5
    sweep h.host "startup" `shouldReturn` 1
    startup <- reconciled h.host
    length startup `shouldBe` 3
    all (":github:44:31:pr:7:1:" `T.isInfixOf`) startup `shouldBe` True
    sweep h.host "periodic" `shouldReturn` 1
    reconciled h.host `shouldReturn` startup
    writeIORef provider.head (T.replicate 40 "c")
    sweep h.host "periodic" `shouldReturn` 1
    changed <- reconciled h.host
    take 3 changed `shouldBe` startup
    length changed `shouldBe` 6
    all (":github:44:31:pr:7:2:" `T.isInfixOf`) (drop 3 changed) `shouldBe` True
    Host.close h.host
    restarted <- v5Harness tmp provider v5Runner id
    sweep restarted.host "startup" `shouldReturn` 1
    reconciled restarted.host `shouldReturn` changed
    grants tmp "revision,source_kind" `shouldReturn` [[S.SQLInteger 2, S.SQLText "host-reconcile"]]
    Host.close restarted.host

  it "test_selected_v5_restart_rebuilds_timer_after_crash_before_runnable_hint" . withTempRoot $ \tmp -> do
    provider <- newV5Provider
    clockUs <- newIORef (1000000 :: Integer)
    let clocked = withTimers 10 (readIORef clockUs) ((/ 1000000) . fromInteger <$> readIORef clockUs)
        history = tmp </> "applications/44/31/7/history.jsonl"
        timerDeliveries = length . filter ((== "on_timer") . snd) <$> historyDeliveries history
    first <- v5Harness tmp provider v5Runner clocked
    _ <- application first.host 44 31 7
    sweep first.host "startup" `shouldReturn` 1
    Runnable.count first.host.runnable `shouldReturn` 1
    void (pump first.host 20)
    writeIORef clockUs 11000000
    setHooks first.host $ \hooks ->
      hooks
        { aroundRecordPosture = \instanceText maturation _ -> do
            instanceText `shouldBe` instance7
            maturation `shouldBe` Just 21.0
            throwIO SimulatedProcessDeath
        }
    runDue first.host 100 `shouldThrow` (== SimulatedProcessDeath)
    reminders provider `shouldReturn` 1
    timerDeliveries `shouldReturn` 1
    setHooks first.host $ \hooks -> hooks {aroundRecordPosture = \_ _ real -> real}
    Host.close first.host
    let applicationRoot = tmp </> "applications/44/31/7"
    forM_ [applicationRoot </> "timers.sqlite3", tmp </> "runnable.sqlite3"] $ \path -> do
      removeFile path
      forM_ ["-wal", "-shm"] $ \suffix -> do
        exists <- doesFileExist (path <> suffix)
        when exists $ removeFile (path <> suffix)
    second <- v5Harness tmp provider v5Runner clocked
    sweep second.host "startup" `shouldReturn` 1
    Runnable.count second.host.runnable `shouldReturn` 1
    runDue second.host 100 `shouldReturn` 0
    reminders provider `shouldReturn` 1
    writeIORef clockUs 21000000
    runDue second.host 100 `shouldReturn` 1
    reminders provider `shouldReturn` 2
    timerDeliveries `shouldReturn` 2
    Host.close second.host

  it "test_host_skips_post_reconciliation_settlement_when_application_reports_a_custody_fence" . withTempRoot $ \tmp -> do
    let fenced app = writeIORef app.onReconcile (\reason -> modifyIORef' app.reconciles (<> [reason]) >> pure False)
    h <- harness tmp defaults {customize = fenced}
    activateInstance h.host instance7 Nothing (Just "startup") `shouldReturn` True
    app <- app0 h
    readIORef app.reconciles `shouldReturn` ["startup:44:31:7"]
    readIORef app.settlements `shouldReturn` 1
    Host.close h.host

  it "test_host_rechecks_custody_and_route_before_post_reconciliation_settlement" . withTempRoot $ \tmp -> do
    let custodyRace app = writeIORef app.onReconcile $ \reason -> do
          modifyIORef' app.reconciles (<> [reason])
          identity <- newDelivery
          insertPending app.options.custodyPath [(identity, observationOf identity)]
          pure True
    h <- harness tmp defaults {customize = custodyRace}
    activateInstance h.host instance7 Nothing (Just "startup") `shouldReturn` True
    app <- app0 h
    readIORef app.settlements `shouldReturn` 1
    Host.close h.host
    hostRef <- newIORef Nothing
    let routeRace racing = writeIORef racing.onReconcile $ \reason -> do
          modifyIORef' racing.reconciles (<> [reason])
          readIORef hostRef >>= mapM_ suspend
          pure True
    createDirectoryIfMissing True (tmp </> "route")
    routed <- harness (tmp </> "route") defaults {customize = routeRace}
    writeIORef hostRef (Just routed.host)
    activateInstance routed.host instance7 Nothing (Just "startup") `shouldReturn` True
    routedApp <- app0 routed
    readIORef routedApp.settlements `shouldReturn` 1
    Host.close routed.host

  it "test_scoped_resolver_wraps_unexpected_durable_activity_error_as_nonretryable" . withTempRoot $ \tmp -> do
    let broken app = writeIORef app.onActivity $ \name ->
          pure (Just (gate name [] (\_ _ -> throwIO (ValueError "provider detail must not escape"))))
    h <- harness tmp defaults {customize = broken}
    _ <- application h.host 44 31 7
    Just resolved <- resolveActivity h.host instance7 "announce_gate"
    outcome <- try (resolved (invocationOf "announce_gate" (Object [])) dummyContext)
    case outcome of
      Left (failure :: ActivityError) -> do
        let fields = activityFailureOf failure
        fields.failureKind `shouldBe` "ValueError"
        fields.failureRetryable `shouldBe` False
        show failure `shouldNotSatisfy` ("provider detail" `isInfixOfS`)
      Right value -> expectationFailure ("the activity returned " <> show value)
    Host.close h.host

  it "test_durable_activity_resolver_fails_closed_for_malformed_scope_and_request" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    let scopeError :: ActivityError -> Bool
        scopeError failure =
          let fields = activityFailureOf failure
           in fields.failureKind == "PublicationScopeError" && not fields.failureRetryable
    Just malformed <- resolveActivity h.host "not-a-pr-instance" "dash_gate"
    malformed (invocationOf "dash_gate" (Object [])) dummyContext `shouldThrow` scopeError
    (isNothing <$> resolveActivity h.host "not-a-pr-instance" "review") `shouldReturn` True
    _ <- application h.host 44 31 7
    suspend h.host
    Just resolved <- resolveActivity h.host instance7 "dash_gate"
    resolved (invocationOf "dash_gate" (Object [])) dummyContext `shouldThrow` scopeError
    Host.close h.host

  describe "test_startup_preflight_rejects_noninteger_pull_request_binding" $
    forM_ [("True", "true"), ("7.0", "7.0")] $ \(label, spelled) -> it ("[" <> label <> "]") . withTempRoot $ \tmp -> do
      let root = tmp </> "applications/44/31/7"
      createDirectoryIfMissing True root
      BS.writeFile (root </> "binding.json") ("{\"instance_id\": \"github:44:31:pr:7\", \"repository\": \"owner/one\", \"pull_request\": " <> spelled <> "}")
      BS.writeFile (root </> "history.jsonl") ""
      clients <- newFakeClients
      harness tmp defaults {givenClients = Just clients} `shouldThrow` runtimeError "binding is unreadable or malformed"
      readIORef clients.operationCalls `shouldReturn` []

  it "test_run_due_contains_instance_failure_rewakes_and_recovers_scheduler_health" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    let first = instance7
        second = "github:44:32:pr:8"
    attempts <- newIORef Map.empty
    setHooks h.host $ \hooks ->
      hooks
        { activateOverride = Just $ \instanceText _ -> do
            modifyIORef' attempts (Map.insertWith (+) instanceText (1 :: Int))
            count <- (Map.! instanceText) <$> readIORef attempts
            when (instanceText == first && count == 1) $ throwIO (RuntimeError "sensitive scheduler failure")
            pure True
        }
    Runnable.wake h.host.runnable first 0 "petri-timer" "next-maturation"
    Runnable.wake h.host.runnable second 0 "webhook" "delivery"
    runDue h.host 100 `shouldReturn` 1
    readIORef attempts `shouldReturn` Map.fromList [(first, 1), (second, 1)]
    now <- realToFrac <$> getPOSIXTime
    Runnable.takeDueAt h.host.runnable 100 now `shouldReturn` [first]
    report <- health h.host
    member "status" report `shouldBe` String "degraded"
    member "scheduler" report `shouldBe` Object [("degraded_instances", Int 1), ("error_classes", Array [String "RuntimeError"])]
    dumpsSortedText report `shouldNotSatisfy` T.isInfixOf "sensitive scheduler failure"
    Runnable.wake h.host.runnable first 0 "scheduler-repair" "run-due-failure"
    runDue h.host 100 `shouldReturn` 1
    ((Map.! first) <$> readIORef attempts) `shouldReturn` 2
    (member "status" <$> health h.host) `shouldReturn` String "ok"
    Host.close h.host

  it "test_startup_sweep_settles_frozen_terminal_before_provider_reconciliation" . withTempRoot $ \tmp -> do
    void (bound tmp 31 7)
    events <- newIORef []
    let record event = modifyIORef' events (<> [event :: Text])
        frozen app = do
          published <- newIORef False
          writeIORef app.onSettle (record "settle" >> writeIORef published True)
          writeIORef app.onReconcile $ \_ -> do
            done <- readIORef published
            record ("reconcile:" <> if done then "True" else "False")
            unless done $ record "duplicate-publication"
            pure True
    h <- harness tmp defaults {customize = frozen}
    sweep h.host "startup" `shouldReturn` 1
    readIORef events `shouldReturn` ["settle", "reconcile:True", "settle"]
    Host.close h.host

  it "test_sweep_route_deactivation_during_pre_settlement_skips_reconciliation_and_second_settle" . withTempRoot $ \tmp -> do
    void (bound tmp 31 7)
    h <- harness tmp defaults
    _ <- application h.host 44 31 7
    app <- app0 h
    settlements <- newIORef []
    writeIORef app.onSettle (modifyIORef' settlements (<> ["settle" :: Text]) >> suspend h.host)
    sweep h.host "periodic" `shouldReturn` 1
    readIORef settlements `shouldReturn` ["settle"]
    Host.close h.host

  let terminalApplication events app = writeIORef app.onSettle (modifyIORef' events (<> ["settle" :: Text]))

  it "test_activity_terminal_wake_only_settles_once_without_provider_reconciliation" . withTempRoot $ \tmp -> do
    events <- newIORef []
    h <- harness tmp defaults {customize = terminalApplication events}
    _ <- application h.host 44 31 7
    Runnable.wake h.host.runnable instance7 0 "activity-terminal" "dashboard_publish"
    runDue h.host 100 `shouldReturn` 1
    readIORef events `shouldReturn` ["settle"]
    app <- app0 h
    readIORef app.reconciles `shouldReturn` []
    Host.close h.host

  it "test_due_wake_reconstructs_uncached_persisted_instance_and_settles_once" . withTempRoot $ \tmp -> do
    void (bound tmp 31 7)
    events <- newIORef []
    h <- harness tmp defaults {customize = terminalApplication events}
    Runnable.wake h.host.runnable instance7 0 "petri-timer" "next-maturation"
    runDue h.host 100 `shouldReturn` 1
    (Map.member key7 <$> readIORef h.host.loaded) `shouldReturn` True
    readIORef events `shouldReturn` ["settle"]
    Host.close h.host

  it "test_due_wake_reconstructs_inactive_bound_instance_to_settle_terminal" . withTempRoot $ \tmp -> do
    void (bound tmp 31 7)
    events <- newIORef []
    h <- harness tmp defaults {customize = terminalApplication events}
    suspend h.host
    Runnable.wake h.host.runnable instance7 0 "activity-terminal" "dashboard_publish"
    runDue h.host 100 `shouldReturn` 1
    (Map.member key7 <$> readIORef h.host.loaded) `shouldReturn` True
    readIORef events `shouldReturn` ["settle"]
    app <- app0 h
    readIORef app.reconciles `shouldReturn` []
    Host.close h.host

  it "test_startup_sweep_repairs_inactive_bound_instance_without_runnable_hint" . withTempRoot $ \tmp -> do
    void (bound tmp 31 7)
    events <- newIORef []
    h <- harness tmp defaults {customize = terminalApplication events}
    suspend h.host
    Runnable.count h.host.runnable `shouldReturn` 0
    sweep h.host "startup" `shouldReturn` 1
    readIORef events `shouldReturn` ["settle"]
    app <- app0 h
    readIORef app.reconciles `shouldReturn` []
    Host.close h.host

  it "test_close_waits_for_admitted_pump_then_closes_application_and_is_idempotent" . withTempRoot $ \tmp -> do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    closeStarted <- newEmptyMVar
    closeFinished <- newEmptyMVar
    events <- newIORef []
    let closing app = do
          writeIORef app.onRunDurable $ \_ -> do
            void (tryPutMVar entered ())
            wait1 release `shouldReturn` True
            modifyIORef' events (<> ["pump-finished" :: Text])
            pure 0
          writeIORef app.onClose (modifyIORef' events (<> ["application-close"]))
    h <- harness tmp defaults {customize = closing}
    _ <- application h.host 44 31 7
    pumped <- newEmptyMVar
    _ <- forkIO (try @SomeException (pump h.host 20) >> putMVar pumped ())
    wait1 entered `shouldReturn` True
    _ <- forkIO $ do
      putMVar closeStarted ()
      _ <- try @SomeException (Host.close h.host)
      putMVar closeFinished ()
    wait1 closeStarted `shouldReturn` True
    (isJust <$> timeout 50000 (readMVar closeFinished)) `shouldReturn` False
    putMVar release ()
    wait1 pumped `shouldReturn` True
    wait1 closeFinished `shouldReturn` True
    readIORef events `shouldReturn` ["pump-finished", "application-close"]
    Host.close h.host
    (length . filter (== "application-close") <$> readIORef events) `shouldReturn` 1

  it "test_sweep_failure_on_one_pr_does_not_block_another" . withTempRoot $ \tmp -> do
    forM_ [7, 8] (bound tmp 31)
    h <- harness tmp defaults {failing = (== 0)}
    sweep h.host "periodic" `shouldReturn` 1
    apps <- made h
    length apps `shouldBe` 2
    second <- appAt h 1
    readIORef second.reconciles `shouldReturn` ["periodic:44:31:8"]

  it "test_validation_counts_remain_parseable_when_the_launcher_masks_app_identity" . withTempRoot $ \tmp -> do
    clients <- registrationClients [(31, "owner/one"), (32, "owner/two")]
    h <- harness tmp defaults {givenClients = Just clients}
    evidence <- reconcileRegistration h.host
    Host.close h.host
    let masked = foldl (\text identity -> T.replace identity "<concealed by 1Password>" text) (dumpsSortedText evidence) ["17", "hamsterdan-test"]
    Right parsed <- pure (parseJson pythonLoads (TE.encodeUtf8 masked))
    member "reconciled_installations" parsed `shouldBe` Int 1
    member "admitted_repositories" parsed `shouldBe` Int 2

  it "test_restart_applies_one_complete_configuration_and_removes_former_selection" . withTempRoot $ \tmp -> do
    firstClients <- registrationClients [(31, "owner/one"), (32, "owner/two")]
    first <- harness tmp defaults {givenClients = Just firstClients, reconcileRegistry = False}
    (member "admitted_repositories" <$> reconcileRegistration first.host) `shouldReturn` Int 2
    (isJust <$> Routing.route first.host.registry 44 32) `shouldReturn` True
    Host.close first.host
    secondClients <- registrationClients [(31, "owner/one")]
    second <- harness tmp defaults {givenClients = Just secondClients, reconcileRegistry = False, repositories = [(31, "owner/one")]}
    reconcileRegistration second.host
      `shouldReturn` Object
        [ ("app_id", String "17")
        , ("app_slug", String "hamsterdan-test")
        , ("reconciled_installations", Int 1)
        , ("admitted_repositories", Int 1)
        ]
    (isNothing <$> Routing.route second.host.registry 44 32) `shouldReturn` True
    Host.close second.host

  it "test_registration_failure_preserves_the_current_registry_and_host_identity" . withTempRoot $ \tmp -> do
    clients <- registrationClients [(31, "owner/one"), (32, "owner/two")]
    h <- harness tmp defaults {givenClients = Just clients, reconcileRegistry = False}
    void (reconcileRegistration h.host)
    failing' <- newFakeClients
    writeIORef failing'.registration (Just (Left (toException (RuntimeError "selected repository inventory is malformed"))))
    writeIORef h.host.clientsRef (hostClientsOf failing')
    reconcileRegistration h.host `shouldThrow` runtimeError "inventory is malformed"
    readIORef h.host.installationIds `shouldReturn` Set.fromList [44]
    (isJust <$> Routing.route h.host.registry 44 31) `shouldReturn` True
    (isJust <$> Routing.route h.host.registry 44 32) `shouldReturn` True

  it "test_host_service_uses_one_injected_clock_and_transport_factory" . withTempRoot $ \tmp -> do
    provider <- newV5Provider
    let clock = pure 17.0 :: IO Double
        through client =
          Transport
            { request = \method path body -> client.request method path body >> (providerTransport provider).request method path body
            , pages = (providerTransport provider).pages
            }
    h <-
      harness
        tmp
        defaults
          { reconcileRegistry = False
          , transportFactory = Just through
          , configure = withClock clock
          }
    activateRepositories h.host [(31, "owner/one")]
    _ <- application h.host 44 31 7
    Runnable.wake h.host.runnable instance7 17.0 "test" "clock"
    app <- app0 h
    void (app.authority.transport.request "GET" "/repos/owner/one/pulls/7" Nothing)
    readIORef h.clients.operationCalls `shouldReturn` [(44, [31])]
    readIORef h.clients.operationRequests `shouldReturn` [("GET", "/repos/owner/one/pulls/7")]
    readIORef provider.calls `shouldReturn` [("GET", "/repos/owner/one/pulls/7")]
    Runnable.takeDue h.host.runnable 100 `shouldReturn` [instance7]
    case app.options.clock of
      Just injected -> injected `shouldReturn` 17.0
      Nothing -> expectationFailure "the application received no clock"
    Host.close h.host

  it "test_bounded_host_doors_execute_at_most_one_item" . withTempRoot $ \tmp -> do
    limits <- newIORef []
    let activities app = writeIORef app.onRunDurable (\limit -> modifyIORef' limits (<> [limit]) >> pure limit)
    h <- harness tmp defaults {customize = activities}
    _ <- application h.host 44 31 7
    first <- newDelivery
    second <- newDelivery
    void (receiveSigned h.host envelope first "pull_request")
    void (receiveSigned h.host (envelopeAt 32 8) second "pull_request")
    processOne h.host `shouldReturn` Just (CustodyOneResult first "completed")
    statusOf h.host first `shouldReturn` Just "terminal"
    statusOf h.host second `shouldReturn` Just "pending"
    runOneActivity h.host `shouldReturn` 1
    readIORef limits `shouldReturn` [1]
    Host.close h.host

  it "test_bounded_custody_door_reports_disposal_with_an_existing_application" . withTempRoot $ \tmp -> do
    h <- harness tmp defaults
    _ <- application h.host 44 31 7
    delivery <- newDelivery
    void (receiveSigned h.host (commentEnvelope "9" "not addressed to the App") delivery "issue_comment")
    processOne h.host `shouldReturn` Just (CustodyOneResult delivery "disposed")
    statusOf h.host delivery `shouldReturn` Just "terminal"
    Host.close h.host

  it "test_abrupt_drop_releases_resources_without_settling" . withTempRoot $ \tmp -> do
    events <- newIORef []
    let dropping app = do
          writeIORef app.onSettle (modifyIORef' events (<> ["settle" :: Text]))
          writeIORef app.onClose (modifyIORef' events (<> ["close"]))
    h <- harness tmp defaults {customize = dropping}
    _ <- application h.host 44 31 7
    abort h.host
    abort h.host
    readIORef events `shouldReturn` ["close"]
    readIORef h.clients.closed `shouldReturn` 1
  where
    member name = \case
      Object members -> maybe Null id (lookup name members)
      _ -> Null
    isInfixOfS needle haystack = T.isInfixOf needle (T.pack haystack)

