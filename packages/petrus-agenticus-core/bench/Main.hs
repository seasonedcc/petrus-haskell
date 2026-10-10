-- | Agenticus core benchmarks.  Each @Bench.*@ module is the twin of a
-- @bench/python_*.py@ script timing the reference on the same workload; see
-- @bench/RESULTS.md@.
module Main (main) where

import Bench.Catalog qualified
import Bench.Effect qualified
import Test.Tasty.Bench

main :: IO ()
main =
  defaultMain
    [ Bench.Catalog.benchmarks
    , Bench.Effect.benchmarks
    ]
