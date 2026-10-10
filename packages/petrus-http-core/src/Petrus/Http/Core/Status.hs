-- | CPython 3.14's @http.HTTPStatus@ table: the reason phrase
-- @BaseHTTPRequestHandler@ puts on status lines and the description its
-- error pages explain the code with. (CPython's phrases differ from other
-- tables for some codes, e.g. 413 @Content Too Large@ and 422
-- @Unprocessable Content@.)
module Petrus.Http.Core.Status
  ( statusPhrase
  , statusDescription
  , statusTable
  ) where

import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Text (Text)

-- | The reason phrase for a code (@HTTPStatus(code).phrase@), if CPython
-- knows the code.
statusPhrase :: Int -> Maybe Text
statusPhrase code = fst <$> IntMap.lookup code statuses

-- | The long description (@HTTPStatus(code).description@).
statusDescription :: Int -> Maybe Text
statusDescription code = snd <$> IntMap.lookup code statuses

statuses :: IntMap (Text, Text)
statuses = IntMap.fromList [(code, (phrase, description)) | (code, phrase, description) <- statusTable]

-- | Every code CPython 3.14 defines, with its phrase and description.
statusTable :: [(Int, Text, Text)]
statusTable =
  [ (100, "Continue", "Request received, please continue")
  , (101, "Switching Protocols", "Switching to new protocol; obey Upgrade header")
  , (102, "Processing", "Server is processing the request")
  , (103, "Early Hints", "Headers sent to prepare for the response")
  , (200, "OK", "Request fulfilled, document follows")
  , (201, "Created", "Document created, URL follows")
  , (202, "Accepted", "Request accepted, processing continues off-line")
  , (203, "Non-Authoritative Information", "Request fulfilled from cache")
  , (204, "No Content", "Request fulfilled, nothing follows")
  , (205, "Reset Content", "Clear input form for further input")
  , (206, "Partial Content", "Partial content follows")
  , (207, "Multi-Status", "Response contains multiple statuses in the body")
  , (208, "Already Reported", "Operation has already been reported")
  , (226, "IM Used", "Request completed using instance manipulations")
  , (300, "Multiple Choices", "Object has several resources -- see URI list")
  , (301, "Moved Permanently", "Object moved permanently -- see URI list")
  , (302, "Found", "Object moved temporarily -- see URI list")
  , (303, "See Other", "Object moved -- see Method and URL list")
  , (304, "Not Modified", "Document has not changed since given time")
  , (305, "Use Proxy", "You must use proxy specified in Location to access this resource")
  , (307, "Temporary Redirect", "Object moved temporarily -- see URI list")
  , (308, "Permanent Redirect", "Object moved permanently -- see URI list")
  , (400, "Bad Request", "Bad request syntax or unsupported method")
  , (401, "Unauthorized", "No permission -- see authorization schemes")
  , (402, "Payment Required", "No payment -- see charging schemes")
  , (403, "Forbidden", "Request forbidden -- authorization will not help")
  , (404, "Not Found", "Nothing matches the given URI")
  , (405, "Method Not Allowed", "Specified method is invalid for this resource")
  , (406, "Not Acceptable", "URI not available in preferred format")
  , (407, "Proxy Authentication Required", "You must authenticate with this proxy before proceeding")
  , (408, "Request Timeout", "Request timed out; try again later")
  , (409, "Conflict", "Request conflict")
  , (410, "Gone", "URI no longer exists and has been permanently removed")
  , (411, "Length Required", "Client must specify Content-Length")
  , (412, "Precondition Failed", "Precondition in headers is false")
  , (413, "Content Too Large", "Content is too large")
  , (414, "URI Too Long", "URI is too long")
  , (415, "Unsupported Media Type", "Entity body in unsupported format")
  , (416, "Range Not Satisfiable", "Cannot satisfy request range")
  , (417, "Expectation Failed", "Expect condition could not be satisfied")
  , (418, "I'm a Teapot", "Server refuses to brew coffee because it is a teapot")
  , (421, "Misdirected Request", "Server is not able to produce a response")
  , (422, "Unprocessable Content", "Server is not able to process the contained instructions")
  , (423, "Locked", "Resource of a method is locked")
  , (424, "Failed Dependency", "Dependent action of the request failed")
  , (425, "Too Early", "Server refuses to process a request that might be replayed")
  , (426, "Upgrade Required", "Server refuses to perform the request using the current protocol")
  , (428, "Precondition Required", "The origin server requires the request to be conditional")
  , (429, "Too Many Requests", "The user has sent too many requests in a given amount of time (\"rate limiting\")")
  , (431, "Request Header Fields Too Large", "The server is unwilling to process the request because its header fields are too large")
  , (451, "Unavailable For Legal Reasons", "The server is denying access to the resource as a consequence of a legal demand")
  , (500, "Internal Server Error", "Server got itself in trouble")
  , (501, "Not Implemented", "Server does not support this operation")
  , (502, "Bad Gateway", "Invalid responses from another server/proxy")
  , (503, "Service Unavailable", "The server cannot process the request due to a high load")
  , (504, "Gateway Timeout", "The gateway server did not receive a timely response")
  , (505, "HTTP Version Not Supported", "Cannot fulfill request")
  , (506, "Variant Also Negotiates", "Server has an internal configuration error")
  , (507, "Insufficient Storage", "Server is not able to store the representation")
  , (508, "Loop Detected", "Server encountered an infinite loop while processing a request")
  , (510, "Not Extended", "Request does not meet the resource access policy")
  , (511, "Network Authentication Required", "The client needs to authenticate to gain network access")
  ]
