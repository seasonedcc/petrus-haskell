-- | CPython's @repr()@ of the scalars upstream interpolates into error
-- messages with @!r@ (strings, bytes, ints and floats), and of containers of
-- already-rendered items. The @repr()@ and @str()@ of whole Python objects
-- (what @json.loads@ returns among them) are "Petrus.Json.Python.Object"'s.
--
-- The 'Text' functions are the API; the 'String' spellings
-- ('pythonReprText', 'pythonReprBytes', 'pythonReprFloat') remain for the
-- SQLite and PostgreSQL layers, which build 'String' messages.
module Petrus.Json.Repr
  ( -- * Scalars
    pythonIntRepr
  , pythonOptionalStrRepr
  , pythonBytesRepr
  , pythonDoubleRepr
    -- * Containers of already-rendered items
  , pythonListRepr
  , pythonStrListRepr
  , pythonTupleRepr
    -- * 'String' spellings
  , pythonReprText
  , pythonReprBytes
  , pythonReprFloat
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr)
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)
import Petrus.Json.Encode (pythonFloatRepr)
import Petrus.Json.PythonText (pythonStrRepr)

-- | @repr(int)@.
pythonIntRepr :: Integral a => a -> Text
pythonIntRepr = T.pack . show . toInteger

-- | @repr@ of a @str | None@.
pythonOptionalStrRepr :: Maybe Text -> Text
pythonOptionalStrRepr = maybe "None" pythonStrRepr

-- | @repr(float)@, including @inf@, @-inf@ and @nan@.
pythonDoubleRepr :: Double -> Text
pythonDoubleRepr = T.pack . pythonReprFloat

-- | @repr(bytes)@: @b'…'@ with the same quote choice as @repr(str)@,
-- printable ASCII kept and every other byte as @\\xhh@.
pythonBytesRepr :: ByteString -> Text
pythonBytesRepr = T.pack . pythonReprBytes

-- | @repr(list)@ given each item's repr.
pythonListRepr :: [Text] -> Text
pythonListRepr items = "[" <> T.intercalate ", " items <> "]"

-- | @repr(list)@ of a list of strings.
pythonStrListRepr :: [Text] -> Text
pythonStrListRepr = pythonListRepr . map pythonStrRepr

-- | @repr(tuple)@ given each item's repr (a single item keeps its comma).
pythonTupleRepr :: [Text] -> Text
pythonTupleRepr = \case
  [single] -> "(" <> single <> ",)"
  items -> "(" <> T.intercalate ", " items <> ")"

-- | @repr(str)@, exact for every code point ('pythonStrRepr').
pythonReprText :: Text -> String
pythonReprText = T.unpack . pythonStrRepr

hex :: Char -> Int -> Int -> String
hex marker width n = '\\' : marker : replicate (width - length digits) '0' ++ digits
  where
    digits = showHex n ""

-- | @repr(bytes)@ as a 'String' ('pythonBytesRepr').
pythonReprBytes :: ByteString -> String
pythonReprBytes bytes = 'b' : quote : BS.foldr escape [quote] bytes
  where
    quote = if BS.elem 39 bytes && not (BS.elem 34 bytes) then '"' else '\''
    escape w rest
      | c == quote || c == '\\' = '\\' : c : rest
      | c == '\t' = '\\' : 't' : rest
      | c == '\n' = '\\' : 'n' : rest
      | c == '\r' = '\\' : 'r' : rest
      | w < 0x20 || w >= 0x7f = hex 'x' 2 (fromIntegral w) ++ rest
      | otherwise = c : rest
      where
        c = chr (fromIntegral w)

-- | @repr(float)@ as a 'String' ('pythonDoubleRepr').
pythonReprFloat :: Double -> String
pythonReprFloat d
  | isNaN d = "nan"
  | isInfinite d = if d > 0 then "inf" else "-inf"
  | otherwise = pythonFloatRepr d
