{-# LANGUAGE MultiWayIf #-}

-- | Strings holding lone surrogates, as Python's @str@ can.
--
-- CPython's @json.loads@ admits a lone surrogate escape (@"\\ud800"@) and
-- its @json.dumps@ writes one back (@ensure_ascii@ escapes it again). A
-- 'Text' holds Unicode scalar values only, so petrus-json represents such a
-- string as a 'Text' whose bytes are WTF-8 (<https://wtf-8.codeberg.page/>):
-- UTF-8, except that a surrogate code point U+D800–U+DFFF is spelled with
-- its generalized three-byte sequence (@ED A0 80@ for U+D800).
--
-- Such a 'Text' behaves like the Python @str@ it stands for:
--
-- * equality is byte equality, so two strings are equal exactly when their
--   code points are (WTF-8 is injective);
-- * ordering is byte order, which is code point order, CPython's @str@ order
--   (and what @sort_keys@ uses);
-- * 'Data.Text.length', 'Data.Text.unpack' and iteration see the surrogate as
--   one 'Char' (GHC's 'Char' admits surrogate code points);
-- * 'Petrus.Json.Encode.dumps' writes the surrogate back as @\\udXXX@ under
--   @ensure_ascii@, and as its WTF-8 bytes otherwise (the bytes of the @str@
--   CPython returns, which CPython itself could not encode as UTF-8 either).
--
-- Only the parser ('Petrus.Json.Parse.KeepLoneSurrogates', which a reader
-- asks for explicitly) and 'fromCodePoints' / 'fromWtf8' build such a 'Text';
-- 'Data.Text.pack' and friends still replace surrogates with U+FFFD, and
-- every value without a lone surrogate is ordinary UTF-8. A writer that
-- needs strict UTF-8 checks 'hasLoneSurrogate' first, as CPython's
-- @str.encode()@ refuses such a string.
module Petrus.Json.Wtf8
  ( fromCodePoints
  , fromWtf8
  , hasLoneSurrogate
  , holdsLoneSurrogate
  , lossyUtf8
  , surrogateText
  , unsafeTextFromBytes
  ) where

import Data.Bits (shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BU
import Data.Char (ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Array qualified as TA
import Data.Text.Encoding qualified as TE
import Data.Text.Foreign qualified as TF
import Data.Text.Internal qualified as TI
import Data.Word (Word8)
import Petrus.Json.Value (Json (..))
import Foreign.Ptr (castPtr)
import System.IO.Unsafe (unsafeDupablePerformIO)

-- | Copy bytes into a 'Text' without validating them. The caller guarantees
-- they are UTF-8, or WTF-8 as this module describes.
-- unsafeDupablePerformIO: writes only the array this call allocates.
unsafeTextFromBytes :: ByteString -> Text
unsafeTextFromBytes bytes
  | BS.null bytes = T.empty
  | otherwise =
      unsafeDupablePerformIO
        (BU.unsafeUseAsCStringLen bytes (\(pointer, size) -> TF.fromPtr (castPtr pointer) (fromIntegral size)))

-- | The one-code-point string of a surrogate (0xD800–0xDFFF), in WTF-8.
-- Any other code point is a caller's bug ('error'), as 'chr' treats one
-- past U+10FFFF.
surrogateText :: Int -> Text
surrogateText code
  | code < 0xD800 || code > 0xDFFF = error ("surrogateText: not a surrogate code point " ++ show code)
  | otherwise = unsafeTextFromBytes (BS.pack (threeBytes code))

threeBytes :: Int -> [Word8]
threeBytes code =
  [ fromIntegral (0xE0 .|. (code `shiftR` 12))
  , fromIntegral (0x80 .|. ((code `shiftR` 6) .&. 0x3F))
  , fromIntegral (0x80 .|. (code .&. 0x3F))
  ]

-- | 'Data.Text.pack' that keeps surrogate code points (as WTF-8) instead of
-- replacing them with U+FFFD: the Haskell spelling of a Python string
-- literal such as @"a\\ud800"@.
fromCodePoints :: String -> Text
fromCodePoints chars
  | any isSurrogate chars = unsafeTextFromBytes (BS.pack (concatMap encode chars))
  | otherwise = T.pack chars
  where
    isSurrogate c = ord c >= 0xD800 && ord c <= 0xDFFF
    encode c
      | isSurrogate c = threeBytes (ord c)
      | otherwise = BS.unpack (TE.encodeUtf8 (T.singleton c))

-- | Whether a 'Text' holds a surrogate code point (only a WTF-8 'Text' can).
-- It reads the text's own bytes: a surrogate's WTF-8 sequence starts
-- @ED A0@ to @ED BF@, which no UTF-8 sequence does.
hasLoneSurrogate :: Text -> Bool
hasLoneSurrogate (TI.Text array offset size) = go offset
  where
    end = offset + size
    go i
      | i + 1 >= end = False
      | TA.unsafeIndex array i == 0xED && TA.unsafeIndex array (i + 1) >= 0xA0 = True
      | otherwise = go (i + 1)

-- | Rust's @String::from_utf8_lossy@ of the string's WTF-8 bytes: each
-- surrogate's three bytes are three invalid sequences, so each becomes
-- three U+FFFD (how pydantic-core spells such a string in an error's
-- location).
lossyUtf8 :: Text -> Text
lossyUtf8 text
  | hasLoneSurrogate text = T.concatMap spell text
  | otherwise = text
  where
    spell c
      | ord c >= 0xD800 && ord c <= 0xDFFF = T.replicate 3 (T.singleton '\xFFFD')
      | otherwise = T.singleton c

-- | Whether any string of a value (member names included) holds a
-- surrogate code point.
holdsLoneSurrogate :: Json -> Bool
holdsLoneSurrogate = \case
  String s -> hasLoneSurrogate s
  Array items -> any holdsLoneSurrogate items
  Object members -> any (\(k, v) -> hasLoneSurrogate k || holdsLoneSurrogate v) members
  _ -> False

-- | The 'Text' of generalized UTF-8 bytes (UTF-8 that may also spell
-- surrogate code points, Python's @surrogatepass@), or 'Nothing' when the
-- bytes are not well-formed.
fromWtf8 :: ByteString -> Maybe Text
fromWtf8 bytes
  | valid 0 = Just (unsafeTextFromBytes bytes)
  | otherwise = Nothing
  where
    size = BS.length bytes
    byte i = BU.unsafeIndex bytes i
    continuation i = i < size && byte i .&. 0xC0 == 0x80
    inRange i lo hi = i < size && byte i >= lo && byte i <= hi
    valid i
      | i >= size = True
      | otherwise =
          let b = byte i
           in if
                | b < 0x80 -> valid (i + 1)
                | b >= 0xC2 && b <= 0xDF -> continuation (i + 1) && valid (i + 2)
                | b == 0xE0 -> inRange (i + 1) 0xA0 0xBF && continuation (i + 2) && valid (i + 3)
                | b >= 0xE1 && b <= 0xEF -> continuation (i + 1) && continuation (i + 2) && valid (i + 3)
                | b == 0xF0 -> inRange (i + 1) 0x90 0xBF && continuation (i + 2) && continuation (i + 3) && valid (i + 4)
                | b >= 0xF1 && b <= 0xF3 -> continuation (i + 1) && continuation (i + 2) && continuation (i + 3) && valid (i + 4)
                | b == 0xF4 -> inRange (i + 1) 0x80 0x8F && continuation (i + 2) && continuation (i + 3) && valid (i + 4)
                | otherwise -> False
