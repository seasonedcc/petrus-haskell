module Main (main) where

import Data.ByteString.Builder qualified as B
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Petrus.Json
import Petrus.Json.PythonTextSpec qualified as PythonTextSpec
import Petrus.Json.ReferenceParse (referenceParseJson)
import Test.Hspec
import Test.QuickCheck

main :: IO ()
main = hspec $ do
  PythonTextSpec.spec
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

-- | A JSON document written by one of the encoder spellings Petrus uses.
documentText :: Gen BS.ByteString
documentText = do
  value <- sized (\n -> jsonValue (min 4 (n `div` 10 + 1)))
  options <-
    elements
      [ defaultDumps
      , compact
      , indented {allowNan = True}
      , compact {ensureAscii = True, allowNan = True}
      , defaultDumps {sortKeys = True}
      ]
  pure (either (const "null") id (dumps options value))

jsonValue :: Int -> Gen Json
jsonValue depth =
  frequency $
    [ (1, pure Null)
    , (1, Bool <$> arbitrary)
    , (3, Int <$> integer)
    , (3, Float <$> double)
    , (3, String . T.pack <$> listOf character)
    ]
      ++ if depth <= 0
        then []
        else
          [ (2, Array <$> resize 5 (listOf (jsonValue (depth - 1))))
          , (2, Object <$> resize 6 (listOf ((,) <$> (T.pack <$> listOf character) <*> jsonValue (depth - 1))))
          ]
  where
    integer =
      oneof
        [ arbitrary
        , choose (-(10 ^ (19 :: Int)), 10 ^ (19 :: Int))
        , choose (-(10 ^ (40 :: Int)), 10 ^ (40 :: Int))
        , elements
            [ 0
            , -1
            , 9007199254740991
            , 9007199254740992
            , -9007199254740991
            , -9007199254740992
            , 999999999999999999
            , 1000000000000000000
            , -999999999999999999
            , 9223372036854775807
            , -9223372036854775808
            ]
        ]
    double =
      oneof
        [ arbitrary
        , (/ 1000) . fromInteger <$> choose (-(10 ^ (12 :: Int)), 10 ^ (12 :: Int))
        , (* 1e-300) <$> arbitrary
        , elements [0, -0.0, 0.1, 1e22, 1e23, 5e-324, 1.7976931348623157e308, 1 / 0, -1 / 0, 0 / 0, 123456789012345.6, 9007199254740993]
        ]
    character =
      frequency
        [ (8, elements (['a' .. 'z'] ++ ['0' .. '9'] ++ " .:"))
        , (1, elements "\"\\/\b\f\n\r\t\x01\x1f\x7f")
        , (1, elements "\x80\xe9\x2028\xffff\x1F600\x10ffff")
        ]

-- | Random single-byte insertions, deletions, and replacements drawn from
-- the bytes that matter to the grammar.
mutated :: BS.ByteString -> Gen BS.ByteString
mutated text = do
  edits <- choose (1, 3 :: Int)
  go edits text
  where
    go :: Int -> BS.ByteString -> Gen BS.ByteString
    go 0 current = pure current
    go n current = do
      position <- choose (0, BS.length current)
      byte <- elements soup
      edit <-
        elements
          [ BS.take position current <> BS.singleton byte <> BS.drop position current
          , BS.take position current <> BS.drop (position + 1) current
          , BS.take position current <> BS.singleton byte <> BS.drop (position + 1) current
          ]
      go (n - 1) edit

soup :: [Word8]
soup =
  BS.unpack (BC.pack "{}[],:\" 0123456789-+.eEntfalsruNIiy \t\n\r\\u/bdD8")
    ++ [0x00, 0x01, 0x1f, 0x7f, 0x80, 0xbf, 0xc0, 0xc3, 0xa9, 0xed, 0xa0, 0xef, 0xbb, 0xf0, 0x9f, 0xf8, 0xff]

-- | Number spellings, valid and invalid: signs, leading zeros, fractions,
-- exponents of every size, and digit runs on both sides of the fast paths'
-- limits.
numberSpelling :: Gen String
numberSpelling = do
  sign <- elements ["", "", "-", "+"]
  whole <- frequency [(1, pure "0"), (1, pure "00"), (6, digitRun 1 25), (1, pure "")]
  fraction <- frequency [(2, pure ""), (3, ("." ++) <$> digitRun 1 25), (1, pure ".")]
  expo <-
    frequency
      [ (3, pure "")
      , (3, exponentPart 1 3)
      , (1, exponentPart 4 22)
      , (1, (: []) <$> elements "eE")
      ]
  trailer <- frequency [(6, pure ""), (1, elements [" ", "]", "x", ".", "e"])]
  pure (sign ++ whole ++ fraction ++ expo ++ trailer)
  where
    exponentPart low high = do
      marker <- elements "eE"
      sign <- elements ["", "+", "-"]
      digits <- digitRun low high
      pure (marker : sign ++ digits)
    digitRun :: Int -> Int -> Gen String
    digitRun low high = do
      n <- choose (low, high)
      vectorOf n (frequency [(1, pure '0'), (4, elements ['1' .. '9'])])
