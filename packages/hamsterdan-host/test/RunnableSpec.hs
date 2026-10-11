-- | @tests/unit/host/test_runnable.py@.
module RunnableSpec (spec) where

import Control.Monad (forM_)
import Data.Text qualified as T
import Database.SQLite3 qualified as S
import Hamsterdan.Host.Runnable qualified as R
import System.Directory (doesFileExist, listDirectory)
import System.FilePath ((</>))
import Data.ByteString qualified as BS
import Data.List (isSuffixOf)
import Test.Hspec
import TestSupport

spec :: Spec
spec = describe "test_runnable" $ do
  it "test_wakes_coalesce_and_due_instances_are_taken_deterministically" . withTempRoot $ \tmp -> do
    index <- R.openRunnableIndexWith (tmp </> "runnable.sqlite3") (pure 10)
    R.wake index "instance-b" 3 "webhook" "delivery"
    R.wake index "instance-a" 2 "webhook" "delivery"
    R.wake index "instance-a" 1 "webhook" "delivery"
    R.wake index "instance-c" 11 "webhook" "delivery"
    R.count index `shouldReturn` 3
    R.nextDue index `shouldReturn` Just 1
    R.takeDue index 100 `shouldReturn` ["instance-a", "instance-b"]
    R.nextDue index `shouldReturn` Just 11
    R.takeDue index 100 `shouldReturn` []
    R.takeDueAt index 100 11 `shouldReturn` ["instance-c"]
    R.nextDue index `shouldReturn` Nothing
    R.close index

  it "test_wake_added_after_take_is_not_lost_and_reopen_is_durable" . withTempRoot $ \tmp -> do
    let path = tmp </> "runnable.sqlite3"
    first <- R.openRunnableIndex path
    R.wake first "instance" 0 "webhook" "one"
    R.takeDueAt first 100 0 `shouldReturn` ["instance"]
    R.wake first "instance" 0 "webhook" "two"
    R.close first
    second <- R.openRunnableIndex path
    R.takeDueAt second 100 0 `shouldReturn` ["instance"]
    R.close second

  forM_ ["bytes", "schema"] $ \damage ->
    it ("test_disposable_index_recovers_from_corruption_or_incompatible_schema[" <> damage <> "]") . withTempRoot $ \tmp -> do
      let path = tmp </> "runnable.sqlite3"
      if damage == "bytes"
        then BS.writeFile path "not a sqlite database"
        else do
          db <- S.open (T.pack path)
          S.exec db "CREATE TABLE wakes (wrong TEXT)"
          S.close db
      index <- R.openRunnableIndex path
      R.wake index "instance" 0 "repair" "recovered"
      R.takeDueAt index 100 0 `shouldReturn` ["instance"]
      doesFileExist (tmp </> "runnable.sqlite3.corrupt") `shouldReturn` True
      R.close index

  it "test_repeated_recovery_keeps_only_one_bounded_quarantine" . withTempRoot $ \tmp -> do
    let path = tmp </> "runnable.sqlite3"
    BS.writeFile path "first"
    R.openRunnableIndex path >>= R.close
    BS.writeFile path "second"
    R.openRunnableIndex path >>= R.close
    names <- listDirectory tmp
    filter (".corrupt" `isSuffixOf`) names `shouldBe` ["runnable.sqlite3.corrupt"]

  it "test_timer_is_replaced_and_cancelled_without_disturbing_other_wakes" . withTempRoot $ \tmp -> do
    index <- R.openRunnableIndex (tmp </> "runnable.sqlite3")
    R.wake index "instance" 5 "activity-terminal" "publish"
    R.replaceTimer index "instance" (Just 20)
    R.replaceTimer index "instance" (Just 30)
    R.takeDueAt index 100 5 `shouldReturn` ["instance"]
    R.takeDueAt index 100 20 `shouldReturn` []
    R.cancelTimer index "instance"
    R.takeDueAt index 100 100 `shouldReturn` []
    R.close index

  forM_ [("", "empty"), (T.replicate 257 "x", "long")] $ \(value, label) ->
    it ("test_identifiers_are_nonempty_and_bounded[" <> label <> "]") . withTempRoot $ \tmp -> do
      index <- R.openRunnableIndex (tmp </> "runnable.sqlite3")
      R.wake index value 0 "kind" "identity" `shouldThrow` valueError "bounded identifier"
      R.close index

  forM_ [(1 / 0, "inf"), (-1 / 0, "-inf"), (0 / 0, "nan")] $ \(due, label) ->
    it ("test_due_time_must_be_finite[" <> label <> "]") . withTempRoot $ \tmp -> do
      index <- R.openRunnableIndex (tmp </> "runnable.sqlite3")
      R.wake index "instance" due "kind" "identity" `shouldThrow` valueError "finite"
      R.close index
