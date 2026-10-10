-- | Shared fixtures for the History store specs.
module Petrus.HistoryStore.Support
  ( withScratch
  , jsonlReopen
  , place'
  , transition'
  , token'
  , storeErrorContaining
  , upstreamPython
  , runPython
  , pythonOrPending
  ) where

import Control.Exception (bracket)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.HistoryStore.Jsonl
import Petrus.Impetus.HistoryStore (HistoryStore)
import Petrus.Impetus.Petrinet (NetPath, Token)
import Petrus.Impetus.TestSupport (np, tokD)
import Petrus.Json (Json (..))
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec

-- | A fresh scratch directory, removed afterwards.
withScratch :: (FilePath -> IO a) -> IO a
withScratch action = do
  base <- getTemporaryDirectory
  bracket
    ( do
        (path, handle) <- openTempFile base "petrus-history-store"
        hClose handle
        removeFile path
        createDirectory path
        pure path
    )
    removeDirectoryRecursive
    action

-- | The reference's @reopen@ fixture for JSONL: each call loads a fresh
-- store over the same file.
jsonlReopen :: FilePath -> IO HistoryStore
jsonlReopen directory = openJsonlHistoryStore (directory </> "history.jsonl")

-- | @PLACE, TRANSITION = NetPath("p"), NetPath("t")@.
place', transition' :: NetPath
place' = np "p"
transition' = np "t"

-- | @TOKEN = Token("issue", {"id": "goose", "passed": True})@.
token' :: Token
token' = tokD "issue" (Object [("id", String "goose"), ("passed", Bool True)])

-- | A store refusal whose message contains the fragment.
storeErrorContaining :: Text -> Selector HistoryStoreError
storeErrorContaining fragment (HistoryStoreError message) = fragment `T.isInfixOf` message

-- | The pinned reference's virtual environment interpreter and its root,
-- when synced (@cd upstream/petrus && uv sync@).
upstreamPython :: IO (Maybe (FilePath, FilePath))
upstreamPython = do
  root <- makeAbsolute ("../.." </> "upstream" </> "petrus")
  let python = root </> ".venv" </> "bin" </> "python"
  present <- doesFileExist python
  pure (if present then Just (python, root) else Nothing)

-- | Run a script under the reference (cwd = the upstream root); fail the
-- example on a non-zero exit and return its stdout.
runPython :: (FilePath, FilePath) -> FilePath -> [String] -> IO String
runPython (python, root) script arguments = do
  scriptPath <- makeAbsolute script
  (code, out, err) <- readCreateProcessWithExitCode (proc python (scriptPath : arguments)) {cwd = Just root} ""
  case code of
    ExitSuccess -> pure out
    ExitFailure n -> do
      expectationFailure ("python " <> script <> " exited " <> show n <> ":\n" <> out <> err)
      pure out

-- | Run the example against the reference, or mark it pending when the
-- reference's environment is not synced.
pythonOrPending :: ((FilePath, FilePath) -> IO ()) -> IO ()
pythonOrPending body =
  upstreamPython >>= \case
    Just python -> body python
    Nothing -> pendingWith "upstream/petrus is not synced (cd upstream/petrus && uv sync)"
