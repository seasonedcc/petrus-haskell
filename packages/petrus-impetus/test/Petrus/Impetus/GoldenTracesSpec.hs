-- | Parity: @tests/integration/test_golden_replay.py@,
-- @tests/integration/test_passthrough_chain.py@, and the replay harness
-- @tests/harness.py@; plus the byte-identity of the regenerated corpus
-- (@scripts/gen-golden-traces.py@ ported as "Petrus.Impetus.GoldenTraces").
module Petrus.Impetus.GoldenTracesSpec (spec) where

import Control.Monad (forM_, unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Impetus.Binding (BoundHandler (..))
import Petrus.Impetus.GoldenTraces
import Petrus.Impetus.History.Codec (decodeRecord, encodeRecord)
import Petrus.Impetus.History.Replay (replayMarking)
import Petrus.Impetus.HistoryStore qualified as Store
import Petrus.Impetus.Instance
import Petrus.Impetus.NetDefinition (compileNetDefinition, netDefinitionFromJson)
import Petrus.Impetus.Petrinet hiding (candidates, nextMaturation)
import Petrus.Impetus.TestSupport (np)
import Petrus.Impetus.WireSupport (specFile)
import Petrus.Json
import System.Directory (listDirectory)
import Test.Hspec

traces :: FilePath -> FilePath
traces name = specFile ("traces/" <> name)

loadFixture :: Text -> IO Json
loadFixture name = do
  raw <- BS.readFile (traces (T.unpack name <> ".json"))
  either fail pure (parseJson surrogateRefusingLoads raw)

manifestEntries :: IO [Json]
manifestEntries = do
  raw <- BS.readFile (traces "manifest.json")
  case parseJson surrogateRefusingLoads raw of
    Right manifest | Just (Array xs) <- lookupMember "fixtures" manifest -> pure xs
    _ -> fail "manifest.json has no fixtures"

fixtureNames :: IO [Text]
fixtureNames = map (str . at "name") <$> manifestEntries

spec :: Spec
spec = describe "Impetus golden traces" $ do
  describe "regeneration" $ do
    it "regenerates every fixture and the manifest byte-identically" $ do
      files <- generateCorpus >>= either (fail . T.unpack) pure
      map (.file) files `shouldBe` map ((<> ".json") . T.unpack . (.name)) scenarios <> ["manifest.json"]
      forM_ files $ \f -> do
        committed <- BS.readFile (traces f.file)
        unless (f.bytes == committed) $
          expectationFailure (f.file <> " differs from the committed fixture (sha256 " <> T.unpack (sha256Hex f.bytes) <> ")")

  -- test_manifest_hashes_every_normative_fixture
  it "the manifest hashes every normative fixture" $ do
    raw <- BS.readFile (traces "manifest.json")
    manifest <- either fail pure (parseJson surrogateRefusingLoads raw)
    at "format" manifest `shouldBe` String "petrus-impetus-golden-trace-manifest"
    at "version" manifest `shouldBe` Int 2
    entries <- manifestEntries
    let files = map (str . at "file") entries
        names = map (str . at "name") entries
    Set.size (Set.fromList files) `shouldBe` length files
    Set.size (Set.fromList names) `shouldBe` length names
    files `shouldBe` map (<> ".json") names
    present <- filter (\f -> ".json" `T.isSuffixOf` f && f /= "manifest.json") . map T.pack <$> listDirectory (traces "")
    sort files `shouldBe` sort present
    forM_ entries $ \entry -> do
      payload <- BS.readFile (traces (T.unpack (str (at "file" entry))))
      String (sha256Hex payload) `shouldBe` at "sha256" entry
      BS.length (SHA256.hash payload) `shouldBe` 32
      value <- either fail pure (parseJson surrogateRefusingLoads payload)
      Int (fromIntegral (length (arr (at "walk" value)))) `shouldBe` at "walkSteps" entry

  -- test_migration_contracts_are_visible_in_raw_fixtures
  it "migration contracts are visible in raw fixtures" $ do
    perArc <- loadFixture "per_arc_passthrough"
    let produced = arr (at "produced" (at "outcome" (head' (arr (at "walk" perArc)))))
    produced
      `shouldBe` [ Object [("place", String place'), ("token", Object [("color", String "X"), ("data", Object [("n", Int v)])])]
                 | place' <- ["left", "right"]
                 , v <- [1, 2]
                 ]
    all (\p' -> at "color" (at "token" p') /= String "Config") produced `shouldBe` True
    guarded <- arr . at "candidatesBefore" . head' . arr . at "walk" <$> loadFixture "guard_enumeration"
    [(at "transition" b, at "amount" (at "data" (head' (arr (at "tokens" (head' (arr (at "consumed" b)))))))) | b <- guarded]
      `shouldBe` [(String "accept", Int 150), (String "reject", Int 40)]
    records <- map (str . at "record") . arr . at "history" <$> loadFixture "source_delivery"
    let index name = length (takeWhile (/= name) records)
    index "ExternalEventDelivered" `shouldSatisfy` (< index "FiringBegun")
    index "FiringBegun" `shouldSatisfy` (< index "TokensProduced")
    heterogeneous <- arr . at "produced" . at "outcome" . head' . arr . at "walk" <$> loadFixture "heterogeneous_fanout"
    [(at "place" e, at "color" (at "token" e)) | e <- heterogeneous]
      `shouldBe` [(String "approved", String "ApprovalNotice"), (String "ledger", String "LedgerEntry")]

  -- test_normative_fixture_replays[name]
  describe "normative fixtures replay" $ do
    names <- runIO fixtureNames
    forM_ names $ \name -> it (T.unpack name) $ do
      _ <- replayFixture =<< loadFixture name
      pure ()

  -- test_passthrough_chain_replays
  it "the passthrough chain replays to termination" $ do
    inst <- replayFixture =<< loadFixture "passthrough_chain"
    status inst >>= (`shouldBe` Terminated)

-- | @tests/harness.py::replay@: execute every recorded action and compare
-- candidates, outcomes, marking, status, and the canonical History.
replayFixture :: Json -> IO Instance
replayFixture fixture = do
  at "format" fixture `shouldBe` String "petrus-impetus-golden-trace"
  at "version" fixture `shouldBe` Int 2
  definition <- either (fail . T.unpack) pure (netDefinitionFromJson (at "net" fixture))
  net <- either (fail . T.unpack) pure (compileNetDefinition definition)
  let bindings = case at "bindings" fixture of
        Object members -> members
        _ -> []
      declarations = Set.fromList (map fst bindings)
      declared = declaredSymbols net
  declarations `shouldBe` declared
  at "bindings" fixture `shouldBe` Object [(k, v) | (k, v) <- Map.toList bindingSpecs, k `Set.member` declared]
  initial <- either (fail . T.unpack) pure (decodeMarking (at "initialMarking" fixture))
  inst <-
    newInstance
      net
      defaultInstanceConfig
        { initialMarking = initial
        , guardImplementations = Map.fromList [(Symbol k, g) | (k, g) <- Map.toList goldenGuards, k `Set.member` declarations]
        , handlerImplementations = Map.fromList [(Symbol k, PureHandler h) | (k, h) <- Map.toList goldenHandlers, k `Set.member` declarations]
        , suppliedIdentity = Just ("golden-" <> T.replace "_" "-" (str (at "name" fixture)))
        }
      >>= either (fail . T.unpack . renderInstanceError) pure
  forM_ (arr (at "walk" fixture)) $ \expected -> do
    enabledBefore <- candidates inst
    Array (map encodeBinding enabledBefore) `shouldBe` at "candidatesBefore" expected
    let action = at "action" expected
        when' = lookupMember "at" action >>= jsonInstant
        orFail = either (fail . T.unpack . renderInstanceError) pure
    outcome <- case str (at "kind" action) of
      "step" -> step inst when' >>= orFail
      "deliver" -> do
        tokens <- either (fail . T.unpack) pure (traverse decodeToken (arr (at "tokens" action)))
        acceptDelivery inst (np (str (at "source" action))) tokens (str (at "identity" action)) Nothing when' >>= orFail >>= \case
          DeliveryAccepted accepted -> Just <$> (completeDelivery inst accepted when' >>= orFail)
          _ -> fail "the recorded delivery was not freshly accepted"
      "seal" -> Nothing <$ (seal inst (np (str (at "source" action))) when' >>= orFail)
      other -> fail ("unknown action " <> T.unpack other)
    maybe Null encodeOutcome outcome `shouldBe` at "outcome" expected
    markingAfter <- marking inst
    encodeMarking markingAfter `shouldBe` at "markingAfter" expected
    status inst >>= (`shouldBe` at "statusAfter" expected) . String . statusText
  final <- marking inst
  encodeMarking final `shouldBe` at "marking" (at "final" fixture)
  status inst >>= (`shouldBe` at "status" (at "final" fixture)) . String . statusText
  history <- Store.records (instanceHistory inst)
  Array (map encodeRecord history) `shouldBe` at "history" fixture
  decoded <- either (fail . T.unpack) pure (traverse decodeRecord (arr (at "history" fixture)))
  replayed <- either (fail . T.unpack) pure (replayMarking decoded)
  when (encodeMarking replayed /= encodeMarking final) $
    expectationFailure "replay_marking of the decoded History differs from the instance marking"
  pure inst

decodeMarking :: Json -> Either Text Marking
decodeMarking value = do
  entries <- traverse entry (arr value)
  Right (markingFromList entries)
  where
    entry e = (,) (np (str (at "place" e))) <$> traverse decodeToken (arr (at "tokens" e))

at :: Text -> Json -> Json
at key value = maybe (error ("missing " <> T.unpack key)) id (lookupMember key value)

str :: Json -> Text
str = \case
  String s -> s
  other -> error ("expected a string, got " <> show other)

arr :: Json -> [Json]
arr = \case
  Array xs -> xs
  other -> error ("expected an array, got " <> show other)

head' :: [a] -> a
head' = \case
  x : _ -> x
  [] -> error "empty"
