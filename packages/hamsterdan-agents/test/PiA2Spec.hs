-- | @tests/unit/host/test_pi_a2.py@: the host-owned Pi A2 policy and
-- authority boundaries.
module PiA2Spec (spec, directEnvironment) where

import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, void)
import Data.Bits (xor, (.&.))
import Data.ByteArray qualified as BA
import Data.ByteString qualified as BS
import Data.IORef
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hamsterdan.Host.PiA2
import Petrus.Agenticus.Connection.Key (KeyContext, KeyOperations (..), mkKeyContext)
import Petrus.Agenticus.Error (AgenticusError (..), throwLeft)
import Petrus.Agenticus.Error qualified as AE
import Petrus.Agenticus.Hands.Contract (ToolMethod (..))
import Petrus.Agenticus.Runtime.PiA2Host
  ( PiA2RuntimeHostConfig (..)
  , closeHost
  , hostAuthorityRequested
  , hostConfig
  , hostDescriptor
  , probeHost
  )
import Petrus.Motus.Worker (RuntimeError (..), ValueError (..))
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory (canonicalizePath, createDirectory, doesPathExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files qualified as Posix
import System.Posix.Files (setFileCreationMask)
import Test.Hspec

withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "pi-a2"

keyContext :: Integer -> IO KeyContext
keyContext epoch = throwLeft (mkKeyContext "synthetic" epoch 1)

keyFailure :: AgenticusError -> Bool
keyFailure e = e.errorClass == AE.KeyOperationError

valueFailure :: Text -> ValueError -> Bool
valueFailure fragment (ValueError message) = fragment `T.isInfixOf` message

-- | The environment of the reference tests' direct-key configurations.
directEnvironment :: FilePath -> Text -> Text -> Text -> [(Text, Text)]
directEnvironment tmp provider model key =
  [ ("HAMSTERDAN_PI_PROVIDER", provider)
  , ("HAMSTERDAN_PI_MODEL", model)
  , ("HAMSTERDAN_PI_API_KEY", key)
  , ("HAMSTERDAN_PI_CLI_PATH", T.pack (tmp </> "cli"))
  , ("HAMSTERDAN_PI_NODE_PATH", T.pack (tmp </> "node"))
  , ("HAMSTERDAN_PI_PACKAGE_ROOT", T.pack (tmp </> "package"))
  ]

replace :: Text -> Text -> [(Text, Text)] -> [(Text, Text)]
replace name value environment = [(k, if k == name then value else v) | (k, v) <- environment]

closed :: IO Bool -> Expectation
closed action = action `shouldReturn` True

spec :: Spec
spec = describe "tests/unit/host/test_pi_a2.py" $ do
  it "test_persistent_keys_authenticate_context_tamper_and_erase" . withTmp $ \tmp -> do
    selected <- keyContext 1
    keys <- persistentKeyOperations (tmp </> "keys")
    sealed <- keys.seal selected (BA.convert ("synthetic secret" :: BS.ByteString))
    recreated <- persistentKeyOperations (tmp </> "keys")
    opened <- recreated.open selected sealed
    (BA.convert opened :: BS.ByteString) `shouldBe` "synthetic secret"
    other <- keyContext 2
    recreated.open other sealed `shouldThrow` keyFailure
    let tampered = BS.init sealed <> BS.singleton (BS.last sealed `xor` 1)
    recreated.open selected tampered `shouldThrow` keyFailure
    evidence <- recreated.erase "synthetic"
    evidence.erased `shouldBe` True
    recreated.open selected sealed `shouldThrow` keyFailure

  it "test_new_key_is_synced_before_sealing_returns" . withTmp $ \tmp -> do
    syncs <- newIORef []
    let observe fd = do
          status <- Posix.getFdStatus fd
          modifyIORef' syncs (<> [if Posix.isDirectory status then "directory" else "file" :: Text])
          defaultPiA2Hooks.fsync fd
    keys <- persistentKeyOperationsWith defaultPiA2Hooks {fsync = observe} (tmp </> "keys")
    selected <- keyContext 1
    void (keys.seal selected (BA.convert ("synthetic" :: BS.ByteString)))
    readIORef syncs `shouldReturn` ["file", "directory"]

  it "test_one_shot_supplier_transfers_mutable_buffer_once" $ do
    let source = BA.convert ("synthetic" :: BS.ByteString)
    calls <- newIORef (0 :: Int)
    supplier <- newOneShotApiKeySupplier (modifyIORef' calls (+ 1) >> pure source)
    supplied <- supplier
    supplied `shouldBe` source
    supplier `shouldThrow` \(RuntimeError message) -> "already spent" `T.isInfixOf` message
    readIORef calls `shouldReturn` 1

  it "test_owned_composition_and_probe_do_not_request_authority" . withTmp $ \tmp ->
    bracket (composeOwnedPiA2With defaultPiA2Hooks tmp Nothing) (\owned -> void (closeHost owned.host)) $ \owned -> do
      hostDescriptor.identity.name `shouldBe` "pi.native.a2.local"
      owned.authority.connection.profile `shouldBe` "api-key"
      hostAuthorityRequested owned.host `shouldReturn` False
      void (probeHost owned.host)
      hostAuthorityRequested owned.host `shouldReturn` False

  it "test_owned_composition_retains_a_finite_runtime_deadline" . withTmp $ \tmp ->
    bracket (composeOwnedPiA2 tmp Nothing) (void . closeHost) $ \host -> do
      let config = hostConfig host
      (config.wallTimeout, config.attachmentTimeout, config.cancellationGrace) `shouldBe` (900, 960, 5)
      (config.attachmentTimeout > config.wallTimeout + config.cancellationGrace) `shouldBe` True
      config.maxToolCalls `shouldBe` 32
      config.capabilities `shouldBe` Set.fromList [WorkspaceRead, WorkspaceSearch, WorkspaceWrite]

  it "test_direct_key_config_redacts_authority_and_supplies_it_once" . withTmp $ \tmp -> do
    config <- installationFromEnvironment (directEnvironment tmp "openai" "gpt-5.6-sol" "synthetic-direct-key") Nothing
    ("synthetic-direct-key" `T.isInfixOf` T.pack (show config)) `shouldBe` False
    bracket (composeOwnedPiA2With defaultPiA2Hooks (tmp </> "state") (Just config)) (\owned -> void (closeHost owned.host)) $ \owned -> do
      void (probeHost owned.host)
      hostAuthorityRequested owned.host `shouldReturn` False
      supplied <- owned.authority.supplyApiKey
      (BA.convert supplied :: BS.ByteString) `shouldBe` "synthetic-direct-key"
      owned.authority.supplyApiKey `shouldThrow` \(RuntimeError message) -> "already spent" `T.isInfixOf` message

  describe "test_direct_key_config_refuses_missing_or_malformed_authority" $
    forM_ ["", "short", T.replicate 513 "x", T.replicate 16 "x" <> "\n", T.replicate 16 "x" <> "\0", T.replicate 16 "\233"] $ \value ->
      it (show (T.take 20 value)) . withTmp $ \tmp ->
        installationFromEnvironment (directEnvironment tmp "openai" "gpt-5.6-sol" value) Nothing
          `shouldThrow` \(ValueError _) -> True

  it "test_direct_key_config_refuses_retired_file_inputs" $
    installationFromEnvironment [("HAMSTERDAN_PI_API_KEY_FILE", "/stale/key")] Nothing
      `shouldThrow` valueFailure "retired Pi credential-file"

  describe "test_installation_config_rejects_relative_custody_paths" $
    forM_ ["HAMSTERDAN_PI_CLI_PATH", "HAMSTERDAN_PI_NODE_PATH", "HAMSTERDAN_PI_PACKAGE_ROOT"] $ \name ->
      it (T.unpack name) . withTmp $ \tmp ->
        installationFromEnvironment
          (replace name "relative" (directEnvironment tmp "anthropic" "claude-sonnet-4-5" "synthetic-direct-authority"))
          Nothing
          `shouldThrow` valueFailure "must be absolute"

  describe "test_installation_config_accepts_only_qualified_provider_model_pairs" $
    forM_
      [ ("anthropic", "claude-sonnet-4-5")
      , ("openai", "gpt-5.6-sol")
      , ("openrouter", "anthropic/claude-sonnet-4.5")
      ]
      $ \(provider, model) -> it (T.unpack provider) . withTmp $ \tmp -> do
        let environment = directEnvironment tmp provider model "synthetic-direct-authority"
        ((.provider) <$> installationFromEnvironment environment Nothing) `shouldReturn` provider
        installationFromEnvironment (replace "HAMSTERDAN_PI_MODEL" "unqualified" environment) Nothing
          `shouldThrow` valueFailure "qualified"

  it "test_existing_state_refuses_provider_change_before_runtime_construction" . withTmp $ \tmp -> do
    let state = tmp </> "state"
    closed (composeOwnedPiA2 state Nothing >>= closeHost)
    installationFromEnvironment (directEnvironment tmp "openai" "gpt-5.6-sol" "synthetic-direct-authority") (Just state)
      `shouldThrow` valueFailure "existing Pi A2 state"

  it "test_competing_provider_binding_winner_is_revalidated_before_runtime_construction" . withTmp $ \tmp -> do
    let state = tmp </> "state"
        root = state </> "pi-a2"
        competing source destination = do
          BS.writeFile destination "openai\ngpt-5.6-sol\n"
          Posix.setFileMode destination 0o600
          defaultPiA2Hooks.link source destination
    composeOwnedPiA2With defaultPiA2Hooks {link = competing} state Nothing
      `shouldThrow` valueFailure "different provider/model"
    BS.readFile (root </> "installation") `shouldReturn` "openai\ngpt-5.6-sol\n"
    doesPathExist (root </> "runtime-host") `shouldReturn` False

  it "test_installation_binding_survives_a_crash_cut_after_atomic_publication" . withTmp $ \tmp -> do
    let state = tmp </> "state"
        root = state </> "pi-a2"
    cuts <- newIORef (0 :: Int)
    resolvedRoot <- (\resolved -> resolved </> "state" </> "pi-a2") <$> canonicalizePath tmp
    let cutAfterPublication real path = do
          count <- atomicModifyIORef' cuts (\n -> (n + 1, n + 1))
          if path == resolvedRoot && count == 1 then throwIO (userError "synthetic crash cut") else real path
    composeOwnedPiA2With defaultPiA2Hooks {syncDirectory = cutAfterPublication} state Nothing
      `shouldThrow` \e -> "synthetic crash cut" `T.isInfixOf` T.pack (show (e :: IOError))
    BS.readFile (root </> "installation") `shouldReturn` "anthropic\nclaude-sonnet-4-5\n"
    doesPathExist (root </> "runtime-host") `shouldReturn` False
    closed (composeOwnedPiA2 state Nothing >>= closeHost)

  it "test_installation_binding_is_restartable_under_a_restrictive_umask" . withTmp $ \tmp -> do
    let root = tmp </> "pi-a2"
    createDirectory root
    Posix.setFileMode root 0o700
    bracket (setFileCreationMask 0o777) setFileCreationMask $ \_ -> bindInstallation root "openai" "gpt-5.6-sol"
    status <- Posix.getFileStatus (root </> "installation")
    (Posix.fileMode status .&. 0o7777) `shouldBe` 0o600
    bindInstallation root "openai" "gpt-5.6-sol"

  it "test_production_composition_does_not_inject_provider_or_client_factory" $ do
    root <- repoRoot
    source <- TIO.readFile (root </> "packages" </> "hamsterdan-agents" </> "src" </> "Hamsterdan" </> "Host" </> "PiA2.hs")
    let (_, production) = T.breakOn "composeRuntime = \\config authority -> " source
    ("composePiA2Runtime config authority getMonotonicTime" `T.isPrefixOf` T.drop (T.length "composeRuntime = \\config authority -> ") production)
      `shouldBe` True
    forM_ ["composePiA2RuntimeWith", "composePiA2ScriptedClientRuntime", "PiHelperFactory"] $ \needle ->
      (needle `T.isInfixOf` source) `shouldBe` False
