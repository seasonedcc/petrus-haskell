module Main (main) where

import FoldCorpusSpec qualified
import LifecycleSpec qualified
import StartupSpec qualified
import CiSpec qualified
import ConversationSpec qualified
import DashboardSpec qualified
import EscalationSpec qualified
import MutationSpec qualified
import RemindersSpec qualified
import ReviewSpec qualified
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
  DashboardSpec.spec
  EscalationSpec.spec
  MutationSpec.spec
  RemindersSpec.spec
  ReviewSpec.spec
