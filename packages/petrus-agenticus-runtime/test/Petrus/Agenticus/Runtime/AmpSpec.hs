{-# LANGUAGE RecordWildCards #-}

-- | @tests/petrus/agenticus/runtime/test_amp.py@: Amp A1 provider-managed
-- runtime conformance without provider use.
--
-- The reference's async-generator @execute@ fakes are 'AmpEventStream'
-- records here, and its @monkeypatch@ of the probe environment is an
-- 'AmpProbeHooks' value. The last group (not in the reference) drives the
-- official sidecar against the fake @amp_sdk@ in @test/fixtures/amp@.
module Petrus.Agenticus.Runtime.AmpSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM, forM_, unless, void)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Attachment.Binding (AttachmentBinding (..), BindingSettlement (..))
import Petrus.Agenticus.Attachment.Episode (AttachmentSettlement (..), EpisodeAttachment, episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor (..), DescriptorKind (..), capabilityDescriptor, descriptorIdentity)
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot, mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody (ConnectionStatus (..), ConnectionView (..), mkConnectionIdentity)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Program.Descriptor (AgentProgramDescriptor (..), ContinuationRequirement (..), ProgramOwnership (..))
import Petrus.Agenticus.Runtime.Amp
import Petrus.Agenticus.Runtime.Installation (InstalledComponent (..), ProbeDisposition (..), ProbeIssue (..), RuntimeInstallation (..), RuntimeProbeResult (..))
import Petrus.Agenticus.Runtime.Operation (RuntimeCleanupDisposition (..), RuntimeOperationCleanup (..))
import Petrus.Agenticus.Runtime.Profiles (ampA1)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..))
import Petrus.Agenticus.Thread.Continuation (Continuation (..), ContinuationDescriptor (..), ContinuationState (..), mkContinuation)
import Petrus.Agenticus.Thread.Identity (mkContinuationId, mkEpisodeId, mkThreadId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.TestSupport.Python (pythonExecutable, pythonJson)
import System.Directory (doesFileExist, makeAbsolute)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

threadId', otherThreadId, promptCanary, errorCanary :: Text
threadId' = "T-11111111-1111-1111-1111-111111111111"
otherThreadId = "T-22222222-2222-2222-2222-222222222222"
promptCanary = "prompt-canary-never-render"
errorCanary = "provider-error-canary-never-render"

hostFencedEffect :: CapabilityDescriptor
hostFencedEffect = capabilityDescriptor (descriptorIdentity KindEffect "host.fenced" 1) ["effect.host-fenced"] []

event :: [(Text, Json)] -> AmpEvent
event = jsonEvent

successfulEvents :: Text -> Text -> [AmpEvent]
successfulEvents thread text =
  [ event [("type", String "system"), ("subtype", String "init"), ("session_id", String thread)]
  , event
      [ ("type", String "assistant")
      , ("session_id", String thread)
      , ("message", Object [("content", Array [Object [("type", String "text"), ("text", String text)]])])
      ]
  , event
      [ ("type", String "result")
      , ("subtype", String "success")
      , ("session_id", String thread)
      , ("is_error", Bool False)
      , ("result", String text)
      ]
  ]

-- ---------------------------------------------------------------------------
-- Custody fakes

data Continuations = Continuations {values :: IORef (Map Text AmpContinuationPayloadV1)}

newContinuations :: IO Continuations
newContinuations = Continuations <$> newIORef Map.empty

continuationOperations :: Continuations -> AmpContinuationOperations
continuationOperations c =
  AmpContinuationOperations
    { store = \operationId payload -> do
        let reference = "amp-continuation-" <> operationId
        existing <- Map.lookup reference <$> readIORef c.values
        case existing of
          Just e | e /= payload -> throwAgenticus RuntimeError "conflicting synthetic Continuation"
          _ -> modifyIORef' c.values (Map.insert reference payload)
        pure reference
    , load = \reference ->
        Map.lookup reference <$> readIORef c.values >>= maybe (throwAgenticus KeyError reference) pure
    }

data Turns = Turns {values :: IORef (Map Text (Text, Text))}

newTurns :: IO Turns
newTurns = Turns <$> newIORef Map.empty

turnOperations :: Turns -> AmpTurnOperations
turnOperations t =
  AmpTurnOperations $ \operationId thread finalText -> do
    let reference = "amp-turn-" <> operationId
        value = (thread, finalText)
    existing <- Map.lookup reference <$> readIORef t.values
    case existing of
      Just e | e /= value -> throwAgenticus RuntimeError "conflicting synthetic Turn"
      _ -> modifyIORef' t.values (Map.insert reference value)
    pure reference

-- ---------------------------------------------------------------------------
-- Fixtures

connection :: ConnectionView
connection = ConnectionView (ok (mkConnectionIdentity "amp-connection" "amp" "safe-account-fingerprint" "platform-managed")) StatusReady 3 4 Nothing

snapshot :: CapabilityDescriptor -> ResolutionSnapshot
snapshot runtime =
  ok . mkResolutionSnapshot 1 $
    [ runtime
    , ampConnectionCapabilities
    , ampProgramCapabilities
    , ampProviderManagedHands
    , ampProviderManagedTerritory
    , ampContinuationCapabilities
    , hostFencedEffect
    ]

data Attached = Attached {attachment :: EpisodeAttachment, binding :: AmpProviderManagedBinding}

attach :: Text -> Maybe ResolutionSnapshot -> IO Attached
attach episode selected = do
  binding <- newAmpProviderManagedBinding
  attachment <-
    newEpisodeAttachment
      (ok (mkEpisodeId episode))
      (fromMaybe (snapshot ampA1) selected)
      (ampAttachmentBinding binding)
      ("attachment-" <> episode)
      100
      episodeOptions {Episode.clock = pure 1}
  pure (Attached attachment binding)

data Request = Request
  { episode :: Text
  , turn :: Text
  , operation :: Text
  , attached :: Maybe Attached
  , continuation :: Maybe Continuation
  , prompt :: Text
  }

request :: Request
request = Request "episode-1" "turn-1" "operation-1" Nothing Nothing promptCanary

invocation :: Request -> IO AmpRuntimeInvocation
invocation r = do
  a <- maybe (attach r.episode Nothing) pure r.attached
  pure . ok $
    newAmpRuntimeInvocation r.operation (ok (mkEpisodeId r.episode)) (ok (mkTurnId r.turn)) r.prompt connection a.attachment a.binding r.continuation

continuationFor :: Text -> Continuation
continuationFor reference =
  ok (mkContinuation (ok (mkContinuationId "continuation-1")) (ok (mkThreadId "agenticus-thread-1")) ampContinuationDescriptor reference ContinuationInUse)

-- | @ready_probe@: the qualified CLI, SDK version and protocol surface.
data Probe = Probe {version :: IORef (Maybe Text)}

readyHooks :: IO (Probe, AmpProbeHooks)
readyHooks = do
  version <- newIORef (Just ampSdkVersion)
  let hooks =
        AmpProbeHooks
          { resolveCli = pure (Just ["/qualified/amp"])
          , installedSdkVersion = readIORef version
          , runCli = \argv ->
              pure $
                if last argv == "--version"
                  then ampCliVersion <> " (released safely)\n"
                  else "--orb-execute --project --stream-json"
          , sdkProtocolReady = pure True
          }
  pure (Probe version, hooks)

-- | A stream over a fixed list whose finalizers run the given actions.
listStream :: [AmpEvent] -> IO () -> IO () -> IO AmpEventStream
listStream events onAbort onClose = do
  remaining <- newIORef events
  pure
    AmpEventStream
      { next = atomicModifyIORef' remaining $ \case
          [] -> ([], Nothing)
          e : rest -> (rest, Just e)
      , abort = onAbort
      , close = onClose
      }

data Rig = Rig
  { adapter :: AmpRuntimeAdapter
  , continuations :: Continuations
  , turns :: Turns
  , calls :: IORef [(Text, [(Text, Json)])]
  , probe :: Probe
  }

rigWith :: AmpExecute -> IO (Continuations, Turns, Probe, AmpRuntimeAdapter)
rigWith execute = do
  continuations <- newContinuations
  turns <- newTurns
  (probe, hooks) <- readyHooks
  adapter <-
    newAmpRuntimeAdapter
      (ampRuntimeConfig "henriquebastos/petrus")
      (ampContinuationCodec (continuationOperations continuations))
      (turnOperations turns)
      AmpAdapterOptions {sdkExecute = execute, clock = pure 1, hooks}
  result <- probeAmp adapter
  result.disposition `shouldBe` ProbeReady
  pure (continuations, turns, probe, adapter)

rig :: Maybe [AmpEvent] -> IO Rig
rig events = do
  calls <- newIORef []
  let execute prompt options = do
        modifyIORef' calls (<> [(prompt, options)])
        listStream (fromMaybe (successfulEvents threadId' "safe result") events) (pure ()) (pure ())
  (continuations, turns, probe, adapter) <- rigWith execute
  pure Rig {..}

start :: AmpRuntimeAdapter -> Request -> IO AmpOperation
start adapter r = invocation r >>= startAmp adapter

waitFor :: AmpOperation -> Double -> IO RuntimeTurnSettlement
waitFor o = waitAmpOperation o . Just

protocolCode :: Text -> IO a -> Expectation
protocolCode code action =
  try action >>= \case
    Left (e :: AgenticusError) -> e.errorMessage `shouldBe` ("runtime protocol error: " <> code)
    Right _ -> expectationFailure ("expected " <> T.unpack code)

raisesWith :: ErrorClass -> Text -> Either AgenticusError a -> Expectation
raisesWith cls fragment = \case
  Left e -> do
    e.errorClass `shouldBe` cls
    (e.errorMessage, fragment `T.isInfixOf` e.errorMessage) `shouldBe` (e.errorMessage, True)
  Right _ -> expectationFailure ("expected " <> show cls)

-- | A stream that yields @system/init@ and then blocks until interrupted.
blockingStream :: IO () -> IO () -> IO () -> IO AmpEventStream
blockingStream entered onAbort onClose = do
  step <- newIORef (0 :: Int)
  forever' <- newEmptyMVar :: IO (MVar ())
  pure
    AmpEventStream
      { next = do
          n <- atomicModifyIORef' step (\k -> (k + 1, k))
          if n == 0
            then pure (Just (event [("type", String "system"), ("subtype", String "init"), ("session_id", String threadId')]))
            else entered >> takeMVar forever' >> pure Nothing
      , abort = onAbort
      , close = onClose
      }

waitFlag :: MVar () -> Double -> IO Bool
waitFlag flag seconds = isJust <$> timeout (round (seconds * 1000000)) (readMVar flag)

set' :: MVar () -> IO ()
set' flag = void (tryPutMVar flag ())

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "test_amp" $ do
  it "test_descriptors_freeze_provider_owned_amp_native_profile" $ do
    ampProgram.ownership `shouldBe` ProviderOwned
    ampProgram.acceptsFreshStart `shouldBe` True
    ampProgram.producedContinuation `shouldBe` Just ampContinuationDescriptor.identity
    map (.identity) ampProgram.acceptedContinuations `shouldBe` [ampContinuationDescriptor.identity]
    (ampProgram.ownsSteering, ampProgram.ownsEvaluation) `shouldBe` (False, False)
    ampA1.offers `shouldBe` Set.fromList ["archetype.a1", "loop.provider-owned", "topology.provider-managed"]

  it "test_continuation_payload_and_codec_are_exact_and_opaque" $ do
    continuations <- newContinuations
    let codec = ampContinuationCodec (continuationOperations continuations)
        payload = ok (mkAmpContinuationPayloadV1 threadId')
    reference <- ampCodecStore codec "operation-1" payload
    let value = continuationFor reference
    ampPayloadFromData (ampPayloadToData payload) `shouldBe` Right payload
    ampCodecLoad codec value `shouldReturn` payload
    show value `shouldNotContain` T.unpack threadId'
    raisesWith ValueError "exact versioned" $
      ampPayloadFromData (Object [("schema_version", Int 1), ("thread_id", String threadId'), ("project", String "foreign")])
    raisesWith ValueError "T-prefixed" (mkAmpContinuationPayloadV1 "session-1")

  it "test_config_and_invocation_hide_prompt_and_reject_implicit_profile_changes" $ do
    let config = ok (newAmpRuntimeConfig (ampRuntimeConfig "henriquebastos/petrus"))
    requested <- invocation request
    T.unpack (renderAmpRuntimeInvocation requested) `shouldNotContain` T.unpack promptCanary
    (config.sdkVersion, config.cliVersion) `shouldBe` (ampSdkVersion, ampCliVersion)
    raisesWith ValueError "built-in mode" (newAmpRuntimeConfig (ampRuntimeConfig "henriquebastos/petrus") {mode = "custom-fallback"})
    raisesWith ValueError "exact qualified" (newAmpRuntimeConfig (ampRuntimeConfig "henriquebastos/petrus") {sdkVersion = "latest"})
    a <- attach "episode-1" Nothing
    let foreign' = ConnectionView (ok (mkConnectionIdentity "connection" "openai" "fingerprint" "api-key")) StatusReady 1 1 Nothing
    raisesWith ValueError "platform-managed" $
      newAmpRuntimeInvocation "operation-1" (ok (mkEpisodeId "episode-1")) (ok (mkTurnId "turn-1")) "safe" foreign' a.attachment a.binding Nothing

  it "test_probe_requires_exact_sdk_cli_and_orb_protocol_before_start" $ do
    current <- rig Nothing
    result <- probeAmp current.adapter
    result.disposition `shouldBe` ProbeReady
    let installation = fromMaybe (error "installation") result.installation
    map (.version) installation.components `shouldBe` [ampCliVersion, ampSdkVersion]
    installation.capabilities `shouldBe` Set.fromList ["runtime.cancel", "runtime.continue", "runtime.orb", "runtime.provider-managed"]
    writeIORef current.probe.version (Just "0.1.6")
    mismatch <- probeAmp current.adapter
    mismatch.disposition `shouldBe` ProbeIncompatible
    map (.code) mismatch.issues `shouldBe` ["version-mismatch"]
    protocolCode "runtime-not-ready" (start current.adapter request)

  it "test_probe_reports_absent_sdk_without_importing_or_materializing" $ do
    continuations <- newContinuations
    turns <- newTurns
    imported <- newIORef False
    (_, hooks) <- readyHooks
    adapter <-
      newAmpRuntimeAdapter
        (ampRuntimeConfig "henriquebastos/petrus")
        (ampContinuationCodec (continuationOperations continuations))
        (turnOperations turns)
        ampAdapterOptions {hooks = hooks {installedSdkVersion = pure Nothing, sdkProtocolReady = writeIORef imported True >> pure True}}
    result <- probeAmp adapter
    result.disposition `shouldBe` ProbeNotInstalled
    map (.code) result.issues `shouldBe` ["sdk-not-installed"]
    readIORef imported `shouldReturn` False

  it "test_new_turn_uses_only_orb_project_policy_and_settles_one_batch" $ do
    current <- rig (Just (successfulEvents threadId' "safe\x1b[31m result\x1b[0m\x00"))
    a <- attach "episode-1" Nothing
    operation <- start current.adapter request {attached = Just a}
    result <- waitFor operation 2
    result.outcome `shouldBe` TurnCompleted
    (result.acceptedAppends, result.terminationCode) `shouldBe` (1, "turn-completed")
    result.outputReference `shouldBe` Just "amp-turn-operation-1"
    result.continuationReference `shouldBe` Just "amp-continuation-operation-1"
    readIORef current.calls
      `shouldReturn` [
                       ( promptCanary
                       ,
                         [ ("executor", String "orb")
                         , ("project", String "henriquebastos/petrus")
                         , ("mode", String "medium")
                         , ("visibility", String "private")
                         , ("no_archive_after_execute", Bool False)
                         ]
                       )
                     ]
    (Map.lookup "amp-turn-operation-1" <$> readIORef current.turns.values) `shouldReturn` Just (threadId', "safe result\xfffd")
    (fmap payloadThreadId . Map.lookup "amp-continuation-operation-1" <$> readIORef current.continuations.values)
      `shouldReturn` Just threadId'
    -- The binding is provider-managed: no Motus lease behind it.
    isJust (Episode.episodeBinding a.attachment).motus `shouldBe` False
    settled <- Episode.settle a.attachment 10
    (settled.settlement.verified, settled.archive) `shouldBe` (True, "")
    cleanup <- closeAmpOperation operation
    cleanup.disposition `shouldBe` RuntimeCleanupClean
    protocolCode "operation-closed" (waitAmpOperation operation Nothing)

  it "test_continue_loads_only_exact_amp_thread_and_reuses_provider_placement" $ do
    current <- rig Nothing
    first <- start current.adapter request >>= (`waitFor` 2)
    let previous = continuationFor (fromMaybe "" first.continuationReference)
    nextAttachment <- attach "episode-2" Nothing
    second <-
      start current.adapter request {episode = "episode-2", turn = "turn-2", operation = "operation-2", attached = Just nextAttachment, continuation = Just previous, prompt = "second prompt"}
        >>= (`waitFor` 2)
    second.outcome `shouldBe` TurnCompleted
    calls <- readIORef current.calls
    lookup "continue_thread" (snd (calls !! 1)) `shouldBe` Just (String threadId')
    lookup "executor" (snd (calls !! 1)) `shouldBe` Just (String "orb")
    (fmap payloadThreadId . Map.lookup (fromMaybe "" second.continuationReference) <$> readIORef current.continuations.values)
      `shouldReturn` Just threadId'

  let initEvent thread = event [("type", String "system"), ("subtype", String "init"), ("session_id", String thread)]
      malformed =
        [ ("events0-missing-system-init", [event [("type", String "assistant"), ("session_id", String threadId')]], "missing-system-init")
        , ("events1-malformed-thread-id", [initEvent "not-a-thread"], "malformed-thread-id")
        , ("events2-event-thread-mismatch", [initEvent threadId', event [("type", String "assistant"), ("session_id", String otherThreadId)]], "event-thread-mismatch")
        , ("events3-terminal-result-missing", [initEvent threadId'], "terminal-result-missing")
        ,
          ( "events4-duplicate-terminal"
          , successfulEvents threadId' "safe result"
              <> [event [("type", String "result"), ("subtype", String "success"), ("session_id", String threadId'), ("is_error", Bool False), ("result", String "again")]]
          , "duplicate-terminal"
          )
        ]
  forM_ malformed $ \(name, events, code) ->
    it ("test_malformed_or_incomplete_stream_fails_without_an_append[" <> name <> "]") $ do
      current <- rig (Just events)
      operation <- start current.adapter request
      result <- waitFor operation 2
      result.outcome `shouldBe` TurnFailed
      (result.acceptedAppends, result.terminationCode) `shouldBe` (0, code)
      (result.outputReference, result.continuationReference) `shouldBe` (Nothing, Nothing)
      cleanup <- closeAmpOperation operation
      cleanup.disposition `shouldBe` RuntimeCleanupUnverified

  it "test_provider_error_is_typed_without_retaining_raw_diagnostic" $ do
    let events =
          [ initEvent threadId'
          , event
              [ ("type", String "result")
              , ("subtype", String "error_during_execution")
              , ("session_id", String threadId')
              , ("is_error", Bool True)
              , ("error", String errorCanary)
              ]
          ]
    current <- rig (Just events)
    operation <- start current.adapter request
    result <- waitFor operation 2
    (result.outcome, result.terminationCode) `shouldBe` (TurnFailed, "provider-failed")
    (result.acceptedAppends, result.outputReference) `shouldBe` (0, Nothing)
    result.continuationReference `shouldBe` Just "amp-continuation-operation-1"
    cleanup <- closeAmpOperation operation
    show result `shouldNotContain` T.unpack errorCanary
    show cleanup `shouldNotContain` T.unpack errorCanary
    cleanup.disposition `shouldBe` RuntimeCleanupClean

  it "test_protocol_failure_finalizes_the_sdk_stream" $ do
    finalized <- newEmptyMVar
    let execute _ _ =
          listStream [initEvent threadId', event [("type", String "assistant"), ("session_id", String otherThreadId)]] (set' finalized) (set' finalized)
    (_, _, _, adapter) <- rigWith execute
    operation <- start adapter request
    result <- waitFor operation 2
    result.terminationCode `shouldBe` "event-thread-mismatch"
    waitFlag finalized 2 `shouldReturn` True

  it "test_cancellation_is_idempotent_but_remote_provider_cleanup_stays_unverified" $ do
    entered <- newEmptyMVar
    stopped <- newEmptyMVar
    finishCleanup <- newEmptyMVar
    let execute _ _ =
          blockingStream
            (set' entered)
            (waitFlag finishCleanup 2 >>= \held -> if held then set' stopped else pure ())
            (pure ())
    (_, _, _, adapter) <- rigWith execute
    operation <- start adapter request
    waitFlag entered 2 `shouldReturn` True
    cancelAmpOperation operation "stop" `shouldReturn` CancellationRequested
    cancelAmpOperation operation "stop" `shouldReturn` CancellationAlreadyRequested
    set' finishCleanup
    result <- waitFor operation 2
    waitFlag stopped 2 `shouldReturn` True
    (result.outcome, result.acceptedAppends) `shouldBe` (TurnCancelled, 0)
    cancelAmpOperation operation "late" `shouldReturn` CancellationTooLate
    cleanup <- closeAmpOperation operation
    cleanup.disposition `shouldBe` RuntimeCleanupUnverified
    cleanup.code `shouldBe` "provider-state-uncertain"

  it "test_wait_timeout_does_not_change_operation_and_active_close_is_refused" $ do
    entered <- newEmptyMVar
    let execute _ _ = blockingStream (set' entered) (pure ()) (pure ())
    (_, _, _, adapter) <- rigWith execute
    operation <- start adapter request
    waitFlag entered 2 `shouldReturn` True
    try (waitFor operation 0.01) >>= \case
      Left (e :: AgenticusError) -> e.errorClass `shouldBe` TimeoutError
      Right _ -> expectationFailure "expected TimeoutError"
    protocolCode "operation-active" (closeAmpOperation operation)
    cancelAmpOperation operation "cleanup" `shouldReturn` CancellationRequested
    ((.outcome) <$> waitFor operation 2) `shouldReturn` TurnCancelled

  it "test_operation_identity_is_lookup_first_and_conflicts_fail_before_provider_call" $ do
    current <- rig Nothing
    a <- attach "episode-1" Nothing
    first <- start current.adapter request {attached = Just a}
    again <- start current.adapter request {attached = Just a}
    ampOperationId again `shouldBe` ampOperationId first
    ((.outcome) <$> waitFor again 2) `shouldReturn` TurnCompleted
    ((.outcome) <$> waitFor first 2) `shouldReturn` TurnCompleted
    length <$> readIORef current.calls `shouldReturn` 1
    protocolCode "operation-conflict" (start current.adapter request {prompt = "different", attached = Just a})
    length <$> readIORef current.calls `shouldReturn` 1

  it "test_wrong_catalog_snapshot_fails_before_sdk_execution" $ do
    current <- rig Nothing
    let wrong = capabilityDescriptor (descriptorIdentity KindRuntime "amp.lookalike" 1) (Set.toList ampA1.offers) ampA1.requires
    a <- attach "episode-1" (Just (snapshot wrong))
    protocolCode "resolution-mismatch" (start current.adapter request {attached = Just a})
    readIORef current.calls `shouldReturn` []

  it "test_amp_defining_module_imports_without_optional_sdk" $ do
    -- No SDK is linked: the official options name an interpreter that does
    -- not exist, and building the adapter and descriptors never runs it.
    continuations <- newContinuations
    turns <- newTurns
    let absent = ampSidecar {python = "/nonexistent/python"}
    adapter <-
      newAmpRuntimeAdapter
        (ampRuntimeConfig "henriquebastos/petrus")
        (ampContinuationCodec (continuationOperations continuations))
        (turnOperations turns)
        ampAdapterOptions {sdkExecute = officialExecute absent, hooks = officialProbeHooks absent}
    renderAmpRuntimeAdapter adapter `shouldReturn` "AmpRuntimeAdapter(project='henriquebastos/petrus', mode='medium', ready=False)"
    ampProgram.identity `shouldBe` ampProgramCapabilities.identity

  describe "official sidecar (not in the reference)" $ do
    let fixtureSidecar = do
          python <- pythonExecutable
          root <- makeAbsolute ("test" </> "fixtures" </> "amp")
          pure ampSidecar {python, searchPath = [root], grace = 5}

    -- divergences/amp.md item 1: every stream of a pool shares one sidecar
    -- process, which upstream (one interpreter, no sidecar) has no
    -- counterpart of. Each test runs its own pool.
    describe "shared sidecar: many streams on one process" $ do
      let pooled pool = (\s -> s {pool}) <$> fixtureSidecar
          adapterFor sidecar project = do
            continuations <- newContinuations
            turns <- newTurns
            (_, hooks) <- readyHooks
            adapter <-
              newAmpRuntimeAdapter
                (ampRuntimeConfig project)
                (ampContinuationCodec (continuationOperations continuations))
                (turnOperations turns)
                AmpAdapterOptions {sdkExecute = officialExecute sidecar, clock = pure 1, hooks}
            void (probeAmp adapter)
            pure (turns, adapter)
          named n = request {episode = "episode-" <> n, turn = "turn-" <> n, operation = "operation-" <> n, prompt = "prompt-" <> n}

      it "runs concurrent streams on one sidecar, each settling on its own" $ withSystemTempDirectory "petrus-amp" $ \tmp ->
        withSidecarPool 5 $ \pool -> do
          sidecar <- pooled pool
          let marker = tmp </> "cancelled"
          (_, blocking) <- adapterFor sidecar (T.pack ("block:" <> marker))
          blocked <- start blocking (named "blocked")
          (turns, adapter) <- adapterFor sidecar "henriquebastos/petrus"
          -- Three streams run to completion while a fourth blocks mid-turn.
          finished <-
            concurrentlyAll
              [ do
                  operation <- start adapter (named name)
                  result <- waitFor operation 30
                  cleanup <- closeAmpOperation operation
                  pure (result, cleanup)
              | name <- ["a", "b", "c"]
              ]
          forM_ finished $ \(result, cleanup) -> do
            result.outcome `shouldBe` TurnCompleted
            cleanup.disposition `shouldBe` RuntimeCleanupClean
          stored <- readIORef turns.values
          Map.keys stored `shouldMatchList` ["amp-turn-operation-" <> name | name <- ["a", "b", "c"]]
          -- Each stream echoed its own prompt.
          forM_ ["a", "b", "c"] $ \name ->
            fmap (T.isInfixOf ("prompt-" <> name) . snd) (Map.lookup ("amp-turn-operation-" <> name) stored) `shouldBe` Just True
          cancelAmpOperation blocked "stop" `shouldReturn` CancellationRequested
          result <- waitFor blocked 30
          result.outcome `shouldBe` TurnCancelled
          doesFileExist marker `shouldReturn` True
          length <$> sidecarPoolPids pool `shouldReturn` 1

      it "settles every stream of a sidecar that dies mid-turn, and the next stream respawns it" $ withSystemTempDirectory "petrus-amp" $ \tmp ->
        withSidecarPool 5 $ \pool -> do
          sidecar <- pooled pool
          -- A stream waiting mid-turn, past every cancellation.
          let marker = tmp </> "waiting"
          (_, blocking) <- adapterFor sidecar (T.pack ("stuck:" <> marker))
          blocked <- start blocking (named "blocked")
          awaitFile marker
          original <- sidecarPoolPids pool
          length original `shouldBe` 1
          -- The SDK crashes the sidecar process under one stream: both that
          -- turn and the other stream's settle as upstream settles an SDK
          -- stream that raises (client-failed).
          (_, dying) <- adapterFor sidecar "die"
          died <- start dying (named "die") >>= (`waitFor` 30)
          blockedResult <- waitFor blocked 30
          (died.outcome, died.terminationCode) `shouldBe` (TurnFailed, "client-failed")
          (blockedResult.outcome, blockedResult.terminationCode) `shouldBe` (TurnFailed, "client-failed")
          -- The next stream starts a new sidecar.
          (_, adapter) <- adapterFor sidecar "henriquebastos/petrus"
          next <- start adapter (named "next") >>= (`waitFor` 30)
          next.outcome `shouldBe` TurnCompleted
          respawned <- sidecarPoolPids pool
          (length respawned, any (`elem` original) respawned) `shouldBe` (1, False)

      it "reports a stream stuck past the release grace as uncertain while the others proceed" $ withSystemTempDirectory "petrus-amp" $ \tmp ->
        withSidecarPool 2 $ \pool -> do
          sidecar <- (\s -> s {grace = 1}) <$> pooled pool
          let marker = tmp </> "stuck"
          (_, stuckAdapter) <- adapterFor sidecar (T.pack ("stuck:" <> marker))
          stuck <- start stuckAdapter (named "stuck")
          awaitFile marker
          cancelAmpOperation stuck "stop" `shouldReturn` CancellationRequested
          -- While the stuck stream's teardown hangs in the sidecar, another
          -- stream on the same sidecar runs a whole turn.
          (_, adapter) <- adapterFor sidecar "henriquebastos/petrus"
          other <- start adapter (named "other") >>= (`waitFor` 30)
          other.outcome `shouldBe` TurnCompleted
          stuckResult <- waitFor stuck 30
          stuckResult.outcome `shouldBe` TurnCancelled
          ((.code) <$> closeAmpOperation stuck) `shouldReturn` "provider-state-uncertain"
          -- Closing the pool ends the sidecar although a teardown is stuck
          -- in it: past the pool's grace, it is killed.
          timeout 10000000 (closeSidecarPool pool 2) `shouldReturn` Just ()
          sidecarPoolPids pool `shouldReturn` []

    it "reads the SDK version and protocol through the sidecar" $ do
      sidecar <- fixtureSidecar
      let hooks = officialProbeHooks sidecar
      hooks.installedSdkVersion `shouldReturn` Just ampSdkVersion
      hooks.sdkProtocolReady `shouldReturn` True
      (officialProbeHooks sidecar {searchPath = ["/nonexistent"]}).sdkProtocolReady `shouldReturn` False

    it "runs one Orb turn through the official execute" $ do
      sidecar <- fixtureSidecar
      (continuations, turns, _, adapter) <- rigWith (officialExecute sidecar)
      operation <- start adapter request
      result <- waitFor operation 30
      result.outcome `shouldBe` TurnCompleted
      stored <- Map.lookup "amp-turn-operation-1" <$> readIORef turns.values
      fmap fst stored `shouldBe` Just threadId'
      fmap (T.isInfixOf "\"executor\": \"orb\"" . snd) stored `shouldBe` Just True
      fmap (T.isInfixOf promptCanary . snd) stored `shouldBe` Just True
      Map.size <$> readIORef continuations.values `shouldReturn` 1
      ((.disposition) <$> closeAmpOperation operation) `shouldReturn` RuntimeCleanupClean

    it "injects the cancellation into the SDK generator" $ withSystemTempDirectory "petrus-amp" $ \tmp -> do
      sidecar <- fixtureSidecar
      let marker = tmp </> "cancelled"
      continuations <- newContinuations
      turns <- newTurns
      (_, hooks) <- readyHooks
      adapter <-
        newAmpRuntimeAdapter
          (ampRuntimeConfig (T.pack ("block:" <> marker)))
          (ampContinuationCodec (continuationOperations continuations))
          (turnOperations turns)
          AmpAdapterOptions {sdkExecute = officialExecute sidecar, clock = pure 1, hooks}
      void (probeAmp adapter)
      operation <- start adapter request
      -- Let the sidecar deliver system/init and block.
      threadDelay 500000
      cancelAmpOperation operation "stop" `shouldReturn` CancellationRequested
      result <- waitFor operation 30
      result.outcome `shouldBe` TurnCancelled
      doesFileExist marker `shouldReturn` True
      ((.code) <$> closeAmpOperation operation) `shouldReturn` "provider-state-uncertain"

    -- divergences/amp.md: upstream reads each event's size and attributes
    -- in the SDK's own process, where reading can raise; the sidecar
    -- reports where it raised and admission meets it where upstream would.
    it "settles events that raise where upstream reads them as the reference does" $ do
      sidecar <- fixtureSidecar
      root <- makeAbsolute ("test" </> "fixtures" </> "amp")
      script <- makeAbsolute ("test" </> "fixtures" </> "amp-raising-reference.py")
      reference <- pythonJson "import runpy, sys\nsys.argv = sys.argv[1:]\nrunpy.run_path(sys.argv[0], run_name='__main__')" [script, root]
      scenarios <- case reference of
        Object members -> pure members
        other -> fail ("unexpected reference output: " <> show other)
      length scenarios `shouldSatisfy` (>= 20)
      forM_ scenarios $ \(name, expected) -> do
        continuations <- newContinuations
        turns <- newTurns
        (_, hooks) <- readyHooks
        adapter <-
          newAmpRuntimeAdapter
            (ampRuntimeConfig ("raise:" <> name))
            (ampContinuationCodec (continuationOperations continuations))
            (turnOperations turns)
            AmpAdapterOptions {sdkExecute = officialExecute sidecar, clock = pure 1, hooks}
        void (probeAmp adapter)
        operation <- start adapter request
        result <- waitFor operation 30
        cleanup <- closeAmpOperation operation
        let outcome = case result.outcome of
              TurnCompleted -> "completed"
              TurnFailed -> "failed"
              TurnCancelled -> "cancelled"
              TurnIndeterminate -> "indeterminate" :: Text
        (name, Array [String outcome, Int result.acceptedAppends, String result.terminationCode, String cleanup.code])
          `shouldBe` (name, expected)

-- | Run the actions on their own threads and collect their results in
-- order, rethrowing the first failure.
concurrentlyAll :: [IO a] -> IO [a]
concurrentlyAll actions = do
  boxes <- forM actions $ \action -> do
    box <- newEmptyMVar
    _ <- forkIO (try action >>= putMVar box)
    pure box
  forM boxes $ \box -> takeMVar box >>= either (\(e :: SomeException) -> throwIO e) pure

-- | Wait (up to ten seconds) until a fake SDK has touched @path@.
awaitFile :: FilePath -> IO ()
awaitFile path = go (200 :: Int)
  where
    go 0 = expectationFailure ("never touched: " <> path)
    go n = doesFileExist path >>= \found -> unless found (threadDelay 50000 >> go (n - 1))
