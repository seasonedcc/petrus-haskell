-- | Port of @tests/petrus/impetus/test_net_document_lineage.py@: uniform,
-- marking-first Net document lineage. Where the reference matches a message
-- fragment, this spec asserts the exact message it produces.
module Petrus.Impetus.NetDocumentLineageSpec (spec) where

import Data.ByteString qualified as BS
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.NetDocument
import Petrus.Impetus.TestSupport
import Petrus.Impetus.WireSupport
import Petrus.Json (Json (..), fromCodePoints, lookupMember)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

lineageFixture :: BS.ByteString
lineageFixture = unsafePerformIO (readSpec "net-document-v1-lineage.json")
{-# NOINLINE lineageFixture #-}

fixtureValue :: Json
fixtureValue = mustJson lineageFixture

entry :: Int -> [Step]
entry index = [K "lineage", K "entries", I index]

-- | @parse_net_document(encoded(value))@ after a change.
parseChanged :: (Json -> Json) -> Either Text NetDocumentV1
parseChanged change = parseNetDocument (writerBytes (change fixtureValue))

pydantic :: Text -> Text -> Text -> Text -> Text -> Text -> Text
pydantic title loc message errorType input inputType =
  "1 validation error for "
    <> title
    <> "\n"
    <> loc
    <> "\n  "
    <> message
    <> " [type="
    <> errorType
    <> ", input_value="
    <> input
    <> ", input_type="
    <> inputType
    <> "]\n    For further information visit https://errors.pydantic.dev/2.13/v/"
    <> errorType

members :: Json -> [Text]
members = \case
  Object ms -> map fst ms
  _ -> []

spec :: Spec
spec = describe "Petrus.Impetus.NetDocument lineage" $ do
  -- test_fixture_is_one_uniform_marking_first_navigation_sequence
  it "reads the fixture as one uniform, marking-first navigation sequence" $ do
    document <- expectRight (parseNetDocument lineageFixture)
    lineage <- maybe (expectationFailure "no lineage" >> error "unreachable") pure document.lineage
    map (\e -> (e.id, e.parent, e.provenance)) lineage.entries
      `shouldBe` [(0, Nothing, Observed), (1, Just 0, Observed), (2, Just 0, Manual), (3, Just 2, Simulated), (4, Just 1, Manual), (5, Just 4, Simulated)]
    lineage.head `shouldBe` 3
    map (\m -> m.place) (take 1 (lineage.entries !! 1).marking) `shouldBe` ["done"]
    map (\m -> m.place) (take 1 (lineage.entries !! 2).marking) `shouldBe` ["pending"]
    map (\t -> t.payload) (take 1 (concatMap (\m -> m.tokens) (take 1 (lineage.entries !! 3).marking)))
      `shouldBe` [Object [("result", String "succeeded-hypothesis")]]

  -- test_observed_manual_and_simulated_entries_have_the_same_core_shape
  it "gives observed, manual, and simulated entries the same core shape" $ do
    let entries = case getAt [K "lineage", K "entries"] fixtureValue of
          Array xs -> xs
          _ -> []
    nub (map members entries) `shouldBe` [["id", "parent", "provenance", "marking", "metadata"]]
    nub [p | Just (String p) <- map (lookupMember "provenance") entries] `shouldMatchList` ["observed", "simulated", "manual"]
    (lookupMember "history_records" (getAt (entry 0 <> [K "metadata"]) fixtureValue) >>= nonEmpty) `shouldSatisfy` (/= Nothing)
    (lookupMember "note" (getAt (entry 2 <> [K "metadata"]) fixtureValue) >>= nonEmpty) `shouldSatisfy` (/= Nothing)
    getAt (entry 4 <> [K "metadata"]) fixtureValue `shouldBe` Object []

  -- test_fixture_round_trip_is_exact_without_hidden_evidence_or_replay_state
  it "round-trips the fixture exactly without hidden evidence or replay state" $ do
    payload <- expectRight (parseNetDocument lineageFixture >>= serializeNetDocument)
    payload `shouldBe` lineageFixture
    mapM_ (\needle -> BS.isInfixOf needle payload `shouldBe` False) ["\"sources\"", "\"fact\"", "\"checkpoint\"", "\"base64\""]

  describe "test_lineage_shape_is_strict" $ do
    let refuses label change message = it label (parseChanged change `shouldFailWith` message)
        wrapped = ("invalid Petrus Net document v1: " <>)
    -- test_lineage_shape_is_strict[set_entry_id]
    refuses "an id that is not the array index" (setAt (entry 4) "id" (Int 5)) "lineage.entries[4].id must equal its array index"
    -- test_lineage_shape_is_strict[set_parent_forward]
    refuses "a parent that is not smaller" (setAt (entry 2) "parent" (Int 2)) "lineage.entries[2].parent must be a smaller entry id"
    -- test_lineage_shape_is_strict[set_second_root]
    refuses "a second root" (setAt (entry 2) "parent" Null) "lineage.entries[2].parent must be a smaller entry id"
    -- test_lineage_shape_is_strict[set_unknown_head]
    refuses "an unknown head" (setAt [K "lineage"] "head" (Int 6)) "lineage.head must name an existing entry"
    -- test_lineage_shape_is_strict[remove_entries]
    refuses "no entries" (setAt [K "lineage"] "entries" (Array [])) "lineage.entries must be nonempty"
    -- test_lineage_shape_is_strict[remove_metadata]
    refuses "missing metadata" (deleteAt (entry 0) "metadata") $
      wrapped (pydantic "NetDocumentV1" "lineage.entries.0.metadata" "Field required" "missing" "{'id': 0, 'parent': None,...'result': 'failed'}}]}]}" "dict")
    -- test_lineage_shape_is_strict[use_non_object_metadata]
    refuses "non-object metadata" (setAt (entry 0) "metadata" (Array [])) $
      wrapped (pydantic "NetDocumentV1" "lineage.entries.0.metadata" "Value error, metadata must be an object" "value_error" "[]" "list")
    -- test_lineage_shape_is_strict[add_old_source_custody]
    refuses "old source custody" (setAt [K "lineage"] "sources" (Array [])) $
      wrapped (pydantic "NetDocumentV1" "lineage.sources" "Extra inputs are not permitted" "extra_forbidden" "[]" "list")

  describe "test_every_entry_contains_one_complete_valid_sparse_marking" $ do
    let refuses label change message = it label (parseChanged change `shouldFailWith` message)
        marking = entry 0 <> [K "marking"]
        workToken = Object [("color", String "Work"), ("data", Null)]
    -- test_every_entry_contains_one_complete_valid_sparse_marking[duplicate_place]
    refuses "a duplicated place" (editAt marking (\case Array xs -> Array (xs <> take 1 xs); v -> v)) "lineage.entries[0].marking places must be unique"
    -- test_every_entry_contains_one_complete_valid_sparse_marking[unsorted_places]
    refuses
      "unsorted places"
      ( setAt (entry 0) "marking" $
          Array
            [ Object [("place", String "pending"), ("tokens", Array [workToken])]
            , Object [("place", String "done"), ("tokens", Array [workToken])]
            ]
      )
      "lineage.entries[0].marking places must be sorted by Unicode scalar value"
    -- test_every_entry_contains_one_complete_valid_sparse_marking[empty_sparse_place]
    refuses "an empty sparse place" (setAt (marking <> [I 0]) "tokens" (Array [])) "lineage.entries[0].marking[0].tokens must be nonempty in sparse marking form"
    -- test_every_entry_contains_one_complete_valid_sparse_marking[foreign_place]
    refuses "a foreign place" (setAt (marking <> [I 0]) "place" (String "foreign")) "lineage.entries[0].marking[0].place names foreign place 'foreign'"
    -- test_every_entry_contains_one_complete_valid_sparse_marking[wrong_color]
    refuses "a token of the wrong color" (setAt (marking <> [I 0, K "tokens", I 0]) "color" (String "Foreign")) "lineage.entries[0].marking[0].tokens[0].color 'Foreign' does not match place 'pending' color 'Work'"

  -- test_exact_negative_fixture_is_refused
  it "refuses the exact negative fixture" $ do
    fixture <- readSpec "net-document-v1-invalid-lineage.json"
    parseNetDocument fixture `shouldFailWith` "lineage.entries[3].marking[0].place names foreign place 'foreign'"

  -- test_metadata_is_non_authoritative_strict_json
  -- (the tuple and non-string-key cases are enforced by types: metadata is a
  -- list of 'Text'-named 'Json' members)
  it "keeps metadata non-authoritative strict JSON" $ do
    document <- expectRight (parseNetDocument lineageFixture)
    lineage <- maybe (expectationFailure "no lineage" >> error "unreachable") pure document.lineage
    let e = lineage.entries !! 2
        with = mkLineageEntry e.id e.parent e.provenance e.marking
    changed <- expectRight (with [("history_records", Array [Object [("record", String "Invented")]]), ("anything", Array [Bool True, Null, Float 3.5])])
    changed.marking `shouldBe` e.marking
    lookup "anything" changed.metadata `shouldBe` Just (Array [Bool True, Null, Float 3.5])
    with [("number", Float (1 / 0))]
      `shouldFailWith` pydantic "LineageEntry" "metadata" "Value error, JSON numbers must be finite" "value_error" "{'number': inf}" "dict"
    with [("number", Int (2 ^ (53 :: Int)))]
      `shouldFailWith` pydantic "LineageEntry" "metadata" "Value error, integral JSON numbers must be within the JavaScript safe-integer range" "value_error" "{'number': 9007199254740992}" "dict"
    with [("number", Float 1e20)]
      `shouldFailWith` pydantic "LineageEntry" "metadata" "Value error, integral JSON numbers must be within the JavaScript safe-integer range" "value_error" "{'number': 1e+20}" "dict"

  -- test_caller_mutation_does_not_change_parsed_lineage
  -- (enforced by types: a parsed document shares no mutable state with the
  -- caller's value; the round trip still holds)
  it "is unaffected by the caller's value" $ do
    document <- expectRight (parseNetDocument (writerBytes fixtureValue))
    let _mutated = setAt (entry 0 <> [K "metadata"]) "instance" (String "mutated") (setAt (entry 0) "id" (Int 99) fixtureValue)
    serializeNetDocument document `shouldBe` Right (writerBytes fixtureValue)

  describe "test_direct_token_data_must_already_be_strict_json" $ do
    -- enforced by types: test_direct_token_data_must_already_be_strict_json[tuple] ('Json' has no tuples)
    -- enforced by types: test_direct_token_data_must_already_be_strict_json[non-string-key] ('Json' member names are 'Text')
    -- test_direct_token_data_must_already_be_strict_json[inf]
    it "refuses a non-finite number" $
      mkMarkingToken Nothing (Object [("number", Float (1 / 0))])
        `shouldFailWith` pydantic "MarkingToken" "data" "Value error, JSON numbers must be finite" "value_error" "{'number': inf}" "dict"
    -- beyond upstream: a lone surrogate (a WTF-8 'Text', "Petrus.Json.Wtf8")
    -- in a value or a member name, refused as the reference refuses its str
    it "refuses a lone surrogate in a string or a member name" $ do
      mkMarkingToken Nothing (Object [("s", String (fromCodePoints "a\xD800"))])
        `shouldFailWith` pydantic "MarkingToken" "data" "Value error, JSON strings must contain Unicode scalar values" "value_error" "{'s': 'a\\ud800'}" "dict"
      mkMarkingToken Nothing (Object [(fromCodePoints "\xDC00", Int 1)])
        `shouldFailWith` pydantic "MarkingToken" "data" "Value error, JSON strings must contain Unicode scalar values" "value_error" "{'\\udc00': 1}" "dict"
    -- test_direct_token_data_must_already_be_strict_json[2**53]
    it "refuses an unsafe integer" $
      mkMarkingToken Nothing (Object [("number", Int (2 ^ (53 :: Int)))])
        `shouldFailWith` pydantic "MarkingToken" "data" "Value error, integral JSON numbers must be within the JavaScript safe-integer range" "value_error" "{'number': 9007199254740992}" "dict"
  where
    nonEmpty = \case
      Array [] -> Nothing
      Object [] -> Nothing
      String s | T.null s -> Nothing
      Null -> Nothing
      other -> Just other
