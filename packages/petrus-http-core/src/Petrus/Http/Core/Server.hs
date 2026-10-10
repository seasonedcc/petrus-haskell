{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE MultiWayIf #-}

-- | A CPython-compatible HTTP/1.0 server: @http.server.ThreadingHTTPServer@
-- with a @BaseHTTPRequestHandler@ whose @protocol_version@ is @HTTP/1.0@,
-- which is what both upstream Petrus HTTP services are.
--
-- * 'createServer' binds and listens (IPv4, @SO_REUSEADDR@, backlog 5) and
--   starts nothing; the application runs 'serveForever', stops it with
--   'shutdown' and releases the socket with 'serverClose'.
-- * Each accepted connection gets its own thread and carries exactly one
--   request; whatever follows it (pipelined requests) is discarded. The
--   connection is then shut down for writing and closed.
-- * Before the handler runs, the request line and header block are read and
--   checked exactly as CPython does ("Petrus.Http.Core.Parse"); refusals
--   (400, 414, 431, 505, and 501 for a method the server does not
--   support) are written with @send_error@'s bytes
--   ("Petrus.Http.Core.Response").
-- * An optional per-connection timeout applies to each socket operation
--   (each receive and each write), like @socket.settimeout@; a timeout
--   drops the connection silently unless the handler catches
--   'ConnectionTimeout'.
module Petrus.Http.Core.Server
  ( -- * Configuration
    ServerConfig (..)
  , defaultServerConfig
  , defaultServerSoftware
  , defaultExceptionReporter

    -- * Lifecycle
  , Server
  , Handler
  , createServer
  , serverPort
  , serverAddress
  , serveForever
  , shutdown
  , serverClose
  , withRunningServer
  , setConnectionTimeout

    -- * Requests
  , Request
  , requestMethod
  , requestPath
  , requestRawTarget
  , requestVersion
  , requestLine
  , requestHeaders
  , requestPeer
  , requestHeader
  , requestHeaderValues
  , readBody

    -- * Responses
  , sendResponse
  , sendError
  , sendBytes

    -- * Connection failures
  , ConnectionTimeout (..)
  , isConnectionError
  , pythonAddress
  ) where

import Control.Concurrent (forkIO, forkIOWithUnmask, threadWaitReadSTM)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Exception
  ( Exception
  , IOException
  , SomeAsyncException
  , SomeException
  , bracket
  , bracketOnError
  , catch
  , displayException
  , finally
  , fromException
  , mask
  , onException
  , throwIO
  , try
  )
import Control.Monad (unless, void, when)
import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Data.Version (showVersion)
import Foreign.C.Error (Errno (..), eCONNABORTED, eCONNREFUSED, eCONNRESET, ePIPE, eSHUTDOWN)
import GHC.IO.Exception (IOException (..))
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (..)
  , Family (..)
  , HostAddress
  , ShutdownCmd (..)
  , SockAddr (..)
  , Socket
  , SocketOption (..)
  , SocketType (..)
  , accept
  , bind
  , close
  , defaultHints
  , getAddrInfo
  , getSocketName
  , hostAddressToTuple
  , listen
  , setSocketOption
  , socket
  , socketPort
  , withFdSocket
  )
import Network.Socket qualified as Socket
import Network.Socket.ByteString (recv, sendAll)
import Paths_petrus_http_core (version)
import Petrus.Http.Core.Parse
  ( Headers
  , RequestLine (..)
  , RequestLineError (..)
  , lookupHeader
  , lookupHeaders
  , maxHeaders
  , maxLineLength
  , parseHeaderBlock
  , parseRequestLine
  )
import Petrus.Http.Core.Response (Response, httpDate, renderError, renderResponse)
import Petrus.Json.Repr (pythonReprText)
import System.IO (hPutStr, stderr)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

-- | How a server is bound and how it treats connections.
data ServerConfig = ServerConfig
  { serverHost :: String
  -- ^ The IPv4 host to bind (@""@ binds every interface, as in Python).
  , serverPortNumber :: Int
  -- ^ 0 picks an ephemeral port ('serverPort' reports it).
  , connectionTimeout :: Maybe Double
  -- ^ Seconds each socket operation on a connection may take (CPython's
  -- per-connection @settimeout@). 'Nothing' waits indefinitely, as the
  -- observation server does. Changeable later with 'setConnectionTimeout';
  -- each connection uses the value current when it is accepted.
  , waitForHandlersOnClose :: Bool
  -- ^ Whether 'serverClose' waits for running handlers
  -- (@block_on_close@ with @daemon_threads = False@, the simulation
  -- server), or returns at once (@daemon_threads = True@, the observation
  -- server).
  , serverSoftware :: ByteString
  -- ^ The @Server@ header value.
  , listenBacklog :: Int
  , supportsMethod :: ByteString -> Bool
  -- ^ Whether a @do_METHOD@ exists. A request for any other method is
  -- answered with @501 Unsupported method ('METHOD')@ without reaching the
  -- handler.
  , reportException :: SockAddr -> SomeException -> IO ()
  -- ^ Called with an exception that escapes the handler (other than
  -- 'ConnectionTimeout'): @handle_error@.
  }

-- | Every interface, an ephemeral port, no timeout, 'serverClose' does not
-- wait, 'defaultServerSoftware', backlog 5, every method supported,
-- 'defaultExceptionReporter'.
defaultServerConfig :: ServerConfig
defaultServerConfig =
  ServerConfig
    { serverHost = ""
    , serverPortNumber = 0
    , connectionTimeout = Nothing
    , waitForHandlersOnClose = False
    , serverSoftware = defaultServerSoftware
    , listenBacklog = 5
    , supportsMethod = const True
    , reportException = defaultExceptionReporter
    }

-- | @petrus-haskell/<version>@: the @Server@ header (CPython's is
-- @BaseHTTP/0.6 Python/3.14.x@).
defaultServerSoftware :: ByteString
defaultServerSoftware = BC.pack ("petrus-haskell/" <> showVersion version)

-- | @socketserver.BaseServer.handle_error@'s report on standard error,
-- with the exception's 'displayException' in place of the traceback.
defaultExceptionReporter :: SockAddr -> SomeException -> IO ()
defaultExceptionReporter peer e =
  hPutStr stderr $
    unlines
      [ dashes
      , "Exception occurred during processing of request from " <> pythonAddress peer
      , displayExceptionText
      , dashes
      ]
  where
    dashes = replicate 40 '-'
    displayExceptionText = displayException e

-- | A peer address as Python prints a client address: @('127.0.0.1', 50000)@.
pythonAddress :: SockAddr -> String
pythonAddress = \case
  SockAddrInet port host -> "('" <> dotted host <> "', " <> show port <> ")"
  other -> show other
  where
    dotted :: HostAddress -> String
    dotted host = let (a, b, c, d) = hostAddressToTuple host in intercalate "." (map show [a, b, c, d])

-- | Handles one request. It writes the response itself ('sendResponse',
-- 'sendError'), may read the body ('readBody'), and may throw: a
-- 'ConnectionTimeout' drops the connection, anything else goes to
-- 'reportException'.
type Handler = Request -> IO ()

-- | A bound, listening server.
data Server = Server
  { serverSocket :: Socket
  , serverSettings :: ServerConfig
  , serverHandler :: Handler
  , serverTimeout :: IORef (Maybe Double)
  , shutdownRequested :: TVar Bool
  , loopRunning :: TVar Bool
  , loopExits :: TVar Int
  , activeHandlers :: TVar Int
  , serverClosed :: IORef Bool
  }

-- | Bind and listen; no thread is started.
createServer :: ServerConfig -> Handler -> IO Server
createServer config handler = do
  let hints = defaultHints {addrFlags = [AI_PASSIVE], addrFamily = AF_INET, addrSocketType = Stream}
      host = if null (serverHost config) then Nothing else Just (serverHost config)
  addresses <- getAddrInfo (Just hints) host (Just (show (serverPortNumber config)))
  address <- case addresses of
    first : _ -> pure first
    [] -> ioError (userError ("no IPv4 address for " <> serverHost config))
  listener <- bracketOnError (socket AF_INET Stream Socket.defaultProtocol) close $ \sock -> do
    setSocketOption sock ReuseAddr 1
    bind sock (addrAddress address)
    listen sock (listenBacklog config)
    pure sock
  Server listener config handler
    <$> newIORef (connectionTimeout config)
    <*> newTVarIO False
    <*> newTVarIO False
    <*> newTVarIO 0
    <*> newTVarIO 0
    <*> newIORef False

-- | The bound port (@server.server_port@).
serverPort :: Server -> IO Int
serverPort server = fromIntegral <$> socketPort (serverSocket server)

-- | The bound address.
serverAddress :: Server -> IO SockAddr
serverAddress server = getSocketName (serverSocket server)

-- | Change the timeout for connections accepted from now on.
setConnectionTimeout :: Server -> Maybe Double -> IO ()
setConnectionTimeout server = writeIORef (serverTimeout server)

-- | Accept connections until 'shutdown', handling each in its own thread.
-- As in CPython, a 'shutdown' requested while no loop runs makes the next
-- 'serveForever' return at once.
serveForever :: Server -> IO ()
serveForever server = mask $ \restore -> do
  atomically (writeTVar (loopRunning server) True)
  fd <- withFdSocket (serverSocket server) (pure . Fd)
  let loop = do
        (readable, unregister) <- threadWaitReadSTM fd
        stop <-
          restore
            ( atomically $
                (True <$ (readTVar (shutdownRequested server) >>= check))
                  <|> (False <$ readable)
            )
            `onException` unregister
        unregister
        unless stop $ do
          accepted <- try (restore (accept (serverSocket server)))
          case accepted of
            Right (connection, peer) -> spawnHandler server connection peer
            Left (_ :: IOException) -> pure ()
          loop
  loop `finally` atomically do
    writeTVar (loopRunning server) False
    writeTVar (shutdownRequested server) False
    modifyTVar' (loopExits server) (+ 1)

-- | Stop 'serveForever' and wait until it has returned. Returns at once
-- when no loop is running.
shutdown :: Server -> IO ()
shutdown server = do
  (running, exits) <- atomically do
    writeTVar (shutdownRequested server) True
    (,) <$> readTVar (loopRunning server) <*> readTVar (loopExits server)
  when running . atomically $
    readTVar (loopExits server) >>= check . (/= exits)

-- | Close the listening socket; with 'waitForHandlersOnClose', then wait
-- for every running handler. Call after 'shutdown'. Idempotent.
serverClose :: Server -> IO ()
serverClose server = do
  alreadyClosed <- atomicModifyIORef' (serverClosed server) (True,)
  unless alreadyClosed (close (serverSocket server))
  when (waitForHandlersOnClose (serverSettings server)) . atomically $
    readTVar (activeHandlers server) >>= check . (== 0)

-- | Create a server, run 'serveForever' in a thread, run the action, then
-- 'shutdown' and 'serverClose'.
withRunningServer :: ServerConfig -> Handler -> (Server -> IO a) -> IO a
withRunningServer config handler action =
  bracket (createServer config handler) serverClose $ \server ->
    bracket (forkIO (serveForever server)) (const (shutdownLoop server)) (const (action server))
  where
    -- The loop may not have started yet; wait for it to run or the
    -- shutdown request would linger.
    shutdownLoop server = do
      atomically (readTVar (loopRunning server) >>= check)
      shutdown server

spawnHandler :: Server -> Socket -> SockAddr -> IO ()
spawnHandler server connection peer = do
  atomically (modifyTVar' (activeHandlers server) (+ 1))
  seconds <- readIORef (serverTimeout server)
  let finished = do
        closeConnection connection
        atomically (modifyTVar' (activeHandlers server) (subtract 1))
  void $ forkIOWithUnmask \unmask ->
    (unmask (handleConnection server connection peer seconds) `catch` \(_ :: SomeException) -> pure ())
      `finally` finished

-- @shutdown_request@: shut down for writing, then close.
closeConnection :: Socket -> IO ()
closeConnection connection = do
  Socket.shutdown connection ShutdownSend `catch` \(_ :: IOException) -> pure ()
  close connection

handleConnection :: Server -> Socket -> SockAddr -> Maybe Double -> IO ()
handleConnection server connection peer seconds = do
  buffer <- newIORef BS.empty
  let conn =
        Conn
          { connSocket = connection
          , connBuffer = buffer
          , connTimeout = (\s -> max 0 (ceiling (s * 1e6))) <$> seconds
          , connSoftware = serverSoftware (serverSettings server)
          }
  outcome <- try (handleOneRequest server conn peer)
  case outcome of
    Right () -> pure ()
    Left e
      | Just ConnectionTimeout <- fromException e -> pure ()
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | otherwise ->
          reportException (serverSettings server) peer e
            `catch` \(_ :: SomeException) -> pure ()

-- @handle_one_request@ with @close_connection@ always true.
handleOneRequest :: Server -> Conn -> SockAddr -> IO ()
handleOneRequest server conn peer = do
  raw <- readLineLimited conn (maxLineLength + 1)
  if
    | BS.length raw > maxLineLength -> sendErrorOn conn "" "" 414 Nothing Nothing
    | BS.null raw -> pure ()
    | otherwise -> case parseRequestLine raw of
        Nothing -> pure ()
        Just (Left refusal) ->
          sendErrorOn conn (lineErrorVersion refusal) "" (lineErrorStatus refusal) (Just (lineErrorMessage refusal)) Nothing
        Just (Right line) -> do
          block <- if lineSimple line then pure (Right []) else readHeaderBlock conn
          case block of
            Left (message, explain) ->
              sendErrorOn conn (lineVersion line) (lineCommand line) 431 (Just message) (Just explain)
            Right headers -> do
              let request =
                    Request
                      { requestMethod = lineCommand line
                      , requestPath = linePath line
                      , requestRawTarget = lineRawTarget line
                      , requestVersion = lineVersion line
                      , requestLine = lineText line
                      , requestHeaders = headers
                      , requestPeer = peer
                      , requestConn = conn
                      }
              if supportsMethod (serverSettings server) (lineCommand line)
                then serverHandler server request
                else
                  sendError
                    request
                    501
                    (Just ("Unsupported method (" <> T.pack (pythonReprText (TE.decodeLatin1 (lineCommand line))) <> ")"))
                    Nothing

-- @http.client.parse_headers@: read lines up to and including the blank
-- line (or end of input), refusing long lines and too many of them.
readHeaderBlock :: Conn -> IO (Either (Text, Text) Headers)
readHeaderBlock conn = go (0 :: Int) []
  where
    go count lines' = do
      line <- readLineLimited conn (maxLineLength + 1)
      let count' = count + 1
          lines'' = line : lines'
      if
        | BS.length line > maxLineLength ->
            pure (Left ("Line too long", "got more than " <> T.pack (show maxLineLength) <> " bytes when reading header line"))
        | count' > maxHeaders ->
            pure (Left ("Too many headers", "got more than " <> T.pack (show maxHeaders) <> " headers"))
        | line == "\r\n" || line == "\n" || BS.null line ->
            pure (Right (parseHeaderBlock (BS.concat (reverse lines''))))
        | otherwise -> go count' lines''

-- | A request that passed CPython's checks.
data Request = Request
  { requestMethod :: ByteString
  -- ^ The method token as sent (@self.command@).
  , requestPath :: ByteString
  -- ^ The target with a leading run of slashes reduced to one
  -- (@self.path@).
  , requestRawTarget :: ByteString
  -- ^ The target exactly as sent (the request line's second word).
  , requestVersion :: ByteString
  -- ^ @HTTP/1.0@, @HTTP/1.1@…, or @HTTP/0.9@, in which case responses
  -- are written without status line and headers.
  , requestLine :: ByteString
  -- ^ The request line without its line ending.
  , requestHeaders :: Headers
  -- ^ Header fields in order, as parsed by the @email@ compat32 parser
  -- (empty for a two-word HTTP/0.9 request).
  , requestPeer :: SockAddr
  , requestConn :: Conn
  }

-- | @self.headers.get(name)@: the first value, name compared
-- case-insensitively.
requestHeader :: ByteString -> Request -> Maybe ByteString
requestHeader name = lookupHeader name . requestHeaders

-- | @self.headers.get_all(name)@ (an empty list for none).
requestHeaderValues :: ByteString -> Request -> [ByteString]
requestHeaderValues name = lookupHeaders name . requestHeaders

-- | @self.rfile.read(n)@: the next @n@ body bytes, fewer only when the
-- client closed its side first; a negative count reads to the end of the
-- input. Throws 'ConnectionTimeout' when a receive times out.
readBody :: Request -> Int -> IO ByteString
readBody request wanted = readExactly (requestConn request) wanted

-- | Write a response ('renderResponse' with this server's @Server@ value
-- and the current @Date@). Throws 'ConnectionTimeout' when the write times
-- out and an 'IOException' when the client is gone ('isConnectionError').
sendResponse :: Request -> Response -> IO ()
sendResponse request resp = do
  let conn = requestConn request
  date <- httpDate <$> getCurrentTime
  sendBytes request (renderResponse (connSoftware conn) date (requestVersion request) resp)

-- | @self.send_error(code, message, explain)@ ('renderError').
sendError :: Request -> Int -> Maybe Text -> Maybe Text -> IO ()
sendError request = sendErrorOn (requestConn request) (requestVersion request) (requestMethod request)

-- | @self.wfile.write(bytes)@.
sendBytes :: Request -> ByteString -> IO ()
sendBytes request = writeAll (requestConn request)

-- | A socket operation exceeded the connection timeout (CPython's
-- @TimeoutError@).
data ConnectionTimeout = ConnectionTimeout
  deriving stock (Eq, Show)

instance Exception ConnectionTimeout

-- | Whether an exception is one of CPython's @ConnectionError@s: broken
-- pipe, connection reset, aborted or refused (or a socket shut down).
isConnectionError :: SomeException -> Bool
isConnectionError e = case fromException e of
  Just IOError {ioe_errno = Just errno} -> Errno errno `elem` [ePIPE, eCONNRESET, eCONNABORTED, eCONNREFUSED, eSHUTDOWN]
  _ -> False

-- Connection I/O --------------------------------------------------------

data Conn = Conn
  { connSocket :: Socket
  , connBuffer :: IORef ByteString
  , connTimeout :: Maybe Int
  , connSoftware :: ByteString
  }

-- The size CPython's buffered reader asks the socket for
-- (io.DEFAULT_BUFFER_SIZE in 3.14).
receiveSize :: Int
receiveSize = 131072

withTimeout :: Conn -> IO a -> IO a
withTimeout conn action = case connTimeout conn of
  Nothing -> action
  Just micros -> timeout micros action >>= maybe (throwIO ConnectionTimeout) pure

receive :: Conn -> IO ByteString
receive conn = withTimeout conn (recv (connSocket conn) receiveSize)

writeAll :: Conn -> ByteString -> IO ()
writeAll conn bytes = withTimeout conn (sendAll (connSocket conn) bytes)

-- readline(limit): through the next LF, at most limit bytes, or what is
-- left at the end of input.
readLineLimited :: Conn -> Int -> IO ByteString
readLineLimited conn limit = readIORef (connBuffer conn) >>= go 0
  where
    -- Bytes before 'searched' are known to hold no LF.
    go searched buffered =
      case BS.elemIndex 10 (BS.drop searched (BS.take limit buffered)) of
        Just i -> emit (searched + i + 1) buffered
        Nothing
          | BS.length buffered >= limit -> emit limit buffered
          | otherwise -> do
              chunk <- receive conn
              if BS.null chunk
                then emit (BS.length buffered) buffered
                else go (BS.length buffered) (buffered <> chunk)
    emit n buffered = do
      let (line, rest) = BS.splitAt n buffered
      writeIORef (connBuffer conn) rest
      pure line

readExactly :: Conn -> Int -> IO ByteString
readExactly conn wanted = do
  buffered <- readIORef (connBuffer conn)
  if wanted >= 0 && BS.length buffered >= wanted
    then do
      let (body, rest) = BS.splitAt wanted buffered
      writeIORef (connBuffer conn) rest
      pure body
    else do
      writeIORef (connBuffer conn) BS.empty
      let go have chunks
            | wanted >= 0 && have >= wanted = finish chunks
            | otherwise = do
                chunk <- receive conn
                if BS.null chunk
                  then finish chunks
                  else go (have + BS.length chunk) (chunk : chunks)
          finish chunks = do
            let everything = BS.concat (reverse chunks)
            if wanted < 0
              then pure everything
              else do
                let (body, rest) = BS.splitAt wanted everything
                writeIORef (connBuffer conn) rest
                pure body
      go (BS.length buffered) [buffered]

sendErrorOn :: Conn -> ByteString -> ByteString -> Int -> Maybe Text -> Maybe Text -> IO ()
sendErrorOn conn requestVersion' command status message explain = do
  date <- httpDate <$> getCurrentTime
  writeAll conn (renderError (connSoftware conn) date requestVersion' command status message explain)
