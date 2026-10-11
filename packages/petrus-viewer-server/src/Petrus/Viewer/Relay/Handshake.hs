-- | The server side of the WebSocket opening handshake, answered the way the
-- @ws@ library's @WebSocketServer.handleUpgrade@ answers it (8.x, no
-- extensions, no @verifyClient@), byte for byte: the same checks in the same
-- order, the same @400@/@405@ responses, and the same @101@ response with
-- the first requested subprotocol.
module Petrus.Viewer.Relay.Handshake
  ( upgradeResponse
  , acceptKey
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Char (digitToInt, isDigit, isHexDigit, isSpace)
import Data.Digest.Pure.SHA (bytestringDigest, sha1)
import Network.HTTP.Types (Method, RequestHeaders)

-- | @Right@ the @101@ response that completes the upgrade, or @Left@ the
-- whole response that refuses it (the connection is closed after it).
upgradeResponse :: Method -> RequestHeaders -> Either ByteString ByteString
upgradeResponse method headers
  | method /= "GET" = Left (abort 405 "Invalid HTTP method" [])
  | maybe True ((/= "websocket") . BC.map toLowerAscii) upgrade = Left (abort 400 "Invalid Upgrade header" [])
  | maybe True (not . validKey) key = Left (abort 400 "Missing or invalid Sec-WebSocket-Key header" [])
  | version /= Just 13 && version /= Just 8 =
      Left (abort 400 "Missing or invalid Sec-WebSocket-Version header" [("Sec-WebSocket-Version", "13, 8")])
  | otherwise = case maybe (Right []) parseProtocols (header "sec-websocket-protocol") of
      Left () -> Left (abort 400 "Invalid Sec-WebSocket-Protocol header" [])
      Right protocols ->
        Right . B.intercalate "\r\n" $
          [ "HTTP/1.1 101 Switching Protocols"
          , "Upgrade: websocket"
          , "Connection: Upgrade"
          , "Sec-WebSocket-Accept: " <> maybe "" acceptKey key
          ]
            ++ ["Sec-WebSocket-Protocol: " <> p | p : _ <- [protocols]]
            ++ ["", ""]
  where
    -- Node trims spaces and tabs around a value and joins repeated request
    -- headers with ", "
    header name = case [ows v | (k, v) <- headers, k == CI.mk name] of
      [] -> Nothing
      vs -> Just (B.intercalate ", " vs)
    ows = BC.dropWhile isOws . BC.dropWhileEnd isOws
    isOws c = c == ' ' || c == '\t'
    upgrade = header "upgrade"
    key = header "sec-websocket-key"
    version = header "sec-websocket-version" >>= jsNumber
    toLowerAscii c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

-- | @/^[+/0-9A-Za-z]{22}==$/@
validKey :: ByteString -> Bool
validKey k =
  B.length k == 24
    && BC.all (\c -> c == '+' || c == '/' || (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) (B.take 22 k)
    && B.drop 22 k == "=="

-- | @Sec-WebSocket-Accept@ for a key.
acceptKey :: ByteString -> ByteString
acceptKey k = B64.encode (BL.toStrict (bytestringDigest (sha1 (BL.fromStrict (k <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))))

-- | @abortHandshake(socket, code, message, headers)@.
abort :: Int -> ByteString -> [(ByteString, ByteString)] -> ByteString
abort code message extra =
  "HTTP/1.1 "
    <> BC.pack (show code)
    <> " "
    <> reason
    <> "\r\n"
    <> B.intercalate "\r\n" [k <> ": " <> v | (k, v) <- fields]
    <> "\r\n\r\n"
    <> message
  where
    reason = case code of
      405 -> "Method Not Allowed"
      _ -> "Bad Request"
    fields =
      [("Connection", "close"), ("Content-Type", "text/html"), ("Content-Length", BC.pack (show (B.length message)))] ++ extra

-- | @subprotocol.parse@: comma-separated tokens, optional spaces or tabs
-- after each token, no duplicates; the names in order.
parseProtocols :: ByteString -> Either () [ByteString]
parseProtocols h = go 0 (-1) (-1) []
  where
    n = B.length h
    go :: Int -> Int -> Int -> [ByteString] -> Either () [ByteString]
    go i start end acc
      | i == n =
          if start == -1 || end /= -1
            then Left ()
            else add (slice start i) acc >>= Right . reverse
      | end == -1 && tokenChar c = go (i + 1) (if start == -1 then i else start) end acc
      | i /= 0 && (c == ' ' || c == '\t') = go (i + 1) start (if end == -1 && start /= -1 then i else end) acc
      | c == ',' =
          if start == -1
            then Left ()
            else add (slice start (if end == -1 then i else end)) acc >>= go (i + 1) (-1) (-1)
      | otherwise = Left ()
      where
        c = BC.index h i
    slice a b = B.take (b - a) (B.drop a h)
    add p acc = if p `elem` acc then Left () else Right (p : acc)
    tokenChar ch = (ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch `elem` ("!#$%&'*+-.^_`|~" :: String)

-- | JavaScript's @+string@ for the numbers a version header can hold;
-- 'Nothing' for NaN.
jsNumber :: ByteString -> Maybe Double
jsNumber raw = case BC.unpack (BC.dropWhile isSpace (BC.dropWhileEnd isSpace raw)) of
  "" -> Just 0
  '0' : x : ds | x `elem` ("xX" :: String), not (null ds), all isHexDigit ds -> Just (base 16 ds)
  '0' : x : ds | x `elem` ("bB" :: String), not (null ds), all (`elem` ("01" :: String)) ds -> Just (base 2 ds)
  '0' : x : ds | x `elem` ("oO" :: String), not (null ds), all (`elem` ['0' .. '7']) ds -> Just (base 8 ds)
  '+' : rest -> decimal rest
  '-' : rest -> negate <$> decimal rest
  s -> decimal s
  where
    decimal s = case s of
      "Infinity" -> Just (1 / 0)
      _ ->
        let (whole, r1) = span isDigit s
            (frac, r2) = case r1 of
              '.' : r -> span isDigit r
              _ -> ("", r1)
            dotted = take 1 r1 == "."
            (ex, r3) = case r2 of
              e : r | e `elem` ("eE" :: String) -> case r of
                sign : ds | sign `elem` ("+-" :: String), (d@(_ : _), rest) <- span isDigit ds -> (sign : d, rest)
                _ | (d@(_ : _), rest) <- span isDigit r -> (d, rest)
                _ -> ("bad", r2)
              _ -> ("", r2)
         in if null r3 && ex /= "bad" && (not (null whole) || not (null frac)) && (dotted || null frac)
              then Just (read (nonEmpty whole <> "." <> nonEmpty frac <> (if null ex then "" else "e" <> dropWhile (== '+') ex)) :: Double)
              else Nothing
    nonEmpty x = if null x then "0" else x
    base b = fromInteger . foldl (\a d -> a * b + toInteger (digitToInt d)) 0
