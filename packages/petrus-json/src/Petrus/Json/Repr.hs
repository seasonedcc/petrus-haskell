-- | CPython's @repr()@ for the values upstream interpolates into error
-- messages with @!r@ (instance ids, journal modes, row values). Shared by
-- the SQLite and PostgreSQL layers; the "Petrus.Json" umbrella does not
-- re-export it.
module Petrus.Json.Repr
  ( pythonReprText
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

-- | @repr(str)@, exact for every code point ('pythonStrRepr').
pythonReprText :: Text -> String
pythonReprText = T.unpack . pythonStrRepr

hex :: Char -> Int -> Int -> String
hex marker width n = '\\' : marker : replicate (width - length digits) '0' ++ digits
  where
    digits = showHex n ""

-- | @repr(bytes)@: @b'…'@ with the same quote choice, printable ASCII kept
-- and every other byte as @\\xhh@.
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

-- | @repr(float)@, including @inf@, @-inf@ and @nan@.
pythonReprFloat :: Double -> String
pythonReprFloat d
  | isNaN d = "nan"
  | isInfinite d = if d > 0 then "inf" else "-inf"
  | otherwise = pythonFloatRepr d
