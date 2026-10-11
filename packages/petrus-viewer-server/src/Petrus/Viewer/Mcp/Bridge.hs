-- | The MCP server's connection to the agent relay (the "bridge").
--
-- Mirrors @server/mcp.mjs@: candidate URLs are tried in order
-- (@PETRUS_AGENT_URL@, else @ws://localhost:5173/ws/agent@ then
-- @ws://127.0.0.1:5173/ws/agent@); a connection counts once the relay's
-- @welcome@ arrives; when no bridge answers, the viewer server is started
-- once in the background and the URLs are retried every 500 ms until
-- @PETRUS_MCP_BRIDGE_WAIT_MS@ elapses. Requests are petrus-agent envelopes
-- with ids @mcp-N@ (@ping-N@ for the status probe), answered by matching
-- responses or failed after @PETRUS_MCP_REQUEST_TIMEOUT_MS@.
module Petrus.Viewer.Mcp.Bridge
  ( BridgeConfig (..)
  , bridgeConfigFromEnv
  , Bridge
  , newBridge
  , ensureBridge
  , sendBridgeRequest
  , BridgeStatus (..)
  , bridgeStatus
  , hasBrowserUI
  , bridgeUnavailableMessage
  , timedOutMessage
  , uiInitHint
  , PerfLog
  , perfLog
  , mkPerfLog
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (SomeException, catch, try)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Network.WebSockets qualified as WS
import Petrus.Viewer.Json
import Petrus.Viewer.Log
import Petrus.Viewer.Mcp.Reactor (Reactor, withSocketStream)
import Petrus.Viewer.UiDir (locateUiDir)
import Petrus.Viewer.WsUrl
import System.Directory (doesFileExist, findExecutable)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO (stderr)
import System.Process qualified as P
import Text.Read (readMaybe)

data BridgeConfig = BridgeConfig
  { agentUrls :: [Text]
  , requestTimeoutMs :: Int
  , bridgeWaitMs :: Int
  , retryIntervalMs :: Int
  , autoStart :: Maybe (FilePath, [String])
  -- ^ the command started (once, detached) when no bridge answers
  }

-- | @Number(process.env.X || default)@: unset or empty means the default; a
-- non-numeric value is @NaN@, which the Node timers treat as zero.
envMs :: String -> Int -> IO Int
envMs name def = do
  v <- lookupEnv name
  pure $ case v of
    Nothing -> def
    Just "" -> def
    Just s -> case readMaybe (trim s) :: Maybe Double of
      Just d | not (isNaN d || isInfinite d) -> max 0 (round d)
      _ -> 0
  where
    trim = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')

bridgeConfigFromEnv :: IO BridgeConfig
bridgeConfigFromEnv = do
  url <- lookupEnv "PETRUS_AGENT_URL"
  timeout <- envMs "PETRUS_MCP_REQUEST_TIMEOUT_MS" 5000
  wait <- envMs "PETRUS_MCP_BRIDGE_WAIT_MS" 3000
  cmd <- autoStartCommand
  pure
    BridgeConfig
      { agentUrls = case url of
          Just u | not (null u) -> [T.pack u]
          _ -> ["ws://localhost:5173/ws/agent", "ws://127.0.0.1:5173/ws/agent"]
      , requestTimeoutMs = timeout
      , bridgeWaitMs = wait
      , retryIntervalMs = 500
      , autoStart = cmd
      }

-- | The Node server runs @pnpm run dev@ in the viewer checkout it belongs
-- to, whatever the working directory. Here the viewer server is the
-- @petrus@ executable: @PETRUS_MCP_DEV_COMMAND@ (run through @sh -c@) when
-- set, else @petrus --no-open@ found next to this executable or on @PATH@.
-- The UI it serves does not depend on the working directory either:
-- @PETRUS_UI_DIR@ when set (the server inherits it), else the build found
-- next to this executable or that @petrus@ ("Petrus.Viewer.UiDir"),
-- passed as @--ui-dir@.
autoStartCommand :: IO (Maybe (FilePath, [String]))
autoStartCommand = do
  custom <- lookupEnv "PETRUS_MCP_DEV_COMMAND"
  case custom of
    Just c | not (null c) -> pure (Just ("/bin/sh", ["-c", c]))
    _ -> do
      self <- getExecutablePath
      let sibling = takeDirectory self </> "petrus"
      here <- doesFileExist sibling
      found <- if here then pure (Just sibling) else findExecutable "petrus"
      uiEnv <- lookupEnv "PETRUS_UI_DIR"
      ui <- case uiEnv of
        Just d | not (null d) -> pure Nothing
        _ -> locateUiDir (takeDirectory self : maybe [] (pure . takeDirectory) found)
      pure (fmap (,["--no-open"] ++ maybe [] (\d -> ["--ui-dir", d]) ui) found)

newtype PerfLog = PerfLog (Maybe Logger)

mkPerfLog :: IO PerfLog
mkPerfLog = do
  v <- lookupEnv "PETRUS_PERF"
  if v == Just "0" then pure (PerfLog Nothing) else PerfLog . Just <$> newConsoleLogger 0 stderr 2

-- | @[petrus-perf] <ISO time> <label> <json>@ on stderr.
perfLog :: PerfLog -> ByteString -> [(Text, JsValue)] -> IO ()
perfLog (PerfLog lg) label fields = forM_ lg $ \l -> do
  ts <- isoTimestamp
  logLine l ("[petrus-perf] " <> ts <> " " <> label <> " " <> encodeJs (obj fields))

data Active = Active
  { activeUrl :: Text
  , activeConn :: WS.Connection
  , activeOpen :: TVar Bool
  , activeSendLock :: MVar ()
  }

-- | What a pending request resolves to: the result (absent when the
-- response carried none) or an error message.
type Outcome = Either Text (Maybe JsValue)

data Pending = Pending
  { pendingVar :: TMVar Outcome
  , pendingSent :: Double
  , pendingAction :: Text
  }

data Bridge = Bridge
  { config :: BridgeConfig
  , perf :: PerfLog
  , reactor :: Reactor
  -- ^ the event loop the bridge connections are read on
  , active :: TVar (Maybe Active)
  , clientId :: TVar JsValue
  , pending :: TVar (Map JsString Pending)
  , nextRequestId :: IORef Int
  , spawned :: IORef Bool
  , ensureLock :: MVar ()
  }

newBridge :: BridgeConfig -> PerfLog -> Reactor -> IO Bridge
newBridge cfg pl r =
  Bridge cfg pl r
    <$> newTVarIO Nothing
    <*> newTVarIO JsNull
    <*> newTVarIO Map.empty
    <*> newIORef 1
    <*> newIORef False
    <*> newMVar ()

uiInitHint :: Text
uiInitHint = "Petrus UI is likely not initialized. Start the dev server and open http://localhost:5173/ in a browser window."

bridgeUnavailableMessage :: BridgeConfig -> Text
bridgeUnavailableMessage cfg =
  "Agent not connected. Petrus bridge unavailable at " <> T.intercalate ", " (agentUrls cfg) <> ". " <> uiInitHint

timedOutMessage :: Text -> Text
timedOutMessage action = "Agent request " <> action <> " timed out. " <> uiInitHint

ms1 :: Double -> JsValue
ms1 = num . fixed1

-- | Connect to one URL; 'True' once the relay welcomed us.
connectBridgeAt :: Bridge -> Text -> IO Bool
connectBridgeAt b url = do
  start <- monotonicMs
  result <- newEmptyMVar
  let finish ok = do
        first <- tryPutMVar result ok
        when first $ do
          now <- monotonicMs
          perfLog (perf b) "ws-connect" [("url", str url), ("connected", JsBool ok), ("ms", ms1 (now - start))]
  case parseWsUrl url of
    Left _ -> finish False
    Right target -> void . forkIO $ do
      r <- try @SomeException . runWsClient (withSocketStream (reactor b)) target WS.defaultConnectionOptions $ \conn -> do
        openVar <- newTVarIO True
        lock <- newMVar ()
        let me = Active url conn openVar lock
            loop = do
              m <- WS.receiveData conn
              handleMessage me m
              loop
        loop `catch` \(_ :: SomeException) -> pure ()
        atomically (writeTVar openVar False)
        wasActive <- atomically $ do
          cur <- readTVar (active b)
          case cur of
            Just a | activeOpen a == openVar -> do
              writeTVar (active b) Nothing
              writeTVar (clientId b) JsNull
              pure True
            _ -> pure False
        when wasActive $ perfLog (perf b) "ws-disconnected" [("url", str url)]
      either (const (finish False)) (const (finish False)) r
      where
        handleMessage me raw = case parseJs (decodeLenient (BL.toStrict raw)) of
          Left _ -> pure ()
          Right (JsObj m) -> do
            let typ = lookupKey "type" m
            if typ == Just (str "welcome")
              then do
                atomically $ do
                  writeTVar (active b) (Just me)
                  writeTVar (clientId b) (fromMaybe JsNull (lookupKey "clientId" m))
                finish True
              else
                unless (typ == Just (str "client_count") || typ == Just (str "leave")) $
                  when (lookupKey "protocol" m == Just (str "petrus-agent") && lookupKey "kind" m == Just (str "response")) $
                    case lookupKey "requestId" m of
                      Just (JsStr rid) -> do
                        p <- atomically $ do
                          ps <- readTVar (pending b)
                          case Map.lookup rid ps of
                            Nothing -> pure Nothing
                            Just p -> do
                              writeTVar (pending b) (Map.delete rid ps)
                              pure (Just p)
                        forM_ p $ \pd -> do
                          now <- monotonicMs
                          let ok = maybe False truthy (lookupKey "ok" m)
                          perfLog
                            (perf b)
                            "bridge-response"
                            ( [("requestId", JsStr rid), ("action", str (pendingAction pd))]
                                ++ maybe [] (\v -> [("ok", v)]) (lookupKey "ok" m)
                                ++ [("roundtripMs", ms1 (now - pendingSent pd))]
                            )
                          atomically . void . tryPutTMVar (pendingVar pd) $
                            if ok
                              then Right (lookupKey "result" m)
                              else Left (errorText (lookupKey "error" m))
                      _ -> pure ()
          Right _ -> pure ()
  readMVar result
  where
    errorText = \case
      Just (JsObj e) | Just msg <- lookupKey "message" e, truthy msg -> jsToString msg
      _ -> "Agent error"

connectBridgeOnce :: Bridge -> IO Bool
connectBridgeOnce b = go (agentUrls (config b))
  where
    go [] = pure False
    go (u : us) = do
      ok <- connectBridgeAt b u
      if ok then pure True else go us

-- | @ensureBridge@: connect, or start the viewer server and keep retrying.
ensureBridge :: Bridge -> IO (Either Text ())
ensureBridge b = withMVar (ensureLock b) $ \_ -> do
  ok <- connectBridgeOnce b
  if ok
    then pure (Right ())
    else do
      first <- atomicModifyIORef' (spawned b) (True,)
      unless first $ forM_ (autoStart (config b)) spawnDetached
      start <- monotonicMs
      let deadline = start + fromIntegral (bridgeWaitMs (config b))
          loop = do
            now <- monotonicMs
            if now >= deadline
              then pure (Left (bridgeUnavailableMessage (config b)))
              else do
                threadDelay (retryIntervalMs (config b) * 1000)
                again <- connectBridgeOnce b
                if again then pure (Right ()) else loop
      loop
  where
    spawnDetached (cmd, args) = do
      r <-
        try @SomeException $
          P.createProcess
            (P.proc cmd args)
              { P.std_in = P.NoStream
              , P.std_out = P.NoStream
              , P.std_err = P.NoStream
              , P.new_session = True
              }
      either (const (pure ())) (const (pure ())) r

currentActive :: Bridge -> IO (Maybe Active)
currentActive b = atomically $ do
  cur <- readTVar (active b)
  case cur of
    Just a -> do
      open <- readTVar (activeOpen a)
      pure (if open then Just a else Nothing)
    Nothing -> pure Nothing

-- | The request envelope exactly as @server/mcp.mjs@ writes it. The action
-- is free text: the browser also answers @canvas.screenshot@, which is not
-- part of the validated protocol vocabulary.
requestEnvelope :: JsString -> Text -> JsObject -> JsValue
requestEnvelope rid action params =
  obj
    [ ("protocol", str "petrus-agent")
    , ("version", int 1)
    , ("kind", str "request")
    , ("requestId", JsStr rid)
    , ("action", str action)
    , ("params", JsObj params)
    ]

sendOn :: Active -> JsValue -> IO ()
sendOn a v = withMVar (activeSendLock a) $ \_ ->
  WS.sendTextData (activeConn a) (encodeJsLazy v) `catch` \(_ :: SomeException) -> pure ()

register :: Bridge -> Text -> Text -> IO (JsString, TMVar Outcome)
register b prefix action = do
  n <- atomicModifyIORef' (nextRequestId b) (\i -> (i + 1, i))
  let rid = prefix <> "-" <> T.pack (show n)
  var <- newEmptyTMVarIO
  now <- monotonicMs
  atomically (modifyTVar' (pending b) (Map.insert (jsString rid) (Pending var now action)))
  pure (jsString rid, var)

-- | Wait for an outcome; 'Nothing' after the timeout (the request is then
-- forgotten, so a late response is ignored).
awaitOutcome :: Bridge -> JsString -> TMVar Outcome -> Int -> IO (Maybe Outcome)
awaitOutcome b rid var timeoutMs = do
  timer <- registerDelay (timeoutMs * 1000)
  atomically $
    (Just <$> takeTMVar var)
      `orElse` do
        fired <- readTVar timer
        unless fired retry
        modifyTVar' (pending b) (Map.delete rid)
        pure Nothing

-- | @sendBridgeRequest(action, params)@: the response's result, or the
-- error message the tool reports.
sendBridgeRequest :: Bridge -> Text -> JsObject -> IO (Either Text (Maybe JsValue))
sendBridgeRequest b actionText params = do
  cur <- currentActive b
  ready <- case cur of
    Just a -> pure (Right a)
    Nothing -> do
      perfLog (perf b) "bridge-reconnecting" [("action", str actionText), ("reason", str "ws not open")]
      r <- ensureBridge b
      case r of
        Left _ -> pure (Left (bridgeUnavailableMessage (config b)))
        Right () -> maybe (Left (bridgeUnavailableMessage (config b))) Right <$> currentActive b
  case ready of
    Left e -> pure (Left e)
    Right a -> do
      (rid, var) <- register b "mcp" actionText
      perfLog (perf b) "bridge-send" [("requestId", JsStr rid), ("action", str actionText)]
      start <- monotonicMs
      sendOn a (requestEnvelope rid actionText params)
      out <- awaitOutcome b rid var (requestTimeoutMs (config b))
      case out of
        Just o -> pure o
        Nothing -> do
          now <- monotonicMs
          perfLog (perf b) "bridge-timeout" [("requestId", JsStr rid), ("action", str actionText), ("ms", ms1 (now - start))]
          pure (Left (timedOutMessage actionText))

data BridgeStatus = BridgeStatus
  { statusConnected :: Bool
  , statusUrl :: Maybe Text
  , statusClientId :: JsValue
  }

bridgeStatus :: Bridge -> IO BridgeStatus
bridgeStatus b = do
  cur <- currentActive b
  cid <- readTVarIO (clientId b)
  pure (BridgeStatus (maybe False (const True) cur) (activeUrl <$> cur) cid)

-- | The status probe: a @document.inspect@ answered within 1.5 s.
hasBrowserUI :: Bridge -> IO Bool
hasBrowserUI b = do
  cur <- currentActive b
  case cur of
    Nothing -> pure False
    Just a -> do
      (rid, var) <- register b "ping" "document.inspect"
      sendOn a (requestEnvelope rid "document.inspect" emptyObject)
      out <- awaitOutcome b rid var 1500
      pure $ case out of
        Just (Right _) -> True
        _ -> False
