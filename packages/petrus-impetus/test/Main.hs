module Main (main) where

import Petrus.Impetus.ArcFiltersSpec qualified as ArcFiltersSpec
import Petrus.Impetus.DotSpec qualified as DotSpec
import Petrus.Impetus.EnablednessSpec qualified as EnablednessSpec
import Petrus.Impetus.FiringSpec qualified as FiringSpec
import Petrus.Impetus.MarkingSpec qualified as MarkingSpec
import Petrus.Impetus.SchemaSpec qualified as SchemaSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  SchemaSpec.spec
  MarkingSpec.spec
  EnablednessSpec.spec
  ArcFiltersSpec.spec
  FiringSpec.spec
  DotSpec.spec
