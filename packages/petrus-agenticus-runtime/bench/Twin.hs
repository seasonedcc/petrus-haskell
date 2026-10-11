-- | The Python twins' own timing protocol, for rows where tasty-bench's
-- doubling does not compare like with like.
--
-- @timed(label, operation, batches=7, per_batch=N)@ in the twins: one
-- warm-up call, then 7 batches of @N@ calls, reporting the median batch's
-- mean time per call. Two kinds of row use it:
--
-- * a workload whose cost grows with the calls before it (the scripted A2
--   turn), where tasty-bench's doubling measures a much fuller state than
--   the twin does;
-- * an fsync-bound workload (the Pi ledger cycle), where the machine's file
--   system has slow periods. A tasty-bench run lasts 4–60 s and reports a
--   mean, so one slow period moves it; the twin's 1.4 s and median do not.
--   Timing both sides alike makes the rounds comparable.
--
-- The result line reads @twin NAME NANOSECONDS@ after the readable figure,
-- for scripts that tabulate interleaved rounds.
module Twin (twin) where

import Data.List (sort)
import GHC.Clock (getMonotonicTime)
import Test.Tasty.Bench (Benchmark)
import Test.Tasty.Providers (IsTest (..), singleTest, testPassed)
import Text.Printf (printf)

data TwinProtocol = TwinProtocol String Int (IO ())

instance IsTest TwinProtocol where
  testOptions = pure []
  run _ (TwinProtocol name perBatch operation) _ = do
    operation
    let batch = do
          start <- getMonotonicTime
          mapM_ (const operation) [1 .. perBatch]
          end <- getMonotonicTime
          pure ((end - start) / fromIntegral perBatch)
    samples <- sort <$> mapM (const batch) [1 .. 7 :: Int]
    let at i = samples !! i
    pure
      ( testPassed
          ( printf
              "%s per call (median of 7 batches of %d, after 1 warm-up; batches %s to %s)\ntwin %s %.1f"
              (seconds (at 3))
              perBatch
              (seconds (at 0))
              (seconds (at 6))
              name
              (at 3 * 1e9)
          )
      )

seconds :: Double -> String
seconds s
  | s >= 1e-3 = printf "%.3f ms" (s * 1e3)
  | s >= 1e-6 = printf "%.3f µs" (s * 1e6)
  | otherwise = printf "%.1f ns" (s * 1e9)

-- | A row timed with the twins' protocol: @per_batch@ calls a batch.
twin :: String -> Int -> IO () -> Benchmark
twin name perBatch operation = singleTest name (TwinProtocol name perBatch operation)
