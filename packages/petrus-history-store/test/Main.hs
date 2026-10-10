module Main (main) where

import Petrus.HistoryStore.BackendContractSpec qualified as BackendContract
import Petrus.HistoryStore.InteropSpec qualified as Interop
import Petrus.HistoryStore.JsonlSpec qualified as Jsonl
import Test.Hspec

main :: IO ()
main = hspec $ do
  Jsonl.spec
  BackendContract.spec
  Interop.spec
