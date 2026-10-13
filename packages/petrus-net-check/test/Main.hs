module Main (main) where

import CheckSpec qualified
import Test.Hspec

main :: IO ()
main = hspec CheckSpec.spec
