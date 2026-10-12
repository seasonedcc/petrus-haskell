module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Control.Exception (ErrorCall (..), SomeException, bracket, throwIO, try)
import Control.Monad (forM_, void, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Json (Json (..), defaultDumps, dumps, encodeErrorMessage, pythonFloatRepr)
import Petrus.Posix (FileStat (..), Follow (..), permissionBits, realpath, statAt)
import Petrus.Sqlite
import Petrus.TestSupport
import Database.SQLite3 (Database)
import System.Directory (createDirectory, createDirectoryLink, doesFileExist, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

main :: IO ()
main = hspec $ do
  profileSpec
  paramSpec
  transactionSpec
  poolSpec
  schemaSpec
  reprSpec
  fenceSpec

withTemp :: (FilePath -> IO a) -> IO a
withTemp action = withSystemTempDirectory "petrus-sqlite" $ \dir -> realpath dir >>= action

-- The History store's DDL, verbatim from petrus.impetus.history_store.sqlite
-- (a test below checks it against the pinned module).
historyDdl :: [Text]
historyDdl =
  [ "CREATE TABLE impetus_history_schema (\n    component TEXT PRIMARY KEY CHECK (component = 'history'),\n    version INTEGER NOT NULL\n)"
  , "INSERT INTO impetus_history_schema (component, version) VALUES ('history', 1)"
  , "CREATE TABLE impetus_history_events (\n    instance TEXT NOT NULL,\n    position INTEGER NOT NULL CHECK (position >= 0),\n    event_id TEXT NOT NULL UNIQUE,\n    record_type TEXT NOT NULL,\n    occurrence INTEGER,\n    payload TEXT NOT NULL,\n    recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),\n    PRIMARY KEY (instance, position)\n)"
  , "CREATE UNIQUE INDEX impetus_history_one_firing_terminal\n    ON impetus_history_events (instance, occurrence)\n    WHERE record_type IN ('FiringCompleted', 'FiringFailed')"
  , "CREATE UNIQUE INDEX impetus_history_one_activity_terminal\n    ON impetus_history_events (instance, occurrence)\n    WHERE record_type IN ('ActivityCompleted', 'ActivityFailed')"
  ]

strings :: Json -> [Text]
strings = \case
  Array items -> [s | String s <- items]
  _ -> []

sqlJson :: SQLData -> Json
sqlJson = \case
  SQLInteger n -> Int (toInteger n)
  SQLFloat d -> Float d
  SQLText t -> String t
  SQLBlob b -> String (TE.decodeLatin1 b)
  SQLNull -> Null

firstValue :: Maybe [SQLData] -> Json
firstValue = \case
  Just (value : _) -> sqlJson value
  _ -> Null

pragmaNames :: [Text]
pragmaNames = ["journal_mode", "synchronous", "foreign_keys", "busy_timeout", "secure_delete"]

pythonPragmas :: String -> FilePath -> IO Json
pythonPragmas kind path =
  pythonJson
    ( T.unlines
        [ "import json, sqlite3, sys"
        , "from pathlib import Path"
        , "from types import SimpleNamespace"
        , "kind, path = sys.argv[1], sys.argv[2]"
        , "if kind == 'history':"
        , "    from petrus.impetus.history_store.sqlite import SqliteHistoryStore"
        , "    c = SqliteHistoryStore(path, 'probe')._connection"
        , "elif kind == 'local':"
        , "    from petrus.motus.dispatch.local import _connect"
        , "    c = _connect(Path(path))"
        , "elif kind in ('ledger', 'secure'):"
        , "    # petrus.agenticus.connection.storage / attachment._retention"
        , "    c = sqlite3.connect(path, isolation_level=None, check_same_thread=False, timeout=5)"
        , "    c.execute('PRAGMA journal_mode = DELETE')"
        , "    c.execute('PRAGMA synchronous = FULL')"
        , "    if kind == 'secure':"
        , "        c.execute('PRAGMA secure_delete = ON')"
        , "elif kind == 'codex':"
        , "    from petrus.agenticus.runtime._codex_gondolin_service import _CodexGondolinRuntimeService as S"
        , "    c = S._connect_db(SimpleNamespace(_ledger=Path(path)))"
        , "print(json.dumps([c.execute('PRAGMA ' + p).fetchone()[0] for p in sys.argv[3:]] + [c.isolation_level]))"
        ]
    )
    ([kind, path] ++ map T.unpack pragmaNames)

haskellPragmas :: Profile -> FilePath -> IO Json
haskellPragmas profile path = withConnection profile path $ \connection -> do
  values <- mapM (\name -> firstValue <$> queryFirst connection ("PRAGMA " <> name) []) pragmaNames
  let isolation = if isolationLevel profile == Autocommit then Null else String ""
  pure (Array (values ++ [isolation]))

profileSpec :: Spec
profileSpec = describe "Connection profiles" $ do
  forM_
    [ ("history", historyStoreProfile)
    , ("local", localDispatchProfile)
    , ("ledger", ledgerProfile)
    , ("secure", secureLedgerProfile)
    , ("codex", codexServiceProfile)
    ]
    $ \(kind, profile) ->
      it ("sets the same connection state as upstream's " ++ kind ++ " connection") $ withTemp $ \dir -> do
        expected <- pythonPragmas kind (dir </> "python.sqlite3")
        actual <- haskellPragmas profile (dir </> "haskell.sqlite3")
        actual `shouldBe` expected

  it "spells every statement exactly as upstream" $ do
    setup historyStoreProfile
      `shouldBe` [ Pragma "PRAGMA busy_timeout = 5000"
                 , Pragma "PRAGMA foreign_keys = ON"
                 , Pragma "PRAGMA synchronous = FULL"
                 , RequireWal "PRAGMA journal_mode = WAL" (RetryLocked 5 0.01) CaseInsensitive
                 ]
    source <- readUpstream "src/petrus/motus/dispatch/local.py"
    forM_ [s | Pragma s <- setup localDispatchProfile] $ \statement ->
      BC.unpack source `shouldSatisfy` (T.unpack ("connection.execute(\"" <> statement <> "\")") `isIn`)

  it "refuses a database that will not switch to WAL with upstream's messages" $ do
    Left refusal <- try (open historyStoreProfile ":memory:")
    expected <-
      python
        "import sys\nfrom petrus.impetus.history_store.sqlite import SqliteHistoryStore\ntry:\n    SqliteHistoryStore(':memory:', 'x')\nexcept ValueError as e:\n    print(e)"
        []
    BC.pack (historyWalRefusal refusal) <> "\n" `shouldBe` expected
    expectedLocal <-
      python "from pathlib import Path\nfrom petrus.motus.dispatch.local import _connect\ntry:\n    _connect(Path(':memory:'))\nexcept ValueError as e:\n    print(e)" []
    BC.pack (localDispatchWalRefusal refusal) <> "\n" `shouldBe` expectedLocal
    reportedMode refusal `shouldBe` Just (SQLText "memory")

  it "retries journal_mode=WAL while the database is locked, within the window" $ withTemp $ \dir -> do
    let path = dir </> "busy.sqlite3"
    withConnection ledgerProfile path $ \connection -> execute_ connection "CREATE TABLE t (x)"
    withPython (exclusiveHolder path) [] $ \holder -> do
      expectLine holder "held"
      let impatient = Profile {busyTimeoutMs = 0, isolationLevel = Autocommit, setup = [RequireWal "PRAGMA journal_mode = WAL" (RetryLocked 0.3 0.01) CaseInsensitive]}
      start <- getMonotonicTime
      result <- try (open impatient path) :: IO (Either SQLError Connection)
      elapsed <- subtract start <$> getMonotonicTime
      case result of
        Left err -> (isLockedError err, elapsed >= 0.3) `shouldBe` (True, True)
        Right connection -> close connection >> expectationFailure "opened while locked"
      done <- newEmptyMVar
      void . forkIO $ do
        outcome <- try (withConnection impatient {setup = [RequireWal "PRAGMA journal_mode = WAL" (RetryLocked 5 0.01) CaseInsensitive]} path (\c -> queryFirst c "PRAGMA journal_mode" []))
        putMVar done (outcome :: Either SomeException (Maybe [SQLData]))
      threadDelay 200000
      sendLine holder "release"
      expectLine holder "released"
      timeout 5000000 (takeMVar done) >>= \case
        Just (Right mode) -> mode `shouldBe` Just [SQLText "wal"]
        other -> expectationFailure ("WAL switch did not succeed after release: " ++ show (fmap (either show show) other))
  where
    isIn needle haystack = T.pack needle `T.isInfixOf` T.pack haystack

exclusiveHolder :: FilePath -> Text
exclusiveHolder path =
  T.unlines
    [ "import sqlite3, sys"
    , "c = sqlite3.connect(" <> T.pack (show path) <> ", isolation_level=None)"
    , "c.execute('BEGIN EXCLUSIVE')"
    , "print('held', flush=True)"
    , "sys.stdin.readline()"
    , "c.execute('COMMIT')"
    , "print('released', flush=True)"
    , "sys.stdin.readline()"
    ]

-- A Python writer on the same file, driven by lines: try (BEGIN IMMEDIATE
-- with a short timeout), hold, commit.
pythonWriter :: Text
pythonWriter =
  T.unlines
    [ "import sqlite3, sys"
    , "c = sqlite3.connect(sys.argv[1], timeout=0.2, isolation_level=None)"
    , "print('ready', flush=True)"
    , "for line in sys.stdin:"
    , "    command = line.strip()"
    , "    try:"
    , "        if command == 'try':"
    , "            c.execute('BEGIN IMMEDIATE'); c.execute('ROLLBACK'); print('acquired', flush=True)"
    , "        elif command == 'hold':"
    , "            c.execute('BEGIN IMMEDIATE'); c.execute('INSERT INTO t VALUES (1)'); print('holding', flush=True)"
    , "        elif command == 'commit':"
    , "            c.execute('COMMIT'); print('committed', flush=True)"
    , "        elif command == 'count':"
    , "            print(c.execute('SELECT count(*) FROM t').fetchone()[0], flush=True)"
    , "    except sqlite3.OperationalError as error:"
    , "        print('error: ' + str(error), flush=True)"
    ]

paramSpec :: Spec
paramSpec = describe "Parameters" $ do
  it "binds UTF-8 bytes as the TEXT value their Text binds" $ withTemp $ \dir ->
    withConnection historyStoreProfile (dir </> "p.sqlite3") $ \connection -> do
      execute_ connection "CREATE TABLE t (k INTEGER, v TEXT)"
      -- The last text is a slice (a non-zero offset into its array).
      forM_ (zip [0 ..] ["", "{\"a\":1}", "caf\233 \128512", "nul\0inside", T.drop 2 "\233\233x\0y"]) $ \(k, text) -> do
        void (executeParams connection "INSERT INTO t VALUES (?, ?)" [Datum (SQLInteger (2 * k)), Datum (SQLText text)])
        void (executeParams connection "INSERT INTO t VALUES (?, ?)" [Datum (SQLInteger (2 * k + 1)), Utf8Text (TE.encodeUtf8 text)])
      rows <- query connection "SELECT typeof(v), length(v), hex(v) FROM t ORDER BY k" []
      length rows `shouldBe` 10
      let pairs (a : b : rest) = (a, b) : pairs rest
          pairs _ = []
      forM_ (pairs rows) $ \(viaText, viaBytes) -> viaBytes `shouldBe` viaText

  it "refuses a parameter list of the wrong length, UTF-8 text included" $ withTemp $ \dir ->
    withConnection historyStoreProfile (dir </> "p.sqlite3") $ \connection -> do
      execute_ connection "CREATE TABLE t (v TEXT)"
      executeParams connection "INSERT INTO t VALUES (?)" [Utf8Text "a", Utf8Text "b"]
        `shouldThrow` (== userError "mismatched parameter count for bind.  Prepared statement needs 1, 2 given")

transactionSpec :: Spec
transactionSpec = describe "Transactions" $ do
  it "BEGIN IMMEDIATE excludes a Python writer until commit" $ withTemp $ \dir -> do
    let path = dir </> "tx.sqlite3"
    withConnection historyStoreProfile path $ \connection -> do
      execute_ connection "CREATE TABLE t (x)"
      withPython pythonWriter [path] $ \writer -> do
        expectLine writer "ready"
        withImmediateTransaction connection $ do
          void (execute connection "INSERT INTO t VALUES (?)" [SQLInteger 1])
          sendLine writer "try"
          readLine writer `shouldReturn` "error: database is locked"
        sendLine writer "try"
        readLine writer `shouldReturn` "acquired"
        sendLine writer "count"
        readLine writer `shouldReturn` "1"

  it "waits for a Python writer's transaction (busy timeout) and then commits" $ withTemp $ \dir -> do
    let path = dir </> "tx.sqlite3"
    withConnection historyStoreProfile path $ \connection -> do
      execute_ connection "CREATE TABLE t (x)"
      withPython pythonWriter [path] $ \writer -> do
        expectLine writer "ready"
        sendLine writer "hold"
        expectLine writer "holding"
        done <- newEmptyMVar
        void . forkIO $ do
          outcome <- try (withImmediateTransaction connection (execute connection "INSERT INTO t VALUES (2)" []))
          putMVar done (outcome :: Either SQLError Int)
        threadDelay 300000
        tryReadMVar done >>= (`shouldSatisfy` maybe True (const False))
        sendLine writer "commit"
        expectLine writer "committed"
        timeout 5000000 (takeMVar done) `shouldReturn` Just (Right 1)
        sendLine writer "count"
        readLine writer `shouldReturn` "2"

  it "gives up with SQLITE_BUSY after the profile's busy timeout" $ withTemp $ \dir -> do
    let path = dir </> "tx.sqlite3"
        quick = Profile {busyTimeoutMs = 100, isolationLevel = Autocommit, setup = []}
    withConnection quick path $ \connection -> do
      execute_ connection "CREATE TABLE t (x)"
      withPython pythonWriter [path] $ \writer -> do
        expectLine writer "ready"
        sendLine writer "hold"
        expectLine writer "holding"
        Left err <- try (withImmediateTransaction connection (pure ()))
        (sqlError err, isLockedError err) `shouldBe` (ErrorBusy, True)
        inTransaction connection `shouldReturn` False

  it "rolls back when the action throws and leaves no transaction open" $ withTemp $ \dir ->
    withConnection historyStoreProfile (dir </> "tx.sqlite3") $ \connection -> do
      execute_ connection "CREATE TABLE t (x)"
      Left (ErrorCall message) <-
        try (withImmediateTransaction connection (execute connection "INSERT INTO t VALUES (1)" [] >> throwIO (ErrorCall "boom")))
      message `shouldBe` "boom"
      inTransaction connection `shouldReturn` False
      query connection "SELECT count(*) FROM t" [] `shouldReturn` [[SQLInteger 0]]
      changed <- withImmediateTransaction connection (executeMany connection "INSERT INTO t VALUES (?)" [[SQLInteger n] | n <- [1 .. 3]])
      changed `shouldBe` 3
      query connection "SELECT x FROM t ORDER BY x" [] `shouldReturn` [[SQLInteger 1], [SQLInteger 2], [SQLInteger 3]]

  it "reports rowcount for ON CONFLICT DO NOTHING like cursor.rowcount" $ withTemp $ \dir ->
    withConnection historyStoreProfile (dir </> "tx.sqlite3") $ \connection -> do
      execute_ connection "CREATE TABLE t (k TEXT PRIMARY KEY, v TEXT)"
      execute connection "INSERT INTO t VALUES (?, ?) ON CONFLICT DO NOTHING" [SQLText "a", SQLText "1"] `shouldReturn` 1
      execute connection "INSERT INTO t VALUES (?, ?) ON CONFLICT DO NOTHING" [SQLText "a", SQLText "2"] `shouldReturn` 0

  it "opens implicit transactions for DML under the legacy isolation level only" $ withTemp $ \dir -> do
    withConnection codexServiceProfile (dir </> "codex.sqlite3") $ \connection -> do
      execute_ connection "CREATE TABLE t (x)"
      inTransaction connection `shouldReturn` False
      void (query connection "SELECT * FROM t" [])
      inTransaction connection `shouldReturn` False
      void (execute connection "  /* note */ -- line\n insert INTO t VALUES (1)" [])
      inTransaction connection `shouldReturn` True
      commit connection
      inTransaction connection `shouldReturn` False
    withConnection historyStoreProfile (dir </> "history.sqlite3") $ \connection -> do
      execute_ connection "CREATE TABLE t (x)"
      void (execute connection "INSERT INTO t VALUES (1)" [])
      inTransaction connection `shouldReturn` False

  it "keeps a path that looks like a URI literal, as sqlite3.connect(uri=False) does" $ withTemp $ \dir -> do
    withConnection ledgerProfile (dir </> "file:odd.sqlite3?mode=ro") $ \connection -> execute_ connection "CREATE TABLE t (x)"
    doesFileExist (dir </> "file:odd.sqlite3?mode=ro") `shouldReturn` True

-- | A pool over the Local Dispatch profile whose opener counts the
-- connections it opens.
countingPool :: Int -> FilePath -> IO (Pool, IORef Int)
countingPool = countingPoolWith localDispatchProfile

countingPoolWith :: Profile -> Int -> FilePath -> IO (Pool, IORef Int)
countingPoolWith profile capacity path = do
  opened <- newIORef 0
  pool <- newPool capacity path (modifyIORef' opened (+ 1) >> open profile path)
  pure (pool, opened)

handle :: Pool -> IO Database
handle pool = withPooledConnection pool (pure . connectionDatabase)

poolSpec :: Spec
poolSpec = describe "Pool" $ do
  it "reuses one connection for sequential operations and keeps the WAL until it closes" $ withTemp $ \dir -> do
    let path = dir </> "pool.sqlite3"
    (pool, opened) <- countingPool 4 path
    withPooledConnection pool $ \c -> withImmediateTransaction c (execute_ c "CREATE TABLE t (x)")
    first <- handle pool
    forM_ [1 .. 5 :: Int] $ \n ->
      withPooledConnection pool $ \c -> withImmediateTransaction c (void (execute c "INSERT INTO t VALUES (?)" [SQLInteger (fromIntegral n)]))
    handle pool `shouldReturn` first
    readIORef opened `shouldReturn` 1
    doesFileExist (path <> "-wal") `shouldReturn` True
    closePool pool
    -- The pool's connection was the last one: closing it checkpointed the
    -- WAL and deleted it.
    doesFileExist (path <> "-wal") `shouldReturn` False
    withConnection localDispatchProfile path $ \c -> query c "SELECT count(*) FROM t" [] `shouldReturn` [[SQLInteger 5]]

  it "gives concurrent operations connections of their own and keeps at most its capacity idle" $ withTemp $ \dir -> do
    (pool, opened) <- countingPool 1 (dir </> "pool.sqlite3")
    (outer, inner) <- withPooledConnection pool $ \a -> (connectionDatabase a,) <$> handle pool
    outer `shouldNotBe` inner
    readIORef opened `shouldReturn` 2
    -- One of the two stayed idle, the other was closed.
    _ <- withPooledConnection pool $ \_ -> handle pool
    readIORef opened `shouldReturn` 3
    closePool pool

  it "reopens when the path names another file" $ withTemp $ \dir -> do
    let path = dir </> "pool.sqlite3"
    (pool, opened) <- countingPool 4 path
    withPooledConnection pool $ \c -> execute_ c "CREATE TABLE t (x)"
    forM_ ["", "-wal", "-shm"] $ \suffix -> do
      present <- doesFileExist (path <> suffix)
      when present (removeFile (path <> suffix))
    rows <- withPooledConnection pool $ \c -> query c "SELECT name FROM sqlite_master" []
    rows `shouldBe` []
    readIORef opened `shouldReturn` 2
    doesFileExist path `shouldReturn` True
    closePool pool

  it "closes a connection after a SQLite error or with a transaction left open, and reuses it otherwise" $ withTemp $ \dir -> do
    (pool, opened) <- countingPool 4 (dir </> "pool.sqlite3")
    withPooledConnection pool $ \c -> execute_ c "CREATE TABLE t (x)"
    Left (ErrorCall _) <- try (withPooledConnection pool (\_ -> throwIO (ErrorCall "boom")))
    readIORef opened `shouldReturn` 1
    Left (_ :: SQLError) <- try (withPooledConnection pool (\c -> execute_ c "INSERT INTO missing VALUES (1)"))
    _ <- handle pool
    readIORef opened `shouldReturn` 2
    withPooledConnection pool begin
    open' <- withPooledConnection pool inTransaction
    open' `shouldBe` False
    readIORef opened `shouldReturn` 3
    closePool pool

  it "stays usable once closed, with a connection per operation" $ withTemp $ \dir -> do
    (pool, opened) <- countingPool 4 (dir </> "pool.sqlite3")
    _ <- handle pool
    closePool pool
    closePool pool
    _ <- handle pool
    _ <- handle pool
    readIORef opened `shouldReturn` 3

  it "never reuses an in-memory connection" $ do
    (pool, opened) <- countingPoolWith ledgerProfile 4 ":memory:"
    withPooledConnection pool $ \c -> execute_ c "CREATE TABLE t (x)"
    rows <- withPooledConnection pool $ \c -> query c "SELECT name FROM sqlite_master" []
    rows `shouldBe` []
    readIORef opened `shouldReturn` 2
    closePool pool

schemaSpec :: Spec
schemaSpec = describe "Schema" $ do
  it "keeps a verbatim copy of the History store DDL" $ do
    value <- pythonJson "import json\nfrom petrus.impetus.history_store.sqlite import _DDL\nprint(json.dumps(list(_DDL)))" []
    strings value `shouldBe` historyDdl

  it "creates sqlite_master rows byte-identical to the Python History store" $ withTemp $ \dir -> do
    let ours = dir </> "haskell.sqlite3"
        theirs = dir </> "python.sqlite3"
    withConnection historyStoreProfile ours $ \connection ->
      withImmediateTransaction connection (createSchema connection historyDdl)
    void (python "import sys\nfrom petrus.impetus.history_store.sqlite import SqliteHistoryStore\nSqliteHistoryStore(sys.argv[1], 'i').close()" [theirs])
    let master path = withConnection ledgerProfile path $ \c -> query c "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name" []
    mine <- withConnection historyStoreProfile ours $ \c -> query c "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name" []
    python' <- master theirs
    mine `shouldBe` python'
    -- The Python store accepts the Haskell-created file (its DDL text check passes).
    accepted <- python "import sys\nfrom petrus.impetus.history_store.sqlite import SqliteHistoryStore\ns = SqliteHistoryStore(sys.argv[1], 'i'); print(len(s)); s.close()" [ours]
    accepted `shouldBe` "0\n"

  it "accepts whitespace and case variants and refuses real differences, as upstream does" $ withTemp $ \dir -> do
    let variant = T.replace "position INTEGER NOT NULL" "position   integer\tNOT NULL" (historyDdl !! 2)
        different = T.replace "position >= 0" "position > 0" (historyDdl !! 2)
    forM_ [("variant", variant, True), ("different", different, False)] $ \(name, events, ok) -> do
      let path = dir </> (name ++ ".sqlite3")
          ddl = take 2 historyDdl ++ [events] ++ drop 3 historyDdl
      withConnection historyStoreProfile path $ \connection -> do
        withImmediateTransaction connection (createSchema connection ddl)
        actual <- objectSql connection ["impetus_history_schema", "impetus_history_events", "impetus_history_one_firing_terminal", "impetus_history_one_activity_terminal"]
        let expected = Map.fromList (zip ["impetus_history_schema", "impetus_history_events", "impetus_history_one_firing_terminal", "impetus_history_one_activity_terminal"] [historyDdl !! 0, historyDdl !! 2, historyDdl !! 3, historyDdl !! 4])
        ddlMatches expected actual `shouldBe` ok
      verdict <-
        python
          "import sys\nfrom petrus.impetus.history_store.sqlite import SqliteHistoryStore\ntry:\n    SqliteHistoryStore(sys.argv[1], 'i').close(); print('ok')\nexcept ValueError as e:\n    print(str(e).split(': ', 1)[1])"
          [path]
      verdict `shouldBe` (if ok then "ok\n" else "corrupt or foreign impetus_history version 1 DDL shape\n")

  it "normalizes DDL exactly like re.sub(r'\\s+', ' ', s.strip()).lower()" $ do
    let samples =
          [ "  CREATE\tTABLE  x (\n a INT )\r\n"
          , "A\x1c\&B\x1d\&C\x1e\&D\x1f\&E\x85\&F\xa0G\x1680H\x2000I\x200aJ\x2028K\x2029L\x202fM\x205fN\x3000O"
          , "ÀÉÎ ǅ ẞ İ Ω \x200bZERO-WIDTH\x200b"
          , ""
          , "   "
          , "x\x0b\x0cy"
          , "\x0391\x03A3 \x03A3\x0391 \x0391\x03A3\x0301. \x1C89\x0130"
          ]
    expected <- pythonJson "import json, re, sys\nprint(json.dumps([re.sub(r'\\s+', ' ', s.strip()).lower() for s in json.loads(sys.argv[1])]))" [jsonList samples]
    strings expected `shouldBe` map normalizeDdl samples

  it "reads table_info, index_info and foreign_key_list like Python, and Local Dispatch accepts the Haskell-created file" $ withTemp $ \dir -> do
    let path = dir </> "dispatch.sqlite3"
    ddl <- strings <$> pythonJson "import json\nfrom petrus.motus.dispatch.local import _DDL\nprint(json.dumps(list(_DDL)))" []
    length ddl `shouldBe` 6
    withConnection localDispatchProfile path $ \connection -> withImmediateTransaction connection (createSchema connection ddl)
    void (python "import sys\nfrom pathlib import Path\nfrom petrus.motus.dispatch.local import _initialize\n_initialize(Path(sys.argv[1]))" [path])
    let tables = ["impetus_local_dispatch_schema", "impetus_local_dispatch_tasks", "impetus_local_dispatch_terminals", "impetus_local_dispatch_cancellations"]
    expected <-
      pythonJson
        ( T.unlines
            [ "import json, sqlite3, sys"
            , "c = sqlite3.connect(sys.argv[1])"
            , "tables = sys.argv[2:]"
            , "print(json.dumps({"
            , "  'table_info': [[list(r) for r in c.execute(f'PRAGMA table_info({t})')] for t in tables],"
            , "  'index_info': [list(r) for r in c.execute('PRAGMA index_info(impetus_local_dispatch_claimable)')],"
            , "  'foreign_key_list': [list(r) for r in c.execute('PRAGMA foreign_key_list(impetus_local_dispatch_terminals)')],"
            , "  'user_version': c.execute('PRAGMA user_version').fetchone()[0],"
            , "  'quick_check': c.execute('PRAGMA quick_check').fetchone()[0]}))"
            ]
        )
        (path : map T.unpack tables)
    actual <- withConnection localDispatchProfile path $ \connection -> do
      infos <- mapM (tableInfo connection) tables
      index <- indexInfo connection "impetus_local_dispatch_claimable"
      foreignKeys <- foreignKeyList connection "impetus_local_dispatch_terminals"
      version <- userVersion connection
      check <- quickCheck connection
      let column c =
            Array
              [ Int (toInteger (columnId c)), String (columnName c), String (columnType c)
              , Int (if columnNotNull c then 1 else 0), maybe Null String (columnDefault c), Int (toInteger (columnPrimaryKey c))
              ]
          indexRow i = Array [Int (toInteger (indexRank i)), Int (toInteger (indexColumnId i)), maybe Null String (indexColumnName i)]
          foreignRow f =
            Array
              [ Int (toInteger (foreignKeyId f)), Int (toInteger (foreignKeySeq f)), String (foreignKeyTable f), String (foreignKeyFrom f)
              , maybe Null String (foreignKeyTo f), String (foreignKeyOnUpdate f), String (foreignKeyOnDelete f), String (foreignKeyMatch f)
              ]
      pure $
        Object
          [ ("table_info", Array (map (Array . map column) infos))
          , ("index_info", Array (map indexRow index))
          , ("foreign_key_list", Array (map foreignRow foreignKeys))
          , ("user_version", Int (toInteger version))
          , ("quick_check", maybe Null String check)
          ]
    actual `shouldBe` expected
    objects <- withConnection localDispatchProfile path $ \connection -> schemaObjects connection "impetus_local_dispatch_%"
    Map.lookup "impetus_local_dispatch_claimable" objects `shouldBe` Just "index"
    Map.size objects `shouldBe` 5

jsonList :: [Text] -> String
jsonList items = either (error . encodeErrorMessage) BC.unpack (dumps defaultDumps (Array (map String items)))

reprSpec :: Spec
reprSpec = describe "Python repr" $ do
  it "matches repr() for str, bytes, int, float and None" $ do
    let texts = ["demo", "", "it's", "say \"hi\"", "both ' and \"", "tab\tnew\nret\r", "back\\slash", "\x00\x1f\x7f", "é ü ✓", "\x85\xa0\xad", "\x2028\xe000\xfffe", "\x1f600 \xe0001", "\x10ffff"]
    expected <- pythonJson "import json, sys\nprint(json.dumps([repr(s) for s in json.loads(sys.argv[1])]))" [jsonList texts]
    strings expected `shouldBe` map (T.pack . pythonReprText) texts
    let values = [SQLInteger (-42), SQLFloat 0.1, SQLFloat 1e22, SQLFloat (-0.0), SQLFloat (1 / 0), SQLNull, SQLBlob "a'b\"c\x00\xff", SQLBlob "it's"]
    others <- pythonJson "import json\nprint(json.dumps([repr(v) for v in (-42, 0.1, 1e22, -0.0, float('inf'), None, b'a\\'b\"c\\x00\\xff', b\"it's\")]))" []
    strings others `shouldBe` map (T.pack . pythonReprSqlData) values
    pythonFloatRepr 0.1 `shouldBe` "0.1"

-- A Python process holding (or refused) the upstream _WriterFence.
pythonFence :: Text
pythonFence =
  T.unlines
    [ "import sys"
    , "from petrus.impetus.history_store.sqlite import _WriterFence"
    , "try:"
    , "    fence = _WriterFence(sys.argv[1], sys.argv[2])"
    , "    print('held ' + str(fence.path), flush=True)"
    , "except (RuntimeError, ValueError) as error:"
    , "    print('refused ' + str(error), flush=True)"
    , "    fence = None"
    , "sys.stdin.readline()"
    , "if fence is not None:"
    , "    fence.close()"
    , "print('released', flush=True)"
    , "sys.stdin.readline()"
    ]

fenceSpec :: Spec
fenceSpec = describe "WriterFence" $ do
  it "derives the same lock path as Python, through symlinked and dot-dot spellings" $ withTemp $ \dir -> do
    createDirectory (dir </> "real")
    createDirectoryLink (dir </> "real") (dir </> "alias")
    forM_ [(dir </> "alias" </> "db.sqlite3", "demo"), (dir </> "real" </> "x" </> ".." </> "db.sqlite3", "é"), (dir </> "real" </> "db.sqlite3", "it's \"quoted\"")] $ \(path, instanceId) -> do
      line <- withPython pythonFence [path, T.unpack instanceId] $ \fence -> readLine fence <* sendLine fence ""
      (_, lockPath) <- writerFencePaths path instanceId
      line `shouldBe` BC.pack "held " <> TE.encodeUtf8 (T.pack lockPath)

  it "is refused while Python holds it, with upstream's message, and vice versa" $ withTemp $ \dir -> do
    let path = dir </> "db.sqlite3"
        instanceId = "inst'1"
    withPython pythonFence [path, T.unpack instanceId] $ \holder -> do
      held <- readLine holder
      BC.take 5 held `shouldBe` "held "
      refusal <- try (acquireWriterFence path instanceId)
      either Just (const Nothing) refusal `shouldBe` Just (SecondWriter instanceId path)
      -- Another instance in the same database is independent.
      withWriterFence path "other" (const (pure ()))
      sendLine holder ""
      expectLine holder "released"
    withWriterFence path instanceId $ \fence -> do
      ensureWriterFence fence
      message <- withPython pythonFence [path, T.unpack instanceId] $ \other -> readLine other <* sendLine other ""
      message `shouldBe` "refused " <> BC.pack (fenceErrorMessage (SecondWriter instanceId path))
      lockDir <- statAt Nothing (takeDirectory (fenceLockPath fence)) FollowLinks
      lockFile <- statAt Nothing (fenceLockPath fence) FollowLinks
      (permissionBits lockDir, permissionBits lockFile) `shouldBe` (0o700, 0o600)
      statLinkCount lockFile `shouldBe` 1

  it "refuses an empty instance id with upstream's message" $ withTemp $ \dir -> do
    message <- withPython pythonFence [dir </> "db.sqlite3", ""] $ \other -> readLine other <* sendLine other ""
    acquireWriterFence (dir </> "db.sqlite3") "" `shouldThrow` (== EmptyInstance)
    message `shouldBe` "refused " <> BC.pack (fenceErrorMessage EmptyInstance)

  it "releases idempotently and can be taken again" $ withTemp $ \dir -> do
    fence <- acquireWriterFence (dir </> "db.sqlite3") "x"
    releaseWriterFence fence
    releaseWriterFence fence
    bracket (acquireWriterFence (dir </> "db.sqlite3") "x") releaseWriterFence (const (pure ()))
