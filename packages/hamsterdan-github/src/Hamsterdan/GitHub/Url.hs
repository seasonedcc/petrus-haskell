{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The URL spellings the reference's request path depends on:
--
-- * @urllib.parse.urlsplit@ (and its @hostname@, @port@, @username@ and
--   @password@ properties), which the transport uses to refuse foreign
--   origins and to read @Link@ headers, and @urllib.parse.quote@ and
--   @unquote@: re-exported from hamsterdan-contracts'
--   "Hamsterdan.Python.Url", which the Pi prompt envelope shares;
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

import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isHexDigit, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Python.Text (pyIntBase)
import Hamsterdan.Python.Url (SplitResult (..), hostname, ipv4, ipv6, password, percent, port, quote, unquote, urlsplit, username)

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
