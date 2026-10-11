module JsonSpec (spec) where

import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Viewer.Json
import Test.Hspec
import Test.QuickCheck
import TestSupport (fixturePath)

-- | @JSON.stringify(JSON.parse(input))@, or the @SyntaxError@ message.
roundTrip :: Text -> Either Text Text
roundTrip = either (Left . jsStringText) Right . roundTripJs

-- | 'roundTrip' with the message as a JavaScript string (lone surrogates
-- kept).
roundTripJs :: Text -> Either JsString Text
roundTripJs input = TE.decodeUtf8 . encodeJs <$> parseJs (TE.encodeUtf8 input)

stringify :: B.ByteString -> Either JsString B.ByteString
stringify = fmap encodeJs . parseJs

spec :: Spec
spec = do
  describe "JSON.parse / JSON.stringify semantics" $ do
    it "matches V8 on a recorded corpus of 1800+ documents (results and error messages)" $ do
      raw <- B.readFile (fixturePath "json-parse-v8.json")
      cases <- case parseJs raw of
        Right (JsArr cs) -> pure cs
        _ -> fail "bad fixture"
      let expected v = case asObject v of
            Just o
              | Just (JsStr s) <- lookupKey "ok" o -> Just (Right (jsStringText s))
              | Just (JsStr s) <- lookupKey "error" o -> Just (Left s)
            _ -> Nothing
          mismatches =
            [ (input, got, want)
            | JsArr [JsStr i, e] <- cases
            , Just want <- [expected e]
            , let input = jsStringText i
            , let got = roundTripJs input
            , got /= want
            ]
      length cases `shouldSatisfy` (> 1800)
      take 5 mismatches `shouldBe` []

    it "keeps the lone surrogate V8's message cuts from a pair" $ do
      -- recorded from Node 22 (JSON.stringify of e.message)
      let message s = either (Just . TE.decodeUtf8 . jsStringBytes) (const Nothing) (parseJs (TE.encodeUtf8 s))
      message "[\x1F600]" `shouldBe` Just "Unexpected token '\\ud83d', \\\"[\x1F600]\\\" is not valid JSON"
      message "[1,aaaaaaaaa\x1F600\&bbbbbbbbbbbbbbb"
        `shouldBe` Just "Unexpected token 'a', \\\"[1,aaaaaaaaa\\ud83d\\\"... is not valid JSON"
      message (T.replicate 12 "\x1F600")
        `shouldBe` Just "Unexpected token '\\ud83d', \\\"\x1F600\x1F600\x1F600\x1F600\x1F600\\\"... is not valid JSON"

    it "formats numbers like Number.prototype.toString" $ do
      stringify "[1e21,1e-7,1e-6,123e-20,-0,0.1,5e-324,100,1.0,9007199254740993,0.30000000000000004,1E+2,-1e400]"
        `shouldBe` Right "[1e+21,1e-7,0.000001,1.23e-18,0,0.1,5e-324,100,1,9007199254740992,0.30000000000000004,100,null]"
      -- Recorded from Node 22: the rounding interval's ends are admitted for
      -- an even significand, and exact ties go to even.
      stringify "[9.999999999999999e22,99999999999999991611392,2.98023223876953125e-8,1.2345678901234567e-300,123456789012345678]"
        `shouldBe` Right "[1e+23,1e+23,2.9802322387695312e-8,1.2345678901234568e-300,123456789012345680]"

    it "orders integer-like keys first and keeps the last duplicate in the first position" $ do
      stringify "{\"b\":1,\"a\":2,\"10\":3,\"2\":4,\"4294967295\":5,\"4294967294\":6,\"01\":7,\"b\":8}"
        `shouldBe` Right "{\"2\":4,\"10\":3,\"4294967294\":6,\"b\":8,\"a\":2,\"4294967295\":5,\"01\":7}"

    it "escapes strings like JSON.stringify (lone surrogates as \\u escapes)" $ do
      roundTrip "\"\\u00e9\\ud83d\\ude00\\ud800\\u2028\\u001f\\/\""
        `shouldBe` Right "\"\xe9\x1F600\\ud800\x2028\\u001f/\""

    it "reports V8's messages" $ do
      roundTrip "" `shouldBe` Left "Unexpected end of JSON input"
      roundTrip "tru-e" `shouldBe` Left "Unexpected number in JSON at position 3 (line 1 column 4)"
      roundTrip "[1\r\n]x" `shouldBe` Left "Unexpected non-whitespace character after JSON at position 5 (line 2 column 2)"
      roundTrip "\"\\x\"" `shouldBe` Left "Bad escaped character in JSON at position 2 (line 1 column 3)"
      roundTrip "\"\\Ā\"" `shouldBe` Left "Unexpected token 'Ā', \"\"\\Ā\"\" is not valid JSON"
      roundTrip "undefined" `shouldBe` Left "\"undefined\" is not valid JSON"
      roundTrip "<!doctype html><html></html>"
        `shouldBe` Left "Unexpected token '<', \"<!doctype \"... is not valid JSON"

  describe "properties" $ do
    it "jsString escapes like JSON.stringify and decodes back" $
      property $ \(StrText t) ->
        let s = jsString t
         in (jsStringBytes s === TE.encodeUtf8 (T.concatMap stringifyChar t)) .&&. (jsStringText s === t)
    it "encoding is a fixed point of parse . encode" $
      property $ \(Doc v) -> stringify (encodeJs v) === Right (encodeJs v)
    it "pretty output parses back to the same value" $
      property $ \(Doc v) -> stringify (encodePretty v) === Right (encodeJs v)
    it "pretty output is JSON.stringify(v, null, 2) byte for byte" $ do
      -- recorded from Node 22
      fmap encodePretty (parseJs "{\"a\":[1,{\"b\":[]}],\"c\":{},\"d\\\"\":\"x\\n\"}")
        `shouldBe` Right "{\n  \"a\": [\n    1,\n    {\n      \"b\": []\n    }\n  ],\n  \"c\": {},\n  \"d\\\"\": \"x\\n\"\n}"
    it "pretty output matches a direct spelling of the format" $
      property $ \(Doc v) -> encodePretty v === prettyRef 0 v

-- | @JSON.stringify(v, null, 2)@ spelled out directly.
prettyRef :: Int -> JsValue -> B.ByteString
prettyRef ind = \case
  JsArr [] -> "[]"
  JsArr xs -> container "[" "]" [prettyRef (ind + 1) x | x <- xs]
  JsObj o
    | null (objectToList o) -> "{}"
    | otherwise -> container "{" "}" ["\"" <> jsStringBytes k <> "\": " <> prettyRef (ind + 1) x | (k, x) <- objectToList o]
  other -> encodeJs other
  where
    pad n = B.replicate (2 * n) 0x20
    container open close items =
      open <> "\n" <> B.intercalate ",\n" (map (pad (ind + 1) <>) items) <> "\n" <> pad ind <> close

newtype Doc = Doc JsValue
  deriving stock (Show)

instance Arbitrary Doc where
  arbitrary = Doc <$> sized (go . min 4)
    where
      go :: Int -> Gen JsValue
      go 0 = scalar
      go n =
        frequency
          [ (3, scalar)
          , (1, arr <$> resize 4 (listOf (go (n - 1))))
          , (1, obj <$> resize 5 (listOf ((,) <$> key <*> go (n - 1))))
          ]
      scalar =
        oneof
          [ pure JsNull
          , JsBool <$> arbitrary
          , num <$> (arbitrary `suchThat` (\d -> not (isNaN d || isInfinite d)))
          , int <$> arbitrary
          , str . T.pack <$> listOf (oneof [arbitrary, elements "\"\\\n\t\x7f\xe9\x2028\x1F600"])
          ]
      key = elements ["a", "b", "0", "1", "10", "01", "-1", "4294967294", "4294967295", "é", ""]

-- | Text weighted towards the characters JSON.stringify escapes.
newtype StrText = StrText Text
  deriving stock (Show)

instance Arbitrary StrText where
  arbitrary =
    StrText . T.pack
      <$> listOf
        ( frequency
            [ (3, choose ('\0', '\x7f'))
            , (2, elements "\"\\\n\r\t\b\f\x1f\x7f")
            , (1, choose ('\x80', '\x10ffff') `suchThat` (\c -> c < '\xd800' || c > '\xdfff'))
            ]
        )
  shrink (StrText t) = StrText . T.pack <$> shrink (T.unpack t)

-- | One character as JSON.stringify writes it inside a string literal.
stringifyChar :: Char -> Text
stringifyChar = \case
  '"' -> "\\\""
  '\\' -> "\\\\"
  '\n' -> "\\n"
  '\r' -> "\\r"
  '\t' -> "\\t"
  '\b' -> "\\b"
  '\f' -> "\\f"
  c
    | c < ' ' -> T.pack ("\\u00" ++ [hex (fromEnum c `div` 16), hex (fromEnum c `mod` 16)])
    | otherwise -> T.singleton c
  where
    hex d = "0123456789abcdef" !! d
