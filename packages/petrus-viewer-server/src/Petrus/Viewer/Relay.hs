-- | The two WebSocket relays of the viewer backend.
--
-- * The agent relay (@/ws/agent@, the @agentRelay@ Vite plugin) connects the
--   browser's @AgentProvider@ with MCP servers and other sidecars.
-- * The collaboration relay (@server/collab.mjs@, proxied at @/collab-ws@)
--   connects browsers editing the same net.
--
-- Both assign sequential string ids, greet with @welcome@, broadcast a count
-- on every join and leave, stamp each relayed object with the sender's id
-- (overwriting any spoofed value), deliver to one target when the target
-- field is truthy, and otherwise broadcast to everyone but the sender.
--
-- Routing is one STM transaction per event, so every client observes the
-- same total order of relay events, exactly like the single-threaded Node
-- event loop. Each client has its own outbound queue and writer thread, so
-- a slow receiver never blocks a sender (Node's @ws.send@ never blocks
-- either).
--
-- All threads of one relay run on one capability (@forkOn@). Relay work is
-- a chain of hand-offs between threads (reader, queue, writer); across
-- capabilities each hand-off wakes another OS thread, which costs more than
-- the work itself (on macOS, 16 relay pairs ran at half the round trips per
-- second spread over four capabilities than on one). HTTP requests still
-- use every capability. The agent relay uses capability 0 and the
-- collaboration relay capability 1 (modulo the capability count).
module Petrus.Viewer.Relay
  ( RelayKind (..)
  , Relay
  , newRelay
  , relayClientCount
  , serveConnection
  , wsApp
  , relayMessage
  , routeRaw
  , Routed (..)
  ) where

import Control.Concurrent.Async (wait, withAsyncOn)
import Control.Concurrent.STM
import Control.Exception (SomeException, finally, try)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Unsafe qualified as BU
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Network.WebSockets qualified as WS
import Petrus.Viewer.Json
import Petrus.Viewer.Json.Canonical (Member (..), canonicalObject)
import Petrus.Viewer.Log

data RelayKind
  = -- | @/ws/agent@: ids are @clientId@, counts are @client_count@, only
    -- JSON objects are relayed, petrus-agent timing is logged.
    AgentRelay
  | -- | @collab.mjs@: ids are @peerId@, counts are @peer_count@.
    CollabRelay
  deriving stock (Eq, Show)

data Client = Client
  { clientNumber :: Int
  , clientIdStr :: JsString
  , outbox :: TQueue Out
  }

data Out
  = Frame BL.ByteString
  | Shutdown
  | -- | written by a joining client's writer once its greeting is on the wire
    Signal (TMVar ())
  | -- | hold this client's later frames until the gate opens (bounded wait)
    Await (TMVar ())

data Relay = Relay
  { kind :: RelayKind
  , nextId :: TVar Int
  , clients :: TVar (Map Int Client)
  , timings :: IORef (Map JsString Double)
  , perfLogger :: Maybe Logger
  , capability :: Int
  -- ^ where all of this relay's threads run
  }

newRelay :: RelayKind -> Maybe Logger -> IO Relay
newRelay k lg =
  Relay k <$> newTVarIO 1 <*> newTVarIO Map.empty <*> newIORef Map.empty <*> pure lg
    <*> pure (case k of AgentRelay -> 0; CollabRelay -> 1)

relayClientCount :: Relay -> IO Int
relayClientCount r = Map.size <$> readTVarIO (clients r)

idKey, targetKey :: RelayKind -> JsString
idKey = \case
  AgentRelay -> jsString "clientId"
  CollabRelay -> jsString "peerId"
targetKey = \case
  AgentRelay -> jsString "targetClientId"
  CollabRelay -> jsString "targetPeerId"

countMessage :: RelayKind -> Int -> BL.ByteString
countMessage k n =
  encodeJsLazy (obj [("type", str (case k of AgentRelay -> "client_count"; CollabRelay -> "peer_count")), ("count", int n)])

idMessage :: RelayKind -> ByteString -> JsString -> BL.ByteString
idMessage k typ i = encodeJsLazy (JsObj (objectFromList [(jsString "type", JsStr (unsafeJsStringFromCanonical typ)), (idKey k, JsStr i)]))

-- | Accept a pending WebSocket like the @ws@ server does (echoing the first
-- requested subprotocol) and serve it.
wsApp :: Relay -> WS.ServerApp
wsApp relay pending = do
  let protos = WS.getRequestSubprotocols (WS.pendingRequest pending)
  conn <- WS.acceptRequestWith pending WS.defaultAcceptRequest {WS.acceptSubprotocol = listToMaybe protos}
  serveConnection relay conn

-- | Run one client connection until it closes.
serveConnection :: Relay -> WS.Connection -> IO ()
serveConnection relay conn = withAsyncOn (capability relay) (serveHere relay conn) wait

serveHere :: Relay -> WS.Connection -> IO ()
serveHere relay conn = do
  me <- atomically $ do
    n <- readTVar (nextId relay)
    writeTVar (nextId relay) (n + 1)
    q <- newTQueue
    gate <- newEmptyTMVar
    let c = Client n (jsString (showText n)) q
    modifyTVar' (clients relay) (Map.insert n c)
    -- Node writes the newcomer's welcome and count before the others' count
    -- in one event-loop turn; the gate keeps that order on the wire
    writeTQueue q (Frame (idMessage (kind relay) "welcome" (clientIdStr c)))
    cs <- readTVar (clients relay)
    let msg = countMessage (kind relay) (Map.size cs)
    forM_ cs $ \o ->
      if clientNumber o == n
        then writeTQueue (outbox o) (Frame msg) >> writeTQueue (outbox o) (Signal gate)
        else writeTQueue (outbox o) (Await gate) >> writeTQueue (outbox o) (Frame msg)
    pure c
  withAsyncOn (capability relay) (writer me) $ \_ ->
    receiveLoop me `finally` leave me
  where
    showText n = T.pack (show (n :: Int))

    broadcastCount = do
      cs <- readTVar (clients relay)
      let msg = countMessage (kind relay) (Map.size cs)
      forM_ cs $ \c -> writeTQueue (outbox c) (Frame msg)

    writer me = do
      let loop = do
            items <- atomically $ do
              x <- readTQueue (outbox me)
              rest <- flushTQueue (outbox me)
              pure (x : rest)
            continue <- process [] items
            when continue loop
          -- frames are batched into one write until a control item
          process acc = \case
            [] -> sendAll (reverse acc)
            Frame f : rest -> process (f : acc) rest
            Shutdown : _ -> False <$ sendAll (reverse acc)
            Signal g : rest -> do
              ok <- sendAll (reverse acc)
              atomically (void (tryPutTMVar g ()))
              if ok then process [] rest else pure False
            Await g : rest -> do
              ok <- sendAll (reverse acc)
              timeout <- registerDelay 250000
              atomically (readTMVar g `orElse` (readTVar timeout >>= check))
              if ok then process [] rest else pure False
          sendAll [] = pure True
          sendAll frames = do
            r <- try @SomeException (WS.sendDataMessages conn (map (\f -> WS.Text f Nothing) frames))
            pure (either (const False) (const True) r)
      loop

    receiveLoop me = do
      r <- try @SomeException (WS.receiveDataMessage conn)
      case r of
        Left _ -> pure ()
        Right dm -> do
          continue <- case dm of
            WS.Text bytes _ -> do
              let strict = BL.toStrict bytes
              if B.isValidUtf8 strict
                then handleRaw me strict >> pure True
                else do
                  -- ws closes with 1007 on malformed UTF-8 text frames
                  _ <- try @SomeException (WS.sendCloseCode conn 1007 ("Invalid WebSocket frame: invalid UTF-8 sequence" :: ByteString))
                  pure False
            WS.Binary bytes -> handleRaw me (decodeLenient (BL.toStrict bytes)) >> pure True
          when continue (receiveLoop me)

    handleRaw me raw = do
        now <- maybe (pure 0) (const monotonicMs) (perfLogger relay)
        case routeRaw (kind relay) (clientIdStr me) raw of
          Nothing -> pure ()
          Just routed -> do
            -- Vite logs before sending. Here the request/response timing is
            -- recorded first, but the line is written after the frame is
            -- queued, so that the frame's writer runs before the logger
            emit <- maybe (pure (pure ())) (\lg -> logTiming lg me now routed) (perfLogger relay)
            let frame = Frame (routedBytes routed)
            atomically $ do
              cs <- readTVar (clients relay)
              case routedTarget routed of
                Just target ->
                  case [c | c <- Map.elems cs, JsStr (clientIdStr c) == target] of
                    (c : _) -> writeTQueue (outbox c) frame
                    [] -> pure ()
                Nothing
                  | routedTargeted routed -> pure ()
                  | otherwise -> forM_ cs $ \c -> unless (clientNumber c == clientNumber me) (writeTQueue (outbox c) frame)
            emit

    leave me = atomically $ do
      modifyTVar' (clients relay) (Map.delete (clientNumber me))
      writeTQueue (outbox me) Shutdown
      cs <- readTVar (clients relay)
      let out = idMessage (kind relay) "leave" (clientIdStr me)
      forM_ cs $ \c -> writeTQueue (outbox c) (Frame out)
      broadcastCount

    logTiming lg me now routed = case look "protocol" of
      Just protocol
        | protocol == str "petrus-agent" -> do
            let kindV = look "kind"
                reqId = case look "requestId" of
                  Just (JsStr s) -> Just s
                  _ -> Nothing
            case (kindV, reqId) of
              (Just k, Just rid)
                | k == str "request" -> do
                    atomicModifyIORef' (timings relay) (\m -> (Map.insert rid now m, ()))
                    pure . perfLine lg "relay-forward-request" $
                      [("requestId", JsStr rid)] ++ opt "action" (look "action") ++ [("from", JsStr (clientIdStr me))]
                | k == str "response" -> do
                    start <- atomicModifyIORef' (timings relay) (\m -> (Map.delete rid m, Map.lookup rid m))
                    pure . forM_ start $ \s ->
                      perfLine lg "relay-forward-response" $
                        [("requestId", JsStr rid)]
                          ++ opt "action" (look "action")
                          ++ opt "ok" (look "ok")
                          ++ [("relayRoundtripMs", num (fixed1 (now - s))), ("from", JsStr (clientIdStr me))]
                          ++ opt "to" (look "targetClientId")
              _ -> pure (pure ())
      _ -> pure (pure ())
      where
        look = routedLookup routed . jsString
    opt k = maybe [] (\v -> [(k, v)])
    perfLine lg label fields = do
      ts <- isoTimestamp
      logLine lg ("[petrus-relay-perf] " <> ts <> " " <> label <> " " <> encodeJs (obj fields))

-- | The result of routing one parsed message.
data Routed = Routed
  { routedBytes :: BL.ByteString
  -- ^ what every recipient receives
  , routedTargeted :: Bool
  -- ^ the target field was truthy (deliver to at most one client)
  , routedTarget :: Maybe JsValue
  -- ^ the target value when it can match a client id (a string)
  , routedLookup :: JsString -> Maybe JsValue
  -- ^ a member of the relayed object (as relayed, id included)
  }

-- | Route one text message from the wire. Text already in
-- @JSON.stringify@ form (what every known client sends) is relayed by
-- splicing the id member into its bytes, without building the value
-- ("Petrus.Viewer.Json.Canonical"); any other text takes the full
-- @JSON.parse@ / @JSON.stringify@ round trip of 'relayMessage'. Both give
-- the same result (a property test checks it).
routeRaw :: RelayKind -> JsString -> ByteString -> Maybe Routed
routeRaw k sender raw = case canonicalObject raw of
  Nothing -> either (const Nothing) (relayMessage k sender) (parseJs raw)
  Just members ->
    let idK = jsStringBytes (idKey k)
        idV = "\"" <> jsStringBytes sender <> "\""
        bytes = case [m | m <- members, memberKey m == idK] of
          -- an existing id keeps its position
          (m : _) -> B.concat [BU.unsafeTake (memberStart m) raw, idV, BU.unsafeDrop (memberEnd m) raw]
          []
            | null members -> B.concat ["{\"", idK, "\":", idV, "}"]
            | otherwise -> B.concat [BU.unsafeTake (B.length raw - 1) raw, ",\"", idK, "\":", idV, "}"]
        look key
          | jsStringBytes key == idK = Just (JsStr sender)
          | otherwise = case [m | m <- members, memberKey m == jsStringBytes key] of
              (m : _) -> either (const Nothing) Just (parseJs (BU.unsafeTake (memberEnd m - memberStart m) (BU.unsafeDrop (memberStart m) raw)))
              [] -> Nothing
        target = look (targetKey k)
        targeted = maybe False truthy target
     in Just
          Routed
            { routedBytes = BL.fromStrict bytes
            , routedTargeted = targeted
            , routedTarget = if targeted then target else Nothing
            , routedLookup = look
            }

-- | Pure routing decision for one message from the client with the given
-- id; 'Nothing' means the message is dropped.
relayMessage :: RelayKind -> JsString -> JsValue -> Maybe Routed
relayMessage k sender = \case
  JsObj o ->
    let o' = insertKeyS (idKey k) (JsStr sender) o
        target = lookupKeyS (targetKey k) o'
        targeted = maybe False truthy target
     in Just
          Routed
            { routedBytes = encodeJsLazy (JsObj o')
            , routedTargeted = targeted
            , routedTarget = if targeted then target else Nothing
            , routedLookup = \key -> lookupKeyS key o'
            }
  JsArr xs
    | k == CollabRelay ->
        -- assigning a property to an array is invisible to JSON.stringify
        Just (Routed (encodeJsLazy (JsArr xs)) False Nothing (const Nothing))
  _ -> Nothing
