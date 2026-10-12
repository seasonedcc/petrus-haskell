-- | Bidirectional codecs that reproduce pydantic's strict, frozen,
-- @extra="forbid"@ dataclasses over CPython-compatible JSON.
--
-- Hamsterdan's contracts are pydantic dataclasses. Their wire spelling is
-- @TypeAdapter(T).dump_python(value, mode="json")@: every field present
-- (defaults included), in declaration order, tuples as arrays, @None@ as
-- @null@. Their admission is @TypeAdapter(T).validate_json@ in strict mode:
-- exact JSON types (no int/float/bool/str coercion), unknown members refused,
-- missing members refused unless the field has a default.
--
-- A 'Codec' pairs an encoder and a decoder that are built from the same field
-- list, so encode order and decode admission can never drift apart.
module Hamsterdan.Contracts.Codec
  ( -- * Codecs
    Codec (..)
  , encode
  , decode
  , DecodeError (..)
  , renderDecodeError

    -- * Records
  , ObjectCodec
  , record
  , recordWith
  , member
  , memberConst
  , field
  , fieldDefault
  , constField
  , constFieldDefault

    -- * Scalars and containers
  , text
  , integer
  , bool
  , anyJson
  , object
  , list
  , dict
  , nullable
  , literalInteger
  , Enumeration (..)
  , enumeration
  , unspelling
  , union
  , mapCodec
  , refine
  , leaf
  , normalizing
  , finiteJson
  , pythonDict
  , pairOrEmpty

    -- * Contracts
  , Contract (..)
  , colorOf
  , dump
  , validate
  , validateJson
  , Model (..)
  , modelOf

    -- * Re-exports
  , Object
  ) where

import Data.ByteString (ByteString)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..), parseJson, surrogateRefusingLoads)

-- | A JSON object's members in order.
type Object = [(Text, Json)]

-- | Why a value was refused, with the JSON path that refused it.
data DecodeError = DecodeError
  { errorPath :: [Text]
  , errorReason :: Text
  }
  deriving stock (Eq, Show)

-- | @path: reason@, with @$@ for the root.
renderDecodeError :: DecodeError -> Text
renderDecodeError (DecodeError path reason) =
  (if null path then "$" else T.intercalate "." path) <> ": " <> reason

-- | A named, bidirectional codec.
data Codec a = Codec
  { codecName :: Text
  -- ^ The pydantic type name (the token color for a model).
  , codecFields :: [Text]
  -- ^ A record's JSON member names in declaration order (empty otherwise).
  , encoder :: a -> Json
  , decoder :: Json -> Either DecodeError a
  }

-- | A codec that is not a record.
leaf :: Text -> (a -> Json) -> (Json -> Either DecodeError a) -> Codec a
leaf name = Codec name []

-- | Encode a value.
encode :: Codec a -> a -> Json
encode = encoder

-- | Decode a value.
decode :: Codec a -> Json -> Either DecodeError a
decode = decoder

failAt :: Text -> Either DecodeError a
failAt reason = Left (DecodeError [] reason)

within :: Text -> Either DecodeError a -> Either DecodeError a
within segment = either (\(DecodeError path reason) -> Left (DecodeError (segment : path) reason)) Right

-- | The members of a record, in declaration order, for both directions.
data ObjectCodec r a = ObjectCodec
  { declared :: [Text] -> [Text]
  , encodeMembers :: r -> Object -> Object
  , decodeMembers :: Map.Map Text Json -> Either DecodeError a
  }

instance Functor (ObjectCodec r) where
  fmap f codec = codec {decodeMembers = fmap f . decodeMembers codec}

instance Applicative (ObjectCodec r) where
  pure value = ObjectCodec id (const id) (const (Right value))
  left <*> right =
    ObjectCodec
      { declared = declared left . declared right
      , encodeMembers = \value -> encodeMembers left value . encodeMembers right value
      , decodeMembers = \members -> decodeMembers left members <*> decodeMembers right members
      }

-- | Decode one member's value (for a positional decoder; see 'recordWith').
member :: Text -> Codec a -> Json -> Either DecodeError a
member name codec value = within name (decoder codec value)
{-# INLINE member #-}

-- | Check one single-valued @Literal[...]@ member's value (for a positional
-- decoder; see 'recordWith').
memberConst :: Text -> Json -> Json -> Either DecodeError ()
memberConst name expected value = within name (literal expected value)
{-# INLINE memberConst #-}

-- | A required member.
field :: Text -> (r -> a) -> Codec a -> ObjectCodec r a
field name getter codec =
  ObjectCodec
    { declared = (name :)
    , encodeMembers = \value -> ((name, encoder codec (getter value)) :)
    , decodeMembers = \members -> case Map.lookup name members of
        Nothing -> Left (DecodeError [name] "field required")
        Just value -> within name (decoder codec value)
    }

-- | A member with a default used when the member is absent.
fieldDefault :: Text -> (r -> a) -> a -> Codec a -> ObjectCodec r a
fieldDefault name getter fallback codec =
  ObjectCodec
    { declared = (name :)
    , encodeMembers = \value -> ((name, encoder codec (getter value)) :)
    , decodeMembers = \members -> case Map.lookup name members of
        Nothing -> Right fallback
        Just value -> within name (decoder codec value)
    }

-- | A required @Literal[...]@ member with a single admitted value. It
-- carries no information, so it has no Haskell field.
constField :: Text -> Json -> ObjectCodec r ()
constField name expected =
  ObjectCodec
    { declared = (name :)
    , encodeMembers = const ((name, expected) :)
    , decodeMembers = \members -> case Map.lookup name members of
        Nothing -> Left (DecodeError [name] "field required")
        Just value -> within name (literal expected value)
    }

-- | A single-valued @Literal[...]@ member whose default is that value.
constFieldDefault :: Text -> Json -> ObjectCodec r ()
constFieldDefault name expected =
  ObjectCodec
    { declared = (name :)
    , encodeMembers = const ((name, expected) :)
    , decodeMembers = \members -> case Map.lookup name members of
        Nothing -> Right ()
        Just value -> within name (literal expected value)
    }

literal :: Json -> Json -> Either DecodeError ()
literal expected actual
  | sameLiteral expected actual = Right ()
  | otherwise = failAt "input should be the literal value"
  where
    -- pydantic matches a literal by Python equality: Literal[0] admits
    -- false, 0.0, and -0.0 even in strict mode; string literals admit only
    -- the exact string.
    sameLiteral (String a) (String b) = a == b
    sameLiteral (Int a) (Int b) = a == b
    sameLiteral (Int a) (Bool b) = a == (if b then 1 else 0)
    sameLiteral (Int a) (Float b) = not (isNaN b || isInfinite b) && toRational b == fromInteger a
    sameLiteral _ _ = False

-- | A strict, @extra="forbid"@ record named after its pydantic class.
record :: Text -> ObjectCodec a a -> Codec a
record name = recordWith name (const Nothing)

-- | 'record' with a positional fast path: when the input's members are
-- exactly the declared ones in declaration order (always the case for a
-- pydantic dump), the positional decoder reads their values directly,
-- without building a lookup table. It must decode the same members, in the
-- same order, with the same codecs as the 'ObjectCodec' (the generator emits
-- both from one field list); it answers 'Nothing' only for an arity it does
-- not handle, which falls back to the general path.
recordWith :: Text -> (Object -> Maybe (Either DecodeError a)) -> ObjectCodec a a -> Codec a
recordWith name positional members =
  Codec
    { codecName = name
    , codecFields = names
    , encoder = \value -> Object (encodeMembers members value [])
    , decoder = \case
        Object input
          | inDeclaredOrder names input, Just decoded <- positional input -> decoded
          | otherwise -> do
              let keyed = Map.fromList input
              case find (\(key, _) -> not (Set.member key known)) input of
                Just (key, _) -> Left (DecodeError [key] "extra inputs are not permitted")
                Nothing -> decodeMembers members keyed
        _ -> failAt ("input should be an object for " <> name)
    }
  where
    names = declared members []
    known = Set.fromList names
    inDeclaredOrder (expected : others) ((key, _) : rest) = expected == key && inDeclaredOrder others rest
    inDeclaredOrder [] [] = True
    inDeclaredOrder _ _ = False

-- | A strict @str@.
text :: Codec Text
text = leaf "str" String $ \case
  String value -> Right value
  _ -> failAt "input should be a valid string"

-- | A strict @int@: JSON integers only (never booleans or floats).
integer :: Codec Integer
integer = leaf "int" Int $ \case
  Int value -> Right value
  _ -> failAt "input should be a valid integer"

-- | A strict @bool@.
bool :: Codec Bool
bool = leaf "bool" Bool $ \case
  Bool value -> Right value
  _ -> failAt "input should be a valid boolean"

-- | @Any@: every JSON value, kept as is. Dumping spells a non-finite float
-- as @null@ (pydantic's @ser_json_inf_nan="null"@); the decoded value keeps
-- it, as the Python object does.
anyJson :: Codec Json
anyJson = leaf "Any" finiteJson Right

-- | @dict[str, Any]@ (and bare @dict@): an object, member order kept, each
-- key once (at its first position, with its last value, as a Python dict).
object :: Codec Object
object = leaf "dict" (finiteJson . Object) $ \case
  Object members -> Right (pythonDict members)
  _ -> failAt "input should be a valid dictionary"

-- | pydantic's JSON-mode dump of an untyped value: non-finite floats become
-- @null@.
finiteJson :: Json -> Json
finiteJson = \case
  Float value | isNaN value || isInfinite value -> Null
  Array values -> Array (map finiteJson values)
  Object members -> Object [(key, finiteJson value) | (key, value) <- members]
  value -> value

-- | The members a Python @dict@ built from these pairs holds.
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

-- | @list[T]@ and @tuple[T, ...]@ (JSON arrays in both cases).
list :: Codec a -> Codec [a]
list item = leaf ("list[" <> codecName item <> "]") (Array . map (encoder item)) $ \case
  Array values -> traverse (\(index, value) -> within (T.pack (show index)) (decoder item value)) (zip [(0 :: Int) ..] values)
  _ -> failAt "input should be a valid list"

-- | @dict[str, T]@, member order kept.
dict :: Codec a -> Codec [(Text, a)]
dict item =
  leaf
    ("dict[str, " <> codecName item <> "]")
    (\members -> Object [(key, encoder item value) | (key, value) <- members])
    $ \case
      Object members -> traverse (\(key, value) -> (key,) <$> within key (decoder item value)) (pythonDict members)
      _ -> failAt "input should be a valid dictionary"

-- | @T | None@.
nullable :: Codec a -> Codec (Maybe a)
nullable inner = leaf (codecName inner <> " | None") (maybe Null (encoder inner)) $ \case
  Null -> Right Nothing
  value -> Just <$> decoder inner value

-- | @Literal[n]@ for one integer.
literalInteger :: Integer -> Codec ()
literalInteger expected = leaf "Literal" (const (Int expected)) (literal (Int expected))

-- | A string @Literal[...]@ as a Haskell enumeration: every constructor has
-- exactly one wire spelling.
class (Bounded a, Enum a) => Enumeration a where
  spelling :: a -> Text

-- | The codec of an 'Enumeration' under its pydantic name: only the
-- spellings are admitted.
enumeration :: forall a. (Enumeration a) => Text -> Codec a
enumeration name =
  Codec
    { codecName = name
    , codecFields = []
    , encoder = String . spelling
    , decoder = \case
        String spelled | Just value <- Map.lookup spelled table -> Right value
        _ -> failAt ("input should be one of " <> T.intercalate ", " (Map.keys table))
    }
  where
    table = spellings @a

-- | Every member by its spelling.
spellings :: (Enumeration a) => Map.Map Text a
spellings = Map.fromList [(spelling value, value) | value <- [minBound .. maxBound]]

-- | The member the text spells, if any.
unspelling :: (Enumeration a) => Text -> Maybe a
unspelling spelled = Map.lookup spelled spellings

-- | A pydantic smart-mode union of disjoint members: the first member that
-- admits the input wins; encoding dispatches on the Haskell constructor.
union :: Text -> (a -> Json) -> [Json -> Either DecodeError a] -> Codec a
union name encodeWith alternatives = leaf name encodeWith $ \value ->
  case [decoded | Right decoded <- map ($ value) alternatives] of
    decoded : _ -> Right decoded
    [] -> failAt ("input does not match any member of " <> name)

-- | Change a codec's Haskell type with a total isomorphism.
mapCodec :: (a -> b) -> (b -> a) -> Codec a -> Codec b
mapCodec to from codec = codec {encoder = encoder codec . from, decoder = fmap to . decoder codec}

-- | Post-validate (pydantic @__post_init__@) after decoding.
refine :: (a -> Either Text a) -> Codec a -> Codec a
refine check codec = codec {decoder = \value -> decoder codec value >>= either failAt Right . check}

-- | Normalize after decoding and before encoding, so a value that violates a
-- pydantic @__post_init__@ rewrite can never be spelled.
normalizing :: (a -> a) -> Codec a -> Codec a
normalizing settle codec =
  codec {encoder = encoder codec . settle, decoder = fmap settle . decoder codec}

-- | @tuple[int, int] | tuple[()]@: a pair, or the empty tuple.
pairOrEmpty :: Codec (Maybe (Integer, Integer))
pairOrEmpty = leaf "tuple[int, int] | tuple[()]" spell $ \case
  Array [] -> Right Nothing
  Array [Int first, Int second] -> Right (Just (first, second))
  _ -> failAt "input should be a pair of integers or an empty tuple"
  where
    spell = \case
      Nothing -> Array []
      Just (first, second) -> Array [Int first, Int second]

-- | A value with a pydantic @TypeAdapter@: a dataclass model, a @Literal@
-- enumeration, or a union of models.
class Contract a where
  contract :: Codec a

-- | The token color of a model: its pydantic class name.
colorOf :: forall a. (Contract a) => a -> Text
colorOf _ = codecName (contract @a)

-- | @TypeAdapter(T).dump_python(value, mode="json")@.
dump :: (Contract a) => a -> Json
dump = encoder contract

-- | Strict admission of an already-parsed JSON value.
validate :: (Contract a) => Json -> Either DecodeError a
validate = decoder contract

-- | @TypeAdapter(T).validate_json(bytes)@ in strict mode. pydantic's JSON
-- parser (jiter) refuses a lone surrogate escape, so this one does too.
validateJson :: (Contract a) => ByteString -> Either DecodeError a
validateJson bytes = case parseJson surrogateRefusingLoads bytes of
  Left problem -> Left (DecodeError [] ("invalid JSON: " <> T.pack problem))
  Right value -> validate value

-- | A model with its type erased, for differential tests and registries.
data Model = Model
  { modelName :: Text
  , modelFields :: [Text]
  , modelRoundTrip :: Json -> Either DecodeError Json
  -- ^ Validate, then dump.
  }

-- | Erase a model's type.
modelOf :: Codec a -> Model
modelOf codec = Model (codecName codec) (codecFields codec) (fmap (encoder codec) . decoder codec)
