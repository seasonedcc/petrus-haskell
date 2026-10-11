module Main (main) where

import PiSpec qualified
import ProtocolSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  ProtocolSpec.spec
  PiSpec.spec
