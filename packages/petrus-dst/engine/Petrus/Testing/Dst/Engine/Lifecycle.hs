{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The lifecycle reset and late-terminal world: a port of the reference's
-- @tests/dst/lifecycle_world.py@. A scoped delivery requests an Activity,
-- a reset fences it, the process crashes, and the late terminal is
-- quarantined; the cancellation-refusal variant refuses the cancellation
-- instruction after the canonical reset and repairs it on fresh load.
module Petrus.Testing.Dst.Engine.Lifecycle
  ( instanceId
  , scenarioId
  , cancellationScenarioId
  , scopeName'
  , profileIdentity
  , checkerIdentity
  , cancellationProfileIdentity
  , cancellationCheckerIdentity
  , worldBudget
  , applicationNet
  , LifecycleGeneration (..)
  , LifecycleProfile (..)
  , lifecycleEngineProfile
  , lifecycleCancellationRefusalProfile
  , lifecycleAuthorityChecker
  , cancellationAuthorityChecker
  , executeLifecycleStory
  , buildLifecycleArtifact
  , executeLifecycleCancellationStory
  , buildLifecycleCancellationArtifact
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM, when)
import Control.Monad.Except (catchError, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (toList)
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (invocation)
import Petrus.Engine (DriveOutcome (..), Engine)
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.Binding (handlerTokens)
import Petrus.Impetus.History.Records
  ( ActivityTerminalQuarantined (..)
  , Record (..)
  , ScopeOpened (..)
  , ScopeReset (..)
  , recordName
  )
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.Instance (DeliveryScope (..), FiringOutcome (..))
import Petrus.Impetus.Petrinet
import Petrus.Impetus.Scope (scopeGeneration, scopeName)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (CancellationInstruction (..), Dispatch (..), dispositionText)
import Petrus.Motus.Dispatch.InMemory (InMemoryDispatch, completeOccurrence, inMemoryDispatch, newInMemoryDispatch, pending)
import Petrus.Testing.Dst hiding (dispositionText)
import Petrus.Testing.Dst.Engine.Bridge (Bridged (..), withBridge)
import Petrus.Testing.Dst.Engine.Common
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Testing.Dst.Timeline qualified as Timeline
import Petrus.Testing.Dst.World qualified as World

source, input, done, project :: NetPath
source = path "source"
input = path "input"
done = path "done"
project = path "project"

instanceId, scenarioId, cancellationScenarioId :: Text
instanceId = "dst-world-lifecycle-race"
scenarioId = "lifecycle-reset-late-terminal-world-v3"
cancellationScenarioId = "lifecycle-cancellation-refusal-world-v3"

-- | @SCOPE_NAME@.
scopeName' :: Text
scopeName' = "draft"

commandsDefinition :: Json
commandsDefinition =
  Object
    [ ("activity.complete", strs ["occurrence", "result"])
    , ("engine.drive", Array [])
    , ("scope.open", strs ["name"])
    , ("scope.reset", strs ["name"])
    , ("source.deliver", strs ["identity", "scope", "value"])
    ]

profileIdentity :: ProfileIdentity
profileIdentity =
  Identity
    { name = "petrus.engine.lifecycle-race"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("commands", commandsDefinition)
              , ("instance", String instanceId)
              , ( "net"
                , Object
                    [ ("activity", String "calculate")
                    , ("places", strs ["done", "input"])
                    , ("source", String "source")
                    , ("transition", String "project")
                    ]
                )
              , ( "observations"
                , strs
                    [ "activity-requested"
                    , "duplicate-acknowledged"
                    , "engine.lifecycle-authority"
                    , "recovered-reset"
                    , "reset-committed"
                    , "terminal-quarantined"
                    ]
                )
              ]
          )
    }

checkerIdentity :: CheckerIdentity
checkerIdentity =
  Identity
    { name = "petrus.engine.lifecycle-authority"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ( "properties"
                , strs
                    [ "active scope generation equals authored lifecycle authority"
                    , "canonical opens, resets, and quarantines do not exceed authored external facts"
                    , "cancelled activity terminals never become ordinary terminal or projection facts"
                    ]
                )
              ]
          )
    }

cancellationProfileIdentity :: ProfileIdentity
cancellationProfileIdentity =
  Identity
    { name = "petrus.engine.lifecycle-cancellation-refusal"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ("commands", commandsDefinition)
              , ( "fault"
                , Object
                    [ ("disposition", String "refuse")
                    , ("name", String "dispatch.refuse-cancellation")
                    , ("target", String "scope_fenced")
                    ]
                )
              , ("instance", String instanceId)
              , ( "observations"
                , strs ["cancellation-refused", "cancellation-repaired", "engine.cancellation-authority", "terminal-quarantined"]
                )
              ]
          )
    }

cancellationCheckerIdentity :: CheckerIdentity
cancellationCheckerIdentity =
  Identity
    { name = "petrus.engine.cancellation-authority"
    , version = 1
    , digest =
        digestOf
          ( Object
              [ ( "properties"
                , strs
                    [ "a canonical reset exists before cancellation is attempted"
                    , "fresh load repeats the byte-equivalent cancellation instruction"
                    , "the reset fence authorizes late-terminal quarantine independently of cancellation custody"
                    ]
                )
              ]
          )
    }

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

applicationNet :: Net
applicationNet =
  either (error . T.unpack) id $
    mkNet
      NetSpec
        { places = [place input, place done]
        , transitions = [transition source, (transition project) {handler = Just (HandlerSymbol "bridge")}]
        , arcs = [arc source input, arc input project, arc project done]
        , completion = Nothing
        , name = Just "dst-world-lifecycle-race"
        }

-- ---------------------------------------------------------------------------
-- The bridge

data Bridge = Bridge {prepared :: IORef Int, projected :: IORef Int}

bridged :: Bridge -> Bridged
bridged bridge =
  Bridged
    { prepare = \b -> case bindingTokens b of
        t : _ -> Right (invocation "calculate" t.payload)
        [] -> Left "IndexError('tuple index out of range')"
    , project = \_ result -> Right (handlerTokens [(done, [Token (Just "Done") result])])
    , onPrepare = Right () <$ modifyIORef' bridge.prepared (+ 1)
    , onProject = Right () <$ modifyIORef' bridge.projected (+ 1)
    }

-- ---------------------------------------------------------------------------
-- Profiles

-- | @LifecycleGeneration@.
data LifecycleGeneration = LifecycleGeneration
  { engine :: Engine
  , history :: HistoryStore
  , pool :: InMemoryDispatch
  , bridge :: Bridge
  , drives :: IORef Int
  , poisoned :: IORef Bool
  , refuseNext :: Maybe (Text -> IO ())
  }

-- | A lifecycle profile and its authored facts.
data LifecycleProfile = LifecycleProfile
  { profile :: Profile IO LifecycleGeneration
  , scopeGenerationRef :: IORef Integer
  , scopeOpens :: IORef Int
  , scopeResets :: IORef Int
  , sourceDeliveries :: IORef Int
  , terminalDeliveries :: IORef Int
  , cancellationAttempts :: IORef [Json]
  }

lifecycleFields :: [(Text, [Text])]
lifecycleFields =
  [ ("activity-requested", ["active_scopes", "bridge", "frontier", "pending", "record_types"])
  , ("duplicate-acknowledged", ["active_scopes", "bridge", "drives", "frontier", "quarantined_occurrences", "record_types"])
  , ( "engine.lifecycle-authority"
    , [ "active_scopes"
      , "authored_scope_generation"
      , "authored_scope_opens"
      , "authored_scope_resets"
      , "authored_source_deliveries"
      , "authored_terminal_deliveries"
      , "record_types"
      ]
    )
  , ("recovered-reset", ["active_scopes", "bridge", "drives", "frontier", "pending", "record_types"])
  , ("reset-committed", ["active_scopes", "bridge", "frontier", "pending", "record_types", "scope_resets"])
  , ("terminal-quarantined", ["active_scopes", "bridge", "drives", "frontier", "quarantined_occurrences", "record_types"])
  ]

cancellationFields :: [(Text, [Text])]
cancellationFields =
  [ ("activity-requested", maybe [] id (lookup "activity-requested" lifecycleFields))
  , ("cancellation-refused", debug)
  , ("cancellation-repaired", debug)
  , ("engine.cancellation-authority", maybe [] id (lookup "engine.lifecycle-authority" lifecycleFields) <> ["cancellation_attempts"])
  , ("terminal-quarantined", debug)
  ]
  where
    debug =
      [ "active_scopes"
      , "bridge"
      , "cancellation_attempts"
      , "drives"
      , "frontier"
      , "pending"
      , "poisoned"
      , "quarantined_occurrences"
      , "record_types"
      , "scope_resets"
      ]

-- | The detached cancellation-instruction view.
cancellationView :: CancellationInstruction -> [(Text, Json)]
cancellationView instruction = invocationView instruction.occurrence instruction.invocation <> [("history_position", jsonInt instruction.historyPosition)]

-- | @RefusingCancellationDispatch(attempts)@.
refusingCancellationDispatch :: IORef [Json] -> InMemoryDispatch -> IO (Dispatch, Text -> IO ())
refusingCancellationDispatch attempts pool = do
  refusal <- newIORef Nothing
  let delegate = inMemoryDispatch pool
      cancel' instruction = do
        let attempt = cancellationView instruction
        armed <- readIORef refusal
        case armed of
          Just message -> do
            writeIORef refusal Nothing
            modifyIORef' attempts (<> [Object (("accepted", Bool False) : ("disposition", Null) : attempt)])
            throwIO (PyException "OSError" message)
          Nothing -> case delegate.cancel of
            Nothing -> throwIO (PyException "TypeError" "the in-memory Dispatch has no cancellation contract")
            Just inner -> do
              disposition <- inner instruction
              modifyIORef' attempts (<> [Object (("accepted", Bool True) : ("disposition", String (dispositionText disposition)) : attempt)])
              pure disposition
  pure (delegate {cancel = Just cancel'}, writeIORef refusal . Just)

-- | The shared @LifecycleEngineProfile@ implementation; 'True' builds the
-- cancellation-refusal subclass.
newLifecycle :: Bool -> FilePath -> IO LifecycleProfile
newLifecycle refusing historyPath = do
  time <- newWorldTime
  scopeGenerationRef <- newIORef 0
  scopeOpens <- newIORef (0 :: Int)
  scopeResets <- newIORef (0 :: Int)
  sourceDeliveries <- newIORef (0 :: Int)
  terminalDeliveries <- newIORef (0 :: Int)
  drops <- newIORef (0 :: Int)
  closes <- newIORef (0 :: Int)
  attempts <- newIORef []
  let identity = if refusing then cancellationProfileIdentity else profileIdentity
      fields = if refusing then cancellationFields else lifecycleFields
      scheduledNow name payload = do
        at <- now
        pure ScheduledCommand {instant = at, command = Command {profile = identity, name, payload}}
      open load = do
        history <- openJsonlHistoryStore historyPath
        pool <- newInMemoryDispatch
        (port, refuseNext) <-
          if refusing
            then (\(d, r) -> (d, Just r)) <$> refusingCancellationDispatch attempts pool
            else pure (inMemoryDispatch pool, Nothing)
        bridge <- Bridge <$> newIORef 0 <*> newIORef 0
        let options = withBridge (bridged bridge) Engine.defaultEngineOptions {Engine.clock = Just (worldClock time)}
        engine <-
          if load
            then Engine.load applicationNet instanceId history port options
            else Engine.create applicationNet instanceId history port options
        LifecycleGeneration engine history pool bridge <$> newIORef 0 <*> newIORef False <*> pure refuseNext
      state g = do
        records <- toList <$> g.history.snapshot
        isPoisoned <- readIORef g.poisoned
        active <-
          if isPoisoned
            then
              pure $
                foldl
                  ( \acc -> \case
                      RScopeOpened r -> upsert (scopeName r.scope) (scopeGeneration r.scope) acc
                      RScopeReset r -> upsert (scopeName r.opened) (scopeGeneration r.opened) acc
                      _ -> acc
                  )
                  []
                  records
            else do
              scopes <- Engine.activeScopes g.engine
              pure [(name, scopeGeneration s) | (name, s) <- Map.toAscList scopes]
        generation <- readIORef scopeGenerationRef
        opens <- readIORef scopeOpens
        resets <- readIORef scopeResets
        sources <- readIORef sourceDeliveries
        terminals <- readIORef terminalDeliveries
        prepared <- readIORef g.bridge.prepared
        projected <- readIORef g.bridge.projected
        d <- readIORef g.drives
        waiting <- sortOn fst <$> pending g.pool
        recorded <- readIORef attempts
        pure $
          [ ("active_scopes", Object [(name, Int gen) | (name, gen) <- active])
          , ("authored_scope_generation", Int generation)
          , ("authored_scope_opens", jsonInt opens)
          , ("authored_scope_resets", jsonInt resets)
          , ("authored_source_deliveries", jsonInt sources)
          , ("authored_terminal_deliveries", jsonInt terminals)
          , ("bridge", Object [("prepared", jsonInt prepared), ("projected", jsonInt projected)])
          , ("drives", jsonInt d)
          , ("frontier", jsonInt (length records))
          , ("pending", Array [jsonInt o | (o, _) <- waiting])
          , ("poisoned", Bool isPoisoned)
          , ("quarantined_occurrences", Array [jsonInt r.occurrence | RActivityTerminalQuarantined r <- records])
          , ("record_types", Array (map (String . recordName) records))
          , ( "scope_resets"
            , Array
                [ Object [("closed", Int (scopeGeneration r.closed)), ("opened", Int (scopeGeneration r.opened))]
                | RScopeReset r <- records
                ]
            )
          ]
            <> [("cancellation_attempts", Array recorded) | refusing]
      applied g extra scheduled = do
        frontier <- ioScenario (historyLength g.history)
        pure ApplyResult {disposition = Applied, value = Object (("frontier", Int frontier) : extra), scheduled}
      activeScope g name = do
        scopes <- ioScenario (Engine.activeScopes g.engine)
        maybe (raise "KeyError" (pythonStrRepr name)) pure (Map.lookup name scopes)
      baseApply g c = case c.name of
        "scope.open" -> do
          scope <- ioScenario (Engine.openScope g.engine scopeName')
          liftIO $ do
            modifyIORef' scopeOpens (+ 1)
            writeIORef scopeGenerationRef (scopeGeneration scope)
          applied g [("generation", Int (scopeGeneration scope))] []
        "source.deliver" -> do
          let scopeKey = case member "scope" c.payload of
                String s -> s
                _ -> ""
              identityText = case member "identity" c.payload of
                String s -> s
                _ -> ""
          scope <- activeScope g scopeKey
          _ <-
            ioScenario
              ( Engine.deliver
                  g.engine
                  source
                  [Token (Just "Input") (member "value" c.payload)]
                  identityText
                  (Just (ScopeGeneration scope))
              )
          liftIO (modifyIORef' sourceDeliveries (+ 1))
          drive <- scheduledNow "engine.drive" (Object [])
          applied g [] [drive]
        "scope.reset" -> do
          current <- activeScope g scopeName'
          opened <- ioScenario (Engine.resetScope g.engine current)
          liftIO $ do
            modifyIORef' scopeResets (+ 1)
            writeIORef scopeGenerationRef (scopeGeneration opened)
          applied g [("generation", Int (scopeGeneration opened))] []
        "activity.complete" -> do
          occurrence <- maybe (raise "TypeError" "occurrence") pure (lookupInt "occurrence" c.payload)
          ioScenario (completeOccurrence g.pool (fromInteger occurrence) (member "result" c.payload))
          liftIO (modifyIORef' terminalDeliveries (+ 1))
          drive <- scheduledNow "engine.drive" (Object [])
          applied g [] [drive]
        _ -> do
          (outcome, snapshot) <- ioScenario $ do
            outcome <- Engine.advance g.engine
            modifyIORef' g.drives (+ 1)
            snapshot <- engineCurrent g.engine
            pure (outcome, snapshot)
          applied
            g
            [ ("firings", Array [String (netPathText f.transition) | f <- outcome.firings])
            , ("ready", Bool outcome.ready)
            , ("status", member "status" snapshot)
            , ("waiting", Bool outcome.waiting)
            ]
            []
      refusingApply g c
        | c.name /= "scope.reset" = baseApply g c
        | otherwise = do
            matched <- faults "scope_fenced"
            expected <- forM matched $ \f -> do
              when (f.name /= "dispatch.refuse-cancellation" || not (isObject f.payload)) $
                raise "ValueError" ("unsupported lifecycle cancellation-refusal fault " <> pythonStrRepr f.name)
              message <- case member "message" f.payload of
                String m -> pure m
                _ -> raise "ValueError" "dispatch.refuse-cancellation message must be a string"
              case g.refuseNext of
                Nothing -> raise "TypeError" "cancellation-refusal profile requires its faulting Dispatch"
                Just arm -> liftIO (arm message)
              pure message
            let lastExpected = if null expected then Nothing else Just (last expected)
            outcome <- tryScenario (baseApply g c)
            case outcome of
              Right result -> pure result
              Left failure
                | failure.errorType == "OSError" && Just failure.errorMessage == lastExpected -> do
                    records <- ioScenario (toList <$> g.history.snapshot)
                    opened <- case reverse records of
                      RScopeReset r : _ -> pure r.opened
                      _ -> raise "AssertionError" "cancellation refusal occurred before canonical ScopeReset"
                    frontier <- liftIO $ do
                      writeIORef g.poisoned True
                      modifyIORef' scopeResets (+ 1)
                      writeIORef scopeGenerationRef (scopeGeneration opened)
                      historyLength g.history
                    pure
                      ApplyResult
                        { disposition = RefusedExpected
                        , value = Object [("error", String failure.errorMessage), ("frontier", Int frontier)]
                        , scheduled = []
                        }
                | otherwise -> raise failure.errorType failure.errorMessage
      isObject = \case
        Object _ -> True
        _ -> False
      profile =
        Profile
          { identity
          , validate = validateCommand
          , validateFault = \f ->
              if refusing
                then
                  if f.name /= "dispatch.refuse-cancellation"
                    || f.target /= "scope_fenced"
                    || f.disposition /= Refuse
                    || not (exactKeys ["message"] f.payload)
                    || not (isString (member "message" f.payload))
                    then throwError (ProfileError "ValueError" "unsupported lifecycle cancellation-refusal fault")
                    else pure f
                else throwError (ProfileError "ValueError" ("lifecycle Engine profile has no fault named " <> pythonStrRepr f.name))
          , create = do
              _ <- syncTime time
              g <- ioScenario (open False)
              pure GenerationStart {generation = g, scheduled = []}
          , load = do
              _ <- syncTime time
              g <- ioScenario (open True)
              drive <- scheduledNow "engine.drive" (Object [])
              pure GenerationStart {generation = g, scheduled = [drive]}
          , apply = \g c -> do
              _ <- syncTime time
              (if refusing then refusingApply else baseApply) g c
          , observe = \g request -> do
              _ <- syncTime time
              wanted <- case lookup request.name fields of
                Nothing -> raise "ValueError" ("unknown lifecycle Engine profile observation " <> pythonStrRepr request.name)
                Just fs -> pure fs
              if request.payload == Null || request.payload == Object []
                then pure ()
                else raise "ValueError" "lifecycle Engine profile observations do not accept parameters"
              select wanted <$> ioScenario (state g)
          , dropGeneration = \g -> ioDoor (modifyIORef' drops (+ 1) >> Engine.close g.engine)
          , closeGeneration = \g -> ioDoor (modifyIORef' closes (+ 1) >> Engine.close g.engine)
          , resourceUsage = Nothing
          }
  pure
    LifecycleProfile
      { profile
      , scopeGenerationRef
      , scopeOpens
      , scopeResets
      , sourceDeliveries
      , terminalDeliveries
      , cancellationAttempts = attempts
      }
  where
    upsert key value acc = case lookup key acc of
      Just _ -> [(k, if k == key then value else v) | (k, v) <- acc]
      Nothing -> acc <> [(key, value)]
    isString = \case
      String _ -> True
      _ -> False

-- | Run a door, returning its refusal instead of raising it.
tryScenario :: Scenario IO a -> Scenario IO (Either ProfileError a)
tryScenario body = catchError (Right <$> body) (pure . Left)

-- | @LifecycleEngineProfile.validate@.
validateCommand :: Command -> Door IO Command
validateCommand c = case c.name of
  "engine.drive"
    | c.payload /= Object [] -> refuse "engine.drive payload must be an empty object"
    | otherwise -> pure c
  name
    | name == "scope.open" || name == "scope.reset" ->
        if c.payload /= Object [("name", String scopeName')]
          then refuse (name <> " requires the exact supported scope name")
          else pure c
  "source.deliver"
    | not (exactKeys ["identity", "scope", "value"] c.payload) ->
        refuse "source.deliver requires exact identity, scope, and value fields"
    | not (nonEmptyString (member "identity" c.payload)) -> refuse "source.deliver identity must be a non-empty string"
    | member "scope" c.payload /= String scopeName' -> refuse "source.deliver requires the supported scope"
    | not (isInt (member "value" c.payload)) -> refuse "source.deliver value must be an integer"
    | otherwise -> pure c
  "activity.complete"
    | not (exactKeys ["occurrence", "result"] c.payload) ->
        refuse "activity.complete requires exact occurrence and result fields"
    | not (isPositiveInt (member "occurrence" c.payload)) -> refuse "activity.complete occurrence must be a positive integer"
    | otherwise -> pure c
  other -> refuse ("unknown lifecycle Engine profile command " <> pythonStrRepr other)
  where
    refuse = throwError . ProfileError "ValueError"
    nonEmptyString = \case
      String s -> not (T.null s)
      _ -> False
    isInt = \case
      Int _ -> True
      _ -> False

-- | @LifecycleEngineProfile(history_path)@.
lifecycleEngineProfile :: FilePath -> IO LifecycleProfile
lifecycleEngineProfile = newLifecycle False

-- | @LifecycleCancellationRefusalProfile(history_path)@.
lifecycleCancellationRefusalProfile :: FilePath -> IO LifecycleProfile
lifecycleCancellationRefusalProfile = newLifecycle True

-- ---------------------------------------------------------------------------
-- Checkers

lifecycleCheck :: Observation -> CheckResult
lifecycleCheck o =
  let records = case member "record_types" o.value of
        Array xs -> xs
        _ -> []
      int key = maybe 0 id (lookupInt key o.value)
      generation = int "authored_scope_generation"
      opens = int "authored_scope_opens"
      resets = int "authored_scope_resets"
      sources = int "authored_source_deliveries"
      terminals = int "authored_terminal_deliveries"
      actualScopes = member "active_scopes" o.value
      expectedScopes = if generation == 0 then Object [] else Object [(scopeName', Int generation)]
      count name = toInteger (countOf name records)
      canonicalOpens = count "ScopeOpened"
      canonicalResets = count "ScopeReset"
      quarantined = count "ActivityTerminalQuarantined"
      ordinary = count "ActivityCompleted" + count "ActivityFailed"
      projections = count "FiringCompleted"
      passed =
        actualScopes == expectedScopes
          && canonicalOpens <= opens
          && opens <= 1
          && canonicalResets <= resets
          && resets <= 1
          && quarantined <= terminals
          && quarantined <= 1
          && ordinary == 0
          && projections <= sources
          && sources <= 1
   in CheckResult
        { passed
        , detail =
            Object
              [ ("activity_terminals", Int ordinary)
              , ("authored_scope_generation", Int generation)
              , ("authored_scope_opens", Int opens)
              , ("authored_scope_resets", Int resets)
              , ("authored_source_deliveries", Int sources)
              , ("authored_terminal_deliveries", Int terminals)
              , ("canonical_scope_opens", Int canonicalOpens)
              , ("canonical_scope_resets", Int canonicalResets)
              , ("firing_completed", Int projections)
              , ("terminal_quarantined", Int quarantined)
              ]
        }

-- | @LifecycleAuthorityChecker@.
lifecycleAuthorityChecker :: Checker
lifecycleAuthorityChecker =
  Checker
    { identity = checkerIdentity
    , request = ObservationRequest {name = "engine.lifecycle-authority", payload = Object []}
    , check = pureCheck (Right . lifecycleCheck)
    }

-- | @CancellationAuthorityChecker@.
cancellationAuthorityChecker :: Checker
cancellationAuthorityChecker =
  Checker
    { identity = cancellationCheckerIdentity
    , request = ObservationRequest {name = "engine.cancellation-authority", payload = Object []}
    , check = pureCheck $ \o -> do
        let lifecycle = lifecycleCheck o
            attempts = case member "cancellation_attempts" o.value of
              Array xs -> xs
              _ -> []
            records = case member "record_types" o.value of
              Array xs -> xs
              _ -> []
            acceptances = [a | attempt <- attempts, Bool a <- [member "accepted" attempt]]
            dispositions = [member "disposition" attempt | attempt <- attempts]
            instructions = [Object [(k, v) | (k, v) <- ms, k /= "accepted", k /= "disposition"] | Object ms <- attempts]
            stable = case instructions of
              [] -> True
              first : rest -> all (== first) rest
            resets = countOf "ScopeReset" records
            quarantined = countOf "ActivityTerminalQuarantined" records
            passed =
              lifecycle.passed
                && length attempts <= 2
                && acceptances == take (length acceptances) [False, True]
                && dispositions == take (length dispositions) [Null, String "tombstoned"]
                && stable
                && (null attempts || resets == 1)
                && (quarantined == 0 || resets == 1)
        Right
          CheckResult
            { passed
            , detail =
                Object
                  [ ("accepted_cancellations", jsonInt (length (filter id acceptances)))
                  , ("cancellation_acceptances", Array (map Bool acceptances))
                  , ("cancellation_dispositions", Array dispositions)
                  , ("canonical_scope_resets", jsonInt resets)
                  , ("instruction_stable", Bool stable)
                  , ("lifecycle_authority", Bool lifecycle.passed)
                  , ("terminal_quarantined", jsonInt quarantined)
                  ]
            }
    }

-- ---------------------------------------------------------------------------
-- Stories

bridgeJson :: Integer -> Integer -> Json
bridgeJson a b = Object [("prepared", Int a), ("projected", Int b)]

draftScopes :: Integer -> Json
draftScopes generation = Object [(scopeName', Int generation)]

openAndDeliver :: Timeline -> WorldT IO LifecycleGeneration ()
openAndDeliver timeline = do
  _ <- Timeline.command timeline "scope.open" (Object [("name", String scopeName')])
  _ <-
    Timeline.command
      timeline
      "source.deliver"
      (Object [("identity", String "draft-input-3"), ("scope", String scopeName'), ("value", Int 3)])
  pure ()

complete2 :: Timeline -> WorldT IO LifecycleGeneration ()
complete2 timeline = do
  _ <- Timeline.command timeline "activity.complete" (Object [("occurrence", Int 2), ("result", Object [("value", Int 3)])])
  pure ()

-- | @execute_lifecycle_story(history_path)@: the authoring body.
executeLifecycleStory :: WorldT IO LifecycleGeneration ()
executeLifecycleStory = do
  timeline <- World.timeline
  openAndDeliver timeline
  requested <- Timeline.runUntil timeline "activity-requested" (\o -> memberOf "pending" o == Array [Int 2])
  ensure (memberOf "active_scopes" requested == draftScopes 1) "requested scopes"
  ensure (memberOf "bridge" requested == bridgeJson 1 0) "requested bridge"
  _ <- Timeline.command timeline "scope.reset" (Object [("name", String scopeName')])
  reset <- Timeline.observe timeline "reset-committed"
  ensure (memberOf "active_scopes" reset == draftScopes 2) "reset scopes"
  ensure (memberOf "pending" reset == Array []) "reset pending"
  ensure (memberOf "scope_resets" reset == Array [Object [("closed", Int 1), ("opened", Int 2)]]) "reset records"
  Timeline.crash timeline "lifecycle_reset_before_late_terminal"
  _ <- World.restart
  timeline' <- World.timeline
  recovered <- Timeline.runUntil timeline' "recovered-reset" (\o -> memberOf "drives" o == Int 1)
  ensure (memberOf "active_scopes" recovered == draftScopes 2) "recovered scopes"
  ensure (memberOf "pending" recovered == Array []) "recovered pending"
  ensure (memberOf "bridge" recovered == bridgeJson 0 0) "recovered bridge"
  complete2 timeline'
  quarantined <- Timeline.runUntil timeline' "terminal-quarantined" (\o -> memberOf "quarantined_occurrences" o == Array [Int 2])
  ensure (memberOf "bridge" quarantined == bridgeJson 0 0) "quarantined bridge"
  let frontier = memberOf "frontier" quarantined
  complete2 timeline'
  acknowledged <- Timeline.runUntil timeline' "duplicate-acknowledged" (\o -> memberOf "drives" o == Int 3)
  ensure (memberOf "frontier" acknowledged == frontier) "acknowledged frontier"
  ensure (memberOf "quarantined_occurrences" acknowledged == Array [Int 2]) "acknowledged quarantine"
  ensure (memberOf "bridge" acknowledged == bridgeJson 0 0) "acknowledged bridge"
  Timeline.beginFair timeline'
  Timeline.finish timeline' Quiescent

-- | @build_lifecycle_artifact(history_path)@.
buildLifecycleArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildLifecycleArtifact historyPath = do
  p <- lifecycleEngineProfile historyPath
  World.withWorld
    WorldConfig {profile = p.profile, budget = worldBudget, checkers = [lifecycleAuthorityChecker], seed = Nothing, progress = Nothing}
    (executeLifecycleStory >> World.artifact scenarioId)

-- | @execute_lifecycle_cancellation_story(history_path)@: the authoring body.
executeLifecycleCancellationStory :: WorldT IO LifecycleGeneration ()
executeLifecycleCancellationStory = do
  timeline <- World.timeline
  openAndDeliver timeline
  _ <- Timeline.runUntil timeline "activity-requested" (\o -> memberOf "pending" o == Array [Int 2])
  Timeline.activateFault
    timeline
    (Timeline.fault "dispatch.refuse-cancellation" "scope_fenced")
      { Timeline.disposition = Refuse
      , Timeline.payload = Object [("message", String "dst cancellation acceptance refused")]
      }
  _ <- Timeline.command timeline "scope.reset" (Object [("name", String scopeName')])
  refused <- Timeline.observe timeline "cancellation-refused"
  ensure (memberOf "active_scopes" refused == draftScopes 2) "refused scopes"
  ensure (memberOf "pending" refused == Array [Int 2]) "refused pending"
  ensure (memberOf "poisoned" refused == Bool True) "refused poisoned"
  ensure (memberOf "scope_resets" refused == Array [Object [("closed", Int 1), ("opened", Int 2)]]) "refused resets"
  case memberOf "cancellation_attempts" refused of
    Array [failed] -> do
      ensure (atKey "accepted" failed == Bool False) "failed attempt"
      ensure (atKey "history_position" failed == memberOf "frontier" refused) "failed position"
    _ -> ensure False "one failed attempt"
  Timeline.crash timeline "scope_fenced"
  _ <- World.restart
  timeline' <- World.timeline
  repaired <-
    Timeline.runUntil timeline' "cancellation-repaired" $ \o -> case memberOf "cancellation_attempts" o of
      Array xs -> length xs == 2
      _ -> False
  ensure (memberOf "active_scopes" repaired == draftScopes 2) "repaired scopes"
  ensure (memberOf "pending" repaired == Array []) "repaired pending"
  ensure (memberOf "poisoned" repaired == Bool False) "repaired poisoned"
  case memberOf "cancellation_attempts" repaired of
    Array [Object failed, accepted] ->
      ensure
        ( accepted
            == Object
              ( ("accepted", Bool True)
                  : ("disposition", String "tombstoned")
                  : [(k, v) | (k, v) <- failed, k /= "accepted", k /= "disposition"]
              )
        )
        "repaired attempt"
    _ -> ensure False "two attempts"
  complete2 timeline'
  quarantined <- Timeline.runUntil timeline' "terminal-quarantined" (\o -> memberOf "quarantined_occurrences" o == Array [Int 2])
  ensure (memberOf "bridge" quarantined == bridgeJson 0 0) "quarantined bridge"
  ensure
    ( case memberOf "record_types" quarantined of
        Array xs -> countOf "ActivityTerminalQuarantined" xs == 1
        _ -> False
    )
    "one quarantine"
  Timeline.beginFair timeline'
  Timeline.finish timeline' Quiescent

-- | @build_lifecycle_cancellation_artifact(history_path)@.
buildLifecycleCancellationArtifact :: FilePath -> IO (Either DstFailure AnyArtifact)
buildLifecycleCancellationArtifact historyPath = do
  p <- lifecycleCancellationRefusalProfile historyPath
  World.withWorld
    WorldConfig {profile = p.profile, budget = worldBudget, checkers = [cancellationAuthorityChecker], seed = Nothing, progress = Nothing}
    (executeLifecycleCancellationStory >> World.artifact cancellationScenarioId)

