module Main (main) where

import Petrus.Processes.ConformanceSpec qualified as Conformance
import Test.Hspec

main :: IO ()
main = hspec $ do
  Conformance.spec
