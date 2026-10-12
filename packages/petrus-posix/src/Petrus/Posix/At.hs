{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE InterruptibleFFI #-}

-- | openat-family file operations relative to a directory descriptor.
--
-- Upstream's private-file custody (agenticus materialization, the Gondolin
-- and Codex helpers) never follows a path from the root: it walks
-- @os.open(name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, dir_fd=parent)@ one
-- component at a time and then creates, stats, renames and unlinks with
-- @dir_fd=@. This module provides the same calls. A 'Nothing' directory means
-- @AT_FDCWD@ (the current directory), as Python's @dir_fd=None@ does.
--
-- Errors are raised as 'IOError's carrying @errno@ and the path, like
-- Python's 'OSError' subclasses (@FileExistsError@ is 'isAlreadyExistsError',
-- @FileNotFoundError@ is 'System.IO.Error.isDoesNotExistError', and so on).
module Petrus.Posix.At
  ( -- * Opening
    openAt
  , openDirectoryAt
  , createExclusiveAt

    -- * Directory entries
  , mkdirAt
  , unlinkAt
  , removeDirectoryAt
  , renameAt
  , listDirectoryFd
  , rmtree

    -- * Metadata
  , Follow (..)
  , FileStat (..)
  , statAt
  , fdStat
  , isRegularFile
  , isDirectory
  , isSymbolicLink
  , permissionBits
  , fchmod

    -- * Re-exports from "System.Posix.IO"
  , OpenMode (..)
  , OpenFileFlags (..)
  , defaultFileFlags
  , closeFd
  ) where

import Control.Exception (bracket, throwIO, try)
import Control.Monad (forM, unless, void)
import Data.Bits ((.&.))
import Data.Int (Int64)
import Data.Maybe (catMaybes)
import Foreign.C.Error (eINTR, eOK, getErrno, throwErrno, throwErrnoIfMinus1Retry_, throwErrnoPath)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek, peekElemOff)
import GHC.IO.Exception (IOErrorType (InappropriateType))
import System.IO.Error (isDoesNotExistError, mkIOError)
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, openFdAt)
import Petrus.Posix.Internal (withPath)
import System.Posix.Internals (peekFilePath)
import System.Posix.Types (CMode (..), Fd (..), FileMode)

foreign import ccall unsafe "petrus_posix.h petrus_at_fdcwd" c_at_fdcwd :: IO CInt

foreign import ccall unsafe "petrus_posix.h petrus_at_removedir" c_at_removedir :: IO CInt

foreign import ccall interruptible "petrus_posix.h petrus_fstatat"
  c_fstatat :: CInt -> CString -> CInt -> Ptr Int64 -> IO CInt

foreign import ccall unsafe "petrus_posix.h petrus_fstat" c_fstat :: CInt -> Ptr Int64 -> IO CInt

foreign import capi interruptible "sys/stat.h mkdirat" c_mkdirat :: CInt -> CString -> CMode -> IO CInt

foreign import capi interruptible "unistd.h unlinkat" c_unlinkat :: CInt -> CString -> CInt -> IO CInt

foreign import capi interruptible "stdio.h renameat" c_renameat :: CInt -> CString -> CInt -> CString -> IO CInt

foreign import capi unsafe "sys/stat.h fchmod" c_fchmod :: CInt -> CMode -> IO CInt

foreign import ccall unsafe "petrus_posix.h petrus_fdopendir" c_fdopendir :: CInt -> IO (Ptr ())

foreign import ccall unsafe "petrus_posix.h petrus_readdir" c_readdir :: Ptr () -> Ptr CInt -> IO CString

foreign import ccall unsafe "petrus_posix.h petrus_closedir" c_closedir :: Ptr () -> IO CInt

-- Run a call returning -1 on failure, retrying on EINTR and throwing an
-- IOError naming the path otherwise.
retryPath :: String -> FilePath -> IO CInt -> IO ()
retryPath location path call = do
  result <- call
  if result /= -1
    then pure ()
    else do
      errno <- getErrno
      if errno == eINTR then retryPath location path call else throwErrnoPath location path

directoryFd :: Maybe Fd -> IO CInt
directoryFd = maybe c_at_fdcwd (\(Fd fd) -> pure fd)

-- | @os.open(path, flags, mode, dir_fd=dir)@ ("System.Posix.IO"'s
-- 'openFdAt'). Python descriptors are close-on-exec; set 'cloexec' to match.
openAt :: Maybe Fd -> FilePath -> OpenMode -> OpenFileFlags -> IO Fd
openAt = openFdAt

-- | @os.open(name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, dir_fd=dir)@, the
-- step of every upstream openat walk. A symlink fails with @ELOOP@ (or
-- @ENOTDIR@), never followed.
openDirectoryAt :: Maybe Fd -> FilePath -> IO Fd
openDirectoryAt dir name =
  openFdAt dir name ReadOnly defaultFileFlags {directory = True, nofollow = True, cloexec = True}

-- | @os.open(name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode,
-- dir_fd=dir)@: create a new private file, failing with @EEXIST@ when the name
-- exists (including as a dangling symlink).
createExclusiveAt :: Maybe Fd -> FilePath -> FileMode -> IO Fd
createExclusiveAt dir name mode =
  openFdAt dir name WriteOnly defaultFileFlags {creat = Just mode, exclusive = True, nofollow = True, cloexec = True}

-- | @os.mkdir(name, mode, dir_fd=dir)@ (the mode is subject to the umask).
mkdirAt :: Maybe Fd -> FilePath -> FileMode -> IO ()
mkdirAt dir name mode = do
  base <- directoryFd dir
  withPath name $ \cname ->
    retryPath "mkdirat" name (c_mkdirat base cname mode)

-- | @os.unlink(name, dir_fd=dir)@.
unlinkAt :: Maybe Fd -> FilePath -> IO ()
unlinkAt dir name = do
  base <- directoryFd dir
  withPath name $ \cname ->
    retryPath "unlinkat" name (c_unlinkat base cname 0)

-- | @os.rmdir(name, dir_fd=dir)@.
removeDirectoryAt :: Maybe Fd -> FilePath -> IO ()
removeDirectoryAt dir name = do
  base <- directoryFd dir
  flag <- c_at_removedir
  withPath name $ \cname ->
    retryPath "unlinkat" name (c_unlinkat base cname flag)

-- | @os.replace(src, dst, src_dir_fd=, dst_dir_fd=)@: an atomic rename that
-- replaces an existing destination.
renameAt :: Maybe Fd -> FilePath -> Maybe Fd -> FilePath -> IO ()
renameAt fromDir from toDir to = do
  fromBase <- directoryFd fromDir
  toBase <- directoryFd toDir
  withPath from $ \cfrom -> withPath to $ \cto ->
    retryPath "renameat" from (c_renameat fromBase cfrom toBase cto)

-- | @os.listdir(fd)@: the entry names of an open directory, in @readdir@
-- order, without @.@ and @..@. The descriptor stays open and owned by the
-- caller (the listing uses a duplicate).
listDirectoryFd :: Fd -> IO [FilePath]
listDirectoryFd fd = map fst <$> scanDirectoryFd fd

-- | 'listDirectoryFd' with what @d_type@ says of each entry, as
-- @os.scandir(fd)@ keeps it: 'Just' whether it is a directory (a symbolic
-- link is not), or 'Nothing' when the file system does not say.
scanDirectoryFd :: Fd -> IO [(FilePath, Maybe Bool)]
scanDirectoryFd (Fd fd) =
  bracket open (void . c_closedir) collect
  where
    open = do
      stream <- c_fdopendir fd
      if stream == nullPtr then throwErrno "fdopendir" else pure stream
    collect stream = alloca $ \kind ->
      let go acc = do
            entry <- c_readdir stream kind
            if entry == nullPtr
              then do
                errno <- getErrno
                unless (errno == eOK) (throwErrno "readdir")
                pure (reverse acc)
              else do
                name <- peekFilePath entry
                directory <- peek kind
                let known = case directory of
                      1 -> Just True
                      0 -> Just False
                      _ -> Nothing
                go (if name == "." || name == ".." then acc else (name, known) : acc)
       in go []

-- | @shutil.rmtree(path)@ as CPython 3.14 runs it on POSIX
-- (@_rmtree_safe_fd@): @lstat@ the top, open it @O_RDONLY | O_NONBLOCK@,
-- refuse it when @fstat@ does not name the same file (a symbolic link), list
-- it, unlink every entry that is not a directory relative to it, descend into
-- the directories (the last listed first) the same way, close it, and
-- @rmdir@ it relative to its parent. Below the top every call is relative to
-- an open directory, so no path is resolved twice and no symbolic link is
-- followed.
--
-- The first error is raised. As in CPython, an entry that vanishes while the
-- tree is walked is skipped; only the top's own absence raises (a
-- does-not-exist error).
rmtree :: FilePath -> IO ()
rmtree path = removeTree Nothing path True

removeTree :: Maybe Fd -> FilePath -> Bool -> IO ()
removeTree parent name top = skipVanished $ do
  original <- statAt parent name NoFollowLinks
  bracket (openAt parent name ReadOnly defaultFileFlags {nonBlock = True, cloexec = True}) closeFd $ \fd -> do
    opened <- fdStat fd
    unless ((statDevice opened, statInode opened) == (statDevice original, statInode original)) $
      ioError (mkIOError InappropriateType "Cannot call rmtree on a symbolic link" Nothing (Just name))
    entries <- scanDirectoryFd fd
    directories <- fmap catMaybes . forM entries $ \(entry, known) -> do
      directory <- maybe (directoryAt fd entry) (pure . Just) known
      case directory of
        Just True -> pure (Just entry)
        Just False -> Nothing <$ vanishing (unlinkAt (Just fd) entry)
        Nothing -> pure Nothing
    mapM_ (\entry -> removeTree (Just fd) entry False) (reverse directories)
  removeDirectoryAt parent name
  where
    skipVanished = if top then id else vanishing
    -- DirEntry.is_dir(follow_symlinks=False) when d_type said nothing: an
    -- entry that vanished is skipped ('Nothing'), and one that cannot be
    -- examined is unlinked like a file.
    directoryAt fd entry =
      try (statAt (Just fd) entry NoFollowLinks) >>= \case
        Right stat -> pure (Just (isDirectory stat))
        Left e
          | isDoesNotExistError e -> pure Nothing
          | otherwise -> pure (Just False)

-- | Run the action, ignoring a does-not-exist error.
vanishing :: IO () -> IO ()
vanishing action =
  try action >>= \case
    Left e | not (isDoesNotExistError e) -> throwIO e
    _ -> pure ()

-- | Whether the final component of a path is followed when it is a symlink
-- (@follow_symlinks=@ / @AT_SYMLINK_NOFOLLOW@).
data Follow = FollowLinks | NoFollowLinks
  deriving stock (Eq, Show)

-- | The fields of @struct stat@ upstream reads (an @os.stat_result@ subset).
data FileStat = FileStat
  { statDevice :: Int64
  , statInode :: Int64
  , statMode :: Int64
  , statLinkCount :: Int64
  , statUid :: Int64
  , statGid :: Int64
  , statSize :: Int64
  , statAccessSeconds :: Int64
  , statAccessNanoseconds :: Int64
  , statModifySeconds :: Int64
  , statModifyNanoseconds :: Int64
  , statChangeSeconds :: Int64
  , statChangeNanoseconds :: Int64
  }
  deriving stock (Eq, Show)

-- | The 13 fields the C shim writes, in 'FileStat' field order.
peekFileStat :: Ptr Int64 -> IO FileStat
peekFileStat buffer =
  FileStat
    <$> field 0
    <*> field 1
    <*> field 2
    <*> field 3
    <*> field 4
    <*> field 5
    <*> field 6
    <*> field 7
    <*> field 8
    <*> field 9
    <*> field 10
    <*> field 11
    <*> field 12
  where
    field = peekElemOff buffer

-- | @os.stat(name, dir_fd=dir, follow_symlinks=...)@.
statAt :: Maybe Fd -> FilePath -> Follow -> IO FileStat
statAt dir name follow = do
  base <- directoryFd dir
  let flag = if follow == NoFollowLinks then 1 else 0
  allocaArray 13 $ \buffer -> do
    withPath name $ \cname ->
      retryPath "fstatat" name (c_fstatat base cname flag buffer)
    peekFileStat buffer

-- | @os.fstat(fd)@.
fdStat :: Fd -> IO FileStat
fdStat (Fd fd) =
  allocaArray 13 $ \buffer -> do
    throwErrnoIfMinus1Retry_ "fstat" (c_fstat fd buffer)
    peekFileStat buffer

fileType :: FileStat -> Int64
fileType stat = statMode stat .&. 0o170000

-- | @stat.S_ISREG@.
isRegularFile :: FileStat -> Bool
isRegularFile = (== 0o100000) . fileType

-- | @stat.S_ISDIR@.
isDirectory :: FileStat -> Bool
isDirectory = (== 0o040000) . fileType

-- | @stat.S_ISLNK@.
isSymbolicLink :: FileStat -> Bool
isSymbolicLink = (== 0o120000) . fileType

-- | @stat.S_IMODE@: the permission bits (including setuid, setgid, sticky).
permissionBits :: FileStat -> Int64
permissionBits stat = statMode stat .&. 0o7777

-- | @os.fchmod(fd, mode)@.
fchmod :: Fd -> FileMode -> IO ()
fchmod (Fd fd) mode = throwErrnoIfMinus1Retry_ "fchmod" (c_fchmod fd mode)
