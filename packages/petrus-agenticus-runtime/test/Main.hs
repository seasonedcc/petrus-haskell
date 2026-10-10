module Main (main) where

import Petrus.Agenticus.Runtime.AgentNetRunnerSpec qualified
import Petrus.Agenticus.Runtime.PiA2HostSpec qualified
import Petrus.Agenticus.Runtime.PiApplicationSpec qualified
import Petrus.Agenticus.Runtime.PiDifferentialSpec qualified
import Petrus.Agenticus.Runtime.PiModelPhaseSpec qualified
import Petrus.Agenticus.Runtime.PiSpec qualified
import Petrus.Agenticus.Runtime.RunnerDifferentialSpec qualified
import System.Environment (lookupEnv)
import Test.Hspec

main :: IO ()
main =
  -- The Pi A2 host process tests re-execute this binary as their child.
  lookupEnv "PETRUS_PI_A2_HOST_CHILD" >>= \case
    Just mode -> Petrus.Agenticus.Runtime.PiA2HostSpec.child mode
    Nothing -> hspec $ do
      Petrus.Agenticus.Runtime.AgentNetRunnerSpec.spec
      Petrus.Agenticus.Runtime.RunnerDifferentialSpec.spec
      Petrus.Agenticus.Runtime.PiSpec.spec
      Petrus.Agenticus.Runtime.PiDifferentialSpec.spec
      Petrus.Agenticus.Runtime.PiModelPhaseSpec.spec
      Petrus.Agenticus.Runtime.PiApplicationSpec.spec
      Petrus.Agenticus.Runtime.PiA2HostSpec.spec
