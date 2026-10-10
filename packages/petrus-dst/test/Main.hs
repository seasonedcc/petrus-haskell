module Main (main) where

import Petrus.Testing.Dst.Runner (processChildHook)
import Spec.Stories qualified
import Test.Hspec

main :: IO ()
main = do
  processChildHook mempty
  hspec $ do
    Spec.Stories.spec
