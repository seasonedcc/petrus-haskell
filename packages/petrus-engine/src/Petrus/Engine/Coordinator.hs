-- | The asynchronous coordinator over one Instance (the reference's private
-- @petrus.engine._coordination.Coordinator@).
--
-- Each 'drive' reconciles once (first drive only), then observes a
-- 'Snapshot' — collecting the Dispatch's arrived outcomes, enumerating
-- candidates, deriving the pending maturation, consulting the sensor — lets
-- the driving policy choose one offered action, and applies at most that one
-- action against the single writer, stamped from the clock.
--
-- = Commit points
--
-- @commit@ is the joined-transaction commit point ('Nothing' for
-- backend-owned stores, whose every append is durable at the door). It is
-- called exactly where the reference calls it:
--
-- * after reconcile, and after a reconcile-leg terminal failure before its
--   halt propagates;
-- * a 'BeginCandidate': once, after begin and dispatch (or pure completion)
--   — begin, dispatch, and the selection commit or vanish together, and the
--   selection state installs only after that commit returns;
-- * an 'AcceptResult': after the freeze (@record_activity_completion@ /
--   @record_activity_failure@), then again after the projection or failure —
--   the frozen terminal survives a projection crash;
-- * an 'AcceptDelivery': after a fresh acceptance (before projection), and
--   after the turn when it appended anything; a recorded source-projection
--   failure commits before it propagates;
-- * a 'Wait' or 'Stop': before the drive returns (no idle transaction is left
--   open across a host wait).
module Petrus.Engine.Coordinator
  ( Coordinator
  , newCoordinator
  , drive
  , cancelClosure
  , supportsCancellation
  , selectionStateText
  , completePure
  ) where

import Prelude hiding (span)
import Control.DeepSeq (force)
import Control.Exception (SomeAsyncException, SomeException, catch, evaluate, fromException, throwIO, toException, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Foldable (toList)
import Data.IORef
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityFailure, ActivityFailureFields (..), failureFields)
import Petrus.Engine.Vocabulary
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..))
import Petrus.Impetus.History.Records (FiringFailed (..), Record (..))
import Petrus.Impetus.History.Replay (replayCancellationPositions)
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance hiding (terminalFailure)
import Petrus.Impetus.Petrinet (Binding (..), Instant, NetPath, markingToList, netName, netPathText, outputs)
import Petrus.Impetus.Selection (SelectionPolicy (..), SelectionProposal (..), foldHistory)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch
import Petrus.Telemetry (Level (..), Span, TelemetryLogger, accumulateTime, atLevel, bind, emit, getLogger, increment, spanSet, withSpanClassifying)
import Petrus.Telemetry qualified as Telemetry

-- | The candidate-selection policy (read before each proposal: fixed for
-- 'EngineSelection', built from the host's input for 'SteeredSelection')
-- and its live state.
data SelectionSlot = forall s. (Eq s, Show s) => SelectionSlot (IO (SelectionPolicy s)) (IORef s)

-- | The coordinator: the only component that applies actions to the
-- Instance.
data Coordinator = Coordinator
  { inst :: Instance
  , port :: Dispatch
  , policy :: DrivingPolicy
  , selection :: SelectionSlot
  , clock :: Clock
  , sensor :: Maybe Sensor
  , commit :: Maybe (IO ())
  , arrived :: IORef (Seq (Int, ActivityOutcome))
  -- ^ Collected but unaccepted outcomes, in arrival order.
  , deliveries :: IORef (Seq Delivery)
  -- ^ Sensed but unaccepted parcels, FIFO.
  , dispatched :: IORef (IntMap FiringOccurrence)
  -- ^ Every Activity occurrence this coordinator answers for, ended ones
  -- included.
  , reconciled :: IORef Bool
  , previous :: IORef (Maybe Action)
  , offer :: IORef (Maybe (Binding, IO ()))
  -- ^ The current turn's candidate and the action installing its proposal.
  , logger :: TelemetryLogger
  }

-- | Build the coordinator: fold the selection state from History and
-- refuse a Dispatch that cannot fence recorded lifecycle cancellations.
newCoordinator ::
  Instance -> Dispatch -> DrivingPolicy -> EngineSelection -> Clock -> Maybe Sensor -> Maybe (IO ()) -> Maybe Telemetry.EventSink -> IO Coordinator
newCoordinator inst port policy engineSelection clock sensor commit sink = do
  history <- (instanceHistory inst).snapshot
  selection <- case engineSelection of
    EngineSelection selectionPolicy initial -> slot (pure selectionPolicy) initial history
    SteeredSelection input build initial -> slot (build <$> input) initial history
  occurrences <- activityOccurrences inst
  recordedCancellations <- cancelled inst
  when (any (isJust . (.invocation)) recordedCancellations && isNothing port.cancel) $
    throwIO
      ( EngineTypeError
          "cannot load lifecycle-cancelled Activities with this Dispatch: it does not implement the recoverable cancellation extension"
      )
  arrived <- newIORef Seq.empty
  deliveries <- newIORef Seq.empty
  dispatched <- newIORef occurrences
  reconciled <- newIORef False
  previous <- newIORef Nothing
  offer <- newIORef Nothing
  let base = getLogger "impetus" sink
      net = instanceNet inst
      fields = ("instance", String (instanceIdentity inst)) : [("net", String n) | Just n <- [netName net]]
  pure
    Coordinator
      { inst
      , port
      , policy
      , selection
      , clock
      , sensor
      , commit
      , arrived
      , deliveries
      , dispatched
      , reconciled
      , previous
      , offer
      , logger = either (const base) id (bind fields base)
      }

-- | A selection slot whose state is folded from History.
slot :: (Eq s, Show s) => IO (SelectionPolicy s) -> s -> Seq Record -> IO SelectionSlot
slot current initial history = do
  atLoad <- current
  state <- either (throwIO . EngineValueError) pure (foldHistory atLoad initial history)
  SelectionSlot current <$> newIORef state

-- | Whether this composition can fence lifecycle-cancelled Activities.
supportsCancellation :: Coordinator -> Bool
supportsCancellation c = isCancellable c.port

-- | The live selection state, shown (test and diagnostic access).
selectionStateText :: Coordinator -> IO Text
selectionStateText c = case c.selection of
  SelectionSlot _ ref -> T.pack . show <$> readIORef ref

committed :: Coordinator -> IO ()
committed c = sequence_ c.commit

stamp :: Coordinator -> IO (Maybe Instant)
stamp c = Just <$> c.clock.now

historyLength :: Coordinator -> IO Int
historyLength c = Store.size (instanceHistory c.inst)

-- ---------------------------------------------------------------------------
-- Drive

-- | Reconcile once, then observe, choose, and apply at most one action.
drive :: Coordinator -> IO DriveOutcome
drive c = withSpanClassifying engineErrorType c.logger "drive" [] $ \span -> do
  firings <- newIORef Seq.empty
  done <- readIORef c.reconciled
  unless done $ do
    -- Flagged before the work: a reconcile leg is safe to leave half-done
    -- (durable state answers the next load) but never to repeat in-process.
    writeIORef c.reconciled True
    reconcile c firings span
    committed c
    n <- Seq.length <$> readIORef firings
    spanSet span [("reconciled_firings", Int (fromIntegral n))]
  snapshot <- accumulateTime span "observe_ms" (observeTurn c)
  action <- c.policy snapshot
  requireOffered snapshot action
  let loop current chosen = case chosen of
        _
          | isPosture chosen -> do
              committed c
              let waiting = chosen == Wait
              done' <- toList <$> readIORef firings
              spanSet span [("firings", Int (fromIntegral (length done'))), ("waiting", Bool waiting), ("ready", Bool False)]
              DriveOutcome done' waiting False <$> nextMaturation c.inst
        _ -> do
          before <- historyLength c
          (install, applied) <- accumulateTime span "apply_ms" (apply c chosen firings span)
          if applied
            then do
              increment span "actions" 1
              after <- historyLength c
              unless (isDelivery chosen && after == before) (committed c)
              sequence_ install
              writeIORef c.previous (Just chosen)
              profiling <- atLevel Profile
              when profiling (emitGauges c)
              done' <- toList <$> readIORef firings
              spanSet span [("firings", Int (fromIntegral (length done'))), ("waiting", Bool False), ("ready", Bool True)]
              DriveOutcome done' False True <$> nextMaturation c.inst
            else do
              -- A clock can reveal that a chosen AdvanceTime is not due; it
              -- cannot consume the turn, so the policy chooses again
              -- without that offer.
              let narrowed = current {actions = filter (/= chosen) current.actions}
              next <- c.policy narrowed
              requireOffered narrowed next
              loop narrowed next
  loop snapshot action
  where
    isPosture = \case Wait -> True; Stop -> True; _ -> False
    isDelivery = \case AcceptDelivery _ -> True; _ -> False

requireOffered :: Snapshot -> Action -> IO ()
requireOffered snapshot action =
  unless (action `elem` snapshot.actions) $
    throwIO (EngineValueError ("the policy chose an action the coordinator did not offer: " <> actionRepr action))

actionRepr :: Action -> Text
actionRepr = \case
  AcceptResult o outcome -> "AcceptResult(occurrence=" <> tshow o <> ", outcome=" <> T.pack (show outcome) <> ")"
  AcceptDelivery d -> "AcceptDelivery(delivery=" <> T.pack (show d) <> ")"
  BeginCandidate b -> "BeginCandidate(binding=" <> T.pack (show b) <> ")"
  AdvanceTime i -> "AdvanceTime(instant=" <> T.pack (show i) <> ")"
  Wait -> "Wait()"
  Stop -> "Stop()"

tshow :: Show a => a -> Text
tshow = T.pack . show

emitGauges :: Coordinator -> IO ()
emitGauges c = do
  occupied <- markingToList <$> marking c.inst
  records' <- historyLength c
  flying <- inFlight c.inst
  current <- Telemetry.currentRssMb
  maxRss <- Telemetry.maxRssMb
  emit
    c.logger
    "gauges"
    [ ("history_records", Int (fromIntegral records'))
    , ("places_occupied", Int (fromIntegral (length occupied)))
    , ("tokens_total", Int (fromIntegral (sum (map (length . snd) occupied))))
    , ("in_flight", Int (fromIntegral (length flying)))
    , ("current_rss_mb", maybe Null Float current)
    , ("max_rss_mb", Float maxRss)
    ]

-- ---------------------------------------------------------------------------
-- Reconcile

-- | Repair recorded cancellations, redispatch the outbox, complete the
-- projection-pending by projection alone, and drive pure in-flight
-- occurrences to terminal — each leg over the resumed in-flight set in begin
-- order.
reconcile :: Coordinator -> IORef (Seq FiringOutcome) -> Span -> IO ()
reconcile c firings span = do
  reconcileCancellations c
  flying <- inFlight c.inst
  pending <- IntSet.fromList . map (.occurrence) <$> projectionPending c.inst
  forM_ flying $ \o -> case o.invocation of
    Just inv
      | not (IntSet.member o.occurrence pending) -> do
          modifyIORef' c.dispatched (IntMap.insert o.occurrence o)
          c.port.dispatch o.occurrence inv
    _ -> pure ()
  forM_ flying $ \o ->
    when (isJust o.invocation && IntSet.member o.occurrence pending) $ do
      outcomes <- pendingActivityOutcomes c.inst
      case IntMap.lookup o.occurrence outcomes of
        Just (TerminalFailure failure)
          | not (projectsFailure c o.binding.transition) -> do
              at <- stamp c
              orThrowInstance (failFiring c.inst o (FailureValue failure) at)
              committed c
              throwIO (terminalHalt o failure)
        _ -> pure ()
      at <- stamp c
      outcome <- orThrowInstance (complete c.inst o Nothing at)
      modifyIORef' firings (Seq.|> outcome)
  forM_ flying $ \o ->
    when (isNothing o.invocation) $ do
      outcome <- completePure c o (Just span)
      modifyIORef' firings (Seq.|> outcome)

reconcileCancellations :: Coordinator -> IO ()
reconcileCancellations c = do
  history <- (instanceHistory c.inst).snapshot
  positions <- either (throwIO . EngineValueError) pure (replayCancellationPositions history)
  recorded <- cancelled c.inst
  forM_ recorded $ \o ->
    when (isJust o.invocation) $
      case IntMap.lookup o.occurrence positions of
        Just position -> () <$ cancelOne c o position
        Nothing -> throwIO (EngineRuntimeError ("no recorded cancellation position for occurrence " <> tshow o.occurrence))

terminalHalt :: FiringOccurrence -> ActivityFailure -> EngineError
terminalHalt o failure =
  EngineRuntimeError
    ( "activity for firing occurrence "
        <> tshow o.occurrence
        <> " ("
        <> netPathText o.binding.transition
        <> ") failed terminally: "
        <> (failureFields failure).failureError
    )

-- | Whether the transition's bound ActivityHandler projects failures.
projectsFailure :: Coordinator -> NetPath -> Bool
projectsFailure c transition = case boundHandler c.inst transition of
  ActivityBound handler -> isJust handler.projectFailure
  PureHandler _ -> False

-- ---------------------------------------------------------------------------
-- Observe

-- | One turn's snapshot.
observeTurn :: Coordinator -> IO Snapshot
observeTurn c = do
  flying <- inFlight c.inst
  let byId = IntSet.fromList (map (.occurrence) flying)
  collected <- c.port.collect
  modifyIORef' c.arrived (<> Seq.fromList collected)
  buffered <- readIORef c.arrived
  known <- readIORef c.dispatched
  resolved <- forM (toList buffered) $ \(occurrenceId, outcome) ->
    if IntSet.member occurrenceId byId
      then pure (Just (occurrenceId, outcome))
      else case IntMap.lookup occurrenceId known of
        Just ended -> do
          at <- stamp c
          _ <- orThrowInstance $ case outcome of
            Failed failure -> recordActivityFailure c.inst ended failure at
            Succeeded result -> recordActivityCompletion c.inst ended result at
          pure Nothing
        Nothing ->
          throwIO
            ( EngineValueError
                ( "the Dispatch completed occurrence "
                    <> tshow occurrenceId
                    <> ", which is not in flight: a Dispatch answers only for invocations its coordinator dispatched"
                )
            )
  let remaining = [r | Just r <- resolved]
  writeIORef c.arrived (Seq.fromList remaining)
  let resultActions = [AcceptResult o outcome | (o, outcome) <- remaining]
  enabled <- candidates c.inst
  writeIORef c.offer Nothing
  beginActions <-
    if null enabled
      then pure []
      else case c.selection of
        SelectionSlot current stateRef -> do
          policy' <- current
          state <- readIORef stateRef
          case policy'.propose enabled state of
            Left err -> throwIO (EngineValueError err)
            Right Nothing -> do
              emit c.logger "candidate_selection_declined" [("enabled", Int (fromIntegral (length enabled)))]
              pure []
            Right (Just proposal) -> do
              unless (proposal.binding `elem` enabled) $
                throwIO (EngineValueError "candidate selection proposed a binding outside the enabled offer")
              unless (proposal.priorState == state) $
                throwIO (EngineValueError "candidate selection proposal does not carry the live prior state")
              let install = do
                    live <- readIORef stateRef
                    unless (live == proposal.priorState) $
                      throwIO
                        ( EngineRuntimeError
                            "selection state changed before its begin commit: the proposal prior state no longer matches"
                        )
                    writeIORef stateRef proposal.nextState
              writeIORef c.offer (Just (proposal.binding, install))
              pure [BeginCandidate proposal.binding]
  maturation <- nextMaturation c.inst
  frozen <- IntSet.fromList . map (.occurrence) <$> projectionPending c.inst
  let arrivedIds = IntSet.fromList (map fst remaining)
      outstanding =
        any
          (\o -> isJust o.invocation && not (IntSet.member o.occurrence arrivedIds) && not (IntSet.member o.occurrence frozen))
          flying
  armedSources <- armed c.inst
  queued <- readIORef c.deliveries
  case c.sensor of
    Just sense | Seq.null queued && not (Map.null armedSources) -> do
      parcels <- sense
      modifyIORef' c.deliveries (<> Seq.fromList parcels)
    _ -> pure ()
  parcels <- toList <$> readIORef c.deliveries
  let deliveryActions = map AcceptDelivery (takeWhile (\d -> Map.member d.source armedSources) parcels)
      actions =
        resultActions
          ++ beginActions
          ++ [AdvanceTime m | Just m <- [maturation]]
          ++ deliveryActions
          ++ [Wait | outstanding]
          ++ [Stop]
      views = [InFlightView o.occurrence o.binding.transition o.binding.consumed (isJust o.invocation) | o <- flying]
  Snapshot actions views <$> readIORef c.previous

-- ---------------------------------------------------------------------------
-- Apply

-- | Apply one chosen action against the single writer. Returns the
-- selection install deferred to the joined commit, and whether the action
-- applied.
apply :: Coordinator -> Action -> IORef (Seq FiringOutcome) -> Span -> IO (Maybe (IO ()), Bool)
apply c action firings span = case action of
  AcceptResult occurrenceId outcome -> do
    flying <- inFlight c.inst
    o <- case find ((== occurrenceId) . (.occurrence)) flying of
      Just held -> pure held
      Nothing -> throwIO (EngineRuntimeError ("occurrence " <> tshow occurrenceId <> " is no longer in flight"))
    -- Unbuffered before the writer commits: a refused freeze spends the
    -- arrival, and recovery is a fresh load whose outbox redispatches.
    modifyIORef' c.arrived (removeFirst ((== occurrenceId) . fst))
    case outcome of
      Failed failure -> do
        at <- stamp c
        _ <- orThrowInstance (recordActivityFailure c.inst o failure at)
        committed c
        let projects = projectsFailure c o.binding.transition
        at' <- stamp c
        if projects
          then orThrowInstance (complete c.inst o Nothing at') >>= \f -> modifyIORef' firings (Seq.|> f)
          else orThrowInstance (failFiring c.inst o (FailureValue failure) at')
        -- The recorded failure is a whole fact: it commits before the halt.
        committed c
        if projects then pure (Nothing, True) else throwIO (terminalHalt o failure)
      Succeeded result -> do
        at <- stamp c
        _ <- orThrowInstance (recordActivityCompletion c.inst o result at)
        -- The freeze is its own durability boundary.
        committed c
        at' <- stamp c
        f <- orThrowInstance (complete c.inst o Nothing at')
        modifyIORef' firings (Seq.|> f)
        pure (Nothing, True)
  AcceptDelivery chosen -> do
    queued <- readIORef c.deliveries
    let position = case Seq.findIndexL (sameDelivery chosen) queued of
          Just i -> Just i
          Nothing -> Seq.findIndexL (== chosen) queued
    parcel <- case position of
      Just i -> do
        writeIORef c.deliveries (Seq.deleteAt i queued)
        pure (Seq.index queued i)
      Nothing -> throwIO (EngineRuntimeError "the chosen delivery is no longer buffered")
    before <- historyLength c
    at <- stamp c
    answer <- orThrowInstance (acceptDelivery c.inst parcel.source parcel.tokens parcel.identity parcel.scope at)
    case answer of
      DeliveryAccepted accepted -> do
        after <- historyLength c
        when (after /= before) (committed c)
        outcome <- completeAccepted c accepted
        modifyIORef' firings (Seq.|> outcome)
      _ -> pure ()
    pure (Nothing, True)
  BeginCandidate binding -> do
    at <- stamp c
    o <- accumulateTime span "begin_ms" (orThrowInstance (begin c.inst binding at))
    install <- maybe (pure ()) snd <$> readIORef c.offer
    -- A backend-owned begin is durable at the door: install now. A joined
    -- backend installs only after the provider commit returns.
    when (isNothing c.commit) install
    case o.invocation of
      Nothing -> do
        outcome <- completePure c o (Just span)
        modifyIORef' firings (Seq.|> outcome)
      Just inv -> do
        modifyIORef' c.dispatched (IntMap.insert o.occurrence o)
        c.port.dispatch o.occurrence inv
    pure (if isJust c.commit then Just install else Nothing, True)
  AdvanceTime instant ->
    c.clock.observe instant >>= \case
      Nothing -> pure (Nothing, False)
      Just observed
        | observed < instant ->
            throwIO
              ( EngineValueError
                  ( "clock observed "
                      <> tshow observed
                      <> ", before the requested maturation "
                      <> tshow instant
                      <> ": observe must return None or an instant at least as late as requested"
                  )
              )
        | otherwise -> do
            _ <- orThrowInstance (wake c.inst observed)
            pure (Nothing, True)
  Wait -> throwIO (EngineValueError "cannot apply non-mutating host posture Wait()")
  Stop -> throwIO (EngineValueError "cannot apply non-mutating host posture Stop()")

-- | Complete an accepted delivery's source occurrence; a recorded terminal
-- failure (exactly one FiringFailed for it) commits before propagating.
completeAccepted :: Coordinator -> AcceptedDelivery -> IO FiringOutcome
completeAccepted c accepted = do
  before <- historyLength c
  at <- stamp c
  orThrowInstance (completeDelivery c.inst accepted at) `catch` \(e :: SomeException) -> do
    unless (isAsync e) $ do
      history <- (instanceHistory c.inst).snapshot
      case Seq.viewr history of
        _ Seq.:> RFiringFailed failed
          | Seq.length history == before + 1 && failed.occurrence == firingOccurrenceIdInt accepted.occurrence -> committed c
        _ -> pure ()
    throwIO e

isAsync :: SomeException -> Bool
isAsync e = isJust (fromException e :: Maybe SomeAsyncException)

removeFirst :: (a -> Bool) -> Seq a -> Seq a
removeFirst matches xs = maybe xs (`Seq.deleteAt` xs) (Seq.findIndexL matches xs)

-- ---------------------------------------------------------------------------
-- Pure completion

-- | Drive a begun pure occurrence to terminal: run the bound handler here
-- (fully evaluated, so a lazy failure is the handler's) and commit its
-- outcome. A failing handler, or a result the commit refuses, is failed and
-- settled through the commit point before propagating; a History refusal
-- of the prepared batch propagates as the store's own exception.
completePure :: Coordinator -> FiringOccurrence -> Maybe Span -> IO FiringOutcome
completePure c o span = case boundHandler c.inst transition of
  ActivityBound _ ->
    throwIO (EngineTypeError ("pure firing " <> netPathText transition <> " is bound to an ActivityHandler"))
  PureHandler handler -> do
    result <- timed "handler_ms" (try (evaluate (force (handler o.binding (outputs (instanceNet c.inst) transition)))))
    case result of
      Left e
        | isAsync e -> throwIO e
        | otherwise -> settle (exceptionFailureText e) e
      Right (Left text) -> settle text (toEngine (EngineHandlerFailed text))
      Right (Right envelope) -> do
        committedOutcome <- timed "commit_ms" (stamp c >>= commitCompletion c.inst o (Just envelope))
        case committedOutcome of
          Right outcome -> pure outcome
          Left (CommitRefused e) -> throwIO e
          Left err -> settle (firingFailureText err) (toEngine (instanceToEngine err))
  where
    transition = o.binding.transition
    timed :: Text -> IO r -> IO r
    timed field body = maybe body (\s -> accumulateTime s field body) span
    settle text err = do
      flying <- inFlight c.inst
      when (any ((== o.occurrence) . (.occurrence)) flying) $ do
        at <- stamp c
        orThrowInstance (failFiring c.inst o (FailureText text) at)
        committed c
      throwIO err
    toEngine :: EngineError -> SomeException
    toEngine = toException

instanceToEngine :: InstanceError -> EngineError
instanceToEngine = \case
  Refused m -> EngineValueError m
  TypeRefused m -> EngineTypeError m
  RuntimeRefused m -> EngineRuntimeError m
  HandlerRaised m -> EngineHandlerFailed m
  CommitRefused e -> EngineRuntimeError (T.pack (show e))

-- ---------------------------------------------------------------------------
-- Cancellation

-- | Install exact operational fences after the caller committed the
-- canonical close or reset at the given History position.
cancelClosure :: Coordinator -> ScopeClosure -> Int -> IO [CancellationDisposition]
cancelClosure c closure position = do
  recorded <- cancelled c.inst
  let byId = IntMap.fromList [(o.occurrence, o) | o <- recorded]
  fmap concat . forM closure.cancelled $ \occurrenceId -> case IntMap.lookup occurrenceId byId of
    Just o | isJust o.invocation -> (: []) <$> cancelOne c o position
    Just _ -> pure []
    Nothing -> throwIO (EngineRuntimeError ("cancelled occurrence " <> tshow occurrenceId <> " is not recorded as cancelled"))

cancelOne :: Coordinator -> FiringOccurrence -> Int -> IO CancellationDisposition
cancelOne c o position = case (c.port.cancel, o.invocation) of
  (Nothing, _) ->
    throwIO
      ( EngineTypeError
          "cannot cancel lifecycle-scoped Activity: this Dispatch does not implement the recoverable cancellation extension"
      )
  (_, Nothing) -> throwIO (EngineRuntimeError "a pure occurrence has no Activity to cancel")
  (Just cancelPort, Just inv) -> do
    modifyIORef' c.dispatched (IntMap.insert o.occurrence o)
    instruction <- either (throwIO . EngineValueError) pure (cancellationInstruction o.occurrence inv position)
    disposition <- cancelPort instruction
    emit
      c.logger
      "activity_cancelled"
      [ ("occurrence", Int (fromIntegral o.occurrence))
      , ("history_position", Int (fromIntegral position))
      , ("disposition", String (dispositionText disposition))
      ]
    pure disposition
