module Main (main) where

import AgenticusSpec qualified
import PiA2FactorySpec qualified
import PiA2Spec qualified
import PiSpec qualified
import ProtocolSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  ProtocolSpec.spec
  PiSpec.spec
  AgenticusSpec.spec
  PiA2Spec.spec
  PiA2FactorySpec.spec
