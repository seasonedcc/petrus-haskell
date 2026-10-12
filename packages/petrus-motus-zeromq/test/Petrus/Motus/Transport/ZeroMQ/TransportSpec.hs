-- | @tests/petrus/motus/transport/test_zeromq_dispatch_transport.py@: the
-- ZeroMQ Worker Dispatch transport's production acceptance. The
-- reference's @asyncio.run(...)@ blocks become direct calls on the
-- asynchronous access (Haskell has no event loop), its task cancellation an
-- asynchronous exception thrown at the requesting thread, and its
-- subprocess servers the suite re-executed in a server mode (the
-- process-death cases also run against the reference's server module).
module Petrus.Motus.Transport.ZeroMQ.TransportSpec (spec) where

import Control.Concurrent
import Control.Exception
import Control.Monad (forM_, replicateM, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.List (nub, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Activity hiding (invocation)
import Petrus.Activity qualified as A
import Petrus.TestSupport (valid)
import Petrus.Json (Json (..), defaultDumps, dumps, parseJson, surrogateRefusingLoads)
import Petrus.Motus.Dispatch (ActivityAttempt, ActivityOutcome (..), AttemptFailure (..), CancellationDisposition (..), cancellationInstruction)
import Petrus.Motus.Dispatch qualified as D
import Petrus.Motus.Dispatch.Local qualified as Local
import Petrus.Motus.Transport.ZeroMQ
  ( ClientOptions (..)
  , RuntimeError (..)
  , ServerOptions (..)
  , defaultClientOptions
  , defaultServerOptions
  , fromFactory
  , localServer
  , localServerWith
  , newAsyncZeroMQWorkerAccess
  , newZeroMQWorkerDispatch
  , requestDrain
  , serveForever
  , zapDomain
  )
import Petrus.Motus.Transport.ZeroMQ qualified as Z
import Petrus.Motus.Transport.ZeroMQ.Native qualified as N
import Petrus.Motus.Transport.ZeroMQ.Socket (RawDealer (..), RpcSocket (..), SocketFactory (..), TransportFailure (..))
import Petrus.Motus.Transport.ZeroMQ.Support
import Petrus.Motus.Transport.ZeroMQ.Wire (WireError (..), decodeAttempt, decodeMessage, encodeAttempt)
import Petrus.Motus.Worker (WorkerOptions (..), asyncWorkerFromAccess, defaultWorkerOptions, runAsyncWorker, stopAsyncWorker)
import Petrus.Motus.Worker qualified as W
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Hspec hiding (context)

-- | A Python-side @json.dumps(obj).encode()@ request (key order kept).
encoded :: Json -> ByteString
encoded = either (error . show) id . dumps defaultDumps

parsed :: ByteString -> Json
parsed = either error id . parseJson surrogateRefusingLoads

member :: Text -> Json -> Json
member key = \case
  Object members -> maybe Null id (lookup key members)
  _ -> Null

clientWith :: Text -> (ClientOptions -> ClientOptions) -> IO Z.ZeroMQWorkerDispatch
clientWith endpoint tweak = newZeroMQWorkerDispatch endpoint (tweak defaultClientOptions)

accessWith :: Text -> (ClientOptions -> ClientOptions) -> IO (Z.AsyncZeroMQWorkerAccess, W.WorkerAccess)
accessWith endpoint tweak = do
  access <- newAsyncZeroMQWorkerAccess endpoint (tweak defaultClientOptions)
  pure (access, Z.toWorkerAccess access)

withClient :: Text -> (ClientOptions -> ClientOptions) -> (Z.ZeroMQWorkerDispatch -> IO a) -> IO a
withClient endpoint tweak = bracket (clientWith endpoint tweak) Z.close

requireJust :: Maybe a -> IO a
requireJust = maybe (expectationFailure "expected an Attempt" >> error "unreachable") pure

-- | A thread's outcome, as an awaited task's.
data Task a = Task ThreadId (MVar (Either SomeException a))

spawn :: IO a -> IO (Task a)
spawn action = do
  result <- newEmptyMVar
  thread <- forkIO (try action >>= putMVar result)
  pure (Task thread result)

cancelTask :: Task a -> IO (Either SomeException a)
cancelTask (Task thread result) = killThread thread >> readMVar result

-- | @_attempt_for_transport()@.
transportAttempt :: ActivityAttempt
transportAttempt =
  either (error . T.unpack) id (D.activityAttempt "attempt" "epoch" "claimant" "default" invocation Null (Just "instance"))

-- | One-frame and multipart requests on a raw DEALER, each answered by
-- one JSON frame.
withJsonDealer :: Text -> ((ByteString -> IO Json, [ByteString] -> IO Json) -> IO a) -> IO a
withJsonDealer endpoint body =
  withRawDealer endpoint $ \exchange -> do
    let requestMany frames =
          exchange frames >>= \case
            [frame] -> pure (parsed frame)
            other -> error ("unexpected reply " <> show other)
    body (requestMany . pure, requestMany)

-- | Run against this suite's server (re-executed in the given mode) or,
-- when asked and synced, the reference's server module.
serverImpl :: Bool -> String -> (Either String Python -> IO ()) -> IO ()
serverImpl reference mode body
  | reference = withReference (body . Right)
  | otherwise = body (Left mode)

spec :: Spec
spec = do
  it "zap domain preserves the operational protocol identity" $
    zapDomain `shouldBe` "impetus.dispatch.worker.v2"

  it "ipc round trips attempt, heartbeat null, and terminal fencing" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
    dispatch <- localDispatch path "instance" [("work", "cpu")]
    Local.dispatch dispatch 1 invocation
    withRunning (localServer (ipcEndpoint tmp "dispatch.sock") path ["cpu", "io"] Nothing Nothing) $ \running ->
      withClient running.endpoint (\o -> o {queues = ["cpu"], workerId = Just "remote-cpu"}) $ \client -> do
        attempt <- Z.claim client >>= requireJust
        attempt.queue `shouldBe` "cpu"
        attempt.invocation `shouldBe` invocation
        let progress = obj [("progress", Array [Int 1, Int 2])]
        Z.heartbeat client attempt (Just progress) `shouldReturn` progress
        Z.heartbeat client attempt Nothing `shouldReturn` progress
        Z.heartbeat client attempt (Just Null) `shouldReturn` Null
        let done = obj [("completed", Array [Bool True])]
        Z.complete client attempt done
        Z.complete client attempt done
        Local.collect dispatch `shouldReturn` [(1, Succeeded done)]
        Z.heartbeat client attempt Nothing `shouldThrow` valueErrorMatching "stale Activity attempt"
        Z.complete client attempt (obj [("completed", Array [Bool False])])
          `shouldThrow` valueErrorMatching "conflicting terminal report"

  it "ipc round trips v2 policy and classified failure for sync and async clients" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
        policy =
          policyOf
            (policyFields defaultExecutionPolicy)
              { attempts = 3
              , heartbeatTimeout = 4
              , initialInterval = 5
              , coefficient = 3
              , maxInterval = 20
              , startToClose = Just 40
              , scheduleToClose = Just 90
              }
        call =
          valid . activityInvocation $
            ActivityInvocationFields
              { activity = "work"
              , input = obj [("operation", String "stable")]
              , policy
              , correlation = Just "correlation"
              , idempotency = Just "idempotency"
              }
        failure = failureOf (ActivityFailureFields "invalid" "InvalidRequest" (obj [("field", String "name")]) False (Just 7))
    dispatch <- localDispatch path "v2" []
    Local.dispatch dispatch 1 call
    Local.dispatch dispatch 2 call
    withRunning (localServer (ipcEndpoint tmp "v2-dispatch.sock") path ["default"] Nothing Nothing) $ \running ->
      withClient running.endpoint id $ \client -> do
        first <- Z.claim client >>= requireJust
        first.invocation `shouldBe` call
        Z.fail client first (FailureClassified failure)
        (access, port) <- accessWith running.endpoint id
        ( do
            attempt <- port.claim 0 >>= requireJust
            attempt.invocation `shouldBe` call
            port.fail 0 attempt (FailureClassified failure)
          )
          `finally` Z.closeAccess access
        Local.collect dispatch `shouldReturn` [(1, Failed failure), (2, Failed failure)]

  it "async ipc direct claim, heartbeat, completion fencing, and idempotent close" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
    dispatch <- localDispatch path "async-direct" [("work", "cpu")]
    Local.dispatch dispatch 1 invocation
    withRunning (localServer (ipcEndpoint tmp "async-dispatch.sock") path ["cpu"] Nothing Nothing) $ \running -> do
      (access, port) <- accessWith running.endpoint (\o -> o {queues = ["cpu"], workerId = Just "direct"})
      attempt <- port.claim 0 >>= requireJust
      let cursor = obj [("cursor", Int 1)]
      port.heartbeat 0 attempt (Just cursor) `shouldReturn` cursor
      port.heartbeat 0 attempt Nothing `shouldReturn` cursor
      port.heartbeat 0 attempt (Just Null) `shouldReturn` Null
      port.complete 0 attempt (obj [("done", Bool True)])
      port.heartbeat 0 attempt Nothing `shouldThrow` valueErrorMatching "stale Activity attempt"
      Z.closeAccess access
      Z.closeAccess access
      Local.collect dispatch `shouldReturn` [(1, Succeeded (obj [("done", Bool True)]))]

  it "sync and async transport clients observe lifecycle cancellation fences" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
        fence attempt position =
          either (error . T.unpack) id (cancellationInstruction (occurrenceOf attempt) invocation position)
    dispatch <- localDispatch path "cancelled" []
    Local.dispatch dispatch 1 invocation
    Local.dispatch dispatch 2 invocation
    withRunning (localServer (ipcEndpoint tmp "cancel-dispatch.sock") path ["default"] Nothing Nothing) $ \running ->
      withClient running.endpoint (\o -> o {Z.workerId = Just "sync"}) $ \client -> do
        attempt <- Z.claim client >>= requireJust
        Local.cancel dispatch (fence attempt 11) `shouldReturn` Fenced
        Z.heartbeat client attempt Nothing `shouldThrow` valueErrorMatching "stale Activity attempt"
        Z.complete client attempt (obj [("client", String "sync"), ("effect", String "ambiguous")])
        (access, port) <- accessWith running.endpoint (\o -> o {Z.workerId = Just "async"})
        ( do
            other <- port.claim 0 >>= requireJust
            Local.cancel dispatch (fence other 12) `shouldReturn` Fenced
            port.heartbeat 0 other Nothing `shouldThrow` valueErrorMatching "stale Activity attempt"
            port.complete 0 other (obj [("client", String "async"), ("effect", String "ambiguous")])
          )
          `finally` Z.closeAccess access
        outcomes <- Local.collect dispatch
        sort [c | (_, Succeeded o) <- outcomes, String c <- [member "client" o]] `shouldBe` ["async", "sync"]

  -- The reference refuses use from another event loop ("owning event
  -- loop"); a Haskell access has no loop to own (DIVERGENCES.md). The
  -- owner's close stays idempotent.
  it "async access owner close remains idempotent (the wrong-loop refusal has no Haskell analogue)" $ withScratch $ \tmp -> do
    (access, port) <- accessWith (ipcEndpoint tmp "unused.sock") id
    port.ready
    Z.closeAccess access
    Z.closeAccess access
    port.ready `shouldThrow` runtimeErrorMatching "is closed"

  describe "worker socket setup failure closes new socket" $
    forM_ [False, True] $ \asynchronous ->
      it ("asynchronous=" <> show asynchronous) $ withScratch $ \tmp -> do
        closed <- newIORef (0 :: Int)
        let raw =
              RawDealer
                { setInt = \option _ -> when (option == N.SendHighWaterMark) $ throwIO (RuntimeError "option refused")
                , setMaxMessageSize = \_ -> pure ()
                , setBytes = \_ _ -> pure ()
                , connectTo = \_ -> pure ()
                , closeRaw = modifyIORef' closed (+ 1)
                , connected = RpcSocket {send = \_ -> pure (), receive = \_ -> pure Nothing, close = pure ()}
                }
            factory = SocketFactory (pure raw)
        if asynchronous
          then do
            (access, _) <- accessWith (ipcEndpoint tmp "unused.sock") (\o -> o {socketFactory = Just factory})
            void (Z.openAccessSocket access) `shouldThrow` runtimeErrorMatching "option refused"
            readIORef closed `shouldReturn` 1
            Z.closeAccess access
          else do
            client <- clientWith (ipcEndpoint tmp "unused.sock") (\o -> o {socketFactory = Just factory})
            void (Z.openClientSocket client) `shouldThrow` runtimeErrorMatching "option refused"
            readIORef closed `shouldReturn` 1
            Z.close client

  it "async send cancellation boundary and permit wait are distinct" $ withScratch $ \tmp -> do
    sendEntered <- newEmptyMVar
    release <- newEmptyMVar :: IO (MVar ())
    closed <- newIORef (0 :: Int)
    let socket =
          RpcSocket
            { send = \_ -> putMVar sendEntered () >> readMVar release
            , receive = \_ -> throwIO (userError "send did not finish")
            , close = modifyIORef' closed (+ 1)
            }
    (access, port) <- accessWith (ipcEndpoint tmp "unused.sock") (\o -> o {maxInFlightOperations = 1, socketOpener = Just (pure socket)})
    sending <- spawn (port.claim 0)
    takeMVar sendEntered
    waiting <- spawn (port.claim 1)
    yield
    threadDelay 10000
    cancelTask waiting >>= \case
      Left e | Just ThreadKilled <- fromException e -> pure ()
      other -> expectationFailure ("the permit wait was not a plain cancellation: " <> show (fmap (const ()) other))
    cancelTask sending >>= \case
      Left e | Just err <- fromException e -> err `shouldSatisfy` uncertainMatching "outcome is uncertain"
      other -> expectationFailure ("the send was not uncertain: " <> show (fmap (const ()) other))
    readIORef closed `shouldReturn` 1
    Z.closeAccess access

  it "async completion retries identical payload with fresh bounded sockets" $ withScratch $ \tmp -> do
    payloads <- newIORef []
    sockets <- newIORef []
    live <- newIORef (0 :: Int)
    peak <- newIORef (0 :: Int)
    let open = do
          n <- atomicModifyIORef' live (\l -> (l + 1, l + 1))
          modifyIORef' peak (max n)
          isClosed <- newIORef False
          modifyIORef' sockets (isClosed :)
          pure
            RpcSocket
              { send = \payload -> modifyIORef' payloads (payload :)
              , receive = \_ -> throwIO ReceiveTimedOut
              , close = do
                  already <- readIORef isClosed
                  when already $ expectationFailure "closed twice"
                  writeIORef isClosed True
                  modifyIORef' live (subtract 1)
              }
    (access, port) <-
      accessWith
        (ipcEndpoint tmp "unused.sock")
        (\o -> o {requestTimeout = 0.001, terminalTimeout = 0.02, maxInFlightOperations = 1, socketOpener = Just open})
    port.complete 0 transportAttempt (obj [("same", Array [Int 1])])
      `shouldThrow` uncertainMatching "sent but not acknowledged"
    sent <- readIORef payloads
    length sent `shouldSatisfy` (>= 2)
    length (nub sent) `shouldBe` 1
    (readIORef sockets >>= mapM readIORef) >>= (`shouldSatisfy` and)
    readIORef peak `shouldReturn` 1
    readIORef live `shouldReturn` 0
    Z.closeAccess access

  it "v2 attempt wire requires and preserves nullable instance" $ do
    let wire = encodeAttempt transportAttempt
        fields = case wire of
          Object members -> members
          _ -> []
    sort (map fst fields) `shouldBe` sort ["attempt_id", "epoch", "claimant", "queue", "invocation", "latest_details", "instance"]
    fmap (.instance') (decodeAttempt wire) `shouldBe` Right (Just "instance")
    let withInstance v = Object [(k, if k == "instance" then v else x) | (k, x) <- fields]
    fmap (.instance') (decodeAttempt (withInstance Null)) `shouldBe` Right Nothing
    case decodeAttempt (Object (filter ((/= "instance") . fst) fields)) of
      Left (WireValue m) -> m `shouldSatisfy` matches "requires exactly"
      _ -> expectationFailure "expected a ValueError"

  it "ipc async worker uses concurrent zeromq owner lanes and heartbeats" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
    dispatch <- localDispatch path "async-zmq" [("work", "io")]
    forM_ [0 .. 2 :: Integer] $ \number ->
      Local.dispatch dispatch (fromInteger number + 1) (valid (A.invocation "work" (obj [("number", Int number)])))
    withRunning (localServer (ipcEndpoint tmp "dispatch.sock") path ["io"] Nothing Nothing) $ \running -> do
      entered <- newIORef (0 :: Int)
      peak <- newIORef (0 :: Int)
      workerRef <- newEmptyMVar
      let work called context = do
            n <- atomicModifyIORef' entered (\e -> (e + 1, e + 1))
            atomicModifyIORef' peak (\p -> (max p n, ()))
            let number = member "number" called.input
            details <- context.heartbeat (Just (obj [("number", number)]))
            threadDelay 20000
            atomicModifyIORef' entered (\e -> (e - 1, ()))
            when (number == Int 2) $ readMVar workerRef >>= stopAsyncWorker
            pure details
      worker <-
        asyncWorkerFromAccess
          (Z.toWorkerAccess <$> newAsyncZeroMQWorkerAccess running.endpoint defaultClientOptions {queues = ["io"], workerId = Just "async-zmq"})
          (Map.fromList [("work", work)])
          3
          defaultWorkerOptions {output = \_ -> pure ()}
      putMVar workerRef worker
      timeout 5000000 (runAsyncWorker worker 0.01) `shouldReturn` Just ()
      readIORef peak `shouldReturn` 3
      sortOn fst <$> Local.collect dispatch
        `shouldReturn` [(fromInteger n + 1, Succeeded (obj [("number", Int n)])) | n <- [0 .. 2]]

  it "queue allowlist, drain, and thread ownership are explicit" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
        endpoint = ipcEndpoint tmp "dispatch.sock"
    dispatch <- localDispatch path "instance" []
    Local.dispatch dispatch 1 invocation
    server <- localServer endpoint path ["default"] Nothing Nothing
    bracket (startRunning server) closeRunning $ \_ ->
      withClient endpoint (\o -> o {queues = ["admin"], requestTimeout = 0.5}) $ \refused ->
        withClient endpoint (\o -> o {requestTimeout = 0.5}) $ \client -> do
          void (Z.claim refused) `shouldThrow` valueErrorMatching "outside the server allowlist"
          crossThread <- spawn (Z.claim client)
          let Task _ result = crossThread
          readMVar result >>= \case
            Left e | Just err <- fromException e -> err `shouldSatisfy` runtimeErrorMatching "owning thread"
            _ -> expectationFailure "expected the owning-thread refusal"
          attempt <- Z.claim client >>= requireJust
          attempt.instance' `shouldBe` Just "instance"
          requestDrain server 2
          Z.complete client attempt (String "drained")
          Local.collect dispatch `shouldReturn` [(1, Succeeded (String "drained"))]
          Z.claim client `shouldReturn` Nothing

  it "ipc second server is refused before zeromq can steal the binding" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
        endpoint = ipcEndpoint tmp "dispatch.sock"
    withRunning (localServer endpoint path ["default"] Nothing Nothing) $ \_ -> do
      second <- localServer endpoint path ["default"] Nothing Nothing
      serveForever second `shouldThrow` runtimeErrorMatching "endpoint is already owned"

  it "curve tcp allows approved key and times out unapproved key" $ withScratch $ \tmp -> do
    certificates <- curveCertificates tmp
    let path = tmp </> "dispatch.sqlite3"
    dispatch <- localDispatch path "instance" []
    Local.dispatch dispatch 1 invocation
    Local.dispatch dispatch 2 invocation
    let make = localServer "tcp://127.0.0.1:*" path ["default"] (Just certificates.serverSecret) (Just certificates.allowed)
        keyed secret public seconds o =
          o {clientSecretCertificate = Just secret, serverPublicCertificate = Just public, requestTimeout = seconds}
    withRunning make $ \running ->
      withClient running.endpoint (keyed certificates.clientSecret certificates.serverPublic 1) $ \approved ->
        withClient running.endpoint (keyed certificates.strangerSecret certificates.serverPublic 0.2) $ \stranger ->
          withClient running.endpoint (keyed certificates.clientSecret certificates.otherServerPublic 0.2) $ \wrongServer -> do
            void (Z.claim stranger) `shouldThrow` notAcknowledged "claim"
            void (Z.claim wrongServer) `shouldThrow` notAcknowledged "claim"
            attempt <- Z.claim approved >>= requireJust
            Z.complete approved attempt (String "accepted")
            (access, port) <- accessWith running.endpoint (keyed certificates.clientSecret certificates.serverPublic 1)
            ( do
                native <- port.claim 0 >>= requireJust
                port.complete 0 native (String "native accepted")
              )
              `finally` Z.closeAccess access
            Local.collect dispatch `shouldReturn` [(1, Succeeded (String "accepted")), (2, Succeeded (String "native accepted"))]

  -- Beyond the reference suite: stopping a CURVE server closes its ROUTER
  -- and then cancels the ZAP handler's wait, while clients are connected
  -- and still connecting, so that the ending CURVE sessions keep the ZAP
  -- socket busy with pipe commands. libzmq's poll handles those in user
  -- space, where the cancel's signal can be lost; the wait must still end
  -- (closeRunning allows 5 s).
  it "a curve server stops while its clients are still connected" $ withScratch $ \tmp -> do
    certificates <- curveCertificates tmp
    let path = tmp </> "dispatch.sqlite3"
        keyed o = o {clientSecretCertificate = Just certificates.clientSecret, serverPublicCertificate = Just certificates.serverPublic, requestTimeout = 1}
    _ <- localDispatch path "instance" []
    forM_ [1 .. 20 :: Int] $ \trial -> do
      running <- localServer "tcp://127.0.0.1:*" path ["default"] (Just certificates.serverSecret) (Just certificates.allowed) >>= startRunning
      withClient running.endpoint keyed $ \client -> do
        Z.claim client `shouldReturn` Nothing
        bracket (replicateM 10 (Z.openClientSocket client)) (mapM_ (\socket -> socket.close)) $ \_ -> do
          connecting <- newIORef True
          let churn = do
                socket <- Z.openClientSocket client
                threadDelay 1000
                socket.close
                readIORef connecting >>= flip when churn
          churned <- newEmptyMVar
          _ <- forkIO (churn `finally` putMVar churned ())
          threadDelay (20000 + (trial * 3700) `mod` 15000)
          closeRunning running `finally` (writeIORef connecting False >> takeMVar churned)

  -- The same, reduced to one socket and made reliable: a receive with no
  -- deadline, cancelled while peers keep connecting and leaving (the
  -- audit's reproduction; an unbounded poll lost most of these cancels).
  it "a receive with no deadline is cancelled while peers come and go" $ do
    context <- N.newContext
    forM_ [1 .. 20 :: Int] $ \trial -> do
      socket <- N.newSocket context N.Rep
      N.setIntOption socket N.Linger 0
      let endpoint = "inproc://cancelled-" <> T.pack (show trial)
      N.bind socket endpoint
      churning <- newIORef True
      -- Closed sockets are reaped asynchronously: the pause keeps the
      -- context under libzmq's socket limit.
      let churn = do
            bracket (N.newSocket context N.Dealer) N.closeSocket $ \peer -> do
              N.setIntOption peer N.Linger 0
              N.connect peer endpoint
            threadDelay 50
            readIORef churning >>= flip when churn
      churned <- newEmptyMVar
      _ <- forkIO (churn `finally` putMVar churned ())
      finished <- newEmptyMVar
      waiter <- forkIO (void (N.receiveFrames socket Nothing) `finally` putMVar finished ())
      threadDelay (200 + (trial * 37) `mod` 1500)
      killed <- newEmptyMVar
      _ <- forkIO (killThread waiter >> putMVar killed ())
      delivered <- timeout 2000000 (takeMVar killed)
      writeIORef churning False
      takeMVar churned
      -- On failure the waiter keeps its socket and the context stays open.
      case delivered of
        Nothing -> expectationFailure ("trial " <> show trial <> ": the cancel was not delivered within 2 s")
        Just () -> takeMVar finished >> N.closeSocket socket
    N.terminateContext context

  it "public-only server certificate fails before starting authenticator" $ withScratch $ \tmp -> do
    certificates <- curveCertificates tmp
    void (localServer "tcp://127.0.0.1:*" (tmp </> "dispatch.sqlite3") ["default"] (Just certificates.serverPublic) (Just certificates.allowed))
      `shouldThrow` valueErrorMatching "server certificate must contain a public and secret key"

  describe "tcp requires curve and ipc rejects curve configuration" $ do
    it "endpoint=tcp://127.0.0.1:5000" $ withScratch $ \tmp -> do
      let endpoint = "tcp://127.0.0.1:5000"
      void (clientWith endpoint id) `shouldThrow` valueErrorMatching "requires client secret and server public"
      void (localServer endpoint (tmp </> "db") ["default"] Nothing Nothing)
        `shouldThrow` valueErrorMatching "requires a server secret certificate"
    it "endpoint=ipc:///tmp/impetus-test" $ withScratch $ \tmp -> do
      let endpoint = "ipc:///tmp/impetus-test"
      void (clientWith endpoint (\o -> o {clientSecretCertificate = Just "client", serverPublicCertificate = Just "server"}))
        `shouldThrow` valueErrorMatching "rejects TCP CURVE"
      void (localServer endpoint (tmp </> "db") ["default"] (Just "server") (Just "clients"))
        `shouldThrow` valueErrorMatching "rejects TCP CURVE"

  -- Beyond the reference suite: @_decode_message@'s refusals, as the
  -- pinned CPython words them. An integer past the digit limit raises
  -- before the syntax error that follows it.
  describe "malformed messages are refused with CPython's text" $
    it "decodeMessage" $ do
      let refusal = either (Just . (\case WireValue m -> m; WireType m -> "TypeError: " <> m)) (const Nothing) . decodeMessage
      refusal ("{\"a\": " <> BS.replicate 4301 0x31 <> ", }")
        `shouldBe` Just "Exceeds the limit (4300 digits) for integer string conversion: value has 4301 digits; use sys.set_int_max_str_digits() to increase the limit"
      refusal "{\"a\": 1, }" `shouldBe` Just "invalid ZeroMQ Dispatch JSON message: Illegal trailing comma before end of object: line 1 column 8 (char 7)"
      refusal "{\"a\": \"\xff\"}" `shouldBe` Just "invalid ZeroMQ Dispatch JSON message: 'utf-8' codec can't decode byte 0xff in position 7: invalid start byte"
      refusal "[1]" `shouldBe` Just "ZeroMQ Dispatch message must be a JSON object"

  describe "non-finite request, terminal, and drain timeouts are refused" $
    forM_ [("nan", 0 / 0), ("inf", 1 / 0), ("-inf", -1 / 0)] $ \(label, seconds :: Double) ->
      it ("timeout=" <> label) $ withScratch $ \tmp -> do
        let endpoint = ipcEndpoint tmp "dispatch.sock"
        void (clientWith endpoint (\o -> o {requestTimeout = seconds})) `shouldThrow` valueErrorMatching "finite non-negative"
        void (clientWith endpoint (\o -> o {terminalTimeout = seconds})) `shouldThrow` valueErrorMatching "finite non-negative"
        server <- localServer endpoint (tmp </> "dispatch.sqlite3") ["default"] Nothing Nothing
        requestDrain server seconds `shouldThrow` valueErrorMatching "finite non-negative"

  it "async lost claim reply is uncertain and not replayed" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
        endpoint = ipcEndpoint tmp "async-lost-claim.sock"
    dispatch <- localDispatch path "async-lost-claim" []
    Local.dispatch dispatch 1 (invocationWith 2 1)
    calls <- newIORef Map.empty
    let factory queues worker = do
          delays <- newIORef (Map.fromList [("claim", 0.2)])
          countingProvider calls . delayedProvider delays <$> localWorker path queues worker
    withRunning (fromFactory endpoint factory Z.maxMessageBytes) $ \_ -> do
      (access, port) <- accessWith endpoint (\o -> o {requestTimeout = 0.05})
      (void (port.claim 0) `shouldThrow` (\e -> uncertainMatching "'claim'" e && uncertainMatching "not acknowledged" e))
        `finally` Z.closeAccess access
      readIORef calls `shouldReturn` Map.fromList [("claim", 1)]
      assertTask path 1

  it "async lost heartbeat and failure replies are not replayed" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
        endpoint = ipcEndpoint tmp "async-lost-nonterminal.sock"
    dispatch <- localDispatch path "async-lost-nonterminal" []
    Local.dispatch dispatch 1 (invocationWith 1 2)
    calls <- newIORef Map.empty
    let factory queues worker = do
          delays <- newIORef (Map.fromList [("heartbeat", 0.2), ("fail", 0.2)])
          provider <- delayedProvider delays <$> localWorker path queues worker
          let counted = countingProvider calls provider
          -- Only heartbeat and fail are counted, as in the reference.
          pure counted {D.claim = provider.claim}
    withRunning (fromFactory endpoint factory Z.maxMessageBytes) $ \_ -> do
      (access, port) <- accessWith endpoint id
      ( do
          attempt <- port.claim 0 >>= requireJust
          Z.setAccessRequestTimeout access 0.05
          void (port.heartbeat 0 attempt (Just (obj [("persisted", Bool True)])))
            `shouldThrow` (\e -> uncertainMatching "'heartbeat'" e && uncertainMatching "not acknowledged" e)
          threadDelay 200000
          port.fail 0 attempt (FailureMessage "final")
            `shouldThrow` (\e -> uncertainMatching "'fail'" e && uncertainMatching "not acknowledged" e)
        )
        `finally` Z.closeAccess access
      readIORef calls `shouldReturn` Map.fromList [("fail", 1), ("heartbeat", 1)]
      Local.collect dispatch `shouldReturn` [(1, Failed (failureOf (ActivityFailureFields "final" "ActivityError" Null True Nothing)))]

  it "lost claim reply is not blindly replayed and recovers by lease expiry" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
        endpoint = ipcEndpoint tmp "dispatch.sock"
    dispatch <- localDispatch path "instance" []
    Local.dispatch dispatch 1 (invocationWith 2 1)
    let factory queues worker = do
          delays <- newIORef (Map.fromList [("claim", 0.2)])
          delayedProvider delays <$> localWorker path queues worker
    withRunning (fromFactory endpoint factory Z.maxMessageBytes) $ \_ ->
      withClient endpoint (\o -> o {requestTimeout = 0.05}) $ \client -> do
        void (Z.claim client) `shouldThrow` notAcknowledged "claim"
        -- One claim reached custody. A blind RPC retry would have
        -- incremented another task or epoch; the only task stays leased at
        -- epoch 1.
        assertTask path 1
        threadDelay 1050000
        replacement <- Local.openLocalWorkerDispatch path Local.defaultLocalWorkerOptions {Local.explicitClaimant = Just "replacement"}
        reclaimed <- Local.claim replacement >>= requireJust
        reclaimed.epoch `shouldBe` "2"

  it "lost terminal reply is redelivered exactly until acknowledged" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
        endpoint = ipcEndpoint tmp "dispatch.sock"
    dispatch <- localDispatch path "instance" []
    Local.dispatch dispatch 1 invocation
    delays <- newIORef (Map.fromList [("complete", 0.2)])
    let factory queues worker = delayedProvider delays <$> localWorker path queues worker
    withRunning (fromFactory endpoint factory Z.maxMessageBytes) $ \_ ->
      withClient endpoint (\o -> o {terminalTimeout = 1}) $ \client -> do
        attempt <- Z.claim client >>= requireJust
        -- Only completion needs the short deadline that forces reply loss.
        Z.setRequestTimeout client 0.05
        Z.complete client attempt (obj [("durable", Bool True)])
        Local.collect dispatch `shouldReturn` [(1, Succeeded (obj [("durable", Bool True)]))]

  describe "uncertain completion redelivers exactly across dispatch process death" $
    forM_ [False, True] $ \reference ->
      it (if reference then "replacement: the reference's server" else "replacement: this server") $
        serverImpl reference "server" $ \replacementServer -> withScratch $ \tmp -> do
          let path = tmp </> "dispatch.sqlite3"
              endpoint = ipcEndpoint tmp "dispatch.sock"
              committed = tmp </> "completion-committed"
          dispatch <- localDispatch path "instance" []
          Local.dispatch dispatch 1 invocation
          first <- startServerProcess (Left "delayed") [path, T.unpack endpoint, committed]
          member "endpoint" first.readiness `shouldBe` String endpoint
          replacement <- newIORef Nothing
          ( withClient endpoint (\o -> o {terminalTimeout = 3}) $ \client -> do
              attempt <- Z.claim client >>= requireJust
              killer <- spawn $ do
                present <- waitForFile committed 5
                when (not present) $ throwIO (userError "delayed server did not commit completion")
                killProcess first.handle
                started <- startServerProcess replacementServer (serverArguments path endpoint)
                writeIORef replacement (Just started)
              Z.setRequestTimeout client 0.1
              Z.complete client attempt (obj [("survived", String "process death")])
              let Task _ result = killer
              timeout 5000000 (readMVar result) >>= \case
                Just (Right ()) -> pure ()
                other -> expectationFailure ("the killer failed: " <> show (fmap (fmap (const ())) other))
              Local.collect dispatch `shouldReturn` [(1, Succeeded (obj [("survived", String "process death")]))]
            )
            `finally` do
              killProcess first.handle
              readIORef replacement >>= mapM_ (void . stopServerProcess . (.handle))

  it "lost heartbeat and failure replies are not replayed" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
        endpoint = ipcEndpoint tmp "dispatch.sock"
    dispatch <- localDispatch path "instance" []
    delays <- newIORef (Map.fromList [("heartbeat", 0.2), ("fail", 0.2)])
    let factory queues worker = delayedProvider delays <$> localWorker path queues worker
    withRunning (fromFactory endpoint factory Z.maxMessageBytes) $ \_ -> do
      withClient endpoint id $ \readiness -> Z.claim readiness `shouldReturn` Nothing
      Local.dispatch dispatch 1 (invocationWith 2 2)
      Local.dispatch dispatch 2 (invocationWith 1 2)
      withClient endpoint id $ \client -> do
        setupTimeout <- Z.requestTimeoutOf client
        first <- Z.claim client >>= requireJust
        Z.setRequestTimeout client 0.05
        void (Z.heartbeat client first (Just (obj [("persisted", Bool True)]))) `shouldThrow` notAcknowledged "heartbeat"
        details <- rawDetails path
        details `shouldBe` obj [("persisted", Bool True)]
        threadDelay 200000
        Z.fail client first (FailureMessage "retry") `shouldThrow` notAcknowledged "fail"
        threadDelay 250000
        Z.setRequestTimeout client setupTimeout
        replacement <- Z.claim client >>= requireJust
        replacement.epoch `shouldBe` "2"
        Z.complete client replacement (String "recovered")
        final <- Z.claim client >>= requireJust
        modifyIORef' delays (Map.insert "fail" 0.2)
        Z.setRequestTimeout client 0.05
        Z.fail client final (FailureMessage "final") `shouldThrow` notAcknowledged "fail"
        Local.collect dispatch
          `shouldReturn` [ (1, Succeeded (String "recovered"))
                         , (2, Failed (failureOf (ActivityFailureFields "final" "ActivityError" Null True Nothing)))
                         ]

  it "protocol refuses widened, unknown version, and oversized requests" $ withScratch $ \tmp -> do
    let endpoint = ipcEndpoint tmp "dispatch.sock"
        base =
          [ ("version", Int 2)
          , ("request_id", String "request")
          , ("client_id", String "client")
          , ("worker_id", String "worker")
          , ("queues", Array [String "default"])
          , ("operation", String "claim")
          ]
        with key v = Object [(k, if k == key then v else x) | (k, x) <- base]
    withRunning (localServerWith endpoint (tmp </> "dispatch.sqlite3") ["default"] defaultServerOptions {maxMessageBytes = 1000}) $ \_ ->
      withJsonDealer endpoint $ \(request, requestFrames) -> do
        forM_
          [ (Object (base ++ [("extra", Bool True)]), "requires exactly")
          , (with "version" (Int 1), "unsupported")
          , (with "version" (Bool True), "unsupported")
          , (with "operation" (String (T.replicate 300 "x")), "protocol limit")
          , (Object (base ++ [("padding", String (T.replicate 1500 "x"))]), "maximum message size")
          ]
          $ \(message, fragment) -> do
            response <- request (encoded message)
            member "ok" response `shouldSatisfy` isFalse
            member "kind" (member "error" response) `shouldBe` String "protocol"
            case member "message" (member "error" response) of
              String m -> m `shouldSatisfy` matches fragment
              other -> expectationFailure ("no message: " <> show other)
        multipart <- requestFrames [encoded (Object base), "extra"]
        member "kind" (member "error" multipart) `shouldBe` String "protocol"
        case member "message" (member "error" multipart) of
          String m -> m `shouldSatisfy` matches "exactly one application frame"
          other -> expectationFailure ("no message: " <> show other)
        response <- request (encoded (Object base))
        member "ok" response `shouldSatisfy` isTrue

  it "stale attempt payload cannot change claimant or epoch" $ withScratch $ \tmp -> do
    let path = tmp </> "dispatch.sqlite3"
        endpoint = ipcEndpoint tmp "dispatch.sock"
    dispatch <- localDispatch path "instance" []
    Local.dispatch dispatch 1 invocation
    withRunning (localServer endpoint path ["default"] Nothing Nothing) $ \_ ->
      withClient endpoint id $ \client -> do
        attempt <- Z.claim client >>= requireJust
        let longer = (policyFields defaultExecutionPolicy) {attempts = 2, heartbeatTimeout = 3600}
            altered epoch claimant queue invocation' =
              either (error . T.unpack) id $
                D.activityAttempt attempt.attemptId epoch claimant queue invocation' attempt.latestDetails attempt.instance'
        forM_
          [ altered "2" attempt.claimant attempt.queue attempt.invocation
          , altered attempt.epoch "other" attempt.queue attempt.invocation
          , altered attempt.epoch attempt.claimant "other" attempt.invocation
          , altered attempt.epoch attempt.claimant attempt.queue $
              valid (activityInvocation (invocationFields attempt.invocation) {policy = policyOf longer})
          ]
          $ \stale -> Z.heartbeat client stale Nothing `shouldThrow` valueErrorMatching "stale Activity attempt"
        Z.complete client attempt (String "done")

  describe "dispatch service process death preserves lease details and restart recovery" $
    forM_ [False, True] $ \reference ->
      it (if reference then "server: the reference's" else "server: this one") $
        serverImpl reference "server" $ \which -> withScratch $ \tmp -> do
          let path = tmp </> "dispatch.sqlite3"
              endpoint = ipcEndpoint tmp "dispatch.sock"
          dispatch <- localDispatch path "instance" []
          Local.dispatch dispatch 1 (invocationWith 2 1)
          first <- startServerProcess which (serverArguments path endpoint)
          member "ready" first.readiness `shouldBe` Bool True
          member "endpoint" first.readiness `shouldBe` String endpoint
          second <- newIORef Nothing
          ( withClient endpoint (\o -> o {requestTimeout = 0.5}) $ \firstClient -> do
              attempt <- Z.claim firstClient >>= requireJust
              Z.heartbeat firstClient attempt (Just (obj [("checkpoint", Int 4)])) `shouldReturn` obj [("checkpoint", Int 4)]
              killProcess first.handle
              void (Z.heartbeat firstClient attempt Nothing) `shouldThrow` notAcknowledged "heartbeat"
              started <- startServerProcess which (serverArguments path endpoint)
              writeIORef second (Just started)
              Z.heartbeat firstClient attempt (Just (obj [("checkpoint", Int 5)])) `shouldReturn` obj [("checkpoint", Int 5)]
              withClient endpoint (\o -> o {requestTimeout = 0.5}) $ \replacement -> do
                Z.claim replacement `shouldReturn` Nothing
                threadDelay 1050000
                reclaimed <- Z.claim replacement >>= requireJust
                reclaimed.instance' `shouldBe` Just "instance"
                reclaimed.epoch `shouldBe` "2"
                reclaimed.latestDetails `shouldBe` obj [("checkpoint", Int 5)]
                Z.complete replacement reclaimed (String "recovered")
              Local.collect dispatch `shouldReturn` [(1, Succeeded (String "recovered"))]
            )
            `finally` killProcess first.handle
          readIORef second >>= mapM_ (\started -> stopServerProcess started.handle `shouldReturn` ExitSuccess)
  where
    isFalse = \case
      Bool False -> True
      _ -> False
    isTrue = \case
      Bool True -> True
      _ -> False

-- | The server CLI's arguments in the reference's @_start_server_process@.
serverArguments :: FilePath -> Text -> [String]
serverArguments path endpoint = ["--path", path, "--bind", T.unpack endpoint, "--queue", "default", "--drain-timeout", "0.1"]
