{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The public-Engine projection-recovery world: a port of the reference's
-- @tests/dst/engine_world.py@ (profiles, checkers, and executable stories).
--
-- Every profile here drives the real Haskell Engine through its public
-- doors, over a JSONL History file and an in-memory Dispatch, exactly as the
-- reference's @EngineProfile@ family drives the Python Engine. The
-- reference's subclasses become 'Base' values: the overridable protected
-- methods (@_history@, @_dispatch@, @_bridge@, @_configure_faults@,
-- @_observation_state@, …) are fields, and a subclass that overrides a public
-- door updates the 'Profile' record built by 'baseProfile'.
module Petrus.Testing.Dst.Engine.Projection
  ( -- * Constants
    instanceId
  , legacyScenarioId
  , scenarioId
  , seededScenarioId
  , scenarioSeed
  , historyRefusalScenarioId
  , historyAckLossScenarioId
  , dispatchRefusalScenarioId
  , invariantFailureScenarioId
  , budgetFailureScenarioId
  , resourceScenarioId
  , resourceBudgetFailureScenarioId
  , worldBudget
  , resourceWorldBudget
  , applicationNet
    -- * Identities
  , profileIdentity
  , resourceProfileIdentity
  , historyRefusalProfileIdentity
  , historyAckLossProfileIdentity
  , dispatchRefusalProfileIdentity
  , checkerIdentity
  , commitAuthorityCheckerIdentity
  , acceptedCommitAuthorityCheckerIdentity
  , dispatchAuthorityCheckerIdentity
  , terminalRefusalCheckerIdentity
    -- * Profiles
  , Generation (..)
  , Bridge (..)
  , newBridge
  , bridged
  , EngineProfile (..)
  , Base (..)
  , newBase
  , baseProfile
  , baseObservationFields
  , engineProfile
  , resourceBoundedEngineProfile
  , historyRefusalEngineProfile
  , historyAckLossEngineProfile
  , dispatchRefusalEngineProfile
  , baseState
  , scheduledDrive
    -- * Checkers
  , engineHistoryChecker
  , commitAuthorityChecker
  , acceptedCommitAuthorityChecker
  , dispatchAuthorityChecker
  , terminalRefusalChecker
    -- * Stories
  , executeProjectionStory
  , buildProjectionArtifact
  , buildSeededProjectionArtifact
  , executeResourceBoundedStory
  , buildResourceBoundedArtifact
  , buildResourceBudgetFailureArtifact
  , executeHistoryRefusalStory
  , buildHistoryRefusalArtifact
  , executeHistoryAckLossStory
  , buildHistoryAckLossArtifact
  , executeDispatchRefusalStory
  , buildDispatchRefusalArtifact
  , buildInvariantFailureArtifact
  , buildBudgetFailureArtifact
  , authorArtifact
  ) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM, unless, when)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString qualified as BS
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (invocation)
import Petrus.Engine (Engine)
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.Binding (handlerTokens)
import Petrus.Impetus.History.Records (Record (..))
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.Instance (FiringOutcome (..))
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (Dispatch (..))
import Petrus.Motus.Dispatch.InMemory (InMemoryDispatch, completeOccurrence, inMemoryDispatch, newInMemoryDispatch, pending)
import Petrus.Testing.Dst
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Testing.Dst.Engine.Bridge (Bridged (..), withBridge)
import Petrus.Testing.Dst.Engine.Common
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World
import System.Directory (doesFileExist, getFileSize)

-- ---------------------------------------------------------------------------
-- Constants

input, done, project :: NetPath
input = path "input"
done = path "done"
project = path "project"

instanceId, legacyScenarioId, scenarioId, seededScenarioId :: Text
instanceId = "dst-world-projection-recovery"
legacyScenarioId = "projection-crash-recovery-world-v1"
scenarioId = "projection-crash-recovery-world-v3"
seededScenarioId = "seeded-projection-crash-recovery-world-v3"

scenarioSeed :: Integer
scenarioSeed = 1729

historyRefusalScenarioId, historyAckLossScenarioId, dispatchRefusalScenarioId :: Text
historyRefusalScenarioId = "history-refusal-crash-recovery-world-v3"
historyAckLossScenarioId = "history-ack-loss-recovery-world-v3"
dispatchRefusalScenarioId = "dispatch-refusal-crash-recovery-world-v3"

invariantFailureScenarioId, budgetFailureScenarioId, resourceScenarioId, resourceBudgetFailureScenarioId :: Text
invariantFailureScenarioId = "terminal-checker-failure-world-v2"
budgetFailureScenarioId = "action-budget-exhaustion-world-v2"
resourceScenarioId = "resource-bounded-recovery-world-v4"
resourceBudgetFailureScenarioId = "history-record-budget-exhaustion-world-v4"

profileIdentity :: ProfileIdentity
profileIdentity =
  Identity
    { name = "petrus.engine.projection-recovery"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("commands", strs ["engine.complete", "engine.drive"])
              , ("cut", String "activity_terminal_frozen")
              , ("instance", String instanceId)
              , ( "net"
                , Object [("activity", String "calculate"), ("places", strs ["done", "input"]), ("transition", String "project")]
                )
              , ("observations", strs ["activity-requested", "engine.safety", "projection-refused", "terminal"])
              ]
          )
    }

resourceProfileIdentity :: ProfileIdentity
resourceProfileIdentity =
  Identity
    { name = "petrus.engine.resource-bounded-recovery"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("commands", strs ["engine.complete", "engine.drive"])
              , ("instance", String instanceId)
              , ("observations", strs ["activity-requested", "engine.safety", "terminal"])
              , ( "resources"
                , strs
                    [ "pending.dispatch"
                    , "pending.in_flight"
                    , "retained.history_bytes"
                    , "retained.history_records"
                    , "retained.marking_bytes"
                    , "retained.marking_tokens"
                    ]
                )
              ]
          )
    }

historyRefusalProfileIdentity :: ProfileIdentity
historyRefusalProfileIdentity =
  Identity
    { name = "petrus.engine.history-refusal-recovery"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("commands", strs ["engine.complete", "engine.drive"])
              , ( "fault"
                , Object
                    [ ("disposition", String "refuse")
                    , ("name", String "history.refuse")
                    , ("target", String "activity_terminal_frozen")
                    ]
                )
              , ("instance", String instanceId)
              , ( "observations"
                , strs
                    [ "activity-requested"
                    , "engine.commit-authority"
                    , "engine.safety"
                    , "recovered-request"
                    , "semantic-batch-refused"
                    , "terminal"
                    ]
                )
              , ("pending_invocation", strs ["activity", "correlation", "idempotency", "input", "occurrence", "policy"])
              ]
          )
    }

historyAckLossProfileIdentity :: ProfileIdentity
historyAckLossProfileIdentity =
  Identity
    { name = "petrus.engine.history-ack-loss-recovery"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("commands", strs ["engine.complete", "engine.drive"])
              , ( "fault"
                , Object
                    [ ("disposition", String "raise")
                    , ("name", String "history.lose-ack")
                    , ("target", String "activity_terminal_frozen")
                    ]
                )
              , ("instance", String instanceId)
              , ( "observations"
                , strs ["activity-requested", "engine.accepted-commit-authority", "terminal-ack-lost", "terminal-recovered"]
                )
              ]
          )
    }

dispatchRefusalProfileIdentity :: ProfileIdentity
dispatchRefusalProfileIdentity =
  Identity
    { name = "petrus.engine.dispatch-refusal-recovery"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("commands", strs ["engine.complete", "engine.drive"])
              , ( "fault"
                , Object
                    [ ("disposition", String "refuse")
                    , ("name", String "dispatch.refuse")
                    , ("target", String "activity_requested")
                    ]
                )
              , ("instance", String instanceId)
              , ("observations", strs ["dispatch-refused", "dispatch-recovered", "engine.dispatch-authority", "terminal"])
              , ("property", String "one frozen invocation is redispatched without re-preparation")
              ]
          )
    }

checkerId :: Text -> Json -> CheckerIdentity
checkerId name definition = Identity {name, version = 1, digest = digestOf definition}

checkerIdentity :: CheckerIdentity
checkerIdentity =
  checkerId
    "petrus.engine.history-order"
    (Object [("properties", strs ["one activity request", "one frozen terminal", "terminal precedes projection"])])

commitAuthorityCheckerIdentity :: CheckerIdentity
commitAuthorityCheckerIdentity =
  checkerId
    "petrus.engine.commit-authority"
    ( Object
        [ ( "property"
          , String
              "activity terminals and projections never exceed authored terminal deliveries minus pre-commit history refusals"
          )
        ]
    )

acceptedCommitAuthorityCheckerIdentity :: CheckerIdentity
acceptedCommitAuthorityCheckerIdentity =
  checkerId
    "petrus.engine.accepted-commit-authority"
    ( Object
        [ ( "property"
          , String
              "a post-commit acknowledgement loss implies one durable terminal, which remains bounded by authored terminal delivery"
          )
        ]
    )

dispatchAuthorityCheckerIdentity :: CheckerIdentity
dispatchAuthorityCheckerIdentity =
  checkerId
    "petrus.engine.dispatch-authority"
    ( Object
        [ ( "properties"
          , strs
              [ "dispatch follows one canonical Activity request"
              , "refused custody leaves no accepted terminal authority"
              , "reload republishes the byte-equivalent invocation without prepare"
              ]
          )
        ]
    )

terminalRefusalCheckerIdentity :: CheckerIdentity
terminalRefusalCheckerIdentity =
  checkerId
    "petrus.engine.deliberate-terminal-refusal"
    (Object [("property", String "terminal firing is rejected to prove exact checker-failure replay")])

-- | @WORLD_BUDGET@.
worldBudget :: SomeBudget
worldBudget =
  SomeBudget
    Budget
      { actions = 32
      , queuedCommands = 8
      , timerAdvances = 0
      , logicalInstant = 0
      , reloads = 1
      , predicatePolls = 16
      , artifactBytes = 262144
      }

-- | @resource_world_budget(history_records=...)@.
resourceWorldBudget :: Integer -> SomeBudget
resourceWorldBudget historyRecords =
  SomeBudgetV4
    BudgetV4
      { limits =
          Budget
            { actions = 32
            , queuedCommands = 8
            , timerAdvances = 0
            , logicalInstant = 0
            , reloads = 1
            , predicatePolls = 16
            , artifactBytes = 262144
            }
      , profileResources =
          Map.fromList
            [ ("pending.dispatch", 4)
            , ("pending.in_flight", 4)
            , ("retained.history_bytes", 65536)
            , ("retained.history_records", historyRecords)
            , ("retained.marking_bytes", 8192)
            , ("retained.marking_tokens", 16)
            ]
      }

-- | @application_net()@.
applicationNet :: Net
applicationNet =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = [place input, place done]
        , transitions = [(transition project) {handler = Just (HandlerSymbol "bridge")}]
        , arcs = [arc input project, arc project done]
        , completion = Nothing
        , name = Just "dst-world-projection-recovery"
        }

-- ---------------------------------------------------------------------------
-- The bridge

-- | @ProjectionBridge@ (and @DispatchRefusalBridge@, through 'onPrepare').
data Bridge = Bridge
  { prepared :: IORef Int
  , projected :: IORef Int
  , projectionError :: IORef (Maybe Text)
  , onPrepare :: IO ()
  }

newBridge :: IO () -> IO Bridge
newBridge onPrepare = Bridge <$> newIORef 0 <*> newIORef 0 <*> newIORef Nothing <*> pure onPrepare

-- | The bridge's pure prepare/project pair, and the per-call effects of
-- the reference's bridge: counting, and reading its armed fault.
bridged :: Bridge -> Bridged
bridged bridge =
  Bridged
    { prepare = \b -> case bindingTokens b of
        t : _ -> Right (invocation "calculate" t.payload)
        [] -> Left "IndexError('tuple index out of range')"
    , project = \_ result -> Right (handlerTokens [(done, [Token (Just "Done") result])])
    , onPrepare = Right () <$ (modifyIORef' bridge.prepared (+ 1) >> bridge.onPrepare)
    , onProject = do
        modifyIORef' bridge.projected (+ 1)
        maybe (Right ()) (Left . runtimeErrorText) <$> readIORef bridge.projectionError
    }

-- ---------------------------------------------------------------------------
-- Generations and the base profile

-- | @EngineGeneration@.
data Generation = Generation
  { engine :: Engine
  , history :: HistoryStore
  , pool :: InMemoryDispatch
  , bridge :: Bridge
  , poisoned :: IORef Bool
  , dropped :: IORef Bool
  , historyFault :: Maybe (Text -> IO ())
  -- ^ @refuse_terminal@ / @lose_terminal_ack@ of a faulting History adapter.
  , dispatchFault :: Maybe (Text -> IO ())
  -- ^ @refuse_next@ of a faulting Dispatch adapter.
  }

-- | The class attributes and protected methods of one @EngineProfile@
-- subclass.
data Base = Base
  { identity :: ProfileIdentity
  , observationFields :: [(Text, [Text])]
  , historyPath :: FilePath
  , time :: WorldTime
  , drops :: IORef Int
  , closes :: IORef Int
  , makeHistory :: IO (HistoryStore, Maybe (Text -> IO ()))
  -- ^ @_history@.
  , makeDispatch :: IO (InMemoryDispatch, Dispatch, Maybe (Text -> IO ()))
  -- ^ @_dispatch@.
  , makeBridge :: IO Bridge
  -- ^ @_bridge@.
  , terminalReady :: IO ()
  -- ^ @_terminal_ready@.
  , configureFaults :: Generation -> Scenario IO [(Text, Text)]
  -- ^ @_configure_faults@: the expected @(class, str)@ errors.
  , extraState :: IO [(Text, Json)]
  -- ^ The members a subclass's @_observation_state@ adds.
  , faultCheck :: Fault -> Door IO Fault
  -- ^ @validate_fault@.
  }

-- | An Engine profile and its base (for state the stories inspect).
data EngineProfile = EngineProfile
  { base :: Base
  , profile :: Profile IO Generation
  }

baseObservationFields :: [(Text, [Text])]
baseObservationFields =
  [ ("activity-requested", ["frontier", "pending", "status"])
  , ("projection-refused", ["bridge", "frontier", "record_types", "status"])
  , ("terminal", ["bridge", "drops", "frontier", "marking", "record_types", "status"])
  ]

-- | @EngineProfile(history_path)@'s defaults.
newBase :: FilePath -> IO Base
newBase historyPath = do
  time <- newWorldTime
  drops <- newIORef 0
  closes <- newIORef 0
  pure
    Base
      { identity = profileIdentity
      , observationFields = baseObservationFields
      , historyPath
      , time
      , drops
      , closes
      , makeHistory = (,Nothing) <$> openJsonlHistoryStore historyPath
      , makeDispatch = do
          pool <- newInMemoryDispatch
          pure (pool, inMemoryDispatch pool, Nothing)
      , makeBridge = newBridge (pure ())
      , terminalReady = pure ()
      , configureFaults = projectionFaults
      , extraState = pure []
      , faultCheck = \f ->
          if f.name /= "projection.raise"
            || f.target /= "activity_terminal_frozen"
            || f.disposition /= Raise
            || not (messagePayload f.payload)
            then throwError (ProfileError "ValueError" "unsupported public-Engine profile fault")
            else pure f
      }

messagePayload :: Json -> Bool
messagePayload payload = exactKeys ["message"] payload && isString (member "message" payload)
  where
    isString = \case
      String _ -> True
      _ -> False

-- | The base @_configure_faults@: @projection.raise@ at
-- @activity_terminal_frozen@ arms the bridge's projection error.
projectionFaults :: Generation -> Scenario IO [(Text, Text)]
projectionFaults generation = do
  matched <- faults "activity_terminal_frozen"
  forM matched $ \f -> do
    when (f.name /= "projection.raise" || f.disposition /= Raise) $
      raise "ValueError" ("unsupported public-Engine profile fault " <> pythonStrRepr f.name)
    message <- faultMessage "projection.raise" f
    liftIO (writeIORef generation.bridge.projectionError (Just message))
    pure ("RuntimeError", message)

-- | The exact @{"message": str}@ payload of a fault.
faultMessage :: Text -> Fault -> Scenario IO Text
faultMessage label f = do
  unless (exactKeys ["message"] f.payload) $ raise "ValueError" (label <> " requires an exact message payload")
  case member "message" f.payload of
    String message -> pure message
    _ -> raise "ValueError" (label <> " message must be a string")

-- | @_scheduled(context, "engine.drive", {})@.
scheduledDrive :: ProfileIdentity -> Scenario IO ScheduledCommand
scheduledDrive identity = do
  at <- now
  pure ScheduledCommand {instant = at, command = Command {profile = identity, name = "engine.drive", payload = Object []}}

-- | The base @EngineProfile@ doors over one 'Base'.
baseProfile :: Base -> Profile IO Generation
baseProfile b =
  Profile
    { identity = b.identity
    , validate = \c -> case c.name of
        "engine.drive"
          | c.payload /= Object [] || not (isObject c.payload) ->
              throwError (ProfileError "ValueError" "engine.drive payload must be an empty object")
          | otherwise -> pure c
        "engine.complete"
          | not (exactKeys ["occurrence", "result"] c.payload) ->
              throwError (ProfileError "ValueError" "engine.complete requires exact occurrence and result fields")
          | not (isPositiveInt (member "occurrence" c.payload)) ->
              throwError (ProfileError "ValueError" "engine.complete occurrence must be a positive integer")
          | otherwise -> pure c
        other -> throwError (ProfileError "ValueError" ("unknown public-Engine profile command " <> pythonStrRepr other))
    , validateFault = b.faultCheck
    , create = do
        _ <- syncTime b.time
        generation <- ioScenario (open b Nothing)
        drive <- scheduledDrive b.identity
        pure GenerationStart {generation, scheduled = [drive]}
    , load = do
        _ <- syncTime b.time
        generation <- ioScenario (open b (Just ()))
        drive <- scheduledDrive b.identity
        pure GenerationStart {generation, scheduled = [drive]}
    , apply = baseApply b
    , observe = \generation request -> do
        _ <- syncTime b.time
        baseObserve b generation request
    , dropGeneration = \generation -> ioDoor $ do
        modifyIORef' b.drops (+ 1)
        writeIORef generation.dropped True
        Engine.close generation.engine
    , closeGeneration = \generation -> ioDoor $ do
        modifyIORef' b.closes (+ 1)
        Engine.close generation.engine
    , resourceUsage = Nothing
    }
  where
    isObject = \case
      Object _ -> True
      _ -> False

-- | Create (no argument) or load (an argument) one Engine generation.
open :: Base -> Maybe () -> IO Generation
open b mode = do
  (history, historyFault) <- b.makeHistory
  (pool, port, dispatchFault) <- b.makeDispatch
  bridge <- b.makeBridge
  let options = withBridge (bridged bridge) Engine.defaultEngineOptions {Engine.clock = Just (worldClock b.time)}
  engine <- case mode of
    Nothing ->
      Engine.create
        applicationNet
        instanceId
        history
        port
        options {Engine.marking = markingFromList [(input, [Token (Just "Input") (Int 3)])]}
    Just () -> Engine.load applicationNet instanceId history port options
  Generation engine history pool bridge <$> newIORef False <*> newIORef False <*> pure historyFault <*> pure dispatchFault

-- | The base @apply@.
baseApply :: Base -> Generation -> Command -> Scenario IO ApplyResult
baseApply b generation c = do
  _ <- syncTime b.time
  if c.name == "engine.complete"
    then do
      occurrence <- maybe (raise "TypeError" "occurrence") pure (lookupInt "occurrence" c.payload)
      frontier <- ioScenario $ do
        completeOccurrence generation.pool (fromInteger occurrence) (member "result" c.payload)
        b.terminalReady
        historyLength generation.history
      drive <- scheduledDrive b.identity
      pure ApplyResult {disposition = Applied, value = Object [("frontier", Int frontier)], scheduled = [drive]}
    else do
      expected <- b.configureFaults generation
      outcome <- liftIO (try (Engine.advance generation.engine))
      case outcome of
        Left (e :: SomeException) -> do
          let actual = pythonError e
          if actual `elem` expected
            then do
              frontier <- ioScenario $ do
                writeIORef generation.poisoned True
                historyLength generation.history
              pure
                ApplyResult
                  { disposition = RefusedExpected
                  , value = Object [("error", String (snd actual)), ("frontier", Int frontier)]
                  , scheduled = []
                  }
            else raise (fst actual) (snd actual)
        Right driven -> do
          (status, frontier, idle) <- ioScenario $ do
            current <- engineCurrent generation.engine
            frontier <- historyLength generation.history
            idle <- null <$> pending generation.pool
            pure (member "status" current, frontier, idle)
          scheduled <-
            if status `notElem` [String "completed", String "terminated"] && driven.ready && idle
              then (: []) <$> scheduledDrive b.identity
              else pure []
          pure
            ApplyResult
              { disposition = Applied
              , value =
                  Object
                    [ ("firings", Array [String (netPathText f.transition) | f <- driven.firings])
                    , ("frontier", Int frontier)
                    , ("ready", Bool driven.ready)
                    , ("status", status)
                    , ("waiting", Bool driven.waiting)
                    ]
              , scheduled
              }

-- | The base @observe@ (which also answers @engine.safety@).
baseObserve :: Base -> Generation -> ObservationRequest -> Scenario IO Json
baseObserve b generation request = do
  let fields = lookup request.name b.observationFields
  when (request.name /= "engine.safety" && null fields) $
    raise "ValueError" ("unknown public-Engine profile observation " <> pythonStrRepr request.name)
  unless (request.payload == Null || request.payload == Object []) $
    raise "ValueError" "public-Engine profile observations do not accept parameters"
  state <- ioScenario (baseState b generation)
  pure $
    if request.name == "engine.safety"
      then Object [("record_types", maybe Null id (lookup "record_types" state))]
      else select (maybe [] id fields) state

-- | The base @_observation_state@ plus the subclass's members.
baseState :: Base -> Generation -> IO [(Text, Json)]
baseState b generation = do
  types <- recordTypes generation.history
  frontier <- historyLength generation.history
  isPoisoned <- readIORef generation.poisoned
  (status, markingValue, inFlightValue) <-
    if isPoisoned
      then pure (String "poisoned", Null, Null)
      else do
        current <- engineCurrent generation.engine
        pure (member "status" current, member "marking" current, member "in_flight" current)
  prepared <- readIORef generation.bridge.prepared
  projected <- readIORef generation.bridge.projected
  drops <- readIORef b.drops
  waiting <- sortOn fst <$> pending generation.pool
  extra <- b.extraState
  pure $
    [ ("bridge", Object [("prepared", jsonInt prepared), ("projected", jsonInt projected)])
    , ("drops", jsonInt drops)
    , ("frontier", Int frontier)
    , ("in_flight", inFlightValue)
    , ("marking", markingValue)
    , ("pending", Array [jsonInt o | (o, _) <- waiting])
    , ("pending_invocations", Array [Object (invocationView o inv) | (o, inv) <- waiting])
    , ("record_types", strs types)
    , ("status", status)
    ]
      <> extra

-- | @EngineProfile(history_path)@.
engineProfile :: FilePath -> IO EngineProfile
engineProfile historyPath = do
  b <- newBase historyPath
  pure EngineProfile {base = b, profile = baseProfile b}

-- | @ResourceBoundedEngineProfile(history_path)@.
resourceBoundedEngineProfile :: FilePath -> IO EngineProfile
resourceBoundedEngineProfile historyPath = do
  b0 <- newBase historyPath
  let b =
        b0
          { identity = resourceProfileIdentity
          , faultCheck = \_ -> throwError (ProfileError "ValueError" "resource-bounded public-Engine profile does not accept faults")
          }
  pure
    EngineProfile
      { base = b
      , profile = (baseProfile b) {resourceUsage = Just (ioDoor . resourceGauges b)}
      }

-- | @ResourceBoundedEngineProfile.resource_usage(generation)@.
resourceGauges :: Base -> Maybe Generation -> IO ResourceUsage
resourceGauges b generation = do
  history <- maybe (openJsonlHistoryStore b.historyPath) (pure . (.history)) generation
  exists <- doesFileExist b.historyPath
  historyBytes <- if exists then getFileSize b.historyPath else pure 0
  (markingValue, inFlight, dispatchPending) <- case generation of
    Nothing -> pure (Array [], 0, 0)
    Just g -> do
      current <- engineCurrent g.engine
      waiting <- pending g.pool
      let inFlightCount = case member "in_flight" current of
            Array xs -> length xs
            _ -> 0
      pure (member "marking" current, inFlightCount, length waiting)
  records <- historyLength history
  markingBytes <- either (throwIO . PyException "ValueError") (pure . BS.length) (canonicalBytes markingValue)
  let markingTokens = case markingValue of
        Array entries -> sum [case member "tokens" e of Array ts -> length ts; _ -> 0 | e <- entries]
        _ -> 0
  pure $
    ResourceUsage $
      Map.fromList
        [ ("pending.dispatch", toInteger dispatchPending)
        , ("pending.in_flight", toInteger inFlight)
        , ("retained.history_bytes", historyBytes)
        , ("retained.history_records", records)
        , ("retained.marking_bytes", toInteger markingBytes)
        , ("retained.marking_tokens", toInteger markingTokens)
        ]

-- | A JSONL History whose single terminal append can be refused before (or
-- whose acknowledgement can be lost after) durable acceptance.
faultingHistory :: Bool -> FilePath -> IO () -> IO (HistoryStore, Maybe (Text -> IO ()))
faultingHistory afterAcceptance historyPath onFault = do
  delegate <- openJsonlHistoryStore historyPath
  armed <- newIORef Nothing
  let terminal = \case
        RActivityCompleted _ -> True
        RActivityFailed _ -> True
        _ -> False
      extend' = \case
        [record] | terminal record -> do
          pendingFault <- readIORef armed
          case pendingFault of
            Nothing -> delegate.extend [record]
            Just message -> do
              writeIORef armed Nothing
              when afterAcceptance (delegate.extend [record])
              onFault
              throwIO (PyException "OSError" message)
        batch -> delegate.extend batch
  pure (delegate {extend = extend'}, Just (writeIORef armed . Just))

-- | @HistoryRefusalEngineProfile(history_path)@.
historyRefusalEngineProfile :: FilePath -> IO EngineProfile
historyRefusalEngineProfile historyPath = do
  b0 <- newBase historyPath
  deliveries <- newIORef (0 :: Int)
  refusals <- newIORef (0 :: Int)
  let b =
        b0
          { identity = historyRefusalProfileIdentity
          , observationFields =
              [ ("activity-requested", ["frontier", "pending", "status", "pending_invocations"])
              , ("engine.commit-authority", ["record_types", "terminal_deliveries", "terminal_refusals"])
              , ( "recovered-request"
                , [ "bridge"
                  , "frontier"
                  , "pending"
                  , "pending_invocations"
                  , "record_types"
                  , "status"
                  , "terminal_deliveries"
                  , "terminal_refusals"
                  ]
                )
              , ("semantic-batch-refused", ["bridge", "frontier", "record_types", "status", "terminal_deliveries", "terminal_refusals"])
              , ("terminal", ["bridge", "drops", "frontier", "marking", "record_types", "status"])
              ]
          , makeHistory = faultingHistory False historyPath (modifyIORef' refusals (+ 1))
          , terminalReady = modifyIORef' deliveries (+ 1)
          , extraState = do
              d <- readIORef deliveries
              r <- readIORef refusals
              pure [("terminal_deliveries", jsonInt d), ("terminal_refusals", jsonInt r)]
          , faultCheck = messageFault "history.refuse" "activity_terminal_frozen" Refuse "unsupported history-refusal Engine profile fault"
          , configureFaults =
              armedFaults
                "activity_terminal_frozen"
                "history.refuse"
                Refuse
                "unsupported history-refusal Engine profile fault "
                (.historyFault)
                ("TypeError", "history-refusal Engine profile requires its faulting History adapter")
          }
  pure EngineProfile {base = b, profile = baseProfile b}

-- | @HistoryAckLossEngineProfile(history_path)@.
historyAckLossEngineProfile :: FilePath -> IO EngineProfile
historyAckLossEngineProfile historyPath = do
  b0 <- newBase historyPath
  deliveries <- newIORef (0 :: Int)
  losses <- newIORef (0 :: Int)
  let b =
        b0
          { identity = historyAckLossProfileIdentity
          , observationFields =
              [ ("activity-requested", ["frontier", "pending", "status"])
              , ("engine.accepted-commit-authority", ["record_types", "terminal_ack_losses", "terminal_deliveries"])
              , ("terminal-ack-lost", ["bridge", "frontier", "record_types", "status", "terminal_ack_losses", "terminal_deliveries"])
              , ("terminal-recovered", ["bridge", "drops", "frontier", "marking", "record_types", "status"])
              ]
          , makeHistory = faultingHistory True historyPath (modifyIORef' losses (+ 1))
          , terminalReady = modifyIORef' deliveries (+ 1)
          , extraState = do
              d <- readIORef deliveries
              l <- readIORef losses
              pure [("terminal_ack_losses", jsonInt l), ("terminal_deliveries", jsonInt d)]
          , faultCheck =
              messageFault "history.lose-ack" "activity_terminal_frozen" Raise "unsupported History acknowledgement-loss Engine profile fault"
          , configureFaults =
              armedFaults
                "activity_terminal_frozen"
                "history.lose-ack"
                Raise
                "unsupported History acknowledgement-loss fault "
                (.historyFault)
                ("TypeError", "History acknowledgement-loss profile requires its faulting adapter")
          }
  pure EngineProfile {base = b, profile = baseProfile b}

-- | A @validate_fault@ accepting one named fault with a message payload.
messageFault :: Text -> Text -> FaultDisposition -> Text -> Fault -> Door IO Fault
messageFault name target disposition refusal f
  | f.name /= name || f.target /= target || f.disposition /= disposition || not (messagePayload f.payload) =
      throwError (ProfileError "ValueError" refusal)
  | otherwise = pure f

-- | A @_configure_faults@ that arms an adapter with each matched fault's
-- message and expects @OSError(message)@.
armedFaults
  :: Text
  -> Text
  -> FaultDisposition
  -> Text
  -> (Generation -> Maybe (Text -> IO ()))
  -> (Text, Text)
  -> Generation
  -> Scenario IO [(Text, Text)]
armedFaults target name disposition unsupported adapter (missingClass, missingMessage) generation = do
  matched <- faults target
  forM matched $ \f -> do
    when (f.name /= name || f.disposition /= disposition) $ raise "ValueError" (unsupported <> pythonStrRepr f.name)
    message <- faultMessage name f
    case adapter generation of
      Nothing -> raise missingClass missingMessage
      Just arm -> liftIO (arm message)
    pure ("OSError", message)

-- | @RefusingInMemoryDispatch(attempts)@: one-shot refusal at the public
-- Dispatch acceptance door, recording every attempt.
refusingDispatch :: IORef [Json] -> IO (InMemoryDispatch, Dispatch, Maybe (Text -> IO ()))
refusingDispatch attempts = do
  pool <- newInMemoryDispatch
  refusal <- newIORef Nothing
  let delegate = inMemoryDispatch pool
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
  pure (pool, delegate {dispatch = dispatch'}, Just (writeIORef refusal . Just))

-- | @DispatchRefusalEngineProfile(history_path)@.
dispatchRefusalEngineProfile :: FilePath -> IO EngineProfile
dispatchRefusalEngineProfile historyPath = do
  b0 <- newBase historyPath
  attempts <- newIORef []
  prepareCalls <- newIORef (0 :: Int)
  let debug =
        [ "bridge"
        , "dispatch_attempts"
        , "frontier"
        , "marking"
        , "pending"
        , "pending_invocations"
        , "prepare_calls"
        , "record_types"
        , "status"
        ]
      b =
        b0
          { identity = dispatchRefusalProfileIdentity
          , observationFields =
              [ ("dispatch-refused", debug)
              , ("dispatch-recovered", debug)
              , ("engine.dispatch-authority", ["dispatch_attempts", "prepare_calls", "record_types"])
              , ("terminal", debug)
              ]
          , makeDispatch = refusingDispatch attempts
          , makeBridge = newBridge (modifyIORef' prepareCalls (+ 1))
          , extraState = do
              recorded <- readIORef attempts
              calls <- readIORef prepareCalls
              pure [("dispatch_attempts", Array recorded), ("prepare_calls", jsonInt calls)]
          , faultCheck = messageFault "dispatch.refuse" "activity_requested" Refuse "unsupported Dispatch-refusal Engine profile fault"
          , configureFaults =
              armedFaults
                "activity_requested"
                "dispatch.refuse"
                Refuse
                "unsupported Dispatch-refusal fault "
                (.dispatchFault)
                ("TypeError", "Dispatch-refusal profile requires its faulting adapter")
          }
      p = baseProfile b
  pure
    EngineProfile
      { base = b
      , profile = p {create = (\started -> GenerationStart {generation = started.generation, scheduled = []}) <$> p.create}
      }

-- ---------------------------------------------------------------------------
-- Checkers

intAt :: Text -> Json -> Integer
intAt key value = maybe 0 id (lookupInt key value)

listAt :: Text -> Json -> [Json]
listAt key value = case member key value of
  Array xs -> xs
  _ -> []

positions :: Text -> [Json] -> [Int]
positions name records = [i | (i, r) <- zip [0 ..] records, r == String name]

-- | @EngineHistoryChecker@.
engineHistoryChecker :: Checker
engineHistoryChecker =
  Checker
    { identity = checkerIdentity
    , request = ObservationRequest {name = "engine.safety", payload = Object []}
    , check = pureCheck $ \o -> do
        let records = listAt "record_types" o.value
            requested = positions "ActivityRequested" records
            completed = positions "ActivityCompleted" records
            projected = positions "FiringCompleted" records
            passed0 = length requested <= 1 && length completed <= 1
            passed = case (projected, completed) of
              (p : _, [c]) -> passed0 && c < p
              (_ : _, _) -> False
              ([], _) -> passed0
        Right
          CheckResult
            { passed
            , detail =
                Object
                  [ ("activity_completed", jsonInt (length completed))
                  , ("activity_requested", jsonInt (length requested))
                  , ("firing_completed", jsonInt (length projected))
                  ]
            }
    }

-- | @CommitAuthorityChecker@.
commitAuthorityChecker :: Checker
commitAuthorityChecker =
  Checker
    { identity = commitAuthorityCheckerIdentity
    , request = ObservationRequest {name = "engine.commit-authority", payload = Object []}
    , check = pureCheck $ \o -> do
        let records = listAt "record_types" o.value
            deliveries = intAt "terminal_deliveries" o.value
            refusals = intAt "terminal_refusals" o.value
            completed = toInteger (countOf "ActivityCompleted" records + countOf "ActivityFailed" records)
            projected = toInteger (countOf "FiringCompleted" records)
            limit = deliveries - refusals
            passed = 0 <= refusals && refusals <= deliveries && completed <= limit && projected <= completed && completed <= 1
        Right
          CheckResult
            { passed
            , detail =
                Object
                  [ ("accepted_terminal_limit", Int limit)
                  , ("activity_terminals", Int completed)
                  , ("authored_terminal_deliveries", Int deliveries)
                  , ("firing_completed", Int projected)
                  , ("history_refusals", Int refusals)
                  ]
            }
    }

-- | @AcceptedCommitAuthorityChecker@.
acceptedCommitAuthorityChecker :: Checker
acceptedCommitAuthorityChecker =
  Checker
    { identity = acceptedCommitAuthorityCheckerIdentity
    , request = ObservationRequest {name = "engine.accepted-commit-authority", payload = Object []}
    , check = pureCheck $ \o -> do
        let records = listAt "record_types" o.value
            deliveries = intAt "terminal_deliveries" o.value
            losses = intAt "terminal_ack_losses" o.value
            terminals = toInteger (countOf "ActivityCompleted" records + countOf "ActivityFailed" records)
            projected = toInteger (countOf "FiringCompleted" records)
            passed =
              0 <= losses && losses <= deliveries && deliveries <= 1 && losses <= terminals && terminals <= deliveries && projected <= terminals
        Right
          CheckResult
            { passed
            , detail =
                Object
                  [ ("durable_activity_terminals", Int terminals)
                  , ("firing_completed", Int projected)
                  , ("terminal_ack_losses", Int losses)
                  , ("terminal_deliveries", Int deliveries)
                  ]
            }
    }

-- | @DispatchAuthorityChecker@.
dispatchAuthorityChecker :: Checker
dispatchAuthorityChecker =
  Checker
    { identity = dispatchAuthorityCheckerIdentity
    , request = ObservationRequest {name = "engine.dispatch-authority", payload = Object []}
    , check = pureCheck $ \o -> do
        let attempts = listAt "dispatch_attempts" o.value
            prepareCalls = intAt "prepare_calls" o.value
            records = listAt "record_types" o.value
            requested = toInteger (countOf "ActivityRequested" records)
            completed = toInteger (countOf "ActivityCompleted" records + countOf "ActivityFailed" records)
            projected = toInteger (countOf "FiringCompleted" records)
            acceptances = [a | attempt <- attempts, Bool a <- [member "accepted" attempt]]
            views = [Object [(k, v) | (k, v) <- members, k /= "accepted"] | Object members <- attempts]
            stable = case views of
              [] -> True
              first : rest -> all (== first) rest
            limit = toInteger (length (filter id acceptances))
            passed =
              length attempts <= 2
                && acceptances == take (length acceptances) [False, True]
                && stable
                && requested <= 1
                && (null attempts || requested == 1)
                && prepareCalls <= 1
                && (requested == 0 || prepareCalls == 1)
                && completed <= limit
                && projected <= completed
                && completed <= 1
        Right
          CheckResult
            { passed
            , detail =
                Object
                  [ ("accepted_dispatches", Int limit)
                  , ("activity_requested", Int requested)
                  , ("activity_terminals", Int completed)
                  , ("dispatch_acceptances", Array (map Bool acceptances))
                  , ("firing_completed", Int projected)
                  , ("invocation_stable", Bool stable)
                  , ("prepare_calls", Int prepareCalls)
                  ]
            }
    }

-- | @TerminalRefusalChecker@.
terminalRefusalChecker :: Checker
terminalRefusalChecker =
  Checker
    { identity = terminalRefusalCheckerIdentity
    , request = ObservationRequest {name = "engine.safety", payload = Object []}
    , check = pureCheck $ \o -> do
        let terminal = String "FiringCompleted" `elem` listAt "record_types" o.value
        Right CheckResult {passed = not terminal, detail = Object [("terminal_firing", Bool terminal)]}
    }

-- ---------------------------------------------------------------------------
-- Stories

pendingIs :: [Integer] -> Observation -> Bool
pendingIs expected o = memberOf "pending" o == Array (map Int expected)

statusIs :: Text -> Observation -> Bool
statusIs expected o = memberOf "status" o == String expected

-- | The common terminal marking.
doneMarking :: Json -> Json
doneMarking result = Array [Object [("place", String "done"), ("tokens", Array [Object [("color", String "Done"), ("data", result)]])]]

-- | Run an authoring body in a fresh World and return the named artifact;
-- the World is always closed.
authorArtifact :: WorldConfig IO g -> WorldT IO g a -> Text -> IO (Either DstFailure AnyArtifact)
authorArtifact cfg body name = World.withWorld cfg (body >> World.artifact name)

-- | @execute_projection_story(history_path, seed=seed)@: the authoring
-- body; it returns the stale first-generation Timeline.
executeProjectionStory :: Maybe Integer -> WorldT IO Generation Timeline
executeProjectionStory seed = do
  timeline <- World.timeline
  requested <- Timeline.runUntil timeline "activity-requested" (pendingIs [1])
  ensure (memberOf "frontier" requested == Int 6) "requested frontier"
  (result, faultText) <- case seed of
    Nothing -> pure (3, "dst projection fault")
    Just _ -> do
      workload <- World.chooseIndex WorkloadChoice 3
      faultIndex <- World.chooseIndex FaultChoice 2
      identifier <- World.chooseIdentifier "scenario"
      reverseOrder <- World.chooseIndex EventOrderChoice 2
      let observations = (if reverseOrder /= 0 then reverse else id) ["activity-requested", "projection-refused"]
      mapM_ (Timeline.observe timeline) observations
      let label = ["projection", "bridge"] !! fromInteger faultIndex
      pure ([3, 5, 8] !! fromInteger workload, "dst " <> label <> " fault " <> identifier)
  Timeline.activateFault
    timeline
    (Timeline.fault "projection.raise" "activity_terminal_frozen")
      { Timeline.disposition = Raise
      , Timeline.payload = Object [("message", String faultText)]
      }
  _ <- Timeline.command timeline "engine.complete" (Object [("occurrence", Int 1), ("result", Object [("value", Int result)])])
  refused <- Timeline.runUntil timeline "projection-refused" (statusIs "poisoned")
  ensure (memberOf "frontier" refused == Int 7) "refused frontier"
  let stale = timeline
  Timeline.crash timeline "activity_terminal_frozen"
  _ <- World.restart
  timeline' <- World.timeline
  Timeline.beginFair timeline'
  terminal <- Timeline.runUntil timeline' "terminal" (statusIs "terminated")
  ensure (memberOf "frontier" terminal == Int 9) "terminal frontier"
  ensure (memberOf "marking" terminal == doneMarking (Object [("value", Int result)])) "terminal marking"
  Timeline.finish timeline' Converged
  pure stale

projectionConfig :: EngineProfile -> [Checker] -> Maybe Integer -> WorldConfig IO Generation
projectionConfig p checkers seed = WorldConfig {profile = p.profile, budget = worldBudget, checkers, seed, progress = Nothing}

-- | @build_projection_artifact(history_path)@.
buildProjectionArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildProjectionArtifact historyPath = do
  p <- engineProfile historyPath
  authorArtifact (projectionConfig p [engineHistoryChecker] Nothing) (executeProjectionStory Nothing) scenarioId

-- | @build_seeded_projection_artifact(history_path)@.
buildSeededProjectionArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildSeededProjectionArtifact historyPath = do
  p <- engineProfile historyPath
  authorArtifact
    (projectionConfig p [engineHistoryChecker] (Just scenarioSeed))
    (executeProjectionStory (Just scenarioSeed))
    seededScenarioId

-- | @execute_resource_bounded_story(history_path)@: the authoring body.
executeResourceBoundedStory :: WorldT IO Generation ()
executeResourceBoundedStory = do
  timeline <- World.timeline
  requested <- Timeline.runUntil timeline "activity-requested" (pendingIs [1])
  ensure (memberOf "frontier" requested == Int 6) "requested frontier"
  Timeline.crash timeline "activity_request_durable"
  _ <- World.restart
  timeline' <- World.timeline
  recovered <- Timeline.runUntil timeline' "activity-requested" (pendingIs [1])
  ensure (memberOf "frontier" recovered == Int 6) "recovered frontier"
  _ <- Timeline.command timeline' "engine.complete" (Object [("occurrence", Int 1), ("result", Object [("value", Int 3)])])
  Timeline.beginFair timeline'
  terminal <- Timeline.runUntil timeline' "terminal" (statusIs "terminated")
  ensure (memberOf "frontier" terminal == Int 9) "terminal frontier"
  Timeline.finish timeline' Converged

-- | @build_resource_bounded_artifact(history_path)@.
buildResourceBoundedArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildResourceBoundedArtifact historyPath = do
  p <- resourceBoundedEngineProfile historyPath
  authorArtifact
    WorldConfig {profile = p.profile, budget = resourceWorldBudget 16, checkers = [engineHistoryChecker], seed = Nothing, progress = Nothing}
    executeResourceBoundedStory
    resourceScenarioId

-- | @build_resource_budget_failure_artifact(history_path)@.
buildResourceBudgetFailureArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildResourceBudgetFailureArtifact historyPath = do
  p <- resourceBoundedEngineProfile historyPath
  authorArtifact
    WorldConfig {profile = p.profile, budget = resourceWorldBudget 5, checkers = [engineHistoryChecker], seed = Nothing, progress = Nothing}
    ( do
        timeline <- World.timeline
        outcome <- World.tryWorld (Timeline.runUntil timeline "activity-requested" (pendingIs [1]))
        case outcome of
          Left (BudgetExhausted _ _) -> pure ()
          Left other -> World.throwWorld other
          Right _ -> ensure False "the deliberate History-record resource budget did not exhaust"
    )
    resourceBudgetFailureScenarioId

-- | @execute_history_refusal_story(history_path)@: the authoring body.
executeHistoryRefusalStory :: WorldT IO Generation Timeline
executeHistoryRefusalStory = do
  timeline <- World.timeline
  requested <- Timeline.runUntil timeline "activity-requested" (pendingIs [1])
  ensure (memberOf "frontier" requested == Int 6) "requested frontier"
  let invocations = memberOf "pending_invocations" requested
  ensure (invocations == expectedInvocations) "requested invocations"
  Timeline.activateFault
    timeline
    (Timeline.fault "history.refuse" "activity_terminal_frozen")
      { Timeline.disposition = Refuse
      , Timeline.payload = Object [("message", String "dst terminal history refused")]
      }
  _ <- Timeline.command timeline "engine.complete" (Object [("occurrence", Int 1), ("result", Object [("value", Int 3)])])
  refused <- Timeline.runUntil timeline "semantic-batch-refused" (statusIs "poisoned")
  ensure (memberOf "frontier" refused == Int 6) "refused frontier"
  ensure (memberOf "terminal_deliveries" refused == Int 1 && memberOf "terminal_refusals" refused == Int 1) "refusal counts"
  ensure (String "ActivityCompleted" `notElem` listAt "record_types" refused.value) "no completion"
  ensure (atKey "projected" (memberOf "bridge" refused) == Int 0) "no projection"
  let stale = timeline
  Timeline.crash timeline "semantic_batch_refused"
  _ <- World.restart
  timeline' <- World.timeline
  recovered <- Timeline.runUntil timeline' "recovered-request" (pendingIs [1])
  ensure (memberOf "frontier" recovered == Int 6) "recovered frontier"
  ensure (memberOf "bridge" recovered == bridgeJson 0 0) "recovered bridge"
  ensure (memberOf "pending_invocations" recovered == invocations) "recovered invocations"
  _ <- Timeline.command timeline' "engine.complete" (Object [("occurrence", Int 1), ("result", Object [("value", Int 3)])])
  Timeline.beginFair timeline'
  terminal <- Timeline.runUntil timeline' "terminal" (statusIs "terminated")
  ensure (memberOf "frontier" terminal == Int 9) "terminal frontier"
  ensure (memberOf "bridge" terminal == bridgeJson 0 1) "terminal bridge"
  ensure (memberOf "marking" terminal == doneMarking (Object [("value", Int 3)])) "terminal marking"
  Timeline.finish timeline' Converged
  pure stale
  where
    expectedInvocations =
      Array
        [ Object
            [ ("activity", String "calculate")
            , ("correlation", String "occurrence-1")
            , ("idempotency", String "occurrence-1")
            , ("input", Int 3)
            , ("occurrence", Int 1)
            , ( "policy"
              , Object
                  [ ("attempts", Int 1)
                  , ("coefficient", Int 2)
                  , ("heartbeat_timeout", Int 30)
                  , ("initial_interval", Int 0)
                  , ("jitter", Int 0)
                  , ("max_interval", Int 60)
                  , ("schedule_to_close", Null)
                  , ("start_to_close", Null)
                  ]
              )
            ]
        ]

bridgeJson :: Integer -> Integer -> Json
bridgeJson prepared projected = Object [("prepared", Int prepared), ("projected", Int projected)]

-- | @build_history_refusal_artifact(history_path)@.
buildHistoryRefusalArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildHistoryRefusalArtifact historyPath = do
  p <- historyRefusalEngineProfile historyPath
  authorArtifact (projectionConfig p [commitAuthorityChecker] Nothing) executeHistoryRefusalStory historyRefusalScenarioId

-- | @execute_history_ack_loss_story(history_path)@: the authoring body.
executeHistoryAckLossStory :: WorldT IO Generation ()
executeHistoryAckLossStory = do
  timeline <- World.timeline
  requested <- Timeline.runUntil timeline "activity-requested" (pendingIs [1])
  ensure (memberOf "frontier" requested == Int 6) "requested frontier"
  Timeline.activateFault
    timeline
    (Timeline.fault "history.lose-ack" "activity_terminal_frozen")
      { Timeline.disposition = Raise
      , Timeline.payload = Object [("message", String "dst terminal acknowledgement lost")]
      }
  _ <- Timeline.command timeline "engine.complete" (Object [("occurrence", Int 1), ("result", Object [("value", Int 3)])])
  lost <- Timeline.runUntil timeline "terminal-ack-lost" (statusIs "poisoned")
  ensure (memberOf "frontier" lost == Int 7) "lost frontier"
  ensure (memberOf "terminal_ack_losses" lost == Int 1 && memberOf "terminal_deliveries" lost == Int 1) "loss counts"
  ensure (countOf "ActivityCompleted" (listAt "record_types" lost.value) == 1) "one completion"
  ensure (memberOf "bridge" lost == bridgeJson 1 0) "lost bridge"
  Timeline.crash timeline "terminal_commit_accepted_ack_lost"
  _ <- World.restart
  timeline' <- World.timeline
  Timeline.beginFair timeline'
  terminal <- Timeline.runUntil timeline' "terminal-recovered" (statusIs "terminated")
  ensure (memberOf "frontier" terminal == Int 9) "terminal frontier"
  ensure (memberOf "bridge" terminal == bridgeJson 0 1) "terminal bridge"
  ensure (memberOf "marking" terminal == doneMarking (Object [("value", Int 3)])) "terminal marking"
  Timeline.finish timeline' Converged

-- | @build_history_ack_loss_artifact(history_path)@.
buildHistoryAckLossArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildHistoryAckLossArtifact historyPath = do
  p <- historyAckLossEngineProfile historyPath
  authorArtifact (projectionConfig p [acceptedCommitAuthorityChecker] Nothing) executeHistoryAckLossStory historyAckLossScenarioId

-- | @execute_dispatch_refusal_story(history_path)@: the authoring body.
executeDispatchRefusalStory :: WorldT IO Generation ()
executeDispatchRefusalStory = do
  timeline <- World.timeline
  Timeline.activateFault
    timeline
    (Timeline.fault "dispatch.refuse" "activity_requested")
      { Timeline.disposition = Refuse
      , Timeline.payload = Object [("message", String "dst Dispatch acceptance refused")]
      }
  _ <- Timeline.command timeline "engine.drive" (Object [])
  refused <- Timeline.observe timeline "dispatch-refused"
  ensure (memberOf "frontier" refused == Int 6) "refused frontier"
  ensure (memberOf "pending" refused == Array []) "refused pending"
  ensure (memberOf "prepare_calls" refused == Int 1) "refused prepare calls"
  refusedAttempt <- case listAt "dispatch_attempts" refused.value of
    [attempt] -> pure attempt
    _ -> ensure False "one refused attempt" >> pure Null
  ensure (atKey "accepted" refusedAttempt == Bool False) "refused attempt"
  ensure (memberOf "status" refused == String "poisoned") "refused status"
  Timeline.crash timeline "activity_requested"
  _ <- World.restart
  timeline' <- World.timeline
  recovered <- Timeline.runUntil timeline' "dispatch-recovered" (pendingIs [1])
  ensure (memberOf "frontier" recovered == Int 6) "recovered frontier"
  ensure (memberOf "prepare_calls" recovered == Int 1) "recovered prepare calls"
  ensure (memberOf "bridge" recovered == bridgeJson 0 0) "recovered bridge"
  case listAt "dispatch_attempts" recovered.value of
    [Object first, Object second] -> do
      let strip = filter ((/= "accepted") . fst)
      ensure (Object second == Object (("accepted", Bool True) : strip first)) "redispatched invocation"
      ensure (memberOf "pending_invocations" recovered == Array [Object (strip second)]) "pending invocation"
    _ -> ensure False "two dispatch attempts"
  _ <- Timeline.command timeline' "engine.complete" (Object [("occurrence", Int 1), ("result", Object [("value", Int 3)])])
  Timeline.beginFair timeline'
  terminal <- Timeline.runUntil timeline' "terminal" (statusIs "terminated")
  ensure (memberOf "frontier" terminal == Int 9) "terminal frontier"
  ensure (memberOf "prepare_calls" terminal == Int 1) "terminal prepare calls"
  ensure (memberOf "marking" terminal == doneMarking (Object [("value", Int 3)])) "terminal marking"
  Timeline.finish timeline' Converged

-- | @build_dispatch_refusal_artifact(history_path)@.
buildDispatchRefusalArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildDispatchRefusalArtifact historyPath = do
  p <- dispatchRefusalEngineProfile historyPath
  authorArtifact (projectionConfig p [dispatchAuthorityChecker] Nothing) executeDispatchRefusalStory dispatchRefusalScenarioId

-- | @build_invariant_failure_artifact(history_path)@.
buildInvariantFailureArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildInvariantFailureArtifact historyPath = do
  p <- engineProfile historyPath
  authorArtifact
    (projectionConfig p [engineHistoryChecker, terminalRefusalChecker] Nothing)
    ( do
        timeline <- World.timeline
        _ <- Timeline.runUntil timeline "activity-requested" (pendingIs [1])
        _ <- Timeline.command timeline "engine.complete" (Object [("occurrence", Int 1), ("result", Object [("value", Int 3)])])
        outcome <- World.tryWorld World.step
        case outcome of
          Left (InvariantViolation _) -> pure ()
          Left other -> World.throwWorld other
          Right _ -> ensure False "the deliberate terminal checker did not reject the Engine boundary"
    )
    invariantFailureScenarioId

-- | @build_budget_failure_artifact(history_path)@.
buildBudgetFailureArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildBudgetFailureArtifact historyPath = do
  p <- engineProfile historyPath
  let budget =
        SomeBudget
          Budget
            { actions = 1
            , queuedCommands = 8
            , timerAdvances = 0
            , logicalInstant = 0
            , reloads = 0
            , predicatePolls = 1
            , artifactBytes = 262144
            }
  authorArtifact
    WorldConfig {profile = p.profile, budget, checkers = [], seed = Nothing, progress = Nothing}
    ( do
        timeline <- World.timeline
        _ <- World.step
        outcome <- World.tryWorld (Timeline.observe timeline "activity-requested")
        case outcome of
          Left (BudgetExhausted _ _) -> pure ()
          Left other -> World.throwWorld other
          Right _ -> ensure False "the deliberate action budget did not exhaust"
    )
    budgetFailureScenarioId
