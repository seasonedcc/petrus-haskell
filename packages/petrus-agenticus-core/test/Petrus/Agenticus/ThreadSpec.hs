-- | Ports of @tests/petrus/agenticus/thread/test_continuation.py@ and
-- @thread/test_identity_and_lifecycle.py@.
module Petrus.Agenticus.ThreadSpec (spec) where

import Control.Monad (forM_)
import Data.Foldable (toList)
import Data.IORef
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Catalog.Result
import Petrus.Agenticus.Error
import Petrus.Agenticus.Program.Descriptor
import Petrus.Agenticus.Support
import Petrus.Agenticus.Thread.Continuation
import Petrus.Agenticus.Thread.Identity
import Petrus.Agenticus.Thread.Lifecycle
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Test.Hspec

ident :: DescriptorKind -> Text -> DescriptorIdentity
ident k n = descriptorIdentity k n 1

programOf :: Text -> Text -> AgentProgramDescriptor
programOf name continuationName =
  let p = ident KindProgram name
      c = ident KindContinuation continuationName
   in agentProgramDescriptor p HarnessOwned True [continuationRequirement c p] (Just c) False False

contDescriptor :: Text -> Text -> ContinuationDescriptor
contDescriptor name programName = continuationDescriptor (ident KindContinuation name) (ident KindProgram programName)

cont :: Text -> Text -> ContinuationDescriptor -> Text -> Continuation
cont i t d ref = expectRight (newContinuation (literalContinuationId i) (literalThreadId t) d ref)

programId, continuationIdentity :: DescriptorIdentity
programId = ident KindProgram "harness.pi-core"
continuationIdentity = ident KindContinuation "pi.core-context"

piProgram :: AgentProgramDescriptor
piProgram =
  agentProgramDescriptor
    programId
    HarnessOwned
    True
    [continuationRequirement continuationIdentity programId]
    (Just continuationIdentity)
    False
    False

piDescriptor :: ContinuationDescriptor
piDescriptor = continuationDescriptor continuationIdentity programId

budget2 :: EpisodeBudget
budget2 = episodeBudget 2 2

plainProgram :: AgentProgramDescriptor
plainProgram = expectRight (simpleProgram programId HarnessOwned)

runtimeId :: Text -> DescriptorIdentity
runtimeId = ident KindRuntime

thread0 :: Text -> Maybe Continuation -> Thread
thread0 t c = expectRight (newThread (literalThreadId t) c)

eid :: Text -> EpisodeId
eid = literalEpisodeId

tid :: Text -> TurnId
tid = literalTurnId

encodeSorted :: Json -> Text
encodeSorted = either (error . show) id . J.dumpsText J.defaultDumps {J.sortKeys = True}

spec :: Spec
spec = do
  describe "thread/test_continuation.py" $ do
    it "test_compatibility_table_never_infers_cross_program_portability" $ do
      let programs =
            [ programOf "amp.provider" "amp.thread"
            , programOf "pi.harness" "pi.session-jsonl"
            , programOf "impetus.net" "impetus.marking-projection"
            ]
          continuations =
            [ contDescriptor "amp.thread" "amp.provider"
            , contDescriptor "pi.session-jsonl" "pi.harness"
            , contDescriptor "impetus.marking-projection" "impetus.net"
            ]
          table = [[compatible (checkContinuationCompatibility p (Just c)) | c <- continuations] | p <- programs]
      table `shouldBe` [[True, False, False], [False, True, False], [False, False, True]]

    it "test_program_that_requires_a_continuation_refuses_a_fresh_start" $ do
      let d = agentProgramDescriptor (ident KindProgram "provider.resume-only") ProviderOwned False [] Nothing False False
          r = checkContinuationCompatibility d Nothing
      compatible r `shouldBe` False
      [(i.code, i.subject) | i <- r.issues] `shouldBe` [("continuation-required", "provider.resume-only")]

    it "test_incompatible_continuation_fails_typed_before_codec_or_execution" $ do
      let ampDescriptor = contDescriptor "amp.thread" "amp.provider"
          ampContinuation = cont "continuation-amp-1" "thread-1" ampDescriptor "opaque:amp:thread-9"
          piDesc = contDescriptor "pi.session-jsonl" "pi.harness"
          th = thread0 "thread-1" (Just ampContinuation)
          piHarness = programOf "pi.harness" "pi.session-jsonl"
      loads <- newIORef (0 :: Int)
      executions <- newIORef (0 :: Int)
      let codec =
            ContinuationCodec
              { descriptor = piDesc
              , load = \c -> do
                  modifyIORef' loads (+ 1)
                  pure c.stateReference
              }
      T.isInfixOf "opaque:amp:thread-9" (T.pack (show ampContinuation)) `shouldBe` False
      case startEpisode (eid "episode-1") piHarness (runtimeId "pi.application-owned") (episodeBudget 2 2) th of
        Right _ -> do
          _ <- codec.load ampContinuation
          modifyIORef' executions (+ 1)
          expectationFailure "expected IncompatibleContinuation"
        Left e -> do
          e.errorClass `shouldBe` IncompatibleContinuation
          e `shouldSatisfy` (`isInstanceOf` ValueError)
          e.errorMessage `shouldBe` "Continuation is incompatible with Agent Program: continuation-not-accepted"
      readIORef executions `shouldReturn` 0
      readIORef loads `shouldReturn` 0
      resultToData (threadContinuationCompatibility piHarness th)
        `shouldBe` Object
          [ ("schema_version", Int 1)
          , ("candidate", identityToData (ident KindProgram "pi.harness"))
          , ("issues", Array [Object [("code", String "continuation-not-accepted"), ("subject", String "amp.thread")]])
          ]
      -- The typed refusal carries the same result.
      case requireContinuationCompatible piHarness (Just ampDescriptor) of
        Left refusal -> do
          refusal.result `shouldBe` threadContinuationCompatibility piHarness th
          incompatibleContinuationError refusal `shouldBe` agenticusError IncompatibleContinuation "Continuation is incompatible with Agent Program: continuation-not-accepted"
        Right () -> expectationFailure "expected a refusal"

    it "test_explicit_migration_requirement_can_accept_another_programs_continuation" $ do
      let source = ident KindProgram "provider.native"
          c = ident KindContinuation "provider.native-thread"
          migration =
            agentProgramDescriptor
              (ident KindProgram "harness.migration")
              HarnessOwned
              False
              [continuationRequirement c source]
              Nothing
              False
              False
      compatible (checkContinuationCompatibility migration (Just (continuationDescriptor c source))) `shouldBe` True
      let mismatch =
            checkContinuationCompatibility
              migration
              (Just (continuationDescriptor c (ident KindProgram "provider.lookalike")))
      compatible mismatch `shouldBe` False
      map (.code) mismatch.issues `shouldBe` ["continuation-program-mismatch"]

    it "test_continuation_revision_can_be_claimed_only_once" $ do
      let c = cont "continuation-once" "thread-once" (contDescriptor "pi.session-jsonl" "pi.harness") "opaque:pi:once"
          claimed = expectRight (claimContinuation c)
      claimContinuation claimed `shouldRaiseMatching'` (ContinuationTransitionError, "in-use")
      claimContinuation (retireContinuation claimed) `shouldRaiseMatching'` (ContinuationTransitionError, "retired")

  describe "thread/test_identity_and_lifecycle.py" $ do
    it "test_lifecycle_identities_are_serializable_but_not_interchangeable" $ do
      -- Distinct newtypes: equal text in different roles cannot even be
      -- compared, which is stronger than upstream's runtime inequality.
      let t = literalThreadId "same-value"
          c = literalContinuationId "same-value"
          e = literalEpisodeId "same-value"
          u = literalTurnId "same-value"
      lifecycleIdFromData (lifecycleIdToData t) `shouldBe` Right t
      lifecycleIdFromData (lifecycleIdToData c) `shouldBe` Right c
      lifecycleIdFromData (lifecycleIdToData e) `shouldBe` Right e
      lifecycleIdFromData (lifecycleIdToData u) `shouldBe` Right u
      map lifecycleIdToData [t] <> map lifecycleIdToData [c] `shouldBe` [String "same-value", String "same-value"]
      mkThreadId " thread " `shouldRaiseMatching` ValueError $ "trimmed"

    it "test_one_thread_spans_runtime_replacement_without_absorbing_neighboring_identities" $ do
      let th0 = thread0 "thread-durable" Nothing
          th1 =
            expectRight $ startEpisode (eid "episode-gondolin") piProgram (runtimeId "pi.gondolin") budget2 th0
              >>= startTurn (tid "turn-gondolin-1")
              >>= acceptAppend (tid "turn-gondolin-1")
              >>= settleTurn (tid "turn-gondolin-1") TurnCompleted
          first = expectRight (newContinuation (literalContinuationId "continuation-1") th1.id piDescriptor "pi-store:key-1")
          th2 = expectRight $ settleEpisode EpisodeCompleted (Just first) th1 >>= \s -> Right s.thread
          th3 = expectRight (startEpisode (eid "episode-e2b") piProgram (runtimeId "pi.e2b") budget2 th2)
      fmap (.state) th3.continuation `shouldBe` Just ContinuationInUse
      let th4 =
            expectRight $ startTurn (tid "turn-e2b-1") th3
              >>= acceptAppend (tid "turn-e2b-1")
              >>= settleTurn (tid "turn-e2b-1") TurnCompleted
          second = expectRight (newContinuation (literalContinuationId "continuation-2") th4.id piDescriptor "pi-store:key-2")
          final = expectRight $ settleEpisode EpisodeCompleted (Just second) th4 >>= \s -> closeThread s.thread
          restored = expectRight (threadFromData (threadToData final))
          encoded = encodeSorted (threadToData restored)
      restored `shouldBe` final
      restored.state `shouldBe` ThreadClosed
      [e.runtime.name | e <- toList restored.episodes] `shouldBe` ["pi.gondolin", "pi.e2b"]
      [e.acceptedAppends | e <- toList restored.episodes] `shouldBe` [1, 1]
      fmap (.state) restored.continuation `shouldBe` Just ContinuationRetired
      forM_ ["workspace", "agent_home", "process", "territory", "provider_session", "transcript", "history"] $ \forbidden ->
        encoded `shouldNotSatisfy` T.isInfixOf forbidden

    it "test_active_episode_and_turn_round_trip_with_an_in_use_continuation" $ do
      let c = cont "continuation-active" "thread-active" piDescriptor "pi-store:active"
          th =
            expectRight $ startEpisode (eid "episode-active") piProgram (runtimeId "pi.application-owned") budget2 (thread0 "thread-active" (Just c))
              >>= startTurn (tid "turn-active")
          restored = expectRight (threadFromData (threadToData th))
      restored `shouldBe` th
      fmap (.state) restored.continuation `shouldBe` Just ContinuationInUse
      let active = expectRight (activeEpisode restored)
      case Seq.viewr active.turns of
        _ Seq.:> turn -> turn.state `shouldBe` TurnRunning
        Seq.EmptyR -> expectationFailure "no turns"

    it "test_turn_and_append_budgets_fail_before_an_unaccounted_transition" $ do
      let appendLimited0 =
            expectRight $ startEpisode (eid "episode-append-limited") piProgram (runtimeId "pi.application-owned") (episodeBudget 2 1) (thread0 "append-limited" Nothing)
              >>= startTurn (tid "turn-1")
              >>= acceptAppend (tid "turn-1")
      acceptAppend (tid "turn-1") appendLimited0 `shouldRaiseMatching` EpisodeBudgetExceeded $ "accepted_appends"
      either budgetExceededDimension (const Nothing) (acceptAppend (tid "turn-1") appendLimited0)
        `shouldBe` Just "accepted_appends"
      let appendLimited1 = expectRight (settleTurn (tid "turn-1") TurnCompleted appendLimited0)
      startTurn (tid "turn-after-append-budget") appendLimited1 `shouldRaiseMatching` EpisodeBudgetExceeded $ "accepted_appends"
      let appendLimited2 = expectRight $ settleEpisode EpisodeBudgetExhausted Nothing appendLimited1 >>= \s -> Right s.thread
      fmap (.settlement) (lastEpisode appendLimited2) `shouldBe` Just (Just EpisodeBudgetExhausted)

      let turnLimited =
            expectRight $ startEpisode (eid "episode-turn-limited") plainProgram (runtimeId "pi.application-owned") (episodeBudget 1 2) (thread0 "turn-limited" Nothing)
              >>= startTurn (tid "only-turn")
              >>= settleTurn (tid "only-turn") TurnCompleted
      startTurn (tid "too-many") turnLimited `shouldRaiseMatching` EpisodeBudgetExceeded $ "turns"
      let notExhausted =
            expectRight (startEpisode (eid "episode-not-exhausted") plainProgram (runtimeId "pi.application-owned") budget2 (thread0 "not-exhausted" Nothing))
      settleEpisode EpisodeBudgetExhausted Nothing notExhausted `shouldRaiseMatching` LifecycleTransitionError $ "requires an exhausted"

    it "test_cancellation_and_settlement_races_are_first_terminal_fact_wins" $ do
      let running =
            expectRight $ startEpisode (eid "episode-race-settlement") plainProgram (runtimeId "pi.application-owned") budget2 (thread0 "race-settlement" Nothing)
              >>= activeEpisode
          settled = expectRight (episodeSettle EpisodeCompleted Nothing running)
      settled.disposition `shouldBe` SettlementAccepted
      let lateCancel = episodeRequestCancellation settled.episode
      lateCancel.disposition `shouldBe` CancellationTooLate
      lateCancel.episode.settlement `shouldBe` Just EpisodeCompleted
      fmap (.disposition) (episodeSettle EpisodeCompleted Nothing settled.episode) `shouldBe` Right SettlementDuplicate
      episodeSettle EpisodeFailed Nothing settled.episode `shouldRaiseMatching` LifecycleTransitionError $ "already settled"

      let threadSettled =
            expectRight $ startEpisode (eid "thread-episode-race-settlement") plainProgram (runtimeId "pi.application-owned") budget2 (thread0 "thread-race-settlement" Nothing)
              >>= settleEpisode EpisodeCompleted Nothing
      fmap (.disposition) (requestCancellation threadSettled.thread) `shouldBe` Right CancellationTooLate
      let duplicate = expectRight (settleEpisode EpisodeCompleted Nothing threadSettled.thread)
      duplicate.disposition `shouldBe` SettlementDuplicate
      duplicate.thread `shouldBe` threadSettled.thread
      settleEpisode EpisodeFailed Nothing threadSettled.thread `shouldRaiseMatching` LifecycleTransitionError $ "already settled"

      let th =
            expectRight (startEpisode (eid "episode-race-cancellation") plainProgram (runtimeId "pi.application-owned") budget2 (thread0 "race-cancellation" Nothing))
          cancellation = expectRight (requestCancellation th)
      cancellation.disposition `shouldBe` CancellationRequested
      fmap (.state) (activeEpisode cancellation.thread) `shouldBe` Right EpisodeCancelling
      let cancelled = expectRight (settleEpisode EpisodeCancelled Nothing cancellation.thread)
      cancelled.disposition `shouldBe` SettlementAccepted
      fmap (.settlement) (lastEpisode cancelled.thread) `shouldBe` Just (Just EpisodeCancelled)

      let activeTurnThread =
            expectRight $ startEpisode (eid "episode-race-active-turn") plainProgram (runtimeId "pi.application-owned") budget2 (thread0 "race-active-turn" Nothing)
              >>= startTurn (tid "turn-race-active")
          cancelling = (expectRight (requestCancellation activeTurnThread)).thread
      settleTurn (tid "turn-race-active") TurnCompleted cancelling `shouldRaiseMatching` LifecycleTransitionError $ "cancellation-winning Turn"
      let cancelling' = expectRight (settleTurn (tid "turn-race-active") TurnCancelled cancelling)
      settleEpisode EpisodeCompleted Nothing cancelling' `shouldRaiseMatching` LifecycleTransitionError $ "cancellation won"

    it "test_settlement_and_deserialization_require_the_declared_continuation" $ do
      let th = expectRight (startEpisode (eid "episode-required-output") piProgram (runtimeId "pi.application-owned") budget2 (thread0 "thread-required-output" Nothing))
      settleEpisode EpisodeCompleted Nothing th `shouldRaiseMatching` LifecycleTransitionError $ "requires its declared"
      let c = expectRight (newContinuation (literalContinuationId "continuation-required-output") th.id piDescriptor "pi-store:required-output")
          settled = expectRight $ settleEpisode EpisodeCompleted (Just c) th >>= \s -> Right s.thread
          corrupted = case setMember "continuation" Null (threadToData settled) of
            Object members ->
              Object
                [ (k, if k == "episodes" then mapEpisodes v else v)
                | (k, v) <- members
                ]
            other -> other
          mapEpisodes = \case
            Array (first : rest) -> Array (setMember "next_continuation" Null first : rest)
            other -> other
      threadFromData corrupted `shouldRaiseMatching` ValueError $ "requires its declared"

    it "test_failed_episode_retires_its_input_revision_and_may_publish_a_new_one" $ do
      let input = cont "continuation-input" "thread-failed" piDescriptor "pi-store:same-native-state"
          running = expectRight (startEpisode (eid "episode-failed") piProgram (runtimeId "pi.application-owned") budget2 (thread0 "thread-failed" (Just input)))
          output = expectRight (newContinuation (literalContinuationId "continuation-output") running.id piDescriptor "pi-store:same-native-state")
          failed = expectRight $ settleEpisode EpisodeFailed (Just output) running >>= \s -> Right s.thread
      fmap (fmap (.state) . (.continuation)) (lastEpisode failed) `shouldBe` Just (Just ContinuationRetired)
      failed.continuation `shouldBe` Just output

    it "test_provider_shaped_fake_traces_never_enter_the_common_lifecycle" $ do
      custody <- newIORef ([] :: [Text])
      let traces =
            [ (ProviderOwned, "{\"amp_events\": [{\"type\": \"assistant\", \"blocks\": [{\"text\": \"done\"}]}]}")
            , (HarnessOwned, "[{\"role\": \"assistant\", \"content\": [{\"type\": \"text\", \"text\": \"done\"}]}]")
            , (NetOwned, "[[\"transition\", \"append\"], {\"tokens\": {\"accepted\": 1}}]")
            ]
      forM_ (zip [1 :: Int ..] traces) $ \(index, (ownership, trace)) -> do
        let n = T.pack (show index)
            d = expectRight (simpleProgram (ident KindProgram ("fake." <> ownershipText ownership)) ownership)
            th1 =
              expectRight $ startEpisode (eid ("episode-" <> n)) d (runtimeId ("runtime." <> n)) (episodeBudget 1 1) (thread0 ("thread-" <> n) Nothing)
                >>= startTurn (tid ("turn-" <> n))
        modifyIORef' custody (<> [trace])
        let th =
              expectRight $ acceptAppend (tid ("turn-" <> n)) th1
                >>= settleTurn (tid ("turn-" <> n)) TurnCompleted
                >>= settleEpisode EpisodeCompleted Nothing
                >>= \s -> Right s.thread
            lifecycleData = encodeSorted (threadToData th)
            final = case lastEpisode th of
              Just e -> e
              Nothing -> error "no episode"
        Seq.length final.turns `shouldBe` 1
        fmap (.state) (toList final.turns) `shouldBe` [TurnSettled]
        final.acceptedAppends `shouldBe` 1
        forM_ ["amp_events", "role", "transition", "tokens"] $ \key ->
          lifecycleData `shouldNotSatisfy` T.isInfixOf key
      readIORef custody `shouldReturn` map snd traces
      Set.size (Set.fromList (map snd traces)) `shouldBe` 3

lastEpisode :: Thread -> Maybe Episode
lastEpisode t = case Seq.viewr t.episodes of
  _ Seq.:> e -> Just e
  Seq.EmptyR -> Nothing

shouldRaiseMatching' :: (Show a) => Either AgenticusError a -> (ErrorClass, Text) -> Expectation
shouldRaiseMatching' outcome (cls, needle) = shouldRaiseMatching outcome cls needle
