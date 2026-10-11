-- | CPython 3.14's case mappings and @str.isdigit@, exact for every code
-- point.
--
-- "Data.Text"'s 'Data.Text.toLower', 'Data.Text.toUpper' and
-- 'Data.Text.toCaseFold' follow the Unicode version GHC ships (15.1 for
-- GHC 9.10), and 'Data.Char.isDigit' is ASCII only. These follow the
-- tables @gen/gen_python_tables.py@ generates from the pinned interpreter
-- (CPython 3.14, Unicode 16.0), as "Petrus.Json.PythonText" does for the
-- other @str@ predicates. A lone surrogate (a WTF-8 'Text',
-- "Petrus.Json.Wtf8") maps to itself, as in CPython.
module Petrus.Json.PythonCase
  ( pythonLower
  , pythonUpper
  , pythonCasefold
  , isPythonDigit
  , isPythonCased
  , isPythonCaseIgnorable
  ) where

import Data.Char (chr, ord)
import Data.IntMap.Strict qualified as IntMap
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json.PythonText.CaseTables
import Petrus.Json.Wtf8 (fromCodePoints)

-- | A case mapping: the single-code-point targets, then the longer ones.
data Mapping = Mapping !(IntMap.IntMap Int) !(IntMap.IntMap [Int])

mapping :: [(Int, Int, Int, Int)] -> [(Int, [Int])] -> Mapping
mapping runs specials =
  Mapping
    (IntMap.fromList [(first + k * stride, first + k * stride + delta) | (first, count, stride, delta) <- runs, k <- [0 .. count - 1]])
    (IntMap.fromList specials)

lowerMapping, upperMapping, casefoldMapping :: Mapping
lowerMapping = mapping lowerRuns lowerSpecials
upperMapping = mapping upperRuns upperSpecials
casefoldMapping = mapping casefoldRuns casefoldSpecials
{-# NOINLINE lowerMapping #-}
{-# NOINLINE upperMapping #-}
{-# NOINLINE casefoldMapping #-}

-- | The code points one code point maps to (prepended to the rest).
mapped :: Mapping -> Char -> String -> String
mapped (Mapping singles specials) c rest = case IntMap.lookup n singles of
  Just target -> chr target : rest
  Nothing -> case IntMap.lookup n specials of
    Just targets -> map chr targets ++ rest
    Nothing -> c : rest
  where
    n = ord c
{-# INLINE mapped #-}

-- | Apply a mapping, ASCII text through "Data.Text" (which agrees there).
caseMap :: (Text -> Text) -> (String -> String) -> Text -> Text
caseMap ascii general text
  | T.all (< '\x80') text = ascii text
  | otherwise = fromCodePoints (general (T.unpack text))

-- | @str.lower()@: full lower-case mapping, with the final-sigma rule for
-- U+03A3 (CPython's @handle_capital_sigma@: final when a cased code point
-- precedes it and none follows, case-ignorable ones skipped both ways).
pythonLower :: Text -> Text
pythonLower = caseMap T.toLower (go [])
  where
    -- @before@ holds the code points already read, nearest first.
    go _ [] = []
    go before (c : rest)
      | c == '\x3A3' = (if finalSigma before rest then '\x3C2' else '\x3C3') : go (c : before) rest
      | otherwise = mapped lowerMapping c (go (c : before) rest)
    finalSigma before rest = case dropWhile isPythonCaseIgnorable before of
      c : _ | isPythonCased c -> case dropWhile isPythonCaseIgnorable rest of
        d : _ -> not (isPythonCased d)
        [] -> True
      _ -> False

-- | @str.upper()@.
pythonUpper :: Text -> Text
pythonUpper = caseMap T.toUpper (foldr (mapped upperMapping) [])

-- | @str.casefold()@.
pythonCasefold :: Text -> Text
pythonCasefold = caseMap T.toLower (foldr (mapped casefoldMapping) [])

rangeSet :: [(Int, Int)] -> IntMap.IntMap Int
rangeSet = IntMap.fromList

inRanges :: IntMap.IntMap Int -> Char -> Bool
inRanges ranges c = case IntMap.lookupLE (ord c) ranges of
  Just (_, high) -> ord c <= high
  Nothing -> False
{-# INLINE inRanges #-}

digits, cased, caseIgnorable :: IntMap.IntMap Int
digits = rangeSet digitRanges
cased = rangeSet casedRanges
caseIgnorable = rangeSet caseIgnorableRanges
{-# NOINLINE digits #-}
{-# NOINLINE cased #-}
{-# NOINLINE caseIgnorable #-}

-- | @str.isdigit()@ for one code point (Numeric_Type Decimal or Digit).
isPythonDigit :: Char -> Bool
isPythonDigit c
  | c < '\x80' = c >= '0' && c <= '9'
  | otherwise = inRanges digits c

-- | The Unicode Cased property, as CPython's tables hold it.
isPythonCased :: Char -> Bool
isPythonCased = inRanges cased

-- | The Unicode Case_Ignorable property, as CPython's tables hold it.
isPythonCaseIgnorable :: Char -> Bool
isPythonCaseIgnorable = inRanges caseIgnorable
