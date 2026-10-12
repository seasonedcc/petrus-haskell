{-# LANGUAGE MagicHash #-}

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
  , dumpsMany
  , dumpsText
  , pythonFloatRepr
  , EncodeError (..)
  , encodeErrorMessage
  ) where

import Control.Exception (Exception, throw, throwIO, try)
import Control.Monad (when)
import Control.Monad.ST (stToIO)
import Data.Bits (shiftR, (.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Unsafe qualified as BU
import Data.Char (ord)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Array qualified as TA
import Data.Text.Encoding qualified as TE
import Data.Text.Internal qualified as TI
import Data.Text.Unsafe qualified as TU
import Data.Word (Word8)
import Foreign.ForeignPtr (ForeignPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Foreign.Marshal.Utils (copyBytes, fillBytes)
import Foreign.Ptr (Ptr, castPtr, minusPtr, plusPtr)
import Foreign.Storable (pokeByteOff)
import GHC.Exts (Int (I#))
import GHC.ForeignPtr (plusForeignPtr, unsafeWithForeignPtr)
import GHC.Num (Integer (IS))
import Numeric (showHex)
import Petrus.Json.Float (floatReprBuilder, maxFloatReprLength, pythonFloatRepr, writeFloatRepr)
import Petrus.Json.Limits (defaultNestingLimit, intReprDigitsError, maxIntStrDigits)
import Petrus.Json.Value
import Petrus.Json.Wtf8 (unsafeTextFromBytes)
import System.IO.Unsafe (unsafeDupablePerformIO)

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
-- One pass writes the document into a growing buffer ('written'), so every
-- value is visited once and every string is scanned once; 'dumpsBuilder' is
-- the streaming equivalent and spells the same bytes. The writer refuses as
-- it goes, at the first value the options refuse in writer order (a
-- container before its items, keys sorted under 'sortKeys'), which is the
-- refusal 'dumpsBuilder' reports too. unsafeDupablePerformIO: the writer
-- touches only buffers this call allocates, so 'dumps' is pure.
dumps :: EncodeOptions -> Json -> Either EncodeError BS.ByteString
dumps options value =
  unsafeDupablePerformIO $
    either (\(Refused problem) -> Left problem) Right <$> try (direct (layoutOf options) value)

-- | 'dumps' of each item's value in turn, for a batch written together:
-- every item with its spelling, or the first item refused with its
-- problem. The answer equals @traverse@ over 'dumps' (same bytes, same
-- first refusal); the test suite checks it.
--
-- The spellings are written back to back into one growing buffer and
-- answered as slices of it, instead of a 2 000-byte buffer and an exact-size
-- copy per value. Each slice keeps the whole buffer alive, so this is for
-- spellings that are used together and dropped together, such as the
-- payloads of one database write batch (the History store's batch commit),
-- not for spellings kept apart.
dumpsMany :: EncodeOptions -> (a -> Json) -> [a] -> Either (a, EncodeError) [(a, BS.ByteString)]
dumpsMany options valueOf items = unsafeDupablePerformIO $ do
  first <- BI.mallocByteString initialCapacity
  ref <- newIORef (Buffer first initialCapacity)
  let layout = layoutOf options
      go !offset ends = \case
        [] -> do
          Buffer final _ <- readIORef ref
          pure (Right (zip items (slices final ends)))
        item : rest ->
          try (written layout ref 0 offset (valueOf item)) >>= \case
            Left (Refused problem) -> pure (Left (item, problem))
            Right end -> go end (end : ends) rest
  go 0 [] items
  where
    -- The end offsets come newest first; each value starts where the one
    -- before it ends.
    slices final = build []
      where
        build acc = \case
          [] -> acc
          [end] -> slice 0 end : acc
          end : rest@(start : _) -> let !piece = slice start end in build (piece : acc) rest
        slice start end = BI.BS (plusForeignPtr final start) (end - start)

-- | Serialize to text: CPython's @json.dumps@ @str@. The bytes 'dumps'
-- writes are UTF-8 by construction, or WTF-8 where a string holds a lone
-- surrogate and 'ensureAscii' is off ("Petrus.Json.Wtf8"), so they become
-- the 'Text' as they are.
dumpsText :: EncodeOptions -> Json -> Either EncodeError Text
dumpsText options value = unsafeTextFromBytes <$> dumps options value

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
ordered options members = if sortKeys options then sortBy (comparing fst) members else members

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
      | otherwise = floatReprBuilder d

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

-- | The output buffer and its capacity. It only grows, and every write
-- first 'reserve's its room, so no pointer outlives the buffer it points
-- into.
data Buffer = Buffer {-# UNPACK #-} !(ForeignPtr Word8) {-# UNPACK #-} !Int

-- | Write a whole document; answer exactly its bytes.
direct :: Layout -> Json -> IO BS.ByteString
direct layout value = do
  first <- BI.mallocByteString initialCapacity
  ref <- newIORef (Buffer first initialCapacity)
  end <- written layout ref 0 0 value
  Buffer final capacity <- readIORef ref
  -- Keep the growth slack out of long-lived values.
  if 4 * (capacity - end) > capacity
    then BI.create end (\target -> unsafeWithForeignPtr final (\source -> copyBytes target source end))
    else pure (BI.BS final end)

initialCapacity :: Int
initialCapacity = 2000

-- | The base of a buffer with room for @size@ more bytes at @offset@.
reserve :: IORef Buffer -> Int -> Int -> IO (Ptr Word8)
reserve ref offset size = do
  Buffer buffer capacity <- readIORef ref
  if offset + size <= capacity
    then pure (unsafeForeignPtrToPtr buffer)
    else grow ref offset (offset + size)
{-# INLINE reserve #-}

grow :: IORef Buffer -> Int -> Int -> IO (Ptr Word8)
grow ref used needed = do
  Buffer old capacity <- readIORef ref
  let capacity' = max needed (2 * capacity)
  new <- BI.mallocByteString capacity'
  unsafeWithForeignPtr new $ \target -> unsafeWithForeignPtr old $ \source -> copyBytes target source used
  writeIORef ref (Buffer new capacity')
  pure (unsafeForeignPtrToPtr new)
{-# NOINLINE grow #-}

-- | Members in writer order: by key under 'sortKeys' (stably, as
-- @sorted(dict.items())@ on distinct keys), skipping the sort when they
-- already are.
orderedMembers :: Layout -> [(Text, Json)] -> [(Text, Json)]
orderedMembers layout members
  | layoutSorted layout, not (ascending members) = sortBy (comparing fst) members
  | otherwise = members
  where
    ascending = \case
      (a, _) : rest@((b, _) : _) -> a <= b && ascending rest
      _ -> True

-- | Write a value's spelling at an offset; answer the offset after it. It
-- throws 'Refused' (caught by 'dumps') at the first value the options
-- refuse, in writer order.
written :: Layout -> IORef Buffer -> Int -> Int -> Json -> IO Int
written layout ref = go
  where
    asciiOnly = layoutAscii layout
    go :: Int -> Int -> Json -> IO Int
    go level offset = \case
      Null -> four offset 0x6E 0x75 0x6C 0x6C
      Bool True -> four offset 0x74 0x72 0x75 0x65
      Bool False -> do
        end <- four offset 0x66 0x61 0x6C 0x73
        byte end 0x65
      Int i
        | Just limit <- layoutDigitLimit layout, tooManyDigits limit i -> throwIO (Refused (IntegerTooLarge limit))
        | otherwise -> writeInteger ref offset i
      Float d
        | isNaN d || isInfinite d ->
            if layoutAllowNan layout
              then bytes offset (if isNaN d then "NaN" else if d > 0 then "Infinity" else "-Infinity")
              else throwIO (Refused (NonFiniteNumber d))
        | otherwise -> do
            base <- reserve ref offset maxFloatReprLength
            end <- writeFloatRepr d (base `plusPtr` offset)
            pure (end `minusPtr` base)
      String s -> writeString asciiOnly ref offset s
      Array [] -> two offset 0x5B 0x5D
      Object [] -> two offset 0x7B 0x7D
      Array items -> enter level >> container level offset 0x5B 0x5D (go (level + 1)) items
      Object members -> enter level >> container level offset 0x7B 0x7D member (orderedMembers layout members)
        where
          member at (key, item) = do
            afterKey <- writeString asciiOnly ref at key
            afterSep <- bytes afterKey (layoutKeySep layout)
            go (level + 1) afterSep item
    enter level = case layoutDepthLimit layout of
      Just limit | level >= limit -> throwIO (Refused (NestingTooDeep limit))
      _ -> pure ()
    container :: Int -> Int -> Word8 -> Word8 -> (Int -> a -> IO Int) -> [a] -> IO Int
    container level offset open close item items = do
      afterOpen <- byte offset open
      first <- newline (level + 1) afterOpen
      end <- case items of
        [] -> pure first
        x : rest -> item first x >>= separated rest
      outer <- newline level end
      byte outer close
      where
        separated [] at = pure at
        separated (x : rest) at = do
          afterSep <- bytes at (layoutItemSep layout)
          afterLine <- newline (level + 1) afterSep
          item afterLine x >>= separated rest
    newline level offset = case layoutIndent layout of
      Nothing -> pure offset
      Just width -> do
        let spaces = width * level
        base <- reserve ref offset (1 + spaces)
        pokeByteOff base offset (0x0A :: Word8)
        fillBytes (base `plusPtr` (offset + 1)) 0x20 spaces
        pure (offset + 1 + spaces)
    byte offset w = do
      base <- reserve ref offset 1
      pokeByteOff base offset (w :: Word8)
      pure (offset + 1)
    two offset a b = do
      base <- reserve ref offset 2
      pokeByteOff base offset (a :: Word8)
      pokeByteOff base (offset + 1) (b :: Word8)
      pure (offset + 2)
    four offset a b c d = do
      base <- reserve ref offset 4
      pokeByteOff base offset (a :: Word8)
      pokeByteOff base (offset + 1) (b :: Word8)
      pokeByteOff base (offset + 2) (c :: Word8)
      pokeByteOff base (offset + 3) (d :: Word8)
      pure (offset + 4)
    bytes offset chunk = do
      let size = BS.length chunk
      base <- reserve ref offset size
      let copy i
            | i >= size = pure ()
            | otherwise = pokeByteOff base (offset + i) (BU.unsafeIndex chunk i) >> copy (i + 1)
      copy 0
      pure (offset + size)

writeInteger :: IORef Buffer -> Int -> Integer -> IO Int
writeInteger ref offset = \case
  IS n -> do
    base <- reserve ref offset 20
    let value = I# n
    if value < 0
      then do
        pokeByteOff base offset (0x2D :: Word8)
        unsigned base (offset + 1) (negate (fromIntegral value))
      else unsigned base offset (fromIntegral value)
  i -> do
    let digits = BC.pack (show i)
        size = BS.length digits
    base <- reserve ref offset size
    BU.unsafeUseAsCString digits (\source -> copyBytes (base `plusPtr` offset) (castPtr source) size)
    pure (offset + size)
  where
    unsigned :: Ptr Word8 -> Int -> Word -> IO Int
    unsigned base at value = do
      let size = wordDigits 1 value
          fill i v = do
            let (q, r) = v `quotRem` 10
            pokeByteOff base i (fromIntegral (0x30 + r) :: Word8)
            if q == 0 then pure () else fill (i - 1) q
      fill (at + size - 1) value
      pure (at + size)
    wordDigits :: Int -> Word -> Int
    wordDigits n v = if v < 10 then n else wordDigits (n + 1) (v `quot` 10)

-- | A JSON string: CPython's @py_encode_basestring@, or
-- @py_encode_basestring_ascii@ under 'ensureAscii'.
--
-- The text is scanned once, by UTF-8 byte: every byte of a multi-byte
-- sequence is at least 0x80, so the escape tests never match inside one.
-- Runs that need no escape are copied whole.
writeString :: Bool -> IORef Buffer -> Int -> Text -> IO Int
writeString asciiOnly ref offset (TI.Text array from size)
  | firstSpecial == stop = do
      base <- reserve ref offset (size + 2)
      pokeByteOff base offset (0x22 :: Word8)
      stToIO (TA.copyToPointer array from (base `plusPtr` (offset + 1)) size)
      pokeByteOff base (offset + size + 1) (0x22 :: Word8)
      pure (offset + size + 2)
  | otherwise = do
      -- The longest escape spells one input byte in six output bytes.
      base <- reserve ref offset (6 * size + 2)
      pokeByteOff base offset (0x22 :: Word8)
      end <- runs base from firstSpecial (offset + 1)
      pokeByteOff base end (0x22 :: Word8)
      pure (end + 1)
  where
    stop = from + size
    -- A byte to escape: a C0 control, a quote, a backslash and, under
    -- 'ensureAscii', anything from 0x7F up.
    limit = if asciiOnly then 0x7F - 0x20 else 0x100 - 0x20 :: Word
    special w = (fromIntegral w - 0x20 :: Word) >= limit || w == 0x22 || w == 0x5C
    scan i
      | i >= stop = i
      | special (TA.unsafeIndex array i) = i
      | otherwise = scan (i + 1)
    firstSpecial = scan from
    -- Copy the plain run [start, at), then escape the character at @at@.
    runs :: Ptr Word8 -> Int -> Int -> Int -> IO Int
    runs base start at out = do
      let plain = at - start
      when (plain > 0) (stToIO (TA.copyToPointer array start (base `plusPtr` out) plain))
      let out' = out + plain
      if at >= stop
        then pure out'
        else do
          let w = TA.unsafeIndex array at
          if w < 0x80
            then do
              out'' <- escapeByte base out' w
              runs base (at + 1) (scan (at + 1)) out''
            else do
              let TU.Iter c delta = TU.iterArray array at
                  n = ord c
              out'' <-
                if n > 0xFFFF
                  then do
                    let v = n - 0x10000
                    middle <- unicodeEscape base out' (0xD800 + v `shiftR` 10)
                    unicodeEscape base middle (0xDC00 + v .&. 0x3FF)
                  else unicodeEscape base out' n
              runs base (at + delta) (scan (at + delta)) out''
    escapeByte base out w = case w of
      0x22 -> twoAt base out 0x22
      0x5C -> twoAt base out 0x5C
      0x0A -> twoAt base out 0x6E
      0x0D -> twoAt base out 0x72
      0x09 -> twoAt base out 0x74
      0x08 -> twoAt base out 0x62
      0x0C -> twoAt base out 0x66
      _ -> unicodeEscape base out (fromIntegral w)
    twoAt base out w = do
      pokeByteOff base out (0x5C :: Word8)
      pokeByteOff base (out + 1) (w :: Word8)
      pure (out + 2)
    unicodeEscape :: Ptr Word8 -> Int -> Int -> IO Int
    unicodeEscape base out n = do
      pokeByteOff base out (0x5C :: Word8)
      pokeByteOff base (out + 1) (0x75 :: Word8)
      let digit k = let d = (n `shiftR` (4 * k)) .&. 0xF in fromIntegral (if d < 10 then 0x30 + d else 0x57 + d) :: Word8
      pokeByteOff base (out + 2) (digit 3)
      pokeByteOff base (out + 3) (digit 2)
      pokeByteOff base (out + 4) (digit 1)
      pokeByteOff base (out + 5) (digit 0)
      pure (out + 6)

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

-- | The smallest integer with more than 'maxIntStrDigits' digits.
intDigitBound :: Integer
intDigitBound = 10 ^ maxIntStrDigits
{-# NOINLINE intDigitBound #-}
