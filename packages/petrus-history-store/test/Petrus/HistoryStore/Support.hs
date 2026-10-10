-- | Shared fixtures for the History store specs.
module Petrus.HistoryStore.Support
  ( withScratch
  , jsonlReopen
  , place'
  , transition'
  , token'
  , storeErrorContaining
  , runPython
  , withReference
  ) where

import Control.Exception (bracket)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.HistoryStore.Jsonl
import Petrus.Impetus.HistoryStore (HistoryStore)
import Petrus.Impetus.Petrinet (NetPath, Token)
import Petrus.Impetus.TestSupport (np, tokD)
import Petrus.Json (Json (..))
import Petrus.TestSupport.Python (pythonExecutable)
import Petrus.TestSupport.Repo (upstreamPetrus)
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

-- | Run the example against the pinned reference: its interpreter
-- (provisioned by @scripts/upstream-python@ on first use) and the upstream
-- root. Fails loudly, never skips, when the reference cannot be provisioned.
withReference :: ((FilePath, FilePath) -> IO a) -> IO a
withReference body = do
  python <- pythonExecutable
  root <- upstreamPetrus
  body (python, root)
