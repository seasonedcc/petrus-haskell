-- | The reference's strict JSON loader for DST payloads.
--
-- The reference loads artifacts, run specs, and progress frames with
-- @json.loads(payload, object_pairs_hook=_strict_object,
-- parse_constant=_refuse_constant)@. This module reproduces that admission
-- and, on refusal, the exact CPython error text, from petrus-json's
-- CPython-compatibility layer:
--
-- * the payload is decoded the way @json.loads(bytes)@ decodes it
--   ('decodeJsonBytes': @json.detect_encoding@, then UTF-8, UTF-8 with
--   signature, UTF-16, or UTF-32 with @surrogatepass@), so a UTF-16
--   artifact is admitted exactly as the reference admits it and an
--   undecodable payload reports CPython's codec message;
-- * duplicate members, @NaN@/@Infinity@ constants, integer tokens beyond
--   CPython's 4300-digit conversion limit, and every syntax error are
--   reported with CPython's message and character position, in the order
--   CPython's scanner meets them ("Petrus.Json.Python.Scanner" with
--   'Scanner.strictHooks').
--
-- Admission uses the @petrus-json@ parser; only refusals take the slower
-- scanner.
--
-- One documented divergence remains: CPython admits lone UTF-16 surrogates
-- (from @\\ud800@ escapes or @surrogatepass@ decoding); the DST models hold
-- 'Data.Text.Text', so a payload CPython would admit with one is refused
-- here ('loneSurrogate').
module Petrus.Testing.Dst.Internal.StrictJson
  ( loadStrictJson
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (DuplicateMembers (..), Json, ParseOptions (..), parseJson, surrogateRefusingLoads)
import Petrus.Json.Python (decodeJsonBytes)
import Petrus.Json.Python.Scanner qualified as Scanner

-- | Load one strict DST JSON document. A refusal carries the text of the
-- Python exception the reference wraps (without its
-- @invalid strict DST …:@ prefix).
loadStrictJson :: ByteString -> Either Text Json
loadStrictJson payload = do
  text <- decodeJsonBytes payload
  case parseJson options (TE.encodeUtf8 text) of
    Right value -> Right value
    Left problem -> Left $ case Scanner.loads Scanner.strictHooks text of
      Left (Scanner.DecodeError message position) -> Scanner.decodeErrorText text message position
      Left (Scanner.HookError message) -> message
      Right raw
        | holdsSurrogate raw -> loneSurrogate
        -- petrus-json's nesting guard refuses what CPython's scanner admits.
        | otherwise -> T.pack problem

options :: ParseOptions
options =
  surrogateRefusingLoads
    { duplicateMembers = RejectDuplicates
    , allowNonFiniteConstants = False
    }

-- | The refusal of a payload CPython admits with a lone surrogate.
loneSurrogate :: Text
loneSurrogate = "the payload contains a lone UTF-16 surrogate, which this port cannot represent"

holdsSurrogate :: Scanner.Raw -> Bool
holdsSurrogate = \case
  Scanner.RStr s -> any Scanner.isSurrogate s
  Scanner.RList items -> any holdsSurrogate items
  Scanner.RDict members -> any (\(k, v) -> any Scanner.isSurrogate k || holdsSurrogate v) members
  _ -> False
