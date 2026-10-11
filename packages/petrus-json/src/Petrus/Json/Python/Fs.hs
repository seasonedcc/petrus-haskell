-- | CPython's file-system codec on POSIX: UTF-8 with the @surrogateescape@
-- error handler (@os.fsdecode@, @os.fsencode@, and what @sys.argv@,
-- @os.listdir@ and @open@ apply to names).
--
-- Decoding never fails: each byte that does not begin a well-formed UTF-8
-- sequence becomes the lone surrogate @U+DC00 + byte@, kept in a WTF-8
-- 'Text' ("Petrus.Json.Wtf8"). Encoding turns those surrogates back into
-- their bytes, so names round-trip, and refuses any other surrogate with
-- CPython's @UnicodeEncodeError@.
module Petrus.Json.Python.Fs
  ( fsDecode
  , fsEncode
  , fsEncodeFailure
  ) where

import Data.Bits (shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Unsafe qualified as BU
import Data.Char (ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Petrus.Json.Python.Decode (CodecFailure (..))
import Petrus.Json.Python.Exception (PythonException, unicodeEncodeError)
import Petrus.Json.Wtf8 (hasLoneSurrogate, unsafeTextFromBytes)

-- | @bytes.decode("utf-8", "surrogateescape")@.
fsDecode :: ByteString -> Text
fsDecode bytes
  | BS.isValidUtf8 bytes = TE.decodeUtf8 bytes
  | otherwise = unsafeTextFromBytes (BL.toStrict (BB.toLazyByteString (go 0)))
  where
    size = BS.length bytes
    at = BU.unsafeIndex bytes
    go i
      | i >= size = mempty
      | otherwise = case wellFormed i of
          0 -> escape (at i) <> go (i + 1)
          n -> BB.byteString (BU.unsafeTake n (BU.unsafeDrop i bytes)) <> go (i + n)
    -- The length of the well-formed sequence at @i@ (strict UTF-8: no
    -- overlong form, no surrogate, nothing past U+10FFFF), or 0.
    wellFormed i
      | b0 < 0x80 = 1
      | b0 >= 0xC2 && b0 <= 0xDF = if follows 1 0x80 0xBF then 2 else 0
      | b0 == 0xE0 = three 0xA0 0xBF
      | b0 == 0xED = three 0x80 0x9F
      | b0 >= 0xE1 && b0 <= 0xEF = three 0x80 0xBF
      | b0 == 0xF0 = four 0x90 0xBF
      | b0 >= 0xF1 && b0 <= 0xF3 = four 0x80 0xBF
      | b0 == 0xF4 = four 0x80 0x8F
      | otherwise = 0
      where
        b0 = at i
        follows k lo hi = i + k < size && at (i + k) >= lo && at (i + k) <= hi
        three lo hi = if follows 1 lo hi && follows 2 0x80 0xBF then 3 else 0
        four lo hi = if follows 1 lo hi && follows 2 0x80 0xBF && follows 3 0x80 0xBF then 4 else 0
    -- U+DC00 + byte, spelled in generalized UTF-8.
    escape :: Word8 -> BB.Builder
    escape b =
      let code = 0xDC00 + fromIntegral b :: Int
       in BB.word8 0xED <> BB.word8 (0x80 .|. fromIntegral ((code `shiftR` 6) .&. 0x3F)) <> BB.word8 (0x80 .|. fromIntegral (code .&. 0x3F))

-- | @text.encode("utf-8", "surrogateescape")@: the bytes, or CPython's
-- @UnicodeEncodeError@.
fsEncode :: Text -> Either PythonException ByteString
fsEncode text
  | not (hasLoneSurrogate text) = Right (TE.encodeUtf8 text)
  | Just failure <- fsEncodeFailure text = Left (unicodeEncodeError text failure)
  | otherwise = Right (BL.toStrict (BB.toLazyByteString (foldMap char (T.unpack text))))
  where
    char c
      | n >= 0xDC80 && n <= 0xDCFF = BB.word8 (fromIntegral (n - 0xDC00))
      | otherwise = BB.charUtf8 c
      where
        n = ord c

-- | The failure 'fsEncode' reports, if any. CPython's encoder hands the
-- handler each run of surrogates; @surrogateescape@ writes the escapes
-- from its start and raises the original error, from the first surrogate
-- it cannot write to the end of the run.
fsEncodeFailure :: Text -> Maybe CodecFailure
fsEncodeFailure text
  | not (hasLoneSurrogate text) = Nothing
  | otherwise = go 0 (T.unpack text)
  where
    go _ [] = Nothing
    go position chars@(c : rest)
      | isSurrogate c =
          let (run, after) = span isSurrogate chars
              end = position + length run
           in case break (not . escapable) run of
                (_, []) -> go end after
                (written, _) -> Just (CodecFailure "utf-8" (position + length written) end "surrogates not allowed")
      | otherwise = go (position + 1) rest
    isSurrogate c = c >= '\xD800' && c <= '\xDFFF'
    escapable c = c >= '\xDC80' && c <= '\xDCFF'
