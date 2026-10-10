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

import Data.Char (isPrint, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)
import Petrus.Json (Json (..), pythonFloatRepr)

-- | CPython's @repr(str)@.
pyStr :: Text -> Text
pyStr text =
  let useDouble = T.any (== '\'') text && not (T.any (== '"') text)
      quote = if useDouble then '"' else '\''
      escape c
        | c == quote = T.pack ['\\', c]
        | c == '\\' = "\\\\"
        | c == '\n' = "\\n"
        | c == '\r' = "\\r"
        | c == '\t' = "\\t"
        | isPrint c && c /= '\x7f' = T.singleton c
        | ord c < 0x100 = "\\x" <> pad 2 (ord c)
        | ord c < 0x10000 = "\\u" <> pad 4 (ord c)
        | otherwise = "\\U" <> pad 8 (ord c)
      pad width n = let digits = showHex n "" in T.pack (replicate (width - length digits) '0' ++ digits)
   in T.singleton quote <> T.concatMap escape text <> T.singleton quote

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
