-- | The JSON reader as it was before the decode-speed work (commit
-- 11b5375), kept verbatim as a test oracle: the property tests in
-- @test/Main.hs@ require the current 'Petrus.Json.parseJson' to give the
-- same value (spelling-exact) or the same refusal text on every input.
module Petrus.Json.ReferenceParse (referenceParseJson) where

import Control.Monad (when)
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BU
import Data.Char (chr)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Petrus.Json.Parse (DuplicateMembers (..), ParseOptions (..))
import Petrus.Json.Value

-- | Parse one complete JSON document.
referenceParseJson :: ParseOptions -> ByteString -> Either String Json
referenceParseJson options input
  | BS.isPrefixOf "\xEF\xBB\xBF" input = Left "Unexpected UTF-8 BOM (decode using utf-8-sig)"
  | otherwise = do
      (value, end) <- valueAt options input (skipSpace input 0)
      let rest = skipSpace input end
      when (rest < BS.length input) (Left ("Extra data at byte " ++ show rest))
      Right value

skipSpace :: ByteString -> Int -> Int
skipSpace input = go
  where
    go i
      | i < BS.length input, isSpace (BU.unsafeIndex input i) = go (i + 1)
      | otherwise = i
    isSpace w = w == 0x20 || w == 0x09 || w == 0x0A || w == 0x0D

byteAt :: ByteString -> Int -> Maybe Word8
byteAt input i
  | i < BS.length input = Just (BU.unsafeIndex input i)
  | otherwise = Nothing

expecting :: String -> Int -> Either String a
expecting what i = Left ("Expecting " ++ what ++ " at byte " ++ show i)

valueAt :: ParseOptions -> ByteString -> Int -> Either String (Json, Int)
valueAt options input i = case byteAt input i of
  Nothing -> expecting "value" i
  Just w -> case w of
    0x22 -> do
      (text, end) <- stringAt input (i + 1)
      Right (String text, end)
    0x7B -> objectAt options input (i + 1)
    0x5B -> arrayAt options input (i + 1)
    0x6E -> literal "null" Null
    0x74 -> literal "true" (Bool True)
    0x66 -> literal "false" (Bool False)
    0x4E -> constant "NaN" (0 / 0)
    0x49 -> constant "Infinity" (1 / 0)
    0x2D
      | BS.isPrefixOf "-Infinity" (BS.drop i input) -> constant "-Infinity" (-1 / 0)
    _
      | w == 0x2D || (w >= 0x30 && w <= 0x39) -> numberAt options input i
      | otherwise -> expecting "value" i
  where
    literal spelling value
      | BS.isPrefixOf spelling (BS.drop i input) = Right (value, i + BS.length spelling)
      | otherwise = expecting "value" i
    constant spelling value
      | not (BS.isPrefixOf spelling (BS.drop i input)) = expecting "value" i
      | allowNonFiniteConstants options = Right (Float value, i + BS.length spelling)
      | otherwise = Left ("non-finite JSON number " ++ show spelling)

objectAt :: ParseOptions -> ByteString -> Int -> Either String (Json, Int)
objectAt options input start = case byteAt input first of
  Just 0x7D -> Right (Object [], first + 1)
  _ -> members first [] Set.empty
  where
    first = skipSpace input start
    members i acc seen = do
      key <- case byteAt input i of
        Just 0x22 -> stringAt input (i + 1)
        _ -> expecting "property name enclosed in double quotes" i
      let (name, afterKey) = key
          colon = skipSpace input afterKey
      case byteAt input colon of
        Just 0x3A -> Right ()
        _ -> expecting "':' delimiter" colon
      (value, afterValue) <- valueAt options input (skipSpace input (colon + 1))
      (acc', seen') <-
        if Set.member name seen
          then case duplicateMembers options of
            RejectDuplicates -> Left ("duplicate JSON member " ++ show (T.unpack name))
            LastWins -> Right (replaceMember name value acc, seen)
          else Right ((name, value) : acc, Set.insert name seen)
      let next = skipSpace input afterValue
      case byteAt input next of
        Just 0x2C -> members (skipSpace input (next + 1)) acc' seen'
        Just 0x7D -> Right (Object (reverse acc'), next + 1)
        _ -> expecting "',' delimiter" next
    replaceMember name value = map (\member@(k, _) -> if k == name then (k, value) else member)

arrayAt :: ParseOptions -> ByteString -> Int -> Either String (Json, Int)
arrayAt options input start = case byteAt input first of
  Just 0x5D -> Right (Array [], first + 1)
  _ -> items first []
  where
    first = skipSpace input start
    items i acc = do
      (value, afterValue) <- valueAt options input i
      let next = skipSpace input afterValue
      case byteAt input next of
        Just 0x2C -> items (skipSpace input (next + 1)) (value : acc)
        Just 0x5D -> Right (Array (reverse (value : acc)), next + 1)
        _ -> expecting "',' delimiter" next

-- | Parse a string body starting just after the opening quote.
stringAt :: ByteString -> Int -> Either String (Text, Int)
stringAt input start = scan start
  where
    len = BS.length input
    -- Fast path: a run with no escapes decodes as one slice.
    scan i
      | i >= len = Left ("Unterminated string starting at byte " ++ show (start - 1))
      | otherwise = case BU.unsafeIndex input i of
          0x22 -> do
            text <- decodeSlice start i
            Right (text, i + 1)
          0x5C -> slow start i []
          w
            | w < 0x20 -> Left ("Invalid control character at byte " ++ show i)
            | otherwise -> scan (i + 1)
    decodeSlice from to = case TE.decodeUtf8' (BS.take (to - from) (BS.drop from input)) of
      Right text -> Right text
      Left _ -> Left "invalid UTF-8 in string"
    -- Slow path with escapes: accumulate decoded chunks.
    slow chunkStart i chunks
      | i >= len = Left ("Unterminated string starting at byte " ++ show (start - 1))
      | otherwise = case BU.unsafeIndex input i of
          0x22 -> do
            chunk <- decodeSlice chunkStart i
            Right (T.concat (reverse (chunk : chunks)), i + 1)
          0x5C -> do
            chunk <- decodeSlice chunkStart i
            (escaped, next) <- escapeAt (i + 1)
            slow next next (escaped : chunk : chunks)
          w
            | w < 0x20 -> Left ("Invalid control character at byte " ++ show i)
            | otherwise -> slow chunkStart (i + 1) chunks
    escapeAt i = case byteAt input i of
      Just 0x22 -> Right ("\"", i + 1)
      Just 0x5C -> Right ("\\", i + 1)
      Just 0x2F -> Right ("/", i + 1)
      Just 0x62 -> Right ("\b", i + 1)
      Just 0x66 -> Right ("\f", i + 1)
      Just 0x6E -> Right ("\n", i + 1)
      Just 0x72 -> Right ("\r", i + 1)
      Just 0x74 -> Right ("\t", i + 1)
      Just 0x75 -> do
        high <- hex4 (i + 1)
        if high >= 0xD800 && high <= 0xDBFF
          then case (byteAt input (i + 5), byteAt input (i + 6)) of
            (Just 0x5C, Just 0x75) -> do
              low <- hex4 (i + 7)
              if low >= 0xDC00 && low <= 0xDFFF
                then
                  Right
                    (T.singleton (chr (0x10000 + ((high - 0xD800) `shiftL` 10) .|. (low - 0xDC00))), i + 11)
                else surrogate
            _ -> surrogate
          else
            if high >= 0xDC00 && high <= 0xDFFF
              then surrogate
              else Right (T.singleton (chr high), i + 5)
      _ -> Left ("Invalid \\escape at byte " ++ show (i - 1))
    surrogate = Left "JSON strings must contain Unicode scalar values"
    hex4 i
      | i + 4 > len = Left ("Invalid \\uXXXX escape at byte " ++ show i)
      | otherwise = foldl step (Right 0) [i .. i + 3]
      where
        step acc j = do
          value <- acc
          digit <- hexDigit (BU.unsafeIndex input j)
          Right (value * 16 + digit)
        hexDigit w
          | w >= 0x30 && w <= 0x39 = Right (fromIntegral w - 0x30)
          | w >= 0x61 && w <= 0x66 = Right (fromIntegral w - 0x57)
          | w >= 0x41 && w <= 0x46 = Right (fromIntegral w - 0x37)
          | otherwise = Left ("Invalid \\uXXXX escape at byte " ++ show i)

-- | CPython's number grammar: @-?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?@.
numberAt :: ParseOptions -> ByteString -> Int -> Either String (Json, Int)
numberAt options input start = do
  let afterSign = if byteAt input start == Just 0x2D then start + 1 else start
  integerEnd <- case byteAt input afterSign of
    Just 0x30 -> Right (afterSign + 1)
    Just w | w >= 0x31 && w <= 0x39 -> Right (digitsFrom (afterSign + 1))
    _ -> expecting "value" start
  let fractionEnd = case (byteAt input integerEnd, byteAt input (integerEnd + 1)) of
        (Just 0x2E, Just w) | isDigit w -> digitsFrom (integerEnd + 2)
        _ -> integerEnd
      exponentEnd = case byteAt input fractionEnd of
        Just w
          | w == 0x65 || w == 0x45 ->
              let signed = case byteAt input (fractionEnd + 1) of
                    Just s | s == 0x2B || s == 0x2D -> fractionEnd + 2
                    _ -> fractionEnd + 1
               in case byteAt input signed of
                    Just d | isDigit d -> digitsFrom (signed + 1)
                    _ -> fractionEnd
        _ -> fractionEnd
      token = BS.take (exponentEnd - start) (BS.drop start input)
      spelling = map (chr . fromIntegral) (BS.unpack token)
  if fractionEnd == integerEnd && exponentEnd == fractionEnd
    then do
      let value = read spelling :: Integer
      case integerRange options of
        Just (low, high)
          | value < low || value > high ->
              Left
                ( "JSON integer "
                    ++ spelling
                    ++ " is outside the inclusive interoperable range ["
                    ++ show low
                    ++ ", "
                    ++ show high
                    ++ "]"
                )
        _ -> Right (Int value, exponentEnd)
    else do
      when (integerTokensOnly options) (Left ("v3 JSON numbers must use integer token spelling, got " ++ spelling))
      let value = readDouble token
      when (finiteFloatsOnly options && (isInfinite value || isNaN value)) (Left ("non-finite JSON number " ++ spelling))
      Right (Float value, exponentEnd)
  where
    isDigit w = w >= 0x30 && w <= 0x39
    digitsFrom i = case byteAt input i of
      Just w | isDigit w -> digitsFrom (i + 1)
      _ -> i

-- | Correctly rounded decimal-to-double conversion with an overflow guard.
readDouble :: ByteString -> Double
readDouble token =
  let text = map (chr . fromIntegral) (BS.unpack token)
      (mantissaPart, exponentPart) = break (\c -> c == 'e' || c == 'E') text
      negative = take 1 mantissaPart == "-"
      unsigned = if negative then drop 1 mantissaPart else mantissaPart
      (whole, fractionWithDot) = break (== '.') unsigned
      fraction = drop 1 fractionWithDot
      digits = dropWhile (== '0') (whole ++ fraction)
      expo = case exponentPart of
        [] -> 0
        _ : rest -> readSigned rest
      scale = expo - toInteger (length fraction)
      magnitude
        | null digits = 0
        -- Far outside the double range: decide without building a huge rational.
        | toInteger (length digits) + scale > 400 = 1 / 0
        | toInteger (length digits) + scale < -400 = 0
        | otherwise = fromRational (fromInteger (read digits) * (10 ^^ scale)) :: Double
   in if negative then negate magnitude else magnitude
  where
    readSigned :: String -> Integer
    readSigned ('+' : rest) = read rest
    readSigned ('-' : rest) = negate (read rest)
    readSigned rest = read rest
