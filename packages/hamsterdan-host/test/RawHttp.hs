-- | A minimal HTTP/1.1 client over a raw socket, so tests see a server's
-- response exactly as it is written to the wire.
module RawHttp
  ( RawResponse (..)
  , rawRequest
  , exchange
  , parseResponse
  , comparable
  , connectionHeader
  ) where

import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.CaseInsensitive qualified as CI
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)

data RawResponse = RawResponse
  { statusLine :: ByteString
  , status :: Int
  , headers :: [(ByteString, ByteString)]
  , body :: ByteString
  }
  deriving stock (Eq, Show)

-- | A request with a fixed @host@ (so redirects name the same authority
-- whatever the port), @connection: close@, and @content-length@ whenever
-- there is a body or the method is @POST@.
rawRequest :: ByteString -> ByteString -> [(ByteString, ByteString)] -> ByteString -> ByteString
rawRequest method target extra payload =
  method
    <> " "
    <> target
    <> " HTTP/1.1\r\nhost: testserver\r\nconnection: close\r\n"
    <> BS.concat [name <> ": " <> value <> "\r\n" | (name, value) <- extra]
    <> (if BS.null payload && method /= "POST" then "" else "content-length: " <> BC.pack (show (BS.length payload)) <> "\r\n")
    <> "\r\n"
    <> payload

-- | Send the request bytes to @127.0.0.1:port@ and read until the server
-- closes the connection.
exchange :: Int -> ByteString -> IO ByteString
exchange port bytes = bracket open close $ \sock -> do
  sendAll sock bytes
  let go chunks = do
        chunk <- recv sock 65536
        if BS.null chunk then pure (BS.concat (reverse chunks)) else go (chunk : chunks)
  go []
  where
    open = do
      sock <- socket AF_INET Stream defaultProtocol
      connect sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
      pure sock

parseResponse :: ByteString -> RawResponse
parseResponse raw =
  let (head', rest) = BS.breakSubstring "\r\n\r\n" raw
      (statusLine, headerLines) = case splitCrlf head' of
        first : others -> (first, others)
        [] -> ("", [])
      status = case BC.words statusLine of
        _ : code : _ | Just (n, _) <- BC.readInt code -> n
        _ -> 0
      headers = [(name, BC.dropWhile (== ' ') (BS.drop 1 value)) | line <- headerLines, let (name, value) = BC.break (== ':') line]
   in RawResponse {statusLine, status, headers, body = BS.drop 4 rest}
  where
    splitCrlf bytes
      | BS.null bytes = []
      | otherwise =
          let (line, rest) = BS.breakSubstring "\r\n" bytes
           in line : splitCrlf (BS.drop 2 rest)

-- | The response without the headers each server writes itself: @date@
-- and @server@ (which vary), and the hop-by-hop @connection@, whose
-- position among the headers differs between uvicorn (after the
-- application's headers) and warp (before them); its value is compared
-- on its own. Header names keep their wire spelling.
comparable :: RawResponse -> RawResponse
comparable response =
  response
    { headers =
        [ (name, value)
        | (name, value) <- response.headers
        , CI.foldCase name `notElem` ["date", "server", "connection"]
        ]
    }

-- | The @connection@ header's value, if any.
connectionHeader :: RawResponse -> Maybe ByteString
connectionHeader response = lookup "connection" [(CI.foldCase name, value) | (name, value) <- response.headers]
