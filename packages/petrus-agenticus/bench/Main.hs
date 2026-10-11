-- | petrus-agenticus benchmarks. Each @Bench.*@ module is the twin of a
-- @bench/python_*.py@ script that times the reference on the same workload;
-- see @bench/RESULTS.md@.
module Main (main) where

import Bench.AgentNet qualified
import Bench.Retention qualified
import Test.Tasty (localOption)
import Test.Tasty.Bench

main :: IO ()
main = do
  Bench.AgentNet.checkWorkload
  Bench.Retention.withLedger $ \ledger ->
    -- Wall-clock time for every benchmark, as the Python twins measure it
    -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
    -- time spent waiting on the kernel, servers and child processes.
    defaultMain (map (localOption WallTime) [Bench.AgentNet.benchmarks, Bench.Retention.benchmarks ledger])
