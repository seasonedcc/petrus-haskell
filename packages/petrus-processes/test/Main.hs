module Main (main) where

import Petrus.Processes.ConformanceSpec qualified as Conformance
import Petrus.Processes.InteropSpec qualified as Interop
import Test.Hspec

main :: IO ()
main = hspec $ do
  Conformance.spec
  Interop.spec
