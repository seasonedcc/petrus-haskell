module Main (main) where

import Petrus.Engine.InteropSpec qualified as Interop
import Test.Hspec

main :: IO ()
main = hspec Interop.spec
