-- | Provider-backed coding-agent and exact-CAS gate for V5 mutation
-- (@host/v5/mutation.py@).
--
-- Provider reconciliation precedes every authority read and agent call.
-- The full host/provider claim is checked both before and after the
-- agent; the exact ref CAS remains the final atomic head fence.
module Hamsterdan.Host.V5.Mutation
  ( MutationPublisher (..)
  , mutationPublisher
  , V5MutationGate (..)
  , mutationRequest
  , gitGate
  ) where

import Control.Exception (throwIO, try)
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Agents.Protocol
  ( AgentProtocolError (..)
  , AgentRunner (..)
  , CodingOutcome (..)
  , CodingRequest (..)
  , CodingRequestKind (..)
  , CodingResult (..)
  , Invocation (..)
  )
import Hamsterdan.Contracts.Codec (Contract, dump, spelling, unspelling)
import Hamsterdan.Contracts.ReadinessV5 (DeclinedM (..), FaultM (..), MovedM (..), MutWork (..), Phase (..), Pushed (..))
import Hamsterdan.GitHub.Models (GitHubBoundaryError (..))
import Hamsterdan.Host.Errors (catchGate, caughtReason)
import Hamsterdan.Host.GitPublish
  ( GitPublishError (..)
  , GitPublishResult (..)
  , GitReconciliation (..)
  , HostGitPublisher
  , PublicationCategory (..)
  , categoryName
  , payloadDigest
  )
import Hamsterdan.Host.GitPublish qualified as Git
import Hamsterdan.Host.Python (ValueError (..), sha256HexText)
import Hamsterdan.Host.V5.Claim (ClaimReader, CurrentClaim (..))
import Hamsterdan.Readiness.NetV5.Gating (Variant, variantOf)
import Petrus.Json (Json (..))

-- | The publisher surface the gate binds to.
data MutationPublisher = MutationPublisher
  { reconcile :: Text -> Text -> Text -> Text -> Bool -> IO GitReconciliation
  -- ^ @reconcile(operation=, payload_digest=, expected_head=, base_head=, merge_base=)@
  , publish :: CodingResult -> Text -> Text -> Text -> Text -> Bool -> IO GitPublishResult
  -- ^ @publish(result, operation=, payload_digest=, expected_head=, base_head=, merge_base=)@
  }

mutationPublisher :: HostGitPublisher -> MutationPublisher
mutationPublisher p = MutationPublisher {reconcile = Git.reconcile p, publish = Git.publish p}

-- | @V5MutationGate(repository, pull_request, runner, publisher,
-- public_clone_url, claim)@.
data V5MutationGate = V5MutationGate
  { repository :: Text
  , pullRequest :: Integer
  , runner :: AgentRunner
  , publisher :: MutationPublisher
  , publicCloneUrl :: Text
  , claim :: ClaimReader
  }

-- | @V5MutationGate.request(repository, pull_request, work)@.
mutationRequest :: Text -> Integer -> MutWork -> IO CodingRequest
mutationRequest repository pullRequest work = do
  let operation = "mutation:" <> repository <> ":pr:" <> T.pack (show pullRequest) <> ":" <> work.opKey
      ref = "hamsterdan/mutation/" <> T.take 32 (sha256HexText operation)
  (fingerprint, selectedWork, failureEvidence, lineage) <-
    if work.kind == "repair"
      then do
        let prefix = "repair:" <> work.lineage <> ":"
            rest = T.drop (T.length prefix) work.op
        if T.null work.lineage
          || not (prefix `T.isPrefixOf` work.op)
          || T.null rest
          || not (T.null work.instruction)
          || work.runId <= 0
          || work.attempt <= 0
          then throwIO (ValueError "repair mutation payload is malformed")
          else
            pure
              ( rest
              , []
              , [ [ ("head", String work.head)
                  , ("run_id", Int work.runId)
                  , ("attempt", Int work.attempt)
                  , ("conclusion", String "failure")
                  , ("fingerprint", String rest)
                  ]
                ]
              , [[("kind", String "repair_budget"), ("lineage", String work.lineage), ("operation", String work.op)]]
              )
      else
        if work.kind `notElem` ["change", "update_base", "resolve_conflict"]
          then throwIO (ValueError "mutation kind is malformed")
          else pure ("", [[("kind", String work.kind), ("request", String work.instruction)]], [], [])
  pure
    CodingRequest
      { kind = spelling (if work.kind == "repair" then RequestRepair else RequestChange)
      , repository
      , pullRequest
      , epoch = work.incarnation
      , head = work.head
      , base = work.base
      , ref
      , selectedWork
      , failureEvidence
      , fingerprint
      , lineage
      , reproductionStatus = "unknown"
      , mergeBase = work.kind `elem` ["update_base", "resolve_conflict"]
      }

agentCategory :: AgentProtocolError -> Text
agentCategory e
  | e.timedOut = "timed_out"
  | e.canceled = "canceled"
  | Just c <- e.resultCategory = enumValue c
  | Just c <- e.cleanupCategory = enumValue c
  | otherwise = "protocol"

enumValue :: (Contract a) => a -> Text
enumValue c = case dump c of
  String t -> t
  other -> T.pack (show other)

orRepr :: Text -> Text -> Text
orRepr cls message = if T.null message then cls <> "()" else message

-- | @git_gate(work)@.
gitGate :: V5MutationGate -> MutWork -> IO Variant
gitGate g work = do
  request <- mutationRequest g.repository g.pullRequest work
  let agentOperation = "mutation:" <> g.repository <> ":pr:" <> T.pack (show g.pullRequest) <> ":" <> work.opKey
      digest =
        payloadDigest
          ( Object
              [ ("schema_version", Int 1)
              , ("semantic_operation", String work.op)
              , ("policy", String work.policy)
              , ("coding_request", dump request)
              ]
          )
      expected = CurrentClaim PhaseRunning work.incarnation work.head work.base work.policy
      fault reason =
        variantOf
          FaultM
            { op = work.op
            , opKey = work.opKey
            , head = work.head
            , base = work.base
            , policy = work.policy
            , reason
            , incarnation = work.incarnation
            , kind = work.kind
            , instruction = work.instruction
            , runId = work.runId
            , attempt = work.attempt
            }
      pushed newHead =
        variantOf Pushed {op = work.op, opKey = work.opKey, head = work.head, newHead, incarnation = work.incarnation, lineage = work.lineage}
      moved current = do
        let phase = current.phase
        pure $
          variantOf
            MovedM
              { op = work.op
              , opKey = work.opKey
              , head = work.head
              , incarnation = work.incarnation
              , observed = current.head
              , observedBase = current.base
              , observedPolicy = current.policy
              , observedIncarnation = current.incarnation
              , observedPhase = phase
              }
      declined category reason =
        variantOf DeclinedM {op = work.op, opKey = work.opKey, head = work.head, incarnation = work.incarnation, category, reason}
      reconcileOnce = do
        outcome <- try (try (g.publisher.reconcile work.opKey digest work.head work.base request.mergeBase))
        pure $ case outcome of
          Left (e :: GitPublishError) -> Left (fault (orRepr "GitPublishError" e.reason))
          Right (Left (e :: GitHubBoundaryError)) -> Left (fault (orRepr "GitHubBoundaryError" e.message))
          Right (Right r) -> Right r
      readClaim = catchGate (Right <$> g.claim) (pure . Left . fault . caughtReason)
  first <- reconcileOnce
  case first of
    Left terminal -> pure terminal
    Right r | r.disposition == Git.OperationExisting -> pure (pushed r.commit)
    Right _ -> do
      before <- readClaim
      case before of
        Left terminal -> pure terminal
        Right current | current /= expected -> moved current
        Right _ -> do
          ran <-
            try $
              g.runner.code
                g.publicCloneUrl
                request
                Invocation {operation = agentOperation, attempt = 1, isCurrent = Just ((== expected) <$> g.claim)}
          after <- readClaim
          case after of
            Left terminal -> pure terminal
            Right current | current /= expected -> moved current
            Right _ -> case ran of
              Left (e :: AgentProtocolError) -> pure (declined (agentCategory e) (orRepr "AgentProtocolError" e.reason))
              Right result
                | correlation result /= requestCorrelation request ->
                    pure (declined "correlation" "agent result did not match its request")
                | unspelling result.status /= Just CodingChanged ->
                    pure
                      ( declined
                          (maybe "output_schema" spelling (unspelling @CodingOutcome result.status))
                          "agent produced no publishable change"
                      )
                | otherwise -> do
                    outcome <- try (try (g.publisher.publish result work.opKey digest work.head work.base request.mergeBase))
                    case outcome of
                      Right (Right published) -> pure (pushed published.head)
                      Right (Left (e :: GitHubBoundaryError)) -> pure (fault (orRepr "GitHubBoundaryError" e.message))
                      Left (e :: GitPublishError)
                        | e.category `elem` [Correlation, PatchAdmission] ->
                            pure (declined (categoryName e.category) (orRepr "GitPublishError" e.reason))
                        | e.category == CurrentAuthority -> do
                            current <- readClaim
                            either pure moved current
                        | e.category == RefCas -> do
                            again <- reconcileOnce
                            case again of
                              Left terminal -> pure terminal
                              Right r | r.disposition == Git.OperationExisting -> pure (pushed r.commit)
                              Right _ -> pure (fault (orRepr "GitPublishError" e.reason))
                        | otherwise -> pure (fault (orRepr "GitPublishError" e.reason))
  where
    correlation (r :: CodingResult) = (r.kind, r.repository, r.pullRequest, r.epoch, r.head, r.base, r.ref)
    requestCorrelation (r :: CodingRequest) = (r.kind, r.repository, r.pullRequest, r.epoch, r.head, r.base, r.ref)
