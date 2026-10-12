{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The authenticated client stack under 'Hamsterdan.GitHub.Transport':
-- what @GitHubAppClients@, GitHubKit's @AppAuth@, httpx's @Client.send@ and
-- hishel do between a request path and the bytes on the wire.
--
-- * Every request goes to @https://api.github.com@ with httpx's headers, in
--   httpx's order, and an @Authorization@ chosen by GitHubKit's route rules:
--   the App JWT for App routes, an installation token otherwise.
-- * Installation tokens are minted on demand
--   (@POST /app/installations/{id}/access_tokens@, scoped to the exact
--   repository ids) and cached with GitHubKit's expiry; the JWT is cached
--   for eight minutes. The cache is shared by every client of one
--   'AppClients', as GitHubKit's @MemCacheStrategy@ is.
-- * Responses pass through the shared HTTP cache ('Hamsterdan.GitHub.Cache')
--   and the metadata hook, and a redirect is never followed.
--
-- The network is the 'Exchange' in 'ClientOptions', so tests and the
-- differential corpus drive this whole stack without a socket.
module Hamsterdan.GitHub.Client
  ( -- * Clients
    AppClients
  , ClientOptions (..)
  , defaultClientOptions
  , AppCredentials (..)
  , newAppClients
  , GitHubClient
  , appClient
  , installationClient
  , inventoryClient
  , clientInstallation

    -- * Requests
  , ClientResponse (..)
  , sendRequest
  , RequestMetadata (..)

    -- * Pieces (exported for tests)
  , appRoute
  , installationCacheKey
  , parseExpiresAt
  , validateInstallationToken
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (GeneralCategory (DecimalNumber), generalCategory, isAsciiUpper, toLower)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Calendar (fromGregorianValid, toModifiedJulianDay)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Hamsterdan.GitHub.Cache (CacheRequest (..), CacheResponse (..), CacheStore, cachedSend, newCacheStore)
import Hamsterdan.GitHub.Http
import Hamsterdan.GitHub.Jwt (SigningKey, appJwt, loadSigningKey)
import Hamsterdan.Python (PythonException (..), pythonExceptionStr)
import Hamsterdan.Python qualified as Py
import Hamsterdan.GitHub.Url qualified as Url
import Petrus.Json (Json (..), parseJson, surrogateRefusingLoads)

-- | The App identity GitHubKit authenticates as.
data AppCredentials = AppCredentials
  { appId :: Integer
  , clientId :: Text
  , privateKey :: Text
  -- ^ The PEM private key.
  }

-- | @RequestMetadata@: what the metadata hook learns of every response.
data RequestMetadata = RequestMetadata
  { method :: Text
  , path :: Text
  , requestId :: Maybe Text
  , rateLimitRemaining :: Maybe Integer
  , rateLimitReset :: Maybe Integer
  , status :: Int
  }
  deriving stock (Eq, Show)

-- | The injectable effects of the client stack.
data ClientOptions = ClientOptions
  { exchange :: Exchange
  -- ^ The network.
  , clock :: IO Double
  -- ^ POSIX seconds; GitHubKit's @datetime.now@ and hishel's @time.time@.
  , metadataHook :: Maybe (RequestMetadata -> IO ())
  }

-- | The production options over a fresh TLS manager.
defaultClientOptions :: IO ClientOptions
defaultClientOptions = do
  exchange <- newRealExchange
  pure ClientOptions {exchange, clock = realToFrac <$> getPOSIXTime, metadataHook = Nothing}

-- | @GitHubAppClients@: the App and installation clients of one process
-- and registration, sharing one token cache and one HTTP cache.
data AppClients = AppClients
  { credentials :: AppCredentials
  , options :: ClientOptions
  , signingKey :: IORef (Maybe (Either Text SigningKey))
  , memCache :: IORef (Map Text (Text, Double))
  , httpCache :: CacheStore
  }

-- | One GitHubKit client: the App itself, or an installation (optionally
-- restricted to exact repository ids).
data GitHubClient = GitHubClient
  { owner :: AppClients
  , installation :: Maybe (Integer, Maybe [Integer])
  }

newAppClients :: AppCredentials -> ClientOptions -> IO AppClients
newAppClients credentials options = do
  signingKey <- newIORef Nothing
  memCache <- newIORef Map.empty
  httpCache <- newCacheStore
  pure AppClients {credentials, options, signingKey, memCache, httpCache}

-- | @GitHubAppClients.app@.
appClient :: AppClients -> GitHubClient
appClient owner = GitHubClient {owner, installation = Nothing}

-- | @GitHubAppClients.installation@: 'Left' is the @ValueError@ message.
installationClient :: AppClients -> Integer -> [Integer] -> Either Text GitHubClient
installationClient owner installationId repositoryIds
  | installationId <= 0 = Left "installation id is malformed"
  | null canonical || any (<= 0) canonical = Left "repository ids are malformed"
  | otherwise = Right GitHubClient {owner, installation = Just (installationId, Just canonical)}
  where
    canonical = sort (nub repositoryIds)

-- | @GitHubAppClients.inventory@: an installation client without a
-- repository allow-list, for inventory discovery only.
inventoryClient :: AppClients -> Integer -> Either Text GitHubClient
inventoryClient owner installationId
  | installationId <= 0 = Left "installation id is malformed"
  | otherwise = Right GitHubClient {owner, installation = Just (installationId, Nothing)}

clientInstallation :: GitHubClient -> Maybe (Integer, Maybe [Integer])
clientInstallation client = client.installation

-- | A response as httpx returns it from @send(stream=True)@: ASCII headers
-- (lowercase, merged) and the raw, still content-encoded body.
data ClientResponse = ClientResponse
  { status :: Int
  , headers :: Headers
  , chunks :: IO ByteString
  }

-- | @client.send(client.build_request(method, path, json=body),
-- stream=True)@ on a GitHubKit client. The body is the compact JSON httpx
-- writes; the response is usable inside the continuation only.
sendRequest :: GitHubClient -> Text -> Text -> Maybe ByteString -> (ClientResponse -> IO a) -> IO a
sendRequest client method path body continue = do
  url <- either (throwIO . uncaught "InvalidURL") pure (Url.apiUrl path)
  let contentHeaders = case body of
        Just bytes -> [("content-length", T.pack (show (BS.length bytes))), ("content-type", "application/json")]
        Nothing -> []
      emptyLength = [("content-length", "0") | body == Nothing, method `elem` ["POST", "PUT", "PATCH"]]
      headers =
        [("host", Url.apiHost)]
          <> emptyLength
          <> [ ("accept-encoding", "gzip, deflate")
             , ("connection", "keep-alive")
             , ("user-agent", "GitHubKit/Python")
             , ("accept", "application/vnd.github+json")
             , ("cache-control", "no-cache")
             ]
          <> contentHeaders
      request = CacheRequest {method, url = Url.urlText url, requestHeaders = headers, body = fromMaybe "" body}
  authorized <- authorize client (Url.decodedPath url) request
  dispatch client.owner (Url.decodedPath url) authorized continue

-- | GitHubKit's @AppAuth.sync_auth_flow@.
authorize :: GitHubClient -> Text -> CacheRequest -> IO CacheRequest
authorize client decoded request
  | bypassRoute decoded = pure request
  | otherwise = do
      route <- either (throwIO . uncaught "InvalidURL") pure (apiRoute decoded)
      if
        | appRoute route -> do
            jwt <- currentJwt client.owner
            pure (withAuthorization ("Bearer " <> jwt))
        | basicRoute decoded ->
            throwIO (githubFailure "AuthCredentialError" "GitHub APP's client_id and client_secret must be provided for application apis")
        | otherwise -> case client.installation of
            Nothing ->
              throwIO (githubFailure "AuthCredentialError" "GitHub APP installation_id must be provided for accessing apis as an installation")
            Just (installationId, repositoryIds) -> do
              let key = installationCacheKey client.owner.credentials.appId installationId repositoryIds
              cached <- memGet client.owner key
              token <- case cached of
                Just token | not (T.null token) -> pure token
                _ -> mint client.owner installationId repositoryIds key
              pure (withAuthorization ("token " <> token))
  where
    withAuthorization value = request {requestHeaders = request.requestHeaders <> [("authorization", value)]}

-- | @AppAuth.INSTALLATION_CACHE_KEY@ for an installation and its
-- (canonical) repository ids.
installationCacheKey :: Integer -> Integer -> Maybe [Integer] -> Text
installationCacheKey issuer installationId repositoryIds =
  "githubkit:auth:app:" <> T.pack (show issuer) <> ":installation:" <> T.pack (show installationId) <> ":::" <> T.intercalate "," (map (T.pack . show) (fromMaybe [] repositoryIds))

-- | @_get_api_route@: the route GitHubKit matches App routes against, after
-- a round trip through @httpx.URL(path=…)@. 'Left' is httpx's
-- @InvalidURL@ message.
apiRoute :: Text -> Either Text Text
apiRoute decoded = do
  let stripped = T.drop 1 decoded
      route = if "/" `T.isPrefixOf` stripped then stripped else "/" <> stripped
  when (T.length route > 65536) (Left "URL component 'path' too long")
  forM_ (T.findIndex (\c -> c < ' ' || c == '\DEL') route) $ \index ->
    Left ("Invalid non-printable ASCII character in URL path component, " <> asciiRepr (T.index route index) <> " at position " <> T.pack (show index) <> ".")
  when (T.any (`elem` ['?', '#']) route) (Left "Invalid URL component 'path'")
  when ("//" `T.isPrefixOf` route) (Left "Relative URLs cannot have a path starting with '//'")
  Right (Url.unquote route)
  where
    asciiRepr = Py.strRepr . T.singleton

-- | GitHubKit's @BYPASS_REGEX@ (searched).
bypassRoute :: Text -> Bool
bypassRoute decoded =
  let body = fromMaybe decoded (T.stripSuffix "\n" decoded)
   in any (`T.isSuffixOf` decoded) suffixes || any (`T.isSuffixOf` body) suffixes
  where
    suffixes = ["/login/oauth/access_token", "/login/device/code"]

-- | GitHubKit's @BASIC_AUTH_REGEX@ (searched).
basicRoute :: Text -> Bool
basicRoute decoded = any candidate (drop 1 (T.splitOn "/applications/" decoded))
  where
    candidate rest =
      let (name, after) = T.break (== '/') rest
       in not (T.null name) && any (`T.isPrefixOf` T.drop 1 after) ["token", "grant"]

-- | One App-route pattern: literals and @(?:.+?)@ wildcards.
data Piece = Lit String | Wild

-- | GitHubKit's @APP_AUTH_REGEX@: a case-insensitive full match (Python's
-- @$@ admits one trailing newline).
appRoute :: Text -> Bool
appRoute route =
  let folded = map fold (T.unpack route)
      candidates = folded : [init folded | not (null folded), last folded == '\n']
   in or [matches pattern candidate | pattern <- routes, candidate <- candidates]
  where
    -- Python's IGNORECASE: ASCII case plus the code points whose simple
    -- case mapping or sre equivalence lands on an ASCII letter.
    fold c
      | isAsciiUpper c = toLower c
      | c == '\x130' || c == '\x131' = 'i'
      | c == '\x17f' = 's'
      | c == '\x212a' = 'k'
      | otherwise = c
    matches pieces input = case pieces of
      [] -> null input
      Lit text : rest -> case splitAt (length text) input of
        (prefix, remainder) | prefix == text -> matches rest remainder
        _ -> False
      Wild : rest -> go rest input (1 :: Int)
      where
        go rest text n
          | n > length text = False
          | '\n' `elem` take n text = False
          | matches rest (drop n text) = True
          | otherwise = go rest text (n + 1)
    routes =
      map
        parse
        [ "/app"
        , "/app/hook/config"
        , "/app/hook/deliveries"
        , "/app/hook/deliveries/*"
        , "/app/hook/deliveries/*/attempts"
        , "/app/installations"
        , "/app/installations/*"
        , "/app/installations/*/access_tokens"
        , "/app/installations/*/suspended"
        , "/app/installation-requests"
        , "/marketplace_listing/accounts/*"
        , "/marketplace_listing/plan"
        , "/marketplace_listing/plans"
        , "/marketplace_listing/plans/*/accounts"
        , "/marketplace_listing/stubbed/accounts/*"
        , "/marketplace_listing/stubbed/plan"
        , "/marketplace_listing/stubbed/plans"
        , "/marketplace_listing/stubbed/plans/*/accounts"
        , "/orgs/*/installation"
        , "/repos/*/*/installation"
        , "/users/*/installation"
        ]
    parse :: String -> [Piece]
    parse = \case
      [] -> []
      '*' : rest -> Wild : parse rest
      text -> let (literal, rest) = break (== '*') text in Lit literal : parse rest

-- | The App JWT from the token cache, signing a new one when absent.
currentJwt :: AppClients -> IO Text
currentJwt owner = do
  let issuer = T.pack (show owner.credentials.appId)
      key = "githubkit:auth:app:" <> issuer <> ":jwt"
  cached <- memGet owner key
  case cached of
    Just token | not (T.null token) -> pure token
    _ -> do
      signing <- signingKeyOf owner
      now <- owner.options.clock
      token <- either (throwIO . uncaught "InvalidKeyError") pure (appJwt signing issuer (floor now))
      memSet owner key token 480
      pure token

signingKeyOf :: AppClients -> IO SigningKey
signingKeyOf owner = do
  loaded <- readIORef owner.signingKey
  parsed <- case loaded of
    Just value -> pure value
    Nothing -> do
      let value = loadSigningKey owner.credentials.privateKey
      atomicModifyIORef' owner.signingKey (const (Just value, ()))
      pure value
  either (throwIO . uncaught "InvalidKeyError") pure parsed

-- | GitHubKit's @MemCache.get@: expired items are dropped first.
memGet :: AppClients -> Text -> IO (Maybe Text)
memGet owner key = do
  now <- owner.options.clock
  atomicModifyIORef' owner.memCache $ \cache ->
    let live = Map.filter (\(_, expireAt) -> not (expireAt < now)) cache
     in (live, fst <$> Map.lookup key live)

-- | @MemCache.set(key, value, timedelta(seconds=ttl))@.
memSet :: AppClients -> Text -> Text -> Double -> IO ()
memSet owner key value ttl = do
  now <- owner.options.clock
  atomicModifyIORef' owner.memCache $ \cache ->
    (Map.insert key (value, now + ttl) (Map.filter (\(_, expireAt) -> not (expireAt < now)) cache), ())

-- | Mint an installation token (GitHubKit's token request and response
-- check) and cache it until a minute before it expires.
mint :: AppClients -> Integer -> Maybe [Integer] -> Text -> IO Text
mint owner installationId repositoryIds key = do
  jwt <- currentJwt owner
  let path = "/app/installations/" <> T.pack (show installationId) <> "/access_tokens"
      body = case repositoryIds of
        Just ids -> "{\"repository_ids\":[" <> T.intercalate "," (map (T.pack . show) ids) <> "]}"
        Nothing -> "{}"
      bytes = TE.encodeUtf8 body
      request =
        CacheRequest
          { method = "POST"
          , url = "https://" <> Url.apiHost <> path
          , requestHeaders =
              [ ("host", Url.apiHost)
              , ("user-agent", "GitHubKit/Python")
              , ("accept", "application/vnd.github+json")
              , ("content-length", T.pack (show (BS.length bytes)))
              , ("content-type", "application/json")
              , ("authorization", "Bearer " <> jwt)
              ]
          , body = bytes
          }
  (token, expiresAt) <- dispatch owner path request $ \response -> do
    decoder <- contentDecoder response.headers response.chunks
    content <- readAll decoder
    checkTokenResponse response content
  now <- owner.options.clock
  when (expiresAt - 60 < minimumDatetime) $
    throwIO (uncaught "OverflowError" "date value out of range")
  memSet owner key token (expiresAt - now - 60)
  pure token
  where
    -- 0001-01-01T00:00:00Z.
    minimumDatetime = -62135596800

-- | GitHubKit's @_check@ and @InstallationToken@ parsing of a token
-- response: the token and its expiry (POSIX seconds).
checkTokenResponse :: ClientResponse -> ByteString -> IO (Text, Double)
checkTokenResponse response content = do
  let isError = response.status >= 400 && response.status <= 599
  when (response.status == 403 || response.status == 429) (checkRateLimit response content)
  when isError (throwIO (githubFailure "RequestFailed" ("Request failed with status " <> T.pack (show response.status))))
  (token, expiresAt) <- either (throwIO . valueFailure "ValidationError") pure (validateInstallationToken content)
  expiry <- either (throwIO . valueFailure "ValueError") pure (parseExpiresAt expiresAt)
  pure (token, fromInteger expiry)

-- | GitHubKit's @_check_rate_limit@ for a 403 or 429 token response.
checkRateLimit :: ClientResponse -> ByteString -> IO ()
checkRateLimit response content = do
  case lookupHeader "retry-after" response.headers of
    Just value -> do
      seconds <- either throwIO pure (pyIntValue value)
      checkTimedelta seconds
      throwIO (githubFailure "SecondaryRateLimitExceeded" "secondary rate limit exceeded")
    Nothing -> pure ()
  when (lookupHeader "x-ratelimit-remaining" response.headers == Just "0") $ do
    case lookupHeader "x-ratelimit-reset" response.headers of
      Just value -> do
        reset <- either throwIO pure (pyIntValue value)
        if
          | reset > 9223372036854775807 || reset < -9223372036854775808 ->
              throwIO (uncaught "OverflowError" "timestamp out of range for platform time_t")
          | reset >= 67768036191676800 || reset <= -67768040609740801 ->
              throwIO (ClientError OsKind "OSError" "[Errno 84] Value too large to be stored in data type")
          | reset > 253402300799 || reset < -62135596800 ->
              throwIO (valueFailure "ValueError" "year is out of range")
          | otherwise -> pure ()
      Nothing -> pure ()
    let parsed = either (const Nothing) Just (Py.loadsBytes content)
    secondary <- case parsed of
      Just (Object members) | Just message <- lookup "message" (lastWins members) -> case message of
        String text -> pure ("secondary rate" `T.isInfixOf` text)
        Array items -> pure (any (\item -> item == String "secondary rate") items)
        Object entries -> pure (isJust (lookup "secondary rate" entries))
        other -> throwIO (uncaught "TypeError" ("argument of type '" <> pyTypeName other <> "' is not a container or iterable"))
      _ -> pure False
    throwIO (githubFailure (if secondary then "SecondaryRateLimitExceeded" else "PrimaryRateLimitExceeded") "rate limit exceeded")
  where
    pyIntValue value = either (\failure@(PythonException cls _) -> Left (valueFailure cls (pythonExceptionStr failure))) Right (Py.intText value)
    checkTimedelta seconds =
      when (seconds > 86399999999999 || seconds < -86399999913600) $
        throwIO (uncaught "OverflowError" "days must have magnitude <= 999999999")
    lastWins members = reverse members
    pyTypeName = \case
      Null -> "NoneType"
      Bool _ -> "bool"
      Int _ -> "int"
      Float _ -> "float"
      String _ -> "str"
      Array _ -> "list"
      Object _ -> "dict"

-- | Pydantic's validation of GitHubKit's @InstallationToken@ model from
-- JSON: the token and @expires_at@ strings, and the optional members'
-- types (each may be @null@). Items of @repositories@ must be objects,
-- but their members are not validated (see DIVERGENCES.md). 'Left' describes the failure.
-- GitHubKit validates the body with pydantic's @validate_json@, whose JSON
-- parser (jiter) refuses a lone surrogate escape, as this one does.
validateInstallationToken :: ByteString -> Either Text (Text, Text)
validateInstallationToken content = do
  document <- either (Left . ("Invalid JSON: " <>) . T.pack) Right (parseJson surrogateRefusingLoads content)
  members <- case document of
    Object members -> Right members
    _ -> Left "Input should be an object"
  let field name = lookup name (reverse members)
  token <- case field "token" of
    Just (String text) -> Right text
    _ -> Left "token: Input should be a valid string"
  expiresAt <- case field "expires_at" of
    Just (String text) -> Right text
    _ -> Left "expires_at: Input should be a valid string"
  optional "permissions" (field "permissions") permissions
  optional "repository_selection" (field "repository_selection") (\case String s -> s `elem` ["all", "selected"]; _ -> False)
  optional "repositories" (field "repositories") (\case Array items -> all (\case Object _ -> True; _ -> False) items; _ -> False)
  optional "single_file" (field "single_file") (\case String _ -> True; _ -> False)
  optional "has_multiple_single_files" (field "has_multiple_single_files") laxBool
  optional "single_file_paths" (field "single_file_paths") (\case Array items -> all (\case String _ -> True; _ -> False) items; _ -> False)
  Right (token, expiresAt)
  where
    optional name value valid = case value of
      Nothing -> Right ()
      Just Null -> Right ()
      Just other -> unless (valid other) (Left (name <> ": invalid"))
    laxBool = \case
      Bool _ -> True
      Int n -> n == 0 || n == 1
      Float d -> d == 0 || d == 1
      String s -> T.toLower s `elem` ["0", "off", "f", "false", "n", "no", "1", "on", "t", "true", "y", "yes"]
      _ -> False
    permissions = \case
      Object entries ->
        and
          [ case lookup name permissionValues of
              Just allowed -> case value of
                Null -> True
                String s -> s `elem` allowed
                _ -> False
              Nothing -> True
          | (name, value) <- lastWinsMembers entries
          ]
      _ -> False
    lastWinsMembers entries = Map.toList (Map.fromList entries)

-- | AppPermissions' admitted values per permission.
permissionValues :: [(Text, [Text])]
permissionValues =
  [ (name, ["read", "write"])
  | name <-
      [ "actions", "administration", "artifact_metadata", "attestations", "checks", "code_quality", "codespaces", "contents"
      , "dependabot_secrets", "deployments", "discussions", "environments", "issues", "merge_queues", "metadata", "packages"
      , "pages", "pull_requests", "repository_custom_properties", "repository_hooks", "secret_scanning_alerts", "secrets"
      , "security_events", "single_file", "statuses", "vulnerability_alerts", "custom_properties_for_organizations", "members"
      , "organization_administration", "organization_custom_roles", "organization_custom_org_roles"
      , "organization_copilot_seat_management", "organization_copilot_agent_settings", "organization_announcement_banners"
      , "organization_hooks", "organization_personal_access_tokens", "organization_personal_access_token_requests"
      , "organization_packages", "organization_secrets", "organization_self_hosted_runners", "organization_user_blocking"
      , "email_addresses", "followers", "git_ssh_keys", "gpg_keys", "interaction_limits", "starring"
      ]
  ]
    <> [ (name, ["read", "write", "admin"])
       | name <- ["repository_projects", "organization_custom_properties", "organization_projects", "enterprise_custom_properties_for_organizations"]
       ]
    <> [("workflows", ["write"]), ("profile", ["write"]), ("organization_events", ["read"]), ("organization_plan", ["read"])]

-- | @datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")@ as POSIX seconds
-- (UTC). 'Left' is the @ValueError@ message.
parseExpiresAt :: Text -> Either Text Integer
parseExpiresAt value = do
  let input = T.unpack value
  (groups, rest) <- maybe bad Right (matchFormat input)
  unless (null rest) (Left ("unconverted data remains: " <> T.pack rest))
  numbers <- traverse (maybe bad Right . Py.pyIntBase 10 . T.pack) groups
  (year, month, day, hour, minute, second) <- case numbers of
    [y, mo, d, h, mi, s] -> Right (y, mo, d, h, mi, s)
    _ -> bad
  when (year < 1) (Left ("year " <> T.pack (show year) <> " is out of range"))
  first <- maybe (Left ("year " <> T.pack (show year) <> " is out of range")) Right (fromGregorianValid year (fromInteger month) 1)
  _ <- maybe (Left "day is out of range for month") Right (fromGregorianValid year (fromInteger month) (fromInteger day))
  when (second > 59) (Left "second must be in 0..59")
  let days = toModifiedJulianDay first - 40587 + day - 1
  Right (((days * 24 + hour) * 60 + minute) * 60 + second)
  where
    bad :: Either Text a
    bad = Left ("time data " <> T.pack (show value) <> " does not match format '%Y-%m-%dT%H:%M:%SZ'")
    digit c = generalCategory c == DecimalNumber
    range lo hi c = c >= lo && c <= hi
    -- Each field's alternatives, in the regular expression's order.
    yearField = [[digit, digit, digit, digit]]
    monthField = [[(== '1'), range '0' '2'], [(== '0'), range '1' '9'], [range '1' '9']]
    dayField = [[(== '3'), range '0' '1'], [range '1' '2', digit], [(== '0'), range '1' '9'], [range '1' '9'], [(== ' '), range '1' '9']]
    hourField = [[(== '2'), range '0' '3'], [range '0' '1', digit], [digit]]
    minuteField = [[range '0' '5', digit], [digit]]
    secondField = [[(== '6'), range '0' '1'], [range '0' '5', digit], [digit]]
    literal expected c = toLower c == expected
    fields = [(yearField, Just '-'), (monthField, Just '-'), (dayField, Just 't'), (hourField, Just ':'), (minuteField, Just ':'), (secondField, Just 'z')]
    matchFormat input = go fields input []
    go [] text acc = Just (reverse acc, text)
    go ((alternatives, separator) : more) text acc =
      firstJust
        [ case separator of
            Just sep -> case drop (length alternative) text of
              c : rest | literal sep c -> go more rest (take (length alternative) text : acc)
              _ -> Nothing
            Nothing -> go more (drop (length alternative) text) (take (length alternative) text : acc)
        | alternative <- alternatives
        , length alternative <= length text
        , and (zipWith ($) alternative text)
        ]
    firstJust = \case
      [] -> Nothing
      Just x : _ -> Just x
      Nothing : rest -> firstJust rest

-- | httpx's @_send_handling_redirects@ for one request (redirects are
-- never followed), over the shared HTTP cache: the response as httpx
-- hands it back, after the metadata hook.
dispatch :: AppClients -> Text -> CacheRequest -> (ClientResponse -> IO a) -> IO a
dispatch owner decoded request continue =
  cachedSend owner.httpCache owner.options.clock (wireSender owner.options.exchange) request $ \cached -> do
    headers <- asciiHeaders cached.responseHeaders
    let response = ClientResponse {status = cached.status, headers, chunks = cached.chunks}
    forM_ owner.options.metadataHook $ \hook ->
      hook
        RequestMetadata
          { method = request.method
          , path = decoded
          , requestId = lookupHeader "x-github-request-id" headers
          , rateLimitRemaining = integerHeader "x-ratelimit-remaining" headers
          , rateLimitReset = integerHeader "x-ratelimit-reset" headers
          , status = cached.status
          }
    when (response.status `elem` [301, 302, 303, 307, 308]) $
      forM_ (lookupHeader "location" headers) checkRedirectLocation
    continue response
  where
    integerHeader name headers = case lookupHeader name headers of
      Just value | Py.isAsciiDecimal value -> Just (read (T.unpack value))
      _ -> Nothing

-- | httpx builds the redirect request even when it will not follow it;
-- a malformed @Location@ fails there.
checkRedirectLocation :: Text -> IO ()
checkRedirectLocation location = case Url.httpxUrl location of
  Left message -> throwIO (transportFailure "RemoteProtocolError" ("Invalid URL in location header: " <> message <> "."))
  Right parsed ->
    when (not (T.null parsed.scheme) && T.null parsed.host && not (T.null parsed.path) && not ("/" `T.isPrefixOf` parsed.path)) $
      throwIO (uncaught "InvalidURL" "For absolute URLs, path must be empty or begin with '/'")

-- | hishel's @request_sender@ over the network: the request as httpx
-- re-encodes it, the response re-chunked to 128 KiB, and a @304@ read
-- (and decoded) eagerly.
wireSender :: Exchange -> CacheRequest -> (CacheResponse -> IO a) -> IO a
wireSender network request continue = do
  headers <- asciiHeaders request.requestHeaders
  let afterHost = T.drop (T.length ("https://" <> Url.apiHost)) request.url
      target = if T.null afterHost || "?" `T.isPrefixOf` afterHost then "/" <> afterHost else afterHost
      wire = HttpRequest {method = request.method, target, url = request.url, headers, body = request.body}
  let Exchange send = network
  send wire $ \(raw :: RawResponse) -> do
    let headers' = mergeHeaders (decodeHeaders raw.headers)
    chunked <- rechunk 131072 raw.readChunk
    if raw.status == 304
      then do
        decoder <- contentDecoder headers' chunked
        content <- readAll decoder
        let adjusted = case lookupHeader "content-encoding" headers' of
              Just _ -> setLength (BS.length content) (filter ((/= "content-encoding") . fst) headers')
              Nothing -> headers'
        reader <- replayChunks [content | not (BS.null content)]
        continue CacheResponse {status = 304, responseHeaders = adjusted, chunks = reader}
      else continue CacheResponse {status = raw.status, responseHeaders = headers', chunks = chunked}
  where
    setLength n hs = case break ((== "content-length") . fst) hs of
      (before, _ : after) -> before <> (("content-length", T.pack (show n)) : after)
      _ -> hs <> [("content-length", T.pack (show n))]

replayChunks :: [ByteString] -> IO (IO ByteString)
replayChunks stored = do
  remaining <- newIORef stored
  pure $ atomicModifyIORef' remaining $ \case
    [] -> ([], "")
    chunk : rest -> (rest, chunk)

-- | httpx's @ByteChunker(chunk_size)@ over a raw stream.
rechunk :: Int -> IO ByteString -> IO (IO ByteString)
rechunk size source = do
  buffer <- newIORef (BS.empty, False)
  let next = do
        (pending, ended) <- readIORef buffer
        if
          | BS.length pending >= size -> do
              let (chunk, rest) = BS.splitAt size pending
              atomicModifyIORef' buffer (const ((rest, ended), ()))
              pure chunk
          | ended -> do
              atomicModifyIORef' buffer (const ((BS.empty, True), ()))
              pure pending
          | otherwise -> do
              chunk <- source
              if BS.null chunk
                then atomicModifyIORef' buffer (const ((pending, True), ()))
                else atomicModifyIORef' buffer (const ((pending <> chunk, False), ()))
              next
  pure next
