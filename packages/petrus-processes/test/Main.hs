module Main (main) where

import Petrus.Processes.ConformanceSpec qualified as Conformance
import Petrus.Processes.DemoSpec qualified as Demo
import Petrus.Processes.InteropSpec qualified as Interop
import Petrus.Processes.TypedSpec qualified as Typed
import Test.Hspec

main :: IO ()
main = hspec $ do
  Conformance.spec
  Interop.spec
  Demo.spec
  Typed.spec
