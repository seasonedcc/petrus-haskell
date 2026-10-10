module Main (main) where

import Petrus.Engine.Absurd.InteropSpec qualified as InteropSpec
import Petrus.Engine.AbsurdSpec qualified as AbsurdSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "Petrus.Engine.Absurd" AbsurdSpec.spec
  describe "Absurd Engine interop with the reference" InteropSpec.spec
