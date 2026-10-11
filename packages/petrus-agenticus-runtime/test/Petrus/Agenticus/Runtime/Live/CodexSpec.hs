-- | @tests/petrus/agenticus/runtime/test_codex_real.py@: opt-in authorized
-- acceptance for the exact Codex A2 Local and A3 Gondolin lanes.
--
-- Where the reference skips inside an opted-in test (no @codex@ CLI, no
-- @OPENAI_API_KEY@, no Gondolin SDK, image or auth file, or another image
-- build), the port fails with the same message.
module Petrus.Agenticus.Runtime.Live.CodexSpec (spec) where

import Control.Exception (throwIO, try)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding (BindingSettlement (..), MotusAttachmentBinding, motusBinding, openMotusBinding)
import Petrus.Agenticus.Attachment.Episode (AttachmentSettlement (..), EpisodeAttachment, episodeOptions, newEpisodeAttachment)
import Petrus.Agenticus.Attachment.Episode qualified as Episode
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor)
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot, mkResolutionSnapshot)
import Petrus.Agenticus.Connection.Custody (ConnectionStatus (..), ConnectionView (..), ErasureResult (..), erase, lookupConnection, mkConnectionIdentity, revoke)
import Petrus.Agenticus.Connection.Storage (ConnectionStorage (..))
import Petrus.Agenticus.Runtime.Codex
import Petrus.Agenticus.Runtime.Installation (InstalledComponent (..), ProbeDisposition (..), RuntimeInstallation (..), RuntimeProbeResult (..))
import Petrus.Agenticus.Runtime.Live.Support
import Petrus.Agenticus.Runtime.Operation (cleanupVerified)
import Petrus.Agenticus.Runtime.Pi (piConnectionCustody)
import Petrus.Agenticus.Runtime.Profiles (codexA2Local, codexA3Gondolin)
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement (..))
import Petrus.Agenticus.Thread.Continuation (ContinuationState (..), mkContinuation)
import Petrus.Agenticus.Thread.Identity (mkContinuationId, mkEpisodeId, mkThreadId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import Petrus.Motus.Execution (EnvironmentProvider, capMicrovm, capPrivateFileTransfer, capVm, mkEnvironmentSpec)
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Providers.Gondolin (GondolinConfig (..), gondolinConfig, gondolinProvider, newGondolinEnvironment)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import System.Directory (createDirectory, findExecutable, makeAbsolute, removeDirectoryRecursive)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (getSymbolicLinkStatus, intersectFileModes, isRegularFile, linkCount, removeLink, setFileMode)
import System.Posix.Files qualified as Files
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Test.Hspec

g1, g2, a3G1, a3G2 :: Text
g1 = "CODEX_A2_G1_20260803"
g2 = "CODEX_A2_G2_20260803"
a3G1 = "CODEX_A3_G1_20260803"
a3G2 = "CODEX_A3_G2_20260803"

snapshotWith :: CapabilityDescriptor -> CapabilityDescriptor -> ResolutionSnapshot
snapshotWith runtime territory =
  ok . mkResolutionSnapshot 1 $
    [ runtime
    , codexConnectionCapabilities
    , codexProgramCapabilities
    , codexCollocatedHands
    , territory
    , codexContinuationCapabilities
    , hostFencedEffect
    ]

localSnapshot, gondolinSnapshot :: ResolutionSnapshot
localSnapshot = snapshotWith codexA2Local codexLocalTerritory
gondolinSnapshot = snapshotWith codexA3Gondolin codexGondolinTerritory

-- | The in-memory Continuation and Turn stores and their operations.
data Stores = Stores
  { continuations :: Store CodexContinuationPayloadV1
  , turns :: Store (Text, Text)
  }

newStores :: IO Stores
newStores =
  Stores
    <$> newStore "live-continuation-" "conflicting live Continuation candidate"
    <*> newStore "live-turn-" "conflicting live Turn candidate"

codec :: Stores -> CodexContinuationCodec
codec s = codexContinuationCodec CodexContinuationOperations {store = remember s.continuations, load = stored s.continuations . Just}

turnOperations :: Stores -> CodexTurnOperations
turnOperations s = CodexTurnOperations (\operationId thread text -> remember s.turns operationId (thread, text))

opaqueMessages :: HandoffMessages
opaqueMessages =
  HandoffMessages
    { missing = "the authorized Gondolin cell requires its explicitly selected opaque file auth"
    , inspect = "the selected opaque file auth could not be inspected safely"
    , custodyInvariant = "the selected opaque file auth failed its custody invariant"
    , open = "the selected opaque file auth could not be opened safely"
    , read = "the selected opaque file auth could not be read safely"
    , changedDuringTransfer = "the selected opaque file auth changed or violated its bound during custody transfer"
    , notAuthority = "the selected opaque file auth changed or violated its bound during custody transfer"
    , changedBeforeCustody = "the selected opaque file auth changed before Agent Connection custody accepted it"
    , notConsumed = "the selected opaque file auth was not consumed into Agent Connection custody"
    , consume = "the selected opaque file auth could not be consumed into Agent Connection custody"
    }

-- | @_official_file_auth@: one official @codex login --with-api-key@ into a
-- private home, whose @auth.json@ becomes the opaque authority.
officialFileAuth :: FilePath -> FilePath -> IO ByteString
officialFileAuth root executable = do
  apiKey <-
    lookupEnv "OPENAI_API_KEY" >>= \case
      Just key | not (null key) -> pure key
      _ -> failWith "the authorized Codex A2 cell requires OPENAI_API_KEY for one-time official file login"
  let home = root </> "login-handoff"
  createDirectory home
  setFileMode home 0o700
  node <- maybe "." takeDirectory <$> findExecutable "node"
  let path = T.unpack (T.intercalate ":" (unique [T.pack (takeDirectory executable), T.pack node, "/bin:/usr/bin"]))
      environment = [("HOME", home), ("CODEX_HOME", home), ("LANG", "C.UTF-8"), ("PATH", path)]
  login <- timeout 30000000 (readCreateProcessWithExitCode (proc executable ["login", "--with-api-key"]) {env = Just environment} (apiKey <> "\n"))
  case login of
    Just (ExitSuccess, _, _) -> pure ()
    Just _ -> failWith "official Codex file-auth bootstrap failed"
    Nothing -> failWith "official Codex file-auth bootstrap timed out"
  let auth = home </> "auth.json"
  metadata <-
    try (getSymbolicLinkStatus auth) >>= \case
      Right m -> pure m
      Left (_ :: IOError) -> failWith "official Codex file-auth bootstrap produced no handoff"
  check
    (isRegularFile metadata && Files.fileMode metadata `intersectFileModes` 0o7777 == 0o600 && linkCount metadata == 1)
    "official Codex file-auth handoff failed its private-file invariant"
  (_, value, _) <- readNoFollow auth 1000001
  check (not (B.null value) && B.length value <= 1000000) "official Codex file-auth handoff is outside the accepted bound"
  removeLink auth
  removeDirectoryRecursive home
  pure value
  where
    unique = foldr (\x acc -> x : filter (/= x) acc) []

localBinding :: FilePath -> Text -> IO MotusAttachmentBinding
localBinding root operationId = do
  let workspace = root </> ("workspace-" <> T.unpack operationId)
  createDirectory workspace
  archive <- workspaceArchive workspace
  provider <- localProvider <$> newLocalProcessEnvironment
  openMotusBinding provider ("territory-" <> operationId) (ok (mkEnvironmentSpec Nothing [capPrivateFileTransfer])) archive ("input-" <> operationId)

gondolinBinding :: FilePath -> Text -> EnvironmentProvider -> Text -> IO MotusAttachmentBinding
gondolinBinding root operationId provider image = do
  let workspace = root </> ("workspace-" <> T.unpack operationId)
  createDirectory workspace
  archive <- workspaceArchive workspace
  openMotusBinding
    provider
    ("territory-" <> operationId)
    (ok (mkEnvironmentSpec (Just image) [capVm, capMicrovm, capPrivateFileTransfer]))
    archive
    ("input-" <> operationId)

-- | One Turn: start, wait, close; the output text and the payload.
turn
  :: CodexRuntimeAdapter
  -> Stores
  -> LiveCustody
  -> Text
  -> EpisodeAttachment
  -> (Text, Text, Text)
  -> Maybe Text
  -> Double
  -> IO (Text, CodexContinuationPayloadV1, RuntimeTurnSettlement)
turn adapter stores c connectionId attachment (operationId, turnId, prompt) prior wait = do
  connection <- lookupConnection c.custody connectionId
  let continuation =
        prior >>= \reference ->
          Just . ok $
            mkContinuation
              (ok (mkContinuationId (connectionId <> "-continuation-1")))
              (ok (mkThreadId (connectionId <> "-thread")))
              codexContinuationDescriptor
              reference
              ContinuationInUse
  invocation <-
    newCodexRuntimeInvocation
      CodexRuntimeInvocation
        { operationId
        , episodeId = Episode.episodeId attachment
        , turnId = ok (mkTurnId turnId)
        , prompt
        , connection
        , attachment
        , continuation
        }
  operation <- startCodex adapter invocation
  result <- waitCodexOperation operation (Just wait)
  (result.outcome, result.acceptedAppends) `shouldBe` (TurnCompleted, 1)
  cleanup <- closeCodexOperation operation
  cleanupVerified cleanup `shouldBe` True
  (_, output) <- stored stores.turns result.outputReference
  payload <- stored stores.continuations result.continuationReference
  pure (output, payload, result)

private :: ByteString -> CodexContinuationPayloadV1 -> AttachmentSettlement -> Bool
private auth payload settled = not (auth `B.isInfixOf` settled.archive) && not (payload.rollout `B.isInfixOf` settled.archive)

spec :: Spec
spec = describe "test_codex_real" $ do
  live
    "test_exact_codex_a2_local_fresh_then_native_resume"
    "PETRUS_CV16_CODEX_LIVE"
    "the authorized Codex A2 Local cell"
    $ withSystemTempDirectory "codex-live"
    $ \tmp -> do
      configured <- lookupEnv "PETRUS_CV16_CODEX_BIN"
      found <- maybe (findExecutable "codex") (pure . Just) (configured >>= \p -> if null p then Nothing else Just p)
      executable <- maybe (failWith "the exact Codex CLI is not installed") makeAbsolute found
      auth <- officialFileAuth tmp executable

      keys <- liveKeys "live connection key is unavailable"
      c <- openLiveCustody tmp keys
      _ <-
        authorizeLive
          c
          "codex-live-host"
          "codex-live-enroll"
          (ok (mkConnectionIdentity "codex-live" "codex" (sha256Text "codex-live-account") "file-auth"))
          auth
          "codex-live-authorize"
      stores <- newStores
      defaults <- codexAdapterOptions
      let hooks = defaults.hooks
          which name = if name == "codex" then pure (Just executable) else hooks.which name
      operations <- piConnectionCustody c.custody
      adapter <-
        newCodexRuntimeAdapter
          (codexRuntimeConfig "codex-live-host") {credentialTtl = 240, commandTimeout = 180, cancellationGrace = 10}
          (codec stores)
          (turnOperations stores)
          operations
          defaults {hooks = hooks {which}}
      probe <- probeCodex adapter
      probe.disposition `shouldBe` ProbeReady
      (map (.version) . (.components) <$> probe.installation) `shouldSatisfy` maybe False ((== Just codexVersion) . firstOf)

      now <- getMonotonicTime
      binding1 <- localBinding tmp "g1"
      attachment1 <- newEpisodeAttachment (ok (mkEpisodeId "codex-live-episode-1")) localSnapshot (motusBinding binding1) "codex-live-attachment-1" (now + 240) episodeOptions
      (output1, payload1, result1) <-
        turn adapter stores c "codex-live" attachment1 ("codex-live-g1", "codex-live-turn-1", "Reply with exactly " <> g1 <> ". Do not run commands or use tools.") Nothing 240
      (g1 `T.isInfixOf` output1 && not (T.null payload1.threadId)) `shouldBe` True
      settled1 <- settleVerified attachment1 10
      private auth payload1 settled1 `shouldBe` True

      later <- getMonotonicTime
      binding2 <- localBinding tmp "g2"
      attachment2 <-
        Episode.successor attachment1 (ok (mkEpisodeId "codex-live-episode-2")) localSnapshot (motusBinding binding2) "codex-live-attachment-2" (later + 240) Nothing Nothing
      (output2, payload2, _) <-
        turn
          adapter
          stores
          c
          "codex-live"
          attachment2
          ("codex-live-g2", "codex-live-turn-2", "State the prior marker, then " <> g2 <> ". Do not run commands or use tools.")
          result1.continuationReference
          240
      payload2.threadId `shouldBe` payload1.threadId
      ordered output2 [g1, g2] `shouldBe` True
      settled2 <- settleVerified attachment2 10
      private auth payload2 settled2 `shouldBe` True
      ((.stateVersion) <$> lookupConnection c.custody "codex-live") `shouldReturn` 3
      isEmptyDirectory c.materialized `shouldReturn` True

      _ <- revoke c.custody "codex-live" "codex-live-revoke"
      erased <- erase c.custody "codex-live" "codex-live-erase"
      erased.connection.status `shouldBe` StatusReauthorizationRequired
      c.storage.close

  live
    "test_exact_codex_a3_gondolin_fresh_then_native_resume"
    "PETRUS_CV16_CODEX_GONDOLIN_LIVE"
    "the authorized Codex A3 Gondolin cell"
    $ withSystemTempDirectory "codex-gondolin-live"
    $ \tmp -> do
      let selected name = lookupEnv name >>= \v -> pure (v >>= \x -> if null x then Nothing else Just x)
      sdk <- selected "PETRUS_REAL_GONDOLIN_SDK_MODULE"
      image <- selected "PETRUS_REAL_GONDOLIN_IMAGE"
      authName <- selected "PETRUS_CV16_CODEX_AUTH_FILE"
      (sdk', image', authSource) <- case (sdk, image, authName) of
        (Just s, Just i, Just a) -> pure (T.pack s, T.pack i, a)
        _ -> failWith "the authorized Codex A3 cell requires the selected Gondolin SDK, image, and opaque auth"
      buildId <- lookupEnv "PETRUS_REAL_GONDOLIN_BUILD_ID"
      check
        (image' == codexGondolinImageRef && buildId == Just (T.unpack codexGondolinBuildId))
        "the authorized Codex A3 cell requires the exact selected immutable image build"
      (auth, originalIdentity) <- readHandoff opaqueMessages authSource 1000000 False ""

      keys <- liveKeys "live connection key is unavailable"
      c <- openLiveCustody tmp keys
      _ <-
        authorizeLive
          c
          "codex-gondolin-host"
          "codex-gondolin-enroll"
          (ok (mkConnectionIdentity "codex-gondolin" "codex" (sha256Text "codex-gondolin-account") "file-auth"))
          auth
          "codex-gondolin-authorize"
      let eraseCustody = do
            outcome <- tryAny $ do
              _ <- revoke c.custody "codex-gondolin" "codex-gondolin-revoke"
              erased <- erase c.custody "codex-gondolin" "codex-gondolin-erase"
              pure erased.connection.status
            case outcome of
              Right StatusReauthorizationRequired -> pure ()
              Right _ -> failWith "the Gondolin Agent Connection did not finish in reauthorization-required state"
              Left _ -> failWith "the Gondolin Agent Connection cleanup could not be verified"
      flip withCleanup c.storage.close . flip withCleanup eraseCustody $ do
        consumeHandoff opaqueMessages authSource originalIdentity
        stores <- newStores
        defaults <- codexAdapterOptions
        operations <- piConnectionCustody c.custody
        adapter <-
          newCodexGondolinRuntimeAdapter
            (codexRuntimeConfig "codex-gondolin-host") {credentialTtl = 300, commandTimeout = 240, cancellationGrace = 15}
            (codec stores)
            (turnOperations stores)
            operations
            defaults
        environment <-
          newGondolinEnvironment (tmp </> "gondolin") (gondolinConfig sdk') {gondolinLeaseTtl = 600, gondolinStartupTimeout = 120}
        let provider = gondolinProvider environment

        binding1 <- gondolinBinding tmp "a3-g1" provider image'
        now <- getMonotonicTime
        attachment1 <-
          newEpisodeAttachment (ok (mkEpisodeId "codex-gondolin-episode-1")) gondolinSnapshot (motusBinding binding1) "codex-gondolin-attachment-1" (now + 300) episodeOptions
        (payload1, result1, settled1) <- do
          outcome <- tryAny $ do
            probe1 <- probeCodexGondolin adapter (Just attachment1)
            probe1.disposition `shouldBe` ProbeReady
            (map (.version) . (.components) <$> probe1.installation) `shouldSatisfy` maybe False ((== Just codexGondolinVersion) . firstOf)
            (output1, payload1, result1) <-
              turn
                adapter
                stores
                c
                "codex-gondolin"
                attachment1
                ("codex-gondolin-g1", "codex-gondolin-turn-1", "Reply with exactly " <> a3G1 <> ". Do not run commands or use tools.")
                Nothing
                300
            unless (a3G1 `T.isInfixOf` output1 && not (T.null payload1.threadId)) $
              failWith "the first Gondolin Codex marker or native thread identity was absent"
            pure (payload1, result1)
          settled1 <- Episode.settle attachment1 15
          either throwIO (\(p, r) -> pure (p, r, settled1)) outcome
        settled1.settlement.verified `shouldBe` True
        unless (private auth payload1 settled1) $ failWith "private Codex state entered the first Gondolin workspace archive"
        isEmptyDirectory (tmp </> "gondolin") `shouldReturn` True

        binding2 <- gondolinBinding tmp "a3-g2" provider image'
        later <- getMonotonicTime
        attachment2 <-
          Episode.successor
            attachment1
            (ok (mkEpisodeId "codex-gondolin-episode-2"))
            gondolinSnapshot
            (motusBinding binding2)
            "codex-gondolin-attachment-2"
            (later + 300)
            Nothing
            Nothing
        (payload2, settled2) <- do
          outcome <- tryAny $ do
            probe2 <- probeCodexGondolin adapter (Just attachment2)
            probe2.disposition `shouldBe` ProbeReady
            (output2, payload2, _) <-
              turn
                adapter
                stores
                c
                "codex-gondolin"
                attachment2
                ("codex-gondolin-g2", "codex-gondolin-turn-2", "State the prior marker, then " <> a3G2 <> ". Do not run commands or use tools.")
                result1.continuationReference
                300
            when (payload2.threadId /= payload1.threadId) $
              failWith "the Gondolin Codex native thread identity changed across Episodes"
            unless (ordered output2 [a3G1, a3G2]) $
              failWith "the resumed Gondolin Codex marker order was not preserved"
            pure payload2
          settled2 <- Episode.settle attachment2 15
          either throwIO (\p -> pure (p, settled2)) outcome
        settled2.settlement.verified `shouldBe` True
        unless (private auth payload2 settled2) $ failWith "private Codex state entered the second Gondolin workspace archive"
        isEmptyDirectory (tmp </> "gondolin") `shouldReturn` True
        ((.stateVersion) <$> lookupConnection c.custody "codex-gondolin") `shouldReturn` 3
        isEmptyDirectory c.materialized `shouldReturn` True
  where
    firstOf = \case
      x : _ -> Just x
      [] -> Nothing
