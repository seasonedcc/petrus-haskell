-- | Response bytes exactly as CPython 3.14's @BaseHTTPRequestHandler@
-- writes them with @protocol_version = "HTTP/1.0"@: the status line, then
-- @Server@ and @Date@ (@send_response@), then the caller's headers, a blank
-- line and the body. Status line and headers are left out entirely when
-- the request is HTTP/0.9, as CPython does. Pure, so the bytes can be
-- compared with Python's directly.
module Petrus.Http.Core.Response
  ( -- * Responses
    Response (..)
  , response
  , renderResponse
  , ResponseEncodingError (..)

    -- * Error pages (@send_error@)
  , renderError
  , errorPage
  , errorContentType
  , escapeHtml
  , bodyAllowed

    -- * Header values
  , httpDate
  , protocolVersion
  ) where

import Control.Exception (Exception, throw)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), dayOfWeek, toGregorian)
import Petrus.Http.Core.Status (statusDescription, statusPhrase)

-- | A response for 'renderResponse'.
data Response = Response
  { responseStatus :: Int
  , responseReason :: Maybe Text
  -- ^ The reason phrase; 'Nothing' takes CPython's phrase for the code (an
  -- empty phrase for a code it does not know). Written as ISO-8859-1.
  , responseHeaders :: [(ByteString, ByteString)]
  -- ^ Written in order after @Server@ and @Date@.
  , responseBody :: ByteString
  -- ^ Written as given. 'renderResponse' never adds @Content-Length@ and
  -- never drops the body for @HEAD@: as with @BaseHTTPRequestHandler@, both
  -- are the handler's decision.
  }
  deriving stock (Eq, Show)

-- | A response with the default reason phrase.
response :: Int -> [(ByteString, ByteString)] -> ByteString -> Response
response status headers body = Response status Nothing headers body

-- | Raised when a reason phrase has a character outside ISO-8859-1, which
-- CPython refuses the same way (@UnicodeEncodeError@ from
-- @send_response_only@).
newtype ResponseEncodingError = ResponseEncodingError Text
  deriving stock (Eq, Show)

instance Exception ResponseEncodingError

-- | The protocol written on every status line.
protocolVersion :: ByteString
protocolVersion = "HTTP/1.0"

-- | The bytes for a response: server software (the @Server@ value), the
-- @Date@ value ('httpDate'), the request version (@HTTP/0.9@ suppresses
-- the status line and every header) and the response.
renderResponse :: ByteString -> ByteString -> ByteString -> Response -> ByteString
renderResponse software date version (Response status reason headers body)
  | version == "HTTP/0.9" = body
  | otherwise =
      BL.toStrict . B.toLazyByteString $
        B.byteString protocolVersion
          <> B.char7 ' '
          <> B.intDec status
          <> B.char7 ' '
          <> B.byteString (latin1Strict phrase)
          <> crlf
          <> header ("Server", software)
          <> header ("Date", date)
          <> foldMap header headers
          <> crlf
          <> B.byteString body
  where
    phrase = case reason of
      Just text -> text
      Nothing -> maybe "" id (statusPhrase status)
    header (name, value) = B.byteString name <> ": " <> B.byteString value <> crlf
    crlf = "\r\n"

latin1Strict :: Text -> ByteString
latin1Strict text
  | T.all (<= '\xff') text = BC.pack (T.unpack text)
  | otherwise = throw (ResponseEncodingError text)

-- | @send_error(code, message, explain)@: the reason phrase is the message
-- (CPython's phrase for the code by default, @???@ for an unknown code),
-- headers @Connection: close@ and — when the code takes a body —
-- @Content-Type: text/html;charset=utf-8@ and @Content-Length@, then the
-- 'errorPage', which is left out for a @HEAD@ command. Arguments: server
-- software, date, request version, request command, code, message,
-- explanation.
renderError :: ByteString -> ByteString -> ByteString -> ByteString -> Int -> Maybe Text -> Maybe Text -> ByteString
renderError software date version command status message explain =
  renderResponse software date version $
    Response
      { responseStatus = status
      , responseReason = Just shortMessage
      , responseHeaders =
          ("Connection", "close")
            : if hasBody
              then [("Content-Type", errorContentType), ("Content-Length", BC.pack (show (BS.length page)))]
              else []
      , responseBody = if hasBody && command /= "HEAD" then page else ""
      }
  where
    shortMessage = maybe (maybe "???" id (statusPhrase status)) id message
    longMessage = maybe (maybe "???" id (statusDescription status)) id explain
    hasBody = bodyAllowed status
    page = errorPage status shortMessage longMessage

-- | Whether @send_error@ writes a page for the code: not for 1xx, 204, 205
-- or 304.
bodyAllowed :: Int -> Bool
bodyAllowed status = status >= 200 && status `notElem` [204, 205, 304]

-- | @DEFAULT_ERROR_CONTENT_TYPE@.
errorContentType :: ByteString
errorContentType = "text/html;charset=utf-8"

-- | @DEFAULT_ERROR_MESSAGE@ filled in with the code and the HTML-escaped
-- message and explanation, as UTF-8.
errorPage :: Int -> Text -> Text -> ByteString
errorPage status message explain =
  TE.encodeUtf8 . T.concat $
    [ "<!DOCTYPE HTML>\n"
    , "<html lang=\"en\">\n"
    , "    <head>\n"
    , "        <meta charset=\"utf-8\">\n"
    , "        <style type=\"text/css\">\n"
    , "            :root {\n"
    , "                color-scheme: light dark;\n"
    , "            }\n"
    , "        </style>\n"
    , "        <title>Error response</title>\n"
    , "    </head>\n"
    , "    <body>\n"
    , "        <h1>Error response</h1>\n"
    , "        <p>Error code: ", code, "</p>\n"
    , "        <p>Message: ", escapeHtml message, ".</p>\n"
    , "        <p>Error code explanation: ", code, " - ", escapeHtml explain, ".</p>\n"
    , "    </body>\n"
    , "</html>\n"
    ]
  where
    code = T.pack (show status)

-- | @html.escape(text, quote=False)@: @&@, @<@ and @>@.
escapeHtml :: Text -> Text
escapeHtml = T.concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  c -> T.singleton c

-- | @email.utils.formatdate(usegmt=True)@: @Sat, 10 Oct 2026 12:00:00 GMT@
-- (whole seconds, truncated).
httpDate :: UTCTime -> ByteString
httpDate (UTCTime day time) =
  BL.toStrict . B.toLazyByteString $
    B.string7 (weekdays !! (fromEnum (dayOfWeek day) `mod` 7))
      <> ", "
      <> two dayOfMonth
      <> B.char7 ' '
      <> B.string7 (months !! (monthOfYear - 1))
      <> B.char7 ' '
      <> B.integerDec year
      <> B.char7 ' '
      <> two hours
      <> B.char7 ':'
      <> two minutes
      <> B.char7 ':'
      <> two seconds
      <> " GMT"
  where
    (year, monthOfYear, dayOfMonth) = toGregorian day
    -- Whole seconds, truncated.
    total = min 86399 (floor (toRational time)) :: Int
    (hours, rest) = total `divMod` 3600
    (minutes, seconds) = rest `divMod` 60
    two n = B.char7 (toEnum (48 + n `div` 10)) <> B.char7 (toEnum (48 + n `mod` 10))
    weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
