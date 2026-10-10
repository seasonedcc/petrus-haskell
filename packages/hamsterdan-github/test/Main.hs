module Main (main) where

import AppFoundationSpec qualified
import ConfigCorpusSpec qualified
import Test.Hspec (hspec)
import WebhookCorpusSpec qualified

main :: IO ()
main = hspec $ do
  AppFoundationSpec.spec
  ConfigCorpusSpec.spec
  WebhookCorpusSpec.spec
