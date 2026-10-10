{-# LANGUAGE FieldSelectors #-}

-- | Port of @tests/petrus/agenticus/program/test_agent_net.py@, plus the
-- differential replay of @differential/agent_net_corpus.json@.
module Petrus.Agenticus.AgentNetSpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_, unless, when)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity (ActivityInvocation (..))
import Petrus.Agenticus.Error
import Petrus.Agenticus.Program.AgentNet
import Petrus.Agenticus.Catalog.Descriptor qualified as Catalog
import Petrus.Agenticus.Program.Descriptor qualified as Program
import Petrus.Agenticus.Program.Descriptor (ProgramOwnership (..))
import Petrus.Agenticus.Thread.Continuation qualified as Continuation
import Petrus.Agenticus.TestSupport
import Petrus.Engine qualified as Engine
import Petrus.HistoryStore.Jsonl (encodeLine)
import Petrus.Impetus.History.Records (ActivityRequested (..), Record (..))
import Petrus.Impetus.HistoryStore (HistoryStore (..), inMemoryHistoryStore)
import Petrus.Impetus.Instance (Status)
import Petrus.Impetus.Instance qualified as Instance
import Petrus.Impetus.NetDefinition (projectNetDefinition, serializeNetDefinition)
import Petrus.Impetus.Petrinet (Marking, Token (..), markingFromList, markingPlaces, netPathText, netPlaceOrder, netTransitionOrder, netUriText, placeTokens)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch.Inline (inlineDispatch, newInlineDispatch)
import Test.Hspec

digest :: Text
digest = T.replicate 64 "a"

errorCategoryList :: [Text]
errorCategoryList =
  ["capability", "path", "argv", "write", "unknown", "deadline", "aborted", "stale_epoch", "post_fence", "provider", "schema", "authority", "budget"]

ok :: Either AgenticusError a -> a
ok = either (error . show) id

-- | The upstream @state(...)@ fixture.
data StateArgs = StateArgs
  { sPhase :: Integer
  , sPhases :: Integer
  , sToolCount :: Integer
  , sTools :: Integer
  , sOutput :: Maybe Text
  , sContinuation :: Maybe Text
  , sCapabilities :: [Text]
  , sResults :: [ModelResult]
  }

defaults :: StateArgs
defaults = StateArgs 1 3 0 4 Nothing Nothing ["workspace_read"] []

stateWith :: StateArgs -> Either AgenticusError LoopState
stateWith a = mkLoopState "episode-1" "turn-1" a.sPhase a.sPhases a.sToolCount a.sTools a.sOutput a.sContinuation 7 a.sCapabilities a.sResults

state :: LoopState
state = ok (stateWith defaults)

proposal :: Text -> Text -> Proposal
proposal identity method = ok (mkProposal identity method (Object [("path", String (identity <> ".txt"))]))

readP :: Text -> Proposal
readP identity = proposal identity "workspace_read"

-- | One observed Activity call: @("model", phase, ids, results)@ or
-- @("hands", id, method)@, spelled as JSON so the corpus can compare it.
type Call = Json

data Run = Run
  { engine :: Engine.Engine
  , history :: HistoryStore
  , calls :: [Call]
  , quiescent :: [([Record], Marking, Status)]
  }

-- | The upstream @run(script, hands, initial=...)@ fixture.
run :: [(StopReason, [Proposal])] -> [(Text, Bool)] -> LoopState -> IO Run
run script hands initial = do
  modelScript <- newIORef script
  handsScript <- newIORef hands
  callsRef <- newIORef []
  let pop ref = atomicModifyIORef' ref $ \case
        x : xs -> (xs, x)
        [] -> error "StopIteration"
      record c = modifyIORef' callsRef (c :)
      model inv _context = do
        current <- either throwIO pure (loopStateFromData inv.input)
        (stop, ps) <- pop modelScript
        record (Array [String "model", Int current.phase, Array [String x.id | x <- ps], Array (map modelResultToModelData current.results)])
        let suffix = T.pack (show current.phase)
        either throwIO (pure . modelSettlementToData) $
          mkModelSettlement current stop digest ("output-" <> suffix) ("continuation-" <> suffix) ps
      tool inv _context = do
        let item = member "proposal" inv.input
            identity = memberText "id" item
        record (Array [String "hands", String identity, member "method" item])
        (category, succeeded') <- pop handsScript
        result <-
          either throwIO pure $
            mkModelResult
              identity
              succeeded'
              (if succeeded' then Object [("value", String identity)] else Null)
              (if succeeded' then Nothing else Just (Object [("category", String category), ("detail", String "safe failure")]))
        pure (Object [("version", Int 1), ("result", modelResultToData result)])
  store <- inMemoryHistoryStore
  port <- inlineDispatch <$> newInlineDispatch (Map.fromList [(modelPhaseActivity, model), (handsActivity, tool)])
  engine <-
    Engine.create
      agentNet
      "scripted-agent"
      store
      port
      (agentNetOptions Engine.defaultEngineOptions {Engine.marking = initialMarking initial})
  quiescentRef <- newIORef []
  let loop = do
        outcome <- Engine.advance engine
        inFlight <- Engine.inFlight engine
        records <- Engine.records engine
        seen <- readIORef quiescentRef
        let fresh = case seen of
              [] -> True
              (latest, _, _) : _ -> length records /= length latest
        when (null inFlight && fresh) $ do
          m <- Engine.marking engine
          s <- Engine.status engine
          modifyIORef' quiescentRef ((records, m, s) :)
        when outcome.ready loop
  loop
  Run engine store <$> (reverse <$> readIORef callsRef) <*> (reverse <$> readIORef quiescentRef)

runDefault :: [(StopReason, [Proposal])] -> [(Text, Bool)] -> IO Run
runDefault script hands = run script hands state

terminal :: Run -> IO Json
terminal r = do
  m <- Engine.marking r.engine
  case toList (placeTokens done m) of
    [tok] -> pure tok.payload
    other -> expectationFailure ("expected one terminal token, got " <> show other) >> error "unreachable"

terminalCode :: Run -> IO Json
terminalCode r = member "code" <$> terminal r

requested :: Run -> IO [Text]
requested r = do
  records <- Engine.records r.engine
  pure [a.activity | RActivityRequested a <- records]

modelCall :: Integer -> [Text] -> [Json] -> Json
modelCall ph ids results = Array [String "model", Int ph, Array (map String ids), Array results]

handsCall :: Text -> Text -> Json
handsCall identity method = Array [String "hands", String identity, String method]

failure :: Text -> Text -> Json
failure category detail =
  Object [("version", Int 1), ("ok", Bool False), ("data", Null), ("error", Object [("category", String category), ("detail", String detail)])]

success :: Text -> Json
success value = Object [("version", Int 1), ("ok", Bool True), ("data", Object [("value", String value)]), ("error", Null)]

callResults :: Json -> [Json]
callResults = \case
  Array [_, _, _, Array rs] -> rs
  _ -> []

spec :: Spec
spec = do
  describe "program/test_agent_net.py" upstream
  describe "differential/agent_net_corpus.json" differential

upstream :: Spec
upstream = do
  it "test_exact_descriptors_capabilities_and_serializable_envelopes" $ do
    agentAsNetProgram.ownership `shouldBe` NetOwned
    agentAsNetProgram.acceptsFreshStart `shouldBe` True
    agentAsNetProgram.ownsSteering `shouldBe` False
    agentAsNetProgram.ownsEvaluation `shouldBe` False
    length agentAsNetProgram.acceptedContinuations `shouldBe` 1
    map (.identity) agentAsNetProgram.acceptedContinuations `shouldBe` [agentAsNetContinuationDescriptor.identity]
    agentAsNetProgram.producedContinuation `shouldBe` Just agentAsNetContinuationDescriptor.identity
    agentAsNetProgramCapabilities.offers `shouldBe` Set.fromList ["program.net-owned"]
    agentAsNetContinuationCapabilities.offers `shouldBe` Set.fromList ["continuation.net-owned"]
    state.outputRef `shouldBe` Nothing
    state.continuationRef `shouldBe` Nothing
    loopStateFromData (loopStateToData state) `shouldBe` Right state
    let item = readP "call-1"
    proposalFromData (proposalToData item) `shouldBe` Right item

  it "test_fresh_and_resumed_state_reference_contracts" $ do
    state.outputRef `shouldBe` Nothing
    let resumed = ok (stateWith defaults {sOutput = Just "output-prior", sContinuation = Just "continuation-prior"})
    loopStateFromData (loopStateToData resumed) `shouldBe` Right resumed
    stateWith defaults {sOutput = Just "output-only"} `shouldRaise` (ValueError, "both be absent or both be present")
    stateWith defaults {sContinuation = Just "continuation-only"} `shouldRaise` (ValueError, "both be absent or both be present")

  it "test_exact_topology_activity_separation_and_done_token_completion" $ do
    Set.fromList (map netPathText (netPlaceOrder agentNet))
      `shouldBe` Set.fromList ["model_pending", "model_settled", "tool_pending", "tool_settled", "done"]
    Set.fromList (map netPathText (netTransitionOrder agentNet))
      `shouldBe` Set.fromList ["model_phase", "classify_model", "execute_tool", "reject_tool", "record_result"]
    r <- runDefault [(Stop, [])] []
    m <- Engine.marking r.engine
    m `shouldBe` markingFromList [(done, toList (placeTokens done m))]
    map netPathText (markingPlaces m) `shouldBe` ["done"]
    Engine.status r.engine `shouldReturn` Instance.Completed
    r.calls `shouldBe` [modelCall 1 [] []]
    requested r `shouldReturn` [modelPhaseActivity]
    terminal r
      `shouldReturn` Object
        [ ("version", Int 1)
        , ("episode_id", String "episode-1")
        , ("turn_id", String "turn-1")
        , ("code", String "completed")
        , ("phases", Int 1)
        , ("tools", Int 0)
        , ("output_ref", String "output-1")
        , ("continuation_ref", String "continuation-1")
        ]

  it "test_multi_tool_batch_is_sequential_and_one_activity_per_actual_call" $ do
    r <- runDefault [(ToolUse, [readP "one", readP "two"]), (Stop, [])] [("ok", True), ("ok", True)]
    r.calls
      `shouldBe` [ modelCall 1 ["one", "two"] []
                 , handsCall "one" "workspace_read"
                 , handsCall "two" "workspace_read"
                 , modelCall 2 [] [success "one", success "two"]
                 ]
    requested r `shouldReturn` [modelPhaseActivity, handsActivity, handsActivity, modelPhaseActivity]
    terminalCode r `shouldReturn` String "completed"

  it "test_unsupported_and_not_granted_are_pure_ordered_rejections" $ do
    r <- runDefault [(ToolUse, [proposal "unknown" "not_a_tool", proposal "blocked" "workspace_write"]), (Stop, [])] []
    let refused = failure "capability" "tool is unsupported or not granted"
    r.calls `shouldBe` [modelCall 1 ["unknown", "blocked"] [], modelCall 2 [] [refused, refused]]
    requested r `shouldReturn` [modelPhaseActivity, modelPhaseActivity]

  it "test_length_rejects_whole_batch_without_hands_and_returns_ordered_results" $ do
    r <- runDefault [(Length, [readP "one", readP "two"]), (Stop, [])] []
    let refused = failure "provider" "proposal rejected after length stop"
    r.calls `shouldBe` [modelCall 1 ["one", "two"] [], modelCall 2 [] [refused, refused]]
    (filter (== handsActivity) <$> requested r) `shouldReturn` []
    terminalCode r `shouldReturn` String "completed"

  it "test_length_without_proposals_is_a_completed_provider_phase" $ do
    r <- runDefault [(Length, [])] []
    r.calls `shouldBe` [modelCall 1 [] []]
    terminalCode r `shouldReturn` String "completed"

  it "test_proposals_are_discovered_from_content_not_the_stop_reason" $ do
    r <- runDefault [(Stop, [readP "one"]), (Stop, [])] [("ok", True)]
    [c | Array (String c : _) <- r.calls] `shouldBe` ["model", "hands", "model"]
    terminalCode r `shouldReturn` String "completed"

  forM_ [(ErrorStop, "failed"), (Aborted, "cancelled")] $ \(stop, code) ->
    it ("test_provider_terminal_routes[" <> show stop <> "-" <> T.unpack code <> "]") $ do
      r <- runDefault [(stop, [readP "ignored"])] []
      r.calls `shouldBe` [modelCall 1 ["ignored"] []]
      terminalCode r `shouldReturn` String code

  it "test_hands_abort_cancels_after_current_call" $ do
    r <- runDefault [(ToolUse, [readP "one", readP "two"])] [("aborted", False)]
    r.calls `shouldBe` [modelCall 1 ["one", "two"] [], handsCall "one" "workspace_read"]
    terminalCode r `shouldReturn` String "cancelled"
    (member "tools" <$> terminal r) `shouldReturn` Int 1

  it "test_phase_and_tool_budget_terminals" $ do
    phaseRun <- run [(Length, [readP "one"])] [] (ok (stateWith defaults {sPhases = 1}))
    toolRun <- run [(ToolUse, [readP "one"])] [] (ok (stateWith defaults {sTools = 0}))
    terminalCode phaseRun `shouldReturn` String "phase-budget-exhausted"
    terminalCode toolRun `shouldReturn` String "tool-budget-exhausted"
    toolRun.calls `shouldBe` [modelCall 1 ["one"] []]

  it "test_mid_batch_tool_budget_stops_before_a_second_hands_dispatch" $ do
    r <- run [(ToolUse, [readP "one", readP "two"])] [("ok", True)] (ok (stateWith defaults {sTools = 1}))
    r.calls `shouldBe` [modelCall 1 ["one", "two"] [], handsCall "one" "workspace_read"]
    terminalCode r `shouldReturn` String "tool-budget-exhausted"
    (member "tools" <$> terminal r) `shouldReturn` Int 1

  it "test_blocked_then_allowed_batch_preserves_result_order" $ do
    r <- runDefault [(ToolUse, [proposal "blocked" "workspace_write", readP "allowed"]), (Stop, [])] [("ok", True)]
    (r.calls !! 1) `shouldBe` handsCall "allowed" "workspace_read"
    let results = callResults (r.calls !! 2)
    map (member "ok") results `shouldBe` [Bool False, Bool True]
    map (member "category" . member "error") results `shouldBe` [String "capability", Null]

  it "test_failed_hands_result_is_model_data_and_not_an_escaped_failure" $ do
    r <- runDefault [(ToolUse, [readP "one"]), (Stop, [])] [("path", False)]
    r.calls
      `shouldBe` [modelCall 1 ["one"] [], handsCall "one" "workspace_read", modelCall 2 [] [failure "path" "safe failure"]]
    terminalCode r `shouldReturn` String "completed"

  it "test_results_are_supplied_to_exactly_one_following_model_phase" $ do
    r <- runDefault [(ToolUse, [readP "one"]), (ToolUse, [readP "two"]), (Stop, [])] [("ok", True), ("ok", True)]
    let modelCalls = [c | c@(Array (String "model" : _)) <- r.calls]
    map (map (member "value" . member "data") . callResults) modelCalls `shouldBe` [[], [String "one"], [String "two"]]

  forM_ errorCategoryList $ \category ->
    it ("test_model_result_projection_has_exact_shape_and_known_error_categories[" <> T.unpack category <> "]") $ do
      let result = ok (failed "call" category "bounded")
      modelResultToModelData result `shouldBe` failure category "bounded"
      modelResultFromData (modelResultToData result) `shouldBe` Right result

  it "test_model_result_error_vocabulary_is_the_hands_contract" $ do
    Set.fromList errorCategoryList `shouldBe` errorCategories
    failed "call" "new-unruled-error" "bounded" `shouldRaise` (ValueError, "category is unsupported")

  it "test_payloads_and_all_loop_dimensions_are_bounded" $ do
    mkProposal "large" "workspace_write" (Object [("content", String (T.replicate (fromInteger maxJsonBytes) "x"))])
      `shouldRaise` (ValueError, "4096-byte bound")
    failed "failed" "unknown" (T.replicate 129 "x") `shouldRaise` (ValueError, "128-byte bound")
    mkModelSettlement state ToolUse digest "output" "continuation" [readP ("call-" <> T.pack (show i)) | i <- [0 .. maxProposals]]
      `shouldRaise` (ValueError, "bounded batch")
    mkModelSettlement state ToolUse digest "output" "continuation" [readP "duplicate", readP "duplicate"]
      `shouldRaise` (ValueError, "unique")
    stateWith defaults {sPhases = maxPhases + 1} `shouldRaise` (ValueError, "phase ordinal")
    stateWith defaults {sTools = maxTools + 1} `shouldRaise` (ValueError, "tool count")
    -- @state(phase=True)@: a boolean is not an integer.
    let withBool = case loopStateToData state of
          Object members -> Object [(k, if k == "phase" then Bool True else v) | (k, v) <- members]
          other -> other
    loopStateFromData withBool `shouldRaise` (ValueError, "phase ordinal")

  it "test_history_has_model_and_hands_facts_without_custody_data" $ do
    r <- runDefault [(ToolUse, [readP "one"]), (Stop, [])] [("ok", True)]
    records <- Engine.records r.engine
    requested r `shouldReturn` [modelPhaseActivity, handsActivity, modelPhaseActivity]
    length [() | RActivityCompleted _ <- records] `shouldBe` 3
    -- The reference scans @repr(record)@; the durable spelling is scanned
    -- here, together with the derived 'Show'.
    let encoded = T.toLower (T.concat (map (either id TE.decodeUtf8 . encodeLine) records) <> T.pack (show records))
    forM_ ["transcript-bytes", "credential", "api_key", "attachment_id", "attachment_epoch", "territory_id", "raw_provider", "diagnostics"] $ \value ->
      (value `T.isInfixOf` encoded) `shouldBe` False

  it "test_reconstruction_matches_every_committed_quiescent_prefix" $ do
    r <- runDefault [(ToolUse, [readP "one"]), (Stop, [])] [("ok", True)]
    stored <- toList <$> r.history.snapshot
    records <- Engine.records r.engine
    stored `shouldBe` records
    (length r.quiescent > 2) `shouldBe` True
    forM_ r.quiescent $ \(prefix, expectedMarking, expectedStatus) -> do
      prefixHistory <- inMemoryHistoryStore
      prefixHistory.extend prefix
      port <- inlineDispatch <$> newInlineDispatch Map.empty
      resumed <-
        Engine.load agentNet "scripted-agent" prefixHistory port (agentNetOptions Engine.defaultEngineOptions)
      Engine.inFlight resumed >>= (`shouldSatisfy` null)
      Engine.marking resumed `shouldReturn` expectedMarking
      Engine.status resumed `shouldReturn` expectedStatus
      Engine.close resumed

  it "test_static_net_module_has_no_provider_or_runtime_dependency" $ do
    source <- TE.decodeUtf8 <$> BS.readFile "src/Petrus/Agenticus/Program/AgentNet.hs"
    let imported = [T.words line !! 1 | line <- T.lines source, "import " `T.isPrefixOf` line, length (T.words line) > 1]
        forbidden = ["Anthropic", "OpenAI", "Petrus.Agenticus.Runtime"]
    (length imported > 5) `shouldBe` True
    [m | m <- imported, any (`T.isPrefixOf` m) forbidden] `shouldBe` []

-- ---------------------------------------------------------------------------
-- Differential replay

corpusPath :: FilePath
corpusPath = "differential/agent_net_corpus.json"

differential :: Spec
differential = do
  corpus <- runIO (loadJson corpusPath)
  it "Net definition bytes and implementation URIs match the reference" $ do
    let definition = member "definition" corpus
    (TE.decodeUtf8 <$> (projectNetDefinition agentNet >>= serializeNetDefinition)) `shouldBe` Right (memberText "bytes" definition)
    Array (map (String . netUriText) (sort (Map.keys agentNetHandlersByUri))) `shouldBe` member "handlers" definition
    Array (map (String . netUriText) (sort (Map.keys agentNetGuardsByUri))) `shouldBe` member "guards" definition
  describe "scripted runs (calls, History bytes, status, terminal)" $
    case member "runs" corpus of
      Array runs -> forM_ runs replayRun
      _ -> it "has runs" (expectationFailure "corpus has no runs")
  it "envelope from_data / to_data bytes and refusals" $
    case member "envelopes" corpus of
      Array cases -> do
        mismatches <- concat <$> mapM checkEnvelope cases
        unless (null mismatches) $ expectationFailure (unlines (take 10 mismatches))
        length cases `shouldSatisfy` (> 1000)
      _ -> expectationFailure "corpus has no envelopes"

replayRun :: Json -> Spec
replayRun entry = it (T.unpack (memberText "name" entry)) $ do
  initial <- expectRight (loopStateFromData (member "initial" entry))
  script <- case member "script" entry of
    Array steps -> mapM step steps
    _ -> fail "script"
  hands <- case member "hands" entry of
    Array outcomes -> pure [(c, b) | Array [String c, Bool b] <- outcomes]
    _ -> fail "hands"
  r <- run script hands initial
  Array r.calls `shouldBe` member "calls" entry
  records <- Engine.records r.engine
  map (either id TE.decodeUtf8 . encodeLine) records `shouldBe` [s | String s <- arrayOf (member "history" entry)]
  (String . Instance.statusText <$> Engine.status r.engine) `shouldReturn` member "status" entry
  m <- Engine.marking r.engine
  let finished = case toList (placeTokens done m) of
        tok : _ -> tok.payload
        [] -> Null
  finished `shouldBe` member "terminal" entry
  where
    step = \case
      Array [stop, Array items] -> do
        reason <- expectRight (parseStopReason stop)
        ps <- mapM (expectRight . proposalFromData) items
        pure (reason, ps)
      other -> fail ("bad step " <> show other)
    arrayOf = \case
      Array xs -> xs
      _ -> []

checkEnvelope :: Json -> IO [String]
checkEnvelope entry = do
  let kind = memberText "kind" entry
      input = member "input" entry
      actual = case kind of
        "proposal" -> proposalToData <$> proposalFromData input
        "model_result" -> modelResultToData <$> modelResultFromData input
        "model_result_failed" -> modelResultToData <$> modelResultFromData input
        "loop_state" -> loopStateToData <$> loopStateFromData input
        "model_settlement" -> modelSettlementToData <$> modelSettlementFromData input
        "tool_work" -> toolWorkToData <$> toolWorkFromData input
        "hands_settlement" -> handsSettlementToData <$> handsSettlementFromData input
        "terminal" -> terminalToData <$> terminalFromData input
        other -> error ("unknown kind " <> T.unpack other)
      expected = case member "data" entry of
        String bytes -> Right bytes
        _ -> Left (Object [("class", member "class" entry), ("message", member "message" entry)])
      got = either (Left . refusal) (Right . dumpsDefault) actual
      label = T.unpack kind <> " " <> T.unpack (memberText "label" entry)
  pure [label <> ": expected " <> show expected <> ", got " <> show got | got /= expected]
