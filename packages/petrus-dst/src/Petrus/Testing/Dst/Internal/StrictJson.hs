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

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Json (DuplicateMembers (..), Json (..), ParseOptions (..), parseJson, pythonJsonLoads)
import Petrus.Json.Python (decodeJsonBytes)
import Petrus.Json.Python.Scanner qualified as Scanner
import Petrus.Json.Wtf8 (hasLoneSurrogate)

-- | Load one strict DST JSON document. A refusal carries the text of the
-- Python exception the reference wraps (without its
-- @invalid strict DST …:@ prefix).
loadStrictJson :: ByteString -> Either Text Json
loadStrictJson payload = do
  text <- decodeJsonBytes payload
  value <- case parseJson options (TE.encodeUtf8 text) of
    Right value -> Right value
    Left problem -> case Scanner.loads Scanner.strictHooks text of
      Left (Scanner.DecodeError message position) -> Left (Scanner.decodeErrorText text message position)
      Left (Scanner.HookError message) -> Left message
      Right raw
        -- petrus-json reads a surrogate from an escape only; one that the
        -- payload's own bytes spelled (@surrogatepass@) comes from the
        -- scanner, once petrus-json's limits admit the same document with
        -- U+FFFD (as long in UTF-8) in its place.
        | hasLoneSurrogate text ->
            Scanner.rawJson raw <$ first T.pack (parseJson options (TE.encodeUtf8 (T.map unpaired text)))
        -- petrus-json's nesting guard refuses what CPython's scanner admits.
        | otherwise -> Left (T.pack problem)
  if surrogateKey value then Left loneSurrogateKey else Right value
  where
    unpaired c = if Scanner.isSurrogate c then '\xFFFD' else c

options :: ParseOptions
options =
  pythonJsonLoads
    { duplicateMembers = RejectDuplicates
    , allowNonFiniteConstants = False
    }

-- | The refusal of a payload CPython admits with a lone surrogate in an
-- object key.
loneSurrogateKey :: Text
loneSurrogateKey = "the payload contains a lone UTF-16 surrogate in an object key, which this port cannot represent"

surrogateKey :: Json -> Bool
surrogateKey = \case
  Array items -> any surrogateKey items
  Object members -> any (\(k, v) -> hasLoneSurrogate k || surrogateKey v) members
  _ -> False
