module Main (main) where

import OracleCorpusSpec qualified
import ReadinessModelSpec qualified
import ReadinessScenariosSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  ReadinessModelSpec.spec
  OracleCorpusSpec.spec
  ReadinessScenariosSpec.spec
