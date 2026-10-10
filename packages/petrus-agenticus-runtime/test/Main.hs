module Main (main) where

import Petrus.Agenticus.Runtime.AgentNetRunnerSpec qualified
import Test.Hspec

main :: IO ()
main = hspec Petrus.Agenticus.Runtime.AgentNetRunnerSpec.spec
