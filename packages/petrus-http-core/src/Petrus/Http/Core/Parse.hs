-- | Request parsing exactly as CPython 3.14's @BaseHTTPRequestHandler@ does
-- it: the request line (@parse_request@) and the header block
-- (@http.client.parse_headers@, i.e. the @email@ package's compat32
-- parser). Bytes are ISO-8859-1 throughout, as in CPython; these functions
-- are pure so they can be checked against the Python implementation
-- directly.
module Petrus.Http.Core.Parse
  ( -- * Request line
    RequestLine (..)
  , RequestLineError (..)
  , parseRequestLine
  , collapseLeadingSlashes
  , isLatin1Space

    -- * Header block
  , Headers
  , parseHeaderBlock
  , lookupHeader
  , lookupHeaders

    -- * Limits
  , maxLineLength
  , maxHeaders
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAsciiUpper, toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Petrus.Json.Repr (pythonReprText)

-- | @http.client._MAXLINE@: the longest request or header line, in bytes.
maxLineLength :: Int
maxLineLength = 65536

-- | @http.client._MAXHEADERS@: header lines counted with the terminating
-- blank line, so at most 99 headers fit.
maxHeaders :: Int
maxHeaders = 100

-- | A parsed request line.
data RequestLine = RequestLine
  { lineCommand :: ByteString
  -- ^ The method token, case-sensitive (@self.command@).
  , linePath :: ByteString
  -- ^ The target with a leading run of slashes reduced to one
  -- (@self.path@).
  , lineRawTarget :: ByteString
  -- ^ The second word of the line, unmodified.
  , lineVersion :: ByteString
  -- ^ @HTTP/x.y@ as sent, or @HTTP/0.9@ for a two-word line.
  , lineText :: ByteString
  -- ^ The line without its trailing CR/LF characters
  -- (@self.requestline@).
  , lineSimple :: Bool
  -- ^ A two-word (HTTP/0.9 simple) request: no header block follows. A
  -- three-word line naming @HTTP/0.9@ is not simple: its headers are read,
  -- but its responses are still written without status line and headers.
  }
  deriving stock (Eq, Show)

-- | A request line CPython refuses, with the response it sends.
data RequestLineError = RequestLineError
  { lineErrorStatus :: Int
  , lineErrorMessage :: Text
  -- ^ The @send_error@ message (the status line's reason phrase and the
  -- error page's message).
  , lineErrorVersion :: ByteString
  -- ^ The request version in effect when the error is sent. CPython writes
  -- no status line and no headers while it is @HTTP/0.9@, so several
  -- refusals are a bare HTML page.
  }
  deriving stock (Eq, Show)

-- | @parse_request@'s request-line half. 'Nothing' is an empty line (no
-- words): CPython closes the connection without a response.
parseRequestLine :: ByteString -> Maybe (Either RequestLineError RequestLine)
parseRequestLine raw
  | null wordsOf = Nothing
  | otherwise = Just $ do
      version <-
        if length wordsOf >= 3
          then checkVersion (last wordsOf)
          else Right "HTTP/0.9"
      case wordsOf of
        [command, target]
          | command /= "GET" -> Left (RequestLineError 400 ("Bad HTTP/0.9 request type (" <> repr command <> ")") "HTTP/0.9")
          | otherwise -> Right (RequestLine command (collapseLeadingSlashes target) target "HTTP/0.9" line True)
        [command, target, _] -> Right (RequestLine command (collapseLeadingSlashes target) target version line False)
        _ -> Left (RequestLineError 400 ("Bad request syntax (" <> repr line <> ")") version)
  where
    line = BC.dropWhileEnd (\c -> c == '\r' || c == '\n') raw
    wordsOf = filter (not . BS.null) (BS.splitWith isLatin1Space line)
    checkVersion version =
      case BS.stripPrefix "HTTP/" version of
        Just number
          | [major, minor] <- BC.split '.' number
          , all validComponent [major, minor] ->
              if (readInt major, readInt minor) >= (2, 0)
                then Left (RequestLineError 505 ("Invalid HTTP version (" <> latin1 number <> ")") "HTTP/0.9")
                else Right version
        _ -> Left (RequestLineError 400 ("Bad request version (" <> repr version <> ")") "HTTP/0.9")
    -- After split('/', 1) the number may contain further slashes; they make
    -- a component non-numeric, which CPython refuses the same way.
    validComponent c = not (BS.null c) && BS.length c <= 10 && BS.all (\w -> w >= 48 && w <= 57) c
    readInt :: ByteString -> Integer
    readInt = maybe 0 fst . BC.readInteger
    repr = T.pack . pythonReprText . latin1

latin1 :: ByteString -> Text
latin1 = TE.decodeLatin1

-- | @str.isspace()@ for an ISO-8859-1 character: what @str.split()@
-- splits the request line on (including U+001C–U+001F, U+0085 and U+00A0).
isLatin1Space :: Word8 -> Bool
isLatin1Space w = (w >= 9 && w <= 13) || (w >= 0x1c && w <= 0x20) || w == 0x85 || w == 0xa0

-- | CPython's @'/' + path.lstrip('/')@ for a target starting with @//@.
collapseLeadingSlashes :: ByteString -> ByteString
collapseLeadingSlashes target
  | "//" `BS.isPrefixOf` target = BS.cons 47 (BS.dropWhile (== 47) target)
  | otherwise = target

-- | Header fields in arrival order: names and values as sent (ISO-8859-1
-- bytes), duplicates kept.
type Headers = [(ByteString, ByteString)]

-- | The first value of a header, compared case-insensitively
-- (@message.get(name)@).
lookupHeader :: ByteString -> Headers -> Maybe ByteString
lookupHeader name headers = case lookupHeaders name headers of
  value : _ -> Just value
  [] -> Nothing

-- | Every value of a header in order (@message.get_all(name)@).
lookupHeaders :: ByteString -> Headers -> [ByteString]
lookupHeaders name headers = [value | (key, value) <- headers, lower key == wanted]
  where
    wanted = lower name
    lower = BC.map (\c -> if isAsciiUpper c then toLower c else c)

-- | Parse the header lines read after the request line (including the
-- terminating blank line, if any), as @http.client.parse_headers@ does with
-- the @email@ compat32 parser:
--
-- * lines are split on CR, LF and CRLF;
-- * the header section ends at a blank line or at the first line that is
--   neither @name:@ (name of printable ASCII without @:@, possibly empty),
--   nor a continuation (leading space or tab), nor @From @ — everything
--   after it is body and ignored;
-- * a value is the text after the first colon with the continuation lines
--   appended verbatim (their line breaks included), then leading spaces,
--   tabs, CRs and LFs removed (so a value that starts on a continuation
--   line loses the fold) and trailing CRs and LFs removed; trailing spaces
--   stay;
-- * a line starting with @:@, a leading continuation and @From @ lines are
--   skipped (the first line's @From @ is the envelope header).
parseHeaderBlock :: ByteString -> Headers
parseHeaderBlock block = fields (headerSection (splitLines block))

-- Universal-newline split keeping the line ends.
splitLines :: ByteString -> [ByteString]
splitLines bytes
  | BS.null bytes = []
  | otherwise =
      let (content, rest) = BS.break (\w -> w == 10 || w == 13) bytes
          endLength
            | "\r\n" `BS.isPrefixOf` rest = 2
            | BS.null rest = 0
            | otherwise = 1
          lineLength = BS.length content + endLength
       in BS.take lineLength bytes : splitLines (BS.drop lineLength bytes)

headerSection :: [ByteString] -> [ByteString]
headerSection = takeWhile isHeaderLine
  where
    isHeaderLine line =
      "From " `BS.isPrefixOf` line
        || startsWithContinuation line
        || case BS.span isNameByte line of
          (_, rest) -> "\58" `BS.isPrefixOf` rest
    isNameByte w = (w >= 0x21 && w <= 0x39) || (w >= 0x3b && w <= 0x7e)

startsWithContinuation :: ByteString -> Bool
startsWithContinuation line = case BS.uncons line of
  Just (w, _) -> w == 32 || w == 9
  Nothing -> False

fields :: [ByteString] -> Headers
fields lines' = go (zip [0 :: Int ..] lines') Nothing
  where
    count = length lines'
    go [] current = flush current []
    go ((lineno, line) : rest) current
      | startsWithContinuation line = case current of
          Nothing -> go rest Nothing
          Just (first, continuation) -> go rest (Just (first, line : continuation))
      | "From " `BS.isPrefixOf` line =
          flush current $
            if lineno /= 0 && lineno == count - 1 then [] else go rest Nothing
      | otherwise = case BC.elemIndex ':' line of
          Just 0 -> flush current (go rest Nothing)
          Just _ -> flush current (go rest (Just (line, [])))
          Nothing -> flush current (go rest Nothing)
    flush Nothing next = next
    flush (Just (first, continuation)) next = field first (reverse continuation) : next
    field first continuation =
      let (name, afterName) = BC.break (== ':') first
          value = BC.dropWhile (\c -> c == ' ' || c == '\t' || c == '\r' || c == '\n') (BS.drop 1 afterName <> BS.concat continuation)
       in (name, BC.dropWhileEnd (\c -> c == '\r' || c == '\n') value)
