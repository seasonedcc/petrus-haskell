module Main (main) where

import Petrus.Testing.Dst.Runner (processChildHook)
import Spec.Choice qualified
import Spec.Codec qualified
import Spec.Properties qualified
import Spec.Runner qualified
import Spec.Stories qualified
import Spec.Transcript qualified
import Test.Hspec

main :: IO ()
main = do
  processChildHook Spec.Runner.entrypoints
  hspec $ do
    Spec.Choice.spec
    Spec.Codec.spec
    Spec.Stories.spec
    Spec.Runner.spec
    Spec.Transcript.spec
    Spec.Properties.spec
