module Main (main) where

import Petrus.Impetus.ArcFiltersSpec qualified as ArcFiltersSpec
import Petrus.Impetus.DotSpec qualified as DotSpec
import Petrus.Impetus.EnablednessSpec qualified as EnablednessSpec
import Petrus.Impetus.FifoQueueSpec qualified as FifoQueueSpec
import Petrus.Impetus.FiringSpec qualified as FiringSpec
import Petrus.Impetus.GoldenTracesSpec qualified as GoldenTracesSpec
import Petrus.Impetus.KernelDifferentialSpec qualified as KernelDifferentialSpec
import Petrus.Impetus.MarkingSpec qualified as MarkingSpec
import Petrus.Impetus.NetDefinitionCorpusSpec qualified as NetDefinitionCorpusSpec
import Petrus.Impetus.NetDefinitionPropertiesSpec qualified as NetDefinitionPropertiesSpec
import Petrus.Impetus.NetDefinitionSpec qualified as NetDefinitionSpec
import Petrus.Impetus.NetDocumentLineageSpec qualified as NetDocumentLineageSpec
import Petrus.Impetus.NetDocumentSpec qualified as NetDocumentSpec
import Petrus.Impetus.SchemaSpec qualified as SchemaSpec
import Petrus.Impetus.SpecFixturesSpec qualified as SpecFixturesSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  SchemaSpec.spec
  MarkingSpec.spec
  EnablednessSpec.spec
  ArcFiltersSpec.spec
  FiringSpec.spec
  DotSpec.spec
  FifoQueueSpec.spec
  NetDefinitionSpec.spec
  NetDocumentSpec.spec
  NetDocumentLineageSpec.spec
  SpecFixturesSpec.spec
  NetDefinitionPropertiesSpec.spec
  NetDefinitionCorpusSpec.spec
  GoldenTracesSpec.spec
  KernelDifferentialSpec.spec
