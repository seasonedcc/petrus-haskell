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
  , jsonToPy
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Json.Python (pythonDoubleRepr, pythonIntRepr, pythonListRepr, pythonStrRepr, pythonTupleRepr)

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

-- | CPython's @repr@ (the scalars and containers are petrus-json's
-- "Petrus.Json.Python" spellings).
pyRepr :: PyObj -> Text
pyRepr = \case
  PyNone -> "None"
  PyBool True -> "True"
  PyBool False -> "False"
  PyInt i -> pythonIntRepr i
  PyFloat d -> pythonDoubleRepr d
  PyStr s -> pythonStrRepr s
  PyList items -> pythonListRepr (map pyRepr items)
  PyTuple items -> pythonTupleRepr (map pyRepr items)
  PyDict members -> "{" <> T.intercalate ", " [pyRepr k <> ": " <> pyRepr v | (k, v) <- members] <> "}"
  PyModel name fields -> name <> "(" <> T.intercalate ", " [k <> "=" <> pyRepr v | (k, v) <- fields] <> ")"

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
