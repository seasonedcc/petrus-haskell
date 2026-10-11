{-# LANGUAGE MultiWayIf #-}

-- | The parts of CPython 3.14's @urllib.parse@ and @ipaddress@ the two
-- Petrus HTTP services rely on, exact for every input:
--
-- * 'urlsplit' and the 'SplitResult' accessors ('splitUsername',
--   'splitPassword', 'splitHostname', 'splitPort'): the observation server
--   routes on @urlsplit(self.path)@, and the simulation server validates its
--   allowed origin with them;
-- * 'parseQsl', 'unquote' and 'unquotePlus' (@parse_qsl@ and friends, with
--   UTF-8 decoding under @errors="replace"@, 'decodeUtf8Replace'): the
--   observation server's history query;
-- * 'ipv4Address', 'ipv6Address' and 'ipAddress' (@ipaddress.IPv4Address@,
--   @IPv6Address@ and @ip_address@ acceptance): bracketed hosts in
--   'urlsplit' and the simulation server's origin hosts.
--
-- Strings are 'Text' as in Python 3 (a request target is its ISO-8859-1
-- decoding, as @http.server@ makes it). Refusals carry the text of the
-- @ValueError@ CPython raises.
module Petrus.Http.Core.Url
  ( -- * @urlsplit@
    SplitResult (..)
  , urlsplit
  , splitUsername
  , splitPassword
  , splitHostname
  , splitPort

    -- * Queries
  , parseQsl
  , unquote
  , unquotePlus

    -- * @ipaddress@
  , ipv4Address
  , ipv6Address
  , ipAddress
  ) where

import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Char (chr, isAscii, isAsciiLower, isAsciiUpper, isDigit, isHexDigit, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json.Python (decodeUtf8Replace, pythonStrRepr)

-- ---------------------------------------------------------------------------
-- urlsplit

-- | @urllib.parse.SplitResult@ (missing components are empty, as
-- @urlsplit@ makes them).
data SplitResult = SplitResult
  { splitScheme :: Text
  , splitNetloc :: Text
  , splitPath :: Text
  , splitQuery :: Text
  , splitFragment :: Text
  }
  deriving stock (Eq, Show)

-- | @urllib.parse.urlsplit(url)@: leading C0 controls and spaces are
-- stripped, tabs and line breaks removed, the scheme lowercased, and a
-- bracketed or non-ASCII network location checked as CPython checks it
-- ('Left' with CPython's @ValueError@ text).
urlsplit :: Text -> Either Text SplitResult
urlsplit raw = do
  let cleaned = T.filter (\c -> c /= '\t' && c /= '\r' && c /= '\n') (T.dropWhile (<= ' ') raw)
      (scheme, afterScheme) = case T.breakOn ":" cleaned of
        (candidate, rest)
          | not (T.null rest)
          , Just (first, _) <- T.uncons candidate
          , isAscii first && isAsciiAlpha first
          , T.all isSchemeChar candidate ->
              (T.toLower candidate, T.drop 1 rest)
        _ -> ("", cleaned)
  (netloc, rest) <-
    if "//" `T.isPrefixOf` afterScheme
      then do
        let body = T.drop 2 afterScheme
            (location, remainder) = T.break (\c -> c == '/' || c == '?' || c == '#') body
            opens = T.any (== '[') location
            closes = T.any (== ']') location
        when ((opens && not closes) || (closes && not opens)) $ Left "Invalid IPv6 URL"
        when (opens && closes) $ checkBracketedNetloc location
        Right (location, remainder)
      else Right ("", afterScheme)
  let (beforeFragment, fragment) = splitOnce '#' rest
      (path, query) = splitOnce '?' beforeFragment
  checkNetloc netloc
  Right (SplitResult scheme netloc path query fragment)
  where
    isAsciiAlpha c = isAsciiLower c || isAsciiUpper c
    isSchemeChar c = isAscii c && (isAsciiAlpha c || isDigit c || c == '+' || c == '-' || c == '.')

-- @s.split(c, 1)@ when @c in s@, else @(s, "")@.
splitOnce :: Char -> Text -> (Text, Text)
splitOnce c text = case T.break (== c) text of
  (before, after)
    | T.null after -> (before, "")
    | otherwise -> (before, T.drop 1 after)

-- @str.partition(sep)@ with a one-character separator.
partition :: Char -> Text -> (Text, Bool, Text)
partition c text = case T.break (== c) text of
  (before, after)
    | T.null after -> (before, False, "")
    | otherwise -> (before, True, T.drop 1 after)

-- @str.rpartition(sep)@ with a one-character separator.
rpartition :: Char -> Text -> (Text, Bool, Text)
rpartition c text = case T.breakOnEnd (T.singleton c) text of
  (before, after)
    | T.null before -> ("", False, after)
    | otherwise -> (T.dropEnd 1 before, True, after)

-- _check_bracketed_netloc
checkBracketedNetloc :: Text -> Either Text ()
checkBracketedNetloc netloc = do
  let (_, _, hostAndPort) = rpartition '@' netloc
      (beforeBracket, opened, bracketed) = partition '[' hostAndPort
  hostname <-
    if opened
      then do
        unless (T.null beforeBracket) $ Left "Invalid IPv6 URL"
        let (host, _, port) = partition ']' bracketed
        when (not (T.null port) && not (":" `T.isPrefixOf` port)) $ Left "Invalid IPv6 URL"
        Right host
      else let (host, _, _) = partition ':' hostAndPort in Right host
  checkBracketedHost hostname

-- _check_bracketed_host
checkBracketedHost :: Text -> Either Text ()
checkBracketedHost hostname
  | "v" `T.isPrefixOf` hostname =
      unless (ipvFuture hostname) $ Left "IPvFuture address is invalid"
  | ipv4Address hostname = Left "An IPv4 address cannot be in brackets"
  | otherwise = () <$ ipAddress hostname
  where
    -- \Av[a-fA-F0-9]+\..+\z
    ipvFuture text =
      let (digits, rest) = T.span (\c -> isAscii c && isHexDigit c) (T.drop 1 text)
       in not (T.null digits) && "." `T.isPrefixOf` rest && T.length rest >= 2 && not (T.any (== '\n') (T.drop 1 rest))

-- _checknetloc: a non-ASCII network location must not contain characters
-- whose NFKC normalization introduces one of @/?#\@:@.
checkNetloc :: Text -> Either Text ()
checkNetloc netloc
  | T.all isAscii netloc = Right ()
  | T.any (`elem` nfkcDelimiters) (T.filter (`notElem` ("@:#?" :: String)) netloc) =
      Left ("netloc '" <> netloc <> "' contains invalid characters under NFKC normalization")
  | otherwise = Right ()

-- Every code point whose NFKC normalization contains @/@, @?@, @#@, @\@@ or
-- @:@ (Unicode 16.0, CPython 3.14's @unicodedata@), generated with
-- @[c for c in map(chr, range(0x80, 0x110000)) if any(x in
-- unicodedata.normalize("NFKC", c) for x in "/?#\@:")]@. Normalization
-- never composes into or out of an ASCII character, so a string's NFKC
-- form contains one of them exactly when one of its characters does.
nfkcDelimiters :: [Char]
nfkcDelimiters =
  map
    chr
    [ 0x2047, 0x2048, 0x2049, 0x2100, 0x2101, 0x2105, 0x2106, 0x2A74, 0xFE13, 0xFE16
    , 0xFE55, 0xFE56, 0xFE5F, 0xFE6B, 0xFF03, 0xFF0F, 0xFF1A, 0xFF1F, 0xFF20
    ]

-- | @SplitResult.username@.
splitUsername :: SplitResult -> Maybe Text
splitUsername result = fst (userinfo result)

-- | @SplitResult.password@.
splitPassword :: SplitResult -> Maybe Text
splitPassword result = snd (userinfo result)

userinfo :: SplitResult -> (Maybe Text, Maybe Text)
userinfo result = case rpartition '@' (splitNetloc result) of
  (info, True, _) -> case partition ':' info of
    (user, True, password) -> (Just user, Just password)
    (user, False, _) -> (Just user, Nothing)
  _ -> (Nothing, Nothing)

hostinfo :: SplitResult -> (Text, Maybe Text)
hostinfo result =
  let (_, _, info) = rpartition '@' (splitNetloc result)
      (host, port) = case partition '[' info of
        (_, True, bracketed) ->
          let (h, _, afterBracket) = partition ']' bracketed
              (_, _, p) = partition ':' afterBracket
           in (h, p)
        _ -> let (h, _, p) = partition ':' info in (h, p)
   in (host, if T.null port then Nothing else Just port)

-- | @SplitResult.hostname@: lowercased, a zone identifier (after @%@)
-- kept as is.
splitHostname :: SplitResult -> Maybe Text
splitHostname result = case fst (hostinfo result) of
  "" -> Nothing
  host -> let (address, percent, zone) = partition '%' host in Just (T.toLower address <> (if percent then "%" else "") <> zone)

-- | @SplitResult.port@ ('Left' with CPython's @ValueError@ text).
splitPort :: SplitResult -> Either Text (Maybe Integer)
splitPort result = case snd (hostinfo result) of
  Nothing -> Right Nothing
  Just port
    | T.all (\c -> isAscii c && isDigit c) port -> do
        when (T.length port > 4300) $
          Left
            ( "Exceeds the limit (4300 digits) for integer string conversion: value has "
                <> T.pack (show (T.length port))
                <> " digits; use sys.set_int_max_str_digits() to increase the limit"
            )
        let value = T.foldl' (\acc c -> acc * 10 + toInteger (ord c - 48)) 0 port
        unless (0 <= value && value <= 65535) $ Left "Port out of range 0-65535"
        Right (Just value)
    | otherwise -> Left ("Port could not be cast to integer value as " <> pythonStrRepr port)

-- ---------------------------------------------------------------------------
-- Queries

-- | @urllib.parse.parse_qsl(qs, keep_blank_values, strict_parsing)@ with
-- the default @&@ separator and UTF-8 @errors="replace"@ decoding. Under
-- strict parsing a field without @=@ (including an empty one) is refused
-- with @bad query field: <repr>@.
parseQsl :: Bool -> Bool -> Text -> Either Text [(Text, Text)]
parseQsl keepBlank strict qs
  | T.null qs = Right []
  | otherwise = concat <$> traverse field (T.splitOn "&" qs)
  where
    field segment
      | T.null segment && not strict = Right []
      | otherwise = case partition '=' segment of
          (_, False, _) | strict -> Left ("bad query field: " <> pythonStrRepr segment)
          (name, _, value)
            | not (T.null value) || keepBlank -> Right [(unquotePlus name, unquotePlus value)]
            | otherwise -> Right []

-- | @urllib.parse.unquote_plus(s)@: @+@ becomes a space, then 'unquote'.
unquotePlus :: Text -> Text
unquotePlus = unquote . T.replace "+" " "

-- | @urllib.parse.unquote(s)@: each maximal run of ASCII characters is
-- percent-decoded and the bytes decoded as UTF-8 with
-- 'decodeUtf8Replace'; non-ASCII characters pass through unchanged.
unquote :: Text -> Text
unquote text
  | not (T.any (== '%') text) = text
  | otherwise = T.concat (go text)
  where
    go remaining
      | T.null remaining = []
      | otherwise =
          let (ascii, rest) = T.span isAscii remaining
              (other, rest') = T.span (not . isAscii) rest
           in decodeUtf8Replace (percentDecode (TE.encodeUtf8 ascii)) : other : go rest'

-- _unquote_impl: every "%hh" (two hexadecimal digits) becomes its byte;
-- any other "%" stays.
percentDecode :: ByteString -> ByteString
percentDecode bytes = case BS.split 37 bytes of
  [] -> ""
  first : items -> BL.toStrict (B.toLazyByteString (B.byteString first <> foldMap item items))
  where
    item chunk = case BS.unpack (BS.take 2 chunk) of
      [h, l] | isHex h && isHex l -> B.word8 (hexValue h * 16 + hexValue l) <> B.byteString (BS.drop 2 chunk)
      _ -> B.word8 37 <> B.byteString chunk
    isHex w = (w >= 48 && w <= 57) || (w >= 65 && w <= 70) || (w >= 97 && w <= 102)
    hexValue w
      | w <= 57 = w - 48
      | w <= 70 = w - 55
      | otherwise = w - 87

-- ---------------------------------------------------------------------------
-- ipaddress

-- | Whether @ipaddress.IPv4Address(text)@ accepts the string: exactly four
-- dot-separated decimal octets of ASCII digits, at most three characters,
-- no leading zero, at most 255.
ipv4Address :: Text -> Bool
ipv4Address text =
  not (T.null text)
    && not (T.any (== '/') text)
    && case T.splitOn "." text of
      octets@[_, _, _, _] -> all octet octets
      _ -> False
  where
    octet o =
      not (T.null o)
        && T.all (\c -> isAscii c && isDigit c) o
        && T.length o <= 3
        && (o == "0" || T.head o /= '0')
        && read (T.unpack o) <= (255 :: Int)

-- | Whether @ipaddress.IPv6Address(text)@ accepts the string, including an
-- embedded IPv4 tail and a scope identifier after @%@.
ipv6Address :: Text -> Bool
ipv6Address text
  | T.any (== '/') text = False
  | otherwise = case partition '%' text of
      (address, False, _) -> hextets address
      (address, True, scope) -> not (T.null scope) && not (T.any (== '%') scope) && hextets address
  where
    hextets address
      | T.null address || T.length address > 45 = False
      | otherwise = either (const False) (const True) (parseParts (splitMax 9 address))
    -- str.split(':', maxsplit=9)
    splitMax :: Int -> Text -> [Text]
    splitMax 0 t = [t]
    splitMax n t = case T.break (== ':') t of
      (before, after)
        | T.null after -> [before]
        | otherwise -> before : splitMax (n - 1) (T.drop 1 after)
    parseParts :: [Text] -> Either () ()
    parseParts parts0 = do
      when (length parts0 < 3) $ Left ()
      parts <-
        if T.any (== '.') (last parts0)
          then do
            unless (ipv4Address (last parts0)) $ Left ()
            Right (init parts0 ++ ["0", "0"])
          else Right parts0
      when (length parts > 9) $ Left ()
      let count = length parts
          interior = [i | i <- [1 .. count - 2], T.null (parts !! i)]
      (hi, lo) <- case interior of
        _ : _ : _ -> Left ()
        [skip] -> do
          let hi0 = skip
              lo0 = count - skip - 1
          hi <-
            if firstEmpty parts
              then let h = hi0 - 1 in if h /= 0 then Left () else Right h
              else Right hi0
          lo <-
            if T.null (last parts)
              then let l = lo0 - 1 in if l /= 0 then Left () else Right l
              else Right lo0
          when (8 - (hi + lo) < 1) $ Left ()
          Right (hi, lo)
        [] -> do
          when (count /= 8) $ Left ()
          when (firstEmpty parts) $ Left ()
          when (T.null (last parts)) $ Left ()
          Right (count, 0)
      unless (all hextet (take hi parts ++ drop (count - lo) parts)) $ Left ()
      Right ()
    firstEmpty = \case
      x : _ -> T.null x
      [] -> True
    hextet h = not (T.null h) && T.all (\c -> isAscii c && isHexDigit c) h && T.length h <= 4

-- | @ipaddress.ip_address(text)@ for a string: 'Left' with CPython's
-- message when it is neither an IPv4 nor an IPv6 address.
ipAddress :: Text -> Either Text ()
ipAddress text
  | ipv4Address text || ipv6Address text = Right ()
  | otherwise = Left (pythonStrRepr text <> " does not appear to be an IPv4 or IPv6 address")
