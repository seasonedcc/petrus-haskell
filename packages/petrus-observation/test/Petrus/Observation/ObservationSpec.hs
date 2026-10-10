-- | Port of @tests/petrus/engine/test_observation.py@: every test whose
-- assertion is about the projections themselves. The reference drives an
-- Engine; these drive the Instance doors the Engine would call (see
-- "Petrus.Observation.Support") and capture with 'capture', which is the
-- Engine's read-door seam. Tests about the Engine's lock, re-entry, and
-- poisoning are listed in PARITY.md as deferred to the Engine.
module Petrus.Observation.ObservationSpec (spec) where

import Data.ByteString qualified as BS
import Data.IntMap.Strict qualified as IntMap
import Data.List (nub)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity (ActivityFailureFields (..), activityFailure)
import Petrus.Impetus.History (Record)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Json (Json (..), dumps, dumpsText, indented)
import Petrus.Observation
import Petrus.Observation.Support
import Test.Hspec

door :: HasCallStack => IO (Either InstanceError x) -> IO x
door action = action >>= expectRight . either (Left . renderInstanceError) Right

observe :: HasCallStack => Instance -> IO Json
observe inst = capture inst >>= expectRight . snapshot

page :: HasCallStack => Instance -> Integer -> Integer -> IO Json
page inst afterCursor limit = do
  o <- capture inst
  expectRight (historyPage o.observed.identity o.records afterCursor limit)

document :: HasCallStack => Instance -> IO Json
document inst = capture inst >>= expectRight . netDocument

recordsOf :: Instance -> IO [Record]
recordsOf inst = Store.records (instanceHistory inst)

refusal :: HasCallStack => Either ObservationError Json -> IO Text
refusal = \case
  Left (ObservationError message) -> pure message
  Right _ -> expectationFailure "expected a refusal" >> error "unreachable"

shouldRefuseMatching :: HasCallStack => Either ObservationError Json -> [Text] -> Expectation
shouldRefuseMatching result fragments = do
  message <- refusal result
  let ordered = go message fragments
      go _ [] = True
      go text (f : fs) = case T.breakOn f text of
        (_, rest) | T.null rest -> False
        (_, rest) -> go (T.drop (T.length f) rest) fs
  if ordered then pure () else expectationFailure ("refusal " <> show message <> " does not match " <> show fragments)

int :: Integer -> Json
int = Int

-- The definition-shape net of the first test.
shapeNet :: Net
shapeNet =
  netOf
    NetSpec
      { places = [place "z-place", coloredPlace a "Input"]
      , transitions =
          [ Transition {path = "z", handler = Just (HandlerAnonymous anonymous), guards = [], timers = []}
          , Transition
              { path = "t"
              , handler = Just (HandlerSymbol "named_handler")
              , guards = [GuardSymbol "named_guard", GuardAnonymous anonymous, GuardCel (unsafeCel "true")]
              , timers = [Until (IntNumber 11), Delay (IntNumber 3)]
              }
          ]
      , arcs =
          [ Arc {source = a, target = "t", mode = Consume, weight = 1, color = Just "Input", filter = Just (FilterSymbol "named_filter")}
          , arc "t" "z-place"
          , arc "t" "z-place"
          , Arc {source = "z-place", target = "t", mode = Read, weight = 1, color = Nothing, filter = Just (FilterCel (unsafeCel "true"))}
          ]
      , completion = Just (CompletionSymbol "done")
      , name = Just "shape"
      }

-- The reference builds this net with the DSL: a @lens@ child stamped at
-- @review.correctness@ of a @canonical-design@ root. Places and transitions
-- are listed in first-touch order and arcs in connection order, which is
-- what the DSL lowers to; arc colours are resolved from the places.
inspectionNet :: Net
inspectionNet =
  netOf
    NetSpec
      { places =
          [ coloredPlace "review.correctness.pending" "Work"
          , coloredPlace "review.correctness.done" "Done"
          , coloredPlace "review.correctness.context" "Context"
          , coloredPlace "review.correctness.blocked" "Block"
          ]
      , transitions =
          [ Transition
              { path = review
              , handler = Just (HandlerAnonymous anonymous)
              , guards = [GuardSymbol "ready", GuardCel (unsafeCel "true")]
              , timers = [Delay (IntNumber 3), Until (IntNumber 11)]
              }
          , transition "ingest"
          ]
      , arcs =
          [ arc "review.correctness.pending" review
          , arc review "review.correctness.done"
          , Arc {source = "review.correctness.context", target = review, mode = Read, weight = 1, color = Nothing, filter = Just (FilterCel (unsafeCel "true"))}
          , Arc {source = "review.correctness.blocked", target = review, mode = Inhibit, weight = 1, color = Nothing, filter = Just (FilterSymbol "same_key")}
          , arc "ingest" "review.correctness.pending"
          , arc review "review.correctness.done"
          ]
      , completion = Just (CompletionCel (unsafeCel "size(review.correctness.done) > 0"))
      , name = Just "canonical-design"
      }
  where
    review = "review.correctness.review"

-- | The fixture's own bytes are the reference writer's spelling of the
-- projected value (two-space indentation, insertion order, one newline).
shouldSpellFixture :: HasCallStack => Json -> FilePath -> Expectation
shouldSpellFixture value path = do
  expected <- BS.readFile path
  fmap (<> "\n") (dumps indented value) `shouldBe` Right expected

spec :: Spec
spec = describe "observation (test_observation.py)" $ do
  -- test_exact_definition_shape_order_declarations_uris_and_duplicate_arcs
  it "projects the exact definition shape, order, declarations, URIs, and duplicate arcs" $ do
    projected <- expectRight (definition shapeNet)
    [members ["path"] p | p <- items (member "places" projected)] `shouldBe` [String "a", String "z-place"]
    [members ["path"] t | t <- items (member "transitions" projected)] `shouldBe` [String "t", String "z"]
    let t = firstOf (items (member "transitions" projected))
    member "handler" t
      `shouldBeExactly` Object [("kind", String "symbol"), ("name", String "named_handler"), ("uri", String "transition:/t#handler")]
    member "guards" t
      `shouldBeExactly` Array
        [ Object [("kind", String "symbol"), ("name", String "named_guard"), ("uri", String "transition:/t#guard:named_guard")]
        , Object [("kind", String "anonymous"), ("uri", String "transition:/t#guard:$1")]
        , Object [("kind", String "cel"), ("expression", String "true"), ("uri", String "transition:/t#guard:$2")]
        ]
    member "timers" t
      `shouldBeExactly` Array
        [Object [("kind", String "until"), ("instant", int 11)], Object [("kind", String "delay"), ("duration", int 3)]]
    let arcs' = items (member "arcs" projected)
    map (member "position") arcs' `shouldBe` map int [0, 1, 2, 3]
    (arcs' !! 1) `shouldNotBe` (arcs' !! 2)
    member "color" (firstOf arcs') `shouldBe` String "Input"
    member "filter" (firstOf arcs') `shouldBeExactly` Object [("kind", String "symbol"), ("name", String "named_filter")]
    member "filter" (arcs' !! 3) `shouldBeExactly` Object [("kind", String "cel"), ("expression", String "true")]
    nub [members ["filter", "kind"] x | x <- arcs', member "filter" x /= Null] `shouldBe` [String "symbol", String "cel"]
    member "handler" (items (member "transitions" projected) !! 1)
      `shouldBeExactly` Object [("kind", String "anonymous"), ("uri", String "transition:/z#handler")]
    sourceOnly <- expectRight (definition (netOf (netSpec [place a] [transition source] [arc source a])))
    members ["handler"] (firstOf (items (member "transitions" sourceOnly))) `shouldBe` Null
    member "completion" projected `shouldBeExactly` Object [("kind", String "symbol"), ("name", String "done")]
    encoded <- expectRight (dumpsText indented projected)
    T.isInfixOf "display_name" encoded `shouldBe` False
    T.isInfixOf "implementation" encoded `shouldBe` False

  -- test_canonical_net_inspection_fixture_is_exact_pre_instance_dsl_build_without_implementations
  it "projects the exact inspection fixture from a definition-only net" $ do
    produced <- expectRight (netInspection inspectionNet)
    expected <- readJsonFile (specFile "net-document-v1-inspection.json")
    produced `shouldBeExactly` expected
    produced `shouldSpellFixture` specFile "net-document-v1-inspection.json"
    member "format" produced `shouldBe` String "petrus-net-document"
    member "version" produced `shouldBeExactly` int 1
    body <- expectRight (definition inspectionNet)
    member "definition" produced
      `shouldBeExactly` Object [("format", String "petrus-net-definition"), ("version", int 3), ("definition", body)]
    let arcs' = items (member "arcs" body)
    map (member "position") arcs' `shouldBe` map int [0 .. fromIntegral (length arcs') - 1]
    [ member "position" x
      | x <- arcs'
      , member "source" x == String "review.correctness.review"
      , member "target" x == String "review.correctness.done"
      ]
      `shouldBe` [int 1, int 5]
    encoded <- expectRight (dumpsText indented produced)
    mapM_ (\needle -> T.isInfixOf needle encoded `shouldBe` False) ["canonical-instance", "implementation", "display_name", "<lambda>"]

  -- test_canonical_fixture_is_exact_producer_output_and_has_typed_fifo_activity_pending_state
  it "produces the exact snapshot fixture with a typed FIFO activity-pending state" $ do
    produced <- canonicalInstance >>= observe
    expected <- readJsonFile (specFile "observation/engine-snapshot-v1.json")
    produced `shouldBeExactly` expected
    produced `shouldSpellFixture` specFile "observation/engine-snapshot-v1.json"
    members ["current", "marking"] produced
      `shouldBeExactly` Array [Object [("place", String "a"), ("tokens", Array [Object [("color", String "Input"), ("data", Object [("ordinal", int 2)])]])]]
    let occurrence = firstOf (items (members ["current", "in_flight"] produced))
    member "phase" occurrence `shouldBe` String "activity_pending"
    members ["invocation", "policy"] occurrence
      `shouldBeExactly` Object
        [ ("attempts", int 1)
        , ("heartbeat_timeout", int 30)
        , ("initial_interval", int 0)
        , ("coefficient", int 2)
        , ("max_interval", int 60)
        , ("jitter", int 0)
        , ("start_to_close", Null)
        , ("schedule_to_close", Null)
        ]
    members ["current", "armed"] produced `shouldBeExactly` Array [Object [("source", String "source"), ("key", String "default")]]
    members ["current", "watermark"] produced `shouldBeExactly` int 7

  -- test_canonical_history_fixture_is_exact_complete_page_with_current_typed_occurrences
  it "produces the exact complete History page fixture" $ do
    produced <- canonicalInstance >>= \inst -> page inst 0 100
    expected <- readJsonFile (specFile "observation/engine-history-page-v1.json")
    produced `shouldBeExactly` expected
    produced `shouldSpellFixture` specFile "observation/engine-history-page-v1.json"
    let entries = items (member "records" produced)
    map (member "position") entries `shouldBe` [int i | i <- [0 .. 6]]
    member "next" produced `shouldBe` member "frontier" produced
    all (\x -> members ["record", "schema"] x == int 5) entries `shouldBe` True
    let typed = [members ["color"] t | x <- entries, Object r <- [member "record" x], Just ts <- [lookup "tokens" r], t <- items ts]
    (String "Input" `elem` typed) `shouldBe` True
    let occurrences = [o | x <- entries, Object r <- [member "record" x], Just o <- [lookup "occurrence" r]]
    null occurrences `shouldBe` False
    nub [o | o <- occurrences, o /= Null] `shouldBe` [int 1]

  -- test_protocol_v1_history_transports_one_field_complete_current_schema
  it "transports the complete current schema, scope fields included" $ do
    inst <- canonicalInstance
    scope <- door (openScope inst "draft" Nothing)
    door (acceptDelivery inst source [Token (Just "External") (int 1)] "draft-1" (Just (ScopeGeneration scope)) Nothing) >>= \case
      DeliveryAccepted accepted -> door (completeDelivery inst accepted Nothing) >> pure ()
      other -> expectationFailure ("expected an accepted delivery, got " <> show other)
    _ <- door (closeScope inst scope Nothing)
    produced <- page inst 0 100
    member "protocol" produced `shouldBeExactly` int 1
    let lifecycle = map (member "record") (items (member "records" produced))
    nub (map (member "schema") lifecycle) `shouldBe` [int 5]
    [n | r <- lifecycle, String n <- [member "record" r], "Scope" `T.isPrefixOf` n] `shouldBe` ["ScopeOpened", "ScopeClosed"]
    let scoped = [s | Object r <- lifecycle, Just s <- [lookup "scope" r], s /= Null]
    null scoped `shouldBe` False
    all (\s -> member "name" s == String "draft") scoped `shouldBe` True
    all (\case Object r -> lookup "scope" r /= Nothing; _ -> False) [r | r <- lifecycle, member "record" r == String "TokensInitialized"]
      `shouldBe` True

  -- test_canonical_observed_net_document_fixture_has_one_complete_marking_per_history_record
  it "produces the exact observed Net document fixture, one complete marking per record" $ do
    inst <- canonicalInstance
    produced <- document inst
    expected <- readJsonFile (specFile "net-document-v1-observation.json")
    produced `shouldBeExactly` expected
    produced `shouldSpellFixture` specFile "net-document-v1-observation.json"
    member "format" produced `shouldBe` String "petrus-net-document"
    member "version" produced `shouldBeExactly` int 1
    let lineage = member "lineage" produced
        entries = items (member "entries" lineage)
    history <- recordsOf inst
    member "head" lineage `shouldBe` int (fromIntegral (length entries - 1))
    map (member "id") entries `shouldBe` [int i | i <- [0 .. fromIntegral (length history) - 1]]
    all (\e -> member "provenance" e == String "observed") entries `shouldBe` True
    full <- page inst 0 100
    map (members ["metadata", "history_record"]) entries `shouldBe` map (member "record") (items (member "records" full))
    current <- observe inst
    member "marking" (last entries) `shouldBeExactly` members ["current", "marking"] current
    case members ["metadata", "observation"] (last entries) of
      Object ms -> lookup "marking" ms `shouldBe` Nothing
      other -> expectationFailure ("observation is not an object: " <> show other)

  -- test_capture_pages_freeze_snapshot_frontier_while_history_continues_to_append
  it "pages a captured frontier while History keeps appending" $ do
    inst <- canonicalInstance
    captured <- observe inst
    let frontier = case member "frontier" captured of Int n -> n; _ -> error "frontier"
        loop cursor observedFrontier positions
          | cursor >= frontier = pure (observedFrontier, positions)
          | otherwise = do
              let limit = min 2 (frontier - cursor)
              current <- page inst cursor limit
              let pageFrontier = case member "frontier" current of Int n -> n; _ -> error "frontier"
                  next = case member "next" current of Int n -> n; _ -> error "next"
              member "after" current `shouldBe` int cursor
              member "protocol" current `shouldBe` member "protocol" captured
              member "instance" current `shouldBe` member "instance" captured
              (pageFrontier >= observedFrontier) `shouldBe` True
              next `shouldBe` min (cursor + limit) pageFrontier
              (next <= frontier) `shouldBe` True
              let got = map (member "position") (items (member "records" current))
              got `shouldBe` map int [cursor .. next - 1]
              if next == 2 then door (seal inst source Nothing) else pure ()
              loop next pageFrontier (positions ++ got)
    (finalFrontier, positions) <- loop 0 frontier []
    (finalFrontier > frontier) `shouldBe` True
    positions `shouldBe` map int [0 .. frontier - 1]

  -- test_snapshot_reports_pure_and_projection_pending_phases_and_detaches_frozen_result
  it "reports pure and projection-pending phases with the frozen result" $ do
    pure' <-
      create
        (netOf (netSpec [place a, place b] [transition work] [arc a work, arc work b]))
        defaultInstanceConfig
          { initialMarking = markingFromList [(a, [Token (Just "Input") (Object [("nested", Array [int 1])])])]
          , suppliedIdentity = Just "pure-pending"
          }
    candidates pure' >>= \case
      binding : _ -> door (begin pure' binding Nothing) >> pure ()
      [] -> expectationFailure "expected a candidate"
    observedPure <- observe pure'
    member "phase" (firstOf (items (members ["current", "in_flight"] observedPure))) `shouldBe` String "pure_pending"

    projection <- canonicalInstance
    occurrence <- firstOf <$> inFlight projection
    let result = Object [("nested", Array [Object [("value", int 1)]])]
    _ <- door (recordActivityCompletion projection occurrence result (Just (IntNumber 8)))
    observedProjection <- observe projection
    let pendingOccurrence = firstOf (items (members ["current", "in_flight"] observedProjection))
    member "phase" pendingOccurrence `shouldBe` String "projection_pending"
    member "result" pendingOccurrence `shouldBeExactly` result
    -- The reference then mutates its result dict; a Haskell value cannot
    -- change, so the captured snapshot is detached by construction.

  -- test_snapshot_detaches_a_classified_failure_while_its_firing_terminal_is_pending
  it "reports a classified failure while its firing terminal is pending" $ do
    inst <- canonicalInstance
    occurrence <- firstOf <$> inFlight inst
    failure <-
      expectRight
        ( activityFailure
            ActivityFailureFields
              { failureError = "invalid"
              , failureKind = "InvalidRequest"
              , failureDetails = Object [("field", String "name")]
              , failureRetryable = False
              , failureRetryAfter = Just (IntNumber 9)
              }
        )
    _ <- door (recordActivityFailure inst occurrence failure (Just (IntNumber 8)))
    pendingOccurrence <- firstOf . items . members ["current", "in_flight"] <$> observe inst
    member "phase" pendingOccurrence `shouldBe` String "projection_pending"
    member "result" pendingOccurrence
      `shouldBeExactly` Object
        [ ("error", String "invalid")
        , ("kind", String "InvalidRequest")
        , ("details", Object [("field", String "name")])
        , ("retryable", Bool False)
        , ("retry_after", int 9)
        ]

  -- test_snapshot_detaches_nested_tokens_and_activity_values
  it "keeps nested token and Activity values as captured" $ do
    let tokenData = Object [("items", Array [Object [("value", int 1)]])]
    inst <-
      create
        (netOf NetSpec {places = [place a, place b], transitions = [Transition {path = work, handler = Just (HandlerSymbol "bridge"), guards = [], timers = []}], arcs = [arc a work, arc work b], completion = Nothing, name = Nothing})
        canonicalConfig {initialMarking = markingFromList [(a, [Token (Just "Input") tokenData])], suppliedIdentity = Just "detached", constructionInstant = IntNumber 0}
    advance inst
    occurrence <- firstOf . items . members ["current", "in_flight"] <$> observe inst
    members ["binding", "consumed"] occurrence `seq` pure ()
    member "data" (firstOf (items (member "tokens" (firstOf (items (members ["binding", "consumed"] occurrence))))))
      `shouldBeExactly` tokenData
    members ["invocation", "input"] occurrence `shouldBeExactly` Object [("nested", Array [tokenData])]

  describe "test_protocol_strictly_refuses_non_integer_timer_values" $ do
    let timed timer = netOf (netSpec [place a] [Transition {path = work, handler = Nothing, guards = [], timers = [timer]}] [arc a work])
    -- test_protocol_strictly_refuses_non_integer_timer_values[timer1-Delay duration]
    it "refuses a float Delay duration" $
      definition (timed (Delay (FloatNumber 1.5))) `shouldRefuseMatching` ["Delay duration", "integer"]
    -- test_protocol_strictly_refuses_non_integer_timer_values[timer4-Until instant]
    it "refuses a float Until instant" $
      definition (timed (Until (FloatNumber 1.5))) `shouldRefuseMatching` ["Until instant", "integer"]
    -- [timer0], [timer2], [timer3], [timer5]: Delay(True), Delay("1"),
    -- Until(True), Until("1") are enforced by types (a timer holds a Number).

  -- test_definition_strictly_refuses_non_json_output: enforced by types (a
  -- net name is Text).

  -- test_snapshot_emits_integer_next_maturation_and_refuses_boolean_when_reachable
  it "emits an integer next maturation and refuses a non-integer one" $ do
    let timedNet timer = netOf (netSpec [place a] [Transition {path = work, handler = Nothing, guards = [], timers = [timer]}] [arc a work])
        config at' = defaultInstanceConfig {initialMarking = markingFromList [(a, [Token (Just "X") Null])], constructionInstant = at'}
    timed <- create (timedNet (Delay (IntNumber 5))) (config (IntNumber 2))
    observeTimed <- observe timed
    members ["current", "next_maturation"] observeTimed `shouldBeExactly` int 7
    -- Until(True) cannot be built; the reachable non-integer is a float.
    bad <- create (timedNet (Until (FloatNumber 1.5))) (config (IntNumber 0))
    capture bad >>= \o -> snapshot o `shouldRefuseMatching` ["next maturation", "integer"]

  describe "test_history_page_refuses_malformed_cursor_or_limit" $ do
    let refuses afterCursor limit = do
          inst <- canonicalInstance
          o <- capture inst
          let result = historyCursor afterCursor limit >>= \(x, y) -> historyPage o.observed.identity o.records x y
          case result of
            Left _ -> pure ()
            Right _ -> expectationFailure "expected a refusal"
    -- test_history_page_refuses_malformed_cursor_or_limit[-1-1]
    it "refuses after=-1" $ refuses (int (-1)) (int 1)
    -- test_history_page_refuses_malformed_cursor_or_limit[True-1]
    it "refuses after=True" $ refuses (Bool True) (int 1)
    -- test_history_page_refuses_malformed_cursor_or_limit[0.5-1]
    it "refuses after=0.5" $ refuses (Float 0.5) (int 1)
    -- test_history_page_refuses_malformed_cursor_or_limit[0-0]
    it "refuses limit=0" $ refuses (int 0) (int 0)
    -- test_history_page_refuses_malformed_cursor_or_limit[0-True]
    it "refuses limit=True" $ refuses (int 0) (Bool True)
    -- test_history_page_refuses_malformed_cursor_or_limit[0-1.5]
    it "refuses limit=1.5" $ refuses (int 0) (Float 1.5)
    it "refuses the same values through the typed API" $ do
      inst <- canonicalInstance
      o <- capture inst
      _ <- refusal (historyPage o.observed.identity o.records (-1) 1)
      _ <- refusal (historyPage o.observed.identity o.records 0 0)
      pure ()

  -- test_strict_json_refuses_nonfinite_and_unencodable_nested_data_and_bad_current_time
  it "refuses non-finite token data and a non-integer current watermark" $ do
    let badData payload at' =
          create
            (netOf (netSpec [place a] [] []))
            defaultInstanceConfig {initialMarking = markingFromList [(a, [Token (Just "X") payload])], constructionInstant = at'}
    nan <- badData (Object [("bad", Float (0 / 0))]) (IntNumber 0)
    capture nan >>= \o -> snapshot o `shouldRefuseMatching` ["strict JSON-faithful"]
    -- {"bad": object()} is enforced by types (token data is Json); a
    -- boolean watermark likewise, and the reachable non-integer is a float.
    floatClock <- badData Null (FloatNumber 7.5)
    capture floatClock >>= \o -> snapshot o `shouldRefuseMatching` ["watermark", "integer"]

  -- test_cursor_algebra_polling_concurrent_arrival_and_reconnect_have_no_gap_or_duplicate
  it "polls with no gap or duplicate across concurrent arrival and reconnect" $ do
    inst <- canonicalInstance
    frontier <- (\o -> toInteger (Seq.length o.records)) <$> capture inst
    first' <- page inst 0 2
    let next p = case member "next" p of Int n -> n; _ -> error "next"
        frontierOf p = case member "frontier" p of Int n -> n; _ -> error "frontier"
        positionsOf p = map (member "position") (items (member "records" p))
    door (seal inst source Nothing)
    let loop cursor acc = do
          p <- page inst cursor 2
          let acc' = acc ++ positionsOf p
          if next p == frontierOf p then pure (next p, acc') else loop (next p) acc'
    (cursor, positions) <- loop (next first') (positionsOf first')
    positions `shouldBe` map int [0 .. cursor - 1]
    (cursor > frontier) `shouldBe` True
    atFrontier <- page inst cursor 1
    member "records" atFrontier `shouldBeExactly` Array []
    o <- capture inst
    historyPage o.observed.identity o.records (cursor + 1) 1 `shouldRefuseMatching` ["exceeds captured frontier"]

  describe "Haskell seam" $ do
    it "phaseOf reads the frozen outcomes before the invocation" $ do
      inst <- canonicalInstance
      occurrence <- firstOf <$> inFlight inst
      phaseOf IntMap.empty occurrence `shouldBe` ActivityPending
      phaseText PurePending `shouldBe` "pure_pending"
    it "snapshotWith reuses a projected definition" $ do
      inst <- canonicalInstance
      o <- capture inst
      body <- expectRight (definition o.observed.net)
      snapshotWith body o `shouldBe` snapshot o
    it "an observed document of an empty History is refused" $ do
      inst <- canonicalInstance
      o <- capture inst
      netDocument (Observation o.observed Seq.empty) `shouldRefuseMatching` ["requires nonempty canonical History"]
