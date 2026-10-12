-- | What uvicorn 0.52 (the reference's server, @uvicorn.run(app, host=...,
-- port=...)@ with its defaults) does around the application, besides the
-- HTTP bytes ("Hamsterdan.Host.Api" writes those):
--
-- * its log lines, as @LOGGING_CONFIG@ formats them: the server's own
--   messages on stderr (@%(levelprefix)s %(message)s@) and one access line
--   per response on stdout (@%(levelprefix)s %(client_addr)s -
--   "%(request_line)s" %(status_code)s@), with ANSI colors when stdout is a
--   terminal ('UvicornLog', 'accessLog');
-- * @ProxyHeadersMiddleware@ over @FORWARDED_ALLOW_IPS@ (default
--   @127.0.0.1@): a trusted peer's @X-Forwarded-For@ becomes the client the
--   access line names, and its @X-Forwarded-Proto@ the scheme the
--   application's redirects carry ('proxyHeaders', 'requestScope');
-- * asyncio's @create_server@: every address of the host bound (IPv6 ones
--   IPv6-only), and the bind failure it reports ('bindServer').
module Hamsterdan.Host.Uvicorn
  ( -- * Logging
    UvicornLog (..)
  , Level (..)
  , Message (..)
  , plainMessage
  , logMessage
  , formatLine
  , Color (..)
  , style

    -- * The server's messages
  , startedMessage
  , finishedMessage
  , runningMessage
  , tracebackMessage
  , asgiFailureMessage

    -- * The access log
  , accessLog
  , accessLine
  , statusPhrase
  , logPath

    -- * Proxy headers
  , Scope (..)
  , requestScope
  , proxyHeaders
  , TrustedHosts
  , trustedHosts
  , isTrusted
  , trustedClientAddress
  , parseHostPort

    -- * Binding
  , BindFailure (..)
  , bindServer
  ) where

import Control.Exception (IOException, bracketOnError, try)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum, isAscii)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vault.Lazy qualified as Vault
import Foreign.C.Error (Errno (..), eADDRNOTAVAIL)
import GHC.IO.Exception (IOException (..))
import Hamsterdan.Host.Uvicorn.IpAddress (inNetwork, ipAddress, ipNetwork)
import Hamsterdan.Host.Uvicorn.IpAddress qualified as Ip
import Network.HTTP.Types (Status (..), urlDecode)
import Network.Socket
import Network.Wai (Middleware, Request, httpVersion, rawPathInfo, rawQueryString, remoteHost, requestHeaders, requestMethod, responseStatus, vault)
import Petrus.Json.Python (decodeUtf8Replace, parsePythonInt, pythonStrRepr, pythonStrip)
import Petrus.Posix.Netdb (gaiErrorCode)
import System.IO (Handle, hFlush)
import System.IO.Unsafe (unsafePerformIO)
import Text.Printf (printf)

-- ---------------------------------------------------------------------------
-- Logging

-- | @LOGGING_CONFIG@'s two handlers and the formatters' @use_colors@
-- (@None@, so @sys.stdout.isatty()@ for both).
data UvicornLog = UvicornLog
  { errors :: Handle
  -- ^ The @default@ handler's stream (@sys.stderr@): the @uvicorn.error@
  -- logger.
  , access :: Handle
  -- ^ The @access@ handler's stream (@sys.stdout@): @uvicorn.access@.
  , colors :: Bool
  }

data Level = Info | Warning | Error
  deriving stock (Eq, Show)

-- | A log message and, where uvicorn passes one, its @color_message@.
data Message = Message
  { plain :: Text
  , colored :: Text
  }
  deriving stock (Eq, Show)

plainMessage :: Text -> Message
plainMessage text = Message text text

-- | @uvicorn._ansi@'s colors.
data Color = Red | Green | Yellow | Cyan | BrightRed | BrightWhite
  deriving stock (Eq, Show)

colorCode :: Color -> Int
colorCode = \case
  Red -> 31
  Green -> 32
  Yellow -> 33
  Cyan -> 36
  BrightRed -> 91
  BrightWhite -> 97

-- | @uvicorn._ansi.style(text, fg=..., bold=...)@.
style :: Maybe Color -> Bool -> Text -> Text
style fg bold text =
  maybe "" (\c -> "\ESC[" <> tshow (colorCode c) <> "m") fg
    <> (if bold then "\ESC[1m" else "")
    <> text
    <> "\ESC[0m"

-- | @ColourizedFormatter@'s @levelprefix@: the level name (colored), a
-- colon, and padding to nine columns.
levelPrefix :: Bool -> Level -> Text
levelPrefix colors level =
  (if colors then style (Just color) False name else name) <> ":" <> T.replicate (8 - T.length name) " "
  where
    (name, color) = case level of
      Info -> ("INFO", Green)
      Warning -> ("WARNING", Yellow)
      Error -> ("ERROR", Red)

-- | @DefaultFormatter@ over @%(levelprefix)s %(message)s@.
formatLine :: Bool -> Level -> Message -> Text
formatLine colors level message =
  levelPrefix colors level <> " " <> (if colors then message.colored else message.plain)

-- | One record through the @default@ handler: the formatted line, a
-- newline, a flush (@StreamHandler.emit@).
logMessage :: UvicornLog -> Level -> Message -> IO ()
logMessage log' level message = emit log'.errors (formatLine log'.colors level message)

emit :: Handle -> Text -> IO ()
emit handle line = BS.hPut handle (TE.encodeUtf8 (line <> "\n")) >> hFlush handle

-- ---------------------------------------------------------------------------
-- The server's messages

startedMessage, finishedMessage :: Int -> Message
startedMessage = processMessage "Started"
finishedMessage = processMessage "Finished"

processMessage :: Text -> Int -> Message
processMessage verb pid =
  Message
    (verb <> " server process [" <> tshow pid <> "]")
    (verb <> " server process [" <> style (Just Cyan) False (tshow pid) <> "]")

-- | @Server._log_started_message@ for a host and port: the host as given,
-- in brackets when it holds a colon.
runningMessage :: Text -> Int -> Message
runningMessage host port =
  Message
    ("Uvicorn running on " <> address <> " (Press CTRL+C to quit)")
    ("Uvicorn running on " <> style Nothing True address <> " (Press CTRL+C to quit)")
  where
    address = "http://" <> (if ":" `T.isInfixOf` host then "[" <> host <> "]" else host) <> ":" <> tshow port

-- | What uvicorn logs for a lifespan failure: Starlette's
-- @traceback.format_exc()@, reduced to its header and its last line (the
-- exception, as the command line prints an uncaught one). @format_exc@ ends
-- in a newline, so the logged record ends in a blank line.
tracebackMessage :: Text -> Message
tracebackMessage lastLine = plainMessage ("Traceback (most recent call last):\n" <> lastLine <> "\n")

-- | What uvicorn logs for an exception the application raises:
-- @logger.error("Exception in ASGI application\\n", exc_info=exc)@, the
-- traceback reduced as in 'tracebackMessage'. Logging formats @exc_info@
-- without its final newline.
asgiFailureMessage :: Text -> Message
asgiFailureMessage lastLine = plainMessage ("Exception in ASGI application\nTraceback (most recent call last):\n" <> lastLine)

-- ---------------------------------------------------------------------------
-- The access log

-- | @http.HTTPStatus(code).phrase@ (CPython 3.14).
statusPhrase :: Int -> Maybe Text
statusPhrase code = lookup code phrases
  where
    phrases =
      [ (100, "Continue"), (101, "Switching Protocols"), (102, "Processing"), (103, "Early Hints")
      , (200, "OK"), (201, "Created"), (202, "Accepted"), (203, "Non-Authoritative Information")
      , (204, "No Content"), (205, "Reset Content"), (206, "Partial Content"), (207, "Multi-Status")
      , (208, "Already Reported"), (226, "IM Used")
      , (300, "Multiple Choices"), (301, "Moved Permanently"), (302, "Found"), (303, "See Other")
      , (304, "Not Modified"), (305, "Use Proxy"), (307, "Temporary Redirect"), (308, "Permanent Redirect")
      , (400, "Bad Request"), (401, "Unauthorized"), (402, "Payment Required"), (403, "Forbidden")
      , (404, "Not Found"), (405, "Method Not Allowed"), (406, "Not Acceptable")
      , (407, "Proxy Authentication Required"), (408, "Request Timeout"), (409, "Conflict"), (410, "Gone")
      , (411, "Length Required"), (412, "Precondition Failed"), (413, "Content Too Large")
      , (414, "URI Too Long"), (415, "Unsupported Media Type"), (416, "Range Not Satisfiable")
      , (417, "Expectation Failed"), (418, "I'm a Teapot"), (421, "Misdirected Request")
      , (422, "Unprocessable Content"), (423, "Locked"), (424, "Failed Dependency"), (425, "Too Early")
      , (426, "Upgrade Required"), (428, "Precondition Required"), (429, "Too Many Requests")
      , (431, "Request Header Fields Too Large"), (451, "Unavailable For Legal Reasons")
      , (500, "Internal Server Error"), (501, "Not Implemented"), (502, "Bad Gateway")
      , (503, "Service Unavailable"), (504, "Gateway Timeout"), (505, "HTTP Version Not Supported")
      , (506, "Variant Also Negotiates"), (507, "Insufficient Storage"), (508, "Loop Detected")
      , (510, "Not Extended"), (511, "Network Authentication Required")
      ]

-- | @AccessFormatter@ over its format: the client (@"%s:%d" % client@, or
-- empty), the request line (bold), and the status with its phrase
-- (colored by class).
accessLine :: Bool -> Text -> Text -> Text -> Text -> Int -> Text
accessLine colors client method path version status =
  levelPrefix colors Info <> " " <> client <> " - \"" <> requestLine <> "\" " <> statusText
  where
    line = method <> " " <> path <> " HTTP/" <> version
    requestLine = if colors then style Nothing True line else line
    statusAndPhrase = tshow status <> " " <> fromMaybe "" (statusPhrase status)
    statusText
      | colors, Just color <- lookup (status `div` 100) classColors = style (Just color) False statusAndPhrase
      | otherwise = statusAndPhrase
    classColors = [(1, BrightWhite), (2, Green), (3, Yellow), (4, Red), (5, BrightRed)]

-- | @get_path_with_query_string(scope)@ over h11's scope:
-- @quote(unquote(raw_path))@, then the query string after a @?@ when there
-- is one.
logPath :: Request -> Text
logPath request = quote (decodeUtf8Replace (urlDecode False (rawPathInfo request))) <> query
  where
    queryString = BS.drop 1 (rawQueryString request)
    query = if BS.null queryString then "" else "?" <> TE.decodeLatin1 queryString
    -- @urllib.parse.quote(text, safe="/")@.
    quote = T.concatMap $ \c ->
      if isAscii c && (isAlphaNum c || c `elem` ("_.-~/" :: String))
        then T.singleton c
        else T.concat [T.pack (printf "%%%02X" b) | b <- BS.unpack (TE.encodeUtf8 (T.singleton c))]

-- | Log one access line per response, as the response starts (h11's
-- @RequestResponseCycle.send@), for the client of the request's 'Scope'.
accessLog :: UvicornLog -> Middleware
accessLog log' app request send =
  app request $ \response -> do
    let scope = requestScope request
        client = maybe "" (\(host, port) -> host <> ":" <> tshow port) scope.client
        version = tshow (httpVersion request)
        line =
          accessLine
            log'.colors
            client
            (TE.decodeLatin1 (requestMethod request))
            (logPath request)
            (T.drop 5 version)
            (statusCode (responseStatus response))
    emit log'.access line
    send response

-- ---------------------------------------------------------------------------
-- Proxy headers

-- | The parts of the ASGI scope that @ProxyHeadersMiddleware@ rewrites.
data Scope = Scope
  { client :: Maybe (Text, Integer)
  , scheme :: Text
  }
  deriving stock (Eq, Show)

scopeKey :: Vault.Key Scope
scopeKey = unsafePerformIO Vault.newKey
{-# NOINLINE scopeKey #-}

-- | The request's scope as 'proxyHeaders' left it; without that
-- middleware, no client and @http@.
requestScope :: Request -> Scope
requestScope request = fromMaybe (Scope Nothing "http") (Vault.lookup scopeKey (vault request))

-- | @_TrustedHosts@: everything (@*@), or addresses, networks and literal
-- strings.
data TrustedHosts
  = AlwaysTrust
  | Trusted Trust
  deriving stock (Eq, Show)

data Trust = Trust
  { literals :: Set Text
  , addresses :: Set Ip.IpAddress
  , networks :: [Ip.IpNetwork]
  }
  deriving stock (Eq, Show)

-- | @_TrustedHosts(value)@ for a @FORWARDED_ALLOW_IPS@ string: comma
-- separated and stripped; an entry with a slash is a network if
-- @ip_network@ takes it, any other an address if @ip_address@ does, and
-- the rest literals.
trustedHosts :: Text -> TrustedHosts
trustedHosts value
  | value == "*" = AlwaysTrust
  | otherwise = Trusted (foldr add (Trust Set.empty Set.empty []) (rawHosts value))
  where
    add host trusted
      | "/" `T.isInfixOf` host = maybe literal (\n -> trusted {networks = n : trusted.networks}) (ipNetwork host)
      | otherwise = maybe literal (\a -> trusted {addresses = Set.insert a trusted.addresses}) (ipAddress host)
      where
        literal = trusted {literals = Set.insert host trusted.literals}

-- | @_parse_raw_hosts@.
rawHosts :: Text -> [Text]
rawHosts = map pythonStrip . T.splitOn ","

-- | @host in trusted_hosts@ (@None@ and the empty string are never trusted,
-- unless everything is).
isTrusted :: TrustedHosts -> Maybe Text -> Bool
isTrusted AlwaysTrust _ = True
isTrusted (Trusted trusted) host = case host of
  Nothing -> False
  Just "" -> False
  Just h -> case ipAddress h of
    Just ip -> Set.member ip trusted.addresses || any (inNetwork ip) trusted.networks
    Nothing -> Set.member h trusted.literals

-- | @get_trusted_client_address@: the last untrusted entry of an
-- @X-Forwarded-For@ list, else its first.
trustedClientAddress :: TrustedHosts -> Text -> (Text, Integer)
trustedClientAddress trusted forwarded = case trusted of
  AlwaysTrust -> firstEntry
  _ -> fromMaybe firstEntry (find (not . isTrusted trusted . Just . fst) (map parseHostPort (reverse entries)))
  where
    entries = rawHosts forwarded
    firstEntry = parseHostPort (case entries of e : _ -> e; [] -> "")

-- | @_parse_host_port@: @[v6]:port@, @host:port@ (exactly one colon), or a
-- bare value with port 0; a port that @int()@ refuses is 0.
parseHostPort :: Text -> (Text, Integer)
parseHostPort value
  | Just rest <- T.stripPrefix "[" value = case T.breakOn "]" rest of
      (_, "") -> (value, 0)
      (host, closing) ->
        let remainder = T.drop 1 closing
         in if T.null remainder
              then (host, 0)
              else case T.stripPrefix ":" remainder of
                Nothing -> (value, 0)
                Just port -> (host, fromMaybe 0 (pythonInt port))
  | T.count ":" value == 1
  , (host, port) <- T.breakOnEnd ":" value =
      maybe (value, 0) (\n -> (T.dropEnd 1 host, n)) (pythonInt port)
  | otherwise = (value, 0)
  where
    -- @int(text)@, with its 4300-digit conversion limit.
    pythonInt text = do
      n <- parsePythonInt 10 text
      unless (T.length (T.filter (`notElem` ("_+-" :: String)) (pythonStrip text)) <= 4300) Nothing
      Just n

-- | @ProxyHeadersMiddleware@: for a trusted peer, the last
-- @X-Forwarded-Proto@ (stripped) when it is @http@, @https@, @ws@ or @wss@
-- becomes the scheme, and the @X-Forwarded-For@ values (joined with
-- @", "@) name the client when they name a host.
proxyHeaders :: TrustedHosts -> Middleware
proxyHeaders trusted app request send = do
  peer <- peerAddress (remoteHost request)
  let base = Scope {client = peer, scheme = "http"}
      scope
        | isTrusted trusted (fst <$> peer) = forwarded base
        | otherwise = base
  app request {vault = Vault.insert scopeKey scope (vault request)} send
  where
    headers = requestHeaders request
    forwarded base =
      let proto = case reverse [v | (n, v) <- headers, n == "x-forwarded-proto"] of
            v : _ -> Just (pythonStrip (TE.decodeLatin1 v))
            [] -> Nothing
          withScheme = case proto of
            Just p | p `elem` ["http", "https", "ws", "wss"] -> base {scheme = p}
            _ -> base
       in case [v | (n, v) <- headers, n == "x-forwarded-for"] of
            [] -> withScheme
            values -> case trustedClientAddress trusted (TE.decodeLatin1 (BS.intercalate ", " values)) of
              ("", _) -> withScheme
              address -> withScheme {client = Just address}

-- | @transport.get_extra_info("socket").getpeername()@'s host and port
-- (@inet_ntop@'s text, no scope id).
peerAddress :: SockAddr -> IO (Maybe (Text, Integer))
peerAddress = \case
  SockAddrInet port host ->
    let (a, b, c, d) = hostAddressToTuple host
     in pure (Just (T.intercalate "." (map tshow [a, b, c, d]), toInteger port))
  address@(SockAddrInet6 port _ _ _) -> do
    (host, _) <- getNameInfo [NI_NUMERICHOST] True False address
    pure (fmap (\h -> (T.takeWhile (/= '%') (T.pack h), toInteger port)) host)
  SockAddrUnix _ -> pure Nothing

-- ---------------------------------------------------------------------------
-- Binding

-- | What asyncio raises when @create_server@ cannot bind: an @OSError@
-- (or @socket.gaierror@), as the @str()@ uvicorn logs.
newtype BindFailure = BindFailure Text
  deriving stock (Eq, Show)

-- | @loop.create_server(host=host, port=port)@ as uvicorn calls it: every
-- address @getaddrinfo@ gives (an empty host: every interface), each
-- socket with @SO_REUSEADDR@ (IPv6 ones @IPV6_V6ONLY@) bound and listening
-- with uvicorn's backlog of 2048. An address the system lacks
-- (@EADDRNOTAVAIL@) is skipped. A failure is a 'BindFailure' with asyncio's
-- message; the sockets bound before it are closed.
bindServer :: String -> Int -> IO (Either BindFailure [Socket])
bindServer host port = do
  resolved <- try (getAddrInfo (Just hints) (if null host then Nothing else Just host) (Just (show port)))
  case resolved of
    Left (e :: IOException) -> Left <$> gaiFailure e
    Right infos -> do
      let unique = dedupe infos
      bound <- go unique []
      case bound of
        Left failure -> pure (Left failure)
        Right [] -> do
          addresses <- mapM (addressRepr . addrAddress) unique
          pure (Left (BindFailure ("could not bind on any address out of [" <> T.intercalate ", " addresses <> "]")))
        Right sockets -> Right sockets <$ mapM_ (`listen` 2048) sockets
  where
    hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
    dedupe = foldr (\i acc -> if any (sameInfo i) acc then acc else i : acc) [] . reverse
    sameInfo a b = addrFamily a == addrFamily b && addrAddress a == addrAddress b && addrProtocol a == addrProtocol b
    go [] bound = pure (Right (reverse bound))
    go (info : rest) bound = do
      outcome <-
        bracketOnError (socket (addrFamily info) (addrSocketType info) (addrProtocol info)) close $ \s -> do
          withFdSocket s setCloseOnExecIfNeeded
          setSocketOption s ReuseAddr 1
          case addrFamily info of
            AF_INET6 -> setSocketOption s IPv6Only 1
            _ -> pure ()
          attempt <- try (bind s (addrAddress info))
          case attempt of
            Right () -> pure (Right s)
            Left e -> close s >> pure (Left e)
      case outcome of
        Right s -> go rest (s : bound)
        Left e
          | Errno code <- eADDRNOTAVAIL, ioe_errno e == Just code -> go rest bound
          | otherwise -> do
              mapM_ close bound
              address <- addressRepr (addrAddress info)
              let code = maybe 0 fromIntegral (ioe_errno e) :: Int
                  message = "[errno " <> tshow code <> "] " <> T.toLower (T.pack (ioe_description e))
              pure . Left . BindFailure $
                "[Errno " <> tshow code <> "] error while attempting to bind on address " <> address <> ": " <> message

-- | @socket.gaierror@'s @str()@: @[Errno code] message@, the code being
-- the @EAI_*@ one whose @gai_strerror@ is the failure's message.
gaiFailure :: IOException -> IO BindFailure
gaiFailure e = do
  let message = ioe_description e
  code <- gaiErrorCode message
  pure . BindFailure $ case code of
    Just number -> "[Errno " <> tshow number <> "] " <> T.pack message
    Nothing -> T.pack message

-- | The @repr@ of a socket address as Python gives it: @('host', port)@,
-- or @('host', port, flowinfo, scope_id)@ for IPv6.
addressRepr :: SockAddr -> IO Text
addressRepr = \case
  SockAddrInet port host ->
    let (a, b, c, d) = hostAddressToTuple host
     in pure ("(" <> pythonStrRepr (T.intercalate "." (map tshow [a, b, c, d])) <> ", " <> tshow port <> ")")
  SockAddrInet6 port flow host6 scope -> do
    (host, _) <- getNameInfo [NI_NUMERICHOST] True False (SockAddrInet6 0 0 host6 0)
    let text = T.takeWhile (/= '%') (T.pack (fromMaybe "" host))
    pure ("(" <> pythonStrRepr text <> ", " <> tshow port <> ", " <> tshow flow <> ", " <> tshow scope <> ")")
  SockAddrUnix path -> pure (pythonStrRepr (T.pack path))

tshow :: (Show a) => a -> Text
tshow = T.pack . show
