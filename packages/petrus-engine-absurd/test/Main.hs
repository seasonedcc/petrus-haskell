module Main (main) where

import Petrus.Engine.Absurd.InteropSpec qualified as InteropSpec
import Petrus.Engine.Absurd.Support (topologyRegistries, workerModeVariable)
import Petrus.Engine.Absurd.WorkerTopologySpec qualified as WorkerTopologySpec
import Petrus.Engine.AbsurdSpec qualified as AbsurdSpec
import Petrus.Motus.Worker.Absurd (absurdPlugins)
import Petrus.Motus.Worker.Cli (workerMain)
import System.Environment (lookupEnv)
import Test.Hspec

-- | The test suite, or (with 'workerModeVariable' set) this port's Worker
-- process entry point over the topology registry and the Absurd provider.
main :: IO ()
main =
  lookupEnv workerModeVariable >>= \case
    Just _ -> workerMain "python -m petrus.motus.worker" topologyRegistries absurdPlugins
    Nothing -> hspec $ do
      describe "Petrus.Engine.Absurd" AbsurdSpec.spec
      describe "test_worker_topology.py: the Worker side over Absurd" WorkerTopologySpec.spec
      describe "Absurd Engine interop with the reference" InteropSpec.spec
