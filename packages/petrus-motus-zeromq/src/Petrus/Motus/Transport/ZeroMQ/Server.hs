-- | The ROUTER service (@ZeroMQDispatchServer@): it exposes the Worker side
-- of a custody provider (Local SQLite Dispatch in production) to remote
-- Workers without owning custody itself.
--
-- One thread serves every client strictly serially. The server keeps no
-- correctness state: a cache of one provider per client id (at most 1000,
-- the most recently inserted evicted first, as @dict.popitem@ does), an
-- optional drain deadline during which claims are answered with no Attempt,
-- and nothing else. A reply that cannot be delivered is dropped: custody,
-- not delivery, decides whether an operation happened.
module Petrus.Motus.Transport.ZeroMQ.Server
  ( -- * Servers
    ZeroMQDispatchServer
  , ProviderFactory
  , ServerOptions (..)
  , defaultServerOptions
  , localServer
  , localServerWith
  , fromFactory
  , localFactory
    -- * Running
  , serveForever
  , waitReady
  , requestDrain
  , stopServer
  , endpointOf
    -- * Request handling (exposed for golden tests)
  , Providers
  , newProviders
  , handleRequest
  ) where

import Control.Concurrent.STM
import Control.Exception (SomeAsyncException, SomeException, finally, fromException, onException, throwIO, try)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite3 (SQLError (..))
import Foreign.C.Error (eWOULDBLOCK, getErrno, throwErrno)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTime)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (ActivityAttempt, AttemptFailure (..), DispatchError (..), WorkerDispatch (..))
import Petrus.Motus.Dispatch.Local (LocalWorkerOptions (..), defaultLocalWorkerOptions, openLocalWorkerDispatch)
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Internal.Repr (exceptionMessage, exceptionTypeName, pyRepr, pyStr, pyStrList)
import Petrus.Motus.Transport.ZeroMQ.Curve
import Petrus.Motus.Transport.ZeroMQ.Errors
import Petrus.Motus.Transport.ZeroMQ.Native qualified as Z
import Petrus.Motus.Transport.ZeroMQ.Wire
import Petrus.Activity (ActivityFailureFields (..), activityFailure)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, openFd)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

-- | @provider_factory(queues, worker_id)@: the custody a client's
-- requests are served by.
type ProviderFactory = [Text] -> Text -> IO WorkerDispatch

-- | The server's keyword arguments.
data ServerOptions = ServerOptions
  { serverSecretCertificate :: Maybe FilePath
  , allowedClientKeys :: Maybe FilePath
  , maxMessageBytes :: Int
  }

defaultServerOptions :: ServerOptions
defaultServerOptions = ServerOptions Nothing Nothing Petrus.Motus.Transport.ZeroMQ.Wire.maxMessageBytes

-- | A configured server; 'serveForever' runs it.
data ZeroMQDispatchServer = ZeroMQDispatchServer
  { endpoint :: Text
  , factory :: ProviderFactory
  , keys :: Maybe ServerKeys
  , allowedKeys :: Maybe FilePath
  , messageLimit :: Int
  , bound :: IORef (Maybe Text)
  , readyFlag :: TVar Bool
  , startupError :: IORef (Maybe SomeException)
  , stopping :: TVar Bool
  , drainDeadline :: TVar (Maybe Double)
  }

-- | @ZeroMQDispatchServer.local(endpoint, path, allowed_queues=..., ...)@.
localServer :: Text -> FilePath -> [Text] -> Maybe FilePath -> Maybe FilePath -> IO ZeroMQDispatchServer
localServer endpoint' path allowed server clients =
  localServerWith endpoint' path allowed defaultServerOptions {serverSecretCertificate = server, allowedClientKeys = clients}

-- | @ZeroMQDispatchServer(endpoint, path, allowed_queues=..., ...,
-- max_message_bytes=...)@.
localServerWith :: Text -> FilePath -> [Text] -> ServerOptions -> IO ZeroMQDispatchServer
localServerWith endpoint' path allowed options = do
  factory <- localFactory path allowed
  initialize endpoint' factory options

-- | @ZeroMQDispatchServer._from_factory(endpoint, factory,
-- max_message_bytes=...)@: the private fault-injection door (no CURVE).
fromFactory :: Text -> ProviderFactory -> Int -> IO ZeroMQDispatchServer
fromFactory endpoint' factory limit = initialize endpoint' factory defaultServerOptions {maxMessageBytes = limit}

-- | @_local_factory(path, allowed_queues)@: Local custody for a client's
-- queues when they are all allowed.
localFactory :: FilePath -> [Text] -> IO ProviderFactory
localFactory path allowed = do
  permitted <- Set.fromList <$> mapM (fromWire . nameText "allowed queue") allowed
  when (Set.null permitted) $ throwIO (ValueError "ZeroMQ Local Dispatch server requires at least one allowed queue")
  pure $ \queues workerId -> do
    let requested = dedupe queues
    when (null requested || not (all (`Set.member` permitted) requested)) $
      throwIO (ValueError ("Worker requested queues outside the server allowlist: " <> tupleRepr requested))
    Local.toWorkerDispatch <$> openLocalWorkerDispatch path defaultLocalWorkerOptions {workerQueues = requested, workerId = Just workerId}
  where
    tupleRepr = \case
      [single] -> "(" <> pyStr single <> ",)"
      items -> "(" <> T.intercalate ", " (map pyStr items) <> ")"

initialize :: Text -> ProviderFactory -> ServerOptions -> IO ZeroMQDispatchServer
initialize endpoint' factory options = do
  endpoint <- fromWire (endpointName True endpoint')
  keys <- serverSecurity endpoint options.serverSecretCertificate options.allowedClientKeys
  unless (options.maxMessageBytes >= 1 && options.maxMessageBytes <= Petrus.Motus.Transport.ZeroMQ.Wire.maxMessageBytes) $
    throwIO (ValueError "ZeroMQ maximum message bytes must be an integer from 1 to 1048576")
  bound <- newIORef Nothing
  readyFlag <- newTVarIO False
  startupError <- newIORef Nothing
  stopping <- newTVarIO False
  drainDeadline <- newTVarIO Nothing
  pure
    ZeroMQDispatchServer
      { endpoint
      , factory
      , keys
      , allowedKeys = options.allowedClientKeys
      , messageLimit = options.maxMessageBytes
      , bound
      , readyFlag
      , startupError
      , stopping
      , drainDeadline
      }

endpointOf :: ZeroMQDispatchServer -> Text
endpointOf s = s.endpoint

-- | Serve until 'stopServer', or until a requested drain's deadline;
-- blocks the calling thread. A startup failure (an owned IPC endpoint, a
-- bind error) is recorded for 'waitReady' and rethrown.
serveForever :: ZeroMQDispatchServer -> IO ()
serveForever server = do
  context <- Z.newContext
  providers <- newProviders
  resources <- newIORef Nothing
  let run = do
        opened@(_, _, socket) <- openServer server context
        writeIORef resources (Just opened)
        Z.bind socket server.endpoint
        endpoint <- Z.lastEndpoint socket
        writeIORef server.bound (Just endpoint)
        atomically (writeTVar server.readyFlag True)
        serveRequests server socket providers
      recordFailure e = do
        writeIORef server.startupError (Just e)
        atomically (writeTVar server.readyFlag True)
      cleanup = do
        closeProviders providers
        readIORef resources >>= mapM_ (\(lock, authenticator, socket) -> do
          Z.closeSocket socket
          mapM_ stopAuthenticator authenticator
          Z.terminateContext context
          mapM_ closeFd lock)
        opened <- readIORef resources
        when (null opened) (Z.terminateContext context)
  (try run >>= either (\(e :: SomeException) -> recordFailure e >> throwIO e) pure) `finally` cleanup

-- | @_open_server(context)@: the IPC ownership fence, the ZAP handler (TCP),
-- then the configured ROUTER socket.
openServer :: ZeroMQDispatchServer -> Z.Context -> IO (Maybe Fd, Maybe Authenticator, Z.Socket)
openServer server context = do
  lock <- endpointLock server.endpoint
  let release = mapM_ closeFd lock
  authenticator <-
    ( case (server.keys, server.allowedKeys) of
        (Just _, Just directory) -> Just <$> startAuthenticator context zapDomain directory
        _ -> pure Nothing
      )
      `onException` release
  let unwind = mapM_ stopAuthenticator authenticator >> release
  socket <- Z.newSocket context Z.Router `onException` unwind
  ( do
      Z.setIntOption socket Z.Linger 0
      Z.setIntOption socket Z.SendHighWaterMark highWaterMark
      Z.setIntOption socket Z.ReceiveHighWaterMark highWaterMark
      Z.setInt64Option socket (fromIntegral Petrus.Motus.Transport.ZeroMQ.Wire.maxMessageBytes)
      Z.setIntOption socket Z.SendTimeout 1000
      Z.setIntOption socket Z.RouterMandatory 1
      forM_ server.keys $ \k -> do
        Z.setBytesOption socket Z.ZapDomain (encodeText zapDomain)
        Z.setBytesOption socket Z.CurvePublicKey k.serverPublicKey
        Z.setBytesOption socket Z.CurveSecretKey k.serverSecretKey
        Z.setIntOption socket Z.CurveServer 1
    )
    `onException` (Z.closeSocket socket >> unwind)
  pure (lock, authenticator, socket)
  where
    encodeText = BS.pack . map (fromIntegral . fromEnum) . T.unpack

foreign import ccall unsafe "sys/file.h flock" c_flock :: CInt -> CInt -> IO CInt

-- | @_endpoint_lock(endpoint)@: for @ipc://path@, an exclusive BSD @flock@
-- on @<dir>/.<name>.impetus.lock@ (shared with the reference's servers),
-- refused when another server holds it.
endpointLock :: Text -> IO (Maybe Fd)
endpointLock endpoint
  | not ("ipc://" `T.isPrefixOf` endpoint) = pure Nothing
  | otherwise = do
      let path = T.unpack (T.drop (T.length "ipc://") endpoint)
          parent = takeDirectory path
      createDirectoryIfMissing True parent
      fd@(Fd raw) <-
        openFd (parent </> ("." <> takeFileName path <> ".impetus.lock")) ReadWrite defaultFileFlags {append = True, creat = Just 0o666}
      rc <- c_flock raw (2 {- LOCK_EX -} + 4 {- LOCK_NB -})
      when (rc /= 0) $ do
        errno <- getErrno
        closeFd fd
        if errno == eWOULDBLOCK
          then throwIO (RuntimeError ("ZeroMQ IPC endpoint is already owned: " <> endpoint))
          else throwErrno "flock"
      pure (Just fd)

-- | @wait_ready(timeout)@: the bound endpoint (with the port a @:*@ bind
-- chose), once serving.
waitReady :: ZeroMQDispatchServer -> Double -> IO Text
waitReady server seconds = do
  limit <- fromWire (timeoutSeconds "readiness timeout" seconds)
  ready <- timeout (round (limit * 1000000)) (atomically (readTVar server.readyFlag >>= check))
  when (null ready) $ throwIO (TimeoutError "ZeroMQ Dispatch server did not become ready")
  readIORef server.startupError >>= mapM_ (\e -> throwIO (RuntimeError ("ZeroMQ Dispatch server failed to start: " <> exceptionMessage e)))
  maybe (throwIO (RuntimeError "ZeroMQ Dispatch server failed to start")) pure =<< readIORef server.bound

-- | @request_drain(timeout)@: keep serving, answering claims with no
-- Attempt, until the deadline; then stop.
requestDrain :: ZeroMQDispatchServer -> Double -> IO ()
requestDrain server seconds = do
  limit <- fromWire (timeoutSeconds "drain timeout" seconds)
  now <- getMonotonicTime
  atomically (writeTVar server.drainDeadline (Just (now + limit)))

-- | @stop()@: the serving loop returns within 100 ms.
stopServer :: ZeroMQDispatchServer -> IO ()
stopServer server = atomically (writeTVar server.stopping True)

serveRequests :: ZeroMQDispatchServer -> Z.Socket -> Providers -> IO ()
serveRequests server socket providers = loop
  where
    loop = do
      stop <- readTVarIO server.stopping
      unless stop $ do
        deadline <- readTVarIO server.drainDeadline
        now <- getMonotonicTime
        case deadline of
          Just d | now >= d -> pure ()
          _ -> do
            Z.receiveFrames socket (Just 100000) >>= \case
              Nothing -> pure ()
              Just [] -> pure ()
              Just (route : frames) -> do
                let total = sum (map BS.length frames)
                    (body, problem)
                      | length frames /= 1 = ([], Just "request must contain exactly one application frame")
                      | total > server.messageLimit = ([], Just "request exceeds the maximum message size")
                      | otherwise = (frames, Nothing)
                draining <- isJust <$> readTVarIO server.drainDeadline
                response <- handleRequest server.factory server.messageLimit draining providers problem body
                -- Custody, not reply delivery, decides whether the operation
                -- happened; the client handles the uncertainty.
                void (try @SomeException (Z.sendFrames socket [route, response] (Just 1000)))
            loop

-- ---------------------------------------------------------------------------
-- Providers

-- | The provider cache: per client id, its queues, Worker id, and custody;
-- plus insertion order (most recent first) for eviction.
data Providers = Providers
  { entries :: IORef (Map Text ([Text], Text, WorkerDispatch))
  , order :: IORef [Text]
  }

newProviders :: IO Providers
newProviders = Providers <$> newIORef Map.empty <*> newIORef []

closeProviders :: Providers -> IO ()
closeProviders providers = do
  entries <- readIORef providers.entries
  forM_ (Map.elems entries) $ \(_, _, provider) -> void (try @SomeException provider.close)
  writeIORef providers.entries Map.empty
  writeIORef providers.order []

-- | @_provider(request, providers)@.
providerFor :: ProviderFactory -> Providers -> Text -> Text -> [Text] -> IO WorkerDispatch
providerFor factory providers clientId workerId queues' = do
  let queues = dedupe queues'
  entries <- readIORef providers.entries
  case Map.lookup clientId entries of
    Just (oldQueues, oldWorker, provider)
      | (queues, workerId) /= (oldQueues, oldWorker) -> throwIO (ValueError "client identity cannot change Worker queues or identity")
      | otherwise -> pure provider
    Nothing -> do
      when (Map.size entries >= maxClients) $
        readIORef providers.order >>= \case
          newest : rest -> do
            let evicted = Map.lookup newest entries
            modifyIORef' providers.entries (Map.delete newest)
            writeIORef providers.order rest
            forM_ evicted $ \(_, _, provider) -> provider.close
          [] -> pure ()
      provider <- factory queues workerId
      modifyIORef' providers.entries (Map.insert clientId (queues, workerId, provider))
      modifyIORef' providers.order (clientId :)
      pure provider

-- ---------------------------------------------------------------------------
-- Requests

data Operation
  = Claim
  | Heartbeat ActivityAttempt (Maybe Json)
  | Complete ActivityAttempt Json
  | Fail ActivityAttempt AttemptFailure

baseFields :: [Text]
baseFields = ["version", "request_id", "client_id", "worker_id", "queues", "operation"]

-- | @_handle(frames, providers, protocol_error=...)@: the encoded response
-- to one request.
handleRequest :: ProviderFactory -> Int -> Bool -> Providers -> Maybe Text -> [ByteString] -> IO ByteString
handleRequest factory limit draining providers problem frames = do
  requestId <- newIORef ("unknown" :: Text)
  outcome <- try $ do
    forM_ problem (throwIO . ProtocolError)
    request <- either (throwIO . ProtocolError) pure (parseRequest limit frames)
    let field key = maybe Null id (lookup key request)
        text key = case field key of
          String s -> s
          _ -> ""
    writeIORef requestId (text "request_id")
    operation <- decodeOperation request
    let queues = case field "queues" of
          Array items -> [q | String q <- items]
          _ -> []
    provider <- providerFor factory providers (text "client_id") (text "worker_id") queues
    value <- operate draining provider operation
    fromWire (encodeMessage (Object [("version", Int protocolVersion), ("request_id", String (text "request_id")), ("ok", Bool True), ("value", value)]))
  case outcome of
    Right bytes -> pure bytes
    Left e
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | otherwise -> do
          rid <- readIORef requestId
          let (kind, message) = classify e
          either (const (pure fallback)) pure $
            encodeMessage
              ( Object
                  [ ("version", Int protocolVersion)
                  , ("request_id", String rid)
                  , ("ok", Bool False)
                  , ("error", Object [("kind", String kind), ("message", String message)])
                  ]
              )
  where
    fallback = "{\"error\":{\"kind\":\"service\",\"message\":\"ValueError\"},\"ok\":false,\"request_id\":\"unknown\",\"version\":2}"

-- | The error kind and message: @_ProtocolError@ → @protocol@, any other
-- @ValueError@ → @refused@, anything else → @service@.
classify :: SomeException -> (Text, Text)
classify e
  | Just (ProtocolError m) <- fromException e = ("protocol", errorMessage "_ProtocolError" m)
  | Just (ValueError m) <- fromException e = ("refused", errorMessage "ValueError" m)
  | Just (DispatchError m) <- fromException e = ("refused", errorMessage "ValueError" m)
  | Just (SQLError _ details _) <- fromException e = ("service", errorMessage "OperationalError" details)
  | Just (TypeError m) <- fromException e = ("service", errorMessage "TypeError" m)
  | Just (RuntimeError m) <- fromException e = ("service", errorMessage "RuntimeError" m)
  | otherwise = ("service", errorMessage (exceptionTypeName e) (exceptionMessage e))

-- | @_parse_request(frames)@ (every refusal is a protocol error).
parseRequest :: Int -> [ByteString] -> Either Text [(Text, Json)]
parseRequest limit frames = either (Left . wireErrorMessage) Right $ do
  frame <- case frames of
    [single] -> Right single
    _ -> Left (WireValue "request must contain exactly one application frame")
  when (BS.length frame > limit) $ Left (WireValue "request exceeds the maximum message size")
  request <- decodeMessage frame
  let keys = map fst request
      field key = maybe Null id (lookup key request)
  unless (all (`elem` keys) baseFields) $
    Left (WireValue ("request requires base fields " <> pyStrList (sort baseFields)))
  _ <- wireName "request id" (field "request_id")
  _ <- wireName "client id" (field "client_id")
  _ <- wireName "worker id" (field "worker_id")
  queues <- case field "queues" of
    Array items | not (null items) && length items <= maxQueueCount -> Right items
    _ -> Left (WireValue ("request queues must contain from 1 to " <> T.pack (show maxQueueCount) <> " names"))
  mapM_ (wireName "queue") queues
  case field "version" of
    Int v | v == protocolVersion -> Right request
    other -> Left (WireValue ("unsupported ZeroMQ Dispatch protocol version " <> pyRepr other))

-- | @_decode_operation(request, base)@: a @ValueError@ is a protocol
-- error; the failure constructor's @TypeError@ is not.
decodeOperation :: [(Text, Json)] -> IO Operation
decodeOperation request = case decode of
  Left (WireValue m) -> throwIO (ProtocolError m)
  Left (WireType m) -> throwIO (TypeError m)
  Right operation -> pure operation
  where
    keys = map fst request
    field key = maybe Null id (lookup key request)
    requireFields fields operation =
      unless (sort keys == sort fields) $
        Left (WireValue (operation <> " request requires exactly " <> pyStrList (sort fields)))
    decode = do
      operation <- wireName "operation" (field "operation")
      case operation of
        "claim" -> Claim <$ requireFields baseFields "claim"
        "heartbeat" -> do
          let hasDetails = "details" `elem` keys
          requireFields (baseFields ++ ["attempt"] ++ ["details" | hasDetails]) "heartbeat"
          attempt <- decodeAttempt (field "attempt")
          pure (Heartbeat attempt (if hasDetails then Just (field "details") else Nothing))
        "complete" -> do
          requireFields (baseFields ++ ["attempt", "result"]) "complete"
          attempt <- decodeAttempt (field "attempt")
          pure (Complete attempt (field "result"))
        "fail" -> do
          failure <-
            if "failure" `elem` keys
              then do
                requireFields (baseFields ++ ["attempt", "failure"]) "fail"
                decodeFailure (field "failure")
              else do
                requireFields (baseFields ++ ["attempt", "error"]) "fail"
                message <- case field "error" of
                  String s -> Right s
                  _ -> Left (WireValue "failure error must be a string")
                either (Left . WireValue) Right (activityFailure (ActivityFailureFields message "ActivityError" Null True Nothing))
          attempt <- decodeAttempt (field "attempt")
          pure (Fail attempt (FailureClassified failure))
        other -> Left (WireValue ("unknown Worker Dispatch operation " <> pyStr other))

-- | @_operate(operation, arguments, provider)@.
operate :: Bool -> WorkerDispatch -> Operation -> IO Json
operate draining provider = \case
  Claim
    | draining -> pure (Object [("attempt", Null)])
    | otherwise -> do
        attempt <- provider.claim
        pure (Object [("attempt", maybe Null encodeAttempt attempt)])
  Heartbeat attempt details -> do
    latest <- provider.heartbeat attempt details
    pure (Object [("details", latest)])
  Complete attempt result -> do
    provider.complete attempt result
    pure (Object [("completed", Bool True)])
  Fail attempt failure -> do
    provider.fail attempt failure
    pure (Object [("failed", Bool True)])

