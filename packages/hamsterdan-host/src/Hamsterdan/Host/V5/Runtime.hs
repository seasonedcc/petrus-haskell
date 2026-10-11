-- | The durable Petrus runtime for one cohabited V5 PR Instance
-- (@host/v5/runtime.py@): one Engine whose JSONL History is the workflow
-- authority.
--
-- The gates are wired with 'wireGates'; every gate Activity stamps its
-- result with 'encodeVariant'. Durable publication gates route to a
-- per-Instance Local Dispatch queue, every other gate runs inline.
module Hamsterdan.Host.V5.Runtime
  ( -- * Gate definitions
    GateImplementation (..)
  , gateImplementation
  , hostGateDefinition
  , asActivity
  , gateMembers
  , DurableActivityResolver

    -- * The runtime
  , V5Runtime (..)
  , RuntimeOptions (..)
  , defaultRuntimeOptions
  , RuntimeHooks (..)
  , defaultRuntimeHooks
  , openRuntime
  , engine
  , records
  , markingPlace
  , deliver
  , manifestAccepted
  , manifestFolded
  , foldIngress
  , drain
  , runtimeActivity
  , activeClaim
  , hasUnresolvedPublication
  , timerCommand
  , runtimeTimerHistory
  , conversationContext
  , deliverTimerAck
  , deliverTimerDue
  , ReviewDeferred (..)
  , reviewDeferred
  , deferredOperation
  , deferredAttempt
  , deferredBlocker
  , reviewWakeIdentity
  , deliverReviewWake
  , announceDeferred
  , announceWakeIdentity
  , deliverAnnounceWake
  , runDurableActivities
  , stopDurableActivities
  , closeRuntime
  , durableQueue
  , ingressFolds
  ) where

import Control.Exception (SomeException, finally, onException, throw, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (Typeable)
import Hamsterdan.Contracts.Codec (Contract, dump, validate)
import Hamsterdan.Contracts.ReadinessV5
  ( ADeferred (..)
  , AWake (..)
  , AnnounceReq (..)
  , PublicationDeferred (..)
  , RoundDeferred (..)
  , RoundWake (..)
  , TimerCommand (..)
  , TimerCommandApplied (..)
  , TimerDue (..)
  )
import Hamsterdan.Host.Python (RuntimeError (..), TypeError (..), ValueError (..), dumpsCompactSorted, mkdirPrivate, raiseFailureText, sha256Hex, sha256HexText)
import Hamsterdan.Host.V5.Claim (CurrentClaim (..), Phase (..))
import Hamsterdan.Host.V5.Ingress (IngressEntry (..), ingressFrom)
import Hamsterdan.Host.V5.Timers (TimerFact, timerHistory, timerValue)
import Hamsterdan.PyLiteral (PyValue (PyDict), toJson)
import Petrus.Impetus.Instance.FailureText (PythonArg (..), PythonException (..))
import Hamsterdan.Readiness.NetV5.Board (gateFacts)
import Hamsterdan.Readiness.NetV5.Gating
  ( GateDefinition (..)
  , Variant
  , annotation
  , decodeDataclass
  , durablePublicationGates
  , encodeVariant
  , variantPayloadConverter
  , wireGates
  )
import Hamsterdan.Readiness.NetV5.Review (liveFindings)
import Hamsterdan.Readiness.NetV5.Topology (buildNetV5, derived, gates, seedMarkingWith)
import Petrus.Activity
  ( ActivityDefinition (..)
  , ActivityInvocation (..)
  , activityDeclaration
  , callActivity
  )
import Petrus.Cel.Impetus (celCompilers)
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.History.Records
  ( ActivityCompleted (..)
  , ActivityFailed (..)
  , ActivityRequested (..)
  , ActivityTerminalQuarantined (..)
  , ExternalEventDelivered (..)
  , Record (..)
  )
import Petrus.Impetus.Instance (ImplementationRef (..))
import Petrus.Impetus.Instance.Firing (FiringOutcome (..))
import Petrus.Impetus.Petrinet (Binding (..), NetPath, Token (..), netPathText, placeTokens)
import Petrus.Impetus.Petrinet.Schema (netPath)
import Petrus.Impetus.Selection (SelectionPolicy (..), defaultPipeline)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (CancellationInstruction (..), Dispatch (..))
import Petrus.Motus.Dispatch.Inline (Activity, inlineDispatch, newInlineDispatch)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Worker (Worker, WorkerOptions (..), closeWorker, defaultWorkerOptions, newWorker, runAvailable, stopWorker)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- ---------------------------------------------------------------------------
-- Gate definitions

-- | A gate's typed implementation: @work: Request -> Union@.
data GateImplementation where
  GateImplementation :: (Contract a, Typeable a) => (a -> IO Variant) -> GateImplementation

gateImplementation :: forall a. (Contract a, Typeable a) => (a -> IO Variant) -> GateImplementation
gateImplementation = GateImplementation

-- | The union members a gate's annotation declares (the topology's
-- routing variants for that gate).
gateMembers :: Text -> [Text]
gateMembers name = concat [variants | (_, (gate, variants)) <- gates, gate == name]

-- | @activity(implementation, name=name, heartbeat_timeout=...,
-- converter=VariantPayloadConverter())@: the single @work@ parameter is
-- decoded as its dataclass, and the result is stamped with its
-- @$variant@ (refusing a type outside the union).
hostGateDefinition :: Text -> Maybe Integer -> GateImplementation -> Either Text GateDefinition
hostGateDefinition name heartbeat (GateImplementation (implementation :: a -> IO Variant)) = do
  declaration <- activityDeclaration name heartbeat
  let members = gateMembers name
      function args _ = do
        raw <- maybe (throwIO (TypeError (name <> "() missing 1 required keyword-only argument: 'work'"))) pure (lookup "work" args)
        work <- either raiseFailureText pure (decodeDataclass @a raw)
        value <- implementation work
        either raiseFailureText pure (encodeVariant members value)
  Right
    GateDefinition
      { activity = ActivityDefinition declaration variantPayloadConverter ["work"] function
      , parameters = [("work", annotation @a)]
      , result = members
      }

-- | @DurableActivityResolver = Callable[[str, str, ActivityDefinition],
-- Activity]@: the instance, the Activity name and its definition.
type DurableActivityResolver = Text -> Text -> GateDefinition -> IO (Maybe Activity)

-- | Run a gate definition as an inline-dispatch 'Activity'.
asActivity :: GateDefinition -> Activity
asActivity definition inv ctx = callActivity definition.activity inv ctx >>= either (throwIO . ValueError) pure

-- ---------------------------------------------------------------------------
-- Constants

-- | @_INGRESS_FOLDS@: each door's lifecycle mailbox and admission fold.
ingressFolds :: [(Text, (Text, Text))]
ingressFolds =
  [ ("on_head", ("life.heads", "life.admit_head"))
  , ("on_draft", ("life.drafts", "life.admit_draft"))
  , ("on_ready", ("life.readies", "life.admit_ready"))
  , ("on_close", ("life.closes", "life.admit_close"))
  , ("on_comment", ("life.comments", "life.admit_comment"))
  , ("on_human", ("life.humans", "life.admit_human"))
  , ("on_runs", ("life.runs", "life.admit_runs"))
  ]

-- | @_durable_queue(instance)@.
durableQueue :: Text -> Text
durableQueue instance' = "v5-publication:" <> instance'

-- | @NetPath(text)@, raising its @ValueError@ for a malformed path.
path :: Text -> NetPath
path text = either (throw . ValueError) id (netPath text)

-- ---------------------------------------------------------------------------
-- The engine policy

-- | @_V5EnginePolicy@'s selection half: the default pipeline, restricted
-- to the exact lifecycle fold while one is targeted. The Engine builds it
-- from the target it reads before each proposal ('Engine.SteeredSelection'),
-- where the reference reads the policy's mutable @target@ attribute.
v5Selection :: Maybe NetPath -> SelectionPolicy ()
v5Selection target =
  SelectionPolicy
    { propose = \candidates state ->
        let selected = case target of
              Nothing -> candidates
              Just t -> [c | c <- candidates, c.transition == t]
         in pipeline.propose selected state
    , foldCommitted = pipeline.foldCommitted
    }
  where
    pipeline = defaultPipeline :: SelectionPolicy ()

-- | @_V5EnginePolicy.__call__@: the targeted fold's candidate, or
-- throughput.
v5Driving :: IORef (Maybe NetPath) -> Engine.DrivingPolicy
v5Driving target snapshot =
  readIORef target >>= \case
    Just t -> case [a | a@(Engine.BeginCandidate b) <- snapshot.actions, b.transition == t] of
      selected : _ -> pure selected
      [] -> throwIO (RuntimeError ("V5 ingress row cannot fold through " <> netPathText t))
    Nothing -> Engine.throughputPolicy snapshot

-- ---------------------------------------------------------------------------
-- The runtime

-- | Test seams for the reference tests' method patches: each wraps the
-- real call.
data RuntimeHooks = RuntimeHooks
  { aroundDeliver :: IngressEntry -> IO Engine.Delivered -> IO Engine.Delivered
  -- ^ @runtime.deliver@.
  , aroundEngineDeliver :: IO Engine.Delivered -> IO Engine.Delivered
  -- ^ @runtime.engine.deliver@.
  , aroundTimerAck :: IO Engine.Delivered -> IO Engine.Delivered
  , aroundTimerDue :: IO Engine.Delivered -> IO Engine.Delivered
  , aroundReviewWake :: IO Engine.Delivered -> IO Engine.Delivered
  , aroundAnnounceWake :: IO Engine.Delivered -> IO Engine.Delivered
  }

defaultRuntimeHooks :: RuntimeHooks
defaultRuntimeHooks =
  RuntimeHooks
    { aroundDeliver = \_ real -> real
    , aroundEngineDeliver = id
    , aroundTimerAck = id
    , aroundTimerDue = id
    , aroundReviewWake = id
    , aroundAnnounceWake = id
    }

data V5Runtime = V5Runtime
  { engineRef :: IORef Engine.Engine
  , loader :: IO Engine.Engine
  , definitions :: Map Text GateDefinition
  , agentSettle :: Maybe (Set Text -> IO ())
  , mutationOperation :: Maybe (Text -> Text)
  , durableWorker :: Maybe Worker
  , target :: IORef (Maybe NetPath)
  , hooks :: IORef RuntimeHooks
  }

-- | @V5Runtime.open@'s keyword arguments.
data RuntimeOptions = RuntimeOptions
  { dispatchPath :: Maybe FilePath
  , agentSettle :: Maybe (Set Text -> IO ())
  , mutationOperation :: Maybe (Text -> Text)
  , reminderDelayS :: Integer
  , durableActivityResolver :: Maybe DurableActivityResolver
  }

defaultRuntimeOptions :: RuntimeOptions
defaultRuntimeOptions =
  RuntimeOptions
    { dispatchPath = Nothing
    , agentSettle = Nothing
    , mutationOperation = Nothing
    , reminderDelayS = 3 * 24 * 60 * 60
    , durableActivityResolver = Nothing
    }

-- | @_CompositeDispatch(inline, durable)@.
compositeDispatch :: Dispatch -> Dispatch -> Dispatch
compositeDispatch inline durable =
  Dispatch
    { dispatch = \occurrence inv -> (route inv).dispatch occurrence inv
    , collect = (<>) <$> inline.collect <*> durable.collect
    , cancel = Just $ \instruction -> case (route instruction.invocation).cancel of
        Nothing -> throwIO (TypeError "scope-managed Activity target does not support cancellation")
        Just cancel' -> cancel' instruction
    }
  where
    route inv = if inv.activity `elem` durablePublicationGates then durable else inline

-- | @V5Runtime.open(root, instance, definitions, ...)@.
openRuntime :: FilePath -> Text -> Map Text GateDefinition -> RuntimeOptions -> IO V5Runtime
openRuntime root instance' definitions options = do
  mkdirPrivate root
  -- The topology and its gate wiring are fixed; a refusal here is a
  -- programming error, surfaced as the reference's construction failure.
  built <- either (throwIO . RuntimeError . T.pack . show) pure buildNetV5
  handlers <- either (throwIO . ValueError) pure (wireGates built gates definitions derived)
  target <- newIORef Nothing
  let declarations = [d.activity.declaration | d <- Map.elems definitions]
      registry = Map.map asActivity definitions
      dispatch' = do
        inline <- inlineDispatch <$> newInlineDispatch registry
        case options.dispatchPath of
          Nothing -> pure inline
          Just dispatchPath -> do
            durable <-
              Local.openLocalDispatch
                dispatchPath
                instance'
                Local.defaultLocalDispatchOptions {Local.activityQueues = [(name, durableQueue instance') | name <- durablePublicationGates]}
            pure (compositeDispatch inline (Local.toDispatch durable))
      historyPath = root </> "history.jsonl"
      engineOptions marking' =
        Engine.defaultEngineOptions
          { Engine.marking = marking'
          , Engine.handlers = handlers
          , Engine.guards = Map.fromList [(Exact uri, g) | (uri, g) <- Map.toList built.guards]
          , Engine.celCompilers = celCompilers
          , Engine.policy = v5Driving target
          , Engine.selection = Engine.SteeredSelection (readIORef target) v5Selection ()
          , Engine.activities = declarations
          }
      load = do
        store <- openJsonlHistoryStore historyPath
        port <- dispatch'
        Engine.load built.net instance' store port (engineOptions Engine.defaultEngineOptions.marking)
  exists <- doesFileExist historyPath
  engine0 <-
    if exists
      then load
      else do
        marking' <- either raiseFailureText pure (seedMarkingWith options.reminderDelayS instance')
        store <- openJsonlHistoryStore historyPath
        port <- dispatch'
        Engine.create built.net instance' store port (engineOptions marking')
  worker <- forM options.dispatchPath $ \dispatchPath -> do
    session <- Local.openLocalDispatch dispatchPath instance' Local.defaultLocalDispatchOptions
    provider <- Local.worker session [durableQueue instance'] Nothing
    let durable = Map.filterWithKey (\name _ -> name `elem` durablePublicationGates) definitions
        resolver = case options.durableActivityResolver of
          Nothing -> Nothing
          Just resolve -> Just $ \attemptInstance name -> case Map.lookup name durable of
            Nothing -> pure Nothing
            Just definition -> resolve attemptInstance name definition
    newWorker (Local.toWorkerDispatch provider) (Map.map asActivity durable) defaultWorkerOptions {resolver}
  engineRef <- newIORef engine0
  hooks <- newIORef defaultRuntimeHooks
  let runtime =
        V5Runtime
          { engineRef
          , loader = load
          , definitions
          , agentSettle = options.agentSettle
          , mutationOperation = options.mutationOperation
          , durableWorker = worker
          , target
          , hooks
          }
  ( do
      validateReviewWakeHistory runtime
      validateAnnounceWakeHistory runtime
    )
    `onException` closeRuntime runtime
  pure runtime

engine :: V5Runtime -> IO Engine.Engine
engine runtime = readIORef runtime.engineRef

records :: V5Runtime -> IO [Record]
records runtime = engine runtime >>= Engine.records

markingPlace :: V5Runtime -> Text -> IO [Token]
markingPlace runtime place = toList . placeTokens (path place) <$> (engine runtime >>= Engine.marking)

-- | Reopen canonical History before an exact retry: a JSONL append may
-- have committed before its caller saw an exception, so absence is never
-- inferred from one.
reopen :: V5Runtime -> IO ()
reopen runtime = do
  replacement <- runtime.loader
  previous <- readIORef runtime.engineRef
  writeIORef runtime.engineRef replacement
  Engine.close previous

reopening :: V5Runtime -> IO a -> IO a
reopening runtime action =
  try action >>= \case
    Right value -> pure value
    Left (err :: SomeException) -> reopen runtime >> throwIO err

tokenOf :: IngressEntry -> Token
tokenOf entry = Token (Just entry.color) entry.payload

-- | @deliver(entry)@.
deliver :: V5Runtime -> IngressEntry -> IO Engine.Delivered
deliver runtime entry = do
  h <- readIORef runtime.hooks
  h.aroundDeliver entry $ do
    source <- either (throwIO . ValueError) pure (netPath entry.source)
    reopening runtime $ do
      e <- engine runtime
      h.aroundEngineDeliver (Engine.deliver e source [tokenOf entry] entry.identity Nothing)

-- | @manifest_accepted(entries)@: whether canonical History has accepted
-- every frozen ingress identity.
manifestAccepted :: V5Runtime -> [IngressEntry] -> IO Bool
manifestAccepted runtime entries = do
  rs <- records runtime
  accepted <-
    foldlM' Map.empty [r | RExternalEventDelivered r <- rs] $ \acc r -> do
      when (Map.member r.identity acc) $
        throwIO (RuntimeError "V5 ingress identity occurs more than once in canonical History")
      pure (Map.insert r.identity r acc)
  missing <- forM entries $ \entry -> case Map.lookup entry.identity accepted of
    Nothing -> pure True
    Just r -> do
      let conflict = case r.tokens of
            [token] -> netPathText r.source /= entry.source || token.color /= Just entry.color || token.payload /= entry.payload
            _ -> True
      when conflict $ throwIO (RuntimeError "V5 ingress manifest conflicts with canonical History")
      pure False
  pure (not (or missing))
  where
    foldlM' z xs f = go z xs
      where
        go acc [] = pure acc
        go acc (y : ys) = f acc y >>= \acc' -> go acc' ys

foldOf :: IngressEntry -> IO (Text, Text)
foldOf entry = maybe (throwIO (ValueError "V5 ingress source has no lifecycle fold")) pure (lookup entry.source ingressFolds)

-- | @manifest_folded(entries)@.
manifestFolded :: V5Runtime -> [IngressEntry] -> IO Bool
manifestFolded runtime entries = do
  accepted <- manifestAccepted runtime entries
  if not accepted
    then pure False
    else go entries
  where
    go [] = pure True
    go (entry : rest) = do
      (mailbox, _) <- foldOf entry
      present <- elem (tokenOf entry) <$> markingPlace runtime mailbox
      if present then pure False else go rest

-- | @fold_ingress(entry)@: apply the accepted row's pending lifecycle
-- fold, if replay has not already done so.
foldIngress :: V5Runtime -> IngressEntry -> IO (Maybe Engine.DriveOutcome)
foldIngress runtime entry = do
  (mailbox, targetText) <- foldOf entry
  present <- elem (tokenOf entry) <$> markingPlace runtime mailbox
  if not present
    then pure Nothing
    else do
      let t = path targetText
      writeIORef runtime.target (Just t)
      outcome <-
        reopening runtime (engine runtime >>= Engine.advance)
          `finally` writeIORef runtime.target Nothing
      unless (any (\f -> f.transition == t) outcome.firings) $
        throwIO (RuntimeError "V5 ingress row did not complete its lifecycle fold")
      pure (Just outcome)

-- | @drain(limit=500)@.
drain :: V5Runtime -> Int -> IO Engine.DriveOutcome
drain runtime limit = do
  settleAgentRoutes runtime
  go limit
  where
    go 0 = throwIO (RuntimeError "V5 Engine did not reach an external wait")
    go n = do
      result <- try (engine runtime >>= Engine.advance)
      case result of
        Left (err :: SomeException) -> do
          reopen runtime
          settleAgentRoutes runtime
          throwIO err
        Right outcome -> do
          settleAgentRoutes runtime
          if not outcome.ready then pure outcome else go (n - 1)

lookupObject :: Text -> Json -> Maybe Json
lookupObject key = \case
  Object members -> lookup key members
  _ -> Nothing

isObject :: Json -> Bool
isObject = \case
  Object _ -> True
  _ -> False

variantOfResult :: Json -> Maybe Json
variantOfResult = lookupObject "$variant"

settleAgentRoutes :: V5Runtime -> IO ()
settleAgentRoutes runtime = forM_ runtime.agentSettle $ \settle -> do
  rs <- records runtime
  let requested =
        Map.fromList
          [ (r.occurrence, (r.activity, operation))
          | RActivityRequested r <- rs
          , isObject r.input
          , Just work <- [lookupObject "work" r.input]
          , isObject work
          , Just operation <- [operationOf r.activity work]
          ]
      operationOf name work = case lookupObject "operation" work of
        Just (String operation) -> Just operation
        _
          | name == "git_gate"
          , Just (String opKey) <- lookupObject "op_key" work
          , Just mutationOperation <- runtime.mutationOperation ->
              Just (mutationOperation opKey)
          | otherwise -> Nothing
      terminal = \case
        RActivityCompleted r -> Just (r.occurrence, Just r.result)
        RActivityFailed r -> Just (r.occurrence, Nothing)
        _ -> Nothing
      settled =
        Set.fromList
          [ operation
          | (occurrence, result) <- mapMaybe terminal rs
          , Just (name, operation) <- [Map.lookup occurrence requested]
          , not (name == "git_gate" && (result >>= variantOfResult) == Just (String "FaultM"))
          , not (name == "review_agent" && (result >>= variantOfResult) == Just (String "RoundDeferred"))
          ]
  settle settled

-- | @activity(name)@.
runtimeActivity :: V5Runtime -> Text -> Maybe GateDefinition
runtimeActivity runtime name = Map.lookup name runtime.definitions

terminalOccurrences :: [Record] -> Set Int
terminalOccurrences rs =
  Set.fromList $
    [r.occurrence | RActivityCompleted r <- rs]
      <> [r.occurrence | RActivityFailed r <- rs]
      <> [r.occurrence | RActivityTerminalQuarantined r <- rs]

-- | @active_claim(operation)@.
activeClaim :: V5Runtime -> Text -> IO (Maybe CurrentClaim)
activeClaim runtime operation = do
  rs <- records runtime
  let terminal = terminalOccurrences rs
  claims <-
    fmap concat . forM [r | RActivityRequested r <- rs] $ \r -> case lookupObject "work" r.input of
      Just work
        | isObject r.input
        , isObject work
        , not (Set.member r.occurrence terminal)
        , lookupObject "op" work == Just (String operation) ->
            case (lookupObject "incarnation" work, lookupObject "head" work, lookupObject "base" work, lookupObject "policy" work) of
              (Just (Int incarnation), Just (String head'), Just (String base), Just (String policy)) ->
                pure [CurrentClaim PhaseRunning incarnation head' base policy]
              _ -> throwIO (RuntimeError "active V5 effect claim is malformed")
      _ -> pure []
  case claims of
    [] -> pure Nothing
    [one] -> pure (Just one)
    _ -> throwIO (RuntimeError "V5 effect operation has multiple active requests")

-- | @has_unresolved_publication()@.
hasUnresolvedPublication :: V5Runtime -> IO Bool
hasUnresolvedPublication runtime = do
  rs <- records runtime
  let terminal = terminalOccurrences rs
  pure (or [r.activity `elem` durablePublicationGates | RActivityRequested r <- rs, not (Set.member r.occurrence terminal)])

-- | @timer_command()@: the intentional Net-to-host timer outbox token.
timerCommand :: V5Runtime -> IO (Maybe TimerCommand)
timerCommand runtime =
  markingPlace runtime "rem.commands" >>= \case
    [] -> pure Nothing
    [token] | token.color == Just "TimerCommand" -> either throwIO (pure . Just) (timerValue @TimerCommand token.payload "command")
    _ -> throwIO (RuntimeError "V5 timer outbox has invalid cardinality or color")

-- | @timer_history()@.
runtimeTimerHistory :: V5Runtime -> IO [TimerFact]
runtimeTimerHistory runtime = records runtime >>= timerHistory

-- | @conversation_context()@: the board facts and open findings a fresh
-- comment is read against.
conversationContext :: V5Runtime -> IO ([Json], [Json])
conversationContext runtime = do
  memory <- markingPlace runtime "dash.memory"
  boards <- if null memory then markingPlace runtime "dash.done" else pure memory
  facts <- case boards of
    board : _ -> do
      entries <- case lookupObject "entries" board.payload of
        Just (Array values) -> forM values $ \case
          String entry -> pure entry
          _ -> throwIO (TypeError "V5 board entries are malformed")
        _ -> throwIO (PythonException "KeyError" [PyStr "entries"])
      view <- either raiseFailureText pure (gateFacts entries)
      forM view $ \(kind, body) -> do
        bodyJson <- maybe (throwIO (TypeError "V5 board fact is not JSON")) pure (toJson (PyDict body))
        pure (Object [("kind", String kind), ("body", bodyJson)])
    [] -> pure []
  memories <- markingPlace runtime "review.memory"
  findings <- case memories of
    m : _ -> either raiseFailureText pure (liveFindings m.payload)
    [] -> pure []
  pure (facts, findings)

-- | @deliver_timer_ack(value, identity)@.
deliverTimerAck :: V5Runtime -> TimerCommandApplied -> Text -> IO Engine.Delivered
deliverTimerAck runtime value identity = do
  h <- readIORef runtime.hooks
  h.aroundTimerAck (deliver runtime (ingressFrom "on_timer_command_applied" value identity))

-- | @deliver_timer_due(value, identity)@.
deliverTimerDue :: V5Runtime -> TimerDue -> Text -> IO Engine.Delivered
deliverTimerDue runtime value identity = do
  h <- readIORef runtime.hooks
  h.aroundTimerDue (deliver runtime (ingressFrom "on_timer" value identity))

-- | @RoundDeferred | PublicationDeferred@.
data ReviewDeferred
  = DeferredRound RoundDeferred
  | DeferredPublication PublicationDeferred
  deriving stock (Eq, Show)

deferredOperation :: ReviewDeferred -> Text
deferredOperation = \case
  DeferredRound d -> d.operation
  DeferredPublication d -> d.operation

deferredAttempt :: ReviewDeferred -> Integer
deferredAttempt = \case
  DeferredRound d -> d.attempt
  DeferredPublication d -> d.attempt

deferredBlocker :: ReviewDeferred -> Text
deferredBlocker = \case
  DeferredRound d -> d.blocker
  DeferredPublication d -> d.blocker

-- | @_review_value(model, data, label)@ (and @_announce_value@).
strictValue :: forall a. (Contract a) => Json -> Text -> IO a
strictValue value label = either (const (throwIO (RuntimeError ("V5 " <> label <> " is malformed")))) pure (validate @a value)

-- | @review_deferred()@.
reviewDeferred :: V5Runtime -> IO (Maybe ReviewDeferred)
reviewDeferred runtime = do
  validateReviewWakeHistory runtime
  rounds <- markingPlace runtime "review.deferred"
  publications <- markingPlace runtime "review.publication_deferred"
  case rounds <> publications of
    [] -> pure Nothing
    [token]
      | token.color == Just "RoundDeferred" -> Just . DeferredRound <$> strictValue token.payload "deferred review"
      | token.color == Just "PublicationDeferred" -> Just . DeferredPublication <$> strictValue token.payload "deferred review"
    _ -> throwIO (RuntimeError "V5 deferred review has invalid cardinality or color")

withoutVariant :: Json -> Json
withoutVariant = \case
  Object members -> Object [m | m@(k, _) <- members, k /= "$variant"]
  other -> other

validateReviewWakeHistory :: V5Runtime -> IO ()
validateReviewWakeHistory runtime = do
  rs <- records runtime
  go rs Set.empty Set.empty
  where
    reviewTransitions = ["review.agent", "review.publish"]
    go [] _ _ = pure ()
    go (record : rest) deferred seen = case record of
      RActivityCompleted r
        | netPathText r.transition `elem` reviewTransitions ->
            case variantOfResult r.result of
              Just (String variant) | variant `elem` ["RoundDeferred", "PublicationDeferred"] -> do
                value <-
                  if variant == "RoundDeferred"
                    then DeferredRound <$> strictValue (withoutVariant r.result) "deferred review History terminal"
                    else DeferredPublication <$> strictValue (withoutVariant r.result) "deferred review History terminal"
                let identity =
                      reviewWakeIdentity
                        RoundWake {operation = deferredOperation value, attempt = deferredAttempt value, blocker = deferredBlocker value}
                when (Set.member identity deferred) $
                  throwIO (RuntimeError "V5 deferred review History terminal occurs more than once")
                go rest (Set.insert identity deferred) seen
              _ -> go rest deferred seen
      RExternalEventDelivered r
        | netPathText r.source == "on_review_round_wake" -> do
            wake <- case r.tokens of
              [token] | token.color == Just "RoundWake" -> strictValue @RoundWake token.payload "review wake History delivery"
              _ -> throwIO (RuntimeError "V5 review wake History delivery is malformed")
            let expected = reviewWakeIdentity wake
            when (r.identity /= expected || Set.member r.identity seen) $
              throwIO (RuntimeError "V5 review wake History identity is malformed")
            unless (Set.member expected deferred) $
              throwIO (RuntimeError "V5 review wake History has no deferred round")
            go rest deferred (Set.insert r.identity seen)
      _ -> go rest deferred seen

-- | @review_wake_identity(value)@.
reviewWakeIdentity :: RoundWake -> Text
reviewWakeIdentity value =
  "v5-review-wake:" <> sha256HexText (value.operation <> "\0" <> T.pack (show value.attempt) <> "\0" <> value.blocker)

-- | @deliver_review_wake(value, identity)@.
deliverReviewWake :: V5Runtime -> RoundWake -> Text -> IO Engine.Delivered
deliverReviewWake runtime value identity = do
  h <- readIORef runtime.hooks
  h.aroundReviewWake (deliver runtime (ingressFrom "on_review_round_wake" value identity))

-- | @announce_deferred()@.
announceDeferred :: V5Runtime -> IO (Maybe ADeferred)
announceDeferred runtime = do
  validateAnnounceWakeHistory runtime
  markingPlace runtime "ready.deferred" >>= \case
    [] -> pure Nothing
    [token] | token.color == Just "ADeferred" -> Just <$> strictValue token.payload "deferred announcement"
    _ -> throwIO (RuntimeError "V5 deferred announcement has invalid cardinality or color")

deferredRequest :: ADeferred -> AnnounceReq
deferredRequest value =
  AnnounceReq
    { op = value.op
    , incarnation = value.incarnation
    , head = value.head
    , base = value.base
    , policy = value.policy
    , strictBase = value.strictBase
    , baseCurrent = value.baseCurrent
    }

wakeOf :: ADeferred -> IO AWake
wakeOf value = strictValue (dump value) "deferred announcement"

validateAnnounceWakeHistory :: V5Runtime -> IO ()
validateAnnounceWakeHistory runtime = do
  rs <- records runtime
  go rs Map.empty Set.empty Set.empty
  where
    go [] _ _ _ = pure ()
    go (record : rest) requested deferred seen = case record of
      RActivityRequested r
        | netPathText r.transition == "ready.gate"
        , r.activity == "announce_gate"
        , isObject r.input
        , Just work <- lookupObject "work" r.input
        , isObject work -> do
            value <- strictValue @AnnounceReq work "announcement History request"
            go rest (Map.insert r.occurrence value requested) deferred seen
      RActivityCompleted r
        | netPathText r.transition == "ready.gate"
        , variantOfResult r.result == Just (String "ADeferred") -> do
            value <- strictValue @ADeferred (withoutVariant r.result) "deferred announcement History terminal"
            when (Map.lookup r.occurrence requested /= Just (deferredRequest value)) $
              throwIO (RuntimeError "V5 deferred announcement differs from its History request")
            wake <- wakeOf value
            let identity = announceWakeIdentity wake
            when (Set.member identity deferred) $
              throwIO (RuntimeError "V5 deferred announcement History terminal occurs more than once")
            go rest requested (Set.insert identity deferred) seen
      RExternalEventDelivered r
        | netPathText r.source == "on_announce_wake" -> do
            wake <- case r.tokens of
              [token] | token.color == Just "AWake" -> strictValue @AWake token.payload "announcement wake History delivery"
              _ -> throwIO (RuntimeError "V5 announcement wake History delivery is malformed")
            let expected = announceWakeIdentity wake
            when (r.identity /= expected || Set.member r.identity seen) $
              throwIO (RuntimeError "V5 announcement wake History identity is malformed")
            unless (Set.member expected deferred) $
              throwIO (RuntimeError "V5 announcement wake History has no deferred request")
            go rest requested deferred (Set.insert r.identity seen)
      _ -> go rest requested deferred seen

-- | @announce_wake_identity(value)@.
announceWakeIdentity :: AWake -> Text
announceWakeIdentity value = "v5-announce-wake:" <> sha256Hex (dumpsCompactSorted (dump value))

-- | @deliver_announce_wake(value, identity)@.
deliverAnnounceWake :: V5Runtime -> AWake -> Text -> IO Engine.Delivered
deliverAnnounceWake runtime value identity = do
  h <- readIORef runtime.hooks
  h.aroundAnnounceWake (deliver runtime (ingressFrom "on_announce_wake" value identity))

-- | @run_durable_activities(limit)@.
runDurableActivities :: V5Runtime -> Int -> IO Int
runDurableActivities runtime limit = maybe (pure 0) (`runAvailable` limit) runtime.durableWorker

-- | @stop_durable_activities()@.
stopDurableActivities :: V5Runtime -> IO ()
stopDurableActivities runtime = forM_ runtime.durableWorker stopWorker

-- | @close()@.
closeRuntime :: V5Runtime -> IO ()
closeRuntime runtime =
  forM_ runtime.durableWorker closeWorker `finally` (engine runtime >>= Engine.close)

