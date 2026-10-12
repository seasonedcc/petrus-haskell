-- | A native client for E2B's documented control-plane REST API and the
-- @envd@ API inside each sandbox: the 'E2bSdk' binding the E2B provider
-- loads by default.
--
-- Upstream's @E2bEnvironment@ imports the official @e2b@ Python SDK.  This
-- module speaks the same wire protocol that SDK speaks (checked against
-- @e2b@ 2.55.1, see 'e2bWireProtocol'), restricted to the calls upstream
-- makes:
--
-- * @Sandbox.list@: @GET /v2/sandboxes?metadata=...&limit=...@, paginated by
--   the @x-next-token@ response header;
-- * @Sandbox.create@: @POST /v2/sandboxes@ (@templateID@, @timeout@,
--   @metadata@, @envVars@); a template whose @envdVersion@ is below 0.1.0 is
--   killed and refused, as the SDK does;
-- * @Sandbox.connect@: @POST /v2/sandboxes/{id}/connect@;
-- * @sandbox.kill@: @DELETE /sandboxes/{id}@ (a 404 is not an error);
-- * @files.write@ \/ @files.read@: @POST@ (multipart, field @file@) and
--   @GET /files?path=...@ on envd;
-- * @files.remove@: the Connect unary call @filesystem.Filesystem/Remove@;
-- * @commands.run@: the Connect server stream @process.Process/Start@
--   running @/bin/bash -l -c <cmd>@, and @process.Process/SendSignal@
--   (@SIGNAL_SIGKILL@) to kill it.
--
-- The REST API authenticates with @X-API-KEY@.  envd requests carry
-- @E2b-Sandbox-Id@, @E2b-Sandbox-Port: 49983@ and the sandbox's
-- @X-Access-Token@.  Connect calls use the JSON codec without compression,
-- like the SDK (@ENVD_JSON_CODEC@, @ENVD_RPC_COMPRESSION@).  The SDK speaks
-- HTTP/2 by default and HTTP/1.1 when @E2B_HTTP_VERSION=1.1@; this client
-- always uses HTTP/1.1.
--
-- Configuration follows the SDK's environment variables: @E2B_API_KEY@,
-- @E2B_DOMAIN@ (default @e2b.app@), @E2B_API_URL@ (default
-- @https://api.<domain>@) and @E2B_SANDBOX_URL@ (default
-- @https://sandbox.<domain>@ for E2B's own domains, otherwise
-- @https://49983-<id>.<domain>@).
--
-- Failures surface as 'ExecutionError's whose 'OtherError' kind names the SDK
-- exception class (@AuthenticationException@, @NotFoundException@,
-- @SandboxException@, @TimeoutException@, ...) with the SDK's message.
module Petrus.Motus.Execution.Providers.E2b.Http
  ( E2bConnection (..)
  , connectionFromEnvironment
  , httpSdk
  , httpSdkLoader
  , e2bWireProtocol
  , envdPort
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracketOnError, onException, throwIO, try)
import Control.Monad (unless, when)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Base64.URL qualified as B64U
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word8)
import GHC.Clock (getMonotonicTime)
import Network.HTTP.Client qualified as H
import Network.HTTP.Client.MultipartFormData (formDataBody, partFileRequestBody)
import Network.HTTP.Client.TLS (getGlobalManager)
import Network.HTTP.Types (Header, Method, ResponseHeaders, Status (..), renderQuery)
import Petrus.Json
import Petrus.Motus.Execution.Error
import Petrus.Json.Python (pythonReprBytes)
import Petrus.Motus.Execution.Providers.E2b.Sdk
import System.Environment (lookupEnv)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | The @e2b@ Python SDK release whose wire protocol this client follows.
e2bWireProtocol :: Text
e2bWireProtocol = "e2b-python-sdk 2.55.1"

-- | @ConnectionConfig.envd_port@.
envdPort :: Int
envdPort = 49983

-- | Where and how to reach E2B (the SDK's @ConnectionConfig@).
data E2bConnection = E2bConnection
  { connectionDomain :: Text
  , connectionApiUrl :: Text
  , connectionSandboxUrl :: Maybe Text
  -- ^ Overrides every sandbox's envd URL (@E2B_SANDBOX_URL@).
  , connectionRequestTimeout :: Double
  -- ^ Seconds; the SDK's @REQUEST_TIMEOUT@ is 60.
  , connectionRetries :: Int
  -- ^ Control-plane retries; the SDK's @DEFAULT_RETRIES@ is 3.
  , connectionManager :: H.Manager
  }

-- | The connection the SDK would build from the process environment.
connectionFromEnvironment :: IO E2bConnection
connectionFromEnvironment = do
  domain <- maybe "e2b.app" T.pack . nonEmpty <$> lookupEnv "E2B_DOMAIN"
  apiUrl <- maybe ("https://api." <> domain) T.pack . nonEmpty <$> lookupEnv "E2B_API_URL"
  sandboxUrl <- fmap T.pack . nonEmpty <$> lookupEnv "E2B_SANDBOX_URL"
  E2bConnection domain apiUrl sandboxUrl 60 3 <$> getGlobalManager
  where
    nonEmpty = \case
      Just value | not (null value) -> Just value
      _ -> Nothing

-- | The default loader of 'Petrus.Motus.Execution.Providers.E2b.defaultE2bConfig'.
httpSdkLoader :: IO E2bSdk
httpSdkLoader = httpSdk <$> connectionFromEnvironment

httpSdk :: E2bConnection -> E2bSdk
httpSdk connection =
  E2bSdk
    { sdkList = listSandboxes connection
    , sdkCreate = createSandbox connection
    , sdkConnect = connectSandbox connection
    }

-- * Errors

sdkError :: Text -> Text -> ExecutionError
sdkError cls = executionError (OtherError cls)

throwSdk :: Text -> Text -> IO a
throwSdk cls message = throwIO (sdkError cls message)

-- | @api_exception_from_code@ / @handle_api_exception@.
apiError :: Int -> ByteString -> ExecutionError
apiError status content = case (message, status) of
  (_, 401) -> sdkError "AuthenticationException" (withMessage "401: Unauthorized, please check your credentials.")
  (_, 429) -> sdkError "RateLimitException" (withMessage "429: Rate limit exceeded, please try again later.")
  (_, 503) -> sdkError "ServiceBusyException" (withMessage "503: Service temporarily unavailable, please retry.")
  (Just text, _) -> sdkError "SandboxException" (T.pack (show status) <> ": " <> text)
  (Nothing, _) -> sdkError "SandboxException" (T.pack (show status) <> ": " <> T.pack (pythonReprBytes content))
  where
    message = case parseJson surrogateRefusingLoads content of
      Right body | Just (String text) <- lookupMember "message" body -> Just text
      _ -> Nothing
    withMessage base = maybe base (\text -> base <> " - " <> text) message

-- | @format_envd_api_exception@ with an optional per-call override.
envdApiError :: Maybe (Int, Text) -> Int -> ByteString -> ExecutionError
envdApiError override status body = case (override, status) of
  (Just (code, cls), _) | code == status -> sdkError cls message
  (_, 400) -> sdkError "InvalidArgumentException" message
  (_, 401) -> sdkError "AuthenticationException" message
  (_, 404) -> sdkError "NotFoundException" message
  (_, 429) -> sdkError "RateLimitException" (message <> ": The requests are being rate limited.")
  (_, 502) -> sdkError "SandboxException" message
  (_, 507) -> sdkError "NotEnoughSpaceException" message
  _ -> sdkError "SandboxException" (T.pack (show status) <> ": " <> message)
  where
    message = responseMessage body

-- | @get_message@: the string @message@ of a JSON object body, else its text.
responseMessage :: ByteString -> Text
responseMessage body = case parseJson surrogateRefusingLoads body of
  Right value | Just (String text) <- lookupMember "message" value -> text
  _ -> TE.decodeUtf8With lenientDecode body

-- | A Connect error (@code@ is the Connect code name, e.g. @not_found@).
data ConnectFailure = ConnectFailure {failureCode :: Text, failureMessage :: Text}
  deriving stock (Show)

-- | @handle_rpc_exception@'s default mapping.
rpcError :: ConnectFailure -> ExecutionError
rpcError (ConnectFailure code message) = case code of
  "invalid_argument" -> sdkError "InvalidArgumentException" message
  "unauthenticated" -> sdkError "AuthenticationException" message
  "not_found" -> sdkError "NotFoundException" message
  "unavailable" -> sdkError "SandboxException" message
  "resource_exhausted" -> sdkError "RateLimitException" (message <> ": Rate limit exceeded, please try again later.")
  "canceled" ->
    sdkError "TimeoutException" $
      message
        <> ": The request was cancelled by the server or a proxy while it was in flight \8212 for example when the sandbox is paused or shut down."
  "deadline_exceeded" -> deadlineError message
  _ -> sdkError "SandboxException" (code <> ": " <> message)

deadlineError :: Text -> ExecutionError
deadlineError message =
  sdkError "TimeoutException" $
    message
      <> ": This error is likely due to exceeding 'timeout' \8212 the total time a long running request (like process or directory watch) can be active \8212 or 'request_timeout'. You can modify these by passing 'timeout' or 'request_timeout' when making the request. Use '0' to disable the timeout."

-- | @PLAIN_HTTP_ERROR_CODES@: a non-Connect error response (a proxy
-- answering instead of envd), or a Connect unary error body.
connectFailureFrom :: Int -> ByteString -> ConnectFailure
connectFailureFrom status body = case parseJson surrogateRefusingLoads body of
  Right value
    | Just (String code) <- lookupMember "code" value, code `elem` connectCodes ->
        ConnectFailure code (maybe "" textOf (lookupMember "message" value))
    | otherwise ->
        let status' = case lookupMember "code" value of
              Just (Int n) -> fromInteger n
              _ -> status
            message = case lookupMember "message" value of
              Just (String text) | not (T.null text) -> text
              _ -> fallback
         in ConnectFailure (plainCode status') message
  Left _ -> ConnectFailure (plainCode status) fallback
  where
    fallback
      | B.null body = "HTTP " <> T.pack (show status)
      | otherwise = TE.decodeUtf8With lenientDecode body
    textOf = \case
      String text -> text
      _ -> ""

plainCode :: Int -> Text
plainCode = \case
  400 -> "invalid_argument"
  401 -> "unauthenticated"
  403 -> "permission_denied"
  404 -> "not_found"
  409 -> "already_exists"
  413 -> "resource_exhausted"
  429 -> "resource_exhausted"
  499 -> "canceled"
  500 -> "internal"
  501 -> "unimplemented"
  502 -> "unavailable"
  503 -> "unavailable"
  504 -> "deadline_exceeded"
  505 -> "unimplemented"
  _ -> "unknown"

connectCodes :: [Text]
connectCodes =
  [ "canceled", "unknown", "invalid_argument", "deadline_exceeded", "not_found", "already_exists"
  , "permission_denied", "resource_exhausted", "failed_precondition", "aborted", "out_of_range"
  , "unimplemented", "internal", "unavailable", "data_loss", "unauthenticated"
  ]

-- * HTTP plumbing

userAgent :: ByteString
userAgent = "petrus-haskell-e2b (" <> TE.encodeUtf8 e2bWireProtocol <> " wire protocol)"

encodeJson :: Json -> ByteString
encodeJson value = either (error . encodeErrorMessage) id (dumps compact value)

parseBody :: Text -> ByteString -> IO Json
parseBody what body = case parseJson surrogateRefusingLoads body of
  Right value -> pure value
  Left problem -> throwSdk "SandboxException" ("invalid JSON in " <> what <> ": " <> T.pack problem)

secondsMicro :: Double -> Int
secondsMicro seconds = max 1 (round (seconds * 1000000))

baseRequest :: Text -> Text -> IO H.Request
baseRequest base path = H.parseRequest (T.unpack (T.dropWhileEnd (== '/') base <> path))

-- | The API key the SDK resolves: the explicit option, else @E2B_API_KEY@.
apiKey :: E2bOptions -> IO ByteString
apiKey options = do
  fromEnv <- lookupEnv "E2B_API_KEY"
  case optionApiKey options of
    Just key -> pure (TE.encodeUtf8 key)
    Nothing -> case fromEnv of
      Just key -> pure (BC.pack key)
      Nothing ->
        throwSdk
          "AuthenticationException"
          "API key is required, please visit the API Keys tab at https://e2b.dev/dashboard?tab=keys to get your API key. You can either set the environment variable `E2B_API_KEY` or you can pass it directly to the method like api_key=\"e2b_...\""

data Idempotency = Idempotent | Creates
  deriving stock (Eq)

-- | One control-plane call, with the SDK's retry policy: a 429 carrying an
-- integer @Retry-After@, a 503, a 502 (except for a create) and a failure
-- to connect are retried up to 'connectionRetries' times with exponential
-- back-off from 0.1 s (capped at 10 s), honouring @Retry-After@.
restCall ::
  E2bConnection -> E2bOptions -> Idempotency -> Method -> Text -> [(ByteString, Maybe ByteString)] -> Maybe Json -> IO (Int, ResponseHeaders, ByteString)
restCall connection options idempotency method path query body = do
  key <- apiKey options
  base <- baseRequest (connectionApiUrl connection) path
  let request =
        base
          { H.method = method
          , H.queryString = renderQuery True query
          , H.requestHeaders =
              [("X-API-KEY", key), ("User-Agent", userAgent)]
                <> maybe [] (const [("Content-Type", "application/json")]) body
          , H.requestBody = H.RequestBodyBS (maybe "" encodeJson body)
          , H.responseTimeout = H.responseTimeoutMicro (secondsMicro (connectionRequestTimeout connection))
          }
      attempt :: Int -> IO (Int, ResponseHeaders, ByteString)
      attempt n = do
        outcome <- try (H.httpLbs request (connectionManager connection))
        case outcome of
          Left failure
            | n < connectionRetries connection, connectFailed failure -> backOff n Nothing >> attempt (n + 1)
            | otherwise -> throwIO (transportError failure)
          Right response -> do
            let status = statusCode (H.responseStatus response)
                headers = H.responseHeaders response
                retryAfter = lookup "Retry-After" headers >>= readMaybe . BC.unpack
                retryable = case status of
                  429 -> retryAfter /= Nothing
                  503 -> True
                  502 -> idempotency == Idempotent
                  _ -> False
            if retryable && n < connectionRetries connection
              then backOff n retryAfter >> attempt (n + 1)
              else pure (status, headers, BL.toStrict (H.responseBody response))
  attempt 0
  where
    backOff :: Int -> Maybe Int -> IO ()
    backOff n retryAfter =
      threadDelay $ case retryAfter of
        Just seconds -> seconds * 1000000
        Nothing -> secondsMicro (min 10 (0.1 * 2 ^ n))

connectFailed :: H.HttpException -> Bool
connectFailed = \case
  H.HttpExceptionRequest _ (H.ConnectionFailure _) -> True
  H.HttpExceptionRequest _ H.ConnectionTimeout -> True
  _ -> False

transportError :: H.HttpException -> ExecutionError
transportError = \case
  H.HttpExceptionRequest _ H.ResponseTimeout -> sdkError "TimeoutException" "Request timed out"
  H.HttpExceptionRequest _ content -> executionError ConnectionError (T.pack (show content))
  H.InvalidUrlException url reason -> sdkError "InvalidArgumentException" (T.pack (url <> ": " <> reason))

-- * Control plane

decodeInfo :: Json -> Maybe E2bSandboxInfo
decodeInfo value = do
  String identifier <- lookupMember "sandboxID" value
  let metadata = case lookupMember "metadata" value of
        Just (Object members) -> Map.fromList [(k, v) | (k, String v) <- members]
        _ -> Map.empty
      state = case lookupMember "state" value of
        Just (String text) -> text
        _ -> ""
  pure (E2bSandboxInfo identifier metadata state)

-- | @urllib.parse.urlencode({quote(k): quote(v)})@, as @SandboxPaginator@
-- encodes a metadata query.
metadataQuery :: Map Text Text -> ByteString
metadataQuery metadata =
  B.intercalate "&" [quotePlus (quote k) <> "=" <> quotePlus (quote v) | (k, v) <- Map.toList metadata]
  where
    quote = percent (`B.elem` "/") . TE.encodeUtf8
    quotePlus = B.concatMap (\c -> if c == 0x20 then "+" else B.singleton c) . percent (== 0x20)
    percent keep = B.concatMap (\c -> if unreserved c || keep c then B.singleton c else escape c)
    unreserved c = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c `B.elem` "_.-~"
    escape c = BC.pack ('%' : hex (c `shiftR` 4) : [hex (c .&. 15)])
    hex n = "0123456789ABCDEF" !! fromIntegral n

listSandboxes :: E2bConnection -> E2bOptions -> Map Text Text -> Int -> IO E2bPaginator
listSandboxes connection options metadata limit = do
  state <- newIORef (True, Nothing :: Maybe ByteString)
  pure
    E2bPaginator
      { paginatorHasNext = fst <$> readIORef state
      , paginatorNextItems = \pageOptions -> do
          (more, token) <- readIORef state
          unless more (throwSdk "Exception" "No more items to fetch")
          let callOptions = E2bOptions (maybe (optionApiKey options) Just (optionApiKey pageOptions))
              query =
                [("metadata", Just (metadataQuery metadata)) | not (Map.null metadata)]
                  <> [("limit", Just (BC.pack (show limit))) | limit > 0]
                  <> [("nextToken", Just next) | Just next <- [token]]
          (status, headers, body) <- restCall connection callOptions Idempotent "GET" "/v2/sandboxes" query Nothing
          when (status >= 300) (throwIO (apiError status body))
          let next = lookup "x-next-token" headers >>= \t -> if B.null t then Nothing else Just t
          writeIORef state (next /= Nothing, next)
          parsed <- parseBody "the sandbox list" body
          case parsed of
            Array items -> pure (mapMaybe decodeInfo items)
            Object _ | Just (String message) <- lookupMember "message" parsed -> throwSdk "SandboxException" (message <> ": Request failed")
            _ -> pure []
      }

-- | What a create or connect response says about a sandbox.
data Created = Created
  { createdId :: Text
  , createdDomain :: Maybe Text
  , createdEnvdVersion :: [Int]
  , createdAccessToken :: Maybe Text
  }

decodeCreated :: ByteString -> IO Created
decodeCreated body = do
  value <- parseBody "the sandbox response" body
  let text key = case lookupMember key value of
        Just (String t) -> Just t
        _ -> Nothing
  identifier <- maybe (throwSdk "Exception" "Body of the request is None") pure (text "sandboxID")
  pure (Created identifier (text "domain") (parseVersion (fromMaybe "0.0.0" (text "envdVersion"))) (text "envdAccessToken"))

-- | The numeric release of a @packaging.version.Version@.
parseVersion :: Text -> [Int]
parseVersion = map (fromMaybe 0 . readMaybe . T.unpack . T.takeWhile (`elem` ['0' .. '9'])) . T.splitOn "." . T.dropWhile (== 'v')

versionBelow :: [Int] -> [Int] -> Bool
versionBelow version bound = pad version < pad bound
  where
    pad xs = take 4 (xs <> repeat 0)

createSandbox :: E2bConnection -> E2bOptions -> Text -> Int -> Map Text Text -> IO E2bSandbox
createSandbox connection options template leaseTimeout metadata = do
  let body =
        Object
          [ ("templateID", String template)
          , ("timeout", Int (toInteger leaseTimeout))
          , ("metadata", Object [(k, String v) | (k, v) <- Map.toList metadata])
          , ("envVars", Object [])
          ]
  (status, _, response) <- restCall connection options Creates "POST" "/v2/sandboxes" [] (Just body)
  when (status >= 300) (throwIO (apiError status response))
  created <- decodeCreated response
  when (createdEnvdVersion created `versionBelow` [0, 1, 0]) $ do
    _ <- killSandbox connection options (createdId created)
    throwSdk "TemplateException" "You need to update the template to use the new SDK."
  pure (sandboxHandle connection options created)

connectSandbox :: E2bConnection -> E2bOptions -> Text -> Maybe Int -> IO E2bSandbox
connectSandbox connection options identifier leaseTimeout = do
  let body = Object [("timeout", Int (toInteger seconds)) | Just seconds <- [leaseTimeout]]
  (status, _, response) <-
    restCall connection options Idempotent "POST" ("/v2/sandboxes/" <> pathSegment identifier <> "/connect") [] (Just body)
  when (status == 404) (throwSdk "SandboxNotFoundException" ("Paused sandbox " <> identifier <> " not found"))
  when (status >= 300) (throwIO (apiError status response))
  sandboxHandle connection options <$> decodeCreated response

-- | @Sandbox.kill@: whether the sandbox existed.
killSandbox :: E2bConnection -> E2bOptions -> Text -> IO Bool
killSandbox connection options identifier = do
  (status, _, response) <- restCall connection options Idempotent "DELETE" ("/sandboxes/" <> pathSegment identifier) [] Nothing
  if status == 404
    then pure False
    else do
      when (status >= 300) (throwIO (apiError status response))
      pure True

pathSegment :: Text -> Text
pathSegment = TE.decodeUtf8 . B.concatMap escape . TE.encodeUtf8
  where
    escape c
      | (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c `B.elem` "_.-~" = B.singleton c
      | otherwise = BC.pack ('%' : hex (c `shiftR` 4) : [hex (c .&. 15)])
    hex n = "0123456789ABCDEF" !! fromIntegral n

-- * envd

data Envd = Envd
  { envdConnection :: E2bConnection
  , envdUrl :: Text
  , envdHeaders :: [Header]
  , envdUser :: Maybe ByteString
  -- ^ @user@ for envd older than 0.4.0 (@ENVD_DEFAULT_USER@).
  }

supportedSandboxDomains :: [Text]
supportedSandboxDomains = ["e2b.app", "e2b.dev", "e2b.pro", "e2b-staging.dev"]

sandboxHandle :: E2bConnection -> E2bOptions -> Created -> E2bSandbox
sandboxHandle connection options created =
  E2bSandbox
    { sandboxId = identifier
    , sandboxKill = () <$ killSandbox connection options identifier
    , sandboxWriteFile = writeFile' envd
    , sandboxReadFile = readFile' envd
    , sandboxRemoveFile = removeFile envd
    , sandboxRun = \command runOptions -> startCommand envd command runOptions >>= \handle -> handleWait handle (const (pure ())) (const (pure ()))
    , sandboxRunBackground = startCommand envd
    }
  where
    identifier = createdId created
    domain = fromMaybe (connectionDomain connection) (createdDomain created)
    url = case connectionSandboxUrl connection of
      Just override -> override
      Nothing
        | domain `elem` supportedSandboxDomains -> "https://sandbox." <> domain
        | otherwise -> "https://" <> T.pack (show envdPort) <> "-" <> identifier <> "." <> domain
    envd =
      Envd
        { envdConnection = connection
        , envdUrl = url
        , envdHeaders =
            [ ("User-Agent", userAgent)
            , ("E2b-Sandbox-Id", TE.encodeUtf8 identifier)
            , ("E2b-Sandbox-Port", BC.pack (show envdPort))
            ]
              <> [("X-Access-Token", TE.encodeUtf8 token) | Just token <- [createdAccessToken created]]
        , envdUser = if createdEnvdVersion created `versionBelow` [0, 4, 0] then Just "user" else Nothing
        }

-- | @authentication_header@: Basic @user:@ for old envd, nothing otherwise.
authorization :: Envd -> [Header]
authorization envd = [("Authorization", "Basic " <> B64.encode (user <> ":")) | Just user <- [envdUser envd]]

filesQuery :: Envd -> Text -> ByteString
filesQuery envd path = renderQuery True ([("path", Just (TE.encodeUtf8 path))] <> [("username", Just user) | Just user <- [envdUser envd]])

envdCall :: Envd -> H.Request -> IO (Int, ByteString)
envdCall envd request = do
  outcome <- try (H.httpLbs request (connectionManager (envdConnection envd)))
  case outcome of
    Left failure -> throwIO (transportError failure)
    Right response -> pure (statusCode (H.responseStatus response), BL.toStrict (H.responseBody response))

writeFile' :: Envd -> Text -> ByteString -> IO ()
writeFile' envd path bytes = do
  base <- baseRequest (envdUrl envd) "/files"
  request <-
    formDataBody [partFileRequestBody "file" (T.unpack path) (H.RequestBodyBS bytes)] $
      base
        { H.method = "POST"
        , H.queryString = filesQuery envd path
        , H.requestHeaders = envdHeaders envd
        , H.responseTimeout = H.responseTimeoutMicro (secondsMicro (connectionRequestTimeout (envdConnection envd)))
        }
  (status, body) <- envdCall envd request
  unless (status >= 200 && status < 300) (throwIO (envdApiError (Just (404, "FileNotFoundException")) status body))
  written <- parseBody "the write response" body
  case written of
    Array (_ : _) -> pure ()
    _ -> throwSdk "SandboxException" "Expected to receive information about written file"

readFile' :: Envd -> Text -> IO ByteString
readFile' envd path = do
  base <- baseRequest (envdUrl envd) "/files"
  let request =
        base
          { H.method = "GET"
          , H.queryString = filesQuery envd path
          , H.requestHeaders = envdHeaders envd
          , H.responseTimeout = H.responseTimeoutMicro (secondsMicro (connectionRequestTimeout (envdConnection envd)))
          }
  (status, body) <- envdCall envd request
  unless (status >= 200 && status < 300) (throwIO (envdApiError (Just (404, "FileNotFoundException")) status body))
  pure body

-- | A Connect unary call with the JSON codec.
unary :: Envd -> Text -> Json -> IO (Either ConnectFailure Json)
unary envd procedure message = do
  base <- baseRequest (envdUrl envd) ("/" <> procedure)
  let timeoutSeconds = connectionRequestTimeout (envdConnection envd)
      request =
        base
          { H.method = "POST"
          , H.requestHeaders =
              envdHeaders envd
                <> authorization envd
                <> [ ("Content-Type", "application/json")
                   , ("Connect-Protocol-Version", "1")
                   , ("Connect-Timeout-Ms", BC.pack (show (max 1 (round (timeoutSeconds * 1000) :: Int))))
                   ]
          , H.requestBody = H.RequestBodyBS (encodeJson message)
          , H.responseTimeout = H.responseTimeoutMicro (secondsMicro timeoutSeconds)
          }
  (status, body) <- envdCall envd request
  if status == 200
    then Right <$> parseBody procedure body
    else pure (Left (connectFailureFrom status body))

removeFile :: Envd -> Text -> IO ()
removeFile envd path =
  unary envd "filesystem.Filesystem/Remove" (Object [("path", String path)]) >>= \case
    Right _ -> pure ()
    Left failure -> throwIO (rpcError failure)

-- | @Commands.kill@: whether the process was found.
killProcess :: Envd -> Integer -> IO Bool
killProcess envd pid =
  unary envd "process.Process/SendSignal" (Object [("process", Object [("pid", Int pid)]), ("signal", String "SIGNAL_SIGKILL")]) >>= \case
    Right _ -> pure True
    Left (ConnectFailure "not_found" _) -> pure False
    Left failure -> throwIO (rpcError failure)

-- | Connect envelope framing: one flag byte and a big-endian length.
envelope :: Word8 -> ByteString -> ByteString
envelope flags payload = B.pack (flags : [fromIntegral (len `shiftR` s) | s <- [24, 16, 8, 0]]) <> payload
  where
    len = B.length payload

data Stream = Stream {streamResponse :: H.Response H.BodyReader, streamBuffer :: IORef ByteString}

-- | The next envelope, or 'Nothing' at a clean end of the body.
readEnvelope :: Stream -> IO (Maybe (Word8, ByteString))
readEnvelope stream = do
  header <- takeBytes 5
  case header of
    Nothing -> pure Nothing
    Just bytes -> do
      let len = foldl (\acc b -> acc `shiftL` 8 .|. fromIntegral b) (0 :: Int) (B.unpack (B.drop 1 bytes))
      payload <- takeBytes len
      case payload of
        Just body -> pure (Just (B.head bytes, body))
        Nothing -> throwSdk "SandboxException" "unavailable: the command stream ended inside a message"
  where
    takeBytes n = do
      buffered <- readIORef (streamBuffer stream)
      if B.length buffered >= n
        then do
          let (wanted, rest) = B.splitAt n buffered
          writeIORef (streamBuffer stream) rest
          pure (Just wanted)
        else do
          chunk <-
            try (H.brRead (H.responseBody (streamResponse stream))) >>= \case
              Right bytes -> pure bytes
              Left (failure :: H.HttpException) -> throwIO (rpcError (ConnectFailure "unavailable" (droppedStream failure)))
          if B.null chunk
            then
              if B.null buffered || n == 0
                then pure (if n == 0 then Just "" else Nothing)
                else throwSdk "SandboxException" "unavailable: the command stream ended inside a message"
            else writeIORef (streamBuffer stream) (buffered <> chunk) >> takeBytes n

-- | What a transport failure in the middle of a stream reads as: connectrpc
-- reports it as @UNAVAILABLE@.
droppedStream :: H.HttpException -> Text
droppedStream = \case
  H.HttpExceptionRequest _ content -> "the command stream was dropped: " <> T.pack (show content)
  other -> "the command stream was dropped: " <> T.pack (show other)

data Event
  = EventStart Integer
  | EventStdout ByteString
  | EventStderr ByteString
  | EventEnd Integer (Maybe Text)
  | EventOther

decodeEvent :: ByteString -> IO Event
decodeEvent payload = do
  value <- parseBody "a process event" payload
  pure $ case lookupMember "event" value of
    Just event
      | Just start <- lookupMember "start" event -> EventStart (intMember "pid" start)
      | Just dataEvent <- lookupMember "data" event ->
          case (lookupMember "stdout" dataEvent, lookupMember "stderr" dataEvent) of
            (Just (String chunk), _) -> EventStdout (decodeBytes chunk)
            (_, Just (String chunk)) -> EventStderr (decodeBytes chunk)
            _ -> EventOther
      | Just end <- lookupMember "end" event ->
          EventEnd
            (intMember "exitCode" end)
            (case lookupMember "error" end of Just (String text) -> Just text; _ -> Nothing)
    _ -> EventOther
  where
    intMember key object = case lookupMember key object of
      Just (Int n) -> n
      Just (String text) | Just n <- readMaybe (T.unpack text) -> n
      _ -> 0
    decodeBytes text =
      let encoded = TE.encodeUtf8 text
       in either (const (B64U.decodeLenient encoded)) id (B64.decode encoded)

-- | The trailing message of a Connect stream: its error, if any.
endStreamFailure :: ByteString -> Maybe ConnectFailure
endStreamFailure payload = case parseJson surrogateRefusingLoads payload of
  Right value | Just failure <- lookupMember "error" value ->
    let text key = case lookupMember key failure of
          Just (String t) -> t
          _ -> ""
     in Just (ConnectFailure (if T.null (text "code") then "unknown" else text "code") (text "message"))
  _ -> Nothing

-- | @commands.run(cmd, background=True, envs=..., cwd=..., timeout=...)@:
-- open the @process.Process/Start@ stream and read its start event.
startCommand :: Envd -> Text -> E2bRunOptions -> IO E2bHandle
startCommand envd command options = do
  base <- baseRequest (envdUrl envd) "/process.Process/Start"
  started <- getMonotonicTime
  let seconds = fromMaybe 60 (runTimeout options)
      limited = seconds > 0
      process =
        Object $
          [ ("cmd", String "/bin/bash")
          , ("args", Array [String "-l", String "-c", String command])
          ]
            <> [("envs", Object [(k, String v) | (k, v) <- runEnvs options]) | not (null (runEnvs options))]
            <> [("cwd", String cwd) | Just cwd <- [runCwd options]]
      request =
        base
          { H.method = "POST"
          , H.requestHeaders =
              envdHeaders envd
                <> authorization envd
                <> [ ("Content-Type", "application/connect+json")
                   , ("Connect-Protocol-Version", "1")
                   , ("Keepalive-Ping-Interval", "50")
                   ]
                <> [("Connect-Timeout-Ms", BC.pack (show (max 1 (round (seconds * 1000) :: Int)))) | limited]
          , H.requestBody = H.RequestBodyBS (envelope 0 (encodeJson (Object [("process", process), ("stdin", Bool False)])))
          , H.responseTimeout = if limited then H.responseTimeoutMicro (secondsMicro seconds) else H.responseTimeoutNone
          }
      deadline = if limited then Just (started + seconds) else Nothing
  bracketOnError (openStream request) (H.responseClose . streamResponse) $ \stream -> do
    first <- withinDeadline deadline (readEnvelope stream)
    pid <- case first of
      Just (0, payload) ->
        decodeEvent payload >>= \case
          EventStart pid -> pure pid
          _ -> throwSdk "SandboxException" ("Failed to start process: expected start event, got " <> TE.decodeUtf8With lenientDecode payload)
      Just (_, payload) | Just failure <- endStreamFailure payload -> throwIO (rpcError failure)
      _ -> throwSdk "SandboxException" "Failed to start process: expected start event, got nothing"
    pure
      E2bHandle
        { handleWait = \onStdout onStderr ->
            withinDeadline deadline (collect stream onStdout onStderr)
              `onException` H.responseClose (streamResponse stream)
        , handleKill = () <$ killProcess envd pid
        }
  where
    openStream request = do
      outcome <- try (H.responseOpen request (connectionManager (envdConnection envd)))
      response <- either (throwIO . transportError) pure outcome
      let status = statusCode (H.responseStatus response)
      if status == 200
        then Stream response <$> newIORef ""
        else do
          body <- B.concat <$> H.brConsume (H.responseBody response)
          H.responseClose response
          throwIO (rpcError (connectFailureFrom status body))

-- | The client-side deadline of a Connect call (@timeout_ms@).
withinDeadline :: Maybe Double -> IO a -> IO a
withinDeadline Nothing action = action
withinDeadline (Just at) action = do
  now <- getMonotonicTime
  timeout (max 0 (secondsMicro (at - now))) action >>= \case
    Just value -> pure value
    Nothing -> throwIO (deadlineError "deadline_exceeded: the request deadline expired")

-- | @CommandHandle.wait@, except that a non-zero exit is returned rather
-- than raised as @CommandExitException@ (the 'E2bHandle' contract).
collect :: Stream -> (Text -> IO ()) -> (Text -> IO ()) -> IO E2bCommandResult
collect stream onStdout onStderr = do
  stdoutDecoder <- newIORef (TE.streamDecodeUtf8With lenientDecode)
  stderrDecoder <- newIORef (TE.streamDecodeUtf8With lenientDecode)
  stdoutParts <- newIORef []
  stderrParts <- newIORef []
  ended <- newIORef Nothing
  let feed decoder parts callback chunk = do
        decode <- readIORef decoder
        let TE.Some text _ next = decode chunk
        writeIORef decoder next
        unless (T.null text) (modifyIORef' parts (text :) >> callback text)
      flush decoder parts callback = do
        decode <- readIORef decoder
        let TE.Some _ leftover _ = decode ""
        writeIORef decoder (TE.streamDecodeUtf8With lenientDecode)
        unless (B.null leftover) (modifyIORef' parts ("\65533" :) >> callback "\65533")
      flushAll = flush stdoutDecoder stdoutParts onStdout >> flush stderrDecoder stderrParts onStderr
      loop =
        readEnvelope stream >>= \case
          Nothing -> pure Nothing
          Just (flags, payload)
            | flags .&. 2 /= 0 -> pure (endStreamFailure payload)
            | otherwise -> do
                decodeEvent payload >>= \case
                  EventStdout chunk -> feed stdoutDecoder stdoutParts onStdout chunk
                  EventStderr chunk -> feed stderrDecoder stderrParts onStderr chunk
                  EventEnd code err -> flushAll >> writeIORef ended (Just (code, err))
                  _ -> pure ()
                loop
  failure <- (loop `onException` flushAll) <* H.responseClose (streamResponse stream)
  result <- readIORef ended
  case (failure, result) of
    (Just problem, _) -> flushAll >> throwIO (rpcError problem)
    (Nothing, Nothing) -> flushAll >> throwSdk "Exception" "Command ended without an end event"
    (Nothing, Just (code, _)) -> do
      out <- T.concat . reverse <$> readIORef stdoutParts
      err <- T.concat . reverse <$> readIORef stderrParts
      pure (E2bCommandResult (fromInteger code) out err)
