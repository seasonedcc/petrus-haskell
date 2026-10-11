{-# LANGUAGE AllowAmbiguousTypes #-}

-- | The five restart-convergence cases of
-- @tests/unit/readiness/net_v5/test_inline_recovery.py@, rerun here against
-- the real host gates ('reviewAgent', 'publishGate', 'rerunGate',
-- 'reminderGate', 'gitGate') with the reference's provider-ledger doubles.
--
-- Canonical History is the invocation outbox: a fresh Engine redispatches
-- the exact frozen request after a lost terminal, and the provider's
-- operation ledger turns that redispatch into a lookup. hamsterdan-readiness
-- ports the same protocol around its harness gates; these cases close the
-- gap its PARITY.md records.
module InlineRecoverySpec (spec) where

import Control.Exception (Exception, SomeException, fromException, throwIO, try)
import Control.Monad (void, when)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (Typeable)
import Hamsterdan.Agents.Protocol
import Hamsterdan.Contracts.Codec (Contract, dump, renderDecodeError, validate)
import Hamsterdan.Contracts.ReadinessV5 qualified as C
import Hamsterdan.GitHub.Models
  ( ActionsRunSnapshot (..)
  , FindingPublication (..)
  , PublicationResult (..)
  , RerunIssue (..)
  , publication
  )
import Hamsterdan.Host.GitPublish (GitPublishResult (..), GitReconciliation (..))
import Hamsterdan.Host.Python (ValueError (..))
import Hamsterdan.Host.V5.Claim (CurrentClaim (..), Phase (..))
import Hamsterdan.Host.V5.Gates (PublicationProvider (..), publicationGates, publishGate, reminderGate)
import Hamsterdan.Host.V5.Mutation (MutationPublisher (..), V5MutationGate (..), gitGate)
import Hamsterdan.Host.V5.Rerun (RerunBroker (..), V5RerunGate (..), rerunGate)
import Hamsterdan.Host.V5.Review
  ( ReviewAuthority (..)
  , V5ReviewGate (..)
  , closeReviewRequestStore
  , openReviewRequestStore
  , reviewAgent
  , storeCustody
  )
import Hamsterdan.Host.V5.Runtime (GateImplementation, gateImplementation, hostGateDefinition)
import Hamsterdan.Readiness.NetV5.Gating (GateDefinition (..), Variant, variantOf, wireGates)
import Hamsterdan.Readiness.NetV5.Topology (buildNetV5, derived, gates)
import Petrus.Activity
import Petrus.Cel.Impetus (celCompilers)
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.History.Records (ActivityCompleted (..), ActivityRequested (..), Record (..))
import Petrus.Impetus.Instance (ImplementationRef (..))
import Petrus.Impetus.Petrinet (Token (..), deposit, emptyMarking, netPath)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (ActivityOutcome (..), Dispatch (..))
import System.FilePath ((</>))
import Test.Hspec
import TestSupport (withTempRoot)

instanceId :: Text
instanceId = "test:v5-inline-recovery"

headSha, baseSha, newHead :: Text
headSha = T.replicate 40 "a"
baseSha = T.replicate 40 "b"
newHead = T.replicate 40 "c"

claimValue :: CurrentClaim
claimValue = CurrentClaim PhaseRunning 3 headSha baseSha "policy-1"

model :: forall a. (Contract a) => Json -> a
model raw = either (error . T.unpack . renderDecodeError) id (validate @a raw)

obj :: [(Text, Json)] -> Json
obj = Object

reviewMemory :: [(Text, Json)]
reviewMemory =
  [ ("subject", String "github:12:34:pr:7")
  , ("head", String headSha)
  , ("incarnation", Int 3)
  , ("status", String "pending")
  , ("reviewed", Array [])
  , ("provisional", Array [])
  , ("findings", Array [])
  , ("lineage", Array [])
  , ("dismissed", Array [])
  , ("pub", obj [("phase", String "idle")])
  ]

roundOpen :: C.RoundOpen
roundOpen =
  model @C.RoundOpen . obj $
    [ ("operation", String ("review:github:12:34:pr:7:" <> headSha <> ":i3"))
    , ("head", String headSha)
    , ("base", String baseSha)
    , ("policy", String "policy-1")
    , ("incarnation", Int 3)
    , ("prior_findings", Array [])
    , ("prior_lineage", Array [])
    , ("mem", obj reviewMemory)
    ]

publishable :: C.Publishable
publishable =
  model @C.Publishable . obj $
    [ ("head", String headSha)
    , ("base", String baseSha)
    , ("policy", String "policy-1")
    , ("incarnation", Int 3)
    , ("findings", Array [obj [("id", String "f1"), ("note", String "review finding"), ("blocking", Bool True)]])
    , ("effect", String ("findings:" <> headSha <> ":i3"))
    , ("op", String ("findings:" <> headSha <> ":i3"))
    , ("mem", obj [(k, if k == "pub" then obj [("phase", String "pending")] else v) | (k, v) <- reviewMemory])
    ]

rerunReq :: C.RerunReq
rerunReq =
  model @C.RerunReq . obj $
    [ ("fingerprint", String "lineage:fingerprint")
    , ("fp", String "fingerprint")
    , ("op", String "rerun:lineage:fingerprint")
    , ("head", String headSha)
    , ("base", String baseSha)
    , ("policy", String "policy-1")
    , ("incarnation", Int 3)
    , ("run_id", Int 41)
    , ("attempt", Int 2)
    , ("mem", obj [("reruns", obj []), ("repairs", obj []), ("rerun_faults", obj []), ("closing", Null)])
    ]

remReq :: C.RemReq
remReq = model @C.RemReq (obj [("timer_id", String "timer:github:12:34:pr:7:i3:s0")])

mutWork :: C.MutWork
mutWork =
  model @C.MutWork . obj $
    [ ("op", String "change")
    , ("op_key", String ("push:comment:9:" <> headSha <> ":i3"))
    , ("head", String headSha)
    , ("base", String baseSha)
    , ("policy", String "policy-1")
    , ("incarnation", Int 3)
    , ("lineage", String "")
    , ("kind", String "change")
    , ("instruction", String "rename the config key")
    , ("run_id", Int 0)
    , ("attempt", Int 0)
    ]

-- ---------------------------------------------------------------------------
-- Gate definitions

-- | A gate the case never reaches: its definition only completes the
-- topology wiring.
unreached :: forall a. (Contract a, Typeable a) => Text -> GateImplementation
unreached name = gateImplementation @a (\_ -> expectationFailure ("an unreached gate executed: " <> T.unpack name) >> error "unreachable")

-- | The reference harness's fresh-world @publish_gate@ (no prior comment,
-- no blocker): the findings land. A review round that settles reaches it.
worldPublication :: C.Publishable -> IO Variant
worldPublication work =
  pure . variantOf . model @C.ReviewLanded . obj $
    [ ("head", String work.head)
    , ("incarnation", Int work.incarnation)
    , ("findings", Array (map Object work.findings))
    , ("effect", String work.effect)
    , ("mem", Object work.mem)
    ]

-- | @_definitions(activity_name, implementation)@: the reference's
-- @make_activities(fresh_world())@ for every other gate. Only the
-- fresh-world publication is reachable from these cases; the rest fail
-- loudly if a case ever reaches them.
definitionsWith :: Text -> GateImplementation -> Map Text GateDefinition
definitionsWith name implementation =
  Map.fromList
    [ (n, either (error . T.unpack) id (hostGateDefinition n Nothing i))
    | (n, i) <-
        Map.toList . Map.insert name implementation $
          Map.fromList
            [ ("rerun_gate", unreached @C.RerunReq "rerun_gate")
            , ("review_agent", unreached @C.RoundOpen "review_agent")
            , ("publish_gate", gateImplementation worldPublication)
            , ("git_gate", unreached @C.MutWork "git_gate")
            , ("reply_gate", unreached @C.ReplyReq "reply_gate")
            , ("dash_gate", unreached @C.DashReq "dash_gate")
            , ("reminder_gate", unreached @C.RemReq "reminder_gate")
            , ("announce_gate", unreached @C.AnnounceReq "announce_gate")
            ]
    ]

callDefinition :: GateDefinition -> ActivityInvocation -> IO Json
callDefinition definition inv =
  callActivity definition.activity inv executionContext >>= either (throwIO . ValueError) pure
  where
    executionContext =
      ActivityExecutionContext
        { attemptId = "test"
        , epoch = "1"
        , claimant = "test"
        , instance' = Nothing
        , latestDetails = pure Null
        , heartbeat = \_ -> pure Null
        }

-- ---------------------------------------------------------------------------
-- The crash-cut dispatch

-- | Test-only cut that cannot be classified as an Activity terminal.
data SimulatedProcessDeath = SimulatedProcessDeath
  deriving stock (Show)

instance Exception SimulatedProcessDeath

data Mode = Hold | Discard | Complete
  deriving stock (Eq)

data Cut = Cut
  { invocations :: IORef [(Int, ActivityInvocation)]
  , crashes :: IORef Int
  }

-- | @CrashCutDispatch(activities, mode)@.
crashCut :: Map Text GateDefinition -> Mode -> IO (Dispatch, Cut)
crashCut definitions mode = do
  seen <- newIORef []
  completed <- newIORef []
  crashed <- newIORef 0
  let run occurrence inv = do
        modifyIORef' seen (<> [(occurrence, inv)])
        when (mode /= Hold) $ do
          outcome <- try (callDefinition (definitions Map.! inv.activity) inv)
          case outcome of
            Left (err :: SomeException)
              | Just SimulatedProcessDeath <- fromException err -> modifyIORef' crashed (+ 1)
              | otherwise -> throwIO err
            Right result -> when (mode == Complete) $ modifyIORef' completed (<> [(occurrence, Succeeded result)])
  pure
    ( Dispatch {dispatch = run, collect = atomicModifyIORef' completed (\values -> ([], values)), cancel = Nothing}
    , Cut seen crashed
    )

-- ---------------------------------------------------------------------------
-- Opening, draining, restarting

builtNet :: BuiltNet
builtNet = either (error . show) id buildNetV5

-- | @_open(root, definitions, dispatch, create=..., place=..., work=...)@.
open :: FilePath -> Map Text GateDefinition -> Dispatch -> Maybe (Text, Text, Json) -> IO Engine.Engine
open root definitions port seeded = do
  store <- openJsonlHistoryStore (root </> "history.jsonl")
  let initial = case seeded of
        Just (place, color, payload) -> deposit (path place) (Token (Just color) payload) emptyMarking
        Nothing -> emptyMarking
      options =
        Engine.defaultEngineOptions
          { Engine.marking = initial
          , Engine.handlers = either (error . T.unpack) id (wireGates builtNet gates definitions derived)
          , Engine.guards = Map.fromList [(Exact uri, g) | (uri, g) <- Map.toList builtNet.guards]
          , Engine.celCompilers = celCompilers
          , Engine.activities = [d.activity.declaration | d <- Map.elems definitions]
          , Engine.policy = Engine.throughputPolicy
          }
  case seeded of
    Just _ -> Engine.create builtNet.net instanceId store port options
    Nothing -> Engine.load builtNet.net instanceId store port options
  where
    path = either (error . T.unpack) id . netPath

drain :: Engine.Engine -> IO ()
drain engine = go (100 :: Int)
  where
    go 0 = expectationFailure "V5 inline recovery fixture did not quiesce"
    go n = Engine.advance engine >>= \outcome -> when outcome.ready (go (n - 1))

attemptsOnce :: ExecutionPolicy
attemptsOnce = either (error . T.unpack) id (executionPolicy (policyFields defaultExecutionPolicy) {attempts = 1})

-- | @_request(root, definitions, activity_name, place, work)@.
request :: forall a. (Contract a) => FilePath -> Map Text GateDefinition -> Text -> Text -> a -> IO ActivityRequested
request root definitions activityName place work = do
  (port, cut) <- crashCut definitions Hold
  let payload = dump work
      color = Map.findWithDefault (error "unknown activity") activityName requestColors
  engine <- open root definitions port (Just (place, color, payload))
  drain engine
  [requested] <- (\rs -> [r | RActivityRequested r <- rs, r.activity == activityName]) <$> Engine.records engine
  [(occurrence, inv)] <- readIORef cut.invocations
  occurrence `shouldBe` requested.occurrence
  inv
    `shouldBe` ActivityInvocation
      { activity = activityName
      , input = obj [("work", payload)]
      , policy = attemptsOnce
      , correlation = Just requested.correlation
      , idempotency = Just requested.idempotency
      }
  Engine.close engine
  pure requested
  where
    requestColors =
      Map.fromList
        [ ("review_agent", "RoundOpen")
        , ("publish_gate", "Publishable")
        , ("rerun_gate", "RerunReq")
        , ("reminder_gate", "RemReq")
        , ("git_gate", "MutWork")
        ]

-- | @_restart(root, definitions, mode, requested)@.
restart :: FilePath -> Map Text GateDefinition -> Mode -> ActivityRequested -> IO (Engine.Engine, Cut)
restart root definitions mode requested = do
  (port, cut) <- crashCut definitions mode
  engine <- open root definitions port Nothing
  void (Engine.advance engine)
  [(occurrence, inv)] <- readIORef cut.invocations
  occurrence `shouldBe` requested.occurrence
  inv.input `shouldBe` requested.input
  inv.policy `shouldBe` requested.policy
  inv.correlation `shouldBe` Just requested.correlation
  inv.idempotency `shouldBe` Just requested.idempotency
  pure (engine, cut)

-- | @_finish_and_prove_stable(root, definitions, requested)@.
finishAndProveStable :: FilePath -> Map Text GateDefinition -> ActivityRequested -> IO ()
finishAndProveStable root definitions requested = do
  (engine, _) <- restart root definitions Complete requested
  drain engine
  terminalRecords <- Engine.records engine
  length [() | RActivityCompleted c <- terminalRecords, c.occurrence == requested.occurrence] `shouldBe` 1
  Engine.close engine
  (port, cut) <- crashCut definitions Complete
  stable <- open root definitions port Nothing
  void (Engine.advance stable)
  Engine.records stable `shouldReturn` terminalRecords
  readIORef cut.invocations >>= (`shouldSatisfy` null)
  Engine.close stable

-- ---------------------------------------------------------------------------
-- The provider ledgers

-- | @ClaimPort@.
data ClaimPort = ClaimPort {readable :: IORef Bool, reads :: IORef Int}

newClaimPort :: IO ClaimPort
newClaimPort = ClaimPort <$> newIORef True <*> newIORef 0

readClaim :: ClaimPort -> IO CurrentClaim
readClaim port = do
  modifyIORef' port.reads (+ 1)
  ok <- readIORef port.readable
  if ok then pure claimValue else expectationFailure "lookup-first recovery read moved authority" >> error "unreachable"

unreadable :: IORef Bool -> Text -> IO ()
unreadable flag message = do
  ok <- readIORef flag
  when (not ok) $ expectationFailure (T.unpack message)

currentCheck :: Invocation -> IO ()
currentCheck inv = do
  inv.attempt `shouldBe` 1
  maybe (expectationFailure "is_current is required") (`shouldReturn` True) inv.isCurrent

attemptCheck :: Text -> Invocation -> IO ()
attemptCheck url inv = do
  url `shouldBe` "https://example.test/owner/repo.git"
  currentCheck inv

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "test_inline_recovery (host gates)" $ do
  it "test_review_agent_redispatches_one_frozen_global_operation_without_a_second_agent_execution" . withTempRoot $ \tmp -> do
    held <- newIORef (Map.empty :: Map Text (ReviewRequest, ReviewResult))
    calls <- newIORef (0 :: Int)
    executions <- newIORef (0 :: Int)
    authorityReadable <- newIORef True
    authorityReads <- newIORef (0 :: Int)
    let runner =
          AgentRunner
            { review = \url req inv -> do
                attemptCheck url inv
                modifyIORef' calls (+ 1)
                prior <- Map.lookup inv.operation <$> readIORef held
                case prior of
                  Just (priorRequest, result) -> (priorRequest `shouldBe` req) >> pure result
                  Nothing -> do
                    modifyIORef' executions (+ 1)
                    let result = ReviewResult "owner/repo" 7 3 headSha baseSha "clear" [] []
                    modifyIORef' held (Map.insert inv.operation (req, result))
                    pure result
            , converse = \_ _ _ -> expectationFailure "converse" >> error "unreachable"
            , code = \_ _ _ -> expectationFailure "code" >> error "unreachable"
            }
        authority =
          ReviewAuthority
            { comments = do
                modifyIORef' authorityReads (+ 1)
                unreadable authorityReadable "review replay read current provider comments"
                pure []
            , selectRun = \workflow head' -> do
                modifyIORef' authorityReads (+ 1)
                unreadable authorityReadable "review replay read current provider checks"
                (workflow, head') `shouldBe` ("ci.yml", headSha)
                pure Nothing
            }
    claims <- newClaimPort
    let gateOver store =
          V5ReviewGate
            { repository = "owner/repo"
            , pullRequest = 7
            , authority
            , runner
            , publicCloneUrl = "https://example.test/owner/repo.git"
            , workflowPath = "ci.yml"
            , claim = readClaim claims
            , requests = storeCustody store
            , unstagedCustody = pure Nothing
            }
    requests <- openReviewRequestStore (tmp </> "review-requests.sqlite3")
    let definitions = definitionsWith "review_agent" (gateImplementation (reviewAgent (gateOver requests)))
    requested <- request tmp definitions "review_agent" "review.round" roundOpen
    (requested.correlation, requested.idempotency) `shouldBe` (roundOpen.operation, roundOpen.operation)
    (first, _) <- restart tmp definitions Discard requested
    readIORef executions `shouldReturn` 1
    Map.keys <$> readIORef held `shouldReturn` [roundOpen.operation]
    readIORef authorityReads `shouldReturn` 2
    Engine.close first
    closeReviewRequestStore requests

    writeIORef authorityReadable False
    replayRequests <- openReviewRequestStore (tmp </> "review-requests.sqlite3")
    let replayDefinitions = definitionsWith "review_agent" (gateImplementation (reviewAgent (gateOver replayRequests)))
    (second, _) <- restart tmp replayDefinitions Discard requested
    (,) <$> readIORef executions <*> readIORef calls `shouldReturn` (1, 2)
    readIORef authorityReads `shouldReturn` 2
    Engine.close second

    finishAndProveStable tmp replayDefinitions requested
    (,) <$> readIORef executions <*> readIORef calls `shouldReturn` (1, 3)
    closeReviewRequestStore replayRequests

  it "test_findings_publication_reconciles_before_moved_authority_after_two_lost_terminals" . withTempRoot $ \tmp -> do
    claims <- newClaimPort
    held <- newIORef (Map.empty :: Map Text (Text, Text))
    posts <- newIORef (0 :: Int)
    let unexpected = expectationFailure "unexpected publisher call" >> error "unreachable"
        existingInline = PublicationResult "existing" Nothing True True
        provider =
          PublicationProvider
            { find = \_ _ _ _ _ -> unexpected
            , immutable = \_ _ _ _ _ _ _ -> unexpected
            , immutableOperation = \_ _ _ _ _ -> unexpected
            , dashboard = \_ _ _ _ -> unexpected
            , reminderOperation = \_ _ -> unexpected
            , finding = \pub epoch head' _ -> do
                epoch `shouldBe` 3
                prior <- Map.lookup pub.operation <$> readIORef held
                case prior of
                  Just stored -> (stored `shouldBe` (head', pub.text)) >> pure existingInline
                  Nothing -> do
                    modifyIORef' posts (+ 1)
                    modifyIORef' held (Map.insert pub.operation (head', pub.text))
                    pure (PublicationResult "created" Nothing True True)
            , findings = \_ _ _ _ -> unexpected
            , findingFind = \operation head' -> do
                prior <- Map.lookup operation <$> readIORef held
                case prior of
                  Nothing -> pure Nothing
                  Just (storedHead, _) -> (storedHead `shouldBe` head') >> pure (Just existingInline)
            }
        gate = publicationGates provider (readClaim claims) (pure (Nothing, "author"))
        definitions = definitionsWith "publish_gate" (gateImplementation (publishGate gate))
    requested <- request tmp definitions "publish_gate" "review.publishable" publishable
    (requested.correlation, requested.idempotency) `shouldBe` (publishable.op, publishable.op)
    (first, _) <- restart tmp definitions Discard requested
    readIORef posts `shouldReturn` 1
    Map.keys <$> readIORef held `shouldReturn` [publishable.op <> ":f1"]
    Engine.close first
    writeIORef claims.readable False
    (second, _) <- restart tmp definitions Discard requested
    readIORef posts `shouldReturn` 1
    Engine.close second
    finishAndProveStable tmp definitions requested
    readIORef posts `shouldReturn` 1

  it "test_rerun_reconciles_before_claim_and_runs_reads_after_two_lost_terminals" . withTempRoot $ \tmp -> do
    claims <- newClaimPort
    runsReadable <- newIORef True
    heldOperations <- newIORef Set.empty
    posts <- newIORef (0 :: Int)
    let broker =
          RerunBroker
            { held = \runId head' operation -> do
                (runId, head') `shouldBe` (rerunReq.runId, headSha)
                present <- Set.member operation <$> readIORef heldOperations
                pure (if present then Just (publication "existing" Nothing) else Nothing)
            , issue = \run epoch operation -> do
                (run.id, run.head, epoch) `shouldBe` (rerunReq.runId, headSha, 3)
                present <- Set.member operation <$> readIORef heldOperations
                if present
                  then pure (RerunIssue (publication "existing" Nothing) run.id run.attempt)
                  else do
                    modifyIORef' posts (+ 1)
                    modifyIORef' heldOperations (Set.insert operation)
                    pure (RerunIssue (publication "requested" Nothing) run.id run.attempt)
            }
        runs head' = do
          unreadable runsReadable "lookup-first recovery read workflow runs"
          pure [ActionsRunSnapshot rerunReq.runId head' "ci.yml" rerunReq.attempt "completed" (Just "failure") []]
        gate = V5RerunGate {broker, runs, claim = readClaim claims}
        definitions = definitionsWith "rerun_gate" (gateImplementation (rerunGate gate))
    requested <- request tmp definitions "rerun_gate" "esc.rerun_req" rerunReq
    (requested.correlation, requested.idempotency) `shouldBe` (rerunReq.op, rerunReq.op)
    (first, _) <- restart tmp definitions Discard requested
    readIORef posts `shouldReturn` 1
    readIORef heldOperations `shouldReturn` Set.singleton rerunReq.op
    Engine.close first
    writeIORef claims.readable False
    writeIORef runsReadable False
    (second, _) <- restart tmp definitions Discard requested
    readIORef posts `shouldReturn` 1
    Engine.close second
    finishAndProveStable tmp definitions requested
    readIORef posts `shouldReturn` 1

  it "test_reminder_reconciles_before_claim_and_recipient_reads_after_two_lost_terminals" . withTempRoot $ \tmp -> do
    claims <- newClaimPort
    heldOperations <- newIORef Set.empty
    posts <- newIORef (0 :: Int)
    let unexpected = expectationFailure "unexpected publisher call" >> error "unreachable"
        provider =
          PublicationProvider
            { find = \_ _ _ _ _ -> unexpected
            , immutable = \_ _ _ _ _ _ _ -> unexpected
            , immutableOperation = \_ _ _ _ _ -> unexpected
            , dashboard = \_ _ _ _ -> unexpected
            , reminderOperation = \op recipientContext -> do
                present <- Set.member op <$> readIORef heldOperations
                if present
                  then pure (publication "existing" Nothing)
                  else do
                    recipientContext `shouldReturn` (3, headSha, Nothing, "author")
                    modifyIORef' posts (+ 1)
                    modifyIORef' heldOperations (Set.insert op)
                    pure (publication "created" Nothing)
            , finding = \_ _ _ _ -> unexpected
            , findings = \_ _ _ _ -> unexpected
            , findingFind = \_ _ -> unexpected
            }
        gate = publicationGates provider (readClaim claims) (pure (Nothing, "author"))
        definitions = definitionsWith "reminder_gate" (gateImplementation (reminderGate gate))
        operation = "reminder:" <> remReq.timerId
    requested <- request tmp definitions "reminder_gate" "rem.pub_req" remReq
    (requested.correlation, requested.idempotency) `shouldBe` (operation, operation)
    requested.policy `shouldBe` attemptsOnce
    (first, _) <- restart tmp definitions Discard requested
    readIORef posts `shouldReturn` 1
    readIORef heldOperations `shouldReturn` Set.singleton operation
    Engine.close first
    writeIORef claims.readable False
    (second, _) <- restart tmp definitions Discard requested
    readIORef posts `shouldReturn` 1
    Engine.close second
    finishAndProveStable tmp definitions requested
    readIORef posts `shouldReturn` 1

  it "test_mutation_replays_one_agent_result_then_reconciles_one_ref_advance" . withTempRoot $ \tmp -> do
    claims <- newClaimPort
    heldRuns <- newIORef (Map.empty :: Map Text (CodingRequest, CodingResult))
    calls <- newIORef (0 :: Int)
    executions <- newIORef (0 :: Int)
    heldRefs <- newIORef (Map.empty :: Map Text (Text, Text))
    advances <- newIORef (0 :: Int)
    crashBeforePublish <- newIORef False
    let runner =
          AgentRunner
            { review = \_ _ _ -> expectationFailure "review" >> error "unreachable"
            , converse = \_ _ _ -> expectationFailure "converse" >> error "unreachable"
            , code = \url req inv -> do
                attemptCheck url inv
                modifyIORef' calls (+ 1)
                prior <- Map.lookup inv.operation <$> readIORef heldRuns
                case prior of
                  Just (priorRequest, result) -> (priorRequest `shouldBe` req) >> pure result
                  Nothing -> do
                    modifyIORef' executions (+ 1)
                    let result =
                          CodingResult
                            req.kind
                            req.repository
                            req.pullRequest
                            req.epoch
                            req.head
                            req.base
                            req.ref
                            "changed"
                            "not_attempted"
                            "diff --git a/a b/a\n"
                            ["a"]
                            []
                            "Apply requested change"
                    modifyIORef' heldRuns (Map.insert inv.operation (req, result))
                    pure result
            }
        publisher =
          MutationPublisher
            { reconcile = \operation digest expectedHead _ _ -> do
                prior <- Map.lookup operation <$> readIORef heldRefs
                case prior of
                  Nothing -> pure (GitReconciliation "absent" expectedHead "" [])
                  Just (storedDigest, commit) -> do
                    storedDigest `shouldBe` digest
                    pure (GitReconciliation "existing" commit commit [expectedHead])
            , publish = \_ operation digest expectedHead _ _ -> do
                crash <- readIORef crashBeforePublish
                if crash
                  then writeIORef crashBeforePublish False >> throwIO SimulatedProcessDeath
                  else do
                    modifyIORef' advances (+ 1)
                    modifyIORef' heldRefs (Map.insert operation (digest, newHead))
                    expectedHead `shouldBe` headSha
                    pure (GitPublishResult newHead False)
            }
        gate =
          V5MutationGate
            { repository = "owner/repo"
            , pullRequest = 7
            , runner
            , publisher
            , publicCloneUrl = "https://example.test/owner/repo.git"
            , claim = readClaim claims
            }
        definitions = definitionsWith "git_gate" (gateImplementation (gitGate gate))
    requested <- request tmp definitions "git_gate" "mut.work" mutWork
    (requested.correlation, requested.idempotency) `shouldBe` (mutWork.opKey, mutWork.opKey)

    writeIORef crashBeforePublish True
    (first, cut) <- restart tmp definitions Discard requested
    readIORef cut.crashes `shouldReturn` 1
    (,) <$> readIORef executions <*> readIORef advances `shouldReturn` (1, 0)
    Engine.close first

    (second, _) <- restart tmp definitions Discard requested
    (,,) <$> readIORef executions <*> readIORef calls <*> readIORef advances `shouldReturn` (1, 2, 1)
    Engine.close second
    writeIORef claims.readable False

    finishAndProveStable tmp definitions requested
    (,,) <$> readIORef executions <*> readIORef calls <*> readIORef advances `shouldReturn` (1, 2, 1)
    [(agentOperation, (agentRequest, _))] <- Map.toList <$> readIORef heldRuns
    agentOperation `shouldBe` "mutation:owner/repo:pr:7:" <> mutWork.opKey
    agentRequest.head `shouldBe` headSha
