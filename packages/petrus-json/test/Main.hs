module Main (main) where

import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json
import Petrus.Json.CPythonDifferentialSpec qualified as CPythonDifferentialSpec
import Petrus.Json.FloatReprSpec qualified as FloatReprSpec
import Petrus.Json.Generators
import Petrus.Json.PythonText (pythonStrRepr)
import Petrus.Json.PythonTextSpec qualified as PythonTextSpec
import Petrus.Json.ReferenceParse (referenceParseJson)
import Test.Hspec
import Test.QuickCheck

main :: IO ()
main = hspec $ do
  PythonTextSpec.spec
  FloatReprSpec.spec
  CPythonDifferentialSpec.spec
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
    it "writes the same bytes directly as through the builder, for every option" $
      property $ \(AnyJson value) ->
        let viaBuilder options = BL.toStrict . B.toLazyByteString <$> dumpsBuilder options value
            agree options = counterexample (show options) (show (dumps options value) === show (viaBuilder options))
         in conjoin
              ( map
                  agree
                  [ defaultDumps
                  , indented
                  , compact
                  , compact {sortKeys = True}
                  , defaultDumps {indent = Just 0}
                  , defaultDumps {indent = Just 3, itemSeparator = Just " ;", keySeparator = " = ", ensureAscii = True}
                  , indented {ensureAscii = True, sortKeys = True}
                  ]
              )

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
    it "rejects lone surrogates by default" $
      parse "\"\\ud800\"" `shouldBe` Left "JSON strings must contain Unicode scalar values"
    describe "lone surrogates kept (KeepLoneSurrogates, WTF-8)" $ do
      let keep = parseJson pythonLoads {loneSurrogates = KeepLoneSurrogates}
          ascii = either (error . show) id . dumps defaultDumps
          raw = either (error . show) id . dumps defaultDumps {ensureAscii = False}
      it "keeps a lone surrogate as one WTF-8 code point" $ do
        keep "\"\\ud800\"" `shouldBe` Right (String (surrogateText 0xD800))
        fmap (\case String s -> (T.length s, T.unpack s); _ -> (0, "")) (keep "\"a\\ud800b\"") `shouldBe` Right (3, "a\xD800\&b")
        fmap (\case String s -> TE.encodeUtf8 s; _ -> "") (keep "\"\\udfff\"") `shouldBe` Right "\xED\xBF\xBF"
      it "still pairs surrogates and reads a following escape afresh" $ do
        keep "\"\\ud83d\\ude00\"" `shouldBe` Right (String "\x1F600")
        keep "\"\\udc00\\ud800\"" `shouldBe` Right (String (fromCodePoints "\xDC00\xD800"))
        keep "\"\\ud83d\\u0041\"" `shouldBe` Right (String (fromCodePoints "\xD83D\&A"))
        keep "\"\\ud800\\ud800\\udc00\"" `shouldBe` Right (String (fromCodePoints "\xD800\x10000"))
      it "keeps them in keys and nested values" $
        keep "{\"\\udc00x\": [\"a\\ud83d\", 1]}"
          `shouldBe` Right (Object [(fromCodePoints "\xDC00x", Array [String (fromCodePoints "a\xD83D"), Int 1])])
      it "re-encodes byte for byte: escaped under ensure_ascii, WTF-8 bytes otherwise" $ do
        let line = "{\"\\udc00x\": [\"a\\ud83d\", \"\\ud83d\\ude00\", \"\\udfff\"]}"
        fmap ascii (keep line) `shouldBe` Right line
        fmap raw (keep line) `shouldBe` Right "{\"\xED\xB0\x80x\": [\"a\xED\xA0\xBD\", \"\xF0\x9F\x98\x80\", \"\xED\xBF\xBF\"]}"
      it "orders and compares by code point, as CPython's str" $ do
        compare (fromCodePoints "\xD7FF") (fromCodePoints "\xD800") `shouldBe` LT
        compare (fromCodePoints "\xDFFF") (fromCodePoints "\xE000") `shouldBe` LT
        (fromCodePoints "\xD800" == fromCodePoints "\xD801") `shouldBe` False
        ascii (Object [("b", Int 1), (fromCodePoints "\xD800", Int 2), ("\xE000", Int 3)])
          `shouldBe` "{\"b\": 1, \"\\ud800\": 2, \"\\ue000\": 3}"
      it "fromWtf8 admits generalized UTF-8 only; hasLoneSurrogate finds them" $ do
        fromWtf8 "a\xED\xA0\x80" `shouldBe` Just (fromCodePoints "a\xD800")
        fromWtf8 "\xC0\x80" `shouldBe` Nothing
        fromWtf8 "\xED\xA0" `shouldBe` Nothing
        map hasLoneSurrogate [fromCodePoints "x\xDBFF", "\xD7FF\xE000\x1F600"] `shouldBe` [True, False]
      it "dumpsText answers the str CPython's json.dumps returns" $ do
        dumpsText compact (Array [String (fromCodePoints "a\xD800")]) `shouldBe` Right (fromCodePoints "[\"a\xD800\"]")
        dumpsText defaultDumps (String (fromCodePoints "a\xD800")) `shouldBe` Right "\"a\\ud800\""
      it "repr() escapes a kept surrogate as CPython does" $
        pythonStrRepr (fromCodePoints "a\xD800\&b") `shouldBe` "'a\\ud800b'"
      it "the default presets are unchanged" $ do
        strict "\"\\ud800\"" `shouldSatisfy` isLeft
        loneSurrogates pythonLoads `shouldBe` RefuseLoneSurrogates
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
    it "round-trips strings through every escaping mode" $
      property $ \(StringChars chars) ->
        let value = String (T.pack chars)
            roundTrip options = (parseJson pythonLoads =<< either (Left . show) Right (dumps options value)) == Right value
         in roundTrip defaultDumps && roundTrip compact
    it "round-trips strings at every offset (word-at-a-time scan)" $
      property $ \(StringChars chars) (Small pad) ->
        let value = Array [Int (abs pad), String (T.pack chars)]
            spelled = BC.replicate (fromInteger (abs pad `mod` 9)) ' ' <> either (error . show) id (dumps compact value)
         in fmap show (parseJson pythonLoads spelled) == Right (show value)
    it "round-trips integers of every size" $
      property $ \(Large small) wide ->
        let check i = parseJson pythonLoads (BC.pack (show i)) `exactlyIs` Int i
         in check (toInteger (small :: Int)) .&&. check (wide :: Integer) .&&. check (wide * 10 ^ (17 :: Int)) .&&. check (wide * 10 ^ (19 :: Int))
    it "keeps the first position and last value of repeated members" $
      property $ \(KeyedMembers members) ->
        let spelled = "{" <> BC.intercalate "," [either (error . show) id (dumps compact (String (T.pack key))) <> ":" <> BC.pack (show value) | (key, value) <- members] <> "}"
            expected = Object [(T.pack key, Int (toInteger (lastValue key))) | key <- firstPositions members]
            lastValue key = last [value | (k, value) <- members, k == key]
            firstPositions = foldl (\seen (key, _) -> if key `elem` seen then seen else seen ++ [key]) []
            distinct = length (firstPositions members) == length members
         in fmap show (parseJson pythonLoads spelled) == Right (show expected)
              .&&. (if distinct then parseJson strictLoads spelled `exactlyIs'` expected else property (isLeft (parseJson strictLoads spelled)))

  describe "parseJson against the pre-optimization reader" $ do
    -- The reader was rewritten for speed (an unboxed result type, direct
    -- decimal arithmetic for short numbers, an ASCII string fast path). The
    -- old implementation is kept as a test oracle: on every input, valid or
    -- not, both must produce the exact same value (integer versus float,
    -- member order, -0.0) or the exact same refusal text.
    it "agrees on documents written by every encoder spelling (property)" $
      withNumTests 3000 $
        forAll documentText agreesEverywhere
    it "agrees on mutated documents (property)" $
      withNumTests 10000 $
        forAll (documentText >>= mutated) agreesEverywhere
    it "agrees on number spellings, valid and invalid (property)" $
      withNumTests 20000 $
        forAll numberSpelling (agreesEverywhere . BC.pack)
    it "agrees on byte soup (property)" $
      withNumTests 5000 $
        forAll (BS.pack <$> listOf (elements soup)) agreesEverywhere
    -- The reader resolves duplicates once an object is complete; the
    -- reference refuses a repeat as soon as it reads its value. A failure
    -- after a repeat must still report the repeat.
    it "reports an earlier repeated member before a later failure" $ do
      let strictly = parseJson strictLoads
      strictly "{\"a\": 1, \"a\": 2," `shouldBe` Left "duplicate JSON member \"a\""
      strictly "{\"a\": 1, \"a\": 2 3" `shouldBe` Left "duplicate JSON member \"a\""
      strictly "{\"a\": 1, \"a\": [}" `shouldBe` Left "Expecting value at byte 15"
      strictly "{\"a\": 1, \"a\": 2, \"b\": {\"c\": 1, \"c\": 2}}" `shouldBe` Left "duplicate JSON member \"a\""
      strictly "{\"b\": {\"c\": 1, \"c\": 2}, \"a\": 1, \"a\": 2}" `shouldBe` Left "duplicate JSON member \"c\""
      mapM_
        (\text -> parseJson strictLoads text `shouldBe` referenceParseJson strictLoads text)
        ["{\"a\": 1, \"a\": 2,", "{\"a\": 1, \"a\": [}", "{\"a\": 1, \"a\": 2, \"b\": {\"c\": 1, \"c\": 2}}"]
    it "agrees on cut or extended objects with repeated members (property)" $
      withNumTests 3000 $
        forAll arbitrary $ \(KeyedMembers members) ->
          let spelled = "{" <> BC.intercalate "," [BC.pack (show key) <> ":" <> BC.pack (show value) | (key, value) <- members, all (< '\x80') key] <> "}"
           in forAll (choose (0, BS.length spelled)) $ \cut ->
                forAll (elements ["", "]", ",", "x", ",\"z\":[", "}"]) $ \tailText ->
                  agreesEverywhere (BS.take cut spelled <> BC.pack tailText)

  describe "Eq Json" $ do
    it "compares numbers like Python" $ do
      Int 1 `shouldBe` Float 1
      Bool True `shouldBe` Int 1
      Int (2 ^ (53 :: Int) + 1) `shouldNotBe` Float (2 ^ (53 :: Int))
    it "compares objects as mappings" $
      Object [("a", Int 1), ("b", Int 2)] `shouldBe` Object [("b", Int 2), ("a", Int 1)]
    it "compares objects with repeated keys as their last-wins dicts, symmetrically" $ do
      let repeated = Object [("a", Int 1), ("a", Int 1)]
          distinct = Object [("a", Int 1), ("b", Int 1)]
      (repeated == distinct, distinct == repeated) `shouldBe` (False, False)
      Object [("a", Int 1), ("a", Int 2)] `shouldBe` Object [("a", Int 2)]
      Object [("a", Int 2)] `shouldBe` Object [("a", Int 1), ("a", Int 2)]
      Object [("a", Int 2), ("a", Int 1)] `shouldNotBe` Object [("a", Int 2)]
    -- The equivalence laws, over finite values dense in equal-but-differently
    -- spelled pairs: repeated keys, reordered members, and 1 / 1.0 / true.
    -- (A NaN equals nothing, itself included, as in CPython.)
    it "is reflexive" $
      property $ \(EqLaws a) -> a == a
    it "is symmetric" $
      property $ \(EqLaws a) -> forAll (respelled a) $ \b -> (a == b) === (b == a)
    it "is transitive" $
      property $ \(EqLaws a) ->
        forAll (respelled a) $ \b ->
          forAll (respelled b) $ \c ->
            (a == b && b == c) ==> a == c
    it "equals every equal respelling, both ways" $
      property $ \(EqLaws a) -> forAll (respelledEqual a) $ \b -> a == b && b == a

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

  describe "one-pass dumps" $
    it "refuses exactly what dumpsBuilder refuses, at the same first value (property)" $
      property $ \(Refusable value) sorted nanAllowed depth ->
        let options =
              compact
                { sortKeys = sorted
                , allowNan = nanAllowed
                , reprDigitLimit = Just 30
                , nestingLimit = Just (getSmall (getNonNegative depth))
                }
            built = BL.toStrict . B.toLazyByteString <$> dumpsBuilder options value
            -- Compare refusals by message: NonFiniteNumber NaN /= itself.
            message = either (Left . encodeErrorMessage) Right
         in message (dumps options value) === message built

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
    agreesEverywhere text =
      conjoin
        [ counterexample (show text ++ " under " ++ show options) $
            sameOutcome (parseJson options text) (referenceParseJson options text)
        | options <- parserOptions
        ]
    exactEq' = \case
      Array items -> items
      other -> [other]
    exactlyIs result expected = counterexample (show result) (either (const False) (exactEq expected) result)
    exactlyIs' result expected = exactlyIs result expected

-- | Strings rich in what the scanner must stop at: quotes, backslashes,
-- control characters, and non-ASCII (including astral) characters.
newtype StringChars = StringChars String
  deriving stock (Show)

instance Arbitrary StringChars where
  arbitrary =
    StringChars
      <$> listOf
        ( frequency
            [ (12, choose ('a', 'z'))
            , (2, elements "\"\\/ ")
            , (1, choose ('\0', '\x1f'))
            , (1, elements "\x7f\x80\xe9\x2028\xfffd\x1F600")
            ]
        )
  shrink (StringChars chars) = StringChars <$> shrink chars

-- | Any JSON value, including non-finite floats, huge integers, and strings
-- that need every kind of escape.
newtype AnyJson = AnyJson Json
  deriving stock (Show)

instance Arbitrary AnyJson where
  arbitrary = AnyJson <$> sized value
    where
      value n
        | n <= 1 = scalar
        | otherwise =
            frequency
              [ (3, scalar)
              , (1, Array <$> small (value (n `div` 3)))
              , (1, Object <$> small ((,) <$> text <*> value (n `div` 3)))
              ]
      small gen = chooseInt (0, 4) >>= \count -> vectorOf count gen
      text = (\(StringChars chars) -> T.pack chars) <$> arbitrary
      scalar =
        oneof
          [ pure Null
          , Bool <$> arbitrary
          , Int <$> arbitrary
          , Int . (* (10 ^ (25 :: Int))) <$> arbitrary
          , Int <$> elements [999999999999999999, 1000000000000000000, -1000000000000000000, -999999999999999999]
          , Float <$> arbitrary
          , Float <$> elements [0 / 0, 1 / 0, -1 / 0, -0.0, 1e300, 5e-324]
          , String <$> text
          ]

-- | Object members over a small key alphabet, so repeats are common, and
-- often more than eight members (the hashed duplicate check).
newtype KeyedMembers = KeyedMembers [(String, Int)]
  deriving stock (Show)

instance Arbitrary KeyedMembers where
  arbitrary = do
    count <- choose (1, 40)
    KeyedMembers <$> vectorOf count ((,) <$> elements keys <*> arbitrary)
    where
      keys = ["k" <> show i | i <- [0 :: Int .. 30]] <> ["", "\xe9", "long_key_with_shared_prefix_a", "long_key_with_shared_prefix_b"]


parserOptions :: [ParseOptions]
parserOptions =
  [ pythonLoads
  , strictLoads
  , strictLoads {integerTokensOnly = True, integerRange = Just (safeIntegerMin, safeIntegerMax)}
  , pythonLoads {finiteFloatsOnly = True}
  ]

-- | The same value, spelling for spelling, or the same refusal text.
sameOutcome :: Either String Json -> Either String Json -> Bool
sameOutcome (Right a) (Right b) = exactEq a b
sameOutcome (Left a) (Left b) = a == b
sameOutcome _ _ = False

-- | Small documents dense in what an encoder may refuse: non-finite floats,
-- long integers, nesting, and keys out of order.
newtype Refusable = Refusable Json
  deriving stock (Show)

instance Arbitrary Refusable where
  arbitrary = Refusable <$> sized go
    where
      go :: Int -> Gen Json
      go n
        | n <= 1 = leaf
        | otherwise =
            frequency
              [ (3, leaf)
              , (2, Array <$> (choose (0, 3) >>= \k -> vectorOf k (go (n `div` 2))))
              , (2, Object <$> (choose (0, 3) >>= \k -> vectorOf k ((,) <$> elements ["b", "a", "c", "aa"] <*> go (n `div` 2))))
              ]
      leaf =
        oneof
          [ pure Null
          , Int <$> elements [0, -7, 10 ^ (29 :: Int), 10 ^ (30 :: Int), negate (10 ^ (31 :: Int))]
          , Float <$> elements [1.5, 0 / 0, 1 / 0, -1 / 0]
          , pure (String "s")
          ]

-- | Finite values over a small key alphabet, so objects often repeat keys,
-- with numbers among 0, 1 and 2 in every numeric spelling.
newtype EqLaws = EqLaws Json
  deriving stock (Show)

instance Arbitrary EqLaws where
  arbitrary = EqLaws <$> sized go
    where
      go :: Int -> Gen Json
      go n
        | n <= 1 = leaf
        | otherwise =
            frequency
              [ (3, leaf)
              , (1, Array <$> (choose (0, 3) >>= \k -> vectorOf k (go (n `div` 3))))
              , (2, Object <$> (choose (0, 4) >>= \k -> vectorOf k ((,) <$> elements ["a", "b", "c"] <*> go (n `div` 3))))
              ]
      leaf = elements [Null, Bool False, Bool True, Int 0, Int 1, Int 2, Float 0, Float 1, Float (-0.0), Float 1.5, String "a", String "b"]

-- | A value spelled differently and equal to it under Python value
-- equality: members reordered, a stale value for a key slipped in before
-- its last occurrence, and numbers respelled across bool, int and float.
respelledEqual :: Json -> Gen Json
respelledEqual = \case
  Int 0 -> elements [Int 0, Float 0, Float (-0.0), Bool False]
  Int 1 -> elements [Int 1, Float 1, Bool True]
  Bool b -> elements [Bool b, Int (if b then 1 else 0)]
  Float d | d == 0 -> elements [Float 0, Float (-0.0), Int 0, Bool False]
  Array items -> Array <$> traverse respelledEqual items
  Object members -> do
    let lastWins = [(k, v) | (i, (k, v)) <- zip [1 :: Int ..] members, k `notElem` map fst (drop i members)]
    kept <- traverse (\(k, v) -> (,) k <$> respelledEqual v) lastWins
    shuffled <- shuffle kept
    stale <- sublistOf [(k, Int 99) | (k, _) <- shuffled]
    pure (Object (stale <> shuffled))
  other -> pure other

-- | A respelling that is equal (most of the time) or changed in one place.
respelled :: Json -> Gen Json
respelled a = frequency [(3, respelledEqual a), (1, changed a)]
  where
    changed = \case
      Array items@(_ : _) -> do
        i <- chooseInt (0, length items - 1)
        pure (Array [if j == i then String "changed" else item | (j, item) <- zip [0 ..] items])
      Object ((k, _) : rest) -> pure (Object ((k, String "changed") : rest))
      _ -> pure (String "changed")
