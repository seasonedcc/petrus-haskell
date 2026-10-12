-- | @python -m hamsterdan.operator@.
module Main (main) where

import GHC.IO.Encoding (mkTextEncoding, setForeignEncoding)
import Hamsterdan.Operator (productionEnvironment, runOperator)
import Petrus.Argparse (getArguments)
import System.Exit (exitWith)

-- | @sys.argv@ is decoded with @surrogateescape@ ('getArguments'), so an
-- undecodable byte stays a lone surrogate. The process library encodes
-- what it hands to @exec@ with the foreign encoding; its round-tripping
-- variant turns such a surrogate back into its byte, as @os.fsencode@
-- does.
main :: IO ()
main = do
  mkTextEncoding "UTF-8//ROUNDTRIP" >>= setForeignEncoding
  env <- productionEnvironment
  argv <- getArguments
  runOperator env argv >>= exitWith
