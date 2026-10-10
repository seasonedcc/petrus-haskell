-- | 'pythonFloatRepr' is CPython's @float.__repr__@, and every float path of
-- the encoder spells it.
--
-- Two classes of doubles separate CPython's repr from GHC's
-- 'Numeric.floatToDigits' and bytestring's Ryu, which petrus-json once used:
--
-- * at least 2^53 with an even significand, where CPython admits a shorter
--   decimal on the rounding interval's end (@repr(1e23) == "1e+23"@, not
--   @9.999999999999999e+22@);
-- * exact ties one digit past the shortest answer, which CPython breaks to
--   even (@repr(2**-25) == "2.9802322387695312e-08"@, not @...313e-08@).
--
-- The differential below runs CPython itself (the pinned upstream
-- environment) over more than 100 000 seeded doubles that include both
-- classes, and compares every float path byte for byte.
module Petrus.Json.FloatReprSpec (spec) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Word (Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Petrus.Json
import Petrus.Json.Float (floatReprBuilder, pythonFloatReprBytes)
import Petrus.Json.Repr (pythonReprFloat)
import System.Directory (doesFileExist, getCurrentDirectory, makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec

-- | A deterministic stream of finite doubles from a 64-bit LCG.
doublesFrom :: Word64 -> Int -> [Double]
doublesFrom seed n = take n (filter finite (map castWord64ToDouble (drop 1 (iterate step seed))))
  where
    step x = x * 6364136223846793005 + 1442695040888963407
    finite d = not (isNaN d || isInfinite d)

-- | At least 2^53 with an even significand: the interval's ends are admitted.
endAdmitted :: Double -> Bool
endAdmitted d = abs d >= 2 ^ (53 :: Int) && even (fst (decodeFloat d))

-- | Exact ties at 17 and 18 significant digits: @(2^52 + r) * 2^k@.
ties :: [Double]
ties = take 5000 [encodeFloat (2 ^ (52 :: Int) + r) k | (r, k) <- zip offsets (cycle [-25 .. -1]), odd r]
  where
    offsets = map (`mod` (2 ^ (52 :: Int))) (iterate (\x -> (x * 6364136223846793005 + 1) `mod` (2 ^ (64 :: Int))) 99)

edgeDoubles :: [Double]
edgeDoubles =
  [ 0, -0.0, 1, -1, 0.1, 0.2, 0.1 + 0.2, 1 / 3, 2 / 3, 0.5, 1.5, 100, 1e15, 1e16, 1e17, 123456789012345678
  , 9007199254740992, 9007199254740993, 1e-4, 1e-5, 0.0001, 0.00012345, 1.5e-7, 1e21, 1e22, 1e23
  , 5e-324, 2.2250738585072014e-308, 2.225073858507201e-308, 1.7976931348623157e308, 4.9406564584124654e-324
  , 0.3, 2.5, 3.5, 1e-7, 9.999999999999999e15, 9.999999999999998e-5, 12345.678, -0.0001, -1e16
  , 2 ^^ (-25 :: Int), 2 ^^ (-24 :: Int), 2 ^^ (-1 :: Int)
  ]
    <> [castWord64ToDouble (1 `shiftL` k .|. 1) | k <- [0 .. 62]]

-- | 70 000 random bit patterns, 20 000 large even-significand doubles,
-- 5 000 exact ties, 2 000 subnormals, 10 000 short decimals, every power of
-- ten and two, and the edge cases, each with its negation where it differs.
corpus :: [Double]
corpus = edgeDoubles <> map negate edgeDoubles <> doublesFrom 4242 70000 <> large <> ties <> map negate ties <> subnormals <> decimals <> powers
  where
    large = take 20000 (filter endAdmitted (doublesFrom 777 200000))
    subnormals = map (castWord64ToDouble . (`mod` (2 ^ (52 :: Int))) . castDoubleToWord64) (doublesFrom 99 2000)
    decimals =
      [fromIntegral i * 0.1 | i <- [0 .. 3000 :: Int]]
        <> [fromIntegral i / 1000 | i <- [1 .. 3000 :: Int]]
        <> [fromIntegral i * 1.0e-7 | i <- [1 .. 2000 :: Int]]
        <> [fromIntegral i * 1.0e14 | i <- [1 .. 2000 :: Int]]
    powers = filter (\d -> d /= 0 && not (isInfinite d)) ([10 ^^ k | k <- [-330 .. 310 :: Int]] <> [2 ^^ k | k <- [-1080 .. 1023 :: Int]])

-- | The pinned reference interpreter and its checkout, provisioned by
-- @scripts/upstream-python@ as every differential suite's is. (petrus-json
-- cannot use petrus-test-support, which depends on it.) Fails, never skips,
-- when the environment cannot be provisioned.
upstreamPython :: IO (FilePath, FilePath)
upstreamPython = getCurrentDirectory >>= makeAbsolute >>= root >>= provision
  where
    root dir = do
      found <- doesFileExist (dir </> "scripts" </> "upstream-python")
      if found
        then pure dir
        else if takeDirectory dir == dir then fail "no scripts/upstream-python above the test's directory" else root (takeDirectory dir)
    provision dir = do
      (code, out, err) <- readCreateProcessWithExitCode (proc (dir </> "scripts" </> "upstream-python") ["petrus"]) ""
      case (code, lines out) of
        (ExitSuccess, exe : _) -> pure (exe, dir </> "upstream" </> "petrus")
        _ -> fail ("scripts/upstream-python could not provision the reference: " ++ err)

-- | CPython's @json.dumps@ and @repr@ of every double, one per line, after
-- the compact array: @(dumps, [repr])@.
cpython :: [Double] -> IO (BS.ByteString, [BS.ByteString])
cpython doubles = do
  (exe, checkout) <- upstreamPython
  let code =
        unlines
          [ "import json, struct, sys"
          , "doubles = [struct.unpack('<d', int(b).to_bytes(8, 'little'))[0] for b in sys.stdin.read().split(',')]"
          , "out = sys.stdout"
          , "out.write(json.dumps(doubles, separators=(',', ':')) + '\\n')"
          , "out.write('\\n'.join(repr(d) for d in doubles))"
          ]
      bits = foldr1 (\a b -> a ++ "," ++ b) (map (show . castDoubleToWord64) doubles)
  (code', out, err) <- readCreateProcessWithExitCode (proc exe ["-I", "-B", "-c", code]) {cwd = Just checkout} bits
  case (code', BC.lines (BC.pack out)) of
    (ExitSuccess, encoded : reprs) -> pure (encoded, reprs)
    _ -> fail ("CPython failed: " ++ err)

spec :: Spec
spec = describe "pythonFloatRepr (CPython's float.__repr__)" $ do
  it "admits the rounding interval's ends for even significands, as CPython does" $ do
    pythonFloatRepr 1e23 `shouldBe` "1e+23"
    pythonFloatRepr 9007199254740993 `shouldBe` "9007199254740992.0"
    pythonFloatRepr 123456789012345678 `shouldBe` "1.2345678901234568e+17"
  it "breaks exact ties to even, as CPython does" $
    pythonFloatRepr (2 ^^ (-25 :: Int)) `shouldBe` "2.9802322387695312e-08"
  it "is what every float path writes" $ do
    let check d = do
          let expected = BC.pack (pythonFloatRepr d)
          pythonFloatReprBytes d `shouldBe` expected
          BL.toStrict (B.toLazyByteString (floatReprBuilder d)) `shouldBe` expected
          dumps defaultDumps (Float d) `shouldBe` Right expected
          fmap (BL.toStrict . B.toLazyByteString) (dumpsBuilder compact (Float d)) `shouldBe` Right expected
          pythonReprFloat d `shouldBe` pythonFloatRepr d
    mapM_ check (edgeDoubles <> map negate edgeDoubles)
  it "matches CPython's json.dumps and repr byte for byte on over 100 000 doubles" $ do
    let doubles = corpus
    length doubles `shouldSatisfy` (> 100000)
    (encoded, reprs) <- cpython doubles
    length reprs `shouldBe` length doubles
    dumps compact (Array (map Float doubles)) `shouldBe` Right encoded
    fmap (BL.toStrict . B.toLazyByteString) (dumpsBuilder compact (Array (map Float doubles))) `shouldBe` Right encoded
    let mismatches = [(d, mine, theirs) | (d, theirs) <- zip doubles reprs, let mine = pythonFloatReprBytes d, mine /= theirs]
    take 5 mismatches `shouldBe` []
