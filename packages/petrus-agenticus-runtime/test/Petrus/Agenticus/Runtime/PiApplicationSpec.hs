-- | @tests/petrus/agenticus/runtime/test_pi_application.py@: the
-- deterministic acceptance matrix for the application-owned Pi A5 boundary.
--
-- The rig keeps the reference's shape: one Episode attachment over a local
-- process provider relabelled to the qualified territory ('newTerritory'),
-- the production Motus workspace adapter and gateway, scripted clients for
-- the adapter matrix, and the verbatim helper (under the system @node@) for
-- the framed-protocol tests.
module Petrus.Agenticus.Runtime.PiApplicationSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Exception (finally, throwIO, try)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding (MotusAttachmentBinding, bindingExecution, motusBinding, openMotusBinding)
import Petrus.Agenticus.Attachment.Episode (EpisodeAttachment, episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (DescriptorKind (..), capabilityDescriptor, descriptorIdentity)
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot, mkResolutionSnapshot, snapshotDescriptor)
import Petrus.Agenticus.Connection.Custody (ConnectionStatus (..), ConnectionView (..), mkConnectionIdentity)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Conformance qualified as Conformance
import Petrus.Agenticus.Hands.Contract
  ( RejectionCategory (..)
  , ToolMethod (..)
  , mkToolError
  , mkToolResult
  , toolMethodText
  , toolResultToData
  , toolResultToModelData
  )
import Petrus.Agenticus.Hands.Gateway (CallEvidence (..), GatewayCounters (..), HandsGateway, counters)
import Petrus.Agenticus.Hands.Gateway qualified as Gateway
import Petrus.Agenticus.Hands.Grants (GrantSpec (..), closeGrant, grantSpec, openGrant)
import Petrus.Agenticus.Hands.Workspace (defaultCommandTimeout, newMotusWorkspaceAdapter, workspaceHandsAdapter)
import Petrus.Agenticus.Program.Descriptor (ProgramOwnership (..))
import Petrus.Agenticus.Runtime.Installation (ProbeDisposition (..), mkInstalledComponent, mkRuntimeInstallation)
import Petrus.Agenticus.Runtime.Operation (RuntimeCleanupDisposition (..), RuntimeOperationCleanup, runtimeProtocolError, runtimeProtocolErrorCode)
import Petrus.Agenticus.Runtime.Pi (piApiKeyCatalog, piSdkSourceCommit)
import Petrus.Agenticus.Runtime.Pi.Internal qualified as Pi
import Petrus.Agenticus.Runtime.PiApplication.Internal
import Petrus.Agenticus.Runtime.PiSupport
  ( FakeCustody (..)
  , Territory (..)
  , custodyOperations
  , custodyView
  , effect
  , fixture
  , newFakeCustody
  , newTerritory
  , ok
  , raises
  , recordedKinds
  , withTemp
  )
import Petrus.Agenticus.Runtime.Profiles (piApplicationA5E2b, piApplicationA5Gondolin)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement)
import Petrus.Agenticus.Thread.Continuation (Continuation, ContinuationDescriptor, ContinuationState (..), continuationDescriptor, mkContinuation)
import Petrus.Agenticus.Thread.Identity (mkContinuationId, mkEpisodeId, mkThreadId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Execution (EnvironmentProvider (..), defaultSpec)
import Petrus.Motus.Execution.Archive (workspaceArchive)
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, findExecutable, makeAbsolute)
import Petrus.TestSupport.Python (pythonJson)
import System.Exit (ExitCode (..))
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode, readProcessWithExitCode)
import System.Timeout (timeout)
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Continuations and turns

data Continuations = Continuations
  { values :: IORef (Map Text PiApplicationContinuationPayloadV1)
  , failing :: IORef Bool
  }

newContinuations :: IO Continuations
newContinuations = Continuations <$> newIORef Map.empty <*> newIORef False

continuationOperations :: Continuations -> PiApplicationContinuationOperations
continuationOperations c =
  PiApplicationContinuationOperations
    { store = \operationId payload -> do
        broken <- readIORef c.failing
        when broken $ throwAgenticus RuntimeError "store failed"
        let reference = "continuation-" <> operationId
        known <- readIORef c.values
        case Map.lookup reference known of
          Just existing | existing /= payload -> throwAgenticus RuntimeError "conflict"
          _ -> modifyIORef' c.values (Map.insert reference payload)
        pure reference
    , load = \reference ->
        Map.lookup reference <$> readIORef c.values
          >>= maybe (throwAgenticus KeyError (T.pack (show reference))) pure
    }

data Turns = Turns
  { values :: IORef (Map Text PiApplicationStepPayloadV1)
  , failing :: IORef Bool
  }

newTurns :: IO Turns
newTurns = Turns <$> newIORef Map.empty <*> newIORef False

turnOperations :: Turns -> PiApplicationTurnOperations
turnOperations t =
  PiApplicationTurnOperations
    { storeTurn = \operationId payload -> do
        broken <- readIORef t.failing
        when broken $ throwAgenticus RuntimeError "store failed"
        modifyIORef' t.values (Map.insert operationId payload)
        pure ("turn-" <> operationId)
    }

-- ---------------------------------------------------------------------------
-- Scripted clients

data Plan = Plan
  { method :: Maybe ToolMethod
  , params :: Json
  , planText :: Text
  , planError :: Maybe Text
  , block :: Bool
  , clean :: Bool
  , syntheticWrite :: Bool
  }

plan :: Plan
plan = Plan Nothing (Object []) "ok" Nothing False True False

toolPlan :: ToolMethod -> [(Text, Json)] -> Plan
toolPlan m p = plan {method = Just m, params = Object p}

data Client = Client
  { plan :: Plan
  , entered :: MVar ()
  }

runClient :: Client -> Maybe PiApplicationContinuationPayloadV1 -> IO () -> ApplicationClient
runClient c prior afterRun =
  ApplicationClient
    { run = \gateway inv current deadline -> do
        _ <- tryPutMVar c.entered ()
        let spin = do
              live <- current
              now <- getMonotonicTime
              when (c.plan.block && live && now < deadline) (threadDelay 2000 >> spin)
        spin
        mapM_ (throwIO . runtimeProtocolError) c.plan.planError
        live <- current
        unless live $ throwIO (runtimeProtocolError "cancelled")
        now <- getMonotonicTime
        when (now >= deadline) $ throwIO (runtimeProtocolError "deadline-exceeded")
        results <- case c.plan.method of
          Nothing -> pure []
          Just m -> do
            coords <- Episode.coordinates inv.attachment
            let callId = "call-" <> inv.operationId
            result <-
              if c.plan.syntheticWrite
                then
                  pure . ok $
                    mkToolResult callId coords.attachmentId coords.attachmentEpoch False Nothing $
                      Just (ok (mkToolError CategoryWrite "application guard blocked workspace write"))
                else
                  Gateway.submit
                    gateway
                    ( Object
                        [ ("version", Int 1)
                        , ("call_id", String callId)
                        , ("episode_id", String coords.episodeId)
                        , ("attachment_id", String coords.attachmentId)
                        , ("attachment_epoch", Int coords.attachmentEpoch)
                        , ("grant_epoch", Int inv.grantEpoch)
                        , ("method", String (toolMethodText m))
                        , ("params", c.plan.params)
                        ]
                    )
            pure [result]
        let previous = case J.parseJson J.surrogateRefusingLoads (maybe "[]" (.transcriptJson) prior) of
              Right (Array items) -> items
              _ -> []
            messages =
              previous
                <> [ Object [("role", String "user"), ("content", String inv.observation)]
                   , Object [("role", String "assistant"), ("content", String c.plan.planText)]
                   ]
            transcript = ok (J.dumps J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"} (Array messages))
        afterRun
        pure ApplicationCandidate {text = c.plan.planText, transcript, results}
    , close = pure c.plan.clean
    }

data Factory = Factory
  { plans :: IORef [Plan]
  , calls :: IORef [ApplicationClientArgs]
  , clients :: IORef [Client]
  , afterRun :: IORef (IO ())
  -- ^ The reference's wrapped @Client.run@.
  }

newFactory :: [Plan] -> IO Factory
newFactory plans' =
  Factory <$> newIORef (if null plans' then [plan] else plans') <*> newIORef [] <*> newIORef [] <*> newIORef (pure ())

factoryRecord :: Factory -> ApplicationFactory
factoryRecord f = ApplicationFactory $ \args -> do
  modifyIORef' f.calls (<> [args])
  next <- atomicModifyIORef' f.plans $ \case
    p : rest -> (rest, p)
    [] -> ([], error "IndexError: pop from empty list")
  entered <- newEmptyMVar
  let client = Client {plan = next, entered}
  modifyIORef' f.clients (<> [client])
  hook <- readIORef f.afterRun
  pure (runClient client args.prior hook)

-- ---------------------------------------------------------------------------
-- Rigs

snapshot :: Text -> ResolutionSnapshot
snapshot profile =
  ok . mkResolutionSnapshot 1 $
    [ if profile == "gondolin" then piApplicationA5Gondolin else piApplicationA5E2b
    , piApplicationConnectionCapabilities
    , piApplicationProgramCapabilities
    , piApplicationHands
    , capabilityDescriptor (descriptorIdentity KindTerritory ("motus." <> profile) 1) ["territory." <> profile] []
    , piApplicationContinuationCapabilities
    , effect
    ]

data Rig = Rig
  { profile :: Text
  , territory :: Territory
  , binding :: MotusAttachmentBinding
  , attachment :: EpisodeAttachment
  , gateway :: HandsGateway
  , custody :: FakeCustody
  , continuations :: Continuations
  , turns :: Turns
  , factory :: Factory
  , adapter :: PiApplicationRuntimeAdapter
  , working :: FilePath
  }

-- | What a test fixes on the adapter before it exists (the reference
-- assigns @_config@, @_clock@ and @_binding_current@ afterwards).
data RigTweaks = RigTweaks
  { tweakConfig :: PiApplicationRuntimeConfig -> PiApplicationRuntimeConfig
  , tweakClock :: Maybe (IO Double)
  , tweakHooks :: ApplicationAdapterHooks
  }

noTweaks :: RigTweaks
noTweaks = RigTweaks id Nothing noApplicationHooks

newRig :: FilePath -> Text -> [Plan] -> Double -> IO Rig
newRig = newRigWith noTweaks

newRigWith :: RigTweaks -> FilePath -> Text -> [Plan] -> Double -> IO Rig
newRigWith tweaks root profile plans wallTimeout = do
  let working = root </> "working"
      runtime = root </> "runtime"
      source = root </> "source"
  mapM_ (createDirectoryIfMissing True) [working, runtime, source]
  setFileMode runtime 0o700
  writeFile (source </> "message.txt") "before"
  writeFile (source </> "verify.sh") "#!/bin/sh\ngrep -q after message.txt\n"
  territory <- newTerritory profile
  archive <- workspaceArchive source
  binding <- openMotusBinding territory.provider ("territory-" <> profile) defaultSpec archive "input"
  now <- getMonotonicTime
  attachment <- newEpisodeAttachment (ok (mkEpisodeId "episode")) (snapshot profile) (motusBinding binding) ("attachment-" <> profile) (now + 10) episodeOptions
  execution <- bindingExecution binding
  workspace <- newMotusWorkspaceAdapter territory.provider execution ["/bin/sh", "verify.sh"] defaultCommandTimeout
  gateway <- Episode.gateway attachment (workspaceHandsAdapter workspace) 256
  custody <- newFakeCustody "api-key" "anthropic"
  continuations <- newContinuations
  turns <- newTurns
  factory <- newFactory plans
  let component = ok (mkInstalledComponent "pi-agent-core" "0.83.0" "test")
      prepare descriptor r =
        r
          { installation = Just (ok (mkRuntimeInstallation descriptor.identity 1 [component] "test" "test" Set.empty))
          , node = Just "/fake"
          , coding = Just "/fake"
          , core = Just "/fake"
          , ai = Just "/fake"
          }
  adapter <-
    newPiApplicationRuntimeAdapterWith
      ApplicationAdapterOptions
        { clock = fromMaybe getMonotonicTime tweaks.tweakClock
        , factory = Just (factoryRecord factory)
        , hooks = tweaks.tweakHooks
        , prepare
        }
      ( tweaks.tweakConfig
          (piApplicationRuntimeConfig "anthropic" "claude-sonnet-4-5" profile working runtime)
            { hostId = "host"
            , wallTimeout
            , cancellationGrace = 0.03
            }
      )
      (piApplicationContinuationCodec (continuationOperations continuations))
      (turnOperations turns)
      (applicationCustody (custodyOperations custody))
  pure Rig {profile, territory, binding, attachment, gateway, custody, continuations, turns, factory, adapter, working}

newRig' :: FilePath -> Text -> [Plan] -> IO Rig
newRig' root profile plans = newRig root profile plans 1

data InvocationOptions = InvocationOptions
  { optContinuation :: Maybe Continuation
  , optObservation :: Maybe Text
  , optGrantEpoch :: Maybe Integer
  , optConnection :: Maybe ConnectionView
  }

defaults :: InvocationOptions
defaults = InvocationOptions Nothing Nothing Nothing Nothing

-- | @rig.invocation(name, capabilities, ...)@.
invocationWith :: Rig -> Text -> [ToolMethod] -> InvocationOptions -> IO PiApplicationRuntimeInvocation
invocationWith rig name capabilities o = do
  let deadline = Episode.episodeDeadline rig.attachment
  grant <-
    openGrant
      (Episode.grants rig.attachment)
      (grantSpec capabilities deadline 8)
        { specWritablePaths = ["message.txt", "continuity.txt"]
        , specAllowedArgv = [["/bin/cat", "message.txt"]]
        }
  view <- maybe (custodyView rig.custody) pure o.optConnection
  newPiApplicationRuntimeInvocation
    PiApplicationRuntimeInvocation
      { operationId = name
      , episodeId = ok (mkEpisodeId "episode")
      , turnId = ok (mkTurnId ("turn-" <> name))
      , observation = maybe name id o.optObservation
      , connection = view
      , attachment = rig.attachment
      , gateway = rig.gateway
      , grantEpoch = maybe grant.grantEpoch id o.optGrantEpoch
      , continuation = o.optContinuation
      }

invocationFor :: Rig -> Text -> [ToolMethod] -> IO PiApplicationRuntimeInvocation
invocationFor rig name capabilities = invocationWith rig name capabilities defaults

-- | @rig.run(name, capabilities, continuation)@.
runRig :: Rig -> Text -> [ToolMethod] -> Maybe Continuation -> IO (RuntimeTurnSettlement, RuntimeOperationCleanup)
runRig rig name capabilities continuation = do
  inv <- invocationWith rig name capabilities defaults {optContinuation = continuation}
  operation <- startApplication rig.adapter inv
  result <- waitApplicationOperation operation (Just 2)
  cleanup <- closeApplicationOperation operation
  pure (result, cleanup)

claimedWith :: ContinuationDescriptor -> ContinuationState -> Text -> Continuation
claimedWith descriptor state reference =
  ok (mkContinuation (ok (mkContinuationId ("id-" <> reference))) (ok (mkThreadId "thread")) descriptor reference state)

claimed :: Text -> Continuation
claimed = claimedWith piApplicationContinuationDescriptor ContinuationInUse

settledVerified :: Rig -> IO Bool
settledVerified rig = (.settlement.verified) <$> Episode.settle rig.attachment 30

viewWith :: Text -> Text -> ConnectionView
viewWith provider profile =
  ConnectionView
    { identity = ok (mkConnectionIdentity "connection" provider "account" profile)
    , status = StatusReady
    , authorityEpoch = 3
    , stateVersion = 4
    , stateDigest = Nothing
    }

requireNode :: IO FilePath
requireNode = findExecutable "node" >>= maybe (expectationFailure "node is required" >> error "unreachable") pure

newPrivateRoot :: FilePath -> String -> IO FilePath
newPrivateRoot tmp name = do
  let root = tmp </> ("private-" <> name)
  createDirectory root
  setFileMode root 0o700
  pure root

-- | The three JavaScript modules of the framed-protocol tests.
writeModules :: FilePath -> FilePath -> IO (FilePath, FilePath, FilePath)
writeModules tmp coreFixture = do
  let coding = tmp </> "coding.mjs"
      core = tmp </> "core.mjs"
      ai = tmp </> "ai.mjs"
  forM_ [(coding, "application_coding.mjs"), (core, coreFixture), (ai, "application_ai.mjs")] $ \(path, name) ->
    fixture name >>= B.writeFile path . TE.encodeUtf8
  pure (coding, core, ai)

transcriptMessages :: ByteString -> [Json]
transcriptMessages raw = case J.parseJson J.surrogateRefusingLoads raw of
  Right (Array items) -> items
  _ -> error "transcript is not an array"

member :: Text -> Json -> Json
member name = \case
  Object fields -> maybe Null id (lookup name fields)
  _ -> Null

-- | Signal @started@, then wait for @released@ (the reference's
-- @assert release.wait(2)@).
stall :: MVar () -> MVar () -> IO ()
stall started released = do
  _ <- tryPutMVar started ()
  waited <- timeout 2000000 (readMVar released)
  when (isNothing waited) $ throwAgenticus (OtherError "AssertionError") "release did not arrive"

-- ---------------------------------------------------------------------------
-- Specs

spec :: Spec
spec = describe "test_pi_application" $ do
  descriptorSpecs
  episodeSpecs
  framedSpecs
  boundarySpecs
  surrogateSpecs
  settlementSpecs
  publicationSpecs
  packageSpecs

descriptorSpecs :: Spec
descriptorSpecs = do
  it "test_exact_identities_capabilities_ownership_and_snapshots" $ do
    piApplicationProgram.ownership `shouldBe` HarnessOwned
    piApplicationProgram.identity `shouldBe` descriptorIdentity KindProgram "pi.application-owned" 1
    (piApplicationProgram.ownsSteering && piApplicationProgram.ownsEvaluation) `shouldBe` True
    piApplicationProgramCapabilities.offers `shouldBe` Set.fromList ["program.application-owned"]
    piApplicationConnectionCapabilities.offers `shouldBe` Set.fromList ["connection.pi-compatible"]
    piApplicationHands.offers `shouldBe` Set.fromList ["hands.capability-scoped"]
    forM_ [("gondolin", piApplicationA5Gondolin), ("e2b", piApplicationA5E2b)] $ \(profile, descriptor) -> do
      let selected = snapshot profile
      snapshotDescriptor KindRuntime selected `shouldBe` Just descriptor
      fmap (.identity.name) (snapshotDescriptor KindTerritory selected) `shouldBe` Just ("motus." <> profile)
      descriptor.offers `shouldBe` Set.fromList ["archetype.a5", "loop.application-owned", "topology.split"]

  forM_ piApiKeyCatalog $ \(provider, model) ->
    it (T.unpack ("test_api_key_direct_catalog_is_exact[" <> provider <> "-" <> model <> "]")) $ withTemp $ \tmp -> do
      createDirectory (tmp </> "w")
      createDirectory (tmp </> "r")
      setFileMode (tmp </> "r") 0o700
      config <- newPiApplicationRuntimeConfig (piApplicationRuntimeConfig provider model "gondolin" (tmp </> "w") (tmp </> "r"))
      config.provider `shouldBe` provider

  forM_ ["subscription", "cc-patch-subscription", "openai-codex"] $ \profile ->
    it (T.unpack ("test_subscription_and_codex_profiles_are_rejected[" <> profile <> "]")) $ withTemp $ \tmp -> do
      rig <- newRig' tmp "gondolin" [plan]
      raises
        (invocationWith rig "foreign-authority" [] defaults {optConnection = Just (viewWith "anthropic" profile)})
        ValueError
        "only an api-key connection"
        `finally` void (Episode.settle rig.attachment 30)

  forM_ [("unknown", "x", "gondolin"), ("anthropic", "unknown", "gondolin"), ("anthropic", "claude-sonnet-4-5", "local")] $
    \(provider, model, profile) ->
      it (T.unpack ("test_unsupported_provider_model_or_territory[" <> provider <> "-" <> model <> "-" <> profile <> "]")) $
        withTemp $ \tmp -> do
          createDirectory (tmp </> "w")
          createDirectory (tmp </> "r")
          setFileMode (tmp </> "r") 0o700
          raises (newPiApplicationRuntimeConfig (piApplicationRuntimeConfig provider model profile (tmp </> "w") (tmp </> "r"))) ValueError ""

  it "test_shared_model_tool_result_projection_excludes_attachment_custody" $ do
    let result = ok (mkToolResult "call" "attachment-gondolin" 7 True (Just [("text", String "bounded")]) Nothing)
    toolResultToModelData result
      `shouldBe` Object [("version", Int 1), ("ok", Bool True), ("data", Object [("text", String "bounded")]), ("error", Null)]
    member "attachment_id" (toolResultToData result) `shouldBe` String "attachment-gondolin"
    member "epoch" (toolResultToData result) `shouldBe` Int 7
    let denied =
          ok . mkToolResult "denied" "attachment-e2b" 11 False Nothing $
            Just (ok (mkToolError CategoryWrite "application guard blocked workspace write"))
    toolResultToModelData denied
      `shouldBe` Object
        [ ("version", Int 1)
        , ("ok", Bool False)
        , ("data", Null)
        , ("error", Object [("category", String "write"), ("detail", String "application guard blocked workspace write")])
        ]

episodeSpecs :: Spec
episodeSpecs = do
  it "test_seven_separate_operations_drive_policy_and_real_gateway" $ withTemp $ \tmp -> do
    let plans =
          [ (toolPlan WorkspaceWrite [("path", String "message.txt"), ("content", String "after")]) {syntheticWrite = True}
          , toolPlan WorkspaceRead [("path", String "message.txt")]
          , toolPlan WorkspaceSearch [("query", String "before"), ("path", String "message.txt")]
          , toolPlan WorkspaceShell [("argv", Array [String "/bin/cat", String "message.txt"]), ("cwd", String ".")]
          , toolPlan WorkspaceWrite [("path", String "message.txt"), ("content", String "after")]
          , toolPlan WorkspaceTest []
          , plan {planText = "ES049_APP_E1_OK"}
          ]
    rig <- newRig' tmp "gondolin" plans
    policy <- Conformance.newSevenStepEpisodePolicy (Conformance.policyConfig (Episode.episodeAttachmentId rig.attachment) 1 "ES049_APP_E1_OK")
    continuation <- newIORef Nothing
    let capabilities = [[WorkspaceRead], [WorkspaceRead], [WorkspaceSearch], [WorkspaceShell], [WorkspaceWrite], [WorkspaceTest], []]
    forM_ (zip3 [0 :: Int ..] capabilities plans) $ \(index, granted, step) -> do
      _ <- Conformance.beginTurn policy
      let name = "op-" <> T.pack (show index)
      (result, cleanup) <- readIORef continuation >>= runRig rig name granted
      (result.outcome, cleanup.disposition) `shouldBe` (TurnCompleted, RuntimeCleanupClean)
      stored <- (Map.! name) <$> readIORef rig.turns.values
      forM_ stored.results $ \toolResult -> forM_ step.method $ \m -> Conformance.observe policy m toolResult
      ready <- Conformance.writeGrantReady policy
      when ready $ Conformance.noteGrantOpened policy
      _ <- Conformance.appendObservation policy
      writeIORef continuation (claimed <$> result.continuationReference)
    (.admitted) <$> Conformance.admitMarker policy "ES049_APP_E1_OK" `shouldReturn` True
    Conformance.policyTurns policy `shouldReturn` 7
    Conformance.policyAppends policy `shouldReturn` 7
    observed <- counters rig.gateway
    (observed.adapterEntries, observed.targetMutations) `shouldBe` (5, 1)
    length . filter (== "materialize") <$> recordedKinds rig.custody `shouldReturn` 7
    final <- (Map.! "continuation-op-6") <$> readIORef rig.continuations.values
    length (transcriptMessages final.transcriptJson) `shouldBe` 14
    void (Episode.settle rig.attachment 30)

  it "test_gondolin_settles_before_e2b_and_continuation_crosses_without_authority_leak" $ withTemp $ \tmp -> do
    e1 <- newRig' (tmp </> "e1") "gondolin" [plan {planText = "E1"}]
    (first, _) <- runRig e1 "e1" [] Nothing
    reference <- maybe (expectationFailure "no continuation" >> error "unreachable") pure first.continuationReference
    payload <- (Map.! reference) <$> readIORef e1.continuations.values
    settledVerified e1 `shouldReturn` True
    gone <- providerLookup e1.territory.provider "territory-gondolin"
    isNothing gone `shouldBe` True
    let e1Working = (applicationAdapterConfig e1.adapter).workingDirectory
    e2 <- newRigWith noTweaks {tweakConfig = \config -> config {workingDirectory = e1Working}} (tmp </> "e2") "e2b" [plan {planText = "E2"}] 1
    modifyIORef' e2.continuations.values (Map.insert reference payload)
    (second, _) <- runRig e2 "e2" [] (Just (claimed reference))
    secondReference <- maybe (expectationFailure "no continuation" >> error "unreachable") pure second.continuationReference
    stored <- (Map.! secondReference) <$> readIORef e2.continuations.values
    map (member "content") (transcriptMessages stored.transcriptJson) `shouldBe` map String ["e1", "E1", "e2", "E2"]
    let rendered = TE.decodeUtf8 stored.transcriptJson
    forM_ ["gondolin", "attachment-gondolin", "credential", "grant_epoch", "workspace"] $ \value ->
      (value, value `T.isInfixOf` rendered) `shouldBe` (value, False)

  it "test_closed_write_is_synthetic_and_crossing_flat" $ withTemp $ \tmp -> do
    rig <- newRig' tmp "gondolin" [(toolPlan WorkspaceWrite [("path", String "message.txt"), ("content", String "after")]) {syntheticWrite = True}]
    (result, _) <- runRig rig "blocked" [WorkspaceRead] Nothing
    stored <- (Map.! "blocked") <$> readIORef rig.turns.values
    case stored.results of
      [tool] -> fmap (.category) tool.resultError `shouldBe` Just CategoryWrite
      other -> expectationFailure ("expected one result, got " <> show (length other))
    observed <- counters rig.gateway
    (observed.adapterEntries, observed.stages, observed.commits, observed.targetMutations) `shouldBe` (0, 0, 0, 0)
    result.outcome `shouldBe` TurnCompleted

framedSpecs :: Spec
framedSpecs = do
  it "test_real_framed_helper_blocks_write_and_round_trips_permitted_read" $ withTemp $ \tmp -> do
    node <- requireNode
    helper <- piApplicationHelperPath
    (coding, core, ai) <- writeModules tmp "application_core_guard.mjs"
    let argsFor inv privateRoot config prior =
          ApplicationClientArgs
            { node
            , codingEntrypoint = coding
            , coreEntrypoint = core
            , aiEntrypoint = ai
            , privateRoot
            , config
            , invocation = inv
            , prior
            , apiKey = "credential-canary"
            }
        priorFor rig = do
          let config = applicationAdapterConfig rig.adapter
          pure (ok (mkPiApplicationContinuationPayloadV1 (applicationWorkingBinding config.workingDirectory) "[{\"role\":\"user\",\"content\":\"prior\"}]"))
    forM_ ["blocked", "read"] $ \observation -> do
      rig <- newRig' (tmp </> T.unpack observation) "gondolin" [plan]
      inv <- invocationWith rig observation [WorkspaceRead] defaults {optObservation = Just observation}
      prior <- priorFor rig
      privateRoot <- newPrivateRoot tmp (T.unpack observation)
      let config = applicationAdapterConfig rig.adapter
      client <- applicationSubprocessClient <$> newApplicationSubprocessClient helper (argsFor inv privateRoot config (Just prior))
      deadline <- (+ 2) <$> getMonotonicTime
      candidate <- client.run rig.gateway inv (pure True) deadline
      client.close `shouldReturn` True
      let transcript = transcriptMessages candidate.transcript
      map (member "content") (take 1 transcript) `shouldBe` [String "prior"]
      map (member "role") (drop 1 transcript) `shouldBe` map String ["user", "assistant"]
      observed <- counters rig.gateway
      case candidate.results of
        first : _
          | observation == "blocked" -> do
              fmap (.category) first.resultError `shouldBe` Just CategoryWrite
              (observed.adapterEntries, observed.stages, observed.commits, observed.targetMutations) `shouldBe` (0, 0, 0, 0)
          | otherwise -> (first.ok, observed.adapterEntries) `shouldBe` (True, 1)
        [] -> expectationFailure "expected a tool result"
      void (Episode.settle rig.attachment 30)

    rig <- newRig' (tmp </> "overflow") "gondolin" [plan]
    inv <- invocationWith rig "overflow" [WorkspaceRead] defaults {optObservation = Just "overflow"}
    privateRoot <- newPrivateRoot tmp "overflow"
    config <- newPiApplicationRuntimeConfig (applicationAdapterConfig rig.adapter) {maxToolCalls = 1}
    prior <- priorFor rig
    client <- applicationSubprocessClient <$> newApplicationSubprocessClient helper (argsFor inv privateRoot config (Just prior))
    deadline <- (+ 2) <$> getMonotonicTime
    raises (client.run rig.gateway inv (pure True) deadline) RuntimeProtocolError "protocol-failed"
    client.close `shouldReturn` True
    (.adapterEntries) <$> counters rig.gateway `shouldReturn` 1
    void (Episode.settle rig.attachment 30)

    full <- newRig' (tmp </> "full-result") "gondolin" [plan]
    fullInv <- invocationWith full "full-result" [WorkspaceRead] defaults {optObservation = Just "read"}
    fullRoot <- newPrivateRoot tmp "full-result"
    let fullConfig = applicationAdapterConfig full.adapter
    fullPrior <- priorFor full
    fullClient <-
      applicationSubprocessClient
        <$> newApplicationSubprocessClientWith
          ApplicationSubprocessOptions {modelData = toolResultToData}
          helper
          (argsFor fullInv fullRoot fullConfig (Just fullPrior))
    fullDeadline <- (+ 2) <$> getMonotonicTime
    raises (fullClient.run full.gateway fullInv (pure True) fullDeadline) RuntimeProtocolError "protocol-failed"
    fullClient.close `shouldReturn` True
    (.adapterEntries) <$> counters full.gateway `shouldReturn` 1
    void (Episode.settle full.attachment 30)

  it "test_real_framed_tool_projection_preserves_prefix_without_attachment_custody" $ withTemp $ \tmp -> do
    node <- requireNode
    helper <- piApplicationHelperPath
    (coding, core, ai) <- writeModules tmp "application_core_projection.mjs"
    state <- newIORef (Nothing, Nothing, Nothing)
    forM_ ["gondolin", "e2b"] $ \profile -> do
      (prior, accepted, priorAttachment) <- readIORef state
      rig <- newRig' (tmp </> T.unpack profile) profile [plan]
      inv <- invocationWith rig profile [WorkspaceRead] defaults {optObservation = Just profile}
      privateRoot <- newPrivateRoot tmp (T.unpack profile)
      let config = applicationAdapterConfig rig.adapter
      client <-
        applicationSubprocessClient
          <$> newApplicationSubprocessClient
            helper
            ApplicationClientArgs
              { node
              , codingEntrypoint = coding
              , coreEntrypoint = core
              , aiEntrypoint = ai
              , privateRoot
              , config
              , invocation = inv
              , prior
              , apiKey = "credential-canary"
              }
      deadline <- (+ 2) <$> getMonotonicTime
      candidate <- client.run rig.gateway inv (pure True) deadline
      client.close `shouldReturn` True
      let transcript = transcriptMessages candidate.transcript
          rendered = TE.decodeUtf8 candidate.transcript
          attachmentId = Episode.episodeAttachmentId rig.attachment
      forM_ accepted $ \previous -> take (length previous) transcript `shouldBe` previous
      projection <- case member "content" (transcript !! (length transcript - 2)) of
        Array (first : _) | String body <- member "text" first -> either (fail . show) pure (J.parseJson J.surrogateRefusingLoads (TE.encodeUtf8 body))
        other -> fail ("unexpected tool content " <> show other)
      projection
        `shouldBe` Object [("version", Int 1), ("ok", Bool True), ("data", Object [("content", String "before")]), ("error", Null)]
      coords <- Episode.coordinates rig.attachment
      case candidate.results of
        first : _ -> (first.attachmentId, first.epoch) `shouldBe` (attachmentId, coords.attachmentEpoch)
        [] -> expectationFailure "expected a tool result"
      (attachmentId `T.isInfixOf` rendered) `shouldBe` False
      forM_ priorAttachment $ \previous -> (previous `T.isInfixOf` rendered) `shouldBe` False
      let next = ok (mkPiApplicationContinuationPayloadV1 (applicationWorkingBinding config.workingDirectory) candidate.transcript)
      writeIORef state (Just next, Just transcript, Just (maybe attachmentId id priorAttachment))
      void (Episode.settle rig.attachment 30)

  it "test_real_protocol_rejects_post_terminal_and_post_abort_frames_before_gateway" $ withTemp $ \tmp -> do
    node <- requireNode
    let clientFor scriptFixture name = do
          let helper = tmp </> (name <> ".mjs")
          fixture scriptFixture >>= B.writeFile helper . TE.encodeUtf8
          rig <- newRig' (tmp </> name) "gondolin" [plan]
          inv <- invocationFor rig (T.pack name) [WorkspaceRead]
          privateRoot <- newPrivateRoot tmp name
          let config = applicationAdapterConfig rig.adapter
          client <-
            applicationSubprocessClient
              <$> newApplicationSubprocessClient
                helper
                ApplicationClientArgs
                  { node
                  , codingEntrypoint = "/unused/coding"
                  , coreEntrypoint = "/unused/core"
                  , aiEntrypoint = "/unused/ai"
                  , privateRoot
                  , config
                  , invocation = inv
                  , prior = Nothing
                  , apiKey = "credential-canary"
                  }
          pure (client, rig, inv)
    forM_
      [ ("application_post_terminal.mjs", "post-terminal", 2, "frame-order")
      , ("application_post_abort.mjs", "post-abort", 0.01, "deadline-exceeded")
      , ("application_noncanonical.mjs", "noncanonical", 2, "malformed-complete")
      ]
      $ \(script, name, budget, code) -> do
        (client, rig, inv) <- clientFor script name
        deadline <- (+ budget) <$> getMonotonicTime
        raises (client.run rig.gateway inv (pure True) deadline) RuntimeProtocolError code
        client.close `shouldReturn` True
        (.adapterEntries) <$> counters rig.gateway `shouldReturn` 0
        void (Episode.settle rig.attachment 30)

-- | The reference admits a lone surrogate escape into a helper frame and
-- fails on, or forwards, the member that holds it (@divergences/pi.md@,
-- item 6). Each case forges one such frame.
surrogateSpecs :: Spec
surrogateSpecs = describe "lone surrogate escapes in helper frames (not in the reference)" $ do
  let clientFor options tmp scenario = do
        node <- requireNode
        let name = "surrogate-" <> T.unpack scenario
            helper = tmp </> (name <> ".mjs")
        fixture "application_lone_surrogate.mjs" >>= B.writeFile helper . TE.encodeUtf8 . T.replace "__SCENARIO__" scenario
        rig <- newRig' (tmp </> name) "gondolin" [plan]
        inv <- invocationFor rig (T.pack name) [WorkspaceRead]
        privateRoot <- newPrivateRoot tmp name
        client <-
          applicationSubprocessClient
            <$> newApplicationSubprocessClientWith
              options
              helper
              ApplicationClientArgs
                { node
                , codingEntrypoint = "/unused/coding"
                , coreEntrypoint = "/unused/core"
                , aiEntrypoint = "/unused/ai"
                , privateRoot
                , config = applicationAdapterConfig rig.adapter
                , invocation = inv
                , prior = Nothing
                , apiKey = "credential-canary"
                }
        deadline <- (+ 2) <$> getMonotonicTime
        pure (client.run rig.gateway inv (pure True) deadline, client, rig)
      finish client rig = do
        client.close `shouldReturn` True
        void (Episode.settle rig.attachment 30)
      calls rig = map (\e -> (e.method, e.ok, e.category)) <$> Gateway.evidence rig.gateway

  it "forwards tool_call parameters that hold one to the Hands gateway" $ withTemp $ \tmp -> do
    (run, client, rig) <- clientFor applicationSubprocessOptions tmp "params"
    candidate <- run
    candidate.text `shouldBe` "done"
    calls rig `shouldReturn` [(Nothing, False, Just CategoryPath)]
    finish client rig

  it "fails a tool_result that echoes one as helper-pipe-failed (str.encode())" $ withTemp $ \tmp -> do
    let echo _ = Object [("echo", String (J.surrogateText 0xD800))]
    (run, client, rig) <- clientFor ApplicationSubprocessOptions {modelData = echo} tmp "echo"
    raises run RuntimeProtocolError "helper-pipe-failed"
    finish client rig

  it "raises the tool_call identity's encode failure, which no except catches" $ withTemp $ \tmp -> do
    (run, client, rig) <- clientFor applicationSubprocessOptions tmp "identity"
    raises run ValueError "surrogates not allowed"
    calls rig `shouldReturn` []
    finish client rig

  forM_
    [ ("text", "malformed-complete")
    , ("transcript", "malformed-complete")
    , ("method", "malformed-tool-call")
    , ("type", "frame-order")
    , ("member", "frame-order")
    , ("code", "frame-order")
    ]
    $ \(scenario, code) ->
      it (T.unpack ("fails one in the " <> scenario <> " as " <> code)) $ withTemp $ \tmp -> do
        (run, client, rig) <- clientFor applicationSubprocessOptions tmp scenario
        raises run RuntimeProtocolError code
        calls rig `shouldReturn` []
        finish client rig

-- | The settlement edges where the reference raises something other than
-- @RuntimeProtocolError@ (a helper outliving the grace, a list or dict in a
-- set-membership test), against the pinned reference running the same
-- forged helper (@test/fixtures/pi/application-settlement-reference.py@).
-- Each scenario is @[exception class, settlement code, TypeError message]@,
-- the code being what @_execute@ assigns while the operation is current.
settlementSpecs :: Spec
settlementSpecs =
  it "settles helper-exit timeouts and unhashable frame members as the reference does" $ withTemp $ \tmp -> do
    node <- requireNode
    source <- makeAbsolute ("test" </> "fixtures" </> "pi" </> "application_settlement.mjs")
    script <- makeAbsolute ("test" </> "fixtures" </> "pi" </> "application-settlement-reference.py")
    let referenceRoot = tmp </> "reference"
    createDirectory referenceRoot
    reference <-
      pythonJson
        "import runpy, sys\nsys.argv = sys.argv[1:]\nrunpy.run_path(sys.argv[0], run_name='__main__')"
        [script, source, node, referenceRoot]
    scenarios <- case reference of
      Object members -> pure members
      other -> fail ("unexpected reference output: " <> show other)
    length scenarios `shouldBe` 12
    template <- fixture "application_settlement.mjs"
    forM_ scenarios $ \(scenario, expected) -> do
      let name = "settlement-" <> T.unpack scenario
          helper = tmp </> (name <> ".mjs")
      B.writeFile helper (TE.encodeUtf8 (T.replace "__SCENARIO__" scenario template))
      rig <- newRig' (tmp </> name) "gondolin" [plan]
      inv <- invocationFor rig (T.pack name) [WorkspaceRead]
      privateRoot <- newPrivateRoot tmp name
      client <-
        applicationSubprocessClient
          <$> newApplicationSubprocessClient
            helper
            ApplicationClientArgs
              { node
              , codingEntrypoint = "/unused/coding"
              , coreEntrypoint = "/unused/core"
              , aiEntrypoint = "/unused/ai"
              , privateRoot
              , config = applicationAdapterConfig rig.adapter
              , invocation = inv
              , prior = Nothing
              , apiKey = "credential-canary"
              }
      deadline <- (+ 2) <$> getMonotonicTime
      outcome <- try (client.run rig.gateway inv (pure True) deadline)
      let observed = case outcome of
            Right _ -> ["completed", "turn-completed", ""]
            Left e -> case runtimeProtocolErrorCode e of
              Just code -> ["RuntimeProtocolError", code, ""]
              Nothing ->
                [ errorClassName e.errorClass
                , "runtime-failed"
                , if e.errorClass == TypeError then e.errorMessage else ""
                ]
      (scenario, Array (map String observed)) `shouldBe` (scenario, expected)
      void client.close
      void (Episode.settle rig.attachment 30)

boundarySpecs :: Spec
boundarySpecs = do
  it "test_immutable_prior_transcript_plus_delta_and_payload_bounds" $ do
    let raw = "[{\"role\":\"user\",\"content\":\"prior\"}]" :: ByteString
        value = ok (mkPiApplicationContinuationPayloadV1 (T.replicate 64 "d") raw)
    value.transcriptJson `shouldBe` raw
    either (\e -> e.errorClass `isSubclassOf` ValueError) (const False) (mkPiApplicationContinuationPayloadV1 (T.replicate 64 "d") "[NaN]")
      `shouldBe` True
    fmap (const ()) (applicationTranscript (B.concat (replicate 10 "[] ")) 2 10)
      `shouldSatisfy` either (("byte bound" `T.isInfixOf`) . (.errorMessage)) (const False)
    fmap (const ()) (applicationTranscript "[{},{}]" 100 1)
      `shouldSatisfy` either (("message array" `T.isInfixOf`) . (.errorMessage)) (const False)
    forM_ ["W10", "W10==", "!!!!"] $ \encoded ->
      (encoded, either (const True) (\decoded -> b64Encode' decoded /= encoded) (pyB64Decode encoded)) `shouldBe` (encoded, True)

  it "test_foreign_continuation_project_binding_and_claim_state_rejected" $ withTemp $ \tmp -> do
    rig <- newRig' tmp "gondolin" [plan]
    let alien = continuationDescriptor (descriptorIdentity KindContinuation "foreign" 1) (descriptorIdentity KindProgram "foreign" 1)
    foreignInv <- invocationWith rig "foreign" [] defaults {optContinuation = Just (claimedWith alien ContinuationInUse "missing")}
    raises (startApplication rig.adapter foreignInv) ValueError ""
    modifyIORef' rig.continuations.values (Map.insert "bad" (ok (mkPiApplicationContinuationPayloadV1 (T.replicate 64 "e") "[]")))
    projectInv <- invocationWith rig "project" [] defaults {optContinuation = Just (claimed "bad")}
    raises (startApplication rig.adapter projectInv) RuntimeProtocolError "project-mismatch"
    stateInv <- invocationWith rig "state" [] defaults {optContinuation = Just (claimedWith piApplicationContinuationDescriptor ContinuationAvailable "bad")}
    raises (startApplication rig.adapter stateInv) RuntimeProtocolError "not-claimed"

  it "test_resolution_grant_runtime_and_connection_bindings_reject_stale" $ withTemp $ \tmp -> do
    rig <- newRig' tmp "gondolin" [plan]
    stale <- invocationWith rig "stale" [] defaults {optGrantEpoch = Just 999}
    raises (startApplication rig.adapter stale) RuntimeProtocolError "grant-mismatch"
    wrong <- invocationWith rig "provider" [] defaults {optConnection = Just (viewWith "openai" "api-key")}
    raises (startApplication rig.adapter wrong) RuntimeProtocolError "provider-mismatch"
    writeIORef rig.territory.drift (Just "e2b")
    territory <- invocationFor rig "territory" []
    raises (startApplication rig.adapter territory) RuntimeProtocolError "territory-lease"

  it "test_idempotent_redelivery_and_operation_conflict" $ withTemp $ \tmp -> do
    rig <- newRig' tmp "gondolin" [plan {block = True}]
    inv <- invocationFor rig "same" []
    first <- startApplication rig.adapter inv
    again <- startApplication rig.adapter inv
    (again == first) `shouldBe` True
    raises (startApplication rig.adapter inv {observation = "different"}) RuntimeProtocolError "operation-conflict"
    void (cancelApplicationOperation first "done")
    void (waitApplicationOperation first (Just 2))
    void (closeApplicationOperation first)

  it "test_cancellation_deadline_and_cleanup_failure_prevent_publication" $ withTemp $ \tmp -> do
    rig <- newRig' (tmp </> "cancel") "gondolin" [plan {block = True}]
    operation <- invocationFor rig "cancel" [] >>= startApplication rig.adapter
    entered <- timeout 1000000 $ do
      let firstClient = readIORef rig.factory.clients >>= \case
            client : _ -> pure client
            [] -> threadDelay 2000 >> firstClient
      client <- firstClient
      readMVar client.entered
    isJust entered `shouldBe` True
    cancelApplicationOperation operation "stop" `shouldReturn` CancellationRequested
    (.outcome) <$> waitApplicationOperation operation (Just 2) `shouldReturn` TurnCancelled
    (.disposition) <$> closeApplicationOperation operation `shouldReturn` RuntimeCleanupClean
    deadline <- newRig (tmp </> "deadline") "gondolin" [plan {block = True}] 0.02
    (expired, _) <- runRig deadline "deadline" [] Nothing
    expired.terminationCode `shouldBe` "deadline-exceeded"
    dirty <- newRig' (tmp </> "dirty") "gondolin" [plan {clean = False}]
    (result, cleanup) <- runRig dirty "dirty" [] Nothing
    (result.terminationCode, cleanup.disposition) `shouldBe` ("cleanup-unverified", RuntimeCleanupUnverified)
    Map.null <$> readIORef dirty.turns.values `shouldReturn` True
    Map.null <$> readIORef dirty.continuations.values `shouldReturn` True

  forM_ ["provider-failed", "protocol-failed", "terminal-missing", "frame-order", "malformed-frame"] $ \code ->
    it (T.unpack ("test_helper_failures_do_not_publish[" <> code <> "]")) $ withTemp $ \tmp -> do
      rig <- newRig' tmp "gondolin" [plan {planError = Just code}]
      (result, cleanup) <- runRig rig "failure" [] Nothing
      (result.outcome, result.terminationCode, result.outputReference, result.continuationReference)
        `shouldBe` (TurnFailed, code, Nothing, Nothing)
      cleanup.disposition `shouldBe` RuntimeCleanupClean
      Map.null <$> readIORef rig.turns.values `shouldReturn` True
      Map.null <$> readIORef rig.continuations.values `shouldReturn` True

publicationSpecs :: Spec
publicationSpecs = do
  it "test_application_a5_post_run_lease_drift_releases_authority_without_publication" $ withTemp $ \tmp -> do
    rig <- newRig' tmp "gondolin" [plan]
    inv <- invocationFor rig "post-run-stale" []
    writeIORef rig.factory.afterRun (writeIORef rig.territory.drift (Just "e2b"))
    operation <- startApplication rig.adapter inv
    result <- waitApplicationOperation operation (Just 2)
    result.outcome `shouldBe` TurnFailed
    result.terminationCode `shouldBe` "runtime-territory-lease-required"
    (result.outputReference, result.continuationReference) `shouldBe` (Nothing, Nothing)
    Map.null <$> readIORef rig.turns.values `shouldReturn` True
    Map.null <$> readIORef rig.continuations.values `shouldReturn` True
    recordedKinds rig.custody `shouldReturn` ["materialize", "release"]
    (.disposition) <$> closeApplicationOperation operation `shouldReturn` RuntimeCleanupClean
    writeIORef rig.territory.drift Nothing
    settledVerified rig `shouldReturn` True

  forM_ ["gondolin", "e2b"] $ \profile ->
    it (T.unpack ("test_application_a5_cancellation_wins_while_remote_publication_lookup_is_stalled[" <> profile <> "]")) $
      withTemp $ \tmp -> do
        (hooks, started, released) <- stallLookups
        rig <- newRigWith noTweaks {tweakHooks = hooks} tmp profile [plan] 1
        inv <- invocationFor rig "stalled-publication" []
        operation <- startApplication rig.adapter inv
        timeout 2000000 (readMVar started) >>= (`shouldBe` Just ())
        ( do
            waitStarted <- getMonotonicTime
            raises (waitApplicationOperation operation (Just 0.05)) TimeoutError "has not settled"
            waited <- subtract waitStarted <$> getMonotonicTime
            (waited < 0.2) `shouldBe` True
            cancelStarted <- getMonotonicTime
            cancelApplicationOperation operation "stop" `shouldReturn` CancellationRequested
            cancelled <- subtract cancelStarted <$> getMonotonicTime
            (cancelled < 0.2) `shouldBe` True
          )
          `finally` void (tryPutMVar released ())
        result <- waitApplicationOperation operation (Just 2)
        result.outcome `shouldBe` TurnCancelled
        (result.outputReference, result.continuationReference) `shouldBe` (Nothing, Nothing)
        Map.null <$> readIORef rig.turns.values `shouldReturn` True
        Map.null <$> readIORef rig.continuations.values `shouldReturn` True
        recordedKinds rig.custody `shouldReturn` ["materialize", "release"]
        (.disposition) <$> closeApplicationOperation operation `shouldReturn` RuntimeCleanupClean
        settledVerified rig `shouldReturn` True

  forM_ [(lapse, profile) | lapse <- ["grant", "deadline"], profile <- ["gondolin", "e2b"]] $ \(lapse, profile) ->
    it (T.unpack ("test_application_a5_rechecks_publication_admission_after_remote_lookup[" <> lapse <> "-" <> profile <> "]")) $
      withTemp $ \tmp -> do
        now <- getMonotonicTime >>= newIORef
        (hooks, started, released) <- stallLookups
        rig <- newRigWith noTweaks {tweakClock = Just (readIORef now), tweakHooks = hooks} tmp profile [plan] 1
        inv <- invocationFor rig "stale-admission" []
        operation <- startApplication rig.adapter inv
        timeout 2000000 (readMVar started) >>= (`shouldBe` Just ())
        expected <-
          if lapse == "grant"
            then closeGrant (Episode.grants rig.attachment) >> pure "grant-mismatch"
            else writeIORef now (Episode.episodeDeadline rig.attachment) >> pure "deadline-exceeded"
        putMVar released ()
        result <- waitApplicationOperation operation (Just 2)
        result.outcome `shouldBe` TurnFailed
        result.terminationCode `shouldBe` expected
        (result.outputReference, result.continuationReference) `shouldBe` (Nothing, Nothing)
        Map.null <$> readIORef rig.turns.values `shouldReturn` True
        Map.null <$> readIORef rig.continuations.values `shouldReturn` True
        recordedKinds rig.custody `shouldReturn` ["materialize", "release"]
        (.disposition) <$> closeApplicationOperation operation `shouldReturn` RuntimeCleanupClean
        settledVerified rig `shouldReturn` True

  it "test_application_a5_publication_claim_makes_later_cancellation_too_late" $ withTemp $ \tmp -> do
    rig <- newRig' tmp "gondolin" [plan]
    inv <- invocationFor rig "claimed-publication" []
    started <- newEmptyMVar
    released <- newEmptyMVar
    writeIORef rig.custody.beforeAdmit (stall started released)
    operation <- startApplication rig.adapter inv
    timeout 2000000 (readMVar started) >>= (`shouldBe` Just ())
    cancelApplicationOperation operation "stop" `shouldReturn` CancellationTooLate
    putMVar released ()
    result <- waitApplicationOperation operation (Just 2)
    result.outcome `shouldBe` TurnCompleted
    (isJust result.outputReference, isJust result.continuationReference) `shouldBe` (True, True)
    (.disposition) <$> closeApplicationOperation operation `shouldReturn` RuntimeCleanupClean
    settledVerified rig `shouldReturn` True

  forM_ ["admit", "turn", "continuation"] $ \failure ->
    it (T.unpack ("test_publication_failures_return_no_references_and_release_authority[" <> failure <> "]")) $ withTemp $ \tmp -> do
      rig <- newRig' tmp "gondolin" [plan]
      case failure of
        "admit" -> writeIORef rig.custody.beforeAdmit (throwAgenticus RuntimeError "stale")
        "turn" -> writeIORef rig.turns.failing True
        _ -> writeIORef rig.continuations.failing True
      (result, cleanup) <- runRig rig "publication" [] Nothing
      result.outcome `shouldBe` TurnFailed
      (result.outputReference, result.continuationReference) `shouldBe` (Nothing, Nothing)
      cleanup.disposition `shouldBe` RuntimeCleanupClean
      kinds <- recordedKinds rig.custody
      drop (length kinds - 1) kinds `shouldBe` ["release"]
      when (failure `elem` ["admit", "turn"]) $ Map.null <$> readIORef rig.turns.values `shouldReturn` True
      when (failure /= "continuation") $ Map.null <$> readIORef rig.continuations.values `shouldReturn` True

-- | Stall every @_binding_current@ after the initial validation until
-- released.
stallLookups :: IO (ApplicationAdapterHooks, MVar (), MVar ())
stallLookups = do
  started <- newEmptyMVar
  released <- newEmptyMVar
  calls <- newIORef (0 :: Int)
  let hooks =
        ApplicationAdapterHooks
          { bindingCurrent = Just $ \original inv -> do
              n <- atomicModifyIORef' calls (\x -> (x + 1, x + 1))
              when (n > 1) (stall started released)
              original inv
          }
  pure (hooks, started, released)

packageSpecs :: Spec
packageSpecs = do
  it "test_package_source_versions_node_syntax_and_credential_free_probe_shape" $ do
    (piApplicationCodingAgentVersion, piApplicationAgentCoreVersion, piApplicationAiVersion) `shouldBe` ("0.83.0", "0.83.0", "0.83.0")
    piApplicationSourceCommit `shouldBe` piSdkSourceCommit
    helper <- piApplicationHelperPath
    node <- requireNode
    (code, _, _) <- readProcessWithExitCode node ["--check", helper] ""
    code `shouldBe` ExitSuccess
    body <- TE.decodeUtf8 <$> B.readFile helper
    ("maxLength:1024" `T.isInfixOf` body) `shouldBe` True

  -- The reference's @qualification_installation@ tests: they run against
  -- the exact packages installed under 'qualificationPrefix', and pend with
  -- the reference's skip reasons otherwise.
  it "test_exact_helper_core_loop_fake_stream_is_one_turn_delta_only_and_authority_free" $ withTemp $ \tmp -> do
    let root = qualificationPrefix </> "node_modules/@earendil-works/pi-coding-agent"
        node = qualificationPrefix </> "node_modules/node/bin/node"
    installed <- (&&) <$> doesFileExist node <*> doesDirectoryExist root
    if not installed
      then pendingWith "exact Pi qualification packages required"
      else do
        helper <- piApplicationHelperPath
        let core = root </> "node_modules/@earendil-works/pi-agent-core/dist/index.js"
            ai = root </> "node_modules/@earendil-works/pi-ai/dist/index.js"
            coding = root </> "dist/index.js"
            environment = [("HOME", tmp), ("PATH", takeDirectory node), ("LANG", "C.UTF-8"), ("LC_ALL", "C.UTF-8")]
        (code, out, err) <- readCreateProcessWithExitCode ((proc node [helper, coding, core, ai, "--test-probe"]) {env = Just environment}) ""
        unless (code == ExitSuccess) (expectationFailure err)
        J.parseJson J.surrogateRefusingLoads (TE.encodeUtf8 (T.pack out))
          `shouldBe` Right
            ( Object
                [ ("type", String "test-probe")
                , ("ok", Bool True)
                , ("stream_calls", Int 1)
                , ("context_ok", Bool True)
                , ("prior_immutable", Bool True)
                , ("delta_only", Bool True)
                , ("network", Bool False)
                ]
            )

  it "test_exact_installed_application_package_probe" $ withTemp $ \tmp -> do
    opted <- lookupEnv "PETRUS_CV16_PI_APPLICATION_QUALIFY"
    if opted /= Just "1"
      then pendingWith "set PETRUS_CV16_PI_APPLICATION_QUALIFY=1 for exact installed-package probe"
      else do
        let root = qualificationPrefix </> "node_modules/@earendil-works/pi-coding-agent"
            cli = qualificationPrefix </> "node_modules/.bin/pi"
            node = qualificationPrefix </> "node_modules/node/bin/node"
            working = tmp </> "working"
            runtime = tmp </> "runtime"
        createDirectory working
        createDirectory runtime
        setFileMode runtime 0o700
        custody <- newFakeCustody "api-key" "anthropic"
        continuations <- newContinuations
        turns <- newTurns
        adapter <-
          newPiApplicationRuntimeAdapter
            (piApplicationRuntimeConfig "anthropic" "claude-sonnet-4-5" "gondolin" working runtime)
            (piApplicationContinuationCodec (continuationOperations continuations))
            (turnOperations turns)
            (applicationCustody (custodyOperations custody))
            getMonotonicTime
            Nothing
        result <- probeApplication adapter ApplicationProbePaths {cliPath = Just cli, nodePath = Just node, packageRoot = Just root}
        unless (result.disposition == ProbeReady) (expectationFailure (show result.issues))

-- | Where the reference's qualification tests find the exact Pi packages.
qualificationPrefix :: FilePath
qualificationPrefix = "/tmp/petrus-pi-a2-probe"

-- | @base64.b64decode(value, validate=True)@ and @b64encode@ over text.
pyB64Decode :: Text -> Either AgenticusError ByteString
pyB64Decode = Pi.pyB64DecodeText

b64Encode' :: ByteString -> Text
b64Encode' = Pi.b64Encode
