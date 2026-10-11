-- | @tests/unit/host/test_export.py@: the executable contracts of the
-- offline evidence exporter, case for case and name for name.
--
-- Two properties carry the package's promise and every case defends one:
-- nothing is dropped (a missing body, a turn with no transcript, a body no
-- operation claims are all reported, never silently omitted) and nothing
-- is invented or written back (History and raw deliveries travel byte for
-- byte, boards come from the production renderer, and the source state
-- directory is never modified); a raw record this PR's inbox never
-- admitted is counted and named, never copied.
module ExportSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.List (sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fixtures
import Hamsterdan.Export
import Petrus.Json (Json (..))
import System.Directory
  ( createDirectory
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (..), withFile)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "hamsterdan-export"

-- | @build(tmp_path, webhook_deliveries=..., **changes)@.
build :: FilePath -> [FilePath] -> Changes -> IO (FilePath, Report)
build tmp webhookDeliveries changes = do
  source <- stateDir tmp changes
  let out = tmp </> "package"
  report <-
    exportPackage
      ExportRequest
        { stateDir = T.pack source
        , out = T.pack out
        , repository
        , pullRequest
        , identity = []
        , webhookDeliveries = map T.pack webhookDeliveries
        }
  pure (out, report)

request :: FilePath -> FilePath -> ExportRequest
request source out =
  ExportRequest
    { stateDir = T.pack source
    , out = T.pack out
    , repository
    , pullRequest
    , identity = []
    , webhookDeliveries = []
    }

-- | @transcript(out, operation, attempt)@.
transcript :: FilePath -> Text -> Integer -> IO Json
transcript out operation attempt = do
  let stem = T.replace ":" "-" (agentOperationId operation attempt)
  loadJson <$> BS.readFile (out </> "transcripts" </> T.unpack stem <> ".json")

readText' :: FilePath -> IO Text
readText' path = TE.decodeUtf8 <$> BS.readFile path

numberAt :: [Text] -> Report -> Json
numberAt keys report = case keys of
  first : rest -> foldl (flip member) (report.numbers Map.! first) rest
  [] -> Null

anyGap :: (Text -> Bool) -> Report -> Bool
anyGap predicate report = any predicate report.gaps

sha256Hex :: BS.ByteString -> Text
sha256Hex = TE.decodeUtf8 . Base16.encode . SHA256.hash

instancePath :: FilePath -> FilePath
instancePath source = source </> "applications" </> show installation </> show repositoryId </> show pullRequest

-- | Every regular file below a directory, recursively.
filesBelow :: FilePath -> IO [FilePath]
filesBelow root = do
  names <- sort <$> listDirectory root
  fmap concat . forM names $ \name -> do
    let path = root </> name
    directory <- doesDirectoryExist path
    if directory then filesBelow path else pure [path]

-- | A JSON value with every object's members sorted: Python's dict
-- equality ignores member order.
normalized :: Json -> Json
normalized = \case
  Object members -> Object (sortOn fst [(k, normalized v) | (k, v) <- members])
  Array items -> Array (map normalized items)
  other -> other

textOf :: Json -> IO Text
textOf = \case
  String text -> pure text
  other -> fail ("not a string: " <> show other)

refusedWith :: Text -> Either EvidenceExportError a -> Bool
refusedWith fragment = \case
  Left (EvidenceExportError message) -> fragment `T.isInfixOf` message
  Right _ -> False

spec :: Spec
spec = describe "test_export" $ do
  describe "TestHistoryTravelsAsTheAuthority" $ do
    it "test_canonical_history_is_copied_byte_for_byte" . withTmp $ \tmp -> do
      source <- stateDir tmp defaults
      let out = tmp </> "package"
      _ <- exportPackage (request source out)
      original <- BS.readFile (instancePath source </> "history.jsonl")
      BS.readFile (out </> "history" </> "history.jsonl") `shouldReturn` original
      manifest <- loadJson <$> BS.readFile (out </> "MANIFEST.json")
      member "records" (member "history" manifest) `shouldBe` Int (toInteger (length history))
      member "sha256" (member "history" manifest) `shouldBe` String (sha256Hex original)

    it "test_the_index_names_every_record_once_in_file_order" . withTmp $ \tmp -> do
      (out, _) <- build tmp [] defaults
      index <- readText' (out </> "history" </> "index.md")
      let lines' = [line | line <- T.lines index, isDigits (T.strip (T.take 5 line))]
          isDigits t = not (T.null t) && T.all (`elem` ['0' .. '9']) t
      length lines' `shouldBe` length history
      map (T.takeWhile (/= ' ') . T.strip) lines' `shouldBe` map (T.pack . show) [1 .. length history]
      (lines' !! 2) `shouldSatisfy` (\l -> "ActivityRequested" `T.isInfixOf` l && "review_agent" `T.isInfixOf` l)

    it "test_a_record_kind_the_index_cannot_name_is_reported_not_hidden" . withTmp $ \tmp -> do
      let history' = history ++ [record "SomethingNewer" [("occurrence", Int 9), ("instant", Int 9), ("detail", String "x")]]
      (_, report) <- build tmp [] defaults {history = Just history'}
      report `shouldSatisfy` anyGap ("SomethingNewer" `T.isInfixOf`)
      readText' (tmp </> "package" </> "history" </> "index.md") >>= (`shouldSatisfy` T.isInfixOf "detail=x")

  describe "TestBoardHistory" $ do
    it "test_each_landed_dashboard_publication_becomes_one_numbered_board" . withTmp $ \tmp -> do
      (out, report) <- build tmp [] defaults
      boards <- sort . filter (\n -> take 1 n `elem` map pure ['0' .. '9'] && T.isSuffixOf ".md" (T.pack n)) <$> listDirectory (out </> "boards")
      boards `shouldBe` ["0001.md", "0002.md"]
      numberAt ["boards", "dash_landed"] report `shouldBe` Int 2

    it "test_a_board_is_the_production_render_of_its_entry_log" . withTmp $ \tmp -> do
      (out, _) <- build tmp [] defaults
      board <- readText' (out </> "boards" </> "0001.md")
      board `shouldSatisfy` T.isPrefixOf "## Hamsterdan summary \x2014 "
      board `shouldSatisfy` (\b -> "\x2705 success" `T.isInfixOf` b && "head h1 on base b1" `T.isInfixOf` b)

    it "test_a_publication_that_never_landed_produces_no_board" . withTmp $ \tmp -> do
      (out, _) <- build tmp [] defaults
      readText' (out </> "boards" </> "index.md") >>= (`shouldNotSatisfy` T.isInfixOf "d3")

  describe "TestTranscriptJoin" $ do
    it "test_the_join_key_is_the_digest_the_agent_runner_writes" $ do
      let expected = "pi:" <> sha256Hex (TE.encodeUtf8 (reviewOperation <> "\0" <> "2"))
      agentOperationId reviewOperation 2 `shouldBe` expected

    it "test_a_review_attempt_carries_its_request_and_its_response" . withTmp $ \tmp -> do
      (out, _) <- build tmp [] defaults
      document <- transcript out reviewOperation 1
      member "kind" document `shouldBe` String "review"
      member "history_occurrences" document `shouldBe` Array [Int 2]
      let inputs = member "history_activity_inputs" (member "request" document)
      case inputs of
        Array (first : _) -> member "attempt" (member "work" first) `shouldBe` Int 1
        other -> expectationFailure (show other)
      normalized (member "review_request" (member "request" document))
        `shouldBe` normalized (Object [("repository", String repository), ("head", String "h1")])
      member "body_present" (member "response" document) `shouldBe` Bool True
      member "output_text" (member "response" document) `shouldBe` String "output text"
      member "outcome" (member "pi_operation" document) `shouldBe` String "completed"
      sessionName <- textOf (member "session_jsonl" (member "response" document))
      BS.readFile (out </> "transcripts" </> T.unpack sessionName) `shouldReturn` "{\"role\":\"user\"}\n"

    it "test_an_operation_with_no_body_is_reported_as_missing_not_dropped" . withTmp $ \tmp -> do
      (out, report) <- build tmp [] defaults
      document <- transcript out reviewOperation 2
      member "body_present" (member "response" document) `shouldBe` Bool False
      member "history_occurrences" document `shouldBe` Array [Int 3]
      numberAt ["transcripts", "bodies_missing"] report `shouldBe` Int 1
      report `shouldSatisfy` anyGap ((reviewOperation <> " attempt 2") `T.isInfixOf`)
      readText' (out </> "README.md") >>= (`shouldSatisfy` T.isInfixOf (reviewOperation <> " attempt 2"))

    it "test_a_mutation_operation_joins_through_its_binding_scoped_name" . withTmp $ \tmp -> do
      (out, _) <- build tmp [] defaults
      document <- transcript out mutationOperation 1
      member "kind" document `shouldBe` String "mutation"
      member "attempt" document `shouldBe` Int 1
      member "body_present" (member "response" document) `shouldBe` Bool True

    it "test_two_requests_for_one_agent_turn_collapse_to_one_transcript" . withTmp $ \tmp -> do
      let gitGate r = case r of
            Object members -> lookup "activity" members == Just (String "git_gate")
            _ -> False
          repeated = case filter gitGate history of
            Object members : rest ->
              Object [(k, case k of "occurrence" -> Int 8; "instant" -> Int 9; _ -> v) | (k, v) <- members] : rest
            other -> other
      (out, report) <- build tmp [] defaults {history = Just (history ++ repeated)}
      document <- transcript out mutationOperation 1
      member "history_occurrences" document `shouldBe` Array [Int 4, Int 8]
      case member "history_activity_inputs" (member "request" document) of
        Array inputs -> length inputs `shouldBe` 2
        other -> expectationFailure (show other)
      numberAt ["transcripts", "operations"] report `shouldBe` Int 4

    it "test_a_conversation_operation_absent_from_history_is_still_exported" . withTmp $ \tmp -> do
      (out, _) <- build tmp [] defaults
      document <- transcript out conversationOperation 1
      member "origin" document `shouldBe` String "agent-routes"
      member "history_occurrences" document `shouldBe` Array []
      member "kind" document `shouldBe` String "conversation"
      member "body_present" (member "response" document) `shouldBe` Bool True

    it "test_a_body_no_operation_claims_is_exported_as_unattributed" . withTmp $ \tmp -> do
      let orphan = "pi:" <> T.replicate 64 "a"
      (out, report) <- build tmp [] defaults {bodies = [agentOperationId reviewOperation 1, orphan]}
      document <- loadJson <$> BS.readFile (out </> "transcripts" </> T.unpack (T.replace ":" "-" orphan) <> ".json")
      member "kind" document `shouldBe` String "unattributed"
      member "body_present" (member "response" document) `shouldBe` Bool True
      report `shouldSatisfy` anyGap (orphan `T.isInfixOf`)

    it "test_the_index_lists_every_operation_with_its_join_outcome" . withTmp $ \tmp -> do
      (out, _) <- build tmp [] defaults
      index <- loadJson <$> BS.readFile (out </> "transcripts" </> "index.json")
      case index of
        Array entries -> do
          Set.fromList [l | entry <- entries, String l <- [member "logical_operation" entry]]
            `shouldBe` Set.fromList [reviewOperation, mutationOperation, conversationOperation]
          length [() | entry <- entries, member "body_present" entry == Bool True] `shouldBe` 3
        other -> expectationFailure (show other)

  describe "TestWebhookInbox" $ do
    it "test_every_inbox_row_travels_with_its_parsed_observation" . withTmp $ \tmp -> do
      (out, report) <- build tmp [] defaults
      rows <- map (loadJson . TE.encodeUtf8) . T.lines <$> readText' (out </> "webhooks" </> "inbox.jsonl")
      map (member "delivery_id") rows `shouldBe` [String admittedDelivery, String secondDelivery]
      map (member "action" . member "observation") (take 1 rows) `shouldBe` [String "opened"]
      normalized (report.numbers Map.! "webhooks")
        `shouldBe` normalized (Object [("rows", Int 2), ("by_event", Object [("issue_comment", Int 1), ("pull_request", Int 1)])])

    it "test_the_readme_says_the_inbox_holds_no_raw_request_body" . withTmp $ \tmp -> do
      (out, report) <- build tmp [] defaults
      report `shouldSatisfy` anyGap ("raw request body" `T.isInfixOf`)
      readText' (out </> "README.md") >>= (`shouldSatisfy` T.isInfixOf "raw request body")

  describe "TestRawWebhookDeliveries" $ do
    let admittedFile = admittedDelivery <> "-pull_request.json"
        admittedRecord = (admittedFile, rawDelivery admittedDelivery "pull_request" "opened")
    it "test_a_raw_record_the_inbox_admitted_is_copied_byte_identically" . withTmp $ \tmp -> do
      source <- deliveries tmp "deliveries" [admittedRecord]
      (out, report) <- build tmp [source] defaults
      original <- BS.readFile (source </> T.unpack admittedFile)
      BS.readFile (out </> "webhooks" </> "deliveries" </> T.unpack admittedFile) `shouldReturn` original
      index <- loadJson <$> BS.readFile (out </> "webhooks" </> "deliveries" </> "index.json")
      case index of
        Array entries -> case [e | e <- entries, member "delivery_id" e == String admittedDelivery] of
          entry : _ -> do
            member "sha256" entry `shouldBe` String (sha256Hex original)
            member "bytes" entry `shouldBe` Int (toInteger (BS.length original))
          [] -> expectationFailure "no index entry"
        other -> expectationFailure (show other)
      numberAt ["raw_deliveries", "copied"] report `shouldBe` Int 1

    it "test_an_inbox_row_with_no_raw_record_is_reported_as_a_gap" . withTmp $ \tmp -> do
      source <- deliveries tmp "deliveries" [admittedRecord]
      (out, report) <- build tmp [source] defaults
      numberAt ["raw_deliveries", "inbox_rows_without_raw"] report `shouldBe` Array [String secondDelivery]
      report `shouldSatisfy` anyGap (\g -> secondDelivery `T.isInfixOf` g && "issue_comment" `T.isInfixOf` g)
      readText' (out </> "README.md") >>= (`shouldSatisfy` T.isInfixOf secondDelivery)

    it "test_a_raw_record_for_another_pull_request_is_counted_never_copied" . withTmp $ \tmp -> do
      let otherFile = otherPrDelivery <> "-workflow_run.json"
      source <- deliveries tmp "deliveries" [admittedRecord, (otherFile, rawDelivery otherPrDelivery "workflow_run" "completed")]
      (out, report) <- build tmp [source] defaults
      numberAt ["raw_deliveries", "out_of_scope_files"] report `shouldBe` Int 1
      numberAt ["raw_deliveries", "files_seen"] report `shouldBe` Int 2
      doesFileExist (out </> "webhooks" </> "deliveries" </> T.unpack otherFile) `shouldReturn` False
      listing <- loadJson <$> BS.readFile (out </> "webhooks" </> "out-of-scope-deliveries.json")
      case member "files" listing of
        Array files -> map (member "delivery_id") files `shouldBe` [String otherPrDelivery]
        other -> expectationFailure (show other)
      index <- BS.readFile (out </> "webhooks" </> "deliveries" </> "index.json")
      index `shouldNotSatisfy` BS.isInfixOf (TE.encodeUtf8 otherPrDelivery)

    it "test_a_redelivered_guid_travels_as_both_of_its_records" . withTmp $ \tmp -> do
      let redelivered = admittedDelivery <> "-pull_request-original-99.json"
      source <- deliveries tmp "deliveries" [admittedRecord, (redelivered, rawDelivery admittedDelivery "pull_request" "opened")]
      (out, report) <- build tmp [source] defaults
      numberAt ["raw_deliveries", "copied"] report `shouldBe` Int 2
      numberAt ["raw_deliveries", "matched_deliveries"] report `shouldBe` Int 1
      doesFileExist (out </> "webhooks" </> "deliveries" </> T.unpack redelivered) `shouldReturn` True

    it "test_a_file_that_is_not_a_delivery_record_is_named_not_guessed_at" . withTmp $ \tmp -> do
      source <-
        deliveries tmp "deliveries" [admittedRecord, ("_deliveries-index.json", Array [Object [("guid", String admittedDelivery)]])]
      (_, report) <- build tmp [source] defaults
      numberAt ["raw_deliveries", "unrecognized_files"] report
        `shouldBe` Array [String (T.pack (source </> "_deliveries-index.json"))]
      report `shouldSatisfy` anyGap ("_deliveries-index.json" `T.isInfixOf`)

    it "test_omitting_the_flag_is_stated_in_the_manifest_and_the_readme" . withTmp $ \tmp -> do
      (out, report) <- build tmp [] defaults
      manifest <- loadJson <$> BS.readFile (out </> "MANIFEST.json")
      normalized (member "raw_deliveries" manifest)
        `shouldBe` normalized (Object [("supplied", Bool False), ("directories", Array []), ("copied", Int 0)])
      doesDirectoryExist (out </> "webhooks" </> "deliveries") `shouldReturn` False
      readText' (out </> "README.md") >>= (`shouldSatisfy` T.isInfixOf "no raw GitHub delivery record")
      report `shouldSatisfy` anyGap ("no --webhook-deliveries directory was supplied" `T.isInfixOf`)

    it "test_a_missing_delivery_directory_refuses_instead_of_reporting_zero" . withTmp $ \tmp -> do
      source <- stateDir tmp defaults
      result <- try (exportPackage (request source (tmp </> "package")) {webhookDeliveries = [T.pack (tmp </> "absent")]})
      result `shouldSatisfy` refusedWith "does not exist"

  describe "TestSessionTranscriptCoverage" $ do
    it "test_a_completed_turn_exports_its_full_session_transcript" . withTmp $ \tmp -> do
      (out, report) <- build tmp [] defaults
      document <- transcript out reviewOperation 1
      member "coverage" document `shouldBe` String "session_exported"
      sessionName <- textOf (member "session_jsonl" (member "response" document))
      session <- BS.readFile (out </> "transcripts" </> T.unpack sessionName)
      session `shouldBe` "{\"role\":\"user\"}\n"
      member "session_jsonl_bytes" (member "response" document) `shouldBe` Int (toInteger (BS.length session))
      numberAt ["transcripts", "session_jsonl_bytes"] report `shouldBe` Int (3 * toInteger (BS.length "{\"role\":\"user\"}\n"))

    it "test_a_body_without_a_session_is_reported_with_the_reason_not_dropped" . withTmp $ \tmp -> do
      let cancelled = agentOperationId reviewOperation 1
      (out, report) <- build tmp [] defaults {sessionless = [cancelled]}
      document <- transcript out reviewOperation 1
      member "body_present" (member "response" document) `shouldBe` Bool True
      member "session_present" (member "response" document) `shouldBe` Bool False
      member "coverage" document `shouldBe` String "body_without_session"
      case member "coverage_reason" document of
        String reason -> reason `shouldSatisfy` T.isInfixOf "cancelled before any transcript line was appended"
        other -> expectationFailure (show other)
      numberAt ["transcripts", "coverage", "body_without_session"] report `shouldBe` Int 1
      report `shouldSatisfy` anyGap (\g -> "has a body but no session transcript" `T.isInfixOf` g && cancelled `T.isInfixOf` g)
      readText' (out </> "README.md") >>= (`shouldSatisfy` T.isInfixOf cancelled)

    it "test_a_deferred_round_with_neither_names_the_deferral_as_its_reason" . withTmp $ \tmp -> do
      (out, report) <- build tmp [] defaults
      document <- transcript out reviewOperation 2
      member "coverage" document `shouldBe` String "no_body_no_session"
      member "history_terminals" document `shouldBe` Array [String "RoundDeferred"]
      case member "coverage_reason" document of
        String reason -> reason `shouldSatisfy` T.isInfixOf "deferred before the agent runtime stored a body"
        other -> expectationFailure (show other)
      report `shouldSatisfy` anyGap ("RoundDeferred" `T.isInfixOf`)

    it "test_an_absence_history_cannot_explain_says_so_rather_than_inventing_one" . withTmp $ \tmp -> do
      let deferred r = case r of
            Object members -> case lookup "result" members of
              Just (Object result) -> lookup "$variant" result == Just (String "RoundDeferred")
              _ -> False
            _ -> False
      (out, _) <- build tmp [] defaults {history = Just (filter (not . deferred) history)}
      document <- transcript out reviewOperation 2
      member "coverage" document `shouldBe` String "no_body_no_session"
      case member "coverage_reason" document of
        String reason -> reason `shouldSatisfy` T.isInfixOf "History does not say why"
        other -> expectationFailure (show other)

    it "test_the_coverage_classes_account_for_every_operation_exactly_once" . withTmp $ \tmp -> do
      (out, report) <- build tmp [] defaults {sessionless = [agentOperationId mutationOperation 1]}
      let coverage = numberAt ["transcripts", "coverage"] report
      normalized coverage
        `shouldBe` normalized (Object [("session_exported", Int 2), ("body_without_session", Int 1), ("no_body_no_session", Int 1)])
      numberAt ["transcripts", "operations"] report `shouldBe` Int 4
      index <- loadJson <$> BS.readFile (out </> "transcripts" </> "index.json")
      case index of
        Array entries -> length [() | e <- entries, member "session_present" e == Bool True] `shouldBe` 2
        other -> expectationFailure (show other)

  describe "TestMissingPiecesAreNamed" $ do
    let stores =
          [ ("bodies", "bodies.sqlite3")
          , ("webhooks", "webhooks.sqlite3")
          , ("agent-routes", "agent-routes.sqlite3")
          , ("review-requests", "review-requests.sqlite3")
          ]
    mapM_
      ( \(store, phrase) ->
          it ("test_an_absent_store_is_named_in_the_readme[" <> T.unpack store <> "-" <> T.unpack phrase <> "]") . withTmp $ \tmp -> do
            (out, report) <- build tmp [] defaults {omit = [store]}
            report `shouldSatisfy` anyGap (phrase `T.isInfixOf`)
            readText' (out </> "README.md") >>= (`shouldSatisfy` T.isInfixOf phrase)
            doesFileExist (out </> "history" </> "history.jsonl") `shouldReturn` True
      )
      stores

    it "test_an_absent_bodies_store_still_lists_every_history_operation" . withTmp $ \tmp -> do
      (out, report) <- build tmp [] defaults {omit = ["bodies"]}
      numberAt ["transcripts", "bodies_joined"] report `shouldBe` Int 0
      document <- transcript out reviewOperation 1
      member "body_present" (member "response" document) `shouldBe` Bool False

    it "test_the_absent_run_identity_is_reported_against_the_done_condition" . withTmp $ \tmp -> do
      (_, report) <- build tmp [] defaults
      report `shouldSatisfy` anyGap ("run-identity" `T.isInfixOf`)
      numberAt ["identity", "files"] report `shouldBe` Array [String "binding.json"]

    it "test_a_supplied_identity_file_travels_and_clears_the_gap" . withTmp $ \tmp -> do
      let pins = tmp </> "pins.md"
      BS.writeFile pins "petrus @ 4e5c2500\nimage sha-7df44260\n"
      source <- stateDir tmp defaults
      let out = tmp </> "package"
      report <- exportPackage (request source out) {identity = [T.pack pins]}
      readText' (out </> "identity" </> "pins.md") >>= (`shouldSatisfy` T.isPrefixOf "petrus @")
      report `shouldNotSatisfy` anyGap ("run-identity" `T.isInfixOf`)

  describe "TestPackageBoundaries" $ do
    it "test_a_credential_named_file_is_excluded_and_listed" . withTmp $ \tmp -> do
      source <- stateDir tmp defaults
      BS.writeFile (source </> "webhook-secret") "never-copied"
      let secret = tmp </> "hamsterdan.env"
      BS.writeFile secret "HAMSTERDAN_PI_API_KEY=never-copied"
      let out = tmp </> "package"
      report <- exportPackage (request source out) {identity = [T.pack secret]}
      doesFileExist (out </> "identity" </> "hamsterdan.env") `shouldReturn` False
      case numberAt ["identity", "excluded_by_name"] report of
        Array names -> names `shouldContain` [String "webhook-secret"]
        other -> expectationFailure (show other)
      readText' (out </> "README.md") >>= (`shouldNotSatisfy` T.isInfixOf "never-copied")
      copied <- filesBelow out >>= mapM BS.readFile
      BS.concat copied `shouldNotSatisfy` BS.isInfixOf "never-copied"

    it "test_the_source_state_directory_is_never_written_to" . withTmp $ \tmp -> do
      source <- stateDir tmp defaults
      let digests = filesBelow source >>= mapM (\p -> (p,) . sha256Hex <$> BS.readFile p)
      earlier <- digests
      _ <- exportPackage (request source (tmp </> "package"))
      digests `shouldReturn` earlier

    it "test_an_unknown_pull_request_refuses_instead_of_writing_an_empty_package" . withTmp $ \tmp -> do
      source <- stateDir tmp defaults
      let out = tmp </> "package"
      result <- try (exportPackage (request source out) {pullRequest = 999})
      result `shouldSatisfy` refusedWith "expected exactly one"
      doesDirectoryExist out `shouldReturn` False

    it "test_a_populated_output_directory_is_refused" . withTmp $ \tmp -> do
      source <- stateDir tmp defaults
      let out = tmp </> "package"
      createDirectory out
      BS.writeFile (out </> "README.md") "earlier package"
      result <- try (exportPackage (request source out))
      result `shouldSatisfy` refusedWith "not empty"
      BS.readFile (out </> "README.md") `shouldReturn` "earlier package"

  describe "TestCommandLine" $ do
    it "test_a_successful_run_prints_every_gap_and_the_package_path" . withTmp $ \tmp -> do
      source <- stateDir tmp defaults
      let out = tmp </> "package"
      (code, printed, problems) <-
        captured tmp ["--state-dir", T.pack source, "--out", T.pack out, "--repository", repository, "--pull-request", T.pack (show pullRequest)]
      code `shouldBe` ExitSuccess
      manifest <- loadJson <$> BS.readFile (out </> "MANIFEST.json")
      Int (toInteger (T.count "GAP: " problems)) `shouldBe` member "gaps" manifest
      printed `shouldSatisfy` T.isInfixOf ("package written to " <> T.pack out)

    it "test_a_refused_export_exits_nonzero_with_the_reason" . withTmp $ \tmp -> do
      (code, _, problems) <-
        captured
          tmp
          [ "--state-dir"
          , T.pack (tmp </> "absent")
          , "--out"
          , T.pack (tmp </> "package")
          , "--repository"
          , repository
          , "--pull-request"
          , T.pack (show pullRequest)
          ]
      code `shouldBe` ExitFailure 2
      problems `shouldSatisfy` T.isInfixOf "export failed:"

-- | @main(argv)@ with @capsys@: the exit status and both streams.
captured :: FilePath -> [Text] -> IO (ExitCode, Text, Text)
captured tmp argv = do
  let outPath = tmp </> "captured-stdout"
      errPath = tmp </> "captured-stderr"
  code <-
    withFile outPath WriteMode $ \output ->
      withFile errPath WriteMode $ \errors ->
        runExport ExportEnvironment {environment = Map.fromList [("COLUMNS", "80")], output, errors} argv
  (,,) code <$> readText' outPath <*> readText' errPath
