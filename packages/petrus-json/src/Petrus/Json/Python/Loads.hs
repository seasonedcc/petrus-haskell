-- | @json.loads@ with CPython's defaults, as a value or the exception it
-- raises.
--
-- A @str@ in the common subset is read in place ("Petrus.Json.Parse.InPlace");
-- any other document is admitted by "Petrus.Json"'s parser. Only a refusal
-- goes through "Petrus.Json.Python.Scanner", CPython's scanner, which words
-- the exception exactly as the reference does, or admits a text holding a
-- raw lone surrogate (which the byte parser refuses as invalid UTF-8). A lone surrogate, escaped
-- (@"\\ud800"@) or decoded from the bytes (@surrogatepass@), is kept as
-- WTF-8 ("Petrus.Json.Wtf8"), as CPython keeps it in a @str@.
module Petrus.Json.Python.Loads
  ( loadsText
  , loadsUtf8
  , loadsBytes
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json.Parse (parseJson, pythonJsonLoads)
import Petrus.Json.Parse.InPlace (parseInPlace)
import Petrus.Json.Python.Decode (jsonBytesFailure)
import Petrus.Json.Python.Exception (PythonException, pythonError, unicodeDecodeError)
import Petrus.Json.Python.Scanner qualified as Scanner
import Petrus.Json.Value (Json)
import Petrus.Json.Wtf8 (hasLoneSurrogate)

-- | @json.loads(s)@ for a @str@: the value, or the @JSONDecodeError@ or
-- @int()@'s digit-limit @ValueError@ it raises. A document nested past
-- 'Petrus.Json.Limits.defaultNestingLimit' raises @RecursionError@ with
-- petrus-json's text (CPython's depends on its C stack; see
-- DIVERGENCES.md).
loadsText :: Text -> Either PythonException Json
loadsText text
  | "\xFEFF" `T.isPrefixOf` text = Left unexpectedBom
  | otherwise = decodeText text

-- | 'loadsText' for a @str@ given as its UTF-8 encoding, parsed in place:
-- valid UTF-8 holds no raw lone surrogate, so only a refusal is decoded
-- (leniently, should the bytes not be UTF-8) for the scanner.
loadsUtf8 :: ByteString -> Either PythonException Json
loadsUtf8 bytes
  | "\xEF\xBB\xBF" `BS.isPrefixOf` bytes = Left unexpectedBom
  | otherwise = case parseJson pythonJsonLoads bytes of
      Right value -> Right value
      Left _ -> decodeText (TE.decodeUtf8Lenient bytes)

unexpectedBom :: PythonException
unexpectedBom = pythonError "JSONDecodeError" "Unexpected UTF-8 BOM (decode using utf-8-sig): line 1 column 1 (char 0)"

-- | @json.loads@ past its @str@ checks: 'Scanner.decode'.
decodeText :: Text -> Either PythonException Json
decodeText text = case parseInPlace text of
  Just value -> Right value
  Nothing -> case parseJson pythonJsonLoads (TE.encodeUtf8 text) of
    Right value -> Right value
    Left problem -> case Scanner.decode Scanner.defaultHooks text of
      Left (Scanner.DecodeError message position) -> Left (pythonError "JSONDecodeError" (Scanner.decodeErrorText text message position))
      Left (Scanner.HookError message) -> Left (pythonError "ValueError" message)
      Right raw
        | hasLoneSurrogate text -> Right (Scanner.rawJson raw)
        | otherwise -> Left (pythonError "RecursionError" (T.pack problem))

-- | @json.loads(b)@ for @bytes@: decoded as 'jsonBytesFailure' decodes them
-- (@json.detect_encoding@, @surrogatepass@), or their @UnicodeDecodeError@,
-- then scanned (a U+FEFF the codec left is an unexpected character here,
-- not the @str@ refusal 'loadsText' gives). (After @surrogatepass@ has passed a surrogate, CPython's
-- error keeps that first error's @args@ while its attributes, and so its
-- @str()@, name the failure; this one's @args@ are the failure's. See
-- DIVERGENCES.md.)
loadsBytes :: ByteString -> Either PythonException Json
loadsBytes raw = either (Left . uncurry unicodeDecodeError) decodeText (jsonBytesFailure raw)
