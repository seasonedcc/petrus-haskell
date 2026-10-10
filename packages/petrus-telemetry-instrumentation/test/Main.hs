-- | The telemetry instrumentation evidence. The level and the default sink
-- are process-global and every example observes them through 'capture', so
-- the whole suite runs sequentially.
module Main (main) where

import Petrus.Telemetry.DifferentialSpec qualified as Differential
import Petrus.Telemetry.InstrumentationSpec qualified as Instrumentation
import Test.Hspec

main :: IO ()
main = hspec . sequential $ do
  describe "test_telemetry_instrumentation.py" Instrumentation.spec
  describe "differential/telemetry_scenarios.py" Differential.spec
