-- | Where the built viewer UI (the output of @pnpm build@ in petrus-viewer)
-- is found when no directory is given.
--
-- Upstream never has to look: @bin/petrus.mjs@ and the MCP server's
-- auto-start run Vite in the viewer checkout they belong to. The Haskell
-- executables serve a build instead, so they look for one next to
-- themselves, independently of the working directory:
--
-- 1. @\<bin\>/../share/petrus-viewer/ui@: an installed layout, with the
--    executables in @\<prefix\>/bin@ and the UI copied to
--    @\<prefix\>/share/petrus-viewer/ui@;
-- 2. @upstream/petrus-viewer/dist@ in the source checkout the executable
--    was built in (the nearest ancestor of its directory that has one), so
--    a @cabal build@ in this repository finds the UI that @pnpm build@
--    made in the submodule.
--
-- A candidate counts only when it holds an @index.html@.
-- @--ui-dir@ and @PETRUS_UI_DIR@ take precedence over all of this (see
-- "Petrus.Viewer.Cli").
module Petrus.Viewer.UiDir
  ( locateUiDir
  , uiDirCandidates
  ) where

import System.Directory (doesFileExist)
import System.FilePath (isDrive, takeDirectory, (</>))

-- | The places a build is looked for, in order, for executables living in
-- the given directories.
uiDirCandidates :: [FilePath] -> [FilePath]
uiDirCandidates binDirs =
  [takeDirectory dir </> "share" </> "petrus-viewer" </> "ui" | dir <- binDirs]
    ++ [ancestor </> "upstream" </> "petrus-viewer" </> "dist" | dir <- binDirs, ancestor <- ancestors dir]
  where
    ancestors d
      | isDrive d || takeDirectory d == d = [d]
      | otherwise = d : ancestors (takeDirectory d)

-- | The first candidate that holds a build.
locateUiDir :: [FilePath] -> IO (Maybe FilePath)
locateUiDir = firstBuilt . uiDirCandidates
  where
    firstBuilt = \case
      [] -> pure Nothing
      d : ds -> do
        built <- doesFileExist (d </> "index.html")
        if built then pure (Just d) else firstBuilt ds
