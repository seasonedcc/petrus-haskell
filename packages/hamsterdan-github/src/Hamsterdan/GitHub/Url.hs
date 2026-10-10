{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The URL spellings the reference's request path depends on:
--
-- * @urllib.parse.urlsplit@ (and its @hostname@, @port@, @username@ and
--   @password@ properties), which the transport uses to refuse foreign
--   origins and to read @Link@ headers;
-- * @urllib.parse.quote@ and @unquote@;
-- * httpx's relative-URL parsing and its merge onto
--   @https://api.github.com/@, which decides the exact request target
--   (percent-encoding, dot-segment removal, a dropped fragment).
module Hamsterdan.GitHub.Url
  ( -- * urllib.parse
    SplitResult (..)
  , urlsplit
  , hostname
  , port
  , username
  , password
  , quote
  , unquote

    -- * httpx
  , ApiUrl (..)
  , apiUrl
  , apiPath
  , urlText
  , rawTarget
  , decodedPath
  , apiHost
  , HttpxUrl (..)
  , httpxUrl
  ) where

import Data.Bits (shiftR, (.&.))
import Data.ByteString qualified as BS
import Data.Char (chr, isAlpha, isAsciiLower, isAsciiUpper, isDigit, isHexDigit, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Word (Word8)
import Numeric (readHex)
import Hamsterdan.GitHub.Python (pyIntBase)

-- | @SplitResult@.
data SplitResult = SplitResult
  { scheme :: Text
  , netloc :: Text
  , path :: Text
  , query :: Text
  , fragment :: Text
  }
  deriving stock (Eq, Show)

-- | @urllib.parse.urlsplit(url)@ (CPython 3.14): 'Left' is the
-- @ValueError@ message.
--
-- Bracketed hosts are validated as CPython does for the shapes the
-- transport can meet (IPv4 refused in brackets, IPv6 and @v@-prefixed
-- IPvFuture checked); the NFKC netloc check for non-ASCII hosts is not
-- reproduced (see DIVERGENCES.md).
urlsplit :: Text -> Either Text SplitResult
urlsplit original = do
  let cleaned = T.filter (`notElem` ['\t', '\r', '\n']) (T.dropWhile (<= ' ') original)
      (scheme, rest) = case T.breakOn ":" cleaned of
        (candidate, after)
          | not (T.null after)
          , Just (first, _) <- T.uncons candidate
          , first < '\x80' && isAlpha first
          , T.all schemeChar candidate ->
              (T.toLower candidate, T.drop 1 after)
        _ -> ("", cleaned)
  (netloc, afterNetloc) <-
    if "//" `T.isPrefixOf` rest
      then do
        let body = T.drop 2 rest
            (location, remainder) = T.break (`elem` ['/', '?', '#']) body
        let opens = T.any (== '[') location
            closes = T.any (== ']') location
        if opens /= closes
          then Left "Invalid IPv6 URL"
          else do
            if opens && closes then checkBracketedNetloc location else Right ()
            Right (location, remainder)
      else Right ("", rest)
  let (beforeFragment, fragment) = case T.breakOn "#" afterNetloc of
        (before, after) | not (T.null after) -> (before, T.drop 1 after)
        _ -> (afterNetloc, "")
      (path, query) = case T.breakOn "?" beforeFragment of
        (before, after) | not (T.null after) -> (before, T.drop 1 after)
        _ -> (beforeFragment, "")
  Right SplitResult {scheme, netloc, path, query, fragment}
  where
    schemeChar c = (c < '\x80' && (isAlpha c || isDigit c)) || c `elem` ['+', '-', '.']

checkBracketedNetloc :: Text -> Either Text ()
checkBracketedNetloc location = do
  let hostAndPort = snd (rpartition "@" location)
  host <- case T.breakOn "[" hostAndPort of
    (before, after)
      | not (T.null after) -> do
          if T.null before then Right () else Left "Invalid IPv6 URL"
          let (inside, portPart) = T.breakOn "]" (T.drop 1 after)
              portText = T.drop 1 portPart
          if not (T.null portText) && not (":" `T.isPrefixOf` portText) then Left "Invalid IPv6 URL" else Right inside
    _ -> Right (fst (T.breakOn ":" hostAndPort))
  if "v" `T.isPrefixOf` host
    then if ipvFuture host then Right () else Left "IPvFuture address is invalid"
    else
      if ipv4 host
        then Left "An IPv4 address cannot be in brackets"
        else if ipv6 host then Right () else Left ("'" <> host <> "' does not appear to be an IPv4 or IPv6 address")
  where
    ipvFuture host = case T.breakOn "." (T.drop 1 host) of
      (hex, dotted) -> not (T.null hex) && T.all isHexDigit hex && T.length dotted > 1

-- | @ipaddress.IPv4Address@ syntax: four decimal octets without leading
-- zeros.
ipv4 :: Text -> Bool
ipv4 host = case T.splitOn "." host of
  parts@[_, _, _, _] -> all octet parts
  _ -> False
  where
    octet part =
      not (T.null part)
        && T.length part <= 3
        && T.all (\c -> c >= '0' && c <= '9') part
        && (T.length part == 1 || T.head part /= '0')
        && (read (T.unpack part) :: Int) <= 255

-- | @ipaddress.IPv6Address@ syntax (with an optional @%scope@ and an
-- embedded IPv4 tail).
ipv6 :: Text -> Bool
ipv6 raw =
  let (address, scope) = T.breakOn "%" raw
   in (T.null scope || T.length scope > 1) && groups address
  where
    groups address =
      let parts = T.splitOn ":" address
          ipv4Tail = not (null parts) && T.any (== '.') (last parts)
          limit = if ipv4Tail then 7 else 8
          hexParts = if ipv4Tail then init parts else parts
          tailOk = not ipv4Tail || ipv4 (last parts)
          hexOk p = T.length p <= 4 && T.all isHexDigit p
          skips = length (filter T.null (drop 1 (init' hexParts)))
       in length parts >= 3
            && tailOk
            && all hexOk hexParts
            && length parts <= limit + 1
            && if "::" `T.isInfixOf` address
              then skips <= 1 && length (T.breakOnAll "::" address) == 1 && (length (filter (not . T.null) hexParts) + (if ipv4Tail then 2 else 0)) < 8
              else not (any T.null hexParts) && length hexParts + (if ipv4Tail then 2 else 0) == 8
    init' xs = if null xs then [] else init xs

rpartition :: Text -> Text -> (Text, Text)
rpartition separator value = case T.breakOnEnd separator value of
  (before, after)
    | T.null before -> ("", value)
    | otherwise -> (T.dropEnd (T.length separator) before, after)

-- | The @(hostname, port)@ text of @_hostinfo@.
hostinfo :: SplitResult -> (Text, Maybe Text)
hostinfo split =
  let info = snd (rpartition "@" split.netloc)
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

-- | @SplitResult.hostname@: lowercased, 'Nothing' when empty.
hostname :: SplitResult -> Maybe Text
hostname split = case fst (hostinfo split) of
  "" -> Nothing
  host -> Just (T.toLower host)

-- | @SplitResult.port@: 'Left' is the @ValueError@ message.
port :: SplitResult -> Either Text (Maybe Integer)
port split = case snd (hostinfo split) of
  Nothing -> Right Nothing
  Just text
    | T.all (\c -> c >= '0' && c <= '9') text ->
        let value = read (T.unpack text) :: Integer
         in if value <= 65535 then Right (Just value) else Left "Port out of range 0-65535"
    | otherwise -> Left ("Port could not be cast to integer value as " <> T.pack (show text))

-- | @SplitResult.username@.
username :: SplitResult -> Maybe Text
username split = case T.breakOnEnd "@" split.netloc of
  (before, _) | not (T.null before) -> Just (fst (T.breakOn ":" (T.dropEnd 1 before)))
  _ -> Nothing

-- | @SplitResult.password@.
password :: SplitResult -> Maybe Text
password split = case T.breakOnEnd "@" split.netloc of
  (before, _)
    | not (T.null before) -> case T.breakOn ":" (T.dropEnd 1 before) of
        (_, rest) | not (T.null rest) -> Just (T.drop 1 rest)
        _ -> Nothing
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

-- | The API origin.
apiHost :: Text
apiHost = "api.github.com"

-- | A request URL on @https://api.github.com@ as httpx builds it: the
-- percent-encoded path (possibly empty) and the optional query.
data ApiUrl = ApiUrl
  { path :: Text
  , query :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | @httpx.Client(base_url="https://api.github.com/").build_request(m,
-- relative)@'s URL. 'Left' is httpx's @InvalidURL@ message.
apiUrl :: Text -> Either Text ApiUrl
apiUrl relative = do
  checkUrl relative
  let (beforeFragment, _) = T.breakOn "#" relative
      (rawPath, rawQuery) = case T.breakOn "?" beforeFragment of
        (p, q) | T.null q -> (p, Nothing)
        (p, q) -> (p, Just (T.drop 1 q))
  if "//" `T.isPrefixOf` rawPath
    then Left "Relative URLs cannot have a path starting with '//'"
    else
      if ":" `T.isPrefixOf` rawPath
        then Left "Relative URLs cannot have a path starting with ':'"
        else do
          let quotedPath = httpxQuote pathSafe rawPath
              quotedQuery = httpxQuote querySafe <$> rawQuery
              relativeTarget = (if T.null quotedPath then "/" else quotedPath) <> maybe "" ("?" <>) quotedQuery
              merged = "/" <> T.dropWhile (== '/') relativeTarget
          apiPath merged

-- | @base_url.copy_with(raw_path=target)@ for an already-quoted target.
apiPath :: Text -> Either Text ApiUrl
apiPath target = do
  checkUrl target
  let (rawPath, rawQuery) = case T.breakOn "?" target of
        (p, q) | T.null q -> (p, Nothing)
        (p, q) -> (p, Just (T.drop 1 q))
  if T.any (== '#') rawPath || maybe False (T.any (== '#')) rawQuery
    then Left "Invalid URL component 'path'"
    else Right ApiUrl {path = httpxQuote pathSafe (normalizePath rawPath), query = httpxQuote querySafe <$> rawQuery}

checkUrl :: Text -> Either Text ()
checkUrl value
  | T.length value > 65536 = Left "URL too long"
  | otherwise = case T.findIndex (\c -> c < ' ' || c == '\DEL') value of
      Just index ->
        let c = T.index value index
         in Left ("Invalid non-printable ASCII character in URL, " <> asciiRepr c <> " at position " <> T.pack (show index) <> ".")
      Nothing -> Right ()
  where
    asciiRepr c = case c of
      '\t' -> "'\\t'"
      '\n' -> "'\\n'"
      '\r' -> "'\\r'"
      _ -> T.pack ("'\\x" <> pad (showHexByte (ord c)) <> "'")
    pad s = replicate (2 - length s) '0' <> s
    showHexByte n = map (\d -> "0123456789abcdef" !! d) (digits n)
    digits n = if n < 16 then [n] else digits (n `div` 16) <> [n `mod` 16]

-- | httpx's @normalize_path@ (dot-segment removal).
normalizePath :: Text -> Text
normalizePath value
  | not (T.any (== '.') value) = value
  | otherwise =
      let components = T.splitOn "/" value
       in if "." `notElem` components && ".." `notElem` components
            then value
            else T.intercalate "/" (reverse (foldl step [] components))
  where
    step output = \case
      "." -> output
      ".." -> case output of
        [] -> []
        [""] -> [""]
        _ : rest -> rest
      component -> component : output

-- | httpx's @quote@: keep valid @%XX@ escapes, percent-encode the rest of
-- what is not safe.
httpxQuote :: (Char -> Bool) -> Text -> Text
httpxQuote safe value = go value
  where
    go text = case T.breakOn "%" text of
      (before, after)
        | T.null after -> encode before
        | validEscape (T.drop 1 after) -> encode before <> T.take 3 after <> go (T.drop 3 after)
        | otherwise -> encode before <> "%" <> go (T.drop 1 after)
    validEscape rest = T.length (T.take 2 rest) == 2 && T.all isHexDigit (T.take 2 rest)
    encode text
      | T.all keep text = text
      | otherwise = T.concatMap (\c -> if keep c then T.singleton c else TE.decodeLatin1 (BS.concatMap percent (TE.encodeUtf8 (T.singleton c)))) text
    keep c = unreserved c || c == '%' || safe c
    unreserved c = isAsciiUpper c || isAsciiLower c || isDigit c || c `elem` ['-', '.', '_', '~']

pathSafe :: Char -> Bool
pathSafe c = c >= ' ' && c < '\DEL' && c `notElem` [' ', '"', '#', '<', '>', '?', '`', '{', '}']

querySafe :: Char -> Bool
querySafe c = c >= ' ' && c < '\DEL' && c `notElem` [' ', '"', '#', '<', '>']

-- | @str(url)@.
urlText :: ApiUrl -> Text
urlText url = "https://" <> apiHost <> url.path <> maybe "" ("?" <>) url.query

-- | The request target on the wire (@url.raw_path@).
rawTarget :: ApiUrl -> Text
rawTarget url = (if T.null url.path then "/" else url.path) <> maybe "" ("?" <>) url.query

-- | @url.path@: percent-decoded, @/@ when empty.
decodedPath :: ApiUrl -> Text
decodedPath url = if T.null url.path then "/" else unquote url.path

-- | The parts of an absolute or relative URL httpx's redirect handling
-- consults.
data HttpxUrl = HttpxUrl
  { scheme :: Text
  , host :: Text
  , path :: Text
  }
  deriving stock (Eq, Show)

-- | @httpx.URL(value)@: 'Left' is the @InvalidURL@ message. Non-ASCII hosts
-- are admitted without IDNA validation (see DIVERGENCES.md).
httpxUrl :: Text -> Either Text HttpxUrl
httpxUrl value = do
  checkUrl value
  let (scheme, afterScheme) = case T.span schemeChar value of
        (candidate, rest)
          | Just (first, _) <- T.uncons candidate
          , isAsciiUpper first || isAsciiLower first
          , Just (':', after) <- T.uncons rest ->
              (candidate, after)
        _ -> case T.uncons value of
          Just (':', after) -> ("", after)
          _ -> ("", value)
      (authority, afterAuthority) =
        if "//" `T.isPrefixOf` afterScheme
          then let (a, rest) = T.break (`elem` ['/', '?', '#']) (T.drop 2 afterScheme) in (Just a, rest)
          else (Nothing, afterScheme)
      rawPath = T.takeWhile (`notElem` ['?', '#']) afterAuthority
      (userinfo, hostAndPort) = case authority of
        Nothing -> ("", "")
        Just a -> case T.breakOnEnd "@" a of
          (before, after) | not (T.null before) -> (T.dropEnd 1 before, after)
          _ -> ("", a)
      (host, portText) =
        case T.uncons hostAndPort of
          Just ('[', _)
            | T.any (== ']') hostAndPort ->
                let (before, after) = T.breakOnEnd "]" hostAndPort
                 in (before, dropColon after)
          _ -> let (h, rest) = T.break (`elem` [':', '@']) hostAndPort in (h, dropColon rest)
      dropColon t = maybe t id (T.stripPrefix ":" t)
  encodedHost <- encodeHost host
  portNumber <-
    if T.null portText
      then Right Nothing
      else maybe (Left ("Invalid port: " <> T.pack (show portText))) (Right . Just) (pyIntBase 10 portText)
  let defaultPort = lookup (T.toLower scheme) [("ftp", 21), ("http", 80), ("https", 443), ("ws", 80), ("wss", 443)]
      normalizedPort = if portNumber == defaultPort then Nothing else portNumber
      hasScheme = not (T.null scheme)
      hasAuthority = not (T.null userinfo) || not (T.null encodedHost) || normalizedPort /= Nothing
  if hasAuthority && not (T.null rawPath) && not ("/" `T.isPrefixOf` rawPath)
    then Left "For absolute URLs, path must be empty or begin with '/'"
    else Right ()
  if not hasScheme && not hasAuthority && "//" `T.isPrefixOf` rawPath
    then Left "Relative URLs cannot have a path starting with '//'"
    else Right ()
  if not hasScheme && not hasAuthority && ":" `T.isPrefixOf` rawPath
    then Left "Relative URLs cannot have a path starting with ':'"
    else Right ()
  let path = if hasScheme || hasAuthority then normalizePath rawPath else rawPath
  Right HttpxUrl {scheme = T.toLower scheme, host = encodedHost, path}
  where
    schemeChar c = isAsciiUpper c || isAsciiLower c || isDigit c || c `elem` ['+', '.', '-']
    encodeHost host
      | T.null host = Right ""
      | ipv4Style host = if ipv4 host then Right host else Left ("Invalid IPv4 address: " <> T.pack (show host))
      | "[" `T.isPrefixOf` host && "]" `T.isSuffixOf` host && T.length host >= 2 =
          let inner = T.drop 1 (T.dropEnd 1 host)
           in if ipv6 inner then Right inner else Left ("Invalid IPv6 address: " <> T.pack (show host))
      | otherwise = Right (T.toLower host)
    ipv4Style host = case T.splitOn "." host of
      parts@[_, _, _, _] -> all (\p -> not (T.null p) && T.all (\c -> c >= '0' && c <= '9') p) parts
      _ -> False
