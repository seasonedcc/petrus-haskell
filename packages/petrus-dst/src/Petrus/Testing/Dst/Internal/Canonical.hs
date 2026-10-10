-- | A specialised encoder for the one spelling every DST digest and artifact
-- uses: @json.dumps(value, allow_nan=False, separators=(",", ":"),
-- sort_keys=True)@ (ASCII-escaped). It writes exactly the bytes of
-- @'Petrus.Json.dumps' canonicalOptions@ — the test suite checks the two
-- against each other on generated values and on every fixture — but skips
-- the general encoder's per-node error plumbing and per-character string
-- building: strings of plain printable ASCII, which is nearly every DST
-- string, are copied in one piece.
module Petrus.Testing.Dst.Internal.Canonical
  ( canonicalBuilder
  , canonicalStrict
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Builder.Extra qualified as BE
import Data.ByteString.Lazy qualified as BL
import Data.Char (ord)
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Numeric (showHex)
import Petrus.Json (Json (..), pythonFloatRepr)

-- | The canonical bytes, or the first non-finite float.
canonicalStrict :: Json -> Either Double BS.ByteString
canonicalStrict value = case nonFinite value of
  Just d -> Left d
  Nothing ->
    Right (BL.toStrict (BE.toLazyByteStringWith (BE.untrimmedStrategy 4096 BE.smallChunkSize) BL.empty (canonicalBuilder value)))

-- | The canonical spelling of a value without non-finite floats.
canonicalBuilder :: Json -> B.Builder
canonicalBuilder = \case
  Null -> B.string7 "null"
  Bool True -> B.string7 "true"
  Bool False -> B.string7 "false"
  Int i -> B.integerDec i
  Float d -> B.string7 (pythonFloatRepr d)
  String s -> string s
  Array [] -> B.string7 "[]"
  Array (first : rest) -> B.char7 '[' <> canonicalBuilder first <> foldr (\item acc -> B.char7 ',' <> canonicalBuilder item <> acc) (B.char7 ']') rest
  Object [] -> B.string7 "{}"
  Object members -> case sortBy (comparing fst) members of
    [] -> B.string7 "{}"
    first : rest -> B.char7 '{' <> member first <> foldr (\m acc -> B.char7 ',' <> member m <> acc) (B.char7 '}') rest
  where
    member (key, value) = string key <> B.char7 ':' <> canonicalBuilder value

-- | The first non-finite float in encoding order (sorted keys), as the
-- encoder meets it; the cheap unsorted scan settles the common case.
nonFinite :: Json -> Maybe Double
nonFinite value = case scan (map snd) value of
  Nothing -> Nothing
  Just _ -> scan (map snd . sortBy (comparing fst)) value
  where
    scan :: ([(Text, Json)] -> [Json]) -> Json -> Maybe Double
    scan order = \case
      Float d | isNaN d || isInfinite d -> Just d
      Array items -> firstJust order items
      Object members -> firstJust order (order members)
      _ -> Nothing
    firstJust order = foldr (\item rest -> maybe rest Just (scan order item)) Nothing

-- | CPython's @py_encode_basestring_ascii@.
string :: Text -> B.Builder
string s
  | T.all plain s = B.char7 '"' <> TE.encodeUtf8Builder s <> B.char7 '"'
  | otherwise = B.char7 '"' <> T.foldr (\c rest -> escape c <> rest) mempty s <> B.char7 '"'
  where
    plain c = c >= ' ' && c <= '~' && c /= '"' && c /= '\\'
    escape c = case c of
      '"' -> B.string7 "\\\""
      '\\' -> B.string7 "\\\\"
      '\n' -> B.string7 "\\n"
      '\r' -> B.string7 "\\r"
      '\t' -> B.string7 "\\t"
      '\b' -> B.string7 "\\b"
      '\f' -> B.string7 "\\f"
      _
        | plain c -> B.char7 c
        | ord c > 0xFFFF ->
            let v = ord c - 0x10000
             in unicodeEscape (0xD800 + (v `div` 0x400)) <> unicodeEscape (0xDC00 + (v `mod` 0x400))
        | otherwise -> unicodeEscape (ord c)
    unicodeEscape n = let digits = showHex n "" in B.string7 ("\\u" ++ replicate (4 - length digits) '0' ++ digits)
