-- | Python text semantics needed to reproduce upstream bytes and messages.
--
-- File names travel through Python as @str@ values decoded from the file
-- system encoding (UTF-8) with the @surrogateescape@ error handler.  That
-- decoding is a bijection, so this package keeps names as raw bytes and only
-- decodes them here when Python would observe code points: for sorting, for
-- @repr@ in error messages, and for the ASCII "replace" encoding used in
-- ustar header fields.
module Petrus.Motus.Execution.Internal.PyText
  ( -- * Surrogate-escape decoding
    decodeSurrogateEscape
  , encodeSurrogateEscape
  , isStrictUtf8
  , codePointSortKey
  , codePointLength
  , asciiReplace
    -- * repr
  , pyStrRepr
  , pyBytesRepr
  , pyListRepr
    -- * int() / float()
  , pyInt
  , pyIntBytes
  , pyFloat
  , pyIntError
  , pyIntBytesError
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Char (chr, isDigit, ord, toLower)
import Data.List (dropWhileEnd)
import Data.Text qualified as T
import Data.Word (Word8)
import Petrus.Json.Python (isPythonSpace, pythonDecimal, pythonListRepr, pythonReprBytes, pythonStringRepr)

-- | Decode UTF-8 the way CPython does with @errors="surrogateescape"@: every
-- byte that does not begin a complete, valid UTF-8 sequence becomes the lone
-- surrogate @U+DC00 + byte@.
decodeSurrogateEscape :: ByteString -> String
decodeSurrogateEscape = go
  where
    go bytes = case B.uncons bytes of
      Nothing -> []
      Just (b0, rest)
        | b0 < 0x80 -> chr (fromIntegral b0) : go rest
        | otherwise -> case validSequence bytes of
            Just (c, n) -> c : go (B.drop n bytes)
            Nothing -> chr (0xDC00 + fromIntegral b0) : go rest

-- | Inverse of 'decodeSurrogateEscape' (Python's @encode("utf-8",
-- "surrogateescape")@ restricted to strings produced by that decoder).
encodeSurrogateEscape :: String -> ByteString
encodeSurrogateEscape = B.pack . concatMap encodeChar
  where
    encodeChar c
      | n >= 0xDC80 && n <= 0xDCFF = [fromIntegral (n - 0xDC00)]
      | otherwise = utf8Generalized n
      where
        n = ord c

-- | One valid UTF-8 sequence at the head of the input, as CPython's strict
-- decoder accepts it (no overlongs, no surrogates, nothing above U+10FFFF).
validSequence :: ByteString -> Maybe (Char, Int)
validSequence bytes = case B.unpack (B.take 4 bytes) of
  (b0 : b1 : _)
    | b0 >= 0xC2 && b0 <= 0xDF && cont b1 ->
        Just (chr (((fromIntegral b0 .&. 0x1F) `shiftL` 6) .|. low b1), 2)
  (b0 : b1 : b2 : _)
    | b0 == 0xE0 && b1 >= 0xA0 && b1 <= 0xBF && cont b2 -> three b0 b1 b2
    | b0 >= 0xE1 && b0 <= 0xEC && cont b1 && cont b2 -> three b0 b1 b2
    | b0 == 0xED && b1 >= 0x80 && b1 <= 0x9F && cont b2 -> three b0 b1 b2
    | b0 >= 0xEE && b0 <= 0xEF && cont b1 && cont b2 -> three b0 b1 b2
  (b0 : b1 : b2 : b3 : _)
    | b0 == 0xF0 && b1 >= 0x90 && b1 <= 0xBF && cont b2 && cont b3 -> four b0 b1 b2 b3
    | b0 >= 0xF1 && b0 <= 0xF3 && cont b1 && cont b2 && cont b3 -> four b0 b1 b2 b3
    | b0 == 0xF4 && b1 >= 0x80 && b1 <= 0x8F && cont b2 && cont b3 -> four b0 b1 b2 b3
  _ -> Nothing
  where
    cont b = b >= 0x80 && b <= 0xBF
    low b = fromIntegral b .&. 0x3F :: Int
    three b0 b1 b2 =
      Just (chr (((fromIntegral b0 .&. 0x0F) `shiftL` 12) .|. (low b1 `shiftL` 6) .|. low b2), 3)
    four b0 b1 b2 b3 =
      Just
        ( chr
            ( ((fromIntegral b0 .&. 0x07) `shiftL` 18)
                .|. (low b1 `shiftL` 12)
                .|. (low b2 `shiftL` 6)
                .|. low b3
            )
        , 4
        )

-- | Whether the bytes decode under strict UTF-8 (no surrogate escapes).
isStrictUtf8 :: ByteString -> Bool
isStrictUtf8 bytes = case B.uncons bytes of
  Nothing -> True
  Just (b0, rest)
    | b0 < 0x80 -> isStrictUtf8 (B.dropWhile (< 0x80) rest)
    | otherwise -> case validSequence bytes of
        Just (_, n) -> isStrictUtf8 (B.drop n bytes)
        Nothing -> False

-- | A byte string whose lexicographic order equals CPython's code-point
-- order of the surrogate-escaped decoding.  Valid UTF-8 maps to itself.
codePointSortKey :: ByteString -> ByteString
codePointSortKey bytes
  | B.all (< 0x80) bytes || isStrictUtf8 bytes = bytes
  | otherwise = B.pack (concatMap (utf8Generalized . ord) (decodeSurrogateEscape bytes))

-- | Number of code points Python sees in the surrogate-escaped decoding.
codePointLength :: ByteString -> Int
codePointLength bytes
  | B.all (< 0x80) bytes = B.length bytes
  | otherwise = length (decodeSurrogateEscape bytes)

-- | Python's @s.encode("ascii", "replace")@ of the surrogate-escaped
-- decoding: every non-ASCII code point (including escapes) becomes @?@.
asciiReplace :: ByteString -> ByteString
asciiReplace bytes
  | B.all (< 0x80) bytes = bytes
  | otherwise = BC.pack [if ord c < 0x80 then c else '?' | c <- decodeSurrogateEscape bytes]

-- | Generalized UTF-8 (surrogates encoded like any other code point); its
-- byte order is code-point order.
utf8Generalized :: Int -> [Word8]
utf8Generalized n
  | n < 0x80 = [fromIntegral n]
  | n < 0x800 = [0xC0 .|. hi 6, cont 0]
  | n < 0x10000 = [0xE0 .|. hi 12, cont 6, cont 0]
  | otherwise = [0xF0 .|. hi 18, cont 12, cont 6, cont 0]
  where
    hi s = fromIntegral (n `shiftR` s)
    cont s = 0x80 .|. (fromIntegral (n `shiftR` s) .&. 0x3F)

-- | CPython's @repr()@ of a @str@ that may hold surrogate escapes, as a
-- 'String' (petrus-json's 'pythonStringRepr').
pyStrRepr :: String -> String
pyStrRepr = T.unpack . pythonStringRepr

-- | CPython's @repr()@ of a @bytes@ object.
pyBytesRepr :: ByteString -> String
pyBytesRepr = pythonReprBytes

-- | CPython's @repr()@ of a list of strings.
pyListRepr :: [String] -> String
pyListRepr = T.unpack . pythonListRepr . map pythonStringRepr

-- | The decimal value of a Unicode decimal digit, as CPython's @int()@
-- accepts it.
decimalValue :: Char -> Maybe Integer
decimalValue = fmap fromIntegral . pythonDecimal

-- | CPython's @int(s)@ for a @str@ in base 10; 'Nothing' when CPython raises
-- 'ValueError'.
pyInt :: String -> Maybe Integer
pyInt raw = do
  let stripped = dropWhileEnd isPythonSpace (dropWhile isPythonSpace raw)
  (negative, body) <- case stripped of
    '-' : rest -> Just (True, rest)
    '+' : rest -> Just (False, rest)
    rest -> Just (False, rest)
  value <- digitsWithUnderscores body
  pure (if negative then negate value else value)
  where
    digitsWithUnderscores body = do
      firstChar : rest <- Just body
      d0 <- decimalValue firstChar
      loop d0 rest
    loop acc [] = Just acc
    loop acc ('_' : c : rest) = decimalValue c >>= \d -> loop (acc * 10 + d) rest
    loop acc (c : rest) = decimalValue c >>= \d -> loop (acc * 10 + d) rest

-- | CPython's @int(b)@ for a @bytes@ value (ASCII digits, ASCII whitespace).
pyIntBytes :: ByteString -> Maybe Integer
pyIntBytes bytes
  | B.any (>= 0x80) bytes = Nothing
  | otherwise = pyInt (BC.unpack bytes)

-- | The 'ValueError' message CPython gives for @int(s)@.
pyIntError :: String -> String
pyIntError s = "invalid literal for int() with base 10: " ++ pyStrRepr s

-- | The 'ValueError' message CPython gives for @int(b)@.
pyIntBytesError :: ByteString -> String
pyIntBytesError b = "invalid literal for int() with base 10: " ++ pyBytesRepr b

-- | CPython's @float(s)@ for the forms tar headers carry; 'Nothing' when
-- CPython raises 'ValueError'.
pyFloat :: String -> Maybe Double
pyFloat raw = do
  let stripped = dropWhileEnd isPythonSpace (dropWhile isPythonSpace raw)
      (sign, body) = case stripped of
        '-' : rest -> (negate, rest)
        '+' : rest -> (id, rest)
        rest -> (id, rest)
      lowered = map toLower body
  if lowered `elem` ["inf", "infinity"]
    then Just (sign (1 / 0))
    else
      if lowered == "nan"
        then Just (0 / 0)
        else sign <$> (traverse asciiDigit body >>= underscores >>= parseDecimal)
  where
    asciiDigit c = case decimalValue c of
      Just d -> Just (chr (ord '0' + fromIntegral d))
      Nothing -> Just c
    underscores s = go s
      where
        go (a : '_' : b : rest)
          | isDigit a && isDigit b = (a :) <$> go (b : rest)
          | otherwise = Nothing
        go ('_' : _) = Nothing
        go (c : rest) = (c :) <$> go rest
        go [] = Just []
    parseDecimal s = do
      let (intPart, afterInt) = span isDigit s
          (fracPart, afterFrac) = case afterInt of
            '.' : rest -> span isDigit rest
            _ -> ("", afterInt)
      if null intPart && null fracPart then Nothing else Just ()
      expPart <- case afterFrac of
        "" -> Just "0"
        e : rest | e == 'e' || e == 'E' -> case rest of
          '-' : ds | validExponent ds -> Just ('-' : ds)
          '+' : ds | validExponent ds -> Just ds
          ds | validExponent ds -> Just ds
          _ -> Nothing
        _ -> Nothing
      let expo = read expPart :: Integer
          zeroMantissa = all (== '0') (intPart ++ fracPart)
          literal =
            (if null intPart then "0" else intPart)
              ++ "."
              ++ (if null fracPart then "0" else fracPart)
              ++ "e"
              ++ show expo
      if zeroMantissa
        then Just 0
        else
          if expo > 400 + fromIntegral (length intPart)
            then Just (1 / 0)
            else
              if expo < -400 - fromIntegral (length fracPart)
                then Just 0
                else case reads literal of
                  [(value, "")] -> Just value
                  _ -> Nothing
    validExponent ds = not (null ds) && all isDigit ds
