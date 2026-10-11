module Main (main) where

import AgenticusSpec qualified
import PiSpec qualified
import ProtocolSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  ProtocolSpec.spec
  PiSpec.spec
  AgenticusSpec.spec
