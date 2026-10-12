{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Cross-runtime replay of the reference's 51 world fixtures (and the
-- Engine-backed replay mutations of @tests/dst/test_world.py@) against
-- door transcripts recorded from the Python Engine profiles by
-- @scripts/transcript_vectors.py@: the Haskell interpreter must make
-- exactly the recorded door calls, with exactly the recorded arguments and
-- context-service results, and end with the reference's replay result
-- bytes or error.
module Spec.Transcript (spec) where

import Control.Monad (forM_)
import Data.Text qualified as T
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
import Transcript
import Spec.Support
import Test.Hspec

transcripts :: IO Json
transcripts = readJson (dataFile "transcripts.json")

decoded :: Json -> IO (Transcript, AnyArtifact)
decoded vector = do
  transcript <- either (fail . T.unpack) pure (pTranscript vector)
  artifact <- either (fail . show) pure (decodeArtifact (textBytes (memberText "artifact" vector)))
  pure (transcript, artifact)

-- | Replay one recorded vector and compare everything.
replayed :: Json -> Expectation
replayed vector = do
  (transcript, artifact) <- decoded vector
  (outcome, divergences) <- replayTranscript transcript artifact
  let actual = canonText (replayJson outcome)
  (memberText "name" vector, divergences, actual) `shouldBe` (memberText "name" vector, [], canonText (member "outcome" vector))

spec :: Spec
spec = describe "Engine fixture replays (Python-recorded door transcripts)" $ do
  it "replays all 51 world fixtures with the reference's calls and result bytes" $ do
    fixtures <- memberList "fixtures" <$> transcripts
    length fixtures `shouldBe` 51
    length (filter (T.isPrefixOf "joined-" . memberText "name") fixtures) `shouldBe` 33
    forM_ fixtures replayed

  it "fails closed on each replay mutation exactly as the reference does" $ do
    mutations <- memberList "mutations" <$> transcripts
    map (memberText "name") mutations
      `shouldBe` [ "changed-failure-location"
                 , "checker-version-mismatch"
                 , "journal-digest-mismatch"
                 , "checker-unregistered"
                 , "changed-seed-provenance"
                 ]
    forM_ mutations replayed

  it "reports a divergence when the interpreter's calls differ from the transcript" $ do
    fixtures <- memberList "fixtures" <$> transcripts
    let target = "resource-bounded-recovery-world-v4.json"
    vector <- case filter ((== target) . memberText "name") fixtures of
      v : _ -> pure v
      [] -> fail "missing fixture"
    (transcript, artifact) <- decoded vector
    let tampered = case transcript.calls of
          first : rest -> transcript {calls = rest <> [first]}
          [] -> transcript
    (outcome, divergences) <- replayTranscript tampered artifact
    divergences `shouldSatisfy` (not . null)
    either failureClass (const "pass") outcome `shouldBe` "TranscriptDivergence"
