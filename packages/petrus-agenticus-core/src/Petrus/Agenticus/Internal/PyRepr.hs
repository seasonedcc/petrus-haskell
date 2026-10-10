-- | CPython's @repr()@ of a @str@, which upstream error messages embed through
-- f-string @{value!r}@ conversions (for example
-- @connection 'connection-main' does not exist@).
--
-- The same algorithm lives in @Petrus.Testing.Dst.PyRepr@; it is repeated
-- here so the core package does not depend on the DST harness.
module Petrus.Agenticus.Internal.PyRepr
  ( pyStrRepr
  ) where

import Data.Char (GeneralCategory (..), generalCategory, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)

-- | CPython's @str.__repr__@ (@unicode_repr@).
pyStrRepr :: Text -> Text
pyStrRepr s = T.singleton quote <> T.concatMap escape s <> T.singleton quote
  where
    quote = if T.any (== '\'') s && not (T.any (== '"') s) then '"' else '\''
    escape c
      | c == quote || c == '\\' = T.pack ['\\', c]
      | c == '\t' = "\\t"
      | c == '\n' = "\\n"
      | c == '\r' = "\\r"
      | ord c < 0x20 || ord c == 0x7f = hexEscape 'x' 2 (ord c)
      | ord c < 0x7f = T.singleton c
      | printable c = T.singleton c
      | ord c <= 0xff = hexEscape 'x' 2 (ord c)
      | ord c <= 0xffff = hexEscape 'u' 4 (ord c)
      | otherwise = hexEscape 'U' 8 (ord c)
    hexEscape tag width n =
      let digits = showHex n ""
       in T.pack ('\\' : tag : replicate (width - length digits) '0' ++ digits)
    printable c = case generalCategory c of
      Control -> False
      Format -> False
      Surrogate -> False
      PrivateUse -> False
      NotAssigned -> False
      LineSeparator -> False
      ParagraphSeparator -> False
      Space -> c == ' '
      _ -> True
