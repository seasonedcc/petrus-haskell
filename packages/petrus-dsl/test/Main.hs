module Main (main) where

import Petrus.Impetus.DslCorpusSpec qualified as DslCorpusSpec
import Petrus.Impetus.DslSpec qualified as DslSpec
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  DslSpec.spec
  DslCorpusSpec.spec
