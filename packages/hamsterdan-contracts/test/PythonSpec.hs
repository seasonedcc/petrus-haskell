{-# LANGUAGE OverloadedRecordDot #-}

-- | The shared CPython layer ("Hamsterdan.Python") against the pinned
-- interpreter: each property generates inputs, runs the reference
-- expression over all of them in one Python process, and requires the
-- port's answer for every input to be the one CPython 3.14 gave (the value,
-- or the exception's class and @str()@).
module PythonSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (nubBy)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Python.Exception (PythonException (..), pythonExceptionStr)
import Hamsterdan.Python.Json qualified as Json
import Hamsterdan.Python.Object (PyObject (..), loadsValue, toJson)
import Hamsterdan.Python.Text qualified as Py
import Hamsterdan.Python.Url (SplitResult)
import Hamsterdan.Python.Url qualified as Url
import Hamsterdan.Python.Value qualified as Value
import Numeric (showHex)
import Petrus.Json (Json (..), defaultDumps, dumps, encodeErrorMessage, parseJson, surrogateRefusingLoads)
import Petrus.TestSupport.Python (PythonResult (..), runPython)
import System.Exit (ExitCode (..))
import Test.Hspec
import Test.QuickCheck (Gen, arbitrary, choose, elements, frequency, generate, listOf, oneof, suchThat, vectorOf)

spec :: Spec
spec = describe "Hamsterdan.Python against the pinned interpreter" $ do
  it "urllib.parse: urlsplit, hostname, port, username, password, urlunsplit" $ do
    urls <- generate (vectorOf 3000 urlGen)
    agree urlScript urlCase (map String (fixedUrls <> urls))

  it "int(str) and int(str, 16)" $ do
    values <- generate (vectorOf 3000 intGen)
    agree intScript intCase (map String (fixedInts <> values))

  it "uuid.UUID(str)" $ do
    values <- generate (vectorOf 2000 uuidGen)
    agree uuidScript uuidCase (map String values)

  it "str.splitlines, on the text and on its UTF-8 bytes" $ do
    values <- generate (vectorOf 2000 (tokens linePieces 10))
    agree linesScript linesCase (map String values)

  it "built-ins over json.loads values: type, bool, str, repr, int, [i], .get" $ do
    values <- generate (vectorOf 2000 (jsonGen 4))
    agree valueScript valueCase values

  it "json.loads(bytes) in every encoding detect_encoding recognizes" $
    agree loadsScript loadsCase [Array (map (Int . toInteger) (BS.unpack b)) | b <- encodedDocuments]

  it "the dynamic value model loads UTF-16 and UTF-32 JSON bytes" $
    -- The exporter's copy refused them (UnsupportedJsonEncoding).
    mapM_
      (\b -> fmap (either (const Null) id . toJson False) (loadsValue (PyBytes b)) `shouldBe` Right (Array [Int 1, String "\233"]))
      [encoder "[1, \"\233\"]" | encoder <- [TE.encodeUtf16LE, TE.encodeUtf16BE, TE.encodeUtf32LE, TE.encodeUtf32BE]]

-- * Running the reference

-- | Run @script@ with the JSON array of @inputs@ on stdin; it prints the
-- JSON array of its answers.
live :: Text -> [Json] -> IO [Json]
live script inputs = do
  input <- either (fail . encodeErrorMessage) pure (dumps defaultDumps (Array inputs))
  result <- runPython (prelude <> script) [] input
  case (result.resultExit, parseJson surrogateRefusingLoads result.resultStdout) of
    (ExitSuccess, Right (Array answers)) -> pure answers
    _ -> fail ("the reference failed: " <> show result)

prelude :: Text
prelude =
  T.unlines
    [ "import json, sys"
    , "def attempt(f):"
    , "    try:"
    , "        return {'value': f()}"
    , "    except Exception as e:"
    , "        return {'error': [type(e).__name__, str(e)]}"
    , "inputs = json.load(sys.stdin)"
    ]

agree :: Text -> (Json -> Json) -> [Json] -> Expectation
agree script port inputs = do
  answers <- live script inputs
  length answers `shouldBe` length inputs
  let mismatches = [(input, expected, actual) | (input, expected) <- zip inputs answers, let actual = port input, show actual /= show expected]
  take 5 mismatches `shouldBe` []

attempt :: Either PythonException Json -> Json
attempt = either failure (\value -> Object [("value", value)])
  where
    failure e@(PythonException cls _) = Object [("error", Array [String cls, String (pythonExceptionStr e)])]

text :: Json -> Text
text = \case
  String s -> s
  other -> error ("not a string: " <> show other)

orNull :: Maybe Text -> Json
orNull = maybe Null String

tokens :: [Text] -> Int -> Gen Text
tokens pool most = do
  count <- choose (0, most)
  T.concat <$> vectorOf count (elements pool)

-- * urllib.parse

urlScript :: Text
urlScript =
  T.unlines
    [ "from urllib.parse import urlsplit, urlunsplit"
    , "def case(u):"
    , "    try:"
    , "        r = urlsplit(u)"
    , "    except ValueError as e:"
    , "        return {'error': str(e)}"
    , "    try:"
    , "        p = r.port"
    , "    except ValueError as e:"
    , "        p = {'error': str(e)}"
    , "    return {'split': list(r), 'hostname': r.hostname, 'port': p, 'username': r.username, 'password': r.password, 'unsplit': urlunsplit(r)}"
    , "print(json.dumps([case(u) for u in inputs]))"
    ]

urlCase :: Json -> Json
urlCase input = case Url.urlsplit (text input) of
  Left e -> Object [("error", String e)]
  Right r ->
    Object
      [ ("split", Array (map String (fields r)))
      , ("hostname", orNull (Url.hostname r))
      , ("port", either (\e -> Object [("error", String e)]) (maybe Null Int) (Url.port r))
      , ("username", orNull (Url.username r))
      , ("password", orNull (Url.password r))
      , ("unsplit", String (Url.urlunsplit r))
      ]
  where
    fields :: SplitResult -> [Text]
    fields r = [r.scheme, r.netloc, r.path, r.query, r.fragment]

fixedUrls :: [Text]
fixedUrls =
  [ "https://api.github.com/repos/o/r?page=2#x"
  , "https://user:pw@[fe80::1%eth0]:8443/p"
  , "https://[fe80::1%25en0]/"
  , "https://[v1.fe]/"
  , "https://[::1/"
  , "https://a\65295b/"
  , "https://a\65312b@host/"
  , "https://\8448.com/"
  , "https://\8453/"
  , "https://\189.com/"
  , "  \tHTTPS://EXAMPLE.com:080/a\nb"
  , "https://\913\931.\913\931\913/"
  , "https://\7305\304.com/"
  , "https://h:\1635/"
  , "https://h:65536/"
  , "https://h:99999999999999999999999/"
  , "https://[::1]x/"
  , "https://x[::1]/"
  ]

urlGen :: Gen Text
urlGen = frequency [(3, structured), (1, tokens urlPieces 14)]
  where
    structured = do
      lead <- elements ["", "", " ", "\1", "\t "]
      scheme <- elements ["", "http:", "https:", "HTTPS:", "git+ssh:", "a1:", "1a:", "h_t:", "mailto:", "\233:"]
      slashes <- elements ["//", "//", "//", "/", ""]
      user <- elements ["", "", "user@", "user:pass@", ":pw@", "a@b@", "us%40er:p:w@", "@", "\233:\8448@"]
      host <- elements hosts
      portText <- elements ["", "", ":", ":80", ":0", ":65535", ":65536", ":-1", ":8a", ": 80", ":\1635", ":00080", ":+1"]
      rest <- elements ["", "/", "/path", "/a b", "?q=1", "#frag", "/p?q#f", "?#", "/\t/", "/\n", "#a#b", "?a?b"]
      noise <- tokens urlPieces 3
      at <- choose (0, 6 :: Int)
      let parts = [lead, scheme, slashes, user, host, portText, rest]
      pure (T.concat (take at parts <> [noise] <> drop at parts))
    hosts =
      [ "example.com", "EXAMPLE.com", "api.github.com", "[::1]", "[::1", "::1]", "[fe80::1%25eth0]", "[fe80::1%eth0]"
      , "[FE80::A%Eth0]", "[v1.fe]", "[v1.]", "[V7.a:b]", "[1.2.3.4]", "[::ffff:1.2.3.4]", "[zz]", "x[::1]", "[::1]x", "1.2.3.4"
      , "\201XAMPLE.com", "\931\943\963\965\966\959\962", "\8448", "\65349\65368", "a\65295b", "a\65311b", "a\65283b"
      , "a\65312b", "a\65306b", "\188", "\8453", "\453", "", "a%00b", "localhost", "[::1]:", "[]"
      ]
    urlPieces =
      [ ":", "/", "//", "?", "#", "@", "[", "]", "%", "a", "B", "1", " ", "\t", "\n", "\r", "\233", "\65295"
      , "\65312", "\65306", "\8448", ".", "-", "+", "[::1]", "http:", "//h", "\1635"
      ]

-- * int()

intScript :: Text
intScript =
  T.unlines
    [ "def hex16(s):"
    , "    try:"
    , "        return format(int(s, 16), 'x')"
    , "    except ValueError:"
    , "        return None"
    , "print(json.dumps([{'int': attempt(lambda: int(s)), 'int16': hex16(s)} for s in inputs]))"
    ]

intCase :: Json -> Json
intCase input =
  Object
    [ ("int", attempt (Int <$> Py.intText s))
    , ("int16", maybe Null (String . hex) (Py.pyIntBase 16 s))
    ]
  where
    s = text input
    hex n
      | n < 0 = "-" <> T.pack (showHex (negate n) "")
      | otherwise = T.pack (showHex n "")

fixedInts :: [Text]
fixedInts =
  [ T.replicate 4300 "1"
  , T.replicate 4301 "1"
  , " -" <> T.replicate 4301 "7" <> " "
  , T.replicate 4300 "1_"
  , T.replicate 300 "\233"
  ]

intGen :: Gen Text
intGen = frequency [(3, tokens pieces 8), (1, T.pack <$> listOf (elements "0123456789_"))]
  where
    pieces =
      [ "0", "1", "7", "9", "12", "_", "__", "+", "-", " ", "\t", "\n", "\v", "\f", "\28", "\31", "\133", "\160"
      , "\8232", "\12288", "\8203", "\1635", "\65299", "\2411", "\120791", "a", "f", "F", "g", "x", "0x", "0X"
      , "\233", "\0", "1_000", "\8309"
      ]

-- * uuid.UUID

uuidScript :: Text
uuidScript =
  T.unlines
    [ "import uuid"
    , "def canonical(s):"
    , "    try:"
    , "        return str(uuid.UUID(s))"
    , "    except ValueError:"
    , "        return None"
    , "print(json.dumps([canonical(s) for s in inputs]))"
    ]

uuidCase :: Json -> Json
uuidCase = orNull . Py.canonicalUuid . text

uuidGen :: Gen Text
uuidGen = do
  hex <- T.pack <$> vectorOf 32 (elements "0123456789abcdefABCDEF")
  let part from size = T.take size (T.drop from hex)
      dashed = T.intercalate "-" [part 0 8, part 8 4, part 12 4, part 16 4, part 20 12]
  shaped <- elements [hex, dashed, "{" <> dashed <> "}", "urn:uuid:" <> dashed, "uuid:" <> hex, "{{" <> hex, dashed <> "-"]
  mutation <- choose (0, 3 :: Int)
  position <- choose (0, T.length shaped)
  piece <- elements ["_", " ", "+", "-", "g", "\1635", "{", "}", "urn:", "0x", "\65297"]
  pure $ case mutation of
    0 -> shaped
    1 -> T.take position shaped <> piece <> T.drop (position + T.length piece) shaped
    2 -> T.take position shaped <> T.drop (position + 1) shaped
    _ -> T.take position shaped <> piece <> T.drop position shaped

-- * str.splitlines

linesScript :: Text
linesScript = "print(json.dumps([s.splitlines() for s in inputs]))\n"

linesCase :: Json -> Json
linesCase input
  | onBytes == onText = Array (map String onText)
  | otherwise = String "the byte and text splits differ"
  where
    s = text input
    onText = Py.splitlines s
    onBytes = map TE.decodeUtf8 (Py.splitlinesUtf8 (TE.encodeUtf8 s))

linePieces :: [Text]
linePieces = ["a", "\233", "\8364", "\128512", " ", "\t", "\n", "\r", "\r\n", "\n\r", "\v", "\f", "\28", "\29", "\30", "\31", "\133", "\8232", "\8233", "\8231", "\194", "x\r"]

-- * Built-ins over JSON values

valueScript :: Text
valueScript =
  T.unlines
    [ "def case(v):"
    , "    return {'type': type(v).__name__, 'truthy': bool(v), 'str': str(v), 'repr': repr(v),"
    , "            'int': attempt(lambda: int(v)), 'sub0': attempt(lambda: v[0]), 'sub3': attempt(lambda: v[3]),"
    , "            'get': attempt(lambda: v.get('k'))}"
    , "print(json.dumps([case(v) for v in inputs]))"
    ]

valueCase :: Json -> Json
valueCase v =
  Object
    [ ("type", String (Value.typeName v))
    , ("truthy", Bool (Value.truthy v))
    , ("str", String (Value.str v))
    , ("repr", String (Value.repr v))
    , ("int", attempt (Int <$> Value.intOf v))
    , ("sub0", attempt (Value.subscript 0 v))
    , ("sub3", attempt (Value.subscript 3 v))
    , ("get", attempt (Value.get "k" v))
    ]

jsonGen :: Int -> Gen Json
jsonGen depth
  | depth <= 0 = scalar
  | otherwise =
      frequency
        [ (4, scalar)
        , (1, Array <$> smallList (jsonGen (depth - 1)))
        , (1, Object . nubBy (\a b -> fst a == fst b) <$> smallList ((,) <$> elements keys <*> jsonGen (depth - 1)))
        ]
  where
    smallList g = choose (0, 4) >>= (`vectorOf` g)
    keys = ["k", "a", "b", "\233", "", "0", "'", "\""]
    scalar =
      frequency
        [ (1, pure Null)
        , (1, Bool <$> arbitrary)
        , (2, Int <$> arbitrary)
        , (1, Int <$> elements [2 ^ (70 :: Int), negate (2 ^ (64 :: Int)), 0])
        , (3, Float <$> floatGen)
        , (4, String <$> tokens textPieces 6)
        ]
    floatGen =
      oneof
        [ arbitrary `suchThat` finite
        , elements [0, -0.0, 0.1, 1e16, 1e15, 1e-5, 1e-4, 123456789012345678, 1e22, 5e-324, 1.7976931348623157e308, 2.5, -1.5e300, 1 / 3]
        , (encodeFloat <$> choose (-(2 ^ (53 :: Int)), 2 ^ (53 :: Int)) <*> choose (-1074, 970)) `suchThat` finite
        ]
    finite d = not (isNaN d || isInfinite d)
    textPieces =
      [ "a", "Z", "0", "12", " ", "'", "\"", "\\", "\n", "\t", "\0", "\127", "\133", "\160", "\233", "\8364", "\128512"
      , "\7305", "\68928", "\888", "\173", "\8203", "\65279", "\31", "\1635", "\65297", " 42 ", "-7", "1_0", "k"
      ]

-- * json.loads(bytes)

loadsScript :: Text
loadsScript = "print(json.dumps([attempt(lambda: json.loads(bytes(b))) for b in inputs]))\n"

loadsCase :: Json -> Json
loadsCase = \case
  Array octets -> attempt (Json.loadsBytes (BS.pack [fromInteger o | Int o <- octets]))
  other -> error ("not bytes: " <> show other)

encodedDocuments :: [ByteString]
encodedDocuments =
  [ bom <> encoder document
  | document <- ["{\"a\": [1, 2.5, \"\233\128512\"]}", "[]", "\"x\"", "{", "1 2", "  [null, true] ", "", "7"]
  , (bom, encoder) <-
      [ ("", TE.encodeUtf8)
      , ("\xef\xbb\xbf", TE.encodeUtf8)
      , ("", TE.encodeUtf16LE)
      , ("", TE.encodeUtf16BE)
      , ("\xff\xfe", TE.encodeUtf16LE)
      , ("\xfe\xff", TE.encodeUtf16BE)
      , ("", TE.encodeUtf32LE)
      , ("", TE.encodeUtf32BE)
      , ("\xff\xfe\x00\x00", TE.encodeUtf32LE)
      , ("\x00\x00\xfe\xff", TE.encodeUtf32BE)
      ]
  ]
    <> ["[1]\x80", "\xff\xfe[\x00", "\x00[\x00]\x00", "[\x00\x00\x00]\x00\x00"]
