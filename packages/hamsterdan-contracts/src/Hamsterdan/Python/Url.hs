{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | CPython 3.14's @urllib.parse@ for @str@ input, as the Hamsterdan
-- reference uses it: @urlsplit@ (with its @ValueError@ cases: bracketed
-- hosts and NFKC-expanding netlocs) and @urlunsplit@, the @hostname@,
-- @port@, @username@ and @password@ properties, and @quote@ and
-- @unquote@. The Pi prompt envelope and the GitHub transport's origin
-- check and @Link@ headers share it.
module Hamsterdan.Python.Url
  ( SplitResult (..)
  , urlsplit
  , urlunsplit
  , hostname
  , port
  , username
  , password
  , quote
  , unquote

    -- * Shared with other URL parsers
  , ipv4
  , ipv6
  , percent
  ) where

import Control.Monad (forM_, unless, when)
import Data.Bits (shiftR, (.&.))
import Data.ByteString qualified as BS
import Data.Char (chr, isAlpha, isAscii, isAsciiLower, isAsciiUpper, isDigit, isHexDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Word (Word8)
import Numeric (readHex)
import Petrus.Json.Python (pythonLower, pythonStrRepr)

-- | @SplitResult(scheme, netloc, path, query, fragment)@.
data SplitResult = SplitResult
  { scheme :: Text
  , netloc :: Text
  , path :: Text
  , query :: Text
  , fragment :: Text
  }
  deriving stock (Eq, Show)

schemeChar :: Char -> Bool
schemeChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("+-." :: String)

-- | @urlsplit(url)@; 'Left' is the @ValueError@ message.
urlsplit :: Text -> Either Text SplitResult
urlsplit raw = do
  let url0 = T.filter (`notElem` ("\t\r\n" :: String)) (T.dropWhile (<= ' ') raw)
      (scheme, url1) = case T.breakOn ":" url0 of
        (candidate, rest)
          | not (T.null rest)
          , Just (first, _) <- T.uncons candidate
          , isAscii first && isAlpha first
          , T.all schemeChar candidate ->
              (T.toLower candidate, T.drop 1 rest)
        _ -> ("", url0)
  (netloc, url2) <-
    if "//" `T.isPrefixOf` url1
      then do
        let rest = T.drop 2 url1
            (location, remainder) = T.break (`elem` ("/?#" :: String)) rest
        when (T.elem '[' location /= T.elem ']' location) $ Left "Invalid IPv6 URL"
        when (T.elem '[' location && T.elem ']' location) $ checkBracketedNetloc location
        pure (location, remainder)
      else pure ("", url1)
  let (url3, fragment) = case T.breakOn "#" url2 of
        (before, after) | not (T.null after) -> (before, T.drop 1 after)
        _ -> (url2, "")
      (path, query) = case T.breakOn "?" url3 of
        (before, after) | not (T.null after) -> (before, T.drop 1 after)
        _ -> (url3, "")
  checkNetloc netloc
  pure SplitResult {scheme, netloc, path, query, fragment}

-- | @_check_bracketed_netloc(netloc)@.
checkBracketedNetloc :: Text -> Either Text ()
checkBracketedNetloc location = do
  let hostAndPort = snd (rpartition "@" location)
      (before, bracket) = T.breakOn "[" hostAndPort
  host <-
    if not (T.null bracket)
      then do
        unless (T.null before) $ Left "Invalid IPv6 URL"
        let (inside, closing) = T.breakOn "]" (T.drop 1 bracket)
            afterBracket = T.drop 1 closing
        when (not (T.null afterBracket) && not (":" `T.isPrefixOf` afterBracket)) $ Left "Invalid IPv6 URL"
        pure inside
      else pure (fst (T.breakOn ":" hostAndPort))
  checkBracketedHost host

rpartition :: Text -> Text -> (Text, Text)
rpartition separator value = case T.breakOnEnd separator value of
  (before, after) | not (T.null before) -> (T.dropEnd (T.length separator) before, after)
  _ -> ("", value)

-- | @_check_bracketed_host(hostname)@.
checkBracketedHost :: Text -> Either Text ()
checkBracketedHost host
  | "v" `T.isPrefixOf` host =
      let (digits, rest) = T.span isHexAscii (T.drop 1 host)
       in unless (not (T.null digits) && "." `T.isPrefixOf` rest && T.length rest > 1 && not (T.elem '\n' (T.drop 1 rest))) $
            Left "IPvFuture address is invalid"
  | ipv4 host = Left "An IPv4 address cannot be in brackets"
  | ipv6 host = Right ()
  | otherwise = Left (pythonStrRepr host <> " does not appear to be an IPv4 or IPv6 address")
  where
    isHexAscii c = isAscii c && isHexDigit c

-- | @IPv4Address(value)@ succeeds.
ipv4 :: Text -> Bool
ipv4 value = not (T.elem '/' value) && case T.splitOn "." value of
  octets@[_, _, _, _] -> all octet octets
  _ -> False
  where
    octet s =
      not (T.null s)
        && T.all (\c -> isAscii c && isDigit c) s
        && T.length s <= 3
        && (s == "0" || T.head s /= '0')
        && read (T.unpack s) <= (255 :: Int)

-- | @IPv6Address(value)@ succeeds.
ipv6 :: Text -> Bool
ipv6 value
  | T.elem '/' value = False
  | otherwise =
      let (address, scope) = T.breakOn "%" value
       in (T.null scope || (T.length scope > 1 && not (T.elem '%' (T.drop 1 scope)))) && ipv6Address address

ipv6Address :: Text -> Bool
ipv6Address address
  | T.null address || T.length address > 45 = False
  | otherwise = either (const False) (const True) $ do
      let split = splitMax 9 address
      when (length split < 3) $ Left ()
      parts <-
        if T.elem '.' (last split)
          then if ipv4 (last split) then Right (init split <> ["0", "0"]) else Left ()
          else Right split
      when (length parts > 9) $ Left ()
      let inner = [i | i <- [1 .. length parts - 2], T.null (parts !! i)]
      (hi, lo) <- case inner of
        [] -> do
          when (length parts /= 8 || T.null (take1 parts) || T.null (last parts)) $ Left ()
          pure (length parts, 0)
        [skip] -> do
          let hi0 = skip
              lo0 = length parts - skip - 1
          hi1 <- if T.null (take1 parts) then (if hi0 - 1 /= 0 then Left () else Right 0) else Right hi0
          lo1 <- if T.null (last parts) then (if lo0 - 1 /= 0 then Left () else Right 0) else Right lo0
          when (8 - (hi1 + lo1) < 1) $ Left ()
          pure (hi1, lo1)
        _ -> Left ()
      forM_ (take hi parts <> drop (length parts - lo) parts) $ \hextet ->
        unless (not (T.null hextet) && T.length hextet <= 4 && T.all (\c -> isAscii c && isHexDigit c) hextet) $ Left ()
  where
    take1 = \case
      first : _ -> first
      [] -> ""
    splitMax :: Int -> Text -> [Text]
    splitMax n s
      | n == 0 = [s]
      | otherwise = case T.breakOn ":" s of
          (before, after) | not (T.null after) -> before : splitMax (n - 1) (T.drop 1 after)
          _ -> [s]

-- | The non-ASCII characters whose NFKC form contains one of @/?#\@:@
-- (Unicode 16.0, the pinned interpreter's database).
nfkcExpands :: Char -> Bool
nfkcExpands c =
  c
    `elem` ( "\x2047\x2048\x2049\x2100\x2101\x2105\x2106\x2A74\xFE13\xFE16\xFE55\xFE56\xFE5F\xFE6B\xFF03\xFF0F\xFF1A\xFF1F\xFF20"
               :: String
           )

-- | @_checknetloc(netloc)@.
checkNetloc :: Text -> Either Text ()
checkNetloc location
  | T.null location || T.all isAscii location = Right ()
  | T.any nfkcExpands (T.filter (`notElem` ("@:#?" :: String)) location) =
      Left ("netloc '" <> location <> "' contains invalid characters under NFKC normalization")
  | otherwise = Right ()

-- | @urlunsplit((scheme, netloc, path, query, fragment))@.
urlunsplit :: SplitResult -> Text
urlunsplit r =
  let usesNetloc = r.scheme `elem` usesNetlocSchemes
      netloc
        | not (T.null r.netloc) = Just r.netloc
        | not (T.null r.scheme) && usesNetloc && (T.null r.path || "/" `T.isPrefixOf` r.path) = Just ""
        | otherwise = Nothing
      withNetloc = case netloc of
        Just location ->
          let path = if not (T.null r.path) && not ("/" `T.isPrefixOf` r.path) then "/" <> r.path else r.path
           in "//" <> location <> path
        Nothing
          | "//" `T.isPrefixOf` r.path -> "//" <> r.path
          | otherwise -> r.path
      withScheme = if T.null r.scheme then withNetloc else r.scheme <> ":" <> withNetloc
      withQuery = if T.null r.query then withScheme else withScheme <> "?" <> r.query
   in if T.null r.fragment then withQuery else withQuery <> "#" <> r.fragment

usesNetlocSchemes :: [Text]
usesNetlocSchemes =
  [ ""
  , "ftp"
  , "http"
  , "gopher"
  , "nntp"
  , "telnet"
  , "imap"
  , "wais"
  , "file"
  , "mms"
  , "https"
  , "shttp"
  , "snews"
  , "prospero"
  , "rtsp"
  , "rtsps"
  , "rtspu"
  , "rsync"
  , "svn"
  , "svn+ssh"
  , "sftp"
  , "nfs"
  , "git"
  , "git+ssh"
  , "ws"
  , "wss"
  , "itms-services"
  ]

-- | The @(hostname, port)@ text of @_hostinfo@.
hostinfo :: SplitResult -> (Text, Maybe Text)
hostinfo r =
  let info = snd (rpartition "@" r.netloc)
   in case T.breakOn "[" info of
        (_, after)
          | not (T.null after) ->
              let (host, rest) = T.breakOn "]" (T.drop 1 after)
               in (host, nonEmpty (T.drop 1 (snd (T.breakOn ":" (T.drop 1 rest)))))
        _ ->
          let (host, rest) = T.breakOn ":" info
           in (host, nonEmpty (T.drop 1 rest))
  where
    nonEmpty t = if T.null t then Nothing else Just t

-- | @SplitResult.hostname@: lowercased (a scoped IPv6 address keeps its
-- zone as written), 'Nothing' when empty.
hostname :: SplitResult -> Maybe Text
hostname r = case fst (hostinfo r) of
  "" -> Nothing
  host -> let (address, zone) = T.breakOn "%" host in Just (pythonLower address <> zone)

-- | @SplitResult.port@: 'Left' is the @ValueError@ message.
port :: SplitResult -> Either Text (Maybe Integer)
port r = case snd (hostinfo r) of
  Nothing -> Right Nothing
  Just text
    | T.all (\c -> c >= '0' && c <= '9') text ->
        let value = read (T.unpack text) :: Integer
         in if value <= 65535 then Right (Just value) else Left "Port out of range 0-65535"
    | otherwise -> Left ("Port could not be cast to integer value as " <> pythonStrRepr text)

-- | @SplitResult.username@ ('Nothing' is @None@).
username :: SplitResult -> Maybe Text
username r = case T.breakOnEnd "@" r.netloc of
  (before, _) | not (T.null before) -> Just (fst (T.breakOn ":" (T.dropEnd 1 before)))
  _ -> Nothing

-- | @SplitResult.password@ ('Nothing' is @None@).
password :: SplitResult -> Maybe Text
password r = case T.breakOnEnd "@" r.netloc of
  (before, _)
    | not (T.null before) ->
        let (_, rest) = T.breakOn ":" (T.dropEnd 1 before)
         in if T.null rest then Nothing else Just (T.drop 1 rest)
  _ -> Nothing

-- | @urllib.parse.quote(value, safe=safe)@.
quote :: Text -> Text -> Text
quote safe value = TE.decodeLatin1 (BS.concatMap escape (TE.encodeUtf8 value))
  where
    escape byte
      | alwaysSafe byte || (byte < 0x80 && T.any (== chr (fromIntegral byte)) safe) = BS.singleton byte
      | otherwise = percent byte
    alwaysSafe byte =
      let c = chr (fromIntegral byte)
       in isAsciiUpper c || isAsciiLower c || isDigit c || c `elem` ['_', '.', '-', '~']

percent :: Word8 -> BS.ByteString
percent byte = BS.pack [37, hexDigit (byte `shiftR` 4), hexDigit (byte .&. 15)]
  where
    hexDigit n = if n < 10 then 48 + n else 55 + n

-- | @urllib.parse.unquote(value)@: UTF-8 with replacement.
unquote :: Text -> Text
unquote value
  | not (T.any (== '%') value) = value
  | otherwise = T.concat (map decodeRun (T.groupBy (\a b -> (a < '\x80') == (b < '\x80')) value))
  where
    decodeRun run
      | T.all (< '\x80') run = TE.decodeUtf8With TEE.lenientDecode (unquoteBytes (TE.encodeUtf8 run))
      | otherwise = run

unquoteBytes :: BS.ByteString -> BS.ByteString
unquoteBytes bytes = case BS.elemIndex 37 bytes of
  Nothing -> bytes
  Just index ->
    let (before, rest) = BS.splitAt index bytes
        hex = BS.take 2 (BS.drop 1 rest)
     in if BS.length hex == 2 && BS.all (isHexDigit . chr . fromIntegral) hex
          then case readHex (map (chr . fromIntegral) (BS.unpack hex)) of
            [(n, "")] -> before <> BS.singleton (fromIntegral (n :: Int)) <> unquoteBytes (BS.drop 3 rest)
            _ -> before <> BS.take 1 rest <> unquoteBytes (BS.drop 1 rest)
          else before <> BS.take 1 rest <> unquoteBytes (BS.drop 1 rest)
