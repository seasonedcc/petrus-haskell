module Main (main) where

import Petrus.Engine.ExecutionSpec qualified as Area
import Test.Hspec

main :: IO ()
main = hspec Area.spec
