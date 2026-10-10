module Main (main) where

import BindingSpec qualified
import RunnableSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  BindingSpec.spec
  RunnableSpec.spec
