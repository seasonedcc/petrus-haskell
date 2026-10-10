-- | CPython's @payload.decode("utf-8")@ and @json.loads(text)@, including
-- the exact text of their errors.
--
-- The server answers a malformed request with
-- @invalid ZeroMQ Dispatch JSON message: {error}@, where @{error}@ is
-- CPython's 'UnicodeDecodeError' or 'json.JSONDecodeError' text, so a Haskell
-- server must spell those errors as CPython does. Values are parsed by
-- "Petrus.Json" ('pythonLoads'); only when a document is refused does
-- 'jsonDecodeError' re-scan it the way CPython's C scanner (@_json.c@) and
-- @json.decoder@ do, to find CPython's message and character position.
module Petrus.Motus.Transport.ZeroMQ.PythonDecode
  ( pythonUtf8
  , pythonJsonLoads
  , jsonDecodeError
  ) where

import Data.Array.Unboxed (UArray, bounds, listArray, (!))
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Numeric (showHex)
import Petrus.Json (Json, parseJson, pythonLoads)

-- | @bytes.decode("utf-8")@: the text, or CPython's @UnicodeDecodeError@
-- message.
pythonUtf8 :: ByteString -> Either Text Text
pythonUtf8 bytes = case TE.decodeUtf8' bytes of
  Right text -> Right text
  Left _ -> Left (maybe "'utf-8' codec can't decode bytes" id (utf8Error bytes))

-- | The first UTF-8 error, as CPython's strict UTF-8 decoder reports it.
utf8Error :: ByteString -> Maybe Text
utf8Error bytes = go 0
  where
    n = BS.length bytes
    at :: Int -> Word8
    at = BS.index bytes
    cont b = b .&. 0xC0 == 0x80
    go i
      | i >= n = Nothing
      | b0 < 0x80 = go (i + 1)
      | b0 < 0xC2 = report i (i + 1) "invalid start byte"
      | b0 < 0xE0 =
          if n - i < 2
            then report i n "unexpected end of data"
            else if not (cont (at (i + 1))) then report i (i + 1) "invalid continuation byte" else go (i + 2)
      | b0 < 0xF0 =
          let bad2 b = not (cont b) || (if b < 0xA0 then b0 == 0xE0 else b0 == 0xED)
           in if n - i < 3
                then
                  if n - i >= 2 && bad2 (at (i + 1))
                    then report i (i + 1) "invalid continuation byte"
                    else report i n "unexpected end of data"
                else
                  if bad2 (at (i + 1))
                    then report i (i + 1) "invalid continuation byte"
                    else
                      if not (cont (at (i + 2)))
                        then report i (i + 2) "invalid continuation byte"
                        else go (i + 3)
      | b0 < 0xF5 =
          let bad2 b = not (cont b) || (if b < 0x90 then b0 == 0xF0 else b0 == 0xF4)
           in if n - i < 4
                then
                  if n - i >= 2 && bad2 (at (i + 1))
                    then report i (i + 1) "invalid continuation byte"
                    else
                      if n - i >= 3 && not (cont (at (i + 2)))
                        then report i (i + 2) "invalid continuation byte"
                        else report i n "unexpected end of data"
                else
                  if bad2 (at (i + 1))
                    then report i (i + 1) "invalid continuation byte"
                    else
                      if not (cont (at (i + 2)))
                        then report i (i + 2) "invalid continuation byte"
                        else
                          if not (cont (at (i + 3)))
                            then report i (i + 3) "invalid continuation byte"
                            else go (i + 4)
      | otherwise = report i (i + 1) "invalid start byte"
      where
        b0 = at i
    report start end reason
      | end == start + 1 =
          Just
            ( "'utf-8' codec can't decode byte 0x"
                <> hex2 (at start)
                <> " in position "
                <> tshow start
                <> ": "
                <> reason
            )
      | otherwise =
          Just ("'utf-8' codec can't decode bytes in position " <> tshow start <> "-" <> tshow (end - 1) <> ": " <> reason)
    hex2 b = let h = showHex b "" in T.pack (replicate (2 - length h) '0' ++ h)

-- | @json.loads(payload.decode("utf-8"))@: the value, or the message of
-- the @ValueError@ CPython raises (a @UnicodeDecodeError@, a
-- @JSONDecodeError@, or the integer-digit limit's plain @ValueError@),
-- tagged with whether it is a decode error (@True@) or a plain
-- @ValueError@ (@False@), which the transport reports without its prefix.
pythonJsonLoads :: ByteString -> Either (Bool, Text) Json
pythonJsonLoads bytes = case pythonUtf8 bytes of
  Left message -> Left (True, message)
  Right text -> case parseJson pythonLoads bytes of
    Right value -> Right value
    Left problem -> case jsonDecodeError text of
      Just message -> Left (True, message)
      Nothing
        | "Exceeds the limit" `T.isPrefixOf` T.pack problem -> Left (False, T.pack problem)
        | otherwise -> Left (True, T.pack problem)

-- | CPython's @JSONDecodeError@ message for a document @json.loads@
-- refuses, or 'Nothing' when CPython's scanner accepts it.
jsonDecodeError :: Text -> Maybe Text
jsonDecodeError text
  | T.take 1 text == "\xFEFF" = Just (located "Unexpected UTF-8 BOM (decode using utf-8-sig)" 0)
  | otherwise = case scanValue (skipSpace 0) of
      Left (message, position) -> Just (located message position)
      Right end ->
        let end' = skipSpace end
         in if end' /= len then Just (located "Extra data" end') else Nothing
  where
    len = T.length text
    doc :: UArray Int Char
    doc = listArray (0, len - 1) (T.unpack text)
    char i = doc ! i
    lastIndex = snd (bounds doc)
    isSpace c = c == ' ' || c == '\t' || c == '\n' || c == '\r'
    skipSpace i
      | i <= lastIndex && isSpace (char i) = skipSpace (i + 1)
      | otherwise = i
    located message position =
      let before = T.take position text
          line = T.count "\n" before + 1
          column = case T.breakOnEnd "\n" before of
            ("", _) -> position + 1
            (prefix, _) -> position - (T.length prefix - 1)
       in T.pack message <> ": line " <> tshow line <> " column " <> tshow column <> " (char " <> tshow position <> ")"
    matches i word = i + length word <= len && all (\(k, c) -> char (i + k) == c) (zip [0 ..] word)

    -- scan_once_unicode
    scanValue :: Int -> Either (String, Int) Int
    scanValue i
      | i >= len = Left ("Expecting value", i)
      | otherwise = case char i of
          '"' -> scanString (i + 1)
          '{' -> scanObject (i + 1)
          '[' -> scanArray (i + 1)
          'n' | i + 3 < len && matches i "null" -> Right (i + 4)
          't' | i + 3 < len && matches i "true" -> Right (i + 4)
          'f' | i + 4 < len && matches i "false" -> Right (i + 5)
          'N' | i + 2 < len && matches i "NaN" -> Right (i + 3)
          'I' | i + 7 < len && matches i "Infinity" -> Right (i + 8)
          '-' | i + 8 < len && matches i "-Infinity" -> Right (i + 9)
          _ -> scanNumber i

    -- _match_number_unicode
    scanNumber start = do
      afterSign <-
        if char start == '-'
          then if start + 1 > lastIndex then Left ("Expecting value", start) else Right (start + 1)
          else Right start
      let c = char afterSign
      afterInt <-
        if c >= '1' && c <= '9'
          then Right (digits (afterSign + 1))
          else if c == '0' then Right (afterSign + 1) else Left ("Expecting value", start)
      let afterFrac =
            if afterInt < lastIndex && char afterInt == '.' && isDigit (char (afterInt + 1))
              then digits (afterInt + 2)
              else afterInt
          afterExp =
            if afterFrac < lastIndex && (char afterFrac == 'e' || char afterFrac == 'E')
              then
                let signAt = afterFrac + 1
                    afterSign' = if signAt < lastIndex && (char signAt == '-' || char signAt == '+') then signAt + 1 else signAt
                    end = digits afterSign'
                 in if isDigit (char (end - 1)) then end else afterFrac
              else afterFrac
      Right afterExp
    digits i
      | i <= lastIndex && isDigit (char i) = digits (i + 1)
      | otherwise = i

    -- scanstring_unicode (strict)
    scanString :: Int -> Either (String, Int) Int
    scanString begin1 = chunk begin1
      where
        begin = begin1 - 1
        chunk end = findStop end
        findStop next
          | next >= len = Left ("Unterminated string starting at", begin)
          | otherwise =
              let d = char next
               in if d == '"'
                    then Right (next + 1)
                    else
                      if d == '\\'
                        then escape (next + 1)
                        else
                          if d <= '\x1f'
                            then Left ("Invalid control character at", next)
                            else findStop (next + 1)
        escape next
          | next == len = Left ("Unterminated string starting at", begin)
          | char next /= 'u' =
              if char next `elem` ("\"\\/bfnrt" :: String)
                then chunk (next + 1)
                else Left ("Invalid \\escape", next - 1)
          | otherwise =
              let first = next + 1
                  end = first + 4
               in if end >= len
                    then Left ("Invalid \\uXXXX escape", first - 1)
                    else
                      if not (all (isHex . char) [first .. end - 1])
                        then Left ("Invalid \\uXXXX escape", end - 5)
                        else
                          let code = hexValue [char k | k <- [first .. end - 1]]
                           in if code >= 0xD800 && code <= 0xDBFF && end + 6 < len && char end == '\\' && char (end + 1) == 'u'
                                then
                                  let end2 = end + 6
                                   in if not (all (isHex . char) [end + 2 .. end2 - 1])
                                        then Left ("Invalid \\uXXXX escape", end2 - 5)
                                        else
                                          let low = hexValue [char k | k <- [end + 2 .. end2 - 1]]
                                           in if low >= 0xDC00 && low <= 0xDFFF then chunk end2 else chunk end
                                else chunk end
    isHex c = isDigit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
    hexValue :: String -> Int
    hexValue = foldl (\acc c -> acc * 16 + hexDigit c) 0
    hexDigit c
      | isDigit c = fromEnum c - fromEnum '0'
      | c >= 'a' && c <= 'f' = fromEnum c - fromEnum 'a' + 10
      | otherwise = fromEnum c - fromEnum 'A' + 10

    -- _parse_object_unicode
    scanObject start =
      let i = skipSpace start
       in if i <= lastIndex && char i == '}' then Right (i + 1) else member i
      where
        member i
          | i > lastIndex || char i /= '"' = Left ("Expecting property name enclosed in double quotes", i)
          | otherwise = do
              afterKey <- scanString (i + 1)
              let colon = skipSpace afterKey
              if colon > lastIndex || char colon /= ':'
                then Left ("Expecting ':' delimiter", colon)
                else do
                  afterValue <- scanValue (skipSpace (colon + 1))
                  let j = skipSpace afterValue
                  if j <= lastIndex && char j == '}'
                    then Right (j + 1)
                    else
                      if j > lastIndex || char j /= ','
                        then Left ("Expecting ',' delimiter", j)
                        else
                          let k = skipSpace (j + 1)
                           in if k <= lastIndex && char k == '}'
                                then Left ("Illegal trailing comma before end of object", j)
                                else member k

    -- _parse_array_unicode
    scanArray start =
      let i = skipSpace start
       in if i <= lastIndex && char i == ']' then Right (i + 1) else element i
      where
        element i = do
          afterValue <- scanValue i
          let j = skipSpace afterValue
          if j <= lastIndex && char j == ']'
            then Right (j + 1)
            else
              if j > lastIndex || char j /= ','
                then Left ("Expecting ',' delimiter", j)
                else
                  let k = skipSpace (j + 1)
                   in if k <= lastIndex && char k == ']'
                        then Left ("Illegal trailing comma before end of array", j)
                        else element k

tshow :: (Show a) => a -> Text
tshow = T.pack . show
