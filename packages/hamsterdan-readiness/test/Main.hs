module Main (main) where

import FoldCorpusSpec qualified
import StartupSpec qualified
import Test.Hspec (hspec)
import TopologySpec qualified

main :: IO ()
main = hspec $ do
  TopologySpec.spec
  StartupSpec.spec
  FoldCorpusSpec.spec
