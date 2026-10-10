module Main (main) where

import Petrus.Agenticus.AgentNetSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  Petrus.Agenticus.AgentNetSpec.spec
