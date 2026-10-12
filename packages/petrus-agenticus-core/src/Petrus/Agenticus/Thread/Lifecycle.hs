-- | Immutable Thread, Episode, and Turn lifecycle contracts
-- (@petrus.agenticus.thread.lifecycle@).
--
-- Values are only built through validating constructors ('mkTurn',
-- 'mkEpisode', 'mkThread', the @*FromData@ decoders) and the transitions,
-- which refuse exactly what upstream refuses, in the same order and with the
-- same class and message.  Transitions take the subject last so they chain
-- with @>>=@:
--
-- > newThread tid Nothing >>= startEpisode eid program runtime budget >>= startTurn turn
--
-- Upstream rebuilds a frozen dataclass on every transition and so revalidates
-- every Episode of the Thread each time (quadratic in Thread length).  Each
-- Episode transition here still revalidates its Episode, but Thread
-- transitions only check what the transition can change: the invariants that
-- concern earlier Episodes are preserved by construction (see
-- @divergences/thread.md@).  'mkThread' and 'threadFromData' run the full
-- validation.
module Petrus.Agenticus.Thread.Lifecycle
  ( -- * States, outcomes and dispositions
    ThreadState (..)
  , EpisodeState (..)
  , TurnState (..)
  , TurnOutcome (..)
  , EpisodeOutcome (..)
  , CancellationDisposition (..)
  , SettlementDisposition (..)
  , StrEnum (enumText)
  , parseStrEnum
    -- * Errors
  , lifecycleTransitionError
  , episodeBudgetExceeded
  , budgetExceededDimension
    -- * Budgets
  , EpisodeBudget
  , mkEpisodeBudget
  , episodeBudget
  , episodeBudgetToData
  , episodeBudgetFromData
    -- * Turns
  , Turn
  , mkTurn
  , turnAcceptAppend
  , turnSettle
  , turnToData
  , turnFromData
    -- * Episodes
  , Episode
  , mkEpisode
  , activeTurn
  , budgetExhausted
  , episodeStartTurn
  , episodeAcceptAppend
  , episodeSettleTurn
  , episodeRequestCancellation
  , episodeSettle
  , episodeToData
  , episodeFromData
  , EpisodeCancellation (episode, disposition)
  , EpisodeSettlement (episode, disposition)
    -- * Threads
  , Thread
  , mkThread
  , newThread
  , activeEpisode
  , startEpisode
  , threadContinuationCompatibility
  , startTurn
  , acceptAppend
  , settleTurn
  , requestCancellation
  , settleEpisode
  , closeThread
  , threadToData
  , threadFromData
  , ThreadCancellation (thread, disposition)
  , ThreadSettlement (thread, disposition)
  ) where

import Data.Foldable (toList)
import Data.Sequence (Seq (..))
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Records (HasField (..))
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Catalog.Result (CompatibilityResult)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Shape
import Petrus.Agenticus.Internal.Validate
import Petrus.Agenticus.Program.Descriptor (AgentProgramDescriptor)
import Petrus.Agenticus.Thread.Continuation
import Petrus.Agenticus.Thread.Identity
import Petrus.Json (Json (..))
import Prelude hiding (id)
import Prelude qualified

------------------------------------------------------------------------------
-- Enumerations

data ThreadState = ThreadOpen | ThreadClosed
  deriving stock (Eq, Show, Enum, Bounded)

instance StrEnum ThreadState where
  enumText = \case
    ThreadOpen -> "open"
    ThreadClosed -> "closed"

data EpisodeState = EpisodeRunning | EpisodeCancelling | EpisodeSettled
  deriving stock (Eq, Show, Enum, Bounded)

instance StrEnum EpisodeState where
  enumText = \case
    EpisodeRunning -> "running"
    EpisodeCancelling -> "cancelling"
    EpisodeSettled -> "settled"

data TurnState = TurnRunning | TurnSettled
  deriving stock (Eq, Show, Enum, Bounded)

instance StrEnum TurnState where
  enumText = \case
    TurnRunning -> "running"
    TurnSettled -> "settled"

data TurnOutcome = TurnCompleted | TurnFailed | TurnCancelled | TurnIndeterminate
  deriving stock (Eq, Show, Enum, Bounded)

instance StrEnum TurnOutcome where
  enumText = \case
    TurnCompleted -> "completed"
    TurnFailed -> "failed"
    TurnCancelled -> "cancelled"
    TurnIndeterminate -> "indeterminate"

data EpisodeOutcome
  = EpisodeCompleted
  | EpisodeFailed
  | EpisodeCancelled
  | EpisodeBudgetExhausted
  | EpisodeIndeterminate
  deriving stock (Eq, Show, Enum, Bounded)

instance StrEnum EpisodeOutcome where
  enumText = \case
    EpisodeCompleted -> "completed"
    EpisodeFailed -> "failed"
    EpisodeCancelled -> "cancelled"
    EpisodeBudgetExhausted -> "budget-exhausted"
    EpisodeIndeterminate -> "indeterminate"

data CancellationDisposition = CancellationRequested | CancellationAlreadyRequested | CancellationTooLate
  deriving stock (Eq, Show, Enum, Bounded)

instance StrEnum CancellationDisposition where
  enumText = \case
    CancellationRequested -> "requested"
    CancellationAlreadyRequested -> "already-requested"
    CancellationTooLate -> "too-late"

data SettlementDisposition = SettlementAccepted | SettlementDuplicate
  deriving stock (Eq, Show, Enum, Bounded)

instance StrEnum SettlementDisposition where
  enumText = \case
    SettlementAccepted -> "accepted"
    SettlementDuplicate -> "duplicate"

------------------------------------------------------------------------------
-- Errors

-- | @LifecycleTransitionError(message)@.
lifecycleTransitionError :: Text -> AgenticusError
lifecycleTransitionError = agenticusError LifecycleTransitionError

-- | @EpisodeBudgetExceeded(dimension)@ (a @LifecycleTransitionError@).
episodeBudgetExceeded :: Text -> AgenticusError
episodeBudgetExceeded dimension = agenticusError EpisodeBudgetExceeded (budgetPrefix <> dimension)

budgetPrefix :: Text
budgetPrefix = "Episode budget exhausted for "

-- | The exceeded dimension (@error.dimension@) of an 'episodeBudgetExceeded'.
budgetExceededDimension :: AgenticusError -> Maybe Text
budgetExceededDimension e
  | e.errorClass == EpisodeBudgetExceeded = T.stripPrefix budgetPrefix e.errorMessage
  | otherwise = Nothing

refuse :: Text -> Either AgenticusError a
refuse = Left . lifecycleTransitionError

check :: Bool -> Text -> Either AgenticusError ()
check ok message = if ok then Right () else Left (valueError message)

------------------------------------------------------------------------------
-- Budgets

-- | The exact progression bounds owned by an Episode.
data EpisodeBudget = EpisodeBudget
  { _maxTurns :: Integer
  , _maxAcceptedAppends :: Integer
  }
  deriving stock (Eq, Show)

instance HasField "maxTurns" EpisodeBudget Integer where
  getField r = r._maxTurns

instance HasField "maxAcceptedAppends" EpisodeBudget Integer where
  getField r = r._maxAcceptedAppends

mkEpisodeBudget :: Integer -> Integer -> Either AgenticusError EpisodeBudget
mkEpisodeBudget t a =
  EpisodeBudget
    <$> positiveInteger "Episode budget max_turns" t
    <*> positiveInteger "Episode budget max_accepted_appends" a

-- | 'mkEpisodeBudget' for literals known to be valid.
episodeBudget :: Integer -> Integer -> EpisodeBudget
episodeBudget t a = either (error . T.unpack . errorMessage) Prelude.id (mkEpisodeBudget t a)

episodeBudgetToData :: EpisodeBudget -> Json
episodeBudgetToData b =
  Object
    [ ("schema_version", Int 1)
    , ("max_turns", Int b.maxTurns)
    , ("max_accepted_appends", Int b.maxAcceptedAppends)
    ]

episodeBudgetFromData :: Json -> Either AgenticusError EpisodeBudget
episodeBudgetFromData raw = do
  fields <-
    exactObject
      ["schema_version", "max_turns", "max_accepted_appends"]
      (valueError "Episode budget requires its exact versioned fields")
      raw
  requireSchemaVersion "Episode budget" fields
  EpisodeBudget
    <$> positiveIntegerJson "Episode budget max_turns" (member "max_turns" fields)
    <*> positiveIntegerJson "Episode budget max_accepted_appends" (member "max_accepted_appends" fields)

------------------------------------------------------------------------------
-- Turns

-- | One progression step and only its provider-neutral lifecycle facts.
data Turn = Turn
  { _id :: TurnId
  , _episode :: EpisodeId
  , _ordinal :: Integer
  , _state :: TurnState
  , _acceptedAppends :: Integer
  , _outcome :: Maybe TurnOutcome
  }
  deriving stock (Eq, Show)

instance HasField "id" Turn TurnId where
  getField r = r._id

instance HasField "episode" Turn EpisodeId where
  getField r = r._episode

instance HasField "ordinal" Turn Integer where
  getField r = r._ordinal

instance HasField "state" Turn TurnState where
  getField r = r._state

instance HasField "acceptedAppends" Turn Integer where
  getField r = r._acceptedAppends

instance HasField "outcome" Turn (Maybe TurnOutcome) where
  getField r = r._outcome

-- | @Turn(id, episode, ordinal, state, accepted_appends, outcome)@.
mkTurn
  :: TurnId -> EpisodeId -> Integer -> TurnState -> Integer -> Maybe TurnOutcome -> Either AgenticusError Turn
mkTurn i e o s a out = do
  _ <- positiveInteger "Turn ordinal" o
  _ <- nonnegativeInteger "Turn accepted_appends" a
  check (not (s == TurnRunning && out /= Nothing)) "a running Turn cannot have an outcome"
  check (not (s == TurnSettled && out == Nothing)) "a settled Turn requires a TurnOutcome"
  pure (Turn i e o s a out)

turnAcceptAppend :: Turn -> Either AgenticusError Turn
turnAcceptAppend t
  | t.state /= TurnRunning = refuse "accepted appends require a running Turn"
  | otherwise = Right (Turn t.id t.episode t.ordinal t.state (t.acceptedAppends + 1) t.outcome)

turnSettle :: TurnOutcome -> Turn -> Either AgenticusError Turn
turnSettle o t
  | t.state == TurnSettled = refuse "Turn is already settled"
  | otherwise = Right (Turn t.id t.episode t.ordinal TurnSettled t.acceptedAppends (Just o))

turnToData :: Turn -> Json
turnToData t =
  Object
    [ ("schema_version", Int 1)
    , ("id", lifecycleIdToData t.id)
    , ("episode", lifecycleIdToData t.episode)
    , ("ordinal", Int t.ordinal)
    , ("state", strEnumData t.state)
    , ("accepted_appends", Int t.acceptedAppends)
    , ("outcome", maybe Null strEnumData t.outcome)
    ]

turnFromData :: Json -> Either AgenticusError Turn
turnFromData raw = do
  fields <-
    exactObject
      ["schema_version", "id", "episode", "ordinal", "state", "accepted_appends", "outcome"]
      (valueError "Turn requires its exact versioned lifecycle fields")
      raw
  requireSchemaVersion "Turn" fields
  let unsupported = valueError "Turn state or outcome is not supported"
  s <- maybe (Left unsupported) Right (strEnumJson (member "state" fields))
  out <- case member "outcome" fields of
    Null -> Right Nothing
    other -> maybe (Left unsupported) (Right . Just) (strEnumJson other)
  i <- lifecycleIdFromData (member "id" fields)
  e <- lifecycleIdFromData (member "episode" fields)
  o <- positiveIntegerJson "Turn ordinal" (member "ordinal" fields)
  a <- nonnegativeIntegerJson "Turn accepted_appends" (member "accepted_appends" fields)
  mkTurn i e o s a out

------------------------------------------------------------------------------
-- Episodes

-- | One bounded execution with no workspace, process, or transcript custody.
data Episode = Episode
  { _id :: EpisodeId
  , _thread :: ThreadId
  , _program :: DescriptorIdentity
  , _runtime :: DescriptorIdentity
  , _budget :: EpisodeBudget
  , _expectedContinuation :: Maybe DescriptorIdentity
  , _continuation :: Maybe Continuation
  , _state :: EpisodeState
  , _turns :: Seq Turn
  , _acceptedAppends :: Integer
  , _settlement :: Maybe EpisodeOutcome
  , _nextContinuation :: Maybe Continuation
  }
  deriving stock (Eq, Show)

instance HasField "id" Episode EpisodeId where
  getField r = r._id

instance HasField "thread" Episode ThreadId where
  getField r = r._thread

instance HasField "program" Episode DescriptorIdentity where
  getField r = r._program

instance HasField "runtime" Episode DescriptorIdentity where
  getField r = r._runtime

instance HasField "budget" Episode EpisodeBudget where
  getField r = r._budget

instance HasField "expectedContinuation" Episode (Maybe DescriptorIdentity) where
  getField r = r._expectedContinuation

instance HasField "continuation" Episode (Maybe Continuation) where
  getField r = r._continuation

instance HasField "state" Episode EpisodeState where
  getField r = r._state

instance HasField "turns" Episode (Seq Turn) where
  getField r = r._turns

instance HasField "acceptedAppends" Episode Integer where
  getField r = r._acceptedAppends

instance HasField "settlement" Episode (Maybe EpisodeOutcome) where
  getField r = r._settlement

instance HasField "nextContinuation" Episode (Maybe Continuation) where
  getField r = r._nextContinuation

data EpisodeCancellation = EpisodeCancellation
  { episode :: Episode
  , disposition :: CancellationDisposition
  }
  deriving stock (Eq, Show)

data EpisodeSettlement = EpisodeSettlement
  { episode :: Episode
  , disposition :: SettlementDisposition
  }
  deriving stock (Eq, Show)

-- | @Episode(id, thread, program, runtime, budget, expected_continuation,
-- continuation, state, turns, accepted_appends, settlement,
-- next_continuation)@ with the full upstream validation.
mkEpisode
  :: EpisodeId
  -> ThreadId
  -> DescriptorIdentity
  -> DescriptorIdentity
  -> EpisodeBudget
  -> Maybe DescriptorIdentity
  -> Maybe Continuation
  -> EpisodeState
  -> Seq Turn
  -> Integer
  -> Maybe EpisodeOutcome
  -> Maybe Continuation
  -> Either AgenticusError Episode
mkEpisode i t p r b ex c s ts a out next = validateEpisode (Episode i t p r b ex c s ts a out next)

validateEpisode :: Episode -> Either AgenticusError Episode
validateEpisode e = do
  -- _validate_identities
  _ <- identityOfKind KindProgram "Episode program" e.program
  _ <- identityOfKind KindRuntime "Episode runtime" e.runtime
  _ <- traverse (identityOfKind KindContinuation "Episode expected_continuation") e.expectedContinuation
  ownContinuation "continuation" e.continuation
  ownContinuation "next_continuation" e.nextContinuation
  _ <- nonnegativeInteger "Episode accepted_appends" e.acceptedAppends
  -- turns
  require (all (\turn -> turn.episode == e.id) e.turns) (typeError "Episode turns must be Turn values for this Episode")
  let count = Seq.length e.turns
  check (Set.size (Set.fromList [turn.id | turn <- toList e.turns]) == count) "Episode Turn ids must be unique"
  check (and (zipWith (==) [turn.ordinal | turn <- toList e.turns] [1 ..])) "Episode Turn ordinals must be contiguous from one"
  check (toInteger count <= e.budget.maxTurns) "Episode turns exceed max_turns"
  check (sum [turn.acceptedAppends | turn <- toList e.turns] == e.acceptedAppends) "Episode accepted_appends must equal its Turn accounting"
  check (e.acceptedAppends <= e.budget.maxAcceptedAppends) "Episode accepted_appends exceed budget"
  let running = Seq.length (Seq.filter (\turn -> turn.state == TurnRunning) e.turns)
      lastRunning = case e.turns of
        _ :|> turn -> turn.state == TurnRunning
        Empty -> False
  check (running <= 1 && (running == 0 || lastRunning)) "only the final Episode Turn may be running"
  -- _validate_state
  if e.state == EpisodeSettled
    then do
      check (e.settlement /= Nothing) "a settled Episode requires an EpisodeOutcome"
      check (running == 0) "a settled Episode cannot have a running Turn"
      check (maybe True (\c -> c.state == ContinuationRetired) e.continuation) "a settled Episode input Continuation must be retired"
      validateResultContinuation e
    else do
      check (e.settlement == Nothing && e.nextContinuation == Nothing) "an active Episode cannot have settlement output"
      check (maybe True (\c -> c.state == ContinuationInUse) e.continuation) "an active Episode input Continuation must be in use"
  pure e
  where
    ownContinuation label = \case
      Just c
        | c.thread /= e.thread ->
            Left (typeError ("Episode " <> label <> " must be a Continuation for this Thread"))
      _ -> Right ()

validateResultContinuation :: Episode -> Either AgenticusError ()
validateResultContinuation e = do
  check
    (not (e.settlement == Just EpisodeCompleted && e.expectedContinuation /= Nothing && e.nextContinuation == Nothing))
    "a completed Episode requires its declared result Continuation"
  case e.nextContinuation of
    Nothing -> pure ()
    Just next -> case e.expectedContinuation of
      Nothing -> Left (valueError "Episode program does not declare a result Continuation")
      Just expected -> do
        check (next.state == ContinuationAvailable) "an Episode result Continuation must be available"
        check (next.descriptor.identity == expected) "Episode result Continuation descriptor does not match its program"
        check (next.descriptor.program == e.program) "Episode result Continuation names another Agent Program"

-- | The final Turn while it is running.
activeTurn :: Episode -> Maybe Turn
activeTurn e = case e.turns of
  _ :|> turn | turn.state == TurnRunning -> Just turn
  _ -> Nothing

budgetExhausted :: Episode -> Bool
budgetExhausted e =
  toInteger (Seq.length e.turns) >= e.budget.maxTurns || e.acceptedAppends >= e.budget.maxAcceptedAppends

withTurns :: Seq Turn -> Integer -> Episode -> Either AgenticusError Episode
withTurns ts a e =
  validateEpisode
    (Episode e.id e.thread e.program e.runtime e.budget e.expectedContinuation e.continuation e.state ts a e.settlement e.nextContinuation)

episodeStartTurn :: TurnId -> Episode -> Either AgenticusError Episode
episodeStartTurn turnId e
  | e.state /= EpisodeRunning = refuse "new Turns require a running Episode"
  | activeTurn e /= Nothing = refuse "an Episode may have only one running Turn"
  | toInteger (Seq.length e.turns) >= e.budget.maxTurns = Left (episodeBudgetExceeded "turns")
  | e.acceptedAppends >= e.budget.maxAcceptedAppends = Left (episodeBudgetExceeded "accepted_appends")
  | any (\turn -> turn.id == turnId) e.turns = refuse "Turn id is already present in this Episode"
  | otherwise = do
      turn <- mkTurn turnId e.id (toInteger (Seq.length e.turns) + 1) TurnRunning 0 Nothing
      withTurns (e.turns :|> turn) e.acceptedAppends e

requireActiveTurn :: TurnId -> Episode -> Either AgenticusError Turn
requireActiveTurn turnId e = case activeTurn e of
  Just turn | turn.id == turnId -> Right turn
  _ -> refuse "Turn is not the running Turn of this Episode"

replaceLastTurn :: Turn -> Seq Turn -> Seq Turn
replaceLastTurn turn = \case
  rest :|> _ -> rest :|> turn
  Empty -> Seq.singleton turn

episodeAcceptAppend :: TurnId -> Episode -> Either AgenticusError Episode
episodeAcceptAppend turnId e = do
  if e.state /= EpisodeRunning then refuse "accepted appends require a running Episode" else Right ()
  turn <- requireActiveTurn turnId e
  if e.acceptedAppends >= e.budget.maxAcceptedAppends then Left (episodeBudgetExceeded "accepted_appends") else Right ()
  appended <- turnAcceptAppend turn
  withTurns (replaceLastTurn appended e.turns) (e.acceptedAppends + 1) e

episodeSettleTurn :: TurnId -> TurnOutcome -> Episode -> Either AgenticusError Episode
episodeSettleTurn turnId o e = do
  turn <- requireActiveTurn turnId e
  if e.state == EpisodeCancelling && o == TurnCompleted
    then refuse "a cancellation-winning Turn cannot complete"
    else Right ()
  settled <- turnSettle o turn
  withTurns (replaceLastTurn settled e.turns) e.acceptedAppends e

episodeRequestCancellation :: Episode -> EpisodeCancellation
episodeRequestCancellation e = case e.state of
  EpisodeSettled -> EpisodeCancellation e CancellationTooLate
  EpisodeCancelling -> EpisodeCancellation e CancellationAlreadyRequested
  EpisodeRunning ->
    EpisodeCancellation
      ( Episode
          e.id
          e.thread
          e.program
          e.runtime
          e.budget
          e.expectedContinuation
          e.continuation
          EpisodeCancelling
          e.turns
          e.acceptedAppends
          e.settlement
          e.nextContinuation
      )
      CancellationRequested

episodeSettle :: EpisodeOutcome -> Maybe Continuation -> Episode -> Either AgenticusError EpisodeSettlement
episodeSettle o next e
  | e.state == EpisodeSettled =
      if e.settlement == Just o && e.nextContinuation == next
        then Right (EpisodeSettlement e SettlementDuplicate)
        else refuse "Episode is already settled with a different outcome or Continuation"
  | activeTurn e /= Nothing = refuse "Episode cannot settle while a Turn is running"
  | o == EpisodeCompleted && e.state /= EpisodeRunning = refuse "cancellation won before completed settlement"
  | o == EpisodeCancelled && e.state /= EpisodeCancelling = refuse "cancelled settlement requires a cancellation request"
  | o == EpisodeBudgetExhausted && (e.state /= EpisodeRunning || not (budgetExhausted e)) =
      refuse "budget-exhausted settlement requires an exhausted Episode budget"
  | otherwise = do
      settled <-
        validateEpisode
          ( Episode
              e.id
              e.thread
              e.program
              e.runtime
              e.budget
              e.expectedContinuation
              (retireContinuation <$> e.continuation)
              EpisodeSettled
              e.turns
              e.acceptedAppends
              (Just o)
              next
          )
      pure (EpisodeSettlement settled SettlementAccepted)

episodeToData :: Episode -> Json
episodeToData e =
  Object
    [ ("schema_version", Int 1)
    , ("id", lifecycleIdToData e.id)
    , ("thread", lifecycleIdToData e.thread)
    , ("program", identityToData e.program)
    , ("runtime", identityToData e.runtime)
    , ("budget", episodeBudgetToData e.budget)
    , ("expected_continuation", maybe Null identityToData e.expectedContinuation)
    , ("continuation", maybe Null continuationToData e.continuation)
    , ("state", strEnumData e.state)
    , ("turns", Array (map turnToData (toList e.turns)))
    , ("accepted_appends", Int e.acceptedAppends)
    , ("settlement", maybe Null strEnumData e.settlement)
    , ("next_continuation", maybe Null continuationToData e.nextContinuation)
    ]

optional :: (Json -> Either AgenticusError a) -> Json -> Either AgenticusError (Maybe a)
optional decode = \case
  Null -> Right Nothing
  other -> Just <$> decode other

episodeFromData :: Json -> Either AgenticusError Episode
episodeFromData raw = do
  fields <-
    exactObject
      [ "schema_version"
      , "id"
      , "thread"
      , "program"
      , "runtime"
      , "budget"
      , "expected_continuation"
      , "continuation"
      , "state"
      , "turns"
      , "accepted_appends"
      , "settlement"
      , "next_continuation"
      ]
      (valueError "Episode requires its exact versioned lifecycle fields")
      raw
  requireSchemaVersion "Episode" fields
  rawTurns <- case member "turns" fields of
    Array items -> Right items
    _ -> Left (typeError "Episode turns must be a JSON array")
  let unsupported = valueError "Episode state or settlement is not supported"
  s <- maybe (Left unsupported) Right (strEnumJson (member "state" fields))
  out <- case member "settlement" fields of
    Null -> Right Nothing
    other -> maybe (Left unsupported) (Right . Just) (strEnumJson other)
  i <- lifecycleIdFromData (member "id" fields)
  t <- lifecycleIdFromData (member "thread" fields)
  p <- identityFromData (member "program" fields)
  r <- identityFromData (member "runtime" fields)
  b <- episodeBudgetFromData (member "budget" fields)
  ex <- optional identityFromData (member "expected_continuation" fields)
  c <- optional continuationFromData (member "continuation" fields)
  ts <- traverse turnFromData rawTurns
  a <- nonnegativeIntegerJson "Episode accepted_appends" (member "accepted_appends" fields)
  next <- optional continuationFromData (member "next_continuation" fields)
  mkEpisode i t p r b ex c s (Seq.fromList ts) a out next

------------------------------------------------------------------------------
-- Threads

-- | Durable related-work lineage across sequential Episodes and runtimes.
data Thread = Thread
  { _id :: ThreadId
  , _state :: ThreadState
  , _episodes :: Seq Episode
  , _continuation :: Maybe Continuation
  }
  deriving stock (Eq, Show)

instance HasField "id" Thread ThreadId where
  getField r = r._id

instance HasField "state" Thread ThreadState where
  getField r = r._state

instance HasField "episodes" Thread (Seq Episode) where
  getField r = r._episodes

instance HasField "continuation" Thread (Maybe Continuation) where
  getField r = r._continuation

data ThreadCancellation = ThreadCancellation
  { thread :: Thread
  , disposition :: CancellationDisposition
  }
  deriving stock (Eq, Show)

data ThreadSettlement = ThreadSettlement
  { thread :: Thread
  , disposition :: SettlementDisposition
  }
  deriving stock (Eq, Show)

-- | @Thread(id, state, episodes, continuation)@ with the full upstream
-- validation.
mkThread :: ThreadId -> ThreadState -> Seq Episode -> Maybe Continuation -> Either AgenticusError Thread
mkThread i s es c = validateThread (Thread i s es c)

-- | @Thread(id, continuation=...)@: an open Thread with no Episodes.
newThread :: ThreadId -> Maybe Continuation -> Either AgenticusError Thread
newThread i = mkThread i ThreadOpen Seq.empty

validateThread :: Thread -> Either AgenticusError Thread
validateThread t = do
  -- _validated_episodes
  require (all (\e -> e.thread == t.id) t.episodes) (typeError "Thread episodes must be Episode values for this Thread")
  let es = toList t.episodes
  check (Set.size (Set.fromList [e.id | e <- es]) == length es) "Thread Episode ids must be unique"
  let active = [e | e <- es, e.state /= EpisodeSettled]
      lastActive = case t.episodes of
        _ :|> e -> e.state /= EpisodeSettled
        Empty -> False
  check (length active <= 1 && (null active || lastActive)) "only the final Thread Episode may be active"
  check
    (and (zipWith (\previous current -> sameRevision previous.nextContinuation current.continuation) es (drop 1 es)))
    "adjacent Thread Episodes must share one Continuation revision"
  let outputs = [c.id | e <- es, Just c <- [e.nextContinuation]]
  check (Set.size (Set.fromList outputs) == length outputs) "Thread result Continuation ids must be unique"
  -- _validate_continuation
  case t.continuation of
    Just c | c.thread /= t.id -> Left (typeError "Thread continuation must be a Continuation for this Thread")
    _ -> Right ()
  -- _validate_state
  let finalNext = case t.episodes of
        _ :|> e -> Just e.nextContinuation
        Empty -> Nothing
  case (t.state, active) of
    (ThreadClosed, _) -> do
      check (null active) "a closed Thread cannot have an active Episode"
      check (maybe True (\c -> c.state == ContinuationRetired) t.continuation) "a closed Thread Continuation must be retired"
      check (maybe True (sameRevision t.continuation) finalNext) "a closed Thread must retain its final Continuation revision"
    (ThreadOpen, _ : _) ->
      check (Just t.continuation == fmap (.continuation) (lastOf active)) "an active Episode must own the Thread Continuation"
    (ThreadOpen, []) -> do
      check (maybe True (\c -> c.state == ContinuationAvailable) t.continuation) "an open resting Thread Continuation must be available"
      check (maybe True (== t.continuation) finalNext) "an open resting Thread must expose its final Continuation"
  pure t
  where
    lastOf xs = case reverse xs of
      x : _ -> Just x
      [] -> Nothing

finalEpisode :: Thread -> Maybe Episode
finalEpisode t = case t.episodes of
  _ :|> e -> Just e
  Empty -> Nothing

-- | The final Episode while it is not settled.
activeEpisode :: Thread -> Either AgenticusError Episode
activeEpisode t = case finalEpisode t of
  Just e | e.state /= EpisodeSettled -> Right e
  _ -> refuse "Thread has no active Episode"

-- | The compatibility verdict 'startEpisode' enforces for this program:
-- the 'CompatibilityResult' an @IncompatibleContinuation@ refusal carries.
threadContinuationCompatibility :: AgentProgramDescriptor -> Thread -> CompatibilityResult
threadContinuationCompatibility p t = checkContinuationCompatibility p ((.descriptor) <$> t.continuation)

startEpisode
  :: EpisodeId -> AgentProgramDescriptor -> DescriptorIdentity -> EpisodeBudget -> Thread -> Either AgenticusError Thread
startEpisode episodeId p r b t
  | t.state /= ThreadOpen = refuse "a closed Thread cannot start an Episode"
  | maybe False (\e -> e.state /= EpisodeSettled) (finalEpisode t) = refuse "a Thread may have only one active Episode"
  | any (\e -> e.id == episodeId) t.episodes = refuse "Episode id is already present in this Thread"
  | otherwise = do
      either (Left . incompatibleContinuationError) Right $
        requireContinuationCompatible p ((.descriptor) <$> t.continuation)
      claimed <- traverse claimContinuation t.continuation
      e <-
        mkEpisode
          episodeId
          t.id
          p.identity
          r
          b
          p.producedContinuation
          claimed
          EpisodeRunning
          Seq.empty
          0
          Nothing
          Nothing
      pure (Thread t.id t.state (t.episodes :|> e) claimed)

-- | Replace the active Episode; the Thread exposes its Continuation.
replaceActive :: Thread -> Episode -> Thread
replaceActive t e = Thread t.id t.state (replaceLast t.episodes) e.continuation
  where
    replaceLast = \case
      rest :|> _ -> rest :|> e
      Empty -> Seq.singleton e

onActive :: (Episode -> Either AgenticusError Episode) -> Thread -> Either AgenticusError Thread
onActive step t = do
  e <- activeEpisode t
  replaceActive t <$> step e

startTurn :: TurnId -> Thread -> Either AgenticusError Thread
startTurn turnId = onActive (episodeStartTurn turnId)

acceptAppend :: TurnId -> Thread -> Either AgenticusError Thread
acceptAppend turnId = onActive (episodeAcceptAppend turnId)

settleTurn :: TurnId -> TurnOutcome -> Thread -> Either AgenticusError Thread
settleTurn turnId o = onActive (episodeSettleTurn turnId o)

requestCancellation :: Thread -> Either AgenticusError ThreadCancellation
requestCancellation t = case finalEpisode t of
  Just e | e.state == EpisodeSettled -> Right (ThreadCancellation t CancellationTooLate)
  _ -> do
    e <- activeEpisode t
    let cancellation = episodeRequestCancellation e
    pure (ThreadCancellation (replaceActive t cancellation.episode) cancellation.disposition)

settleEpisode :: EpisodeOutcome -> Maybe Continuation -> Thread -> Either AgenticusError ThreadSettlement
settleEpisode o next t = case finalEpisode t of
  Just e | e.state == EpisodeSettled -> do
    retry <- episodeSettle o next e
    pure (ThreadSettlement t retry.disposition)
  _ -> do
    e <- activeEpisode t
    validateThreadResult t e o next
    s <- episodeSettle o next e
    pure (ThreadSettlement (Thread t.id t.state (replaceLast s.episode t.episodes) next) s.disposition)
  where
    replaceLast e = \case
      rest :|> _ -> rest :|> e
      Empty -> Seq.singleton e

validateThreadResult :: Thread -> Episode -> EpisodeOutcome -> Maybe Continuation -> Either AgenticusError ()
validateThreadResult t e o = \case
  Nothing
    | o == EpisodeCompleted && e.expectedContinuation /= Nothing ->
        refuse "completed Episode requires its declared result Continuation"
    | otherwise -> Right ()
  Just c -> case e.expectedContinuation of
    Nothing -> refuse "Agent Program does not declare a result Continuation"
    Just expected
      | c.thread /= t.id -> refuse "result Continuation belongs to another Thread"
      | c.state /= ContinuationAvailable -> refuse "result Continuation must be available"
      | c.descriptor.identity /= expected -> refuse "result Continuation descriptor does not match Agent Program"
      | c.descriptor.program /= e.program -> refuse "result Continuation names another Agent Program"
      | c.id `elem` knownIds -> refuse "result Continuation id is already present in this Thread"
      | otherwise -> Right ()
  where
    knownIds = [k.id | prior <- toList t.episodes, Just k <- [prior.continuation, prior.nextContinuation]]

closeThread :: Thread -> Either AgenticusError Thread
closeThread t
  | t.state == ThreadClosed = Right t
  | maybe False (\e -> e.state /= EpisodeSettled) (finalEpisode t) = refuse "a Thread cannot close with an active Episode"
  | otherwise = Right (Thread t.id ThreadClosed t.episodes (retireContinuation <$> t.continuation))

threadToData :: Thread -> Json
threadToData t =
  Object
    [ ("schema_version", Int 1)
    , ("id", lifecycleIdToData t.id)
    , ("state", strEnumData t.state)
    , ("episodes", Array (map episodeToData (toList t.episodes)))
    , ("continuation", maybe Null continuationToData t.continuation)
    ]

threadFromData :: Json -> Either AgenticusError Thread
threadFromData raw = do
  fields <-
    exactObject
      ["schema_version", "id", "state", "episodes", "continuation"]
      (valueError "Thread requires its exact versioned lifecycle fields")
      raw
  requireSchemaVersion "Thread" fields
  rawEpisodes <- case member "episodes" fields of
    Array items -> Right items
    _ -> Left (typeError "Thread episodes must be a JSON array")
  s <- maybe (Left (valueError "Thread state is not supported")) Right (strEnumJson (member "state" fields))
  i <- lifecycleIdFromData (member "id" fields)
  es <- traverse episodeFromData rawEpisodes
  c <- optional continuationFromData (member "continuation" fields)
  mkThread i s (Seq.fromList es) c
