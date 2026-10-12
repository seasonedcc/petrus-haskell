{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The cross-layer public-Engine World for stateful generation: a port of
-- the reference's @tests/dst/generated_runtime_world.py@.
--
-- One real Engine spans the generated vocabulary: identified scoped
-- deliveries, a delayed timer transition, Activity retry over the real
-- SQLite 'LocalDispatch' (under the World's provider clock), a one-shot
-- pre-custody Dispatch refusal, a one-shot refusal of the work projection
-- batch before it reaches the JSONL History, and scope reset fencing a late
-- terminal. The checker judges the live state against detached canonical
-- folds of the History.
module Petrus.Testing.Dst.Engine.GeneratedRuntime
  ( instanceId
  , scenarioId
  , scopeName
  , maturationInstant
  , profileIdentity
  , checkerIdentity
  , worldBudget
  , applicationNet
  , RuntimeGeneration (..)
  , GeneratedRuntimeProfile (..)
  , generatedRuntimeProfile
  , RuntimeVariant (..)
  , generatedRuntimeProfileWith
  , livelockProfileIdentity
  , generatedRuntimeChecker
  , StoryOptions (..)
  , defaultStoryOptions
  , executeGeneratedRuntimeStory
  , buildGeneratedRuntimeArtifact
  , buildGeneratedRuntimeArtifactWith
  , drainNow
  , drainAll
  ) where

import Control.Exception (throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.IORef
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity
  ( ActivityFailureFields (..)
  , ActivityInvocationFields (..)
  , ExecutionPolicyFields (..)
  , activityFailure
  , executionPolicy
  , failureFields
  )
import Petrus.Engine (DriveOutcome (..), Engine)
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.Binding (handlerTokens, prepareInvocation)
import Petrus.Impetus.History.Records
  ( ActivityRequested (..)
  , ActivityTerminalQuarantined (..)
  , CandidateSelected (..)
  , ExternalEventDelivered (..)
  , FiringBegun (..)
  , FiringCompleted (..)
  , FiringFailed (..)
  , Record (..)
  , ScopeOpened (..)
  , ScopeReset (..)
  , TimerMatured (..)
  , recordName
  , recordOccurrence
  )
import Petrus.Impetus.History.Records qualified as Records
import Petrus.Impetus.History.Replay (replayMarking, replayScopes, replayWatermark)
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.Instance (DeliveryScope (..), FiringOutcome (..))
import Petrus.Impetus.Petrinet hiding (Delay)
import Petrus.Impetus.Petrinet qualified as Petrinet
import Petrus.Impetus.Scope (scopeGeneration)
import Petrus.Json (Json (..), lookupMember, parseJson, surrogateRefusingLoads)
import Petrus.Motus.Dispatch (ActivityAttempt, AttemptFailure (..), Dispatch (..))
import Petrus.Motus.Dispatch.Local (LocalDispatch, LocalDispatchClock (..), LocalWorkerDispatch)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Observation qualified as Observation
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Bridge (Bridged (..), withBridge)
import Petrus.Testing.Dst.Engine.Common
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World
import System.Directory (doesFileExist, getFileSize)

-- ---------------------------------------------------------------------------
-- Constants

source, inputPlace, result, waiting, released, work, release :: NetPath
source = path "source"
inputPlace = path "input"
result = path "result"
waiting = path "waiting"
released = path "released"
work = path "work"
release = path "release"

scopeName, instanceId, scenarioId :: Text
scopeName = "batch"
instanceId = "dst-generated-runtime"
scenarioId = "generated-runtime-cross-layer-world-v4"

maturationInstant :: Integer
maturationInstant = 5

resourceKeys :: [Text]
resourceKeys =
  [ "pending.dispatch_tasks"
  , "pending.in_flight"
  , "pending.worker_claim"
  , "retained.dispatch_facts"
  , "retained.external_facts"
  , "retained.history_bytes"
  , "retained.history_records"
  , "retained.marking_bytes"
  , "retained.marking_tokens"
  ]

-- | @PROFILE_IDENTITY@.
profileIdentity :: ProfileIdentity
profileIdentity =
  Identity
    { name = "petrus.engine.generated-runtime"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ( "commands"
                , Object
                    [ ("engine.drive", Array [])
                    , ("scope.open", strs ["name"])
                    , ("scope.reset", strs ["name"])
                    , ("source.deliver", strs ["identity", "value"])
                    , ("worker.claim", Array [])
                    , ("worker.complete", strs ["result"])
                    , ("worker.fail", strs ["attempt", "error"])
                    ]
                )
              , ("faults", Object [("dispatch.refuse", String "activity_requested"), ("history.refuse", String "projection_committed")])
              , ("instance", String instanceId)
              , ("observations", strs ["engine.generated-runtime-authority", "generated-runtime-state"])
              , ("resources", strs resourceKeys)
              , ("timer", Int maturationInstant)
              ]
          )
    }

-- | @LIVELOCK_PROFILE_IDENTITY@ (@generated_runtime_qualification.py@):
-- the test-only falsification mutant's identity.
livelockProfileIdentity :: ProfileIdentity
livelockProfileIdentity =
  Identity
    { name = "petrus.engine.generated-runtime-livelock-mutation"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("base_profile", toJson profileIdentity)
              , ("mutation", String "reschedule an otherwise quiescent engine.drive at the same logical instant")
              ]
          )
    }

-- | @CHECKER_IDENTITY@.
checkerIdentity :: CheckerIdentity
checkerIdentity =
  Identity
    { name = "petrus.engine.generated-runtime-authority"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ( "properties"
                , strs
                    [ "live marking and watermark agree with canonical replay"
                    , "live in-flight and lifecycle state agrees with a small History fold"
                    , "occurrences remain dense and selected, begun, and terminal records stay writer-valid"
                    , "one stable invocation spans refusal, redispatch, retry, and reload"
                    , "provider execution never repeats after a frozen terminal"
                    , "identified deliveries have one canonical authority and exact redelivery acknowledgement"
                    , "scope reset fences late terminal projection"
                    , "refused projection exposes no firing completion"
                    , "world and retry work remain bounded"
                    ]
                )
              ]
          )
    }

-- | @WORLD_BUDGET@.
worldBudget :: SomeBudget
worldBudget =
  SomeBudgetV4
    BudgetV4
      { limits =
          Budget
            { actions = 96
            , queuedCommands = 8
            , timerAdvances = 1
            , logicalInstant = maturationInstant
            , reloads = 4
            , predicatePolls = 24
            , artifactBytes = 524288
            }
      , profileResources =
          Map.fromList
            [ ("pending.dispatch_tasks", 2)
            , ("pending.in_flight", 2)
            , ("pending.worker_claim", 1)
            , ("retained.dispatch_facts", 32)
            , ("retained.external_facts", 64)
            , ("retained.history_bytes", 65536)
            , ("retained.history_records", 128)
            , ("retained.marking_bytes", 8192)
            , ("retained.marking_tokens", 8)
            ]
      }

-- | @application_net()@.
applicationNet :: Net
applicationNet =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = [place inputPlace, place result, place waiting, place released]
        , transitions =
            [ transition source
            , (transition work) {handler = Just (HandlerSymbol "bridge")}
            , (transition release) {timers = [Petrinet.Delay (IntNumber maturationInstant)]}
            ]
        , arcs = [arc source inputPlace, arc inputPlace work, arc work result, arc waiting release, arc release released]
        , completion = Nothing
        , name = Just "dst-generated-runtime"
        }

-- ---------------------------------------------------------------------------
-- The bridge

-- | @RuntimeBridge(prepared, projected)@: counts into the profile.
bridged :: IORef Int -> IORef Int -> Bridged
bridged prepared projected =
  Bridged
    { prepare = \b -> case bindingTokens b of
            t : _ -> do
              policy <-
                executionPolicy
                  ExecutionPolicyFields
                    { attempts = 2
                    , heartbeatTimeout = 30
                    , initialInterval = IntNumber 0
                    , coefficient = IntNumber 2
                    , maxInterval = IntNumber 60
                    , jitter = IntNumber 0
                    , startToClose = Nothing
                    , scheduleToClose = Nothing
                    }
              prepareInvocation ActivityInvocationFields {activity = "calculate", input = t.payload, policy, correlation = Nothing, idempotency = Nothing}
            [] -> Left "IndexError('tuple index out of range')"
    , project = \_ value -> Right (handlerTokens [(result, [Token (Just "Result") value])])
    , onPrepare = Right () <$ modifyIORef' prepared (+ 1)
    , onProject = Right () <$ modifyIORef' projected (+ 1)
    }

-- ---------------------------------------------------------------------------
-- Refusing adapters

-- | @RefusingProjectionHistory@: one-shot refusal before a work projection
-- batch reaches JSONL, recording every work projection batch.
refusingProjectionHistory :: FilePath -> IORef [Json] -> IO (HistoryStore, Text -> IO ())
refusingProjectionHistory historyPath attempts = do
  delegate <- openJsonlHistoryStore historyPath
  refusal <- newIORef Nothing
  let workProjection = \case
        RFiringCompleted r -> r.transition == work
        _ -> False
      extend' records
        | not (any workProjection records) = delegate.extend records
        | otherwise = do
            let attempt = ("record_types", strs (map recordName records))
            armed <- readIORef refusal
            case armed of
              Just message -> do
                writeIORef refusal Nothing
                modifyIORef' attempts (<> [Object [("accepted", Bool False), attempt]])
                throwIO (PyException "OSError" message)
              Nothing -> do
                delegate.extend records
                modifyIORef' attempts (<> [Object [("accepted", Bool True), attempt]])
  pure (delegate {extend = extend'}, writeIORef refusal . Just)

-- | @RefusingLocalDispatch@: one-shot pre-custody refusal on the public
-- LocalDispatch door, recording every dispatch attempt.
refusingDispatch :: LocalDispatch -> IORef [Json] -> IO (Dispatch, Text -> IO ())
refusingDispatch custody attempts = do
  refusal <- newIORef Nothing
  let delegate = Local.toDispatch custody
      dispatch' occurrence inv = do
        let attempt = invocationView occurrence inv
        armed <- readIORef refusal
        case armed of
          Just message -> do
            writeIORef refusal Nothing
            modifyIORef' attempts (<> [Object (("accepted", Bool False) : attempt)])
            throwIO (PyException "OSError" message)
          Nothing -> do
            delegate.dispatch occurrence inv
            modifyIORef' attempts (<> [Object (("accepted", Bool True) : attempt)])
  pure (delegate {dispatch = dispatch'}, writeIORef refusal . Just)

-- ---------------------------------------------------------------------------
-- The profile

-- | @RuntimeGeneration@.
data RuntimeGeneration = RuntimeGeneration
  { engine :: Engine
  , history :: HistoryStore
  , local :: LocalDispatch
  , refuseNextDispatch :: Text -> IO ()
  , refuseNextProjection :: Text -> IO ()
  , worker :: IORef (Maybe (LocalWorkerDispatch, ActivityAttempt))
  , poisoned :: IORef Bool
  , timerScheduled :: IORef (Maybe Integer)
  }

-- | A @GeneratedRuntimeProfile@ and its cross-generation state.
data GeneratedRuntimeProfile = GeneratedRuntimeProfile
  { profile :: Profile IO RuntimeGeneration
  , deliveryAttempts :: IORef [Json]
  , dispatchAttempts :: IORef [Json]
  , projectionAttempts :: IORef [Json]
  , workerAttempts :: IORef [Json]
  , workerFailures :: IORef [Json]
  , workerCompletions :: IORef [Json]
  , prepareCalls :: IORef Int
  , projectCalls :: IORef Int
  , scopeGenerationRef :: IORef Integer
  , scopeOpens :: IORef Int
  , scopeResets :: IORef Int
  , drops :: IORef Int
  , closes :: IORef Int
  }

-- | @_attempt_occurrence@: the occurrence of a LocalDispatch attempt
-- identity (@[instance, occurrence]@).
attemptOccurrence :: ActivityAttempt -> Either Text Integer
attemptOccurrence attempt = case parseJson surrogateRefusingLoads (TE.encodeUtf8 attempt.attemptId) of
  Right (Array [_, Int occurrence]) -> Right occurrence
  _ -> Left "generated runtime received a malformed LocalDispatch attempt identity"

-- | The marking projection's @json.dumps(..., separators=(",", ":"))@ size
-- and token count.
markingGauges :: Json -> IO (Integer, Integer)
markingGauges view = do
  bytes <- either (throwIO . PyException "ValueError") pure (canonicalBytes view)
  let tokens = case view of
        Array entries -> sum [case member "tokens" e of Array ts -> length ts; _ -> 0 | e <- entries]
        _ -> 0
  pure (toInteger (BS.length bytes), toInteger tokens)

markingView :: Marking -> IO Json
markingView m = either (throwIO . PyException "ValueError" . T.pack . show) pure (Observation.marking m)

numberJson :: Number -> Json
numberJson = \case
  IntNumber i -> Int i
  FloatNumber d -> Float d

occurrencePair :: NetPath -> Int -> Json
occurrencePair t o = Object [("occurrence", jsonInt o), ("transition", String (netPathText t))]

-- | Which generated-runtime profile class to build.
data RuntimeVariant
  = -- | @GeneratedRuntimeProfile@.
    Unmutated
  | -- | @LivelockMutationProfile@ (@generated_runtime_qualification.py@): a
    -- test-only falsification profile which preserves safety but cannot
    -- quiesce. Its @_drive@ reschedules an otherwise quiescent
    -- @engine.drive@ at the same logical instant once the timer is due and
    -- the Engine is awaiting.
    LivelockMutation
  deriving stock (Eq, Show)

-- | @GeneratedRuntimeProfile(history_path, dispatch_path)@.
generatedRuntimeProfile :: FilePath -> FilePath -> IO GeneratedRuntimeProfile
generatedRuntimeProfile = generatedRuntimeProfileWith Unmutated

-- | @GeneratedRuntimeProfile@ or @LivelockMutationProfile@ over the same
-- History and LocalDispatch paths.
generatedRuntimeProfileWith :: RuntimeVariant -> FilePath -> FilePath -> IO GeneratedRuntimeProfile
generatedRuntimeProfileWith variant historyPath dispatchPath = do
  time <- newWorldTime
  deliveryAttempts <- newIORef []
  dispatchAttempts <- newIORef []
  projectionAttempts <- newIORef []
  workerAttempts <- newIORef []
  workerFailures <- newIORef []
  workerCompletions <- newIORef []
  prepareCalls <- newIORef 0
  projectCalls <- newIORef 0
  scopeGenerationRef <- newIORef 0
  scopeOpens <- newIORef 0
  scopeResets <- newIORef 0
  drops <- newIORef 0
  closes <- newIORef 0
  let variantIdentity = case variant of
        Unmutated -> profileIdentity
        LivelockMutation -> livelockProfileIdentity
      scheduledAt instant = ScheduledCommand {instant, command = Command {profile = variantIdentity, name = "engine.drive", payload = Object []}}
      -- LivelockMutationProfile._drive
      mutate current r = case variant of
        LivelockMutation
          | null r.scheduled && current >= maturationInstant -> case lookupMember "status" r.value of
              Nothing -> raise "KeyError" "'status'"
              Just (String "awaiting") -> pure ApplyResult {disposition = r.disposition, value = r.value, scheduled = [scheduledAt current]}
              Just _ -> pure r
        _ -> pure r
      open load = do
        (history, refuseNextProjection) <- refusingProjectionHistory historyPath projectionAttempts
        custody <-
          Local.openLocalDispatch
            dispatchPath
            instanceId
            Local.defaultLocalDispatchOptions {Local.clock = Just (LocalDispatchClock (worldProviderMs time))}
        (dispatch', refuseNextDispatch) <- refusingDispatch custody dispatchAttempts
        let options = withBridge (bridged prepareCalls projectCalls) Engine.defaultEngineOptions {Engine.clock = Just (worldClock time)}
        engine <-
          if load
            then Engine.load applicationNet instanceId history dispatch' options
            else
              Engine.create
                applicationNet
                instanceId
                history
                dispatch'
                options {Engine.marking = markingFromList [(waiting, [Token (Just "Waiting") Null])]}
        RuntimeGeneration engine history custody refuseNextDispatch refuseNextProjection
          <$> newIORef Nothing
          <*> newIORef False
          <*> newIORef Nothing
      start load = do
        current <- syncTime time
        g <- ioScenario (open load)
        pure GenerationStart {generation = g, scheduled = [scheduledAt current | load]}
      applied g value = do
        frontier <- ioScenario (historyLength g.history)
        pure ApplyResult {disposition = Applied, value = Object (("frontier", Int frontier) : value), scheduled = []}
      activeScope g = do
        scopes <- ioScenario (Engine.activeScopes g.engine)
        maybe (raise "KeyError" (pythonStrRepr scopeName)) pure (Map.lookup scopeName scopes)
      activeAttempt g = do
        held <- liftIO (readIORef g.worker)
        maybe (raise "RuntimeError" "worker outcome requires one claimed Activity attempt") pure held
      attemptView attempt = do
        occurrence <- orRaise "ValueError" (attemptOccurrence attempt)
        let inv = attempt.invocation
        pure $
          Object
            [ ("activity", String inv.activity)
            , ("correlation", maybe Null String inv.correlation)
            , ("epoch", Int (epochOf attempt))
            , ("idempotency", maybe Null String inv.idempotency)
            , ("input", inv.input)
            , ("occurrence", Int occurrence)
            , ("policy", policyJson inv.policy)
            , ("queue", String attempt.queue)
            ]
      faultMessage f name = do
        unless (f.name == name && isObject f.payload) $
          raise "ValueError" ("unexpected generated-runtime fault " <> pythonStrRepr f.name)
        case member "message" f.payload of
          String message -> pure message
          _ -> raise "ValueError" ("generated-runtime fault " <> pythonStrRepr name <> " requires a message")
      configureFaults :: RuntimeGeneration -> Scenario IO [Text]
      configureFaults g = do
        dispatchFaults <- faults "activity_requested"
        dispatchMessages <- forM dispatchFaults $ \f -> do
          message <- faultMessage f "dispatch.refuse"
          liftIO (g.refuseNextDispatch message)
          pure message
        projectionFaults <- faults "projection_committed"
        projectionMessages <- forM projectionFaults $ \f -> do
          message <- faultMessage f "history.refuse"
          liftIO (g.refuseNextProjection message)
          pure message
        pure (dispatchMessages <> projectionMessages)
      applyCommand g c current = case c.name of
        "scope.open" -> do
          scope <- ioScenario (Engine.openScope g.engine scopeName)
          liftIO $ do
            writeIORef scopeGenerationRef (scopeGeneration scope)
            modifyIORef' scopeOpens (+ 1)
          applied g [("generation", Int (scopeGeneration scope))]
        "scope.reset" -> do
          scope <- activeScope g
          opened <- ioScenario (Engine.resetScope g.engine scope)
          liftIO $ do
            writeIORef scopeGenerationRef (scopeGeneration opened)
            modifyIORef' scopeResets (+ 1)
          applied g [("generation", Int (scopeGeneration opened))]
        "source.deliver" -> do
          let identity = case member "identity" c.payload of
                String s -> s
                _ -> ""
              value = member "value" c.payload
          scope <- activeScope g
          outcome <- ioScenario (Engine.deliver g.engine source [Token (Just "Input") value] identity (Just (ScopeGeneration scope)))
          let disposition = case outcome of
                Engine.DeliveryPrior _ -> Idempotent
                _ -> Applied
              attempt = Object [("disposition", String (actionDispositionText disposition)), ("identity", String identity), ("value", value)]
          liftIO (modifyIORef' deliveryAttempts (<> [attempt]))
          frontier <- ioScenario (historyLength g.history)
          pure
            ApplyResult
              { disposition
              , value = Object [("attempt", attempt), ("frontier", Int frontier)]
              , scheduled = [scheduledAt current]
              }
        "worker.claim" -> do
          held <- liftIO (readIORef g.worker)
          when (isJust held) (raise "RuntimeError" "generated runtime already holds an Activity attempt")
          n <- liftIO (length <$> readIORef workerAttempts)
          w <- ioScenario (Local.worker g.local ["default"] (Just ("dst-generated-worker-" <> T.pack (show (n + 1)))))
          claimed <- ioScenario (Local.claim w)
          attempt <- maybe (raise "RuntimeError" "LocalDispatch has no eligible generated-runtime Activity") pure claimed
          liftIO (writeIORef g.worker (Just (w, attempt)))
          detached <- attemptView attempt
          liftIO (modifyIORef' workerAttempts (<> [detached]))
          applied g [("attempt", detached), ("instant", Int current)]
        "worker.fail" -> do
          (w, attempt) <- activeAttempt g
          let expectedJson = member "attempt" c.payload
              expected = case expectedJson of
                Int n -> n
                Bool True -> 1
                _ -> 0
              errorText = case member "error" c.payload of
                String s -> s
                _ -> ""
          unless (epochOf attempt == expected) $
            raise "ValueError" ("worker.fail expected epoch " <> pyIntText expectedJson <> ", found " <> attempt.epoch)
          failure <-
            orRaise "ValueError" $
              activityFailure
                ActivityFailureFields
                  { failureError = errorText
                  , failureKind = "Unavailable"
                  , failureDetails = Object [("attempt", expectedJson)]
                  , failureRetryable = True
                  , failureRetryAfter = Just (IntNumber 0)
                  }
          ioScenario (Local.fail w attempt (FailureClassified failure))
          liftIO (modifyIORef' workerFailures (<> [Object [("attempt", expectedJson), ("error", String (failureFields failure).failureError)]]))
          ioScenario (Local.close w)
          liftIO (writeIORef g.worker Nothing)
          applied g [("failed_epoch", expectedJson)]
        "worker.complete" -> do
          (w, attempt) <- activeAttempt g
          let value = member "result" c.payload
          ioScenario (Local.complete w attempt value)
          occurrence <- orRaise "ValueError" (attemptOccurrence attempt)
          records <- ioScenario (toList <$> g.history.snapshot)
          let cancelled = or [fromInteger occurrence `elem` r.cancelled | RScopeReset r <- records]
              report =
                Object
                  [ ("cancelled", Bool cancelled)
                  , ("epoch", Int (epochOf attempt))
                  , ("occurrence", Int occurrence)
                  , ("result", value)
                  ]
          liftIO (modifyIORef' workerCompletions (<> [report]))
          ioScenario (Local.close w)
          liftIO (writeIORef g.worker Nothing)
          applied g [("report", report)]
        _ -> drive g current >>= mutate current
      drive g current = do
        liftIO $ do
          scheduledTimer <- readIORef g.timerScheduled
          when (scheduledTimer == Just current) (writeIORef g.timerScheduled Nothing)
        expected <- configureFaults g
        advanced <- liftIO (try (Engine.advance g.engine))
        case advanced of
          Left e -> do
            let (cls, message) = pythonError e
            if cls == "OSError" && message `elem` expected
              then do
                liftIO (writeIORef g.poisoned True)
                frontier <- ioScenario (historyLength g.history)
                pure
                  ApplyResult
                    { disposition = RefusedExpected
                    , value = Object [("error", String message), ("frontier", Int frontier)]
                    , scheduled = []
                    }
              else throwError (ProfileError cls message)
          Right outcome -> do
            (snapshot, frontier) <- ioScenario ((,) <$> engineCurrent g.engine <*> historyLength g.history)
            let inFlight = case member "in_flight" snapshot of
                  Array xs -> xs
                  _ -> []
                activityPending = any (\entry -> member "phase" entry == String "activity_pending") inFlight
            timerScheduled <- liftIO (readIORef g.timerScheduled)
            scheduled <-
              if outcome.ready && not activityPending
                then pure [scheduledAt current]
                else case member "next_maturation" snapshot of
                  Int next
                    | timerScheduled /= Just next -> do
                        liftIO (writeIORef g.timerScheduled (Just next))
                        pure [scheduledAt next]
                  _ -> pure []
            pure
              ApplyResult
                { disposition = Applied
                , value =
                    Object
                      [ ("firings", Array [String (netPathText f.transition) | f <- outcome.firings])
                      , ("frontier", Int frontier)
                      , ("ready", Bool outcome.ready)
                      , ("status", member "status" snapshot)
                      , ("waiting", Bool outcome.waiting)
                      ]
                , scheduled
                }
      state g current = do
        records <- toList <$> g.history.snapshot
        isPoisoned <- readIORef g.poisoned
        live <- if isPoisoned then pure Nothing else Just <$> engineCurrent g.engine
        liveScopes <- case live of
          Nothing -> pure Null
          Just _ -> do
            scopes <- Engine.activeScopes g.engine
            pure (Object [(name, Int (scopeGeneration s)) | (name, s) <- Map.toAscList scopes])
        (replayedScopes, _) <- either (throwIO . PyException "ValueError") pure (replayScopes records)
        replayedMarking <- either (throwIO . PyException "ValueError") pure (replayMarking records) >>= markingView
        watermark <- either (throwIO . PyException "ValueError") pure (replayWatermark records)
        generation <- readIORef scopeGenerationRef
        opens <- readIORef scopeOpens
        resets <- readIORef scopeResets
        deliveries <- readIORef deliveryAttempts
        dispatches <- readIORef dispatchAttempts
        dropped <- readIORef drops
        prepared <- readIORef prepareCalls
        projected <- readIORef projectCalls
        projections <- readIORef projectionAttempts
        attempts <- readIORef workerAttempts
        completions <- readIORef workerCompletions
        failures <- readIORef workerFailures
        let liveField key = maybe Null (member key) live
        pure $
          Object
            [ ("active_scopes", Object [(name, Int (scopeGeneration s)) | (name, s) <- Map.toAscList replayedScopes])
            , ("authored_scope_generation", Int generation)
            , ("authored_scope_opens", jsonInt opens)
            , ("authored_scope_resets", jsonInt resets)
            , ( "canonical_deliveries"
              , Array
                  [ Object [("identity", String r.identity), ("value", tokenData r.tokens)]
                  | RExternalEventDelivered r <- records
                  ]
              )
            , ("completed_occurrences", Array [jsonInt r.occurrence | RActivityCompleted r <- records])
            , ("current_instant", Int current)
            , ("delivery_attempts", Array deliveries)
            , ("dispatch_attempts", Array dispatches)
            , ("drops", jsonInt dropped)
            , ("firing_begun", Array [occurrencePair r.transition r.occurrence | RFiringBegun r <- records])
            , ("firing_completed", Array [occurrencePair r.transition r.occurrence | RFiringCompleted r <- records])
            , ("firing_failed", Array [occurrencePair r.transition r.occurrence | RFiringFailed r <- records])
            , ("firing_selected", Array [occurrencePair r.transition r.occurrence | RCandidateSelected r <- records])
            , ("frontier", jsonInt (length records))
            , ("live_in_flight", liveField "in_flight")
            , ("live_marking", liveField "marking")
            , ("live_scopes", liveScopes)
            , ("live_watermark", liveField "watermark")
            , ("prepare_calls", jsonInt prepared)
            , ("project_calls", jsonInt projected)
            , ("projection_attempts", Array projections)
            , ("quarantined_occurrences", Array [jsonInt r.occurrence | RActivityTerminalQuarantined r <- records])
            , ("record_types", strs (map recordName records))
            , ( "record_occurrences"
              , Array
                  [ Object [("kind", String (recordName r)), ("occurrence", jsonInt o)]
                  | r <- records
                  , Just o <- [recordOccurrence r]
                  ]
              )
            , ("replay_marking", replayedMarking)
            , ("replay_watermark", numberJson watermark)
            , ( "requested_invocations"
              , Array
                  [ Object
                      [ ("activity", String r.activity)
                      , ("correlation", String r.correlation)
                      , ("idempotency", String r.idempotency)
                      , ("input", r.input)
                      , ("occurrence", jsonInt r.occurrence)
                      , ("policy", policyJson r.policy)
                      ]
                  | RActivityRequested r <- records
                  ]
              )
            , ( "scope_records"
              , Array
                  ( concat
                      [ case r of
                          RScopeOpened o -> [Object [("generation", Int (scopeGeneration o.scope)), ("kind", String "open")]]
                          RScopeReset s ->
                            [ Object
                                [ ("cancelled", Array (map jsonInt s.cancelled))
                                , ("closed", Int (scopeGeneration s.closed))
                                , ("kind", String "reset")
                                , ("opened", Int (scopeGeneration s.opened))
                                ]
                            ]
                          _ -> []
                      | r <- records
                      ]
                  )
              )
            , ("status", maybe (String "poisoned") (member "status") live)
            , ( "timer_maturations"
              , Array
                  [ Object [("instant", numberJson r.instant), ("maturation_instant", numberJson r.maturationInstant)]
                  | RTimerMatured r <- records
                  ]
              )
            , ("worker_attempts", Array attempts)
            , ("worker_completions", Array completions)
            , ("worker_failures", Array failures)
            ]
      resources generation = do
        records <- case generation of
          Just g -> toList <$> g.history.snapshot
          Nothing -> do
            exists <- doesFileExist historyPath
            if exists then toList <$> (openJsonlHistoryStore historyPath >>= (.snapshot)) else pure []
        facts <- mapM readIORef [deliveryAttempts, dispatchAttempts, projectionAttempts, workerAttempts, workerFailures, workerCompletions]
        dispatches <- readIORef dispatchAttempts
        attempts <- readIORef workerAttempts
        failures <- readIORef workerFailures
        completions <- readIORef workerCompletions
        claimHeld <- case generation of
          Just g -> isJust <$> readIORef g.worker
          Nothing -> pure False
        exists <- doesFileExist historyPath
        historyBytes <- if exists then getFileSize historyPath else pure 0
        view <-
          if null records
            then markingView emptyMarking
            else either (throwIO . PyException "ValueError") pure (replayMarking records) >>= markingView
        (markingBytes, markingTokens) <- markingGauges view
        let begun = nub [r.occurrence | RFiringBegun r <- records]
            ended = nub ([r.occurrence | RFiringCompleted r <- records] <> [r.occurrence | RFiringFailed r <- records])
            cancelled = nub (concat [r.cancelled | RScopeReset r <- records])
            acceptedDispatch = nub [member "occurrence" a | a <- dispatches, member "accepted" a == Bool True]
            providerTerminals = nub [member "occurrence" c | c <- completions]
            count = toInteger . length
        pure $
          ResourceUsage $
            Map.fromList
              [ ("pending.dispatch_tasks", count (filter (`notElem` providerTerminals) acceptedDispatch))
              , ("pending.in_flight", count [o | o <- begun, o `notElem` ended, o `notElem` cancelled])
              , ("pending.worker_claim", if claimHeld then 1 else 0)
              , ("retained.dispatch_facts", count acceptedDispatch + count attempts + count failures + count completions)
              , ("retained.external_facts", sum (map count facts))
              , ("retained.history_bytes", historyBytes)
              , ("retained.history_records", count records)
              , ("retained.marking_bytes", markingBytes)
              , ("retained.marking_tokens", markingTokens)
              ]
      emptyPayload p = p == Object []
      validate c = case c.name of
        n
          | n `elem` ["engine.drive", "worker.claim"] ->
              if emptyPayload c.payload then pure c else throwError (ProfileError "ValueError" (n <> " payload must be an empty object"))
          | n `elem` ["scope.open", "scope.reset"] ->
              if c.payload == Object [("name", String scopeName)]
                then pure c
                else throwError (ProfileError "ValueError" (n <> " requires the exact supported scope name"))
        "source.deliver" -> do
          unless (exactKeys ["identity", "value"] c.payload) $
            throwError (ProfileError "ValueError" "source.deliver requires exact identity and value fields")
          case member "identity" c.payload of
            String s | not (T.null s) -> pure ()
            _ -> throwError (ProfileError "ValueError" "source.deliver identity must be a non-empty string")
          case member "value" c.payload of
            Int _ -> pure ()
            _ -> throwError (ProfileError "ValueError" "source.deliver value must be an integer")
          pure c
        "worker.fail" -> do
          unless (exactKeys ["attempt", "error"] c.payload) $
            throwError (ProfileError "ValueError" "worker.fail requires exact attempt and error fields")
          unless (member "attempt" c.payload `elem` [Int 1, Int 2]) $
            throwError (ProfileError "ValueError" "worker.fail attempt must be 1 or 2")
          case member "error" c.payload of
            String s | not (T.null s) -> pure ()
            _ -> throwError (ProfileError "ValueError" "worker.fail error must be a non-empty string")
          pure c
        "worker.complete" ->
          if exactKeys ["result"] c.payload
            then pure c
            else throwError (ProfileError "ValueError" "worker.complete requires one exact result field")
        n -> throwError (ProfileError "ValueError" ("unknown generated-runtime command " <> pythonStrRepr n))
      validateFault f = do
        let expected = case f.name of
              "dispatch.refuse" -> Just "activity_requested"
              "history.refuse" -> Just "projection_committed"
              _ -> Nothing
        unless (expected == Just f.target && f.disposition == Refuse) $
          throwError (ProfileError "ValueError" ("unsupported generated-runtime fault " <> pythonStrRepr f.name))
        unless (exactKeys ["message"] f.payload) $
          throwError (ProfileError "ValueError" "generated-runtime faults require one exact message field")
        case member "message" f.payload of
          String s | not (T.null s) -> pure f
          _ -> throwError (ProfileError "ValueError" "generated-runtime fault message must be a non-empty string")
      release' counter g = ioDoor $ do
        modifyIORef' counter (+ 1)
        held <- readIORef g.worker
        forM_ held (Local.close . fst)
        Engine.close g.engine
      profile =
        Profile
          { identity = variantIdentity
          , validate
          , validateFault
          , create = start False
          , load = start True
          , apply = \g c -> do
              current <- syncTime time
              applyCommand g c current
          , observe = \g request -> do
              current <- syncTime time
              unless (request.name `elem` ["engine.generated-runtime-authority", "generated-runtime-state"]) $
                raise "ValueError" ("unknown generated-runtime observation " <> pythonStrRepr request.name)
              unless (request.payload == Null || emptyPayload request.payload) $
                raise "ValueError" "generated-runtime observations do not accept parameters"
              ioScenario (state g current)
          , dropGeneration = release' drops
          , closeGeneration = release' closes
          , resourceUsage = Just (ioDoor . resources)
          }
  pure
    GeneratedRuntimeProfile
      { profile
      , deliveryAttempts
      , dispatchAttempts
      , projectionAttempts
      , workerAttempts
      , workerFailures
      , workerCompletions
      , prepareCalls
      , projectCalls
      , scopeGenerationRef
      , scopeOpens
      , scopeResets
      , drops
      , closes
      }
  where
    isObject = \case
      Object _ -> True
      _ -> False
    tokenData = \case
      t : _ -> t.payload
      [] -> Null
    pyIntText = \case
      Int n -> T.pack (show n)
      Bool True -> "True"
      Bool False -> "False"
      other -> T.pack (show other)

-- ---------------------------------------------------------------------------
-- The checker

-- | @GeneratedRuntimeAuthorityChecker()@. The reference's checker keeps
-- @_frozen_execution_counts@ across the checks of one World or replay; here
-- that dictionary is the checker's memory, which the World threads from one
-- check to the next and every World or replay starts empty.
generatedRuntimeChecker :: Checker
generatedRuntimeChecker =
  Checker
    { identity = checkerIdentity
    , request = ObservationRequest {name = "engine.generated-runtime-authority", payload = Object []}
    , check = Check [] (\frozen o -> Right (verdict frozen o.value))
    }

-- | @set(a) <= set(b)@ over JSON values (Python equality).
subset :: [Json] -> [Json] -> Bool
subset a b = all (`elem` b) a

-- | @dict@ built from pairs: the last value per key, in first-key order.
dictOf :: [(Json, a)] -> [(Json, a)]
dictOf pairs = [(k, last [v | (k', v) <- pairs, k' == k]) | k <- nub (map fst pairs)]

-- | Python @dict@ equality.
dictEq :: (Eq a) => [(Json, a)] -> [(Json, a)] -> Bool
dictEq a b = length a == length b && all (\(k, v) -> maybe False (== v) (lookup k b)) a

withoutKeys :: [Text] -> Json -> Json
withoutKeys keys = \case
  Object members -> Object [(k, v) | (k, v) <- members, k `notElem` keys]
  other -> other

-- | The verdict over one observation, and the frozen execution counts after it.
verdict :: [(Json, (Int, Int))] -> Json -> (CheckResult, [(Json, (Int, Int))])
verdict frozen value =
  let liveMarking = member "live_marking" value
      replayExact =
        liveMarking == Null
          || (liveMarking == member "replay_marking" value && member "live_watermark" value == member "replay_watermark" value)

      selected = listOf "firing_selected" value
      begun = listOf "firing_begun" value
      pair entry = Array [member "occurrence" entry, member "transition" entry]
      begunPairs = nub (map pair begun)
      selectedPairs = nub (map pair selected)
      begunOccurrences = nub (map (member "occurrence") begun)
      occurrencePairs =
        selectedPairs `subset` begunPairs
          && length selectedPairs == length selected
          && length begunOccurrences == length begun

      completedFirings = listOf "firing_completed" value
      failedFirings = listOf "firing_failed" value
      completedIds = map (member "occurrence") completedFirings
      failedIds = map (member "occurrence") failedFirings
      recordOccurrences = listOf "record_occurrences" value
      intsOf xs = [n | Int n <- xs]
      historyWriterValid =
        length (intsOf begunOccurrences) == length begunOccurrences
          && sort (intsOf begunOccurrences) == [1 .. toInteger (length begun)]
          && all (\entry -> member "occurrence" entry `elem` begunOccurrences) recordOccurrences
          && length completedIds == length (nub completedIds)
          && length failedIds == length (nub failedIds)
          && not (any (`elem` failedIds) completedIds)

      requests = listOf "requested_invocations" value
      dispatches = listOf "dispatch_attempts" value
      workerAttempts = listOf "worker_attempts" value
      requestByOccurrence = dictOf [(member "occurrence" r, r) | r <- requests]
      requestFor occurrence = lookup occurrence requestByOccurrence
      invocationStable =
        all (\d -> Just (withoutKeys ["accepted"] d) == requestFor (member "occurrence" d)) dispatches
          && all (\a -> Just (withoutKeys ["epoch", "queue"] a) == requestFor (member "occurrence" a)) workerAttempts
      preparationExact = member "prepare_calls" value == jsonInt (length requests)

      attemptsByOccurrence =
        [ (occurrence, [member "epoch" a | a <- workerAttempts, member "occurrence" a == occurrence])
        | occurrence <- nub (map (member "occurrence") workerAttempts)
        ]
      retriesBounded =
        all (\(_, epochs) -> epochs == map Int [1 .. toInteger (length epochs)] && length epochs <= 2) attemptsByOccurrence

      deliveryAttempts = listOf "delivery_attempts" value
      canonicalDeliveries = listOf "canonical_deliveries" value
      (accepted, deliveryAcknowledgements) = foldl acknowledge ([], True) deliveryAttempts
      acknowledge (acc, ok) attempt =
        let identity = member "identity" attempt
            payload = member "value" attempt
         in case lookup identity acc of
              Nothing -> (acc <> [(identity, payload)], ok && member "disposition" attempt == String "applied")
              Just prior -> (acc, ok && prior == payload && member "disposition" attempt == String "idempotent")
      deliveryExact = canonicalDeliveries == [Object [("identity", i), ("value", p)] | (i, p) <- accepted]

      completed = listOf "completed_occurrences" value
      quarantined = listOf "quarantined_occurrences" value
      completions = listOf "worker_completions" value
      terminalUnique = length completed == length (nub completed) && length quarantined == length (nub quarantined)
      completionOccurrences = map (member "occurrence") completions
      terminalAuthorized =
        (completed <> quarantined) `subset` completionOccurrences
          && length completionOccurrences == length (nub completionOccurrences)

      projectionAttempts = listOf "projection_attempts" value
      workFirings = [f | f <- completedFirings, member "transition" f == String "work"]
      projectionExact =
        member "project_calls" value == jsonInt (length projectionAttempts)
          && length workFirings == length [a | a <- projectionAttempts, member "accepted" a == Bool True]
          && map (member "occurrence") workFirings `subset` completed

      activeScopes = member "active_scopes" value
      generation = member "authored_scope_generation" value
      lifecycleExact =
        activeScopes == (if generation == Int 0 then Object [] else Object [(scopeName, generation)])
          && (member "live_scopes" value == Null || member "live_scopes" value == activeScopes)
          && member "authored_scope_opens" value `leq` 1
          && member "authored_scope_resets" value `leq` 1
          && and [truthy (member "cancelled" c) | c <- completions, member "occurrence" c `elem` quarantined]

      cancelled = nub (concat [listOf "cancelled" r | r <- listOf "scope_records" value])
      expectedInFlight =
        [o | o <- begunOccurrences, o `notElem` completedIds, o `notElem` failedIds, o `notElem` cancelled]
      requestOccurrences = map (member "occurrence") requests
      expectedPhases =
        [ ( o
          , if o `elem` completed
              then String "projection_pending"
              else if o `elem` requestOccurrences then String "activity_pending" else String "pure_pending"
          )
        | o <- expectedInFlight
        ]
      liveInFlight = member "live_in_flight" value
      inFlightExact =
        liveInFlight == Null
          || dictEq (dictOf [(member "occurrence" e, member "phase" e) | e <- listOf "live_in_flight" value]) expectedPhases

      maturations = listOf "timer_maturations" value
      timerFirings = [f | f <- completedFirings, member "transition" f == String "release"]
      timerExact =
        length maturations <= 1
          && all (== Object [("instant", Int maturationInstant), ("maturation_instant", Int maturationInstant)]) maturations
          && length timerFirings <= length maturations

      boundsHold =
        length (listOf "record_types" value) <= 128
          && length deliveryAttempts <= 8
          && length workerAttempts <= 16
      -- @_frozen_execution_counts.setdefault@ over every completed
      -- occurrence (no short circuit).
      freeze (ok, known) occurrence =
        let execCounts =
              ( length [() | a <- dispatches, member "occurrence" a == occurrence]
              , length [() | a <- workerAttempts, member "occurrence" a == occurrence]
              )
         in case lookup occurrence known of
              Just previous -> (ok && execCounts == previous, known)
              Nothing -> (ok, known <> [(occurrence, execCounts)])
      (frozenExecution, frozen') = foldl' freeze (True, frozen) completed
      passed =
        and
          [ replayExact
          , inFlightExact
          , occurrencePairs
          , historyWriterValid
          , invocationStable
          , preparationExact
          , retriesBounded
          , deliveryExact
          , deliveryAcknowledgements
          , terminalUnique
          , terminalAuthorized
          , frozenExecution
          , projectionExact
          , lifecycleExact
          , timerExact
          , boundsHold
          ]
   in ( CheckResult
          { passed
      , detail =
          Object
            [ ("bounds_hold", Bool boundsHold)
            , ("delivery_acknowledgements", Bool deliveryAcknowledgements)
            , ("delivery_exact", Bool deliveryExact)
            , ("frozen_execution", Bool frozenExecution)
            , ("history_writer_valid", Bool historyWriterValid)
            , ("in_flight_exact", Bool inFlightExact)
            , ("invocation_stable", Bool invocationStable)
            , ("lifecycle_exact", Bool lifecycleExact)
            , ("occurrence_pairs", Bool occurrencePairs)
            , ("projection_exact", Bool projectionExact)
            , ("preparation_exact", Bool preparationExact)
            , ("replay_exact", Bool replayExact)
            , ("retries_bounded", Bool retriesBounded)
            , ("terminal_authorized", Bool terminalAuthorized)
            , ("terminal_unique", Bool terminalUnique)
            , ("timer_exact", Bool timerExact)
            ]
      }
      , frozen'
      )
  where
    leq v n = case v of
      Int i -> i <= n
      _ -> False
    truthy = \case
      Bool b -> b
      Null -> False
      Int i -> i /= 0
      String s -> not (T.null s)
      Array xs -> not (null xs)
      Object ms -> not (null ms)
      Float d -> d /= 0

-- ---------------------------------------------------------------------------
-- The story

-- | The keyword arguments of @execute_generated_runtime_story@.
data StoryOptions = StoryOptions
  { firstValue :: Integer
  , secondValue :: Integer
  , retryError :: Text
  , dispatchError :: Text
  , projectionError :: Text
  , finish :: Bool
  }

defaultStoryOptions :: StoryOptions
defaultStoryOptions =
  StoryOptions
    { firstValue = 3
    , secondValue = 7
    , retryError = "generated retry"
    , dispatchError = "dst generated Dispatch custody refused"
    , projectionError = "dst generated projection refused"
    , finish = True
    }

-- | Step while the head of the queue is due now.
drainNow :: WorldT IO RuntimeGeneration ()
drainNow = do
  queued <- World.pending
  current <- World.currentInstant
  case queued of
    q : _ | member "instant" q == Int current -> World.step >> drainNow
    _ -> pure ()

drainAll :: WorldT IO RuntimeGeneration ()
drainAll = do
  n <- World.pendingCount
  when (n > 0) (World.step >> drainAll)

-- | @execute_generated_runtime_story@: the authoring body.
executeGeneratedRuntimeStory :: StoryOptions -> WorldT IO RuntimeGeneration ()
executeGeneratedRuntimeStory opts = do
  timeline <- World.timeline
  let scope = Object [("name", String scopeName)]
      firings o key = listOf key o.value
      hasFiring t o = any (\f -> member "transition" f == String t) (firings o "firing_completed")
  _ <- Timeline.command timeline "scope.open" scope
  Timeline.activateFault
    timeline
    (Timeline.fault "dispatch.refuse" "activity_requested")
      { Timeline.disposition = Refuse
      , Timeline.payload = Object [("message", String opts.dispatchError)]
      }
  _ <- Timeline.command timeline "source.deliver" (Object [("identity", String "generated-event-1"), ("value", Int opts.firstValue)])
  refused <- World.step
  ensure (refused.result.disposition == RefusedExpected) "refused disposition"

  Timeline.crash timeline "generated_dispatch_refused"
  _ <- World.restart
  timeline' <- World.timeline
  requested <-
    Timeline.runUntil
      timeline'
      "generated-runtime-state"
      (\o -> length [() | a <- listOf "dispatch_attempts" o.value, member "accepted" a == Bool True] == 1)
  ensure (memberOf "prepare_calls" requested == Int 1) "requested prepare"

  first <- Timeline.command timeline' "worker.claim" (Object [])
  ensure (member "epoch" (member "attempt" first.value) == Int 1) "first epoch"
  _ <- Timeline.command timeline' "worker.fail" (Object [("attempt", Int 1), ("error", String opts.retryError)])
  second <- Timeline.command timeline' "worker.claim" (Object [])
  ensure (member "epoch" (member "attempt" second.value) == Int 2) "second epoch"
  _ <- Timeline.command timeline' "worker.complete" (Object [("result", Object [("value", Int opts.firstValue)])])

  Timeline.activateFault
    timeline'
    (Timeline.fault "history.refuse" "projection_committed")
      { Timeline.disposition = Refuse
      , Timeline.payload = Object [("message", String opts.projectionError)]
      }
  projected <- Timeline.command timeline' "engine.drive" (Object [])
  ensure (projected.disposition == RefusedExpected) "projected disposition"
  frozen <- Timeline.observe timeline' "generated-runtime-state"
  ensure (memberOf "completed_occurrences" frozen == Array [Int 2]) "frozen completed"
  ensure (not (hasFiring "work" frozen)) "frozen projection"

  Timeline.crash timeline' "generated_projection_refused"
  _ <- World.restart
  timeline'' <- World.timeline
  recovered <- Timeline.runUntil timeline'' "generated-runtime-state" (hasFiring "work")
  ensure (memberOf "prepare_calls" recovered == Int 1) "recovered prepare"
  ensure (length (firings recovered "worker_attempts") == 2) "recovered attempts"

  drainNow
  duplicate <- Timeline.command timeline'' "source.deliver" (Object [("identity", String "generated-event-1"), ("value", Int opts.firstValue)])
  ensure (duplicate.disposition == Idempotent) "duplicate disposition"
  drainNow

  _ <- Timeline.command timeline'' "source.deliver" (Object [("identity", String "generated-event-2"), ("value", Int opts.secondValue)])
  _ <- Timeline.runUntil timeline'' "generated-runtime-state" (\o -> length (firings o "requested_invocations") == 2)
  late <- Timeline.command timeline'' "worker.claim" (Object [])
  let lateOccurrence = member "occurrence" (member "attempt" late.value)
  _ <- Timeline.command timeline'' "scope.reset" scope
  _ <- Timeline.command timeline'' "worker.complete" (Object [("result", Object [("value", Int opts.secondValue)])])
  _ <- Timeline.command timeline'' "engine.drive" (Object [])
  quarantined <- Timeline.observe timeline'' "generated-runtime-state"
  ensure (lateOccurrence `elem` firings quarantined "quarantined_occurrences") "late quarantined"
  ensure (memberOf "active_scopes" quarantined == Object [(scopeName, Int 2)]) "quarantined scopes"

  timer <- Timeline.runUntil timeline'' "generated-runtime-state" (hasFiring "release")
  ensure (memberOf "current_instant" timer == Int maturationInstant) "timer instant"
  ensure
    ( memberOf "timer_maturations" timer
        == Array [Object [("instant", Int maturationInstant), ("maturation_instant", Int maturationInstant)]]
    )
    "timer maturations"
  drainAll
  when opts.finish (Timeline.finish timeline'' ExternalWait)

-- | @build_generated_runtime_artifact(history_path, dispatch_path)@.
buildGeneratedRuntimeArtifact :: FilePath -> FilePath -> IO (Either DstFailure AnyArtifact)
buildGeneratedRuntimeArtifact = buildGeneratedRuntimeArtifactWith defaultStoryOptions

-- | @build_generated_runtime_artifact(history_path, dispatch_path, **options)@.
buildGeneratedRuntimeArtifactWith :: StoryOptions -> FilePath -> FilePath -> IO (Either DstFailure AnyArtifact)
buildGeneratedRuntimeArtifactWith opts historyPath dispatchPath = do
  p <- generatedRuntimeProfile historyPath dispatchPath
  let checker = generatedRuntimeChecker
  World.withWorld
    WorldConfig {profile = p.profile, budget = worldBudget, checkers = [checker], seed = Nothing, progress = Nothing}
    (executeGeneratedRuntimeStory opts >> World.artifact scenarioId)

