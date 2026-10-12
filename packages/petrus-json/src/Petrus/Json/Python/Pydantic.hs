{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The text of a pydantic 2.13 (pydantic-core 2.46) @ValidationError@, and
-- the Python objects its lines quote.
--
-- The reference's refusals embed @str(ValidationError)@ verbatim: the error
-- count and model title, then for each error its dotted location, message,
-- error type, a truncated @repr@ of the offending input and that input's
-- Python type, and the documentation URL. This is the one rendering of that
-- text in the port; each package validates its own models and hands the
-- errors here ('renderValidationError'), so a pydantic upgrade changes one
-- module.
module Petrus.Json.Python.Pydantic
  ( -- * Python objects
    PyObject (..)
  , fromJson
  , fromRaw
  , pyRepr
  , pyStrValue
  , pyTypeName
    -- * Validation errors
  , Loc (..)
  , LineError (..)
  , stringUnicode
  , renderValidationError
  , renderLoc
  , truncateRepr
  , pydanticDocsUrl
  ) where

import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json.Python.Scanner (Raw (..), rawText)
import Petrus.Json.PythonText (pythonStrRepr)
import Petrus.Json.Repr (pythonDoubleRepr, pythonIntRepr, pythonListRepr, pythonTupleRepr)
import Petrus.Json.Value (Json (..))
import Petrus.Json.Wtf8 (lossyUtf8)

-- ---------------------------------------------------------------------------
-- Python objects

-- | A Python object as a validator sees it: JSON-shaped, plus the tuples a
-- @model_dump(mode="python")@ produces and opaque model instances (which
-- appear in errors only through their @repr@). A dict's members are its
-- items in order, each key once.
data PyObject
  = PNone
  | PBool Bool
  | PInt Integer
  | PFloat Double
  | PStr Text
  | PList [PyObject]
  | PTuple [PyObject]
  | PDict [(Text, PyObject)]
  | -- | A model instance: its class name and its @repr@.
    PInstance Text Text

-- | The object @json.loads@ builds for a parsed value (whose objects hold
-- each key once).
fromJson :: Json -> PyObject
fromJson = \case
  Null -> PNone
  Bool b -> PBool b
  Int i -> PInt i
  Float d -> PFloat d
  String s -> PStr s
  Array items -> PList (map fromJson items)
  Object members -> PDict [(k, fromJson v) | (k, v) <- members]

-- | A scanned value whose strings are already admitted as scalar values.
fromRaw :: Raw -> PyObject
fromRaw = \case
  RNull -> PNone
  RBool b -> PBool b
  RInt i -> PInt i
  RFloat d -> PFloat d
  RStr s -> PStr (rawText s)
  RList items -> PList (map fromRaw items)
  RDict members -> PDict [(rawText k, fromRaw v) | (k, v) <- members]

-- | CPython's @repr@.
pyRepr :: PyObject -> Text
pyRepr = \case
  PNone -> "None"
  PBool True -> "True"
  PBool False -> "False"
  PInt i -> pythonIntRepr i
  PFloat d -> pythonDoubleRepr d
  PStr s -> pythonStrRepr s
  PList items -> pythonListRepr (map pyRepr items)
  PTuple items -> pythonTupleRepr (map pyRepr items)
  PDict members -> "{" <> T.intercalate ", " [pythonStrRepr k <> ": " <> pyRepr v | (k, v) <- members] <> "}"
  PInstance _ text -> text

-- | CPython's @str()@ (which differs from @repr@ only for strings).
pyStrValue :: PyObject -> Text
pyStrValue = \case
  PStr s -> s
  other -> pyRepr other

-- | @type(x).__qualname__@, which pydantic reports as @input_type@.
pyTypeName :: PyObject -> Text
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

-- ---------------------------------------------------------------------------
-- Validation errors

-- | One location step: a field or dict key, or an item index.
data Loc = Key Text | Index Int

-- | One error of a @ValidationError@.
data LineError = LineError
  { loc :: [Loc]
  -- ^ Outermost first; empty for an error on the whole input.
  , message :: Text
  , errorType :: Text
  -- ^ pydantic's error type (@missing@, @int_parsing@, ...).
  , input :: PyObject
  }

-- | pydantic-core's refusal of a @str@ it must read as UTF-8 (a literal
-- member, a number to parse, an unknown member's name) that holds a lone
-- surrogate.
stringUnicode :: PyObject -> LineError
stringUnicode = LineError [] "Input should be a valid string, unable to parse raw data as a unicode string" "string_unicode"

-- | @str(ValidationError)@ for a model title and its errors.
renderValidationError :: Text -> [LineError] -> Text
renderValidationError title errors = T.intercalate "\n" (header : concatMap line errors)
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
           , "    For further information visit " <> pydanticDocsUrl <> err.errorType
           ]

-- | The URL every error line points at, before its error type.
pydanticDocsUrl :: Text
pydanticDocsUrl = "https://errors.pydantic.dev/2.13/v/"

-- | A dotted location. pydantic-core quotes a key holding a dot in
-- backticks, and holds keys as Rust strings, so a lone surrogate reads as
-- @from_utf8_lossy@ spells it ('lossyUtf8').
renderLoc :: [Loc] -> Text
renderLoc = T.intercalate "." . map step
  where
    step = \case
      Key key
        | T.any (== '.') k -> "`" <> k <> "`"
        | otherwise -> k
        where
          k = lossyUtf8 key
      Index i -> T.pack (show i)

-- | pydantic shortens an input @repr@ longer than 50 UTF-8 bytes to its
-- first 25 bytes and last 24 bytes, each moved to a character boundary.
truncateRepr :: Text -> Text
truncateRepr text
  | BS.length bytes <= 50 = text
  | otherwise = TE.decodeUtf8 (BS.take (floorBoundary 25) bytes) <> "..." <> TE.decodeUtf8 (BS.drop (ceilBoundary (BS.length bytes - 24)) bytes)
  where
    bytes = TE.encodeUtf8 text
    continuation i = i < BS.length bytes && let b = BS.index bytes i in b >= 0x80 && b < 0xC0
    floorBoundary i = if continuation i then floorBoundary (i - 1) else i
    ceilBoundary i = if continuation i then ceilBoundary (i + 1) else i
