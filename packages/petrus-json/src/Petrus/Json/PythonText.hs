-- | CPython 3.14's string predicates and @repr(str)@, exact for every code
-- point.
--
-- The Petrus reference embeds @repr@ of strings in many error and
-- diagnostic texts, and @repr@ escapes exactly the characters for which
-- @str.isprintable@ is false. GHC's "Data.Char" follows the Unicode version
-- GHC ships (15.1 for GHC 9.10) and its 'Data.Char.isPrint' admits the space
-- separators, so neither can stand in for CPython's predicate. The table in
-- "Petrus.Json.PythonText.Printable" is generated from the pinned
-- interpreter (CPython 3.14, Unicode 16.0) by @gen/gen_python_printable.py@,
-- and the test suite checks every code point 0..0x10FFFF against the
-- committed vector @test/python-printable.txt@.
module Petrus.Json.PythonText
  ( isPythonPrintable
  , pythonStrRepr
  , pythonStringRepr
  ) where

import Data.Char (ord)
import Data.IntMap.Strict qualified as IntMap
import Data.Text (Text)
import Data.Text qualified as T
import Numeric (showHex)
import Petrus.Json.PythonText.Printable (printableRanges)

printable :: IntMap.IntMap Int
printable = IntMap.fromList printableRanges
{-# NOINLINE printable #-}

-- | CPython's @str.isprintable@ for one code point (a lone surrogate is never
-- printable).
isPythonPrintable :: Char -> Bool
isPythonPrintable c
  | n < 0x7F = n >= 0x20
  | n < 0xA1 = False
  | otherwise = case IntMap.lookupLE n printable of
      Just (_, high) -> n <= high
      Nothing -> False
  where
    n = ord c

-- | CPython's @repr(str)@.
pythonStrRepr :: Text -> Text
pythonStrRepr = pythonStringRepr . T.unpack

-- | CPython's @repr(str)@ over code points, which may include lone
-- surrogates (a 'Text' cannot hold them, but a scanned JSON key can).
pythonStringRepr :: String -> Text
pythonStringRepr chars = T.pack ([quote] ++ concatMap escape chars ++ [quote])
  where
    quote = if '\'' `elem` chars && '"' `notElem` chars then '"' else '\''
    escape c
      | c == quote || c == '\\' = ['\\', c]
      | c == '\t' = "\\t"
      | c == '\n' = "\\n"
      | c == '\r' = "\\r"
      | isPythonPrintable c = [c]
      | ord c < 0x100 = "\\x" ++ pad 2 (ord c)
      | ord c < 0x10000 = "\\u" ++ pad 4 (ord c)
      | otherwise = "\\U" ++ pad 8 (ord c)
    pad width n = let digits = showHex n "" in replicate (width - length digits) '0' ++ digits
