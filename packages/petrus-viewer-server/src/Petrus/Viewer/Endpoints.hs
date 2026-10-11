-- | The HTTP endpoints of @server/openFileEndpoint.mjs@:
--
-- * @GET /__petrus/open-file@ returns the pending file once (204 when none);
-- * @POST /__petrus/open-file@ sets a new pending file by path;
-- * @POST /__petrus/resolve-ref@ resolves a net ref against a base path,
--   reading local files and fetching (and caching) remote ones.
--
-- Paths, status codes, headers, bodies, and error texts follow the Node
-- implementation.
module Petrus.Viewer.Endpoints
  ( OpenFileState
  , newOpenFileState
  , pendingOpenFile
  , endpointsMiddleware
  , Reply (..)
  , openFilePath
  , resolveRefPath
  , openFileReply
  , resolveRefOptions
  , ResolveResult (..)
  , ResolveStep (..)
  , resolveRefStep
  , resolveReply
  , resolveRef
  , readFileNode
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types qualified as H
import Network.Wai qualified as W
import Petrus.Viewer.FileIO (pathExists, readFileBytes)
import Petrus.Viewer.Json
import Petrus.Viewer.Http (lbsResponse)
import Petrus.Viewer.Url
import Petrus.Viewer.UrlCache
import System.IO.Error (isDoesNotExistError, isPermissionError)

-- | The pending file (consumed by the next GET) and its source URL.
data OpenFileState = OpenFileState (IORef (Maybe FilePath, Maybe Text))

newOpenFileState :: Maybe FilePath -> Maybe Text -> IO OpenFileState
newOpenFileState f u = OpenFileState <$> newIORef (f, u)

pendingOpenFile :: OpenFileState -> IO (Maybe FilePath, Maybe Text)
pendingOpenFile (OpenFileState ref) = readIORef ref

-- | A response as the handlers make it: the status, the headers the Node
-- handler sets (in its order), and the body. The server adds the framing
-- headers (@Date@, @Connection@, @Content-Length@).
data Reply = Reply
  { replyStatus :: H.Status
  , replyHeaders :: H.ResponseHeaders
  , replyBody :: B.ByteString
  }

replyResponse :: Reply -> W.Response
replyResponse (Reply st hs body) = lbsResponse st hs (BL.fromStrict body)

corsHeaders :: B.ByteString -> H.ResponseHeaders
corsHeaders methods =
  [ ("Access-Control-Allow-Origin", "*")
  , ("Access-Control-Allow-Methods", methods)
  , ("Access-Control-Allow-Headers", "Content-Type")
  ]

jsonReply :: H.Status -> H.ResponseHeaders -> JsValue -> Reply
jsonReply st hs v = Reply st (hs ++ [("Content-Type", "application/json")]) (encodeJs v)

errorBody :: Text -> JsValue
errorBody msg = obj [("error", str msg)]

endpointsMiddleware :: OpenFileState -> HC.Manager -> W.Middleware
endpointsMiddleware st mgr app req respond
  | url == openFilePath = openFileReply st method (readBody req) >>= respond . replyResponse
  | url == resolveRefPath && method == "OPTIONS" = respond (replyResponse resolveRefOptions)
  | url == resolveRefPath && method == "POST" = do
      body <- readBody req
      result <- resolveRefBody mgr body
      respond (replyResponse (resolveReply result))
  | otherwise = app req respond
  where
    -- Node compares req.url, i.e. path plus query string, exactly
    url = W.rawPathInfo req <> W.rawQueryString req
    method = W.requestMethod req

-- | The request targets the endpoints answer (Node compares @req.url@).
openFilePath, resolveRefPath :: B.ByteString
openFilePath = "/__petrus/open-file"
resolveRefPath = "/__petrus/resolve-ref"

readBody :: W.Request -> IO B.ByteString
readBody req = decodeLenient . BL.toStrict <$> W.strictRequestBody req

-- | Every method on @/__petrus/open-file@, given the method and the request
-- body (decoded leniently; read only by @POST@).
openFileReply :: OpenFileState -> H.Method -> IO B.ByteString -> IO Reply
openFileReply (OpenFileState ref) method getBody = case method of
  "OPTIONS" -> pure (Reply H.status204 cors "")
  "GET" -> do
    -- consume the pending file at once (another connection's GET must
    -- not read it too), and put it back if it cannot be read, as Node
    -- leaves it pending when readFileSync throws
    pending <- atomicModifyIORef' ref (\p -> ((Nothing, Nothing), p))
    case pending of
      (Nothing, _) -> pure (Reply H.status204 cors "")
      (Just path, src) -> do
        r <- readFileNode path
        case r of
          Left err -> do
            atomicModifyIORef' ref (\case (Nothing, Nothing) -> (pending, ()); now -> (now, ()))
            pure (jsonReply H.status500 cors (errorBody err))
          Right content ->
            pure . jsonReply H.status200 cors $
              obj [("path", str (T.pack path)), ("content", str content), ("sourceUrl", maybe JsNull str src)]
  "POST" -> do
    body <- getBody
    case parseJs body of
      Left _ -> pure (jsonReply H.status400 cors (errorBody "Invalid request body"))
      Right JsNull -> pure (jsonReply H.status400 cors (errorBody "Invalid request body"))
      Right v -> do
        let filePath = case v of
              JsObj o -> lookupKey "path" o
              _ -> Nothing
        exists <- case filePath of
          Just (JsStr s) | not (T.null (jsStringText s)) -> pathExists (T.unpack (jsStringText s))
          _ -> pure False
        case filePath of
          Just (JsStr s) | exists -> do
            atomicModifyIORef' ref (\(_, u) -> ((Just (T.unpack (jsStringText s)), u), ()))
            pure (jsonReply H.status200 cors (obj [("ok", JsBool True), ("path", JsStr s)]))
          _ -> pure (jsonReply H.status400 cors (errorBody "File not found"))
  _ -> pure (Reply H.status405 cors "")
  where
    cors = corsHeaders "GET, POST, OPTIONS"

resolveRefOptions :: Reply
resolveRefOptions = Reply H.status204 (corsHeaders "POST, OPTIONS") ""

-- | @fs.readFileSync(path, "utf-8")@ with Node's error messages.
readFileNode :: FilePath -> IO (Either Text Text)
readFileNode path = do
  r <- try @IOException (readFileBytes path)
  pure $ case r of
    Right bytes -> Right (TE.decodeUtf8With TE.lenientDecode bytes)
    Left e
      | isDoesNotExistError e -> Left (T.pack ("ENOENT: no such file or directory, open '" ++ path ++ "'"))
      | isPermissionError e -> Left (T.pack ("EACCES: permission denied, open '" ++ path ++ "'"))
      | "is a directory" `T.isInfixOf` T.toLower (T.pack (show e)) || "inappropriate type" `T.isInfixOf` T.toLower (T.pack (show e)) ->
          Left "EISDIR: illegal operation on a directory, read"
      | otherwise -> Left (T.pack (show e))

data ResolveResult
  = Resolved JsValue
  | ResolveError Text

resolveReply :: ResolveResult -> Reply
resolveReply = \case
  Resolved v -> jsonReply H.status200 (corsHeaders "POST, OPTIONS") v
  ResolveError msg -> jsonReply H.status400 (corsHeaders "POST, OPTIONS") (errorBody msg)

-- | Where a resolve-ref request stands before any network access: answered,
-- or waiting for a remote fetch of this URL.
data ResolveStep
  = ResolveDone ResolveResult
  | ResolveFetch Text

-- | Finish a step, fetching when it needs to.
runResolveStep :: HC.Manager -> ResolveStep -> IO ResolveResult
runResolveStep mgr = \case
  ResolveDone r -> pure r
  ResolveFetch url -> fetchRef mgr url

resolveRefBody :: HC.Manager -> B.ByteString -> IO ResolveResult
resolveRefBody mgr body = resolveRefStep body >>= runResolveStep mgr

-- | The POST handler up to the point where it would fetch.
resolveRefStep :: B.ByteString -> IO ResolveStep
resolveRefStep body = case parseJs body of
  Left e -> done (ResolveError (T.pack e))
  Right JsNull -> done (ResolveError "Cannot destructure property 'ref' of 'JSON.parse(...)' as it is null.")
  Right v -> do
    let field k = case v of
          JsObj o -> lookupKey k o
          _ -> Nothing
        ref = field "ref"
        basePath = field "basePath"
    if not (maybe False truthy ref) || not (maybe False truthy basePath)
      then done (ResolveError "Missing ref or basePath")
      else case (ref, basePath) of
        (Just (JsStr r), Just b) -> resolveRefLocal (jsStringText r) (jsToString b)
        _ -> done (ResolveError "ref.endsWith is not a function")
  where
    done = pure . ResolveDone

-- | Resolve a ref against a base path (the body of the POST handler).
resolveRef :: HC.Manager -> Text -> Text -> IO ResolveResult
resolveRef mgr ref basePath = resolveRefLocal ref basePath >>= runResolveStep mgr

-- | 'resolveRef' up to the point where it would fetch.
resolveRefLocal :: Text -> Text -> IO ResolveStep
resolveRefLocal ref basePath = do
  let normalizedRef = if ".json" `T.isSuffixOf` ref then ref else ref <> ".json"
  case resolveUrl normalizedRef basePath of
    Nothing -> done (ResolveError "Invalid URL")
    Just u -> do
      let resolvedUrl = serializeUrl u
      case urlScheme u of
        "file" -> case decodeURIComponent (urlPathname u) of
          Left e -> done (ResolveError e)
          Right filePath -> do
            exists <- pathExists (T.unpack filePath)
            if not exists
              then done (ResolveError ("File not found: " <> filePath))
              else do
                r <- readFileNode (T.unpack filePath)
                done $ case r of
                  Left e -> ResolveError e
                  Right content -> Resolved (obj [("content", str content), ("resolvedPath", str ("file://" <> filePath))])
        s
          | s == "https" || s == "http" -> pure (ResolveFetch resolvedUrl)
        _ -> done (ResolveError ("Unsupported protocol: " <> urlProtocol u))
  where
    done = pure . ResolveDone

-- | The remote branch: fetch, cache, answer.
fetchRef :: HC.Manager -> Text -> IO ResolveResult
fetchRef mgr resolvedUrl = do
  fr <- fetchText mgr resolvedUrl
  case fr of
    FetchHttpError code -> pure (ResolveError ("HTTP " <> T.pack (show code) <> ": " <> resolvedUrl))
    FetchFailed e -> pure (ResolveError ("Fetch failed: " <> e))
    FetchOk content -> do
      cached <- case slugifyUrl resolvedUrl of
        Right (Just slug) -> case cacheRelativePath resolvedUrl of
          Right rel -> either (const Nothing) Just <$> try @IOException (cacheFile slug rel content)
          Left _ -> pure Nothing
        _ -> pure Nothing
      pure . Resolved . obj $
        [("content", str content), ("resolvedPath", str resolvedUrl)]
          ++ maybe [] (\p -> [("cachedPath", str (T.pack p))]) cached
