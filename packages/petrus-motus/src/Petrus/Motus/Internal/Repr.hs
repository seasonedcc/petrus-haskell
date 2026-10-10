-- | CPython @repr@ spellings for Motus diagnostics (presentation only).
module Petrus.Motus.Internal.Repr
  ( pyStr
  , pyStrList
  , exceptionTypeName
  , exceptionMessage
  ) where

import Control.Exception (SomeException (..), displayException)
import Data.Char (isPrint, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Typeable (typeOf)
import Numeric (showHex)

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

-- | @repr@ of a Python list of strings.
pyStrList :: [Text] -> Text
pyStrList items = "[" <> T.intercalate ", " (map pyStr items) <> "]"

-- | The exception's type name: the analogue of @type(error).__name__@.
exceptionTypeName :: SomeException -> Text
exceptionTypeName (SomeException e) = T.pack (show (typeOf e))

-- | The exception's message without a trailing call stack: the analogue of
-- @str(error)@.
exceptionMessage :: SomeException -> Text
exceptionMessage (SomeException e) = fst (T.breakOn "\nCallStack (from" (T.pack (displayException e)))
