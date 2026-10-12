{-# LANGUAGE PatternSynonyms #-}

-- | The host's Python-compatible building blocks: the built-in exceptions
-- the reference raises (petrus-motus's @RuntimeError@, @ValueError@ and
-- @LookupError@, which its worker catches, and 'TypeError', a
-- 'PythonException'), its
-- JSON spellings, @hashlib.sha256@ hex digests, and SQLite transactions as
-- the reference runs them on @isolation_level=None@ connections.
module Hamsterdan.Host.Python
  ( -- * Exceptions
    RuntimeError (..)
  , ValueError (..)
  , pattern TypeError
  , isTypeError
  , LookupError (..)
  , raisePython

    -- * @except Exception@
  , BaseException (..)
  , baseExceptionToException
  , baseExceptionFromException
  , isPythonException
  , catchPython
  , tryPython

    -- * JSON
  , dumpsSorted
  , dumpsSortedText
  , dumpsCompactSorted
  , dumpsDefault

    -- * Hashes
  , sha256Hex
  , sha256HexText

    -- * SQLite
  , immediate

    -- * Files
  , mkdirPrivate
  ) where

import Control.Exception
  ( Exception (..)
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
import Data.Typeable (cast)
import System.Exit (ExitCode)
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Hamsterdan.Sqlite (Connection)
import Hamsterdan.Python.Exception (raisingDumps)
import Hamsterdan.Python.Hashlib (sha256Hex, sha256HexText)
import Petrus.Impetus.Instance.FailureText (PyObject (..), PythonException (..))
import Hamsterdan.Sqlite qualified as Sql
import Petrus.Json (EncodeOptions (..), Json, compact, defaultDumps, dumps, dumpsText)
import Petrus.Motus.Worker (LookupError (..), RuntimeError (..), ValueError (..))
import System.Directory (createDirectoryIfMissing, doesDirectoryExist)
import System.FilePath (takeDirectory)
import System.Posix.Directory qualified as PosixDir

-- | The reference's @TypeError@ raised with one message.
pattern TypeError :: Text -> PythonException
pattern TypeError message = PythonException "TypeError" [PyStr message]

-- | @except TypeError@.
isTypeError :: SomeException -> Bool
isTypeError e = case fromException e of
  Just (PythonException "TypeError" _) -> True
  _ -> False

-- | @raise error@: petrus-motus's type for a @ValueError@ or
-- @RuntimeError@ raised with one message (the worker, and the host's
-- catchers, match those types), the 'PythonException' itself for any
-- other. The motus types are petrus-motus's API, which its own catchers
-- and its other ports use, so the bridge stays at this one point.
raisePython :: PythonException -> IO a
raisePython failure = case failure of
  PythonException "ValueError" [PyStr m] -> throwIO (ValueError m)
  PythonException "RuntimeError" [PyStr m] -> throwIO (RuntimeError m)
  _ -> throwIO failure

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

-- | @json.dumps(value)@.
dumpsDefault :: Json -> Text
dumpsDefault value = raisingDumps (dumpsText defaultDumps value)

-- | @BEGIN IMMEDIATE@ ... @COMMIT@, rolling back on any exception, under
-- the connection lock.
immediate :: Connection -> IO a -> IO a
immediate db action = Sql.withLock db $ mask $ \restore -> do
  Sql.script db "BEGIN IMMEDIATE"
  result <- restore action `onException` void (try @SomeException (Sql.script db "ROLLBACK"))
  Sql.script db "COMMIT"
  pure result

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
