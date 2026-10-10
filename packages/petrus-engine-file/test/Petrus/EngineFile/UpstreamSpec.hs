-- | petrus-engine's @tests/test_json_formatter.py@, which calls
-- @compact_json@ directly with its own key orders. (The loader, file-ref,
-- resolution and timed-transition tests are corpus cases under
-- @upstream/...@, checked against the reference's recorded results.)
module Petrus.EngineFile.UpstreamSpec (spec) where

import Petrus.EngineFile.Encode (compactJsonWith)
import Petrus.EngineFile.Value (Value (..))
import Test.Hspec

spec :: Spec
spec = describe "upstream tests/test_json_formatter.py" $ do
  it "orders root and nested keys" $
    compactJsonWith
      2
      100
      ["a", "b", "netSchema"]
      ["source", "target"]
      (VDict [("netSchema", VDict [("z", VInt 0 False), ("target", VStr "t"), ("source", VStr "s")]), ("b", VInt 1 False), ("a", VInt 2 False)])
      `shouldBe` Right "{\n  \"a\": 2,\n  \"b\": 1,\n  \"netSchema\": {\"source\": \"s\", \"target\": \"t\", \"z\": 0}\n}\n"

  it "breaks containers with nested values into multiple lines" $
    compactJsonWith 2 100 [] [] (VList [VDict [("a", VInt 1 False)]])
      `shouldBe` Right "[\n  {\"a\": 1}\n]\n"

  it "converts whole number floats to ints" $
    compactJsonWith 2 100 [] [] (VDict [("a", VFloat 1.0), ("b", VFloat 1.5)])
      `shouldBe` Right "{\"a\": 1, \"b\": 1.5}\n"
