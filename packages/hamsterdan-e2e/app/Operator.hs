-- | @hamsterdan-e2e-operator FIXTURE.json <operator arguments>@: the
-- Haskell @hamsterdan-operator@ acting on a tier C fixture instead of
-- HBNetwork's (the twin of @python/e2e_operator.py@).
module Main (main) where

import Data.Text qualified as T
import Hamsterdan.E2E.Fixture (fixtureOperator, readFixture)
import Hamsterdan.Operator (OperatorEnvironment (..), productionEnvironment, runOperator)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main =
  getArgs >>= \case
    path : arguments -> do
      configured <- readFixture path
      env <- productionEnvironment
      runOperator env {operator = fixtureOperator configured} (map T.pack arguments) >>= exitWith
    [] -> hPutStrLn stderr "usage: hamsterdan-e2e-operator FIXTURE.json <operator arguments>" >> exitWith (ExitFailure 2)
