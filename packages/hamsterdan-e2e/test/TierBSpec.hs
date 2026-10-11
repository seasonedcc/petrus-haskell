-- | Tier B of docs/hamsterdan.md §5.2, offline: every readiness journey is
-- recorded as a tape from the reference host over real HTTP
-- (@python/record_journey.py@), replayed into the reference
-- (@python/replay_python.py@) and into this host ("Hamsterdan.E2E.Replay"),
-- each against the tape's fake GitHub (@python/tape_server.py@), and the
-- three runs compared (@python/compare_tier_b.py@): the writes (byte for
-- byte between the replays), every History file byte for byte, the state
-- directory, the final comment set, and no unrecorded, unused or
-- mismatched exchange anywhere.
--
-- Three recordings add a failure path (an agent call failing, a GitHub
-- connection dropped without an answer, once where the host stops on it
-- and once where it recovers), and the last group checks that the
-- comparison does fail when a side differs. Recorded failures raise
-- alike in both replays (@python/raise_check.py@), and a record the
-- reference refuses is refused.
--
-- The reference environment is provisioned by @scripts/upstream-python@;
-- when it cannot be, these tests fail, never skip.
module TierBSpec (spec) where

import Control.Exception (SomeException, displayException, fromException, try)
import Control.Monad (forM, forM_, unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Protocol (AgentProtocolError (..))
import Hamsterdan.Contracts.Codec qualified as Codec
import Hamsterdan.E2E.Replay (RecordedError, raiseRecorded)
import Hamsterdan.E2E.Tape (TapeError, canonical, field, member)
import Hamsterdan.GitHub.Models (BoundaryKind (..), GitHubBoundaryError (..), failureClassName)
import Hamsterdan.Host.GitPublish (GitPublishError (..), categoryName)
import Petrus.Json (Json (..))
import Petrus.Json.Python (loadsBytes)
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Support
import System.Directory (copyFile, createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

-- | @(test name, journey, fault)@.
cases :: [(String, String, Maybe String)]
cases =
  [(journey, journey, Nothing) | journey <- journeys]
    <> [ ("seeded_review_finding, its agent call failing", "seeded_review_finding", Just "agent")
       , ("clean_green, a GitHub connection dropped (the pump raises)", "clean_green", Just "github:12")
       , ("agent_repair, a GitHub connection dropped (the host recovers)", "agent_repair", Just "github:60")
       ]

journeys :: [String]
journeys =
  [ "clean_green"
  , "first_attempt_flake"
  , "persistent_ci_regression"
  , "seeded_review_finding"
  , "conversational_change"
  , "agent_repair"
  , "hero_review"
  , "draft_ready"
  , "stale_base_update"
  , "true_conflict_resolution"
  , "collaboration_approval"
  ]

spec :: Spec
spec = describe "tier B: the reference recorded, both hosts replayed" $ do
  forM_ cases $ \(name, journey, fault) ->
    it name $ withRoot $ \dir -> do
      run <- tierB dir journey fault
      (status, report) <- compareRun run []
      unless (status == ExitSuccess && member "ok" report == Bool True) $
        expectationFailure ("the replays differ from the recording:\n" <> render report)
      -- Every replay served the whole tape, so the comparison saw writes.
      case member "writes" (member "haskell" (member "summary" report)) of
        Int writes -> writes `shouldSatisfy` (> 0)
        other -> expectationFailure ("no write count: " <> show other)
  describe "the comparison fails when a side differs" $ do
    it "on a History byte, an unrecorded request and a failed step" $ withRoot $ \dir -> do
      run <- tierB dir "clean_green" Nothing
      (clean, _) <- compareRun run []
      clean `shouldBe` ExitSuccess
      -- An unrecorded request on the Haskell side.
      BS.appendFile (run.haskell </> "server.jsonl") "{\"body\": \"\", \"kind\": \"unrecorded\", \"method\": \"GET\", \"n\": 999, \"path\": \"/extra\", \"status\": 500, \"tape_seq\": null}\n"
      (status1, report1) <- compareRun run []
      status1 `shouldBe` ExitFailure 1
      render (member "problems" report1) `shouldContain` "unrecorded"
      -- A History byte.
      histories <- historyFiles (run.haskell </> "root")
      case histories of
        path : _ -> BS.appendFile path "\n"
        [] -> expectationFailure "no History file"
      (status2, report2) <- compareRun run []
      status2 `shouldBe` ExitFailure 1
      differences <- field @[Json] "differences" report2
      map (member "aspect") differences `shouldContain` [String "history"]
    it "on a tape the host cannot follow (an agent result missing)" $ withRoot $ \dir -> do
      run <- tierB dir "seeded_review_finding" Nothing
      -- The same tape without its agent results: the replay runner meets an
      -- unknown key, and the host goes elsewhere than the recording.
      let tape = dir </> "tape-without-agents"
      createDirectoryIfMissing True tape
      forM_ ["meta.json", "github.jsonl", "steps.jsonl", "publisher.jsonl"] $ \file ->
        copyFile (run.tape </> file) (tape </> file)
      BS.writeFile (tape </> "agents.jsonl") ""
      broken <- replayHaskell run.python' [] tape (dir </> "broken")
      (status, report) <- compareRun run {tape, haskell = broken} []
      status `shouldBe` ExitFailure 1
      render (member "problems" report) `shouldContain` "agents_unknown"
  describe "recorded failures (host_seams.raise_recorded, differential)" $
    it "raise the same exceptions, and the same records are refused" $ withRoot $ \dir -> do
      interpreter <- upstreamPythonExecutable "hamsterdan"
      BS.writeFile (dir </> "failures.jsonl") (TE.encodeUtf8 (mconcat [line <> "\n" | line <- failures]))
      out <- script interpreter "raise_check.py" [dir </> "failures.jsonl"]
      python <- forM (BC.lines out) $ either (fail . show) (pure . canonical) . loadsBytes
      haskell <- forM failures $ \line -> either (fail . show) (fmap canonical . raised) (loadsBytes (TE.encodeUtf8 line))
      haskell `shouldBe` python

-- | Recorded @error@ members: every class the seams raise, records the
-- reference refuses (a missing member, an unknown category, a provider
-- detail outside its vocabulary) and other classes.
failures :: [Text]
failures =
  [ "{\"class\": \"RuntimeError\", \"reason\": \"boom\"}"
  , "{\"class\": \"ValueError\"}"
  , "{\"class\": \"OSError\", \"reason\": null}"
  , "{\"class\": \"Thing\", \"reason\": 3}"
  , "{\"class\": \"Thing\", \"reason\": \"caf\\u00e9\"}"
  , "{\"reason\": \"no class\"}"
  , "{\"class\": \"AgentProtocolError\", \"reason\": \"late\", \"canceled\": false, \"timed_out\": true, \"result_category\": \"runtime_lifecycle\", \"cleanup_category\": null}"
  , "{\"class\": \"AgentProtocolError\", \"reason\": \"gone\", \"canceled\": true, \"timed_out\": false, \"result_category\": null, \"cleanup_category\": \"cleanup_unverified\"}"
  , "{\"class\": \"AgentProtocolError\", \"reason\": \"half\", \"timed_out\": false, \"result_category\": null, \"cleanup_category\": null}"
  , "{\"class\": \"AgentProtocolError\", \"reason\": \"odd\", \"canceled\": false, \"timed_out\": false, \"result_category\": \"sideways\", \"cleanup_category\": null}"
  , "{\"class\": \"GitPublishError\", \"category\": \"boundary_unavailable\", \"reason\": \"down\"}"
  , "{\"class\": \"GitPublishError\", \"category\": \"nowhere\", \"reason\": \"down\"}"
  , "{\"class\": \"GitPublishError\", \"category\": \"correlation\"}"
  , "{\"class\": \"GitHubBoundaryError\", \"message\": \"refused\", \"failure_class\": \"payload_rejection\", \"provider_status\": 422, \"provider_detail\": \"bad\"}"
  , "{\"class\": \"GitHubObjectWriteError\", \"message\": \"write\", \"failure_class\": \"transport_ambiguity\", \"provider_status\": null, \"provider_detail\": \"none\"}"
  , "{\"class\": \"GitHubObjectWriteError\", \"message\": \"write\", \"failure_class\": \"transport_ambiguity\", \"provider_status\": null, \"provider_detail\": \"\"}"
  , "{\"class\": \"GitHubBoundaryError\", \"message\": \"m\", \"failure_class\": \"capability_denial\", \"provider_status\": 99, \"provider_detail\": \"none\"}"
  , "{\"class\": \"GitHubBoundaryError\", \"message\": \"m\", \"failure_class\": \"capability_denial\", \"provider_status\": 403, \"provider_detail\": \"Not.Allowed\"}"
  , "{\"class\": \"GitHubBoundaryError\", \"message\": \"refused\", \"failure_class\": \"payload_rejection\", \"provider_status\": 422}"
  ]

-- | What 'raiseRecorded' raised, as @raise_check.py@ describes it.
raised :: Json -> IO Json
raised failure = do
  outcome <- try @SomeException (raiseRecorded failure)
  pure . Object $ case outcome of
    Right () -> [("raised", Bool False)]
    Left problem
      | Just (_ :: TapeError) <- fromException problem -> [("refused", Bool True)]
      | Just (e :: AgentProtocolError) <- fromException problem ->
          [ ("class", String "AgentProtocolError")
          , ("str", String e.reason)
          , ("canceled", Bool e.canceled)
          , ("timed_out", Bool e.timedOut)
          , ("result_category", maybe Null Codec.dump e.resultCategory)
          , ("cleanup_category", maybe Null Codec.dump e.cleanupCategory)
          ]
      | Just (e :: GitPublishError) <- fromException problem ->
          [("class", String "GitPublishError"), ("str", String e.reason), ("category", String (categoryName e.category))]
      | Just (e :: GitHubBoundaryError) <- fromException problem ->
          [ ("class", String (if e.kind == ObjectWrite then "GitHubObjectWriteError" else "GitHubBoundaryError"))
          , ("str", String e.message)
          , ("failure_class", String (failureClassName e.failureClass))
          , ("provider_status", maybe Null (Int . toInteger) e.providerStatus)
          , ("provider_detail", String e.providerDetail)
          ]
      | Just (e :: RecordedError) <- fromException problem ->
          [("class", String "RuntimeError"), ("str", String (T.pack (displayException e)))]
      | otherwise -> [("unexpected", String (T.pack (displayException problem)))]
