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
  , column
  , nullable
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Petrus.Json (Json, parseJson, surrogateRefusingLoads)
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
decodeJson = parseJson surrogateRefusingLoads

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

-- | Decode a non-null column value, failing on @NULL@.
column :: (ByteString -> Either String a) -> Maybe ByteString -> Either String a
column decode = maybe (Left "unexpected NULL") decode

-- | Decode a nullable column value (@NULL@ is 'Nothing', Python @None@).
nullable :: (ByteString -> Either String a) -> Maybe ByteString -> Either String (Maybe a)
nullable decode = traverse decode
