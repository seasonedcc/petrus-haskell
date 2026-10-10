-- | Canonical artifact bytes, digests, and the strict artifact decoder.
--
-- 'encodeArtifact' produces exactly the reference's
-- @json.dumps(artifact.model_dump(mode="json"), allow_nan=False,
-- separators=(",", ":"), sort_keys=True).encode()@, and 'decodeArtifact'
-- admits exactly what @decode_artifact@ admits.
module Petrus.Testing.Dst.Codec
  ( -- * Canonical JSON
    canonicalOptions
  , canonicalBytes
  , digestJson
  , journalDigest

    -- * Artifacts
  , encodeArtifact
  , decodeArtifact
  , loadArtifact
  , artifactFromJson
  , DecodeError (..)
  , decodeErrorMessage

    -- * Replay results
  , encodeReplayResult

    -- * Strict JSON
  , loadStrictJson
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (EncodeError (..), EncodeOptions (..), Json (..), compact, dumps, lookupMember)
import Petrus.Testing.Dst.Decode
import Petrus.Testing.Dst.Internal.StrictJson (loadStrictJson)
import Petrus.Testing.Dst.PyRepr (jsonToPy, pyRepr)
import Petrus.Testing.Dst.Types

-- | @separators=(",", ":"), sort_keys=True, allow_nan=False@ with the
-- default @ensure_ascii=True@.
canonicalOptions :: EncodeOptions
canonicalOptions = compact {sortKeys = True, ensureAscii = True}

-- | Canonical bytes of strict JSON data; refuses non-finite numbers with
-- CPython's message.
canonicalBytes :: Json -> Either Text ByteString
canonicalBytes value = case dumps canonicalOptions value of
  Right bytes -> Right bytes
  Left (NonFiniteNumber d) -> Left ("Out of range float values are not JSON compliant: " <> floatName d)
  where
    floatName d
      | isNaN d = "nan"
      | d > 0 = "inf"
      | otherwise = "-inf"

-- | @digest_json@: @sha256:@ and the hex SHA-256 of the canonical bytes.
digestJson :: Json -> Either Text Text
digestJson value = do
  bytes <- canonicalBytes value
  Right ("sha256:" <> T.pack (show (hash bytes :: Digest SHA256)))

-- | @_journal_digest@ over journal entries.
journalDigest :: [JournalEntry] -> Text
journalDigest entries = case digestJson (Array (map toJson entries)) of
  Right digest -> digest
  -- Journal entries hold only validated finite JSON.
  Left message -> "invalid:" <> message

-- | @encode_artifact@: canonical bytes, refused when larger than the
-- artifact's own byte budget.
encodeArtifact :: AnyArtifact -> Either Text ByteString
encodeArtifact artifact = do
  bytes <- canonicalBytes (toJson artifact)
  let limit = budgetArtifactBytes (artifactBudget artifact)
  if toInteger (BS.length bytes) > limit
    then Left ("DST artifact has " <> tshow (BS.length bytes) <> " bytes; limit is " <> tshow limit)
    else Right bytes

-- | Canonical bytes of a replay result.
encodeReplayResult :: AnyReplayResult -> ByteString
encodeReplayResult result = case canonicalBytes (toJson result) of
  Right bytes -> bytes
  Left _ -> BS.empty

-- | A refused artifact.
data DecodeError
  = -- | A @ValueError@ raised by @decode_artifact@ itself (size, JSON,
    -- version); the text is the reference's exact @str(error)@.
    DecodeRefused Text
  | -- | A pydantic @ValidationError@ for the named model.
    DecodeInvalid Text SchemaError
  deriving stock (Eq, Show)

decodeErrorMessage :: DecodeError -> Text
decodeErrorMessage = \case
  DecodeRefused message -> message
  DecodeInvalid modelName e -> renderSchemaError modelName e

-- | @decode_artifact@.
decodeArtifact :: ByteString -> Either DecodeError AnyArtifact
decodeArtifact payload
  | BS.length payload > fromInteger maxArtifactBytes =
      Left (DecodeRefused ("DST artifact exceeds the format ceiling of " <> tshow maxArtifactBytes <> " bytes"))
  | otherwise = do
      value <- either (Left . DecodeRefused . ("invalid strict DST JSON: " <>)) Right (loadStrictJson payload)
      artifact <- artifactFromJson value
      let limit = budgetArtifactBytes (artifactBudget artifact)
      if toInteger (BS.length payload) > limit
        then Left (DecodeRefused ("DST artifact has " <> tshow (BS.length payload) <> " bytes; limit is " <> tshow limit))
        else Right artifact

-- | @load_artifact@.
loadArtifact :: FilePath -> IO (Either DecodeError AnyArtifact)
loadArtifact path = decodeArtifact <$> BS.readFile path

-- | Version dispatch and model validation of a loaded JSON value.
artifactFromJson :: Json -> Either DecodeError AnyArtifact
artifactFromJson value = case value of
  Object _ -> case lookupMember "version" value of
    Just v
      | v == Int 1 -> validated "ScenarioArtifactV1" (ArtifactV1 <$> pArtifactV1 value)
      | v == Int 2 -> validated "ScenarioArtifactV2" (ArtifactV2 <$> pArtifactV2 value)
      | v == Int 3 -> validated "ScenarioArtifactV3" (ArtifactV3 <$> pArtifactV3 value)
      | v == Int 4 -> validated "ScenarioArtifact" (ArtifactV4 <$> pArtifactV4 value)
    other -> Left (DecodeRefused ("unsupported DST artifact version " <> maybe "None" (pyRepr . jsonToPy) other))
  _ -> Left (DecodeRefused "invalid strict DST JSON: artifact must be an object")
  where
    validated modelName = either (Left . DecodeInvalid modelName) Right

tshow :: (Show a) => a -> Text
tshow = T.pack . show
