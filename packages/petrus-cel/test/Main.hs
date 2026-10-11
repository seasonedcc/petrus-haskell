module Main (main) where

import Test.Hspec

import Corpus qualified
import Impetus qualified
import KernelSeam qualified
import Live qualified
import Properties qualified

main :: IO ()
main = do
  corpus <- Corpus.load
  hspec $ do
    Corpus.spec corpus
    Impetus.spec
    KernelSeam.spec
    Live.spec
    Properties.spec
