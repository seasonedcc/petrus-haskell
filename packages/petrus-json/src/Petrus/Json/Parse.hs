-- | A strict JSON parser with the admission knobs the Petrus wire formats need.
--
-- 'pythonLoads' accepts exactly what CPython's @json.loads@ accepts (except
-- lone surrogate escapes, which no Petrus format admits and 'Data.Text.Text'
-- cannot hold). 'ParseOptions' then tighten admission the way the reference's
-- @object_pairs_hook@, @parse_int@, @parse_float@, and @parse_constant@ hooks
-- do: refuse duplicate members, non-finite constants, decimal or exponent
-- number spellings, or integers outside the interoperable range.
--
-- Both presets also apply CPython's resource limits (see "Petrus.Json.Limits"):
-- integer tokens longer than 4300 digits are refused with CPython's exact
-- message, and documents nested deeper than 'defaultNestingLimit' are refused
-- instead of exhausting memory.
module Petrus.Json.Parse
  ( ParseOptions (..)
  , DuplicateMembers (..)
  , pythonLoads
  , strictLoads
  , parseJson
  , safeIntegerMin
  , safeIntegerMax
  ) where

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
import Petrus.Json.Limits (defaultNestingLimit, intStrDigitsError, maxIntStrDigits)
import Petrus.Json.Value

-- | How to treat a repeated object member.
data DuplicateMembers
  = -- | CPython's default: the last value wins at the first member's position.
    LastWins
  | -- | Refuse the document.
    RejectDuplicates
  deriving stock (Eq, Show)

-- | Admission rules beyond JSON syntax.
data ParseOptions = ParseOptions
  { duplicateMembers :: DuplicateMembers
  , allowNonFiniteConstants :: Bool
  -- ^ Accept CPython's @NaN@, @Infinity@, and @-Infinity@ literals.
  , integerTokensOnly :: Bool
  -- ^ Refuse any number with a fraction or exponent.
  , integerRange :: Maybe (Integer, Integer)
  -- ^ Inclusive bounds every integer token must satisfy.
  , finiteFloatsOnly :: Bool
  -- ^ Refuse float tokens that overflow to infinity.
  , maxIntegerDigits :: Maybe Int
  -- ^ Refuse integer tokens with more digits (sign excluded) than this, with
  -- CPython's @ValueError@ text. CPython's default is 'maxIntStrDigits'.
  , maxNestingDepth :: Maybe Int
  -- ^ Refuse documents with more nested arrays and objects than this.
  }
  deriving stock (Eq, Show)

-- | CPython's @json.loads@ defaults.
pythonLoads :: ParseOptions
pythonLoads =
  ParseOptions
    { duplicateMembers = LastWins
    , allowNonFiniteConstants = True
    , integerTokensOnly = False
    , integerRange = Nothing
    , finiteFloatsOnly = False
    , maxIntegerDigits = Just maxIntStrDigits
    , maxNestingDepth = Just defaultNestingLimit
    }

-- | Duplicate-free, finite JSON: the common strict admission of Petrus formats.
strictLoads :: ParseOptions
strictLoads =
  pythonLoads
    { duplicateMembers = RejectDuplicates
    , allowNonFiniteConstants = False
    , finiteFloatsOnly = True
    }

-- | The RFC 8259 interoperable integer bounds.
safeIntegerMin, safeIntegerMax :: Integer
safeIntegerMin = -(2 ^ (53 :: Int) - 1)
safeIntegerMax = 2 ^ (53 :: Int) - 1

-- | Parse one complete JSON document.
parseJson :: ParseOptions -> ByteString -> Either String Json
parseJson options input
  | BS.isPrefixOf "\xEF\xBB\xBF" input = Left "Unexpected UTF-8 BOM (decode using utf-8-sig)"
  | otherwise = case valueAt options input 0 (skipSpace input 0) of
      Failed message -> Left message
      Done value end ->
        let rest = skipSpace input end
         in if rest < BS.length input then Left ("Extra data at byte " ++ show rest) else Right value

-- | One step of the scanner: a value and the offset just past it, or the
-- refusal. A dedicated type (rather than @Either String (a, Int)@) lets the
-- offset stay unboxed and saves a tuple and an 'Either' per scanned value.
data Step a = Done !a {-# UNPACK #-} !Int | Failed String

-- | Lift an 'Either' leaf scanner into a 'Step'.
fromEither :: Either String (a, Int) -> Step a
fromEither = \case
  Right (value, end) -> Done value end
  Left message -> Failed message
{-# INLINE fromEither #-}

skipSpace :: ByteString -> Int -> Int
skipSpace input = go
  where
    len = BS.length input
    go !i
      | i < len, isSpace (BU.unsafeIndex input i) = go (i + 1)
      | otherwise = i
    isSpace w = w == 0x20 || w == 0x09 || w == 0x0A || w == 0x0D
{-# INLINE skipSpace #-}

byteAt :: ByteString -> Int -> Maybe Word8
byteAt input i
  | i < BS.length input = Just (BU.unsafeIndex input i)
  | otherwise = Nothing
{-# INLINE byteAt #-}

expectingMessage :: String -> Int -> String
expectingMessage what i = "Expecting " ++ what ++ " at byte " ++ show i

expecting :: String -> Int -> Either String a
expecting what i = Left (expectingMessage what i)

-- | Parse the value at a byte offset, @depth@ containers deep.
valueAt :: ParseOptions -> ByteString -> Int -> Int -> Step Json
valueAt options input !depth i = case byteAt input i of
  Nothing -> Failed (expectingMessage "value" i)
  Just w -> case w of
    0x22 -> case stringAt input (i + 1) of
      Done text end -> Done (String text) end
      Failed message -> Failed message
    0x7B -> nested "object" (objectAt options input (depth + 1) (i + 1))
    0x5B -> nested "array" (arrayAt options input (depth + 1) (i + 1))
    0x6E -> literal "null" Null
    0x74 -> literal "true" (Bool True)
    0x66 -> literal "false" (Bool False)
    0x4E -> constant "NaN" (0 / 0)
    0x49 -> constant "Infinity" (1 / 0)
    0x2D
      | BS.isPrefixOf "-Infinity" (BS.drop i input) -> constant "-Infinity" (-1 / 0)
    _
      | w == 0x2D || (w >= 0x30 && w <= 0x39) -> fromEither (numberAt options input i)
      | otherwise -> Failed (expectingMessage "value" i)
  where
    nested kind parse = case maxNestingDepth options of
      Just limit
        | depth >= limit ->
            Failed
              ( "maximum nesting depth ("
                  ++ show limit
                  ++ ") exceeded while decoding a JSON "
                  ++ kind
                  ++ " from a unicode string"
              )
      _ -> parse
    literal spelling value
      | BS.isPrefixOf spelling (BS.drop i input) = Done value (i + BS.length spelling)
      | otherwise = Failed (expectingMessage "value" i)
    constant spelling value
      | not (BS.isPrefixOf spelling (BS.drop i input)) = Failed (expectingMessage "value" i)
      | allowNonFiniteConstants options = Done (Float value) (i + BS.length spelling)
      | otherwise = Failed ("non-finite JSON number " ++ show spelling)

objectAt :: ParseOptions -> ByteString -> Int -> Int -> Step Json
objectAt options input depth start = case byteAt input first of
  Just 0x7D -> Done (Object []) (first + 1)
  _ -> members first [] (0 :: Int) Set.empty
  where
    first = skipSpace input start
    -- Duplicate detection scans the (short) member list until an object
    -- grows past 'smallObject' members, and only then pays for a 'Set'.
    smallObject = 16
    members !i acc !count seen = case byteAt input i of
      Just 0x22 -> case stringAt input (i + 1) of
        Failed message -> Failed message
        Done name afterKey ->
          let colon = skipSpace input afterKey
           in case byteAt input colon of
                Just 0x3A -> case valueAt options input depth (skipSpace input (colon + 1)) of
                  Failed message -> Failed message
                  Done value afterValue ->
                    let duplicate
                          | count < smallObject = any ((== name) . fst) acc
                          | otherwise = Set.member name seen
                        next = skipSpace input afterValue
                        continue acc' count' seen' = case byteAt input next of
                          Just 0x2C -> members (skipSpace input (next + 1)) acc' count' seen'
                          Just 0x7D -> Done (Object (reverse acc')) (next + 1)
                          _ -> Failed (expectingMessage "',' delimiter" next)
                     in if duplicate
                          then case duplicateMembers options of
                            RejectDuplicates -> Failed ("duplicate JSON member " ++ show (T.unpack name))
                            LastWins -> continue (replaceMember name value acc) count seen
                          else
                            let grown = count + 1
                                seenNext
                                  | grown < smallObject = seen
                                  | grown == smallObject = Set.fromList (name : map fst acc)
                                  | otherwise = Set.insert name seen
                             in continue ((name, value) : acc) grown seenNext
                _ -> Failed (expectingMessage "':' delimiter" colon)
      _ -> Failed (expectingMessage "property name enclosed in double quotes" i)
    replaceMember name value = map (\member@(k, _) -> if k == name then (k, value) else member)

arrayAt :: ParseOptions -> ByteString -> Int -> Int -> Step Json
arrayAt options input depth start = case byteAt input first of
  Just 0x5D -> Done (Array []) (first + 1)
  _ -> items first []
  where
    first = skipSpace input start
    items !i acc = case valueAt options input depth i of
      Failed message -> Failed message
      Done value afterValue ->
        let next = skipSpace input afterValue
         in case byteAt input next of
              Just 0x2C -> items (skipSpace input (next + 1)) (value : acc)
              Just 0x5D -> Done (Array (reverse (value : acc))) (next + 1)
              _ -> Failed (expectingMessage "',' delimiter" next)

-- | Parse a string body starting just after the opening quote.
stringAt :: ByteString -> Int -> Step Text
stringAt input start = scan start 0
  where
    len = BS.length input
    -- Fast path: a run with no escapes decodes as one slice. @high@
    -- collects the bits of every byte, so an all-ASCII run (the common case)
    -- skips UTF-8 validation: ASCII bytes are their own code points.
    scan !i !high
      | i >= len = Failed ("Unterminated string starting at byte " ++ show (start - 1))
      | otherwise = case BU.unsafeIndex input i of
          0x22
            | high < 0x80 -> Done (TE.decodeLatin1 (slice start i)) (i + 1)
            | otherwise -> case decodeSlice start i of
                Right text -> Done text (i + 1)
                Left message -> Failed message
          0x5C -> fromEither (slow start i [])
          w
            | w < 0x20 -> Failed ("Invalid control character at byte " ++ show i)
            | otherwise -> scan (i + 1) (high .|. w)
    slice from to = BU.unsafeTake (to - from) (BU.unsafeDrop from input)
    decodeSlice from to = case TE.decodeUtf8' (slice from to) of
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
      case maxIntegerDigits options of
        Just limit
          | integerEnd - afterSign > limit -> Left (intStrDigitsError limit (integerEnd - afterSign))
        _ -> Right ()
      let !value
            -- Up to 18 digits fit an 'Int' exactly: accumulate the bytes
            -- directly instead of going through 'read'.
            | integerEnd - afterSign <= 18 =
                let magnitude = digitsValue afterSign integerEnd
                 in toInteger (if afterSign == start then magnitude else negate magnitude)
            | otherwise = read spelling :: Integer
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
      let !value = case fastDouble input (afterSign /= start) afterSign integerEnd fractionEnd exponentEnd of
            Just d -> d
            Nothing -> readDouble token
      when (finiteFloatsOnly options && (isInfinite value || isNaN value)) (Left ("non-finite JSON number " ++ spelling))
      Right (Float value, exponentEnd)
  where
    isDigit w = w >= 0x30 && w <= 0x39
    digitsFrom i = case byteAt input i of
      Just w | isDigit w -> digitsFrom (i + 1)
      _ -> i
    digitsValue :: Int -> Int -> Int
    digitsValue from to = go from 0
      where
        go i !acc
          | i < to = go (i + 1) (acc * 10 + fromIntegral (BU.unsafeIndex input i) - 0x30)
          | otherwise = acc

-- | Clinger's fast path: a decimal whose significant digits fit in 15 digits
-- (so below 2^53) scaled by at most 10^22 is one correctly rounded IEEE
-- multiplication or division of two exactly representable doubles, which is
-- the same double the exact rational conversion in 'readDouble' rounds to.
-- 'Nothing' sends every other spelling to 'readDouble'.
--
-- The arguments are the byte offsets 'numberAt' found: the first integer
-- digit, the end of the integer part, the end of the fraction (the
-- fraction digits start one past the dot), and the end of the token.
fastDouble :: ByteString -> Bool -> Int -> Int -> Int -> Int -> Maybe Double
fastDouble input negative integerStart integerEnd fractionEnd exponentEnd
  | exponentDigits > 4 = Nothing
  | significant > 15 = Nothing
  | mantissa == 0 = Just (signed 0)
  | scale >= 0 && scale <= 22 = Just (signed (fromIntegral mantissa * powerOfTen scale))
  | scale < 0 && scale >= -22 = Just (signed (fromIntegral mantissa / powerOfTen (negate scale)))
  | otherwise = Nothing
  where
    hasFraction = fractionEnd > integerEnd
    fractionStart = integerEnd + 1
    fractionLength = if hasFraction then fractionEnd - fractionStart else 0
    -- Digits of the integer part then the fraction, as one digit stream.
    digitAt k
      | k < integerEnd - integerStart = BU.unsafeIndex input (integerStart + k)
      | otherwise = BU.unsafeIndex input (fractionStart + k - (integerEnd - integerStart))
    totalDigits = integerEnd - integerStart + fractionLength
    leadingZeros = length (takeWhile (\k -> digitAt k == 0x30) [0 .. totalDigits - 1])
    significant = totalDigits - leadingZeros
    mantissa :: Int
    mantissa = foldl (\acc k -> acc * 10 + fromIntegral (digitAt k) - 0x30) 0 [leadingZeros .. totalDigits - 1]
    -- The exponent part, when present: [eE][+-]?digits.
    exponentStart = fractionEnd + 1
    exponentSign = if exponentEnd > fractionEnd then BU.unsafeIndex input exponentStart else 0x30
    exponentDigitsStart
      | exponentEnd <= fractionEnd = exponentEnd
      | exponentSign == 0x2B || exponentSign == 0x2D = exponentStart + 1
      | otherwise = exponentStart
    exponentDigits = exponentEnd - exponentDigitsStart
    exponentMagnitude :: Int
    exponentMagnitude = foldl (\acc i -> acc * 10 + fromIntegral (BU.unsafeIndex input i) - 0x30) 0 [exponentDigitsStart .. exponentEnd - 1]
    exponentValue = if exponentSign == 0x2D then negate exponentMagnitude else exponentMagnitude
    scale = exponentValue - fractionLength
    signed d = if negative then negate d else d

-- | Exact powers of ten up to 10^22 (every one is a representable double).
powerOfTen :: Int -> Double
powerOfTen k = powersOfTen !! k

powersOfTen :: [Double]
powersOfTen = [fromInteger (10 ^ k) | k <- [0 .. 22 :: Int]]

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
