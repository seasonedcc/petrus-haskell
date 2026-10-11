-- | Port of upstream @tests/petrus/engine/test_execution.py@ outside
-- @TestIdentifiedDeliveryPhases@: the simulated clock, the Engine driving
-- the firing-occurrence seam, timers, terminal failure, delivery parcels,
-- and sensed ingress.
--
-- Upstream tests whose subject is a Python-only runtime property (``str``/
-- ``int`` subclasses, ``__deepcopy__`` hooks, attribute interception, a
-- ``None`` or non-'Delivery' sensor answer, tuple-vs-list xToken data) are
-- ruled out by the Haskell types; they are listed with their reason in the
-- package's PARITY.md rather than spelled as examples here.
module Petrus.Engine.ExecutionSpec (spec) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocation (..), invocation)
import Petrus.Engine qualified as Engine
import Petrus.Engine.TestSupport
import Petrus.Impetus.Binding
import Petrus.Impetus.History.Records
import Petrus.Impetus.HistoryStore (HistoryStore, inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance (AcceptedDelivery (..), DeliveryAnswer (..), DeliveryScope (..), FiringOutcome (..), Status (..), deliveryIdentityText, firingOccurrenceIdInt)
import Petrus.Impetus.Petrinet hiding (token)
import Petrus.Impetus.TestSupport (mustNet, netOf, np, tok, tokD)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (Dispatch (..))
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Test.Hspec

a, b, c, t, src :: NetPath
a = np "a"
b = np "b"
c = np "c"
t = np "t"
src = np "src"

-- | @_line_net(handler)@: a -> t -> b.
lineNet :: Maybe Text -> Net
lineNet handler = netOf [place a, place b] [Transition t (HandlerSymbol <$> handler) [] []] [arc a t, arc t b]

-- | @_expiry_net(*timers)@.
expiryNet :: [Timer] -> Net
expiryNet timers = netOf [place a, place b] [Transition t Nothing [] timers] [arc a t, arc t b]

-- | @_ingress_net()@: src -> a -> t -> b.
ingressNet :: Net
ingressNet = netOf [place a, place b] [transition src, transition t] [arc src a, arc a t, arc t b]

memory :: IO Dispatch
memory = inMemoryDispatch <$> newInMemoryDispatch

opts :: Engine.EngineOptions
opts = Engine.defaultEngineOptions

-- | @Engine.create(net, identity, history=history, dispatch=InMemoryDispatch(), ...)@.
createIn :: Net -> Text -> HistoryStore -> Engine.EngineOptions -> IO Engine.Engine
createIn net identity history options = do
  port <- memory
  Engine.create net identity history port options

-- | Same, over a fresh in-memory History.
createFresh :: Net -> Text -> Engine.EngineOptions -> IO Engine.Engine
createFresh net identity options = do
  history <- inMemoryHistoryStore
  createIn net identity history options

-- | The reference's @re.search@ over a @.*@-joined pattern: the fragments
-- occur in order.
inOrder :: [Text] -> Text -> Bool
inOrder [] _ = True
inOrder (fragment : rest) message = case T.breakOn fragment message of
  (_, found)
    | T.null found -> False
    | otherwise -> inOrder rest (T.drop (T.length fragment) found)

transitions :: Engine.DriveOutcome -> [NetPath]
transitions outcome = [firing.transition | firing <- outcome.firings]

occurrences :: Engine.DriveOutcome -> [Int]
occurrences outcome = [firing.occurrence | firing <- outcome.firings]

delivered :: [Record] -> [ExternalEventDelivered]
delivered recorded = [event | RExternalEventDelivered event <- recorded]

spec :: Spec
spec = do
  describe "TestSimulatedClock" $ do
    it "now starts at the construction instant" $ do
      zero <- Engine.simulatedClock 0
      zero.now `shouldReturn` 0
      seven <- Engine.simulatedClock 7
      seven.now `shouldReturn` 7

    it "observe jumps without rewinding" $ do
      clock <- Engine.simulatedClock 7
      clock.observe 10 `shouldReturn` Just 10
      clock.observe 4 `shouldReturn` Just 10
      clock.now `shouldReturn` 10

  describe "TestEngineDrivesTheSeam" $ do
    it "typed place rejects an incompatible initial token before history is written" $ do
      history <- inMemoryHistoryStore
      createIn (netOf [coloredPlace a "Expected"] [] []) "invalid-initial-marking" history
        opts {Engine.marking = markingFromList [(a, [tok "Other"])]}
        `shouldThrow` \case
          Engine.EngineValueError m -> inOrder ["initial marking", "place a", "Expected", "Other"] m
          _ -> False
      Store.size history `shouldReturn` 0

    it "pumping one action turns drives a pure chain to quiescence" $ do
      let xToken = tok "X"
          step = np "step"
          net = netOf [place a, place b, place c] [transition t, transition step] [arc a t, arc t b, arc b step, arc step c]
      engine <- createFresh net "pure-chain" opts {Engine.marking = markingFromList [(a, [xToken])]}
      outcome <- advanceUntilRest engine
      transitions outcome `shouldBe` [t, step]
      occurrences outcome `shouldBe` [1, 2]
      Engine.marking engine `shouldReturn` markingFromList [(c, [xToken])]
      Engine.status engine `shouldReturn` Terminated

    it "an activity invocation executes through inline dispatch" $ do
      consulted <- newIORef []
      let charge =
            ActivityHandler
              { prepare = \_ -> Right (invocation "charge" (Object [("n", Int 1)]))
              , project = \_ result -> Right (handlerTokens [(b, [tokD "X" result])])
              , projectFailure = Nothing
              }
      port <- inlineOf [("charge", \inv _ -> modifyIORef' consulted (<> [inv]) >> pure (Object [("ok", Bool True)]))]
      history <- inMemoryHistoryStore
      engine <-
        Engine.create (lineNet (Just "price")) "activity" history port
          opts {Engine.marking = markingFromList [(a, [tok "X"])], Engine.handlers = symbols [("price", ActivityBound charge)]}
      _ <- advanceUntilRest engine
      seen <- readIORef consulted
      case seen of
        [first] ->
          first
            `shouldBe` ActivityInvocation "charge" (Object [("n", Int 1)]) first.policy (Just "occurrence-1") (Just "occurrence-1")
        other -> expectationFailure ("expected one invocation, got " <> show other)
      recorded <- Store.records history
      [() | RActivityCompleted _ <- recorded] `shouldSatisfy` (not . null)
      Engine.marking engine `shouldReturn` markingFromList [(b, [tokD "X" (Object [("ok", Bool True)])])]

    it "a pure projection never touches dispatch" $ do
      inner <- memory
      let forbidden = inner {dispatch = \_ _ -> throwIO (ErrorCall "a pure projection reached Dispatch")}
          price _ _ = Right (handlerTokens [(b, [tok "X"])])
      history <- inMemoryHistoryStore
      engine <-
        Engine.create (lineNet (Just "price")) "pure-projection" history forbidden
          opts {Engine.marking = markingFromList [(a, [tok "X"])], Engine.handlers = symbols [("price", PureHandler price)]}
      _ <- advanceUntilRest engine
      Engine.marking engine `shouldReturn` markingFromList [(b, [tok "X"])]

    it "firing records are stamped from the engine clock" $ do
      clock <- Engine.simulatedClock 5
      engine <- createFresh (lineNet Nothing) "clock-stamp" opts {Engine.marking = markingFromList [(a, [tok "X"])], Engine.clock = Just clock}
      outcome <- advanceUntilRest engine
      case outcome.firings of
        [firing] -> map recordInstant firing.records `shouldSatisfy` all (== 5)
        other -> expectationFailure ("expected one firing, got " <> show other)

  describe "TestEngineObservesTimers" $ do
    it "simulated time matures and fires" $ do
      let xToken = tok "X"
      engine <- createFresh (expiryNet [Delay 10]) "timer" opts {Engine.marking = markingFromList [(a, [xToken])]}
      outcome <- advanceUntilRest engine
      transitions outcome `shouldBe` [t]
      Engine.records engine >>= (`shouldContain` [RTimerMatured (TimerMatured 10 10)])
      Engine.marking engine `shouldReturn` markingFromList [(b, [xToken])]

    it "repeated delays anchor on each production" $ do
      let second = np "second"
          net =
            netOf
              [place a, place b, place c]
              [Transition t Nothing [] [Delay 5], Transition second Nothing [] [Delay 5]]
              [arc a t, arc t b, arc b second, arc second c]
      engine <- createFresh net "repeated-timers" opts {Engine.marking = markingFromList [(a, [tok "X"])]}
      _ <- advanceUntilRest engine
      recorded <- Engine.records engine
      [matured | RTimerMatured matured <- recorded] `shouldBe` [TimerMatured 5 5, TimerMatured 10 10]

    it "until matures at its declared instant" $ do
      engine <- createFresh (expiryNet [Until 100]) "until" opts {Engine.marking = markingFromList [(a, [tok "X"])]}
      _ <- advanceUntilRest engine
      Engine.records engine >>= (`shouldContain` [RTimerMatured (TimerMatured 100 100)])

    it "a late observation is harmless and an early one fails loud" $ do
      let adjusted adjustment = do
            at <- newIORef 0
            pure
              Engine.Clock
                { Engine.now = readIORef at
                , Engine.observe = \instant -> do
                    writeIORef at (instant + adjustment)
                    Just <$> readIORef at
                }
      lateClock <- adjusted 3
      late <- createFresh (expiryNet [Delay 10]) "late" opts {Engine.marking = markingFromList [(a, [tok "X"])], Engine.clock = Just lateClock}
      _ <- advanceUntilRest late
      Engine.records late >>= (`shouldContain` [RTimerMatured (TimerMatured 10 13)])

      earlyClock <- adjusted (-1)
      early <- createFresh (expiryNet [Delay 10]) "early" opts {Engine.marking = markingFromList [(a, [tok "X"])], Engine.clock = Just earlyClock}
      Engine.advance early `shouldThrow` valueError "observed 9, before the requested maturation 10"

  describe "TestTerminalFailure" $
    it "a raising pure handler records failure and poisons the engine" $ do
      let explode _ _ = Left "RuntimeError('quote service down')"
      history <- inMemoryHistoryStore
      engine <-
        createIn (lineNet (Just "price")) "failure" history
          opts {Engine.marking = markingFromList [(a, [tok "X", tok "X"])], Engine.handlers = symbols [("price", PureHandler explode)]}
      Engine.advance engine `shouldThrow` handlerFailed "quote service down"
      recorded <- Store.records history
      case reverse recorded of
        RFiringFailed failed : _ -> failed.error `shouldSatisfy` T.isInfixOf "quote service down"
        other -> expectationFailure ("expected a trailing FiringFailed, got " <> show (take 1 other))
      Engine.advance engine `shouldThrow` runtimeError "poisoned"

  describe "TestDelivery" $ do
    it "normalizes source tokens and identity" $ do
      let xToken = tok "X"
      case Engine.delivery (np "src") [xToken] "evt-9" Nothing of
        Right parcel -> do
          parcel.source `shouldBe` src
          parcel.tokens `shouldBe` [xToken]
          parcel.identity `shouldBe` "evt-9"
        Left err -> expectationFailure (T.unpack err)

    it "requires a stable identity at parcel construction" $
      -- The missing-argument TypeError is ruled out by the constructor's
      -- arity; the empty identity is the refused value.
      Engine.delivery src [tok "X"] "" Nothing
        `shouldBe` Left "delivery identity must be a non-empty string of the exact built-in type, got ''"

    describe "requires a valid scope name at parcel construction" $
      mapM_
        ( \name ->
            it (show name) $
              Engine.delivery src [tok "X"] "event-1" (Just (ScopeName name))
                `shouldBe` Left "delivery scope name must be non-empty and contain no NUL"
        )
        ["", "invalid\NULscope"]

    it "rejects a string payload and snapshots a sequence" $
      -- A string payload is a type error in Haskell; the sequence half
      -- carries over.
      ((.tokens) <$> Engine.delivery src [tok "X", tok "Y"] "xToken-event" Nothing) `shouldBe` Right [tok "X", tok "Y"]

  describe "TestEngineSenses" $ do
    it "sensed delivery interleaves with internal work" $ do
      let xToken = tok "X"
      sensor <- scripted [[mkDelivery src [xToken] "sensed-event"], [], []]
      engine <- createFresh ingressNet "sensed" opts {Engine.sensor = Just sensor}
      outcome <- advanceUntilRest engine
      transitions outcome `shouldBe` [src, t]
      Engine.marking engine `shouldReturn` markingFromList [(b, [xToken])]

    it "sensed redelivery is acknowledged once" $ do
      let redelivered = mkDelivery src [tok "X"] "evt-9"
      sensor <- scripted [[redelivered], [redelivered], []]
      engine <- createFresh ingressNet "redelivery" opts {Engine.sensor = Just sensor}
      _ <- advanceUntilRest engine
      recorded <- Engine.records engine
      [event.identity | event <- delivered recorded] `shouldBe` ["evt-9"]

    it "selecting a later equal delivery does not drop an earlier content conflict" $ do
      let selectSecond snapshot = pure $ case [action | action@(Engine.AcceptDelivery _) <- snapshot.actions] of
            deliveries@(_ : _) -> deliveries !! min 1 (length deliveries - 1)
            [] -> last snapshot.actions
      sensor <-
        scripted
          [ [ mkDelivery src [tokD "X" (Bool True)] "event-7"
            , mkDelivery src [tokD "X" (Int 1)] "event-7"
            ]
          ]
      history <- inMemoryHistoryStore
      engine <-
        createIn (netOf [place a] [transition src] [arc src a]) "equal-sensor-collision" history
          opts {Engine.policy = selectSecond, Engine.sensor = Just sensor}
      _ <- Engine.advance engine
      accepted <- Store.records history
      Engine.advance engine `shouldThrow` \case
        Engine.EngineValueError m -> inOrder ["delivery identity conflict for 'event-7'", "content differs"] m
        _ -> False
      recorded <- Store.records history
      case delivered recorded of
        [event] -> case event.tokens of
          [xToken] -> case xToken.payload of
            Int 1 -> pure ()
            other -> expectationFailure ("expected integer data, got " <> show other)
          other -> expectationFailure ("expected one xToken, got " <> show other)
        other -> expectationFailure ("expected one delivery, got " <> show other)
      recorded `shouldBe` accepted

    it "sensor can redeliver the identity returned by a prior acceptance" $ do
      let xToken = tok "X"
      history <- inMemoryHistoryStore
      first <- createIn ingressNet "returned-sensor-identity" history opts
      answer <- Engine.acceptDelivery first src [xToken] "event-7" Nothing
      accepted <- case answer of
        DeliveryAccepted carrier -> pure carrier
        other -> expectationFailure ("expected an acceptance, got " <> show other) >> error "unreachable"
      Engine.close first
      sensor <- scripted [[mkDelivery src [xToken] (deliveryIdentityText accepted.identity)], [], []]
      port <- memory
      resumed <- Engine.load ingressNet "returned-sensor-identity" history port opts {Engine.sensor = Just sensor}
      outcome <- advanceUntilRest resumed
      occurrences outcome `shouldBe` [firingOccurrenceIdInt accepted.occurrence, 2]
      recorded <- Store.records history
      [event.identity | event <- delivered recorded] `shouldBe` ["event-7"]

    it "sensor decline returns control and a sealed engine never consults" $ do
      declining <- scripted [[]]
      awaiting <- createFresh ingressNet "awaiting" opts {Engine.sensor = Just declining}
      ((.firings) <$> advanceUntilRest awaiting) `shouldReturn` []
      Engine.status awaiting `shouldReturn` Awaiting

      let never = throwIO (ErrorCall "consulted with nothing armed")
      sealed <- createFresh ingressNet "sealed" opts {Engine.sensor = Just never}
      Engine.seal sealed src
      ((.firings) <$> advanceUntilRest sealed) `shouldReturn` []
      Engine.status sealed `shouldReturn` Terminated

    it "completed status does not disable an armed sensor" $ do
      let xToken = tok "X"
          expression = either (error . T.unpack) id (cel "size(a) != 0")
          net = mustNet (NetSpec [place a] [transition src] [arc src a] (Just (CompletionCel expression)) Nothing)
          nonEmpty marking' = Right (not (null [() | (p, ts) <- markingToList marking', p == a, _ <- ts]))
          compilers = noCelCompilers {compileCompletion = \_ _ -> Right nonEmpty}
      statuses <- newIORef []
      hosted <- newIORef Nothing
      let sensor = do
            current <- readIORef hosted >>= maybe (throwIO (ErrorCall "sensor consulted before the Engine exists")) Engine.status
            modifyIORef' statuses (<> [current])
            seen <- length <$> readIORef statuses
            pure [mkDelivery src [xToken] "completed-event" | seen == 1]
      engine <- createFresh net "completed-sensor" opts {Engine.sensor = Just sensor, Engine.celCompilers = compilers}
      writeIORef hosted (Just engine)
      _ <- advanceUntilRest engine
      readIORef statuses `shouldReturn` [Awaiting, Completed]
      Engine.status engine `shouldReturn` Completed

    it "available ingress interrupts a pending timer once" $ do
      clock <- Engine.simulatedClock 0
      let net = netOf [place a, place b] [transition src, Transition t Nothing [] [Delay 10]] [arc src a, arc a t, arc t b]
      sensor <- scripted [[mkDelivery src [tok "X"] "evt-1"], []]
      engine <-
        createFresh net "timer-ingress"
          opts {Engine.marking = markingFromList [(a, [tok "X"])], Engine.clock = Just clock, Engine.sensor = Just sensor}
      first <- Engine.advance engine
      clock.now `shouldReturn` 0
      second <- Engine.advance engine
      transitions first `shouldBe` [src]
      second.ready `shouldBe` True
      clock.now `shouldReturn` 10

    it "sensed delivery is stamped from the clock and matches direct delivery" $ do
      let xToken = tok "X"
      sensedHistory <- inMemoryHistoryStore
      sensedClock <- Engine.simulatedClock 5
      sensor <- scripted [[mkDelivery src [xToken] "parity-event"], [], []]
      sensed <- createIn ingressNet "parity-sensed" sensedHistory opts {Engine.clock = Just sensedClock, Engine.sensor = Just sensor, Engine.at = 5}
      _ <- advanceUntilRest sensed

      manualHistory <- inMemoryHistoryStore
      manualClock <- Engine.simulatedClock 5
      manual <- createIn ingressNet "parity-sensed" manualHistory opts {Engine.clock = Just manualClock, Engine.at = 5}
      _ <- Engine.deliver manual src [xToken] "parity-event" Nothing
      _ <- advanceUntilRest manual

      sensedRecords <- Store.records sensedHistory
      Store.records manualHistory `shouldReturn` sensedRecords
      recorded <- Engine.records sensed
      [event.instant | event <- delivered recorded] `shouldBe` [5]

    it "source projection runs inline and a failure poisons" $ do
      let explode _ _ = Left "RuntimeError('bad event')"
      sensor <- scripted [[mkDelivery src [tok "X"] "failing-event"]]
      history <- inMemoryHistoryStore
      engine <-
        createIn (netOf [place a] [Transition src (Just (HandlerSymbol "ingest")) [] []] [arc src a]) "bad-source" history
          opts {Engine.handlers = symbols [("ingest", PureHandler explode)], Engine.sensor = Just sensor}
      Engine.advance engine `shouldThrow` handlerFailed "bad event"
      recorded <- Store.records history
      case reverse recorded of
        RFiringFailed _ : _ -> pure ()
        other -> expectationFailure ("expected a trailing FiringFailed, got " <> show (take 1 other))

  describe "TestEngineRefusesABrokenSensor" $ do
    it "a generator answer is snapshotted" $ do
      let xToken = tok "X"
      rounds <- newIORef []
      let sensor = do
            n <- length <$> readIORef rounds
            modifyIORef' rounds (<> [n])
            pure [mkDelivery src [xToken] "generator-event" | n == 0]
      engine <- createFresh ingressNet "generator-sensor" opts {Engine.sensor = Just sensor}
      outcome <- advanceUntilRest engine
      transitions outcome `shouldBe` [src, t]
      readIORef rounds `shouldReturn` [0, 1, 2 :: Int]

    it "a raising sensor appends nothing and poisons" $ do
      history <- inMemoryHistoryStore
      engine <- createIn ingressNet "raising-sensor" history opts {Engine.sensor = Just (throwIO (ErrorCall "sensor exploded"))}
      initial <- Store.records history
      Engine.advance engine `shouldThrow` errorCall "sensor exploded"
      Store.records history `shouldReturn` initial
      Engine.advance engine `shouldThrow` runtimeError "poisoned"
