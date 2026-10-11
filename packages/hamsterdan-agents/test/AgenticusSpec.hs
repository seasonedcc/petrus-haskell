-- | @tests/unit/host/test_agenticus.py@: deterministic Agenticus
-- composition, runner selection, and the durable operation route store.
module AgenticusSpec (spec, compositionFor) where

import Control.Exception (throwIO)
import Control.Monad (forM_, void, when)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hamsterdan.Agents.Pi (PiRuntime (..), PiWorkspaceProvider (..))
import Hamsterdan.Agents.Protocol
import Hamsterdan.Sqlite (SQLData (..))
import Hamsterdan.Sqlite qualified as Sql
import Hamsterdan.Host.Agenticus
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor (..), DescriptorIdentity (..), DescriptorKind (..), capabilityDescriptor)
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot (..), mkResolutionSnapshot, snapshotFromData, snapshotToData)
import Petrus.Agenticus.Error (throwLeft)
import Petrus.Agenticus.Runtime.Installation
  ( ProbeDisposition (..)
  , RuntimeProbeResult
  , mkInstalledComponent
  , mkProbeIssue
  , mkRuntimeInstallation
  , mkRuntimeProbeResult
  )
import Petrus.Agenticus.Runtime.Pi (piApiKeyCatalog)
import Petrus.Agenticus.Runtime.Profiles (agentAsNetA5Local, ampA1, piNativeA2Local)
import Petrus.Json (Json (..), defaultDumps, dumps)
import Hamsterdan.Host.AgentRuntime (closeOwnedResources, composeAgentRuntimeWith)
import Hamsterdan.Host.PiA2 (installationFromEnvironment)
import Petrus.Motus.Worker (RuntimeError (..), ValueError (..))
import Petrus.TestSupport.Repo (repoRoot)
import ProtocolSpec (reviewRequest)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "agenticus"

compositionError :: Text -> AgentCompositionError -> Bool
compositionError fragment (AgentCompositionError message) = fragment `T.isInfixOf` message

-- | @compose_agent(provider=..., model=...)@.
compositionFor :: Text -> Text -> IO AgentComposition
compositionFor provider model = composeAgent Nothing (Just provider) (Just model)

defaultComposition :: IO AgentComposition
defaultComposition = composeAgent Nothing Nothing Nothing

routes :: FilePath -> IO AgentRouteStore
routes tmp = openAgentRouteStore (tmp </> "agent-routes.sqlite3")

applications :: FilePath -> FilePath
applications tmp = tmp </> "applications"

-- | @AgentComposition(provider, model, profile, ResolutionSnapshot(rev + 1, ...))@.
changedComposition :: AgentComposition -> IO AgentComposition
changedComposition composition = do
  snapshot <- throwLeft (mkResolutionSnapshot (composition.snapshot.catalogRevision + 1) composition.snapshot.descriptors)
  pure (AgentComposition composition.provider composition.model composition.profile snapshot)

-- | @json.dumps(encode_record(ActivityRequested(...)))@ with the default
-- policy fields and instant.
requested :: Text -> Text -> Json -> Integer -> Text -> Json
requested transition activity work heartbeat correlation =
  Object
    [ ("record", String "ActivityRequested")
    , ("schema", Int 5)
    , ("transition", String transition)
    , ("activity", String activity)
    , ("input", Object [("work", work)])
    , ( "policy"
      , Object
          [ ("attempts", Int 1)
          , ("heartbeat_timeout", Int heartbeat)
          , ("initial_interval", Int 0)
          , ("coefficient", Int 2)
          , ("max_interval", Int 60)
          , ("jitter", Int 0)
          , ("start_to_close", Null)
          , ("schedule_to_close", Null)
          ]
      )
    , ("correlation", String correlation)
    , ("idempotency", String correlation)
    , ("occurrence", Int 1)
    , ("scope", Null)
    , ("instant", Int 0)
    ]

completed :: Text -> Json -> Json
completed transition result =
  Object
    [ ("record", String "ActivityCompleted")
    , ("schema", Int 5)
    , ("transition", String transition)
    , ("result", result)
    , ("occurrence", Int 1)
    , ("instant", Int 0)
    ]

writeHistory :: FilePath -> [Json] -> IO ()
writeHistory path records = do
  createDirectoryIfMissing True (takeDirectory path)
  lines' <- traverse (either (fail . show) pure . dumps defaultDumps) records
  BS.writeFile path (BS.intercalate "\n" lines' <> "\n")

operationWork :: Text -> Json
operationWork operation = Object [("operation", String operation)]

-- | @legacy_route_database(path, composition)@.
legacyRouteDatabase :: FilePath -> AgentComposition -> IO (Sql.Connection, Text)
legacyRouteDatabase path composition = do
  database <- Sql.open (T.pack path)
  Sql.script
    database
    "CREATE TABLE agent_routes (\n            operation TEXT PRIMARY KEY, mode TEXT NOT NULL, profile TEXT NOT NULL,\n            snapshot TEXT, resolved INTEGER NOT NULL\n        );\n        CREATE TABLE active_agent_route (\n            singleton INTEGER PRIMARY KEY, mode TEXT NOT NULL, profile TEXT NOT NULL, snapshot TEXT\n        );"
  pure (database, snapshotData composition.snapshot)

columnsOf :: Sql.Connection -> IO (Set.Set Text)
columnsOf database = do
  rows <- Sql.query database "PRAGMA table_info(agent_routes)" []
  pure (Set.fromList [name | _ : SQLText name : _ <- rows])

resolvedOf :: AgentRouteStore -> Text -> IO [[SQLData]]
resolvedOf store operation = Sql.query (routeDatabase store) "SELECT resolved FROM agent_routes WHERE operation = ?" [SQLText operation]

-- | @ProbeRuntime@: counts probes and refuses any start.
data ProbeRuntime = ProbeRuntime {probes :: IORef Int, starts :: IORef Int}

probeRuntime :: RuntimeProbeResult -> IO (ProbeRuntime, (IO RuntimeProbeResult, PiRuntime, PiWorkspaceProvider))
probeRuntime result = do
  probes <- newIORef 0
  starts <- newIORef 0
  let runtime =
        PiRuntime
          { start = \_ -> modifyIORef' starts (+ 1) >> fail "runner selection must not start provider work"
          , loadOutput = \_ -> fail "unused"
          , loadWorkspaceArchive = \_ -> fail "unused"
          }
      workspaces = PiWorkspaceProvider (\_ _ _ _ _ -> fail "unused")
  pure (ProbeRuntime {probes, starts}, (modifyIORef' probes (+ 1) >> pure result, runtime, workspaces))

-- | @probe_result(disposition)@.
probeResult :: ProbeDisposition -> IO RuntimeProbeResult
probeResult disposition = case disposition of
  ProbeReady -> do
    component <- throwLeft (mkInstalledComponent "pi" "1" "qualified:test")
    installation <-
      throwLeft
        ( mkRuntimeInstallation
            piNativeA2Local.identity
            1
            [component]
            "linux"
            "x86_64"
            (Set.fromList ["runtime.cancel", "runtime.continue", "runtime.harness-owned", "runtime.local"])
        )
    throwLeft (mkRuntimeProbeResult piNativeA2Local.identity disposition (Just installation) [])
  _ -> do
    issue <- throwLeft (mkProbeIssue "runtime-unavailable" (Just "pi"))
    throwLeft (mkRuntimeProbeResult piNativeA2Local.identity disposition Nothing [issue])

isPi :: ComposedRunner -> Bool
isPi = \case
  SelectedPi _ -> True
  SelectedUnavailable -> False

sampleReview :: ReviewResult
sampleReview =
  ReviewResult
    { repository = "owner/repo"
    , pullRequest = 3
    , epoch = 2
    , head = ""
    , base = ""
    , status = "clear"
    , findings = []
    , lineage = []
    }

reviewOnly :: (Text -> Integer -> IO ()) -> AgentRunner
reviewOnly onReview =
  AgentRunner
    { review = \_ _ inv -> onReview inv.operation inv.attempt >> pure sampleReview
    , converse = \_ _ _ -> fail "unused"
    , code = \_ _ _ -> fail "unused"
    }

invocation :: Text -> Integer -> Invocation
invocation operation attempt = Invocation {operation, attempt, isCurrent = Nothing}

spec :: Spec
spec = describe "tests/unit/host/test_agenticus.py" $ do
  it "test_exact_pi_native_a2_local_api_key_profile_resolves_immutable_snapshot" $ do
    composition <- defaultComposition
    composition.profile `shouldBe` "pi-native-a2-local-anthropic-claude-sonnet-4-5-api-key"
    ("anthropic", "claude-sonnet-4-5") `elem` piApiKeyCatalog `shouldBe` True
    Set.fromList [item.identity.name | item <- composition.snapshot.descriptors]
      `shouldBe` Set.fromList
        [ "pi.compatible-api-key"
        , "pi.harness-owned"
        , "pi.native.a2.local"
        , "pi.collocated"
        , "motus.local"
        , "pi.native"
        , "hamsterdan.host-fenced"
        ]
    snapshotFromData (snapshotToData composition.snapshot) `shouldBe` Right composition.snapshot

  describe "test_agent_route_profile_uses_the_exact_qualified_installation_selection" $
    forM_
      [ ("anthropic", "claude-sonnet-4-5", "pi-native-a2-local-anthropic-claude-sonnet-4-5-api-key")
      , ("openai", "gpt-5.6-sol", "pi-native-a2-local-openai-gpt-5.6-sol-api-key")
      , ("openrouter", "anthropic/claude-sonnet-4.5", "pi-native-a2-local-openrouter-anthropic/claude-sonnet-4.5-api-key")
      ]
      $ \(provider, model, profile) -> it (T.unpack provider) $
        ((.profile) <$> compositionFor provider model) `shouldReturn` profile

  it "test_unqualified_agent_provider_model_pair_fails_closed" $
    compositionFor "openai" "claude-sonnet-4-5" `shouldThrow` compositionError "not qualified"

  it "test_supplied_environment_cannot_trigger_an_implicit_provider_selection" $
    composeAgent (Just []) Nothing Nothing `shouldThrow` compositionError "explicit provider and model"

  it "test_missing_disabled_and_incompatible_profiles_refuse_deterministically" $ do
    let withoutHands = [item | item <- agenticusDescriptors, item.identity.kind /= KindHands]
    resolveAgenticus withoutHands Nothing `shouldThrow` compositionError "missing-selection"
    let enabled = [item.identity | item <- agenticusDescriptors, item /= hostFencedEffect]
    resolveAgenticus agenticusDescriptors (Just enabled) `shouldThrow` compositionError "not-enabled"
    let incompatible = capabilityDescriptor hostFencedEffect.identity [] []
        descriptors = [if item == hostFencedEffect then incompatible else item | item <- agenticusDescriptors]
    resolveAgenticus descriptors Nothing `shouldThrow` compositionError "missing-capability"

  it "test_amp_a1_is_not_isolation" $ do
    let descriptors = [if item.identity.kind == KindRuntime then ampA1 else item | item <- agenticusDescriptors]
    resolveAgenticus descriptors Nothing `shouldThrow` compositionError "not agent isolation"

  it "test_agent_net_runner_a5_topology_is_explicitly_rejected" $ do
    let descriptors = [if item.identity.kind == KindRuntime then agentAsNetA5Local else item | item <- agenticusDescriptors]
    resolveAgenticus descriptors Nothing `shouldThrow` compositionError "A5 topology"

  describe "test_removed_agent_route_settings_fail_clearly" $
    forM_ ["HAMSTERDAN_AGENT_MODE", "HAMSTERDAN_AGENT_ISOLATION_REQUIRED"] $ \name -> it (T.unpack name) $
      composeAgent (Just [(name, "legacy-amp")]) Nothing Nothing `shouldThrow` compositionError "no longer supported"

  it "test_exact_ready_probe_selects_pi_without_starting_authority" $ do
    (runtime, selection) <- probeRuntime =<< probeResult ProbeReady
    runner <- composeAgentRunner (Just selection)
    isPi runner `shouldBe` True
    readIORef runtime.probes `shouldReturn` 1
    readIORef runtime.starts `shouldReturn` 0

  describe "test_not_ready_probe_fails_closed" $
    forM_ [ProbeNotInstalled, ProbeUnavailable] $ \disposition -> it (show disposition) $ do
      (runtime, selection) <- probeRuntime =<< probeResult disposition
      runner <- composeAgentRunner (Just selection)
      isPi runner `shouldBe` False
      readIORef runtime.probes `shouldReturn` 1
      readIORef runtime.starts `shouldReturn` 0

  it "test_production_runtime_constructs_workspace_before_owned_runtime" . withTmp $ \tmp -> do
    let environment =
          [ ("HAMSTERDAN_PI_PROVIDER", "anthropic")
          , ("HAMSTERDAN_PI_MODEL", "claude-sonnet-4-5")
          , ("HAMSTERDAN_PI_API_KEY", "synthetic-direct-authority")
          , ("HAMSTERDAN_PI_CLI_PATH", T.pack (tmp </> "cli"))
          , ("HAMSTERDAN_PI_NODE_PATH", T.pack (tmp </> "node"))
          , ("HAMSTERDAN_PI_PACKAGE_ROOT", T.pack (tmp </> "package"))
          ]
    installation <- installationFromEnvironment environment Nothing
    runtimes <- newIORef (0 :: Int)
    let compose _ _ = modifyIORef' runtimes (+ 1)
        workspaces _ = throwIO (ValueError "synthetic workspace failure") :: IO ()
    composeAgentRuntimeWith workspaces compose (tmp </> "state") installation
      `shouldThrow` (== ValueError "synthetic workspace failure")
    readIORef runtimes `shouldReturn` 0

  it "test_startup_cleanup_attempts_every_independently_owned_resource" $ do
    closed <- newIORef []
    let resource name failing = do
          modifyIORef' closed (<> [name :: Text])
          when failing $ throwIO (RuntimeError "synthetic")
    closeOwnedResources Nothing (Just (resource "runtime" True)) (Just (resource "routes" False))
      `shouldThrow` (\(RuntimeError message) -> "cleanup is unverified" `T.isInfixOf` message)
    readIORef closed `shouldReturn` ["runtime", "routes"]

  it "test_snapshot_persists_and_claim_reconstructs_same_route_after_restart" . withTmp $ \tmp -> do
    composition <- defaultComposition
    store <- routes tmp
    activateRoutes store composition (applications tmp)
    claimed <- claimRoute store "review:one" composition
    closeRoutes store
    reopened <- routes tmp
    activateRoutes reopened composition (applications tmp)
    claimRoute reopened "review:one" composition `shouldReturn` claimed
    different <- changedComposition composition
    claimRoute reopened "review:one" different `shouldThrow` compositionError "route"
    closeRoutes reopened

  it "test_legacy_schema_preserves_only_agenticus_operation_custody" . withTmp $ \tmp -> do
    let path = tmp </> "agent-routes.sqlite3"
    composition <- defaultComposition
    (database, snapshot) <- legacyRouteDatabase path composition
    void $
      Sql.execute
        database
        "INSERT INTO agent_routes VALUES (?, 'agenticus', ?, ?, 0)"
        [SQLText "review:existing", SQLText composition.profile, SQLText snapshot]
    void $ Sql.execute database "INSERT INTO agent_routes VALUES ('review:old', 'legacy-amp', 'old', NULL, 1)" []
    void $
      Sql.execute database "INSERT INTO active_agent_route VALUES (1, 'agenticus', ?, ?)" [SQLText composition.profile, SQLText snapshot]
    Sql.close database
    store <- openAgentRouteStore path
    activateRoutes store composition (applications tmp)
    ((.operation) <$> claimRoute store "review:existing" composition) `shouldReturn` "review:existing"
    columnsOf (routeDatabase store) `shouldReturn` Set.fromList ["operation", "profile", "snapshot", "resolved"]
    Sql.query (routeDatabase store) "SELECT 1 FROM agent_routes WHERE operation = 'review:old'" [] `shouldReturn` []
    closeRoutes store

  it "test_terminal_history_repairs_legacy_crash_gap_before_migration" . withTmp $ \tmp -> do
    let path = tmp </> "agent-routes.sqlite3"
    composition <- defaultComposition
    (database, _) <- legacyRouteDatabase path composition
    void $ Sql.execute database "INSERT INTO agent_routes VALUES ('review:terminal', 'legacy-amp', 'old', NULL, 0)" []
    void $ Sql.execute database "INSERT INTO active_agent_route VALUES (1, 'legacy-amp', 'old', NULL)" []
    Sql.close database
    writeHistory
      (applications tmp </> "1" </> "2" </> "3" </> "history.jsonl")
      [ requested "execute.review" "review" (operationWork "review:terminal") 30 "review:terminal"
      , completed "execute.review" (Object [])
      ]
    store <- openAgentRouteStore path
    activateRoutes store composition (applications tmp)
    Sql.query (routeDatabase store) "SELECT 1 FROM agent_routes" [] `shouldReturn` []
    closeRoutes store

  describe "test_unreconstructible_unresolved_legacy_schema_is_refused_atomically" $
    forM_ ["legacy-amp", "agenticus"] $ \mode -> it (T.unpack mode) . withTmp $ \tmp -> do
      let path = tmp </> "agent-routes.sqlite3"
      composition <- defaultComposition
      (database, _) <- legacyRouteDatabase path composition
      void $ Sql.execute database "INSERT INTO agent_routes VALUES ('review:blocked', ?, 'old', NULL, 0)" [SQLText mode]
      void $ Sql.execute database "INSERT INTO active_agent_route VALUES (1, ?, 'old', NULL)" [SQLText mode]
      Sql.close database
      store <- openAgentRouteStore path
      activateRoutes store composition (applications tmp)
        `shouldThrow` \(AgentCompositionError message) ->
          "cannot be resumed" `T.isInfixOf` message || "lacks reconstructible composition" `T.isInfixOf` message
      closeRoutes store
      unchanged <- Sql.open (T.pack path)
      columns <- columnsOf unchanged
      Set.member "mode" columns `shouldBe` True
      rows <- Sql.query unchanged "SELECT mode, resolved FROM agent_routes" []
      take 1 rows `shouldBe` [[SQLText mode, SQLInteger 0]]
      Sql.close unchanged

  it "test_routed_runner_claims_and_forwards_each_explicit_attempt_without_changing_identity" . withTmp $ \tmp -> do
    composition <- defaultComposition
    store <- routes tmp
    activateRoutes store composition (applications tmp)
    calls <- newIORef []
    let subject = routedAgentRunner (reviewOnly (\operation attempt -> modifyIORef' calls (<> [(operation, attempt)]))) store composition Nothing
    forM_ [1, 2] $ \attempt -> void (subject.review "repository" reviewRequest (invocation "review:one" attempt))
    readIORef calls `shouldReturn` [("review:one", 1), ("review:one", 2)]
    ((.operation) <$> claimRoute store "review:one" composition) `shouldReturn` "review:one"
    closeRoutes store

  it "test_routed_runner_claims_before_fault" . withTmp $ \tmp -> do
    composition <- defaultComposition
    store <- routes tmp
    activateRoutes store composition (applications tmp)
    calls <- newIORef (0 :: Int)
    let failing kind operation attempt = do
          (kind, operation, attempt) `shouldBe` ("review", "review:fault", 1)
          throwIO (RuntimeError "qualified fault")
        subject = routedAgentRunner (reviewOnly (\_ _ -> modifyIORef' calls (+ 1))) store composition (Just failing)
    subject.review "repository" reviewRequest (invocation "review:fault" 1)
      `shouldThrow` \(RuntimeError message) -> "qualified fault" `T.isInfixOf` message
    readIORef calls `shouldReturn` 0
    closeRoutes store

  it "test_old_process_cannot_claim_after_an_atomic_composition_change" . withTmp $ \tmp -> do
    composition <- defaultComposition
    changed <- changedComposition composition
    oldProcess <- routes tmp
    activateRoutes oldProcess composition (applications tmp)
    newProcess <- routes tmp
    activateRoutes newProcess changed (applications tmp)
    claimRoute oldProcess "review:late" composition `shouldThrow` compositionError "no longer active"
    closeRoutes oldProcess
    closeRoutes newProcess

  it "test_terminal_history_repairs_crash_gap_before_composition_change" . withTmp $ \tmp -> do
    composition <- defaultComposition
    store <- routes tmp
    activateRoutes store composition (applications tmp)
    void (claimRoute store "review:terminal" composition)
    closeRoutes store
    writeHistory
      (applications tmp </> "1" </> "2" </> "3" </> "history.jsonl")
      [ requested "execute.review" "review" (operationWork "review:terminal") 30 "review:terminal"
      , completed "execute.review" (Object [])
      ]
    reopened <- routes tmp
    activateRoutes reopened composition (applications tmp)
    closeRoutes reopened

  let reviewOperation = "review:github:1:2:pr:3:" <> T.replicate 40 "a" <> ":i1"
      reviewHistory tmp variant =
        writeHistory
          (applications tmp </> "1" </> "2" </> "3" </> "history.jsonl")
          [ requested "review.agent" "review_agent" (operationWork reviewOperation) 300 reviewOperation
          , completed "review.agent" (Object [("$variant", String variant)])
          ]
      claimedThenClosed tmp composition operation = do
        store <- routes tmp
        activateRoutes store composition (applications tmp)
        void (claimRoute store operation composition)
        closeRoutes store

  it "test_v5_review_terminal_history_repairs_the_global_agent_route" . withTmp $ \tmp -> do
    composition <- defaultComposition
    claimedThenClosed tmp composition reviewOperation
    reviewHistory tmp "RoundUnable"
    reopened <- routes tmp
    activateRoutes reopened composition (applications tmp)
    resolvedOf reopened reviewOperation `shouldReturn` [[SQLInteger 1]]
    closeRoutes reopened

  it "test_v5_deferred_review_history_keeps_the_global_agent_route_recoverable" . withTmp $ \tmp -> do
    composition <- defaultComposition
    claimedThenClosed tmp composition reviewOperation
    reviewHistory tmp "RoundDeferred"
    reopened <- routes tmp
    activateRoutes reopened composition (applications tmp)
    ((.resolved) <$> claimRoute reopened reviewOperation composition) `shouldReturn` False
    closeRoutes reopened

  let opKey = "push:comment:9:" <> T.replicate 40 "a" <> ":i1"
      mutationOperation = "mutation:owner/repo:pr:3:" <> opKey
      mutationHistory tmp binding variant = do
        let root = applications tmp </> "1" </> "2" </> "3"
        createDirectoryIfMissing True root
        TIO.writeFile (root </> "binding.json") binding
        writeHistory
          (root </> "history.jsonl")
          [ requested "mut.git_gate" "git_gate" (Object [("op_key", String opKey)]) 300 opKey
          , completed "mut.git_gate" (Object [("$variant", String variant)])
          ]

  describe "test_v5_mutation_known_terminal_repairs_the_global_agent_route" $
    forM_ ["Pushed", "MovedM", "DeclinedM"] $ \variant -> it (T.unpack variant) . withTmp $ \tmp -> do
      composition <- defaultComposition
      claimedThenClosed tmp composition mutationOperation
      mutationHistory
        tmp
        "{\"instance_id\": \"github:1:2:pr:3\", \"repository\": \"owner/repo\", \"pull_request\": 3, \"topology\": \"v5\"}"
        variant
      reopened <- routes tmp
      activateRoutes reopened composition (applications tmp)
      resolvedOf reopened mutationOperation `shouldReturn` [[SQLInteger 1]]
      closeRoutes reopened

  it "test_v5_mutation_fault_keeps_the_agent_route_recoverable" . withTmp $ \tmp -> do
    composition <- defaultComposition
    claimedThenClosed tmp composition mutationOperation
    mutationHistory tmp "{\"instance_id\": \"github:1:2:pr:3\", \"repository\": \"owner/repo\", \"pull_request\": 3}" "FaultM"
    reopened <- routes tmp
    activateRoutes reopened composition (applications tmp)
    ((.resolved) <$> claimRoute reopened mutationOperation composition) `shouldReturn` False
    closeRoutes reopened

  it "test_history_repair_refuses_a_mismatched_terminal_transition" . withTmp $ \tmp -> do
    composition <- defaultComposition
    store <- routes tmp
    activateRoutes store composition (applications tmp)
    void (claimRoute store "review:mismatched" composition)
    writeHistory
      (applications tmp </> "1" </> "2" </> "3" </> "history.jsonl")
      [ requested "execute.review" "review" (operationWork "review:mismatched") 30 "review:mismatched"
      , completed "execute.change" (Object [])
      ]
    activateRoutes store composition (applications tmp) `shouldThrow` compositionError "mismatched terminal"
    closeRoutes store

  it "test_host_composition_imports_only_public_defining_modules" $ do
    root <- repoRoot
    source <- TIO.readFile (root </> "packages" </> "hamsterdan-agents" </> "src" </> "Hamsterdan" </> "Host" </> "Agenticus.hs")
    forM_
      [ "import Petrus.Agenticus.Catalog.Descriptor"
      , "import Petrus.Agenticus.Catalog.Resolution"
      , "import Petrus.Agenticus.Runtime.Pi\n"
      , "import Petrus.Agenticus.Runtime.Profiles"
      ]
      $ \needle -> (needle `T.isInfixOf` source) `shouldBe` True
    -- The umbrella modules (the reference's @from petrus.agenticus import@
    -- and @from petrus.motus import@).
    forM_ ["import Petrus.Agenticus\n", "import Petrus.Agenticus (", "import Petrus.Motus\n", "import Petrus.Motus ("] $ \needle ->
      (needle `T.isInfixOf` source) `shouldBe` False
