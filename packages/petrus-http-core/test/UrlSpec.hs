-- | "Petrus.Http.Core.Url" against CPython 3.14's @urllib.parse@ and
-- @ipaddress@, case by case on a generated corpus.
module UrlSpec (urlSpec) where

import Control.Monad (forM_)
import Data.Bits (shiftR, xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (unfoldr)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64, Word8)
import Petrus.Http.Core.Url
import Petrus.Json (Json (..), defaultDumps, dumps, parseJson, pythonLoads)
import Petrus.Json.Python (decodeUtf8Replace)
import Petrus.TestSupport.Python (PythonResult (..), runPython)
import Test.Hspec
import Text.Printf (printf)

urlSpec :: Spec
urlSpec = describe "Petrus.Http.Core.Url (differential against CPython 3.14)" $ do
  it "agrees with urlsplit, its accessors, parse_qsl, unquote and ipaddress on every corpus case" $ do
    let cases = corpus
        input = encode (Array (map String cases))
    result <- runPython reference [] input
    case parseJson pythonLoads (resultStdout result) of
      Left problem -> expectationFailure ("Python printed invalid JSON: " <> problem <> "\n" <> show (resultStderr result))
      Right (Array expected) -> do
        length expected `shouldBe` length cases
        forM_ (zip cases expected) $ \(text, theirs) ->
          (text, encode (observe text)) `shouldBe` (text, encode theirs)
      Right other -> expectationFailure ("unexpected Python output " <> show other)
  it "decodes arbitrary byte strings as bytes.decode('utf-8', 'replace')" $ do
    let blobs = byteCorpus
        hexes = map (T.concat . map (T.pack . printf "%02x") . BS.unpack) blobs
        quoted h = T.concat (map ("%" <>) (T.chunksOf 2 h))
    result <-
      runPython
        "import sys, json, urllib.parse\nprint(json.dumps([[bytes.fromhex(h).decode('utf-8', 'replace'), urllib.parse.unquote(''.join('%' + h[i:i + 2] for i in range(0, len(h), 2)))] for h in json.load(sys.stdin)]))"
        []
        (encode (Array (map String hexes)))
    case parseJson pythonLoads (resultStdout result) of
      Right (Array expected) -> do
        length expected `shouldBe` length blobs
        forM_ (zip3 hexes blobs expected) $ \(hex, blob, theirs) ->
          (hex, encode (Array [String (decodeUtf8Replace blob), String (unquote (quoted hex))])) `shouldBe` (hex, encode theirs)
      other -> expectationFailure ("unexpected Python output " <> show other <> show (resultStderr result))

encode :: Json -> ByteString
encode = either (error . show) id . dumps defaultDumps

-- The Haskell side of one case, shaped like the reference's output.
observe :: Text -> Json
observe text =
  Array
    [ case urlsplit text of
        Left message -> Object [("error", String message)]
        Right parts ->
          Array
            [ Array (map String [splitScheme parts, splitNetloc parts, splitPath parts, splitQuery parts, splitFragment parts])
            , maybe Null String (splitUsername parts)
            , maybe Null String (splitPassword parts)
            , maybe Null String (splitHostname parts)
            , either (\message -> Object [("error", String message)]) (maybe Null Int) (splitPort parts)
            ]
    , either (\message -> Object [("error", String message)]) pairs (parseQsl True True text)
    , either (\message -> Object [("error", String message)]) pairs (parseQsl False False text)
    , String (unquote text)
    , String (unquotePlus text)
    , either String (const Null) (ipAddress text)
    , Bool (ipv4Address text)
    , Bool (ipv6Address text)
    ]
  where
    pairs = Array . map (\(name, value) -> Array [String name, String value])

reference :: Text
reference =
  T.unlines
    [ "import ipaddress, json, sys, urllib.parse"
    , "def err(fn):"
    , "    try:"
    , "        return fn()"
    , "    except ValueError as e:"
    , "        return {'error': str(e)}"
    , "def split(s):"
    , "    try:"
    , "        r = urllib.parse.urlsplit(s)"
    , "    except ValueError as e:"
    , "        return {'error': str(e)}"
    , "    return [list(r), r.username, r.password, r.hostname, err(lambda: r.port)]"
    , "def ok(cls, s):"
    , "    try:"
    , "        cls(s)"
    , "        return True"
    , "    except ValueError:"
    , "        return False"
    , "def ip(s):"
    , "    try:"
    , "        ipaddress.ip_address(s)"
    , "        return None"
    , "    except ValueError as e:"
    , "        return str(e)"
    , "out = []"
    , "for s in json.loads(sys.stdin.buffer.read()):"
    , "    out.append(["
    , "        split(s),"
    , "        err(lambda: [list(p) for p in urllib.parse.parse_qsl(s, keep_blank_values=True, strict_parsing=True)]),"
    , "        err(lambda: [list(p) for p in urllib.parse.parse_qsl(s)]),"
    , "        urllib.parse.unquote(s),"
    , "        urllib.parse.unquote_plus(s),"
    , "        ip(s),"
    , "        ok(ipaddress.IPv4Address, s),"
    , "        ok(ipaddress.IPv6Address, s),"
    , "    ])"
    , "print(json.dumps(out))"
    ]

-- The corpus ----------------------------------------------------------------

-- splitmix64, so the corpus is the same on every run.
randoms :: Word64 -> [Word64]
randoms = unfoldr (\s -> let s' = s + 0x9E3779B97F4A7C15 in Just (mix s', s'))
  where
    mix z0 =
      let z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xBF58476D1CE4E5B9
          z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
       in z2 `xor` (z2 `shiftR` 31)

pick :: [a] -> Word64 -> a
pick xs r = xs !! fromIntegral (r `mod` fromIntegral (length xs))

-- Fragments the generator strings together: delimiters, IP pieces,
-- percent escapes (valid and ill-formed UTF-8), controls and characters
-- that NFKC-normalize into delimiters.
fragments :: [Text]
fragments =
  [ "/", "//", "?", "#", "@", ":", "::", "[", "]", "%", ".", "+", "=", "&", "&&", "==", "-", "_", "v", "V", "v1.x"
  , "0", "1", "00", "01", "255", "256", "999", "1234", "65535", "65536", "007", "ffff", "FFFF", "fffff", "g", "x", "a", "abc"
  , "127.0.0.1", "1.2.3", "1.2.3.4.5", "::1", "fe80::1", "1::", "::ffff:1.2.3.4", "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7:8:9", "%eth0"
  , "http", "HTTP", "h-t.t+p", "1http", "localhost", "LOCALHOST", "Example.COM", "user", "pass", "limit", "after"
  , " ", "\t", "\r", "\n", "\x00", "\x1f", "\x7f", "\x80", "\xa0", "\xe9", "\xff", "\x130", "\x212a", "\xff21"
  , "\xff1a", "\xff0f", "\x2100", "\xfe5f", "\xff20", "\x2047", "\x1d400", "\x10ffff", "\x00df"
  , "%2", "%20", "%2B", "%2b", "%25", "%3D", "%26", "%zz", "%C3", "%A9", "%C3%A9", "%FF", "%E0%A0", "%E0%80%80", "%ED%A0%80"
  , "%F0%9F%98", "%F0%9F%98%80", "%F4%90%80%80", "%C0%AF", "%80", "%e2%82%ac", "%E2%82"
  ]

corpus :: [Text]
corpus = handpicked ++ generated
  where
    generated = take 6000 (go (randoms 20261010))
    go (r : rs) =
      let n = fromIntegral (r `mod` 9) + 1
          (pieces, rest) = splitAt n rs
          prefixes = ["", "", "", "//", "http://", "/v1/history?", "//[", "http://user:pw@[", "", "?"]
       in (pick prefixes (r `shiftR` 20) <> T.concat (map (pick fragments) pieces)) : go rest
    go [] = []

handpicked :: [Text]
handpicked =
  [ "", "/", "//", "///", "/v1/snapshot", "//v1/snapshot", "/v1/history?after=0&limit=10", "after=0&limit=10"
  , "http://127.0.0.1:8000", "http://[::1]:8000", "http://[::1]x", "http://[::1", "http://::1]", "http://a[::1]"
  , "http://[127.0.0.1]", "http://[v1.x]", "http://[v.x]", "http://[vg.x]", "http://[v1.]", "http://[v1.\x00]"
  , "http://[fe80::1%eth0]:1/", "http://[FE80::A%Zone]", "http://h:", "http://h:00080", "http://h:+1", "http://h:-1"
  , "http://h:65536", "http://h:\x0661", "http://h:" <> T.replicate 4301 "1", "http://u:p@h:1", "http://u@p@h", "http://@h"
  , "http://h\xff1a\&1", "http://\xe9\x2100", "http://\xe9@x", "HTTP://H", "1http://h", "h-t.t+p://h", ":x", "a:"
  , "  \t http://h", "ht\ttp://h\n/p\r", "#a?b", "?a#b", "a=1&&b=2", "a", "&", "=", "a=", "=b", "a=b=c", "a+b=c+d"
  , "%", "%%", "%2", "%41%42", "%C3%A9", "%C3", "%ff%fe", "caf\xe9%20%C3%A9", "\xe9%41\xe9%42"
  , "0.0.0.0", "255.255.255.255", "256.0.0.0", "01.2.3.4", "1.2.3.04", "1.2.3", "1.2.3.4/8", "\x0661.2.3.4"
  , "::", ":::", "::1", "1::", "1:::2", "1::2::3", ":1::2", "1::2:", "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7::", "::2:3:4:5:6:7:8"
  , "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7::8", "::ffff:1.2.3.4", "::1.2.3.4", "1:2:3:4:5:6:1.2.3.4", "1:2:3:4:5:6:7:1.2.3.4"
  , "fe80::1%", "fe80::1%a%b", "fe80::1%eth0", "12345::", "0:0:0:0:0:0:0:0", T.replicate 46 "0" <> "::", "1:2:3:4:5:6:7:8/64"
  ]

-- Byte strings for the UTF-8 decoder: every short sequence class,
-- truncations, overlongs, surrogates, out-of-range lead bytes, and random
-- mixes.
byteCorpus :: [ByteString]
byteCorpus = map BS.pack (fixed ++ take 4000 (go (randoms 42)))
  where
    fixed :: [[Word8]]
    fixed =
      [[b] | b <- [0 .. 255]]
        ++ [[a, b] | a <- [0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xED, 0xEF, 0xF0, 0xF4, 0xF5, 0xFF], b <- [0x00, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0]]
        ++ [[0xE0, 0xA0, 0x80], [0xE0, 0x9F, 0x80], [0xED, 0x9F, 0xBF], [0xED, 0xA0, 0x80], [0xF0, 0x90, 0x80, 0x80], [0xF0, 0x8F, 0x80, 0x80]]
        ++ [[0xF4, 0x8F, 0xBF, 0xBF], [0xF4, 0x90, 0x80, 0x80], [0xF0, 0x9F, 0x98], [0xF0, 0x9F, 0x98, 0x41], [0xE2, 0x82, 0x41]]
    go (r : rs) =
      let n = fromIntegral (r `mod` 12)
          (bytes, rest) = splitAt n rs
          bias b = pick [0x41, 0x80, 0xBF, 0xC3, 0xE0, 0xED, 0xF0, 0xF4, 0x9F, 0xA0, fromIntegral b] b
       in map bias bytes : go rest
    go [] = []
