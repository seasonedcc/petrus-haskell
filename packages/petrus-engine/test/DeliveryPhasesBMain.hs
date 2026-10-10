module Main (main) where

import Petrus.Engine.DeliveryPhasesBSpec qualified as Area
import Test.Hspec

main :: IO ()
main = hspec Area.spec
