-- | Parity: @tests/petrus/impetus/history_store/test_history_backends.py@,
-- the backend-contract suite, run against the JSONL backend.
--
-- The reference runs every case against each durable backend through one
-- @reopen@ fixture whose each call loads a FRESH backend over the same
-- storage — the kill-and-reload move. 'backendContract' is that suite over
-- any such factory; this package instantiates it for JSONL (the SQLite
-- store adds its own instantiation next to it).
module Petrus.HistoryStore.BackendContractSpec (spec, backendContract) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Petrus.Activity (ActivityInvocationFields (ActivityInvocationFields), invocation, invocationFields)
import Petrus.HistoryStore.Jsonl (HistoryStoreError (..))
import Petrus.HistoryStore.Support (jsonlReopen, withScratch)
import Petrus.Impetus.History
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.HistorySupport (everyRecordCategory)
import Petrus.Impetus.Binding
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Petrus.Json
import Test.Hspec
import Petrus.TestSupport (valid)

intake, queue, work, out :: NetPath
intake = np "intake"
queue = np "queue"
work = np "work"
out = np "out"

-- | @Charge@: the reference's counting ActivityHandler. Its prepare and
-- project are pure here, so a re-run cannot be counted; 'refusingPrepare'
-- stands in for "prepared == 0" by refusing if it is ever consulted.
charge :: ActivityHandler
charge =
  ActivityHandler
    { prepare = \b -> case bindingTokens b of
        [issue] -> do
          amount <- field "amount" issue
          invocation "charge_card" (Object [("amount", amount)])
        other -> Left ("expected one issue, got " <> T.pack (show other))
    , project = \_ result -> case lookupMember "status" result of
        Just s -> Right (handlerTokens [(out, [tokD "Receipt" (Object [("status", s)])])])
        Nothing -> Left "KeyError('status')"
    , projectFailure = Nothing
    }

-- | A Charge whose prepare must never run (the record supplies the
-- invocation on resume).
refusingPrepare :: ActivityHandler
refusingPrepare = charge {prepare = \_ -> Left "prepare re-ran: the record should have supplied the invocation"}

handlers :: ActivityHandler -> InstanceConfig
handlers h = defaultInstanceConfig {handlerImplementations = Map.fromList [(Symbol "charge", ActivityBound h)]}

-- | @intake (source) -> queue -> work (ActivityHandler) -> out@.
activityNet :: Net
activityNet =
  netOf
    [place queue, place out]
    [transition intake, Transition work (Just (HandlerSymbol "charge")) [] []]
    [arc intake queue, arc queue work, arc work out]

payment :: Token
payment = tokD "Payment" (Object [("amount", Int 100)])

receipt :: Marking
receipt = markingFromList [(out, [tokD "Receipt" (Object [("status", String "captured")])])]

expectOk :: (HasCallStack, Show e) => IO (Either e a) -> IO a
expectOk action = action >>= expectRight

recordsOf :: Instance -> IO [Record]
recordsOf = Store.records . instanceHistory

spec :: Spec
spec = backendContract "jsonl" (\body -> withScratch (body . jsonlReopen))

-- | The suite over a backend: @withReopen@ runs an example with a fresh
-- storage and its @reopen@ factory.
backendContract :: String -> ((IO HistoryStore -> IO ()) -> IO ()) -> Spec
backendContract backend withReopen = describe ("backend contract (" <> backend <> ")") $ do
  describe "round trip" $ do
    -- TestRoundTrip.test_a_store_contains_history_without_being_history
    -- (the isinstance half is enforced by types: a store is one record of
    -- operations, never a subtype of the in-memory one)
    it "a store contains history" $ withReopen $ \reopen -> do
      store <- reopen
      let initialized = RTokensInitialized (TokensInitialized queue [black] 0 [] Nothing)
      Store.append store initialized
      Store.records store `shouldReturn` [initialized]

    -- TestRoundTrip.test_every_record_category_round_trips_value_equal
    it "every record category round-trips value-equal" $ withReopen $ \reopen -> do
      reopen >>= \store -> store.extend everyRecordCategory
      (reopen >>= Store.records) `shouldReturn` everyRecordCategory

    -- TestRoundTrip.test_append_and_extend_accumulate_and_a_reload_continues
    it "append and extend accumulate, and a reload continues" $ withReopen $ \reopen -> do
      history <- reopen
      Store.append history (RTokensInitialized (TokensInitialized queue [black] 0 [] Nothing))
      history.extend [RFiringBegun (FiringBegun work 1 Nothing 1)]
      Store.size history `shouldReturn` 2
      resumed <- reopen
      before' <- Store.records history
      Store.records resumed `shouldReturn` before'
      let later = RTokensProduced (TokensProduced out [black] 1 [] Nothing 2)
      Store.append resumed later
      (reopen >>= Store.records) `shouldReturn` (before' ++ [later])

    -- TestRoundTrip.test_durable_before_in_memory
    it "is durable before in memory" $ withReopen $ \reopen -> do
      history <- reopen
      Store.append history (RTokensInitialized (TokensInitialized queue [black] 0 [] Nothing))
      mirror <- Store.records history
      (reopen >>= Store.records) `shouldReturn` mirror

    -- TestRoundTrip.test_nan_token_data_is_refused_loud_on_both_backends
    -- (the refusal's message is the durable backend's; asserted here is the
    -- kernel's half of the contract: a refused write enters nothing)
    it "a refused (NaN) record fails loud and enters nothing" $ withReopen $ \reopen -> do
      history <- reopen
      Store.append history (RTokensInitialized (TokensInitialized queue [tokD "x" (Float (0 / 0))] 0 [] Nothing))
        `shouldThrow` \(HistoryStoreError m) -> "TokensInitialized" `T.isInfixOf` m
      Store.size history `shouldReturn` 0
      (reopen >>= Store.records) `shouldReturn` []

    -- TestRoundTrip.test_a_mid_batch_encode_failure_writes_nothing (NaN
    -- stands in for the reference's unencodable object())
    it "a mid-batch encode failure writes nothing" $ withReopen $ \reopen -> do
      history <- reopen
      history.extend
        [ RFiringBegun (FiringBegun work 1 Nothing 1)
        , RTokensProduced (TokensProduced out [tokD "x" (Float (1 / 0))] 1 [] Nothing 1)
        ]
        `shouldThrow` \(HistoryStoreError m) -> "TokensProduced" `T.isInfixOf` m
      Store.size history `shouldReturn` 0
      (reopen >>= Store.records) `shouldReturn` []

    -- Beyond the reference's NaN case: every refusal of @json.dumps@ (here an
    -- integer over CPython's 4300-digit limit in token data) fails loud with
    -- the backend's "cannot durably encode" text, on every backend alike,
    -- and leaves the stored history exactly as it was (no blank line, no
    -- partial row), so the next load still succeeds.
    it "an over-long integer fails loud and leaves the history unchanged" $ withReopen $ \reopen -> do
      history <- reopen
      let kept = RTokensInitialized (TokensInitialized queue [black] 0 [] Nothing)
          huge = RTokensProduced (TokensProduced out [tokD "x" (Object [("n", Int (10 ^ (5000 :: Int)))])] 1 [] Nothing 1)
          refusal = "cannot durably encode TokensProduced: " <> T.pack (encodeErrorMessage (IntegerTooLarge maxIntStrDigits)) <> " — durable instants"
      Store.append history kept
      Store.append history huge
        `shouldThrow` \(HistoryStoreError m) -> refusal `T.isPrefixOf` m && "must be JSON-faithful values" `T.isSuffixOf` m
      history.extend [RFiringBegun (FiringBegun work 1 Nothing 1), huge]
        `shouldThrow` \(HistoryStoreError m) -> refusal `T.isPrefixOf` m
      Store.records history `shouldReturn` [kept]
      (reopen >>= Store.records) `shouldReturn` [kept]

  describe "Instance parity" $ do
    let driven reopen = do
          store <- reopen
          inst <- expectOk (newInstance activityNet (handlers charge) {historyStore = Just store})
          answer <- expectOk (acceptDelivery inst intake [payment] "evt_123" Nothing (Just 1))
          accepted <- case answer of
            DeliveryAccepted a -> pure a
            other -> expectationFailure ("expected an accepted delivery, got " <> show other) >> error "unreachable"
          _ <- expectOk (completeDelivery inst accepted (Just 1))
          (b : _) <- candidates inst
          occurrence <- expectOk (begin inst b (Just 2))
          _ <- expectOk (recordActivityCompletion inst occurrence (Object [("status", String "captured")]) (Just 3))
          _ <- expectOk (complete inst occurrence Nothing (Just 4))
          pure (inst, occurrence)
        resumed reopen = reopen >>= \store -> expectOk (resume activityNet store (handlers charge))

    -- TestInstanceParity.test_construction_over_a_recorded_history_is_rejected
    it "construction over a recorded history is rejected" $ withReopen $ \reopen -> do
      store <- reopen
      _ <- expectOk (newInstance activityNet (handlers charge) {historyStore = Just store})
      again <- reopen
      Left (Refused message) <- newInstance activityNet (handlers charge) {historyStore = Just again}
      message
        `shouldBe` "cannot construct an Instance over a recorded history (2 records): construction appends the instance's initial records; a recorded history is for resume()"

    -- TestInstanceParity.test_a_full_drive_kills_and_resumes_identical
    it "a full drive kills and resumes identical" $ withReopen $ \reopen -> do
      (inst, _) <- driven reopen
      recorded <- recordsOf inst
      live <- marking inst
      liveStatus <- status inst
      back <- resumed reopen
      recordsOf back `shouldReturn` recorded
      marking back `shouldReturn` live
      live `shouldBe` receipt
      watermark back `shouldReturn` 4
      status back `shouldReturn` liveStatus

    -- TestInstanceParity.test_the_occurrence_counter_resumes_past_every_recorded_id
    it "the occurrence counter resumes past every recorded id" $ withReopen $ \reopen -> do
      (_, occurrence) <- driven reopen
      back <- resumed reopen
      DeliveryAccepted accepted <- expectOk (acceptDelivery back intake [payment] "evt_456" Nothing Nothing)
      outcome <- expectOk (completeDelivery back accepted Nothing)
      outcome.occurrence `shouldBe` occurrence.occurrence + 1

    -- TestInstanceParity.test_the_accepted_identity_index_resumes_from_the_records
    it "the accepted-identity index resumes from the records" $ withReopen $ \reopen -> do
      (inst, _) <- driven reopen
      [delivered] <- (\rs -> [r | RExternalEventDelivered r <- rs]) <$> recordsOf inst
      back <- resumed reopen
      acknowledgement <- expectOk (acceptDelivery back intake [payment] "evt_123" Nothing Nothing)
      acknowledgement `shouldBe` DeliveryPrior (PriorAcknowledgement "evt_123" delivered.occurrence)
      durable <- reopen >>= Store.records
      recordsOf back `shouldReturn` durable

    -- TestInstanceParity.test_the_terminal_activity_index_resumes_from_the_records
    it "the terminal-activity index resumes from the records" $ withReopen $ \reopen -> do
      (_, occurrence) <- driven reopen
      back <- resumed reopen
      before' <- Store.size (instanceHistory back)
      expectOk (recordActivityCompletion back occurrence (Object [("status", String "captured")]) Nothing)
        `shouldReturn` TerminalAcknowledged
      Store.size (instanceHistory back) `shouldReturn` before'
      Left (Refused message) <- recordActivityCompletion back occurrence (Object [("status", String "declined")]) Nothing
      message
        `shouldBe` "cannot record an activity completion for firing occurrence 2 (work): the occurrence ended with a different result — an operational conflict, not a redelivery"

  describe "kill-window parity" $ do
    let begun reopen = do
          store <- reopen
          inst <-
            expectOk
              ( newInstance
                  activityNet
                  (handlers charge) {historyStore = Just store, initialMarking = markingFromList [(queue, [payment])]}
              )
          (b : _) <- candidates inst
          occurrence <- expectOk (begin inst b (Just 2))
          pure (inst, occurrence)

    -- TestKillWindowParity.test_killed_after_the_begin_batch_resumes_and_redispatches
    it "killed after the begin batch: resumes and redispatches" $ withReopen $ \reopen -> do
      (_, occurrence) <- begun reopen
      back <- reopen >>= \store -> expectOk (resume activityNet store (handlers refusingPrepare))
      [rebuilt] <- inFlight back
      rebuilt `shouldBe` occurrence
      -- ActivityInvocation("charge_card", input={"amount": 100},
      -- correlation="occurrence-1", idempotency="occurrence-1"); built
      -- positionally because correlation/idempotency are also History
      -- record fields (an ambiguous record update).
      let requested = valid (invocation "charge_card" (Object [("amount", Int 100)]))
      fmap invocationFields rebuilt.invocation
        `shouldBe` Just (ActivityInvocationFields requested.activity requested.input requested.policy (Just "occurrence-1") (Just "occurrence-1"))
      _ <- expectOk (recordActivityCompletion back rebuilt (Object [("status", String "captured")]) (Just 9))
      _ <- expectOk (complete back rebuilt Nothing (Just 9))
      -- prepared == 0 is refusingPrepare never refusing; projected == 1 is
      -- the one projected receipt.
      marking back `shouldReturn` receipt

    -- TestKillWindowParity.test_killed_after_the_frozen_result_resumes_projection_pending
    it "killed after the frozen result: resumes projection-pending" $ withReopen $ \reopen -> do
      (inst, occurrence) <- begun reopen
      _ <- expectOk (recordActivityCompletion inst occurrence (Object [("status", String "captured")]) (Just 3))
      back <- reopen >>= \store -> expectOk (resume activityNet store (handlers refusingPrepare))
      [rebuilt] <- inFlight back
      awaiting <- projectionPending back
      map (.occurrence) awaiting `shouldContain` [rebuilt.occurrence]
      firing <- expectOk (complete back rebuilt Nothing (Just 9))
      firing.occurrence `shouldBe` rebuilt.occurrence
      marking back `shouldReturn` receipt
      durable <- reopen >>= Store.records
      recordsOf back `shouldReturn` durable
