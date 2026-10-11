module Main (main) where

import Test.Hspec (hspec)
import TierBSpec qualified
import TierCSpec qualified

main :: IO ()
main = hspec (TierBSpec.spec >> TierCSpec.spec)
