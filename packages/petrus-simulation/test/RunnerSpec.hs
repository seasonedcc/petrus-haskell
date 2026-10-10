-- | Port of @tests/petrus/engine/test_simulation.py@ (19 tests, 27
-- items). Each example names the upstream test it ports. The upstream
-- tests monkeypatch module constants; these lower the same bounds through
-- 'SimulationBounds'. Where upstream replaces @Engine.create@ or
-- @Engine.advance@ to prove a refusal comes first, these assert the pure
-- 'admit' refuses, which cannot reach an Engine.
module RunnerSpec (spec) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (invocation)
import Petrus.Engine qualified as Engine
import Petrus.Impetus.Binding (BoundHandler (..))
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.Petrinet
import Petrus.Json (Json (..), lookupMember, parseJson, strictLoads)
import Petrus.Motus.Dispatch (Dispatch (..))
import Petrus.Motus.Dispatch.Inline (inlineDispatch, newInlineDispatch)
import Petrus.Simulation
import Petrus.Simulation qualified as Sim
import Petrus.TestSupport.Repo (repoRoot)
import Support
import System.Directory (createDirectoryIfMissing, listDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Hspec

-- | @strict_json(payload)@
strictJson :: HasCallStack => BS.ByteString -> Json
strictJson payload = either (error . ("not strict JSON: " <>)) id (parseJson strictLoads payload)

run :: HasCallStack => BuiltNet -> Marking -> Int -> IO Json
run built marking maxActions = simulate built marking maxActions >>= either (fail . show) (pure . strictJson)

runWith :: SimulationBounds -> BuiltNet -> Marking -> Int -> IO (Either SimulationError BS.ByteString)
runWith = simulateWith

-- | @pytest.raises(SimulationProfileError, match=…)@ (fragments in order).
shouldRefuse :: HasCallStack => Either SimulationError x -> [Text] -> Expectation
shouldRefuse outcome fragments = case outcome of
  Left (ProfileError message) -> unless (matches message fragments) $ expectationFailure ("unexpected message: " <> T.unpack message)
  Left other -> expectationFailure ("not a profile error: " <> show other)
  Right _ -> expectationFailure "accepted"
  where
    matches text = \case
      [] -> True
      f : fs -> case T.breakOn f text of
        (_, rest) | T.null rest -> False
        (_, rest) -> matches (T.drop (T.length f) rest) fs

entries :: Json -> [Json]
entries document = case lookupMember "lineage" document >>= lookupMember "entries" of
  Just (Array items) -> items
  _ -> []

summary :: Json -> Json
summary document = case entries document of
  first : _ -> fromMaybe Null (lookupMember "metadata" first)
  [] -> Null

recordNames :: Json -> [Json]
recordNames document = [fromMaybe Null (lookupMember "metadata" e >>= lookupMember "history_record" >>= lookupMember "record") | e <- entries document]

currentMarking :: Json -> Maybe Json
currentMarking document = do
  Int headIndex <- lookupMember "lineage" document >>= lookupMember "head"
  lookupMember "marking" (entries document !! fromInteger headIndex)

field :: Text -> Json -> Json
field name value = fromMaybe Null (lookupMember name value)

loopNet :: BuiltNet
loopNet = builtOf (netOf (netSpec [place a] [transition t] [arc a t, arc t a]))

onePlace :: BuiltNet
onePlace = builtOf (netOf (netSpec [place a] [] []))

emptyNet :: BuiltNet
emptyNet = builtOf (netOf (netSpec [] [] []))

admits :: BuiltNet -> Marking -> Either SimulationError ()
admits built marking = () <$ admit defaultBounds built marking 1

-- | @Transition(path, guards=…)@
guarded :: NetPath -> [GuardDeclaration] -> Transition
guarded path declarations = Transition path Nothing declarations []

spec :: Spec
spec = describe "test_simulation.py" $ do
  it "test_owner_fixture_is_exact_strict_and_complete" $ do
    let (built, marking) = buildScenario
    payload <- simulate built marking 32 >>= either (fail . show) pure
    fixture <- specPath "spec/net-document-v1-simulation.json" >>= BS.readFile
    payload `shouldBe` fixture
    let result = strictJson payload
    field "format" result `shouldBe` String "petrus-net-document"
    field "version" result `shouldBe` Int 1
    map (field "id") (entries result) `shouldBe` map Int [0 .. toInteger (length (entries result)) - 1]
    all ((== String "simulated") . field "provenance") (entries result) `shouldBe` True
    length (filter (== String "TimerMatured") (recordNames result)) `shouldBe` 1
    field "status" (summary result) `shouldBe` String "completed"
    (lookupMember "outcome" (summary result) >>= lookupMember "actions_applied") `shouldBe` Just (Int 2)

  it "test_rest_and_exact_action_limit_have_no_extra_probe" $ do
    idle <- run onePlace emptyMarking 1
    field "outcome" (summary idle) `shouldBe` Object [("actions_applied", Int 0), ("reason", String "rest")]
    limited <- run loopNet (markingFromList [(a, [black])]) 3
    field "outcome" (summary limited) `shouldBe` Object [("actions_applied", Int 3), ("reason", String "action_limit")]
    length (filter (== String "FiringCompleted") (recordNames limited)) `shouldBe` 3

  describe "test_max_actions_is_a_positive_bounded_non_boolean_integer" $
    forM_ [Bool True, Bool False, Int 0, Int (-1), Int 257, Float 1.5, String "1"] $ \value -> it (show value) $ do
      let expected = "max_actions must be an integer from 1 through 256, got " <> pythonRepr value
      maxActionsFromJson defaultBounds value `shouldBe` Left (ProfileError expected)
      case value of
        Int n -> simulate emptyNet emptyMarking (fromInteger n) >>= (`shouldBe` Left (ProfileError expected))
        _ -> pure ()

  describe "test_named_and_anonymous_handlers_are_refused_before_engine_creation" $
    forM_ [("named", HandlerSymbol "named"), ("ANONYMOUS", HandlerAnonymous anonymous)] $ \(label, declaration) -> it label $ do
      let built = builtOf (netOf (netSpec [] [(transition t) {handler = Just declaration}] []))
      admits built emptyMarking `shouldRefuse` ["handler", "absent"]
      simulate built emptyMarking 1 >>= (`shouldRefuse` ["handler", "absent"])

  it "test_implementation_maps_and_non_json_tokens_are_refused" $ do
    let net = netOf (netSpec [place a] [(transition t) {handler = Just (HandlerSymbol "named")}] [])
        uri = fromMaybe (error "no handler uri") (handlerUri net t)
    simulate BuiltNet {net, handlers = Map.singleton uri (PureHandler (\_ _ -> Left "unused")), guards = Map.empty} emptyMarking 1
      >>= (`shouldRefuse` ["handler implementations"])
    simulate onePlace (markingFromList [(a, [Token (Just "X") (Float (0 / 0))])]) 1
      >>= (`shouldRefuse` ["strict JSON-faithful"])

  it "test_graph_initial_token_and_payload_bounds" $ do
    let tooManyPlaces = builtOf (netOf (netSpec [place (either (error . T.unpack) id (netPath ("p" <> T.pack (show n)))) | n <- [0 :: Int .. 128]] [] []))
    simulate tooManyPlaces emptyMarking 1 >>= (`shouldRefuse` ["places limit"])
    simulate onePlace (markingFromList [(a, replicate 513 black)]) 1 >>= (`shouldRefuse` ["initial token limit"])

  it "test_transition_arc_cel_definition_and_result_bounds" $ do
    runWith defaultBounds {Sim.transitions = 0} (builtOf (netOf (netSpec [] [transition t] []))) emptyMarking 1
      >>= (`shouldRefuse` ["transitions limit"])
    runWith defaultBounds {Sim.arcs = 0} (builtOf (netOf (netSpec [place a] [transition t] [arc a t]))) emptyMarking 1
      >>= (`shouldRefuse` ["arcs limit"])
    runWith
      defaultBounds {Sim.celBytes = 1}
      (builtOf (netOf (netSpec [place a] [guarded t [GuardCel (unsafeCel "xx")]] [arc a t])))
      emptyMarking
      1
      >>= (`shouldRefuse` ["CEL expression limit"])
    runWith defaultBounds {Sim.definitionBytes = 1} emptyNet emptyMarking 1 >>= (`shouldRefuse` ["definition limit"])
    runWith defaultBounds {Sim.resultBytes = 1} emptyNet emptyMarking 1 >>= (`shouldRefuse` ["serialized result limit"])

  it "test_retained_history_and_candidate_work_limits_precede_next_advance" $ do
    let marking = markingFromList [(a, [black])]
    runWith defaultBounds {Sim.retainedTokens = 0} loopNet marking 1 >>= (`shouldRefuse` ["retained token limit"])
    runWith defaultBounds {Sim.historyRecords = 0} loopNet marking 1 >>= (`shouldRefuse` ["History record limit"])
    runWith defaultBounds {Sim.retainedPayloadBytes = 1} loopNet marking 1 >>= (`shouldRefuse` ["retained token payload limit"])
    runWith defaultBounds {Sim.historyPayloadBytes = 1} loopNet marking 1 >>= (`shouldRefuse` ["History payload limit"])
    -- upstream replaces Engine.advance and asserts it is never called: the
    -- refusal is admission's, before any Engine exists.
    (() <$ admit defaultBounds {Sim.candidateOffers = 0} loopNet marking 1) `shouldRefuse` ["reachable input-scan limit"]
    runWith defaultBounds {Sim.candidateOffers = 0} loopNet marking 1 >>= (`shouldRefuse` ["reachable input-scan limit"])

  it "test_legal_graph_cross_transition_scan_sum_is_refused_before_engine_create" $ do
    let paths = [either (error . T.unpack) id (netPath ("t" <> T.pack (show n))) | n <- [0 :: Int .. 19]]
        built = builtOf (netOf (netSpec [place a] (map transition paths) [arc a p' | p' <- paths]))
        marking = markingFromList [(a, replicate 512 black)]
    admits built marking `shouldRefuse` ["reachable input-scan limit", "bound 10240"]
    simulate built marking 1 >>= (`shouldRefuse` ["reachable input-scan limit", "bound 10240"])

  it "test_completion_reports_completed_without_halting_an_enabled_action" $ do
    let built =
          builtOf . netOf $
            (netSpec [place a, place "b", place "done"] [transition t] [arc "b" t, arc t "done"])
              { completion = Just (CompletionCel (unsafeCel "size(a) > 0"))
              }
    result <- run built (markingFromList [(a, [black]), ("b", [black])]) 2
    field "outcome" (summary result) `shouldBe` Object [("actions_applied", Int 1), ("reason", String "rest")]
    field "status" (summary result) `shouldBe` String "completed"
    currentMarking result
      `shouldBe` Just
        ( Array
            [ Object [("place", String "a"), ("tokens", Array [Object [("color", Null), ("data", Null)]])]
            , Object [("place", String "done"), ("tokens", Array [Object [("color", Null), ("data", Null)]])]
            ]
        )

  it "test_simulation_does_not_change_a_separate_live_engine" $ do
    let net = netOf (netSpec [place a] [] [])
    store <- inMemoryHistoryStore
    port <- inlineDispatch <$> newInlineDispatch Map.empty
    live <- Engine.create net "live" store port Engine.defaultEngineOptions {Engine.marking = markingFromList [(a, [black])]}
    beforeMarking <- Engine.marking live
    beforeRecords <- Engine.records live
    _ <- simulate (builtOf net) emptyMarking 1
    Engine.marking live `shouldReturn` beforeMarking
    Engine.records live `shouldReturn` beforeRecords
    Engine.close live

  it "test_admission_is_field_complete_and_precedes_engine_create" $ do
    let namedGuardNet = netOf (netSpec [place a] [guarded t [GuardSymbol "named"]] [arc a t])
        cases =
          [ (builtOf (netOf (netSpec [place a] [(transition t) {timers = [Delay (IntNumber (-1))]}] [arc a t])), emptyMarking, "non-negative")
          , (onePlace, markingFromList [("foreign", [black])], "foreign place")
          , -- "exactly Token": a queue item is always a Token in Haskell (enforced by types)
            (builtOf (netOf (netSpec [coloredPlace a "X"] [] [])), markingFromList [(a, [Token (Just "Y") Null])], "does not match")
          , (builtOf namedGuardNet, emptyMarking, "inline Cel")
          , (builtOf (netOf (netSpec [place a] [guarded t [GuardAnonymous anonymous]] [arc a t])), emptyMarking, "inline Cel")
          , (builtOf (netOf (netSpec [place a] [transition t] [(arc a t) {filter = Just (FilterSymbol "named")}])), emptyMarking, "filter")
          , -- an ANONYMOUS filter or completion has no Haskell representation (enforced by types)
            (builtOf (netOf (netSpec [] [] []) {completion = Just (CompletionSymbol "named")}), emptyMarking, "completion")
          , ( BuiltNet {net = namedGuardNet, handlers = Map.empty, guards = Map.fromList [(uri, \_ -> Right True) | uri <- take 1 (guardUris namedGuardNet t)]}
            , emptyMarking
            , "guard implementations"
            )
          , (builtOf (netOf (netSpec [] [(transition t) {handler = Just (HandlerSymbol "named")}] [])), emptyMarking, "handler")
          , (onePlace, markingFromList [(a, [Token (Just "X") (Float (1 / 0))])], "strict JSON")
          ]
    forM_ cases $ \(built, marking, message) -> do
      admits built marking `shouldRefuse` [message]
      simulate built marking 1 >>= (`shouldRefuse` [message])

  it "test_malformed_weight_and_multiple_selecting_inputs_are_explicitly_refused" $ do
    -- weight True is unrepresentable (weight :: Int); any other weight is the same refusal
    simulate (builtOf (netOf (netSpec [place a] [transition t] [(arc a t) {weight = 2}]))) emptyMarking 1
      >>= (`shouldRefuse` ["exact non-boolean integer 1"])
    simulate (builtOf (netOf (netSpec [place a, place "b"] [transition t] [arc a t, arc "b" t]))) emptyMarking 1
      >>= (`shouldRefuse` ["at most one selecting"])

  it "test_read_selection_and_output_fanout_are_refused_before_engine_create" $ do
    -- Upstream forces a READ selecting arc past Net validation with
    -- object.__setattr__. Net is abstract here, so the only reachable such
    -- net carries a handler, which admission refuses first; mkNet itself
    -- refuses the handlerless read-only transition.
    either (const True) (const False) (mkNet (netSpec [place a] [transition t] [(arc a t) {mode = Read}])) `shouldBe` True
    let fanout = builtOf (netOf (netSpec [place a, place "b", place "c"] [transition t] [arc a t, arc t "b", arc t "c"]))
        big = markingFromList [(a, [Token (Just "X") (String (T.replicate 999000 "x"))])]
    admits fanout big `shouldRefuse` ["at most one output arc"]
    simulate fanout big 1 >>= (`shouldRefuse` ["at most one output arc"])

  it "test_consume_plus_many_inhibits_is_rejected_by_reachable_scan_bound" $ do
    let blocker = "blocker"
        built = builtOf (netOf (netSpec [place a, place blocker] [transition t] (arc a t : replicate 20 ((arc blocker t) {mode = Inhibit}))))
        marking = markingFromList [(a, [black]), (blocker, replicate 511 black)]
    admits built marking `shouldRefuse` ["reachable input-scan limit"]

  it "test_mutating_input_after_simulate_cannot_change_returned_bytes" $ do
    -- Haskell values are immutable: the input cannot be mutated afterwards.
    let data' = Object [("nested", Array [Int 1])]
    payload <- run onePlace (markingFromList [(a, [Token (Just "X") data'])]) 1
    (lookupMember "scenario" (summary payload) >>= lookupMember "initial_marking")
      `shouldBe` Just (Array [Object [("place", String "a"), ("tokens", Array [Object [("color", String "X"), ("data", data')]])]])

  it "test_dispatch_is_structurally_impossible" $ do
    outcome <- try (forbiddenDispatch.dispatch 0 (invocation "x" Null))
    case outcome of
      Left (SimulationProfileException message) -> T.unpack message `shouldContain` "forbids Dispatch"
      Right () -> expectationFailure "dispatch was accepted"
    (null <$> forbiddenDispatch.collect) `shouldReturn` True
    simulate onePlace (markingFromList [(a, [Token (Just "X") (String (T.replicate 1000001 "x"))])]) 1
      >>= (`shouldRefuse` ["payload limit"])

  it "test_failed_atomic_replace_preserves_the_previous_destination" $
    withTemporaryDirectory "replace" $ \directory -> do
      let destination = directory </> "result.petrus-simulation.json"
      BS.writeFile destination "previous"
      outcome <- try (export defaultExportOps {replace = \_ _ -> throwIO (userError "replace failed")} destination 32)
      either (\e -> show (e :: SomeException) `shouldContain` "replace failed") (\() -> expectationFailure "exported") outcome
      BS.readFile destination `shouldReturn` "previous"
      listDirectory directory `shouldReturn` ["result.petrus-simulation.json"]

  describe "test_failed_temp_publication_preserves_destination_and_cleans_temp" $
    forM_
      [ ("write", defaultExportOps {write = \_ _ -> throwIO (userError "write failed")})
      , ("fsync", defaultExportOps {fsync = \_ -> throwIO (userError "fsync failed")})
      ]
      $ \(failure, ops) -> it failure $
        withTemporaryDirectory failure $ \directory -> do
          let destination = directory </> "result.petrus-simulation.json"
          BS.writeFile destination "previous"
          outcome <- try (export ops destination 32)
          either (\e -> show (e :: SomeException) `shouldContain` (failure <> " failed")) (\() -> expectationFailure "exported") outcome
          BS.readFile destination `shouldReturn` "previous"
          sort <$> listDirectory directory `shouldReturn` ["result.petrus-simulation.json"]
  where
    withTemporaryDirectory label action = do
      -- bench-results/tmp is ignored by version control and absent from a
      -- fresh checkout, so build the path from the repository root instead
      -- of requiring it to exist (createDirectoryIfMissing makes it).
      root <- repoRoot
      let directory = root </> "bench-results" </> "tmp" </> ("petrus-simulation-test-" <> label)
      createDirectoryIfMissing True directory
      result <- action directory
      removeDirectoryRecursive directory
      pure result
