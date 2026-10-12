-- | @tests/unit/agents/test_pi.py@, except its coding-activity cases, which
-- drive the host's @V5MutationGate@ and live in hamsterdan-host's
-- @PiActivitySpec@.
module PiSpec (spec) where

import Control.Exception (throwIO, try)
import Control.Monad (forM, forM_)
import Data.IORef
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString.Base16 qualified as Base16
import Hamsterdan.Agents.Pi
import Hamsterdan.Agents.Pi.Doubles
import Hamsterdan.Agents.Protocol
import Hamsterdan.Agents.Validate
import Hamsterdan.Contracts.Codec (contract, encode)
import Petrus.Agenticus.Error (ErrorClass (TimeoutError), agenticusError)
import Petrus.Agenticus.Runtime.Operation (runtimeProtocolError)
import Petrus.Agenticus.Runtime.PiA2Host (PiA2RuntimeStart (..))
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumpsText, parseJson, surrogateRefusingLoads)
import PiDoubles
import Test.Hspec

reviewRequest :: ReviewRequest
reviewRequest =
  ReviewRequest
    { repository = "owner/repo"
    , pullRequest = 7
    , epoch = 2
    , head = headSha
    , base = baseSha
    , diffPath = "diff.patch"
    , policy = []
    , reviewLenses = ["correctness"]
    , contextPaths = []
    , actionsEvidence = []
    , priorFindings = []
    , priorComments = []
    , priorReplies = []
    , appliedChanges = []
    }

conversationRequest :: ConversationRequest
conversationRequest =
  ConversationRequest
    { repository = "owner/repo"
    , pullRequest = 7
    , epoch = 2
    , head = headSha
    , base = baseSha
    , commentContext = [("text", str "status")]
    , actor = [("id", int 1), ("login", str "human")]
    , dashboard = [("review", str "clear")]
    , gates = [[("name", str "overall"), ("ready", Bool True)]]
    , findings = []
    , allowedIntents = [[("type", str "status"), ("arguments", arr []), ("mutation", Bool False)]]
    }

codingRequest :: CodingRequest
codingRequest =
  CodingRequest
    { kind = "change"
    , repository = "owner/repo"
    , pullRequest = 7
    , epoch = 2
    , head = headSha
    , base = baseSha
    , ref = "hamsterdan/change/one"
    , selectedWork = []
    , failureEvidence = []
    , fingerprint = ""
    , lineage = []
    , reproductionStatus = "unknown"
    , mergeBase = False
    }

common :: [(Text, Json)]
common =
  [ ("repository", str "owner/repo")
  , ("pull_request", int 7)
  , ("epoch", int 2)
  , ("head", str headSha)
  , ("base", str baseSha)
  ]

clearReview :: Json
clearReview = obj (common <> [("status", str "clear"), ("findings", arr []), ("lineage", arr [])])

render :: Json -> Text
render = either (error . show) id . dumpsText defaultDumps

sortedCompact :: EncodeOptions
sortedCompact = defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True}

parse :: Text -> Json
parse = either error id . parseJson surrogateRefusingLoads . TE.encodeUtf8

keys :: Json -> [Text]
keys = \case
  Object members -> map fst members
  _ -> []

member :: Text -> Json -> Json
member name = \case
  Object members -> maybe Null id (lookup name members)
  _ -> Null

prompt :: PromptKind -> AgentRequest -> Text
prompt kind request = either (error . show) id (encodePrompt kind testUrl request)

-- | @with pytest.raises(AgentProtocolError) as caught: ...@.
failure :: IO a -> IO AgentProtocolError
failure action =
  try action >>= \case
    Left e -> pure e
    Right _ -> fail "expected AgentProtocolError"

failsMatching :: Text -> IO a -> Expectation
failsMatching pattern action = do
  e <- failure action
  T.unpack e.reason `shouldContain` T.unpack pattern

invocation :: Text -> Integer -> Invocation
invocation operation attempt = Invocation {operation, attempt, isCurrent = Nothing}

-- | @is_current=lambda: next(iter(values))@.
currentFrom :: [Bool] -> IO (IO Bool)
currentFrom values = do
  ref <- newIORef values
  pure $ atomicModifyIORef' ref $ \case
    next : rest -> (rest, next)
    [] -> ([], error "StopIteration")

reviewWith :: PiNativeRunner -> Text -> Text -> Maybe (IO Bool) -> IO ReviewResult
reviewWith subject url operation current = (piAgentRunner subject).review url reviewRequest (invocation operation 1) {isCurrent = current}

timeoutError :: IO a
timeoutError = throwIO (agenticusError TimeoutError "timed out")

spec :: Spec
spec = describe "tests/unit/agents/test_pi.py" $ do
  describe "test_prompts_supply_exact_canonical_bounded_result_contract" $
    forM_
      [ (ReviewKind, AgentReview reviewRequest, 3)
      , (ConversationKind, AgentConversation conversationRequest, 2)
      , (CodingKind, AgentCoding codingRequest, 2)
      ]
      $ \(kind, request, version) -> it (T.unpack (promptKindText kind)) $ do
        let encoded = prompt kind request
            payload = parse encoded
            contractValue = member "response_contract" payload
            exactFields = Set.fromList (keys (member "exact_fields" contractValue))
            forbidden = case member "forbidden_envelope_fields" contractValue of
              Array values -> Set.fromList [s | String s <- values]
              _ -> Set.empty
            requestData = case request of
              AgentReview r -> encode contract r
              AgentConversation r -> encode contract r
              AgentCoding r -> encode contract r
            resultFields = case kind of
              ReviewKind -> reviewResultFields
              ConversationKind -> conversationResultFields
              CodingKind -> codingResultFields
        encoded `shouldBe` prompt kind request
        dumpsText sortedCompact payload `shouldBe` Right encoded
        payload
          `shouldBe` obj
            [ ("instructions", member "instructions" payload)
            , ("kind", str (promptKindText kind))
            , ("prompt_version", int version)
            , ("repository_url", str testUrl)
            , ("request", requestData)
            , ("response_contract", contractValue)
            ]
        exactFields `shouldBe` resultFields
        Set.disjoint exactFields forbidden `shouldBe` True
        forbidden `shouldBe` Set.difference (Set.fromList (keys payload)) exactFields
        T.length encoded `shouldSatisfy` (<= 64 * 1024)

  it "test_prompt_nested_contracts_share_validator_field_sets" $ do
    let review = member "nested" (member "response_contract" (parse (prompt ReviewKind (AgentReview reviewRequest))))
        conversation = member "nested" (member "response_contract" (parse (prompt ConversationKind (AgentConversation conversationRequest))))
        fieldsOf name value = Set.fromList (keys (member name value))
    fieldsOf "finding_exact_fields" review `shouldBe` findingFields
    fieldsOf "related_location_exact_fields" review `shouldBe` relatedLocationFields
    fieldsOf "lineage_exact_fields" review `shouldBe` lineageFields
    fieldsOf "intent_exact_fields" conversation `shouldBe` intentFields
    reviewResultFields `shouldBe` Set.fromList (keys (encode contract (ReviewResult "" 0 0 "" "" "" [] [])))
    Set.isProperSubsetOf (Set.fromList commonResultFields) reviewResultFields `shouldBe` True
    codingResultFields
      `shouldBe` Set.fromList (keys (encode contract (CodingResult "" "" 0 0 "" "" "" "" "" "" [] [] "")))

  it "test_prompt_requires_marker_safe_finding_and_lineage_identities" $ do
    let payload = parse (prompt ReviewKind (AgentReview reviewRequest))
        nested = member "nested" (member "response_contract" payload)
        grammar = "[A-Za-z0-9][A-Za-z0-9._-]{0,47}"
    member "prompt_version" payload `shouldBe` int 3
    member "id" (member "finding_exact_fields" nested)
      `shouldBe` str ("unique 1-48 ASCII-character identifier matching " <> grammar <> "; colon and whitespace are forbidden")
    member "finding_id" (member "lineage_exact_fields" nested)
      `shouldBe` str ("unique within lineage; for new and still_open copy an exact returned finding.id matching " <> grammar)

  it "test_supplied_review_contract_describes_outputs_the_validator_accepts" $ do
    let statusOf = \case
          Right (ResultReview r) -> Just r.status
          _ -> Nothing
        finding =
          obj
            [ ("id", str "finding-one")
            , ("path", str "src/example.py")
            , ("line", int 7)
            , ("related_locations", arr [obj [("path", str "tests/test_example.py"), ("line", int 11)]])
            , ("title", str "Guard the exact state")
            , ("body", str "The current branch accepts stale state.")
            , ("severity", str "high")
            , ("confidence", Float 0.9)
            , ("evidence", str "The comparison uses the prior value.")
            , ("blocking", Bool True)
            , ("suggestion", str "return current == expected")
            ]
    statusOf (validateResult KindReview clearReview (AgentReview reviewRequest) Nothing) `shouldBe` Just "clear"
    statusOf
      ( validateResult
          KindReview
          ( obj
              ( common
                  <> [ ("status", str "blocking")
                     , ("findings", arr [finding])
                     , ("lineage", arr [obj [("finding_id", str "finding-one"), ("state", str "new"), ("supersedes", Null)]])
                     ]
              )
          )
          (AgentReview reviewRequest)
          Nothing
      )
      `shouldBe` Just "blocking"

  it "test_prompt_envelope_fields_remain_invalid_result_fields" $ do
    let members = membersOf clearReview
    refusedMatching "result fields differ" $
      validateResult KindReview (obj (members <> [("prompt_version", int 3)])) (AgentReview reviewRequest) Nothing

  it "test_explicit_response_contract_still_fails_closed_when_prompt_exceeds_limit" $ do
    let paths = [T.pack ("context/" <> pad (show index) <> "-") <> T.replicate 700 "x" <> ".txt" | index <- [0 :: Int .. 99]]
        pad s = replicate (3 - length s) '0' <> s
    refusedMatching "prompt exceeded limit" $
      encodePrompt ReviewKind testUrl (AgentReview reviewRequest {contextPaths = paths})

  it "test_review_waits_reads_strict_result_and_closes_verified_operation" $ do
    operation <- newFakeOperation "review:one" TurnCompleted True
    (subject, runtime) <- fakeRunner clearReview operation
    result <- reviewWith subject testUrl "review:one" Nothing
    result.status `shouldBe` "clear"
    started <- readIORef runtime.started
    length started `shouldBe` 1
    let first = firstOf started
    first.prompt `shouldBe` prompt ReviewKind (AgentReview reviewRequest)
    first.workspaceArchive `shouldBe` testWorkspaceArchive
    first.operationId `shouldBe` piOperationId "review:one" 1
    first.workspaceDigest `shouldBe` TE.decodeUtf8 (Base16.encode (SHA256.hash testWorkspaceArchive))
    first.workspaceCorrelation `shouldBe` "synthetic-workspace"
    first.policy `shouldBe` readPolicy
    readIORef operation.waits `shouldReturn` 1
    readIORef operation.closed `shouldReturn` 1

  it "test_logical_operation_and_attempt_derive_stable_distinct_pi_execution_identities" $ do
    started <- forM [1, 2] $ \attempt -> do
      operation <- newFakeOperation (piOperationId "review:attempts" attempt) TurnCompleted True
      runtime <- newFakeRuntime operation (render clearReview) []
      subject <- fakeRunnerFor runtime defaultPiRunnerOptions
      result <- (piAgentRunner subject).review testUrl reviewRequest (invocation "review:attempts" attempt)
      result.status `shouldBe` "clear"
      (\values -> (firstOf values).operationId) <$> readIORef runtime.started
    started `shouldBe` [piOperationId "review:attempts" 1, piOperationId "review:attempts" 2]

  it "test_conversation_and_code_preserve_strict_output_correlation" $ do
    let intent = [("type", str "status"), ("arguments", obj []), ("mutation", Bool False), ("explicit", Bool True), ("confidence", int 1)]
    conversationOperation <- newFakeOperation "conversation:one" TurnCompleted True
    (subject, _) <- fakeRunner (obj (common <> [("intents", arr [obj intent])])) conversationOperation
    conversed <- (piAgentRunner subject).converse testUrl conversationRequest (invocation "conversation:one" 1)
    conversed.intents `shouldBe` [intent]
    let codingResult =
          common
            <> [ ("kind", str "change")
               , ("ref", str "hamsterdan/change/one")
               , ("status", str "unchanged")
               , ("reproduction_status", str "not_attempted")
               , ("diff", str "")
               , ("changed_files", arr [])
               , ("validation_evidence", arr [])
               , ("proposed_commit_message", str "")
               ]
    codeOperation <- newFakeOperation "code:one" TurnCompleted True
    (coder, _) <- fakeRunner (obj codingResult) codeOperation
    coded <- (piAgentRunner coder).code testUrl codingRequest (invocation "code:one" 1)
    coded.status `shouldBe` "unchanged"
    mismatchedOperation <- newFakeOperation "code:two" TurnCompleted True
    let mismatched = [(k, if k == "head" then str (T.replicate 40 "c") else v) | (k, v) <- codingResult]
    (mismatchedRunner, _) <- fakeRunner (obj mismatched) mismatchedOperation
    failsMatching "correlation" $ (piAgentRunner mismatchedRunner).code testUrl codingRequest (invocation "code:two" 1)

  it "test_malformed_output_and_operation_identity_mismatch_fail_closed" $ do
    malformedOperation <- newFakeOperation (piOperationId "review:malformed" 1) TurnCompleted True
    runtime <- newFakeRuntime malformedOperation "{}" []
    writeIORef runtime.output "not-json"
    malformed <- fakeRunnerFor runtime defaultPiRunnerOptions
    failsMatching "malformed JSON" $ reviewWith malformed testUrl "review:malformed" Nothing
    readIORef malformedOperation.closed `shouldReturn` 1

    mismatchedOperation <- newFakeOperation "review:other" TurnCompleted True
    other <- newFakeRuntime mismatchedOperation "{}" []
    mismatched <- fakeRunnerFor other defaultPiRunnerOptions
    failsMatching "identity mismatched" $ reviewWith mismatched testUrl "review:expected" Nothing
    readIORef mismatchedOperation.cancellations `shouldReturn` ["operation-mismatch"]
    readIORef mismatchedOperation.closed `shouldReturn` 1

  it "test_runtime_never_starts_without_valid_explicit_operation_identity" $ do
    operation <- newFakeOperation "review:unclaimed" TurnCompleted True
    runtime <- newFakeRuntime operation "{}" []
    subject <- fakeRunnerFor runtime defaultPiRunnerOptions
    failsMatching "invalid operation" $ reviewWith subject testUrl "" Nothing
    (length <$> readIORef runtime.started) `shouldReturn` 0

  it "test_authority_is_rechecked_after_workspace_preparation_before_start" $ do
    operation <- newFakeOperation (piOperationId "review:stale-preparation" 1) TurnCompleted True
    runtime <- newFakeRuntime operation "{}" []
    subject <- fakeRunnerFor runtime defaultPiRunnerOptions
    current <- currentFrom [True, False]
    caught <- failure (reviewWith subject testUrl "review:stale-preparation" (Just current))
    caught.canceled `shouldBe` True
    (length <$> readIORef runtime.started) `shouldReturn` 0

  it "test_stable_start_identity_and_failed_preflight_cannot_start_or_reuse_route" $ do
    operation <- newFakeOperation (piOperationId "review:expected" 1) TurnCompleted True
    runtime <- newFakeRuntime operation "{}" []
    subject <- fakeRunnerFor runtime defaultPiRunnerOptions
    _ <- failure (reviewWith subject testUrl "review:expected" Nothing)
    first <- firstOf <$> readIORef runtime.started
    replayOperation <- newFakeOperation (piOperationId "review:expected" 1) TurnCompleted True
    replayRuntime <- newFakeRuntime replayOperation "{}" []
    replay <- fakeRunnerFor replayRuntime defaultPiRunnerOptions
    _ <- failure (reviewWith replay testUrl "review:expected" Nothing)
    second <- firstOf <$> readIORef replayRuntime.started
    (first.operationId, first.episodeId, first.turnId) `shouldBe` (second.operationId, second.episodeId, second.turnId)

    again <- fakeRunnerFor runtime defaultPiRunnerOptions
    failsMatching "repository URL" $ reviewWith again "https://user@example.invalid/repo" "review:preflight" Nothing
    failsMatching "identity mismatched" $ reviewWith again testUrl "review:preflight" Nothing
    length <$> readIORef runtime.started `shouldReturn` 2

  it "test_stale_timeout_failure_and_unverified_cleanup_fail_safe" $ do
    stale <- newFakeOperation "review:stale" TurnCompleted True
    (subject, _) <- fakeRunner clearReview stale
    current <- currentFrom [True, True, False]
    writeIORef stale.waitOverride (Just (const timeoutError))
    caught <- failure (reviewWith subject testUrl "review:stale" (Just current))
    caught.canceled `shouldBe` True
    readIORef stale.cancellations `shouldReturn` ["stale-authority"]
    readIORef stale.closed `shouldReturn` 1

    failed <- newFakeOperation "review:failed" TurnFailed True
    (failedRunner, _) <- fakeRunner clearReview failed
    failsMatching "completed result" $ reviewWith failedRunner testUrl "review:failed" Nothing
    readIORef failed.closed `shouldReturn` 1

    unverified <- newFakeOperation "review:unclean" TurnCompleted False
    (uncleanRunner, _) <- fakeRunner clearReview unverified
    failsMatching "cleanup is unverified" $ reviewWith uncleanRunner testUrl "review:unclean" Nothing

  it "test_default_runner_admits_completion_after_the_retired_outer_timeout" $ do
    elapsed <- newIORef (0 :: Double)
    timeouts <- newIORef []
    operation <- newFakeOperation (piOperationId "review:long-running" 1) TurnCompleted True
    writeIORef operation.waitOverride . Just $ \bound -> do
      modifyIORef' timeouts (<> [bound])
      count <- length <$> readIORef timeouts
      if count == 1 then writeIORef elapsed 301 >> timeoutError else pure ()
    runtime <- newFakeRuntime operation (render clearReview) []
    subject <- fakeRunnerFor runtime defaultPiRunnerOptions {clock = readIORef elapsed}
    result <- reviewWith subject testUrl "review:long-running" Nothing
    result.status `shouldBe` "clear"
    readIORef timeouts `shouldReturn` [Just 0.1, Just 0.1]
    readIORef operation.cancellations `shouldReturn` []
    readIORef operation.closed `shouldReturn` 1

  it "test_stale_authority_is_polled_between_bounded_waits" $ do
    operation <- newFakeOperation (piOperationId "review:stale-wait" 1) TurnCompleted True
    timeouts <- newIORef []
    writeIORef operation.waitOverride (Just (\bound -> modifyIORef' timeouts (<> [bound]) >> timeoutError))
    runtime <- newFakeRuntime operation "{}" []
    subject <- fakeRunnerFor runtime defaultPiRunnerOptions
    current <- currentFrom [True, True, True, False]
    caught <- failure (reviewWith subject testUrl "review:stale-wait" (Just current))
    caught.canceled `shouldBe` True
    readIORef timeouts `shouldReturn` [Just 0.1]
    readIORef operation.cancellations `shouldReturn` ["stale-authority"]
    readIORef runtime.loadedOutputs `shouldReturn` []
    readIORef operation.closed `shouldReturn` 1

  it "test_authority_lost_during_settlement_is_not_admitted" $ do
    operation <- newFakeOperation (piOperationId "review:stale-settlement" 1) TurnCompleted True
    runtime <- newFakeRuntime operation (render clearReview) []
    subject <- fakeRunnerFor runtime defaultPiRunnerOptions
    current <- currentFrom [True, True, True, False]
    caught <- failure (reviewWith subject testUrl "review:stale-settlement" (Just current))
    caught.canceled `shouldBe` True
    readIORef operation.cancellations `shouldReturn` ["stale-authority"]
    readIORef runtime.loadedOutputs `shouldReturn` []
    readIORef operation.closed `shouldReturn` 1

  it "test_timeout_cancels_before_verified_close" $ do
    operation <- newFakeOperation (piOperationId "review:timeout" 1) TurnCompleted True
    writeIORef operation.waitOverride (Just (const timeoutError))
    runtime <- newFakeRuntime operation "{}" []
    clock <- currentFrom' [0.0, 2.0]
    subject <- fakeRunnerFor runtime defaultPiRunnerOptions {timeout = Just 1, clock}
    caught <- failure (reviewWith subject testUrl "review:timeout" Nothing)
    caught.timedOut `shouldBe` True
    readIORef operation.cancellations `shouldReturn` ["host-timeout"]
    readIORef operation.closed `shouldReturn` 1

  describe "test_runner_rejects_nonfinite_or_unordered_wait_policy" $
    -- The four parameters that pass a bool or a string ((True, 0.1),
    -- ("1", 0.1), (None, True), (None, "0.1")) do not type-check: the
    -- options are 'Double's. PARITY.md counts them as compile-time.
    forM_
      [ (Just 0, 0.1)
      , (Just (-1), 0.1)
      , (Just (0 / 0), 0.1)
      , (Just (1 / 0), 0.1)
      , (Just 0.05, 0.1)
      , (Nothing, 0)
      , (Nothing, -1)
      , (Nothing, 0 / 0)
      , (Nothing, 1 / 0)
      ]
      $ \(timeout, pollInterval) -> it (show (timeout, pollInterval)) $ do
        operation <- newFakeOperation "unused" TurnCompleted True
        runtime <- newFakeRuntime operation "{}" []
        case newPiNativeRunner (fakePiRuntime runtime) (fakeProvider runtime.workspaces) defaultPiRunnerOptions {timeout, pollInterval} of
          Left message -> T.unpack message `shouldContain` "timeout and poll interval"
          Right _ -> expectationFailure "expected ValueError"

  it "test_coding_archive_policy_derives_unchanged_and_changed_or_rejects_missing_archive" $ do
    let base =
          common
            <> [ ("kind", str "change")
               , ("ref", str "hamsterdan/change/one")
               , ("reproduction_status", str "not_attempted")
               , ("diff", str "")
               , ("changed_files", arr [])
               , ("validation_evidence", arr [])
               , ("proposed_commit_message", str "")
               ]
        with extra = obj ([(k, maybe v id (lookup k extra)) | (k, v) <- base] <> [(k, v) | (k, v) <- extra, isNothing (lookup k base)])
        code subject operation = (piAgentRunner subject).code testUrl codingRequest (invocation operation 1)
    unchangedOperation <- newFakeOperation "code:archive" TurnCompleted True
    (subject, runtime) <- fakeRunner (with [("status", str "unchanged")]) unchangedOperation
    ((.status) <$> code subject "code:archive") `shouldReturn` "unchanged"
    readIORef runtime.loadedArchives `shouldReturn` [piOperationId "code:archive" 1]

    changedOperation <- newFakeOperation "code:changed" TurnCompleted True
    (changedRunner, changedRuntime) <-
      fakeRunner
        ( with
            [ ("status", str "changed")
            , ("diff", str "synthetic")
            , ("changed_files", strs ["x.py"])
            , ("validation_evidence", arr [obj [("command", str "synthetic"), ("result", str "passed")]])
            , ("proposed_commit_message", str "Apply synthetic change")
            ]
        )
        changedOperation
    changed <- code changedRunner "code:changed"
    (changed.diff, changed.changedFiles) `shouldBe` ("canonical diff", ["x.py"])
    readIORef changedRuntime.loadedArchives `shouldReturn` [piOperationId "code:changed" 1]

    missingOperation <- newFakeOperation "code:missing" TurnCompleted True
    (missingRunner, missingRuntime) <- fakeRunner (with [("status", str "unchanged")]) missingOperation
    writeIORef missingRuntime.archive ""
    missing <- failure (code missingRunner "code:missing")
    T.unpack missing.reason `shouldContain` "archive is unavailable"
    missing.resultCategory `shouldBe` Just WorkspaceReconciliation

    invalidOperation <- newFakeOperation "code:invalid-archive" TurnCompleted True
    (invalidRunner, invalidRuntime) <- fakeRunner (with [("status", str "unchanged")]) invalidOperation
    writeIORef invalidRuntime.archiveOverride (Just (const (throwIO (runtimeProtocolError "workspace-archive-corrupt"))))
    invalid <- failure (code invalidRunner "code:invalid-archive")
    T.unpack invalid.reason `shouldContain` "archive is unavailable"
    invalid.resultCategory `shouldBe` Just WorkspaceReconciliation

  it "test_agent_failure_categories_are_closed_and_first_cause_is_one_shot" $ do
    -- The closed-vocabulary TypeError is a type error here: a category is
    -- an 'AgentResultCategory', so "owner/private" cannot be passed.
    let error0 = (protocolError "private diagnostic") {resultCategory = Just OutputSchema}
        retained = retainCleanupCategory CleanupUnverified (retainResultCategory Correlation error0)
    retained.resultCategory `shouldBe` Just OutputSchema
    retained.cleanupCategory `shouldBe` Just CleanupUnverified

  it "test_throwing_runtime_identity_is_sanitized_and_still_closes" $ do
    let operationName = "code:broken-identity"
    operation <- newFakeOperation (piOperationId operationName 1) TurnCompleted True
    runtime <- newFakeRuntime operation "{}" []
    subject <- fakeRunnerFor runtime defaultPiRunnerOptions
    writeIORef operation.identityBroken True
    caught <- failure ((piAgentRunner subject).code testUrl codingRequest (invocation operationName 1))
    caught.resultCategory `shouldBe` Just RuntimeLifecycle
    caught.cleanupCategory `shouldBe` Just CleanupUnverified
    readIORef operation.closed `shouldReturn` 1

  it "test_throwing_cancel_cannot_replace_correlation_or_stale_authority" $ do
    let throwing = Just (const (fail "private cancel diagnostic"))
    mismatch <- newFakeOperation "code:actual" TurnCompleted True
    writeIORef mismatch.cancelOverride throwing
    runtime <- newFakeRuntime mismatch "{}" []
    subject <- fakeRunnerFor runtime defaultPiRunnerOptions
    caught <- failure ((piAgentRunner subject).code testUrl codingRequest (invocation "code:expected" 1))
    caught.resultCategory `shouldBe` Just Correlation
    readIORef mismatch.closed `shouldReturn` 1

    stale <- newFakeOperation (piOperationId "code:stale" 1) TurnCompleted True
    writeIORef stale.cancelOverride throwing
    staleRuntime <- newFakeRuntime stale "{}" []
    staleRunner <- fakeRunnerFor staleRuntime defaultPiRunnerOptions
    current <- currentFrom [True, True, False]
    staleCaught <- failure ((piAgentRunner staleRunner).code testUrl codingRequest (invocation "code:stale" 1) {isCurrent = Just current})
    (staleCaught.canceled, staleCaught.resultCategory) `shouldBe` (True, Nothing)
    readIORef stale.closed `shouldReturn` 1
  where
    currentFrom' :: [Double] -> IO (IO Double)
    currentFrom' values = do
      ref <- newIORef values
      pure $ atomicModifyIORef' ref $ \case
        next : rest -> (rest, next)
        [] -> ([], error "StopIteration")
