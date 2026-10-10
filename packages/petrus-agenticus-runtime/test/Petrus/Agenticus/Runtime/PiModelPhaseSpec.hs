-- | Port of @tests/petrus/agenticus/runtime/test_pi_model_phase.py@. Labels
-- are the reference's pytest ids.
module Petrus.Agenticus.Runtime.PiModelPhaseSpec (spec) where

import Control.Exception (throwIO, try)
import Control.Monad (forM_, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Foldable (toList)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Activity (ActivityExecutionContext (..), ActivityInvocation (..), invocation)
import Petrus.Agenticus.Connection.Custody
  ( AdmissionResult (..)
  , AttachmentFence (..)
  , mkConnectionIdentity
  , ConnectionStatus (..)
  , ConnectionView (..)
  , LeaseMode (..)
  , ReleaseResult (..)
  )
import Petrus.Agenticus.Connection.Materialization (CleanupEvidence (..))
import Petrus.Agenticus.Error
import Petrus.Agenticus.Program.AgentNet
  ( LoopState
  , ModelResult
  , ModelSettlement (..)
  , Proposal (..)
  , StopReason (..)
  , agentNet
  , agentNetOptions
  , done
  , initialMarking
  , loopStateToData
  , maxProposals
  , mkLoopState
  , mkModelResult
  , modelPhaseActivity
  , modelSettlementFromData
  , modelSettlementToData
  , stopReasonText
  )
import Petrus.Agenticus.Runtime.Operation (runtimeProtocolError)
import Petrus.Agenticus.Runtime.Pi (PiHome (..), PiMaterialization (..), pyB64DecodeText, runBounded, strictLoad)
import Petrus.Agenticus.Runtime.PiModelPhase
import Petrus.Agenticus.Runtime.PiSupport (fixture, raises, raisesValueLike, withTemp)
import Petrus.Engine qualified as Engine
import Petrus.Impetus.HistoryStore (inMemoryHistoryStore)
import Petrus.Impetus.Petrinet (Token (..), placeTokens)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Dispatch.Inline (inlineDispatch, newInlineDispatch)
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, findExecutable, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (..), proc)
import Test.Hspec

spec :: Spec
spec = describe "test_pi_model_phase" $ do
  payloadSpecs
  candidateSpecs
  adapterSpecs
  subprocessSpecs
  realHelperSpecs

-- ---------------------------------------------------------------------------
-- Fixtures

key :: ByteString
key = "credential-canary"

usage :: Json
usage =
  Object
    [ ("input", Int 1)
    , ("output", Int 2)
    , ("cacheRead", Int 0)
    , ("cacheWrite", Int 0)
    , ("totalTokens", Int 3)
    , ("cost", Object [("input", Int 0), ("output", Int 0), ("cacheRead", Int 0), ("cacheWrite", Int 0), ("total", Int 0)])
    ]

-- | @assistant(stop, content, **extra)@.
assistant :: Text -> Maybe [Json] -> [(Text, Json)] -> Json
assistant stop content extra =
  Object $
    [ ("role", String "assistant")
    , ("content", Array (fromMaybe [Object [("type", String "text"), ("text", String "private-model-output")]] content))
    , ("api", String "anthropic-messages")
    , ("provider", String "anthropic")
    , ("model", String "claude-sonnet-4-5")
    , ("usage", usage)
    , ("stopReason", String stop)
    , ("timestamp", Int 0)
    ]
      <> extra

defaultAssistant :: Json
defaultAssistant = assistant "stop" Nothing []

-- | @dict.update(name=value)@.
update :: Text -> Json -> Json -> Json
update name value = \case
  Object members
    | isJust (lookup name members) -> Object [(k, if k == name then value else v) | (k, v) <- members]
    | otherwise -> Object (members <> [(name, value)])
  other -> other

toolCall :: Text -> Text -> Json -> Json
toolCall identity name arguments =
  Object [("type", String "toolCall"), ("id", String identity), ("name", String name), ("arguments", arguments)]

userMessage :: Json
userMessage = Object [("role", String "user"), ("content", Array [Object [("type", String "text"), ("text", String "Continue.")]]), ("timestamp", Int 0)]

-- | @json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()@.
encoded :: Json -> ByteString
encoded = either (const (error "unencodable fixture")) id . J.dumps J.compact {J.allowNan = True}

load :: ByteString -> Json
load = either (const (error "fixture is not strict JSON")) id . strictLoad

member :: Text -> Json -> Json
member name = \case
  Object members -> fromMaybe Null (lookup name members)
  _ -> Null

items :: Json -> [Json]
items = \case
  Array xs -> xs
  _ -> []

state :: Integer -> Maybe Text -> Maybe Text -> [ModelResult] -> LoopState
state phase output continuation results =
  either (error . show) id $
    mkLoopState "episode" "turn" phase 4 0 8 output continuation 1 ["workspace_read", "workspace_test"] results

initial :: LoopState
initial = state 1 Nothing Nothing []

result :: Text -> Bool -> Json -> Maybe Json -> ModelResult
result identity ok' value failure = either (error . show) id (mkModelResult identity ok' value failure)

throwsLeft :: Either AgenticusError a -> IO a
throwsLeft = either throwIO pure

-- ---------------------------------------------------------------------------
-- The rig

data CustodyFlags = CustodyFlags
  { admit :: IORef Bool
  , clean :: IORef Bool
  , releaseRaises :: IORef Bool
  , mode :: IORef LeaseMode
  , authorityEpoch :: IORef Integer
  , baseVersion :: IORef Integer
  }

data Operations = Operations
  { continuations :: IORef (Map.Map Text PiModelPhaseContinuationPayloadV1)
  , publications :: IORef (Map.Map Text (PiModelPhaseOutputPayloadV1, PiModelPhaseContinuationPayloadV1))
  , loadRaises :: IORef Bool
  , publishRaises :: IORef Bool
  }

data ClientPlan = ClientPlan
  { final :: Json
  , planClean :: Bool
  , planError :: Maybe Text
  , candidate :: Maybe PhaseCandidate
  }

data Rig = Rig
  { tmp :: FilePath
  , events :: IORef [Text]
  , runtimeRoot :: FilePath
  , config :: PiModelPhaseConfig
  , connection :: ConnectionView
  , custodyFlags :: CustodyFlags
  , custody :: PiModelPhaseCustody
  , ops :: Operations
  , operations :: PiModelPhaseOperations
  , plan :: IORef ClientPlan
  , frames :: IORef [Json]
  , factory :: PhaseFactory
  , adapter :: PiModelPhaseAdapter
  }

event :: IORef [Text] -> Text -> IO ()
event ref name = modifyIORef' ref (<> [name])

newCustody :: IORef [Text] -> IO (CustodyFlags, PiModelPhaseCustody)
newCustody events = do
  flags <- CustodyFlags <$> newIORef True <*> newIORef True <*> newIORef False <*> newIORef LeaseRead <*> newIORef 3 <*> newIORef 4
  let custody =
        PiModelPhaseCustody
          { materialize = \connectionId hostId requested ttl _ -> do
              event events "materialize"
              when (requested /= LeaseRead || ttl <= 0) $ expectationFailure "materialize must request a positive read lease"
              leaseMode <- readIORef flags.mode
              epoch <- readIORef flags.authorityEpoch
              version <- readIORef flags.baseVersion
              now <- getMonotonicTime
              pure
                PiMaterialization
                  { fence = AttachmentFence "credential" "lease" connectionId hostId 1 epoch version
                  , mode = leaseMode
                  , expiresAt = now + ttl
                  , home = PiHome {read = pure key, replace = \_ -> pure ()}
                  }
          , admitResult = \fence operationId -> do
              event events "admit"
              admitted <- readIORef flags.admit
              pure AdmissionResult {operationId, purpose = "result", attachmentId = if admitted then fence.attachmentId else "wrong"}
          , release = \materialization operationId -> do
              event events "release"
              raising <- readIORef flags.releaseRaises
              when raising $ throwIO (userError "private release diagnostic")
              cleaned <- readIORef flags.clean
              pure
                ReleaseResult
                  { operationId
                  , cleanup =
                      CleanupEvidence
                        { attachmentId = materialization.fence.attachmentId
                        , removed = cleaned
                        , alreadyAbsent = False
                        , bytesOverwritten = toInteger (B.length key)
                        , physicalErasureGuaranteed = False
                        , securityViolation = not cleaned
                        }
                  }
          }
  pure (flags, custody)

newOperations :: IORef [Text] -> IO (Operations, PiModelPhaseOperations)
newOperations events = do
  ops <- Operations <$> newIORef Map.empty <*> newIORef Map.empty <*> newIORef False <*> newIORef False
  let operations =
        PiModelPhaseOperations
          { loadContinuation = \reference -> do
              event events "load"
              raising <- readIORef ops.loadRaises
              when raising $ throwIO (userError "private load diagnostic")
              stored <- readIORef ops.continuations
              maybe (throwIO (userError ("KeyError: " <> T.unpack reference))) pure (Map.lookup reference stored)
          , publish = \operationId output continuation -> do
              event events "publish"
              raising <- readIORef ops.publishRaises
              when raising $ throwIO (userError "private publication diagnostic")
              modifyIORef' ops.publications (Map.insert operationId (output, continuation))
              throwsLeft (mkPiModelPhasePublication ("output-" <> operationId) ("continuation-" <> operationId))
          }
  pure (ops, operations)

-- | The reference's scripted @Client@: echo the exact transcript extension
-- the adapter expects, or the plan's candidate or error.
scriptedClient :: IORef ClientPlan -> IORef [Text] -> IORef [Json] -> FilePath -> PhaseClient
scriptedClient planRef events frames privateRoot =
  PhaseClient
    { run = \frame wall heartbeat -> do
        event events "run"
        modifyIORef' frames (<> [frame])
        present <- doesDirectoryExist privateRoot
        when (wall <= 0 || not present) $ expectationFailure "run needs a positive timeout and the private root"
        heartbeat
        p <- readIORef planRef
        forM_ p.planError (throwIO . runtimeProtocolError)
        case p.candidate of
          Just value -> pure value
          Nothing -> do
            prior <- case member "transcript" frame of
              String text -> either (const (error "transcript is not base64")) (pure . load) (pyB64DecodeText text)
              _ -> error "transcript missing"
            let observed = case member "observation" frame of
                  Null -> []
                  observation -> [Object [("role", String "user"), ("content", Array [Object [("type", String "text"), ("text", observation)]]), ("timestamp", Int 0)]]
                results =
                  [ Object
                      [ ("role", String "toolResult")
                      , ("toolCallId", member "id" item)
                      , ("toolName", member "method" item)
                      , ("content", Array [Object [("type", String "text"), ("text", String (either (error . show) id (J.dumpsText J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"} (member "result" item))))]])
                      , ("isError", Bool (member "ok" (member "result" item) /= Bool True))
                      , ("timestamp", Int 0)
                      ]
                  | item <- items (member "results" frame)
                  ]
                messages = items prior <> observed <> results <> [p.final]
            pure PhaseCandidate {assistant = encoded p.final, transcript = encoded (Array messages)}
    , close = do
        event events "client-close"
        (.planClean) <$> readIORef planRef
    }

newRig :: FilePath -> Json -> Text -> IO Rig
newRig tmp final observation = do
  events <- newIORef []
  let runtimeRoot = tmp </> "runtime"
  createDirectory runtimeRoot
  setFileMode runtimeRoot 0o700
  config <-
    newPiModelPhaseConfig
      (piModelPhaseConfig "anthropic" "claude-sonnet-4-5" "host" runtimeRoot "episode" "turn") {observation, timeout = 1}
  let connection = ConnectionView (either (error . show) id (mkConnectionIdentity "connection" "anthropic" "account" "api-key")) StatusReady 3 4 Nothing
  (custodyFlags, custody) <- newCustody events
  (ops, operations) <- newOperations events
  plan <- newIORef ClientPlan {final, planClean = True, planError = Nothing, candidate = Nothing}
  frames <- newIORef []
  let factory =
        PhaseFactory
          { create = \args -> do
              event events "client-create"
              pure (scriptedClient plan events frames args.privateRoot)
          , isSubprocess = False
          }
  adapter <- newPiModelPhaseAdapter config connection custody operations "node" (Just "/fake/pi/index.js") (Just factory)
  pure Rig {tmp, events, runtimeRoot, config, connection, custodyFlags, custody, ops, operations, plan, frames, factory, adapter}

withRig :: Json -> (Rig -> IO a) -> IO a
withRig final body = withTemp $ \tmp -> newRig tmp final "Continue." >>= body

-- | Point the rig's adapter at real @node@, the verbatim helper and the
-- reference's fake coding SDK (@write_fake_coding@), through a subprocess
-- factory that, like the reference's @RealFactory@, needs no probe.
useRealHelper :: Rig -> IO ()
useRealHelper rig = do
  node <- requireNode
  let entry = rig.tmp </> "coding.mjs"
  fixture "model_phase_coding.mjs" >>= B.writeFile entry . TE.encodeUtf8
  setModelPhaseNode rig.adapter node
  setModelPhaseSdkEntrypoint rig.adapter (Just entry)
  setModelPhaseFactory rig.adapter subprocessPhaseFactory {isSubprocess = False}

phaseContext :: (Maybe Json -> IO Json) -> ActivityExecutionContext
phaseContext heartbeat =
  ActivityExecutionContext
    { attemptId = "attempt"
    , epoch = "epoch"
    , claimant = "claimant"
    , instance' = Nothing
    , latestDetails = pure Null
    , heartbeat
    }

invokeRaw :: Rig -> LoopState -> (Maybe Json -> IO Json) -> IO Json
invokeRaw rig value heartbeat =
  modelPhaseAdapterActivity
    rig.adapter
    (invocation modelPhaseActivity (loopStateToData value)) {idempotency = Just "operation"}
    (phaseContext heartbeat)

invoke :: Rig -> LoopState -> IO ModelSettlement
invoke rig value = invokeRaw rig value (\_ -> pure Null) >>= throwsLeft . modelSettlementFromData

eventsOf :: Rig -> IO [Text]
eventsOf rig = readIORef rig.events

publicationsOf :: Rig -> IO (Map.Map Text (PiModelPhaseOutputPayloadV1, PiModelPhaseContinuationPayloadV1))
publicationsOf rig = readIORef rig.ops.publications

-- | @phase._validate_candidate(b"[]", _Candidate(final, [user, final]), state(), ...)@.
validateFresh :: Json -> Either AgenticusError (ByteString, ByteString, [Proposal], StopReason)
validateFresh final =
  validateCandidate
    "[]"
    PhaseCandidate {assistant = encoded final, transcript = encoded (Array [userMessage, final])}
    initial
    "Continue."
    "anthropic"
    "claude-sonnet-4-5"

protocolError :: Text -> IO a -> Expectation
protocolError code action = raises action RuntimeProtocolError code

-- ---------------------------------------------------------------------------
-- Payloads, publications and configuration

payloadSpecs :: Spec
payloadSpecs =
  it "test_payloads_publication_and_config_are_strict_and_bounded" $ withTemp $ \tmp -> do
    void (throwsLeft (mkPiModelPhaseContinuationPayloadV1 "[]"))
    void (throwsLeft (mkPiModelPhaseOutputPayloadV1 "{}"))
    payloadSchemaVersion `shouldBe` 1
    publication <- throwsLeft (mkPiModelPhasePublication "output" "continuation")
    publication.outputReference `shouldBe` "output"
    forM_ ["[NaN]", "[{\"x\":1,\"x\":2}]", "null"] $ \raw ->
      raisesValueLike (mkPiModelPhaseContinuationPayloadV1 raw)
    raisesValueLike (mkPiModelPhaseOutputPayloadV1 "[]")
    raisesValueLike (mkPiModelPhasePublication "" "continuation")
    let runtime = tmp </> "config"
        base = piModelPhaseConfig "anthropic" "claude-sonnet-4-5" "host" runtime "episode" "turn"
    createDirectory runtime
    setFileMode runtime 0o700
    raises (newPiModelPhaseConfig base {provider = "unknown", model = "model"}) ValueError "direct API-key catalog"
    -- The reference passes @timeout=True@; a 'Double' cannot hold a bool, so
    -- the non-positive and non-finite refusals stand in for it.
    forM_ [0, -1, 0 / 0, 1 / 0] $ \bad ->
      raises (newPiModelPhaseConfig base {timeout = bad}) ValueError "positive and finite"
    setFileMode runtime 0o755
    raises (newPiModelPhaseConfig base) ValueError "mode-0700"
    setFileMode runtime 0o700
    accepted <- newPiModelPhaseConfig base {observation = "one\ntwo"}
    accepted.observation `shouldSatisfy` T.isInfixOf "\n"
    raises (newPiModelPhaseConfig base {observation = "bad\0value"}) ValueError "observation is invalid"

-- ---------------------------------------------------------------------------
-- Candidate validation

candidateSpecs :: Spec
candidateSpecs = do
  forM_ [minBound .. maxBound] $ \stop ->
    it ("test_candidate_preserves_stop_optional_private_fields_and_source_order[" <> T.unpack (stopReasonText stop) <> "]") $ do
      let final =
            assistant
              (stopReasonText stop)
              ( Just
                  [ Object
                      [ ("type", String "toolCall")
                      , ("id", String "first")
                      , ("name", String "workspace_read")
                      , ("arguments", Object [("path", String "a")])
                      , ("thoughtSignature", String "private-signature")
                      ]
                  , Object [("type", String "text"), ("text", String "between")]
                  , toolCall "second" "workspace_test" (Object [])
                  ]
              )
              [("errorMessage", String "private-provider-diagnostic"), ("responseId", String "private-response")]
      (_, _, proposals, observed) <- throwsLeft (validateFresh final)
      observed `shouldBe` stop
      map (.id) proposals `shouldBe` ["first", "second"]

  forM_ ["pending", "deferred", "foreign"] $ \stop ->
    it ("test_candidate_rejects_unsupported_terminal_stops[" <> T.unpack stop <> "]") $
      protocolError "malformed-complete" (throwsLeft (validateFresh (assistant stop Nothing [])))

  let mutations =
        [ update "provider" (String "wrong")
        , update "timestamp" (Float (1 / 0))
        , update "usage" (Object [("input", Int 1)])
        , update "content" (Array [Object [("type", String "foreign"), ("text", String "x")]])
        , update "content" (Array [Object [("type", String "text"), ("text", String "x"), ("foreign", Bool True)]])
        ]
  forM_ (zip [0 :: Int ..] mutations) $ \(index, mutation) ->
    it ("test_candidate_rejects_malformed_public_assistant[<lambda>" <> show index <> "]") $
      protocolError "malformed-complete" (throwsLeft (validateFresh (mutation defaultAssistant)))

-- ---------------------------------------------------------------------------
-- The adapter

adapterSpecs :: Spec
adapterSpecs = do
  it "test_success_cleans_and_releases_before_atomic_private_publication" $
    withRig
      ( assistant
          "toolUse"
          (Just [Object [("type", String "text"), ("text", String "private-model-output")], toolCall "call" "workspace_read" (Object [("path", String "a")])])
          []
      )
      $ \rig -> do
        settlement <- invoke rig initial
        settlement.stop `shouldBe` ToolUse
        settlement.outputRef `shouldBe` "output-operation"
        settlement.continuationRef `shouldBe` "continuation-operation"
        map (.id) settlement.proposals `shouldBe` ["call"]
        eventsOf rig `shouldReturn` ["materialize", "client-create", "run", "client-close", "admit", "release", "publish"]
        listDirectory rig.runtimeRoot `shouldReturn` []
        Just (output, continuation) <- Map.lookup "operation" <$> publicationsOf rig
        output.assistantJson `shouldSatisfy` B.isInfixOf "private-model-output"
        continuation.transcriptJson `shouldSatisfy` B.isSuffixOf "]"
        let rendered = encoded (modelSettlementToData settlement)
        forM_ ["credential-canary", "private-model-output", "api_key"] $ \canary ->
          rendered `shouldNotSatisfy` B.isInfixOf canary

  it "test_phase_one_resume_adds_observation_after_prior_continuation" $ withRig defaultAssistant $ \rig -> do
    let prior = [defaultAssistant]
    payload <- throwsLeft (mkPiModelPhaseContinuationPayloadV1 (encoded (Array prior)))
    modifyIORef' rig.ops.continuations (Map.insert "prior" payload)
    void (invoke rig (state 1 (Just "old-output") (Just "prior") []))
    [frame] <- readIORef rig.frames
    member "observation" frame `shouldBe` String "Continue."
    Just (_, continuation) <- Map.lookup "operation" <$> publicationsOf rig
    let transcript = items (load continuation.transcriptJson)
    take 1 transcript `shouldBe` prior
    map (member "role") (drop 1 transcript) `shouldBe` [String "user", String "assistant"]

  it "test_phase_two_injects_exact_ordered_results_without_observation" $ withRig defaultAssistant $ \rig -> do
    let priorAssistant =
          assistant
            "toolUse"
            (Just [toolCall "one" "workspace_read" (Object [("path", String "a")]), toolCall "two" "workspace_test" (Object [])])
            []
    payload <- throwsLeft (mkPiModelPhaseContinuationPayloadV1 (encoded (Array [priorAssistant])))
    modifyIORef' rig.ops.continuations (Map.insert "prior" payload)
    let results =
          [ result "one" True (Object [("content", String "a")]) Nothing
          , result "two" False Null (Just (Object [("category", String "unknown"), ("detail", String "bounded failure")]))
          ]
    void (invoke rig (state 2 (Just "old-output") (Just "prior") results))
    [frame] <- readIORef rig.frames
    member "observation" frame `shouldBe` Null
    map (member "id") (items (member "results" frame)) `shouldBe` [String "one", String "two"]
    map (member "method") (items (member "results" frame)) `shouldBe` [String "workspace_read", String "workspace_test"]
    Just (_, continuation) <- Map.lookup "operation" <$> publicationsOf rig
    let transcript = items (load continuation.transcriptJson)
    map (member "role") transcript `shouldBe` map String ["assistant", "toolResult", "toolResult", "assistant"]
    case map (member "text") (concatMap (items . member "content") (take 1 (drop 1 transcript))) of
      String text : _ -> case load (TE.encodeUtf8 text) of
        Object members -> map fst members `shouldMatchList` ["version", "ok", "data", "error"]
        other -> expectationFailure ("tool result text is not an object: " <> show other)
      other -> expectationFailure ("tool result has no text: " <> show other)
    forM_ (take 2 (drop 1 transcript)) $ \message ->
      encoded message `shouldNotSatisfy` B.isInfixOf "attachment"

  it "test_result_identity_mismatch_fails_before_authority_use" $ withRig defaultAssistant $ \rig -> do
    let priorAssistant = assistant "toolUse" (Just [toolCall "expected" "workspace_read" (Object [("path", String "a")])]) []
    payload <- throwsLeft (mkPiModelPhaseContinuationPayloadV1 (encoded (Array [priorAssistant])))
    modifyIORef' rig.ops.continuations (Map.insert "prior" payload)
    protocolError "result-mismatch" $
      invoke rig (state 2 (Just "old-output") (Just "prior") [result "wrong" True (Object [("content", String "a")]) Nothing])
    eventsOf rig `shouldReturn` ["load"]

  let failures =
        [ ("client", "helper-protocol", \rig -> modifyIORef' rig.plan (\p -> p {planError = Just "helper-protocol"}))
        , ("client-clean", "cleanup-unverified", \rig -> modifyIORef' rig.plan (\p -> p {planClean = False}))
        , ("admit", "custody-admission-mismatch", \rig -> writeIORef rig.custodyFlags.admit False)
        , ("release", "cleanup-unverified", \rig -> writeIORef rig.custodyFlags.clean False)
        , ("release-raises", "cleanup-unverified", \rig -> writeIORef rig.custodyFlags.releaseRaises True)
        , ("publish", "runtime-failed", \rig -> writeIORef rig.ops.publishRaises True)
        ]
  forM_ failures $ \(failure, code, arm) ->
    it ("test_failures_release_authority_and_publish_nothing[" <> failure <> "-" <> T.unpack code <> "]") $
      withRig defaultAssistant $ \rig -> do
        arm rig
        protocolError code (invoke rig initial)
        eventsOf rig >>= (`shouldSatisfy` elem "release")
        publicationsOf rig `shouldReturn` Map.empty
        listDirectory rig.runtimeRoot `shouldReturn` []

  let mismatches =
        [ ("mode", "custody-materialization-mismatch", \rig -> writeIORef rig.custodyFlags.mode LeaseRefresh)
        , ("authority", "custody-state-mismatch", \rig -> modifyIORef' rig.custodyFlags.authorityEpoch (+ 1))
        , ("version", "custody-state-mismatch", \rig -> modifyIORef' rig.custodyFlags.baseVersion (+ 1))
        ]
  forM_ mismatches $ \(mismatch, code, arm) ->
    it ("test_materialization_fence_mismatch_releases_without_provider_use[" <> mismatch <> "]") $
      withRig defaultAssistant $ \rig -> do
        arm rig
        protocolError code (invoke rig initial)
        eventsOf rig `shouldReturn` ["materialize", "release"]
        publicationsOf rig `shouldReturn` Map.empty

  forM_ [("revoked", StatusRevoked), ("reauthorization_required", StatusReauthorizationRequired)] $ \(label, status) ->
    it ("test_not_ready_connection_is_rejected_at_construction[" <> label <> "]") $ withRig defaultAssistant $ \rig -> do
      let connection = ConnectionView rig.connection.identity status 3 4 Nothing
      raises
        (newPiModelPhaseAdapter rig.config connection rig.custody rig.operations "node" (Just "/fake/pi/index.js") (Just rig.factory))
        ValueError
        "ready api-key"

  it "test_private_load_failure_and_state_mismatch_are_sanitized_pre_authority" $ withRig defaultAssistant $ \rig -> do
    writeIORef rig.ops.loadRaises True
    refusedWithout "continuation-load-failed" "private load diagnostic" (invoke rig (state 1 (Just "old-output") (Just "missing") []))
    eventsOf rig `shouldReturn` ["load"]
    modifyModelPhaseConfig rig.adapter (\c -> c {episodeId = "other"})
    protocolError "state-mismatch" (invoke rig initial)
    eventsOf rig `shouldReturn` ["load"]

  it "test_stale_activity_claim_rejects_before_authority" $ withRig defaultAssistant $ \rig -> do
    let stale _ = throwIO (userError "private claim diagnostic")
    refusedWithout "activity-stale" "private claim diagnostic" (invokeRaw rig initial stale)
    eventsOf rig `shouldReturn` []

  it "test_malformed_candidate_and_proposal_overflow_publish_nothing" $ withRig defaultAssistant $ \rig -> do
    modifyIORef' rig.plan (\p -> p {candidate = Just PhaseCandidate {assistant = encoded defaultAssistant, transcript = "[]"}})
    protocolError "transcript-mismatch" (invoke rig initial)
    publicationsOf rig `shouldReturn` Map.empty
    let calls = [toolCall ("call-" <> T.pack (show index)) "workspace_test" (Object []) | index <- [0 .. maxProposals]]
    protocolError "proposal-overflow" (throwsLeft (validateFresh (assistant "toolUse" (Just calls) [])))

  it "test_duplicate_tool_call_identity_is_rejected_before_publication" $
    withRig (assistant "toolUse" (Just [toolCall "duplicate" "workspace_test" (Object []), toolCall "duplicate" "workspace_test" (Object [])]) []) $ \rig -> do
      protocolError "malformed-proposal" (invoke rig initial)
      publicationsOf rig `shouldReturn` Map.empty

  it "test_activity_adapter_drives_the_real_static_net_to_completion" $ withRig defaultAssistant $ \rig -> do
    store <- inMemoryHistoryStore
    port <- inlineDispatch <$> newInlineDispatch (Map.fromList [(modelPhaseActivity, modelPhaseAdapterActivity rig.adapter)])
    engine <-
      Engine.create
        agentNet
        "model-phase-net"
        store
        port
        (agentNetOptions Engine.defaultEngineOptions {Engine.marking = initialMarking initial})
    let loop = Engine.advance engine >>= \outcome -> when outcome.ready loop
    loop
    marking <- Engine.marking engine
    case toList (placeTokens done marking) of
      token : _ -> member "code" token.payload `shouldBe` String "completed"
      [] -> expectationFailure "no terminal token"
    Map.size <$> publicationsOf rig `shouldReturn` 1

-- | A protocol refusal with @code@ that carries none of the private
-- diagnostic.
refusedWithout :: Text -> Text -> IO a -> Expectation
refusedWithout code diagnostic action =
  try action >>= \case
    Left (e :: AgenticusError) -> do
      e.errorClass `shouldBe` RuntimeProtocolError
      e.errorMessage `shouldSatisfy` T.isInfixOf code
      e.errorMessage `shouldNotSatisfy` T.isInfixOf diagnostic
    Right _ -> expectationFailure ("expected " <> T.unpack code)

-- ---------------------------------------------------------------------------
-- The subprocess client

requireNode :: IO FilePath
requireNode = findExecutable "node" >>= maybe (expectationFailure "node is required" >> error "unreachable") pure

newPrivateRoot :: FilePath -> IO FilePath
newPrivateRoot tmp = do
  let root = tmp </> "private"
  createDirectory root
  setFileMode root 0o700
  pure root

subprocessSpecs :: Spec
subprocessSpecs = do
  let frames' =
        [ ( "process.stdout.write('{\"type\":\"complete\",\"assistant\":\"e30\",\"transcript\":\"W10=\"}\\n')"
          , "process.stdout.write('{\"type\":\"complete\",\"assistant\":\"e30\",\"transcript\":\"W10=\"}\\\\n')"
          , "malformed-complete"
          )
        , ( "process.stdout.write('{\"type\":\"complete\",\"assistant\":\"e30=\",\"transcript\":\"W10=\"}\\n{\"type\":\"complete\",\"assistant\":\"e30=\",\"transcript\":\"W10=\"}\\n')"
          , "process.stdout.write('{\"type\":\"complete\",\"assistant\":\"e30=\",\"transcript\":\"W10=\"}\\\\n{\"type\":\"complete\",\"assistant\":\"e30=\",\"transcript\":\"W10=\"}\\\\n')"
          , "helper-protocol"
          )
        , ( "process.stdout.write('{\"type\":\"complete\",\"assistant\":\"e30=\",\"assistant\":\"e30=\",\"transcript\":\"W10=\"}\\n')"
          , "process.stdout.write('{\"type\":\"complete\",\"assistant\":\"e30=\",\"assistant\":\"e30=\",\"transcript\":\"W10=\"}\\\\n')"
          , "malformed-frame"
          )
        ]
  forM_ frames' $ \(body, label, code) ->
    it ("test_subprocess_rejects_duplicate_post_terminal_and_noncanonical_frames[" <> label <> "-" <> T.unpack code <> "]") $
      withTemp $ \tmp -> do
        node <- requireNode
        let helper = tmp </> "bad.mjs"
        B.writeFile helper (TE.encodeUtf8 ("process.stdin.resume();process.stdin.on('end',()=>{" <> T.pack body <> ";});\n"))
        root <- newPrivateRoot tmp
        client <- newPhaseSubprocessClient node helper "/unused" root
        protocolError code ((phaseSubprocessClient client).run (Object []) 1 (pure ()))
        (phaseSubprocessClient client).close `shouldReturn` True

  it "test_subprocess_rejects_a_relative_node_before_launch" $ withTemp $ \tmp -> do
    root <- newPrivateRoot tmp
    protocolError "runtime-not-ready" (newPhaseSubprocessClient "node" (tmp </> "helper.mjs") "/unused" root)

  it "test_subprocess_deadline_kills_the_helper_group_and_discards_stderr" $ withTemp $ \tmp -> do
    node <- requireNode
    let helper = tmp </> "slow.mjs"
    B.writeFile helper "process.stderr.write('PRIVATE PROVIDER DIAGNOSTIC');setTimeout(()=>{},10000);\n"
    root <- newPrivateRoot tmp
    client <- newPhaseSubprocessClient node helper "/unused" root
    refusedWithout "deadline-exceeded" "PRIVATE" $
      (phaseSubprocessClient client).run (Object [("blob", String (T.replicate 1000000 "x"))]) 0.03 (pure ())
    (phaseSubprocessClient client).close `shouldReturn` True
    phaseSubprocessExited client `shouldReturn` True

  it "test_subprocess_heartbeat_refusal_stops_before_the_wall_deadline" $ withTemp $ \tmp -> do
    node <- requireNode
    let helper = tmp </> "slow.mjs"
    B.writeFile helper "process.stdin.resume();setTimeout(()=>{},10000);\n"
    root <- newPrivateRoot tmp
    client <- newPhaseSubprocessClient node helper "/unused" root
    refusedWithout "activity-stale" "private claim diagnostic" $
      (phaseSubprocessClient client).run (Object []) 0.1 (throwIO (userError "private claim diagnostic"))
    (phaseSubprocessClient client).close `shouldReturn` True

-- ---------------------------------------------------------------------------
-- The verbatim helper under real node

realHelperSpecs :: Spec
realHelperSpecs = do
  it "test_real_helper_runs_one_public_stream_with_declarations_and_no_tool_executor" $ withRig defaultAssistant $ \rig -> do
    useRealHelper rig
    settlement <- invoke rig initial
    settlement.stop `shouldBe` Stop
    Just (output, _) <- Map.lookup "operation" <$> publicationsOf rig
    firstText (load output.assistantJson) `shouldBe` String "calls=1;roles=user;declarations=5;prompt=9"
    source <- piModelPhaseHelperPath >>= B.readFile
    forM_ ["runAgentLoop", "AgentSession", "shouldStopAfterTurn", ".execute"] $ \name ->
      source `shouldNotSatisfy` B.isInfixOf name

  it "test_real_helper_accepts_bounded_multiline_observation" $ withTemp $ \tmp -> do
    let observation = "line one\n" <> T.replicate 300 "x"
    rig <- newRig tmp defaultAssistant observation
    useRealHelper rig
    void (invoke rig initial)
    Just (output, _) <- Map.lookup "operation" <$> publicationsOf rig
    case firstText (load output.assistantJson) of
      String text -> text `shouldSatisfy` T.isSuffixOf ("prompt=" <> T.pack (show (T.length observation)))
      other -> expectationFailure ("no text block: " <> show other)

  it "test_real_subprocess_requires_the_exact_installed_probe_before_authority" $ withRig defaultAssistant $ \rig -> do
    useRealHelper rig
    setModelPhaseFactory rig.adapter subprocessPhaseFactory
    protocolError "runtime-not-ready" (invoke rig initial)
    eventsOf rig `shouldReturn` []

  it "test_helper_syntax_and_exact_hands_bounds" $ do
    helper <- piModelPhaseHelperPath
    checked <- runBounded (proc "node" ["--check", helper])
    fmap (\(code, _, _) -> code) checked `shouldBe` Just ExitSuccess
    source <- B.readFile helper
    forM_ ["maxItems:4", "maxLength:64", "maxLength:8", "maxLength:1024"] $ \bound ->
      source `shouldSatisfy` B.isInfixOf bound

  it "test_exact_installed_model_phase_probe" $ withTemp $ \tmp -> do
    let prefix = "/tmp/petrus-pi-a2-probe"
        root = prefix </> "node_modules/@earendil-works/pi-coding-agent"
        node = prefix </> "node_modules/node/bin/node"
    installed <- (&&) <$> doesFileExist node <*> doesDirectoryExist root
    if not installed
      then pendingWith "exact Pi qualification packages required"
      else do
        createDirectory (tmp </> "probe")
        rig <- newRig (tmp </> "probe") defaultAssistant "Continue."
        setModelPhaseNode rig.adapter node
        probeModelPhase rig.adapter root `shouldReturn` True
        modelPhaseNode rig.adapter >>= (`shouldSatisfy` ("/" `T.isPrefixOf`) . T.pack)
        helper <- piModelPhaseHelperPath
        let environment = [("HOME", tmp), ("PATH", prefix </> "node_modules/node/bin"), ("LANG", "C.UTF-8"), ("LC_ALL", "C.UTF-8")]
        Just (code, out, err) <- runBounded (proc node [helper, root </> "dist/index.js", "--test-probe"]) {env = Just environment}
        (code, err) `shouldBe` (ExitSuccess, "")
        load (B.dropWhileEnd (== 10) out)
          `shouldBe` Object
            [ ("type", String "test-probe")
            , ("ok", Bool True)
            , ("stream_calls", Int 1)
            , ("convert", Bool True)
            , ("tool_execute", Bool False)
            , ("network", Bool False)
            , ("complete", Bool True)
            ]

-- | @private["content"][0]["text"]@.
firstText :: Json -> Json
firstText value = case items (member "content" value) of
  block : _ -> member "text" block
  [] -> Null
