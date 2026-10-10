-- | Parity: @tests/petrus/impetus/history/test_history.py@.
--
-- Records are plain values here: the reference's constructor
-- (@__post_init__@) rules are 'recordInvariants', applied at every door
-- (the codec, the writer, replay), so a record's own precondition is
-- asserted through it. A replay divergence is a 'Left' with the
-- reference's @ValueError@ text.
module Petrus.Impetus.HistorySpec (spec) where

import Petrus.Impetus.History
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport
import Petrus.Json (Json (..))
import Test.Hspec
import Test.QuickCheck

initialized :: NetPath -> [Token] -> Record
initialized p ts = RTokensInitialized (TokensInitialized p ts 0 [] Nothing)

consumed :: NetPath -> [Token] -> Int -> Record
consumed p ts o = RTokensConsumed (TokensConsumed p ts o [] Nothing 0)

produced :: NetPath -> [Token] -> Int -> Record
produced p ts o = RTokensProduced (TokensProduced p ts o [] Nothing 0)

readTokens :: NetPath -> [Token] -> Int -> Record
readTokens p ts o = RTokensRead (TokensRead p ts o [] Nothing 0)

spec :: Spec
spec = describe "History" $ do
  describe "ExternalEventDelivered" $ do
    -- TestExternalEventDelivered.test_identity_must_be_a_non_empty_string
    -- (the 7 and None identities are enforced by types: identity is Text)
    it "requires a non-empty string identity" $
      recordInvariants (RExternalEventDelivered (ExternalEventDelivered (np "src") [tok "X"] "" 1 Nothing 0))
        `shouldFailWith` "ExternalEventDelivered requires an exact non-empty string identity, got ''"

  describe "replayMarking" $ do
    let a = np "a"
        b = np "b"
        token' = tok "X"
    -- TestReplayMarking.test_rebuilds_marking_from_recorded_movements
    it "rebuilds the marking from recorded movements" $
      replayMarking [initialized a [token'], consumed a [token'] 1, produced b [token'] 1]
        `shouldBe` Right (markingFromList [(b, [token'])])

    -- TestReplayMarking.test_projects_each_complete_marking_from_one_history_iteration
    it "projects each complete marking from one history iteration" $
      replayMarkings
        [ initialized a [token']
        , RCandidateSelected (CandidateSelected (np "move") 1 0)
        , consumed a [token'] 1
        , produced b [token'] 1
        ]
        `shouldBe` Right
          [ markingFromList [(a, [token'])]
          , markingFromList [(a, [token'])]
          , emptyMarking
          , markingFromList [(b, [token'])]
          ]

    -- TestReplayMarking.test_empty_history_is_an_empty_marking
    it "an empty history is an empty marking" $
      replayMarking ([] :: [Record]) `shouldBe` Right emptyMarking

    -- TestReplayMarking.test_only_movement_records_affect_the_marking
    it "only movement records affect the marking" $ do
      let t = np "t"
          src = np "src"
          withLifecycle =
            [ initialized a [token']
            , RDeliveryRegistrationOpened (DeliveryRegistrationOpened src "default" Nothing 0)
            , RExternalEventDelivered (ExternalEventDelivered src [tok "Y"] "occurrence-1" 1 Nothing 0)
            , RCandidateSelected (CandidateSelected t 2 0)
            , RFiringBegun (FiringBegun t 2 Nothing 0)
            , consumed a [token'] 2
            , produced b [token'] 2
            , RFiringCompleted (FiringCompleted t 2 0)
            , RDeliveryRegistrationClosed (DeliveryRegistrationClosed src "default" Nothing 0)
            ]
      replayMarking withLifecycle `shouldBe` Right (markingFromList [(b, [token'])])

    -- TestReplayMarking.test_tokens_read_is_a_movement_category_record_yet_replay_inert
    it "TokensRead is a movement-category record, yet replay-inert" $ do
      let gate = np "gate"
          settings = tokD "Config" (Object [("mode", String "strict")])
      replayMarking
        [ initialized a [tok "X"]
        , initialized gate [settings]
        , consumed a [tok "X"] 1
        , readTokens gate [settings] 1
        ]
        `shouldBe` Right (markingFromList [(gate, [settings])])

    -- TestReplayMarking.test_a_diverging_consume_record_fails_loud
    it "a diverging consume record fails loud" $
      replayMarking [initialized a [tok "X"], consumed a [tok "WRONG"] 1]
        `shouldFailWith` "replay divergence: cannot consume Token('WRONG', None) from a: token not present"

  describe "properties" $ do
    -- Not upstream (no Hypothesis there): moving a queue front to back one
    -- token per occurrence replays to the moved queue, every intermediate
    -- marking is one projection, and reads never move anything.
    let a = np "a"
        b = np "b"
        gate = np "gate"
        item n = tokD "Item" (Object [("n", Int n)])
    it "replaying k front-to-back moves leaves the rest in place, in order (property)" $
      property $ \(NonNegative (n :: Int)) (NonNegative (k0 :: Int)) ->
        let tokens = map (item . toInteger) [1 .. n]
            k = if n == 0 then 0 else k0 `mod` (n + 1)
            moves = concat [[consumed a [t] o, readTokens gate [black] o, produced b [t] o] | (t, o) <- zip (take k tokens) [1 ..]]
            history = initialized a tokens : initialized gate [black] : moves
         in replayMarking history
              === Right (markingFromList (filter (not . null . snd) [(a, drop k tokens), (gate, [black]), (b, take k tokens)]))
    it "replayMarkings projects one marking per record, ending at replayMarking (property)" $
      property $ \(NonNegative (n :: Int)) ->
        let tokens = map (item . toInteger) [1 .. n]
            history = initialized a tokens : concat [[consumed a [t] o, produced b [t] o] | (t, o) <- zip tokens [1 ..]]
         in case (replayMarkings history, replayMarking history) of
              (Right markings, Right final) -> length markings === length history .&&. last markings === final
              other -> counterexample (show other) False
