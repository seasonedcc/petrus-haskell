-- | Fixtures for the SQLite History store specs: the @reopen@ factory, raw
-- connections for the reference's @sqlite3.connect@ mutations, and the
-- pinned reference run as the other process.
module Petrus.HistoryStore.SqliteSupport
  ( withSqliteReopen
  , openTracked
  , rawExec
  , rawQuery
  , reference
  , referenceScript
  , withReference
  , exotic
  ) where

import Control.Exception (bracket, finally)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Text (Text)
import Petrus.Activity (Number (..))
import Petrus.HistoryStore.Sqlite (SqliteHistoryStore (..), openSqliteHistoryStore)
import Petrus.Impetus.History (Record (..), TokensInitialized (..))
import Petrus.Impetus.HistoryStore (HistoryStore)
import Petrus.Impetus.TestSupport (np, tokD)
import Petrus.Json (Json (..))
import Petrus.Sqlite.Connection (IsolationLevel (..), SQLData)
import Petrus.Sqlite.Connection qualified as Sql
import Petrus.TestSupport.Python (PythonProcess, python, withPython)
import System.Directory (makeAbsolute)
import System.FilePath ((</>))

-- | The reference's @reopen@ fixture for SQLite: each call loads a fresh
-- store over @history.sqlite3@ for instance @backend-contract@. Every store
-- opened is closed when the example ends.
withSqliteReopen :: FilePath -> (IO HistoryStore -> IO a) -> IO a
withSqliteReopen directory body = do
  opened <- newIORef []
  let reopen = (.history) <$> openTracked opened (directory </> "history.sqlite3") "backend-contract"
  body reopen `finally` (readIORef opened >>= mapM_ (.close))

-- | Open a store and remember it for closing.
openTracked :: IORef [SqliteHistoryStore] -> FilePath -> Text -> IO SqliteHistoryStore
openTracked opened path instanceId = do
  store <- openSqliteHistoryStore path instanceId
  modifyIORef' opened (store :)
  pure store

-- | @with sqlite3.connect(path) as connection: connection.execute(...)@:
-- statements on a plain connection, committed.
rawExec :: FilePath -> [Text] -> IO ()
rawExec path statements =
  bracket (Sql.connect path 5000 LegacyDeferred) Sql.close $ \connection -> do
    mapM_ (Sql.execute_ connection) statements
    Sql.commit connection

-- | Rows of a query on a plain connection.
rawQuery :: FilePath -> Text -> IO [[SQLData]]
rawQuery path statement = bracket (Sql.connect path 5000 LegacyDeferred) Sql.close $ \connection -> Sql.query connection statement []

-- | The interop driver, absolute (the suite runs from the package).
referenceScript :: IO FilePath
referenceScript = makeAbsolute ("test" </> "interop" </> "sqlite_interop.py")

-- | Run one driver subcommand under the pinned reference
-- (@python -I@, cwd = @upstream/petrus@) and answer its stdout; a non-zero
-- exit fails with both streams.
reference :: [String] -> IO ByteString
reference arguments = do
  script <- referenceScript
  python runner (script : arguments)

-- | Run a driver subcommand interactively (a line protocol over stdin and
-- stdout) for the duration of an action; the process is terminated after.
withReference :: [String] -> (PythonProcess -> IO a) -> IO a
withReference arguments action = do
  script <- referenceScript
  withPython runner (script : arguments) action

runner :: Text
runner = "import runpy, sys; sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name='__main__')"

-- | The driver's @EXOTIC@: one record whose token data exercises the payload
-- spelling (non-ASCII and astral text, escapes, floats in CPython's repr,
-- big integers, @-0.0@, nesting) and a float instant.
exotic :: Record
exotic =
  RTokensInitialized
    ( TokensInitialized
        (np "p")
        [ tokD
            "text"
            ( Object
                [ ("s", String "na\239ve \9731 \128512 \"q\" \\ / \t\n\0 \127")
                , ("f", Float 0.1)
                , ("big", Int (10 ^ (20 :: Int)))
                , ("neg", Float (-0.0))
                , ("exp", Float 1e16)
                , ("tiny", Float 5e-324)
                , ("list", Array [Int 1, Float 2.5, Null, Bool True, Object []])
                , ("\233", String "key")
                ]
            )
        ]
        (FloatNumber 0.5)
        []
        Nothing
    )
