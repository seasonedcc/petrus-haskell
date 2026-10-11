-- | Parity: @tests/petrus/impetus/history_store/test_sqlite_history.py@,
-- the direct production contract of the local SQLite History store, plus
-- the backend-contract suite of @test_history_backends.py@ with
-- @reopen = sqlite@.
--
-- Where the reference matches a refusal with a regex fragment, the examples
-- compare the whole message (the texts are the reference's; the interop
-- suite checks them against the reference process on the same files).
module Petrus.HistoryStore.SqliteSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, when)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.HistoryStore.BackendContractSpec (backendContract)
import Petrus.HistoryStore.Sqlite
import Petrus.HistoryStore.SqliteSupport
import Petrus.HistoryStore.Support (withScratch)
import Petrus.Impetus.History
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.HistorySupport (everyRecordCategory)
import Petrus.Impetus.Petrinet (NetPath, black)
import Petrus.Impetus.TestSupport (np, tokD)
import Petrus.Json (EncodeOptions (..), Json (..), compact, dumps, parseJson, pythonLoads)
import Petrus.Posix.Path (purePath)
import Petrus.Sqlite.Connection (SQLData (..))
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Hspec

place', transition' :: NetPath
place' = np "place"
transition' = np "transition"

initialized :: Record
initialized = RTokensInitialized (TokensInitialized place' [black] 0 [] Nothing)

begun :: Int -> Integer -> Record
begun occurrence instant = RFiringBegun (FiringBegun transition' occurrence Nothing (fromInteger instant))

completed :: Int -> Integer -> Record
completed occurrence instant = RFiringCompleted (FiringCompleted transition' occurrence (fromInteger instant))

failed :: Text -> Int -> Integer -> Record
failed message occurrence instant = RFiringFailed (FiringFailed transition' message occurrence (fromInteger instant))

produced :: Int -> Integer -> Record
produced occurrence instant = RTokensProduced (TokensProduced place' [black] occurrence [] Nothing (fromInteger instant))

-- | A refusal with exactly this message.
refusal :: Text -> Selector HistoryStoreError
refusal expected (HistoryStoreError message) = message == expected

-- | Open a store for the duration of an action.
withStore :: FilePath -> Text -> (SqliteHistoryStore -> IO a) -> IO a
withStore = withSqliteHistoryStore

-- | Open, read the records, close.
recordsAt :: FilePath -> Text -> IO [Record]
recordsAt path instanceId = withStore path instanceId (Store.records . (.history))

-- | The path as the reference prints @self.path@.
shown :: FilePath -> Text
shown = T.pack . purePath

spec :: Spec
spec = do
  backendContract "sqlite" (\body -> withScratch (\dir -> withSqliteReopen dir body))

  describe "test_sqlite_history.py" $ do
    it "schema initializes idempotently reopens and preserves unrelated tables" $ withScratch $ \dir -> do
      let path = dir </> "nested" </> "local.sqlite3"
      withStore path "one" $ \history -> do
        Store.append history.history initialized
        rawExec path ["CREATE TABLE unrelated_dispatch_state (value TEXT)", "INSERT INTO unrelated_dispatch_state VALUES ('intact')"]
        held <- Store.records history.history
        recordsAt path "one" `shouldReturn` held
      rawQuery path "SELECT value FROM unrelated_dispatch_state" `shouldReturn` [[SQLText "intact"]]
      rawQuery path "SELECT version FROM impetus_history_schema" `shouldReturn` [[SQLInteger 1]]

    describe "unsupported schema refuses without mutation" $
      forM_ [0 :: Integer, 2] $ \version ->
        it ("version " <> show version) $ withScratch $ \dir -> do
          let path = dir </> "foreign.sqlite3"
          rawExec
            path
            [ "CREATE TABLE impetus_history_schema (component TEXT PRIMARY KEY, version INTEGER NOT NULL)"
            , "INSERT INTO impetus_history_schema VALUES ('history', " <> T.pack (show version) <> ")"
            ]
          untouched <- BS.readFile path
          openSqliteHistoryStore path "one"
            `shouldThrow` refusal
              ( shown path
                  <> ": unsupported impetus_history schema metadata [('history', "
                  <> T.pack (show version)
                  <> ")]; this store reads version 1 only and does not migrate"
              )
          BS.readFile path `shouldReturn` untouched

    it "unversioned known shape refuses" $ withScratch $ \dir -> do
      let path = dir </> "unversioned.sqlite3"
      rawExec path ["CREATE TABLE impetus_history_events (payload TEXT)"]
      openSqliteHistoryStore path "one"
        `shouldThrow` refusal (shown path <> ": foreign or unversioned impetus_history schema; migration is not supported")

    it "current schema refuses a weakened terminal index with the same name" $ withScratch $ \dir -> do
      let path = dir </> "weakened.sqlite3"
      openSqliteHistoryStore path "one" >>= (.close)
      rawExec
        path
        [ "DROP INDEX impetus_history_one_activity_terminal"
        , "CREATE INDEX impetus_history_one_activity_terminal ON impetus_history_events (instance, occurrence)"
        ]
      openSqliteHistoryStore path "one"
        `shouldThrow` refusal (shown path <> ": corrupt or foreign impetus_history version 1 DDL shape")

    it "every record category round trips and payload is canonical" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      withStore path "one" $ \history -> history.history.extend everyRecordCategory
      recordsAt path "one" `shouldReturn` everyRecordCategory
      ([SQLText payload] : _) <- rawQuery path "SELECT payload FROM impetus_history_events ORDER BY position"
      (firstRecord : _) <- pure everyRecordCategory
      parseJson pythonLoads (TE.encodeUtf8 payload) `shouldBe` Right (encodeRecord firstRecord)
      -- and the bytes are the reference's spelling of every record
      payloads <- rawQuery path "SELECT payload FROM impetus_history_events ORDER BY position"
      payloads
        `shouldBe` [ [SQLText (TE.decodeUtf8 bytes)]
                   | Right bytes <- map (dumps compact {ensureAscii = True} . encodeRecord) everyRecordCategory
                   ]

    it "failed batch is atomic and json unfaithful data never enters" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      withStore path "one" $ \history -> do
        history.history.extend [begun 1 1, completed 1 2]
        history.history.extend [produced 1 3, failed "different" 1 3]
          `shouldThrow` refusal
            "occurrence 1 of one already holds its terminal fact (FiringCompleted, event one:1); refusing different FiringFailed (event one:3)"
        Store.append history.history (RTokensInitialized (TokensInitialized place' [tokD "bad" (Float (0 / 0))] 4 [] Nothing))
          `shouldThrow` refusal
            "cannot durably encode TokensInitialized: Out of range float values are not JSON compliant: nan — durable instants, token data, and activity input/result must be JSON-faithful values"
        held <- Store.records history.history
        recordsAt path "one" `shouldReturn` held
        Store.size history.history `shouldReturn` 2

    it "exact retry acknowledges and different retry refuses" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      withStore path "one" $ \first -> withStore path "one" $ \twin -> do
        let record = completed 1 2
        Store.append first.history record
        Store.append twin.history record
        Store.records twin.history `shouldReturn` [record]
        Store.records first.history `shouldReturn` [record]
      withStore path "one" $ \stale -> withStore path "one" $ \winner -> do
        Store.append winner.history (begun 2 3)
        Store.append stale.history (produced 2 3)
          `shouldThrow` refusal "event one:1 is already recorded as a different fact (stored FiringBegun, appending TokensProduced)"

    it "terminal identity and instances are isolated" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
          terminal = completed 1 2
      withStore path "one" $ \one -> do
        one.history.extend [begun 1 1, terminal]
        Store.append one.history terminal
        Store.size one.history `shouldReturn` 2
        Store.append one.history (failed "different" 1 3)
          `shouldThrow` refusal
            "occurrence 1 of one already holds its terminal fact (FiringCompleted, event one:1); refusing different FiringFailed (event one:2)"
        withStore path "two" $ \two -> do
          Store.append two.history (failed "its own" 1 3)
          Store.records two.history `shouldReturn` [failed "its own" 1 3]
        held <- Store.records one.history
        recordsAt path "one" `shouldReturn` held

    describe "fresh constructor refuses corrupt durable rows" $ do
      let corrupted corruption expected = withScratch $ \dir -> do
            let path = dir </> "history.sqlite3"
            withStore path "one" $ \history -> Store.append history.history initialized
            rawExec path [corruption]
            openSqliteHistoryStore path "one" `shouldThrow` refusal (expected path)
      it "gap" $
        corrupted
          "UPDATE impetus_history_events SET position = 2, event_id = 'one:2'"
          (\path -> shown path <> ": history for 'one' is non-dense or has corrupt event identity at position 0")
      it "payload" $
        corrupted
          "UPDATE impetus_history_events SET payload = '{broken'"
          ( const
              "event one:0 does not decode as an event history record: Expecting property name enclosed in double quotes: line 1 column 2 (char 1)"
          )
      it "metadata" $
        corrupted "UPDATE impetus_history_events SET record_type = 'FiringBegun'" (const "event one:0 has corrupt indexing metadata")

    -- The non-string half (instance 7) is enforced by types: the instance
    -- id is 'Text'.
    it "constructor requires non empty instance" $ withScratch $ \dir ->
      openSqliteHistoryStore (dir </> "history.sqlite3") ""
        `shouldThrow` refusal "SqliteHistoryStore requires a non-empty string instance id, got ''"

    it "concurrent first initialization for distinct instances" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      go <- newEmptyMVar
      arrived <- newIORef (0 :: Int)
      results <- forM ["one", "two"] $ \instanceId -> do
        done <- newEmptyMVar
        _ <- forkIO $ do
          -- threading.Barrier(2): both threads start opening together
          n <- atomicModifyIORef' arrived (\k -> (k + 1, k + 1))
          when (n == 2) (putMVar go ())
          readMVar go
          outcome <- try (openSqliteHistoryStore path instanceId >>= (.close))
          putMVar done outcome
        pure done
      outcomes <- forM results $ \done -> timeout 10000000 (takeMVar done)
      forM_ outcomes $ \case
        Just (Right ()) -> pure ()
        Just (Left (failure :: SomeException)) -> expectationFailure (show failure)
        Nothing -> expectationFailure "an initializing thread is still alive after 10 s"

  describe "beyond upstream" $ do
    it "closing is idempotent and a closed store refuses appends but keeps its mirror" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      history <- openSqliteHistoryStore path "one"
      Store.append history.history initialized
      history.close
      history.close
      Store.append history.history (begun 1 1) `shouldThrow` (== ClosedDatabase)
      Store.records history.history `shouldReturn` [initialized]

    it "an empty batch commits nothing and enters nothing" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      withStore path "one" $ \history -> do
        history.history.extend []
        Store.size history.history `shouldReturn` 0
      rawQuery path "SELECT count(*) FROM impetus_history_events" `shouldReturn` [[SQLInteger 0]]

    it "an equal terminal held elsewhere is acknowledged and later positions stay dense" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      withStore path "one" $ \history -> do
        history.history.extend [begun 1 1, completed 1 2]
        -- the re-sent terminal is acknowledged at its own position; the next
        -- record takes the position the terminal did not
        history.history.extend [completed 1 2, produced 2 3]
        Store.records history.history `shouldReturn` [begun 1 1, completed 1 2, produced 2 3]
      rows <- rawQuery path "SELECT position, event_id, record_type, occurrence FROM impetus_history_events WHERE instance = 'one' ORDER BY position"
      rows
        `shouldBe` [ [SQLInteger 0, SQLText "one:0", SQLText "FiringBegun", SQLInteger 1]
                   , [SQLInteger 1, SQLText "one:1", SQLText "FiringCompleted", SQLInteger 1]
                   , [SQLInteger 2, SQLText "one:2", SQLText "TokensProduced", SQLInteger 2]
                   ]
      recordsAt path "one" `shouldReturn` [begun 1 1, completed 1 2, produced 2 3]

    it "a conflict no stored row explains is a runtime failure" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      withStore path "one" $ \history -> do
        -- a foreign row squats the event identity one:0 under another instance
        rawExec
          path
          [ "INSERT INTO impetus_history_events (instance, position, event_id, record_type, occurrence, payload) VALUES ('other', 0, 'x', 'TokensProduced', 1, '{}')"
          , "INSERT INTO impetus_history_events (instance, position, event_id, record_type, occurrence, payload) VALUES ('other', 1, 'one:0', 'TokensProduced', 1, '{}')"
          ]
        -- the identity row exists but differs: a conflicting fact
        Store.append history.history initialized
          `shouldThrow` refusal "event one:0 is already recorded as a different fact (stored TokensProduced, appending TokensInitialized)"
      withScratch $ \other -> do
        let path' = other </> "history.sqlite3"
        withStore path' "one" $ \history -> do
          -- the (instance, position) key is taken by a row with another event id
          rawExec
            path'
            ["INSERT INTO impetus_history_events (instance, position, event_id, record_type, occurrence, payload) VALUES ('one', 0, 'elsewhere', 'TokensProduced', 1, '{}')"]
          Store.append history.history initialized
            `shouldThrow` (== Store.UnverifiableConflict "insert of event one:0 conflicted but no stored row explains it")

    it "the exotic record's payload is the compact ASCII spelling" $ withScratch $ \dir -> do
      let path = dir </> "history.sqlite3"
      withStore path "one" $ \history -> Store.append history.history exotic
      recordsAt path "one" `shouldReturn` [exotic]
      [[SQLText payload]] <- rawQuery path "SELECT payload FROM impetus_history_events"
      payload
        `shouldBe` "{\"record\":\"TokensInitialized\",\"schema\":5,\"place\":\"p\",\"tokens\":[{\"color\":\"text\",\"data\":{\"s\":\"na\\u00efve \\u2603 \\ud83d\\ude00 \\\"q\\\" \\\\ / \\t\\n\\u0000 \\u007f\",\"f\":0.1,\"big\":100000000000000000000,\"neg\":-0.0,\"exp\":1e+16,\"tiny\":5e-324,\"list\":[1,2.5,null,true,{}],\"\\u00e9\":\"key\"}}],\"instant\":0.5,\"entries\":[],\"scope\":null}"
