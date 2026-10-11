-- | Port of @tests/petrus/agenticus/runtime/test_pi.py@. Labels are the
-- reference's pytest ids.
module Petrus.Agenticus.Runtime.PiSpec (spec) where

import Control.Concurrent.MVar
import Control.Exception (finally, try)
import Control.Monad (forM_, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding (BindingSettlement (..))
import Petrus.Agenticus.Attachment.Episode (AttachmentSettlement (..), EpisodeAttachment, episodeDeadline)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor (..), DescriptorIdentity (..), DescriptorKind (..), capabilityDescriptor, descriptorIdentity)
import Petrus.Agenticus.Connection.Custody
  ( AttachmentFence (..)
  , ConnectionIdentity (..)
  , ConnectionStatus (..)
  , ConnectionView (..)
  , LeaseMode (..)
  , Materialization (..)
  , PublicationResult (..)
  , agentConnectionCustody
  , authorize
  , closeCustody
  , enrollHost
  , lookupConnection
  , mkConnectionIdentity
  , newOpaqueState
  )
import Petrus.Agenticus.Connection.Custody qualified as Custody
import Petrus.Agenticus.Connection.Materialization (CleanupEvidence (..), newPrivateFileMaterializer, replaceMaterialized)
import Petrus.Agenticus.Connection.Storage (openSqliteConnectionStorage)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract (RejectionCategory (..), ToolMethod (..), allToolMethods, toolMethodText, toolResultToData)
import Petrus.Agenticus.Hands.Gateway (CallEvidence (..), GatewayCounters (..), counters, evidence, gatewayAttachmentId)
import Petrus.Agenticus.Hands.Grants (closeGrant, grantSpec, openGrant)
import Petrus.Agenticus.Program.Descriptor (AgentProgramDescriptor (..), ProgramOwnership (..))
import Petrus.Agenticus.Runtime.Custody (HostMaterialization (..))
import Petrus.Agenticus.Runtime.Internal.Process (spawnPiped)
import Petrus.Agenticus.Runtime.Operation (RuntimeCleanupDisposition (..), RuntimeOperation (..), RuntimeOperationCleanup (..), cleanupVerified)
import Petrus.Agenticus.Runtime.Pi.Internal
import Petrus.Agenticus.Runtime.PiRecovery
import Petrus.Agenticus.Runtime.PiSupport
import Petrus.Agenticus.Runtime.Profiles (piNativeA2Local, piNativeA4E2b, piNativeA4Gondolin)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..))
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Directory (canonicalizePath, createDirectory, findExecutable, removeDirectoryRecursive)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose)
import System.Posix.Files (setFileMode)
import System.Posix.IO (FdOption (..), OpenMode (..), closeFd, defaultFileFlags, dupTo, handleToFd, openFd, queryFdOption)
import System.Posix.Types (Fd (..))
import System.Process (getPid, readProcessWithExitCode, waitForProcess)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "test_pi" $ do
  descriptorSpecs
  payloadSpecs
  adapterSpecs
  helperSpecs
  a4Specs
  failureSpecs
  subscriptionSpecs
  lifecycleSpecs
  recoverySpecs
  surrogateSpecs
  spawnSpecs

-- ---------------------------------------------------------------------------
-- Helpers

keyText :: Text
keyText = TE.decodeUtf8 key

digest64 :: Text
digest64 = T.replicate 64 "d"

startWait :: Rig -> PiRuntimeInvocation -> IO RuntimeTurnSettlement
startWait rig inv = startPi rig.adapter inv >>= \op -> waitPiOperation op (Just 3)

closeDisposition :: PiOperation -> IO RuntimeCleanupDisposition
closeDisposition op = (.disposition) <$> closePiOperation op

settledVerified :: EpisodeAttachment -> IO Bool
settledVerified a = (.settlement.verified) <$> Episode.settle a 30

kinds :: Rig -> IO [Text]
kinds rig = recordedKinds rig.custody

noRefs :: RuntimeTurnSettlement -> Expectation
noRefs r = (r.outputReference, r.continuationReference) `shouldBe` (Nothing, Nothing)

emptyRoot :: Rig -> Expectation
emptyRoot rig = runtimeRootEntries rig `shouldReturn` []

-- | @dataclasses.replace(invocation, ...)@ over the fields tests change.
reinvoke :: PiRuntimeInvocation -> Text -> ConnectionView -> Integer -> PiRuntimeInvocation
reinvoke i p view epoch =
  PiRuntimeInvocation
    { operationId = i.operationId
    , episodeId = i.episodeId
    , turnId = i.turnId
    , prompt = p
    , connection = view
    , attachment = i.attachment
    , gateway = i.gateway
    , grantEpoch = epoch
    , continuation = i.continuation
    }

withPrompt :: PiRuntimeInvocation -> Text -> PiRuntimeInvocation
withPrompt i p = reinvoke i p i.connection i.grantEpoch

withIdentity :: PiRuntimeInvocation -> ConnectionIdentity -> PiRuntimeInvocation
withIdentity i identity =
  reinvoke
    i
    i.prompt
    ConnectionView
      { identity
      , status = i.connection.status
      , authorityEpoch = i.connection.authorityEpoch
      , stateVersion = i.connection.stateVersion
      , stateDigest = i.connection.stateDigest
      }
    i.grantEpoch

reidentify :: ConnectionIdentity -> Text -> Text -> ConnectionIdentity
reidentify c connectionId profile =
  ok (mkConnectionIdentity connectionId c.provider c.accountFingerprint profile)

-- | Run a helper test with Node, started once beforehand.
--
-- The helper tests bound one protocol run by the reference's wall-clock
-- budgets (the 3 s run deadline, the 5 s Episode deadline), which are
-- already running while the helper process loads. The first Node start in a
-- CI job is a cold one (binary and builtins paged in from disk): on an idle
-- runner it costs ~150 ms against ~20 ms warm, but while the other suites run
-- alongside it has taken over 2 s, and once more than the whole 3 s. That
-- start-up is not what these tests bound, so it is paid here, outside them.
withNode :: (FilePath -> IO ()) -> IO ()
withNode body = findExecutable "node" >>= maybe (expectationFailure "node is not on PATH: the private helper protocol test runs the helper under the real Node") (\node -> warm node >> body node)
  where
    warm node = do
      (code, _, _) <- readProcessWithExitCode node ["-e", ""] ""
      when (code /= ExitSuccess) $ expectationFailure "node did not start"

privateDirectory :: FilePath -> IO ()
privateDirectory path = createDirectory path >> setFileMode path 0o700

operationRoot :: Rig -> FilePath -> IO FilePath
operationRoot rig name = pure ((rigConfig rig).runtimeRoot </> name)

helperArgs
  :: Rig -> FilePath -> Text -> FilePath -> PiRuntimeInvocation -> Maybe PiContinuationPayloadV1 -> Maybe Text -> Maybe ByteString -> Maybe Text -> IO PiHelperArgs
helperArgs rig node sdk privateRoot inv prior apiKey nativeAuth extension = do
  let config = rigConfig rig
  pure
    PiHelperArgs
      { node
      , sdkEntrypoint = sdk
      , privateRoot
      , config = config {cancellationGrace = 2}
      , invocation = inv
      , prior
      , apiKey
      , nativeAuth
      , extension
      }

-- | @framed_tool_client(...)@.
framedClient :: SubprocessOptions -> FilePath -> FilePath -> FilePath -> Rig -> PiRuntimeInvocation -> Maybe PiContinuationPayloadV1 -> IO SubprocessClient
framedClient options node sdk privateRoot rig inv prior = do
  privateDirectory privateRoot
  helper <- piHelperPath
  helperArgs rig node (T.pack sdk) privateRoot inv prior (Just keyText) Nothing Nothing >>= newSubprocessClientWith options helper

runFor :: SubprocessClient -> PiRuntimeInvocation -> IO PiHelperResult
runFor c inv = do
  now <- getMonotonicTime
  (subprocessClient c).run inv.gateway inv (pure True) (now + 3)

closeClient :: SubprocessClient -> IO Bool
closeClient c = (subprocessClient c).close

framedSdk :: IO Text
framedSdk = fixture "framed_tool_sdk.mjs"

writeText :: FilePath -> Text -> IO ()
writeText path = B.writeFile path . TE.encodeUtf8

signalWait :: MVar () -> MVar () -> IO ()
signalWait started released = do
  void (tryPutMVar started ())
  void (timeout 2000000 (readMVar released))

awaitSignal :: MVar () -> Expectation
awaitSignal v = timeout 2000000 (readMVar v) `shouldReturn` Just ()

-- | The reference's stalled @_binding_current@: every call after the first
-- signals and waits for release.
stallBindingCurrent :: IO (PiAdapterHooks, MVar (), MVar ())
stallBindingCurrent = do
  started <- newEmptyMVar
  released <- newEmptyMVar
  calls <- newIORef (0 :: Int)
  let stalled original current = do
        n <- atomicModifyIORef' calls (\c -> (c + 1, c + 1))
        when (n > 1) (signalWait started released)
        original current
  pure (PiAdapterHooks (Just stalled) Nothing Nothing, started, released)

shouldNotContain' :: Text -> [Text] -> Expectation
shouldNotContain' rendered secrets = forM_ secrets $ \s -> (s, s `T.isInfixOf` rendered) `shouldBe` (s, False)

-- ---------------------------------------------------------------------------
-- Descriptors and payloads

descriptorSpecs :: Spec
descriptorSpecs = do
  it "test_descriptors_pins_and_reprs_are_exact_and_opaque" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions
    inv <- invocation rig "opaque"
    let payload = ok (mkPiContinuationPayloadV1 sessionId digest64 (session sessionId [Object [("body", String sessionCanary)]]))
    (piProgram.ownership, piProgram.ownsSteering) `shouldBe` (HarnessOwned, False)
    (piSdkVersion, piAiVersion) `shouldBe` ("0.83.0", "0.83.0")
    piNativeA2Local.identity.name `shouldBe` "pi.native.a2.local"
    piApiKeyCatalog `shouldBe` [("anthropic", "claude-sonnet-4-5"), ("openrouter", "anthropic/claude-sonnet-4.5"), ("openai", "gpt-5.6-sol")]
    piSubscriptionCatalog `shouldBe` [("anthropic", "claude-sonnet-4-5"), ("openai-codex", "gpt-5.6-sol")]
    piCcPatchSubscriptionCatalog `shouldBe` [("anthropic", "claude-sonnet-4-5")]
    piCcPatchVersion `shouldBe` "1.0.1"
    piCcPatchSourceCommit `shouldBe` "1891a39e3e1c61e37f950159fdc51de1ecffce84"
    piSubscriptionConnectionCapabilities.offers `shouldBe` Set.fromList ["connection.pi-compatible"]
    piCcPatchConnectionCapabilities.offers `shouldBe` Set.fromList ["connection.pi-compatible"]
    let config = rigConfig rig
    adapterText <- renderPiRuntimeAdapter rig.adapter
    let rendered = T.pack (show payload) <> renderPiRuntimeConfig config <> renderPiRuntimeInvocation inv <> adapterText
    rendered `shouldNotContain'` [sessionId, sessionCanary, prompt, "pi-access-canary", "pi-refresh-canary", T.pack tmp]

  forM_
    [ ("local", piNativeA2Local, "pi.collocated", "motus.local", ["runtime.cancel", "runtime.continue", "runtime.local", "runtime.harness-owned"], "descriptor0", "capabilities0")
    , ("gondolin", piNativeA4Gondolin, "pi.capability-scoped", "motus.gondolin", ["runtime.cancel", "runtime.continue", "runtime.split", "runtime.harness-owned"], "descriptor1", "capabilities1")
    , ("e2b", piNativeA4E2b, "pi.capability-scoped", "motus.e2b", ["runtime.cancel", "runtime.continue", "runtime.split", "runtime.harness-owned"], "descriptor2", "capabilities2")
    ]
    $ \(profile, descriptor, handsName, territoryName, capabilities, descriptorId, capabilitiesId) ->
      it
        ( "test_native_territory_profile_selects_exact_descriptor_and_capabilities["
            <> T.unpack (T.intercalate "-" [profile, descriptorId, handsName, territoryName, capabilitiesId])
            <> "]"
        )
        $ withTemp
        $ \tmp -> do
          rig <- newRig (tmp </> T.unpack profile) rigOptions {optTerritory = profile}
          adapterDescriptor rig.adapter `shouldBe` descriptor
          (adapterHands rig.adapter).identity.name `shouldBe` handsName
          (adapterTerritory rig.adapter).identity.name `shouldBe` territoryName
          adapterRuntimeCapabilities rig.adapter `shouldBe` Set.fromList capabilities
          rendered <- renderPiRuntimeAdapter rig.adapter
          rendered `shouldSatisfy` T.isInfixOf ("territory_profile='" <> profile <> "'")

  it "test_native_territory_profile_defaults_local_and_rejects_unknown" $ withTemp $ \tmp -> do
    let working = tmp </> "working"
        private = tmp </> "private"
    createDirectory working
    privateDirectory private
    (piRuntimeConfig "provider" "model" working private).territoryProfile `shouldBe` "local"
    let defaults = piRuntimeConfig "provider" "model" working private
    raises (newPiRuntimeConfig defaults {hostId = defaults.hostId, territoryProfile = "docker"}) ValueError "territory_profile"

payloadSpecs :: Spec
payloadSpecs = do
  forM_ ["", "not-uuid", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"] $ \identity ->
    it ("test_payload_rejects_noncanonical_identity[" <> T.unpack identity <> "]") $
      raises (either throwIOE pure (mkPiContinuationPayloadV1 identity digest64 (session sessionId []))) ValueError "session identity"

  forM_
    [ ("{}", "{}")
    , ("{}\\n", "{}\n")
    , ( "{\"type\":\"session\",\"version\":3,\"id\":\"11111111-1111-4111-8111-111111111111\",\"x\":NaN}\\n"
      , "{\"type\":\"session\",\"version\":3,\"id\":\"11111111-1111-4111-8111-111111111111\",\"x\":NaN}\n"
      )
    , ( "{\"type\":\"session\",\"version\":3,\"id\":\"11111111-1111-4111-8111-111111111111\"}\\n{\"type\":\"session\",\"version\":3,\"id\":\"11111111-1111-4111-8111-111111111111\"}\\n"
      , session sessionId [] <> session sessionId []
      )
    ]
    $ \(label, body) ->
      it ("test_native_jsonl_is_complete_strict_and_has_one_matching_header[" <> label <> "]") $
        raisesValueLike (mkPiContinuationPayloadV1 sessionId digest64 body)

  it "test_native_jsonl_is_preserved_without_rewriting" $ do
    let body = "{ \"type\":\"session\", \"version\":3, \"id\":\"11111111-1111-4111-8111-111111111111\" }\n"
    (ok (mkPiContinuationPayloadV1 sessionId digest64 body)).sessionJsonl `shouldBe` body

  let canonical = b64Encode auth
  forM_
    [ (canonical <> "=", B.length auth + 1)
    , (b64Encode (auth <> "\0"), B.length auth + 1)
    , (canonical, B.length auth - 1)
    ]
    $ \(encoded, bound) ->
      it ("test_native_auth_protocol_rejects_noncanonical_or_oversized_frames[" <> T.unpack encoded <> "]") $
        raisesValueLike (decodeNativeAuth (String encoded) "anthropic" bound)

throwIOE :: AgenticusError -> IO a
throwIOE e = throwAgenticus e.errorClass e.errorMessage

-- ---------------------------------------------------------------------------
-- The scripted adapter

adapterSpecs :: Spec
adapterSpecs = do
  it "test_fresh_success_has_exact_custody_and_private_invocation" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions
    inv <- invocation rig "first"
    op <- startPi rig.adapter inv
    r <- waitPiOperation op (Just 3)
    (r.outcome, r.acceptedAppends, r.outputReference, r.continuationReference)
      `shouldBe` (TurnCompleted, 1, Just "pi-turn-first", Just "pi-continuation-first")
    readIORef rig.custody.records
      `shouldReturn` [("materialize", "first.materialize"), ("admit", "first.admit"), ("release", "first.release")]
    calls <- readIORef rig.factory.calls
    case calls of
      call : _ -> do
        (call.config.provider, call.config.model, call.apiKey) `shouldBe` ("provider", "model", Just keyText)
        call.prior `shouldBe` Nothing
      [] -> expectationFailure "no helper was created"
    sort (map (toolMethodText . fst) piToolSchemas) `shouldBe` sort (map toolMethodText allToolMethods)
    forM_ piToolSchemas $ \(method, schema) ->
      (toolMethodText method, additionalPropertiesFalse schema) `shouldBe` (toolMethodText method, True)
    emptyRoot rig
    closeDisposition op `shouldReturn` RuntimeCleanupClean

additionalPropertiesFalse :: Json -> Bool
additionalPropertiesFalse = \case
  Object members | Just (Bool False) <- lookup "additionalProperties" members -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- The private Node helper

helperSpecs :: Spec
helperSpecs = do
  forM_ ["local", "gondolin", "e2b"] $ \profile ->
    it ("test_private_node_helper_routes_the_provider_tool_identity_through_hands[" <> T.unpack profile <> "]") $
      withNode $ \node -> withTemp $ \tmp -> do
        rig <- newRig tmp rigOptions {optTerritory = profile}
        inv <- invocation rig "helper-protocol"
        privateRoot <- operationRoot rig "protocol-operation"
        let sdk = tmp </> "fake-pi-sdk.mjs"
        framedSdk >>= writeText sdk
        client <- framedClient subprocessOptions node sdk privateRoot rig inv Nothing
        result <- runFor client inv
        (isJust result.candidate, result.nativeAuth, result.code) `shouldBe` (True, Nothing, "turn-completed")
        forM_ result.candidate $ \candidate -> do
          candidate.text `shouldBe` "protocol-answer"
          candidate.sessionJsonl `shouldSatisfy` B.isPrefixOf ("{\"type\":\"session\",\"version\":3,\"id\":\"" <> TE.encodeUtf8 candidate.sessionId)
          candidate.sessionJsonl `shouldSatisfy` B.isInfixOf "\"toolCallId\":\"provider-tool-call\""
          forM_ ["\"call_id\"", TE.encodeUtf8 (Episode.episodeAttachmentId inv.attachment), "\"attachment_id\"", "\"epoch\""] $ \custody ->
            (custody, custody `B.isInfixOf` candidate.sessionJsonl) `shouldBe` (custody, False)
        calls <- evidence inv.gateway
        map (\e -> (e.callId, e.method)) calls `shouldBe` [("provider-tool-call", Just WorkspaceRead)]
        ((.adapterEntries) <$> counters inv.gateway) `shouldReturn` 1
        closeClient client `shouldReturn` True
        removeDirectoryRecursive privateRoot

  forM_
    [ ([WorkspaceRead, WorkspaceSearch], False, "capabilities0")
    , ([WorkspaceRead, WorkspaceSearch], True, "capabilities1")
    , ([WorkspaceRead, WorkspaceSearch, WorkspaceWrite], False, "capabilities2")
    , ([WorkspaceRead, WorkspaceSearch, WorkspaceWrite], True, "capabilities3")
    ]
    $ \(capabilities, resumed, label) ->
      it ("test_private_node_helper_advertises_only_the_fresh_or_resumed_operations_current_grant[" <> label <> "-" <> show resumed <> "]") $
        withNode $ \node -> withTemp $ \tmp -> do
          rig <- newRig tmp rigOptions
          inv <- (.invocation) <$> invoke rig "filtered-tools" invocationOptions {invCapabilities = Just capabilities}
          privateRoot <- operationRoot rig "filtered-tools-operation"
          let sdk = tmp </> "filtered-tools-sdk.mjs"
              expected = T.intercalate "," (map toolMethodText capabilities)
              marker = "  const state={messages:[]}; const listeners=[];"
          source <- framedSdk
          writeText sdk $
            T.replace
              marker
              ("  if(options.customTools.map(value=>value.name).join()!=='" <> expected <> "') throw new Error('advertisement');\n" <> marker)
              source
          let config = rigConfig rig
          let prior =
                if resumed
                  then Just (ok (mkPiContinuationPayloadV1 sessionId (workingBinding config.workingDirectory) (session sessionId [])))
                  else Nothing
          client <- framedClient subprocessOptions node sdk privateRoot rig inv prior
          case lookup "schemas" (subprocessStartFrame client) of
            Just (Object schemas) -> map fst schemas `shouldBe` map toolMethodText capabilities
            _ -> expectationFailure "start frame has no schema object"
          result <- runFor client inv
          isJust result.candidate `shouldBe` True
          when resumed $ fmap (.sessionId) result.candidate `shouldBe` Just sessionId
          fmap (.method) . take 1 <$> evidence inv.gateway `shouldReturn` [Just WorkspaceRead]
          closeClient client `shouldReturn` True
          removeDirectoryRecursive privateRoot

  it "test_private_client_keeps_gateway_authoritative_for_a_forged_known_tool" $ withNode $ \node -> withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions
    inv <- (.invocation) <$> invoke rig "forged-known-tool" invocationOptions {invCapabilities = Just [WorkspaceRead], invMaxCalls = 1}
    privateRoot <- operationRoot rig "forged-known-tool-operation"
    privateDirectory privateRoot
    let helper = tmp </> "forged-known-tool-helper.mjs"
    fixture "forged_known_tool_helper.mjs" >>= writeText helper
    client <- helperArgs rig node "/ignored" privateRoot inv Nothing (Just keyText) Nothing Nothing >>= newSubprocessClient helper
    result <- runFor client inv
    fmap (.text) result.candidate `shouldBe` Just "answer"
    calls <- evidence inv.gateway
    map (\e -> (e.method, e.ok, e.category)) calls
      `shouldBe` [(Just WorkspaceTest, False, Just CategoryCapability), (Just WorkspaceRead, True, Nothing)]
    ((.adapterEntries) <$> counters inv.gateway) `shouldReturn` 1
    closeClient client `shouldReturn` True
    removeDirectoryRecursive privateRoot

  it "test_private_client_keeps_unknown_tools_outside_the_closed_protocol" $ withNode $ \node -> withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions
    inv <- (.invocation) <$> invoke rig "forged-unknown-tool" invocationOptions {invCapabilities = Just [WorkspaceRead]}
    privateRoot <- operationRoot rig "forged-unknown-tool-operation"
    privateDirectory privateRoot
    let helper = tmp </> "forged-unknown-tool-helper.mjs"
    fixture "forged_unknown_tool_helper.mjs" >>= writeText helper
    client <- helperArgs rig node "/ignored" privateRoot inv Nothing (Just keyText) Nothing Nothing >>= newSubprocessClient helper
    raises (runFor client inv) RuntimeProtocolError "malformed-tool-call"
    evidence inv.gateway `shouldReturn` []
    closeClient client `shouldReturn` True
    removeDirectoryRecursive privateRoot

  forM_ [(Object [], "schemas0"), (Object [("future_tool", Object [])], "schemas1")] $ \(schemas, label) ->
    it ("test_private_node_helper_rejects_empty_or_unknown_advertised_tool_sets[" <> label <> "]") $
      withNode $ \node -> withTemp $ \tmp -> do
        rig <- newRig tmp rigOptions
        inv <- invocation rig "invalid-tools"
        privateRoot <- operationRoot rig "invalid-tools-operation"
        let sdk = tmp </> "invalid-tools-sdk.mjs"
        framedSdk >>= writeText sdk
        let replaceSchemas frame = [(name, if name == "schemas" then schemas else value) | (name, value) <- frame]
        client <- framedClient subprocessOptions {adjustStart = replaceSchemas} node sdk privateRoot rig inv Nothing
        raises (runFor client inv) RuntimeProtocolError "protocol-failed"
        evidence inv.gateway `shouldReturn` []
        closeClient client `shouldReturn` True
        removeDirectoryRecursive privateRoot

  it "test_private_node_helper_rejects_custody_bearing_model_result" $ withNode $ \node -> withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions
    invoked <- invoke rig "full-result" invocationOptions
    let inv = invoked.invocation
    privateRoot <- operationRoot rig "full-result-operation"
    let sdk = tmp </> "fake-pi-sdk.mjs"
    framedSdk >>= writeText sdk
    client <- framedClient subprocessOptions {modelData = toolResultToData} node sdk privateRoot rig inv Nothing
    raises (runFor client inv) RuntimeProtocolError "protocol-failed"
    ((.adapterEntries) <$> counters inv.gateway) `shouldReturn` 1
    closeClient client `shouldReturn` True
    removeDirectoryRecursive privateRoot
    settledVerified invoked.attachment `shouldReturn` True

  it "test_framed_native_a4_resume_excludes_episode_custody_from_exact_jsonl_prefix" $ withNode $ \node -> withTemp $ \tmp -> do
    let sdk = tmp </> "fake-pi-sdk.mjs"
    framedSdk >>= writeText sdk
    helper <- piHelperPath
    let realHelper r =
          r {installation = r.installation, node = Just node, sdkEntrypoint = Just (T.pack sdk), factory = Just (subprocessFactory helper)}
    gondolin <- newRig (tmp </> "gondolin") rigOptions {optTerritory = "gondolin", optPrepare = realHelper}
    firstInvoked <- invoke gondolin "g1" invocationOptions
    firstOperation <- startPi gondolin.adapter firstInvoked.invocation
    firstResult <- waitPiOperation firstOperation (Just 3)
    firstReference <- maybe (fail "no continuation") pure firstResult.continuationReference
    closeDisposition firstOperation `shouldReturn` RuntimeCleanupClean
    Just first <- Map.lookup firstReference <$> readIORef gondolin.continuations.values
    emptyRoot gondolin
    settledVerified firstInvoked.attachment `shouldReturn` True

    e2b <- newRig (tmp </> "e2b") rigOptions {optTerritory = "e2b", optPredecessor = Just gondolin, optPrepare = realHelper}
    secondInvoked <- invoke e2b "g2" invocationOptions {invContinuation = Just (claimed firstReference)}
    secondOperation <- startPi e2b.adapter secondInvoked.invocation
    secondResult <- waitPiOperation secondOperation (Just 3)
    secondReference <- maybe (fail "no continuation") pure secondResult.continuationReference
    closeDisposition secondOperation `shouldReturn` RuntimeCleanupClean
    Just second <- Map.lookup secondReference <$> readIORef e2b.continuations.values
    emptyRoot e2b

    second.sessionId `shouldBe` first.sessionId
    second.sessionJsonl `shouldSatisfy` B.isPrefixOf first.sessionJsonl
    B.length second.sessionJsonl `shouldSatisfy` (> B.length first.sessionJsonl)
    let position needle = B.length (fst (B.breakSubstring needle second.sessionJsonl))
    position "\"toolCallId\":\"provider-tool-call\"" `shouldSatisfy` (< position "\"toolCallId\":\"provider-tool-call-resumed\"")
    forM_
      [ "\"call_id\""
      , "\"attachment_id\""
      , TE.encodeUtf8 (Episode.episodeAttachmentId firstInvoked.attachment)
      , TE.encodeUtf8 (Episode.episodeAttachmentId secondInvoked.attachment)
      , "\"epoch\""
      ]
      $ \custody -> (custody, custody `B.isInfixOf` second.sessionJsonl) `shouldBe` (custody, False)
    map (.callId) . take 1 <$> evidence firstInvoked.invocation.gateway `shouldReturn` ["provider-tool-call"]
    map (.callId) . take 1 <$> evidence secondInvoked.invocation.gateway `shouldReturn` ["provider-tool-call-resumed"]
    gatewayAttachmentId firstInvoked.invocation.gateway `shouldBe` Episode.episodeAttachmentId firstInvoked.attachment
    gatewayAttachmentId secondInvoked.invocation.gateway `shouldBe` Episode.episodeAttachmentId secondInvoked.attachment
    settledVerified secondInvoked.attachment `shouldReturn` True

  let subscriptionCases =
        [ ("subscription", "anthropic", "claude-sonnet-4-5", auth, refreshedAuth)
        , ("subscription", "openai-codex", "gpt-5.6-sol", openaiAuth, refreshedOpenaiAuth)
        , ("cc-patch-subscription", "anthropic", "claude-sonnet-4-5", auth, refreshedAuth)
        ]
  forM_ [0o600 :: Int, 0o640] $ \returnedMode -> forM_ [False, True] $ \providerFailure -> forM_ subscriptionCases $ \(profile, provider, model, authority, refreshed) ->
    it
      ( "test_private_node_helper_imports_and_exports_native_subscription_auth["
          <> T.unpack (T.intercalate "-" [T.pack (show returnedMode), T.pack (show providerFailure), profile, provider, model, TE.decodeUtf8 authority, TE.decodeUtf8 refreshed])
          <> "]"
      )
      $ withNode
      $ \node -> withTemp $ \tmp -> do
        rig <- newRig tmp rigOptions {optProfile = profile, optProvider = Just provider}
        inv <- invocation rig "subscription-helper"
        privateRoot <- operationRoot rig "subscription-operation"
        privateDirectory privateRoot
        let sdk = tmp </> "fake-pi-subscription-sdk.mjs"
        source <- fixture "subscription_sdk.mjs"
        writeText sdk $
          foldr
            (uncurry T.replace)
            source
            [ ("__EXPECTED_AUTH__", b64Encode authority)
            , ("__REFRESHED_AUTH__", b64Encode refreshed)
            , ("__PROVIDER__", provider)
            , ("__MODEL__", model)
            , ("__FAIL__", if providerFailure then "true" else "false")
            , ("__MODE__", T.pack (show returnedMode))
            ]
        extension <-
          if profile == "cc-patch-subscription"
            then do
              let path = tmp </> "fake-cc-patch.ts"
              writeText path "export default function() {}"
              Just . T.pack <$> canonicalizePath path
            else pure Nothing
        helper <- piHelperPath
        client <- helperArgs rig node (T.pack sdk) privateRoot inv Nothing Nothing (Just authority) extension >>= newSubprocessClient helper
        if returnedMode /= 0o600
          then do
            raises (runFor client inv) RuntimeProtocolError "protocol-failed"
            closeClient client `shouldReturn` True
            removeDirectoryRecursive privateRoot
          else do
            result <- runFor client inv
            result.nativeAuth `shouldBe` Just refreshed
            result.code `shouldBe` (if providerFailure then "provider-failed" else "turn-completed")
            isNothing result.candidate `shouldBe` providerFailure
            forM_ result.candidate $ \candidate -> candidate.text `shouldBe` "subscription-answer"
            map (.callId) . reverse . take 1 . reverse <$> evidence inv.gateway `shouldReturn` ["subscription-tool-call"]
            closeClient client `shouldReturn` True
            removeDirectoryRecursive privateRoot

  forM_
    [ ("subscription", "send({type:\"complete\",session_id:start.session_id,text:\"answer\",session:body});process.exit(0);")
    , ("subscription", "send({type:\"failed\",code:\"aborted\",auth:start.auth});process.exit(1);")
    , ("api-key", "send({type:\"complete\",session_id:start.session_id,text:\"answer\",session:body,auth:\"e30=\"});process.exit(0);")
    ]
    $ \(profile, terminal) ->
      it ("test_private_client_rejects_auth_on_the_wrong_terminal_frame[" <> T.unpack profile <> "-" <> T.unpack terminal <> "]") $
        withNode $ \node -> withTemp $ \tmp -> do
          rig <- newRig tmp rigOptions {optProfile = profile}
          inv <- invocation rig "wrong-auth-frame"
          privateRoot <- operationRoot rig "wrong-auth-operation"
          privateDirectory privateRoot
          let helper = tmp </> "wrong-auth-helper.mjs"
          fixture "wrong_auth_helper.mjs" >>= writeText helper . T.replace "__TERMINAL__" terminal
          client <-
            helperArgs
              rig
              node
              "/ignored"
              privateRoot
              inv
              Nothing
              (if profile == "api-key" then Just keyText else Nothing)
              (if profile == "subscription" then Just auth else Nothing)
              Nothing
              >>= newSubprocessClient helper
          outcome <- try (runFor client inv)
          case outcome of
            Left (e :: AgenticusError) -> do
              e.errorClass `shouldBe` RuntimeProtocolError
              e.errorMessage `shouldSatisfy` (\m -> "frame-order" `T.isInfixOf` m || "malformed-failed" `T.isInfixOf` m)
            Right _ -> expectationFailure "expected a RuntimeProtocolError"
          closeClient client `shouldReturn` True
          removeDirectoryRecursive privateRoot

-- ---------------------------------------------------------------------------
-- Resume and the A4 territories

a4Specs :: Spec
a4Specs = do
  it "test_native_resume_preserves_identity_and_extends_opaque_jsonl" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optPlans = [plan {planText = "one"}, plan {planText = "two"}]}
    firstInv <- invocation rig "g1"
    first <- startWait rig firstInv
    firstReference <- maybe (fail "no continuation") pure first.continuationReference
    Just old <- Map.lookup firstReference <$> readIORef rig.continuations.values
    secondInv <- (.invocation) <$> invoke rig "g2" invocationOptions {invContinuation = Just (claimed firstReference)}
    second <- startWait rig secondInv
    secondReference <- maybe (fail "no continuation") pure second.continuationReference
    Just new <- Map.lookup secondReference <$> readIORef rig.continuations.values
    calls <- readIORef rig.factory.calls
    map (.prior) (drop 1 calls) `shouldBe` [Just old]
    new.sessionId `shouldBe` old.sessionId
    new.sessionJsonl `shouldSatisfy` B.isPrefixOf old.sessionJsonl

  it "test_native_a4_resumes_only_continuation_after_settled_gondolin_replacement" $ withTemp $ \tmp -> do
    gondolin <- newRig (tmp </> "gondolin") rigOptions {optPlans = [plan {planText = "one"}], optTerritory = "gondolin"}
    firstInvoked <- invoke gondolin "g1" invocationOptions
    firstOperation <- startPi gondolin.adapter firstInvoked.invocation
    first <- waitPiOperation firstOperation (Just 3)
    closeDisposition firstOperation `shouldReturn` RuntimeCleanupClean
    let firstReference = maybe "" id first.continuationReference
    Just firstPayload <- Map.lookup firstReference <$> readIORef gondolin.continuations.values
    settledVerified firstInvoked.attachment `shouldReturn` True

    e2b <- newRig (tmp </> "e2b") rigOptions {optPlans = [plan {planText = "two"}], optTerritory = "e2b", optPredecessor = Just gondolin}
    secondInvoked <- invoke e2b "g2" invocationOptions {invContinuation = Just (claimed firstReference)}
    secondOperation <- startPi e2b.adapter secondInvoked.invocation
    second <- waitPiOperation secondOperation (Just 3)
    closeDisposition secondOperation `shouldReturn` RuntimeCleanupClean
    Just secondPayload <- Map.lookup (maybe "" id second.continuationReference) <$> readIORef e2b.continuations.values
    map (.prior) <$> readIORef e2b.factory.calls `shouldReturn` [Just firstPayload]
    secondPayload.sessionId `shouldBe` firstPayload.sessionId
    secondPayload.sessionJsonl `shouldSatisfy` B.isPrefixOf firstPayload.sessionJsonl
    firstPayload.sessionJsonl `shouldNotSatisfy` B.isInfixOf "attachment-g1"
    secondPayload.sessionJsonl `shouldNotSatisfy` B.isInfixOf "attachment-g1"
    secondPayload.sessionJsonl `shouldNotSatisfy` B.isInfixOf "attachment-g2"
    settledVerified secondInvoked.attachment `shouldReturn` True

  it "test_native_a4_rejects_cross_territory_resume_with_a_different_project_binding" $ withTemp $ \tmp -> do
    gondolin <- newRig (tmp </> "gondolin") rigOptions {optTerritory = "gondolin"}
    firstInvoked <- invoke gondolin "g1" invocationOptions
    firstOperation <- startPi gondolin.adapter firstInvoked.invocation
    first <- waitPiOperation firstOperation (Just 3)
    closeDisposition firstOperation `shouldReturn` RuntimeCleanupClean
    settledVerified firstInvoked.attachment `shouldReturn` True

    e2b <- newRig (tmp </> "e2b") rigOptions {optTerritory = "e2b"}
    readIORef gondolin.continuations.values >>= \known -> modifyIORef' e2b.continuations.values (Map.union known)
    secondInvoked <- invoke e2b "g2" invocationOptions {invContinuation = Just (claimed (maybe "" id first.continuationReference))}
    raises (startPi e2b.adapter secondInvoked.invocation) RuntimeProtocolError "continuation-project-mismatch"
    readIORef e2b.custody.records `shouldReturn` []
    length <$> readIORef e2b.factory.calls `shouldReturn` 0
    settledVerified secondInvoked.attachment `shouldReturn` True

  it "test_native_a4_rejects_cross_profile_resolution_and_lease_before_authority" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optTerritory = "gondolin"}
    alien <- invoke rig "foreign" invocationOptions {invSelected = Just (snapshotFor Nothing rig.connection "e2b")}
    raises (startPi rig.adapter alien.invocation) RuntimeProtocolError "resolution-mismatch"
    readIORef rig.custody.records `shouldReturn` []
    length <$> readIORef rig.factory.calls `shouldReturn` 0
    settledVerified alien.attachment `shouldReturn` True

    stale <- invoke rig "stale" invocationOptions
    writeIORef stale.territory.drift (Just "e2b")
    ( do
        raises (startPi rig.adapter stale.invocation) RuntimeProtocolError "runtime-territory-lease-required"
        readIORef rig.custody.records `shouldReturn` []
        length <$> readIORef rig.factory.calls `shouldReturn` 0
      )
      `finally` writeIORef stale.territory.drift Nothing
    settledVerified stale.attachment `shouldReturn` True

  it "test_native_a4_post_run_lease_drift_releases_authority_without_publication" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optTerritory = "gondolin"}
    invoked <- invoke rig "post-run-stale" invocationOptions
    writeIORef rig.factory.afterRun (writeIORef invoked.territory.drift (Just "e2b"))
    op <- startPi rig.adapter invoked.invocation
    r <- waitPiOperation op (Just 3)
    r.outcome `shouldBe` TurnFailed
    r.terminationCode `shouldBe` "runtime-territory-lease-required"
    r.acceptedAppends `shouldBe` 0
    noRefs r
    kinds rig `shouldReturn` ["materialize", "release"]
    closeDisposition op `shouldReturn` RuntimeCleanupClean
    writeIORef invoked.territory.drift Nothing
    settledVerified invoked.attachment `shouldReturn` True

  forM_ ["gondolin", "e2b"] $ \profile ->
    it ("test_native_a4_cancellation_wins_while_remote_publication_lookup_is_stalled[" <> T.unpack profile <> "]") $ withTemp $ \tmp -> do
      (hooks, started, released) <- stallBindingCurrent
      rig <- newRig tmp rigOptions {optTerritory = profile, optHooks = hooks}
      invoked <- invoke rig "stalled-publication" invocationOptions
      op <- startPi rig.adapter invoked.invocation
      awaitSignal started
      ( do
          waitStarted <- getMonotonicTime
          raises (waitPiOperation op (Just 0.05)) TimeoutError "has not settled"
          getMonotonicTime >>= \now -> (now - waitStarted) `shouldSatisfy` (< 0.2)
          cancelStarted <- getMonotonicTime
          cancelPiOperation op "stop" `shouldReturn` CancellationRequested
          getMonotonicTime >>= \now -> (now - cancelStarted) `shouldSatisfy` (< 0.2)
        )
        `finally` void (tryPutMVar released ())
      r <- waitPiOperation op (Just 3)
      r.outcome `shouldBe` TurnCancelled
      noRefs r
      Map.null <$> readIORef rig.turns.values `shouldReturn` True
      Map.null <$> readIORef rig.continuations.values `shouldReturn` True
      kinds rig `shouldReturn` ["materialize", "release"]
      closeDisposition op `shouldReturn` RuntimeCleanupClean
      settledVerified invoked.attachment `shouldReturn` True

  forM_ ["grant", "deadline"] $ \lapse -> forM_ ["gondolin", "e2b"] $ \profile ->
    it ("test_native_a4_rechecks_publication_admission_after_remote_lookup[" <> lapse <> "-" <> T.unpack profile <> "]") $ withTemp $ \tmp -> do
      clock <- getMonotonicTime >>= newIORef
      (hooks, started, released) <- stallBindingCurrent
      rig <- newRig tmp rigOptions {optTerritory = profile, optClock = Just (readIORef clock), optHooks = hooks}
      invoked <- invoke rig "stale-admission" invocationOptions
      op <- startPi rig.adapter invoked.invocation
      awaitSignal started
      expected <-
        if lapse == "grant"
          then closeGrant (Episode.grants invoked.attachment) >> pure "grant-mismatch"
          else writeIORef clock (episodeDeadline invoked.attachment) >> pure "deadline-exceeded"
      putMVar released ()
      r <- waitPiOperation op (Just 3)
      r.outcome `shouldBe` TurnFailed
      r.terminationCode `shouldBe` expected
      noRefs r
      Map.null <$> readIORef rig.turns.values `shouldReturn` True
      Map.null <$> readIORef rig.continuations.values `shouldReturn` True
      kinds rig `shouldReturn` ["materialize", "release"]
      closeDisposition op `shouldReturn` RuntimeCleanupClean
      settledVerified invoked.attachment `shouldReturn` True

  it "test_native_a4_publication_claim_makes_later_cancellation_too_late" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optTerritory = "gondolin"}
    invoked <- invoke rig "claimed-publication" invocationOptions
    started <- newEmptyMVar
    released <- newEmptyMVar
    writeIORef rig.custody.beforeAdmit (signalWait started released)
    op <- startPi rig.adapter invoked.invocation
    awaitSignal started
    cancelPiOperation op "stop" `shouldReturn` CancellationTooLate
    putMVar released ()
    r <- waitPiOperation op (Just 3)
    r.outcome `shouldBe` TurnCompleted
    (isJust r.outputReference, isJust r.continuationReference) `shouldBe` (True, True)
    closeDisposition op `shouldReturn` RuntimeCleanupClean
    settledVerified invoked.attachment `shouldReturn` True

-- ---------------------------------------------------------------------------
-- Failures before and after authority

failureSpecs :: Spec
failureSpecs = do
  it "test_resolution_stale_lease_provider_and_expired_deadline_fail_before_authority" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions
    let alien = capabilityDescriptor (descriptorIdentity KindRuntime "foreign" 1) [] []
    resolution <- invoke rig "resolution" invocationOptions {invSelected = Just (snapshotFor (Just alien) rig.connection "local")}
    raises (startPi rig.adapter resolution.invocation) RuntimeProtocolError "resolution-mismatch"
    lease <- invoke rig "lease" invocationOptions
    writeIORef lease.territory.lookupOverride (Just (\_ -> pure Nothing))
    raises (startPi rig.adapter lease.invocation) RuntimeProtocolError "runtime-local-lease-required"
    providerInv <- invocation rig "provider"
    let other = ok (mkConnectionIdentity "connection" "other" "account" "api-key")
    raises (startPi rig.adapter (withIdentity providerInv other)) RuntimeProtocolError "connection-provider-mismatch"
    now <- getMonotonicTime
    expired <- (.invocation) <$> invoke rig "expired" invocationOptions {invDeadline = Just (now - 1)}
    r <- startWait rig expired
    r.terminationCode `shouldBe` "deadline-exceeded"
    readIORef rig.custody.records `shouldReturn` []
    length <$> readIORef rig.factory.calls `shouldReturn` 0

  forM_ [(plan {planError = Just "provider-failed"}, "provider-failed", "plan0"), (plan {planClean = False}, "cleanup-unverified", "plan1")] $ \(scripted, code, label) ->
    it ("test_provider_and_cleanup_failures_publish_no_references[" <> label <> "-" <> T.unpack code <> "]") $ withTemp $ \tmp -> do
      rig <- newRig tmp rigOptions {optPlans = [scripted]}
      inv <- invocation rig "failure"
      r <- startWait rig inv
      (r.outcome, r.terminationCode, r.acceptedAppends) `shouldBe` (TurnFailed, code, 0)
      noRefs r

  it "test_output_storage_failure_and_release_uncertainty_remove_candidate_refs" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions
    writeIORef rig.turns.failing True
    r <- invocation rig "store" >>= startWait rig
    r.outcome `shouldBe` TurnFailed
    noRefs r
    continuationRig <- newRig (tmp </> "continuation") rigOptions
    writeIORef continuationRig.continuations.failing True
    r' <- invocation continuationRig "continuation-store" >>= startWait continuationRig
    Map.member "pi-turn-continuation-store" <$> readIORef continuationRig.turns.values `shouldReturn` True
    r'.outcome `shouldBe` TurnFailed
    noRefs r'
    otherRig <- newRig (tmp </> "other") rigOptions
    writeIORef otherRig.custody.uncertain True
    r'' <- invocation otherRig "release" >>= startWait otherRig
    r''.terminationCode `shouldBe` "cleanup-unverified"
    noRefs r''

-- ---------------------------------------------------------------------------
-- Subscription custody

subscriptionSpecs :: Spec
subscriptionSpecs = do
  forM_ ["subscription", "cc-patch-subscription"] $ \profile ->
    it ("test_subscription_success_checkpoints_rotated_native_auth_after_verified_cleanup[" <> T.unpack profile <> "]") $ withTemp $ \tmp -> do
      rig <- newRig tmp rigOptions {optProfile = profile}
      r <- invocation rig "subscription" >>= startWait rig
      (r.outcome, r.acceptedAppends, r.terminationCode) `shouldBe` (TurnCompleted, 1, "turn-completed")
      readIORef rig.custody.records
        `shouldReturn` [ ("materialize", "subscription.materialize")
                       , ("activate", "subscription.activate")
                       , ("admit", "subscription.admit")
                       , ("checkpoint", "subscription.checkpoint")
                       ]
      readIORef rig.custody.home `shouldReturn` refreshedAuth
      readIORef rig.custody.stateVersion `shouldReturn` 5
      [call] <- readIORef rig.factory.calls
      (call.apiKey, call.nativeAuth) `shouldBe` (Nothing, Just auth)
      call.extension `shouldBe` (if profile == "cc-patch-subscription" then Just "/fake/pi-cc-patch/index.ts" else Nothing)
      emptyRoot rig

  it "test_clean_subscription_provider_failure_checkpoints_auth_without_turn_publication" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optPlans = [plan {planProviderFailed = True}], optProfile = "subscription"}
    r <- invocation rig "provider-failure" >>= startWait rig
    (r.outcome, r.acceptedAppends, r.terminationCode) `shouldBe` (TurnFailed, 0, "provider-failed")
    noRefs r
    kinds rig `shouldReturn` ["materialize", "activate", "admit", "checkpoint"]
    readIORef rig.custody.home `shouldReturn` refreshedAuth

  it "test_subscription_spawn_failure_releases_before_activation" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optProfile = "subscription"}
    writeIORef rig.factory.failCreate True
    r <- invocation rig "spawn" >>= startWait rig
    (r.outcome, r.acceptedAppends) `shouldBe` (TurnFailed, 0)
    kinds rig `shouldReturn` ["materialize", "release"]

  it "test_helper_construction_refuses_a_grant_replaced_after_initial_validation" $ withTemp $ \tmp -> do
    helper <- piHelperPath
    attached <- newEmptyMVar
    let replacing = PiHelperFactory $ \arguments -> do
          current <- readMVar attached
          _ <- openGrant (Episode.grants current) (grantSpec [WorkspaceRead] (episodeDeadline current) 1)
          subprocessClient <$> newSubprocessClient helper arguments
    rig <- newRig tmp rigOptions {optPrepare = \r -> r {installation = r.installation, factory = Just replacing}}
    invoked <- invoke rig "replaced-grant" invocationOptions {invCapabilities = Just [WorkspaceRead]}
    putMVar attached invoked.attachment
    op <- startPi rig.adapter invoked.invocation
    r <- waitPiOperation op (Just 3)
    (r.outcome, r.acceptedAppends, r.terminationCode) `shouldBe` (TurnFailed, 0, "grant-mismatch")
    kinds rig `shouldReturn` ["materialize", "release"]
    closeDisposition op `shouldReturn` RuntimeCleanupClean
    emptyRoot rig
    settledVerified invoked.attachment `shouldReturn` True

  it "test_cc_patch_lane_rejects_native_subscription_descriptor_before_authority" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optProfile = "cc-patch-subscription"}
    inv <- invocation rig "wrong-profile"
    let mislabeled = withIdentity inv (reidentify inv.connection.identity inv.connection.identity.connectionId "subscription")
    raises (startPi rig.adapter mislabeled) RuntimeProtocolError "connection-profile-mismatch"
    readIORef rig.custody.records `shouldReturn` []
    length <$> readIORef rig.factory.calls `shouldReturn` 0

    native <- newRig (tmp </> "native") rigOptions {optProfile = "subscription"}
    nativeInv <- invocation native "wrong-profile"
    let patched = withIdentity nativeInv (reidentify nativeInv.connection.identity nativeInv.connection.identity.connectionId "cc-patch-subscription")
    raises (startPi native.adapter patched) RuntimeProtocolError "connection-profile-mismatch"
    readIORef native.custody.records `shouldReturn` []
    length <$> readIORef native.factory.calls `shouldReturn` 0

  it "test_cc_patch_lane_requires_qualified_extension_before_authority" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optProfile = "cc-patch-subscription", optPrepare = \r -> r {installation = r.installation, ccPatchEntrypoint = Nothing}}
    inv <- invocation rig "missing-extension"
    raises (startPi rig.adapter inv) RuntimeProtocolError "cc-patch-not-ready"
    readIORef rig.custody.records `shouldReturn` []
    length <$> readIORef rig.factory.calls `shouldReturn` 0

  it "test_uncertain_subscription_run_releases_activated_lease_without_checkpoint" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optPlans = [plan {planError = Just "protocol-failed"}], optProfile = "subscription"}
    r <- invocation rig "uncertain" >>= startWait rig
    (r.outcome, r.acceptedAppends) `shouldBe` (TurnFailed, 0)
    noRefs r
    kinds rig `shouldReturn` ["materialize", "activate", "release"]

  it "test_subscription_stale_attachment_after_run_prevents_checkpoint_and_result_publication" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optProfile = "subscription", optHooks = PiAdapterHooks Nothing (Just (\_ -> pure (Just "grant-mismatch"))) Nothing}
    inv <- invocation rig "stale"
    r <- startWait rig inv
    (r.terminationCode, r.acceptedAppends) `shouldBe` ("grant-mismatch", 0)
    noRefs r
    Map.null <$> readIORef rig.turns.values `shouldReturn` True
    Map.null <$> readIORef rig.continuations.values `shouldReturn` True
    kinds rig `shouldReturn` ["materialize", "activate", "release"]

  forM_ [False, True] $ \providerFailed ->
    it ("test_subscription_auth_export_with_uncertain_helper_cleanup_is_not_checkpointed[" <> show providerFailed <> "]") $ withTemp $ \tmp -> do
      rig <- newRig tmp rigOptions {optPlans = [plan {planClean = False, planProviderFailed = providerFailed}], optProfile = "subscription"}
      r <- invocation rig "cleanup" >>= startWait rig
      (r.terminationCode, r.acceptedAppends) `shouldBe` ("cleanup-unverified", 0)
      noRefs r
      kinds rig `shouldReturn` ["materialize", "activate", "release"]
      emptyRoot rig

  it "test_subscription_missing_returned_auth_requires_reauthorization" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optPlans = [plan {planOmitAuth = True}], optProfile = "subscription"}
    r <- invocation rig "missing-auth" >>= startWait rig
    (r.terminationCode, r.acceptedAppends) `shouldBe` ("credential-invalid", 0)
    kinds rig `shouldReturn` ["materialize", "activate", "release"]
    Map.null <$> readIORef rig.turns.values `shouldReturn` True
    Map.null <$> readIORef rig.continuations.values `shouldReturn` True

  let invalidAuthorities =
        [ ("anthropic", "not-json")
        , ("anthropic", "{\"other\":{\"type\":\"oauth\",\"access\":\"a\",\"refresh\":\"r\",\"expires\":1}}")
        , ("anthropic", "{\"anthropic\":{\"type\":\"oauth\",\"access\":\"a\",\"refresh\":\"r\",\"expires\":1},\"other\":{}}")
        ]
      openaiMissingAccount = ("openai-codex", "{\"openai-codex\":{\"type\":\"oauth\",\"access\":\"a\",\"refresh\":\"r\",\"expires\":1}}")
  forM_
    ( invalidAuthorities
        <> [("anthropic", "{\"anthropic\":{\"type\":\"oauth\",\"access\":\"a\",\"access\":\"b\",\"refresh\":\"r\",\"expires\":1}}"), openaiMissingAccount]
    )
    $ \(provider, authority) ->
      it ("test_invalid_subscription_authority_is_rejected_before_activation[" <> T.unpack provider <> "-" <> T.unpack (TE.decodeUtf8 authority) <> "]") $ withTemp $ \tmp -> do
        rig <- newRig tmp rigOptions {optProfile = "subscription", optProvider = Just provider}
        writeIORef rig.custody.home authority
        r <- invocation rig "invalid-input" >>= startWait rig
        (r.terminationCode, r.acceptedAppends) `shouldBe` ("credential-invalid", 0)
        kinds rig `shouldReturn` ["materialize", "release"]
        length <$> readIORef rig.factory.calls `shouldReturn` 0
        emptyRoot rig

  forM_ (invalidAuthorities <> [openaiMissingAccount]) $ \(provider, returned) ->
    it ("test_invalid_returned_subscription_authority_requires_reauthorization[" <> T.unpack provider <> "-" <> T.unpack (TE.decodeUtf8 returned) <> "]") $ withTemp $ \tmp -> do
      rig <- newRig tmp rigOptions {optPlans = [plan {planRefreshed = Just returned}], optProfile = "subscription", optProvider = Just provider}
      r <- invocation rig "invalid-output" >>= startWait rig
      (r.terminationCode, r.acceptedAppends) `shouldBe` ("credential-invalid", 0)
      noRefs r
      kinds rig `shouldReturn` ["materialize", "activate", "release"]
      emptyRoot rig

  it "test_subscription_reserves_publication_time_before_materializing_authority" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optProfile = "subscription", optConfig = \config -> config {credentialTtl = 2}}
    inv <- invocation rig "ttl"
    raises (startPi rig.adapter inv) RuntimeProtocolError "subscription-ttl-insufficient"
    readIORef rig.custody.records `shouldReturn` []

    deadlineRig <- newRig (tmp </> "deadline") rigOptions {optProfile = "subscription"}
    now <- getMonotonicTime
    deadlineInv <- (.invocation) <$> invoke deadlineRig "deadline" invocationOptions {invDeadline = Just (now + 1)}
    r <- startWait deadlineRig deadlineInv
    r.terminationCode `shouldBe` "deadline-exceeded"
    readIORef deadlineRig.custody.records `shouldReturn` []

  it "test_subscription_deadline_after_activation_releases_without_checkpoint" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optPlans = [plan {planBlock = True}], optWallTimeout = 0.05, optProfile = "subscription"}
    r <- invocation rig "run-deadline" >>= startWait rig
    (r.terminationCode, r.acceptedAppends) `shouldBe` ("deadline-exceeded", 0)
    kinds rig `shouldReturn` ["materialize", "activate", "release"]
    Map.null <$> readIORef rig.turns.values `shouldReturn` True
    Map.null <$> readIORef rig.continuations.values `shouldReturn` True

  it "test_subscription_storage_or_checkpoint_failure_publishes_no_references" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optProfile = "subscription"}
    writeIORef rig.turns.failing True
    r <- invocation rig "turn-store" >>= startWait rig
    (r.outcome, r.outputReference) `shouldBe` (TurnFailed, Nothing)
    Map.null <$> readIORef rig.turns.values `shouldReturn` True
    Map.null <$> readIORef rig.continuations.values `shouldReturn` True
    kinds rig `shouldReturn` ["materialize", "activate", "admit", "checkpoint"]

    checkpointRig <- newRig (tmp </> "checkpoint") rigOptions {optProfile = "subscription"}
    writeIORef checkpointRig.custody.checkpointFail True
    r' <- invocation checkpointRig "checkpoint" >>= startWait checkpointRig
    (r'.outcome, r'.acceptedAppends) `shouldBe` (TurnFailed, 0)
    noRefs r'
    kinds checkpointRig `shouldReturn` ["materialize", "activate", "admit", "checkpoint", "release"]

  forM_ [False, True] $ \malformed ->
    it ("test_stale_or_malformed_subscription_checkpoint_publishes_no_result[" <> show malformed <> "]") $ withTemp $ \tmp -> do
      rig <- newRig tmp rigOptions {optProfile = "subscription"}
      inv <- invocation rig "bad-checkpoint"
      -- The reference returns @object()@ for the malformed case; a typed
      -- result can only be malformed by naming another operation.
      writeIORef rig.custody.checkpointOverride $ Just $ \m operationId -> do
        modifyIORef' rig.custody.records (<> [("checkpoint", operationId)])
        view <- custodyView rig.custody
        size <- B.length <$> readIORef rig.custody.home
        pure
          PublicationResult
            { operationId = if malformed then operationId <> ".malformed" else operationId
            , connection = view
            , cleanup = CleanupEvidence m.fence.attachmentId True False (toInteger size) False False
            }
      r <- startWait rig inv
      (r.terminationCode, r.acceptedAppends) `shouldBe` ("connection-publication-mismatch", 0)
      noRefs r
      Map.null <$> readIORef rig.turns.values `shouldReturn` True
      Map.null <$> readIORef rig.continuations.values `shouldReturn` True
      kinds rig `shouldReturn` ["materialize", "activate", "admit", "checkpoint", "release"]

  it "test_real_refresh_custody_checkpoints_or_requires_reauthorization_after_activation" $ withTemp $ \tmp -> do
    storage <- openSqliteConnectionStorage (tmp </> "connection.sqlite3")
    keys <- aesKeys
    materializer <- newPrivateFileMaterializer (tmp </> "materialized")
    let custody = agentConnectionCustody storage keys materializer getMonotonicTime
    enrollHost custody "host" "enroll"
    state <- newOpaqueState auth
    _ <- authorize custody (ok (mkConnectionIdentity "pi-subscription" "anthropic" "account" "subscription")) state "authorize"
    unactivated <- Custody.materialize custody "pi-subscription" "host" LeaseRefresh 30 "materialize-0"
    _ <- Custody.release custody unactivated "release-0"
    (.status) <$> lookupConnection custody "pi-subscription" `shouldReturn` StatusReady
    first <- Custody.materialize custody "pi-subscription" "host" LeaseRefresh 30 "materialize-1"
    Custody.activate custody first "activate-1"
    replaceMaterialized first.home refreshedAuth
    published <- Custody.checkpoint custody first "checkpoint-1"
    (published.connection.status, published.connection.stateVersion) `shouldBe` (StatusReady, 2)
    second <- Custody.materialize custody "pi-subscription" "host" LeaseRefresh 30 "materialize-2"
    Custody.activate custody second "activate-2"
    _ <- Custody.release custody second "release-2"
    current <- lookupConnection custody "pi-subscription"
    (current.status, current.stateDigest) `shouldBe` (StatusReauthorizationRequired, Nothing)
    closeCustody custody

-- ---------------------------------------------------------------------------
-- Operation lifecycle

lifecycleSpecs :: Spec
lifecycleSpecs = do
  forM_ ["api-key", "subscription"] $ \profile ->
    it ("test_cancel_deadline_redelivery_conflict_and_too_late_claim[" <> T.unpack profile <> "]") $ withTemp $ \tmp -> do
      rig <- newRig tmp rigOptions {optPlans = [plan {planBlock = True}], optProfile = profile}
      inv <- invocation rig "cancel"
      op <- startPi rig.adapter inv
      waitUntil 2 (not . null <$> readIORef rig.factory.clients)
      readIORef rig.factory.clients >>= \case
        client : _ -> timeout 2000000 (readMVar client.entered) `shouldReturn` Just ()
        [] -> expectationFailure "no client"
      again <- startPi rig.adapter inv
      (again == op) `shouldBe` True
      raises (startPi rig.adapter (withPrompt inv "changed")) RuntimeProtocolError "operation-conflict"
      cancelPiOperation op "stop" `shouldReturn` CancellationRequested
      (.outcome) <$> waitPiOperation op (Just 3) `shouldReturn` TurnCancelled
      when (profile == "subscription") $ kinds rig `shouldReturn` ["materialize", "activate", "release"]

  it "test_thread_start_failure_rolls_back_registration" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optHooks = PiAdapterHooks Nothing Nothing (Just (\_ -> throwAgenticus RuntimeError "start"))}
    inv <- invocation rig "thread"
    raises (startPi rig.adapter inv) RuntimeError "start"
    adapterOperationIds rig.adapter >>= (`shouldNotContain` ["thread"])

  it "test_canaries_never_render_log_or_error" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions {optProfile = "subscription", optProvider = Just "openai-codex"}
    inv <- invocation rig "canary"
    op <- startPi rig.adapter inv
    r <- waitPiOperation op (Just 3)
    adapterText <- renderPiRuntimeAdapter rig.adapter
    let rendered = adapterText <> renderPiRuntimeInvocation inv <> T.pack (show op) <> T.pack (show r)
    rendered
      `shouldNotContain'` [ keyText
                          , prompt
                          , sessionCanary
                          , sessionId
                          , "pi-openai-access-canary"
                          , "pi-openai-refresh-canary"
                          , "pi-openai-account-canary"
                          ]

  -- The reference imports the module in a subprocess whose @subprocess.run@
  -- raises. Haskell imports have no effects; the equivalent is that building
  -- an adapter discovers nothing until 'probe' runs.
  it "test_import_has_no_node_or_npm_dependency" $ withTemp $ \tmp -> do
    let working = tmp </> "working"
        private = tmp </> "private"
    createDirectory working
    privateDirectory private
    continuations <- newContinuations
    turns <- newTurns
    custody <- newFakeCustody "api-key" "provider"
    adapter <-
      newPiRuntimeAdapter
        (piRuntimeConfig "provider" "model" working private)
        (piContinuationCodec (continuationOperations continuations))
        (turnOperations turns)
        (custodyOperations custody)
        getMonotonicTime
        Nothing
    r <- readAdapterRuntime adapter
    (isNothing r.node, isNothing r.sdkEntrypoint, isNothing r.installation, isNothing r.factory) `shouldBe` (True, True, True, True)

  it "test_adapter_evicts_only_closed_operation_receipts" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions
    inv <- invocation rig "evict"
    op <- startPi rig.adapter inv
    raises (evictPi rig.adapter inv.operationId) RuntimeProtocolError "operation-active"
    _ <- waitPiOperation op (Just 3)
    isJust <$> receiptPi rig.adapter inv.operationId `shouldReturn` True
    _ <- closePiOperation op
    evictPi rig.adapter inv.operationId `shouldReturn` True
    evictPi rig.adapter inv.operationId `shouldReturn` False

-- ---------------------------------------------------------------------------
-- Durable recovery

ledgerAt :: FilePath -> FilePath
ledgerAt tmp = tmp </> "ledger" </> "operations.sqlite3"

surfaceWith :: Rig -> (PiAdapterSurface -> PiAdapterSurface) -> PiAdapterSurface
surfaceWith rig f = f (piAdapterSurface rig.adapter)

replaceStart :: (PiRuntimeInvocation -> IO RuntimeOperation) -> PiAdapterSurface -> PiAdapterSurface
replaceStart start s = PiAdapterSurface {adapter = s.adapter, config = s.config, start, receipt = s.receipt, evict = s.evict}

replaceReceipt :: (Text -> IO (Maybe RuntimeTurnSettlement)) -> PiAdapterSurface -> PiAdapterSurface
replaceReceipt receipt s = PiAdapterSurface {adapter = s.adapter, config = s.config, start = s.start, receipt, evict = s.evict}

fingerprintFor :: Rig -> PiRuntimeInvocation -> IO Text
fingerprintFor rig inv = either throwIOE pure (piDurableFingerprint (rigConfig rig) inv)

admitFor :: SqlitePiOperationLedger -> Rig -> PiRuntimeInvocation -> IO ()
admitFor ledger rig inv = do
  fingerprint <- fingerprintFor rig inv
  void (ledgerAdmit ledger inv.operationId fingerprint inv.episodeId inv.turnId)

lookupRecord :: SqlitePiOperationLedger -> Text -> IO PiOperationRecord
lookupRecord ledger operationId = ledgerLookup ledger operationId >>= maybe (fail "no record") pure

waitOp :: PiRecoveredOperation -> Maybe Double -> IO RuntimeTurnSettlement
waitOp o = (recoveredOperation o).wait

closeOp :: PiRecoveredOperation -> IO RuntimeOperationCleanup
closeOp o = (recoveredOperation o).close

-- | A ledger whose next armed call persists, then loses its acknowledgement.
data LossyLedger = LossyLedger
  { ledger :: PiOperationLedger
  , settleArmed :: IORef Bool
  , upgradeArmed :: IORef Bool
  }

lossyLedger :: PiOperationLedger -> IO LossyLedger
lossyLedger l = do
  settleArmed <- newIORef False
  upgradeArmed <- newIORef False
  let lose armed message record = do
        fire <- atomicModifyIORef' armed (False,)
        when fire $ throwAgenticus StorageError message
        pure record
  pure
    LossyLedger
      { ledger =
          PiOperationLedger
            { recover = l.recover
            , admit = l.admit
            , lookup = l.lookup
            , records = l.records
            , settle = \i r -> l.settle i r >>= lose settleArmed "synthetic lost settlement acknowledgement"
            , upgradeCleanup = \i c -> l.upgradeCleanup i c >>= lose upgradeArmed "synthetic lost cleanup acknowledgement"
            , acknowledge = l.acknowledge
            , watermark = l.watermark
            , close = l.close
            }
      , settleArmed
      , upgradeArmed
      }

recoverySpecs :: Spec
recoverySpecs = do
  it "test_recovered_runtime_persists_before_dispatch_and_wait_publication" $ withTemp $ \tmp -> do
    rig <- newRig (tmp </> "rig") rigOptions
    inv <- invocation rig "durable"
    ledger <- openSqlitePiOperationLedger (ledgerAt tmp)
    let observed s = flip replaceStart s $ \value -> do
          record <- ledgerLookup ledger value.operationId
          fmap (.phase) record `shouldBe` Just PhaseExecuting
          s.start value
    runtime <- newPiRecoveredRuntimeWith (surfaceWith rig observed) (sqlitePiOperationLedger ledger)
    first <- startRecovered runtime inv
    again <- startRecovered runtime inv
    (again == first) `shouldBe` True
    result <- waitOp first (Just 3)
    length <$> readIORef rig.factory.calls `shouldReturn` 1
    record <- lookupRecord ledger "durable"
    ok (recordSettlement record) `shouldBe` result
    cleanup <- closeOp first
    (.cleanup) <$> lookupRecord ledger "durable" `shouldReturn` cleanup.disposition
    ledgerClose ledger

  it "test_restart_classifies_execution_and_replays_without_adapter_access" $ withTemp $ \tmp -> do
    let path = ledgerAt tmp
    rig <- newRig (tmp </> "first") rigOptions
    inv <- invocation rig "ambiguous"
    ledger <- openSqlitePiOperationLedger path
    admitFor ledger rig inv
    (.phase) <$> lookupRecord ledger "ambiguous" `shouldReturn` PhaseExecuting
    ledgerClose ledger

    reopened <- openSqlitePiOperationLedger path
    (.phase) <$> lookupRecord reopened "ambiguous" `shouldReturn` PhaseExecuting
    recovered <- newPiRecoveredRuntime rig.adapter (sqlitePiOperationLedger reopened)
    map (.outcome) (take 1 (recoveredSettlements recovered)) `shouldBe` [TurnIndeterminate]
    r <- startRecovered recovered inv >>= \o -> waitOp o Nothing
    r.outcome `shouldBe` TurnIndeterminate
    (r.terminationCode, r.acceptedAppends) `shouldBe` ("restart-indeterminate", 0)
    length <$> readIORef rig.factory.calls `shouldReturn` 0
    ledgerClose reopened

  it "test_recovery_atomically_classifies_every_preexisting_execution" $ withTemp $ \tmp -> do
    let path = ledgerAt tmp
    rig <- newRig (tmp </> "rig") rigOptions
    first <- invocation rig "ambiguous-one"
    second <- invocation rig "ambiguous-two"
    ledger <- openSqlitePiOperationLedger path
    forM_ [first, second] (admitFor ledger rig)
    ledgerClose ledger

    reopened <- openSqlitePiOperationLedger path
    runtime <- newPiRecoveredRuntime rig.adapter (sqlitePiOperationLedger reopened)
    length (recoveredSettlements runtime) `shouldBe` 2
    map (.outcome) (recoveredSettlements runtime) `shouldBe` [TurnIndeterminate, TurnIndeterminate]
    map (.phase) <$> ledgerRecords reopened `shouldReturn` [PhaseSettled, PhaseSettled]
    length <$> readIORef rig.factory.calls `shouldReturn` 0
    ledgerClose reopened

  it "test_operation_ledger_refuses_a_second_live_writer" $ withTemp $ \tmp -> do
    let path = ledgerAt tmp
    ledger <- openSqlitePiOperationLedger path
    raises (openSqlitePiOperationLedger path) StorageError "already has a live writer"
    ledgerClose ledger
    openSqlitePiOperationLedger path >>= ledgerClose

  it "test_completed_replay_conflict_acknowledgement_watermark_and_eviction" $ withTemp $ \tmp -> do
    let path = ledgerAt tmp
    rig <- newRig (tmp </> "first") rigOptions
    inv <- invocation rig "completed"
    ledger <- openSqlitePiOperationLedger path
    runtime <- newPiRecoveredRuntime rig.adapter (sqlitePiOperationLedger ledger)
    op <- startRecovered runtime inv
    result <- waitOp op (Just 3)
    again <- startRecovered runtime inv
    (again == op) `shouldBe` True
    _ <- closeOp op
    _ <- acknowledgeRecovered runtime "completed"
    ledgerWatermark ledger `shouldReturn` 1
    evictRecovered runtime `shouldReturn` ["completed"]
    (startRecovered runtime inv >>= \o -> waitOp o Nothing) `shouldReturn` result
    ledgerClose ledger

    fresh <- newRig (tmp </> "fresh") rigOptions {optPredecessor = Just rig}
    reopened <- openSqlitePiOperationLedger path
    recovered <- newPiRecoveredRuntime fresh.adapter (sqlitePiOperationLedger reopened)
    (startRecovered recovered inv >>= \o -> waitOp o Nothing) `shouldReturn` result
    length <$> readIORef fresh.factory.calls `shouldReturn` 0
    raises (startRecovered recovered (withPrompt inv "changed prompt")) RuntimeProtocolError "operation-conflict"
    ledgerClose reopened

  it "test_close_persists_a_naturally_settled_result_before_cleanup" $ withTemp $ \tmp -> do
    rig <- newRig (tmp </> "rig") rigOptions
    inv <- invocation rig "close-before-wait"
    ledger <- openSqlitePiOperationLedger (ledgerAt tmp)
    runtime <- newPiRecoveredRuntime rig.adapter (sqlitePiOperationLedger ledger)
    op <- startRecovered runtime inv
    waitUntil 3 (isJust <$> receiptPi rig.adapter inv.operationId)
    cleanup <- closeOp op
    record <- lookupRecord ledger inv.operationId
    (.outcome) (ok (recordSettlement record)) `shouldBe` TurnCompleted
    (record.cleanup, cleanup.disposition) `shouldBe` (RuntimeCleanupClean, RuntimeCleanupClean)
    raises (waitOp op Nothing) RuntimeProtocolError "operation-closed"
    closeOp op `shouldReturn` cleanup
    ledgerClose ledger

  it "test_cancelled_close_without_a_local_receipt_is_durably_indeterminate" $ withTemp $ \tmp -> do
    rig <- newRig (tmp </> "rig") rigOptions {optPlans = [plan {planBlock = True}]}
    inv <- invocation rig "close-without-receipt"
    ledger <- openSqlitePiOperationLedger (ledgerAt tmp)
    runtime <- newPiRecoveredRuntimeWith (surfaceWith rig (replaceReceipt (\_ -> pure Nothing))) (sqlitePiOperationLedger ledger)
    op <- startRecovered runtime inv
    waitUntil 2 (not . null <$> readIORef rig.factory.clients)
    readIORef rig.factory.clients >>= \case
      client : _ -> timeout 2000000 (readMVar client.entered) `shouldReturn` Just ()
      [] -> expectationFailure "no client"
    (recoveredOperation op).cancel "stop" `shouldReturn` CancellationRequested
    cleanup <- closeOp op
    record <- lookupRecord ledger inv.operationId
    (.outcome) (ok (recordSettlement record)) `shouldBe` TurnIndeterminate
    (record.terminationCode, record.outputReference) `shouldBe` (Just "close-indeterminate", Nothing)
    closeOp op `shouldReturn` cleanup
    raises (waitOp op Nothing) RuntimeProtocolError "operation-closed"
    ledgerClose ledger

  it "test_replayed_operation_obeys_close_then_wait_contract" $ withTemp $ \tmp -> do
    let path = ledgerAt tmp
    rig <- newRig (tmp </> "rig") rigOptions
    inv <- invocation rig "replay-close"
    ledger <- openSqlitePiOperationLedger path
    runtime <- newPiRecoveredRuntime rig.adapter (sqlitePiOperationLedger ledger)
    op <- startRecovered runtime inv
    _ <- waitOp op (Just 3)
    _ <- closeOp op
    ledgerClose ledger

    reopened <- openSqlitePiOperationLedger path
    replay <- newPiRecoveredRuntime rig.adapter (sqlitePiOperationLedger reopened) >>= (`startRecovered` inv)
    cleanup <- closeOp replay
    closeOp replay `shouldReturn` cleanup
    raises (waitOp replay Nothing) RuntimeProtocolError "operation-closed"
    ledgerClose reopened

  it "test_lost_ledger_acknowledgements_retry_without_changing_the_result" $ withTemp $ \tmp -> do
    rig <- newRig (tmp </> "rig") rigOptions
    inv <- invocation rig "lost-ledger-ack"
    ledger <- openSqlitePiOperationLedger (ledgerAt tmp)
    lossy <- lossyLedger (sqlitePiOperationLedger ledger)
    op <- newPiRecoveredRuntime rig.adapter lossy.ledger >>= (`startRecovered` inv)
    writeIORef lossy.settleArmed True
    raises (waitOp op (Just 3)) StorageError "lost settlement acknowledgement"
    result <- waitOp op (Just 3)
    ok . recordSettlement <$> lookupRecord ledger inv.operationId `shouldReturn` result

    writeIORef lossy.upgradeArmed True
    raises (closeOp op) StorageError "lost cleanup acknowledgement"
    cleanup <- closeOp op
    cleanupVerified cleanup `shouldBe` True
    (.cleanup) <$> lookupRecord ledger inv.operationId `shouldReturn` cleanup.disposition
    ledgerClose ledger

  it "test_durable_fingerprint_ignores_reconstructed_fences_but_rejects_stable_route_change" $ withTemp $ \tmp -> do
    rig <- newRig tmp rigOptions
    inv <- invocation rig "fingerprint"
    original <- fingerprintFor rig inv
    let view = inv.connection
        reconstructed =
          reinvoke
            inv
            inv.prompt
            ConnectionView
              { identity = view.identity
              , status = view.status
              , authorityEpoch = view.authorityEpoch + 1
              , stateVersion = view.stateVersion + 1
              , stateDigest = view.stateDigest
              }
            (inv.grantEpoch + 1)
    fingerprintFor rig reconstructed `shouldReturn` original
    changed <- fingerprintFor rig (withIdentity inv (reidentify view.identity "connection-other" view.identity.profile))
    changed `shouldNotBe` original

  it "test_start_failure_and_ledger_cleanup_recovery_are_safe_and_secret_free" $ withTemp $ \tmp -> do
    let path = ledgerAt tmp
    rig <- newRig (tmp </> "rig") rigOptions
    inv <- invocation rig "failure"
    ledger <- openSqlitePiOperationLedger path
    runtime <- newPiRecoveredRuntimeWith (surfaceWith rig (replaceStart (\_ -> throwAgenticus RuntimeError prompt))) (sqlitePiOperationLedger ledger)
    raises (startRecovered runtime inv) RuntimeProtocolError "runtime-start-failed"
    record <- lookupRecord ledger inv.operationId
    (record.phase, record.cleanup) `shouldBe` (PhaseSettled, RuntimeCleanupNotCreated)
    ledgerClose ledger
    body <- B.readFile path
    let config = rigConfig rig
    forM_ [TE.encodeUtf8 prompt, auth, TE.encodeUtf8 sessionCanary, TE.encodeUtf8 (T.pack config.workingDirectory)] $ \secret ->
      (secret, secret `B.isInfixOf` body) `shouldBe` (secret, False)
    reopened <- openSqlitePiOperationLedger path
    (.cleanup) <$> lookupRecord reopened inv.operationId `shouldReturn` RuntimeCleanupNotCreated
    ledgerClose reopened

-- ---------------------------------------------------------------------------
-- Lone surrogate escapes in helper frames (not in the reference)

-- | The reference admits a lone surrogate escape into a helper frame and
-- fails on, or forwards, the member that holds it (@divergences/pi.md@,
-- item 6). Each case forges one such frame.
surrogateSpecs :: Spec
surrogateSpecs = describe "lone surrogate escapes in helper frames (not in the reference)" $ do
  let clientFor options tmp node scenario = do
        rig <- newRig tmp rigOptions
        inv <- (.invocation) <$> invoke rig ("surrogate-" <> scenario) invocationOptions {invCapabilities = Just [WorkspaceRead]}
        privateRoot <- operationRoot rig (T.unpack ("surrogate-" <> scenario <> "-operation"))
        privateDirectory privateRoot
        let helper = tmp </> "lone-surrogate-helper.mjs"
        fixture "lone_surrogate_helper.mjs" >>= writeText helper . T.replace "__SCENARIO__" scenario
        client <- helperArgs rig node "/ignored" privateRoot inv Nothing (Just keyText) Nothing Nothing >>= newSubprocessClientWith options helper
        pure (client, inv, privateRoot)
      finish (client, _, privateRoot) = do
        closeClient client `shouldReturn` True
        removeDirectoryRecursive privateRoot
      calls inv = map (\e -> (e.method, e.ok, e.category)) <$> evidence inv.gateway

  it "forwards tool_call parameters that hold one to the Hands gateway" $ withNode $ \node -> withTemp $ \tmp -> do
    opened@(client, inv, _) <- clientFor subprocessOptions tmp node "params"
    result <- runFor client inv
    fmap (.text) result.candidate `shouldBe` Just "answer"
    calls inv `shouldReturn` [(Nothing, False, Just CategoryPath)]
    finish opened

  it "fails a tool_result that echoes one as helper-pipe-failed (str.encode())" $ withNode $ \node -> withTemp $ \tmp -> do
    let echo _ = Object [("echo", String (J.surrogateText 0xD800))]
    opened@(client, inv, _) <- clientFor subprocessOptions {modelData = echo} tmp node "echo"
    raises (runFor client inv) RuntimeProtocolError "helper-pipe-failed"
    finish opened

  it "raises the tool_call identity's encode failure, which no except catches" $ withNode $ \node -> withTemp $ \tmp -> do
    opened@(client, inv, _) <- clientFor subprocessOptions tmp node "identity"
    raises (runFor client inv) ValueError "surrogates not allowed"
    calls inv `shouldReturn` []
    finish opened

  forM_
    [ ("text", "malformed-complete")
    , ("method", "malformed-tool-call")
    , ("type", "unknown-frame")
    , ("member", "frame-order")
    , ("code", "malformed-failed")
    ]
    $ \(scenario, code) ->
      it (T.unpack ("fails one in the " <> scenario <> " as " <> code)) $ withNode $ \node -> withTemp $ \tmp -> do
        opened@(client, inv, _) <- clientFor subprocessOptions tmp node scenario
        raises (runFor client inv) RuntimeProtocolError code
        calls inv `shouldReturn` []
        finish opened

-- ---------------------------------------------------------------------------
-- Spawning (not in the reference)

spawnSpecs :: Spec
spawnSpecs = describe "spawnPiped (not in the reference)" $ do
  it "starts the helper like Popen(close_fds=True, start_new_session=True)" $ do
    -- An inheritable descriptor (dup2 clears close-on-exec) the child must
    -- not see.
    devNull <- openFd "/dev/null" ReadOnly defaultFileFlags
    inherited <- dupTo devNull (Fd 50) `finally` closeFd devNull
    flip finally (closeFd inherited) $ do
      Just (i, o, e, process) <- spawnPiped "/bin/sh" ["-c", "ps -o pgid= -p $$; ls /dev/fd"] Nothing (Just [("PATH", "/bin:/usr/bin")])
      Just pid <- getPid process
      hClose i
      output <- B.hGetContents o
      _ <- B.hGetContents e
      waitForProcess process `shouldReturn` ExitSuccess
      case T.lines (TE.decodeUtf8 output) of
        group : descriptors -> do
          -- A new session leads its own process group.
          read (T.unpack (T.strip group)) `shouldBe` (fromIntegral pid :: Int)
          -- stdio, and the two descriptors @ls@ opens itself (3 and 4, the
          -- same listing as under CPython's Popen(close_fds=True)).
          take 3 descriptors `shouldBe` ["0", "1", "2"]
          filter (`notElem` ["0", "1", "2", "3", "4"]) descriptors `shouldBe` []
        [] -> expectationFailure "no output"
  it "gives the parent non-blocking pipe ends, as the process package does" $ do
    -- Reads and writes then wait in the IO manager rather than in a safe
    -- foreign call per chunk, which cost each Amp Turn about 75 µs.
    Just (i, o, e, process) <- spawnPiped "/bin/cat" [] Nothing (Just [("PATH", "/bin:/usr/bin")])
    descriptors <- mapM handleToFd [i, o, e]
    mapM (`queryFdOption` NonBlockingRead) descriptors `shouldReturn` [True, True, True]
    mapM_ closeFd descriptors
    waitForProcess process `shouldReturn` ExitSuccess
  it "reports a helper that cannot be started" $ do
    started <- spawnPiped "/nonexistent/helper" [] Nothing Nothing
    isNothing started `shouldBe` True
