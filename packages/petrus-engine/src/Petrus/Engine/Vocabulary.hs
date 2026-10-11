-- | The Engine's configuration, outcome, and policy vocabulary
-- (the public names of @petrus.engine@ besides @Engine@ itself).
--
-- * 'Delivery' — a sensor's parcel, validated at construction.
-- * 'Clock' and 'simulatedClock' — how the driving runtime observes time.
-- * 'Sensor' — a nonblocking local ingress adapter.
-- * 'Action', 'Snapshot', 'InFlightView' — what a 'DrivingPolicy' observes
--   and chooses among; 'chooseConservative' and 'chooseThroughput' are the
--   two shipped policies.
-- * 'DriveOutcome' — why one 'Petrus.Engine.advance' returned.
-- * 'EngineError' — the reference's @ValueError@ / @TypeError@ /
--   @RuntimeError@ refusals, and a handler's failure.
module Petrus.Engine.Vocabulary
  ( -- * Deliveries
    Delivery (source, tokens, identity, scope)
  , delivery
  , sameDelivery
    -- * Time and ingress
  , Clock (..)
  , simulatedClock
  , Sensor
    -- * Actions and policies
  , Action (..)
  , InFlightView (..)
  , Snapshot (..)
  , DrivingPolicy
  , chooseConservative
  , chooseThroughput
  , purePolicy
  , conservativePolicy
  , throughputPolicy
    -- * Selection
  , EngineSelection (..)
  , defaultSelection
    -- * Outcomes
  , DriveOutcome (..)
    -- * Errors
  , EngineError (..)
  , engineErrorMessage
  , failureText
  , throwInstanceError
  , orThrowInstance
  ) where

import Control.Exception (Exception (..), SomeException, fromException, throwIO)
import Data.IORef
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Internal.Repr (pyStr)
import Petrus.Impetus.Instance
  ( DeliveryScope (..)
  , FiringOutcome
  , InstanceError (..)
  , exceptionFailureText
  )
import Petrus.Impetus.Petrinet (Binding (..), Instant, NetPath, Selection, Token (..))
import Petrus.Impetus.Selection (SelectionPolicy, defaultPipeline)
import Petrus.Json (exactEq)
import Petrus.Motus.Dispatch (ActivityOutcome, DispatchError (..))

-- ---------------------------------------------------------------------------
-- Errors

-- | An Engine refusal, spelled after the reference's exception type.
data EngineError
  = -- | The reference's @ValueError@.
    EngineValueError Text
  | -- | The reference's @TypeError@.
    EngineTypeError Text
  | -- | The reference's @RuntimeError@ (poisoned or closed Engines, a
    -- terminal Activity failure, a broken selection invariant).
    EngineRuntimeError Text
  | -- | A pure handler or projection failed; the text is its recorded
    -- failure (the reference re-raises the handler's own exception).
    EngineHandlerFailed Text
  deriving stock (Eq, Show)

instance Exception EngineError where
  displayException = T.unpack . engineErrorMessage

-- | The error's message.
engineErrorMessage :: EngineError -> Text
engineErrorMessage = \case
  EngineValueError m -> m
  EngineTypeError m -> m
  EngineRuntimeError m -> m
  EngineHandlerFailed m -> m

-- | The reference's @firing_failure_text(error)@ for any exception the
-- Engine sees: its type and message, bounded.
failureText :: SomeException -> Text
failureText e = case fromException e of
  Just engineError -> T.take 4096 $ case engineError of
    EngineValueError m -> "ValueError(" <> pyStr m <> ")"
    EngineTypeError m -> "TypeError(" <> pyStr m <> ")"
    EngineRuntimeError m -> "RuntimeError(" <> pyStr m <> ")"
    EngineHandlerFailed m -> if T.null m then "Exception" else m
  Nothing -> case fromException e of
    Just (DispatchError m) -> T.take 4096 ("ValueError(" <> pyStr m <> ")")
    Nothing -> exceptionFailureText e

-- | Raise a kernel refusal as the reference would: a @ValueError@,
-- @TypeError@, or @RuntimeError@; a handler failure; or the History store's
-- own exception.
throwInstanceError :: InstanceError -> IO a
throwInstanceError = \case
  Refused m -> throwIO (EngineValueError m)
  TypeRefused m -> throwIO (EngineTypeError m)
  RuntimeRefused m -> throwIO (EngineRuntimeError m)
  HandlerRaised m -> throwIO (EngineHandlerFailed m)
  CommitRefused e -> throwIO e

-- | Run a kernel door, raising its refusal.
orThrowInstance :: IO (Either InstanceError a) -> IO a
orThrowInstance door = door >>= either throwInstanceError pure

-- ---------------------------------------------------------------------------
-- Deliveries

-- | A sensor's parcel: one external delivery for a driver to accept before
-- source projection. Only constructible through 'delivery'.
data Delivery = Delivery
  { source :: NetPath
  , tokens :: [Token]
  , identity :: Text
  , scope :: Maybe DeliveryScope
  }
  deriving stock (Eq, Show)

-- | Validate a parcel as @Delivery.__post_init__@ does: a non-empty
-- identity and, for a bare scope name, a non-empty name without NUL. (The
-- reference's exact-type checks are enforced by the types.)
delivery :: NetPath -> [Token] -> Text -> Maybe DeliveryScope -> Either Text Delivery
delivery source tokens identity scope
  | T.null identity =
      Left "delivery identity must be a non-empty string of the exact built-in type, got ''"
  | Just (ScopeName name) <- scope, T.null name || T.any (== '\NUL') name =
      Left "delivery scope name must be non-empty and contain no NUL"
  | otherwise = Right (Delivery source tokens identity scope)

-- | Exact equality of two parcels: token data compared by spelling (an
-- integer is not a boolean), the way the reference tells two buffered
-- parcels apart by object identity.
sameDelivery :: Delivery -> Delivery -> Bool
sameDelivery a b =
  a.source == b.source
    && a.identity == b.identity
    && a.scope == b.scope
    && length a.tokens == length b.tokens
    && and (zipWith (\x y -> x.color == y.color && exactEq x.payload y.payload) a.tokens b.tokens)

-- ---------------------------------------------------------------------------
-- Time and ingress

-- | How the driving runtime observes time. 'now' stamps the records a
-- driver appends; 'observe' is the nonblocking timer read: 'Nothing' means
-- the requested instant is still future, and an observed instant is never
-- earlier than requested.
data Clock = Clock
  { now :: IO Instant
  , observe :: Instant -> IO (Maybe Instant)
  }

-- | @SimulatedClock(at)@: simulated time that starts at @at@ and jumps
-- straight to an observed instant, never rewinding.
simulatedClock :: Instant -> IO Clock
simulatedClock at = do
  current <- newIORef at
  pure
    Clock
      { now = readIORef current
      , observe = \instant -> atomicModifyIORef' current (\held -> let next = max held instant in (next, Just next))
      }

-- | A nonblocking local ingress adapter: each observation transfers a
-- finite batch of already-available deliveries (empty to decline).
type Sensor = IO [Delivery]

-- ---------------------------------------------------------------------------
-- Actions

-- | The invariant-preserving action vocabulary the coordinator owns.
data Action
  = -- | Commit one arrived Activity outcome for the in-flight occurrence id.
    AcceptResult Int ActivityOutcome
  | -- | Accept one sensed delivery durably, then complete its pure source
    -- occurrence.
    AcceptDelivery Delivery
  | -- | Begin the enabled binding (the coordinator holds its selection
    -- proposal).
    BeginCandidate Binding
  | -- | Observe the pending maturation and land the wake append when due.
    AdvanceTime Instant
  | -- | Hand control back: dispatched results are outstanding.
    Wait
  | -- | End the drive.
    Stop
  deriving stock (Eq, Show)

-- | A policy's detached view of one in-flight occurrence.
data InFlightView = InFlightView
  { occurrence :: Int
  , transition :: NetPath
  , consumed :: [Selection]
  , impure :: Bool
  }
  deriving stock (Eq, Show)

-- | What a driving policy observes each turn: the available actions in
-- deterministic order, the in-flight views, and the previously applied
-- action.
data Snapshot = Snapshot
  { actions :: [Action]
  , inFlight :: [InFlightView]
  , previous :: Maybe Action
  }
  deriving stock (Eq, Show)

-- | A driving policy: choose exactly one of the snapshot's actions. It may
-- observe effects (record what it saw); the coordinator refuses an action it
-- did not offer.
type DrivingPolicy = Snapshot -> IO Action

-- | A pure policy as a 'DrivingPolicy'; its refusal is a @ValueError@.
purePolicy :: (Snapshot -> Either Text Action) -> DrivingPolicy
purePolicy choose snapshot = either (throwIO . EngineValueError) pure (choose snapshot)

-- | 'chooseConservative' as a 'DrivingPolicy' (the default).
conservativePolicy :: DrivingPolicy
conservativePolicy = purePolicy chooseConservative

-- | 'chooseThroughput' as a 'DrivingPolicy'.
throughputPolicy :: DrivingPolicy
throughputPolicy = purePolicy chooseThroughput

noAction :: Text
noAction = "no available action: the coordinator always offers Stop"

isAcceptResult, isAcceptDelivery, isBegin, isAdvance, isWait, isStop :: Action -> Bool
isAcceptResult = \case AcceptResult {} -> True; _ -> False
isAcceptDelivery = \case AcceptDelivery {} -> True; _ -> False
isBegin = \case BeginCandidate {} -> True; _ -> False
isAdvance = \case AdvanceTime {} -> True; _ -> False
isWait = \case Wait -> True; _ -> False
isStop = \case Stop -> True; _ -> False

-- | Commit each arrived result before anything else; give one pending
-- delivery interrupt priority; after a delivery, candidate and time work
-- progress before another delivery. Wait does not block buffered ingress,
-- but no second candidate begins while a result is outstanding.
chooseConservative :: Snapshot -> Either Text Action
chooseConservative snapshot
  | Just result <- find isAcceptResult offered = Right result
  | Just parcel <- pending, not (maybe False isAcceptDelivery snapshot.previous) = Right parcel
  | Just wait <- find isWait offered = Right (maybe wait id pending)
  | Just begin <- find isBegin offered = Right begin
  | Just advance <- find isAdvance offered = Right advance
  | Just parcel <- pending = Right parcel
  | Just stop <- find isStop offered = Right stop
  | otherwise = Left noAction
  where
    offered = snapshot.actions
    pending = find isAcceptDelivery offered

-- | The concurrency demonstrator: begin every structurally independent
-- candidate before accepting results. A candidate whose consumed selections
-- collide by value with an in-flight occurrence's is skipped.
chooseThroughput :: Snapshot -> Either Text Action
chooseThroughput snapshot
  | Just parcel <- find isAcceptDelivery offered, not (maybe False isAcceptDelivery snapshot.previous) = Right parcel
  | Just begin <- find independent offered = Right begin
  | otherwise = case [a | kind <- [isAcceptResult, isAdvance, isAcceptDelivery, isWait, isStop], a <- take 1 (filter kind offered)] of
      a : _ -> Right a
      [] -> Left noAction
  where
    offered = snapshot.actions
    spent = [(place, token) | view <- snapshot.inFlight, (place, held) <- view.consumed, token <- held]
    independent = \case
      BeginCandidate binding -> not (any (`elem` spent) [(place, token) | (place, held) <- binding.consumed, token <- held])
      _ -> False

-- ---------------------------------------------------------------------------
-- Selection

-- | A candidate-selection policy with its initial state (the reference's
-- @selection=@ argument, whose state starts at @None@). The state type is
-- the policy's own.
data EngineSelection
  = forall s. (Eq s, Show s) => EngineSelection (SelectionPolicy s) s
  | -- | A selection its host steers between drives (a reference policy
    -- object whose attribute the host sets, as Hamsterdan's
    -- @_V5EnginePolicy.target@). The coordinator reads the input before
    -- each proposal and proposes with the policy built from it; the
    -- policy stays pure. History is folded at load with the policy built
    -- from the input read then.
    forall i s. (Eq s, Show s) => SteeredSelection (IO i) (i -> SelectionPolicy s) s

-- | @SelectionPipeline()@.
defaultSelection :: EngineSelection
defaultSelection = EngineSelection (defaultPipeline :: SelectionPolicy ()) ()

-- ---------------------------------------------------------------------------
-- Outcomes

-- | Why one drive returned and what it committed: the firings in commit
-- order, whether it returned on 'Wait', whether the host should re-drive,
-- and the post-turn deadline.
data DriveOutcome = DriveOutcome
  { firings :: [FiringOutcome]
  , waiting :: Bool
  , ready :: Bool
  , nextMaturation :: Maybe Instant
  }
  deriving stock (Eq, Show)
