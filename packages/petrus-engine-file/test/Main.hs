module Main (main) where

import Petrus.EngineFile.CliSpec qualified as CliSpec
import Petrus.EngineFile.CorpusSpec qualified as CorpusSpec
import Petrus.EngineFile.KernelSpec qualified as KernelSpec
import Petrus.EngineFile.LiveSpec qualified as LiveSpec
import Petrus.EngineFile.UpstreamSpec qualified as UpstreamSpec
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  UpstreamSpec.spec
  CorpusSpec.spec
  KernelSpec.spec
  LiveSpec.spec
  CliSpec.spec
