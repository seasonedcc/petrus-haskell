module Main (main) where

import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json
import Test.Hspec
import Test.QuickCheck

main :: IO ()
main = hspec $ do
  describe "pythonFloatRepr" $ do
    let cases =
          [ (1e16, "1e+16")
          , (1e15, "1000000000000000.0")
          , (0.0001, "0.0001")
          , (1e-05, "1e-05")
          , (-0.0, "-0.0")
          , (0.1, "0.1")
          , (1.5, "1.5")
          , (123456789.125, "123456789.125")
          , (1.7976931348623157e308, "1.7976931348623157e+308")
          , (5e-324, "5e-324")
          , (2.5e-5, "2.5e-05")
          , (1234567890123456.7, "1234567890123456.8")
          , (12345678901234567.0, "1.2345678901234568e+16")
          ]
    mapM_ (\(d, s) -> it s (pythonFloatRepr d `shouldBe` s)) cases
    it "round-trips through the parser" $
      property $ \d ->
        not (isNaN d || isInfinite d) ==>
          case parseJson pythonLoads (BC.pack (pythonFloatRepr d)) of
            Right (Float d') -> d' == (d :: Double) && isNegativeZero d' == isNegativeZero d
            _ -> False

  describe "dumps" $ do
    let render options = either (error . show) (T.unpack . TE.decodeUtf8) . dumps options
    it "matches json.dumps defaults" $
      render defaultDumps (Object [("a", Array [Int 1, Float 2, Null]), ("é", String "\x1F600\n")])
        `shouldBe` "{\"a\": [1, 2.0, null], \"\\u00e9\": \"\\ud83d\\ude00\\n\"}"
    it "matches the indented writer" $
      render indented (Object [("a", Array [Int 1, Object []]), ("b", Array []), ("é", String "x")])
        `shouldBe` "{\n  \"a\": [\n    1,\n    {}\n  ],\n  \"b\": [],\n  \"é\": \"x\"\n}"
    it "sorts keys canonically" $
      canonicalText (Object [("b", Int 1), ("a", Bool True)]) `shouldBe` Right "{\"a\":true,\"b\":1}"
    it "refuses non-finite numbers when asked" $
      dumps indented (Float (1 / 0)) `shouldSatisfy` isLeft
    it "escapes control characters" $
      render indented (String "\x01\x7f") `shouldBe` "\"\\u0001\x7f\""

  describe "parseJson" $ do
    let parse = parseJson pythonLoads . BC.pack
        strict = parseJson strictLoads . BC.pack
    it "keeps integers and floats apart" $ do
      fmap exactEq' (parse "[1, 1.0, 1e2]") `shouldBe` Right [Int 1, Float 1, Float 100]
    it "lets the last duplicate win at the first position" $
      fmap show (parse "{\"a\": 1, \"b\": 2, \"a\": 3}") `shouldBe` Right (show (Object [("a", Int 3), ("b", Int 2)]))
    it "rejects duplicates when strict" $
      strict "{\"a\": 1, \"a\": 2}" `shouldSatisfy` isLeft
    it "accepts Python constants by default only" $ do
      parse "[NaN, Infinity, -Infinity]" `shouldSatisfy` either (const False) (const True)
      strict "NaN" `shouldSatisfy` isLeft
    it "rejects malformed numbers" $
      mapM_ (\s -> parse s `shouldSatisfy` isLeft) ["01", "1.", ".5", "+1", "1e", "-"]
    it "rejects lone surrogates" $
      parse "\"\\ud800\"" `shouldSatisfy` isLeft
    it "decodes surrogate pairs" $
      parse "\"\\ud83d\\ude00\"" `shouldBe` Right (String "\x1F600")
    it "rejects raw control characters" $
      parse "\"a\tb\"" `shouldSatisfy` isLeft
    it "rejects trailing data" $
      parse "1 2" `shouldSatisfy` isLeft
    it "enforces integer-only and range options" $ do
      let opts = strictLoads {integerTokensOnly = True, integerRange = Just (safeIntegerMin, safeIntegerMax)}
      parseJson opts "1.0" `shouldSatisfy` isLeft
      parseJson opts "9007199254740992" `shouldSatisfy` isLeft
      parseJson opts "-9007199254740991" `shouldBe` Right (Int (-9007199254740991))
    it "overflows huge exponents to infinity" $
      parse "1e999999999999999999" `shouldBe` Right (Float (1 / 0))

  describe "Eq Json" $ do
    it "compares numbers like Python" $ do
      Int 1 `shouldBe` Float 1
      Bool True `shouldBe` Int 1
      Int (2 ^ (53 :: Int) + 1) `shouldNotBe` Float (2 ^ (53 :: Int))
    it "compares objects as mappings" $
      Object [("a", Int 1), ("b", Int 2)] `shouldBe` Object [("b", Int 2), ("a", Int 1)]

  describe "CPython integer string-conversion limit" $ do
    let digits n = BC.replicate n '7'
        tooMany :: Int -> Either String a
        tooMany n =
          Left
            ( "Exceeds the limit (4300 digits) for integer string conversion: value has "
                ++ show n
                ++ " digits; use sys.set_int_max_str_digits() to increase the limit"
            )
    it "parses 4300 digits" $
      fmap (\case Int i -> length (show i); _ -> 0) (parseJson pythonLoads (digits 4300)) `shouldBe` Right 4300
    it "refuses 4301 digits with CPython's message, sign excluded" $ do
      parseJson pythonLoads (digits 4301) `shouldBe` tooMany 4301
      parseJson pythonLoads ("-" <> digits 4301) `shouldBe` tooMany 4301
      parseJson strictLoads ("[" <> digits 4400 <> "]") `shouldBe` tooMany 4400
    it "does not limit float tokens" $ do
      parseJson pythonLoads (digits 5000 <> ".0") `shouldBe` Right (Float (1 / 0))
      parseJson pythonLoads (digits 5000 <> "e1") `shouldBe` Right (Float (1 / 0))
    it "can be lifted" $
      parseJson pythonLoads {maxIntegerDigits = Nothing} (digits 5000) `shouldSatisfy` either (const False) (const True)
    it "refuses to print more than 4300 digits, sign excluded" $ do
      fmap BC.length (dumps defaultDumps (Int (10 ^ (4300 :: Int) - 1))) `shouldBe` Right 4300
      fmap BC.length (dumps defaultDumps (Int (negate (10 ^ (4300 :: Int) - 1)))) `shouldBe` Right 4301
      dumps defaultDumps (Array [Int (10 ^ (4300 :: Int))]) `shouldBe` Left (IntegerTooLarge 4300)
      dumps indented (Int (negate (10 ^ (4300 :: Int)))) `shouldBe` Left (IntegerTooLarge 4300)
      either (Left . encodeErrorMessage) Right (dumps compact (Int (10 ^ (4300 :: Int))))
        `shouldBe` Left "Exceeds the limit (4300 digits) for integer string conversion; use sys.set_int_max_str_digits() to increase the limit"
    it "converts decimal digit strings like int()" $ do
      decimalInteger "0042" `shouldBe` Right 42
      decimalInteger (BC.replicate 4301 '0') `shouldBe` tooMany 4301
      decimalInteger (BC.replicate 4300 '0') `shouldBe` Right 0
      decimalInteger "+1" `shouldSatisfy` isLeft

  describe "nesting-depth guard" $ do
    let arrays n = BC.replicate n '[' <> BC.replicate n ']'
        objects n = mconcat (replicate n "{\"a\":") <> "1" <> BC.replicate n '}'
    it "accepts the depths upstream exercises" $
      parseJson strictLoads (arrays 1200) `shouldSatisfy` either (const False) (const True)
    it "accepts exactly the limit" $
      parseJson pythonLoads (arrays defaultNestingLimit) `shouldSatisfy` either (const False) (const True)
    it "refuses one level deeper, naming the container" $ do
      parseJson pythonLoads (arrays (defaultNestingLimit + 1))
        `shouldBe` Left "maximum nesting depth (100000) exceeded while decoding a JSON array from a unicode string"
      parseJson pythonLoads {maxNestingDepth = Just 3} (objects 4)
        `shouldBe` Left "maximum nesting depth (3) exceeded while decoding a JSON object from a unicode string"
    it "survives input far deeper than any stack" $
      parseJson pythonLoads (arrays 1000000) `shouldSatisfy` isLeft
    it "bounds the encoder too, where empty containers do not recurse (as in CPython)" $ do
      let nested n = iterate (Array . pure) (Array []) !! (n - 1)
          len = fmap BC.length . dumps compact
      len (nested (defaultNestingLimit + 1)) `shouldBe` Right (2 * defaultNestingLimit + 2)
      len (nested (defaultNestingLimit + 2)) `shouldBe` Left (NestingTooDeep defaultNestingLimit)

  describe "encodeErrorMessage" $
    it "matches CPython's allow_nan=False text" $
      map (encodeErrorMessage . NonFiniteNumber) [0 / 0, 1 / 0, -1 / 0]
        `shouldBe` [ "Out of range float values are not JSON compliant: nan"
                   , "Out of range float values are not JSON compliant: inf"
                   , "Out of range float values are not JSON compliant: -inf"
                   ]

  describe "typeExactEq" $ do
    it "ignores member order" $
      Object [("a", Int 1), ("b", Array [Null])] `typeExactEq` Object [("b", Array [Null]), ("a", Int 1)] `shouldBe` True
    it "treats 0.0 and -0.0 as equal" $
      Float 0 `typeExactEq` Float (-0.0) `shouldBe` True
    it "distinguishes int, float and bool at every depth" $ do
      Int 1 `typeExactEq` Float 1 `shouldBe` False
      Int 1 `typeExactEq` Bool True `shouldBe` False
      Object [("weight", Int 1)] `typeExactEq` Object [("weight", Float 1)] `shouldBe` False
      Object [("weight", Int 1)] `typeExactEq` Object [("weight", Bool True)] `shouldBe` False
    it "compares arrays in order and keys as sets" $ do
      Array [Int 1, Int 2] `typeExactEq` Array [Int 2, Int 1] `shouldBe` False
      Object [("a", Int 1)] `typeExactEq` Object [("a", Int 1), ("b", Int 1)] `shouldBe` False
    it "never equates NaN" $
      Float (0 / 0) `typeExactEq` Float (0 / 0) `shouldBe` False
  where
    exactEq' = \case
      Array items -> items
      other -> [other]
