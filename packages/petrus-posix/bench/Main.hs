-- | petrus-posix hot paths. Each benchmark has a same-named counterpart in
-- @bench/python_bench.py@ timing the upstream Python code path; run both
-- with @scripts/bench petrus-posix@.
module Main (main) where

import Control.DeepSeq (force)
import Control.Exception (evaluate, finally)
import Data.ByteString qualified as BS
import Petrus.Posix
import System.Directory (createDirectory, createDirectoryLink, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import System.IO.Temp (createTempDirectory)
import Test.Tasty (localOption)
import Test.Tasty.Bench

main :: IO ()
main = do
  dir <- realpath =<< (getTemporaryDirectory >>= \tmp -> createTempDirectory tmp "petrus-posix-bench")
  createDirectory (dir </> "real")
  createDirectory (dir </> "real" </> "a")
  BS.writeFile (dir </> "real" </> "file") "x"
  createDirectoryLink "real" (dir </> "link")
  -- Paths are built once and fully evaluated, as the Python twin binds them
  -- once: a lazily built path could otherwise be rebuilt on every iteration.
  [lockPath, otherLock, symlinked, state] <-
    evaluate . force $
      [dir </> "bench.lock", dir </> "other.lock", dir </> "link" </> "a" </> ".." </> "file", dir </> "state.json"]
  let payload = BS.replicate 1024 120
  held <- openLockFile lockPath
  root <- openDirectoryAt Nothing dir
  flip finally (closeFd held >> closeFd root >> removeDirectoryRecursive dir) $
    -- Wall-clock time for every benchmark, as the Python twins measure it
    -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
    -- time spent waiting on the kernel, servers and child processes.
    defaultMain . map (localOption WallTime) $
      [ bgroup
          "flock"
          [ bench "tryLock-unlock" (whnfIO (tryLock held Exclusive >> unlock held))
          , bench "open-tryLock-close" (whnfIO (openLockFile otherLock >>= \fd -> tryLock fd Exclusive >> closeFd fd))
          ]
      , bgroup
          "path"
          [ bench "resolve-symlinked" (nfIO (pathResolve symlinked))
          , bench "expanduser-resolve" (nfIO (expandAndResolve symlinked))
          ]
      , bgroup
          "at"
          [ bench "stat-nofollow" (whnfIO (statInode <$> statAt (Just root) "link" NoFollowLinks))
          ]
      , bgroup
          "atomic"
          [ bench "write-1KiB-fsync" (whnfIO (atomicWriteFile defaultAtomicWrite state payload))
          ]
      , bgroup
          "resource"
          [ bench "max_rss_mb" (whnfIO maxRssMb)
          ]
      ]
