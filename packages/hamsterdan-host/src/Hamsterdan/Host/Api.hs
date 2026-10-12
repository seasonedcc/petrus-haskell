-- | The HTTP ingress, kept strictly separate from durable background work
-- (@host/api.py@).
--
-- The reference is a FastAPI application served by uvicorn; this is a WAI
-- application served by warp that answers every request the reference's
-- routing answers with the same status, the same body bytes, and the same
-- @content-type@, @content-length@, @allow@, and @location@ headers:
--
-- * @GET /healthz@: 200, the service health as compact JSON.
-- * @POST /github/webhooks@: 202 with the durable custody receipt; 400
--   @{"detail": ...}@ for a refused delivery or a body over
--   'Custody.maxBodyBytes'; 500 @Internal Server Error@ (plain text) for
--   any other failure.
-- * FastAPI's default pages (@/openapi.json@, @/docs@, @/redoc@,
--   @/docs/oauth2-redirect@), byte for byte.
-- * Starlette's routing fallbacks: 405 @{"detail":"Method Not Allowed"}@
--   with @allow@, 307 to the path without its trailing slash, and 404
--   @{"detail":"Not Found"}@.
--
-- Served ('serve', 'hostServerApplication'), every response also carries
-- what uvicorn writes around the application's headers ('uvicornHeaders'),
-- and every status line is h11's @HTTP/1.1@, also for an HTTP/1.0 request
-- ('runHostSocket'), so the bytes on the wire are uvicorn's.
--
-- The lifespan ('withLifespan') is the reference's: reconcile the
-- registration (optionally), start the inbox worker, serve, then stop the
-- service, wait for the worker (its failure is the primary error), and
-- close the service whatever happened.
module Hamsterdan.Host.Api
  ( -- * The application
    hostWaiApplication
  , hostServerApplication
  , uvicornHeaders

    -- * The lifespan
  , withLifespan

    -- * Serving
  , ServeOptions (..)
  , Served (..)
  , hostSettings
  , serve
  , runHostSocket
  , withHostServer
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId, threadDelay)
import Control.Concurrent.Async (mapConcurrently_, wait, withAsync)
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, bracket, bracket_, finally, onException, throwIO, try)
import Control.Monad (void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Char (toLower)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Functor ((<&>))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Hamsterdan.GitHub.Webhooks (Receipt (..), WebhookRejected (..), dispositionName)
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Api.Documents (oauth2RedirectDocument, openApiDocument, redocDocument, swaggerDocument)
import Hamsterdan.Host.Service (HostService (..))
import Hamsterdan.Host.Service qualified as Service
import Hamsterdan.Host.Uvicorn
  ( BindFailure (..)
  , Level (..)
  , Scope (..)
  , TrustedHosts
  , UvicornLog
  , accessLog
  , bindServer
  , finishedMessage
  , logMessage
  , plainMessage
  , proxyHeaders
  , requestScope
  , runningMessage
  , startedMessage
  , tracebackMessage
  , asgiFailureMessage
  , trustedHosts
  )
import Network.HTTP.Types (Status, http10, http11, status200, status202, status307, status400, status404, status405, status500, urlDecode)
import Network.HTTP.Types.Header (Header)
import Network.Wai (Application, Middleware, Request, Response, getRequestBodyChunk, httpVersion, mapResponseHeaders, rawPathInfo, rawQueryString, requestHeaderHost, requestHeaders, requestMethod, responseLBS)
import Network.Socket (Socket, SocketOption (NoDelay), accept, close, setCloseOnExecIfNeeded, setSocketOption, socketPort, withFdSocket)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.Warp.Internal (Connection (..), Settings (..), runSettingsConnection, socketConnection)
import Hamsterdan.Python.Url qualified as Url
import Petrus.Json (Json (..), compact, dumps)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (Handler (..), Signal, installHandler, sigINT, sigTERM)

-- ---------------------------------------------------------------------------
-- Responses

-- | Starlette's @Response@ headers: the given headers (names lowercased),
-- then @content-length@ (always, the body is never streamed), then
-- @content-type@ when there is a media type.
respond :: Status -> [Header] -> Maybe ByteString -> ByteString -> Response
respond status extra mediaType body =
  responseLBS
    status
    ( extra
        <> [("content-length", BC.pack (show (BS.length body)))]
        <> maybe [] (\media -> [("content-type", media)]) mediaType
    )
    (BL.fromStrict body)

-- | Starlette's @JSONResponse@: @json.dumps(content, ensure_ascii=False,
-- allow_nan=False, separators=(",", ":"))@.
jsonResponse :: Status -> [Header] -> Json -> Response
jsonResponse status extra value = case dumps compact value of
  Right body -> respond status extra (Just "application/json") body
  Left _ -> internalError

-- | FastAPI's @HTTPException@ handler.
detail :: Status -> [Header] -> Text -> Response
detail status extra message = jsonResponse status extra (Object [("detail", String message)])

-- | Starlette's @ServerErrorMiddleware@ response.
internalError :: Response
internalError = respond status500 [] (Just "text/plain; charset=utf-8") "Internal Server Error"

html :: ByteString -> Response
html = respond status200 [] (Just "text/html; charset=utf-8")

-- ---------------------------------------------------------------------------
-- Routing

data Endpoint = Endpoint
  { path :: ByteString
  , methods :: [ByteString]
  , handler :: HostService -> Request -> IO Response
  }

-- | FastAPI's default routes, then the application's, in registration
-- order. The default pages are Starlette routes, which admit @HEAD@
-- beside @GET@ (warp sends no body for @HEAD@); FastAPI's API routes admit
-- exactly their declared method.
endpoints :: [Endpoint]
endpoints =
  [ Endpoint "/openapi.json" page (\_ _ -> pure (respond status200 [] (Just "application/json") openApiDocument))
  , Endpoint "/docs" page (\_ _ -> pure (html swaggerDocument))
  , Endpoint "/docs/oauth2-redirect" page (\_ _ -> pure (html oauth2RedirectDocument))
  , Endpoint "/redoc" page (\_ _ -> pure (html redocDocument))
  , Endpoint "/healthz" ["GET"] (\service _ -> jsonResponse status200 [] <$> Service.health service)
  , Endpoint "/github/webhooks" ["POST"] webhook
  ]
  where
    -- Starlette joins a route's method set for @allow@, so the reference's
    -- order follows the process's string hashing; this is one of its two
    -- orders.
    page = ["GET", "HEAD"]

-- | The application over one service.
hostWaiApplication :: HostService -> Application
hostWaiApplication = reportingApplication (\_ -> pure ())

-- | 'hostWaiApplication', reporting what a route raised after its 500 is
-- sent, as uvicorn logs the exception Starlette's @ServerErrorMiddleware@
-- raises again after answering.
reportingApplication :: (SomeException -> IO ()) -> HostService -> Application
reportingApplication report service request send = do
  outcome <- try @SomeException (route service request)
  case outcome of
    Right response -> send response
    Left failure -> send internalError <* report failure

-- | 'hostWaiApplication' as uvicorn serves it: behind its proxy headers
-- middleware over the trusted hosts ('proxyHeaders'), with its headers
-- ('uvicornHeaders').
hostServerApplication :: TrustedHosts -> HostService -> Application
hostServerApplication trusted = proxyHeaders trusted . uvicornHeaders . hostWaiApplication

-- | What uvicorn's h11 protocol writes around an application's headers:
-- @date@ and @server: uvicorn@ before them, and @Connection: close@ after
-- them when the connection will not persist (the request says @close@, or
-- it is older than HTTP/1.1). Warp keeps a @date@ or @server@ the
-- response already has, and closes the connection when the response says
-- @close@ without adding its own @Connection@ header.
uvicornHeaders :: Middleware
uvicornHeaders app request send = do
  now <- getCurrentTime
  let date = BC.pack (formatTime defaultTimeLocale "%a, %d %b %Y %H:%M:%S GMT" now)
      tokens = [BC.map toLower (BC.strip token) | (name, value) <- requestHeaders request, name == "connection", token <- BC.split ',' value]
      closing = httpVersion request < http11 || "close" `elem` tokens
      around headers = [("date", date), ("server", "uvicorn")] <> headers <> [("Connection", "close") | closing]
  app request (send . mapResponseHeaders around)

-- | Starlette's @Router@: a full match, else the first path-only match
-- (405), else the trailing-slash redirect, else 404.
route :: HostService -> Request -> IO Response
route service request =
  case find (\e -> e.path == path' && requestMethod request `elem` e.methods) endpoints of
    Just endpoint -> endpoint.handler service request
    Nothing -> case find (\e -> e.path == path') endpoints of
      Just endpoint -> pure (detail status405 [("allow", BS.intercalate ", " endpoint.methods)] "Method Not Allowed")
      Nothing
        | path' /= "/"
        , let redirected = if "/" `BS.isSuffixOf` path' then BC.dropWhileEnd (== '/') path' else path' <> "/"
        , any (\e -> e.path == redirected) endpoints ->
            -- @RedirectResponse@ sets @location@ after its own headers.
            pure (responseLBS status307 [("content-length", "0"), ("location", location redirected)] "")
        | otherwise -> pure (detail status404 [] "Not Found")
  where
    -- uvicorn's @scope["path"]@: the percent-decoded request path.
    path' = urlDecode False (rawPathInfo request)
    -- @str(URL(scope=redirect_scope))@ under @RedirectResponse@'s quoting,
    -- with the scope's scheme ('proxyHeaders' may have set it).
    location redirected =
      TE.encodeUtf8 (requestScope request).scheme
        <> "://"
        <> maybe "" id (requestHeaderHost request)
        <> Url.quoteBytes ":/%#?=@[]!$&'()*+,;" redirected
        <> rawQueryString request

-- | @POST /github/webhooks@.
webhook :: HostService -> Request -> IO Response
webhook service request = do
  body <- readBounded request Custody.maxBodyBytes
  case body of
    Nothing -> pure (detail status400 [] "request body is too large")
    Just bytes -> do
      outcome <- try (Custody.receive service.custody headers bytes)
      case outcome of
        Left (WebhookRejected message) -> pure (detail status400 [] message)
        Right receipt ->
          pure $
            jsonResponse
              status202
              []
              ( Object
                  [ ("custody", String "durable")
                  , ("delivery_id", String receipt.deliveryId)
                  , ("disposition", String (dispositionName receipt.disposition))
                  ]
              )
  where
    -- @request.scope["headers"]@: lowercased names, latin-1 decoded.
    headers = [(latin1 (CI.foldedCase name), latin1 value) | (name, value) <- requestHeaders request]
    latin1 = TE.decodeLatin1

-- | The request body, or 'Nothing' once it exceeds the bound.
readBounded :: Request -> Int -> IO (Maybe ByteString)
readBounded request limit = go 0 []
  where
    go size chunks = do
      chunk <- getRequestBodyChunk request
      if BS.null chunk
        then pure (Just (BS.concat (reverse chunks)))
        else do
          let size' = size + BS.length chunk
          if size' > limit then pure Nothing else go size' (chunk : chunks)

-- ---------------------------------------------------------------------------
-- The lifespan

-- | @lifespan@: reconcile the registration (when asked), run the inbox
-- worker beside the action, then stop the service, wait for the worker,
-- and close the service. A worker failure is re-raised after the action;
-- the service is closed in every case.
--
-- The worker is owned ('withAsync'): it is always stopped and awaited (or,
-- if the wait itself is interrupted, cancelled) before the service closes.
withLifespan :: HostService -> Bool -> IO a -> IO a
withLifespan service reconcileStartup action = flip finally (Service.close service) $ do
  when reconcileStartup (void (Service.reconcileRegistration service)) `onException` Service.stop service
  withAsync (Service.worker service) $ \worker -> do
    result <- try @SomeException action
    Service.stop service
    -- @await task@ in the @finally@: a worker failure replaces the
    -- action's, as Python's does.
    wait worker
    either throwIO pure result

-- ---------------------------------------------------------------------------
-- Serving

data ServeOptions = ServeOptions
  { host :: String
  , port :: Int
  , log :: UvicornLog
  , forwardedAllowIps :: Text
  -- ^ @FORWARDED_ALLOW_IPS@, else @127.0.0.1@ (uvicorn's default).
  , failureLine :: SomeException -> Text
  -- ^ The last line of the traceback the reference logs for a lifespan
  -- or route failure (the line the command line prints for an uncaught
  -- exception).
  , onStarted :: Int -> IO ()
  -- ^ Once the sockets listen, with the bound port.
  }

-- | How 'serve' ended.
data Served
  = -- | @sys.exit(STARTUP_FAILURE)@: the lifespan's startup failed, or
    -- binding did (after the lifespan's shutdown).
    StartupFailed
  | -- | Shut down, by the signal it captured.
    ShutDown (Maybe Signal)
  deriving stock (Eq, Show)

-- | Where 'serve' is, for its signal handlers.
data Phase
  = Starting
  | Serving (IO ())
  | Stopping Signal

-- | @uvicorn.run(create_app(service), host=host, port=port)@: uvicorn's
-- @Server.serve@ with its log lines ("Hamsterdan.Host.Uvicorn"), over the
-- reference's lifespan:
--
-- * @Started server process@; the lifespan's startup (reconcile the
--   registration, start the inbox worker); on failure the service is
--   stopped and closed, the failure logged, and 'StartupFailed'.
-- * Bind every address of the host ('bindServer'); on failure the error is
--   logged, the lifespan shut down, and 'StartupFailed'.
-- * @Uvicorn running on …@, then serve, with an access line per response
--   and @FORWARDED_ALLOW_IPS@'s proxy headers, until SIGINT or SIGTERM. A
--   route's failure is answered 500 and logged (@Exception in ASGI
--   application@).
-- * @Shutting down@: stop listening, wait 0.1 s (and say so when requests
--   are still in flight), let warp finish them; then the lifespan's
--   shutdown (stop the service, wait for the worker, close the service;
--   a failure is logged, not raised) and @Finished server process@.
--
-- uvicorn's @capture_signals@ raises the captured signal again after the
-- shutdown (@signal.raise_signal@), so the reference process then ends the
-- way that signal ends it; the caller does the same with the signal
-- 'ShutDown' carries.
serve :: HostService -> ServeOptions -> IO Served
serve service options = do
  pid <- fromIntegral <$> getProcessID
  phase <- newIORef Starting
  drained <- newEmptyMVar
  let say = logMessage options.log
      lifespanFailure failure = say Error (tracebackMessage (options.failureLine failure))
      capture signal = CatchOnce $ do
        stopping <- atomicModifyIORef' phase $ \case
          Serving stop -> (Stopping signal, stop >> putMVar drained ())
          Starting -> (Stopping signal, pure ())
          stopped@(Stopping _) -> (stopped, pure ())
        stopping
  mapM_ (\signal -> installHandler signal (capture signal) Nothing) [sigTERM, sigINT]
  say Info (startedMessage pid)
  say Info (plainMessage "Waiting for application startup.")
  startup <- try @SomeException (void (Service.reconcileRegistration service))
  case startup of
    Left failure -> do
      -- The lifespan's @finally@: stop and close the service.
      closing <- try @SomeException (Service.stop service >> Service.close service)
      lifespanFailure (either id (const failure) closing)
      say Error (plainMessage "Application startup failed. Exiting.")
      pure StartupFailed
    Right () -> withAsync (Service.worker service) $ \worker -> do
      say Info (plainMessage "Application startup complete.")
      let shutdownLifespan = do
            say Info (plainMessage "Waiting for application shutdown.")
            outcome <- try @SomeException ((Service.stop service >> wait worker) `finally` Service.close service)
            case outcome of
              Left failure -> do
                lifespanFailure failure
                say Error (plainMessage "Application shutdown failed. Exiting.")
              Right () -> say Info (plainMessage "Application shutdown complete.")
      bound <- bindServer options.host options.port
      case bound of
        Left (BindFailure message) -> do
          say Error (plainMessage message)
          shutdownLifespan
          pure StartupFailed
        Right sockets -> flip finally (mapM_ close sockets) $ do
          port <- case sockets of
            listener : _ -> fromIntegral <$> socketPort listener
            [] -> pure options.port
          say Info (runningMessage (T.pack options.host) port)
          inFlight <- newIORef (0 :: Int)
          let shuttingDown = do
                say Info (plainMessage "Shutting down")
                mapM_ close sockets
                threadDelay 100000
                busy <- readIORef inFlight
                when (busy > 0) $
                  say Info (plainMessage "Waiting for connections to close. (CTRL+C to force quit)")
              app =
                counted inFlight
                  . proxyHeaders (trustedHosts options.forwardedAllowIps)
                  . accessLog options.log
                  . uvicornHeaders
                  $ reportingApplication (say Error . asgiFailureMessage . options.failureLine) service
          serving <- atomicModifyIORef' phase $ \case
            Starting -> (Serving shuttingDown, True)
            other -> (other, False)
          if serving
            then do
              options.onStarted port
              mapConcurrently_ (\listener -> runHostSocket hostSettings listener app) sockets
              readIORef phase >>= \case
                Stopping _ -> takeMVar drained
                _ -> pure ()
            else shuttingDown
          shutdownLifespan
          say Info (finishedMessage pid)
          readIORef phase <&> \case
            Stopping signal -> ShutDown (Just signal)
            _ -> ShutDown Nothing

-- | Count the requests in flight (h11's connections with a response
-- cycle under way).
counted :: IORef Int -> Middleware
counted inFlight app request send =
  bracket_
    (atomicModifyIORef' inFlight (\n -> (n + 1, ())))
    (atomicModifyIORef' inFlight (\n -> (n - 1, ())))
    (app request send)

-- | @Warp.runSettingsSocket@ with h11's status line: an HTTP/1.0 request's
-- response starts @HTTP/1.1@, as uvicorn writes it, where warp echoes the
-- request's version.
--
-- Warp writes the status line from the request it parsed, which no
-- middleware sees, so the rewrite is in the connection: the application
-- marks its thread while it sends the response to an HTTP/1.0 request, and
-- the first bytes warp sends from that thread (the status line, at the
-- start of the header block) have their version replaced. Warp runs the
-- application and writes its response on the connection's own thread.
-- Everything else (headers, @Connection: close@, the body, persistence) is
-- warp's, unchanged.
runHostSocket :: Warp.Settings -> Socket -> Application -> IO ()
runHostSocket settings socket app = do
  marked <- newIORef Set.empty
  settings.settingsInstallShutdownHandler (close socket)
  let connection = do
        (accepted, address) <- accept socket
        withFdSocket accepted setCloseOnExecIfNeeded
        void (try @IOException (setSocketOption accepted NoDelay 1))
        raw <- socketConnection settings accepted
        pure (h11StatusLine marked raw, address)
  runSettingsConnection settings connection (markHttp10 marked app)

-- | Mark the current thread while the application sends its response to an
-- HTTP/1.0 request.
markHttp10 :: IORef (Set ThreadId) -> Middleware
markHttp10 marked app request send
  | httpVersion request /= http10 = app request send
  | otherwise = app request $ \response -> do
      thread <- myThreadId
      atomicModifyIORef' marked (\threads -> (Set.insert thread threads, ()))
      send response `finally` atomicModifyIORef' marked (\threads -> (Set.delete thread threads, ()))

-- | The connection whose first send on a marked thread says @HTTP/1.1@.
h11StatusLine :: IORef (Set ThreadId) -> Connection -> Connection
h11StatusLine marked conn =
  conn
    { connSendAll = \bytes -> rewrite bytes >>= connSendAll conn
    , connSendMany = \case
        first : rest -> rewrite first >>= \first' -> connSendMany conn (first' : rest)
        [] -> connSendMany conn []
    }
  where
    rewrite bytes = do
      thread <- myThreadId
      wasMarked <- atomicModifyIORef' marked (\threads -> (Set.delete thread threads, Set.member thread threads))
      pure $ case BS.stripPrefix "HTTP/1.0 " bytes of
        Just rest | wasMarked -> "HTTP/1.1 " <> rest
        _ -> bytes

-- | Serve an application with 'runHostSocket' on a free local port for the
-- duration of an action (@Warp.testWithApplicationSettings@).
withHostServer :: Warp.Settings -> Application -> (Int -> IO a) -> IO a
withHostServer settings app action =
  bracket Warp.openFreePort (close . snd) $ \(port, socket) -> do
    ready <- newEmptyMVar
    done <- newEmptyMVar
    server <- forkIO (runHostSocket (Warp.setBeforeMainLoop (putMVar ready ()) settings) socket app `finally` putMVar done ())
    takeMVar ready
    action port `finally` (killThread server >> takeMVar done)

-- | The warp settings 'serve' starts from: uvicorn's @server@ banner (which
-- 'uvicornHeaders' writes in uvicorn's position, so warp keeps it) and a
-- bounded graceful shutdown (uvicorn waits for in-flight requests).
hostSettings :: Warp.Settings
hostSettings =
  Warp.setServerName "uvicorn"
    . Warp.setGracefulShutdownTimeout (Just 30)
    $ Warp.defaultSettings
