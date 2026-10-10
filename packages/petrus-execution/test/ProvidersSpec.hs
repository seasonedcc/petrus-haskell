-- | Cross-provider halves of @test_execution_contract.py@: the public
-- surface, semantic capability discovery and foreign-lease destroy, checked
-- across all four providers at once.
module ProvidersSpec (spec) where

import Control.Monad (forM_)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Providers.Docker (dockerProvider, newDockerEnvironment)
import Petrus.Motus.Execution.Providers.E2b (E2bConfig (..), defaultE2bConfig, e2bProvider, missingSdk, newE2bEnvironment)
import Petrus.Motus.Execution.Providers.Gondolin (gondolinConfig, gondolinProvider, newGondolinEnvironment)
import Petrus.Motus.Execution.Providers.Local (localProvider, newLocalProcessEnvironment)
import Support
import System.FilePath ((</>))
import Test.Hspec

allProviders :: FilePath -> IO [EnvironmentProvider]
allProviders tmp =
  sequenceA
    [ localProvider <$> newLocalProcessEnvironment
    , dockerProvider <$> newDockerEnvironment
    , e2bProvider <$> newE2bEnvironment defaultE2bConfig {e2bSdkLoader = expectationFailure "must not load the E2B SDK" >> missingSdk}
    , gondolinProvider <$> newGondolinEnvironment (tmp </> "gondolin") (gondolinConfig "unused.mjs")
    ]

expectedCapabilities :: Text -> [Text]
expectedCapabilities = \case
  "local-process" -> ["command-cancellation", "explicit-environment", "private-file-transfer", "process-group", "workspace"]
  "docker" -> ["container", "explicit-environment", "recreatable-lookup", "territory-cancellation", "workspace"]
  "e2b" -> ["command-cancellation", "explicit-environment", "recreatable-lookup", "vm", "workspace"]
  "gondolin" -> ["explicit-environment", "microvm", "private-file-transfer", "recreatable-lookup", "territory-cancellation", "vm", "workspace"]
  other -> error ("unexpected provider " <> show other)

spec :: Spec
spec = describe "test_execution_contract (cross-provider)" $ do
  it "test_public_surface_is_exact_optional_safe_and_owns_its_values (bounds and capability vocabulary)" $ do
    ( maxCommandOutputBytes
      , maxPrivateFileBytes
      , maxPrivateFileNameBytes
      , maxPrivateFilesPerAttachment
      , maxPrivateFileTotalBytes
      )
      `shouldBe` (1000000, 1000000, 64, 16, 4000000)
    map
      capabilityKey
      [ capCommandCancellation
      , capContainer
      , capExplicitEnvironment
      , capMicrovm
      , capPrivateFileTransfer
      , capProcessGroup
      , capRecreatableLookup
      , capTerritoryCancellation
      , capVm
      , capWorkspace
      ]
      `shouldBe` [ "command-cancellation"
                 , "container"
                 , "explicit-environment"
                 , "microvm"
                 , "private-file-transfer"
                 , "process-group"
                 , "recreatable-lookup"
                 , "territory-cancellation"
                 , "vm"
                 , "workspace"
                 ]

  it "test_provider_capability_discovery_is_semantic_and_provider_differences_are_explicit" $ withTempDir $ \tmp -> do
    providers <- allProviders tmp
    map providerName providers `shouldBe` ["local-process", "docker", "e2b", "gondolin"]
    forM_ providers $ \provider ->
      (providerName provider, Set.map capabilityKey (providerCapabilities provider))
        `shouldBe` (providerName provider, Set.fromList (expectedCapabilities (providerName provider)))
    map (isJust . providerPrivateFiles) providers `shouldBe` [True, False, False, True]

  it "test_destroy_never_verifies_absence_for_a_foreign_provider" $ withTempDir $ \tmp -> do
    providers <- allProviders tmp
    let foreignLease = either (error . show) id (mkEnvironmentLease "foreign-cleanup" "foreign-provider" "foreign-lease" Set.empty Ready)
    forM_ providers $ \provider -> do
      result <- providerDestroy provider foreignLease
      (providerName provider, cleanupDisposition result, cleanupVerified result)
        `shouldBe` (providerName provider, Unverified, False)
