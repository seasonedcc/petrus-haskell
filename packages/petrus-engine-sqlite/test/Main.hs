module Main (main) where

import Petrus.Engine.SqliteInteropSpec qualified as Interop
import Petrus.Engine.SqliteSpec qualified as Sqlite
import Petrus.Engine.SqliteSupport (roleVariable, runRole)
import System.Environment (getArgs, lookupEnv)
import Test.Hspec

-- | The suite, or — re-executed by the contention tests with
-- 'roleVariable' set — one holder or contender process.
main :: IO ()
main =
  lookupEnv roleVariable >>= \case
    Just role -> getArgs >>= runRole role
    Nothing -> hspec $ do
      Sqlite.spec
      Interop.spec
