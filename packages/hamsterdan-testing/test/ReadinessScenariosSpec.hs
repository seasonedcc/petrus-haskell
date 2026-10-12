-- | @tests/integration/host/test_readiness_scenarios.py@: the eleven
-- deterministic readiness journeys, run through this host by
-- "Hamsterdan.Testing.Journeys", each with its upstream @assert_*@ checks
-- ported over the journey's @JourneyResult@ (as the plain JSON both
-- implementations print).
--
-- "journeys against the reference" runs each journey through the Python
-- host too (@differential/journeys_reference.py@, over the upstream test
-- module itself) and requires the same bytes from every pairing: the whole
-- journey in this host, and the journey split in half across two host
-- lifetimes on one state directory (Haskell then Haskell, Python then
-- Haskell, Haskell then Python). The comparison covers the whole
-- @JourneyResult@ (every GitHub call and request body, every comment and
-- review comment and their edits, the agent requests and results, the Git
-- reconciliations, publications, objects and compare-and-swap) and the
-- state directory (History, the host's databases, @agent-routes.sqlite3@,
-- every other file) as the reference reads it back, with only the Worker
-- claimant's random identity and the Local Dispatch wall-clock columns
-- normalized.
module ReadinessScenariosSpec (spec) where

import Control.Monad (forM_, unless)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.List (nub, sort)
import Data.Maybe (isJust, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Testing.Journeys hiding (Phase (..))
import Hamsterdan.Testing.Readiness
  ( AuthorityClaim (..)
  , AuthorityFacts (..)
  , CheckFacts (..)
  , CheckStatus (..)
  , CiFacts (..)
  , CiRecovery (..)
  , HumanFacts (..)
  , Lifecycle (..)
  , ReadinessDisposition (..)
  , ReadinessExpectation (..)
  , ReadinessFacts (..)
  , ReviewFacts (..)
  , ReviewStatus (..)
  , evaluate
  , humanFacts
  , readinessFacts
  )
import Petrus.Json (Json (..), compact, defaultDumps, dumps, dumpsText, parseJson, surrogateRefusingLoads)
import Petrus.Json.Encode (EncodeOptions (..))
import Petrus.TestSupport.Python (upstreamPythonExecutable)
import Petrus.TestSupport.Repo (repoRoot)
import System.Directory (canonicalizePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process.Typed (byteStringInput, proc, readProcess, setStdin)
import Test.Hspec

spec :: Spec
spec = do
  describe "tests/integration/host/test_readiness_scenarios.py" $ do
    it "test_clean_green_user_journey" $ withRoot $ \root -> do
      result <- runJourney CleanGreen root
      assertCleanGreen result
      (evaluate (cleanGreenModelFacts result)).disposition `shouldBe` Ready
    it "test_first_attempt_flake_user_journey" $ withRoot $ \root ->
      runJourney FirstAttemptFlake root >>= assertFirstAttemptFlake
    it "test_persistent_ci_regression_user_journey" $ withRoot $ \root ->
      runJourney PersistentCiRegression root >>= assertPersistentCiRegression
    it "test_seeded_review_finding_user_journey" $ withRoot $ \root ->
      runJourney SeededReviewFinding root >>= assertSeededReviewFinding
    it "test_conversational_change_user_journey" $ withRoot $ \root ->
      runJourney ConversationalChange root >>= assertConversationalChange
    it "test_agent_repair_user_journey" $ withRoot $ \root ->
      runJourney AgentRepair root >>= assertAgentRepair
    it "test_hero_review_user_journey" $ withRoot $ \root -> do
      first <- runJourney HeroReview (root </> "first")
      second <- runJourney HeroReview (root </> "second")
      assertHeroReview first
      assertHeroReview second
      element 2 (head' (reviews first)) `shouldBe` element 2 (head' (reviews second))
      findingOperations first `shouldBe` findingOperations second
    it "test_draft_ready_user_journey" $ withRoot $ \root ->
      runJourney DraftReady root >>= assertDraftReady
    it "test_stale_base_update_user_journey" $ withRoot $ \root ->
      runJourney StaleBaseUpdate root >>= assertStaleBaseUpdate
    it "test_true_conflict_resolution_user_journey" $ withRoot $ \root ->
      runJourney TrueConflictResolution root >>= assertTrueConflictResolution
    it "test_collaboration_approval_user_journey" $ withRoot $ \root ->
      runJourney CollaborationApproval root >>= assertCollaborationApproval

  describe "journeys against the reference" $
    forM_ [minBound .. maxBound] $ \journey -> do
      let name = T.unpack (journeyName journey)
          phases = length (phasesOf journey)
          half = max 1 (phases `div` 2)
      describe name . beforeAll (referenceJourney journey) $ do
        it "the whole journey" $ \expected -> withRoot $ \root -> do
          result <- runJourney journey root
          state <- referenceDump root
          sameJson (name <> ": result") (member "result" expected) result
          sameJson (name <> ": state") (member "state" expected) state
        it "Haskell then Haskell" $ \expected -> withRoot $ \root -> do
          first <- driveJourney journey root (0, half) Nothing
          second <- driveJourney journey root (half, phases) (Just (member "carry" first))
          state <- referenceDump root
          sameJson (name <> ": result") (member "result" expected) (member "result" second)
          sameJson (name <> ": state") (member "state" expected) state
        it "Python then Haskell" $ \expected -> withRoot $ \root -> do
          first <- referenceDrive journey root (0, half) Nothing
          second <- driveJourney journey root (half, phases) (Just (member "carry" first))
          state <- referenceDump root
          sameJson (name <> ": result") (member "result" expected) (member "result" second)
          sameJson (name <> ": state") (member "state" expected) state
        it "Haskell then Python" $ \expected -> withRoot $ \root -> do
          first <- driveJourney journey root (0, half) Nothing
          second <- referenceDrive journey root (half, phases) (Just (member "carry" first))
          state <- referenceDump root
          sameJson (name <> ": result") (member "result" expected) (member "result" second)
          sameJson (name <> ": state") (member "state" expected) state

withRoot :: (FilePath -> IO a) -> IO a
withRoot use = withSystemTempDirectory "hamsterdan-journey" (\dir -> canonicalizePath dir >>= use)

-- ---------------------------------------------------------------------------
-- The reference

reference :: [String] -> ByteString -> IO Json
reference arguments input = do
  executable <- upstreamPythonExecutable "hamsterdan"
  repo <- repoRoot
  let script = repo </> "packages" </> "hamsterdan-testing" </> "differential" </> "journeys_reference.py"
      config = setStdin (byteStringInput (BL.fromStrict input)) (proc executable (["-I", "-B", script] <> arguments))
  (status, out, err) <- readProcess config
  unless (status == ExitSuccess) $
    expectationFailure ("the reference journey driver failed: " <> BC.unpack (BL.toStrict err))
  -- The Petrus Worker reports each processed Activity on stdout; the
  -- driver's document is the last line.
  case reverse (filter (not . BC.null) (BC.lines (BL.toStrict out))) of
    line : _ -> case parseJson surrogateRefusingLoads line of
      Right value -> pure value
      Left problem -> expectationFailure ("unreadable reference output: " <> problem) >> pure Null
    [] -> expectationFailure "the reference journey driver printed nothing" >> pure Null

-- | @journeys_reference.py journey NAME ROOT@ in a fresh directory:
-- @{"result": …, "state": …}@.
referenceJourney :: Journey -> IO Json
referenceJourney journey = withRoot $ \root -> do
  document <- reference ["journey", T.unpack (journeyName journey), root] ""
  check "the reference reports a result" (member "comments" (member "result" document) /= Null)
  check "the reference reports the state" (member "agent-routes.sqlite3" (member "state" document) /= Null)
  pure document

referenceDrive :: Journey -> FilePath -> (Int, Int) -> Maybe Json -> IO Json
referenceDrive journey root (from, to) carry =
  reference ["drive", root] . either (error . show) id . dumps compact . Object $
    [ ("journey", String (journeyName journey))
    , ("phases", Array [Int (toInteger from), Int (toInteger to)])
    ]
      <> maybe [] (\value -> [("carry", value)]) carry

referenceDump :: FilePath -> IO Json
referenceDump root = reference ["dump", root] ""

-- | Equal JSON, reported as the first differing lines of the canonical
-- (sorted, indented) spelling.
sameJson :: String -> Json -> Json -> IO ()
sameJson label expected actual = do
  let lined value = T.lines (either (error . show) id (dumpsText defaultDumps {sortKeys = True, indent = Just 1, ensureAscii = False} value))
      left = lined expected
      right = lined actual
  unless (left == right) $ do
    let width = max (length left) (length right)
        pad xs = map Just xs <> replicate (width - length xs) Nothing
        differing = [(n, a, b) | (n, a, b) <- zip3 [1 :: Int ..] (pad left) (pad right), a /= b]
    expectationFailure
      ( label
          <> " differs from the reference at "
          <> show (length differing)
          <> " lines; first:\n"
          <> unlines [show n <> "\n  reference: " <> show a <> "\n  haskell:   " <> show b | (n, a, b) <- take 12 differing]
      )

-- ---------------------------------------------------------------------------
-- JSON access

member :: Text -> Json -> Json
member key = \case
  Object members -> maybe Null id (lookup key members)
  _ -> Null

(!) :: Json -> Text -> Json
value ! key = member key value

element :: Int -> Json -> Json
element index = \case
  Array values | (value : _) <- drop index values -> value
  _ -> Null

list :: Json -> [Json]
list = \case
  Array values -> values
  _ -> []

txt :: Json -> Text
txt = \case
  String value -> value
  Null -> "None"
  other -> canonical other

canonical :: Json -> Text
canonical value = either (error . show) id (dumpsText defaultDumps {sortKeys = True} value)

-- | Python equality of two plain values.
(===) :: Json -> Json -> Bool
a === b = canonical a == canonical b

head' :: [Json] -> Json
head' = maybe Null id . listToMaybe

check :: String -> Bool -> IO ()
check label ok = unless ok (expectationFailure label)

object :: [(Text, Json)] -> Json
object = Object

-- ---------------------------------------------------------------------------
-- The result's parts

runnerOf :: Json -> Json
runnerOf result = result ! "runner"

reviews, reviewResults, codeCalls, codeResults, conversationCalls, conversationResults :: Json -> [Json]
reviews result = list (runnerOf result ! "reviews")
reviewResults result = list (runnerOf result ! "review_results")
codeCalls result = list (runnerOf result ! "code_calls")
codeResults result = list (runnerOf result ! "code_results")
conversationCalls result = list (runnerOf result ! "conversation_calls")
conversationResults result = list (runnerOf result ! "conversation_results")

codes, conversations :: Json -> Json
codes result = runnerOf result ! "codes"
conversations result = runnerOf result ! "conversations"

comments, reviewComments, everyComment :: Json -> [Json]
comments result = list (result ! "comments")
reviewComments result = list (result ! "review_comments")
everyComment result = comments result <> reviewComments result

bodyOf :: Json -> Text
bodyOf item = txt (item ! "body")

marked :: Text -> [Json] -> [Json]
marked marker = filter ((marker `T.isInfixOf`) . bodyOf)

dashboardMarker, readinessMarker, findingMarker, rerunMarker :: Text
dashboardMarker = "<!-- hamsterdan:dashboard -->"
readinessMarker = "<!-- hamsterdan:readiness "
findingMarker = "<!-- hamsterdan:finding "
rerunMarker = "<!-- hamsterdan-rerun "

calls :: Json -> [(Text, Text)]
calls result = [(txt (element 0 c), txt (element 1 c)) | c <- list (result ! "provider_calls")]

callsIn :: Json -> [(Text, Text)]
callsIn value = [(txt (element 0 c), txt (element 1 c)) | c <- list value]

requests :: Json -> [(Text, Text, Text)]
requests result = [(txt (element 0 r), txt (element 1 r), txt (element 2 r)) | r <- list (result ! "provider_requests")]

writes :: Json -> [(Text, Text, Json, Text)]
writes result = [(txt (element 0 w), txt (element 1 w), element 2 w, txt (element 3 w)) | w <- list (result ! "provider_writes")]

followUpWrites :: Json -> [(Text, Text, Json, Text)]
followUpWrites result = drop (fromInteger (number (result ! "before_follow_up_write_count"))) (writes result)

number :: Json -> Integer
number = \case
  Int n -> n
  _ -> -1

providerState :: Json -> [Json]
providerState result = list (result ! "provider_state")

expectState :: Json -> (Text, Bool, Bool, Bool, Text, Text, Text) -> IO ()
expectState result (state, draft, merged, mergeable, mergeableState, headValue, baseValue) =
  Array (providerState result)
    `shouldBe` Array [String state, Bool draft, Bool merged, Bool mergeable, String mergeableState, String headValue, String baseValue]

fromBot :: Json -> Bool
fromBot item = (item ! "user") === object [("login", String bot)]

fromAuthor :: Json -> Bool
fromAuthor item = (item ! "user") === object [("login", String "author")]

canaries :: [Text]
canaries = [privateKey, webhookSecret, clientSecret, installationToken]

noCanaries :: Text -> IO ()
noCanaries encoded = check "no secret reaches agent work" (not (any (`T.isInfixOf` encoded) canaries))

assertPublicClone :: Json -> IO ()
assertPublicClone url = url `shouldBe` String "https://github.com/owner/repo.git"

-- | No forbidden fragment in any request path or body.
noForbiddenRequests :: [Text] -> Json -> IO ()
noForbiddenRequests forbidden result =
  check
    "no forbidden provider request"
    (not (or [fragment `T.isInfixOf` path || fragment `T.isInfixOf` body | (_, path, body) <- requests result, fragment <- forbidden]))

forbiddenWithRerun, forbiddenWithoutRerun :: [Text]
forbiddenWithRerun = ["/git/blobs", "/git/trees", "/git/commits", "/git/refs", "/merge", "/rerun", "updateRefs"]
forbiddenWithoutRerun = ["/git/blobs", "/git/trees", "/git/commits", "/git/refs", "/merge", "updateRefs"]

quiescent :: Json -> IO ()
quiescent result = do
  Array (comments result) `shouldBe` (result ! "quiescent_comments")
  Int (toInteger (length (reviews result))) `shouldBe` (result ! "quiescent_review_count")

-- | @(run_id, run_attempt, run_conclusion, rerun_requests)@.
runFacts :: Json -> [Json]
runFacts result = [result ! "run_id", result ! "run_attempt", result ! "run_conclusion", result ! "rerun_requests"]

-- | @(run_attempt, run_conclusion, rerun_requests)@.
attemptFacts :: Json -> [Json]
attemptFacts result = [result ! "run_attempt", result ! "run_conclusion", result ! "rerun_requests"]

isDigest :: Text -> Bool
isDigest value = T.length value == 64 && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) value

-- | @re.fullmatch(rf"<!-- hamsterdan-rerun run=101 head={head} operation=([^ >]+) -->", body)@.
rerunOperation :: Text -> Text -> Maybe Text
rerunOperation headValue body = do
  rest <- T.stripPrefix ("<!-- hamsterdan-rerun run=101 head=" <> headValue <> " operation=") body
  operation <- T.stripSuffix " -->" rest
  if T.null operation || T.any (`elem` [' ', '>']) operation then Nothing else Just operation

-- | @re.search(r"<!-- hamsterdan:finding operation=([^ >]+) head=([^ >]+) -->", body)@.
findingMarkerOf :: Text -> Maybe (Text, Text)
findingMarkerOf body = listToMaybe (mapMaybe at (T.breakOnAll prefix body))
  where
    prefix = "<!-- hamsterdan:finding operation="
    at (_, rest) = do
      let afterPrefix = T.drop (T.length prefix) rest
          (operation, afterOperation) = T.break (`elem` [' ', '>']) afterPrefix
      afterHead <- T.stripPrefix " head=" afterOperation
      let (headValue, afterHeadValue) = T.break (`elem` [' ', '>']) afterHead
      if T.null operation || T.null headValue || not (" -->" `T.isPrefixOf` afterHeadValue)
        then Nothing
        else Just (operation, headValue)

-- | @ReviewResult(...)@ as its plain dump.
reviewResultJson :: Json -> Text -> Text -> Text -> [Json] -> [Json] -> Json
reviewResultJson epoch headValue baseValue status findings lineage =
  object
    [ ("repository", String "owner/repo")
    , ("pull_request", Int 7)
    , ("epoch", epoch)
    , ("head", String headValue)
    , ("base", String baseValue)
    , ("status", String status)
    , ("findings", Array findings)
    , ("lineage", Array lineage)
    ]

-- | @CodingResult(...)@ as its plain dump.
codingResultJson :: Text -> Json -> Text -> Text -> Json -> Text -> Text -> [Text] -> Text -> Text -> Json
codingResultJson kind epoch headValue baseValue ref reproduction diff changed command message =
  object
    [ ("kind", String kind)
    , ("repository", String "owner/repo")
    , ("pull_request", Int 7)
    , ("epoch", epoch)
    , ("head", String headValue)
    , ("base", String baseValue)
    , ("ref", ref)
    , ("status", String "changed")
    , ("reproduction_status", String reproduction)
    , ("diff", String diff)
    , ("changed_files", Array (map String changed))
    , ("validation_evidence", Array [object [("command", String command), ("outcome", String "passed")]])
    , ("proposed_commit_message", String message)
    ]

blockingFindingJson :: Json
blockingFindingJson = object blockingFinding

-- | @(item["id"], item["head"], item["attempt"], item["status"], item["conclusion"])@.
actionFacts :: Json -> [Json]
actionFacts item = [item ! "id", item ! "head", item ! "attempt", item ! "status", item ! "conclusion"]

-- | The single element of a list, or a failure.
single :: String -> [a] -> IO a
single label = \case
  [one] -> pure one
  other -> expectationFailure (label <> ": expected exactly one, got " <> show (length other)) >> error label

-- ---------------------------------------------------------------------------
-- The model facts

-- | @clean_green_model_facts(result)@.
cleanGreenModelFacts :: Json -> ReadinessFacts
cleanGreenModelFacts result =
  (readinessFacts "github:44:31:pr:7" (AuthorityFacts 1 (Just authority) authority))
    { admittedObservations = ["initial-pull-request-delivery"]
    , ci = CiFacts headValue ["build"] [CheckFacts "build" (if result ! "run_conclusion" == String "success" then Success else Failure)] RecoveryNone
    , review = ReviewFacts headValue (if txt (head' (reviewResults result) ! "status") == "blocking" then ReviewBlocking else ReviewClear) []
    , human = humanFacts {approvals = 1, requiredApprovals = 1}
    }
  where
    state = providerState result
    flag index = element index (Array state) == Bool True
    headValue = txt (element 5 (Array state))
    lifecycle
      | flag 2 = Merged
      | flag 1 = Draft
      | element 0 (Array state) == String "closed" = Closed
      | otherwise = Active
    authority =
      AuthorityClaim
        { installation = 44
        , repository = 31
        , pullRequest = 7
        , head = headValue
        , base = txt (element 6 (Array state))
        , policy = "parity-policy"
        , lifecycle
        , strictBase = True
        , baseCurrent = True
        , mergeable = flag 3
        }

-- ---------------------------------------------------------------------------
-- The upstream checks

assertClearReview :: Json -> IO ()
assertClearReview result = do
  length (reviews result) `shouldBe` 1
  let entry = head' (reviews result)
      url = element 0 entry
      request = element 1 entry
  [request ! "repository", request ! "pull_request", request ! "head", request ! "base"]
    `shouldBe` [String "owner/repo", Int 7, String headSha, String baseSha]
  check "the one clear review result" (Array (reviewResults result) === Array [reviewResultJson (request ! "epoch") headSha baseSha "clear" [] []])
  check "an operation, attempt 1" (txt (element 2 entry) /= "" && element 3 entry == Int 1)
  assertPublicClone url
  noCanaries (txt url <> canonical request)

assertCleanGreen :: Json -> IO ()
assertCleanGreen result = do
  result ! "custody_before" `shouldBe` String "pending"
  result ! "custody_after" `shouldBe` String "terminal"
  result ! "custody_counts" `shouldBe` object [("terminal", Int 1)]
  assertClearReview result
  [codes result, conversations result] `shouldBe` [Int 0, Int 0]
  let dashboard = marked dashboardMarker (comments result)
      readiness = marked readinessMarker (comments result)
  (length dashboard, length readiness) `shouldBe` (1, 1)
  check "readiness names the head" (("head=" <> headSha) `T.isInfixOf` bodyOf (head' readiness))
  check "readiness is ready" ("All observed gates are ready" `T.isInfixOf` bodyOf (head' readiness))
  check "every comment is the bot's" (all fromBot (comments result))
  reviewComments result `shouldBe` []
  check "no finding" (null (marked findingMarker (comments result)))
  check "no rerun" (null (marked "hamsterdan-rerun" (comments result)))
  attemptFacts result `shouldBe` [Int 1, String "success", Int 0]
  expectState result ("open", False, False, True, "clean", headSha, baseSha)
  let required =
        [ ("GET", "/repos/owner/repo/pulls/7")
        , ("GET", "/repos/owner/repo/git/ref/heads/main")
        , ("GET", "/repos/owner/repo/rules/branches/main")
        , ("GET", "/repos/owner/repo/compare/" <> baseSha <> "..." <> headSha)
        , ("GET", "/repos/owner/repo/actions/workflows/.github%2Fworkflows%2Fci.yml/runs?event=pull_request&head_sha=" <> headSha <> "&per_page=20")
        , ("GET", "/repos/owner/repo/actions/runs/101/attempts/1/jobs?per_page=100")
        , ("GET", "/repos/owner/repo/pulls/7/requested_reviewers")
        , ("PAGES", "/repos/owner/repo/pulls/7/reviews?per_page=100")
        , ("POST", "/graphql")
        ]
  check "every required evidence call" (all (`elem` calls result) required)
  let forbidden = ["/git/blobs", "/git/trees", "/git/commits", "/git/refs", "/merge", "/rerun", "updateRefs"]
  check "no forbidden call" (not (or [fragment `T.isInfixOf` path | (_, path) <- calls result, fragment <- forbidden]))
  quiescent result

-- | The checks @assert_first_attempt_flake@ and
-- @assert_persistent_ci_regression@ share before the follow-up.
assertBeforeRerun :: Json -> IO Json
assertBeforeRerun result = do
  let beforeComments = list (result ! "before_follow_up_comments")
      beforeCalls = callsIn (result ! "before_follow_up_calls")
      beforeDashboard = marked dashboardMarker beforeComments
  (length (marked rerunMarker beforeComments), length beforeDashboard) `shouldBe` (1, 1)
  marked readinessMarker beforeComments `shouldBe` []
  check "attempt 1's jobs before the follow-up" (("GET", "/repos/owner/repo/actions/runs/101/attempts/1/jobs?per_page=100") `elem` beforeCalls)
  check "no attempt 2 before the follow-up" (not (any (("/attempts/2/jobs" `T.isInfixOf`) . snd) beforeCalls))
  pure (head' beforeDashboard)

assertRerunMarker :: [Json] -> IO ()
assertRerunMarker reruns = check "the rerun marker" (isJust (rerunOperation headSha (bodyOf (head' reruns))))

assertFirstAttemptFlake :: Json -> IO ()
assertFirstAttemptFlake result = do
  result ! "custody_before" `shouldBe` String "pending"
  result ! "custody_after" `shouldBe` String "terminal"
  result ! "follow_up_custody_before" `shouldBe` String "pending"
  result ! "custody_counts" `shouldBe` object [("terminal", Int 2)]
  attemptFacts result `shouldBe` [Int 2, String "success", Int 1]
  assertClearReview result
  [codes result, conversations result] `shouldBe` [Int 0, Int 0]
  beforeDashboard <- assertBeforeRerun result
  let reruns = marked rerunMarker (comments result)
      dashboard = marked dashboardMarker (comments result)
      readiness = marked readinessMarker (comments result)
  (length reruns, length dashboard, length readiness) `shouldBe` (1, 1, 1)
  assertRerunMarker reruns
  check "readiness names the head" (("head=" <> headSha) `T.isInfixOf` bodyOf (head' readiness))
  check "readiness is ready" ("All observed gates are ready" `T.isInfixOf` bodyOf (head' readiness))
  check "every comment is the bot's" (all fromBot (comments result))
  reviewComments result `shouldBe` []
  check "no finding" (null (marked findingMarker (comments result)))
  expectState result ("open", False, False, True, "clean", headSha, baseSha)
  let current = head' dashboard
      dashboardId = beforeDashboard ! "id"
  check "the dashboard edited in place" (Array dashboard === Array [withBody beforeDashboard (current ! "body")])
  check "the dashboard changed" (current ! "body" /= beforeDashboard ! "body")
  check "the follow-up patches the dashboard" (any (\(method, _, identifier, body) -> method == "PATCH" && identifier == dashboardId && body == bodyOf current) (followUpWrites result))
  [body | (method, _, _, body) <- writes result, method == "POST", rerunMarker `T.isInfixOf` body] `shouldBe` [bodyOf (head' reruns)]
  [body | (_, _, _, body) <- writes result, readinessMarker `T.isInfixOf` body] `shouldBe` [bodyOf (head' readiness)]
  check "no finding write" (not (any (\(_, _, _, body) -> findingMarker `T.isInfixOf` body) (writes result)))
  check "attempt 1's jobs" (("GET", "/repos/owner/repo/actions/runs/101/attempts/1/jobs?per_page=100") `elem` calls result)
  check "attempt 2's jobs" (("GET", "/repos/owner/repo/actions/runs/101/attempts/2/jobs?per_page=100") `elem` calls result)
  noForbiddenRequests forbiddenWithoutRerun result
  quiescent result

withBody :: Json -> Json -> Json
withBody item body = case item of
  Object members -> Object [(key, if key == "body" then body else value) | (key, value) <- members]
  other -> other

assertPersistentCiRegression :: Json -> IO ()
assertPersistentCiRegression result = do
  [result ! "custody_before", result ! "follow_up_custody_before"] `shouldBe` [String "pending", String "pending"]
  result ! "custody_after" `shouldBe` String "terminal"
  result ! "custody_counts" `shouldBe` object [("terminal", Int 2)]
  attemptFacts result `shouldBe` [Int 2, String "failure", Int 1]
  assertClearReview result
  conversations result `shouldBe` Int 0
  beforeDashboard <- assertBeforeRerun result
  let reruns = marked rerunMarker (comments result)
      dashboard = marked dashboardMarker (comments result)
      readiness = marked readinessMarker (comments result)
  (length reruns, length dashboard) `shouldBe` (1, 1)
  readiness `shouldBe` []
  assertRerunMarker reruns
  check "no finding" (null (marked findingMarker (comments result)))
  expectState result ("open", False, False, True, "clean", headSha, baseSha)
  [codes result, runnerOf result ! "coding_status"] `shouldBe` [Int 1, String "unchanged"]
  entry <- single "code calls" (codeCalls result)
  let url = element 0 entry
      request = element 1 entry
  [request ! "kind", request ! "repository", request ! "pull_request", request ! "head", request ! "base"]
    `shouldBe` [String "repair", String "owner/repo", Int 7, String headSha, String baseSha]
  assertPublicClone url
  check "an operation, attempt 1" (txt (element 2 entry) /= "" && element 3 entry == Int 1)
  failure <- single "failure evidence" (list (request ! "failure_evidence"))
  txt (failure ! "run_id") `shouldBe` "101"
  [failure ! "head", failure ! "attempt", failure ! "conclusion"] `shouldBe` [String headSha, Int 2, String "failure"]
  [request ! "fingerprint", failure ! "fingerprint"] `shouldBe` [String failureFingerprint, String failureFingerprint]
  noCanaries (txt url <> canonical request)
  list (result ! "git_publications") `shouldBe` []
  reconciliation <- single "reconciliations" (list (result ! "git_reconciliations"))
  [reconciliation ! "expected_head", reconciliation ! "base_head", reconciliation ! "merge_base"] `shouldBe` [String headSha, String baseSha, Bool False]
  check "an operation and digest" (txt (reconciliation ! "operation") /= "" && txt (reconciliation ! "payload_digest") /= "")
  let dashboardId = beforeDashboard ! "id"
      current = head' dashboard
  current ! "id" `shouldBe` dashboardId
  check "CI failing on the dashboard" ("| CI checks | \x274c failing |" `T.isInfixOf` bodyOf current)
  check "the follow-up patches the dashboard" (any (\(method, _, identifier, body) -> method == "PATCH" && identifier == dashboardId && body == bodyOf current) (followUpWrites result))
  check "no readiness or finding write" (not (any (\(_, _, _, body) -> readinessMarker `T.isInfixOf` body || findingMarker `T.isInfixOf` body) (writes result)))
  check "attempt 2's jobs" (("GET", "/repos/owner/repo/actions/runs/101/attempts/2/jobs?per_page=100") `elem` calls result)
  noForbiddenRequests forbiddenWithoutRerun result
  quiescent result

assertSeededReviewFinding :: Json -> IO ()
assertSeededReviewFinding result = do
  result ! "custody_before" `shouldBe` String "pending"
  result ! "custody_after" `shouldBe` String "terminal"
  result ! "custody_counts" `shouldBe` object [("terminal", Int 1)]
  length (reviews result) `shouldBe` 1
  let entry = head' (reviews result)
      url = element 0 entry
      request = element 1 entry
  [request ! "repository", request ! "pull_request", request ! "head", request ! "base"]
    `shouldBe` [String "owner/repo", Int 7, String headSha, String baseSha]
  check
    "the one blocking review result"
    (Array (reviewResults result) === Array [reviewResultJson (request ! "epoch") headSha baseSha "blocking" [blockingFindingJson] blockingLineage])
  check "an operation, attempt 1" (txt (element 2 entry) /= "" && element 3 entry == Int 1)
  assertPublicClone url
  actions <- single "actions evidence" (list (request ! "actions_evidence"))
  actionFacts actions `shouldBe` [Int 101, String headSha, Int 1, String "completed", String "success"]
  noCanaries (txt url <> canonical request)
  [codes result, conversations result] `shouldBe` [Int 0, Int 0]
  let dashboard = marked dashboardMarker (comments result)
      readiness = marked readinessMarker (comments result)
      findingComments = marked findingMarker (everyComment result)
  (length dashboard, length findingComments) `shouldBe` (1, 1)
  readiness `shouldBe` []
  findingComment <- single "finding comments" findingComments
  check "the finding is a review comment" (findingComment `elem` reviewComments result)
  [findingComment ! "path", findingComment ! "line"] `shouldBe` [member "path" blockingFindingJson, member "line" blockingFindingJson]
  let findingBody = bodyOf findingComment
  check "the finding's prose" (txt (member "body" blockingFindingJson) `T.isInfixOf` findingBody)
  check "the suggestion" (("```suggestion\n" <> txt (member "suggestion" blockingFindingJson) <> "\n```") `T.isInfixOf` findingBody)
  check "no title" (not (txt (member "title" blockingFindingJson) `T.isInfixOf` findingBody))
  check "no evidence" (not (txt (member "evidence" blockingFindingJson) `T.isInfixOf` findingBody))
  case findingMarkerOf findingBody of
    Just (operation, markedHead) -> check "the finding marker" (markedHead == headSha && (":" <> findingId) `T.isSuffixOf` operation)
    Nothing -> expectationFailure "no finding marker"
  check "the review row" ("| Dan's review | \x274c blocking \x00b7 1 blocking of 1 finding(s) |" `T.isInfixOf` bodyOf (head' dashboard))
  check "every comment is the bot's" (all fromBot (everyComment result))
  attemptFacts result `shouldBe` [Int 1, String "success", Int 0]
  expectState result ("open", False, False, True, "clean", headSha, baseSha)
  [list (result ! "git_reconciliations"), list (result ! "git_publications")] `shouldBe` [[], []]
  check "the workflow runs" (("GET", "/repos/owner/repo/actions/workflows/.github%2Fworkflows%2Fci.yml/runs?event=pull_request&head_sha=" <> headSha <> "&per_page=20") `elem` calls result)
  check "attempt 1's jobs" (("GET", "/repos/owner/repo/actions/runs/101/attempts/1/jobs?per_page=100") `elem` calls result)
  [body | (_, _, _, body) <- writes result, findingMarker `T.isInfixOf` body] `shouldBe` [findingBody]
  [body | (_, _, _, body) <- writes result, readinessMarker `T.isInfixOf` body] `shouldBe` []
  noForbiddenRequests forbiddenWithRerun result
  quiescent result

-- | The comment-context instruction, @text@ or @body@.
commentText :: Json -> Json
commentText = \case
  Object members | Just value <- lookup "text" members -> value
  other -> other ! "body"

assertConversationalChange :: Json -> IO ()
assertConversationalChange result = do
  [result ! "custody_before", result ! "follow_up_custody_before", result ! "head_follow_up_custody_before"]
    `shouldBe` replicate 3 (String "pending")
  result ! "custody_after" `shouldBe` String "terminal"
  result ! "custody_counts" `shouldBe` object [("terminal", Int 3)]
  [conversations result, Int (toInteger (length (conversationCalls result)))] `shouldBe` [Int 1, Int 1]
  let conversationEntry = head' (conversationCalls result)
      conversation = element 1 conversationEntry
  [conversation ! "repository", conversation ! "pull_request", conversation ! "head", conversation ! "base"]
    `shouldBe` [String "owner/repo", Int 7, String headSha, String baseSha]
  commentText (conversation ! "comment_context") `shouldBe` String changeInstruction
  (conversation ! "actor") ! "login" `shouldBe` String "author"
  declaration <- single "change declarations" [item | item <- list (conversation ! "allowed_intents"), item ! "type" == String "change"]
  [declaration ! "mutation", declaration ! "requires_explicit"] `shouldBe` [Bool True, Bool True]
  check
    "the classified change"
    ( Array (conversationResults result)
        === Array
          [ object
              [ ("repository", String "owner/repo")
              , ("pull_request", Int 7)
              , ("epoch", conversation ! "epoch")
              , ("head", String headSha)
              , ("base", String baseSha)
              , ("intents", Array [changeIntent "change" changeInstruction])
              ]
          ]
    )
  element 2 conversationEntry `shouldBe` String ("conversation:owner/repo:pr:7:delivery:" <> txt (result ! "conversation_delivery_id"))
  element 3 conversationEntry `shouldBe` Int 1
  assertPublicClone (element 0 conversationEntry)
  [codes result, Int (toInteger (length (codeCalls result)))] `shouldBe` [Int 1, Int 1]
  let codingEntry = head' (codeCalls result)
      coding = element 1 codingEntry
  [coding ! "kind", coding ! "repository", coding ! "pull_request", coding ! "head", coding ! "base"]
    `shouldBe` [String "change", String "owner/repo", Int 7, String headSha, String baseSha]
  check "the instruction reaches the coding agent" (changeInstruction `T.isInfixOf` canonical (coding ! "selected_work"))
  check "no failure evidence, no merge base" (list (coding ! "failure_evidence") == [] && coding ! "merge_base" /= Bool True)
  let expectedOperation = "push:comment:501:" <> headSha <> ":i1"
  element 2 codingEntry `shouldBe` String ("mutation:owner/repo:pr:7:" <> expectedOperation)
  element 3 codingEntry `shouldBe` Int 1
  assertPublicClone (element 0 codingEntry)
  noCanaries (txt (element 0 codingEntry) <> canonical (object [("conversation", conversation), ("coding", coding)]))
  publication <- single "publications" (list (result ! "git_publications"))
  [publication ! "expected_head", publication ! "base_head", publication ! "merge_base"] `shouldBe` [String headSha, String baseSha, Bool False]
  check "a payload digest" (isDigest (txt (publication ! "payload_digest")))
  let published = publication ! "result"
  forM_ ["kind", "repository", "pull_request", "epoch", "head", "base", "ref"] $ \field ->
    published ! field `shouldBe` coding ! field
  published ! "status" `shouldBe` String "changed"
  published ! "changed_files" `shouldBe` Array [String "README.md"]
  published ! "diff" `shouldBe` String changeDiff
  publication ! "operation" `shouldBe` String expectedOperation
  reconciliation <- single "reconciliations" (list (result ! "git_reconciliations"))
  [reconciliation ! "expected_head", reconciliation ! "base_head", reconciliation ! "merge_base"] `shouldBe` [String headSha, String baseSha, Bool False]
  reconciliation ! "operation" `shouldBe` publication ! "operation"
  reconciliation ! "payload_digest" `shouldBe` publication ! "payload_digest"
  (length (reviews result), length (reviewResults result)) `shouldBe` (2, 2)
  [element 1 entry ! "head" | entry <- reviews result] `shouldBe` [String headSha, String newHeadSha]
  [element 1 entry ! "epoch" | entry <- reviews result] `shouldBe` [Int 1, Int 2]
  [review ! "epoch" | review <- reviewResults result] `shouldBe` [Int 1, Int 2]
  [review ! "status" | review <- reviewResults result] `shouldBe` [String "clear", String "clear"]
  check "every review clones publicly" (all ((== String "https://github.com/owner/repo.git") . element 0) (reviews result))
  newActions <- single "new actions evidence" (list (element 1 (element 1 (Array (reviews result))) ! "actions_evidence"))
  actionFacts newActions `shouldBe` [Int 102, String newHeadSha, Int 1, String "in_progress", Null]
  runFacts result `shouldBe` [Int 102, Int 1, Null, Int 0]
  expectState result ("open", False, False, True, "clean", newHeadSha, baseSha)
  let human = filter fromAuthor (comments result)
      botComments = filter fromBot (comments result)
      dashboard = marked dashboardMarker botComments
      readiness = marked readinessMarker botComments
  check "the human comment" (Array human === Array [humanComment changeInstruction])
  (length dashboard, length readiness) `shouldBe` (1, 1)
  let dashboardBody = bodyOf (head' dashboard)
  check "the dashboard names the new head" (newHeadSha `T.isInfixOf` dashboardBody)
  check "CI in progress" ("| CI checks | \x23f3 in progress |" `T.isInfixOf` dashboardBody)
  check "readiness of the first head" (("head=" <> headSha) `T.isInfixOf` bodyOf (head' readiness))
  check "no readiness of the new head" (not (newHeadSha `T.isInfixOf` bodyOf (head' readiness)))
  check "no finding" (null (marked findingMarker botComments))
  check "no rerun" (null (marked "hamsterdan-rerun" botComments))
  beforeDashboard <- single "dashboards before" (marked dashboardMarker (list (result ! "before_follow_up_comments")))
  head' dashboard ! "id" `shouldBe` beforeDashboard ! "id"
  check "the dashboard changed" (head' dashboard ! "body" /= beforeDashboard ! "body")
  check "the follow-up patches the dashboard" (any (\(method, _, identifier, body) -> method == "PATCH" && identifier == head' dashboard ! "id" && body == dashboardBody) (followUpWrites result))
  check "the new compare" (("GET", "/repos/owner/repo/compare/" <> baseSha <> "..." <> newHeadSha) `elem` calls result)
  check "run 102's jobs" (("GET", "/repos/owner/repo/actions/runs/102/attempts/1/jobs?per_page=100") `elem` calls result)
  noForbiddenRequests forbiddenWithRerun result
  quiescent result

changeIntent :: Text -> Text -> Json
changeIntent kind instruction =
  object
    [ ("type", String kind)
    , ("arguments", object [("request", String instruction)])
    , ("mutation", Bool True)
    , ("explicit", Bool True)
    , ("confidence", Float 1.0)
    ]

humanComment :: Text -> Json
humanComment instruction =
  object
    [ ("id", Int 501)
    , ("html_url", String "https://github.com/owner/repo/pull/7#issuecomment-501")
    , ("body", String ("@hamsterdan-test " <> instruction))
    , ("user", object [("login", String "author")])
    ]

-- | The digest of the compare-and-swap's @clientMutationId@.
expectedClient :: Text -> Text -> Text
expectedClient initialHead finalHead =
  TE.decodeUtf8 . Base16.encode . SHA256.hash . either (error . show) id . dumps compact {sortKeys = True} $
    object
      [ ("repository", String "owner/repo")
      , ("ref", String "refs/heads/feature")
      , ("expected_head", String initialHead)
      , ("commit", String finalHead)
      ]

objectWrites :: Json -> [Text]
objectWrites result = [path | (method, path, _) <- requests result, method == "POST", "/repos/owner/repo/git/" `T.isPrefixOf` path]

gitObjectPaths :: [Text]
gitObjectPaths = ["/repos/owner/repo/git/blobs", "/repos/owner/repo/git/trees", "/repos/owner/repo/git/commits"]

updateRefsRequests :: Json -> Int
updateRefsRequests result = length [() | (method, path, body) <- requests result, method == "POST", path == "/graphql", "updateRefs" `T.isInfixOf` body]

assertAgentRepair :: Json -> IO ()
assertAgentRepair result = do
  let initialHead = txt (result ! "initial_head")
      initialBase = txt (result ! "initial_base")
      finalHead = txt (element 5 (Array (providerState result)))
  [result ! "custody_before", result ! "follow_up_custody_before", result ! "head_follow_up_custody_before"]
    `shouldBe` replicate 3 (String "pending")
  result ! "custody_after" `shouldBe` String "terminal"
  result ! "custody_counts" `shouldBe` object [("terminal", Int 3)]
  runFacts result `shouldBe` [Int 102, Int 1, String "success", Int 1]
  expectState result ("open", False, False, True, "clean", finalHead, initialBase)
  check "a new head" (finalHead `notElem` [initialHead, initialBase])
  conversations result `shouldBe` Int 0
  conversationCalls result `shouldBe` []
  [length (codeCalls result), length (codeResults result)] `shouldBe` [1, 1]
  codes result `shouldBe` Int 1
  let codingEntry = head' (codeCalls result)
      url = element 0 codingEntry
      coding = element 1 codingEntry
      codingOperation = element 2 codingEntry
  assertPublicClone url
  [coding ! "kind", coding ! "repository", coding ! "pull_request", coding ! "epoch"] `shouldBe` [String "repair", String "owner/repo", Int 7, Int 1]
  [coding ! "head", coding ! "base", element 3 codingEntry] `shouldBe` [String initialHead, String initialBase, Int 1]
  check "a hamsterdan ref" ("hamsterdan/" `T.isPrefixOf` txt (coding ! "ref"))
  failure <- single "failure evidence" (list (coding ! "failure_evidence"))
  (txt (failure ! "run_id"), [failure ! "head", failure ! "attempt", failure ! "conclusion", failure ! "fingerprint"])
    `shouldBe` ("101", [String initialHead, Int 2, String "failure", String failureFingerprint])
  noCanaries (txt url <> canonical coding)
  codingResult <- single "code results" (codeResults result)
  check
    "the repair result"
    (codingResult === codingResultJson "repair" (Int 1) initialHead initialBase (coding ! "ref") "confirmed" repairDiff ["src/readiness.py"] "repair-check" "fix: repair seeded failure")
  (length (reviews result), length (reviewResults result)) `shouldBe` (2, 2)
  [[element 1 entry ! "epoch", element 1 entry ! "head"] | entry <- reviews result]
    `shouldBe` [[Int 1, String initialHead], [Int 2, String finalHead]]
  check
    "every review"
    ( all
        ( \entry ->
            element 0 entry == String "https://github.com/owner/repo.git"
              && element 1 entry ! "base" == String initialBase
              && element 3 entry == Int 1
              && txt (element 2 entry) /= ""
        )
        (reviews result)
    )
  let firstReview = element 0 (Array (reviewResults result))
      repairedReview = element 1 (Array (reviewResults result))
  check "the blocking review" (Array [firstReview ! "status", firstReview ! "findings", firstReview ! "lineage"] === Array [String "blocking", Array [blockingFindingJson], Array blockingLineage])
  check
    "the resolved review"
    ( Array [repairedReview ! "status", repairedReview ! "findings", repairedReview ! "lineage"]
        === Array [String "clear", Array [], Array [object [("finding_id", String findingId), ("state", String "resolved"), ("supersedes", Null)]]]
    )
  let firstRequest = element 1 (element 0 (Array (reviews result)))
      repairedRequest = element 1 (element 1 (Array (reviews result)))
  [firstRequest ! "prior_findings", firstRequest ! "applied_changes"] `shouldBe` [Array [], Array []]
  prior <- single "prior findings" (list (repairedRequest ! "prior_findings"))
  check "the prior finding" (all (\(key, value) -> prior ! key === value) blockingFinding)
  check "the applied lineage" (repairedRequest ! "applied_changes" === Array blockingLineage)
  [[item ! "id", item ! "head", item ! "attempt", item ! "conclusion"] | item <- list (firstRequest ! "actions_evidence")]
    `shouldBe` [[Int 101, String initialHead, Int 1, String "failure"]]
  [[item ! "id", item ! "head", item ! "attempt", item ! "conclusion"] | item <- list (repairedRequest ! "actions_evidence")]
    `shouldBe` [[Int 102, String finalHead, Int 1, String "success"]]
  forM_ ["/repos/owner/repo/actions/runs/101/attempts/1/jobs?per_page=100", "/repos/owner/repo/actions/runs/101/attempts/2/jobs?per_page=100", "/repos/owner/repo/actions/runs/102/attempts/1/jobs?per_page=100"] $ \path ->
    check ("the call " <> T.unpack path) (("GET", path) `elem` calls result)
  let publicationOperation = "push:repair:L1:" <> failureFingerprint <> ":" <> initialHead <> ":i1"
  codingOperation `shouldBe` String ("mutation:owner/repo:pr:7:" <> publicationOperation)
  publication <- single "publications" (list (result ! "git_publications"))
  publication ! "operation" `shouldBe` String publicationOperation
  publication ! "expected_head" `shouldBe` String initialHead
  [publication ! "base_head", publication ! "merge_base"] `shouldBe` [String initialBase, Bool False]
  let payloadDigest = txt (publication ! "payload_digest")
  check "a payload digest" (isDigest payloadDigest)
  check "the published result" (publication ! "result" === codingResult)
  publication ! "outcome" `shouldBe` object [("head", String finalHead), ("recovered", Bool False)]
  let reconciliations = list (result ! "git_reconciliations")
      dispositions = [txt ((item ! "result") ! "disposition") | item <- reconciliations]
  check "absent first, existing last" (take 1 dispositions == ["absent"] && take 1 (reverse dispositions) == ["existing"])
  check "one existing" (length (filter (== "existing") dispositions) == 1 && sort (nub dispositions) == ["absent", "existing"])
  forM_ reconciliations $ \reconciliation -> do
    reconciliation ! "operation" `shouldBe` String publicationOperation
    reconciliation ! "payload_digest" `shouldBe` String payloadDigest
    reconciliation ! "expected_head" `shouldBe` String initialHead
    [reconciliation ! "base_head", reconciliation ! "merge_base"] `shouldBe` [String initialBase, Bool False]
  (head' reconciliations ! "result") ! "observed_head" `shouldBe` String initialHead
  check
    "the final reconciliation"
    ( (head' (reverse reconciliations) ! "result")
        === object [("disposition", String "existing"), ("observed_head", String finalHead), ("commit", String finalHead), ("parents", Array [String initialHead])]
    )
  cas <- single "compare-and-swaps" (list (result ! "git_cas_updates"))
  [cas ! "before", cas ! "after"] `shouldBe` [String initialHead, String finalHead]
  cas ! "client" `shouldBe` String (expectedClient initialHead finalHead)
  result ! "git_remote_head" `shouldBe` String finalHead
  result ! "git_commit_parents" `shouldBe` Array [String initialHead]
  check "the repaired guard" ("if mergeable and all_gates_clear:" `T.isInfixOf` txt (result ! "git_repaired_content"))
  check "no unrepaired guard" (not ("    if all_gates_clear:" `T.isInfixOf` txt (result ! "git_repaired_content")))
  result ! "git_commit_body"
    `shouldBe` String ("fix: repair seeded failure\n\nHamsterdan-Operation: " <> publicationOperation <> "\nHamsterdan-Payload-Digest: " <> payloadDigest)
  let created = list (result ! "git_created_objects")
  check "three objects, the commit among them" (length created == 3 && String finalHead `elem` created)
  objectWrites result `shouldBe` gitObjectPaths
  let events = list (result ! "git_boundary_events")
      indexed = zip [0 :: Int ..] events
      kind event = txt (event ! "kind")
      indicesOf wanted = [index | (index, event) <- indexed, kind event == wanted]
      objectIndices = indicesOf "object"
      firstOf wanted = maybe (-1) id (listToMaybe (indicesOf wanted))
      casEvent = firstOf "cas"
      finalReconciliation = maybe (-1) id (listToMaybe (reverse (indicesOf "reconcile")))
      publicationEvent = firstOf "publish"
      firstObject = maybe (-1) id (listToMaybe objectIndices)
      lastObject = maybe (-1) id (listToMaybe (reverse objectIndices))
  [txt (event ! "path") | event <- events, kind event == "object"] `shouldBe` objectWrites result
  check "a first absent reconciliation" (kind (head' events) == "reconcile" && txt ((head' events ! "result") ! "disposition") == "absent")
  check
    "the boundary order"
    (0 < firstObject && firstObject <= lastObject && lastObject < casEvent && casEvent < finalReconciliation && finalReconciliation < publicationEvent)
  check "the compare-and-swap event" (element casEvent (Array events) === object [("kind", String "cas"), ("before", String initialHead), ("after", String finalHead)])
  txt ((element finalReconciliation (Array events) ! "result") ! "disposition") `shouldBe` "existing"
  publicationEvent `shouldBe` length events - 1
  updateRefsRequests result `shouldBe` 1
  check "no merge" (not (any (\(_, path, _) -> "/merge" `T.isInfixOf` path) (requests result)))
  let rerun = marked rerunMarker (comments result)
      dashboard = marked dashboardMarker (comments result)
      readiness = marked readinessMarker (comments result)
      findings = marked findingMarker (everyComment result)
  map length [rerun, dashboard, readiness, findings] `shouldBe` [1, 1, 1, 1]
  check "the rerun of the initial head" (("run=101 head=" <> initialHead) `T.isInfixOf` bodyOf (head' rerun))
  check "the finding" (findingId `T.isInfixOf` bodyOf (head' findings) && initialHead `T.isInfixOf` bodyOf (head' findings))
  check "the dashboard names the final head" (finalHead `T.isInfixOf` bodyOf (head' dashboard))
  check "readiness of the final head" (("head=" <> finalHead) `T.isInfixOf` bodyOf (head' readiness))
  check "the clear review row" ("| Dan's review | \x2705 clear \x00b7 0 findings |" `T.isInfixOf` bodyOf (head' dashboard))
  check "head follow-up comments" (result ! "head_follow_up_comments_before" /= Null)
  check "no readiness before the head follow-up" (null (marked readinessMarker (list (result ! "head_follow_up_comments_before"))))
  [body | (_, _, _, body) <- writes result, readinessMarker `T.isInfixOf` body] `shouldBe` [bodyOf (head' readiness)]
  check "every comment is the bot's" (all fromBot (everyComment result))
  quiescent result

-- | @finding_operations(result)@.
findingOperations :: Json -> [Text]
findingOperations result =
  [ maybe "<no marker>" (\(operation, markedHead) -> if markedHead == headSha then operation else "<wrong head>") (findingMarkerOf (bodyOf item))
  | item <- marked findingMarker (everyComment result)
  ]

assertHeroReview :: Json -> IO ()
assertHeroReview result = do
  result ! "custody_before" `shouldBe` String "pending"
  result ! "custody_after" `shouldBe` String "terminal"
  result ! "custody_counts" `shouldBe` object [("terminal", Int 1)]
  length (reviews result) `shouldBe` 1
  let entry = head' (reviews result)
      url = element 0 entry
      request = element 1 entry
  assertPublicClone url
  [request ! "repository", request ! "pull_request", request ! "epoch", request ! "head", request ! "base"]
    `shouldBe` [String "owner/repo", Int 7, Int 1, String headSha, String baseSha]
  [request ! "prior_findings", request ! "applied_changes"] `shouldBe` [Array [], Array []]
  actions <- single "actions evidence" (list (request ! "actions_evidence"))
  actionFacts actions `shouldBe` [Int 101, String headSha, Int 1, String "completed", String "success"]
  check "an operation, attempt 1" (txt (element 2 entry) /= "" && element 3 entry == Int 1)
  noCanaries (txt url <> canonical request)
  review <- single "review results" (reviewResults result)
  [review ! "repository", review ! "pull_request", review ! "epoch", review ! "head", review ! "base", review ! "status"]
    `shouldBe` [String "owner/repo", Int 7, Int 1, String headSha, String baseSha, String "blocking"]
  check "the hero findings" (review ! "findings" === Array (map object heroFindings))
  check "the hero lineage" (review ! "lineage" === Array heroLineage)
  [codes result, conversations result] `shouldBe` [Int 0, Int 0]
  let dashboard = marked dashboardMarker (comments result)
      readiness = marked readinessMarker (comments result)
      findingEffects = marked findingMarker (everyComment result)
  length dashboard `shouldBe` 1
  readiness `shouldBe` []
  [length findingEffects, length (reviewComments result)] `shouldBe` [length heroFindings, length heroFindings]
  forM_ (map object heroFindings) $ \finding -> do
    comment <- single "finding comment" [item | item <- findingEffects, (":" <> txt (finding ! "id") <> " head=") `T.isInfixOf` bodyOf item]
    check "the finding is a review comment" (comment `elem` reviewComments result)
    [comment ! "path", comment ! "line"] `shouldBe` [finding ! "path", finding ! "line"]
    let body = bodyOf comment
    check "the finding's prose" (txt (finding ! "body") `T.isInfixOf` body)
    check "no title" (not (txt (finding ! "title") `T.isInfixOf` body))
    check "no evidence" (not (txt (finding ! "evidence") `T.isInfixOf` body))
    forM_ (list (finding ! "related_locations")) $ \related ->
      check "the related location" ((txt (related ! "path") <> ":" <> txt (related ! "line")) `T.isInfixOf` body)
  findingOperations result `shouldBe` ["findings:" <> headSha <> ":i1:" <> txt (object finding ! "id") | finding <- heroFindings]
  ttlBody <- single "ttl finding" [bodyOf item | item <- findingEffects, ":F-ttl-unit head=" `T.isInfixOf` bodyOf item]
  check "the ttl suggestion" ("```suggestion\ntimedelta(seconds=ttl_seconds)\n```" `T.isInfixOf` ttlBody)
  check "no other suggestion" (not (any (\item -> "```suggestion" `T.isInfixOf` bodyOf item) [item | item <- findingEffects, not (":F-ttl-unit head=" `T.isInfixOf` bodyOf item)]))
  let dashboardBody = bodyOf (head' dashboard)
  check "the dashboard names the head and blocks" (headSha `T.isInfixOf` dashboardBody && "blocking" `T.isInfixOf` dashboardBody)
  check "the review row" ("| Dan's review | \x274c blocking \x00b7 3 blocking of 3 finding(s) |" `T.isInfixOf` dashboardBody)
  [body | (_, _, _, body) <- writes result, findingMarker `T.isInfixOf` body] `shouldBe` map bodyOf findingEffects
  noForbiddenRequests forbiddenWithRerun result
  runFacts result `shouldBe` [Int 101, Int 1, String "success", Int 0]
  expectState result ("open", False, False, True, "clean", headSha, baseSha)
  map (list . (result !)) ["git_reconciliations", "git_publications", "git_cas_updates"] `shouldBe` [[], [], []]
  check "every comment is the bot's" (all fromBot (everyComment result))
  quiescent result

assertDraftReady :: Json -> IO ()
assertDraftReady result = do
  let draft = result ! "draft_phase"
  check "a draft phase" (draft /= Null)
  draft ! "custody_before" `shouldBe` String "pending"
  draft ! "custody_after" `shouldBe` String "terminal"
  draft ! "custody_counts" `shouldBe` object [("terminal", Int 1)]
  map (draft !) ["comments", "review_comments", "provider_writes"] `shouldBe` replicate 3 (Array [])
  [draft ! "agent_counts", draft ! "rerun_requests"] `shouldBe` [Array [Int 0, Int 0, Int 0], Int 0]
  [draft ! "ready_custody_before", draft ! "ready_custody_after"] `shouldBe` [String "pending", String "terminal"]
  result ! "custody_after" `shouldBe` String "terminal"
  result ! "custody_counts" `shouldBe` object [("terminal", Int 2)]
  assertClearReview result
  [codes result, conversations result] `shouldBe` [Int 0, Int 0]
  let dashboard = marked dashboardMarker (comments result)
      readiness = marked readinessMarker (comments result)
  (length dashboard, length readiness) `shouldBe` (1, 1)
  check "not unable" (not ("unable" `T.isInfixOf` T.toLower (bodyOf (head' dashboard))))
  check "not canceled" (not ("canceled" `T.isInfixOf` T.toLower (bodyOf (head' dashboard))))
  check "readiness names the head" (("head=" <> headSha) `T.isInfixOf` bodyOf (head' readiness))
  check "readiness is ready" ("All observed gates are ready" `T.isInfixOf` bodyOf (head' readiness))
  reviewComments result `shouldBe` []
  check "no finding" (null (marked findingMarker (comments result)))
  check "no rerun" (null (marked "hamsterdan-rerun" (comments result)))
  attemptFacts result `shouldBe` [Int 1, String "success", Int 0]
  expectState result ("open", False, False, True, "clean", headSha, baseSha)
  noForbiddenRequests forbiddenWithRerun result
  check "every comment is the bot's" (all fromBot (comments result))
  quiescent result

assertStaleBaseUpdate :: Json -> IO ()
assertStaleBaseUpdate result =
  assertBaseMutation result "update_base" updateBaseInstruction updateBaseDiff "BASE-NOTES.md" "base-check" "merge: update feature from main" "Latest base behavior." False

assertTrueConflictResolution :: Json -> IO ()
assertTrueConflictResolution result =
  assertBaseMutation
    result
    "resolve_conflict"
    resolveConflictInstruction
    conflictDiff
    "src/pr_fixture/__init__.py"
    "conflict-check"
    "merge: resolve feature and main conflict"
    "\"\"\"Minimal release-qualified domain for the PR-readiness laboratory fixtures.\"\"\""
    True

-- | @_assert_base_mutation(result, ...)@.
assertBaseMutation :: Json -> Text -> Text -> Text -> Text -> Text -> Text -> Text -> Bool -> IO ()
assertBaseMutation result mutationKind instruction diff changedFile command message finalContent conflicted = do
  let initialHead = txt (result ! "initial_head")
      initialBase = txt (result ! "initial_base")
      finalHead = txt (element 5 (Array (providerState result)))
      currentBase = txt (element 6 (Array (providerState result)))
      stale = result ! "stale_base_phase"
  check "a stale-base phase" (stale /= Null)
  [stale ! "custody_before", stale ! "custody_after"] `shouldBe` [String "pending", String "terminal"]
  [stale ! "old_base", stale ! "current_base"] `shouldBe` [String initialBase, String currentBase]
  check "distinct revisions" (currentBase `notElem` [initialHead, initialBase] && finalHead `notElem` [initialHead, initialBase, currentBase])
  staleDashboard <- single "stale dashboards" (marked dashboardMarker (list (stale ! "comments")))
  let staleBody = bodyOf staleDashboard
  check "the stale base row" ("base is stale" `T.isInfixOf` staleBody && "| Base | \x26a0\xfe0f behind" `T.isInfixOf` staleBody)
  if conflicted then check "the conflict row" ("| Conflicts | \x274c merge conflict |" `T.isInfixOf` staleBody) else pure ()
  drop 1 (list (stale ! "agent_counts")) `shouldBe` [Int 0, Int 0]
  [result ! "custody_before", result ! "follow_up_custody_before", result ! "head_follow_up_custody_before"]
    `shouldBe` replicate 3 (String "pending")
  result ! "custody_after" `shouldBe` String "terminal"
  result ! "custody_counts" `shouldBe` object [("terminal", Int 4)]
  expectState result ("open", False, False, True, "clean", finalHead, currentBase)
  runFacts result `shouldBe` [Int 102, Int 1, String "success", Int 0]
  [conversations result, Int (toInteger (length (conversationCalls result)))] `shouldBe` [Int 1, Int 1]
  let conversationEntry = head' (conversationCalls result)
      conversation = element 1 conversationEntry
  assertPublicClone (element 0 conversationEntry)
  [conversation ! "repository", conversation ! "pull_request", conversation ! "head", conversation ! "base"]
    `shouldBe` [String "owner/repo", Int 7, String initialHead, String currentBase]
  commentText (conversation ! "comment_context") `shouldBe` String instruction
  declaration <- case [item | item <- list (conversation ! "allowed_intents"), item ! "type" == String mutationKind] of
    item : _ -> pure item
    [] -> expectationFailure "no declaration of the mutation" >> pure Null
  [declaration ! "mutation", declaration ! "requires_explicit"] `shouldBe` [Bool True, Bool True]
  classified <- single "conversation results" (conversationResults result)
  intent <- single "intents" (list (classified ! "intents"))
  check "the intent" (intent === changeIntent mutationKind instruction)
  element 2 conversationEntry `shouldBe` String ("conversation:owner/repo:pr:7:delivery:" <> txt (result ! "conversation_delivery_id"))
  element 3 conversationEntry `shouldBe` Int 1
  [codes result, Int (toInteger (length (codeCalls result))), Int (toInteger (length (codeResults result)))] `shouldBe` [Int 1, Int 1, Int 1]
  let codingEntry = head' (codeCalls result)
      coding = element 1 codingEntry
  assertPublicClone (element 0 codingEntry)
  [coding ! "kind", coding ! "repository", coding ! "pull_request", coding ! "head", coding ! "base"]
    `shouldBe` [String "change", String "owner/repo", Int 7, String initialHead, String currentBase]
  selectedWork <- single "selected work" (list (coding ! "selected_work"))
  selectedWork ! "kind" `shouldBe` String mutationKind
  let selectedInstruction = case selectedWork ! "request" of
        Null -> (selectedWork ! "arguments") ! "request"
        value -> value
  selectedInstruction `shouldBe` String instruction
  [coding ! "failure_evidence", coding ! "merge_base", element 3 codingEntry] `shouldBe` [Array [], Bool True, Int 1]
  codingResult <- single "code results" (codeResults result)
  check
    "the coding result"
    (codingResult === codingResultJson "change" (coding ! "epoch") initialHead currentBase (coding ! "ref") "not_attempted" diff [changedFile] command message)
  noCanaries (txt (element 0 codingEntry) <> canonical (object [("conversation", conversation), ("coding", coding)]))
  let publicationOperation = "push:comment:501:" <> initialHead <> ":i1"
  element 2 codingEntry `shouldBe` String ("mutation:owner/repo:pr:7:" <> publicationOperation)
  publication <- single "publications" (list (result ! "git_publications"))
  publication ! "operation" `shouldBe` String publicationOperation
  publication ! "expected_head" `shouldBe` String initialHead
  [publication ! "base_head", publication ! "merge_base"] `shouldBe` [String currentBase, Bool True]
  let payloadDigest = txt (publication ! "payload_digest")
  check "a payload digest" (isDigest payloadDigest)
  check "the published result" (publication ! "result" === codingResult)
  publication ! "outcome" `shouldBe` object [("head", String finalHead), ("recovered", Bool False)]
  let reconciliations = list (result ! "git_reconciliations")
      dispositions = [txt ((item ! "result") ! "disposition") | item <- reconciliations]
  check "reconciliations" (not (null reconciliations))
  check "absent first, existing last" (take 1 dispositions == ["absent"] && take 1 (reverse dispositions) == ["existing"])
  sort (nub dispositions) `shouldBe` ["absent", "existing"]
  forM_ reconciliations $ \reconciliation -> do
    reconciliation ! "operation" `shouldBe` String publicationOperation
    reconciliation ! "payload_digest" `shouldBe` String payloadDigest
    reconciliation ! "expected_head" `shouldBe` String initialHead
    [reconciliation ! "base_head", reconciliation ! "merge_base"] `shouldBe` [String currentBase, Bool True]
  check
    "the final reconciliation"
    ( (head' (reverse reconciliations) ! "result")
        === object [("disposition", String "existing"), ("observed_head", String finalHead), ("commit", String finalHead), ("parents", Array [String initialHead, String currentBase])]
    )
  cas <- single "compare-and-swaps" (list (result ! "git_cas_updates"))
  [cas ! "before", cas ! "after"] `shouldBe` [String initialHead, String finalHead]
  result ! "git_remote_head" `shouldBe` String finalHead
  result ! "git_commit_parents" `shouldBe` Array [String initialHead, String currentBase]
  result ! "git_repaired_content" `shouldBe` String finalContent
  result ! "git_commit_body"
    `shouldBe` String (message <> "\n\nHamsterdan-Operation: " <> publicationOperation <> "\nHamsterdan-Payload-Digest: " <> payloadDigest)
  let created = list (result ! "git_created_objects")
  check "three objects, the commit among them" (length created == 3 && String finalHead `elem` created)
  objectWrites result `shouldBe` gitObjectPaths
  updateRefsRequests result `shouldBe` 1
  check "no merge" (not (any (\(_, path, _) -> "/merge" `T.isInfixOf` path) (requests result)))
  check "head follow-up snapshots" (result ! "head_follow_up_comments_before" /= Null && result ! "head_follow_up_review_count_before" /= Null)
  let beforeHeadComments = list (result ! "head_follow_up_comments_before")
  beforeHeadDashboard <- single "dashboards before the head follow-up" (marked dashboardMarker beforeHeadComments)
  let beforeHeadBody = bodyOf beforeHeadDashboard
  check "the dashboard predates the final head" (not (finalHead `T.isInfixOf` beforeHeadBody))
  check "still behind" ("| Base | \x26a0\xfe0f behind" `T.isInfixOf` beforeHeadBody)
  if conflicted then check "still conflicted" ("| Conflicts | \x274c merge conflict |" `T.isInfixOf` beforeHeadBody) else pure ()
  beforeHeadReadiness <- single "readiness before the head follow-up" (marked readinessMarker beforeHeadComments)
  check "readiness of the initial head" (("head=" <> initialHead) `T.isInfixOf` bodyOf beforeHeadReadiness)
  check "no readiness of the final head" (not (("head=" <> finalHead) `T.isInfixOf` bodyOf beforeHeadReadiness))
  let reviewRequests = map (element 1) (reviews result)
      priorCount = fromInteger (number (result ! "head_follow_up_review_count_before"))
      priorReviews = take priorCount reviewRequests
  check "prior reviews of the initial head" (not (null priorReviews) && all (\request -> request ! "head" == String initialHead) priorReviews)
  length reviewRequests `shouldBe` priorCount + 1
  [head' reviewRequests ! "head", head' reviewRequests ! "base"] `shouldBe` [String initialHead, String initialBase]
  [last reviewRequests ! "head", last reviewRequests ! "base"] `shouldBe` [String finalHead, String currentBase]
  [review ! "status" | review <- reviewResults result] `shouldBe` replicate (length reviewRequests) (String "clear")
  check "every review clones publicly" (all ((== String "https://github.com/owner/repo.git") . element 0) (reviews result))
  finalActions <- single "final actions evidence" (list (last reviewRequests ! "actions_evidence"))
  actionFacts finalActions `shouldBe` [Int 102, String finalHead, Int 1, String "completed", String "success"]
  check "the human comment" (Array (filter fromAuthor (comments result)) === Array [humanComment instruction])
  let botComments = filter fromBot (comments result)
  dashboard <- single "dashboards" (marked dashboardMarker botComments)
  let readiness = marked readinessMarker botComments
  length readiness `shouldBe` 2
  check "readiness of the initial head" (any ((("head=" <> initialHead) `T.isInfixOf`) . bodyOf) readiness)
  check "readiness of the final head" (any ((("head=" <> finalHead) `T.isInfixOf`) . bodyOf) readiness)
  let dashboardBody = bodyOf dashboard
  check "the dashboard names the final head" (finalHead `T.isInfixOf` dashboardBody)
  check "the base is current" ("| Base | \x2705 current with" `T.isInfixOf` dashboardBody)
  if conflicted then check "no conflict" ("| Conflicts | \x2705 none |" `T.isInfixOf` dashboardBody) else pure ()
  check "no finding" (null (marked findingMarker botComments))
  check "no rerun" (null (marked "hamsterdan-rerun" botComments))
  reviewComments result `shouldBe` []
  quiescent result

assertCollaborationApproval :: Json -> IO ()
assertCollaborationApproval result = do
  let phase = result ! "collaboration_phase"
  check "a collaboration phase" (phase /= Null)
  phase ! "deliveries"
    `shouldBe` Array
      [ Array [String label, String "pending", String "terminal"]
      | label <- ["review_requested", "changes_requested", "approved_thread_open", "thread_resolved"]
      ]
  let dashboards = map txt (list (phase ! "dashboards"))
  length dashboards `shouldBe` 5
  phase ! "readiness_counts" `shouldBe` Array (map Int [0, 0, 0, 0, 1])
  let rows =
        [ "| Human review | \x23f3 not approved \x00b7 0 unresolved thread(s) |"
        , "| Human review | \x23f3 not approved \x00b7 0 unresolved thread(s) |"
        , "| Human review | \x274c changes requested \x00b7 1 unresolved thread(s) |"
        , "| Human review | \x2705 approved \x00b7 1 unresolved thread(s) |"
        , "| Human review | \x2705 approved \x00b7 0 unresolved thread(s) |"
        ]
  forM_ (zip rows dashboards) $ \(row, dashboard) -> check (T.unpack row) (row `T.isInfixOf` dashboard)
  [result ! "custody_before", result ! "custody_after"] `shouldBe` [String "pending", String "terminal"]
  result ! "custody_counts" `shouldBe` object [("terminal", Int 5)]
  expectState result ("open", False, False, True, "clean", headSha, baseSha)
  runFacts result `shouldBe` [Int 101, Int 1, String "success", Int 0]
  [codes result, conversations result] `shouldBe` [Int 0, Int 0]
  [codeCalls result, conversationCalls result] `shouldBe` [[], []]
  (length (reviews result), length (reviewResults result)) `shouldBe` (1, 1)
  let entry = head' (reviews result)
      request = element 1 entry
  assertPublicClone (element 0 entry)
  [request ! "head", request ! "base", request ! "epoch"] `shouldBe` [String headSha, String baseSha, Int 1]
  check "an operation, attempt 1" (txt (element 2 entry) /= "" && element 3 entry == Int 1)
  let review = head' (reviewResults result)
  [review ! "head", review ! "base", review ! "status", review ! "findings"] `shouldBe` [String headSha, String baseSha, String "clear", Array []]
  let dashboard = marked dashboardMarker (comments result)
      readiness = marked readinessMarker (comments result)
  (length dashboard, length readiness) `shouldBe` (1, 1)
  Just (bodyOf (head' dashboard)) `shouldBe` listToMaybe (reverse dashboards)
  check "readiness names the head" (("head=" <> headSha) `T.isInfixOf` bodyOf (head' readiness))
  check "readiness is ready" ("All observed gates are ready" `T.isInfixOf` bodyOf (head' readiness))
  reviewComments result `shouldBe` []
  check "no finding" (null (marked findingMarker (comments result)))
  check "no rerun" (null (marked "hamsterdan-rerun" (comments result)))
  map (list . (result !)) ["git_reconciliations", "git_publications", "git_cas_updates"] `shouldBe` [[], [], []]
  noForbiddenRequests forbiddenWithRerun result
  check "every comment is the bot's" (all fromBot (comments result))
  quiescent result
