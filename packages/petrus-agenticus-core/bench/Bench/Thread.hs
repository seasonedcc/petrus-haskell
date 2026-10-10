-- | Thread lifecycle benchmarks, the twins of @bench/python_thread.py@.
--
-- Workload: one Thread with 1 000 sequential Episodes of 4 Turns each.
-- Every Episode runs a harness-owned program that produces a Continuation:
-- start the Episode (claiming the previous revision), then four times start
-- a Turn, accept one append and settle it completed, then settle the
-- Episode completed with a fresh result Continuation.
module Bench.Thread (benchmarks) where

import Data.Foldable (toList)
import Data.Text qualified as T
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Program.Descriptor
import Petrus.Agenticus.Thread.Continuation
import Petrus.Agenticus.Thread.Identity
import Petrus.Agenticus.Thread.Lifecycle
import Petrus.Json (Json)
import Petrus.Json qualified as J
import Test.Tasty.Bench

programId, continuationIdentity, runtimeId :: DescriptorIdentity
programId = descriptorIdentity KindProgram "bench.program" 1
continuationIdentity = descriptorIdentity KindContinuation "bench.context" 1
runtimeId = descriptorIdentity KindRuntime "bench.runtime" 1

program :: AgentProgramDescriptor
program =
  agentProgramDescriptor
    programId
    HarnessOwned
    True
    [continuationRequirement continuationIdentity programId]
    (Just continuationIdentity)
    False
    False

descriptor :: ContinuationDescriptor
descriptor = continuationDescriptor continuationIdentity programId

budget :: EpisodeBudget
budget = episodeBudget 4 4

ok :: Either a b -> b
ok = either (error "benchmark workload must be valid") id

name :: T.Text -> Int -> T.Text
name prefix i = prefix <> T.pack (show i)

-- | Run Episode @i@ to completion.
episode :: Thread -> Int -> Thread
episode t i =
  let started = ok (startEpisode (literalEpisodeId (name "episode-" i)) program runtimeId budget t)
      turn th j =
        let u = literalTurnId (name "turn-" (i * 4 + j))
         in ok (startTurn u th >>= acceptAppend u >>= settleTurn u TurnCompleted)
      ran = foldl turn started [1 .. 4]
      next = ok (newContinuation (literalContinuationId (name "continuation-" i)) ran.id descriptor (name "store:" i))
   in (ok (settleEpisode EpisodeCompleted (Just next) ran)).thread

build :: Int -> Thread
build n = foldl episode (ok (newThread (literalThreadId "bench-thread") Nothing)) [1 .. n]

built :: Thread
built = build 1000

builtData :: Json
builtData = threadToData built

benchmarks :: Benchmark
benchmarks =
  bgroup
    "thread"
    [ bench "build-1000x4" (whnf (forceThread . build) 1000)
    , bench "episode-after-1000" (whnf (\t -> forceThread (episode t 1001)) built)
    , bench "to-json-1000x4" (whnf (either (error . show) id . J.dumps J.defaultDumps . threadToData) built)
    , bench "dumps-only-1000x4" (whnf (either (error . show) id . J.dumps J.defaultDumps) builtData)
    , bench "from-data-1000x4" (whnf (either (error . show) (length . (.episodes)) . threadFromData) builtData)
    ]

-- | Touch every Episode (their fields are strict, so this forces the whole
-- lifecycle value without an NFData instance).
forceThread :: Thread -> Integer
forceThread t = sum [e.acceptedAppends | e <- toList t.episodes]
