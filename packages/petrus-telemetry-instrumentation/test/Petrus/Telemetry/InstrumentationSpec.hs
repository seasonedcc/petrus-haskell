{-# LANGUAGE ScopedTypeVariables #-}

-- | Parity: @tests/petrus/telemetry/test_telemetry_instrumentation.py@ — the
-- ES-020 instrumentation the kernel doors, the Engine's driving loop, and
-- the JSONL store emit, observed through 'capture'. One @it@ per upstream
-- test, named after it, in upstream order, followed by Haskell-specific
-- checks.
--
-- The layering rule under test: the kernel emits one event per committed
-- fact batch, after the append, stamped with the record's virtual instant;
-- wall-clock spans appear only in the driving runtime and the backends.
--
-- __What changes in translation.__ The upstream @RuntimeError@ raised by a
-- handler is the handler's 'Left' text in the reference's recorded spelling
-- (@RuntimeError('handler broke')@), so @firing_failed.error@ is
-- comparable verbatim. The Engine rethrows it as an 'Engine.EngineError',
-- so a halted drive's @error_type@ is @EngineError@, not @RuntimeError@
-- (petrus-telemetry/DIVERGENCES.md, 15).
module Petrus.Telemetry.InstrumentationSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, void)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Engine qualified as Engine
import Petrus.Engine.TestSupport (handlerFailed, symbols)
import Petrus.HistoryStore.Jsonl (openJsonlHistoryStore)
import Petrus.HistoryStore.Support (withScratch)
import Petrus.Impetus.Binding (BoundHandler (..))
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet (Marking, Net, black, markingFromList)
import Petrus.Impetus.Selection (SelectionPolicy, first, selectionPipeline)
import Petrus.Json (Json (..), exactEq)
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.Telemetry
import Petrus.Telemetry.Scenarios
import System.FilePath ((</>))
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Fixtures

-- | @Marking({NetPath("a"): (Token("X"),)})@.
aX :: Marking
aX = markingFromList [(p "a", [x])]

-- | The reference's @_engine@: an Engine over an in-memory History and an
-- InMemoryDispatch.
engineOf :: Net -> Text -> Marking -> [(Text, BoundHandler)] -> IO Engine.Engine
engineOf net identity m handlers' = do
  port <- inMemoryDispatch <$> newInMemoryDispatch
  newEngine net identity Nothing port (\o -> o {Engine.marking = m, Engine.handlers = symbols handlers'})

-- | @[payload for payload in recorder if payload["event"] == name]@.
named :: Text -> [Payload] -> [Payload]
named name = filter ((== Just (String name)) . lookup "event")

-- | @events[0]@.
firstOf :: [Payload] -> Payload
firstOf = \case
  e : _ -> e
  [] -> error "no events were emitted"

eventNames :: [Payload] -> [Text]
eventNames = map $ \payload -> case lookup "event" payload of
  Just (String name) -> name
  other -> error ("an event without a name: " <> show other)

field :: Text -> Payload -> Json
field key payload = maybe (error ("missing field " <> T.unpack key <> " in " <> show payload)) id (lookup key payload)

int :: Text -> Payload -> Integer
int key payload = case field key payload of
  Int n -> n
  other -> error (T.unpack key <> " is not an int: " <> show other)

-- | Exact payload equality: keys in order, values with Python's type
-- distinctions (the reference's dict @==@ is order-blind; this is stricter).
shouldBePayloads :: HasCallStack => [Payload] -> [Payload] -> Expectation
shouldBePayloads actual expected =
  if length actual == length expected && and (zipWith (\a b -> exactEq (Object a) (Object b)) actual expected)
    then pure ()
    else expectationFailure ("expected " <> show expected <> "\n but got " <> show actual)

captured :: IO a -> IO [Payload]
captured action = capture Nothing Nothing $ \recorder -> action >> recorded recorder

capturedAt :: Level -> IO a -> IO [Payload]
capturedAt lvl action = capture Nothing (Just lvl) $ \recorder -> action >> recorded recorder

newInst :: Net -> InstanceConfig -> IO Instance
newInst net cfg = okI (newInstance net cfg)

withIdentity :: Text -> Marking -> InstanceConfig
withIdentity identity m = defaultInstanceConfig {initialMarking = m, suppliedIdentity = Just identity}

-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "TestKernelDoorEvents" $ do
    it "test_construction_emits_instance_created" $ do
      events <- captured (newInst forkNet (withIdentity "i-1" aX) {constructionInstant = 5})
      -- records=2: the identity fact plus the one marked place.
      events
        `shouldBePayloads` [ [ ("event", String "impetus_instance_created")
                             , ("instance", String "i-1")
                             , ("places", Int 3)
                             , ("transitions", Int 1)
                             , ("records", Int 2)
                             , ("instant", Int 5)
                             ]
                           ]

    it "test_step_emits_begun_then_completed_correlated_by_occurrence" $ do
      inst <- newInst forkNet (withIdentity "i-1" aX)
      events <- captured (okI (step inst (Just 7)))
      case events of
        [begun, completed] -> do
          [begun]
            `shouldBePayloads` [ [ ("event", String "impetus_firing_begun")
                                 , ("instance", String "i-1")
                                 , ("transition", String "t")
                                 , ("occurrence", Int 1)
                                 , ("instant", Int 7)
                                 , ("impure", Bool False)
                                 ]
                               ]
          field "event" completed `shouldBe` String "impetus_firing_completed"
          field "transition" completed `shouldBe` String "t"
          int "occurrence" completed `shouldBe` 1
          int "instant" completed `shouldBe` 7
          int "records" completed `shouldSatisfy` (> 0)
        other -> expectationFailure ("expected two events, got " <> show other)

    -- The kernel's telemetry mirrors its append rule: a fruitless probe
    -- appends nothing and is not a fact — so it emits nothing either.
    it "test_a_fruitless_step_emits_nothing" $ do
      inst <- newInst forkNet defaultInstanceConfig
      events <- captured $ do
        outcome <- okI (step inst Nothing)
        isNothing outcome `shouldBe` True
      events `shouldBe` []

    it "test_a_raising_handler_emits_firing_failed" $ do
      inst <-
        newInst
          (handledNet "boom")
          defaultInstanceConfig
            { initialMarking = markingFromList [(p "a", [black])]
            , handlerImplementations = symbols [("boom", PureHandler boom)]
            }
      events <- captured $ do
        outcome <- step inst Nothing
        case outcome of
          Left (HandlerRaised message) -> message `shouldSatisfy` T.isInfixOf "handler broke"
          other -> expectationFailure ("expected the handler to raise, got " <> show other)
      eventNames events `shouldBe` ["impetus_firing_begun", "impetus_firing_failed"]
      let failed = events !! 1
      field "transition" failed `shouldBe` String "t"
      int "occurrence" failed `shouldBe` 1
      case field "error" failed of
        String message -> message `shouldSatisfy` T.isInfixOf "RuntimeError"
        other -> expectationFailure ("error is not a string: " <> show other)

    it "test_acceptance_and_completion_emit_the_delivery_lifecycle_and_redelivery_answer" $ do
      inst <- newInst sourceNet (withIdentity "i-1" mempty')
      events <- captured $ do
        accepted <- acceptedOf =<< okI (acceptDelivery inst (p "s") [x] "evt-1" Nothing Nothing)
        void (okI (completeDelivery inst accepted Nothing))
        void (okI (acceptDelivery inst (p "s") [x] "evt-1" Nothing Nothing))
      eventNames events
        `shouldBe` [ "impetus_firing_begun"
                   , "impetus_delivery_accepted"
                   , "impetus_firing_completed"
                   , "impetus_delivery_redelivered"
                   ]
      [events !! 1]
        `shouldBePayloads` [ [ ("event", String "impetus_delivery_accepted")
                             , ("instance", String "i-1")
                             , ("source", String "s")
                             , ("identity", String "evt-1")
                             , ("occurrence", Int 1)
                             , ("tokens", Int 1)
                             ]
                           ]
      [events !! 3]
        `shouldBePayloads` [ [ ("event", String "impetus_delivery_redelivered")
                             , ("instance", String "i-1")
                             , ("source", String "s")
                             , ("identity", String "evt-1")
                             , ("occurrence", Int 1)
                             ]
                           ]

    it "test_the_supplied_identity_is_spelled_on_the_acceptance" $ do
      inst <- newInst sourceNet defaultInstanceConfig
      events <- captured $ do
        accepted <- acceptedOf =<< okI (acceptDelivery inst (p "s") [x] "telemetry-event" Nothing Nothing)
        void (okI (completeDelivery inst accepted Nothing))
      case named "impetus_delivery_accepted" events of
        [accepted] -> field "identity" accepted `shouldBe` String "telemetry-event"
        other -> expectationFailure ("expected one acceptance, got " <> show other)

    it "test_seal_emits_the_closed_count" $ do
      inst <- newInst sourceNet (withIdentity "i-1" mempty')
      events <- captured (okI (seal inst (p "s") (Just 3)))
      events
        `shouldBePayloads` [ [ ("event", String "impetus_registrations_sealed")
                             , ("instance", String "i-1")
                             , ("source", String "s")
                             , ("closed", Int 1)
                             , ("instant", Int 3)
                             ]
                           ]

    it "test_wake_emits_only_when_a_maturation_derives" $ do
      inst <- newInst timerNet (withIdentity "i-1" (markingFromList [(p "a", [black])]))
      events <- captured $ do
        early <- okI (wake inst 5) -- early: suppressed, no fact, no event
        isNothing early `shouldBe` True
        void (okI (wake inst 10))
      events
        `shouldBePayloads` [ [ ("event", String "impetus_timer_matured")
                             , ("instance", String "i-1")
                             , ("maturation", Int 10)
                             , ("instant", Int 10)
                             ]
                           ]

    it "test_resume_emits_instance_resumed_under_the_recorded_identity" $ do
      inst <- newInst forkNet (withIdentity "i-1" aX)
      void (okI (run inst))
      size <- Store.size (instanceHistory inst)
      events <- captured (okI (resume forkNet (instanceHistory inst) defaultInstanceConfig))
      events
        `shouldBePayloads` [ [ ("event", String "impetus_instance_resumed")
                             , ("instance", String "i-1")
                             , ("records", Int (toInteger size))
                             , ("watermark", Int 0)
                             , ("in_flight", Int 0)
                             ]
                           ]

  describe "TestJsonlCommitEvents" $
    it "test_every_durable_commit_emits_batch_size_bytes_and_latency" $ withScratch $ \dir -> do
      events <- captured $ do
        store <- openJsonlHistoryStore (dir </> "history.jsonl")
        inst <- newInst forkNet defaultInstanceConfig {initialMarking = aX, historyStore = Just store}
        okI (run inst)
      let commits = named "impetus_jsonl_commit" events
      -- every append batch crosses the durable seam and emits
      commits `shouldSatisfy` (not . null)
      forM_ commits $ \commit -> do
        int "records" commit `shouldSatisfy` (> 0)
        int "bytes" commit `shouldSatisfy` (> 0)
        int "elapsed_ms" commit `shouldSatisfy` (>= 0)

  describe "TestEngineSpan" $ do
    it "test_advance_is_a_span_whose_counters_summarize_the_turn" $ do
      engine <- engineOf forkNet "span" aX []
      (events, outcome) <- capture Nothing Nothing $ \recorder -> do
        outcome <- Engine.advance engine
        (,outcome) <$> recorded recorder
      field "event" (firstOf events) `shouldBe` String "impetus_drive_started"
      let finished = last events
      field "event" finished `shouldBe` String "impetus_drive_finished"
      field "status" finished `shouldBe` String "success"
      int "firings" finished `shouldBe` toInteger (length outcome.firings)
      length outcome.firings `shouldBe` 1
      int "elapsed_ms" finished `shouldSatisfy` (>= 0)
      -- Between the span's edges: the kernel doors' own per-fact events.
      eventNames (init (drop 1 events)) `shouldBe` ["impetus_firing_begun", "impetus_firing_completed"]

    -- Adapted: error_type is the Haskell exception's type, EngineError.
    it "test_a_halting_advance_finishes_the_span_failed" $ do
      engine <- engineOf (handledNet "boom") "failed-span" (markingFromList [(p "a", [black])]) [("boom", PureHandler boom)]
      events <- captured (Engine.advance engine `shouldThrow` handlerFailed "handler broke")
      let finished = last events
      field "event" finished `shouldBe` String "impetus_drive_finished"
      field "status" finished `shouldBe` String "failed"
      field "error_type" finished `shouldBe` String "EngineError"

  describe "TestInstanceIdentity" $ do
    -- Identity is always on: an instance with no supplied id mints one, and
    -- every event it emits is discriminable by it.
    it "test_every_door_event_carries_the_minted_identity" $ do
      inst <- newInst forkNet defaultInstanceConfig {initialMarking = aX}
      events <- captured (okI (step inst Nothing))
      events `shouldSatisfy` (not . null)
      forM_ events $ \payload -> field "instance" payload `shouldBe` String (instanceIdentity inst)

    it "test_two_instances_mint_distinct_identities" $ do
      firstOne <- newInst forkNet defaultInstanceConfig
      second <- newInst forkNet defaultInstanceConfig
      instanceIdentity firstOne `shouldNotBe` instanceIdentity second

    it "test_the_driver_span_carries_the_instance_identity" $ do
      engine <- engineOf forkNet "order-7" aX []
      events <- captured (Engine.advance engine)
      events `shouldSatisfy` (not . null)
      forM_ events $ \payload -> field "instance" payload `shouldBe` String "order-7"

    it "test_a_named_net_stamps_the_kind_beside_the_identity" $ do
      engine <- engineOf (namedForkNet (Just "order-fulfillment")) "order-7" aX []
      events <- captured (Engine.advance engine)
      events `shouldSatisfy` (not . null)
      forM_ events $ \payload -> do
        field "net" payload `shouldBe` String "order-fulfillment"
        field "instance" payload `shouldBe` String "order-7"

    it "test_resume_speaks_the_recorded_identity_not_a_resupplied_one" $ do
      inst <- newInst forkNet (withIdentity "order-7" aX)
      resumed <- okI (resume forkNet (instanceHistory inst) defaultInstanceConfig)
      events <- captured (okI (step resumed Nothing))
      instanceIdentity resumed `shouldBe` "order-7"
      events `shouldSatisfy` (not . null)
      forM_ events $ \payload -> field "instance" payload `shouldBe` String "order-7"

    it "test_a_trace_without_identity_refuses_before_emitting_resume" $ do
      inst <- newInst forkNet defaultInstanceConfig {initialMarking = aX}
      malformed <- inMemoryHistoryStore
      recorded' <- Store.records (instanceHistory inst)
      malformed.extend (drop 1 recorded')
      events <- captured $ do
        outcome <- resume forkNet malformed defaultInstanceConfig
        case outcome of
          Left (Refused message) -> message `shouldSatisfy` T.isInfixOf "construction batch requires InstanceCreated"
          Left other -> expectationFailure ("expected a ValueError-like refusal, got " <> show other)
          Right _ -> expectationFailure "expected the resume to refuse"
      events `shouldBe` []

  describe "TestPhaseTimings" $
    -- The kernel is timed FROM its Engine: wall time stays outside the
    -- semantic writer and the one-action turn reports each owned phase.
    it "test_drive_finished_breaks_the_loop_down_by_phase" $ do
      engine <- engineOf forkNet "phase" aX []
      events <- captured (Engine.advance engine)
      let finished = last events
      field "event" finished `shouldBe` String "impetus_drive_finished"
      forM_ ["observe_ms", "apply_ms", "begin_ms", "handler_ms", "commit_ms"] $ \phase ->
        int phase finished `shouldSatisfy` (>= 0)

  describe "TestGauges" $ do
    it "test_profile_level_emits_state_gauges_each_firing" $ do
      engine <- engineOf forkNet "gauges" aX []
      events <- capturedAt Profile (Engine.advance engine)
      case named "impetus_gauges" events of
        [gauges] -> do
          int "history_records" gauges `shouldSatisfy` (> 0)
          int "places_occupied" gauges `shouldBe` 2 -- the fan-out landed on b and c
          int "tokens_total" gauges `shouldBe` 2
          int "in_flight" gauges `shouldBe` 0
          case field "max_rss_mb" gauges of
            Float mb -> mb `shouldSatisfy` (> 0)
            other -> expectationFailure ("max_rss_mb is not a float: " <> show other)
        other -> expectationFailure ("expected one gauges event, got " <> show other)

    it "test_facts_level_gathers_no_gauges" $ do
      engine <- engineOf forkNet "no-gauges" aX []
      events <- captured (Engine.advance engine)
      named "impetus_gauges" events `shouldBe` []

  describe "TestEngineOutcomeSpan" $
    it "test_drive_span_reports_actions_firings_and_waiting" $ do
      engine <- engineOf forkNet "outcome-span" aX []
      (events, outcome) <- capture Nothing Nothing $ \recorder -> do
        outcome <- Engine.advance engine
        (,outcome) <$> recorded recorder
      field "event" (firstOf events) `shouldBe` String "impetus_drive_started"
      let finished = last events
      field "event" finished `shouldBe` String "impetus_drive_finished"
      field "status" finished `shouldBe` String "success"
      int "actions" finished `shouldBe` 1 -- the one BeginCandidate the policy chose
      int "firings" finished `shouldBe` toInteger (length outcome.firings)
      length outcome.firings `shouldBe` 1
      field "waiting" finished `shouldSatisfy` exactEq (Bool False)

  describe "Haskell-specific" $ do
    -- test_coordinator.py's test_all_filtered_appends_no_history_and_emits_decline_telemetry
    -- asserts only the History half; this pins the telemetry half.
    it "an all-filtered offer emits candidate_selection_declined with the enabled count" $ do
      port <- inMemoryDispatch <$> newInMemoryDispatch
      let declining = selectionPipeline [const False] [] first :: SelectionPolicy ()
      engine <-
        newEngine
          forkNet
          "declined"
          Nothing
          port
          (\o -> o {Engine.marking = markingFromList [(p "a", [x, x])], Engine.selection = Engine.EngineSelection declining ()})
      events <- captured (Engine.advance engine)
      named "impetus_candidate_selection_declined" events
        `shouldBePayloads` [[("event", String "impetus_candidate_selection_declined"), ("instance", String "declined"), ("enabled", Int 2)]]

    it "level off silences every door, span, and commit" $ withScratch $ \dir -> do
      events <- capturedAt Off $ do
        store <- openJsonlHistoryStore (dir </> "history.jsonl")
        port <- inMemoryDispatch <$> newInMemoryDispatch
        engine <- newEngine forkNet "silent" (Just store) port (\o -> o {Engine.marking = aX})
        untilRest engine
      events `shouldBe` []

    it "an explicit Instance and Engine sink bypasses the process default" $ do
      recorder <- newRecorder
      outside <- captured $ do
        port <- inMemoryDispatch <$> newInMemoryDispatch
        engine <- newEngine forkNet "explicit" Nothing port (\o -> o {Engine.marking = aX, Engine.telemetrySink = Just (recorderSink recorder)})
        void (Engine.advance engine)
      outside `shouldBe` []
      eventNames <$> recorded recorder
        `shouldReturn` [ "impetus_instance_created"
                       , "impetus_drive_started"
                       , "impetus_firing_begun"
                       , "impetus_firing_completed"
                       , "impetus_drive_finished"
                       ]

    it "a failing sink never breaks a run" $ do
      let broken = EventSink (\_ -> ioError (userError "observability unavailable"))
      port <- inMemoryDispatch <$> newInMemoryDispatch
      engine <- newEngine forkNet "broken-sink" Nothing port (\o -> o {Engine.marking = aX, Engine.telemetrySink = Just broken})
      outcome <- try (Engine.advance engine) :: IO (Either SomeException Engine.DriveOutcome)
      either (expectationFailure . show) (\o -> length o.firings `shouldBe` 1) outcome
  where
    mempty' = markingFromList []
    acceptedOf = \case
      DeliveryAccepted a -> pure a
      other -> expectationFailure ("expected an acceptance, got " <> show other) >> fail "unreachable"
