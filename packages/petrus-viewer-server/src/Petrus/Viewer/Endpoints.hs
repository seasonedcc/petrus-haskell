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
  , ResolveResult (..)
  , resolveRef
  , readFileNode
  ) where

import Control.Exception (IOException, bracket, try)
import Data.ByteString qualified as B
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types qualified as H
import Network.Wai qualified as W
import Petrus.Viewer.Json
import Petrus.Viewer.Http (lbsResponse)
import Petrus.Viewer.Url
import Petrus.Viewer.UrlCache
import System.Directory (doesPathExist)
import System.IO.Error (isDoesNotExistError, isPermissionError)
import System.Posix.Files (fileSize, getFdStatus)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, fdReadBuf, openFd)

-- | The pending file (consumed by the next GET) and its source URL.
data OpenFileState = OpenFileState (IORef (Maybe FilePath, Maybe Text))

newOpenFileState :: Maybe FilePath -> Maybe Text -> IO OpenFileState
newOpenFileState f u = OpenFileState <$> newIORef (f, u)

pendingOpenFile :: OpenFileState -> IO (Maybe FilePath, Maybe Text)
pendingOpenFile (OpenFileState ref) = readIORef ref

corsHeaders :: B.ByteString -> H.ResponseHeaders
corsHeaders methods =
  [ ("Access-Control-Allow-Origin", "*")
  , ("Access-Control-Allow-Methods", methods)
  , ("Access-Control-Allow-Headers", "Content-Type")
  ]

jsonResponse :: H.Status -> H.ResponseHeaders -> JsValue -> W.Response
jsonResponse st hs v = lbsResponse st (hs ++ [("Content-Type", "application/json")]) (encodeJsLazy v)

errorBody :: Text -> JsValue
errorBody msg = obj [("error", str msg)]

endpointsMiddleware :: OpenFileState -> HC.Manager -> W.Middleware
endpointsMiddleware st mgr app req respond
  | url == "/__petrus/open-file" = openFile st req respond
  | url == "/__petrus/resolve-ref" && method == "OPTIONS" =
      respond (lbsResponse H.status204 (corsHeaders "POST, OPTIONS") "")
  | url == "/__petrus/resolve-ref" && method == "POST" = do
      body <- readBody req
      result <- resolveRefBody mgr body
      respond (resolveResponse result)
  | otherwise = app req respond
  where
    -- Node compares req.url, i.e. path plus query string, exactly
    url = W.rawPathInfo req <> W.rawQueryString req
    method = W.requestMethod req

readBody :: W.Request -> IO B.ByteString
readBody req = decodeLenient . BL.toStrict <$> W.strictRequestBody req

openFile :: OpenFileState -> W.Application
openFile (OpenFileState ref) req respond = case W.requestMethod req of
  "OPTIONS" -> respond (lbsResponse H.status204 cors "")
  "GET" -> do
    (pending, src) <- readIORef ref
    case pending of
      Nothing -> respond (lbsResponse H.status204 cors "")
      Just path -> do
        r <- readFileNode path
        case r of
          Left err -> respond (jsonResponse H.status500 cors (errorBody err))
          Right content -> do
            writeIORef ref (Nothing, Nothing)
            respond . jsonResponse H.status200 cors $
              obj [("path", str (T.pack path)), ("content", str content), ("sourceUrl", maybe JsNull str src)]
  "POST" -> do
    body <- readBody req
    case parseJs body of
      Left _ -> respond (jsonResponse H.status400 cors (errorBody "Invalid request body"))
      Right JsNull -> respond (jsonResponse H.status400 cors (errorBody "Invalid request body"))
      Right v -> do
        let filePath = case v of
              JsObj o -> lookupKey "path" o
              _ -> Nothing
        exists <- case filePath of
          Just (JsStr s) | not (T.null (jsStringText s)) -> doesPathExist (T.unpack (jsStringText s))
          _ -> pure False
        case filePath of
          Just (JsStr s) | exists -> do
            modifyIORef' ref (\(_, u) -> (Just (T.unpack (jsStringText s)), u))
            respond (jsonResponse H.status200 cors (obj [("ok", JsBool True), ("path", JsStr s)]))
          _ -> respond (jsonResponse H.status400 cors (errorBody "File not found"))
  _ -> respond (lbsResponse H.status405 cors "")
  where
    cors = corsHeaders "GET, POST, OPTIONS"

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

-- | The whole file: open, fstat, read to EOF, close, without the 'Handle'
-- machinery (buffers, locking) that dominates small reads.
readFileBytes :: FilePath -> IO B.ByteString
readFileBytes path = bracket (openFd path ReadOnly defaultFileFlags) closeFd $ \fd -> do
  size <- fromIntegral . fileSize <$> getFdStatus fd
  let chunkSize = max 4096 (size + 1) :: Int
      readChunk = BI.createAndTrim chunkSize $ \p -> fromIntegral <$> fdReadBuf fd p (fromIntegral chunkSize)
      go acc = do
        chunk <- readChunk
        if B.null chunk then pure (B.concat (reverse acc)) else go (chunk : acc)
  go []

data ResolveResult
  = Resolved JsValue
  | ResolveError Text

resolveResponse :: ResolveResult -> W.Response
resolveResponse = \case
  Resolved v -> jsonResponse H.status200 (corsHeaders "POST, OPTIONS") v
  ResolveError msg -> jsonResponse H.status400 (corsHeaders "POST, OPTIONS") (errorBody msg)

resolveRefBody :: HC.Manager -> B.ByteString -> IO ResolveResult
resolveRefBody mgr body = case parseJs body of
  Left e -> pure (ResolveError (T.pack e))
  Right JsNull -> pure (ResolveError "Cannot destructure property 'ref' of 'JSON.parse(...)' as it is null.")
  Right v -> do
    let field k = case v of
          JsObj o -> lookupKey k o
          _ -> Nothing
        ref = field "ref"
        basePath = field "basePath"
    if not (maybe False truthy ref) || not (maybe False truthy basePath)
      then pure (ResolveError "Missing ref or basePath")
      else case (ref, basePath) of
        (Just (JsStr r), Just b) -> resolveRef mgr (jsStringText r) (jsToString b)
        _ -> pure (ResolveError "ref.endsWith is not a function")

-- | Resolve a ref against a base path (the body of the POST handler).
resolveRef :: HC.Manager -> Text -> Text -> IO ResolveResult
resolveRef mgr ref basePath = do
  let normalizedRef = if ".json" `T.isSuffixOf` ref then ref else ref <> ".json"
  case resolveUrl normalizedRef basePath of
    Nothing -> pure (ResolveError "Invalid URL")
    Just u -> do
      let resolvedUrl = serializeUrl u
      case urlScheme u of
        "file" -> case decodeURIComponent (urlPathname u) of
          Left e -> pure (ResolveError e)
          Right filePath -> do
            exists <- doesPathExist (T.unpack filePath)
            if not exists
              then pure (ResolveError ("File not found: " <> filePath))
              else do
                r <- readFileNode (T.unpack filePath)
                pure $ case r of
                  Left e -> ResolveError e
                  Right content -> Resolved (obj [("content", str content), ("resolvedPath", str ("file://" <> filePath))])
        s
          | s == "https" || s == "http" -> do
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
        _ -> pure (ResolveError ("Unsupported protocol: " <> urlProtocol u))
