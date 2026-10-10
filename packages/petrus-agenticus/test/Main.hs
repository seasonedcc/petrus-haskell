module Main (main) where

import Petrus.Agenticus.AgentNetSpec qualified
import Petrus.Agenticus.BindingSpec qualified
import Petrus.Agenticus.BoundariesSpec qualified
import Petrus.Agenticus.PyTextSpec qualified
import Petrus.Agenticus.WorkspaceSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  Petrus.Agenticus.AgentNetSpec.spec
  Petrus.Agenticus.BindingSpec.spec
  Petrus.Agenticus.BoundariesSpec.spec
  Petrus.Agenticus.PyTextSpec.spec
  Petrus.Agenticus.WorkspaceSpec.spec
