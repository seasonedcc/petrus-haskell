-- | Provider-backed review-agent gate for the V5 topology
-- (@host/v5/review.py@).
--
-- The review loop owns prior-finding selection and the globally scoped
-- logical operation. This adapter gathers credential-free context, freezes
-- the exact request in durable custody (@review-requests.sqlite3@, table
-- @v5_review_requests@), invokes the routed 'AgentRunner', and classifies
-- clean agent inability separately from genuine activity failures.
module Hamsterdan.Host.V5.Review
  ( -- * Request custody
    ReviewRequestCustody (..)
  , V5ReviewRequestStore
  , openReviewRequestStore
  , storeCustody
  , lookupRequest
  , claimRequest
  , closeReviewRequestStore
  , encodeRequest

    -- * The gate
  , ReviewAuthority (..)
  , gitHubReviewAuthority
  , V5ReviewGate (..)
  , reviewAgent
  , reviewLenses
  , runSnapshotJson
  ) where

import Control.Exception (onException, throwIO, try)
import Control.Monad (unless, when)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Hamsterdan.Agents.Protocol
  ( AgentCleanupCategory (..)
  , AgentProtocolError (..)
  , AgentResultCategory (..)
  , AgentRunner (..)
  , Invocation (..)
  , ReviewRequest (..)
  , ReviewResult (..)
  )
import Hamsterdan.Contracts.Codec (Object, dump, validateJson)
import Hamsterdan.Contracts.ReadinessV5
  ( AgentReview (..)
  , Phase (..)
  , ReviewUnableCategory (..)
  , RoundDeferred (..)
  , RoundMoved (..)
  , RoundOpen (..)
  , RoundUnable (..)
  )
import Hamsterdan.GitHub.Gateway (GitHubAuthority)
import Hamsterdan.GitHub.Gateway qualified as Gateway
import Hamsterdan.GitHub.Models (ActionsJobSnapshot (..), ActionsRunSnapshot (..))
import Hamsterdan.GitHub.Python qualified as Py
import Hamsterdan.Sqlite (Connection, SQLData (..))
import Hamsterdan.Sqlite qualified as Sql
import Hamsterdan.Host.Errors (catchBoundary)
import Hamsterdan.Host.Python (RuntimeError (..), ValueError (..), dumpsSortedText, immediate, mkdirPrivate, sha256HexText)
import Hamsterdan.Host.V5.Claim (ClaimReader, CurrentClaim (..))
import Hamsterdan.Readiness.NetV5.Gating (Variant, variantOf)
import Petrus.Json (Json (..))
import System.FilePath (takeDirectory)
import System.IO (stderr)

-- ---------------------------------------------------------------------------
-- Request custody

-- | Freeze the exact credential-free request before agent submission.
data ReviewRequestCustody = ReviewRequestCustody
  { lookup :: Text -> Integer -> IO (Maybe ReviewRequest)
  , claim :: Text -> ReviewRequest -> Integer -> IO ReviewRequest
  }

-- | @V5ReviewRequestStore(path)@.
newtype V5ReviewRequestStore = V5ReviewRequestStore Connection

-- | @json.dumps(asdict(request), sort_keys=True, separators=(",", ":"))@.
encodeRequest :: ReviewRequest -> Text
encodeRequest = dumpsSortedText . dump

loadRequest :: SQLData -> SQLData -> IO ReviewRequest
loadRequest raw digest = case (raw, digest) of
  (SQLText text, SQLText expected) | sha256HexText text == expected -> do
    request <- case validateJson @ReviewRequest (TE.encodeUtf8 text) of
      Left _ -> throwIO (RuntimeError "stored V5 review request is malformed")
      Right value -> pure value
    unless (encodeRequest request == text) $ throwIO (RuntimeError "stored V5 review request is not canonical")
    pure request
  _ -> throwIO (RuntimeError "stored V5 review request digest is invalid")

tableDdl :: Text
tableDdl =
  "CREATE TABLE v5_review_requests (\n\
  \                            operation TEXT NOT NULL,\n\
  \                            attempt INTEGER NOT NULL CHECK(attempt >= 1),\n\
  \                            request_json TEXT NOT NULL,\n\
  \                            digest TEXT NOT NULL,\n\
  \                            PRIMARY KEY(operation, attempt)\n\
  \                        )"

openReviewRequestStore :: FilePath -> IO V5ReviewRequestStore
openReviewRequestStore path = do
  mkdirPrivate (takeDirectory path)
  db <- Sql.open (T.pack path)
  let setup = do
        _ <- Sql.query db "PRAGMA journal_mode=WAL" []
        _ <- Sql.query db "PRAGMA synchronous=FULL" []
        Sql.script
          db
          "CREATE TABLE IF NOT EXISTS v5_review_requests (\n\
          \                    operation TEXT NOT NULL,\n\
          \                    attempt INTEGER NOT NULL CHECK(attempt >= 1),\n\
          \                    request_json TEXT NOT NULL,\n\
          \                    digest TEXT NOT NULL,\n\
          \                    PRIMARY KEY(operation, attempt)\n\
          \                )"
        columns <- Sql.query db "PRAGMA table_info(v5_review_requests)" []
        let names = [name | _ : SQLText name : _ <- columns]
        unless ("attempt" `elem` names) $
          immediate db $ do
            Sql.script db "ALTER TABLE v5_review_requests RENAME TO v5_review_requests_v1"
            Sql.script db tableDdl
            Sql.script db "INSERT INTO v5_review_requests SELECT operation,1,request_json,digest FROM v5_review_requests_v1"
            Sql.script db "DROP TABLE v5_review_requests_v1"
  setup `onException` Sql.close db
  pure (V5ReviewRequestStore db)

lookupRequest :: V5ReviewRequestStore -> Text -> Integer -> IO (Maybe ReviewRequest)
lookupRequest (V5ReviewRequestStore db) operation attempt = do
  rows <-
    Sql.withLock db $
      Sql.query db "SELECT request_json,digest FROM v5_review_requests WHERE operation=? AND attempt=?" [SQLText operation, SQLInteger (fromIntegral attempt)]
  case rows of
    [raw, digest] : _ -> Just <$> loadRequest raw digest
    _ -> pure Nothing

claimRequest :: V5ReviewRequestStore -> Text -> ReviewRequest -> Integer -> IO ReviewRequest
claimRequest (V5ReviewRequestStore db) operation request attempt = do
  let raw = encodeRequest request
      digest = sha256HexText raw
  immediate db $ do
    _ <-
      Sql.execute
        db
        "INSERT OR IGNORE INTO v5_review_requests VALUES(?,?,?,?)"
        [SQLText operation, SQLInteger (fromIntegral attempt), SQLText raw, SQLText digest]
    rows <-
      Sql.query db "SELECT request_json,digest FROM v5_review_requests WHERE operation=? AND attempt=?" [SQLText operation, SQLInteger (fromIntegral attempt)]
    case rows of
      [storedRaw, storedDigest] : _ -> loadRequest storedRaw storedDigest
      _ -> throwIO (RuntimeError "V5 review request custody did not retain its claim")

closeReviewRequestStore :: V5ReviewRequestStore -> IO ()
closeReviewRequestStore (V5ReviewRequestStore db) = Sql.close db

storeCustody :: V5ReviewRequestStore -> ReviewRequestCustody
storeCustody store = ReviewRequestCustody {lookup = lookupRequest store, claim = claimRequest store}

-- ---------------------------------------------------------------------------
-- The gate

-- | Read-only provider context gathered before agent execution.
data ReviewAuthority = ReviewAuthority
  { comments :: IO [Object]
  , selectRun :: Text -> Text -> IO (Maybe ActionsRunSnapshot)
  }

gitHubReviewAuthority :: GitHubAuthority -> ReviewAuthority
gitHubReviewAuthority authority =
  ReviewAuthority {comments = Gateway.comments authority, selectRun = Gateway.selectRun authority}

-- | @V5ReviewGate(...)@.
data V5ReviewGate = V5ReviewGate
  { repository :: Text
  , pullRequest :: Integer
  , authority :: ReviewAuthority
  , runner :: AgentRunner
  , publicCloneUrl :: Text
  , workflowPath :: Text
  , claim :: ClaimReader
  , requests :: ReviewRequestCustody
  , unstagedCustody :: IO (Maybe Text)
  }

reviewLenses :: [Text]
reviewLenses = ["correctness", "security", "tests", "maintainability", "developer experience"]

-- | @asdict(run)@.
runSnapshotJson :: ActionsRunSnapshot -> Object
runSnapshotJson run =
  [ ("id", Int run.id)
  , ("head", String run.head)
  , ("workflow", String run.workflow)
  , ("attempt", Int run.attempt)
  , ("status", String run.status)
  , ("conclusion", maybe Null String run.conclusion)
  , ("jobs", Array (map job run.jobs))
  ]
  where
    job j =
      Object
        [ ("id", Int j.id)
        , ("name", String j.name)
        , ("status", String j.status)
        , ("conclusion", maybe Null String j.conclusion)
        , ("required", Bool j.required)
        ]

category :: AgentProtocolError -> ReviewUnableCategory
category e
  | e.timedOut = UnableTimedOut
  | e.canceled = UnableCanceled
  | Just c <- e.resultCategory = case c of
      RuntimeLifecycle -> UnableRuntimeLifecycle
      OutputSchema -> UnableOutputSchema
      Correlation -> UnableCorrelation
      Unchanged -> UnableUnchanged
      Unable -> UnableUnable
      WorkspaceReconciliation -> UnableWorkspaceReconciliation
  | Just CleanupUnverified <- e.cleanupCategory = UnableCleanupUnverified
  | otherwise = UnableProtocol

objects :: [Object] -> Json
objects = Array . map Object

reviewAgent :: V5ReviewGate -> RoundOpen -> IO Variant
reviewAgent g work = do
  let expected = CurrentClaim PhaseRunning work.incarnation work.head work.base work.policy
      deferred blocker =
        variantOf
          RoundDeferred
            { operation = work.operation
            , head = work.head
            , base = work.base
            , policy = work.policy
            , incarnation = work.incarnation
            , priorFindings = work.priorFindings
            , priorLineage = work.priorLineage
            , mem = work.mem
            , attempt = work.attempt
            , blocker
            }
      unable c = variantOf RoundUnable {head = work.head, incarnation = work.incarnation, category = c, mem = work.mem}
      readClaimUnstaged =
        catchBoundary (Right <$> g.claim) $ \rethrow -> g.unstagedCustody >>= maybe rethrow (pure . Left)
      current = do
        blocked <- g.unstagedCustody
        case blocked of
          Just _ -> pure False
          Nothing -> do
            catchBoundary ((== expected) <$> g.claim) $ \rethrow ->
              g.unstagedCustody >>= maybe rethrow (const (pure False))
  early <- g.unstagedCustody
  case early of
    Just blocker -> pure (deferred blocker)
    Nothing -> do
      frozen <- g.requests.lookup work.operation work.attempt
      mapM_ (validateRequest g work) frozen
      claimed <- readClaimUnstaged
      case claimed of
        Left blocker -> pure (deferred blocker)
        Right observed
          | observed /= expected -> do
              let phase = observed.phase
              pure $
                variantOf
                  RoundMoved
                    { head = work.head
                    , incarnation = work.incarnation
                    , observed = observed.head
                    , observedBase = observed.base
                    , observedPolicy = observed.policy
                    , observedIncarnation = observed.incarnation
                    , observedPhase = phase
                    , mem = work.mem
                    }
          | otherwise -> do
              request <- case frozen of
                Just request -> pure request
                Nothing -> do
                  composed <- composeRequest g work
                  request <- g.requests.claim work.operation composed work.attempt
                  validateRequest g work request
                  pure request
              outcome <-
                try @AgentProtocolError $
                  g.runner.review g.publicCloneUrl request (Invocation {operation = work.operation, attempt = work.attempt, isCurrent = Just current})
              case outcome of
                Left e -> do
                  late <-
                    if e.canceled && maybe True (const False) e.cleanupCategory
                      then g.unstagedCustody
                      else pure Nothing
                  case late of
                    Just blocker -> pure (deferred blocker)
                    Nothing -> do
                      let c = category e
                      -- @LOG.warning(...)@: no handler is configured for the
                      -- host's loggers, so logging's last resort writes the
                      -- bare message to stderr.
                      TIO.hPutStrLn stderr $
                        "V5 review agent unavailable category="
                          <> (case dump c of String t -> t; other -> T.pack (show other))
                          <> " incarnation="
                          <> T.pack (show work.incarnation)
                          <> " head="
                          <> work.head
                          <> " operation="
                          <> work.operation
                      pure (unable c)
                Right result -> do
                  late <- g.unstagedCustody
                  case late of
                    Just blocker -> pure (deferred blocker)
                    Nothing
                      | result.status == "unable" -> pure (unable UnableUnable)
                      | result.status `notElem` ["clear", "blocking"] ->
                          throwIO (ValueError "agent returned an unrecognized review status")
                      | otherwise ->
                          pure $
                            variantOf
                              AgentReview
                                { head = work.head
                                , base = work.base
                                , policy = work.policy
                                , incarnation = work.incarnation
                                , findings = result.findings
                                , lineage = result.lineage
                                , mem = work.mem
                                }

-- | @_compose_request(work)@.
composeRequest :: V5ReviewGate -> RoundOpen -> IO ReviewRequest
composeRequest g work = do
  items <- g.authority.comments
  let recent = drop (length items - 100) items
      comment item =
        [ ("id", get "id" item)
        , ("url", maybe (String "") id (Prelude.lookup "html_url" item))
        , ("body", String (T.take 20000 (Py.str (maybe (String "") id (Prelude.lookup "body" item)))))
        , ( "author"
          , case Prelude.lookup "user" item of
              Just (Object user) -> maybe (String "") id (Prelude.lookup "login" user)
              _ -> String ""
          )
        ]
      get key item = maybe Null id (Prelude.lookup key item)
      prior = map comment recent
  run <- g.authority.selectRun g.workflowPath work.head
  pure
    ReviewRequest
      { repository = g.repository
      , pullRequest = g.pullRequest
      , epoch = work.incarnation
      , head = work.head
      , base = work.base
      , diffPath = "diff.patch"
      , policy = [("digest", String work.policy)]
      , reviewLenses
      , contextPaths = []
      , actionsEvidence = maybe [] (\r -> [runSnapshotJson r]) run
      , priorFindings = work.priorFindings
      , priorComments = prior
      , priorReplies = []
      , appliedChanges = work.priorLineage
      }

-- | @_validate_request(work, request)@, under Python equality.
validateRequest :: V5ReviewGate -> RoundOpen -> ReviewRequest -> IO ()
validateRequest g work request = do
  let frozen =
        [ String request.repository
        , Int request.pullRequest
        , Int request.epoch
        , String request.head
        , String request.base
        , String request.diffPath
        , Object request.policy
        , Array (map String request.reviewLenses)
        , Array (map String request.contextPaths)
        , objects request.priorFindings
        , objects request.priorReplies
        , objects request.appliedChanges
        ]
      expected =
        [ String g.repository
        , Int g.pullRequest
        , Int work.incarnation
        , String work.head
        , String work.base
        , String "diff.patch"
        , Object [("digest", String work.policy)]
        , Array (map String reviewLenses)
        , Array []
        , objects work.priorFindings
        , Array []
        , objects work.priorLineage
        ]
  when (frozen /= expected) $ throwIO (RuntimeError "V5 review operation selected a different review request")
