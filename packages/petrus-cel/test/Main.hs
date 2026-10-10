module Main (main) where

import Test.Hspec

import Corpus qualified
import Impetus qualified

main :: IO ()
main = do
  corpus <- Corpus.load
  hspec $ do
    Corpus.spec corpus
    Impetus.spec
