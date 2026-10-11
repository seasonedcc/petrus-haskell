-- | Python text semantics needed to reproduce upstream bytes and messages.
--
-- File names travel through Python as @str@ values decoded from the file
-- system encoding (UTF-8) with the @surrogateescape@ error handler.  That
-- decoding is a bijection, so this package keeps names as raw bytes and only
-- decodes them (petrus-json's 'fsDecode', a WTF-8 'T.Text' that keeps the
-- escapes) when Python would observe code points: for sorting, for @repr@ in
-- error messages, for the ASCII "replace" encoding used in ustar header
-- fields, and for the numbers in pax headers.
module Petrus.Motus.Execution.Internal.PyText
  ( -- * Names as Python sees them
    isStrictUtf8
  , codePointSortKey
  , codePointLength
  , asciiReplace
  , nameRepr
  , textModeDecode
    -- * int() / float()
  , pyIntBytes
  , pyFloat
  , pyIntError
  , pyIntBytesError
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Char (chr, isDigit, ord, toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json.Python (decodeUtf8Python, fsDecode, isPythonNumberSpace, parsePythonInt, pythonDecimal, pythonReprBytes, pythonStrRepr)

-- | Whether the bytes decode under strict UTF-8 (no surrogate escapes).
isStrictUtf8 :: ByteString -> Bool
isStrictUtf8 = B.isValidUtf8

-- | A byte string whose lexicographic order equals CPython's code-point
-- order of the surrogate-escaped decoding: the decoding's WTF-8 bytes
-- (a surrogate is spelled like any other code point, so byte order is
-- code-point order). Valid UTF-8 maps to itself.
codePointSortKey :: ByteString -> ByteString
codePointSortKey bytes
  | isStrictUtf8 bytes = bytes
  | otherwise = TE.encodeUtf8 (fsDecode bytes)

-- | Number of code points Python sees in the surrogate-escaped decoding.
codePointLength :: ByteString -> Int
codePointLength bytes
  | B.all (< 0x80) bytes = B.length bytes
  | otherwise = T.length (fsDecode bytes)

-- | Python's @s.encode("ascii", "replace")@ of the surrogate-escaped
-- decoding: every non-ASCII code point (including escapes) becomes @?@.
asciiReplace :: ByteString -> ByteString
asciiReplace bytes
  | B.all (< 0x80) bytes = bytes
  | otherwise = BC.pack (T.unpack (T.map (\c -> if c < '\x80' then c else '?') (fsDecode bytes)))

-- | @repr()@ of the @str@ Python holds for a file name.
nameRepr :: ByteString -> Text
nameRepr = pythonStrRepr . fsDecode

-- | Bytes read in text mode (@Path.read_text()@, @subprocess.run(text=True)@):
-- strict UTF-8, failing with the @UnicodeDecodeError@'s text, then universal
-- newlines.
textModeDecode :: ByteString -> Either Text Text
textModeDecode = fmap (T.replace "\r" "\n" . T.replace "\r\n" "\n") . decodeUtf8Python

-- | CPython's @int(b)@ for a @bytes@ value (ASCII digits, ASCII whitespace).
pyIntBytes :: ByteString -> Maybe Integer
pyIntBytes bytes
  | B.any (>= 0x80) bytes = Nothing
  | otherwise = parsePythonInt 10 (TE.decodeLatin1 bytes)

-- | The 'ValueError' message CPython gives for @int(s)@.
pyIntError :: Text -> String
pyIntError s = "invalid literal for int() with base 10: " ++ T.unpack (pythonStrRepr s)

-- | The 'ValueError' message CPython gives for @int(b)@.
pyIntBytesError :: ByteString -> String
pyIntBytesError b = "invalid literal for int() with base 10: " ++ pythonReprBytes b

-- | CPython's @float(s)@ for the forms tar headers carry; 'Nothing' when
-- CPython raises 'ValueError'.
pyFloat :: Text -> Maybe Double
pyFloat raw = do
  let stripped = T.unpack (T.dropAround isPythonNumberSpace raw)
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
    asciiDigit c = case pythonDecimal c of
      Just d -> Just (chr (ord '0' + d))
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
