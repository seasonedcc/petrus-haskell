{-# LANGUAGE DeriveAnyClass #-}
-- | The input values validation sees, and the Python objects they become.
--
-- The reference validates two kinds of input. @model_validate_json@ (the
-- file loader) validates the values jiter parses, which keep every member
-- of an object, duplicates included, and tell an integer of at most 18
-- digits ('Int' in jiter) from a longer one ('BigInt'). @model_validate@
-- (the formatter and in-memory sources) validates the Python objects
-- @json.loads@ builds, where a repeated member has already collapsed to its
-- last value at its first position. 'Value' carries both; 'pyDict' and
-- 'toPython' turn a jiter value into the Python object pydantic hands to
-- plain validators and @Any@ fields, and 'toPyObject' into petrus-json's
-- 'PyObject', which error reprs and type names are spelled from.
module Petrus.EngineFile.Value
  ( Value (..)
  , pyDict
  , toPython
  , toPyObject
  , pyRepr
  , pyTypeName
  , fitsI64
  , pyEq
  , pyEqWith
  ) where

import Control.DeepSeq (NFData)
import GHC.Generics (Generic)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Petrus.Json.Python.Pydantic (PyObject (..))
import Petrus.Json.Python.Pydantic qualified as Pydantic

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

-- | The members of the Python dict built from these pairs: a repeated key
-- keeps its first position and takes its last value.
pyDict :: [(Text, a)] -> [(Text, a)]
pyDict members = case members of
  [] -> members
  [_] -> members
  _
    | Map.size lastValue == length members -> members
    | otherwise -> go Set.empty members
  where
    lastValue = Map.fromList members
    go _ [] = []
    go seen ((k, _) : rest)
      | Set.member k seen = go seen rest
      | otherwise = (k, lastValue Map.! k) : go (Set.insert k seen) rest

-- | The Python object for a value: dicts deduplicated, recursively.
toPython :: Value -> Value
toPython = \case
  VList items -> VList (map toPython items)
  VDict members -> VDict [(k, toPython v) | (k, v) <- pyDict members]
  v -> v

-- | The Python object for a value, as petrus-json models it.
toPyObject :: Value -> PyObject
toPyObject = \case
  VNull -> PNone
  VBool b -> PBool b
  VInt i _ -> PInt i
  VFloat d -> PFloat d
  VStr s -> PStr s
  VList items -> PList (map toPyObject items)
  VDict members -> PDict [(k, toPyObject v) | (k, v) <- pyDict members]

-- | @repr()@ of the Python object.
pyRepr :: Value -> Text
pyRepr = Pydantic.pyRepr . toPyObject

-- | @type(x).__qualname__@ of the Python object.
pyTypeName :: Value -> Text
pyTypeName = \case
  VNull -> Pydantic.pyTypeName PNone
  VBool b -> Pydantic.pyTypeName (PBool b)
  VInt i _ -> Pydantic.pyTypeName (PInt i)
  VFloat d -> Pydantic.pyTypeName (PFloat d)
  VStr s -> Pydantic.pyTypeName (PStr s)
  VList _ -> Pydantic.pyTypeName (PList [])
  VDict _ -> Pydantic.pyTypeName (PDict [])

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
  _ -> case (numeric a, numeric b) of
    (Just x, Just y) -> numEq x y
    _ -> False
  where
    pyEq' = pyEqWith nanIdentity
    numeric = \case
      VBool t -> Just (Left (if t then 1 else 0))
      VInt i _ -> Just (Left i)
      VFloat d -> Just (Right d)
      _ -> Nothing
    numEq (Left x) (Left y) = x == y
    numEq (Right x) (Right y) = x == y
    numEq (Left x) (Right y) = intFloat x y
    numEq (Right x) (Left y) = intFloat y x
    intFloat i d
      | isNaN d || isInfinite d = False
      | otherwise = toRational d == fromInteger i
