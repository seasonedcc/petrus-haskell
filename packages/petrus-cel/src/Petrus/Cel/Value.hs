-- | The runtime values of cel-python, modelled as the Python objects they
-- are.
--
-- cel-python evaluates CEL with ordinary Python objects: the @celtypes@
-- classes (@IntType@, @StringType@, @ListType@, ...), but also plain @int@,
-- @float@, @str@, @list@, @bytes@ and @timedelta@ values that leak out of
-- inherited arithmetic (@true + 2@ is a plain @int@), class and function
-- objects (an identifier such as @int@ or @size@ evaluates to the class or
-- function itself), the activation's name containers, and @CELEvalError@
-- exceptions used as values. Every observable result -- @repr@, truthiness,
-- which operation raises -- depends on which of these a value is, so each
-- has its own constructor here.
module Petrus.Cel.Value
  ( -- * Values
    Value (..)
  , Entries
  , NameContainer
  , Referent (..)
  , emptyReferent
  , referentValue
  , CelError (..)
  , celError
  , celErrorWith
    -- * Python classes
  , PyClass (..)
  , pyType
  , isSubclass
  , classRepr
  , className
  , classQualifiedName
    -- * Exceptions
  , Exc (..)
  , pyExc
  , fromPyErr
  , keyError
  , excRepr
  , excStr
  , excClassOf
  , excArgsRepr
  , excArg0
  , excToCelError
    -- * Object protocol basics
  , valueRepr
  , valueStr
  , truthy
  , HashKey (..)
  , hashKey
  , unhashable
    -- * Views
  , asInteger
  , asDouble
  , asText
  , asBytes
  , asList
  , asDict
  , asDelta
  , isDictLike
  , isMappingLike
  , containerEntries
    -- * Constructors
  , intType
  , uintType
  , checkInt64
  , checkUint64
  , durationType
  , notImplementedTypeError
  , jsonToCel
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Petrus.Cel.Python
import Petrus.Cel.Time
import Petrus.Json (Json (..))

-- | Ordered dictionary entries (Python dicts keep insertion order).
type Entries = [(Value, Value)]

-- | An activation scope: names to referents, in insertion order.
type NameContainer = [(Text, Referent)]

-- | cel-python's @Referent@: what a name in the activation refers to.
data Referent = Referent
  { referentAnnotation :: Maybe PyClass
  , referentContainer :: Maybe NameContainer
  , referentSetValue :: Maybe Value
  -- ^ @Just@ once a value is set (possibly @None@).
  }

-- | A fresh @Referent()@.
emptyReferent :: Referent
emptyReferent = Referent Nothing Nothing Nothing

-- | @Referent.value@: the container wins over a set value, which wins over
-- the annotation.
referentValue :: Referent -> Value
referentValue r = case (referentContainer r, referentSetValue r, referentAnnotation r) of
  (Just c, _, _) -> VContainer c
  (Nothing, Just v, _) -> v
  (Nothing, Nothing, Just cls) -> VClass cls
  (Nothing, Nothing, Nothing) -> VNone

-- | A @CELEvalError@: its three arguments (message, the wrapped exception's
-- class, and that exception's arguments) and the dump of the tree it was
-- raised at, if any.
data CelError = CelError
  { celErrorMessage :: Text
  , celErrorCause :: Text
  -- ^ @repr@ of the wrapped exception class, e.g. @<class 'TypeError'>@.
  , celErrorCauseArgs :: Text
  -- ^ @repr@ of the wrapped exception's @args@ (or @None@).
  , celErrorTree :: Maybe Text
  }

instance Eq CelError where
  a == b =
    (celErrorMessage a, celErrorCause a, celErrorCauseArgs a)
      == (celErrorMessage b, celErrorCause b, celErrorCauseArgs b)

-- | @CELEvalError(message, ex.__class__, ex.args, tree=...)@.
celError :: Text -> Exc -> Maybe Text -> CelError
celError message cause tree =
  CelError
    { celErrorMessage = message
    , celErrorCause = excClassRepr' cause
    , celErrorCauseArgs = excArgsRepr cause
    , celErrorTree = tree
    }
  where
    excClassRepr' = \case
      PyExc cls _ _ -> excClassRepr cls
      CelExc _ -> classRepr CCELEvalError

-- | @CELEvalError(message, cls, args)@ with an explicit cause class and the
-- @repr@ of its arguments (cel-python passes @None@ for some).
celErrorWith :: Text -> ExcClass -> Text -> Maybe Text -> CelError
celErrorWith message cls args tree =
  CelError
    { celErrorMessage = message
    , celErrorCause = excClassRepr cls
    , celErrorCauseArgs = args
    , celErrorTree = tree
    }

-- | A Python object as cel-python can produce it.
data Value
  = VNone
  | -- | @BoolType@ (an @int@ subclass: @bool('2')@ holds 2 and prints as True)
    VBool Integer
  | VInt Integer
  | VUint Integer
  | VDouble Double
  | VString Text
  | VBytes ByteString
  | VList [Value]
  | VMap Entries
  | VMessage Entries
  | VTimestamp Datetime
  | VDuration Timedelta
  | -- | plain @int@
    PInt Integer
  | -- | plain @float@
    PFloat Double
  | -- | plain @str@
    PStr Text
  | -- | plain @bytes@
    PBytes ByteString
  | -- | plain @list@
    PList [Value]
  | -- | plain @datetime.timedelta@
    PTimedelta Timedelta
  | -- | a class object
    VClass PyClass
  | -- | a Python function from the functions table, by @__name__@
    VFunction Text
  | VContainer NameContainer
  | VReferent Referent
  | VError CelError

-- | The Python classes values can have.
data PyClass
  = CNoneType
  | CInt
  | CFloat
  | CStr
  | CBytes
  | CList
  | CDict
  | CTimedelta
  | CDatetime
  | CType
  | CFunction
  | CBoolType
  | CIntType
  | CUintType
  | CDoubleType
  | CStringType
  | CBytesType
  | CListType
  | CMapType
  | CMessageType
  | CTimestampType
  | CDurationType
  | CTypeType
  | CNameContainer
  | CReferent
  | CCELEvalError
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Python's @type(value)@.
pyType :: Value -> PyClass
pyType = \case
  VNone -> CNoneType
  VBool _ -> CBoolType
  VInt _ -> CIntType
  VUint _ -> CUintType
  VDouble _ -> CDoubleType
  VString _ -> CStringType
  VBytes _ -> CBytesType
  VList _ -> CListType
  VMap _ -> CMapType
  VMessage _ -> CMessageType
  VTimestamp _ -> CTimestampType
  VDuration _ -> CDurationType
  PInt _ -> CInt
  PFloat _ -> CFloat
  PStr _ -> CStr
  PBytes _ -> CBytes
  PList _ -> CList
  PTimedelta _ -> CTimedelta
  VClass _ -> CType
  VFunction _ -> CFunction
  VContainer _ -> CNameContainer
  VReferent _ -> CReferent
  VError _ -> CCELEvalError

parentClass :: PyClass -> Maybe PyClass
parentClass = \case
  CBoolType -> Just CInt
  CIntType -> Just CInt
  CUintType -> Just CInt
  CDoubleType -> Just CFloat
  CStringType -> Just CStr
  CBytesType -> Just CBytes
  CListType -> Just CList
  CMapType -> Just CDict
  CMessageType -> Just CMapType
  CTimestampType -> Just CDatetime
  CDurationType -> Just CTimedelta
  CTypeType -> Just CType
  CNameContainer -> Just CDict
  _ -> Nothing

-- | @issubclass(a, b)@.
isSubclass :: PyClass -> PyClass -> Bool
isSubclass a b = a == b || maybe False (`isSubclass` b) (parentClass a)

-- | The class's @__name__@ (CPython's @tp_name@ for builtins).
className :: PyClass -> Text
className = \case
  CNoneType -> "NoneType"
  CInt -> "int"
  CFloat -> "float"
  CStr -> "str"
  CBytes -> "bytes"
  CList -> "list"
  CDict -> "dict"
  CTimedelta -> "datetime.timedelta"
  CDatetime -> "datetime.datetime"
  CType -> "type"
  CFunction -> "function"
  CBoolType -> "BoolType"
  CIntType -> "IntType"
  CUintType -> "UintType"
  CDoubleType -> "DoubleType"
  CStringType -> "StringType"
  CBytesType -> "BytesType"
  CListType -> "ListType"
  CMapType -> "MapType"
  CMessageType -> "MessageType"
  CTimestampType -> "TimestampType"
  CDurationType -> "DurationType"
  CTypeType -> "TypeType"
  CNameContainer -> "NameContainer"
  CReferent -> "Referent"
  CCELEvalError -> "CELEvalError"

-- | The module-qualified name (@celpy.celtypes.IntType@, @int@).
classQualifiedName :: PyClass -> Text
classQualifiedName cls
  | cls `elem` [CNameContainer, CReferent, CCELEvalError] = "celpy.evaluation." <> className cls
  | cls >= CBoolType = "celpy.celtypes." <> className cls
  | otherwise = className cls

-- | @repr(cls)@: @<class 'celpy.celtypes.IntType'>@.
classRepr :: PyClass -> Text
classRepr cls = "<class '" <> classQualifiedName cls <> "'>"

-- ---------------------------------------------------------------------------
-- Exceptions

-- | A raised Python exception.
data Exc
  = -- | class, @str(exc)@, and the @repr@ of each argument
    PyExc ExcClass Text [Text]
  | -- | a raised @CELEvalError@
    CelExc CelError

-- | An exception with a single string argument.
pyExc :: ExcClass -> Text -> Exc
pyExc cls message = PyExc cls message [argRepr]
  where
    argRepr = case cls of
      Re2Error -> bytesRepr' message
      _ -> strRepr message
    bytesRepr' = bytesRepr . TE.encodeUtf8

-- | Lift the time module's exceptions.
fromPyErr :: PyErr -> Exc
fromPyErr (PyErr cls message) = pyExc cls message

-- | @KeyError(key)@.
keyError :: Value -> Exc
keyError key = PyExc KeyError (valueRepr key) [valueRepr key]

-- | The exception's class name.
excClassOf :: Exc -> Maybe ExcClass
excClassOf = \case
  PyExc cls _ _ -> Just cls
  CelExc _ -> Nothing

-- | @repr(exc)@.
excRepr :: Exc -> Text
excRepr = \case
  PyExc cls _ args -> excClassName cls <> "(" <> T.intercalate ", " args <> ")"
  CelExc e -> valueRepr (VError e)

-- | @str(exc)@.
excStr :: Exc -> Text
excStr = \case
  PyExc _ message _ -> message
  CelExc e -> celErrorArgsRepr e

-- | @repr(exc.args)@.
excArgsRepr :: Exc -> Text
excArgsRepr = \case
  PyExc _ _ args -> tupleRepr args
  CelExc e -> celErrorArgsRepr e

-- | @exc.args[0]@ as text (cel-python only ever reads string arguments).
excArg0 :: Exc -> Text
excArg0 = \case
  PyExc _ message _ -> message
  CelExc e -> celErrorMessage e

-- | Wrap a caught exception as @CELEvalError(message, ex.__class__, ex.args)@.
excToCelError :: Text -> Maybe Text -> Exc -> CelError
excToCelError message tree ex = celError message ex tree

tupleRepr :: [Text] -> Text
tupleRepr = \case
  [] -> "()"
  [x] -> "(" <> x <> ",)"
  xs -> "(" <> T.intercalate ", " xs <> ")"

celErrorArgsRepr :: CelError -> Text
celErrorArgsRepr e = tupleRepr [strRepr (celErrorMessage e), celErrorCause e, celErrorCauseArgs e]

-- ---------------------------------------------------------------------------
-- repr / str / bool

-- | Python's @repr()@ (function addresses omitted, as the corpus normalises
-- them).
valueRepr :: Value -> Text
valueRepr = \case
  VNone -> "None"
  VBool n -> "BoolType(" <> (if n /= 0 then "True" else "False") <> ")"
  VInt n -> "IntType(" <> showT n <> ")"
  VUint n -> "UintType(" <> showT n <> ")"
  VDouble d -> "DoubleType(" <> floatRepr d <> ")"
  VString t -> "StringType(" <> strRepr t <> ")"
  VBytes b -> "BytesType(" <> bytesRepr b <> ")"
  VList xs -> "ListType(" <> listRepr xs <> ")"
  VMap kvs -> "MapType(" <> dictRepr kvs <> ")"
  VMessage kvs -> "MessageType(" <> dictRepr kvs <> ")"
  VTimestamp dt -> "TimestampType(" <> strRepr (datetimeStr dt) <> ")"
  VDuration td -> "DurationType(" <> strRepr (durationStr td) <> ")"
  PInt n -> showT n
  PFloat d -> floatRepr d
  PStr t -> strRepr t
  PBytes b -> bytesRepr b
  PList xs -> listRepr xs
  PTimedelta td -> timedeltaRepr td
  VClass cls -> classRepr cls
  VFunction name -> "<function " <> name <> ">"
  VContainer c -> containerRepr c
  VReferent r -> referentRepr r
  VError e ->
    "CELEvalError(*"
      <> celErrorArgsRepr e
      <> maybe "" (\t -> ", tree=" <> strRepr t) (celErrorTree e)
      <> ")"
  where
    listRepr xs = "[" <> T.intercalate ", " (map valueRepr xs) <> "]"

dictRepr :: Entries -> Text
dictRepr kvs = "{" <> T.intercalate ", " [valueRepr k <> ": " <> valueRepr v | (k, v) <- kvs] <> "}"

containerRepr :: NameContainer -> Text
containerRepr c = "NameContainer(" <> dictRepr [(PStr k, VReferent r) | (k, r) <- c] <> ", parent=None)"

referentRepr :: Referent -> Text
referentRepr r =
  "Referent(annotation="
    <> maybe "None" classRepr (referentAnnotation r)
    <> ", container="
    <> maybe "None" containerRepr (referentContainer r)
    <> ", _value="
    <> maybe "None" valueRepr (referentSetValue r)
    <> ")"

showT :: (Show a) => a -> Text
showT = T.pack . show

durationStr :: Timedelta -> Text
durationStr td = showT (truncate (timedeltaTotalSeconds td) :: Integer) <> "s"

-- | Python's @str()@.
valueStr :: Value -> Text
valueStr = \case
  VBool n -> if n /= 0 then "True" else "False"
  VInt n -> showT n
  VUint n -> showT n
  VDouble d -> floatRepr d
  VString t -> t
  VTimestamp dt -> datetimeStr dt
  VDuration td -> durationStr td
  PInt n -> showT n
  PFloat d -> floatRepr d
  PStr t -> t
  PTimedelta td -> timedeltaStr td
  VError e -> celErrorArgsRepr e
  v -> valueRepr v

-- | @str(timedelta)@: @[D day[s], ]H:MM:SS[.UUUUUU]@.
timedeltaStr :: Timedelta -> Text
timedeltaStr (Timedelta micros) =
  let (days, rest) = micros `divMod` 86400000000
      (secs, us) = rest `divMod` 1000000
      (h, r2) = secs `divMod` 3600
      (m, s) = r2 `divMod` 60
      pad v = T.justifyRight 2 '0' (showT v)
      dayPart
        | days == 0 = ""
        | otherwise = showT days <> (if abs days == 1 then " day, " else " days, ")
      usPart = if us == 0 then "" else "." <> T.justifyRight 6 '0' (showT us)
   in dayPart <> showT h <> ":" <> pad m <> ":" <> pad s <> usPart

-- | Python's @bool()@.
truthy :: Value -> Bool
truthy = \case
  VNone -> False
  VBool n -> n /= 0
  VInt n -> n /= 0
  VUint n -> n /= 0
  VDouble d -> d /= 0
  VString t -> not (T.null t)
  VBytes b -> b /= mempty
  VList xs -> not (null xs)
  VMap kvs -> not (null kvs)
  VMessage kvs -> not (null kvs)
  VTimestamp _ -> True
  VDuration (Timedelta us) -> us /= 0
  PInt n -> n /= 0
  PFloat d -> d /= 0
  PStr t -> not (T.null t)
  PBytes b -> b /= mempty
  PList xs -> not (null xs)
  PTimedelta (Timedelta us) -> us /= 0
  VClass _ -> True
  VFunction _ -> True
  VContainer c -> not (null c)
  VReferent _ -> True
  VError _ -> True

-- ---------------------------------------------------------------------------
-- Hashing

-- | The equivalence class of Python's @hash()@ that decides which dictionary
-- keys are ever compared.
data HashKey
  = HashNumber Integer
  | HashText Text
  | HashBytes ByteString
  | HashNone
  | HashDatetime Integer
  | HashDelta Integer
  | HashClass PyClass
  | HashFunction Text
  | -- | NaN hashes by identity: equal to nothing else.
    HashUnique
  deriving stock (Eq)

-- | @hash(value)@, or 'Nothing' for unhashable objects.
hashKey :: Value -> Maybe HashKey
hashKey = \case
  VNone -> Just HashNone
  VBool n -> Just (HashNumber (hashInteger n))
  VInt n -> Just (HashNumber (hashInteger n))
  VUint n -> Just (HashNumber (hashInteger n))
  PInt n -> Just (HashNumber (hashInteger n))
  VDouble d -> Just (maybe HashUnique HashNumber (hashDouble d))
  PFloat d -> Just (maybe HashUnique HashNumber (hashDouble d))
  VString t -> Just (HashText t)
  PStr t -> Just (HashText t)
  VBytes b -> Just (HashBytes b)
  PBytes b -> Just (HashBytes b)
  VTimestamp dt -> Just (HashDatetime (datetimeUtcMicros dt))
  VDuration (Timedelta us) -> Just (HashDelta us)
  PTimedelta (Timedelta us) -> Just (HashDelta us)
  VClass cls -> Just (HashClass cls)
  VFunction name -> Just (HashFunction name)
  _ -> Nothing

-- | The @TypeError@ for using an unhashable object as a dict key.
unhashable :: Value -> Exc
unhashable v =
  let cls = pyType v
   in pyExc
        TypeError
        ("cannot use '" <> classQualifiedName cls <> "' as a dict key (unhashable type: '" <> className cls <> "')")

-- ---------------------------------------------------------------------------
-- Views

-- | An @int@ (or subclass) value.
asInteger :: Value -> Maybe Integer
asInteger = \case
  VBool n -> Just n
  VInt n -> Just n
  VUint n -> Just n
  PInt n -> Just n
  _ -> Nothing

-- | A @float@ (or subclass) value.
asDouble :: Value -> Maybe Double
asDouble = \case
  VDouble d -> Just d
  PFloat d -> Just d
  _ -> Nothing

-- | A @str@ (or subclass) value.
asText :: Value -> Maybe Text
asText = \case
  VString t -> Just t
  PStr t -> Just t
  _ -> Nothing

-- | A @bytes@ (or subclass) value.
asBytes :: Value -> Maybe ByteString
asBytes = \case
  VBytes b -> Just b
  PBytes b -> Just b
  _ -> Nothing

-- | A @list@ (or subclass) value.
asList :: Value -> Maybe [Value]
asList = \case
  VList xs -> Just xs
  PList xs -> Just xs
  _ -> Nothing

-- | A @dict@ (or subclass) value's entries.
asDict :: Value -> Maybe Entries
asDict = \case
  VMap kvs -> Just kvs
  VMessage kvs -> Just kvs
  VContainer c -> Just (containerEntries c)
  _ -> Nothing

-- | A @timedelta@ (or subclass) value.
asDelta :: Value -> Maybe Timedelta
asDelta = \case
  VDuration td -> Just td
  PTimedelta td -> Just td
  _ -> Nothing

-- | Is the value a @dict@ (or subclass)?
isDictLike :: Value -> Bool
isDictLike v = case asDict v of
  Just _ -> True
  Nothing -> False

-- | @PyMapping_Check@ (has @__getitem__@): lists, dicts, str and bytes.
isMappingLike :: Value -> Bool
isMappingLike v = case v of
  VList _ -> True
  PList _ -> True
  VBytes _ -> True
  PBytes _ -> True
  VString _ -> True
  PStr _ -> True
  _ -> isDictLike v

-- | A name container's entries as a dict's (plain @str@ keys, @Referent@
-- values).
containerEntries :: NameContainer -> Entries
containerEntries c = [(PStr k, VReferent r) | (k, r) <- c]

-- ---------------------------------------------------------------------------
-- Constructors

-- | The @int64@ range check of @IntType@.
checkInt64 :: Integer -> Either Exc Integer
checkInt64 n
  | n >= -(2 ^ (63 :: Int)) && n < 2 ^ (63 :: Int) = Right n
  | otherwise = Left (pyExc ValueError "overflow")

-- | The @uint64@ range check of @UintType@.
checkUint64 :: Integer -> Either Exc Integer
checkUint64 n
  | n >= 0 && n < 2 ^ (64 :: Int) = Right n
  | otherwise = Left (pyExc ValueError "overflow")

-- | @int(NotImplemented)@'s error, which celtypes arithmetic raises whenever
-- an inherited @int@ operation declines its operand.
notImplementedTypeError :: Exc
notImplementedTypeError =
  pyExc TypeError "int() argument must be a string, a bytes-like object or a real number, not 'NotImplementedType'"

-- | @IntType(result)@ of an inherited @int@ operation ('Nothing' is
-- @NotImplemented@).
intType :: Maybe Value -> Either Exc Value
intType = \case
  Just (PInt n) -> VInt <$> checkInt64 n
  _ -> Left notImplementedTypeError

-- | @UintType(result)@ of an inherited @int@ operation.
uintType :: Maybe Value -> Either Exc Value
uintType = \case
  Just (PInt n) -> VUint <$> checkUint64 n
  _ -> Left notImplementedTypeError

-- | @DurationType(timedelta)@ with its range check (whose message is a
-- literal, un-interpolated @{seconds}@).
durationType :: Timedelta -> Either Exc Value
durationType td
  | abs (timedeltaTotalSeconds td) <= fromIntegral maxDurationSeconds = Right (VDuration td)
  | otherwise = Left (pyExc ValueError "range error: {seconds}")

-- | @celpy.json_to_cel@.
jsonToCel :: Json -> Either Exc Value
jsonToCel = \case
  Null -> Right VNone
  Bool b -> Right (VBool (if b then 1 else 0))
  Int n -> VInt <$> checkInt64 n
  Float d -> Right (VDouble d)
  String t -> Right (VString t)
  Array xs -> VList <$> traverse jsonToCel xs
  Object kvs -> VMap <$> traverse (\(k, v) -> (,) (VString k) <$> jsonToCel v) kvs
