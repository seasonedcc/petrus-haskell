module Main (main) where

import Petrus.Impetus.SchemaSpec qualified as SchemaSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  SchemaSpec.spec
