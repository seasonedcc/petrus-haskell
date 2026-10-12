-- | @tests/unit/host/test_publication_qualification.py@, case for case
-- (same names). The cases whose inputs the port's types cannot express (a
-- non-boolean callback result, a @str@ subclass, a non-string category)
-- are in "TypeGuaranteeSpec".
module PublicationQualificationSpec (spec, changeResult) where

import Control.Exception (throwIO)
import Control.Monad (forM_, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Agents.Protocol (AgentCleanupCategory, AgentResultCategory (OutputSchema))
import Hamsterdan.Agents.Protocol qualified as Agents
import Hamsterdan.Contracts.Codec (Contract (..), encode)
import Hamsterdan.Contracts.Readiness (ChangeResult (..))
import Hamsterdan.Python.Object (PV (..), pythonError)
import Hamsterdan.Host.GitPublish (GitPublishError (..), PublicationCategory (GitOperation, Idempotency, PatchAdmission, RefCas), categoryName)
import Hamsterdan.Host.PublicationQualification
import Petrus.Json (Json (..))
import Petrus.Posix.At (FileStat (..), Follow (..), isDirectory, permissionBits)
import Petrus.Posix.At qualified as At
import Support (shouldEqualPy)
import System.Directory (createDirectory, doesPathExist, renameDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Directory qualified as PosixDir
import System.Posix.Files (createSymbolicLink, setFileCreationMask, setFileMode)
import Test.Hspec

-- | @result(ok=..., category=..., agent_result=..., agent_cleanup=...)@.
changeResult :: Bool -> Text -> Text -> Text -> ChangeResult
changeResult ok category agentResult agentCleanup =
  ChangeResult
    { epoch = 2
    , head = T.replicate 40 "a"
    , ok
    , provisionalHead = ""
    , fingerprint = ""
    , lineage = ""
    , operation = "change:diagnostic"
    , publicationCategory = category
    , agentResultCategory = agentResult
    , agentCleanupCategory = agentCleanup
    }

wire :: Contract c => c -> Text
wire c = case encode contract c of
  String s -> s
  _ -> ""

-- | @tmp_path / name@, created with mode 0700.
privateDirectory :: FilePath -> FilePath -> IO FilePath
privateDirectory tmp name = do
  let path = tmp </> name
  PosixDir.createDirectory path 0o700
  setFileMode path 0o700
  pure path

recorder :: IORef [Text] -> Text -> IO Bool
recorder calls name = modifyIORef' calls (<> [name]) >> pure True

pushCalls :: IORef [[Text]] -> [Text] -> IO Int
pushCalls calls command = modifyIORef' calls (<> [command]) >> pure 0

a40, b40 :: Text
a40 = T.replicate 40 "a"
b40 = T.replicate 40 "b"

target :: Text
target = "https://github.com/owner/target.git"

spec :: Spec
spec = describe "tests/unit/host/test_publication_qualification.py" do
  it "test_setup_orchestration_stops_before_push_and_keeps_cleanup_separate" do
    withSystemTempDirectory "qualification" \tmp -> do
      setFileMode tmp 0o700
      calls <- newIORef []
      let record = recorder calls
      outcome <-
        qualifySetup
          SetupSequence
            { onIdentity = record "identity"
            , onTarget = pure False
            , onPrePush = record "pre_push"
            , pusher = atomicSetupPush (tmp </> "spent")
            , remote = "https://github.com/example/fixture.git"
            , base = a40
            , head = b40
            , runner = \_ -> modifyIORef' calls (<> ["push"]) >> pure 0
            , onReadback = record "readback"
            , onPullRequest = record "pr"
            , onCurrentCas = record "current"
            , onStaleCas = record "stale"
            , onCleanup = pure False
            }
      readIORef calls `shouldReturn` ["identity"]
      outcome.firstCausePhase `shouldBe` Just Target
      outcome.firstCauseCategory `shouldBe` Just ObservationUnconfirmed
      outcome.cleanup.category `shouldBe` Just ObservationUnconfirmed
      outcome.push `shouldBe` Nothing

  it "test_setup_orchestration_reads_back_once_without_retry_and_then_admits_observations" do
    withSystemTempDirectory "qualification" \tmp -> do
      setFileMode tmp 0o700
      calls <- newIORef []
      let record = recorder calls
      outcome <-
        qualifySetup
          SetupSequence
            { onIdentity = pure True
            , onTarget = pure True
            , onPrePush = pure True
            , pusher = atomicSetupPush (tmp </> "spent")
            , remote = "https://github.com/example/fixture.git"
            , base = a40
            , head = b40
            , runner = \_ -> modifyIORef' calls (<> ["push"]) >> pure 1
            , onReadback = record "readback"
            , onPullRequest = record "pr"
            , onCurrentCas = record "current"
            , onStaleCas = record "stale"
            , onCleanup = pure True
            }
      readIORef calls `shouldReturn` ["push", "readback", "pr", "current", "stale"]
      outcome.firstCausePhase `shouldBe` Just Push
      outcome.firstCauseCategory `shouldBe` Just PushUnconfirmed
      fmap (.confirmed) outcome.readback `shouldBe` Just True
      setupAccepted outcome `shouldBe` False

  it "test_original_failure_is_retained_and_zero_publication_suppresses_every_assertion" do
    evidence <- newPublicationQualification
    calls <- newIORef []
    recordOriginal evidence (changeResult False (categoryName RefCas) "" "") 0
    runPublicationAssertions
      evidence
      (recorder calls "schema")
      (recorder calls "tree")
      (throwIO (GitPublishError PatchAdmission "private secondary diagnostic"))
    readIORef calls `shouldReturn` []
    state <- snapshot evidence
    state.originalCategory `shouldBe` Just RefCas
    state.replayCategory `shouldBe` Nothing
    publicationSanitized state
      `shouldEqualPy` PDict
        [ ("accepted", PBool False)
        , ("original_publications", PInt 0)
        , ("agent_result_category", PStr "")
        , ("agent_cleanup_category", PStr "")
        , ("original_category", PStr "ref_cas")
        , ("publication_assertions_allowed", PBool False)
        , ("schema_assertion", PNone)
        , ("tree_assertion", PNone)
        , ("replay_assertion", PNone)
        , ("replay_category", PStr "")
        , ("cleanup_verified", PNone)
        , ("cleanup_category", PStr "")
        ]

  it "test_success_runs_assertions_and_one_replay_without_overwriting_original" do
    evidence <- newPublicationQualification
    calls <- newIORef []
    recordOriginal evidence (changeResult True "" "" "") 1
    runPublicationAssertions evidence (recorder calls "schema") (recorder calls "tree") (recorder calls "replay")
    recordCleanup evidence True
    readIORef calls `shouldReturn` ["schema", "tree", "replay"]
    state <- snapshot evidence
    publicationAccepted state `shouldBe` True
    (state.originalCategory, state.replayCategory) `shouldBe` (Nothing, Nothing)

  describe "test_agent_result_first_cause_suppresses_all_publication_assertions" do
    forM_ [minBound .. maxBound :: AgentResultCategory] \category ->
      it (T.unpack (wire category)) do
        evidence <- newPublicationQualification
        calls <- newIORef []
        recordOriginal evidence (changeResult False "" (wire category) "") 0
        runPublicationAssertions evidence (recorder calls "schema") (recorder calls "tree") (recorder calls "replay")
        readIORef calls `shouldReturn` []
        state <- snapshot evidence
        state.agentResultCategory `shouldBe` Just category
        state.originalCategory `shouldBe` Nothing
        case publicationSanitized state of
          PDict members -> lookup "agent_result_category" members `shouldSatisfy` maybe False (\v -> show v == show (PStr (wire category)))
          _ -> expectationFailure "not a dict"

  it "test_agent_result_first_cause_and_cleanup_uncertainty_remain_separate" do
    evidence <- newPublicationQualification
    recordOriginal evidence (changeResult False "" (wire OutputSchema) (wire Agents.CleanupUnverified)) 0
    recordCleanup evidence False
    state <- snapshot evidence
    state.agentResultCategory `shouldBe` Just OutputSchema
    state.agentCleanupCategory `shouldBe` Just (Agents.CleanupUnverified :: AgentCleanupCategory)
    state.originalCategory `shouldBe` Nothing
    state.cleanupCategory `shouldBe` Just CleanupUnverified

  it "test_replay_and_cleanup_failures_are_separate_and_do_not_replace_original" do
    evidence <- newPublicationQualification
    recordOriginal evidence (changeResult True "" "" "") 1
    runPublicationAssertions evidence (pure True) (pure True) (throwIO (GitPublishError Idempotency "private"))
    recordCleanup evidence False
    state <- snapshot evidence
    state.originalCategory `shouldBe` Nothing
    state.replayCategory `shouldBe` Just (ReplayPublication Idempotency)
    state.cleanupCategory `shouldBe` Just CleanupUnverified
    publicationAccepted state `shouldBe` False

  describe "test_arbitrary_or_private_diagnostics_cannot_enter_retained_evidence" do
    let effects =
          [ changeResult False "owner/private-ref" "" ""
          , changeResult False "https://example.invalid/private" "" ""
          , changeResult False "raw provider diagnostic" "" ""
          , changeResult False "" "owner/private-ref" ""
          , changeResult False "" "raw model diagnostic" ""
          , changeResult False "" "" "raw cleanup prose"
          ]
    forM_ (zip [0 :: Int ..] effects) \(index, effect) ->
      it ("effect" <> show index) do
        evidence <- newPublicationQualification
        recordOriginal evidence effect 0 `shouldThrow` \(QualificationError _ message) -> "closed vocabulary" `T.isInfixOf` message

  it "test_inconsistent_or_repeated_original_and_cleanup_evidence_is_rejected" do
    let raises needle (QualificationError cls message) = cls == "ValueError" && needle `T.isInfixOf` message
    evidence <- newPublicationQualification
    recordOriginal evidence (changeResult False "" "" "") 0 `shouldThrow` raises "lacks a closed category"
    fresh <- newPublicationQualification
    recordOriginal fresh (changeResult True "" "" "") 0 `shouldThrow` raises "inconsistent"

    recordOriginal evidence (changeResult False (categoryName GitOperation) "" "") 0
    recordOriginal evidence (changeResult False (categoryName RefCas) "" "") 0 `shouldThrow` raises "inconsistent"
    recordCleanup evidence True
    recordCleanup evidence False `shouldThrow` raises "inconsistent"

    overlap <- newPublicationQualification
    recordOriginal overlap (changeResult False (categoryName RefCas) (wire Agents.Correlation) "") 0 `shouldThrow` raises "cannot overlap"

  it "test_assertions_are_one_shot_and_non_boolean_evidence_is_rejected" do
    -- The non-boolean callback result and the non-boolean @ok@ cannot be
    -- written (TypeGuaranteeSpec); the one-shot rule still holds after a
    -- first run that raised part-way.
    let raises needle (QualificationError _ message) = needle `T.isInfixOf` message
    evidence <- newPublicationQualification
    recordOriginal evidence (changeResult True "" "" "") 1
    runPublicationAssertions evidence (throwIO (QualificationError "ValueError" "publication assertions must be boolean")) (pure True) (pure True)
      `shouldThrow` raises "must be boolean"
    runPublicationAssertions evidence (pure True) (pure True) (pure True) `shouldThrow` raises "already started"
    publicationAccepted <$> snapshot evidence `shouldReturn` False

  it "test_atomic_setup_push_spends_before_one_exact_command" do
    withSystemTempDirectory "qualification" \tmp -> do
      root <- privateDirectory tmp "private"
      commands <- newIORef []
      outcome <- push (atomicSetupPush (root </> "push-spent")) target a40 b40 (pushCalls commands)
      readIORef commands
        `shouldReturn` [["git", "push", "--atomic", target, a40 <> ":refs/heads/main", b40 <> ":refs/heads/hamsterdan/ds11-live-v4"]]
      (outcome.commandSucceeded, outcome.attempted, outcome.category) `shouldBe` (True, True, Nothing)
      pushSanitized outcome `shouldEqualPy` PDict [("attempted", PBool True), ("command_succeeded", PBool True), ("category", PStr "")]
      marker <- At.statAt Nothing (root </> "push-spent") NoFollowLinks
      (marker.statMode `mod` 0o1000) `shouldBe` 0o600

  it "test_atomic_setup_timeout_is_closed_sanitized_and_durably_spent" do
    withSystemTempDirectory "qualification" \tmp -> do
      root <- privateDirectory tmp "private"
      let coordinate = "owner/private-timeout-canary"
          diagnostic = "credential-and-coordinate-private-diagnostic"
          spent = root </> "push-spent"
          timeout' command =
            throwIO (pythonError "TimeoutExpired" ("Command '" <> T.pack (show command) <> "' timed out after 1 seconds: " <> diagnostic <> coordinate))
      outcome <- push (atomicSetupPush spent) ("https://github.com/" <> coordinate <> ".git") a40 b40 timeout'
      let retained = T.pack (show outcome <> show (pushSanitized outcome))
      outcome.category `shouldBe` Just BoundaryUnavailable
      (outcome.attempted, outcome.commandSucceeded) `shouldBe` (True, False)
      retained `shouldNotSatisfy` T.isInfixOf coordinate
      retained `shouldNotSatisfy` T.isInfixOf diagnostic

      calls <- newIORef []
      replay <- push (atomicSetupPush spent) "https://github.com/owner/another-target.git" (T.replicate 40 "c") (T.replicate 40 "d") (pushCalls calls)
      readIORef calls `shouldReturn` []
      replay.category `shouldBe` Just AlreadySpent
      (replay.attempted, replay.commandSucceeded) `shouldBe` (False, False)

  it "test_atomic_setup_nonzero_or_throwing_runner_never_retains_private_diagnostics" do
    -- The third reference case (a runner returning @True@) cannot be
    -- written: TypeGuaranteeSpec.
    withSystemTempDirectory "qualification" \tmp ->
      forM_
        [ ("nonzero", \_ -> pure 1, PushUnconfirmed)
        , ("throwing", \_ -> throwIO (RuntimeError "private runner diagnostic"), BoundaryUnavailable)
        ]
        \(name, runner, category) -> do
          root <- privateDirectory tmp name
          outcome <- push (atomicSetupPush (root </> "push-spent")) "https://github.com/owner/private-target.git" a40 b40 runner
          outcome.category `shouldBe` Just category
          T.pack (show outcome <> show (pushSanitized outcome)) `shouldNotSatisfy` T.isInfixOf "private"

  describe "test_invalid_atomic_setup_command_is_refused_before_spending" do
    let cases =
          [ ("https://token@github.com/owner/target.git", a40, b40)
          , ("https://github.com/owner/target.git?token=private", a40, b40)
          , ("https://github.com/owner/target.git?", a40, b40)
          , ("https://github.com/owner/target.git#", a40, b40)
          , ("https://github.com:/owner/target.git", a40, b40)
          , ("https://GITHUB.COM/owner/target.git", a40, b40)
          , ("\nhttps://github.com/owner/target.git", a40, b40)
          , ("https://git\thub.com/owner/target.git", a40, b40)
          , ("https://example.invalid/owner/target.git", a40, b40)
          , (target, T.replicate 40 "A", b40)
          , (target, a40, a40)
          ]
    forM_ (zip [0 :: Int ..] cases) \(index, (remote, base, head')) ->
      it ("case" <> show index) do
        withSystemTempDirectory "qualification" \tmp -> do
          root <- privateDirectory tmp "private"
          calls <- newIORef []
          outcome <- push (atomicSetupPush (root </> "push-spent")) remote base head' (pushCalls calls)
          readIORef calls `shouldReturn` []
          doesPathExist (root </> "push-spent") `shouldReturn` False
          outcome.category `shouldBe` Just BoundaryUnavailable

  it "test_atomic_setup_fence_failure_is_closed_without_running" do
    withSystemTempDirectory "qualification" \tmp -> do
      let unsafe = tmp </> "unsafe"
      createDirectory unsafe
      setFileMode unsafe 0o755
      calls <- newIORef []
      outcome <- push (atomicSetupPush (unsafe </> "push-spent")) target a40 b40 (pushCalls calls)
      readIORef calls `shouldReturn` []
      outcome.category `shouldBe` Just FenceUnavailable
      (outcome.attempted, outcome.commandSucceeded) `shouldBe` (False, False)

  it "test_atomic_setup_syncs_file_then_directory_before_running" do
    withSystemTempDirectory "qualification" \tmp -> do
      root <- privateDirectory tmp "private"
      synced <- newIORef []
      let fs = systemFs {fsync = \fd -> do
                            kind <- kindOf fd
                            modifyIORef' synced (<> [kind])
                            systemFs.fsync fd}
          subject = AtomicSetupPush {spentPath = root </> "push-spent", fs}
      outcome <- push subject target a40 b40 \_ -> do
        seen <- readIORef synced
        pure (if seen == ["file", "directory"] then 0 else 1)
      outcome.commandSucceeded `shouldBe` True
      readIORef synced `shouldReturn` ["file", "directory"]

  describe "test_atomic_setup_sync_failure_never_runs" do
    forM_ ["file", "directory"] \failedKind ->
      it (T.unpack failedKind) do
        withSystemTempDirectory "qualification" \tmp -> do
          root <- privateDirectory tmp "private"
          calls <- newIORef []
          let fs = systemFs {fsync = \fd -> do
                                kind <- kindOf fd
                                when (kind == failedKind) $ ioError (userError "private sync diagnostic")
                                systemFs.fsync fd}
          outcome <- push AtomicSetupPush {spentPath = root </> "push-spent", fs} target a40 b40 (pushCalls calls)
          readIORef calls `shouldReturn` []
          outcome.category `shouldBe` Just FenceUnavailable
          outcome.attempted `shouldBe` False

  it "test_atomic_setup_close_failure_is_sanitized_without_running" do
    withSystemTempDirectory "qualification" \tmp -> do
      root <- privateDirectory tmp "private"
      calls <- newIORef []
      let fs = systemFs {close = \fd -> do
                            directory <- isDirectory <$> At.fdStat fd
                            systemFs.close fd
                            when directory $ ioError (userError "private close diagnostic")}
      outcome <- push AtomicSetupPush {spentPath = root </> "push-spent", fs} "https://github.com/owner/private-target.git" a40 b40 (pushCalls calls)
      readIORef calls `shouldReturn` []
      outcome.category `shouldBe` Just FenceUnavailable
      outcome.attempted `shouldBe` False
      T.pack (show outcome <> show (pushSanitized outcome)) `shouldNotSatisfy` T.isInfixOf "private"

  it "test_atomic_setup_forces_exact_marker_mode_under_restrictive_umask" do
    withSystemTempDirectory "qualification" \tmp -> do
      root <- privateDirectory tmp "private"
      previous <- setFileCreationMask 0o777
      outcome <- push (atomicSetupPush (root </> "push-spent")) target a40 b40 (\_ -> pure 0)
      _ <- setFileCreationMask previous
      outcome.commandSucceeded `shouldBe` True
      permissionBits <$> At.statAt Nothing (root </> "push-spent") NoFollowLinks `shouldReturn` 0o600

  it "test_atomic_setup_parent_substitution_never_runs" do
    withSystemTempDirectory "qualification" \tmp -> do
      root <- privateDirectory tmp "private"
      let displaced = tmp </> "displaced"
          spent = root </> "push-spent"
      substituted <- newIORef False
      calls <- newIORef []
      let fs = systemFs {open = \dir path request -> do
                           done <- readIORef substituted
                           when (not done && (path == spent || path == "push-spent")) do
                             renameDirectory root displaced
                             PosixDir.createDirectory root 0o700
                             writeIORef substituted True
                           systemFs.open dir path request}
      outcome <- push AtomicSetupPush {spentPath = spent, fs} target a40 b40 (pushCalls calls)
      readIORef substituted `shouldReturn` True
      readIORef calls `shouldReturn` []
      outcome.category `shouldBe` Just FenceUnavailable
      outcome.attempted `shouldBe` False

  it "test_atomic_setup_short_marker_write_remains_closed" do
    withSystemTempDirectory "qualification" \tmp -> do
      root <- privateDirectory tmp "private"
      calls <- newIORef []
      let fs = systemFs {write = \_ value -> pure (BS.length value - 1)}
      outcome <- push AtomicSetupPush {spentPath = root </> "push-spent", fs} target a40 b40 (pushCalls calls)
      readIORef calls `shouldReturn` []
      outcome.category `shouldBe` Just FenceUnavailable
      outcome.attempted `shouldBe` False
      replay <- push (atomicSetupPush (root </> "push-spent")) target a40 b40 (pushCalls calls)
      readIORef calls `shouldReturn` []
      replay.category `shouldBe` Just FenceUnavailable

  it "test_atomic_setup_existing_symlink_marker_never_runs" do
    withSystemTempDirectory "qualification" \tmp -> do
      root <- privateDirectory tmp "private"
      let outside = tmp </> "outside"
      writeFile outside "atomic-two-ref-v1\n"
      createSymbolicLink outside (root </> "push-spent")
      calls <- newIORef []
      outcome <- push (atomicSetupPush (root </> "push-spent")) target a40 b40 (pushCalls calls)
      readIORef calls `shouldReturn` []
      outcome.category `shouldBe` Just FenceUnavailable
      outcome.attempted `shouldBe` False

  it "test_setup_observation_timeout_never_renders_private_command_or_diagnostics" do
    let coordinate = "owner/private-observation-canary"
        diagnostic = "private-provider-diagnostic"
    outcome <-
      observeSetupBoundary
        (throwIO (pythonError "TimeoutExpired" ("Command 'gh api repos/" <> coordinate <> "/branches' timed out after 30 seconds: " <> diagnostic)))
    let retained = T.pack (show outcome <> show (observationSanitized outcome))
    outcome.confirmed `shouldBe` False
    outcome.category `shouldBe` Just BoundaryUnavailable
    retained `shouldNotSatisfy` T.isInfixOf coordinate
    retained `shouldNotSatisfy` T.isInfixOf diagnostic

  describe "test_setup_observation_requires_strict_confirmation_without_retaining_diagnostics" do
    -- The second reference case (an observer returning @"yes"@) cannot be
    -- written: TypeGuaranteeSpec.
    forM_
      [ ("false", pure False, ObservationUnconfirmed)
      , ("throwing", throwIO (RuntimeError "private observation diagnostic"), BoundaryUnavailable)
      ]
      \(name, observer, category) ->
        it name do
          outcome <- observeSetupBoundary observer
          (outcome.confirmed, outcome.category) `shouldBe` (False, Just category)
          T.pack (show outcome <> show (observationSanitized outcome)) `shouldNotSatisfy` T.isInfixOf "private"
  where
    kindOf fd = do
      metadata <- At.fdStat fd
      pure (if isDirectory metadata then "directory" else "file" :: Text)
