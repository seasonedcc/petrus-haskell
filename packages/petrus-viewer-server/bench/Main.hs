-- | Load client for comparing viewer backends (the Haskell server and the
-- upstream Node servers) with the same client. bench/run.mjs starts the
-- servers and calls this once per scenario; each run prints one JSON line.
--
-- > petrus-viewer-bench relay  --port P [--pairs 8] [--iters 2000]
-- > petrus-viewer-bench fanout --port P [--path /collab-ws] [--receivers 50] [--messages 1000]
-- > petrus-viewer-bench http   --port P --endpoint open-file|resolve-ref --file F
-- >                            [--concurrency 16] [--requests 20000]
module Main (main) where

import Control.Concurrent.Async (forConcurrently, forConcurrently_, mapConcurrently_, withAsync)
import Control.Concurrent.STM
import Control.Monad (forM_, forever, replicateM, unless, void, when)
import Control.Exception (bracket)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Char (toLower)
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Network.HTTP.Client qualified as HC
import Network.Socket qualified as S
import Network.Socket.ByteString qualified as SB
import Network.WebSockets qualified as WS
import Petrus.Viewer.Endpoints (ResolveResult (..), readFileNode, resolveRef)
import Petrus.Viewer.Json
import Petrus.Viewer.Relay (RelayKind (..), Routed (..), relayMessage)
import Petrus.Viewer.Url (decodeURIComponent, parseUrl, resolveUrl, serializeUrl)
import System.Directory (doesPathExist)
import System.Posix.IO qualified as PIO
import System.Posix.Files qualified as PF
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeDirectory, (</>))
import Text.Read (readMaybe)

main :: IO ()
main =
  getArgs >>= \case
    ("relay" : opts) -> relayBench (options opts)
    ("fanout" : opts) -> fanoutBench (options opts)
    ("http" : opts) -> httpBench (options opts)
    ("micro" : opts) -> microBench (options opts)
    _ -> die "usage: petrus-viewer-bench relay|fanout|http --port P ..."

type Opts = [(String, String)]

options :: [String] -> Opts
options = \case
  (('-' : '-' : k) : v : rest) -> (k, v) : options rest
  _ -> []

opt :: Read a => Opts -> String -> a -> a
opt o k d = fromMaybe d (lookup k o >>= readMaybe)

optS :: Opts -> String -> String -> String
optS o k d = fromMaybe d (lookup k o)

-- | @--host@ (default 127.0.0.1) and @--port@.
port :: Opts -> IO (String, Int)
port o = do
  p <- maybe (die "--port is required") pure (lookup "port" o >>= readMaybe)
  pure (optS o "host" "127.0.0.1", p)

-- | Latency summary in microseconds plus throughput.
report :: Text -> [(Text, JsValue)] -> Double -> Int -> [Double] -> IO ()
report scenario extra elapsed ops lats = do
  let sorted = sort lats
      n = length sorted
      pct p = if n == 0 then 0 else sorted !! min (n - 1) (floor (p * fromIntegral n :: Double))
      us x = num (fromIntegral (round (x * 1e7) :: Int) / 10)
  BL.putStr . (<> "\n") . encodeJsLazy $
    obj
      ( [ ("scenario", str scenario)
        , ("ops", int ops)
        , ("seconds", num elapsed)
        , ("opsPerSec", num (fromIntegral (round (fromIntegral ops / elapsed :: Double) :: Int)))
        , ("p50us", us (pct 0.5))
        , ("p99us", us (pct 0.99))
        ]
          ++ extra
      )

-- WebSocket helpers -------------------------------------------------------

data Client = Client {conn :: WS.Connection, inbox :: TQueue B.ByteString}

withClient :: (String, Int) -> String -> (Client -> IO a) -> IO a
withClient (host, p) path act =
  WS.runClient host p path $ \c -> do
    q <- newTQueueIO
    withAsync (forever (WS.receiveData c >>= atomically . writeTQueue q)) $ \_ ->
      act (Client c q) <* WS.sendClose c ("" :: Text)

recv :: Client -> IO B.ByteString
recv c = atomically (readTQueue (inbox c))

-- | The next message containing @needle@ (others are skipped).
recvMatching :: B.ByteString -> Client -> IO B.ByteString
recvMatching needle c = do
  m <- recv c
  if needle `B.isInfixOf` m then pure m else recvMatching needle c

idFrom :: Text -> B.ByteString -> Text
idFrom k m = case parseJs m of
  Right v | Just o <- asObject v, Just (JsStr s) <- lookupKey k o -> jsStringText s
  _ -> ""

-- | Nest a list of clients.
withClients :: Int -> (String, Int) -> String -> ([Client] -> IO a) -> IO a
withClients 0 _ _ act = act []
withClients n p path act = withClient p path $ \c -> withClients (n - 1) p path (act . (c :))

-- Agent relay round trip ----------------------------------------------------

-- | A 2.4 KB inspect-style result, the size of a small net summary.
resultPayload :: JsValue
resultPayload =
  obj
    [ ("netName", str "bench")
    , ( "places"
      , arr [obj [("id", str ("orders.p" <> T.pack (show i))), ("tokens", int i), ("label", str "a place label")] | i <- [1 .. 40 :: Int]]
      )
    ]

-- | Agent clients send requests targeted at their browser client, which
-- answers each one with a response targeted back; one op = one round trip.
relayBench :: Opts -> IO ()
relayBench o = do
  p <- port o
  let pairs = opt o "pairs" (8 :: Int)
      iters = opt o "iters" (2000 :: Int)
      warm = max 50 (iters `div` 10)
  latsRef <- newIORef []
  ready <- newTVarIO (0 :: Int)
  go <- newEmptyTMVarIO
  done <- newTVarIO (0 :: Int)
  startRef <- newIORef 0
  let pairRun = withClient p "/ws/agent" $ \browser -> do
        bid <- idFrom "clientId" <$> recvMatching "welcome" browser
        let answer = forever $ do
              m <- recvMatching "\"request\"" browser
              case parseJs m of
                Right v | Just req <- asObject v -> do
                  let resp =
                        obj
                          [ ("protocol", str "petrus-agent")
                          , ("version", int 1)
                          , ("kind", str "response")
                          , ("requestId", fromMaybe JsNull (lookupKey "requestId" req))
                          , ("action", fromMaybe JsNull (lookupKey "action" req))
                          , ("ok", JsBool True)
                          , ("result", resultPayload)
                          , ("targetClientId", fromMaybe JsNull (lookupKey "clientId" req))
                          ]
                  WS.sendTextData (conn browser) (encodeJs resp)
                _ -> pure ()
        withAsync answer $ \_ -> withClient p "/ws/agent" $ \agent -> do
          _ <- recvMatching "welcome" agent
          let request i =
                encodeJs $
                  obj
                    [ ("protocol", str "petrus-agent")
                    , ("version", int 1)
                    , ("kind", str "request")
                    , ("requestId", str ("r" <> T.pack (show i)))
                    , ("action", str "document.inspect")
                    , ("params", obj [("includeSchema", JsBool True)])
                    , ("targetClientId", str bid)
                    ]
              roundTrip i = do
                t0 <- getMonotonicTime
                WS.sendTextData (conn agent) (request i)
                _ <- recvMatching "\"response\"" agent
                t1 <- getMonotonicTime
                pure (t1 - t0)
          forM_ [1 .. warm] (void . roundTrip)
          atomically (modifyTVar' ready (+ 1))
          atomically (readTMVar go)
          lats <- mapM roundTrip [1 .. iters]
          atomicModifyIORef' latsRef (\acc -> (lats ++ acc, ()))
          atomically (modifyTVar' done (+ 1))
          -- keep both sockets open until every pair has finished
          atomically (readTVar done >>= \d -> unless (d == pairs) retry)
  withAsync (forConcurrently_ [1 .. pairs] (const pairRun)) $ \_ -> do
    atomically (readTVar ready >>= \r -> unless (r == pairs) retry)
    getMonotonicTime >>= writeIORef startRef
    atomically (putTMVar go ())
    atomically (readTVar done >>= \d -> unless (d == pairs) retry)
    t1 <- getMonotonicTime
    t0 <- readIORef startRef
    lats <- readIORef latsRef
    report "relay" [("pairs", int pairs)] (t1 - t0) (pairs * iters) lats

-- Collaboration fan-out ---------------------------------------------------

-- | One sender, @receivers@ peers: the sender bursts @messages@ cursor
-- updates; one op = one delivery to one receiver.
fanoutBench :: Opts -> IO ()
fanoutBench o = do
  p <- port o
  let path = optS o "path" "/collab-ws"
      receivers = opt o "receivers" (50 :: Int)
      messages = opt o "messages" (1000 :: Int)
      cursor :: Text -> Int -> Double -> B.ByteString
      cursor phase i t =
        encodeJs $
          obj [("type", str "cursor"), ("phase", str phase), ("x", int i), ("y", int (i * 2)), ("userName", str "bench"), ("seq", int i), ("t", num t)]
  withClients receivers p path $ \peers -> withClient p path $ \sender -> do
    -- every peer has seen the sender join (peer_count == receivers + 1)
    let total = receivers + 1
        countMsg = "\"count\":" <> B.pack (map (fromIntegral . fromEnum) (show total))
    forM_ (sender : peers) $ \c -> recvMatching countMsg c
    let burst phase = do
          t0 <- getMonotonicTime
          results <-
            withAsync
              ( forM_ [1 .. messages] $ \i ->
                  getMonotonicTime >>= WS.sendTextData (conn sender) . cursor phase i
              )
              $ \_ -> forConcurrently peers $ \c -> do
                lats <- replicateM messages $ do
                  m <- recvMatching ("\"phase\":\"" <> encodePhase phase <> "\"") c
                  now <- getMonotonicTime
                  pure $ case parseJs m of
                    Right v | Just ob <- asObject v, Just n <- lookupKey "t" ob >>= asNumber -> now - n
                    _ -> 0
                end <- getMonotonicTime
                pure (end, lats)
          let end = maximum (map fst results)
          pure (end - t0, concatMap snd results)
        encodePhase = B.pack . map (fromIntegral . fromEnum) . T.unpack
    _ <- burst "warm"
    (elapsed, lats) <- burst "run"
    report "fanout" [("receivers", int receivers), ("messages", int messages)] elapsed (receivers * messages) lats

-- HTTP endpoints ------------------------------------------------------------

-- | open-file: one op = POST the file as pending, then GET it;
-- resolve-ref: one op = POST a relative ref resolved against the file's
-- directory.
--
-- open-file keeps one pending file for the whole server, so with several
-- clients the work would depend on how the server interleaves them (a GET
-- reads the file only when no other GET consumed it since the last POST).
-- With more than one client the op therefore runs in lockstep rounds: every
-- client POSTs, all wait, every client GETs, all wait. Each round is then
-- the same work on every server: one POST per client (200), and one GET
-- that reads the file (200) while the others find nothing pending (204).
-- Latencies count the time in requests, not the time waiting for the
-- other clients.
--
-- Each client is one keep-alive connection driven by 'Conn': the request
-- is a fixed byte string and the response is read by its Content-Length.
-- A general client (http-client) costs more per request than these
-- servers do, and with 16 clients it, not the server, set the pace.
httpBench :: Opts -> IO ()
httpBench o = do
  p <- port o
  let endpoint = optS o "endpoint" "resolve-ref"
      file = optS o "file" ""
      concurrency = opt o "concurrency" (16 :: Int)
      requests = opt o "requests" (20000 :: Int)
      hostHeader = BC.pack ((if ':' `elem` fst p then "[" <> fst p <> "]" else fst p) <> ":" <> show (snd p))
  when (null file) (die "--file is required")
  statuses <- newIORef ([] :: [Int])
  barrier <- newBarrier concurrency
  let post path body =
        "POST " <> path <> " HTTP/1.1\r\nHost: " <> hostHeader <> "\r\nContent-Type: application/json\r\nContent-Length: "
          <> BC.pack (show (B.length body)) <> "\r\n\r\n" <> body
      get path = "GET " <> path <> " HTTP/1.1\r\nHost: " <> hostHeader <> "\r\n\r\n"
      ref = "./" <> T.pack (takeFileNameOf file)
      basePath = "file://" <> T.pack (takeDirectory file </> "A.json")
      openFilePost = post "/__petrus/open-file" (encodeJs (obj [("path", str (T.pack file))]))
      openFileGet = get "/__petrus/open-file"
      resolvePost = post "/__petrus/resolve-ref" (encodeJs (obj [("ref", str ref), ("basePath", str basePath)]))
      timed act = do
        t0 <- getMonotonicTime
        x <- act
        t1 <- getMonotonicTime
        pure (x, t1 - t0)
      lockstep = concurrency > 1 && endpoint == "open-file"
      -- the statuses, and the time spent in requests
      op :: Conn -> IO ([Int], Double)
      op c = case endpoint of
        "open-file-get" -> (\(s, t) -> ([s], t)) <$> timed (exchange c openFileGet)
        "open-file" -> do
          (s1, t1) <- timed (exchange c openFilePost)
          when lockstep (awaitBarrier barrier)
          (s2, t2) <- timed (exchange c openFileGet)
          when lockstep (awaitBarrier barrier)
          pure ([s1, s2], t1 + t2)
        _ -> (\(s, t) -> ([s], t)) <$> timed (exchange c resolvePost)
      perWorker = requests `div` concurrency
      worker record c = replicateM perWorker $ do
        (ss, t) <- op c
        when record (atomicModifyIORef' statuses (\acc -> (ss ++ acc, ())))
        pure t
  bracket (replicateM concurrency (openConn p)) (mapM_ closeConn) $ \conns -> do
    -- warm up (JIT, connections)
    mapConcurrently_ (worker False) conns
    t0 <- getMonotonicTime
    lats <- concat <$> forConcurrently conns (worker True)
    t1 <- getMonotonicTime
    ss <- readIORef statuses
    let countOf s = length (filter (== s) ss)
    report
      (T.pack endpoint)
      [ ("concurrency", int concurrency)
      , ("status200", int (countOf 200))
      , ("status204", int (countOf 204))
      , ("statusOther", int (length ss - countOf 200 - countOf 204))
      ]
      (t1 - t0)
      (perWorker * concurrency)
      lats
  where
    takeFileNameOf = reverse . takeWhile (/= '/') . reverse

-- | One keep-alive HTTP/1.1 connection and the bytes read past the last
-- response.
data Conn = Conn S.Socket (IORef B.ByteString)

openConn :: (String, Int) -> IO Conn
openConn (host, p) = do
  addr <- S.getAddrInfo (Just S.defaultHints {S.addrSocketType = S.Stream}) (Just host) (Just (show p)) >>= \case
    a : _ -> pure a
    [] -> die ("cannot resolve " <> host)
  s <- S.socket (S.addrFamily addr) S.Stream S.defaultProtocol
  S.setSocketOption s S.NoDelay 1
  S.connect s (S.addrAddress addr)
  Conn s <$> newIORef ""

closeConn :: Conn -> IO ()
closeConn (Conn s _) = S.close s

-- | Send one request and read its response; the status code. Responses
-- must carry Content-Length (or be 204/304), as both servers' do here.
exchange :: Conn -> B.ByteString -> IO Int
exchange (Conn s pending) request = do
  SB.sendAll s request
  buffered <- readIORef pending
  (headEnd, buf) <- fill buffered (\b -> let (h, rest) = B.breakSubstring "\r\n\r\n" b in if B.null rest then Nothing else Just (B.length h + 4))
  let headBytes = B.take headEnd buf
      status = maybe 0 fst (BC.readInt (B.take 3 (B.drop 9 headBytes)))
      fields = map (BC.map toLower . BC.takeWhile (/= ':')) (drop 1 (BC.lines headBytes))
      valueOf name =
        [ BC.dropWhile (== ' ') (BC.drop 1 v)
        | line <- drop 1 (BC.lines headBytes)
        , let (k, v) = BC.break (== ':') line
        , BC.map toLower k == name
        ]
  when ("transfer-encoding" `elem` fields) (die "the load client does not read chunked responses")
  len <- case valueOf "content-length" of
    v : _ | Just (n, _) <- BC.readInt v -> pure n
    _ | status == 204 || status == 304 -> pure 0
    _ -> die ("response without Content-Length: " <> show headBytes)
  (_, full) <- fill buf (\b -> if B.length b >= headEnd + len then Just 0 else Nothing)
  writeIORef pending (B.drop (headEnd + len) full)
  pure status
  where
    fill b done = case done b of
      Just x -> pure (x, b)
      Nothing -> do
        chunk <- SB.recv s 65536
        when (B.null chunk) (die "the server closed the connection")
        fill (b <> chunk) done

-- | A reusable barrier for @n@ threads.
data Barrier = Barrier Int (TVar Int) (TVar Int)

newBarrier :: Int -> IO Barrier
newBarrier n = Barrier n <$> newTVarIO 0 <*> newTVarIO 0

awaitBarrier :: Barrier -> IO ()
awaitBarrier (Barrier n waiting generation) = do
  mine <- atomically $ do
    w <- readTVar waiting
    g <- readTVar generation
    if w + 1 == n
      then Nothing <$ (writeTVar waiting 0 >> writeTVar generation (g + 1))
      else Just g <$ writeTVar waiting (w + 1)
  forM_ mine $ \g -> atomically (readTVar generation >>= \now -> when (now == g) retry)

-- Library micro-benchmarks ------------------------------------------------

-- | Time the library pieces on the request paths (one op = one call).
microBench :: Opts -> IO ()
microBench o = do
  let file = optS o "file" ""
      iters = opt o "iters" (20000 :: Int)
  when (null file) (die "--file is required")
  raw <- B.readFile file
  mgr <- HC.newManager HC.defaultManagerSettings
  let content = either (const "") id (TE.decodeUtf8' raw)
      ref = "./" <> T.pack (reverse (takeWhile (/= '/') (reverse file)))
      base = "file://" <> T.pack (takeDirectory file </> "A.json")
      parsed = either (const JsNull) id (parseJs raw)
      relayIn = encodeJs (obj [("protocol", str "petrus-agent"), ("version", int 1), ("kind", str "response"), ("requestId", str "r1"), ("ok", JsBool True), ("result", resultPayload), ("targetClientId", str "1")])
      timeIt :: Text -> (Int -> IO Int) -> IO ()
      timeIt name f = do
        _ <- mapM f [1 .. iters `div` 10]
        t0 <- getMonotonicTime
        total <- sum <$> mapM f [1 .. iters]
        t1 <- getMonotonicTime
        BL.putStr . (<> "\n") . encodeJsLazy $
          obj [("micro", str name), ("usPerOp", num (fromIntegral (round ((t1 - t0) / fromIntegral iters * 1e7) :: Int) / 10)), ("check", int (total `mod` 7))]
  timeIt "resolveUrl" $ \i -> pure $! maybe 0 (T.length . serializeUrl) (resolveUrl (ref <> T.pack (show (i `mod` 2))) base)
  timeIt "parseUrl base" $ \i -> pure $! maybe 0 (T.length . serializeUrl) (parseUrl (base <> T.pack (show (i `mod` 2))))
  timeIt "parseUrl short" $ \i -> pure $! maybe 0 (T.length . serializeUrl) (parseUrl ("file:///a/b" <> T.pack (show (i `mod` 2))))
  timeIt "parseUrl only (no serialize)" $ \i -> pure $! maybe 0 (const 1) (parseUrl (base <> T.pack (show (i `mod` 2))))
  timeIt "parseJs net file" $ \i -> pure $! either (const i) (const 1) (parseJs raw)
  timeIt "encodeJs content string" $ \i -> pure $! B.length (encodeJs (obj [("content", str (if i < 0 then T.empty else content)), ("n", int i)]))
  timeIt "decode+jsString file bytes" $ \i -> pure $! i + B.length (jsStringBytes (jsString (TE.decodeUtf8Lenient (if i < 0 then B.empty else raw))))
  timeIt "readFileNode+encode (resolve-ref body)" $ \i -> either T.length (\c -> i + B.length (encodeJs (obj [("content", str c)]))) <$> readFileNode file
  timeIt "encodeJs parsed net" $ \i -> pure $! i + B.length (encodeJs parsed)
  timeIt "relayMessage parse+route+encode" $ \i -> pure $! i + case parseJs relayIn of
    Right v | Just r <- relayMessage AgentRelay (jsString "2") v -> fromIntegral (BL.length (routedBytes r))
    _ -> 0
  -- a screenshot response: a 2 MB data URL in one string
  let screenshotIn = encodeJs (obj [("protocol", str "petrus-agent"), ("kind", str "response"), ("requestId", str "r1"), ("ok", JsBool True), ("result", obj [("dataUrl", str ("data:image/png;base64," <> T.replicate 500000 "iVB+"))])])
  timeIt "relayMessage 2 MB screenshot" $ \i -> pure $! i + case parseJs (if i < 0 then B.empty else screenshotIn) of
    Right v | Just r <- relayMessage AgentRelay (jsString "2") v -> fromIntegral (BL.length (routedBytes r))
    _ -> 0
  let filePath = takeDirectory file </> "B.json"
  timeIt "decodeURIComponent path" $ \i -> pure $! i + either T.length T.length (decodeURIComponent (T.pack file))
  timeIt "doesPathExist" $ \i -> (\b -> if b then i else 0) <$> doesPathExist filePath
  timeIt "readFileNode" $ \i -> either T.length ((+ i) . T.length) <$> readFileNode filePath
  timeIt "B.readFile" $ \i -> (+ i) . B.length <$> B.readFile filePath
  timeIt "open+close" $ \i -> PIO.openFd filePath PIO.ReadOnly PIO.defaultFileFlags >>= PIO.closeFd >> pure i
  timeIt "stat" $ \i -> (\s -> i + fromIntegral (PF.fileSize s)) <$> PF.getFileStatus filePath
  timeIt "decodeUtf8 file" $ \i -> pure $! i + T.length (TE.decodeUtf8 (if i < 0 then B.empty else raw))
  timeIt "resolveRef (file)" $ \_ -> do
    r <- resolveRef mgr ref base
    pure $ case r of
      Resolved _ -> 1
      ResolveError _ -> 2
