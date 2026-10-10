-- | Recognizing JSON text that is already in @JSON.stringify@ form.
--
-- The relays answer every message with
-- @JSON.stringify(Object.assign(JSON.parse(raw), {id}))@. Almost every
-- client (the browser, the MCP server, other relays) sends what
-- @JSON.stringify@ printed, and for such text @JSON.stringify(JSON.parse(raw))
-- == raw@: the relay then only has to splice the id member in. This module
-- decides, in one allocation-light pass, whether a text is such a fixed
-- point, and reports the byte spans of its top-level members. Anything it
-- does not accept goes through the full 'Petrus.Viewer.Json.parseJs' and
-- 'Petrus.Viewer.Json.encodeJs' round trip, so it only has to be sound (never
-- accept a text that the round trip would change), not complete.
--
-- A text is accepted when it has no whitespace outside strings, every
-- string is spelled the way @JSON.stringify@ escapes it (only @\\\"@,
-- @\\\\@, @\\b@, @\\f@, @\\n@, @\\r@, @\\t@, lowercase @\\u00XX@ for the
-- other control characters, and lowercase @\\uXXXX@ for lone surrogates),
-- every number is its own canonical ECMAScript spelling, and no object has
-- a duplicate key or an array-index key (which @JSON.parse@ would reorder).
module Petrus.Viewer.Json.Canonical
  ( Member (..)
  , canonicalObject
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Unsafe qualified as BU
import Data.List (sort)
import Data.Word (Word8)
import Petrus.Viewer.Json.Number (canonicalLiteral)

-- | A top-level member: the key (canonical escaped bytes, without quotes)
-- and the byte span @[start, end)@ of its value in the text.
data Member = Member
  { memberKey :: ByteString
  , memberStart :: Int
  , memberEnd :: Int
  }
  deriving stock (Eq, Show)

-- | The members of a JSON object text that @JSON.stringify(JSON.parse(raw))@
-- reproduces byte for byte, in order; 'Nothing' for any other text.
canonicalObject :: ByteString -> Maybe [Member]
canonicalObject raw
  | len < 2 || at 0 /= 0x7b = Nothing
  | at 1 == 0x7d = if len == 2 then Just [] else Nothing
  | otherwise = top 1 []
  where
    len = B.length raw
    at :: Int -> Word8
    at = BU.unsafeIndex raw
    {-# INLINE at #-}
    slice a b = BU.unsafeTake (b - a) (BU.unsafeDrop a raw)

    -- i points at the opening quote of a top-level key
    top i acc
      | i < len && at i == 0x22 =
          let ke = string (i + 1)
           in if ke < 0 || ke >= len || at ke /= 0x3a
                then Nothing
                else
                  let ve = value (ke + 1)
                      acc' = Member (slice (i + 1) (ke - 1)) (ke + 1) ve : acc
                   in if ve < 0 || ve >= len
                        then Nothing
                        else case at ve of
                          0x2c -> top (ve + 1) acc'
                          0x7d
                            | ve + 1 == len
                            , keysOk (map memberKey acc') ->
                                Just (reverse acc')
                          _ -> Nothing
      | otherwise = Nothing

    -- every scanner returns the index just past what it accepted, or -1
    value :: Int -> Int
    value i
      | i >= len = -1
      | otherwise = case at i of
          0x7b -> object (i + 1)
          0x5b -> array (i + 1)
          0x22 -> string (i + 1)
          0x74 -> literal i "true"
          0x66 -> literal i "false"
          0x6e -> literal i "null"
          w | w == 0x2d || isDigit w -> number i
          _ -> -1

    literal i word
      | slice i (min len (i + n)) == word = i + n
      | otherwise = -1
      where
        n = B.length word

    object i
      | i < len && at i == 0x7d = i + 1
      | otherwise = members i []

    members i keys
      | i < len && at i == 0x22 =
          let ke = string (i + 1)
           in if ke < 0 || ke >= len || at ke /= 0x3a
                then -1
                else
                  let ve = value (ke + 1)
                      keys' = slice (i + 1) (ke - 1) : keys
                   in if ve < 0 || ve >= len
                        then -1
                        else case at ve of
                          0x2c -> members (ve + 1) keys'
                          0x7d | keysOk keys' -> ve + 1
                          _ -> -1
      | otherwise = -1

    array i
      | i < len && at i == 0x5d = i + 1
      | otherwise = elements i

    elements i =
      let e = value i
       in if e < 0 || e >= len
            then -1
            else case at e of
              0x2c -> elements (e + 1)
              0x5d -> e + 1
              _ -> -1

    -- i is just past the opening quote
    string i
      | i >= len = -1
      | otherwise = case at i of
          0x22 -> i + 1
          0x5c -> escape (i + 1)
          w
            | w < 0x20 -> -1
            | otherwise -> string (i + 1)

    -- i is just past a backslash
    escape i
      | i >= len = -1
      | otherwise = case at i of
          w | w `elem` shortEscapes -> string (i + 1)
          0x75 -> case hex4 True (i + 1) of
            c
              | c < 0 -> -1
              | c < 0x20 && c `notElem` [0x08, 0x09, 0x0a, 0x0c, 0x0d] -> string (i + 5)
              | c >= 0xD800 && c <= 0xDBFF -> if lowFollows (i + 5) then -1 else string (i + 5)
              | c >= 0xDC00 && c <= 0xDFFF -> string (i + 5)
              | otherwise -> -1
          _ -> -1

    -- a high surrogate escape followed by a low one is a pair, which
    -- JSON.stringify prints as the character itself
    lowFollows j =
      j + 1 < len
        && at j == 0x5c
        && at (j + 1) == 0x75
        && let c = hex4 False (j + 2) in c >= 0xDC00 && c <= 0xDFFF

    -- four hex digits (lowercase only when canonical), or -1
    hex4 :: Bool -> Int -> Int
    hex4 lowerOnly i
      | i + 4 > len = -1
      | otherwise = go 0 0
      where
        go :: Int -> Int -> Int
        go k acc
          | k == 4 = acc
          | otherwise = case hexDigit lowerOnly (at (i + k)) of
              d | d < 0 -> -1
                | otherwise -> go (k + 1) ((acc `shiftL` 4) .|. d)

    number i =
      let i1 = if at i == 0x2d then i + 1 else i
       in if i1 >= len || not (isDigit (at i1))
            then -1
            else
              let i2 = if at i1 == 0x30 then i1 + 1 else digits (i1 + 1)
                  i3
                    | i2 < len && at i2 == 0x2e =
                        if i2 + 1 < len && isDigit (at (i2 + 1)) then digits (i2 + 2) else -1
                    | otherwise = i2
                  i4
                    | i3 >= 0 && i3 < len && (at i3 == 0x65 || at i3 == 0x45) =
                        let s = i3 + 1
                            s' = if s < len && (at s == 0x2b || at s == 0x2d) then s + 1 else s
                         in if s' < len && isDigit (at s') then digits (s' + 1) else -1
                    | otherwise = i3
               in if i4 < 0
                    then -1
                    else
                      let lit = slice i i4
                       in if fst (canonicalLiteral lit) == lit then i4 else -1

    digits i
      | i < len && isDigit (at i) = digits (i + 1)
      | otherwise = i

shortEscapes :: [Word8]
shortEscapes = [0x22, 0x5c, 0x62, 0x66, 0x6e, 0x72, 0x74]

isDigit :: Word8 -> Bool
isDigit w = w >= 0x30 && w <= 0x39
{-# INLINE isDigit #-}

hexDigit :: Bool -> Word8 -> Int
hexDigit lowerOnly w
  | isDigit w = fromIntegral (w - 0x30)
  | w >= 0x61 && w <= 0x66 = fromIntegral (w - 0x61 + 10)
  | not lowerOnly && w >= 0x41 && w <= 0x46 = fromIntegral (w - 0x41 + 10)
  | otherwise = -1

-- | No duplicates and no array-index keys (canonical key bytes).
keysOk :: [ByteString] -> Bool
keysOk keys = not (any isArrayIndex keys) && distinct
  where
    distinct = case keys of
      [] -> True
      [_] -> True
      _ | short keys (8 :: Int) -> pairwise keys
        | otherwise -> let s = sort keys in and (zipWith (/=) s (drop 1 s))
    short [] _ = True
    short _ 0 = False
    short (_ : r) n = short r (n - 1)
    pairwise [] = True
    pairwise (k : r) = notElem k r && pairwise r

-- | ECMAScript array index: canonical decimal of an integer in [0, 2^32 - 2].
isArrayIndex :: ByteString -> Bool
isArrayIndex b =
  let n = B.length b
   in n > 0
        && n <= 10
        && B.all isDigit b
        && (n == 1 || BU.unsafeHead b /= 0x30)
        && B.foldl' (\acc w -> acc * 10 + toInteger (w - 0x30)) 0 b <= (4294967294 :: Integer)
