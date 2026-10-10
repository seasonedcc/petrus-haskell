-- | Parity: @tests/petrus/impetus/dsl/test_petrinet_dsl.py@. Each example
-- names the upstream test it ports; cases the Haskell types make
-- unrepresentable are listed in PARITY.md (and pinned here by a comment
-- where a neighbouring assertion is still checked).
module Petrus.Impetus.DslSpec (spec) where

import Control.Monad (void)
import Data.Either (isLeft)
import Data.Maybe (listToMaybe)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Petrus.Impetus.Binding (BoundHandler (..), Handler, HandlerResult (..), TypedArgs, handlerTokens, param)
import Petrus.Impetus.Dsl
import Petrus.Impetus.Dsl.Support
import Petrus.Impetus.Instance (InstanceConfig (..), defaultInstanceConfig, marking, newInstance, run)
import Petrus.Impetus.NetDocument (projectNetDocument, serializeNetDocument)
import Petrus.Impetus.Petrinet.Enabledness (Binding (..))
import Petrus.Impetus.Petrinet.Marking (Token (..), markingFromList)
import Petrus.Impetus.Petrinet.Schema
  ( AnonymousDeclaration (..)
  , Arc (..)
  , GuardDeclaration (..)
  , HandlerDeclaration (..)
  , Place (..)
  , Transition (..)
  , guardUris
  , handlerUri
  , netArcs
  , netName
  , netPlaces
  , netTransitions
  , netUriText
  )
import Petrus.Impetus.Petrinet.Schema qualified as Schema
import Petrus.Json (Json (..))
import Test.Hspec hiding (after, before, pending)
import Petrus.Impetus.DslCorpusSpec (locate)
import Data.ByteString qualified as BS

-- | Author and build, expecting success.
built :: HasCallStack => Header -> (forall s. Author s a) -> IO BuiltNet
built header program = case netSpec header program >>= build of
  Right b -> pure b
  Left err -> expectationFailure ("expected a build, got " <> show err) >> error "unreachable"

-- | Author, expecting success.
authored :: HasCallStack => Header -> (forall s. Author s a) -> IO NetSpec
authored header program = case netSpec header program of
  Right s -> pure s
  Left err -> expectationFailure ("expected a specification, got " <> show err) >> error "unreachable"

-- | The outcome is refused with exactly this message.
refusedWith :: HasCallStack => Either DslError a -> Text -> Expectation
refusedWith outcome text = case outcome of
  Left err -> err.message `shouldBe` text
  Right _ -> expectationFailure ("expected the refusal " <> show text)

placeOf :: BuiltNet -> Text -> Maybe Place
placeOf b at = Map.lookup (np at) (netPlaces b.net)

transitionOf :: BuiltNet -> Text -> Maybe Transition
transitionOf b at = Map.lookup (np at) (netTransitions b.net)

placePaths :: BuiltNet -> Set.Set Text
placePaths b = Set.fromList (map Schema.netPathText (Map.keys (netPlaces b.net)))

transitionPaths :: BuiltNet -> Set.Set Text
transitionPaths b = Set.fromList (map Schema.netPathText (Map.keys (netTransitions b.net)))

anonymousName :: Maybe HandlerDeclaration -> Maybe (Maybe Text)
anonymousName = \case
  Just (HandlerAnonymous (AnonymousDeclaration name)) -> Just name
  _ -> Nothing

consumeArc :: Text -> Text -> Maybe Text -> Arc
consumeArc from to c = Arc (np from) (np to) Consume 1 c Nothing

spec :: Spec
spec = describe "petrus.impetus.dsl" $ do
  -- test_path_proxies_return_stable_authored_spec_types
  it "returns stable node handles whose absolute paths follow the scope" $ do
    case runNetSpec (named "orders") $ do
      a <- p "pending"
      b <- p "pending"
      r1 <- scope "review" (p "pending")
      r2 <- scope "review" (p "pending")
      pure (a == b && r1 == r2, nodePath a, nodePath r1) of
      Right (_, outcome) -> outcome `shouldBe` (True, np "pending", np "review.pending")
      Left err -> expectationFailure (show err)
    -- Handles are distinct types (P s / T s), so @isinstance@ is the type;
    -- they expose 'nodePath' and nothing else.

  -- test_net_spec_name_is_optional_but_an_empty_name_is_rejected
  it "has an optional name and refuses an empty one" $ do
    unnamedSpec <- authored unnamed (void (p "pending" ~> t "process"))
    specName unnamedSpec `shouldBe` Nothing
    b <- either (fail . show) pure (build unnamedSpec)
    netName b.net `shouldBe` Nothing
    netSpec (named "") (pure ()) `refusedWith` "net specification name must be a non-empty string or None, got ''"

  -- test_apply_named_child_is_an_ordinary_scope_that_can_receive_a_stamp
  it "treats apply as an ordinary scope that can receive a stamp" $ do
    flat <- built (named "flat") (void (scope "apply" (p "pending" ~> t "process")))
    transitionPaths flat `shouldSatisfy` Set.member "apply.process"
    child <- authored (named "child") (void (p "pending" ~> t "process"))
    composed <- built (named "composed") (scope "apply" (stamp child))
    transitionPaths composed `shouldSatisfy` Set.member "apply.process"

  -- test_item_navigation_authors_python_reserved_scope_segments
  describe "authors scope segments the reference reserves (p, t, s, stamp)" $
    mapM_
      ( \segment -> it (show segment) $ do
          b <- built (named "reserved-scopes") (void (scope segment (p "pending" ~> t "process")))
          placePaths b `shouldSatisfy` Set.member (segment <> ".pending")
          transitionPaths b `shouldSatisfy` Set.member (segment <> ".process")
      )
      ["p", "t", "s", "stamp"]

  -- test_item_navigation_requires_exactly_one_non_empty_scope_segment
  describe "requires exactly one non-empty scope segment" $
    mapM_
      ( \segment -> it (show segment) $
          netSpec unnamed (scope segment (pure ()))
            `refusedWith` ("scope segment must be one non-empty path segment, got " <> quoted segment)
      )
      ["", "nested.scope"]

  -- test_item_navigation_rejects_non_string_scope_segments: enforced by
  -- types ('scope' takes 'Text').

  -- test_only_right_shift_builds_default_and_explicit_connections
  it "builds default and explicit connections with ~>" $ do
    b <- built (named "orders") $ do
      pending <- p "pending" >>= color "Order"
      receipt <- p "receipt" >>= color "Receipt"
      process <- t "process" >>= configure [handler "process"]
      void $ pending ~> process ~> receipt
      void $ pending ~> readArc {arcWeight = 2, arcColor = Just "Order", arcFilter = Just (FilterSymbol "current")} ~> process
    Map.elems (netPlaces b.net) `shouldBe` [Place (np "pending") (Just "Order"), Place (np "receipt") (Just "Receipt")]
    Map.elems (netTransitions b.net) `shouldBe` [Transition (np "process") (Just (HandlerSymbol "process")) [] []]
    netArcs b.net
      `shouldBe` [ consumeArc "pending" "process" (Just "Order")
                 , consumeArc "process" "receipt" (Just "Receipt")
                 , Arc (np "pending") (np "process") Read 2 (Just "Order") (Just (FilterSymbol "current"))
                 ]

  -- test_arc_and_connection_specs_preserve_authored_order_and_multiplicity
  it "preserves authored order and multiplicity, fanning out source-major" $ do
    s <- authored (named "multiplicity") $ do
      let inscription = arc {arcColor = Just "Order"}
      void $ sequence [p "left", p "right"] ~> inscription ~> sequence [t "first", t "second"]
      void $ p "left" ~> inscription ~> t "first"
    [(nodeRefPath c.source, nodeRefPath c.target) | c <- connections s]
      `shouldBe` [ (np "left", np "first")
                 , (np "left", np "second")
                 , (np "right", np "first")
                 , (np "right", np "second")
                 , (np "left", np "first")
                 ]
    map (.inscription) (connections s) `shouldSatisfy` all (== arc {arcColor = Just "Order"})

  -- test_arc_factory_names_modes_and_does_not_accept_mode_as_a_parameter
  it "names arc modes by factory" $ do
    arc.arcMode `shouldBe` Consume
    readArc.arcMode `shouldBe` Read
    inhibitArc.arcMode `shouldBe` Inhibit
    -- @arc(ArcMode.READ)@ / @arc(mode=...)@: enforced by types ('arc' is a
    -- value, not a function of a mode).

  -- test_build_snapshots_are_independent_and_implementation_maps_are_immutable
  it "builds independent snapshots" $ do
    first <- built (named "snapshots") (void (p "pending" ~> t "first"))
    second <- built (named "snapshots") (void (p "pending" ~> t "first") >> void (t "first" ~> p "done"))
    length (netArcs first.net) `shouldBe` 1
    length (netArcs second.net) `shouldBe` 2
    -- Immutable maps: enforced by types ('Map' values).

  -- test_cross_specification_failure_is_atomic: enforced by types (the
  -- rank-2 brand @s@ makes connecting handles of two specifications
  -- ill-typed).

  -- test_identical_configuration_is_idempotent_and_override_is_explicit
  it "makes identical configuration idempotent and change explicit" $ do
    let fields = [handler "first", guards ["ready"], timers [Delay (IntNumber 3)]]
    (s, results) <- expectRight $ runNetSpec (named "configuration") $ do
      transition <- t "process" >>= configure fields
      void $ (p "pending" >>= color "Order") ~> transition
      again <- configure fields transition
      conflict <- attempt (void (configure [handler "second"] transition))
      overridden <- override [handler "second"] transition
      pure (again == transition, conflict, overridden == transition)
    let (same, conflict, sameAfterOverride) = results
    same `shouldBe` True
    sameAfterOverride `shouldBe` True
    conflict `refusedWith` "transition process is already configured; use transition.override(...) to change it"
    b <- either (fail . show) pure (build s)
    Just declaration <- pure (transitionOf b "process")
    declaration.handler `shouldBe` Just (HandlerSymbol "second")
    declaration.guards `shouldBe` [GuardSymbol "ready"]
    declaration.timers `shouldBe` [Delay (IntNumber 3)]

  -- test_conflicting_place_color_fails_without_mutation
  it "refuses a conflicting place color without mutation" $ do
    case runNetSpec (named "places") $ do
      place <- p "pending" >>= color "Order"
      conflict <- attempt (void (color "Receipt" place))
      current <- placeColor place
      pure (conflict, current) of
      Right (_, (conflict, current)) -> do
        conflict `refusedWith` "place pending is already configured with color 'Order'"
        current `shouldBe` Just "Order"
      Left err -> expectationFailure (show err)

  -- test_place_override_changes_or_clears_color_and_requires_a_base
  it "overrides or clears a place color and requires a base" $ do
    let stage n = built (named "place-overrides") $ do
          place <- p "pending" >>= color "Order"
          if n >= (1 :: Int) then void (recolor (Just "Receipt") place) else pure ()
          if n >= 2 then void (recolor Nothing place) else pure ()
    before <- stage 0
    changed <- stage 1
    cleared <- stage 2
    (.color) <$> placeOf before "pending" `shouldBe` Just (Just "Order")
    (.color) <$> placeOf changed "pending" `shouldBe` Just (Just "Receipt")
    (.color) <$> placeOf cleared "pending" `shouldBe` Just Nothing
    netSpec (named "place-overrides") (void $ p "undeclared" >>= recolor (Just "Order"))
      `refusedWith` "place undeclared has no explicit or inherited configuration to override"

  -- test_transition_override_preserves_omitted_fields_and_explicitly_clears_values
  it "keeps omitted fields on override and clears given ones" $ do
    let stage n = built (named "transition-overrides") $ do
          transition <- t "process" >>= configure [handler "process", guards ["ready"], timers [Delay (IntNumber 3)]]
          void $ (p "pending" >>= color "Order") ~> transition
          void $ override [noHandler] transition
          if n >= (2 :: Int) then void (override [guards [], timers []] transition) else pure ()
    Just first <- transitionOf <$> stage 1 <*> pure "process"
    first.handler `shouldBe` Nothing
    first.guards `shouldBe` [GuardSymbol "ready"]
    first.timers `shouldBe` [Delay (IntNumber 3)]
    Just second <- transitionOf <$> stage 2 <*> pure "process"
    second.handler `shouldBe` Nothing
    second.guards `shouldBe` []
    second.timers `shouldBe` []

  -- test_transition_override_requires_a_base_and_at_least_one_field
  it "requires a base and at least one field to override a transition" $ do
    netSpec (named "invalid-overrides") (void $ t "undeclared" >>= override [handler "process"])
      `refusedWith` "transition undeclared has no explicit or inherited configuration to override"
    netSpec (named "invalid-overrides") (void $ t "process" >>= configure [handler "process"] >>= override [])
      `refusedWith` "transition override requires at least one of handler, guards, or timers"

  -- test_transition_override_is_atomic_when_a_supplied_field_is_invalid:
  -- the invalid value (a node used as a guard) is a type error; atomicity of
  -- a refused step is checked with a refusal that can happen.
  it "leaves the specification unchanged when an override is refused" $ do
    b <- built (named "atomic-overrides") $ do
      transition <- t "process" >>= configure [handler "process", guards ["ready"]]
      void $ (p "pending" >>= color "Order") ~> transition
      refused <- attempt (t "undeclared" >>= override [handler "changed", guards []])
      pure (isLeft refused)
    Just declaration <- pure (transitionOf b "process")
    declaration.handler `shouldBe` Just (HandlerSymbol "process")
    declaration.guards `shouldBe` [GuardSymbol "ready"]

  -- test_callable_specs_configure_stable_identity_reused_by_bare_references
  it "configures stable identities that later bare references reuse" $ do
    case runNetSpec (named "callable-specs") $ do
      transition <- t "publish"
      published <- p "published" >>= color "Receipt"
      audited <- p "audited" >>= color "Receipt"
      configured <- configure [handler "publish"] transition
      again <- t "publish"
      publishedAgain <- p "published"
      void $ transition ~> published
      void $ transition ~> audited
      pure (configured == transition && again == transition && publishedAgain == published) of
      Left err -> expectationFailure (show err)
      Right (s, stable) -> do
        stable `shouldBe` True
        b <- either (fail . show) pure (build s)
        Map.elems (netTransitions b.net) `shouldBe` [Transition (np "publish") (Just (HandlerSymbol "publish")) [] []]
        netArcs b.net
          `shouldBe` [consumeArc "publish" "published" (Just "Receipt"), consumeArc "publish" "audited" (Just "Receipt")]

  -- test_configuration_after_topology_applies_at_build_without_mutating_prior_snapshot
  it "applies configuration made after topology at build" $ do
    let program :: Bool -> Author s ()
        program late = do
          transition <- t "publish"
          void $ transition ~> (p "published" >>= color "Receipt")
          if late
            then void (configure [handler "publish"] transition) >> void (transition ~> (p "audit" >>= color "Receipt"))
            else pure ()
    before <- built (named "late-configuration") (program False)
    after <- built (named "late-configuration") (program True)
    ((.handler) <$> transitionOf before "publish") `shouldBe` Just Nothing
    ((.handler) <$> transitionOf after "publish") `shouldBe` Just (Just (HandlerSymbol "publish"))
    length (netArcs before.net) `shouldBe` 1
    length (netArcs after.net) `shouldBe` 2

  -- test_callable_node_specs_are_rejected_as_handler_and_guard_values:
  -- enforced by types ('HandlerSpec' and 'GuardSpec' are closed sums).

  -- test_canonical_net_remains_the_semantic_validation_boundary
  it "surfaces the canonical Net's refusals at build" $ do
    -- @net.p.left >> net.p.right@ does not type-check here (arcs join a
    -- place and a transition), so the boundary is checked with refusals only
    -- the canonical constructor makes.
    (netSpec (named "invalid") (void $ p "left" ~> arc {arcWeight = 0} ~> t "right") >>= build)
      `refusedWith` "arc weight must be an integer >= 1, got 0: left -> right"
    (netSpec (named "invalid") (void $ (p "left" >>= color "Order") ~> arc {arcColor = Just "Receipt"} ~> t "right") >>= build)
      `refusedWith` "arc left -> right declares color 'Receipt', incompatible with place left color 'Order'"

  -- test_python_comparison_operator_is_not_supported: enforced by types.
  -- test_color_adapter_rejects_non_type_objects: enforced by types (a color
  -- is 'Text', or 'colorOf' of a 'Typed' type).
  it "names a typed payload's color" $ colorOf @Order `shouldBe` "Order"

  -- test_direct_and_callable_guard_lower_after_place_colors_and_execute_by_declaration_uri
  it "lowers direct and typed guards by declaration URI and executes them" $ do
    b <- built (named "typed") $ do
      pending <- p "pending" >>= color "Order"
      receipt <- p "receipt" >>= color "Receipt"
      transition <-
        t "process" >>= configure [handler (direct "process" processArgs), guards [typedGuard "positive" positiveArgs]]
      void $ pending ~> transition ~> receipt
    Just declaration <- pure (transitionOf b "process")
    anonymousName declaration.handler `shouldBe` Just (Just "process")
    [name | GuardAnonymous (AnonymousDeclaration name) <- declaration.guards] `shouldBe` [Just "positive"]
    Map.keys b.handlers `shouldBe` [u | Just u <- [handlerUri b.net (np "process")]]
    Map.keys b.guards `shouldBe` guardUris b.net (np "process")
    let start = markingFromList [(np "pending", [Token (Just "Order") (Object [("amount", Int 4)])])]
    instance' <- newInstance b.net (withImplementations b defaultInstanceConfig {initialMarking = start}) >>= either (fail . show) pure
    _ <- run instance' >>= either (fail . show) pure
    final <- marking instance'
    final `shouldBe` markingFromList [(np "receipt", [Token (Just "Receipt") (Object [("total", Int 5)])])]

  -- test_typed_guard_uses_a_custom_converter_for_every_selected_input_and_stays_anonymous
  it "decodes every selected input through the guard's own types" $ do
    b <- built (named "custom-guard") $ do
      pending <- p "pending" >>= color "Order"
      configuration <- p "configuration" >>= color "Config"
      transition <- t "review" >>= configure [guards [typedGuard "within_limit" withinLimitArgs]]
      void $ pending ~> transition
      void $ configuration ~> readArc ~> transition
    let binding =
          Binding
            (np "review")
            [(np "pending", [Token (Just "Order") (Object [("amount", String "4")])])]
            [(np "configuration", [Token (Just "Config") (Object [("limit", String "5")])])]
            []
    [guard] <- pure (Map.elems b.guards)
    guard binding `shouldBe` Right True
    Just declaration <- pure (transitionOf b "review")
    [name | GuardAnonymous (AnonymousDeclaration name) <- declaration.guards] `shouldBe` [Just "within_limit"]
    map netUriText (Map.keys b.guards) `shouldBe` ["transition:/review#guard:$0"]

  -- test_typed_guard_factory_preserves_the_exact_bool_result_contract:
  -- enforced by types ('typedGuard' takes 'TypedArgs Bool').
  it "lowers a typed guard whose result is a Bool by construction" $ do
    b <- built (named "exact-bool") $ do
      pending <- p "pending" >>= color "Order"
      transition <- t "review" >>= configure [guards [typedGuard "truthy" (const True <$> (param "order" :: TypedArgs Order))]]
      void $ pending ~> transition
    [guard] <- pure (Map.elems b.guards)
    guard (Binding (np "review") [(np "pending", [Token (Just "Order") (Object [("amount", Int 4)])])] [] []) `shouldBe` Right True

  -- test_scalar_and_mixed_guard_forms_preserve_authored_order_and_absolute_positions
  it "keeps mixed guard order and absolute guard positions" $ do
    b <- built (named "guards") $ do
      transition <- t "review"
      let positive = typedGuard "positive" positiveArgs
      void $ configure [guards ["named", positive, celGuard (unsafeCel "true"), positive]] transition
      void $ (p "pending" >>= color "Order") ~> transition
    Just declaration <- pure (transitionOf b "review")
    declaration.guards
      `shouldBe` [GuardSymbol "named", GuardAnonymous (AnonymousDeclaration Nothing), GuardCel (unsafeCel "true"), GuardAnonymous (AnonymousDeclaration Nothing)]
    let uris = guardUris b.net (np "review")
    map netUriText uris
      `shouldBe` [ "transition:/review#guard:named"
                 , "transition:/review#guard:$1"
                 , "transition:/review#guard:$2"
                 , "transition:/review#guard:$3"
                 ]
    Map.keys b.guards `shouldBe` [uris !! 1, uris !! 3]
    scalarNet <- built (named "scalar") (void (t "review" >>= configure [guards ["named"]]) >> void (p "pending" ~> t "review"))
    ((.guards) <$> transitionOf scalarNet "review") `shouldBe` Just [GuardSymbol "named"]

  -- test_guards_reject_mutable_iterables_and_generators (×2): enforced by
  -- types (guards are an immutable list; there is no other form).

  -- test_handler_rejects_raw_callable_without_direct_or_advanced_flavor:
  -- enforced by types (a function is not a 'HandlerSpec').

  -- test_petri_aware_specs_use_owner_identity_not_callable_name
  it "keys Petri-aware implementations by owner identity" $ do
    b <- built (named "identity") $ do
      transition <- t "process" >>= configure [handler (petriHandler "<lambda>" marker), guards [petriGuard "<lambda>" trueGuard]]
      void $ p "pending" ~> transition
    map netUriText (Map.keys b.handlers) `shouldBe` ["transition:/process#handler"]
    map netUriText (Map.keys b.guards) `shouldBe` ["transition:/process#guard:$0"]
    case Map.elems b.handlers of
      [PureHandler h] -> (.tokens) <$> h (Binding (np "process") [] [] []) [] `shouldBe` Right [(np "marker", [])]
      _ -> expectationFailure "expected the supplied pure handler"

  -- test_same_callable_spec_reused_across_transitions_keeps_two_declarations
  it "keeps two declarations for one implementation reused on two transitions" $ do
    b <- built (named "reuse") $ do
      let specification = petriGuard "guard" trueGuard
      void $ t "left" >>= configure [guards [specification]]
      void $ t "right" >>= configure [guards [specification]]
      void $ p "pending" ~> sequence [t "left", t "right"]
    Map.size b.guards `shouldBe` 2

  -- test_build_snapshots_keep_the_callable_association_selected_at_build_time
  it "keeps the implementation selected at build time" $ do
    let program :: Bool -> Author s ()
        program second = do
          transition <- t "process" >>= configure [handler (petriHandler "first_handler" (tagged "first"))]
          void $ p "pending" ~> transition
          if second then void (override [handler (petriHandler "second_handler" (tagged "second"))] transition) else pure ()
    first <- built (named "callable-snapshots") (program False)
    second <- built (named "callable-snapshots") (program True)
    handlerTag first `shouldBe` Just "first"
    handlerTag second `shouldBe` Just "second"

  -- test_scope_stamp_rebases_reusable_definition_at_each_destination
  it "rebases a stamped definition at each destination" $ do
    lens <- authored (named "review-lens") $ do
      review <- t "review" >>= configure [handler (petriHandler "handler" emptyHandler), guards [petriGuard "guard" trueGuard]]
      void $ (p "work" >>= color "Order") ~> review ~> p "done"
      pure (nodePath review)
    (_, lensReview) <- either (fail . show) pure (runNetSpec (named "review-lens") (nodePath <$> t "review"))
    lensReview `shouldBe` np "review"
    (rootSpec, correctnessReview) <- expectRight $ runNetSpec (named "reviews") $ scope "review" $ do
      scope "correctness" (stamp lens)
      scope "risk" (stamp lens)
      void $ scope "correctness" (p "done" >>= color "Receipt")
      void $ scope "risk" (p "done" >>= color "Receipt")
      nodePath <$> scope "correctness" (t "review" >>= override [handler "correctness"])
    correctnessReview `shouldBe` np "review.correctness.review"
    b <- either (fail . show) pure (build rootSpec)
    placePaths b `shouldBe` Set.fromList ["review.correctness.work", "review.correctness.done", "review.risk.work", "review.risk.done"]
    ((.handler) <$> transitionOf b "review.correctness.review") `shouldBe` Just (Just (HandlerSymbol "correctness"))
    (anonymousName . (.handler) =<< transitionOf b "review.risk.review") `shouldBe` Just (Just "handler")
    Map.keys b.handlers `shouldBe` [u | Just u <- [handlerUri b.net (np "review.risk.review")]]
    Set.fromList (Map.keys b.guards)
      `shouldBe` Set.fromList (guardUris b.net (np "review.correctness.review") ++ guardUris b.net (np "review.risk.review"))

  -- test_flat_parent_authoring_and_stamped_child_authoring_compose_together
  it "composes flat parent authoring with a stamped child" $ do
    child <- authored (named "child") (void (p "pending" ~> t "finish" ~> p "done"))
    b <- built (named "root") $ scope "review" $ do
      void $ p "context" ~> t "publish"
      scope "correctness" (stamp child)
      void $ scope "correctness" (p "done") ~> t "publish"
    placePaths b `shouldSatisfy` Set.member "review.context"
    transitionPaths b `shouldSatisfy` Set.member "review.publish"
    transitionPaths b `shouldSatisfy` Set.member "review.correctness.finish"
    last (netArcs b.net) `shouldBe` consumeArc "review.correctness.done" "review.publish" Nothing

  -- test_stamped_specification_remains_live_between_immutable_build_snapshots:
  -- N/A (specifications are immutable values, so a stamp embeds the child
  -- as it was; a changed child is a new value stamped again). The produced
  -- nets are checked by the corpus cases live.first / live.second.
  it "builds each stamped child value as given" $ do
    child <- authored (named "child") (void (p "pending" ~> t "process" ~> p "done"))
    audited <- authored (named "child") (void (p "pending" ~> t "process" ~> p "done") >> void (t "process" ~> p "audit"))
    first <- built (named "root") (scope "worker" (stamp child))
    second <- built (named "root") (scope "worker" (stamp audited))
    placePaths first `shouldSatisfy` (not . Set.member "worker.audit")
    placePaths second `shouldSatisfy` Set.member "worker.audit"
    length (netArcs first.net) `shouldBe` 2
    length (netArcs second.net) `shouldBe` 3

  -- test_restamping_a_scope_replaces_the_base_and_clears_destination_overrides
  it "replaces the base and clears overrides when a scope is stamped again" $ do
    first <- authored (named "first") (void (p "pending" ~> (t "process" >>= configure [handler "first"]) ~> p "done"))
    second <- authored (named "second") (void (p "ready" ~> (t "process" >>= configure [handler "second"]) ~> p "complete"))
    b <- built (named "root") $ scope "worker" $ do
      stamp first
      void $ t "process" >>= override [handler "specialized"]
      stamp second
    placePaths b `shouldBe` Set.fromList ["worker.ready", "worker.complete"]
    ((.handler) <$> transitionOf b "worker.process") `shouldBe` Just (Just (HandlerSymbol "second"))

  -- test_stamp_refuses_to_erase_direct_content_without_mutating_the_scope
  it "refuses to stamp over direct content, without mutation" $ do
    child <- authored (named "child") (void (p "pending" ~> t "process"))
    (s, refused) <- expectRight $ runNetSpec (named "root") $ scope "worker" $ do
      void $ p "local"
      attempt (stamp child)
    refused `refusedWith` "cannot stamp child at worker: destination already owns place worker.local"
    b <- either (fail . show) pure (build s)
    placePaths b `shouldBe` Set.fromList ["worker.local"]

  -- test_stamp_diagnostics_identify_enclosing_stamp_and_requested_missing_node
  it "identifies the enclosing stamp and the requested missing node" $ do
    child <- authored (named "child") (void (p "pending" ~> t "process"))
    replacement <- authored unnamed (pure ())
    netSpec (named "root") (scope "worker" (stamp child >> scope "nested" (stamp replacement)))
      `refusedWith` "cannot stamp <anonymous> at worker.nested: scope belongs to child stamped at worker"
    netSpec (named "root") (scope "worker" (stamp child >> void (t "missing" >>= override [handler "missing"])))
      `refusedWith` "stamp of child at worker has no transition missing requested as worker.missing"

  -- test_root_stamp_and_missing_connection_diagnostics_name_the_composition_location
  it "names the composition location of root stamps and missing connections" $ do
    child <- authored (named "child") (void (p "pending" ~> t "process"))
    netSpec (named "root") (stamp child)
      `refusedWith` "cannot stamp child at <root>: reusable definitions require a non-root scope"
    root <- authored (named "root") $ do
      scope "worker" (stamp child)
      void $ scope "worker" (p "missing") ~> t "publish"
    build root `refusedWith` "net specification root at <root> connection references missing place worker.missing"

  -- test_nested_stamps_flatten_and_stamp_cycles_fail_explicitly
  it "flattens nested stamps" $ do
    inner <- authored (named "inner") (void (p "pending" ~> t "process" ~> p "done"))
    outer <- authored (named "outer") (scope "child" (stamp inner))
    b <- built (named "root") (scope "parent" (stamp outer))
    transitionPaths b `shouldSatisfy` Set.member "parent.child.process"
    -- The cycle half is unrepresentable: a specification embeds its stamped
    -- children by value, so no finite specification contains itself.

  -- test_copy_snapshots_a_composed_specification_without_retaining_source_links
  it "flattens a composed specification into an independent one" $ do
    child <- authored (named "child") (void (p "pending" ~> t "process" ~> p "done"))
    root <- authored (named "root") (scope "worker" (stamp child))
    copy <- either (fail . show) pure (flatten root)
    specName copy `shouldBe` Just "root"
    b <- either (fail . show) pure (build copy)
    rootBuilt <- either (fail . show) pure (build root)
    placePaths b `shouldBe` placePaths rootBuilt
    placePaths b `shouldSatisfy` (not . Set.member "worker.audit")
    length (connections copy) `shouldBe` 2

  -- test_stamped_specification_cannot_contribute_root_completion
  it "refuses a stamped child that declares root completion" $ do
    child <- authored (withCompletion (CompletionSymbol "complete") (named "child")) (void (p "pending" ~> t "process"))
    root <- authored (named "root") (scope "worker" (stamp child))
    build root `refusedWith` "stamped net specification child at worker cannot declare root completion"

  -- spec/net-document-v1-inspection.json is built upstream with the DSL
  -- (tests/petrus/engine/test_observation.py); the Haskell DSL rebuilds it
  -- byte for byte.
  it "rebuilds the observation inspection fixture byte for byte" $ do
    lens <- authored (named "lens") $ do
      review <-
        t "review"
          >>= configure
            [ handler (petriHandler "<lambda>" emptyHandler)
            , guards ["ready", celGuard (unsafeCel "true")]
            , timers [Delay (IntNumber 3), Until (IntNumber 11)]
            ]
      void $ (p "pending" >>= color "Work") ~> review ~> (p "done" >>= color "Done")
      void $ (p "context" >>= color "Context") ~> readArc {arcFilter = Just (FilterCel (unsafeCel "true"))} ~> review
      void $ (p "blocked" >>= color "Block") ~> inhibitArc {arcFilter = Just (FilterSymbol "same_key")} ~> review
    b <- built (withCompletion (CompletionCel (unsafeCel "size(review.correctness.done) > 0")) (named "canonical-design")) $ do
      scope "review" (scope "correctness" (stamp lens))
      void $ t "ingest" ~> scope "review" (scope "correctness" (p "pending"))
      void $ scope "review" (scope "correctness" (t "review" ~> p "done"))
    produced <- either (fail . show) pure (projectNetDocument b.net Nothing Nothing >>= serializeNetDocument)
    fixture <- locate "../../upstream/petrus/spec/net-document-v1-inspection.json" >>= BS.readFile
    produced `shouldBe` fixture
  where
    quoted text = "'" <> text <> "'"
    marker _ _ = Right (HandlerResult [(np "marker", [])] [] [])
    tagged :: Text -> Handler
    tagged tag _ _ = Right (handlerTokens [(np tag, [])])
    handlerTag :: BuiltNet -> Maybe Text
    handlerTag b = case Map.elems b.handlers of
      [PureHandler h] -> case h (Binding (np "process") [] [] []) [] of
        Right result -> Schema.netPathText . fst <$> listToMaybe result.tokens
        Left _ -> Nothing
      _ -> Nothing

expectRight :: Show e => Either e a -> IO a
expectRight = either (fail . show) pure
