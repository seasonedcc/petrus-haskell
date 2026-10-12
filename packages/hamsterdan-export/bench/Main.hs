-- | Wall-clock benchmark of the exporter against the reference.
--
-- Three state directories:
--
-- * __fixture__: the upstream test suite's default state directory
--   (@test/Fixtures.hs@, a port of @test_export.py@'s @state_dir@).
-- * __host-driven__: a state directory the reference host wrote
--   (@hamsterdan-host@'s @differential/state_reference.py drive@ over
--   @differential/host_steps.json@), about 600 History records.
-- * __large__: the fixture plus 2000 agent review operations (request and
--   completion each, half with stored bodies) and 400 board publications,
--   about 4800 History records.
--
-- Two shapes per state directory, both timed by wall clock (monotonic):
--
-- * __CLI__: @python -I -B -m hamsterdan.host.export@ against the
--   @hamsterdan-export@ binary, each a fresh process with the same
--   arguments, interleaved run by run (the order flips every run).
--   Interpreter and runtime start-up are included: that is what an operator
--   pays.
-- * __in process__: @hamsterdan.host.export.main@ called repeatedly inside
--   one long-lived interpreter (@bench/bench.py@) against 'runExport'
--   called repeatedly inside this process, interleaved run by run the same
--   way. Start-up excluded; the interpreter is warm after its first run.
--
-- Each cell is the median of the runs (default 21; @--runs N@), with the
-- minimum alongside. Output directories are removed between runs, outside
-- the timed region.
module Main (main) where

import Control.Monad (forM, forM_, replicateM, when)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Fixtures
import GHC.Clock (getMonotonicTime)
import Hamsterdan.Export (ExportEnvironment (..), agentOperationId, runExport)
import Petrus.Json (Json (..))
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory (findExecutable, removePathForcibly, renameFile)
import System.Environment (getArgs, lookupEnv)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), IOMode (WriteMode), hClose, hGetLine, hPutStrLn, hSetBuffering, withFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process.Typed
import Text.Printf (printf)

data Subject = Subject
  { label :: String
  , state :: FilePath
  , repositoryName :: Text
  }

main :: IO ()
main = do
  args <- getArgs
  case args of
    -- Only build the large state directory under DIR, for profiling.
    ["--write-large", dir] -> stateDir dir largeChanges >>= putStrLn
    -- Only export STATE N times in this process, for profiling.
    ["--repeat", state, repositoryName, n] ->
      withSystemTempDirectory "hamsterdan-export-repeat" $ \tmp ->
        () <$ inProcess tmp (read n) (Subject "repeat" state (T.pack repositoryName))
    ["--runs", n] -> compareAll (read n)
    _ -> compareAll 21

compareAll :: Int -> IO ()
compareAll runs = do
  repo <- repoRoot
  python <- upstreamPythonExecutable "hamsterdan"
  binary <- exportBinary
  withSystemTempDirectory "hamsterdan-export-bench" $ \tmp -> do
    fixture <- stateDir (tmp </> "fixture") defaults
    driven <- drivenState repo python (tmp </> "driven")
    large <- stateDir (tmp </> "large") largeChanges
    let subjects =
          [ Subject "fixture" fixture repository
          , Subject "host-driven" driven "owner/one"
          , Subject "large" large repository
          ]
    putStrLn "| State directory | Shape | Haskell median (min) | Python median (min) | Python / Haskell | Haskell ahead |"
    putStrLn "| --- | --- | ---: | ---: | ---: | ---: |"
    forM_ subjects $ \subject -> do
      (hsCli, pyCli) <- cli tmp python binary runs subject
      row subject.label "CLI (fresh process)" hsCli pyCli
      (hsIn, pyIn) <- bothInProcess repo python tmp runs subject
      row subject.label "in process" hsIn pyIn

row :: String -> String -> [Double] -> [Double] -> IO ()
row subject shape hs py =
  printf
    "| %s | %s | %s (%s) | %s (%s) | %.2f× | %d of %d |\n"
    subject
    shape
    (duration (median hs))
    (duration (minimum hs))
    (duration (median py))
    (duration (minimum py))
    (median py / median hs)
    -- the runs are paired (interleaved run by run): Haskell's wins
    (length (filter id (zipWith (<) hs py)))
    (length hs)

median :: [Double] -> Double
median xs = let sorted = sort xs in sorted !! (length sorted `div` 2)

duration :: Double -> String
duration seconds
  | seconds >= 1 = printf "%.2f s" seconds
  | otherwise = printf "%.1f ms" (seconds * 1000)

argvFor :: Subject -> FilePath -> [String]
argvFor subject out =
  ["--state-dir", subject.state, "--out", out, "--repository", T.unpack subject.repositoryName, "--pull-request", "7"]

-- | Both CLIs, interleaved run by run.
cli :: FilePath -> FilePath -> FilePath -> Int -> Subject -> IO ([Double], [Double])
cli tmp python binary runs subject = do
  pairs <- forM [1 .. runs] $ \index -> do
    let hsRun = timed (proc binary (argvFor subject (tmp </> "out-hs") ++ ["+RTS", "-M2G", "-RTS"])) (tmp </> "out-hs")
        pyRun = timed (proc python (["-I", "-B", "-m", "hamsterdan.host.export"] ++ argvFor subject (tmp </> "out-py"))) (tmp </> "out-py")
    if even index
      then (,) <$> hsRun <*> pyRun
      else do
        py <- pyRun
        hs <- hsRun
        pure (hs, py)
  pure (unzip pairs)
  where
    timed config out = do
      start <- getMonotonicTime
      (status, _, err) <- readProcess config
      end <- getMonotonicTime
      when (status /= ExitSuccess) $ fail ("export failed: " <> show err)
      removePathForcibly out
      pure (end - start)

inProcess :: FilePath -> Int -> Subject -> IO [Double]
inProcess tmp runs subject = replicateM runs (haskellRun tmp subject)

-- | One 'runExport' over the subject, timed; its output removed after.
haskellRun :: FilePath -> Subject -> IO Double
haskellRun tmp subject =
  withFile "/dev/null" WriteMode $ \sink -> do
    let env = ExportEnvironment {environment = Map.empty, output = sink, errors = sink}
        out = tmp </> "out-in-hs"
    start <- getMonotonicTime
    status <- runExport env (map T.pack (argvFor subject out))
    end <- getMonotonicTime
    when (status /= ExitSuccess) $ fail "export failed"
    removePathForcibly out
    pure (end - start)

-- | Both sides in process, interleaved run by run (the order flips every
-- run): this process's 'runExport' and one long-lived interpreter running
-- @bench/bench.py@, which times one @main@ per line it reads.
bothInProcess :: FilePath -> FilePath -> FilePath -> Int -> Subject -> IO ([Double], [Double])
bothInProcess repo python tmp runs subject = do
  let script = repo </> "packages" </> "hamsterdan-export" </> "bench" </> "bench.py"
      config =
        setStdin createPipe . setStdout createPipe $
          proc python ["-I", "-B", script, subject.state, tmp </> "out-in-py", T.unpack subject.repositoryName, "7"]
  withProcessWait_ config $ \server -> do
    let toServer = getStdin server
        fromServer = getStdout server
    hSetBuffering toServer LineBuffering
    ready <- hGetLine fromServer
    when (ready /= "ready") $ fail ("bench.py: " <> ready)
    let pyRun = do
          hPutStrLn toServer "run"
          read <$> hGetLine fromServer
        hsRun = haskellRun tmp subject
    pairs <- forM [1 .. runs] $ \index ->
      if even index
        then (,) <$> hsRun <*> pyRun
        else do
          py <- pyRun
          hs <- hsRun
          pure (hs, py)
    hClose toServer
    pure (unzip pairs)

drivenState :: FilePath -> FilePath -> FilePath -> IO FilePath
drivenState repo python root = do
  steps <- BS.readFile (repo </> "packages" </> "hamsterdan-export" </> "differential" </> "host_steps.json")
  let script = repo </> "packages" </> "hamsterdan-host" </> "differential" </> "state_reference.py"
      state = root </> "state"
  _ <- readProcessStdout_ (setStdin (byteStringInput (BL.fromStrict steps)) (proc python ["-I", "-B", script, "drive", state]))
  renameFile (state </> "test-agent-routes.sqlite3") (state </> "agent-routes.sqlite3")
  pure state

largeChanges :: Changes
largeChanges =
  defaults
    { history = Just (history ++ concatMap review [1 .. operations] ++ map board [1 .. 400])
    , bodies = defaults.bodies ++ [agentOperationId (operation i) 1 | i <- [1 .. operations], even i]
    , routes = defaults.routes ++ map operation [1 .. operations]
    }
  where
    operations = 2000 :: Integer
    operation i = "review:" <> instanceName <> ":r" <> T.pack (show i) <> ":i1"
    review i =
      [ record
          "ActivityRequested"
          [ ("transition", String "review.agent")
          , ("activity", String "review_agent")
          , ("occurrence", Int (100 + i))
          , ("instant", Int (100 + 2 * i))
          , ("scope", String "/review")
          , ("correlation", String (operation i))
          , ("idempotency", String (operation i))
          , ("policy", Object [("attempts", Int 1)])
          , ("input", Object [("work", Object [("operation", String (operation i)), ("head", String "h1"), ("attempt", Int 1)])])
          ]
      , record
          "ActivityCompleted"
          [ ("transition", String "review.agent")
          , ("occurrence", Int (100 + i))
          , ("instant", Int (101 + 2 * i))
          , ("result", Object [("$variant", String "AgentReview"), ("head", String "h1")])
          ]
      ]
    board i =
      record
        "ActivityCompleted"
        [ ("transition", String "dash.publish")
        , ("occurrence", Int (5000 + i))
        , ("instant", Int (9000 + i))
        , ( "result"
          , Object
              [ ("$variant", String (if even i then "DashLanded" else "DashDeferred"))
              , ("entries", Array (map String (take (fromInteger (1 + i `mod` 3)) boardEntries)))
              , ("digest", String ("b" <> T.pack (show i)))
              ]
          )
        ]

exportBinary :: IO FilePath
exportBinary =
  lookupEnv "HAMSTERDAN_EXPORT" >>= \case
    Just path -> pure path
    Nothing -> findExecutable "hamsterdan-export" >>= maybe (fail "hamsterdan-export is not on PATH") pure
