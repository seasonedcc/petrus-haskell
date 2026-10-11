-- | A fast path for @json.loads(text)@ over the documents providers return.
--
-- 'fastLoads' decodes the common subset of JSON directly into Python
-- values: objects without repeated keys, arrays, strings whose escapes are
-- not surrogates and contain no control characters, integers of up to 4000
-- digits, @true@, @false@ and @null@, at most 500 levels deep, with JSON
-- whitespace around. Within that subset @json.loads@ has exactly one result,
-- which is what 'fastLoads' returns. For anything else (floats, @NaN@ and
-- the infinities, repeated keys, surrogate escapes, every malformed
-- document) it returns 'Nothing' and the caller uses the reference loader,
-- 'Hamsterdan.Export.Python.loadsText', which reproduces CPython's values
-- and errors in full. The test suite checks the two agree, and agree with
-- CPython, on every document the fast path accepts.
--
-- It reads the text's UTF-8 array in place: a string without escapes is a
-- slice of the document, not a copy.
module Hamsterdan.Operator.FastJson
  ( fastLoads
  ) where

import Data.Bits (shiftL, (.|.))
import Data.Char (chr)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Array qualified as A
import Data.Text.Internal (Text (..))
import Data.Word (Word8)
import Hamsterdan.Export.Python (PV (..))

-- | A parsed value and the offset after it, or a refusal.
data Step a = Step a {-# UNPACK #-} !Int | Refused

-- | The document's value, or 'Nothing' when it is outside the subset.
fastLoads :: Text -> Maybe PV
fastLoads (Text array offset len) = case value 0 (skip offset) of
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

    value :: Int -> Int -> Step PV
    value !depth !i
      | i >= limit = Refused
      | otherwise = case at i of
          0x22 -> case string (i + 1) of
            Step s j -> Step (PStr s) j
            Refused -> Refused
          0x7b | depth < 500 -> object (depth + 1) (skip (i + 1))
          0x5b | depth < 500 -> array' (depth + 1) (skip (i + 1))
          0x74 | matches i "true" -> Step (PBool True) (i + 4)
          0x66 | matches i "false" -> Step (PBool False) (i + 5)
          0x6e | matches i "null" -> Step PNone (i + 4)
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
            || count > 4000
            || (count > 1 && at start == 0x30)
            || (end < limit && (at end == 0x2e || at end == 0x65 || at end == 0x45))
            then Refused
            else
              let magnitude
                    | count <= 18 = toInteger (accumulate start end (0 :: Int))
                    | otherwise = accumulateBig start end 0
               in Step (PInt (if negative then negate magnitude else magnitude)) end

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
      | i < limit, at i == 0x5d = Step (PList []) (i + 1)
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
                    0x5d -> Step (PList (reverse (item : acc))) (l + 1)
                    _ -> Refused

    object depth i
      | i < limit, at i == 0x7d = Step (PDict []) (i + 1)
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
                                    | count < 16 || distinct acc' -> Step (PDict (reverse acc')) (n + 1)
                                  _ -> Refused
          where
            -- Small objects check each key as it comes; larger ones once,
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
              0x22 -> Step (Text array start (j - start)) (j + 1)
              0x5c -> escaped [Text array start (j - start)] j
              w | w < 0x20 -> Refused
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
              0x22 -> Step (T.concat (reverse (Text array runStart (j - runStart) : pieces))) (j + 1)
              0x5c -> escaped (Text array runStart (j - runStart) : pieces) j
              w | w < 0x20 -> Refused
              _ -> rest pieces runStart (j + 1)

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
