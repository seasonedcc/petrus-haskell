-- | The slice of Pydantic v2 (2.13, strict mode) that the reference's
-- Net-definition and Net-document models use, reproduced message for
-- message.
--
-- The reference admits wire documents through frozen, strict,
-- @extra="forbid"@ Pydantic models, and its refusal texts embed the
-- resulting 'ValidationError' verbatim: the error count and model title, each
-- error's dotted location, message, error type, a truncated Python @repr@ of
-- the offending input and its Python type, and the documentation URL. A
-- conforming implementation must refuse with the same text, so this module
-- models the inputs as Python values ('PV') and the validators as small
-- combinators that report errors in Pydantic's order: declared fields first
-- (each field's errors in place), then forbidden extra members in input
-- order, and model-level (\"after\") validators only when every field
-- passed.
module Petrus.Impetus.Internal.Pydantic
  ( -- * Python values
    PV (..)
  , fromRaw
  , fromJson
  , pyRepr
  , pyStrRepr
  , pyStringRepr
  , pyStrValue
  , pyTypeName
    -- * Errors
  , Loc (..)
  , LineError (..)
  , Validated
  , renderValidationError
  , valueError
    -- * Validators
  , Collect (..)
  , collect
  , at
  , model
  , required
  , defaulted
  , afterModel
  , checked
  , tagged
  , tupleOf
  , strictStr
  , optional
  , literalStr
  , literalInt
  , intRange
  ) where

import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Impetus.Internal.PyJson (Raw (..), rawText)
import Petrus.Json (Json (..), pythonFloatRepr)
import Petrus.Json.PythonText (pythonStringRepr)

-- ---------------------------------------------------------------------------
-- Python values

-- | A Python value as a model validator sees it: JSON-shaped, plus the
-- tuples a @model_dump(mode="python")@ produces and opaque model instances
-- (which appear in errors only through their @repr@).
data PV
  = PNone
  | PBool Bool
  | PInt Integer
  | PFloat Double
  | PStr Text
  | PList [PV]
  | PTuple [PV]
  | PDict [(Text, PV)]
  | -- | A model instance: its class name and its @repr@.
    PInstance Text Text

-- | A scanned value whose strings are already admitted as scalar values.
fromRaw :: Raw -> PV
fromRaw = \case
  RNull -> PNone
  RBool b -> PBool b
  RInt i -> PInt i
  RFloat d -> PFloat d
  RStr s -> PStr (rawText s)
  RList items -> PList (map fromRaw items)
  RDict members -> PDict [(rawText k, fromRaw v) | (k, v) <- members]

fromJson :: Json -> PV
fromJson = \case
  Null -> PNone
  Bool b -> PBool b
  Int i -> PInt i
  Float d -> PFloat d
  String s -> PStr s
  Array items -> PList (map fromJson items)
  Object members -> PDict [(k, fromJson v) | (k, v) <- members]

-- | CPython's @repr@.
pyRepr :: PV -> Text
pyRepr = \case
  PNone -> "None"
  PBool True -> "True"
  PBool False -> "False"
  PInt i -> T.pack (show i)
  PFloat d -> floatRepr d
  PStr s -> pyStrRepr s
  PList items -> "[" <> T.intercalate ", " (map pyRepr items) <> "]"
  PTuple [single] -> "(" <> pyRepr single <> ",)"
  PTuple items -> "(" <> T.intercalate ", " (map pyRepr items) <> ")"
  PDict members -> "{" <> T.intercalate ", " [pyStrRepr k <> ": " <> pyRepr v | (k, v) <- members] <> "}"
  PInstance _ text -> text

floatRepr :: Double -> Text
floatRepr d
  | isNaN d = "nan"
  | isInfinite d = if d > 0 then "inf" else "-inf"
  | otherwise = T.pack (pythonFloatRepr d)

-- | CPython's @str()@ (which differs from @repr@ only for strings).
pyStrValue :: PV -> Text
pyStrValue = \case
  PStr s -> s
  other -> pyRepr other

-- | The Python type name Pydantic reports as @input_type@.
pyTypeName :: PV -> Text
pyTypeName = \case
  PNone -> "NoneType"
  PBool _ -> "bool"
  PInt _ -> "int"
  PFloat _ -> "float"
  PStr _ -> "str"
  PList _ -> "list"
  PTuple _ -> "tuple"
  PDict _ -> "dict"
  PInstance name _ -> name

-- | CPython's @repr(str)@.
pyStrRepr :: Text -> Text
pyStrRepr = pyStringRepr . T.unpack

-- | CPython's @repr(str)@ over code points, which may include lone
-- surrogates (a scanned key can).
pyStringRepr :: String -> Text
pyStringRepr = pythonStringRepr

-- ---------------------------------------------------------------------------
-- Errors

-- | One location step: a member name or an item index.
data Loc = Key Text | Index Int

-- | One line of a 'ValidationError'.
data LineError = LineError
  { loc :: [Loc]
  , message :: Text
  , errorType :: Text
  , input :: PV
  }

type Validated a = Either [LineError] a

-- | A @ValueError@ raised by a field or model validator.
valueError :: Text -> PV -> LineError
valueError text = LineError [] ("Value error, " <> text) "value_error"

-- | @str(ValidationError)@ for a model title and its errors.
renderValidationError :: Text -> [LineError] -> Text
renderValidationError title errors =
  T.intercalate "\n" (header : concatMap line errors)
  where
    count = length errors
    header =
      T.pack (show count)
        <> (if count == 1 then " validation error for " else " validation errors for ")
        <> title
    line err =
      [renderLoc err.loc | not (null err.loc)]
        ++ [ "  "
               <> err.message
               <> " [type="
               <> err.errorType
               <> ", input_value="
               <> truncateRepr (pyRepr err.input)
               <> ", input_type="
               <> pyTypeName err.input
               <> "]"
           , "    For further information visit https://errors.pydantic.dev/2.13/v/" <> err.errorType
           ]
    -- pydantic-core quotes a key containing a dot so the path stays readable.
    renderLoc = T.intercalate "." . map (\case Key k | T.any (== '.') k -> "`" <> k <> "`"; Key k -> k; Index i -> T.pack (show i))

-- | Pydantic shortens an input @repr@ longer than 50 UTF-8 bytes to its
-- first 25 bytes and last 24 bytes (moved to character boundaries).
truncateRepr :: Text -> Text
truncateRepr text
  | BS.length bytes <= 50 = text
  | otherwise = TE.decodeUtf8 (BS.take headEnd bytes) <> "..." <> TE.decodeUtf8 (BS.drop tailStart bytes)
  where
    bytes = TE.encodeUtf8 text
    boundary i = i >= BS.length bytes || not (continuation (BS.index bytes i))
    continuation w = w >= 0x80 && w < 0xC0
    headEnd = last (filter boundary [0 .. 25])
    tailStart = head' (filter boundary [BS.length bytes - 24 .. BS.length bytes])
    head' = \case
      x : _ -> x
      [] -> BS.length bytes

-- ---------------------------------------------------------------------------
-- Validators

-- | Error-accumulating composition of independent field validations.
newtype Collect a = Collect (Validated a)

instance Functor Collect where
  fmap f (Collect v) = Collect (fmap f v)

instance Applicative Collect where
  pure = Collect . Right
  Collect (Left e1) <*> Collect (Left e2) = Collect (Left (e1 ++ e2))
  Collect (Left e1) <*> Collect (Right _) = Collect (Left e1)
  Collect (Right _) <*> Collect (Left e2) = Collect (Left e2)
  Collect (Right f) <*> Collect (Right a) = Collect (Right (f a))

collect :: Collect a -> Validated a
collect (Collect v) = v

-- | Prefix every error's location.
at :: Loc -> Validated a -> Validated a
at step = first (map (\err -> err {loc = step : err.loc}))

-- | A strict, @extra="forbid"@ model: the builder looks fields up by name;
-- unknown members are refused after every declared field.
model :: Text -> [Text] -> ([(Text, PV)] -> PV -> Collect a) -> PV -> Validated a
model className fields build = \case
  whole@(PDict members) ->
    let extras =
          [ LineError [Key k] "Extra inputs are not permitted" "extra_forbidden" v
          | (k, v) <- members
          , k `notElem` fields
          ]
     in case (collect (build members whole), extras) of
          (Right a, []) -> Right a
          (Right _, es) -> Left es
          (Left es, more) -> Left (es ++ more)
  other -> Left [LineError [] ("Input should be a valid dictionary or instance of " <> className) "model_type" other]

-- | A required field.
required :: [(Text, PV)] -> PV -> Text -> (PV -> Validated a) -> Collect a
required members whole name validate = Collect $ case lookup name members of
  Nothing -> Left [LineError [Key name] "Field required" "missing" whole]
  Just value -> at (Key name) (validate value)

-- | A field with a default.
defaulted :: [(Text, PV)] -> Text -> a -> (PV -> Validated a) -> Collect a
defaulted members name fallback validate = Collect $ case lookup name members of
  Nothing -> Right fallback
  Just value -> at (Key name) (validate value)

-- | A model-level \"after\" validator: it sees the built value and reports
-- against the model's whole input.
afterModel :: (a -> Maybe Text) -> PV -> Validated a -> Validated a
afterModel check whole result = do
  value <- result
  case check value of
    Nothing -> Right value
    Just text -> Left [valueError text whole]

-- | A field \"after\" validator over the field's own input.
checked :: (a -> Maybe Text) -> (PV -> Validated a) -> PV -> Validated a
checked check validate value = do
  result <- validate value
  case check result of
    Nothing -> Right result
    Just text -> Left [valueError text value]

-- | A union discriminated by the @kind@ member; the matched member's errors
-- are located under its tag.
tagged :: [(Text, PV -> Validated a)] -> PV -> Validated a
tagged choices = \case
  whole@(PDict members) -> case lookup "kind" members of
    Nothing -> Left [LineError [] "Unable to extract tag using discriminator 'kind'" "union_tag_not_found" whole]
    Just tagValue ->
      let tag = pyStrValue tagValue
       in case (tagValue, lookup tag choices) of
            (PStr _, Just validate) -> at (Key tag) (validate whole)
            _ ->
              Left
                [ LineError
                    []
                    ( "Input tag '"
                        <> tag
                        <> "' found using 'kind' does not match any of the expected tags: "
                        <> T.intercalate ", " ["'" <> name <> "'" | (name, _) <- choices]
                    )
                    "union_tag_invalid"
                    whole
                ]
  other -> Left [LineError [] "Input should be a valid dictionary or object to extract fields from" "model_attributes_type" other]

-- | @tuple[X, ...]@ behind the reference's list-to-tuple \"before\"
-- validator: a list or tuple, item by item.
tupleOf :: (PV -> Validated a) -> PV -> Validated [a]
tupleOf validate = \case
  PList items -> each items
  PTuple items -> each items
  other -> Left [LineError [] "Input should be a valid tuple" "tuple_type" other]
  where
    each items = collect (traverse (\(i, item) -> Collect (at (Index i) (validate item))) (zip [0 ..] items))

strictStr :: PV -> Validated Text
strictStr = \case
  PStr s -> Right s
  other -> Left [LineError [] "Input should be a valid string" "string_type" other]

-- | @X | None@.
optional :: (PV -> Validated a) -> PV -> Validated (Maybe a)
optional validate = \case
  PNone -> Right Nothing
  other -> Just <$> validate other

-- | @Literal["a", "b", ...]@.
literalStr :: [Text] -> PV -> Validated Text
literalStr options = \case
  PStr s | s `elem` options -> Right s
  other -> Left [LineError [] ("Input should be " <> spelled) "literal_error" other]
  where
    quoted = map (\o -> "'" <> o <> "'") options
    spelled = case reverse quoted of
      [] -> ""
      [single] -> single
      lastOne : earlier -> T.intercalate ", " (reverse earlier) <> " or " <> lastOne

-- | @Literal[n]@: Python equality, except that a @bool@ never matches.
literalInt :: Integer -> PV -> Validated Integer
literalInt expected = \case
  PInt i | i == expected -> Right expected
  PFloat d | not (isNaN d || isInfinite d) && toRational d == fromInteger expected -> Right expected
  other -> Left [LineError [] ("Input should be " <> T.pack (show expected)) "literal_error" other]

-- | A strict @int@ (never a @bool@ or @float@) within inclusive bounds.
intRange :: Integer -> Integer -> PV -> Validated Integer
intRange low high = \case
  PInt i
    | i < low -> Left [LineError [] ("Input should be greater than or equal to " <> T.pack (show low)) "greater_than_equal" (PInt i)]
    | i > high -> Left [LineError [] ("Input should be less than or equal to " <> T.pack (show high)) "less_than_equal" (PInt i)]
    | otherwise -> Right i
  other -> Left [LineError [] "Input should be a valid integer" "int_type" other]
