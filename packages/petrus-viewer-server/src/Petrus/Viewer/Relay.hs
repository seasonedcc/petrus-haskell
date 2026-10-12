{-# LANGUAGE MultiWayIf #-}

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
-- = How a relay runs
--
-- Like the Node relays, each relay is one event loop: a single thread that
-- owns every socket of the relay once the HTTP upgrade is done. The loop
-- waits for readiness on all of them at once ("Petrus.Viewer.EventLoop":
-- kqueue or epoll, the sockets stay registered), reads what is there, decodes the
-- WebSocket frames ("Petrus.Viewer.Relay.Frame", the checks and close codes
-- of the @ws@ library), routes each message, and appends the outgoing
-- frames to the receivers' output queues; at the end of each turn every
-- queue is written with one @writev@. A receiver whose socket buffer is
-- full keeps its queue (written when the socket drains), so a slow
-- receiver never blocks the others, as with @ws.send@.
--
-- One thread means the relay sees events in one total order, exactly like
-- Node's event loop: a newcomer's @welcome@ and count precede anyone
-- else's count, and every client sees joins, messages, and leaves in the
-- same order. It also means that serving a message costs one shared
-- readiness wait, one @recv@, and one @writev@ per receiver, with no
-- thread hand-offs; a thread per connection (the previous design) paid a
-- wake-up and a readiness registration with GHC's I/O manager for every
-- message (see bench/RESULTS.md).
--
-- The HTTP side stays with Warp: the upgrade request is answered with the
-- @ws@ library's handshake bytes ("Petrus.Viewer.Relay.Handshake", written
-- through 'Network.Wai.responseRaw'), then the connection's socket is
-- handed to the loop ('relaySocket') and Warp's thread waits until the
-- loop has closed it.
module Petrus.Viewer.Relay
  ( RelayKind (..)
  , Relay
  , withRelay
  , relayClientCount
  , relaySocket
  , relayMessage
  , routeRaw
  , Routed (..)
  ) where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.STM
import Control.Exception (SomeException, mask_, onException, try, uninterruptibleMask_)
import Control.Monad (forM_, unless, when)
import Data.Bits ((.|.), shiftL)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Unsafe qualified as BU
import Data.IORef
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Word (Word16, Word8)
import Foreign.C.Types (CInt)
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Network.Socket qualified as S
import Petrus.Viewer.EventLoop
import Petrus.Viewer.Json
import Petrus.Viewer.Json.Canonical (Member (..), canonicalObject)
import Petrus.Viewer.Log
import Petrus.Viewer.Relay.Frame

data RelayKind
  = -- | @/ws/agent@: ids are @clientId@, counts are @client_count@, only
    -- JSON objects are relayed, petrus-agent timing is logged.
    AgentRelay
  | -- | @collab.mjs@: ids are @peerId@, counts are @peer_count@.
    CollabRelay
  deriving stock (Eq, Show)

-- State ------------------------------------------------------------------------

-- | A connection handed to the loop by the thread that accepted it.
data Ticket = Ticket
  { ticketSocket :: S.Socket
  , ticketFd :: CInt
  , ticketDone :: TVar Bool
  -- ^ set by the loop once it has closed the socket
  }

data Command = Join Ticket | Detach Ticket

-- | Output waiting for a socket: a queue of byte strings (front, and the
-- back reversed).
data OutQueue = OutQueue [ByteString] [ByteString]

data Conn = Conn
  { connNumber :: Int
  , connId :: JsString
  , connTicket :: Ticket
  , connPending :: IORef [ByteString]
  -- ^ received bytes not yet decoded, newest first
  , connPendingSize :: IORef Int
  , connNeed :: IORef Int
  -- ^ bytes needed before decoding can make progress (0: unknown)
  , connFragments :: IORef (Maybe (Word8, [ByteString], Int))
  -- ^ a fragmented message in progress: opcode, payloads (newest first), size
  , connOut :: IORef OutQueue
  , connDirty :: IORef Bool
  , connWatchingWrite :: IORef Bool
  , connClosing :: IORef Bool
  -- ^ a close frame is queued: read nothing more, close once written
  }

data Relay = Relay
  { kind :: RelayKind
  , perfLogger :: Maybe Logger
  , loop :: EventLoop
  , commands :: IORef [Command]
  , clientCount :: IORef Int
  -- the rest is touched by the loop thread only
  , nextId :: IORef Int
  , conns :: IORef (IntMap Conn)
  -- ^ by client number (join order, the order Node's Map iterates in)
  , byFd :: IORef (IntMap Conn)
  , dirtyConns :: IORef [Conn]
  , timings :: IORef (Map JsString Double)
  , scratch :: ForeignPtr Word8
  }

scratchSize :: Int
scratchSize = 256 * 1024

-- | The @ws@ default @maxPayload@: 100 MiB per message.
messageLimit :: Int
messageLimit = 100 * 1024 * 1024

-- | Run a relay (its loop thread) for the duration of the action. On exit
-- every connection still open is closed.
withRelay :: RelayKind -> Maybe Logger -> (Relay -> IO a) -> IO a
withRelay k lg action = do
  caps <- getNumCapabilities
  let cap = (case k of AgentRelay -> 0; CollabRelay -> 1) `mod` caps
  withEventLoop "relay" cap newRelay turn shutdown action
  where
    newRelay l =
      Relay k lg l
        <$> newIORef []
        <*> newIORef 0
        <*> newIORef 1
        <*> newIORef IM.empty
        <*> newIORef IM.empty
        <*> newIORef []
        <*> newIORef Map.empty
        <*> mallocForeignPtrBytes scratchSize

-- | Close every connection (loop thread, on exit).
shutdown :: Relay -> IO ()
shutdown relay = do
  cs <- readIORef (conns relay)
  forM_ cs $ \c -> closeTicket relay (connTicket c)
  writeIORef (conns relay) IM.empty
  writeIORef (byFd relay) IM.empty
  writeIORef (clientCount relay) 0
  cmds <- atomicModifyIORef' (commands relay) (\xs -> ([], xs))
  forM_ cmds $ \case
    Join t -> closeTicket relay t
    Detach t -> closeTicket relay t

relayClientCount :: Relay -> IO Int
relayClientCount = readIORef . clientCount

submit :: Relay -> Command -> IO ()
submit relay cmd = do
  atomicModifyIORef' (commands relay) (\xs -> (cmd : xs, ()))
  wake (loop relay)

-- | Hand the socket of an upgraded connection (the @101@ response already
-- written) to the relay, and wait until the relay has closed it.
relaySocket :: Relay -> S.Socket -> IO ()
relaySocket relay sock = do
  fd <- S.unsafeFdSocket sock
  done <- newTVarIO False
  let ticket = Ticket sock fd done
      finished = (readTVar done >>= check) `orElse` awaitStopped (loop relay)
  mask_ $ do
    submit relay (Join ticket)
    atomically finished `onException` do
      -- the server is going away: the socket must leave the loop before
      -- Warp closes it (bounded, should the loop be gone)
      submit relay (Detach ticket)
      deadline <- registerDelay 2000000
      uninterruptibleMask_ (atomically (finished `orElse` (readTVar deadline >>= check)))

-- The loop ---------------------------------------------------------------------

-- | One turn of the loop: serve what is ready, then write every queue.
turn :: Relay -> IO ()
turn relay = do
  pollWait (loop relay) (-1) >>= mapM_ dispatch
  flushAll relay
  where
    dispatch = \case
      Woken -> do
        cmds <- atomicModifyIORef' (commands relay) (\xs -> ([], reverse xs))
        mapM_ (runCommand relay) cmds
      Ready fd isReadable isWritable -> do
        m <- IM.lookup (fromIntegral fd) <$> readIORef (byFd relay)
        forM_ m $ \c -> do
          r <- try @SomeException $ do
            when isWritable (flushConn relay c)
            when isReadable (readConn relay c)
          either (const (dropConn relay c)) pure r

runCommand :: Relay -> Command -> IO ()
runCommand relay = \case
  Join t -> do
    r <- watch (loop relay) (ticketFd t)
    if r < 0 then closeTicket relay t else join relay t
  Detach t -> do
    m <- IM.lookup (fromIntegral (ticketFd t)) <$> readIORef (byFd relay)
    case m of
      Just c | ticketDone (connTicket c) == ticketDone t -> dropConn relay c
      _ -> pure ()

join :: Relay -> Ticket -> IO ()
join relay t = do
  n <- readIORef (nextId relay)
  writeIORef (nextId relay) (n + 1)
  c <-
    Conn n (jsString (T.pack (show n))) t
      <$> newIORef []
      <*> newIORef 0
      <*> newIORef 0
      <*> newIORef Nothing
      <*> newIORef (OutQueue [] [])
      <*> newIORef False
      <*> newIORef False
      <*> newIORef False
  modifyIORef' (conns relay) (IM.insert n c)
  modifyIORef' (byFd relay) (IM.insert (fromIntegral (ticketFd t)) c)
  modifyIORef' (clientCount relay) (+ 1)
  -- ws.send(welcome), then the count to everyone (the newcomer included)
  sendText relay c (BL.toStrict (idMessage (kind relay) "welcome" (connId c)))
  broadcastCount relay

broadcastCount :: Relay -> IO ()
broadcastCount relay = do
  cs <- readIORef (conns relay)
  let msg = BL.toStrict (countMessage (kind relay) (IM.size cs))
      frame = encodeFrame opText msg
  forM_ cs $ \c -> enqueue relay c frame

-- | Close the socket of a connection that was never joined or is leaving,
-- and release the thread waiting for it.
closeTicket :: Relay -> Ticket -> IO ()
closeTicket relay t = do
  unwatch (loop relay) (ticketFd t)
  _ <- try @SomeException (S.close (ticketSocket t))
  atomically (writeTVar (ticketDone t) True)

-- | The connection is gone: forget it, tell the others (@ws@ 'close').
dropConn :: Relay -> Conn -> IO ()
dropConn relay c = do
  present <- IM.member (connNumber c) <$> readIORef (conns relay)
  when present $ do
    modifyIORef' (conns relay) (IM.delete (connNumber c))
    modifyIORef' (byFd relay) (IM.delete (fromIntegral (ticketFd (connTicket c))))
    modifyIORef' (clientCount relay) (subtract 1)
    writeIORef (connOut c) (OutQueue [] [])
    closeTicket relay (connTicket c)
    let out = encodeFrame opText (BL.toStrict (idMessage (kind relay) "leave" (connId c)))
    cs <- readIORef (conns relay)
    forM_ cs $ \o -> enqueue relay o out
    broadcastCount relay

-- Output -----------------------------------------------------------------------

enqueue :: Relay -> Conn -> [ByteString] -> IO ()
enqueue relay c chunks = do
  closing <- readIORef (connClosing c)
  unless closing (push relay c chunks)

push :: Relay -> Conn -> [ByteString] -> IO ()
push relay c chunks = do
  OutQueue front back <- readIORef (connOut c)
  writeIORef (connOut c) (OutQueue front (reverse chunks ++ back))
  dirty <- readIORef (connDirty c)
  unless dirty $ do
    writeIORef (connDirty c) True
    modifyIORef' (dirtyConns relay) (c :)

sendText :: Relay -> Conn -> ByteString -> IO ()
sendText relay c = enqueue relay c . encodeFrame opText

-- | Write every queue that got output this turn (until none is left: a
-- connection closing while its queue is written tells the others).
flushAll :: Relay -> IO ()
flushAll relay = do
  cs <- atomicModifyIORef' (dirtyConns relay) (\xs -> ([], reverse xs))
  unless (null cs) $ do
    forM_ cs $ \c -> do
      writeIORef (connDirty c) False
      r <- try @SomeException (flushConn relay c)
      either (const (dropConn relay c)) pure r
    flushAll relay

-- | Write as much of the queue as the socket takes; watch for writability
-- while something is left; close a closing connection once it is written.
flushConn :: Relay -> Conn -> IO ()
flushConn relay c = do
  OutQueue front back <- readIORef (connOut c)
  let chunks = filter (not . B.null) (front ++ reverse back)
      fd = ticketFd (connTicket c)
  (rest, failed) <- writeChunks fd chunks
  writeIORef (connOut c) (OutQueue rest [])
  watching <- readIORef (connWatchingWrite c)
  closing <- readIORef (connClosing c)
  if failed
    then dropConn relay c
    else
      if null rest
        then do
          when watching $ do
            watchWrite (loop relay) fd False
            writeIORef (connWatchingWrite c) False
          when closing (dropConn relay c)
        else unless watching $ do
          watchWrite (loop relay) fd True
          writeIORef (connWatchingWrite c) True

-- Input ------------------------------------------------------------------------

-- | Read what the socket has and decode it.
readConn :: Relay -> Conn -> IO ()
readConn relay c = do
  closing <- readIORef (connClosing c)
  let fd = ticketFd (connTicket c)
  r <- withForeignPtr (scratch relay) $ \p -> recvSocket fd p scratchSize
  if
    | r == -2 -> pure ()
    | r <= 0 -> dropConn relay c -- end of stream or error: ws 'close'
    | closing -> pure () -- ws stops reading after a close frame
    | otherwise -> do
        let view = BI.BS (scratch relay) r
        pend <- readIORef (connPending c)
        if null pend
          then decodeFrom relay c view True
          else do
            size <- (+ r) <$> readIORef (connPendingSize c)
            need <- readIORef (connNeed c)
            -- copied now: the scratch area is reused by the next recv
            let !kept = B.copy view
            writeIORef (connPending c) (kept : pend)
            writeIORef (connPendingSize c) size
            when (size >= need) $ do
              chunks <- readIORef (connPending c)
              writeIORef (connPending c) []
              writeIORef (connPendingSize c) 0
              decodeFrom relay c (B.concat (reverse chunks)) False

-- | Decode the frames at the start of the buffer. @borrowed@: the buffer is
-- the scratch area, so what is kept must be copied.
decodeFrom :: Relay -> Conn -> ByteString -> Bool -> IO ()
decodeFrom relay c buf borrowed = do
  frag <- readIORef (connFragments c)
  let soFar = maybe 0 (\(_, _, s) -> s) frag
  case parseHeader (maybe False (const True) frag) soFar messageLimit buf of
    NeedMore -> keep 0
    Refuse code -> failWith relay c code
    Parsed h
      | B.length buf < hSize h + hLength h -> keep (hSize h + hLength h)
      | otherwise -> do
          -- the payload is a fresh buffer, made now (not when first used,
          -- by which time the scratch area may hold other bytes)
          let !payload = unmaskedCopy h buf
              rest = BU.unsafeDrop (hSize h + hLength h) buf
          continue <- onFrame relay c h payload
          closing <- readIORef (connClosing c)
          when (continue && not closing && not (B.null rest)) (decodeFrom relay c rest borrowed)
  where
    keep need = do
      let !kept = if borrowed then B.copy buf else buf
      writeIORef (connPending c) [kept]
      writeIORef (connPendingSize c) (B.length buf)
      writeIORef (connNeed c) need

-- | One complete frame; False when the connection is closing.
onFrame :: Relay -> Conn -> Header -> ByteString -> IO Bool
onFrame relay c h payload
  | op == opPing = True <$ push relay c (encodeFrame opPong payload)
  | op == opPong = pure True
  | op == opClose = do
      if B.null payload
        then closeWith relay c B.empty
        else do
          let code = fromIntegral (BU.unsafeIndex payload 0) `shiftL` 8 .|. fromIntegral (BU.unsafeIndex payload 1) :: Int
              reason = BU.unsafeDrop 2 payload
          if
            | not (validCloseCode code) -> failWith relay c 1002
            | not (B.isValidUtf8 reason) -> failWith relay c 1007
            | otherwise -> closeWith relay c payload -- echo code and reason
      pure False
  | otherwise = do
      frag <- readIORef (connFragments c)
      case (frag, hFin h) of
        (Nothing, True) -> message op payload
        (Nothing, False) -> True <$ writeIORef (connFragments c) (Just (op, [payload], B.length payload))
        (Just (op0, ps, size), False) -> True <$ writeIORef (connFragments c) (Just (op0, payload : ps, size + B.length payload))
        (Just (op0, ps, _), True) -> do
          writeIORef (connFragments c) Nothing
          message op0 (B.concat (reverse (payload : ps)))
  where
    op = hOpcode h
    message o bytes
      | o == opText =
          if B.isValidUtf8 bytes
            then True <$ routeIn relay c bytes
            else False <$ failWith relay c 1007
      | otherwise = True <$ routeIn relay c (decodeLenient bytes)

-- | Queue a close frame and stop reading; the socket closes once written.
closeWith :: Relay -> Conn -> ByteString -> IO ()
closeWith relay c payload = do
  push relay c (encodeFrame opClose payload)
  writeIORef (connClosing c) True
  writeIORef (connPending c) []
  writeIORef (connFragments c) Nothing

-- | A protocol error: @ws@ closes with the code and no reason.
failWith :: Relay -> Conn -> Word16 -> IO ()
failWith relay c code = closeWith relay c (closePayload code)

-- Routing ----------------------------------------------------------------------

-- | Route one text message from a client.
routeIn :: Relay -> Conn -> ByteString -> IO ()
routeIn relay me raw = do
  now <- maybe (pure 0) (const monotonicMs) (perfLogger relay)
  case routeRaw (kind relay) (connId me) raw of
    Nothing -> pure ()
    Just routed -> do
      -- Vite logs before sending; the line is queued for the logger thread
      -- right after the frame is queued here (same order, same values)
      emit <- maybe (pure (pure ())) (\lg -> logTiming relay lg me now routed) (perfLogger relay)
      let frame = encodeFrame opText (BL.toStrict (routedBytes routed))
      cs <- readIORef (conns relay)
      case routedTarget routed of
        Just target ->
          forM_ (targetNumber target >>= (`IM.lookup` cs)) $ \c ->
            when (JsStr (connId c) == target) (enqueue relay c frame)
        Nothing
          | routedTargeted routed -> pure ()
          | otherwise -> forM_ cs $ \c -> unless (connNumber c == connNumber me) (enqueue relay c frame)
      emit

-- | The client number a target value can name (ids are decimal numbers).
targetNumber :: JsValue -> Maybe Int
targetNumber = \case
  JsStr s
    | let b = jsStringBytes s
    , not (B.null b)
    , B.length b < 16
    , B.all (\w -> w >= 48 && w <= 57) b ->
        Just (B.foldl' (\acc w -> acc * 10 + fromIntegral (w - 48)) 0 b)
  _ -> Nothing

logTiming :: Relay -> Logger -> Conn -> Double -> Routed -> IO (IO ())
logTiming relay lg me now routed = case look "protocol" of
  Just protocol
    | protocol == str "petrus-agent" -> do
        let kindV = look "kind"
            reqId = case look "requestId" of
              Just (JsStr s) -> Just s
              _ -> Nothing
        case (kindV, reqId) of
          (Just k, Just rid)
            | k == str "request" -> do
                modifyIORef' (timings relay) (Map.insert rid now)
                pure . perfLine "relay-forward-request" $
                  [("requestId", JsStr rid)] ++ opt "action" (look "action") ++ [("from", JsStr (connId me))]
            | k == str "response" -> do
                start <- atomicModifyIORef' (timings relay) (\m -> (Map.delete rid m, Map.lookup rid m))
                pure . forM_ start $ \s ->
                  perfLine "relay-forward-response" $
                    [("requestId", JsStr rid)]
                      ++ opt "action" (look "action")
                      ++ opt "ok" (look "ok")
                      ++ [("relayRoundtripMs", num (fixed1 (now - s))), ("from", JsStr (connId me))]
                      ++ opt "to" (look "targetClientId")
          _ -> pure (pure ())
  _ -> pure (pure ())
  where
    look = routedLookup routed . jsString
    opt k = maybe [] (\v -> [(k, v)])
    perfLine label fields = do
      ts <- isoTimestamp
      logLine lg ("[petrus-relay-perf] " <> ts <> " " <> label <> " " <> encodeJs (obj fields))

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
