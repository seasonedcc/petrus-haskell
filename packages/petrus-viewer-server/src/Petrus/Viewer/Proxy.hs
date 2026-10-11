-- | The dev server's @/temporal@ proxy: requests under the prefix are
-- forwarded to the Temporal HTTP API (default @http://localhost:7243@) with
-- the prefix stripped and the Host header rewritten (@changeOrigin@). A
-- failed upstream yields an empty @500 text/plain@ response, like Vite.
--
-- Like Vite's http-proxy, it passes the content codings through untouched:
-- the browser's @Accept-Encoding@ goes to the target as sent (and none when
-- the browser sent none), the target's body and its @Content-Encoding@ come
-- back as they are, never decompressed. The answer is streamed to the
-- browser as it arrives.
module Petrus.Viewer.Proxy
  ( proxyApp
  , stripPrefixPath
  ) where

import Control.Exception (SomeException, throwIO, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Char8 qualified as BC
import Data.IORef (newIORef, readIORef, writeIORef)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types qualified as H
import Network.Wai qualified as W

hopByHop :: [H.HeaderName]
hopByHop =
  [ "Connection"
  , "Keep-Alive"
  , "Proxy-Authenticate"
  , "Proxy-Authorization"
  , "TE"
  , "Trailer"
  , "Transfer-Encoding"
  , "Upgrade"
  , "Host"
  , "Content-Length"
  ]

-- | Strip a path prefix (@/temporal@) the way the Vite rewrite does.
stripPrefixPath :: ByteString -> ByteString -> ByteString
stripPrefixPath prefix p = case B.stripPrefix prefix p of
  Just rest -> rest
  Nothing -> p

-- | Forward the request to @target@ (scheme://host:port, no trailing slash).
proxyApp :: HC.Manager -> String -> ByteString -> W.Application
proxyApp mgr target prefix req respond = do
  body <- W.strictRequestBody req
  let path = stripPrefixPath prefix (W.rawPathInfo req)
      url = target ++ BC.unpack (if B.null path then "/" else path) ++ BC.unpack (W.rawQueryString req)
      failed = respond (W.responseLBS H.status500 [("Content-Type", "text/plain")] "")
      forwarded = [h | h@(n, _) <- W.requestHeaders req, n `notElem` hopByHop]
      -- http-client asks for gzip when the request names no coding; an
      -- empty Accept-Encoding makes it send none, as the browser did.
      encoding = [("Accept-Encoding", "") | "Accept-Encoding" `notElem` map fst forwarded]
  parsed <- try @SomeException (HC.parseRequest url)
  case parsed of
    Left _ -> failed
    Right base -> do
      let hostHeader = HC.host base <> (if HC.port base `elem` [80, 443] then "" else ":" <> BC.pack (show (HC.port base)))
          outReq =
            base
              { HC.method = W.requestMethod req
              , HC.requestHeaders = ("Host", hostHeader) : forwarded <> encoding
              , HC.requestBody = HC.RequestBodyLBS body
              , HC.redirectCount = 0
              , HC.decompress = const False
              }
      started <- newIORef False
      r <- try @SomeException $ HC.withResponse outReq mgr $ \resp -> do
        writeIORef started True
        respond $
          W.responseStream
            (HC.responseStatus resp)
            [h | h@(n, _) <- HC.responseHeaders resp, n `notElem` hopByHop]
            ( \write flush ->
                let loop = do
                      chunk <- HC.brRead (HC.responseBody resp)
                      if B.null chunk then pure () else write (BB.byteString chunk) >> flush >> loop
                 in loop
            )
      case r of
        Right received -> pure received
        Left e -> do
          -- Before the target answered: Vite's empty 500. After the answer
          -- began, the browser's response is under way; Warp closes it.
          answered <- readIORef started
          if answered then throwIO e else failed
