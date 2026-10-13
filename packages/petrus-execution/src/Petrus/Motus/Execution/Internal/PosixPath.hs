-- | CPython @os.path@ algorithms over raw (byte) paths, for the tarfile
-- extraction filter and the command working-directory checks.
--
-- File-system primitives (BSD @flock@, @fsync@, atomic replace, the
-- @*at@ family and @stat@) come from @petrus-posix@. What stays here is
-- what @petrus-posix@ does not offer: @os.path.realpath@ with its @strict@
-- modes (the tarfile @data@ filter calls it with @ALLOW_MISSING@ and
-- reports the failing errno and path), and @normpath@, @dirname@, @join@
-- and @commonpath@ on undecoded bytes, which the archive code compares
-- byte for byte.
module Petrus.Motus.Execution.Internal.PosixPath
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
    -- * Existence checks
  , lstatMaybe
  , statMaybe
  , pathExists
  , pathLexists
  ) where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Map.Strict qualified as Map
import Foreign.C.Error (Errno (..), eLOOP, eNOENT, eNOTDIR)
import Foreign.C.Types (CInt (..))
import GHC.Foreign qualified as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import GHC.IO.Exception (IOException (..))
import Petrus.Posix.Path qualified as Path
import System.Posix.ByteString.FilePath (RawFilePath)
import System.Posix.Directory.ByteString (getWorkingDirectory)
import System.Posix.Files.ByteString
  ( FileStatus
  , getFileStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isSymbolicLink
  , readSymbolicLink
  )


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

-- | CPython @posixpath.normpath@ on a byte path (petrus-posix's
-- 'Path.normpath', exact on the bytes since it inspects only @/@ and @.@).
normpath :: ByteString -> ByteString
normpath = BC.pack . Path.normpath . BC.unpack

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
