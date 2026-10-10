module Main (main) where

import Petrus.Agenticus.CatalogSpec qualified
import Petrus.Agenticus.EffectSpec qualified
import Petrus.Agenticus.ProgramSpec qualified
import Petrus.Agenticus.RuntimeFoundationSpec qualified
import Petrus.Agenticus.ThreadDifferentialSpec qualified
import Petrus.Agenticus.ThreadSpec qualified
import Petrus.Agenticus.Hands.ConformanceSpec qualified
import Petrus.Agenticus.Hands.DifferentialSpec qualified
import Petrus.Agenticus.HandsSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  Petrus.Agenticus.CatalogSpec.spec
  Petrus.Agenticus.EffectSpec.spec
  Petrus.Agenticus.ThreadSpec.spec
  Petrus.Agenticus.ProgramSpec.spec
  Petrus.Agenticus.RuntimeFoundationSpec.spec
  Petrus.Agenticus.ThreadDifferentialSpec.spec
  Petrus.Agenticus.HandsSpec.spec
  Petrus.Agenticus.Hands.ConformanceSpec.spec
  Petrus.Agenticus.Hands.DifferentialSpec.spec
