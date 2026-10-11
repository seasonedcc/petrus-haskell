-- | @python -m hamsterdan.host.export@.
module Main (main) where

import Data.Text qualified as T
import Hamsterdan.Export (productionEnvironment, runExport)
import System.Environment (getArgs)
import System.Exit (exitWith)

main :: IO ()
main = do
  env <- productionEnvironment
  argv <- map T.pack <$> getArgs
  runExport env argv >>= exitWith
