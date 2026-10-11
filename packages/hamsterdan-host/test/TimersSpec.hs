-- | @tests/unit/host/test_v5_timers.py@.
module TimersSpec (spec) where

import Control.Exception (SomeException, fromException)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite3 qualified as S
import Hamsterdan.Contracts.Codec (dump, validate)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.GitHub.Sqlite (SQLData (..))
import Hamsterdan.GitHub.Sqlite qualified as Sql
import Hamsterdan.Host.Python (RuntimeError (..), ValueError (..))
import Hamsterdan.Host.V5.Timers qualified as T5
import Petrus.Activity (Number (..))
import Petrus.Impetus.History.Records (ExternalEventDelivered (..), Record (..))
import Petrus.Impetus.Petrinet.Marking (Token (..))
import Petrus.Impetus.Petrinet.Schema (netPath)
import Petrus.Json (Json (..))
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Hspec
import TestSupport

subject :: Text
subject = "github:44:31:pr:7"

timer :: Integer -> Integer -> Text -> ReminderTimer
timer incarnation sequence' head' =
  ReminderTimer
    { id = "timer:" <> subject <> ":i" <> tshow incarnation <> ":s" <> tshow sequence'
    , incarnation
    , sequence = sequence'
    , head = head'
    }

tshow :: (Show a) => a -> Text
tshow = T.pack . show

operation :: Integer -> Text
operation generation = "timer-command:" <> subject <> ":g" <> tshow generation

arm :: Integer -> ReminderTimer -> Integer -> TimerCommand
arm generation value delay =
  TimerCommand {operation = operation generation, command = CommandArm ArmReminder {timer = value, delayS = delay}}

cancel :: Integer -> ReminderTimer -> TimerCommand
cancel generation value =
  TimerCommand {operation = operation generation, command = CommandCancel CancelReminder {timer = value, reason = "draft"}}

armedFact :: Integer -> ReminderTimer -> Text -> TimerCommandApplied
armedFact generation value due =
  TimerCommandApplied {operation = operation generation, result = ResultArmed TimerArmed {timer = value, dueAt = due}}

clockRef :: Integer -> IO (IORef Integer, IO Integer)
clockRef start = do
  ref <- newIORef start
  pure (ref, readIORef ref)

open' :: FilePath -> [T5.TimerFact] -> Maybe TimerCommand -> IO T5.V5TimerStore
open' path facts outstanding = T5.openTimerStore path subject facts outstanding

withDb :: FilePath -> (S.Database -> IO a) -> IO a
withDb path use = do
  db <- S.open (T.pack path)
  result <- use db
  S.close db
  pure result

rows :: S.Database -> Text -> IO [[SQLData]]
rows db sql = do
  statement <- S.prepare db sql
  let go acc =
        S.step statement >>= \case
          S.Done -> pure (reverse acc)
          S.Row -> S.columns statement >>= \row -> go (row : acc)
  result <- go []
  S.finalize statement
  pure result

spec :: Spec
spec = describe "test_v5_timers" $ do
  it "test_exact_arm_replay_preserves_deadline_and_conflicting_payload_fails" . withTempRoot $ \tmp -> do
    (now, clock) <- clockRef 1000000
    store <- T5.openTimerStoreWith (tmp </> "timers.sqlite3") subject [] Nothing clock
    let command = arm 1 (timer 1 0 "h1") 10
    first <- T5.apply store command
    writeIORef now 9000000
    replayed <- T5.apply store command
    replayed `shouldBe` first
    case first.result of
      ResultArmed armed -> armed.dueAt `shouldBe` "1970-01-01T00:00:11.000000Z"
      other -> expectationFailure (show other)
    let conflicting = TimerCommand {operation = command.operation, command = CommandArm ArmReminder {timer = timer 1 1 "h1", delayS = 10}}
    T5.apply store conflicting `shouldThrow` runtimeError "different timer command"
    T5.close store

  it "test_new_arm_atomically_supersedes_and_stale_cancel_cannot_touch_it" . withTempRoot $ \tmp -> do
    (now, clock) <- clockRef 1000000
    let path = tmp </> "timers.sqlite3"
        old = timer 1 0 "h1"
        current = timer 2 0 "h2"
    store <- T5.openTimerStoreWith path subject [] Nothing clock
    _ <- T5.apply store (arm 1 old 10)
    T5.markAckDelivered store (operation 1)
    writeIORef now 2000000
    _ <- T5.apply store (arm 2 current 10)
    writeIORef now 3000000
    _ <- T5.apply store (cancel 3 old)
    states <- withDb path (`rows` "SELECT timer_id,state FROM v5_timers ORDER BY timer_id")
    states `shouldBe` [[SQLText old.id, SQLText "superseded"], [SQLText current.id, SQLText "armed"]]
    T5.nextDue store `shouldReturn` Just 12.0
    T5.close store

  it "test_ack_and_maturity_crash_markers_replay_exact_frozen_values" . withTempRoot $ \tmp -> do
    (now, clock) <- clockRef 1000000
    let path = tmp </> "timers.sqlite3"
    store <- T5.openTimerStoreWith path subject [] Nothing clock
    let command = arm 1 (timer 1 0 "h1") 1
    applied <- T5.apply store command
    T5.pendingAck store `shouldReturn` Just applied
    T5.close store
    reopened <- T5.openTimerStoreWith path subject [] (Just command) clock
    T5.pendingAck reopened `shouldReturn` Just applied
    T5.markAckDelivered reopened applied.operation
    T5.pendingAck reopened `shouldReturn` Nothing
    writeIORef now 2000000
    Just claimed <- T5.claimDue reopened
    claimed.value.maturedAt `shouldBe` "1970-01-01T00:00:02.000000Z"
    T5.close reopened
    replayed <- T5.openTimerStoreWith path subject [T5.FactApplied applied] Nothing clock
    T5.pendingMaturity replayed `shouldReturn` Just claimed
    T5.markMaturityDelivered replayed claimed.value.timer.id
    T5.pendingMaturity replayed `shouldReturn` Nothing
    T5.nextDue replayed `shouldReturn` Nothing
    T5.close replayed

  it "test_history_rebuild_recovers_acknowledged_deadline_and_maturity" . withTempRoot $ \tmp -> do
    let value = timer 1 0 "h1"
        armed = armedFact 1 value "2026-08-16T00:00:00.000000Z"
        due = TimerDue {timer = value, dueAt = "2026-08-16T00:00:00.000000Z", maturedAt = "2026-08-16T00:00:01.000000Z"}
    armedStore <- open' (tmp </> "armed.sqlite3") [T5.FactApplied armed] Nothing
    T5.nextDue armedStore `shouldReturn` Just 1786838400.0
    T5.close armedStore
    maturedStore <- open' (tmp </> "matured.sqlite3") [T5.FactApplied armed, T5.FactDue due] Nothing
    T5.nextDue maturedStore `shouldReturn` Nothing
    T5.pendingMaturity maturedStore `shouldReturn` Nothing
    T5.close maturedStore

  it "test_history_rebuild_recovers_outstanding_arm_when_its_ack_is_canonical" . withTempRoot $ \tmp -> do
    let command = arm 1 (timer 1 0 "h1") 10
        acknowledged = armedFact 1 (timer 1 0 "h1") "2026-08-16T00:00:00.000000Z"
    store <- open' (tmp </> "timers.sqlite3") [T5.FactApplied acknowledged] (Just command)
    T5.nextDue store `shouldReturn` Just 1786838400.0
    T5.close store

  it "test_semantically_corrupt_deadline_rebuilds_from_canonical_history" . withTempRoot $ \tmp -> do
    let path = tmp </> "timers.sqlite3"
    store <- T5.openTimerStoreWith path subject [] Nothing (pure 1000000)
    acknowledged <- T5.apply store (arm 1 (timer 1 0 "h1") 10)
    T5.markAckDelivered store acknowledged.operation
    T5.close store
    withDb path (`S.exec` "UPDATE v5_timers SET due_at_us=1000000")
    rebuilt <- open' path [T5.FactApplied acknowledged] Nothing
    T5.nextDue rebuilt `shouldReturn` Just 11.0
    doesFileExist (tmp </> "timers.sqlite3.corrupt") `shouldReturn` True
    T5.close rebuilt

  it "test_store_missing_new_history_generation_rebuilds_canonical_timer" . withTempRoot $ \tmp -> do
    let path = tmp </> "timers.sqlite3"
        first = armedFact 1 (timer 1 0 "h1") "2026-08-16T00:00:00.000000Z"
        second = armedFact 2 (timer 2 0 "h2") "2026-08-17T00:00:00.000000Z"
    open' path [T5.FactApplied first] Nothing >>= T5.close
    rebuilt <- open' path [T5.FactApplied first, T5.FactApplied second] Nothing
    T5.nextDue rebuilt `shouldReturn` Just 1786924800.0
    T5.close rebuilt

  it "test_missing_or_corrupt_store_with_unacknowledged_arm_fails_closed" . withTempRoot $ \tmp -> do
    let command = arm 1 (timer 1 0 "h1") 10
    open' (tmp </> "missing.sqlite3") [] (Just command) `shouldThrow` runtimeError "unacknowledged arm"
    BS.writeFile (tmp </> "corrupt.sqlite3") "not sqlite"
    open' (tmp </> "corrupt.sqlite3") [] (Just command) `shouldThrow` runtimeError "unacknowledged arm"

  it "test_unacknowledged_arm_failure_preserves_the_database_triplet" . withTempRoot $ \tmp -> do
    let path = tmp </> "timers.sqlite3"
        command = arm 1 (timer 1 0 "h1") 10
    store <- T5.openTimerStoreWith path subject [] Nothing (pure 1000000)
    _ <- T5.apply store command
    T5.close store
    withDb path (`S.exec` "CREATE TABLE incompatible(value TEXT)")
    open' path [] (Just command) `shouldThrow` runtimeError "unacknowledged arm"
    doesFileExist path `shouldReturn` True
    doesFileExist (tmp </> "timers.sqlite3.corrupt") `shouldReturn` False
    withDb path (`rows` "SELECT due_at_us FROM v5_timers") `shouldReturn` [[SQLInteger 11000000]]

  it "test_pending_arm_must_equal_the_net_command_and_preserves_its_deadline_on_failure" . withTempRoot $ \tmp -> do
    let path = tmp </> "timers.sqlite3"
        value = timer 1 0 "h1"
        stored = arm 1 value 1
    store <- T5.openTimerStoreWith path subject [] Nothing (pure 1000000)
    _ <- T5.apply store stored
    T5.close store
    open' path [] (Just (arm 1 value 2)) `shouldThrow` runtimeError "unacknowledged arm"
    preserved <- open' path [] (Just stored)
    T5.nextDue preserved `shouldReturn` Just 2.0
    T5.pendingAck preserved >>= (`shouldSatisfy` isJust)
    T5.close preserved

  it "test_pending_cancel_mismatch_rebuilds_before_the_net_command_applies" . withTempRoot $ \tmp -> do
    let path = tmp </> "timers.sqlite3"
        value = timer 1 0 "h1"
        armed = armedFact 1 value "1970-01-01T00:00:11.000000Z"
        stored = cancel 2 value
    store <- open' path [T5.FactApplied armed] Nothing
    _ <- T5.apply store stored
    T5.close store
    let outstanding = TimerCommand {operation = stored.operation, command = CommandCancel CancelReminder {timer = value, reason = "closed"}}
    rebuilt <- open' path [T5.FactApplied armed] (Just outstanding)
    T5.pendingAck rebuilt `shouldReturn` Nothing
    T5.nextDue rebuilt `shouldReturn` Just 11.0
    _ <- T5.apply rebuilt outstanding
    T5.nextDue rebuilt `shouldReturn` Nothing
    T5.close rebuilt

  it "test_failed_history_rebuild_does_not_leave_false_empty_custody" . withTempRoot $ \tmp -> do
    let path = tmp </> "timers.sqlite3"
        value = timer 1 0 "h1"
        invalid = armedFact 2 value "2026-08-16T00:00:00.000000Z"
        valid = armedFact 1 value "2026-08-16T00:00:00.000000Z"
    open' path [T5.FactApplied invalid] Nothing `shouldThrow` runtimeError "not contiguous"
    rebuilt <- open' path [T5.FactApplied valid] Nothing
    T5.nextDue rebuilt `shouldReturn` Just 1786838400.0
    T5.close rebuilt

  it "test_reopened_store_enforces_wal_and_foreign_keys" . withTempRoot $ \tmp -> do
    let path = tmp </> "timers.sqlite3"
    open' path [] Nothing >>= T5.close
    reopened <- open' path [] Nothing
    Sql.query (T5.storeConnection reopened) "PRAGMA journal_mode" [] `shouldReturn` [[SQLText "wal"]]
    Sql.query (T5.storeConnection reopened) "PRAGMA foreign_keys" [] `shouldReturn` [[SQLInteger 1]]
    T5.close reopened

  it "test_intact_armed_row_without_history_or_pending_ack_is_rebuilt_as_absent" . withTempRoot $ \tmp -> do
    let path = tmp </> "timers.sqlite3"
    store <- T5.openTimerStoreWith path subject [] Nothing (pure 1000000)
    applied <- T5.apply store (arm 1 (timer 1 0 "h1") 10)
    T5.markAckDelivered store applied.operation
    T5.close store
    reopened <- open' path [] Nothing
    T5.nextDue reopened `shouldReturn` Nothing
    T5.close reopened

  it "test_repeated_corruption_preserves_each_quarantined_database" . withTempRoot $ \tmp -> do
    let path = tmp </> "timers.sqlite3"
    BS.writeFile path "first corrupt database"
    open' path [] Nothing >>= T5.close
    BS.readFile (tmp </> "timers.sqlite3.corrupt") `shouldReturn` "first corrupt database"
    BS.writeFile path "second corrupt database"
    open' path [] Nothing >>= T5.close
    BS.readFile (tmp </> "timers.sqlite3.corrupt") `shouldReturn` "first corrupt database"
    BS.readFile (tmp </> "timers.sqlite3.corrupt.1") `shouldReturn` "second corrupt database"

  forM_ [0, -1, 2147483648] $ \delay ->
    it ("test_arm_delay_is_a_positive_bounded_integer[" <> show delay <> "]") . withTempRoot $ \tmp -> do
      store <- open' (tmp </> ("timers-" <> show delay <> ".sqlite3")) [] Nothing
      T5.apply store (arm 1 (timer 1 0 "h1") delay) `shouldThrow` \(e :: SomeException) ->
        case (fromException e, fromException e) of
          (Just (ValueError m), _) -> "delay" `T.isInfixOf` m
          (_, Just (RuntimeError m)) -> "delay" `T.isInfixOf` m
          _ -> False
      T5.close store

  it "test_arm_delay_contract_rejects_boolean" $ do
    let encoded = case dump ArmReminder {timer = timer 1 0 "h1", delayS = 1} of
          Object members -> Object [(k, if k == "delay_s" then Bool True else v) | (k, v) <- members]
          other -> other
    (validate @ArmReminder encoded) `shouldSatisfy` either (const True) (const False)

  let applied = armedFact 1 (timer 1 0 "h1") "1970-01-01T00:00:11.000000Z"
      due = TimerDue {timer = timer 1 0 "h1", dueAt = "1970-01-01T00:00:11.000000Z", maturedAt = "1970-01-01T00:00:12.000000Z"}
  forM_
    [ ("on_timer_command_applied", "TimerCommandApplied", dump applied)
    , ("on_timer", "TimerDue", dump due)
    ]
    $ \(source, color, fact) ->
      it ("test_timer_history_rejects_typed_fact_under_wrong_identity[" <> T.unpack source <> "]") $ do
        let path = either (error . show) id (netPath source)
            record =
              RExternalEventDelivered
                ExternalEventDelivered
                  { source = path
                  , tokens = [Token {color = Just color, payload = fact}]
                  , identity = "wrong-identity"
                  , occurrence = 1
                  , scope = Nothing
                  , instant = IntNumber 0
                  }
        T5.timerHistory [record] `shouldThrow` runtimeError "identity"
