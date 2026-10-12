-- | Whole Codex, Claude and Amp Turns, and the Codex A3 runtime service's
-- round trip; the twins of @bench/python_bench.py@.
--
-- Each row takes one Turn through the host's adapter, against the same fakes
-- the reference side uses (@test/fixtures@), with a fresh operation id every
-- call:
--
-- * @codex-turn@: open a Local Motus territory and its Episode Attachment,
--   'startCodex' (real 'AgentConnectionCustody' over a SQLite ledger:
--   materialize and activate; the fake @codex@ CLI and the private helper's
--   @collect@ run as subprocesses; checkpoint and admission),
--   'waitCodexOperation', 'closeCodexOperation', and settle the attachment.
-- * @codex-a3-service-turn@: the A3 lane end to end over its host-local
--   runtime service: open a Gondolin Motus territory (the fake Gondolin SDK
--   @test/fixtures/codex/fake_gondolin_codex.mjs@, whose guest commands run
--   on the host) and its Episode Attachment, probe the guest @codex@, start
--   the service on a fresh private state directory under the platform's
--   temporary directory (@TMPDIR@, else @/tmp@; the Unix socket path in it
--   must stay within 104 bytes on macOS, 108 on Linux): its fence and
--   SQLite replay ledger; send one request through the Worker-side Activity client over
--   the Unix socket (the service records the operation, runs one Codex Turn
--   with the same custody as @codex-turn@, stores and replies the terminal),
--   close the service, remove its state directory, and settle the
--   attachment.
-- * @claude-turn@: open a Local Motus territory, its Episode Attachment, the
--   Hands gateway and a grant, then 'startClaude' (custody materialization,
--   the official client of the fake @claude_agent_sdk@ through the sidecar:
--   its PreToolUse hook twice, one @workspace_read@ through the gateway, the
--   session store's @append@, three messages), wait, close, and settle.
-- * @amp-turn@: an Episode Attachment over the provider-managed binding, then
--   'startAmp' (the official @execute@ of the fake @amp_sdk@ through the
--   sidecar: @system/init@, an assistant event and the @success@ result),
--   wait, close, and settle.
--
-- The connection keys are reversible stand-ins on both sides, so the cipher
-- is not measured. The probes run once, before timing, through the official
-- probe hooks.
module TurnsBench
  ( turnsBenchmarks
    -- * Shared with "PiTurnsBench"
  , ok
  , counter
  , completed
  , verified
  , settled
  , hostFencedEffect
  ) where

import Control.Exception (finally)
import Control.Monad (unless)
import Data.ByteArray qualified as BA
import Data.ByteString qualified as B
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Activity (ActivityExecutionContext (..), ActivityInvocation (..), defaultExecutionPolicy)
import Petrus.Agenticus.Attachment.Binding (AttachmentCoordinates (..), BindingSettlement (..), bindingExecution, motusBinding, openMotusBinding)
import Petrus.Agenticus.Attachment.Episode (AttachmentSettlement (..), EpisodeAttachment, episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor, DescriptorKind (..), capabilityDescriptor, descriptorIdentity)
import Petrus.Agenticus.Catalog.Resolution (mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody
  ( AdmissionResult (..)
  , AgentConnectionCustody
  , AttachmentFence (..)
  , ConnectionIdentity (..)
  , ConnectionStatus (..)
  , ConnectionView (..)
  , ReleaseResult (..)
  , agentConnectionCustody
  , authorize
  , enrollHost
  , lookupConnection
  , mkConnectionIdentity
  , newOpaqueState
  )
import Petrus.Agenticus.Connection.Key (KeyOperations (..), mkKeyErasureEvidence)
import Petrus.Agenticus.Connection.Materialization (CleanupEvidence (..), newPrivateFileMaterializer)
import Petrus.Agenticus.Connection.Storage (openSqliteConnectionStorage)
import Petrus.Agenticus.Hands.Contract (allToolMethods)
import Petrus.Agenticus.Hands.Grants (CapabilityGrant (..), GrantSpec (..), grantSpec, openGrant)
import Petrus.Agenticus.Hands.Workspace (defaultCommandTimeout, newMotusWorkspaceAdapter, workspaceHandsAdapter)
import Petrus.Agenticus.Runtime.Amp
import Petrus.Agenticus.Runtime.Claude
import Petrus.Agenticus.Runtime.Codex
import Petrus.Agenticus.Runtime.CodexGondolin
  ( closeCodexGondolinRuntimeService
  , codexGondolinActivityClientWith
  , endpointVariable
  , jsonBytes
  , newCodexGondolinRuntimeService
  , serviceActivity
  , startCodexGondolinRuntimeService
  , tokenVariable
  )
import Petrus.Agenticus.Runtime.Custody
import Petrus.Agenticus.Runtime.Installation (ProbeDisposition (..), RuntimeProbeResult (..))
import Petrus.Agenticus.Runtime.Operation (RuntimeOperationCleanup, cleanupVerified)
import Petrus.Agenticus.Runtime.Profiles (ampA1, claudeA2Local, codexA2Local, codexA3Gondolin)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..))
import Petrus.Agenticus.Thread.Identity (lifecycleIdToData, mkEpisodeId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import Petrus.Json (Json (..))
import Petrus.Motus.Execution (capMicrovm, capPrivateFileTransfer, capVm, defaultSpec, mkEnvironmentSpec)
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Providers.Gondolin (GondolinConfig (..), gondolinConfig, gondolinProvider, newGondolinEnvironment)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import Petrus.TestSupport.Python (pythonExecutable)
import System.Directory (createDirectory, getTemporaryDirectory, makeAbsolute, removeDirectoryRecursive)
import System.Environment (lookupEnv, setEnv)
import System.FilePath ((</>))
import System.IO.Temp (createTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Tasty.Bench

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

hostFencedEffect :: CapabilityDescriptor
hostFencedEffect = capabilityDescriptor (descriptorIdentity KindEffect "host.fenced" 1) ["effect.host-fenced"] []

-- | Reversible stand-in keys shared with the twin.
keys :: KeyOperations
keys =
  KeyOperations
    { seal = \_ plaintext -> pure ("sealed:" <> BA.convert plaintext)
    , open = \_ sealed -> pure (BA.convert (B.drop 7 sealed))
    , erase = \connectionId -> either (fail . show) pure (mkKeyErasureEvidence connectionId True)
    }

-- | A fresh operation number per call.
counter :: IO (IO Text)
counter = do
  ref <- newIORef (0 :: Int)
  pure (T.pack . show <$> atomicModifyIORef' ref (\n -> (n + 1, n)))

completed :: RuntimeTurnSettlement -> IO ()
completed settlement = unless (settlement.outcome == TurnCompleted) (fail ("turn did not complete: " <> show settlement.terminationCode))

verified :: RuntimeOperationCleanup -> IO ()
verified cleanup = unless (cleanupVerified cleanup) (fail "cleanup not verified")

settled :: EpisodeAttachment -> IO ()
settled attachment = do
  settlement <- Episode.settle attachment 5
  unless settlement.settlement.verified (fail "attachment settlement not verified")

ready :: RuntimeProbeResult -> IO ()
ready probe = unless (probe.disposition == ProbeReady) (fail ("probe not ready: " <> show probe.disposition))

prependPath :: FilePath -> IO ()
prependPath directory = do
  current <- maybe "" id <$> lookupEnv "PATH"
  setEnv "PATH" (directory <> ":" <> current)

-- ---------------------------------------------------------------------------
-- Codex

-- | The fake @codex@ CLI at @version@, written to @root@.
fakeCodex :: FilePath -> FilePath -> Text -> IO FilePath
fakeCodex python root version = do
  template <- TE.decodeUtf8 <$> B.readFile ("test" </> "fixtures" </> "codex" </> "fake_codex.py")
  let executable = root </> "codex"
  B.writeFile executable (TE.encodeUtf8 (T.replace "__VERSION__" version (T.replace "__PYTHON__" (T.pack python) template)))
  setFileMode executable 0o755
  pure executable

-- | Real custody over a SQLite ledger with the @codex-bench@ connection
-- authorized, and the in-memory Continuation and Turn stores.
data CodexRig = CodexRig
  { custody :: AgentConnectionCustody
  , continuations :: CodexContinuationOperations
  , turns :: CodexTurnOperations
  }

codexRig :: FilePath -> IO CodexRig
codexRig root = do
  let installation = root </> "installation"
  createDirectory installation
  setFileMode installation 0o700
  storage <- openSqliteConnectionStorage (installation </> "connections.sqlite3")
  materializer <- newPrivateFileMaterializer (installation </> "materialized")
  let custody = agentConnectionCustody storage keys materializer getMonotonicTime
  enrollHost custody "host-1" "enroll-codex-host"
  state <- newOpaqueState "bench-auth-state"
  _ <- authorize custody (ok (mkConnectionIdentity "codex-bench" "codex" "safe-account" "file-auth")) state "authorize-codex"
  values <- newIORef Map.empty
  let continuations =
        CodexContinuationOperations
          { store = \operationId payload -> do
              let reference = "codex-continuation-" <> operationId
              modifyIORef' values (Map.insert reference payload)
              pure reference
          , load = \reference -> maybe (fail "no continuation") pure . Map.lookup reference =<< readIORef values
          }
      turns = CodexTurnOperations (\operationId _ _ -> pure ("codex-turn-" <> operationId))
  pure CodexRig {custody, continuations, turns}

codexTurn :: FilePath -> FilePath -> IO (IO ())
codexTurn python root = do
  _ <- fakeCodex python root codexVersion
  prependPath root
  CodexRig {custody, continuations, turns} <- codexRig root
  operations <- hostConnectionCustody custody
  adapter <-
    newCodexRuntimeAdapter
      (codexRuntimeConfig "host-1") {credentialTtl = 10, commandTimeout = 10, cancellationGrace = 1}
      (codexContinuationCodec continuations)
      turns
      operations
      CodexAdapterOptions {clock = getMonotonicTime, hooks = officialCodexProbeHooks, interpreter = python, guestInterpreter = "/usr/bin/python3", startWrapper = id}
  ready =<< probeCodex adapter
  let selected =
        ok . mkResolutionSnapshot 1 $
          [ codexA2Local
          , codexConnectionCapabilities
          , codexProgramCapabilities
          , codexCollocatedHands
          , codexLocalTerritory
          , codexContinuationCapabilities
          , hostFencedEffect
          ]
  createDirectory (root </> "workspace")
  archive <- workspaceArchive (root </> "workspace")
  provider <- localProvider <$> newLocalProcessEnvironment
  next <- counter
  pure $ do
    n <- next
    binding <- openMotusBinding provider ("territory-" <> n) (ok (mkEnvironmentSpec Nothing [capPrivateFileTransfer])) archive ("input-" <> n)
    now <- getMonotonicTime
    attachment <- newEpisodeAttachment (ok (mkEpisodeId ("episode-" <> n))) selected (motusBinding binding) ("attachment-" <> n) (now + 30) episodeOptions
    connection <- lookupConnection custody "codex-bench"
    invocation <-
      newCodexRuntimeInvocation
        CodexRuntimeInvocation
          { operationId = "operation-" <> n
          , episodeId = Episode.episodeId attachment
          , turnId = ok (mkTurnId ("turn-" <> n))
          , prompt = "first"
          , connection
          , attachment
          , continuation = Nothing
          }
    operation <- startCodex adapter invocation
    completed =<< waitCodexOperation operation (Just 30)
    verified =<< closeCodexOperation operation
    settled attachment

-- ---------------------------------------------------------------------------
-- Codex A3 runtime service

codexA3ServiceTurn :: FilePath -> FilePath -> IO (IO ())
codexA3ServiceTurn python root = do
  executable <- fakeCodex python root codexGondolinVersion
  let architecture = root </> "fake-uname"
      sdk = root </> "fake-gondolin-codex.mjs"
      jsonPath = TE.decodeUtf8 . ok . jsonBytes . String . T.pack
  writeFile architecture "#!/bin/sh\nprintf aarch64\n"
  setFileMode architecture 0o755
  template <- TE.decodeUtf8 <$> B.readFile ("test" </> "fixtures" </> "codex" </> "fake_gondolin_codex.mjs")
  B.writeFile sdk . TE.encodeUtf8 $
    T.replace "__STARTED__" (jsonPath (root </> "fake-codex-command-started")) $
      T.replace "__UNAME__" (jsonPath architecture) $
        T.replace "__CODEX__" (jsonPath executable) template
  CodexRig {custody, continuations, turns} <- codexRig root
  operations <- hostConnectionCustody custody
  adapter <-
    newCodexGondolinRuntimeAdapter
      (codexRuntimeConfig "host-1") {credentialTtl = 10, commandTimeout = 10, cancellationGrace = 2}
      (codexContinuationCodec continuations)
      turns
      operations
      CodexAdapterOptions {clock = getMonotonicTime, hooks = officialCodexProbeHooks, interpreter = python, guestInterpreter = "/usr/bin/python3", startWrapper = id}
  environment <- newGondolinEnvironment (root </> "gondolin") (gondolinConfig (T.pack sdk)) {gondolinLeaseTtl = 30}
  let provider = gondolinProvider environment
      spec = ok (mkEnvironmentSpec (Just "fake-image") [capVm, capMicrovm, capPrivateFileTransfer])
      selected =
        ok . mkResolutionSnapshot 1 $
          [ codexA3Gondolin
          , codexConnectionCapabilities
          , codexProgramCapabilities
          , codexCollocatedHands
          , codexGondolinTerritory
          , codexContinuationCapabilities
          , hostFencedEffect
          ]
      token = T.replicate 32 "t"
      context =
        ActivityExecutionContext
          { attemptId = "activity-attempt"
          , epoch = "1"
          , claimant = "host"
          , instance' = Nothing
          , latestDetails = pure Null
          , heartbeat = pure . maybe Null id
          }
  createDirectory (root </> "workspace")
  writeFile (root </> "workspace" </> "public-input.txt") "public-workspace-canary"
  archive <- workspaceArchive (root </> "workspace")
  next <- counter
  pure $ do
    n <- next
    binding <- openMotusBinding provider ("territory-" <> n) spec archive ("input-" <> n)
    now <- getMonotonicTime
    attachment <- newEpisodeAttachment (ok (mkEpisodeId ("episode-" <> n))) selected (motusBinding binding) ("attachment-" <> n) (now + 30) episodeOptions
    ready =<< probeCodexGondolin adapter (Just attachment)
    connection <- lookupConnection custody "codex-bench"
    state <- getTemporaryDirectory >>= (`createTempDirectory` "petrus-a3-")
    let endpoint = state </> "runtime.sock"
    service <- newCodexGondolinRuntimeService endpoint (state </> "runtime-ledger.db") token adapter connection attachment
    startCodexGondolinRuntimeService service
    coordinates <- Episode.coordinates attachment
    let input =
          Object
            [ ("version", Int 1)
            , ("episode_id", lifecycleIdToData (Episode.episodeId attachment))
            , ("turn_id", String ("turn-" <> n))
            , ("prompt", String "first")
            , ("attachment_id", String coordinates.attachmentId)
            , ("attachment_epoch", Int coordinates.attachmentEpoch)
            , ("connection_id", String connection.identity.connectionId)
            , ("authority_epoch", Int connection.authorityEpoch)
            , ("state_version", Int connection.stateVersion)
            , ("continuation", Null)
            ]
        invocation =
          ActivityInvocation
            { activity = serviceActivity
            , input
            , policy = defaultExecutionPolicy
            , correlation = Nothing
            , idempotency = Just ("operation-" <> n)
            }
        variables name
          | name == endpointVariable = pure (Just (T.pack endpoint))
          | name == tokenVariable = pure (Just token)
          | otherwise = pure Nothing
    result <-
      codexGondolinActivityClientWith variables invocation context
        `finally` closeCodexGondolinRuntimeService service
        `finally` removeDirectoryRecursive state
    case result of
      Object members
        | lookup "outcome" members == Just (String "completed")
        , Just (Object cleanup) <- lookup "cleanup" members
        , lookup "disposition" cleanup == Just (String "clean") ->
            pure ()
      _ -> fail ("service turn did not complete: " <> show result)
    settled attachment

-- ---------------------------------------------------------------------------
-- Claude

-- | The reference test's fake custody: one READ lease per Turn.
claudeCustody :: HostConnectionCustody
claudeCustody =
  HostConnectionCustody
    { materialize = \connection host mode ttl _ -> do
        now <- getMonotonicTime
        pure
          HostMaterialization
            { fence = AttachmentFence "connection-attachment" "connection-lease" connection host 1 3 4
            , mode
            , expiresAt = now + ttl
            , home = ProviderHome {read = pure "sk-ant-api03-bench", replace = \_ -> pure ()}
            }
    , activate = \_ _ -> fail "activate"
    , admitResult = \fence operationId -> pure AdmissionResult {operationId, purpose = "result", attachmentId = fence.attachmentId}
    , checkpoint = \_ _ -> fail "checkpoint"
    , release = \m operationId ->
        pure
          ReleaseResult
            { operationId
            , cleanup =
                CleanupEvidence
                  { attachmentId = m.fence.attachmentId
                  , removed = True
                  , alreadyAbsent = False
                  , bytesOverwritten = 18
                  , physicalErasureGuaranteed = False
                  , securityViolation = False
                  }
            }
    }

claudeTurn :: FilePath -> FilePath -> IO (IO ())
claudeTurn python root = do
  let working = root </> "project"
      runtimeRoot = root </> "runtime"
  createDirectory working
  createDirectory runtimeRoot
  setFileMode runtimeRoot 0o700
  fixture <- makeAbsolute ("test" </> "fixtures" </> "claude")
  values <- newIORef Map.empty
  let sidecar = ClaudeSidecar python [fixture] 10 defaultSidecarPool
      continuations =
        ClaudeContinuationOperations
          { store = \operationId payload -> do
              let reference = "claude-continuation-" <> operationId
              modifyIORef' values (Map.insert reference payload)
              pure reference
          , load = \reference -> maybe (fail "no continuation") pure . Map.lookup reference =<< readIORef values
          }
      turns = ClaudeTurnOperations (\operationId _ -> pure ("claude-turn-" <> operationId))
  adapter <-
    newClaudeRuntimeAdapter
      (claudeRuntimeConfig "claude-sonnet-4-5" working runtimeRoot) {hostId = "host-1", credentialTtl = 10, wallTimeout = 30, cancellationGrace = 5}
      (claudeContinuationCodec continuations)
      turns
      claudeCustody
      ClaudeAdapterOptions {clock = getMonotonicTime, clientFactory = Nothing, hooks = officialClaudeProbeHooks sidecar, interpreter = python, ready = Nothing}
  ready =<< probeClaude adapter Nothing
  let selected =
        ok . mkResolutionSnapshot 1 $
          [ claudeA2Local
          , claudeConnectionCapabilities
          , claudeProgramCapabilities
          , claudeCollocatedHands
          , claudeLocalTerritory
          , claudeContinuationCapabilities
          , hostFencedEffect
          ]
      view = ConnectionView (ok (mkConnectionIdentity "claude-connection" "claude" "safe-account" "api-key")) StatusReady 3 4 Nothing
  createDirectory (root </> "workspace")
  writeFile (root </> "workspace" </> "marker.txt") "workspace-marker"
  archive <- workspaceArchive (root </> "workspace")
  provider <- localProvider <$> newLocalProcessEnvironment
  next <- counter
  pure $ do
    n <- next
    binding <- openMotusBinding provider ("territory-" <> n) defaultSpec archive ("input-" <> n)
    now <- getMonotonicTime
    let episode = ok (mkEpisodeId ("episode-" <> n))
        deadline = now + 30
    attachment <- newEpisodeAttachment episode selected (motusBinding binding) ("attachment-" <> n) deadline episodeOptions
    execution <- bindingExecution binding
    workspace <- newMotusWorkspaceAdapter provider execution ["/bin/true"] defaultCommandTimeout
    gateway <- Episode.gateway attachment (workspaceHandsAdapter workspace) 256
    grant <-
      openGrant
        (Episode.grants attachment)
        (grantSpec allToolMethods deadline 16) {specWritablePaths = ["output.txt"], specAllowedArgv = [["/bin/true"]]}
    invocation <-
      newClaudeRuntimeInvocation
        ClaudeRuntimeInvocation
          { operationId = "operation-" <> n
          , episodeId = episode
          , turnId = ok (mkTurnId ("turn-" <> n))
          , prompt = "prompt"
          , connection = view
          , attachment
          , gateway
          , grantEpoch = grant.grantEpoch
          , continuation = Nothing
          }
    operation <- startClaude adapter invocation
    completed =<< waitClaudeOperation operation (Just 30)
    verified =<< closeClaudeOperation operation
    settled attachment

-- ---------------------------------------------------------------------------
-- Amp

ampTurn :: FilePath -> FilePath -> IO (IO ())
ampTurn python root = do
  let cli = root </> "amp"
  writeFile cli $
    "#!/bin/sh\nif [ \"$1\" = --version ]; then echo \""
      <> T.unpack ampCliVersion
      <> " (bench)\"; else echo \"--orb-execute --project --stream-json\"; fi\n"
  setFileMode cli 0o755
  setEnv "AMP_CLI_PATH" cli
  fixture <- makeAbsolute ("test" </> "fixtures" </> "amp")
  values <- newIORef Map.empty
  let sidecar = AmpSidecar python [fixture] 10 defaultSidecarPool
      continuations =
        AmpContinuationOperations
          { store = \operationId payload -> do
              let reference = "amp-continuation-" <> operationId
              modifyIORef' values (Map.insert reference payload)
              pure reference
          , load = \reference -> maybe (fail "no continuation") pure . Map.lookup reference =<< readIORef values
          }
      turns = AmpTurnOperations (\operationId _ _ -> pure ("amp-turn-" <> operationId))
  adapter <-
    newAmpRuntimeAdapter
      (ampRuntimeConfig "bench/project")
      (ampContinuationCodec continuations)
      turns
      AmpAdapterOptions {sdkExecute = officialExecute sidecar, clock = getMonotonicTime, hooks = officialProbeHooks sidecar}
  ready =<< probeAmp adapter
  let selected =
        ok . mkResolutionSnapshot 1 $
          [ ampA1
          , ampConnectionCapabilities
          , ampProgramCapabilities
          , ampProviderManagedHands
          , ampProviderManagedTerritory
          , ampContinuationCapabilities
          , hostFencedEffect
          ]
      connection = ConnectionView (ok (mkConnectionIdentity "amp-connection" "amp" "safe-account-fingerprint" "platform-managed")) StatusReady 3 4 Nothing
  next <- counter
  pure $ do
    n <- next
    binding <- newAmpProviderManagedBinding
    now <- getMonotonicTime
    let episode = ok (mkEpisodeId ("episode-" <> n))
    attachment <- newEpisodeAttachment episode selected (ampAttachmentBinding binding) ("attachment-" <> n) (now + 30) episodeOptions
    invocation <- either (fail . show) pure (newAmpRuntimeInvocation ("operation-" <> n) episode (ok (mkTurnId ("turn-" <> n))) "prompt" connection attachment binding Nothing)
    operation <- startAmp adapter invocation
    completed =<< waitAmpOperation operation (Just 30)
    verified =<< closeAmpOperation operation
    settled attachment

-- | The four rows, each over its own directory under @tmp@.
turnsBenchmarks :: FilePath -> IO [Benchmark]
turnsBenchmarks tmp = do
  python <- pythonExecutable
  let build name make = do
        let directory = tmp </> name
        createDirectory directory
        bench name . whnfIO <$> make python directory
  sequence
    [ build "codex-turn" codexTurn
    , build "codex-a3-service-turn" codexA3ServiceTurn
    , build "claude-turn" claudeTurn
    , build "amp-turn" ampTurn
    ]
