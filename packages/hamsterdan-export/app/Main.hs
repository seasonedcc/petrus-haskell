-- | @python -m hamsterdan.host.export@.
module Main (main) where

import Hamsterdan.Export (productionEnvironment, runExport)
import Petrus.Argparse (getArguments)
import System.Exit (exitWith)

-- | The arguments are decoded as CPython decodes @sys.argv@
-- ('getArguments'), so an undecodable byte names the same file again.
main :: IO ()
main = do
  env <- productionEnvironment
  argv <- getArguments
  runExport env argv >>= exitWith
