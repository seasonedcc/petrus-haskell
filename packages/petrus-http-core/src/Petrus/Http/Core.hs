-- | A CPython-compatible HTTP/1.0 server core for the Petrus observation
-- and simulation services: @http.server.ThreadingHTTPServer@ with a
-- @BaseHTTPRequestHandler@ (@protocol_version = "HTTP/1.0"@), byte for
-- byte, one request per connection.
--
-- * "Petrus.Http.Core.Server": binding, the accept loop, shutdown, requests
--   and responses.
-- * "Petrus.Http.Core.Parse": CPython's request-line and header parsing.
-- * "Petrus.Http.Core.Response": status lines, headers and @send_error@
--   pages.
-- * "Petrus.Http.Core.Status": CPython's status phrases.
--
-- The only intended byte difference from CPython is the @Server@ header
-- value ('defaultServerSoftware'); see DIVERGENCES.md.
module Petrus.Http.Core
  ( module Petrus.Http.Core.Server
  , module Petrus.Http.Core.Parse
  , module Petrus.Http.Core.Response
  , module Petrus.Http.Core.Status
  ) where

import Petrus.Http.Core.Parse
import Petrus.Http.Core.Response
import Petrus.Http.Core.Server
import Petrus.Http.Core.Status
