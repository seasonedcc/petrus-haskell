-- | The dev server's @/temporal@ proxy: requests under the prefix are
-- forwarded to the Temporal HTTP API (default @http://localhost:7243@) with
-- the prefix stripped and the Host header rewritten (@changeOrigin@). A
-- failed upstream yields an empty @500 text/plain@ response, like Vite.
module Petrus.Viewer.Proxy
  ( proxyApp
  , stripPrefixPath
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.CaseInsensitive qualified as CI
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
  r <- try @SomeException $ do
    base <- HC.parseRequest url
    let hostHeader = HC.host base <> (if HC.port base `elem` [80, 443] then "" else ":" <> BC.pack (show (HC.port base)))
        outReq =
          base
            { HC.method = W.requestMethod req
            , HC.requestHeaders =
                ("Host", hostHeader) : [h | h@(n, _) <- W.requestHeaders req, n `notElem` hopByHop]
            , HC.requestBody = HC.RequestBodyLBS body
            , HC.redirectCount = 0
            }
    HC.httpLbs outReq mgr
  case r of
    Left _ -> respond (W.responseLBS H.status500 [("Content-Type", "text/plain")] "")
    Right resp ->
      respond $
        W.responseLBS
          (HC.responseStatus resp)
          [h | h@(n, _) <- HC.responseHeaders resp, n `notElem` hopByHop, CI.foldedCase n /= "content-encoding"]
          (HC.responseBody resp)
