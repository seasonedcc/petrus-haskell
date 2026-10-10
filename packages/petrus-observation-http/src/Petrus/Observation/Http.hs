-- | The host-owned HTTP binding for observation protocol 1: a port of
-- @petrus.engine.observation_http@ on "Petrus.Http.Core", byte for byte.
--
-- > server <- createObservationServer engine "127.0.0.1" 0
-- > port <- serverPort server
-- > _ <- forkIO (serveForever server)
-- > …
-- > shutdown server >> serverClose server
--
-- Like the reference, 'createObservationServer' only binds: the
-- application owns serving, shutdown and close, and closing the server
-- never closes the Engine. Routes:
--
-- * @GET /v1/snapshot@, @GET /v1/document@ (no query) and
--   @GET /v1/history?after=N&limit=M@ (@limit@ at most
--   'maxHistoryPageLimit'): the Engine's three read doors, as compact,
--   key-sorted, ASCII-escaped JSON;
-- * @OPTIONS@ on any path: 204 with @Allow: GET, OPTIONS@;
-- * @POST@, @PUT@, @PATCH@, @DELETE@ and @HEAD@ on any path: 405 with
--   @Allow@ (and, as upstream, a JSON body even for @HEAD@);
-- * any other method: "Petrus.Http.Core"'s 501 page.
--
-- Failures map as upstream's handler maps exceptions: a refused request or
-- view (@ValueError@) is 400 @invalid_request@ with the refusal's text, an
-- unavailable Engine (@RuntimeError@) is 503 @engine_unavailable@, a
-- vanished client is ignored, and anything else is 500 @internal_error@.
module Petrus.Observation.Http
  ( -- * Servers
    createObservationServer
  , createObservationServerWith
  , observationServerConfig
  , ObservationServer

    -- * Read doors
  , ObservationDoors (..)
  , engineDoors

    -- * The handler
  , observationHandler
  , maxHistoryPageLimit
  , historyQuery

    -- * Serving (re-exported from "Petrus.Http.Core")
  , serveForever
  , shutdown
  , serverClose
  , serverPort
  , serverAddress
  , withRunningServer
  ) where

import Control.Exception (Exception (..), SomeAsyncException, SomeException, catch, throwIO, try)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Foreign.C.Error (Errno (..), eCONNRESET, ePIPE)
import GHC.IO.Exception (IOException (..))
import Petrus.Engine (Engine, EngineError (..))
import Petrus.Http.Core
  ( Handler
  , Request
  , Server
  , ServerConfig (..)
  , createServer
  , defaultServerConfig
  , requestMethod
  , requestPath
  , response
  , sendResponse
  , serveForever
  , serverAddress
  , serverClose
  , serverPort
  , shutdown
  , withRunningServer
  )
import Petrus.Http.Core.Url (SplitResult (..), parseQsl, urlsplit)
import Petrus.Json (EncodeError (..), EncodeOptions (..), Json (..), defaultDumps, dumps, encodeErrorMessage)
import Petrus.Json.Limits (decimalInteger)
import Petrus.Observation (ObservationError, observationErrorText)
import Petrus.Observation.Engine qualified as Observe

-- | A bound observation server ("Petrus.Http.Core"'s 'Server').
type ObservationServer = Server

-- | @MAX_HISTORY_PAGE_LIMIT@: the largest @limit@ the adapter accepts.
maxHistoryPageLimit :: Integer
maxHistoryPageLimit = 1000

-- | The three reads the adapter serves. 'engineDoors' reads an Engine;
-- tests substitute failing doors.
data ObservationDoors = ObservationDoors
  { snapshotDoor :: IO Json
  -- ^ @engine.snapshot()@
  , documentDoor :: IO Json
  -- ^ @engine.net_document()@
  , historyDoor :: Integer -> Integer -> IO Json
  -- ^ @engine.history_page(after, limit)@
  }

-- | An Engine's read doors ("Petrus.Observation.Engine").
engineDoors :: Engine -> ObservationDoors
engineDoors engine =
  ObservationDoors
    { snapshotDoor = Observe.snapshot engine
    , documentDoor = Observe.netDocument engine
    , historyDoor = Observe.historyPage engine
    }

-- | @create_observation_server(engine, host, port)@: bind an inert server
-- (no thread is started). Port 0 picks an ephemeral port.
createObservationServer :: Engine -> String -> Int -> IO ObservationServer
createObservationServer engine = createObservationServerWith (engineDoors engine)

-- | 'createObservationServer' over any read doors.
createObservationServerWith :: ObservationDoors -> String -> Int -> IO ObservationServer
createObservationServerWith doors host port =
  createServer (observationServerConfig host port) (observationHandler doors)

-- | The server settings upstream's @ObservationHTTPServer@ has: no socket
-- timeout, daemon handler threads (closing does not wait for them), and the
-- methods it defines a @do_*@ for.
observationServerConfig :: String -> Int -> ServerConfig
observationServerConfig host port =
  defaultServerConfig
    { serverHost = host
    , serverPortNumber = port
    , connectionTimeout = Nothing
    , waitForHandlersOnClose = False
    , supportsMethod = (`elem` ["GET", "OPTIONS", "POST", "PUT", "PATCH", "DELETE", "HEAD"])
    }

-- Outcomes ------------------------------------------------------------------

-- How a failure inside @do_GET@ is answered (the handler's except clauses).
data Failure
  = Invalid Text
  | Unavailable
  | Internal
  | Gone

classify :: SomeException -> Maybe Failure
classify e
  | Just (_ :: SomeAsyncException) <- fromException e = Nothing
  | Just (refusal :: ObservationError) <- fromException e = Just (Invalid (observationErrorText refusal))
  | Just (RequestRefused message) <- fromException e = Just (Invalid message)
  | Just engineError <- fromException e = Just $ case engineError of
      EngineValueError message -> Invalid message
      EngineRuntimeError _ -> Unavailable
      EngineTypeError _ -> Internal
      EngineHandlerFailed _ -> Internal
  | Just (EncodingRefused refusal) <- fromException e = Just $ case refusal of
      -- json.dumps raises ValueError for these two …
      NonFiniteNumber _ -> Invalid (T.pack (encodeErrorMessage refusal))
      IntegerTooLarge _ -> Invalid (T.pack (encodeErrorMessage refusal))
      -- … and RecursionError, a RuntimeError, for this one.
      NestingTooDeep _ -> Unavailable
  | vanished e = Just Gone
  | otherwise = Just Internal

-- BrokenPipeError and ConnectionResetError, the two the handler ignores.
vanished :: SomeException -> Bool
vanished e = case fromException e of
  Just IOError {ioe_errno = Just errno} -> Errno errno `elem` [ePIPE, eCONNRESET]
  _ -> False

-- A ValueError the adapter raises itself (target or query refusals).
newtype RequestRefused = RequestRefused Text
  deriving stock (Show)

instance Exception RequestRefused

newtype EncodingRefused = EncodingRefused EncodeError
  deriving stock (Show)

instance Exception EncodingRefused

-- The handler -----------------------------------------------------------------

-- | Upstream's @_ObservationHandler@.
observationHandler :: ObservationDoors -> Handler
observationHandler doors request = case requestMethod request of
  "GET" -> get doors request
  "OPTIONS" -> respond request 204 "" Nothing (Just "GET, OPTIONS")
  _ -> failWith request 405 "method_not_allowed" "method not allowed" (Just "GET, OPTIONS")

get :: ObservationDoors -> Request -> IO ()
get doors request = do
  outcome <- try route
  case outcome of
    Right () -> pure ()
    Left e -> case classify e of
      Nothing -> throwIO e
      Just (Invalid message) -> failWith request 400 "invalid_request" message Nothing
      Just Unavailable -> failWith request 503 "engine_unavailable" "Engine is unavailable" Nothing
      Just Gone -> pure ()
      Just Internal -> failWith request 500 "internal_error" "internal server error" Nothing
  where
    route = do
      -- self.path is str(raw_requestline, "iso-8859-1") with leading
      -- slashes collapsed.
      target <- either (throwIO . RequestRefused) pure (urlsplit (TE.decodeLatin1 (requestPath request)))
      case splitPath target of
        "/v1/snapshot" -> do
          noQuery target "snapshot does not accept query parameters"
          snapshotDoor doors >>= json request 200
        "/v1/document" -> do
          noQuery target "document does not accept query parameters"
          documentDoor doors >>= json request 200
        "/v1/history" -> do
          (after, limit) <- either (throwIO . RequestRefused) pure (historyQuery (splitQuery target))
          historyDoor doors after limit >>= json request 200
        _ -> failWith request 404 "not_found" "route not found" Nothing
    noQuery target message
      | T.null (splitQuery target) = pure ()
      | otherwise = throwIO (RequestRefused message)

-- | @_history_query(query)@: exactly one @after@ and one @limit@, each a
-- non-empty unsigned decimal integer, @limit@ at most
-- 'maxHistoryPageLimit'. 'Left' carries upstream's @ValueError@ text.
historyQuery :: Text -> Either Text (Integer, Integer)
historyQuery query = do
  pairs <- parseQsl True True query
  values <- collect [] pairs
  let lookupValue name = maybe (Left ("history query parameter " <> name <> " is required exactly once")) Right (lookup name values)
      checked name = do
        value <- lookupValue name
        if not (T.null value) && T.all (\c -> c >= '0' && c <= '9') value
          then Right value
          else Left ("history query parameter " <> name <> " must be a non-empty unsigned decimal integer")
  afterText <- checked "after"
  limitText <- checked "limit"
  after <- integer afterText
  limit <- integer limitText
  if limit > maxHistoryPageLimit
    then Left ("history limit must not exceed adapter maximum " <> T.pack (show maxHistoryPageLimit))
    else Right (after, limit)
  where
    collect seen = \case
      [] -> Right seen
      (name, value) : rest
        | name `notElem` ["after", "limit"] ->
            Left ("unknown history query parameter: " <> (if T.null name then "<empty>" else name))
        | name `elem` map fst seen -> Left ("history query parameter " <> name <> " must appear exactly once")
        | otherwise -> collect ((name, value) : seen) rest
    integer = either (Left . T.pack) Right . decimalInteger . TE.encodeUtf8

-- Responses -------------------------------------------------------------------

-- json.dumps(value, allow_nan=False, separators=(",", ":"), sort_keys=True)
encoding :: EncodeOptions
encoding = defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True, allowNan = False}

json :: Request -> Int -> Json -> IO ()
json request status value = jsonWith request status value Nothing

jsonWith :: Request -> Int -> Json -> Maybe ByteString -> IO ()
jsonWith request status value allow = case dumps encoding value of
  Left refusal -> throwIO (EncodingRefused refusal)
  Right body -> respond request status body (Just "application/json; charset=utf-8") allow

-- @_error@: the error body; a vanished client is ignored.
failWith :: Request -> Int -> Text -> Text -> Maybe ByteString -> IO ()
failWith request status code message allow =
  jsonWith request status (Object [("error", Object [("code", String code), ("message", String message)])]) allow
    `catch` \e -> if vanished e then pure () else throwIO e

-- @_respond@: the header order upstream writes.
respond :: Request -> Int -> ByteString -> Maybe ByteString -> Maybe ByteString -> IO ()
respond request status body contentType allow =
  sendResponse request (response status headers body)
  where
    headers =
      maybe [] (\value -> [("Content-Type", value)]) contentType
        ++ [ ("Content-Length", BC.pack (show (BC.length body)))
           , ("Cache-Control", "no-store")
           , ("Access-Control-Allow-Origin", "*")
           , ("Access-Control-Allow-Methods", "GET, OPTIONS")
           , ("Access-Control-Allow-Headers", "Content-Type")
           ]
        ++ maybe [] (\value -> [("Allow", value)]) allow
