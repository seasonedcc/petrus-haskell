{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Exact-repository and pull-request authority reads and Git object
-- writes (@github_app/gateway.py@).
--
-- Every read goes through a 'Transport' (the effect seam), issues the
-- reference's requests in the reference's order, and refuses provider
-- evidence with the reference's messages. Where CPython would raise an
-- exception the reference does not catch, 'PythonFault' carries its class.
module Hamsterdan.GitHub.Gateway
  ( -- * Authority
    GitHubAuthority (..)
  , githubAuthority
  , root

    -- * Git objects
  , createTree
  , createCommit
  , objectWriteError

    -- * Reads
  , pullRequest
  , policy
  , humanReview
  , resolveStaleFindingThreads
  , baseCurrent
  , comments
  , workflowRuns
  , selectRun
  , jobs
  , RunResult (..)
  , runResult
  , actionsEvidence
  , failureLogs
  , maxPages

    -- * Shared helpers
  , isSha
  , findingMarkerHead
  , viewerThread
  , firstComment
  , policyDigest
  ) where

import Control.Exception (Exception (..), catch, throwIO)
import Control.Monad (foldM, forM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Char (isAsciiLower, isDigit, isHexDigit)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hamsterdan.GitHub.Models
import Hamsterdan.GitHub.Python (PythonFault (..))
import Hamsterdan.GitHub.Python qualified as Py
import Hamsterdan.GitHub.Transport (digest, pyFault)
import Hamsterdan.GitHub.Url qualified as Url
import Petrus.Json (Json (..))

-- | @MAX_PAGES@ for object-wrapped collections.
maxPages :: Int
maxPages = 20

-- | @GitHubAuthority@: reads authority for exactly one configured
-- repository and pull request.
data GitHubAuthority = GitHubAuthority
  { transport :: Transport
  , repository :: Text
  , owner :: Text
  , name :: Text
  , prNumber :: Integer
  , graphql :: Maybe GraphQLTransport
  }

-- | @GitHubAuthority(transport, repository, pr_number, graphql=graphql)@.
githubAuthority :: Transport -> Text -> Integer -> Maybe GraphQLTransport -> Either InvalidRequest GitHubAuthority
githubAuthority transport repository prNumber graphql =
  let (owner, rest) = T.breakOn "/" repository
      name = T.drop 1 rest
   in if T.null rest || T.null owner || T.null name || "/" `T.isInfixOf` name || prNumber <= 0
        then Left (InvalidRequest "repository and pull request must be exact")
        else Right GitHubAuthority {transport, repository, owner, name, prNumber, graphql}

-- | @/repos/{repository}@.
root :: GitHubAuthority -> Text
root authority = "/repos/" <> authority.repository

-- | @_SHA.fullmatch(value)@: exactly forty hexadecimal digits.
isSha :: Text -> Bool
isSha value = T.length value == 40 && T.all isHexDigit value

-- | @re.fullmatch(r"[0-9a-f]{40}", value)@.
isLowerSha :: Text -> Bool
isLowerSha value = T.length value == 40 && T.all (\c -> isDigit c || (isAsciiLower c && isHexDigit c)) value

malformed :: Text -> IO a
malformed = throwIO . boundary

-- | @GitHubObjectWriteError(f"GitHub did not prove {kind} creation")@.
objectWriteError :: Text -> GitHubBoundaryError
objectWriteError kind = (boundary ("GitHub did not prove " <> kind <> " creation")) {kind = ObjectWrite}

-- | @_get(path)@: the body of a 200 response.
getOk :: GitHubAuthority -> Text -> IO Json
getOk authority path = do
  response <- authority.transport.request "GET" path Nothing
  unless (response.status == 200) $
    malformed ("GitHub GET " <> fst (T.breakOn "?" path) <> " returned status " <> T.pack (show response.status))
  pure response.body

-- | @_created_sha(response, kind)@.
createdSha :: WireResponse -> Text -> IO Text
createdSha response kind = case response.body of
  Object members
    | response.status == 201
    , Just (String sha) <- lookup "sha" members
    , isLowerSha sha ->
        pure sha
  _ -> throwIO (objectWriteError kind)

-- | @create_tree(base_tree=…, entries=…)@: one blob per present entry
-- (in order), then the tree.
createTree :: GitHubAuthority -> Text -> [(Text, Text, Maybe ByteString)] -> IO Text
createTree authority baseTree entries = do
  tree <- forM entries $ \(path, mode, content) -> do
    sha <- case content of
      Nothing -> pure Null
      Just bytes -> do
        response <-
          authority.transport.request
            "POST"
            (root authority <> "/git/blobs")
            (Just [("content", String (TE.decodeLatin1 (Base64.encode bytes))), ("encoding", String "base64")])
        String <$> createdSha response "blob"
    pure (Object [("path", String path), ("mode", String mode), ("type", String "blob"), ("sha", sha)])
  response <-
    authority.transport.request
      "POST"
      (root authority <> "/git/trees")
      (Just [("base_tree", String baseTree), ("tree", Array tree)])
  createdSha response "tree"

-- | @create_commit(tree=…, parents=…, message=…, name=…, email=…)@.
createCommit :: GitHubAuthority -> Text -> [Text] -> Text -> Text -> Text -> IO Text
createCommit authority tree parents message name email = do
  let person = Object [("name", String name), ("email", String email)]
  response <-
    authority.transport.request
      "POST"
      (root authority <> "/git/commits")
      ( Just
          [ ("message", String message)
          , ("tree", String tree)
          , ("parents", Array (map String parents))
          , ("author", person)
          , ("committer", person)
          ]
      )
  createdSha response "commit"

-- | The CPython classes a @except KeyError, TypeError, ValueError@ clause
-- catches.
caughtByKeyTypeValue :: Text -> Bool
caughtByKeyTypeValue cls =
  cls `elem` ["KeyError", "TypeError", "ValueError", "UnicodeError", "UnicodeEncodeError", "UnicodeDecodeError", "JSONDecodeError"]

-- | Raised inside a @try@ block to reach its @except@ clause.
data Escape = Escape
  deriving stock (Show)

instance Exception Escape

escape :: IO a
escape = throwIO Escape

-- | @value[key]@ inside a @try@ that catches @KeyError@ and @TypeError@.
item :: Text -> Json -> IO Json
item key = \case
  Object members -> maybe escape pure (lookup key members)
  _ -> escape

-- | Run a @try@ block whose @except KeyError, TypeError, ValueError@
-- clause raises a boundary failure.
guarded :: Text -> IO a -> IO a
guarded message action =
  (action `catch` \Escape -> malformed message)
    `catch` \fault@(PythonFault cls _) -> if caughtByKeyTypeValue cls then malformed message else throwIO fault

-- | @pull_request()@.
pullRequest :: GitHubAuthority -> IO PullRequestSnapshot
pullRequest authority = do
  value <- getOk authority (root authority <> "/pulls/" <> T.pack (show authority.prNumber))
  let message = "GitHub pull request evidence is malformed"
  case value of
    Object _ -> pure ()
    _ -> malformed message
  guarded message $ do
    headValue <- item "head" value
    baseValue <- item "base" value
    user <- item "user" value
    repo <- either pyFault pure (Py.get "repo" headValue)
    let headRepository = case repo of
          Object members -> maybe Null id (lookup "full_name" members)
          _ -> Null
    sha <- item "sha" headValue
    baseSha <- item "sha" baseValue
    headRef <- item "ref" headValue
    baseRef <- item "ref" baseValue
    author <- item "login" user
    shaText <- exactSha sha
    _ <- exactSha baseSha
    baseReference <- getOk authority (root authority <> "/git/ref/heads/" <> Url.quote "" (Py.str baseRef))
    currentBase <- case baseReference of
      Object members
        | Just (Object object) <- lookup "object" members
        , Just (String current) <- lookup "sha" object
        , isSha current ->
            pure current
      _ -> escape
    state <- Py.str <$> item "state" value
    let mergeableState = maybe (String "unknown") id (lookup' "mergeable_state" value)
        url = maybe (String "") id (lookup' "html_url" value)
    (mergeableText, urlText, headRepositoryText) <- case (mergeableState, url, headRepository) of
      (String a, String b, String c) -> pure (a, b, c)
      _ -> escape
    draft <- Py.truthy <$> item "draft" value
    pure
      PullRequestSnapshot
        { repository = authority.repository
        , number = authority.prNumber
        , state
        , draft
        , head = T.toLower shaText
        , base = T.toLower currentBase
        , headRef = Py.str headRef
        , baseRef = Py.str baseRef
        , mergeable = maybe Null id (lookup' "mergeable" value)
        , merged = maybe False Py.truthy (lookup' "merged" value)
        , closed = state == "closed"
        , author = Py.str author
        , mergeableState = mergeableText
        , url = urlText
        , headRepository = headRepositoryText
        }
  where
    exactSha = \case
      String text | isSha text -> pure text
      _ -> escape

lookup' :: Text -> Json -> Maybe Json
lookup' key = \case
  Object members -> lookup key members
  _ -> Nothing

-- | @policy(base_ref)@: effective rules, else classic branch protection,
-- else none.
policy :: GitHubAuthority -> Text -> IO RepositoryPolicy
policy authority baseRef = do
  let encoded = Url.quote "" baseRef
  effective <- authority.transport.request "GET" (root authority <> "/rules/branches/" <> encoded) Nothing
  (rules, source) <-
    if
      | effective.status == 200 -> case effective.body of
          Array items | Just rules <- traverse asObject items -> pure (rules, "effective_rules")
          _ -> malformed "GitHub effective branch policy evidence is malformed"
      | effective.status == 404 -> do
          protection <- authority.transport.request "GET" (root authority <> "/branches/" <> encoded <> "/protection") Nothing
          if
            | protection.status == 200 -> case protection.body of
                Object members -> (,"branch_protection") <$> classicRules members
                _ -> malformed "GitHub branch protection evidence is malformed"
            | protection.status == 404 -> pure ([], "none")
            | otherwise -> malformed "GitHub branch policy evidence is incomplete"
      | otherwise -> malformed "GitHub effective branch policy evidence is incomplete"
  (strict, checks, approvals, conversations) <- derivePolicy rules
  let required = Set.toAscList checks
  pure
    RepositoryPolicy
      { strict
      , updateRequired = strict
      , requiredChecks = required
      , requiredApprovals = approvals
      , conversationResolution = conversations
      , source
      , digest = policyDigest strict required approvals conversations source
      }
  where
    asObject = \case
      Object members -> Just members
      _ -> Nothing

-- | The canonical policy digest.
policyDigest :: Bool -> [Text] -> Integer -> Bool -> Text -> Text
policyDigest strict required approvals conversations source =
  digest
    ( Object
        [ ("strict", Bool strict)
        , ("update_required", Bool strict)
        , ("required_checks", Array (map String required))
        , ("required_approvals", Int approvals)
        , ("conversation_resolution", Bool conversations)
        , ("source", String source)
        ]
    )

-- | @_classic_rules@.
classicRules :: [(Text, Json)] -> IO [[(Text, Json)]]
classicRules value = do
  checks <- optionalDict "required_status_checks" "GitHub branch protection status checks are malformed"
  review <- optionalDict "required_pull_request_reviews" "GitHub branch protection review policy is malformed"
  conversations <- optionalDict "required_conversation_resolution" "GitHub branch protection conversation policy is malformed"
  let field members key fallback = maybe fallback id (lookup key members)
      strict = field checks "strict" (Bool False)
      contexts = field checks "contexts" (Array [])
      count = field review "required_approving_review_count" (Int 0)
      resolution = field conversations "enabled" (Bool False)
  case (strict, contexts, count, resolution) of
    (Bool strictValue, Array items, Int n, Bool resolved)
      | Just names <- traverse context items
      , n >= 0 ->
          pure
            [ [ ("type", String "required_status_checks")
              , ( "parameters"
                , Object
                    [ ("strict_required_status_checks_policy", Bool strictValue)
                    , ("required_status_checks", Array [Object [("context", String name)] | name <- names])
                    ]
                )
              ]
            , [ ("type", String "pull_request")
              , ( "parameters"
                , Object
                    [ ("required_approving_review_count", Int n)
                    , ("required_review_thread_resolution", Bool resolved)
                    ]
                )
              ]
            ]
    _ -> malformed "GitHub branch protection policy is malformed"
  where
    optionalDict key message = case lookup key value of
      Nothing -> pure []
      Just Null -> pure []
      Just (Object members) -> pure members
      Just _ -> malformed message
    context = \case
      String name | not (T.null name) -> Just name
      _ -> Nothing

-- | @_derive_policy@.
derivePolicy :: [[(Text, Json)]] -> IO (Bool, Set.Set Text, Integer, Bool)
derivePolicy = foldM step (False, Set.empty, 0, False)
  where
    step (strict, checks, approvals, conversations) rule = do
      let ruleType = lookup "type" rule
          parameters = lookup "parameters" rule
      (strict', checks') <-
        if ruleType == Just (String "required_status_checks")
          then case parameters of
            Just (Object members)
              | Just (Bool policyStrict) <- lookup "strict_required_status_checks_policy" members -> do
                  required <- case lookup "required_status_checks" members of
                    Just (Array items) -> pure items
                    _ -> malformed "GitHub required checks are malformed"
                  added <- forM required $ \case
                    Object check | Just (String name) <- lookup "context" check, not (T.null name) -> pure name
                    _ -> malformed "GitHub required check is malformed"
                  pure (strict || policyStrict, foldr Set.insert checks added)
            _ -> malformed "GitHub required status policy is malformed"
          else pure (strict, checks)
      (approvals', conversations') <-
        if ruleType == Just (String "pull_request")
          then case parameters of
            Just (Object members)
              | Just (Int count) <- lookup "required_approving_review_count" members
              , count >= 0
              , Just (Bool resolution) <- lookup "required_review_thread_resolution" members ->
                  pure (max approvals count, conversations || resolution)
            _ -> malformed "GitHub pull request policy is malformed"
          else pure (approvals, conversations)
      pure (strict', checks', approvals', conversations')

-- | @human_review()@.
humanReview :: GitHubAuthority -> IO HumanReviewSnapshot
humanReview authority = do
  requested <- getOk authority (root authority <> "/pulls/" <> T.pack (show authority.prNumber) <> "/requested_reviewers")
  users <- case requested of
    Object members -> case lookup "users" members of
      Nothing -> throwIO (PythonFault "KeyError" "'users'")
      Just (Array items) -> pure items
      Just _ -> malformed "GitHub requested-reviewer evidence is malformed"
    _ -> malformed "GitHub requested-reviewer evidence is malformed"
  let requestedNames =
        Set.toAscList
          ( Set.fromList
              [ Py.str login
              | Object fields <- users
              , Just login <- [lookup "login" fields]
              , Py.truthy login
              ]
          )
  reviews <- authority.transport.pages (root authority <> "/pulls/" <> T.pack (show authority.prNumber) <> "/reviews?per_page=100")
  keyed <- forM reviews $ \review -> do
    let value = Object review
        submitted = Py.str (maybe (String "") id (lookup "submitted_at" review))
    identifier <- either pyFault pure (Py.intOf (maybe (Int 0) id (lookup "id" review)))
    pure ((submitted, identifier), value)
  latestRef <- newIORef (Map.empty :: Map.Map Text Text)
  let ordered = map snd (sortOn fst keyed)
  mapM_ (record latestRef) ordered
  latest <- Map.toAscList <$> readIORef latestRef
  (unresolved, capability) <- case authority.graphql of
    Nothing -> pure (Nothing, "threads_unavailable")
    Just graphql -> do
      outcome <- tryBoundary (graphql.reviewThreads authority.owner authority.name authority.prNumber)
      case outcome of
        Left _ -> pure (Nothing, "threads_unavailable")
        Right threads -> do
          counted <- forM threads $ \thread -> do
            resolved <- either pyFault pure (Py.get "isResolved" thread)
            pure (not (Py.truthy resolved) && not (viewerThread thread))
          pure (Just (length (filter id counted)), "available")
  pure
    HumanReviewSnapshot
      { requestedReviewers = requestedNames
      , latestReviews = latest
      , approvals = [name | (name, state) <- latest, state == "APPROVED"]
      , changesRequested = [name | (name, state) <- latest, state == "CHANGES_REQUESTED"]
      , unresolvedThreads = unresolved
      , threadsCapability = capability
      }
  where
    record latestRef review = do
      let login = case lookup' "user" review of
            Just (Object user) -> maybe Null id (lookup "login" user)
            _ -> Null
          state = Py.upper (Py.str (maybe (String "") id (lookup' "state" review)))
      when (Py.truthy login && state `elem` ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]) $
        if state == "DISMISSED"
          then modifyIORef' latestRef (Map.delete (Py.str login))
          else modifyIORef' latestRef (Map.insert (Py.str login) state)

tryBoundary :: IO a -> IO (Either GitHubBoundaryError a)
tryBoundary action = (Right <$> action) `catch` (pure . Left)

-- | @_viewer_thread@: whether the App itself opened the thread.
viewerThread :: Json -> Bool
viewerThread thread = case firstComment thread of
  Just first -> lookup "viewerDidAuthor" first == Just (Bool True)
  Nothing -> False

-- | @_first_comment@.
firstComment :: Json -> Maybe [(Text, Json)]
firstComment thread = case lookup' "comments" thread of
  Just (Object listing)
    | Just (Array (Object first : _)) <- lookup "nodes" listing -> Just first
  _ -> Nothing

-- | @_FINDING_MARKER_HEAD.search(body)@: the head of the first finding
-- marker in the body.
findingMarkerHead :: Text -> Maybe Text
findingMarkerHead body = go (T.breakOnAll prefix body)
  where
    prefix = "<!-- hamsterdan:finding operation="
    go = \case
      [] -> Nothing
      (_, rest) : others -> maybe (go others) Just (matchAt (T.drop (T.length prefix) rest))
    matchAt rest =
      let (operation, after) = T.break (\c -> c == ' ' || c == '>') rest
       in if T.null operation
            then Nothing
            else do
              afterHead <- T.stripPrefix " head=" after
              let (sha, tailText) = T.splitAt 40 afterHead
              if isLowerSha sha && " -->" `T.isPrefixOf` tailText then Just sha else Nothing

-- | @resolve_stale_finding_threads(current_head)@: resolve the App's own
-- unresolved finding threads left by superseded heads.
resolveStaleFindingThreads :: GitHubAuthority -> Text -> IO Int
resolveStaleFindingThreads authority currentHead = case authority.graphql of
  Nothing -> pure 0
  Just graphql -> do
    threads <- graphql.reviewThreads authority.owner authority.name authority.prNumber
    foldM (resolveOne graphql) 0 threads
  where
    resolveOne graphql resolved thread = do
      isResolved <- either pyFault pure (Py.get "isResolved" thread)
      if Py.truthy isResolved || not (viewerThread thread)
        then pure resolved
        else do
          let body = maybe "" (\first -> Py.str (maybe (String "") id (lookup "body" first))) (firstComment thread)
          case findingMarkerHead body of
            Just head' | head' /= currentHead -> do
              identifier <- maybe (throwIO (PythonFault "KeyError" "'id'")) pure (lookup' "id" thread)
              graphql.resolveReviewThread (Py.str identifier)
              pure (resolved + 1)
            _ -> pure resolved

-- | @base_current(pull)@: whether the head is not behind the base.
baseCurrent :: GitHubAuthority -> PullRequestSnapshot -> IO Bool
baseCurrent authority pull = do
  value <- getOk authority (root authority <> "/compare/" <> pull.base <> "..." <> pull.head)
  let message = "GitHub base comparison evidence is malformed"
  members <- case value of
    Object members -> pure members
    _ -> malformed message
  let status = maybe Null id (lookup "status" members)
  unless (Py.hashable status) $
    throwIO (PythonFault "TypeError" ("unhashable type: '" <> (if Py.isList status then "list" else "dict") <> "'"))
  unless (any (Py.pyEqText status) ["ahead", "behind", "diverged", "identical"]) (malformed message)
  case lookup "behind_by" members of
    Just (Int behind) | behind >= 0 -> pure (behind == 0)
    _ -> malformed message

-- | @comments()@.
comments :: GitHubAuthority -> IO [[(Text, Json)]]
comments authority = authority.transport.pages (root authority <> "/issues/" <> T.pack (show authority.prNumber) <> "/comments?per_page=100")

-- | @_object_collection(path, field)@.
objectCollection :: GitHubAuthority -> Text -> Text -> IO [[(Text, Json)]]
objectCollection authority start field = go (Just start) Set.empty Nothing []
  where
    go current seen total acc = case current of
      Nothing -> case total of
        Just count | toInteger (length acc) == count -> pure acc
        _ -> malformed "GitHub object collection pagination is incomplete"
      Just path -> do
        when (Set.member path seen || Set.size seen >= maxPages) $
          malformed "GitHub object pagination is cyclic or exceeds its bound"
        response <- authority.transport.request "GET" path Nothing
        body <- case response.body of
          Object members | response.status == 200 -> pure members
          _ -> malformed "GitHub object collection is unavailable"
        case (lookup field body, lookup "total_count" body) of
          (Just (Array items), Just (Int count))
            | Just page <- traverse object items
            , count >= 0
            , maybe True (== count) total ->
                go response.nextPath (Set.insert path seen) (Just count) (acc <> page)
          _ -> malformed "GitHub object collection evidence is malformed"
    object = \case
      Object members -> Just members
      _ -> Nothing

-- | @workflow_runs(workflow, head)@: the exact-head runs of the workflow
-- that belong to this pull request, newest attempt first.
workflowRuns :: GitHubAuthority -> Text -> Text -> IO [ActionsRunSnapshot]
workflowRuns authority workflow head' = do
  unless (isSha head') (throwIO (InvalidRequest "head must be an exact commit SHA"))
  values <-
    objectCollection
      authority
      ( root authority
          <> "/actions/workflows/"
          <> Url.quote "" workflow
          <> "/runs?event=pull_request&head_sha="
          <> T.toLower head'
          <> "&per_page=20"
      )
      "workflow_runs"
  -- The comprehension filters and validates each run in turn.
  runs <- fmap concat . forM values $ \value ->
    if lookup "head_sha" value == Just (String head')
      then do
        pulls <- runPullNumbers value
        if authority.prNumber `elem` pulls
          then (: []) <$> run value workflow authority.prNumber
          else pure []
      else pure []
  pure (sortOn (\candidate -> Down (candidate.attempt, candidate.id)) runs)

-- | @select_run(workflow, head)@.
selectRun :: GitHubAuthority -> Text -> Text -> IO (Maybe ActionsRunSnapshot)
selectRun authority workflow head' = do
  runs <- workflowRuns authority workflow head'
  pure (case runs of first : _ -> Just first; [] -> Nothing)

-- | @_run(value, workflow, pr_number)@.
run :: [(Text, Json)] -> Text -> Integer -> IO ActionsRunSnapshot
run value workflow prNumber = do
  pulls <- runPullNumbers value
  let field key = lookup key value
      expected = removePrefix workflow
  case (field "id", field "run_attempt", field "head_sha", field "event", field "path", field "status", maybe Null id (field "conclusion")) of
    (Just (Int identifier), Just (Int attempt), Just (String head'), Just (String "pull_request"), Just (String path), Just (String status), conclusion)
      | identifier > 0
      , attempt > 0
      , isSha head'
      , removePrefix path == expected
      , Just conclusionText <- optionalText conclusion
      , prNumber `elem` pulls ->
          pure
            ActionsRunSnapshot
              { id = identifier
              , head = T.toLower head'
              , workflow
              , attempt
              , status
              , conclusion = conclusionText
              , jobs = []
              }
    _ -> malformed "GitHub Actions run evidence is malformed or outside the requested PR workflow"
  where
    removePrefix text = maybe text id (T.stripPrefix ".github/workflows/" text)

optionalText :: Json -> Maybe (Maybe Text)
optionalText = \case
  Null -> Just Nothing
  String text -> Just (Just text)
  _ -> Nothing

-- | @_run_pull_numbers(value)@.
runPullNumbers :: [(Text, Json)] -> IO [Integer]
runPullNumbers value = case lookup "pull_requests" value of
  Just (Array pulls) | Just numbers <- traverse number pulls -> pure numbers
  _ -> malformed "GitHub Actions run pull request evidence is malformed"
  where
    number = \case
      Object pull | Just (Int n) <- lookup "number" pull, n > 0 -> Just n
      _ -> Nothing

-- | @jobs(run, required_checks)@: the attempt's jobs, plus a failed
-- placeholder for every required check the attempt does not report.
jobs :: GitHubAuthority -> ActionsRunSnapshot -> [Text] -> IO ActionsRunSnapshot
jobs authority snapshot requiredChecks = do
  values <-
    objectCollection
      authority
      (root authority <> "/actions/runs/" <> T.pack (show snapshot.id) <> "/attempts/" <> T.pack (show snapshot.attempt) <> "/jobs?per_page=100")
      "jobs"
  let required = Set.fromList requiredChecks
  observedJobs <- mapM (job required) values
  let observed = Set.fromList [j.name | j <- observedJobs]
      missing =
        [ ActionsJobSnapshot {id = 0, name, status = "completed", conclusion = Just "failure", required = True}
        | name <- Set.toAscList (Set.difference required observed)
        ]
  pure snapshot {jobs = observedJobs <> missing}

-- | @_job(value, required)@.
job :: Set.Set Text -> [(Text, Json)] -> IO ActionsJobSnapshot
job required value =
  case (lookup "id" value, lookup "name" value, lookup "status" value, maybe Null id (lookup "conclusion" value)) of
    (Just (Int identifier), Just (String name), Just (String status), conclusion)
      | identifier > 0
      , not (T.null name)
      , Just conclusionText <- optionalText conclusion ->
          pure ActionsJobSnapshot {id = identifier, name, status, conclusion = conclusionText, required = Set.member name required}
    _ -> malformed "GitHub Actions job evidence is malformed"

-- | The @run_result(run)@ mapping.
data RunResult = RunResult
  { runId :: Text
  , head :: Text
  , attempt :: Integer
  , status :: Text
  , conclusion :: Text
  , requiredJobs :: [Text]
  }
  deriving stock (Eq, Show)

-- | @run_result(run)@.
runResult :: ActionsRunSnapshot -> RunResult
runResult snapshot =
  let required = filter (.required) snapshot.jobs
      completed = snapshot.status == "completed"
      base = if completed then snapshot.conclusion else Nothing
      conclusion
        | completed && any (\j -> j.conclusion `notElem` [Nothing, Just "success", Just "skipped"]) required = Just "failure"
        | otherwise = base
   in RunResult
        { runId = T.pack (show snapshot.id)
        , head = snapshot.head
        , attempt = snapshot.attempt
        , status = snapshot.status
        , conclusion = case conclusion of
            Just text | not (T.null text) -> text
            _ -> "pending"
        , requiredJobs = map (.name) required
        }

-- | @actions_evidence(run, required_checks)@.
actionsEvidence :: GitHubAuthority -> ActionsRunSnapshot -> [Text] -> IO ActionsEvidence
actionsEvidence authority snapshot requiredChecks = do
  current <- jobs authority snapshot requiredChecks
  conclusion <- case (runResult current).conclusion of
    "pending" -> pure (if current.status == "in_progress" then InProgress else Queued)
    "success" -> pure Success
    "failure" -> pure Failure
    _ -> malformed "GitHub Actions conclusion is unsupported"
  let failed =
        sortOn
          (\(name, value) -> (name, maybe "" id value))
          [(j.name, j.conclusion) | j <- current.jobs, j.required, j.conclusion /= Just "success"]
  pure ActionsEvidence {run = current, conclusion, failedRequiredJobs = failed}

-- | @failure_logs(run, binary)@.
failureLogs :: GitHubAuthority -> ActionsRunSnapshot -> BinaryTransport -> IO ByteString
failureLogs authority snapshot binary = do
  bytes <-
    binary.download
      (root authority <> "/actions/runs/" <> T.pack (show snapshot.id) <> "/attempts/" <> T.pack (show snapshot.attempt) <> "/logs")
      maxLogBytes
  when (BS.length bytes > maxLogBytes) (malformed "GitHub Actions logs exceed their bound")
  pure bytes
