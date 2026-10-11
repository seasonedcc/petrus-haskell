-- | The reference's @_bounded_text@, over CPython's
-- @bytes.decode("utf-8", errors="replace")@ ('decodeUtf8Replace', from
-- "Petrus.Json.Python"): agenticus returns decoded process output to the
-- model, so the reference's substitution is reproduced exactly.
module Petrus.Agenticus.Internal.PyText
  ( boundedText
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json.Python (decodeUtf8Replace)

-- | The reference's @_bounded_text(data, limit)@: decode at most @limit@
-- bytes with replacement, then drop trailing characters until the UTF-8
-- encoding fits @limit@ (a replacement character can be longer than the
-- bytes it replaced). The flag reports any truncation.
boundedText :: ByteString -> Int -> (Text, Bool)
boundedText bytes limit
  | fits = (decoded, B.length bytes > limit)
  | otherwise = (T.take (prefix 0 0 (T.unpack decoded)) decoded, True)
  where
    decoded = decodeUtf8Replace (B.take limit bytes)
    fits = B.length (TE.encodeUtf8 decoded) <= limit
    -- Dropping characters from the end until the encoding fits leaves the
    -- longest prefix whose encoding fits; count it in one pass.
    prefix :: Int -> Int -> String -> Int
    prefix count size = \case
      c : rest | size + width c <= limit -> prefix (count + 1) (size + width c) rest
      _ -> count
    width c
      | c < '\x80' = 1
      | c < '\x800' = 2
      | c < '\x10000' = 3
      | otherwise = 4
