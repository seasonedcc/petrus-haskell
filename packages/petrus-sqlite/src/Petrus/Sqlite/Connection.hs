{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnliftedFFITypes #-}

-- | SQLite connections opened exactly as upstream opens them.
--
-- Every upstream SQLite store calls @sqlite3.connect(path, timeout=…,
-- isolation_level=…)@ and then runs a fixed, site-specific sequence of
-- PRAGMAs. Those settings are shared state of the database file (WAL is
-- persistent; @synchronous@, @busy_timeout@ and @foreign_keys@ shape how a
-- Haskell writer and a Python writer interleave), so a 'Profile' records the
-- exact statement texts and order of each site:
--
-- * 'historyStoreProfile': the SQLite History store
--   (@petrus.impetus.history_store.sqlite@).
-- * 'localDispatchProfile': Local Dispatch (@petrus.motus.dispatch.local@,
--   @_connect@). Upstream opens a new connection per operation; the port
--   keeps a few of them open between operations ("Petrus.Sqlite.Pool").
-- * 'ledgerProfile' / 'secureLedgerProfile': the agenticus ledgers
--   (connection storage, Pi recovery and A2 host; attachment retention adds
--   @secure_delete@), which use a rollback journal.
-- * 'codexServiceProfile': the Codex Gondolin service ledger (default
--   isolation level, so DML statements open an implicit transaction).
--
-- Writes use 'withImmediateTransaction' (@BEGIN IMMEDIATE@ … @COMMIT@, or
-- @ROLLBACK@ when the action throws), as upstream does.
--
-- A 'Connection' is not safe for concurrent use from several threads; like
-- upstream's @check_same_thread=False@ connections guarded by a lock, callers
-- serialize access.
module Petrus.Sqlite.Connection
  ( -- * Profiles
    Profile (..)
  , Setup (..)
  , WalRetry (..)
  , WalMatch (..)
  , IsolationLevel (..)
  , historyStoreProfile
  , localDispatchProfile
  , ledgerProfile
  , secureLedgerProfile
  , codexServiceProfile

    -- * Connections
  , Connection
  , connectionPath
  , connectionDatabase
  , open
  , connect
  , configure
  , close
  , withConnection

    -- * Statements
  , execute
  , execute_
  , executeWith
  , Statement
  , bindParam
  , bindTextParam
  , bindUtf8Param
  , bindInt64Param
  , bindNullParam
  , executeMany
  , query
  , queryFirst
  , changes
  , lastInsertRowId

    -- * Transactions
  , withImmediateTransaction
  , withLegacyTransaction
  , begin
  , commit
  , rollback
  , inTransaction

    -- * Errors
  , WalRefused (..)
  , historyWalRefusal
  , localDispatchWalRefusal
  , isLockedError
  , pythonSqliteClass
  , SQLError (..)
  , Error (..)
  , SQLData (..)
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, SomeException, bracket, catch, mask, onException, throwIO, try)
import Control.Monad (forM_, void, when, zipWithM_)
import Data.ByteString (ByteString)
import Data.Char (isSpace)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Array qualified as TA
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Text.Internal qualified as TI
import Database.SQLite3
  ( Database
  , Error (..)
  , SQLData (..)
  , SQLError (..)
  , SQLOpenFlag (..)
  , SQLVFS (..)
  , Statement
  , StepResult (..)
  )
import Database.SQLite3 qualified as S
import Database.SQLite3.Bindings.Types (CDatabase, CError (..), CStatement, decodeError)
import Database.SQLite3.Direct qualified as Direct
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr)
import GHC.Exts (ByteArray#)
import GHC.Clock (getMonotonicTime)
import Petrus.Posix.Path (purePath)
import Petrus.Sqlite.PythonRepr (pythonReprSqlData)

-- | How @PRAGMA journal_mode = WAL@ is retried when it reports the database
-- as locked (the statement can bypass the busy handler while another first
-- opener is switching the file to WAL).
data WalRetry
  = -- | Fail on the first error (the Codex service).
    NoRetry
  | -- | Retry every @interval@ seconds while the error message contains
    -- @locked@ and the window (seconds, monotonic) has not elapsed: upstream
    -- uses @RetryLocked 5 0.01@.
    RetryLocked Double Double
  deriving stock (Eq, Show)

-- | One step of a profile, run in order after the connection opens.
data Setup
  = -- | A statement executed verbatim (its result rows are ignored).
    Pragma Text
  | -- | A @journal_mode = WAL@ statement whose reported mode must be @wal@.
    RequireWal Text WalRetry WalMatch
  deriving stock (Eq, Show)

-- | How a 'RequireWal' step compares the reported journal mode with @wal@.
data WalMatch
  = -- | @str(mode).lower() == "wal"@.
    CaseInsensitive
  | -- | @fetchone() == ("wal",)@, as the Codex service compares.
    ExactWal
  deriving stock (Eq, Show)

-- | Python's @isolation_level@: 'Autocommit' is @None@ (statements run as
-- written, transactions are explicit); 'LegacyDeferred' is the default
-- @""@, under which @INSERT@/@UPDATE@/@DELETE@/@REPLACE@ open an implicit
-- @BEGIN@ when no transaction is active.
data IsolationLevel = Autocommit | LegacyDeferred
  deriving stock (Eq, Show)

-- | A connection profile: @sqlite3.connect(path, timeout=…,
-- isolation_level=…)@ followed by the setup statements.
data Profile = Profile
  { busyTimeoutMs :: Int
  -- ^ @timeout=@ of @sqlite3.connect@, in milliseconds (the busy handler).
  , isolationLevel :: IsolationLevel
  , setup :: [Setup]
  }
  deriving stock (Eq, Show)

locked :: WalRetry
locked = RetryLocked 5 0.01

-- | The SQLite History store: @timeout=5.0, isolation_level=None@, then
-- @PRAGMA busy_timeout = 5000@, @PRAGMA foreign_keys = ON@,
-- @PRAGMA synchronous = FULL@, @PRAGMA journal_mode = WAL@ (retried).
historyStoreProfile :: Profile
historyStoreProfile =
  Profile
    { busyTimeoutMs = 5000
    , isolationLevel = Autocommit
    , setup =
        [ Pragma "PRAGMA busy_timeout = 5000"
        , Pragma "PRAGMA foreign_keys = ON"
        , Pragma "PRAGMA synchronous = FULL"
        , RequireWal "PRAGMA journal_mode = WAL" locked CaseInsensitive
        ]
    }

-- | Local Dispatch (@_connect@): the same settings spelled without spaces.
localDispatchProfile :: Profile
localDispatchProfile =
  Profile
    { busyTimeoutMs = 5000
    , isolationLevel = Autocommit
    , setup =
        [ Pragma "PRAGMA busy_timeout=5000"
        , Pragma "PRAGMA foreign_keys=ON"
        , Pragma "PRAGMA synchronous=FULL"
        , RequireWal "PRAGMA journal_mode=WAL" locked CaseInsensitive
        ]
    }

-- | The agenticus ledgers (connection storage, Pi recovery, Pi A2 host):
-- @timeout=5, isolation_level=None@, @PRAGMA journal_mode = DELETE@,
-- @PRAGMA synchronous = FULL@.
ledgerProfile :: Profile
ledgerProfile =
  Profile
    { busyTimeoutMs = 5000
    , isolationLevel = Autocommit
    , setup = [Pragma "PRAGMA journal_mode = DELETE", Pragma "PRAGMA synchronous = FULL"]
    }

-- | Attachment retention (territory custody): 'ledgerProfile' plus
-- @PRAGMA secure_delete = ON@.
secureLedgerProfile :: Profile
secureLedgerProfile = ledgerProfile {setup = setup ledgerProfile ++ [Pragma "PRAGMA secure_delete = ON"]}

-- | The Codex Gondolin service ledger: @timeout=2@, default isolation level,
-- @PRAGMA journal_mode=WAL@ (must report exactly @wal@, no retry), then
-- @PRAGMA synchronous=FULL@.
codexServiceProfile :: Profile
codexServiceProfile =
  Profile
    { busyTimeoutMs = 2000
    , isolationLevel = LegacyDeferred
    , setup = [RequireWal "PRAGMA journal_mode=WAL" NoRetry ExactWal, Pragma "PRAGMA synchronous=FULL"]
    }

-- | An open connection with its prepared-statement cache (CPython's
-- @sqlite3@ caches 128 statements per connection; so does this).
data Connection = Connection
  { connectionPath :: FilePath
  -- ^ The path as given to 'open'.
  , connectionDatabase :: Database
  -- ^ The underlying @direct-sqlite@ handle, for anything not wrapped here.
  , connectionIsolation :: IsolationLevel
  , statementCache :: IORef (Map.Map Text Statement)
  }

-- | The journal mode a 'RequireWal' step reported instead of @wal@.
data WalRefused = WalRefused
  { refusedPath :: FilePath
  , reportedMode :: Maybe SQLData
  }
  deriving stock (Eq, Show)

instance Exception WalRefused

-- | The History store's message:
-- @f"{self.path}: SQLite refused WAL journal mode (reported {mode!r})"@.
historyWalRefusal :: WalRefused -> String
historyWalRefusal refusal =
  purePath (refusedPath refusal) ++ ": SQLite refused WAL journal mode (reported " ++ maybe "None" pythonReprSqlData (reportedMode refusal) ++ ")"

-- | Local Dispatch's message: @f"{path}: SQLite refused WAL mode"@.
localDispatchWalRefusal :: WalRefused -> String
localDispatchWalRefusal refusal = purePath (refusedPath refusal) ++ ": SQLite refused WAL mode"

-- | Whether an error is the one upstream retries: its message contains
-- @locked@ (case-insensitively), e.g. @database is locked@.
isLockedError :: SQLError -> Bool
isLockedError err = "locked" `T.isInfixOf` T.toLower (sqlErrorDetails err)

-- | The @sqlite3@ exception class CPython raises for a primary result code
-- (@get_exception_class@ in @Modules/_sqlite/util.c@): its
-- @type(error).__name__@, whose module is @sqlite3@ except for
-- @MemoryError@ (a built-in).
pythonSqliteClass :: Error -> Text
pythonSqliteClass = \case
  ErrorInternal -> "InternalError"
  ErrorNotFound -> "InternalError"
  ErrorNoMemory -> "MemoryError"
  ErrorError -> "OperationalError"
  ErrorPermission -> "OperationalError"
  ErrorAbort -> "OperationalError"
  ErrorBusy -> "OperationalError"
  ErrorLocked -> "OperationalError"
  ErrorReadOnly -> "OperationalError"
  ErrorInterrupt -> "OperationalError"
  ErrorIO -> "OperationalError"
  ErrorFull -> "OperationalError"
  ErrorCan'tOpen -> "OperationalError"
  ErrorProtocol -> "OperationalError"
  ErrorEmpty -> "OperationalError"
  ErrorSchema -> "OperationalError"
  ErrorCorrupt -> "DatabaseError"
  ErrorTooBig -> "DataError"
  ErrorConstraint -> "IntegrityError"
  ErrorMismatch -> "IntegrityError"
  ErrorMisuse -> "InterfaceError"
  ErrorRange -> "InterfaceError"
  _ -> "DatabaseError"

-- | @sqlite3.connect(path, timeout=…)@ only: open (creating if needed) and
-- set the busy timeout, without the profile's setup statements.
connect :: FilePath -> Int -> IsolationLevel -> IO Connection
connect path timeoutMs isolation = do
  -- Python passes the path literally (uri=False). The bundled SQLite is
  -- built with URI filenames enabled, so keep a "file:" path literal.
  let name = if "file:" `isPrefixOf` path then "./" ++ path else path
  database <- S.open2 (T.pack name) [SQLOpenReadWrite, SQLOpenCreate] SQLVFSDefault
  cache <- newIORef Map.empty
  let connection = Connection path database isolation cache
  setBusyTimeout database timeoutMs `onException` S.close database
  pure connection

foreign import ccall unsafe "sqlite3_busy_timeout"
  c_sqlite3_busy_timeout :: Ptr CDatabase -> CInt -> IO CInt

-- | @sqlite3_busy_timeout@, as @sqlite3.connect(timeout=…)@ sets it: the
-- C call, not a @PRAGMA busy_timeout@ statement (the same setting, without
-- preparing and running a statement on every connect).
setBusyTimeout :: Database -> Int -> IO ()
setBusyTimeout database@(Direct.Database handle) timeoutMs = do
  code <- c_sqlite3_busy_timeout handle (fromIntegral timeoutMs)
  when (code /= 0) $ do
    Direct.Utf8 details <- Direct.errmsg database
    throwIO SQLError {sqlError = decodeError (CError code), sqlErrorDetails = TE.decodeUtf8With lenientDecode details, sqlErrorContext = "sqlite3_busy_timeout"}

-- | Open a connection and run the profile's setup statements in order. On
-- any failure the connection is closed and the error rethrown (a refused
-- WAL switch raises 'WalRefused').
open :: Profile -> FilePath -> IO Connection
open profile path = mask $ \restore -> do
  connection <- connect path (busyTimeoutMs profile) (isolationLevel profile)
  restore (mapM_ (runSetup connection) (setup profile)) `onException` close connection
  pure connection

-- | Run a profile's setup statements on an already connected database, in
-- order (a refused WAL switch raises 'WalRefused'). For openers that must
-- inspect the file between @sqlite3.connect@ and their PRAGMAs, as the
-- History store's preflight does; 'open' is 'connect' followed by this.
configure :: Connection -> Profile -> IO ()
configure connection profile = mapM_ (runSetup connection) (setup profile)

runSetup :: Connection -> Setup -> IO ()
runSetup connection = \case
  Pragma statement -> void (query connection statement [])
  RequireWal statement retry match -> do
    start <- getMonotonicTime
    mode <- walLoop start statement retry
    let ok = case mode of
          Just (SQLText text) -> case match of
            ExactWal -> text == "wal"
            CaseInsensitive -> T.toLower text == "wal"
          -- str(mode).lower() of a non-text value is never "wal".
          _ -> False
    when (not ok) (throwIO (WalRefused (connectionPath connection) mode))
  where
    walLoop start statement retry = do
      result <- try (queryFirst connection statement [])
      case result of
        Right row -> pure (row >>= headMaybe)
        Left err -> case retry of
          RetryLocked window interval | isLockedError err -> do
            now <- getMonotonicTime
            if now >= start + window
              then throwIO err
              else threadDelay (round (interval * 1000000)) >> walLoop start statement retry
          _ -> throwIO err
    headMaybe = \case
      value : _ -> Just value
      [] -> Nothing

-- | Finalize cached statements and close the connection (an open
-- transaction is rolled back by SQLite, as when Python closes).
close :: Connection -> IO ()
close connection = do
  cached <- atomicModifyIORef' (statementCache connection) (Map.empty,)
  forM_ cached $ \statement -> S.finalize statement `catch` \(_ :: SQLError) -> pure ()
  S.close (connectionDatabase connection)

-- | 'open', run the action, 'close'.
withConnection :: Profile -> FilePath -> (Connection -> IO a) -> IO a
withConnection profile path = bracket (open profile path) close

cacheLimit :: Int
cacheLimit = 128

-- Run an action with a prepared statement from the cache, reset and
-- unbound afterwards.
withPrepared :: Connection -> Text -> (Statement -> IO a) -> IO a
withPrepared connection sql action = do
  cache <- readIORef (statementCache connection)
  statement <- case Map.lookup sql cache of
    Just statement -> pure statement
    Nothing -> do
      statement <- S.prepare (connectionDatabase connection) sql
      evicted <-
        if Map.size cache >= cacheLimit
          then writeIORef (statementCache connection) (Map.singleton sql statement) >> pure (Map.elems cache)
          else writeIORef (statementCache connection) (Map.insert sql statement cache) >> pure []
      mapM_ S.finalize evicted
      pure statement
  let cleanup = (S.reset statement `catch` \(_ :: SQLError) -> pure ()) >> S.clearBindings statement
  (action statement <* cleanup) `onException` cleanup

-- CPython (3.6+, legacy transaction control) begins implicitly before
-- INSERT/UPDATE/DELETE/REPLACE when not in a transaction.
implicitBegin :: Connection -> Text -> IO ()
implicitBegin connection sql =
  when (connectionIsolation connection == LegacyDeferred && isDml sql) $ do
    autocommit <- Direct.getAutoCommit (connectionDatabase connection)
    when autocommit (control connection "BEGIN ")

isDml :: Text -> Bool
isDml sql = any (`T.isPrefixOf` T.toLower (T.take 7 (skipNoise sql))) ["insert", "update", "delete", "replace"]
  where
    skipNoise text
      | Just rest <- T.stripPrefix "--" stripped = skipNoise (T.drop 1 (T.dropWhile (/= '\n') rest))
      | Just rest <- T.stripPrefix "/*" stripped = skipNoise (T.drop 2 (snd (T.breakOn "*/" rest)))
      | otherwise = stripped
      where
        stripped = T.dropWhile isSpace text

-- | Execute one statement with positional parameters and return
-- @sqlite3_changes()@ (Python's @cursor.rowcount@ for DML statements).
execute :: Connection -> Text -> [SQLData] -> IO Int
execute connection sql params = executeWith connection sql (`bindAll` params)

-- | 'execute' with the parameters bound by an action ('bindParam',
-- 'bindTextParam', 'bindUtf8Param', 'bindInt64Param', 'bindNullParam')
-- instead of from a list, for a statement run once per row of a batch. The
-- action must bind every parameter of the statement (one left unbound is
-- @NULL@).
executeWith :: Connection -> Text -> (Statement -> IO ()) -> IO Int
executeWith connection sql binder = do
  implicitBegin connection sql
  withPrepared connection sql $ \statement -> do
    binder statement
    drain statement
  S.changes (connectionDatabase connection)
  where
    drain statement =
      S.step statement >>= \case
        Row -> drain statement
        Done -> pure ()

-- | Bind every parameter from a list, refusing a list of the wrong length
-- (direct-sqlite's 'S.bind', with text bound by 'bindTextParam').
bindAll :: Statement -> [SQLData] -> IO ()
bindAll statement params = do
  Direct.ParamIndex count <- Direct.bindParameterCount statement
  when (count /= length params) $
    fail
      ( "mismatched parameter count for bind.  Prepared statement needs "
          ++ show count
          ++ ", "
          ++ show (length params)
          ++ " given"
      )
  zipWithM_ (bindParam statement) [1 ..] params

-- | Bind one parameter (1-based), as direct-sqlite's 'S.bindSQLData' does,
-- text by 'bindTextParam'.
bindParam :: Statement -> Int -> SQLData -> IO ()
bindParam statement index = \case
  SQLText text -> bindTextParam statement index text
  datum -> S.bindSQLData statement (fromIntegral index) datum

foreign import ccall unsafe "petrus_sqlite_bind_text"
  c_petrus_sqlite_bind_text :: Ptr CStatement -> CInt -> ByteArray# -> Int -> CInt -> IO CInt

-- | Bind a text parameter (1-based) from the 'Text''s own UTF-8 bytes,
-- which SQLite copies (as CPython binds a @str@), without the intermediate
-- UTF-8 copy of direct-sqlite's 'S.bindText'.
bindTextParam :: Statement -> Int -> Text -> IO ()
bindTextParam statement@(Direct.Statement handle) index (TI.Text (TA.ByteArray array) offset size) =
  c_petrus_sqlite_bind_text handle (fromIntegral index) array offset (fromIntegral size) >>= bound statement "bind text"

-- | Bind a text parameter (1-based) from bytes that are already UTF-8.
bindUtf8Param :: Statement -> Int -> ByteString -> IO ()
bindUtf8Param statement index bytes =
  Direct.bindText statement (fromIntegral index) (Direct.Utf8 bytes) >>= either (failed statement "bind text") pure

-- | Bind an integer parameter (1-based).
bindInt64Param :: Statement -> Int -> Int64 -> IO ()
bindInt64Param statement index value = S.bindInt64 statement (fromIntegral index) value

-- | Bind @NULL@ to a parameter (1-based).
bindNullParam :: Statement -> Int -> IO ()
bindNullParam statement index = S.bindNull statement (fromIntegral index)

bound :: Statement -> Text -> CInt -> IO ()
bound statement context = \case
  0 -> pure ()
  code -> failed statement context (decodeError (CError code))

-- | direct-sqlite's error for a failed call on a statement.
failed :: Statement -> Text -> Error -> IO a
failed statement context err = do
  database <- Direct.getStatementDatabase statement
  Direct.Utf8 details <- Direct.errmsg database
  throwIO SQLError {sqlError = err, sqlErrorDetails = TE.decodeUtf8With lenientDecode details, sqlErrorContext = context}

-- | Execute one statement without parameters, ignoring rows.
execute_ :: Connection -> Text -> IO ()
execute_ connection sql = void (execute connection sql [])

-- | @executemany@: run the statement once per parameter list, returning the
-- total number of changed rows.
executeMany :: Connection -> Text -> [[SQLData]] -> IO Int
executeMany connection sql rows = sum <$> mapM (execute connection sql) rows

-- | Run a statement and collect every row.
query :: Connection -> Text -> [SQLData] -> IO [[SQLData]]
query connection sql params = do
  implicitBegin connection sql
  withPrepared connection sql $ \statement -> do
    bindAll statement params
    -- The first step may wait for locks (the busy handler sleeps), so it is
    -- a safe call. Later steps of the same statement already hold the read
    -- snapshot and never wait, so they use the cheaper unsafe call.
    let loop acc =
          S.stepNoCB statement >>= \case
            Row -> S.columns statement >>= \row -> loop (row : acc)
            Done -> pure (reverse acc)
    S.step statement >>= \case
      Row -> S.columns statement >>= \row -> loop [row]
      Done -> pure []

-- | Run a statement and return its first row (@fetchone()@).
queryFirst :: Connection -> Text -> [SQLData] -> IO (Maybe [SQLData])
queryFirst connection sql params = do
  implicitBegin connection sql
  withPrepared connection sql $ \statement -> do
    bindAll statement params
    S.step statement >>= \case
      Row -> Just <$> S.columns statement
      Done -> pure Nothing

-- | @sqlite3_changes()@ for the last statement.
changes :: Connection -> IO Int
changes = S.changes . connectionDatabase

-- | @cursor.lastrowid@.
lastInsertRowId :: Connection -> IO Int64
lastInsertRowId = S.lastInsertRowId . connectionDatabase

-- | Whether a transaction is open (@connection.in_transaction@).
inTransaction :: Connection -> IO Bool
inTransaction connection = not <$> Direct.getAutoCommit (connectionDatabase connection)

-- Run a transaction-control statement (@BEGIN …@, @COMMIT@, @ROLLBACK@)
-- through the prepared-statement cache, as CPython runs
-- @connection.execute("BEGIN IMMEDIATE")@. Preparing it on every
-- transaction (@sqlite3_exec@) cost a parse and a code generation per
-- statement, a measurable share of a short transaction. The step is a safe
-- call: @BEGIN IMMEDIATE@ can wait on the busy handler and @COMMIT@ syncs.
control :: Connection -> Text -> IO ()
control connection sql = withPrepared connection sql (void . S.step)

-- | @connection.execute("BEGIN IMMEDIATE")@.
begin :: Connection -> IO ()
begin connection = control connection "BEGIN IMMEDIATE"

-- | @connection.commit()@: @COMMIT@ when a transaction is open, otherwise
-- nothing.
commit :: Connection -> IO ()
commit connection = do
  open' <- inTransaction connection
  when open' (control connection "COMMIT")

-- | @connection.rollback()@: @ROLLBACK@ when a transaction is open,
-- otherwise nothing.
rollback :: Connection -> IO ()
rollback connection = do
  open' <- inTransaction connection
  when open' (control connection "ROLLBACK")

-- | Upstream's write pattern:
--
-- > connection.execute("BEGIN IMMEDIATE")
-- > try: …; connection.commit()
-- > except BaseException: connection.rollback(); raise
--
-- @BEGIN IMMEDIATE@ takes the write lock up front (waiting up to the busy
-- timeout for another writer), so the action never upgrades a read
-- transaction. If the commit itself fails the transaction is rolled back
-- too. A failing rollback does not mask the original exception.
withImmediateTransaction :: Connection -> IO a -> IO a
withImmediateTransaction connection action = mask $ \restore -> do
  begin connection
  result <- restore action `onException` rollbackQuietly
  commit connection `onException` rollbackQuietly
  pure result
  where
    rollbackQuietly = rollback connection `catch` \(_ :: SomeException) -> pure ()

-- | @with connection:@ under the legacy isolation level: commit on success,
-- roll back on an exception (the connection stays open).
withLegacyTransaction :: Connection -> IO a -> IO a
withLegacyTransaction connection action = mask $ \restore -> do
  result <- restore action `onException` (rollback connection `catch` \(_ :: SomeException) -> pure ())
  commit connection
  pure result
