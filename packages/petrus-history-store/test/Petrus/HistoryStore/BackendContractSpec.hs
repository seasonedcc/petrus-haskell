-- | Parity: @tests/petrus/impetus/history_store/test_history_backends.py@,
-- the backend-contract suite, run against the JSONL backend.
--
-- The suite itself is defined once, in the kernel's test tree
-- (@Petrus.Impetus.HistoryStoreContract@, compiled in here). 'backendContract'
-- instantiates it for a durable backend, with the refusal every backend
-- shares; this package runs it for JSONL (the SQLite store adds its own
-- instantiation next to it, and petrus-history-postgres one for Postgres).
module Petrus.HistoryStore.BackendContractSpec (spec, backendContract) where

import Control.Exception (fromException)
import Data.Text qualified as T
import Petrus.HistoryStore.Jsonl (HistoryStoreError (..))
import Petrus.HistoryStore.Support (jsonlReopen, withScratch)
import Petrus.Impetus.History
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.HistoryStoreContract (historyStoreContract)
import Petrus.Impetus.Petrinet
import Petrus.Impetus.TestSupport (np, tokD)
import Petrus.Json
import Test.Hspec

queue, work, out :: NetPath
queue = np "queue"
work = np "work"
out = np "out"

spec :: Spec
spec = backendContract "jsonl" (\body -> withScratch (body . jsonlReopen))

-- | The suite over a backend: @withReopen@ runs an example with a fresh
-- storage and its @reopen@ factory.
backendContract :: String -> ((IO HistoryStore -> IO ()) -> IO ()) -> Spec
backendContract backend withReopen =
  describe ("backend contract (" <> backend <> ")") $
    historyStoreContract withReopen (fmap (\(HistoryStoreError m) -> m) . fromException) $ do
      -- Beyond the reference's NaN case: every refusal of @json.dumps@ (here an
      -- integer over CPython's 4300-digit limit in token data) fails loud with
      -- the backend's "cannot durably encode" text, on every backend alike,
      -- and leaves the stored history exactly as it was (no blank line, no
      -- partial row), so the next load still succeeds.
      it "an over-long integer fails loud and leaves the history unchanged" $ withReopen $ \reopen -> do
        history <- reopen
        let kept = RTokensInitialized (TokensInitialized queue [black] 0 [] Nothing)
            huge = RTokensProduced (TokensProduced out [tokD "x" (Object [("n", Int (10 ^ (5000 :: Int)))])] 1 [] Nothing 1)
            refusal = "cannot durably encode TokensProduced: " <> T.pack (encodeErrorMessage (IntegerTooLarge maxIntStrDigits)) <> " — durable instants"
        Store.append history kept
        Store.append history huge
          `shouldThrow` \(HistoryStoreError m) -> refusal `T.isPrefixOf` m && "must be JSON-faithful values" `T.isSuffixOf` m
        history.extend [RFiringBegun (FiringBegun work 1 Nothing 1), huge]
          `shouldThrow` \(HistoryStoreError m) -> refusal `T.isPrefixOf` m
        Store.records history `shouldReturn` [kept]
        (reopen >>= Store.records) `shouldReturn` [kept]
