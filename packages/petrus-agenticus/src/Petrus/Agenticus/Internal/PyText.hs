-- | CPython text behaviours the agenticus adapters reproduce exactly.
--
-- = @bytes.decode("utf-8", errors="replace")@
--
-- CPython substitutes one U+FFFD for each /maximal subpart/ of an
-- ill-formed sequence (Unicode §3.9, "U+FFFD Substitution of Maximal
-- Subparts"): a lead byte followed by the longest prefix of valid
-- continuation bytes it admits. Surrogate encodings (@ED A0..BF@), overlong
-- forms (@C0@, @C1@, @E0 80..9F@, @F0 80..8F@) and code points above
-- U+10FFFF (@F4 90..@, @F5..FF@) are ill-formed. The byte that breaks a
-- sequence is not consumed; decoding resumes at it.
--
-- @text@'s lenient decoder does not promise this exact substitution count,
-- and agenticus returns decoded process output to the model, so the
-- reference's spelling is reproduced here.
module Petrus.Agenticus.Internal.PyText
  ( decodeReplace
  , boundedText
  , splitLines
  ) where

import Data.Bits (shiftL, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Unsafe qualified as BU
import Data.Char (chr)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)

replacement :: Char
replacement = '\xFFFD'

-- | @data.decode(errors="replace")@.
decodeReplace :: ByteString -> Text
decodeReplace bytes = case TE.decodeUtf8' bytes of
  Right valid -> valid
  Left _ -> T.pack (go 0)
  where
    n = B.length bytes
    at :: Int -> Word8
    at = BU.unsafeIndex bytes
    cont i = i < n && at i >= 0x80 && at i <= 0xBF
    inRange i lo hi = i < n && at i >= lo && at i <= hi
    go i
      | i >= n = []
      | b < 0x80 = chr (fromIntegral b) : go (i + 1)
      | b >= 0xC2 && b <= 0xDF =
          if cont (i + 1)
            then chr (((fromIntegral b .&. 0x1F) `shiftL` 6) .|. low (i + 1)) : go (i + 2)
            else replacement : go (i + 1)
      | b >= 0xE0 && b <= 0xEF =
          let (lo, hi) = case b of
                0xE0 -> (0xA0, 0xBF)
                0xED -> (0x80, 0x9F)
                _ -> (0x80, 0xBF)
           in if not (inRange (i + 1) lo hi)
                then replacement : go (i + 1)
                else
                  if not (cont (i + 2))
                    then replacement : go (i + 2)
                    else
                      chr (((fromIntegral b .&. 0x0F) `shiftL` 12) .|. (low (i + 1) `shiftL` 6) .|. low (i + 2))
                        : go (i + 3)
      | b >= 0xF0 && b <= 0xF4 =
          let (lo, hi) = case b of
                0xF0 -> (0x90, 0xBF)
                0xF4 -> (0x80, 0x8F)
                _ -> (0x80, 0xBF)
           in if not (inRange (i + 1) lo hi)
                then replacement : go (i + 1)
                else
                  if not (cont (i + 2))
                    then replacement : go (i + 2)
                    else
                      if not (cont (i + 3))
                        then replacement : go (i + 3)
                        else
                          chr
                            ( ((fromIntegral b .&. 0x07) `shiftL` 18)
                                .|. (low (i + 1) `shiftL` 12)
                                .|. (low (i + 2) `shiftL` 6)
                                .|. low (i + 3)
                            )
                            : go (i + 4)
      | otherwise = replacement : go (i + 1)
      where
        b = at i
    low :: Int -> Int
    low i = fromIntegral (at i) .&. 0x3F

-- | The reference's @_bounded_text(data, limit)@: decode at most @limit@
-- bytes with replacement, then drop trailing characters until the UTF-8
-- encoding fits @limit@ (a replacement character can be longer than the
-- bytes it replaced). The flag reports any truncation.
boundedText :: ByteString -> Int -> (Text, Bool)
boundedText bytes limit
  | fits = (decoded, B.length bytes > limit)
  | otherwise = (T.take (prefix 0 0 (T.unpack decoded)) decoded, True)
  where
    decoded = decodeReplace (B.take limit bytes)
    fits = B.length (TE.encodeUtf8 decoded) <= limit
    -- Dropping characters from the end until the encoding fits leaves the
    -- longest prefix whose encoding fits; count it in one pass.
    prefix :: Int -> Int -> String -> Int
    prefix count size = \case
      c : rest | size + width c <= limit -> prefix (count + 1) (size + width c) rest
      _ -> count
    width c
      | c < '\x80' = 1
      | c < '\x800' = 2
      | c < '\x10000' = 3
      | otherwise = 4

-- | @str.splitlines()@: every Unicode line boundary Python recognises, with
-- @\\r\\n@ as one boundary and no trailing empty line.
splitLines :: Text -> [Text]
splitLines text
  | T.null text = []
  | otherwise =
      let (line, rest) = T.break boundary text
       in line : case T.uncons rest of
            Nothing -> []
            Just ('\r', more) | Just ('\n', after) <- T.uncons more -> splitLines after
            Just (_, more) -> splitLines more
  where
    boundary c = c `elem` ("\n\r\v\f\x1c\x1d\x1e\x85\x2028\x2029" :: String)
