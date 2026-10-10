{-# LANGUAGE CApiFFI #-}

-- | POSIX helpers this package needs before @petrus-posix@ lands on main.
--
-- __Seam:__ everything here (BSD @flock@, @fsync@, atomic replace, and the
-- CPython-compatible @os.path@ algorithms) belongs to the shared
-- @petrus-posix@ package that another track is building.  When it lands,
-- this module should become a thin re-export of it (or disappear) without
-- changing callers.  Nothing in this module knows about execution
-- territories.
module Petrus.Motus.Execution.Internal.Posix
  ( -- * Raw paths
    RawFilePath
  , toRawPath
  , fromRawPath
    -- * CPython @os.path@ algorithms (posixpath, 3.14)
  , RealpathMode (..)
  , OsError (..)
  , realpath
  , normpath
  , dirname
  , joinPath
  , isAbsolute
  , commonpathWithin
  , purePosixNormalize
    -- * Errors
  , ioErrno
  , isDoesNotExistErrno
    -- * File-system primitives
  , lstatMaybe
  , statMaybe
  , pathExists
  , pathLexists
  , flockExclusive
  , flockUnlock
  , fsyncFd
  , atomicWriteFile
  , mkdirP
  ) where

import Control.Exception (IOException, bracket, bracketOnError, try)
import Control.Monad (unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Unsafe qualified as BU
import Data.IORef
import Data.Map.Strict qualified as Map
import Foreign.C.Error (Errno (..), eNOENT, eNOTDIR, eLOOP, throwErrnoIfMinus1Retry_, getErrno)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (castPtr)
import GHC.Foreign qualified as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import GHC.IO.Exception (IOException (..))
import System.Posix.ByteString.FilePath (RawFilePath)
import System.Posix.Directory.ByteString (createDirectory, getWorkingDirectory)
import System.Posix.Files.ByteString
  ( FileStatus
  , getFileStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isSymbolicLink
  , readSymbolicLink
  , removeLink
  , rename
  )
import System.Posix.IO.ByteString
  ( OpenFileFlags (..)
  , OpenMode (..)
  , closeFd
  , defaultFileFlags
  , fdWriteBuf
  , openFd
  )
import System.Posix.Types (Fd (..))

-- | Encode a 'FilePath' with the file-system encoding (round-tripping
-- undecodable bytes exactly like Python's @os.fsencode@).
toRawPath :: FilePath -> IO RawFilePath
toRawPath path = do
  encoding <- getFileSystemEncoding
  GHC.withCStringLen encoding path B.packCStringLen

-- | Decode a raw path with the file-system encoding.
fromRawPath :: RawFilePath -> IO FilePath
fromRawPath raw = do
  encoding <- getFileSystemEncoding
  B.useAsCStringLen raw (GHC.peekCStringLen encoding)

-- | An @OSError@: errno plus the path CPython would attach.
data OsError = OsError {osErrno :: CInt, osPath :: RawFilePath}
  deriving stock (Eq, Show)

-- | Which errors @os.path.realpath@ tolerates.
data RealpathMode
  = -- | @strict=False@: every 'OSError' is ignored.
    NonStrict
  | -- | @strict=True@: nothing is ignored.
    Strict
  | -- | @strict=os.path.ALLOW_MISSING@: only @FileNotFoundError@ is ignored.
    AllowMissing
  deriving stock (Eq, Show)

ioErrno :: IOException -> CInt
ioErrno e = maybe 0 id (ioe_errno e)

isDoesNotExistErrno :: IOException -> Bool
isDoesNotExistErrno e = ioe_errno e == Just (let Errno n = eNOENT in n)

errnoValue :: Errno -> CInt
errnoValue (Errno n) = n

-- | Port of CPython 3.14 @posixpath.realpath@ (stack-based, with the
-- @seen@ map for loop detection).
realpath :: RealpathMode -> RawFilePath -> IO (Either OsError RawFilePath)
realpath mode filename = do
  start <-
    if "/" `B.isPrefixOf` filename
      then pure "/"
      else getWorkingDirectory
  seenRef <- newIORef Map.empty
  let strict = mode /= NonStrict
      ignored e = case mode of
        NonStrict -> True
        Strict -> False
        AllowMissing -> isDoesNotExistErrno e
      -- Stack entries: Left marker (symlink path whose resolution is done)
      -- or Right part.
      initial = map Right (BC.split '/' filename)
      loop :: RawFilePath -> [Either RawFilePath RawFilePath] -> Int -> IO (Either OsError RawFilePath)
      loop path rest partCount
        | partCount <= 0 = pure (Right path)
        | otherwise = case rest of
            [] -> pure (Right path)
            Left linkPath : more -> do
              modifyIORef' seenRef (Map.insert linkPath (Just path))
              loop path more partCount
            Right name : more -> do
              let remaining = partCount - 1
              if B.null name || name == "."
                then loop path more remaining
                else
                  if name == ".."
                    then loop (parentOf path) more remaining
                    else do
                      let newpath = if path == "/" then path <> name else path <> "/" <> name
                      statResult <- try (getSymbolicLinkStatus newpath)
                      case statResult of
                        Left e
                          | ignored e -> loop newpath more remaining
                          | otherwise -> pure (Left (OsError (ioErrno e) newpath))
                        Right status
                          | not (isSymbolicLink status) ->
                              if strict && remaining > 0 && not (isDirectory status)
                                then pure (Left (OsError (errnoValue eNOTDIR) newpath))
                                else loop newpath more remaining
                          | otherwise -> do
                              seen <- readIORef seenRef
                              case Map.lookup newpath seen of
                                Just (Just resolved) -> loop resolved more remaining
                                Just Nothing
                                  | strict -> pure (Left (OsError (errnoValue eLOOP) newpath))
                                  | otherwise -> loop newpath more remaining
                                Nothing -> do
                                  targetResult <- try (readSymbolicLink newpath)
                                  case targetResult of
                                    Left e
                                      | ignored e -> loop newpath more remaining
                                      | otherwise -> pure (Left (OsError (ioErrno e) newpath))
                                    Right target -> do
                                      modifyIORef' seenRef (Map.insert newpath Nothing)
                                      let parts = BC.split '/' target
                                          base = if "/" `B.isPrefixOf` target then "/" else path
                                      loop
                                        base
                                        (map Right parts ++ [Left newpath] ++ more)
                                        (remaining + length parts)
  loop start initial (length initial)
  where
    parentOf path = case BC.elemIndexEnd '/' path of
      Just 0 -> "/"
      Just i -> B.take i path
      Nothing -> "/"

-- | CPython @posixpath.normpath@.
normpath :: ByteString -> ByteString
normpath path
  | B.null path = "."
  | otherwise =
      let initialSlashes
            | "//" `B.isPrefixOf` path && not ("///" `B.isPrefixOf` path) = 2
            | "/" `B.isPrefixOf` path = 1
            | otherwise = 0 :: Int
          step acc comp
            | B.null comp || comp == "." = acc
            | comp /= ".." || (initialSlashes == 0 && null acc) || (take 1 acc == [".."]) = comp : acc
            | not (null acc) = drop 1 acc
            | otherwise = acc
          comps = reverse (foldl step [] (BC.split '/' path))
          joined = BC.replicate initialSlashes '/' <> B.intercalate "/" comps
       in if B.null joined then "." else joined

-- | CPython @posixpath.dirname@.
dirname :: ByteString -> ByteString
dirname p =
  let i = maybe 0 (+ 1) (BC.elemIndexEnd '/' p)
      headPart = B.take i p
   in if not (B.null headPart) && BC.any (/= '/') headPart
        then BC.dropWhileEnd (== '/') headPart
        else headPart

-- | CPython @posixpath.join@ for two components.
joinPath :: ByteString -> ByteString -> ByteString
joinPath a b
  | "/" `B.isPrefixOf` b = b
  | B.null a || "/" `B.isSuffixOf` a = a <> b
  | otherwise = a <> "/" <> b

isAbsolute :: ByteString -> Bool
isAbsolute = B.isPrefixOf "/"

-- | @os.path.commonpath([target, dest]) == dest@ for two absolute,
-- normalized paths (as 'realpath' returns them).
commonpathWithin :: ByteString -> ByteString -> Bool
commonpathWithin target dest =
  let parts = filter (\c -> not (B.null c) && c /= ".") . BC.split '/'
      destParts = parts dest
      targetParts = parts target
      common = map fst (takeWhile (uncurry (==)) (zip destParts targetParts))
      commonPath = "/" <> B.intercalate "/" common
   in commonPath == dest

-- | @PurePosixPath(name)@ normalization: returns whether the path is
-- absolute and its parts (empty and @.@ components dropped, @..@ kept).
-- The leading anchor follows pathlib: exactly two slashes stay @//@.
purePosixNormalize :: ByteString -> (ByteString, [ByteString])
purePosixNormalize name =
  let anchor
        | "//" `B.isPrefixOf` name && not ("///" `B.isPrefixOf` name) = "//"
        | "/" `B.isPrefixOf` name = "/"
        | otherwise = ""
      parts = filter (\c -> not (B.null c) && c /= ".") (BC.split '/' name)
   in (anchor, parts)

lstatMaybe :: RawFilePath -> IO (Maybe FileStatus)
lstatMaybe path = either (const Nothing) Just <$> (try (getSymbolicLinkStatus path) :: IO (Either IOException FileStatus))

statMaybe :: RawFilePath -> IO (Maybe FileStatus)
statMaybe path = either (const Nothing) Just <$> (try (getFileStatus path) :: IO (Either IOException FileStatus))

-- | @os.path.exists@ (follows symlinks, every error means absent).
pathExists :: RawFilePath -> IO Bool
pathExists path = maybe False (const True) <$> statMaybe path

-- | @os.path.lexists@.
pathLexists :: RawFilePath -> IO Bool
pathLexists path = maybe False (const True) <$> lstatMaybe path

foreign import capi safe "sys/file.h flock" c_flock :: CInt -> CInt -> IO CInt

foreign import capi safe "unistd.h fsync" c_fsync :: CInt -> IO CInt

foreign import capi "sys/file.h value LOCK_EX" lockEx :: CInt

foreign import capi "sys/file.h value LOCK_UN" lockUn :: CInt

-- | Blocking BSD @flock(LOCK_EX)@.
flockExclusive :: Fd -> IO ()
flockExclusive (Fd fd) = throwErrnoIfMinus1Retry_ "flock" (c_flock fd lockEx)

flockUnlock :: Fd -> IO ()
flockUnlock (Fd fd) = void (c_flock fd lockUn)

fsyncFd :: Fd -> IO ()
fsyncFd (Fd fd) = throwErrnoIfMinus1Retry_ "fsync" (c_fsync fd)

-- | Write @data@ to a unique temporary file beside @path@ (mode 0600,
-- @O_EXCL@), fsync it, and @rename@ it over @path@; the temporary file is
-- removed on failure.  The temporary name is produced by @tempName@.
atomicWriteFile :: IO RawFilePath -> RawFilePath -> ByteString -> IO ()
atomicWriteFile tempName path contents = do
  temporary <- tempName
  let flags = defaultFileFlags {exclusive = True, creat = Just 0o600, cloexec = True, trunc = True}
  bracketOnError (pure ()) (\_ -> void (try (removeLink temporary) :: IO (Either IOException ()))) $ \_ -> do
    bracket (openFd temporary WriteOnly flags) closeFd $ \fd -> do
      writeAll fd contents
      fsyncFd fd
    rename temporary path

writeAll :: Fd -> ByteString -> IO ()
writeAll fd bytes = unless (B.null bytes) $ do
  written <- BU.unsafeUseAsCStringLen bytes $ \(ptr, len) -> fdWriteBuf fd (castPtr ptr) (fromIntegral len)
  when (written == 0) $ do
    errno <- getErrno
    ioError (userError ("short write (errno " <> show (errnoValue errno) <> ")"))
  writeAll fd (B.drop (fromIntegral written) bytes)

-- | @Path.mkdir(parents=True, exist_ok=True)@ with mode 0777 (umask
-- applies), failing when an existing entry is not a directory.
mkdirP :: RawFilePath -> IO ()
mkdirP path = do
  existing <- statMaybe path
  case existing of
    Just status
      | isDirectory status -> pure ()
    _ -> do
      let parent = dirname (BC.dropWhileEnd (== '/') path)
      unless (B.null parent || parent == path || parent == "/") (mkdirP parent)
      result <- try (createDirectory path 0o777)
      case result of
        Right () -> pure ()
        Left (e :: IOException) -> do
          now <- statMaybe path
          case now of
            Just status | isDirectory status -> pure ()
            _ -> ioError e
