module Main (main) where

import Petrus.Engine.Postgres.InteropSpec qualified as Interop
import Petrus.Engine.PostgresSpec qualified as Postgres
import Test.Hspec

main :: IO ()
main = hspec $ do
  Postgres.spec
  Interop.spec
