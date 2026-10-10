module Main (main) where

import ArchiveSpec qualified
import System.Posix.Files (setFileCreationMask)
import Test.Hspec

main :: IO ()
main = do
  -- Extraction fixtures were generated under umask 022.
  _ <- setFileCreationMask 0o022
  hspec $ do
    ArchiveSpec.spec
