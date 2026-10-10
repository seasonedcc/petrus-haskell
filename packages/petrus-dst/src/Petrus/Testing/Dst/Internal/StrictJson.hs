{-# LANGUAGE MultiWayIf #-}

-- | The reference's strict JSON loader for DST payloads.
--
-- The reference loads artifacts, run specs, and progress frames with
-- @json.loads(payload, object_pairs_hook=_strict_object,
-- parse_constant=_refuse_constant)@. This module reproduces that admission
-- and, on refusal, the exact CPython error text:
--
-- * the payload is decoded the way @json.loads(bytes)@ decodes it
--   (@json.detect_encoding@, then UTF-8, UTF-8 with signature, UTF-16, or
--   UTF-32 with @surrogatepass@), so a UTF-16 artifact is admitted exactly
--   as the reference admits it and invalid UTF-8 reports CPython's codec
--   message;
-- * duplicate members, @NaN@/@Infinity@ constants, integer tokens beyond
--   CPython's 4300-digit conversion limit, and every syntax error are
--   reported with CPython's message and character position, in the order
--   CPython's scanner meets them.
--
-- Admission uses the @petrus-json@ parser; only refusals take the slower
-- diagnostic scanner, which mirrors CPython's @json.decoder@ step by step.
--
-- One documented divergence remains: CPython admits lone UTF-16 surrogates
-- (from @\\ud800@ escapes or @surrogatepass@ decoding); 'Data.Text.Text'
-- cannot hold them, so such payloads are refused here.
module Petrus.Testing.Dst.Internal.StrictJson
  ( loadStrictJson
  , pythonDecodeBytes
  ) where

import Data.Array.Unboxed (UArray, bounds, listArray, (!))
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr, isHexDigit, ord)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Numeric (showHex)
import Petrus.Json (DuplicateMembers (..), Json (..), ParseOptions (..), parseJson, pythonLoads)
import Petrus.Testing.Dst.PyRepr (pyStrRepr)

-- | Load one strict DST JSON document. A refusal carries the text of the
-- Python exception the reference wraps (without its
-- @invalid strict DST …:@ prefix).
loadStrictJson :: ByteString -> Either Text Json
loadStrictJson payload = case pythonDecodeBytes payload of
  Left message -> Left message
  Right (Utf8Direct body) -> admit (parseJson options body) (lazyText body)
  Right (Decoded text) -> admit (parseJson options (TE.encodeUtf8 text)) (const text)
  where
    admit parsed text = case parsed of
      Right value
        | not (hasHugeInteger value) -> Right value
      Right _ -> Left (diagnoseOr "integer conversion limit" (text ()))
      Left message -> Left (diagnoseOr (T.pack message) (text ()))
    lazyText body () = TE.decodeUtf8 body
    diagnoseOr fallback text = maybe fallback id (diagnose text)

options :: ParseOptions
options =
  pythonLoads
    { duplicateMembers = RejectDuplicates
    , allowNonFiniteConstants = False
    }

-- | CPython's @sys.get_int_max_str_digits()@ default.
maxIntDigits :: Int
maxIntDigits = 4300

hasHugeInteger :: Json -> Bool
hasHugeInteger = \case
  Int i -> abs i >= 10 ^ maxIntDigits
  Array items -> any hasHugeInteger items
  Object members -> any (hasHugeInteger . snd) members
  _ -> False

-- ---------------------------------------------------------------------------
-- Byte decoding: json.detect_encoding plus the codec, with surrogatepass.

data DecodedPayload
  = -- | Plain UTF-8 without a signature: parse the original bytes.
    Utf8Direct ByteString
  | Decoded Text

-- | Decode JSON bytes as @json.loads@ does, or return CPython's codec error.
pythonDecodeBytes :: ByteString -> Either Text DecodedPayload
pythonDecodeBytes b
  | BS.isPrefixOf "\x00\x00\xFE\xFF" b = utf32 "utf-32" True (BS.drop 4 b) 4
  | BS.isPrefixOf "\xFF\xFE\x00\x00" b = utf32 "utf-32" False (BS.drop 4 b) 4
  | BS.isPrefixOf "\xFE\xFF" b = utf16 "utf-16" True (BS.drop 2 b) 2
  | BS.isPrefixOf "\xFF\xFE" b = utf16 "utf-16" False (BS.drop 2 b) 2
  | BS.isPrefixOf "\xEF\xBB\xBF" b = Decoded <$> utf8 (BS.drop 3 b)
  | BS.length b >= 4 =
      if
        | BS.index b 0 == 0 ->
            if BS.index b 1 /= 0 then utf16 "utf-16-be" True b 0 else utf32 "utf-32-be" True b 0
        | BS.index b 1 == 0 ->
            if BS.index b 2 /= 0 || BS.index b 3 /= 0
              then utf16 "utf-16-le" False b 0
              else utf32 "utf-32-le" False b 0
        | otherwise -> direct
  | BS.length b == 2 =
      if
        | BS.index b 0 == 0 -> utf16 "utf-16-be" True b 0
        | BS.index b 1 == 0 -> utf16 "utf-16-le" False b 0
        | otherwise -> direct
  | otherwise = direct
  where
    direct = case TE.decodeUtf8' b of
      Right _ -> Right (Utf8Direct b)
      Left _ -> Left (utf8Failure b)
    utf8 body = case TE.decodeUtf8' body of
      Right text -> Right text
      Left _ -> Left (utf8Failure body)

-- | CPython's strict UTF-8 decoder error for an invalid payload, with the
-- @surrogatepass@ handler's acceptance of encoded surrogates.
utf8Failure :: ByteString -> Text
utf8Failure b = go 0
  where
    len = BS.length b
    at = BS.index b
    cont w = w >= 0x80 && w <= 0xBF
    go i
      | i >= len = "the payload contains a lone UTF-16 surrogate, which this port cannot represent"
      | otherwise =
          let w = at i
           in if
                | w < 0x80 -> go (i + 1)
                | w >= 0xC2 && w <= 0xDF -> sequenceOf i [cont]
                | w == 0xE0 -> sequenceOf i [\x -> x >= 0xA0 && x <= 0xBF, cont]
                | w == 0xED -> surrogateOr i
                | w >= 0xE1 && w <= 0xEF -> sequenceOf i [cont, cont]
                | w == 0xF0 -> sequenceOf i [\x -> x >= 0x90 && x <= 0xBF, cont, cont]
                | w >= 0xF1 && w <= 0xF3 -> sequenceOf i [cont, cont, cont]
                | w == 0xF4 -> sequenceOf i [\x -> x >= 0x80 && x <= 0x8F, cont, cont]
                | otherwise -> failure i (i + 1) "invalid start byte"
    sequenceOf i checks = step 1 checks
      where
        step _ [] = go (i + length checks + 1)
        step k (check : rest)
          | i + k >= len = failure i len "unexpected end of data"
          | check (at (i + k)) = step (k + 1) rest
          | otherwise = failure i (i + k) "invalid continuation byte"
    surrogateOr i
      | i + 2 < len, at (i + 1) >= 0xA0, at (i + 1) <= 0xBF, cont (at (i + 2)) =
          -- surrogatepass decodes an encoded surrogate; Text cannot hold it.
          "the payload contains a lone UTF-16 surrogate, which this port cannot represent"
      | otherwise = sequenceOf i [\x -> x >= 0x80 && x <= 0x9F, cont]
    failure start end reason = codecError "utf-8" start end reason (at start)

codecError :: Text -> Int -> Int -> Text -> Word8 -> Text
codecError codec start end reason first
  | end - start == 1 =
      "'" <> codec <> "' codec can't decode byte 0x" <> hex2 first <> " in position " <> tshow start <> ": " <> reason
  | otherwise =
      "'" <> codec <> "' codec can't decode bytes in position " <> tshow start <> "-" <> tshow (end - 1) <> ": " <> reason
  where
    hex2 w = let h = showHex w "" in T.pack (replicate (2 - length h) '0' ++ h)

utf16 :: Text -> Bool -> ByteString -> Int -> Either Text DecodedPayload
utf16 codec bigEndian body offset = go 0 []
  where
    len = BS.length body
    unit i =
      let a = fromIntegral (BS.index body i) :: Int
          z = fromIntegral (BS.index body (i + 1)) :: Int
       in if bigEndian then a `shiftL` 8 .|. z else z `shiftL` 8 .|. a
    go i acc
      | i == len = Right (Decoded (T.pack (reverse acc)))
      | i + 1 >= len = Left (codecError codec (offset + i) (offset + len) "truncated data" (BS.index body i))
      | otherwise =
          let u = unit i
           in if
                | u >= 0xD800 && u <= 0xDBFF ->
                    if i + 3 < len && unit (i + 2) >= 0xDC00 && unit (i + 2) <= 0xDFFF
                      then go (i + 4) (chr (0x10000 + ((u - 0xD800) `shiftL` 10) .|. (unit (i + 2) - 0xDC00)) : acc)
                      else Left loneSurrogate
                | u >= 0xDC00 && u <= 0xDFFF -> Left loneSurrogate
                | otherwise -> go (i + 2) (chr u : acc)

utf32 :: Text -> Bool -> ByteString -> Int -> Either Text DecodedPayload
utf32 codec bigEndian body offset = go 0 []
  where
    len = BS.length body
    byte i = fromIntegral (BS.index body i) :: Int
    unit i =
      if bigEndian
        then byte i `shiftL` 24 .|. byte (i + 1) `shiftL` 16 .|. byte (i + 2) `shiftL` 8 .|. byte (i + 3)
        else byte (i + 3) `shiftL` 24 .|. byte (i + 2) `shiftL` 16 .|. byte (i + 1) `shiftL` 8 .|. byte i
    go i acc
      | i == len = Right (Decoded (T.pack (reverse acc)))
      | i + 3 >= len = Left (codecError codec (offset + i) (offset + len) "truncated data" (BS.index body i))
      | otherwise =
          let u = unit i
           in if
                | u > 0x10FFFF -> Left (codecError codec (offset + i) (offset + i + 4) "code point not in range(0x110000)" (BS.index body i))
                | u >= 0xD800 && u <= 0xDFFF -> Left loneSurrogate
                | otherwise -> go (i + 4) (chr u : acc)

loneSurrogate :: Text
loneSurrogate = "the payload contains a lone UTF-16 surrogate, which this port cannot represent"

-- ---------------------------------------------------------------------------
-- The diagnostic scanner: CPython's json.decoder, reporting the first error.

type Doc = UArray Int Char

data Failure
  = -- | A @JSONDecodeError@ with message and character position.
    Decode Text Int
  | -- | A plain @ValueError@ (hook, constant, or integer-limit refusal).
    Plain Text

-- | The text of the first error CPython would raise for this document, or
-- 'Nothing' when CPython would admit it.
diagnose :: Text -> Maybe Text
diagnose text = case document of
  Left (Decode message pos) -> Just (decodeError message pos)
  Left (Plain message) -> Just message
  Right () -> Nothing
  where
    s :: Doc
    s = listArray (0, T.length text - 1) (T.unpack text)
    len = let (_, hi) = bounds s in hi + 1
    charAt i = if i >= 0 && i < len then Just (s ! i) else Nothing
    isWs c = c == ' ' || c == '\t' || c == '\n' || c == '\r'
    skipWs i = case charAt i of
      Just c | isWs c -> skipWs (i + 1)
      _ -> i
    startsWith i lit = and [charAt (i + k) == Just c | (k, c) <- zip [0 ..] lit]

    document = do
      end <- stop "Expecting value" (scanOnce (skipWs 0))
      let end' = skipWs end
      if end' /= len then Left (Decode "Extra data" end') else Right ()

    decodeError message pos =
      let before = take pos (T.unpack text)
          lineno = length (filter (== '\n') before) + 1
          colno = case lastNewline before of
            Nothing -> pos + 1
            Just n -> pos - n
       in message <> ": line " <> tshow lineno <> " column " <> tshow colno <> " (char " <> tshow pos <> ")"
    lastNewline before = case [k | (k, c) <- zip [0 ..] before, c == '\n'] of
      [] -> Nothing
      ks -> Just (last ks)

    -- scan_once: Left (Left pos) is StopIteration(pos).
    stop message = either (Left . either (Decode message) id) Right
    scanOnce :: Int -> Either (Either Int Failure) Int
    scanOnce i = case charAt i of
      Nothing -> Left (Left i)
      Just '"' -> fail' (snd <$> scanString (i + 1))
      Just '{' -> fail' (parseObject (i + 1))
      Just '[' -> fail' (parseArray (i + 1))
      Just 'n' | startsWith i "null" -> Right (i + 4)
      Just 't' | startsWith i "true" -> Right (i + 4)
      Just 'f' | startsWith i "false" -> Right (i + 5)
      Just 'N' | startsWith i "NaN" -> Left (Right (Plain "non-finite JSON number NaN"))
      Just 'I' | startsWith i "Infinity" -> Left (Right (Plain "non-finite JSON number Infinity"))
      Just '-' | startsWith i "-Infinity" -> Left (Right (Plain "non-finite JSON number -Infinity"))
      _ -> matchNumber i
    fail' = either (Left . Right) Right

    matchNumber :: Int -> Either (Either Int Failure) Int
    matchNumber start = do
      let afterSign = if charAt start == Just '-' then start + 1 else start
      intEnd <- case charAt afterSign of
        Just c | c >= '1' && c <= '9' -> Right (digitsFrom (afterSign + 1))
        Just '0' -> Right (afterSign + 1)
        _ -> Left (Left start)
      let fracEnd = case (charAt intEnd, charAt (intEnd + 1)) of
            (Just '.', Just c) | isDigit c -> digitsFrom (intEnd + 2)
            _ -> intEnd
          expEnd = case charAt fracEnd of
            Just c
              | c == 'e' || c == 'E' ->
                  let signed = case charAt (fracEnd + 1) of
                        Just x | x == '+' || x == '-' -> fracEnd + 2
                        _ -> fracEnd + 1
                   in case charAt signed of
                        Just d | isDigit d -> digitsFrom (signed + 1)
                        _ -> fracEnd
            _ -> fracEnd
          digits = intEnd - afterSign
      if fracEnd == intEnd && expEnd == fracEnd && digits > maxIntDigits
        then
          Left
            ( Right
                ( Plain
                    ( "Exceeds the limit ("
                        <> tshow maxIntDigits
                        <> " digits) for integer string conversion: value has "
                        <> tshow digits
                        <> " digits; use sys.set_int_max_str_digits() to increase the limit"
                    )
                )
            )
        else Right expEnd
    isDigit c = c >= '0' && c <= '9'
    digitsFrom i = case charAt i of
      Just c | isDigit c -> digitsFrom (i + 1)
      _ -> i

    -- scanstring with strict=True; returns the decoded key and the end.
    scanString :: Int -> Either Failure (Text, Int)
    scanString start = go start []
      where
        begin = start - 1
        go i acc = case charAt i of
          Nothing -> Left (Decode "Unterminated string starting at" begin)
          Just '"' -> Right (T.pack (reverse acc), i + 1)
          Just '\\' -> case charAt (i + 1) of
            Nothing -> Left (Decode "Unterminated string starting at" begin)
            Just 'u' -> do
              high <- hex4 (i + 1)
              if high >= 0xD800 && high <= 0xDBFF && charAt (i + 6) == Just '\\' && charAt (i + 7) == Just 'u'
                then do
                  low <- hex4 (i + 7)
                  if low >= 0xDC00 && low <= 0xDFFF
                    then go (i + 12) (chr (0x10000 + ((high - 0xD800) `shiftL` 10) .|. (low - 0xDC00)) : acc)
                    else go (i + 6) (surrogateChar high : acc)
                else go (i + 6) (surrogateChar high : acc)
            Just c -> case lookup c escapes of
              Just e -> go (i + 2) (e : acc)
              Nothing -> Left (Decode "Invalid \\escape" i)
          Just c
            | c < '\x20' -> Left (Decode "Invalid control character at" i)
            | otherwise -> go (i + 1) (c : acc)
        -- A lone surrogate stands in as U+FFFD for key comparison only.
        surrogateChar n = if n >= 0xD800 && n <= 0xDFFF then '\xFFFD' else chr n
        -- CPython's C scanner requires one more character after the four
        -- digits before it reads them.
        hex4 u
          | u + 5 >= len = Left (Decode "Invalid \\uXXXX escape" u)
          | all (maybe False isHexDigit . charAt) [u + 1 .. u + 4] =
              Right (foldl (\acc k -> acc * 16 + hexValue (s ! k)) 0 [u + 1 .. u + 4])
          | otherwise = Left (Decode "Invalid \\uXXXX escape" u)
        hexValue c
          | c >= '0' && c <= '9' = ord c - 48
          | c >= 'a' && c <= 'f' = ord c - 87
          | otherwise = ord c - 55
    escapes = [('"', '"'), ('\\', '\\'), ('/', '/'), ('b', '\b'), ('f', '\f'), ('n', '\n'), ('r', '\r'), ('t', '\t')]

    parseObject :: Int -> Either Failure Int
    parseObject open = do
      let first = skipWs open
      case charAt first of
        Just '}' -> Right (first + 1)
        Just '"' -> members (first + 1) Set.empty Nothing
        _ -> Left (Decode "Expecting property name enclosed in double quotes" first)
      where
        members keyStart seen duplicate = do
          (key, afterKey) <- scanString keyStart
          let colon = skipWs afterKey
          case charAt colon of
            Just ':' -> Right ()
            _ -> Left (Decode "Expecting ':' delimiter" colon)
          let valueStart = skipWs (colon + 1)
          end <- stop "Expecting value" (scanOnce valueStart)
          let duplicate' = case duplicate of
                Nothing | Set.member key seen -> Just key
                _ -> duplicate
              seen' = Set.insert key seen
              next = skipWs end
          case charAt next of
            Just '}' -> case duplicate' of
              Just k -> Left (Plain ("duplicate JSON field " <> pyStrRepr k))
              Nothing -> Right (next + 1)
            Just ',' -> do
              let afterComma = skipWs (next + 1)
              case charAt afterComma of
                Just '"' -> members (afterComma + 1) seen' duplicate'
                Just '}' -> Left (Decode "Illegal trailing comma before end of object" next)
                _ -> Left (Decode "Expecting property name enclosed in double quotes" afterComma)
            _ -> Left (Decode "Expecting ',' delimiter" next)

    parseArray :: Int -> Either Failure Int
    parseArray open = do
      let first = skipWs open
      case charAt first of
        Just ']' -> Right (first + 1)
        _ -> items first
      where
        items i = do
          end <- stop "Expecting value" (scanOnce i)
          let next = skipWs end
          case charAt next of
            Just ']' -> Right (next + 1)
            Just ',' -> do
              let afterComma = skipWs (next + 1)
              case charAt afterComma of
                Just ']' -> Left (Decode "Illegal trailing comma before end of array" next)
                _ -> items afterComma
            _ -> Left (Decode "Expecting ',' delimiter" next)

tshow :: (Show a) => a -> Text
tshow = T.pack . show
