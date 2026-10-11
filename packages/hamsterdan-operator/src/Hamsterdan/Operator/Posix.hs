-- | The POSIX calls the qualification fences make (@os.fstat@, @os.lstat@,
-- @os.stat(name, dir_fd=..., follow_symlinks=False)@), @shutil.which@, and
-- the @pathlib@ and @os.path@ string rules the operator applies to its file
-- arguments.
module Hamsterdan.Operator.Posix
  ( -- * Status
    Stat (..)
  , fdStat
  , lstat
  , statAt
  , isDirectory
  , isRegular
  , isSymlink
  , permissionBits
  , effectiveUid
  , which

    -- * Removal
  , rmtree

    -- * Paths
  , isAbsolute
  , pathParent
  , pathName
  , normpath
  ) where

import Control.Exception (IOException, try)
import Data.Bits ((.&.))
import Data.List (intercalate)
import Data.Set qualified as Set
import Data.Word (Word64)
import Foreign.C.Error (Errno (..), errnoToIOError, throwErrnoPathIfMinus1_)
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CChar, CInt (..), CSize (..))
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr, nullPtr)
import System.Environment (lookupEnv)
import System.Posix.Files (fileAccess, getFileStatus)
import System.Posix.Files qualified as PosixFiles
import System.Posix.Types (Fd (..))
import System.Posix.User (getEffectiveUserID)

-- | The fields of a @struct stat@ the fences compare.
data Stat = Stat
  { mode :: Word64
  , uid :: Word64
  , dev :: Word64
  , ino :: Word64
  , nlink :: Word64
  , size :: Word64
  }
  deriving stock (Eq, Show)

foreign import ccall unsafe "hamsterdan_fstat"
  c_fstat :: CInt -> Ptr Word64 -> IO CInt

foreign import ccall unsafe "hamsterdan_lstat"
  c_lstat :: CString -> Ptr Word64 -> IO CInt

foreign import ccall unsafe "hamsterdan_fstatat_nofollow"
  c_fstatat :: CInt -> CString -> Ptr Word64 -> IO CInt

withStat :: String -> FilePath -> (Ptr Word64 -> IO CInt) -> IO Stat
withStat call path action = allocaArray 6 $ \out -> do
  throwErrnoPathIfMinus1_ call path (action out)
  fields <- peekArray 6 out
  case fields of
    [m, u, d, i, n, s] -> pure Stat {mode = m, uid = u, dev = d, ino = i, nlink = n, size = s}
    _ -> ioError (userError "stat: short result")

-- | @os.fstat(fd)@.
fdStat :: Fd -> IO Stat
fdStat (Fd fd) = withStat "fstat" "" (c_fstat fd)

-- | @os.lstat(path)@ (@Path.lstat()@, @Path.stat(follow_symlinks=False)@).
lstat :: FilePath -> IO Stat
lstat path = withCString path $ \cpath -> withStat "lstat" path (c_lstat cpath)

-- | @os.stat(name, dir_fd=fd, follow_symlinks=False)@.
statAt :: Fd -> FilePath -> IO Stat
statAt (Fd fd) name = withCString name $ \cname -> withStat "fstatat" name (c_fstatat fd cname)

fileType :: Stat -> Word64
fileType s = s.mode .&. 0o170000

isDirectory, isRegular, isSymlink :: Stat -> Bool
isDirectory s = fileType s == 0o040000
isRegular s = fileType s == 0o100000
isSymlink s = fileType s == 0o120000

-- | @stat.S_IMODE(mode)@.
permissionBits :: Stat -> Word64
permissionBits s = s.mode .&. 0o7777

-- | @os.geteuid()@.
effectiveUid :: IO Word64
effectiveUid = fromIntegral <$> getEffectiveUserID

foreign import ccall safe "hamsterdan_rmtree"
  c_rmtree :: CString -> IO CInt

-- | @shutil.rmtree(path)@ (CPython's descriptor-relative walk, which never
-- follows a symbolic link and resolves no path below the top twice). Raises
-- the first error the walk meets; a missing top is a does-not-exist error,
-- and a top that is a symbolic link raises like any other refusal.
rmtree :: FilePath -> IO ()
rmtree path = do
  err <- withCString path c_rmtree
  if err == 0 then pure () else ioError (errnoToIOError "rmtree" (Errno err) Nothing (Just path))

foreign import ccall unsafe "hamsterdan_cs_path"
  c_csPath :: Ptr CChar -> CSize -> IO CSize

-- | @os.confstr("CS_PATH")@, or @os.defpath@ when the system has none.
csPath :: IO String
csPath = do
  size <- c_csPath nullPtr 0
  if size == 0
    then pure "/bin:/usr/bin"
    else allocaArray (fromIntegral size) \buffer -> c_csPath buffer size >> peekCString buffer

-- | @shutil.which(name)@ for a name without a directory part (POSIX):
-- along @PATH@ (@os.confstr("CS_PATH")@ when it is unset, nothing when it
-- is empty), each directory once, the first @os.path.join(directory,
-- name)@ that exists, passes @os.access(_, os.X_OK)@ and is not a
-- directory.
which :: String -> IO (Maybe FilePath)
which name = do
  path <- lookupEnv "PATH" >>= maybe csPath pure
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
