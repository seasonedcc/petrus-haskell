-- | Parity: @tests/petrus/impetus/history_store/test_postgres_history.py@
-- (21 tests) and the @postgres@ parameter of
-- @test_history_backends.py@'s @reopen@ fixture (14 tests), plus the
-- store's own edges (exact DDL, telemetry, statement shapes).
--
-- Every example runs against one scratch database ("Petrus.TestSupport");
-- without @PETRUS_TEST_POSTGRES@ they are pending, saying so.
module Petrus.HistoryStore.PostgresSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, finally, fromException, try)
import Control.Monad (forM, forM_, void)
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.HistoryStore.BackendContractSpec (backendContract)
import Petrus.HistoryStore.Postgres
import Petrus.HistoryStore.Postgres.Support
import Petrus.Impetus.History
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.HistoryStore (CommitMode (..), HistoryStore (..))
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Impetus.TestSupport (np, netOf)
import Petrus.Json (Json (..))
import Petrus.Postgres
import Petrus.Telemetry (newRecorder, recorded, recorderSink)
import Petrus.TestSupport
import Test.Hspec

place', transition' :: NetPath
place' = np "p"
transition' = np "t"

initialized :: Record
initialized = RTokensInitialized (TokensInitialized place' [black] 0 [] Nothing)

begun :: Int -> Number -> Record
begun occurrence instant = RFiringBegun (FiringBegun transition' occurrence Nothing instant)

completed :: Int -> Number -> Record
completed occurrence instant = RFiringCompleted (FiringCompleted transition' occurrence instant)

failed :: Text -> Int -> Number -> Record
failed message occurrence instant = RFiringFailed (FiringFailed transition' message occurrence instant)

produced :: Int -> Number -> Record
produced occurrence instant = RTokensProduced (TokensProduced place' [black] occurrence [] Nothing instant)

open' :: Connection -> Text -> IO HistoryStore
open' = openPostgresHistoryStore

recordsAt :: Connection -> Text -> IO [Record]
recordsAt connection instanceId = open' connection instanceId >>= Store.records

spec :: Spec
spec = do
  postgresSpec $ do
    ensureSchemaSpec
    backendShapeSpec
    transactionalBatchesSpec
    verifyOnConflictSpec
    callerTransactionSpec
    decodeSpec
    beyondUpstreamSpec
  postgresBackendContract

-- | The @postgres@ parameter of @test_history_backends.py@'s @reopen@: each
-- call loads a fresh store over the same instance on one connection.
postgresBackendContract :: Spec
postgresBackendContract = do
  current <- runIO (newIORef Nothing)
  postgresSpec $
    aroundWith (\action target -> writeIORef current (Just target) >> action ()) $
      backendContract "postgres" $ \body ->
        readIORef current >>= \case
          Nothing -> expectationFailure "no PostgreSQL target"
          Just target -> withPgConnection target $ \connection -> do
            instanceId <- freshInstance "backend-contract"
            body (open' connection instanceId)

-- ---------------------------------------------------------------------------
-- TestEnsureSchema

ensureSchemaSpec :: SpecWith PostgresTarget
ensureSchemaSpec = describe "TestEnsureSchema" $ do
  it "ensure_schema_is_idempotent_and_survives_existing_rows" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      ensureSchema pg
      open' pg instanceId >>= \h -> Store.append h initialized
      ensureSchema pg
      (open' pg instanceId >>= Store.size) `shouldReturn` 1

  it "an_unprovisioned_database_fails_loud_naming_ensure_schema" $ \target ->
    withPg target True $ \connection -> do
      instanceId <- freshInstance "pg-only"
      execute_ connection "DROP SCHEMA IF EXISTS impetus CASCADE" []
      (open' connection instanceId `shouldThrow` valueErrorMatching ["ensure_schema"])
        `finally` ensureSchema connection

-- ---------------------------------------------------------------------------
-- TestBackendShape

backendShapeSpec :: SpecWith PostgresTarget
backendShapeSpec = describe "TestBackendShape" $ do
  -- The non-string half (instance=7) is enforced by types.
  it "the_instance_id_must_be_a_non_empty_string" $ \target ->
    withPgConnection target $ \pg ->
      open' pg "" `shouldThrow` valueErrorMatching ["non-empty string instance"]

  it "one_table_holds_many_instances_apart" $ \target ->
    withPgConnection target $ \pg -> do
      first <- freshInstance "pg-only"
      second <- freshInstance "pg-only"
      open' pg first >>= \h -> Store.append h initialized
      open' pg second >>= \h -> Store.append h (begun 1 1)
      recordsAt pg first `shouldReturn` [initialized]
      recordsAt pg second `shouldReturn` [begun 1 1]

  it "the_stored_row_speaks_the_ratified_payload" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      let record = completed 7 3
      open' pg instanceId >>= \h -> Store.append h record
      [Row event recordType occurrence payload] <- rows pg instanceId
      event `shouldBe` (instanceId <> ":0")
      recordType `shouldBe` "FiringCompleted"
      occurrence `shouldBe` Just 7
      payload `shouldBe` encodeRecord record

  it "schema_2_is_refused_through_the_actual_postgresql_history_load" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      execute_
        pg
        "INSERT INTO impetus.semantic_events (event_id, net_instance_id, record_type, occurrence, payload) VALUES (%s, %s, %s, %s, %s::jsonb)"
        [ textParam (instanceId <> ":0")
        , textParam instanceId
        , textParam "ActivityRequested"
        , intParam 1
        , textParam
            "{\"record\": \"ActivityRequested\", \"schema\": 2, \"transition\": \"t\", \"activity\": \"old\", \"capabilities\": [\"gpu\"], \"occurrence\": 1, \"instant\": 0}"
        ]
      open' pg instanceId `shouldThrow` valueErrorMatching ["'schema' is 2", "reads schema 5 only"]

-- ---------------------------------------------------------------------------
-- TestTransactionalBatches

transactionalBatchesSpec :: SpecWith PostgresTarget
transactionalBatchesSpec = describe "TestTransactionalBatches" $
  it "a_batch_that_fails_mid_transaction_leaves_nothing" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      history <- open' pg instanceId
      history.extend [begun 1 1, completed 1 2]
      stale <- open' pg instanceId
      stale.extend [produced 1 3, failed "late diverging terminal" 1 3]
        `shouldThrow` valueErrorMatching ["terminal"]
      Store.size stale `shouldReturn` 2
      expected <- Store.records history
      recordsAt pg instanceId `shouldReturn` expected

-- ---------------------------------------------------------------------------
-- TestVerifyOnConflict

verifyOnConflictSpec :: SpecWith PostgresTarget
verifyOnConflictSpec = describe "TestVerifyOnConflict" $ do
  it "a_duplicate_identical_append_is_acknowledged_without_a_second_row" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      let record = completed 1 2
      first <- open' pg instanceId
      twin <- open' pg instanceId
      Store.append first record
      Store.append twin record
      length <$> rows pg instanceId `shouldReturn` 1
      Store.records twin `shouldReturn` [record]
      Store.records first `shouldReturn` [record]

  it "a_conflicting_different_append_fails_loud_naming_the_event" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      first <- open' pg instanceId
      twin <- open' pg instanceId
      Store.append first (completed 1 2)
      Store.append twin (failed "boom" 1 2)
        `shouldThrow` valueErrorMatching [instanceId <> ":0", "FiringCompleted", "FiringFailed"]
      length <$> rows pg instanceId `shouldReturn` 1

  it "a_second_terminal_fact_conflicts_at_the_index_and_verifies" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      history <- open' pg instanceId
      let terminal = completed 1 2
      history.extend [begun 1 1, terminal]
      Store.append history terminal
      map (.rowType) <$> rows pg instanceId `shouldReturn` ["FiringBegun", "FiringCompleted"]
      Store.size history `shouldReturn` 2
      length <$> rows pg instanceId `shouldReturn` 2
      Store.append history (failed "diverging" 1 3)
        `shouldThrow` valueErrorMatching ["terminal", "FiringCompleted", "FiringFailed"]

  it "the_history_continues_past_a_terminal_index_acknowledgement" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      history <- open' pg instanceId
      let terminal = completed 1 2
      history.extend [begun 1 1, terminal]
      Store.append history terminal
      Store.append history (produced 1 3)
      reloaded <- open' pg instanceId
      mirror <- Store.records history
      Store.records reloaded `shouldReturn` mirror
      Store.append reloaded (begun 2 4)
      map (.rowEvent) <$> rows pg instanceId `shouldReturn` [instanceId <> ":" <> T.pack (show n) | n <- [0 .. 3 :: Int]]
      reloadedRecords <- Store.records reloaded
      recordsAt pg instanceId `shouldReturn` reloadedRecords

  it "two_connections_identical_terminal_at_divergent_positions_acknowledges" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      let terminal = completed 1 2
      writerA <- open' pg instanceId
      writerA.extend [begun 1 1, produced 1 2, terminal]
      withPg target True $ \connectionB -> do
        writerB <- open' connectionB instanceId
        Store.append writerB terminal
        Store.size writerB `shouldReturn` 3
        length <$> rows pg instanceId `shouldReturn` 3
      length . filter (== "FiringCompleted") . map (.rowType) <$> rows pg instanceId `shouldReturn` 1

  it "two_connections_different_terminal_at_divergent_positions_fails_loud" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      writerA <- open' pg instanceId
      writerA.extend [begun 1 1, produced 1 2, completed 1 2]
      withPg target True $ \connectionB -> do
        writerB <- open' connectionB instanceId
        Store.append writerB (failed "boom" 1 3)
          `shouldThrow` valueErrorMatching ["terminal", "FiringCompleted", "FiringFailed"]
        Store.size writerB `shouldReturn` 3
      map (.rowType) <$> rows pg instanceId `shouldReturn` ["FiringBegun", "TokensProduced", "FiringCompleted"]

  it "the_one_terminal_activity_fact_index_holds_the_same_discipline" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      history <- open' pg instanceId
      let captured = RActivityCompleted (ActivityCompleted transition' (Object [("status", String "captured")]) 1 2)
      Store.append history captured
      Store.append history captured
      length <$> rows pg instanceId `shouldReturn` 1
      Store.append history (RActivityFailed (ActivityFailed transition' "late failure" "ActivityError" Null False Nothing 1 3))
        `shouldThrow` valueErrorMatching ["terminal", "ActivityCompleted", "ActivityFailed"]

  it "concurrent_duplicate_terminal_appends_one_wins_the_other_acknowledges" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-race"
      let record = completed 1 2
      barrier <- newBarrier 2
      outcomes <- race 2 $ \_ -> withPg target True $ \connection -> do
        history <- open' connection instanceId
        awaitBarrier barrier
        Store.append history record
      map (either (Just . show) (const Nothing)) outcomes `shouldBe` [Nothing, Nothing]
      recordsAt pg instanceId `shouldReturn` [record]

  it "concurrent_different_terminal_appends_exactly_one_is_refused" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-race"
      barrier <- newBarrier 2
      let contenders = [("completed", completed 1 2), ("failed", failed "boom" 1 2)]
      outcomes <- race 2 $ \i -> withPg target True $ \connection -> do
        history <- open' connection instanceId
        awaitBarrier barrier
        Store.append history (snd (contenders !! i))
      let winners = [fst c | (c, Right ()) <- zip contenders outcomes]
          losers = [e | Left e <- outcomes]
      length winners `shouldBe` 1
      length losers `shouldBe` 1
      forM_ losers $ \e -> fmap (\(HistoryStoreError _) -> ()) (fromException e) `shouldBe` Just ()
      [Row _ recordType _ _] <- rows pg instanceId
      recordType `shouldBe` (if winners == ["completed" :: Text] then "FiringCompleted" else "FiringFailed")

-- | Run @n@ racers on their own threads; each outcome in racer order.
race :: Int -> (Int -> IO ()) -> IO [Either SomeException ()]
race n racer = do
  slots <- forM [0 .. n - 1] $ \i -> do
    slot <- newEmptyMVar
    void (forkIO (try (racer i) >>= putMVar slot))
    pure slot
  mapM takeMVar slots

-- ---------------------------------------------------------------------------
-- TestCallerTransactionJoin

callerTransactionSpec :: SpecWith PostgresTarget
callerTransactionSpec = describe "TestCallerTransactionJoin" $ do
  it "appends_join_the_callers_transaction_and_land_at_its_commit" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      mirror <- withPg target False $ \caller -> do
        history <- open' caller instanceId
        history.mode `shouldBe` JoinedTransaction
        Store.append history initialized
        history.extend [begun 1 1, RTokensConsumed (TokensConsumed place' [black] 1 [] Nothing 1)]
        rows pg instanceId `shouldReturn` []
        commit caller
        Store.records history
      length <$> rows pg instanceId `shouldReturn` 3
      recordsAt pg instanceId `shouldReturn` mirror

  it "a_rolled_back_caller_transaction_takes_the_appends_with_it" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      withPg target False $ \caller -> do
        history <- open' caller instanceId
        Store.append history initialized
        rollback caller
      rows pg instanceId `shouldReturn` []
      recordsAt pg instanceId `shouldReturn` []

  it "loading_inside_the_callers_transaction_sees_its_own_appends" $ \target ->
    withPgConnection target $ \_ -> do
      instanceId <- freshInstance "pg-only"
      withPg target False $ \caller -> do
        open' caller instanceId >>= \h -> Store.append h initialized
        recordsAt caller instanceId `shouldReturn` [initialized]
        rollback caller

  it "a_rollback_discards_the_whole_runtime_derived_over_the_backend" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      let intake = np "intake"
          out = np "out"
          net = netOf [place out] [transition intake] [arc intake out]
          config store = defaultInstanceConfig {historyStore = Just store}
          deliver' inst identity at' = do
            Right (DeliveryAccepted accepted) <- acceptDelivery inst intake [black] identity Nothing (Just at')
            Right outcome <- completeDelivery inst accepted (Just at')
            pure outcome
      withPg target False $ \caller -> do
        store <- open' caller instanceId
        Right inst <- newInstance net (config store)
        _ <- deliver' inst "evt_1" 3
        commit caller
        _ <- deliver' inst "evt_2" 5
        rollback caller
        watermark inst `shouldReturn` 5
        length . placeTokens out <$> marking inst `shouldReturn` 2
      fresh <- open' pg instanceId
      Right resumed <- resume net fresh (config fresh)
      watermark resumed `shouldReturn` 3
      length . placeTokens out <$> marking resumed `shouldReturn` 1
      redelivered <- deliver' resumed "evt_2" 7
      redelivered.occurrence `shouldBe` 2
      length . placeTokens out <$> marking resumed `shouldReturn` 2

-- ---------------------------------------------------------------------------
-- TestDecodeFailsLoudAtLoad

decodeSpec :: SpecWith PostgresTarget
decodeSpec = describe "TestDecodeFailsLoudAtLoad" $
  it "a_row_that_does_not_decode_names_its_event" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      execute_
        pg
        "INSERT INTO impetus.semantic_events (event_id, net_instance_id, record_type, payload) VALUES (%s, %s, %s, %s::jsonb)"
        [textParam (instanceId <> ":0"), textParam instanceId, textParam "Bogus", textParam "{\"record\": \"Bogus\", \"schema\": 2}"]
      open' pg instanceId `shouldThrow` valueErrorMatching [instanceId <> ":0", "Bogus"]

-- ---------------------------------------------------------------------------
-- Beyond upstream

beyondUpstreamSpec :: SpecWith PostgresTarget
beyondUpstreamSpec = describe "beyond upstream" $ do
  it "an autocommit connection gives a backend-owned store, whose batches commit at once" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      history <- open' pg instanceId
      history.mode `shouldBe` BackendOwned
      Store.append history initialized
      transactionStatus pg `shouldReturn` Idle
      withPg target True $ \other -> recordsAt other instanceId `shouldReturn` [initialized]

  it "emits postgres_commit with the batch size and the entered count" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      recorder <- newRecorder
      history <- openPostgresHistoryStoreWith defaultPostgresHistoryOptions {telemetry = Just (recorderSink recorder)} pg instanceId
      history.extend [begun 1 1, completed 1 2]
      Store.append history (completed 1 2)
      events <- recorded recorder
      let shape = [(lookup "event" e, lookup "records" e, lookup "entered" e) | e <- events]
      shape
        `shouldBe` [ (Just (String "impetus_postgres_commit"), Just (Int 2), Just (Int 2))
                   , (Just (String "impetus_postgres_commit"), Just (Int 1), Just (Int 0))
                   ]

  it "refuses an unencodable batch before the connection sees it, with the reference's text" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      history <- open' pg instanceId
      history.extend [begun 1 1, RTokensProduced (TokensProduced place' [Token (Just "x") (Float (0 / 0))] 1 [] Nothing 1)]
        `shouldThrow` (\(HistoryStoreError m) -> m == "cannot durably encode TokensProduced: Out of range float values are not JSON compliant: nan — durable instants, token data, and activity input/result must be JSON-faithful values")
      rows pg instanceId `shouldReturn` []
      Store.size history `shouldReturn` 0

  it "a refused append in join mode leaves the mirror untouched and the caller must roll back" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      open' pg instanceId >>= \h -> h.extend [begun 1 1, completed 1 2]
      withPg target False $ \caller -> do
        stale <- open' caller instanceId
        stale.extend [produced 1 3, failed "different" 1 3] `shouldThrow` valueErrorMatching ["terminal"]
        Store.size stale `shouldReturn` 2
        transactionStatus caller `shouldReturn` InTransaction
        rollback caller
      length <$> rows pg instanceId `shouldReturn` 2

  it "rejects a string holding U+0000 at the server, as jsonb does for the reference" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      history <- open' pg instanceId
      outcome <- try (Store.append history (RTokensInitialized (TokensInitialized place' [Token (Just "x") (String "a\0b")] 0 [] Nothing)))
      case outcome of
        Left (e :: PostgresError) -> errorSqlState e `shouldBe` Just "22P05"
        Right () -> expectationFailure "expected the server to refuse \\u0000"
      Store.size history `shouldReturn` 0

  it "reads jsonb's normalization back as psycopg does (1e16 is an integer)" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      let record = RTokensInitialized (TokensInitialized place' [Token (Just "x") (Float 1e16)] 0 [] Nothing)
      stale <- open' pg instanceId
      open' pg instanceId >>= \h -> Store.append h record
      fresh <- open' pg instanceId
      [RTokensInitialized back] <- Store.records fresh
      map (.payload) back.tokens `shouldBe` [Int 10000000000000000]
      -- The stale writer's identical record verifies equal (1e16 == 10**16).
      Store.append stale record
      Store.size stale `shouldReturn` 1
      length <$> rows pg instanceId `shouldReturn` 1

  it "keeps the event ids dense across many batches" $ \target ->
    withPgConnection target $ \pg -> do
      instanceId <- freshInstance "pg-only"
      history <- open' pg instanceId
      forM_ [1 .. 5 :: Int] $ \n -> history.extend [begun n (fromIntegral n), completed n (fromIntegral n)]
      events <- map (.rowEvent) <$> rows pg instanceId
      events `shouldBe` [instanceId <> ":" <> T.pack (show n) | n <- [0 .. 9 :: Int]]
      sort (Map.keys (Map.fromList [(e, ()) | e <- events])) `shouldBe` sort events
