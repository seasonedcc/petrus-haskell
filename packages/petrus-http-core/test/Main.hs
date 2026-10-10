module Main (main) where

import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar, readMVar, takeMVar, threadDelay, tryReadMVar)
import Control.Exception (IOException, SomeException, bracket, catch, displayException, throwIO, try)
import Control.Monad (forM, void)
import Data.Bits (shiftR, xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTime)
import Network.Socket
  ( Family (..)
  , ShutdownCmd (..)
  , SockAddr (..)
  , Socket
  , SocketType (..)
  , close
  , connect
  , defaultProtocol
  , getSocketName
  , socket
  , tupleToHostAddress
  )
import Network.Socket qualified as Socket
import Network.Socket.ByteString (recv, sendAll)
import Petrus.Http.Core
import Petrus.Json (Json (..), defaultDumps, dumps, parseJson, pythonLoads)
import Petrus.TestSupport.Python (readLine, runPython, withPython, PythonResult (..))
import Petrus.TestSupport.Repo (repoRoot)
import System.Timeout (timeout)
import Test.Hspec

main :: IO ()
main = do
  root <- repoRoot
  script <- T.pack <$> readFile (root <> "/packages/petrus-http-core/test/reference_server.py")
  reports <- newIORef []
  withReference script "none" $ \python ->
    withReference script "0.2" $ \pythonTimed ->
      withEcho reports Nothing $ \haskell ->
        withEcho reports (Just 0.2) $ \haskellTimed ->
          hspec $ do
            pureSpec
            wireSpec python haskell
            timeoutSpec pythonTimed haskellTimed
            exceptionSpec reports python haskell
            lifecycleSpec

-- Reference servers ------------------------------------------------------

withReference :: Text -> String -> (Int -> IO a) -> IO a
withReference script seconds action =
  withPython script [seconds] $ \process -> do
    port <- readLine process
    action (read (BC.unpack port))

echoMethods :: [ByteString]
echoMethods = ["GET", "POST", "PUT", "TEAPOT", "NOCONTENT", "UNKNOWN", "DEFAULT", "REASON", "NOPHRASE", "BOOM"]

withEcho :: IORef [(SockAddr, String)] -> Maybe Double -> (Int -> IO a) -> IO a
withEcho reports seconds action =
  withRunningServer config echo (\server -> serverPort server >>= action)
  where
    config =
      defaultServerConfig
        { serverHost = "127.0.0.1"
        , connectionTimeout = seconds
        , supportsMethod = (`elem` echoMethods)
        , reportException = \peer e -> atomicModifyIORef' reports (\old -> ((peer, displayException e) : old, ()))
        }

-- The reference handler, as Haskell.
echo :: Handler
echo request = case requestMethod request of
  "TEAPOT" -> sendError request 418 (Just "<tea & cake>") (Just "short & stout")
  "NOCONTENT" -> sendError request 204 Nothing Nothing
  "UNKNOWN" -> sendError request 599 Nothing Nothing
  "DEFAULT" -> sendError request 404 Nothing Nothing
  "REASON" -> sendResponse request (Response 299 (Just "Custom Reason") [("X-A", "1")] "done")
  "NOPHRASE" -> sendResponse request (response 299 [] "")
  "BOOM" -> throwIO (userError "boom")
  _ -> do
    body <- case requestHeader "Content-Length" request of
      Just digits
        | not (BS.null digits)
        , BC.all (\c -> c >= '0' && c <= '9') digits ->
            readBody request (read (BC.unpack digits)) `catch` \ConnectionTimeout -> pure "<timeout>"
      _ -> pure ""
    let latin1 = String . TE.decodeLatin1
        payload =
          either (error . show) id . dumps defaultDumps $
            Array
              [ latin1 (requestMethod request)
              , latin1 (requestPath request)
              , latin1 (requestRawTarget request)
              , latin1 (requestVersion request)
              , latin1 (requestLine request)
              , Array [Array [latin1 k, latin1 v] | (k, v) <- requestHeaders request]
              , latin1 body
              ]
    sendResponse request $
      response 200 [("Content-Type", "application/json"), ("Content-Length", BC.pack (show (BS.length payload)))] payload

-- Clients ------------------------------------------------------------------

localhost :: Int -> SockAddr
localhost port = SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1))

withClient :: Int -> (Socket -> IO a) -> IO a
withClient port action =
  bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
    connect sock (localhost port)
    action sock

receiveAll :: Socket -> IO ByteString
receiveAll sock = go []
  where
    go chunks = do
      chunk <- timeout 10000000 (recv sock 65536 `catch` \(e :: IOException) -> pure (BC.pack ("<" <> show e <> ">")))
      case chunk of
        Nothing -> pure (BS.concat (reverse ("<client timeout>" : chunks)))
        Just bytes
          | BS.null bytes -> pure (BS.concat (reverse chunks))
          | otherwise -> go (bytes : chunks)

-- Send the request, half-close, read the whole response.
exchange :: Int -> ByteString -> IO ByteString
exchange port request = withClient port $ \sock -> do
  sendAll sock request
  Socket.shutdown sock ShutdownSend
  receiveAll sock

-- Send without half-closing (the server must stop on its own).
exchangeOpen :: Int -> ByteString -> IO (ByteString, Double)
exchangeOpen port request = withClient port $ \sock -> do
  start <- getMonotonicTime
  sendAll sock request
  bytes <- receiveAll sock
  end <- getMonotonicTime
  pure (bytes, end - start)

-- Replace the Server and Date values, which legitimately differ.
normalize :: ByteString -> ByteString
normalize bytes
  | "HTTP/1.0 " `BS.isPrefixOf` bytes =
      let (headBlock, rest) = BS.breakSubstring "\r\n\r\n" bytes
       in BS.intercalate "\r\n" (map field (splitOn "\r\n" headBlock)) <> rest
  | otherwise = bytes
  where
    field line
      | "Server: " `BS.isPrefixOf` line = "Server: *"
      | "Date: " `BS.isPrefixOf` line = "Date: *"
      | otherwise = line

splitOn :: ByteString -> ByteString -> [ByteString]
splitOn separator bytes =
  let (first, rest) = BS.breakSubstring separator bytes
   in if BS.null rest then [first] else first : splitOn separator (BS.drop (BS.length separator) rest)

headerValue :: ByteString -> ByteString -> Maybe ByteString
headerValue name bytes =
  let headBlock = fst (BS.breakSubstring "\r\n\r\n" bytes)
   in case [BS.drop (BS.length name + 2) line | line <- splitOn "\r\n" headBlock, (name <> ": ") `BS.isPrefixOf` line] of
        value : _ -> Just value
        [] -> Nothing

sameAsPython :: Int -> Int -> ByteString -> IO ByteString
sameAsPython python haskell request = do
  expected <- exchange python request
  actual <- exchange haskell request
  normalize actual `shouldBe` normalize expected
  if "HTTP/1.0 " `BS.isPrefixOf` actual
    then do
      headerValue "Server" actual `shouldBe` Just defaultServerSoftware
      fmap BS.length (headerValue "Date" actual) `shouldBe` Just 29
    else pure ()
  pure actual

statusOf :: ByteString -> ByteString
statusOf = BS.take 12

-- Wire differential ----------------------------------------------------------

wireCases :: [(String, ByteString)]
wireCases =
  [ ("a plain GET", "GET /x?y=1#f HTTP/1.0\r\nHost: example\r\nAccept: */*\r\n\r\n")
  , ("an HTTP/1.1 GET (still one request, HTTP/1.0 answer)", "GET / HTTP/1.1\r\nHost: a\r\nConnection: keep-alive\r\n\r\n")
  , ("LF-only line endings", "GET /lf HTTP/1.0\nA: 1\nB: 2\n\n")
  , ("tabs and odd whitespace between words", "GET\t/t\x0b\&HTTP/1.0\r\n\r\n")
  , ("U+001C as a separator", "GET\x1c/u HTTP/1.0\r\n\r\n")
  , ("NEL (0x85) inside the target splits it", "GET /a\x85\&b HTTP/1.0\r\n\r\n")
  , ("NBSP (0xa0) as a separator", "GET\xa0/nbsp HTTP/1.0\r\n\r\n")
  , ("a latin-1 target", "GET /\xe9t\xe9 HTTP/1.0\r\n\r\n")
  , ("a request line with extra CRs", "GET /cr HTTP/1.0\r\r\r\n\r\n")
  , ("a request line ended by EOF", "GET /eof HTTP/1.0")
  , ("leading slashes collapse", "GET //a//b HTTP/1.0\r\n\r\n")
  , ("only slashes", "GET /// HTTP/1.0\r\n\r\n")
  , ("absolute-form target", "GET http://host/v1/snapshot HTTP/1.0\r\n\r\n")
  , ("asterisk target", "PUT * HTTP/1.0\r\n\r\n")
  , ("HTTP/0.9 GET", "GET /simple\r\n")
  , ("HTTP/0.9 GET with collapsed slashes", "GET //simple\r\nIgnored: header\r\n\r\n")
  , ("HTTP/0.9 POST", "POST /simple\r\n")
  , ("three words naming HTTP/0.9", "GET /nine HTTP/0.9\r\nX: 1\r\n\r\n")
  , ("one word", "GET\r\n\r\n")
  , ("one odd word", "\xff\x85\r\n")
  , ("four words", "GET / extra HTTP/1.0\r\n\r\n")
  , ("four words with a bad version", "GET / extra HTTP/x\r\n\r\n")
  , ("five words", "GET a b c HTTP/1.1\r\n\r\n")
  , ("version HTTP/1.x", "GET / HTTP/1.x\r\n\r\n")
  , ("version HTTP/1", "GET / HTTP/1\r\n\r\n")
  , ("version HTTP/1.1.1", "GET / HTTP/1.1.1\r\n\r\n")
  , ("version HTTPS/1.0", "GET / HTTPS/1.0\r\n\r\n")
  , ("lowercase version", "GET / http/1.0\r\n\r\n")
  , ("version with an 11-digit component", "GET / HTTP/12345678901.0\r\n\r\n")
  , ("version with a 10-digit component", "GET / HTTP/1.0123456789\r\n\r\n")
  , ("version with leading zeros", "GET / HTTP/001.000\r\n\r\n")
  , ("version with a superscript digit", "GET / HTTP/\xb2.0\r\n\r\n")
  , ("version with a slash", "GET / HTTP/1.0/2\r\n\r\n")
  , ("version with an empty component", "GET / HTTP/.1\r\n\r\n")
  , ("HTTP/2.0", "GET / HTTP/2.0\r\n\r\n")
  , ("HTTP/10.0", "GET / HTTP/10.0\r\n\r\n")
  , ("HTTP/1.99", "GET / HTTP/1.99\r\n\r\n")
  , ("an empty request line", "\r\n")
  , ("a blank request line", "  \t \r\n")
  , ("nothing at all", "")
  , ("an unsupported method", "FROB /x HTTP/1.0\r\n\r\n")
  , ("an unsupported method with a quote", "it's / HTTP/1.0\r\n\r\n")
  , ("an unsupported latin-1 method", "\xe9t\xe9 / HTTP/1.0\r\n\r\n")
  , ("HEAD is unsupported here: 501 without a page", "HEAD / HTTP/1.0\r\n\r\n")
  , ("method names are case-sensitive", "get / HTTP/1.0\r\n\r\n")
  , ("duplicate headers keep order and case", "GET / HTTP/1.0\r\nX-A: 1\r\nx-a: 2\r\nX-B: 3\r\nX-A: 4\r\n\r\n")
  , ("folded headers", "GET / HTTP/1.0\r\nX: a\r\n  b\r\n\tc\r\nY: d\r\n\r\n")
  , ("a value starting on a continuation line loses the fold", "GET / HTTP/1.0\r\nY:\r\n\tcont\r\nZ: \r\n  z\r\n\r\n")
  , ("whitespace around values","GET / HTTP/1.0\r\nX: \t lead\r\nY:trail  \t\r\nZ:\r\nW:  \r\n\r\n")
  , ("a line without a colon ends the headers", "GET / HTTP/1.0\r\nX: 1\r\nBogus line\r\nY: 2\r\n\r\n")
  , ("a name with a space ends the headers", "GET / HTTP/1.0\r\nX: 1\r\nA B: 2\r\n\r\n")
  , ("a leading continuation line is dropped", "GET / HTTP/1.0\r\n continued\r\nX: 1\r\n\r\n")
  , ("a line starting with a colon is dropped", "GET / HTTP/1.0\r\n:x\r\n bad\r\nY: 1\r\n\r\n")
  , ("From lines", "GET / HTTP/1.0\r\nFrom someone\r\nX: 1\r\nFrom other\r\nY: 2\r\nFrom last\r\n\r\n")
  , ("bare CR line endings inside headers", "GET / HTTP/1.0\r\nX: 1\rY: 2\r\r\nZ: 3\r\n\r\n")
  , ("latin-1 header names and values", "GET / HTTP/1.0\r\n\xe9: \xfc\x85\r\nA: \xa0\r\n\r\n")
  , ("headers ended by EOF", "GET / HTTP/1.0\r\nX: 1\r\nY: 2")
  , ("a header line ended by EOF without newline", "GET / HTTP/1.0\r\nX: 1")
  , ("a POST body", "POST /submit HTTP/1.0\r\nContent-Length: 5\r\n\r\nhello")
  , ("a latin-1 POST body", "POST /submit HTTP/1.0\r\nContent-Length: 4\r\n\r\n\xff\x00\xe9\n")
  , ("a short POST body", "POST /submit HTTP/1.0\r\nContent-Length: 50\r\n\r\nshort")
  , ("a POST body with leftovers", "POST /submit HTTP/1.0\r\nContent-Length: 3\r\n\r\nabcdef")
  , ("Content-Length with trailing space is kept as is", "POST /submit HTTP/1.0\r\nContent-Length: 3 \r\n\r\nabc")
  , ("Expect: 100-continue is ignored", "POST /e HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\nok")
  , ("pipelined requests: only the first is answered", "GET /first HTTP/1.0\r\n\r\nGET /second HTTP/1.0\r\n\r\n")
  , ("send_error with HTML in message and explanation", "TEAPOT / HTTP/1.0\r\n\r\n")
  , ("send_error 204 has no page", "NOCONTENT / HTTP/1.0\r\n\r\n")
  , ("send_error with an unknown code", "UNKNOWN / HTTP/1.0\r\n\r\n")
  , ("send_error defaults", "DEFAULT / HTTP/1.0\r\n\r\n")
  , ("send_error over HTTP/0.9", "TEAPOT /x HTTP/0.9\r\n\r\n")
  , ("a custom reason phrase", "REASON / HTTP/1.0\r\n\r\n")
  , ("an unknown code's empty phrase", "NOPHRASE / HTTP/1.0\r\n\r\n")
  , ("a handler exception closes without a response", "BOOM / HTTP/1.0\r\n\r\n")
  , ("a 65536-byte request line is accepted", "GET /" <> BC.replicate (65536 - 16) 'a' <> " HTTP/1.0\r\n\r\n")
  , ("a 65537-byte request line is 414", "GET /" <> BC.replicate (65537 - 16) 'a' <> " HTTP/1.0\r\n\r\n")
  , ("a much longer request line is 414", "GET /" <> BC.replicate 70000 'a' <> " HTTP/1.0\r\n\r\n")
  , ("a 65536-byte header line is accepted", "GET / HTTP/1.0\r\nX: " <> BC.replicate (65536 - 5) 'h' <> "\r\n\r\n")
  , ("a 65537-byte header line is 431", "GET / HTTP/1.0\r\nX: " <> BC.replicate (65537 - 5) 'h' <> "\r\n\r\n")
  , ("a long header line on HEAD has no page", "HEAD / HTTP/1.0\r\nX: " <> BC.replicate 70000 'h' <> "\r\n\r\n")
  , ("99 headers are accepted", "GET / HTTP/1.0\r\n" <> manyHeaders 99 <> "\r\n")
  , ("100 headers are 431", "GET / HTTP/1.0\r\n" <> manyHeaders 100 <> "\r\n")
  , ("100 header lines ended by EOF are accepted", "GET / HTTP/1.0\r\n" <> manyHeaders 100)
  ]
  where
    manyHeaders n = BS.concat [BC.pack ("H" <> show i <> ": " <> show i <> "\r\n") | i <- [1 .. n :: Int]]

wireSpec :: Int -> Int -> Spec
wireSpec python haskell = describe "responses compared byte for byte with CPython's http.server" $ do
  mapM_ (\(name, request) -> it name (void (sameAsPython python haskell request))) wireCases
  it "the comparisons cover the refusals they are meant to" $ do
    let statusFor name = case lookup name wireCases of
          Just request -> statusOf <$> exchange haskell request
          Nothing -> pure "missing case"
    statusFor "a 65537-byte request line is 414" `shouldReturn` "HTTP/1.0 414"
    statusFor "a 65537-byte header line is 431" `shouldReturn` "HTTP/1.0 431"
    statusFor "100 headers are 431" `shouldReturn` "HTTP/1.0 431"
    statusFor "99 headers are accepted" `shouldReturn` "HTTP/1.0 200"
    statusFor "four words" `shouldReturn` "HTTP/1.0 400"
    statusFor "an unsupported method" `shouldReturn` "HTTP/1.0 501"
    -- Refusals sent while the version is still HTTP/0.9 are a bare page.
    statusFor "HTTP/2.0" `shouldReturn` "<!DOCTYPE HT"
    statusFor "HTTP/0.9 GET" `shouldReturn` "[\"GET\", \"/si"
  it "sends one write per response" $ do
    -- CPython writes the header block and the body separately; the bytes are
    -- the same, the segments may differ.
    bytes <- exchange haskell "GET /one HTTP/1.0\r\n\r\n"
    BS.length bytes `shouldSatisfy` (> 0)

-- Timeouts ---------------------------------------------------------------------

timeoutSpec :: Int -> Int -> Spec
timeoutSpec python haskell = describe "per-operation connection timeouts (0.2 s)" $ do
  let both request = do
        (expected, pythonSeconds) <- exchangeOpen python request
        (actual, haskellSeconds) <- exchangeOpen haskell request
        normalize actual `shouldBe` normalize expected
        pure (pythonSeconds, haskellSeconds, actual)
  it "drops a silent connection without a response" $ do
    (_, seconds, actual) <- both ""
    actual `shouldBe` ""
    seconds `shouldSatisfy` (\s -> s >= 0.15 && s < 5)
  it "drops a connection stalled in the headers" $ do
    (_, _, actual) <- both "GET / HTTP/1.0\r\nX: 1\r\n"
    actual `shouldBe` ""
  it "lets the handler see a body read time out" $ do
    (_, _, actual) <- both "POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nabc"
    actual `shouldSatisfy` BS.isInfixOf "<timeout>"
  it "times out each operation, not the whole request" $ do
    -- Three header lines 0.12 s apart: 0.36 s in total, each wait < 0.2 s.
    let trickle sock = do
          mapM_ (\line -> sendAll sock line >> threadDelay 120000) ["GET /slow HTTP/1.0\r\n", "A: 1\r\n", "B: 2\r\n"]
          sendAll sock "\r\n"
          receiveAll sock
    expected <- withClient python trickle
    actual <- withClient haskell trickle
    normalize actual `shouldBe` normalize expected
    statusOf actual `shouldBe` "HTTP/1.0 200"

-- Handler exceptions -------------------------------------------------------

exceptionSpec :: IORef [(SockAddr, String)] -> Int -> Int -> Spec
exceptionSpec reports _ haskell = describe "handler exceptions" $ do
  it "are reported with the client address and close the connection" $ do
    (bytes, peer) <- withClient haskell $ \sock -> do
      peer <- getSocketName sock
      sendAll sock "BOOM / HTTP/1.0\r\n\r\n"
      Socket.shutdown sock ShutdownSend
      (,peer) <$> receiveAll sock
    bytes `shouldBe` ""
    let waitForReport n = do
          found <- lookup peer <$> readIORef reports
          case found of
            Just message -> pure message
            Nothing | n > (0 :: Int) -> threadDelay 10000 >> waitForReport (n - 1)
            Nothing -> expectationFailure "no report" >> pure ""
    message <- waitForReport 200
    message `shouldContain` "boom"
  it "print the client address the way Python does" $ do
    pythonAddress (SockAddrInet 50000 (tupleToHostAddress (127, 0, 0, 1))) `shouldBe` "('127.0.0.1', 50000)"

-- Lifecycle ------------------------------------------------------------------

quietConfig :: ServerConfig
quietConfig = defaultServerConfig {serverHost = "127.0.0.1", reportException = \_ _ -> pure ()}

ok :: Handler
ok request = sendResponse request (response 200 [("Content-Length", "2")] "ok")

lifecycleSpec :: Spec
lifecycleSpec = describe "server lifecycle" $ do
  it "binds without serving until serveForever runs" $
    bracket (createServer quietConfig ok) serverClose $ \server -> do
      port <- serverPort server
      port `shouldSatisfy` (> 0)
      withClient port $ \sock -> do
        sendAll sock "GET / HTTP/1.0\r\n\r\n"
        timeout 200000 (recv sock 10) `shouldReturn` Nothing
        loop <- forkIO (serveForever server)
        reply <- receiveAll sock
        statusOf reply `shouldBe` "HTTP/1.0 200"
        shutdown server
        void (pure loop)
  it "returns from shutdown at once when nothing runs, and the next loop exits at once" $
    bracket (createServer quietConfig ok) serverClose $ \server -> do
      timeout 1000000 (shutdown server) `shouldReturn` Just ()
      timeout 1000000 (serveForever server) `shouldReturn` Just ()
  it "stops serving after shutdown and can serve again" $
    bracket (createServer quietConfig ok) serverClose $ \server -> do
      port <- serverPort server
      done <- newEmptyMVar
      _ <- forkIO (serveForever server >> putMVar done ())
      statusOf <$> exchange port "GET / HTTP/1.0\r\n\r\n" `shouldReturn` "HTTP/1.0 200"
      shutdown server
      timeout 1000000 (takeMVar done) `shouldReturn` Just ()
      _ <- forkIO (serveForever server >> putMVar done ())
      statusOf <$> exchange port "GET / HTTP/1.0\r\n\r\n" `shouldReturn` "HTTP/1.0 200"
      shutdown server
      timeout 1000000 (takeMVar done) `shouldReturn` Just ()
  it "waits for running handlers on close when configured (simulation)" $ do
    (closed, entered, release) <- blockedHandlerClose True
    tryReadMVar closed >>= (`shouldSatisfy` isNothing)
    putMVar release ()
    timeout 2000000 (readMVar closed) `shouldReturn` Just ()
    void (pure entered)
  it "does not wait for running handlers otherwise (observation)" $ do
    (closed, _, release) <- blockedHandlerClose False
    tryReadMVar closed >>= (`shouldSatisfy` isJust)
    putMVar release ()
  it "rebinds the same port after close (SO_REUSEADDR)" $ do
    port <- withRunningServer quietConfig ok $ \server -> do
      port <- serverPort server
      statusOf <$> exchange port "GET / HTTP/1.0\r\n\r\n" `shouldReturn` "HTTP/1.0 200"
      pure port
    withRunningServer quietConfig {serverPortNumber = port} ok $ \server ->
      serverPort server `shouldReturn` port
  it "applies a changed timeout to later connections" $
    withRunningServer quietConfig ok $ \server -> do
      port <- serverPort server
      setConnectionTimeout server (Just 0.1)
      (bytes, seconds) <- exchangeOpen port ""
      bytes `shouldBe` ""
      seconds `shouldSatisfy` (< 5)
  it "refuses a busy port" $
    withRunningServer quietConfig ok $ \server -> do
      port <- serverPort server
      result <- try (bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> Socket.bind sock (localhost port))
      either (\(_ :: IOException) -> True) (const False) result `shouldBe` True
  it "handles concurrent connections independently" $
    withRunningServer quietConfig echo $ \server -> do
      port <- serverPort server
      slow <- forkIO $ withClient port $ \sock -> sendAll sock "GET / HTTP/1.0\r\n" >> threadDelay 500000
      replies <- forM [1 .. 20 :: Int] $ \i -> exchange port (BC.pack ("GET /" <> show i <> " HTTP/1.0\r\n\r\n"))
      map statusOf replies `shouldBe` replicate 20 "HTTP/1.0 200"
      void (pure slow)

-- Close a server while a handler is blocked; report whether close returned
-- within 200 ms.
blockedHandlerClose :: Bool -> IO (MVar (), MVar (), MVar ())
blockedHandlerClose waitForHandlers = do
  entered <- newEmptyMVar
  release <- newEmptyMVar
  closed <- newEmptyMVar
  let handler request = do
        putMVar entered ()
        readMVar release
        ok request
  server <- createServer quietConfig {waitForHandlersOnClose = waitForHandlers} handler
  port <- serverPort server
  _ <- forkIO (serveForever server)
  _ <- forkIO (void (try (exchange port "GET / HTTP/1.0\r\n\r\n") :: IO (Either SomeException ByteString)))
  takeMVar entered
  shutdown server
  _ <- forkIO (serverClose server >> putMVar closed ())
  threadDelay 200000
  pure (closed, entered, release)

-- Pure parts against CPython -----------------------------------------------

pureSpec :: Spec
pureSpec = describe "pure parts against CPython" $ do
  it "has CPython's status table" $ do
    expected <- pythonJsonOut "from http import HTTPStatus\nimport json\nprint(json.dumps([[s.value, s.phrase, s.description] for s in HTTPStatus]))" ""
    let actual = Array [Array [Int (fromIntegral code), String phrase, String description] | (code, phrase, description) <- statusTable]
    actual `shouldBe` expected
  it "renders send_error pages like CPython" $ do
    let cases = [(404, "Not Found", "Nothing matches the given URI"), (418, "<tea & cake>", "a > b & c < d \"q\" 'q'"), (599, "???", "???"), (500, "caf\233 \8364 \128512", "")]
        input = jsonInput (Array [Array [Int code, String m, String e] | (code, m, e) <- cases])
    expected <- pythonJsonOut "import html, json, sys\nfrom http.server import DEFAULT_ERROR_MESSAGE as F\nprint(json.dumps([(F % {'code': c, 'message': html.escape(m, quote=False), 'explain': html.escape(e, quote=False)}) for c, m, e in json.load(sys.stdin)]))" input
    let actual = Array [String (TE.decodeUtf8 (errorPage (fromIntegral code) m e)) | (code, m, e) <- cases]
    actual `shouldBe` expected
  it "formats Date like email.utils.formatdate(usegmt=True)" $ do
    let stamps = [0, 951782400, 1700000000.9, 4102444799, 1234567890] :: [Double]
        input = jsonInput (Array (map Float stamps))
    expected <- pythonJsonOut "import json, sys\nfrom email.utils import formatdate\nprint(json.dumps([formatdate(t, usegmt=True) for t in json.load(sys.stdin)]))" input
    let actual = Array [String (TE.decodeLatin1 (httpDate (posixSecondsToUTCTime (realToFrac t)))) | t <- stamps]
    actual `shouldBe` expected
  it "parses request lines like parse_request (generated lines)" $ do
    let lines' = generatedRequestLines
        input = jsonInput (Array (map (String . TE.decodeLatin1) lines'))
    expected <- pythonJsonOut requestLineProbe input
    mismatches lines' (map requestLineOutcome lines') expected `shouldBe` []
  it "parses header blocks like http.client (generated blocks)" $ do
    let blocks = generatedHeaderBlocks
        input = jsonInput (Array (map (String . TE.decodeLatin1) blocks))
    expected <- pythonJsonOut "import http.client, json, sys\nprint(json.dumps([[[k, v] for k, v in http.client._parse_header_lines([b.encode('latin-1')]).items()] for b in json.load(sys.stdin)]))" input
    let actual = [Array [Array [latin1 k, latin1 v] | (k, v) <- parseHeaderBlock block] | block <- blocks]
    mismatches blocks actual expected `shouldBe` []
  it "renders a response without status line and headers for HTTP/0.9" $
    renderResponse "s" "d" "HTTP/0.9" (response 200 [("A", "b")] "body") `shouldBe` "body"
  it "renders a response's header order" $
    renderResponse "s" "d" "HTTP/1.1" (response 201 [("A", "b"), ("A", "c")] "x")
      `shouldBe` "HTTP/1.0 201 Created\r\nServer: s\r\nDate: d\r\nA: b\r\nA: c\r\n\r\nx"
  where
    latin1 = String . TE.decodeLatin1

-- The first few inputs whose results differ from Python's.
mismatches :: [ByteString] -> [Json] -> Json -> [(ByteString, Json, Json)]
mismatches inputs actual = \case
  Array expected
    | length expected == length inputs ->
        take 5 [(input, mine, theirs) | (input, mine, theirs) <- zip3 inputs actual expected, mine /= theirs]
  other -> [("<Python returned another shape>", Null, other)]

requestLineProbe :: Text
requestLineProbe =
  T.unlines
    [ "import io, json, sys"
    , "from http.server import BaseHTTPRequestHandler"
    , "class H(BaseHTTPRequestHandler):"
    , "    def send_error(self, code, message=None, explain=None):"
    , "        self.err = [code, message, self.request_version]"
    , "out = []"
    , "for line in json.load(sys.stdin):"
    , "    h = H.__new__(H)"
    , "    h.raw_requestline = line.encode('latin-1')"
    , "    h.rfile = io.BytesIO(b'\\r\\n')"
    , "    h.err = None"
    , "    ok = h.parse_request()"
    , "    if h.err: out.append(['error'] + h.err)"
    , "    elif not ok: out.append(['empty'])"
    , "    else: out.append(['ok', h.command, h.path, h.request_version, h.requestline])"
    , "print(json.dumps(out))"
    ]

requestLineOutcome :: ByteString -> Json
requestLineOutcome line = case parseRequestLine line of
  Nothing -> Array [String "empty"]
  Just (Left refusal) ->
    Array [String "error", Int (fromIntegral (lineErrorStatus refusal)), String (lineErrorMessage refusal), latin1 (lineErrorVersion refusal)]
  Just (Right parsed) ->
    Array [String "ok", latin1 (lineCommand parsed), latin1 (linePath parsed), latin1 (lineVersion parsed), latin1 (lineText parsed)]
  where
    latin1 = String . TE.decodeLatin1

-- A deterministic generator (splitmix-style) for the generated cases.
pseudoRandom :: Word64 -> [Word64]
pseudoRandom = drop 1 . iterate step
  where
    step x = let z = x + 0x9e3779b97f4a7c15 in mix z
    mix z0 =
      let z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xbf58476d1ce4e5b9
          z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb
       in z2 `xor` (z2 `shiftR` 31)

pick :: [a] -> Word64 -> a
pick options r = options !! fromIntegral (r `mod` fromIntegral (length options))

chunksOf :: Int -> [a] -> [[a]]
chunksOf n xs = case splitAt n xs of
  (chunk, rest) | length chunk == n -> chunk : chunksOf n rest
  _ -> []

generatedRequestLines :: [ByteString]
generatedRequestLines = take 1500 (map build (chunksOf 12 (pseudoRandom 2026)))
  where
    methods = ["GET", "POST", "get", "HEAD", "\xe9", "G'T"]
    targets = ["/", "//a//b", "/x?y#z", "http://h/p", "*", "/\xe9", "///", "/'\""]
    versions = ["HTTP/1.0", "HTTP/1.1", "HTTP/0.9", "HTTP/2.0", "HTTP/1.x", "HTTP/1", "HTTP/01.01", "HTTPS/1.0", "HTTP/1.1.1", "HTTP/12345678901.0", "HTTP/1234567890.0", "HTTP/\xb2.0", "http/1.0", "HTTP/1.0/x", "HTTP/", "HTTP/.1", "HTTP/3.0", "HTTP/1.10", "HTTP/1.-1", "HTTP/+1.0"]
    separators = [" ", "\t", "  ", "\x0b", "\x0c", "\x1c", "\x1d", "\x1e", "\x1f", "\x85", "\xa0", " \t "]
    endings = ["\r\n", "\n", "", "\r\r\n", "\r"]
    edges = ["", " ", "\t"]
    build rs = case rs of
      (r0 : r1 : r2 : r3 : r4 : r5 : r6 : r7 : r8 : r9 : _) ->
        let wordsOf = case r0 `mod` 7 of
              0 -> []
              1 -> [pick methods r1]
              2 -> [pick methods r1, pick targets r2]
              3 -> [pick methods r1, pick targets r2, pick versions r3]
              4 -> [pick methods r1, pick targets r2, pick versions r3]
              5 -> [pick methods r1, pick targets r2, "x", pick versions r3]
              _ -> [pick methods r1, pick targets r2, "x", "y", pick versions r3]
            separator = pick separators r4
            alternate = pick separators r5
            joined = BS.intercalate (if odd r6 then separator else alternate) wordsOf
         in pick edges r7 <> joined <> pick edges r8 <> pick endings r9
      _ -> ""

generatedHeaderBlocks :: [ByteString]
generatedHeaderBlocks = take 1500 (map build (chunksOf 16 (pseudoRandom 1999)))
  where
    pieces =
      [ "X: 1", "x: 2", "Y:", "Z:  spaced  \t", " cont", "\tcont2", "From a", "From ", ":bad", "Bogus"
      , "A B: c", "\xe9: \xfc", "\x85:\xa0", "Content-Length: 3 ", "K:v:w", "Q :sp", "\x7f: del", "!#$%: sym"
      ]
    endings = ["\r\n", "\n", "\r"]
    terminators = ["\r\n", "\n", "", "\r"]
    build rs = case rs of
      (count : rest) ->
        let n = fromIntegral (count `mod` 7)
            line (a, b) = pick pieces a <> pick endings b
            pairs = take n (zip rest (drop 7 rest))
         in BS.concat (map line pairs) <> pick terminators (rest !! 14)
      [] -> ""

jsonInput :: Json -> ByteString
jsonInput = either (error . show) id . dumps defaultDumps

pythonJsonOut :: Text -> ByteString -> IO Json
pythonJsonOut code input = do
  result <- runPython code [] input
  case parseJson pythonLoads (resultStdout result) of
    Right value -> pure value
    Left problem -> do
      expectationFailure ("Python failed: " <> problem <> "\n" <> BC.unpack (resultStderr result))
      pure Null
