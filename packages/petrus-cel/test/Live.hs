-- | Live round trips through the pinned reference (not in the reference's
-- suite; the audit's IMP-4).
--
-- For every end-to-end case of @test/corpus/cel-instance.json@ (nets whose
-- guards, arc filters and completion conditions are inline CEL), the Net
-- definition and Net document Haskell projects from the compiled net, and
-- the History Haskell writes running the case on 'Petrus.Cel.Impetus.celCompilers',
-- are handed to the reference's own @parse_net_definition@,
-- @parse_net_document@ and @decode_record@, which must accept them and
-- serialize them back byte for byte ("Petrus.TestSupport.Reference"). The
-- reference must be available: without it the group fails.
module Live
  ( spec
  ) where

import Control.Monad (forM, replicateM_)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Impetus (caseSteps, celInstanceCases, startCelCase)
import Petrus.Impetus.History.Codec (encodeRecord)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.NetDefinition (projectNetDefinition, serializeNetDefinition)
import Petrus.Impetus.NetDocument (projectNetDocument, serializeNetDocument)
import Petrus.Json
import Petrus.TestSupport.Reference

spec :: Spec
spec = describe "live round trip through the pinned reference" $
  it "accepts and rewrites byte for byte the CEL nets and the History Haskell writes running them" $ do
    cases <- celInstanceCases
    payloads <- fmap concat . forM cases $ \c -> do
      let name = case lookupMember "name" c of
            Just (String n) -> T.unpack n
            _ -> error "cel-instance case without a name"
      (net, inst) <- startCelCase c
      replicateM_ (length (caseSteps c)) (step inst Nothing >>= either (fail . T.unpack . renderInstanceError) (const (pure ())))
      history <- Store.records (instanceHistory inst)
      definition <- expectRight (projectNetDefinition net >>= serializeNetDefinition)
      document <- expectRight (projectNetDocument net Nothing Nothing >>= serializeNetDocument)
      records <- forM (zip [0 :: Int ..] history) $ \(i, r) ->
        (name <> " record " <> show i,HistoryRecordSubject,) <$> recordBytes (encodeRecord r)
      pure ((name <> " definition", NetDefinitionSubject, definition) : (name <> " document", NetDocumentSubject, document) : records)
    length payloads `shouldSatisfy` (> length cases * 3)
    shouldRoundTripThroughReference payloads

-- | One record as @json.dumps(encode_record(record))@ spells it.
recordBytes :: Json -> IO ByteString
recordBytes = either (fail . encodeErrorMessage) pure . dumps defaultDumps

expectRight :: Either Text a -> IO a
expectRight = either (fail . T.unpack) pure
