-- | Effect benchmarks, the twins of @bench/python_effect.py@ (benchmark id
-- @agenticus-effect@ in docs/runtime.md §13.5).
--
-- Workload: @digest_payload@ over nested payloads of about 1 KB, 100 KB and
-- 1 MB of canonical JSON (records with Unicode and escaped strings,
-- integers, bools, nulls, nested objects and lists), from decoded 'Json' as
-- the reference receives a dict; and 'executeJson' with an in-memory
-- adapter on the first-execution and replay paths.  The payload digests are
-- checked against the reference's before anything is timed.
module Bench.Effect (benchmarks) where

import Control.DeepSeq (NFData (..))
import Data.ByteString qualified as B
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Effect.Gateway
import Petrus.Agenticus.Effect.Model
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Test.Tasty.Bench

record :: Int -> Json
record i =
  Object
    [ ("id", Int (toInteger i))
    , ("name", String ("registro-é-😀-" <> tshow i))
    , ("note", String "texto \"citado\"\n\tcom barra \\ e controle \x01")
    , ("tags", Array [String "α", String "β", String "γ", String (tshow (i `mod` 7))])
    , ("flags", Object [("active", Bool (even i)), ("deleted", Null), ("score", Int (toInteger i * 7919))])
    , ("nested", Object [("z", Array [Int (toInteger i), Int (negate (toInteger i)), Int (2 ^ (64 :: Int) + toInteger i)]), ("a", Object [("中文", String "値"), ("k", Bool (i `mod` 3 == 0))])])
    ]
  where
    tshow = T.pack . show

-- | Records until the canonical size reaches the target, as the reference
-- builds them.
payload :: Int -> Json
payload target = go 0 0 []
  where
    go i size acc
      | size >= target = Object [("records", Array (reverse acc)), ("meta", Object [("count", Int (toInteger i)), ("schema", String "bench-v1")])]
      | otherwise =
          let item = record i
           in go (i + 1) (size + canonicalSize item + 1) (item : acc)
    canonicalSize item = B.length (right (J.dumps J.compact {J.sortKeys = True} item))

-- | Reference digests printed by @bench/python_effect.py@.
references :: [(Text, Int, Text)]
references =
  [ ("1KB", 1_000, "sha256:3b5c9f511c189f278da3575b674451e7fd04d65fc04581eb160c5f7024ee0a43")
  , ("100KB", 100_000, "sha256:f363464cad75e7c343b6955f2f4797d5e025a8c63bfea19eacdc616808c39caf")
  , ("1MB", 1_000_000, "sha256:2ff8d81e69d827a1e1d10c159bc7b93e5bd33ee4842d2da48f0e8cb2fef2d4df")
  ]

checked :: Text -> Int -> Text -> Json
checked name size expected =
  let value = payload size
   in case digestPayloadJson value of
        Right digest | digest == expected -> value
        other -> error ("payload " <> T.unpack name <> " digest differs from the reference: " <> show other)

-- | Environments forced through their canonical bytes (petrus-json has no
-- 'NFData' instance).
newtype Forced = Forced Json

instance NFData Forced where
  rnf (Forced value) = rnf (right (J.dumps J.compact value))

newtype Strict = Strict EffectPayload

instance NFData Strict where
  rnf (Strict value) = rnf (canonicalPayload value)

right :: (Show e) => Either e a -> a
right = either (error . show) id

message :: Json
message = Object [("message", String "ready")]

theProposal :: EffectProposal
theProposal =
  right $
    mkEffectProposal "proposal-7" "bulletin.publish" 1 (right (digestPayloadJson message)) (right (mkTargetIdentity "bulletin" "release-notes")) "bulletin.publish"

theFence :: EffectFence
theFence = right (mkEffectFence theProposal.proposalId theProposal.digest 4 "revision-11" "episode-3" "attachment-8" 2)

theReceipt :: EffectReceipt
theReceipt =
  right $
    mkEffectReceipt
      theProposal.proposalId
      theProposal.digest
      theProposal.payloadDigest
      theProposal.target
      (right (digestPayloadJson (Object [("provider_record", String "record-1")])))

approval :: EffectDecision
approval = right (approve theProposal theFence)

executing, replaying :: EffectGateway
executing = effectGateway (EffectAdapter (\_ -> pure LookupSafeToRetry) (\_ _ _ -> pure theReceipt)) (EffectFenceSource (\_ -> pure theFence))
replaying =
  effectGateway
    (EffectAdapter (\_ -> pure (LookupApplied theReceipt)) (\_ _ _ -> error "replay must not execute"))
    (EffectFenceSource (\_ -> pure theFence))

benchmarks :: Benchmark
benchmarks =
  bgroup "effect" $
    [ env (pure (Forced (checked name size expected))) $ \(Forced value) ->
        bench ("digest-" <> T.unpack name) (nf (right . digestPayloadJson) value)
    | (name, size, expected) <- references
    ]
      <> [ env (pure (Strict (right (payloadFromJson (checked "1MB" 1_000_000 (thd references)))))) $ \(Strict strict) ->
             bench "digest-1MB-strict-payload" (nf digestPayload strict)
         , bench "gateway-execute" (whnfIO (executeJson executing theProposal message approval))
         , bench "gateway-replay" (whnfIO (executeJson replaying theProposal message approval))
         ]
  where
    thd = \case
      [_, _, (_, _, d)] -> d
      _ -> error "references"
