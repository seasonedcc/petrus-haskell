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
-- comparison does fail when a side differs.
--
-- The reference environment is provisioned by @scripts/upstream-python@;
-- when it cannot be, these tests fail, never skip.
module TierBSpec (spec) where

import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Hamsterdan.E2E.Tape (list, member)
import Petrus.Json (Json (..))
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
      [text | Object fields <- list (member "differences" report2), Just (String text) <- [lookup "aspect" fields]]
        `shouldContain` ["history"]
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
