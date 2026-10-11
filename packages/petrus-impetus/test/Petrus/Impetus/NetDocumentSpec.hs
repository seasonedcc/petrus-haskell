-- | Port of @tests/petrus/impetus/test_net_document.py@: the portable Net
-- document's definition/view foundation. Where the reference matches a
-- message fragment, this spec asserts the exact message it produces.
module Petrus.Impetus.NetDocumentSpec (spec) where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)
import Petrus.Impetus.NetDefinition
import Petrus.Impetus.NetDocument
import Petrus.Impetus.Petrinet (Number (..))
import Petrus.Impetus.TestSupport
import Petrus.Impetus.WireSupport
import Petrus.Json (Json (..), lookupMember)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

definitionFixture :: NetDefinitionV3
definitionFixture = unsafePerformIO (readSpec "net-definition-v3.json" >>= either (fail . T.unpack) pure . parseNetDefinition)
{-# NOINLINE definitionFixture #-}

documentValue :: Json
documentValue =
  Object
    [ ("format", String "petrus-net-document")
    , ("version", Int 1)
    , ("definition", netDefinitionToJson definitionFixture)
    , ( "view"
      , Object
          [ ("version", Int 1)
          , ( "nodes"
            , Array
                [ Object [("node", String "review.correctness.pending"), ("x", Float 20.5), ("y", Int (-40))]
                , Object [("node", String "review.correctness.review"), ("x", Int 240), ("y", Float 80.25)]
                ]
            )
          ]
      )
    ]

-- | @parse_net_document(json.dumps(value, ensure_ascii=False))@ after a change.
parseChanged :: (Json -> Json) -> Either Text NetDocumentV1
parseChanged change = parseNetDocument (pyDumpsUnicode (change documentValue))

pydantic :: Text -> Text -> Text -> Text -> Text -> Text
pydantic loc message errorType input inputType =
  "invalid Petrus Net document v1: 1 validation error for NetDocumentV1\n"
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

hexDigest :: BS.ByteString -> Text
hexDigest = T.pack . concatMap (\w -> let h = showHex w "" in if length h == 1 then '0' : h else h) . BS.unpack . SHA256.hash

spec :: Spec
spec = describe "Petrus.Impetus.NetDocument" $ do
  -- test_projection_parse_serialize_and_identity_fixed_points
  it "projects, parses, serializes, and identifies as fixed points" $ do
    net <- expectRight (compileNetDefinition definitionFixture)
    projected <-
      expectRight $
        projectNetDocument
          net
          (Just [("review.correctness.pending", (FloatNumber 20.5, IntNumber (-40))), ("review.correctness.review", (IntNumber 240, FloatNumber 80.25))])
          Nothing
    encoded <- expectRight (serializeNetDocument projected)
    parsed <- expectRight (parseNetDocument encoded)
    fixture <- readSpec "net-document-v1.json"
    parsed `shouldBe` projected
    parsed.definition `shouldBe` definitionFixture
    serializeNetDocument parsed `shouldBe` Right encoded
    encoded `shouldBe` fixture
    BS.isSuffixOf "\n" encoded `shouldBe` True
    canonical <- expectRight (serializeNetDefinition definitionFixture)
    definitionIdentity parsed `shouldBe` Right (hexDigest canonical)

  -- test_definition_only_document_omits_view_and_view_never_changes_identity
  it "omits the view of a definition-only document, and a view never changes identity" $ do
    net <- expectRight (compileNetDefinition definitionFixture)
    plain <- expectRight (projectNetDocument net Nothing Nothing)
    arranged <- expectRight (projectNetDocument net (Just [("ingest", (FloatNumber 1.25, FloatNumber 2.5))]) Nothing)
    plain.view `shouldBe` Nothing
    encoded <- expectRight (serializeNetDocument plain)
    lookupMember "view" (mustJson encoded) `shouldBe` Nothing
    definitionIdentity plain `shouldBe` definitionIdentity arranged

  -- test_partial_fractional_view_is_valid_and_schema_is_strict
  it "admits a partial, fractional view and publishes a strict JSON Schema" $ do
    document <- expectRight (parseNetDocument (pyDumpsUnicode documentValue))
    let schema = netDocumentV1JsonSchema
    fmap (map (\n -> n.node) . (\v -> v.nodes)) document.view
      `shouldBe` Just ["review.correctness.pending", "review.correctness.review"]
    lookupMember "additionalProperties" schema `shouldBe` Just (Bool False)
    (lookupMember "properties" schema >>= lookupMember "format" >>= lookupMember "const") `shouldBe` Just (String "petrus-net-document")
    (lookupMember "properties" schema >>= lookupMember "version" >>= lookupMember "const") `shouldBe` Just (Int 1)
    Just (Object defs) <- pure (lookupMember "$defs" schema)
    [name | (name, item) <- defs, lookupMember "additionalProperties" item /= Just (Bool False)] `shouldBe` []
    -- Byte for byte the reference's model_json_schema(): JsonSchemaSpec.

  describe "test_malformed_or_confused_documents_are_refused" $ do
    let refuses label change message = it label (parseChanged change `shouldFailWith` message)
        viewInput = "{'version': 1, 'nodes': [..., 'x': 20.5, 'y': -40}]}"
    -- test_malformed_or_confused_documents_are_refused[version]
    refuses "a boolean version" (setAt [] "version" (Bool True)) $
      pydantic "version" "Value error, version must be the integer 1" "value_error" "True" "bool"
    -- test_malformed_or_confused_documents_are_refused[format]
    refuses "a Net-definition format" (setAt [] "format" (String "petrus-net-definition")) $
      pydantic "format" "Input should be 'petrus-net-document'" "literal_error" "'petrus-net-definition'" "str"
    -- test_malformed_or_confused_documents_are_refused[extra]
    refuses "an extra member" (setAt [] "extra" (Bool True)) $
      pydantic "extra" "Extra inputs are not permitted" "extra_forbidden" "True" "bool"
    -- test_malformed_or_confused_documents_are_refused[absent or an object]
    refuses "a null view" (setAt [] "view" Null) "view must be absent or an object, not null"
    -- test_malformed_or_confused_documents_are_refused[view.version]
    refuses "a boolean view version" (setAt [K "view"] "version" (Bool True)) $
      pydantic "view.version" "Value error, version must be the integer 1" "value_error" "True" "bool"
    -- test_malformed_or_confused_documents_are_refused[view extra]
    refuses "an extra view member" (setAt [K "view"] "extra" (Bool True)) $
      pydantic "view.extra" "Extra inputs are not permitted" "extra_forbidden" "True" "bool"
    -- test_malformed_or_confused_documents_are_refused[Unicode scalar]
    refuses "reversed view nodes" (editAt [K "view", K "nodes"] (\case Array xs -> Array (reverse xs); v -> v)) $
      pydantic "view" "Value error, view nodes must be sorted by Unicode scalar value" "value_error" viewInput "dict"
    -- test_malformed_or_confused_documents_are_refused[unique]
    refuses "a duplicated view node" (editAt [K "view", K "nodes"] (\case Array xs -> Array (xs <> take 1 xs); v -> v)) $
      pydantic "view" "Value error, view node paths must be unique" "value_error" viewInput "dict"
    -- test_malformed_or_confused_documents_are_refused[foreign]
    refuses "a foreign view node" (setAt [K "view", K "nodes", I 0] "node" (String "foreign"))
      "view contains foreign definition node 'foreign'"
    -- test_malformed_or_confused_documents_are_refused[NetPath]
    refuses "a malformed view node path" (setAt [K "view", K "nodes", I 0] "node" (String "review..pending")) $
      pydantic "view.nodes.0.node" "Value error, NetPath segments must be non-empty, got 'review..pending'" "value_error" "'review..pending'" "str"
    -- test_malformed_or_confused_documents_are_refused[definition]
    refuses "a definition of another version" (setAt [K "definition"] "version" (Int 2)) $
      pydantic "definition.version" "Input should be 3" "literal_error" "2" "int"

  describe "test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate" $ do
    -- test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate[duplicate]
    it "refuses a duplicate member" $
      parseNetDocument "{\"format\":\"petrus-net-document\",\"format\":\"petrus-net-document\",\"version\":1,\"definition\":{}}"
        `shouldFailWith` "duplicate JSON member 'format'"
    -- test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate[NaN]
    it "refuses NaN" $
      parseNetDocument "{\"format\":\"petrus-net-document\",\"version\":1,\"definition\":{},\"view\":{\"version\":1,\"nodes\":[],\"x\":NaN}}"
        `shouldFailWith` "non-finite JSON number NaN"
    -- test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate[\xff]
    it "refuses malformed UTF-8" $
      parseNetDocument "\xff"
        `shouldFailWith` "invalid Petrus Net document v1: 'utf-8' codec can't decode byte 0xff in position 0: invalid start byte"
    -- test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate[surrogate]
    it "refuses an escaped lone surrogate" $
      parseNetDocument "{\"format\":\"petrus-net-document\",\"version\":1,\"definition\":\"\\ud800\"}"
        `shouldFailWith` "invalid Petrus Net document v1: JSON strings must contain Unicode scalar values"

  -- test_negative_interoperability_fixture_is_refused
  it "refuses the negative interoperability fixture" $ do
    fixture <- readSpec "net-document-v1-invalid-foreign-view.json"
    parseNetDocument fixture `shouldFailWith` "view contains foreign definition node 'foreign'"

  describe "test_view_coordinates_must_be_finite_interoperable_json_numbers" $ do
    let refuses label coordinate message =
          it label (parseChanged (setAt [K "view", K "nodes", I 0] "x" coordinate) `shouldFailWith` message)
    -- test_view_coordinates_must_be_finite_interoperable_json_numbers[nan]
    refuses "NaN" (Float (0 / 0)) "non-finite JSON number NaN"
    -- test_view_coordinates_must_be_finite_interoperable_json_numbers[inf]
    refuses "Infinity" (Float (1 / 0)) "non-finite JSON number Infinity"
    -- test_view_coordinates_must_be_finite_interoperable_json_numbers[-inf]
    refuses "-Infinity" (Float (-1 / 0)) "non-finite JSON number -Infinity"
    -- test_view_coordinates_must_be_finite_interoperable_json_numbers[10**400]
    refuses "10**400" (Int (10 ^ (400 :: Int))) "invalid Petrus Net document v1: integral JSON numbers must be within the JavaScript safe-integer range"
    -- test_view_coordinates_must_be_finite_interoperable_json_numbers[True]
    refuses "True" (Bool True) $
      pydantic "view.nodes.0.x" "Value error, coordinate must be a JSON number" "value_error" "True" "bool"
    -- test_view_coordinates_must_be_finite_interoperable_json_numbers["20"]
    refuses "\"20\"" (String "20") $
      pydantic "view.nodes.0.x" "Value error, coordinate must be a JSON number" "value_error" "'20'" "str"

  -- test_direct_model_serialization_revalidates_foreign_nodes_and_nonfinite_coordinates
  it "revalidates foreign nodes and non-finite coordinates on direct serialization and projection" $ do
    document <- expectRight (netDocumentFromJson documentValue)
    foreign' <- expectRight (netDocumentFromJson (setAt [K "view", K "nodes", I 0] "node" (String "foreign") documentValue))
    serializeNetDocument foreign' `shouldFailWith` "view contains foreign definition node 'foreign'"
    net <- expectRight (compileNetDefinition definitionFixture)
    projectNetDocument net (Just [("ingest", (FloatNumber (1 / 0), IntNumber 0))]) Nothing
      `shouldFailWith` "cannot project Petrus Net document v1: 1 validation error for NodePosition\nx\n  Value error, coordinate must be a finite interoperable JSON number [type=value_error, input_value=inf, input_type=float]\n    For further information visit https://errors.pydantic.dev/2.13/v/value_error"
    fixture <- readSpec "net-document-v1.json"
    serializeNetDocument document `shouldBe` Right fixture
