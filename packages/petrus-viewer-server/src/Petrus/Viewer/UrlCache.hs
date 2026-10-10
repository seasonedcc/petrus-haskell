-- | Local caching of fetched net files (@server/urlCache.mjs@).
--
-- Files fetched from HTTP URLs are cached under @~/Documents/Petrus/<slug>/@
-- for offline access and editing.
module Petrus.Viewer.UrlCache
  ( slugifyUrl
  , getCacheDir
  , cacheRelativePath
  , cacheFile
  , joinPosix
  , normalizePosix
  , FetchResult (..)
  , fetchText
  , newFetchManager
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.List (intercalate)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Network.HTTP.Client qualified as H
import Network.HTTP.Client.TLS qualified as H
import Network.HTTP.Types qualified as HT
import Petrus.Viewer.Url
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.FilePath (takeDirectory)

-- | Directory slug for a URL: @org-repo-ref@ for raw GitHub content,
-- @host-dir-segments@ otherwise, 'Nothing' for @file:@ URLs. 'Left' carries
-- the @TypeError@ message for an unparsable URL.
slugifyUrl :: Text -> Either Text (Maybe Text)
slugifyUrl url = case parseUrl url of
  Nothing -> Left "Invalid URL"
  Just u
    | urlScheme u == "file" -> Right Nothing
    | otherwise ->
        let segs = pathSegs u
         in case segs of
              (org : repo : ref : _)
                | urlHostname u == "raw.githubusercontent.com" ->
                    Right (Just (T.intercalate "-" [org, repo, ref]))
              _ ->
                let dirSegs = if null segs then [] else init segs
                 in Right (Just (T.intercalate "-" (urlHostname u : dirSegs)))

pathSegs :: Url -> [Text]
pathSegs u = filter (not . T.null) (T.splitOn "/" (urlPathname u))

-- | @~/Documents/Petrus/<slug>@ (with @path.join@ normalization).
getCacheDir :: Text -> IO FilePath
getCacheDir slug = do
  home <- getHomeDirectory
  pure (joinPosix [home, "Documents", "Petrus", T.unpack slug])

-- | Relative file path for caching a URL.
cacheRelativePath :: Text -> Either Text Text
cacheRelativePath url = case parseUrl url of
  Nothing -> Left "Invalid URL"
  Just u ->
    let segs = pathSegs u
     in Right $
          if urlHostname u == "raw.githubusercontent.com"
            then
              if length segs > 3
                then T.intercalate "/" (drop 3 segs)
                else case segs of
                  [] -> "file.json"
                  _ -> last segs
            else T.intercalate "/" segs

-- | Write content under the cache directory; returns the absolute path.
cacheFile :: Text -> Text -> Text -> IO FilePath
cacheFile slug relativePath content = do
  dir <- getCacheDir slug
  let filePath = joinPosix [dir, T.unpack relativePath]
  createDirectoryIfMissing True (takeDirectory filePath)
  B.writeFile filePath (TE.encodeUtf8 content)
  pure filePath

-- | Node's @path.join@ on POSIX.
joinPosix :: [FilePath] -> FilePath
joinPosix parts = case filter (not . null) parts of
  [] -> "."
  ps -> normalizePosix (intercalate "/" ps)

-- | Node's @path.normalize@ on POSIX.
normalizePosix :: FilePath -> FilePath
normalizePosix p
  | null p = "."
  | otherwise =
      let absolute = take 1 p == "/"
          trailing = last p == '/'
          segs = foldl step [] (splitSlash p)
          step acc seg
            | null seg || seg == "." = acc
            | seg == ".." = case acc of
                (x : xs) | x /= ".." -> xs
                _ -> if absolute then acc else ".." : acc
            | otherwise = seg : acc
          body = intercalate "/" (reverse segs)
          withTrail b = if trailing && not (null b) then b ++ "/" else b
       in case (absolute, body) of
            (True, _) -> "/" ++ withTrail body
            (False, "") -> if trailing then "./" else "."
            (False, _) -> withTrail body
  where
    splitSlash s = case break (== '/') s of
      (a, []) -> [a]
      (a, _ : r) -> a : splitSlash r

data FetchResult
  = FetchOk Text
  | FetchHttpError Int
  | FetchFailed Text

newFetchManager :: IO H.Manager
newFetchManager = H.newTlsManager

-- | Node's @fetch(url)@ followed by @res.text()@: redirects followed, body
-- decoded as UTF-8 with replacement and a leading BOM stripped. Transport
-- failures report undici's message, @fetch failed@.
fetchText :: H.Manager -> Text -> IO FetchResult
fetchText mgr url = do
  r <- try @SomeException $ do
    req <- H.parseRequest (T.unpack url)
    resp <- H.httpLbs req {H.redirectCount = 20} mgr
    pure (HT.statusCode (H.responseStatus resp), BL.toStrict (H.responseBody resp))
  pure $ case r of
    Left _ -> FetchFailed "fetch failed"
    Right (code, body)
      | code >= 200 && code < 300 -> FetchOk (stripBom (TE.decodeUtf8With TE.lenientDecode body))
      | otherwise -> FetchHttpError code
  where
    stripBom t = maybe t id (T.stripPrefix "\xFEFF" t)
