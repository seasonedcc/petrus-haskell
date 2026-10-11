{-# LANGUAGE MultiWayIf #-}

-- | Simulation HTTP profile 1: a port of @petrus.simulation_http@, the
-- strict host-owned transport for one fixed bounded simulation build, on
-- "Petrus.Http.Core", byte for byte.
--
-- > server <- createSimulationServer built "127.0.0.1" 0 "http://localhost:5173"
-- > _ <- forkIO (serveForever (simulationHttp server))
-- > …
-- > shutdownSimulationServer server   -- refuses new simulations, stops the loop
-- > closeSimulationServer server      -- waits for running requests
--
-- Routes: @GET /v1/simulation-profile@ (the profile, captured before
-- binding) and @POST /v1/simulations@ (one run of the fixed build), each
-- with @OPTIONS@. Every request needs the configured exact @Origin@ and an
-- origin-form target without query; every method token is dispatched (no
-- 501). Requests are framed strictly (one @Content-Type@ of
-- @application/json@, one decimal @Content-Length@ up to 1,048,576, no
-- @Expect@ or encodings), decoded strictly, and checked against the fixed
-- definition before the one simulation slot is taken; the slot is released
-- before the response is written.
module Petrus.Simulation.Http
  ( -- * Servers
    SimulationServer
  , simulationHttp
  , simulationServerProfile
  , simulationServerProfileBytes
  , createSimulationServer
  , createSimulationServerWith
  , SimulationServerConfig (..)
  , simulationServerConfig
  , SimulationServerError (..)
  , shutdownSimulationServer
  , closeSimulationServer
  , withSimulationServer

    -- * Pieces
  , validateOrigin
  , decodeMarking
  , simulationPath
  , profilePath

    -- * Serving (re-exported from "Petrus.Http.Core")
  , serveForever
  , serverPort
  , serverAddress
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newMVar, withMVar, modifyMVar_)
import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, readTVar, writeTVar)
import Control.Exception (Exception (..), SomeAsyncException, SomeException, bracket, catch, finally, throwIO, try)
import Control.Monad (unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAscii, isAsciiLower, isAsciiUpper, isDigit, ord)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Http.Core
  ( ConnectionTimeout (..)
  , Handler
  , Request
  , Server
  , ServerConfig (..)
  , createServer
  , defaultServerConfig
  , isConnectionError
  , readBody
  , requestHeaderValues
  , requestMethod
  , requestRawTarget
  , requestSimple
  , response
  , sendResponse
  , serveForever
  , serverAddress
  , serverClose
  , serverPort
  , shutdown
  )
import Petrus.Http.Core.Url (SplitResult (..), ipv4Address, ipv6Address, splitHostname, splitPassword, splitPort, splitUsername, urlsplit)
import Petrus.Impetus.Dsl (BuiltNet)
import Petrus.Impetus.Petrinet (Marking, Token (..), markingFromList, netPath)
import Petrus.Json (Json (..), canonicalText, parseJson, strictLoads, typeExactEq)
import Petrus.Json.Python (pythonStrListRepr)
import Petrus.Simulation (SimulationError (..), simulate, simulationProfile)

-- ---------------------------------------------------------------------------
-- Configuration

-- | How a simulation server is built.
data SimulationServerConfig = SimulationServerConfig
  { host :: String
  , port :: Int
  -- ^ 0 picks an ephemeral port.
  , allowedOrigin :: Text
  -- ^ The one exact HTTP(S) origin every request must carry
  -- ('validateOrigin').
  , connectionTimeout :: Maybe Double
  -- ^ Seconds per socket operation (@CONNECTION_TIMEOUT_SECONDS@, 5).
  , runner :: BuiltNet -> Marking -> Int -> IO (Either SimulationError ByteString)
  -- ^ The simulation run ('simulate'); tests substitute it as the
  -- reference's tests replace @simulation_http.simulate@.
  }

-- | 'createSimulationServer''s configuration.
simulationServerConfig :: String -> Int -> Text -> SimulationServerConfig
simulationServerConfig host port origin =
  SimulationServerConfig
    { host = host
    , port = port
    , allowedOrigin = origin
    , connectionTimeout = Just 5
    , runner = simulate
    }

-- | Why no server was created: the reference's @ValueError@s.
data SimulationServerError
  = -- | The allowed origin is not one exact absolute HTTP(S) origin.
    OriginRefused Text
  | -- | The build is outside @implementation-free-v1@
    -- (@SimulationProfileError@), or could not be profiled.
    BuildRefused SimulationError
  deriving stock (Eq, Show)

instance Exception SimulationServerError

-- | A bound simulation server over one admitted build.
data SimulationServer = SimulationServer
  { http :: Server
  , profile :: Json
  , profileBytes :: ByteString
  , admission :: MVar Bool
  -- ^ @_admission_lock@ around @_shutting_down@.
  , slot :: TVar Bool
  -- ^ Whether the one simulation slot is taken.
  }

-- | The underlying "Petrus.Http.Core" server (for 'serveForever',
-- 'serverPort' and 'serverAddress').
simulationHttp :: SimulationServer -> Server
simulationHttp server = server.http

-- | @server.profile@: the profile served at @/v1/simulation-profile@.
simulationServerProfile :: SimulationServer -> Json
simulationServerProfile server = server.profile

-- | The exact bytes served at @/v1/simulation-profile@.
simulationServerProfileBytes :: SimulationServer -> ByteString
simulationServerProfileBytes server = server.profileBytes

profilePath, simulationPath :: ByteString
profilePath = "/v1/simulation-profile"
simulationPath = "/v1/simulations"

-- | @create_simulation_server(built, host, port, allowed_origin=…)@:
-- validate the origin, admit and profile the build, then bind (no thread
-- is started). Throws 'SimulationServerError'.
createSimulationServer :: BuiltNet -> String -> Int -> Text -> IO SimulationServer
createSimulationServer built host port origin = createSimulationServerWith (simulationServerConfig host port origin) built

createSimulationServerWith :: SimulationServerConfig -> BuiltNet -> IO SimulationServer
createSimulationServerWith config built = do
  origin <- either (throwIO . OriginRefused) pure (validateOrigin config.allowedOrigin)
  profile <- either (throwIO . BuildRefused) pure (simulationProfile built)
  profileBytes <- either (throwIO . BuildRefused . UnexpectedError . T.pack . show) (pure . TE.encodeUtf8) (canonicalText profile)
  definition <- case [value | Object members <- [profile], ("definition", value) <- members] of
    value : _ -> pure value
    [] -> throwIO (BuildRefused (UnexpectedError "the profile has no definition"))
  admission <- newMVar False
  slot <- newTVarIO False
  let state = Pending origin definition admission slot config built profileBytes
      settings =
        defaultServerConfig
          { serverHost = config.host
          , serverPortNumber = config.port
          , connectionTimeout = config.connectionTimeout
          , waitForHandlersOnClose = True
          , supportsMethod = const True
          }
  server <- createServer settings (handler state)
  pure SimulationServer {http = server, profile, profileBytes, admission, slot}

-- | @server.shutdown()@: refuse new simulations (503), then stop
-- 'serveForever' and wait for it to return.
shutdownSimulationServer :: SimulationServer -> IO ()
shutdownSimulationServer server = do
  modifyMVar_ server.admission (const (pure True))
  shutdown server.http

-- | @server.server_close()@: close the socket and wait for every running
-- request (@block_on_close@ with non-daemon threads).
closeSimulationServer :: SimulationServer -> IO ()
closeSimulationServer server = serverClose server.http

-- | Create a server, serve it in a thread for the duration of an action,
-- then shut it down and close it.
withSimulationServer :: SimulationServerConfig -> BuiltNet -> (SimulationServer -> IO a) -> IO a
withSimulationServer config built action =
  bracket (createSimulationServerWith config built) closeSimulationServer $ \server -> do
    finished <- newTVarIO False
    void (forkIO (serveForever server.http `finally` atomically (writeTVar finished True)))
    action server `finally` do
      shutdownSimulationServer server
      atomically (readTVar finished >>= check)

-- ---------------------------------------------------------------------------
-- The handler

data Pending = Pending
  { origin :: Text
  , definition :: Json
  , admission :: MVar Bool
  , slot :: TVar Bool
  , config :: SimulationServerConfig
  , built :: BuiltNet
  , profileBytes :: ByteString
  }

-- @_RequestError@
data Refusal = Refusal Int Text Text
  deriving stock (Show)

instance Exception Refusal

refusal :: Int -> Text -> Text -> IO a
refusal status code message = throwIO (Refusal status code message)

invalid :: Text -> IO a
invalid = refusal 400 "invalid_request"

handler :: Pending -> Handler
handler state request = do
  outcome <- try (dispatch state request)
  case outcome of
    Right () -> pure ()
    Left e
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | Just (Refusal status code message) <- fromException e -> failWith state request status code message Nothing
      | ignorable e -> pure ()
      | otherwise -> failWith state request 500 "internal_error" "internal server error" Nothing

-- ConnectionError and TimeoutError.
ignorable :: SomeException -> Bool
ignorable e = isConnectionError e || fromException e == Just ConnectionTimeout

-- @_dispatch(method)@
dispatch :: Pending -> Request -> IO ()
dispatch state request = do
  let method = requestMethod request
      target = requestRawTarget request
  -- A simple HTTP/0.9 request's @self.headers@ is a plain dict upstream,
  -- whose missing @get_all@ fails the origin check as an unexpected error.
  when (requestSimple request) $ throwIO (userError "'dict' object has no attribute 'get_all'")
  case requestHeaderValues "Origin" request of
    [value] | value == TE.encodeUtf8 state.origin -> pure ()
    _ -> refusal 403 "origin_not_allowed" "origin is not allowed"
  when
    ( not ("/" `BS.isPrefixOf` target)
        || "//" `BS.isPrefixOf` target
        || BC.elem '?' target
        || BC.elem '#' target
    )
    $ invalid "an origin-form path without query is required"
  allow <- case target of
    _ | target == profilePath -> pure "GET, OPTIONS"
    _ | target == simulationPath -> pure "POST, OPTIONS"
    _ -> refusal 404 "not_found" "route not found"
  if method `notElem` BS.split 0x20 (BS.concat (BS.split 0x2C allow))
    then failWith state request 405 "method_not_allowed" "method not allowed" (Just allow)
    else
      if
        | method == "OPTIONS" -> respond state request 204 "" False (Just allow)
        | target == profilePath -> respond state request 200 state.profileBytes True Nothing
        | otherwise -> simulation state request

-- @_error@: a vanished or slow client is ignored.
failWith :: Pending -> Request -> Int -> Text -> Text -> Maybe ByteString -> IO ()
failWith state request status code message allow =
  respond state request status body True allow `catch` \e -> unless (ignorable e) (throwIO e)
  where
    body = either (error . show) TE.encodeUtf8 (canonicalText (Object [("error", Object [("code", String code), ("message", String message)])]))

-- @_respond@
respond :: Pending -> Request -> Int -> ByteString -> Bool -> Maybe ByteString -> IO ()
respond state request status body contentType allow =
  sendResponse request (response status headers (if requestMethod request == "HEAD" then "" else body))
  where
    headers =
      [("Content-Type", "application/json; charset=utf-8") | contentType]
        ++ [ ("Content-Length", BC.pack (show (BS.length body)))
           , ("Cache-Control", "no-store")
           , ("Access-Control-Allow-Origin", TE.encodeUtf8 state.origin)
           , ("Vary", "Origin")
           ]
        ++ concat [[("Allow", value), ("Access-Control-Allow-Methods", value), ("Access-Control-Allow-Headers", "Content-Type")] | Just value <- [allow]]

-- @_body()@: strict framing, then exactly Content-Length bytes.
requestBody :: Request -> IO ByteString
requestBody request = do
  let present name = not (null (requestHeaderValues name request))
  when (present "Expect") $ invalid "Expect is not supported"
  when (present "Transfer-Encoding" || present "Content-Encoding") $
    refusal 415 "unsupported_media_type" "encoded bodies are not supported"
  media <- case requestHeaderValues "Content-Type" request of
    [value] -> pure value
    _ -> refusal 415 "unsupported_media_type" "application/json is required"
  let parts = map (lowerLatin1 . stripPython) (BS.split 0x3B media)
  case parts of
    first : rest
      | first == "application/json", all (== "charset=utf-8") rest, length parts <= 2 -> pure ()
    _ -> refusal 415 "unsupported_media_type" "application/json utf-8 is required"
  digits <- case requestHeaderValues "Content-Length" request of
    [value] | not (BS.null value), BC.all isDigit value -> pure value
    _ -> refusal 411 "length_required" "exactly one valid Content-Length is required"
  let lexical = case BC.dropWhile (== '0') digits of
        "" -> "0"
        significant -> significant
      maximum' = "1048576" :: ByteString
  when (BS.length lexical > BS.length maximum' || (BS.length lexical == BS.length maximum' && lexical > maximum')) $
    refusal 413 "payload_too_large" "request body exceeds 1048576 bytes"
  let wanted = read (BC.unpack lexical) :: Int
  received <- try (readBody request wanted)
  case received of
    Left ConnectionTimeout -> invalid "request body is shorter than Content-Length"
    Right bytes
      | BS.length bytes /= wanted -> invalid "request body is shorter than Content-Length"
      | otherwise -> pure bytes

-- @str.strip()@ on an ISO-8859-1 string: Python's whitespace in that range.
stripPython :: ByteString -> ByteString
stripPython = BS.dropWhileEnd isPythonSpace . BS.dropWhile isPythonSpace
  where
    isPythonSpace w = (w >= 0x09 && w <= 0x0D) || (w >= 0x1C && w <= 0x20) || w == 0x85 || w == 0xA0

-- @str.lower()@ on an ISO-8859-1 string (the result is compared with ASCII
-- text only, so letters outside ASCII need only stay non-ASCII).
lowerLatin1 :: ByteString -> ByteString
lowerLatin1 = BS.map (\w -> if w >= 0x41 && w <= 0x5A then w + 32 else w)

-- @_simulation()@
simulation :: Pending -> Request -> IO ()
simulation state request = do
  raw <- requestBody request
  decoded <- either (const (invalid "request body must be strict JSON")) pure (strictJson raw)
  fields <- exactObject decoded ["expected_definition", "initial_marking", "max_actions"] "request"
  expected <- case lookup "expected_definition" fields of
    Just value@(Object _) -> pure value
    _ -> invalid "expected_definition must be an object"
  marking <- either invalid pure (decodeMarking (maybe Null id (lookup "initial_marking" fields)))
  maxActions <- case lookup "max_actions" fields of
    Just (Int n) | 1 <= n && n <= 256 -> pure (fromInteger n)
    _ -> invalid "max_actions must be an integer from 1 through 256"
  unless (typeExactEq expected state.definition) $
    refusal 409 "definition_mismatch" "expected definition does not match fixed definition"
  admitted <- withMVar state.admission $ \shuttingDown ->
    if shuttingDown
      then pure (Left ("server_shutting_down", "server is shutting down", 503))
      else atomically $ do
        taken <- readTVar state.slot
        if taken
          then pure (Left ("simulation_busy", "another simulation is running", 429))
          else Right () <$ writeTVar state.slot True
  case admitted of
    Left (code, message, status) -> refusal status code message
    Right () -> pure ()
  result <-
    (state.config.runner state.built marking maxActions)
      `finally` atomically (writeTVar state.slot False)
  case result of
    Right payload -> respond state request 200 payload True Nothing
    Left (ProfileError _) -> refusal 422 "simulation_rejected" "simulation was rejected"
    Left (UnexpectedError _) -> refusal 500 "internal_error" "internal server error"

-- @_strict_loads(payload)@: strict UTF-8, duplicate-free, finite JSON whose
-- strings are Unicode scalar values.
strictJson :: ByteString -> Either String Json
strictJson raw
  | not (BS.isValidUtf8 raw) = Left "invalid UTF-8"
  | otherwise = parseJson strictLoads raw

-- @_exact_object(value, fields, subject)@
exactObject :: Json -> [Text] -> Text -> IO [(Text, Json)]
exactObject value fields subject = case value of
  Object members | sort (map fst members) == sort fields -> pure members
  _ -> invalid (subject <> " must contain exactly " <> pythonStrListRepr (sort fields))

-- | @_decode_marking(value)@: the protocol-v1 sorted place/token shape.
-- 'Left' carries the 400 message.
decodeMarking :: Json -> Either Text Marking
decodeMarking = \case
  Array entries -> markingFromList <$> go Nothing entries
  _ -> Left "initial_marking must be an array"
  where
    go _ [] = Right []
    go previous (entry : rest) = do
      item <- exact entry ["place", "tokens"] "marking entry"
      name <- case lookup "place" item of
        Just (String text) | not (T.null text) -> Right text
        _ -> Left "marking place must be a nonempty string"
      case previous of
        Just before | name <= before -> Left "initial_marking places must be unique and sorted"
        _ -> Right ()
      values <- case lookup "tokens" item of
        Just (Array values@(_ : _)) -> Right values
        _ -> Left "marking token queues must be nonempty arrays"
      path <- either (const (Left "marking place is invalid")) Right (netPath name)
      tokens <- traverse token values
      ((path, tokens) :) <$> go (Just name) rest
    token value = do
      fields <- exact value ["color", "data"] "token"
      color <- case lookup "color" fields of
        Just Null -> Right Nothing
        Just (String text) | not (T.null text) -> Right (Just text)
        _ -> Left "token color must be null or nonempty string"
      pure (Token color (maybe Null id (lookup "data" fields)))
    exact value fields subject = case value of
      Object members | sort (map fst members) == sort fields -> Right members
      _ -> Left (subject <> " must contain exactly " <> pythonStrListRepr (sort fields))

-- ---------------------------------------------------------------------------
-- Origins

-- | @_validate_origin(origin)@: one exact absolute HTTP(S) origin, with a
-- conservative canonical DNS, IPv4, or bracketed IPv6 host and an optional
-- port. 'Left' carries the reference's message.
validateOrigin :: Text -> Either Text Text
validateOrigin origin = do
  when (origin `elem` ["*", "null"] || T.any (\c -> pythonSpace c || ord c < 32) origin) $
    Left "allowed_origin must be one exact absolute HTTP(S) origin"
  parsed <- urlsplit origin
  when
    ( splitScheme parsed `notElem` ["http", "https"]
        || T.null (splitNetloc parsed)
        || not (T.null (splitPath parsed))
        || not (T.null (splitQuery parsed))
        || not (T.null (splitFragment parsed))
    )
    $ Left "allowed_origin must be one exact absolute HTTP(S) origin without path, query, or fragment"
  when (splitUsername parsed /= Nothing || splitPassword parsed /= Nothing) $
    Left "allowed_origin must not contain user information"
  port <- either (const (Left "allowed_origin port must be in range")) Right (splitPort parsed)
  hostname <- case splitHostname parsed of
    Just name
      | maybe True (\p -> 1 <= p && p <= 65535) port
      , not (":" `T.isSuffixOf` splitNetloc parsed) ->
          Right name
    _ -> Left "allowed_origin must contain a hostname and valid port"
  validateHostname (splitNetloc parsed) hostname port
  unless (origin == splitScheme parsed <> "://" <> splitNetloc parsed) $
    Left "allowed_origin must be an exactly serialized web origin"
  pure origin

-- _validate_hostname
validateHostname :: Text -> Text -> Maybe Integer -> Either Text ()
validateHostname netloc hostname port = do
  let authority
        | "[" `T.isPrefixOf` netloc = case T.findIndex (== ']') netloc of
            Just closing -> T.take (closing + 1) netloc
            Nothing -> netloc
        | otherwise = case port of
            Just _ -> case T.breakOnEnd ":" netloc of
              (before, _) | not (T.null before) -> T.dropEnd 1 before
              _ -> netloc
            Nothing -> netloc
      invalidHost = Left "allowed_origin contains an invalid host"
  when (T.any (`elem` ("%\\," :: String)) netloc || not (T.all isAscii hostname)) invalidHost
  if "[" `T.isPrefixOf` authority
    then do
      unless ("]" `T.isSuffixOf` authority) invalidHost
      unless (ipv6Address hostname) invalidHost
    else unless (ipv4Address hostname) $ do
      let labels = T.splitOn "." hostname
      when (T.length hostname > 253 || not (all label labels)) invalidHost
  where
    -- [A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?
    label text = case T.unpack text of
      [c] -> alnum c
      c : more ->
        alnum c && alnum (last more) && length more <= 62 && all (\x -> alnum x || x == '-') more
      [] -> False
    alnum c = isAsciiLower c || isAsciiUpper c || (isAscii c && isDigit c)

-- @str.isspace()@ (Unicode 16.0).
pythonSpace :: Char -> Bool
pythonSpace c =
  (c >= '\t' && c <= '\r')
    || (c >= '\x1c' && c <= ' ')
    || c == '\x85'
    || c == '\xa0'
    || c == '\x1680'
    || (c >= '\x2000' && c <= '\x200a')
    || c == '\x2028'
    || c == '\x2029'
    || c == '\x202f'
    || c == '\x205f'
    || c == '\x3000'
