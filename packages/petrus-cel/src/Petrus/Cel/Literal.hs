-- | Literal tokens and how cel-python turns their source text into values.
--
-- cel-python cooks string and bytes literals with its own escape regex
-- (@CEL_ESCAPES_PAT@), which deviates from the CEL specification in ways this
-- module reproduces:
--
-- * newlines inside a triple-quoted (non-raw) literal are dropped, because the
--   pattern's catch-all @.@ does not match @\\n@ (a @\\r@ is kept);
-- * unknown escapes such as @\\z@ keep their backslash;
-- * @\\ddd@ is read with Python's @int(..., 8)@, so Unicode digits count and
--   @\\999@ fails with @int()@'s message;
-- * in bytes, @\\u@ escapes above 255 fail with @bytes()@'s range error and a
--   @\\U@ escape raises a @TypeError@ from @ord()@ that escapes evaluation;
-- * @-1u@ and other out-of-range integers fail only when evaluated (with the
--   message @overflow@), never at parse time.
module Petrus.Cel.Literal
  ( LiteralKind (..)
  , LiteralValue (..)
  , cookLiteral
  , literalTokenType
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr, isHexDigit, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Numeric (readHex)

import Petrus.Cel.Python (asciiTransform, parseFloatText, parseIntDigits, strRepr)
import Petrus.Cel.Unicode (pythonDecimal)

-- | The lexical class of a literal token (lark's terminal names).
data LiteralKind
  = IntLiteral
  | UintLiteral
  | FloatLiteral
  | StringLiteral
  | MultilineStringLiteral
  | BytesLiteral
  | BoolLiteral
  | NullLiteral
  deriving stock (Eq, Ord, Show)

-- | The lark terminal name of a literal kind (@INT_LIT@, ...).
literalTokenType :: LiteralKind -> Text
literalTokenType = \case
  IntLiteral -> "INT_LIT"
  UintLiteral -> "UINT_LIT"
  FloatLiteral -> "FLOAT_LIT"
  StringLiteral -> "STRING_LIT"
  MultilineStringLiteral -> "MLSTRING_LIT"
  BytesLiteral -> "BYTES_LIT"
  BoolLiteral -> "BOOL_LIT"
  NullLiteral -> "NULL_LIT"

-- | What evaluating a literal produces.
data LiteralValue
  = LitInt Integer
  | LitUint Integer
  | LitDouble Double
  | LitString Text
  | LitBytes ByteString
  | LitBool Bool
  | LitNull
  | -- | A @ValueError@ while cooking; the literal evaluates to a @CELEvalError@
    -- carrying this message.
    LitValueError Text
  | -- | A @TypeError@ while cooking; cel-python does not catch it, so the
    -- whole evaluation fails with it.
    LitTypeError Text
  deriving stock (Eq, Show)

-- | Cook a literal token's source text exactly like cel-python's evaluator.
cookLiteral :: LiteralKind -> Text -> LiteralValue
cookLiteral kind text = case kind of
  IntLiteral -> intType text
  UintLiteral -> uintType (T.dropEnd 1 text)
  FloatLiteral -> maybe (LitValueError ("could not convert string to float: " <> strRepr text)) LitDouble (parseFloatText text)
  StringLiteral -> cookString text
  MultilineStringLiteral -> cookString text
  BytesLiteral -> cookBytes text
  BoolLiteral -> LitBool (T.toLower text == "true")
  NullLiteral -> LitNull

int64 :: Integer -> LiteralValue
int64 n
  | n >= -(2 ^ (63 :: Int)) && n < 2 ^ (63 :: Int) = LitInt n
  | otherwise = LitValueError "overflow"

-- | @IntType(text)@ for a lexed @INT_LIT@.
intType :: Text -> LiteralValue
intType text
  | Just rest <- T.stripPrefix "-0x" text = either (const bad) (int64 . negate) (parseIntDigits 16 (asciiTransform rest))
  | Just rest <- T.stripPrefix "0x" text = either (const bad) int64 (parseIntDigits 16 (asciiTransform rest))
  | otherwise = either (const bad) int64 (parseIntDigits 10 (asciiTransform text))
  where
    bad = LitValueError ("invalid literal for int() with base 10: " <> strRepr text)

-- | @UintType(text[:-1])@ for a lexed @UINT_LIT@: only a @0x@ prefix is
-- special, so @-0x1u@ fails as a decimal literal.
uintType :: Text -> LiteralValue
uintType text =
  let parsed = case T.stripPrefix "0x" text of
        Just rest -> (16, parseIntDigits 16 (asciiTransform rest))
        Nothing -> (10 :: Int, parseIntDigits 10 (asciiTransform text))
   in case parsed of
        (_, Right n)
          | n >= 0 && n < 2 ^ (64 :: Int) -> LitUint n
          | otherwise -> LitValueError "overflow"
        (base, Left _) ->
          LitValueError ("invalid literal for int() with base " <> T.pack (show base) <> ": " <> strRepr (if base == 16 then T.drop 2 text else text))

-- | One match of @CEL_ESCAPES_PAT@.
data Piece
  = Plain Char
  | Simple Char
  | Octal Text
  | Hex2 Int
  | Unicode4 Int
  | Unicode8 Text Int

-- | @CEL_ESCAPES_PAT.finditer@: ordered alternatives at each position; a
-- position no alternative matches (a newline) is skipped.
escapes :: String -> [Piece]
escapes = \case
  [] -> []
  '\\' : c : rest
    | c `elem` ("abfnrtv\"'\\" :: String) -> Simple c : escapes rest
  '\\' : a : b : c : rest
    | all isPyDigit [a, b, c] -> Octal (T.pack [a, b, c]) : escapes rest
  '\\' : 'x' : a : b : rest
    | all isHexDigit [a, b] -> Hex2 (hexValue [a, b]) : escapes rest
  '\\' : 'u' : rest
    | (ds, rest') <- splitAt 4 rest, length ds == 4, all isHexDigit ds -> Unicode4 (hexValue ds) : escapes rest'
  '\\' : 'U' : rest
    | (ds, rest') <- splitAt 8 rest, length ds == 8, all isHexDigit ds -> Unicode8 (T.pack ('\\' : 'U' : ds)) (hexValue ds) : escapes rest'
  '\n' : rest -> escapes rest
  c : rest -> Plain c : escapes rest
  where
    isPyDigit c = pythonDecimal c /= Nothing

hexValue :: String -> Int
hexValue ds = case readHex ds of
  [(v, "")] -> v
  _ -> 0

simpleEscape :: Char -> Char
simpleEscape = \case
  'a' -> '\a'
  'b' -> '\b'
  'f' -> '\f'
  'n' -> '\n'
  'r' -> '\r'
  't' -> '\t'
  'v' -> '\v'
  c -> c

octalValue :: Text -> Either Text Integer
octalValue digits = case parseIntDigits 8 (asciiTransform digits) of
  Right v -> Right v
  Left _ -> Left ("invalid literal for int() with base 8: " <> strRepr digits)

pyChr :: Integer -> Either Text Char
pyChr n
  | n < 0 || n > 0x10FFFF = Left "chr() arg not in range(0x110000)"
  | otherwise = Right (chr (fromIntegral n))

-- | Is the literal written with a triple quote right after @prefixLength@
-- characters?
tripleAt :: Int -> Text -> Bool
tripleAt n text = let q = T.take 3 (T.drop n text) in q == "\"\"\"" || q == "'''"

-- | Cook a @STRING_LIT@ or @MLSTRING_LIT@ (celpy's @celstr@).
cookString :: Text -> LiteralValue
cookString text
  | T.take 1 text `elem` ["r", "R"] =
      LitString (if tripleAt 1 text then slice 4 3 else slice 2 1)
  | otherwise =
      let body = if tripleAt 0 text then slice 3 3 else slice 1 1
       in either LitValueError (LitString . T.pack) (traverse expand (escapes (T.unpack body)))
  where
    slice front back = T.dropEnd back (T.drop front text)
    expand = \case
      Plain c -> Right c
      Simple c -> Right (simpleEscape c)
      Hex2 v -> Right (chr v)
      Unicode4 v -> pyChr (fromIntegral v)
      Unicode8 _ v -> pyChr (fromIntegral v)
      Octal ds -> octalValue ds >>= pyChr

-- | Cook a @BYTES_LIT@ (celpy's @celbytes@).
cookBytes :: Text -> LiteralValue
cookBytes text
  | T.toLower (T.take 2 text) == "br" =
      let body = if tripleAt 2 text then slice 5 3 else slice 3 1
       in toBytes (map (Right . fromIntegral . ord) (T.unpack body))
  | otherwise =
      let body = if tripleAt 1 text then slice 4 3 else slice 2 1
       in toBytes (concatMap expand (escapes (T.unpack body)))
  where
    slice front back = T.dropEnd back (T.drop front text)
    expand :: Piece -> [Either (Bool, Text) Integer]
    expand = \case
      Plain c -> map (Right . fromIntegral) (BS.unpack (TE.encodeUtf8 (T.singleton c)))
      Simple c -> [Right (fromIntegral (ord (simpleEscape c)))]
      Hex2 v -> [Right (fromIntegral v)]
      Unicode4 v -> [Right (fromIntegral v)]
      Unicode8 escape _ ->
        [Left (True, "ord() expected a character, but string of length " <> T.pack (show (T.length escape)) <> " found")]
      Octal ds -> [either (\m -> Left (False, m)) Right (octalValue ds)]
    -- bytes(iterable) consumes items in order and fails on the first bad one.
    toBytes :: [Either (Bool, Text) Integer] -> LiteralValue
    toBytes items = go [] items
      where
        go acc = \case
          [] -> LitBytes (BS.pack (reverse acc))
          Right v : rest
            | v >= 0 && v < 256 -> go (fromIntegral v : acc) rest
            | otherwise -> LitValueError "bytes must be in range(0, 256)"
          Left (True, message) : _ -> LitTypeError message
          Left (False, message) : _ -> LitValueError message
