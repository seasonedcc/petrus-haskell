-- | Parity: @tests/petrus/impetus/petrinet/test_schema.py@.
module Petrus.Impetus.SchemaSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport
import Test.Hspec

-- | @a -> t -> b@.
lineNet :: Net
lineNet = netOf [place (np "a"), place (np "b")] [transition (np "t")] [arc (np "a") (np "t"), arc (np "t") (np "b")]

netIsSource :: NetPath -> Bool
netIsSource at =
  let net =
        netOf
          [place (np "a"), place (np "out")]
          [transition (np "t"), transition (np "src")]
          [arc (np "a") (np "t"), arc (np "src") (np "out")]
   in isSource net at

spec :: Spec
spec = describe "Petrinet.Schema" $ do
  describe "NetPath" $ do
    -- TestNetPath.test_dotted_string_splits_into_segments
    it "splits a dotted path into segments" $ do
      netPathSegments (np "review.start") `shouldBe` ["review", "start"]
      netPathText (np "review.start") `shouldBe` "review.start"
    -- TestNetPath.test_empty_address_is_rejected
    it "rejects an empty path" $
      netPath "" `shouldFailWith` "NetPath requires a non-empty dotted string or a NetPath, got ''"
    it "rejects empty segments" $
      netPath "a..b" `shouldFailWith` "NetPath segments must be non-empty, got 'a..b'"
    it "reprs like the reference" $
      show (np "a.b") `shouldBe` "NetPath('a.b')"
    -- test_single_segment
    it "keeps a single segment" $
      netPathSegments (np "start") `shouldBe` ["start"]
    -- test_str_round_trips
    it "round-trips its string spelling" $
      netPathText (np "review.start") `shouldBe` "review.start"
    -- test_coercing_a_netpath_is_idempotent: there is no coercion from a
    -- NetPath (enforced by types); re-parsing its spelling yields an equal path.
    it "re-parses its own spelling to an equal path" $
      netPath (netPathText (np "review.start")) `shouldBe` Right (np "review.start")
    -- test_empty_path_segment_is_rejected (parametrized)
    it "rejects a leading empty segment" $
      netPath ".a" `shouldFailWith` "NetPath segments must be non-empty, got '.a'"
    it "rejects a trailing empty segment" $
      netPath "a." `shouldFailWith` "NetPath segments must be non-empty, got 'a.'"

  describe "NetUri" $ do
    it "addresses arcs with and without occurrences" $ do
      netUriText (arcUri (np "a") (np "t") Nothing) `shouldBe` "arc:/a->/t"
      netUriText (arcUri (np "a.b") (np "t") (Just 2)) `shouldBe` "arc:/a/b->/t#$2"
    it "percent-encodes declaration names" $ do
      uri <- expectRight (declarationUri TransitionOwner (np "t") "guard" (Just "é ok$"))
      netUriText uri `shouldBe` "transition:/t#guard:%C3%A9%20ok$"
    it "rejects non-canonical spellings" $ do
      netUri "arc:/a->/t%2f" `shouldFailWith` "invalid canonical NetUri 'arc:/a->/t%2f'"
      netUri "http://x" `shouldFailWith` "invalid canonical NetUri 'http://x'"
    -- test_declaration_uri_escapes_path_segments_and_names_canonically
    it "escapes declaration path segments and names canonically" $ do
      uri <- expectRight (declarationUri TransitionOwner (np "review/a.start") "guard" (Just "ready now?"))
      netUriText uri `shouldBe` "transition:/review%2Fa/start#guard:ready%20now%3F"
      show uri `shouldBe` "NetUri('transition:/review%2Fa/start#guard:ready%20now%3F')"
    -- enforced by types: test_declaration_uri_rejects_unknown_owner (UriOwner is closed)
    -- test_arc_and_filter_uris_escape_endpoint_segments_and_preserve_one_fragment
    it "escapes arc endpoints and preserves one fragment for the arc filter" $ do
      let uri = arcUri (np "review/a.start") (np "run now") (Just 1)
      netUriText uri `shouldBe` "arc:/review%2Fa/start->/run%20now#$1"
      fmap netUriText (arcFilterUri uri) `shouldBe` Right "arc:/review%2Fa/start->/run%20now#filter:$1"
    -- test_arc_filter_refuses_a_declaration_uri_as_its_owner
    it "refuses a declaration URI as an arc filter owner" $ do
      owner <- expectRight (netUri "arc:/pending->/review#filter:$0")
      arcFilterUri owner
        `shouldFailWith` "arc filter owner must use a generated occurrence fragment, got NetUri('arc:/pending->/review#filter:$0')"
    -- test_noncanonical_uri_is_rejected (parametrized)
    it "rejects a URI without an owner prefix" $
      netUri "transition" `shouldFailWith` "invalid canonical NetUri 'transition'"
    it "rejects a URI with whitespace" $
      netUri "transition:/review start" `shouldFailWith` "invalid canonical NetUri 'transition:/review start'"
    it "rejects lowercase percent escapes" $
      netUri "transition:/review%2fstart" `shouldFailWith` "invalid canonical NetUri 'transition:/review%2fstart'"

  describe "Net" $ do
    it "rejects an arc between two places" $
      mkNet (netSpec [place (np "a"), place (np "b")] [] [arc (np "a") (np "b")])
        `shouldFailWith` "arc must connect a place and a transition: a -> b"
    -- Beyond upstream: canonical_net_path, the protocol doors' path
    -- normalization. Messages captured from the reference.
    it "canonicalizes an exact protocol spelling (canonical_net_path)" $ do
      canonicalNetPath (np "a.b") `shouldBe` Right (np "a.b")
      canonicalNetPath ("a.b" :: T.Text) `shouldBe` Right (np "a.b")
      canonicalNetPath ("" :: T.Text) `shouldFailWith` "NetPath requires a non-empty dotted string or a NetPath, got ''"
      canonicalNetPath ("a..b" :: T.Text) `shouldFailWith` "NetPath segments must be non-empty, got 'a..b'"
    -- Beyond upstream (spec/net-schema.md, Arcs: "validation MUST reject
    -- place -> place and transition -> transition"); upstream tests only the
    -- first. The message is the reference's.
    it "rejects an arc between two transitions" $
      mkNet (netSpec [place (np "p")] [transition (np "a"), transition (np "b")] [arc (np "a") (np "b")])
        `shouldFailWith` "arc must connect a place and a transition: a -> b"
    it "resolves a place color onto untyped incident arcs" $ do
      let net = netOf [coloredPlace (np "p") "Order"] [transition (np "t")] [arc (np "p") (np "t")]
      map (.color) (netArcs net) `shouldBe` [Just "Order"]
    it "identifies source transitions" $ do
      let net = netOf [place (np "out")] [transition (np "src")] [arc (np "src") (np "out")]
      isSource net (np "src") `shouldBe` True
      sourceTransitions net `shouldBe` [np "src"]

    -- test_anonymous_declaration_display_name_is_non_semantic
    it "treats an anonymous declaration's display name as non-semantic" $ do
      named <- expectRight (anonymousNamed "review_matches")
      named.displayName `shouldBe` Just "review_matches"
      named `shouldBe` anonymous
    -- test_anonymous_declaration_rejects_invalid_display_name ('' case; the
    -- non-string case is enforced by types)
    it "rejects an empty anonymous display name" $ do
      anonymousNamed "" `shouldFailWith` "anonymous declaration display name must be a non-empty string or None, got ''"
      mkNet
        ( netSpec
            [place (np "p")]
            [(transition (np "t")) {handler = Just (HandlerAnonymous (AnonymousDeclaration (Just "")))}]
            [arc (np "p") (np "t")]
        )
        `shouldFailWith` "anonymous declaration display name must be a non-empty string or None, got ''"

    -- test_transition_behavior_declaration_indexes_are_canonical_and_immutable
    -- (immutability is enforced by types)
    it "indexes transition behavior declarations canonically" $ do
      let source = np "source"
          at = np "review.publish"
          target = np "target"
          inline = GuardCel (unsafeCel "source.color == 'Generation'")
          declared = [GuardSymbol "ready", GuardAnonymous anonymous, inline, GuardAnonymous anonymous]
          net =
            netOf
              [place source, place target]
              [(transition at) {handler = Just (HandlerAnonymous anonymous), guards = declared}]
              [arc source at, arc at target]
      handler <- expectRight (declarationUri TransitionOwner at "handler" Nothing)
      uris <- mapM (\n -> expectRight (declarationUri TransitionOwner at "guard" (Just n))) ["ready", "$1", "$2", "$3"]
      handlerUri net at `shouldBe` Just handler
      guardUris net at `shouldBe` uris
      handlerDeclarations net `shouldBe` [(handler, HandlerAnonymous anonymous)]
      guardDeclarations net `shouldBe` zip uris declared

    -- test_arc_occurrences_and_filters_are_position_aligned_and_immutable
    it "aligns arc occurrences and filters by position" $ do
      let p = np "p"
          t = np "t"
          out = np "out"
          repeated = (arc p t) {filter = Just (FilterSymbol "accept")}
          output = arc t out
          net = netOf [place p, place out] [transition t] [repeated, output, repeated]
      first' <- expectRight (netUri "arc:/p->/t#$0")
      outputUri <- expectRight (netUri "arc:/t->/out")
      second' <- expectRight (netUri "arc:/p->/t#$1")
      filter0 <- expectRight (netUri "arc:/p->/t#filter:$0")
      filter1 <- expectRight (netUri "arc:/p->/t#filter:$1")
      netArcs net `shouldBe` [repeated, output, repeated]
      arcUris net `shouldBe` [first', outputUri, second']
      filterUris net `shouldBe` [Just filter0, Nothing, Just filter1]
      inputs net t `shouldBe` [repeated, repeated]
      [position | (position, _, _) <- inputPositions net t] `shouldBe` [0, 2]
      filterDeclarations net `shouldBe` [(filter0, FilterSymbol "accept"), (filter1, FilterSymbol "accept")]

    -- test_unique_arc_and_filter_use_unfragmented_occurrence_address
    it "addresses a unique arc without a fragment" $ do
      expected <- expectRight (netUri "arc:/a->/t")
      arcUriAt lineNet 0 `shouldBe` Just expected
      filterUris lineNet `shouldBe` [Nothing, Nothing]

    -- test_generated_declaration_namespace_is_reserved (parametrized)
    it "reserves the generated namespace for handlers" $
      mkNet (netSpec [] [(transition (np "t")) {handler = Just (HandlerSymbol "$generated")}] [])
        `shouldFailWith` "handler symbol must be non-empty and cannot start with '$', got '$generated': t"
    it "reserves the generated namespace for guards" $
      mkNet (netSpec [] [Transition (np "t") Nothing [GuardSymbol "$0"] []] [])
        `shouldFailWith` "guard symbol must be non-empty and cannot start with '$', got '$0': t"

    -- test_duplicate_named_guards_are_rejected
    it "rejects duplicate named guards" $
      mkNet (netSpec [] [Transition (np "t") Nothing [GuardSymbol "ready", GuardSymbol "ready"] []] [])
        `shouldFailWith` "duplicate named guard 'ready': t"

    -- test_inputs_and_outputs_are_indexed
    it "indexes inputs and outputs" $ do
      map (.source) (inputs lineNet (np "t")) `shouldBe` [np "a"]
      map (.target) (outputs lineNet (np "t")) `shouldBe` [np "b"]

    -- test_transition_with_inputs_is_not_a_source
    it "does not treat a transition with inputs as a source" $
      netIsSource (np "t") `shouldBe` False
    -- test_transition_without_inputs_is_a_source
    it "treats a transition without inputs as a source" $
      netIsSource (np "src") `shouldBe` True

    -- test_name_collision_is_rejected
    it "rejects a place/transition name collision" $
      mkNet (netSpec [place (np "x")] [transition (np "x")] [])
        `shouldFailWith` "place/transition name collision: ['x']"

    -- test_duplicate_node_paths_are_rejected_before_dictionary_collapse
    it "rejects duplicate node paths" $ do
      mkNet (netSpec [place (np "p"), place (np "p")] [transition (np "t")] []) `shouldFailWith` "duplicate place path"
      mkNet (netSpec [place (np "p")] [transition (np "t"), transition (np "t")] []) `shouldFailWith` "duplicate transition path"

    -- test_place_to_place_arc_is_rejected
    it "rejects a place-to-place arc" $
      mkNet (netSpec [place (np "a"), place (np "b")] [] [arc (np "a") (np "b")])
        `shouldFailContaining` "connect a place and a transition"

    -- test_input_arcs_preserve_definition_order_across_modes
    it "preserves input arc definition order across modes" $ do
      let t = np "t"
          net =
            netOf
              [place (np "p"), place (np "q"), place (np "r")]
              [transition t]
              [(arc (np "p") t) {mode = Read}, arc (np "q") t, (arc (np "r") t) {mode = Inhibit}]
      map (.mode) (inputs net t) `shouldBe` [Read, Consume, Inhibit]

    -- test_arc_mode_predicates_expose_semantic_vocabulary (parametrized)
    describe "arc mode predicates" $
      mapM_
        ( \(m, expected) ->
            it ("expose the vocabulary for " <> show m) $ do
              let a = (arc (np "p") (np "t")) {mode = m}
              (isConsume a, isRead a, isInhibit a) `shouldBe` expected
        )
        [(Consume, (True, False, False)), (Read, (False, True, False)), (Inhibit, (False, False, True))]

    -- test_read_or_inhibit_only_transition_without_a_handler_is_rejected
    it "rejects a read-only transition without a handler" $
      mkNet (netSpec [place (np "p")] [transition (np "t")] [(arc (np "p") (np "t")) {mode = Read}])
        `shouldFailWith` "transition t: a non-source transition with no consume input arc and no handler would fire forever consuming and producing nothing"

    -- test_read_or_inhibit_only_transition_with_a_handler_is_legal
    it "accepts a read-only transition with a handler" $ do
      let net =
            netOf
              [place (np "p")]
              [(transition (np "t")) {handler = Just (HandlerSymbol "emit")}]
              [(arc (np "p") (np "t")) {mode = Read}]
      inputs net (np "t") `shouldSatisfy` (not . null)

    -- test_guards_on_a_source_transition_are_rejected
    it "rejects guards on a source transition in both encodings" $ do
      let build g = mkNet (netSpec [place (np "p")] [Transition (np "src") Nothing [g] []] [arc (np "src") (np "p")])
          prefix = "transition src: guards on a source transition cannot be honored — it fires only on external delivery, never through enabledness; found "
      build (GuardSymbol "ready") `shouldFailWith` (prefix <> "['ready']")
      build (GuardCel (unsafeCel "1 == 1")) `shouldFailWith` (prefix <> "[Cel(expression='1 == 1')]")

    -- test_arc_weight_must_be_a_positive_integer (the 0 case; True, 1.0, 1.5
    -- and "1" are enforced by types)
    it "rejects a weight below one" $
      mkNet (netSpec [place (np "a")] [transition (np "t")] [(arc (np "a") (np "t")) {weight = 0}])
        `shouldFailWith` "arc weight must be an integer >= 1, got 0: a -> t"

    -- enforced by types: test_arc_mode_must_be_the_closed_enum

    -- test_filter_symbol_uses_the_authored_symbol_namespace (parametrized)
    it "rejects an empty filter symbol" $
      mkNet (netSpec [place (np "a")] [transition (np "t")] [(arc (np "a") (np "t")) {filter = Just (FilterSymbol "")}])
        `shouldFailWith` "filter symbol must be non-empty and cannot start with '$', got '': a -> t"
    it "rejects a generated filter symbol" $
      mkNet (netSpec [place (np "a")] [transition (np "t")] [(arc (np "a") (np "t")) {filter = Just (FilterSymbol "$generated")}])
        `shouldFailWith` "filter symbol must be non-empty and cannot start with '$', got '$generated': a -> t"

    -- test_mode_on_an_output_arc_is_rejected
    it "rejects a mode on an output arc" $
      mkNet (netSpec [place (np "p")] [transition (np "t")] [arc (np "p") (np "t"), (arc (np "t") (np "p")) {mode = Read}])
        `shouldFailWith` "mode on output arc t -> p: modes are input inscriptions"

    -- test_typed_output_arc_admits_its_color_only
    it "lets a typed output arc admit its color only" $ do
      let a = withArcColor (Just "X") (arc (np "t") (np "b"))
      arcAdmits a (tok "X").color `shouldBe` True
      arcAdmits a (tok "Y").color `shouldBe` False
      arcAdmits a black.color `shouldBe` False

    -- test_untyped_arc_admits_anything
    it "lets an untyped arc admit anything" $ do
      let a = arc (np "t") (np "b")
      arcAdmits a (tok "X").color `shouldBe` True
      arcAdmits a black.color `shouldBe` True

    -- test_typed_place_resolves_untyped_input_and_output_arcs_once (parametrized)
    describe "typed places" $
      mapM_
        ( \m ->
            it ("resolve untyped input and output arcs once for " <> show m) $ do
              let source = np "source"
                  target = np "target"
                  at = np "move"
                  net =
                    netOf
                      [coloredPlace source "Input", coloredPlace target "Output"]
                      [(transition at) {handler = if m /= Consume then Just (HandlerSymbol "move") else Nothing}]
                      [(arc source at) {mode = m}, arc at target]
                  expectedInput = withArcColor (Just "Input") ((arc source at) {mode = m})
                  expectedOutput = withArcColor (Just "Output") (arc at target)
              inputs net at `shouldBe` [expectedInput]
              outputs net at `shouldBe` [expectedOutput]
              netArcs net `shouldBe` [expectedInput, expectedOutput]
        )
        [minBound .. maxBound]

    -- test_explicit_arc_color_remains_the_contract_of_an_untyped_place
    it "keeps an explicit arc color as the contract of an untyped place" $ do
      let source = np "source"
          target = np "target"
          at = np "move"
          net =
            netOf
              [place source, place target]
              [transition at]
              [withArcColor (Just "Input") (arc source at), withArcColor (Just "Output") (arc at target)]
      map (.color) (inputs net at) `shouldBe` [Just "Input"]
      map (.color) (outputs net at) `shouldBe` [Just "Output"]

    -- test_explicit_arc_color_cannot_conflict_with_its_place (parametrized)
    describe "an explicit arc color conflicting with its place" $
      mapM_
        ( \(a, endpoint) ->
            it ("is rejected on " <> T.unpack endpoint) $
              mkNet (netSpec [coloredPlace (np "source") "Expected"] [transition (np "move")] [a])
                `shouldFailWith` ("arc " <> endpoint <> " declares color 'Other', incompatible with place source color 'Expected'")
        )
        [ (withArcColor (Just "Other") (arc (np "source") (np "move")), "source -> move")
        , (withArcColor (Just "Other") (arc (np "move") (np "source")), "move -> source")
        ]

    -- test_place_color_must_be_a_non_empty_nominal_name_or_none ('' case; 7,
    -- False and a class are enforced by types)
    it "rejects an empty place color" $
      mkNet (netSpec [coloredPlace (np "typed") ""] [] [])
        `shouldFailWith` "place color must be a non-empty nominal color name or None, got '': typed"

    -- test_arc_color_must_be_a_non_empty_nominal_name_or_none ('' case; the
    -- rest are enforced by types)
    it "rejects an empty arc color" $
      mkNet (netSpec [place (np "source")] [transition (np "transition")] [withArcColor (Just "") (arc (np "source") (np "transition"))])
        `shouldFailWith` "arc color must be a non-empty nominal color name or None, got '': source -> transition"

    -- test_color_is_the_shared_language_neutral_nominal_name_alias
    it "spells a color as a plain nominal name" $ do
      let c :: Color
          c = "Generation"
      c `shouldBe` "Generation"

    -- enforced by types: test_node_views_are_read_only (Net is an immutable value)
    it "exposes node views as values" $
      Map.keys (netPlaces lineNet) `shouldBe` [np "a", np "b"]

  describe "Cel" $ do
    -- test_str_is_the_expression_source_presentation_only (the comparison to
    -- a bare string is enforced by types)
    it "presents its expression source without losing its tag" $ do
      let declaration = unsafeCel "amount >= 100"
      celExpression declaration `shouldBe` "amount >= 100"
      show declaration `shouldBe` "Cel(expression='amount >= 100')"
    -- test_a_named_symbol_and_an_equal_spelled_expression_stay_distinct_keys
    it "keeps a symbol and an equally spelled expression as distinct keys" $ do
      let registry = Map.fromList [(BySymbol "armed", "symbol-bound" :: String), (ByCel (unsafeCel "armed"), "expression-bound")]
      Map.lookup (BySymbol "armed") registry `shouldBe` Just "symbol-bound"
      Map.lookup (ByCel (unsafeCel "armed")) registry `shouldBe` Just "expression-bound"
    -- test_an_empty_expression_is_rejected
    it "rejects an empty expression" $
      cel "" `shouldFailWith` "Cel requires a non-empty expression string, got ''"
