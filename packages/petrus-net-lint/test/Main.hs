module Main (main) where

import LintSpec qualified
import Test.Hspec

main :: IO ()
main = hspec LintSpec.spec
