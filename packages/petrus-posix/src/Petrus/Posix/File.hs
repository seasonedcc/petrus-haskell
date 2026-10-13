{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE InterruptibleFFI #-}
{-# LANGUAGE MultiWayIf #-}

-- | Durable writes: @fsync@, write loops, and the atomic-replace pattern
-- upstream uses for every state file it rewrites (the Gondolin registry,
-- agent-net thread projections, artifact and timeline indexes, the
-- simulation export helper):
--
-- 1. create a temporary file in the destination's directory with
--    @O_CREAT | O_EXCL@ and mode @0600@;
-- 2. write everything, flush, @os.fsync@;
-- 3. @os.replace(temporary, destination)@;
-- 4. optionally @fsync@ the directory (agent-net does, the others do not);
-- 5. on any failure, unlink the temporary file and leave the previous
--    destination untouched.
--
-- The temporary file's name is the only per-site difference; 'TempNaming'
-- reproduces each upstream spelling so leftovers look the same on disk.
module Petrus.Posix.File
  ( -- * fsync and writing
    fsyncFd
  , fsyncPath
  , writeAll
  , writeAllBuffer

    -- * Writing without a hand-off (files and character devices)
  , DirectFd
  , directFd
  , writeDirect

    -- * Atomic replace
  , AtomicWrite (..)
  , defaultAtomicWrite
  , atomicWriteFile
  , TempNaming (..)
  , mkstempNaming
  , prefixNaming
  , hiddenUuidNaming
  , uuidNaming
  , uuid4Hex

    -- * Directories
  , makeDirectories
  ) where

import Control.Exception (bracket, onException, throwIO, try)
import Control.Monad (unless, when)
import Data.Bits (clearBit, setBit)
import Data.ByteString (ByteString)
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.Word (Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.C.Error (throwErrnoIfMinus1Retry, throwErrnoIfMinus1Retry_)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Numeric (showHex)
import Petrus.Posix.At (Follow (..), isDirectory, statAt)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Error (catchIOError, isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Directory (createDirectory)
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, fdWriteBuf, openFd)
import System.Posix.Types (CSsize (..), Fd (..), FileMode)
import System.Posix.Files qualified
import System.Posix.Files (getFdStatus, isCharacterDevice, isRegularFile)
import System.Random (randomRIO)
import System.Random.Stateful (globalStdGen, uniformListM)

foreign import capi interruptible "unistd.h fsync" c_fsync :: CInt -> IO CInt

-- | @os.fsync(fd)@ (plain @fsync(2)@, as CPython uses; on macOS that is not
-- @F_FULLFSYNC@ in either implementation).
fsyncFd :: Fd -> IO ()
fsyncFd (Fd fd) = throwErrnoIfMinus1Retry_ "fsync" (c_fsync fd)

-- | Open a path read-only (a directory works too), @fsync@ it and close it:
-- @fd = os.open(path, os.O_RDONLY); os.fsync(fd); os.close(fd)@.
fsyncPath :: FilePath -> IO ()
fsyncPath path =
  bracket (openFd path ReadOnly defaultFileFlags {cloexec = True}) closeFd fsyncFd

-- | Write the whole buffer, looping over short writes (@EINTR@ is retried).
writeAll :: Fd -> ByteString -> IO ()
writeAll fd bytes = unsafeUseAsCStringLen bytes $ \(pointer, size) -> writeAllBuffer fd (castPtr pointer) size

-- | 'writeAll' from memory the caller holds, such as an erasable buffer
-- whose secret must not be copied into a 'ByteString'.
writeAllBuffer :: Fd -> Ptr Word8 -> Int -> IO ()
writeAllBuffer fd pointer remaining = when (remaining > 0) $ do
  written <- fromIntegral <$> fdWriteBuf fd pointer (fromIntegral remaining)
  writeAllBuffer fd (pointer `plusPtr` written) (remaining - written)

-- | A descriptor open on a regular file or a character device (a terminal,
-- @/dev/null@): one whose @write(2)@ completes without waiting for a
-- reader. Only 'directFd' makes one.
newtype DirectFd = DirectFd Fd

-- | The descriptor as a 'DirectFd', if @fstat@ says it is a regular file or
-- a character device; 'Nothing' for a pipe, a socket or anything else (and
-- when @fstat@ fails).
directFd :: Fd -> IO (Maybe DirectFd)
directFd fd = do
  status <- try @IOError (getFdStatus fd)
  pure $ case status of
    Right st | isRegularFile st || isCharacterDevice st -> Just (DirectFd fd)
    _ -> Nothing

-- | 'writeAll' through an @unsafe@ foreign call: the write runs on the
-- calling capability, where 'writeAll''s safe call releases the capability
-- and, when other threads are runnable, hands it to another OS thread and
-- back on every call. Short writes loop, @EINTR@ is retried, and a failure
-- raises the errno's 'IOError', as 'writeAll' does.
--
-- While the call runs, no other Haskell thread of the capability runs, as
-- Node's event loop waits for its synchronous @console.log@ to a file or a
-- terminal. That is why only a 'DirectFd' takes it: a regular file or a
-- character device does not wait for a reader (a terminal can still apply
-- flow control, which stalls Node's loop the same way), while a pipe or a
-- socket could block the capability indefinitely.
--
-- Measured where it is used, the viewer's @petrus-mcp@ logging every
-- bridge request to @/dev/null@ with 16 calls in flight: 'writeAll' served
-- 0.74x the calls this does, and fell behind Node's (bench/RESULTS.md,
-- "@writeDirect@"; petrus-viewer-server's bench/RESULTS.md, "Low-level code,
-- measured").
writeDirect :: DirectFd -> ByteString -> IO ()
writeDirect (DirectFd (Fd fd)) bytes = unsafeUseAsCStringLen bytes $ \(pointer, size) -> go (castPtr pointer) size
  where
    go :: Ptr Word8 -> Int -> IO ()
    go pointer remaining = when (remaining > 0) $ do
      written <- throwErrnoIfMinus1Retry "writeDirect" (c_write_unsafe fd pointer (fromIntegral remaining))
      go (pointer `plusPtr` fromIntegral written) (remaining - fromIntegral written)

foreign import capi unsafe "unistd.h write" c_write_unsafe :: CInt -> Ptr Word8 -> CSize -> IO CSsize

-- | How the temporary file is named, given the destination's file name.
newtype TempNaming = TempNaming (FilePath -> IO FilePath)

-- | Options for 'atomicWriteFile'.
data AtomicWrite = AtomicWrite
  { tempNaming :: TempNaming
  -- ^ The temporary file's name in the destination directory.
  , tempMode :: FileMode
  -- ^ Creation mode of the temporary (and so the final) file.
  , syncDirectory :: Bool
  -- ^ @fsync@ the directory after the rename.
  }

-- | @tempfile.mkstemp(dir=...)@ naming, mode @0600@, no directory fsync
-- (artifacts and timeline indexes).
defaultAtomicWrite :: AtomicWrite
defaultAtomicWrite = AtomicWrite {tempNaming = mkstempNaming, tempMode = 0o600, syncDirectory = False}

-- | @tempfile.mkstemp@'s names: @tmp@ followed by eight characters from
-- @abcdefghijklmnopqrstuvwxyz0123456789_@.
mkstempNaming :: TempNaming
mkstempNaming = prefixNaming (const "tmp")

-- | @tempfile.NamedTemporaryFile(prefix=prefix(name))@: the prefix followed by
-- eight random characters. The simulation export helper uses
-- @prefixNaming (\\name -> "." ++ name ++ ".")@.
prefixNaming :: (FilePath -> FilePath) -> TempNaming
prefixNaming prefix = TempNaming $ \name -> do
  suffix <- mapM (const randomCharacter) [1 :: Int .. 8]
  pure (prefix name ++ suffix)
  where
    alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_"
    randomCharacter = (alphabet !!) <$> randomRIO (0, length alphabet - 1)

-- | @f".{name}.{uuid4().hex}.tmp"@ (agent-net thread projections).
hiddenUuidNaming :: TempNaming
hiddenUuidNaming = TempNaming $ \name -> do
  hex <- uuid4Hex
  pure ("." ++ name ++ "." ++ hex ++ ".tmp")

-- | @f"{base}.{uuid4().hex}.tmp"@ for a fixed base (Gondolin writes
-- @registry.<hex>.tmp@ next to @registry.json@: @uuidNaming "registry"@).
uuidNaming :: FilePath -> TempNaming
uuidNaming base = TempNaming $ \_ -> do
  hex <- uuid4Hex
  pure (base ++ "." ++ hex ++ ".tmp")

-- | @uuid.uuid4().hex@: 32 lowercase hex digits with the version-4 and RFC
-- 4122 variant bits set.
uuid4Hex :: IO String
uuid4Hex = do
  bytes <- uniformListM 16 globalStdGen :: IO [Word8]
  let fixed = zipWith fix [0 :: Int ..] bytes
      fix 6 b = (b `clearBit` 7 `clearBit` 6 `clearBit` 5 `clearBit` 4) `setBit` 6
      fix 8 b = (b `clearBit` 6) `setBit` 7
      fix _ b = b
  pure (concatMap (\b -> let s = showHex b "" in if length s == 1 then '0' : s else s) fixed)

-- | Atomically replace @destination@ with @contents@ (see the module header).
-- The temporary file is created with
-- @O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC@; a name collision
-- draws a fresh name, as @mkstemp@ does. Any exception (including from the
-- directory fsync) unlinks the temporary file before propagating.
atomicWriteFile :: AtomicWrite -> FilePath -> ByteString -> IO ()
atomicWriteFile options destination contents = do
  (temporary, fd) <- create (100 :: Int)
  let cleanup = removeIfPresent temporary
  flip onException cleanup $ do
    (writeAll fd contents >> fsyncFd fd) `onException` closeFd fd
    closeFd fd
    renamePath temporary destination
    when (syncDirectory options) (fsyncPath directory)
  where
    directory = let d = takeDirectory destination in if null d then "." else d
    TempNaming naming = tempNaming options
    create attempts = do
      name <- naming (takeFileName destination)
      let temporary = directory </> name
      result <- try (openFd temporary WriteOnly defaultFileFlags {creat = Just (tempMode options), exclusive = True, nofollow = True, cloexec = True})
      case result of
        Right fd -> pure (temporary, fd)
        Left err
          | isAlreadyExistsError err && attempts > 1 -> create (attempts - 1)
          | otherwise -> throwIO err

renamePath :: FilePath -> FilePath -> IO ()
renamePath = System.Posix.Files.rename -- os.replace is rename(2)

removeIfPresent :: FilePath -> IO ()
removeIfPresent path =
  System.Posix.Files.removeLink path `catchIOError` \err ->
    unless (isDoesNotExistError err) (ioError err)

-- | @Path(path).mkdir(mode, parents=True, exist_ok=True)@: missing parents
-- are created with the default mode @0o777@ (minus the umask) and only the
-- leaf gets @mode@; an existing directory is accepted, an existing
-- non-directory raises @EEXIST@.
makeDirectories :: FilePath -> FileMode -> IO ()
makeDirectories path mode = do
  -- Fast path: an existing directory is accepted without attempting mkdir
  -- (the outcome Python reaches through mkdir's EEXIST and is_dir()).
  existing <- (isDirectory <$> statAt Nothing path FollowLinks) `catchIOError` \_ -> pure False
  unless existing (makeDirectoriesSlow path mode)

makeDirectoriesSlow :: FilePath -> FileMode -> IO ()
makeDirectoriesSlow path mode =
  createDirectory path mode `catchIOError` \err ->
    if
      | isDoesNotExistError err -> do
          let parent = takeDirectory path
          when (parent == path) (ioError err)
          makeDirectories parent 0o777
          createDirectory path mode `catchIOError` existing
      | otherwise -> existing err
  where
    existing err = do
      isDir <- (isDirectory <$> statAt Nothing path FollowLinks) `catchIOError` \_ -> pure False
      unless isDir (ioError err)
