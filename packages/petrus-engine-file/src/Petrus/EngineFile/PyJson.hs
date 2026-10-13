-- | The parser behind the formatter and in-memory sources: CPython 3.14's
-- @json.loads@ on a @str@.
--
-- Documents are admitted by petrus-json's parser with @json.loads@'s
-- options, and a refused document is re-scanned by
-- "Petrus.Json.Python.Scanner" for CPython's @JSONDecodeError@ message and
-- position (in code points), or the @ValueError@ of an integer past
-- @int()@'s 4300-digit limit. The objects built are CPython's: a repeated
-- key keeps its first position and takes its last value, integers are
-- unbounded, and @NaN@, @Infinity@ and @-Infinity@ are floats. An unpaired
-- @\\uD800@-style escape gives a string holding the lone surrogate, as
-- CPython's @str@ does: a WTF-8 'Text' ("Petrus.Json.Wtf8"), which the
-- encoder writes back as the same escape.
module Petrus.EngineFile.PyJson
  ( PyJsonError (..)
  , pyLoads
  , renderPyJsonError
  , pyJsonErrorClass
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Petrus.EngineFile.Value (Value (..))
import Petrus.Json (Json (..), ParseOptions (..), pythonJsonLoads)
import Petrus.Json.Python (LoadsRefusal (..), parseOrExplain)
import Petrus.Json.Python.Scanner qualified as Scanner

-- | Why @json.loads@ refused a document.
data PyJsonError
  = -- | @JSONDecodeError(msg, doc, pos)@ with @pos@ a code point offset,
    -- already rendered as @"msg: line L column C (char P)"@.
    DecodeError Text
  | -- | @ValueError@ from @int()@ on an integer of too many digits, with
    -- CPython's text.
    IntegerTooLong Text
  deriving stock (Eq, Show)

-- | The exception class the reference raises.
pyJsonErrorClass :: PyJsonError -> Text
pyJsonErrorClass = \case
  DecodeError _ -> "JSONDecodeError"
  IntegerTooLong _ -> "ValueError"

-- | @str(exception)@.
renderPyJsonError :: PyJsonError -> Text
renderPyJsonError = \case
  DecodeError text -> text
  IntegerTooLong text -> text

-- | @json.loads(text)@ for UTF-8 encoded text. The nesting is unbounded,
-- as the reference's is short of the C stack (DIVERGENCES.md, 1).
pyLoads :: ByteString -> Either PyJsonError Value
pyLoads input = case parseOrExplain options (Scanner.loads Scanner.defaultHooks) input (TE.decodeUtf8Lenient input) of
  Right json -> Right (fromJson json)
  Left (LoadsDecodeError text) -> Left (DecodeError text)
  Left (LoadsHookError message) -> Left (IntegerTooLong message)
  Left (LoadsBeyondLimits problem) -> Left (DecodeError problem)
  where
    options = pythonJsonLoads {maxNestingDepth = Nothing}

fromJson :: Json -> Value
fromJson = \case
  Null -> VNull
  Bool b -> VBool b
  Int i -> VInt i False
  Float d -> VFloat d
  String s -> VStr s
  Array items -> VList (map fromJson items)
  Object members -> VDict [(k, fromJson v) | (k, v) <- members]
