-- | Port of @tests/petrus/engine/test_engine.py@: the provider-neutral
-- one-Instance Engine composition.
module Petrus.Engine.EngineSpec (spec) where

import Control.Exception (IOException, throwIO)
import Control.Monad (forM_, void)
import Data.Foldable (toList)
import Data.IORef
import Data.IntMap.Strict qualified as IntMap
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation (..), ExecutionPolicyFields (..), activityDeclaration, invocation, policyFields)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Internal (selectionState)
import Petrus.Engine.Provider (EngineResources (..), OpenMode (..), openEngine)
import Petrus.Engine.TestSupport
import Petrus.Impetus.Binding (ActivityHandler (..), BoundHandler (..), handlerTokens)
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore (HistoryStore (..), inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance (DeliveryScope (..), FiringOutcome (..), ScopeClosure (..), Status (..))
import Petrus.Impetus.Petrinet
import Petrus.Impetus.Scope (LifecycleScope, scopeGeneration, scopeName)
import Petrus.Impetus.Selection (roundRobin)
import Petrus.Impetus.TestSupport (netOf, np, tok, tokD)
import Petrus.Json (Json (..), lookupMember)
import Petrus.Motus.Dispatch
import Petrus.Motus.Dispatch.InMemory
import Test.Hspec hiding (before, pending)

a, b, work, source, output :: NetPath
a = np "a"
b = np "b"
work = np "work"
source = np "source"
output = np "output"

activityNet :: Net
activityNet =
  netOf
    [place a, place b]
    [Transition work (Just (HandlerSymbol "bridge")) [] []]
    [arc a work, arc work b]

sourceNet :: Net
sourceNet = netOf [place output] [transition source] [arc source output]

inlineActivity :: IO Dispatch
inlineActivity = inlineOf [("activity", \inv _ -> pure (Object [("value", inv.input)]))]

input3 :: Marking
input3 = markingFromList [(a, [tokD "Input" (Int 3)])]

done3 :: Marking
done3 = markingFromList [(b, [tokD "Done" (Object [("value", Int 3)])])]

bridgeOptions :: Bridge -> Engine.EngineOptions
bridgeOptions bridge = Engine.defaultEngineOptions {Engine.handlers = symbols [("bridge", bridge.handler)]}

-- | @Engine.create(...)@ with a fresh counting Bridge.
createWith :: Net -> Text -> HistoryStore -> Dispatch -> Marking -> IO Engine.Engine
createWith net identity history port initial = do
  bridge <- newBridge "activity" b
  Engine.create net identity history port (bridgeOptions bridge) {Engine.marking = initial}

loadWith :: Net -> Text -> HistoryStore -> Dispatch -> IO Engine.Engine
loadWith net identity history port = do
  bridge <- newBridge "activity" b
  Engine.load net identity history port (bridgeOptions bridge)

isCandidateSelected, isActivityRequested, isActivityCompleted, isFiringCompleted :: Record -> Bool
isCandidateSelected = \case RCandidateSelected _ -> True; _ -> False
isActivityRequested = \case RActivityRequested _ -> True; _ -> False
isActivityCompleted = \case RActivityCompleted _ -> True; _ -> False
isFiringCompleted = \case RFiringCompleted _ -> True; _ -> False

transitions :: [FiringOutcome] -> [NetPath]
transitions = map (.transition)

pendingOccurrences :: InMemoryDispatch -> IO [Int]
pendingOccurrences pool = map fst <$> pending pool

-- | An IO exception whose text contains the fragment (@OSError@).
ioErrorContaining :: String -> Selector IOException
ioErrorContaining fragment e = fragment `isInfixOf` show e

-- | The poisoning / closing doors the reference checks: advance, wait,
-- marking, records.
readingDoors :: Engine.Engine -> [IO ()]
readingDoors engine =
  [ void (Engine.advance engine)
  , void (Engine.wait engine 0)
  , void (Engine.marking engine)
  , void (Engine.records engine)
  ]

ready :: IO Engine.DriveOutcome -> IO Bool
ready = fmap (.ready)

waiting :: IO Engine.DriveOutcome -> IO Bool
waiting = fmap (.waiting)

-- ---------------------------------------------------------------------------
-- Lifecycle-scope fixtures

scopedNet :: Net
scopedNet =
  netOf
    [place a, place b]
    [transition source, Transition work (Just (HandlerSymbol "bridge")) [] []]
    [arc source a, arc a work, arc work b]

-- | @TestLifecycleScopes.create(history, dispatch)@.
createScoped :: HistoryStore -> Dispatch -> IO Engine.Engine
createScoped history port = createWith scopedNet "scoped-engine" history port emptyMarking

loadScoped :: HistoryStore -> Dispatch -> IO Engine.Engine
loadScoped = loadWith scopedNet "scoped-engine"

-- | Open "draft", deliver one scoped input, and begin its Activity.
draftInFlight :: Engine.Engine -> IO LifecycleScope
draftInFlight engine = do
  scope <- Engine.openScope engine "draft"
  _ <- Engine.deliver engine source [tokD "Input" (Int 3)] "draft-3" (Just (ScopeGeneration scope))
  _ <- Engine.advance engine
  pure scope

-- | An in-memory pool whose cancel port also records each instruction.
recordingPool :: IO (Dispatch, IORef [CancellationInstruction])
recordingPool = do
  pool <- newInMemoryDispatch
  instructions <- newIORef []
  let base = inMemoryDispatch pool
      recorded = case base.cancel of
        Just cancelPort -> Just $ \instruction -> do
          modifyIORef' instructions (<> [instruction])
          cancelPort instruction
        Nothing -> Nothing
  pure (base {cancel = recorded}, instructions)

-- | A Dispatch that only redelivers scripted terminal reports (and refuses
-- any dispatch, like the reference's @raise AssertionError@).
redelivering :: IORef [(Int, ActivityOutcome)] -> Dispatch
redelivering reports =
  Dispatch
    { dispatch = \occurrence inv -> throwIO (userError ("AssertionError: " <> show (occurrence, inv)))
    , collect = atomicModifyIORef' reports (\held -> ([], held))
    , cancel = Nothing
    }

-- ---------------------------------------------------------------------------
-- Joined-transaction fixtures

-- | @_joined_engine(history, dispatch, create, bridge, selection=RoundRobin((T,)), commit, release)@.
joinedEngine :: TransactionalHistory -> Dispatch -> Bool -> BoundHandler -> Maybe (IO ()) -> IO () -> IO Engine.Engine
joinedEngine tx port creating handler commitOverride release = do
  policy <- either (fail . show) pure (roundRobin [work])
  let resources = (txResources tx release) {commit = Just (maybe (txCommit tx) id commitOverride)}
      options =
        Engine.defaultEngineOptions
          { Engine.marking = if creating then input3 else emptyMarking
          , Engine.handlers = symbols [("bridge", handler)]
          , Engine.selection = Engine.EngineSelection policy Nothing
          }
  openEngine (if creating then CreateInstance else LoadInstance) activityNet "joined-test" tx.store port options resources

freshBridge :: IO BoundHandler
freshBridge = (.handler) <$> newBridge "activity" b

raisingDispatch :: Text -> IO Dispatch
raisingDispatch message = do
  pool <- newInMemoryDispatch
  pure (inMemoryDispatch pool) {dispatch = \_ _ -> throwIO (Engine.EngineRuntimeError message)}

spec :: Spec
spec = do
  neutralSurface
  lifecycleScopes
  neutralSurfaceContinued
  joinedTransactionFate

-- ---------------------------------------------------------------------------

neutralSurface :: Spec
neutralSurface = describe "TestNeutralEngineSurface" $ do
  it "engine alone owns composed source delivery" $ do
    -- Compile-time evidence: the composed door is the Engine's
    -- (Petrus.Impetus.Instance exports no @deliver@; its two phases are
    -- acceptDelivery and completeDelivery).
    let door :: Engine.Engine -> NetPath -> [Token] -> Text -> Maybe DeliveryScope -> IO Engine.Delivered
        door = Engine.deliver
    (door `seq` True) `shouldBe` True

  it "engine is the concrete live composition with only universal doors" $ do
    -- Compile-time evidence: every universal door is exported; the Engine
    -- type is abstract (no direct construction), and the protocol views
    -- (snapshot, net_document, history_page) live on the observation seam.
    let doors :: [String]
        doors =
          [ Engine.acceptDelivery `seq` "accept_delivery"
          , Engine.advance `seq` "advance"
          , Engine.activeScopes `seq` "active_scopes"
          , Engine.close `seq` "close"
          , Engine.closeScope `seq` "close_scope"
          , Engine.completeDelivery `seq` "complete_delivery"
          , Engine.create `seq` "create"
          , Engine.deliver `seq` "deliver"
          , Engine.inFlight `seq` "in_flight"
          , Engine.load `seq` "load"
          , Engine.marking `seq` "marking"
          , Engine.records `seq` "records"
          , Engine.resetScope `seq` "reset_scope"
          , Engine.seal `seq` "seal"
          , Engine.status `seq` "status"
          , Engine.openScope `seq` "open_scope"
          , Engine.wait `seq` "wait"
          ]
    length doors `shouldBe` 17

  it "engine module owns configuration outcome and policy vocabulary" $ do
    let vocabulary :: [String]
        vocabulary =
          [ (Engine.AcceptDelivery :: Engine.Delivery -> Engine.Action) `seq` "AcceptDelivery"
          , (Engine.AcceptResult :: Int -> ActivityOutcome -> Engine.Action) `seq` "AcceptResult"
          , (Engine.AdvanceTime :: Instant -> Engine.Action) `seq` "AdvanceTime"
          , (Engine.BeginCandidate :: Binding -> Engine.Action) `seq` "BeginCandidate"
          , (Engine.Clock :: IO Instant -> (Instant -> IO (Maybe Instant)) -> Engine.Clock) `seq` "Clock"
          , (Engine.delivery :: NetPath -> [Token] -> Text -> Maybe DeliveryScope -> Either Text Engine.Delivery) `seq` "Delivery"
          , (Engine.DriveOutcome :: [FiringOutcome] -> Bool -> Bool -> Maybe Instant -> Engine.DriveOutcome) `seq` "DriveOutcome"
          , (Engine.conservativePolicy :: Engine.DrivingPolicy) `seq` "DrivingPolicy"
          , (Engine.InFlightView :: Int -> NetPath -> [Selection] -> Bool -> Engine.InFlightView) `seq` "InFlightView"
          , (pure [] :: Engine.Sensor) `seq` "Sensor"
          , (Engine.simulatedClock :: Instant -> IO Engine.Clock) `seq` "SimulatedClock"
          , (Engine.Snapshot :: [Engine.Action] -> [Engine.InFlightView] -> Maybe Engine.Action -> Engine.Snapshot) `seq` "Snapshot"
          , Engine.Stop `seq` "Stop"
          , Engine.Wait `seq` "Wait"
          , Engine.chooseConservative `seq` "choose_conservative"
          , Engine.chooseThroughput `seq` "choose_throughput"
          ]
    length vocabulary `shouldBe` 16

  it "create accepts an explicit initial semantic instant while load derives it" $ do
    history <- inMemoryHistoryStore
    port <- inMemoryDispatch <$> newInMemoryDispatch
    created <- Engine.create sourceNet "real-time" history port Engine.defaultEngineOptions {Engine.at = 17}
    take 1 <$> Engine.records created `shouldReturn` [RInstanceCreated (InstanceCreated "real-time" Nothing 17)]
    Engine.close created

    port' <- inMemoryDispatch <$> newInMemoryDispatch
    loaded <- Engine.load sourceNet "real-time" history port' Engine.defaultEngineOptions
    recorded <- Store.records history
    Engine.records loaded `shouldReturn` recorded
    Engine.close loaded

  it "create advance close and load preserve one canonical history" $ do
    history <- inMemoryHistoryStore
    bridge <- newBridge "activity" b
    port <- inlineActivity
    engine <- Engine.create activityNet "neutral" history port (bridgeOptions bridge) {Engine.marking = input3}
    (created : RTokensInitialized initialized : _) <- Engine.records engine
    created `shouldBe` RInstanceCreated (InstanceCreated "neutral" Nothing 0)
    (initialized.place, initialized.tokens) `shouldBe` (a, [tokD "Input" (Int 3)])
    outcome <- advanceUntilRest engine
    outcome.waiting `shouldBe` False
    Engine.marking engine `shouldReturn` done3
    Engine.status engine `shouldReturn` Terminated
    recorded <- Engine.records engine
    Engine.close engine

    loadedBridge <- newBridge "activity" b
    port' <- inlineActivity
    loaded <- Engine.load activityNet "neutral" history port' (bridgeOptions loadedBridge)
    Engine.records loaded `shouldReturn` recorded
    Engine.marking loaded `shouldReturn` done3
    readIORef loadedBridge.prepared `shouldReturn` 0
    readIORef loadedBridge.projected `shouldReturn` 0
    Engine.close loaded

  -- Port-only: the hook through which a host counts handler calls or
  -- injects a fault (the reference's bridges do it inside the handler).
  describe "handler observer" $ do
    let observedHandler =
          ActivityBound
            ActivityHandler
              { prepare = \binding -> case bindingTokens binding of
                  t : _ -> Right (invocation "activity" t.payload)
                  [] -> Left "IndexError('tuple index out of range')"
              , project = \_ result -> Right (handlerTokens [(b, [tokD "Done" result])])
              , projectFailure = Nothing
              }
        observing armed calls =
          Engine.defaultEngineOptions
            { Engine.handlers = symbols [("bridge", observedHandler)]
            , Engine.marking = input3
            , Engine.handlerObserver = Just $ \call -> do
                let name = case call of
                      Engine.Preparing _ -> "prepare"
                      Engine.Projecting _ _ -> "project"
                      Engine.ProjectingFailure _ _ -> "project_failure" :: Text
                modifyIORef' calls (<> [name])
                fault <- readIORef armed
                pure (if fault == Just name then Left "RuntimeError('armed')" else Right ())
            }

    it "runs once before each Activity handler call" $ do
      history <- inMemoryHistoryStore
      port <- inlineActivity
      calls <- newIORef []
      armed <- newIORef Nothing
      engine <- Engine.create activityNet "observed" history port (observing armed calls)
      _ <- advanceUntilRest engine
      Engine.marking engine `shouldReturn` done3
      readIORef calls `shouldReturn` ["prepare", "project"]
      Engine.close engine

    it "answering Left raises the call before anything is appended" $ do
      history <- inMemoryHistoryStore
      port <- inlineActivity
      calls <- newIORef []
      armed <- newIORef (Just "prepare")
      engine <- Engine.create activityNet "observed-fault" history port (observing armed calls)
      before <- Engine.records engine
      Engine.advance engine `shouldThrow` (== Engine.EngineHandlerFailed "RuntimeError('armed')")
      readIORef calls `shouldReturn` ["prepare"]
      (toList <$> history.snapshot) `shouldReturn` before

  it "advance yields after each whole action" $ do
    history <- inMemoryHistoryStore
    port <- inlineActivity
    engine <- createWith activityNet "one-action" history port input3

    begun <- Engine.advance engine
    begun.ready `shouldBe` True
    begun.waiting `shouldBe` False
    length <$> Engine.inFlight engine `shouldReturn` 1
    afterBegin <- Engine.records engine
    any isActivityRequested afterBegin `shouldBe` True
    any isActivityCompleted afterBegin `shouldBe` False

    completed <- Engine.advance engine
    completed.ready `shouldBe` True
    transitions completed.firings `shouldBe` [work]
    Engine.marking engine `shouldReturn` done3

    stopped <- Engine.advance engine
    stopped.ready `shouldBe` False
    stopped.waiting `shouldBe` False
    stopped.nextMaturation `shouldBe` Nothing
    Engine.close engine

  forM_ [("choose_conservative" :: Text, Engine.conservativePolicy), ("choose_throughput", Engine.throughputPolicy)] $ \(name, policy) ->
    it ("future time does not make engine hide buffered ingress [" <> T.unpack name <> "]") $ do
      let cursor = np "cursor"
          tick = np "tick"
          net =
            netOf
              [place cursor, place output]
              [Transition tick Nothing [] [Delay 5], transition source]
              [arc cursor tick, arc tick cursor, arc source output]
          wallClock = Engine.Clock {Engine.now = pure 0, Engine.observe = \_ -> pure Nothing}
      parcels <- newIORef [[mkDelivery source [tokD "External" (Int 1)] "evt-1", mkDelivery source [tokD "External" (Int 2)] "evt-2"]]
      history <- inMemoryHistoryStore
      port <- inMemoryDispatch <$> newInMemoryDispatch
      engine <-
        Engine.create net ("future-time-" <> name) history port
          Engine.defaultEngineOptions
            { Engine.marking = markingFromList [(cursor, [tok "Cursor"])]
            , Engine.policy = policy
            , Engine.clock = Just wallClock
            , Engine.sensor = Just (atomicModifyIORef' parcels (\case [] -> ([], []); r : rs -> (rs, r)))
            }

      first <- Engine.advance engine
      second <- Engine.advance engine

      transitions (first.firings <> second.firings) `shouldBe` [source, source]
      second.ready `shouldBe` True
      toList . placeTokens output <$> Engine.marking engine `shouldReturn` [tokD "External" (Int 1), tokD "External" (Int 2)]
      Engine.close engine

-- ---------------------------------------------------------------------------

lifecycleScopes :: Spec
lifecycleScopes = describe "TestLifecycleScopes" $ do
  it "close commits before retiring pending dispatch and late terminal is quarantined" $ do
    history <- inMemoryHistoryStore
    pool <- newInMemoryDispatch
    engine <- createScoped history (inMemoryDispatch pool)
    scope <- Engine.openScope engine "draft"
    _ <- Engine.deliver engine source [tokD "Input" (Int 3)] "draft-3" (Just (ScopeGeneration scope))
    ready (Engine.advance engine) `shouldReturn` True
    [occurrence] <- pendingOccurrences pool

    closure <- Engine.closeScope engine scope

    closure.cancelled `shouldBe` [occurrence]
    pending pool `shouldReturn` []
    recorded <- Engine.records engine
    let closePositions = [i | (i, RScopeClosed _) <- zip [1 :: Int ..] recorded]
    fmap (.historyPosition) . IntMap.lookup occurrence <$> cancelledInstructions pool `shouldReturn` Just (head' closePositions)
    completeOccurrence pool occurrence (Object [("value", Int 3)])
    _ <- Engine.advance engine
    lastRecord <- last' <$> Engine.records engine
    case lastRecord of
      RActivityTerminalQuarantined quarantined -> quarantined.occurrence `shouldBe` occurrence
      other -> expectationFailure ("expected ActivityTerminalQuarantined, got " <> show other)

  it "restart acknowledges exact ended terminal redelivery and refuses conflict" $ do
    history <- inMemoryHistoryStore
    pool <- newInMemoryDispatch
    engine <- createScoped history (inMemoryDispatch pool)
    _ <- draftInFlight engine
    [occurrence] <- pendingOccurrences pool
    completeOccurrence pool occurrence (Object [("value", Int 3)])
    _ <- Engine.advance engine
    Engine.close engine

    reports <- newIORef [(occurrence, Succeeded (Object [("value", Int 3)]))]
    resumed <- loadScoped history (redelivering reports)
    before <- Store.records history

    _ <- Engine.advance resumed

    Store.records history `shouldReturn` before
    modifyIORef' reports (<> [(occurrence, Succeeded (Object [("value", Int 4)]))])
    Engine.advance resumed `shouldThrow` (\e -> valueError "different result" e && valueError "operational conflict" e)

  it "restart acknowledges exact quarantined terminal and refuses conflict" $ do
    history <- inMemoryHistoryStore
    pool <- newInMemoryDispatch
    engine <- createScoped history (inMemoryDispatch pool)
    scope <- draftInFlight engine
    [occurrence] <- pendingOccurrences pool
    _ <- Engine.closeScope engine scope
    Engine.close engine

    fresh <- newInMemoryDispatch
    reports <- newIORef [(occurrence, Succeeded (Object [("value", Int 3)]))]
    let redelivery = (inMemoryDispatch fresh) {collect = atomicModifyIORef' reports (\held -> ([], held))}
    resumed <- loadScoped history redelivery
    _ <- Engine.advance resumed
    before <- Store.records history
    modifyIORef' reports (<> [(occurrence, Succeeded (Object [("value", Int 3)]))])

    _ <- Engine.advance resumed

    Store.records history `shouldReturn` before
    modifyIORef' reports (<> [(occurrence, Succeeded (Object [("value", Int 4)]))])
    Engine.advance resumed `shouldThrow` valueError "conflicting terminal activity report"

  it "reset is one canonical record with no unscoped generation gap" $ do
    history <- inMemoryHistoryStore
    pool <- newInMemoryDispatch
    engine <- createScoped history (inMemoryDispatch pool)
    first <- draftInFlight engine
    before <- length <$> Engine.records engine

    second <- Engine.resetScope engine first

    (scopeName second, scopeGeneration second) `shouldBe` (scopeName first, scopeGeneration first + 1)
    Engine.activeScopes engine `shouldReturn` Map.fromList [("draft", second)]
    recorded <- Engine.records engine
    length recorded `shouldBe` before + 1
    case last' recorded of
      RScopeReset _ -> pure ()
      other -> expectationFailure ("expected ScopeReset, got " <> show other)
    pending pool `shouldReturn` []

  it "restart repairs a committed cancellation instruction idempotently" $ do
    history <- inMemoryHistoryStore
    pool <- newInMemoryDispatch
    engine <- createScoped history (inMemoryDispatch pool)
    scope <- draftInFlight engine
    closure <- Engine.closeScope engine scope
    Engine.close engine

    (repaired, instructions) <- recordingPool
    resumed <- loadScoped history repaired

    _ <- Engine.advance resumed

    issued <- readIORef instructions
    map (.occurrence) issued `shouldBe` closure.cancelled
    case (repaired.cancel, issued) of
      (Just cancelPort, instruction : _) -> cancelPort instruction `shouldReturn` Acknowledged
      _ -> expectationFailure "expected a cancellable Dispatch and a recorded instruction"

  forM_ ["close" :: Text, "reset"] $ \operation ->
    it ("post commit cancellation failure poisoning is repaired after restart [" <> T.unpack operation <> "]") $ do
      let message = "injected " <> operation <> " cancellation failure"
      pool <- newInMemoryDispatch
      let failing = (inMemoryDispatch pool) {cancel = Just (\_ -> throwIO (Engine.EngineRuntimeError message))}
      history <- inMemoryHistoryStore
      engine <- createScoped history failing
      scope <- draftInFlight engine
      [occurrence] <- pendingOccurrences pool

      (if operation == "close" then void (Engine.closeScope engine scope) else void (Engine.resetScope engine scope))
        `shouldThrow` runtimeError message

      terminal <- last' <$> Store.records history
      opened <- case terminal of
        RScopeClosed closed | operation == "close" -> (closed.cancelled `shouldBe` [occurrence]) >> pure Nothing
        RScopeReset reset | operation == "reset" -> (reset.cancelled `shouldBe` [occurrence]) >> pure (Just reset.opened)
        _ -> expectationFailure ("unexpected terminal record " <> show terminal) >> pure Nothing

      (repaired, instructions) <- recordingPool
      resumed <- loadScoped history repaired
      _ <- Engine.advance resumed

      map (.occurrence) <$> readIORef instructions `shouldReturn` [occurrence]
      forM_ opened $ \successor -> Engine.activeScopes resumed `shouldReturn` Map.fromList [("draft", successor)]

  it "scope close append failure never notifies dispatch" $ do
    base <- inMemoryHistoryStore
    let refusing =
          base
            { extend = \batch ->
                if any (\case RScopeClosed _ -> True; _ -> False) batch
                  then throwIO (userError "close refused")
                  else base.extend batch
            }
    (dispatch', instructions) <- recordingPool
    engine <- createScoped refusing dispatch'
    scope <- draftInFlight engine

    Engine.closeScope engine scope `shouldThrow` ioErrorContaining "close refused"

    readIORef instructions `shouldReturn` []

  it "unsupported dispatch is refused before canonical close" $ do
    dispatched <- newIORef []
    let legacy =
          Dispatch
            { dispatch = \occurrence inv -> modifyIORef' dispatched (<> [(occurrence, inv)])
            , collect = pure []
            , cancel = Nothing
            }
    history <- inMemoryHistoryStore
    engine <- createScoped history legacy
    scope <- draftInFlight engine
    before <- Store.size history

    Engine.closeScope engine scope `shouldThrow` (\e -> typeError "does not implement" e && typeError "cancellation" e)

    Store.size history `shouldReturn` before

  it "sensor delivery preserves exact scope provenance" $ do
    holder <- newIORef []
    bridge <- newBridge "activity" b
    history <- inMemoryHistoryStore
    port <- inMemoryDispatch <$> newInMemoryDispatch
    engine <- Engine.create scopedNet "scoped-sensor" history port (bridgeOptions bridge) {Engine.sensor = Just (readIORef holder)}
    scope <- Engine.openScope engine "draft"
    writeIORef holder [mkScopedDelivery source [tokD "Input" (Int 3)] "sensor-3" (Just (ScopeGeneration scope))]

    _ <- Engine.advance engine

    Engine.marking engine `shouldReturn` markingFromList [(a, [tokD "Input" (Int 3)])]
    _ <- Engine.closeScope engine scope
    markingNull <$> Engine.marking engine `shouldReturn` True

-- ---------------------------------------------------------------------------

neutralSurfaceContinued :: Spec
neutralSurfaceContinued = describe "TestNeutralEngineSurfaceContinued" $ do
  it "direct identifier delivery enables a separate fetch activity" $ do
    let fetched = np "fetched"
        fetch = np "fetch"
        fetchHandler =
          ActivityHandler
            { prepare = \binding -> case bindingTokens binding of
                first : _ -> Right (invocation "fetch" (Object [("id", first.payload)]))
                [] -> Left "IndexError('tuple index out of range')"
            , project = \_ result -> Right (handlerTokens [(fetched, [tokD "Fetched" result])])
            , projectFailure = Nothing
            }
        net =
          netOf
            [place output, place fetched]
            [transition source, Transition fetch (Just (HandlerSymbol "fetch")) [] []]
            [arc source output, arc output fetch, arc fetch fetched]
    port <- inlineOf [("fetch", \inv _ -> pure (Object [("body", maybe Null id (lookupMember "id" inv.input))]))]
    history <- inMemoryHistoryStore
    engine <-
      Engine.create net "identifier-fetch" history port
        Engine.defaultEngineOptions {Engine.handlers = symbols [("fetch", ActivityBound fetchHandler)]}

    _ <- Engine.deliver engine source [tokD "ExternalId" (String "evt-7")] "webhook-7" Nothing
    recorded <- Engine.records engine
    any (\case RExternalEventDelivered delivered -> delivered.identity == "webhook-7"; _ -> False) recorded `shouldBe` True

    ready (Engine.advance engine) `shouldReturn` True
    ready (Engine.advance engine) `shouldReturn` True
    ready (Engine.advance engine) `shouldReturn` False
    Engine.marking engine `shouldReturn` markingFromList [(fetched, [tokD "Fetched" (Object [("body", String "evt-7")])])]
    Engine.close engine

  it "create load and identity preconditions refuse without mutation" $ do
    empty <- inMemoryHistoryStore
    port <- inlineActivity
    loadWith activityNet "missing" empty port `shouldThrow` valueError "does not exist"
    Store.records empty `shouldReturn` []

    recorded <- inMemoryHistoryStore
    created <- createWith activityNet "recorded" recorded port emptyMarking
    before <- Store.records recorded
    createWith activityNet "recorded" recorded port emptyMarking `shouldThrow` valueError "already exists"
    loadWith activityNet "different" recorded port
      `shouldThrow` valueError "storage key and recorded identity must match exactly"
    Store.records recorded `shouldReturn` before
    Engine.close created

  it "a joined-transaction store without a commit point is refused (beyond upstream)" $ do
    tx <- newTransactionalHistory
    port <- inlineActivity
    released <- newIORef (0 :: Int)
    openEngine CreateInstance activityNet "joined" tx.store port Engine.defaultEngineOptions (txResources tx (modifyIORef' released (+ 1))) {commit = Nothing}
      `shouldThrow` valueError "a joined-transaction History store requires the provider's commit point"
    -- The refusal is a construction failure: the provider's resources are
    -- rolled back and released, and nothing was appended.
    readIORef tx.rollbacks `shouldReturn` 1
    readIORef released `shouldReturn` 1
    txPending tx `shouldReturn` []
    txCommitted tx `shouldReturn` []

  it "activity policy resolution belongs to engine and snapshots declarations" $ do
    -- Declarations are immutable values here: the reference's
    -- @declarations.clear()@ after construction has no Haskell spelling.
    declaration <- either (fail . show) pure (activityDeclaration "activity" (Just 7))
    bridge <- newBridge "activity" b
    history <- inMemoryHistoryStore
    port <- inMemoryDispatch <$> newInMemoryDispatch
    engine <-
      Engine.create activityNet "policy" history port
        (bridgeOptions bridge)
          { Engine.marking = input3
          , Engine.activities = [declaration]
          , Engine.defaultHeartbeatTimeout = 4
          }

    waiting (advanceUntilRest engine) `shouldReturn` True
    recorded <- Engine.records engine
    case [r | RActivityRequested r <- recorded] of
      r : _ -> (policyFields r.policy).heartbeatTimeout `shouldBe` 7
      [] -> expectationFailure "expected an ActivityRequested record"
    Engine.close engine

  it "wait is bounded without provider notification and in memory work can be pumped" $ do
    history <- inMemoryHistoryStore
    pool <- newInMemoryDispatch
    engine <- createWith activityNet "pumped" history (inMemoryDispatch pool) input3

    waiting (advanceUntilRest engine) `shouldReturn` True
    Engine.wait engine 0 `shouldReturn` False
    [occurrence] <- pendingOccurrences pool
    completeOccurrence pool occurrence (Object [("value", Int 3)])
    waiting (advanceUntilRest engine) `shouldReturn` False
    Engine.status engine `shouldReturn` Terminated
    Engine.close engine

  it "deliver seal and close are isolated between two neutral engines" $ do
    leftHistory <- inMemoryHistoryStore
    rightHistory <- inMemoryHistoryStore
    leftPort <- inMemoryDispatch <$> newInMemoryDispatch
    rightPort <- inMemoryDispatch <$> newInMemoryDispatch
    left <- Engine.create sourceNet "left" leftHistory leftPort Engine.defaultEngineOptions
    right <- Engine.create sourceNet "right" rightHistory rightPort Engine.defaultEngineOptions

    _ <- Engine.deliver left source [tokD "Input" (String "left")] "left-event" Nothing
    Engine.seal left source
    Engine.marking left `shouldReturn` markingFromList [(output, [tokD "Input" (String "left")])]
    Engine.marking right `shouldReturn` emptyMarking
    leftRecords <- Engine.records left
    rightRecords <- Engine.records right
    leftRecords `shouldNotBe` rightRecords

    Engine.close left
    _ <- Engine.deliver right source [tokD "Input" (String "right")] "right-event" Nothing
    Engine.marking right `shouldReturn` markingFromList [(output, [tokD "Input" (String "right")])]
    Engine.seal right source
    Engine.close right

  it "a writing failure poisons the whole engine and fresh load recovers" $ do
    history <- inMemoryHistoryStore
    raising <- raisingDispatch "dispatch unavailable"
    engine <- createWith activityNet "poison" history raising input3
    Engine.advance engine `shouldThrow` runtimeError "dispatch unavailable"
    forM_ (readingDoors engine) $ \door -> door `shouldThrow` runtimeError "fresh Engine.load"

    port <- inlineActivity
    resumed <- loadWith activityNet "poison" history port
    waiting (advanceUntilRest resumed) `shouldReturn` False
    Engine.marking resumed `shouldReturn` done3
    Engine.close resumed

  it "close is hosting only idempotent and hands out no mutable collaborator" $ do
    -- The Engine type is abstract: no coordinator, dispatch, instance,
    -- history, or resources handle is exported from Petrus.Engine.
    history <- inMemoryHistoryStore
    port <- inlineActivity
    engine <- createWith activityNet "closed" history port emptyMarking
    recorded <- Store.records history

    Engine.close engine
    Engine.close engine
    Store.records history `shouldReturn` recorded
    forM_ (readingDoors engine) $ \door -> door `shouldThrow` runtimeError "Engine is closed"

-- ---------------------------------------------------------------------------

joinedTransactionFate :: Spec
joinedTransactionFate = describe "TestPrivateJoinedTransactionFate" $ do
  it "commit refusal rolls back and never installs the selection" $ do
    tx <- newTransactionalHistory
    modifyIORef' tx.refuse (Set.insert 3) -- construction, reconcile, then begin boundary
    released <- newIORef []
    port <- inMemoryDispatch <$> newInMemoryDispatch
    handler <- freshBridge
    engine <- joinedEngine tx port True handler Nothing (modifyIORef' released (<> [True]))

    Engine.advance engine `shouldThrow` runtimeError "commit 3 refused"

    any isCandidateSelected <$> txCommitted tx `shouldReturn` False
    txPending tx `shouldReturn` []
    readIORef tx.rollbacks `shouldReturn` 1
    readIORef released `shouldReturn` [True]
    selectionState engine `shouldReturn` "Nothing"

  it "dispatch failure rolls back the uncommitted begin and releases hosting" $ do
    tx <- newTransactionalHistory
    released <- newIORef []
    raising <- raisingDispatch "dispatch failed"
    handler <- freshBridge
    engine <- joinedEngine tx raising True handler Nothing (modifyIORef' released (<> [True]))

    Engine.advance engine `shouldThrow` runtimeError "dispatch failed"

    any isCandidateSelected <$> txCommitted tx `shouldReturn` False
    txPending tx `shouldReturn` []
    readIORef tx.rollbacks `shouldReturn` 1
    readIORef released `shouldReturn` [True]
    selectionState engine `shouldReturn` "Nothing"

  it "selection installs only after the begin commit returns" $ do
    tx <- newTransactionalHistory
    observed <- newIORef []
    holder <- newIORef Nothing
    let commit' = do
          held <- readIORef holder
          selected <- any isCandidateSelected <$> txPending tx
          case held of
            Just engine | selected -> selectionState engine >>= \s -> modifyIORef' observed (<> [s])
            _ -> pure ()
          txCommit tx
    port <- inMemoryDispatch <$> newInMemoryDispatch
    handler <- freshBridge
    engine <- joinedEngine tx port True handler (Just commit') (pure ())
    writeIORef holder (Just engine)

    ready (Engine.advance engine) `shouldReturn` True

    readIORef observed `shouldReturn` ["Nothing"]
    selectionState engine `shouldReturn` "Just 0"
    any isCandidateSelected <$> txCommitted tx `shouldReturn` True

  it "second boundary commit failure keeps the frozen terminal but not projection" $ do
    tx <- newTransactionalHistory
    pool <- newInMemoryDispatch
    handler <- freshBridge
    engine <- joinedEngine tx (inMemoryDispatch pool) True handler Nothing (pure ())
    ready (Engine.advance engine) `shouldReturn` True
    completeOccurrence pool 1 (Object [("value", Int 3)])
    modifyIORef' tx.refuse (Set.insert 5) -- freeze is commit 4; projection boundary is commit 5

    Engine.advance engine `shouldThrow` runtimeError "commit 5 refused"

    length . filter isActivityCompleted <$> txCommitted tx `shouldReturn` 1
    any isFiringCompleted <$> txCommitted tx `shouldReturn` False
    txPending tx `shouldReturn` []

    fresh <- inMemoryDispatch <$> newInMemoryDispatch
    handler' <- freshBridge
    resumed <- joinedEngine tx fresh False handler' Nothing (pure ())
    outcome <- Engine.advance resumed
    transitions outcome.firings `shouldBe` [work]
    Engine.marking resumed `shouldReturn` done3

  it "terminal result freezes before projection failure and fresh load retries projection only" $ do
    bridge <- newBridge "activity" b
    let broken = case bridge.handler of
          ActivityBound h -> ActivityBound h {project = \_ _ -> Left "KeyError('projection bug')"}
          other -> other
    tx <- newTransactionalHistory
    pool <- newInMemoryDispatch
    engine <- joinedEngine tx (inMemoryDispatch pool) True broken Nothing (pure ())
    ready (Engine.advance engine) `shouldReturn` True
    completeOccurrence pool 1 (Object [("value", Int 3)])

    Engine.advance engine `shouldThrow` handlerFailed "projection bug"

    length . filter isActivityCompleted <$> txCommitted tx `shouldReturn` 1
    any isFiringCompleted <$> txCommitted tx `shouldReturn` False

    fresh <- inMemoryDispatch <$> newInMemoryDispatch
    handler' <- freshBridge
    resumed <- joinedEngine tx fresh False handler' Nothing (pure ())
    outcome <- Engine.advance resumed
    transitions outcome.firings `shouldBe` [work]
    Engine.marking resumed `shouldReturn` done3

-- ---------------------------------------------------------------------------

head', last' :: [x] -> x
head' = \case x : _ -> x; [] -> error "empty"
last' = head' . reverse
