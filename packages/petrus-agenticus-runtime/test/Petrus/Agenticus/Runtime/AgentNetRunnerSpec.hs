-- | Port of @tests/petrus/agenticus/runtime/test_agent_net_runner.py@.
--
-- The reference replaces @runner.repository@ with a failing object; here
-- the runner is created over a repository whose @save@ a test-owned switch
-- turns into that failure.
module Petrus.Agenticus.Runtime.AgentNetRunnerSpec (spec, scriptedBinding, workspace) where

import Control.Exception (throwIO, try)
import Control.Monad (void)
import Data.ByteString qualified as B
import Data.IORef
import Data.List (sort)
import Data.Maybe (isJust)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Activity (ActivityExecutionContext (..), ActivityInvocation)
import Petrus.Agenticus.Attachment.Binding
import Petrus.Agenticus.Attachment.Episode
import Petrus.Agenticus.Catalog.Descriptor (capabilityDescriptor)
import Petrus.Agenticus.Catalog.Resolution (mkResolutionSnapshot)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Contract (ToolMethod (..), capabilityScopedHands)
import Petrus.Agenticus.Hands.Gateway (HandsAdapter (..), StagedWrite (..), mkShellOutcome, mkStagedWrite, mkTestOutcome)
import Petrus.Agenticus.Hands.Grants (GrantSpec (..), grantSpec, openGrant)
import Petrus.Agenticus.Program.AgentNet
import Petrus.Agenticus.Runtime.AgentNetRunner
import Petrus.Agenticus.Runtime.Profiles (TerritoryProfile (..), agentAsNetA5Local, territoryIdentity)
import Petrus.Agenticus.Thread.Continuation (Continuation (..))
import Petrus.Agenticus.Thread.Identity (mkEpisodeId, mkThreadId)
import Petrus.Agenticus.Thread.Lifecycle (Episode (..), EpisodeOutcome (..), Thread (..), Turn (..), TurnOutcome (..), newThread)
import Petrus.Engine qualified as Engine
import Petrus.Impetus.History.Records (ActivityCompleted (..), ActivityRequested (..), Record (..))
import Petrus.Impetus.Instance.Firing (FiringOccurrence (..))
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

digest :: Text
digest = T.replicate 64 "a"

raises :: IO a -> ErrorClass -> Text -> Expectation
raises action cls fragment =
  try action >>= \case
    Left (e :: AgenticusError) -> do
      (e.errorClass, e.errorClass `isSubclassOf` cls) `shouldBe` (e.errorClass, True)
      (e.errorMessage, fragment `T.isInfixOf` e.errorMessage) `shouldBe` (e.errorMessage, True)
    Right _ -> expectationFailure ("expected " <> show cls <> " containing " <> show fragment)

-- | The scripted @Binding@: every lifecycle call is recorded.
scriptedBinding :: IO (AttachmentBinding, IORef [Text])
scriptedBinding = do
  events <- newIORef []
  let record e = modifyIORef' events (<> [e])
  pure
    ( AttachmentBinding
        { kind = "local-runner"
        , cancel = \_ -> record "cancel"
        , exportArchive = record "export" >> pure "archive"
        , settle = record "destroy" >> either throwIO pure (mkBindingSettlement "local-runner" "clean" True "")
        , motus = Nothing
        }
    , events
    )

-- | The scripted @Workspace@ adapter.
workspace :: IO (HandsAdapter, IORef [Text])
workspace = do
  calls <- newIORef []
  let record c = modifyIORef' calls (<> [c])
  pure
    ( HandsAdapter
        { read = \_ -> record "read" >> pure "safe"
        , search = \_ _ -> record "search" >> pure ["match"]
        , shell = \_ _ -> record "shell" >> either throwIO pure (mkShellOutcome 0 "safe" "" False)
        , stageWrite = \call path' _ -> record "stage" >> either throwIO pure (mkStagedWrite call path' (T.replicate 64 "b"))
        , commitWrite = \staged -> record "commit" >> pure staged.digest
        , discardWrite = \_ -> record "discard"
        , runTest = record "test" >> either throwIO pure (mkTestOutcome True (T.replicate 64 "c"))
        , discardAllStages = record "cleanup" >> pure 0
        }
    , calls
    )

-- | The scripted @Model@: pops one plan per phase and records each state.
model :: [(StopReason, [Proposal])] -> IO (ActivityInvocation -> ActivityExecutionContext -> IO Json, IORef [LoopState])
model plans = do
  remaining <- newIORef plans
  calls <- newIORef []
  pure
    ( \invocation ctx -> do
        invocation.activity `shouldBe` modelPhaseActivity
        state' <- either throwIO pure (loopStateFromData invocation.input)
        modifyIORef' calls (<> [state'])
        void (ctx.heartbeat (Just (Object [("phase", String "model")])))
        (stop, proposals) <-
          atomicModifyIORef' remaining $ \case
            x : xs -> (xs, x)
            [] -> ([], error "StopIteration")
        let suffix = T.pack (show state'.phase)
        either throwIO (pure . modelSettlementToData) $
          mkModelSettlement state' stop digest ("output-" <> suffix) ("continuation-" <> suffix) proposals
    , calls
    )

attachmentWith :: [ToolMethod] -> Integer -> Text -> IO (EpisodeAttachment, IORef [Text])
attachmentWith methods maxCalls identity = do
  (binding, events) <- scriptedBinding
  let snapshot =
        ok $
          mkResolutionSnapshot
            1
            [agentAsNetA5Local, capabilityScopedHands, capabilityDescriptor (territoryIdentity Local) [] []]
  current <-
    newEpisodeAttachment (ok (mkEpisodeId "episode-1")) snapshot binding identity 100 episodeOptions {clock = pure 1}
  void $
    openGrant
      (grants current)
      (grantSpec methods 90 maxCalls) {specWritablePaths = ["out.txt"], specAllowedArgv = [["printf", "ok"]]}
  pure (current, events)

attachment :: IO (EpisodeAttachment, IORef [Text])
attachment = attachmentWith [WorkspaceRead] 4 "attachment-1"

initialState :: [Text] -> Integer -> Integer -> LoopState
initialState capabilities phaseLimit toolLimit =
  ok (mkLoopState "episode-1" "turn-1" 1 phaseLimit 0 toolLimit Nothing Nothing 1 capabilities [])

initial :: LoopState
initial = initialState ["workspace_read"] 3 4

freshThread :: Thread
freshThread = ok (newThread (ok (mkThreadId "thread-1")) Nothing)

create :: FilePath -> (ActivityInvocation -> ActivityExecutionContext -> IO Json) -> EpisodeAttachment -> HandsAdapter -> IO AgentNetRunner
create root model' current adapter = createRunner root "agent-net-1" freshThread initial current model' adapter

loadAgain :: FilePath -> EpisodeAttachment -> HandsAdapter -> IO (AgentNetRunner, IORef [LoopState])
loadAgain root current adapter = do
  (m, calls) <- model []
  r <- loadRunner root current m adapter
  pure (r, calls)

readProposal :: Proposal
readProposal = ok (mkProposal "read-1" "workspace_read" (Object [("path", String "README.md")]))

lastEpisode :: Thread -> Episode
lastEpisode t = case Seq.viewr t.episodes of
  _ Seq.:> e -> e
  Seq.EmptyR -> error "no Episode"

lastTurn :: Episode -> Turn
lastTurn e = case Seq.viewr e.turns of
  _ Seq.:> t -> t
  Seq.EmptyR -> error "no Turn"

requestedActivities :: AgentNetRunner -> IO [Text]
requestedActivities r = do
  records' <- Engine.records (runnerEngine r)
  pure [a.activity | RActivityRequested a <- records']

completedOccurrences :: AgentNetRunner -> IO [Int]
completedOccurrences r = do
  records' <- Engine.records (runnerEngine r)
  pure [c.occurrence | RActivityCompleted c <- records']

withTemp :: (FilePath -> IO a) -> IO a
withTemp = withSystemTempDirectory "agent-net-runner"

spec :: Spec
spec = describe "runtime/test_agent_net_runner.py" $ do
  it "test_local_runner_uses_history_for_order_and_projects_thread_idempotently" $ withTemp $ \tmp -> do
    (current, events) <- attachment
    (adapter, calls) <- workspace
    (m, _) <- model [(ToolUse, [readProposal]), (Stop, [])]
    runner <- create tmp m current adapter
    projection <- drain runner 256

    projectionSettled projection `shouldBe` True
    (terminalCodeText . (.code) <$> projection.terminal) `shouldBe` Just "completed"
    [(p.outputReference, p.continuationReference) | p <- projection.appends]
      `shouldBe` [("output-1", "continuation-1"), ("output-2", "continuation-2")]
    map (.callId) projection.hands `shouldBe` ["read-1"]
    let episode = lastEpisode projection.thread
    episode.acceptedAppends `shouldBe` 2
    (lastTurn episode).outcome `shouldBe` Just TurnCompleted
    episode.settlement `shouldBe` Just EpisodeCompleted
    ((.stateReference) <$> episode.nextContinuation) `shouldBe` Just "continuation-2"
    readIORef calls `shouldReturn` ["read", "cleanup"]
    readIORef events `shouldReturn` ["export", "destroy"]
    requestedActivities runner `shouldReturn` [modelPhaseActivity, handsActivity, modelPhaseActivity]
    (length <$> completedOccurrences runner) `shouldReturn` 3

    durable <- (jsonThreadRepository (tmp </> "thread.json")).load
    durable `shouldBe` Just projection
    threadText <- B.readFile (tmp </> "thread.json")
    let value = ok (J.parseJson J.surrogateRefusingLoads threadText)
        members = case value of
          Object ms -> ms
          _ -> []
        threadJson = ok (J.dumpsText J.defaultDumps (maybe Null id (lookup "thread" members)))
    ("attachment" `T.isInfixOf` threadJson) `shouldBe` False
    (lookup "attachment" members >>= \case Object a -> lookup "attachment_id" a; _ -> Nothing)
      `shouldBe` Just (String "attachment-1")
    ("transcript" `B.isInfixOf` threadText) `shouldBe` False
    closeRunner runner

    (reloaded, _) <- loadAgain tmp current adapter
    runnerProjection reloaded `shouldReturn` projection
    raises (advance reloaded) AgentNetRunnerError "cannot advance"
    closeRunner reloaded

  it "test_quiescent_reconstruction_projects_unobserved_completion_without_redispatch" $ withTemp $ \tmp -> do
    (current, _) <- attachment
    (adapter, _) <- workspace
    (m, _) <- model [(Stop, [])]
    first <- create tmp m current adapter
    void (Engine.advance (runnerEngine first))
    void (Engine.advance (runnerEngine first))
    ((.appends) <$> runnerProjection first) `shouldReturn` []
    (null <$> Engine.inFlight (runnerEngine first)) `shouldReturn` True
    closeRunner first

    (resumed, replacement) <- loadAgain tmp current adapter
    (length . (.appends) <$> runnerProjection resumed) `shouldReturn` 1
    readIORef replacement `shouldReturn` []
    void (drain resumed 256)
    ((.settlement) . lastEpisode <$> runnerThread resumed) `shouldReturn` Just EpisodeCompleted
    readIORef replacement `shouldReturn` []
    closeRunner resumed

  it "test_reconstruction_finishes_thread_projection_after_attachment_settled_before_save" $ withTemp $ \tmp -> do
    (current, events) <- attachment
    (adapter, _) <- workspace
    (m, _) <- model [(Stop, [])]
    failing <- newIORef False
    let original = runnerThreadRepository tmp
        repository' =
          AgentNetThreadRepository
            { load = original.load
            , save = \expected value -> do
                refuse <- readIORef failing
                if refuse && isJust value.terminal
                  then ioError (userError "injected final Thread save refusal")
                  else original.save expected value
            }
    runner <- createRunnerWith repository' tmp "agent-net-1" freshThread initial current m adapter
    void (advance runner)
    void (advance runner)
    writeIORef failing True
    try (advance runner) >>= \case
      Left (e :: IOError) -> show e `shouldContain` "injected final"
      Right _ -> expectationFailure "expected the injected save refusal"
    settled current `shouldReturn` True
    readIORef events `shouldReturn` ["export", "destroy"]
    closeRunner runner

    (resumed, _) <- loadAgain tmp current adapter
    runnerSettled resumed `shouldReturn` True
    (isJust . (.terminal) <$> runnerProjection resumed) `shouldReturn` True
    ((.settlement) . lastEpisode <$> runnerThread resumed) `shouldReturn` Just EpisodeCompleted
    readIORef events `shouldReturn` ["export", "destroy"]
    closeRunner resumed

  it "test_reconstructed_in_flight_model_is_indeterminate_before_first_advance" $ withTemp $ \tmp -> do
    (current, events) <- attachment
    (adapter, calls) <- workspace
    (paid, paidCalls) <- model [(Stop, [])]
    first <- create tmp paid current adapter
    void (advance first)
    (length <$> readIORef paidCalls) `shouldReturn` 1
    (not . null <$> Engine.inFlight (runnerEngine first)) `shouldReturn` True
    closeRunner first

    (resumed, forbidden) <- loadAgain tmp current adapter
    runnerSettled resumed `shouldReturn` True
    halt' <- (.halt) <$> runnerProjection resumed
    ((.code) <$> halt') `shouldBe` Just Indeterminate
    ((.activity) <$> halt') `shouldBe` Just modelPhaseActivity
    episode <- lastEpisode <$> runnerThread resumed
    (lastTurn episode).outcome `shouldBe` Just TurnIndeterminate
    episode.settlement `shouldBe` Just EpisodeIndeterminate
    readIORef forbidden `shouldReturn` []
    readIORef calls `shouldReturn` []
    readIORef events `shouldReturn` ["cancel", "export", "destroy"]
    raises (advance resumed) AgentNetRunnerError "cannot advance"
    closeRunner resumed

  it "test_reconstructed_in_flight_hands_is_indeterminate_without_a_second_crossing" $ withTemp $ \tmp -> do
    (current, events) <- attachment
    (adapter, calls) <- workspace
    (m, _) <- model [(ToolUse, [readProposal])]
    first <- create tmp m current adapter
    let handsInFlight =
          Engine.inFlight (runnerEngine first) >>= \case
            o : _ | Just inv <- o.invocation -> pure (inv.activity == handsActivity)
            _ -> pure False
        loop = handsInFlight >>= \done' -> if done' then pure () else advance first >> loop
    loop
    readIORef calls `shouldReturn` ["read"]
    (length . (.appends) <$> runnerProjection first) `shouldReturn` 1
    closeRunner first

    callsBefore <- readIORef calls
    (resumed, _) <- loadAgain tmp current adapter
    halt' <- (.halt) <$> runnerProjection resumed
    ((.code) <$> halt') `shouldBe` Just Indeterminate
    ((.activity) <$> halt') `shouldBe` Just handsActivity
    readIORef calls `shouldReturn` (callsBefore <> ["cleanup"])
    readIORef events `shouldReturn` ["cancel", "export", "destroy"]
    completed <- completedOccurrences resumed
    (fmap (\h -> fromInteger h.occurrence `elem` completed) halt') `shouldBe` Just False
    closeRunner resumed

  it "test_in_process_activity_failure_settles_thread_and_attachment_before_propagating" $ withTemp $ \tmp -> do
    (current, events) <- attachment
    (adapter, calls) <- workspace
    modelCalls <- newIORef (0 :: Int)
    let failing _ _ = do
          modifyIORef' modelCalls (+ 1)
          ioError (userError "provider-failed")
    runner <- createRunner tmp "agent-net-1" freshThread initial current failing adapter
    void (advance runner)
    try (advance runner) >>= \case
      Left (Engine.EngineRuntimeError message) -> T.unpack message `shouldContain` "failed terminally"
      Left other -> expectationFailure ("unexpected Engine error " <> show other)
      Right _ -> expectationFailure "expected a terminal Activity failure"
    readIORef modelCalls `shouldReturn` 1
    halt' <- (.halt) <$> runnerProjection runner
    ((.code) <$> halt') `shouldBe` Just ActivityFailedHalt
    ((.activity) <$> halt') `shouldBe` Just modelPhaseActivity
    episode <- lastEpisode <$> runnerThread runner
    (lastTurn episode).outcome `shouldBe` Just TurnFailed
    episode.settlement `shouldBe` Just EpisodeFailed
    readIORef events `shouldReturn` ["cancel", "export", "destroy"]
    readIORef calls `shouldReturn` []
    closeRunner runner

  it "test_model_abort_cancels_attachment_and_projects_first_terminal_outcome" $ withTemp $ \tmp -> do
    (current, events) <- attachment
    (adapter, _) <- workspace
    (m, _) <- model [(Aborted, [])]
    runner <- create tmp m current adapter
    projection <- drain runner 256
    let episode = lastEpisode projection.thread
    (lastTurn episode).outcome `shouldBe` Just TurnCancelled
    episode.settlement `shouldBe` Just EpisodeCancelled
    readIORef events `shouldReturn` ["cancel", "export", "destroy"]
    (jsonThreadRepository (tmp </> "thread.json")).load `shouldReturn` Just projection
    closeRunner runner

  it "test_create_is_once_and_stale_attachment_or_grant_fails_before_history" $ withTemp $ \tmp -> do
    (current, _) <- attachment
    (adapter, _) <- workspace
    (m, _) <- model [(Stop, [])]
    runner <- create tmp m current adapter
    (m2, _) <- model []
    raises (create tmp m2 current adapter) AgentNetRunnerError "already exists"
    closeRunner runner

    (other, _) <- attachmentWith [WorkspaceRead] 4 "attachment-other"
    raises (loadAgain tmp other adapter) AgentNetRunnerError "does not match"

    (wrong, _) <- attachmentWith [WorkspaceTest] 4 "attachment-1"
    raises
      (createRunner (tmp </> "wrong") "agent-net-1" freshThread (initialState ["workspace_read"] 3 4) wrong m2 adapter)
      AgentNetRunnerError
      "does not match"
    doesFileExist (tmp </> "wrong" </> "history.jsonl") `shouldReturn` False
    doesFileExist (tmp </> "wrong" </> "thread.json") `shouldReturn` False

  it "test_mid_episode_grant_replacement_fails_before_another_engine_action" $ withTemp $ \tmp -> do
    (current, _) <- attachment
    (adapter, _) <- workspace
    (m, modelCalls) <- model [(Stop, [])]
    runner <- create tmp m current adapter
    void (openGrant (grants current) (grantSpec [WorkspaceTest] 90 4))
    raises (advance runner) AgentNetRunnerError "does not match"
    readIORef modelCalls `shouldReturn` []
    requestedActivities runner `shouldReturn` []
    closeRunner runner

  it "test_durable_projection_rejects_mutation_and_carries_no_private_payload" $ withTemp $ \tmp -> do
    (current, _) <- attachment
    (adapter, _) <- workspace
    (m, _) <- model [(Stop, [])]
    runner <- create tmp m current adapter
    let repository = jsonThreadRepository (tmp </> "thread.json")
    Just stale <- repository.load
    void (advance runner)
    void (advance runner)
    raises (repository.save (Just stale) stale) AgentNetRunnerError "changed concurrently"
    bytes <- B.readFile (tmp </> "thread.json")
    case ok (J.parseJson J.surrogateRefusingLoads bytes) of
      Object members ->
        sort (map fst members)
          `shouldBe` sort ["schema_version", "instance_id", "initial", "thread", "attachment", "appends", "hands", "terminal", "halt"]
      other -> expectationFailure ("not an object: " <> show other)
    ("private-model-output" `T.isInfixOf` TE.decodeUtf8 bytes) `shouldBe` False
    closeRunner runner
