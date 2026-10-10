module Main (main) where

import Petrus.Fabric.ConformanceSpec qualified as Conformance
import Petrus.Fabric.DemoSpec qualified as Demo
import Petrus.Fabric.InteropSpec qualified as Interop
import Petrus.Fabric.ReferenceSpec qualified as Reference
import Petrus.Fabric.TypedSpec qualified as Typed
import Test.Hspec

main :: IO ()
main = hspec $ do
  Conformance.spec
  Interop.spec
  Demo.spec
  Typed.spec
  Reference.spec
