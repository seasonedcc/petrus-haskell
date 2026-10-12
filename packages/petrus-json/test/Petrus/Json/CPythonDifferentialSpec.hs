-- | petrus-json against CPython's own @json@ module, for every configuration
-- the pinned upstream uses.
--
-- The configurations are the ones @upstream/petrus/src@ and
-- @upstream/hamsterdan/src@ pass (an AST survey of every @json.dumps@ and
-- @json.loads@ call; the PARITY ledger lists them with a call site each):
--
-- * sixteen @json.dumps@ keyword combinations of @sort_keys@, @separators@,
--   @ensure_ascii@, @allow_nan@ and @indent@, each an 'EncodeOptions' value;
-- * four @json.loads@ admission profiles: no hooks; a duplicate-refusing
--   @object_pairs_hook@ with a refusing @parse_constant@ (Pi, DST, Net
--   documents); the simulation service's strict loader, which also round
--   trips the value through a strict UTF-8 @json.dumps@; and the Net
--   definition v3 hooks (safe-range @parse_int@, refusing @parse_float@).
--
-- A deterministic corpus (fixed seeds) goes through the pinned interpreter
-- (@test/cpython_json_oracle.py@, run with @scripts/upstream-python@'s
-- CPython 3.14.6) and through petrus-json, and every answer is compared:
--
-- * @dumps@: the exact bytes, or the exact refusal text (@allow_nan=False@'s
--   @Out of range float values …@ and @int.__repr__@'s 4300-digit
--   @Exceeds the limit …@), in writer order;
-- * @loads@: acceptance, then the exact value (integer versus float, @-0.0@,
--   member order, the last duplicate's value at the first position), and the
--   exact 4300-digit refusal text where CPython raises it. With
--   'KeepLoneSurrogates', the plain profile admits exactly what CPython does,
--   lone surrogates included (as WTF-8, "Petrus.Json.Wtf8"), value for value.
--   Two documented divergences ("DIVERGENCES.md") are checked as such: under
--   the default 'RefuseLoneSurrogates' a document CPython admits with a lone
--   surrogate escape is refused with the surrogate message, and other
--   refusals are compared as refusals (CPython's @JSONDecodeError@ texts
--   carry line and column, petrus-json's a byte offset).
--
-- The @dumps@ corpus holds strings with lone surrogates too: under
-- @ensure_ascii@ both sides escape them, otherwise both write the @str@'s
-- WTF-8 bytes (the oracle encodes with @surrogatepass@).
module Petrus.Json.CPythonDifferentialSpec (spec) where

import Control.Monad (forM_, unless, when)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Char (chr, digitToInt, isHexDigit)
import Data.List (nubBy)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Numeric (readHex, showHex)
import Petrus.Json
import Petrus.Json.Generators (documentText, mutated, numberSpelling, soup)
import Petrus.Json.Reference (repositoryRoot, upstreamPython)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process.Typed (byteStringInput, proc, readProcess, setStdin, setWorkingDir)
import Test.Hspec
import Test.QuickCheck (Gen, choose, chooseInt, elements, frequency, listOf, oneof, resize, sized, suchThat, vectorOf)
import Test.QuickCheck.Gen (unGen)
import Test.QuickCheck.Random (mkQCGen)

-- * Configurations -------------------------------------------------------------

-- | Every @json.dumps@ keyword combination upstream passes (default=… aside:
-- it only converts objects a 'Json' cannot hold), with its options.
dumpsConfigurations :: [(String, EncodeOptions)]
dumpsConfigurations =
  [ ("{}", defaultDumps)
  , ("{\"separators\":[\",\",\":\"],\"sort_keys\":true}", tight {sortKeys = True})
  , ("{\"allow_nan\":false,\"separators\":[\",\",\":\"],\"sort_keys\":true}", tight {sortKeys = True, allowNan = False})
  , ("{\"allow_nan\":false}", defaultDumps {allowNan = False})
  , ("{\"allow_nan\":false,\"ensure_ascii\":false,\"separators\":[\",\",\":\"],\"sort_keys\":true}", compact {sortKeys = True})
  , ("{\"separators\":[\",\",\":\"]}", tight)
  , ("{\"sort_keys\":true}", defaultDumps {sortKeys = True})
  , ("{\"allow_nan\":false,\"ensure_ascii\":false,\"separators\":[\",\",\":\"]}", compact)
  , ("{\"indent\":2,\"sort_keys\":true}", defaultDumps {indent = Just 2, sortKeys = True})
  , ("{\"allow_nan\":false,\"separators\":[\",\",\":\"]}", tight {allowNan = False})
  , ("{\"ensure_ascii\":true,\"separators\":[\",\",\":\"],\"sort_keys\":true}", tight {sortKeys = True, ensureAscii = True})
  , ("{\"allow_nan\":false,\"ensure_ascii\":false}", defaultDumps {allowNan = False, ensureAscii = False})
  , ("{\"ensure_ascii\":false,\"separators\":[\",\",\":\"],\"sort_keys\":true}", tight {sortKeys = True, ensureAscii = False})
  , ("{\"allow_nan\":false,\"ensure_ascii\":false,\"indent\":2}", indented)
  , ("{\"ensure_ascii\":false,\"separators\":[\",\",\":\"]}", tight {ensureAscii = False})
  , ("{\"indent\":2}", defaultDumps {indent = Just 2})
  ]
  where
    tight = defaultDumps {itemSeparator = Just ",", keySeparator = ":"}

-- | The plain profile keeping lone surrogates: compared with the oracle's
-- plain answer, value for value.
keepingSurrogates :: ParseOptions
keepingSurrogates = pythonJsonLoads

-- | The @json.loads@ admission profiles, in the oracle's order.
loadsProfiles :: [(String, ParseOptions)]
loadsProfiles =
  [ ("plain", surrogateRefusingLoads)
  , ("unique-no-constants", surrogateRefusingLoads {duplicateMembers = RejectDuplicates, allowNonFiniteConstants = False})
  , ("simulation-http", strictLoads)
  , ("net-definition-v3", strictLoads {integerTokensOnly = True, integerRange = Just (safeIntegerMin, safeIntegerMax)})
  ]

-- * Transport ------------------------------------------------------------------

hex :: BS.ByteString -> Json
hex = String . TE.decodeUtf8 . BL.toStrict . B.toLazyByteString . B.byteStringHex

-- | A value in the oracle's tagged transport.
tag :: Json -> Json
tag = \case
  Null -> Array [String "N"]
  Bool True -> Array [String "T"]
  Bool False -> Array [String "F"]
  Int i -> Array [String "i", String (T.pack ((if i < 0 then "-" else "") ++ showHex (abs i) ""))]
  Float d -> Array [String "d", String (T.pack (pad16 (showHex (castDoubleToWord64 d) "")))]
  String s -> Array [String "s", hex (TE.encodeUtf8 s)]
  Array items -> Array [String "a", Array (map tag items)]
  Object members -> Array [String "o", Array [Array [hex (TE.encodeUtf8 k), tag v] | (k, v) <- members]]
  where
    pad16 s = replicate (16 - length s) '0' ++ s

-- | A tagged value back (strings with lone surrogates as WTF-8); 'Nothing'
-- when bytes are not even generalized UTF-8.
untag :: Json -> Maybe Json
untag = \case
  Array [String "N"] -> Just Null
  Array [String "T"] -> Just (Bool True)
  Array [String "F"] -> Just (Bool False)
  Array [String "i", String digits] -> Just (Int (readSignedHex (T.unpack digits)))
  Array [String "d", String bits] -> Just (Float (castWord64ToDouble (fromInteger (readSignedHex (T.unpack bits)))))
  Array [String "s", String bytes] -> String <$> utf8 bytes
  Array [String "a", Array items] -> Array <$> mapM untag items
  Array [String "o", Array members] -> Object <$> mapM member members
  other -> error ("bad tagged value " ++ show other)
  where
    member = \case
      Array [String key, value] -> (,) <$> utf8 key <*> untag value
      other -> error ("bad tagged member " ++ show other)
    utf8 text = fromWtf8 (unhex (T.unpack text))

readSignedHex :: String -> Integer
readSignedHex = \case
  '-' : digits -> negate (readSignedHex digits)
  digits -> case readHex digits of
    [(value, "")] -> value
    _ -> error ("bad hex " ++ digits)

unhex :: String -> BS.ByteString
unhex = BS.pack . pairs
  where
    pairs (a : b : rest) | isHexDigit a && isHexDigit b = fromIntegral (digitToInt a * 16 + digitToInt b) : pairs rest
    pairs [] = []
    pairs other = error ("bad hex " ++ take 20 other)

-- | Run the oracle on one request; its answer lines.
oracle :: BL.ByteString -> IO [BS.ByteString]
oracle request = do
  (exe, checkout) <- upstreamPython
  root <- repositoryRoot
  let script = root </> "packages" </> "petrus-json" </> "test" </> "cpython_json_oracle.py"
  (code, out, err) <- readProcess (setWorkingDir checkout (setStdin (byteStringInput request) (proc exe ["-I", "-B", script])))
  case code of
    ExitSuccess | BL.null err -> pure (filter (not . BS.null) (BC.lines (BL.toStrict out)))
    _ -> fail ("the CPython oracle failed: " ++ BC.unpack (BL.toStrict err))

-- | An oracle answer: the result after @=@, or the refusal's class and text.
data Answer = Answered BS.ByteString | Refused Text Text

answer :: BS.ByteString -> Answer
answer line = case BC.uncons line of
  Just ('=', rest) -> Answered rest
  Just ('!', rest) -> case parseJson surrogateRefusingLoads rest of
    Right (Array [String cls, String message]) -> Refused cls message
    other -> error ("bad refusal line " ++ show other)
  _ -> error ("bad oracle line " ++ show line)

chunksOf :: Int -> [a] -> [[a]]
chunksOf n = \case
  [] -> []
  xs -> let (a, b) = splitAt n xs in a : chunksOf n b

-- * Corpora --------------------------------------------------------------------

generate :: Int -> Gen a -> a
generate seed gen = unGen gen (mkQCGen seed) 30

-- | Characters dense in what an encoder escapes or a sort orders: controls,
-- quotes, backslashes, DEL, Latin-1, the line separators, the BMP edges,
-- noncharacters and astral planes (no lone surrogates: a 'Text' cannot hold
-- them).
richChar :: Gen Char
richChar =
  frequency
    [ (12, elements (['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] ++ " _-.:/"))
    , (2, elements "\"\\")
    , (2, choose ('\0', '\x1f'))
    , (2, elements "\x7f\x80\x9f\xa0\xe9\xff\x100\x7ff\x800\x2028\x2029\xd7ff\xe000\xfeff\xfffd\xfffe\xffff")
    , (1, elements "\x10000\x1F600\x1F9D1\x10fffd\x10ffff")
    , (1, choose ('\x80', '\x10ffff') `suchThat` (\c -> c < '\xd800' || c > '\xdfff'))
    ]

-- | Text for the @dumps@ corpus: 'richChar', and now and then a lone
-- surrogate (a WTF-8 'Text', as 'KeepLoneSurrogates' parses one).
richText :: Gen Text
richText = fromCodePoints <$> resize 12 (listOf (frequency [(40, richChar), (1, choose ('\xd800', '\xdfff'))]))

richInteger :: Gen Integer
richInteger =
  frequency
    [ (6, toInteger <$> chooseInt (-1000, 1000))
    , (3, choose (-(2 ^ (64 :: Int)), 2 ^ (64 :: Int)))
    , (2, elements [2 ^ (53 :: Int) - 1, 2 ^ (53 :: Int), 2 ^ (53 :: Int) + 1, -(2 ^ (63 :: Int)), 2 ^ (63 :: Int) - 1, 2 ^ (63 :: Int), 10 ^ (18 :: Int), 10 ^ (19 :: Int) - 1])
    , (2, chooseInt (20, 400) >>= \k -> choose (-(10 ^ k), 10 ^ k))
    , -- the digit limit, on both sides of it
      (1, elements [10 ^ (4299 :: Int), 10 ^ (4300 :: Int) - 1, -(10 ^ (4300 :: Int) - 1), 10 ^ (4300 :: Int), -(10 ^ (4300 :: Int)), 10 ^ (4400 :: Int)])
    ]

richDouble :: Gen Double
richDouble =
  frequency
    [ (4, castWord64ToDouble . fromInteger <$> choose (0, 2 ^ (64 :: Int) - 1))
    , (3, (/ 1000) . fromInteger <$> choose (-(10 ^ (9 :: Int)), 10 ^ (9 :: Int)))
    , (2, elements [0, -0.0, 0.1, 0.5, 1, 1e15, 1e16, 1e17, 1e22, 1e23, 1e-5, 1e-4, 5e-324, 2.2250738585072014e-308, 1.7976931348623157e308, 9007199254740993])
    , (1, elements [0 / 0, 1 / 0, -1 / 0])
    ]

-- | Any value with distinct keys (a CPython dict holds no repeats).
dumpsValue :: Int -> Gen Json
dumpsValue depth =
  frequency $
    [ (1, pure Null)
    , (1, Bool <$> elements [False, True])
    , (3, Int <$> richInteger)
    , (3, Float <$> richDouble)
    , (3, String <$> richText)
    ]
      ++ if depth <= 0
        then []
        else
          [ (2, Array <$> (chooseInt (0, 5) >>= \n -> vectorOf n (dumpsValue (depth - 1))))
          , (2, Object . nubBy (\a b -> fst a == fst b) <$> (chooseInt (0, 6) >>= \n -> vectorOf n ((,) <$> richText <*> dumpsValue (depth - 1))))
          ]

-- | Values deeper than the recursion of a naive encoder, as upstream's
-- simulation tests nest them (1 200 levels).
deepValues :: [Json]
deepValues =
  [ iterate (Array . pure) (Int 1) !! 1200
  , iterate (\v -> Object [("k", v)]) (Array []) !! 1200
  , iterate (\v -> Array [Object [("a", v), ("b", Float (0 / 0))]]) Null !! 300
  ]

dumpsCorpus :: [Json]
dumpsCorpus = deepValues ++ generate 20261011 (vectorOf 2000 (sized (\n -> dumpsValue (min 4 (n `div` 6 + 1)))))

-- | String bodies built from fragments: plain and multi-byte characters,
-- every escape, @\\u@ escapes in both cases, surrogate pairs, lone and
-- misordered surrogates, invalid escapes, raw controls and invalid UTF-8.
escapedString :: Gen BS.ByteString
escapedString = do
  fragments <- resize 10 (listOf fragment)
  close <- frequency [(9, pure "\""), (1, pure "")]
  pure ("\"" <> mconcat fragments <> close)
  where
    fragment =
      frequency
        [ (6, BC.pack <$> resize 6 (listOf (elements (['a' .. 'z'] ++ " /'"))))
        , (2, TE.encodeUtf8 . T.pack <$> resize 3 (listOf richChar))
        , (3, elements ["\\\"", "\\\\", "\\/", "\\b", "\\f", "\\n", "\\r", "\\t"])
        , (3, unicodeEscape <$> chooseInt (0, 0xFFFF) <*> elements [False, True])
        , (2, (\h l -> unicodeEscape h False <> unicodeEscape l True) <$> chooseInt (0xD800, 0xDBFF) <*> chooseInt (0xDC00, 0xDFFF))
        , (1, unicodeEscape <$> chooseInt (0xD800, 0xDFFF) <*> elements [False, True])
        , (1, (\l h -> unicodeEscape l False <> unicodeEscape h False) <$> chooseInt (0xDC00, 0xDFFF) <*> chooseInt (0xD800, 0xDBFF))
        , (1, elements ["\\x41", "\\u12", "\\u12G4", "\\U0001F600", "\\", "\\'", "\\a", "\\0"])
        , (1, BS.singleton <$> elements ([0x00, 0x01, 0x09, 0x0A, 0x1F, 0x7F] :: [Word8]))
        , (1, BS.pack <$> elements [[0x80], [0xC3], [0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82], [0xFF]])
        ]
    unicodeEscape :: Int -> Bool -> BS.ByteString
    unicodeEscape n upper =
      let digits = showHex n ""
          padded = replicate (4 - length digits) '0' ++ digits
       in BC.pack ("\\u" ++ (if upper then map toUpperHex padded else padded))
    toUpperHex c = if c >= 'a' && c <= 'f' then chr (fromEnum c - 32) else c

-- | Objects over a small key alphabet, so repeats are common, nested.
keyedObject :: Int -> Gen BS.ByteString
keyedObject depth = do
  n <- chooseInt (0, 10)
  members <- vectorOf n $ do
    key <- elements ["a", "b", "c", "\\u0061", "\xc3\xa9", "\\u00e9", "", "aa"]
    value <-
      if depth <= 0
        then elements ["1", "1.0", "true", "null", "\"x\"", "NaN", "[]", "{}", "-0", "1e400"]
        else frequency [(3, elements ["1", "2.5", "null", "\"v\""]), (1, keyedObject (depth - 1))]
    pure ("\"" <> key <> "\":" <> value)
  pure ("{" <> BS.intercalate "," members <> "}")

-- | Whitespace between tokens: JSON's four, and characters that are not
-- JSON whitespace (form feed, vertical tab, NBSP, U+2028, a BOM).
spaced :: BS.ByteString -> Gen BS.ByteString
spaced document = do
  let pieces = BC.split ',' document
  separators <- vectorOf (length pieces) (resize 3 (listOf (elements [" ", "\t", "\n", "\r", " ", "\f", "\v", "\xc2\xa0", "\xe2\x80\xa8", "\xef\xbb\xbf"])))
  lead <- elements ["", " ", "\n\t", "\f"]
  pure (lead <> BS.intercalate "," (zipWith (\p s -> mconcat s <> p) pieces separators))

-- | Documents that sit on the edges CPython draws: constants, overflow,
-- signs, malformed numbers, the BOM, the digit limit, deep nesting.
edgeDocuments :: [BS.ByteString]
edgeDocuments =
  [ "", " ", "\xef\xbb\xbf{}", "\xef\xbb\xbf", "NaN", "-NaN", "nan", "Infinity", "-Infinity", "+Infinity", "infinity"
  , "[NaN,Infinity,-Infinity]", "{\"a\":NaN}", "1e400", "-1e400", "1e-400", "-1e-400", "1E+2", "1e+2", "0e0", "-0", "-0.0"
  , "0.0", "-0e-0", "1.7976931348623157e308", "1.7976931348623159e308", "4.9e-324", "2.4703282292062327e-324"
  , "2.4703282292062328e-324", "9007199254740993", "9007199254740993.0", "123456789012345678901234567890"
  , "0.1e1", "1.", ".5", "+1", "01", "-01", "00", "1e", "1e+", "1.5e-", "-", "--1", "1.2.3", "1e2e3", "0x10"
  , "[1,]", "[,1]", "{,}", "{\"a\":1,}", "{\"a\" 1}", "{\"a\":}", "{1:2}", "{'a':1}", "[1 2]", "tru", "nul", "fals", "truex"
  , "\"\\u0000\"", "\"\\ud800\"", "\"\\udc00\\ud800\"", "\"\\ud83d\\ude00\"", "\"\\uD83D\\uDE00\"", "\"\\ud83dx\"", "[\"\\ud800\", 1]"
  , "{\"\\ud800\": 1}", "\"a\tb\"", "\"\x7f\"", "\"\xed\xa0\x80\"", "\"\xc0\x80\"", "\"unterminated", "\"\\", "\"\\u"
  , "1 ", " 1", "1\n", "[] []", "{}x", "null null", "\"x\"\"y\"", "[\x0c]", "[\x0b]", "[\xc2\xa0]"
  ]
    ++ [BC.replicate n '7' | n <- [4299, 4300, 4301, 4302]]
    ++ ["-" <> BC.replicate n '7' | n <- [4300, 4301]]
    ++ ["[" <> BC.replicate 4301 '1' <> "]", "{\"a\":" <> BC.replicate 4301 '1' <> "}", BC.replicate 5000 '9' <> ".5", "1e" <> BC.replicate 5000 '9']
    ++ ["[NaN, " <> BC.replicate 4301 '1' <> "]", "{\"a\":1,\"a\":2," <> "\"b\":" <> BC.replicate 4301 '1' <> "}"]
    ++ [BC.replicate n '[' <> BC.replicate n ']' | n <- [1, 2, 1200]]
    ++ [mconcat (replicate 1200 "{\"a\":") <> "1" <> BC.replicate 1200 '}', BC.replicate 1200 '[' <> BC.replicate 1199 ']']

loadsCorpus :: [BS.ByteString]
loadsCorpus =
  edgeDocuments
    ++ generate 1 (vectorOf 3000 documentText)
    ++ generate 2 (vectorOf 4000 (documentText >>= mutated))
    ++ generate 3 (vectorOf 2000 (BC.pack <$> numberSpelling))
    ++ generate 4 (vectorOf 1000 ((\s -> "[" <> BC.pack s <> "]") <$> numberSpelling))
    ++ generate 5 (vectorOf 1500 (BS.pack <$> resize 40 (listOf (elements soup))))
    ++ generate 6 (vectorOf 2500 escapedString)
    ++ generate 7 (vectorOf 1500 (keyedObject 2))
    ++ generate 8 (vectorOf 800 (oneof [documentText, keyedObject 1] >>= spaced))

-- * The checks -----------------------------------------------------------------

surrogateRefusal :: String
surrogateRefusal = "JSON strings must contain Unicode scalar values"

spec :: Spec
spec = describe "differential against CPython's json (the pinned reference)" $ do
  it "json.dumps: every configuration upstream uses, byte for byte and refusal for refusal" $ do
    let configurations = "[" <> BL.intercalate "," (map (BL.fromStrict . BC.pack . fst) dumpsConfigurations) <> "]"
        transport value = either (error . show) BL.fromStrict (dumps defaultDumps (tag value))
        request = "dumps\n" <> configurations <> "\n" <> BL.intercalate "\n" (map transport dumpsCorpus) <> "\n"
    answers <- oracle request
    length answers `shouldBe` length dumpsCorpus * length dumpsConfigurations
    let mine options value = either (Left . T.pack . encodeErrorMessage) Right (dumps options value)
        theirs line = case answer line of
          Answered h -> Right (unhex (BC.unpack h))
          Refused _ message -> Left message
        results =
          [ (name, value, ours, reference)
          | (value, row) <- zip dumpsCorpus (chunksOf (length dumpsConfigurations) answers)
          , ((name, options), line) <- zip dumpsConfigurations row
          , let ours = mine options value
                reference = theirs line
          ]
        mismatches = [(name, value, ours, reference) | (name, value, ours, reference) <- results, ours /= reference]
        refusals = length [() | (_, _, Left _, _) <- results]
    take 3 mismatches `shouldBe` []
    -- The corpus reaches both refusals and plenty of bytes.
    refusals `shouldSatisfy` (> 1000)
    length results `shouldSatisfy` (>= 32000)

  it "json.loads: every admission profile upstream uses, value for value" $ do
    let request = "loads\n" <> BL.intercalate "\n" (map (\document -> "x" <> B.toLazyByteString (B.byteStringHex document)) loadsCorpus) <> "\n"
    answers <- oracle request
    length answers `shouldBe` length loadsCorpus * length loadsProfiles
    let check profile options document line =
          let ours = parseJson options document
           in case (answer line, ours) of
                (Answered tagged, _) -> case parseJson surrogateRefusingLoads tagged of
                  Left problem -> Just ("unreadable oracle value: " ++ problem)
                  Right t -> case untag t of
                    Nothing -> Just ("oracle value is not generalized UTF-8: " ++ show t)
                    Just expected
                      -- CPython admits a lone surrogate escape; the default refuses it.
                      | holdsLoneSurrogate expected, ours == Left surrogateRefusal -> Nothing
                      | otherwise -> case ours of
                          Right value | exactEq value expected -> Nothing
                          _ -> Just ("CPython admits " ++ show expected ++ ", petrus-json answers " ++ show ours)
                (Refused _ message, Left problem)
                  | profile == "plain"
                  , "Exceeds the limit" `T.isPrefixOf` message
                  , problem /= T.unpack message && problem /= surrogateRefusal ->
                      Just ("CPython refuses with " ++ show message ++ ", petrus-json with " ++ show problem)
                  | otherwise -> Nothing
                (Refused cls message, Right value) -> Just ("CPython refuses (" ++ T.unpack cls ++ ": " ++ T.unpack message ++ "), petrus-json admits " ++ show value)
        rows = zip loadsCorpus (chunksOf (length loadsProfiles) answers)
        verdicts =
          [ (name, document, check name options document line, line)
          | (document, row) <- rows
          , ((name, options), line) <- zip loadsProfiles row
          ]
        problems = [(name, document, problem) | (name, document, Just problem, _) <- verdicts]
    take 3 problems `shouldBe` []
    -- Keeping lone surrogates, the plain profile is CPython's json.loads:
    -- the same admissions, value for value, lone surrogates included.
    let plainLines = [line | (n, _, _, line) <- verdicts, n == "plain"]
        kept =
          [ (document, problem)
          | (document, line) <- zip loadsCorpus plainLines
          , Just problem <- [check ("plain" :: String) keepingSurrogates document line]
          ]
        surrogateAdmissions =
          length
            [ ()
            | (document, line) <- zip loadsCorpus plainLines
            , Right value <- [parseJson keepingSurrogates document]
            , holdsLoneSurrogate value
            , BC.isPrefixOf "=" line
            ]
    take 3 kept `shouldBe` []
    surrogateAdmissions `shouldSatisfy` (> 200)
    -- Every profile both admits and refuses a substantial share.
    forM_ loadsProfiles $ \(name, _) -> do
      let mine = [line | (n, _, _, line) <- verdicts, n == name]
          admitted = length [() | line <- mine, BC.isPrefixOf "=" line]
      when (admitted < 2000 || length mine - admitted < 2000) $
        expectationFailure (name ++ ": " ++ show admitted ++ " admitted of " ++ show (length mine))
    length loadsCorpus `shouldSatisfy` (> 16000)

  it "the oracle's transport is lossless (every corpus value survives tag/untag)" $
    forM_ dumpsCorpus $ \value ->
      unless (maybe False (exactEq value) (untag (tag value))) $ expectationFailure (show value)
