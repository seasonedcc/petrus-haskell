-- | Python @repr@ spellings for diagnostics.
--
-- The kernel's error and diagnostic texts follow the reference's f-strings,
-- many of which embed @{value!r}@. These helpers reproduce CPython's @repr@
-- for the value shapes those messages carry, so a Haskell diagnostic reads
-- like its Python counterpart. They are presentation only: no wire format or
-- semantic decision depends on them.
module Petrus.Impetus.Internal.Repr
  ( pyStr
  , pyOptStr
  , pyJson
  , pyList
  , pyTuple
  , pyInt
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..), pythonFloatRepr)
import Petrus.Json.PythonText (pythonStrRepr)

-- | CPython's @repr(str)@ (CPython 3.14's printability, for every code
-- point: "Petrus.Json.PythonText").
pyStr :: Text -> Text
pyStr = pythonStrRepr

-- | @repr@ of @str | None@.
pyOptStr :: Maybe Text -> Text
pyOptStr = maybe "None" pyStr

-- | @repr@ of a JSON-shaped Python value (dicts, lists, scalars).
pyJson :: Json -> Text
pyJson = \case
  Null -> "None"
  Bool True -> "True"
  Bool False -> "False"
  Int i -> T.pack (show i)
  Float d
    | isNaN d -> "nan"
    | isInfinite d -> if d > 0 then "inf" else "-inf"
    | otherwise -> T.pack (pythonFloatRepr d)
  String s -> pyStr s
  Array items -> "[" <> T.intercalate ", " (map pyJson items) <> "]"
  Object members -> "{" <> T.intercalate ", " [pyStr k <> ": " <> pyJson v | (k, v) <- members] <> "}"

-- | @repr@ of a Python list given each item's repr.
pyList :: [Text] -> Text
pyList items = "[" <> T.intercalate ", " items <> "]"

-- | @repr@ of a Python tuple given each item's repr.
pyTuple :: [Text] -> Text
pyTuple [single] = "(" <> single <> ",)"
pyTuple items = "(" <> T.intercalate ", " items <> ")"

pyInt :: Show a => a -> Text
pyInt = T.pack . show
