-- | The coding-activity cases of @tests/unit/agents/test_pi.py@: the Pi
-- native runner (over the reference's runtime doubles) behind the host's
-- V5 mutation gate. They live here because the gate is a host module; the
-- adapter-only cases are in @hamsterdan-agents@'s @PiSpec@.
module PiActivitySpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Agents.Pi
import Hamsterdan.Agents.Pi.Doubles
import Hamsterdan.Agents.Protocol hiding (Correlation)
import Hamsterdan.Agents.Protocol qualified as P
import Hamsterdan.Contracts.Codec (Contract, dump, validate)
import Hamsterdan.Contracts.ReadinessV5 (DeclinedM (..), MutWork (..), Pushed (..))
import Hamsterdan.Host.GitPublish (GitPublishResult (..), GitReconciliation (..), OperationDisposition (..))
import Hamsterdan.Host.V5.Claim (CurrentClaim (..), Phase (..))
import Hamsterdan.Host.V5.Mutation
import Hamsterdan.Readiness.NetV5.Gating (Variant (..))
import Petrus.Agenticus.Thread.Lifecycle (TurnOutcome (..))
import Petrus.Json (Json (..), defaultDumps, dumpsText)
import Test.Hspec

headSha, baseSha :: Text
headSha = T.replicate 40 "a"
baseSha = T.replicate 40 "b"

-- | @mutation_work(operation)@.
mutationWork :: Text -> MutWork
mutationWork operation =
  MutWork
    { op = "change"
    , opKey = operation
    , head = headSha
    , base = baseSha
    , policy = "policy"
    , incarnation = 2
    , lineage = ""
    , kind = "change"
    , instruction = "apply the bounded change"
    , runId = 0
    , attempt = 0
    }

-- | @mutation_agent_operation(operation)@.
mutationAgentOperation :: Text -> Text
mutationAgentOperation operation = "mutation:owner/repo:pr:7:" <> operation

-- | @activity_coding_result(operation, status=, head=)@.
activityCodingResult :: Text -> Text -> Text -> IO Json
activityCodingResult operation status headValue = do
  request <- mutationRequest "owner/repo" 7 (mutationWork operation)
  let isChanged = status == "changed"
  pure $
    Object
      [ ("kind", String "change")
      , ("repository", String "owner/repo")
      , ("pull_request", Int 7)
      , ("epoch", Int 2)
      , ("head", String headValue)
      , ("base", String baseSha)
      , ("ref", String request.ref)
      , ("status", String status)
      , ("reproduction_status", String "not_attempted")
      , ("diff", String (if isChanged then "untrusted" else ""))
      , ("changed_files", Array (if isChanged then [String "bounded.txt"] else []))
      , ("validation_evidence", Array (if isChanged then [Object [("check", String "passed")]] else []))
      , ("proposed_commit_message", String (if isChanged then "Apply bounded change" else ""))
      ]

-- | @ActivityPublisher()@.
data ActivityPublisher = ActivityPublisher {calls :: IORef Int, result :: IORef (Maybe CodingResult)}

-- | @run_coding_activity(subject, runtime, operation)@.
runCodingActivity :: PiNativeRunner -> Text -> IO (Variant, ActivityPublisher)
runCodingActivity subject operation = do
  publisher <- ActivityPublisher <$> newIORef 0 <*> newIORef Nothing
  let gate =
        V5MutationGate
          { repository = "owner/repo"
          , pullRequest = 7
          , runner = piAgentRunner subject
          , publisher =
              MutationPublisher
                { reconcile = \_ _ _ _ _ -> pure (GitReconciliation OperationAbsent headSha "" [])
                , publish = \value _ _ _ _ _ -> do
                    modifyIORef' publisher.calls (+ 1)
                    writeIORef publisher.result (Just value)
                    pure (GitPublishResult (T.replicate 40 "c") False)
                }
          , publicCloneUrl = testUrl
          , claim = pure (CurrentClaim PhaseRunning 2 headSha baseSha "policy")
          }
  effect <- gitGate gate (mutationWork operation)
  pure (effect, publisher)

decode :: forall a. (Contract a) => Text -> Variant -> IO a
decode name v = do
  v.name `shouldBe` name
  either (fail . show) pure (validate @a v.fields)

enumText :: (Contract a) => a -> Text
enumText c = case dump c of String t -> t; other -> T.pack (show other)

declined :: Variant -> AgentResultCategory -> Expectation
declined effect category = do
  out <- decode @DeclinedM "DeclinedM" effect
  out.category `shouldBe` enumText category

rendered :: Json -> Text
rendered value = either (const "") id (dumpsText defaultDumps value)

spec :: Spec
spec = describe "tests/unit/agents/test_pi.py" $ do
  describe "test_coding_activity_retains_each_adapter_admission_failure_without_retry_or_publication" $
    forM_
      [ ("runtime", RuntimeLifecycle)
      , ("schema", OutputSchema)
      , ("correlation", P.Correlation)
      , ("workspace", WorkspaceReconciliation)
      ]
      $ \(name, category) -> it (T.unpack name) $ do
        let operationId = "change:admission-" <> name
        output <- activityCodingResult operationId "unchanged" (if name == "correlation" then T.replicate 40 "c" else headSha)
        operation <-
          newFakeOperation
            (mutationAgentOperation operationId)
            (if name == "runtime" then TurnFailed else TurnCompleted)
            True
        (subject, runtime) <- fakeRunner output operation
        case name of
          "schema" -> writeIORef runtime.output "not-json private model prose"
          "workspace" -> writeIORef runtime.archive ""
          _ -> pure ()
        (effect, publisher) <- runCodingActivity subject operationId
        declined effect category
        length <$> readIORef runtime.started `shouldReturn` 1
        readIORef publisher.calls `shouldReturn` 0

  describe "test_coding_activity_retains_valid_nonmutation_outcome_without_retry_or_publication" $
    forM_ [("unchanged", Unchanged), ("unable", Unable)] $ \(status, category) -> it (T.unpack status) $ do
      let operationId = "change:admission-" <> status
      output <- activityCodingResult operationId status headSha
      (subject, runtime) <- fakeRunner output =<< newFakeOperation (mutationAgentOperation operationId) TurnCompleted True
      (effect, publisher) <- runCodingActivity subject operationId
      declined effect category
      length <$> readIORef runtime.started `shouldReturn` 1
      readIORef publisher.calls `shouldReturn` 0

  it "test_coding_activity_passes_accepted_changed_result_to_existing_publisher" $ do
    let operationId = "change:admission-changed"
    output <- activityCodingResult operationId "changed" headSha
    (subject, runtime) <- fakeRunner output =<< newFakeOperation (mutationAgentOperation operationId) TurnCompleted True
    (effect, publisher) <- runCodingActivity subject operationId
    out <- decode @Pushed "Pushed" effect
    out.newHead `shouldBe` T.replicate 40 "c"
    readIORef publisher.calls `shouldReturn` 1
    accepted <- maybe (fail "publisher.result is None") pure =<< readIORef publisher.result
    accepted.diff `shouldBe` "canonical diff"
    accepted.changedFiles `shouldBe` ["bounded.txt"]
    length <$> readIORef runtime.started `shouldReturn` 1

  it "test_operation_cleanup_failure_cannot_overwrite_first_output_admission_cause" $ do
    let operationId = "change:admission-cleanup"
    output <- activityCodingResult operationId "unchanged" headSha
    (subject, runtime) <- fakeRunner output =<< newFakeOperation (mutationAgentOperation operationId) TurnCompleted False
    writeIORef runtime.output "not-json private model prose"
    (effect, publisher) <- runCodingActivity subject operationId
    declined effect OutputSchema
    readIORef publisher.calls `shouldReturn` 0
    length <$> readIORef runtime.started `shouldReturn` 1

  it "test_workspace_preparation_and_cleanup_failure_retains_both_closed_causes" $ do
    let operationId = "change:admission-preparation"
    output <- activityCodingResult operationId "unchanged" headSha
    operation <- newFakeOperation (mutationAgentOperation operationId) TurnCompleted True
    runtime <- newFakeRuntime operation (rendered output) []
    let failedWorkspaces = PiWorkspaceProvider $ \_ _ _ _ _ -> throwIO (PiWorkspaceCleanupError True)
    subject <- either (fail . show) pure (newPiNativeRunner (fakePiRuntime runtime) failedWorkspaces defaultPiRunnerOptions)
    (effect, publisher) <- runCodingActivity subject operationId
    declined effect WorkspaceReconciliation
    null <$> readIORef runtime.started `shouldReturn` True
    readIORef publisher.calls `shouldReturn` 0
