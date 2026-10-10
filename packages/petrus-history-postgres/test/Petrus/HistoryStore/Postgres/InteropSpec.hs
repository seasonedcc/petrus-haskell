-- | PostgreSQL History interop with the pinned reference: both
-- implementations share one scratch database, so every example crosses the
-- language boundary over the same table — identical DDL and catalog, rows
-- and payload spelling, records written by either loading value-equal in
-- the other, verify-on-conflict between a Python and a Haskell writer
-- (stale and racing), joined transactions invisible to the other language
-- until commit, and the doorbell (@pg_notify@) committing or vanishing with
-- the History batch it rides with.
--
-- Runs @test/interop/postgres_history_interop.py@ under the pinned
-- @upstream/petrus/.venv@ (synced with the @postgres@ extra on first use);
-- pending without @PETRUS_TEST_POSTGRES@.
module Petrus.HistoryStore.Postgres.InteropSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, void)
import Data.ByteString.Char8 qualified as BC
import Data.Either (isRight)
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.HistoryStore.Postgres
import Petrus.HistoryStore.Postgres.Support
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.History.Records (Record, recordName)
import Petrus.Impetus.HistoryStore (CommitMode (..), HistoryStore (..))
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.HistorySupport (everyRecordCategory)
import Petrus.Json (Json (..))
import Petrus.Postgres (Notification (..), backendPid, commit, dispatchChannel, execute_, listen, notify, rollback, waitForNotification)
import Petrus.TestSupport (PostgresTarget, postgresSpec)
import Test.Hspec

script :: FilePath
script = "test/interop/postgres_history_interop.py"

-- | The script with the scratch database's DSN first.
py :: PostgresTarget -> [String] -> IO BC.ByteString
py target arguments = runScript script (dsnArgument target : arguments)

pyJson :: PostgresTarget -> [String] -> IO Json
pyJson target arguments = runScriptJson script (dsnArgument target : arguments)

interactive :: PostgresTarget -> [String] -> (Interactive -> IO a) -> IO a
interactive target arguments = withScript script (dsnArgument target : arguments)

-- | Send one line and read the script's one-line JSON answer.
ask :: Interactive -> BC.ByteString -> IO Json
ask running line = send running line >> receiveJson running

recordAt :: Int -> Record
recordAt = (everyRecordCategory !!)

-- | The reference's refusal text for a different fact at an event id.
differentFact :: Text -> Int -> Record -> Record -> Text
differentFact instanceId position stored appending =
  "event "
    <> eventId instanceId position
    <> " is already recorded as a different fact: refusing to overwrite an appended fact (stored "
    <> recordName stored
    <> ", appending "
    <> recordName appending
    <> ")"

-- | A row without its instance: event-id position, type, occurrence,
-- payload text.
rowShape :: Text -> Json -> Json
rowShape instanceId = \case
  Array [String event, String inst, recordType, occurrence, payload]
    | inst == instanceId, Just position <- T.stripPrefix (instanceId <> ":") event ->
        Array [String position, recordType, occurrence, payload]
  other -> other

counted :: PostgresTarget -> Text -> IO Json
counted target instanceId = pyJson target ["count", T.unpack instanceId]

spec :: Spec
spec = postgresSpec $ describe "PostgreSQL History interop with the reference" $ do
  aroundWith (\action target -> withPgConnection target (\_ -> action target)) $ do
    describe "schema and spelling" schemaSpec
    describe "rows written by either implementation" rowsSpec
    describe "verify-on-conflict across languages" conflictSpec
    describe "joined transactions and the doorbell across languages" joinedSpec

schemaSpec :: SpecWith PostgresTarget
schemaSpec = do
  it "the DDL statements are the reference's, byte for byte" $ \target ->
    pyJson target ["ddl"] `shouldReturn` Array (map String schemaStatements)

  it "every record's payload parameter is the reference's json.dumps spelling, byte for byte" $ \target -> do
    out <- py target ["payloads"]
    let ours = [either (error . T.unpack) id (encodePayload r) | r <- everyRecordCategory]
    BC.lines out `shouldBe` ours

  it "the schema either implementation provisions has the same catalog, and each ensure is idempotent over the other's" $ \target ->
    withPg target True $ \connection -> do
      void (py target ["drop"])
      void (py target ["ensure"])
      referenceCatalog <- pyJson target ["catalog"]
      ensureSchema connection
      pyJson target ["catalog"] `shouldReturn` referenceCatalog
      execute_ connection "DROP SCHEMA impetus CASCADE" []
      ensureSchema connection
      pyJson target ["catalog"] `shouldReturn` referenceCatalog
      void (py target ["ensure"])
      pyJson target ["catalog"] `shouldReturn` referenceCatalog

rowsSpec :: SpecWith PostgresTarget
rowsSpec = do
  it "rows the reference wrote load value-equal in Haskell" $ \target -> do
    instanceId <- freshInstance "interop-py"
    void (py target ["write-every", T.unpack instanceId])
    withPg target True $ \connection ->
      (openPostgresHistoryStore connection instanceId >>= Store.records) `shouldReturn` everyRecordCategory

  it "rows Haskell wrote load value-equal in the reference" $ \target -> do
    instanceId <- freshInstance "interop-hs"
    withPg target True $ \connection -> openPostgresHistoryStore connection instanceId >>= \s -> s.extend everyRecordCategory
    void (py target ["verify-every", T.unpack instanceId])
    pyJson target ["records", T.unpack instanceId] `shouldReturn` Array (map encodeRecord everyRecordCategory)

  it "both implementations write identical rows (event ids, types, occurrences, stored payloads)" $ \target -> do
    reference <- freshInstance "interop-py"
    ours <- freshInstance "interop-hs"
    void (py target ["write-every", T.unpack reference])
    withPg target True $ \connection -> openPostgresHistoryStore connection ours >>= \s -> s.extend everyRecordCategory
    referenceRows <- pyJson target ["rows", T.unpack reference]
    ourRows <- pyJson target ["rows", T.unpack ours]
    case (referenceRows, ourRows) of
      (Array rs, Array os) -> do
        length rs `shouldBe` length everyRecordCategory
        map (rowShape ours) os `shouldBe` map (rowShape reference) rs
      _ -> expectationFailure "rows did not print arrays"

  it "a history both languages extend in turn loads identically in each" $ \target -> do
    instanceId <- freshInstance "interop-turns"
    let (firstHalf, secondHalf) = splitAt 10 everyRecordCategory
    withPg target True $ \connection -> openPostgresHistoryStore connection instanceId >>= \s -> s.extend firstHalf
    interactive target ["stale", T.unpack instanceId] $ \running -> do
      receiveJson running `shouldReturn` String "ready"
      forM_ [10 .. length everyRecordCategory - 1] $ \i ->
        ask running ("append " <> BC.pack (show i)) `shouldReturn` String "ok"
    withPg target True $ \connection ->
      (openPostgresHistoryStore connection instanceId >>= Store.records) `shouldReturn` firstHalf <> secondHalf
    void (py target ["verify-every", T.unpack instanceId])

conflictSpec :: SpecWith PostgresTarget
conflictSpec = do
  it "a stale reference writer acknowledges Haskell's value-equal fact and refuses a different one with the reference text" $ \target -> do
    instanceId <- freshInstance "interop-stale-py"
    interactive target ["stale", T.unpack instanceId] $ \running -> do
      receiveJson running `shouldReturn` String "ready"
      withPg target True $ \connection -> openPostgresHistoryStore connection instanceId >>= \s -> s.extend [recordAt 0, recordAt 1]
      ask running "append 0" `shouldReturn` String "ok"
      ask running "append 2"
        `shouldReturn` String ("error ValueError: " <> differentFact instanceId 1 (recordAt 1) (recordAt 2))
    counted target instanceId `shouldReturn` Int 2

  it "a stale Haskell writer acknowledges the reference's value-equal fact and refuses a different one with the same text" $ \target -> do
    instanceId <- freshInstance "interop-stale-hs"
    withPg target True $ \connection -> do
      stale <- openPostgresHistoryStore connection instanceId
      interactive target ["stale", T.unpack instanceId] $ \running -> do
        receiveJson running `shouldReturn` String "ready"
        ask running "append 0" `shouldReturn` String "ok"
        ask running "append 1" `shouldReturn` String "ok"
      stale.extend [recordAt 0]
      stale.extend [recordAt 2] `shouldThrow` (\(HistoryStoreError m) -> m == differentFact instanceId 1 (recordAt 1) (recordAt 2))
      Store.records stale `shouldReturn` [recordAt 0]
    counted target instanceId `shouldReturn` Int 2

  it "racing a reference writer with the same facts: every round both succeed and each position holds one row" $ \target -> do
    instanceId <- freshInstance "interop-race-same"
    let rounds = 12
    withPg target True $ \connection -> do
      ours <- openPostgresHistoryStore connection instanceId
      interactive target ["stale", T.unpack instanceId] $ \running -> do
        receiveJson running `shouldReturn` String "ready"
        forM_ [0 .. rounds - 1] $ \i -> do
          (theirs, mine) <- race2 (ask running ("append " <> BC.pack (show i))) (ours.extend [recordAt i])
          either (Left . show) Right theirs `shouldBe` Right (String "ok")
          mine `shouldSatisfy` isRight
        ask running "count" `shouldReturn` Int (toInteger rounds)
      Store.records ours `shouldReturn` take rounds everyRecordCategory
    rowsNow <- rows' target instanceId
    length rowsNow `shouldBe` rounds

  it "racing a reference writer with different facts: exactly one wins, the loser is refused naming the winner's fact" $ \target -> do
    outcomes <- forM [1 :: Int .. 6] $ \_ -> do
      instanceId <- freshInstance "interop-race-differ"
      withPg target True $ \connection -> do
        ours <- openPostgresHistoryStore connection instanceId
        interactive target ["stale", T.unpack instanceId] $ \running -> do
          receiveJson running `shouldReturn` String "ready"
          (theirs, mine) <- race2 (ask running "append 3") (ours.extend [recordAt 4])
          stored <- withPg target True $ \probe -> openPostgresHistoryStore probe instanceId >>= Store.records
          case (theirs, mine) of
            (Right (String "ok"), Left failure) -> do
              stored `shouldBe` [recordAt 3]
              show failure `shouldContain` T.unpack (differentFact instanceId 0 (recordAt 3) (recordAt 4))
              pure "reference"
            (Right (String answer), Right ()) -> do
              stored `shouldBe` [recordAt 4]
              answer `shouldBe` "error ValueError: " <> differentFact instanceId 0 (recordAt 4) (recordAt 3)
              pure "haskell"
            other -> expectationFailure ("unexpected race outcome " <> show other) >> pure "neither"
    outcomes `shouldSatisfy` all (`elem` ["reference", "haskell" :: String])
  where
    rows' target instanceId = withPg target True $ \connection -> rows connection instanceId

-- | Run both at once (each started as close to the other as possible).
race2 :: IO a -> IO () -> IO (Either SomeException a, Either SomeException ())
race2 left right = do
  start <- newEmptyMVar
  leftDone <- newEmptyMVar
  rightDone <- newEmptyMVar
  void (forkIO (readMVar start >> try left >>= putMVar leftDone))
  void (forkIO (readMVar start >> try right >>= putMVar rightDone))
  putMVar start ()
  (,) <$> takeMVar leftDone <*> takeMVar rightDone

joinedSpec :: SpecWith PostgresTarget
joinedSpec = do
  it "a Haskell joined batch is invisible to the reference until commit, and gone after rollback" $ \target -> do
    instanceId <- freshInstance "interop-joined-hs"
    withPg target False $ \connection -> do
      store <- openPostgresHistoryStore connection instanceId
      store.mode `shouldBe` JoinedTransaction
      store.extend [recordAt 0, recordAt 1]
      counted target instanceId `shouldReturn` Int 0
      commit connection
      counted target instanceId `shouldReturn` Int 2
      store.extend [recordAt 2]
      rollback connection
      counted target instanceId `shouldReturn` Int 2

  it "a reference joined batch is invisible to Haskell until commit, and gone after rollback" $ \target -> do
    instanceId <- freshInstance "interop-joined-py"
    let loaded = withPg target True $ \connection -> length <$> loadPostgresHistory connection instanceId
    interactive target ["joined", T.unpack instanceId] $ \running -> do
      receiveJson running `shouldReturn` String "ready"
      ask running "append 0" `shouldReturn` String "ok"
      ask running "append 1" `shouldReturn` String "ok"
      loaded `shouldReturn` 0
      ask running "commit" `shouldReturn` String "ok"
      loaded `shouldReturn` 2
      ask running "append 2" `shouldReturn` String "ok"
      ask running "rollback" `shouldReturn` String "ok"
      loaded `shouldReturn` 2

  it "a reference batch and its impetus_dispatch doorbell reach a Haskell listener together on commit, never on rollback" $ \target ->
    withPg target True $ \listener -> do
      instanceId <- freshInstance "interop-doorbell-py"
      listen listener dispatchChannel
      interactive target ["joined", T.unpack instanceId] $ \running -> do
        receiveJson running `shouldReturn` String "ready"
        ask running "append 0" `shouldReturn` String "ok"
        ask running ("notify " <> TE.encodeUtf8 dispatchChannel <> " default") `shouldReturn` String "ok"
        ask running "rollback" `shouldReturn` String "ok"
        waitForNotification listener 0.5 `shouldReturn` Nothing

        ask running "append 0" `shouldReturn` String "ok"
        ask running ("notify " <> TE.encodeUtf8 dispatchChannel <> " default") `shouldReturn` String "ok"
        ask running "commit" `shouldReturn` String "ok"
        waitForNotification listener 5 >>= \case
          Just n -> do
            (n.notificationChannel, n.notificationPayload) `shouldBe` (dispatchChannel, "default")
            -- the doorbell rang after the batch was durable
            withPg target True $ \probe -> length <$> loadPostgresHistory probe instanceId `shouldReturn` 1
          Nothing -> expectationFailure "no doorbell after commit"

  it "a Haskell batch and its doorbell reach a reference listener together on commit, never on rollback" $ \target -> do
    instanceId <- freshInstance "interop-doorbell-hs"
    interactive target ["listen", T.unpack dispatchChannel] $ \running -> do
      receiveJson running `shouldReturn` String "ready"
      withPg target False $ \connection -> do
        store <- openPostgresHistoryStore connection instanceId
        pid <- backendPid connection
        pid `shouldSatisfy` (> 0)
        store.extend [recordAt 0]
        notify connection dispatchChannel "default"
        rollback connection
        ask running "drain 0.5" `shouldReturn` Array []

        fresh <- openPostgresHistoryStore connection instanceId
        fresh.extend [recordAt 0]
        notify connection dispatchChannel "default"
        commit connection
        ask running "drain 2" `shouldReturn` Array [Array [String dispatchChannel, String "default"]]
        counted target instanceId `shouldReturn` Int 1
        toList <$> loadPostgresHistory connection instanceId `shouldReturn` [recordAt 0]
        rollback connection
