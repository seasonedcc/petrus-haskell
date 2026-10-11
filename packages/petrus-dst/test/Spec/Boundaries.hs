{-# LANGUAGE OverloadedRecordDot #-}

-- | @tests/dst/test_dst_boundaries.py@: CV19.DS4 bounded complementary
-- production-boundary operation.
--
-- The real route runs the owner suites' built binaries; their PostgreSQL
-- owners are pending without @PETRUS_TEST_POSTGRES@, and the route refuses
-- pending owners (the reference's @--forbid-skips@), so the real-route
-- example is pending without a server too, exactly as the owners are.
module Spec.Boundaries (spec) where

import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Json (Json (..), parseJson, pythonLoads)
import Petrus.Testing.Dst.Boundaries
import Petrus.Testing.Dst.Campaign.Support (ToolError (..))
import Petrus.TestSupport.Postgres (lookupPostgresUrl, skipMessage)
import Spec.Support (member, memberList)
import System.Directory (getFileSize)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

refusing :: Text -> ToolError -> Bool
refusing needle (ToolError message) = needle `T.isInfixOf` message

readReport :: FilePath -> IO Json
readReport file = BS.readFile file >>= either fail pure . parseJson pythonLoads

timeoutRunner :: BoundaryRunner
timeoutRunner =
  BoundaryRunner
    { execute = \_ ->
        pure
          ( Object
              [ ("elapsed_ms", Int 120000)
              , ("outcome", String "timeout")
              , ("returncode", Int (-9))
              , ("termination", String "killed")
              ]
          )
    , repository = pure (Object [("commit", String (T.replicate 40 "0")), ("dirty", Bool False)])
    }

spec :: Spec
spec = describe "test_dst_boundaries.py (production-boundary qualification)" $ do
  server <- runIO lookupPostgresUrl
  it "test_real_boundary_route_reports_executed_claims_and_non_equivalence" $
    case server of
      Nothing -> pendingWith skipMessage
      Just _ -> withSystemTempDirectory "petrus-dst-boundaries-" $ \dir -> do
        let reportPath = dir </> "boundaries.json"
        code <- runBoundaryQualification [p.name | p <- boundaryProfiles] reportPath
        report <- readReport reportPath
        code `shouldBe` 0
        member "format" report `shouldBe` String reportFormat
        member "version" report `shouldBe` Int reportVersion
        member "outcome" report `shouldBe` String "pass"
        member "deselected_profiles" report `shouldBe` Array []
        getFileSize reportPath >>= (`shouldSatisfy` (<= toInteger reportBytes))
        let profiles = memberList "profiles" report
        length profiles `shouldBe` 6
        Set.fromList [t | p <- profiles, String t <- [member "outcome" p]] `shouldBe` Set.fromList ["pass"]
        Set.fromList [t | p <- profiles, String t <- [member "evidence" p]]
          `shouldBe` Set.fromList
                [ "deterministic-world"
                , "real-postgresql-absurd-transaction"
                , "real-postgresql-absurd-reconstruction"
                , "real-worker-process-sigkill"
                , "real-zeromq-dispatch-process-kill"
                ]
        comparison <- case memberList "comparisons" report of
          c : _ -> pure c
          [] -> fail "no comparisons"
        member "status" comparison `shouldBe` String "complete"
        case member "non_equivalence" comparison of
          String s -> ("does not OS-kill the authority" `T.isInfixOf` s) `shouldBe` True
          other -> expectationFailure (show other)
        case memberList "unmodeled_boundaries" report of
          String first : _ -> ("authority-process OS SIGKILL" `T.isInfixOf` first) `shouldBe` True
          other -> expectationFailure (show other)

  it "test_boundary_route_refuses_empty_duplicate_and_unknown_selection" $
    withSystemTempDirectory "petrus-dst-boundaries-" $ \dir -> do
      runBoundaryQualification [] (dir </> "empty.json") `shouldThrow` refusing "at least one profile"
      runBoundaryQualification ["simulated-dispatch-crash-load", "simulated-dispatch-crash-load"] (dir </> "duplicate.json")
        `shouldThrow` refusing "more than once"
      runBoundaryQualification ["unknown"] (dir </> "unknown.json") `shouldThrow` refusing "unknown production-boundary profile"

  it "test_boundary_timeout_and_report_overage_are_visible" $
    withSystemTempDirectory "petrus-dst-boundaries-" $ \dir -> do
      let reportPath = dir </> "timeout.json"
      code <- runBoundaryQualificationWith timeoutRunner reportBytes ["simulated-dispatch-crash-load"] reportPath
      report <- readReport reportPath
      code `shouldBe` 1
      member "outcome" report `shouldBe` String "timeout"
      [member "outcome" p | p <- memberList "profiles" report] `shouldBe` [String "not-qualified"]

      runBoundaryQualificationWith timeoutRunner 1 ["simulated-dispatch-crash-load"] (dir </> "overage.json")
        `shouldThrow` (\(ToolError m) -> "production-boundary report has " `T.isPrefixOf` m && " bytes; limit is 1" `T.isSuffixOf` m)
