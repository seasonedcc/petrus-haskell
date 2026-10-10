module Main (main) where

import Test.Hspec (hspec)
import TopologySpec qualified

main :: IO ()
main = hspec $ do
  TopologySpec.spec
