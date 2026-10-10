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
  , osError
  ) where

import Control.Exception (IOException, bracket, try)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Foreign.C.Error (Errno (..), eACCES, eISDIR, eNOENT, eNOTDIR, ePERM)
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..))
import GHC.IO.Exception (IOException (..))
import Numeric (showHex)
import Petrus.EngineFile.Validate (PyException (..))
import Petrus.Json.PythonText (pythonStrRepr)
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
readText :: Text -> IO (Either PyException ByteString)
readText path = do
  bytes <- readBytes path
  pure (bytes >>= decodeText)

-- | Open and read a whole file as @open(path, "rb")@ does, with its
-- exceptions.
readBytes :: Text -> IO (Either PyException ByteString)
readBytes path
  | T.any (== '\0') path = pure (Left (PyException "ValueError" "embedded null byte"))
  | otherwise = do
      opened <- try (openFd raw ReadOnly defaultFileFlags) :: IO (Either IOException Fd)
      case opened of
        Left e -> failure e
        Right fd -> do
          status <- try (getFdStatus fd) :: IO (Either IOException FileStatus)
          case status of
            Left e -> closeFd fd >> failure e
            Right st
              | isDirectory st -> closeFd fd >> (Left <$> osError path eISDIR)
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
writeBytes :: Text -> ByteString -> IO (Either PyException ())
writeBytes path bytes
  | T.any (== '\0') path = pure (Left (PyException "ValueError" "embedded null byte"))
  | otherwise = do
      opened <-
        try (openFd (TE.encodeUtf8 path) WriteOnly defaultFileFlags {trunc = True, creat = Just 0o666})
          :: IO (Either IOException Fd)
      case opened of
        Left e -> ioFailure path e
        Right fd -> do
          result <- try (bracket (PIO.fdToHandle fd) hClose (`BS.hPut` bytes)) :: IO (Either IOException ())
          either (ioFailure path) (pure . Right) result

ioFailure :: Text -> IOException -> IO (Either PyException a)
ioFailure path e = case ioe_errno e of
  Just n -> Left <$> osError path (Errno n)
  Nothing -> pure (Left (PyException "OSError" (T.pack (show e))))

-- | The @OSError@ subclass CPython raises for an errno, with its text.
osError :: Text -> Errno -> IO PyException
osError path errno@(Errno n) = do
  description <- c_strerror n >>= peekCString
  pure
    ( PyException
        (errnoClass errno)
        ("[Errno " <> T.pack (show n) <> "] " <> T.pack description <> ": " <> pythonStrRepr path)
    )

errnoClass :: Errno -> Text
errnoClass errno
  | errno == eNOENT = "FileNotFoundError"
  | errno == eISDIR = "IsADirectoryError"
  | errno == eNOTDIR = "NotADirectoryError"
  | errno == eACCES || errno == ePERM = "PermissionError"
  | otherwise = "OSError"

foreign import ccall unsafe "string.h strerror"
  c_strerror :: CInt -> IO CString

-- | Strict UTF-8 decoding with CPython's @UnicodeDecodeError@, then
-- universal newlines (@\\r\\n@ and @\\r@ become @\\n@).
decodeText :: ByteString -> Either PyException ByteString
decodeText bytes = case invalidUtf8 bytes of
  Nothing -> Right (translateNewlines bytes)
  Just (start, end, reason) ->
    Left
      ( PyException
          "UnicodeDecodeError"
          ( if end - start == 1
              then
                "'utf-8' codec can't decode byte 0x"
                  <> hex2 (BS.index bytes start)
                  <> " in position "
                  <> T.pack (show start)
                  <> ": "
                  <> reason
              else
                "'utf-8' codec can't decode bytes in position "
                  <> T.pack (show start)
                  <> "-"
                  <> T.pack (show (end - 1))
                  <> ": "
                  <> reason
          )
      )
  where
    hex2 w = T.pack (let s = showHex w "" in if length s < 2 then '0' : s else s)

-- | The first error CPython's UTF-8 decoder reports: start, end and reason.
invalidUtf8 :: ByteString -> Maybe (Int, Int, Text)
invalidUtf8 bytes = go 0
  where
    len = BS.length bytes
    at i = BS.index bytes i
    cont w = w .&. 0xC0 == 0x80
    go i
      | i >= len = Nothing
      | b < 0x80 = go (i + 1)
      | b < 0xC2 = invalidStart
      | b < 0xE0 =
          if remaining < 2
            then endOfData
            else if cont (at (i + 1)) then go (i + 2) else continuation 1
      | b < 0xF0 =
          let bad2 c2 = not (cont c2) || (if c2 < 0xA0 then b == 0xE0 else b == 0xED)
           in if remaining < 3
                then
                  if remaining < 2
                    then endOfData
                    else if bad2 (at (i + 1)) then continuation 1 else endOfData
                else
                  if bad2 (at (i + 1))
                    then continuation 1
                    else if not (cont (at (i + 2))) then continuation 2 else go (i + 3)
      | b < 0xF5 =
          let bad2 c2 = not (cont c2) || (if c2 < 0x90 then b == 0xF0 else b == 0xF4)
           in if remaining < 4
                then
                  if remaining < 2
                    then endOfData
                    else
                      if bad2 (at (i + 1))
                        then continuation 1
                        else
                          if remaining < 3
                            then endOfData
                            else if not (cont (at (i + 2))) then continuation 2 else endOfData
                else
                  if bad2 (at (i + 1))
                    then continuation 1
                    else
                      if not (cont (at (i + 2)))
                        then continuation 2
                        else if not (cont (at (i + 3))) then continuation 3 else go (i + 4)
      | otherwise = invalidStart
      where
        b = at i
        remaining = len - i
        invalidStart = Just (i, i + 1, "invalid start byte")
        endOfData = Just (i, len, "unexpected end of data")
        continuation k = Just (i, i + k, "invalid continuation byte")

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
