-- | A strict JSON parser with the admission knobs the Petrus wire formats need.
--
-- 'pythonLoads' accepts exactly what CPython's @json.loads@ accepts (except
-- lone surrogate escapes, which no Petrus format admits and 'Data.Text.Text'
-- cannot hold). 'ParseOptions' then tighten admission the way the reference's
-- @object_pairs_hook@, @parse_int@, @parse_float@, and @parse_constant@ hooks
-- do: refuse duplicate members, non-finite constants, decimal or exponent
-- number spellings, or integers outside the interoperable range.
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
import Data.Bits (complement, countTrailingZeros, shiftL, shiftR, xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BU
import Data.Char (chr)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Array qualified as TA
import Data.Text.Foreign qualified as TF
import Data.Text.Internal qualified as TI
import Control.Monad.ST (ST, runST)
import Data.Array.Base (unsafeRead, unsafeWrite)
import Data.Array.ST (STUArray, newArray)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peekByteOff)
import GHC.ByteOrder (ByteOrder (..), targetByteOrder)
import System.IO.Unsafe (unsafeDupablePerformIO)
import Data.Word (Word64, Word8)
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
  | otherwise = case valueAt options input (skipSpace input 0) of
      Step value end
        | end < 0 -> Left (failureMessage value)
        | otherwise ->
            let rest = skipSpace input end
             in if rest < BS.length input then Left ("Extra data at byte " ++ show rest) else Right value

-- | A production's value and the offset just after it. The parser returns
-- this single-constructor product (which GHC returns unboxed) rather than an
-- @Either String (Json, Int)@; a negative offset marks a failure, whose
-- message travels in the value slot (see 'failed').
data Step = Step Json {-# UNPACK #-} !Int

-- | A parsed string and the offset after its closing quote; a negative
-- offset marks a failure whose message is the text.
data TextStep = TextStep Text {-# UNPACK #-} !Int

failed :: String -> Step
failed message = Step (String (T.pack message)) (-1)

failureMessage :: Json -> String
failureMessage = \case
  String message -> T.unpack message
  _ -> "invalid JSON"

expecting :: String -> Int -> Step
expecting what i = failed ("Expecting " ++ what ++ " at byte " ++ show i)

skipSpace :: ByteString -> Int -> Int
skipSpace input = go
  where
    len = BS.length input
    go i
      | i < len, isSpace (BU.unsafeIndex input i) = go (i + 1)
      | otherwise = i
    isSpace w = w == 0x20 || w == 0x09 || w == 0x0A || w == 0x0D
{-# INLINE skipSpace #-}

-- | The byte at an offset, or -1 past the end.
at :: ByteString -> Int -> Int
at input i
  | i < BS.length input = fromIntegral (BU.unsafeIndex input i)
  | otherwise = -1
{-# INLINE at #-}

byteAt :: ByteString -> Int -> Maybe Word8
byteAt input i
  | i < BS.length input = Just (BU.unsafeIndex input i)
  | otherwise = Nothing

valueAt :: ParseOptions -> ByteString -> Int -> Step
valueAt options input i = case at input i of
  0x22 -> case stringAt input (i + 1) of
    TextStep text end
      | end < 0 -> Step (String text) end
      | otherwise -> Step (String text) end
  0x7B -> objectAt options input (i + 1)
  0x5B -> arrayAt options input (i + 1)
  0x6E
    | at input (i + 1) == 0x75 && at input (i + 2) == 0x6C && at input (i + 3) == 0x6C -> Step Null (i + 4)
  0x74
    | at input (i + 1) == 0x72 && at input (i + 2) == 0x75 && at input (i + 3) == 0x65 -> Step (Bool True) (i + 4)
  0x66
    | at input (i + 1) == 0x61 && at input (i + 2) == 0x6C && at input (i + 3) == 0x73 && at input (i + 4) == 0x65 ->
        Step (Bool False) (i + 5)
  0x4E -> constant "NaN" (0 / 0)
  0x49 -> constant "Infinity" (1 / 0)
  w
    | w == 0x2D && BS.isPrefixOf "-Infinity" (BU.unsafeDrop i input) -> constant "-Infinity" (-1 / 0)
    | w == 0x2D || (w >= 0x30 && w <= 0x39) -> numberAt options input i
    | otherwise -> expecting "value" i
  where
    constant spelling value
      | not (BS.isPrefixOf spelling (BU.unsafeDrop i input)) = expecting "value" i
      | allowNonFiniteConstants options = Step (Float value) (i + BS.length spelling)
      | otherwise = failed ("non-finite JSON number " ++ show spelling)

objectAt :: ParseOptions -> ByteString -> Int -> Step
objectAt options input start = case at input first of
  0x7D -> Step (Object []) (first + 1)
  _ -> members first [] 0
  where
    first = skipSpace input start
    members :: Int -> [(Text, Json)] -> Int -> Step
    members !i acc !count = case at input i of
      0x22 -> case stringAt input (i + 1) of
        TextStep name afterKey
          | afterKey < 0 -> Step (String name) afterKey
          | otherwise ->
              let colon = skipSpace input afterKey
               in case at input colon of
                    0x3A -> case valueAt options input (skipSpace input (colon + 1)) of
                      failure@(Step value afterValue)
                        | afterValue < 0 -> failure
                        | otherwise ->
                            let acc' = (name, value) : acc
                                next = skipSpace input afterValue
                             in case at input next of
                                  0x2C -> members (skipSpace input (next + 1)) acc' (count + 1)
                                  0x7D -> finish (count + 1) (reverse acc') (next + 1)
                                  _ -> expecting "',' delimiter" next
                    _ -> expecting "':' delimiter" colon
      _ -> expecting "property name enclosed in double quotes" i
    -- Duplicates are resolved once the object is complete, as CPython's
    -- object_pairs_hook sees them.
    finish count found end
      | not (hasDuplicates count found) = Step (Object found) end
      | otherwise = case duplicateMembers options of
          RejectDuplicates -> failed ("duplicate JSON member " ++ show (T.unpack (firstDuplicate Set.empty found)))
          LastWins -> Step (Object (lastWins found)) end
    hasDuplicates count found
      | count <= 8 = quadratic found
      -- Distinct hashes prove distinct keys; only a collision needs the
      -- exact (comparison-based) check.
      | otherwise = hashesCollide count found && Set.size (Set.fromList (map fst found)) /= count
    quadratic [] = False
    quadratic ((key, _) : rest) = any ((== key) . fst) rest || quadratic rest
    firstDuplicate seen = \case
      [] -> T.empty
      (key, _) : rest
        | Set.member key seen -> key
        | otherwise -> firstDuplicate (Set.insert key seen) rest
    -- Each name once, at its first position, with its last value.
    lastWins found =
      let final = foldl (\m (key, value) -> Map.insert key value m) Map.empty found
          go _ [] = []
          go seen ((key, _) : rest)
            | Set.member key seen = go seen rest
            | otherwise = (key, final Map.! key) : go (Set.insert key seen) rest
       in go Set.empty found

arrayAt :: ParseOptions -> ByteString -> Int -> Step
arrayAt options input start = case at input first of
  0x5D -> Step (Array []) (first + 1)
  _ -> items first []
  where
    first = skipSpace input start
    items :: Int -> [Json] -> Step
    items !i acc = case valueAt options input i of
      failure@(Step value afterValue)
        | afterValue < 0 -> failure
        | otherwise ->
            let next = skipSpace input afterValue
             in case at input next of
                  0x2C -> items (skipSpace input (next + 1)) (value : acc)
                  0x5D -> Step (Array (reverse (value : acc))) (next + 1)
                  _ -> expecting "',' delimiter" next

-- | Whether two keys share a hash, via a small open-addressing table of
-- their FNV-1a hashes.
hashesCollide :: Int -> [(Text, a)] -> Bool
hashesCollide count found = runST $ do
  let size = until (>= 2 * count) (* 2) 16
      mask = size - 1
  table <- newArray (0, size - 1) 0 :: ST s (STUArray s Int Int)
  let insert [] = pure False
      insert ((key, _) : rest) = do
        -- 0 marks an empty slot.
        let hash = case keyHash key of 0 -> 1; h -> h
            probe slot = do
              occupant <- unsafeRead table slot
              if occupant == 0
                then unsafeWrite table slot hash >> insert rest
                else
                  if occupant == hash
                    then pure True
                    else probe ((slot + 1) .&. mask)
        probe (hash .&. mask)
  insert found

-- | A cheap key hash for the duplicate pre-check: the length and up to the
-- first and last eight UTF-8 bytes. Equal keys always hash equally; a
-- collision only costs the exact check.
keyHash :: Text -> Int
keyHash (TI.Text array offset size) =
  let byte i = fromIntegral (TA.unsafeIndex array i) :: Int
      window from count = go from (from + count) 0
        where
          go i end acc
            | i >= end = acc
            | otherwise = go (i + 1) end (acc * 257 + byte i)
      front = window offset (min 8 size)
      back = if size > 8 then window (offset + max 8 (size - 8)) (min 8 (size - 8)) else 0
   in ((size * 1099511628211) `xor` front) * 1099511628211 `xor` (back * 6364136223846793005)

-- | The offset of the first byte at or after @from@ that ends a plain string
-- run: a quote, a backslash, a control character, or a non-ASCII byte; the
-- input length when there is none. Eight bytes are tested at a time.
findSpecial :: ByteString -> Int -> Int
findSpecial input from
  | targetByteOrder /= LittleEndian = bytewise from
  | otherwise = unsafeDupablePerformIO (BU.unsafeUseAsCString input (\pointer -> wordwise (castPtr pointer) from))
  where
    len = BS.length input
    special w = w == 0x22 || w == 0x5C || w < 0x20 || w >= 0x80
    bytewise i
      | i < len, not (special (BU.unsafeIndex input i)) = bytewise (i + 1)
      | otherwise = i
    wordwise :: Ptr Word8 -> Int -> IO Int
    wordwise pointer i
      | i + 8 <= len = do
          word <- peekByteOff pointer i :: IO Word64
          let flagged = flags word
          if flagged == 0
            then wordwise pointer (i + 8)
            else pure (i + countTrailingZeros flagged `shiftR` 3)
      | otherwise = pure (bytewise i)
    ones = 0x0101010101010101 :: Word64
    highs = 0x8080808080808080 :: Word64
    zeroByte v = (v - ones) .&. complement v .&. highs
    -- The lowest flagged byte is exact (borrows only reach higher bytes).
    flags word =
      (word .&. highs)
        .|. ((word - 0x20 * ones) .&. complement word .&. highs)
        .|. zeroByte (word `xor` (0x22 * ones))
        .|. zeroByte (word `xor` (0x5C * ones))

-- | Parse a string body starting just after the opening quote.
stringAt :: ByteString -> Int -> TextStep
stringAt input start
  -- Fast path: plain ASCII up to the closing quote is one copy.
  | end < BS.length input, BU.unsafeIndex input end == 0x22 = TextStep (copyAscii (slice start end)) (end + 1)
  | otherwise = case stringSlow input start of
      Left problem -> TextStep (T.pack problem) (-1)
      Right (text, after) -> TextStep text after
  where
    end = findSpecial input start
    slice from to = BU.unsafeTake (to - from) (BU.unsafeDrop from input)

stringSlow :: ByteString -> Int -> Either String (Text, Int)
stringSlow input start = scanFrom True start
  where
    len = BS.length input
    -- An ASCII-only run is valid UTF-8 by construction and copies directly.
    scanFrom ascii i
      | i >= len = Left ("Unterminated string starting at byte " ++ show (start - 1))
      | otherwise = case BU.unsafeIndex input i of
          0x22
            | ascii -> Right (copyAscii (slice start i), i + 1)
            | otherwise -> do
                text <- decodeSlice start i
                Right (text, i + 1)
          0x5C -> slow start i []
          w
            | w < 0x20 -> Left ("Invalid control character at byte " ++ show i)
            | otherwise -> scanFrom (ascii && w < 0x80) (i + 1)
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

-- | Copy bytes known to be ASCII (hence valid UTF-8) into a 'Text'.
copyAscii :: ByteString -> Text
copyAscii bytes
  | BS.null bytes = T.empty
  | otherwise =
      unsafeDupablePerformIO
        (BU.unsafeUseAsCStringLen bytes (\(pointer, size) -> TF.fromPtr (castPtr pointer) (fromIntegral size)))

-- | CPython's number grammar: @-?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?@.
numberAt :: ParseOptions -> ByteString -> Int -> Step
numberAt options input start
  -- Fast path: a short integer token with no range to check.
  | Nothing <- integerRange options
  , digitsStart < len
  , isDigitByte leading =
      let digitsEnd = if leading == 0x30 then digitsStart + 1 else scanDigits (digitsStart + 1)
       in if digitsEnd - digitsStart <= 18 && not (continues digitsEnd)
            then
              let magnitude = smallDigits digitsStart digitsEnd 0
               in Step (Int (toInteger (if negative then negate magnitude else magnitude))) digitsEnd
            else slow
  | otherwise = slow
  where
    len = BS.length input
    slow = case numberSlow options input start of
      Left problem -> failed problem
      Right (value, end) -> Step value end
    negative = BU.unsafeIndex input start == 0x2D
    digitsStart = if negative then start + 1 else start
    leading = BU.unsafeIndex input digitsStart
    scanDigits !i
      | i < len, isDigitByte (BU.unsafeIndex input i) = scanDigits (i + 1)
      | otherwise = i
    -- A fraction, an exponent, or a further digit (after a leading zero)
    -- leaves the token to the general path.
    continues i = i < len && (let w = BU.unsafeIndex input i in w == 0x2E || w == 0x65 || w == 0x45 || isDigitByte w)
    smallDigits :: Int -> Int -> Int -> Int
    smallDigits !i !end !acc
      | i >= end = acc
      | otherwise = smallDigits (i + 1) end (acc * 10 + fromIntegral (BU.unsafeIndex input i) - 0x30)
    isDigitByte w = w >= 0x30 && w <= 0x39

numberSlow :: ParseOptions -> ByteString -> Int -> Either String (Json, Int)
numberSlow options input start = do
  let afterSign = if byteAt input start == Just 0x2D then start + 1 else start
  integerEnd <- case byteAt input afterSign of
    Just 0x30 -> Right (afterSign + 1)
    Just w | w >= 0x31 && w <= 0x39 -> Right (digitsFrom (afterSign + 1))
    _ -> Left ("Expecting value at byte " ++ show start)
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
      let value = case BS.uncons token of
            Just (0x2D, digits) -> negate (digitsValue digits)
            _ -> digitsValue token
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
    digitsValue = BS.foldl' (\acc w -> acc * 10 + toInteger (w - 0x30)) 0
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
