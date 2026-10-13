-- | Unit and property checks for the Python-literal printer and parser. The
-- byte-for-byte agreement with CPython lives in CorpusSpec.
module PyLiteralSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.PyLiteral
import Petrus.Json (Json (..))
import Petrus.Json.Wtf8 (fromCodePoints)
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = describe "Hamsterdan.PyLiteral" $ do
  describe "repr" $ do
    it "chooses quotes as CPython does" $ do
      repr (LitStr "plain") `shouldBe` "'plain'"
      repr (LitStr "it's") `shouldBe` "\"it's\""
      repr (LitStr "say \"hi\"") `shouldBe` "'say \"hi\"'"
      repr (LitStr "both ' and \"") `shouldBe` "'both \\' and \"'"
    it "escapes controls and non-printables" $ do
      repr (LitStr "a\tb\nc\rd\\e") `shouldBe` "'a\\tb\\nc\\rd\\\\e'"
      repr (LitStr "\0\x1b\x7f\x80\xa0\xad") `shouldBe` "'\\x00\\x1b\\x7f\\x80\\xa0\\xad'"
      repr (LitStr "\x2028\xfeff\x10ffff") `shouldBe` "'\\u2028\\ufeff\\U0010ffff'"
      repr (LitStr "é中😀") `shouldBe` "'é中😀'"
    it "spells containers" $ do
      repr (LitTuple []) `shouldBe` "()"
      repr (LitTuple [LitInt 1]) `shouldBe` "(1,)"
      repr (LitTuple [LitInt 1, LitNone]) `shouldBe` "(1, None)"
      repr (LitList [LitBool True, LitFloat 1e16, LitFloat (-0.0)]) `shouldBe` "[True, 1e+16, -0.0]"
      repr (LitDict [(LitStr "a", LitList []), (LitInt 2, LitDict [])]) `shouldBe` "{'a': [], 2: {}}"
      repr (LitList [LitFloat (1 / 0), LitFloat (-1 / 0), LitFloat (0 / 0)]) `shouldBe` "[inf, -inf, nan]"
    it "spells dashboard entries and digests" $ do
      let body = [("status", String "clear"), ("head", String "abc"), ("blocking", Int 0)]
      dictEntry "review" body `shouldBe` "review:{'status': 'clear', 'head': 'abc', 'blocking': 0}"
      sortedItemsDigest "review" body `shouldBe` "review:[('blocking', 0), ('head', 'abc'), ('status', 'clear')]"

  describe "literalEval" $ do
    it "parses the modeled literals" $ do
      literalEval "{'a': [1, (2,), -3.5e1, None, True], \"b\": ()}"
        `shouldBe` Right (LitDict [(LitStr "a", LitList [LitInt 1, LitTuple [LitInt 2], LitFloat (-35), LitNone, LitBool True]), (LitStr "b", LitTuple [])])
      literalEval "  0x_ff, 0o17, 0b1_0, 1_000," `shouldBe` Right (LitTuple [LitInt 255, LitInt 15, LitInt 2, LitInt 1000])
      literalEval "'a' \"b\" r'\\n' '''c\nd'''" `shouldBe` Right (LitStr "ab\\nc\nd")
      literalEval "'\\x41\\u00e9\\U0001F600\\101\\q'" `shouldBe` Right (LitStr "Aé😀A\\q")
      literalEval "[\n  1,  # one\n  2,\n]\n" `shouldBe` Right (LitList [LitInt 1, LitInt 2])
    it "merges Python-equal dict keys, keeping the first key and the last value" $
      literalEval "{1: 'a', True: 'b', 1.0: 'c', 2: 'd'}" `shouldBe` Right (LitDict [(LitInt 1, LitStr "c"), (LitInt 2, LitStr "d")])
    it "classifies failures" $ do
      kindOf "{[]: 1}" `shouldBe` Just Unhashable
      kindOf "{(1, [2]): 3}" `shouldBe` Just Unhashable
      kindOf "x" `shouldBe` Just Malformed
      kindOf "-True" `shouldBe` Just Malformed
      kindOf "1 + 2" `shouldBe` Just Malformed
      kindOf "01" `shouldBe` Just Malformed
      kindOf "'\\x4'" `shouldBe` Just Malformed
      kindOf "\n 1" `shouldBe` Just Malformed
      kindOf "b'x'" `shouldBe` Just Unsupported
      kindOf "1j" `shouldBe` Just Unsupported
      kindOf "{1, 2}" `shouldBe` Just Unsupported
      kindOf "'\\N{BULLET}'" `shouldBe` Just Unsupported
      kindOf (fromCodePoints "'\xDC80'") `shouldBe` Just Malformed
    it "keeps escaped lone surrogates, unpaired, as CPython does" $ do
      fmap repr (literalEval "'\\ud800'") `shouldBe` Right "'\\ud800'"
      fmap repr (literalEval "'\\ud83d\\ude00'") `shouldBe` Right "'\\ud83d\\ude00'"
    it "spells unhashable refusals as CPython 3.14 does" $ do
      let messageOf source = either (\(LiteralError _ message) -> Just message) (const Nothing) (literalEval source)
      messageOf "{[1]: 2}" `shouldBe` Just "cannot use 'list' as a dict key (unhashable type: 'list')"
      messageOf "{{}: 1}" `shouldBe` Just "cannot use 'dict' as a dict key (unhashable type: 'dict')"
      messageOf "{((1, [2]),): 3}" `shouldBe` Just "cannot use 'tuple' as a dict key (unhashable type: 'list')"
      messageOf "{(1, {})}" `shouldBe` Just "cannot use 'tuple' as a set element (unhashable type: 'dict')"
    it "round trips repr for finite values" $
      property $ \(Finite value) -> fmap repr (literalEval (repr value)) === Right (repr value)
    it "agrees with JSON for JSON-shaped values" $
      property $ \(Finite value) -> case toJson value of
        Just json -> fmap repr (literalEval (repr (fromJson json))) === Right (repr (fromJson json))
        Nothing -> property True
    it "prints JSON bodies directly exactly as repr of the loaded value" $
      property $ \(Finite value) (Finite other) -> case (toJson value, toJson other) of
        (Just json, Just second) ->
          let body = [("a", json), ("b'\"", second), ("\x1F600", Float (0 / 0)), ("c", Float (-1 / 0))]
           in (dictEntry "k" body === "k:" <> repr (fromJson (Object body)))
                .&&. ( sortedItemsDigest "k" body
                        === "k:" <> repr (LitList [LitTuple [LitStr key, fromJson item] | (key, item) <- body'])
                     )
          where
            body' = [("a", json), ("b'\"", second), ("c", Float (-1 / 0)), ("\x1F600", Float (0 / 0))]
        _ -> property True

kindOf :: Text -> Maybe LiteralErrorKind
kindOf source = either (Just . errorKind) (const Nothing) (literalEval source)

-- | A modeled value without NaN or infinities (whose reprs are names).
newtype Finite = Finite PyValue
  deriving stock (Show)

instance Arbitrary Finite where
  arbitrary = Finite <$> sized value
    where
      value :: Int -> Gen PyValue
      value n
        | n <= 1 = scalar
        | otherwise =
            frequency
              [ (4, scalar)
              , (1, LitList <$> small (value (n `div` 3)))
              , (1, LitTuple <$> small (value (n `div` 3)))
              , (1, LitDict . dedupe <$> small ((,) <$> key <*> value (n `div` 3)))
              ]
      small gen = do
        count <- chooseInt (0, 3)
        vectorOf count gen
      scalar =
        oneof
          [ pure LitNone
          , LitBool <$> arbitrary
          , LitInt <$> arbitrary
          , LitInt . (* (10 ^ (30 :: Int))) <$> arbitrary
          , LitFloat <$> (arbitrary `suchThat` (\d -> not (isNaN d || isInfinite d)))
          , LitStr . T.pack <$> listOf character
          ]
      key = oneof [LitStr . T.pack <$> listOf character, LitInt <$> arbitrary, LitTuple . pure . LitStr . T.pack <$> listOf character]
      character =
        frequency
          [ (6, choose ('a', 'z'))
          , (2, elements "'\"\\\t\n\r\0\x7f #{}[](),:")
          , (2, arbitrary `suchThat` (\c -> c < '\xd800' || c > '\xdfff'))
          ]
      dedupe = go []
        where
          go _ [] = []
          go seen ((k, v) : rest)
            | any (pyEq k) seen = go seen rest
            | otherwise = (k, v) : go (k : seen) rest
