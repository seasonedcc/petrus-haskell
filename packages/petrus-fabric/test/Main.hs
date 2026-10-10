module Main (main) where

import Petrus.Fabric.ConformanceSpec qualified as Conformance
import Petrus.Fabric.DemoSpec qualified as Demo
import Petrus.Fabric.InteropSpec qualified as Interop
import Test.Hspec

main :: IO ()
main = hspec $ do
  Conformance.spec
  Interop.spec
  Demo.spec
