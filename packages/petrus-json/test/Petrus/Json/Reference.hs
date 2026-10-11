-- | The pinned reference interpreter, for the suites that run CPython itself.
--
-- petrus-json cannot use petrus-test-support (which depends on it), so it
-- provisions the reference the same way, through @scripts/upstream-python@,
-- the single place that pins CPython 3.14.6. A missing or unprovisionable
-- environment fails the test; it never skips it.
module Petrus.Json.Reference
  ( upstreamPython
  , repositoryRoot
  ) where

import System.Directory (doesFileExist, getCurrentDirectory, makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (proc, readCreateProcessWithExitCode)

-- | The repository root: the nearest ancestor holding @scripts/upstream-python@.
repositoryRoot :: IO FilePath
repositoryRoot = getCurrentDirectory >>= makeAbsolute >>= go
  where
    go dir = do
      found <- doesFileExist (dir </> "scripts" </> "upstream-python")
      if found
        then pure dir
        else if takeDirectory dir == dir then fail "no scripts/upstream-python above the test's directory" else go (takeDirectory dir)

-- | The pinned interpreter and the @upstream/petrus@ checkout it runs from.
upstreamPython :: IO (FilePath, FilePath)
upstreamPython = do
  root <- repositoryRoot
  (code, out, err) <- readCreateProcessWithExitCode (proc (root </> "scripts" </> "upstream-python") ["petrus"]) ""
  case (code, lines out) of
    (ExitSuccess, exe : _) -> pure (exe, root </> "upstream" </> "petrus")
    _ -> fail ("scripts/upstream-python could not provision the reference: " ++ err)
