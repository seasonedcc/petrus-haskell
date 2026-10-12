-- | Statement text and parameters, spelled the way upstream's psycopg 3
-- calls spell them.
--
-- Upstream SQL uses psycopg's @%s@ placeholders; 'Sql' converts them to
-- libpq's @$1@, @$2@, … once per statement value (a top-level 'Sql'
-- constant converts once per program), so upstream statements can be
-- copied verbatim. Parameters carry the type OID psycopg would send for the
-- corresponding Python value: @str@ goes out untyped (OID 0, the server
-- infers the type from context, exactly as with psycopg), @int@ as
-- @int2@/@int4@/@int8@/@numeric@ chosen by magnitude, @bool@ as @bool@,
-- @float@ as @float8@, @bytes@ as @bytea@, @Jsonb(...)@ as @jsonb@ and
-- lists as arrays.
module Petrus.Postgres.Param
  ( -- * Statements
    Sql
  , sql
  , sqlSource
  , sqlRaw
  , sqlConverted
  , convertPlaceholders
  , quoteIdentifier

    -- * Parameters
  , Param (..)
  , ParamFormat (..)
  , nullParam
  , maybeParam
  , textParam
  , boolParam
  , intParam
  , integerParam
  , floatParam
  , byteaParam
  , jsonbParam
  , jsonbRawParam
  , textArrayParam
  , intArrayParam
  , timestamptzParam
  , typedParam

    -- * Type OIDs
  , oidBool
  , oidBytea
  , oidInt8
  , oidInt2
  , oidInt4
  , oidText
  , oidFloat8
  , oidNumeric
  , oidJsonb
  , oidUnknown
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Int (Int64)
import Data.String (IsString (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), defaultTimeLocale, formatTime, picosecondsToDiffTime)
import Data.Word (Word32)
import Petrus.Json (EncodeError, Json, defaultDumps, dumps, pythonFloatRepr)

-- | A statement in psycopg spelling. Construct with 'sql' or a string
-- literal (@OverloadedStrings@).
data Sql = Sql
  { sqlSource :: Text
  -- ^ The statement as written.
  , sqlRaw :: ~ByteString
  -- ^ UTF-8 of the statement as written, sent when there are no parameters
  -- (psycopg leaves a statement executed without parameters untouched,
  -- @%%@ included).
  , sqlConverted :: ~(Either Text (ByteString, Int))
  -- ^ The statement with placeholders converted, and their count.
  }

instance IsString Sql where
  fromString = sql . T.pack

instance Show Sql where
  show = show . sqlSource

-- | Prepare a statement.
sql :: Text -> Sql
sql source = Sql source (TE.encodeUtf8 source) (convertPlaceholders source)

-- | psycopg's positional placeholder conversion: each @%s@, @%b@ or @%t@
-- becomes the next @$n@, @%%@ becomes @%@, and a @%@ at the end of the text
-- or before a newline stays as it is. Other @%@ sequences are refused with
-- psycopg's messages. Placeholders are found anywhere in the text, string
-- literals included, as psycopg does.
convertPlaceholders :: Text -> Either Text (ByteString, Int)
convertPlaceholders = go [] 0
  where
    go acc n s =
      let (prefix, rest) = T.break (== '%') s
       in case T.uncons rest of
            Nothing -> Right (TE.encodeUtf8 (T.concat (reverse (prefix : acc))), n)
            Just (_, after) -> case T.uncons after of
              Nothing -> go ("%" : prefix : acc) n after
              Just (c, after')
                | c == '\n' -> go ("%" : prefix : acc) n after
                | c == '%' -> go ("%" : prefix : acc) n after'
                | c == 's' || c == 'b' || c == 't' ->
                    go (T.pack ('$' : show (n + 1)) : prefix : acc) (n + 1) after'
                | c == '(' -> Left (named rest)
                | c == ' ' ->
                    Left
                      "incomplete placeholder: '%'; if you want to use '%' as an operator you can double it up, i.e. use '%%'"
                | otherwise ->
                    Left ("only '%s', '%b', '%t' are allowed as placeholders, got '%" <> T.singleton c <> "'")
    named rest =
      let inner = T.drop 2 rest
          (name, close) = T.break (== ')') inner
       in if not (T.null name) && T.length close >= 2 && T.index close 1 /= '\n'
            then "named placeholders require a mapping of parameters"
            else "incomplete placeholder: '" <> T.takeWhile (\c -> c /= ' ' && c /= '\n' && c /= '\t') rest <> "'"

-- | psycopg's @sql.Identifier@ (libpq's @PQescapeIdentifier@): always
-- double-quoted, embedded double quotes doubled.
quoteIdentifier :: Text -> Text
quoteIdentifier name = "\"" <> T.replace "\"" "\"\"" name <> "\""

-- | How a parameter value is encoded on the wire.
data ParamFormat = TextFormat | BinaryFormat
  deriving stock (Eq, Show)

-- | One statement parameter: its type OID (0 lets the server infer it), its
-- encoded value ('Nothing' is SQL @NULL@) and the value's format.
data Param = Param
  { paramOid :: Word32
  , paramValue :: Maybe ByteString
  , paramFormat :: ParamFormat
  }
  deriving stock (Eq, Show)

oidBool, oidBytea, oidInt8, oidInt2, oidInt4, oidText, oidFloat8, oidNumeric, oidJsonb, oidUnknown :: Word32
oidBool = 16
oidBytea = 17
oidInt8 = 20
oidInt2 = 21
oidInt4 = 23
oidText = 25
oidFloat8 = 701
oidNumeric = 1700
oidJsonb = 3802
oidUnknown = 0

-- | Python @None@.
nullParam :: Param
nullParam = Param oidUnknown Nothing TextFormat

-- | 'nullParam' for 'Nothing'.
maybeParam :: (a -> Param) -> Maybe a -> Param
maybeParam = maybe nullParam

-- | Python @str@: untyped (OID 0), as psycopg sends it. A value containing
-- U+0000 is refused when the statement runs, with psycopg's message.
textParam :: Text -> Param
textParam t = Param oidUnknown (Just (TE.encodeUtf8 t)) TextFormat

-- | Python @bool@.
boolParam :: Bool -> Param
boolParam b = Param oidBool (Just (if b then "t" else "f")) TextFormat

-- | Python @int@ within 64 bits: @int2@, @int4@ or @int8@ by magnitude.
intParam :: Int64 -> Param
intParam n = Param (intOid (toInteger n)) (Just (BC.pack (show n))) TextFormat

-- | Python @int@ of any size (@numeric@ beyond 64 bits).
integerParam :: Integer -> Param
integerParam n = Param (intOid n) (Just (BC.pack (show n))) TextFormat

intOid :: Integer -> Word32
intOid n
  | n >= -32768 && n < 32768 = oidInt2
  | n >= -2147483648 && n < 2147483648 = oidInt4
  | n >= -9223372036854775808 && n < 9223372036854775808 = oidInt8
  | otherwise = oidNumeric

-- | Python @float@ (@float8@; @NaN@, @Infinity@ and @-Infinity@ spelled as
-- PostgreSQL reads them).
floatParam :: Double -> Param
floatParam d = Param oidFloat8 (Just spelled) TextFormat
  where
    spelled
      | isNaN d = "NaN"
      | isInfinite d = if d > 0 then "Infinity" else "-Infinity"
      | otherwise = BC.pack (pythonFloatRepr d)

-- | Python @bytes@ (@bytea@, sent in binary).
byteaParam :: ByteString -> Param
byteaParam b = Param oidBytea (Just b) BinaryFormat

-- | psycopg's @Jsonb(value)@: the value serialized by @json.dumps@ with its
-- defaults (so @NaN@ is spelled and then refused by the server, as
-- upstream's would be), typed @jsonb@.
jsonbParam :: Json -> Either EncodeError Param
jsonbParam value = jsonbRawParam <$> dumps defaultDumps value

-- | Already-serialized JSON text typed @jsonb@ (upstream's
-- @%s::jsonb@ with a @str@ is 'textParam' instead).
jsonbRawParam :: ByteString -> Param
jsonbRawParam b = Param oidJsonb (Just b) TextFormat

-- | A Python @list@ of @str@: an array literal sent untyped, as psycopg
-- sends it (@'{a,b}'@, elements quoted when needed).
textArrayParam :: [Text] -> Param
textArrayParam items = Param oidUnknown (Just (TE.encodeUtf8 ("{" <> T.intercalate "," (map element items) <> "}"))) TextFormat
  where
    element t
      | needsQuotes t = "\"" <> T.concatMap escape t <> "\""
      | otherwise = t
    needsQuotes t =
      T.null t || T.toLower t == "null" || T.any (\c -> c `elem` (",\"\\{}" :: String) || isSpace c) t
    isSpace c = c == ' ' || (c >= '\t' && c <= '\r')
    escape c
      | c == '"' || c == '\\' = T.pack ['\\', c]
      | otherwise = T.singleton c

-- | A Python @list@ of @int@: an @int2[]@, @int4[]@, @int8[]@ or
-- @numeric[]@ literal by the widest element, as psycopg chooses.
intArrayParam :: [Integer] -> Param
intArrayParam items = Param arrayOid (Just (BC.pack ("{" ++ commaSeparated ++ "}"))) TextFormat
  where
    commaSeparated = foldr (\n rest -> show n ++ (if null rest then "" else ',' : rest)) "" items
    arrayOid
      | null items = oidUnknown
      | otherwise = case maximum (0 : map width items) of
      0 -> 1005
      1 -> 1007
      2 -> 1016
      _ -> 1231
    width n
      | oid == oidInt2 = 0 :: Int
      | oid == oidInt4 = 1
      | oid == oidInt8 = 2
      | otherwise = 3
      where
        oid = intOid n

-- | A value in PostgreSQL's text input syntax with an explicit type OID.
typedParam :: Word32 -> ByteString -> Param
typedParam oid value = Param oid (Just value) TextFormat

-- | An aware UTC @datetime@ as @timestamptz@ (OID 1184): an ISO-8601
-- literal truncated to microseconds, the resolution of a Python
-- @datetime@ and of PostgreSQL (@2026-10-10 17:33:00.431234+00:00@, the
-- fraction without trailing zeros).
timestamptzParam :: UTCTime -> Param
timestamptzParam time =
  let micros = floor (toRational (utctDayTime time) * 1000000) :: Integer
      truncated = time {utctDayTime = picosecondsToDiffTime (micros * 1000000)}
   in typedParam 1184 (BC.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S%Q+00:00" truncated))
