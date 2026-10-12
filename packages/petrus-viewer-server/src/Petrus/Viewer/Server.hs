{-# LANGUAGE MultiWayIf #-}

-- | The viewer backend as one HTTP server: everything the browser UI and the
-- agents talk to, in the precedence the Vite dev server gives it.
--
-- * WebSocket upgrades: exactly @/ws/agent@ → the agent relay; any path
--   under @/collab-ws@ → the collaboration relay, when collaboration is on
--   ('serverCollab'; the dev server proxies it to @server/collab.mjs@ only
--   when Vite runs with @--host@; here it runs in process).
-- * @/__petrus/open-file@ and @/__petrus/resolve-ref@ (before anything
--   else, like @attachOpenFileEndpoint@).
-- * @/temporal…@ → the Petrus observation history source when configured
--   and the path is one it serves, else the Temporal HTTP API proxy.
-- * Everything else → the built UI.
--
-- Connections arrive at the HTTP front ("Petrus.Viewer.HttpFront"), one
-- event loop that answers the two endpoints itself with Node's framing (no
-- thread wake-up or I/O manager registration per request). A connection
-- that sends anything else, or a request the front does not parse
-- conservatively, is handed to Warp together with the bytes already read,
-- and stays with Warp from then on.
module Petrus.Viewer.Server
  ( ServerConfig (..)
  , defaultServerConfig
  , ServerHandle (..)
  , withServer
  , runServer
  , viewerApp
  , collabApp
  , Sockets
  , newSockets
  , runCollabServer
  , bindListeners
  ) where

import Control.Concurrent.Async (mapConcurrently_, withAsync)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Exception (IOException, bracket, bracketOnError, throwIO, try)
import Control.Concurrent (forkOnWithUnmask, getNumCapabilities, threadDelay)
import Control.Monad (forM, forever, void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.List (nub)
import Data.Maybe (isJust)
import Data.Text (Text)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types qualified as H
import Network.Socket qualified as S
import Network.Wai qualified as W
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.Warp.Internal qualified as WarpI
import Data.CaseInsensitive qualified as CI
import Petrus.Viewer.Endpoints
import Petrus.Viewer.History.Observation
import Petrus.Viewer.HttpFront
import Petrus.Viewer.Log
import Petrus.Viewer.Proxy
import Petrus.Viewer.Relay
import Petrus.Viewer.Relay.Handshake (upgradeResponse)
import Petrus.Viewer.Static
import Petrus.Viewer.Http (lbsResponse)
import Petrus.Viewer.UrlCache (newFetchManager)
import System.IO (BufferMode (..), hSetBuffering, stdout)
import System.IO.Error (isAlreadyInUseError)

data ServerConfig = ServerConfig
  { serverHost :: String
  -- ^ @localhost@ (both loopback families, like Vite) or an address/name
  , serverPort :: Int
  , serverStrictPort :: Bool
  -- ^ fail instead of moving to the next free port
  , serverUiDir :: Maybe FilePath
  , serverTemporalTarget :: String
  , serverObservation :: [Text]
  , serverOpenFile :: Maybe FilePath
  , serverSourceUrl :: Maybe Text
  , serverRelayPerf :: Bool
  , serverCollab :: Bool
  -- ^ serve the collaboration relay at @/collab-ws@. Vite proxies it only
  -- when it runs with @--host@, which @bin/petrus.mjs@ never passes; off,
  -- an upgrade there is refused.
  }

defaultServerConfig :: ServerConfig
defaultServerConfig =
  ServerConfig
    { serverHost = "localhost"
    , serverPort = 5173
    , serverStrictPort = False
    , serverUiDir = Nothing
    , serverTemporalTarget = "http://localhost:7243"
    , serverObservation = []
    , serverOpenFile = Nothing
    , serverSourceUrl = Nothing
    , serverRelayPerf = True
    , serverCollab = False
    }

data ServerHandle = ServerHandle
  { handlePort :: Int
  , handleAgentRelay :: Relay
  , handleCollabRelay :: Maybe Relay
  -- ^ when 'serverCollab' is on
  , handleOpenFile :: OpenFileState
  }

-- | Bind the listening sockets: every address of the host on the first
-- free port from the requested one (Vite moves on when a port is taken).
bindListeners :: String -> Int -> Bool -> IO (Int, [S.Socket])
bindListeners host port0 strict
  | port0 == 0 = ephemeral (10 :: Int)
  | otherwise = go port0
  where
    go port = do
      addrs <- resolve port
      r <- tryBindAll addrs
      case r of
        Right socks@(_ : _) -> pure (port, socks)
        Right [] -> ioError (userError ("could not bind " <> host <> ":" <> show port))
        Left e
          | isAlreadyInUseError e && not strict && port < 65535 -> go (port + 1)
          | otherwise -> throwIO e
    -- port 0: the first address picks a free port, the others follow it
    ephemeral attempts = do
      addrs <- resolve 0
      case addrs of
        [] -> ioError (userError ("could not resolve " <> host))
        (first : others) -> do
          s0 <- bindOne first
          port <- fromIntegral <$> S.socketPort s0
          rest <- resolve port
          let others' = [a | a <- rest, S.addrFamily a `elem` map S.addrFamily others]
          r <- tryBindAll others'
          case r of
            Right socks -> pure (port, s0 : socks)
            Left e
              | attempts > 0 && isAlreadyInUseError e -> S.close s0 >> ephemeral (attempts - 1)
              | otherwise -> S.close s0 >> throwIO e
    resolve port = do
      let hints = S.defaultHints {S.addrSocketType = S.Stream, S.addrFlags = [S.AI_PASSIVE, S.AI_NUMERICSERV]}
          names = if host == "localhost" then ["127.0.0.1", "::1"] else [host]
      infos <- concat <$> forM names (\n -> either (const []) id <$> try @IOException (S.getAddrInfo (Just hints) (Just n) (Just (show port))))
      pure (nubByAddr infos)
    nubByAddr infos = [a | (i, a) <- zip [0 :: Int ..] infos, S.addrAddress a `notElem` map S.addrAddress (take i infos)]
    -- all-or-nothing: a busy address releases the ones already bound
    tryBindAll addrs = do
      results <- forM addrs (\a -> try @IOException (bindOne a))
      let socks = [s | Right s <- results]
          errs = [e | Left e <- results]
      case filter isAlreadyInUseError errs of
        (e : _) -> mapM_ S.close socks >> pure (Left e)
        []
          | null socks, (e : _) <- errs -> pure (Left e)
          | otherwise -> pure (Right socks)
    bindOne a =
      bracketOnError (S.socket (S.addrFamily a) S.Stream S.defaultProtocol) S.close $ \s -> do
        S.setSocketOption s S.ReuseAddr 1
        case S.addrFamily a of
          -- "::" is dual stack (Node's default listen address)
          S.AF_INET6 -> S.setSocketOption s S.IPv6Only (if host == "::" then 0 else 1)
          _ -> pure ()
        S.bind s (S.addrAddress a)
        S.listen s 2048
        pure s

-- | Whether Node would emit @upgrade@ for the request rather than
-- @request@: an @Upgrade@ header and @upgrade@ among the @Connection@
-- tokens (whatever the protocol; the relay's handshake checks the rest).
isWsUpgrade :: W.Request -> Bool
isWsUpgrade req =
  any ((== "upgrade") . fst) hs
    && or [CI.mk (BC.strip t) == ("upgrade" :: CI.CI B.ByteString) | (k, v) <- hs, k == "connection", t <- BC.split ',' v]
  where
    hs = W.requestHeaders req

-- | The accepted sockets by peer address, so that a WebSocket upgrade can
-- hand its socket to a relay loop. Filled by the accept function of the
-- Warp settings ('newWarpSettings'), emptied by its close hook (which runs
-- while the socket is still open, so a peer address names one socket).
newtype Sockets = Sockets (IORef (Map.Map S.SockAddr S.Socket))

newSockets :: IO Sockets
newSockets = Sockets <$> newIORef Map.empty

-- | Serve a WebSocket upgrade with a relay: answer the handshake as @ws@
-- does (the 101, or the 400/405 that refuses it), then hand the socket
-- to the relay. The client may not send frames before it has the 101
-- (RFC 6455, 4.1), so Warp has buffered nothing past the request.
relayApp :: Sockets -> Relay -> W.Application
relayApp (Sockets ref) relay req respond = do
  sock <- Map.lookup (W.remoteHost req) <$> readIORef ref
  case sock of
    Just s ->
      respond $
        W.responseRaw
          ( \_ sink -> case upgradeResponse (W.requestMethod req) (W.requestHeaders req) of
              Left refusal -> sink refusal
              -- Warp's 30 s inactivity timeout would close the relayed
              -- socket (Warp sees no traffic once the relay owns it);
              -- ws, like the reference, keeps an upgraded socket open.
              Right accepted -> Warp.pauseTimeout req >> sink accepted >> relaySocket relay s
          )
          (lbsResponse H.status500 [("Content-Type", "text/plain")] "WebSocket relay: raw responses unsupported")
    Nothing -> respond (lbsResponse H.status500 [("Content-Type", "text/plain")] "WebSocket relay: unknown connection")

-- | The full viewer backend.
--
-- Without a collaboration relay, @/collab-ws@ is a path like any other:
-- an upgrade there gets @404@, as on any unknown WebSocket path.
viewerApp :: ServerConfig -> HC.Manager -> Sockets -> Relay -> Maybe Relay -> OpenFileState -> Maybe ObservationSources -> W.Application
viewerApp cfg mgr sockets agent collab openState observation req respond
  | isWsUpgrade req = case wsRelay of
      Just relay -> relayApp sockets relay req respond
      Nothing -> notFound req respond
  | otherwise = endpointsMiddleware openState mgr rest req respond
  where
    url = W.rawPathInfo req <> W.rawQueryString req
    collabPath = isJust collab && "/collab-ws" `B.isPrefixOf` url
    wsRelay
      | url == "/ws/agent" = Just agent
      | collabPath = collab
      | otherwise = Nothing
    rest r k
      | collabPath = k (lbsResponse H.status426 [("Content-Type", "text/plain")] "Upgrade Required")
      | "/temporal" `B.isPrefixOf` W.rawPathInfo r =
          case observation >>= \src -> observationApp src mgr "/temporal" r of
            Just handler -> handler >>= k
            Nothing -> proxyApp mgr (serverTemporalTarget cfg) "/temporal" r k
      | otherwise = case serverUiDir cfg of
          Just dir -> staticApp dir r k
          Nothing ->
            k
              ( lbsResponse
                  H.status404
                  [("Content-Type", "text/plain")]
                  "Petrus UI not configured: build the viewer (pnpm build) and pass --ui-dir or set PETRUS_UI_DIR."
              )
    notFound _ k = k (lbsResponse H.status404 [("Content-Type", "text/plain")] "Not Found")

-- | @server/collab.mjs@: a collaboration relay on every path; plain HTTP
-- requests get @426 Upgrade Required@.
collabApp :: Sockets -> Relay -> W.Application
collabApp sockets relay req k
  | isWsUpgrade req = relayApp sockets relay req k
  | otherwise = k (lbsResponse H.status426 [("Content-Type", "text/plain")] "Upgrade Required")

-- | Warp settings. Each connection's thread is pinned to a capability,
-- round robin: a request then runs start to finish on one capability (with
-- that capability's I/O manager), instead of being woken on whichever
-- capability is free, and connections still spread over all of them.
-- A connection is forgotten in 'Sockets' when Warp is done with it.
warpSettings :: Sockets -> IO Warp.Settings
warpSettings (Sockets ref) = do
  counter <- newIORef (0 :: Int)
  let spread :: ((forall a. IO a -> IO a) -> IO ()) -> IO ()
      spread io = do
        caps <- getNumCapabilities
        n <- atomicModifyIORef' counter (\c -> (c + 1, c))
        void (forkOnWithUnmask (n `mod` caps) io)
      forget addr = atomicModifyIORef' ref (\m -> (Map.delete addr m, ()))
  pure . Warp.setFork spread . Warp.setOnClose forget . Warp.setOnException (\_ _ -> pure ()) $
    Warp.setServerName "" Warp.defaultSettings

-- | 'warpSettings' for Warp's own accept loop: accepted sockets are
-- recorded in 'Sockets' until Warp is done with them.
newWarpSettings :: Sockets -> IO Warp.Settings
newWarpSettings sockets@(Sockets ref) = do
  let accept listener = do
        (s, addr) <- S.accept listener
        atomicModifyIORef' ref (\m -> (Map.insert addr s m, ()))
        pure (s, addr)
  Warp.setAccept accept <$> warpSettings sockets

-- | Warp serving the connections the HTTP front hands it: each arrives
-- with the bytes the front already read, which Warp reads first.
warpForHandOffs :: Sockets -> Warp.Settings -> Chan (S.Socket, S.SockAddr, B.ByteString) -> W.Application -> IO ()
warpForHandOffs (Sockets ref) settings handOffs =
  WarpI.runSettingsConnectionMaker settings $ do
    (sock, peer, buffered) <- readChan handOffs
    atomicModifyIORef' ref (\m -> (Map.insert peer sock m, ()))
    let connect = do
          conn <- WarpI.socketConnection settings sock
          pending <- newIORef buffered
          let recvFirst = do
                b <- atomicModifyIORef' pending (B.empty,)
                if B.null b then WarpI.connRecv conn else pure b
          pure conn {WarpI.connRecv = recvFirst}
    pure (connect, peer)

-- | What the HTTP front answers itself: the open-file and resolve-ref
-- requests that do not need the network.
frontConfig :: OpenFileState -> (S.Socket -> S.SockAddr -> B.ByteString -> IO ()) -> FrontConfig
frontConfig openState handOff =
  FrontConfig
    { frontClaims = \method target ->
        target == openFilePath || (target == resolveRefPath && (method == "POST" || method == "OPTIONS"))
    , frontHandle = \(Request method target body) ->
        if
          | target == openFilePath -> Respond <$> openFileReply openState method (pure body)
          | method == "OPTIONS" -> pure (Respond resolveRefOptions)
          | otherwise ->
              resolveRefStep body >>= \case
                ResolveDone r -> pure (Respond (resolveReply r))
                ResolveFetch _ -> pure PassToWarp
    , frontHandOff = handOff
    }

-- | Start the server, run the action with it, stop it afterwards.
withServer :: ServerConfig -> (ServerHandle -> IO a) -> IO a
withServer cfg action = do
  mgr <- newFetchManager
  -- a log writer thread, when one is needed, runs next to the collaboration
  -- relay, away from the agent relay's loop (capability 0)
  logger <- if serverRelayPerf cfg then Just <$> newStdoutLogger 1 else pure Nothing
  openState <- newOpenFileState (serverOpenFile cfg) (serverSourceUrl cfg)
  observation <- case serverObservation cfg of
    [] -> pure Nothing
    urls -> Just <$> newObservationSources (nub urls)
  sockets <- newSockets
  let withCollab k
        | serverCollab cfg = withRelay CollabRelay Nothing (k . Just)
        | otherwise = k Nothing
  withRelay AgentRelay logger $ \agent -> withCollab $ \collab ->
    bracket (bindListeners (serverHost cfg) (serverPort cfg) (serverStrictPort cfg)) (mapM_ S.close . snd) $ \(port, socks) -> do
      let app = viewerApp cfg mgr sockets agent collab openState observation
      settings <- Warp.setPort port <$> warpSettings sockets
      handOffs <- newChan
      withAsync (warpForHandOffs sockets settings handOffs app) $ \_ ->
        withFront socks (frontConfig openState (\s peer buffered -> writeChan handOffs (s, peer, buffered))) $
          action (ServerHandle port agent collab openState)

-- | Serve until interrupted; @onReady@ runs once the sockets listen.
runServer :: ServerConfig -> (Int -> IO ()) -> IO ()
runServer cfg onReady = withServer cfg $ \h -> do
  onReady (handlePort h)
  forever (threadDelay maxBound)

-- | @node server/collab.mjs [port]@: the standalone relay, listening on
-- every interface like @new WebSocketServer({ port })@.
runCollabServer :: Int -> IO ()
runCollabServer port = do
  sockets <- newSockets
  withRelay CollabRelay Nothing $ \relay ->
    bracket (bindListeners "::" port True) (mapM_ S.close . snd) $ \(_, socks) -> do
      hSetBuffering stdout LineBuffering
      putStrLn ("Collab relay listening on ws://localhost:" <> show port)
      settings <- newWarpSettings sockets
      mapConcurrently_ (\s -> Warp.runSettingsSocket settings s (collabApp sockets relay)) socks
