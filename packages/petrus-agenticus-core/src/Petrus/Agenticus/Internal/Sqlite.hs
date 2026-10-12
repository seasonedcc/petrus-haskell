-- | The SQLite surface the Agenticus ledgers use, over @petrus-sqlite@.
--
-- A 'Database' is a @petrus-sqlite@ 'Connection' (with its per-connection
-- prepared-statement cache, as CPython's @sqlite3@ keeps one). Statements
-- are named by their SQL text, as the reference passes them to
-- @connection.execute@.
--
-- Failures surface the way CPython's @sqlite3@ module raises them: an
-- 'AgenticusError' of the exception class @_pysqlite_seterror@ picks for the
-- result code (for example @OperationalError@ for @SQLITE_BUSY@), with
-- @sqlite3_errmsg@ as the message.
module Petrus.Agenticus.Internal.Sqlite
  ( Database
  , SqlValue
  , SQLData (..)
  , openDatabase
  , openDatabaseWith
  , closeDatabase
  , execute_
  , runSql
  , queryRow
  , queryRows
  , changedRows
  , inTransaction
  , pythonSqliteClass
  ) where

import Control.Exception (catch, throwIO)
import Control.Monad (void)
import Data.Text (Text)
import Database.SQLite3 qualified as Sql
import Petrus.Agenticus.Error
import Petrus.Sqlite.Connection (Connection, IsolationLevel (..), SQLData (..), SQLError (..), pythonSqliteClass)
import Petrus.Sqlite.Connection qualified as Connection

-- | An open ledger connection.
type Database = Connection

-- | A bound parameter or a column value.
type SqlValue = SQLData

-- | @sqlite3.connect(path, timeout=5, isolation_level=None)@, as every
-- Agenticus ledger connects: an autocommit connection (transactions are
-- explicit) with a five-second busy handler.
openDatabase :: FilePath -> IO Database
openDatabase = openDatabaseWith 5000

-- | @sqlite3.connect(path, timeout=milliseconds / 1000,
-- isolation_level=None)@.
openDatabaseWith :: Int -> FilePath -> IO Database
openDatabaseWith milliseconds path = translated (Connection.connect path milliseconds Autocommit)

closeDatabase :: Database -> IO ()
closeDatabase database = translated (Connection.close database)

-- | Execute one or more statements without parameters or results
-- (@executescript@-like; the statements are not cached).
execute_ :: Database -> Text -> IO ()
execute_ database sql = translated (Sql.exec (Connection.connectionDatabase database) sql)

-- | Execute one statement with parameters, to completion.
runSql :: Database -> Text -> [SqlValue] -> IO ()
runSql database sql parameters = translated (void (Connection.execute database sql parameters))

-- | Run a statement and return its first row (@fetchone()@).
queryRow :: Database -> Text -> [SqlValue] -> IO (Maybe [SqlValue])
queryRow database sql parameters = translated (Connection.queryFirst database sql parameters)

-- | Run a statement and return every row (@fetchall()@).
queryRows :: Database -> Text -> [SqlValue] -> IO [[SqlValue]]
queryRows database sql parameters = translated (Connection.query database sql parameters)

-- | @cursor.rowcount@ of the last data-modifying statement.
changedRows :: Database -> IO Int
changedRows = Connection.changes

-- | @Connection.in_transaction@ (@not sqlite3_get_autocommit@).
inTransaction :: Database -> IO Bool
inTransaction = Connection.inTransaction

translated :: IO a -> IO a
translated action =
  action `catch` \(failure :: SQLError) ->
    throwIO (AgenticusError (OtherError (pythonSqliteClass failure.sqlError)) failure.sqlErrorDetails)
