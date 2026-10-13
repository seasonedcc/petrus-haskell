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
-- A lone UTF-16 surrogate in a string value is admitted, as CPython admits
-- it (from a @\\ud800@ escape or @surrogatepass@ decoding), and kept as
-- WTF-8 ("Petrus.Json.Wtf8"), which the validators and the canonical
-- encoder carry back byte for byte. One documented divergence remains: a
-- lone surrogate in an object /key/ is refused ('loneSurrogateKey'), since
-- the reference's @model_dump@ rewrites such keys (see DIVERGENCES.md).
module Petrus.Testing.Dst.Internal.StrictJson
  ( loadStrictJson
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Petrus.Json (DuplicateMembers (..), Json (..), ParseOptions (..), pythonJsonLoads)
import Petrus.Json.Python (LoadsRefusal (..), decodeJsonBytes, parseOrExplain)
import Petrus.Json.Python.Scanner qualified as Scanner
import Petrus.Json.Wtf8 (hasLoneSurrogate)

-- | Load one strict DST JSON document. A refusal carries the text of the
-- Python exception the reference wraps (without its
-- @invalid strict DST …:@ prefix).
loadStrictJson :: ByteString -> Either Text Json
loadStrictJson payload = do
  text <- decodeJsonBytes payload
  value <- case parseOrExplain options (Scanner.decode Scanner.strictHooks) (TE.encodeUtf8 text) text of
    Right value -> Right value
    Left (LoadsDecodeError message) -> Left message
    Left (LoadsHookError message) -> Left message
    -- petrus-json's nesting guard refuses what CPython's scanner admits.
    Left (LoadsBeyondLimits problem) -> Left problem
  if surrogateKey value then Left loneSurrogateKey else Right value

options :: ParseOptions
options =
  pythonJsonLoads
    { duplicateMembers = RejectDuplicates
    , allowNonFiniteConstants = False
    }

-- | The refusal of a payload CPython admits with a lone surrogate in an
-- object key.
loneSurrogateKey :: Text
loneSurrogateKey = "the payload contains a lone UTF-16 surrogate in an object key, which the reference's pydantic re-encoding rewrites"

surrogateKey :: Json -> Bool
surrogateKey = \case
  Array items -> any surrogateKey items
  Object members -> any (\(k, v) -> hasLoneSurrogate k || surrogateKey v) members
  _ -> False
