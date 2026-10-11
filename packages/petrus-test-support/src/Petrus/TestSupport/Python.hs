-- | Running Python reference snippets for differential tests.
--
-- The Python side is always the pinned upstream: its own virtual environment
-- (@upstream/petrus/.venv@, provisioned by @scripts/upstream-python@ on first
-- use, which pins the Python version and runs
-- @uv sync --frozen --extra postgres@ when the environment is missing or
-- stale), with the pinned @petrus@ package and @psycopg@ importable. Snippets run with @python -I -c@ from @upstream/petrus@, so the
-- interpreter ignores user site-packages and @PYTHON*@ variables, and relative
-- fixture paths resolve as they do in the upstream test suite.
--
-- Two shapes are offered: one-shot snippets ('python', 'pythonJson',
-- 'runPython') and interactive helpers ('withPython') that speak a line
-- protocol over stdin and stdout, for example a process that takes a lock,
-- prints @locked@, and holds it until told to release.
module Petrus.TestSupport.Python
  ( -- * The interpreter
    pythonExecutable
  , upstreamPythonExecutable
  , PythonFailure (..)

    -- * One-shot snippets
  , PythonResult (..)
  , runPython
  , python
  , pythonJson

    -- * Interactive helpers
  , PythonProcess
  , withPython
  , sendLine
  , readLine
  , expectLine
  , closeInput
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (Exception, finally, throwIO)
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json, parseJson, pythonLoads)
import Petrus.TestSupport.Repo (repoRoot, upstreamPetrus)
import System.FilePath ((</>))
import System.IO (Handle, hClose, hFlush, hSetBuffering, BufferMode (..))
import System.IO.Unsafe (unsafePerformIO)
import System.Process qualified as Process
import System.Process.Typed
import System.Timeout (timeout)

-- | A Python snippet failed, or the reference environment is unavailable.
data PythonFailure = PythonFailure
  { failureContext :: String
  , failureStdout :: ByteString
  , failureStderr :: ByteString
  }

instance Show PythonFailure where
  show failure =
    failureContext failure
      ++ "\n--- stdout ---\n"
      ++ BC.unpack (failureStdout failure)
      ++ "\n--- stderr ---\n"
      ++ BC.unpack (failureStderr failure)

instance Exception PythonFailure

-- The interpreter paths, resolved once per process and upstream project.
interpreters :: MVar [(String, FilePath)]
interpreters = unsafePerformIO (newMVar [])
{-# NOINLINE interpreters #-}

-- | The @upstream/petrus@ virtual environment's interpreter, provisioned by
-- @scripts/upstream-python@ (the single place that pins the reference's
-- Python version) the first time a process asks for it. Fails loudly, never
-- skips, when the environment cannot be provisioned.
pythonExecutable :: IO FilePath
pythonExecutable = upstreamPythonExecutable "petrus"

-- | The interpreter of another pinned upstream project's environment
-- (@"petrus"@, @"petrus-engine"@ or @"hamsterdan"@), provisioned the same way as
-- 'pythonExecutable'.
upstreamPythonExecutable :: String -> IO FilePath
upstreamPythonExecutable project = modifyMVar interpreters $ \known ->
  case lookup project known of
    Just path -> pure (known, path)
    Nothing -> do
      root <- repoRoot
      let script = root </> "scripts" </> "upstream-python"
      (code, out, err) <- readProcess (setStdin nullStream (proc script [project]))
      let path = BC.unpack (BC.strip (BL.toStrict out))
      unless (code == ExitSuccess && not (null path)) $
        throwIO
          ( PythonFailure
              ("scripts/upstream-python " ++ project ++ " could not provision the upstream Python environment")
              (BL.toStrict out)
              (BL.toStrict err)
          )
      pure ((project, path) : known, path)

-- | The outcome of a one-shot snippet.
data PythonResult = PythonResult
  { resultExit :: ExitCode
  , resultStdout :: ByteString
  , resultStderr :: ByteString
  }
  deriving stock (Show)

snippet :: Text -> [String] -> IO (ProcessConfig () () ())
snippet code args = do
  exe <- pythonExecutable
  dir <- upstreamPetrus
  pure
    ( setWorkingDir dir
        (setEnvInherit (proc exe (["-I", "-c", T.unpack code] ++ args)))
    )

-- | Run a snippet (@python -I -c code args…@) with the given stdin, whatever
-- its exit status. @sys.argv[1:]@ holds the arguments.
runPython :: Text -> [String] -> ByteString -> IO PythonResult
runPython code args input = do
  config <- snippet code args
  (code', out, err) <- readProcess (setStdin (byteStringInput (BL.fromStrict input)) config)
  pure (PythonResult code' (BL.toStrict out) (BL.toStrict err))

-- | Run a snippet with empty stdin and return its stdout; a non-zero exit
-- raises 'PythonFailure' carrying both output streams.
python :: Text -> [String] -> IO ByteString
python code args = do
  result <- runPython code args ""
  case resultExit result of
    ExitSuccess -> pure (resultStdout result)
    ExitFailure status ->
      throwIO
        ( PythonFailure
            ("Python snippet exited with status " ++ show status ++ ":\n" ++ T.unpack code)
            (resultStdout result)
            (resultStderr result)
        )

-- | Run a snippet and parse its stdout as one JSON document (CPython
-- @json.loads@ semantics), typically produced by @print(json.dumps(…))@.
pythonJson :: Text -> [String] -> IO Json
pythonJson code args = do
  out <- python code args
  case parseJson pythonLoads out of
    Right value -> pure value
    Left problem -> throwIO (PythonFailure ("Python snippet printed invalid JSON: " ++ problem) out "")

-- | A running interactive snippet.
data PythonProcess = PythonProcess
  { processStdin :: Handle
  , processStdout :: Handle
  }

-- | Run an interactive snippet for the duration of an action, then terminate
-- it (its exact process, never a pattern) and wait for it. Lines written by
-- the snippet must be flushed (@print(…, flush=True)@).
--
-- The snippet is terminated and its exit awaited here, before
-- 'withProcessTerm' cleans up: that cleanup cancels typed-process's thread
-- blocked in @waitpid@, and when the snippet exits at that moment (it
-- finished, or a test made it die) the status that call reaped is lost, so
-- the cleanup's own wait fails with ECHILD ("waitForProcess: does not exist
-- (No child processes)"). Waiting through 'waitExitCode' never cancels that
-- thread, and the cleanup then finds the process already gone.
withPython :: Text -> [String] -> (PythonProcess -> IO a) -> IO a
withPython code args action = do
  config <- snippet code args
  let piped = setStdin createPipe (setStdout createPipe (setStderr inherit config))
  withProcessTerm piped $ \running -> do
    let input = getStdin running
        output = getStdout running
    hSetBuffering input LineBuffering
    action (PythonProcess input output) `finally` do
      Process.terminateProcess (unsafeProcessHandle running)
      void (waitExitCode running)

-- | Write one line (a newline is appended) to the snippet's stdin.
sendLine :: PythonProcess -> ByteString -> IO ()
sendLine process line = do
  BS.hPut (processStdin process) (line <> "\n")
  hFlush (processStdin process)

-- | Read one line (without its newline) from the snippet's stdout, failing
-- after 30 seconds or at end of file.
readLine :: PythonProcess -> IO ByteString
readLine process = do
  line <- timeout 30000000 (BC.hGetLine (processStdout process))
  case line of
    Just text -> pure (BC.filter (/= '\r') text)
    Nothing -> throwIO (PythonFailure "timed out after 30 s waiting for a line from Python" "" "")

-- | Read one line and require it to be exactly the given text.
expectLine :: PythonProcess -> ByteString -> IO ()
expectLine process expected = do
  line <- readLine process
  unless (line == expected) $
    throwIO (PythonFailure ("expected the line " ++ show expected ++ " from Python, got " ++ show line) line "")

-- | Close the snippet's stdin, so that it reads end of file.
closeInput :: PythonProcess -> IO ()
closeInput = hClose . processStdin
