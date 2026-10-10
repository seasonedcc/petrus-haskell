{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Replays @test/corpus/effects.jsonl@ (scripts/gen_effects_corpus.py):
-- every authority read, Git object write, comment and rerun effect and
-- GraphQL call against the recorded provider replies. The port must issue
-- the reference's interactions (requests with byte-identical JSON bodies,
-- page reads, downloads, fence and fault calls, retry delays, context
-- reads) in the same order and reach the same outcome.
module EffectsCorpusSpec (spec) where

import Control.Exception (Exception, SomeException, fromException, throwIO, try)
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Corpus
import Hamsterdan.GitHub.Effects qualified as E
import Hamsterdan.GitHub.Gateway qualified as G
import Hamsterdan.GitHub.Models
import Hamsterdan.GitHub.Python (PythonFault (..))
import Hamsterdan.GitHub.Transport (githubGraphQL)
import Petrus.Json (Json (..), compact, dumps)
import Test.Hspec (Spec, describe, it, runIO)

spec :: Spec
spec = describe "reads, effects and GraphQL corpus" $ do
  rows <- runIO (readCorpus "effects.jsonl")
  let ops = nub [textOf (field "op" row) | row <- rows]
  forM_ ops $ \op -> do
    let selected = filter (\row -> textOf (field "op" row) == op) rows
    it (T.unpack op <> " reproduces every interaction and outcome (" <> show (length selected) <> " cases)") $ do
      mismatches <- newIORef []
      forM_ (zip [0 :: Int ..] selected) $ \(index, row) -> replay mismatches (T.unpack op <> " #" <> show index) row
      readIORef mismatches >>= expectNone

-- | The scripted fence refused.
data FenceRefused = FenceRefused
  deriving stock (Show)

instance Exception FenceRefused

-- | The port issued an interaction the reference did not.
newtype Diverged = Diverged String
  deriving stock (Show)

instance Exception Diverged

data Script = Script
  { events :: IORef [Json]
  , context :: String
  }

-- | Take the next recorded event, which must be of the given kind.
next :: Script -> Text -> String -> IO Json
next script kind description = do
  remaining <- readIORef script.events
  case remaining of
    event : rest | field "t" event == String kind -> do
      writeIORef script.events rest
      pure event
    event : _ -> throwIO (Diverged ("expected " <> T.unpack (canonical event) <> "\n  actual " <> description))
    [] -> throwIO (Diverged ("no more events; actual " <> description))

-- | The exact (order-preserving) compact spelling.
spelling :: Json -> Text
spelling value = either (T.pack . show) TE.decodeUtf8 (dumps compact value)

same :: Script -> String -> Json -> Json -> IO ()
same _ description expected actual =
  unless (spelling expected == spelling actual) $
    throwIO (Diverged (description <> "\n  expected " <> T.unpack (spelling expected) <> "\n  actual   " <> T.unpack (spelling actual)))

failureClassOf :: Text -> FailureClass
failureClassOf = \case
  "transport_ambiguity" -> TransportAmbiguity
  "transient_http_rejection" -> TransientHttpRejection
  "capability_denial" -> CapabilityDenial
  "payload_rejection" -> PayloadRejection
  _ -> ProviderRejection

raiseBoundary :: Json -> IO a
raiseBoundary spec' =
  throwIO
    GitHubBoundaryError
      { kind = Boundary
      , message = textOf (field "message" spec')
      , failureClass = failureClassOf (textOf (field "failure_class" spec'))
      , providerStatus = case field "provider_status" spec' of
          Int n -> Just (fromInteger n)
          _ -> Nothing
      , providerDetail = textOf (field "provider_detail" spec')
      }

scriptedTransport :: Script -> Transport
scriptedTransport script =
  Transport
    { request = \method path body -> do
        let shown = Object [("method", String method), ("path", String path), ("body", maybe Null Object body)]
        event <- next script "request" ("request " <> T.unpack (spelling shown))
        same script "request" (Object [("method", field "method" event), ("path", field "path" event), ("body", field "body" event)]) shown
        case member "raise" event of
          Just spec' -> raiseBoundary spec'
          Nothing -> do
            let reply = field "reply" event
            pure
              WireResponse
                { status = fromInteger (intOf (field "status" reply))
                , body = field "body" reply
                , nextPath = case field "next_path" reply of
                    String p -> Just p
                    _ -> Nothing
                }
    , pages = \path -> do
        event <- next script "pages" ("pages " <> T.unpack path)
        same script "pages" (field "path" event) (String path)
        case member "raise" event of
          Just spec' -> raiseBoundary spec'
          Nothing -> pure [members | Object members <- listOf (field "reply" event)]
    }

scriptedDownloads :: Script -> BinaryTransport
scriptedDownloads script =
  BinaryTransport
    { download = \path limit -> do
        event <- next script "download" ("download " <> T.unpack path)
        same script "download" (Array [field "path" event, field "limit" event]) (Array [String path, Int (toInteger limit)])
        case member "raise" event of
          Just spec' -> raiseBoundary spec'
          Nothing -> do
            let reply = field "reply" event
            pure (BS.replicate (fromInteger (intOf (field "length" reply))) (fromInteger (intOf (field "fill" reply))))
    }

scriptedFence :: Script -> E.Fence
scriptedFence script repository number epoch head' operation = do
  let actual = Array [String repository, Int number, Int epoch, String head', String operation]
  event <- next script "fence" ("fence " <> T.unpack (spelling actual))
  same script "fence" (field "args" event) actual
  case member "raise" event of
    Just _ -> throwIO FenceRefused
    Nothing -> pure ()

scriptedFault :: Script -> E.EffectFault
scriptedFault script phase repository number kind operation = do
  let actual = Array [String phase, String repository, Int number, String kind, String operation]
  event <- next script "fault" ("fault " <> T.unpack (spelling actual))
  same script "fault" (field "args" event) actual
  mapM_ raiseBoundary (member "raise" event)

scriptedDelay :: Script -> Double -> IO ()
scriptedDelay script seconds = do
  event <- next script "delay" ("delay " <> show seconds)
  let expected = case field "seconds" event of
        Int n -> fromInteger n
        Float d -> d
        _ -> -1
  unless (expected == seconds) $ throwIO (Diverged ("delay expected " <> show expected <> " actual " <> show seconds))

scriptedContext :: Script -> IO [Json]
scriptedContext script = listOf . field "reply" <$> next script "context" "context"

replay :: Mismatches -> String -> Json -> IO ()
replay mismatches context row = do
  events <- newIORef (listOf (field "events" row))
  let script = Script {events, context}
      args = field "args" row
      transport = scriptedTransport script
      graphql = if boolOf (field "graphql" args) then Just (githubGraphQL transport) else Nothing
      authority = either (error . show) id (G.githubAuthority transport "owner/repo" 7 graphql)
      publisher =
        either (error . show) id $
          E.commentPublisher
            transport
            "owner/repo"
            7
            "hamsterdan[bot]"
            (scriptedFence script)
            (if boolOf (field "fault" args) then Just (scriptedFault script) else Nothing)
            (scriptedDelay script)
  outcome <- try (runOperation script transport authority publisher (textOf (field "op" row)) args)
  case outcome of
    Left (e :: SomeException)
      | Just (Diverged detail) <- fromException e ->
          check mismatches (context <> " diverged") "" detail
    _ -> do
      remaining <- readIORef events
      check mismatches (context <> " unconsumed events") [] (map spelling remaining)
      check mismatches (context <> " outcome") (expectedOutcome (field "outcome" row)) (actualOutcome outcome)

-- | The recorded outcome, with the messages of CPython faults dropped.
expectedOutcome :: Json -> Text
expectedOutcome outcome = canonical $ case member "error" outcome of
  Just failure
    | textOf (field "class" failure) `elem` faultClasses
    , not (textOf (field "message" failure) `elem` refusalMessages) ->
        Object [("error", Object [("class", field "class" failure)])]
  _ -> outcome
  where
    faultClasses = ["KeyError", "TypeError", "AttributeError", "ValueError", "OverflowError"]
    refusalMessages =
      [ "repository and pull request must be exact"
      , "head must be an exact commit SHA"
      , "bot login must be the configured GitHub App bot login"
      , "publication marker identity is malformed"
      , "stable publication operation collided with a different payload"
      , "a native review batch requires anchored findings"
      , "a native review batch requires unique finding operations"
      , "GitHub rejected comment publication"
      , "GitHub rejected dashboard publication"
      , "GitHub rejected dashboard update"
      ]

actualOutcome :: Either SomeException Json -> Text
actualOutcome = \case
  Right value -> canonical (Object [("ok", value)])
  Left e -> canonical (Object [("error", errorJson e)])

errorJson :: SomeException -> Json
errorJson e
  | Just (failure :: GitHubBoundaryError) <- fromException e =
      Object
        [ ("class", String (if failure.kind == ObjectWrite then "GitHubObjectWriteError" else "GitHubBoundaryError"))
        , ("message", String failure.message)
        , ("failure_class", String (failureClassName failure.failureClass))
        , ("provider_status", maybe Null (Int . toInteger) failure.providerStatus)
        , ("provider_detail", String failure.providerDetail)
        ]
  | Just (InvalidRequest message) <- fromException e = refusal "ValueError" message
  | Just PublicationCollision <- fromException e = refusal "ValueError" "stable publication operation collided with a different payload"
  | Just (PublicationRejected operation) <- fromException e = refusal "ValueError" ("GitHub rejected " <> operation)
  | Just (RerunRefused message) <- fromException e = refusal "RerunRefusedError" message
  | Just FenceRefused <- fromException e = refusal "FenceRefused" "stale authority"
  | Just (PythonFault cls _) <- fromException e = Object [("class", String cls)]
  | otherwise = refusal "HaskellException" (T.pack (show e))
  where
    refusal cls message = Object [("class", String cls), ("message", String message)]

-- Arguments ------------------------------------------------------------------

runOf :: Json -> ActionsRunSnapshot
runOf value =
  ActionsRunSnapshot
    { id = intOf (field "id" value)
    , head = textOf (field "head" value)
    , workflow = textOf (field "workflow" value)
    , attempt = intOf (field "attempt" value)
    , status = textOf (field "status" value)
    , conclusion = optionalText (field "conclusion" value)
    , jobs =
        [ ActionsJobSnapshot
            { id = intOf (field "id" job)
            , name = textOf (field "name" job)
            , status = textOf (field "status" job)
            , conclusion = optionalText (field "conclusion" job)
            , required = boolOf (field "required" job)
            }
        | job <- listOf (field "jobs" value)
        ]
    }

optionalText :: Json -> Maybe Text
optionalText = \case
  String text -> Just text
  _ -> Nothing

findingOf :: Json -> FindingPublication
findingOf value =
  FindingPublication
    { operation = textOf (field "operation" value)
    , text = textOf (field "text" value)
    , path = textOf (field "path" value)
    , line = intOf (field "line" value)
    , relatedLocations = [(textOf p, intOf l) | Array [p, l] <- listOf (field "related_locations" value)]
    , suggestion = textOf (field "suggestion" value)
    , link = textOf (field "link" value)
    }

pullOf :: Json -> PullRequestSnapshot
pullOf value =
  PullRequestSnapshot
    { repository = textOf (field "repository" value)
    , number = intOf (field "number" value)
    , state = textOf (field "state" value)
    , draft = boolOf (field "draft" value)
    , head = textOf (field "head" value)
    , base = textOf (field "base" value)
    , headRef = textOf (field "head_ref" value)
    , baseRef = textOf (field "base_ref" value)
    , mergeable = field "mergeable" value
    , merged = boolOf (field "merged" value)
    , closed = boolOf (field "closed" value)
    , author = textOf (field "author" value)
    , mergeableState = textOf (field "mergeable_state" value)
    , url = textOf (field "url" value)
    , headRepository = textOf (field "head_repository" value)
    }

maybeText :: Json -> Maybe Text
maybeText = \case
  String text -> Just text
  _ -> Nothing

-- Outcomes -------------------------------------------------------------------

texts :: [Text] -> Json
texts = Array . map String

pullJson :: PullRequestSnapshot -> Json
pullJson pull =
  Object
    [ ("repository", String pull.repository)
    , ("number", Int pull.number)
    , ("state", String pull.state)
    , ("draft", Bool pull.draft)
    , ("head", String pull.head)
    , ("base", String pull.base)
    , ("head_ref", String pull.headRef)
    , ("base_ref", String pull.baseRef)
    , ("mergeable", pull.mergeable)
    , ("merged", Bool pull.merged)
    , ("closed", Bool pull.closed)
    , ("author", String pull.author)
    , ("mergeable_state", String pull.mergeableState)
    , ("url", String pull.url)
    , ("head_repository", String pull.headRepository)
    ]

policyJson :: RepositoryPolicy -> Json
policyJson policy =
  Object
    [ ("strict", Bool policy.strict)
    , ("update_required", Bool policy.updateRequired)
    , ("required_checks", texts policy.requiredChecks)
    , ("required_approvals", Int policy.requiredApprovals)
    , ("conversation_resolution", Bool policy.conversationResolution)
    , ("source", String policy.source)
    , ("digest", String policy.digest)
    ]

reviewJson :: HumanReviewSnapshot -> Json
reviewJson review =
  Object
    [ ("requested_reviewers", texts review.requestedReviewers)
    , ("latest_reviews", Array [texts [n, s] | (n, s) <- review.latestReviews])
    , ("approvals", texts review.approvals)
    , ("changes_requested", texts review.changesRequested)
    , ("unresolved_threads", maybe Null (Int . toInteger) review.unresolvedThreads)
    , ("threads_capability", String review.threadsCapability)
    ]

jobJson :: ActionsJobSnapshot -> Json
jobJson job =
  Object
    [ ("id", Int job.id)
    , ("name", String job.name)
    , ("status", String job.status)
    , ("conclusion", maybe Null String job.conclusion)
    , ("required", Bool job.required)
    ]

runJson :: ActionsRunSnapshot -> Json
runJson run =
  Object
    [ ("id", Int run.id)
    , ("head", String run.head)
    , ("workflow", String run.workflow)
    , ("attempt", Int run.attempt)
    , ("status", String run.status)
    , ("conclusion", maybe Null String run.conclusion)
    , ("jobs", Array (map jobJson run.jobs))
    ]

evidenceJson :: ActionsEvidence -> Json
evidenceJson evidence =
  Object
    [ ("run", runJson evidence.run)
    , ( "conclusion"
      , String $ case evidence.conclusion of
          Queued -> "queued"
          InProgress -> "in_progress"
          Success -> "success"
          Failure -> "failure"
      )
    , ("failed_required_jobs", Array [Array [String n, maybe Null String c] | (n, c) <- evidence.failedRequiredJobs])
    ]

resultJson :: G.RunResult -> Json
resultJson result =
  Object
    [ ("run_id", String result.runId)
    , ("head", String result.head)
    , ("attempt", Int result.attempt)
    , ("status", String result.status)
    , ("conclusion", String result.conclusion)
    , ("required_jobs", texts result.requiredJobs)
    ]

publicationJson :: PublicationResult -> Json
publicationJson result =
  Object
    [ ("status", String result.status)
    , ("reference", maybe Null (\r -> Object [("id", Int r.id), ("url", String r.url)]) result.reference)
    , ("capability_available", Bool result.capabilityAvailable)
    , ("inline", Bool result.inline)
    ]

bytesJson :: BS.ByteString -> Json
bytesJson bytes = Object [("fill", Int (if BS.null bytes then 0 else toInteger (BS.head bytes))), ("length", Int (toInteger (BS.length bytes)))]

-- Operations -----------------------------------------------------------------

runOperation :: Script -> Transport -> G.GitHubAuthority -> E.CommentPublisher -> Text -> Json -> IO Json
runOperation script transport authority publisher op args = case op of
  "authority" ->
    case G.githubAuthority transport (textOf (field "repository" args)) (intOf (field "pr" args)) Nothing of
      Left failure -> throwIO failure
      Right built -> pure (Object [("owner", String built.owner), ("name", String built.name), ("root", String (G.root built))])
  "pull_request" -> pullJson <$> G.pullRequest authority
  "policy" -> policyJson <$> G.policy authority (textOf (field "base_ref" args))
  "human_review" -> reviewJson <$> G.humanReview authority
  "resolve_stale" -> Int . toInteger <$> G.resolveStaleFindingThreads authority (textOf (field "current_head" args))
  "base_current" -> Bool <$> G.baseCurrent authority (pullOf (field "pull" args))
  "comments" -> Array . map Object <$> G.comments authority
  "workflow_runs" -> Array . map runJson <$> G.workflowRuns authority (textOf (field "workflow" args)) (textOf (field "head" args))
  "select_run" -> maybe Null runJson <$> G.selectRun authority (textOf (field "workflow" args)) (textOf (field "head" args))
  "jobs" -> runJson <$> G.jobs authority (runOf (field "run" args)) (map textOf (listOf (field "required" args)))
  "actions_evidence" -> evidenceJson <$> G.actionsEvidence authority (runOf (field "run" args)) (map textOf (listOf (field "required" args)))
  "run_result" -> pure (resultJson (G.runResult (runOf (field "run" args))))
  "failure_logs" -> bytesJson <$> G.failureLogs authority (runOf (field "run" args)) (scriptedDownloads script)
  "create_tree" ->
    String
      <$> G.createTree
        authority
        (textOf (field "base_tree" args))
        [ (textOf p, textOf m, contentOf c)
        | Array [p, m, c] <- listOf (field "entries" args)
        ]
  "create_commit" ->
    String
      <$> G.createCommit
        authority
        (textOf (field "tree" args))
        (map textOf (listOf (field "parents" args)))
        (textOf (field "message" args))
        (textOf (field "name" args))
        (textOf (field "email" args))
  "review_threads" -> Array <$> (githubGraphQL transport).reviewThreads (textOf (field "owner" args)) (textOf (field "name" args)) 7
  "resolve_thread" -> Null <$ (githubGraphQL transport).resolveReviewThread (textOf (field "thread" args))
  "cas_ref" ->
    Null
      <$ (githubGraphQL transport).compareAndSwapRef
        (textOf (field "repository" args))
        (textOf (field "ref" args))
        (textOf (field "expected" args))
        (textOf (field "commit" args))
  "publisher" ->
    case E.commentPublisher transport "owner/repo" 7 (textOf (field "bot_login" args)) (scriptedFence script) Nothing (scriptedDelay script) of
      Left failure -> throwIO failure
      Right built -> pure (Object [("bot_login", String built.botLogin), ("root", String built.root)])
  "marker" ->
    either throwIO (pure . String) (E.marker (textOf (field "kind" args)) (textOf (field "operation" args)) (textOf (field "head" args)))
  "immutable" ->
    publicationJson
      <$> E.immutable
        publisher
        (textOf (field "kind" args))
        (textOf (field "operation" args))
        (intOf (field "epoch" args))
        (textOf (field "head" args))
        (textOf (field "body" args))
        (maybeText (field "authority_operation" args))
        (map textOf (listOf (field "compatible" args)))
  "find" ->
    maybe Null publicationJson
      <$> E.findPublication
        publisher
        (textOf (field "kind" args))
        (textOf (field "operation" args))
        (textOf (field "head" args))
        (textOf (field "body" args))
        (map textOf (listOf (field "compatible" args)))
  "immutable_operation" ->
    publicationJson
      <$> E.immutableOperation
        publisher
        (textOf (field "kind" args))
        (textOf (field "operation" args))
        (textOf (field "body" args))
        ( scriptedContext script >>= \case
            [epoch, head'] -> pure (intOf epoch, textOf head')
            other -> error ("corpus: context " <> show other)
        )
        (map textOf (listOf (field "compatible" args)))
  "reminder_operation" ->
    publicationJson
      <$> E.reminderOperation
        publisher
        (textOf (field "operation" args))
        ( scriptedContext script >>= \case
            [epoch, head', reviewer, author] -> pure (intOf epoch, textOf head', maybeText reviewer, textOf author)
            other -> error ("corpus: context " <> show other)
        )
  "reminder" ->
    publicationJson
      <$> E.reminder
        publisher
        (textOf (field "operation" args))
        (intOf (field "epoch" args))
        (textOf (field "head" args))
        (maybeText (field "reviewer" args))
        (textOf (field "author" args))
        (maybeText (field "maintainer" args))
  "dashboard" ->
    publicationJson
      <$> E.dashboard publisher (textOf (field "operation" args)) (intOf (field "epoch" args)) (textOf (field "head" args)) (textOf (field "body" args))
  "finding" ->
    publicationJson
      <$> E.publishFinding
        publisher
        (findingOf (field "finding" args))
        (intOf (field "epoch" args))
        (textOf (field "head" args))
        (maybeText (field "authority_operation" args))
  "finding_find" ->
    maybe Null publicationJson
      <$> E.findingFind publisher (textOf (field "operation" (field "finding" args))) (textOf (field "head" args))
  "findings" ->
    Array . map publicationJson
      <$> E.publishFindings
        publisher
        (intOf (field "epoch" args))
        (textOf (field "head" args))
        (map findingOf (listOf (field "findings" args)))
        (textOf (field "authority_operation" args))
  "held" -> do
    let run = runOf (field "run" args)
    maybe Null publicationJson <$> E.held broker run.id run.head (textOf (field "operation" args))
  "issue" -> do
    issued <- E.issue broker (runOf (field "run" args)) (intOf (field "epoch" args)) (textOf (field "operation" args))
    pure
      ( Object
          [ ("result", publicationJson issued.result)
          , ("cut_run_id", Int issued.cutRunId)
          , ("cut_attempt", Int issued.cutAttempt)
          ]
      )
  "rerun_request" ->
    publicationJson <$> E.requestRerun broker (runOf (field "run" args)) (intOf (field "epoch" args)) (textOf (field "operation" args))
  other -> error ("corpus: unknown op " <> show other)
  where
    broker = E.CommentRerunBroker {authority, publisher}
    contentOf = \case
      Null -> Nothing
      String encoded -> Just (either error id (decodeBase64 encoded))
      other -> error ("corpus: content " <> show other)

decodeBase64 :: Text -> Either String BS.ByteString
decodeBase64 = B64.decode . TE.encodeUtf8
