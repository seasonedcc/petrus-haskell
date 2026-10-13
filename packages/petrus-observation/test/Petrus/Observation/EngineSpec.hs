-- | Port of @tests/petrus/engine/test_observation.py@ through the Engine:
-- the three tests of the Engine's lock, re-entry guard, and commit
-- poisoning, and an Engine-driven twin of every projection test that
-- "Petrus.Observation.ObservationSpec" drives with Instance doors. Every
-- read goes through "Petrus.Observation.Engine" (the reference's
-- @Engine.snapshot()@, @Engine.history_page()@, @Engine.net_document()@),
-- which reads on 'Petrus.Engine.Observation.observeEngine'.
module Petrus.Observation.EngineSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (void, when)
import Data.IORef
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityFailureFields (..), activityFailure)
import Petrus.Engine qualified as Engine
import Petrus.Engine.Internal (engineInstance, guarded)
import Petrus.Engine.Provider (EngineResources (..), OpenMode (..), defaultResources, openEngine)
import Petrus.Impetus.Binding (BoundHandler (..))
import Petrus.Impetus.HistoryStore (HistoryStore (..), inMemoryHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance (DeliveryScope (..), ImplementationRef (..), InstanceConfig (..), InstanceError, renderInstanceError)
import Petrus.Impetus.Instance qualified as I
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Motus.Dispatch.InMemory (inMemoryDispatch, newInMemoryDispatch)
import Petrus.Observation (ObservationError (..))
import Petrus.Observation.Engine qualified as Observe
import Petrus.Observation.Support
import System.Timeout (timeout)
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Builders

memoryDispatch :: IO Dispatch
memoryDispatch = inMemoryDispatch <$> newInMemoryDispatch

-- | @canonical_engine(history=...)@: the canonical net created at 7 over
-- the given History and an @InMemoryDispatch@, advanced once (the Activity
-- occurrence begins).
canonicalEngineWith :: HasCallStack => Maybe Engine.Sensor -> IO Engine.Engine
canonicalEngineWith sensor = do
  store <- inMemoryHistoryStore
  port <- memoryDispatch
  engine <- Engine.create canonicalNet "canonical-instance" store port (canonicalOptions sensor)
  outcome <- Engine.advance engine
  outcome.ready `shouldBe` True
  pure engine

canonicalEngine :: HasCallStack => IO Engine.Engine
canonicalEngine = canonicalEngineWith Nothing

canonicalOptions :: Maybe Engine.Sensor -> Engine.EngineOptions
canonicalOptions sensor =
  Engine.defaultEngineOptions
    { Engine.marking = canonicalConfig.initialMarking
    , Engine.handlers = Map.fromList [(Symbol "bridge", ActivityBound bridge)]
    , Engine.celCompilers = celStub
    , Engine.at = IntNumber 7
    , Engine.sensor = sensor
    }

-- | @Engine.create(net, identity, history=InMemoryHistoryStore(),
-- dispatch=InMemoryDispatch(), marking=..., at=...)@.
createEngine :: Net -> Text -> Marking -> Instant -> IO Engine.Engine
createEngine net identity initial at' = do
  store <- inMemoryHistoryStore
  port <- memoryDispatch
  Engine.create net identity store port Engine.defaultEngineOptions {Engine.marking = initial, Engine.at = at'}

sourceNet :: Net
sourceNet = netOf (netSpec [place a] [transition source] [arc source a])

door :: HasCallStack => IO (Either InstanceError x) -> IO x
door action = action >>= expectRight . either (Left . renderInstanceError) Right

-- ---------------------------------------------------------------------------
-- Selectors and readers

-- | @pytest.raises(RuntimeError, match=fragment)@.
runtimeError :: Text -> Selector Engine.EngineError
runtimeError fragment = \case
  Engine.EngineRuntimeError message -> fragment `T.isInfixOf` message
  _ -> False

-- | @pytest.raises(ValueError, match=fragment)@ from a projection.
valueError :: Text -> Selector ObservationError
valueError fragment (ObservationError message) = fragment `T.isInfixOf` message

-- | Ordered regex fragments (@match="a.*b"@).
valueErrorMatching :: [Text] -> Selector ObservationError
valueErrorMatching fragments (ObservationError message) = go message fragments
  where
    go _ [] = True
    go text (f : fs) = case T.breakOn f text of
      (_, rest) | T.null rest -> False
      (_, rest) -> go (T.drop (T.length f) rest) fs

integer :: HasCallStack => Json -> Integer
integer = \case
  Int n -> n
  other -> error ("not an integer: " <> show other)

int :: Integer -> Json
int = Int

-- ---------------------------------------------------------------------------
-- @PausingHistory@

-- | @PausingHistory(InMemoryHistoryStore)@: once 'pause' is set, every
-- append signals 'appended' after it lands and then waits (at most 2 s, the
-- reference's @assert self.resume.wait(2)@) for 'resume'.
data PausingHistory = PausingHistory
  { store :: HistoryStore
  , pause :: IORef Bool
  , appended :: MVar ()
  , resume :: MVar ()
  }

newPausingHistory :: IO PausingHistory
newPausingHistory = do
  base <- inMemoryHistoryStore
  pause <- newIORef False
  appended <- newEmptyMVar
  resume <- newEmptyMVar
  let extend' batch = do
        base.extend batch
        paused <- readIORef pause
        when paused $ do
          void (tryPutMVar appended ())
          resumed <- timeout 2000000 (readMVar resume)
          when (isNothing resumed) $ throwIO (userError "PausingHistory: resume was not signalled within 2 s")
  pure
    PausingHistory
      { store = HistoryStore {snapshot = base.snapshot, count = base.count, extend = extend', mode = base.mode}
      , pause
      , appended
      , resume
      }

-- | Run an action on its own thread; the returned action joins it (at most
-- 5 s) and reports whether it finished.
spawn :: IO () -> IO (IO Bool)
spawn action = do
  finished <- newEmptyMVar
  _ <- forkIO (action >> putMVar finished ())
  pure (maybe False (const True) <$> timeout 5000000 (readMVar finished))

spec :: Spec
spec = describe "observation through the Engine (test_observation.py)" $ do
  describe "the Engine's coherence" $ do
    -- test_snapshot_blocks_between_append_and_projection_then_sees_coherent_after_state
    it "a snapshot blocks between a writer's append and projection, then sees the coherent after state" $ do
      history <- newPausingHistory
      port <- memoryDispatch
      engine <- Engine.create sourceNet "barrier" history.store port Engine.defaultEngineOptions
      writeIORef history.pause True
      errors <- newIORef ([] :: [SomeException])
      let recordingErrors action = try action >>= either (\e -> modifyIORef' errors (<> [e])) pure
      joinWriter <- spawn (recordingErrors (void (Engine.deliver engine source [Token (Just "X") Null] "barrier-event" Nothing)))
      appendedInTime <- timeout 1000000 (readMVar history.appended)
      appendedInTime `shouldBe` Just ()
      completed <- newEmptyMVar
      snapshots <- newIORef []
      joinReader <-
        spawn
          ( recordingErrors (Observe.snapshot engine >>= \s -> modifyIORef' snapshots (<> [s]))
              >> putMVar completed ()
          )
      completedEarly <- timeout 20000 (readMVar completed)
      completedEarly `shouldBe` Nothing
      putMVar history.resume ()
      writerDone <- joinWriter
      readerDone <- joinReader
      (writerDone, readerDone) `shouldBe` (True, True)
      readIORef errors >>= \es -> map show es `shouldBe` []
      observed <- firstOf <$> readIORef snapshots
      recorded <- Engine.records engine
      member "frontier" observed `shouldBe` int (fromIntegral (length recorded))
      member "tokens" (firstOf (items (members ["current", "marking"] observed)))
        `shouldBeExactly` Array [Object [("color", String "X"), ("data", Null)]]

    -- Beyond upstream (O-006 for the document): the same barrier as above,
    -- with the reader taking @Engine.net_document()@.
    it "a document read blocks between a writer's append and projection, then sees the coherent after state (beyond upstream)" $ do
      history <- newPausingHistory
      port <- memoryDispatch
      engine <- Engine.create sourceNet "barrier" history.store port Engine.defaultEngineOptions
      writeIORef history.pause True
      errors <- newIORef ([] :: [SomeException])
      let recordingErrors action = try action >>= either (\e -> modifyIORef' errors (<> [e])) pure
      joinWriter <- spawn (recordingErrors (void (Engine.deliver engine source [Token (Just "X") Null] "barrier-event" Nothing)))
      appendedInTime <- timeout 1000000 (readMVar history.appended)
      appendedInTime `shouldBe` Just ()
      completed <- newEmptyMVar
      documents <- newIORef []
      joinReader <-
        spawn
          ( recordingErrors (Observe.netDocument engine >>= \d -> modifyIORef' documents (<> [d]))
              >> putMVar completed ()
          )
      completedEarly <- timeout 20000 (readMVar completed)
      completedEarly `shouldBe` Nothing
      putMVar history.resume ()
      writerDone <- joinWriter
      readerDone <- joinReader
      (writerDone, readerDone) `shouldBe` (True, True)
      readIORef errors >>= \es -> map show es `shouldBe` []
      observed <- firstOf <$> readIORef documents
      settled <- Observe.netDocument engine
      observed `shouldBeExactly` settled

    -- test_same_thread_public_reentry_is_refused_but_sensor_status_observation_remains_supported
    it "same-thread public re-entry is refused, but status observation from inside a door remains supported" $ do
      atomic <- canonicalEngine
      guarded atomic (Observe.snapshot atomic) `shouldThrow` runtimeError "cannot re-enter"

      engine <- canonicalEngine
      let readAll = (,,,) <$> Engine.marking engine <*> Engine.status engine <*> Engine.inFlight engine <*> Engine.records engine
      observed <- guarded engine readAll
      current <- readAll
      observed `shouldBe` current

    -- test_joined_commit_failure_poisons_observation_and_hides_uncommitted_frontier
    it "a joined commit failure poisons observation and hides the uncommitted frontier" $ do
      history <- inMemoryHistoryStore
      port <- memoryDispatch
      -- The reference swaps in @_EngineResources(commit=<raises>)@ after
      -- construction; here the commit hook raises once armed.
      refusing <- newIORef False
      let commitHook = readIORef refusing >>= \armed -> when armed (throwIO (Engine.EngineRuntimeError "commit refused"))
      engine <-
        openEngine CreateInstance sourceNet "poison" history port Engine.defaultEngineOptions defaultResources {commit = Just commitHook}
      committedFrontier <- Store.size history
      writeIORef refusing True
      Engine.deliver engine source [Token (Just "X") Null] "poison-event" Nothing `shouldThrow` runtimeError "commit refused"
      -- The backend-owned double cannot roll back; the Engine still refuses
      -- exposure.
      afterFailure <- Store.size history
      (committedFrontier < afterFailure) `shouldBe` True
      Observe.snapshot engine `shouldThrow` runtimeError "poisoned"
      Observe.historyPage engine 0 10 `shouldThrow` runtimeError "poisoned"
      -- Beyond upstream: the remaining door, and the Engine's refusal before
      -- any cursor check.
      Observe.netDocument engine `shouldThrow` runtimeError "poisoned"
      Observe.historyPageJson engine (Bool True) (int 0) `shouldThrow` runtimeError "poisoned"

    it "a sensor consulted inside advance is refused a protocol view but may read status (beyond upstream)" $ do
      engineRef <- newIORef Nothing
      seen <- newIORef []
      let sensor =
            readIORef engineRef >>= \case
              Nothing -> pure []
              Just engine -> do
                refused <- try (Observe.snapshot engine)
                currentStatus <- Engine.status engine
                modifyIORef' seen (<> [(either (Just . Engine.engineErrorMessage) (const Nothing) refused, currentStatus)])
                pure []
      store <- inMemoryHistoryStore
      port <- memoryDispatch
      engine <- Engine.create canonicalNet "canonical-instance" store port (canonicalOptions (Just sensor))
      writeIORef engineRef (Just engine)
      _ <- Engine.advance engine
      _ <- Engine.advance engine
      consulted <- readIORef seen
      null consulted `shouldBe` False
      currentStatus <- Engine.status engine
      consulted
        `shouldBe` [ (Just "public Engine operation cannot re-enter while a writing door is active", currentStatus)
                   | _ <- consulted
                   ]
      -- The Engine is not poisoned: the sensor caught its refusal.
      void (Observe.snapshot engine)

    it "a closed Engine refuses every view" $ do
      engine <- canonicalEngine
      Engine.close engine
      let closed = runtimeError "this Engine is closed; create or load a new Engine before observing or driving"
      Observe.snapshot engine `shouldThrow` closed
      Observe.historyPage engine 0 1 `shouldThrow` closed
      Observe.netDocument engine `shouldThrow` closed

  describe "Engine-driven projections (twins of the Instance-door ports)" $ do
    -- test_canonical_fixture_is_exact_producer_output_and_has_typed_fifo_activity_pending_state
    it "produces the exact snapshot fixture with a typed FIFO activity-pending state" $ do
      produced <- canonicalEngine >>= Observe.snapshot
      expected <- readJsonFile (specFile "observation/engine-snapshot-v1.json")
      produced `shouldBeExactly` expected
      produced `shouldSpellFixture` specFile "observation/engine-snapshot-v1.json"
      members ["current", "marking"] produced
        `shouldBeExactly` Array [Object [("place", String "a"), ("tokens", Array [Object [("color", String "Input"), ("data", Object [("ordinal", int 2)])]])]]
      let occurrence = firstOf (items (members ["current", "in_flight"] produced))
      member "phase" occurrence `shouldBe` String "activity_pending"
      members ["invocation", "policy"] occurrence
        `shouldBeExactly` Object
          [ ("attempts", int 1)
          , ("heartbeat_timeout", int 30)
          , ("initial_interval", int 0)
          , ("coefficient", int 2)
          , ("max_interval", int 60)
          , ("jitter", int 0)
          , ("start_to_close", Null)
          , ("schedule_to_close", Null)
          ]
      members ["current", "armed"] produced `shouldBeExactly` Array [Object [("source", String "source"), ("key", String "default")]]
      members ["current", "watermark"] produced `shouldBeExactly` int 7

    -- test_canonical_history_fixture_is_exact_complete_page_with_current_typed_occurrences
    it "produces the exact complete History page fixture" $ do
      produced <- canonicalEngine >>= \engine -> Observe.historyPage engine 0 100
      expected <- readJsonFile (specFile "observation/engine-history-page-v1.json")
      produced `shouldBeExactly` expected
      produced `shouldSpellFixture` specFile "observation/engine-history-page-v1.json"
      let entries = items (member "records" produced)
      map (member "position") entries `shouldBe` [int i | i <- [0 .. integer (member "frontier" produced) - 1]]
      member "next" produced `shouldBe` member "frontier" produced
      all (\x -> members ["record", "schema"] x == int 5) entries `shouldBe` True
      let typed = [member "color" t | x <- entries, Object r <- [member "record" x], Just ts <- [lookup "tokens" r], t <- items ts]
      (String "Input" `elem` typed) `shouldBe` True
      let occurrences = [o | x <- entries, Object r <- [member "record" x], Just o <- [lookup "occurrence" r]]
      null occurrences `shouldBe` False
      nub [o | o <- occurrences, o /= Null] `shouldBe` [int 1]

    -- test_protocol_v1_history_transports_one_field_complete_current_schema
    it "transports the complete current schema, scope fields included" $ do
      engine <- canonicalEngine
      scope <- Engine.openScope engine "draft"
      _ <- Engine.deliver engine source [Token (Just "External") (int 1)] "draft-1" (Just (ScopeGeneration scope))
      _ <- Engine.closeScope engine scope
      produced <- Observe.historyPage engine 0 100
      member "protocol" produced `shouldBeExactly` int 1
      let lifecycle = map (member "record") (items (member "records" produced))
      nub (map (member "schema") lifecycle) `shouldBe` [int 5]
      [n | r <- lifecycle, String n <- [member "record" r], "Scope" `T.isPrefixOf` n] `shouldBe` ["ScopeOpened", "ScopeClosed"]
      let scoped = [s | Object r <- lifecycle, Just s <- [lookup "scope" r], s /= Null]
      null scoped `shouldBe` False
      all (\s -> member "name" s == String "draft") scoped `shouldBe` True
      all (\case Object r -> lookup "scope" r /= Nothing; _ -> False) [r | r <- lifecycle, member "record" r == String "TokensInitialized"]
        `shouldBe` True

    -- test_canonical_observed_net_document_fixture_has_one_complete_marking_per_history_record
    it "produces the exact observed Net document fixture, one complete marking per record" $ do
      engine <- canonicalEngine
      produced <- Observe.netDocument engine
      expected <- readJsonFile (specFile "net-document-v1-observation.json")
      produced `shouldBeExactly` expected
      produced `shouldSpellFixture` specFile "net-document-v1-observation.json"
      member "format" produced `shouldBe` String "petrus-net-document"
      member "version" produced `shouldBeExactly` int 1
      let lineage = member "lineage" produced
          entries = items (member "entries" lineage)
      recorded <- Engine.records engine
      member "head" lineage `shouldBe` int (fromIntegral (length entries - 1))
      map (member "id") entries `shouldBe` [int i | i <- [0 .. fromIntegral (length recorded) - 1]]
      all (\e -> member "provenance" e == String "observed") entries `shouldBe` True
      full <- Observe.historyPage engine 0 100
      map (members ["metadata", "history_record"]) entries `shouldBe` map (member "record") (items (member "records" full))
      current <- Observe.snapshot engine
      member "marking" (last entries) `shouldBeExactly` members ["current", "marking"] current
      case members ["metadata", "observation"] (last entries) of
        Object ms -> lookup "marking" ms `shouldBe` Nothing
        other -> expectationFailure ("observation is not an object: " <> show other)

    -- test_capture_pages_freeze_snapshot_frontier_while_history_continues_to_append
    it "pages a captured frontier while History keeps appending" $ do
      engine <- canonicalEngine
      captured <- Observe.snapshot engine
      let frontier = integer (member "frontier" captured)
          loop cursor observedFrontier positions
            | cursor >= frontier = pure (observedFrontier, positions)
            | otherwise = do
                let limit = min 2 (frontier - cursor)
                current <- Observe.historyPage engine cursor limit
                let pageFrontier = integer (member "frontier" current)
                    next = integer (member "next" current)
                member "after" current `shouldBe` int cursor
                member "protocol" current `shouldBe` member "protocol" captured
                member "instance" current `shouldBe` member "instance" captured
                (pageFrontier >= observedFrontier) `shouldBe` True
                next `shouldBe` min (cursor + limit) pageFrontier
                (next <= frontier) `shouldBe` True
                let got = map (member "position") (items (member "records" current))
                got `shouldBe` map int [cursor .. next - 1]
                when (next == 2) $ Engine.seal engine source
                loop next pageFrontier (positions ++ got)
      (finalFrontier, positions) <- loop 0 frontier []
      (finalFrontier > frontier) `shouldBe` True
      positions `shouldBe` map int [0 .. frontier - 1]

    -- test_snapshot_reports_pure_and_projection_pending_phases_and_detaches_frozen_result
    it "reports pure and projection-pending phases with the frozen result" $ do
      pureEngine <-
        createEngine
          (netOf (netSpec [place a, place b] [transition work] [arc a work, arc work b]))
          "pure-pending"
          (markingFromList [(a, [Token (Just "Input") (Object [("nested", Array [int 1])])])])
          (IntNumber 0)
      -- Public Instance operations create the phase (the reference calls
      -- @engine._instance.begin@).
      I.candidates (engineInstance pureEngine) >>= \case
        binding : _ -> void (door (I.begin (engineInstance pureEngine) binding Nothing))
        [] -> expectationFailure "expected a candidate"
      observedPure <- Observe.snapshot pureEngine
      member "phase" (firstOf (items (members ["current", "in_flight"] observedPure))) `shouldBe` String "pure_pending"

      projection <- canonicalEngine
      occurrence <- firstOf <$> Engine.inFlight projection
      let result = Object [("nested", Array [Object [("value", int 1)]])]
      _ <- door (I.recordActivityCompletion (engineInstance projection) occurrence result (Just (IntNumber 8)))
      pendingOccurrence <- firstOf . items . members ["current", "in_flight"] <$> Observe.snapshot projection
      member "phase" pendingOccurrence `shouldBe` String "projection_pending"
      member "result" pendingOccurrence `shouldBeExactly` result

    -- test_snapshot_detaches_a_classified_failure_while_its_firing_terminal_is_pending
    it "reports a classified failure while its firing terminal is pending" $ do
      engine <- canonicalEngine
      occurrence <- firstOf <$> Engine.inFlight engine
      failure <-
        expectRight
          ( activityFailure
              ActivityFailureFields
                { failureError = "invalid"
                , failureKind = "InvalidRequest"
                , failureDetails = Object [("field", String "name")]
                , failureRetryable = False
                , failureRetryAfter = Just (IntNumber 9)
                }
          )
      _ <- door (I.recordActivityFailure (engineInstance engine) occurrence failure (Just (IntNumber 8)))
      pendingOccurrence <- firstOf . items . members ["current", "in_flight"] <$> Observe.snapshot engine
      member "phase" pendingOccurrence `shouldBe` String "projection_pending"
      member "result" pendingOccurrence
        `shouldBeExactly` Object
          [ ("error", String "invalid")
          , ("kind", String "InvalidRequest")
          , ("details", Object [("field", String "name")])
          , ("retryable", Bool False)
          , ("retry_after", int 9)
          ]

    -- test_snapshot_detaches_nested_tokens_and_activity_values
    it "keeps nested token and Activity values as captured" $ do
      let tokenData = Object [("items", Array [Object [("value", int 1)]])]
          net = netOf (netSpec [place a, place b] [Transition {path = work, handler = Just (HandlerSymbol "bridge"), guards = [], timers = []}] [arc a work, arc work b])
      store <- inMemoryHistoryStore
      port <- memoryDispatch
      engine <-
        Engine.create net "detached" store port (canonicalOptions Nothing) {Engine.marking = markingFromList [(a, [Token (Just "Input") tokenData])], Engine.at = IntNumber 0}
      _ <- Engine.advance engine
      occurrence <- firstOf . items . members ["current", "in_flight"] <$> Observe.snapshot engine
      member "data" (firstOf (items (member "tokens" (firstOf (items (members ["binding", "consumed"] occurrence))))))
        `shouldBeExactly` tokenData
      members ["invocation", "input"] occurrence `shouldBeExactly` Object [("nested", Array [tokenData])]

    -- test_snapshot_emits_integer_next_maturation_and_refuses_boolean_when_reachable
    it "emits an integer next maturation and refuses a non-integer one" $ do
      let timedNet timer = netOf (netSpec [place a] [Transition {path = work, handler = Nothing, guards = [], timers = [timer]}] [arc a work])
          initial = markingFromList [(a, [Token (Just "X") Null])]
      timed <- createEngine (timedNet (Delay (IntNumber 5))) "timed" initial (IntNumber 2)
      observed <- Observe.snapshot timed
      members ["current", "next_maturation"] observed `shouldBeExactly` int 7
      -- Until(True) cannot be built; the reachable non-integer is a float.
      bad <- createEngine (timedNet (Until (FloatNumber 1.5))) "bad-timed" initial (IntNumber 0)
      Observe.snapshot bad `shouldThrow` valueErrorMatching ["next maturation", "integer"]

    describe "test_history_page_refuses_malformed_cursor_or_limit" $ do
      let refuses afterCursor limit message = do
            engine <- canonicalEngine
            Observe.historyPageJson engine afterCursor limit `shouldThrow` (== ObservationError message)
      -- test_history_page_refuses_malformed_cursor_or_limit[-1-1]
      it "refuses after=-1" $ refuses (int (-1)) (int 1) "history after must be a non-negative integer, got -1"
      -- test_history_page_refuses_malformed_cursor_or_limit[True-1]
      it "refuses after=True" $ refuses (Bool True) (int 1) "history after must be a non-negative integer, got True"
      -- test_history_page_refuses_malformed_cursor_or_limit[0.5-1]
      it "refuses after=0.5" $ refuses (Float 0.5) (int 1) "history after must be a non-negative integer, got 0.5"
      -- test_history_page_refuses_malformed_cursor_or_limit[0-0]
      it "refuses limit=0" $ refuses (int 0) (int 0) "history limit must be a positive integer, got 0"
      -- test_history_page_refuses_malformed_cursor_or_limit[0-True]
      it "refuses limit=True" $ refuses (int 0) (Bool True) "history limit must be a positive integer, got True"
      -- test_history_page_refuses_malformed_cursor_or_limit[0-1.5]
      it "refuses limit=1.5" $ refuses (int 0) (Float 1.5) "history limit must be a positive integer, got 1.5"
      it "refuses the same values through the typed door" $ do
        engine <- canonicalEngine
        Observe.historyPage engine (-1) 1 `shouldThrow` (== ObservationError "history after must be a non-negative integer, got -1")
        Observe.historyPage engine 0 0 `shouldThrow` (== ObservationError "history limit must be a positive integer, got 0")

    -- test_strict_json_refuses_nonfinite_and_unencodable_nested_data_and_bad_current_time
    it "refuses non-finite token data and a non-integer current watermark" $ do
      nan <- createEngine (netOf (netSpec [place a] [] [])) "bad-data" (markingFromList [(a, [Token (Just "X") (Object [("bad", Float (0 / 0))])])]) (IntNumber 0)
      Observe.snapshot nan `shouldThrow` valueError "strict JSON-faithful"
      -- {"bad": object()} is enforced by types (token data is Json). The
      -- reference forces a boolean watermark into the Instance; the
      -- reachable non-integer is a float construction instant.
      floatClock <- createEngine (netOf (netSpec [place a] [] [])) "bad-time" emptyMarking (FloatNumber 7.5)
      Observe.snapshot floatClock `shouldThrow` valueErrorMatching ["watermark", "integer"]

    -- test_cursor_algebra_polling_concurrent_arrival_and_reconnect_have_no_gap_or_duplicate
    it "polls with no gap or duplicate across concurrent arrival and reconnect" $ do
      engine <- canonicalEngine
      frontier <- integer . member "frontier" <$> Observe.snapshot engine
      first' <- Observe.historyPage engine 0 2
      let next p = integer (member "next" p)
          frontierOf p = integer (member "frontier" p)
          positionsOf p = map (member "position") (items (member "records" p))
      Engine.seal engine source
      let loop cursor acc = do
            p <- Observe.historyPage engine cursor 2
            let acc' = acc ++ positionsOf p
            if next p == frontierOf p then pure (next p, acc') else loop (next p) acc'
      (cursor, positions) <- loop (next first') (positionsOf first')
      positions `shouldBe` map int [0 .. cursor - 1]
      (cursor > frontier) `shouldBe` True
      atFrontier <- Observe.historyPage engine cursor 1
      member "records" atFrontier `shouldBeExactly` Array []
      Observe.historyPage engine (cursor + 1) 1 `shouldThrow` valueError "exceeds captured frontier"
