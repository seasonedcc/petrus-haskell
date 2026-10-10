-- | petrus-agenticus benchmarks. Each @Bench.*@ module is the twin of a
-- @bench/python_*.py@ script that times the reference on the same workload;
-- see @bench/RESULTS.md@.
module Main (main) where

import Bench.AgentNet qualified
import Test.Tasty.Bench

main :: IO ()
main = do
  Bench.AgentNet.checkWorkload
  defaultMain [Bench.AgentNet.benchmarks]
