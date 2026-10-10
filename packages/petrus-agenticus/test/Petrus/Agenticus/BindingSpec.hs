-- | Port of @tests/petrus/agenticus/attachment/test_binding.py@.
module Petrus.Agenticus.BindingSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_, void)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as T
import Petrus.Agenticus.Attachment.Binding
import Petrus.Agenticus.Error
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (workspaceArchive)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "petrus-agenticus-binding"

-- | The upstream @ProviderManagedBinding@: an honest provider-managed
-- binding with no Motus lease.
providerManaged :: IO (AttachmentBinding, IORef Bool)
providerManaged = do
  cancelled <- newIORef False
  pure
    ( AttachmentBinding
        { kind = "provider-managed"
        , cancel = \_ -> writeIORef cancelled True
        , exportArchive = pure "archive"
        , settle = either (error . show) pure (mkBindingSettlement "provider-managed" "clean" True "")
        , motus = Nothing
        }
    , cancelled
    )

openIn :: EnvironmentProvider -> T.Text -> FilePath -> IO MotusAttachmentBinding
openIn provider operation source = do
  archive <- workspaceArchive source
  openMotusBinding provider operation defaultSpec archive "input"

command :: CommandSpec -> Command
command = either (error . show) id . mkCommand

spec :: Spec
spec = describe "attachment/test_binding.py" $ do
  it "test_outer_binding_shape_does_not_assume_motus" $ do
    (binding, cancelled) <- providerManaged
    binding.cancel "stop"
    readIORef cancelled `shouldReturn` True
    binding.exportArchive `shouldReturn` "archive"
    ((.verified) <$> binding.settle) `shouldReturn` True
    isNothing binding.motus `shouldBe` True

  it "test_motus_binding_is_lookup_first_and_settles_exact_lease" $ withTmp $ \tmp -> do
    let source = tmp </> "source"
    createDirectory source
    provider <- localProvider <$> newLocalProcessEnvironment
    existing <- providerCreate provider "ds6-binding" defaultSpec
    binding <- openIn provider "ds6-binding" source
    bindingLeaseIdentity binding `shouldBe` leaseIdentity existing
    (leaseIdentity . attachmentLease <$> bindingExecution binding) `shouldReturn` leaseIdentity existing
    archive <- bindingExportArchive binding
    BS.null archive `shouldBe` False
    settlement <- bindingSettle binding
    settlement.verified `shouldBe` True
    settlement.disposition `shouldBe` cleanupDispositionText Clean

  forM_ ["cancel", "timeout"] $ \interruption ->
    it ("test_motus_binding_discards_interrupted_output_but_still_destroys_the_territory[" <> interruption <> "]") $
      withTmp $ \tmp -> do
        let source = tmp </> ("source-" <> interruption)
        createDirectory source
        writeFile (source </> "value") "base"
        base <- workspaceArchive source
        provider <- localProvider <$> newLocalProcessEnvironment
        binding <- openMotusBinding provider ("ds6-" <> T.pack interruption) defaultSpec base "input"
        if interruption == "cancel"
          then bindingCancel binding "stop"
          else do
            result <-
              bindingExecute
                binding
                (command (commandSpec ["/bin/sh", "-c", "printf changed > value; sleep 1"]) {specTimeout = Just (FractionalSeconds 0.05)})
            resultTimedOut result `shouldBe` True
        bindingExportArchive binding `shouldReturn` base
        ((.verified) <$> bindingSettle binding) `shouldReturn` True

  it "test_foreign_cleanup_evidence_never_verifies" $ withTmp $ \tmp -> do
    let source = tmp </> "source"
    createDirectory source
    provider <- localProvider <$> newLocalProcessEnvironment
    archive <- workspaceArchive source
    other <- providerCreate provider "other" defaultSpec
    let foreignDestroy = provider {providerDestroy = \_ -> pure (CleanupResult (leaseIdentity other) Clean "")}
    binding <- openMotusBinding foreignDestroy "ds6-foreign" defaultSpec archive "input"
    ((.verified) <$> bindingSettle binding) `shouldReturn` False
    -- Clean up both real leases through the real destroy.
    providerLookup provider "ds6-foreign" >>= mapM_ (void . providerDestroy provider)
    providerLookup provider "other" >>= mapM_ (void . providerDestroy provider)

  it "test_open_attach_failure_cleans_the_claimed_lease_or_fails_uncertain" $ withTmp $ \tmp -> do
    provider <- localProvider <$> newLocalProcessEnvironment
    archive <- workspaceArchive tmp
    let failing = provider {providerAttach = \_ _ _ -> ioError (userError "SECRET-CANARY")}
    outcome <- try (openMotusBinding failing "ds6-attach-failure" defaultSpec archive "input")
    case outcome of
      Left (e :: AgenticusError) -> do
        e.errorClass `shouldBe` MotusBindingError
        ("verified cleanup" `T.isInfixOf` e.errorMessage) `shouldBe` True
        ("SECRET-CANARY" `T.isInfixOf` T.pack (show e)) `shouldBe` False
      Right _ -> expectationFailure "attach failure must refuse"
    (isJust <$> providerLookup provider "ds6-attach-failure") `shouldReturn` False
