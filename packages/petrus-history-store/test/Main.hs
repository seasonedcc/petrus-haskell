module Main (main) where

import Petrus.HistoryStore.BackendContractSpec qualified as BackendContract
import Petrus.HistoryStore.InteropSpec qualified as Interop
import Petrus.HistoryStore.JsonlSpec qualified as Jsonl
import Petrus.HistoryStore.SqliteInteropSpec qualified as SqliteInterop
import Petrus.HistoryStore.SqliteSpec qualified as Sqlite
import Test.Hspec

main :: IO ()
main = hspec $ do
  Jsonl.spec
  BackendContract.spec
  Interop.spec
  Sqlite.spec
  SqliteInterop.spec
