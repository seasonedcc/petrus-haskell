-- | Parity: @tests/petrus/impetus/instance/test_fifo_queue.py@, plus a
-- resume round trip over the same trace.
module Petrus.Impetus.FifoQueueSpec (spec) where

import Data.Foldable (toList)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport hiding (enabledTransitions)
import Petrus.Json (Json (..))
import Test.Hspec

queue, take', taken :: NetPath
queue = np "queue"
take' = np "take"
taken = np "taken"

fifoNet :: Net
fifoNet = netOf [place queue, place taken] [transition take'] [arc queue take', arc take' taken]

item :: Integer -> Token
item n = Token (Just "Item") (Object [("seq", Int n)])

seeded :: IO Instance
seeded =
  newInstance fifoNet defaultInstanceConfig {initialMarking = markingFromList [(queue, map item [1, 2, 3])]}
    >>= expectRight

spec :: Spec
spec = describe "Instance FIFO drain" $ do
  -- test_each_firing_consumes_the_front_token
  it "each firing consumes the front token" $ do
    instance' <- seeded
    Just firing <- step instance' Nothing >>= expectRight
    firing.consumed `shouldBe` [item 1]
    current <- marking instance'
    toList (placeTokens queue current) `shouldBe` [item 2, item 3]
  -- test_sink_accumulates_in_arrival_order
  it "the sink accumulates in arrival order" $ do
    instance' <- seeded
    firings <- run instance' >>= expectRight
    length firings `shouldBe` 3
    current <- marking instance'
    toList (placeTokens taken current) `shouldBe` map item [1, 2, 3]
    status instance' >>= (`shouldBe` Terminated)
  it "resumes to the same marking, watermark, and occurrence counter" $ do
    instance' <- seeded
    _ <- step instance' Nothing >>= expectRight
    resumed <- resume fifoNet (instanceHistory instance') defaultInstanceConfig >>= expectRight
    instanceIdentity resumed `shouldBe` instanceIdentity instance'
    (,) <$> marking resumed <*> watermark resumed >>= (`shouldBe` (markingFromList [(queue, [item 2, item 3]), (taken, [item 1])], IntNumber 0))
    Just firing <- step resumed Nothing >>= expectRight
    firing.occurrence `shouldBe` 2
    n <- Store.size (instanceHistory resumed)
    n `shouldBe` 12
