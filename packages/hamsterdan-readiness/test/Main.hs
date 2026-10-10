module Main (main) where

import FoldCorpusSpec qualified
import LifecycleSpec qualified
import StartupSpec qualified
import CiSpec qualified
import ConversationSpec qualified
import Test.Hspec (hspec)
import TopologySpec qualified

main :: IO ()
main = hspec $ do
  TopologySpec.spec
  StartupSpec.spec
  LifecycleSpec.spec
  FoldCorpusSpec.spec
  CiSpec.spec
  ConversationSpec.spec
