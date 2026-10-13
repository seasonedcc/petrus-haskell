{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE MultiWayIf #-}

-- | Python-compatible path normalization and resolution.
--
-- Upstream derives identities from resolved paths: the SQLite writer fence
-- hashes @str(Path(path).expanduser().resolve())@ into its lock-file name, so
-- a Haskell process locking the same database must produce the same string
-- byte for byte (on macOS @\/tmp@ resolves to @\/private\/tmp@; a missing tail
-- is kept; a symlink loop is left unresolved rather than raising). These
-- functions are direct ports of CPython 3.14's @posixpath.realpath@
-- (non-strict), @posixpath.expanduser@ and @pathlib@'s path parsing,
-- @Path.expanduser@ and @Path.resolve@.
--
-- 'System.Directory.canonicalizePath' is /not/ a substitute: it differs on
-- missing components, symlink loops and @..@ after a symlink.
module Petrus.Posix.Path
  ( -- * pathlib
    purePath
  , purePathParent
  , pathParts
  , pathExpandUser
  , pathResolve
  , expandAndResolve
  , HomeDirectoryUnknown (..)

    -- * os.path
  , normpath
  , realpath
  , expandUser

    -- * os
  , confstrPath
  ) where

import Control.Exception (Exception, throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.List (dropWhileEnd, elemIndex, intercalate, isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Foreign.C.Error (eOK, getErrno, resetErrno, throwErrno)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (nullPtr)
import System.Environment (lookupEnv)
import System.IO.Error (catchIOError)
import System.Posix.Directory.ByteString (getWorkingDirectory)
import System.Posix.Files.ByteString (readSymbolicLink)
import Petrus.Posix.Internal (withPath)
import System.Posix.Internals (peekFilePath)
import System.Posix.User (getRealUserID, getUserEntryForID, getUserEntryForName, homeDirectory)

-- | @RuntimeError("Could not determine home directory.")@ from
-- @Path.expanduser@.
newtype HomeDirectoryUnknown = HomeDirectoryUnknown String
  deriving stock (Eq, Show)

instance Exception HomeDirectoryUnknown

splitSlash :: String -> [String]
splitSlash s = case break (== '/') s of
  (part, []) -> [part]
  (part, _ : rest) -> part : splitSlash rest

-- | @PurePosixPath@'s parse: the root (@""@, @"/"@ or exactly @"//"@; three
-- or more leading slashes collapse to one) and the parts, with empty and
-- @"."@ parts dropped.
pathParts :: FilePath -> (String, [String])
pathParts path = (root, filter (\part -> not (null part) && part /= ".") (splitSlash rest))
  where
    (root, rest) = case path of
      '/' : '/' : '/' : _ -> ("/", drop 1 path)
      '/' : '/' : after -> ("//", after)
      '/' : after -> ("/", after)
      _ -> ("", path)

formatParts :: String -> [String] -> FilePath
formatParts root parts
  | null root && null parts = "."
  | otherwise = root ++ intercalate "/" parts

-- | @str(PurePosixPath(path))@: @"a//b/./c/"@ is @"a/b/c"@, @""@ is @"."@,
-- @"//x"@ keeps both slashes, @".."@ is kept (pathlib never collapses it).
purePath :: FilePath -> FilePath
purePath = uncurry formatParts . pathParts

-- | @str(PurePosixPath(path).parent)@, lexically: the path without its
-- last part (@"a/b/"@ gives @"a"@, @"a"@ gives @"."@), and a root or @"."@
-- is its own parent.
purePathParent :: FilePath -> FilePath
purePathParent path = case pathParts path of
  (root, []) -> formatParts root []
  (root, parts) -> formatParts root (init parts)

-- | @os.path.normpath(path)@ (@posixpath@): repeated slashes and @.@ parts
-- removed and each @..@ collapsed with the part before it, lexically. Two
-- leading slashes are kept (three or more become one), a @..@ at the root
-- is dropped and a relative path keeps its leading @..@ parts; an empty
-- result is @"."@. Only @/@ and @.@ are inspected, so the result is exact
-- for the 'Data.ByteString.Char8' spelling of a byte path as well.
normpath :: FilePath -> FilePath
normpath "" = "."
normpath path = if null joined then "." else joined
  where
    initial = case path of
      '/' : '/' : '/' : _ -> "/"
      '/' : '/' : _ -> "//"
      '/' : _ -> "/"
      _ -> ""
    joined = initial ++ intercalate "/" (reverse (foldl' step [] (splitSlash path)))
    step kept part
      | null part || part == "." = kept
      | part /= ".." || (null initial && null kept) || take 1 kept == [".."] = part : kept
      | otherwise = drop 1 kept

-- | @os.path.expanduser(path)@: a leading @~@ is replaced by @$HOME@ (or the
-- password database entry for the real uid when @HOME@ is unset) and @~user@
-- by that user's home; an unknown user leaves the path unchanged. Trailing
-- slashes of the home directory are stripped, and an empty result is @"/"@.
expandUser :: FilePath -> IO FilePath
expandUser path
  | not ("~" `isPrefixOf` path) = pure path
  | otherwise = do
      let i = maybe (length path) (+ 1) (elemIndex '/' (drop 1 path))
      home <-
        if i == 1
          then lookupEnv "HOME" >>= maybe ownHome (pure . Just)
          else namedHome (take (i - 1) (drop 1 path))
      pure $ case home of
        Nothing -> path
        Just userhome ->
          let expanded = dropWhileEnd (== '/') userhome ++ drop i path
           in if null expanded then "/" else expanded
  where
    ownHome = (Just . homeDirectory <$> (getRealUserID >>= getUserEntryForID)) `catchIOError` \_ -> pure Nothing
    namedHome name = (Just . homeDirectory <$> getUserEntryForName name) `catchIOError` \_ -> pure Nothing

-- | @str(Path(path).expanduser())@: only a relative path whose first part
-- starts with @~@ is expanded. Throws 'HomeDirectoryUnknown' when the
-- expansion still starts with @~@ (an unknown user, as in Python).
pathExpandUser :: FilePath -> IO FilePath
pathExpandUser path = case pathParts path of
  ("", first@('~' : _) : rest) -> do
    home <- expandUser first
    if "~" `isPrefixOf` home
      then throwIO (HomeDirectoryUnknown "Could not determine home directory.")
      else do
        let (root, parts) = pathParts home
        pure (formatParts root (parts ++ rest))
  _ -> pure (purePath path)

-- | @str(Path(path).resolve())@ (non-strict): 'realpath' of the normalized
-- path, normalized again.
pathResolve :: FilePath -> IO FilePath
pathResolve path = realpath (purePath path)
-- realpath's result is already normalized: it is absolute, starts with a
-- single slash and joins only non-empty, non-"." names.

-- | @str(Path(path).expanduser().resolve())@, the SQLite engine's database
-- identity.
expandAndResolve :: FilePath -> IO FilePath
expandAndResolve path = pathExpandUser path >>= realpath -- already normalized

data Pending = Part ByteString | Resolved ByteString

foreign import ccall unsafe "petrus_posix.h petrus_lstat_kind" c_lstat_kind :: CString -> IO CInt

-- | @os.path.realpath(path)@ with @strict=False@ (CPython 3.14): symlinks
-- are resolved component by component; errors from @lstat@/@readlink@ are
-- ignored (the component is kept as is); a symlink loop leaves the looping
-- link unresolved. Relative paths start from @getcwd()@.
--
-- The walk runs on the file-system encoding of the path (as the syscalls
-- see it) and decodes the result once.
realpath :: FilePath -> IO FilePath
realpath filename = do
  raw <- withPath filename BS.packCString
  resolved <- realpathRaw raw
  BS.useAsCString resolved peekFilePath

realpathRaw :: ByteString -> IO ByteString
realpathRaw filename = do
  start <- if "/" `BS.isPrefixOf` filename then pure "/" else getWorkingDirectory
  let parts = BC.split '/' filename
  go start Map.empty (map Part parts) (length parts)
  where
    go :: ByteString -> Map.Map ByteString (Maybe ByteString) -> [Pending] -> Int -> IO ByteString
    go path _ _ 0 = pure path
    go path seen pending count = case pending of
      [] -> pure path
      Resolved link : rest -> go path (Map.insert link (Just path) seen) rest count
      Part name : rest
        | BS.null name || name == "." -> go path seen rest (count - 1)
        | name == ".." -> go (parent path) seen rest (count - 1)
        | otherwise -> do
            let newpath = if path == "/" then path <> name else BS.concat [path, "/", name]
                count' = count - 1
            kind <- BS.useAsCString newpath c_lstat_kind
            if
              | kind /= 1 -> go newpath seen rest count'
              | Just cached <- Map.lookup newpath seen -> go (fromMaybe newpath cached) seen rest count'
              | otherwise -> do
                  target <- (Just <$> readSymbolicLink newpath) `catchIOError` \_ -> pure Nothing
                  case target of
                    Nothing -> go newpath seen rest count'
                    Just link -> do
                      let targetParts = BC.split '/' link
                          path' = if "/" `BS.isPrefixOf` link then "/" else path
                      go
                        path'
                        (Map.insert newpath Nothing seen)
                        (map Part targetParts ++ Resolved newpath : rest)
                        (count' + length targetParts)
    parent path = case BC.elemIndexEnd '/' path of
      Nothing -> "/"
      Just i -> if i == 0 then "/" else BS.take i path

foreign import capi unsafe "unistd.h confstr" c_confstr :: CInt -> CString -> CSize -> IO CSize

foreign import capi unsafe "unistd.h value _CS_PATH" csPathName :: CInt

-- | @os.confstr("CS_PATH")@: the system's default command search path
-- (@shutil.which@'s fallback when @PATH@ is unset), or 'Nothing' when the
-- system defines none.
confstrPath :: IO (Maybe FilePath)
confstrPath = do
  resetErrno
  size <- c_confstr csPathName nullPtr 0
  if size == 0
    then do
      errno <- getErrno
      if errno == eOK then pure Nothing else throwErrno "confstr"
    else allocaBytes (fromIntegral size) $ \buffer -> do
      _ <- c_confstr csPathName buffer size
      Just <$> peekFilePath buffer
