-- | Validation of a parsed document into a 'FlatNetFile', reproducing
-- pydantic 2.13 (pydantic-core 2.46) lax-mode validation of the
-- @FlatNetFile@ model: the same coercions, the same errors in the same
-- order at the same locations, the same @ValidationError@ text, and the
-- same exceptions escaping validation (the @TypeError@ a @NetPath@
-- validator raises, the @OverflowError@ of an out-of-range @timedelta@).
--
-- 'JsonMode' is @model_validate_json@ (input from "Petrus.EngineFile.Jiter")
-- and 'PythonMode' is @model_validate@ on the objects @json.loads@ builds
-- (input from "Petrus.EngineFile.PyJson"); they differ in a few coercions
-- and in message wording.
module Petrus.EngineFile.Validate
  ( Mode (..)
  , PyException (..)
  , LocItem (..)
  , ErrorKind (..)
  , LineError (..)
  , validateFile
  , validationError
  , renderLineErrors
  , truncateRepr
  , coerceNetPath
  , newNetPath
  ) where

import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.EngineFile.Duration
import Petrus.EngineFile.Number (IntParse (..), strAsFloat, strAsInt)
import Petrus.EngineFile.Types
import Petrus.EngineFile.Value

-- | Which pydantic entry point is validating.
data Mode = JsonMode | PythonMode
  deriving stock (Eq, Show)

-- | An exception the reference raises: its class name and @str()@.
data PyException = PyException
  { exceptionClass :: Text
  , message :: Text
  }
  deriving stock (Eq, Show)

-- | A location item: a field or dict key, or a list index.
data LocItem = LocKey Text | LocIndex Int
  deriving stock (Eq, Show)

-- | The pydantic error types validation can produce.
data ErrorKind
  = Missing
  | ModelType Text
  | DictType
  | ListType
  | TupleType
  | StringType
  | IntType
  | IntParsing
  | IntFromFloat
  | IntParsingSize
  | FiniteNumber
  | FloatType
  | FloatParsing
  | TimeDeltaType
  | TimeDeltaParsing Text
  | EnumError
  | LiteralError
  | ValueErrorKind Text
  | TooLong Int Int
  | JsonInvalid Text
  deriving stock (Eq, Show)

-- | One line of a @ValidationError@: location (outermost first), error,
-- and the input it was raised for.
data LineError = LineError
  { loc :: [LocItem]
  , kind :: ErrorKind
  , input :: Value
  }
  deriving stock (Show)

-- Validation results ------------------------------------------------------------

data V a = Ok a | Errs [LineError] | Exc PyException

instance Functor V where
  fmap f = \case
    Ok a -> Ok (f a)
    Errs es -> Errs es
    Exc e -> Exc e

instance Applicative V where
  pure = Ok
  vf <*> va = case vf of
    Exc e -> Exc e
    Ok f -> fmap f va
    Errs es -> case va of
      Exc e -> Exc e
      Ok _ -> Errs es
      Errs es' -> Errs (es ++ es')

failWith :: ErrorKind -> Value -> V a
failWith k v = Errs [LineError [] k v]

at :: LocItem -> V a -> V a
at item = \case
  Errs es -> Errs [e {loc = item : e.loc} | e <- es]
  other -> other

andThen :: V a -> (a -> V b) -> V b
andThen v f = case v of
  Ok a -> f a
  Errs es -> Errs es
  Exc e -> Exc e

-- Scalars -------------------------------------------------------------------------

vStr :: Value -> V Text
vStr = \case
  VStr s -> Ok s
  v -> failWith StringType v

vInt :: Value -> V Integer
vInt v = case v of
  VInt i _ -> Ok i
  VBool b -> Ok (if b then 1 else 0)
  VFloat d -> floatAsInt d
  VStr s -> case strAsInt s of
    IntOk i -> Ok i
    IntBadString -> failWith IntParsing v
    IntTooLarge -> failWith IntParsingSize v
  _ -> failWith IntType v
  where
    floatAsInt d
      | isNaN d || isInfinite d = failWith FiniteNumber v
      | d /= fromInteger (truncate d) = failWith IntFromFloat v
      | d > -9223372036854775808 && d < 9223372036854775808 = Ok (truncate d)
      | otherwise = failWith IntParsingSize v

-- | An integer as the nearest double (infinite when out of range).
intToDouble :: Integer -> Double
intToDouble i
  | fitsI64 i = fromIntegral (fromInteger i :: Int)
  | otherwise = fromRational (toRational i)

vFloat :: Mode -> Value -> V Double
vFloat mode v = case v of
  VFloat d -> Ok d
  VInt i _ -> case mode of
    JsonMode -> Ok (intToDouble i)
    PythonMode ->
      let d = intToDouble i
       in if isInfinite d then failWith FloatType v else Ok d
  VBool b -> Ok (if b then 1 else 0)
  VStr s -> maybe (failWith FloatParsing v) Ok (strAsFloat s)
  _ -> failWith FloatType v

vTimedelta :: Mode -> Value -> V Timedelta
vTimedelta mode v = case v of
  VStr s -> duration (parseDuration (TE.encodeUtf8 s))
  VInt i big -> case mode of
    JsonMode
      | big -> failWith TimeDeltaType v
      | otherwise -> duration (intDuration i)
    PythonMode
      | fitsI64 i -> duration (intDuration i)
      | otherwise ->
          let d = intToDouble i
           in if isInfinite d then failWith TimeDeltaType v else duration (floatDuration d)
  VBool b
    | mode == PythonMode -> duration (intDuration (if b then 1 else 0))
  VFloat d -> duration (floatDuration d)
  _ -> failWith TimeDeltaType v
  where
    duration = \case
      Right t -> Ok t
      Left (TimedeltaOverflow d) ->
        Exc (PyException "OverflowError" ("days=" <> T.pack (show d) <> "; must have magnitude <= 999999999"))
      Left e -> failWith (TimeDeltaParsing (durationErrorDoc e)) v

vArcKind :: Value -> V ArcKind
vArcKind = \case
  VStr "normal" -> Ok Normal
  VStr "inhibitor" -> Ok Inhibitor
  VStr "read" -> Ok Read
  v -> failWith EnumError v

vInterface :: Value -> V Interface
vInterface = \case
  VStr "input" -> Ok InputInterface
  VStr "output" -> Ok OutputInterface
  VStr "awaiting" -> Ok AwaitingInterface
  VStr "control" -> Ok ControlInterface
  v -> failWith LiteralError v

nullable :: (Value -> V a) -> Value -> V (Maybe a)
nullable f = \case
  VNull -> Ok Nothing
  v -> Just <$> f v

-- | @NetPath.coerce@, the plain validator every path field uses: a
-- @TypeError@ escapes (an outer 'Left'); a @ValueError@ becomes a
-- validation error (an inner 'Left' with its message).
coerceNetPath :: Value -> Either PyException (Either Text NetPath)
coerceNetPath value = case value of
  VStr s -> Right (Right (netPathFromText s))
  VList items -> checkedSegments (map toPython items)
  VDict members -> checkedSegments [VStr k | (k, _) <- pyDict members]
  other -> Left (PyException "TypeError" ("'" <> pyTypeName other <> "' object is not iterable"))

-- | The segment check of @NetPath.__new__@ on a tuple of segments: a
-- @TypeError@ escapes (an outer 'Left'); a @ValueError@ is an inner 'Left'
-- with its message.
checkedSegments :: [Value] -> Either PyException (Either Text NetPath)
checkedSegments items = go items
  where
    go [] = Right (Right (NetPath (map segment items)))
    go (item : rest) = case contains item of
      Left e -> Left e
      Right True ->
        Right
          ( Left
              ( "NetPath segment "
                  <> pyRepr item
                  <> " must not contain the separator '.'; pass a single dot-separated string to split on it."
              )
          )
      Right False -> go rest
    contains = \case
      VStr s -> Right (T.isInfixOf "." s)
      VList xs -> Right (any (pyEq (VStr ".")) xs)
      VDict ms -> Right (any ((== ".") . fst) ms)
      other -> Left (PyException "TypeError" ("argument of type '" <> pyTypeName other <> "' is not a container or iterable"))
    segment = \case
      VStr s -> SegText s
      other -> SegOther other

-- | @NetPath(*segments)@, which @append@ and @prepend@ call: one segment is
-- coerced on its own (a string split, a list or dict iterated), several are
-- checked as they are. A @ValueError@ escapes like any exception.
newNetPath :: [Segment] -> Either PyException NetPath
newNetPath segments = case segments of
  [] -> Right rootPath
  [one] -> raising (coerceNetPath (segmentValue one))
  _ -> raising (checkedSegments (map segmentValue segments))
  where
    raising = \case
      Left e -> Left e
      Right (Left msg) -> Left (PyException "ValueError" msg)
      Right (Right path) -> Right path
    segmentValue = \case
      SegText t -> VStr t
      SegOther v -> v

vNetPath :: Value -> V NetPath
vNetPath v = case coerceNetPath v of
  Left e -> Exc e
  Right (Left msg) -> failWith (ValueErrorKind msg) v
  Right (Right path) -> Ok path

-- Containers ----------------------------------------------------------------------

-- | @dict[K, V]@ with string keys converted by @key@ (which never fails for
-- the key types these models use); the result keeps Python dict order.
vDict :: (Text -> k) -> (Value -> V a) -> Value -> V [(k, a)]
vDict key value v = case v of
  VDict members ->
    (\pairs -> [(key k, a) | (k, a) <- pyDict pairs])
      <$> traverse (\(k, item) -> at (LocKey k) ((k,) <$> value item)) members
  _ -> failWith DictType v

vList :: (Value -> V a) -> Value -> V [a]
vList item v = case v of
  VList items -> traverse (\(i, x) -> at (LocIndex i) (item x)) (zip [0 ..] items)
  _ -> failWith ListType v

vPair :: Mode -> Value -> V (Double, Double)
vPair mode v = case v of
  VList items -> case items of
    [a, b] -> (,) <$> at (LocIndex 0) (vFloat mode a) <*> at (LocIndex 1) (vFloat mode b)
    [a] -> (,) <$> at (LocIndex 0) (vFloat mode a) <*> at (LocIndex 1) (failWith Missing v)
    [] -> (,) <$> at (LocIndex 0) (failWith Missing v) <*> at (LocIndex 1) (failWith Missing v)
    a : b : _ -> case (,) <$> at (LocIndex 0) (vFloat mode a) <*> at (LocIndex 1) (vFloat mode b) of
      Exc e -> Exc e
      _ -> failWith (TooLong 2 (length items)) v
  _ -> failWith TupleType v

-- | A model: @fields@ looks each field up (the last member with that name
-- wins) and validates them in definition order.
vModel :: Text -> (Value -> (Text -> Maybe Value) -> V a) -> Value -> V a
vModel className fields v = case v of
  VDict members -> fields v (lookupLast members)
  _ -> failWith (ModelType className) v

-- | The value of the last member with this name.
lookupLast :: [(Text, Value)] -> Text -> Maybe Value
lookupLast members name = go Nothing members
  where
    go found [] = found
    go found ((k, x) : rest) = go (if k == name then Just x else found) rest

required :: Value -> (Text -> Maybe Value) -> Text -> (Value -> V a) -> V a
required whole lookupField name f = at (LocKey name) $ case lookupField name of
  Just x -> f x
  Nothing -> failWith Missing whole

optional :: (Text -> Maybe Value) -> Text -> a -> (Value -> V a) -> V a
optional lookupField name def f = at (LocKey name) $ case lookupField name of
  Just x -> f x
  Nothing -> Ok def

-- Models ----------------------------------------------------------------------------

metadataField :: (Text -> Maybe Value) -> V (Maybe Metadata)
metadataField lookupField =
  optional lookupField "metadata" Nothing (nullable (vDict id (Ok . toPython)))

vFlatArc :: Value -> V FlatArc
vFlatArc = vModel "FlatArc" $ \whole field ->
  FlatArc
    <$> required whole field "source" vNetPath
    <*> required whole field "target" vNetPath
    <*> optional field "kind" Normal vArcKind
    <*> optional field "weight" 1 vInt
    <*> metadataField field

vPlaceDef :: Value -> V PlaceDef
vPlaceDef = vModel "PlaceDef" $ \_ field ->
  PlaceDef
    <$> optional field "initial" 0 vInt
    <*> optional field "label" Nothing (nullable vStr)
    <*> optional field "interface" Nothing (nullable vInterface)
    <*> metadataField field

vTransitionDef :: Mode -> Value -> V TransitionDef
vTransitionDef mode = vModel "TransitionDef" $ \_ field ->
  TransitionDef
    <$> optional field "handler" Nothing (nullable vStr)
    <*> optional field "guard" Nothing (nullable vStr)
    <*> optional field "label" Nothing (nullable vStr)
    <*> metadataField field
    <*> optional field "delay" Nothing (nullable (vTimedelta mode))

vRefEntry :: Value -> V RefEntry
vRefEntry = vModel "RefEntry" $ \whole field -> RefEntry <$> required whole field "ref" vStr

vViewState :: Mode -> Value -> V ViewState
vViewState mode = vModel "ViewState" $ \_ field ->
  ViewState
    <$> optional field "arcWaypoints" Nothing (nullable (vDict id (vList (vPair mode))))
    <*> optional field "layout" [] (vDict netPathFromText (vPair mode))
    <*> optional field "zoom" 1 (vFloat mode)
    <*> optional field "pan" (0, 0) (vPair mode)
    <*> optional field "selected" [] (vList vNetPath)

vFlatNetFile :: Mode -> Value -> V FlatNetFile
vFlatNetFile mode = vModel "FlatNetFile" $ \whole field ->
  let fieldsResult =
        FlatNetFile
          <$> optional field "fileVersion" "2" vStr
          <*> required whole field "net" vStr
          <*> optional field "arcs" [] (vList vFlatArc)
          <*> optional field "places" [] (vDict netPathFromText vPlaceDef)
          <*> optional field "transitions" [] (vDict netPathFromText (vTransitionDef mode))
          <*> optional field "refs" [] (vDict netPathFromText vRefEntry)
          <*> optional field "viewState" Nothing (nullable (vViewState mode))
   in fieldsResult `andThen` \file ->
        if any (\(NetPath segs, _) -> null segs) file.refs
          then failWith (ValueErrorKind "Empty mount NetPath is invalid") whole
          else Ok file

-- | Validate a parsed document. A 'Left' is the exception the reference
-- raises: a @ValidationError@ (with its rendered text) or an exception that
-- escaped validation.
validateFile :: Mode -> Value -> Either PyException FlatNetFile
validateFile mode v = case vFlatNetFile mode v of
  Ok file -> Right file
  Errs es -> Left (validationError mode es)
  Exc e -> Left e

-- Rendering -------------------------------------------------------------------------

-- | The @ValidationError@ for @FlatNetFile@ with these lines.
validationError :: Mode -> [LineError] -> PyException
validationError mode es = PyException "ValidationError" (renderLineErrors "FlatNetFile" mode es)

-- | @str(ValidationError)@.
renderLineErrors :: Text -> Mode -> [LineError] -> Text
renderLineErrors title mode es =
  T.pack (show (length es))
    <> " validation error"
    <> (if length es == 1 then "" else "s")
    <> " for "
    <> title
    <> "\n"
    <> T.intercalate "\n" (map line es)
  where
    line e =
      locLine e.loc
        <> "  "
        <> messageOf mode e.kind
        <> " [type="
        <> typeOf e.kind
        <> ", input_value="
        <> truncateRepr (pyRepr e.input)
        <> ", input_type="
        <> pyTypeName e.input
        <> "]\n    For further information visit https://errors.pydantic.dev/2.13/v/"
        <> typeOf e.kind
    locLine [] = ""
    locLine items = T.intercalate "." (map locText items) <> "\n"
    locText = \case
      LocKey k
        | T.isInfixOf "." k -> "`" <> k <> "`"
        | otherwise -> k
      LocIndex i -> T.pack (show i)

-- | pydantic's @write_truncated_to_limited_bytes(repr, 50)@.
truncateRepr :: Text -> Text
truncateRepr t
  | BS.length bytes <= 50 = t
  | otherwise =
      TE.decodeUtf8 (BS.take (floorBoundary 25) bytes)
        <> "..."
        <> TE.decodeUtf8 (BS.drop (ceilBoundary (BS.length bytes - 24)) bytes)
  where
    bytes = TE.encodeUtf8 t
    isContinuation i = i < BS.length bytes && let b = BS.index bytes i in b >= 0x80 && b < 0xC0
    floorBoundary i = if isContinuation i then floorBoundary (i - 1) else i
    ceilBoundary i = if isContinuation i then ceilBoundary (i + 1) else i

typeOf :: ErrorKind -> Text
typeOf = \case
  Missing -> "missing"
  ModelType _ -> "model_type"
  DictType -> "dict_type"
  ListType -> "list_type"
  TupleType -> "tuple_type"
  StringType -> "string_type"
  IntType -> "int_type"
  IntParsing -> "int_parsing"
  IntFromFloat -> "int_from_float"
  IntParsingSize -> "int_parsing_size"
  FiniteNumber -> "finite_number"
  FloatType -> "float_type"
  FloatParsing -> "float_parsing"
  TimeDeltaType -> "time_delta_type"
  TimeDeltaParsing _ -> "time_delta_parsing"
  EnumError -> "enum"
  LiteralError -> "literal_error"
  ValueErrorKind _ -> "value_error"
  TooLong _ _ -> "too_long"
  JsonInvalid _ -> "json_invalid"

messageOf :: Mode -> ErrorKind -> Text
messageOf mode = \case
  Missing -> "Field required"
  ModelType cls -> json "Input should be an object" ("Input should be a valid dictionary or instance of " <> cls)
  DictType -> json "Input should be an object" "Input should be a valid dictionary"
  ListType -> json "Input should be a valid array" "Input should be a valid list"
  TupleType -> json "Input should be a valid array" "Input should be a valid tuple"
  StringType -> "Input should be a valid string"
  IntType -> "Input should be a valid integer"
  IntParsing -> "Input should be a valid integer, unable to parse string as an integer"
  IntFromFloat -> "Input should be a valid integer, got a number with a fractional part"
  IntParsingSize -> "Unable to parse input string as an integer, exceeded maximum size"
  FiniteNumber -> "Input should be a finite number"
  FloatType -> "Input should be a valid number"
  FloatParsing -> "Input should be a valid number, unable to parse string as a number"
  TimeDeltaType -> json "Input should be a valid duration" "Input should be a valid timedelta"
  TimeDeltaParsing doc -> json "Input should be a valid duration, " "Input should be a valid timedelta, " <> doc
  EnumError -> "Input should be 'normal', 'inhibitor' or 'read'"
  LiteralError -> "Input should be 'input', 'output', 'awaiting' or 'control'"
  ValueErrorKind msg -> "Value error, " <> msg
  TooLong maxLength actual ->
    "Tuple should have at most "
      <> T.pack (show maxLength)
      <> " item"
      <> (if maxLength == 1 then "" else "s")
      <> " after validation, not "
      <> T.pack (show actual)
  JsonInvalid desc -> "Invalid JSON: " <> desc
  where
    json a b = if mode == JsonMode then a else b
