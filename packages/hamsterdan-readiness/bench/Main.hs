-- | Hot-path benchmarks for hamsterdan-readiness; bench.py runs the same
-- operations on the same inputs (the test corpora) in the pinned Python.
--
-- > cabal bench hamsterdan-readiness --benchmark-options='+RTS -M2G -RTS'
--
-- * folding: every recorded fold binding of test/corpus/folds.jsonl fed to
--   the handler wired for its transition (one pass, all loops), and the
--   same per loop;
-- * board rendering: @render_board@ and @gate_facts@ over every entry log
--   of test/corpus/board.jsonl (one pass).
--
-- Results and the comparison with Python are in RESULTS.md.
module Main (main) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Readiness.NetV5.Board (gateFactsValue, renderBoard)
import Hamsterdan.Readiness.NetV5.Topology (buildNetV5)
import Petrus.Impetus.Binding (BoundHandler (..), HandlerResult)
import Petrus.Impetus.Dsl (BuiltNet (..))
import Petrus.Impetus.Petrinet (Binding (..), NetPath, Token (..))
import Petrus.Impetus.Petrinet.Schema (Arc, handlerUri, netPath, outputs)
import Petrus.Json (Json (..), parseJson, pythonLoads)
import Test.Tasty (localOption)
import Test.Tasty.Bench

-- | One fold call: the handler, its binding, and its output arcs.
data Call = Call Text (Binding -> [Arc] -> Either Text HandlerResult) Binding [Arc]

main :: IO ()
main = do
  built <- either (const (fail "buildNetV5 failed")) pure buildNetV5
  folds <- corpus "test/corpus/folds.jsonl"
  boards <- corpus "test/corpus/board.jsonl"
  calls <- traverse (callOf built) [row | row <- folds, member "call" row == Just (String "fold")]
  let logs = [[e | String e <- items] | row <- boards, Just (Array items) <- [member "entries" row]]
      loops = nub [loop | Call loop _ _ _ <- calls]
      run selected = [f binding arcs | Call _ f binding arcs <- selected]
  -- Wall-clock time for every benchmark, as the Python twins measure it
  -- (time.perf_counter_ns); tasty-bench's default CPU time would leave out
  -- time spent waiting on the kernel, servers and child processes.
  defaultMain . map (localOption WallTime) $
    [ bgroup
        "folding"
        ( bench ("every corpus fold (" <> show (length calls) <> " calls)") (nf run calls)
            : [ bench (T.unpack loop <> " folds (" <> show (length mine) <> " calls)") (nf run mine)
              | loop <- loops
              , let mine = [c | c@(Call l _ _ _) <- calls, l == loop]
              ]
        )
    , bgroup
        "board"
        [ bench ("render_board over every corpus log (" <> show (length logs) <> " logs)") (nf (map renderBoard) logs)
        , bench ("gate_facts over every corpus log (" <> show (length logs) <> " logs)") (nf (map (fmap (const ()) . gateFactsValue)) logs)
        ]
    ]

corpus :: FilePath -> IO [Json]
corpus file = do
  bytes <- BS.readFile file
  traverse (either fail pure . parseJson pythonLoads) (filter (not . BS.null) (BS8.split '\n' bytes))

member :: Text -> Json -> Maybe Json
member key = \case
  Object members -> lookup key members
  _ -> Nothing

callOf :: BuiltNet -> Json -> IO Call
callOf built row = do
  transitionText <- case member "transition" row of
    Just (String found) -> pure found
    other -> fail ("fold row transition: " <> show other)
  transition <- either (fail . T.unpack) pure (netPath transitionText)
  handler <- case handlerUri built.net transition >>= (`Map.lookup` built.handlers) of
    Just (PureHandler f) -> pure f
    _ -> fail ("no fold handler for " <> T.unpack transitionText)
  binding <-
    either fail pure $
      Binding transition <$> selections "consumed" <*> selections "read" <*> tokens (member "delivered" row)
  pure (Call (T.takeWhile (/= '.') transitionText) handler binding (outputs built.net transition))
 where
  selections :: Text -> Either String [(NetPath, [Token])]
  selections key = case member key row of
    Just (Array items) -> traverse selection items
    other -> Left ("fold row " <> T.unpack key <> ": " <> show other)
  selection = \case
    Array [String place, items] -> (,) <$> either (Left . T.unpack) Right (netPath place) <*> tokens (Just items)
    other -> Left ("fold row selection: " <> show other)
  tokens = \case
    Just (Array items) -> traverse token items
    other -> Left ("fold row tokens: " <> show other)
  token = \case
    Array [String color, payload] -> Right (Token (Just color) payload)
    Array [Null, payload] -> Right (Token Nothing payload)
    other -> Left ("fold row token: " <> show other)
