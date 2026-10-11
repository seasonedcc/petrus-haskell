module Main (main) where

import BindingSpec qualified
import RunnableSpec qualified
import TimersSpec qualified
import IngressSpec qualified
import GatesSpec qualified
import RerunSpec qualified
import ReviewSpec qualified
import GitPublishSpec qualified
import MutationSpec qualified
import IngressApplicationSpec qualified
import InlineRecoverySpec qualified
import ServiceSpec qualified
import ApiSpec qualified
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
  MutationSpec.spec
  IngressApplicationSpec.spec
  InlineRecoverySpec.spec
  ServiceSpec.spec
  ApiSpec.spec
