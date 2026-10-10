-- | Python @repr()@ spellings.
--
-- Several reference error messages embed Python @repr@ output (for example
-- @DST budget 'actions' exhausted at limit 1@, or the checker list in
-- @DST checker failure after atomic boundary: ['a', 'b']@). Some of these
-- strings are retained inside artifacts and covered by journal digests, so
-- they must be byte-identical. This module renders a small Python object
-- model the way CPython's @repr@ does.
module Petrus.Testing.Dst.PyRepr
  ( PyObj (..)
  , pyRepr
  , pyStrRepr
  , jsonToPy
  ) where

import Data.Char (GeneralCategory (..), generalCategory, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)
import Petrus.Json (Json (..), pythonFloatRepr)

-- | The Python values whose @repr@ the reference messages use.
data PyObj
  = PyNone
  | PyBool Bool
  | PyInt Integer
  | PyFloat Double
  | PyStr Text
  | PyList [PyObj]
  | PyTuple [PyObj]
  | PyDict [(PyObj, PyObj)]
  | -- | A pydantic model: @Name(field=value, ...)@.
    PyModel Text [(Text, PyObj)]
  deriving stock (Show)

-- | CPython's @repr@.
pyRepr :: PyObj -> Text
pyRepr = \case
  PyNone -> "None"
  PyBool True -> "True"
  PyBool False -> "False"
  PyInt i -> T.pack (show i)
  PyFloat d
    | isNaN d -> "nan"
    | isInfinite d -> if d > 0 then "inf" else "-inf"
    | otherwise -> T.pack (pythonFloatRepr d)
  PyStr s -> pyStrRepr s
  PyList items -> "[" <> T.intercalate ", " (map pyRepr items) <> "]"
  PyTuple [single] -> "(" <> pyRepr single <> ",)"
  PyTuple items -> "(" <> T.intercalate ", " (map pyRepr items) <> ")"
  PyDict members -> "{" <> T.intercalate ", " [pyRepr k <> ": " <> pyRepr v | (k, v) <- members] <> "}"
  PyModel name fields -> name <> "(" <> T.intercalate ", " [k <> "=" <> pyRepr v | (k, v) <- fields] <> ")"

-- | CPython's @str.__repr__@ (@unicode_repr@).
pyStrRepr :: Text -> Text
pyStrRepr s = T.singleton quote <> T.concatMap escape s <> T.singleton quote
  where
    quote = if T.any (== '\'') s && not (T.any (== '"') s) then '"' else '\''
    escape c
      | c == quote || c == '\\' = T.pack ['\\', c]
      | c == '\t' = "\\t"
      | c == '\n' = "\\n"
      | c == '\r' = "\\r"
      | ord c < 0x20 || ord c == 0x7f = hexEscape 'x' 2 (ord c)
      | ord c < 0x7f = T.singleton c
      | printable c = T.singleton c
      | ord c <= 0xff = hexEscape 'x' 2 (ord c)
      | ord c <= 0xffff = hexEscape 'u' 4 (ord c)
      | otherwise = hexEscape 'U' 8 (ord c)
    hexEscape tag width n =
      let digits = showHex n ""
       in T.pack ('\\' : tag : replicate (width - length digits) '0' ++ digits)
    printable c = case generalCategory c of
      Control -> False
      Format -> False
      Surrogate -> False
      PrivateUse -> False
      NotAssigned -> False
      LineSeparator -> False
      ParagraphSeparator -> False
      Space -> c == ' '
      _ -> True

-- | The Python object @json.loads@ produces for a JSON value.
jsonToPy :: Json -> PyObj
jsonToPy = \case
  Null -> PyNone
  Bool b -> PyBool b
  Int i -> PyInt i
  Float d -> PyFloat d
  String s -> PyStr s
  Array items -> PyList (map jsonToPy items)
  Object members -> PyDict [(PyStr k, jsonToPy v) | (k, v) <- members]
