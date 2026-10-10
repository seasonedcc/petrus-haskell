-- | The fast canonical encoder ("Petrus.Fabric.Canonical") writes exactly
-- what CPython writes for @json.dumps(allow_nan=False, ensure_ascii=False,
-- sort_keys=True, separators=(",", ":"))@, and what petrus-json's general
-- encoder writes except for two classes of doubles where petrus-json's
-- 'floatToDigits' spelling is not CPython's repr:
--
-- * at least 2^53 with an even significand, where CPython admits a shorter
--   decimal on the rounding interval's end (@repr(1e23) == "1e+23"@;
--   'floatToDigits' spells @9.999999999999999e+22@);
-- * exact ties one digit past the shortest answer, which CPython breaks to
--   even (@repr(2**-25) == "2.9802322387695312e-08"@; 'floatToDigits'
--   spells @...313e-08@). These need @o * 2^k@ (@o@ odd) with
--   @-25 <= k <= 22@.
module Petrus.Fabric.CanonicalSpec (spec) where

import Data.Bits (countTrailingZeros, shiftL, (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Petrus.Fabric (canonicalBytes)
import Petrus.Fabric.Canonical (canonicalFast)
import Petrus.Json (Json (..), compact, dumps)
import Petrus.Json.Encode (EncodeOptions (..))
import Petrus.TestSupport (PythonResult (..), runPython)
import System.Exit (ExitCode (..))
import Test.Hspec
import Test.QuickCheck

general :: Json -> Maybe BS.ByteString
general = either (const Nothing) Just . dumps compact {sortKeys = True}

-- | Doubles where petrus-json's 'floatToDigits' spelling and CPython's
-- repr may differ (see the module header).
endAdmitted, shortDyadic, petrusJsonMayDiffer :: Double -> Bool
endAdmitted d = abs d >= 2 ^ (53 :: Int) && even (fst (decodeFloat d))
shortDyadic d =
  let (m, e) = decodeFloat (abs d)
      zeros = if m == 0 then 0 else countTrailingZeros (fromInteger m :: Word64)
   in d /= 0 && e + zeros >= -25 && e + zeros <= 22
petrusJsonMayDiffer d = endAdmitted d || shortDyadic d

-- | Exact ties at 17 and 18 significant digits: @(2^52 + r) * 2^k@.
ties :: [Double]
ties = take 5000 [encodeFloat (2 ^ (52 :: Int) + r) k | (r, k) <- zip offsets (cycle [-25 .. -1]), odd r]
  where
    offsets = map (`mod` (2 ^ (52 :: Int))) (iterate (\x -> (x * 6364136223846793005 + 1) `mod` (2 ^ (64 :: Int))) 99)

-- | Finite doubles from uniformly random bit patterns (every exponent,
-- subnormals included), outside 'endAdmitted'.
finiteDoubles :: Gen Double
finiteDoubles = (castWord64ToDouble <$> (arbitrary :: Gen Word64)) `suchThat` (\d -> not (isNaN d || isInfinite d || petrusJsonMayDiffer d))

-- | A deterministic stream of finite doubles from a 64-bit LCG.
doublesFrom :: Word64 -> Int -> [Double]
doublesFrom seed n = take n (filter finite (map castWord64ToDouble (drop 1 (iterate step seed))))
  where
    step x = x * 6364136223846793005 + 1442695040888963407
    finite d = not (isNaN d || isInfinite d)

edgeDoubles :: [Double]
edgeDoubles =
  [ 0, -0.0, 1, -1, 0.1, 0.2, 0.1 + 0.2, 1 / 3, 2 / 3, 0.5, 1.5, 100, 1e15, 1e16, 1e17, 123456789012345678
  , 9007199254740992, 9007199254740993, 1e-4, 1e-5, 0.0001, 0.00012345, 1.5e-7, 1e21, 1e22, 1e23
  , 5e-324, 2.2250738585072014e-308, 2.225073858507201e-308, 1.7976931348623157e308, 4.9406564584124654e-324
  , 0.3, 2.5, 3.5, 1e-7, 9.999999999999999e15, 9.999999999999998e-5, 12345.678, -0.0001, -1e16
  ]
    <> [castWord64ToDouble (1 `shiftL` k .|. 1) | k <- [0 .. 62]]

jsonValues :: Int -> Gen Json
jsonValues size
  | size <= 1 = scalars
  | otherwise =
      frequency
        [ (3, scalars)
        , (1, Array <$> resize 6 (listOf (jsonValues (size `div` 3))))
        , (1, Object <$> resize 6 (listOf ((,) <$> texts <*> jsonValues (size `div` 3))))
        ]
  where
    scalars =
      oneof
        [ pure Null
        , Bool <$> arbitrary
        , Int <$> arbitrary
        , Int <$> elements [2 ^ (64 :: Int), -(2 ^ (63 :: Int)) - 1, 10 ^ (40 :: Int), 10 ^ (4299 :: Int)]
        , Float <$> finiteDoubles
        , Float <$> elements (filter (not . petrusJsonMayDiffer) edgeDoubles)
        , String <$> texts
        ]

texts :: Gen Text
texts = T.pack <$> listOf (frequency [(4, choose ('a', 'z')), (2, elements "\"\\\n\r\t\b\f\0\x1f\x7f /é\x2028\x1F600\xFFFD"), (1, arbitrary)])

spec :: Spec
spec = describe "the fast canonical encoder" $ do
  it "writes petrus-json's bytes for generated values" $
    property $ forAll (sized (jsonValues . max 1)) $ \value -> canonicalFast value === general value
  it "writes petrus-json's bytes for 200000 random finite doubles" $
    filter (\d -> canonicalFast (Float d) /= general (Float d)) (filter (not . petrusJsonMayDiffer) (doublesFrom 20261010 200000)) `shouldBe` []
  it "writes petrus-json's bytes for the float edge cases" $
    filter (\d -> canonicalFast (Float d) /= general (Float d)) (filter (not . petrusJsonMayDiffer) (edgeDoubles <> map negate edgeDoubles)) `shouldBe` []
  it "spells 1e23 and 2^-25 as CPython does, where floatToDigits does not" $ do
    canonicalFast (Float 1e23) `shouldBe` Just "1e+23"
    general (Float 1e23) `shouldBe` Just "9.999999999999999e+22"
    canonicalFast (Float (2 ^^ (-25 :: Int))) `shouldBe` Just "2.9802322387695312e-08"
    general (Float (2 ^^ (-25 :: Int))) `shouldBe` Just "2.9802322387695313e-08"
  it "defers every refusal to the general encoder" $ do
    canonicalFast (Object [("bad", Float (0 / 0))]) `shouldBe` Nothing
    canonicalFast (Array [Float (1 / 0)]) `shouldBe` Nothing
    canonicalFast (Int (10 ^ (4300 :: Int))) `shouldBe` Nothing
    either (const True) (const False) (canonicalBytes (Object [("bad", Float (-1 / 0))])) `shouldBe` True
  it "writes CPython's bytes for 50000 random doubles, 20000 large even-significand ones, 5000 ties, 2000 subnormals, 10000 short decimals, powers of ten and two, the edge cases, and escaped strings" $ do
    let large = take 20000 (filter endAdmitted (doublesFrom 777 200000))
        powers = [10 ^^ k | k <- [-330 .. 310 :: Int]] <> [2 ^^ k | k <- [-1080 .. 1023 :: Int]]
        subnormals = map (castWord64ToDouble . (`mod` (2 ^ (52 :: Int))) . castDoubleToWord64) (doublesFrom 99 2000)
        decimals = [fromIntegral i * 0.1 | i <- [0 .. 3000 :: Int]] <> [fromIntegral i / 1000 | i <- [1 .. 3000 :: Int]] <> [fromIntegral i * 1.0e-7 | i <- [1 .. 2000 :: Int]] <> [fromIntegral i * 1.0e14 | i <- [1 .. 2000 :: Int]]
        doubles = edgeDoubles <> map negate edgeDoubles <> doublesFrom 4242 50000 <> large <> ties <> subnormals <> decimals <> filter (\d -> d /= 0 && not (isInfinite d)) powers
        strings = ["plain", "q\"b\\s", "\n\r\t\b\f\0\x01\x1f\x7f", "é\x2028\x1F600\xFFFD", "{\"a\":1}"]
        value = Object [("floats", Array (map Float doubles)), ("strings", Array (map String strings)), ("keys", Object [(k, Int 1) | k <- strings])]
        code =
          T.unlines
            [ "import json, struct, sys"
            , "doubles = [struct.unpack('<d', int(b).to_bytes(8, 'little'))[0] for b in sys.stdin.read().split(',')]"
            , "strings = json.loads(sys.argv[1])"
            , "value = {'floats': doubles, 'strings': strings, 'keys': {k: 1 for k in strings}}"
            , "sys.stdout.buffer.write(json.dumps(value, allow_nan=False, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode())"
            ]
        bits = BC.intercalate "," (map (BC.pack . show . castDoubleToWord64) doubles)
        -- ASCII-escaped, so argv carries it unchanged.
        stringsJson = either (const "[]") BC.unpack (dumps compact {ensureAscii = True} (Array (map String strings)))
    result <- runPython code [stringsJson] bits
    (resultExit result, resultStderr result) `shouldBe` (ExitSuccess, "")
    canonicalBytes value `shouldBe` Right (resultStdout result)
