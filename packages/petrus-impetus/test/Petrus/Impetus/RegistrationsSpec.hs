-- | Parity: @tests/petrus/impetus/instance/test_registrations.py@ — the
-- delivery registration lifecycle (instantiation opens, handler-driven
-- opens and closes, @seal@) and the AWAITING status leg.
--
-- Translation notes. The reference's inline completion condition
-- @Cel("size(done) == 1")@ compiles through a test-local 'CelCompilers' stub
-- that recognises exactly that expression (CEL lives in another package).
-- The reference's bare token mapping as a handler result is 'handlerTokens'.
module Petrus.Impetus.RegistrationsSpec (spec) where

import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Petrus.Impetus.Binding
import Petrus.Impetus.DoorSupport
import Petrus.Impetus.History
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates, candidatesWithDiagnostics, nextMaturation)
import Petrus.Impetus.TestSupport (expectRight, mustNet, np, shouldFailWith, tok)
import Petrus.Impetus.TestSupport qualified as TS
import Test.Hspec

event, done, webhook, settle :: NetPath
event = np "event"
done = np "done"
webhook = np "webhook"
settle = np "settle"

-- | @webhook (source) -> event -> settle -> done@, optionally with the
-- declared completion condition @size(done) == 1@.
webhookNet :: Bool -> Net
webhookNet withCondition =
  mustNet
    NetSpec
      { places = [place event, place done]
      , transitions = [transition webhook, transition settle]
      , arcs = [arc webhook event, arc event settle, arc settle done]
      , completion = if withCondition then Just (CompletionCel (unsafeCel "size(done) == 1")) else Nothing
      , name = Nothing
      }

-- | The CEL stub: @size(done) == 1@ over the marking.
celStub :: CelCompilers
celStub =
  CelCompilers
    { compileGuard = noCelCompilers.compileGuard
    , compileFilter = noCelCompilers.compileFilter
    , compileCompletion = \expression places ->
        if celExpression expression == "size(done) == 1"
          then Right (\m -> Right (length (placeTokens done m) == 1))
          else noCelCompilers.compileCompletion expression places
    }

webhookInstance :: Bool -> Marking -> IO Instance
webhookInstance withCondition initial =
  mkInstance (webhookNet withCondition) defaultInstanceConfig {initialMarking = initial, celCompilers = celStub}

requests, events, subscribe :: NetPath
requests = np "requests"
events = np "events"
subscribe = np "subscribe"

-- | @requests -> subscribe (handled) -> events <- webhook (source)@.
handledNet :: Net
handledNet =
  TS.netOf
    [place requests, place events]
    [(transition subscribe) {handler = Just (HandlerSymbol "hook")}, transition webhook]
    [arc requests subscribe, arc subscribe events, arc webhook events]

hooked :: Handler -> IO Instance
hooked hook =
  mkInstance
    handledNet
    defaultInstanceConfig {initialMarking = markingFromList [(requests, [black])], handlerImplementations = pureHandler "hook" hook}

registration :: NetPath -> Text -> DeliveryRegistration
registration = DeliveryRegistration

opened, closed :: NetPath -> Text -> Maybe Int -> Record
opened s k o = RDeliveryRegistrationOpened (DeliveryRegistrationOpened s k o 0)
closed s k o = RDeliveryRegistrationClosed (DeliveryRegistrationClosed s k o 0)

-- | An in-flight occurrence on the handled @subscribe@ transition.
begun :: IO (Instance, FiringOccurrence)
begun = do
  let net =
        TS.netOf
          [place requests, place events]
          [(transition subscribe) {handler = Just (HandlerSymbol "hook")}, transition webhook]
          [arc requests subscribe, arc webhook events]
  inst <-
    mkInstance
      net
      defaultInstanceConfig
        { initialMarking = markingFromList [(requests, [black])]
        , handlerImplementations = pureHandler "hook" (\_ _ -> Right (handlerTokens []))
        }
  [b] <- candidates inst
  o <- begin inst b Nothing >>= expectRight
  pure (inst, o)

lastRecords :: Int -> Instance -> IO [Record]
lastRecords n inst = (\rs -> drop (length rs - n) rs) <$> historyRecords inst

spec :: Spec
spec = describe "Delivery registrations" $ do
  describe "registration identity" $ do
    -- TestDeliveryRegistrationIdentity.test_a_source_spelling_normalizes_to_its_netpath_identity:
    -- enforced by types (a registration's source is a 'NetPath'; there is no
    -- second, string spelling to normalize).
    -- TestDeliveryRegistrationIdentity.test_an_empty_key_is_rejected
    it "rejects an empty key" $
      deliveryRegistration webhook "" `shouldFailWith` "DeliveryRegistration requires a non-empty string key of the exact built-in type, got ''"
    -- TestDeliveryRegistrationIdentity.test_a_non_string_key_is_rejected:
    -- enforced by types (the key is 'Text').

  describe "registration lifecycle" $ do
    -- TestDeliveryRegistrationLifecycle.test_construction_opens_one_default_registration_per_source_in_stable_order
    it "opens one default registration per source at construction, in stable order" $ do
      let bSrc = np "b_src"
          aSrc = np "a_src"
          p = np "p"
          q = np "q"
          net = TS.netOf [place p, place q] [transition bSrc, transition aSrc] [arc bSrc p, arc aSrc q]
      inst <- mkInstance net defaultInstanceConfig {initialMarking = markingFromList [(p, [black])]}
      historyRecords inst
        >>= ( `shouldBe`
                [ RInstanceCreated (InstanceCreated (instanceIdentity inst) Nothing 0)
                , RTokensInitialized (TokensInitialized p [black] 0 [] Nothing)
                , opened aSrc "default" Nothing
                , opened bSrc "default" Nothing
                ]
            )
    -- TestDeliveryRegistrationLifecycle.test_seal_records_the_registration_close
    it "records the registration close on seal" $ do
      inst <- webhookInstance False emptyMarking
      seal inst webhook Nothing >>= expectRight
      lastRecords 1 inst >>= (`shouldBe` [closed webhook "default" Nothing])
    -- TestDeliveryRegistrationLifecycle.test_sealing_with_no_armed_registration_is_rejected
    it "rejects sealing with no armed registration" $ do
      inst <- webhookInstance False emptyMarking
      seal inst webhook Nothing >>= expectRight
      result <- seal inst webhook Nothing
      result `refusedWith` "cannot seal source transition webhook: no armed delivery registration"
    -- TestDeliveryRegistrationLifecycle.test_sealing_a_non_source_transition_is_rejected
    it "rejects sealing a non-source transition" $ do
      inst <- webhookInstance False emptyMarking
      result <- seal inst settle Nothing
      result `refusedWith` "cannot seal transition settle: it has input arcs — only a source transition has delivery registrations"
    -- TestDeliveryRegistrationLifecycle.test_sealing_an_unknown_transition_is_rejected
    it "rejects sealing an unknown transition" $ do
      inst <- webhookInstance False emptyMarking
      result <- seal inst (np "nowhere") Nothing
      result `refusedWith` "cannot seal nowhere: not a transition of this net"
    -- TestDeliveryRegistrationLifecycle.test_delivery_with_no_armed_registration_is_rejected
    it "rejects delivery with no armed registration" $ do
      inst <- webhookInstance False emptyMarking
      seal inst webhook Nothing >>= expectRight
      result <- acceptDelivery inst webhook [tok "X"] "after-seal" Nothing Nothing
      result `refusedWith` "cannot deliver to source transition webhook: no armed delivery registration"

  describe "armed projection" $ do
    -- TestArmedProjection.test_armed_exposes_each_armed_source_with_its_open_keys
    it "exposes each armed source with its open keys" $ do
      inst <- webhookInstance False emptyMarking
      armed inst >>= (`shouldBe` Map.fromList [(webhook, Set.fromList ["default"])])
    -- TestArmedProjection.test_a_sealed_source_leaves_the_projection
    it "drops a sealed source from the projection" $ do
      inst <- webhookInstance False emptyMarking
      seal inst webhook Nothing >>= expectRight
      projection <- armed inst
      projection `shouldBe` Map.empty
      Map.null projection `shouldBe` True
    -- TestArmedProjection.test_armed_is_structurally_read_only:
    -- enforced by types (the projection is an immutable 'Map' of immutable
    -- 'Set's; no write reaches the instance).

  describe "handler-driven lifecycle" $ do
    -- TestHandlerDrivenLifecycle.test_a_handler_result_opens_a_registration_on_a_source
    it "opens a registration from a handler result" $ do
      inst <- hooked (\_ _ -> Right (HandlerResult [] [registration webhook "sub"] []))
      Just firing <- step inst Nothing >>= expectRight
      historyRecords inst >>= (`shouldContain` [opened webhook "sub" (Just firing.occurrence)])
    -- TestHandlerDrivenLifecycle.test_two_registrations_close_independently
    it "closes two registrations independently" $ do
      let hook b _
            | b.transition == subscribe = Right (HandlerResult [] [registration webhook "sub"] [])
            | otherwise =
                let final = case bindingTokens b of
                      t : _ -> t.color == Just "Final"
                      [] -> False
                 in Right (HandlerResult [(events, bindingTokens b)] [] [registration webhook "sub" | final])
          net =
            TS.netOf
              [place requests, place events]
              [(transition subscribe) {handler = Just (HandlerSymbol "hook")}, (transition webhook) {handler = Just (HandlerSymbol "hook")}]
              [arc requests subscribe, arc webhook events]
      inst <-
        mkInstance
          net
          defaultInstanceConfig {initialMarking = markingFromList [(requests, [black])], handlerImplementations = pureHandler "hook" hook}
      _ <- run inst >>= expectRight
      firing <- deliver inst webhook [tok "Final"] "final-event"
      historyRecords inst >>= (`shouldContain` [closed webhook "sub" (Just firing.occurrence)])
      status inst >>= (`shouldBe` Awaiting)
      _ <- deliver inst webhook [tok "X"] "default-event"
      pure ()
    -- TestHandlerDrivenLifecycle.test_a_handler_closing_the_last_registration_stops_delivery
    it "stops delivery when a handler closes the last registration" $ do
      let hook b _ = Right (HandlerResult [(events, bindingTokens b)] [] [registration webhook "default"])
          net = TS.netOf [place events] [(transition webhook) {handler = Just (HandlerSymbol "hook")}] [arc webhook events]
      inst <- mkInstance net defaultInstanceConfig {handlerImplementations = pureHandler "hook" hook}
      _ <- deliver inst webhook [tok "X"] "closing-event"
      status inst >>= (`shouldBe` Terminated)
      result <- acceptDelivery inst webhook [tok "X"] "after-close" Nothing Nothing
      result `refusedWith` "cannot deliver to source transition webhook: no armed delivery registration"
    -- TestHandlerDrivenLifecycle.test_a_handler_open_rearms_a_sealed_source
    it "re-arms a sealed source from a handler open" $ do
      inst <- hooked (\_ _ -> Right (HandlerResult [] [registration webhook "sub"] []))
      seal inst webhook Nothing >>= expectRight
      status inst >>= (`shouldBe` Running)
      _ <- step inst Nothing >>= expectRight
      status inst >>= (`shouldBe` Awaiting)
      _ <- deliver inst webhook [tok "X"] "rearmed-event"
      current <- marking inst
      toList (placeTokens events current) `shouldBe` [tok "X"]
    -- TestHandlerDrivenLifecycle.test_seal_closes_every_armed_registration
    it "closes every armed registration on seal" $ do
      inst <- hooked (\_ _ -> Right (HandlerResult [] [registration webhook "sub"] []))
      _ <- step inst Nothing >>= expectRight
      seal inst webhook Nothing >>= expectRight
      lastRecords 2 inst >>= (`shouldBe` [closed webhook "default" Nothing, closed webhook "sub" Nothing])
      status inst >>= (`shouldBe` Terminated)
    -- TestHandlerDrivenLifecycle.test_closes_apply_before_opens_so_one_result_refreshes_a_key
    it "applies closes before opens so one result refreshes a key" $ do
      inst <- hooked (\_ _ -> Right (HandlerResult [] [registration webhook "default"] [registration webhook "default"]))
      Just firing <- step inst Nothing >>= expectRight
      lastRecords 3 inst
        >>= ( `shouldBe`
                [ closed webhook "default" (Just firing.occurrence)
                , opened webhook "default" (Just firing.occurrence)
                , RFiringCompleted (FiringCompleted subscribe firing.occurrence 0)
                ]
            )
      status inst >>= (`shouldBe` Awaiting)
    -- TestHandlerDrivenLifecycle.test_the_committed_effects_follow_the_movements_as_their_own_records
    it "commits the effects after the movements as their own records" $ do
      inst <- hooked (\_ _ -> Right (HandlerResult [(events, [tok "X"])] [registration webhook "sub"] []))
      Just firing <- step inst Nothing >>= expectRight
      lastRecords 3 inst
        >>= ( `shouldBe`
                [ RTokensProduced (TokensProduced events [tok "X"] firing.occurrence [] Nothing 0)
                , opened webhook "sub" (Just firing.occurrence)
                , RFiringCompleted (FiringCompleted subscribe firing.occurrence 0)
                ]
            )
    -- TestHandlerDrivenLifecycle.test_a_tokens_only_envelope_is_the_bare_mapping
    it "spells a tokens-only envelope as the bare mapping" $ do
      bare <- hooked (\_ _ -> Right (handlerTokens [(events, [tok "X"])]))
      wrapped <- hooked (\_ _ -> Right (HandlerResult [(events, [tok "X"])] [] []))
      _ <- step bare Nothing >>= expectRight
      _ <- step wrapped Nothing >>= expectRight
      bareRecords <- drop 1 <$> historyRecords bare
      wrappedRecords <- drop 1 <$> historyRecords wrapped
      bareRecords `shouldBe` wrappedRecords
      bareMarking <- marking bare
      marking wrapped >>= (`shouldBe` bareMarking)
    -- TestHandlerDrivenLifecycle.test_registration_records_are_inert_during_replay
    it "keeps registration records inert during replay" $ do
      inst <- hooked (\_ _ -> Right (HandlerResult [(events, [tok "X"])] [registration webhook "sub"] []))
      _ <- step inst Nothing >>= expectRight
      seal inst webhook Nothing >>= expectRight
      current <- marking inst
      replayMarking <$> historyRecords inst >>= (`shouldBe` Right current)

  describe "effect validation" $ do
    let completeWith inst o result = complete inst o (Just result) Nothing
    -- TestEffectValidation.test_closing_a_registration_that_is_not_armed_is_rejected
    it "rejects closing a registration that is not armed" $ do
      (inst, o) <- begun
      result <- completeWith inst o (HandlerResult [] [] [registration webhook "sub"])
      result `refusedWith` "cannot complete firing occurrence 1 (subscribe): close of delivery registration 'sub' on webhook: not armed"
    -- TestEffectValidation.test_opening_an_already_armed_registration_is_rejected
    it "rejects opening an already armed registration" $ do
      (inst, o) <- begun
      result <- completeWith inst o (HandlerResult [] [registration webhook "default"] [])
      result `refusedWith` "cannot complete firing occurrence 1 (subscribe): open of delivery registration 'default' on webhook: already armed"
    -- TestEffectValidation.test_an_effect_on_an_unknown_transition_is_rejected
    it "rejects an effect on an unknown transition" $ do
      (inst, o) <- begun
      result <- completeWith inst o (HandlerResult [] [registration (np "nowhere") "sub"] [])
      result `refusedWith` "cannot complete firing occurrence 1 (subscribe): delivery-registration effect on nowhere: not a transition of this net"
    -- TestEffectValidation.test_an_effect_on_a_non_source_transition_is_rejected
    it "rejects an effect on a non-source transition" $ do
      (inst, o) <- begun
      result <- completeWith inst o (HandlerResult [] [registration subscribe "sub"] [])
      result
        `refusedWith` "cannot complete firing occurrence 1 (subscribe): delivery-registration effect on transition subscribe: it has input arcs — only a source transition has delivery registrations"
    -- TestEffectValidation.test_a_non_registration_effect_is_rejected:
    -- enforced by types (the envelope's effects are 'DeliveryRegistration's).
    -- TestEffectValidation.test_effects_on_a_pure_projection_are_legal_recorded_facts
    it "records effects on a pure projection as legal facts" $ do
      let p = np "p"
          q = np "q"
          t = np "t"
          net = TS.netOf [place p, place q] [transition t, transition webhook] [arc p t, arc t q, arc webhook q]
      inst <- mkInstance net defaultInstanceConfig {initialMarking = markingFromList [(p, [black])]}
      [b] <- candidates inst
      o <- begin inst b Nothing >>= expectRight
      firing <- completeWith inst o (HandlerResult [] [] [registration webhook "default"]) >>= expectRight
      historyRecords inst >>= (`shouldContain` [closed webhook "default" (Just firing.occurrence)])
      projection <- armed inst
      Map.member webhook projection `shouldBe` False
    -- TestEffectValidation.test_a_rejected_effect_leaves_nothing_appended_and_the_occurrence_in_flight
    it "appends nothing for a rejected effect and leaves the occurrence in flight" $ do
      (inst, o) <- begun
      prior <- historyRecords inst
      result <- completeWith inst o (HandlerResult [] [] [registration webhook "sub"])
      result `refusedWith` "cannot complete firing occurrence 1 (subscribe): close of delivery registration 'sub' on webhook: not armed"
      historyRecords inst >>= (`shouldBe` prior)
      inFlight inst >>= (`shouldBe` [o])
      failFiring inst o (FailureText "ValueError('close of an unarmed registration')") Nothing >>= expectRight
      inFlight inst >>= (`shouldBe` [])

  describe "awaiting status" $ do
    -- TestAwaitingStatus.test_quiescent_with_an_armed_registration_is_awaiting
    it "is awaiting when quiescent with an armed registration" $ do
      inst <- webhookInstance False emptyMarking
      isQuiescent inst >>= (`shouldBe` True)
      status inst >>= (`shouldBe` Awaiting)
    -- TestAwaitingStatus.test_running_outranks_awaiting
    it "ranks running above awaiting" $ do
      inst <- webhookInstance False (markingFromList [(event, [black])])
      status inst >>= (`shouldBe` Running)
    -- TestAwaitingStatus.test_completion_outranks_an_armed_registration (ported via CEL stub)
    it "ranks completion above an armed registration" $ do
      inst <- webhookInstance True (markingFromList [(event, [black])])
      _ <- run inst >>= expectRight
      status inst >>= (`shouldBe` Completed)
    -- TestAwaitingStatus.test_awaiting_when_the_declared_condition_does_not_hold (ported via CEL stub)
    it "is awaiting when the declared condition does not hold" $ do
      inst <- webhookInstance True emptyMarking
      status inst >>= (`shouldBe` Awaiting)
    -- TestAwaitingStatus.test_seal_flips_status_with_zero_net_activity (ported via CEL stub)
    it "flips status on seal with zero net activity" $ do
      inst <- webhookInstance True emptyMarking
      prior <- marking inst
      status inst >>= (`shouldBe` Awaiting)
      seal inst webhook Nothing >>= expectRight
      status inst >>= (`shouldBe` Stuck)
      marking inst >>= (`shouldBe` prior)
    -- TestAwaitingStatus.test_sealed_with_no_condition_collapses_to_terminated
    it "collapses to terminated when sealed with no condition" $ do
      inst <- webhookInstance False emptyMarking
      seal inst webhook Nothing >>= expectRight
      status inst >>= (`shouldBe` Terminated)
    -- TestAwaitingStatus.test_one_armed_source_among_sealed_ones_keeps_the_instance_awaiting
    it "keeps awaiting while one source among sealed ones is armed" $ do
      let aSrc = np "a_src"
          bSrc = np "b_src"
          p = np "p"
          q = np "q"
      inst <- mkInstance (TS.netOf [place p, place q] [transition aSrc, transition bSrc] [arc aSrc p, arc bSrc q]) defaultInstanceConfig
      seal inst aSrc Nothing >>= expectRight
      status inst >>= (`shouldBe` Awaiting)
      seal inst bSrc Nothing >>= expectRight
      status inst >>= (`shouldBe` Terminated)
