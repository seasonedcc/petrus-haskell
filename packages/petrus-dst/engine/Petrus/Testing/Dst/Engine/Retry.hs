{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Public-Engine worlds over production LocalDispatch custody: a port of
-- the reference's @tests/dst/retry_world.py@.
--
-- Three profiles share one implementation, as the reference's
-- @RetryEngineProfile@ and its two subclasses do:
--
-- * 'Retry' (@RetryEngineProfile@): one retryable failure, a crash, the
--   reclaimed exact invocation, and exhaustion.
-- * 'DelayedRetry' (@DelayedRetryEngineProfile@): the same under the
--   World's explicit provider clock, crossing the retry deadline exactly.
-- * 'Terminal' (@TerminalEngineProfile@): one durable provider result, an
--   idempotent report, a refused conflicting report, a crash before
--   collection, and convergence.
--
-- Each generation opens the real SQLite 'LocalDispatch' over the profile's
-- database file and the real Engine over its JSONL History, exactly as the
-- reference's @_generation@ does.
module Petrus.Testing.Dst.Engine.Retry
  ( -- * Constants
    instanceId
  , scenarioId
  , terminalScenarioId
  , delayedRetryScenarioId
  , retryAvailableInstant
  , worldBudget
  , delayedRetryWorldBudget
  , applicationNet
    -- * Identities
  , profileIdentity
  , delayedRetryProfileIdentity
  , terminalProfileIdentity
  , checkerIdentity
  , delayedRetryCheckerIdentity
  , terminalCheckerIdentity
    -- * Profiles
  , RetryKind (..)
  , RetryGeneration (..)
  , RetryProfile (..)
  , retryEngineProfile
  , delayedRetryEngineProfile
  , terminalEngineProfile
    -- * Checkers
  , retryAuthorityChecker
  , delayedRetryAuthorityChecker
  , terminalAuthorityChecker
    -- * Stories
  , executeRetryStory
  , buildRetryArtifact
  , executeDelayedRetryStory
  , buildDelayedRetryArtifact
  , executeTerminalStory
  , buildTerminalArtifact
  ) where

import Control.Exception (fromException, try)
import Control.Monad (forM_, unless, when)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (toList)
import Data.IORef
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
  ( ActivityFailureFields (..)
  , ActivityInvocation (..)
  , ExecutionPolicyFields (..)
  , activityFailure
  , executionPolicy
  )
import Petrus.Engine (DriveOutcome (..), Engine)
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.Binding (handlerTokens)
import Petrus.Impetus.History.Records (recordName)
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.Instance (FiringOutcome (..))
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (ActivityAttempt (epoch, instance', invocation, queue), AttemptFailure (..), DispatchError (..))
import Petrus.Motus.Dispatch.Local (LocalDispatch, LocalDispatchClock (..), LocalWorkerDispatch)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Testing.Dst
import Petrus.Testing.Dst.Engine.Bridge (Bridged (..), withBridge)
import Petrus.Testing.Dst.Engine.Common
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World

-- ---------------------------------------------------------------------------
-- Constants

inputPlace, done, work :: NetPath
inputPlace = path "input"
done = path "done"
work = path "work"

instanceId, scenarioId, terminalScenarioId, delayedRetryScenarioId :: Text
instanceId = "dst-world-retry-recovery"
scenarioId = "retry-crash-exhaustion-world-v3"
terminalScenarioId = "local-terminal-redelivery-world-v3"
delayedRetryScenarioId = "delayed-retry-crash-recovery-world-v3"

-- | @RETRY_AVAILABLE_INSTANT@.
retryAvailableInstant :: Integer
retryAvailableInstant = 5

identityOf :: Text -> Json -> Identity k
identityOf name definition = Identity {name, version = 1, digest = digestOf definition}

policyDefinition :: Integer -> Json
policyDefinition interval = Object [("attempts", Int 2), ("initial_interval", Int interval)]

retryCommands :: [(Text, Json)]
retryCommands =
  [ ("engine.drive", Array [])
  , ("worker.claim", Array [])
  , ("worker.fail", strs ["attempt", "error"])
  ]

-- | @PROFILE_IDENTITY@.
profileIdentity :: ProfileIdentity
profileIdentity =
  identityOf
    "petrus.engine.local-dispatch-retry"
    ( Object
        [ ("commands", Object retryCommands)
        , ("dispatch", String "local")
        , ("instance", String instanceId)
        , ("observations", strs ["activity-requested", "engine.retry-authority", "retry-claimed", "retry-exhausted", "retry-recovered"])
        , ("policy", policyDefinition 0)
        ]
    )

-- | @DELAYED_RETRY_PROFILE_IDENTITY@.
delayedRetryProfileIdentity :: ProfileIdentity
delayedRetryProfileIdentity =
  identityOf
    "petrus.engine.local-dispatch-delayed-retry"
    ( Object
        [ ("commands", Object (retryCommands <> [("worker.probe", Array [])]))
        , ("dispatch", String "local")
        , ("instance", String instanceId)
        , ( "observations"
          , strs
              [ "activity-requested"
              , "delayed-retry-available"
              , "delayed-retry-before-available"
              , "delayed-retry-recovered"
              , "delayed-retry-terminal"
              , "engine.delayed-retry-authority"
              ]
          )
        , ("policy", policyDefinition retryAvailableInstant)
        , ("provider_clock", String "world-logical-seconds-to-milliseconds-v1")
        ]
    )

-- | @TERMINAL_PROFILE_IDENTITY@.
terminalProfileIdentity :: ProfileIdentity
terminalProfileIdentity =
  identityOf
    "petrus.engine.local-dispatch-terminal"
    ( Object
        [ ( "commands"
          , Object [("engine.drive", Array []), ("worker.claim", Array []), ("worker.complete", strs ["result"])]
          )
        , ("dispatch", String "local")
        , ("instance", String instanceId)
        , ( "observations"
          , strs
              [ "engine.local-terminal-authority"
              , "local-terminal-converged"
              , "local-terminal-durable"
              , "local-terminal-requested"
              ]
          )
        , ("policy", policyDefinition 0)
        ]
    )

checkerIdentity, delayedRetryCheckerIdentity, terminalCheckerIdentity :: CheckerIdentity
checkerIdentity =
  identityOf
    "petrus.engine.retry-authority"
    ( Object
        [ ( "properties"
          , strs
              [ "retry claims preserve one logical invocation across exact epochs"
              , "a terminal Activity failure requires exhaustion of both authored attempts"
              , "retry exhaustion produces no business projection"
              ]
          )
        ]
    )
delayedRetryCheckerIdentity =
  identityOf
    "petrus.engine.delayed-retry-authority"
    ( Object
        [ ( "properties"
          , strs
              [ "retry claims preserve one logical invocation across exact epochs"
              , "a delayed retry is unavailable before its provider deadline"
              , "the reconstructed retry becomes claimable at its exact provider deadline"
              , "retry exhaustion produces no business projection"
              ]
          )
        ]
    )
terminalCheckerIdentity =
  identityOf
    "petrus.engine.local-terminal-authority"
    ( Object
        [ ( "properties"
          , strs
              [ "the first accepted provider result remains authoritative"
              , "an exact provider report is idempotent and a conflicting report is refused"
              , "one durable provider result produces at most one canonical terminal and projection"
              ]
          )
        ]
    )

-- | @WORLD_BUDGET@.
worldBudget :: SomeBudget
worldBudget =
  SomeBudget
    Budget
      { actions = 40
      , queuedCommands = 8
      , timerAdvances = 0
      , logicalInstant = 0
      , reloads = 1
      , predicatePolls = 16
      , artifactBytes = 262144
      }

-- | @DELAYED_RETRY_WORLD_BUDGET@.
delayedRetryWorldBudget :: SomeBudget
delayedRetryWorldBudget =
  SomeBudget
    Budget
      { actions = 48
      , queuedCommands = 8
      , timerAdvances = 2
      , logicalInstant = retryAvailableInstant
      , reloads = 1
      , predicatePolls = 20
      , artifactBytes = 262144
      }

-- | @application_net()@.
applicationNet :: Net
applicationNet =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = [place inputPlace, place done]
        , transitions = [(transition work) {handler = Just (HandlerSymbol "bridge")}]
        , arcs = [arc inputPlace work, arc work done]
        , completion = Nothing
        , name = Just "dst-world-retry-recovery"
        }

-- ---------------------------------------------------------------------------
-- The bridge

-- | @RetryBridge@: counts its calls.
data Bridge = Bridge {prepared :: IORef Int, projected :: IORef Int}

-- | The bridge's pure prepare/project pair and its call counting.
bridged :: Integer -> Bridge -> Bridged
bridged interval bridge =
  Bridged
    { prepare = \b -> case bindingTokens b of
            t : _ -> do
              policy <-
                executionPolicy
                  ExecutionPolicyFields
                    { attempts = 2
                    , heartbeatTimeout = 30
                    , initialInterval = IntNumber interval
                    , coefficient = IntNumber 2
                    , maxInterval = IntNumber 60
                    , jitter = IntNumber 0
                    , startToClose = Nothing
                    , scheduleToClose = Nothing
                    }
              Right ActivityInvocation {activity = "work", input = t.payload, policy, correlation = Nothing, idempotency = Nothing}
            [] -> Left "IndexError('tuple index out of range')"
    , project = \_ result -> Right (handlerTokens [(done, [Token (Just "Done") result])])
    , onPrepare = Right () <$ modifyIORef' bridge.prepared (+ 1)
    , onProject = Right () <$ modifyIORef' bridge.projected (+ 1)
    }

-- ---------------------------------------------------------------------------
-- Profiles

-- | Which of the reference's three profile classes.
data RetryKind = Retry | DelayedRetry | Terminal
  deriving stock (Eq, Show)

-- | @RetryGeneration@.
data RetryGeneration = RetryGeneration
  { engine :: Engine
  , history :: HistoryStore
  , dispatch :: LocalDispatch
  , bridge :: Bridge
  , worker :: IORef (Maybe (LocalWorkerDispatch, ActivityAttempt))
  , drives :: IORef Int
  , poisoned :: IORef Bool
  }

-- | A retry-family profile and its cross-generation state.
data RetryProfile = RetryProfile
  { kind :: RetryKind
  , profile :: Profile IO RetryGeneration
  , attempts :: IORef [Json]
  , claimChecks :: IORef [Json]
  , failuresDelivered :: IORef Int
  , drops :: IORef Int
  , closes :: IORef Int
  , acceptedResults :: IORef [Json]
  , terminalReports :: IORef [Json]
  }

retryDebugFields :: [Text]
retryDebugFields =
  ["attempts", "bridge", "drives", "drops", "failures_delivered", "frontier", "in_flight", "marking", "record_types", "status"]

observationFields :: RetryKind -> [(Text, [Text])]
observationFields = \case
  Retry ->
    [ ("activity-requested", retryDebugFields)
    , ("engine.retry-authority", ["attempts", "failures_delivered", "record_types"])
    , ("retry-claimed", retryDebugFields)
    , ("retry-exhausted", retryDebugFields)
    , ("retry-recovered", retryDebugFields)
    ]
  DelayedRetry ->
    let fields = retryDebugFields <> ["claim_checks", "current_instant"]
     in [ ("activity-requested", fields)
        , ("delayed-retry-available", fields)
        , ("delayed-retry-before-available", fields)
        , ("delayed-retry-recovered", fields)
        , ("delayed-retry-terminal", fields)
        , ("engine.delayed-retry-authority", ["attempts", "claim_checks", "current_instant", "failures_delivered", "record_types"])
        ]
  Terminal ->
    let fields =
          [ "accepted_results"
          , "attempts"
          , "bridge"
          , "drives"
          , "drops"
          , "frontier"
          , "in_flight"
          , "marking"
          , "record_types"
          , "status"
          , "terminal_reports"
          ]
     in [ ("engine.local-terminal-authority", ["accepted_results", "attempts", "bridge", "marking", "record_types", "status", "terminal_reports"])
        , ("local-terminal-converged", fields)
        , ("local-terminal-durable", fields)
        , ("local-terminal-requested", fields)
        ]

-- | @RetryEngineProfile(history_path, dispatch_path)@.
retryEngineProfile :: FilePath -> FilePath -> IO RetryProfile
retryEngineProfile = newRetryProfile Retry

-- | @DelayedRetryEngineProfile(history_path, dispatch_path)@.
delayedRetryEngineProfile :: FilePath -> FilePath -> IO RetryProfile
delayedRetryEngineProfile = newRetryProfile DelayedRetry

-- | @TerminalEngineProfile(history_path, dispatch_path)@.
terminalEngineProfile :: FilePath -> FilePath -> IO RetryProfile
terminalEngineProfile = newRetryProfile Terminal

-- | The detached attempt view (@_attempt_view@).
attemptView :: ActivityAttempt -> Json
attemptView attempt =
  Object
    [ ("activity", String inv.activity)
    , ("correlation", maybe Null String inv.correlation)
    , ("epoch", Int (epochOf attempt))
    , ("idempotency", maybe Null String inv.idempotency)
    , ("input", inv.input)
    , ("instance", maybe Null String attempt.instance')
    , ("policy", policyJson inv.policy)
    , ("queue", String attempt.queue)
    ]
  where
    inv = attempt.invocation

newRetryProfile :: RetryKind -> FilePath -> FilePath -> IO RetryProfile
newRetryProfile kind historyPath dispatchPath = do
  time <- newWorldTime
  attempts <- newIORef []
  claimChecks <- newIORef []
  failuresDelivered <- newIORef 0
  drops <- newIORef 0
  closes <- newIORef 0
  acceptedResults <- newIORef []
  terminalReports <- newIORef []
  let identity = case kind of
        Retry -> profileIdentity
        DelayedRetry -> delayedRetryProfileIdentity
        Terminal -> terminalProfileIdentity
      interval = if kind == DelayedRetry then retryAvailableInstant else 0
      label = case kind of
        Terminal -> "terminal"
        _ -> "retry"
      scheduledAt instant name = ScheduledCommand {instant, command = Command {profile = identity, name, payload = Object []}}
      retrySchedule = [scheduledAt (retryAvailableInstant - 1) "worker.probe", scheduledAt retryAvailableInstant "worker.claim"]
      open load = do
        history <- openJsonlHistoryStore historyPath
        let providerClock = if kind == DelayedRetry then Just (LocalDispatchClock (worldProviderMs time)) else Nothing
        dispatch <- Local.openLocalDispatch dispatchPath instanceId Local.defaultLocalDispatchOptions {Local.clock = providerClock}
        bridge <- Bridge <$> newIORef 0 <*> newIORef 0
        let options = withBridge (bridged interval bridge) Engine.defaultEngineOptions {Engine.clock = Just (worldClock time)}
        engine <-
          if load
            then Engine.load applicationNet instanceId history (Local.toDispatch dispatch) options
            else
              Engine.create
                applicationNet
                instanceId
                history
                (Local.toDispatch dispatch)
                options {Engine.marking = markingFromList [(inputPlace, [Token (Just "Input") (Int 3)])]}
        RetryGeneration engine history dispatch bridge <$> newIORef Nothing <*> newIORef 0 <*> newIORef False
      start load = do
        current <- syncTime time
        g <- ioScenario (open load)
        extra <-
          if load && kind == DelayedRetry
            then liftIO $ do
              failures <- readIORef failuresDelivered
              claimed <- readIORef attempts
              pure (if failures == 1 && length claimed == 1 then retrySchedule else [])
            else pure []
        pure GenerationStart {generation = g, scheduled = scheduledAt current "engine.drive" : extra}
      applied g value scheduled = do
        frontier <- ioScenario (historyLength g.history)
        pure ApplyResult {disposition = Applied, value = Object (("frontier", Int frontier) : value), scheduled}
      claimWith g workerId = do
        w <- ioScenario (Local.worker g.dispatch ["default"] (Just workerId))
        attempt <- ioScenario (Local.claim w)
        pure (w, attempt)
      applyCommand g c current = case c.name of
        "worker.probe" | kind == DelayedRetry -> do
          (w, attempt) <- claimWith g "dst-retry-probe"
          let check =
                Object
                  [ ("available", Bool (isJust attempt))
                  , ("epoch", maybe Null (Int . epochOf) attempt)
                  , ("instant", Int current)
                  ]
          liftIO (modifyIORef' claimChecks (<> [check]))
          case attempt of
            Nothing -> ioScenario (Local.close w)
            Just a -> liftIO $ do
              writeIORef g.worker (Just (w, a))
              modifyIORef' attempts (<> [attemptView a])
          applied g [("claim_check", check)] []
        "worker.complete" | kind == Terminal -> do
          held <- liftIO (readIORef g.worker)
          (w, attempt) <- maybe (raise "RuntimeError" "worker.complete requires one claimed Activity attempt") pure held
          let result = member "result" c.payload
          outcome <- liftIO (try (Local.complete w attempt result))
          disposition <- case outcome of
            Left e
              | Just (DispatchError message) <- fromException e
              , "conflicting terminal report" `T.isInfixOf` message ->
                  pure RefusedExpected
              | otherwise -> let (cls, message) = pythonError e in throwError (ProfileError cls message)
            Right () -> do
              accepted <- liftIO (readIORef acceptedResults)
              case accepted of
                [] -> Applied <$ liftIO (writeIORef acceptedResults [result])
                first : _
                  | result == first -> pure Idempotent
                  | otherwise -> raise "AssertionError" "LocalDispatch accepted a conflicting terminal report"
          let report :: Json
              report = Object [("disposition", String (actionDispositionText disposition)), ("result", result)]
          liftIO (modifyIORef' terminalReports (<> [report]))
          frontier <- ioScenario (historyLength g.history)
          pure ApplyResult {disposition, value = Object [("frontier", Int frontier), ("report", report)], scheduled = []}
        "worker.claim" -> do
          held <- liftIO (readIORef g.worker)
          when (isJust held) (raise "RuntimeError" "retry generation already holds an Activity attempt")
          n <- liftIO (length <$> readIORef attempts)
          (w, claimed) <- claimWith g ("dst-worker-" <> T.pack (show (n + 1)))
          attempt <- maybe (raise "RuntimeError" "LocalDispatch has no eligible Activity retry") pure claimed
          let detached = attemptView attempt
          liftIO $ do
            writeIORef g.worker (Just (w, attempt))
            modifyIORef' attempts (<> [detached])
            modifyIORef' claimChecks (<> [Object [("available", Bool True), ("epoch", Int (epochOf attempt)), ("instant", Int current)]])
          applied g [("attempt", detached)] []
        "worker.fail" -> do
          held <- liftIO (readIORef g.worker)
          (w, attempt) <- maybe (raise "RuntimeError" "worker.fail requires one claimed Activity attempt") pure held
          let expected = maybe 0 id (lookupInt "attempt" c.payload)
              errorText = case member "error" c.payload of
                String s -> s
                _ -> ""
          unless (epochOf attempt == expected) $
            raise "ValueError" ("worker.fail expected epoch " <> T.pack (show expected) <> ", found " <> attempt.epoch)
          failure <-
            orRaise "ValueError" $
              activityFailure
                ActivityFailureFields
                  { failureError = errorText
                  , failureKind = "Unavailable"
                  , failureDetails = Object [("attempt", Int expected)]
                  , failureRetryable = True
                  , failureRetryAfter = Just (IntNumber 0)
                  }
          ioScenario (Local.fail w attempt (FailureClassified failure))
          ioScenario (Local.close w)
          liftIO $ do
            writeIORef g.worker Nothing
            modifyIORef' failuresDelivered (+ 1)
          let scheduled
                | kind == DelayedRetry && expected == 1 = retrySchedule
                | expected == 2 = [scheduledAt current "engine.drive"]
                | otherwise = []
          applied g [("failed_epoch", Int expected)] scheduled
        _ -> drive g current
      drive g current = do
        liftIO (modifyIORef' g.drives (+ 1))
        advanced <- liftIO (try (Engine.advance g.engine))
        case advanced of
          Left e -> do
            let (cls, message) = pythonError e
            names <- ioScenario (map recordName . toList <$> g.history.snapshot)
            case reverse names of
              "FiringFailed" : "ActivityFailed" : _
                | cls == "RuntimeError" -> do
                    liftIO (writeIORef g.poisoned True)
                    pure
                      ApplyResult
                        { disposition = ActionQuarantined
                        , value = Object [("error", String message), ("frontier", jsonInt (length names))]
                        , scheduled = []
                        }
              _ -> throwError (ProfileError cls message)
          Right outcome -> do
            (snapshot, names) <- ioScenario $ do
              snapshot <- engineCurrent g.engine
              names <- map recordName . toList <$> g.history.snapshot
              pure (snapshot, names)
            let status = member "status" snapshot
                activityPending = "ActivityRequested" `elem` names && "ActivityFailed" `notElem` names
                scheduled
                  | status `notElem` [String "completed", String "terminated"] && outcome.ready && not activityPending =
                      [scheduledAt current "engine.drive"]
                  | otherwise = []
            pure
              ApplyResult
                { disposition = Applied
                , value =
                    Object
                      [ ("firings", Array [String (netPathText f.transition) | f <- outcome.firings])
                      , ("frontier", jsonInt (length names))
                      , ("ready", Bool outcome.ready)
                      , ("status", status)
                      , ("waiting", Bool outcome.waiting)
                      ]
                , scheduled
                }
      state g current = do
        names <- map recordName . toList <$> g.history.snapshot
        isPoisoned <- readIORef g.poisoned
        (status, marking, inFlight) <-
          if isPoisoned
            then pure (String "poisoned", Null, Null)
            else do
              snapshot <- engineCurrent g.engine
              pure (member "status" snapshot, member "marking" snapshot, member "in_flight" snapshot)
        claimed <- readIORef attempts
        p <- readIORef g.bridge.prepared
        pr <- readIORef g.bridge.projected
        d <- readIORef g.drives
        dropped <- readIORef drops
        failures <- readIORef failuresDelivered
        checks <- readIORef claimChecks
        accepted <- readIORef acceptedResults
        reports <- readIORef terminalReports
        pure
          [ ("accepted_results", Array accepted)
          , ("attempts", Array claimed)
          , ("bridge", Object [("prepared", jsonInt p), ("projected", jsonInt pr)])
          , ("claim_checks", Array checks)
          , ("current_instant", Int current)
          , ("drives", jsonInt d)
          , ("drops", jsonInt dropped)
          , ("failures_delivered", jsonInt failures)
          , ("frontier", jsonInt (length names))
          , ("in_flight", inFlight)
          , ("marking", marking)
          , ("record_types", Array (map String names))
          , ("status", status)
          , ("terminal_reports", Array reports)
          ]
      observeLabel = if kind == DelayedRetry then "delayed-retry" else "retry"
      emptyPayload p = p == Object []
      validateRetry c = case c.name of
        n
          | n `elem` ["engine.drive", "worker.claim"] ->
              if emptyPayload c.payload then pure c else throwError (ProfileError "ValueError" (n <> " payload must be an empty object"))
        "worker.fail" -> do
          unless (exactKeys ["attempt", "error"] c.payload) $
            throwError (ProfileError "ValueError" "worker.fail requires exact attempt and error fields")
          case member "attempt" c.payload of
            Int n | n `elem` [1, 2] -> pure ()
            _ -> throwError (ProfileError "ValueError" "worker.fail attempt must be 1 or 2")
          case member "error" c.payload of
            String s | not (T.null s) -> pure ()
            _ -> throwError (ProfileError "ValueError" "worker.fail error must be a non-empty string")
          pure c
        n -> throwError (ProfileError "ValueError" ("unknown retry Engine profile command " <> pythonStrRepr n))
      validate c = case kind of
        DelayedRetry
          | c.name == "worker.probe" ->
              if emptyPayload c.payload then pure c else throwError (ProfileError "ValueError" "worker.probe payload must be an empty object")
        Terminal -> case c.name of
          n
            | n `elem` ["engine.drive", "worker.claim"] ->
                if emptyPayload c.payload then pure c else throwError (ProfileError "ValueError" (n <> " payload must be an empty object"))
          "worker.complete" ->
            if exactKeys ["result"] c.payload
              then pure c
              else throwError (ProfileError "ValueError" "worker.complete requires one exact result field")
          n -> throwError (ProfileError "ValueError" ("unknown terminal Engine profile command " <> pythonStrRepr n))
        _ -> validateRetry c
      release counter g = ioDoor $ do
        modifyIORef' counter (+ 1)
        held <- readIORef g.worker
        forM_ held (Local.close . fst)
        Engine.close g.engine
      profile =
        Profile
          { identity
          , validate
          , validateFault = \f -> throwError (ProfileError "ValueError" (label <> " Engine profile has no fault named " <> pythonStrRepr f.name))
          , create = start False
          , load = start True
          , apply = \g c -> do
              current <- syncTime time
              applyCommand g c current
          , observe = \g request -> do
              current <- syncTime time
              fields <- case lookup request.name (observationFields kind) of
                Nothing -> raise "ValueError" ("unknown " <> observeLabel <> " Engine profile observation " <> pythonStrRepr request.name)
                Just fs -> pure fs
              unless (request.payload == Null || emptyPayload request.payload) $
                raise "ValueError" (observeLabel <> " Engine profile observations do not accept parameters")
              select fields <$> ioScenario (state g current)
          , dropGeneration = release drops
          , closeGeneration = release closes
          , resourceUsage = Nothing
          }
  pure RetryProfile {kind, profile, attempts, claimChecks, failuresDelivered, drops, closes, acceptedResults, terminalReports}

-- ---------------------------------------------------------------------------
-- Checkers

intOf :: Text -> Json -> Integer
intOf key value = maybe 0 id (lookupInt key value)

withoutEpoch :: Json -> Json
withoutEpoch = \case
  Object members -> Object [(k, v) | (k, v) <- members, k /= "epoch"]
  other -> other

-- | @RetryAuthorityChecker.check@.
retryVerdict :: Json -> (Bool, [(Text, Json)])
retryVerdict value =
  let attempts = listOf "attempts" value
      failures = intOf "failures_delivered" value
      records = listOf "record_types" value
      requested = countOf "ActivityRequested" records
      activityFailed = countOf "ActivityFailed" records
      firingFailed = countOf "FiringFailed" records
      projected = countOf "FiringCompleted" records
      expectedEpochs = map Int [1 .. toInteger (length attempts)]
      epochs = map (member "epoch") attempts
      logical = map withoutEpoch attempts
      invocationStable = case logical of
        [] -> True
        first : _ -> all (== first) logical
      acceptedTerminalLimit = if failures >= 2 then 1 else 0 :: Int
      passed =
        requested <= 1
          && length attempts <= 2
          && epochs == expectedEpochs
          && invocationStable
          && 0 <= failures
          && failures <= toInteger (length attempts)
          && activityFailed <= acceptedTerminalLimit
          && firingFailed == activityFailed
          && projected == 0
   in ( passed
      , [ ("accepted_terminal_limit", jsonInt acceptedTerminalLimit)
        , ("activity_failed", jsonInt activityFailed)
        , ("activity_requested", jsonInt requested)
        , ("attempt_epochs", Array epochs)
        , ("failures_delivered", Int failures)
        , ("firing_completed", jsonInt projected)
        , ("firing_failed", jsonInt firingFailed)
        , ("invocation_stable", Bool invocationStable)
        ]
      )

-- | @RetryAuthorityChecker@.
retryAuthorityChecker :: Checker
retryAuthorityChecker =
  Checker
    { identity = checkerIdentity
    , request = ObservationRequest {name = "engine.retry-authority", payload = Object []}
    , check = pureCheck $ \o -> let (passed, detail) = retryVerdict o.value in Right CheckResult {passed, detail = Object detail}
    }

-- | @DelayedRetryAuthorityChecker@.
delayedRetryAuthorityChecker :: Checker
delayedRetryAuthorityChecker =
  Checker
    { identity = delayedRetryCheckerIdentity
    , request = ObservationRequest {name = "engine.delayed-retry-authority", payload = Object []}
    , check = pureCheck $ \o -> do
        let (authority, detail) = retryVerdict o.value
            claimChecks = listOf "claim_checks" o.value
            attempts = listOf "attempts" o.value
            current = intOf "current_instant" o.value
            check' available epoch instant = Object [("available", Bool available), ("epoch", epoch), ("instant", Int instant)]
            expected =
              [ check' True (Int 1) 0
              , check' False Null (retryAvailableInstant - 1)
              , check' True (Int 2) retryAvailableInstant
              ]
            exactPrefix = length claimChecks <= length expected && claimChecks == take (length claimChecks) expected
            noEarlyRetry = length attempts < 2 || current >= retryAvailableInstant
        Right
          CheckResult
            { passed = authority && exactPrefix && noEarlyRetry
            , detail =
                Object
                  ( detail
                      <> [ ("claim_checks", Array claimChecks)
                         , ("current_instant", Int current)
                         , ("exact_deadline", Int retryAvailableInstant)
                         , ("exact_prefix", Bool exactPrefix)
                         , ("no_early_retry", Bool noEarlyRetry)
                         ]
                  )
            }
    }

-- | @TerminalAuthorityChecker@.
terminalAuthorityChecker :: Checker
terminalAuthorityChecker =
  Checker
    { identity = terminalCheckerIdentity
    , request = ObservationRequest {name = "engine.local-terminal-authority", payload = Object []}
    , check = pureCheck $ \o -> do
        let value = o.value
            reports = listOf "terminal_reports" value
            acceptedResults = listOf "accepted_results" value
            attempts = listOf "attempts" value
            records = listOf "record_types" value
            bridge = member "bridge" value
            marking = listOf "marking" value
            results = map (member "result") reports
            authority = take 1 results
            expectedDispositions =
              [ String $
                  if i == (0 :: Int)
                    then "applied"
                    else if Just result == safeHead authority then "idempotent" else "refused_expected"
              | (i, result) <- zip [0 ..] results
              ]
            reportedDispositions = map (member "disposition") reports
            requested = countOf "ActivityRequested" records
            completed = countOf "ActivityCompleted" records
            firingCompleted = countOf "FiringCompleted" records
            activityFailed = countOf "ActivityFailed" records
            firingFailed = countOf "FiringFailed" records
            attemptEpochs = map (member "epoch") attempts
            projectedResults =
              [ member "data" tok
              | p <- marking
              , member "place" p == String "done"
              , tok <- listOf "tokens" p
              ]
            terminalLimit = if null authority then 0 else 1
            expectedProjection = if firingCompleted > 0 then authority else []
            passed =
              requested <= 1
                && attemptEpochs `elem` [[], [Int 1]]
                && reportedDispositions == expectedDispositions
                && acceptedResults == authority
                && completed <= terminalLimit
                && firingCompleted == completed
                && activityFailed == 0
                && firingFailed == 0
                && member "projected" bridge == jsonInt firingCompleted
                && projectedResults == expectedProjection
        Right
          CheckResult
            { passed
            , detail =
                Object
                  [ ("accepted_results", Array acceptedResults)
                  , ("activity_completed", jsonInt completed)
                  , ("activity_failed", jsonInt activityFailed)
                  , ("activity_requested", jsonInt requested)
                  , ("attempt_epochs", Array attemptEpochs)
                  , ("expected_dispositions", Array expectedDispositions)
                  , ("firing_completed", jsonInt firingCompleted)
                  , ("firing_failed", jsonInt firingFailed)
                  , ("projected_results", Array projectedResults)
                  , ("reported_dispositions", Array reportedDispositions)
                  , ("terminal_limit", jsonInt terminalLimit)
                  ]
            }
    }
  where
    safeHead = \case
      x : _ -> Just x
      [] -> Nothing

-- ---------------------------------------------------------------------------
-- Stories

recordsOf :: Observation -> [Json]
recordsOf o = case memberOf "record_types" o of
  Array xs -> xs
  _ -> []

hasRecord :: Text -> Observation -> Bool
hasRecord name o = String name `elem` recordsOf o

attemptOf :: ApplyResult -> Json
attemptOf result = member "attempt" result.value

bridgeIs :: Int -> Int -> Observation -> Bool
bridgeIs p pr o = memberOf "bridge" o == Object [("prepared", jsonInt p), ("projected", jsonInt pr)]

epochsOf :: Observation -> [Json]
epochsOf o = case memberOf "attempts" o of
  Array xs -> map (member "epoch") xs
  _ -> []

failPayload :: Integer -> Text -> Json
failPayload n e = Object [("attempt", Int n), ("error", String e)]

-- | @execute_retry_story@: the authoring body.
executeRetryStory :: WorldT IO RetryGeneration ()
executeRetryStory = do
  timeline <- World.timeline
  requested <- Timeline.runUntil timeline "activity-requested" (hasRecord "ActivityRequested")
  ensure (bridgeIs 1 0 requested) "requested bridge"
  ensure (memberOf "attempts" requested == Array []) "requested attempts"
  firstClaim <- Timeline.command timeline "worker.claim" (Object [])
  let first = attemptOf firstClaim
  ensure (member "epoch" first == Int 1) "first epoch"
  _ <- Timeline.command timeline "worker.fail" (failPayload 1 "temporary-1")
  Timeline.crash timeline "retry_epoch_1_durable"
  _ <- World.restart
  timeline' <- World.timeline
  recovered <- Timeline.runUntil timeline' "retry-recovered" (\o -> memberOf "drives" o == Int 1)
  ensure (bridgeIs 0 0 recovered) "recovered bridge"
  ensure (memberOf "failures_delivered" recovered == Int 1) "recovered failures"
  ensure (countOf "ActivityRequested" (recordsOf recovered) == 1) "recovered request"
  ensure (not (hasRecord "ActivityFailed" recovered)) "recovered failure"
  secondClaim <- Timeline.command timeline' "worker.claim" (Object [])
  let second = attemptOf secondClaim
  ensure (member "epoch" second == Int 2) "second epoch"
  ensure (withoutEpoch second == withoutEpoch first) "stable invocation"
  claimed <- Timeline.observe timeline' "retry-claimed"
  ensure (epochsOf claimed == [Int 1, Int 2]) "claimed epochs"
  _ <- Timeline.command timeline' "worker.fail" (failPayload 2 "temporary-2")
  Timeline.beginFair timeline'
  exhausted <- Timeline.runUntil timeline' "retry-exhausted" (\o -> memberOf "status" o == String "poisoned")
  let records = recordsOf exhausted
  ensure (countOf "ActivityFailed" records == 1 && countOf "FiringFailed" records == 1) "exhausted failures"
  ensure (String "FiringCompleted" `notElem` records) "exhausted projection"
  ensure (bridgeIs 0 0 exhausted) "exhausted bridge"
  Timeline.finish timeline' Quarantined

-- | @execute_delayed_retry_story@: the authoring body.
executeDelayedRetryStory :: WorldT IO RetryGeneration ()
executeDelayedRetryStory = do
  timeline <- World.timeline
  _ <- Timeline.runUntil timeline "activity-requested" (hasRecord "ActivityRequested")
  firstClaim <- Timeline.command timeline "worker.claim" (Object [])
  let first = attemptOf firstClaim
  ensure (member "epoch" first == Int 1) "first epoch"
  ensure (member "initial_interval" (member "policy" first) == Int retryAvailableInstant) "first policy"
  _ <- Timeline.command timeline "worker.fail" (failPayload 1 "temporary-1")
  Timeline.crash timeline "delayed_retry_epoch_1_durable"
  _ <- World.restart
  timeline' <- World.timeline
  recovered <- Timeline.runUntil timeline' "delayed-retry-recovered" (\o -> memberOf "drives" o == Int 1)
  ensure (memberOf "current_instant" recovered == Int 0) "recovered instant"
  ensure (bridgeIs 0 0 recovered) "recovered bridge"
  let lastCheck o = case memberOf "claim_checks" o of
        Array xs@(_ : _) -> last xs
        _ -> Null
  before <-
    Timeline.runUntil
      timeline'
      "delayed-retry-before-available"
      (\o -> member "instant" (lastCheck o) == Int (retryAvailableInstant - 1))
  ensure (memberOf "current_instant" before == Int (retryAvailableInstant - 1)) "before instant"
  ensure
    ( lastCheck before
        == Object [("available", Bool False), ("epoch", Null), ("instant", Int (retryAvailableInstant - 1))]
    )
    "before check"
  ensure (epochsOf before == [Int 1]) "before epochs"
  available <-
    Timeline.runUntil
      timeline'
      "delayed-retry-available"
      (\o -> length (epochsOf o) == 2)
  ensure (memberOf "current_instant" available == Int retryAvailableInstant) "available instant"
  ensure (epochsOf available == [Int 1, Int 2]) "available epochs"
  case memberOf "attempts" available of
    Array [a, b] -> ensure (withoutEpoch a == withoutEpoch b) "stable invocation"
    _ -> ensure False "available attempts"
  _ <- Timeline.command timeline' "worker.fail" (failPayload 2 "temporary-2")
  Timeline.beginFair timeline'
  terminal <- Timeline.runUntil timeline' "delayed-retry-terminal" (\o -> memberOf "status" o == String "poisoned")
  let records = recordsOf terminal
  ensure (countOf "ActivityFailed" records == 1 && countOf "FiringFailed" records == 1) "terminal failures"
  ensure (bridgeIs 0 0 terminal) "terminal bridge"
  Timeline.finish timeline' Quarantined

-- | @execute_terminal_story@: the authoring body.
executeTerminalStory :: WorldT IO RetryGeneration ()
executeTerminalStory = do
  timeline <- World.timeline
  requested <- Timeline.runUntil timeline "local-terminal-requested" (hasRecord "ActivityRequested")
  ensure (bridgeIs 1 0 requested) "requested bridge"
  claim <- Timeline.command timeline "worker.claim" (Object [])
  ensure (member "epoch" (attemptOf claim) == Int 1) "claim epoch"
  let terminal = Object [("value", Int 6)]
  accepted <- Timeline.command timeline "worker.complete" (Object [("result", terminal)])
  duplicate <- Timeline.command timeline "worker.complete" (Object [("result", terminal)])
  conflict <- Timeline.command timeline "worker.complete" (Object [("result", Object [("value", Int 7)])])
  ensure (accepted.disposition == Applied) "accepted disposition"
  ensure (duplicate.disposition == Idempotent) "duplicate disposition"
  ensure (conflict.disposition == RefusedExpected) "conflict disposition"
  durable <- Timeline.observe timeline "local-terminal-durable"
  ensure (memberOf "accepted_results" durable == Array [terminal]) "durable results"
  ensure (not (hasRecord "ActivityCompleted" durable)) "durable records"
  ensure (bridgeIs 1 0 durable) "durable bridge"
  Timeline.crash timeline "local_terminal_durable_before_collect"
  _ <- World.restart
  timeline' <- World.timeline
  Timeline.beginFair timeline'
  converged <- Timeline.runUntil timeline' "local-terminal-converged" (\o -> memberOf "status" o == String "terminated")
  let records = recordsOf converged
  ensure (countOf "ActivityCompleted" records == 1 && countOf "FiringCompleted" records == 1) "converged records"
  ensure (bridgeIs 0 1 converged) "converged bridge"
  ensure
    ( memberOf "marking" converged
        == Array [Object [("place", String "done"), ("tokens", Array [Object [("color", String "Done"), ("data", terminal)]])]]
    )
    "converged marking"
  Timeline.finish timeline' Converged

author :: SomeBudget -> Checker -> RetryProfile -> WorldT IO RetryGeneration () -> Text -> IO (Either DstFailure AnyArtifact)
author budget checker p body name =
  World.withWorld
    WorldConfig {profile = p.profile, budget, checkers = [checker], seed = Nothing, progress = Nothing}
    (body >> World.artifact name)

-- | @build_retry_artifact(history_path, dispatch_path)@.
buildRetryArtifact :: FilePath -> FilePath -> IO (Either DstFailure AnyArtifact)
buildRetryArtifact historyPath dispatchPath = do
  p <- retryEngineProfile historyPath dispatchPath
  author worldBudget retryAuthorityChecker p executeRetryStory scenarioId

-- | @build_delayed_retry_artifact(history_path, dispatch_path)@.
buildDelayedRetryArtifact :: FilePath -> FilePath -> IO (Either DstFailure AnyArtifact)
buildDelayedRetryArtifact historyPath dispatchPath = do
  p <- delayedRetryEngineProfile historyPath dispatchPath
  author delayedRetryWorldBudget delayedRetryAuthorityChecker p executeDelayedRetryStory delayedRetryScenarioId

-- | @build_terminal_artifact(history_path, dispatch_path)@.
buildTerminalArtifact :: FilePath -> FilePath -> IO (Either DstFailure AnyArtifact)
buildTerminalArtifact historyPath dispatchPath = do
  p <- terminalEngineProfile historyPath dispatchPath
  author worldBudget terminalAuthorityChecker p executeTerminalStory terminalScenarioId
