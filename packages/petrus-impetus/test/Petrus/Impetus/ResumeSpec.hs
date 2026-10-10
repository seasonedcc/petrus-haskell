-- | Parity: @tests/petrus/impetus/instance/test_resume.py@ — rebuilding a
-- live Instance from its records: the marking, the armed registrations, the
-- watermark, the occurrence counter, and the in-flight occurrences, plus the
-- replay folds those projections are ('replayArmed', 'replayInFlight',
-- 'replayWatermark', 'replayNextOccurrence').
--
-- Translation notes. The reference writes through a @JsonlHistoryStore(path)@
-- and resumes by re-opening the same path. JSONL is a durable backend that
-- lives in another package, so a /durable file/ here is an 'IORef' of
-- records, and re-opening it is 'mirroredHistoryStore' over its current
-- contents with a durable write that appends to the same 'IORef' — the same
-- one-file-before-and-after-the-crash shape, without JSONL's file format.
module Petrus.Impetus.ResumeSpec (spec) where

import Data.IORef
import Data.Text (Text)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Petrus.Impetus.Binding
import Petrus.Impetus.DoorSupport
import Petrus.Impetus.History
import Petrus.Impetus.HistoryStore (Admission (..), CommitMode (..), HistoryStore, mirroredHistoryStore)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Internal.OMap qualified as OMap
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport (expectRight, np, obj, shouldFailWith, tok, tokD)
import Petrus.Impetus.TestSupport qualified as TS
import Petrus.Json (Json (..))
import Test.Hspec

intake, work, queue, out, gate, ghost :: NetPath
intake = np "intake"
work = np "work"
queue = np "queue"
out = np "out"
gate = np "gate"
ghost = np "ghost"

forward :: Handler
forward b _ = Right (HandlerResult [(out, bindingTokens b)] [] [])

-- | @intake (source) -> queue -> work (impure) -> out@.
simpleNet :: Net
simpleNet =
  TS.netOf
    [place queue, place out]
    [transition intake, (transition work) {handler = Just (HandlerSymbol "work")}]
    [arc intake queue, arc queue work, arc work out]

-- | @queue -> work (impure, also reading gate) -> out@.
readingNet :: Net
readingNet =
  TS.netOf
    [place queue, place gate, place out]
    [(transition work) {handler = Just (HandlerSymbol "work")}]
    [arc queue work, (arc gate work) {mode = Read}, arc work out]

-- | @handlers={"work": h}@.
workConfig :: Handler -> InstanceConfig
workConfig h = defaultInstanceConfig {handlerImplementations = pureHandler "work" h}

-- | The complete prefix the live writer emits for @net@.
constructionRecords :: Net -> Marking -> IO [Record]
constructionRecords net m =
  mkInstance net (workConfig forward) {initialMarking = m, suppliedIdentity = Just "resume-test"} >>= historyRecords

-- | A durable file standing in for the reference's JSONL path.
newtype DurableFile = DurableFile (IORef [Record])

newFile :: IO DurableFile
newFile = DurableFile <$> newIORef []

-- | @JsonlHistoryStore(path)@: a store over the file's current contents whose
-- durable write appends to the file.
open :: DurableFile -> IO HistoryStore
open (DurableFile ref) = do
  loaded <- readIORef ref
  mirroredHistoryStore BackendOwned (Seq.fromList loaded) $ \batch -> do
    modifyIORef' ref (<> batch)
    pure (map (const Entered) batch)

-- | @Instance(net, handlers=..., history=JsonlHistoryStore(path))@.
liveOn :: DurableFile -> Net -> InstanceConfig -> IO Instance
liveOn file net cfg = do
  store <- open file
  mkInstance net cfg {historyStore = Just store}

-- | @Instance.resume(net, JsonlHistoryStore(path), ...)@.
resumeFrom :: HasCallStack => DurableFile -> Net -> InstanceConfig -> IO Instance
resumeFrom file net cfg = open file >>= \store -> resume net store cfg >>= expectRight

-- | @Instance.resume(net, history, handlers={"work": forward})@ over records,
-- expected to succeed or refuse.
resumeRecords :: Net -> [Record] -> IO (Either InstanceError Instance)
resumeRecords net rs = storeOf rs >>= \store -> resume net store (workConfig forward)

completeWith :: Instance -> FiringOccurrence -> [(NetPath, [Token])] -> Maybe Instant -> IO FiringOutcome
completeWith inst o tokens at = complete inst o (Just (HandlerResult tokens [] [])) at >>= expectRight

selected :: NetPath -> Int -> Instant -> Record
selected t o i = RCandidateSelected (CandidateSelected t o i)

begun :: NetPath -> Int -> Instant -> Record
begun t o i = RFiringBegun (FiringBegun t o Nothing i)

consumedFrom :: NetPath -> [Token] -> Int -> Instant -> Record
consumedFrom p ts o i = RTokensConsumed (TokensConsumed p ts o [] Nothing i)

readFrom :: NetPath -> [Token] -> Int -> Instant -> Record
readFrom p ts o i = RTokensRead (TokensRead p ts o [] Nothing i)

producedTo :: NetPath -> [Token] -> Int -> Instant -> Record
producedTo p ts o i = RTokensProduced (TokensProduced p ts o [] Nothing i)

delivered :: NetPath -> [Token] -> Text -> Int -> Instant -> Record
delivered s ts identity o i = RExternalEventDelivered (ExternalEventDelivered s ts identity o Nothing i)

opened, closed :: NetPath -> Text -> Maybe Int -> Instant -> Record
opened s k o i = RDeliveryRegistrationOpened (DeliveryRegistrationOpened s k o i)
closed s k o i = RDeliveryRegistrationClosed (DeliveryRegistrationClosed s k o i)

completed :: NetPath -> Int -> Instant -> Record
completed t o i = RFiringCompleted (FiringCompleted t o i)

failed :: NetPath -> Text -> Int -> Instant -> Record
failed t e o i = RFiringFailed (FiringFailed t e o i)

queued :: Marking
queued = markingFromList [(queue, [black])]

issue :: Token
issue = tokD "issue" (obj [("id", String "goose")])

settings :: Token
settings = tokD "Config" (obj [("mode", String "strict")])

spec :: Spec
spec = describe "Resume" $ do
  describe "resume" $ do
    -- TestResume.test_resume_rebuilds_marking_watermark_and_continues_the_file
    it "rebuilds marking and watermark and continues the same durable record" $ do
      file <- newFile
      inst <- liveOn file simpleNet (workConfig forward)
      _ <- deliverAt inst intake [black] "resume-event" Nothing (Just 3)
      resumed <- resumeFrom file simpleNet (workConfig forward)
      marking resumed >>= (`shouldBe` queued)
      marking inst >>= (`shouldBe` queued)
      watermark resumed >>= (`shouldBe` 3)
      (,) <$> status resumed <*> status inst >>= \(a, b) -> a `shouldBe` b
      firing <- step resumed (Just 5) >>= expectRight
      (.transition) <$> firing `shouldBe` Just work
      marking resumed >>= (`shouldBe` markingFromList [(out, [black])])
      reopened <- open file >>= Store.records
      historyRecords resumed >>= (`shouldBe` reopened)
    -- TestResume.test_resume_never_reuses_a_recorded_occurrence_id
    it "never reuses a recorded occurrence id" $ do
      file <- newFile
      inst <- liveOn file simpleNet (workConfig forward)
      _ <- deliver inst intake [black] "before-resume"
      _ <- run inst >>= expectRight
      resumed <- resumeFrom file simpleNet (workConfig forward)
      firing <- deliver resumed intake [black] "after-resume"
      firing.occurrence `shouldBe` 3
    -- TestResume.test_resume_rebuilds_the_armed_registrations
    it "rebuilds the armed registrations" $ do
      let refresh b _ = Right (HandlerResult [(out, bindingTokens b)] [DeliveryRegistration intake "hook"] [DeliveryRegistration intake "default"])
      file <- newFile
      inst <- liveOn file simpleNet (workConfig refresh)
      _ <- deliver inst intake [black] "refresh-event"
      _ <- run inst >>= expectRight
      resumed <- resumeFrom file simpleNet (workConfig refresh)
      seal resumed intake Nothing >>= expectRight
      rs <- historyRecords resumed
      last rs `shouldBe` closed intake "hook" Nothing 0
      acceptDelivery resumed intake [black] "after-refresh-seal" Nothing Nothing
        >>= (`refusedWith` "cannot deliver to source transition intake: no armed delivery registration")
    -- TestResume.test_resume_after_seal_takes_no_delivery
    it "takes no delivery after a seal" $ do
      file <- newFile
      inst <- liveOn file simpleNet (workConfig forward)
      seal inst intake Nothing >>= expectRight
      resumed <- resumeFrom file simpleNet (workConfig forward)
      acceptDelivery resumed intake [black] "after-seal" Nothing Nothing
        >>= (`refusedWith` "cannot deliver to source transition intake: no armed delivery registration")
    -- TestResume.test_resume_rebuilds_an_in_flight_occurrence_a_driver_can_complete
    it "rebuilds an in-flight occurrence a driver can complete" $ do
      file <- newFile
      inst <- liveOn file simpleNet (workConfig forward)
      _ <- deliverAt inst intake [black] "in-flight-completion" Nothing (Just 3)
      b <- head' <$> candidates inst
      o <- begin inst b (Just 4) >>= expectRight
      resumed <- resumeFrom file simpleNet (workConfig forward)
      inFlight resumed >>= (`shouldBe` [o])
      status resumed >>= (`shouldBe` Running)
      firing <- completeWith resumed o [(out, bindingTokens o.binding)] (Just 9)
      firing.occurrence `shouldBe` o.occurrence
      marking resumed >>= (`shouldBe` markingFromList [(out, [black])])
      watermark resumed >>= (`shouldBe` 9)
    -- TestResume.test_resume_rebuilds_an_in_flight_occurrence_a_driver_can_fail
    it "rebuilds an in-flight occurrence a driver can fail" $ do
      file <- newFile
      inst <- liveOn file simpleNet (workConfig forward)
      _ <- deliver inst intake [black] "in-flight-failure"
      b <- head' <$> candidates inst
      _ <- begin inst b Nothing >>= expectRight
      resumed <- resumeFrom file simpleNet (workConfig forward)
      rebuilt <- single =<< inFlight resumed
      failFiring resumed rebuilt (FailureText "crashed worker never reported") Nothing >>= expectRight
      rs <- historyRecords resumed
      last rs `shouldSatisfy` \case
        RFiringFailed _ -> True
        _ -> False
      inFlight resumed >>= (`shouldBe` [])
    -- TestResume.test_a_rebuilt_delivered_occurrence_carries_its_delivered_tokens
    it "rebuilds a delivered occurrence carrying its delivered tokens" $ do
      prefix <- constructionRecords simpleNet emptyMarking
      resumed <- resumeRecords simpleNet (prefix <> [delivered intake [issue] "occurrence-1" 1 2, begun intake 1 2]) >>= expectRight
      rebuilt <- single =<< inFlight resumed
      rebuilt.binding.delivered `shouldBe` [issue]
      rebuilt.binding.consumed `shouldBe` []
      _ <- completeWith resumed rebuilt [(queue, [issue])] Nothing
      marking resumed >>= (`shouldBe` markingFromList [(queue, [issue])])
    -- TestResume.test_an_orphan_initiation_is_not_in_flight_but_its_id_never_re_mints
    it "keeps an orphan initiation out of flight but never re-mints its id" $ do
      prefix <- constructionRecords simpleNet queued
      resumed <- resumeRecords simpleNet (prefix <> [selected work 1 1]) >>= expectRight
      inFlight resumed >>= (`shouldBe` [])
      firing <- step resumed Nothing >>= expectRight
      (.occurrence) <$> firing `shouldBe` Just 2
    -- TestResume.test_resume_restores_a_pending_delay_and_wakes_it
    it "restores a pending delay and wakes it" $ do
      let start = np "start"
          expire = np "expire"
          net = TS.netOf [place start, place out] [(transition expire) {timers = [Delay 5]}] [arc start expire, arc expire out]
      file <- newFile
      _ <- liveOn file net defaultInstanceConfig {initialMarking = markingFromList [(start, [black])]}
      resumed <- resumeFrom file net defaultInstanceConfig
      nextMaturation resumed >>= (`shouldBe` Just 5)
      step resumed Nothing >>= expectRight >>= (`shouldBe` Nothing) . fmap (.transition)
      wake resumed 5 >>= expectRight >>= (`shouldSatisfy` (/= Nothing))
      firing <- step resumed Nothing >>= expectRight
      (.transition) <$> firing `shouldBe` Just expire
      marking resumed >>= (`shouldBe` markingFromList [(out, [black])])
    -- TestResume.test_resume_rejects_an_empty_history
    it "rejects an empty history" $
      resumeRecords simpleNet []
        >>= (`refusedWith` "cannot resume from an empty history: nothing is recorded — construct an Instance instead")
    -- TestResume.test_resume_rejects_token_records_on_a_foreign_place
    it "rejects token records on a foreign place" $ do
      prefix <- constructionRecords simpleNet emptyMarking
      resumeRecords simpleNet (prefix <> [producedTo ghost [black] 1 0])
        >>= (`refusedWith` "cannot resume: token records on ghost: not a place of this net")
    -- TestResume.test_resume_rejects_a_non_monotone_history
    it "rejects a non-monotone history" $ do
      prefix <- constructionRecords simpleNet emptyMarking
      resumeRecords simpleNet (prefix <> [selected work 1 10, selected work 2 5])
        >>= (`refusedWith` "replay divergence: instant 5 steps backwards past 10: the single writer appends monotone instants")
    -- TestResume.test_resume_rejects_a_scheduled_selection_on_a_source
    it "rejects a scheduled selection on a source" $ do
      prefix <- constructionRecords simpleNet emptyMarking
      resumeRecords simpleNet (prefix <> [selected intake 1 1, begun intake 1 1])
        >>= (`refusedWith` "cannot resume firing occurrence 1 (intake): a scheduled selection on a source transition — a source fires only through accept_delivery()")
    -- TestResume.test_resume_rejects_a_delivery_on_a_non_source
    it "rejects a delivery on a non-source" $ do
      prefix <- constructionRecords simpleNet emptyMarking
      resumeRecords simpleNet (prefix <> [delivered work [black] "occurrence-1" 1 1, begun work 1 1])
        >>= (`refusedWith` "cannot resume firing occurrence 1 (work): an external event on a transition with input arcs — only a source transition takes delivery")
    -- TestResume.test_resume_rejects_consumed_records_that_do_not_match_the_consume_arcs
    it "rejects consumed records that do not match the consume arcs" $ do
      prefix <- constructionRecords simpleNet queued
      resumeRecords simpleNet (prefix <> [selected work 1 1, begun work 1 1])
        >>= (`refusedWith` "cannot resume firing occurrence 1 (work): its consume selections do not match the transition's consume arcs — a live begin takes one consume selection per arc, in input-arc order, weight tokens each")
    -- TestResume.test_resume_rejects_a_registration_on_a_foreign_node
    it "rejects a registration on a foreign node" $ do
      prefix <- constructionRecords simpleNet queued
      resumeRecords
        simpleNet
        (prefix <> [selected work 1 1, begun work 1 1, consumedFrom queue [black] 1 1, opened ghost "default" (Just 1) 2, completed work 1 2])
        >>= (`refusedWith` "cannot resume: delivery-registration records on ghost: not a transition of this net")
    -- TestResume.test_resume_rejects_a_registration_on_a_non_source
    it "rejects a registration on a non-source" $ do
      prefix <- constructionRecords simpleNet queued
      resumeRecords
        simpleNet
        (prefix <> [selected work 1 1, begun work 1 1, consumedFrom queue [black] 1 1, opened work "default" (Just 1) 2, completed work 1 2])
        >>= (`refusedWith` "cannot resume: delivery-registration records on transition work: it has input arcs — only a source transition has delivery registrations")
    -- TestResume.test_resume_rejects_an_in_flight_occurrence_on_a_foreign_transition
    it "rejects an in-flight occurrence on a foreign transition" $ do
      prefix <- constructionRecords simpleNet emptyMarking
      resumeRecords simpleNet (prefix <> [selected ghost 1 0, begun ghost 1 0])
        >>= (`refusedWith` "cannot resume firing occurrence 1 (ghost): not a transition of this net")
    -- TestResume.test_resume_rebuilds_an_in_flight_occurrence_with_its_recorded_read_selections
    it "rebuilds an in-flight occurrence with its recorded read selections" $ do
      file <- newFile
      inst <- liveOn file readingNet (workConfig forward) {initialMarking = markingFromList [(queue, [black]), (gate, [settings])]}
      b <- head' <$> candidates inst
      o <- begin inst b (Just 2) >>= expectRight
      resumed <- resumeFrom file readingNet (workConfig forward)
      inFlight resumed >>= (`shouldBe` [o])
      rebuilt <- single =<< inFlight resumed
      rebuilt.binding.read `shouldBe` [(gate, [settings])]
      firing <- completeWith resumed rebuilt [(out, bindingTokens rebuilt.binding)] (Just 3)
      firing.occurrence `shouldBe` o.occurrence
      marking resumed >>= (`shouldBe` markingFromList [(gate, [settings]), (out, [black])])
    -- TestResume.test_resume_rejects_read_records_that_do_not_match_the_read_arcs
    it "rejects read records that do not match the read arcs" $ do
      prefix <- constructionRecords readingNet (markingFromList [(queue, [black]), (gate, [black])])
      resumeRecords readingNet (prefix <> [selected work 1 1, begun work 1 1, consumedFrom queue [black] 1 1])
        >>= (`refusedWith` "cannot resume firing occurrence 1 (work): its read selections do not match the transition's read arcs — a live begin takes one read selection per arc, in input-arc order, weight tokens each")
    -- TestResume.test_resume_rejects_a_consume_record_count_that_disagrees_with_the_arc_weight
    it "rejects a consume record count that disagrees with the arc weight" $ do
      let a = np "a"
          t = np "t"
          b = np "b"
          net = TS.netOf [place a, place b] [transition t] [(arc a t) {weight = 2}, arc t b]
      prefix <- constructionRecords net (markingFromList [(a, [black, black])])
      store <- storeOf (prefix <> [selected t 1 1, begun t 1 1, consumedFrom a [black] 1 1])
      resume net store defaultInstanceConfig
        >>= (`refusedWith` "cannot resume firing occurrence 1 (t): its consume selections do not match the transition's consume arcs — a live begin takes one consume selection per arc, in input-arc order, weight tokens each")
    -- TestResume.test_resume_rejects_a_read_record_count_that_disagrees_with_the_arc_weight
    it "rejects a read record count that disagrees with the arc weight" $ do
      let config = tok "Config"
      prefix <- constructionRecords readingNet (markingFromList [(queue, [black]), (gate, [config, config])])
      resumeRecords
        readingNet
        (prefix <> [selected work 1 1, begun work 1 1, consumedFrom queue [black] 1 1, readFrom gate [config, config] 1 1])
        >>= (`refusedWith` "cannot resume firing occurrence 1 (work): its read selections do not match the transition's read arcs — a live begin takes one read selection per arc, in input-arc order, weight tokens each")

  describe "replayArmed" $ do
    let armedOf rs = fmap OMap.toList (replayArmed rs)
    -- TestReplayArmed.test_folds_opens_and_closes_in_order
    it "folds opens and closes in order" $
      armedOf
        [ opened intake "default" Nothing 0
        , begun work 1 1
        , closed intake "default" (Just 1) 1
        , opened intake "hook" (Just 1) 1
        , completed work 1 1
        ]
        `shouldBe` Right [(intake, Set.fromList ["hook"])]
    -- TestReplayArmed.test_a_source_closed_to_nothing_stays_present_and_empty
    it "keeps a source closed to nothing present and empty" $
      armedOf [opened intake "default" Nothing 0, closed intake "default" Nothing 1]
        `shouldBe` Right [(intake, Set.empty)]
    -- TestReplayArmed.test_an_open_of_an_armed_key_is_replay_divergence
    it "treats an open of an armed key as replay divergence" $
      armedOf [opened intake "default" Nothing 0, opened intake "default" Nothing 1]
        `shouldFailWith` "replay divergence: delivery registration 'default' on intake opened while armed"
    -- TestReplayArmed.test_a_close_of_an_unarmed_key_is_replay_divergence
    it "treats a close of an unarmed key as replay divergence" $
      armedOf [closed intake "default" Nothing 0]
        `shouldFailWith` "replay divergence: delivery registration 'default' on intake closed while not armed"

  describe "replayInFlight" $ do
    -- TestReplayInFlight.test_rebuilds_begun_occurrences_with_their_consumed_selections_in_order
    it "rebuilds begun occurrences with their consumed selections in order" $ do
      let other = np "other"
          rs = [selected work 1 1, begun work 1 1, consumedFrom queue [tok "a"] 1 1, consumedFrom other [tok "b"] 1 1]
      o <- expectRight (replayInFlight rs) >>= single
      o.occurrence `shouldBe` 1
      o.binding.transition `shouldBe` work
      o.binding.consumed `shouldBe` [(queue, [tok "a"]), (other, [tok "b"])]
      o.records `shouldBe` drop 1 rs
    -- TestReplayInFlight.test_ended_occurrences_are_not_in_flight
    it "keeps ended occurrences out of flight" $
      replayInFlight [selected work 1 1, begun work 1 1, completed work 1 2, selected work 2 3, begun work 2 3, failed work "boom" 2 4]
        `shouldBe` Right []
    -- TestReplayInFlight.test_rebuilds_a_begun_occurrence_with_its_recorded_read_selections
    it "rebuilds a begun occurrence with its recorded read selections" $ do
      let rs = [selected work 1 1, begun work 1 1, consumedFrom queue [black] 1 1, readFrom gate [settings] 1 1]
      o <- expectRight (replayInFlight rs) >>= single
      o.binding.consumed `shouldBe` [(queue, [black])]
      o.binding.read `shouldBe` [(gate, [settings])]
      o.records `shouldBe` drop 1 rs
    -- TestReplayInFlight.test_a_delivered_occurrence_rebuilds_with_its_delivered_tokens
    it "rebuilds a delivered occurrence with its delivered tokens" $ do
      o <- expectRight (replayInFlight [delivered intake [issue] "occurrence-1" 1 1, begun intake 1 1]) >>= single
      o.binding.delivered `shouldBe` [issue]
      o.binding.consumed `shouldBe` []
    -- TestReplayInFlight.test_an_initiation_alone_is_not_in_flight
    it "keeps an initiation alone out of flight" $
      replayInFlight [selected work 1 1] `shouldBe` Right []
    -- TestReplayInFlight.test_a_consume_with_no_begun_boundary_is_replay_divergence
    it "treats a consume with no begun boundary as replay divergence" $
      replayInFlight [consumedFrom queue [black] 1 1]
        `shouldFailWith` "replay divergence: tokens consumed from queue for firing occurrence 1 with no begun boundary"
    -- TestReplayInFlight.test_a_begun_boundary_with_no_initiation_is_replay_divergence
    it "treats a begun boundary with no initiation as replay divergence" $
      replayInFlight [begun work 1 1]
        `shouldFailWith` "replay divergence: firing occurrence 1 (work) begun with no initiation record"
    -- TestReplayInFlight.test_end_records_with_no_terminal_boundary_are_a_torn_batch
    it "treats end records with no terminal boundary as a torn batch" $
      replayInFlight [selected work 1 1, begun work 1 1, consumedFrom queue [black] 1 1, producedTo out [black] 1 2]
        `shouldFailWith` "replay divergence: firing occurrence 1 (work) carries end records with no terminal boundary — a torn commit batch"

  describe "replayWatermark" $ do
    let initialized i = RTokensInitialized (TokensInitialized queue [black] i [] Nothing)
    -- TestReplayWatermark.test_the_watermark_is_the_last_records_instant
    it "is the last record's instant" $
      replayWatermark [initialized 0, selected work 1 7] `shouldBe` Right 7
    -- TestReplayWatermark.test_a_backwards_instant_is_replay_divergence
    it "treats a backwards instant as replay divergence" $
      replayWatermark [initialized 10, selected work 1 5]
        `shouldFailWith` "replay divergence: instant 5 steps backwards past 10: the single writer appends monotone instants"
    -- TestReplayWatermark.test_an_empty_history_proves_no_watermark
    it "proves no watermark from an empty history" $
      replayWatermark ([] :: [Record]) `shouldFailWith` "an empty history proves no watermark"

  describe "replayNextOccurrence" $ do
    -- TestReplayNextOccurrence.test_an_orphan_initiations_id_is_spent
    it "spends an orphan initiation's id" $
      replayNextOccurrence [selected work 3 1] `shouldBe` 4
    -- TestReplayNextOccurrence.test_none_correlations_spend_nothing
    it "spends nothing on absent correlations" $
      replayNextOccurrence [opened intake "default" Nothing 0] `shouldBe` 1
    -- TestReplayNextOccurrence.test_a_stray_terminal_records_id_is_spent
    it "spends a stray terminal record's id" $
      replayNextOccurrence [failed work "stray" 7 1] `shouldBe` 8
  where
    head' = \case
      x : _ -> x
      [] -> error "expected a candidate"
    single = \case
      [x] -> pure x
      xs -> expectationFailure ("expected exactly one, got " <> show (length xs)) >> error "unreachable"
