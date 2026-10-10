-- | @petrus-golden-traces OUTPUT_DIRECTORY@: regenerate the Impetus-native
-- golden trace corpus (every fixture plus @manifest.json@) through the
-- Haskell kernel. The output is byte-identical to the reference's
-- @scripts/gen-golden-traces.py@, so regenerating into @spec/traces@ of the
-- pinned checkout leaves it unchanged:
--
-- > cabal run petrus-golden-traces -- upstream/petrus/spec/traces
module Main (main) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Petrus.Impetus.GoldenTraces (GoldenFile (..), generateCorpus)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, getProgName)
import System.Exit (die)
import System.FilePath ((</>))

main :: IO ()
main =
  getArgs >>= \case
    [output] -> do
      createDirectoryIfMissing True output
      files <- either (die . T.unpack) pure =<< generateCorpus
      let fixtures = filter (\f -> f.file /= "manifest.json") files
      forM_ files $ \f -> do
        BS.writeFile (output </> f.file) f.bytes
        if f.file == "manifest.json"
          then pure ()
          else putStrLn ("wrote " <> f.file <> " (" <> show f.walkSteps <> " steps)")
      putStrLn ("manifest: " <> show (length fixtures) <> " Impetus-native fixtures")
    _ -> do
      name <- getProgName
      die ("usage: " <> name <> " OUTPUT_DIRECTORY")
