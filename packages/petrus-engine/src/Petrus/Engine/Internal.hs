-- | The Engine's implementation: one provider-neutral live composition
-- around exactly one durable Instance (the reference's
-- @petrus.engine.Engine@).
--
-- Not a stable interface: import "Petrus.Engine" (callers),
-- "Petrus.Engine.Provider" (provider compositions), or
-- "Petrus.Engine.Observation" (protocol views).
module Petrus.Engine.Internal
  ( -- * Engines
    Engine
  , EngineOptions (..)
  , defaultEngineOptions
  , EngineResources (..)
  , defaultResources
  , OpenMode (..)
  , openEngine
  , create
  , load
    -- * Driving
  , advance
  , wait
    -- * Writing doors
  , Delivered (..)
  , deliver
  , acceptDelivery
  , completeDelivery
  , openScope
  , closeScope
  , resetScope
  , seal
  , close
    -- * Read doors
  , marking
  , status
  , inFlight
  , activeScopes
  , records
  , observeEngine
    -- * Test access
  , guarded
  , selectionState
  , engineInstance
  ) where

import Control.Concurrent (ThreadId, myThreadId, threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket_, finally, onException, throwIO, try)
import Control.Monad (unless, when)
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Petrus.Activity
  ( ActivityDeclaration
  , ActivityInvocation (..)
  , ExecutionPolicyFields (..)
  , declarationHeartbeatTimeout
  , declarationName
  , executionPolicy
  , policyFields
  )
import Petrus.Engine.Coordinator (Coordinator, cancelClosure, drive, newCoordinator, selectionStateText, supportsCancellation)
import Petrus.Engine.Vocabulary
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), CelCompilers, Completion, noCelCompilers)
import Petrus.Impetus.History.Records (FiringFailed (..), Record (..), ScopeReset (..))
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
  ( AcceptedDelivery (..)
  , DeliveryAnswer (..)
  , DeliveryScope
  , FiringOccurrence (..)
  , FiringOutcome
  , ImplementationRef
  , Instance
  , InstanceConfig (..)
  , PriorAcknowledgement
  , ScopeClosure (..)
  , ScopedDeliveryAcknowledgement
  , Status
  , canonicalAcceptedDelivery
  , defaultInstanceConfig
  , instanceHistory
  , instanceIdentity
  , newInstance
  , resume
  )
import Petrus.Impetus.Instance qualified as I
import Petrus.Impetus.Internal.Repr (pyStr)
import Petrus.Impetus.Petrinet (Filter, Guard, Instant, Marking, Net, NetPath, Token, emptyMarking)
import Petrus.Impetus.Scope (LifecycleScope)
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Telemetry (EventSink)

-- ---------------------------------------------------------------------------
-- Configuration

-- | Everything @Engine.create@ / @Engine.load@ takes besides the Net, the
-- Instance identity, the History store, and the Dispatch.
data EngineOptions = EngineOptions
  { marking :: Marking
  -- ^ The initial marking ('create' only).
  , at :: Instant
  -- ^ The construction instant ('create' only).
  , handlers :: Map ImplementationRef BoundHandler
  , guards :: Map ImplementationRef Guard
  , filters :: Map ImplementationRef Filter
  , completions :: Map Text Completion
  , celCompilers :: CelCompilers
  , policy :: DrivingPolicy
  , selection :: EngineSelection
  , clock :: Maybe Clock
  -- ^ 'Nothing': a 'simulatedClock' starting at the Instance's watermark.
  , sensor :: Maybe Sensor
  , activities :: [ActivityDeclaration]
  , defaultHeartbeatTimeout :: Integer
  , telemetrySink :: Maybe EventSink
  }

-- | The reference's keyword defaults.
defaultEngineOptions :: EngineOptions
defaultEngineOptions =
  EngineOptions
    { marking = emptyMarking
    , at = 0
    , handlers = Map.empty
    , guards = Map.empty
    , filters = Map.empty
    , completions = Map.empty
    , celCompilers = noCelCompilers
    , policy = conservativePolicy
    , selection = defaultSelection
    , clock = Nothing
    , sensor = Nothing
    , activities = []
    , defaultHeartbeatTimeout = 30
    , telemetrySink = Nothing
    }

-- | A provider's transaction and hosting fate for one Engine (the
-- reference's private @_EngineResources@).
--
-- * 'commit' — the joined-transaction commit point; 'Nothing' for
--   backend-owned stores, whose appends are durable at the door.
-- * 'rollback' — undo the open transaction after a writing-door failure
--   (called before the resources close).
-- * 'release' then 'close' — drop the writer fence, then the connection;
--   each runs at most once, 'close' even when 'release' throws.
-- * 'ensure' — checked before every door (a lost lease raises here).
-- * 'wait' — a provider wake hint; 'Nothing' sleeps the bounded interval.
data EngineResources = EngineResources
  { commit :: Maybe (IO ())
  , rollback :: IO ()
  , release :: IO ()
  , close :: IO ()
  , ensure :: IO ()
  , wait :: Maybe (Double -> IO Bool)
  }

-- | Backend-owned writes: no commit point, nothing to release.
defaultResources :: EngineResources
defaultResources = EngineResources Nothing (pure ()) (pure ()) (pure ()) (pure ()) Nothing

-- | Whether 'openEngine' creates a previously absent Instance or loads an
-- existing one.
data OpenMode = CreateInstance | LoadInstance
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- The Engine

-- | The live motion-producing composition around one durable Instance.
--
-- Every writing-door exception poisons the composition: the provider rolls
-- back and releases first, and the coherent continuation is always a fresh
-- 'load' over committed History.
data Engine = Engine
  { inst :: Instance
  , coordinator :: Coordinator
  , engineClock :: Clock
  , resources :: EngineResources
  , monitor :: MVar ()
  , holder :: IORef (Maybe ThreadId)
  -- ^ The thread holding the monitor (the reference's re-entrant lock).
  , writer :: IORef (Maybe ThreadId)
  -- ^ The thread inside a writing door.
  , resourcesClosed :: IORef Bool
  , broken :: IORef (Maybe Text)
  , closed :: IORef Bool
  }

-- | Create and host a previously absent Instance over backend-owned writes.
create :: Net -> Text -> HistoryStore -> Dispatch -> EngineOptions -> IO Engine
create net identity store port options = openEngine CreateInstance net identity store port options defaultResources

-- | Load and host an existing Instance over backend-owned writes.
load :: Net -> Text -> HistoryStore -> Dispatch -> EngineOptions -> IO Engine
load net identity store port options = openEngine LoadInstance net identity store port options defaultResources

-- | The provider entry: open an Engine carrying a provider's transaction
-- and resource fate. On any construction failure the resources roll back,
-- release, and close before the failure propagates.
openEngine :: OpenMode -> Net -> Text -> HistoryStore -> Dispatch -> EngineOptions -> EngineResources -> IO Engine
openEngine mode net identity store port options resources =
  construct `onException` fate
  where
    fate = resources.rollback `finally` (resources.release `finally` resources.close)
    construct = do
      when (options.defaultHeartbeatTimeout <= 0) $
        throwIO (EngineValueError "Engine default_heartbeat_timeout must be a positive integer")
      let declared = Map.fromList [(declarationName d, d) | d <- options.activities]
      when (Map.size declared /= length options.activities) $
        throwIO (EngineValueError "Engine Activity declarations require unique names")
      let handlers = Map.map (resolveTimeouts options.defaultHeartbeatTimeout declared) options.handlers
          config =
            defaultInstanceConfig
              { handlerImplementations = handlers
              , guardImplementations = options.guards
              , filterImplementations = options.filters
              , completionImplementations = options.completions
              , celCompilers = options.celCompilers
              , historyStore = Just store
              , telemetrySink = options.telemetrySink
              }
      existing <- Store.size store
      inst <- case mode of
        CreateInstance -> do
          when (existing /= 0) $
            throwIO (EngineValueError ("cannot create Instance " <> pyStr identity <> ": canonical history already exists"))
          newInstance net config {initialMarking = options.marking, constructionInstant = options.at, suppliedIdentity = Just identity}
            >>= either throwInstanceError pure
        LoadInstance -> do
          when (existing == 0) $
            throwIO (EngineValueError ("cannot load Instance " <> pyStr identity <> ": canonical history does not exist"))
          loaded <- resume net store config >>= either throwInstanceError pure
          unless (instanceIdentity loaded == identity) $
            throwIO
              ( EngineValueError
                  ( "cannot load Instance "
                      <> pyStr identity
                      <> ": canonical InstanceCreated identity is "
                      <> pyStr (instanceIdentity loaded)
                      <> "; storage key and recorded identity must match exactly"
                  )
              )
          pure loaded
      clock <- maybe (I.watermark inst >>= simulatedClock) pure options.clock
      coordinator <-
        newCoordinator inst port options.policy options.selection clock options.sensor resources.commit options.telemetrySink
      sequence_ resources.commit
      Engine inst coordinator clock resources
        <$> newMVar ()
        <*> newIORef Nothing
        <*> newIORef Nothing
        <*> newIORef False
        <*> newIORef Nothing
        <*> newIORef False

-- | Freeze the Engine-composed heartbeat timeout into each prepared
-- invocation: the named declaration's timeout, else the Engine default.
resolveTimeouts :: Integer -> Map Text ActivityDeclaration -> BoundHandler -> BoundHandler
resolveTimeouts fallback declared = \case
  PureHandler h -> PureHandler h
  ActivityBound h ->
    ActivityBound
      h
        { prepare = \b -> do
            inv <- h.prepare b
            let timeout = fromMaybe fallback (Map.lookup inv.activity declared >>= declarationHeartbeatTimeout)
            resolved <- either (Left . valueError) Right (executionPolicy (policyFields inv.policy) {heartbeatTimeout = timeout})
            Right (ActivityInvocation inv.activity inv.input resolved inv.correlation inv.idempotency)
        }
  where
    valueError m = "ValueError(" <> pyStr m <> ")"

-- ---------------------------------------------------------------------------
-- The monitor

-- | Hold the monitor, re-entrantly for the holding thread (the reference's
-- @RLock@).
monitored :: Engine -> IO a -> IO a
monitored e body = do
  me <- myThreadId
  held <- readIORef e.holder
  if held == Just me
    then body
    else bracket_ (takeMVar e.monitor >> writeIORef e.holder (Just me)) (writeIORef e.holder Nothing >> putMVar e.monitor ()) body

refuseReentry :: Engine -> IO ()
refuseReentry e = do
  me <- myThreadId
  active <- readIORef e.writer
  when (active == Just me) $
    throwIO (EngineRuntimeError "public Engine operation cannot re-enter while a writing door is active")

ensureOpen :: Engine -> IO ()
ensureOpen e = do
  e.resources.ensure
  readIORef e.broken >>= \case
    Just text ->
      throwIO
        ( EngineRuntimeError
            ( "this Engine is poisoned after a writing door failed ("
                <> text
                <> "): History, Instance, Dispatch, and the advancement lane may have advanced together — continue through a fresh Engine.load or provider load function"
            )
        )
    Nothing -> pure ()
  isClosed <- readIORef e.closed
  when isClosed $
    throwIO (EngineRuntimeError "this Engine is closed; create or load a new Engine before observing or driving")

closeResources :: Engine -> IO ()
closeResources e = do
  done <- readIORef e.resourcesClosed
  unless done $ do
    writeIORef e.resourcesClosed True
    e.resources.release `finally` e.resources.close

committed :: Engine -> IO ()
committed e = sequence_ e.resources.commit

-- | A writing door: any failure poisons the Engine, rolls the provider back,
-- and closes its resources before propagating.
guarded :: Engine -> IO a -> IO a
guarded e door = monitored e $ do
  refuseReentry e
  ensureOpen e
  me <- myThreadId
  writeIORef e.writer (Just me)
  outcome <- try door
  writeIORef e.writer Nothing
  case outcome of
    Right value -> pure value
    Left (failure :: SomeException) -> do
      writeIORef e.broken (Just (failureText failure))
      e.resources.rollback `finally` closeResources e
      throwIO failure

readDoor :: Bool -> Engine -> IO a -> IO a
readDoor allowReentry e operation = monitored e $ do
  unless allowReentry (refuseReentry e)
  ensureOpen e
  operation

-- ---------------------------------------------------------------------------
-- Driving

-- | Reconcile if first loaded, then apply at most one whole action and
-- return the host's next posture.
advance :: Engine -> IO DriveOutcome
advance e = guarded e (drive e.coordinator)

-- | Wait for a provider wake hint, or sleep the bounded neutral polling
-- interval (seconds) and answer 'False'.
wait :: Engine -> Double -> IO Bool
wait e timeout = do
  waiter <- readDoor True e (pure e.resources.wait)
  case waiter of
    Just hint -> hint timeout
    Nothing -> do
      when (timeout > 0) $ threadDelay (round (timeout * 1000000))
      pure False

-- ---------------------------------------------------------------------------
-- Writing doors

-- | What 'deliver' answers: the completed source firing, or the door's
-- acknowledgement of a prior or scoped delivery.
data Delivered
  = Delivered FiringOutcome
  | DeliveredPrior PriorAcknowledgement
  | DeliveredScoped ScopedDeliveryAcknowledgement
  deriving stock (Eq, Show)

-- | Accept and complete one identified external delivery across two
-- durable boundaries.
deliver :: Engine -> NetPath -> [Token] -> Text -> Maybe DeliveryScope -> IO Delivered
deliver e source tokens identity scope = guarded e $
  acceptIdentified e source tokens identity scope >>= \case
    DeliveryAccepted accepted -> do
      completed <- completeAccepted e accepted
      committed e
      pure (Delivered completed)
    DeliveryPrior prior -> pure (DeliveredPrior prior)
    DeliveryScoped scoped -> pure (DeliveredScoped scoped)

-- | Durably accept and begin one identified source delivery without
-- completing it.
acceptDelivery :: Engine -> NetPath -> [Token] -> Text -> Maybe DeliveryScope -> IO DeliveryAnswer
acceptDelivery e source tokens identity scope = guarded e (acceptIdentified e source tokens identity scope)

acceptIdentified :: Engine -> NetPath -> [Token] -> Text -> Maybe DeliveryScope -> IO DeliveryAnswer
acceptIdentified e source tokens identity scope = do
  before <- historyLength e
  now <- e.engineClock.now
  answer <- orThrowInstance (I.acceptDelivery e.inst source tokens identity scope (Just now))
  after <- historyLength e
  when (after /= before) (committed e)
  pure answer

-- | Complete only the accepted unfinished pure source occurrence named by
-- the carrier.
completeDelivery :: Engine -> AcceptedDelivery -> IO FiringOutcome
completeDelivery e accepted = guarded e $ do
  completed <- completeAccepted e accepted
  committed e
  pure completed

completeAccepted :: Engine -> AcceptedDelivery -> IO FiringOutcome
completeAccepted e raw = do
  accepted <- either (throwIO . EngineValueError) pure (canonicalAcceptedDelivery raw)
  before <- historyLength e
  now <- e.engineClock.now
  orThrowInstance (I.completeDelivery e.inst accepted (Just now)) `onException` do
    history <- (instanceHistory e.inst).snapshot
    case Seq.viewr history of
      _ Seq.:> RFiringFailed failed
        | Seq.length history == before + 1 && failed.occurrence == accepted.occurrence -> committed e
      _ -> pure ()

-- | Open and commit the next lifecycle generation for the name.
openScope :: Engine -> Text -> IO LifecycleScope
openScope e name = guarded e $ do
  now <- e.engineClock.now
  scope <- orThrowInstance (I.openScope e.inst name (Just now))
  committed e
  pure scope

-- | Commit exact cleanup, then install recoverable Dispatch cancellation
-- fences.
closeScope :: Engine -> LifecycleScope -> IO ScopeClosure
closeScope e scope = guarded e $ do
  requireScopeCancellation e scope
  now <- e.engineClock.now
  closure <- orThrowInstance (I.closeScope e.inst scope (Just now))
  position <- historyLength e
  -- The canonical close is visible before any cancellation instruction.
  committed e
  _ <- cancelClosure e.coordinator closure position
  -- Joined providers durably publish their operational fences.
  committed e
  pure closure

-- | Atomically close the scope and open its successor, then fence
-- cancelled custody.
resetScope :: Engine -> LifecycleScope -> IO LifecycleScope
resetScope e scope = guarded e $ do
  requireScopeCancellation e scope
  now <- e.engineClock.now
  opened <- orThrowInstance (I.resetScope e.inst scope (Just now))
  position <- historyLength e
  history <- (instanceHistory e.inst).snapshot
  closure <- case Seq.viewr history of
    _ Seq.:> RScopeReset reset -> pure (ScopeClosure reset.closed reset.discarded reset.cancelled)
    _ -> throwIO (EngineRuntimeError "reset_scope did not append ScopeReset")
  committed e
  _ <- cancelClosure e.coordinator closure position
  committed e
  pure opened

requireScopeCancellation :: Engine -> LifecycleScope -> IO ()
requireScopeCancellation e scope = do
  flying <- I.inFlight e.inst
  let needsCancellation = any (\o -> o.scope == Just scope && isJust o.invocation) flying
  when (needsCancellation && not (supportsCancellation e.coordinator)) $
    throwIO
      ( EngineTypeError
          "cannot close lifecycle scope with in-flight Activities: this Dispatch does not implement the recoverable cancellation extension"
      )

-- | Close a source's default delivery registration and commit it.
seal :: Engine -> NetPath -> IO ()
seal e source = guarded e $ do
  now <- e.engineClock.now
  orThrowInstance (I.seal e.inst source (Just now))
  committed e

-- | Release hosting resources without changing semantic Instance status.
-- Idempotent; refused from inside a writing door.
close :: Engine -> IO ()
close e = monitored e $ do
  refuseReentry e
  isClosed <- readIORef e.closed
  unless isClosed $ do
    writeIORef e.closed True
    closeResources e

-- ---------------------------------------------------------------------------
-- Read doors

-- | The current marking (an immutable value).
marking :: Engine -> IO Marking
marking e = readDoor True e (I.marking e.inst)

-- | The Instance's derived status.
status :: Engine -> IO Status
status e = readDoor True e (I.status e.inst)

-- | In-flight occurrence values in begin order.
inFlight :: Engine -> IO [FiringOccurrence]
inFlight e = readDoor True e (I.inFlight e.inst)

-- | The exact active lifecycle generation per name.
activeScopes :: Engine -> IO (Map Text LifecycleScope)
activeScopes e = readDoor True e (I.activeScopes e.inst)

-- | The canonical History record values.
records :: Engine -> IO [Record]
records e = readDoor True e (toList <$> (instanceHistory e.inst).snapshot)

-- | One coherent, non-reentrant read of the hosted Instance and its
-- History — the seam the protocol views (@snapshot@, @net_document@,
-- @history_page@) are built on. The operation must only read.
observeEngine :: Engine -> (Instance -> Seq Record -> IO a) -> IO a
observeEngine e operation = readDoor False e $ do
  history <- (instanceHistory e.inst).snapshot
  operation e.inst history

historyLength :: Engine -> IO Int
historyLength e = Store.size (instanceHistory e.inst)

-- ---------------------------------------------------------------------------
-- Test access

-- | The coordinator's live selection state, shown (the reference tests read
-- @engine._coordinator._selection_state@).
selectionState :: Engine -> IO Text
selectionState e = selectionStateText e.coordinator

-- | The hosted Instance (tests and provider compositions only: writing
-- through it bypasses the Engine's commit points).
engineInstance :: Engine -> Instance
engineInstance e = e.inst
