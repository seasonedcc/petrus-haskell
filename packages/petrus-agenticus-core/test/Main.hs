module Main (main) where

import Petrus.Agenticus.CatalogSpec qualified
import Petrus.Agenticus.EffectSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  Petrus.Agenticus.CatalogSpec.spec
  Petrus.Agenticus.EffectSpec.spec
