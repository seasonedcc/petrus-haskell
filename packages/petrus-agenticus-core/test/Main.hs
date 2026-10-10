module Main (main) where

import Petrus.Agenticus.CatalogSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  Petrus.Agenticus.CatalogSpec.spec
