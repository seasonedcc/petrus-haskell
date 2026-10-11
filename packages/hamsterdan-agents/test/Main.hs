module Main (main) where

import AgenticusSpec qualified
import InteropSpec qualified
import PiA2FactorySpec qualified
import PiA2Spec qualified
import PiSpec qualified
import PiWorkspaceSpec qualified
import ProtocolSpec qualified
import ResultDifferentialSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  ProtocolSpec.spec
  PiSpec.spec
  AgenticusSpec.spec
  PiA2Spec.spec
  PiA2FactorySpec.spec
  PiWorkspaceSpec.spec
  InteropSpec.spec
  ResultDifferentialSpec.spec
