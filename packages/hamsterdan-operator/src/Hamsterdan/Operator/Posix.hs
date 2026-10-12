-- | The rest of the CPython the operator calls on its file arguments:
-- @os.geteuid@, @shutil.which@, and the @pathlib@ and @os.path@ string
-- rules. The descriptor-relative calls themselves (@os.fstat@, @os.stat(name,
-- dir_fd=..., follow_symlinks=False)@, @shutil.rmtree@) are
-- "Petrus.Posix.At"'s.
module Hamsterdan.Operator.Posix
  ( effectiveUid
  , which

    -- * Paths
  , isAbsolute
  , pathParent
  , pathName
  , normpath
  ) where

import Control.Exception (IOException, try)
import Data.Int (Int64)
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Petrus.Posix.Path (confstrPath)
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

-- | @PurePosixPath(path)@: the root (@""@, @"/"@ or @"//"@) and the parts,
-- with empty and @.@ components dropped.
parts :: FilePath -> (String, [String])
parts path = (root, filter (`notElem` ["", "."]) (splitSlash rest))
  where
    (root, rest) = case path of
      '/' : '/' : c : more | c /= '/' -> ("//", c : more)
      '/' : '/' : [] -> ("//", [])
      '/' : more -> ("/", dropWhile (== '/') more)
      _ -> ("", path)
    splitSlash s = case break (== '/') s of
      (part, []) -> [part]
      (part, _ : more) -> part : splitSlash more

render :: String -> [String] -> FilePath
render root components = case (root, components) of
  ("", []) -> "."
  _ -> root <> intercalate "/" components

-- | @str(Path(path).parent)@.
pathParent :: FilePath -> FilePath
pathParent path = let (root, components) = parts path in render root (if null components then [] else init components)

-- | @Path(path).name@.
pathName :: FilePath -> String
pathName path = case snd (parts path) of
  [] -> ""
  components -> last components

-- | @os.path.normpath(path)@ (POSIX), which @os.path.abspath@ applies to an
-- absolute path.
normpath :: FilePath -> FilePath
normpath "" = "."
normpath path =
  let initial = case path of
        '/' : '/' : c : _ | c /= '/' -> "//"
        "//" -> "//"
        '/' : _ -> "/"
        _ -> ""
      components = foldl step [] (splitSlash path)
      step acc component
        | component `elem` ["", "."] = acc
        | component /= ".." = acc <> [component]
        | null initial && (null acc || last acc == "..") = acc <> [component]
        | not (null acc) = init acc
        | otherwise = acc
      joined = initial <> intercalate "/" components
   in if null joined then "." else joined
  where
    splitSlash s = case break (== '/') s of
      (part, []) -> [part]
      (part, _ : more) -> part : splitSlash more
