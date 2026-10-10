-- | Parity: @tests/petrus/impetus/petrinet/test_marking.py@ and
-- @tests/petrus/impetus/petrinet/test_token_queue.py@.
module Petrus.Impetus.MarkingSpec (spec) where

import Data.Foldable (toList)
import Data.Functor.Identity (runIdentity)
import Data.List (findIndex)
import Data.Sequence qualified as Seq
import Petrus.Impetus.Petrinet
import Petrus.Impetus.Scope (lifecycleScope)
import Petrus.Impetus.TestSupport
import Petrus.Json (Json (..))
import Test.Hspec
import Test.QuickCheck

-- | A small token alphabet so that equal occurrences are common.
newtype SmallToken = SmallToken Token
  deriving stock (Show)

instance Arbitrary SmallToken where
  arbitrary =
    SmallToken
      <$> oneof
        [ pure black
        , tok <$> elements ["A", "B"]
        , tokD <$> elements ["A", "B"] <*> (Int <$> chooseInteger (0, 2))
        ]

unwrap :: [SmallToken] -> [Token]
unwrap = map (\(SmallToken t) -> t)

-- | A queue whose entry instants are its positions (so instants identify
-- which occurrence survived).
positional :: [Token] -> TokenQueue
positional ts = queueFromPairs (zip ts (map IntNumber [0 ..]))

admittedPositions :: (Token -> Bool) -> Maybe Int -> TokenQueue -> Either String [Int]
admittedPositions judge limit q = either (Left . show) Right (runIdentity (admittedBy (pure . judge) limit q))

spec :: Spec
spec = describe "Petrinet.Marking" $ do
  describe "Token" $ do
    -- test_black_token_has_no_color
    it "a black token has no color" $ do
      isBlack black `shouldBe` True
      black.color `shouldBe` Nothing
    -- test_black_token_equals_empty_token
    it "the black token equals the empty token" $
      black `shouldBe` Token Nothing Null
    -- test_colored_token_carries_color_and_data
    it "a colored token carries color and data" $ do
      let t = tokD "Payment" (obj [("amount", Int 150)])
      isBlack t `shouldBe` False
      t.color `shouldBe` Just "Payment"
      t.payload `shouldBe` obj [("amount", Int 150)]
    -- test_equality_is_by_value
    it "compares by value" $ do
      tokD "Payment" (obj [("amount", Int 1)]) `shouldBe` tokD "Payment" (obj [("amount", Int 1)])
      tokD "Payment" (obj [("amount", Int 1)]) `shouldNotBe` tokD "Payment" (obj [("amount", Int 2)])

  describe "Marking" $ do
    let p = np "a"
    -- test_from_counts_creates_black_tokens
    it "from counts creates black tokens" $
      toList (placeTokens p (fromCounts [(p, 2)])) `shouldBe` [black, black]
    -- test_missing_place_is_empty
    it "reads a missing place as empty" $
      placeTokens (np "nope") emptyMarking `shouldBe` Seq.empty
    -- test_empty_places_are_dropped
    it "drops empty places" $
      markingFromList [(p, [])] `shouldBe` emptyMarking
    -- test_consume_removes_the_requested_tokens_and_is_immutable
    it "consume removes the requested tokens and leaves the original untouched" $ do
      let m = markingFromList [(p, [tok "A", tok "B", tok "C"])]
      updated <- expectRight (consume p [tok "B"] m)
      toList (placeTokens p updated) `shouldBe` [tok "A", tok "C"]
      toList (placeTokens p m) `shouldBe` [tok "A", tok "B", tok "C"]
    -- test_consuming_equal_tokens_removes_one_occurrence_each
    it "consuming equal tokens removes one occurrence each" $ do
      let m = markingFromList [(p, [black, black])]
      fmap (toList . placeTokens p) (consume p [black] m) `shouldBe` Right [black]
      consume p [black, black] m `shouldBe` Right emptyMarking
    -- test_consuming_the_last_token_drops_the_place
    it "consuming the last token drops the place" $
      consume p [black] (markingFromList [(p, [black])]) `shouldBe` Right emptyMarking
    -- test_deposit_appends_and_is_immutable
    it "deposit appends and leaves the original untouched" $ do
      let m = markingFromList [(p, [tok "A"])]
          updated = deposit p (tok "B") m
      toList (placeTokens p updated) `shouldBe` [tok "A", tok "B"]
      toList (placeTokens p m) `shouldBe` [tok "A"]
    -- test_counts_reports_queue_lengths
    it "counts reports queue lengths" $
      counts (markingFromList [(np "a", [black, black]), (np "b", [black])]) `shouldBe` [(np "a", 2), (np "b", 1)]
    -- test_consuming_a_token_not_present_fails_loud
    it "consuming a token not present fails loud" $
      consume p [tok "B"] (markingFromList [(p, [tok "A"])])
        `shouldFailWith` "cannot consume Token('B', None) from a: token not present"
    -- test_consuming_more_occurrences_than_present_fails_loud
    it "consuming more occurrences than present fails loud" $
      consume p [black, black] (markingFromList [(p, [black])])
        `shouldFailWith` "cannot consume Token.black() from a: token not present"
    -- test_truthiness_reflects_emptiness
    it "reports emptiness" $ do
      markingNull emptyMarking `shouldBe` True
      markingNull (markingFromList [(p, [black])]) `shouldBe` False

    it "deposit then consume of the same token restores the counts (property)" $
      property $ \(tokens :: [SmallToken]) (SmallToken t) ->
        let m = markingFromList [(p, unwrap tokens)]
         in fmap counts (consume p [t] (deposit p t m)) === Right (counts m)

  describe "TokenQueue" $ do
    describe "deposit" $ do
      -- test_deposit_appends_to_the_back_and_is_immutable
      it "appends to the back and leaves the original untouched" $ do
        let queue = emptyQueue
            first' = depositToken (tok "A") 1 queue
            second' = depositToken (tok "B") 2 first'
        toList (queueTokens second') `shouldBe` [tok "A", tok "B"]
        toList (queueTokens first') `shouldBe` [tok "A"]
        queueNull queue `shouldBe` True
      -- test_positions_index_tokens_and_instants_alike
      it "positions index tokens and instants alike" $ do
        let queue = depositToken (tok "B") 7 (depositToken (tok "A") 3 emptyQueue)
        queueIndex queue 0 `shouldBe` Just (tok "A")
        queueIndex queue 1 `shouldBe` Just (tok "B")
        toList (queueInstants queue) `shouldBe` [Just 3, Just 7]

    describe "remove" $ do
      -- test_remove_takes_the_front_most_equal_occurrence
      it "takes the front-most equal occurrence" $ do
        remaining <- expectRight (removeTokens [black] (queueFromPairs [(black, 1), (black, 2)]))
        toList (queueTokens remaining) `shouldBe` [black]
        toList (queueInstants remaining) `shouldBe` [Just 2]
      -- test_remove_matches_on_the_token_half_mid_queue
      it "matches on the token half mid-queue" $ do
        let queue = queueFromPairs [(tok "A", 1), (tok "B", 2), (tok "C", 3)]
        remaining <- expectRight (removeTokens [tok "B"] queue)
        toList (queueTokens remaining) `shouldBe` [tok "A", tok "C"]
        toList (queueInstants remaining) `shouldBe` [Just 1, Just 3]
        toList (queueTokens queue) `shouldBe` [tok "A", tok "B", tok "C"]
      -- test_removals_apply_in_request_order
      it "applies removals in request order" $ do
        remaining <- expectRight (removeTokens [tok "A", tok "A"] (queueFromPairs [(tok "A", 1), (tok "A", 2), (tok "B", 3)]))
        toList (queueTokens remaining) `shouldBe` [tok "B"]
        toList (queueInstants remaining) `shouldBe` [Just 3]
      -- test_removing_a_token_not_present_fails_loud (the error carries the
      -- token; the ValueError subclassing is a Python concern)
      it "fails loud on a token not present, carrying the token" $ do
        let queue = queueFromPairs [(tok "A", 1)]
        removeTokens [tok "B"] queue `shouldBe` Left (tok "B")
        toList (queueTokens queue) `shouldBe` [tok "A"]
        -- The exact-occurrence removal spells the reference's message.
        removeExact [(tok "B", 0)] queue `shouldFailWith` "cannot remove Token('B', None): token not present"
      -- test_removing_more_occurrences_than_present_fails_loud
      it "fails loud on more occurrences than present" $
        removeTokens [black, black] (queueFromPairs [(black, 1)]) `shouldBe` Left black

      it "removes the front-most equal occurrence, keeping the rest in order (property)" $
        property $ \(tokens :: [SmallToken]) (SmallToken t) ->
          let ts = unwrap tokens
              queue = positional ts
           in case findIndex (== t) ts of
                Nothing -> removeTokens [t] queue === Left t
                Just i ->
                  let kept = [(x, Just (fromIntegral n)) | (n, x) <- zip [0 :: Int ..] ts, n /= i]
                   in fmap (\q -> zip (toList (queueTokens q)) (toList (queueInstants q))) (removeTokens [t] queue) === Right kept

      it "applies a multi-token removal as successive single removals (property)" $
        property $ \(tokens :: [SmallToken]) (requested :: [SmallToken]) ->
          let queue = positional (unwrap tokens)
              successive = foldl (\acc t -> acc >>= removeTokens [t]) (Right queue) (unwrap requested)
           in fmap reprQueue (removeTokens (unwrap requested) queue) === fmap reprQueue successive

    describe "sequence surface" $ do
      -- test_the_sequence_surface_is_the_token_half
      it "is the token half" $ do
        let queue = queueFromPairs [(tok "A", 1), (tok "B", 2)]
        queueLength queue `shouldBe` 2
        toList (queueTokens queue) `shouldBe` [tok "A", tok "B"]
        tok "B" `elem` queueTokens queue `shouldBe` True
        Seq.elemIndexL (tok "B") (queueTokens queue) `shouldBe` Just 1
      -- test_slicing_keeps_the_pairs_together
      it "keeps the pairs together when sliced" $ do
        let queue = queueFromPairs [(tok "A", 1), (tok "B", 2), (tok "C", 3)]
            tail' = queueSlice 1 (queueLength queue) queue
        toList (queueTokens tail') `shouldBe` [tok "B", tok "C"]
        toList (queueInstants tail') `shouldBe` [Just 2, Just 3]
      -- test_truthiness_reflects_emptiness
      it "reports emptiness" $ do
        queueNull emptyQueue `shouldBe` True
        queueNull (depositToken black 0 emptyQueue) `shouldBe` False

    describe "admittedBy" $ do
      -- test_positions_of_admitted_tokens_front_to_back
      it "returns the positions of admitted tokens front to back" $
        admittedPositions (\t -> t.color == Just "A") Nothing (queueFromPairs [(tok "A", 1), (tok "B", 2), (tok "A", 3)])
          `shouldBe` Right [0, 2]
      -- test_limit_stops_the_scan_where_the_caller_needs_no_more
      it "stops the scan at the limit" $
        admittedPositions (const True) (Just 2) (queueFromPairs [(tok "A", 1), (tok "A", 2), (tok "A", 3)])
          `shouldBe` Right [0, 1]
      -- test_limit_one_accepts_exactly_the_first_admitted_token
      it "with limit one accepts exactly the first admitted token" $
        admittedPositions (\t -> t.color == Just "yes") (Just 1) (queueFromPairs [(tok "no", 1), (tok "yes", 2), (tok "yes", 3)])
          `shouldBe` Right [1]
      -- test_nothing_admitted_is_an_empty_owned_value
      it "returns nothing when nothing is admitted" $
        admittedPositions (const False) Nothing (queueFromPairs [(tok "A", 1)]) `shouldBe` Right []
      -- test_a_non_positive_limit_is_rejected
      it "rejects a non-positive limit" $
        runIdentity (admittedBy (const (pure True)) (Just 0) (queueFromPairs [(tok "A", 1)]))
          `shouldFailWith` "admitted_by requires a positive limit (or None for all), got 0"

      it "with a limit is the prefix of the unlimited scan (property)" $
        property $ \(tokens :: [SmallToken]) (Positive n) ->
          let queue = positional (unwrap tokens)
              judge t = t.color == Just "A"
              everything = [i | (i, t) <- zip [0 ..] (unwrap tokens), judge t]
           in (admittedPositions judge Nothing queue, admittedPositions judge (Just n) queue)
                === (Right everything, Right (take n everything))

    describe "value semantics" $ do
      -- test_equality_compares_both_halves
      it "compares both halves" $ do
        let atOne = queueFromPairs [(tok "A", 1)]
        atOne `shouldBe` depositToken (tok "A") 1 emptyQueue
        atOne `shouldNotBe` depositToken (tok "A") 2 emptyQueue
        atOne `shouldNotBe` depositToken (tok "B") 1 emptyQueue
      -- test_construction_from_pairs_round_trips
      it "round-trips construction from pairs" $
        queueFromPairs [(tok "A", 1), (tok "B", 2)] `shouldBe` depositToken (tok "B") 2 (depositToken (tok "A") 1 emptyQueue)
      -- test_durable_provenance_does_not_change_the_established_public_value_or_repr_surface
      it "keeps durable provenance out of the public value and repr" $ do
        scope <- expectRight (lifecycleScope "draft" 2)
        let enriched = queueFromEntries [QueueEntry (tok "A") (Just 1) (Just 17) (Just scope)]
        enriched `shouldBe` queueFromPairs [(tok "A", 1)]
        reprQueue enriched `shouldBe` "TokenQueue([(Token('A', None), 1)])"
        toList (queueIdentities enriched) `shouldBe` [Just 17]
        toList (queueScopes enriched) `shouldBe` [Just scope]
      -- test_a_time_blind_queue_records_no_instants
      it "records no instants for a time-blind queue" $ do
        let queue = timeBlind [tok "A", tok "B"]
        toList (queueTokens queue) `shouldBe` [tok "A", tok "B"]
        toList (queueInstants queue) `shouldBe` [Nothing, Nothing]
