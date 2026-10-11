module Main (main) where

import Control.Exception (bracket)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Database.PostgreSQL.LibPQ qualified as PQ
import Petrus.Json
import Petrus.TestSupport
import Petrus.TestSupport.Reference
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "Repo" $ do
    it "finds the repository root from a package directory" $ do
      root <- repoRoot
      doesFileExist (root </> "cabal.project") `shouldReturn` True
    it "loads upstream fixtures as CPython would" $ do
      profile <- upstreamJson "spec/observation/simulation-service-profile-v1.json"
      lookupMember "profile" profile `shouldSatisfy` maybe False (const True)
    it "refuses paths that do not exist at the pin" $
      upstreamPath "spec/no-such-file.json" `shouldThrow` (\(MissingUpstream _) -> True)

  describe "Python" $ do
    it "runs snippets in the pinned environment" $ do
      value <- pythonJson "import json, sys, petrus; print(json.dumps([sys.version_info[:2], sys.argv[1:]]))" ["a", "é"]
      value `shouldBe` Array [Array [Int 3, Int 14], Array [String "a", String "é"]]
    it "reports failures with both streams" $
      python "import sys; print('out'); sys.exit('boom')" [] `shouldThrow` \failure ->
        failureStdout failure == "out\n" && BC.isInfixOf "boom" (failureStderr failure)
    it "drives interactive helpers over a line protocol" $
      withPython "import sys\nprint('ready', flush=True)\nfor line in sys.stdin:\n    print(line.strip().upper(), flush=True)" [] $ \helper -> do
        expectLine helper "ready"
        sendLine helper "ping"
        readLine helper `shouldReturn` "PING"

  describe "Reference" $ do
    it "returns the reference's own rewrite of each payload, in order" $ do
      canonical <- upstreamPath "spec/net-definition-v3.json" >>= BS.readFile
      invalid <- upstreamPath "spec/net-definition-v3-invalid-integer.json" >>= BS.readFile
      verdicts <- referenceRoundTrips [(NetDefinitionSubject, canonical), (NetDefinitionSubject, invalid), (NetDefinitionSubject, canonical <> "\n")]
      case verdicts of
        [Reserialized first, Refused problem, Reserialized padded] -> do
          first `shouldBe` canonical
          padded `shouldBe` canonical
          T.unpack problem `shouldContain` "outside the inclusive interoperable range"
        other -> expectationFailure ("unexpected verdicts: " <> show other)
    it "fails an expectation on a refusal or on any byte the reference rewrites" $ do
      canonical <- upstreamPath "spec/net-definition-v3.json" >>= BS.readFile
      shouldRoundTripThroughReference [("canonical", NetDefinitionSubject, canonical)]
      shouldRoundTripThroughReference [("padded", NetDefinitionSubject, canonical <> "\n")] `shouldThrow` anyException
      shouldRoundTripThroughReference [("not JSON", NetDocumentSubject, "{")] `shouldThrow` anyException
    it "rewrites a History record as json.dumps spells it" $ do
      let record = "{\"record\": \"InstanceCreated\", \"schema\": 5, \"instance\": \"i\", \"name\": null, \"instant\": 0}"
      referenceRoundTrips [(HistoryRecordSubject, record)] `shouldReturn` [Reserialized record]

  describe "Postgres" $ postgresSpec $ do
    it "connects to a fresh scratch database" $ \target ->
      bracket (PQ.connectdb (targetUrl target)) PQ.finish $ \connection -> do
        PQ.status connection `shouldReturn` PQ.ConnectionOk
        Just result <- PQ.exec connection "SELECT current_database(), count(*) FROM pg_tables WHERE schemaname = 'public'"
        PQ.getvalue result 0 0 `shouldReturn` Just (targetDatabase target)
        PQ.getvalue result 0 1 `shouldReturn` Just "0"
    it "names scratch databases so they cannot collide with real ones" $ \target ->
      targetDatabase target `shouldSatisfy` BC.isPrefixOf "petrus_test_"
