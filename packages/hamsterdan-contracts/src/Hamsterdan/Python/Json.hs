-- | @json.loads@ as the Hamsterdan reference calls it on provider payloads,
-- stored observations and SQLite values: CPython's defaults, a lone
-- surrogate kept in the @str@ (as WTF-8, "Petrus.Json.Wtf8"), and the
-- exception CPython raises ('PythonException': @JSONDecodeError@,
-- @UnicodeDecodeError@, the digit-limit @ValueError@).
module Hamsterdan.Python.Json
  ( loads
  , loadsBytes
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Petrus.Json (Json)
import Petrus.Json.Python (PythonException, loadsText)
import Petrus.Json.Python qualified as Python

-- | @json.loads(text)@ for a @str@.
loads :: Text -> Either PythonException Json
loads = loadsText

-- | @json.loads(raw)@ for @bytes@: @json.detect_encoding@ (UTF-8, UTF-16
-- or UTF-32, with or without a signature), the @surrogatepass@ decode,
-- then the parse.
loadsBytes :: ByteString -> Either PythonException Json
loadsBytes = Python.loadsBytes
