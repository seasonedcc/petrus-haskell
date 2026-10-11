-- | What the tier B and tier C specs share: recording a journey from the
-- reference, replaying a tape into either host against the tape's fake
-- GitHub, the comparison, and running the package's Python scripts in the
-- reference environment (provisioned by @scripts/upstream-python@; when it
-- cannot be, the tests fail, never skip).
module Support
  ( Run (..)
  , record
  , tierB
  , replayPython
  , replayHaskell
  , compareSides
  , compareRun
  , script
  , scriptPath
  , lastJson
  , historyFiles
  , render
  , readJson
  , withRoot
  , testKey
  ) where

import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Hamsterdan.E2E.Replay (ReplayOptions (..), runReplay)
import Hamsterdan.E2E.Tape (member)
import Petrus.Json (EncodeOptions (..), Json (..), defaultDumps, dumpsText, parseJson, pythonLoads)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory (canonicalizePath, createDirectoryIfMissing, listDirectory)
import System.FilePath ((</>))
import System.IO (hGetLine)
import System.IO.Temp (withSystemTempDirectory)
import System.Process.Typed
import Test.Hspec

data Run = Run
  { python' :: FilePath
  -- ^ The reference interpreter.
  , tape :: FilePath
  , record :: FilePath
  , python :: FilePath
  -- ^ The reference replay: @root@, @server.jsonl@, @report.json@.
  , haskell :: FilePath
  }

-- | @record_journey.py@: the reference interpreter and the tape.
record :: FilePath -> String -> Maybe String -> IO (FilePath, FilePath)
record dir journey fault = do
  interpreter <- upstreamPythonExecutable "hamsterdan"
  let tape = dir </> "tape"
  recorded <- script interpreter "record_journey.py" ([journey, dir </> "record", tape] <> maybe [] (\f -> ["--fault", f]) fault)
  case lastJson recorded of
    Just document -> member "provider_errors" document `shouldBe` Array []
    Nothing -> expectationFailure ("the recording printed no document:\n" <> BC.unpack recorded)
  pure (interpreter, tape)

-- | A journey recorded and replayed into both hosts.
tierB :: FilePath -> String -> Maybe String -> IO Run
tierB dir journey fault = do
  (interpreter, tape) <- record dir journey fault
  python <- replayPython interpreter [] tape (dir </> "python")
  haskell <- replayHaskell interpreter [] tape (dir </> "haskell")
  pure Run {python' = interpreter, tape, record = dir </> "record", python, haskell}

-- | @replay_python.py@, against @tape_server.py@ with the extra server
-- arguments.
replayPython :: FilePath -> [String] -> FilePath -> FilePath -> IO FilePath
replayPython interpreter server tape out = do
  createDirectoryIfMissing True out
  withTapeServer interpreter server tape (out </> "server.jsonl") $ \port ->
    () <$ script interpreter "replay_python.py" [tape, out </> "root", "--github-port", show port, "--server-log", out </> "server.jsonl", "--report", out </> "report.json"]
  pure out

-- | "Hamsterdan.E2E.Replay", in process, against @tape_server.py@.
replayHaskell :: FilePath -> [String] -> FilePath -> FilePath -> IO FilePath
replayHaskell interpreter server tape out = do
  createDirectoryIfMissing True out
  key <- testKey
  report <- withTapeServer interpreter server tape (out </> "server.jsonl") $ \port ->
    runReplay ReplayOptions {tape, root = out </> "root", githubPort = port, serverLog = out </> "server.jsonl", privateKey = key}
  case dumpsText defaultDumps {sortKeys = True, indent = Just 1} report of
    Right text -> BS.writeFile (out </> "report.json") (TE.encodeUtf8 text)
    Left problem -> expectationFailure ("unencodable report: " <> show problem)
  pure out

-- | @compare_tier_b.py@ over a tape, an optional recording and named
-- replays.
compareSides :: FilePath -> FilePath -> Maybe FilePath -> [(String, FilePath)] -> [String] -> IO (ExitCode, Json)
compareSides interpreter tape recording sides extra = do
  let side (name, path) = ["--side", name <> "=" <> (path </> "root") <> "," <> (path </> "server.jsonl") <> "," <> (path </> "report.json")]
  path <- scriptPath "compare_tier_b.py"
  (status, out, err) <-
    readProcess . proc interpreter $
      ["-I", "-B", path, tape]
        <> maybe [] (\root -> ["--record", root]) recording
        <> concatMap side sides
        <> ["--skip-context", "publisher"]
        <> extra
  case parseJson pythonLoads (BL.toStrict out) of
    Right report -> pure (status, report)
    Left problem -> expectationFailure ("unreadable comparison (" <> problem <> "):\n" <> BC.unpack (BL.toStrict err)) >> pure (status, Null)

-- | The recording and both replays.
compareRun :: Run -> [String] -> IO (ExitCode, Json)
compareRun run = compareSides run.python' run.tape (Just run.record) [("python", run.python), ("haskell", run.haskell)]

-- | The tape's fake GitHub on an ephemeral port, stopped (by its own
-- process handle) when the action returns.
withTapeServer :: FilePath -> [String] -> FilePath -> FilePath -> (Int -> IO a) -> IO a
withTapeServer interpreter server tape logPath action = do
  path <- scriptPath "tape_server.py"
  let config = setStdout createPipe (proc interpreter (["-I", "-B", path, tape, "--log", logPath, "--skip-context", "publisher"] <> server))
  withProcessTerm config $ \process -> do
    line <- hGetLine (getStdout process)
    case words line of
      ["port", port] | [(number, "")] <- reads port -> action number
      _ -> expectationFailure ("the tape server did not start: " <> line) >> action 0

scriptPath :: FilePath -> IO FilePath
scriptPath name = do
  repo <- repoRoot
  pure (repo </> "packages" </> "hamsterdan-e2e" </> "python" </> name)

-- | Run one of the package's Python scripts in the reference environment;
-- it must succeed. Its standard output.
script :: FilePath -> FilePath -> [String] -> IO BS.ByteString
script interpreter name arguments = do
  path <- scriptPath name
  (status, out, err) <- readProcess (proc interpreter (["-I", "-B", path] <> arguments))
  unless (status == ExitSuccess) $
    expectationFailure (name <> " failed:\n" <> BC.unpack (BL.toStrict err))
  pure (BL.toStrict out)

-- | The last line that is a JSON document (the Petrus Worker also prints).
lastJson :: BS.ByteString -> Maybe Json
lastJson out = case reverse (filter (not . BC.null) (BC.lines out)) of
  line : _ -> either (const Nothing) Just (parseJson pythonLoads line)
  [] -> Nothing

historyFiles :: FilePath -> IO [FilePath]
historyFiles root = go (3 :: Int) (root </> "applications")
  where
    go 0 dir = pure [dir </> "history.jsonl"]
    go n dir = do
      entries <- listDirectory dir
      concat <$> mapM (go (n - 1) . (dir </>)) entries

render :: Json -> String
render value = either show (BC.unpack . TE.encodeUtf8) (dumpsText defaultDumps {sortKeys = True, indent = Just 1} value)

readJson :: BS.ByteString -> IO Json
readJson bytes = case parseJson pythonLoads bytes of
  Right value -> pure value
  Left problem -> expectationFailure ("not JSON (" <> problem <> "): " <> BC.unpack (BS.take 2000 bytes)) >> pure Null

withRoot :: (FilePath -> IO a) -> IO a
withRoot use = withSystemTempDirectory "hamsterdan-e2e" (\dir -> canonicalizePath dir >>= use)

-- | hamsterdan-github's test App key.
testKey :: IO Text
testKey = do
  repo <- repoRoot
  TE.decodeUtf8 <$> BS.readFile (repo </> "packages" </> "hamsterdan-github" </> "test" </> "corpus" </> "app-test-key.pem")
