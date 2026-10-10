module Main (main) where

import Petrus.Observation.CorpusSpec qualified as CorpusSpec
import Petrus.Observation.ObservationSpec qualified as ObservationSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  ObservationSpec.spec
  CorpusSpec.spec
