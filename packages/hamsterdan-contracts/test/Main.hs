module Main (main) where

import CodecSpec qualified
import CorpusSpec qualified
import ProtocolSpec qualified
import PyLiteralSpec qualified
import PyTextSpec qualified
import RoundTripSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  CodecSpec.spec
  PyLiteralSpec.spec
  CorpusSpec.spec
  ProtocolSpec.spec
  PyTextSpec.spec
  RoundTripSpec.spec
