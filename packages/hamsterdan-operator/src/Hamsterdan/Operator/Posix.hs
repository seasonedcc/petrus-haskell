-- | The rest of the CPython the operator calls on its file arguments:
-- @os.geteuid@, @shutil.which@, and the @pathlib@ and @os.path@ string
-- rules beyond petrus-posix's ("Petrus.Posix.Path" holds @normpath@ and
-- @PurePosixPath@'s parsing and @.parent@). The descriptor-relative calls
-- themselves (@os.fstat@, @os.stat(name, dir_fd=...,
-- follow_symlinks=False)@, @shutil.rmtree@) are "Petrus.Posix.At"'s.
module Hamsterdan.Operator.Posix
  ( effectiveUid
  , which

    -- * Paths
  , isAbsolute
  , pathName
  ) where

import Control.Exception (IOException, try)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Petrus.Posix.Path (confstrPath, pathParts)
import System.Environment (lookupEnv)
import System.Posix.Files (fileAccess, getFileStatus)
import System.Posix.Files qualified as PosixFiles
import System.Posix.User (getEffectiveUserID)

-- | @os.geteuid()@, in the type of 'Petrus.Posix.At.statUid'.
effectiveUid :: IO Int64
effectiveUid = fromIntegral <$> getEffectiveUserID

-- | @shutil.which(name)@ for a name without a directory part (POSIX):
-- along @PATH@ (@os.confstr("CS_PATH")@ when it is unset; nothing when the
-- search path is empty or the system defines none), each directory once, the first @os.path.join(directory,
-- name)@ that exists, passes @os.access(_, os.X_OK)@ and is not a
-- directory.
which :: String -> IO (Maybe FilePath)
which name = do
  path <- lookupEnv "PATH" >>= maybe (fromMaybe "" <$> confstrPath) pure
  if null path then pure Nothing else search Set.empty (splitColon path)
  where
    search _ [] = pure Nothing
    search seen (directory : more)
      | directory `Set.member` seen = search seen more
      | otherwise = do
          let candidate = join directory
          found <- accessCheck candidate
          if found then pure (Just candidate) else search (Set.insert directory seen) more
    join directory
      | null directory = name
      | last directory == '/' = directory <> name
      | otherwise = directory <> "/" <> name
    -- os.path.exists, os.access and os.path.isdir each answer False on an
    -- error.
    accessCheck candidate =
      try (getFileStatus candidate) >>= \case
        Left (_ :: IOException) -> pure False
        Right _ ->
          try (fileAccess candidate False False True) >>= \case
            Left (_ :: IOException) -> pure False
            Right False -> pure False
            Right True ->
              try (getFileStatus candidate) >>= \case
                Left (_ :: IOException) -> pure True
                Right status -> pure (not (PosixFiles.isDirectory status))
    splitColon s = case break (== ':') s of
      (piece, []) -> [piece]
      (piece, _ : rest) -> piece : splitColon rest

-- ---------------------------------------------------------------------------
-- Paths

-- | @Path(path).is_absolute()@.
isAbsolute :: FilePath -> Bool
isAbsolute = \case
  '/' : _ -> True
  _ -> False

-- | @Path(path).name@.
pathName :: FilePath -> String
pathName path = case snd (pathParts path) of
  [] -> ""
  components -> last components
