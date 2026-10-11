{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The agent protocol types of @hamsterdan.agents.protocol@: the requests
-- the host hands an agent runner, the results it gets back, the closed
-- failure vocabularies, and the runner seam itself.
--
-- Upstream these are plain frozen dataclasses (not pydantic). Their wire
-- spelling is @dataclasses.asdict(value)@ (every field, in declaration
-- order) passed to @json.dumps@; the host writes review requests with
-- @sort_keys=True@ for their identity and the Pi runner embeds requests in
-- its prompt envelope. The codecs here reproduce exactly that spelling.
-- Their decoders are strict (exact JSON types, unknown members refused,
-- defaults for the defaulted fields); the semantic result validation of
-- @_validate_result@ belongs to the agents package.
module Hamsterdan.Agents.Protocol
  ( -- * Requests
    ReviewRequest (..)
  , ConversationRequest (..)
  , CodingRequest (..)
  , ChangeRequest
  , RepairRequest
  , AgentRequest (..)

    -- * Results
  , ReviewResult (..)
  , ConversationResult (..)
  , CodingResult (..)
  , ChangeResult
  , RepairResult
  , AgentResult (..)

    -- * Closed vocabularies
  , ReviewVerdict (..)
  , CodingOutcome (..)
  , CodingRequestKind (..)

    -- * Failures
  , AgentResultCategory (..)
  , AgentCleanupCategory (..)
  , AgentProtocolError (..)
  , protocolError
  , retainResultCategory
  , retainCleanupCategory

    -- * The runner seam
  , AgentRunner (..)
  , Invocation (..)
  ) where

import Control.Exception (Exception)
import Data.Text (Text)
import Hamsterdan.Contracts.Codec

-- ---------------------------------------------------------------------------
-- Closed vocabularies
--
-- The dataclasses hold these as plain @str@ (the protocol corpus round-trips
-- any string through the records, so the records keep 'Text'). They are the
-- closed sets @_validate_result@ admits and the host acts on; read a
-- record's field with 'unspelling' and write one with 'spelling'.

-- | @ReviewResult.status@: @clear@, @blocking@ or @unable@.
data ReviewVerdict = VerdictClear | VerdictBlocking | VerdictUnable
  deriving stock (Bounded, Enum, Eq, Ord, Show)

instance Contract ReviewVerdict where
  contract = enum "ReviewVerdict" $ \case
    VerdictClear -> "clear"
    VerdictBlocking -> "blocking"
    VerdictUnable -> "unable"

-- | @CodingResult.status@: @changed@, @unchanged@ or @unable@.
data CodingOutcome = CodingChanged | CodingUnchanged | CodingUnable
  deriving stock (Bounded, Enum, Eq, Ord, Show)

instance Contract CodingOutcome where
  contract = enum "CodingOutcome" $ \case
    CodingChanged -> "changed"
    CodingUnchanged -> "unchanged"
    CodingUnable -> "unable"

-- | @CodingRequest.kind@ (and @CodingResult.kind@): @change@ or @repair@.
data CodingRequestKind = RequestChange | RequestRepair
  deriving stock (Bounded, Enum, Eq, Ord, Show)

instance Contract CodingRequestKind where
  contract = enum "CodingRequestKind" $ \case
    RequestChange -> "change"
    RequestRepair -> "repair"

-- | @ReviewRequest@.
data ReviewRequest = ReviewRequest
  { repository :: Text
  , pullRequest :: Integer
  , epoch :: Integer
  , head :: Text
  , base :: Text
  , diffPath :: Text
  , policy :: Object
  , reviewLenses :: [Text]
  , contextPaths :: [Text]
  , actionsEvidence :: [Object]
  , priorFindings :: [Object]
  , priorComments :: [Object]
  , priorReplies :: [Object]
  , appliedChanges :: [Object]
  }
  deriving stock (Eq, Show)

instance Contract ReviewRequest where
  contract =
    record "ReviewRequest" $
      ReviewRequest
        <$> field "repository" (.repository) text
        <*> field "pull_request" (.pullRequest) integer
        <*> field "epoch" (.epoch) integer
        <*> field "head" (.head) text
        <*> field "base" (.base) text
        <*> field "diff_path" (.diffPath) text
        <*> fieldDefault "policy" (.policy) [] object
        <*> fieldDefault "review_lenses" (.reviewLenses) [] (list text)
        <*> fieldDefault "context_paths" (.contextPaths) [] (list text)
        <*> fieldDefault "actions_evidence" (.actionsEvidence) [] (list object)
        <*> fieldDefault "prior_findings" (.priorFindings) [] (list object)
        <*> fieldDefault "prior_comments" (.priorComments) [] (list object)
        <*> fieldDefault "prior_replies" (.priorReplies) [] (list object)
        <*> fieldDefault "applied_changes" (.appliedChanges) [] (list object)

-- | @ReviewResult@.
data ReviewResult = ReviewResult
  { repository :: Text
  , pullRequest :: Integer
  , epoch :: Integer
  , head :: Text
  , base :: Text
  , status :: Text
  , findings :: [Object]
  , lineage :: [Object]
  }
  deriving stock (Eq, Show)

instance Contract ReviewResult where
  contract =
    record "ReviewResult" $
      ReviewResult
        <$> field "repository" (.repository) text
        <*> field "pull_request" (.pullRequest) integer
        <*> field "epoch" (.epoch) integer
        <*> field "head" (.head) text
        <*> field "base" (.base) text
        <*> field "status" (.status) text
        <*> field "findings" (.findings) (list object)
        <*> field "lineage" (.lineage) (list object)

-- | @ConversationRequest@.
data ConversationRequest = ConversationRequest
  { repository :: Text
  , pullRequest :: Integer
  , epoch :: Integer
  , head :: Text
  , base :: Text
  , commentContext :: Object
  , actor :: Object
  , dashboard :: Object
  , gates :: [Object]
  , findings :: [Object]
  , allowedIntents :: [Object]
  }
  deriving stock (Eq, Show)

instance Contract ConversationRequest where
  contract =
    record "ConversationRequest" $
      ConversationRequest
        <$> field "repository" (.repository) text
        <*> field "pull_request" (.pullRequest) integer
        <*> field "epoch" (.epoch) integer
        <*> field "head" (.head) text
        <*> field "base" (.base) text
        <*> field "comment_context" (.commentContext) object
        <*> field "actor" (.actor) object
        <*> field "dashboard" (.dashboard) object
        <*> field "gates" (.gates) (list object)
        <*> field "findings" (.findings) (list object)
        <*> field "allowed_intents" (.allowedIntents) (list object)

-- | @ConversationResult@.
data ConversationResult = ConversationResult
  { repository :: Text
  , pullRequest :: Integer
  , epoch :: Integer
  , head :: Text
  , base :: Text
  , intents :: [Object]
  }
  deriving stock (Eq, Show)

instance Contract ConversationResult where
  contract =
    record "ConversationResult" $
      ConversationResult
        <$> field "repository" (.repository) text
        <*> field "pull_request" (.pullRequest) integer
        <*> field "epoch" (.epoch) integer
        <*> field "head" (.head) text
        <*> field "base" (.base) text
        <*> field "intents" (.intents) (list object)

-- | @CodingRequest@ (also @ChangeRequest@ and @RepairRequest@).
data CodingRequest = CodingRequest
  { kind :: Text
  , repository :: Text
  , pullRequest :: Integer
  , epoch :: Integer
  , head :: Text
  , base :: Text
  , ref :: Text
  , selectedWork :: [Object]
  , failureEvidence :: [Object]
  , fingerprint :: Text
  , lineage :: [Object]
  , reproductionStatus :: Text
  , mergeBase :: Bool
  }
  deriving stock (Eq, Show)

type ChangeRequest = CodingRequest

type RepairRequest = CodingRequest

instance Contract CodingRequest where
  contract =
    record "CodingRequest" $
      CodingRequest
        <$> field "kind" (.kind) text
        <*> field "repository" (.repository) text
        <*> field "pull_request" (.pullRequest) integer
        <*> field "epoch" (.epoch) integer
        <*> field "head" (.head) text
        <*> field "base" (.base) text
        <*> field "ref" (.ref) text
        <*> fieldDefault "selected_work" (.selectedWork) [] (list object)
        <*> fieldDefault "failure_evidence" (.failureEvidence) [] (list object)
        <*> fieldDefault "fingerprint" (.fingerprint) "" text
        <*> fieldDefault "lineage" (.lineage) [] (list object)
        <*> fieldDefault "reproduction_status" (.reproductionStatus) "unknown" text
        <*> fieldDefault "merge_base" (.mergeBase) False bool

-- | @CodingResult@ (also @ChangeResult@ and @RepairResult@).
data CodingResult = CodingResult
  { kind :: Text
  , repository :: Text
  , pullRequest :: Integer
  , epoch :: Integer
  , head :: Text
  , base :: Text
  , ref :: Text
  , status :: Text
  , reproductionStatus :: Text
  , diff :: Text
  , changedFiles :: [Text]
  , validationEvidence :: [Object]
  , proposedCommitMessage :: Text
  }
  deriving stock (Eq, Show)

type ChangeResult = CodingResult

type RepairResult = CodingResult

instance Contract CodingResult where
  contract =
    record "CodingResult" $
      CodingResult
        <$> field "kind" (.kind) text
        <*> field "repository" (.repository) text
        <*> field "pull_request" (.pullRequest) integer
        <*> field "epoch" (.epoch) integer
        <*> field "head" (.head) text
        <*> field "base" (.base) text
        <*> field "ref" (.ref) text
        <*> field "status" (.status) text
        <*> field "reproduction_status" (.reproductionStatus) text
        <*> field "diff" (.diff) text
        <*> field "changed_files" (.changedFiles) (list text)
        <*> field "validation_evidence" (.validationEvidence) (list object)
        <*> field "proposed_commit_message" (.proposedCommitMessage) text

-- | @AgentRequest@: the union of the three request types.
data AgentRequest
  = AgentReview ReviewRequest
  | AgentConversation ConversationRequest
  | AgentCoding CodingRequest
  deriving stock (Eq, Show)

-- | @AgentResult@: the union of the three result types.
data AgentResult
  = ResultReview ReviewResult
  | ResultConversation ConversationResult
  | ResultCoding CodingResult
  deriving stock (Eq, Show)

-- | @AgentResultCategory@: closed, provider-neutral coding-result admission
-- outcomes.
data AgentResultCategory
  = RuntimeLifecycle
  | OutputSchema
  | Correlation
  | Unchanged
  | Unable
  | WorkspaceReconciliation
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Contract AgentResultCategory where
  contract = enum "AgentResultCategory" $ \case
    RuntimeLifecycle -> "runtime_lifecycle"
    OutputSchema -> "output_schema"
    Correlation -> "correlation"
    Unchanged -> "unchanged"
    Unable -> "unable"
    WorkspaceReconciliation -> "workspace_reconciliation"

-- | @AgentCleanupCategory@: cleanup uncertainty retained separately from
-- result admission.
data AgentCleanupCategory = CleanupUnverified
  deriving stock (Eq, Ord, Show, Bounded, Enum)

instance Contract AgentCleanupCategory where
  contract = enum "AgentCleanupCategory" $ \case
    CleanupUnverified -> "cleanup_unverified"

-- | @AgentProtocolError@. Python's constructor rejects a category outside
-- the closed vocabulary with @TypeError@; here the vocabulary is a type, so
-- that check cannot fail.
data AgentProtocolError = AgentProtocolError
  { reason :: Text
  , canceled :: Bool
  , timedOut :: Bool
  , resultCategory :: Maybe AgentResultCategory
  , cleanupCategory :: Maybe AgentCleanupCategory
  }
  deriving stock (Eq, Show)

instance Exception AgentProtocolError

-- | @AgentProtocolError(reason)@ with every flag and category unset.
protocolError :: Text -> AgentProtocolError
protocolError message = AgentProtocolError message False False Nothing Nothing

-- | @retain_result_category@: the first category sticks.
retainResultCategory :: AgentResultCategory -> AgentProtocolError -> AgentProtocolError
retainResultCategory category failure = case failure.resultCategory of
  Nothing -> failure {resultCategory = Just category}
  Just _ -> failure

-- | @retain_cleanup_category@: the first category sticks.
retainCleanupCategory :: AgentCleanupCategory -> AgentProtocolError -> AgentProtocolError
retainCleanupCategory category failure = case failure.cleanupCategory of
  Nothing -> failure {cleanupCategory = Just category}
  Just _ -> failure

-- | The keyword arguments every runner call takes.
data Invocation = Invocation
  { operation :: Text
  , attempt :: Integer
  , isCurrent :: Maybe (IO Bool)
  -- ^ @is_current@: whether the work is still wanted.
  }

-- | The @AgentRunner@ protocol: one capability per request kind, given the
-- repository URL. A runner signals refusal by throwing 'AgentProtocolError'.
data AgentRunner = AgentRunner
  { review :: Text -> ReviewRequest -> Invocation -> IO ReviewResult
  , converse :: Text -> ConversationRequest -> Invocation -> IO ConversationResult
  , code :: Text -> CodingRequest -> Invocation -> IO CodingResult
  }
