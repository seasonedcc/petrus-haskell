-- | Parity: @tests/petrus/impetus/instance/test_timers.py@ — per-binding,
-- age-anchored timer maturation over the clock watermark: the timer
-- declarations, record instants, entry instants, the pure maturation unit,
-- timed enabledness, wakeups, watermark advance, and timed status.
--
-- Translation notes. The pure enabledness unit's refusals are typed
-- 'EnablednessError' values ('ClockRequired', 'MisalignedInstants') rather
-- than @ValueError@ texts, so those two cases assert the constructor (the
-- reference's message has no Haskell rendering). The reference's
-- @TimerMatured(...)@ constructor check is 'recordInvariants'.
module Petrus.Impetus.TimersSpec (spec) where

import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text qualified as T
import Petrus.Impetus.DoorSupport
import Petrus.Impetus.History
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.Petrinet qualified as P
import Petrus.Impetus.TestSupport (expectRight, mustNet, np, numberField, obj, shouldFailWith, tok, tokD)
import Petrus.Impetus.TestSupport qualified as TS
import Petrus.Json (Json (..))
import Test.Hspec

pendingP, expire, expired, srcT :: NetPath
pendingP = np "pending"
expire = np "expire"
expired = np "expired"
srcT = np "src"

-- | @pending -> expire -> expired@, with the timers under test on @expire@.
expiryNet :: [Timer] -> Net
expiryNet timers = TS.netOf [place pendingP, place expired] [(transition expire) {timers = timers}] [arc pendingP expire, arc expire expired]

pendingMarking :: Marking
pendingMarking = markingFromList [(pendingP, [black])]

-- | An instance over the expiry net with one black token pending.
expiring :: [Timer] -> IO Instance
expiring timers = mkInstance (expiryNet timers) defaultInstanceConfig {initialMarking = pendingMarking}

clock :: Instant -> [(NetPath, [Instant])] -> Maybe Clock
clock w instants = Just (Clock w (Map.fromList [(p, Seq.fromList is) | (p, is) <- instants]))

ingestNet :: Net
ingestNet = TS.netOf [place (np "inbox")] [transition (np "ingest")] [arc (np "ingest") (np "inbox")]

-- | @src (source) -> pending -> expire (Delay 10) -> expired@.
sourcedExpiry :: Net
sourcedExpiry =
  TS.netOf
    [place pendingP, place expired]
    [transition srcT, (transition expire) {timers = [Delay 10]}]
    [arc srcT pendingP, arc pendingP expire, arc expire expired]

timerMatured :: Record -> Bool
timerMatured = \case
  RTimerMatured _ -> True
  _ -> False

spec :: Spec
spec = describe "Timers" $ do
  describe "timer declarations" $ do
    -- TestTimerDeclarations.test_a_timer_must_be_a_delay_or_an_until:
    -- enforced by types ('Timer' is exactly 'Delay' or 'Until').
    -- TestTimerDeclarations.test_timers_on_a_source_transition_are_rejected
    it "rejects timers on a source transition" $
      mkNet (netSpec [place (np "out")] [(transition srcT) {timers = [Delay 10]}] [arc srcT (np "out")])
        `shouldFailWith` "transition src: timers on a source transition cannot be honored — it fires only on external delivery, never through enabledness; found [Delay(duration=10)]"
    -- TestTimerDeclarations.test_a_delay_with_only_inhibitor_inputs_is_rejected
    it "rejects a delay with only inhibitor inputs" $
      mkNet
        ( netSpec
            [place (np "hold"), place (np "out")]
            [(transition (np "t")) {handler = Just (HandlerSymbol "emit"), timers = [Delay 10]}]
            [(arc (np "hold") (np "t")) {mode = Inhibit}, arc (np "t") (np "out")]
        )
        `shouldFailWith` "transition t: a duration timer has no anchor — every input arc is an inhibitor and absence has no entry instant; declare a consume or read input, or use an absolute Until timer"
    -- TestTimerDeclarations.test_an_until_with_only_inhibitor_inputs_is_legal
    it "admits an until with only inhibitor inputs" $ do
      let net =
            mustNet
              ( netSpec
                  [place (np "hold"), place (np "out")]
                  [(transition (np "t")) {handler = Just (HandlerSymbol "emit"), timers = [Until 100]}]
                  [(arc (np "hold") (np "t")) {mode = Inhibit}, arc (np "t") (np "out")]
              )
      (.timers) <$> lookupTransition (np "t") net `shouldBe` Just [Until 100]

  describe "record instants" $ do
    -- TestRecordInstants.test_construction_stamps_the_initial_records_with_its_instant
    it "stamps the construction records with the construction instant" $ do
      let a = np "a"
      inst <- mkInstance (TS.netOf [place a] [] []) defaultInstanceConfig {initialMarking = markingFromList [(a, [black])], constructionInstant = 5}
      historyRecords inst
        >>= ( `shouldBe`
                [ RInstanceCreated (InstanceCreated (instanceIdentity inst) Nothing 5)
                , RTokensInitialized (TokensInitialized a [black] 5 [] Nothing)
                ]
            )
      watermark inst >>= (`shouldBe` 5)
    -- TestRecordInstants.test_delivery_stamps_the_event_and_its_firing_records
    it "stamps the delivery event and its firing records" $ do
      inst <- mkInstance ingestNet defaultInstanceConfig
      _ <- deliverAt inst (np "ingest") [black] "timed-event" Nothing (Just 3)
      rs <- historyRecords inst
      Set.fromList (map recordInstant rs) `shouldBe` Set.fromList [0, 3]
      watermark inst >>= (`shouldBe` 3)
    -- TestRecordInstants.test_an_earlier_instant_is_clamped_to_the_watermark
    it "clamps an earlier instant to the watermark" $ do
      inst <- mkInstance ingestNet defaultInstanceConfig
      _ <- deliverAt inst (np "ingest") [black] "later-event" Nothing (Just 7)
      firing <- deliverAt inst (np "ingest") [black] "clamped-event" Nothing (Just 2)
      watermark inst >>= (`shouldBe` 7)
      map recordInstant firing.records `shouldSatisfy` all (== 7)
    -- TestRecordInstants.test_no_instant_means_no_advance
    it "advances nothing without an instant" $ do
      inst <- mkInstance ingestNet defaultInstanceConfig
      _ <- deliverAt inst (np "ingest") [black] "advanced-event" Nothing (Just 4)
      firing <- deliver inst (np "ingest") [black] "unstamped-event"
      watermark inst >>= (`shouldBe` 4)
      map recordInstant firing.records `shouldSatisfy` all (== 4)
    -- TestRecordInstants.test_a_maturation_cannot_be_observed_before_it_happened
    it "refuses a maturation observed before it happened" $
      recordInvariants (RTimerMatured (TimerMatured 5 3))
        `shouldFailWith` "timer maturation observed at 3, before its maturation instant 5: a wakeup cannot precede what it observes"
    -- TestRecordInstants.test_replay_rebuilds_the_marking_from_instant_stamped_records
    it "replays the marking from instant-stamped records" $ do
      inst <- mkInstance ingestNet defaultInstanceConfig
      _ <- deliverAt inst (np "ingest") [black] "replay-event" Nothing (Just 9)
      current <- marking inst
      replayMarking <$> historyRecords inst >>= (`shouldBe` Right current)

  describe "entry instants" $ do
    let a = np "a"
        b = np "b"
        instantsOf = fmap (Map.map toList) . entryInstants
    -- TestEntryInstants.test_entry_instants_mirror_the_queues_they_annotate
    it "mirrors the queues they annotate" $
      instantsOf
        [ RTokensInitialized (TokensInitialized a [black, tok "X"] 0 [] Nothing)
        , RTokensProduced (TokensProduced b [tok "Y"] 1 [] Nothing 4)
        , RTokensConsumed (TokensConsumed a [black] 1 [] Nothing 6)
        ]
        `shouldBe` Right (Map.fromList [(a, [0]), (b, [4])])
    -- TestEntryInstants.test_consume_removes_the_front_most_equal_occurrence
    it "removes the front-most equal occurrence on consume" $
      instantsOf
        [ RTokensInitialized (TokensInitialized a [black] 0 [] Nothing)
        , RTokensProduced (TokensProduced a [black] 1 [] Nothing 5)
        , RTokensConsumed (TokensConsumed a [black] 1 [] Nothing 7)
        ]
        `shouldBe` Right (Map.fromList [(a, [5])])

  describe "maturation" $ do
    -- TestMaturation.test_a_delay_matures_at_anchor_plus_duration
    it "matures a delay at anchor plus duration" $
      maturation [Delay 10] (Just 5) `shouldBe` Just 15
    -- TestMaturation.test_an_until_matures_at_its_instant_regardless_of_anchor
    it "matures an until at its instant regardless of anchor" $
      maturation [Until 30] (Just 5) `shouldBe` Just 30
    -- TestMaturation.test_conjunction_matures_when_the_last_timer_does
    it "matures a conjunction when the last timer does" $ do
      maturation [Delay 10, Until 30] (Just 0) `shouldBe` Just 30
      maturation [Delay 50, Until 30] (Just 0) `shouldBe` Just 50
    -- TestMaturation.test_an_until_only_binding_needs_no_anchor
    it "needs no anchor for an until-only binding" $
      maturation [Until 30] Nothing `shouldBe` Just 30
    -- TestMaturation.test_no_timers_means_no_maturation
    it "derives no maturation without timers" $
      maturation [] (Just 0) `shouldBe` Nothing

  describe "timed enabledness" $ do
    -- TestTimedEnabledness.test_a_timed_net_requires_the_clock
    it "requires the clock over a timed net" $
      P.candidates (expiryNet [Delay 10]) pendingMarking noImplementations Nothing `shouldBe` Left ClockRequired
    -- TestTimedEnabledness.test_a_watermark_without_entry_instants_is_rejected
    it "rejects a watermark without entry instants" $
      P.candidates (expiryNet [Delay 10]) pendingMarking noImplementations (clock 99 [])
        `shouldBe` Left (MisalignedInstants expire pendingP 0 0)
    -- TestTimedEnabledness.test_candidates_returns_the_binding_once_matured
    it "returns the binding once matured" $ do
      let net = expiryNet [Delay 10]
      P.candidates net pendingMarking noImplementations (clock 0 [(pendingP, [2])]) `shouldBe` Right []
      map (.transition) <$> P.candidates net pendingMarking noImplementations (clock 12 [(pendingP, [2])])
        `shouldBe` Right [expire]
    -- TestTimedEnabledness.test_an_immature_binding_is_not_enabled
    it "does not enable an immature binding" $ do
      inst <- expiring [Delay 10]
      candidates inst >>= (`shouldBe` [])
      enabledTransitions inst >>= (`shouldBe` [])
    -- TestTimedEnabledness.test_the_binding_matures_delay_after_its_token_entered
    it "matures the binding a delay after its token entered" $ do
      inst <- mkInstance sourcedExpiry defaultInstanceConfig
      _ <- deliverAt inst srcT [black] "delay-anchor" Nothing (Just 4)
      nextMaturation inst >>= (`shouldBe` Just 14)
    -- TestTimedEnabledness.test_a_read_bound_token_anchors_the_binding_like_a_consumed_one
    it "anchors the binding on a read-bound token like a consumed one" $ do
      let config = np "config"
          net =
            TS.netOf
              [place pendingP, place config, place expired]
              [transition srcT, (transition expire) {timers = [Delay 10]}]
              [arc srcT config, arc pendingP expire, (arc config expire) {mode = Read}, arc expire expired]
      inst <- mkInstance net defaultInstanceConfig {initialMarking = pendingMarking, constructionInstant = 2}
      _ <- deliverAt inst srcT [black] "read-anchor" Nothing (Just 8)
      nextMaturation inst >>= (`shouldBe` Just 18)
    -- TestTimedEnabledness.test_a_binding_failing_its_guard_is_not_waiting_on_time
    it "does not wait on time for a binding failing its guard" $ do
      let net =
            TS.netOf
              [place pendingP, place expired]
              [(transition expire) {guards = [GuardSymbol "never"], timers = [Delay 10]}]
              [arc pendingP expire, arc expire expired]
      inst <-
        mkInstance net defaultInstanceConfig {initialMarking = pendingMarking, guardImplementations = symbols [("never", \_ -> Right False)]}
      nextMaturation inst >>= (`shouldBe` Nothing)
    -- TestTimedEnabledness.test_a_guard_failed_head_does_not_hide_a_deeper_bindings_maturation
    it "does not let a guard-failed head hide a deeper binding's maturation" $ do
      let small = tokD "Payment" (obj [("amount", Int 40)])
          big = tokD "Payment" (obj [("amount", Int 150)])
          net =
            TS.netOf
              [place pendingP, place expired]
              [(transition expire) {guards = [GuardSymbol "big"], timers = [Delay 10]}]
              [arc pendingP expire, arc expire expired]
          bigGuard b = case bindingPeeked b of
            t : _ -> (>= 100) <$> numberField "amount" t
            [] -> Left "IndexError('tuple index out of range')"
          impls = TS.impls [] [("big", bigGuard)]
          queued = markingFromList [(pendingP, [small, big])]
      P.candidates net queued impls (clock 12 [(pendingP, [0, 8])]) `shouldBe` Right []
      P.nextMaturation net queued impls (clock 12 [(pendingP, [0, 8])]) `shouldBe` Right (Just 18)
      map bindingTokens <$> P.candidates net queued impls (clock 18 [(pendingP, [0, 8])]) `shouldBe` Right [[big]]
    -- TestTimedEnabledness.test_next_maturation_is_none_when_nothing_waits
    it "derives no next maturation when nothing waits" $ do
      inst <- mkInstance (expiryNet [Delay 10]) defaultInstanceConfig
      nextMaturation inst >>= (`shouldBe` Nothing)
    -- TestTimedEnabledness.test_next_maturation_derives_from_the_supplied_clock
    it "derives the next maturation from the supplied clock" $ do
      let net = expiryNet [Delay 10]
      P.nextMaturation net pendingMarking noImplementations (clock 0 [(pendingP, [2])]) `shouldBe` Right (Just 12)
      P.nextMaturation net pendingMarking noImplementations (clock 12 [(pendingP, [2])]) `shouldBe` Right Nothing

  describe "wakeup" $ do
    -- TestWakeup.test_wake_records_the_derived_maturation_and_enables_the_binding
    it "records the derived maturation and enables the binding" $ do
      inst <- expiring [Delay 10]
      record <- wake inst 10 >>= expectRight
      record `shouldBe` Just (TimerMatured 10 10)
      historyRecords inst >>= (`shouldContain` [RTimerMatured (TimerMatured 10 10)])
      watermark inst >>= (`shouldBe` 10)
      enabledTransitions inst >>= (`shouldBe` [expire])
    -- TestWakeup.test_maturation_enables_but_never_fires
    it "enables on maturation but never fires" $ do
      inst <- expiring [Delay 10]
      _ <- wake inst 10 >>= expectRight
      marking inst >>= (`shouldBe` pendingMarking)
      firing <- step inst Nothing >>= expectRight
      (.transition) <$> firing `shouldBe` Just expire
      marking inst >>= (`shouldBe` markingFromList [(expired, [black])])
    -- TestWakeup.test_a_late_wakeup_is_observed_at_its_own_instant
    it "observes a late wakeup at its own instant" $ do
      inst <- expiring [Delay 10]
      wake inst 13 >>= expectRight >>= (`shouldBe` Just (TimerMatured 10 13))
    -- TestWakeup.test_an_early_wakeup_is_suppressed
    it "suppresses an early wakeup" $ do
      inst <- expiring [Delay 10]
      wake inst 5 >>= expectRight >>= (`shouldBe` Nothing)
      watermark inst >>= (`shouldBe` 0)
      rs <- historyRecords inst
      filter timerMatured rs `shouldBe` []
    -- TestWakeup.test_a_stale_wakeup_after_the_binding_was_consumed_is_harmless
    it "treats a stale wakeup after the binding fired as harmless" $ do
      inst <- expiring [Delay 10]
      _ <- wake inst 10 >>= expectRight
      _ <- step inst Nothing >>= expectRight
      wake inst 20 >>= expectRight >>= (`shouldBe` Nothing)
      status inst >>= (`shouldBe` Terminated)

  describe "watermark advance" $ do
    -- TestWatermarkAdvance.test_an_unrelated_event_matures_the_timed_binding
    it "matures the timed binding on an unrelated event" $ do
      let other = np "other"
          net =
            TS.netOf
              [place pendingP, place other, place expired]
              [transition srcT, (transition expire) {timers = [Delay 10]}]
              [arc srcT other, arc pendingP expire, arc expire expired]
      inst <- mkInstance net defaultInstanceConfig {initialMarking = pendingMarking}
      _ <- deliverAt inst srcT [black] "maturing-event" Nothing (Just 12)
      enabledTransitions inst >>= (`shouldBe` [expire])
      rs <- historyRecords inst
      filter timerMatured rs `shouldBe` []
    -- TestWatermarkAdvance.test_a_step_at_an_instant_proves_time_reached_it
    it "proves time reached the instant of a step" $ do
      inst <- expiring [Delay 10]
      firing <- step inst (Just 15) >>= expectRight
      (.transition) <$> firing `shouldBe` Just expire
      watermark inst >>= (`shouldBe` 15)
    -- TestWatermarkAdvance.test_a_step_that_selects_nothing_advances_nothing
    it "advances nothing on a step that selects nothing" $ do
      inst <- expiring [Delay 10]
      firing <- step inst (Just 5) >>= expectRight
      (.transition) <$> firing `shouldBe` Nothing
      watermark inst >>= (`shouldBe` 0)

  describe "timed status" $ do
    -- TestTimedStatus.test_a_sleeping_instance_is_running
    it "keeps a sleeping instance running" $ do
      inst <- expiring [Delay 10]
      isQuiescent inst >>= (`shouldBe` False)
      status inst >>= (`shouldBe` Running)
    -- TestTimedStatus.test_the_instance_ends_only_after_the_matured_binding_fires
    it "ends only after the matured binding fires" $ do
      inst <- expiring [Delay 10]
      _ <- wake inst 10 >>= expectRight
      status inst >>= (`shouldBe` Running)
      _ <- step inst Nothing >>= expectRight
      status inst >>= (`shouldBe` Terminated)

  describe "ratified scenarios" $ do
    -- TestRatifiedScenarios.test_concurrent_bindings_mature_in_anchor_order
    it "matures concurrent bindings in anchor order" $ do
      inst <- mkInstance sourcedExpiry defaultInstanceConfig
      mapM_
        (\arrival -> deliverAt inst srcT [black] ("arrival-" <> T.pack (show arrival)) Nothing (Just (fromInteger arrival)))
        [1, 2, 3 :: Integer]
      mapM_
        ( \maturity -> do
            nextMaturation inst >>= (`shouldBe` Just maturity)
            wake inst maturity >>= expectRight >>= (`shouldBe` Just (TimerMatured maturity maturity))
            firing <- step inst Nothing >>= expectRight
            (.transition) <$> firing `shouldBe` Just expire
        )
        [11, 12, 13]
      marking inst >>= (`shouldBe` markingFromList [(expired, replicate 3 black)])
      nextMaturation inst >>= (`shouldBe` Nothing)
    -- TestRatifiedScenarios.test_an_until_is_indifferent_to_enablement_churn
    it "keeps an until indifferent to enablement churn" $ do
      let hold = np "hold"
          drain = np "drain"
          net =
            TS.netOf
              [place pendingP, place hold, place expired]
              [transition drain, (transition expire) {timers = [Until 100]}]
              [arc hold drain, arc pendingP expire, (arc hold expire) {mode = Inhibit}, arc expire expired]
      inst <- mkInstance net defaultInstanceConfig {initialMarking = markingFromList [(pendingP, [black]), (hold, [black])]}
      firing <- step inst (Just 50) >>= expectRight
      (.transition) <$> firing `shouldBe` Just drain
      candidates inst >>= (`shouldBe` [])
      nextMaturation inst >>= (`shouldBe` Just 100)
      _ <- wake inst 100 >>= expectRight
      enabledTransitions inst >>= (`shouldBe` [expire])
    -- TestRatifiedScenarios.test_a_refresh_transition_restarts_the_delay_by_minting_a_new_entry
    it "restarts the delay through a refresh transition minting a new entry" $ do
      let refresh = np "refresh"
          net =
            TS.netOf
              [place pendingP, place expired]
              [transition refresh, (transition expire) {timers = [Delay 10]}]
              [arc pendingP refresh, arc refresh pendingP, arc pendingP expire, arc expire expired]
      inst <- mkInstance net defaultInstanceConfig {initialMarking = pendingMarking}
      nextMaturation inst >>= (`shouldBe` Just 10)
      firing <- step inst (Just 5) >>= expectRight
      (.transition) <$> firing `shouldBe` Just refresh
      nextMaturation inst >>= (`shouldBe` Just 15)
