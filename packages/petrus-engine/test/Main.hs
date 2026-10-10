module Main (main) where

import Petrus.Engine.CoordinatorSpec qualified as Coordinator
import Petrus.Engine.DeliveryPhasesASpec qualified as DeliveryPhasesA
import Petrus.Engine.DeliveryPhasesBSpec qualified as DeliveryPhasesB
import Petrus.Engine.DeliveryPhasesCSpec qualified as DeliveryPhasesC
import Petrus.Engine.EngineSpec qualified as Engine
import Petrus.Engine.ExecutionSpec qualified as Execution
import Petrus.Engine.InteropSpec qualified as Interop
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "test_engine.py" Engine.spec
  describe "test_coordinator.py" Coordinator.spec
  describe "test_execution.py" $ do
    Execution.spec
    DeliveryPhasesA.spec
    DeliveryPhasesB.spec
    DeliveryPhasesC.spec
  Interop.spec
