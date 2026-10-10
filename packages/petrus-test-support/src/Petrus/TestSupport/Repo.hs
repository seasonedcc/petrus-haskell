-- | Locating this repository and the pinned upstream checkouts from a test.
--
-- @cabal test@ runs each suite from its package directory, while
-- @scripts/check-all@ and editors may run them from elsewhere. Every helper
-- here therefore walks up from the current directory to the repository root
-- (the directory holding @cabal.project@ and @upstream/@), so fixture paths are
-- independent of the working directory.
module Petrus.TestSupport.Repo
  ( repoRoot
  , upstreamPetrus
  , upstreamPath
  , readUpstream
  , upstreamJson
  , MissingUpstream (..)
  ) where

import Control.Exception (Exception, throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Petrus.Json (Json, parseJson, pythonLoads)
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory, makeAbsolute)
import System.FilePath (takeDirectory, (</>))

-- | Raised when the repository root or an upstream file cannot be found.
newtype MissingUpstream = MissingUpstream String
  deriving stock (Show)

instance Exception MissingUpstream

-- | The repository root: the nearest ancestor of the current directory that
-- holds both @cabal.project@ and @upstream/@.
repoRoot :: IO FilePath
repoRoot = getCurrentDirectory >>= makeAbsolute >>= go
  where
    go dir = do
      project <- doesFileExist (dir </> "cabal.project")
      upstream <- doesDirectoryExist (dir </> "upstream")
      if project && upstream
        then pure dir
        else
          let parent = takeDirectory dir
           in if parent == dir
                then throwIO (MissingUpstream "no ancestor directory holds cabal.project and upstream/")
                else go parent

-- | The pinned @henriquebastos/petrus@ checkout (@upstream/petrus@). Fails
-- with a hint when the submodule has not been initialized.
upstreamPetrus :: IO FilePath
upstreamPetrus = do
  root <- repoRoot
  let dir = root </> "upstream" </> "petrus"
  initialized <- doesFileExist (dir </> "pyproject.toml")
  if initialized
    then pure dir
    else
      throwIO
        ( MissingUpstream
            ("upstream/petrus is empty; run `git submodule update --init upstream/petrus` in " ++ root)
        )

-- | An existing path inside @upstream/petrus@, such as
-- @"spec/observation/simulation-service-profile-v1.json"@.
upstreamPath :: FilePath -> IO FilePath
upstreamPath relative = do
  dir <- upstreamPetrus
  let path = dir </> relative
  file <- doesFileExist path
  directory <- doesDirectoryExist path
  if file || directory
    then pure path
    else throwIO (MissingUpstream ("upstream/petrus/" ++ relative ++ " does not exist at the pinned commit"))

-- | The bytes of a file inside @upstream/petrus@.
readUpstream :: FilePath -> IO ByteString
readUpstream relative = upstreamPath relative >>= BS.readFile

-- | A JSON fixture inside @upstream/petrus@, parsed as CPython's @json.loads@
-- would.
upstreamJson :: FilePath -> IO Json
upstreamJson relative = do
  bytes <- readUpstream relative
  either (throwIO . MissingUpstream . (("upstream/petrus/" ++ relative ++ ": ") ++)) pure (parseJson pythonLoads bytes)
