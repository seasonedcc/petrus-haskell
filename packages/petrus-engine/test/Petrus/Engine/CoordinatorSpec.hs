-- | Port of upstream @tests/petrus/engine/test_coordinator.py@: the
-- asynchronous coordinator's drive loop, the two shipped policies,
-- selection durability, late completions, sensed ingress, and
-- reconcile-then-drive.
--
-- @TestInMemoryDispatch@ and @TestInlineDispatch@ are ported in the
-- petrus-motus test suite.
module Petrus.Engine.CoordinatorSpec (spec) where

import Control.Exception (ErrorCall (..), IOException, bracket, throwIO)
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTimeNSec)
import Petrus.Engine qualified as Engine
import Petrus.Engine.TestSupport
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.Impetus.Binding
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore (HistoryStore (..), inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
  ( FiringOccurrence (..)
  , FiringOutcome (..)
  , ImplementationRef
  , Instance
  , InstanceConfig (..)
  , InstanceError (..)
  , defaultInstanceConfig
  , newInstance
  , recordActivityCompletion
  )
import Petrus.Impetus.Instance qualified as I
import Petrus.Impetus.Petrinet hiding (selection, token)
import Petrus.Impetus.Selection (SelectionPolicy (..), first, priority, roundRobin, selectionPipeline)
import Petrus.Impetus.TestSupport (expectRight, netOf, np, tok, tokD)
import Petrus.Json (Json (..), exactEq, lookupMember)
import Petrus.Motus.Dispatch (ActivityOutcome (..), Dispatch (..))
import Petrus.Motus.Dispatch.InMemory (InMemoryDispatch, completeOccurrence, failOccurrence, inMemoryDispatch, newInMemoryDispatch, pending)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Hspec hiding (before, errorCall, pending)
import Test.QuickCheck (Gen, Property, conjoin, counterexample, elements, forAll, oneof, property, shuffle, sublistOf, (===))

a1, t1, b1, a2, t2, b2, a, t, b, src :: NetPath
a1 = np "a1"
t1 = np "t1"
b1 = np "b1"
a2 = np "a2"
t2 = np "t2"
b2 = np "b2"
a = np "a"
t = np "t"
b = np "b"
src = np "src"

-- ---------------------------------------------------------------------------
-- Fixtures

-- | a1 -> t1 -> b1 and a2 -> t2 -> b2: two structurally independent impure
-- transitions.
independentNet :: Net
independentNet =
  netOf
    [place a1, place b1, place a2, place b2]
    [Transition t1 (Just (HandlerSymbol "one")) [] [], Transition t2 (Just (HandlerSymbol "two")) [] []]
    [arc a1 t1, arc t1 b1, arc a2 t2, arc t2 b2]

independentMarking :: Marking
independentMarking = markingFromList [(a1, [tokD "X" (obj [("n", Int 1)])]), (a2, [tokD "Y" (obj [("n", Int 2)])])]

obj :: [(Text, Json)] -> Json
obj = Object

data Handlers = Handlers {one :: Bridge, two :: Bridge}

newHandlers :: IO Handlers
newHandlers = Handlers <$> newBridge "work_one" b1 <*> newBridge "work_two" b2

handlerMap :: Handlers -> Map.Map ImplementationRef BoundHandler
handlerMap hs = symbols [("one", hs.one.handler), ("two", hs.two.handler)]

independentInstance :: IO Instance
independentInstance = do
  hs <- newHandlers
  newInstance independentNet defaultInstanceConfig {initialMarking = independentMarking, handlerImplementations = handlerMap hs}
    >>= expectRight

-- | @_independent_engine(dispatch, history=..., policy=..., ...)@.
independentEngine :: Dispatch -> Maybe HistoryStore -> (Engine.EngineOptions -> Engine.EngineOptions) -> IO (Engine.Engine, Handlers, HistoryStore)
independentEngine port history configure = do
  hs <- newHandlers
  store <- maybe inMemoryHistoryStore pure history
  engine <-
    Engine.create independentNet "coordinator-test" store port $
      configure
        Engine.defaultEngineOptions
          { Engine.marking = independentMarking
          , Engine.handlers = handlerMap hs
          }
  pure (engine, hs, store)

-- | @_activity_net(handler)@: a -> t -> b.
activityNet :: Maybe Text -> Net
activityNet handler =
  netOf [place a, place b] [Transition t (HandlerSymbol <$> handler) [] []] [arc a t, arc t b]

bindingOf :: Instance -> Int -> IO Binding
bindingOf inst index = (!! index) <$> I.candidates inst

views :: Instance -> IO [Engine.InFlightView]
views inst = map (\o -> Engine.InFlightView o.occurrence o.binding.transition o.binding.consumed (isJust o.invocation)) <$> I.inFlight inst

choose :: (Engine.Snapshot -> Either Text Engine.Action) -> Engine.Snapshot -> IO Engine.Action
choose policy snapshot = expectRight (policy snapshot)

snap :: [Engine.Action] -> [Engine.InFlightView] -> Engine.Snapshot
snap actions inFlight = Engine.Snapshot actions inFlight Nothing

after' :: Engine.Action -> [Engine.Action] -> Engine.Snapshot
after' previous actions = Engine.Snapshot actions [] (Just previous)

ok :: Json
ok = obj [("ok", Bool True)]

roundRobinOf :: [NetPath] -> Engine.EngineSelection
roundRobinOf ring = either (error . T.unpack) (`Engine.EngineSelection` Nothing) (roundRobin ring)

pool' :: IO (InMemoryDispatch, Dispatch)
pool' = do
  pool <- newInMemoryDispatch
  pure (pool, inMemoryDispatch pool)

inMemory :: IO Dispatch
inMemory = snd <$> pool'

-- | Capture every offered BeginCandidate, then Stop.
capturing :: IORef [Engine.Action] -> Engine.DrivingPolicy
capturing ref snapshot = do
  modifyIORef' ref (<> [action | action@(Engine.BeginCandidate _) <- snapshot.actions])
  pure Engine.Stop

beginTransitions :: [Engine.Action] -> [NetPath]
beginTransitions actions = [binding.transition | Engine.BeginCandidate binding <- actions]

candidateSelections :: HistoryStore -> IO [NetPath]
candidateSelections store = (\rs -> [r.transition | RCandidateSelected r <- rs]) <$> Store.records store

-- | A list consumed one round per call, empty once exhausted
-- (@next(parcels, ())@).
draining :: [[a]] -> IO (IO [a])
draining rounds = do
  ref <- newIORef rounds
  pure $ atomicModifyIORef' ref (\case [] -> ([], []); r : rs -> (rs, r))

tokensAt :: NetPath -> Marking -> [Token]
tokensAt p m = toList (placeTokens p m)

numberOf :: Token -> Maybe Json
numberOf token = lookupMember "n" token.payload

withScratch :: (FilePath -> IO r) -> IO r
withScratch body = do
  tmp <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let dir = tmp </> ("petrus-engine-coordinator-" <> show stamp)
  bracket (createDirectoryIfMissing True dir >> pure dir) removeDirectoryRecursive body

wallClock :: IORef Instant -> IORef [Instant] -> Engine.Clock
wallClock at observations =
  Engine.Clock
    { now = readIORef at
    , observe = \instant -> do
        modifyIORef' observations (<> [instant])
        current <- readIORef at
        pure (if current < instant then Nothing else Just current)
    }

errorCall :: Text -> Selector ErrorCall
errorCall fragment (ErrorCall message) = fragment `T.isInfixOf` T.pack message

-- | An adapter scripted round by round: dispatch acknowledges, each collect
-- returns the next scripted batch.
scriptedAdapter :: [[(Int, ActivityOutcome)]] -> IO (Dispatch, IORef [Int])
scriptedAdapter rounds = do
  remaining <- newIORef rounds
  dispatched <- newIORef []
  let port =
        Dispatch
          { dispatch = \occurrence _ -> modifyIORef' dispatched (<> [occurrence])
          , collect = atomicModifyIORef' remaining (\case [] -> ([], []); r : rs -> (rs, r))
          , cancel = Nothing
          }
  pure (port, dispatched)

raisingDispatch :: IO Dispatch
raisingDispatch = do
  port <- inMemory
  pure port {dispatch = \_ _ -> throwIO (ErrorCall "dispatch failed")}

-- | @RefusingHistory@: an in-memory store whose appends raise once refused.
refusingHistory :: IO (HistoryStore, IORef Bool)
refusingHistory = do
  inner <- inMemoryHistoryStore
  refused <- newIORef False
  let extend' records = do
        refusing <- readIORef refused
        if refusing then ioError (userError "disk full") else inner.extend records
  pure (inner {extend = extend'}, refused)

-- | Every kind of action a live instance offers, and its in-flight views.
policyPool :: IO ([Engine.Action], [Engine.InFlightView])
policyPool = do
  inst <- independentInstance
  begun <- bindingOf inst 0
  occurrence <- I.begin inst begun Nothing >>= expectRight
  candidates' <- I.candidates inst
  vs <- views inst
  let deliver name = Engine.AcceptDelivery (mkDelivery src [tok "X"] name)
  pure
    ( [ Engine.AcceptResult occurrence.occurrence (Succeeded ok)
      , deliver "property-1"
      , deliver "property-2"
      , Engine.AdvanceTime 9
      , Engine.Wait
      , Engine.Stop
      , Engine.BeginCandidate begun
      ]
        <> map Engine.BeginCandidate candidates'
    , vs
    )

snapshotOf :: [Engine.Action] -> [Engine.InFlightView] -> Gen Engine.Snapshot
snapshotOf offered inFlight = do
  actions <- sublistOf offered >>= shuffle
  views' <- sublistOf inFlight
  previous <- oneof [pure Nothing, Just <$> elements offered]
  pure (Engine.Snapshot actions views' previous)

drawnFrom :: (Engine.Snapshot -> Either Text Engine.Action) -> Engine.Snapshot -> Property
drawnFrom policy snapshot = case policy snapshot of
  Right action -> counterexample ("chose an action not offered: " <> show action) (action `elem` snapshot.actions)
  Left _ -> property True

-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "TestConservativePolicy" $ do
    it "an arrived result outranks everything" $ do
      inst <- independentInstance
      binding <- bindingOf inst 0
      occurrence <- I.begin inst binding Nothing >>= expectRight
      let accept = Engine.AcceptResult occurrence.occurrence (Succeeded ok)
      next' <- bindingOf inst 0
      vs <- views inst
      choose Engine.chooseConservative (snap [accept, Engine.BeginCandidate next', Engine.AdvanceTime 9, Engine.Wait, Engine.Stop] vs)
        `shouldReturn` accept

    it "one candidate at a time waits on an outstanding result" $ do
      inst <- independentInstance
      _ <- bindingOf inst 0 >>= \binding -> I.begin inst binding Nothing >>= expectRight
      next' <- bindingOf inst 0
      vs <- views inst
      choose Engine.chooseConservative (snap [Engine.BeginCandidate next', Engine.Wait, Engine.Stop] vs) `shouldReturn` Engine.Wait

    it "ingress interrupts once then candidate and time make progress" $ do
      inst <- independentInstance
      begin <- Engine.BeginCandidate <$> bindingOf inst 0
      let deliver = Engine.AcceptDelivery (mkDelivery src [tok "X"] "policy-event")
      choose Engine.chooseConservative (snap [begin, Engine.AdvanceTime 9, deliver, Engine.Stop] []) `shouldReturn` deliver
      choose Engine.chooseConservative (after' deliver [begin, deliver, Engine.Stop]) `shouldReturn` begin
      choose Engine.chooseConservative (after' deliver [Engine.AdvanceTime 9, deliver, Engine.Stop]) `shouldReturn` Engine.AdvanceTime 9
      choose Engine.chooseConservative (snap [deliver, Engine.Stop] []) `shouldReturn` deliver
      choose Engine.chooseConservative (snap [Engine.Stop] []) `shouldReturn` Engine.Stop

    it "wait does not block buffered ingress even after a delivery" $ do
      let deliver = Engine.AcceptDelivery (mkDelivery src [tok "X"] "buffered-event")
      choose Engine.chooseConservative (after' deliver [deliver, Engine.Wait, Engine.Stop]) `shouldReturn` deliver

  describe "TestThroughputPolicy" $ do
    it "begins independent work before accepting results" $ do
      inst <- independentInstance
      occurrence <- bindingOf inst 0 >>= \binding -> I.begin inst binding Nothing >>= expectRight
      -- t2: structurally independent of in-flight t1
      begin <- Engine.BeginCandidate <$> bindingOf inst 0
      vs <- views inst
      choose Engine.chooseThroughput (snap [Engine.AcceptResult occurrence.occurrence (Succeeded ok), begin, Engine.Wait, Engine.Stop] vs)
        `shouldReturn` begin

    let aliasedInstance = do
          let dup = tokD "X" (obj [("n", Int 1)])
              other = tok "Y"
              net = netOf [place a, place b] [Transition t (Just (HandlerSymbol "charge")) [] []] [Arc a t Consume 2 Nothing Nothing, arc t b]
          bridge <- newBridge "work" b
          inst <-
            newInstance net defaultInstanceConfig {initialMarking = markingFromList [(a, [dup, dup, other])], handlerImplementations = symbols [("charge", bridge.handler)]}
              >>= expectRight
          bindings <- I.candidates inst
          (bindings !! 1) `shouldBe` (bindings !! 2) -- the aliased pair, sharing `other`
          pure (inst, bindings)

    it "skips a candidate whose selections collide with in flight work" $ do
      (inst, bindings) <- aliasedInstance
      _ <- I.begin inst (bindings !! 1) Nothing >>= expectRight
      vs <- views inst
      choose Engine.chooseThroughput (snap [Engine.BeginCandidate (bindings !! 2), Engine.Wait, Engine.Stop] vs) `shouldReturn` Engine.Wait

    it "ingress interrupts once then existing candidate precedence resumes" $ do
      inst <- independentInstance
      begin <- Engine.BeginCandidate <$> bindingOf inst 0
      let deliver = Engine.AcceptDelivery (mkDelivery src [tok "X"] "throughput-event")
          result = Engine.AcceptResult 1 (Succeeded ok)
      choose Engine.chooseThroughput (snap [result, begin, deliver, Engine.Stop] []) `shouldReturn` deliver
      choose Engine.chooseThroughput (after' deliver [result, begin, deliver, Engine.Stop]) `shouldReturn` begin

    it "a hand forced second begin of the aliased twin fails loud" $ do
      (inst, bindings) <- aliasedInstance
      firstOccurrence <- I.begin inst (bindings !! 1) Nothing >>= expectRight
      I.begin inst (bindings !! 2) Nothing >>= \case
        Left (Refused message) -> message `shouldSatisfy` T.isInfixOf "stale selection"
        other -> expectationFailure ("expected a stale-selection refusal, got " <> either show show other)
      I.inFlight inst `shouldReturn` [firstOccurrence]

  -- Port-only: the laws every snapshot obeys, over random offers drawn from
  -- one live instance's actions (results, ingress, time, waits, stops, an
  -- independent begin and one that collides with the in-flight work).
  describe "built-in driving policies (properties)" $
    beforeAll policyPool $
      it "choose an offered action, and the conservative one always chooses" $ \(offered, inFlight) ->
        forAll (snapshotOf offered inFlight) $ \snapshot ->
          conjoin
            [ drawnFrom Engine.chooseConservative snapshot
            , drawnFrom Engine.chooseThroughput snapshot
            , counterexample "conservative refused a non-empty offer" (isLeft (Engine.chooseConservative snapshot) === null snapshot.actions)
            ]

  describe "TestOneActionDrive" $ do
    it "each drive applies at most one normal action" $ do
      (pool, port) <- pool'
      (engine, _, _) <- independentEngine port Nothing (\o -> o {Engine.policy = Engine.throughputPolicy})
      Engine.advance engine `shouldReturn` Engine.DriveOutcome [] False True Nothing
      length <$> Engine.inFlight engine `shouldReturn` 1
      length <$> pending pool `shouldReturn` 1
      second <- Engine.advance engine
      second.ready `shouldBe` True
      length <$> Engine.inFlight engine `shouldReturn` 2
      length <$> pending pool `shouldReturn` 2
      Engine.advance engine `shouldReturn` Engine.DriveOutcome [] True False Nothing

    it "a future wall clock maturation returns without waiting" $ do
      let net = netOf [place a, place b] [Transition t Nothing [] [Delay 5]] [arc a t, arc t b]
      at <- newIORef 0
      observations <- newIORef []
      port <- inMemory
      store <- inMemoryHistoryStore
      engine <-
        Engine.create net "future-maturation-test" store port
          Engine.defaultEngineOptions {Engine.marking = markingFromList [(a, [tok "X"])], Engine.clock = Just (wallClock at observations)}
      Engine.advance engine `shouldReturn` Engine.DriveOutcome [] False False (Just 5)
      readIORef observations `shouldReturn` [5]
      records <- Engine.records engine
      [r | r@(RTimerMatured _) <- records] `shouldBe` []
      writeIORef at 7
      Engine.advance engine `shouldReturn` Engine.DriveOutcome [] False True Nothing
      Engine.records engine >>= (`shouldSatisfy` elem (RTimerMatured (TimerMatured 5 7)))

    let policies = [("choose_conservative", Engine.conservativePolicy), ("choose_throughput", Engine.throughputPolicy)]
    mapM_
      ( \(name, policy) ->
          it ("a future timer cannot hide buffered ingress after an ingress turn [" <> name <> "]") $ do
            let cursor = np "cursor"
                tick = np "tick"
                net = netOf [place cursor, place a] [Transition tick Nothing [] [Delay 5], transition src] [arc cursor tick, arc tick cursor, arc src a]
            sensor <-
              draining
                [[mkDelivery src [tokD "X" (obj [("n", Int 1)])] "evt_1", mkDelivery src [tokD "X" (obj [("n", Int 2)])] "evt_2"]]
            observations <- newIORef []
            port <- inMemory
            store <- inMemoryHistoryStore
            let clock =
                  Engine.Clock
                    { now = pure 0
                    , observe = \instant -> modifyIORef' observations (<> [instant]) >> pure Nothing
                    }
            engine <-
              Engine.create net ("buffered-ingress-" <> T.pack name) store port
                Engine.defaultEngineOptions
                  { Engine.marking = markingFromList [(cursor, [tok "Cursor"])]
                  , Engine.policy = policy
                  , Engine.clock = Just clock
                  , Engine.sensor = Just sensor
                  }
            first' <- Engine.advance engine
            second <- Engine.advance engine
            map (.transition) (first'.firings <> second.firings) `shouldBe` [src, src]
            second.ready `shouldBe` True
            Engine.marking engine >>= \m -> map numberOf (tokensAt a m) `shouldBe` [Just (Int 1), Just (Int 2)]
            readIORef observations `shouldReturn` [5]
      )
      policies

  describe "TestConcurrentInFlight" $ do
    it "independent occurrences interleave and results commit in arrival order" $ do
      (pool, port) <- pool'
      (engine, _, history) <-
        independentEngine port Nothing (\o -> o {Engine.policy = Engine.throughputPolicy, Engine.selection = roundRobinOf [t2, t1]})
      -- begins both, dispatches both, returns control on Wait
      advanceUntilRest engine `shouldReturn` Engine.DriveOutcome [] True False Nothing
      length <$> Engine.inFlight engine `shouldReturn` 2
      records <- Store.records history
      [r.activity | RActivityRequested r <- records] `shouldBe` ["work_two", "work_one"]
      [() | RActivityCompleted _ <- records] `shouldBe` []
      [oneOccurrence, twoOccurrence] <- map (.occurrence) <$> Engine.inFlight engine
      Set.fromList . map fst <$> pending pool `shouldReturn` Set.fromList [oneOccurrence, twoOccurrence]

      completeOccurrence pool twoOccurrence (obj [("n", Int 1)]) -- completion order != begin order
      completeOccurrence pool oneOccurrence (obj [("n", Int 2)])
      outcome <- advanceUntilRest engine
      map (.occurrence) outcome.firings `shouldBe` [twoOccurrence, oneOccurrence] -- arrival order
      outcome.waiting `shouldBe` False -- quiescent, nothing outstanding
      records' <- Store.records history
      [r.occurrence | RActivityCompleted r <- records'] `shouldBe` [twoOccurrence, oneOccurrence]
      Engine.marking engine
        `shouldReturn` markingFromList [(b1, [tokD "Done" (obj [("n", Int 1)])]), (b2, [tokD "Done" (obj [("n", Int 2)])])]
      Engine.inFlight engine `shouldReturn` []

    it "a terminal activity failure is recorded as one batch and halts the drive" $ do
      (pool, port) <- pool'
      (engine, _, history) <- independentEngine port Nothing id
      (.waiting) <$> advanceUntilRest engine `shouldReturn` True
      [occurrence] <- Engine.inFlight engine
      failOccurrence pool occurrence.occurrence "provider down"
      Engine.advance engine `shouldThrow` runtimeError "provider down"
      records <- Store.records history
      drop (length records - 2) records
        `shouldBe` [ RActivityFailed (ActivityFailed t1 "provider down" "ActivityError" Null False Nothing occurrence.occurrence 0)
                   , RFiringFailed (FiringFailed t1 "provider down" occurrence.occurrence 0)
                   ]

  describe "TestSelectionDurability" $ do
    it "no enabled bindings bypasses selection" $ do
      calls <- newIORef (0 :: Int)
      let spy =
            SelectionPolicy
              { propose = counting calls (\_ _ -> Left "selection must not see an empty enabled offer")
              , foldCommitted = \state _ -> Right state
              } ::
              SelectionPolicy ()
      hs <- newHandlers
      port <- inMemory
      store <- inMemoryHistoryStore
      engine <-
        Engine.create independentNet "empty-selection-test" store port
          Engine.defaultEngineOptions {Engine.handlers = handlerMap hs, Engine.selection = Engine.EngineSelection spy ()}
      (.waiting) <$> Engine.advance engine `shouldReturn` False
      readIORef calls `shouldReturn` 0

    it "round robin choice is recorded before dispatch" $ do
      port <- inMemory
      (engine, _, history) <- independentEngine port Nothing (\o -> o {Engine.selection = roundRobinOf [t1, t2]})
      (.ready) <$> Engine.advance engine `shouldReturn` True
      candidateSelections history `shouldReturn` [t1]

    it "round robin resume matches uninterrupted with an orphan selection" $ do
      turns <- newIORef (0 :: Int)
      let beginOnce snapshot = do
            n <- atomicModifyIORef' turns (\c -> (c + 1, c + 1))
            pure $
              if n == 1
                then head' [action | action@(Engine.BeginCandidate _) <- snapshot.actions]
                else Engine.Stop
      history <- inMemoryHistoryStore
      port <- inMemory
      (firstEngine, hs, _) <-
        independentEngine port (Just history) (\o -> o {Engine.policy = beginOnce, Engine.selection = roundRobinOf [t1, t2]})
      _ <- Engine.advance firstEngine
      _ <- Engine.advance firstEngine
      Engine.close firstEngine
      Store.append history (RCandidateSelected (CandidateSelected t1 999 0))
      reconstructed <- newIORef []
      port' <- inMemory
      resumed <-
        Engine.load independentNet "coordinator-test" history port'
          Engine.defaultEngineOptions
            { Engine.handlers = handlerMap hs
            , Engine.policy = capturing reconstructed
            , Engine.selection = roundRobinOf [t1, t2]
            }
      _ <- Engine.advance resumed
      beginTransitions <$> readIORef reconstructed `shouldReturn` [t2]

    it "backend owned dispatch failure leaves the durable selection for reload" $ do
      port <- raisingDispatch
      (engine, _, history) <- independentEngine port Nothing (\o -> o {Engine.selection = roundRobinOf [t1, t2]})
      Engine.advance engine `shouldThrow` errorCall "dispatch failed"
      candidateSelections history `shouldReturn` [t1]

    it "backend owned dispatch failure installs the already durable begin" $ do
      port <- raisingDispatch
      (engine, hs, history) <- independentEngine port Nothing (\o -> o {Engine.selection = roundRobinOf [t1, t2]})
      Engine.advance engine `shouldThrow` errorCall "dispatch failed"
      nextChoice <- newIORef []
      port' <- inMemory
      resumed <-
        Engine.load independentNet "coordinator-test" history port'
          Engine.defaultEngineOptions
            { Engine.handlers = handlerMap hs
            , Engine.policy = capturing nextChoice
            , Engine.selection = roundRobinOf [t1, t2]
            }
      _ <- Engine.advance resumed
      beginTransitions <$> readIORef nextChoice `shouldReturn` [t2]

    it "backend owned pure completion failure installs like replay" $ do
      let explode :: Handler
          explode _ _ = Left "RuntimeError('completion failed')"
      history <- inMemoryHistoryStore
      port <- inMemory
      engine <-
        Engine.create (activityNet (Just "explode")) "pure-failure-test" history port
          Engine.defaultEngineOptions
            { Engine.marking = markingFromList [(a, [tok "X"])]
            , Engine.handlers = symbols [("explode", PureHandler explode)]
            , Engine.selection = roundRobinOf [t]
            }
      Engine.advance engine `shouldThrow` handlerFailed "completion failed"
      candidateSelections history `shouldReturn` [t]

    it "refused append leaves no candidate selection" $ do
      (history, refused) <- refusingHistory
      port <- inMemory
      (engine, _, _) <- independentEngine port (Just history) (\o -> o {Engine.selection = roundRobinOf [t1, t2]})
      before <- Store.records history
      writeIORef refused True
      Engine.advance engine `shouldThrow` (\(e :: IOException) -> "disk full" `T.isInfixOf` T.pack (show e))
      Store.records history `shouldReturn` before

    it "other action discards proposal and engines isolate shared selection policy" $ do
      let shared = roundRobinOf [t1, t2]
      port <- inMemory
      (stopped, _, stoppedHistory) <- independentEngine port Nothing (\o -> o {Engine.policy = \_ -> pure Engine.Stop, Engine.selection = shared})
      (.waiting) <$> Engine.advance stopped `shouldReturn` False
      candidateSelections stoppedHistory `shouldReturn` []
      firstChoices <- newIORef []
      secondChoices <- newIORef []
      portA <- inMemory
      portB <- inMemory
      (firstEngine, _, _) <- independentEngine portA Nothing (\o -> o {Engine.policy = capturing firstChoices, Engine.selection = shared})
      (secondEngine, _, _) <- independentEngine portB Nothing (\o -> o {Engine.policy = capturing secondChoices, Engine.selection = shared})
      _ <- Engine.advance firstEngine
      _ <- Engine.advance secondEngine
      firstSeen <- take 1 . beginTransitions <$> readIORef firstChoices
      secondSeen <- take 1 . beginTransitions <$> readIORef secondChoices
      firstSeen <> secondSeen `shouldBe` [t1, t1]

    it "all filtered appends no history and emits decline telemetry" $ do
      history <- inMemoryHistoryStore
      port <- inMemory
      let filtered = selectionPipeline [const False] [] first :: SelectionPolicy ()
      (engine, _, _) <- independentEngine port (Just history) (\o -> o {Engine.selection = Engine.EngineSelection filtered ()})
      before <- Store.records history
      (.waiting) <$> Engine.advance engine `shouldReturn` False
      Store.records history `shouldReturn` before

    it "a steered selection proposes with the policy built from its input before each proposal" $ do
      target <- newIORef t2
      let steer wanted = selectionPipeline [\binding -> binding.transition == wanted] [] first :: SelectionPolicy ()
      port <- inMemory
      let beginning snapshot = pure (head' ([action | action@(Engine.BeginCandidate _) <- snapshot.actions] <> [Engine.Stop]))
      (engine, _, history) <-
        independentEngine port Nothing (\o -> o {Engine.policy = beginning, Engine.selection = Engine.SteeredSelection (readIORef target) steer ()})
      _ <- Engine.advance engine
      writeIORef target t1
      _ <- Engine.advance engine
      candidateSelections history `shouldReturn` [t2, t1]

    it "a completion for an occurrence never dispatched is refused loud" $ do
      let rogue = Dispatch {dispatch = \_ _ -> pure (), collect = pure [(99, Succeeded ok)], cancel = Nothing}
      (engine, _, _) <- independentEngine rogue Nothing id
      Engine.advance engine `shouldThrow` valueError "not in flight"

    it "a policy choosing an action the coordinator did not offer is refused" $ do
      port <- inMemory
      (engine, _, _) <- independentEngine port Nothing (\o -> o {Engine.policy = \_ -> pure (Engine.AdvanceTime 99)})
      Engine.advance engine `shouldThrow` valueError "did not offer"

    it "the policy observes detached views never live occurrences" $ do
      observed <- newIORef []
      let watching snapshot = do
            modifyIORef' observed (<> [snapshot])
            Engine.conservativePolicy snapshot
      port <- inMemory
      (engine, _, _) <- independentEngine port Nothing (\o -> o {Engine.policy = watching})
      _ <- advanceUntilRest engine
      withWork <- filter (not . null . (.inFlight)) <$> readIORef observed
      withWork `shouldSatisfy` (not . null)
      mapM_
        ( \snapshot -> case snapshot.inFlight of
            [view] -> view `shouldBe` Engine.InFlightView view.occurrence t1 [(a1, [tokD "X" (obj [("n", Int 1)])])] True
            other -> expectationFailure ("expected one in-flight view, got " <> show other)
        )
        withWork

  describe "TestLateCompletionsThroughCollect" $ do
    it "an identical redelivery for an ended occurrence is acknowledged and the drive continues" $ do
      (adapter, dispatched) <- scriptedAdapter [[], [(1, Succeeded (obj [("n", Int 1)]))], [(1, Succeeded (obj [("n", Int 1)]))]]
      (engine, _, history) <- independentEngine adapter Nothing id
      outcome <- advanceUntilRest engine
      map (.occurrence) outcome.firings `shouldBe` [1] -- exactly one completion committed
      records <- Store.records history
      [r.occurrence | RActivityCompleted r <- records] `shouldBe` [1] -- the redelivery appended nothing
      -- ...and the loop kept driving past the acknowledgement: t2 was
      -- begun and dispatched behind it, its own result now outstanding.
      readIORef dispatched `shouldReturn` [1, 2]
      map (.occurrence) <$> Engine.inFlight engine `shouldReturn` [2]
      outcome.waiting `shouldBe` True

    it "a different late result for an ended occurrence conflicts loud" $ do
      (adapter, _) <- scriptedAdapter [[], [(1, Succeeded (obj [("n", Int 1)]))], [(1, Succeeded (obj [("n", Int 999)]))]]
      (engine, _, _) <- independentEngine adapter Nothing id
      advanceUntilRest engine
        `shouldThrow` (\e -> valueError "different result" e && valueError "operational conflict" e)

  describe "TestConservativePolicyParity" $ do
    it "a representative net produces the same history under equivalent selection" $ do
      let prepPath = np "prep"
          staged = np "staged"
          net =
            netOf
              [place a, place staged, place b]
              [Transition prepPath (Just (HandlerSymbol "prep")) [] [Delay 5], Transition t (Just (HandlerSymbol "charge")) [] []]
              [arc a prepPath, arc prepPath staged, arc staged t, arc t b]
          prep :: Handler
          prep binding _ = case bindingTokens binding of
            token : _ -> Right (handlerTokens [(staged, [tokD "Staged" token.payload])])
            [] -> Left "IndexError('tuple index out of range')"
          marking = markingFromList [(a, [tokD "X" (obj [("amount", Int 10)])])]
          run selection = do
            bridge <- newBridge "charge_card" b
            port <- inlineOf [("charge_card", \_ _ -> pure (obj [("status", String "captured")]))]
            history <- inMemoryHistoryStore
            clock <- Engine.simulatedClock 0
            engine <-
              Engine.create net "parity" history port $
                selection
                  Engine.defaultEngineOptions
                    { Engine.marking = marking
                    , Engine.handlers = symbols [("prep", PureHandler prep), ("charge", bridge.handler)]
                    , Engine.policy = Engine.conservativePolicy
                    , Engine.clock = Just clock
                    }
            outcome <- advanceUntilRest engine
            records <- Store.records history
            pure (engine, outcome, records)
      (_, baselineOutcome, baselineRecords) <- run id
      (priorityEngine, outcome, priorityRecords) <-
        run (\o -> o {Engine.selection = Engine.EngineSelection (priority (Map.fromList [(t, 99)]) :: SelectionPolicy ()) ()})
      length priorityRecords `shouldBe` length baselineRecords
      and (zipWith exactEq (map encodeRecord priorityRecords) (map encodeRecord baselineRecords)) `shouldBe` True
      length outcome.firings `shouldBe` 2
      length baselineOutcome.firings `shouldBe` 2
      outcome.waiting `shouldBe` False
      Engine.inFlight priorityEngine `shouldReturn` []

  describe "TestSensedIngress" $ do
    let sourceNet = netOf [place a] [transition src] [arc src a]
        parcel n identity = mkDelivery src [tokD "X" (obj [("n", Int n)])] identity

    it "sensed deliveries land in fifo order at quiescence" $ do
      sensor <- scripted [[parcel 1 "evt_1", parcel 2 "evt_2"], []]
      port <- inMemory
      store <- inMemoryHistoryStore
      engine <- Engine.create sourceNet "sensed-fifo-test" store port Engine.defaultEngineOptions {Engine.sensor = Just sensor}
      outcome <- advanceUntilRest engine
      map (.transition) outcome.firings `shouldBe` [src, src]
      Engine.marking engine `shouldReturn` markingFromList [(a, [tokD "X" (obj [("n", Int 1)]), tokD "X" (obj [("n", Int 2)])])]

    it "a sensed redelivery acknowledges without a firing or an append" $ do
      sensor <- scripted [[parcel 1 "evt_1"], [parcel 1 "evt_1"], []]
      port <- inMemory
      store <- inMemoryHistoryStore
      engine <- Engine.create sourceNet "sensed-redelivery-test" store port Engine.defaultEngineOptions {Engine.sensor = Just sensor}
      outcome <- advanceUntilRest engine
      length outcome.firings `shouldBe` 1 -- the redelivery acknowledged, never fired
      Engine.marking engine `shouldReturn` markingFromList [(a, [tokD "X" (obj [("n", Int 1)])])]

    mapM_
      ( \(name, policy) ->
          it ("sensed ingress and standing internal work alternate [" <> name <> "]") $ do
            let cursor = np "cursor"
                spin = np "spin"
                net = netOf [place cursor, place a] [transition spin, transition src] [arc cursor spin, arc spin cursor, arc src a]
            sensor <- draining [[parcel 1 "evt_1"], [parcel 2 "evt_2"], [parcel 3 "evt_3"]]
            port <- inMemory
            store <- inMemoryHistoryStore
            engine <-
              Engine.create net ("sensed-alternation-" <> T.pack name) store port
                Engine.defaultEngineOptions
                  { Engine.marking = markingFromList [(cursor, [tok "Cursor"])]
                  , Engine.policy = policy
                  , Engine.sensor = Just sensor
                  }
            transitions <- concat <$> mapM (\_ -> map (.transition) . (.firings) <$> Engine.advance engine) [1 .. 5 :: Int]
            transitions `shouldBe` [src, spin, src, spin, src]
            records <- Engine.records engine
            [r.identity | RExternalEventDelivered r <- records] `shouldBe` ["evt_1", "evt_2", "evt_3"]
      )
      [("choose_conservative", Engine.conservativePolicy), ("choose_throughput", Engine.throughputPolicy)]

    it "a delivery buffered behind a source close is held not applied" $ do
      let hook :: Handler
          hook binding _ = Right (HandlerResult [(a, bindingTokens binding)] [] [DeliveryRegistration src "default"])
          net = netOf [place a] [Transition src (Just (HandlerSymbol "hook")) [] []] [arc src a]
      sensorCalls <- newIORef (0 :: Int)
      let sensor = do
            modifyIORef' sensorCalls (+ 1)
            pure [parcel 1 "evt_1", parcel 2 "evt_2"]
      port <- inMemory
      store <- inMemoryHistoryStore
      engine <-
        Engine.create net "source-close-buffer-test" store port
          Engine.defaultEngineOptions {Engine.handlers = symbols [("hook", PureHandler hook)], Engine.sensor = Just sensor}
      map (.transition) . (.firings) <$> Engine.advance engine `shouldReturn` [src]
      Engine.advance engine `shouldReturn` Engine.DriveOutcome [] False False Nothing
      readIORef sensorCalls `shouldReturn` 1
      records <- Engine.records engine
      [r.identity | RExternalEventDelivered r <- records] `shouldBe` ["evt_1"]

  describe "TestReconcileThenDrive" $ do
    it "an outstanding invocation is redispatched never re prepared" $ withScratch $ \dir -> do
      let path = dir </> "history.jsonl"
      handler <- newBridge "charge_card" b
      store <- openJsonlHistoryStore path
      inst <-
        newInstance
          (activityNet (Just "charge"))
          defaultInstanceConfig
            { initialMarking = markingFromList [(a, [tokD "X" (obj [("n", Int 1)])])]
            , handlerImplementations = symbols [("charge", handler.handler)]
            , historyStore = Just store
            , suppliedIdentity = Just "reconcile-request-test"
            }
          >>= expectRight
      original <- bindingOf inst 0 >>= \binding -> I.begin inst binding Nothing >>= expectRight
      -- the kill: the Instance is abandoned

      fresh <- newBridge "charge_card" b
      (pool, port) <- pool'
      store' <- openJsonlHistoryStore path
      resumed <-
        Engine.load (activityNet (Just "charge")) "reconcile-request-test" store' port
          Engine.defaultEngineOptions {Engine.handlers = symbols [("charge", fresh.handler)], Engine.policy = Engine.conservativePolicy}
      -- reconciles, then waits on the redispatched result
      Engine.advance resumed `shouldReturn` Engine.DriveOutcome [] True False Nothing
      originalInvocation <- maybe (expectationFailure "the original occurrence carries an invocation" >> error "unreachable") pure original.invocation
      pending pool `shouldReturn` [(original.occurrence, originalInvocation)]
      readIORef fresh.prepared `shouldReturn` 0 -- never re-run

      completeOccurrence pool original.occurrence (obj [("status", String "captured")])
      outcome <- Engine.advance resumed
      map (.occurrence) outcome.firings `shouldBe` [original.occurrence]
      outcome.waiting `shouldBe` False
      readIORef fresh.projected `shouldReturn` 1
      Engine.marking resumed `shouldReturn` markingFromList [(b, [tokD "Done" (obj [("status", String "captured")])])]
      Engine.inFlight resumed `shouldReturn` []

    it "a projection pending occurrence completes by projection alone" $ withScratch $ \dir -> do
      let path = dir </> "history.jsonl"
      handler <- newBridge "charge_card" b
      store <- openJsonlHistoryStore path
      inst <-
        newInstance
          (activityNet (Just "charge"))
          defaultInstanceConfig
            { initialMarking = markingFromList [(a, [tokD "X" (obj [("n", Int 1)])])]
            , handlerImplementations = symbols [("charge", handler.handler)]
            , historyStore = Just store
            , suppliedIdentity = Just "reconcile-projection-test"
            }
          >>= expectRight
      occurrence <- bindingOf inst 0 >>= \binding -> I.begin inst binding Nothing >>= expectRight
      _ <- recordActivityCompletion inst occurrence (obj [("status", String "captured")]) Nothing >>= expectRight
      -- the kill

      fresh <- newBridge "charge_card" b
      (pool, port) <- pool'
      store' <- openJsonlHistoryStore path
      resumed <-
        Engine.load (activityNet (Just "charge")) "reconcile-projection-test" store' port
          Engine.defaultEngineOptions {Engine.handlers = symbols [("charge", fresh.handler)], Engine.policy = Engine.conservativePolicy}
      outcome <- Engine.advance resumed
      map (.occurrence) outcome.firings `shouldBe` [occurrence.occurrence]
      pending pool `shouldReturn` [] -- never redispatched
      readIORef fresh.prepared `shouldReturn` 0
      readIORef fresh.projected `shouldReturn` 1
      records <- Engine.records resumed
      [r | r@(RActivityCompleted _) <- records]
        `shouldBe` [RActivityCompleted (ActivityCompleted t (obj [("status", String "captured")]) occurrence.occurrence 0)]
      Engine.marking resumed `shouldReturn` markingFromList [(b, [tokD "Done" (obj [("status", String "captured")])])]

    it "pure in flight is driven to terminal and the drive continues" $ withScratch $ \dir -> do
      let path = dir </> "history.jsonl"
          mid = np "mid"
          chain = netOf [place a, place mid, place b] [transition t, transition t2] [arc a t, arc t mid, arc mid t2, arc t2 b]
          token = tok "X"
      store <- openJsonlHistoryStore path
      inst <-
        newInstance chain defaultInstanceConfig {initialMarking = markingFromList [(a, [token])], historyStore = Just store, suppliedIdentity = Just "reconcile-pure-test"}
          >>= expectRight
      occurrence <- bindingOf inst 0 >>= \binding -> I.begin inst binding Nothing >>= expectRight
      -- the kill

      store' <- openJsonlHistoryStore path
      port <- inMemory
      resumed <- Engine.load chain "reconcile-pure-test" store' port Engine.defaultEngineOptions {Engine.policy = Engine.conservativePolicy}
      outcome <- Engine.advance resumed
      take 1 (map (.occurrence) outcome.firings) `shouldBe` [occurrence.occurrence] -- reconciled first
      length outcome.firings `shouldBe` 2 -- then t2 fired behind it
      Engine.marking resumed `shouldReturn` markingFromList [(b, [token])]
      Engine.inFlight resumed `shouldReturn` []
  where
    head' = \case
      x : _ -> x
      [] -> error "no BeginCandidate offered"
