-- | One custody installation shared by both implementations: a corpus
-- session runs its first steps under one implementation and the rest under
-- the other, over the same SQLite file and materialization root, and every
-- record must still match the reference corpus.  Pending when the pinned
-- reference environment is not synced.
module Petrus.Agenticus.CustodyInteropSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString.Char8 qualified as BC
import Petrus.Agenticus.ConnectionSupport (withScratch)
import Petrus.Agenticus.CustodyScript
import Petrus.Agenticus.Support (loadJson, packageFile)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Directory (doesFileExist, makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec

spec :: Spec
spec = describe "interop: custody sessions across implementations" $ do
  corpus <- runIO (loadJson "differential/custody_corpus.json")
  let sessions = take 6 (members (member "sessions" corpus))
  forM_ sessions $ \session -> do
    let seed = case member "seed" session of
          Int n -> n
          other -> error ("bad seed " <> show other)
        steps = members (member "steps" session)
        expected = members (member "records" session)
        total = length steps
    forM_ [17, 33] $ \split -> do
      it ("seed " <> show seed <> ": Haskell steps [0," <> show split <> "), Python the rest") $
        pythonOrPending $ \python -> withScratch $ \scratch -> do
          prefix <- runSteps scratch steps 0 split
          compareRecords steps 0 (take split expected) prefix
          rest <- continueInPython python seed scratch split total
          compareRecords steps split (drop split expected) (map canonical rest)
      it ("seed " <> show seed <> ": Python steps [0," <> show split <> "), Haskell the rest") $
        pythonOrPending $ \python -> withScratch $ \scratch -> do
          prefix <- continueInPython python seed scratch 0 split
          compareRecords steps 0 (take split expected) (map canonical prefix)
          rest <- runSteps scratch steps split total
          compareRecords steps split (drop split expected) rest

-- | Run @custody_interop.py@ under the reference for steps @[start, stop)@.
continueInPython :: (FilePath, FilePath) -> Integer -> FilePath -> Int -> Int -> IO [Json]
continueInPython (python, root) seed workdir start stop = do
  script <- makeAbsolute =<< packageFile "differential/custody_interop.py"
  corpusPath <- makeAbsolute =<< packageFile "differential/custody_corpus.json"
  let arguments = [script, corpusPath, show seed, workdir, show start, show stop]
  (code, out, err) <- readCreateProcessWithExitCode (proc python arguments) {cwd = Just root} ""
  case code of
    ExitSuccess -> either fail (pure . members) (J.parseJson J.pythonLoads (BC.pack out))
    ExitFailure n -> fail ("custody_interop.py exited " <> show n <> ":\n" <> out <> err)

-- | The pinned reference's interpreter and root, when synced.
pythonOrPending :: ((FilePath, FilePath) -> IO ()) -> IO ()
pythonOrPending body = do
  root <- makeAbsolute ("../.." </> "upstream" </> "petrus")
  let python = root </> ".venv" </> "bin" </> "python"
  present <- doesFileExist python
  if present
    then body (python, root)
    else pendingWith "upstream/petrus is not synced (cd upstream/petrus && uv sync)"
