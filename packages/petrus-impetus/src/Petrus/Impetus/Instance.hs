-- | The Instance: one running Petrinet Instance (@petrus.impetus.instance@).
--
-- An 'Instance' holds a net, its live state — per-place pair-queues of
-- @(token, entry instant)@ maintained by folding exactly the movement records
-- it appends — and its event History. It computes enabled candidates, lets
-- the scheduler pick one, fires it through the begin/end lifecycle, and
-- appends the resulting records through its 'HistoryStore'.
--
-- __Single writer.__ The Instance is the History's only writer and the
-- keeper of the clock watermark. Every door takes the instance's lock, so two
-- threads never interleave a door; every appending door takes an optional
-- instant ('Nothing' advances nothing, an earlier instant clamps to the
-- watermark) and stamps its records with the effective instant. The kernel
-- never reads a wall clock (the one exception is the minted UUIDv7 identity,
-- an opaque value).
--
-- __Durable before live.__ Each door validates everything, commits its whole
-- batch with one 'extend', and only then moves live state and emits its
-- telemetry event (stamped with the record's virtual instant). A store that
-- throws leaves the instance exactly where it was; the exception propagates
-- as an IO exception. A refusal the reference raises as @ValueError@ or
-- @TypeError@ is an 'InstanceError' value.
--
-- __Purity is a type.__ A handler is a pure 'Handler' or an
-- 'ActivityHandler' ("Petrus.Impetus.Binding"); the Instance classifies by
-- constructor. The inline drivers ('step', 'completeDelivery') run pure
-- handlers only; an Engine drives Activity transitions through 'begin',
-- 'recordActivityCompletion', and 'complete'.
module Petrus.Impetus.Instance
  ( -- * Instances
    Instance
  , instanceNet
  , instanceIdentity
  , instanceHistory
  , ImplementationRef (..)
  , InstanceConfig (..)
  , defaultInstanceConfig
  , newInstance
  , resume
    -- * Errors
  , InstanceError (..)
  , renderInstanceError
  , firingFailureText
  , exceptionFailureText
  , pythonFailureText
  , PythonException (..)
  , PythonArg (..)
    -- * Delivery and terminal values
  , AcceptedDelivery (instanceId, source, identity, occurrence)
  , acceptedDelivery
  , canonicalAcceptedDelivery
  , PriorAcknowledgement (..)
  , DeliveryScope (..)
  , DeliveryDisposition (..)
  , ScopedDeliveryAcknowledgement (..)
  , DeliveryAnswer (..)
  , TerminalDisposition (..)
  , ScopeClosure (..)
  , FailureReason (..)
  , Status (..)
  , statusText
    -- * Reads
  , marking
  , watermark
  , candidates
  , candidatesWithDiagnostics
  , enabledTransitions
  , armed
  , inFlight
  , projectionPending
  , activeScopes
  , cancelled
  , activityOccurrences
  , pendingActivityOutcomes
  , nextMaturation
  , isQuiescent
  , status
  , statusWithDiagnostics
  , boundHandler
    -- * Doors
  , openScope
  , closeScope
  , resetScope
  , begin
  , recordActivityCompletion
  , recordActivityFailure
  , complete
  , commitCompletion
  , failFiring
  , step
  , run
  , acceptDelivery
  , completeDelivery
  , seal
  , wake
    -- * Identities
  , module Petrus.Impetus.Instance.Identity
    -- * Firing values
  , module Petrus.Impetus.Instance.Firing
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.DeepSeq (force)
import Control.Exception (Exception (..), SomeAsyncException, SomeException (..), evaluate, throwIO, try)
import Control.Monad (foldM, forM, forM_, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE, withExceptT)
import Data.Foldable (toList)
import Data.IORef
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet (IntSet)
import Data.IntSet qualified as IntSet
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity
  ( ActivityFailure
  , ActivityFailureFields (..)
  , ActivityInvocation (..)
  , activityInvocation
  , failureFields
  , numberJson
  , simpleFailure
  )
import Petrus.Impetus.Binding
import Petrus.Impetus.History.Records
import Petrus.Impetus.History.Replay
import Petrus.Impetus.HistoryStore (HistoryStore (..), inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance.FailureText
import Petrus.Impetus.Instance.Firing
import Petrus.Impetus.Instance.Identity
import Petrus.Impetus.Internal.OMap (OMap)
import Petrus.Impetus.Internal.OMap qualified as OMap
import Petrus.Impetus.Internal.Repr
import Petrus.Impetus.Internal.Uuid (uuid7Hex)
import Petrus.Impetus.Petrinet.Enabledness (Binding (..), Diagnostic, Filter, Guard, ImplementationKey (..), Implementations (..))
import Petrus.Impetus.Petrinet.Enabledness qualified as E
import Petrus.Impetus.Petrinet.Firing (BeginEffect (..), ProducedTokens (..), beginFiring, completeFiring)
import Petrus.Impetus.Petrinet.Marking (Marking, Token (..), emptyMarking, emptyQueue, markingPlaces, markingToList, queueIdentities, queueScopes, reprTokens, reprToken, removeExact, removeTokens, selectedOccurrences)
import Petrus.Impetus.Petrinet.Routing (route)
import Petrus.Impetus.Petrinet.Schema
import Petrus.Impetus.Scope
import Petrus.Json (Json (..), canonicalText, compact, dumps, encodeErrorMessage)
import Petrus.Telemetry (EventSink, Payload, TelemetryLogger, bind, emit, getLogger)

-- ---------------------------------------------------------------------------
-- Errors

-- | A refused door. The reference raises; here a refusal is a value and
-- nothing was appended. A History store's own refusal is never one of these
-- (it propagates as the store's IO exception), except through
-- 'commitCompletion', which reports it distinguishably.
data InstanceError
  = -- | The reference's @ValueError@.
    Refused Text
  | -- | The reference's @TypeError@ (a contract the types could not rule out).
    TypeRefused Text
  | -- | The reference's @RuntimeError@ (a broken live-state invariant).
    RuntimeRefused Text
  | -- | A handler, prepare, or projection raised: its 'Left' text, or the
    -- spelling of a Haskell exception it threw ('exceptionFailureText').
    HandlerRaised Text
  | -- | The History store refused a prepared firing-completion batch.
    CommitRefused SomeException
  deriving stock (Show)

-- | The error's message.
renderInstanceError :: InstanceError -> Text
renderInstanceError = \case
  Refused m -> m
  TypeRefused m -> m
  RuntimeRefused m -> m
  HandlerRaised m -> m
  CommitRefused e -> "History refused a prepared firing-completion batch: " <> T.pack (displayException e)

-- | The deterministic, bounded failure text an inline driver records on
-- @FiringFailed@ (@firing_failure_text@): the reference's
-- @ExceptionName('message')@ spelling for the Instance's own refusals, the
-- handler's text verbatim, at most 4096 characters.
firingFailureText :: InstanceError -> Text
firingFailureText err = T.take 4096 $ case err of
  Refused m -> "ValueError(" <> pyStr m <> ")"
  TypeRefused m -> "TypeError(" <> pyStr m <> ")"
  RuntimeRefused m -> "RuntimeError(" <> pyStr m <> ")"
  HandlerRaised m -> if T.null m then "Exception" else m
  CommitRefused e -> exceptionFailureText e

-- ---------------------------------------------------------------------------
-- Values

-- | Detached correlation value for one accepted unfinished source
-- occurrence. Built through 'acceptedDelivery'; exact redelivery
-- reconstructs the same value from History.
data AcceptedDelivery = AcceptedDelivery
  { instanceId :: InstanceIdentity
  , source :: NetPath
  , identity :: DeliveryIdentity
  , occurrence :: FiringOccurrenceId
  }
  deriving stock (Eq, Show)

-- | @AcceptedDelivery(instance, source, identity, occurrence)@: the field
-- constructors run in the reference's order, and the first refusal wins.
acceptedDelivery :: Text -> NetPath -> Text -> Int -> Either Text AcceptedDelivery
acceptedDelivery owner path ident o =
  AcceptedDelivery <$> mkInstanceIdentity owner <*> pure path <*> mkDeliveryIdentity ident <*> mkFiringOccurrenceId o

-- | @_canonical_accepted_delivery@: snapshot one carrier through its field
-- constructors. The fields are already validated newtypes and the
-- exact-type check is the type's, so every carrier is canonical.
canonicalAcceptedDelivery :: AcceptedDelivery -> Either Text AcceptedDelivery
canonicalAcceptedDelivery = Right

-- | The delivery door's answer to redelivery after the accepted occurrence
-- ended: not a firing, and minting one appends nothing.
data PriorAcknowledgement = PriorAcknowledgement
  { identity :: Text
  , occurrence :: Int
  }
  deriving stock (Eq, Show)

-- | The lifecycle scope a delivery targets: an exact generation, or a bare
-- name whose generation the sender could not know.
data DeliveryScope = ScopeGeneration LifecycleScope | ScopeName Text
  deriving stock (Eq, Show)

-- | Canonical scoped-ingress acknowledgement outcome.
data DeliveryDisposition = Dropped | Quarantined
  deriving stock (Eq, Show)

-- | A scoped delivery durably dispositioned without firing.
data ScopedDeliveryAcknowledgement = ScopedDeliveryAcknowledgement
  { identity :: Text
  , disposition :: DeliveryDisposition
  , scope :: QuarantineScope
  }
  deriving stock (Eq, Show)

-- | The three answers of 'acceptDelivery' (the reference tells them apart by
-- type).
data DeliveryAnswer
  = DeliveryAccepted AcceptedDelivery
  | DeliveryPrior PriorAcknowledgement
  | DeliveryScoped ScopedDeliveryAcknowledgement
  deriving stock (Eq, Show)

-- | The canonical terminal-report door's result.
data TerminalDisposition = TerminalAccepted | TerminalAcknowledged | TerminalQuarantined
  deriving stock (Eq, Show)

-- | The exact cleanup and cancellation committed by close/reset.
data ScopeClosure = ScopeClosure
  { scope :: LifecycleScope
  , discarded :: [Int]
  , cancelled :: [Int]
  }
  deriving stock (Eq, Show)

-- | What 'failFiring' records: a bare error text (the reference's @str@,
-- wrapped as a simple failure) or a classified failure.
data FailureReason = FailureText Text | FailureValue ActivityFailure
  deriving stock (Eq, Show)

-- | Derived instance status, never stored.
data Status = Running | Terminated | Completed | Stuck | Awaiting
  deriving stock (Eq, Show)

-- | The reference's @Status@ values.
statusText :: Status -> Text
statusText = \case
  Running -> "running"
  Terminated -> "terminated"
  Completed -> "completed"
  Stuck -> "stuck"
  Awaiting -> "awaiting"

-- ---------------------------------------------------------------------------
-- Configuration

-- | How a supplied implementation is keyed: by a declaration's local symbol
-- (shared by every declaration of that name) or by one declaration's exact
-- canonical identity. A declaration resolves by one of the two, never both.
data ImplementationRef = Symbol Text | Exact NetUri
  deriving stock (Eq, Ord, Show)

-- | Construction inputs (the reference's keyword arguments). 'resume' reads
-- only the binding fields: the scheduler, the implementations, the CEL
-- compilers, and the telemetry sink.
data InstanceConfig = InstanceConfig
  { initialMarking :: Marking
  , schedulerPolicy :: Scheduler
  , guardImplementations :: Map ImplementationRef Guard
  , handlerImplementations :: Map ImplementationRef BoundHandler
  , filterImplementations :: Map ImplementationRef Filter
  , completionImplementations :: Map Text Completion
  , celCompilers :: CelCompilers
  , constructionInstant :: Instant
  -- ^ The construction instant (default 0, the logical epoch).
  , historyStore :: Maybe HistoryStore
  -- ^ A fresh store to append to; 'Nothing' builds an in-memory one.
  , suppliedIdentity :: Maybe Text
  -- ^ The instance identity; 'Nothing' mints a UUIDv7 hex.
  , telemetrySink :: Maybe EventSink
  -- ^ Where @impetus_*@ events go; 'Nothing' uses the process default.
  }

-- | No marking, the conservative scheduler, no implementations, no CEL.
defaultInstanceConfig :: InstanceConfig
defaultInstanceConfig =
  InstanceConfig
    { initialMarking = emptyMarking
    , schedulerPolicy = selectConservative
    , guardImplementations = Map.empty
    , handlerImplementations = Map.empty
    , filterImplementations = Map.empty
    , completionImplementations = Map.empty
    , celCompilers = noCelCompilers
    , constructionInstant = IntNumber 0
    , historyStore = Nothing
    , suppliedIdentity = Nothing
    , telemetrySink = Nothing
    }

-- ---------------------------------------------------------------------------
-- The instance

-- | Live state: every field is a projection of History, kept current by the
-- doors and rebuilt whole by 'resume'.
data State = State
  { sQueues :: Queues
  , sWatermark :: Instant
  , sArmed :: Map NetPath (Set Text)
  , sNextOccurrence :: Int
  , sNextEntry :: Int
  , sInFlight :: IntMap FiringOccurrence
  , sActivityOccurrences :: IntMap FiringOccurrence
  , sCancelled :: OMap Int FiringOccurrence
  , sFrozen :: IntMap TerminalOutcome
  , sTerminal :: IntMap TerminalOutcome
  , sQuarantined :: IntMap Json
  , sAccepted :: Map Text Record
  , sActiveScopes :: Map Text LifecycleScope
  , sGenerations :: Map Text Integer
  }

-- | A running execution of a net definition.
data Instance = Instance
  { iNet :: Net
  , iIdentity :: Text
  , iHandlers :: Map NetUri BoundHandler
  , iImplementations :: Implementations
  , iCompletion :: Maybe Completion
  , iScheduler :: Scheduler
  , iStore :: HistoryStore
  , iLogger :: TelemetryLogger
  , iState :: IORef State
  , iLock :: MVar ()
  }

instanceNet :: Instance -> Net
instanceNet inst = inst.iNet

-- | The durable instance identity (recorded by @InstanceCreated@).
instanceIdentity :: Instance -> Text
instanceIdentity inst = inst.iIdentity

instanceHistory :: Instance -> HistoryStore
instanceHistory inst = inst.iStore

type Door = ExceptT InstanceError IO

refuse :: Text -> Door a
refuse = throwE . Refused

orRefuse :: Either Text a -> Door a
orRefuse = either refuse pure

-- | Run a door under the single-writer lock.
locked :: Instance -> Door a -> IO (Either InstanceError a)
locked inst door = withMVar inst.iLock (\_ -> runExceptT door)

getState :: Instance -> Door State
getState inst = liftIO (readIORef inst.iState)

putState :: Instance -> State -> Door ()
putState inst st = liftIO (writeIORef inst.iState st)

-- | The effective instant an append takes (@max(at, watermark)@, keeping
-- the supplied spelling when equal, as Python's @max@ does).
effective :: Instant -> Maybe Instant -> Instant
effective w = \case
  Nothing -> w
  Just a -> if w > a then w else a

emitEvent :: Instance -> Text -> Payload -> Door ()
emitEvent inst name payload = liftIO (emit inst.iLogger name payload)

int :: Int -> Json
int = Int . toInteger

text :: Text -> Json
text = String

-- | Validate a complete batch before the live writer appends it: the
-- records' constructor rules first, then the replay door's field rules,
-- prefixed as the reference's writer does.
writerRecords :: [Record] -> Either Text [Record]
writerRecords batch = do
  mapM_ recordInvariants batch
  case mapM_ recordFieldRules batch of
    Left message ->
      Left ("cannot write non-canonical History: " <> fromMaybe message (T.stripPrefix "replay divergence: " message))
    Right () -> Right batch

-- | Validate and commit one batch.
appendBatch :: Instance -> [Record] -> Door [Record]
appendBatch inst records = do
  batch <- orRefuse (writerRecords records)
  liftIO (inst.iStore.extend batch)
  pure batch

applyAll :: Maybe [Int] -> [Record] -> Queues -> Door Queues
applyAll inferred records queues = foldM (\q r -> orRuntime (applyMovement inferred r q)) queues records

orRuntime :: Either Text a -> Door a
orRuntime = either (throwE . RuntimeRefused) pure

-- ---------------------------------------------------------------------------
-- Canonical payloads

-- | @_canonical_payload@: the JSON round trip of a payload whose durable
-- equality is load-bearing. A 'Json' value is already JSON; the round trip
-- refuses what @json.dumps(value, allow_nan=False)@ refuses (non-finite
-- numbers, integers past CPython's 4300-digit limit), with CPython's text.
canonicalPayload :: Json -> Text -> Either Text Json
canonicalPayload value rejection = case dumps compact value of
  Left refusal ->
    Left
      ( rejection
          <> ": the payload must be JSON-faithful — objects, arrays, strings, numbers, booleans, null — and never net state; "
          <> T.pack (encodeErrorMessage refusal)
      )
  Right _ -> Right value

-- | @_canonical_payload_text@ ('Nothing' for a value with no strict JSON
-- spelling, which never reaches a comparison).
canonical :: Json -> Maybe Text
canonical = either (const Nothing) Just . canonicalText

sameCanonical :: Json -> Json -> Bool
sameCanonical a b = case (canonical a, canonical b) of
  (Just x, Just y) -> x == y
  _ -> False

tokensJson :: [Token] -> Json
tokensJson ts = Array [Object [("color", maybe Null String t.color), ("data", t.payload)] | t <- ts]

-- | @_delivery_content_text@.
deliveryContent :: [Token] -> Maybe Text
deliveryContent = canonical . tokensJson

-- | @_canonical_delivery_tokens@.
canonicalDeliveryTokens :: NetPath -> [Token] -> Either Text [Token]
canonicalDeliveryTokens path tokens =
  forM (zip [1 :: Int ..] tokens) $ \(position, t) -> do
    _ <-
      canonicalPayload
        (Object [("color", maybe Null String t.color), ("data", t.payload)])
        ("delivery to " <> netPathText path <> ": token " <> pyInt position <> " has invalid data")
    Right t

failureObject :: ActivityFailure -> Json
failureObject f =
  let x = failureFields f
   in Object
        [ ("error", String x.failureError)
        , ("kind", String x.failureKind)
        , ("details", x.failureDetails)
        , ("retryable", Bool x.failureRetryable)
        , ("retry_after", maybe Null numberJson x.failureRetryAfter)
        ]

-- | @_failure_text@ equality.
sameFailure :: ActivityFailure -> ActivityFailure -> Bool
sameFailure a b = sameCanonical (failureObject a) (failureObject b)

-- | @_terminal_outcome@: the durable envelope of a terminal outcome.
terminalOutcomeJson :: TerminalOutcome -> Json
terminalOutcomeJson = \case
  TerminalFailure f -> Object [("kind", String "failed"), ("failure", failureObject f)]
  TerminalResult v -> Object [("kind", String "completed"), ("value", v)]

-- ---------------------------------------------------------------------------
-- Handler evaluation

isAsync :: SomeException -> Bool
isAsync e = isJust (fromException e :: Maybe SomeAsyncException)

-- | Run a pure handler's answer to normal form, turning a Haskell exception
-- thrown inside it into the handler raising.
forceResult :: Either Text HandlerResult -> IO (Either Text HandlerResult)
forceResult result =
  try (evaluate (force result)) >>= \case
    Left e | isAsync e -> throwIO e
    Left e -> pure (Left (exceptionFailureText e))
    Right value -> pure value

forcePrepared :: Either Text ActivityInvocation -> IO (Either Text ActivityInvocation)
forcePrepared prepared =
  try (evaluate (force prepared)) >>= \case
    Left e | isAsync e -> throwIO e
    Left e -> pure (Left (exceptionFailureText e))
    Right value -> pure value

handlerDoor :: IO (Either Text a) -> Door a
handlerDoor action = liftIO action >>= either (throwE . HandlerRaised) pure

-- ---------------------------------------------------------------------------
-- Symbol binding

-- | Resolve one exact declaration or its named shared fallback, never both.
implementationFor :: Maybe Text -> NetUri -> Map ImplementationRef a -> Text -> Either Text (Maybe a)
implementationFor symbol uri supplied subject =
  case (Map.lookup (Exact uri) supplied, symbol >>= \s -> (s,) <$> Map.lookup (Symbol s) supplied) of
    (Just _, Just (s, _)) ->
      Left
        ( subject <> " declaration " <> netUriText uri <> " has both an exact implementation and local symbol "
            <> pyStr s
        )
    (Just exact, Nothing) -> Right (Just exact)
    (Nothing, Just (_, named)) -> Right (Just named)
    (Nothing, Nothing) -> Right Nothing

transitionsInOrder :: Net -> [Transition]
transitionsInOrder net = [t | p <- netTransitionOrder net, Just t <- [lookupTransition p net]]

-- | The binding layer's one home, shared by both constructors: resolve every
-- declared symbol and inline expression, fail-fast.
bindSymbols :: Net -> InstanceConfig -> Either Text (Map NetUri BoundHandler, Implementations, Maybe Completion)
bindSymbols net cfg = do
  handlerPairs <- fmap catMaybes . forM (transitionsInOrder net) $ \t -> case t.handler of
    Nothing -> Right Nothing
    Just declaration -> do
      uri <- maybe (Left ("transition " <> netPathText t.path <> " has no handler identity")) Right (handlerUri net t.path)
      let symbol = case declaration of
            HandlerSymbol s -> Just s
            HandlerAnonymous _ -> Nothing
      found <- implementationFor symbol uri cfg.handlerImplementations "handler"
      Right (Just (uri, maybe (Left (fromMaybe (netUriText uri) symbol)) Right found))
  let missingHandlers = [m | (_, Left m) <- handlerPairs]
  unless (null missingHandlers) $
    Left ("handler declaration(s) with no implementation: " <> pyList (map pyStr (sortOn id missingHandlers)))
  let handlers = Map.fromList [(uri, h) | (uri, Right h) <- handlerPairs]
  forM_ (transitionsInOrder net) $ \t -> forM_ (handlerUri net t.path) $ \uri ->
    case Map.lookup uri handlers of
      Just (ActivityBound _)
        | isSource net t.path ->
            Left
              ( "handler declaration " <> netUriText uri <> " binds an ActivityHandler to source transition "
                  <> netPathText t.path
                  <> ": a source transition locally and atomically projects its delivered fact — recoverable impure work belongs in a downstream handled transition [DR 2026-07-14 source-delivery-projection-and-identity]"
              )
      _ -> Right ()
  guardPairs <- fmap concat . forM (transitionsInOrder net) $ \t -> do
    let scope = Set.fromList [a.source | a <- inputs net t.path, not (isInhibit a)]
    forM (zip t.guards (guardUris net t.path)) $ \(declaration, uri) -> case declaration of
      GuardCel expression -> do
        when (Map.member (Exact uri) cfg.guardImplementations) $
          Left ("inline guard declaration " <> netUriText uri <> " already supplies its Cel implementation")
        compiled <- cfg.celCompilers.compileGuard expression t.path scope
        Right (uri, Right compiled)
      GuardSymbol s -> resolvedGuard uri (Just s)
      GuardAnonymous _ -> resolvedGuard uri Nothing
  let missingGuards = [m | (_, Left m) <- guardPairs]
  unless (null missingGuards) $
    Left ("guard declaration(s) with no implementation: " <> pyList (map pyStr (sortOn id missingGuards)))
  filterPairs <- forM (filterDeclarations net) $ \(uri, declaration) -> case declaration of
    FilterCel expression -> do
      when (Map.member (Exact uri) cfg.filterImplementations) $
        Left ("inline filter declaration " <> netUriText uri <> " already supplies its Cel implementation")
      compiled <- cfg.celCompilers.compileFilter expression
      Right (uri, Right compiled)
    FilterSymbol s -> do
      found <- implementationFor (Just s) uri cfg.filterImplementations "filter"
      Right (uri, maybe (Left (pyStr s <> " (" <> netUriText uri <> ")")) Right found)
  let missingFilters = [m | (_, Left m) <- filterPairs]
  unless (null missingFilters) $
    Left ("filter declaration(s) with no implementation: " <> pyList (map pyStr (sortOn id missingFilters)))
  completion <- case netCompletion net of
    Nothing -> Right Nothing
    Just (CompletionSymbol s) -> case Map.lookup s cfg.completionImplementations of
      Nothing -> Left ("completion symbol with no implementation: " <> pyStr s)
      Just c -> Right (Just c)
    Just (CompletionCel expression) ->
      Just <$> cfg.celCompilers.compileCompletion expression (Map.keys (netPlaces net))
  let impls =
        Implementations
          { filters = Map.fromList [(ByUri uri, f) | (uri, Right f) <- filterPairs]
          , guards = Map.fromList [(ByUri uri, g) | (uri, Right g) <- guardPairs]
          }
  Right (handlers, impls, completion)
  where
    resolvedGuard uri symbol = do
      found <- implementationFor symbol uri cfg.guardImplementations "guard"
      Right (uri, maybe (Left (fromMaybe (netUriText uri) symbol)) Right found)

-- | The transition's bound implementation; no symbol means the default
-- 'passthrough'.
boundHandler :: Instance -> NetPath -> BoundHandler
boundHandler inst t = case handlerUri inst.iNet t >>= \uri -> Map.lookup uri inst.iHandlers of
  Just h -> h
  Nothing -> PureHandler passthrough

instanceLogger :: Net -> Text -> Maybe EventSink -> TelemetryLogger
instanceLogger net ident sink =
  let base = getLogger "impetus" sink
      fields = ("instance", String ident) : [("net", String n) | Just n <- [netName net]]
   in either (const base) id (bind fields base)

-- ---------------------------------------------------------------------------
-- Construction

validateInitialTokens :: Net -> NetPath -> [Token] -> Either Text ()
validateInitialTokens net p tokens = case lookupPlace p net of
  Just declared
    | Just c <- declared.color
    , (mismatch : _) <- [t | t <- tokens, t.color /= Just c] ->
        Left
          ( "initial marking for place " <> netPathText p <> " requires color " <> pyStr c <> ", got "
              <> pyOptStr mismatch.color
              <> " on "
              <> reprToken mismatch
          )
  _ -> Right ()

-- | @Instance(net, ...)@: record the construction batch to a fresh History.
newInstance :: Net -> InstanceConfig -> IO (Either InstanceError Instance)
newInstance net cfg = runExceptT $ do
  ident <- instanceIdentityText <$> (orRefuse . mkInstanceIdentity =<< maybe (liftIO uuid7Hex) pure cfg.suppliedIdentity)
  let logger = instanceLogger net ident cfg.telemetrySink
      at = cfg.constructionInstant
      initial = markingToList cfg.initialMarking
  forM_ initial $ \(p, ts) -> orRefuse (validateInitialTokens net p ts)
  (handlers, impls, completion) <- orRefuse (bindSymbols net cfg)
  store <- case cfg.historyStore of
    Nothing -> liftIO inMemoryHistoryStore
    Just h -> do
      n <- liftIO (Store.size h)
      when (n > 0) $
        refuse
          ( "cannot construct an Instance over a recorded history (" <> pyInt n
              <> " records): construction appends the instance's initial records; a recorded history is for resume()"
          )
      pure h
  let sources = sourceTransitions net
      records =
        [RInstanceCreated (InstanceCreated ident (netName net) at)]
          ++ [RTokensInitialized (TokensInitialized p ts at [] Nothing) | (p, ts) <- initial]
          ++ [RDeliveryRegistrationOpened (DeliveryRegistrationOpened s "default" Nothing at) | s <- sources]
  batch <- orRefuse (writerRecords records)
  liftIO (store.extend batch)
  queues <- applyAll Nothing batch emptyQueues
  stateRef <- liftIO . newIORef $
    State
      { sQueues = queues
      , sWatermark = at
      , sArmed = Map.fromList [(s, Set.singleton "default") | s <- sources]
      , sNextOccurrence = 1
      , sNextEntry = 1 + sum [length ts | (_, ts) <- initial]
      , sInFlight = IntMap.empty
      , sActivityOccurrences = IntMap.empty
      , sCancelled = OMap.empty
      , sFrozen = IntMap.empty
      , sTerminal = IntMap.empty
      , sQuarantined = IntMap.empty
      , sAccepted = Map.empty
      , sActiveScopes = Map.empty
      , sGenerations = Map.empty
      }
  lock <- liftIO (newMVar ())
  let inst = Instance net ident handlers impls completion cfg.schedulerPolicy store logger stateRef lock
  emitEvent
    inst
    "instance_created"
    [ ("places", int (Map.size (netPlaces net)))
    , ("transitions", int (Map.size (netTransitions net)))
    , ("records", int (length batch))
    , ("instant", numberJson at)
    ]
  pure inst

-- ---------------------------------------------------------------------------
-- Resume

-- | One initial token record the live constructor could emit.
validateReplayedInitialization :: Net -> TokensInitialized -> Instant -> Set NetPath -> Either Text (Set NetPath)
validateReplayedInitialization net r constructed initialized = do
  let p = netPathText r.place
  unless (hasPlace r.place net) $
    Left
      ( "replay divergence: unknown place " <> p
          <> " in the initial marking; the live constructor initializes only declared places"
      )
  when (Set.member r.place initialized) $
    Left ("replay divergence: initial marking place " <> p <> " must be initialized exactly once")
  when (null r.tokens) $
    Left ("replay divergence: initial marking place " <> p <> " has no tokens; the live constructor omits empty places")
  when (r.instant /= constructed) $
    Left
      ( "replay divergence: initial tokens on " <> p <> " use instant " <> pyInt r.instant
          <> ", not construction instant "
          <> pyInt constructed
      )
  when (not (null r.entries) || isJust r.scope) $
    Left
      ( "replay divergence: initial marking place " <> p
          <> " carries queue entries or scope; the live constructor records neither"
      )
  validateInitialTokens net r.place r.tokens
  Right (Set.insert r.place initialized)

-- | The complete prefix emitted by the live constructor.
validateConstructionBatch :: Net -> [Record] -> Maybe InstanceCreated -> Either Text ()
validateConstructionBatch net records identity = do
  created <-
    maybe (Left "replay divergence: the construction batch requires InstanceCreated as its first record") Right identity
  let visit (regs, started, initialized, ended) record
        | ended = case record of
            RTokensInitialized _ ->
              Left "replay divergence: TokensInitialized appears outside the contiguous initial construction prefix"
            _ -> Right (regs, started, initialized, ended)
        | RTokensInitialized r <- record = do
            when started $
              Left
                "replay divergence: initial construction prefix is a construction batch that requires every TokensInitialized record before its source registrations"
            initialized' <- validateReplayedInitialization net r created.instant initialized
            Right (regs, started, initialized', ended)
        | RDeliveryRegistrationOpened r <- record
        , isNothing r.occurrence =
            Right (r : regs, True, initialized, ended)
        | otherwise = Right (regs, started, initialized, True)
  (regsRev, _, _, _) <- foldM visit ([], False, Set.empty, False) (drop 1 records)
  let registrations = reverse regsRev
      expected = [DeliveryRegistrationOpened s "default" Nothing created.instant | s <- sourceTransitions net]
      spell = pyTuple . map (reprRecord . RDeliveryRegistrationOpened)
  when (registrations /= expected) $
    Left
      ( "replay divergence: initial construction prefix is a construction batch whose source registrations require exactly one ordered default open for every source; expected "
          <> spell expected
          <> ", found "
          <> spell registrations
      )

-- | The begin-batch shape rule, writer and replay alike: one selection per
-- consume (read) arc, in input-arc order, on each arc's place, weight tokens
-- each.
validateBindingShape :: Net -> Binding -> Text -> Either Text ()
validateBindingShape net b rejection =
  forM_ [(Consume, b.consumed, "consume" :: Text), (Read, b.read, "read")] $ \(mode, selections, noun) -> do
    let arcs = [a | a <- inputs net b.transition, a.mode == mode]
    when
      ( map fst selections /= map (.source) arcs
          || or [length ts /= a.weight | (a, (_, ts)) <- zip arcs selections]
      )
      $ Left
        ( rejection <> ": its " <> noun <> " selections do not match the transition's " <> noun
            <> " arcs — a live begin takes one "
            <> noun
            <> " selection per arc, in input-arc order, weight tokens each"
        )

validateReplayedOccurrence :: Instance -> FiringOccurrence -> Either Text ()
validateReplayedOccurrence inst o = do
  let t = o.binding.transition
      net = inst.iNet
      rejection = "cannot resume firing occurrence " <> pyInt o.occurrence <> " (" <> netPathText t <> ")"
  unless (hasTransition t net) $ Left (rejection <> ": not a transition of this net")
  when (isSource net t && null o.binding.delivered) $
    Left (rejection <> ": a scheduled selection on a source transition — a source fires only through accept_delivery()")
  when (not (isSource net t) && not (null o.binding.delivered)) $
    Left (rejection <> ": an external event on a transition with input arcs — only a source transition takes delivery")
  validateBindingShape net o.binding rejection
  let activityBound = isActivityBound (boundHandler inst t)
  when (isJust o.invocation && not activityBound) $
    Left
      ( rejection
          <> ": its begin batch froze an activity request, but the transition is not bound to an ActivityHandler — projection needs the handler that prepared it"
      )
  when (isNothing o.invocation && activityBound) $
    Left
      ( rejection
          <> ": the transition binds an ActivityHandler, but the begin batch froze no ActivityRequested — the live writer always freezes the request at begin"
      )

reprOptScope :: Maybe LifecycleScope -> Text
reprOptScope = maybe "None" (T.pack . show)

reprInts :: [Int] -> Text
reprInts = pyTuple . map pyInt

reprProductions :: [(NetPath, [Token])] -> Text
reprProductions xs = pyTuple [pyTuple [T.pack (show p), reprTokens ts] | (p, ts) <- xs]

validateAcceptedSourceProduction :: Net -> ExternalEventDelivered -> Text -> TokensProduced -> Set NetPath -> [Int] -> Either Text ()
validateAcceptedSourceProduction net accepted ident r produced expected = do
  let rejection = "cannot resume: accepted delivery identity " <> pyStr ident <> " source occurrence " <> pyInt accepted.occurrence
      p = netPathText r.place
  when (null r.tokens) $ Left (rejection <> " contains an empty TokensProduced record")
  when (Set.member r.place produced) $ Left (rejection <> " contains a second TokensProduced record for " <> p)
  when (r.scope /= accepted.scope) $
    Left
      ( rejection <> " production on " <> p <> " has lifecycle scope " <> reprOptScope r.scope
          <> ", not the accepted scope "
          <> reprOptScope accepted.scope
      )
  when (isJust r.scope && r.entries /= expected) $
    Left
      ( rejection <> " production on " <> p <> " has queue-entry identities " <> reprInts r.entries
          <> "; the writer's exact next identities are expected "
          <> reprInts expected
      )
  let outs = outputs net accepted.source
      unadmitted = [t | t <- r.tokens, not (any (\a -> a.target == r.place && arcAdmits a t.color) outs)]
  unless (null unadmitted) $
    Left
      ( rejection <> " production on " <> p <> " carries token(s) " <> reprTokens unadmitted
          <> " not admitted by any output arc of source "
          <> netPathText accepted.source
      )

validateDefaultSourceProductions :: Net -> ExternalEventDelivered -> Text -> [(NetPath, [Token])] -> Either Text ()
validateDefaultSourceProductions net accepted ident actual
  | isJust (handlerUri net accepted.source) = Right ()
  | otherwise = do
      let expected = route accepted.tokens (outputs net accepted.source)
          spelling xs = [(p, deliveryContent ts) | (p, ts) <- xs]
      when (spelling actual /= spelling expected) $
        Left
          ( "cannot resume: accepted delivery identity " <> pyStr ident <> " source occurrence "
              <> pyInt accepted.occurrence
              <> " default passthrough requires exact productions "
              <> reprProductions expected
              <> "; found "
              <> reprProductions actual
          )

data SourceFold = SourceFold
  { phases :: IntMap Int
  , phaseNames :: IntMap Text
  , endInstants :: IntMap Instant
  , terminals :: IntMap Text
  , producedPlaces :: IntMap (Set NetPath)
  , productions :: IntMap [(NetPath, [Token])]
  , cancelledSet :: IntSet
  , observed :: IntSet
  , nextEntryF :: Int
  , activeCompletion :: Maybe Int
  }

-- | Every accepted source occurrence has only a writer-valid pure
-- lifecycle: its acceptance pair, then no end; a lone failure; lifecycle
-- cancellation; or one atomic ordered completion batch.
validateAcceptedSourceOccurrences :: Net -> [Record] -> Map Text Record -> Either Text ()
validateAcceptedSourceOccurrences net history accepted = void (foldM visit start history)
  where
    sourceOccurrences =
      IntMap.fromList [(r.occurrence, (ident, r)) | (ident, RExternalEventDelivered r) <- Map.toList accepted]
    start = SourceFold IntMap.empty IntMap.empty IntMap.empty IntMap.empty IntMap.empty IntMap.empty IntSet.empty IntSet.empty 1 Nothing
    rankOf = \case
      RTokensProduced _ -> Just (0 :: Int)
      RDeliveryRegistrationClosed _ -> Just 1
      RDeliveryRegistrationOpened _ -> Just 2
      RFiringCompleted _ -> Just 3
      _ -> Nothing
    reprOcc = maybe "None" pyInt
    visit f0 record = do
      let o = recordOccurrence record
          name = recordName record
          (expected, f) = case record of
            RTokensInitialized r -> entriesStep f0 r.tokens r.entries
            RTokensProduced r -> entriesStep f0 r.tokens r.entries
            _ -> ([], f0)
      forM_ f.activeCompletion $ \active -> when (o /= Just active) $ do
        let (ident, acceptedRecord) = sourceOccurrences IntMap.! active
        Left
          ( "cannot resume: accepted delivery identity " <> pyStr ident <> " source occurrence "
              <> pyInt acceptedRecord.occurrence
              <> " completion batch was interrupted by "
              <> name
              <> " for occurrence "
              <> reprOcc o
          )
      case record of
        RScopeClosed r -> cancel f name r.cancelled
        RScopeReset r -> cancel f name r.cancelled
        _ -> case o >>= \n -> (n,) <$> IntMap.lookup n sourceOccurrences of
          Nothing -> Right f
          Just (n, (ident, acceptedRecord)) -> occurrenceStep f record name n ident acceptedRecord expected
    entriesStep f tokens entries =
      let expected = take (length tokens) [f.nextEntryF ..]
          recorded = if null entries then expected else entries
          next = if null recorded then f.nextEntryF else max f.nextEntryF (maximum recorded + 1)
       in (expected, f {nextEntryF = next})
    cancel f name occurrences = foldM (cancelOne name) f occurrences
    cancelOne name f n = case IntMap.lookup n sourceOccurrences of
      Nothing -> Right f
      Just (ident, acceptedRecord) -> do
        let prefix = "cannot resume: accepted delivery identity " <> pyStr ident <> " source occurrence " <> pyInt acceptedRecord.occurrence
        unless (IntSet.member n f.observed) $
          Left (prefix <> " contains " <> name <> " cancellation before its acceptance pair")
        when (IntMap.member n f.phases || IntMap.member n f.terminals) $ do
          let prior = fromMaybe "None" (maybe (IntMap.lookup n f.terminals) Just (IntMap.lookup n f.phaseNames))
          Left (prefix <> " was lifecycle-cancelled after " <> prior)
        Right f {cancelledSet = IntSet.insert n f.cancelledSet}
    occurrenceStep f record name n ident acceptedRecord expected = case record of
      RExternalEventDelivered _ -> Right f
      RFiringBegun _ -> Right f {observed = IntSet.insert n f.observed}
      _ -> do
        let rejection = "cannot resume: accepted delivery identity " <> pyStr ident <> " source occurrence " <> pyInt n
        unless (IntSet.member n f.observed) $ Left (rejection <> " contains " <> name <> " before its acceptance pair")
        when (IntSet.member n f.cancelledSet) $ Left (rejection <> " contains " <> name <> " after lifecycle cancellation")
        forM_ (IntMap.lookup n f.terminals) $ \terminal -> Left (rejection <> " contains " <> name <> " after " <> terminal)
        when (isActivityOrSelection record) $
          Left
            ( rejection <> " contains " <> name
                <> " — a source delivery is a pure occurrence with no consume, read, or activity records"
            )
        case record of
          RFiringFailed _ -> do
            forM_ (IntMap.lookup n f.phaseNames) $ \prior ->
              Left
                ( rejection <> " contains FiringFailed after " <> prior
                    <> " — a pure source failure batch contains only FiringFailed"
                )
            Right f {terminals = IntMap.insert n name f.terminals}
          _ -> do
            when (isRegistration record && isNothing (handlerUri net acceptedRecord.source)) $
              Left
                ( rejection <> " default passthrough does not permit delivery-registration effects; found " <> name
                )
            rank <- maybe (Left (rejection <> " contains writer-invalid " <> name)) Right (rankOf record)
            let f1 = f {activeCompletion = Just (fromMaybe n f.activeCompletion)}
                priorRank = IntMap.findWithDefault (-1) n f1.phases
                instant = recordInstant record
            when (rank < priorRank) $
              Left (rejection <> " contains disordered " <> name <> " after " <> IntMap.findWithDefault "" n f1.phaseNames)
            forM_ (IntMap.lookup n f1.endInstants) $ \endInstant ->
              when (instant /= endInstant) $
                Left
                  ( rejection <> " completion batch changes instant from " <> pyInt endInstant <> " to "
                      <> pyInt instant
                  )
            let f2 =
                  f1
                    { endInstants = IntMap.insertWith (\_ old -> old) n instant f1.endInstants
                    , phases = IntMap.insert n rank f1.phases
                    , phaseNames = IntMap.insert n name f1.phaseNames
                    }
            case record of
              RTokensProduced r -> do
                let places = IntMap.findWithDefault Set.empty n f2.producedPlaces
                validateAcceptedSourceProduction net acceptedRecord ident r places expected
                Right
                  f2
                    { producedPlaces = IntMap.insert n (Set.insert r.place places) f2.producedPlaces
                    , productions = IntMap.insertWith (\new old -> old ++ new) n [(r.place, r.tokens)] f2.productions
                    }
              RFiringCompleted _ -> do
                validateDefaultSourceProductions net acceptedRecord ident (IntMap.findWithDefault [] n f2.productions)
                Right f2 {terminals = IntMap.insert n name f2.terminals, activeCompletion = Nothing}
              _ -> Right f2
    isActivityOrSelection = \case
      RTokensConsumed _ -> True
      RTokensRead _ -> True
      RActivityRequested _ -> True
      RActivityCompleted _ -> True
      RActivityFailed _ -> True
      RActivityTerminalQuarantined _ -> True
      _ -> False
    isRegistration = \case
      RDeliveryRegistrationClosed _ -> True
      RDeliveryRegistrationOpened _ -> True
      _ -> False

-- | @Instance.resume(net, history, ...)@: rebuild a live instance from its
-- recorded History. Nothing is appended; the resumed instance keeps
-- appending to the same store.
resume :: Net -> HistoryStore -> InstanceConfig -> IO (Either InstanceError Instance)
resume net store cfg = runExceptT $ do
  history <- liftIO (Store.records store)
  when (null history) $
    refuse "cannot resume from an empty history: nothing is recorded — construct an Instance instead"
  orRefuse (validateHistoryRecords history)
  identityRecord <- orRefuse (replayInstanceIdentity history)
  orRefuse (validateConstructionBatch net history identityRecord)
  created <- maybe (refuse "replay divergence: the construction batch requires InstanceCreated as its first record") pure identityRecord
  case (created.name, netName net) of
    (Just recorded, Just supplied)
      | recorded /= supplied ->
          refuse
            ( "cannot resume: the history records net name " <> pyStr recorded <> " but the supplied net is named "
                <> pyStr supplied
                <> " — a foreign trace"
            )
    _ -> pure ()
  ident <- instanceIdentityText <$> orRefuse (mkInstanceIdentity created.instanceId)
  let logger = instanceLogger net ident cfg.telemetrySink
  (handlers, impls, completion) <- orRefuse (bindSymbols net cfg)
  lock <- liftIO (newMVar ())
  placeholder <- liftIO (newIORef emptyState)
  let inst = Instance net ident handlers impls completion cfg.schedulerPolicy store logger placeholder lock
  forM_ [r | RCandidateSelected r <- history] $ \r -> do
    let prefix = "cannot resume firing occurrence " <> pyInt r.occurrence <> " (" <> netPathText r.transition <> "): "
    unless (hasTransition r.transition net) $ refuse (prefix <> "not a transition of this net")
    when (isSource net r.transition) $
      refuse (prefix <> "a scheduled selection on a source transition — a source fires only through accept_delivery()")
  queues <- orRefuse (replayQueues history)
  forM_ (markingPlaces (queuesMarking queues)) $ \p ->
    unless (hasPlace p net) $ refuse ("cannot resume: token records on " <> netPathText p <> ": not a place of this net")
  w <- orRefuse (replayWatermark history)
  armedReplayed <- orRefuse (replayArmed history)
  forM_ (OMap.keys armedReplayed) $ \s -> do
    unless (hasTransition s net) $
      refuse ("cannot resume: delivery-registration records on " <> netPathText s <> ": not a transition of this net")
    unless (isSource net s) $
      refuse
        ( "cannot resume: delivery-registration records on transition " <> netPathText s
            <> ": it has input arcs — only a source transition has delivery registrations"
        )
  let armedNow = Map.fromList [(s, OMap.findWithDefault Set.empty s armedReplayed) | s <- sourceTransitions net]
  live <- orRefuse (replayInFlight history)
  let effectOccurrences =
        IntSet.fromList $
          [n | RDeliveryRegistrationOpened r <- history, Just n <- [r.occurrence]]
            ++ [n | RDeliveryRegistrationClosed r <- history, Just n <- [r.occurrence]]
  effected <- orRefuse (replayFiringOccurrences history effectOccurrences)
  let replayed = foldl (\m o -> OMap.insert o.occurrence o m) OMap.empty (live ++ effected)
  forM_ (OMap.elems replayed) (orRefuse . validateReplayedOccurrence inst)
  activity <- orRefuse (replayActivityOccurrences history)
  cancelledOccurrences <- orRefuse (replayCancelled history)
  frozen <- orRefuse (replayProjectionPending history)
  terminal <- orRefuse (replayTerminalActivity history)
  quarantined <- orRefuse (replayQuarantinedActivity history)
  forM_ history $ \record -> do
    let check src ident' = do
          unless (hasTransition src net) $
            refuse
              ( "cannot resume: accepted delivery identity " <> pyStr ident' <> " records source " <> netPathText src
                  <> ": not a transition of this net"
              )
          unless (isSource net src) $
            refuse
              ( "cannot resume: accepted delivery identity " <> pyStr ident' <> " records transition " <> netPathText src
                  <> " with input arcs — only a source transition can accept delivery"
              )
    case record of
      RExternalEventDelivered r -> check r.source r.identity
      RScopedDeliveryDropped r -> check r.source r.identity
      RScopedDeliveryQuarantined r -> check r.source r.identity
      _ -> pure ()
  acceptedIdentities <- orRefuse (replayAcceptedIdentities history)
  orRefuse (validateAcceptedSourceOccurrences net history acceptedIdentities)
  nextEntry <- orRefuse (replayNextQueueIdentity history)
  (active, generations) <- orRefuse (replayScopes history)
  let inactive = [o.occurrence | o <- live, Just s <- [o.scope], Map.lookup (scopeName s) active /= Just s]
  unless (null inactive) $
    refuse ("replay divergence: lifecycle close left scoped firing occurrence(s) " <> reprInts inactive <> " in flight")
  putState inst $
    State
      { sQueues = queues
      , sWatermark = w
      , sArmed = armedNow
      , sNextOccurrence = replayNextOccurrence history
      , sNextEntry = nextEntry
      , sInFlight = IntMap.fromList [(o.occurrence, o) | o <- live]
      , sActivityOccurrences = IntMap.fromList [(o.occurrence, o) | o <- activity]
      , sCancelled = OMap.fromList [(o.occurrence, o) | o <- cancelledOccurrences]
      , sFrozen = frozen
      , sTerminal = terminal
      , sQuarantined = quarantined
      , sAccepted = acceptedIdentities
      , sActiveScopes = active
      , sGenerations = generations
      }
  emitEvent
    inst
    "instance_resumed"
    [("records", int (length history)), ("watermark", numberJson w), ("in_flight", int (length live))]
  pure inst

emptyState :: State
emptyState =
  State emptyQueues (IntNumber 0) Map.empty 1 1 IntMap.empty IntMap.empty OMap.empty IntMap.empty IntMap.empty IntMap.empty Map.empty Map.empty Map.empty

-- ---------------------------------------------------------------------------
-- Reads

readState :: Instance -> IO State
readState inst = readIORef inst.iState

-- | The current marking: the time-blind view of the pair-queues.
marking :: Instance -> IO Marking
marking inst = queuesMarking . (.sQueues) <$> readState inst

-- | The clock watermark: the instant of the latest appended record.
watermark :: Instance -> IO Instant
watermark inst = (.sWatermark) <$> readState inst

clockOf :: State -> E.Clock
clockOf st = E.Clock st.sWatermark (queuesEntryInstants st.sQueues)

surveyAt :: Instance -> State -> Instant -> IO ([Binding], [Diagnostic])
surveyAt inst st at =
  either (throwIO . InstanceInvariant . T.pack . show) pure $
    E.candidatesWithDiagnostics inst.iNet (queuesMarking st.sQueues) inst.iImplementations (Just (E.Clock at (queuesEntryInstants st.sQueues)))

-- | A candidate computation the Instance's own resolution makes impossible
-- (every declaration is resolved at construction and the clock is always
-- supplied).
newtype InstanceInvariant = InstanceInvariant Text
  deriving stock (Show)

instance Exception InstanceInvariant

-- | Enabled firing candidates at the watermark, in scheduler order.
candidates :: Instance -> IO [Binding]
candidates inst = fst <$> candidatesWithDiagnostics inst

-- | Candidates with the evaluation diagnostics (the reference's warnings).
candidatesWithDiagnostics :: Instance -> IO ([Binding], [Diagnostic])
candidatesWithDiagnostics inst = do
  st <- readState inst
  surveyAt inst st st.sWatermark

-- | Distinct enabled transitions, in stable order.
enabledTransitions :: Instance -> IO [NetPath]
enabledTransitions inst = do
  bindings <- candidates inst
  pure (foldl (\seen b -> if b.transition `elem` seen then seen else seen ++ [b.transition]) [] bindings)

-- | The armed delivery registrations per source transition (sealed sources
-- are absent).
armed :: Instance -> IO (Map NetPath (Set Text))
armed inst = Map.filter (not . Set.null) . (.sArmed) <$> readState inst

-- | Occurrences begun and not ended, in begin order.
inFlight :: Instance -> IO [FiringOccurrence]
inFlight inst = IntMap.elems . (.sInFlight) <$> readState inst

pendingOf :: State -> [FiringOccurrence]
pendingOf st = [o | o <- IntMap.elems st.sInFlight, IntMap.member o.occurrence st.sFrozen]

-- | In-flight occurrences whose terminal activity fact is frozen but whose
-- firing has not ended, in begin order.
projectionPending :: Instance -> IO [FiringOccurrence]
projectionPending inst = pendingOf <$> readState inst

-- | The exact active generation per scope name.
activeScopes :: Instance -> IO (Map Text LifecycleScope)
activeScopes inst = (.sActiveScopes) <$> readState inst

-- | Occurrences terminalized by lifecycle close/reset, in canonical order.
cancelled :: Instance -> IO [FiringOccurrence]
cancelled inst = OMap.elems . (.sCancelled) <$> readState inst

-- | Every canonical Activity occurrence.
activityOccurrences :: Instance -> IO (IntMap FiringOccurrence)
activityOccurrences inst = (.sActivityOccurrences) <$> readState inst

-- | Frozen outcomes still awaiting a firing boundary.
pendingActivityOutcomes :: Instance -> IO (IntMap TerminalOutcome)
pendingActivityOutcomes inst = (.sFrozen) <$> readState inst

nextMaturationOf :: Instance -> State -> IO (Maybe Instant)
nextMaturationOf inst st =
  either (throwIO . InstanceInvariant . T.pack . show) pure $
    E.nextMaturation inst.iNet (queuesMarking st.sQueues) inst.iImplementations (Just (clockOf st))

-- | The earliest maturation among bindings enabled but for their timers.
nextMaturation :: Instance -> IO (Maybe Instant)
nextMaturation inst = readState inst >>= nextMaturationOf inst

quiescentOf :: Instance -> State -> IO Bool
quiescentOf inst st = do
  (enabled, _) <- surveyAt inst st st.sWatermark
  pending <- nextMaturationOf inst st
  pure (null enabled && isNothing pending && IntMap.null st.sInFlight)

-- | Nothing enabled, nothing maturing, nothing in flight.
isQuiescent :: Instance -> IO Bool
isQuiescent inst = readState inst >>= quiescentOf inst

-- | The derived status.
status :: Instance -> IO Status
status inst = fst <$> statusWithDiagnostics inst

-- | The status with the completion condition's evaluation diagnostic (the
-- reference's @CompletionEvaluationWarning@), if it raised.
statusWithDiagnostics :: Instance -> IO (Status, [Text])
statusWithDiagnostics inst = do
  st <- readState inst
  quiescent <- quiescentOf inst st
  if not quiescent
    then pure (Running, [])
    else do
      (holds, diagnostics) <- case inst.iCompletion of
        Nothing -> pure (False, [])
        Just condition -> do
          let current = queuesMarking st.sQueues
          outcome <-
            try (evaluate (force (condition current))) >>= \case
              Left e | isAsync e -> throwIO e
              Left e -> pure (Left (exceptionFailureText e))
              Right value -> pure value
          pure $ case outcome of
            Right value -> (value, [])
            Left failure ->
              ( False
              , [ "completion condition " <> maybe "None" reprCompletionDeclaration (netCompletion inst.iNet)
                    <> " raised "
                    <> failure
                    <> " evaluating "
                    <> T.pack (show current)
                    <> "; read as not holding"
                ]
              )
      let result
            | isJust inst.iCompletion && holds = Completed
            | any (not . Set.null) (Map.elems st.sArmed) = Awaiting
            | isJust inst.iCompletion = Stuck
            | otherwise = Terminated
      pure (result, diagnostics)

-- ---------------------------------------------------------------------------
-- Lifecycle scopes

-- | Open the next generation for a name as one canonical fact.
openScope :: Instance -> Text -> Maybe Instant -> IO (Either InstanceError LifecycleScope)
openScope inst name at = locked inst $ do
  unless (validScopeName name) $ refuse scopeNameError
  st <- getState inst
  when (Map.member name st.sActiveScopes) $
    refuse ("cannot open lifecycle scope " <> pyStr name <> ": a generation is already active")
  scope <- orRefuse (lifecycleScope name (Map.findWithDefault 0 name st.sGenerations + 1))
  let instant = effective st.sWatermark at
  _ <- appendBatch inst [RScopeOpened (ScopeOpened scope instant)]
  putState
    inst
    st
      { sWatermark = instant
      , sActiveScopes = Map.insert name scope st.sActiveScopes
      , sGenerations = Map.insert name (scopeGeneration scope) st.sGenerations
      }
  pure scope

scopeClosure :: State -> LifecycleScope -> Either Text ScopeClosure
scopeClosure st scope = do
  let shown = T.pack (show scope)
  when (Map.lookup (scopeName scope) st.sActiveScopes /= Just scope) $
    Left ("cannot close lifecycle scope " <> shown <> ": it is not the active generation")
  let pending = [o.occurrence | o <- pendingOf st, o.scope == Just scope]
  unless (null pending) $
    Left
      ( "cannot close lifecycle scope " <> shown <> ": accepted Activity terminal(s) " <> reprInts pending
          <> " still require deterministic projection"
      )
  let discarded =
        [ i
        | q <- OMap.elems (queuesByPlace st.sQueues)
        , (Just i, Just provenance) <- zip (toList (queueIdentities q)) (toList (queueScopes q))
        , provenance == scope
        ]
      cancelledIds = [o.occurrence | o <- IntMap.elems st.sInFlight, o.scope == Just scope]
  Right (ScopeClosure scope discarded cancelledIds)

applyScopeTerminal :: Instance -> State -> Record -> ScopeClosure -> Maybe LifecycleScope -> Instant -> Door ()
applyScopeTerminal inst st record closure opened instant = do
  queues <- orRuntime (applyMovement Nothing record st.sQueues)
  let active0 = Map.delete (scopeName closure.scope) st.sActiveScopes
      (active, generations) = case opened of
        Nothing -> (active0, st.sGenerations)
        Just o -> (Map.insert (scopeName o) o active0, Map.insert (scopeName o) (scopeGeneration o) st.sGenerations)
      step' (flight, frozen, gone) n = case IntMap.lookup n flight of
        Just o -> (IntMap.delete n flight, IntMap.delete n frozen, OMap.insert n o gone)
        Nothing -> (flight, frozen, gone)
      (flight', frozen', cancelled') = foldl step' (st.sInFlight, st.sFrozen, st.sCancelled) closure.cancelled
  putState
    inst
    st
      { sQueues = queues
      , sWatermark = instant
      , sActiveScopes = active
      , sGenerations = generations
      , sInFlight = flight'
      , sFrozen = frozen'
      , sCancelled = cancelled'
      }

-- | Close one exact active generation and apply its exact cleanup
-- atomically.
closeScope :: Instance -> LifecycleScope -> Maybe Instant -> IO (Either InstanceError ScopeClosure)
closeScope inst scope at = locked inst $ do
  st <- getState inst
  closure <- orRefuse (scopeClosure st scope)
  let instant = effective st.sWatermark at
  batch <- appendBatch inst [RScopeClosed (ScopeClosed scope closure.discarded closure.cancelled instant)]
  forM_ batch $ \record -> applyScopeTerminal inst st record closure Nothing instant
  pure closure

-- | Atomically close one generation and open its immediate successor.
resetScope :: Instance -> LifecycleScope -> Maybe Instant -> IO (Either InstanceError LifecycleScope)
resetScope inst scope at = locked inst $ do
  st <- getState inst
  closure <- orRefuse (scopeClosure st scope)
  opened <- orRefuse (lifecycleScope (scopeName scope) (scopeGeneration scope + 1))
  let instant = effective st.sWatermark at
  batch <- appendBatch inst [RScopeReset (ScopeReset scope opened closure.discarded closure.cancelled instant)]
  forM_ batch $ \record -> applyScopeTerminal inst st record closure (Just opened) instant
  pure opened

-- ---------------------------------------------------------------------------
-- Begin

-- | Begin a durable firing occurrence for a scheduled binding: mint the
-- occurrence, record the selection, account the consumed tokens. An
-- ActivityHandler's @prepare@ runs first, before anything is appended, and
-- its invocation joins the begin batch as @ActivityRequested@.
begin :: Instance -> Binding -> Maybe Instant -> IO (Either InstanceError FiringOccurrence)
begin inst b at = locked inst (beginDoor inst b at)

beginDoor :: Instance -> Binding -> Maybe Instant -> Door FiringOccurrence
beginDoor inst b at = do
  let t = b.transition
      net = inst.iNet
      prefix = "cannot begin firing " <> netPathText t
  unless (hasTransition t net) $ refuse (prefix <> ": not a transition of this net")
  when (isSource net t) $
    refuse (prefix <> ": a source transition is never scheduled — it fires only through accept_delivery()")
  unless (null b.delivered) $
    refuse
      ( "cannot begin a delivered binding for " <> netPathText t
          <> ": a source firing enters through accept_delivery()"
      )
  orRefuse (validateBindingShape net b prefix)
  prepared <- preparedInvocation inst b
  withExceptT stale $
    beginOccurrence inst b at (\o i -> RCandidateSelected (CandidateSelected t o i)) prepared Nothing
  where
    stale = \case
      Refused m -> Refused ("cannot begin firing " <> netPathText b.transition <> ": stale selection — " <> m)
      other -> other

-- | The prepare half of the Activity seam, run before anything is appended.
preparedInvocation :: Instance -> Binding -> Door (Maybe ActivityInvocation)
preparedInvocation inst b = case boundHandler inst b.transition of
  PureHandler _ -> pure Nothing
  ActivityBound h -> do
    let prefix = "cannot begin firing " <> netPathText b.transition
    raw <- handlerDoor (forcePrepared (h.prepare b))
    inv <- orRefuse (activityInvocation raw)
    forM_ [("correlation" :: Text, inv.correlation), ("idempotency", inv.idempotency)] $ \(name, value) ->
      forM_ value $ \v -> when ("occurrence-" `T.isPrefixOf` v) $
        refuse
          ( prefix <> ": " <> name <> " " <> pyStr v
              <> " uses the writer-reserved 'occurrence-' prefix — the derived self-identity namespace; supply an identity outside it, or None for the writer to derive"
          )
    input <- orRefuse (canonicalPayload inv.input (prefix <> ": invalid activity input"))
    pure (Just (ActivityInvocation inv.activity input inv.policy inv.correlation inv.idempotency))

-- | Resolve a value binding to exact live queue occurrences.
bindingEntries :: Queues -> Binding -> Either Text ([[(Maybe Int, Maybe LifecycleScope)]], [LifecycleScope])
bindingEntries queues b = do
  let places0 = queuesByPlace queues
      missing p tok = "cannot consume " <> reprToken tok <> " from " <> netPathText p <> ": token not present"
  (places1, consumedSel) <-
    foldM
      ( \(places, acc) (p, ts) -> do
          let queue = OMap.findWithDefault emptyQueue p places
          selected <- either (Left . missing p) Right (selectedOccurrences ts queue)
          let identities = [i | (Just i, _) <- selected]
          queue' <-
            if length identities == length ts
              then removeExact (zip ts identities) queue
              else either (Left . missing p) Right (removeTokens ts queue)
          Right (OMap.insert p queue' places, acc ++ [selected])
      )
      (places0, [])
      b.consumed
  readSel <-
    forM b.read $ \(p, ts) ->
      either (Left . missing p) Right (selectedOccurrences ts (OMap.findWithDefault emptyQueue p places1))
  let selections = consumedSel ++ readSel
  Right (selections, [s | sel <- selections, (_, Just s) <- sel])

-- | The one home of an occurrence's birth: the initiation record first
-- (minting the id), the begin records after it, an impure occurrence's
-- @ActivityRequested@ last — one batch.
beginOccurrence ::
  Instance ->
  Binding ->
  Maybe Instant ->
  (Int -> Instant -> Record) ->
  Maybe ActivityInvocation ->
  Maybe LifecycleScope ->
  Door FiringOccurrence
beginOccurrence inst b at initiation prepared supplied = do
  st <- getState inst
  let instant = effective st.sWatermark at
      t = b.transition
      o = st.sNextOccurrence
  (effects, _) <- orRefuse (beginFiring (queuesMarking st.sQueues) b)
  (selected, inferred) <- orRefuse (bindingEntries st.sQueues b)
  let provenance = Set.fromList (inferred ++ maybeToList supplied)
  when (Set.size provenance > 1) $
    refuse
      ( "firing " <> netPathText t <> " combines different lifecycle scopes: "
          <> pyList (map (T.pack . show) (Set.toList provenance))
      )
  let scope = Set.lookupMin provenance
  narrated <- forM (zip effects selected) $ \(effect, entrySelection) -> do
    when (any (isNothing . fst) entrySelection) $
      throwE (RuntimeRefused "live queue entry has no durable occurrence identity")
    let entries = [i | (Just i, _) <- entrySelection]
        recorded = if isJust scope then entries else []
    pure $ case effect of
      ConsumedTokens p ts -> RTokensConsumed (TokensConsumed p ts o recorded scope instant)
      ReadTokens p ts -> RTokensRead (TokensRead p ts o recorded scope instant)
  let selfIdentity = "occurrence-" <> pyInt o
      invocation' =
        fmap
          ( \inv ->
              ActivityInvocation
                inv.activity
                inv.input
                inv.policy
                (Just (fromMaybe selfIdentity inv.correlation))
                (Just (fromMaybe selfIdentity inv.idempotency))
          )
          prepared
      requested =
        [ RActivityRequested
            ( ActivityRequested
                t
                inv.activity
                inv.input
                inv.policy
                (fromMaybe selfIdentity inv.correlation)
                (fromMaybe selfIdentity inv.idempotency)
                o
                scope
                instant
            )
        | Just inv <- [invocation']
        ]
      records = RFiringBegun (FiringBegun t o scope instant) : narrated ++ requested
  batch <- appendBatch inst (initiation o instant : records)
  let committed = drop 1 batch
      occurrence' = FiringOccurrence o b committed invocation' scope
  queues <- applyAll Nothing committed st.sQueues
  putState
    inst
    st
      { sQueues = queues
      , sWatermark = instant
      , sNextOccurrence = o + 1
      , sInFlight = IntMap.insert o occurrence' st.sInFlight
      , sActivityOccurrences =
          if isJust invocation' then IntMap.insert o occurrence' st.sActivityOccurrences else st.sActivityOccurrences
      }
  emitEvent
    inst
    "firing_begun"
    [ ("transition", text (netPathText t))
    , ("occurrence", int o)
    , ("instant", numberJson instant)
    , ("impure", Bool (isJust invocation'))
    ]
  pure occurrence'

-- ---------------------------------------------------------------------------
-- Terminal Activity facts

ensureInFlight :: Instance -> FiringOccurrence -> Text -> Door ()
ensureInFlight inst o verb = do
  st <- getState inst
  let prefix = "cannot " <> verb <> " firing occurrence " <> pyInt o.occurrence <> " (" <> netPathText o.binding.transition <> "): "
  unless (IntMap.lookup o.occurrence st.sInFlight == Just o) $
    if o.occurrence < st.sNextOccurrence && not (IntMap.member o.occurrence st.sInFlight)
      then refuse (prefix <> "not in flight — this instance's occurrence " <> pyInt o.occurrence <> " already ended")
      else refuse (prefix <> "this instance never began it")

-- | Freeze the Activity's terminal result as @ActivityCompleted@, its own
-- append, before deterministic projection. The first terminal fact wins: an
-- equal re-record acknowledges, a different one is a conflict; a
-- lifecycle-cancelled occurrence quarantines the late report.
recordActivityCompletion :: Instance -> FiringOccurrence -> Json -> Maybe Instant -> IO (Either InstanceError TerminalDisposition)
recordActivityCompletion inst o result at = locked inst (recordCompletionDoor inst o result at)

recordCompletionDoor :: Instance -> FiringOccurrence -> Json -> Maybe Instant -> Door TerminalDisposition
recordCompletionDoor inst o result at = do
  st <- getState inst
  let rejection =
        "cannot record an activity completion for firing occurrence " <> pyInt o.occurrence <> " ("
          <> netPathText o.binding.transition
          <> ")"
      canonicalResult = orRefuse (canonicalPayload result (rejection <> ": invalid activity result"))
  if OMap.member o.occurrence st.sCancelled
    then do
      value <- canonicalResult
      quarantineTerminal inst o (terminalOutcomeJson (TerminalResult value)) at
    else case IntMap.lookup o.occurrence st.sTerminal of
      Just terminal -> do
        value <- canonicalResult
        case terminal of
          TerminalFailure f ->
            refuse
              ( rejection <> ": the occurrence ended in terminal activity failure (" <> pyStr (failureFields f).failureError
                  <> ") — a failed occurrence cannot retroactively succeed, and a different late result is an operational conflict [DR 2026-07-14 source-delivery-projection-and-identity]"
              )
          TerminalResult prior
            | sameCanonical prior value -> do
                emitEvent inst "activity_redelivery_acknowledged" [("occurrence", int o.occurrence)]
                pure TerminalAcknowledged
            | otherwise ->
                refuse (rejection <> ": the occurrence ended with a different result — an operational conflict, not a redelivery")
      Nothing -> do
        ensureInFlight inst o "record an activity completion for"
        when (isNothing o.invocation) $
          refuse (rejection <> ": a pure firing runs no activity — complete() takes its handler's result directly")
        value <- canonicalResult
        case IntMap.lookup o.occurrence st.sFrozen of
          Just (TerminalFailure _) ->
            refuse
              ( rejection
                  <> ": a terminal activity fact already exists with a failure — a failed occurrence cannot retroactively succeed"
              )
          Just (TerminalResult frozen)
            | sameCanonical frozen value -> do
                emitEvent inst "activity_redelivery_acknowledged" [("occurrence", int o.occurrence)]
                pure TerminalAcknowledged
            | otherwise ->
                refuse
                  ( rejection
                      <> ": a terminal activity fact already exists with a different result — an operational conflict, not a redelivery"
                  )
          Nothing -> do
            let instant = effective st.sWatermark at
            _ <- appendBatch inst [RActivityCompleted (ActivityCompleted o.binding.transition value o.occurrence instant)]
            putState inst st {sWatermark = instant, sFrozen = IntMap.insert o.occurrence (TerminalResult value) st.sFrozen}
            emitEvent
              inst
              "activity_result_recorded"
              [ ("transition", text (netPathText o.binding.transition))
              , ("occurrence", int o.occurrence)
              , ("instant", numberJson instant)
              ]
            pure TerminalAccepted

-- | Freeze one canonical classified failure before projection or halt.
recordActivityFailure :: Instance -> FiringOccurrence -> ActivityFailure -> Maybe Instant -> IO (Either InstanceError TerminalDisposition)
recordActivityFailure inst o failure at = locked inst (recordFailureDoor inst o failure at)

recordFailureDoor :: Instance -> FiringOccurrence -> ActivityFailure -> Maybe Instant -> Door TerminalDisposition
recordFailureDoor inst o failure at = do
  st <- getState inst
  let conflicting = refuse "conflicting terminal activity report"
  if OMap.member o.occurrence st.sCancelled
    then quarantineTerminal inst o (terminalOutcomeJson (TerminalFailure failure)) at
    else case IntMap.lookup o.occurrence st.sTerminal of
      Just (TerminalFailure terminal) | sameFailure terminal failure -> pure TerminalAcknowledged
      Just _ -> conflicting
      Nothing -> do
        ensureInFlight inst o "record an activity failure for"
        when (isNothing o.invocation) $ refuse "cannot record an activity failure for a pure firing — it runs no activity"
        case IntMap.lookup o.occurrence st.sFrozen of
          Just (TerminalFailure frozen) | sameFailure frozen failure -> pure TerminalAcknowledged
          Just _ -> conflicting
          Nothing -> do
            let instant = effective st.sWatermark at
                x = failureFields failure
            _ <-
              appendBatch
                inst
                [ RActivityFailed
                    ( ActivityFailed
                        o.binding.transition
                        x.failureError
                        x.failureKind
                        x.failureDetails
                        x.failureRetryable
                        x.failureRetryAfter
                        o.occurrence
                        instant
                    )
                ]
            putState inst st {sWatermark = instant, sFrozen = IntMap.insert o.occurrence (TerminalFailure failure) st.sFrozen}
            pure TerminalAccepted

quarantineTerminal :: Instance -> FiringOccurrence -> Json -> Maybe Instant -> Door TerminalDisposition
quarantineTerminal inst o outcome at = do
  st <- getState inst
  let conflicting = refuse "conflicting terminal activity report"
  scope <- case (OMap.lookup o.occurrence st.sCancelled, o.invocation, o.scope) of
    (Just c, Just _, Just s) | c == o -> pure s
    _ -> conflicting
  case IntMap.lookup o.occurrence st.sQuarantined of
    Just prior
      | sameCanonical prior outcome -> pure TerminalAcknowledged
      | otherwise -> conflicting
    Nothing -> do
      let instant = effective st.sWatermark at
      _ <-
        appendBatch
          inst
          [RActivityTerminalQuarantined (ActivityTerminalQuarantined o.binding.transition outcome scope o.occurrence instant)]
      putState inst st {sWatermark = instant, sQuarantined = IntMap.insert o.occurrence outcome st.sQuarantined}
      pure TerminalQuarantined

-- ---------------------------------------------------------------------------
-- Completion

-- | Complete one occurrence. A pure occurrence takes its handler's result;
-- an impure one takes 'Nothing' and projects its frozen Activity fact. A
-- History refusal of the prepared batch is rethrown as the store's own
-- exception, exactly as the reference preserves its backend's refusal.
complete :: Instance -> FiringOccurrence -> Maybe HandlerResult -> Maybe Instant -> IO (Either InstanceError FiringOutcome)
complete inst o result at =
  commitCompletion inst o result at >>= \case
    Left (CommitRefused e) -> throwIO e
    other -> pure other

-- | @_commit_completion@: as 'complete', but a History refusal of the
-- prepared batch is the distinguishable 'CommitRefused'.
commitCompletion :: Instance -> FiringOccurrence -> Maybe HandlerResult -> Maybe Instant -> IO (Either InstanceError FiringOutcome)
commitCompletion inst o result at = locked inst (commitDoor inst o result at)

completeDoor :: Instance -> FiringOccurrence -> Maybe HandlerResult -> Maybe Instant -> Door FiringOutcome
completeDoor inst o result at =
  lift (runExceptT (commitDoor inst o result at)) >>= \case
    Left (CommitRefused e) -> liftIO (throwIO e)
    Left err -> throwE err
    Right outcome -> pure outcome

commitDoor :: Instance -> FiringOccurrence -> Maybe HandlerResult -> Maybe Instant -> Door FiringOutcome
commitDoor inst o result at = do
  ensureInFlight inst o "complete"
  st <- getState inst
  let t = o.binding.transition
      rejection = "cannot complete firing occurrence " <> pyInt o.occurrence <> " (" <> netPathText t <> ")"
  envelope <- case o.invocation of
    Nothing -> maybe (refuse (rejection <> ": a pure firing completes with its handler's result")) pure result
    Just _ -> do
      when (isJust result) $
        refuse
          ( rejection
              <> ": an impure firing projects its frozen activity result — complete() takes no result; record_activity_completion supplies it"
          )
      frozen <-
        maybe
          (refuse (rejection <> ": no terminal activity fact is recorded — record_activity_completion first"))
          pure
          (IntMap.lookup o.occurrence st.sFrozen)
      handler <- case boundHandler inst t of
        ActivityBound h -> pure h
        PureHandler _ ->
          throwE
            ( TypeRefused
                (rejection <> ": its impure occurrence is not bound to an ActivityHandler — recorded and live state disagree")
            )
      case frozen of
        TerminalFailure f -> case handler.projectFailure of
          Nothing -> refuse (rejection <> ": frozen failure has no opt-in failure projection")
          Just projector -> handlerDoor (forceResult (projector o.binding f))
        TerminalResult value -> handlerDoor (forceResult (handler.project o.binding value))
  (armedNext, closes, opens) <- orRefuse (armedAfter inst st rejection envelope)
  let instant = effective st.sWatermark at
      (effects, _) = completeFiring inst.iNet (queuesMarking st.sQueues) t envelope.tokens
      (cursor, producedRev) =
        foldl
          ( \(c, acc) (ProducedTokens p ts) ->
              let entries = take (length ts) [c ..]
                  recorded = if isJust o.scope then entries else []
               in (c + length ts, (RTokensProduced (TokensProduced p ts o.occurrence recorded o.scope instant), entries) : acc)
          )
          (st.sNextEntry, [])
          effects
      produced = reverse producedRev
      appended =
        map fst produced
          ++ [RDeliveryRegistrationClosed (DeliveryRegistrationClosed r.source r.key (Just o.occurrence) instant) | r <- closes]
          ++ [RDeliveryRegistrationOpened (DeliveryRegistrationOpened r.source r.key (Just o.occurrence) instant) | r <- opens]
          ++ [RFiringCompleted (FiringCompleted t o.occurrence instant)]
  batch <- orRefuse (writerRecords appended)
  let outcome =
        FiringOutcome
          t
          o.occurrence
          (concatMap snd o.binding.consumed)
          [(p, tok) | ProducedTokens p ts <- effects, tok <- ts]
          (o.records ++ batch)
  committed <- liftIO (try (inst.iStore.extend batch))
  case committed of
    Left e | isAsync e -> liftIO (throwIO e)
    Left e -> throwE (CommitRefused e)
    Right () -> pure ()
  queues <- foldM (\q (record, entries) -> orRuntime (applyMovement (Just entries) record q)) st.sQueues produced
  let (frozen', terminal') = case (o.invocation, IntMap.lookup o.occurrence st.sFrozen) of
        (Just _, Just value) -> (IntMap.delete o.occurrence st.sFrozen, IntMap.insert o.occurrence value st.sTerminal)
        _ -> (st.sFrozen, st.sTerminal)
  putState
    inst
    st
      { sQueues = queues
      , sWatermark = instant
      , sNextEntry = cursor
      , sArmed = armedNext
      , sFrozen = frozen'
      , sTerminal = terminal'
      , sInFlight = IntMap.delete o.occurrence st.sInFlight
      }
  emitEvent
    inst
    "firing_completed"
    [ ("transition", text (netPathText t))
    , ("occurrence", int o.occurrence)
    , ("instant", numberJson instant)
    , ("records", int (length batch))
    ]
  pure outcome

-- | The armed projection with the envelope's registration effects applied
-- (closes before opens), each checked against the state the earlier ones
-- produced.
armedAfter :: Instance -> State -> Text -> HandlerResult -> Either Text (Map NetPath (Set Text), [DeliveryRegistration], [DeliveryRegistration])
armedAfter inst st rejection envelope = do
  let net = inst.iNet
  forM_ (envelope.closes ++ envelope.opens) $ \effect -> do
    unless (hasTransition effect.source net) $
      Left (rejection <> ": delivery-registration effect on " <> netPathText effect.source <> ": not a transition of this net")
    unless (isSource net effect.source) $
      Left
        ( rejection <> ": delivery-registration effect on transition " <> netPathText effect.source
            <> ": it has input arcs — only a source transition has delivery registrations"
        )
  afterCloses <-
    foldM
      ( \m effect -> do
          let keys = Map.findWithDefault Set.empty effect.source m
          unless (Set.member effect.key keys) $
            Left
              ( rejection <> ": close of delivery registration " <> pyStr effect.key <> " on "
                  <> netPathText effect.source
                  <> ": not armed"
              )
          Right (Map.insert effect.source (Set.delete effect.key keys) m)
      )
      st.sArmed
      envelope.closes
  afterOpens <-
    foldM
      ( \m effect -> do
          let keys = Map.findWithDefault Set.empty effect.source m
          when (Set.member effect.key keys) $
            Left
              ( rejection <> ": open of delivery registration " <> pyStr effect.key <> " on "
                  <> netPathText effect.source
                  <> ": already armed"
              )
          Right (Map.insert effect.source (Set.insert effect.key keys) m)
      )
      afterCloses
      envelope.opens
  Right (afterOpens, envelope.closes, envelope.opens)

-- ---------------------------------------------------------------------------
-- Failure

-- | End the occurrence in terminal failure (@fail@). An impure occurrence
-- records @ActivityFailed@ first (unless already frozen); one whose handler
-- opts into failure projection completes through it instead. An occurrence
-- whose Activity already completed refuses to fail.
failFiring :: Instance -> FiringOccurrence -> FailureReason -> Maybe Instant -> IO (Either InstanceError ())
failFiring inst o reason at = locked inst (failDoor inst o reason at)

failDoor :: Instance -> FiringOccurrence -> FailureReason -> Maybe Instant -> Door ()
failDoor inst o reason at = do
  ensureInFlight inst o "fail"
  failure <- case reason of
    FailureValue f -> pure f
    FailureText m -> orRefuse (simpleFailure m)
  st0 <- getState inst
  forM_ (IntMap.lookup o.occurrence st0.sFrozen) $ \frozen ->
    case frozen of
      TerminalFailure f | sameFailure f failure -> pure ()
      _ ->
        refuse
          ( "cannot fail firing occurrence " <> pyInt o.occurrence <> " (" <> netPathText o.binding.transition
              <> "): its activity already completed — the frozen result stands; fix the projection and retry complete() [DR 2026-07-14 activity-invocation-runtime-seam, Deferred]"
          )
  when (isJust o.invocation && not (IntMap.member o.occurrence st0.sFrozen)) $
    void (recordFailureDoor inst o failure at)
  let projects = case boundHandler inst o.binding.transition of
        ActivityBound h -> isJust h.projectFailure
        PureHandler _ -> False
  if isJust o.invocation && projects
    then void (completeDoor inst o Nothing at)
    else do
      st <- getState inst
      let instant = effective st.sWatermark at
          message = (failureFields failure).failureError
      _ <- appendBatch inst [RFiringFailed (FiringFailed o.binding.transition message o.occurrence instant)]
      let (frozen', terminal') = case (o.invocation, IntMap.lookup o.occurrence st.sFrozen) of
            (Just _, Just value) -> (IntMap.delete o.occurrence st.sFrozen, IntMap.insert o.occurrence value st.sTerminal)
            _ -> (st.sFrozen, st.sTerminal)
      putState
        inst
        st
          { sWatermark = instant
          , sFrozen = frozen'
          , sTerminal = terminal'
          , sInFlight = IntMap.delete o.occurrence st.sInFlight
          }
      emitEvent
        inst
        "firing_failed"
        [ ("transition", text (netPathText o.binding.transition))
        , ("occurrence", int o.occurrence)
        , ("instant", numberJson instant)
        , ("error", text message)
        ]

-- ---------------------------------------------------------------------------
-- Inline drivers

-- | The inline driver's execution (pure projections only): run the bound
-- handler and commit; a raising handler, or a result the commit refuses,
-- records its failure and propagates.
executeDoor :: Instance -> FiringOccurrence -> Maybe Instant -> Door FiringOutcome
executeDoor inst o at = case boundHandler inst o.binding.transition of
  ActivityBound _ -> throwE (TypeRefused ("pure firing " <> netPathText o.binding.transition <> " is bound to an ActivityHandler"))
  PureHandler handler -> do
    attempt <- lift . runExceptT $ do
      envelope <- handlerDoor (forceResult (handler o.binding (outputs inst.iNet o.binding.transition)))
      commitDoor inst o (Just envelope) at
    case attempt of
      Right outcome -> pure outcome
      Left (CommitRefused e) -> liftIO (throwIO e)
      Left err -> do
        st <- getState inst
        when (IntMap.member o.occurrence st.sInFlight) $
          failDoor inst o (FailureText (firingFailureText err)) at
        throwE err

-- | Select and fire one candidate at the effective instant, begin to end,
-- inline. 'Nothing' when nothing is enabled then (nothing appended, the
-- watermark unmoved). An ActivityHandler-bound candidate is refused.
step :: Instance -> Maybe Instant -> IO (Either InstanceError (Maybe FiringOutcome))
step inst at = locked inst $ do
  st <- getState inst
  let prospective = effective st.sWatermark at
  (enabled, _) <- liftIO (surveyAt inst st prospective)
  case inst.iScheduler enabled of
    Nothing -> pure Nothing
    Just b -> do
      when (isActivityBound (boundHandler inst b.transition)) $
        refuse
          ( "cannot step firing " <> netPathText b.transition
              <> ": it binds an ActivityHandler, and this inline driver holds no Dispatch — drive it through Engine"
          )
      o <- beginDoor inst b at
      Just <$> executeDoor inst o Nothing

-- | Step until nothing is enabled at the watermark.
run :: Instance -> IO (Either InstanceError [FiringOutcome])
run inst = go []
  where
    go acc =
      step inst Nothing >>= \case
        Left err -> pure (Left err)
        Right Nothing -> pure (Right (reverse acc))
        Right (Just firing) -> go (firing : acc)

-- ---------------------------------------------------------------------------
-- Delivery

reprTarget :: Maybe DeliveryScope -> Text
reprTarget = \case
  Nothing -> "None"
  Just (ScopeGeneration s) -> T.pack (show s)
  Just (ScopeName n) -> pyStr n

-- | Accept an external event on a source transition and begin its source
-- occurrence without completing it. The identity is the delivery's stable,
-- ingress-supplied identity: an exact redelivery answers from the recorded
-- fact (the reconstructed 'AcceptedDelivery' while unfinished, the
-- 'PriorAcknowledgement' after), appending nothing; a changed source,
-- payload, or scope is a conflict. A delivery to an inactive scope is
-- durably dropped or quarantined instead of firing.
acceptDelivery :: Instance -> NetPath -> [Token] -> Text -> Maybe DeliveryScope -> Maybe Instant -> IO (Either InstanceError DeliveryAnswer)
acceptDelivery inst path tokens ident target at = locked inst $ do
  let net = inst.iNet
  case target of
    Just (ScopeName n) | not (validScopeName n) -> refuse "uncertain delivery scope must be a non-empty name without NUL"
    _ -> pure ()
  when (null tokens) $ refuse ("delivery to " <> netPathText path <> " requires at least one token")
  delivered <- orRefuse (canonicalDeliveryTokens path tokens)
  let content = deliveryContent delivered
  when (T.null ident) $
    refuse
      ( "delivery to " <> netPathText path
          <> ": identity must be a non-empty string of the exact built-in type, got "
          <> pyStr ident
      )
  st <- getState inst
  case Map.lookup ident st.sAccepted of
    Just prior -> do
      let (priorSource, priorTokens, priorScope, priorOccurrence) = case prior of
            RExternalEventDelivered r -> (r.source, r.tokens, ScopeGeneration <$> r.scope, Just r.occurrence)
            RScopedDeliveryDropped r -> (r.source, r.tokens, Just (ScopeGeneration r.scope), Nothing)
            RScopedDeliveryQuarantined r -> (r.source, r.tokens, Just (quarantineTarget r.scope), Nothing)
            _ -> (path, [], Nothing, Nothing)
          matches = deliveryContent priorTokens == content
          occurrenceJson = maybe Null int priorOccurrence
      when (priorSource /= path || not matches || priorScope /= target) $ do
        emitEvent
          inst
          "delivery_conflicted"
          [("source", text (netPathText path)), ("identity", text ident), ("occurrence", occurrenceJson)]
        refuse
          ( "delivery identity conflict for " <> pyStr ident <> ": recorded source " <> T.pack (show priorSource)
              <> ", scope "
              <> reprTarget priorScope
              <> "; attempted source "
              <> T.pack (show path)
              <> ", scope "
              <> reprTarget target
              <> "; canonical token content "
              <> (if matches then "matches" else "differs")
          )
      emitEvent
        inst
        "delivery_redelivered"
        [("source", text (netPathText path)), ("identity", text ident), ("occurrence", occurrenceJson)]
      case prior of
        RScopedDeliveryDropped r -> pure (DeliveryScoped (ScopedDeliveryAcknowledgement ident Dropped (QuarantineGeneration r.scope)))
        RScopedDeliveryQuarantined r -> pure (DeliveryScoped (ScopedDeliveryAcknowledgement ident Quarantined r.scope))
        RExternalEventDelivered r
          | IntMap.member r.occurrence st.sInFlight ->
              DeliveryAccepted <$> orRefuse (acceptedDelivery inst.iIdentity r.source r.identity r.occurrence)
          | otherwise -> pure (DeliveryPrior (PriorAcknowledgement ident r.occurrence))
        _ -> throwE (RuntimeRefused "accepted identity index holds a non-delivery record")
    Nothing -> do
      unless (hasTransition path net) $
        refuse ("cannot deliver to " <> netPathText path <> ": not a transition of this net")
      unless (isSource net path) $
        refuse
          ( "cannot deliver to transition " <> netPathText path
              <> ": it has input arcs — only a source transition takes delivery"
          )
      let inactive = case target of
            Nothing -> False
            Just (ScopeName _) -> True
            Just (ScopeGeneration s) -> Map.lookup (scopeName s) st.sActiveScopes /= Just s
      if inactive
        then do
          let instant = effective st.sWatermark at
              (record, answer) = case target of
                Just (ScopeGeneration s)
                  | scopeGeneration s <= Map.findWithDefault 0 (scopeName s) st.sGenerations ->
                      ( RScopedDeliveryDropped (ScopedDeliveryDropped path delivered ident s instant)
                      , ScopedDeliveryAcknowledgement ident Dropped (QuarantineGeneration s)
                      )
                  | otherwise -> quarantine (QuarantineGeneration s) instant
                Just (ScopeName n) -> quarantine (QuarantineName n) instant
                Nothing -> quarantine (QuarantineName "") instant
              quarantine q i =
                ( RScopedDeliveryQuarantined (ScopedDeliveryQuarantined path delivered ident q i)
                , ScopedDeliveryAcknowledgement ident Quarantined q
                )
          batch <- appendBatch inst [record]
          putState inst st {sWatermark = instant, sAccepted = Map.insert ident (head' record batch) st.sAccepted}
          pure (DeliveryScoped answer)
        else do
          when (Set.null (Map.findWithDefault Set.empty path st.sArmed)) $
            refuse ("cannot deliver to source transition " <> netPathText path <> ": no armed delivery registration")
          let generation = case target of
                Just (ScopeGeneration s) -> Just s
                _ -> Nothing
          o <-
            beginOccurrence
              inst
              (E.deliveredBinding path delivered)
              at
              (\n i -> RExternalEventDelivered (ExternalEventDelivered path delivered ident n generation i))
              Nothing
              generation
          after <- getState inst
          putState
            inst
            after
              { sAccepted =
                  Map.insert
                    ident
                    (RExternalEventDelivered (ExternalEventDelivered path delivered ident o.occurrence generation after.sWatermark))
                    after.sAccepted
              }
          emitEvent
            inst
            "delivery_accepted"
            [ ("source", text (netPathText path))
            , ("identity", text ident)
            , ("occurrence", int o.occurrence)
            , ("tokens", int (length delivered))
            ]
          DeliveryAccepted <$> orRefuse (acceptedDelivery inst.iIdentity path ident o.occurrence)
  where
    quarantineTarget = \case
      QuarantineGeneration s -> ScopeGeneration s
      QuarantineName n -> ScopeName n
    head' fallback = \case
      r : _ -> r
      [] -> fallback

-- | Complete only the pure source occurrence an 'AcceptedDelivery' names.
completeDelivery :: Instance -> AcceptedDelivery -> Maybe Instant -> IO (Either InstanceError FiringOutcome)
completeDelivery inst carrier at = locked inst $ do
  a <- orRefuse (canonicalAcceptedDelivery carrier)
  let owner = instanceIdentityText a.instanceId
      ident = deliveryIdentityText a.identity
      occ = firingOccurrenceIdInt a.occurrence
  when (owner /= inst.iIdentity) $
    refuse
      ( "cannot complete delivery for Instance " <> pyStr owner <> ": this is Instance "
          <> pyStr inst.iIdentity
      )
  st <- getState inst
  let recorded = case Map.lookup ident st.sAccepted of
        Just (RExternalEventDelivered r)
          | r.source == a.source && r.identity == ident && r.occurrence == occ -> Just r
        _ -> Nothing
  o <- case IntMap.lookup occ st.sInFlight of
    Just o -> pure o
    Nothing
      | isJust recorded ->
          refuse
            ( "cannot complete accepted delivery " <> pyStr ident <> ": firing occurrence " <> pyInt occ
                <> " already ended"
            )
      | otherwise ->
          refuse ("cannot complete delivery " <> pyStr ident <> ": no matching accepted unfinished occurrence")
  let t = o.binding.transition
      impure = isJust o.invocation || isActivityBound (boundHandler inst t)
      prefix = "cannot complete delivery " <> pyStr ident <> ": firing occurrence " <> pyInt occ
  unless (isSource inst.iNet t) $
    refuse
      ( prefix <> " belongs to " <> (if impure then "an impure non-source" else "a non-source") <> " transition "
          <> netPathText t
      )
  when impure $ refuse (prefix <> " is impure")
  case recorded of
    Just r
      | t == a.source && o.binding.delivered == r.tokens && o.scope == r.scope -> pure ()
    _ ->
      refuse
        ( "cannot complete delivery " <> pyStr ident <> ": acceptance does not match firing occurrence "
            <> pyInt occ
        )
  executeDoor inst o at

-- | The runtime-policy close-all: close every armed delivery registration of
-- a source transition, one recorded close per key, in key order.
seal :: Instance -> NetPath -> Maybe Instant -> IO (Either InstanceError ())
seal inst path at = locked inst $ do
  let net = inst.iNet
  unless (hasTransition path net) $ refuse ("cannot seal " <> netPathText path <> ": not a transition of this net")
  unless (isSource net path) $
    refuse
      ( "cannot seal transition " <> netPathText path
          <> ": it has input arcs — only a source transition has delivery registrations"
      )
  st <- getState inst
  let keys = Map.findWithDefault Set.empty path st.sArmed
  when (Set.null keys) $
    refuse ("cannot seal source transition " <> netPathText path <> ": no armed delivery registration")
  let instant = effective st.sWatermark at
  batch <-
    appendBatch inst [RDeliveryRegistrationClosed (DeliveryRegistrationClosed path k Nothing instant) | k <- Set.toAscList keys]
  putState inst st {sWatermark = instant, sArmed = Map.insert path Set.empty st.sArmed}
  emitEvent
    inst
    "registrations_sealed"
    [("source", text (netPathText path)), ("closed", int (length batch)), ("instant", numberJson instant)]

-- | The adapter's wakeup at the observed instant: append @TimerMatured@ for
-- the pending maturation, or 'Nothing' when it matures nothing.
wake :: Instance -> Instant -> IO (Either InstanceError (Maybe TimerMatured))
wake inst at = locked inst $ do
  st <- getState inst
  pending <- liftIO (nextMaturationOf inst st)
  let instant = effective st.sWatermark (Just at)
  case pending of
    Just maturing
      | not (instant < maturing) -> do
          let record = TimerMatured maturing instant
          _ <- appendBatch inst [RTimerMatured record]
          putState inst st {sWatermark = instant}
          emitEvent inst "timer_matured" [("maturation", numberJson maturing), ("instant", numberJson instant)]
          pure (Just record)
    _ -> pure Nothing
