-- | The test binary is also the fake external programs the specs script
-- ("Fakes"): a fake mode runs instead of the suite when its flag leads the
-- arguments.
module Main (main) where

import ContainerSpec qualified
import Control.Monad (unless)
import DifferentialSpec qualified
import Fakes qualified
import FastJsonSpec qualified
import OperatorSpec qualified
import PublicationQualificationSpec qualified
import QualificationSetupLocalSpec qualified
import SecretLaunchSpec qualified
import System.Environment (getArgs)
import Test.Hspec
import TypeGuaranteeSpec qualified

main :: IO ()
main = do
  arguments <- getArgs
  handled <- Fakes.dispatch arguments
  unless handled $ hspec do
    OperatorSpec.spec
    PublicationQualificationSpec.spec
    TypeGuaranteeSpec.spec
    FastJsonSpec.spec
    SecretLaunchSpec.spec
    QualificationSetupLocalSpec.spec
    DifferentialSpec.spec
    ContainerSpec.spec
