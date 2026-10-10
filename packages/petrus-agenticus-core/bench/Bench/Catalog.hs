-- | Catalog benchmarks, the twins of @bench/python_catalog.py@ (benchmark id
-- @agenticus-catalog@ in docs/runtime.md §13.5).
--
-- Workload: 1 000 enabled descriptors spread over the seven kinds, each
-- offering @cap-0@..@cap-9@; runtimes require five other kinds with all ten
-- capabilities.  A 6-kind request (runtime plus its five requirements) is
-- resolved repeatedly, and the resulting snapshot is encoded and decoded.
module Bench.Catalog (benchmarks) where

import Control.Monad (forM_)
import Data.Text qualified as T
import Petrus.Agenticus.Catalog.Descriptor
import Petrus.Agenticus.Catalog.Resolution
import Petrus.Json qualified as J
import System.IO.Unsafe (unsafePerformIO)
import Test.Tasty.Bench

caps :: [T.Text]
caps = ["cap-" <> T.pack (show j) | j <- [0 .. 9 :: Int]]

workload :: [CapabilityDescriptor]
workload = [make i | i <- [0 .. 999 :: Int]]
  where
    make i =
      let k = allKinds !! (i `mod` 7)
          reqs
            | k == KindRuntime =
                [ either (error . show) id (mkCompatibilityRequirement rk Nothing 1 caps)
                | rk <- [KindConnection, KindHands, KindTerritory, KindContinuation, KindEffect]
                ]
            | otherwise = []
       in capabilityDescriptor (descriptorIdentity k (kindText k <> "-" <> T.pack (show i)) 1) caps reqs

-- | The first runtime and the first descriptor of each required kind.
requestFor :: ResolutionRequest
requestFor =
  either (error . show) id $
    mkResolutionRequest
      [ head' [d.identity | d <- workload, d.identity.kind == k]
      | k <- [KindRuntime, KindConnection, KindHands, KindTerritory, KindContinuation, KindEffect]
      ]
  where
    head' = \case
      x : _ -> x
      [] -> error "empty"

{-# NOINLINE populated #-}
populated :: Catalog
populated = unsafePerformIO $ do
  c <- newCatalog
  forM_ workload $ \d -> register c d >> enable c d.identity
  pure c

resolvedSnapshot :: ResolutionSnapshot
resolvedSnapshot = case unsafePerformIO (resolve populated requestFor) of
  r | Just s <- r.snapshot -> s
  _ -> error "workload must resolve"

snapshotBytes :: J.Json
snapshotBytes = snapshotToData resolvedSnapshot

benchmarks :: Benchmark
benchmarks =
  bgroup
    "catalog"
    [ bench "resolve-6-kinds" (nfIO (length . (.results) <$> resolve populated requestFor))
    , bench "snapshot-to-json" (nf (either (error . show) id . J.dumps J.defaultDumps . snapshotToData) resolvedSnapshot)
    , bench "snapshot-from-data" (nf (either (error . show) (length . (.descriptors)) . snapshotFromData) snapshotBytes)
    , bench "register+enable-1000" (nfIO (newCatalog >>= \c -> mapM_ (\d -> register c d >> enable c d.identity) workload >> catalogRevisionIO c))
    ]
