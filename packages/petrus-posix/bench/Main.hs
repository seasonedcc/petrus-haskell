-- | petrus-posix hot paths. Each benchmark has a same-named counterpart in
-- @bench/python_bench.py@ timing the upstream Python code path; run both
-- with @scripts/bench petrus-posix@.
module Main (main) where

import Control.Exception (finally)
import Data.ByteString qualified as BS
import Petrus.Posix
import System.Directory (createDirectory, createDirectoryLink, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import System.IO.Temp (createTempDirectory)
import Test.Tasty.Bench

main :: IO ()
main = do
  dir <- realpath =<< (getTemporaryDirectory >>= \tmp -> createTempDirectory tmp "petrus-posix-bench")
  createDirectory (dir </> "real")
  createDirectory (dir </> "real" </> "a")
  BS.writeFile (dir </> "real" </> "file") "x"
  createDirectoryLink "real" (dir </> "link")
  let lockPath = dir </> "bench.lock"
      symlinked = dir </> "link" </> "a" </> ".." </> "file"
      payload = BS.replicate 1024 120
  held <- openLockFile lockPath
  root <- openDirectoryAt Nothing dir
  flip finally (closeFd held >> closeFd root >> removeDirectoryRecursive dir) $
    defaultMain
      [ bgroup
          "flock"
          [ bench "tryLock-unlock" (whnfIO (tryLock held Exclusive >> unlock held))
          , bench "open-tryLock-close" (whnfIO (openLockFile (dir </> "other.lock") >>= \fd -> tryLock fd Exclusive >> closeFd fd))
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
          [ bench "write-1KiB-fsync" (whnfIO (atomicWriteFile defaultAtomicWrite (dir </> "state.json") payload))
          ]
      , bgroup
          "resource"
          [ bench "max_rss_mb" (whnfIO maxRssMb)
          ]
      ]
