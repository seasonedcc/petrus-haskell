-- | QuickCheck properties: totality of the parser and evaluator on
-- arbitrary token soup, and the evaluator against Haskell's own
-- arithmetic, comparison, and string semantics on random data.
module Properties
  ( spec
  ) where

import Data.Int (Int64)
import Data.Char (isAlphaNum)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Petrus.Cel
import Petrus.Cel.Value (Value (..))
import Petrus.Json (Json (..))

-- | A source text made of CEL tokens, mostly ill-formed.
newtype Soup = Soup Text
  deriving stock (Show)

instance Arbitrary Soup where
  arbitrary = do
    n <- chooseInt (0, 14)
    Soup . T.unwords <$> vectorOf n (elements fragments)
    where
      fragments =
        [ "a", "b", "x", "size", "has", "exists", "all", "map", "filter", "(", ")", "[", "]", "{", "}"
        , ",", ".", ":", "?", "+", "-", "*", "/", "%", "!", "==", "!=", "<", "<=", ">", ">=", "&&", "||"
        , "in", "1", "0", "-1", "2u", "1.5", "1e3", "\"s\"", "'t'", "b\"x\"", "r'\\d'", "true", "false"
        , "null", "int", "uint", "double", "string", "matches", "startsWith", "duration", "timestamp"
        , "a.b", "x.y", "9223372036854775807", "18446744073709551615u", "\"\\u00e9\""
        ]

environment :: [(Text, Json)]
environment =
  [ ("a", Int 3)
  , ("b", Array [Int 1, String "two", Null])
  , ("x", Object [("y", Float 1.5), ("z", Bool True)])
  ]

-- | Fully force an outcome through its rendering.
forced :: Either Exc Value -> Int
forced = either (T.length . excRepr) (\v -> T.length (valueRepr v) + fromEnum (truthy v))

int64 :: Integer -> Bool
int64 n = n >= toInteger (minBound :: Int64) && n <= toInteger (maxBound :: Int64)

evalWith :: Text -> [(Text, Json)] -> Either Exc Value
evalWith source env = case compile source of
  Left err -> error ("does not parse: " <> show source <> " " <> show err)
  Right program -> evaluateJson program env

holds :: Text -> [(Text, Json)] -> Bool
holds source env = either (const False) truthy (evalWith source env)

intOf :: Either Exc Value -> Maybe Integer
intOf = \case
  Right (VInt n) -> Just n
  _ -> Nothing

spec :: Spec
spec = describe "properties" $ do
  prop "compile and evaluate are total on token soup" $ \(Soup source) ->
    case compile source of
      Left err -> T.length (parseErrorMessage err) >= 0
      Right program ->
        forced (evaluateJson program environment) >= 0
          && Set.size (freeVariables program) >= 0

  -- Not necessarily whole words: cel-python's contextual lexer reads
  -- @true int@ as @true in t@ (after an operand only @in@ can follow), and
  -- so does this parser.
  prop "free variables are identifier spellings within the source" $ \(Soup source) ->
    case compile source of
      Left _ -> property True
      Right program ->
        let words' = T.split (\c -> not (isAlphaNum c || c == '_')) source
            spelled name = T.all (\c -> isAlphaNum c || c == '_') name && any (name `T.isInfixOf`) words'
         in counterexample (show (freeVariables program)) (all spelled (Set.toList (freeVariables program)))

  it "lexes like cel-python's contextual lexer: true int is true in t" $
    fmap (Set.toList . freeVariables) (compile "true int") `shouldBe` Right ["t"]

  prop "compile is deterministic" $ \(Soup source) ->
    fmap programExpr (compile source) == fmap programExpr (compile source)

  prop "int + - * agree with Integer arithmetic, overflow is an error" $ \(a :: Int64) (b :: Int64) ->
    let env = [("a", Int (toInteger a)), ("b", Int (toInteger b))]
        check op f =
          let exact = f (toInteger a) (toInteger b)
              got = evalWith ("a " <> op <> " b") env
           in counterexample (T.unpack op <> " " <> either (T.unpack . excRepr) (T.unpack . valueRepr) got) $
                if int64 exact then intOf got == Just exact else either (const True) (const False) got
     in check "+" (+) .&&. check "-" (-) .&&. check "*" (*)

  prop "int / and % truncate toward zero" $ \(a :: Int64) (NonZero (b :: Int64)) ->
    let env = [("a", Int (toInteger a)), ("b", Int (toInteger b))]
        q = toInteger a `quot` toInteger b
     in int64 q ==> intOf (evalWith "a / b" env) == Just q
          .&&. intOf (evalWith "a % b" env) == Just (toInteger a `rem` toInteger b)

  prop "int comparisons agree with Ord" $ \(a :: Int64) (b :: Int64) ->
    let env = [("a", Int (toInteger a)), ("b", Int (toInteger b))]
     in holds "a < b" env == (a < b)
          && holds "a <= b" env == (a <= b)
          && holds "a == b" env == (a == b)
          && holds "a != b" env == (a /= b)
          && holds "a > b" env == (a > b)
          && holds "a >= b" env == (a >= b)

  prop "string size, concatenation, and prefix tests agree with Text" $ \(ASCIIString s) (ASCIIString t) ->
    let (s', t') = (T.pack s, T.pack t)
        env = [("s", String s'), ("t", String t'), ("n", Int (toInteger (T.length s' + T.length t')))]
     in holds "size(s + t) == n" env
          && holds "(s + t).startsWith(s)" env
          && holds "(s + t).endsWith(t)" env
          && holds "s + t == t + s" env == (s' <> t' == t' <> s')

  prop "list membership agrees with elem" $ \(xs :: [Int64]) (x :: Int64) ->
    let env = [("xs", Array (map (Int . toInteger) xs)), ("x", Int (toInteger x))]
     in holds "x in xs" env == (x `elem` xs)
          && holds "xs.exists(e, e == x)" env == (x `elem` xs)
          && holds "size(xs.filter(e, e > x)) == size(xs) - size(xs.filter(e, e <= x))" env

  -- Beyond the corpus (which records an error's first argument only): a
  -- string holding a lone surrogate raises CPython's UnicodeEncodeError
  -- wherever cel-python encodes it, with every argument. The expected
  -- texts are celpy's own repr of the raised CELEvalError.
  describe "lone-surrogate strings" $
    it "raise UnicodeEncodeError with CPython's arguments where cel-python encodes them" $ do
      let rendered source = either (error . show) (either excRepr valueRepr . (`evaluateJson` [])) (compile source)
      rendered "bytes('a\\uD800')"
        `shouldBe` "CELEvalError(*('return error for overflow', <class 'UnicodeEncodeError'>, ('utf-8', StringType('a\\ud800'), 1, 2, 'surrogates not allowed')))"
      rendered "('x' + '\\uD800\\uDC00').matches('.')"
        `shouldBe` "CELEvalError(*('return error for overflow', <class 'UnicodeEncodeError'>, ('utf-8', 'x\\ud800\\udc00', 1, 3, 'surrogates not allowed')))"
      rendered "bytes('\\uD800') == b'' || true" `shouldBe` "BoolType(True)"

  -- string(bytes) raises CPython's UnicodeDecodeError with the range of the
  -- first malformed sequence (the expected texts are celpy 0.5.0's own).
  describe "undecodable bytes" $
    it "raise UnicodeDecodeError with CPython's arguments" $ do
      let rendered source = either (error . show) (either excRepr valueRepr . (`evaluateJson` [])) (compile source)
          decodeError arguments = "CELEvalError(*('return error for overflow', <class 'UnicodeDecodeError'>, ('utf-8', " <> arguments <> ")))"
      rendered "string(b'\\xff')" `shouldBe` decodeError "b'\\xff', 0, 1, 'invalid start byte'"
      rendered "string(b'\\xe2\\x82')" `shouldBe` decodeError "b'\\xe2\\x82', 0, 2, 'unexpected end of data'"
      rendered "string(b'\\xe2\\x82A')" `shouldBe` decodeError "b'\\xe2\\x82A', 0, 2, 'invalid continuation byte'"
      rendered "string(b'a\\xf0\\x9f\\x98')" `shouldBe` decodeError "b'a\\xf0\\x9f\\x98', 1, 4, 'unexpected end of data'"
