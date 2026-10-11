module Main (main) where

import Petrus.Engine.BoundarySpec qualified as Boundary
import Petrus.Engine.CoordinatorSpec qualified as Coordinator
import Petrus.Engine.DeliveryPhasesASpec qualified as DeliveryPhasesA
import Petrus.Engine.DeliveryPhasesBSpec qualified as DeliveryPhasesB
import Petrus.Engine.DeliveryPhasesCSpec qualified as DeliveryPhasesC
import Petrus.Engine.EngineSpec qualified as Engine
import Petrus.Engine.ExecutionSpec qualified as Execution
import Petrus.Engine.InteropSpec qualified as Interop
import Petrus.Engine.LocalDispatchSpec qualified as LocalDispatch
import Petrus.Engine.SpecObligationsSpec qualified as SpecObligations
import Petrus.Engine.WorkerTopologySpec qualified as WorkerTopology
import Petrus.Motus.Worker.Cli (noPlugins, workerMain)
import System.Environment (lookupEnv)
import Test.Hspec

-- | The suite, or (re-executed with the Worker topology's mode variable
-- set) the Worker process entry point over its registries.
main :: IO ()
main =
  lookupEnv WorkerTopology.workerModeVariable >>= \case
    Just _ -> workerMain "python -m petrus.motus.worker" WorkerTopology.topologyRegistries noPlugins
    Nothing -> suite

suite :: IO ()
suite = hspec $ do
  describe "test_engine.py" Engine.spec
  describe "test_coordinator.py" Coordinator.spec
  describe "test_execution.py" $ do
    Execution.spec
    DeliveryPhasesA.spec
    DeliveryPhasesB.spec
    DeliveryPhasesC.spec
  describe "test_local_dispatch.py (Engine)" LocalDispatch.spec
  Interop.spec
  WorkerTopology.spec
  Boundary.spec
  SpecObligations.spec
