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
  , hostSettings
  , serve
  , runHostSocket
  , withHostServer
  ) where

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, killThread, myThreadId)
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, bracket, catch, finally, mask, throwIO, try)
import Control.Monad (void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Char (isAlphaNum, toLower)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Streaming.Network (bindPortTCP)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Hamsterdan.GitHub.Webhooks (Receipt (..), WebhookRejected (..), dispositionName)
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Api.Documents (oauth2RedirectDocument, openApiDocument, redocDocument, swaggerDocument)
import Hamsterdan.Host.Service (HostService (..))
import Hamsterdan.Host.Service qualified as Service
import Network.HTTP.Types (Status, http10, http11, status200, status202, status307, status400, status404, status405, status500, urlDecode)
import Network.HTTP.Types.Header (Header)
import Network.Wai (Application, Middleware, Request, Response, getRequestBodyChunk, httpVersion, mapResponseHeaders, rawPathInfo, rawQueryString, requestHeaderHost, requestHeaders, requestMethod, responseLBS)
import Network.Socket (Socket, SocketOption (NoDelay), accept, close, setCloseOnExecIfNeeded, setSocketOption, withFdSocket)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.Warp.Internal (Connection (..), Settings (..), runSettingsConnection, socketConnection)
import Petrus.Json (Json (..), compact, dumps)
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
hostWaiApplication service request send = do
  response <- route service request `catch` \(_ :: SomeException) -> pure internalError
  send response

-- | 'hostWaiApplication' as uvicorn serves it ('uvicornHeaders').
hostServerApplication :: HostService -> Application
hostServerApplication = uvicornHeaders . hostWaiApplication

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
    -- @str(URL(scope=redirect_scope))@ under @RedirectResponse@'s quoting.
    location redirected =
      "http://"
        <> maybe "" id (requestHeaderHost request)
        <> quote redirected
        <> rawQueryString request

-- | @urllib.parse.quote(url, safe=":/%#?=@[]!$&'()*+,;")@ of a path.
quote :: ByteString -> ByteString
quote = BS.concatMap escape
  where
    safe c = isAlphaNum c || c `elem` ("_.-~:/%#?=@[]!$&'()*+,;" :: String)
    escape byte
      | byte < 128 && safe (toEnum (fromIntegral byte)) = BS.singleton byte
      | otherwise = BC.pack ('%' : hex (fromIntegral byte))
    hex :: Int -> String
    hex n = [digits !! (n `div` 16), digits !! (n `mod` 16)]
    digits = "0123456789ABCDEF"

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
withLifespan :: HostService -> Bool -> IO a -> IO a
withLifespan service reconcileStartup action = do
  task <- newEmptyMVar
  let body = do
        when reconcileStartup $ void (Service.reconcileRegistration service)
        done <- newEmptyMVar
        _ <- mask $ \_ -> forkIOWithUnmask $ \unmask -> try @SomeException (unmask (Service.worker service)) >>= putMVar done
        putMVar task done
        action
      finish = do
        Service.stop service
        ( tryReadMVar task >>= \case
            Nothing -> pure ()
            Just done -> readMVar done >>= either throwIO pure
          )
          `finally` Service.close service
  result <- try @SomeException body
  case result of
    Left failure -> finish >> throwIO failure
    Right value -> value <$ finish

-- ---------------------------------------------------------------------------
-- Serving

data ServeOptions = ServeOptions
  { host :: String
  , port :: Int
  , onStarted :: IO ()
  -- ^ After the lifespan's startup, once the socket listens.
  }

-- | @uvicorn.run(create_app(service), host=host, port=port)@: serve until
-- SIGINT or SIGTERM, then shut down gracefully through the lifespan.
--
-- The signal that stopped it, if one did. uvicorn's @capture_signals@
-- restores the previous handlers after the shutdown and raises the
-- captured signal again (@signal.raise_signal@), so the reference process
-- then ends the way that signal ends it; the caller does the same with
-- what this returns.
serve :: HostService -> ServeOptions -> IO (Maybe Signal)
serve service options = do
  captured <- newIORef Nothing
  let capture signal closeSocket = CatchOnce (atomicModifyIORef' captured (const (Just signal, ())) >> closeSocket)
      settings =
        Warp.setHost (fromString options.host)
          . Warp.setPort options.port
          . Warp.setBeforeMainLoop options.onStarted
          . Warp.setInstallShutdownHandler
            ( \closeSocket -> do
                void (installHandler sigTERM (capture sigTERM closeSocket) Nothing)
                void (installHandler sigINT (capture sigINT closeSocket) Nothing)
            )
          $ hostSettings
  withLifespan service True $
    -- @Warp.runSettings@, over 'runHostSocket'.
    bracket (bindPortTCP options.port (fromString options.host)) close $ \socket -> do
      withFdSocket socket setCloseOnExecIfNeeded
      runHostSocket settings socket (hostServerApplication service)
  readIORef captured

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
