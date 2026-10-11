-- | Live round trips through the pinned reference (not in the reference's
-- suite; the audit's IMP-4).
--
-- For every scenario of the differential corpus, rebuilt with the Haskell
-- Instance doors, the observed Net document (marking-first lineage over
-- the canonical History) and every record of the History page are handed
-- to the reference's own @parse_net_document@ and @decode_record@, which
-- must accept them and serialize them back byte for byte
-- ("Petrus.TestSupport.Reference"). The reference must be available:
-- without it the group fails.
module Petrus.Observation.LiveSpec (spec) where

import Control.Monad (forM)
import Data.Text qualified as T
import Petrus.Impetus.NetDocument (parseNetDocumentJson, serializeNetDocument)
import Petrus.Json
import Petrus.Observation
import Petrus.Observation.CorpusSpec (scenario)
import Petrus.Observation.Support
import Petrus.TestSupport.Reference
import Test.Hspec

spec :: Spec
spec = describe "live round trip through the pinned reference" $
  it "accepts and rewrites byte for byte every observed Net document and History page record" $ do
    corpus <- corpusFile >>= readJsonFile
    let names = case member "scenarios" corpus of
          Object scenarios -> map fst scenarios
          _ -> []
    length names `shouldSatisfy` (>= 5)
    payloads <- fmap concat . forM names $ \name -> do
      o <- scenario name >>= capture
      document <- expectRight (first' (netDocument o) >>= parseNetDocumentJson >>= serializeNetDocument)
      page <- expectRight (first' (historyPage o.observed.identity o.records 0 1000))
      records <- forM (zip [0 :: Int ..] (items (member "records" page))) $ \(i, entry) -> do
        bytes <- either (fail . encodeErrorMessage) pure (dumps defaultDumps (member "record" entry))
        pure (T.unpack name <> " record " <> show i, HistoryRecordSubject, bytes)
      pure ((T.unpack name <> " net document", NetDocumentSubject, document) : records)
    shouldRoundTripThroughReference payloads
  where
    first' = either (Left . observationErrorText) Right
