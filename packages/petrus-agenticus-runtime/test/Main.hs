module Main (main) where

import Petrus.Agenticus.Runtime.AgentNetRunnerSpec qualified
import Petrus.Agenticus.Runtime.RunnerDifferentialSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  Petrus.Agenticus.Runtime.AgentNetRunnerSpec.spec
  Petrus.Agenticus.Runtime.RunnerDifferentialSpec.spec
