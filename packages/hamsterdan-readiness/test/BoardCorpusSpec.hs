-- | @render_board@ and @repr(gate_facts(...))@ byte for byte against the
-- pinned Python (scripts/gen_board_corpus.py).
module BoardCorpusSpec (spec) where

import Data.Text (Text)
import Corpus
import Hamsterdan.PyLiteral (repr)
import Hamsterdan.Readiness.NetV5.Board (gateFactsValue, renderBoard)
import Petrus.Json (Json (..))
import Test.Hspec

-- | The expected outcome under @key@: the value, or @key_error@'s text.
expected :: Text -> Json -> Either Text Text
expected key row = case (member key row, member (key <> "_error") row) of
  (Just (String value), _) -> Right value
  (_, Just (String failure)) -> Left failure
  other -> error ("board corpus row: " <> show other)

spec :: Spec
spec = describe "board corpus" $ do
  rows <- runIO (readCorpus "board.jsonl")
  let entriesOf row = [e | String e <- array "entries" row]
      check key compute =
        expectNone
          [ show entries <> "\n  expected " <> show want <> "\n  got      " <> show got
          | row <- rows
          , let entries = entriesOf row
                want = expected key row
                got = compute entries
          , got /= want
          ]
  it ("render_board matches every row (" <> show (length rows) <> ")") $
    check "board" renderBoard
  it ("repr(gate_facts) matches every row (" <> show (length rows) <> ")") $
    check "facts" (fmap repr . gateFactsValue)
  it "covers refusals as well as renders" $ do
    let refusals = [() | row <- rows, Just _ <- [member "board_error" row]]
    length refusals `shouldSatisfy` (> 0)
