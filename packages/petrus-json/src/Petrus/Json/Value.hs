-- | The JSON value model shared by every Petrus wire format.
--
-- Unlike @aeson@'s 'Data.Aeson.Value', this type keeps the distinction between
-- integer and floating-point numbers (CPython's @json@ module does, and the
-- reference implementation's canonical spellings depend on it) and keeps
-- object members in insertion order (CPython dicts are ordered, and Petrus
-- serializes models field by field).
--
-- Equality is the reference implementation's /value/ equality: numbers compare
-- across integer, float, and boolean the way CPython compares them
-- (@1 == 1.0 == True@), and objects compare as mappings regardless of member
-- order (a repeated key counts once, with its last value, as in the @dict@
-- the members build). Over finite numbers it is an equivalence relation;
-- like CPython's @==@, a NaN equals nothing, itself included. Token identity in a marking is defined by that equality, so replay
-- and interop depend on it. Use 'exactEq' where the reference compares
-- canonical spellings instead, and 'typeExactEq' where it compares Python
-- types node by node but ignores member order.
module Petrus.Json.Value
  ( Json (..)
  , exactEq
  , typeExactEq
  , lookupMember
  , isFiniteNumber
  , allFinite
  , jsonTypeName
  ) where

import Control.DeepSeq (NFData (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)

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

-- | CPython value equality.
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
pythonEq a b = case (numeric a, numeric b) of
  (Just x, Just y) -> numericEq x y
  _ -> False

data Numeric = NInt Integer | NFloat Double

numeric :: Json -> Maybe Numeric
numeric = \case
  Bool b -> Just (NInt (if b then 1 else 0))
  Int i -> Just (NInt i)
  Float d -> Just (NFloat d)
  _ -> Nothing

numericEq :: Numeric -> Numeric -> Bool
numericEq (NInt a) (NInt b) = a == b
numericEq (NFloat a) (NFloat b) = a == b
numericEq (NInt a) (NFloat b) = intFloatEq a b
numericEq (NFloat a) (NInt b) = intFloatEq b a

-- CPython compares an int and a float exactly, never by rounding the int.
intFloatEq :: Integer -> Double -> Bool
intFloatEq i d
  | isNaN d || isInfinite d = False
  | otherwise = toRational d == fromInteger i

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
