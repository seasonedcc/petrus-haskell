{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Separable deterministic choice streams (@ChoiceStreams@, algorithm
-- @sha256-counter-v1@).
--
-- Every authority draws from its own counter-addressed SHA-256 stream, so
-- drawing more from one authority never perturbs another. The streams are a
-- pure value here: each draw returns the chosen value and the advanced
-- streams.
module Petrus.Testing.Dst.Choice
  ( ChoiceStreams
  , IndexAuthority (..)
  , indexAuthorityText
  , ChoiceError (..)
  , choiceAlgorithm
  , choiceStreams
  , streamsSeed
  , streamsDraws
  , chooseIndex
  , chooseIdentifier
  , provenance
  , validProvenanceDraws
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits (shiftL, (.|.))
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Testing.Dst.Types (ChoiceProvenance (..), isName, maxPortableInteger)

-- | The authorities that draw indices. The reference's
-- @ChoiceAuthority.IDENTIFIER@ only draws identifiers, so it is not an index
-- authority here.
data IndexAuthority = WorkloadChoice | FaultChoice | EventOrderChoice
  deriving stock (Eq, Ord, Show, Enum, Bounded)

indexAuthorityText :: IndexAuthority -> Text
indexAuthorityText = \case
  WorkloadChoice -> "workload"
  FaultChoice -> "fault"
  EventOrderChoice -> "event_order"

-- | Deterministic choice streams for one seed.
data ChoiceStreams = ChoiceStreams
  { seed :: Integer
  , draws :: Map Text Integer
  }
  deriving stock (Eq, Show)

-- | A refused choice request; the message is the reference's.
data ChoiceError = ChoiceError
  { errorType :: Text
  , message :: Text
  }
  deriving stock (Eq, Show)

choiceAlgorithm :: Text
choiceAlgorithm = "sha256-counter-v1"

-- | @ChoiceStreams(seed)@.
choiceStreams :: Integer -> Either ChoiceError ChoiceStreams
choiceStreams seed
  | seed < 0 || seed > maxPortableInteger =
      Left (ChoiceError "ValueError" "DST choice seed must be an integer from 0 through 2^53 - 1")
  | otherwise = Right (ChoiceStreams seed Map.empty)

streamsSeed :: ChoiceStreams -> Integer
streamsSeed s = s.seed

streamsDraws :: ChoiceStreams -> Map Text Integer
streamsDraws s = s.draws

-- | Choose one unbiased index in @[0, stop)@ without perturbing another
-- authority.
chooseIndex :: IndexAuthority -> Integer -> ChoiceStreams -> Either ChoiceError (Integer, ChoiceStreams)
chooseIndex authority stop streams
  | stop < 1 || stop > maxPortableInteger =
      Left (ChoiceError "ValueError" "DST choice stop must be an integer from 1 through 2^53 - 1")
  | otherwise = probe 0
  where
    key = indexAuthorityText authority
    ordinal = Map.findWithDefault 0 key streams.draws
    space = 1 `shiftL` 256 :: Integer
    ceiling' = space - (space `mod` stop)
    probe :: Integer -> Either ChoiceError (Integer, ChoiceStreams)
    probe n
      | n >= 16 = Left (ChoiceError "RuntimeError" "DST choice rejection sampling exceeded 16 deterministic probes")
      | otherwise =
          let value = bigEndian (streamDigest streams.seed key ordinal n)
           in if value < ceiling'
                then Right (value `mod` stop, ChoiceStreams streams.seed (Map.insert key (ordinal + 1) streams.draws))
                else probe (n + 1)

-- | Generate one seeded stable identifier on a namespace-isolated stream:
-- @namespace-<32 hex>@.
chooseIdentifier :: Text -> ChoiceStreams -> Either ChoiceError (Text, ChoiceStreams)
chooseIdentifier namespace streams
  | not (isName namespace) =
      Left (ChoiceError "ValueError" "choice identifier namespace must be a normalized non-empty name")
  | otherwise =
      let key = "identifier:" <> namespace
          ordinal = Map.findWithDefault 0 key streams.draws
          digest = streamDigest streams.seed key ordinal 0
       in Right
            ( namespace <> "-" <> T.take 32 (TE.decodeLatin1 (B16.encode digest))
            , ChoiceStreams streams.seed (Map.insert key (ordinal + 1) streams.draws)
            )

-- | Seed metadata for discovery.
provenance :: ChoiceStreams -> ChoiceProvenance
provenance s = ChoiceProvenance {seed = s.seed, draws = s.draws}

-- | @ChoiceProvenance.valid_draws@ over draws in document order: 'Nothing' when every draw name names an
-- index authority or an identifier namespace and every count is a positive
-- portable integer; otherwise the reference's message.
validProvenanceDraws :: [(Text, Integer)] -> Maybe Text
validProvenanceDraws = go
  where
    go [] = Nothing
    go ((name, count) : rest)
      | name `notElem` map indexAuthorityText [minBound .. maxBound]
      , not (identifierName name) =
          Just "choice draw names must identify one authority or identifier namespace"
      | count < 1 || count > maxPortableInteger =
          Just "choice draw counts must be positive JSON-portable integers"
      | otherwise = go rest
    identifierName name = case T.stripPrefix "identifier:" name of
      Just namespace -> isName namespace
      Nothing -> False

streamDigest :: Integer -> Text -> Integer -> Integer -> ByteString
streamDigest seed key ordinal probeIndex =
  BA.convert (hash payload :: Digest SHA256)
  where
    -- @json.dumps([algorithm, seed, key, ordinal, probe], separators=(",", ":"))@;
    -- keys are normalized ASCII names, so no escaping is needed.
    payload =
      TE.encodeUtf8
        ( "[\"" <> choiceAlgorithm <> "\"," <> tshow seed <> ",\"" <> key <> "\"," <> tshow ordinal <> "," <> tshow probeIndex <> "]"
        )
    tshow = T.pack . show

bigEndian :: ByteString -> Integer
bigEndian = BS.foldl' (\acc w -> acc `shiftL` 8 .|. fromIntegral w) 0
