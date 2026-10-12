-- | A benchmark row timed with the Python twins' own protocol, for rows where
-- tasty-bench's does not compare like with like.
--
-- tasty-bench doubles a row's iteration count until the estimate's relative
-- deviation is under the target, and reports a mean. Two kinds of row then
-- measure something other than their twin:
--
-- * a stateful row, whose cost grows with the calls before it (a table that
--   fills, a ledger that grows): tasty-bench runs as many calls as the noise
--   demands, so the two sides time different states;
-- * an fsync-bound row: the file system has slow periods, a tasty-bench run
--   lasts as long as the noise demands and reports a mean, so one slow
--   period moves it, while the twin's median of batches does not.
--
-- 'twin' times such a row the way @scripts/bench_timing.py@'s
-- @report(name, fn, number=N)@ (or a twin's own @timed(name, fn, repeats)@,
-- with @N = 1@) does: one warm-up call, then a fixed number of batches of
-- exactly @N@ calls, reporting the median batch's time per call. Both sides
-- make the same calls, so they reach the same state, and take the same
-- statistic. The readable figure is followed by a line
-- @twin NAME NANOSECONDS@, which @scripts/bench-compare@ reads (tasty-bench's
-- CSV leaves such rows out).
module Petrus.TestSupport.BenchTwin
  ( twin
  , twinBatches
  ) where

import Control.Monad (replicateM, replicateM_, void)
import Data.List (sort)
import GHC.Clock (getMonotonicTime)
import System.Environment (lookupEnv)
import Test.Tasty (TestTree)
import Test.Tasty.Providers (IsTest (..), singleTest, testPassed)
import Text.Printf (printf)
import Text.Read (readMaybe)

data TwinRow = TwinRow String (Maybe Int) Int (IO ())

instance IsTest TwinRow where
  testOptions = pure []
  run _ (TwinRow name fixedBatches perBatch operation) _ = do
    batches <- maybe twinBatches pure fixedBatches
    operation
    let batch = do
          start <- getMonotonicTime
          replicateM_ perBatch operation
          end <- getMonotonicTime
          pure ((end - start) / fromIntegral perBatch)
    samples <- sort <$> replicateM batches batch
    let middle = batches `div` 2
        median
          | even batches = (samples !! (middle - 1) + samples !! middle) / 2
          | otherwise = samples !! middle
    pure
      ( testPassed
          ( printf
              "%s per call (median of %d batches of %d, after 1 warm-up; batches %s to %s)\ntwin %s %.1f"
              (seconds median)
              batches
              perBatch
              (seconds (samples !! 0))
              (seconds (samples !! (batches - 1)))
              name
              (median * 1e9)
          )
      )

-- | @scripts/bench_timing.py@'s batch count: @PETRUS_BENCH_BATCHES@, or 10.
twinBatches :: IO Int
twinBatches = maybe 10 (max 1) . (>>= readMaybe) <$> lookupEnv "PETRUS_BENCH_BATCHES"

seconds :: Double -> String
seconds s
  | s >= 1e-3 = printf "%.3f ms" (s * 1e3)
  | s >= 1e-6 = printf "%.3f µs" (s * 1e6)
  | otherwise = printf "%.1f ns" (s * 1e9)

-- | @twin name batches perBatch action@: a row named @name@ in the tree, its
-- @twin@ line named @name@ too (spell it as the twin does, groups and all:
-- @tx.immediate-insert-commit@). @batches@ 'Nothing' takes
-- @bench_timing.py@'s count ('twinBatches'); a twin with its own fixed count
-- (@timed(name, fn, 5)@) passes it.
twin :: String -> Maybe Int -> Int -> IO a -> TestTree
twin name batches perBatch action = singleTest (lastComponent name) (TwinRow name batches perBatch (void action))
  where
    lastComponent = reverse . takeWhile (/= '.') . reverse
