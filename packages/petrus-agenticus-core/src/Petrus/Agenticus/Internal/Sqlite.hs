-- | The small SQLite surface the Agenticus SQLite ledgers need.
--
-- __Swap point.__ The repository's shared SQLite package (@petrus-sqlite@)
-- is not on @main@ yet, so this module wraps @direct-sqlite@ directly.  Every
-- Agenticus ledger goes through these few functions only; once
-- @petrus-sqlite@ lands, replace this module's implementation (not its
-- callers) with that package.
--
-- Failures surface the way CPython's @sqlite3@ module raises them: the
-- exception class @_pysqlite_seterror@ picks for the result code (for
-- example @OperationalError@ for @SQLITE_BUSY@) and @sqlite3_errmsg@ as the
-- message.
module Petrus.Agenticus.Internal.Sqlite
  ( Database
  , Statement
  , SqlValue
  , SQLData (..)
  , openDatabase
  , closeDatabase
  , execute_
  , prepareStatement
  , finalizeStatement
  , runStatement
  , queryRow
  , queryRows
  , changedRows
  , setBusyTimeout
  , inTransaction
  , pythonSqliteClass
  ) where

import Control.Exception (catch, finally, throwIO)
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite3 (Database, SQLData (..), SQLError (..), Statement, StepResult (..))
import Database.SQLite3 qualified as Sql
import Database.SQLite3.Direct qualified as Direct
import Petrus.Agenticus.Error

-- | A bound parameter or a column value.
type SqlValue = SQLData

-- | @sqlite3.connect(path, isolation_level=None)@: an autocommit connection;
-- transactions are always explicit.
openDatabase :: FilePath -> IO Database
openDatabase path = translated (Sql.open (T.pack path))

closeDatabase :: Database -> IO ()
closeDatabase database = translated (Sql.close database)

-- | Execute one or more statements without parameters or results.
execute_ :: Database -> Text -> IO ()
execute_ database sql = translated (Sql.exec database sql)

prepareStatement :: Database -> Text -> IO Statement
prepareStatement database sql = translated (Sql.prepare database sql)

finalizeStatement :: Statement -> IO ()
finalizeStatement = Sql.finalize

-- | Bind, step to completion, and reset a prepared statement.
runStatement :: Statement -> [SqlValue] -> IO ()
runStatement statement parameters =
  translated (Sql.bind statement parameters >> drain) `finally` Sql.reset statement
  where
    drain =
      Sql.step statement >>= \case
        Row -> drain
        Done -> pure ()

-- | Bind and fetch the first row, if any; the statement is reset afterwards.
queryRow :: Statement -> [SqlValue] -> IO (Maybe [SqlValue])
queryRow statement parameters =
  translated
    ( do
        Sql.bind statement parameters
        Sql.step statement >>= \case
          Row -> Just <$> Sql.columns statement
          Done -> pure Nothing
    )
    `finally` Sql.reset statement

-- | Bind and fetch every row; the statement is reset afterwards.
queryRows :: Statement -> [SqlValue] -> IO [[SqlValue]]
queryRows statement parameters =
  translated (Sql.bind statement parameters >> collect []) `finally` Sql.reset statement
  where
    collect rows =
      Sql.step statement >>= \case
        Row -> Sql.columns statement >>= \row -> collect (row : rows)
        Done -> pure (reverse rows)

-- | @cursor.rowcount@ of the last data-modifying statement.
changedRows :: Database -> IO Int
changedRows = Sql.changes

translated :: IO a -> IO a
translated action =
  action `catch` \(failure :: SQLError) ->
    throwIO (AgenticusError (OtherError (pythonSqliteClass failure.sqlError)) failure.sqlErrorDetails)

-- | The @sqlite3@ exception class CPython raises for a result code.
pythonSqliteClass :: Direct.Error -> Text
pythonSqliteClass = \case
  Direct.ErrorInternal -> "InternalError"
  Direct.ErrorNotFound -> "InternalError"
  Direct.ErrorNoMemory -> "MemoryError"
  Direct.ErrorCorrupt -> "DatabaseError"
  Direct.ErrorTooBig -> "DataError"
  Direct.ErrorConstraint -> "IntegrityError"
  Direct.ErrorMismatch -> "IntegrityError"
  Direct.ErrorMisuse -> "InterfaceError"
  Direct.ErrorRange -> "InterfaceError"
  Direct.ErrorNotADatabase -> "DatabaseError"
  Direct.ErrorFormat -> "DatabaseError"
  _ -> "OperationalError"

-- | @sqlite3.connect(..., timeout=seconds)@: wait this many milliseconds on
-- a locked database before failing.
setBusyTimeout :: Database -> Int -> IO ()
setBusyTimeout database milliseconds =
  execute_ database ("PRAGMA busy_timeout = " <> T.pack (show milliseconds))

-- | @Connection.in_transaction@.
inTransaction :: Database -> IO Bool
inTransaction database = not <$> Direct.getAutoCommit database
