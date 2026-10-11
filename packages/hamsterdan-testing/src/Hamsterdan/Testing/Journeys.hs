{-# LANGUAGE MultiWayIf #-}

-- | The deterministic readiness journeys of
-- @tests/integration/host/test_readiness_scenarios.py@, run through this
-- host: the @ScenarioProvider@ GitHub truth (real Git objects in a local
-- repository for the journeys that publish), the @ScenarioRunner@ agent
-- runner, and @_run_journey@'s moves, phase by phase.
--
-- A journey's outcome is the reference's @JourneyResult@ as plain JSON
-- (the shape @differential/journeys_reference.py@ prints), so the two
-- implementations' results compare byte for byte. A journey also runs in
-- spans of its phases, each span one host lifetime over the same state
-- directory: the 'Carry' a span leaves (provider, runner and the journey's
-- snapshots) is the same JSON the reference driver reads and writes, so
-- either implementation resumes the other's half.
--
-- The upstream test module draws delivery ids from @uuid.uuid4()@; here
-- they come from a counter (@00000000-0000-0000-0000-000000000001@, then
-- @...2@), the host's clock is fixed at 'clockSeconds', and the Git
-- fixtures commit at a fixed date with no global or system Git
-- configuration. The reference driver applies the same three seams.
module Hamsterdan.Testing.Journeys
  ( -- * Journeys
    Journey (..)
  , journeyName
  , journeyFromName
  , Phase (..)
  , phasesOf
  , phaseName
  , runJourney
  , driveJourney

    -- * The upstream constants
  , headSha
  , newHeadSha
  , baseSha
  , bot
  , privateKey
  , webhookSecret
  , clientSecret
  , installationToken
  , failureFingerprint
  , findingId
  , blockingFinding
  , blockingLineage
  , heroFindings
  , heroLineage
  , changeInstruction
  , updateBaseInstruction
  , resolveConflictInstruction
  , changeDiff
  , updateBaseDiff
  , conflictDiff
  , repairDiff
  , clockSeconds
  , gitDate
  ) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, unless, void, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.Agents.Protocol
  ( AgentRequest (..)
  , AgentResult (..)
  , AgentRunner (..)
  , CodingRequest (..)
  , CodingResult (..)
  , ConversationRequest (..)
  , ConversationResult (..)
  , Invocation (..)
  , ReviewRequest (..)
  , ReviewResult (..)
  , protocolError
  )
import Hamsterdan.Agents.Protocol qualified as Protocol
import Hamsterdan.Agents.Validate (ResultKind (..), throwFailure, validateResult)
import Hamsterdan.Contracts.Codec qualified as Codec
import Hamsterdan.GitHub.Config (AccountConfig (..), HostConfig (..), secret)
import Hamsterdan.GitHub.Models (InstallationInventory (..), Transport (..), WireResponse (..))
import Hamsterdan.GitHub.Routing qualified as Routing
import Hamsterdan.GitHub.Webhooks (Disposition (..), Observation (..), Receipt (..), sign)
import Hamsterdan.GitHub.Webhooks qualified as Custody
import Hamsterdan.Host.Agenticus (activateRoutes, claimRoute, closeRoutes, composeAgent, openAgentRouteStore, settleRoutes)
import Hamsterdan.Host.GitPublish (GitPublishResult (..), GitReconciliation (..), HostGitPublisher (..), hostGitPublisher, publicationAuthority)
import Hamsterdan.Host.GitPublish qualified as Git
import Hamsterdan.Host.Service
  ( AgentCustody (..)
  , ApplicationFactory
  , HostApplication (..)
  , HostClients (..)
  , HostService (..)
  , ServiceOptions (..)
  , openHostService
  , serviceOptions
  , v5ApplicationFactory
  )
import Hamsterdan.Host.Service qualified as Host
import Hamsterdan.Host.V5.Application (ApplicationOptions (..))
import Hamsterdan.Host.V5.Mutation (MutationPublisher (..))
import Petrus.Impetus.Instance.FailureText (PythonArg (..), PythonException (..))
import Petrus.Json (Json (..), defaultDumps, dumpsText)
import Petrus.Json.Encode (EncodeOptions (..))
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute, removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process.Typed (byteStringInput, proc, readProcess, setEnv, setStdin)
import Text.Printf (printf)

-- ---------------------------------------------------------------------------
-- The upstream constants

headSha, newHeadSha, baseSha, bot, privateKey, webhookSecret, clientSecret, installationToken :: Text
headSha = T.replicate 40 "a"
newHeadSha = T.replicate 40 "c"
baseSha = T.replicate 40 "b"
bot = "hamsterdan-test[bot]"
privateKey = "private-key-parity-canary"
webhookSecret = "webhook-secret-parity-canary"
clientSecret = "client-secret-parity-canary"
installationToken = "ghs_installation-parity-canary"

-- | @FAILURE_FINGERPRINT@: the digest of @[["build","failure"]]@.
failureFingerprint :: Text
failureFingerprint = TE.decodeUtf8 (Base16.encode (SHA256.hash "[[\"build\",\"failure\"]]"))

findingId :: Text
findingId = "F-mergeability-guard"

blockingFinding :: [(Text, Json)]
blockingFinding =
  [ ("id", String findingId)
  , ("path", String "src/readiness.py")
  , ("line", Int 17)
  , ("related_locations", Array [])
  , ("title", String "Keep the mergeability guard fail-closed")
  , ("body", String "This path can report ready while GitHub still reports the pull request as unmergeable.")
  , ("severity", String "high")
  , ("confidence", Float 0.99)
  , ("evidence", String "The ready branch does not test the observed mergeability flag.")
  , ("blocking", Bool True)
  , ("suggestion", String "if mergeable and all_gates_clear:")
  ]

blockingLineage :: [Json]
blockingLineage = [lineageEntry findingId "new"]

lineageEntry :: Text -> Text -> Json
lineageEntry identity state = Object [("finding_id", String identity), ("state", String state), ("supersedes", Null)]

heroFindings :: [[(Text, Json)]]
heroFindings =
  [ [ ("id", String "F-ttl-unit")
    , ("path", String "scenario-fixtures/hero_review/gate.py")
    , ("line", Int 10)
    , ("related_locations", Array [])
    , ("title", String "Lease lasts 60\x00d7 longer than requested")
    , ("body", String "The duration is supplied in seconds but applied as minutes.")
    , ("severity", String "high")
    , ("confidence", Float 0.99)
    , ("evidence", String "The lease passes ttl_seconds to timedelta(minutes=...).")
    , ("blocking", Bool True)
    , ("suggestion", String "timedelta(seconds=ttl_seconds)")
    ]
  , [ ("id", String "F-approval-policy")
    , ("path", String "scenario-fixtures/hero_review/gate.py")
    , ("line", Int 16)
    , ("related_locations", Array [])
    , ("title", String "Rejected reviews count as approvals")
    , ("body", String "The code counts every recorded review, including values explicitly marked false.")
    , ("severity", String "high")
    , ("confidence", Float 0.99)
    , ("evidence", String "The approval count tests review presence rather than its accepted value.")
    , ("blocking", Bool True)
    , ("suggestion", String "")
    ]
  , [ ("id", String "F-cache-key")
    , ("path", String "scenario-fixtures/hero_review/cache.py")
    , ("line", Int 11)
    , ("related_locations", Array [Object [("path", String "scenario-fixtures/hero_review/cache.py"), ("line", Int 6)]])
    , ("title", String "Cache lookup changes with capitalization")
    , ("body", String "Storage normalizes the repository name, but lookup does not, so one repository can produce two keys.")
    , ("severity", String "high")
    , ("confidence", Float 0.99)
    , ("evidence", String "The write path lowercases repository names while the read path uses the original spelling.")
    , ("blocking", Bool True)
    , ("suggestion", String "")
    ]
  ]

heroLineage :: [Json]
heroLineage = [lineageEntry identity "new" | Just (String identity) <- map (lookup "id") heroFindings]

changeInstruction, updateBaseInstruction, resolveConflictInstruction :: Text
changeInstruction = "Add a short usage note to README.md"
updateBaseInstruction = "Update this branch with the latest main branch"
resolveConflictInstruction = "Resolve the merge conflict with the latest main branch"

changeDiff, updateBaseDiff, conflictDiff, repairDiff :: Text
changeDiff =
  T.unlines
    [ "diff --git a/README.md b/README.md"
    , "--- a/README.md"
    , "+++ b/README.md"
    , "@@ -1 +1,3 @@"
    , " # Project"
    , "+"
    , "+Run `hamsterdan` to check pull-request readiness."
    ]
updateBaseDiff =
  T.unlines
    [ "diff --git a/BASE-NOTES.md b/BASE-NOTES.md"
    , "new file mode 100644"
    , "--- /dev/null"
    , "+++ b/BASE-NOTES.md"
    , "@@ -0,0 +1 @@"
    , "+Latest base behavior."
    ]
conflictDiff =
  T.unlines
    [ "diff --git a/src/pr_fixture/__init__.py b/src/pr_fixture/__init__.py"
    , "--- a/src/pr_fixture/__init__.py"
    , "+++ b/src/pr_fixture/__init__.py"
    , "@@ -1 +1 @@"
    , "-\"\"\"Minimal domain module for the PR-readiness laboratory fixtures.\"\"\""
    , "+\"\"\"Minimal release-qualified domain for the PR-readiness laboratory fixtures.\"\"\""
    ]
repairDiff =
  T.unlines
    [ "diff --git a/src/readiness.py b/src/readiness.py"
    , "--- a/src/readiness.py"
    , "+++ b/src/readiness.py"
    , "@@ -14,6 +14,6 @@"
    , " # Readiness must fail closed while GitHub reports unmergeable."
    , " def ready(mergeable, all_gates_clear):"
    , "     # Keep the provider guard attached to the ready branch."
    , "-    if all_gates_clear:"
    , "+    if mergeable and all_gates_clear:"
    , "         return True"
    , "     return False"
    ]

-- | The host's fixed clock (the reference driver's @CLOCK@).
clockSeconds :: Double
clockSeconds = 1786838400

-- | The fixed author and committer date of the Git fixtures.
gitDate :: String
gitDate = "2001-01-01T00:00:00Z"

-- ---------------------------------------------------------------------------
-- Journeys

-- | The eleven @run_*@ journeys.
data Journey
  = CleanGreen
  | FirstAttemptFlake
  | PersistentCiRegression
  | SeededReviewFinding
  | ConversationalChange
  | AgentRepair
  | HeroReview
  | DraftReady
  | StaleBaseUpdate
  | TrueConflictResolution
  | CollaborationApproval
  deriving stock (Eq, Show, Enum, Bounded)

journeyName :: Journey -> Text
journeyName = \case
  CleanGreen -> "clean_green"
  FirstAttemptFlake -> "first_attempt_flake"
  PersistentCiRegression -> "persistent_ci_regression"
  SeededReviewFinding -> "seeded_review_finding"
  ConversationalChange -> "conversational_change"
  AgentRepair -> "agent_repair"
  HeroReview -> "hero_review"
  DraftReady -> "draft_ready"
  StaleBaseUpdate -> "stale_base_update"
  TrueConflictResolution -> "true_conflict_resolution"
  CollaborationApproval -> "collaboration_approval"

journeyFromName :: Text -> Maybe Journey
journeyFromName name = find ((== name) . journeyName) [minBound .. maxBound]

-- | @_run_journey@'s keyword arguments.
data Flags = Flags
  { rerunConclusion :: Maybe Text
  , seededFinding :: Bool
  , conversationalChange :: Bool
  , agentRepair :: Bool
  , heroReview :: Bool
  , draftReady :: Bool
  , updateBase :: Bool
  , resolveConflict :: Bool
  , collaboration :: Bool
  }

flagsOf :: Journey -> Flags
flagsOf journey =
  Flags
    { rerunConclusion = case journey of
        FirstAttemptFlake -> Just "success"
        PersistentCiRegression -> Just "failure"
        AgentRepair -> Just "failure"
        _ -> Nothing
    , seededFinding = journey == SeededReviewFinding
    , conversationalChange = journey == ConversationalChange
    , agentRepair = journey == AgentRepair
    , heroReview = journey == HeroReview
    , draftReady = journey == DraftReady
    , updateBase = journey == StaleBaseUpdate
    , resolveConflict = journey == TrueConflictResolution
    , collaboration = journey == CollaborationApproval
    }

baseMutation :: Flags -> Bool
baseMutation flags = flags.updateBase || flags.resolveConflict

-- | The journeys that publish through the real Git publisher.
repairing :: Flags -> Bool
repairing flags = flags.agentRepair || baseMutation flags

-- | One of @_run_journey@'s spans between convergences.
data Phase = Open | Draft | StaleBase | Collaboration | FollowUp
  deriving stock (Eq, Show)

phaseName :: Phase -> Text
phaseName = \case
  Open -> "open"
  Draft -> "draft"
  StaleBase -> "stale_base"
  Collaboration -> "collaboration"
  FollowUp -> "follow_up"

-- | The journey's phases in @_run_journey@'s order.
phasesOf :: Journey -> [Phase]
phasesOf journey =
  [Open]
    <> [Draft | flags.draftReady]
    <> [StaleBase | baseMutation flags]
    <> [Collaboration | flags.collaboration]
    <> [FollowUp]
  where
    flags = flagsOf journey

-- ---------------------------------------------------------------------------
-- Failures

assertionError :: Text -> IO a
assertionError message = throwIO (PythonException "AssertionError" [PyStr message])

check :: Bool -> Text -> IO ()
check ok message = unless ok (assertionError message)

-- ---------------------------------------------------------------------------
-- JSON

member :: Text -> Json -> Json
member key = \case
  Object members -> fromMaybe Null (lookup key members)
  _ -> Null

-- | The array element at an index ('Null' when absent).
member' :: Int -> Json -> Json
member' index = \case
  Array values | index >= 0, (value : _) <- drop index values -> value
  _ -> Null

textOf :: Json -> Text
textOf = \case
  String value -> value
  Null -> "None"
  other -> canonical other

-- | @json.dumps(value, sort_keys=True)@.
canonical :: Json -> Text
canonical value = either (error . show) id (dumpsText defaultDumps {sortKeys = True} value)

-- | @json.dumps(value)@ as bytes.
pythonDumps :: Json -> ByteString
pythonDumps value = TE.encodeUtf8 (either (error . show) id (dumpsText defaultDumps value))

maybeText :: Maybe Text -> Json
maybeText = maybe Null String

texts :: [Text] -> Json
texts = Array . map String

-- ---------------------------------------------------------------------------
-- The provider's truth

-- | @ScenarioProvider@'s state, field for field.
data ProviderState = ProviderState
  { head :: Text
  , base :: Text
  , state :: Text
  , draft :: Bool
  , merged :: Bool
  , mergeable :: Bool
  , mergeableState :: Text
  , rerunConclusion :: Maybe Text
  , runId :: Integer
  , runAttempt :: Integer
  , runStatus :: Text
  , runConclusion :: Maybe Text
  , rerunRequests :: Integer
  , behindBy :: Integer
  , gitReconciliations :: [Json]
  , gitPublications :: [Json]
  , comments :: [Json]
  , reviewComments :: [Json]
  , requestedReviewers :: [Text]
  , humanReviews :: [Json]
  , reviewThreads :: [Bool]
  , casUpdates :: [Json]
  , gitBoundaryEvents :: [Json]
  , createdGitObjects :: Set.Set Text
  , calls :: [Json]
  , requests :: [Json]
  , writes :: [Json]
  , gitWork :: Maybe FilePath
  , gitRemote :: Maybe FilePath
  }

-- | @ScenarioProvider(rerun_conclusion=, head=, base=, git_work=, git_remote=)@.
newProviderState :: Maybe Text -> Text -> Text -> Maybe FilePath -> Maybe FilePath -> ProviderState
newProviderState rerunConclusion headValue baseValue gitWork gitRemote =
  ProviderState
    { head = headValue
    , base = baseValue
    , state = "open"
    , draft = False
    , merged = False
    , mergeable = True
    , mergeableState = "clean"
    , rerunConclusion
    , runId = 101
    , runAttempt = 1
    , runStatus = "completed"
    , runConclusion = Just (if isJust rerunConclusion then "failure" else "success")
    , rerunRequests = 0
    , behindBy = 0
    , gitReconciliations = []
    , gitPublications = []
    , comments = []
    , reviewComments = []
    , requestedReviewers = []
    , humanReviews =
        [ Object
            [ ("id", Int 301)
            , ("submitted_at", String "2026-08-16T00:00:00Z")
            , ("state", String "APPROVED")
            , ("user", Object [("login", String "reviewer")])
            ]
        ]
    , reviewThreads = [True]
    , casUpdates = []
    , gitBoundaryEvents = []
    , createdGitObjects = Set.empty
    , calls = []
    , requests = []
    , writes = []
    , gitWork
    , gitRemote
    }

providerJson :: ProviderState -> Json
providerJson p =
  Object
    [ ("head", String p.head)
    , ("base", String p.base)
    , ("state", String p.state)
    , ("draft", Bool p.draft)
    , ("merged", Bool p.merged)
    , ("mergeable", Bool p.mergeable)
    , ("mergeable_state", String p.mergeableState)
    , ("rerun_conclusion", maybeText p.rerunConclusion)
    , ("run_id", Int p.runId)
    , ("run_attempt", Int p.runAttempt)
    , ("run_status", String p.runStatus)
    , ("run_conclusion", maybeText p.runConclusion)
    , ("rerun_requests", Int p.rerunRequests)
    , ("behind_by", Int p.behindBy)
    , ("git_reconciliations", Array p.gitReconciliations)
    , ("git_publications", Array p.gitPublications)
    , ("comments", Array p.comments)
    , ("review_comments", Array p.reviewComments)
    , ("requested_reviewers", texts p.requestedReviewers)
    , ("human_reviews", Array p.humanReviews)
    , ("review_threads", Array (map Bool p.reviewThreads))
    , ("cas_updates", Array p.casUpdates)
    , ("git_boundary_events", Array p.gitBoundaryEvents)
    , ("created_git_objects", texts (Set.toAscList p.createdGitObjects))
    , ("calls", Array p.calls)
    , ("requests", Array p.requests)
    , ("writes", Array p.writes)
    , ("git_work", maybe Null (String . T.pack) p.gitWork)
    , ("git_remote", maybe Null (String . T.pack) p.gitRemote)
    ]

providerFromJson :: Json -> ProviderState
providerFromJson value =
  ProviderState
    { head = textOf (at "head")
    , base = textOf (at "base")
    , state = textOf (at "state")
    , draft = bool (at "draft")
    , merged = bool (at "merged")
    , mergeable = bool (at "mergeable")
    , mergeableState = textOf (at "mergeable_state")
    , rerunConclusion = optional (at "rerun_conclusion")
    , runId = int (at "run_id")
    , runAttempt = int (at "run_attempt")
    , runStatus = textOf (at "run_status")
    , runConclusion = optional (at "run_conclusion")
    , rerunRequests = int (at "rerun_requests")
    , behindBy = int (at "behind_by")
    , gitReconciliations = items (at "git_reconciliations")
    , gitPublications = items (at "git_publications")
    , comments = items (at "comments")
    , reviewComments = items (at "review_comments")
    , requestedReviewers = map textOf (items (at "requested_reviewers"))
    , humanReviews = items (at "human_reviews")
    , reviewThreads = map bool (items (at "review_threads"))
    , casUpdates = items (at "cas_updates")
    , gitBoundaryEvents = items (at "git_boundary_events")
    , createdGitObjects = Set.fromList (map textOf (items (at "created_git_objects")))
    , calls = items (at "calls")
    , requests = items (at "requests")
    , writes = items (at "writes")
    , gitWork = T.unpack <$> optional (at "git_work")
    , gitRemote = T.unpack <$> optional (at "git_remote")
    }
  where
    at key = member key value

bool :: Json -> Bool
bool = \case
  Bool b -> b
  _ -> False

int :: Json -> Integer
int = \case
  Int n -> n
  _ -> 0

optional :: Json -> Maybe Text
optional = \case
  String s -> Just s
  _ -> Nothing

items :: Json -> [Json]
items = \case
  Array xs -> xs
  _ -> []

-- | The provider: its truth, and the Git environment its object writes use.
data Provider = Provider
  { truth :: IORef ProviderState
  , environment :: [(String, String)]
  }

-- | @ScenarioProvider.pages(path)@.
providerPages :: Provider -> Text -> IO [[(Text, Json)]]
providerPages provider path = do
  modifyIORef' provider.truth (\p -> p {calls = p.calls <> [texts ["PAGES", path]]})
  p <- readIORef provider.truth
  let objects xs = [members | Object members <- xs]
  case path of
    "/repos/owner/repo/issues/7/comments?per_page=100" -> pure (objects p.comments)
    "/repos/owner/repo/pulls/7/comments?per_page=100" -> pure (objects p.reviewComments)
    "/repos/owner/repo/pulls/7/reviews?per_page=100" -> pure (objects p.humanReviews)
    _ -> assertionError ("unexpected provider pages request: " <> path)

-- | @ScenarioProvider.request(method, path, body)@.
providerRequest :: Provider -> Text -> Text -> Maybe [(Text, Json)] -> IO WireResponse
providerRequest provider method path body = do
  let bodyText = maybe "" (canonical . Object) body
  modifyIORef' provider.truth $ \p ->
    p {calls = p.calls <> [texts [method, path]], requests = p.requests <> [texts [method, path, bodyText]]}
  p <- readIORef provider.truth
  let ok value = pure (WireResponse 200 value Nothing)
      created value = pure (WireResponse 201 value Nothing)
      query = maybe "" (textOf . fromMaybe Null . lookup "query") body
      isGraphQL = method == "POST" && path == "/graphql" && isJust body
  if
    | method == "GET" && path == "/repos/owner/repo/pulls/7" ->
        ok $
          Object
            [ ("state", String p.state)
            , ("draft", Bool p.draft)
            , ("mergeable", Bool p.mergeable)
            , ("mergeable_state", String p.mergeableState)
            , ("merged", Bool p.merged)
            , ("html_url", String "https://github.com/owner/repo/pull/7")
            , ("user", Object [("login", String "author")])
            , ("head", Object [("sha", String p.head), ("ref", String "feature"), ("repo", Object [("full_name", String "owner/repo")])])
            , ("base", Object [("sha", String p.base), ("ref", String "main")])
            ]
    | method == "GET" && path == "/repos/owner/repo/git/ref/heads/main" -> ok (Object [("object", Object [("sha", String p.base)])])
    | method == "GET" && path == "/repos/owner/repo/rules/branches/main" ->
        ok $
          Array
            [ Object
                [ ("type", String "required_status_checks")
                , ( "parameters"
                  , Object
                      [ ("strict_required_status_checks_policy", Bool True)
                      , ("required_status_checks", Array [Object [("context", String "build")]])
                      ]
                  )
                ]
            , Object
                [ ("type", String "pull_request")
                , ( "parameters"
                  , Object [("required_approving_review_count", Int 1), ("required_review_thread_resolution", Bool True)]
                  )
                ]
            ]
    | method == "GET" && path == "/repos/owner/repo/compare/" <> p.base <> "..." <> p.head ->
        ok (Object [("status", String "ahead"), ("behind_by", Int p.behindBy)])
    | method == "GET" && path == "/repos/owner/repo/pulls/7/requested_reviewers" ->
        ok (Object [("users", Array [Object [("login", String login)] | login <- p.requestedReviewers])])
    | method == "GET"
        && path
          == "/repos/owner/repo/actions/workflows/.github%2Fworkflows%2Fci.yml/runs?event=pull_request&head_sha="
            <> p.head
            <> "&per_page=20" ->
        ok $
          Object
            [ ("total_count", Int 1)
            ,
              ( "workflow_runs"
              , Array
                  [ Object
                      [ ("id", Int p.runId)
                      , ("run_attempt", Int p.runAttempt)
                      , ("head_sha", String p.head)
                      , ("event", String "pull_request")
                      , ("path", String ".github/workflows/ci.yml")
                      , ("status", String p.runStatus)
                      , ("conclusion", maybeText p.runConclusion)
                      , ("pull_requests", Array [Object [("number", Int 7)]])
                      ]
                  ]
              )
            ]
    | method == "GET"
        && path == "/repos/owner/repo/actions/runs/" <> showT p.runId <> "/attempts/" <> showT p.runAttempt <> "/jobs?per_page=100" ->
        ok $
          Object
            [ ("total_count", Int 1)
            ,
              ( "jobs"
              , Array
                  [ Object
                      [ ("id", Int (200 + p.runAttempt))
                      , ("name", String "build")
                      , ("status", String p.runStatus)
                      , ("conclusion", maybeText p.runConclusion)
                      ]
                  ]
              )
            ]
    | isGraphQL && "reviewThreads" `T.isInfixOf` query ->
        ok $
          Object
            [ ( "data"
              , Object
                  [ ( "repository"
                    , Object
                        [ ( "pullRequest"
                          , Object
                              [ ( "reviewThreads"
                                , Object
                                    [ ("nodes", Array [Object [("id", String ("thread-" <> showT index)), ("isResolved", Bool resolved)] | (index, resolved) <- zip [1 :: Integer ..] p.reviewThreads])
                                    , ("pageInfo", Object [("hasNextPage", Bool False), ("endCursor", Null)])
                                    ]
                                )
                              ]
                          )
                        ]
                    )
                  ]
              )
            ]
    | method == "POST" && "/repos/owner/repo/git/" `T.isPrefixOf` path, Just members <- body -> gitObject provider path members
    | isGraphQL && "repository(owner" `T.isInfixOf` query -> do
        check
          (maybe Null id (body >>= lookup "variables") == Object [("owner", String "owner"), ("repository", String "repo")])
          "repository lookup variables"
        ok (Object [("data", Object [("repository", Object [("id", String "R_owner_repo")])])])
    | isGraphQL && "updateRefs" `T.isInfixOf` query -> updateRefs provider (member "input" (fromMaybe Null (body >>= lookup "variables")))
    | method == "POST" && path == "/repos/owner/repo/issues/7/comments", Just members <- body -> do
        let identifier = toInteger (length p.comments) + 1
            comment =
              [ ("id", Int identifier)
              , ("html_url", String ("https://github.com/owner/repo/pull/7#issuecomment-" <> showT identifier))
              , ("body", fromMaybe (String "") (lookup "body" members))
              , ("user", Object [("login", String bot)])
              ]
            bodyValue = textOf (fromMaybe Null (lookup "body" comment))
        modifyIORef' provider.truth $ \q ->
          q
            { comments = q.comments <> [Object comment]
            , writes = q.writes <> [Array [String method, String path, Int identifier, String bodyValue]]
            , rerunRequests = q.rerunRequests + (if "<!-- hamsterdan-rerun " `T.isInfixOf` bodyValue then 1 else 0)
            }
        created (Object comment)
    | method == "POST" && path == "/repos/owner/repo/pulls/7/reviews", Just members <- body -> do
        let reviewId = 2000 + toInteger (length p.humanReviews) + 1
            inline = [item | Object item <- items (fromMaybe (Array []) (lookup "comments" members))]
            reviewComment offset item =
              let n = toInteger (length p.reviewComments) + offset
               in [ ("id", Int (1000 + n))
                  , ("html_url", String ("https://github.com/owner/repo/pull/7#discussion_r" <> showT n))
                  , ("body", fromMaybe (String "") (lookup "body" item))
                  , ("user", Object [("login", String bot)])
                  , ("commit_id", fromMaybe Null (lookup "commit_id" members))
                  , ("path", fromMaybe Null (lookup "path" item))
                  , ("line", fromMaybe Null (lookup "line" item))
                  , ("side", fromMaybe Null (lookup "side" item))
                  , ("pull_request_review_id", Int reviewId)
                  ]
            posted = zipWith reviewComment [1 ..] inline
            review =
              [ ("id", Int reviewId)
              , ("html_url", String ("https://github.com/owner/repo/pull/7#pullrequestreview-" <> showT reviewId))
              , ("submitted_at", String "2026-08-16T00:00:01Z")
              , ("state", String "COMMENTED")
              , ("user", Object [("login", String bot)])
              ]
        modifyIORef' provider.truth $ \q ->
          q
            { reviewComments = q.reviewComments <> map Object posted
            , writes = q.writes <> [Array [String method, String path, member "id" (Object c), String (textOf (member "body" (Object c)))] | c <- posted]
            , humanReviews = q.humanReviews <> [Object review]
            }
        ok (Object review)
    | method == "POST" && path == "/repos/owner/repo/pulls/7/comments", Just members <- body -> do
        let n = toInteger (length p.reviewComments) + 1
            comment =
              [ ("id", Int (1000 + n))
              , ("html_url", String ("https://github.com/owner/repo/pull/7#discussion_r" <> showT n))
              , ("body", fromMaybe (String "") (lookup "body" members))
              , ("user", Object [("login", String bot)])
              , ("commit_id", fromMaybe Null (lookup "commit_id" members))
              , ("path", fromMaybe Null (lookup "path" members))
              , ("line", fromMaybe Null (lookup "line" members))
              , ("side", fromMaybe Null (lookup "side" members))
              ]
        modifyIORef' provider.truth $ \q ->
          q
            { reviewComments = q.reviewComments <> [Object comment]
            , writes = q.writes <> [Array [String method, String path, Int (1000 + n), String (textOf (member "body" (Object comment)))]]
            }
        created (Object comment)
    | method == "PATCH", Just identifierText <- T.stripPrefix "/repos/owner/repo/issues/comments/" path, Just members <- body -> do
        let identifier = Int (read (T.unpack identifierText))
            newBody = fromMaybe (String "") (lookup "body" members)
            edit = \case
              Object comment | lookup "id" comment == Just identifier -> Object [(k, if k == "body" then newBody else v) | (k, v) <- comment]
              other -> other
        found <- case find (\c -> member "id" c == identifier) p.comments of
          Just _ -> pure ()
          Nothing -> throwIO (PythonException "StopIteration" [])
        void (pure found)
        modifyIORef' provider.truth $ \q ->
          q {comments = map edit q.comments, writes = q.writes <> [Array [String method, String path, identifier, String (textOf newBody)]]}
        q <- readIORef provider.truth
        case find (\c -> member "id" c == identifier) q.comments of
          Just comment -> ok comment
          Nothing -> throwIO (PythonException "StopIteration" [])
    | otherwise -> assertionError ("unexpected provider request: " <> method <> " " <> path)

showT :: (Show a) => a -> Text
showT = T.pack . show

-- | The Git object API: real objects in the fixture's work repository.
gitObject :: Provider -> Text -> [(Text, Json)] -> IO WireResponse
gitObject provider path body = do
  p <- readIORef provider.truth
  work <- maybe (assertionError "this journey forbids Git object creation") pure p.gitWork
  modifyIORef' provider.truth (\q -> q {gitBoundaryEvents = q.gitBoundaryEvents <> [Object [("kind", String "object"), ("path", String path)]]})
  let at key = fromMaybe Null (lookup key body)
  createdSha <-
    if
      | "/blobs" `T.isSuffixOf` path -> do
          let content = either (const "") id (Base64.decode (TE.encodeUtf8 (textOf (at "content"))))
          gitIn provider.environment work ["hash-object", "-w", "--stdin"] content
      | "/trees" `T.isSuffixOf` path -> do
          let index = work </> ".git" </> "parity-publication-index"
              environment = ("GIT_INDEX_FILE", index) : filter ((/= "GIT_INDEX_FILE") . fst) provider.environment
          exists <- doesFileExist index
          when exists (removeFile index)
          void (gitIn environment work ["read-tree", T.unpack (textOf (at "base_tree"))] "")
          forM_ (items (at "tree")) $ \entry ->
            gitIn
              environment
              work
              ["update-index", "--add", "--cacheinfo", T.unpack (textOf (member "mode" entry) <> "," <> textOf (member "sha" entry) <> "," <> textOf (member "path" entry))]
              ""
          tree <- gitIn environment work ["write-tree"] ""
          removeFile index
          pure tree
      | "/commits" `T.isSuffixOf` path -> do
          let person key = at key
              environment =
                overriding
                  provider.environment
                  [ ("GIT_AUTHOR_NAME", T.unpack (textOf (member "name" (person "author"))))
                  , ("GIT_AUTHOR_EMAIL", T.unpack (textOf (member "email" (person "author"))))
                  , ("GIT_COMMITTER_NAME", T.unpack (textOf (member "name" (person "committer"))))
                  , ("GIT_COMMITTER_EMAIL", T.unpack (textOf (member "email" (person "committer"))))
                  , ("GIT_AUTHOR_DATE", gitDate)
                  , ("GIT_COMMITTER_DATE", gitDate)
                  ]
              parents = concat [["-p", T.unpack (textOf parent)] | parent <- items (at "parents")]
          gitIn environment work (["commit-tree", T.unpack (textOf (at "tree"))] <> parents) (TE.encodeUtf8 (textOf (at "message")))
      | otherwise -> assertionError ("unexpected Git object request: " <> path)
  modifyIORef' provider.truth (\q -> q {createdGitObjects = Set.insert createdSha q.createdGitObjects})
  pure (WireResponse 201 (Object [("sha", String createdSha)]) Nothing)

-- | The @updateRefs@ mutation: the exact compare-and-swap, pushed to the
-- fixture's remote.
updateRefs :: Provider -> Json -> IO WireResponse
updateRefs provider values = do
  p <- readIORef provider.truth
  (work, remote) <- case (p.gitWork, p.gitRemote) of
    (Just w, Just r) -> pure (w, r)
    _ -> assertionError "this journey forbids ref mutation"
  update <- case items (member "refUpdates" values) of
    [one] -> pure one
    _ -> assertionError "exactly one ref update"
  let after = textOf (member "afterOid" update)
      name = textOf (member "name" update)
  check (member "repositoryId" values == String "R_owner_repo") "repository id"
  check (member "name" update == String "refs/heads/feature" && member "force" update == Bool False) "ref update shape"
  check (member "beforeOid" update == String p.head) "ref update lease"
  check (Set.member after p.createdGitObjects) "ref update target"
  current <- gitIn provider.environment remote ["rev-parse", "refs/heads/feature"] ""
  check (current == p.head) "remote ref"
  void (gitIn provider.environment work ["push", "-q", remote, T.unpack (after <> ":" <> name)] "")
  let client = member "clientMutationId" values
  modifyIORef' provider.truth $ \q ->
    q
      { casUpdates = q.casUpdates <> [Object [("before", member "beforeOid" update), ("after", String after), ("client", String (textOf client))]]
      , gitBoundaryEvents = q.gitBoundaryEvents <> [Object [("kind", String "cas"), ("before", String q.head), ("after", String after)]]
      , head = after
      , behindBy = 0
      , mergeable = True
      , mergeableState = "clean"
      , runId = 102
      , runAttempt = 1
      , runStatus = "completed"
      , runConclusion = Just "success"
      }
  pure (WireResponse 200 (Object [("data", Object [("updateRefs", Object [("clientMutationId", client)])])]) Nothing)

-- | @complete_rerun()@.
completeRerun :: IORef ProviderState -> IO ()
completeRerun ref = do
  p <- readIORef ref
  check (isJust p.rerunConclusion && p.rerunRequests == 1) "attempt 2 requires exactly one proven rerun request"
  check (p.runAttempt == 1 && p.runConclusion == Just "failure") "only failed attempt 1 can advance to the rerun outcome"
  writeIORef ref p {runAttempt = 2, runStatus = "completed", runConclusion = p.rerunConclusion}

providerTransport :: Provider -> Transport
providerTransport provider = Transport {request = providerRequest provider, pages = providerPages provider}

-- ---------------------------------------------------------------------------
-- Git

-- | The process environment with the fixtures' determinism: a fixed
-- date, and no global or system configuration.
gitEnvironment :: IO [(String, String)]
gitEnvironment = do
  inherited <- getEnvironment
  pure $
    overriding
      inherited
      [ ("GIT_AUTHOR_DATE", gitDate)
      , ("GIT_COMMITTER_DATE", gitDate)
      , ("GIT_CONFIG_GLOBAL", "/dev/null")
      , ("GIT_CONFIG_NOSYSTEM", "1")
      ]

overriding :: [(String, String)] -> [(String, String)] -> [(String, String)]
overriding base extra = filter ((`notElem` map fst extra) . fst) base <> extra

-- | @git -C root arguments@ with the given standard input: the stripped
-- standard output.
gitIn :: [(String, String)] -> FilePath -> [String] -> ByteString -> IO Text
gitIn environment root arguments input = gitRun environment (["-C", root] <> arguments) input

gitRun :: [(String, String)] -> [String] -> ByteString -> IO Text
gitRun environment arguments input = do
  (status, out, err) <- readProcess (setEnv environment (setStdin (byteStringInput (BL.fromStrict input)) (proc "git" arguments)))
  unless (status == ExitSuccess) $
    throwIO (PythonException "CalledProcessError" [PyStr (T.pack (unwords ("git" : arguments))), PyStr (TE.decodeUtf8 (BL.toStrict err))])
  pure (T.strip (TE.decodeUtf8 (BL.toStrict out)))

git :: [(String, String)] -> FilePath -> [String] -> IO Text
git environment root arguments = gitIn environment root arguments ""

-- | @repair_repository(root)@: the work clone, the bare remote, and the
-- base and head commits.
repairRepository :: [(String, String)] -> FilePath -> IO (FilePath, FilePath, Text, Text)
repairRepository environment root = do
  createDirectoryIfMissing True root
  let remote = root </> "remote.git"
      work = root </> "work"
  void (gitRun environment ["init", "--bare", "-q", remote] "")
  void (gitRun environment ["clone", "-q", remote, work] "")
  void (git environment work ["config", "user.name", "Parity Test"])
  void (git environment work ["config", "user.email", "parity@example.invalid"])
  BS.writeFile (work </> "README.md") "# Project\n"
  void (git environment work ["add", "README.md"])
  void (git environment work ["commit", "-qm", "base"])
  baseCommit <- git environment work ["rev-parse", "HEAD"]
  void (git environment work ["push", "-q", "origin", "HEAD:refs/heads/main"])
  createDirectoryIfMissing False (work </> "src")
  BS.writeFile (work </> "src" </> "readiness.py") . TE.encodeUtf8 $
    T.concat ["# Fixture context " <> showT line <> "\n" | line <- [1 :: Int .. 13]]
      <> "# Readiness must fail closed while GitHub reports unmergeable.\n"
      <> "def ready(mergeable, all_gates_clear):\n"
      <> "    # Keep the provider guard attached to the ready branch.\n"
      <> "    if all_gates_clear:\n"
      <> "        return True\n"
      <> "    return False\n"
  void (git environment work ["add", "src/readiness.py"])
  void (git environment work ["commit", "-qm", "seed failing behavior"])
  headCommit <- git environment work ["rev-parse", "HEAD"]
  void (git environment work ["push", "-q", "origin", "HEAD:refs/heads/feature"])
  pure (work, remote, baseCommit, headCommit)

-- | @advance_base_repository(work, remote, base, head)@.
advanceBaseRepository :: [(String, String)] -> FilePath -> FilePath -> Text -> Text -> IO Text
advanceBaseRepository environment work remote baseCommit headCommit = do
  void (git environment work ["checkout", "-q", "--detach", T.unpack baseCommit])
  BS.writeFile (work </> "BASE-NOTES.md") "Latest base behavior.\n"
  void (git environment work ["add", "BASE-NOTES.md"])
  void (git environment work ["commit", "-qm", "base: advance independently"])
  advanced <- git environment work ["rev-parse", "HEAD"]
  void (git environment work ["push", "-q", remote, T.unpack (advanced <> ":refs/heads/main")])
  void (git environment work ["checkout", "-q", "--detach", T.unpack headCommit])
  pure advanced

-- | @conflict_repository(root)@.
conflictRepository :: [(String, String)] -> FilePath -> IO (FilePath, FilePath, Text, Text)
conflictRepository environment root = do
  createDirectoryIfMissing True root
  let remote = root </> "remote.git"
      work = root </> "work"
      fixture = work </> "src" </> "pr_fixture" </> "__init__.py"
  void (gitRun environment ["init", "--bare", "-q", remote] "")
  void (gitRun environment ["clone", "-q", remote, work] "")
  void (git environment work ["config", "user.name", "Parity Test"])
  void (git environment work ["config", "user.email", "parity@example.invalid"])
  createDirectoryIfMissing True (work </> "src" </> "pr_fixture")
  BS.writeFile fixture "\"\"\"Tiny domain used by the PR-readiness laboratory.\"\"\"\n"
  void (git environment work ["add", "src/pr_fixture/__init__.py"])
  void (git environment work ["commit", "-qm", "base"])
  baseCommit <- git environment work ["rev-parse", "HEAD"]
  void (git environment work ["push", "-q", "origin", "HEAD:refs/heads/main"])
  BS.writeFile fixture "\"\"\"Minimal domain module for the PR-readiness laboratory fixtures.\"\"\"\n"
  void (git environment work ["commit", "-qam", "feature: customize domain"])
  headCommit <- git environment work ["rev-parse", "HEAD"]
  void (git environment work ["push", "-q", "origin", "HEAD:refs/heads/feature"])
  pure (work, remote, baseCommit, headCommit)

-- | @advance_conflicting_base_repository(work, remote, base, head)@.
advanceConflictingBaseRepository :: [(String, String)] -> FilePath -> FilePath -> Text -> Text -> IO Text
advanceConflictingBaseRepository environment work remote baseCommit headCommit = do
  void (git environment work ["checkout", "-q", "--detach", T.unpack baseCommit])
  BS.writeFile (work </> "src" </> "pr_fixture" </> "__init__.py") "\"\"\"Tiny domain used by the PR-readiness laboratory and release qualification.\"\"\"\n"
  void (git environment work ["commit", "-qam", "base: change domain incompatibly"])
  advanced <- git environment work ["rev-parse", "HEAD"]
  void (git environment work ["push", "-q", remote, T.unpack (advanced <> ":refs/heads/main")])
  merged <- mergeTree environment work [T.unpack baseCommit, T.unpack headCommit, T.unpack advanced]
  check ("<<<<<<<" `T.isInfixOf` merged) "the advanced base conflicts"
  void (git environment work ["checkout", "-q", "--detach", T.unpack headCommit])
  pure advanced

-- | @git merge-tree base head advanced@ (the legacy three-way form, which
-- exits zero).
mergeTree :: [(String, String)] -> FilePath -> [String] -> IO Text
mergeTree environment work arguments = git environment work ("merge-tree" : arguments)

-- ---------------------------------------------------------------------------
-- The agent runner

-- | @ScenarioRunner@'s state, field for field.
data RunnerState = RunnerState
  { reviewEntries :: Integer
  , reviews :: [Json]
  , reviewResults :: [Json]
  , conversationCalls :: [Json]
  , conversationResults :: [Json]
  , codeCalls :: [Json]
  , codeResults :: [Json]
  , codingStatus :: Maybe Text
  , seededFinding :: Bool
  , conversationalChange :: Bool
  , updateBase :: Bool
  , resolveConflict :: Bool
  , findingHead :: Maybe Text
  , reviewFindings :: [[(Text, Json)]]
  , codes :: Integer
  , conversations :: Integer
  }

runnerJson :: RunnerState -> Json
runnerJson r =
  Object
    [ ("review_entries", Int r.reviewEntries)
    , ("reviews", Array r.reviews)
    , ("review_results", Array r.reviewResults)
    , ("conversation_calls", Array r.conversationCalls)
    , ("conversation_results", Array r.conversationResults)
    , ("code_calls", Array r.codeCalls)
    , ("code_results", Array r.codeResults)
    , ("coding_status", maybeText r.codingStatus)
    , ("seeded_finding", Bool r.seededFinding)
    , ("conversational_change", Bool r.conversationalChange)
    , ("update_base", Bool r.updateBase)
    , ("resolve_conflict", Bool r.resolveConflict)
    , ("finding_head", maybeText r.findingHead)
    , ("review_findings", Array (map Object r.reviewFindings))
    , ("codes", Int r.codes)
    , ("conversations", Int r.conversations)
    ]

runnerFromJson :: Json -> RunnerState
runnerFromJson value =
  RunnerState
    { reviewEntries = int (at "review_entries")
    , reviews = items (at "reviews")
    , reviewResults = items (at "review_results")
    , conversationCalls = items (at "conversation_calls")
    , conversationResults = items (at "conversation_results")
    , codeCalls = items (at "code_calls")
    , codeResults = items (at "code_results")
    , codingStatus = optional (at "coding_status")
    , seededFinding = bool (at "seeded_finding")
    , conversationalChange = bool (at "conversational_change")
    , updateBase = bool (at "update_base")
    , resolveConflict = bool (at "resolve_conflict")
    , findingHead = optional (at "finding_head")
    , reviewFindings = [members | Object members <- items (at "review_findings")]
    , codes = int (at "codes")
    , conversations = int (at "conversations")
    }
  where
    at key = member key value

call :: Text -> Json -> Text -> Integer -> Json
call url request operation attempt = Array [String url, request, String operation, Int attempt]

-- | @ScenarioRunner@ as the host's agent runner.
scenarioRunner :: IORef RunnerState -> AgentRunner
scenarioRunner ref =
  AgentRunner
    { review = \url request invocation -> do
        modifyIORef' ref (\r -> r {reviewEntries = r.reviewEntries + 1})
        current <- maybe (pure True) id invocation.isCurrent
        unless current $ throwIO (protocolError "review authority moved") {Protocol.canceled = True}
        modifyIORef' ref (\r -> r {reviews = r.reviews <> [call url (Codec.dump request) invocation.operation invocation.attempt]})
        r <- readIORef ref
        let findingOpen = r.seededFinding && maybe True (== request.head) r.findingHead
        when (isJust r.findingHead) $
          if findingOpen
            then check (null request.priorFindings && null request.appliedChanges) "no prior findings on the first review"
            else do
              prior <- case request.priorFindings of
                [one] -> pure one
                _ -> assertionError "exactly one prior finding"
              check (all (\(key, value) -> lookup key prior == Just value) blockingFinding) "the prior finding is the blocking finding"
              check (map Object request.appliedChanges == blockingLineage) "the applied changes are the blocking lineage"
        let lineage state = [lineageEntry identity state | Just (String identity) <- map (lookup "id") r.reviewFindings]
            proposed =
              ReviewResult
                { repository = request.repository
                , pullRequest = request.pullRequest
                , epoch = request.epoch
                , head = request.head
                , base = request.base
                , status = if findingOpen then "blocking" else "clear"
                , findings = if findingOpen then r.reviewFindings else []
                , lineage =
                    [ members
                    | Object members <-
                        if findingOpen then lineage "new" else if r.seededFinding then lineage "resolved" else []
                    ]
                }
        result <- case validateResult KindReview (Codec.dump proposed) (AgentReview request) Nothing of
          Right (ResultReview validated) -> pure validated
          Right _ -> assertionError "a review result"
          Left failure -> throwFailure failure
        modifyIORef' ref (\q -> q {reviewResults = q.reviewResults <> [Codec.dump result]})
        pure result
    , code = \url request invocation -> do
        modifyIORef' ref $ \r ->
          r {codes = r.codes + 1, codeCalls = r.codeCalls <> [call url (Codec.dump request) invocation.operation invocation.attempt]}
        current <- maybe (pure True) id invocation.isCurrent
        check current "the coding authority is current"
        r <- readIORef ref
        result <- case r.codingStatus of
          Nothing -> assertionError "this parity journey must not invoke a coding agent"
          Just "changed" -> do
            let repair = request.kind == "repair"
                (diff, changedFiles, command, message)
                  | repair = (repairDiff, ["src/readiness.py"], "repair-check", "fix: repair seeded failure")
                  | r.resolveConflict = (conflictDiff, ["src/pr_fixture/__init__.py"], "conflict-check", "merge: resolve feature and main conflict")
                  | r.updateBase = (updateBaseDiff, ["BASE-NOTES.md"], "base-check", "merge: update feature from main")
                  | otherwise = (changeDiff, ["README.md"], "readme-check", "docs: add usage note")
            pure
              CodingResult
                { kind = request.kind
                , repository = request.repository
                , pullRequest = request.pullRequest
                , epoch = request.epoch
                , head = request.head
                , base = request.base
                , ref = request.ref
                , status = "changed"
                , reproductionStatus = if repair then "confirmed" else "not_attempted"
                , diff
                , changedFiles
                , validationEvidence = [[("command", String command), ("outcome", String "passed")]]
                , proposedCommitMessage = message
                }
          Just status ->
            pure
              CodingResult
                { kind = request.kind
                , repository = request.repository
                , pullRequest = request.pullRequest
                , epoch = request.epoch
                , head = request.head
                , base = request.base
                , ref = request.ref
                , status
                , reproductionStatus = if request.kind == "repair" then "reproduced" else "not_attempted"
                , diff = ""
                , changedFiles = []
                , validationEvidence = []
                , proposedCommitMessage = ""
                }
        modifyIORef' ref (\q -> q {codeResults = q.codeResults <> [Codec.dump result]})
        pure result
    , converse = \url request invocation -> do
        modifyIORef' ref $ \r ->
          r
            { conversations = r.conversations + 1
            , conversationCalls = r.conversationCalls <> [call url (Codec.dump request) invocation.operation invocation.attempt]
            }
        current <- maybe (pure True) id invocation.isCurrent
        check current "the conversation authority is current"
        r <- readIORef ref
        unless (r.conversationalChange || r.updateBase || r.resolveConflict) $
          assertionError "this parity journey must not invoke a conversation agent"
        let (kind, instruction)
              | r.resolveConflict = ("resolve_conflict", resolveConflictInstruction)
              | r.updateBase = ("update_base", updateBaseInstruction)
              | otherwise = ("change", changeInstruction)
            result =
              ConversationResult
                { repository = request.repository
                , pullRequest = request.pullRequest
                , epoch = request.epoch
                , head = request.head
                , base = request.base
                , intents =
                    [
                      [ ("type", String kind)
                      , ("arguments", Object [("request", String instruction)])
                      , ("mutation", Bool True)
                      , ("explicit", Bool True)
                      , ("confidence", Float 1.0)
                      ]
                    ]
                }
        modifyIORef' ref (\q -> q {conversationResults = q.conversationResults <> [Codec.dump result]})
        pure result
    }

-- ---------------------------------------------------------------------------
-- The Git publisher, observed

reconciliationJson :: GitReconciliation -> Json
reconciliationJson r =
  Object
    [ ("disposition", String r.disposition)
    , ("observed_head", String r.observedHead)
    , ("commit", String r.commit)
    , ("parents", texts r.parents)
    ]

publicationKeywords :: Text -> Text -> Text -> Text -> Bool -> [(Text, Json)]
publicationKeywords operation digest expectedHead baseHead mergeBase =
  [ ("operation", String operation)
  , ("payload_digest", String digest)
  , ("expected_head", String expectedHead)
  , ("base_head", String baseHead)
  , ("merge_base", Bool mergeBase)
  ]

-- | The V5 application with @_run_journey@'s publisher substitutions: the
-- observed real publisher for the journeys that publish (cloning the
-- fixture's remote; the reference reaches the same remote through an
-- @insteadOf@ rewrite of the public clone URL), the reconcile/publish
-- doubles for the CI-failure and conversational-change journeys, and the
-- unpatched publisher otherwise.
journeyApplications :: Flags -> IORef ProviderState -> ApplicationFactory
journeyApplications flags truth root instanceId authority runner options = do
  provider <- readIORef truth
  publisher <-
    if
      | repairing flags, Just remote <- provider.gitRemote -> do
          absolute <- makeAbsolute remote
          real <- hostGitPublisher (publicationAuthority authority) ("file://" <> T.pack absolute)
          let observed = real {reconcileHook = observeReconcile}
          pure . Just $
            MutationPublisher
              { reconcile = Git.reconcile observed
              , publish = \result operation digest expectedHead baseHead mergeBase -> do
                  outcome <- Git.publish observed result operation digest expectedHead baseHead mergeBase
                  let entry =
                        publicationKeywords operation digest expectedHead baseHead mergeBase
                          <> [ ("result", Codec.dump result)
                             , ("outcome", Object [("head", String outcome.head), ("recovered", Bool outcome.recovered)])
                             ]
                  modifyIORef' truth $ \p ->
                    p
                      { gitPublications = p.gitPublications <> [Object entry]
                      , gitBoundaryEvents = p.gitBoundaryEvents <> [Object (("kind", String "publish") : entry)]
                      }
                  pure outcome
              }
      | flags.rerunConclusion == Just "failure" || flags.conversationalChange ->
          pure . Just $
            MutationPublisher
              { reconcile = \operation digest expectedHead baseHead mergeBase -> do
                  modifyIORef' truth $ \p ->
                    p {gitReconciliations = p.gitReconciliations <> [Object (publicationKeywords operation digest expectedHead baseHead mergeBase)]}
                  p <- readIORef truth
                  pure (GitReconciliation "absent" p.head "" [])
              , publish = \result operation digest expectedHead baseHead mergeBase -> do
                  modifyIORef' truth $ \p ->
                    p
                      { gitPublications =
                          p.gitPublications <> [Object (publicationKeywords operation digest expectedHead baseHead mergeBase <> [("result", Codec.dump result)])]
                      }
                  unless flags.conversationalChange $ assertionError "an unchanged repair must never reach Git publication"
                  p <- readIORef truth
                  check (p.head == headSha) "the change publishes on the first head"
                  writeIORef truth p {head = newHeadSha, runId = 102, runAttempt = 1, runStatus = "in_progress", runConclusion = Nothing}
                  pure (GitPublishResult newHeadSha False)
              }
      | otherwise -> pure Nothing
  v5ApplicationFactory root instanceId authority runner options {mutationPublisher = publisher}
  where
    observeReconcile operation digest expectedHead baseHead mergeBase selfCaused reconciliation = do
      result <- reconciliation
      let entry =
            publicationKeywords operation digest expectedHead baseHead mergeBase
              <> [("self_caused_head", String selfCaused) | not (T.null selfCaused)]
              <> [("result", reconciliationJson result)]
      modifyIORef' truth $ \p ->
        p
          { gitReconciliations = p.gitReconciliations <> [Object entry]
          , gitBoundaryEvents = p.gitBoundaryEvents <> [Object (("kind", String "reconcile") : entry)]
          }
      pure result

-- ---------------------------------------------------------------------------
-- One host lifetime over a span of phases

-- | What one span leaves for the next (the reference driver's @carry@).
type Carry = Json

data Drive = Drive
  { journey :: Journey
  , flags :: Flags
  , root :: FilePath
  , provider :: Provider
  , runner :: IORef RunnerState
  , snapshots :: IORef (Map Text Json)
  , nextUuid :: IORef Integer
  , host :: HostService
  }

-- | @config(root)@.
journeyConfig :: FilePath -> HostConfig
journeyConfig root =
  HostConfig
    { appId = 17
    , appSlug = "hamsterdan-test"
    , clientId = clientSecret
    , accounts = [AccountConfig 23 "Owner" [(31, "owner/repo")]]
    , statePath = root
    , watchedAuthors = mempty
    , privateKey = secret privateKey
    , webhookSecret = secret webhookSecret
    }

openDrive :: Journey -> FilePath -> Maybe Carry -> IO Drive
openDrive journey root carry = do
  let flags = flagsOf journey
  environment <- gitEnvironment
  (providerState, runnerState, snapshotMap, next) <- case carry of
    Just value ->
      pure
        ( providerFromJson (member "provider" value)
        , runnerFromJson (member "runner" value)
        , case member "snapshots" value of
            Object members -> Map.fromList members
            _ -> Map.empty
        , int (member "next_uuid" value)
        )
    Nothing -> do
      (work, remote, initialBase, initialHead) <-
        if
          | flags.resolveConflict -> do
              (w, r, b, h) <- conflictRepository environment (root </> "git-world")
              pure (Just w, Just r, b, h)
          | flags.agentRepair || flags.updateBase -> do
              (w, r, b, h) <- repairRepository environment (root </> "git-world")
              pure (Just w, Just r, b, h)
          | otherwise -> pure (Nothing, Nothing, baseSha, headSha)
      let fresh = (newProviderState flags.rerunConclusion initialHead initialBase work remote) {draft = flags.draftReady}
          provided
            | flags.collaboration = fresh {humanReviews = [], reviewThreads = []}
            | otherwise = fresh
          runnerState =
            RunnerState
              { reviewEntries = 0
              , reviews = []
              , reviewResults = []
              , conversationCalls = []
              , conversationResults = []
              , codeCalls = []
              , codeResults = []
              , codingStatus =
                  if
                    | flags.conversationalChange || flags.agentRepair || baseMutation flags -> Just "changed"
                    | flags.rerunConclusion == Just "failure" -> Just "unchanged"
                    | otherwise -> Nothing
              , seededFinding = flags.seededFinding || flags.agentRepair || flags.heroReview
              , conversationalChange = flags.conversationalChange
              , updateBase = flags.updateBase
              , resolveConflict = flags.resolveConflict
              , findingHead = if flags.agentRepair then Just initialHead else Nothing
              , reviewFindings = if flags.heroReview then heroFindings else [blockingFinding]
              , codes = 0
              , conversations = 0
              }
      pure (provided, runnerState, Map.fromList [("initial_head", String initialHead), ("initial_base", String initialBase)], 1)
  truth <- newIORef providerState
  runnerRef <- newIORef runnerState
  snapshotRef <- newIORef snapshotMap
  nextRef <- newIORef next
  let provider = Provider {truth, environment}
      transport = providerTransport provider
      clients =
        HostClients
          { registrationInventory = \_ -> assertionError "registration inventory was not configured"
          , installation = \installationId repositoryIds -> do
              check (installationId == 44 && repositoryIds == [31]) "installation 44 over repository 31"
              pure transport
          , close = pure ()
          }
  agent <- composeAgent Nothing Nothing Nothing
  store <- openAgentRouteStore (root </> "agent-routes.sqlite3")
  activateRoutes store agent (root </> "applications")
  let custody =
        AgentCustody
          { claim = \operation -> void (claimRoute store operation agent)
          , settleOperations = settleRoutes store . Set.toList
          , close = closeRoutes store
          }
  host <-
    openHostService
      (journeyConfig root)
      (serviceOptions (scenarioRunner runnerRef) custody)
        { clients = Just clients
        , applicationFactory = journeyApplications flags truth
        , clock = Just (pure clockSeconds)
        }
  when (carry == Nothing) $
    void (Routing.reconcile host.registry [InstallationInventory 44 23 [(31, "owner/repo")]])
  pure Drive {journey, flags, root, provider, runner = runnerRef, snapshots = snapshotRef, nextUuid = nextRef, host}

carryOf :: Drive -> IO Carry
carryOf d = do
  p <- readIORef d.provider.truth
  r <- readIORef d.runner
  s <- readIORef d.snapshots
  n <- readIORef d.nextUuid
  pure (Object [("provider", providerJson p), ("runner", runnerJson r), ("snapshots", Object (Map.toAscList s)), ("next_uuid", Int n)])

remember :: Drive -> Text -> Json -> IO ()
remember d key value = modifyIORef' d.snapshots (Map.insert key value)

recalled :: Drive -> Text -> IO Json
recalled d key = fromMaybe Null . Map.lookup key <$> readIORef d.snapshots

-- | @str(uuid.uuid4())@ from the counter.
nextDelivery :: Drive -> IO Text
nextDelivery d = do
  n <- readIORef d.nextUuid
  writeIORef d.nextUuid (n + 1)
  let hex = printf "%032x" n :: String
      (a, rest1) = splitAt 8 hex
      (b, rest2) = splitAt 4 rest1
      (c, rest3) = splitAt 4 rest2
      (e, f) = splitAt 4 rest3
  pure (T.pack (a <> "-" <> b <> "-" <> c <> "-" <> e <> "-" <> f))

-- | @_run_journey@'s @external_state()@.
externalState :: Drive -> IO Json
externalState d = do
  p <- readIORef d.provider.truth
  r <- readIORef d.runner
  pure $
    Array
      [ Array p.calls
      , Array p.requests
      , Array p.writes
      , Array r.reviews
      , Array r.reviewResults
      , Array r.conversationCalls
      , Array r.conversationResults
      , Array r.codeCalls
      , Array r.codeResults
      , Int r.conversations
      , Array p.gitReconciliations
      , Array p.gitPublications
      , Array p.casUpdates
      , texts (Set.toAscList p.createdGitObjects)
      , Array p.gitBoundaryEvents
      ]

-- | @host._apps[(44, 31, 7)].has_unresolved_publication()@; an
-- application this host never loaded holds no publication.
unresolved :: Drive -> IO Bool
unresolved d = do
  loaded <- readIORef d.host.apps
  case Map.lookup (44, 31, 7) loaded of
    Just application -> application.hasUnresolvedPublication
    Nothing -> pure False

-- | @converge()@.
converge :: Drive -> IO ()
converge d = go (50 :: Int)
  where
    go 0 = assertionError "parity journey host did not converge"
    go n = do
      before <- externalState d
      processed <- Host.pump d.host 20
      after <- externalState d
      pending <- unresolved d
      unless (processed == 0 && before == after && not pending) (go (n - 1))

-- | Receive a signed delivery, process it, and converge: the delivery id
-- and its custody status before processing.
deliver :: Drive -> ByteString -> Text -> IO (Text, Maybe Text)
deliver d body event = do
  delivery <- nextDelivery d
  receipt <- Custody.receive d.host.custody (signed body delivery event) body
  check (receipt.disposition == Accepted) "the delivery is accepted"
  before <- Custody.status d.host.custody delivery
  waiting <- Custody.pending d.host.custody 100 Nothing
  item <- maybe (throwIO (PythonException "StopIteration" [])) pure (find (\o -> o.deliveryId == delivery) waiting)
  Host.process d.host item
  converge d
  pure (delivery, before)

-- | @signed(body, delivery, event)@.
signed :: ByteString -> Text -> Text -> [(Text, Text)]
signed body delivery event =
  [ ("content-type", "application/json")
  , ("content-length", showT (BS.length body))
  , ("x-hub-signature-256", sign webhookSecret body)
  , ("x-github-delivery", delivery)
  , ("x-github-event", event)
  ]

subjectMembers :: [(Text, Json)]
subjectMembers =
  [ ("installation", Object [("id", Int 44), ("account", Object [("id", Int 23)])])
  , ("repository", Object [("id", Int 31), ("full_name", String "owner/repo")])
  ]

-- | @envelope(action)@.
envelope :: Text -> ByteString
envelope action = pythonDumps (Object ([("action", String action)] <> subjectMembers <> [("pull_request", Object [("number", Int 7)])]))

-- | @workflow_envelope(conclusion, head=)@.
workflowEnvelope :: Text -> Text -> ByteString
workflowEnvelope conclusion headValue =
  pythonDumps . Object $
    [("action", String "completed")]
      <> subjectMembers
      <> [ ( "workflow_run"
           , Object
               [ ("id", Int 101)
               , ("run_attempt", Int 2)
               , ("head_sha", String headValue)
               , ("status", String "completed")
               , ("conclusion", String conclusion)
               , ("pull_requests", Array [Object [("number", Int 7)]])
               ]
           )
         ]

-- | @comment_envelope(comment_id, instruction)@.
commentEnvelope :: Integer -> Text -> ByteString
commentEnvelope commentId instruction =
  pythonDumps . Object $
    [("action", String "created")]
      <> subjectMembers
      <> [ ("issue", Object [("number", Int 7), ("pull_request", Object [("url", String "https://api.github.com/repos/owner/repo/pulls/7")])])
         ,
           ( "comment"
           , Object
               [ ("id", Int commentId)
               , ("body", String ("@hamsterdan-test " <> instruction))
               , ("author_association", String "OWNER")
               , ("user", Object [("id", Int 701), ("login", String "author"), ("type", String "User")])
               ]
           )
         ]

statusJson :: Maybe Text -> Json
statusJson = maybeText

countsJson :: Drive -> IO Json
countsJson d = do
  counted <- Custody.counts d.host.custody
  pure (Object [(name, Int (toInteger n)) | (name, n) <- Map.toList counted])

modifyProvider :: Drive -> (ProviderState -> ProviderState) -> IO ()
modifyProvider d = modifyIORef' d.provider.truth

agentCounts :: RunnerState -> Json
agentCounts r = Array [Int r.reviewEntries, Int r.codes, Int r.conversations]

runPhase :: Drive -> Phase -> IO ()
runPhase d = \case
  Open -> do
    (delivery, before) <- deliver d (envelope (if d.flags.draftReady then "opened" else "synchronize")) "pull_request"
    remember d "delivery" (String delivery)
    remember d "custody_before" (statusJson before)
  Draft -> do
    delivery <- textOf <$> recalled d "delivery"
    draftAfter <- Custody.status d.host.custody delivery
    draftCounts <- countsJson d
    p <- readIORef d.provider.truth
    r <- readIORef d.runner
    modifyProvider d (\q -> q {draft = False})
    (ready, readyBefore) <- deliver d (envelope "ready_for_review") "pull_request"
    readyAfter <- Custody.status d.host.custody ready
    custodyBefore <- recalled d "custody_before"
    remember d "draft_phase" . Object $
      [ ("custody_before", custodyBefore)
      , ("custody_after", statusJson draftAfter)
      , ("custody_counts", draftCounts)
      , ("comments", Array p.comments)
      , ("review_comments", Array p.reviewComments)
      , ("provider_writes", Array p.writes)
      , ("agent_counts", agentCounts r)
      , ("rerun_requests", Int p.rerunRequests)
      , ("ready_custody_before", statusJson readyBefore)
      , ("ready_custody_after", statusJson readyAfter)
      ]
  StaleBase -> do
    initialBase <- textOf <$> recalled d "initial_base"
    initialHead <- textOf <$> recalled d "initial_head"
    p <- readIORef d.provider.truth
    (work, remote) <- case (p.gitWork, p.gitRemote) of
      (Just w, Just r) -> pure (w, r)
      _ -> assertionError "a base mutation journey has a Git world"
    current <-
      if d.flags.resolveConflict
        then advanceConflictingBaseRepository d.provider.environment work remote initialBase initialHead
        else advanceBaseRepository d.provider.environment work remote initialBase initialHead
    modifyProvider d $ \q ->
      (q {base = current, behindBy = 1} :: ProviderState)
        & \q' -> if d.flags.resolveConflict then q' {mergeable = False, mergeableState = "dirty"} else q'
    (stale, staleBefore) <- deliver d (envelope "synchronize") "pull_request"
    staleAfter <- Custody.status d.host.custody stale
    q <- readIORef d.provider.truth
    r <- readIORef d.runner
    remember d "stale_base_phase" . Object $
      [ ("custody_before", statusJson staleBefore)
      , ("custody_after", statusJson staleAfter)
      , ("old_base", String initialBase)
      , ("current_base", String current)
      , ("comments", Array q.comments)
      , ("agent_counts", agentCounts r)
      ]
  Collaboration -> do
    deliveries <- newIORef []
    snapshotsRef <- newIORef []
    let snapshot = do
          p <- readIORef d.provider.truth
          dashboard <- case [c | c <- p.comments, "<!-- hamsterdan:dashboard -->" `T.isInfixOf` textOf (member "body" c)] of
            [one] -> pure (textOf (member "body" one))
            _ -> assertionError "exactly one dashboard"
          let readiness = length [c | c <- p.comments, "<!-- hamsterdan:readiness " `T.isInfixOf` textOf (member "body" c)]
          modifyIORef' snapshotsRef (<> [(dashboard, readiness)])
        observe label event action = do
          (delivery, before) <- deliver d (envelope action) event
          after <- Custody.status d.host.custody delivery
          modifyIORef' deliveries (<> [Array [String label, statusJson before, statusJson after]])
          snapshot
        review identifier submitted state =
          Object [("id", Int identifier), ("submitted_at", String submitted), ("state", String state), ("user", Object [("login", String "reviewer")])]
    snapshot
    modifyProvider d (\q -> q {requestedReviewers = ["reviewer"]})
    observe "review_requested" "pull_request" "review_requested"
    modifyProvider d (\q -> q {requestedReviewers = [], humanReviews = [review 401 "2026-08-16T01:00:00Z" "CHANGES_REQUESTED"], reviewThreads = [False]})
    observe "changes_requested" "pull_request_review" "submitted"
    modifyProvider d (\q -> q {humanReviews = q.humanReviews <> [review 402 "2026-08-16T02:00:00Z" "APPROVED"]})
    observe "approved_thread_open" "pull_request_review" "submitted"
    modifyProvider d (\q -> q {reviewThreads = [True]})
    observe "thread_resolved" "pull_request_review_thread" "resolved"
    delivered <- readIORef deliveries
    taken <- readIORef snapshotsRef
    remember d "collaboration_phase" . Object $
      [ ("deliveries", Array delivered)
      , ("dashboards", texts (map fst taken))
      , ("readiness_counts", Array [Int (toInteger n) | (_, n) <- taken])
      ]
  FollowUp -> do
    initialHead <- textOf <$> recalled d "initial_head"
    p <- readIORef d.provider.truth
    remember d "before_follow_up_comments" (Array p.comments)
    remember d "before_follow_up_calls" (Array p.calls)
    remember d "before_follow_up_write_count" (Int (toInteger (length p.writes)))
    when (repairing d.flags) $ do
      r <- readIORef d.runner
      check (null r.codeCalls) "no coding before the follow-up"
    if
      | d.flags.conversationalChange || baseMutation d.flags -> do
          let commentId = 501
              instruction
                | d.flags.resolveConflict = resolveConflictInstruction
                | d.flags.updateBase = updateBaseInstruction
                | otherwise = changeInstruction
          modifyProvider d $ \q ->
            q
              { comments =
                  q.comments
                    <> [ Object
                           [ ("id", Int commentId)
                           , ("html_url", String "https://github.com/owner/repo/pull/7#issuecomment-501")
                           , ("body", String ("@hamsterdan-test " <> instruction))
                           , ("user", Object [("login", String "author")])
                           ]
                       ]
              }
          (followUp, before) <- deliver d (commentEnvelope commentId instruction) "issue_comment"
          remember d "conversation_delivery_id" (String followUp)
          remember d "follow_up_custody_before" (statusJson before)
          q <- readIORef d.provider.truth
          check (q.head /= initialHead) "the follow-up moved the head"
          when d.flags.conversationalChange $ check (q.head == newHeadSha) "the change published NEW_HEAD"
          headFollowUp d
      | Just conclusion <- d.flags.rerunConclusion -> do
          completeRerun d.provider.truth
          (_, before) <- deliver d (workflowEnvelope conclusion initialHead) "workflow_run"
          remember d "follow_up_custody_before" (statusJson before)
          when d.flags.agentRepair $ do
            q <- readIORef d.provider.truth
            check (q.head /= initialHead) "the repair moved the head"
            r <- readIORef d.runner
            check ([member "head" (member' 1 review) | review <- r.reviews] == [String initialHead]) "one review, of the initial head"
            dashboard <- case [c | c <- q.comments, "<!-- hamsterdan:dashboard -->" `T.isInfixOf` textOf (member "body" c)] of
              [one] -> pure one
              _ -> assertionError "exactly one dashboard before the head follow-up"
            check (not (q.head `T.isInfixOf` textOf (member "body" dashboard))) "the dashboard predates the repaired head"
            headFollowUp d
      | otherwise -> pure ()

headFollowUp :: Drive -> IO ()
headFollowUp d = do
  p <- readIORef d.provider.truth
  r <- readIORef d.runner
  remember d "head_follow_up_comments_before" (Array p.comments)
  remember d "head_follow_up_review_count_before" (Int (toInteger (length r.reviews)))
  (_, before) <- deliver d (envelope "synchronize") "pull_request"
  remember d "head_follow_up_custody_before" (statusJson before)

(&) :: a -> (a -> b) -> b
x & f = f x

-- | @_run_journey@'s closing checks and its @JourneyResult@.
finish :: Drive -> IO Json
finish d = do
  p <- readIORef d.provider.truth
  frozen <- externalState d
  unresolvedBefore <- unresolved d
  check (not unresolvedBefore) "no unresolved publication"
  pumped <- Host.pump d.host 20
  check (pumped == 0) "a quiescent host processes nothing"
  unresolvedAfter <- unresolved d
  still <- externalState d
  check (not unresolvedAfter && still == frozen) "a quiescent host changes nothing"
  snapshots <- readIORef d.snapshots
  r <- readIORef d.runner
  custodyAfter <- Custody.status d.host.custody (textOf (fromMaybe Null (Map.lookup "delivery" snapshots)))
  counts <- countsJson d
  let snap key = fromMaybe Null (Map.lookup key snapshots)
      changed
        | d.flags.resolveConflict = "src/pr_fixture/__init__.py"
        | d.flags.updateBase = "BASE-NOTES.md"
        | otherwise = "src/readiness.py"
      environment = d.provider.environment
  (remoteHead, commitBody, parents, content) <- case p.gitRemote of
    Nothing -> pure ("", "", [], "")
    Just remote -> do
      remoteHead <- git environment remote ["rev-parse", "refs/heads/feature"]
      commitBody <- git environment remote ["log", "-1", "--format=%B", T.unpack p.head]
      parentLine <- git environment remote ["rev-list", "--parents", "-n", "1", T.unpack p.head]
      content <- git environment remote ["show", T.unpack (p.head <> ":" <> changed)]
      pure (remoteHead, commitBody, drop 1 (T.words parentLine), content)
  let result =
        Object
          [ ("custody_before", snap "custody_before")
          , ("custody_after", statusJson custodyAfter)
          , ("custody_counts", counts)
          , ("comments", Array p.comments)
          , ("review_comments", Array p.reviewComments)
          , ("provider_calls", Array p.calls)
          , ("provider_requests", Array p.requests)
          , ("provider_writes", Array p.writes)
          , ("provider_state", Array [String p.state, Bool p.draft, Bool p.merged, Bool p.mergeable, String p.mergeableState, String p.head, String p.base])
          , ("initial_head", snap "initial_head")
          , ("initial_base", snap "initial_base")
          , ("runner", runnerJson r)
          , ("run_attempt", Int p.runAttempt)
          , ("run_id", Int p.runId)
          , ("run_conclusion", maybeText p.runConclusion)
          , ("rerun_requests", Int p.rerunRequests)
          , ("git_reconciliations", Array p.gitReconciliations)
          , ("git_publications", Array p.gitPublications)
          , ("before_follow_up_comments", snap "before_follow_up_comments")
          , ("before_follow_up_calls", snap "before_follow_up_calls")
          , ("before_follow_up_write_count", snap "before_follow_up_write_count")
          , ("follow_up_custody_before", snap "follow_up_custody_before")
          , ("head_follow_up_custody_before", snap "head_follow_up_custody_before")
          , ("head_follow_up_comments_before", snap "head_follow_up_comments_before")
          , ("head_follow_up_review_count_before", snap "head_follow_up_review_count_before")
          , ("conversation_delivery_id", snap "conversation_delivery_id")
          , ("git_cas_updates", Array p.casUpdates)
          , ("git_created_objects", texts (Set.toAscList p.createdGitObjects))
          , ("git_boundary_events", Array p.gitBoundaryEvents)
          , ("git_remote_head", String remoteHead)
          , ("git_commit_body", String commitBody)
          , ("git_commit_parents", texts parents)
          , ("git_repaired_content", String content)
          , ("quiescent_comments", Array p.comments)
          , ("quiescent_review_count", Int (toInteger (length r.reviews)))
          , ("draft_phase", snap "draft_phase")
          , ("stale_base_phase", snap "stale_base_phase")
          , ("collaboration_phase", snap "collaboration_phase")
          ]
  modifyProvider d $ \q ->
    q
      { state = "closed"
      , draft = True
      , merged = True
      , mergeable = False
      , mergeableState = "dirty"
      , head = T.replicate 40 "c"
      , base = T.replicate 40 "d"
      }
  closing <- externalState d
  Host.close d.host
  closed <- externalState d
  check (closed == closing) "closing changes nothing outside"
  q <- readIORef d.provider.truth
  check (q.comments == p.comments) "no comment after the result"
  r' <- readIORef d.runner
  check (length r'.reviews == length r.reviews) "no review after the result"
  pure result

-- | Run phases @[from, to)@ of a journey in one host lifetime on ROOT,
-- resuming the given carry (a fresh journey without one). The drive that
-- runs the last phase also finishes the journey. The output is the
-- reference driver's: @{"carry": …, "result": …}@.
driveJourney :: Journey -> FilePath -> (Int, Int) -> Maybe Carry -> IO Json
driveJourney journey root0 (from, to) carry = do
  root <- makeAbsolute root0
  d <- openDrive journey root carry
  let selected = phasesOf journey
  outcome <- try @SomeException $ do
    forM_ (take (to - from) (drop from selected)) (runPhase d)
    if to >= length selected
      then Just <$> finish d
      else Host.close d.host >> pure Nothing
  case outcome of
    Left problem -> do
      _ <- try @SomeException (Host.close d.host)
      throwIO problem
    Right result -> do
      carried <- carryOf d
      pure (Object ([("carry", carried)] <> maybe [] (\value -> [("result", value)]) result))

-- | The whole journey in one host lifetime: its @JourneyResult@.
runJourney :: Journey -> FilePath -> IO Json
runJourney journey root = member "result" <$> driveJourney journey root (0, length (phasesOf journey)) Nothing
