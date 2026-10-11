-- | @python -m hamsterdan.operator@.
module Main (main) where

import Data.Text qualified as T
import Hamsterdan.Operator (productionEnvironment, runOperator)
import System.Environment (getArgs)
import System.Exit (exitWith)

main :: IO ()
main = do
  env <- productionEnvironment
  argv <- map T.pack <$> getArgs
  runOperator env argv >>= exitWith
