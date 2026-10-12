-- | @python -m hamsterdan.host@: the standalone host command line.
module Main (main) where

import Data.Map.Strict qualified as Map
import Hamsterdan.Host.Cli (productionEnvironment, runCli)
import Petrus.Argparse (getArguments)
import System.Environment (getEnvironment)
import System.Exit (exitWith)

main :: IO ()
main = do
  environment <- Map.fromList <$> getEnvironment
  arguments <- getArguments
  runCli (productionEnvironment environment) arguments >>= exitWith
