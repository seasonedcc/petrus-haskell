-- | Serving the built viewer UI (the output of @pnpm build@, a Vite SPA).
--
-- Files are served from the UI directory; unknown paths requested by a
-- browser (accepting HTML) fall back to @index.html@, like @vite preview@.
module Petrus.Viewer.Static
  ( staticApp
  , contentTypeFor
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Char (toLower)
import Data.Text qualified as T
import Network.HTTP.Types qualified as H
import Network.Wai qualified as W
import System.Directory (doesFileExist)
import Petrus.Viewer.Http (lbsResponse)
import System.FilePath (takeExtension, (</>))

staticApp :: FilePath -> W.Application
staticApp root req respond
  | W.requestMethod req `notElem` ["GET", "HEAD"] =
      respond (lbsResponse H.status404 [("Content-Type", "text/plain")] "Not Found")
  | any unsafeSegment segs = notFound
  | otherwise = do
      let rel = if null segs || segs == [""] then "index.html" else foldr1 (</>) (map T.unpack segs)
          path = root </> rel
      isFile <- doesFileExist path
      if isFile
        then respond (serveFile path)
        else
          if acceptsHtml
            then do
              let index = root </> "index.html"
              hasIndex <- doesFileExist index
              if hasIndex then respond (serveFile index) else notFound
            else notFound
  where
    segs = W.pathInfo req
    unsafeSegment s = s == ".." || s == "." || T.any (\c -> c == '/' || c == '\\' || c == '\0') s
    notFound = respond (lbsResponse H.status404 [("Content-Type", "text/plain")] "Not Found")
    acceptsHtml = case lookup "Accept" (W.requestHeaders req) of
      Just a -> "text/html" `BC.isInfixOf` a || "*/*" `BC.isInfixOf` a
      Nothing -> True
    serveFile p =
      W.responseFile
        H.status200
        [("Content-Type", contentTypeFor p), ("Cache-Control", "no-cache")]
        p
        Nothing

contentTypeFor :: FilePath -> ByteString
contentTypeFor p = case map toLower (takeExtension p) of
  ".html" -> "text/html"
  ".js" -> "text/javascript"
  ".mjs" -> "text/javascript"
  ".css" -> "text/css"
  ".json" -> "application/json"
  ".map" -> "application/json"
  ".svg" -> "image/svg+xml"
  ".png" -> "image/png"
  ".jpg" -> "image/jpeg"
  ".jpeg" -> "image/jpeg"
  ".gif" -> "image/gif"
  ".ico" -> "image/x-icon"
  ".webp" -> "image/webp"
  ".woff" -> "font/woff"
  ".woff2" -> "font/woff2"
  ".ttf" -> "font/ttf"
  ".txt" -> "text/plain"
  ".wasm" -> "application/wasm"
  _ -> "application/octet-stream"
