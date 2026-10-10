-- | CPython's @repr()@ for the values upstream interpolates into error
-- messages with @!r@ (instance ids, journal modes, SQLite row values). The
-- text, bytes and float forms live in "Petrus.Json.Repr" and are re-exported
-- here.
module Petrus.Sqlite.PythonRepr
  ( pythonReprText
  , pythonReprBytes
  , pythonReprFloat
  , pythonReprSqlData
  ) where

import Database.SQLite3 (SQLData (..))
import Petrus.Json.Repr (pythonReprBytes, pythonReprFloat, pythonReprText)

-- | @repr()@ of the Python value @sqlite3@ returns for a column.
pythonReprSqlData :: SQLData -> String
pythonReprSqlData = \case
  SQLInteger n -> show n
  SQLFloat d -> pythonReprFloat d
  SQLText t -> pythonReprText t
  SQLBlob b -> pythonReprBytes b
  SQLNull -> "None"
