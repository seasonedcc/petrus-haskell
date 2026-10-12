-- | What the reference does between a file name and the @str@ it validates:
-- @pathlib@ path spelling and joining, and @Path.read_text()@ (the locale
-- encoding, UTF-8 here, with strict errors and universal newlines), with
-- CPython's @OSError@ and @UnicodeDecodeError@ texts.
module Petrus.EngineFile.PyText
  ( -- * Paths
    PurePath
  , purePath
  , pathText
  , parentPath
  , joinPath

    -- * Reading
  , readText
  , readBytes
  , writeBytes
  , decodeText
  , translateNewlines
  ) where

import Control.Exception (IOException, bracket, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Foreign.C.Error (eISDIR)
import Petrus.Json.Python.Exception (PythonException (..), pythonError)
import Petrus.Json.Python.Decode (utf8DecodeError)
import Petrus.Json.Python.OsError (ioException, osError)
import System.Posix.ByteString (RawFilePath)
import System.Posix.Files.ByteString (FileStatus, getFdStatus, isDirectory)
import System.Posix.IO.ByteString (OpenFileFlags (..), OpenMode (ReadOnly, WriteOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Types (Fd)
import System.Posix.IO.ByteString qualified as PIO
import System.IO (hClose)

-- | A parsed @PurePosixPath@: its root (@""@, @"/"@ or @"//"@) and its
-- parts (no empty or @"."@ parts).
data PurePath = PurePath Text [Text]
  deriving stock (Eq, Show)

-- | @PurePosixPath(text)@.
purePath :: Text -> PurePath
purePath t = PurePath root [p | p <- T.splitOn "/" rest, not (T.null p), p /= "."]
  where
    (root, rest)
      | not ("/" `T.isPrefixOf` t) = ("", t)
      | "//" `T.isPrefixOf` t && not ("///" `T.isPrefixOf` t) = ("//", T.drop 2 t)
      | otherwise = ("/", T.drop 1 t)

-- | @str(path)@.
pathText :: PurePath -> Text
pathText (PurePath root parts)
  | T.null root && null parts = "."
  | otherwise = root <> T.intercalate "/" parts

-- | @path.parent@.
parentPath :: PurePath -> PurePath
parentPath (PurePath root parts)
  | null parts = PurePath root parts
  | otherwise = PurePath root (init parts)

-- | @path / text@.
joinPath :: PurePath -> Text -> PurePath
joinPath base t
  | "/" `T.isPrefixOf` t = purePath t
  | otherwise = case purePath t of
      PurePath _ parts -> let PurePath root baseParts = base in PurePath root (baseParts ++ parts)

-- | @Path(path).read_text()@: the decoded text, as UTF-8 bytes with
-- newlines translated.
readText :: Text -> IO (Either PythonException ByteString)
readText path = do
  bytes <- readBytes path
  pure (bytes >>= decodeText)

-- | Open and read a whole file as @open(path, "rb")@ does, with its
-- exceptions.
readBytes :: Text -> IO (Either PythonException ByteString)
readBytes path
  | T.any (== '\0') path = pure (Left (pythonError "ValueError" "embedded null byte"))
  | otherwise = do
      opened <- try (openFd raw ReadOnly defaultFileFlags) :: IO (Either IOException Fd)
      case opened of
        Left e -> failure e
        Right fd -> do
          status <- try (getFdStatus fd) :: IO (Either IOException FileStatus)
          case status of
            Left e -> closeFd fd >> failure e
            Right st
              | isDirectory st -> closeFd fd >> (Left <$> osError eISDIR path)
              | otherwise -> do
                  result <-
                    try (bracket (PIO.fdToHandle fd) hClose BS.hGetContents) :: IO (Either IOException ByteString)
                  either failure (pure . Right) result
  where
    raw :: RawFilePath
    raw = TE.encodeUtf8 path
    failure = ioFailure path

-- | Create or truncate a file and write bytes, as @open(path, "w")@ and
-- @write@ do, with their exceptions.
writeBytes :: Text -> ByteString -> IO (Either PythonException ())
writeBytes path bytes
  | T.any (== '\0') path = pure (Left (pythonError "ValueError" "embedded null byte"))
  | otherwise = do
      opened <-
        try (openFd (TE.encodeUtf8 path) WriteOnly defaultFileFlags {trunc = True, creat = Just 0o666})
          :: IO (Either IOException Fd)
      case opened of
        Left e -> ioFailure path e
        Right fd -> do
          result <- try (bracket (PIO.fdToHandle fd) hClose (`BS.hPut` bytes)) :: IO (Either IOException ())
          either (ioFailure path) (pure . Right) result

ioFailure :: Text -> IOException -> IO (Either PythonException a)
ioFailure path e = Left <$> ioException path e

-- | Strict UTF-8 decoding with CPython's @UnicodeDecodeError@, then
-- universal newlines (@\\r\\n@ and @\\r@ become @\\n@).
decodeText :: ByteString -> Either PythonException ByteString
decodeText bytes = case utf8DecodeError bytes of
  Nothing -> Right (translateNewlines bytes)
  Just message -> Left (pythonError "UnicodeDecodeError" message)

-- | Universal newlines on decoded UTF-8.
translateNewlines :: ByteString -> ByteString
translateNewlines bytes
  | BS.notElem cr bytes = bytes
  | otherwise = BS.concat (go bytes)
  where
    cr = 13 :: Word8
    go s = case BS.break (== cr) s of
      (before, rest)
        | BS.null rest -> [before]
        | otherwise ->
            let after = BS.drop (if BS.isPrefixOf "\r\n" rest then 2 else 1) rest
             in before : BC.singleton '\n' : go after
