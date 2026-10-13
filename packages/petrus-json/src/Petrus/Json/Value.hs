-- | The JSON value model shared by every Petrus wire format.
--
-- Unlike @aeson@'s 'Data.Aeson.Value', this type keeps the distinction between
-- integer and floating-point numbers (CPython's @json@ module does, and the
-- reference implementation's canonical spellings depend on it) and keeps
-- object members in insertion order (CPython dicts are ordered, and Petrus
-- serializes models field by field).
--
-- Equality ('pythonEq', the 'Eq' instance) is the reference implementation's
-- /value/ equality: numbers compare across integer, float, and boolean the
-- way CPython compares them (@1 == 1.0 == True@, through 'pyNumberEq'),
-- and objects compare as mappings regardless of member order (a repeated
-- key counts once, with its last value, as in the @dict@ the members
-- build). Over finite numbers it is an equivalence relation; like CPython's
-- @==@, a NaN equals nothing, itself included. Token identity in a marking
-- is defined by that equality, so replay and interop depend on it. Use
-- 'exactEq' where the reference compares canonical spellings instead, and
-- 'typeExactEq' where it compares Python types node by node but ignores
-- member order.
module Petrus.Json.Value
  ( Json (..)
  , pythonEq
  , pythonTruthy
  , PyNumber (..)
  , pyNumberEq
  , exactEq
  , typeExactEq
  , lookupMember
  , pythonDict
  , isFiniteNumber
  , allFinite
  , jsonTypeName
  ) where

import Control.DeepSeq (NFData (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Exts (inline)

-- | A JSON value with CPython-compatible number and object semantics.
data Json
  = Null
  | Bool Bool
  | Int Integer
  | Float Double
  | String Text
  | Array [Json]
  | -- | Members in insertion order; keys are unique in every value this
    -- package produces.
    Object [(Text, Json)]
  deriving stock (Show)

instance Eq Json where
  (==) = pythonEq

instance NFData Json where
  rnf = \case
    Null -> ()
    Bool b -> rnf b
    Int i -> rnf i
    Float d -> rnf d
    String s -> rnf s
    Array items -> rnf items
    Object members -> rnf members

-- | CPython's @left == right@ between the objects @json.loads@ builds for
-- two values (the 'Eq' instance): see the module header.
pythonEq :: Json -> Json -> Bool
pythonEq Null Null = True
pythonEq (String a) (String b) = a == b
pythonEq (Array as) (Array bs) = length as == length bs && and (zipWith pythonEq as bs)
pythonEq (Object as) (Object bs) =
  -- The dicts the member lists stand for: a repeated key counts once, with
  -- its last value (as @dict(pairs)@ and @json.loads@ keep it), so the
  -- comparison is symmetric and independent of member order.
  let left = Map.fromList as
      right = Map.fromList bs
   in Map.keysSet left == Map.keysSet right && and (Map.intersectionWith pythonEq left right)
pythonEq a b = case (jsonNumber a, jsonNumber b) of
  -- Inlined at this one call ('inline'), so '==' on two numbers allocates
  -- no 'PyNumber' and compiles to the code of the copy it replaces; the
  -- other callers call 'pyNumberEq'.
  (Just x, Just y) -> inline pyNumberEq x y
  _ -> False

-- | @bool(value)@ of the object @json.loads@ builds: @None@, @False@, zero
-- (@0@, @0.0@, @-0.0@) and an empty string, list or dict are false;
-- everything else, NaN included, is true.
pythonTruthy :: Json -> Bool
pythonTruthy = \case
  Null -> False
  Bool b -> b
  Int i -> i /= 0
  Float d -> d /= 0
  String s -> not (T.null s)
  Array items -> not (null items)
  Object members -> not (null members)

-- | A number as Python's @==@ compares it: an @int@ (or @bool@) exactly, a
-- @float@ by its value.
data PyNumber = PyExact Integer | PyInexact Double

-- | The number a value is (a @bool@, @int@ or @float@).
jsonNumber :: Json -> Maybe PyNumber
jsonNumber = \case
  Bool b -> Just (PyExact (if b then 1 else 0))
  Int i -> Just (PyExact i)
  Float d -> Just (PyInexact d)
  _ -> Nothing

-- | CPython's numeric @==@: an @int@ and a @float@ compare exactly (no
-- rounding of either side), NaN equals nothing and an infinity equals no
-- @int@. The one numeric core of Python @==@ in the port: every Python
-- value model compares numbers with it ('Json' in 'pythonEq', petrus-json's
-- @PyObject@ ("Petrus.Json.Python.Object"), the @ast.literal_eval@ values
-- of @Hamsterdan.PyLiteral@, the engine-file loader's values, and the
-- @sqlite3@ values motus's local dispatch compares), and so do the
-- int-against-float checks of a pydantic @Literal[n]@ (petrus-impetus,
-- Hamsterdan's codecs) and of petrus-history-store's SQLite columns.
pyNumberEq :: PyNumber -> PyNumber -> Bool
pyNumberEq (PyExact a) (PyExact b) = a == b
pyNumberEq (PyInexact a) (PyInexact b) = a == b
pyNumberEq (PyExact a) (PyInexact b) = exactFloatEq a b
pyNumberEq (PyInexact a) (PyExact b) = exactFloatEq b a

exactFloatEq :: Integer -> Double -> Bool
exactFloatEq integral floating =
  not (isNaN floating || isInfinite floating) && toRational floating == fromInteger integral

-- | Structural equality that also distinguishes integer from float spellings
-- and object member order: two values are 'exactEq' exactly when CPython
-- would serialize them to the same text.
exactEq :: Json -> Json -> Bool
exactEq Null Null = True
exactEq (Bool a) (Bool b) = a == b
exactEq (Int a) (Int b) = a == b
exactEq (Float a) (Float b) = (isNaN a && isNaN b) || (a == b && isNegativeZero a == isNegativeZero b)
exactEq (String a) (String b) = a == b
exactEq (Array as) (Array bs) = length as == length bs && and (zipWith exactEq as bs)
exactEq (Object as) (Object bs) =
  length as == length bs && and (zipWith (\(k, v) (k', v') -> k == k' && exactEq v v') as bs)
exactEq _ _ = False

-- | Type-exact, member-order-insensitive equality: the reference's
-- @_exact_json_equal@ (simulation HTTP's definition-mismatch check).
--
-- Every node must have the same Python type (@int@, @float@ and @bool@ never
-- equal each other), objects compare as key sets with each member compared
-- recursively, arrays compare in order, and scalars compare with Python @==@,
-- so @0.0@ equals @-0.0@ and NaN equals nothing. Unlike 'exactEq', member
-- order and the sign of zero do not matter; unlike '==', @1@, @1.0@ and
-- @true@ differ.
--
-- Objects are compared by key /set/, as CPython dicts are: a repeated key in an
-- 'Object' (which no parser preset produces) counts once, with its last value.
typeExactEq :: Json -> Json -> Bool
typeExactEq Null Null = True
typeExactEq (Bool a) (Bool b) = a == b
typeExactEq (Int a) (Int b) = a == b
typeExactEq (Float a) (Float b) = a == b
typeExactEq (String a) (String b) = a == b
typeExactEq (Array as) (Array bs) = length as == length bs && and (zipWith typeExactEq as bs)
typeExactEq (Object as) (Object bs) =
  let left = Map.fromList as
      right = Map.fromList bs
   in Map.keysSet left == Map.keysSet right
        && and (Map.intersectionWith typeExactEq left right)
typeExactEq _ _ = False

-- | The value of an object member, if present.
lookupMember :: Text -> Json -> Maybe Json
lookupMember key = \case
  Object members -> lookup key members
  _ -> Nothing

-- | Whether a number is finite (non-numbers are trivially finite).
isFiniteNumber :: Json -> Bool
isFiniteNumber = \case
  Float d -> not (isNaN d || isInfinite d)
  _ -> True

-- | Whether every number in a value is finite.
allFinite :: Json -> Bool
allFinite = \case
  Float d -> not (isNaN d || isInfinite d)
  Array items -> all allFinite items
  Object members -> all (allFinite . snd) members
  _ -> True

-- | The members a Python @dict@ built from these pairs holds (@dict(pairs)@,
-- as @json.loads@ keeps them): each key once, at its first position, with
-- its last value.
pythonDict :: [(Text, a)] -> [(Text, a)]
pythonDict members
  | distinct = members
  | otherwise = go Set.empty members
  where
    distinct = case drop 8 members of
      [] -> pairwiseDistinct members
      _ -> Map.size final == length members
    pairwiseDistinct [] = True
    pairwiseDistinct ((key, _) : rest) = all ((/= key) . fst) rest && pairwiseDistinct rest
    final = Map.fromList members
    go _ [] = []
    go seen ((key, _) : rest)
      | Set.member key seen = go seen rest
      | otherwise = (key, final Map.! key) : go (Set.insert key seen) rest

-- | The CPython type name of a value (for diagnostics that mirror the
-- reference's messages).
jsonTypeName :: Json -> Text
jsonTypeName = \case
  Null -> "NoneType"
  Bool _ -> "bool"
  Int _ -> "int"
  Float _ -> "float"
  String _ -> "str"
  Array _ -> "list"
  Object _ -> "dict"
