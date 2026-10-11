-- | @python -m hamsterdan.host@: the standalone host command line.
module Main (main) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Hamsterdan.Host.Cli (productionEnvironment, runCli)
import System.Environment (getArgs, getEnvironment)
import System.Exit (exitWith)

main :: IO ()
main = do
  environment <- Map.fromList <$> getEnvironment
  arguments <- map T.pack <$> getArgs
  runCli (productionEnvironment environment) arguments >>= exitWith
