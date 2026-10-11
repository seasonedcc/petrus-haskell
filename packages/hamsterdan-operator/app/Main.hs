-- | @python -m hamsterdan.operator@.
module Main (main) where

import GHC.IO.Encoding (mkTextEncoding, setForeignEncoding)
import Hamsterdan.Operator (productionEnvironment, runOperator)
import Petrus.Json.Python (fsDecode)
import System.Exit (exitWith)
import System.Posix.Env.ByteString (getArgs)

-- | @sys.argv@ is decoded with @surrogateescape@, so an undecodable byte
-- stays a lone surrogate. The process library encodes what it hands to
-- @exec@ with the foreign encoding; its round-tripping variant turns such
-- a surrogate back into its byte, as @os.fsencode@ does.
main :: IO ()
main = do
  mkTextEncoding "UTF-8//ROUNDTRIP" >>= setForeignEncoding
  env <- productionEnvironment
  argv <- map fsDecode <$> getArgs
  runOperator env argv >>= exitWith
