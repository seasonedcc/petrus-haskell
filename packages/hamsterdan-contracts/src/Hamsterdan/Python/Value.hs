-- | The built-in operations the reference applies to what @json.loads@
-- returns (provider payloads, stored observations, binding values), over
-- petrus-json's 'Json': truthiness, @dict.get@, @str()@, @int()@,
-- subscripts, iteration and @type(value).__name__@, each raising the
-- exception CPython raises ('PythonException') where it raises.
module Hamsterdan.Python.Value
  ( -- * Truthiness and types
    truthy
  , orEmpty
  , isDict
  , isList
  , isStr
  , isInt
  , isBool
  , typeName
  , hashable

    -- * Access
  , get
  , getOr
  , subscript
  , iterate'

    -- * Conversions and comparison
  , str
  , repr
  , intOf
  , pyEqText
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Python.Text (intText)
import Petrus.Json (Json (..))
import Petrus.Json.Python (PythonArg (..), PythonException (..), jsonTypeName, pythonError, pythonRepr, pythonStr)

-- | Python truthiness (@bool(value)@).
truthy :: Json -> Bool
truthy = \case
  Null -> False
  Bool b -> b
  Int i -> i /= 0
  Float d -> d /= 0
  String s -> not (T.null s)
  Array items -> not (null items)
  Object members -> not (null members)

-- | @value or {}@.
orEmpty :: Json -> Json
orEmpty value = if truthy value then value else Object []

isDict, isList, isStr, isInt, isBool :: Json -> Bool
isDict = \case Object _ -> True; _ -> False
isList = \case Array _ -> True; _ -> False
isStr = \case String _ -> True; _ -> False
-- | @type(value) is int@ (booleans excluded).
isInt = \case Int _ -> True; _ -> False
isBool = \case Bool _ -> True; _ -> False

-- | @type(value).__name__@.
typeName :: Json -> Text
typeName = jsonTypeName

-- | Whether CPython can hash the value (lists and dicts cannot).
hashable :: Json -> Bool
hashable = \case
  Array _ -> False
  Object _ -> False
  _ -> True

-- | @value.get(key)@: 'Null' when absent; an @AttributeError@ when the
-- value is not a dict.
get :: Text -> Json -> Either PythonException Json
get key = getOr key Null

-- | @value.get(key, default)@.
getOr :: Text -> Json -> Json -> Either PythonException Json
getOr key fallback = \case
  Object members -> Right (maybe fallback id (lookup key members))
  other -> Left (pythonError "AttributeError" ("'" <> typeName other <> "' object has no attribute 'get'"))

-- | @value[index]@ for a non-negative integer index.
subscript :: Int -> Json -> Either PythonException Json
subscript index = \case
  Array items -> case drop index items of
    item : _ -> Right item
    [] -> Left (pythonError "IndexError" "list index out of range")
  String s -> case T.uncons (T.drop index s) of
    Just (c, _) -> Right (String (T.singleton c))
    Nothing -> Left (pythonError "IndexError" "string index out of range")
  Object _ -> Left (PythonException "KeyError" [PyInt (toInteger index)])
  other -> Left (pythonError "TypeError" ("'" <> typeName other <> "' object is not subscriptable"))

-- | @for item in value@.
iterate' :: Json -> Either PythonException [Json]
iterate' = \case
  Array items -> Right items
  String s -> Right (map (String . T.singleton) (T.unpack s))
  Object members -> Right (map (String . fst) members)
  other -> Left (pythonError "TypeError" ("'" <> typeName other <> "' object is not iterable"))

-- | @str(value)@.
str :: Json -> Text
str = pythonStr

-- | @repr(value)@.
repr :: Json -> Text
repr = pythonRepr

-- | @int(value)@.
intOf :: Json -> Either PythonException Integer
intOf = \case
  Int i -> Right i
  Bool b -> Right (if b then 1 else 0)
  Float d
    | isNaN d -> Left (pythonError "ValueError" "cannot convert float NaN to integer")
    | isInfinite d -> Left (pythonError "OverflowError" "cannot convert float infinity to integer")
    | otherwise -> Right (truncate d)
  String s -> intText s
  other -> Left (pythonError "TypeError" ("int() argument must be a string, a bytes-like object or a real number, not '" <> typeName other <> "'"))

-- | @value == "text"@.
pyEqText :: Json -> Text -> Bool
pyEqText value text = case value of
  String s -> s == text
  _ -> False
