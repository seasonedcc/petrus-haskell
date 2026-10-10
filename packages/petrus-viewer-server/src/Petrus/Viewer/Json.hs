-- | JSON values with JavaScript (V8) semantics.
--
-- The Node backend of the viewer never forwards bytes verbatim: every relay
-- does @JSON.stringify(JSON.parse(String(raw)))@ (plus one property
-- assignment), and the MCP server prints results with @JSON.stringify@. To
-- keep the bytes on the wire identical, this module models exactly what that
-- round trip preserves and normalizes:
--
-- * strings are kept in their canonical @JSON.stringify@ escaped form
--   ('JsString'), so lone surrogates (which 'Data.Text.Text' cannot hold)
--   survive and serialization is a copy;
-- * numbers are kept as their canonical ECMAScript spelling plus the double
--   they denote ('JsNumber', see "Petrus.Viewer.Json.Number");
-- * objects follow ECMAScript property order: array-index keys first in
--   ascending numeric order, then the rest in insertion order; a duplicate
--   key keeps its first position and its last value.
--
-- 'parseJs' accepts exactly what @JSON.parse@ accepts on a well-formed UTF-8
-- input. Callers decode wire bytes with 'decodeLenient' first, which mirrors
-- Node's @Buffer#toString('utf8')@ replacement of malformed sequences.
module Petrus.Viewer.Json
  ( -- * Values
    JsValue (..)
  , JsString
  , JsNumber
  , JsObject
    -- * Parsing and encoding
  , parseJs
  , decodeLenient
  , encodeJs
  , encodeJsBuilder
  , encodeJsLazy
  , encodePretty
    -- * Strings
  , jsString
  , jsStringText
  , jsStringBytes
  , unsafeJsStringFromCanonical
    -- * Numbers
  , jsNumber
  , jsInt
  , jsNumberValue
  , jsNumberText
    -- * Objects
  , objectFromList
  , objectToList
  , emptyObject
  , lookupKey
  , lookupKeyS
  , insertKey
  , insertKeyS
  , deleteKey
  , objectKeys
  , objectSize
    -- * Convenience
  , str
  , num
  , int
  , obj
  , arr
  , truthy
  , jsTypeName
  , jsToString
  , asText
  , asObject
  , asNumber
  , asBool
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Builder.Prim qualified as BP
import Data.ByteString.Internal qualified as BI
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Unsafe qualified as BU
import Control.Monad (foldM, void)
import Data.Char (chr, ord)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.C.Types (CSize (..))
import System.IO.Unsafe (unsafeDupablePerformIO)
import Foreign.Storable (poke)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Word (Word16, Word32, Word8)
import Numeric (showHex)
import Petrus.Viewer.Json.Number

-- | A JSON string held in its canonical @JSON.stringify@ escaped form,
-- without the surrounding quotes. Two JavaScript strings are equal exactly
-- when their canonical forms are equal.
newtype JsString = JsString ByteString
  deriving stock (Eq, Ord)

instance Show JsString where
  show (JsString b) = show b

-- | A JSON number: its canonical ECMAScript spelling and its value.
data JsNumber = JsNumber
  { numText :: ByteString
  , numValue :: ~Double
  }

instance Eq JsNumber where
  a == b = numText a == numText b

instance Show JsNumber where
  show = BC.unpack . numText

-- | An object in ECMAScript own-property order.
newtype JsObject = JsObject [(JsString, JsValue)]
  deriving stock (Eq, Show)

data JsValue
  = JsNull
  | JsBool Bool
  | JsNum JsNumber
  | JsStr JsString
  | JsArr [JsValue]
  | JsObj JsObject
  deriving stock (Eq, Show)

------------------------------------------------------------------------------
-- Strings

-- | The JavaScript string for a 'Text'.
jsString :: Text -> JsString
jsString t = JsString (escapeUtf8 (TE.encodeUtf8 t))

-- | UTF-8 bytes of a 'Text' as @JSON.stringify@ writes them inside quotes.
-- A 'Text' holds no lone surrogates, so only ASCII needs escaping. One pass
-- sizes the output, one pass writes it (@cbits/json_escape.c@: the hot
-- path of every string sent to a browser, such as a whole net file).
escapeUtf8 :: ByteString -> ByteString
escapeUtf8 b = unsafeDupablePerformIO $ BU.unsafeUseAsCStringLen b $ \(src, len) -> do
  extra <- fromIntegral <$> c_escapeExtra (castPtr src) (fromIntegral len)
  if extra == 0
    then pure b
    else BI.create (len + extra) $ \dst -> c_escapeWrite (castPtr src) (fromIntegral len) dst (fromIntegral (len + extra))

foreign import ccall unsafe "petrus_json_escape_extra"
  c_escapeExtra :: Ptr Word8 -> CSize -> IO CSize

foreign import ccall unsafe "petrus_json_escape_write"
  c_escapeWrite :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO ()

-- | Wrap bytes already in canonical escaped form (callers must guarantee it).
unsafeJsStringFromCanonical :: ByteString -> JsString
unsafeJsStringFromCanonical = JsString

-- | The canonical escaped bytes (the inside of the JSON string literal).
jsStringBytes :: JsString -> ByteString
jsStringBytes (JsString b) = b

-- | The string as 'Text'. Lone surrogates become U+FFFD.
jsStringText :: JsString -> Text
jsStringText (JsString b)
  | B.notElem 0x5c b = TE.decodeUtf8With TE.lenientDecode b
  | otherwise = T.pack (go (BC.unpack b))
  where
    -- the canonical form only contains \" \\ \b \f \n \r \t \u00XX and
    -- lone-surrogate \uDXXX escapes; everything else is literal UTF-8
    go [] = []
    go ('\\' : c : rest) = case c of
      '"' -> '"' : go rest
      '\\' -> '\\' : go rest
      'b' -> '\b' : go rest
      'f' -> '\f' : go rest
      'n' -> '\n' : go rest
      'r' -> '\r' : go rest
      't' -> '\t' : go rest
      'u' ->
        let (h, rest') = splitAt 4 rest
            v = foldl (\acc x -> acc * 16 + hexVal x) 0 h
         in (if v >= 0xD800 && v <= 0xDFFF then '\xFFFD' else chr v) : go rest'
      other -> other : go rest
    go s =
      let (lit, rest) = break (== '\\') s
       in T.unpack (TE.decodeUtf8With TE.lenientDecode (BC.pack lit)) ++ go rest
    hexVal x
      | x >= '0' && x <= '9' = ord x - 48
      | x >= 'a' && x <= 'f' = ord x - 87
      | otherwise = ord x - 55

------------------------------------------------------------------------------
-- Numbers

jsNumber :: Double -> JsNumber
jsNumber d = JsNumber (formatDouble d) d

jsInt :: Int -> JsNumber
jsInt i = JsNumber (BC.pack (show i)) (fromIntegral i)

jsNumberValue :: JsNumber -> Double
jsNumberValue = numValue

jsNumberText :: JsNumber -> ByteString
jsNumberText = numText

------------------------------------------------------------------------------
-- Objects

emptyObject :: JsObject
emptyObject = JsObject []

objectToList :: JsObject -> [(JsString, JsValue)]
objectToList (JsObject kvs) = kvs

objectKeys :: JsObject -> [JsString]
objectKeys (JsObject kvs) = map fst kvs

objectSize :: JsObject -> Int
objectSize (JsObject kvs) = length kvs

-- | Build an object from members in insertion order, applying ECMAScript
-- duplicate and property-order rules.
objectFromList :: [(JsString, JsValue)] -> JsObject
objectFromList kvs = JsObject (orderIndexKeys (dedupe kvs))

dedupe :: [(JsString, JsValue)] -> [(JsString, JsValue)]
dedupe kvs = case kvs of
  [] -> []
  [_] -> kvs
  _
    | small kvs (16 :: Int) -> if noDupSmall [] kvs then kvs else slow
    | otherwise -> case foldr (\(k, _) acc -> acc >>= \m -> if Map.member k m then Nothing else Just (Map.insert k () m)) (Just Map.empty) kvs of
        Just _ -> kvs
        Nothing -> slow
  where
    small [] _ = True
    small _ 0 = False
    small (_ : r) n = small r (n - 1)
    noDupSmall _ [] = True
    noDupSmall seen ((k, _) : r) = notElem k seen && noDupSmall (k : seen) r
    slow =
      let lastVal = Map.fromList kvs -- later entries win
          go _ [] = []
          go seen ((k, _) : r)
            | Map.member k seen = go seen r
            | otherwise = (k, lastVal Map.! k) : go (Map.insert k () seen) r
       in go Map.empty kvs

orderIndexKeys :: [(JsString, JsValue)] -> [(JsString, JsValue)]
orderIndexKeys kvs
  | any (isArrayIndex . fst) kvs =
      let (idx, rest) = foldr (\kv (is, rs) -> if isArrayIndex (fst kv) then (kv : is, rs) else (is, kv : rs)) ([], []) kvs
       in sortOn (indexValue . fst) idx ++ rest
  | otherwise = kvs

-- | ECMAScript array index: canonical decimal of an integer in [0, 2^32 - 2].
isArrayIndex :: JsString -> Bool
isArrayIndex (JsString b) =
  let n = B.length b
   in n > 0
        && n <= 10
        && B.all (\w -> w >= 0x30 && w <= 0x39) b
        && (n == 1 || BU.unsafeHead b /= 0x30)
        && indexValue (JsString b) <= 4294967294

indexValue :: JsString -> Integer
indexValue (JsString b) = B.foldl' (\acc w -> acc * 10 + toInteger (w - 0x30)) 0 b

lookupKeyS :: JsString -> JsObject -> Maybe JsValue
lookupKeyS k (JsObject kvs) = lookup k kvs

lookupKey :: Text -> JsObject -> Maybe JsValue
lookupKey = lookupKeyS . jsString

-- | @o[k] = v@: replace in place, or add at the ECMAScript position.
insertKeyS :: JsString -> JsValue -> JsObject -> JsObject
insertKeyS k v (JsObject kvs)
  | any ((== k) . fst) kvs = JsObject (map (\(k', v') -> if k' == k then (k', v) else (k', v')) kvs)
  | isArrayIndex k = JsObject (orderIndexKeys (kvs ++ [(k, v)]))
  | otherwise = JsObject (kvs ++ [(k, v)])

insertKey :: Text -> JsValue -> JsObject -> JsObject
insertKey = insertKeyS . jsString

deleteKey :: Text -> JsObject -> JsObject
deleteKey k (JsObject kvs) = let k' = jsString k in JsObject (filter ((/= k') . fst) kvs)

------------------------------------------------------------------------------
-- Convenience

str :: Text -> JsValue
str = JsStr . jsString

num :: Double -> JsValue
num = JsNum . jsNumber

int :: Int -> JsValue
int = JsNum . jsInt

obj :: [(Text, JsValue)] -> JsValue
obj kvs = JsObj (objectFromList [(jsString k, v) | (k, v) <- kvs])

arr :: [JsValue] -> JsValue
arr = JsArr

-- | ECMAScript ToBoolean.
truthy :: JsValue -> Bool
truthy = \case
  JsNull -> False
  JsBool b -> b
  JsNum n -> let v = numValue n in not (v == 0 || isNaN v)
  JsStr (JsString b) -> not (B.null b)
  JsArr _ -> True
  JsObj _ -> True

-- | The type name zod reports for a value (@typeof@, with null and array
-- distinguished).
jsTypeName :: JsValue -> Text
jsTypeName = \case
  JsNull -> "null"
  JsBool _ -> "boolean"
  JsNum n -> if isNaN (numValue n) then "NaN" else "number"
  JsStr _ -> "string"
  JsArr _ -> "array"
  JsObj _ -> "object"

-- | ECMAScript @String(value)@ (as used by template literals).
jsToString :: JsValue -> Text
jsToString = \case
  JsStr s -> jsStringText s
  JsNum n
    | isInfinite v -> if v > 0 then "Infinity" else "-Infinity"
    | isNaN v -> "NaN"
    | otherwise -> TE.decodeUtf8 (numText n)
    where
      v = numValue n
  JsBool True -> "true"
  JsBool False -> "false"
  JsNull -> "null"
  JsArr xs -> T.intercalate "," (map element xs)
  JsObj _ -> "[object Object]"
  where
    element JsNull = ""
    element x = jsToString x

asText :: JsValue -> Maybe Text
asText = \case
  JsStr s -> Just (jsStringText s)
  _ -> Nothing

asObject :: JsValue -> Maybe JsObject
asObject = \case
  JsObj o -> Just o
  _ -> Nothing

asNumber :: JsValue -> Maybe Double
asNumber = \case
  JsNum n -> Just (numValue n)
  _ -> Nothing

asBool :: JsValue -> Maybe Bool
asBool = \case
  JsBool b -> Just b
  _ -> Nothing

------------------------------------------------------------------------------
-- Encoding

encodeJsBuilder :: JsValue -> BB.Builder
encodeJsBuilder = \case
  JsNull -> "null"
  JsBool True -> "true"
  JsBool False -> "false"
  JsNum n -> BB.byteString (numText n)
  JsStr (JsString s) -> quoted s
  JsArr [] -> "[]"
  JsArr (x : xs) -> BB.char7 '[' <> encodeJsBuilder x <> foldr (\y b -> BB.char7 ',' <> encodeJsBuilder y <> b) (BB.char7 ']') xs
  JsObj (JsObject []) -> "{}"
  JsObj (JsObject (kv : kvs)) -> BB.char7 '{' <> member kv <> foldr (\m b -> BB.char7 ',' <> member m <> b) (BB.char7 '}') kvs
  where
    member (JsString k, v) = quoted k <> BB.char7 ':' <> encodeJsBuilder v

quoted :: ByteString -> BB.Builder
quoted s = BB.char7 '"' <> BB.byteString s <> BB.char7 '"'
{-# INLINE quoted #-}

-- | @JSON.stringify(v)@. Every piece is already in its final spelling, so
-- encoding is one pass to size the output and one pass of copies into a
-- single buffer.
encodeJs :: JsValue -> ByteString
encodeJs v = BI.unsafeCreate (encodedSize v) (\p -> void (writeJs v p))

encodeJsLazy :: JsValue -> BL.ByteString
encodeJsLazy = BL.fromStrict . encodeJs

encodedSize :: JsValue -> Int
encodedSize = \case
  JsNull -> 4
  JsBool True -> 4
  JsBool False -> 5
  JsNum n -> B.length (numText n)
  JsStr (JsString s) -> B.length s + 2
  JsArr xs -> foldl' (\acc x -> acc + encodedSize x + 1) 1 xs + (if null xs then 1 else 0)
  JsObj (JsObject kvs) ->
    foldl' (\acc (JsString k, x) -> acc + B.length k + 4 + encodedSize x) 1 kvs + (if null kvs then 1 else 0)

writeJs :: JsValue -> Ptr Word8 -> IO (Ptr Word8)
writeJs v p = case v of
  JsNull -> bytes "null"
  JsBool True -> bytes "true"
  JsBool False -> bytes "false"
  JsNum n -> bytes (numText n)
  JsStr (JsString s) -> quotedAt s p
  JsArr [] -> bytes "[]"
  JsArr (x : xs) -> do
    q <- writeJs x =<< byteAt 0x5b p
    end <- foldM (\q' y -> writeJs y =<< byteAt 0x2c q') q xs
    byteAt 0x5d end
  JsObj (JsObject []) -> bytes "{}"
  JsObj (JsObject (kv : kvs)) -> do
    q <- member kv =<< byteAt 0x7b p
    end <- foldM (\q' m -> member m =<< byteAt 0x2c q') q kvs
    byteAt 0x7d end
  where
    bytes b = copyAt b p
    member (JsString k, x) q = writeJs x =<< byteAt 0x3a =<< quotedAt k q

byteAt :: Word8 -> Ptr Word8 -> IO (Ptr Word8)
byteAt w p = poke p w >> pure (p `plusPtr` 1)
{-# INLINE byteAt #-}

copyAt :: ByteString -> Ptr Word8 -> IO (Ptr Word8)
copyAt b p = BU.unsafeUseAsCStringLen b $ \(src, n) -> do
  copyBytes p (castPtr src) n
  pure (p `plusPtr` n)
{-# INLINE copyAt #-}

quotedAt :: ByteString -> Ptr Word8 -> IO (Ptr Word8)
quotedAt b p = byteAt 0x22 =<< copyAt b =<< byteAt 0x22 p
{-# INLINE quotedAt #-}

-- | @JSON.stringify(v, null, 2)@.
encodePretty :: JsValue -> ByteString
encodePretty v0 = BL.toStrict (BB.toLazyByteString (go 0 v0))
  where
    go :: Int -> JsValue -> BB.Builder
    go ind = \case
      JsArr [] -> "[]"
      JsArr xs ->
        "[\n"
          <> sepBy (map (\x -> pad (ind + 1) <> go (ind + 1) x) xs)
          <> "\n"
          <> pad ind
          <> "]"
      JsObj (JsObject []) -> "{}"
      JsObj (JsObject kvs) ->
        "{\n"
          <> sepBy (map (\(JsString k, x) -> pad (ind + 1) <> quoted k <> ": " <> go (ind + 1) x) kvs)
          <> "\n"
          <> pad ind
          <> "}"
      other -> encodeJsBuilder other
    pad n = BB.byteString (BC.replicate (2 * n) ' ')
    sepBy [] = mempty
    sepBy (b : bs) = b <> foldr (\x acc -> ",\n" <> x <> acc) mempty bs

------------------------------------------------------------------------------
-- Decoding

-- | Decode wire bytes the way Node's @Buffer#toString('utf8')@ does: valid
-- UTF-8 passes through untouched, malformed sequences become U+FFFD.
decodeLenient :: ByteString -> ByteString
decodeLenient b
  | B.isValidUtf8 b = b
  | otherwise = TE.encodeUtf8 (TE.decodeUtf8With TE.lenientDecode b)

-- | @JSON.parse@ on well-formed UTF-8 input. Failures carry the exact V8
-- @SyntaxError@ message (Node 22), which the Node backend surfaces verbatim
-- in some HTTP and MCP error payloads.
parseJs :: ByteString -> Either String JsValue
parseJs input =
  case value (skipWs 0) of
    Fail e -> Left (v8Message input e)
    Ok v i ->
      let j = skipWs i
       in if j == len then Right v else Left (v8Message input (ETrailing j))
  where
    len = B.length input
    at :: Int -> Word8
    at i = BU.unsafeIndex input i
    {-# INLINE at #-}

    skipWs i
      | i < len, isWs (at i) = skipWs (i + 1)
      | otherwise = i

    value i
      | i >= len = Fail EEnd
      | otherwise = case at i of
          0x7b -> object (skipWs (i + 1))
          0x5b -> array (skipWs (i + 1))
          0x22 -> case string (i + 1) of
            SOk s j -> Ok (JsStr s) j
            SFail e -> Fail e
          0x74 -> literal i "true" (JsBool True)
          0x66 -> literal i "false" (JsBool False)
          0x6e -> literal i "null" JsNull
          w | w == 0x2d || isDigitW w -> number i
          _ -> Fail (EToken i)

    literal i word v = go 0
      where
        n = B.length word
        go k
          | k == n = Ok v (i + n)
          | i + k >= len = Fail EEnd
          | at (i + k) == BU.unsafeIndex word k = go (k + 1)
          | otherwise = Fail (EToken (i + k))

    object i
      | i < len && at i == 0x7d = Ok (JsObj emptyObject) (i + 1)
      | i < len && at i == 0x22 = members [] i
      | otherwise = Fail (EExpPropOrBrace i)

    -- i points at the opening quote of a key
    members acc i = case string (i + 1) of
      SFail e -> Fail e
      SOk k j ->
        let j' = skipWs j
         in if j' < len && at j' == 0x3a
              then case value (skipWs (j' + 1)) of
                Fail e -> Fail e
                Ok v l ->
                  let l' = skipWs l
                   in if l' < len && at l' == 0x2c
                        then
                          let m = skipWs (l' + 1)
                           in if m < len && at m == 0x22
                                then members ((k, v) : acc) m
                                else Fail (EExpDqProp m)
                        else
                          if l' < len && at l' == 0x7d
                            then Ok (JsObj (objectFromList (reverse ((k, v) : acc)))) (l' + 1)
                            else Fail (EExpCommaBrace l')
              else Fail (EExpColon j')

    array i
      | i < len && at i == 0x5d = Ok (JsArr []) (i + 1)
      | otherwise = elements [] i

    elements acc i = case value i of
      Fail e -> Fail e
      Ok v j ->
        let j' = skipWs j
         in if j' < len && at j' == 0x2c
              then elements (v : acc) (skipWs (j' + 1))
              else
                if j' < len && at j' == 0x5d
                  then Ok (JsArr (reverse (v : acc))) (j' + 1)
                  else Fail (EExpCommaBracket j')

    number i =
      let i1 = if at i == 0x2d then i + 1 else i
       in if i1 >= len || not (isDigitW (at i1))
            then Fail (ENoNumMinus i1)
            else
              if at i1 == 0x30 && i1 + 1 < len && isDigitW (at (i1 + 1))
                then Fail (ENumberTok (i1 + 1))
                else
                  let i2 = if at i1 == 0x30 then i1 + 1 else digits (i1 + 1)
                   in fraction i i2

    fraction start i2
      | i2 < len && at i2 == 0x2e =
          if i2 + 1 < len && isDigitW (at (i2 + 1))
            then expPart start (digits (i2 + 2))
            else Fail (EUntermFrac (i2 + 1))
      | otherwise = expPart start i2

    expPart start i3
      | i3 < len && (at i3 == 0x65 || at i3 == 0x45) =
          let s = i3 + 1
              s' = if s < len && (at s == 0x2b || at s == 0x2d) then s + 1 else s
           in if s' < len && isDigitW (at s')
                then finish start (digits (s' + 1))
                else Fail (EExpMissing s')
      | otherwise = finish start i3

    finish start end =
      let lit = slice start end
          (canon, v) = canonicalLiteral lit
       in Ok (JsNum (JsNumber canon v)) end

    digits i
      | i < len && isDigitW (at i) = digits (i + 1)
      | otherwise = i

    -- strings: fast path for runs without escapes
    string i = plainRun i i

    plainRun start i
      | i >= len = SFail (EUntermString len)
      | otherwise =
          let w = at i
           in if w == 0x22
                then SOk (JsString (slice start i)) (i + 1)
                else
                  if w == 0x5c
                    then escaped (BB.byteString (slice start i)) i
                    else
                      if w < 0x20
                        then SFail (EBadControl i)
                        else plainRun start (i + 1)

    slice a b = BU.unsafeTake (b - a) (BU.unsafeDrop a input)

    -- slow path: i points at a backslash or at the start of a literal run
    escaped acc i
      | i >= len = SFail (EUntermString len)
      | otherwise = case at i of
          0x22 -> SOk (JsString (BL.toStrict (BB.toLazyByteString acc))) (i + 1)
          0x5c ->
            if i + 1 >= len
              then SFail EEnd
              else case at (i + 1) of
                0x22 -> escaped (acc <> "\\\"") (i + 2)
                0x5c -> escaped (acc <> "\\\\") (i + 2)
                0x2f -> escaped (acc <> "/") (i + 2)
                0x62 -> escaped (acc <> "\\b") (i + 2)
                0x66 -> escaped (acc <> "\\f") (i + 2)
                0x6e -> escaped (acc <> "\\n") (i + 2)
                0x72 -> escaped (acc <> "\\r") (i + 2)
                0x74 -> escaped (acc <> "\\t") (i + 2)
                0x75 -> case hexAt (i + 2) of
                  Left bad -> SFail (EBadUnicode bad)
                  Right c
                    | c >= 0xD800 && c <= 0xDBFF ->
                        case lowAt (i + 6) of
                          Just lo ->
                            let cp = 0x10000 + ((c - 0xD800) `shiftL` 10) + (lo - 0xDC00)
                             in escaped (acc <> utf8 cp) (i + 12)
                          Nothing -> escaped (acc <> "\\u" <> hexLower c) (i + 6)
                    | c >= 0xDC00 && c <= 0xDFFF -> escaped (acc <> "\\u" <> hexLower c) (i + 6)
                    | otherwise -> escaped (acc <> escapeCode c) (i + 6)
                _ -> SFail (EBadEscape (i + 1))
          w
            | w < 0x20 -> SFail (EBadControl i)
            | otherwise ->
                let end = runEnd i
                 in escaped (acc <> BB.byteString (slice i end)) end

    runEnd i
      | i < len, let w = at i, w /= 0x22 && w /= 0x5c && w >= 0x20 = runEnd (i + 1)
      | otherwise = i

    lowAt i
      | i + 1 < len && at i == 0x5c && at (i + 1) == 0x75 =
          case hexAt (i + 2) of
            Right lo | lo >= 0xDC00 && lo <= 0xDFFF -> Just lo
            _ -> Nothing
      | otherwise = Nothing

    -- four hex digits at i, or the position of the first offending byte
    hexAt :: Int -> Either Int Word32
    hexAt i = go 0 0
      where
        go :: Int -> Word32 -> Either Int Word32
        go k acc
          | k == 4 = Right acc
          | i + k >= len = Left (i + k)
          | otherwise = case hexDigit (at (i + k)) of
              Just d -> go (k + 1) ((acc `shiftL` 4) .|. d)
              Nothing -> Left (i + k)

data R = Ok JsValue Int | Fail PErr

data SR = SOk JsString Int | SFail PErr

-- | Where and why @JSON.parse@ failed (byte offsets into the input).
data PErr
  = EEnd
  | EToken Int
  | ENumberTok Int
  | EExpPropOrBrace Int
  | EExpColon Int
  | EExpCommaBrace Int
  | EExpDqProp Int
  | EExpCommaBracket Int
  | ETrailing Int
  | ENoNumMinus Int
  | EUntermFrac Int
  | EExpMissing Int
  | EUntermString Int
  | EBadControl Int
  | EBadEscape Int
  | EBadUnicode Int

-- | V8's @SyntaxError@ message text for a parse failure. Positions are
-- UTF-16 code-unit offsets, as in JavaScript.
v8Message :: ByteString -> PErr -> String
v8Message input = \case
  EEnd -> "Unexpected end of JSON input"
  EToken i
    -- V8 classifies the offending character: a quote starts a string
    -- token, a minus or digit a number token
    | i < B.length input, B.index input i == 0x22 -> atPos "Unexpected string in JSON" i
    | i < B.length input, let w = B.index input i, w == 0x2d || (w >= 0x30 && w <= 0x39) ->
        atPos "Unexpected number in JSON" i
    | otherwise -> unexpectedToken i
  ENumberTok i -> atPos "Unexpected number in JSON" i
  EExpPropOrBrace i -> atPos "Expected property name or '}' in JSON" i
  EExpColon i -> atPos "Expected ':' after property name in JSON" i
  EExpCommaBrace i -> atPos "Expected ',' or '}' after property value in JSON" i
  EExpDqProp i -> atPos "Expected double-quoted property name in JSON" i
  EExpCommaBracket i -> atPos "Expected ',' or ']' after array element in JSON" i
  ETrailing i -> atPos "Unexpected non-whitespace character after JSON" i
  ENoNumMinus i -> atPos "No number after minus sign in JSON" i
  EUntermFrac i -> atPos "Unterminated fractional number in JSON" i
  EExpMissing i -> atPos "Exponent part is missing a number in JSON" i
  EUntermString i -> atPos "Unterminated string in JSON" i
  EBadControl i -> atPos "Bad control character in string literal in JSON" i
  EBadEscape i
    -- V8 reports an escaped character beyond Latin-1 as an unexpected token
    | i < B.length input, B.index input i >= 0xC4 -> unexpectedToken i
    | otherwise -> atPos "Bad escaped character in JSON" i
  EBadUnicode i -> atPos "Bad Unicode escape in JSON" i
  where
    source = utf16Units (TE.decodeUtf8With TE.lenientDecode input)
    total = length source
    unitPos i = utf16Length (TE.decodeUtf8With TE.lenientDecode (B.take i input))
    atPos msg i =
      let p = unitPos i
          -- line terminators: LF, CR, and CR LF (counted once)
          breaks = [k | (k, u, nxt) <- zip3 [0 ..] source (drop 1 source ++ [0]), k < p, u == 0x0a || (u == 0x0d && nxt /= 0x0a)]
          line = 1 + length breaks
          col = if null breaks then p + 1 else p - last breaks
       in msg ++ " at position " ++ show p ++ " (line " ++ show line ++ " column " ++ show col ++ ")"
    whole = unitsString source
    unexpectedToken i
      | whole `elem` ["NaN", "Infinity", "undefined", "[object Object]"] = "\"" ++ whole ++ "\" is not valid JSON"
      | otherwise =
          let p = unitPos i
              c = unitsString (take 1 (drop p source))
              sub a b = unitsString (take (b - a) (drop a source))
              ctx = 10 :: Int
              tok = "Unexpected token '" ++ c ++ "', "
           in if total < 2 * ctx + 1
                then tok ++ "\"" ++ whole ++ "\" is not valid JSON"
                else
                  if p < ctx
                    then tok ++ "\"" ++ sub 0 (p + ctx) ++ "\"... is not valid JSON"
                    else
                      if p < total - ctx
                        then tok ++ "...\"" ++ sub (p - ctx) (p + ctx) ++ "\"... is not valid JSON"
                        else tok ++ "...\"" ++ sub (p - ctx) total ++ "\" is not valid JSON"

utf16Units :: Text -> [Word16]
utf16Units = concatMap unitsOf . T.unpack
  where
    unitsOf c
      | ord c < 0x10000 = [fromIntegral (ord c)]
      | otherwise =
          let v = ord c - 0x10000
           in [fromIntegral (0xD800 + (v `shiftR` 10)), fromIntegral (0xDC00 + (v .&. 0x3FF))]

utf16Length :: Text -> Int
utf16Length = T.foldl' (\n c -> n + if ord c < 0x10000 then 1 else 2) 0

-- | Render UTF-16 units back to a 'String', pairing surrogates.
unitsString :: [Word16] -> String
unitsString = \case
  [] -> []
  (h : l : rest)
    | h >= 0xD800 && h <= 0xDBFF && l >= 0xDC00 && l <= 0xDFFF ->
        chr (0x10000 + ((fromIntegral h - 0xD800) `shiftL` 10) + (fromIntegral l - 0xDC00)) : unitsString rest
  (u : rest)
    | u >= 0xD800 && u <= 0xDFFF -> '\xFFFD' : unitsString rest
    | otherwise -> chr (fromIntegral u) : unitsString rest

isWs :: Word8 -> Bool
isWs w = w == 0x20 || w == 0x0a || w == 0x0d || w == 0x09
{-# INLINE isWs #-}

isDigitW :: Word8 -> Bool
isDigitW w = w >= 0x30 && w <= 0x39
{-# INLINE isDigitW #-}

hexDigit :: Word8 -> Maybe Word32
hexDigit w
  | w >= 0x30 && w <= 0x39 = Just (fromIntegral (w - 0x30))
  | w >= 0x61 && w <= 0x66 = Just (fromIntegral (w - 0x57))
  | w >= 0x41 && w <= 0x46 = Just (fromIntegral (w - 0x37))
  | otherwise = Nothing

hexLower :: Word32 -> BB.Builder
hexLower w = BB.string7 (replicate (4 - length h) '0' ++ h)
  where
    h = showHex w ""

-- | Canonical output for a non-surrogate code unit from a @\\uXXXX@ escape.
escapeCode :: Word32 -> BB.Builder
escapeCode c = case c of
  0x22 -> "\\\""
  0x5c -> "\\\\"
  0x08 -> "\\b"
  0x0c -> "\\f"
  0x0a -> "\\n"
  0x0d -> "\\r"
  0x09 -> "\\t"
  _
    | c < 0x20 -> "\\u" <> hexLower c
    | otherwise -> utf8 c

utf8 :: Word32 -> BB.Builder
utf8 c
  | c < 0x80 = BB.word8 (fromIntegral c)
  | c < 0x800 = BP.primFixed (BP.word8 BP.>*< BP.word8) (byte (0xC0 .|. (c `shiftR` 6)), byte (0x80 .|. (c .&. 0x3F)))
  | c < 0x10000 =
      BB.word8 (byte (0xE0 .|. (c `shiftR` 12)))
        <> BB.word8 (byte (0x80 .|. ((c `shiftR` 6) .&. 0x3F)))
        <> BB.word8 (byte (0x80 .|. (c .&. 0x3F)))
  | otherwise =
      BB.word8 (byte (0xF0 .|. (c `shiftR` 18)))
        <> BB.word8 (byte (0x80 .|. ((c `shiftR` 12) .&. 0x3F)))
        <> BB.word8 (byte (0x80 .|. ((c `shiftR` 6) .&. 0x3F)))
        <> BB.word8 (byte (0x80 .|. (c .&. 0x3F)))
  where
    byte = fromIntegral :: Word32 -> Word8
