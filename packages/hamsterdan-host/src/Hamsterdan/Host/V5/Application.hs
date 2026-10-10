-- | Provider-normalized, custody-backed application for the V5 topology
-- (@host/v5/application.py@): one non-sharded V5 PR actor family behind
-- the host protocol.
module Hamsterdan.Host.V5.Application
  ( -- * Authority
    ApplicationAuthority (..)
  , gitHubApplicationAuthority

    -- * Options
  , ApplicationOptions (..)
  , applicationOptions

    -- * The application
  , PrReadinessV5Application (..)
  , ApplicationHooks (..)
  , defaultApplicationHooks
  , openApplication
  , applicationRuntime
  , currentClaim
  , processObservation
  , conversationOperation
  , intentArg
  , intentDeclarations
  , allowedIntents
  , reconcile
  , settle
  , applicationActivity
  , inactiveActivityResult
  , hasUnresolvedPublication
  , runDurableActivities
  , stopDurableActivities
  , detachedState
  , closeApplication

    -- * Store access through the test seams
  , unstagedCustodyId
  , stageReconciliation
  , projectReconciliation
  ) where

import Control.Exception (finally, onException, throw, throwIO, try)
import Control.Monad (forM, unless, when)
import Data.Char (ord)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Type.Equality ((:~:) (..))
import Data.Typeable (Typeable, eqT)
import Hamsterdan.Agents.Protocol
  ( AgentProtocolError
  , AgentRunner (..)
  , ConversationRequest (..)
  , ConversationResult (..)
  , Invocation (..)
  , protocolError
  )
import Hamsterdan.Contracts.Codec (Object)
import Hamsterdan.Contracts.Readiness (AdmittedConversation (..))
import Hamsterdan.Contracts.ReadinessV5
  ( ABlocked (..)
  , ADeferred (..)
  , AWake (..)
  , AnnounceReq (..)
  , CommentSeen (..)
  , DashBlocked (..)
  , DashReq (..)
  , ReplyBlocked (..)
  , ReplyReq (..)
  , RoundWake (..)
  , TimerCommandApplied (..)
  , TimerDue (..)
  , ReminderTimer (..)
  )
import Hamsterdan.GitHub.Effects (CommentPublisher, EffectFault, commentPublisher, sleepSeconds)
import Hamsterdan.GitHub.Effects qualified as Effects
import Hamsterdan.GitHub.Gateway (GitHubAuthority)
import Hamsterdan.GitHub.Gateway qualified as Gateway
import Hamsterdan.GitHub.Models
  ( HumanReviewSnapshot (..)
  , PullRequestSnapshot (..)
  , RepositoryPolicy (..)
  , Transport
  , boundary
  )
import Hamsterdan.GitHub.Webhooks (Observation (..))
import Hamsterdan.Host.Binding (ensureInstanceBinding)
import Hamsterdan.Host.Errors (UnstagedCustodyError (..))
import Hamsterdan.Host.GitPublish (PublicationAuthority, hostGitPublisher, publicationAuthority)
import Hamsterdan.Host.Python (RuntimeError (..), ValueError (..), raiseFailureText)
import Hamsterdan.Host.V5.Claim (CurrentClaim (..))
import Hamsterdan.Host.V5.Gates (V5PublicationGates (..), announceGate, dashGate, publicationProvider, publishGate, reminderGate, replyGate)
import Hamsterdan.Host.V5.Ingress
  ( IngressAuthority (..)
  , IngressEntry (..)
  , IngressManifest (..)
  , ProjectedEntry
  , V5IngressNormalizer (..)
  , V5IngressStore
  , gitHubIngressAuthority
  , ingressFrom
  , openIngressStore
  )
import Hamsterdan.Host.V5.Ingress qualified as Ingress
import Hamsterdan.Host.V5.Mutation (MutationPublisher, V5MutationGate (..), gitGate, mutationPublisher)
import Hamsterdan.Host.V5.Rerun (RerunBroker, V5RerunGate (..), rerunBroker, rerunGate)
import Hamsterdan.Host.V5.Review
  ( ReviewAuthority
  , V5ReviewGate (..)
  , V5ReviewRequestStore
  , closeReviewRequestStore
  , gitHubReviewAuthority
  , openReviewRequestStore
  , reviewAgent
  , storeCustody
  )
import Hamsterdan.Host.V5.Runtime
  ( DurableActivityResolver
  , RuntimeOptions (..)
  , V5Runtime
  , defaultRuntimeOptions
  , gateImplementation
  , hostGateDefinition
  , openRuntime
  )
import Hamsterdan.Host.V5.Runtime qualified as Runtime
import Hamsterdan.Host.V5.Timers (TimerMaturity (..), V5TimerStore)
import Hamsterdan.Host.V5.Timers qualified as Timers
import Hamsterdan.Readiness.NetV5.Gating (Annotation (..), GateDefinition (..), Variant (..), decodeDataclass, encodeVariant, variantOf)
import Hamsterdan.Readiness.NetV5.Py (pyRepr)
import Petrus.Activity (ActivityDefinition (..), ActivityInvocation (..), declarationName)
import Petrus.Activity.Number (Number (..))
import Petrus.Engine qualified as Engine
import Petrus.Json (Json (..))
import System.FilePath ((</>))

-- ---------------------------------------------------------------------------
-- Authority

-- | The @GitHubAuthority@ surface the application reads: the provider
-- reads, the comment transport, the review context, the rerun broker,
-- stale-thread resolution, and the Git object writes.
data ApplicationAuthority = ApplicationAuthority
  { repository :: Text
  , prNumber :: Integer
  , transport :: Transport
  , ingress :: IngressAuthority
  , review :: ReviewAuthority
  , rerunBroker :: CommentPublisher -> RerunBroker
  -- ^ @CommentRerunBroker(authority, publisher)@.
  , resolveStaleFindingThreads :: Maybe (Text -> IO Int)
  -- ^ @getattr(authority, "resolve_stale_finding_threads", None)@.
  , publication :: PublicationAuthority
  -- ^ What @HostGitPublisher(authority, public_clone_url)@ binds.
  }

-- | The production authority over the GitHub gateway.
gitHubApplicationAuthority :: GitHubAuthority -> ApplicationAuthority
gitHubApplicationAuthority authority =
  ApplicationAuthority
    { repository = authority.repository
    , prNumber = authority.prNumber
    , transport = authority.transport
    , ingress = gitHubIngressAuthority authority
    , review = gitHubReviewAuthority authority
    , rerunBroker = \publisher -> rerunBroker (Effects.CommentRerunBroker authority publisher)
    , resolveStaleFindingThreads = Just (Gateway.resolveStaleFindingThreads authority)
    , publication = publicationAuthority authority
    }

-- ---------------------------------------------------------------------------
-- Options

-- | The constructor's keyword arguments.
data ApplicationOptions = ApplicationOptions
  { agentSettle :: Set Text -> IO ()
  , botLogin :: Text
  , publicCloneUrl :: Text
  , custodyPath :: FilePath
  , workflowPath :: Text
  , reminderDelay :: Double
  , publicationFault :: Maybe EffectFault
  , dispatchPath :: Maybe FilePath
  , timerClockUs :: Maybe (IO Integer)
  , durableActivityResolver :: Maybe DurableActivityResolver
  , clock :: Maybe (IO Double)
  , mutationPublisher :: Maybe MutationPublisher
  , retryDelay :: Double -> IO ()
  -- ^ The comment publisher's transient-retry pause (@time.sleep@).
  }

-- | The required keyword arguments, with the reference's defaults.
applicationOptions :: (Set Text -> IO ()) -> Text -> Text -> FilePath -> ApplicationOptions
applicationOptions agentSettle botLogin publicCloneUrl custodyPath =
  ApplicationOptions
    { agentSettle
    , botLogin
    , publicCloneUrl
    , custodyPath
    , workflowPath = ".github/workflows/ci.yml"
    , reminderDelay = 3 * 24 * 60 * 60
    , publicationFault = Nothing
    , dispatchPath = Nothing
    , timerClockUs = Nothing
    , durableActivityResolver = Nothing
    , clock = Nothing
    , mutationPublisher = Nothing
    , retryDelay = sleepSeconds
    }

-- ---------------------------------------------------------------------------
-- The application

-- | Test seams for the reference tests' instance patches of the ingress
-- store and normalizer.
data ApplicationHooks = ApplicationHooks
  { aroundStageReconciliation :: Text -> [ProjectedEntry] -> IO (Maybe IngressManifest) -> IO (Maybe IngressManifest)
  , aroundUnstagedCustodyId :: Text -> IO (Maybe Text) -> IO (Maybe Text)
  , aroundProjectReconciliation :: IO [ProjectedEntry] -> IO [ProjectedEntry]
  }

defaultApplicationHooks :: ApplicationHooks
defaultApplicationHooks =
  ApplicationHooks
    { aroundStageReconciliation = \_ _ real -> real
    , aroundUnstagedCustodyId = \_ real -> real
    , aroundProjectReconciliation = id
    }

data PrReadinessV5Application = PrReadinessV5Application
  { root :: FilePath
  , instanceId :: Text
  , authority :: ApplicationAuthority
  , runner :: AgentRunner
  , publicCloneUrl :: Text
  , workflowPath :: Text
  , agentSettle :: Set Text -> IO ()
  , ingress :: V5IngressStore
  , reviewRequests :: V5ReviewRequestStore
  , normalizer :: V5IngressNormalizer
  , runtimeRef :: IORef (Maybe V5Runtime)
  , timers :: ~V5TimerStore
  -- ^ Lazy: the gates are bound before the store opens, and never read it.
  , hooks :: IORef ApplicationHooks
  }

mutations :: [Text]
mutations = ["change", "update_base", "resolve_conflict"]

-- | @_ALLOWED@.
allowedIntents :: [Text]
allowedIntents =
  ["reply", "status", "acknowledge", "dismiss", "defer", "snooze", "resume", "reassign", "recover_publication"] <> mutations

unfencedPrefixes :: [Text]
unfencedPrefixes = ["reply:", "reminder:", "dash:"]

publicationHeartbeatSeconds :: Integer
publicationHeartbeatSeconds = 360

-- | @_RECOVERY_OPERATION.fullmatch(operation)@: @[!-~]{1,256}@.
recoveryOperation :: Text -> Bool
recoveryOperation operation =
  not (T.null operation) && T.length operation <= 256 && T.all (\c -> ord c >= 0x21 && ord c <= 0x7e) operation

-- | Python's @str(value)@ of a JSON value.
pyStr :: Json -> Text
pyStr = \case
  String t -> t
  other -> pyRepr other

-- | @PrReadinessV5Application(root, instance_id, authority, runner, ...)@.
--
-- Unlike the reference, a construction failure closes the stores this
-- call had already opened.
openApplication :: FilePath -> Text -> ApplicationAuthority -> AgentRunner -> ApplicationOptions -> IO PrReadinessV5Application
openApplication root instanceId authority runner options = do
  let delay = options.reminderDelay
  when
    ( isNaN delay
        || isInfinite delay
        || delay < 1
        || delay > 2147483647
        || fromInteger (truncate delay) /= delay
    )
    $ throwIO (ValueError "V5 reminder delay must be a positive bounded whole second count")
  let reminderDelayS = truncate delay :: Integer
  _ <-
    ensureInstanceBinding root instanceId authority.repository authority.prNumber
      `catchRuntime` \message -> throwIO (RuntimeError ("V5 " <> message))
  ingress <- openIngressStore options.custodyPath
  ( do
      reviewRequests <- openReviewRequestStore (root </> "review-requests.sqlite3")
      (openRest ingress reviewRequests reminderDelayS)
        `onException` closeReviewRequestStore reviewRequests
    )
    `onException` Ingress.close ingress
  where
    catchRuntime action handler =
      try action >>= \case
        Right value -> pure value
        Left (RuntimeError message) -> handler message
    openRest ingress reviewRequests reminderDelayS = do
      runtimeRef <- newIORef Nothing
      hooks <- newIORef defaultApplicationHooks
      let normalizer = V5IngressNormalizer {authority = authority.ingress, workflowPath = options.workflowPath}
          app timers =
            PrReadinessV5Application
              { root
              , instanceId
              , authority
              , runner
              , publicCloneUrl = options.publicCloneUrl
              , workflowPath = options.workflowPath
              , agentSettle = options.agentSettle
              , ingress
              , reviewRequests
              , normalizer
              , runtimeRef
              , timers
              , hooks
              }
          -- The gates see the application before its timer store exists;
          -- they never touch the timers.
          early = app (throw (RuntimeError "V5 timer store is not open"))
      publisher <-
        either throwIO pure $
          commentPublisher
            authority.transport
            authority.repository
            authority.prNumber
            options.botLogin
            (publisherFence early)
            options.publicationFault
            options.retryDelay
      let provider = publicationProvider publisher
          publications claim =
            V5PublicationGates
              { publisher = provider
              , claim
              , recipients = recipients early
              , dashboardPhase = (.phase) <$> Ingress.claim ingress instanceId
              , resolveStaleThreads = authority.resolveStaleFindingThreads
              }
          fresh = publications (currentClaim early)
          -- Replies retain their admitted context while a repair's new head
          -- awaits intake.
          replies = publications (Ingress.claim ingress instanceId)
          rerun =
            V5RerunGate
              { broker = authority.rerunBroker publisher
              , runs = authority.ingress.workflowRuns options.workflowPath
              , claim = currentClaim early
              }
          review =
            V5ReviewGate
              { repository = authority.repository
              , pullRequest = authority.prNumber
              , authority = authority.review
              , runner
              , publicCloneUrl = options.publicCloneUrl
              , workflowPath = options.workflowPath
              , claim = currentClaim early
              , requests = storeCustody reviewRequests
              , unstagedCustody = unstagedCustodyId early
              }
      gitPublisher <- case options.mutationPublisher of
        Just given -> pure given
        Nothing -> mutationPublisher <$> hostGitPublisher authority.publication options.publicCloneUrl
      let mutation =
            V5MutationGate
              { repository = authority.repository
              , pullRequest = authority.prNumber
              , runner
              , publisher = gitPublisher
              , publicCloneUrl = options.publicCloneUrl
              , claim = currentClaim early
              }
          implementations =
            [ ("rerun_gate", gateImplementation (rerunGate rerun))
            , ("review_agent", gateImplementation (reviewAgent review))
            , ("publish_gate", gateImplementation (publishGate fresh))
            , ("git_gate", gateImplementation (gitGate mutation))
            , ("reply_gate", gateImplementation (replyGate replies))
            , ("dash_gate", gateImplementation (dashGate fresh))
            , ("reminder_gate", gateImplementation (reminderGate fresh))
            , ("announce_gate", gateImplementation (announceGate fresh))
            ]
      definitions <- forM implementations $ \(name, implementation) -> do
        let heartbeat = if name == "publish_gate" then Just publicationHeartbeatSeconds else Nothing
        definition <- either (throwIO . ValueError) pure (hostGateDefinition name heartbeat implementation)
        pure (name, definition)
      let operationPrefix = "mutation:" <> authority.repository <> ":pr:" <> T.pack (show authority.prNumber) <> ":"
      runtime <-
        openRuntime
          root
          instanceId
          (Map.fromList definitions)
          defaultRuntimeOptions
            { dispatchPath = options.dispatchPath
            , agentSettle = Just options.agentSettle
            , mutationOperation = Just (operationPrefix <>)
            , reminderDelayS = reminderDelayS
            , durableActivityResolver = options.durableActivityResolver
            }
      writeIORef runtimeRef (Just runtime)
      timers <-
        ( do
            history <- Runtime.runtimeTimerHistory runtime
            outstanding <- Runtime.timerCommand runtime
            let selectedClock = case (options.timerClockUs, options.clock) of
                  (Just clockUs, _) -> Just clockUs
                  (Nothing, Just seconds) -> Just ((\s -> truncate (s * 1000000)) <$> seconds)
                  (Nothing, Nothing) -> Nothing
                timersPath = root </> "timers.sqlite3"
            case selectedClock of
              Nothing -> Timers.openTimerStore timersPath instanceId history outstanding
              Just clockUs -> Timers.openTimerStoreWith timersPath instanceId history outstanding clockUs
          )
          `onException` Runtime.closeRuntime runtime
      pure (app timers)

-- | @_runtime()@.
applicationRuntime :: PrReadinessV5Application -> IO V5Runtime
applicationRuntime app =
  readIORef app.runtimeRef >>= maybe (throwIO (RuntimeError "V5 runtime is not bound")) pure

-- | @ingress.unstaged_custody_id(instance_id)@, through the test seam.
unstagedCustodyId :: PrReadinessV5Application -> IO (Maybe Text)
unstagedCustodyId app = do
  h <- readIORef app.hooks
  h.aroundUnstagedCustodyId app.instanceId (Ingress.unstagedCustodyId app.ingress app.instanceId)

-- | @ingress.stage_reconciliation(instance_id, projected)@, through the
-- test seam.
stageReconciliation :: PrReadinessV5Application -> [ProjectedEntry] -> IO (Maybe IngressManifest)
stageReconciliation app projected = do
  h <- readIORef app.hooks
  h.aroundStageReconciliation app.instanceId projected (Ingress.stageReconciliation app.ingress app.instanceId projected)

-- | @normalizer.project_reconciliation()@, through the test seam.
projectReconciliation :: PrReadinessV5Application -> IO [ProjectedEntry]
projectReconciliation app = do
  h <- readIORef app.hooks
  h.aroundProjectReconciliation (Ingress.projectReconciliation app.normalizer)

phaseOf :: PullRequestSnapshot -> Text
phaseOf pull
  | pull.closed || pull.merged = "terminal"
  | pull.draft = "quiescent"
  | otherwise = "running"

-- | @current_claim()@.
currentClaim :: PrReadinessV5Application -> IO CurrentClaim
currentClaim app = do
  let fence = unstagedCustodyId app >>= maybe (pure ()) (throwIO . UnstagedCustodyError)
  fence
  grant <- Ingress.claim app.ingress app.instanceId
  pull <- app.authority.ingress.pullRequest
  policy <- app.authority.ingress.policy pull.baseRef
  fence
  when ((phaseOf pull, pull.head, pull.base, policy.digest) /= (grant.phase, grant.head, grant.base, grant.policy)) $
    throwIO (boundary "fresh provider authority is not staged in the V5 host grant")
  pure (CurrentClaim grant.phase grant.incarnation pull.head pull.base policy.digest)

-- | @_publisher_fence(repository, pr, incarnation, head, operation)@.
publisherFence :: PrReadinessV5Application -> Text -> Integer -> Integer -> Text -> Text -> IO ()
publisherFence app repository pr incarnation head' operation = do
  when (repository /= app.authority.repository || pr /= app.authority.prNumber) $
    throwIO (RuntimeError "V5 publication escaped its configured PR")
  unless (any (`T.isPrefixOf` operation) unfencedPrefixes) $ do
    runtime <- applicationRuntime app
    Runtime.activeClaim runtime operation >>= \case
      Just expected | (incarnation, head') == (expected.incarnation, expected.head) -> do
        current <- currentClaim app
        when (current /= expected) $
          throwIO (RuntimeError "V5 publication authority moved before the provider effect")
      _ -> throwIO (RuntimeError "V5 publication has no active full authority claim")

-- | @_recipients()@.
recipients :: PrReadinessV5Application -> IO (Maybe Text, Text)
recipients app = do
  pull <- app.authority.ingress.pullRequest
  review <- app.authority.ingress.humanReview
  pure
    ( case review.requestedReviewers of
        first : _ -> Just first
        [] -> Nothing
    , pull.author
    )

-- | @process_observation(observation, conversation=...)@.
processObservation :: PrReadinessV5Application -> Observation -> Maybe AdmittedConversation -> IO ()
processObservation app observation conversation = do
  routeOperation <- forM conversation $ \admitted -> do
    when (admitted.deliveryId /= observation.deliveryId) $
      throwIO (ValueError "conversation differs from its custodied delivery")
    pure (conversationOperation app admitted.deliveryId)
  frozen <- Ingress.manifest app.ingress observation.deliveryId app.instanceId
  manifest <- case frozen of
    Just manifest -> pure manifest
    Nothing -> do
      let action = case observation.action of
            String t -> Just t
            _ -> Nothing
      entries <- Ingress.project app.normalizer observation.deliveryId (Just observation.event) action Nothing
      staged <- case conversation of
        Nothing -> pure entries
        Just admitted -> do
          target <- Ingress.preview app.ingress app.instanceId entries
          classified <- classify app admitted target
          pure (entries <> [ingressFrom "on_comment" classified ("github-delivery:" <> observation.deliveryId <> ":on_comment")])
      Ingress.stage app.ingress observation.deliveryId app.instanceId staged
  -- The immutable manifest now owns the classifier result. Settlement is
  -- idempotently replayed after a crash in the narrow
  -- manifest-commit/route-settle window.
  mapM_ (app.agentSettle . Set.singleton) routeOperation
  runtime <- applicationRuntime app
  deliverManifest runtime manifest.entries

-- | @_deliver_manifest(runtime, entries)@: the host grant's canonical door
-- order in the actor loop.
deliverManifest :: V5Runtime -> [IngressEntry] -> IO ()
deliverManifest runtime entries =
  mapM_ (\entry -> Runtime.deliver runtime entry >> Runtime.foldIngress runtime entry) entries

asObject :: Json -> IO Object
asObject = \case
  Object members -> pure members
  _ -> throwIO (ValueError "V5 conversation context is malformed")

-- | @_classify(conversation, claim)@.
classify :: PrReadinessV5Application -> AdmittedConversation -> CurrentClaim -> IO CommentSeen
classify app conversation claim = do
  let operation = conversationOperation app conversation.deliveryId
      commentId = T.pack (show conversation.commentId)
  runtime <- applicationRuntime app
  (gates, findings) <- Runtime.conversationContext runtime
  gateObjects <- mapM asObject gates
  findingObjects <- mapM asObject findings
  let request =
        ConversationRequest
          { repository = app.authority.repository
          , pullRequest = app.authority.prNumber
          , epoch = claim.incarnation
          , head = claim.head
          , base = claim.base
          , commentContext =
              [ ("id", Int conversation.commentId)
              , ("body", String conversation.text)
              , ("author_association", String conversation.association)
              ]
          , actor = [("id", Int conversation.actorId), ("login", String conversation.actorLogin)]
          , dashboard = [("phase", String claim.phase), ("head", String claim.head)]
          , gates = gateObjects
          , findings = findingObjects
          , allowedIntents = intentDeclarations
          }
  outcome <- try $ do
    -- Classification precedes the atomic manifest/grant stage. Fence
    -- against fresh provider truth here; the host incarnation becomes
    -- authoritative at stage.
    result <-
      app.runner.converse
        app.publicCloneUrl
        request
        Invocation {operation, attempt = 1, isCurrent = Just (providerMatches app claim)}
    raw <- case result.intents of
      [single] -> pure single
      _ -> throwIO (protocolError "conversation must select exactly one intent")
    case (lookup "type" raw, fromMaybe (Object []) (lookup "arguments" raw)) of
      (Just (String kind), Object arguments) | kind `elem` allowedIntents -> do
        arg <- intentArg kind arguments conversation.text
        pure CommentSeen {id = commentId, kind, arg, authorized = True}
      _ -> throwIO (protocolError "conversation selected an invalid intent")
  pure $ case outcome of
    Right value -> value
    Left (_ :: AgentProtocolError) -> CommentSeen {id = commentId, kind = "", arg = "", authorized = False}

-- | @_conversation_operation(delivery_id)@.
conversationOperation :: PrReadinessV5Application -> Text -> Text
conversationOperation app deliveryId =
  "conversation:" <> app.authority.repository <> ":pr:" <> T.pack (show app.authority.prNumber) <> ":delivery:" <> deliveryId

-- | @_provider_matches(expected)@.
providerMatches :: PrReadinessV5Application -> CurrentClaim -> IO Bool
providerMatches app expected = do
  pull <- app.authority.ingress.pullRequest
  policy <- app.authority.ingress.policy pull.baseRef
  pure ((phaseOf pull, pull.head, pull.base, policy.digest) == (expected.phase, expected.head, expected.base, expected.policy))

-- | @_intent_arg(kind, arguments, comment)@.
intentArg :: Text -> Object -> Text -> IO Text
intentArg kind arguments comment
  | kind `elem` ["reply", "status"] = pure (pyStr (fromMaybe (String "") (lookup "message" arguments)))
  | kind `elem` mutations = pure (pyStr (fromMaybe (String "") (lookup "request" arguments)))
  | kind `elem` ["dismiss", "acknowledge", "defer"]
  , Just (Array (first : _)) <- lookup "findings" arguments =
      pure (pyStr first)
  | kind == "recover_publication" = case arguments of
      [("operation", String operation)]
        | recoveryOperation operation && operation `T.isInfixOf` comment -> pure operation
      _ -> throwIO (protocolError "publication recovery operation was not explicitly named")
  | kind == "reassign" = pure (pyStr (fromMaybe (String "") (lookup "assignee" arguments)))
  | otherwise = pure ""

-- | @_intent_declarations()@.
intentDeclarations :: [Object]
intentDeclarations =
  [ [ ("type", String name)
    , ("mutation", Bool (name `elem` mutations))
    , ("arguments", Array (map String (arguments name)))
    , ("requires_explicit", Bool (name `elem` mutations || name == "recover_publication"))
    ]
  | name <- allowedIntents
  ]
  where
    arguments = \case
      "reply" -> ["message"]
      "status" -> ["message"]
      "acknowledge" -> ["findings"]
      "dismiss" -> ["findings"]
      "defer" -> ["findings"]
      "reassign" -> ["assignee"]
      "recover_publication" -> ["operation"]
      "change" -> ["request"]
      "update_base" -> ["request"]
      "resolve_conflict" -> ["request"]
      _ -> []

-- | @reconcile(reason)@: wake metadata never enters reconciliation
-- identity.
reconcile :: PrReadinessV5Application -> Text -> IO Bool
reconcile app _reason = do
  runtime <- applicationRuntime app
  let pending = Ingress.hasPendingCustody app.ingress app.instanceId
  frozen <- Ingress.latestReconciliation app.ingress app.instanceId
  early <- case frozen of
    Nothing -> pure Nothing
    Just manifest -> do
      accepted <- Runtime.manifestAccepted runtime manifest.entries
      blocked <- pending
      if blocked
        then pure (Just False)
        else do
          deliverManifest runtime manifest.entries
          pure (if accepted then Nothing else Just True)
  case early of
    Just answer -> pure answer
    Nothing -> do
      blocked <- pending
      if blocked
        then pure False
        else do
          projected <- projectReconciliation app
          staged <- stageReconciliation app projected
          case staged of
            Nothing -> pure False
            Just manifest -> do
              blockedAfter <- pending
              if blockedAfter
                then pure False
                else do
                  _ <- Runtime.manifestAccepted runtime manifest.entries
                  deliverManifest runtime manifest.entries
                  pure True

-- | @settle()@: drain, wake, and apply the timer outbox to a fixed point,
-- reporting the store's canonical next deadline.
settle :: PrReadinessV5Application -> IO Engine.DriveOutcome
settle app = do
  runtime <- applicationRuntime app
  let timers = app.timers
      go :: Int -> IO Engine.DriveOutcome
      go 0 = throwIO (RuntimeError "V5 timer settlement did not reach an external wait")
      go n = do
        outcome <- Runtime.drain runtime 500
        woke <- wakeDeferred app runtime
        if woke
          then go (n - 1)
          else
            Timers.pendingAck timers >>= \case
              Just ack -> do
                _ <- Runtime.deliverTimerAck runtime ack (Timers.ackIdentity ack.operation)
                Timers.markAckDelivered timers ack.operation
                go (n - 1)
              Nothing ->
                Runtime.timerCommand runtime >>= \case
                  Just command -> Timers.apply timers command >> go (n - 1)
                  Nothing ->
                    Timers.pendingMaturity timers >>= \case
                      Just maturity -> mature maturity >> go (n - 1)
                      Nothing ->
                        Timers.claimDue timers >>= \case
                          Just maturity -> mature maturity >> go (n - 1)
                          Nothing -> do
                            due <- Timers.nextDue timers
                            pure (Engine.DriveOutcome outcome.firings outcome.waiting outcome.ready (FloatNumber <$> due))
      mature (maturity :: TimerMaturity) = do
        _ <- Runtime.deliverTimerDue runtime maturity.value maturity.identity
        Timers.markMaturityDelivered timers maturity.value.timer.id
  go 500

-- | @_wake_deferred(runtime)@.
wakeDeferred :: PrReadinessV5Application -> V5Runtime -> IO Bool
wakeDeferred app runtime = do
  review <-
    Runtime.reviewDeferred runtime >>= \case
      Nothing -> pure False
      Just deferred -> do
        blocker <- unstagedCustodyId app
        if isNothing blocker
          then do
            let wake =
                  RoundWake
                    { operation = Runtime.deferredOperation deferred
                    , attempt = Runtime.deferredAttempt deferred
                    , blocker = Runtime.deferredBlocker deferred
                    }
            _ <- Runtime.deliverReviewWake runtime wake (Runtime.reviewWakeIdentity wake)
            pure True
          else pure False
  announce <-
    Runtime.announceDeferred runtime >>= \case
      Nothing -> pure False
      Just deferred -> do
        cleared <- barrierCleared app runtime deferred.blocker
        if cleared
          then do
            let wake =
                  AWake
                    deferred.op
                    deferred.incarnation
                    deferred.head
                    deferred.base
                    deferred.policy
                    deferred.strictBase
                    deferred.baseCurrent
                    deferred.blocker
            _ <- Runtime.deliverAnnounceWake runtime wake (Runtime.announceWakeIdentity wake)
            pure True
          else pure False
  pure (review || announce)

-- | @_barrier_cleared(runtime, blocker)@.
barrierCleared :: PrReadinessV5Application -> V5Runtime -> Text -> IO Bool
barrierCleared app runtime blocker =
  Ingress.manifest app.ingress blocker app.instanceId >>= \case
    Just manifest -> Runtime.manifestFolded runtime manifest.entries
    Nothing -> Ingress.custodyTerminal app.ingress app.instanceId blocker

-- | @activity(name)@.
applicationActivity :: PrReadinessV5Application -> Text -> IO (Maybe GateDefinition)
applicationActivity app name = (`Runtime.runtimeActivity` name) <$> applicationRuntime app

-- | @inactive_activity_result(name, invocation, definition)@: the exact
-- typed blocked terminal of a durable publication whose Instance is no
-- longer active, without a provider call.
inactiveActivityResult :: Text -> ActivityInvocation -> Maybe GateDefinition -> IO Json
inactiveActivityResult name invocation = \case
  Just definition
    | declarationName definition.activity.declaration == name && invocation.activity == name -> do
        input <- case invocation.input of
          Object members
            | Set.fromList (map fst members) == Set.fromList (map fst definition.parameters) -> pure members
          _ -> throwIO (ValueError "V5 publication invocation has malformed parameters")
        (parameter, Annotation (_ :: proxy a)) <- case definition.parameters of
          [single] -> pure single
          _ -> throwIO (ValueError "V5 publication invocation has malformed parameters")
        let encoded = fromMaybe Null (lookup parameter input)
        work <- either raiseFailureText pure (decodeDataclass @a encoded)
        result <- case name of
          "reply_gate"
            | Just (w :: ReplyReq) <- as work ->
                pure (variantOf ReplyBlocked {id = w.id, text = w.text})
          "dash_gate"
            | Just (w :: DashReq) <- as work ->
                pure
                  ( variantOf
                      DashBlocked
                        { entries = w.entries
                        , digest = w.digest
                        , desiredEntries = w.desiredEntries
                        , desiredDigest = w.desiredDigest
                        }
                  )
          "announce_gate"
            | Just (w :: AnnounceReq) <- as work ->
                pure (variantOf ABlocked {incarnation = w.incarnation, head = w.head, base = w.base, policy = w.policy})
          _ -> throwIO (ValueError "V5 publication invocation has no inactive result")
        case definition.result of
          -- A single declared type: the ordinary dataclass encoding.
          [_] -> pure result.fields
          members -> either raiseFailureText pure (encodeVariant members result)
  _ -> throwIO (ValueError "V5 publication invocation has no matching Activity definition")
  where
    as :: forall a b. (Typeable a, Typeable b) => a -> Maybe b
    as value = case eqT @a @b of
      Just Refl -> Just value
      Nothing -> Nothing

-- | @has_unresolved_publication()@.
hasUnresolvedPublication :: PrReadinessV5Application -> IO Bool
hasUnresolvedPublication app = applicationRuntime app >>= Runtime.hasUnresolvedPublication

-- | @run_durable_activities(limit)@.
runDurableActivities :: PrReadinessV5Application -> Int -> IO Int
runDurableActivities app limit = applicationRuntime app >>= (`Runtime.runDurableActivities` limit)

-- | @stop_durable_activities()@.
stopDurableActivities :: PrReadinessV5Application -> IO ()
stopDurableActivities app = applicationRuntime app >>= Runtime.stopDurableActivities

-- | @detached_state()@: the durable authority grant without V5 runtime
-- state.
detachedState :: PrReadinessV5Application -> IO Json
detachedState app = do
  claim <- Ingress.detachedClaim app.ingress app.instanceId
  pure $
    Object
      [ ("ready", Null)
      ,
        ( "snapshot"
        , case claim of
            Nothing -> Null
            Just c ->
              Object
                [ ("phase", String c.phase)
                , ("incarnation", Int c.incarnation)
                , ("head", String c.head)
                , ("base_head", String c.base)
                , ("policy_digest", String c.policy)
                ]
        )
      ]

-- | @close()@.
closeApplication :: PrReadinessV5Application -> IO ()
closeApplication app = do
  runtime <- readIORef app.runtimeRef
  mapM_ Runtime.closeRuntime runtime
    `finally` ( Timers.close app.timers
                  `finally` ( closeReviewRequestStore app.reviewRequests
                                `finally` Ingress.close app.ingress
                            )
              )
