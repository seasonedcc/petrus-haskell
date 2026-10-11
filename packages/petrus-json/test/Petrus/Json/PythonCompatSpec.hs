-- | The CPython-compatibility layer ("Petrus.Json.Python") against the pinned
-- interpreter, live, on generated inputs.
--
-- One oracle run (@test/cpython_compat_oracle.py@, CPython 3.14.6 through
-- @scripts/upstream-python@) answers every case, and every answer is
-- compared exactly:
--
-- * the Unicode predicates on /every/ code point: @str.isprintable@,
--   @str.isspace@, the @str.splitlines@ boundaries and
--   @unicodedata.decimal@;
-- * on generated strings dense in whitespace, line boundaries, controls,
--   quotes, the space separators (U+00A0), characters new in Unicode 16.0
--   (U+105C0) and lone surrogates: @repr@, @strip@, @lstrip@, @rstrip@,
--   @split()@, @splitlines()@ and @isprintable()@;
-- * @repr(bytes)@, and @repr(float)@ (non-finite values included);
-- * @repr@, @str@ and @type(...).__name__@ of what @json.loads@ returns;
-- * the text of @json.loads@'s refusals (@JSONDecodeError@ with line,
--   column and character, and @int()@'s digit limit), plain and with a
--   duplicate-refusing @object_pairs_hook@ and a refusing @parse_constant@
--   (whose order decides which fault a document is refused for);
-- * strict @bytes.decode("utf-8")@'s @UnicodeDecodeError@ text;
-- * @json.detect_encoding@ and the @surrogatepass@ decoding @json.loads@
--   applies to bytes, in every encoding it detects, intact and damaged;
-- * @uuid.uuid4()@'s spelling (@str@ and @hex@) from given random bytes.
module Petrus.Json.PythonCompatSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Char (chr, ord)
import Data.List (nub)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Float (castDoubleToWord64)
import Numeric (showHex)
import Petrus.Json
import Petrus.Json.Generators (documentText, mutated, numberSpelling)
import Petrus.Json.Python
import Petrus.Json.Python.Scanner qualified as Scanner
import Petrus.Json.Reference (repositoryRoot, upstreamPython)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Process.Typed (byteStringInput, proc, readProcess, setStdin, setWorkingDir)
import Test.Hspec
import Test.QuickCheck (Gen, choose, chooseInt, elements, frequency, listOf, oneof, resize, vectorOf)
import Test.QuickCheck.Gen (unGen)
import Test.QuickCheck.Random (mkQCGen)

-- * Transport ------------------------------------------------------------------

codePoints :: String -> Json
codePoints = Array . map (Int . toInteger . ord)

hexOf :: BS.ByteString -> Text
hexOf = TE.decodeUtf8 . BL.toStrict . B.toLazyByteString . B.byteStringHex

request :: Text -> Json -> BS.ByteString
request operation argument = either (error . show) id (dumps compact (Array [String operation, argument]))

-- | One oracle run over every request; its answers in order.
oracle :: [BS.ByteString] -> IO [Either Text Json]
oracle requests = do
  (exe, checkout) <- upstreamPython
  root <- repositoryRoot
  let script = root </> "packages" </> "petrus-json" </> "test" </> "cpython_compat_oracle.py"
      input = BL.fromStrict (BC.unlines requests)
  (code, out, err) <- readProcess (setWorkingDir checkout (setStdin (byteStringInput input) (proc exe ["-I", "-B", script])))
  case code of
    ExitSuccess | BL.null err -> pure (map answer (filter (not . BS.null) (BC.lines (BL.toStrict out))))
    _ -> fail ("the CPython oracle failed: " ++ BC.unpack (BL.toStrict err))
  where
    answer line = case parseJson pythonLoads line of
      Right (Array [String "ok", value]) -> Right value
      Right (Array [String "error", String message]) -> Left message
      other -> error ("bad oracle answer " ++ show other)

asString :: Json -> String
asString = \case
  Array items -> [chr (fromInteger n) | Int n <- items]
  other -> error ("not a code point list: " ++ show other)

member :: Text -> Json -> Json
member key value = maybe (error ("no member " ++ T.unpack key)) id (lookupMember key value)

-- * Generators -----------------------------------------------------------------

generate :: Int -> Gen a -> a
generate seed gen = unGen gen (mkQCGen seed) 30

-- | Characters dense in what the predicates and @repr@ decide on.
pyChar :: Gen Char
pyChar =
  frequency
    [ (10, elements (['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] ++ "_-.:/"))
    , (4, elements " \t\n\r\v\f\x1c\x1d\x1e\x1f\x85\xa0\x1680\x2000\x200a\x200b\x2028\x2029\x202f\x205f\x3000")
    , (2, elements "'\"\\")
    , (2, choose ('\0', '\x1f'))
    , (2, elements "\x7f\x80\x9f\xa0\xa1\xad\xe9\xff\x378\x897\x1c89\x2060\xe000\xfeff\xfffd\xffff")
    , (2, elements "\x105C0\x1CC00\x16D70\x1E5F1\x11BF0\x1F600\xE0001\x10FFFF")
    , (2, elements "\x660\x669\x6F5\x966\xFF10\xFF19\x1D7CE\x1D7FF\x16D79")
    , (3, choose ('\x80', '\x10ffff') `suchThat'` (\c -> c < '\xd800' || c > '\xdfff'))
    ]
  where
    suchThat' gen ok = gen >>= \c -> if ok c then pure c else pure 'x'

-- | A string, now and then holding a lone surrogate.
pyString :: Gen String
pyString = resize 16 (listOf (frequency [(30, pyChar), (1, choose ('\xd800', '\xdfff'))]))

-- | Bytes dense in what a UTF-8 decoder classifies: valid sequences of every
-- length, encoded surrogates, overlong and out-of-range starts, stray
-- continuations, truncations.
utf8ish :: Gen BS.ByteString
utf8ish = BS.concat <$> resize 10 (listOf piece)
  where
    piece =
      frequency
        [ (6, TE.encodeUtf8 . T.singleton <$> pyChar)
        , (2, BS.pack <$> vectorOf 1 (elements [0x80, 0xbf, 0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xed, 0xef, 0xf0, 0xf4, 0xf5, 0xff]))
        , (2, BS.pack <$> elements [[0xed, 0xa0, 0x80], [0xed, 0xbf, 0xbf], [0xed, 0xa0], [0xe0, 0x80, 0x80], [0xf0, 0x80, 0x80, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xe2, 0x82], [0xf0, 0x9f, 0x98], [0xc3]])
        , (1, BS.take <$> chooseInt (1, 3) <*> (TE.encodeUtf8 . T.singleton <$> elements "\x20ac\x1F600\x105C0"))
        ]

-- | @json.loads(bytes)@ input: a document's text in one of the encodings
-- @detect_encoding@ tells apart, with or without a signature, now and then
-- damaged.
encodedDocument :: Gen BS.ByteString
encodedDocument = do
  text <- elements ["{\"a\": [1, 2.5, null]}", "\"x\"", "[]", "1", "{}", "\"\x1F600\xe9\""] >>= \base -> oneof [pure base, T.pack <$> pyString']
  bytes <-
    elements
      [ TE.encodeUtf8 text
      , "\xEF\xBB\xBF" <> TE.encodeUtf8 text
      , TE.encodeUtf16LE text
      , TE.encodeUtf16BE text
      , "\xFF\xFE" <> TE.encodeUtf16LE text
      , "\xFE\xFF" <> TE.encodeUtf16BE text
      , TE.encodeUtf32LE text
      , TE.encodeUtf32BE text
      , "\xFF\xFE\x00\x00" <> TE.encodeUtf32LE text
      , "\x00\x00\xFE\xFF" <> TE.encodeUtf32BE text
      ]
  damage <- chooseInt (0, 3)
  case damage of
    0 -> pure bytes
    1 -> do
      at <- chooseInt (0, BS.length bytes)
      pure (BS.take at bytes)
    2 -> do
      at <- chooseInt (0, BS.length bytes)
      unit <- elements [[0x00, 0xd8], [0xd8, 0x00], [0x00, 0xdc], [0xdc, 0x00], [0x00, 0x00, 0x11, 0x00], [0xed, 0xa0, 0x80], [0xff]]
      pure (BS.take at bytes <> BS.pack unit <> BS.drop at bytes)
    _ -> mutated bytes
  where
    pyString' = resize 6 (listOf pyChar)

-- | Documents for @json.loads@'s refusals: written by the encoder spellings,
-- mutated, number spellings, and keyed objects with repeated members and
-- constants.
loadsDocument :: Gen Text
loadsDocument =
  frequency
    [ (3, TE.decodeUtf8Lenient <$> (documentText >>= mutated))
    , (1, TE.decodeUtf8Lenient <$> documentText)
    , (2, T.pack <$> numberSpelling)
    , (2, keyed)
    , (1, T.pack <$> resize 12 (listOf (elements "{}[],:\" 0123456789-.eEnulltrufalsNaInfiy\\u\n\t")))
    ]
  where
    keyed = do
      count <- chooseInt (0, 4)
      members <- vectorOf count ((,) <$> elements ["a", "b", "\\u00e9", "\\ud800", "\\udbff", "it's"] <*> elements ["1", "NaN", "-Infinity", "[1,", "{\"a\":1,\"a\":2}", "\"x\"", "01", "1e", "\"\\x\""])
      close <- elements ["}", "", ",}", " }"]
      pure ("{" <> T.intercalate "," ["\"" <> k <> "\": " <> v | (k, v) <- members] <> close)

-- * Haskell side -----------------------------------------------------------------

-- | The duplicate-refusing, constant-refusing hooks the oracle's strict
-- profile installs.
strictHooks :: Scanner.Hooks Text
strictHooks =
  Scanner.defaultHooks
    { Scanner.parseConstant = \spelling -> Left ("non-finite JSON number " <> T.pack spelling)
    , Scanner.objectPairs = \pairs -> case duplicates (map fst pairs) of
        key : _ -> Left ("duplicate JSON field " <> pythonStringRepr key)
        [] -> Right ()
    }
  where
    duplicates = go []
      where
        go _ [] = []
        go seen (k : rest)
          | k `elem` seen = [k]
          | otherwise = go (k : seen) rest

strictLoadsError :: Text -> Maybe Text
strictLoadsError text = case Scanner.loads strictHooks text of
  Left (Scanner.DecodeError message position) -> Just (Scanner.decodeErrorText text message position)
  Left (Scanner.HookError message) -> Just message
  Right _ -> Nothing

rangesOf :: (Char -> Bool) -> [(Int, Int)]
rangesOf predicate = foldr add [] [code | code <- [0 .. 0x10FFFF], predicate (chr code)]
  where
    add code ((low, high) : rest) | code + 1 == low = (code, high) : rest
    add code rest = (code, code) : rest

pairsOf :: Json -> [(Int, Int)]
pairsOf = \case
  Array items -> [(fromInteger a, fromInteger b) | Array [Int a, Int b] <- items]
  other -> error ("not a pair list: " ++ show other)

-- * Corpora ---------------------------------------------------------------------

strings :: [String]
strings = nub (["", " ", "\xa0", "\x105C0", "a\r\nb\rc\n", " \t x  y \x3000", "it's", "a\"b'c", "\x16D70\x16D79"] ++ [generate seed pyString | seed <- [1 .. 2500]])

byteStrings :: [BS.ByteString]
byteStrings = nub ["", "\xff", "\xe2\x82", "\xed\xa0\x80", "a\xf0\x9f\x98"] ++ [generate seed utf8ish | seed <- [1 .. 2500]]

jsonByteStrings :: [BS.ByteString]
jsonByteStrings = nub ["", "\x00", "\x00\x41", "\x41\x00", "\xFF\xFE", "\xFE\xFF\x00", "\xEF\xBB\xBF"] ++ [generate seed encodedDocument | seed <- [1 .. 2500]]

doubles :: [Double]
doubles = [0, -0.0, 0 / 0, 1 / 0, -1 / 0, 1e16, 1e-5, 0.1, 5e-324] ++ [generate seed (fromInteger <$> choose (-(10 ^ (20 :: Int)), 10 ^ (20 :: Int))) / 1000 | seed <- [1 .. 300]]

loadsDocuments :: [Text]
loadsDocuments = nub ["", " ", "\xFEFF{}", "[1,]", "{\"a\":1,}", "\"\\ud800\"", "1 2", "{\"a\" 1}", "[1 2]", "\"abc", "\"\\u12\"", "\"\\ud800\\u12x\"", T.replicate 4301 "1"] ++ [generate seed loadsDocument | seed <- [1 .. 4000]]

reprDocuments :: [BS.ByteString]
reprDocuments = [document | seed <- [1 .. 800], let document = generate seed documentText]

uuidSeeds :: [BS.ByteString]
uuidSeeds = BS.replicate 16 0 : BS.replicate 16 0xff : [generate seed (BS.pack <$> vectorOf 16 (fromIntegral <$> chooseInt (0, 255))) | seed <- [1 .. 200 :: Int]]

-- | Every case, in the order the requests go out.
data Case
  = UnicodeCase
  | StringCase String
  | BytesReprCase BS.ByteString
  | FloatReprCase Double
  | JsonReprCase Json
  | LoadsCase Text
  | StrictLoadsCase Text
  | Utf8Case BS.ByteString
  | JsonBytesCase BS.ByteString
  | UuidCase BS.ByteString

cases :: [Case]
cases =
  [UnicodeCase]
    ++ map StringCase strings
    ++ map BytesReprCase byteStrings
    ++ map FloatReprCase doubles
    ++ [JsonReprCase value | document <- reprDocuments, Right value <- [parseJson pythonLoads document]]
    ++ map LoadsCase loadsDocuments
    ++ map StrictLoadsCase loadsDocuments
    ++ map Utf8Case byteStrings
    ++ map JsonBytesCase jsonByteStrings
    ++ map UuidCase uuidSeeds

encodeCase :: Case -> BS.ByteString
encodeCase = \case
  UnicodeCase -> request "unicode" Null
  StringCase s -> request "string" (codePoints s)
  BytesReprCase b -> request "bytes-repr" (String (hexOf b))
  FloatReprCase d -> request "float-repr" (String (T.pack (pad16 (showHex (castDoubleToWord64 d) ""))))
  JsonReprCase value -> request "json-repr" (codePoints (T.unpack (either (error . show) id (dumpsText defaultDumps value))))
  LoadsCase text -> request "json-loads" (codePoints (T.unpack text))
  StrictLoadsCase text -> request "json-loads-strict" (codePoints (T.unpack text))
  Utf8Case b -> request "utf8-decode" (String (hexOf b))
  JsonBytesCase b -> request "json-bytes" (String (hexOf b))
  UuidCase b -> request "uuid4" (String (hexOf b))
  where
    pad16 s = replicate (16 - length s) '0' ++ s

-- | The case's disagreements with the oracle's answer (empty when none).
check :: Case -> Either Text Json -> [String]
check c answer = case (c, answer) of
  (UnicodeCase, Right tables) ->
    concat
      [ compareAs "isprintable ranges" (pairsOf (member "printable" tables)) (rangesOf isPythonPrintable)
      , compareAs "isspace ranges" (pairsOf (member "space" tables)) (rangesOf isPythonSpace)
      , compareAs "splitlines boundaries" (pairsOf (member "linebreak" tables)) (rangesOf isPythonLineBreak)
      , compareAs "unicodedata.decimal" (pairsOf (member "decimal" tables)) [(code, d) | code <- [0 .. 0x10FFFF], Just d <- [pythonDecimal (chr code)]]
      ]
  (StringCase s, Right got) ->
    compareAs ("repr " ++ show s) (asString (member "repr" got)) (T.unpack (pythonStringRepr s))
      ++ if any (\ch -> ord ch >= 0xD800 && ord ch <= 0xDFFF) s
        then []
        else
          let t = T.pack s
              strs = map (T.pack . asString) . arrayOf
           in concat
                [ compareAs ("strip " ++ show s) (T.pack (asString (member "strip" got))) (pythonStrip t)
                , compareAs ("lstrip " ++ show s) (T.pack (asString (member "lstrip" got))) (pythonLstrip t)
                , compareAs ("rstrip " ++ show s) (T.pack (asString (member "rstrip" got))) (pythonRstrip t)
                , compareAs ("split " ++ show s) (strs (member "split" got)) (pythonSplit t)
                , compareAs ("splitlines " ++ show s) (strs (member "splitlines" got)) (pythonSplitlines t)
                , compareAs ("isprintable " ++ show s) (member "isprintable" got) (Bool (pythonIsPrintableText t))
                ]
  (BytesReprCase b, Right got) -> compareAs ("repr " ++ show b) (T.pack (asString got)) (pythonBytesRepr b)
  (FloatReprCase d, Right (String got)) -> compareAs ("repr " ++ show d) got (pythonDoubleRepr d)
  (JsonReprCase value, Right got) ->
    concat
      [ compareAs ("repr " ++ show value) (T.pack (asString (member "repr" got))) (pythonRepr value)
      , compareAs ("str " ++ show value) (T.pack (asString (member "str" got))) (pythonStr value)
      , compareAs ("type " ++ show value) (member "type" got) (String (jsonTypeName value))
      ]
  (LoadsCase text, _) -> compareAs ("json.loads " ++ show text) (either Just (const Nothing) answer) (Scanner.jsonDecodeError text)
  (StrictLoadsCase text, _) -> compareAs ("strict json.loads " ++ show text) (either Just (const Nothing) answer) (strictLoadsError text)
  (Utf8Case b, _) ->
    compareAs ("decode " ++ show b) (either Just (const Nothing) answer) (utf8DecodeError b)
      ++ compareAs ("decodeUtf8Python " ++ show b) (either Left (Right . T.pack . asString) answer) (decodeUtf8Python b)
  (JsonBytesCase b, Right got) ->
    compareAs ("detect_encoding " ++ show b) (member "encoding" got) (String (detectEncoding b))
      ++ case lookupMember "error" got of
        Just (String message) -> compareAs ("json bytes " ++ show b) (Left message) (T.unpack <$> decodeJsonBytes b)
        _ -> compareAs ("json bytes " ++ show b) (Right (asString (member "text" got))) (T.unpack <$> decodeJsonBytes b)
  (UuidCase b, Right got) ->
    compareAs ("uuid4 " ++ show b) (member "str" got) (String (uuid4Text b))
      ++ compareAs ("uuid4 hex " ++ show b) (member "hex" got) (String (uuid4HexText b))
  (_, Left message) -> ["the oracle refused a case it should answer: " ++ T.unpack message]
  (_, Right other) -> ["unexpected oracle answer " ++ show other]
  where
    arrayOf = \case
      Array items -> items
      other -> error ("not a list: " ++ show other)

compareAs :: (Eq a, Show a) => String -> a -> a -> [String]
compareAs label expected actual
  | expected == actual = []
  | otherwise = [label ++ ": CPython " ++ show expected ++ ", petrus-json " ++ show actual]

answers :: [Either Text Json]
answers = unsafePerformIO (oracle (map encodeCase cases))
{-# NOINLINE answers #-}

spec :: Spec
spec = describe "Petrus.Json.Python against the pinned CPython" $ do
  it "answers every case" $
    length answers `shouldBe` length cases
  let described = zip cases answers
      group name select = it name $ do
        let mine = [(c, a) | (c, a) <- described, select c]
        length mine `shouldSatisfy` (> 0)
        take 10 (concatMap (uncurry check) mine) `shouldBe` []
  group "agrees on every code point (isprintable, isspace, line boundaries, decimal)" $ \case UnicodeCase -> True; _ -> False
  group "agrees on repr, strip, split, splitlines and isprintable of generated strings" $ \case StringCase _ -> True; _ -> False
  group "agrees on repr(bytes)" $ \case BytesReprCase _ -> True; _ -> False
  group "agrees on repr(float)" $ \case FloatReprCase _ -> True; _ -> False
  group "agrees on repr, str and type name of json.loads values" $ \case JsonReprCase _ -> True; _ -> False
  group "agrees on json.loads refusal texts" $ \case LoadsCase _ -> True; _ -> False
  group "agrees on hooked json.loads refusal texts (hook order)" $ \case StrictLoadsCase _ -> True; _ -> False
  group "agrees on bytes.decode('utf-8') errors" $ \case Utf8Case _ -> True; _ -> False
  group "agrees on json.loads(bytes) decoding (detect_encoding, surrogatepass)" $ \case JsonBytesCase _ -> True; _ -> False
  group "agrees on uuid4's spelling" $ \case UuidCase _ -> True; _ -> False
  it "covers both outcomes" $ do
    let refusals = length [() | (LoadsCase _, Left _) <- described]
        admissions = length [() | (LoadsCase _, Right _) <- described]
        undecodable = length [() | (JsonBytesCase _, Right got) <- described, isJust (lookupMember "error" got)]
        decodable = length [() | (JsonBytesCase _, Right got) <- described, isNothing (lookupMember "error" got)]
    forM_ [refusals, admissions, undecodable, decodable] (`shouldSatisfy` (> 100))
  it "fixes the space separators and Unicode 16.0 additions" $ do
    pythonStrRepr "\xa0" `shouldBe` "'\\xa0'"
    pythonStrRepr "\x105C0" `shouldBe` "'\x105C0'"
