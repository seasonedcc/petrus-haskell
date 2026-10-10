-- | ArtifactStore and Timeline (upstream @test_private_execution_substrate.py@
-- artifact/timeline/telemetry tests), plus differential fixtures generated
-- from the upstream implementation by
-- @test/fixtures/generate_substrate_fixtures.py@.
module SubstrateSpec (spec) where

import Control.Monad (forM_, void)
import Data.Bits ((.&.))
import Data.Char (digitToInt)
import Data.ByteString qualified as B
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime, picosecondsToDiffTime)
import Petrus.Json (Json (..), canonicalText, lookupMember, parseJson, pythonLoads)
import Petrus.Motus.Execution.Artifacts
import Petrus.Motus.Execution.Error
import Petrus.Motus.Execution.Timeline
import Support
import System.Directory (createDirectory, doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.Posix.Files (fileMode, getFileStatus)
import Test.Hspec

decodeLine :: B.ByteString -> Json
decodeLine bytes = either error id (parseJson pythonLoads bytes)

readLines :: FilePath -> IO [Json]
readLines path = map decodeLine . filter (not . B.null) . B.split 10 <$> B.readFile path

member :: Text -> Json -> Json
member key value = maybe (error ("missing " <> T.unpack key)) id (lookupMember key value)

canonical :: Json -> Text
canonical = either (error . show) id . canonicalText

modeOf :: FilePath -> IO Int
modeOf path = (\s -> fromIntegral (fileMode s .&. 0o777)) <$> getFileStatus path

dataFiles :: FilePath -> IO [FilePath]
dataFiles root = do
  tops <- listDirectory root
  concat <$> mapM (\top -> map ((root </> top) </>) . filter (T.isSuffixOf ".data" . T.pack) <$> listDirectory (root </> top)) tops

event :: UTCTime -> Text -> Text -> Int -> [(Text, Text)] -> [Text] -> [(Text, Json)] -> TimelineEvent
event observed identifier producer sequenceNumber correlation causes metadata =
  TimelineEvent
    { eventId = identifier
    , eventKind = "execution.finished"
    , eventSchemaVersion = 1
    , eventProducer = producer
    , eventProducerSequence = sequenceNumber
    , eventObservedAt = observed
    , eventPhase = "execute"
    , eventOutcome = "succeeded"
    , eventCorrelation = correlation
    , eventCausalRefs = causes
    , eventMetadata = metadata
    , eventRetentionPolicy = "short-lived"
    }

fixtureTimes :: [UTCTime]
fixtureTimes =
  [ UTCTime (fromGregorian 2026 10 10) (picosecondsToDiffTime (((12 * 60 + 34) * 60 + 56) * 1000000000000 + 123456000000))
  , UTCTime (fromGregorian 2026 1 2) (picosecondsToDiffTime (((3 * 60 + 4) * 60 + 5) * 1000000000000))
  , UTCTime (fromGregorian 999 12 31) (picosecondsToDiffTime (((23 * 60 + 59) * 60 + 59) * 1000000000000 + 1000000))
  ]

unhex :: String -> B.ByteString
unhex = B.pack . go
  where
    go (a : b : rest) = fromIntegral (digitToInt a * 16 + digitToInt b) : go rest
    go _ = []

objectMembers :: Json -> [(Text, Json)]
objectMembers = \case
  Object members -> members
  other -> error ("not an object: " <> show other)

spec :: Spec
spec = describe "execution substrate" $ do
  fixtures <- runIO (loadFixture "substrate_fixtures.json")

  describe "ArtifactStore" $ do
    it "is host-custodied, integrity-checked and provider-neutral (test_artifacts_are_host_custodied_integrity_checked_and_provider_neutral)" $ withTempDir $ \tmp -> do
      let root = tmp </> "artifacts"
          producer = ProducerCorrelation "operation" "local-process" "opaque"
      reference <- newArtifactStore root >>= \store -> putArtifact store "portable result" "text/plain" "evidence" producer
      (newArtifactStore root >>= (`readArtifact` reference)) `shouldReturn` "portable result"
      artifactProducer reference `shouldBe` producer
      let dataPath = root </> T.unpack (T.take 2 (artifactDigest reference)) </> (T.unpack (artifactDigest reference) <> ".data")
      modeOf dataPath `shouldReturn` 0o600
      B.writeFile dataPath "tampered result"
      store <- newArtifactStore root
      errorMatching (readArtifact store reference) ValueError "integrity"

    it "prunes the oldest blobs without removing current authority (test_artifact_retention_prunes_oldest_without_removing_current_authority)" $ withTempDir $ \tmp -> do
      store <- newArtifactStore (tmp </> "artifacts")
      let producer = ProducerCorrelation "operation" "provider" "lease"
      references <-
        mapM (\i -> putArtifact store (TE.encodeUtf8 ("artifact-" <> T.pack (show i))) "text/plain" "operational" producer) [0 :: Int .. 3]
      let newest = last references
      removed <- pruneArtifacts store 2 (Set.singleton (artifactDigest newest))
      length removed `shouldBe` 2
      readArtifact store newest `shouldReturn` "artifact-3"
      length <$> dataFiles (tmp </> "artifacts") `shouldReturn` 2

    it "validates puts, retention and deletion" $ withTempDir $ \tmp -> do
      store <- newArtifactStore (tmp </> "a" </> "b")
      let producer = ProducerCorrelation "op" "p" "l"
      putArtifact store "x" "" "r" producer
        `shouldThrowMessage` (ValueError, "artifact media type and retention class must be non-empty")
      pruneArtifacts store 0 Set.empty `shouldThrowMessage` (ValueError, "artifact retention must be a positive integer")
      reference <- putArtifact store "x" "text/plain" "r" producer
      again <- putArtifact store "x" "text/plain" "r" producer
      again `shouldBe` reference
      deleteArtifact store reference
      deleteArtifact store reference
      readArtifact store reference `shouldThrowKind` OSError

    it "writes metadata byte-identical to upstream (differential fixture)" $ withTempDir $ \tmp -> do
      store <- newArtifactStore (tmp </> "artifacts")
      forM_ (listField "artifacts" fixtures) $ \case_ -> do
        let bytes = unhex (T.unpack (textField "data_hex" case_))
            producer = case listField "producer" case_ of
              [String o, String p, String l] -> ProducerCorrelation o p l
              other -> error (show other)
        reference <- putArtifact store bytes (textField "media_type" case_) (textField "retention_class" case_) producer
        artifactDigest reference `shouldBe` textField "digest" case_
        let digest = T.unpack (artifactDigest reference)
        B.readFile (tmp </> "artifacts" </> take 2 digest </> (digest <> ".json"))
          `shouldReturn` TE.encodeUtf8 (textField "metadata" case_)

  describe "Timeline" $ do
    it "redacts recursively, correlates, and has no authority (test_timeline_redacts_recursively_correlates_and_has_no_authority)" $ withTempDir $ \tmp -> do
      store <- newArtifactStore (tmp </> "artifacts")
      reference <- putArtifact store "result" "text/plain" "result" (ProducerCorrelation "op" "docker" "id")
      let path = tmp </> "timeline.jsonl"
      timeline <- newTimeline path Nothing
      now <- getCurrentTime
      appendEvent timeline $
        event
          now
          "event"
          "worker"
          1
          [("operation_id", "op"), ("artifact_digest", artifactDigest reference)]
          ["cause"]
          [ ("nested", Object [("password", String "raw"), ("safe", String "visible")])
          , ("auth_headers", Object [("Authorization", String "Bearer raw")])
          ]
      [record] <- readLines path
      member "artifact_digest" (member "correlation" record) `shouldBe` String (artifactDigest reference)
      canonical (member "metadata" record)
        `shouldBe` canonical (Object [("auth_headers", String "[REDACTED]"), ("nested", Object [("password", String "[REDACTED]"), ("safe", String "visible")])])
      modeOf path `shouldReturn` 0o600
      deleteTimeline timeline
      doesFileExist path `shouldReturn` False
      readArtifact store reference `shouldReturn` "result"

    it "mints sequences across restart; retention is sink policy (test_timeline_mints_sequences_across_restart_and_retention_is_sink_policy)" $ withTempDir $ \tmp -> do
      let path = tmp </> "timeline.jsonl"
      timeline <- newTimeline path (Just 2)
      first <- observe timeline "environment.provisioned" (observeSpec "motus.worker-1" "provision" "ready" [("operation_id", "operation")])
      second <-
        observe timeline "agent.turn.completed" (observeSpec "application.agent-1" "turn" "completed" [("operation_id", "operation"), ("thread_id", "thread")])
      restarted <- newTimeline path (Just 2)
      third <-
        observe
          restarted
          "environment.destroyed"
          (observeSpec "motus.worker-1" "destroy" "completed" [("operation_id", "operation")])
            { observeCausalRefs = [eventId first, eventId second]
            }
      records <- readLines path
      map (member "event_kind") records `shouldBe` [String "agent.turn.completed", String "environment.destroyed"]
      eventProducerSequence third `shouldBe` 2
      member "causal_refs" (last records) `shouldBe` Array [String (eventId first), String (eventId second)]

    it "rejects out-of-order sequences, invalid envelopes and bad retention" $ withTempDir $ \tmp -> do
      newTimeline (tmp </> "x.jsonl") (Just 0) `shouldThrowMessage` (ValueError, "Timeline retention must be a positive integer or None")
      timeline <- newTimeline (tmp </> "nested" </> "t.jsonl") Nothing
      now <- getCurrentTime
      appendEvent timeline (event now "e" "worker" 2 [] [] [])
        `shouldThrowMessage` (ValueError, "Timeline producer 'worker' expected sequence 1, got 2")
      appendEvent timeline (event now "" "worker" 1 [] [] []) `shouldThrowMessage` (ValueError, "Timeline event has an invalid envelope")
      appendEvent timeline (event now "e" "worker" 1 [] [] []) {eventSchemaVersion = 2}
        `shouldThrowMessage` (ValueError, "Timeline event has an invalid envelope")
      appendEvent timeline (event now "e" "worker" 1 [] [] [])
      appendEvent timeline (event now "e2" "worker" 2 [] [] [])

    it "trims with hysteresis once retention reaches 100" $ withTempDir $ \tmp -> do
      let path = tmp </> "timeline.jsonl"
      timeline <- newTimeline path (Just 100)
      forM_ [1 :: Int .. 200] $ \_ -> void (observe timeline "tick" (observeSpec "p" "observe" "ok" []))
      length <$> readLines path `shouldReturn` 200
      void (observe timeline "tick" (observeSpec "p" "observe" "ok" []))
      records <- readLines path
      length records `shouldBe` 100
      member "producer_sequence" (last records) `shouldBe` Int 201
      modeOf path `shouldReturn` 0o600

    it "matches upstream key and value redaction (differential fixture)" $ do
      forM_ (listField "secret_keys" fixtures) $ \case_ ->
        (textField "key" case_, isSecretKey (textField "key" case_)) `shouldBe` (textField "key" case_, field "secret" case_ == Bool True)
      forM_ (listField "secret_values" fixtures) $ \case_ ->
        redactSecretValues (textField "value" case_) `shouldBe` textField "redacted" case_

    it "writes lines byte-identical to upstream (differential fixture)" $ withTempDir $ \tmp -> do
      forM_ (zip3 [0 :: Int ..] fixtureTimes (listField "events" fixtures)) $ \(index, observed, case_) -> do
        isoformat observed `shouldBe` textField "observed_at" case_
        let path = tmp </> ("timeline-" <> show index <> ".jsonl")
        timeline <- newTimeline path Nothing
        appendEvent timeline $
          event
            observed
            (textField "event_id" case_)
            "worker"
            1
            [("operation_id", "op"), ("token", "abc"), ("note", "Bearer xyz")]
            ["cause", "caf\233"]
            (objectMembers (field "metadata" case_))
        B.readFile path `shouldReturn` TE.encodeUtf8 (textField "line" case_)

    it "derives phases from event-kind suffixes" $
      forM_ (objectMembers (field "phases" fixtures)) $ \(kind, expected) -> String (phaseOf kind) `shouldBe` expected

  describe "TelemetryTimelineHandler" $ do
    it "builds one redacted, correlated, non-canonical stream (test_telemetry_handler_builds_one_redacted_correlated_noncanonical_stream)" $ withTempDir $ \tmp -> do
      let path = tmp </> "timeline.jsonl"
      timeline <- newTimeline path Nothing
      emitTelemetry (telemetryTimelineHandler timeline) $
        "{\"event\": \"impetus_worker_activity_finished\", \"instance\": \"instance-1\", \"occurrence\": 9, \"attempt\": \"attempt-1\", \"epoch\": 2, \"worker\": \"worker-1\", \"outcome\": \"completed\", \"authorization\": \"Bearer secret-value\", \"note\": \"credential sk-or-secretvalue must not survive\", \"ts\": 1}"
      [record] <- readLines path
      member "event_kind" record `shouldBe` String "impetus_worker_activity_finished"
      (member "phase" record, member "outcome" record) `shouldBe` (String "finish", String "completed")
      canonical (member "correlation" record)
        `shouldBe` canonical
          ( Object
              [ ("attempt", String "attempt-1")
              , ("epoch", String "2")
              , ("instance", String "instance-1")
              , ("occurrence", String "9")
              , ("worker", String "worker-1")
              ]
          )
      member "authorization" (member "metadata" record) `shouldBe` String "[REDACTED]"
      case member "note" (member "metadata" record) of
        String note -> note `shouldNotSatisfy` T.isInfixOf "secretvalue"
        other -> expectationFailure (show other)

    it "never lets a failing sink escape (test_telemetry_handler_failure_is_non_blocking)" $ withTempDir $ \tmp -> do
      let path = tmp </> "timeline.jsonl"
      timeline <- newTimeline path Nothing
      createDirectory path
      emitTelemetry (telemetryTimelineHandler timeline) "{\"event\":\"safe\"}"
      emitTelemetry (telemetryTimelineHandler timeline) "not json"

    it "mirrors telemetry exactly like upstream (differential fixture)" $ withTempDir $ \tmp ->
      forM_ (zip [0 :: Int ..] (listField "telemetry" fixtures)) $ \(index, case_) -> do
        let path = tmp </> ("telemetry-" <> show index <> ".jsonl")
        timeline <- newTimeline path Nothing
        emitTelemetry (telemetryTimelineHandler timeline) (textField "message" case_)
        exists <- doesFileExist path
        case field "record" case_ of
          Null -> exists `shouldBe` False
          expected -> do
            [record] <- readLines path
            let stripped = Object [(k, v) | (k, v) <- objectMembers record, k `notElem` ["event_id", "observed_at"]]
            isJust (lookupMember "event_id" record) `shouldBe` True
            canonical stripped `shouldBe` canonical expected

