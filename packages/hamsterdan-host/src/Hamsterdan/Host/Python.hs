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

    -- * @except Exception@
  , BaseException (..)
  , baseExceptionToException
  , baseExceptionFromException
  , isPythonException
  , catchPython
  , tryPython
  , exceptionClass

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

import Control.Exception
  ( ArithException
  , ArrayException
  , ErrorCall
  , Exception (..)
  , IOException
  , SomeAsyncException
  , SomeException (..)
  , catch
  , mask
  , onException
  , throwIO
  , try
  )
import Data.Maybe (isJust)
import Data.Typeable (cast, typeOf)
import Hamsterdan.GitHub.Models (GitHubBoundaryError (..))
import Hamsterdan.GitHub.Python (PythonFault (..))
import Petrus.Activity (ActivityError)
import Hamsterdan.Host.Agenticus (AgentCompositionError)
import Petrus.Agenticus.Error (AgenticusError (..), errorClassName)
import System.Exit (ExitCode)
import Control.Monad (unless, void)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Sqlite (Connection, SQLData (..))
import Hamsterdan.PyLiteral (literalEval)
import Hamsterdan.PyLiteral qualified as PyLit
import Hamsterdan.PyText (raisingDumps)
import Petrus.Impetus.Instance.FailureText (PythonArg (..), PythonException (..))
import Hamsterdan.Sqlite qualified as Sql
import Petrus.Json (EncodeOptions (..), Json, compact, defaultDumps, dumps, dumpsText)
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

-- ---------------------------------------------------------------------------
-- @except Exception@

-- | The root of the exceptions an @except Exception@ clause does not catch
-- (Python's @BaseException@-only classes, such as a test's simulated
-- process death). Give an exception this parent with
-- 'baseExceptionToException' and 'baseExceptionFromException'.
data BaseException = forall e. (Exception e) => BaseException e

instance Show BaseException where
  showsPrec p (BaseException e) = showsPrec p e

instance Exception BaseException where
  displayException (BaseException e) = displayException e

baseExceptionToException :: (Exception e) => e -> SomeException
baseExceptionToException = toException . BaseException

baseExceptionFromException :: (Exception e) => SomeException -> Maybe e
baseExceptionFromException x = do
  BaseException a <- fromException x
  cast a

-- | Whether @except Exception@ catches it: not an asynchronous exception
-- (a cancellation or interrupt), not a process exit, and not a
-- 'BaseException'.
isPythonException :: SomeException -> Bool
isPythonException e =
  not
    ( isJust (fromException @SomeAsyncException e)
        || isJust (fromException @ExitCode e)
        || isJust (fromException @BaseException e)
    )

-- | @try: ... except Exception as error: ...@.
catchPython :: IO a -> (SomeException -> IO a) -> IO a
catchPython action handler = action `catch` \e -> if isPythonException e then handler e else throwIO e

tryPython :: IO a -> IO (Either SomeException a)
tryPython action = (Right <$> action) `catchPython` (pure . Left)

-- | @type(error).__name__@: the reference class a caught exception stands
-- for.
exceptionClass :: SomeException -> Text
exceptionClass e
  | Just (PythonException name _) <- fromException e = name
  | Just (fault :: PythonFault) <- fromException e = fault.pythonClass
  | Just (_ :: GitHubBoundaryError) <- fromException e = "GitHubBoundaryError"
  | Just (_ :: ActivityError) <- fromException e = "ActivityError"
  | Just (_ :: AgentCompositionError) <- fromException e = "AgentCompositionError"
  | Just (failure :: AgenticusError) <- fromException e = errorClassName failure.errorClass
  | Just (_ :: IOException) <- fromException e = "OSError"
  | Just (_ :: ErrorCall) <- fromException e = "RuntimeError"
  | Just (_ :: ArithException) <- fromException e = "ArithmeticError"
  | Just (_ :: ArrayException) <- fromException e = "IndexError"
  | SomeException inner <- e = T.pack (show (typeOf inner))

sortedAscii :: EncodeOptions
sortedAscii = defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True}

-- | @json.dumps(value, sort_keys=True, separators=(",", ":"))@ (ASCII
-- escapes, NaN allowed).
dumpsSorted :: Json -> ByteString
dumpsSorted value = raisingDumps (dumps sortedAscii value)

dumpsSortedText :: Json -> Text
dumpsSortedText value = raisingDumps (dumpsText sortedAscii value)

-- | @json.dumps(value, sort_keys=True, separators=(",", ":"),
-- ensure_ascii=False, allow_nan=False)@.
dumpsCompactSorted :: Json -> ByteString
dumpsCompactSorted value = raisingDumps (dumps compact {sortKeys = True} value)

dumpsCompactSortedText :: Json -> Text
dumpsCompactSortedText value = raisingDumps (dumpsText compact {sortKeys = True} value)

-- | @json.dumps(value)@.
dumpsDefault :: Json -> Text
dumpsDefault value = raisingDumps (dumpsText defaultDumps value)

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
