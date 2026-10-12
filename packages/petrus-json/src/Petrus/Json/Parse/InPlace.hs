-- | The common subset of JSON, read from a 'Text' in place: the fast path
-- of 'Petrus.Json.Python.Loads.loadsText' (@json.loads@ of a @str@).
--
-- 'parseInPlace' admits objects without repeated members, arrays, strings
-- without surrogates (escaped or raw) or control characters, integers of
-- up to 'maxIntStrDigits' digits, @true@, @false@ and @null@, nested less
-- than 'defaultNestingLimit' deep, with JSON whitespace around. Within that
-- subset @json.loads@ has exactly one result, the one 'parseInPlace'
-- returns. For anything else (floats, @NaN@ and the infinities, repeated
-- members, surrogates, every malformed document) it returns 'Nothing', and
-- 'Petrus.Json.Python.Loads.loadsText' goes on to 'Petrus.Json.parseJson'
-- and CPython's scanner, which decide every document.
--
-- The text is already valid UTF-8, so nothing is validated or copied: a
-- string without escapes is a slice of the document (and keeps the
-- document's array alive while it is). 'Petrus.Json.parseJson' reads bytes
-- and must do both. On hamsterdan-operator's @inspect@ benchmark, whose
-- provider answers are parsed this way, @json.loads@ through
-- 'Petrus.Json.parseJson' alone took the workload to 1.20 ms against
-- CPython's 971.5 µs (0.81×). With this path it takes 790 µs, and 746 µs
-- against CPython's 1.02 ms (1.37×) in a run with the two interleaved (see
-- hamsterdan-operator's @bench/RESULTS.md@, "The JSON fast path").
module Petrus.Json.Parse.InPlace
  ( parseInPlace
  ) where

import Data.Bits (shiftL, (.|.))
import Data.Char (chr)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Array qualified as A
import Data.Text.Internal qualified as TI
import Data.Word (Word8)
import Petrus.Json.Limits (defaultNestingLimit, maxIntStrDigits)
import Petrus.Json.Value (Json (..))

-- | A parsed value and the offset after it, or a refusal.
data Step a = Step a {-# UNPACK #-} !Int | Refused

-- | The document's value, or 'Nothing' when it is outside the subset.
parseInPlace :: Text -> Maybe Json
parseInPlace (TI.Text array offset len) = case value 0 (skip offset) of
  Step parsed end | skip end == limit -> Just parsed
  _ -> Nothing
  where
    limit = offset + len

    at :: Int -> Word8
    at = A.unsafeIndex array
    {-# INLINE at #-}

    skip :: Int -> Int
    skip !i
      | i < limit, space (at i) = skip (i + 1)
      | otherwise = i

    space w = w == 0x20 || w == 0x0a || w == 0x0d || w == 0x09

    digit w = w >= 0x30 && w <= 0x39

    value :: Int -> Int -> Step Json
    value !depth !i
      | i >= limit = Refused
      | otherwise = case at i of
          0x22 -> case string (i + 1) of
            Step s j -> Step (String s) j
            Refused -> Refused
          0x7b | depth < defaultNestingLimit -> object (depth + 1) (skip (i + 1))
          0x5b | depth < defaultNestingLimit -> array' (depth + 1) (skip (i + 1))
          0x74 | matches i "true" -> Step (Bool True) (i + 4)
          0x66 | matches i "false" -> Step (Bool False) (i + 5)
          0x6e | matches i "null" -> Step Null (i + 4)
          w | w == 0x2d || digit w -> integer i
          _ -> Refused

    matches i word =
      i + length word <= limit && and [at (i + k) == fromIntegral (fromEnum c) | (k, c) <- zip [0 ..] word]

    -- -?(0|[1-9][0-9]*), not followed by a fraction or an exponent.
    integer i =
      let negative = at i == 0x2d
          start = if negative then i + 1 else i
          end = digits start
          count = end - start
       in if count == 0
            || count > maxIntStrDigits
            || (count > 1 && at start == 0x30)
            || (end < limit && (at end == 0x2e || at end == 0x65 || at end == 0x45))
            then Refused
            else
              let magnitude
                    | count <= 18 = toInteger (accumulate start end (0 :: Int))
                    | otherwise = accumulateBig start end 0
               in Step (Int (if negative then negate magnitude else magnitude)) end

    digits !j
      | j < limit, digit (at j) = digits (j + 1)
      | otherwise = j

    accumulate !j !end !acc
      | j < end = accumulate (j + 1) end (acc * 10 + fromIntegral (at j - 0x30))
      | otherwise = acc

    accumulateBig :: Int -> Int -> Integer -> Integer
    accumulateBig !j !end !acc
      | j < end = accumulateBig (j + 1) end (acc * 10 + toInteger (at j - 0x30))
      | otherwise = acc

    array' depth i
      | i < limit, at i == 0x5d = Step (Array []) (i + 1)
      | otherwise = items [] i
      where
        items acc j = case value depth j of
          Refused -> Refused
          Step item k ->
            let l = skip k
             in if l >= limit
                  then Refused
                  else case at l of
                    0x2c -> items (item : acc) (skip (l + 1))
                    0x5d -> Step (Array (reverse (item : acc))) (l + 1)
                    _ -> Refused

    object depth i
      | i < limit, at i == 0x7d = Step (Object []) (i + 1)
      | otherwise = members [] (0 :: Int) i
      where
        members acc !count j
          | j >= limit || at j /= 0x22 = Refused
          | otherwise = case string (j + 1) of
              Refused -> Refused
              Step key k ->
                let l = skip k
                 in if l >= limit || at l /= 0x3a || repeated key
                      then Refused
                      else case value depth (skip (l + 1)) of
                        Refused -> Refused
                        Step item m ->
                          let n = skip m
                              acc' = (key, item) : acc
                           in if n >= limit
                                then Refused
                                else case at n of
                                  0x2c -> members acc' (count + 1) (skip (n + 1))
                                  0x7d
                                    | count < 16 || distinct acc' -> Step (Object (reverse acc')) (n + 1)
                                  _ -> Refused
          where
            -- Small objects check each name as it comes; larger ones once,
            -- at the end.
            repeated key = count < 16 && any ((== key) . fst) acc

        distinct pairs = Set.size (Set.fromList (map fst pairs)) == length pairs

    -- After the opening quote: the string and the offset after the closing
    -- quote.
    string :: Int -> Step Text
    string start = plain start
      where
        plain !j
          | j >= limit = Refused
          | otherwise = case at j of
              0x22 -> Step (TI.text array start (j - start)) (j + 1)
              0x5c -> escaped [TI.text array start (j - start)] j
              w | refusedByte w j -> Refused
              _ -> plain (j + 1)
        -- At a backslash, with the pieces so far, last first.
        escaped pieces !j
          | j + 1 >= limit = Refused
          | otherwise =
              let simple piece = rest (piece : pieces) (j + 2) (j + 2)
               in case at (j + 1) of
                    0x22 -> simple "\""
                    0x5c -> simple "\\"
                    0x2f -> simple "/"
                    0x62 -> simple "\b"
                    0x66 -> simple "\f"
                    0x6e -> simple "\n"
                    0x72 -> simple "\r"
                    0x74 -> simple "\t"
                    0x75 -> case hex4 (j + 2) of
                      Just code
                        | code < 0xd800 || code > 0xdfff ->
                            rest (T.singleton (chr code) : pieces) (j + 6) (j + 6)
                      _ -> Refused
                    _ -> Refused
        -- Unescaped bytes from runStart, scanning at j.
        rest pieces !runStart !j
          | j >= limit = Refused
          | otherwise = case at j of
              0x22 -> Step (T.concat (reverse (TI.text array runStart (j - runStart) : pieces))) (j + 1)
              0x5c -> escaped (TI.text array runStart (j - runStart) : pieces) j
              w | refusedByte w j -> Refused
              _ -> rest pieces runStart (j + 1)

    -- A control character, or the start of a surrogate's WTF-8 sequence
    -- (@ED A0@ to @ED BF@), which only a WTF-8 'Text' holds.
    refusedByte w j = w < 0x20 || (w == 0xed && j + 1 < limit && at (j + 1) >= 0xa0)

    hex4 j
      | j + 4 > limit = Nothing
      | otherwise = go 0 (0 :: Int)
      where
        go k !acc
          | k == 4 = Just acc
          | otherwise = case hexDigit (at (j + k)) of
              Just d -> go (k + 1) (acc `shiftL` 4 .|. d)
              Nothing -> Nothing

    hexDigit w
      | w >= 0x30 && w <= 0x39 = Just (fromIntegral w - 0x30)
      | w >= 0x61 && w <= 0x66 = Just (fromIntegral w - 0x61 + 10)
      | w >= 0x41 && w <= 0x46 = Just (fromIntegral w - 0x41 + 10)
      | otherwise = Nothing
