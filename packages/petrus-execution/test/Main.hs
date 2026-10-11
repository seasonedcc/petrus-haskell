module Main (main) where

import ArchiveSpec qualified
import ContractSpec qualified
import CustodyInteropSpec qualified
import DockerSpec qualified
import E2bHttpSpec qualified
import E2bSpec qualified
import GondolinSpec qualified
import LocalSpec qualified
import ProviderAnswersSpec qualified
import ProvidersSpec qualified
import SubstrateSpec qualified
import System.Environment (getArgs, lookupEnv)
import System.Posix.Files (setFileCreationMask)
import Test.Hspec

main :: IO ()
main = do
  -- Extraction fixtures were generated under umask 022.
  _ <- setFileCreationMask 0o022
  lookupEnv CustodyInteropSpec.helperVariable >>= \case
    Just _ -> getArgs >>= CustodyInteropSpec.helper
    Nothing -> suite

suite :: IO ()
suite =
  hspec $ do
    ArchiveSpec.spec
    ContractSpec.spec
    ProvidersSpec.spec
    LocalSpec.spec
    DockerSpec.spec
    E2bSpec.spec
    E2bHttpSpec.spec
    GondolinSpec.spec
    SubstrateSpec.spec
    CustodyInteropSpec.spec
    ProviderAnswersSpec.spec
