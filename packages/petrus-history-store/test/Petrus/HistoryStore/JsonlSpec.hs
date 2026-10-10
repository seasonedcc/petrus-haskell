-- | Parity: @tests/petrus/impetus/history_store/test_persistence.py@ —
-- @TestDurableAppend@ and @TestJsonlHistoryStore@ (the JSONL file
-- mechanics) — plus the load and durability edges the reference implies.
module Petrus.HistoryStore.JsonlSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Petrus.HistoryStore.Jsonl
import Petrus.HistoryStore.Support
import Petrus.Impetus.Binding (handlerTokens)
import Petrus.Impetus.History
import Petrus.Impetus.HistoryStore (HistoryStore (..))
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.HistorySupport (everyRecordCategory)
import Petrus.Impetus.Instance
import Petrus.Impetus.Petrinet hiding (candidates)
import Petrus.Impetus.TestSupport (expectRight, netOf, np, tokD)
import Petrus.Json (Json (..))
import Petrus.Telemetry (newRecorder, recorded, recorderSink)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

initialized :: Record
initialized = RTokensInitialized (TokensInitialized place' [token'] 0 [] Nothing)

spec :: Spec
spec = do
  describe "TestDurableAppend" $ do
    it "appends accumulate across calls" $ withScratch $ \dir -> do
      let path = dir </> "lines.jsonl"
          durable = durableAppend ProcessCrash path
      appendLines durable ["one", "two"]
      appendLines durable ["three"]
      BS.readFile path `shouldReturn` "one\ntwo\nthree\n"

    it "makes the parent directory once needed" $ withScratch $ \dir -> do
      let path = dir </> "nested" </> "deeper" </> "lines.jsonl"
      appendLines (durableAppend ProcessCrash path) ["one"]
      BS.readFile path `shouldReturn` "one\n"

    it "power-failure durability writes the same bytes (fsync is the only difference)" $ withScratch $ \dir -> do
      let path = dir </> "fresh" </> "lines.jsonl"
          durable = durableAppend PowerFailure path
      appendLines durable ["one"]
      appendLines durable ["two"]
      BS.readFile path `shouldReturn` "one\ntwo\n"

  describe "TestJsonlHistoryStore" $ do
    it "the durable spelling is byte-stable" $ withScratch $ \dir -> do
      let path = dir </> "history.jsonl"
          fixture =
            "{\"record\": \"TokensInitialized\", \"schema\": 5, \"place\": \"p\", \
            \\"tokens\": [{\"color\": \"issue\", \"data\": {\"id\": \"goose\", \"passed\": true}}], \
            \\"instant\": 0, \"entries\": [], \"scope\": null}\n\
            \{\"record\": \"CandidateSelected\", \"schema\": 5, \"transition\": \"t\", \
            \\"occurrence\": 1, \"instant\": 2}\n"
          batch = [initialized, RCandidateSelected (CandidateSelected transition' 1 2)]
      store <- openJsonlHistoryStore path
      store.extend batch
      BS.readFile path `shouldReturn` fixture
      (openJsonlHistoryStore path >>= Store.records) `shouldReturn` batch

    it "direct firing lifecycle JSONL bytes are stable" $ withScratch $ \dir -> do
      let path = dir </> "firing.jsonl"
          consumed = np "consume"
          observed = np "read"
          produced = np "produced"
          net =
            netOf
              [place consumed, place observed, place produced]
              [transition transition']
              [arc consumed transition', Arc observed transition' Read 1 Nothing Nothing, arc transition' produced]
          fixture =
            T.unlines
              [ "{\"record\": \"InstanceCreated\", \"schema\": 5, \"instance\": \"fixture-instance\", \"name\": null, \"instant\": 1}"
              , "{\"record\": \"TokensInitialized\", \"schema\": 5, \"place\": \"consume\", \"tokens\": [{\"color\": \"issue\", \"data\": {\"id\": \"goose\", \"passed\": true}}], \"instant\": 1, \"entries\": [], \"scope\": null}"
              , "{\"record\": \"TokensInitialized\", \"schema\": 5, \"place\": \"read\", \"tokens\": [{\"color\": null, \"data\": null}], \"instant\": 1, \"entries\": [], \"scope\": null}"
              , "{\"record\": \"CandidateSelected\", \"schema\": 5, \"transition\": \"t\", \"occurrence\": 1, \"instant\": 2}"
              , "{\"record\": \"FiringBegun\", \"schema\": 5, \"transition\": \"t\", \"occurrence\": 1, \"scope\": null, \"instant\": 2}"
              , "{\"record\": \"TokensConsumed\", \"schema\": 5, \"place\": \"consume\", \"tokens\": [{\"color\": \"issue\", \"data\": {\"id\": \"goose\", \"passed\": true}}], \"occurrence\": 1, \"entries\": [], \"scope\": null, \"instant\": 2}"
              , "{\"record\": \"TokensRead\", \"schema\": 5, \"place\": \"read\", \"tokens\": [{\"color\": null, \"data\": null}], \"occurrence\": 1, \"entries\": [], \"scope\": null, \"instant\": 2}"
              , "{\"record\": \"TokensProduced\", \"schema\": 5, \"place\": \"produced\", \"tokens\": [{\"color\": \"result\", \"data\": {\"fixed\": true}}], \"occurrence\": 1, \"entries\": [], \"scope\": null, \"instant\": 3}"
              , "{\"record\": \"FiringCompleted\", \"schema\": 5, \"transition\": \"t\", \"occurrence\": 1, \"instant\": 3}"
              ]
      history <- openJsonlHistoryStore path
      inst <-
        newInstance
          net
          defaultInstanceConfig
            { initialMarking = markingFromList [(consumed, [token']), (observed, [black])]
            , constructionInstant = 1
            , historyStore = Just history
            , suppliedIdentity = Just "fixture-instance"
            }
          >>= expectRight
      (b : _) <- candidates inst
      occurrence <- begin inst b (Just 2) >>= expectRight
      _ <-
        complete inst occurrence (Just (handlerTokens [(produced, [tokD "result" (Object [("fixed", Bool True)])])])) (Just 3)
          >>= expectRight
      BS.readFile path `shouldReturn` BC.pack (T.unpack fixture)
      live <- Store.records (instanceHistory inst)
      (openJsonlHistoryStore path >>= Store.records) `shouldReturn` live

    it "every append is durable immediately" $ withScratch $ \dir -> do
      let path = dir </> "history.jsonl"
      history <- openJsonlHistoryStore path
      Store.append history initialized
      mirror <- Store.records history
      (openJsonlHistoryStore path >>= Store.records) `shouldReturn` mirror
      history.extend [RFiringBegun (FiringBegun transition' 1 Nothing 1), RFiringCompleted (FiringCompleted transition' 1 1)]
      mirror' <- Store.records history
      (openJsonlHistoryStore path >>= Store.records) `shouldReturn` mirror'
      Store.size history `shouldReturn` 3

    it "loading then appending continues the file" $ withScratch $ \dir -> do
      let path = dir </> "history.jsonl"
          later = RFiringFailed (FiringFailed transition' "later" 3 6)
      openJsonlHistoryStore path >>= \s -> s.extend everyRecordCategory
      resumed <- openJsonlHistoryStore path
      Store.append resumed later
      (openJsonlHistoryStore path >>= Store.records) `shouldReturn` (everyRecordCategory ++ [later])

    it "a missing file is an empty history" $ withScratch $ \dir -> do
      let path = dir </> "nested" </> "history.jsonl"
      history <- openJsonlHistoryStore path
      Store.records history `shouldReturn` []
      doesDirectoryExist (dir </> "nested") `shouldReturn` False
      Store.append history initialized
      doesFileExist path `shouldReturn` True

    it "a v1-encoded line fails loud at load naming the migration" $ withScratch $ \dir -> do
      let path = dir </> "history.jsonl"
      BS.writeFile path "{\"record\": \"RegistrationOpened\", \"source\": \"t\", \"key\": \"default\", \"attempt\": null, \"instant\": 0}\n"
      openJsonlHistoryStore path
        `shouldThrow` \(HistoryStoreError m) ->
          "line 1" `T.isInfixOf` m && "no 'schema' version" `T.isInfixOf` m && "reads schema 5 only" `T.isInfixOf` m

    it "a schema-2 line fails through the actual JSONL load" $ withScratch $ \dir -> do
      let path = dir </> "history.jsonl"
      BS.writeFile
        path
        "{\"record\": \"ActivityRequested\", \"schema\": 2, \"transition\": \"t\", \
        \\"activity\": \"old\", \"capabilities\": [\"gpu\"], \"occurrence\": 1, \"instant\": 0}\n"
      openJsonlHistoryStore path
        `shouldThrow` \(HistoryStoreError m) ->
          "line 1" `T.isInfixOf` m && "'schema' is 2" `T.isInfixOf` m && "reads schema 5 only" `T.isInfixOf` m

    it "a torn tail fails loud naming the line" $ withScratch $ \dir -> do
      let path = dir </> "history.jsonl"
      openJsonlHistoryStore path >>= \s -> Store.append s initialized
      BS.appendFile path "{\"record\": \"FiringComp"
      openJsonlHistoryStore path
        `shouldThrow` \(HistoryStoreError m) ->
          m == T.pack path <> ": line 2 does not decode as an event history record: Unterminated string starting at: line 1 column 12 (char 11)"

    it "unencodable data fails loud and appends nothing" $ withScratch $ \dir -> do
      -- NaN stands in for the reference's object(): every Haskell 'Json'
      -- value is encodable except a non-finite float.
      let path = dir </> "history.jsonl"
      history <- openJsonlHistoryStore path
      Store.append history (RTokensInitialized (TokensInitialized place' [tokD "x" (Float (0 / 0))] 0 [] Nothing))
        `shouldThrow` \(HistoryStoreError m) ->
          m
            == "cannot durably encode TokensInitialized: Out of range float values are not JSON compliant: nan — durable instants and token data must be JSON-faithful values"
      Store.size history `shouldReturn` 0
      doesFileExist path `shouldReturn` False

    it "a mid-batch encoding failure writes nothing" $ withScratch $ \dir -> do
      let path = dir </> "history.jsonl"
      history <- openJsonlHistoryStore path
      history.extend
        [ RFiringBegun (FiringBegun transition' 1 Nothing 1)
        , RTokensProduced (TokensProduced place' [tokD "x" (Float (1 / 0))] 1 [] Nothing 1)
        ]
        `shouldThrow` storeErrorContaining "TokensProduced"
      Store.size history `shouldReturn` 0
      doesFileExist path `shouldReturn` False

  describe "JSONL load edges (the reference's text-mode reader)" $ do
    let loads content = withScratch $ \dir -> do
          let path = dir </> "h.jsonl"
          BS.writeFile path content
          map recordName <$> (openJsonlHistoryStore path >>= Store.records)
        line1 = "{\"record\": \"CandidateSelected\", \"schema\": 5, \"transition\": \"t\", \"occurrence\": 1, \"instant\": 2}"
    it "reads a final line without a terminator" $
      loads (line1 <> "\n" <> line1) `shouldReturn` ["CandidateSelected", "CandidateSelected"]
    it "reads CRLF and CR line endings as universal newlines" $
      loads (line1 <> "\r\n" <> line1 <> "\r" <> line1 <> "\r\n") `shouldReturn` replicate 3 "CandidateSelected"
    it "an empty file is an empty history" $ loads "" `shouldReturn` []
    it "a blank line refuses the load with CPython's diagnostic" $ withScratch $ \dir -> do
      let path = dir </> "h.jsonl"
      BS.writeFile path (line1 <> "\n\n" <> line1 <> "\n")
      openJsonlHistoryStore path
        `shouldThrow` \(HistoryStoreError m) ->
          m == T.pack path <> ": line 2 does not decode as an event history record: Expecting value: line 2 column 1 (char 1)"
    it "a record decode failure carries the codec's message" $ withScratch $ \dir -> do
      let path = dir </> "h.jsonl"
      BS.writeFile path "{\"schema\": 5}\n"
      openJsonlHistoryStore path `shouldThrow` storeErrorContaining (T.pack path <> ": line 1 does not decode as an event history record: ")
    -- decode_record begins with dict(payload): a line that is not a JSON
    -- object is refused with dict's own text (captured from the reference)
    let refusedLine json message = withScratch $ \dir -> do
          let path = dir </> "h.jsonl"
          BS.writeFile path (json <> "\n")
          openJsonlHistoryStore path
            `shouldThrow` \(HistoryStoreError m) -> m == T.pack path <> ": line 1 does not decode as an event history record: " <> message
    it "a line that is a number refuses as dict(5) does" $ refusedLine "5" "'int' object is not iterable"
    it "a line that is null refuses as dict(None) does" $ refusedLine "null" "'NoneType' object is not iterable"
    it "a line that is a string refuses as dict('ab') does" $ refusedLine "\"ab\"" "dictionary update sequence element #0 has length 1; 2 is required"
    it "a line that is an empty list is an empty mapping" $ refusedLine "[]" "cannot decode event history record: payload has no 'record' discriminator"
    it "a list of pairs with an unhashable key refuses as dict() does" $ refusedLine "[[[1], 2]]" "cannot use 'list' as a dict key (unhashable type: 'list')"
    it "a list of pairs is decoded as the mapping dict() builds (the last repeated key wins)" $ withScratch $ \dir -> do
      let path = dir </> "h.jsonl"
      BS.writeFile path "[[\"record\", \"CandidateSelected\"], [\"schema\", 5], [\"transition\", \"t\"], [\"occurrence\", 1], [\"instant\", 2], [\"instant\", 3]]\n"
      (openJsonlHistoryStore path >>= Store.records) `shouldReturn` [RCandidateSelected (CandidateSelected transition' 1 3)]

  describe "jsonl_commit telemetry" $ do
    it "emits one event per durable commit with its batch size and bytes" $ withScratch $ \dir -> do
      recorder <- newRecorder
      let path = dir </> "history.jsonl"
      history <- openJsonlHistoryStoreWith defaultJsonlOptions {telemetry = Just (recorderSink recorder)} path
      history.extend [initialized, RCandidateSelected (CandidateSelected transition' 1 2)]
      events <- recorded recorder
      size <- BS.length <$> BS.readFile path
      case events of
        [payload] -> do
          lookup "event" payload `shouldBe` Just (String "impetus_jsonl_commit")
          lookup "records" payload `shouldBe` Just (Int 2)
          lookup "bytes" payload `shouldBe` Just (Int (fromIntegral size))
          fmap (const ()) (lookup "elapsed_ms" payload) `shouldBe` Just ()
        other -> expectationFailure ("expected one event, got " <> show other)

  describe "a store is the kernel's contract" $
    it "drives an Instance's every appending door through the file" $ withScratch $ \dir -> do
      let path = dir </> "history.jsonl"
          src = np "src"
          net = netOf [place place'] [transition src] [arc src place']
      history <- openJsonlHistoryStore path
      inst <- newInstance net defaultInstanceConfig {historyStore = Just history} >>= expectRight
      DeliveryAccepted accepted <- acceptDelivery inst src [token'] "evt-1" Nothing Nothing >>= expectRight
      _ <- completeDelivery inst accepted Nothing >>= expectRight
      _ <- seal inst src Nothing >>= expectRight
      live <- Store.records (instanceHistory inst)
      (openJsonlHistoryStore path >>= Store.records) `shouldReturn` live
      Map.size (Map.fromList [(recordName r, ()) | r <- live]) `shouldSatisfy` (> 3)
