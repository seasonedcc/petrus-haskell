-- | SQLite History store interop with the pinned reference: both
-- implementations open, validate, load and append to the same database
-- file. Checked here:
--
-- * files written by either side load value-equal in the other, with every
--   payload in the reference's exact spelling;
-- * files created by each side are row-identical (@sqlite_master@ DDL text,
--   schema rows, event rows, journal mode), as dumped by the reference;
-- * interleaved appends to one file from both sides stay dense;
-- * verify-on-conflict answers (acknowledgement, refusal texts, the rolled
--   back batch) agree on the same file states;
-- * every refusal of a foreign, unsupported or corrupt file has the same text;
-- * first initialization under concurrent reference processes and Haskell
--   threads succeeds for every instance;
-- * an Instance begun on one side resumes and completes on the other.
--
-- Runs @test/interop/sqlite_interop.py@ under @upstream/petrus/.venv@ (synced
-- with @uv@ on first use by @petrus-test-support@).
module Petrus.HistoryStore.SqliteInteropSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, fromException, try)
import Control.Monad (forM, forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity (invocation)
import Petrus.HistoryStore.Sqlite
import Petrus.HistoryStore.SqliteSupport
import Petrus.HistoryStore.Support (withScratch)
import Petrus.Impetus.Binding
import Petrus.Impetus.History
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.HistorySupport (everyRecordCategory)
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Impetus.TestSupport (expectRight, field, netOf, np, tokD)
import Petrus.Json (EncodeOptions (..), Json (..), compact, defaultDumps, dumps, lookupMember)
import Petrus.Sqlite.Connection (SQLData (..))
import Petrus.TestSupport.Python (expectLine, readLine, sendLine)
import System.Directory (copyFile)
import System.FilePath ((</>))
import Test.Hspec

everything :: [Record]
everything = everyRecordCategory ++ [exotic]

-- | Python's @len(store)@ / refusal line for one Haskell action.
outcome :: IO Int -> IO ByteString
outcome action =
  try action >>= \case
    Right n -> pure ("ok " <> BC.pack (show n))
    Left (failure :: SomeException)
      | Just (HistoryStoreError message) <- fromException failure -> pure ("ValueError: " <> TE.encodeUtf8 message)
      | Just (UnexplainedConflict message) <- fromException failure -> pure ("RuntimeError: " <> TE.encodeUtf8 message)
      | otherwise -> pure ("unexpected: " <> BC.pack (show failure))

-- | @open PATH INSTANCE@ on this side.
openOutcome :: FilePath -> Text -> IO ByteString
openOutcome path instanceId = outcome (withSqliteHistoryStore path instanceId (Store.size . (.history)))

-- | @append PATH INSTANCE JSON@ on this side.
appendOutcome :: FilePath -> Text -> [Record] -> IO ByteString
appendOutcome path instanceId batch =
  withSqliteHistoryStore path instanceId $ \store -> outcome (store.history.extend batch >> Store.size store.history)

-- | The reference's one non-@ValueError@ load refusal, its
-- @AttributeError@ on a list payload that @dict()@ converted, is a
-- 'HistoryStoreError' here (DIVERGENCES.md); the text is the same.
asRefusal :: ByteString -> ByteString
asRefusal line = maybe line ("ValueError: " <>) (BC.stripPrefix "AttributeError: " line)

trimmed :: ByteString -> ByteString
trimmed = BC.dropWhileEnd (== '\n')

-- | The reference's @dump PATH@.
dumped :: FilePath -> IO ByteString
dumped path = reference ["dump", path]

encodedBatch :: [Record] -> String
encodedBatch batch = either (error . show) BC.unpack (dumps defaultDumps (Array (map encodeRecord batch)))

-- The activity net of @test_history_backends.py@ (the driver imports it).
intake, queue, work, out :: NetPath
intake = np "intake"
queue = np "queue"
work = np "work"
out = np "out"

charge :: Bool -> ActivityHandler
charge mayPrepare =
  ActivityHandler
    { prepare = \b ->
        if not mayPrepare
          then Left "prepare re-ran: the record should have supplied the invocation"
          else case bindingTokens b of
            [issue] -> do
              amount <- field "amount" issue
              Right (invocation "charge_card" (Object [("amount", amount)]))
            other -> Left ("expected one issue, got " <> T.pack (show other))
    , project = \_ result -> case lookupMember "status" result of
        Just s -> Right (handlerTokens [(out, [tokD "Receipt" (Object [("status", s)])])])
        Nothing -> Left "KeyError('status')"
    , projectFailure = Nothing
    }

config :: Bool -> InstanceConfig
config mayPrepare = defaultInstanceConfig {handlerImplementations = Map.fromList [(Symbol "charge", ActivityBound (charge mayPrepare))]}

activityNet :: Net
activityNet =
  netOf
    [place queue, place out]
    [transition intake, Transition work (Just (HandlerSymbol "charge")) [] []]
    [arc intake queue, arc queue work, arc work out]

receipt :: Marking
receipt = markingFromList [(out, [tokD "Receipt" (Object [("status", String "captured")])])]

begun :: Int -> Integer -> Record
begun occurrence instant = RFiringBegun (FiringBegun (np "t") occurrence Nothing (fromInteger instant))

completed :: Int -> Integer -> Record
completed occurrence instant = RFiringCompleted (FiringCompleted (np "t") occurrence (fromInteger instant))

failed :: Text -> Int -> Integer -> Record
failed message occurrence instant = RFiringFailed (FiringFailed (np "t") message occurrence (fromInteger instant))

activityDone :: Int -> Text -> Record
activityDone occurrence status' = RActivityCompleted (ActivityCompleted (np "t") (Object [("status", String status')]) occurrence 4)

produced :: Int -> Integer -> Record
produced occurrence instant = RTokensProduced (TokensProduced (np "p") [black] occurrence [] Nothing (fromInteger instant))

spec :: Spec
spec = describe "SQLite History interop with the reference" $ do
  it "a file the reference wrote loads value-equal with the reference's payload spelling" $ withScratch $ \dir -> do
    let path = dir </> "history.sqlite3"
    void (reference ["write-every", path, "one"])
    withSqliteHistoryStore path "one" (Store.records . (.history)) `shouldReturn` everything
    payloads <- rawQuery path "SELECT payload FROM impetus_history_events ORDER BY position"
    payloads `shouldBe` [[SQLText (TE.decodeUtf8 bytes)] | Right bytes <- map (dumps compact {ensureAscii = True} . encodeRecord) everything]

  it "a file Haskell wrote loads value-equal in the reference with identical payloads" $ withScratch $ \dir -> do
    let path = dir </> "history.sqlite3"
    withSqliteHistoryStore path "one" $ \store -> store.history.extend everything
    reference ["verify-every", path, "one"] `shouldReturn` (BC.pack (show (length everything)) <> "\n")

  it "files created by each side are row-identical" $ withScratch $ \dir -> do
    let ours = dir </> "haskell.sqlite3"
        theirs = dir </> "reference.sqlite3"
    void (reference ["write-every", theirs, "one"])
    withSqliteHistoryStore ours "one" $ \store -> store.history.extend everything
    expected <- dumped theirs
    dumped ours `shouldReturn` expected
    -- and an empty, freshly initialized file
    void (reference ["open", dir </> "fresh-reference.sqlite3", "one"])
    withSqliteHistoryStore (dir </> "fresh-haskell.sqlite3") "one" (const (pure ()))
    fresh <- dumped (dir </> "fresh-reference.sqlite3")
    dumped (dir </> "fresh-haskell.sqlite3") `shouldReturn` fresh

  it "interleaved appends from both sides to one file stay dense and agree" $ withScratch $ \dir -> do
    let path = dir </> "shared.sqlite3"
        (first, rest) = splitAt 5 everything
        (second, third) = splitAt 7 rest
    reference ["append", path, "shared", encodedBatch first] `shouldReturn` "ok 5\n"
    appendOutcome path "shared" second `shouldReturn` "ok 12"
    reference ["append", path, "shared", encodedBatch third] `shouldReturn` BC.pack ("ok " <> show (length everything) <> "\n")
    -- a second instance in the same file, written by both
    appendOutcome path "other" [begun 1 1] `shouldReturn` "ok 1"
    reference ["append", path, "other", encodedBatch [completed 1 2]] `shouldReturn` "ok 2\n"
    withSqliteHistoryStore path "shared" (Store.records . (.history)) `shouldReturn` everything
    withSqliteHistoryStore path "other" (Store.records . (.history)) `shouldReturn` [begun 1 1, completed 1 2]
    reference ["open", path, "other"] `shouldReturn` "ok 2\n"

  describe "verify-on-conflict answers agree on the same file" $ do
    let scenario :: String -> [[Record]] -> [Record] -> Spec
        scenario name prepared batch = it name $ withScratch $ \dir -> do
          let ours = dir </> "haskell.sqlite3"
              theirs = dir </> "reference.sqlite3"
          forM_ prepared $ \prior -> void (appendOutcome ours "one" prior)
          copyFile ours theirs
          -- both sides open the file with the full prepared history and
          -- append the batch from that (stale or current) view
          expected <- reference ["append", theirs, "one", encodedBatch batch]
          ourOutcome <- appendOutcome ours "one" batch
          ourOutcome `shouldBe` trimmed expected
          expectedRows <- dumped theirs
          dumped ours `shouldReturn` expectedRows
    scenario "an exact terminal re-sent is acknowledged without advancing" [[begun 1 1, completed 1 2]] [completed 1 2, produced 2 3]
    scenario "a different firing terminal is refused and the batch rolls back" [[begun 1 1, completed 1 2]] [produced 1 3, failed "different" 1 3]
    scenario "a different activity terminal is refused" [[begun 1 1, activityDone 1 "captured"]] [activityDone 1 "declined"]
    scenario "an equal activity terminal is acknowledged" [[begun 1 1, activityDone 1 "captured"]] [activityDone 1 "captured", completed 1 5]

  it "a stale writer's refusals agree across languages" $ withScratch $ \dir -> do
    let path = dir </> "history.sqlite3"
    withSqliteHistoryStore path "one" $ \stale -> do
      -- the reference wins position 0 behind this store's back
      reference ["append", path, "one", encodedBatch [begun 2 3]] `shouldReturn` "ok 1\n"
      outcome (stale.history.extend [produced 2 3] >> Store.size stale.history)
        `shouldReturn` "ValueError: event one:0 is already recorded as a different fact (stored FiringBegun, appending TokensProduced)"
      -- an exact retry of the reference's fact fills the position
      outcome (stale.history.extend [begun 2 3] >> Store.size stale.history) `shouldReturn` "ok 1"

  describe "refusals of foreign, unsupported and corrupt files have the same text" $ do
    let refused :: String -> (FilePath -> IO ()) -> Spec
        refused name prepare = it name $ withScratch $ \dir -> do
          let path = dir </> "history.sqlite3"
          prepare path
          expected <- reference ["open", path, "one"]
          openOutcome path "one" `shouldReturn` asRefusal (trimmed expected)
        initializedWith path statements = do
          withSqliteHistoryStore path "one" $ \store -> Store.append store.history (begun 1 1)
          rawExec path statements
    forM_ [0 :: Int, 2] $ \version ->
      refused ("unsupported version " <> show version) $ \path ->
        rawExec
          path
          [ "CREATE TABLE impetus_history_schema (component TEXT PRIMARY KEY, version INTEGER NOT NULL)"
          , "INSERT INTO impetus_history_schema VALUES ('history', " <> T.pack (show version) <> ")"
          ]
    refused "two metadata rows" $ \path ->
      rawExec
        path
        [ "CREATE TABLE impetus_history_schema (component TEXT, version INTEGER)"
        , "INSERT INTO impetus_history_schema VALUES ('history', 1), ('history', 1)"
        ]
    refused "a foreign metadata shape" $ \path -> rawExec path ["CREATE TABLE impetus_history_schema (name TEXT)"]
    refused "an unversioned known shape" $ \path -> rawExec path ["CREATE TABLE impetus_history_events (payload TEXT)"]
    refused "a metadata view" $ \path -> rawExec path ["CREATE VIEW impetus_history_schema AS SELECT 'history' AS component, 1 AS version"]
    refused "a weakened terminal index" $ \path ->
      initializedWith
        path
        [ "DROP INDEX impetus_history_one_activity_terminal"
        , "CREATE INDEX impetus_history_one_activity_terminal ON impetus_history_events (instance, occurrence)"
        ]
    refused "an extra object in the namespace" $ \path -> initializedWith path ["CREATE TABLE impetus_history_extra (x)"]
    refused "a whitespace and case variant of the DDL is accepted" $ \path ->
      initializedWith
        path
        [ "DROP INDEX impetus_history_one_firing_terminal"
        , "create   unique index impetus_history_one_firing_terminal on impetus_history_events (instance, occurrence) where record_type in ('FiringCompleted', 'FiringFailed')"
        ]
    refused "a gap" $ \path -> initializedWith path ["UPDATE impetus_history_events SET position = 2, event_id = 'one:2'"]
    refused "a foreign event identity" $ \path -> initializedWith path ["UPDATE impetus_history_events SET event_id = 'two:0'"]
    refused "an undecodable payload" $ \path -> initializedWith path ["UPDATE impetus_history_events SET payload = '{broken'"]
    refused "an empty payload" $ \path -> initializedWith path ["UPDATE impetus_history_events SET payload = ''"]
    refused "a non-text payload" $ \path -> initializedWith path ["UPDATE impetus_history_events SET payload = 5"]
    forM_ ["null", "1.5", "true", "\"\"", "\"ab\"", "[]", "[1]", "[[1, 2, 3]]", "[{}]", "[[[1], 2]]", "[[{}, 2]]", "[[1, 2]]", "[\"ab\", [\"x\", 1]]", "[[\"record\", \"FiringBegun\"], [1, 2]]", "[[\"record\", \"FiringBegun\"], [\"schema\", 5], [1, 2]]", "[[1, 2], [\"record\", \"Nope\"], [\"schema\", 5]]", "[[\"record\", \"FiringBegun\"], [\"schema\", 5], [\"transition\", \"t\"], [\"occurrence\", 1], [\"scope\", null], [\"instant\", 1]]"] $ \json ->
      refused ("a stored payload that is not an object: " <> json) $ \path ->
        initializedWith path ["UPDATE impetus_history_events SET payload = '" <> T.pack json <> "'"]
    refused "a payload of another schema" $ \path ->
      initializedWith path ["UPDATE impetus_history_events SET payload = '{\"record\":\"FiringBegun\",\"schema\":2,\"transition\":\"t\",\"occurrence\":1,\"scope\":null,\"instant\":1}'"]
    refused "a corrupt record type" $ \path -> initializedWith path ["UPDATE impetus_history_events SET record_type = 'FiringCompleted'"]
    refused "a corrupt occurrence" $ \path -> initializedWith path ["UPDATE impetus_history_events SET occurrence = 2"]
    refused "a NULL occurrence where the record has one" $ \path -> initializedWith path ["UPDATE impetus_history_events SET occurrence = NULL"]
    refused "a REAL occurrence equal to the record's is accepted" $ \path -> initializedWith path ["UPDATE impetus_history_events SET occurrence = 1.0"]

  it "an empty instance id is refused with the same text" $ withScratch $ \dir -> do
    expected <- reference ["open", dir </> "history.sqlite3", ""]
    openOutcome (dir </> "history.sqlite3") "" `shouldReturn` trimmed expected

  it "first initialization under concurrent reference processes and Haskell threads" $ withScratch $ \dir -> do
    let path = dir </> "race.sqlite3"
        pythons = ["py-" <> show n | n <- [1 :: Int .. 3]]
        haskells = ["hs-" <> T.pack (show n) | n <- [1 :: Int .. 3]]
    go <- newEmptyMVar
    finished <- forM haskells $ \instanceId -> do
      done <- newEmptyMVar
      _ <- forkIO $ do
        readMVar go
        try (withSqliteHistoryStore path instanceId (const (pure ()))) >>= putMVar done
      pure done
    -- every reference process is ready before any side is released
    let ready [] processes = do
          mapM_ (`sendLine` "") processes
          putMVar go ()
          answers <- mapM readLine processes
          threads <- mapM takeMVar finished
          pure (answers, threads)
        ready (name : more) processes = withReference ["race", path, name] $ \process -> do
          expectLine process "ready"
          ready more (process : processes)
    (answers, threads) <- ready pythons []
    answers `shouldBe` replicate (length pythons) "ok None"
    forM_ threads $ \case
      Right () -> pure ()
      Left (failure :: SomeException) -> expectationFailure (show failure)
    reference ["open", path, "py-1"] `shouldReturn` "ok 0\n"

  it "an Instance the reference began resumes in Haskell and the reference reads the result" $ withScratch $ \dir -> do
    let path = dir </> "history.sqlite3"
    void (reference ["begin", path])
    count <- withSqliteHistoryStore path "interop-1" $ \store -> do
      resumed <- resume activityNet store.history (config False) >>= expectRight
      [occurrence] <- inFlight resumed
      _ <- recordActivityCompletion resumed occurrence (Object [("status", String "captured")]) (Just 3) >>= expectRight
      _ <- complete resumed occurrence Nothing (Just 4) >>= expectRight
      marking resumed `shouldReturn` receipt
      Store.size (instanceHistory resumed)
    reference ["inspect", path] `shouldReturn` (BC.pack (show count) <> "\n")

  it "an Instance Haskell began resumes in the reference and Haskell reads the result" $ withScratch $ \dir -> do
    let path = dir </> "history.sqlite3"
    withSqliteHistoryStore path "interop-1" $ \store -> do
      inst <- newInstance activityNet (config True) {historyStore = Just store.history, suppliedIdentity = Just "interop-1"} >>= expectRight
      DeliveryAccepted accepted <- acceptDelivery inst intake [tokD "Payment" (Object [("amount", Int 100)])] "evt_123" Nothing (Just 1) >>= expectRight
      _ <- completeDelivery inst accepted (Just 1) >>= expectRight
      (b : _) <- candidates inst
      void (begin inst b (Just 2) >>= expectRight)
    void (reference ["finish", path])
    withSqliteHistoryStore path "interop-1" $ \store -> do
      back <- resume activityNet store.history (config False) >>= expectRight
      marking back `shouldReturn` receipt
      watermark back `shouldReturn` 4
      inFlight back `shouldReturn` []
