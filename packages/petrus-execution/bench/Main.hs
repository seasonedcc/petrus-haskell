-- | Haskell side of the petrus-execution benchmarks; mirrors
-- @bench/python_bench.py@ workload for workload (see @bench/RESULTS.md@).
--
-- > petrus-execution-bench WORKDIR [FAKE_GONDOLIN_SDK]
--
-- Set @PETRUS_BENCH_ONLY=<workload>@ to run a single archive workload.
-- Prints one JSON object per line: @{"name", "median_ms", "min_ms", "runs"}@.
module Main (main) where

import Control.Exception (evaluate, finally)
import Control.Monad (forM, forM_, replicateM, void)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import GHC.Clock (getMonotonicTime)
import Petrus.Json (Json (..), canonicalText)
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (archiveDigest, extractWorkspaceArchive, validateWorkspaceArchive, workspaceArchive)
import Petrus.Motus.Execution.Internal.Process (runCaptured, spawnSpec)
import Petrus.Motus.Execution.Providers.Gondolin
import System.Directory (createDirectory, makeAbsolute, removeDirectoryRecursive)
import System.Environment (getArgs, lookupEnv)
import System.FilePath ((</>))
import System.IO (BufferMode (..), hSetBuffering, stdout)
import System.IO.Temp (createTempDirectory)

workloads :: [(String, Int)]
workloads = [("many-small", 7), ("medium", 7), ("one-large", 7)]

handshakes, executions, spawns :: Int
handshakes = 1000
executions = 50
spawns = 100

-- | @subprocess.run(("/usr/bin/true",), capture_output=True, timeout=5)@:
-- the path every Docker CLI call takes.
processBenchmarks :: IO ()
processBenchmarks = do
  let run = runCaptured (spawnSpec ["/usr/bin/true"]) 5
  void run
  samples <- replicateM spawns (timed run)
  report "process/run-captured" samples spawns

timed :: IO a -> IO Double
timed action = do
  started <- getMonotonicTime
  void action
  subtract started <$> getMonotonicTime

median :: [Double] -> Double
median samples =
  let sorted = sort samples
      n = length sorted
   in if even n
        then (sorted !! (n `div` 2 - 1) + sorted !! (n `div` 2)) / 2
        else sorted !! (n `div` 2)

report :: Text -> [Double] -> Int -> IO ()
report name samples runs =
  TIO.putStrLn . either (error . show) id . canonicalText $
    Object
      [ ("name", String name)
      , ("median_ms", Float (median samples * 1000))
      , ("min_ms", Float (minimum samples * 1000))
      , ("runs", Int (fromIntegral runs))
      ]

archiveBenchmarks :: FilePath -> IO ()
archiveBenchmarks workdir = do
  only <- lookupEnv "PETRUS_BENCH_ONLY"
  forM_ [w | w@(name, _) <- workloads, maybe True (== name) only] $ \(name, runs) -> do
    let source = workdir </> name
        label phase = T.pack ("archive/" <> name <> "/" <> phase)
    bytes <- workspaceArchive source
    pack <- replicateM runs (timed (workspaceArchive source >>= evaluate . archiveDigest))
    report (label "pack+sha256") pack runs
    validate <- replicateM runs (timed (validateWorkspaceArchive True [] bytes))
    report (label "validate") validate runs
    extract <- forM [1 .. runs] $ \index -> do
      let target = workdir </> ("extract-hs-" <> name <> "-" <> show index)
      elapsed <- timed (extractWorkspaceArchive bytes target)
      removeDirectoryRecursive target
      pure elapsed
    report (label "extract") extract runs

sidecarBenchmarks :: Text -> IO ()
sidecarBenchmarks sdk = do
  root <- createTempDirectory "/tmp" "petrus-gb-"
  ( do
      env <- newGondolinEnvironment (root </> "g") (gondolinConfig sdk)
      let provider = gondolinProvider env
          spec = either (error . show) id (mkEnvironmentSpec (Just "fake-image") [])
      lease <- provision env "bench" spec
      ( do
          Just record <- readRegistry (operationDirectory env "bench")
          let handshake = sidecarRequest env record [("action", String "handshake")] 2
          replicateM 20 handshake >>= void . evaluate
          samples <- replicateM handshakes (timed handshake)
          report "sidecar/handshake-round-trip" samples handshakes
          createDirectory (root </> "workspace")
          archive <- workspaceArchive (root </> "workspace")
          attachment <- providerAttach provider lease archive "digest"
          let command = either (error . show) id (mkCommand (commandSpec ["/bin/sh", "-c", "true"]))
          void (providerExecute provider attachment command)
          executeSamples <- replicateM executions (timed (providerExecute provider attachment command))
          report "sidecar/execute-round-trip" executeSamples executions
        )
        `finally` providerDestroy provider lease
    )
    `finally` removeDirectoryRecursive root

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case args of
    [workdir] -> archiveBenchmarks workdir >> processBenchmarks
    [workdir, sdk] -> do
      archiveBenchmarks workdir
      processBenchmarks
      makeAbsolute sdk >>= sidecarBenchmarks . T.pack
    _ -> error "usage: petrus-execution-bench WORKDIR [FAKE_GONDOLIN_SDK]"
