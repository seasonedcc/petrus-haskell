-- | The parser behind the formatter and in-memory sources: CPython 3.14's
-- @json.loads@ on a @str@.
--
-- Documents are admitted by petrus-json's parser with @json.loads@'s
-- options, and a refused document is re-scanned by
-- "Petrus.Json.Python.Scanner" for CPython's @JSONDecodeError@ message and
-- position (in code points), or the @ValueError@ of an integer past
-- @int()@'s 4300-digit limit. The objects built are CPython's: a repeated
-- key keeps its first position and takes its last value, integers are
-- unbounded, and @NaN@, @Infinity@ and @-Infinity@ are floats.
--
-- One divergence (see DIVERGENCES.md): CPython builds a @str@ holding a
-- lone surrogate from an unpaired @\\uD800@-style escape, which this
-- package's values do not carry; a document whose objects hold one is
-- refused with 'LoneSurrogate' once it has otherwise parsed.
module Petrus.EngineFile.PyJson
  ( PyJsonError (..)
  , pyLoads
  , renderPyJsonError
  , pyJsonErrorClass
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.EngineFile.Value (Value (..))
import Petrus.Json (Json (..), LoneSurrogates (..), ParseOptions (..), parseJson, pythonLoads)
import Petrus.Json.Python.Scanner qualified as Scanner
import Petrus.Json.Wtf8 (holdsLoneSurrogate)

-- | Why @json.loads@ refused a document.
data PyJsonError
  = -- | @JSONDecodeError(msg, doc, pos)@ with @pos@ a code point offset,
    -- already rendered as @"msg: line L column C (char P)"@.
    DecodeError Text
  | -- | @ValueError@ from @int()@ on an integer of too many digits, with
    -- CPython's text.
    IntegerTooLong Text
  | -- | A lone surrogate in a string (a divergence; see the module notes).
    LoneSurrogate
  deriving stock (Eq, Show)

-- | The exception class the reference raises.
pyJsonErrorClass :: PyJsonError -> Text
pyJsonErrorClass = \case
  DecodeError _ -> "JSONDecodeError"
  IntegerTooLong _ -> "ValueError"
  LoneSurrogate -> "UnsupportedLoneSurrogate"

-- | @str(exception)@.
renderPyJsonError :: PyJsonError -> Text
renderPyJsonError = \case
  DecodeError text -> text
  IntegerTooLong text -> text
  LoneSurrogate -> "a string holds a lone surrogate, which this implementation cannot represent"

-- | @json.loads(text)@ for UTF-8 encoded text. The nesting is unbounded,
-- as the reference's is short of the C stack (DIVERGENCES.md, 2).
pyLoads :: ByteString -> Either PyJsonError Value
pyLoads input = case parseJson options input of
  Right json
    | holdsLoneSurrogate json -> Left LoneSurrogate
    | otherwise -> Right (fromJson json)
  Left problem -> Left $ case Scanner.loads Scanner.defaultHooks text of
    Left (Scanner.DecodeError message position) -> DecodeError (Scanner.decodeErrorText text message position)
    Left (Scanner.HookError message) -> IntegerTooLong message
    Right _ -> DecodeError (T.pack problem)
  where
    options = pythonLoads {maxNestingDepth = Nothing, loneSurrogates = KeepLoneSurrogates}
    text = TE.decodeUtf8Lenient input

fromJson :: Json -> Value
fromJson = \case
  Null -> VNull
  Bool b -> VBool b
  Int i -> VInt i False
  Float d -> VFloat d
  String s -> VStr s
  Array items -> VList (map fromJson items)
  Object members -> VDict [(k, fromJson v) | (k, v) <- members]
