module Main (main) where

import Petrus.Agenticus.AgentNetSpec qualified
import Petrus.Agenticus.BindingSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  Petrus.Agenticus.AgentNetSpec.spec
  Petrus.Agenticus.BindingSpec.spec
