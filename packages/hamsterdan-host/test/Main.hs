module Main (main) where

import BindingSpec qualified
import RunnableSpec qualified
import TimersSpec qualified
import IngressSpec qualified
import GatesSpec qualified
import RerunSpec qualified
import ReviewSpec qualified
import GitPublishSpec qualified
import Test.Hspec

main :: IO ()
main = hspec $ do
  BindingSpec.spec
  RunnableSpec.spec
  TimersSpec.spec
  IngressSpec.spec
  GatesSpec.spec
  RerunSpec.spec
  ReviewSpec.spec
  GitPublishSpec.spec
