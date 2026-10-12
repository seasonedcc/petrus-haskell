-- | The telemetry instrumentation evidence. The level and the default sink
-- are process-global and every example observes them through 'capture', so
-- the whole suite runs sequentially.
module Main (main) where

import Petrus.Telemetry.DifferentialSpec qualified as Differential
import Petrus.Telemetry.InstrumentationSpec qualified as Instrumentation
import Petrus.Telemetry.InvalidLevelSpec qualified as InvalidLevel
import System.Environment (lookupEnv)
import Test.Hspec

-- | With 'InvalidLevel.probeVariable' set, the executable is the child the
-- invalid-level examples observe instead.
main :: IO ()
main =
  lookupEnv InvalidLevel.probeVariable >>= \case
    Just dir -> InvalidLevel.probe dir
    Nothing -> hspec . sequential $ do
      describe "test_telemetry_instrumentation.py" Instrumentation.spec
      describe "differential/telemetry_scenarios.py" Differential.spec
      describe "petrus/telemetry.py import-time level validation" InvalidLevel.spec
