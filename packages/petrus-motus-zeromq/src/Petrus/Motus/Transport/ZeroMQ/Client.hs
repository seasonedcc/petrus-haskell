-- | The Worker side of the transport: a synchronous, thread-confined
-- 'WorkerDispatch' (@ZeroMQWorkerDispatch@) and a native asynchronous
-- 'WorkerAccess' with a bounded number of in-flight operations
-- (@AsyncZeroMQWorkerAccess@).
--
-- Every request attempt uses a fresh DEALER socket. Only @complete@ is
-- redelivered automatically (the identical payload, until the terminal
-- timeout): an exact duplicate terminal report is idempotent in custody. A
-- lost @claim@, @heartbeat@ or @fail@ response is reported as unknown and
-- recovered by custody leases.
module Petrus.Motus.Transport.ZeroMQ.Client
  ( -- * Options
    ClientOptions (..)
  , defaultClientOptions
    -- * Synchronous client
  , ZeroMQWorkerDispatch
  , newZeroMQWorkerDispatch
  , toWorkerDispatch
  , clientIdOf
  , workerIdOf
  , queuesOf
  , setRequestTimeout
  , requestTimeoutOf
  , claim
  , heartbeat
  , complete
  , fail
  , wait
  , close
    -- * Asynchronous access
  , AsyncZeroMQWorkerAccess
  , newAsyncZeroMQWorkerAccess
  , toWorkerAccess
  , setAccessRequestTimeout
  , closeAccess
    -- * Seams for tests
  , replaceSocketFactory
  , openClientSocket
  , replaceAccessSocketFactory
  , replaceAccessSocketOpener
  , openAccessSocket
  ) where

import Control.Concurrent (ThreadId, myThreadId, threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeAsyncException, SomeException, fromException, mask, onException, throwIO, try)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Activity (snapshotHeartbeatDetails)
import Petrus.Json (Json (..))
import Petrus.Motus.Dispatch (ActivityAttempt, AttemptFailure, WorkerDispatch (WorkerDispatch))
import Petrus.Motus.Dispatch qualified as D
import Petrus.Json.Python (pythonStrRepr, uuid4)
import Petrus.Motus.Transport.ZeroMQ.Curve (ClientKeys, clientSecurity)
import Petrus.Motus.Transport.ZeroMQ.Errors
import Petrus.Motus.Transport.ZeroMQ.Native qualified as Z
import Petrus.Motus.Transport.ZeroMQ.Socket
import Petrus.Motus.Transport.ZeroMQ.Wire
import Petrus.Motus.Worker (WorkerAccess (WorkerAccess))
import Petrus.Motus.Worker qualified as W
import System.Posix.Process (getProcessID)
import Prelude hiding (fail)

-- ---------------------------------------------------------------------------
-- Options

-- | The reference's keyword arguments.
data ClientOptions = ClientOptions
  { queues :: [Text]
  , workerId :: Maybe Text
  -- ^ Default: @worker-{pid}@.
  , clientSecretCertificate :: Maybe FilePath
  , serverPublicCertificate :: Maybe FilePath
  , requestTimeout :: Double
  , terminalTimeout :: Double
  , maxInFlightOperations :: Int
  -- ^ The asynchronous access's socket bound (ignored by the synchronous
  -- client).
  }

-- | @queues=("default",)@, 5 s requests, 30 s terminal redelivery, 8
-- in-flight operations.
defaultClientOptions :: ClientOptions
defaultClientOptions =
  ClientOptions
    { queues = ["default"]
    , workerId = Nothing
    , clientSecretCertificate = Nothing
    , serverPublicCertificate = Nothing
    , requestTimeout = 5.0
    , terminalTimeout = 30.0
    , maxInFlightOperations = 8
    }

-- | What both clients validate and derive in their constructors.
data Identity = Identity
  { endpoint :: Text
  , queues :: [Text]
  , workerId :: Text
  , clientId :: Text
  , terminalTimeout :: Double
  , keys :: Maybe ClientKeys
  }

identity :: Text -> Text -> ClientOptions -> IO (Identity, Double)
identity queueNoun endpoint' options = do
  endpoint <- fromWire (endpointName False endpoint')
  queues <- dedupe <$> mapM (fromWire . wireNameText "queue") options.queues
  unless (length queues >= 1 && length queues <= maxQueueCount) $
    throwIO (ValueError (queueNoun <> " requires from 1 to " <> T.pack (show maxQueueCount) <> " queues"))
  pid <- getProcessID
  workerId <- fromWire (wireNameText "worker id" (maybe ("worker-" <> T.pack (show pid)) id (nonEmpty options.workerId)))
  clientId <- uuid4
  requestLimit <- fromWire (timeoutSeconds "request timeout" options.requestTimeout)
  terminal <- fromWire (timeoutSeconds "terminal timeout" options.terminalTimeout)
  when (requestLimit < 0.001 || terminal < 0.001) $
    throwIO (ValueError "ZeroMQ request and terminal timeouts must be at least one millisecond")
  keys <- clientSecurity endpoint options.clientSecretCertificate options.serverPublicCertificate
  pure (Identity endpoint queues workerId clientId terminal keys, requestLimit)
  where
    nonEmpty = \case
      Just "" -> Nothing
      other -> other

-- | The request envelope and its encoded payload.
request :: Identity -> Text -> Text -> [(Text, Json)] -> IO ByteString
request who requestId operation fields =
  fromWire . encodeMessage . Object $
    [ ("version", Int protocolVersion)
    , ("request_id", String requestId)
    , ("client_id", String who.clientId)
    , ("worker_id", String who.workerId)
    , ("queues", Array (map String who.queues))
    , ("operation", String operation)
    ]
      ++ fields

-- | The response's value, or its refusal as the reference's exception.
decoded :: Text -> ByteString -> IO Json
decoded requestId payload = case decodeResponse requestId payload of
  Right v -> pure v
  Left (ResponseValue m) -> throwIO (ValueError m)
  Left (ResponseRuntime m) -> throwIO (RuntimeError m)

claimResult :: Json -> IO (Maybe ActivityAttempt)
claimResult v = do
  members <- fromWire (exact "claim result" ["attempt"] v)
  case lookup "attempt" members of
    Just Null -> pure Nothing
    Just attempt -> Just <$> fromWire (decodeAttempt attempt)
    Nothing -> pure Nothing

heartbeatFields :: ActivityAttempt -> Maybe Json -> IO [(Text, Json)]
heartbeatFields attempt details = do
  snapshot <- traverse (either (throwIO . ValueError) pure . snapshotHeartbeatDetails) details
  pure (("attempt", encodeAttempt attempt) : maybe [] (\d -> [("details", d)]) snapshot)

heartbeatResult :: Json -> IO Json
heartbeatResult v = do
  members <- fromWire (exact "heartbeat result" ["details"] v)
  pure (maybe Null id (lookup "details" members))

acknowledged :: Text -> Text -> Json -> IO ()
acknowledged operation key v = do
  members <- fromWire (exact (operation <> " result") [key] v)
  unless (Object members == Object [(key, Bool True)]) $
    throwIO (RuntimeError ("ZeroMQ Dispatch returned an invalid " <> operation <> " acknowledgement"))

completeFields :: ActivityAttempt -> Json -> IO [(Text, Json)]
completeFields attempt result = do
  faithfulResult <- fromWire (faithful "Activity result" result)
  pure [("attempt", encodeAttempt attempt), ("result", faithfulResult)]

failFields :: ActivityAttempt -> AttemptFailure -> IO [(Text, Json)]
failFields attempt failure = do
  classified <- fromWire (classifiedFailure failure)
  pure [("attempt", encodeAttempt attempt), ("failure", encodeFailure classified)]

sleepSeconds :: Text -> Double -> IO Bool
sleepSeconds noun seconds = do
  s <- fromWire (timeoutSeconds noun seconds)
  threadDelay (round (s * 1000000))
  pure False

-- | Whether a failure is one the reference catches as a transport failure
-- (@TimeoutError@, @zmq.Again@, @zmq.ZMQError@).
isTransport :: SomeException -> Bool
isTransport e = case fromException e of
  Just (_ :: TransportFailure) -> True
  Nothing -> case fromException e of
    Just (_ :: Z.ZmqError) -> True
    Nothing -> False

-- ---------------------------------------------------------------------------
-- Synchronous client

-- | @ZeroMQWorkerDispatch@: confined to the thread that constructed it.
data ZeroMQWorkerDispatch = ZeroMQWorkerDispatch
  { who :: Identity
  , requestTimeout :: IORef Double
  , owner :: ThreadId
  , context :: Z.Context
  , factory :: IORef SocketFactory
  , socket :: IORef (Maybe RpcSocket)
  , closed :: IORef Bool
  }

-- | @ZeroMQWorkerDispatch(endpoint, ...)@.
newZeroMQWorkerDispatch :: Text -> ClientOptions -> IO ZeroMQWorkerDispatch
newZeroMQWorkerDispatch endpoint' options = do
  (who, timeout') <- identity "ZeroMQ Worker Dispatch" endpoint' options
  requestTimeout <- newIORef timeout'
  owner <- myThreadId
  context <- Z.newContext
  factory <- newIORef (zmqSocketFactory context)
  socket <- newIORef Nothing
  closed <- newIORef False
  pure ZeroMQWorkerDispatch {who, requestTimeout, owner, context, factory, socket, closed}

-- | The provider-neutral surface.
toWorkerDispatch :: ZeroMQWorkerDispatch -> WorkerDispatch
toWorkerDispatch c =
  WorkerDispatch
    { D.claim = claim c
    , D.heartbeat = heartbeat c
    , D.complete = complete c
    , D.fail = fail c
    , D.wait = wait c
    , D.close = close c
    }

clientIdOf :: ZeroMQWorkerDispatch -> Text
clientIdOf c = c.who.clientId

workerIdOf :: ZeroMQWorkerDispatch -> Text
workerIdOf c = c.who.workerId

queuesOf :: ZeroMQWorkerDispatch -> [Text]
queuesOf c = c.who.queues

-- | Assign @request_timeout@ (the reference's tests shorten it between
-- calls).
setRequestTimeout :: ZeroMQWorkerDispatch -> Double -> IO ()
setRequestTimeout c = writeIORef c.requestTimeout

requestTimeoutOf :: ZeroMQWorkerDispatch -> IO Double
requestTimeoutOf c = readIORef c.requestTimeout

claim :: ZeroMQWorkerDispatch -> IO (Maybe ActivityAttempt)
claim c = rpc c "claim" [] Nothing >>= claimResult

-- | 'Nothing' omits @details@ (a lease extension only).
heartbeat :: ZeroMQWorkerDispatch -> ActivityAttempt -> Maybe Json -> IO Json
heartbeat c attempt details = do
  fields <- heartbeatFields attempt details
  rpc c "heartbeat" fields Nothing >>= heartbeatResult

complete :: ZeroMQWorkerDispatch -> ActivityAttempt -> Json -> IO ()
complete c attempt result = do
  fields <- completeFields attempt result
  deadline <- (+ c.who.terminalTimeout) <$> getMonotonicTime
  rpc c "complete" fields (Just deadline) >>= acknowledged "complete" "completed"

fail :: ZeroMQWorkerDispatch -> ActivityAttempt -> AttemptFailure -> IO ()
fail c attempt failure = do
  fields <- failFields attempt failure
  rpc c "fail" fields Nothing >>= acknowledged "fail" "failed"

-- | @time.sleep(timeout)@; never woken early.
wait :: ZeroMQWorkerDispatch -> Double -> IO Bool
wait _ = sleepSeconds "wait timeout"

-- | Idempotent; only the owning thread may close.
close :: ZeroMQWorkerDispatch -> IO ()
close c = do
  checkOwner c
  wasClosed <- atomicModifyIORef' c.closed (True,)
  unless wasClosed $ do
    discardSocket c
    Z.terminateContext c.context

checkOwner :: ZeroMQWorkerDispatch -> IO ()
checkOwner c = do
  me <- myThreadId
  when (me /= c.owner) $ throwIO (RuntimeError "ZeroMQ Worker Dispatch sockets may only be used by their owning thread")

discardSocket :: ZeroMQWorkerDispatch -> IO ()
discardSocket c = readIORef c.socket >>= mapM_ (\s -> writeIORef c.socket Nothing >> s.close)

-- | Replace where new sockets come from (the reference's tests assign
-- @_context@).
replaceSocketFactory :: ZeroMQWorkerDispatch -> SocketFactory -> IO ()
replaceSocketFactory c = writeIORef c.factory

-- | @_open_socket()@.
openClientSocket :: ZeroMQWorkerDispatch -> IO RpcSocket
openClientSocket c = do
  factory <- readIORef c.factory
  timeout' <- readIORef c.requestTimeout
  openDealer factory timeout' c.who.endpoint c.who.keys

rpc :: ZeroMQWorkerDispatch -> Text -> [(Text, Json)] -> Maybe Double -> IO Json
rpc c operation fields retryUntil = do
  checkOwner c
  isClosed <- readIORef c.closed
  when isClosed $ throwIO (RuntimeError "ZeroMQ Worker Dispatch is closed")
  requestId <- uuid4
  payload <- request c.who requestId operation fields
  let loop = do
        timeout' <- readIORef c.requestTimeout
        outcome <- try $ do
          s <-
            readIORef c.socket >>= \case
              Just s -> pure s
              Nothing -> do
                s <- openClientSocket c
                writeIORef c.socket (Just s)
                pure s
          s.send payload
          s.receive (requestMilliseconds timeout' * 1000) >>= \case
            Nothing -> throwIO ReceiveTimedOut
            Just frames -> do
              discardSocket c
              case frames of
                [frame] -> pure frame
                _ -> throwIO (RuntimeError "ZeroMQ Dispatch server returned a multipart protocol violation")
        case outcome of
          Right frame -> decoded requestId frame
          Left e
            | isTransport e -> do
                discardSocket c
                now <- getMonotonicTime
                case retryUntil of
                  Just deadline | now < deadline -> loop
                  _ -> throwIO (NotAcknowledged ("ZeroMQ Dispatch request " <> pythonStrRepr operation <> " was not acknowledged"))
            | otherwise -> throwIO e
  loop

-- ---------------------------------------------------------------------------
-- Asynchronous access

-- | @AsyncZeroMQWorkerAccess@: any number of slots share it; at most
-- @maxInFlightOperations@ requests (sockets) are live at once.
data AsyncZeroMQWorkerAccess = AsyncZeroMQWorkerAccess
  { who :: Identity
  , requestTimeout :: IORef Double
  , context :: Z.Context
  , accessFactory :: IORef SocketFactory
  , opener :: IORef (Maybe (IO RpcSocket))
  -- ^ A replacement for 'openAccessSocket', when a test installed one.
  , permits :: TVar Int
  , live :: TVar Int
  , closed :: IORef Bool
  }

-- | @await AsyncZeroMQWorkerAccess.create(endpoint, ...)@.
newAsyncZeroMQWorkerAccess :: Text -> ClientOptions -> IO AsyncZeroMQWorkerAccess
newAsyncZeroMQWorkerAccess endpoint' options = do
  when (options.maxInFlightOperations <= 0) $
    throwIO (ValueError "ZeroMQ maximum in-flight operations must be a positive integer")
  (who, timeout') <- identity "ZeroMQ Worker access" endpoint' options
  requestTimeout <- newIORef timeout'
  context <- Z.newContext
  permits <- newTVarIO options.maxInFlightOperations
  live <- newTVarIO 0
  closed <- newIORef False
  opener <- newIORef Nothing
  accessFactory <- newIORef (zmqSocketFactory context)
  pure AsyncZeroMQWorkerAccess {who, requestTimeout, context, accessFactory, opener, permits, live, closed}

-- | The slot-addressed surface an 'W.AsyncWorker' drives (slots are
-- ignored).
toWorkerAccess :: AsyncZeroMQWorkerAccess -> WorkerAccess
toWorkerAccess a =
  WorkerAccess
    { W.ready = do
        isClosed <- readIORef a.closed
        when isClosed $ throwIO (RuntimeError "ZeroMQ Worker access is closed")
    , W.claim = \_ -> asyncRpc a "claim" [] Nothing >>= claimResult
    , W.heartbeat = \_ attempt details -> do
        fields <- heartbeatFields attempt details
        asyncRpc a "heartbeat" fields Nothing >>= heartbeatResult
    , W.complete = \_ attempt result -> do
        fields <- completeFields attempt result
        deadline <- (+ a.who.terminalTimeout) <$> getMonotonicTime
        asyncRpc a "complete" fields (Just deadline) >>= acknowledged "complete" "completed"
    , W.fail = \_ attempt failure -> do
        fields <- failFields attempt failure
        asyncRpc a "fail" fields Nothing >>= acknowledged "fail" "failed"
    , W.wait = \_ seconds -> sleepSeconds "wait timeout" seconds
    , W.close = closeAccess a
    }

-- | Assign @request_timeout@.
setAccessRequestTimeout :: AsyncZeroMQWorkerAccess -> Double -> IO ()
setAccessRequestTimeout a = writeIORef a.requestTimeout

-- | Idempotent: waits until no request socket is open, then terminates
-- the context.
closeAccess :: AsyncZeroMQWorkerAccess -> IO ()
closeAccess a = do
  wasClosed <- atomicModifyIORef' a.closed (True,)
  unless wasClosed $ do
    atomically (readTVar a.live >>= \n -> when (n > 0) retry)
    Z.terminateContext a.context

-- | Replace where new sockets come from (the reference's tests assign
-- @_context@).
replaceAccessSocketFactory :: AsyncZeroMQWorkerAccess -> SocketFactory -> IO ()
replaceAccessSocketFactory a = writeIORef a.accessFactory

-- | Replace @_open_socket@ (the reference's tests assign it).
replaceAccessSocketOpener :: AsyncZeroMQWorkerAccess -> IO RpcSocket -> IO ()
replaceAccessSocketOpener a = writeIORef a.opener . Just

-- | @_open_socket()@.
openAccessSocket :: AsyncZeroMQWorkerAccess -> IO RpcSocket
openAccessSocket a = do
  factory <- readIORef a.accessFactory
  timeout' <- readIORef a.requestTimeout
  openDealer factory timeout' a.who.endpoint a.who.keys

asyncRpc :: AsyncZeroMQWorkerAccess -> Text -> [(Text, Json)] -> Maybe Double -> IO Json
asyncRpc a operation fields retryUntil = do
  isClosed <- readIORef a.closed
  when isClosed $ throwIO (RuntimeError "ZeroMQ Worker access is closed")
  requestId <- uuid4
  payload <- request a.who requestId operation fields
  let uncertain suffix = OperationUncertain ("ZeroMQ Dispatch request " <> pythonStrRepr operation <> suffix)
      once = mask $ \restore -> do
        -- Waiting for a permit is interruptible and leaves nothing behind:
        -- a cancellation here is a plain cancellation.
        atomically $ do
          n <- readTVar a.permits
          when (n <= 0) retry
          writeTVar a.permits (n - 1)
        let release = atomically (modifyTVar' a.permits (+ 1))
        open <- maybe (openAccessSocket a) id <$> readIORef a.opener
        s <- open `onException` release
        atomically (modifyTVar' a.live (+ 1))
        timeout' <- readIORef a.requestTimeout
        outcome <- try . restore $ do
          s.send payload
          s.receive (round (timeout' * 1000000)) >>= \case
            Nothing -> throwIO ReceiveTimedOut
            Just [frame] -> decoded requestId frame
            Just _ -> throwIO (RuntimeError "ZeroMQ Dispatch server returned a multipart protocol violation")
        _ <- try @SomeException s.close
        atomically (modifyTVar' a.live (subtract 1))
        release
        pure outcome
      loop =
        once >>= \case
          Right v -> pure v
          Left e
            | Just (_ :: SomeAsyncException) <- fromException e -> throwIO (uncertain " outcome is uncertain")
            | isTransport e -> do
                now <- getMonotonicTime
                case retryUntil of
                  Just deadline | now < deadline -> loop
                  _ -> throwIO (uncertain " was sent but not acknowledged")
            | otherwise -> throwIO e
  loop
