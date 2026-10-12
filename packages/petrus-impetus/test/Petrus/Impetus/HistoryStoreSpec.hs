-- | Parity: @tests/petrus/impetus/history_store/test_history_backends.py@,
-- the generic store contract, over the kernel's own seam.
--
-- The reference runs every case against the JSONL, SQLite, and Postgres
-- backends through one @reopen@ fixture whose each call loads a FRESH
-- backend over the same storage. The suite is defined once
-- ('historyStoreContract', @Petrus.Impetus.HistoryStoreContract@) and run by
-- each backend's package; here 'newReopen' is the same fixture over the
-- kernel's own seam: a storage of schema-5 JSON lines ('encodeRecord'
-- spelled by @json.dumps@ with @allow_nan=False@) and a
-- 'Store.mirroredHistoryStore' loaded fresh from it on every call. So "kill
-- the process" is still a reopen, "resumes from the durable record alone"
-- is still literal, and every record crosses real JSON text on its way
-- back.
module Petrus.Impetus.HistoryStoreSpec (spec) where

import Control.Exception (ErrorCall (..), fromException)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Petrus.Impetus.History
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.HistoryStoreContract (historyStoreContract)
import Petrus.Impetus.HistorySupport (newReopen)
import Petrus.Impetus.TestSupport (np)
import Test.Hspec

spec :: Spec
spec = describe "HistoryStore contract" $ do
  historyStoreContract (\body -> newReopen >>= body) (fmap (\(ErrorCall m) -> T.pack m) . fromException) (pure ())

  -- Port-only: the kernel's mirrored-store seam itself.
  describe "mirrored store" $ do
    let begun n = RFiringBegun (FiringBegun (np "work") n Nothing 1)
    it "hands each write the mirror's length as its start position" $ do
      seen <- newIORef []
      store <- Store.mirroredHistoryStore Store.BackendOwned (Seq.fromList [begun 1]) $ \position batch -> do
        modifyIORef' seen (++ [position])
        -- the first record of each batch is held elsewhere
        pure (Store.AcknowledgedElsewhere : (Store.Entered <$ drop 1 batch))
      store.extend [begun 2, begun 3]
      store.extend [begun 4]
      readIORef seen `shouldReturn` [1, 2]
      Store.records store `shouldReturn` [begun 1, begun 3]

    it "refuses a write that miscounts its admissions, and enters nothing" $ do
      store <- Store.mirroredHistoryStore Store.BackendOwned Seq.empty $ \_ _ -> pure [Store.Entered]
      store.extend [begun 1, begun 2] `shouldThrow` (== Store.AdmissionMismatch 2 1)
      Store.size store `shouldReturn` 0
