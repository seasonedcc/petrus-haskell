module Main (main) where

import Petrus.HistoryStore.Postgres.BoundarySpec qualified as Boundary
import Petrus.HistoryStore.Postgres.InteropSpec qualified as Interop
import Petrus.HistoryStore.PostgresSpec qualified as Postgres
import Test.Hspec

main :: IO ()
main = hspec $ do
  Postgres.spec
  Interop.spec
  Boundary.spec
