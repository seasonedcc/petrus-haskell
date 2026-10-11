-- | @python -m hamsterdan.host.export@.
module Main (main) where

import Hamsterdan.Export (productionEnvironment, runExport)
import Petrus.Json.Python (fsDecode)
import System.Exit (exitWith)
import System.Posix.Env.ByteString (getArgs)

-- | The arguments are decoded as CPython decodes @sys.argv@: UTF-8 with
-- @surrogateescape@, so an undecodable byte names the same file again.
main :: IO ()
main = do
  env <- productionEnvironment
  argv <- map fsDecode <$> getArgs
  runExport env argv >>= exitWith
