{-# LANGUAGE DeriveAnyClass #-}
-- | The input values validation sees, and the Python objects they become.
--
-- The reference validates two kinds of input. @model_validate_json@ (the
-- file loader) validates the values jiter parses, which keep every member
-- of an object, duplicates included, and tell an integer of at most 18
-- digits ('Int' in jiter) from a longer one ('BigInt'). @model_validate@
-- (the formatter and in-memory sources) validates the Python objects
-- @json.loads@ builds, where a repeated member has already collapsed to its
-- last value at its first position. 'Value' carries both; 'toPython'
-- (with petrus-json's 'pythonDict') turns a jiter value into the Python
-- object pydantic hands to
-- plain validators and @Any@ fields, and 'toPyObject' into petrus-json's
-- 'PyObject', which error reprs and type names are spelled from.
module Petrus.EngineFile.Value
  ( Value (..)
  , toPython
  , toPyObject
  , pyRepr
  , pyTypeName
  , fitsI64
  , pyEq
  , pyEqWith
  , valueNumber
  ) where

import Control.DeepSeq (NFData)
import GHC.Generics (Generic)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Petrus.Json (pythonDict)
import Petrus.Json.Python.Object (PyNumber (..), PyObject (..), pyNumberEq)
import Petrus.Json.Python.Object qualified as Object

-- | A parsed JSON value.
data Value
  = VNull
  | VBool !Bool
  | -- | An integer; the flag is set when jiter parsed it as a @BigInt@ (more
    -- than 18 digits). Values from @json.loads@ never set it.
    VInt !Integer !Bool
  | VFloat !Double
  | VStr !Text
  | VList ![Value]
  | -- | Members in document order; jiter keeps repeated keys.
    VDict ![(Text, Value)]
  deriving stock (Show, Generic)
  deriving anyclass (NFData)

-- | The Python object for a value: dicts deduplicated, recursively.
toPython :: Value -> Value
toPython = \case
  VList items -> VList (map toPython items)
  VDict members -> VDict [(k, toPython v) | (k, v) <- pythonDict members]
  v -> v

-- | The Python object for a value, as petrus-json models it.
toPyObject :: Value -> PyObject
toPyObject = \case
  VNull -> PyNone
  VBool b -> PyBool b
  VInt i _ -> PyInt i
  VFloat d -> PyFloat d
  VStr s -> PyStr s
  VList items -> PyList (map toPyObject items)
  VDict members -> PyDict [(k, toPyObject v) | (k, v) <- pythonDict members]

-- | @repr()@ of the Python object.
pyRepr :: Value -> Text
pyRepr = Object.pyRepr . toPyObject

-- | @type(x).__qualname__@ of the Python object.
pyTypeName :: Value -> Text
pyTypeName = Object.pyTypeName . toPyObject

-- | Whether an integer fits a signed 64-bit integer.
fitsI64 :: Integer -> Bool
fitsI64 i = i >= -9223372036854775808 && i <= 9223372036854775807

-- | Python @==@ between two objects built from separate parses: numbers
-- compare across @bool@, @int@ and @float@, NaN equals nothing, dicts
-- compare as mappings.
pyEq :: Value -> Value -> Bool
pyEq = pyEqWith False

-- | Python @==@ (through @PyObject_RichCompareBool@, as containers compare
-- their items), where the flag says whether every NaN is one shared object
-- (true of @json.loads@, whose @NaN@ token always yields the same float, so
-- the identity shortcut makes it equal itself).
pyEqWith :: Bool -> Value -> Value -> Bool
pyEqWith nanIdentity a b = case (a, b) of
  (VNull, VNull) -> True
  (VFloat x, VFloat y) | nanIdentity && isNaN x && isNaN y -> True
  (VStr x, VStr y) -> x == y
  (VList xs, VList ys) -> length xs == length ys && and (zipWith pyEq' xs ys)
  (VDict xs, VDict ys) ->
    let mx = Map.fromList xs
        my = Map.fromList ys
     in Map.size mx == Map.size my
          && and [maybe False (pyEq' v) (Map.lookup k my) | (k, v) <- Map.toList mx]
  _ -> case (valueNumber a, valueNumber b) of
    (Just x, Just y) -> pyNumberEq x y
    _ -> False
  where
    pyEq' = pyEqWith nanIdentity

-- | The number a value is (a @bool@, @int@ or @float@), as Python's @==@
-- ('pyNumberEq') and @<@ ('Petrus.Json.Python.Object.pyNumberCompare')
-- compare it.
valueNumber :: Value -> Maybe PyNumber
valueNumber = \case
  VBool t -> Just (PyExact (if t then 1 else 0))
  VInt i _ -> Just (PyExact i)
  VFloat d -> Just (PyInexact d)
  _ -> Nothing
