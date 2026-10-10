-- | The viewer backend as one HTTP server: everything the browser UI and the
-- agents talk to, in the precedence the Vite dev server gives it.
--
-- * WebSocket upgrades: exactly @/ws/agent@ → the agent relay; any path
--   under @/collab-ws@ → the collaboration relay (the dev server proxies it
--   to @server/collab.mjs@; here it runs in process).
-- * @/__petrus/open-file@ and @/__petrus/resolve-ref@ (before anything
--   else, like @attachOpenFileEndpoint@).
-- * @/temporal…@ → the Petrus observation history source when configured
--   and the path is one it serves, else the Temporal HTTP API proxy.
-- * Everything else → the built UI.
module Petrus.Viewer.Server
  ( ServerConfig (..)
  , defaultServerConfig
  , ServerHandle (..)
  , withServer
  , runServer
  , viewerApp
  , collabApp
  , runCollabServer
  , bindListeners
  , wsOptions
  ) where

import Control.Concurrent.Async (forConcurrently_, withAsync)
import Control.Exception (IOException, bracket, bracketOnError, throwIO, try)
import Control.Concurrent (getNumCapabilities, threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Monad (forM, forever)
import Data.ByteString qualified as B
import Data.List (nub)
import Data.Text (Text)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types qualified as H
import Network.Socket qualified as S
import Network.Wai qualified as W
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS
import Petrus.Viewer.Endpoints
import Petrus.Viewer.History.Observation
import Petrus.Viewer.Log
import Petrus.Viewer.Proxy
import Petrus.Viewer.Relay
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
    }

data ServerHandle = ServerHandle
  { handlePort :: Int
  , handleAgentRelay :: Relay
  , handleCollabRelay :: Relay
  , handleOpenFile :: OpenFileState
  }

-- | The @ws@ defaults: 100 MiB messages, no compression.
wsOptions :: WS.ConnectionOptions
wsOptions =
  WS.defaultConnectionOptions
    { WS.connectionFramePayloadSizeLimit = WS.SizeLimit (100 * 1024 * 1024)
    , WS.connectionMessageDataSizeLimit = WS.SizeLimit (100 * 1024 * 1024)
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

isWsUpgrade :: W.Request -> Bool
isWsUpgrade = WaiWS.isWebSocketsReq

-- | The full viewer backend.
viewerApp :: ServerConfig -> HC.Manager -> Relay -> Relay -> OpenFileState -> Maybe ObservationSources -> W.Application
viewerApp cfg mgr agent collab openState observation req respond
  | isWsUpgrade req =
      if url == "/ws/agent"
        then WaiWS.websocketsOr wsOptions (wsApp agent) notFound req respond
        else
          if "/collab-ws" `B.isPrefixOf` url
            then WaiWS.websocketsOr wsOptions (wsApp collab) notFound req respond
            else notFound req respond
  | otherwise = endpointsMiddleware openState mgr rest req respond
  where
    url = W.rawPathInfo req <> W.rawQueryString req
    rest r k
      | "/collab-ws" `B.isPrefixOf` W.rawPathInfo r = k (lbsResponse H.status426 [("Content-Type", "text/plain")] "Upgrade Required")
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
collabApp :: Relay -> W.Application
collabApp relay =
  WaiWS.websocketsOr wsOptions (wsApp relay) $ \_ k ->
    k (lbsResponse H.status426 [("Content-Type", "text/plain")] "Upgrade Required")

warpSettings :: Warp.Settings
warpSettings =
  Warp.setOnException (\_ _ -> pure ()) $
    Warp.setServerName "" Warp.defaultSettings

-- | Accept on every listening socket from every capability. A connection's
-- thread starts on the capability that accepted it and stays there (the
-- executables run with @-qm@, no thread migration), so connections spread
-- over the capabilities without a request ever hopping between them.
acceptEverywhere :: (S.Socket -> IO ()) -> [S.Socket] -> IO ()
acceptEverywhere serve socks = do
  caps <- getNumCapabilities
  forConcurrently_ [(c, s) | c <- [0 .. caps - 1], s <- socks] $ \(c, s) ->
    Async.withAsyncOn c (serve s) Async.wait

-- | Start the server, run the action with it, stop it afterwards.
withServer :: ServerConfig -> (ServerHandle -> IO a) -> IO a
withServer cfg action = do
  mgr <- newFetchManager
  logger <- if serverRelayPerf cfg then Just <$> newAsyncLogger 0 stdout else pure Nothing
  agent <- newRelay AgentRelay logger
  collab <- newRelay CollabRelay Nothing
  openState <- newOpenFileState (serverOpenFile cfg) (serverSourceUrl cfg)
  observation <- case serverObservation cfg of
    [] -> pure Nothing
    urls -> Just <$> newObservationSources (nub urls)
  bracket (bindListeners (serverHost cfg) (serverPort cfg) (serverStrictPort cfg)) (mapM_ S.close . snd) $ \(port, socks) -> do
    let app = viewerApp cfg mgr agent collab openState observation
        serve s = Warp.runSettingsSocket (Warp.setPort port warpSettings) s app
    withAsync (acceptEverywhere serve socks) $ \_ ->
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
  relay <- newRelay CollabRelay Nothing
  bracket (bindListeners "::" port True) (mapM_ S.close . snd) $ \(_, socks) -> do
    hSetBuffering stdout LineBuffering
    putStrLn ("Collab relay listening on ws://localhost:" <> show port)
    acceptEverywhere (\s -> Warp.runSettingsSocket warpSettings s (collabApp relay)) socks
