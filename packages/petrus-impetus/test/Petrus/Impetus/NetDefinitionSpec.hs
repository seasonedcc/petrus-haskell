-- | Port of @tests/petrus/impetus/test_net_definition.py@: conformance of the
-- flat, language-neutral Net-definition v3 protocol. Where the reference
-- matches a message fragment, this spec asserts the exact message the
-- reference produces.
module Petrus.Impetus.NetDefinitionSpec (spec) where

import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.NetDefinition
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport
import Petrus.Impetus.WireSupport
import Petrus.Json (Json (..), fromCodePoints, lookupMember)
import Test.Hspec

documentValue :: Json
documentValue = either (error . show) netDefinitionToJson (projectNetDefinition richNet)

-- | @parse_net_definition(json.dumps(value).encode())@ after a change.
parseChanged :: (Json -> Json) -> Either Text NetDefinitionV3
parseChanged change = parseNetDefinition (pyDumps (change documentValue))

valueError :: Text -> Text -> Text
valueError message input =
  "invalid Petrus Net-definition v3: 1 validation error for NetDefinitionV3\ndefinition\n  Value error, "
    <> message
    <> " [type=value_error, input_value="
    <> input
    <> ", input_type=dict]\n    For further information visit https://errors.pydantic.dev/2.13/v/value_error"

richInput :: Text
richInput = "{'name': 'portable-review...size(review.done) > 0'}}"

outsideRange :: Text -> Text
outsideRange n = "JSON integer " <> n <> " is outside the inclusive interoperable range [-9007199254740991, 9007199254740991]"

spec :: Spec
spec = describe "Petrus.Impetus.NetDefinition" $ do
  -- test_net_project_compile_and_json_fixed_points
  it "projects, compiles, and round-trips JSON as fixed points" $ do
    document <- expectRight (projectNetDefinition richNet)
    encoded <- expectRight (serializeNetDefinition document)
    parsed <- expectRight (parseNetDefinition encoded)
    compiled <- expectRight (compileNetDefinition parsed)
    parsed `shouldBe` document
    projectNetDefinition compiled `shouldBe` Right document
    serializeNetDefinition parsed `shouldBe` Right encoded
    -- observation.definition(compiled) is the definition's JSON value; the
    -- observation module is not part of this port, so the equivalent
    -- projection is checked directly.
    lookupMember "definition" (netDefinitionToJson document)
      `shouldBe` lookupMember "definition" (netDefinitionToJson parsed)
    BS.isSuffixOf "\n" encoded `shouldBe` True

  -- test_parallel_arcs_round_trip_without_wire_identity_and_rederive_the_same_uris
  it "round-trips parallel arcs without wire identity and rederives the same URIs" $ do
    let p = np "p"
        t = np "t"
        out = np "out"
        net =
          netOf
            [place p, place out]
            [transition t]
            [ Arc {source = p, target = t, mode = Consume, weight = 1, color = Nothing, filter = Just (FilterSymbol "same")}
            , Arc {source = p, target = t, mode = Read, weight = 1, color = Nothing, filter = Just (FilterSymbol "same")}
            , arc t out
            ]
    document <- expectRight (projectNetDefinition net)
    wire <- expectRight (serializeNetDefinition document)
    compiled <- expectRight (parseNetDefinition wire >>= compileNetDefinition)
    arcUris compiled `shouldBe` arcUris net
    filterUris compiled `shouldBe` filterUris net
    (projectNetDefinition compiled >>= serializeNetDefinition) `shouldBe` Right wire
    case getAt [K "definition", K "arcs"] (netDefinitionToJson document) of
      Array arcs' -> all (\a -> lookupMember "identity" a == Nothing) arcs' `shouldBe` True
      other -> expectationFailure ("arcs is not a list: " <> show other)

  -- test_exact_fixture_is_the_dsl_document_definition_in_loadable_v3_envelope
  it "reads the exact fixture as the DSL document's definition in a loadable v3 envelope" $ do
    fixture <- readSpec "net-definition-v3.json"
    portable <- mustJson <$> readSpec "net-document-v1-inspection.json"
    document <- expectRight (parseNetDefinition fixture)
    serializeNetDefinition document `shouldBe` Right fixture
    Just (netDefinitionToJson document) `shouldBe` lookupMember "definition" portable
    (compileNetDefinition document >>= projectNetDefinition) `shouldBe` Right document

  -- test_cross_language_integer_and_scalar_order_fixture_is_an_exact_fixed_point
  it "keeps the cross-language integer and scalar-order fixture an exact fixed point" $ do
    fixture <- readSpec "net-definition-v3-interoperability.json"
    NetDefinitionV3 body <- expectRight (parseNetDefinition fixture)
    map (\d -> d.path) body.places `shouldBe` ["place.\xe000", "place.😀"]
    map (\d -> d.path) body.transitions `shouldBe` ["transition.\xe000", "transition.😀"]
    map (\d -> take 1 d.timers) body.transitions
      `shouldBe` [[DelayDefinition jsonSafeIntegerMin], [UntilDefinition jsonSafeIntegerMax]]
    map (\a -> a.weight) (take 1 body.arcs) `shouldBe` [jsonSafeIntegerMax]
    serializeNetDefinition (NetDefinitionV3 body) `shouldBe` Right fixture
    (compileNetDefinition (NetDefinitionV3 body) >>= projectNetDefinition >>= serializeNetDefinition)
      `shouldBe` Right fixture

  describe "test_cross_language_negative_fixtures_are_refused" $ do
    -- test_cross_language_negative_fixtures_are_refused[INVALID_INTEGER_FIXTURE]
    it "refuses the out-of-range integer fixture" $ do
      fixture <- readSpec "net-definition-v3-invalid-integer.json"
      parseNetDefinition fixture `shouldFailWith` outsideRange "9007199254740992"
    -- test_cross_language_negative_fixtures_are_refused[INVALID_UTF16_ORDER_FIXTURE]
    it "refuses the UTF-16-ordered fixture" $ do
      fixture <- readSpec "net-definition-v3-invalid-utf16-order.json"
      parseNetDefinition fixture
        `shouldFailWith` valueError "places must have unique paths sorted by Unicode scalar value" "{'name': 'invalid-utf16-o... [], 'completion': None}"

  -- test_pydantic_schema_is_strict_and_versioned
  it "publishes a strict, versioned JSON Schema" $ do
    let schema = netDefinitionV3JsonSchema
        at' keys = foldl (\value key -> value >>= lookupMember key) (Just schema) keys
        bounded lo hi title' =
          Object [("maximum", Int hi), ("minimum", Int lo), ("title", String title'), ("type", String "integer")]
    at' ["additionalProperties"] `shouldBe` Just (Bool False)
    at' ["properties", "format", "const"] `shouldBe` Just (String "petrus-net-definition")
    at' ["properties", "version", "const"] `shouldBe` Just (Int 3)
    Just (Object defs) <- pure (at' ["$defs"])
    [name | (name, definition) <- defs, lookupMember "additionalProperties" definition /= Just (Bool False)] `shouldBe` []
    at' ["$defs", "DelayDefinition", "properties", "duration"] `shouldBe` Just (bounded jsonSafeIntegerMin jsonSafeIntegerMax "Duration")
    at' ["$defs", "UntilDefinition", "properties", "instant"] `shouldBe` Just (bounded jsonSafeIntegerMin jsonSafeIntegerMax "Instant")
    at' ["$defs", "ArcDefinition", "properties", "position", "maximum"] `shouldBe` Just (Int jsonSafeIntegerMax)
    at' ["$defs", "ArcDefinition", "properties", "position", "minimum"] `shouldBe` Just (Int 0)
    at' ["$defs", "ArcDefinition", "properties", "weight", "maximum"] `shouldBe` Just (Int jsonSafeIntegerMax)
    at' ["$defs", "ArcDefinition", "properties", "weight", "minimum"] `shouldBe` Just (Int 1)
    -- Byte for byte the reference's model_json_schema(): JsonSchemaSpec.

  describe "test_noncanonical_or_invalid_documents_are_refused" $ do
    let refuses label change message = it label (parseChanged change `shouldFailWith` message)
    -- test_noncanonical_or_invalid_documents_are_refused[version]
    refuses "a boolean version" (setAt [] "version" (Bool True)) $
      "invalid Petrus Net-definition v3: 1 validation error for NetDefinitionV3\nversion\n  Input should be 3 [type=literal_error, input_value=True, input_type=bool]\n    For further information visit https://errors.pydantic.dev/2.13/v/literal_error"
    -- test_noncanonical_or_invalid_documents_are_refused[format]
    refuses "a foreign format" (setAt [] "format" (String "foreign-format")) $
      "invalid Petrus Net-definition v3: 1 validation error for NetDefinitionV3\nformat\n  Input should be 'petrus-net-definition' [type=literal_error, input_value='foreign-format', input_type=str]\n    For further information visit https://errors.pydantic.dev/2.13/v/literal_error"
    -- test_noncanonical_or_invalid_documents_are_refused[extra]
    refuses "an extra member" (setAt [] "extra" (Bool True)) $
      "invalid Petrus Net-definition v3: 1 validation error for NetDefinitionV3\nextra\n  Extra inputs are not permitted [type=extra_forbidden, input_value=True, input_type=bool]\n    For further information visit https://errors.pydantic.dev/2.13/v/extra_forbidden"
    -- test_noncanonical_or_invalid_documents_are_refused[Unicode scalar]
    refuses "reversed places" (editAt [K "definition", K "places"] (\case Array xs -> Array (reverse xs); v -> v)) $
      valueError "places must have unique paths sorted by Unicode scalar value" richInput
    -- test_noncanonical_or_invalid_documents_are_refused[unique]
    refuses "a duplicated place" (editAt [K "definition", K "places"] (\case Array xs -> Array (xs <> take 1 xs); v -> v)) $
      valueError "places must have unique paths sorted by Unicode scalar value" richInput
    -- test_noncanonical_or_invalid_documents_are_refused[dense ordered]
    refuses "a sparse arc position" (setAt [K "definition", K "arcs", I 0] "position" (Int 2)) $
      valueError "arc positions must be the dense ordered range [0, len(arcs))" richInput
    -- test_noncanonical_or_invalid_documents_are_refused[exactly projectable: color]
    refuses "an arc without its place's effective color" (setAt [K "definition", K "arcs", I 0] "color" Null)
      "Petrus Net-definition v3 must already be canonical and exactly projectable"
    -- test_noncanonical_or_invalid_documents_are_refused[semantics: target]
    refuses "an arc to a missing node" (setAt [K "definition", K "arcs", I 0] "target" (String "missing"))
      "invalid Petrus Net-definition v3 semantics: arc must connect a place and a transition: source -> missing"
    -- test_noncanonical_or_invalid_documents_are_refused[exactly projectable: handler uri]
    refuses "a handler URI that is not the derived one" (setAt [K "definition", K "transitions", I 0, K "handler"] "uri" (String "transition:/wrong#handler"))
      "Petrus Net-definition v3 must already be canonical and exactly projectable"
    -- test_noncanonical_or_invalid_documents_are_refused[semantics: source guard]
    refuses
      "a guard on a source transition"
      ( setAt
          [K "definition", K "transitions", I 1]
          "guards"
          (Array [Object [("kind", String "cel"), ("expression", String "true"), ("uri", String "transition:/source#guard:$0")]])
      )
      "invalid Petrus Net-definition v3 semantics: transition source: guards on a source transition cannot be honored \8212 it fires only on external delivery, never through enabledness; found [Cel(expression='true')]"

  describe "test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate" $ do
    -- test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate[duplicate]
    it "refuses a duplicate member" $
      parseNetDefinition "{\"format\":\"petrus-net-definition\",\"format\":\"petrus-net-definition\",\"version\":3,\"definition\":{}}"
        `shouldFailWith` "duplicate JSON member 'format'"
    -- test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate[NaN]
    it "refuses NaN" $
      parseNetDefinition "{\"format\":\"petrus-net-definition\",\"version\":3,\"definition\":NaN}"
        `shouldFailWith` "non-finite JSON number NaN"
    -- test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate[\xff]
    it "refuses malformed UTF-8" $
      parseNetDefinition "\xff"
        `shouldFailWith` "invalid Petrus Net-definition v3: 'utf-8' codec can't decode byte 0xff in position 0: invalid start byte"
    -- test_strict_json_refuses_duplicate_nonfinite_utf8_and_surrogate[surrogate]
    it "refuses an escaped lone surrogate" $
      parseNetDefinition "{\"format\":\"petrus-net-definition\",\"version\":3,\"definition\":\"\\ud800\"}"
        `shouldFailWith` "JSON strings must contain Unicode scalar values"

  describe "test_every_json_number_token_is_interoperably_admitted_before_shape" $ do
    -- test_every_json_number_token_is_interoperably_admitted_before_shape[3.0]
    it "refuses 3.0" $ parseNetDefinition "{\"version\":3.0}" `shouldFailWith` "v3 JSON numbers must use integer token spelling, got 3.0"
    -- test_every_json_number_token_is_interoperably_admitted_before_shape[3e0]
    it "refuses 3e0" $ parseNetDefinition "{\"version\":3e0}" `shouldFailWith` "v3 JSON numbers must use integer token spelling, got 3e0"
    -- test_every_json_number_token_is_interoperably_admitted_before_shape[2**53]
    it "refuses 2**53" $ parseNetDefinition "{\"version\":9007199254740992}" `shouldFailWith` outsideRange "9007199254740992"
    -- test_every_json_number_token_is_interoperably_admitted_before_shape[-2**53]
    it "refuses -2**53" $ parseNetDefinition "{\"version\":-9007199254740992}" `shouldFailWith` outsideRange "-9007199254740992"

  describe "test_every_schema_owned_integer_refuses_values_outside_interoperable_range" $ do
    let above = Int (jsonSafeIntegerMax + 1)
        below = Int (jsonSafeIntegerMin - 1)
    -- test_every_schema_owned_integer_refuses_values_outside_interoperable_range[version]
    it "refuses an out-of-range version" $
      parseChanged (setAt [] "version" above) `shouldFailWith` outsideRange "9007199254740992"
    -- test_every_schema_owned_integer_refuses_values_outside_interoperable_range[duration]
    it "refuses an out-of-range delay duration" $
      parseChanged (setAt [K "definition", K "transitions", I 0, K "timers", I 0] "duration" below)
        `shouldFailWith` outsideRange "-9007199254740992"
    -- test_every_schema_owned_integer_refuses_values_outside_interoperable_range[instant]
    it "refuses an out-of-range until instant" $
      parseChanged (setAt [K "definition", K "transitions", I 0, K "timers", I 1] "instant" above)
        `shouldFailWith` outsideRange "9007199254740992"
    -- test_every_schema_owned_integer_refuses_values_outside_interoperable_range[position]
    it "refuses an out-of-range arc position" $
      parseChanged (setAt [K "definition", K "arcs", I 0] "position" above) `shouldFailWith` outsideRange "9007199254740992"
    -- test_every_schema_owned_integer_refuses_values_outside_interoperable_range[weight]
    it "refuses an out-of-range arc weight" $
      parseChanged (setAt [K "definition", K "arcs", I 0] "weight" above) `shouldFailWith` outsideRange "9007199254740992"

  -- enforced by types: test_models_are_deeply_immutable (Haskell values are
  -- immutable)

  -- test_runtime_projection_and_direct_model_serialization_refuse_surrogates
  -- (a 'Text' holds a lone surrogate only as WTF-8, "Petrus.Json.Wtf8")
  it "refuses lone surrogates when projecting a net or serializing a model" $ do
    projectNetDefinition (richNetNamed (Just (fromCodePoints "bad\xD800")))
      `shouldFailWith` "JSON strings must contain Unicode scalar values"
    document <- expectRight (projectNetDefinition richNet)
    let body = document.definition
        renamed = NetDefinitionV3 (NetDefinitionBody (Just (fromCodePoints "bad\xD800")) body.timeDomain body.places body.transitions body.arcs body.completion)
    serializeNetDefinition renamed `shouldFailWith` "JSON strings must contain Unicode scalar values"

  -- test_adversarial_json_nesting_is_normalized_to_protocol_error
  it "normalizes adversarial nesting to a protocol error" $
    parseNetDefinition (BS.replicate 2000 91 <> BS.replicate 2000 93)
      `shouldFailWith` "invalid Petrus Net-definition v3: maximum recursion depth exceeded"

  describe "test_runtime_projection_refuses_integers_outside_interoperable_range" $ do
    let p = np "place"
        t = np "transition"
    -- test_runtime_projection_refuses_integers_outside_interoperable_range[until]
    it "refuses an out-of-range until instant" $
      projectNetDefinition
        (netOf [place p] [Transition {path = t, handler = Nothing, guards = [], timers = [Until (IntNumber (jsonSafeIntegerMax + 1))]}] [arc p t])
        `shouldFailWith` "v3 Until instant 9007199254740992 is outside the inclusive interoperable range [-9007199254740991, 9007199254740991]"
    -- test_runtime_projection_refuses_integers_outside_interoperable_range[weight]
    it "refuses an out-of-range arc weight" $
      projectNetDefinition
        (netOf [place p] [transition t] [Arc {source = p, target = t, mode = Consume, weight = fromInteger (jsonSafeIntegerMax + 1), color = Nothing, filter = Nothing}])
        `shouldFailWith` "v3 arc weight 9007199254740992 is outside the inclusive interoperable range [-9007199254740991, 9007199254740991]"

  -- Not an upstream test: NetDefinitionV3.model_validate(value, strict=True)
  -- on dicts holding lone surrogates, probed on the pinned reference.
  -- pydantic-core reads a literal and an unknown member's name as UTF-8,
  -- and the second ends the model's validation.
  describe "model validation of lone surrogates (pydantic-core string_unicode)" $ do
    let unicode loc input =
          loc
            <> "  Input should be a valid string, unable to parse raw data as a unicode string [type=string_unicode, input_value="
            <> input
            <> ", input_type=str]\n    For further information visit https://errors.pydantic.dev/2.13/v/string_unicode"
        header n = n <> " for NetDefinitionV3\n"
    it "ends a model's validation at an unknown member named with one" $ do
      netDefinitionFromJson (Object [("format", String "petrus-net-definition"), ("version", Int 3), (fromCodePoints "\xD800", Int 1), (fromCodePoints "x\xDC00", Int 2)])
        `shouldFailWith` (header "1 validation error" <> unicode "" "'\\ud800'")
      netDefinitionFromJson (Object [("format", String "petrus-net-definition"), ("version", Int 3), ("definition", Object [(fromCodePoints "\xDFFF", Int 1), ("name", Int 5)])])
        `shouldFailWith` (header "1 validation error" <> unicode "definition\n" "'\\udfff'")
    it "refuses one in a literal, beside the other errors" $
      netDefinitionFromJson
        (Object [("format", String (fromCodePoints "petrus-net-definition\xD800")), ("version", String "3"), ("definition", Object [("name", Int 5), ("time_domain", String (fromCodePoints "integer\xD800"))])])
        `shouldFailWith` T.intercalate
          "\n"
          ( (header "8 validation errors" <> unicode "format\n" "'petrus-net-definition\\ud800'")
              : "version\n  Input should be 3 [type=literal_error, input_value='3', input_type=str]\n    For further information visit https://errors.pydantic.dev/2.13/v/literal_error"
              : "definition.name\n  Input should be a valid string [type=string_type, input_value=5, input_type=int]\n    For further information visit https://errors.pydantic.dev/2.13/v/string_type"
              : unicode "definition.time_domain\n" "'integer\\ud800'"
              : [ "definition." <> name <> "\n  Field required [type=missing, input_value={'name': 5, 'time_domain': 'integer\\ud800'}, input_type=dict]\n    For further information visit https://errors.pydantic.dev/2.13/v/missing"
                | name <- ["places", "transitions", "arcs", "completion"]
                ]
          )
