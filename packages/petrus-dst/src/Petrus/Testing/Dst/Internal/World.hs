{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The deterministic World interpreter (the reference's @World@ class).
--
-- The World is a state machine in 'WorldT': every operation runs in the
-- reference's exact order of checks, budget reservations, profile doors,
-- journal records, resource samples, and checker evaluations, and failures
-- leave the state exactly where the reference leaves it.
module Petrus.Testing.Dst.Internal.World
  ( -- * Worlds
    World
  , WorldConfig (..)
  , worldConfig
  , WorldT
  , newWorld
  , runWorldT
  , withWorld
  , liftWorld
  , tryWorld
  , throwWorld

    -- * Failures
  , DstFailure (..)
  , RunUntil (..)
  , failureMessage
  , failureClass

    -- * Progress (process runner)
  , Progress (..)
  , Boundary (..)

    -- * Operations
  , submit
  , step
  , activateFault
  , observe
  , crash
  , restart
  , beginFair
  , finish
  , artifact
  , close
  , pending
  , pendingCount

    -- * State
  , generation
  , currentInstant
  , operations
  , operationCount
  , operationsFrom
  , journal
  , disposition
  , worldBudget
  , worldProfileIdentity
  , worldCheckerIdentities
  , worldSeed

    -- * Choices
  , chooseIndex
  , chooseIdentifier
  , choiceDraws

    -- * Model checks
  , checkModel
  ) where

import Control.Exception (Exception (..))
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Except (ExceptT, catchError, runExceptT, throwError)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.State.Strict (StateT, gets, modify', runStateT)
import Control.Monad.Trans.Class (lift)
import Data.Foldable (toList)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Testing.Dst.Choice (ChoiceError (..), ChoiceStreams, IndexAuthority, choiceStreams, provenance)
import Petrus.Testing.Dst.Choice qualified as Choice
import Petrus.Testing.Dst.Codec (encodeArtifact, journalDigest)
import Petrus.Testing.Dst.Decode
import Petrus.Testing.Dst.Profile
import Petrus.Testing.Dst.PyRepr
import Petrus.Testing.Dst.Types

-- ---------------------------------------------------------------------------
-- Failures

-- | Details of a @RunUntilFailed@ refusal.
data RunUntil = RunUntil
  { name :: Text
  , disposition :: Disposition
  , observation :: Observation
  , pending :: [Json]
  , journal :: [JournalEntry]
  , budget :: SomeBudget
  }
  deriving stock (Eq, Show)

-- | Every exception the reference's World, Timeline, and replay raise, plus
-- profile failures. Only 'BudgetExhausted' and 'InvariantViolation' raised
-- by the World itself become failure operations.
data DstFailure
  = -- | @BudgetExhausted(bound, limit)@.
    BudgetExhausted Text Integer
  | -- | @InvariantViolation@: a checker refused an atomic boundary.
    InvariantViolation Text
  | -- | @StaleGeneration@.
    StaleGeneration Text
  | -- | @PendingWork@.
    PendingWork Text
  | -- | @DstError@.
    DstError Text
  | -- | A built-in exception the reference raises for contract misuse
    -- (@ValueError@, @TypeError@, @AssertionError@) or a pydantic
    -- @ValidationError@ for an invalid model: class name and message.
    ContractViolation Text Text
  | -- | @ReplayMismatch@.
    ReplayMismatch Text
  | -- | @RunUntilFailed@.
    RunUntilFailed RunUntil
  | -- | A profile door or checker raised.
    ProfileRaised ProfileError
  deriving stock (Eq, Show)

instance Exception DstFailure where
  displayException failure = T.unpack (failureClass failure <> ": " <> failureMessage failure)

-- | The reference exception's @str()@.
failureMessage :: DstFailure -> Text
failureMessage = \case
  BudgetExhausted bound limit -> "DST budget " <> pyStrRepr bound <> " exhausted at limit " <> tshow limit
  InvariantViolation m -> m
  StaleGeneration m -> m
  PendingWork m -> m
  DstError m -> m
  ContractViolation _ m -> m
  ReplayMismatch m -> m
  RunUntilFailed r ->
    "DST run_until "
      <> pyStrRepr r.name
      <> " ended as "
      <> dispositionText r.disposition
      <> "; last="
      <> pyRepr (jsonToPy (toJson r.observation))
      <> "; pending="
      <> pyRepr (PyList (map jsonToPy r.pending))
      <> "; journal_tail="
      <> pyRepr (PyList (map (jsonToPy . toJson) (lastN 8 r.journal)))
  ProfileRaised e -> e.errorMessage
  where
    lastN n xs = drop (length xs - n) xs

-- | The reference exception's class name.
failureClass :: DstFailure -> Text
failureClass = \case
  BudgetExhausted _ _ -> "BudgetExhausted"
  InvariantViolation _ -> "InvariantViolation"
  StaleGeneration _ -> "StaleGeneration"
  PendingWork _ -> "PendingWork"
  DstError _ -> "DstError"
  ContractViolation t _ -> t
  ReplayMismatch _ -> "ReplayMismatch"
  RunUntilFailed _ -> "RunUntilFailed"
  ProfileRaised e -> e.errorType

-- ---------------------------------------------------------------------------
-- State

-- | Process-runner acknowledgements at legal World boundaries.
data Progress m = Progress
  { attempt :: ProcessAttempt -> m (Either DstFailure ())
  , boundary :: Boundary -> m (Either DstFailure ())
  }

-- | The World state a boundary acknowledgement reads.
data Boundary = Boundary
  { operations :: Seq ExpandedOperation
  , journal :: Seq JournalEntry
  , instant :: Integer
  , generation :: Maybe Integer
  , disposition :: Maybe Disposition
  }

data Queued = Queued
  { instant :: Integer
  , order :: Integer
  , generation :: Integer
  , source :: CommandSource
  , command :: Command
  }

data WorldState g = WorldState
  { clock :: Integer
  , live :: Maybe (g, Integer)
  , lastGeneration :: Integer
  , queue :: Map (Integer, Integer) Queued
  , nextOrder :: Integer
  , accepted :: Seq ExpandedOperation
  , entries :: Seq JournalEntry
  , armedFaults :: [ActiveFault]
  , idCounters :: Map Text Integer
  , actionsUsed :: Integer
  , advancesUsed :: Integer
  , reloadsUsed :: Integer
  , pollsUsed :: Integer
  , inFair :: Bool
  , ending :: Maybe Disposition
  , streams :: Maybe ChoiceStreams
  }

-- | One deterministic interpreter over an application-owned profile.
data World m g = World
  { profile :: Profile m g
  , budget :: SomeBudget
  , checkers :: [Checker]
  , progress :: Maybe (Progress m)
  , seed :: Maybe Integer
  , state :: WorldState g
  }

-- | The constructor arguments of the reference's @World@.
data WorldConfig m g = WorldConfig
  { profile :: Profile m g
  , budget :: SomeBudget
  , checkers :: [Checker]
  , seed :: Maybe Integer
  , progress :: Maybe (Progress m)
  }

-- | A configuration without checkers, seed, or progress.
worldConfig :: Profile m g -> SomeBudget -> WorldConfig m g
worldConfig profile budget = WorldConfig {profile, budget, checkers = [], seed = Nothing, progress = Nothing}

-- | Computations against one World.
newtype WorldT m g a = WorldT (ExceptT DstFailure (StateT (World m g) m) a)
  deriving newtype (Functor, Applicative, Monad)

instance (MonadIO m) => MonadIO (WorldT m g) where
  liftIO = WorldT . liftIO

-- | Run a computation; the World is returned in its state after a failure
-- too, as the reference's object survives a raised exception.
runWorldT :: WorldT m g a -> World m g -> m (Either DstFailure a, World m g)
runWorldT (WorldT body) = runStateT (runExceptT body)

-- | Lift an action of the underlying monad.
liftWorld :: (Monad m) => m a -> WorldT m g a
liftWorld = WorldT . lift . lift

-- | Catch a failure (Python's @try@/@except@).
tryWorld :: (Monad m) => WorldT m g a -> WorldT m g (Either DstFailure a)
tryWorld (WorldT body) = WorldT (fmap Right body `catchError` (pure . Left))

throwWorld :: (Monad m) => DstFailure -> WorldT m g a
throwWorld = WorldT . throwError

getsW :: (Monad m) => (WorldState g -> a) -> WorldT m g a
getsW f = WorldT (gets (\w -> f w.state))

modifyW :: (Monad m) => (WorldState g -> WorldState g) -> WorldT m g ()
modifyW f = WorldT (modify' (\w -> w {state = f w.state}))

askW :: (Monad m) => (World m g -> a) -> WorldT m g a
askW f = WorldT (gets f)

-- | Construct a World: the reference's constructor, including the
-- @construct@ acknowledgement, the @before_create@ resource sample, the
-- @create@ door, generation installation, and cleanup on failure.
newWorld :: (Monad m) => WorldConfig m g -> m (Either DstFailure (World m g))
newWorld config = case validateConfig of
  Left failure -> pure (Left failure)
  Right choices -> do
    let world =
          World
            { profile = config.profile
            , budget = config.budget
            , checkers = config.checkers
            , progress = config.progress
            , seed = config.seed
            , state = initialState choices
            }
    (result, world') <- runWorldT construct world
    case result of
      Right () -> pure (Right world')
      Left failure -> do
        (cleanup, _) <- runWorldT cleanupAfterConstruct world'
        pure (Left (either id (const failure) cleanup))
  where
    validateConfig = do
      choices <- case config.seed of
        Nothing -> Right Nothing
        Just s -> either (Left . choiceFailure) (Right . Just) (choiceStreams s)
      let keys = [identityKey c.identity | c <- config.checkers]
      when (length keys /= Set.size (Set.fromList keys)) $
        Left (ContractViolation "ValueError" "DST World checker identities must be unique")
      Right choices
    construct = do
      notifyAttempt AConstruct
      sampleResources Nothing "before_create"
      profile <- askW (\w -> w.profile)
      started <- scenarioDoor profile.create
      installGeneration started False
      notifyBoundary
    cleanupAfterConstruct = do
      live <- getsW (\s -> s.live)
      forM_ live $ \(g, _) -> do
        modifyW (\s -> s {live = Nothing, queue = Map.empty})
        profile <- askW (\w -> w.profile)
        runDoor (profile.closeGeneration g)

initialState :: Maybe ChoiceStreams -> WorldState g
initialState choices =
  WorldState
    { clock = 0
    , live = Nothing
    , lastGeneration = 0
    , queue = Map.empty
    , nextOrder = 0
    , accepted = Seq.empty
    , entries = Seq.empty
    , armedFaults = []
    , idCounters = Map.empty
    , actionsUsed = 0
    , advancesUsed = 0
    , reloadsUsed = 0
    , pollsUsed = 0
    , inFair = False
    , ending = Nothing
    , streams = choices
    }

-- | Construct a World, run a computation, and always close it afterwards
-- (@try: … finally: world.close()@). A failing close replaces the result.
withWorld :: (Monad m) => WorldConfig m g -> WorldT m g a -> m (Either DstFailure a)
withWorld config body = do
  constructed <- newWorld config
  case constructed of
    Left failure -> pure (Left failure)
    Right world -> do
      (result, world') <- runWorldT body world
      (closed, _) <- runWorldT close world'
      pure (either Left (const result) closed)

choiceFailure :: ChoiceError -> DstFailure
choiceFailure e = ContractViolation e.errorType e.message

-- ---------------------------------------------------------------------------
-- Door invocation

runDoor :: (Monad m) => Door m a -> WorldT m g a
runDoor body = WorldT (lift (lift (runExceptT body))) >>= either (throwWorld . ProfileRaised) pure

-- | Run a door with the scenario context; the context's stable-id counters
-- and fault bookkeeping persist even when the door raises.
scenarioDoor :: (Monad m) => Scenario m a -> WorldT m g a
scenarioDoor body = do
  context <- getsW (\s -> ScenarioContext {instant = s.clock, stableIds = s.idCounters, activeFaults = s.armedFaults})
  (result, context') <- WorldT (lift (lift (runScenario body context)))
  modifyW (\s -> s {idCounters = context'.stableIds, armedFaults = context'.activeFaults})
  either (throwWorld . ProfileRaised) pure result

notifyAttempt :: (Monad m) => ProcessAttempt -> WorldT m g ()
notifyAttempt a = do
  progress <- askW (\w -> w.progress)
  forM_ progress $ \p -> liftWorld (p.attempt a) >>= either throwWorld pure

notifyBoundary :: (Monad m) => WorldT m g ()
notifyBoundary = do
  progress <- askW (\w -> w.progress)
  forM_ progress $ \p -> do
    s <- getsW id
    let snapshot =
          Boundary
            { operations = s.accepted
            , journal = s.entries
            , instant = s.clock
            , generation = snd <$> s.live
            , disposition = s.ending
            }
    liftWorld (p.boundary snapshot) >>= either throwWorld pure

-- ---------------------------------------------------------------------------
-- Model checks

-- | Validate a value against its strict model, as pydantic does when the
-- reference constructs it; 'Left' carries a pydantic-style report.
checkModel :: Text -> (Path -> Json -> Parser a) -> Json -> Either Text ()
checkModel modelName parser value = case parser [] value of
  Left e -> Left (renderSchemaError modelName e)
  Right _ -> Right ()

-- | A model the caller built (the reference would refuse it at construction,
-- before the World sees it).
callerModel :: (Monad m) => Text -> (Path -> Json -> Parser a) -> Json -> WorldT m g ()
callerModel modelName parser value =
  either (throwWorld . ContractViolation "ValidationError") pure (checkModel modelName parser value)

-- | A model a profile door returned (the reference's profile would raise the
-- validation error itself).
profileModel :: (Monad m) => Text -> (Path -> Json -> Parser a) -> Json -> WorldT m g ()
profileModel modelName parser value =
  either (throwWorld . ProfileRaised . ProfileError "ValidationError") pure (checkModel modelName parser value)

-- | @Observation(value=_strict_json(value, subject), ...)@ built by the World
-- itself: the non-finite refusal, then pydantic's recursion guard on the
-- value ('jsonValueRecursion').
strictValue :: (Monad m) => Text -> Json -> WorldT m g Json
strictValue subject value = case strictJsonPath value of
  Just at -> throwWorld (ContractViolation "ValueError" (subject <> " has a non-finite number at " <> at))
  Nothing -> case jsonValueRecursion 0 [LKey "value"] value of
    Just e -> throwWorld (ContractViolation "ValidationError" (renderSchemaError "Observation" e))
    Nothing -> pure value

positiveGeneration :: (Monad m) => Text -> Integer -> WorldT m g ()
positiveGeneration modelName g =
  when (g < 1) $
    throwWorld
      ( ContractViolation
          "ValidationError"
          (renderSchemaError modelName (SchemaError [LKey "generation"] "greater_than_equal" "Input should be greater than or equal to 1"))
      )

-- ---------------------------------------------------------------------------
-- Operations

-- | @World._attempt@: acknowledge the attempt, run it, and retain a World
-- budget or invariant refusal as the terminal failure operation.
attemptOperation :: (Monad m) => OperationAttempt -> WorldT m g a -> WorldT m g a
attemptOperation attemptValue body = do
  notifyAttempt (WorldAttempt attemptValue)
  before <- getsW (\s -> Seq.length s.accepted)
  result <- tryWorld body
  case result of
    Right value -> notifyBoundary >> pure value
    Left failure -> do
      current <- getsW (\s -> s.ending)
      let detail = case failure of
            BudgetExhausted bound limit
              | current == Just DBudgetExhausted ->
                  Just (FBudget BudgetFailure {bound, limit, error = failureMessage failure})
            InvariantViolation message
              | current == Just DInvariantFailure -> Just (FInvariant InvariantFailure {error = message})
            _ -> Nothing
      case detail of
        Nothing -> throwWorld failure
        Just failureDetail -> do
          s <- getsW id
          let accepted = Seq.length s.accepted - before
          unless (accepted == 0 || accepted == 1) $
            throwWorld (ContractViolation "AssertionError" "one DST interpreter attempt accepted more than one operation")
          let operation =
                FailureOperation
                  { position = toInteger (Seq.length s.accepted)
                  , instant = s.clock
                  , generation = snd <$> s.live
                  , acceptedOperations = toInteger accepted
                  , attempt = attemptValue
                  , failure = failureDetail
                  }
          appendOperation (Failed operation)
          record JFailure (dispositionText (failureKind failureDetail)) (toJson operation) CurrentGeneration
          notifyBoundary
          throwWorld failure

-- | @World.submit@: enqueue one authored command and execute it at once.
submit :: (Monad m) => Command -> Integer -> WorldT m g ApplyResult
submit command generation' = do
  positiveGeneration "SubmitAttempt" generation'
  callerModel "Command" pCommand (toJson command)
  attemptOperation (ASubmit SubmitAttempt {generation = generation', command}) $ do
    requireGeneration generation'
    isFair <- getsW (\s -> s.inFair)
    when isFair $ throwWorld (DstError "authored commands cannot enter an active DST fair phase")
    due <- headIsDue
    when due $ throwWorld (PendingWork "run eligible profile work before submitting another authored command")
    current <- getsW (\s -> s.clock)
    order <- enqueue current command Authored
    executed <- stepInner
    when (executed.queueOrder /= order) $
      throwWorld (ContractViolation "AssertionError" "DST authored command was not the scheduler's next total-order choice")
    pure executed.result

-- | @World.step@: execute the scheduler's next command.
step :: (Monad m) => WorldT m g ExecuteOperation
step = attemptOperation AStep stepInner

stepInner :: (Monad m) => WorldT m g ExecuteOperation
stepInner = do
  requireUnfinished
  live <- getsW (\s -> s.live)
  (g, liveId) <- maybe (throwWorld (StaleGeneration "DST World has no live generation")) pure live
  queue <- getsW (\s -> s.queue)
  (key, queued) <- maybe (throwWorld (DstError "DST World is waiting with no scheduled command")) pure (Map.lookupMin queue)
  when (queued.generation /= liveId) $
    throwWorld (StaleGeneration ("queued generation " <> tshow queued.generation <> " is no longer live"))
  limits <- budgetLimits <$> askW (\w -> w.budget)
  current <- getsW (\s -> s.clock)
  when (queued.instant > current) $ do
    advances <- getsW (\s -> s.advancesUsed)
    when (advances >= limits.timerAdvances) $ exhaust "timer_advances" limits.timerAdvances
    when (queued.instant > limits.logicalInstant) $ exhaust "logical_instant" limits.logicalInstant
  reserveAction
  modifyW (\s -> s {queue = Map.delete key s.queue})
  when (queued.instant > current) $
    modifyW (\s -> s {advancesUsed = s.advancesUsed + 1, clock = queued.instant})
  profile <- askW (\w -> w.profile)
  result <- scenarioDoor (profile.apply g queued.command)
  profileModel "ApplyResult" pApplyResult (toJson result)
  s <- getsW id
  let operation =
        ExecuteOperation
          { position = toInteger (Seq.length s.accepted)
          , source = queued.source
          , queueOrder = queued.order
          , instant = s.clock
          , generation = liveId
          , command = queued.command
          , result
          }
  appendOperation (Accepted (OpExecute operation))
  record JCommand queued.command.name (toJson (OpExecute operation)) CurrentGeneration
  enqueueAll result.scheduled ProfileSource
  sampleResources (Just g) queued.command.name
  evaluateCheckers queued.command.name operation.position g liveId
  pure operation

-- | @World.activate_fault@.
activateFault :: (Monad m) => Fault -> Integer -> WorldT m g ()
activateFault fault generation' = do
  positiveGeneration "FaultAttempt" generation'
  callerModel "Fault" pFault (toJson fault)
  attemptOperation (AFault FaultAttempt {generation = generation', fault}) $ do
    requireGeneration generation'
    requireUnfinished
    isFair <- getsW (\s -> s.inFair)
    when isFair $ throwWorld (DstError "faults cannot enter an active DST fair phase")
    profile <- askW (\w -> w.profile)
    when (fault.profile /= profile.identity) $
      throwWorld (ContractViolation "ValueError" "DST fault profile does not match this World")
    due <- headIsDue
    when due $ throwWorld (PendingWork "a fault cannot overtake already eligible profile work")
    validated <- runDoor (profile.validateFault fault)
    profileModel "Fault" pFault (toJson validated)
    when (validated.profile /= profile.identity) $
      throwWorld (ContractViolation "TypeError" "ScenarioProfile.validate_fault must return a Fault for its exact identity")
    reserveAction
    s <- getsW id
    let operation =
          FaultOperation
            { position = toInteger (Seq.length s.accepted)
            , instant = s.clock
            , generation = generation'
            , fault = validated
            }
    appendOperation (Accepted (OpFault operation))
    modifyW (\st -> st {armedFaults = st.armedFaults ++ [ActiveFault validated 0]})
    record JFault validated.name (toJson (OpFault operation)) CurrentGeneration
    (g, _) <- liveGeneration
    sampleResources (Just g) ("fault:" <> validated.name)
    evaluateCheckers ("fault:" <> validated.name) operation.position g generation'

-- | @World.observe@.
observe :: (Monad m) => ObservationRequest -> Integer -> Bool -> WorldT m g Observation
observe request generation' poll = do
  positiveGeneration "ObserveAttempt" generation'
  callerModel "ObservationRequest" pObservationRequest (toJson request)
  attemptOperation (AObserve ObserveAttempt {generation = generation', request, poll}) $ do
    requireGeneration generation'
    requireUnfinished
    reserveAction
    when poll $ do
      limits <- budgetLimits <$> askW (\w -> w.budget)
      polls <- getsW (\s -> s.pollsUsed)
      when (polls >= limits.predicatePolls) $ exhaust "predicate_polls" limits.predicatePolls
      modifyW (\s -> s {pollsUsed = s.pollsUsed + 1})
    position <- getsW (\s -> toInteger (Seq.length s.accepted))
    observation <- observeWithoutJournal request position
    let operation = ObserveOperation {position, poll, observation, request}
    appendOperation (Accepted (OpObserve operation))
    record JObservation request.name (toJson (OpObserve operation)) CurrentGeneration
    (g, _) <- liveGeneration
    sampleResources (Just g) ("observe:" <> request.name)
    pure observation

observeWithoutJournal :: (Monad m) => ObservationRequest -> Integer -> WorldT m g Observation
observeWithoutJournal request sequence' = do
  live <- getsW (\s -> s.live)
  (g, liveId) <- maybe (throwWorld (StaleGeneration "cannot observe without a live generation")) pure live
  profile <- askW (\w -> w.profile)
  value <- scenarioDoor (profile.observe g request) >>= strictValue "profile observation"
  current <- getsW (\s -> s.clock)
  pure Observation {name = request.name, value, instant = current, generation = liveId, sequence = sequence'}

-- | @World.crash@: abruptly drop the live generation at a named cut.
crash :: (Monad m) => Text -> Integer -> WorldT m g ()
crash cut generation' = do
  positiveGeneration "CrashAttempt" generation'
  unless (isName cut) $
    throwWorld
      ( ContractViolation
          "ValidationError"
          (renderSchemaError "CrashAttempt" (SchemaError [LKey "cut"] "value_error" "Value error, crash cut must be a normalized non-empty name"))
      )
  attemptOperation (ACrash CrashAttempt {generation = generation', cut}) $ do
    requireGeneration generation'
    requireUnfinished
    isFair <- getsW (\s -> s.inFair)
    when isFair $ throwWorld (DstError "process crashes cannot enter an active DST fair phase")
    reserveAction
    (dropped, droppedId) <- liveGeneration
    position <- getsW (\s -> toInteger (Seq.length s.accepted))
    captured <- captureChecks ("crash:" <> cut) position dropped droppedId
    discarded <- getsW (\s -> toInteger (Map.size s.queue))
    modifyW (\s -> s {live = Nothing, queue = Map.empty})
    profile <- askW (\w -> w.profile)
    runDoor (profile.dropGeneration dropped)
    current <- getsW (\s -> s.clock)
    let operation =
          CrashOperation {position, instant = current, generation = droppedId, cut, discardedCommands = discarded}
    appendOperation (Accepted (OpCrash operation))
    record JCrash cut (toJson (OpCrash operation)) (ExplicitGeneration Nothing)
    sampleResources Nothing ("crash:" <> cut)
    recordChecks captured

-- | @World.restart@: load a new generation after an abrupt drop.
restart :: (Monad m) => WorldT m g Integer
restart = attemptOperation ARestart $ do
  requireUnfinished
  live <- getsW (\s -> s.live)
  when (isJustLive live) $ throwWorld (DstError "DST restart requires an abruptly dropped generation")
  limits <- budgetLimits <$> askW (\w -> w.budget)
  reloadsSoFar <- getsW (\s -> s.reloadsUsed)
  when (reloadsSoFar >= limits.reloads) $ exhaust "reloads" limits.reloads
  reserveAction
  modifyW (\s -> s {reloadsUsed = s.reloadsUsed + 1})
  profile <- askW (\w -> w.profile)
  started <- scenarioDoor profile.load
  installGeneration started True
  (g, liveId) <- liveGeneration
  s <- getsW id
  let operation = RestartOperation {position = toInteger (Seq.length s.accepted), instant = s.clock, generation = liveId}
  appendOperation (Accepted (OpRestart operation))
  record JLoaded profile.identity.name (toJson (OpRestart operation)) CurrentGeneration
  sampleResources (Just g) "load"
  evaluateCheckers "load" operation.position g liveId
  pure liveId
  where
    isJustLive = maybe False (const True)

-- | @World.begin_fair@.
beginFair :: (Monad m) => Integer -> WorldT m g ()
beginFair generation' = do
  positiveGeneration "FairAttempt" generation'
  attemptOperation (AFair FairAttempt {generation = generation'}) $ do
    requireGeneration generation'
    requireUnfinished
    isFair <- getsW (\s -> s.inFair)
    when isFair $ throwWorld (DstError "DST fair phase has already begun")
    active <- getsW (\s -> s.armedFaults)
    unless (null active) $ throwWorld (DstError "DST fair phase requires every activated fault to be consumed")
    reserveAction
    modifyW (\s -> s {inFair = True})
    s <- getsW id
    let operation = FairOperation {position = toInteger (Seq.length s.accepted), instant = s.clock, generation = generation'}
    appendOperation (Accepted (OpFair operation))
    record JFair "begin" (toJson (OpFair operation)) CurrentGeneration
    (g, _) <- liveGeneration
    sampleResources (Just g) "begin_fair"
    evaluateCheckers "begin_fair" operation.position g generation'

-- | @World.finish@ with an authored disposition.
finish :: (Monad m) => AuthoredDisposition -> Integer -> WorldT m g ()
finish ending generation' = do
  positiveGeneration "FinishAttempt" generation'
  attemptOperation (AFinish FinishAttempt {generation = generation', disposition = ending}) $ do
    requireGeneration generation'
    requireUnfinished
    isFair <- getsW (\s -> s.inFair)
    when (isFair && ending == ExternalWait) $
      throwWorld (DstError "an active DST fair phase cannot end as an external wait")
    queue <- getsW (\s -> s.queue)
    unless (Map.null queue) $
      throwWorld (PendingWork ("cannot finish " <> authoredDispositionText ending <> " while scheduled work remains"))
    reserveAction
    s <- getsW id
    let operation =
          FinishOperation
            { position = toInteger (Seq.length s.accepted)
            , instant = s.clock
            , generation = generation'
            , disposition = ending
            }
    appendOperation (Accepted (OpFinish operation))
    modifyW (\st -> st {ending = Just (authoredDisposition ending)})
    record JFinish (authoredDispositionText ending) (toJson (OpFinish operation)) CurrentGeneration
    (g, _) <- liveGeneration
    sampleResources (Just g) ("finish:" <> authoredDispositionText ending)

-- | @World.artifact@: a version-4 artifact for a 'BudgetV4' World,
-- otherwise version 3; refused unless finished or when over its byte budget.
artifact :: (Monad m) => Text -> WorldT m g AnyArtifact
artifact scenarioId = do
  s <- getsW id
  ending <- maybe (throwWorld (DstError "finish the DST World before producing an artifact")) pure s.ending
  world <- askW id
  let operationList = toList s.accepted
      failures = [f.failure | Failed f <- operationList]
      expected =
        ScenarioExpected
          { disposition = ending
          , failure = if null failures then Nothing else Just (last failures)
          , checks = [e | e <- toList s.entries, e.kind == JCheck]
          , journalDigest = journalDigest (toList s.entries)
          }
      origin = provenance <$> s.streams
      checkerIdentities = [c.identity | c <- world.checkers]
      built = case world.budget of
        SomeBudgetV4 b ->
          ArtifactV4
            ScenarioArtifactV4
              { scenarioId
              , profile = world.profile.identity
              , checkers = checkerIdentities
              , budget = b
              , operations = operationList
              , expected
              , origin
              }
        SomeBudget b ->
          ArtifactV3
            ScenarioArtifactV3
              { scenarioId
              , profile = world.profile.identity
              , checkers = checkerIdentities
              , budget = b
              , operations = operationList
              , expected
              , origin
              }
      modelName = case built of
        ArtifactV4 _ -> "ScenarioArtifact"
        _ -> "ScenarioArtifactV3"
  unless (isName scenarioId) $
    throwWorld
      ( ContractViolation
          "ValidationError"
          (renderSchemaError modelName (SchemaError [LKey "scenario_id"] "value_error" "Value error, scenario id must be a normalized non-empty name"))
      )
  forM_ (artifactCoherence built) $ \message ->
    throwWorld (ContractViolation "ValidationError" (renderSchemaError modelName (SchemaError [] "value_error" ("Value error, " <> message))))
  case encodeArtifact built of
    Left message -> throwWorld (ContractViolation "ValueError" message)
    Right _ -> pure built

-- | @World.close@: gracefully close the live generation, if any.
close :: (Monad m) => WorldT m g ()
close = do
  live <- getsW (\s -> s.live)
  forM_ live $ \(g, liveId) -> do
    notifyAttempt (AClose liveId)
    modifyW (\s -> s {live = Nothing, queue = Map.empty})
    profile <- askW (\w -> w.profile)
    runDoor (profile.closeGeneration g)
    notifyBoundary

-- | @World.pending()@: scheduled work in total order.
pending :: (Monad m) => WorldT m g [Json]
pending = getsW (\s -> map pendingJson (Map.elems s.queue))

pendingJson :: Queued -> Json
pendingJson q =
  Object
    [ ("instant", Int q.instant)
    , ("order", Int q.order)
    , ("generation", Int q.generation)
    , ("source", String (commandSourceText q.source))
    , ("command", toJson q.command)
    ]

pendingCount :: (Monad m) => WorldT m g Int
pendingCount = getsW (\s -> Map.size s.queue)

-- ---------------------------------------------------------------------------
-- Accessors

-- | The live generation identity, if any.
generation :: (Monad m) => WorldT m g (Maybe Integer)
generation = getsW (\s -> snd <$> s.live)

currentInstant :: (Monad m) => WorldT m g Integer
currentInstant = getsW (\s -> s.clock)

operations :: (Monad m) => WorldT m g [ExpandedOperation]
operations = getsW (\s -> toList s.accepted)

operationCount :: (Monad m) => WorldT m g Int
operationCount = getsW (\s -> Seq.length s.accepted)

-- | The operations from one position on.
operationsFrom :: (Monad m) => Int -> WorldT m g [ExpandedOperation]
operationsFrom start = getsW (\s -> toList (Seq.drop start s.accepted))

journal :: (Monad m) => WorldT m g [JournalEntry]
journal = getsW (\s -> toList s.entries)

disposition :: (Monad m) => WorldT m g (Maybe Disposition)
disposition = getsW (\s -> s.ending)

worldBudget :: (Monad m) => WorldT m g SomeBudget
worldBudget = askW (\w -> w.budget)

worldProfileIdentity :: (Monad m) => WorldT m g ProfileIdentity
worldProfileIdentity = askW (\w -> w.profile.identity)

worldCheckerIdentities :: (Monad m) => WorldT m g [CheckerIdentity]
worldCheckerIdentities = askW (\w -> [c.identity | c <- w.checkers])

worldSeed :: (Monad m) => WorldT m g (Maybe Integer)
worldSeed = askW (\w -> w.seed)

-- | @world.choices.index(authority, stop)@.
chooseIndex :: (Monad m) => IndexAuthority -> Integer -> WorldT m g Integer
chooseIndex authority stop = withChoices (Choice.chooseIndex authority stop)

-- | @world.choices.identifier(namespace)@.
chooseIdentifier :: (Monad m) => Text -> WorldT m g Text
chooseIdentifier namespace = withChoices (Choice.chooseIdentifier namespace)

-- | The draws so far (@world.choices.provenance().draws@).
choiceDraws :: (Monad m) => WorldT m g (Map Text Integer)
choiceDraws = do
  streams <- getsW (\s -> s.streams) >>= maybe noChoices pure
  pure (Choice.streamsDraws streams)

withChoices :: (Monad m) => (ChoiceStreams -> Either ChoiceError (a, ChoiceStreams)) -> WorldT m g a
withChoices draw = do
  streams <- getsW (\s -> s.streams) >>= maybe noChoices pure
  case draw streams of
    Left e -> throwWorld (choiceFailure e)
    Right (value, streams') -> modifyW (\s -> s {streams = Just streams'}) >> pure value

noChoices :: (Monad m) => WorldT m g a
noChoices = throwWorld (DstError "DST World has no seeded choice authorities")

-- ---------------------------------------------------------------------------
-- Internals

installGeneration :: (Monad m) => GenerationStart g -> Bool -> WorldT m g ()
installGeneration started loaded = do
  forM_ started.scheduled (profileModel "ScheduledCommand" pScheduledCommand . toJson)
  modifyW (\s -> s {lastGeneration = s.lastGeneration + 1, live = Just (started.generation, s.lastGeneration + 1)})
  enqueueAll started.scheduled ProfileSource
  unless loaded $ do
    profile <- askW (\w -> w.profile)
    record JCreated profile.identity.name (Object [("scheduled", Array (map toJson started.scheduled))]) CurrentGeneration
    (g, liveId) <- liveGeneration
    sampleResources (Just g) "create"
    evaluateCheckers "create" 0 g liveId

headIsDue :: (Monad m) => WorldT m g Bool
headIsDue = do
  s <- getsW id
  pure $ case Map.lookupMin s.queue of
    Just ((due, _), _) -> due <= s.clock
    Nothing -> False

-- | @_enqueue@: one authored command.
enqueue :: (Monad m) => Integer -> Command -> CommandSource -> WorldT m g Integer
enqueue scheduledInstant command source = do
  live <- getsW (\s -> s.live)
  when (null live) $ throwWorld (StaleGeneration "cannot schedule work without a live generation")
  current <- getsW (\s -> s.clock)
  when (scheduledInstant < current) $
    throwWorld (ContractViolation "ValueError" "DST profile cannot schedule a command in the past")
  limits <- budgetLimits <$> askW (\w -> w.budget)
  when (scheduledInstant > limits.logicalInstant) $ exhaust "logical_instant" limits.logicalInstant
  validated <- validateCommand command
  size <- getsW (\s -> toInteger (Map.size s.queue))
  when (size >= limits.queuedCommands) $ exhaust "queued_commands" limits.queuedCommands
  enqueueValidated scheduledInstant validated source

-- | @_enqueue_all@: profile follow-up work, admitted all or nothing.
enqueueAll :: (Monad m) => [ScheduledCommand] -> CommandSource -> WorldT m g ()
enqueueAll scheduled source = do
  limits <- budgetLimits <$> askW (\w -> w.budget)
  size <- getsW (\s -> toInteger (Map.size s.queue))
  when (size + toInteger (length scheduled) > limits.queuedCommands) $ exhaust "queued_commands" limits.queuedCommands
  current <- getsW (\s -> s.clock)
  validated <- forM scheduled $ \item -> do
    when (item.instant < current) $
      throwWorld (ContractViolation "ValueError" "DST profile cannot schedule a command in the past")
    when (item.instant > limits.logicalInstant) $ exhaust "logical_instant" limits.logicalInstant
    command <- validateCommand item.command
    pure (item.instant, command)
  forM_ validated $ \(at, command) -> enqueueValidated at command source

enqueueValidated :: (Monad m) => Integer -> Command -> CommandSource -> WorldT m g Integer
enqueueValidated at command source = do
  (_, liveId) <- liveGeneration
  order <- getsW (\s -> s.nextOrder)
  let queued = Queued {instant = at, order, generation = liveId, source, command}
  modifyW (\s -> s {nextOrder = order + 1, queue = Map.insert (at, order) queued s.queue})
  pure order

validateCommand :: (Monad m) => Command -> WorldT m g Command
validateCommand command = do
  profile <- askW (\w -> w.profile)
  when (command.profile /= profile.identity) $
    throwWorld (ContractViolation "ValueError" "DST command profile does not match this World")
  validated <- runDoor (profile.validate command)
  profileModel "Command" pCommand (toJson validated)
  when (validated.profile /= profile.identity) $
    throwWorld (ContractViolation "TypeError" "ScenarioProfile.validate must return a Command for its exact identity")
  pure validated

type Captured = (Checker, Observation, CheckResult, Text)

captureChecks :: (Monad m) => Text -> Integer -> g -> Integer -> WorldT m g [Captured]
captureChecks trigger sequence' g liveId = do
  world <- askW id
  forM world.checkers $ \checker -> do
    value <- scenarioDoor (world.profile.observe g checker.request) >>= strictValue "checker observation"
    current <- getsW (\s -> s.clock)
    let observation =
          Observation {name = checker.request.name, value, instant = current, generation = liveId, sequence = sequence'}
    result <- either (throwWorld . ProfileRaised) pure (checker.check observation)
    profileModel "CheckResult" pCheckResult (toJson result)
    pure (checker, observation, result, trigger)

recordChecks :: (Monad m) => [Captured] -> WorldT m g ()
recordChecks captured = do
  failed <- fmap concat . forM captured $ \(checker, observation, result, trigger) -> do
    record
      JCheck
      checker.identity.name
      ( Object
          [ ("checker", toJson checker.identity)
          , ("trigger", String trigger)
          , ("observation", toJson observation)
          , ("result", toJson result)
          ]
      )
      (ExplicitGeneration (Just observation.generation))
    pure [checker.identity.name | not result.passed]
  unless (null failed) $ do
    modifyW (\s -> s {ending = Just DInvariantFailure})
    throwWorld (InvariantViolation ("DST checker failure after atomic boundary: " <> pyRepr (PyList (map PyStr failed))))

evaluateCheckers :: (Monad m) => Text -> Integer -> g -> Integer -> WorldT m g ()
evaluateCheckers trigger sequence' g liveId = captureChecks trigger sequence' g liveId >>= recordChecks

sampleResources :: (Monad m) => Maybe g -> Text -> WorldT m g ()
sampleResources sampled trigger = do
  world <- askW id
  case world.budget of
    SomeBudget _ -> pure ()
    SomeBudgetV4 b -> do
      resourceDoor <-
        maybe
          (throwWorld (ContractViolation "TypeError" "a version-4 DST profile must define resource_usage"))
          pure
          world.profile.resourceUsage
      usage <- runDoor (resourceDoor sampled)
      profileModel "ResourceUsage" pResourceUsage (toJson usage)
      let expected = Map.keysSet b.profileResources
          actual = Map.keysSet usage.values
      when (actual /= expected) $
        throwWorld
          ( ContractViolation
              "ValueError"
              ( "profile resource usage keys must exactly match its budget; missing="
                  <> pyRepr (PyList (map PyStr (Set.toAscList (Set.difference expected actual))))
                  <> ", additional="
                  <> pyRepr (PyList (map PyStr (Set.toAscList (Set.difference actual expected))))
              )
          )
      record
        JResource
        trigger
        (Object [("usage", Object [(k, Int v) | (k, v) <- Map.toAscList usage.values])])
        (maybe (ExplicitGeneration Nothing) (const CurrentGeneration) sampled)
      let exceeded = sort [k | (k, v) <- Map.toList usage.values, v > Map.findWithDefault 0 k b.profileResources]
      case exceeded of
        k : _ -> exhaust ("profile_resources:" <> k) (Map.findWithDefault 0 k b.profileResources)
        [] -> pure ()

data RecordGeneration = CurrentGeneration | ExplicitGeneration (Maybe Integer)

-- | @World._record@. The reference validates every entry as it builds it,
-- so a journal value that embeds a command payload, result, observation or
-- detail a few containers down can trip pydantic's recursion guard although
-- the embedded value alone did not ('jsonValueRecursion'); the entry is then
-- refused before it is appended.
record :: (Monad m) => JournalKind -> Text -> Json -> RecordGeneration -> WorldT m g ()
record kind name value which = do
  forM_ (jsonValueRecursion 0 [LKey "value"] value) $ \e ->
    throwWorld (ContractViolation "ValidationError" (renderSchemaError "JournalEntry" e))
  appendEntry kind name value which

appendEntry :: (Monad m) => JournalKind -> Text -> Json -> RecordGeneration -> WorldT m g ()
appendEntry kind name value which = modifyW $ \s ->
  let entry =
        JournalEntry
          { position = toInteger (Seq.length s.entries)
          , instant = s.clock
          , generation = case which of
              CurrentGeneration -> case s.live of
                Just (_, liveId) -> liveId `seq` Just liveId
                Nothing -> Nothing
              ExplicitGeneration g -> g
          , kind
          , name
          , value
          }
   in -- Forced: an unevaluated entry would retain this whole state, and
      -- with it the live generation, after the generation is dropped.
      entry `seq` s {entries = s.entries |> entry}

appendOperation :: (Monad m) => ExpandedOperation -> WorldT m g ()
appendOperation operation = modifyW (\s -> s {accepted = s.accepted |> operation})

reserveAction :: (Monad m) => WorldT m g ()
reserveAction = do
  limits <- budgetLimits <$> askW (\w -> w.budget)
  used <- getsW (\s -> s.actionsUsed)
  when (used >= limits.actions) $ exhaust "actions" limits.actions
  modifyW (\s -> s {actionsUsed = s.actionsUsed + 1})

exhaust :: (Monad m) => Text -> Integer -> WorldT m g a
exhaust bound limit = do
  modifyW (\s -> s {ending = Just DBudgetExhausted})
  record JBudget bound (Object [("limit", Int limit)]) CurrentGeneration
  throwWorld (BudgetExhausted bound limit)

requireGeneration :: (Monad m) => Integer -> WorldT m g ()
requireGeneration expected = do
  live <- getsW (\s -> snd <$> s.live)
  when (live /= Just expected) $
    throwWorld
      (StaleGeneration ("DST generation " <> tshow expected <> " is stale; live generation is " <> maybe "None" tshow live))

liveGeneration :: (Monad m) => WorldT m g (g, Integer)
liveGeneration = getsW (\s -> s.live) >>= maybe (throwWorld (StaleGeneration "DST World has no live generation")) pure

requireUnfinished :: (Monad m) => WorldT m g ()
requireUnfinished = do
  ending <- getsW (\s -> s.ending)
  forM_ ending $ \d -> throwWorld (DstError ("DST World already ended as " <> dispositionText d))

tshow :: (Show a) => a -> Text
tshow = T.pack . show
