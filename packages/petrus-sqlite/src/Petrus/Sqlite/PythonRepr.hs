-- | CPython's @repr()@ for the values upstream interpolates into error
-- messages with @!r@ (instance ids, journal modes, SQLite row values).
module Petrus.Sqlite.PythonRepr
  ( pythonReprText
  , pythonReprBytes
  , pythonReprFloat
  , pythonReprSqlData
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (GeneralCategory (..), chr, generalCategory, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite3 (SQLData (..))
import Numeric (showHex)
import Petrus.Json (pythonFloatRepr)

-- | @repr(str)@: single quotes unless the text contains a single quote and
-- no double quote; backslash, the quote, @\\t@, @\\n@, @\\r@ escaped; other
-- control characters and non-printable code points as @\\xhh@, @\\uhhhh@ or
-- @\\Uhhhhhhhh@; printable non-ASCII characters kept.
pythonReprText :: Text -> String
pythonReprText text = quote : T.foldr escape [quote] text
  where
    quote = if T.any (== '\'') text && not (T.any (== '"') text) then '"' else '\''
    escape c rest
      | c == quote || c == '\\' = '\\' : c : rest
      | c == '\t' = '\\' : 't' : rest
      | c == '\n' = '\\' : 'n' : rest
      | c == '\r' = '\\' : 'r' : rest
      | c < ' ' || c == '\DEL' = hex 'x' 2 (ord c) ++ rest
      | c < '\DEL' = c : rest
      | printable c = c : rest
      | ord c <= 0xff = hex 'x' 2 (ord c) ++ rest
      | ord c <= 0xffff = hex 'u' 4 (ord c) ++ rest
      | otherwise = hex 'U' 8 (ord c) ++ rest
    printable c = case generalCategory c of
      Control -> False
      Format -> False
      Surrogate -> False
      PrivateUse -> False
      NotAssigned -> False
      LineSeparator -> False
      ParagraphSeparator -> False
      Space -> False
      _ -> True

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

-- | @repr()@ of the Python value @sqlite3@ returns for a column.
pythonReprSqlData :: SQLData -> String
pythonReprSqlData = \case
  SQLInteger n -> show n
  SQLFloat d -> pythonReprFloat d
  SQLText t -> pythonReprText t
  SQLBlob b -> pythonReprBytes b
  SQLNull -> "None"
