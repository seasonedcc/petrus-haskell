-- | Fixtures for the SQLite Engine specs: the reference tests' empty net and
-- inline Dispatch, a scratch directory, the refusal spelling the reference's
-- driver prints (@"<ExceptionType>: <message>"@), and this test binary
-- re-executed as a separate process (the reference's @spawn@ context).
module Petrus.Engine.SqliteSupport
  ( emptyNet
  , noActivities
  , withScratch
  , refusalLine
  , outcomeLine
    -- * Re-executed roles
  , roleVariable
  , runRole
  , withRole
  , roleLine
  , sendRole
    -- * The reference
  , engineReference
  , withEngineReference
  ) where

import Control.Exception (SomeException, bracket, displayException, fromException, try)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Engine qualified as Engine
import Petrus.Engine.Sqlite (FenceError (..), createEngine, fenceErrorMessage, loadEngine)
import Petrus.HistoryStore.Sqlite (HistoryStoreError (..))
import Petrus.Impetus.Petrinet (Net)
import Petrus.Impetus.TestSupport (netOf)
import Petrus.Motus.Dispatch (Dispatch)
import Petrus.Motus.Dispatch.Inline (inlineDispatch, newInlineDispatch)
import Petrus.TestSupport.Python (PythonProcess, python, withPython)
import System.Directory (createDirectory, getTemporaryDirectory, makeAbsolute, removeDirectoryRecursive, removeFile)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (BufferMode (..), Handle, hClose, hFlush, hGetLine, hSetBuffering, openTempFile, stdout)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, proc, terminateProcess, waitForProcess)

-- | @Net(places=[], transitions=[], arcs=[])@.
emptyNet :: Net
emptyNet = netOf [] [] []

-- | @InlineDispatch({})@.
noActivities :: IO Dispatch
noActivities = inlineDispatch <$> newInlineDispatch Map.empty

-- | A fresh scratch directory, removed afterwards.
withScratch :: (FilePath -> IO a) -> IO a
withScratch =
  bracket
    ( do
        base <- getTemporaryDirectory
        (path, handle) <- openTempFile base "petrus-engine-sqlite"
        hClose handle
        removeFile path
        createDirectory path
        pure path
    )
    removeDirectoryRecursive

-- | The reference driver's spelling of a refusal:
-- @f"{type(error).__name__}: {error}"@.
refusalLine :: SomeException -> ByteString
refusalLine failure = TE.encodeUtf8 (T.pack (kind <> ": " <> message))
  where
    (kind, message)
      | Just fence <- fromException failure = (fenceKind fence, fenceErrorMessage fence)
      | Just engineError <- fromException failure = (engineKind engineError, displayException engineError)
      | Just (HistoryStoreError text) <- fromException failure = ("ValueError", T.unpack text)
      | otherwise = ("Exception", displayException failure)
    fenceKind = \case
      EmptyInstance -> "ValueError"
      _ -> "RuntimeError"
    engineKind = \case
      Engine.EngineValueError _ -> "ValueError"
      Engine.EngineTypeError _ -> "TypeError"
      Engine.EngineRuntimeError _ -> "RuntimeError"
      Engine.EngineHandlerFailed _ -> "Exception"

-- | Run an action and answer @"opened"@ or its refusal line.
outcomeLine :: IO () -> IO ByteString
outcomeLine action = either refusalLine (const "opened") <$> try action

-- ---------------------------------------------------------------------------
-- Re-executed roles

-- | Set in the environment of a re-executed test binary: the role it plays
-- instead of running the suite.
roleVariable :: String
roleVariable = "PETRUS_ENGINE_SQLITE_ROLE"

-- | The roles (the reference test's @_hold_engine@ and @_try_load@ process
-- targets):
--
-- * @hold PATH INSTANCE@ — create an Engine over an empty net, print
--   @ready@, wait for one stdin line (or end of input), close, print
--   @released@;
-- * @try-load PATH INSTANCE@ — load, close, and print @opened@ or the
--   refusal line.
runRole :: String -> [String] -> IO ()
runRole role arguments = do
  hSetBuffering stdout LineBuffering
  case (role, arguments) of
    ("hold", [path, instanceId]) -> do
      port <- noActivities
      engine <- createEngine path emptyNet (T.pack instanceId) port Engine.defaultEngineOptions
      BC.putStrLn "ready"
      _ <- try getLine :: IO (Either SomeException String)
      Engine.close engine
      BC.putStrLn "released"
    ("try-load", [path, instanceId]) -> do
      port <- noActivities
      line <- outcomeLine (loadEngine path emptyNet (T.pack instanceId) port Engine.defaultEngineOptions >>= Engine.close)
      BC.putStrLn line
    _ -> do
      BC.putStrLn ("unknown role " <> BC.pack (show (role, arguments)))
      exitFailure
  hFlush stdout

-- | This test binary re-executed in a role, for the duration of an action
-- (stdin and stdout piped); the process is terminated (SIGTERM, its exact
-- handle) and reaped afterwards.
withRole :: String -> [String] -> ((Handle, Handle, ProcessHandle) -> IO a) -> IO a
withRole role arguments action = do
  self <- getExecutablePath
  environment <- getEnvironment
  let process =
        (proc self arguments)
          { env = Just ((roleVariable, role) : filter ((/= roleVariable) . fst) environment)
          , std_in = CreatePipe
          , std_out = CreatePipe
          }
  bracket
    ( createProcess process >>= \case
        (Just input, Just output, _, handle) -> do
          hSetBuffering input LineBuffering
          pure (input, output, handle)
        _ -> fail "re-executed role without pipes"
    )
    (\(_, _, handle) -> terminateProcess handle >> waitForProcess handle)
    action

-- | One line from a role's stdout.
roleLine :: (Handle, Handle, ProcessHandle) -> IO ByteString
roleLine (_, output, _) = BC.pack <$> hGetLine output

-- | One line to a role's stdin.
sendRole :: (Handle, Handle, ProcessHandle) -> ByteString -> IO ()
sendRole (input, _, _) line = BC.hPutStrLn input line >> hFlush input

-- ---------------------------------------------------------------------------
-- The reference

runner :: T.Text
runner = "import runpy, sys; sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name='__main__')"

driver :: IO FilePath
driver = makeAbsolute ("test" </> "interop" </> "engine_sqlite_interop.py")

-- | Run one driver subcommand under the pinned reference and answer its
-- stdout.
engineReference :: [String] -> IO ByteString
engineReference arguments = do
  script <- driver
  python runner (script : arguments)

-- | A driver subcommand as a line-protocol process for an action's duration.
withEngineReference :: [String] -> (PythonProcess -> IO a) -> IO a
withEngineReference arguments action = do
  script <- driver
  withPython runner (script : arguments) action
