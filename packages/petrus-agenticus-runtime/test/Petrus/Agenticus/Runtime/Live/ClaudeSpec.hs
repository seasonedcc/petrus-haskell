-- | @tests/petrus/agenticus/runtime/test_claude_real.py@: the exact
-- credential-free Claude A2 probe and the authorized G1→G2 cell.
--
-- The adapter runs with its production options: the official
-- @claude-agent-sdk@ and its bundled Claude Code through the Claude sidecar.
-- Where the reference skips inside the opted-in cell (no handoff locator or
-- handoff file), the port fails with the same message.
module Petrus.Agenticus.Runtime.Live.ClaudeSpec (spec) where

import Data.ByteString qualified as B
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding (BindingSettlement (..), bindingExecution, motusBinding, openMotusBinding)
import Petrus.Agenticus.Attachment.Episode (AttachmentSettlement (..), EpisodeAttachment, episodeDeadline, episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot, mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody (ConnectionStatus (..), ConnectionView (..), RevocationResult (..), ErasureResult (..), erase, lookupConnection, mkConnectionIdentity, revoke)
import Petrus.Agenticus.Connection.Storage (ConnectionStorage (..))
import Petrus.Agenticus.Hands.Contract (allToolMethods)
import Petrus.Agenticus.Hands.Gateway (GatewayCounters (..), HandsGateway, counters)
import Petrus.Agenticus.Hands.Grants (CapabilityGrant (..), GrantSpec (..), grantSpec, openGrant)
import Petrus.Agenticus.Hands.Workspace (defaultCommandTimeout, newMotusWorkspaceAdapter, workspaceHandsAdapter)
import Petrus.Agenticus.Runtime.Claude
import Petrus.Agenticus.Runtime.Custody
import Petrus.Agenticus.Runtime.Installation (InstalledComponent (..), ProbeDisposition (..), RuntimeInstallation (..), RuntimeProbeResult (..))
import Petrus.Agenticus.Runtime.Live.Support
import Petrus.Agenticus.Runtime.Operation (cleanupVerified)
import Petrus.Agenticus.Runtime.Profiles (claudeA2Local)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..))
import Petrus.Agenticus.Thread.Continuation (ContinuationState (..), mkContinuation)
import Petrus.Agenticus.Thread.Identity (EpisodeId, mkContinuationId, mkEpisodeId, mkThreadId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import Petrus.Motus.Execution (defaultSpec)
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import System.Directory (createDirectory, createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Hspec

snapshot :: ResolutionSnapshot
snapshot =
  ok . mkResolutionSnapshot 1 $
    [ claudeA2Local
    , claudeConnectionCapabilities
    , claudeProgramCapabilities
    , claudeCollocatedHands
    , claudeLocalTerritory
    , claudeContinuationCapabilities
    , hostFencedEffect
    ]

-- | @_NoCustody@: credential-free qualification may not touch authority.
noCustody :: HostConnectionCustody
noCustody =
  HostConnectionCustody
    { materialize = \_ _ _ _ _ -> failWith "credential-free qualification may not materialize authority"
    , activate = \_ _ -> failWith "credential-free qualification may not activate authority"
    , admitResult = \_ _ -> failWith "credential-free qualification may not admit a result"
    , checkpoint = \_ _ -> failWith "credential-free qualification may not checkpoint authority"
    , release = \_ _ -> failWith "credential-free qualification may not release authority"
    }

data Stores = Stores
  { continuations :: Store ClaudeContinuationPayloadV1
  , turns :: Store Text
  }

newStores :: IO Stores
newStores =
  Stores
    <$> newStore "live-claude-continuation-" "live Claude Continuation custody conflict"
    <*> newStore "live-claude-turn-" "live Claude Turn custody conflict"

model :: IO Text
model = maybe "claude-sonnet-4-5" T.pack <$> lookupEnv "PETRUS_CV16_CLAUDE_MODEL"

-- | @_adapter@: a project binding and a private runtime root under @root@.
adapterFor :: FilePath -> Stores -> HostConnectionCustody -> Text -> IO ClaudeRuntimeAdapter
adapterFor root stores custody model' = do
  let working = root </> "project-binding"
      runtime = root </> "runtime"
  createDirectoryIfMissing False working
  createDirectoryIfMissing False runtime
  setFileMode runtime 0o700
  options <- claudeAdapterOptions
  newClaudeRuntimeAdapter
    (claudeRuntimeConfig model' working runtime)
      { hostId = "claude-live-host"
      , credentialTtl = 240
      , wallTimeout = 180
      , cancellationGrace = 15
      , disconnectTimeout = 30
      }
    (claudeContinuationCodec ClaudeContinuationOperations {store = remember stores.continuations, load = stored stores.continuations . Just})
    (ClaudeTurnOperations (remember stores.turns))
    custody
    options

-- | @_attachment@: a workspace holding @marker.txt@, its Local territory,
-- the Episode Attachment (fresh, or the successor of @prior@), its gateway
-- and a grant of every tool.
attachmentFor :: FilePath -> Text -> EpisodeId -> Text -> Maybe EpisodeAttachment -> IO (EpisodeAttachment, HandsGateway, CapabilityGrant)
attachmentFor root operationId episode marker' prior = do
  let source = root </> ("workspace-" <> T.unpack operationId)
  createDirectory source
  writeFile (source </> "marker.txt") (T.unpack marker')
  provider <- localProvider <$> newLocalProcessEnvironment
  archive <- workspaceArchive source
  binding <- openMotusBinding provider ("territory-" <> operationId) defaultSpec archive ("input-" <> operationId)
  now <- getMonotonicTime
  let attachmentId = "claude-live-attachment-" <> operationId
  attachment <- case prior of
    Nothing -> newEpisodeAttachment episode snapshot (motusBinding binding) attachmentId (now + 240) episodeOptions
    Just p -> Episode.successor p episode snapshot (motusBinding binding) attachmentId (now + 240) Nothing Nothing
  execution <- bindingExecution binding
  workspace <- newMotusWorkspaceAdapter provider execution ["/usr/bin/true"] defaultCommandTimeout
  gateway <- Episode.gateway attachment (workspaceHandsAdapter workspace) 256
  grant <-
    openGrant
      (Episode.grants attachment)
      (grantSpec allToolMethods (episodeDeadline attachment) 8) {specWritablePaths = ["output.txt"], specAllowedArgv = [["/usr/bin/true"]]}
  pure (attachment, gateway, grant)

handoffMessages :: HandoffMessages
handoffMessages =
  HandoffMessages
    { missing = "the authorized Claude A2 cell requires its approved disposable API-key handoff"
    , inspect = "the approved Claude handoff could not be inspected safely"
    , custodyInvariant = "the approved Claude handoff failed its private-file custody invariant"
    , open = "the approved Claude handoff could not be opened safely"
    , read = "the approved Claude handoff could not be read safely"
    , changedDuringTransfer = "the approved Claude handoff changed or violated its bound during custody transfer"
    , notAuthority = "the approved Claude handoff is not valid runtime authority"
    , changedBeforeCustody = "the approved Claude handoff changed before Agent Connection custody accepted it"
    , notConsumed = "the approved Claude handoff was not consumed into Agent Connection custody"
    , consume = "the approved Claude handoff could not be consumed safely"
    }

spec :: Spec
spec = describe "test_claude_real" $ do
  live
    "test_exact_claude_a2_sdk_and_bundled_client"
    "PETRUS_CV16_CLAUDE_QUALIFY"
    "the exact credential-free Claude A2 probe"
    $ withSystemTempDirectory "claude-qualify"
    $ \tmp -> do
      stores <- newStores
      adapter <- adapterFor tmp stores noCustody =<< model
      probe <- probeClaude adapter Nothing
      probe.disposition `shouldBe` ProbeReady
      (Map.fromList . map (\c -> (c.name, c.version)) . (.components) <$> probe.installation)
        `shouldBe` Just (Map.fromList [("claude-agent-sdk", claudeSdkVersion), ("claude-code", claudeCodeVersion)])
      storedCount stores.continuations `shouldReturn` 0
      storedCount stores.turns `shouldReturn` 0

  live
    "test_exact_claude_a2_fresh_then_native_resume"
    "PETRUS_CV16_CLAUDE_LIVE"
    "the authorized Claude A2 G1→G2 cell"
    $ withSystemTempDirectory "claude-live"
    $ \tmp -> do
      handoff <- required "PETRUS_CV16_CLAUDE_AUTH_FILE" "the authorized Claude A2 cell requires its approved disposable handoff locator"
      (authority, handoffIdentity) <- readHandoff handoffMessages handoff 8192 True ""
      model' <- model
      keys <- liveKeys "live Claude connection key is unavailable"
      c <- openLiveCustody tmp keys
      _ <-
        authorizeLive
          c
          "claude-live-host"
          "claude-live-enroll"
          (ok (mkConnectionIdentity "claude-live" "claude" (sha256Text "claude-live-account") "api-key"))
          authority
          "claude-live-authorize"
      let settleConnection =
            ( tryAny (finishConnection c "claude-live" "claude-live-revoke" "claude-live-erase" "the Claude Agent Connection did not finish reauthorization-required")
                >>= either (const (failWith "the Claude Agent Connection cleanup could not be verified")) pure
            )
              `withCleanup` c.storage.close
      flip withCleanup settleConnection $ do
        stores <- newStores
        operations <- hostConnectionCustody c.custody
        adapter <- adapterFor tmp stores operations model'
        probe <- probeClaude adapter Nothing
        probe.disposition `shouldBe` ProbeReady
        consumeHandoff handoffMessages handoff handoffIdentity

        marker1 <- marker "CLAUDE_A2_" 8
        marker2 <- marker "CLAUDE_A2_" 8
        workspace1 <- marker "CLAUDE_WORKSPACE_" 8
        let episode1 = ok (mkEpisodeId "claude-live-episode-1")
            start operationId turnId prompt attachment gateway grant prior = do
              connection <- lookupConnection c.custody "claude-live"
              invocation <-
                newClaudeRuntimeInvocation
                  ClaudeRuntimeInvocation
                    { operationId
                    , episodeId = Episode.episodeId attachment
                    , turnId = ok (mkTurnId turnId)
                    , prompt
                    , connection
                    , attachment
                    , gateway
                    , grantEpoch = grant.grantEpoch
                    , continuation = prior
                    }
              operation <- startClaude adapter invocation
              result <- waitClaudeOperation operation (Just 240)
              (result.outcome, result.acceptedAppends) `shouldBe` (TurnCompleted, 1)
              cleanup <- closeClaudeOperation operation
              cleanupVerified cleanup `shouldBe` True
              output <- stored stores.turns result.outputReference
              payload <- stored stores.continuations result.continuationReference
              entries <- (.adapterEntries) <$> counters gateway
              entries `shouldSatisfy` (>= 1)
              pure (output, payload, result)
            runtimeRoot = tmp </> "runtime"
        (attachment1, gateway1, grant1) <- attachmentFor tmp "g1" episode1 workspace1 Nothing
        ((output1, payload1, result1), settled1) <-
          settledAfter attachment1 $
            start
              "claude-live-g1"
              "claude-live-turn-1"
              ("Use the workspace_read tool to read marker.txt. Then reply with exactly " <> marker1 <> "|" <> workspace1 <> " and no other text.")
              attachment1
              gateway1
              grant1
              Nothing
        (marker1 `T.isInfixOf` output1 && workspace1 `T.isInfixOf` output1) `shouldBe` True
        settled1.settlement.verified `shouldBe` True
        privateTo payload1 settled1 `shouldBe` True
        isEmptyDirectory runtimeRoot `shouldReturn` True
        isEmptyDirectory c.materialized `shouldReturn` True

        workspace2 <- marker "CLAUDE_WORKSPACE_" 8
        let episode2 = ok (mkEpisodeId "claude-live-episode-2")
        (attachment2, gateway2, grant2) <- attachmentFor tmp "g2" episode2 workspace2 (Just attachment1)
        let prior =
              ok $
                mkContinuation
                  (ok (mkContinuationId "claude-live-continuation-1"))
                  (ok (mkThreadId "claude-live-thread"))
                  claudeContinuationDescriptor
                  (maybe "" id result1.continuationReference)
                  ContinuationInUse
        ((output2, payload2, _), settled2) <-
          settledAfter attachment2 $
            start
              "claude-live-g2"
              "claude-live-turn-2"
              ( "Recall the exact marker from the prior turn, then use workspace_read to read marker.txt. Reply with exactly "
                  <> marker1
                  <> "|"
                  <> marker2
                  <> "|"
                  <> workspace2
                  <> " and no other text."
              )
              attachment2
              gateway2
              grant2
              (Just prior)
        payload2.sessionId `shouldBe` payload1.sessionId
        ordered output2 [marker1, marker2, workspace2] `shouldBe` True
        settled2.settlement.verified `shouldBe` True
        privateTo payload2 settled2 `shouldBe` True
        isEmptyDirectory runtimeRoot `shouldReturn` True
        isEmptyDirectory c.materialized `shouldReturn` True
        leasesReleased c `shouldReturn` True
        ((.stateVersion) <$> lookupConnection c.custody "claude-live") `shouldReturn` 1

        revoked <- revoke c.custody "claude-live" "claude-live-revoke"
        revoked.connection.status `shouldBe` StatusRevoked
        erased <- erase c.custody "claude-live" "claude-live-erase"
        erased.connection.status `shouldBe` StatusReauthorizationRequired
  where
    privateTo payload settled = not (payload.transcript `B.isInfixOf` settled.archive)
