-- | @hashlib@ as the Hamsterdan reference uses it. The digest is
-- crypton's, which uses the CPU's SHA instructions where it has them.
module Hamsterdan.Python.Hashlib
  ( sha256Hex
  , sha256HexText
  ) where

import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

-- | @hashlib.sha256(data).hexdigest()@.
sha256Hex :: ByteString -> Text
sha256Hex bytes = TE.decodeLatin1 (Base16.encode (BA.convert (hashWith SHA256 bytes)))

-- | @hashlib.sha256(text.encode()).hexdigest()@.
sha256HexText :: Text -> Text
sha256HexText = sha256Hex . TE.encodeUtf8
