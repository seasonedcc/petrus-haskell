-- | A serializer that reproduces CPython's @json.dumps@ byte for byte.
--
-- Every Petrus wire format is defined by the reference implementation's
-- @json.dumps@ call (canonical Net definitions, golden traces, history
-- payload spellings, identity digests), so this module mirrors the encoder in
-- CPython's @Lib/json/encoder.py@: separators, indentation, key sorting,
-- ASCII escaping, and @float.__repr__@ number spelling.
--
-- It also applies CPython's resource limits ("Petrus.Json.Limits"): an
-- integer of more than 4300 digits is refused ('IntegerTooLarge', as
-- @int.__repr__@ refuses it), and so is a value nested deeper than
-- 'nestingLimit'.
module Petrus.Json.Encode
  ( EncodeOptions (..)
  , defaultDumps
  , indented
  , compact
  , canonicalText
  , dumps
  , dumpsBuilder
  , dumpsText
  , pythonFloatRepr
  , EncodeError (..)
  , encodeErrorMessage
  ) where

import Control.Exception (Exception, evaluate, throw, try)
import Control.Monad.ST (stToIO)
import Data.Bits (shiftR, (.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Unsafe qualified as BU
import Data.Char (intToDigit, ord)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Array qualified as TA
import Data.Text.Encoding qualified as TE
import Data.Text.Internal qualified as TI
import Data.Text.Unsafe qualified as TU
import Data.Word (Word8)
import Foreign.Marshal.Utils (copyBytes, fillBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Storable (pokeByteOff)
import GHC.Num (Integer (IS))
import Numeric (floatToDigits, showHex)
import Petrus.Json.Limits (defaultNestingLimit, intReprDigitsError, maxIntStrDigits)
import Petrus.Json.Value
import System.IO.Unsafe (unsafePerformIO)

-- | The subset of @json.dumps@ keyword arguments Petrus uses.
data EncodeOptions = EncodeOptions
  { indent :: Maybe Int
  -- ^ @indent=@; 'Nothing' writes a single line.
  , itemSeparator :: Maybe Text
  -- ^ @separators=(item, _)@; 'Nothing' uses CPython's default for the indent.
  , keySeparator :: Text
  , sortKeys :: Bool
  , ensureAscii :: Bool
  , allowNan :: Bool
  , reprDigitLimit :: Maybe Int
  -- ^ Refuse integers with more decimal digits (sign excluded) than this;
  -- CPython's default is 4300.
  , nestingLimit :: Maybe Int
  -- ^ Refuse values with more nested non-empty arrays and objects than this
  -- (CPython's encoder writes @[]@ and @{}@ without recursing).
  }
  deriving stock (Eq, Show)

-- | @json.dumps(value)@.
defaultDumps :: EncodeOptions
defaultDumps =
  EncodeOptions
    { indent = Nothing
    , itemSeparator = Nothing
    , keySeparator = ": "
    , sortKeys = False
    , ensureAscii = True
    , allowNan = True
    , reprDigitLimit = Just maxIntStrDigits
    , nestingLimit = Just defaultNestingLimit
    }

-- | @json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2)@, the
-- reference writer for Net definitions, Net documents, and golden traces.
indented :: EncodeOptions
indented = defaultDumps {indent = Just 2, ensureAscii = False, allowNan = False}

-- | @json.dumps(value, allow_nan=False, ensure_ascii=False, separators=(",", ":"))@.
compact :: EncodeOptions
compact = defaultDumps {itemSeparator = Just ",", keySeparator = ":", ensureAscii = False, allowNan = False}

-- | @json.dumps(value, allow_nan=False, ensure_ascii=False, sort_keys=True,
-- separators=(",", ":"))@: the reference's deterministic, type-sensitive
-- spelling used for conflict judgments.
canonicalText :: Json -> Either EncodeError Text
canonicalText = dumpsText compact {sortKeys = True}

-- | A value @json.dumps@ refuses.
data EncodeError
  = -- | NaN or an infinity under @allow_nan=False@.
    NonFiniteNumber Double
  | -- | An integer with more decimal digits than the limit (which it carries).
    IntegerTooLarge Int
  | -- | A value nested deeper than the limit (which it carries).
    NestingTooDeep Int
  deriving stock (Eq, Show)

-- | The text of the exception CPython raises for the same refusal (for
-- 'NestingTooDeep', a fixed-depth analogue of CPython's stack-dependent
-- @RecursionError@).
--
-- >>> encodeErrorMessage (NonFiniteNumber (-1 / 0))
-- "Out of range float values are not JSON compliant: -inf"
encodeErrorMessage :: EncodeError -> String
encodeErrorMessage = \case
  NonFiniteNumber d
    | isNaN d -> "Out of range float values are not JSON compliant: nan"
    | d > 0 -> "Out of range float values are not JSON compliant: inf"
    | otherwise -> "Out of range float values are not JSON compliant: -inf"
  IntegerTooLarge limit -> intReprDigitsError limit
  NestingTooDeep limit -> "maximum nesting depth (" ++ show limit ++ ") exceeded while encoding a JSON object"

-- | Serialize to UTF-8 bytes.
--
-- The document is measured exactly ('sized') and then written into one
-- buffer of that size ('written'); 'dumpsBuilder' is the streaming
-- equivalent and spells the same bytes. The measuring pass also checks
-- every value and abandons at the first refusal, so an accepted document is
-- walked only to measure and to write. A refused one then pays for the
-- search in writer order ('firstProblem'), which sorts keys under
-- 'sortKeys', so both entry points report the same refusal.
dumps :: EncodeOptions -> Json -> Either EncodeError BS.ByteString
dumps options value = case measured layout value of
  Left problem -> Left (maybe problem id (firstProblem options 0 value))
  Right size -> Right (BI.unsafeCreate size (\pointer -> () <$ written layout pointer 0 0 value))
  where
    layout = layoutOf options

-- | The exact size of a value's spelling, or the refusal 'sized' met first.
measured :: Layout -> Json -> Either EncodeError Int
measured layout value =
  unsafePerformIO $
    either (\(Refused problem) -> Left problem) Right <$> try (evaluate (sized layout 0 value))
{-# NOINLINE measured #-}

-- | Serialize to text.
dumpsText :: EncodeOptions -> Json -> Either EncodeError Text
dumpsText options value = TE.decodeUtf8 <$> dumps options value

-- | A refusal met by the writer, which abandons the output ('dumps').
newtype Refused = Refused EncodeError
  deriving stock (Show)

instance Exception Refused

-- | Serialize to a builder.
--
-- A lazy builder cannot take back what it has written, so refusals are
-- decided up front here: a cheap scan in document order settles the common
-- case, and only a refused value pays for the search in writer order (which
-- sorts keys under 'sortKeys').
dumpsBuilder :: EncodeOptions -> Json -> Either EncodeError B.Builder
dumpsBuilder options value
  | checked options, not (clean 0 value), Just problem <- firstProblem options 0 value = Left problem
  | otherwise = Right (writer options value)
  where
    clean :: Int -> Json -> Bool
    clean level = \case
      Float d -> allowNan options || not (isNaN d || isInfinite d)
      Int i -> maybe True (\limit -> not (tooManyDigits limit i)) (reprDigitLimit options)
      Array items@(_ : _) -> shallow level && all (clean (level + 1)) items
      Object members@(_ : _) -> shallow level && all (clean (level + 1) . snd) members
      _ -> True
    shallow level = maybe True (level <) (nestingLimit options)

-- | The first value the options refuse, in writer order: a container before
-- its items, keys sorted under 'sortKeys'.
firstProblem :: EncodeOptions -> Int -> Json -> Maybe EncodeError
firstProblem options = search
  where
    search level = \case
      Float d | not (allowNan options), isNaN d || isInfinite d -> Just (NonFiniteNumber d)
      Int i | Just limit <- reprDigitLimit options, tooManyDigits limit i -> Just (IntegerTooLarge limit)
      Array items@(_ : _) -> deeper level (firstJust (map (search (level + 1)) items))
      Object members@(_ : _) -> deeper level (firstJust (map (search (level + 1) . snd) (ordered options members)))
      _ -> Nothing
    deeper level rest = case nestingLimit options of
      Just limit | level >= limit -> Just (NestingTooDeep limit)
      _ -> rest
    firstJust = \case
      [] -> Nothing
      Just problem : _ -> Just problem
      Nothing : rest -> firstJust rest

-- | Whether the options refuse anything at all.
checked :: EncodeOptions -> Bool
checked options = not (allowNan options) || hasLimit (reprDigitLimit options) || hasLimit (nestingLimit options)
  where
    hasLimit = maybe False (const True)

-- | Whether an integer has more decimal digits than the limit.
tooManyDigits :: Int -> Integer -> Bool
tooManyDigits limit i
  | IS _ <- i, limit >= 19 = False
  | limit == maxIntStrDigits = abs i >= intDigitBound
  | otherwise = abs i >= 10 ^ max 0 limit

ordered :: EncodeOptions -> [(Text, Json)] -> [(Text, Json)]
ordered options members = if sortKeys options then sortOn fst members else members

-- | The writer: a plain 'B.Builder' fold with no 'Either' threaded through
-- it. It throws 'Refused' (caught by 'dumps') at the first value the
-- options refuse, in writer order: a container before its items, keys
-- sorted under 'sortKeys'.
writer :: EncodeOptions -> Json -> B.Builder
writer options = go 0
  where
    refuse = throw . Refused
    digitLimit = reprDigitLimit options
    depthLimit = nestingLimit options
    enter level = case depthLimit of
      Just limit | level >= limit -> refuse (NestingTooDeep limit)
      _ -> ()
    itemSep = case (itemSeparator options, indent options) of
      (Just separator, _) -> separator
      (Nothing, Just _) -> ","
      (Nothing, Nothing) -> ", "
    keySep = TE.encodeUtf8Builder (keySeparator options)
    itemSepB = TE.encodeUtf8Builder itemSep
    newline level = case indent options of
      Nothing -> mempty
      Just width -> B.char7 '\n' <> B.string7 (replicate (width * level) ' ')
    string = stringB (ensureAscii options)

    go :: Int -> Json -> B.Builder
    go level = \case
      Null -> B.string7 "null"
      Bool True -> B.string7 "true"
      Bool False -> B.string7 "false"
      Int i
        | Just limit <- digitLimit, tooManyDigits limit i -> refuse (IntegerTooLarge limit)
        | otherwise -> B.integerDec i
      Float d
        | not (allowNan options), isNaN d || isInfinite d -> refuse (NonFiniteNumber d)
        | otherwise -> floatB d
      String s -> string s
      Array [] -> B.string7 "[]"
      Array items -> enter level `seq` container '[' ']' level (go (level + 1)) items
      Object [] -> B.string7 "{}"
      Object members ->
        let member (key, v) = string key <> keySep <> go (level + 1) v
         in enter level `seq` container '{' '}' level member (ordered options members)

    container :: Char -> Char -> Int -> (a -> B.Builder) -> [a] -> B.Builder
    container open close level item items =
      let inner = newline (level + 1)
          separator = itemSepB <> inner
          body = case items of
            [] -> mempty
            first : rest -> item first <> foldr (\next more -> separator <> item next <> more) mempty rest
       in B.char7 open <> inner <> body <> newline level <> B.char7 close

    -- Non-finite values reach here only when 'allowNan' admits them.
    floatB d
      | isNaN d = B.string7 "NaN"
      | isInfinite d = B.string7 (if d > 0 then "Infinity" else "-Infinity")
      | otherwise = B.string7 (pythonFloatRepr d)

-- * Direct writer --------------------------------------------------------------

data Layout = Layout
  { layoutAscii :: Bool
  , layoutSorted :: Bool
  , layoutIndent :: Maybe Int
  , layoutItemSep :: BS.ByteString
  , layoutKeySep :: BS.ByteString
  , layoutAllowNan :: Bool
  , layoutDigitLimit :: Maybe Int
  , layoutDepthLimit :: Maybe Int
  }

layoutOf :: EncodeOptions -> Layout
layoutOf options =
  Layout
    { layoutAscii = ensureAscii options
    , layoutSorted = sortKeys options
    , layoutIndent = indent options
    , layoutItemSep = TE.encodeUtf8 $ case (itemSeparator options, indent options) of
        (Just separator, _) -> separator
        (Nothing, Just _) -> ","
        (Nothing, Nothing) -> ", "
    , layoutKeySep = TE.encodeUtf8 (keySeparator options)
    , layoutAllowNan = allowNan options
    , layoutDigitLimit = reprDigitLimit options
    , layoutDepthLimit = nestingLimit options
    }

orderedMembers :: Layout -> [(Text, Json)] -> [(Text, Json)]
orderedMembers layout members = if layoutSorted layout then sortOn fst members else members

newlineSize :: Layout -> Int -> Int
newlineSize layout level = maybe 0 (\width -> 1 + width * level) (layoutIndent layout)

-- | The exact length of a value's spelling at a nesting level. It throws
-- 'Refused' (caught by 'measured') at the first value the options refuse,
-- in document order.
sized :: Layout -> Int -> Json -> Int
sized layout level = \case
  Null -> 4
  Bool True -> 4
  Bool False -> 5
  Int i
    | Just limit <- layoutDigitLimit layout, tooManyDigits limit i -> throw (Refused (IntegerTooLarge limit))
    | otherwise -> integerSize i
  Float d
    | not (layoutAllowNan layout), isNaN d || isInfinite d -> throw (Refused (NonFiniteNumber d))
    | otherwise -> length (floatSpelling d)
  String s -> stringSize (layoutAscii layout) s
  Array [] -> 2
  Object [] -> 2
  Array items -> enter `seq` containerSize (map (sized layout (level + 1)) items)
  Object members ->
    enter `seq` containerSize
      [ stringSize (layoutAscii layout) key + BS.length (layoutKeySep layout) + sized layout (level + 1) item
      | (key, item) <- members
      ]
  where
    enter = case layoutDepthLimit layout of
      Just limit | level >= limit -> throw (Refused (NestingTooDeep limit))
      _ -> ()
    containerSize sizes =
      let count = length sizes
       in 2
            + sum sizes
            + (count - 1) * BS.length (layoutItemSep layout)
            + count * newlineSize layout (level + 1)
            + newlineSize layout level

-- | Write a value's spelling at an offset; answer the offset after it.
written :: Layout -> Ptr Word8 -> Int -> Int -> Json -> IO Int
written layout pointer = go
  where
    go level offset = \case
      Null -> ascii offset "null"
      Bool True -> ascii offset "true"
      Bool False -> ascii offset "false"
      Int i -> writeInteger pointer offset i
      Float d -> ascii offset (floatSpelling d)
      String s -> writeString (layoutAscii layout) pointer offset s
      Array [] -> ascii offset "[]"
      Object [] -> ascii offset "{}"
      Array items -> container level offset 0x5B 0x5D (go (level + 1)) items
      Object members -> container level offset 0x7B 0x7D member (orderedMembers layout members)
        where
          member at (key, item) = do
            afterKey <- writeString (layoutAscii layout) pointer at key
            afterSep <- bytes afterKey (layoutKeySep layout)
            go (level + 1) afterSep item
    container :: Int -> Int -> Word8 -> Word8 -> (Int -> a -> IO Int) -> [a] -> IO Int
    container level offset open close item items = do
      pokeByteOff pointer offset open
      first <- newline (level + 1) (offset + 1)
      end <- case items of
        [] -> pure first
        x : rest -> item first x >>= separated rest
      outer <- newline level end
      pokeByteOff pointer outer close
      pure (outer + 1)
      where
        separated [] at = pure at
        separated (x : rest) at = do
          afterSep <- bytes at (layoutItemSep layout)
          afterLine <- newline (level + 1) afterSep
          item afterLine x >>= separated rest
    newline level offset = case layoutIndent layout of
      Nothing -> pure offset
      Just width -> do
        pokeByteOff pointer offset (0x0A :: Word8)
        let spaces = width * level
        fillBytes (pointer `plusPtr` (offset + 1)) 0x20 spaces
        pure (offset + 1 + spaces)
    ascii offset spelling = do
      let go' at = \case
            [] -> pure at
            c : rest -> pokeByteOff pointer at (fromIntegral (ord c) :: Word8) >> go' (at + 1) rest
      go' offset spelling
    bytes offset chunk = do
      BU.unsafeUseAsCStringLen chunk $ \(source, size) ->
        copyBytes (pointer `plusPtr` offset) (castPtr source) size
      pure (offset + BS.length chunk)

floatSpelling :: Double -> String
floatSpelling d
  | isNaN d = "NaN"
  | isInfinite d = if d > 0 then "Infinity" else "-Infinity"
  | otherwise = pythonFloatRepr d

integerSize :: Integer -> Int
integerSize i
  | i < 0 = 1 + integerSize (negate i)
  | i < 10 = 1
  | i < 1000000000000000000 = go 1 (fromInteger i :: Int)
  | otherwise = length (show i)
  where
    go count n = if n < 10 then count else go (count + 1) (n `quot` 10)

writeInteger :: Ptr Word8 -> Int -> Integer -> IO Int
writeInteger pointer offset i
  | i < 0 = do
      pokeByteOff pointer offset (0x2D :: Word8)
      writeInteger pointer (offset + 1) (negate i)
  | i < 1000000000000000000 = do
      let size = integerSize i
          fill at n = do
            pokeByteOff pointer at (fromIntegral (0x30 + n `rem` 10) :: Word8)
            if n < 10 then pure () else fill (at - 1) (n `quot` 10)
      fill (offset + size - 1) (fromInteger i :: Int)
      pure (offset + size)
  | otherwise = do
      let digits = show i
      mapM_ (\(at, c) -> pokeByteOff pointer at (fromIntegral (ord c) :: Word8)) (zip [offset ..] digits)
      pure (offset + length digits)

-- | Whether every byte of a text spells itself inside a JSON string.
plainText :: Bool -> Text -> Bool
plainText asciiOnly (TI.Text array offset size) = go offset
  where
    end = offset + size
    go i
      | i >= end = True
      | otherwise =
          let w = TA.unsafeIndex array i
           in w >= 0x20 && w /= 0x22 && w /= 0x5C && (not asciiOnly || w < 0x7F) && go (i + 1)

stringSize :: Bool -> Text -> Int
stringSize asciiOnly text@(TI.Text _ _ size)
  | plainText asciiOnly text = size + 2
  | otherwise = 2 + T.foldl' (\total c -> total + escapedSize c) 0 text
  where
    escapedSize c
      | c == '"' || c == '\\' || c == '\n' || c == '\r' || c == '\t' || c == '\b' || c == '\f' = 2
      | ord c < 0x20 = 6
      | asciiOnly && ord c > 0x7e = if ord c > 0xFFFF then 12 else 6
      | otherwise = utf8Size c
    utf8Size c
      | ord c < 0x80 = 1
      | ord c < 0x800 = 2
      | ord c < 0x10000 = 3
      | otherwise = 4

writeString :: Bool -> Ptr Word8 -> Int -> Text -> IO Int
writeString asciiOnly pointer offset text@(TI.Text array from size) = do
  pokeByteOff pointer offset (0x22 :: Word8)
  end <-
    if plainText asciiOnly text
      then do
        stToIO (TA.copyToPointer array from (pointer `plusPtr` (offset + 1)) size)
        pure (offset + 1 + size)
      else chars from (offset + 1)
  pokeByteOff pointer end (0x22 :: Word8)
  pure (end + 1)
  where
    stop = from + size
    chars i at
      | i >= stop = pure at
      | otherwise = do
          let TU.Iter c delta = TU.iterArray array i
          next <- escaped c i delta at
          chars (i + delta) next
    escaped c i delta at = case c of
      '"' -> two at 0x22
      '\\' -> two at 0x5C
      '\n' -> two at 0x6E
      '\r' -> two at 0x72
      '\t' -> two at 0x74
      '\b' -> two at 0x62
      '\f' -> two at 0x66
      _
        | ord c < 0x20 -> unicodeEscape at (ord c)
        | asciiOnly && ord c > 0x7e ->
            if ord c > 0xFFFF
              then do
                let v = ord c - 0x10000
                middle <- unicodeEscape at (0xD800 + v `div` 0x400)
                unicodeEscape middle (0xDC00 + v `mod` 0x400)
              else unicodeEscape at (ord c)
        | otherwise -> do
            stToIO (TA.copyToPointer array i (pointer `plusPtr` at) delta)
            pure (at + delta)
    two at w = do
      pokeByteOff pointer at (0x5C :: Word8)
      pokeByteOff pointer (at + 1) (w :: Word8)
      pure (at + 2)
    unicodeEscape at n = do
      pokeByteOff pointer at (0x5C :: Word8)
      pokeByteOff pointer (at + 1) (0x75 :: Word8)
      let digit k = let d = (n `shiftR` (4 * k)) .&. 0xF in fromIntegral (if d < 10 then 0x30 + d else 0x57 + d) :: Word8
      pokeByteOff pointer (at + 2) (digit 3)
      pokeByteOff pointer (at + 3) (digit 2)
      pokeByteOff pointer (at + 4) (digit 1)
      pokeByteOff pointer (at + 5) (digit 0)
      pure (at + 6)

-- | CPython's JSON string encoding (@py_encode_basestring@ /
-- @py_encode_basestring_ascii@).
stringB :: Bool -> Text -> B.Builder
stringB asciiOnly text = B.char7 '"' <> chunks text <> B.char7 '"'
  where
    -- Runs of characters that need no escape are copied as one UTF-8 slice;
    -- only the characters between runs go through 'escape'. The output is
    -- the same as escaping character by character, several times faster.
    plain c = c >= ' ' && c /= '"' && c /= '\\' && (not asciiOnly || c <= '~')
    chunks t
      | T.null t = mempty
      | otherwise =
          let (run, rest) = T.span plain t
           in TE.encodeUtf8Builder run <> case T.uncons rest of
                Nothing -> mempty
                Just (c, rest') -> escape c <> chunks rest'
    escape c = case c of
      '"' -> B.string7 "\\\""
      '\\' -> B.string7 "\\\\"
      '\n' -> B.string7 "\\n"
      '\r' -> B.string7 "\\r"
      '\t' -> B.string7 "\\t"
      '\b' -> B.string7 "\\b"
      '\f' -> B.string7 "\\f"
      _
        | ord c < 0x20 -> unicodeEscape (ord c)
        | asciiOnly && ord c > 0x7e -> asciiEscape (ord c)
        | otherwise -> B.charUtf8 c
    asciiEscape n
      | n > 0xFFFF =
          let v = n - 0x10000
           in unicodeEscape (0xD800 + (v `div` 0x400)) <> unicodeEscape (0xDC00 + (v `mod` 0x400))
      | otherwise = unicodeEscape n
    unicodeEscape n = B.string7 "\\u" <> B.string7 (pad4 (showHex n ""))
    pad4 digits = replicate (4 - length digits) '0' ++ digits

-- | CPython's @float.__repr__@ for a finite double: the shortest digits that
-- round-trip, in positional form when the decimal exponent is in
-- @[-4, 16)@ and in exponent form otherwise.
pythonFloatRepr :: Double -> String
pythonFloatRepr d
  | d == 0 = if isNegativeZero d then "-0.0" else "0.0"
  | d < 0 = '-' : pythonFloatRepr (negate d)
  | otherwise =
      let (digits, decpt) = floatToDigits 10 d
          ds = map intToDigit digits
       in if decpt <= -4 || decpt > 16
            then scientific ds (decpt - 1)
            else positional ds decpt
  where
    scientific ds expo =
      let mantissa = case ds of
            [single] -> [single]
            first : rest -> first : '.' : rest
            [] -> "0"
          sign = if expo < 0 then '-' else '+'
          magnitude = show (abs expo)
       in mantissa ++ "e" ++ [sign] ++ (if length magnitude < 2 then '0' : magnitude else magnitude)
    positional ds decpt
      | decpt <= 0 = "0." ++ replicate (negate decpt) '0' ++ ds
      | decpt >= length ds = ds ++ replicate (decpt - length ds) '0' ++ ".0"
      | otherwise = let (whole, fraction) = splitAt decpt ds in whole ++ "." ++ fraction

-- | The smallest integer with more than 'maxIntStrDigits' digits.
intDigitBound :: Integer
intDigitBound = 10 ^ maxIntStrDigits
{-# NOINLINE intDigitBound #-}
