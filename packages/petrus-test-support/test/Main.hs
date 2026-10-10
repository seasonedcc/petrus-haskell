module Main (main) where

import Control.Exception (bracket)
import Data.ByteString.Char8 qualified as BC
import Database.PostgreSQL.LibPQ qualified as PQ
import Petrus.Json
import Petrus.TestSupport
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

  describe "Postgres" $ postgresSpec $ do
    it "connects to a fresh scratch database" $ \target ->
      bracket (PQ.connectdb (targetUrl target)) PQ.finish $ \connection -> do
        PQ.status connection `shouldReturn` PQ.ConnectionOk
        Just result <- PQ.exec connection "SELECT current_database(), count(*) FROM pg_tables WHERE schemaname = 'public'"
        PQ.getvalue result 0 0 `shouldReturn` Just (targetDatabase target)
        PQ.getvalue result 0 1 `shouldReturn` Just "0"
    it "names scratch databases so they cannot collide with real ones" $ \target ->
      targetDatabase target `shouldSatisfy` BC.isPrefixOf "petrus_test_"
