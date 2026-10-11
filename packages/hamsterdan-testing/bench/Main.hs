-- | Benchmarks for hamsterdan-testing; bench.py runs the same operations on
-- the same inputs in the pinned Python.
--
-- > cabal bench hamsterdan-testing --benchmark-options='+RTS -M2G -RTS'
--
-- The oracle (test/corpus/oracle.jsonl):
--
-- * @ReadinessModel().evaluate@ over every admitted corpus document;
-- * @ReadinessFacts.load@ then @evaluate@ over the same documents' JSON;
-- * @evaluate_liveness@ under the corpus's six environments and both
--   budget flags, over every expectation.
--
-- The journeys: each of the eleven readiness journeys end to end, from an
-- empty directory to the journey result, through the real V5 host, real
-- SQLite stores and real Git repositories.
--
-- Results and the comparison with Python are in RESULTS.md.
module Main (main) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Testing.Journeys (journeyName, runJourney)
import Hamsterdan.Testing.Readiness
import Petrus.Json (Json (..), compact, dumps, encodeErrorMessage, parseJson, pythonLoads)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (localOption)
import Test.Tasty.Bench

main :: IO ()
main = do
  bytes <- BS.readFile "test/corpus/oracle.jsonl"
  rows <- traverse (either fail pure . parseJson pythonLoads) (filter (not . BS.null) (BS8.split '\n' bytes))
  let inputs = [TE.encodeUtf8 input | Object row <- rows, Just (String input) <- [lookup "input" row], lookup "expectation" row /= Nothing]
  facts <- traverse (either (fail . show) pure . (load :: BS.ByteString -> Either Text ReadinessFacts)) inputs
  let expectations = map evaluate facts
      environments = [FairEnvironment (off /= 0) (off /= 1) (off /= 2) (off /= 3) (off /= 4) | off <- [-1 .. 4 :: Int]]
      count = show (length facts)
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain . map (localOption WallTime) $
    [ bgroup
        "oracle"
        [ bench ("evaluate every admitted corpus document (" <> count <> ")") $ nf (map (summary . evaluate)) facts
        , bench ("load and evaluate every admitted corpus document (" <> count <> ")") $
            nf (map (fmap (summary . evaluate) . (load :: BS.ByteString -> Either Text ReadinessFacts))) inputs
        , bench ("evaluate_liveness x12 over every expectation (" <> count <> ")") $
            nf (\es -> [fromEnum (evaluateLiveness e fairness budget) | e <- es, fairness <- environments, budget <- [False, True]]) expectations
        ]
    , -- One journey from an empty directory to its result document, which
      -- is encoded so that all of it is forced.
      bgroup
        "journeys"
        [ bench (T.unpack (journeyName journey)) . nfIO $
            withSystemTempDirectory "journey" $ \root ->
              either (fail . encodeErrorMessage) (pure . BS.length) . dumps compact =<< runJourney journey root
        | journey <- [minBound .. maxBound]
        ]
    ]
 where
  summary e = (e.subject, e.generation, e.ready, fromEnum e.disposition, e.blockers, e.violations)
