-- | @tests/petrus/agenticus/runtime/test_pi_real.py@: the exact
-- credential-free Pi A2 probe and the authorized G1→G2 cell.
--
-- The adapter probes the installed @pi@ CLI, its SDK packages and @node@
-- from @PATH@, as in production.
module Petrus.Agenticus.Runtime.Live.PiSpec (spec) where

import Control.Monad (forM_, unless)
import Data.ByteString qualified as B
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding (bindingExecution, motusBinding, openMotusBinding)
import Petrus.Agenticus.Attachment.Episode (AttachmentSettlement (..), EpisodeAttachment, episodeDeadline, episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor)
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot, mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody (ConnectionStatus (..), ConnectionView (..), ErasureResult (..), RevocationResult (..), erase, lookupConnection, mkConnectionIdentity, revoke)
import Petrus.Agenticus.Connection.Storage (ConnectionStorage (..))
import Petrus.Agenticus.Hands.Contract (ToolMethod (..))
import Petrus.Agenticus.Hands.Gateway (GatewayCounters (..), HandsGateway, counters)
import Petrus.Agenticus.Hands.Grants (CapabilityGrant (..), grantSpec, openGrant)
import Petrus.Agenticus.Hands.Workspace (defaultCommandTimeout, newMotusWorkspaceAdapter, workspaceHandsAdapter)
import Petrus.Agenticus.Runtime.Installation (InstalledComponent (..), ProbeDisposition (..), RuntimeInstallation (..), RuntimeProbeResult (..))
import Petrus.Agenticus.Runtime.Live.Support
import Petrus.Agenticus.Runtime.Operation (cleanupVerified)
import Petrus.Agenticus.Runtime.Pi
import Petrus.Agenticus.Runtime.Profiles (piNativeA2Local)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..))
import Petrus.Agenticus.Thread.Continuation (ContinuationState (..), mkContinuation)
import Petrus.Agenticus.Thread.Identity (EpisodeId, mkContinuationId, mkEpisodeId, mkThreadId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import Petrus.Motus.Execution (defaultSpec)
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Hspec
import Text.Read (readMaybe)

safeCapabilities :: Set.Set Text
safeCapabilities = Set.fromList ["runtime.cancel", "runtime.continue", "runtime.local", "runtime.harness-owned"]

snapshot :: CapabilityDescriptor -> ResolutionSnapshot
snapshot connection =
  ok . mkResolutionSnapshot 1 $
    [ piNativeA2Local
    , connection
    , piProgramCapabilities
    , piCollocatedHands
    , piLocalTerritory
    , piContinuationCapabilities
    , hostFencedEffect
    ]

-- | @_NoCustody@: credential-free qualification may not touch authority.
noCustody :: PiConnectionCustody
noCustody =
  PiConnectionCustody
    { materialize = \_ _ _ _ _ -> failWith "credential-free qualification may not materialize authority"
    , activate = \_ _ -> failWith "credential-free qualification may not activate authority"
    , admitResult = \_ _ -> failWith "credential-free qualification may not admit a result"
    , checkpoint = \_ _ -> failWith "credential-free qualification may not checkpoint authority"
    , release = \_ _ -> failWith "credential-free qualification may not release authority"
    }

data Stores = Stores
  { continuations :: Store PiContinuationPayloadV1
  , turns :: Store Text
  }

newStores :: IO Stores
newStores =
  Stores
    <$> newStore "live-pi-continuation-" "live Pi Continuation custody conflict"
    <*> newStore "live-pi-turn-" "live Pi Turn custody conflict"

-- | @_adapter@: a project binding and a private runtime root under @root@.
adapterFor :: FilePath -> Stores -> PiConnectionCustody -> Text -> Text -> Bool -> IO PiRuntimeAdapter
adapterFor root stores custody provider model ccPatch = do
  let working = root </> "project-binding"
      runtime = root </> "runtime"
  createDirectoryIfMissing False working
  createDirectoryIfMissing False runtime
  setFileMode runtime 0o700
  newPiRuntimeAdapter
    (piRuntimeConfig provider model working runtime)
      { hostId = "pi-live-host"
      , ccPatch
      , credentialTtl = 240
      , wallTimeout = 180
      , cancellationGrace = 15
      }
    (piContinuationCodec PiContinuationOperations {store = remember stores.continuations, load = stored stores.continuations . Just})
    PiTurnOperations {storeTurn = remember stores.turns}
    custody
    getMonotonicTime
    Nothing

-- | @_attachment@: a workspace holding @marker.txt@, its Local territory,
-- the Episode Attachment (fresh, or the successor of @prior@), its gateway
-- and a grant of @workspace_read@ alone.
attachmentFor :: FilePath -> Text -> EpisodeId -> Text -> Maybe EpisodeAttachment -> CapabilityDescriptor -> IO (EpisodeAttachment, HandsGateway, CapabilityGrant)
attachmentFor root operationId episode marker' prior connection = do
  let source = root </> ("workspace-" <> T.unpack operationId)
  createDirectory source
  writeFile (source </> "marker.txt") (T.unpack marker')
  provider <- localProvider <$> newLocalProcessEnvironment
  archive <- workspaceArchive source
  binding <- openMotusBinding provider ("territory-" <> operationId) defaultSpec archive ("input-" <> operationId)
  now <- getMonotonicTime
  let attachmentId = "pi-live-attachment-" <> operationId
  attachment <- case prior of
    Nothing -> newEpisodeAttachment episode (snapshot connection) (motusBinding binding) attachmentId (now + 240) episodeOptions
    Just p -> Episode.successor p episode (snapshot connection) (motusBinding binding) attachmentId (now + 240) Nothing Nothing
  execution <- bindingExecution binding
  workspace <- newMotusWorkspaceAdapter provider execution ["/usr/bin/true"] defaultCommandTimeout
  gateway <- Episode.gateway attachment (workspaceHandsAdapter workspace) 256
  grant <- openGrant (Episode.grants attachment) (grantSpec [WorkspaceRead] (episodeDeadline attachment) 4)
  pure (attachment, gateway, grant)

handoffMessages :: HandoffMessages
handoffMessages =
  HandoffMessages
    { missing = "the approved Pi handoff could not be inspected safely"
    , inspect = "the approved Pi handoff could not be inspected safely"
    , custodyInvariant = "the approved Pi handoff failed its private-file custody invariant"
    , open = "the approved Pi handoff could not be opened safely"
    , read = "the approved Pi handoff could not be read safely"
    , changedDuringTransfer = "the approved Pi handoff changed or violated its bound during custody transfer"
    , notAuthority = "the approved Pi handoff is not valid runtime authority"
    , changedBeforeCustody = "the approved Pi handoff changed before Agent Connection custody accepted it"
    , notConsumed = "the approved Pi handoff was not consumed into Agent Connection custody"
    , consume = "the approved Pi handoff could not be consumed safely"
    }

-- | @_required(name)@.
coordinate :: String -> IO Text
coordinate name = T.pack <$> required name "live Pi qualification requires every explicit authority coordinate"

-- | @PETRUS_CV16_PI_AUTH_PROFILE@, @api-key@ by default.
authProfile :: String -> IO Text
authProfile message = do
  profile <- maybe "api-key" T.pack <$> lookupEnv "PETRUS_CV16_PI_AUTH_PROFILE"
  check (profile `elem` ["api-key", "subscription", "cc-patch-subscription"]) message
  pure profile

nodeVersion :: Text -> Maybe [Int]
nodeVersion = traverse (readMaybe . T.unpack) . T.splitOn "."

spec :: Spec
spec = describe "test_pi_real" $ do
  live
    "test_exact_pi_a2_sdk_ai_and_node"
    "PETRUS_CV16_PI_QUALIFY"
    "the exact credential-free Pi A2 probe"
    $ withSystemTempDirectory "pi-qualify"
    $ \tmp -> do
      provider <- coordinate "PETRUS_CV16_PI_PROVIDER"
      model <- coordinate "PETRUS_CV16_PI_MODEL"
      profile <- authProfile "Pi qualification requires an exact authority profile"
      let ccPatch = profile == "cc-patch-subscription"
      stores <- newStores
      adapter <- adapterFor tmp stores noCustody provider model ccPatch
      result <- probe adapter probePaths
      result.disposition `shouldBe` ProbeReady
      installation <- maybe (failWith "the ready probe carries no installation") pure result.installation
      let versions = Map.fromList [(c.name, c.version) | c <- installation.components]
      Map.keysSet versions `shouldBe` Set.fromList (["pi-coding-agent", "pi-ai", "node"] <> ["pi-cc-patch" | ccPatch])
      (Map.lookup "pi-coding-agent" versions, piSdkVersion) `shouldBe` (Just "0.83.0", "0.83.0")
      (Map.lookup "pi-ai" versions, piAiVersion) `shouldBe` (Just "0.83.0", "0.83.0")
      if ccPatch then (Map.lookup "pi-cc-patch" versions, piCcPatchVersion) `shouldBe` (Just "1.0.1", "1.0.1") else pure ()
      (Map.lookup "node" versions >>= nodeVersion) `shouldSatisfy` maybe False (>= [22, 19, 0])
      installation.capabilities `shouldBe` safeCapabilities
      storedCount stores.continuations `shouldReturn` 0
      storedCount stores.turns `shouldReturn` 0
      isEmptyDirectory (tmp </> "runtime") `shouldReturn` True

  live
    "test_exact_pi_a2_fresh_then_native_resume"
    "PETRUS_CV16_PI_LIVE"
    "the authorized Pi A2 G1→G2 cell"
    $ withSystemTempDirectory "pi-live"
    $ \tmp -> do
      handoff <- T.unpack <$> coordinate "PETRUS_CV16_PI_AUTH_FILE"
      provider <- coordinate "PETRUS_CV16_PI_PROVIDER"
      model <- coordinate "PETRUS_CV16_PI_MODEL"
      profile <- authProfile "live Pi qualification requires an exact authority profile"
      let subscription = profile /= "api-key"
      (authority, handoffIdentity) <- readHandoff handoffMessages handoff (if subscription then 1000000 else 8192) (not subscription) ""
      let connectionCapabilities
            | profile == "cc-patch-subscription" = piCcPatchConnectionCapabilities
            | subscription = piSubscriptionConnectionCapabilities
            | otherwise = piConnectionCapabilities
      keys <- liveKeys "live Pi connection key is unavailable"
      c <- openLiveCustody tmp keys
      _ <-
        authorizeLive
          c
          "pi-live-host"
          "pi-live-enroll"
          (ok (mkConnectionIdentity "pi-live" provider (sha256Text "pi-live-account") profile))
          authority
          "pi-live-authorize"
      attachments <- newIORef []
      let runtimeRoot = tmp </> "runtime"
          cleanup =
            ( do
                opened <- readIORef attachments
                forM_ opened $ \attachment -> do
                  done <- Episode.settled attachment
                  unless done (() <$ Episode.settle attachment 15)
                finishConnection c "pi-live" "pi-live-revoke" "pi-live-erase" "the Pi Agent Connection did not finish reauthorization-required"
                isEmptyDirectory c.materialized `shouldReturn` True
                exists <- doesDirectoryExist runtimeRoot
                if exists then isEmptyDirectory runtimeRoot `shouldReturn` True else pure ()
            )
              `withCleanup` c.storage.close
      flip withCleanup cleanup $ do
        stores <- newStores
        operations <- piConnectionCustody c.custody
        adapter <- adapterFor tmp stores operations provider model (profile == "cc-patch-subscription")
        ((.disposition) <$> probe adapter probePaths) `shouldReturn` ProbeReady
        consumeHandoff handoffMessages handoff handoffIdentity

        marker1 <- marker "PI_A2_" 8
        marker2 <- marker "PI_A2_" 8
        workspace1 <- marker "PI_WORKSPACE_" 8
        let start operationId turnId prompt attachment gateway grant prior = do
              connection <- lookupConnection c.custody "pi-live"
              invocation <-
                newPiRuntimeInvocation
                  PiRuntimeInvocation
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
              operation <- startPi adapter invocation
              result <- waitPiOperation operation (Just 240)
              (result.outcome, result.acceptedAppends) `shouldBe` (TurnCompleted, 1)
              closed <- closePiOperation operation
              cleanupVerified closed `shouldBe` True
              output <- stored stores.turns result.outputReference
              payload <- stored stores.continuations result.continuationReference
              entries <- (.adapterEntries) <$> counters gateway
              entries `shouldSatisfy` (>= 1)
              pure (output, payload, result)
            private payload settled = not (payload.sessionJsonl `B.isInfixOf` settled.archive)
        (attachment1, gateway1, grant1) <- attachmentFor tmp "g1" (ok (mkEpisodeId "pi-live-episode-1")) workspace1 Nothing connectionCapabilities
        modifyIORef' attachments (attachment1 :)
        (output1, payload1, result1) <-
          start
            "pi-live-g1"
            "pi-live-turn-1"
            ("Use workspace_read to read marker.txt. Reply with exactly " <> marker1 <> "|" <> workspace1 <> " and no other text.")
            attachment1
            gateway1
            grant1
            Nothing
        (marker1 `T.isInfixOf` output1 && workspace1 `T.isInfixOf` output1) `shouldBe` True
        settled1 <- settleVerified attachment1 15
        private payload1 settled1 `shouldBe` True
        isEmptyDirectory runtimeRoot `shouldReturn` True
        isEmptyDirectory c.materialized `shouldReturn` True

        workspace2 <- marker "PI_WORKSPACE_" 8
        (attachment2, gateway2, grant2) <-
          attachmentFor tmp "g2" (ok (mkEpisodeId "pi-live-episode-2")) workspace2 (Just attachment1) connectionCapabilities
        modifyIORef' attachments (attachment2 :)
        let prior =
              ok $
                mkContinuation
                  (ok (mkContinuationId "pi-live-continuation-1"))
                  (ok (mkThreadId "pi-live-thread"))
                  piContinuationDescriptor
                  (maybe "" id result1.continuationReference)
                  ContinuationInUse
        (output2, payload2, _) <-
          start
            "pi-live-g2"
            "pi-live-turn-2"
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
        settled2 <- settleVerified attachment2 15
        private payload2 settled2 `shouldBe` True
        isEmptyDirectory runtimeRoot `shouldReturn` True
        isEmptyDirectory c.materialized `shouldReturn` True
        leasesReleased c `shouldReturn` True
        ((.stateVersion) <$> lookupConnection c.custody "pi-live") `shouldReturn` (if subscription then 3 else 1)

        revoked <- revoke c.custody "pi-live" "pi-live-revoke"
        revoked.connection.status `shouldBe` StatusRevoked
        erased <- erase c.custody "pi-live" "pi-live-erase"
        erased.connection.status `shouldBe` StatusReauthorizationRequired
        erased.connection.stateVersion `shouldBe` (if subscription then 4 else 2)
