-- | "Hamsterdan.Host.Uvicorn" against the pinned uvicorn and CPython, live:
-- @ipaddress@'s parsers, @_TrustedHosts@ and @_parse_host_port@ (over
-- hand-picked and generated strings), @http.HTTPStatus@'s phrases, the two
-- formatters with and without colors, and the access line's path.
module UvicornSpec (spec) where

import Control.Monad (forM_, unless)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Host.Uvicorn
import Hamsterdan.Host.Uvicorn.IpAddress (IpAddress (..), IpNetwork (..), IpVersion (..), ipAddress, ipNetwork)
import Network.Wai (defaultRequest, rawPathInfo, rawQueryString)
import Petrus.Json (Json (..), compact, dumps, parseJson, surrogateRefusingLoads)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import System.Process.Typed (byteStringInput, proc, readProcess, setStdin)
import System.Exit (ExitCode (..))
import Test.Hspec

oracle :: Text
oracle =
  T.unlines
    [ "import http, ipaddress, json, logging, sys, urllib.parse"
    , "from uvicorn._ansi import style"
    , "from uvicorn.logging import AccessFormatter, DefaultFormatter"
    , "from uvicorn.middleware.proxy_headers import _TrustedHosts, _parse_host_port"
    , "from uvicorn.protocols.utils import get_path_with_query_string"
    , "q = json.load(sys.stdin)"
    , "def address(text):"
    , "    try: a = ipaddress.ip_address(text)"
    , "    except ValueError: return None"
    , "    return [a.version, int(a), getattr(a, 'scope_id', None)]"
    , "def network(text):"
    , "    try: n = ipaddress.ip_network(text)"
    , "    except ValueError: return None"
    , "    return [n.version, int(n.network_address), n.prefixlen]"
    , "def phrase(code):"
    , "    try: return http.HTTPStatus(code).phrase"
    , "    except ValueError: return None"
    , "def line(colors, level, msg, color_msg, args):"
    , "    f = DefaultFormatter(fmt='%(levelprefix)s %(message)s', use_colors=colors)"
    , "    r = logging.LogRecord('uvicorn.error', level, '', 0, msg, tuple(args) or None, None)"
    , "    if color_msg is not None: r.color_message = color_msg"
    , "    return f.format(r)"
    , "def access(colors, client, method, path, version, status):"
    , "    f = AccessFormatter(fmt='%(levelprefix)s %(client_addr)s - \"%(request_line)s\" %(status_code)s', use_colors=colors)"
    , "    r = logging.LogRecord('uvicorn.access', logging.INFO, '', 0, '%s - \"%s %s HTTP/%s\" %d', (client, method, path, version, status), None)"
    , "    return f.format(r)"
    , "def path(target):"
    , "    raw, _, query = target.encode('ascii').partition(b'?')"
    , "    return get_path_with_query_string({'path': urllib.parse.unquote(raw.decode('ascii')), 'query_string': query})"
    , "templates = {"
    , "  'started': ('Started server process [%d]', 'Started server process [' + style('%d', fg='cyan') + ']'),"
    , "  'finished': ('Finished server process [%d]', 'Finished server process [' + style('%d', fg='cyan') + ']'),"
    , "  'running': ('Uvicorn running on %s://%s:%d (Press CTRL+C to quit)', 'Uvicorn running on ' + style('%s://%s:%d', bold=True) + ' (Press CTRL+C to quit)'),"
    , "  'running6': ('Uvicorn running on %s://[%s]:%d (Press CTRL+C to quit)', 'Uvicorn running on ' + style('%s://[%s]:%d', bold=True) + ' (Press CTRL+C to quit)'),"
    , "}"
    , "levels = {'INFO': logging.INFO, 'WARNING': logging.WARNING, 'ERROR': logging.ERROR}"
    , "out = {"
    , "  'addresses': [address(t) for t in q['strings']],"
    , "  'networks': [network(t) for t in q['strings']],"
    , "  'parsed': [list(_parse_host_port(t)) for t in q['strings']],"
    , "  'trusted': [[h in _TrustedHosts(s) for h in q['strings']] for s in q['specs']],"
    , "  'clients': [[list(_TrustedHosts(s).get_trusted_client_address(x)) for x in q['forwarded']] for s in q['specs']],"
    , "  'phrases': [phrase(c) for c in range(1000)],"
    , "  'lines': [line(c, levels[l], m, None, []) for c in (False, True) for l in levels for m in q['messages']],"
    , "  'templates': [line(c, logging.INFO, templates[k][0], templates[k][1], a) for c in (False, True) for k, a in q['templates']],"
    , "  'access': [access(c, *a) for c in (False, True) for a in q['access']],"
    , "  'paths': [path(t) for t in q['targets']],"
    , "}"
    , "sys.stdout.write(json.dumps(out))"
    ]

-- | Hand-picked addresses, networks, host:port forms and literals.
curated :: [Text]
curated =
  [ "127.0.0.1", "0.0.0.0", "255.255.255.255", "256.1.1.1", "01.2.3.4", "0.0.0.00", "1.2.3", "1.2.3.4.5", "1..2.3"
  , "\1633.2.3.4", "1.2.3.4 ", " 1.2.3.4", "::1", "::", ":::", "1::", "::1:2:3:4:5:6:7", "::1:2:3:4:5:6:7:8"
  , "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7::", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7:8:9:10:11", "1::2::3", ":1::2"
  , "1::2:", ":1:2:3:4:5:6:7:8", "fe80::1%lo0", "fe80::1%", "fe80::1%a%b", "FE80::1%LO0", "::ffff:1.2.3.4"
  , "::1.2.3.4", "1:2:3:4:5:6:1.2.3.4", "1:2:3:4:5:6:7:1.2.3.4", "::1.2.3.04", "12345::", "g::", "0000:0:0:0:0:0:0:1"
  , "1111:2222:3333:4444:5555:6666:7777:8888:9999", "1111:2222:3333:4444:5555:6666:255.255.255.255"
  , "aaaa:bbbb:cccc:dddd:eeee:ffff:aaaa:bbbb:cc"
  , "[::1]:80", "[::1]", "[::1]x", "[::1:80", "[::1]:", "[::1]:+8_0", "[]:5", "1.2.3.4:80", "1.2.3.4:", "1.2.3.4:+8_0"
  , "1.2.3.4: 80 ", "1.2.3.4:\1635", "1.2.3.4:-7", "1.2.3.4:1__0", "1.2.3.4:0x10", "host:port", "a:b:c", "", " "
  , "10.0.0.0/8", "10.0.0.1/8", "10.0.0.0/255.0.0.0", "10.0.0.0/0.255.255.255", "10.0.0.0/255.0.255.0"
  , "10.0.0.0/255.255.255.255", "10.0.0.0/0.0.0.0", "0.0.0.0/0", "::/0", "2001:db8::/32", "2001:db8::1/32"
  , "fe80::%eth0/64", "1.2.3.4/33", "1.2.3.4/", "1.2.3.4/ 8", "1.2.3.4/08", "1.2.3.4/+8", "1.2.3.4/1/2", "::1/129"
  , "::1/128", "/8", "*", "unix:/tmp/x", "localhost", "x\160", "127.0.0.1\133"
  ]

-- | Strings over the characters the parsers care about, from a fixed seed.
generated :: [Text]
generated = take 600 (go (12345 :: Integer))
  where
    alphabet = "0123456789abcdefABCDEF:.:.%/[]  ,+_-\1633\160x" :: String
    next seed = (seed * 6364136223846793005 + 1442695040888963407) `mod` (2 ^ (64 :: Int))
    go seed =
      let lenSeed = next seed
          len = fromInteger (lenSeed `div` 7 `mod` 18)
          (chars, seed') = pick len (next lenSeed) []
       in T.pack chars : go seed'
    pick 0 seed acc = (acc, seed)
    pick n seed acc = pick (n - 1 :: Int) (next seed) (alphabet !! fromInteger (seed `div` 11 `mod` toInteger (length alphabet)) : acc)

specs :: [Text]
specs =
  [ "127.0.0.1"
  , "*"
  , " * "
  , ""
  , "10.0.0.0/8, 127.0.0.1,::1 , unix:/tmp/x"
  , "192.168.0.0/16,fe80::%eth0/64,fe80::1%lo0, 10.0.0.0/255.0.0.0"
  , "2001:db8::/32, 10.0.0.1/8, garbage, 1.2.3.4, 0.0.0.0/0.255.255.255"
  ]

forwardedValues :: [Text]
forwardedValues =
  [ "", "1.2.3.4", "1.2.3.4, 127.0.0.1", "203.0.113.9, 10.1.2.3", "[2001:db8::1]:4711", " , ", "unix:/tmp/x, 10.9.9.9"
  , "a,b,c", "127.0.0.1,::1", "x\160, 127.0.0.1\133", "10.1.1.1, 10.2.2.2", "garbage, 1.2.3.4:99", "fe80::1%lo0, 10.0.0.1"
  , "198.51.100.7:+8_0, 127.0.0.1", "[::1]:x, ::1"
  ]

messages :: [Text]
messages = ["Shutting down", "Application startup complete.", "100% done", "", "Traceback (most recent call last):\nRuntimeError: x"]

accessCases :: [(Text, Text, Text, Text, Int)]
accessCases =
  [ (client, method, path, version, status)
  | (client, method, path, version) <-
      [ ("127.0.0.1:5000", "GET", "/healthz", "1.1"), ("", "POST", "/github/webhooks", "1.0")
      , ("::1:5", "HEAD", "/caf%C3%A9?x=1", "1.1") ]
  , status <- [100, 199, 200, 202, 307, 400, 404, 405, 418, 500, 503, 99, 600]
  ]

targets :: [Text]
targets =
  [ "/", "/healthz", "/a%20b", "/caf%C3%A9", "/%FF", "/%zz", "/%4", "/%", "/a/b%2Fc", "/x?y=1", "/x?", "/~_.-", "/a+b"
  , "/%E2%82", "/%E2%82%AC", "/%ED%A0%80", "/%F0%9F%98%80", "/%25", "/a?b?c", "/a?%20 x", "//x", "/a;b=c,d", "/%c3%a9"
  , "/!$&'()*:@", "/%C3A"
  ]

spec :: Spec
spec = describe "uvicorn's log lines and proxy headers (live against the pinned uvicorn)" $
  it "parses, trusts, formats and quotes as uvicorn and CPython do" $ do
    executable <- upstreamPythonExecutable "hamsterdan"
    let strings = curated <> generated
        templateCases = [("started", [Int 4242]), ("finished", [Int 7]), ("running", [String "http", String "127.0.0.1", Int 8000]), ("running6", [String "http", String "::1", Int 0])]
        query =
          Object
            [ ("strings", Array (map String strings))
            , ("specs", Array (map String specs))
            , ("forwarded", Array (map String forwardedValues))
            , ("messages", Array (map String messages))
            , ("templates", Array [Array [String k, Array a] | (k, a) <- templateCases])
            , ("access", Array [Array [String c, String m, String p, String v, Int (toInteger s)] | (c, m, p, v, s) <- accessCases])
            , ("targets", Array (map String targets))
            ]
        payload = either (error . show) id (dumps compact query)
    (exit, out, err) <- readProcess (setStdin (byteStringInput (BL.fromStrict payload)) (proc executable ["-I", "-B", "-c", T.unpack oracle]))
    unless (exit == ExitSuccess) $ expectationFailure ("the oracle failed: " <> BC.unpack (BL.toStrict err))
    results <- case parseJson surrogateRefusingLoads (BL.toStrict out) of
      Right (Object members) -> pure members
      other -> expectationFailure ("unreadable oracle output: " <> show other) >> pure []
    let field name = case lookup name results of
          Just (Array items) -> items
          _ -> []
        compareAll :: (Show a) => String -> [a] -> [Json] -> [Json] -> Expectation
        compareAll label inputs expected actual = do
          length actual `shouldBe` length expected
          forM_ (zip3 inputs expected actual) $ \(input, e, a) ->
            unless (e == a) $ expectationFailure (label <> " " <> show input <> "\n  reference: " <> show e <> "\n  port:      " <> show a)
        versionNumber = \case
          V4 -> Int 4
          V6 -> Int 6
    compareAll "ip_address" strings (field "addresses") $
      [maybe Null (\a -> Array [versionNumber a.version, Int a.value, maybe Null String a.scopeId]) (ipAddress s) | s <- strings]
    compareAll "ip_network" strings (field "networks") $
      [maybe Null (\n -> Array [versionNumber n.version, Int n.address, Int (toInteger n.prefix)]) (ipNetwork s) | s <- strings]
    compareAll "_parse_host_port" strings (field "parsed") $
      [let (h, p) = parseHostPort s in Array [String h, Int p] | s <- strings]
    compareAll "host in _TrustedHosts" specs (field "trusted") $
      [Array [Bool (isTrusted (trustedHosts s) (Just h)) | h <- strings] | s <- specs]
    compareAll "get_trusted_client_address" specs (field "clients") $
      [Array [let (h, p) = trustedClientAddress (trustedHosts s) x in Array [String h, Int p] | x <- forwardedValues] | s <- specs]
    compareAll "HTTPStatus.phrase" [0 :: Int .. 999] (field "phrases") $
      [maybe Null String (statusPhrase c) | c <- [0 .. 999]]
    let levels = [Info, Warning, Error]
    compareAll "DefaultFormatter" [(c, l, m) | c <- [False, True], l <- levels, m <- messages] (field "lines") $
      [String (formatLine c l (plainMessage m)) | c <- [False, True], l <- levels, m <- messages]
    compareAll "server messages" [(c, k) | c <- [False, True], (k, _) <- templateCases] (field "templates") $
      [ String (formatLine c Info m)
      | c <- [False, True]
      , m <- [startedMessage 4242, finishedMessage 7, runningMessage "127.0.0.1" 8000, runningMessage "::1" 0]
      ]
    compareAll "AccessFormatter" [(c, a) | c <- [False, True], a <- accessCases] (field "access") $
      [String (accessLine c client method path version status) | c <- [False, True], (client, method, path, version, status) <- accessCases]
    compareAll "get_path_with_query_string" targets (field "paths") $
      [String (logPath (requestOf t)) | t <- targets]
  where
    requestOf target =
      let (path, query) = BC.break (== '?') (TE.encodeUtf8 target)
       in defaultRequest {rawPathInfo = path, rawQueryString = query}
