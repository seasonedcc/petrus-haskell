module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, newMVar, modifyMVar_, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, bracket, finally, throwIO, try)
import Control.Monad (forM_, replicateM, void)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Petrus.Json (Json (..), defaultDumps, dumps, parseJson, pythonLoads)
import Petrus.Postgres
import Petrus.TestSupport
import System.Timeout (timeout)
import Test.Hspec

main :: IO ()
main = hspec $ do
  pureSpec
  postgresSpec $ do
    connectionSpec
    errorSpec
    parameterSpec
    fenceSpec
    notifySpec
    interruptSpec

-- * Helpers

dsn :: PostgresTarget -> ByteString
dsn = targetUrl

dsnString :: PostgresTarget -> String
dsnString = BC.unpack . targetUrl

encodeJson :: Json -> String
encodeJson value = either (error . show) BC.unpack (dumps defaultDumps value)

texts :: [Text] -> Json
texts = Array . map String

decode :: ByteString -> Json
decode = either error id . parseJson pythonLoads

member :: Text -> Json -> Json
member key = \case
  Object members -> maybe Null id (lookup key members)
  _ -> Null

-- | A Python psycopg connection driven line by line: each command is a JSON
-- object, each answer a JSON object (see 'agentScript').
agentScript :: Text
agentScript =
  T.unlines
    [ "import json, sys"
    , "import psycopg"
    , "from psycopg import sql"
    , "from psycopg.types.json import Jsonb"
    , "from petrus.engine._postgres import PostgresAuthorityFence"
    , "BASES = ['InterfaceError', 'DataError', 'OperationalError', 'IntegrityError', 'InternalError',"
    , "         'ProgrammingError', 'NotSupportedError', 'DatabaseError']"
    , "conn = psycopg.connect(sys.argv[1], autocommit=sys.argv[2] == 'autocommit')"
    , "fences = {}"
    , "print(json.dumps({'pid': conn.info.backend_pid}), flush=True)"
    , "for line in sys.stdin:"
    , "    cmd = json.loads(line)"
    , "    op = cmd['op']"
    , "    try:"
    , "        if op == 'execute':"
    , "            params = cmd.get('params')"
    , "            if cmd.get('jsonb'):"
    , "                params = [Jsonb(p) for p in params]"
    , "            cur = conn.execute(cmd['sql'], params)"
    , "            rows = cur.fetchall() if cur.description else None"
    , "            out = {'rowcount': cur.rowcount, 'rows': rows, 'status': cur.statusmessage}"
    , "        elif op == 'commit':"
    , "            conn.commit(); out = {}"
    , "        elif op == 'rollback':"
    , "            conn.rollback(); out = {}"
    , "        elif op == 'autocommit':"
    , "            conn.autocommit = cmd['value']; out = {}"
    , "        elif op == 'wait':"
    , "            got = None"
    , "            for n in conn.notifies(timeout=cmd['timeout'], stop_after=1):"
    , "                got = [n.channel, n.payload, n.pid]"
    , "                break"
    , "            out = {'notification': got}"
    , "        elif op == 'fence':"
    , "            fences[cmd['instance']] = PostgresAuthorityFence(conn, cmd['instance']); out = {}"
    , "        elif op == 'release':"
    , "            fences.pop(cmd['instance']).close(); out = {}"
    , "        elif op == 'status':"
    , "            out = {'status': conn.info.transaction_status.name}"
    , "        elif op == 'identifier':"
    , "            out = {'quoted': sql.Identifier(cmd['name']).as_string(conn)}"
    , "        else:"
    , "            out = {'error': 'unknown op'}"
    , "    except Exception as e:"
    , "        base = next((c.__name__ for c in type(e).__mro__ if c.__name__ in BASES), None)"
    , "        out = {'error': type(e).__name__, 'base': base, 'message': str(e), 'sqlstate': getattr(e, 'sqlstate', None)}"
    , "    print(json.dumps(out, default=str), flush=True)"
    ]

data Agent = Agent {agentProcess :: PythonProcess, agentPid :: Int}

withAgent :: PostgresTarget -> Bool -> (Agent -> IO a) -> IO a
withAgent target autocommitMode action =
  withPython agentScript [dsnString target, if autocommitMode then "autocommit" else "join"] $ \process -> do
    hello <- decode <$> readLine process
    case member "pid" hello of
      Int pid -> action (Agent process (fromInteger pid))
      other -> throwIO (userError ("agent did not start: " ++ show other))

ask :: Agent -> [(Text, Json)] -> IO Json
ask agent command = do
  sendLine (agentProcess agent) (BC.pack (encodeJson (Object command)))
  decode <$> readLine (agentProcess agent)

agentExecute :: Agent -> Text -> [Json] -> IO Json
agentExecute agent statement params =
  ask agent [("op", String "execute"), ("sql", String statement), ("params", if null params then Null else Array params)]

-- | The Python-visible shape of a Haskell error: (DB-API base class,
-- SQLSTATE, str(e)).
errorShape :: PostgresError -> (Json, Json, Json)
errorShape failure =
  ( String (T.pack (show (errorClass failure)))
  , maybe Null String (errorSqlState failure)
  , String (errorMessage failure)
  )

pythonErrorShape :: Json -> (Json, Json, Json)
pythonErrorShape answer = (member "base" answer, member "sqlstate" answer, member "message" answer)

expectPostgresError :: IO a -> IO PostgresError
expectPostgresError action =
  try action >>= \case
    Left failure -> pure failure
    Right _ -> throwIO (userError "expected a PostgresError")

scalar :: Connection -> Sql -> [Param] -> IO (Maybe ByteString)
scalar connection statement params =
  queryFirst connection statement params >>= \case
    Just (value : _) -> pure value
    _ -> pure Nothing

withConn :: PostgresTarget -> Bool -> (Connection -> IO a) -> IO a
withConn target = withConnection (dsn target)

-- * Pure behavior

pureSpec :: Spec
pureSpec = describe "pure parts" $ do
  it "derives upstream's fence keys (golden vectors)" $ do
    fenceKey "demo" `shouldBe` Right 9068829335228303175
    fenceKey "pg-only-x" `shouldBe` Right 1026611314415528254
    fenceKey "\233" `shouldBe` Right (-8749034762973604915)
    fenceKey "instance-1" `shouldBe` Right 155117918061411130

  it "derives fence keys identical to _fence_key, and its empty-id refusal" $ do
    let instances = ["demo", "a'b", "\"q\"", "\26085\26412\35486", "\128512 emoji", "tab\there", T.replicate 300 "long", "x"]
    out <-
      python
        ( T.unlines
            [ "import json, sys"
            , "from petrus.engine._postgres import _fence_key"
            , "for i in json.loads(sys.argv[1]): print(_fence_key(i))"
            , "try:"
            , "    _fence_key('')"
            , "except ValueError as e:"
            , "    print(e)"
            ]
        )
        [encodeJson (texts instances)]
    let expected = map (either (const "?") (BC.pack . show) . fenceKey) instances ++ [TE.encodeUtf8 (fenceErrorMessage EmptyFenceInstance)]
    BC.lines out `shouldBe` expected

  it "converts placeholders as psycopg does" $ do
    let queries =
          [ "SELECT %s"
          , "SELECT %s, %s, %b, %t"
          , "SELECT '100%%', %s"
          , "SELECT %s%s"
          , "SELECT 1 %"
          , "SELECT '%\n', %s"
          , "INSERT INTO t (a) VALUES (%s) ON CONFLICT DO NOTHING"
          , "SELECT '%s' || %s"
          , "SELECT %d"
          , "SELECT % s"
          , "no placeholders"
          , "SELECT \233, %s"
          ]
    out <-
      python
        ( T.unlines
            [ "import json, sys"
            , "import psycopg"
            , "from psycopg._queries import _query2pg_nocache"
            , "for q in json.loads(sys.argv[1]):"
            , "    try:"
            , "        query, formats, order, parts = _query2pg_nocache(q.encode(), 'utf-8')"
            , "        print(json.dumps([True, query.decode(), len(parts) - 1]))"
            , "    except psycopg.ProgrammingError as e:"
            , "        print(json.dumps([False, str(e)]))"
            ]
        )
        [encodeJson (texts queries)]
    let ours q = case convertPlaceholders q of
          Right (converted, n) -> Array [Bool True, String (TE.decodeUtf8 converted), Int (toInteger n)]
          Left message -> Array [Bool False, String message]
    map decode (BC.lines out) `shouldBe` map ours queries
    convertPlaceholders "SELECT %(name)s" `shouldSatisfy` isLeft

  it "spells list parameters as psycopg's ListDumper" $ do
    let items = ["a", "b c", "", "NULL", "null", "x,y", "q\"", "back\\slash", "{}", "\233", "tab\t", "plain"]
    out <-
      python
        ( T.unlines
            [ "import json, sys"
            , "from psycopg.adapt import PyFormat, Transformer"
            , "t = Transformer()"
            , "def show(v):"
            , "    d = t.get_dumper(v, PyFormat.AUTO).upgrade(v, PyFormat.AUTO)"
            , "    print(json.dumps([d.oid, bytes(d.dump(v)).decode()]))"
            , "show(json.loads(sys.argv[1]))"
            , "for ints in ([1, 2], [1, 40000], [5, 3000000000], [1, 2**70]):"
            , "    show(ints)"
            ]
        )
        [encodeJson (texts items)]
    let shape p = Array [Int (toInteger (paramOid p)), String (maybe "" TE.decodeUtf8 (paramValue p))]
    map decode (BC.lines out)
      `shouldBe` map
        shape
        [ textArrayParam items
        , intArrayParam [1, 2]
        , intArrayParam [1, 40000]
        , intArrayParam [5, 3000000000]
        , intArrayParam [1, 2 ^ (70 :: Int)]
        ]

  it "types integers by magnitude as psycopg does" $ do
    let values = [0, 1, -1, 32767, 32768, -32768, -32769, 2147483647, 2147483648, -2147483649, 9223372036854775807, 9223372036854775808, -9223372036854775809] :: [Integer]
    out <-
      python
        ( T.unlines
            [ "import json, sys"
            , "from psycopg.adapt import PyFormat, Transformer"
            , "t = Transformer()"
            , "for v in json.loads(sys.argv[1]):"
            , "    print(t.get_dumper(v, PyFormat.AUTO).upgrade(v, PyFormat.AUTO).oid)"
            ]
        )
        [encodeJson (Array (map Int values))]
    BC.lines out `shouldBe` map (BC.pack . show . paramOid . integerParam) values

-- * Connections and transactions

connectionSpec :: SpecWith PostgresTarget
connectionSpec = describe "connections" $ do
  it "opens a transaction implicitly in join mode, READ COMMITTED, and ends it" $ \target ->
    withConn target False $ \connection -> do
      transactionStatus connection `shouldReturn` Idle
      commit connection
      rollback connection
      transactionStatus connection `shouldReturn` Idle
      scalar connection "SHOW transaction_isolation" [] `shouldReturn` Just "read committed"
      transactionStatus connection `shouldReturn` InTransaction
      commit connection
      transactionStatus connection `shouldReturn` Idle
      transactionMode connection `shouldReturn` Joined

  it "runs READ COMMITTED even when the database default differs (ServerDefault follows it)" $ \target -> do
    withConn target True $ \admin ->
      execute_ admin (sql ("ALTER DATABASE " <> TE.decodeUtf8 (targetDatabase target) <> " SET default_transaction_isolation = 'serializable'")) []
    flip finally (withConn target True $ \admin -> execute_ admin (sql ("ALTER DATABASE " <> TE.decodeUtf8 (targetDatabase target) <> " RESET default_transaction_isolation")) []) $ do
      withConn target False $ \connection ->
        scalar connection "SHOW transaction_isolation" [] `shouldReturn` Just "read committed"
      bracket (connectWith defaultConnectOptions {isolationLevel = ServerDefault} (dsn target)) close $ \connection ->
        scalar connection "SHOW transaction_isolation" [] `shouldReturn` Just "serializable"
      withAgent target False $ \agent -> do
        answer <- agentExecute agent "SHOW transaction_isolation" []
        member "rows" answer `shouldBe` Array [Array [String "serializable"]]

  it "keeps join-mode writes invisible to others until commit, and discards them on rollback" $ \target ->
    withConn target True $ \observer -> withConn target False $ \writer -> do
      execute_ observer "CREATE TABLE joined (n int PRIMARY KEY)" []
      void (execute writer "INSERT INTO joined VALUES (%s)" [intParam 1])
      scalar observer "SELECT count(*) FROM joined" [] `shouldReturn` Just "0"
      commit writer
      scalar observer "SELECT count(*) FROM joined" [] `shouldReturn` Just "1"
      void (execute writer "INSERT INTO joined VALUES (%s)" [intParam 2])
      rollback writer
      scalar observer "SELECT count(*) FROM joined" [] `shouldReturn` Just "1"

  it "owns one transaction per batch on autocommit connections and joins otherwise" $ \target ->
    withConn target True $ \observer -> withConn target True $ \owner -> withConn target False $ \joiner -> do
      execute_ observer "CREATE TABLE batches (n int PRIMARY KEY)" []
      transactionMode owner `shouldReturn` Owned
      withTransaction owner $ do
        forM_ [1, 2] $ \n -> execute owner "INSERT INTO batches VALUES (%s)" [intParam n]
        scalar observer "SELECT count(*) FROM batches" [] `shouldReturn` Just "0"
      scalar observer "SELECT count(*) FROM batches" [] `shouldReturn` Just "2"
      outcome <- try @PostgresError $ withTransaction owner $ do
        void (execute owner "INSERT INTO batches VALUES (%s)" [intParam 3])
        execute owner "INSERT INTO batches VALUES (%s)" [intParam 1]
      fmap errorSqlState (either Just (const Nothing) outcome) `shouldBe` Just (Just uniqueViolation)
      transactionStatus owner `shouldReturn` Idle
      scalar observer "SELECT count(*) FROM batches" [] `shouldReturn` Just "2"
      withTransaction joiner (void (execute joiner "INSERT INTO batches VALUES (%s)" [intParam 4]))
      transactionStatus joiner `shouldReturn` InTransaction
      scalar observer "SELECT count(*) FROM batches" [] `shouldReturn` Just "2"
      commit joiner
      scalar observer "SELECT count(*) FROM batches" [] `shouldReturn` Just "3"

  it "matches psycopg's rowcount and statusmessage statement by statement" $ \target ->
    withAgent target True $ \agent -> withConn target True $ \connection -> do
      let run statement params pythonParams = do
            [result] <- executeResults connection (sql statement) params
            execute_ connection "TRUNCATE rc" []
            restore
            answer <- agentExecute agent statement pythonParams
            execute_ connection "TRUNCATE rc" []
            restore
            (Int (toInteger (resultRowCount result)), String (resultCommand result)) `shouldBe` (member "rowcount" answer, member "status" answer)
          restore = execute_ connection "INSERT INTO rc VALUES (1, 'a'), (2, 'b')" []
      execute_ connection "CREATE TABLE rc (n int PRIMARY KEY, label text)" []
      restore
      run "INSERT INTO rc VALUES (%s, %s) ON CONFLICT DO NOTHING" [intParam 1, textParam "a"] [Int 1, String "a"]
      run "INSERT INTO rc VALUES (%s, %s) ON CONFLICT DO NOTHING" [intParam 3, textParam "c"] [Int 3, String "c"]
      run "UPDATE rc SET label = %s WHERE n >= %s" [textParam "z", intParam 1] [String "z", Int 1]
      run "SELECT n, label FROM rc ORDER BY n" [] []
      run "SELECT n FROM rc WHERE n > %s" [intParam 99] [Int 99]
      run "DELETE FROM rc WHERE n = %s" [intParam 2] [Int 2]
      run "CREATE TEMPORARY TABLE IF NOT EXISTS scratch (n int)" [] []

  it "runs parameterless text as written, several statements at once" $ \target ->
    withConn target True $ \connection -> do
      results <- executeResults connection "SELECT 1; SELECT '100%', '%s'" []
      map resultRows results `shouldBe` [[[Just "1"]], [[Just "100%", Just "%s"]]]
      query connection "SELECT '100%%', %s" [textParam "x"] `shouldReturn` [[Just "100%", Just "x"]]

  it "refuses to change autocommit inside a transaction with psycopg's message" $ \target ->
    withConn target False $ \connection -> withAgent target False $ \agent -> do
      execute_ connection "SELECT 1" []
      ours <- expectPostgresError (setAutocommit connection True)
      _ <- agentExecute agent "SELECT 1" []
      theirs <- ask agent [("op", String "autocommit"), ("value", Bool True)]
      String (errorMessage ours) `shouldBe` member "message" theirs
      rollback connection
      setAutocommit connection True
      autocommit connection `shouldReturn` True

  it "closes idempotently and refuses use afterwards" $ \target -> do
    connection <- connect (dsn target) True
    close connection
    close connection
    isClosed connection `shouldReturn` True
    failure <- expectPostgresError (execute_ connection "SELECT 1" [])
    (errorClass failure, errorMessage failure) `shouldBe` (OperationalError, "the connection is closed")

  it "reports a connection killed by the server as broken" $ \target ->
    withConn target True $ \victim -> withConn target True $ \killer -> do
      pid <- backendPid victim
      execute_ killer "SELECT pg_terminate_backend(%s)" [intParam (fromIntegral pid)]
      threadDelay 100000
      failure <- expectPostgresError (execute_ victim "SELECT 1" [])
      errorClass failure `shouldBe` OperationalError
      isBroken victim `shouldReturn` True

-- * Errors

errorSpec :: SpecWith PostgresTarget
errorSpec = describe "errors" $ do
  it "carries the SQLSTATE, DB-API class and str(e) psycopg reports" $ \target ->
    withConn target True $ \connection -> withAgent target True $ \agent -> do
      execute_ connection "CREATE TABLE unique_rows (n int PRIMARY KEY)" []
      execute_ connection "INSERT INTO unique_rows VALUES (1)" []
      let cases =
            [ ("SELECT * FROM impetus.semantic_events", [])
            , ("SELECT * FROM missing_table WHERE n = %s", [intParam 1])
            , ("INSERT INTO unique_rows VALUES (%s)", [intParam 1])
            , ("SELEC 1", [])
            , ("SELECT 1/0", [])
            , ("SELECT %s::int", [textParam "nope"])
            , ("SELECT %s::jsonb", [textParam "{\"a\": NaN}"])
            , ("SELECT absurd.get_schema_version()", [])
            ]
          pythonParam p = maybe Null (\v -> if paramOid p == oidUnknown then String (TE.decodeUtf8 v) else Int (read (BC.unpack v))) (paramValue p)
      forM_ cases $ \(statement, params) -> do
        ours <- expectPostgresError (execute_ connection (sql statement) params)
        theirs <- agentExecute agent statement (map pythonParam params)
        errorShape ours `shouldBe` pythonErrorShape theirs
      missing <- expectPostgresError (execute_ connection "SELECT * FROM missing_table" [])
      hasSqlState undefinedTable missing `shouldBe` True

  it "reports LockNotAvailable (55P03) as psycopg does" $ \target ->
    withConn target True $ \setup -> withConn target False $ \holder -> withConn target True $ \contender -> withAgent target True $ \agent -> do
      execute_ setup "CREATE TABLE locked_rows (n int PRIMARY KEY)" []
      execute_ setup "INSERT INTO locked_rows VALUES (1)" []
      _ <- query holder "SELECT n FROM locked_rows WHERE n = %s FOR UPDATE" [intParam 1]
      ours <- expectPostgresError (query contender "SELECT n FROM locked_rows WHERE n = %s FOR UPDATE NOWAIT" [intParam 1])
      theirs <- agentExecute agent "SELECT n FROM locked_rows WHERE n = %s FOR UPDATE NOWAIT" [Int 1]
      errorShape ours `shouldBe` pythonErrorShape theirs
      hasSqlState lockNotAvailable ours `shouldBe` True
      rollback holder

  it "leaves a join-mode transaction in error until rolled back" $ \target ->
    withConn target False $ \connection -> do
      _ <- expectPostgresError (execute_ connection "SELECT * FROM missing_table" [])
      transactionStatus connection `shouldReturn` InError
      failure <- expectPostgresError (execute_ connection "SELECT 1" [])
      errorSqlState failure `shouldBe` Just "25P02"
      rollback connection
      scalar connection "SELECT 1" [] `shouldReturn` Just "1"

  it "refuses NUL in text and wrong placeholder counts with psycopg's messages" $ \target ->
    withConn target True $ \connection -> withAgent target True $ \agent -> do
      nul <- expectPostgresError (execute_ connection "SELECT %s" [textParam "a\0b"])
      theirsNul <- agentExecute agent "SELECT %s" [String "a\0b"]
      (String (T.pack (show (errorClass nul))), String (errorMessage nul)) `shouldBe` (member "base" theirsNul, member "message" theirsNul)
      count <- expectPostgresError (execute_ connection "SELECT %s, %s" [textParam "a"])
      theirsCount <- agentExecute agent "SELECT %s, %s" [String "a"]
      (String (T.pack (show (errorClass count))), String (errorMessage count)) `shouldBe` (member "base" theirsCount, member "message" theirsCount)

-- * Parameters and values

parameterSpec :: SpecWith PostgresTarget
parameterSpec = describe "parameters and values" $ do
  it "sends parameters with the types psycopg sends" $ \target ->
    withConn target True $ \connection -> withAgent target True $ \agent -> do
      let cases =
            [ (intParam 1, Int 1)
            , (intParam 40000, Int 40000)
            , (intParam 3000000000, Int 3000000000)
            , (integerParam (2 ^ (70 :: Int)), Int (2 ^ (70 :: Int)))
            , (boolParam True, Bool True)
            , (textParam "x", String "x")
            , (floatParam 1.5, Float 1.5)
            , (textArrayParam ["a", "b"], Array [String "a", String "b"])
            , (intArrayParam [1, 2], Array [Int 1, Int 2])
            , (nullParam, Null)
            ]
      forM_ cases $ \(param, pythonValue) -> do
        ours <- try (scalar connection "SELECT pg_typeof(%s)::text" [param])
        theirs <- agentExecute agent "SELECT pg_typeof(%s)::text" [pythonValue]
        case ours of
          Right value -> member "rows" theirs `shouldBe` Array [Array [maybe Null (String . TE.decodeUtf8) value]]
          Left failure -> errorShape failure `shouldBe` pythonErrorShape theirs
      ours <- scalar connection "SELECT pg_typeof(%s)::text" [byteaParam "x"]
      ours `shouldBe` Just "bytea"
      jsonb <- either (throwIO . userError . show) pure (jsonbParam (Object [("a", Int 1)]))
      theirs <- ask agent [("op", String "execute"), ("sql", String "SELECT pg_typeof(%s)::text, %s::text"), ("params", Array [Object [("a", Int 1)], Object [("a", Int 1)]]), ("jsonb", Bool True)]
      oursJson <- queryFirst connection "SELECT pg_typeof(%s)::text, %s::text" [jsonb, jsonb]
      member "rows" theirs `shouldBe` Array [Array (maybe [] (map (maybe Null (String . TE.decodeUtf8))) oursJson)]

  it "round-trips values through the decoders" $ \target ->
    withConn target True $ \connection -> do
      row <-
        queryFirst
          connection
          "SELECT %s::text, %s::int8, %s::bool, %s::float8, %s::bytea, %s::jsonb, %s::text"
          [ textParam "h\233llo \128512"
          , intParam (-9223372036854775808)
          , boolParam False
          , floatParam 0.1
          , byteaParam "\0\1\255bytes"
          , either (error . show) id (jsonbParam (Object [("k", Array [Int 1, Float 2.5, Null, Bool True, String "\233"])]))
          , nullParam
          ]
      case row of
        Just [t, i, b, f, y, j, n] -> do
          column decodeText t `shouldBe` Right "h\233llo \128512"
          column decodeInt i `shouldBe` Right (-9223372036854775808)
          column decodeBool b `shouldBe` Right False
          column decodeDouble f `shouldBe` Right 0.1
          column decodeBytea y `shouldBe` Right "\0\1\255bytes"
          column decodeJson j `shouldBe` Right (Object [("k", Array [Int 1, Float 2.5, Null, Bool True, String "\233"])])
          nullable decodeText n `shouldBe` Right Nothing
        other -> expectationFailure ("unexpected row " ++ show other)
      special <- queryFirst connection "SELECT %s::float8, %s::float8, %s::float8" [floatParam (1 / 0), floatParam (-1 / 0), floatParam 1e300]
      fmap (map (column decodeDouble)) special `shouldBe` Just [Right (1 / 0), Right (-1 / 0), Right 1e300]

  it "quotes identifiers as psycopg's sql.Identifier" $ \target ->
    withAgent target True $ \agent -> forM_ ["t_default", "Mixed Case", "quote\"d", "\233", ""] $ \name -> do
      answer <- ask agent [("op", String "identifier"), ("name", String name)]
      member "quoted" answer `shouldBe` String (quoteIdentifier name)

-- * The authority fence

fenceSpec :: SpecWith PostgresTarget
fenceSpec = describe "authority fence" $ do
  it "excludes a Python writer and is excluded by one, with upstream's messages" $ \target ->
    forM_ ["demo", "inst'\233", "q\"uote"] $ \instanceId ->
      withConn target False $ \connection -> withAgent target False $ \agent -> do
        fence <- acquireAuthorityFence connection instanceId
        transactionStatus connection `shouldReturn` InTransaction
        commit connection
        refused <- ask agent [("op", String "fence"), ("instance", String instanceId)]
        (member "error" refused, member "message" refused) `shouldBe` (String "RuntimeError", String (fenceErrorMessage (FenceHeld instanceId)))
        releaseAuthorityFence fence
        releaseAuthorityFence fence
        fenceHeld fence `shouldReturn` False
        rollback connection
        acquired <- ask agent [("op", String "fence"), ("instance", String instanceId)]
        acquired `shouldBe` Object []
        outcome <- try (acquireAuthorityFence connection instanceId)
        case outcome of
          Left failure -> displayExceptionText failure `shouldBe` fenceErrorMessage (FenceHeld instanceId)
          Right _ -> expectationFailure "acquired a fence Python holds"
        rollback connection
        _ <- ask agent [("op", String "release"), ("instance", String instanceId)]
        withAuthorityFence connection instanceId (\held -> fenceKeyOf held `shouldBe` either (const 0) id (fenceKey instanceId))

  it "refuses an empty instance id before touching the connection" $ \target ->
    withConn target False $ \connection -> do
      outcome <- try (acquireAuthorityFence connection "")
      fmap (const ()) outcome `shouldSatisfy` isLeft
      either (\failure -> failure `shouldBe` EmptyFenceInstance) (const (pure ())) outcome
      transactionStatus connection `shouldReturn` Idle

  it "is released when its connection closes" $ \target -> do
    connection <- connect (dsn target) True
    _ <- acquireAuthorityFence connection "closing"
    withConn target True $ \other -> do
      void (try @FenceError (acquireAuthorityFence other "closing")) -- refused while held
      close connection
      threadDelay 100000
      fence <- acquireAuthorityFence other "closing"
      releaseAuthorityFence fence

  it "swallows database errors on release (a dead connection released it already)" $ \target -> do
    connection <- connect (dsn target) True
    fence <- acquireAuthorityFence connection "dead"
    withConn target True $ \killer -> do
      pid <- backendPid connection
      execute_ killer "SELECT pg_terminate_backend(%s)" [intParam (fromIntegral pid)]
    threadDelay 100000
    releaseAuthorityFence fence
    fenceHeld fence `shouldReturn` False
    close connection

displayExceptionText :: FenceError -> Text
displayExceptionText = fenceErrorMessage

-- * LISTEN/NOTIFY

notifySpec :: SpecWith PostgresTarget
notifySpec = describe "LISTEN/NOTIFY" $ do
  it "receives a Python notification with its channel, payload and sender pid" $ \target ->
    withConn target True $ \listener -> withAgent target True $ \agent -> do
      listen listener resultsChannel
      _ <- agentExecute agent "SELECT pg_notify(%s, %s)" [String resultsChannel, String "queue-\233"]
      received <- waitForNotification listener 5
      received `shouldBe` Just (Notification resultsChannel "queue-\233" (agentPid agent))

  it "delivers a join-mode notification to Python only at commit, never after rollback" $ \target ->
    withConn target False $ \sender -> withAgent target True $ \agent -> do
      _ <- agentExecute agent ("LISTEN " <> dispatchChannel) []
      pid <- backendPid sender
      notify sender dispatchChannel "rolled-back"
      rollback sender
      notify sender dispatchChannel "committed"
      early <- ask agent [("op", String "wait"), ("timeout", Float 0.3)]
      member "notification" early `shouldBe` Null
      commit sender
      late <- ask agent [("op", String "wait"), ("timeout", Float 5)]
      member "notification" late `shouldBe` Array [String dispatchChannel, String "committed", Int (toInteger pid)]
      afterwards <- ask agent [("op", String "wait"), ("timeout", Float 0.3)]
      member "notification" afterwards `shouldBe` Null

  it "subscribes a join-mode listener only once its LISTEN commits" $ \target ->
    withConn target False $ \listener -> withConn target True $ \sender -> do
      listen listener dispatchChannel
      notify sender dispatchChannel "before-commit"
      waitForNotification listener 0.3 `shouldReturn` Nothing
      commit listener
      notify sender dispatchChannel "after-commit"
      fmap notificationPayload <$> waitForNotification listener 5 `shouldReturn` Just "after-commit"

  it "keeps notifications that arrive during other statements, in order, dropping none" $ \target ->
    withConn target True $ \listener -> withConn target True $ \sender -> do
      listen listener resultsChannel
      forM_ ["1", "2", "3"] (notify sender resultsChannel)
      threadDelay 100000
      _ <- query listener "SELECT 1" []
      received <- replicateM 3 (waitForNotification listener 0)
      map (fmap notificationPayload) received `shouldBe` map Just ["1", "2", "3"]
      waitForNotification listener 0 `shouldReturn` Nothing
      forM_ ["4", "5"] (notify sender resultsChannel)
      threadDelay 500000
      first <- map notificationPayload <$> pendingNotifications listener
      second <- map notificationPayload <$> pendingNotifications listener
      (first, second) `shouldBe` (["4", "5"], [])

  it "polls every 0.25 s without a doorbell, like wait_for_results" $ \_ -> do
    probes <- newIORef ([] :: [Double])
    start <- getMonotonicTime
    ready <- pollWithDoorbell defaultPollInterval Nothing 1.0 $ do
      now <- getMonotonicTime
      atomicModifyIORef' probes (\ts -> (ts ++ [now - start], ()))
      pure False
    elapsed <- subtract start <$> getMonotonicTime
    ready `shouldBe` False
    times <- readIORef probes
    length times `shouldSatisfy` (\n -> n >= 4 && n <= 6)
    let gaps = zipWith (-) (drop 1 times) times
    gaps `shouldSatisfy` all (\g -> g >= 0.24 && g < 0.4)
    elapsed `shouldSatisfy` (\e -> e >= 1.0 && e < 1.4)

  it "wakes on the doorbell well before the poll interval" $ \target ->
    withConn target True $ \listener -> withConn target True $ \sender -> do
      listen listener resultsChannel
      flag <- newMVar False
      void . forkIO $ do
        threadDelay 50000
        modifyMVar_ flag (const (pure True))
        notify sender resultsChannel "default"
      start <- getMonotonicTime
      ready <- pollWithDoorbell 5 (Just listener) 10 (readMVar flag)
      elapsed <- subtract start <$> getMonotonicTime
      ready `shouldBe` True
      elapsed `shouldSatisfy` (< 1)

  it "returns False at the timeout when nothing becomes ready" $ \target ->
    withConn target True $ \listener -> do
      listen listener resultsChannel
      start <- getMonotonicTime
      pollWithDoorbell defaultPollInterval (Just listener) 0.6 (pure False) `shouldReturn` False
      elapsed <- subtract start <$> getMonotonicTime
      elapsed `shouldSatisfy` (\e -> e >= 0.6 && e < 1.0)

-- * Interruption

interruptSpec :: SpecWith PostgresTarget
interruptSpec = describe "interruption" $ do
  it "cancels a running statement on an asynchronous exception and stays usable" $ \target -> do
    withConn target True $ \connection -> do
      start <- getMonotonicTime
      outcome <- timeout 200000 (execute_ connection "SELECT pg_sleep(10)" [])
      elapsed <- subtract start <$> getMonotonicTime
      isNothing outcome `shouldBe` True
      elapsed `shouldSatisfy` (< 2)
      scalar connection "SELECT 42" [] `shouldReturn` Just "42"
      transactionStatus connection `shouldReturn` Idle
    withConn target False $ \connection -> do
      outcome <- timeout 200000 (execute_ connection "SELECT pg_sleep(10)" [])
      isNothing outcome `shouldBe` True
      transactionStatus connection `shouldReturn` InError
      rollback connection
      scalar connection "SELECT 7" [] `shouldReturn` Just "7"

  it "serializes concurrent use of one connection" $ \target ->
    withConn target True $ \connection -> do
      done <- newEmptyMVar
      forM_ [1 .. 8 :: Int] $ \i -> forkIO $ do
        outcome <- try @SomeException (scalar connection "SELECT %s::int + 1" [intParam (fromIntegral i)])
        putMVar done (i, outcome)
      results <- replicateM 8 (takeMVar done)
      forM_ results $ \(i, outcome) -> either (const Nothing) id outcome `shouldBe` Just (BC.pack (show (i + 1)))
