-- | Agenticus core benchmarks.  Each @Bench.*@ module is the twin of a
-- @bench/python_*.py@ script timing the reference on the same workload; see
-- @bench/RESULTS.md@.
--
-- @custody [FULL|OFF] [N ...]@ runs the stateful custody driver
-- ("Bench.Custody") instead of the tasty-bench suite.
module Main (main) where

import Bench.Catalog qualified
import Bench.Effect qualified
import Bench.Thread qualified
import Bench.Hands qualified
import Bench.Custody qualified
import System.Environment (getArgs)
import Test.Tasty.Bench

main :: IO ()
main =
  getArgs >>= \case
    "custody" : arguments -> Bench.Custody.run arguments
    _ ->
      defaultMain
        [ Bench.Catalog.benchmarks
        , Bench.Effect.benchmarks
        , Bench.Thread.benchmarks
        , Bench.Hands.benchmarks
        ]
