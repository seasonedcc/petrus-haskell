-- | Load client for comparing viewer backends (the Haskell server and the
-- upstream Node servers) with the same client. bench/run.mjs starts the
-- servers and calls this once per scenario; each run prints one JSON line.
--
-- > petrus-viewer-bench relay   --port P [--pairs 8] [--iters 2000]
-- > petrus-viewer-bench fanout  --port P [--path /collab-ws] [--receivers 50] [--messages 1000]
-- > petrus-viewer-bench http    --port P --endpoint open-file|resolve-ref --file F
-- >                             [--concurrency 16] [--requests 20000]
-- > petrus-viewer-bench http    --port P --endpoint get --target /PATH [--concurrency 16] [--requests 20000]
-- > petrus-viewer-bench mcp     --port RELAY --cmd '["petrus-mcp"]' [--cwd DIR] [--tool T] [--args JSON]
-- >                             [--concurrency 1] [--calls 2000]
-- > petrus-viewer-bench startup --cmd '["petrus","--no-open","net.json"]' [--cwd DIR] [--rounds 10]
-- > petrus-viewer-bench backend [--port 7243]
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (forConcurrently, forConcurrently_, mapConcurrently_, withAsync)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Monad (forM_, forever, replicateM, unless, void, when)
import Control.Exception (IOException, SomeException, bracket, finally, try)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Char (isDigit, toLower)
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types qualified as H
import Network.Socket qualified as S
import Network.Socket.ByteString qualified as SB
import Network.Wai qualified as W
import Network.Wai.Handler.Warp qualified as Warp
import Network.WebSockets qualified as WS
import Numeric (readHex)
import Petrus.Viewer.Endpoints (ResolveResult (..), readFileNode, resolveRef)
import Petrus.Viewer.Json
import Petrus.Viewer.Log (isoTimestamp, logLine, newConsoleLogger)
import Petrus.Viewer.Relay (RelayKind (..), Routed (..), relayMessage)
import Petrus.Viewer.Server (bindListeners)
import Petrus.Viewer.Url (decodeURIComponent, parseUrl, resolveUrl, serializeUrl)
import System.Directory (doesPathExist)
import System.Posix.IO qualified as PIO
import System.Posix.Files qualified as PF
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
import System.Environment (getArgs, getEnvironment)
import System.Exit (die)
import System.FilePath (takeDirectory, (</>))
import System.IO (Handle, IOMode (..), hClose, hFlush, hGetLine, hSetBinaryMode, stdout, withFile)
import System.Process qualified as P
import System.Timeout (timeout)
import Text.Read (readMaybe)

main :: IO ()
main =
  getArgs >>= \case
    ("relay" : opts) -> relayBench (options opts)
    ("fanout" : opts) -> fanoutBench (options opts)
    ("http" : opts) -> httpBench (options opts)
    ("mcp" : opts) -> mcpBench (options opts)
    ("startup" : opts) -> startupBench (options opts)
    ("backend" : opts) -> backendServer (options opts)
    ("micro" : opts) -> microBench (options opts)
    _ -> die "usage: petrus-viewer-bench relay|fanout|http|mcp|startup|backend|micro ..."

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
        , ("opsPerSec", num (rate (fromIntegral ops / elapsed)))
        , ("p50us", us (pct 0.5))
        , ("p99us", us (pct 0.99))
        ]
          ++ extra
      )
  where
    -- whole ops/s, or two decimals below 100 (process starts)
    rate :: Double -> Double
    rate x
      | x < 100 = fromIntegral (round (x * 100) :: Int) / 100
      | otherwise = fromIntegral (round x :: Int)

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

-- | A fake browser: answer every petrus-agent request with 'resultPayload',
-- targeted back at the client that sent it.
answerRequests :: Client -> IO ()
answerRequests browser = forever $ do
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
        withAsync (answerRequests browser) $ \_ -> withClient p "/ws/agent" $ \agent -> do
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
-- get: one op = GET @--target@ (static files, the @/temporal@ proxy); the
-- report adds the body size, so runs against different servers can be
-- checked for the same work.
--
-- Each client is one keep-alive connection driven by 'Conn': the request
-- is a fixed byte string and the response is read by its Content-Length
-- (or its chunks). A general client (http-client) costs more per request
-- than these servers do, and with 16 clients it, not the server, set the
-- pace.
httpBench :: Opts -> IO ()
httpBench o = do
  p <- port o
  let endpoint = optS o "endpoint" "resolve-ref"
      file = optS o "file" ""
      target = BC.pack (optS o "target" "/")
      concurrency = opt o "concurrency" (16 :: Int)
      requests = opt o "requests" (20000 :: Int)
      hostHeader = BC.pack (bracketHost (fst p) <> ":" <> show (snd p))
  when (null file && endpoint /= "get") (die "--file is required")
  statuses <- newIORef ([] :: [Int])
  bodyBytes <- newIORef (0 :: Int)
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
      status c request = fst <$> exchange c request
      op :: Conn -> IO ([Int], Double)
      op c = case endpoint of
        "get" -> do
          ((s, n), t) <- timed (exchange c (get target))
          writeIORef bodyBytes n
          pure ([s], t)
        "open-file-get" -> (\(s, t) -> ([s], t)) <$> timed (status c openFileGet)
        "open-file" -> do
          (s1, t1) <- timed (status c openFilePost)
          when lockstep (awaitBarrier barrier)
          (s2, t2) <- timed (status c openFileGet)
          when lockstep (awaitBarrier barrier)
          pure ([s1, s2], t1 + t2)
        _ -> (\(s, t) -> ([s], t)) <$> timed (status c resolvePost)
      perWorker = requests `div` concurrency
      worker record c = replicateM perWorker $ do
        (ss, t) <- op c
        when record (atomicModifyIORef' statuses (\acc -> (ss ++ acc, ())))
        pure t
  bracket (replicateM concurrency (openConn p)) (mapM_ closeConn) $ \conns -> do
    -- warm up (JIT, connections)
    mapConcurrently_ (worker False) conns
    warmReopened <- sum <$> mapM reconnects conns
    t0 <- getMonotonicTime
    lats <- concat <$> forConcurrently conns (worker True)
    t1 <- getMonotonicTime
    ss <- readIORef statuses
    size <- readIORef bodyBytes
    reopened <- subtract warmReopened . sum <$> mapM reconnects conns
    let countOf s = length (filter (== s) ss)
    report
      (T.pack endpoint)
      ( [ ("concurrency", int concurrency)
        , ("status200", int (countOf 200))
        , ("status204", int (countOf 204))
        , ("statusOther", int (length ss - countOf 200 - countOf 204))
        ]
          ++ [("bodyBytes", int size) | endpoint == "get"]
          ++ [("reconnects", int reopened) | reopened > 0]
      )
      (t1 - t0)
      (perWorker * concurrency)
      lats
  where
    takeFileNameOf = reverse . takeWhile (/= '/') . reverse

-- | One keep-alive HTTP/1.1 client connection: where it goes, the current
-- socket, the bytes read past the last response, and how many times the
-- server closed it after a response (@Connection: close@; Vite's proxy
-- does, and the client then reconnects, as a browser would).
data Conn = Conn (String, Int) (IORef S.Socket) (IORef B.ByteString) (IORef Int)

openConn :: (String, Int) -> IO Conn
openConn to = do
  s <- connectTo to
  Conn to <$> newIORef s <*> newIORef "" <*> newIORef 0

connectTo :: (String, Int) -> IO S.Socket
connectTo (host, p) = do
  addr <- S.getAddrInfo (Just S.defaultHints {S.addrSocketType = S.Stream}) (Just host) (Just (show p)) >>= \case
    a : _ -> pure a
    [] -> die ("cannot resolve " <> host)
  s <- S.socket (S.addrFamily addr) S.Stream S.defaultProtocol
  S.setSocketOption s S.NoDelay 1
  S.connect s (S.addrAddress addr)
  pure s

closeConn :: Conn -> IO ()
closeConn (Conn _ sock _ _) = readIORef sock >>= S.close

reconnects :: Conn -> IO Int
reconnects (Conn _ _ _ n) = readIORef n

-- | Send one request and read its response; the status code and the body
-- size. The body is framed by Content-Length or chunked transfer coding
-- (without trailers); a 204 or 304 has none. After a @Connection: close@
-- response the connection is reopened (in the time of this exchange).
exchange :: Conn -> B.ByteString -> IO (Int, Int)
exchange (Conn to sock pending closes) request = do
  s <- readIORef sock
  SB.sendAll s request
  headBytes <- readUntil "\r\n\r\n"
  let status = maybe 0 fst (BC.readInt (B.take 3 (B.drop 9 headBytes)))
      valueOf name =
        [ BC.strip (BC.drop 1 v)
        | line <- drop 1 (BC.lines headBytes)
        , let (k, v) = BC.break (== ':') line
        , BC.map toLower k == name
        ]
      chunked = any ((== "chunked") . BC.map toLower) (valueOf "transfer-encoding")
      closing = any ((== "close") . BC.map toLower) (valueOf "connection")
  result <-
    if chunked
      then (status,) <$> chunks 0
      else case valueOf "content-length" of
        v : _ | Just (n, _) <- BC.readInt v -> (status, n) <$ skip n
        _ | status == 204 || status == 304 -> pure (status, 0)
        _ -> die ("response without Content-Length: " <> show headBytes)
  when closing $ do
    -- wait for the server's end of the stream before closing, so the
    -- server closes first and keeps the TIME_WAIT state: closing first
    -- here would hold an ephemeral port for each request, and a few runs
    -- exhaust them
    let drain = SB.recv s 65536 >>= \chunk -> unless (B.null chunk) drain
    drain
    S.close s
    connectTo to >>= writeIORef sock
    writeIORef pending ""
    modifyIORef' closes (+ 1)
  pure result
  where
    more = do
      s <- readIORef sock
      chunk <- SB.recv s 65536
      when (B.null chunk) (die "the server closed the connection")
      pure chunk
    -- the bytes before the separator (consumed with it)
    readUntil sep = do
      b <- readIORef pending
      let (h, rest) = B.breakSubstring sep b
      if B.null rest
        then more >>= \c -> writeIORef pending (b <> c) >> readUntil sep
        else h <$ writeIORef pending (B.drop (B.length sep) rest)
    -- discard n bytes without accumulating them
    skip n = do
      b <- readIORef pending
      if B.length b >= n
        then writeIORef pending (B.drop n b)
        else more >>= writeIORef pending >> skip (n - B.length b)
    chunks acc = do
      line <- readUntil "\r\n"
      case readHex (BC.unpack (BC.takeWhile (/= ';') line)) of
        [(0 :: Int, _)] -> acc <$ readUntil "\r\n"
        [(n, _)] -> skip (n + 2) >> chunks (acc + n)
        _ -> die ("bad chunk size: " <> show line)

-- | A host for a URL or a Host header (IPv6 literals in brackets).
bracketHost :: String -> String
bracketHost h = if ':' `elem` h then "[" <> h <> "]" else h

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

-- Processes -----------------------------------------------------------------

-- | @--cmd@: a JSON array of strings, the program and its arguments.
command :: Opts -> IO (FilePath, [String])
command o = case parseJs (BC.pack (optS o "cmd" "")) of
  Right (JsArr (x : xs)) | Just prog <- asText x, Just args <- mapM asText xs -> pure (T.unpack prog, map T.unpack args)
  _ -> die "--cmd must be a JSON array of strings"

withDevNull :: (Handle -> IO a) -> IO a
withDevNull = withFile "/dev/null" ReadWriteMode

-- MCP tools/call round trip ---------------------------------------------------

-- | One MCP server process (@--cmd@, started in @--cwd@) bridged to the
-- agent relay at @--port@, where a fake browser answers every request with
-- 'resultPayload'. After @initialize@ and a warm-up, @--concurrency@
-- workers each send their share of @--calls@ @tools/call@ requests for
-- @--tool@ with @--args@, one at a time, over the process's stdin; one op
-- = one call, from writing the request line to reading its response line.
-- A response with a result that is not @isError@ counts as status 200,
-- anything else as another status, so runs can be checked for the same
-- work.
mcpBench :: Opts -> IO ()
mcpBench o = do
  p@(host, relayPort) <- port o
  (prog, args) <- command o
  let dir = optS o "cwd" "."
      tool = T.pack (optS o "tool" "petrus_status")
      toolArgs = either (const (obj [])) id (parseJs (BC.pack (optS o "args" "{}")))
      calls = opt o "calls" (2000 :: Int)
      concurrency = opt o "concurrency" (1 :: Int)
      warm = max concurrency (calls `div` 10)
      agentUrl = "ws://" <> bracketHost host <> ":" <> show relayPort <> "/ws/agent"
      unset = ["PETRUS_AGENT_URL", "PETRUS_PERF", "PETRUS_MCP_REQUEST_TIMEOUT_MS", "PETRUS_HISTORY_URL"]
  env0 <- getEnvironment
  -- --env K=V adds one variable (e.g. PETRUS_PERF=0)
  let extra = [(k, drop 1 v) | Just kv <- [lookup "env" o], let (k, v) = break (== '=') kv]
      env = ("PETRUS_AGENT_URL", agentUrl) : extra ++ [kv | kv@(k, _) <- env0, k `notElem` unset]
  withClient p "/ws/agent" $ \browser -> do
    _ <- recvMatching "welcome" browser
    withAsync (answerRequests browser) $ \_ -> withDevNull $ \devnull -> do
      let spec = (P.proc prog args) {P.cwd = Just dir, P.env = Just env, P.std_in = P.CreatePipe, P.std_out = P.CreatePipe, P.std_err = P.UseHandle devnull}
      -- the body closes stdin; give the server 2 s to exit on its own
      let release (_, _, _, ph) = do
            exited <- timeout 2000000 (P.waitForProcess ph)
            when (exited == Nothing) (P.terminateProcess ph >> void (P.waitForProcess ph))
      bracket (P.createProcess spec) release $ \case
        (Just hin, Just hout, _, ph) -> do
          pid <- maybe (die "the MCP server exited at once") pure =<< P.getPid ph
          hSetBinaryMode hin True
          hSetBinaryMode hout True
          waiting <- newIORef (Map.empty :: Map.Map Int (MVar B.ByteString))
          nextId <- newIORef (0 :: Int)
          writeLock <- newMVar ()
          let reader = forever $ do
                line <- BC.hGetLine hout
                case parseJs line of
                  Right v | Just m <- asObject v, Just (JsNum n) <- lookupKey "id" m -> do
                    let i = round (jsNumberValue n)
                    mv <- atomicModifyIORef' waiting (\w -> (Map.delete i w, Map.lookup i w))
                    forM_ mv (`putMVar` line)
                  _ -> pure ()
              send line = withMVar writeLock $ \() -> B.hPut hin (line <> "\n") >> hFlush hin
              rpc method params = do
                i <- atomicModifyIORef' nextId (\n -> (n + 1, n + 1))
                mv <- newEmptyMVar
                atomicModifyIORef' waiting (\w -> (Map.insert i mv w, ()))
                send (encodeJs (obj [("jsonrpc", str "2.0"), ("id", int i), ("method", str method), ("params", params)]))
                takeMVar mv
              succeeded line = case parseJs line of
                Right v
                  | Just m <- asObject v
                  , Just result <- lookupKey "result" m >>= asObject ->
                      lookupKey "isError" result /= Just (JsBool True)
                _ -> False
              call = rpc "tools/call" (obj [("name", str tool), ("arguments", toolArgs)])
              worker n = replicateM n $ do
                t0 <- getMonotonicTime
                ok <- succeeded <$> call
                t1 <- getMonotonicTime
                pure (ok, t1 - t0)
          withAsync reader $ \_ -> do
            initialized <- timeout 60000000 $
              rpc "initialize" (obj [("protocolVersion", str "2024-11-05"), ("capabilities", obj []), ("clientInfo", obj [("name", str "petrus-viewer-bench"), ("version", str "1.0")])])
            when (initialized == Nothing) (die "the MCP server did not answer initialize")
            send (encodeJs (obj [("jsonrpc", str "2.0"), ("method", str "notifications/initialized")]))
            forConcurrently_ [1 .. concurrency] (const (void (worker (warm `div` concurrency))))
            let perWorker = calls `div` concurrency
            cpu0 <- cpuSeconds pid
            t0 <- getMonotonicTime
            results <- concat <$> forConcurrently [1 .. concurrency] (const (worker perWorker))
            t1 <- getMonotonicTime
            cpu1 <- cpuSeconds pid
            let oks = length (filter fst results)
                perOp x = num (fromIntegral (round (x / fromIntegral (length results) * 1e7) :: Int) / 10)
            report
              "mcp"
              [ ("tool", str tool)
              , ("concurrency", int concurrency)
              , ("status200", int oks)
              , ("status204", int 0)
              , ("statusOther", int (length results - oks))
              , ("serverUserUsPerOp", perOp (fst cpu1 - fst cpu0))
              , ("serverSysUsPerOp", perOp (snd cpu1 - snd cpu0))
              ]
              (t1 - t0)
              (length results)
              (map snd results)
          hClose hin
        _ -> die "could not start the MCP server"

-- | The CPU time a process has used so far, user and system, from ps(1)
-- (10 ms resolution).
cpuSeconds :: P.Pid -> IO (Double, Double)
cpuSeconds pid = do
  out <- P.readProcess "ps" ["-o", "utime=,stime=", "-p", show pid] ""
  case map seconds (T.words (T.pack out)) of
    [u, s] -> pure (u, s)
    _ -> die ("cannot read the CPU time of " <> show pid)
  where
    -- [[dd-]hh:]mm:ss.cc
    seconds t =
      foldl (\acc x -> acc * 60 + x) 0 (map (fromMaybe 0 . readMaybe . T.unpack . T.replace "-" "") (T.splitOn ":" t)) :: Double

-- Cold start ------------------------------------------------------------------

-- | Start the viewer command (@--cmd@ in @--cwd@, its own process group)
-- @--rounds@ times, after one start that is not counted. One op = one start:
-- from spawning the process until the URL it prints answers both
-- @GET /__petrus/open-file@ (the file named on the command line, 200) and
-- @GET /@ (the UI, 200), each on a new connection, retried until the
-- server accepts it. Then the whole group gets SIGTERM (SIGKILL after 10 s)
-- and the next start waits until the port is closed.
startupBench :: Opts -> IO ()
startupBench o = do
  (prog, args) <- command o
  let dir = optS o "cwd" "."
      rounds = opt o "rounds" (10 :: Int)
      one = withDevNull $ \devnull -> do
        let spec = (P.proc prog args) {P.cwd = Just dir, P.std_in = P.UseHandle devnull, P.std_out = P.CreatePipe, P.std_err = P.UseHandle devnull, P.create_group = True}
        t0 <- getMonotonicTime
        (_, mout, _, ph) <- P.createProcess spec
        pgid <- maybe (die "the process exited at once") pure =<< P.getPid ph
        portRef <- newIORef Nothing
        let measured = do
              hout <- maybe (die "no stdout") pure mout
              p <- serverPort hout
              writeIORef portRef (Just p)
              _ <- forkIO (void (try @IOException (forever (hGetLine hout))))
              s1 <- untilOk p "/__petrus/open-file"
              s2 <- untilOk p "/"
              t1 <- getMonotonicTime
              pure ([s1, s2], t1 - t0)
            stop = do
              signalGroup sigTERM pgid
              exited <- timeout 10000000 (P.waitForProcess ph)
              when (exited == Nothing) (signalGroup sigKILL pgid >> void (P.waitForProcess ph))
              readIORef portRef >>= mapM_ (\p -> do
                closed <- timeout 10000000 (untilClosed p)
                when (closed == Nothing) (signalGroup sigKILL pgid))
        r <- timeout 60000000 measured `finally` stop
        maybe (die "the server did not come up within 60 s") pure r
  void one
  results <- replicateM rounds one
  let ss = concatMap fst results
      countOf s = length (filter (== s) ss)
  report
    "startup"
    [ ("status200", int (countOf 200))
    , ("status204", int (countOf 204))
    , ("statusOther", int (length ss - countOf 200 - countOf 204))
    ]
    (sum (map snd results))
    rounds
    (map snd results)
  where
    signalGroup sig pgid = void (try @SomeException (signalProcessGroup sig (fromIntegral pgid)))
    -- the port of the first http://localhost:N URL the server prints
    serverPort h = do
      line <- T.replace "127.0.0.1" "localhost" . T.pack . stripAnsi <$> hGetLine h
      let (_, rest) = T.breakOn "http://localhost:" line
      case readMaybe (takeWhile isDigit (T.unpack (T.drop (T.length "http://localhost:") rest))) of
        Just p | not (T.null rest) -> pure (p :: Int)
        _ -> serverPort h
    stripAnsi = \case
      '\ESC' : '[' : rest -> stripAnsi (drop 1 (dropWhile (\c -> not (c >= '@' && c <= '~')) rest))
      c : rest -> c : stripAnsi rest
      [] -> []
    -- GET path on a new connection to whichever loopback address accepts it
    getOnce p path = do
      let attempt host = try @IOException $ bracket (openConn (host, p)) closeConn $ \c ->
            fst <$> exchange c ("GET " <> path <> " HTTP/1.1\r\nHost: localhost:" <> BC.pack (show p) <> "\r\nConnection: close\r\n\r\n")
      attempt "127.0.0.1" >>= \case
        Right s -> pure (Just s)
        Left _ -> either (const Nothing) Just <$> attempt "::1"
    -- retried while the server does not accept connections yet
    untilOk p path =
      getOnce p path >>= \case
        Just s -> pure s
        Nothing -> threadDelay 5000 >> untilOk p path
    untilClosed p = do
      open <- or <$> mapM (\host -> either (const False) (const True) <$> try @IOException (bracket (openConn (host, p)) closeConn (const (pure ())))) ["127.0.0.1", "::1"]
      when open (threadDelay 20000 >> untilClosed p)

-- Temporal stand-in -----------------------------------------------------------

-- | A stand-in for the Temporal HTTP API behind the viewers' @/temporal@
-- proxies (both proxy to @localhost:7243@): every request gets the same
-- 'resultPayload' JSON with Content-Length, from Warp on both loopback
-- addresses.
backendServer :: Opts -> IO ()
backendServer o = do
  let p = opt o "port" (7243 :: Int)
      body = encodeJsLazy resultPayload
      headers = [("Content-Type", "application/json"), ("Content-Length", BC.pack (show (BL.length body)))]
      app :: W.Application
      app _ respond = respond (W.responseLBS H.status200 headers body)
  (_, socks) <- bindListeners "localhost" p True
  BC.putStrLn ("listening on " <> BC.pack (show p))
  hFlush stdout
  mapConcurrently_ (\s -> Warp.runSettingsSocket Warp.defaultSettings s app) socks

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
  -- a timing log line as the relay and petrus-mcp write them, to /dev/null
  timeIt "isoTimestamp" $ \i -> (+ i) . B.length <$> isoTimestamp
  devNull <- PIO.openFd "/dev/null" PIO.WriteOnly PIO.defaultFileFlags
  devNullH <- PIO.fdToHandle =<< PIO.dup devNull
  lg <- newConsoleLogger 0 devNullH (fromIntegral devNull)
  timeIt "timing log line to /dev/null" $ \i -> do
    ts <- isoTimestamp
    logLine lg ("[petrus-perf] " <> ts <> " mcp-tool-start " <> encodeJs (obj [("tool", str "petrus_inspect_document"), ("action", str "document.inspect"), ("i", int i)]))
    pure i
  timeIt "resolveRef (file)" $ \_ -> do
    r <- resolveRef mgr ref base
    pure $ case r of
      Resolved _ -> 1
      ResolveError _ -> 2
      ResolveParseError _ -> 3
