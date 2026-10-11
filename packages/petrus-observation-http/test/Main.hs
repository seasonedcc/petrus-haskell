module Main (main) where

import PythonClientSpec qualified
import Test.Hspec
import UpstreamSpec qualified
import WireSpec qualified

main :: IO ()
main = hspec $ do
  UpstreamSpec.spec
  WireSpec.spec
  PythonClientSpec.spec
