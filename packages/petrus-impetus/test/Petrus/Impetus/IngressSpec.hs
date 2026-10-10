-- | Parity: @tests/petrus/impetus/instance/test_ingress.py@ — external
-- delivery to source transitions: the recorded event fact, the
-- passthrough-or-handler projection, and idempotent acceptance by delivery
-- identity.
--
-- Translation notes. A Python handler is a callable that may record what it
-- saw in a closure; a Haskell 'Handler' is pure, so the handler-observation
-- cases assert the binding /inside/ the handler (a mismatch makes it raise,
-- which the firing would record) and read the call count off History (one
-- firing). The reference's raising handler becomes a handler returning
-- 'Left', which the door reports as 'HandlerRaised'.
module Petrus.Impetus.IngressSpec (spec) where

import Data.Text (Text)
import Petrus.Impetus.Binding
import Petrus.Impetus.DoorSupport
import Petrus.Impetus.History
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport (expectRight, np, obj, shouldFailWith, tokD)
import Petrus.Impetus.TestSupport qualified as TS
import Petrus.Json (Json (..))
import Test.Hspec

payment, signal :: Token
payment = tokD "Payment" (obj [("amount", Int 150), ("currency", String "USD")])
signal = tokD "Signal" (obj [("kind", String "cancel")])

payments, signals, ingest :: NetPath
payments = np "payments"
signals = np "signals"
ingest = np "ingest"

-- | One general source transition demultiplexing mixed events by color.
deliveryNet :: Net
deliveryNet =
  TS.netOf
    [place payments, place signals]
    [transition ingest]
    [withArcColor (Just "Payment") (arc ingest payments), withArcColor (Just "Signal") (arc ingest signals)]

src, out :: NetPath
src = np "src"
out = np "out"

identityNet :: Net
identityNet = TS.netOf [place out] [transition src] [arc src out]

receipts :: NetPath
receipts = np "receipts"

raw, receipt :: Token
raw = tokD "RawEvent" (obj [("body", String "{\"total\": 3}")])
receipt = tokD "Receipt" (obj [("total", Int 3)])

handledNet :: Net
handledNet =
  TS.netOf
    [place receipts]
    [(transition ingest) {handler = Just (HandlerSymbol "parse")}]
    [withArcColor (Just "Receipt") (arc ingest receipts)]

new :: Net -> IO Instance
new net = mkInstance net defaultInstanceConfig

handled :: Handler -> IO Instance
handled h = mkInstance handledNet defaultInstanceConfig {handlerImplementations = pureHandler "parse" h}

delivered :: Text -> NetPath -> [Token] -> Record
delivered ident source tokens = RExternalEventDelivered (ExternalEventDelivered source tokens ident 1 Nothing 0)

isEvent :: Record -> Bool
isEvent = \case
  RExternalEventDelivered _ -> True
  _ -> False

spec :: Spec
spec = describe "Ingress" $ do
  describe "delivery" $ do
    -- TestDelivery.test_delivered_tokens_route_by_color_through_the_output_arcs
    it "routes delivered tokens by color through the output arcs" $ do
      inst <- new deliveryNet
      _ <- deliver inst ingest [payment, signal] "mixed-event"
      marking inst >>= (`shouldBe` markingFromList [(payments, [payment]), (signals, [signal])])
      rs <- historyRecords inst
      rs `shouldContain` [delivered "mixed-event" ingest [payment, signal]]
    -- TestDelivery.test_a_single_token_needs_no_sequence
    it "takes a single token" $ do
      inst <- new deliveryNet
      _ <- deliver inst ingest [payment] "single-event"
      marking inst >>= (`shouldBe` markingFromList [(payments, [payment])])
    -- TestDelivery.test_delivery_records_the_event_then_the_firing_lifecycle
    it "records the event, then the firing lifecycle" $ do
      inst <- new deliveryNet
      _ <- deliver inst ingest [payment] "lifecycle-event"
      historyRecords inst
        >>= ( `shouldBe`
                [ RInstanceCreated (InstanceCreated (instanceIdentity inst) Nothing 0)
                , RDeliveryRegistrationOpened (DeliveryRegistrationOpened ingest "default" Nothing 0)
                , delivered "lifecycle-event" ingest [payment]
                , RFiringBegun (FiringBegun ingest 1 Nothing 0)
                , RTokensProduced (TokensProduced payments [payment] 1 [] Nothing 0)
                , RFiringCompleted (FiringCompleted ingest 1 0)
                ]
            )
    -- TestDelivery.test_the_firing_reports_nothing_consumed
    it "reports nothing consumed" $ do
      inst <- new deliveryNet
      firing <- deliver inst ingest [payment] "firing-event"
      firing.transition `shouldBe` ingest
      firing.consumed `shouldBe` []
      firing.produced `shouldBe` [(payments, payment)]
    -- TestDelivery.test_replay_reapplies_the_recorded_movements
    it "replays the recorded movements" $ do
      inst <- new deliveryNet
      _ <- deliver inst ingest [payment, signal] "replay-event"
      current <- marking inst
      replayMarking <$> historyRecords inst >>= (`shouldBe` Right current)
    -- TestDelivery.test_delivered_tokens_no_arc_admits_are_leftover
    it "leaves delivered tokens no arc admits undeposited" $ do
      inst <- new deliveryNet
      firing <- deliver inst ingest [tokD "Unknown" (obj [("x", Int 1)])] "unknown-event"
      firing.produced `shouldBe` []
      marking inst >>= (`shouldBe` emptyMarking)
      rs <- historyRecords inst
      [() | RTokensProduced _ <- rs] `shouldBe` []
    -- TestDelivery.test_a_supplied_delivery_identity_is_recorded
    it "records the supplied delivery identity" $ do
      inst <- new deliveryNet
      _ <- deliver inst ingest [payment] "evt_123"
      historyRecords inst >>= (`shouldContain` [delivered "evt_123" ingest [payment]])
    -- TestDelivery.test_every_delivery_requires_an_identity_before_recording:
    -- enforced by types ('acceptDelivery' takes a required 'Text' identity;
    -- an omitted or None identity is unrepresentable).
    -- TestDelivery.test_an_empty_identity_is_rejected_before_recording
    it "rejects an empty identity before recording" $ do
      inst <- new deliveryNet
      result <- acceptDelivery inst ingest [payment] "" Nothing Nothing
      result `refusedWith` "delivery to ingest: identity must be a non-empty string of the exact built-in type, got ''"
      rs <- historyRecords inst
      filter isEvent rs `shouldBe` []
    -- TestDelivery.test_delivery_to_a_non_source_transition_is_rejected
    it "rejects delivery to a non-source transition" $ do
      let a = np "a"
          t = np "t"
      inst <- mkInstance (TS.netOf [place a] [transition t] [arc a t]) defaultInstanceConfig {initialMarking = markingFromList [(a, [black])]}
      result <- acceptDelivery inst t [payment] "non-source-event" Nothing Nothing
      result `refusedWith` "cannot deliver to transition t: it has input arcs — only a source transition takes delivery"
    -- TestDelivery.test_delivery_to_an_unknown_transition_is_rejected
    it "rejects delivery to an unknown transition" $ do
      inst <- new deliveryNet
      result <- acceptDelivery inst (np "nowhere") [payment] "unknown-source-event" Nothing Nothing
      result `refusedWith` "cannot deliver to nowhere: not a transition of this net"
    -- TestDelivery.test_an_empty_delivery_is_rejected
    it "rejects an empty delivery" $ do
      inst <- new deliveryNet
      result <- acceptDelivery inst ingest [] "empty-event" Nothing Nothing
      result `refusedWith` "delivery to ingest requires at least one token"
    -- TestDelivery.test_a_non_token_delivery_is_rejected_before_recording:
    -- enforced by types (the delivery is a '[Token]').

  describe "delivery identity enforcement" $ do
    -- TestDeliveryIdentityEnforcement.test_a_redelivered_identity_returns_the_prior_acknowledgement_without_an_append
    it "answers a redelivered identity with the prior acknowledgement, appending nothing" $ do
      inst <- new identityNet
      first <- deliver inst src [payment] "evt_123"
      prior <- historyRecords inst
      acknowledgement <- acceptDelivery inst src [payment] "evt_123" Nothing Nothing >>= expectRight
      acknowledgement `shouldBe` DeliveryPrior (PriorAcknowledgement "evt_123" first.occurrence)
      historyRecords inst >>= (`shouldBe` prior)
      marking inst >>= (`shouldBe` markingFromList [(out, [payment])])
    -- TestDeliveryIdentityEnforcement.test_the_identity_check_precedes_registration_validation
    it "checks the identity before registration validation" $ do
      inst <- new identityNet
      first <- deliver inst src [payment] "evt_123"
      seal inst src Nothing >>= expectRight
      acknowledgement <- acceptDelivery inst src [payment] "evt_123" Nothing Nothing >>= expectRight
      acknowledgement `shouldBe` DeliveryPrior (PriorAcknowledgement "evt_123" first.occurrence)
      result <- acceptDelivery inst src [payment] "evt_124" Nothing Nothing
      result `refusedWith` "cannot deliver to source transition src: no armed delivery registration"
    -- TestDeliveryIdentityEnforcement.test_reusing_an_identity_for_changed_content_or_source_is_a_conflict
    it "refuses identity reuse for changed content or source as a conflict" $ do
      let other = np "other"
      inst <- new (TS.netOf [place out] [transition src, transition other] [arc src out, arc other out])
      _ <- deliver inst src [payment] "evt_123"
      prior <- historyRecords inst
      changed <- acceptDelivery inst src [tokD "Payment" (obj [("amount", Int 8)])] "evt_123" Nothing Nothing
      changed
        `refusedWith` "delivery identity conflict for 'evt_123': recorded source NetPath('src'), scope None; attempted source NetPath('src'), scope None; canonical token content differs"
      moved <- acceptDelivery inst other [payment] "evt_123" Nothing Nothing
      moved
        `refusedWith` "delivery identity conflict for 'evt_123': recorded source NetPath('src'), scope None; attempted source NetPath('other'), scope None; canonical token content matches"
      historyRecords inst >>= (`shouldBe` prior)
    -- TestDeliveryIdentityEnforcement.test_distinct_identities_with_equal_data_are_both_preserved
    it "preserves distinct identities with equal data" $ do
      inst <- new identityNet
      _ <- deliver inst src [payment] "evt_1"
      _ <- deliver inst src [payment] "evt_2"
      rs <- historyRecords inst
      [e.identity | RExternalEventDelivered e <- rs] `shouldBe` ["evt_1", "evt_2"]
      marking inst >>= (`shouldBe` markingFromList [(out, [payment, payment])])
    -- TestDeliveryIdentityEnforcement.test_an_identity_is_accepted_even_when_the_source_projection_fails
    it "keeps an identity accepted when the source projection fails" $ do
      let explode _ _ = Left "projection bug"
          net = TS.netOf [place out] [(transition src) {handler = Just (HandlerSymbol "explode")}] [arc src out]
      inst <- mkInstance net defaultInstanceConfig {handlerImplementations = pureHandler "explode" explode}
      accepted <- accept inst src [payment] "evt_123" Nothing Nothing
      result <- completeDelivery inst accepted Nothing
      result `handlerRaisedWith` "projection bug"
      acknowledgement <- acceptDelivery inst src [payment] "evt_123" Nothing Nothing >>= expectRight
      acknowledgement `shouldBe` DeliveryPrior (PriorAcknowledgement "evt_123" 1)
      rs <- historyRecords inst
      [e.identity | RExternalEventDelivered e <- rs] `shouldBe` ["evt_123"]
    -- TestDeliveryIdentityEnforcement.test_the_accepted_identity_index_rebuilds_at_resume
    -- (the reference's JsonlHistoryStore is only "some durable store" here:
    -- the in-memory store the crashed instance wrote stands in for the file)
    it "rebuilds the accepted identity index at resume" $ do
      store <- Store.inMemoryHistoryStore
      inst <- mkInstance identityNet defaultInstanceConfig {historyStore = Just store}
      first <- deliver inst src [payment] "evt_123"
      resumed <- resume identityNet store defaultInstanceConfig >>= expectRight
      prior <- historyRecords resumed
      acknowledgement <- acceptDelivery resumed src [payment] "evt_123" Nothing Nothing >>= expectRight
      acknowledgement `shouldBe` DeliveryPrior (PriorAcknowledgement "evt_123" first.occurrence)
      historyRecords resumed >>= (`shouldBe` prior)
      conflict <- acceptDelivery resumed src [tokD "Payment" (obj [("amount", Int 8)])] "evt_123" Nothing Nothing
      conflict
        `refusedWith` "delivery identity conflict for 'evt_123': recorded source NetPath('src'), scope None; attempted source NetPath('src'), scope None; canonical token content differs"
      historyRecords resumed >>= (`shouldBe` prior)
    -- TestDeliveryIdentityEnforcement.test_a_trace_with_a_twice_accepted_identity_is_replay_divergence
    it "refuses a trace with a twice-accepted identity as replay divergence" $
      replayAcceptedIdentities
        [ RDeliveryRegistrationOpened (DeliveryRegistrationOpened src "default" Nothing 0)
        , RExternalEventDelivered (ExternalEventDelivered src [payment] "evt_1" 1 Nothing 0)
        , RFiringBegun (FiringBegun src 1 Nothing 0)
        , RExternalEventDelivered (ExternalEventDelivered src [payment] "evt_1" 2 Nothing 0)
        , RFiringBegun (FiringBegun src 2 Nothing 0)
        ]
        `shouldFailWith` "replay divergence: delivery identity 'evt_1' accepted twice — the single writer accepts an identity once and answers redelivery from that accepted fact"

  describe "handled source" $ do
    -- TestHandledSource.test_the_handler_receives_the_delivered_tokens_as_the_binding
    it "hands the handler the delivered tokens as the binding" $ do
      -- The reference appends what the handler saw to a list; this pure
      -- handler refuses any other binding instead, and the single firing
      -- in History is the single call.
      let parse b _
            | bindingTokens b == [raw] = Right (handlerTokens [(receipts, [receipt])])
            | otherwise = Left "unexpected binding"
      inst <- handled parse
      _ <- deliver inst ingest [raw] "handler-binding-event"
      marking inst >>= (`shouldBe` markingFromList [(receipts, [receipt])])
      rs <- historyRecords inst
      [r.occurrence | RFiringCompleted r <- rs] `shouldBe` [1]
    -- TestHandledSource.test_a_handled_delivery_records_the_lifecycle_of_a_local_projection
    it "records the lifecycle of a local projection" $ do
      inst <- handled (\_ _ -> Right (handlerTokens [(receipts, [receipt])]))
      _ <- deliver inst ingest [raw] "handler-lifecycle-event"
      historyRecords inst
        >>= ( `shouldBe`
                [ RInstanceCreated (InstanceCreated (instanceIdentity inst) Nothing 0)
                , RDeliveryRegistrationOpened (DeliveryRegistrationOpened ingest "default" Nothing 0)
                , delivered "handler-lifecycle-event" ingest [raw]
                , RFiringBegun (FiringBegun ingest 1 Nothing 0)
                , RTokensProduced (TokensProduced receipts [receipt] 1 [] Nothing 0)
                , RFiringCompleted (FiringCompleted ingest 1 0)
                ]
            )
    -- TestHandledSource.test_the_handler_result_is_recorded_and_never_rerun
    it "records the handler result and never reruns it" $ do
      -- Replay is a fold over records that takes no handler at all, so it
      -- cannot rerun one; the single firing is the single call.
      inst <- handled (\b _ -> if b.transition == ingest then Right (handlerTokens [(receipts, [receipt])]) else Left "wrong transition")
      _ <- deliver inst ingest [raw] "handler-replay-event"
      current <- marking inst
      rs <- historyRecords inst
      replayMarking rs `shouldBe` Right current
      [r.transition | RFiringBegun r <- rs] `shouldBe` [ingest]
    -- TestHandledSource.test_the_event_is_recorded_before_a_raising_handler_propagates
    it "records the event before a raising handler propagates" $ do
      inst <- handled (\_ _ -> Left "boom")
      accepted <- accept inst ingest [raw] "raising-handler-event" Nothing Nothing
      result <- completeDelivery inst accepted Nothing
      result `handlerRaisedWith` "boom"
      rs <- historyRecords inst
      rs `shouldContain` [delivered "raising-handler-event" ingest [raw]]
      case reverse rs of
        RFiringFailed _ : _ -> pure ()
        other -> expectationFailure ("expected FiringFailed last, got " <> show (take 1 other))
      marking inst >>= (`shouldBe` emptyMarking)
