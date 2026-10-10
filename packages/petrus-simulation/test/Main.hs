module Main (main) where

import CorpusSpec qualified
import HttpSpec qualified
import PythonClientSpec qualified
import RunnerSpec qualified
import Test.Hspec
import WireSpec qualified

main :: IO ()
main = hspec $ do
  RunnerSpec.spec
  HttpSpec.spec
  WireSpec.spec
  CorpusSpec.spec
  PythonClientSpec.spec
