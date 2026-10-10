-- | The host's Python-compatible building blocks: the built-in exception
-- types the reference raises (so their 'Data.Typeable' names, which reach
-- History through failure texts, are the reference's class names), its
-- JSON spellings, @hashlib.sha256@ hex digests, and SQLite transactions as
-- the reference runs them on @isolation_level=None@ connections.
module Hamsterdan.Host.Python
  ( -- * Exceptions
    RuntimeError (..)
  , ValueError (..)
  , TypeError (..)
  , LookupError (..)
  , raiseFailureText

    -- * JSON
  , dumpsSorted
  , dumpsSortedText
  , dumpsCompactSorted
  , dumpsCompactSortedText
  , dumpsDefault

    -- * Hashes
  , sha256Hex
  , sha256HexText

    -- * SQLite
  , immediate
  , rowValue

    -- * Files
  , mkdirPrivate
  ) where

import Control.Exception (Exception (..), IOException, SomeException, catch, mask, onException, throwIO, try)
import Control.Monad (unless, void)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.GitHub.Sqlite (Connection, SQLData (..))
import Hamsterdan.PyLiteral (literalEval)
import Hamsterdan.PyLiteral qualified as PyLit
import Petrus.Impetus.Instance.FailureText (PythonArg (..), PythonException (..))
import Hamsterdan.GitHub.Sqlite qualified as Sql
import Petrus.Json (EncodeOptions (..), Json, compact, defaultDumps, dumps, dumpsText, encodeErrorMessage)
import Petrus.Motus.Worker (LookupError (..), RuntimeError (..), ValueError (..))
import System.Directory (createDirectoryIfMissing, doesDirectoryExist)
import System.FilePath (takeDirectory)
import System.Posix.Directory qualified as PosixDir

-- | The reference's @TypeError@.
newtype TypeError = TypeError Text deriving stock (Eq, Show)

instance Exception TypeError where displayException (TypeError m) = T.unpack m

-- | Raise a recorded Python failure text (@Name('message')@, the
-- 'Petrus.Impetus.Instance.FailureText' spelling a pure fold returns) as
-- the exception the reference raises: the host's own type for the
-- built-in classes it raises, 'PythonException' for any other class.
raiseFailureText :: Text -> IO a
raiseFailureText text =
  let (name, rest) = T.breakOn "(" text
      message = case literalEval (T.dropEnd 1 (T.drop 1 rest)) of
        Right (PyLit.PyStr m) -> Just m
        _ -> Nothing
   in case (name, message) of
        ("TypeError", Just m) -> throwIO (TypeError m)
        ("ValueError", Just m) -> throwIO (ValueError m)
        ("RuntimeError", Just m) -> throwIO (RuntimeError m)
        (_, Just m) -> throwIO (PythonException name [PyStr m])
        _ -> throwIO (PythonException name [])

sortedAscii :: EncodeOptions
sortedAscii = defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True}

orFail :: Either a b -> (a -> String) -> b
orFail value render = either (error . render) id value

-- | @json.dumps(value, sort_keys=True, separators=(",", ":"))@ (ASCII
-- escapes, NaN allowed).
dumpsSorted :: Json -> ByteString
dumpsSorted value = orFail (dumps sortedAscii value) encodeErrorMessage

dumpsSortedText :: Json -> Text
dumpsSortedText value = orFail (dumpsText sortedAscii value) encodeErrorMessage

-- | @json.dumps(value, sort_keys=True, separators=(",", ":"),
-- ensure_ascii=False, allow_nan=False)@.
dumpsCompactSorted :: Json -> ByteString
dumpsCompactSorted value = orFail (dumps compact {sortKeys = True} value) encodeErrorMessage

dumpsCompactSortedText :: Json -> Text
dumpsCompactSortedText value = orFail (dumpsText compact {sortKeys = True} value) encodeErrorMessage

-- | @json.dumps(value)@.
dumpsDefault :: Json -> Text
dumpsDefault value = orFail (dumpsText defaultDumps value) encodeErrorMessage

-- | @hashlib.sha256(bytes).hexdigest()@.
sha256Hex :: ByteString -> Text
sha256Hex = TE.decodeUtf8 . Base16.encode . SHA256.hash

-- | @hashlib.sha256(text.encode()).hexdigest()@.
sha256HexText :: Text -> Text
sha256HexText = sha256Hex . TE.encodeUtf8

-- | @BEGIN IMMEDIATE@ ... @COMMIT@, rolling back on any exception, under
-- the connection lock.
immediate :: Connection -> IO a -> IO a
immediate db action = Sql.withLock db $ mask $ \restore -> do
  Sql.script db "BEGIN IMMEDIATE"
  result <- restore action `onException` void (try @SomeException (Sql.script db "ROLLBACK"))
  Sql.script db "COMMIT"
  pure result

-- | The first column of the first row.
rowValue :: [[SQLData]] -> Maybe SQLData
rowValue = \case
  (value : _) : _ -> Just value
  _ -> Nothing

-- | @path.mkdir(mode=0o700, parents=True, exist_ok=True)@: only the leaf
-- gets @0700@; created parents get the default mode, as @pathlib@ does.
mkdirPrivate :: FilePath -> IO ()
mkdirPrivate directory = do
  exists <- doesDirectoryExist directory
  unless exists $ do
    createDirectoryIfMissing True (takeDirectory directory)
    PosixDir.createDirectory directory 0o700 `catch` \(e :: IOException) -> do
      again <- doesDirectoryExist directory
      unless again (throwIO e)
