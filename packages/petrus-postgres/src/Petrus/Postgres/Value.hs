-- | Decoders for column values in PostgreSQL's text output format, giving
-- the Haskell counterparts of the Python values psycopg loads.
module Petrus.Postgres.Value
  ( decodeText
  , decodeInt
  , decodeInteger
  , decodeBool
  , decodeDouble
  , decodeJson
  , decodeBytea
  , decodeTimestamptz
  , column
  , nullable
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isDigit)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, picosecondsToDiffTime)
import Data.Word (Word8)
import Petrus.Json (Json, parseJson, pythonLoads)
import Text.Read (readMaybe)

-- | @text@, @varchar@, @uuid@ and every other type psycopg loads as @str@.
decodeText :: ByteString -> Either String Text
decodeText bytes = either (Left . show) Right (TE.decodeUtf8' bytes)

-- | @int2@, @int4@, @int8@ within 64 bits.
decodeInt :: ByteString -> Either String Int64
decodeInt bytes = case BC.readInt64 bytes of
  Just (n, rest) | BS.null rest -> Right n
  _ -> Left ("not an integer: " ++ show bytes)

-- | Any integer (@numeric@ without a fraction included).
decodeInteger :: ByteString -> Either String Integer
decodeInteger bytes = case BC.readInteger bytes of
  Just (n, rest) | BS.null rest -> Right n
  _ -> Left ("not an integer: " ++ show bytes)

-- | @bool@ (@t@ or @f@).
decodeBool :: ByteString -> Either String Bool
decodeBool = \case
  "t" -> Right True
  "f" -> Right False
  other -> Left ("not a boolean: " ++ show other)

-- | @float4@ and @float8@, including @NaN@ and the infinities.
decodeDouble :: ByteString -> Either String Double
decodeDouble = \case
  "NaN" -> Right (0 / 0)
  "Infinity" -> Right (1 / 0)
  "-Infinity" -> Right (-1 / 0)
  bytes -> maybe (Left ("not a float: " ++ show bytes)) Right (readMaybe (BC.unpack bytes))

-- | @json@ and @jsonb@, loaded as @json.loads@ loads them.
decodeJson :: ByteString -> Either String Json
decodeJson = parseJson pythonLoads

-- | @bytea@ in the hex output format (@\\x…@, PostgreSQL's default).
decodeBytea :: ByteString -> Either String ByteString
decodeBytea bytes = case BS.stripPrefix "\\x" bytes of
  Just hex | even (BS.length hex) -> maybe (Left "invalid bytea hex") (Right . BS.pack) (pairs hex)
  _ -> Left "bytea not in hex output format"
  where
    pairs hex
      | BS.null hex = Just []
      | otherwise = do
          high <- nibble (BS.index hex 0)
          low <- nibble (BS.index hex 1)
          ((high `shiftL` 4 .|. low) :) <$> pairs (BS.drop 2 hex)
    nibble :: Word8 -> Maybe Word8
    nibble w
      | w >= 48 && w <= 57 = Just (w - 48)
      | w >= 97 && w <= 102 = Just (w - 87)
      | w >= 65 && w <= 70 = Just (w - 55)
      | otherwise = Nothing

-- | @timestamptz@ in PostgreSQL's ISO output style
-- (@2026-10-10 17:33:00.431234-03@, the offset optionally with minutes and
-- seconds), as the aware @datetime@ psycopg loads, in UTC.
decodeTimestamptz :: ByteString -> Either String UTCTime
decodeTimestamptz raw = maybe (Left ("not an ISO timestamptz: " <> show raw)) Right $ do
  let text = BC.unpack raw
  (year, rest1) <- number text
  rest2 <- expect '-' rest1
  (month, rest3) <- number rest2
  rest4 <- expect '-' rest3
  (day, rest5) <- number rest4
  rest6 <- expect ' ' rest5
  (hour, rest7) <- number rest6
  rest8 <- expect ':' rest7
  (minute, rest9) <- number rest8
  rest10 <- expect ':' rest9
  (second, rest11) <- number rest10
  let (fraction, rest12) = case rest11 of
        '.' : more -> span isDigit more
        _ -> ("", rest11)
      picos = if null fraction then 0 else read (take 12 (fraction ++ replicate 12 '0')) :: Integer
  (sign, rest13) <- case rest12 of
    '+' : more -> Just (1, more)
    '-' : more -> Just (-1, more)
    _ -> Nothing
  (offsetHours, rest14) <- number rest13
  (offsetMinutes, rest15) <- optionalPart rest14
  (offsetSeconds, rest16) <- optionalPart rest15
  if null rest16 then Just () else Nothing
  let local =
        UTCTime
          (fromGregorian year (fromIntegral month) (fromIntegral day))
          (picosecondsToDiffTime ((hour * 3600 + minute * 60 + second) * 1000000000000 + picos))
      offset = sign * (offsetHours * 3600 + offsetMinutes * 60 + offsetSeconds)
  pure (addUTCTime (fromIntegral (negate offset)) local)
  where
    number s = case span isDigit s of
      ("", _) -> Nothing
      (digits, rest) -> Just (read digits :: Integer, rest)
    expect c (x : rest) | x == c = Just rest
    expect _ _ = Nothing
    optionalPart = \case
      ':' : more -> number more
      other -> Just (0, other)

-- | Decode a non-null column value, failing on @NULL@.
column :: (ByteString -> Either String a) -> Maybe ByteString -> Either String a
column decode = maybe (Left "unexpected NULL") decode

-- | Decode a nullable column value (@NULL@ is 'Nothing', Python @None@).
nullable :: (ByteString -> Either String a) -> Maybe ByteString -> Either String (Maybe a)
nullable decode = traverse decode
