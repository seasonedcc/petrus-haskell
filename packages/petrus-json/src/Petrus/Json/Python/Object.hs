-- | A Python object as the reference's error texts see it, with CPython's
-- @repr()@, @str()@ and @type(x).__qualname__@ of it.
--
-- This is the one Python value model of the port: the arguments of a
-- 'Petrus.Json.Python.Exception.PythonException', the inputs a pydantic
-- @ValidationError@ quotes ("Petrus.Json.Python.Pydantic"), what
-- @json.loads@ builds ('fromJson', 'pythonRepr'), and the dynamic values
-- Hamsterdan's exporter and operator read (@Hamsterdan.Python.Object.PV@
-- is a synonym for it, as petrus-impetus's validation @PV@ is). Two
-- narrower models stay apart on purpose: petrus-engine-file's @Value@
-- (jiter's duplicate keys and NaN identity) and Hamsterdan's @PyLiteral@
-- (what @ast.literal_eval@ returns, non-@str@ keys and sets included). All
-- of them, and 'Json''s own '==', compare numbers with one core,
-- 'pyNumberEq' (defined in "Petrus.Json.Value", re-exported here).
module Petrus.Json.Python.Object
  ( PyObject (..)
  , fromJson
  , fromRaw
  , pyRepr
  , pyStr
  , pyTypeName
  , pyTruthy
  , pyEq
  , PyNumber (..)
  , pyNumber
  , pyNumberEq
  , pythonRepr
  , pythonStr
  , failureArgumentText
  ) where

import Control.DeepSeq (NFData (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json.Limits (maxIntStrDigits)
import Petrus.Json.Python.JsonRepr (jsonRepr)
import Petrus.Json.Python.Scanner (Raw (..))
import Petrus.Json.PythonText (pythonStrRepr)
import Petrus.Json.Repr (pythonBytesRepr, pythonDoubleRepr, pythonIntRepr, pythonListRepr, pythonTupleRepr)
import Petrus.Json.Value (Json (..), PyNumber (..), pyNumberEq)
import Petrus.Json.Wtf8 (fromCodePoints)

-- | A Python object: what @json.loads@ builds, plus @bytes@, the tuples a
-- @model_dump(mode="python")@ produces, @slice@ (the key of the @KeyError@
-- slicing a @dict@ raises, @{}[:20]@), and any other object by its type and
-- @repr@. A dict's members are its items in order, each key once.
data PyObject
  = PyNone
  | PyBool Bool
  | PyInt Integer
  | PyFloat Double
  | PyStr Text
  | PyBytes ByteString
  | PyList [PyObject]
  | PyTuple [PyObject]
  | PyDict [(Text, PyObject)]
  | -- | @slice(start, stop, step)@.
    PySlice (Maybe Integer) (Maybe Integer) (Maybe Integer)
  | -- | Any other object: its type's @__module__@ and @__qualname__@, and
    -- its @repr@ (an instance of a @str@ or @int@ subclass is one of these
    -- too).
    PyInstance Text Text Text
  deriving stock (Eq, Show)

instance NFData PyObject where
  rnf = \case
    PyNone -> ()
    PyBool b -> rnf b
    PyInt i -> rnf i
    PyFloat d -> rnf d
    PyStr s -> rnf s
    PyBytes b -> rnf b
    PyList items -> rnf items
    PyTuple items -> rnf items
    PyDict members -> rnf members
    PySlice a b c -> rnf a `seq` rnf b `seq` rnf c
    PyInstance m q r -> rnf m `seq` rnf q `seq` rnf r

-- | The object @json.loads@ builds for a parsed value (whose objects hold
-- each key once).
fromJson :: Json -> PyObject
fromJson = \case
  Null -> PyNone
  Bool b -> PyBool b
  Int i -> PyInt i
  Float d -> PyFloat d
  String s -> PyStr s
  Array items -> PyList (map fromJson items)
  Object members -> PyDict [(k, fromJson v) | (k, v) <- members]

-- | A scanned value; a string keeps a lone surrogate as WTF-8
-- ("Petrus.Json.Wtf8"), as the @str@ CPython builds does.
fromRaw :: Raw -> PyObject
fromRaw = \case
  RNull -> PyNone
  RBool b -> PyBool b
  RInt i -> PyInt i
  RFloat d -> PyFloat d
  RStr s -> PyStr (fromCodePoints s)
  RList items -> PyList (map fromRaw items)
  RDict members -> PyDict [(fromCodePoints k, fromRaw v) | (k, v) <- members]

-- | CPython's @repr@.
pyRepr :: PyObject -> Text
pyRepr = \case
  PyNone -> "None"
  PyBool True -> "True"
  PyBool False -> "False"
  PyInt i -> pythonIntRepr i
  PyFloat d -> pythonDoubleRepr d
  PyStr s -> pythonStrRepr s
  PyBytes b -> pythonBytesRepr b
  PyList items -> pythonListRepr (map pyRepr items)
  PyTuple items -> pythonTupleRepr (map pyRepr items)
  PyDict members -> "{" <> T.intercalate ", " [pythonStrRepr k <> ": " <> pyRepr v | (k, v) <- members] <> "}"
  PySlice start stop step -> "slice(" <> T.intercalate ", " (map (maybe "None" pythonIntRepr) [start, stop, step]) <> ")"
  PyInstance _ _ text -> text

-- | CPython's @str()@ (which differs from @repr@ only for strings among
-- these objects).
pyStr :: PyObject -> Text
pyStr = \case
  PyStr s -> s
  other -> pyRepr other

-- | @type(x).__qualname__@ (which pydantic reports as @input_type@).
pyTypeName :: PyObject -> Text
pyTypeName = snd . pyType

-- | @type(x).__module__@ and @type(x).__qualname__@.
pyType :: PyObject -> (Text, Text)
pyType = \case
  PyNone -> ("builtins", "NoneType")
  PyBool _ -> ("builtins", "bool")
  PyInt _ -> ("builtins", "int")
  PyFloat _ -> ("builtins", "float")
  PyStr _ -> ("builtins", "str")
  PyBytes _ -> ("builtins", "bytes")
  PyList _ -> ("builtins", "list")
  PyTuple _ -> ("builtins", "tuple")
  PyDict _ -> ("builtins", "dict")
  PySlice {} -> ("builtins", "slice")
  PyInstance modul qualname _ -> (modul, qualname)

-- | @bool(x)@: @None@, zero and empty containers are false. A slice is
-- true, as is an opaque instance ('PyInstance'), whose own @__bool__@ or
-- @__len__@ this model does not carry (@object@'s default is true).
pyTruthy :: PyObject -> Bool
pyTruthy = \case
  PyNone -> False
  PyBool b -> b
  PyInt i -> i /= 0
  PyFloat d -> d /= 0
  PyStr s -> not (T.null s)
  PyBytes b -> not (BS.null b)
  PyList items -> not (null items)
  PyTuple items -> not (null items)
  PyDict members -> not (null members)
  PySlice {} -> True
  PyInstance {} -> True

-- | @left == right@ between objects built separately: numbers compare by
-- value across @bool@, @int@ and @float@ ('pyNumberEq'), NaN equals
-- nothing, a list never equals a tuple, and dicts compare as mappings. An
-- opaque instance ('PyInstance') equals nothing: its own @__eq__@ is not
-- part of this model, and two distinct objects without one are unequal.
pyEq :: PyObject -> PyObject -> Bool
pyEq left right = case (pyNumber left, pyNumber right) of
  (Just a, Just b) -> pyNumberEq a b
  (Just _, Nothing) -> False
  (Nothing, Just _) -> False
  (Nothing, Nothing) -> case (left, right) of
    (PyNone, PyNone) -> True
    (PyStr a, PyStr b) -> a == b
    (PyBytes a, PyBytes b) -> a == b
    (PyList as, PyList bs) -> pairwise as bs
    (PyTuple as, PyTuple bs) -> pairwise as bs
    (PyDict as, PyDict bs) ->
      length as == length bs && all (\(k, v) -> maybe False (pyEq v) (lookup k bs)) as
    (PySlice a b c, PySlice a' b' c') -> (a, b, c) == (a', b', c')
    _ -> False
  where
    pairwise as bs = length as == length bs && and (zipWith pyEq as bs)

-- | The number an object is (a @bool@, @int@ or @float@).
pyNumber :: PyObject -> Maybe PyNumber
pyNumber = \case
  PyBool b -> Just (PyExact (if b then 1 else 0))
  PyInt i -> Just (PyExact i)
  PyFloat d -> Just (PyInexact d)
  _ -> Nothing

-- | @repr(value)@ of the Python object @json.loads@ builds for a value.
pythonRepr :: Json -> Text
pythonRepr = jsonRepr

-- | @str(value)@ of the Python object @json.loads@ builds for a value: a
-- string itself, anything else its 'pythonRepr'.
pythonStr :: Json -> Text
pythonStr = pyStr . fromJson

-- | The reference's @_failure_argument_text(value)@ (the spelling of one
-- exception argument in a firing failure text): @None@, @bool@, @int@,
-- @float@, @str@ and @bytes@ by their @repr@; an @int@ whose @repr@ passes
-- CPython's 4300-digit conversion limit (which raises) and any other object
-- by the marker @<module.qualname>@ of its type.
failureArgumentText :: PyObject -> Text
failureArgumentText value = case value of
  PyNone -> pyRepr value
  PyBool _ -> pyRepr value
  PyInt i | length (show (abs i)) <= maxIntStrDigits -> pyRepr value
  PyFloat _ -> pyRepr value
  PyStr _ -> pyRepr value
  PyBytes _ -> pyRepr value
  _ -> let (modul, qualname) = pyType value in "<" <> modul <> "." <> qualname <> ">"
