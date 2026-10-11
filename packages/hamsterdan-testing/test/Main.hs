module Main (main) where

import OracleCorpusSpec qualified
import ReadinessCampaignSpec qualified
import ReadinessCoverageSpec qualified
import ReadinessModelSpec qualified
import ReadinessScenariosSpec qualified
import ReadinessWorldSpec qualified
import WorldInteropSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  ReadinessModelSpec.spec
  OracleCorpusSpec.spec
  ReadinessScenariosSpec.spec
  ReadinessWorldSpec.spec
  ReadinessCampaignSpec.spec
  ReadinessCoverageSpec.spec
  WorldInteropSpec.spec
