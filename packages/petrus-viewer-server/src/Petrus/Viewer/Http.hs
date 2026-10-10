-- | Responses with a known length.
--
-- Warp sends a lazy 'BL.ByteString' body with chunked transfer encoding;
-- Node's @res.end(body)@ sends @Content-Length@. Sending the length matches
-- Node on the wire and lets Warp write headers and body in one call.
module Petrus.Viewer.Http
  ( lbsResponse
  ) where

import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Network.HTTP.Types qualified as H
import Network.Wai qualified as W

lbsResponse :: H.Status -> H.ResponseHeaders -> BL.ByteString -> W.Response
lbsResponse st hs body
  | H.statusCode st == 204 || H.statusCode st == 304 = W.responseLBS st hs body
  | otherwise = W.responseLBS st (hs ++ [("Content-Length", BC.pack (show (BL.length body)))]) body
