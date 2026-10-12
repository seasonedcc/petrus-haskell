-- | Python semantics over JSON-faithful values, for the folds that read
-- the untyped (@dict[str, Any]@) parts of V5 batons.
--
-- The reference folds subscript, compare, merge, and test the truth of
-- these values with plain Python operators. A value that is not what the
-- fold expects makes Python raise, and the firing records the exception's
-- text. Every helper here reproduces both the result and that text, so a
-- malformed baton fails a Haskell fold exactly as it fails the reference.
module Hamsterdan.Readiness.NetV5.Py
  ( Py
    -- * Types and truth
  , typeName
  , truthy
  , isNone
    -- * Subscripts and lookups
  , getItem
  , getKey
  , get
  , getOr
  , member
  , asObject
  , merge
  , overlay
  , without
  , insert
    -- * Iteration
  , pyList
    -- * Comparisons
  , CompareOp (..)
  , compareValues
  , tupleCompare
  , pyMax2
    -- * Text
  , pyStr
  , pyRepr
    -- * Strict construction
  , construct
  , dumpObject
  , strictText
  , strictInteger
  , spelling
  , unspell
  , texts
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Contracts.Codec (Contract, Enumeration (..), dump, validate)
import Hamsterdan.PyLiteral qualified as Lit
import Hamsterdan.Readiness.NetV5.Folding (PythonException, pyError, typeError, validationError)
import Petrus.Json.Python.Object (PyObject (..), fromJson)
import Petrus.Json (Json (..))
import Hamsterdan.Python.Value (truthy, typeName)
import Hamsterdan.Python.Value qualified as Value

-- | A computation that may raise a Python exception.
type Py = Either PythonException

isNone :: Json -> Bool
isNone = \case
  Null -> True
  _ -> False

-- | @container[key]@ for a string key.
getItem :: Json -> Text -> Py Json
getItem container key = getKey container (String key)

-- | @container[key]@ for any key value.
getKey :: Json -> Json -> Py Json
getKey container key = case container of
  Object members -> do
    hashable key
    case key of
      String k -> maybe (Left (missing key)) Right (lookup k members)
      _ -> Left (missing key)
  String _ -> case key of
    Int _ -> Left (pyError "IndexError" [PyStr "string index out of range"])
    Bool _ -> Left (pyError "IndexError" [PyStr "string index out of range"])
    _ -> Left (typeError ("string indices must be integers, not '" <> typeName key <> "'"))
  Array _ -> Left (typeError ("list indices must be integers or slices, not " <> typeName key))
  other -> Left (typeError ("'" <> typeName other <> "' object is not subscriptable"))
  where
    missing k = pyError "KeyError" [fromJson k]

hashable :: Json -> Py ()
hashable = \case
  Array _ -> Left (typeError "cannot use 'list' as a dict key (unhashable type: 'list')")
  Object _ -> Left (typeError "cannot use 'dict' as a dict key (unhashable type: 'dict')")
  _ -> Right ()

-- | @container.get(key)@: @None@ when absent.
get :: Json -> Text -> Py Json
get container key = getOr container key Null

-- | @container.get(key, default)@.
getOr :: Json -> Text -> Json -> Py Json
getOr container key fallback = Value.getOr key fallback container

-- | @key in container@ for a string key.
member :: Text -> Json -> Py Bool
member key = \case
  Object members -> Right (any ((== key) . fst) members)
  String s -> Right (key `T.isInfixOf` s)
  Array xs -> Right (String key `elem` xs)
  other -> Left (typeError ("argument of type '" <> typeName other <> "' is not a container or iterable"))

-- | A value used as a mapping (@{**value}@).
asObject :: Json -> Py [(Text, Json)]
asObject = \case
  Object members -> Right members
  other -> Left (typeError ("'" <> typeName other <> "' object is not a mapping"))

-- | @{**base, k1: v1, ...}@.
merge :: Json -> [(Text, Json)] -> Py Json
merge base updates = Object . (`overlay` updates) <$> asObject base

-- | @{**base, k1: v1, ...}@ of a dict's members.
overlay :: [(Text, a)] -> [(Text, a)] -> [(Text, a)]
overlay = foldl (\acc (k, v) -> insert k v acc)

-- | @d[k] = v@ on a Python dict: replace in place, or append.
insert :: Text -> a -> [(Text, a)] -> [(Text, a)]
insert k v members
  | any ((== k) . fst) members = [(k', if k' == k then v else v') | (k', v') <- members]
  | otherwise = members ++ [(k, v)]

-- | @{k: v for k, v in d.items() if k != key}@.
without :: Text -> [(Text, a)] -> [(Text, a)]
without key = filter ((/= key) . fst)

-- | @list(value)@ of a JSON-loaded value.
pyList :: Json -> Py [Json]
pyList = \case
  Array xs -> Right xs
  String s -> Right [String (T.singleton c) | c <- T.unpack s]
  Object members -> Right [String k | (k, _) <- members]
  other -> Left (typeError ("'" <> typeName other <> "' object is not iterable"))

-- | A rich comparison operator.
data CompareOp = Lt | Le | Gt | Ge
  deriving stock (Eq, Show)

opText :: CompareOp -> Text
opText = \case
  Lt -> "<"
  Le -> "<="
  Gt -> ">"
  Ge -> ">="

data Num' = Exact Integer | Inexact Double

numeric :: Json -> Maybe Num'
numeric = \case
  Bool b -> Just (Exact (if b then 1 else 0))
  Int i -> Just (Exact i)
  Float d -> Just (Inexact d)
  _ -> Nothing

-- | Python @<@-family comparison of two values.
compareValues :: CompareOp -> Json -> Json -> Py Bool
compareValues op left right = case (numeric left, numeric right) of
  (Just a, Just b) -> Right (numericCompare op a b)
  _ -> case (left, right) of
    (String a, String b) -> Right (ordered op (compare a b))
    (Array a, Array b) -> sequenceCompare op a b
    _ ->
      Left
        ( typeError
            ( "'" <> opText op <> "' not supported between instances of '" <> typeName left <> "' and '"
                <> typeName right
                <> "'"
            )
        )

ordered :: CompareOp -> Ordering -> Bool
ordered op o = case op of
  Lt -> o == LT
  Le -> o /= GT
  Gt -> o == GT
  Ge -> o /= LT

numericCompare :: CompareOp -> Num' -> Num' -> Bool
numericCompare op a b = case (a, b) of
  (Exact x, Exact y) -> ordered op (compare x y)
  (Inexact x, Inexact y) -> floatOp x y
  (Exact x, Inexact y) -> mixed x y False
  (Inexact x, Exact y) -> mixed y x True
  where
    floatOp x y
      | isNaN x || isNaN y = False
      | otherwise = ordered op (compare x y)
    -- an int against a float compares exactly, as CPython does
    mixed i d flipped
      | isNaN d = False
      | isInfinite d = ordered op (if flipped then (if d > 0 then GT else LT) else (if d > 0 then LT else GT))
      | otherwise =
          let o = compare (fromInteger i :: Rational) (toRational d)
           in ordered op (if flipped then invert o else o)
    invert = \case
      LT -> GT
      GT -> LT
      EQ -> EQ

-- | Lexicographic comparison of two sequences: the first unequal pair
-- decides with the operator; otherwise the lengths do.
sequenceCompare :: CompareOp -> [Json] -> [Json] -> Py Bool
sequenceCompare op = go
  where
    go (x : xs) (y : ys)
      | x == y = go xs ys
      | otherwise = compareValues op x y
    go xs ys = Right (ordered op (compare (length xs) (length ys)))

-- | Tuple comparison.
tupleCompare :: CompareOp -> [Json] -> [Json] -> Py Bool
tupleCompare = sequenceCompare

-- | @max(a, b)@ of two tuples: @b@ only when @b > a@.
pyMax2 :: [Json] -> [Json] -> Py [Json]
pyMax2 a b = do
  greater <- tupleCompare Gt b a
  Right (if greater then b else a)

-- | @str(value)@.
pyStr :: Json -> Text
pyStr = \case
  String s -> s
  other -> pyRepr other

-- | @repr(value)@.
pyRepr :: Json -> Text
pyRepr = Lit.repr . Lit.fromJson

-- | Construct a strict workflow value from its fields (a pydantic
-- dataclass constructor call): any field of the wrong type is a
-- @ValidationError@.
construct :: forall a. (Contract a) => [(Text, Json)] -> Py a
construct fields = either (const (Left validationError)) Right (validate @a (Object fields))

strictText :: Json -> Py Text
strictText = \case
  String s -> Right s
  _ -> Left validationError

strictInteger :: Json -> Py Integer
strictInteger = \case
  Int i -> Right i
  _ -> Left validationError

-- | A model's dump as the members of the @dict@ that holds it (a model
-- always dumps to an object).
--
-- The reference's @value.validated_update(**changes)@ (dump, patch the
-- members, revalidate) is record update here: revalidating a well-typed
-- record gives it back (@validate . dump == Right@, checked for every
-- contract by hamsterdan-contracts' RoundTripSpec), so the folds update
-- records with record syntax and the compiler checks each member's name
-- and type.
dumpObject :: (Contract a) => a -> [(Text, Json)]
dumpObject value = case dump value of
  Object members -> members
  _ -> []

-- | A literal value from its spelling (strict, as a constructor would).
unspell :: forall a. (Contract a) => Text -> Py a
unspell spelled = either (const (Left validationError)) Right (validate @a (String spelled))

-- | A tuple of strings as JSON.
texts :: [Text] -> Json
texts = Array . map String
