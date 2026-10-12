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
-- models the inputs as Python values ('PV', petrus-json's 'PyObject', which
-- "Petrus.Json.Python.Pydantic" renders errors over) and the validators as small
-- combinators that report errors in Pydantic's order: declared fields first
-- (each field's errors in place), then forbidden extra members in input
-- order, and model-level (\"after\") validators only when every field
-- passed.
module Petrus.Impetus.Validation.Pydantic
  ( -- * Python values
    PV
  , PyObject (..)
  , fromRaw
  , fromJson
  , pyRepr
  , pyStrRepr
  , pyStringRepr
  , pyStr
  , pyTypeName
  , pvJson
    -- * Errors
  , Loc (..)
  , LineError (..)
  , Validated
  , renderValidationError
  , valueError
  , fatalError
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
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Json.Python.Object (PyObject (..), fromJson, fromRaw, pyRepr, pyStr, pyTypeName)
import Petrus.Json.Python.Pydantic (Loc (..), LineError (..))
import Petrus.Json.Python.Pydantic qualified as Pydantic
import Petrus.Json.PythonText (pythonStrRepr, pythonStringRepr)
import Petrus.Json.Wtf8 (hasLoneSurrogate, lossyUtf8)

-- ---------------------------------------------------------------------------
-- Python values

-- | A Python value as a model validator sees it (petrus-json's
-- 'PyObject', whose @repr@ and type name every pydantic error quotes).
type PV = PyObject

-- | The JSON value of a dumped model (@model_dump(mode="json")@ of the
-- models these validators build): a tuple as an array, and a model
-- instance, which only an error quotes, by its @repr@.
pvJson :: PV -> Json
pvJson = \case
  PyNone -> Null
  PyBool b -> Bool b
  PyInt i -> Int i
  PyFloat d -> Float d
  PyStr s -> String s
  PyList items -> Array (map pvJson items)
  PyTuple items -> Array (map pvJson items)
  PyDict members -> Object [(k, pvJson v) | (k, v) <- members]
  other -> String (pyRepr other)

-- | CPython's @repr(str)@.
pyStrRepr :: Text -> Text
pyStrRepr = pythonStrRepr

-- | CPython's @repr(str)@ over code points, which may include lone
-- surrogates (a scanned key can).
pyStringRepr :: String -> Text
pyStringRepr = pythonStringRepr

-- ---------------------------------------------------------------------------
-- Errors

type Validated a = Either [LineError] a

-- | A @ValueError@ raised by a field or model validator.
valueError :: Text -> PV -> LineError
valueError text = LineError [] ("Value error, " <> text) "value_error"

-- | An exception other than a validation error raised inside a validator
-- (the reference's @RecursionError@): it aborts the whole validation, so
-- the errors collected before it are discarded and nothing after it runs.
-- Its text is the exception's own.
fatalError :: Text -> LineError
fatalError text = LineError [] text fatalType PyNone

fatalType :: Text
fatalType = "<fatal>"

-- | @str(ValidationError)@ for a model title and its errors
-- ('Pydantic.renderValidationError'), or the text of the exception that
-- aborted the validation.
renderValidationError :: Text -> [LineError] -> Text
renderValidationError title errors = case [err.message | err <- errors, err.errorType == fatalType] of
  fatal : _ -> fatal
  [] -> Pydantic.renderValidationError title errors

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
-- unknown members are refused after every declared field. pydantic-core
-- reads each unknown member's name as UTF-8 while it looks for them, so a
-- name holding a lone surrogate (a WTF-8 'Text') ends the model's
-- validation with that one @string_unicode@ error.
model :: Text -> [Text] -> ([(Text, PV)] -> PV -> Collect a) -> PV -> Validated a
model className fields build = \case
  whole@(PyDict members) ->
    let unknown = [(k, v) | (k, v) <- members, k `notElem` fields]
        extras = [LineError [Key k] "Extra inputs are not permitted" "extra_forbidden" v | (k, v) <- unknown]
        -- A declared field's name is never unreadable, so only the unknown
        -- members (usually none) are scanned.
        unreadable = [k | (k, _) <- unknown, hasLoneSurrogate k]
     in case (collect (build members whole), extras) of
          (Left es, _) | any (\err -> err.errorType == fatalType) es -> Left es
          _ | k : _ <- unreadable -> Left [Pydantic.stringUnicode (PyStr k)]
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
  whole@(PyDict members) -> case lookup "kind" members of
    Nothing -> Left [LineError [] "Unable to extract tag using discriminator 'kind'" "union_tag_not_found" whole]
    Just tagValue ->
      let tag = pyStr tagValue
       in case (tagValue, lookup tag choices) of
            (PyStr _, Just validate) -> at (Key tag) (validate whole)
            _ ->
              Left
                [ LineError
                    []
                    ( "Input tag '"
                        <> lossyUtf8 tag
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
  PyList items -> each items
  PyTuple items -> each items
  other -> Left [LineError [] "Input should be a valid tuple" "tuple_type" other]
  where
    each items = collect (traverse (\(i, item) -> Collect (at (Index i) (validate item))) (zip [0 ..] items))

strictStr :: PV -> Validated Text
strictStr = \case
  PyStr s -> Right s
  other -> Left [LineError [] "Input should be a valid string" "string_type" other]

-- | @X | None@.
optional :: (PV -> Validated a) -> PV -> Validated (Maybe a)
optional validate = \case
  PyNone -> Right Nothing
  other -> Just <$> validate other

-- | @Literal["a", "b", ...]@.
literalStr :: [Text] -> PV -> Validated Text
literalStr options = \case
  PyStr s | s `elem` options -> Right s
  other@(PyStr s) | hasLoneSurrogate s -> Left [Pydantic.stringUnicode other]
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
  PyInt i | i == expected -> Right expected
  PyFloat d | not (isNaN d || isInfinite d) && toRational d == fromInteger expected -> Right expected
  other -> Left [LineError [] ("Input should be " <> T.pack (show expected)) "literal_error" other]

-- | A strict @int@ (never a @bool@ or @float@) within inclusive bounds.
intRange :: Integer -> Integer -> PV -> Validated Integer
intRange low high = \case
  PyInt i
    | i < low -> Left [LineError [] ("Input should be greater than or equal to " <> T.pack (show low)) "greater_than_equal" (PyInt i)]
    | i > high -> Left [LineError [] ("Input should be less than or equal to " <> T.pack (show high)) "less_than_equal" (PyInt i)]
    | otherwise -> Right i
  other -> Left [LineError [] "Input should be a valid integer" "int_type" other]
