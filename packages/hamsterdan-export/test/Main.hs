module Main (main) where

import DifferentialSpec qualified
import ExportSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  ExportSpec.spec
  DifferentialSpec.spec
