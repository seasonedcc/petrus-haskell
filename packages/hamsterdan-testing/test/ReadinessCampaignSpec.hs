-- | @tests/integration/testing/test_readiness_campaign.py@: generated
-- readiness campaigns over the deterministic World.
--
-- Upstream draws its examples with Hypothesis (derandomized, a handful of
-- examples per test plus explicit @\@example@ cases). Here every campaign is
-- a deterministic enumeration that includes those explicit cases and covers
-- each generated dimension exhaustively (or, for the state machine, every
-- seed-drawn branch combination with every action sequence up to a bound).
-- Each example is a fresh World in a fresh directory; a BudgetExhausted or
-- InvariantViolation retains the exact failed artifact before the failure
-- propagates, as upstream's @_retain_failure_artifact@ does.
module ReadinessCampaignSpec (spec) where

import Control.Exception (Exception (..), SomeException, catch, finally, throwIO, try)
import Control.Monad (foldM, forM_, unless, when)
import Data.ByteString qualified as BS
import Data.IORef
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Testing.World hiding (PullRequest (..))
import Hamsterdan.Testing.World.Contract (defaultBudget, headSha, reminderDelay)
import Hamsterdan.Testing.World.Coverage (CoverageRun (..), blocked, collectReadinessCoverage, covered)
import Hamsterdan.Testing.World.Scenarios (cleanGreen, drain, green, setPr)
import Petrus.Json (Json (..))
import Petrus.Testing.Dst
  ( AnyArtifact (..)
  , ApplyResult (..)
  , ChoiceProvenance (..)
  , Disposition (..)
  , DstFailure (..)
  , FailureDetail (..)
  , IndexAuthority (..)
  , Observation (..)
  , ReplayResult (..)
  , ScenarioArtifactV4 (..)
  , ScenarioExpected (..)
  , artifactVersion
  , encodeArtifact
  , loadArtifact
  )
import Petrus.Testing.Dst.World qualified as World
import Petrus.TestSupport.Repo (repoRoot)
import ReadinessWorldSpec (items, replayed, withRoot)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import Test.Hspec hiding (after, before, example, pending)

authorityHead :: Text
authorityHead = T.replicate 40 "c"

spec :: Spec
spec = describe "tests/integration/testing/test_readiness_campaign.py" $ do
  it "test_timeline_steps_one_disclosed_host_action" $ withRoot $ \root -> do
    rw <- newReadinessWorld root defaultBudget Nothing
    t <- timeline rw
    delivery <- cleanGreen t False
    (`finally` closeWorld rw) $ do
      pending t `shouldReturn` True
      result <- step t
      result.value `shouldBe` Object [("custody", Object [("delivery", String delivery), ("disposition", String "completed")])]

  it "test_generated_authority_lifecycle_schedules_replay_exactly" $ do
    let paths = ["active", "draft_resume", "closed"]
        -- Each action alone before the lifecycle settles, each alone after
        -- it, and a restart on both sides.
        schedules =
          [([], [])]
            <> [([a], []) | a <- generatedActions]
            <> [([], [a]) | a <- generatedActions]
            <> [(["restart"], ["restart"])]
        examples = [(path, before, after) | path <- paths, (before, after) <- schedules]
    forM_ (zip [0 ..] examples) $ \(seed, (path, before, after)) ->
      labelled ["authority", path, actionsLabel before, actionsLabel after] (authorityExample seed path before after)

  it "test_generated_reminder_timer_recovery_schedules_replay_exactly" $ do
    let examples =
          [ (path, cut, lost, redeliver)
          | path <- ["stable", "new_head", "draft_resume", "closed"]
          , cut <- ["before_due", "after_due", "after_acceptance"]
          , lost <- [False, True]
          , redeliver <- [False, True]
          , path /= "closed" || (cut /= "after_acceptance" && not lost)
          ]
    length examples `shouldBe` 40
    forM_ (zip [0 ..] examples) $ \(seed, (path, cut, lost, redeliver)) ->
      labelled ["timer", path, cut, tshow lost, tshow redeliver] (timerExample seed path cut lost redeliver)

  it "test_generated_v5_git_publication_recovery_schedules_replay_exactly" $ do
    let examples =
          [ (lost, cut, redeliver)
          | lost <- [False, True]
          , cut <- ["none", "before_delivery", "after_acceptance", "after_head"]
          , redeliver <- [False, True]
          ]
    forM_ (zip [0 ..] examples) $ \(seed, (lost, cut, redeliver)) ->
      labelled ["git", tshow lost, cut, tshow redeliver] $
        if unrecoveredAfterAcceptance lost cut
          then gitRefusal seed lost cut redeliver
          else retainedPath "readiness-v5-git-publication-v4.json" >>= \retained -> gitExample retained seed lost cut redeliver

  it "test_generated_delivery_recovery_schedules_replay_exactly" $ do
    seeds <- branchSeeds
    Map.size seeds `shouldBe` 8
    let schedules = [[]] <> [[a] | a <- [Act, Restart]] <> [[a, b] | a <- [Act, Restart], b <- [Act, Restart]]
    forM_ (Map.toList seeds) $ \(branches, seed) ->
      forM_ schedules $ \actions ->
        labelled ["delivery", tshow seed, tshow branches, tshow actions] $ do
          retained <- retainedPath "readiness-counterexample-v4.json"
          deliveryMachine False retained seed actions

  it "test_shrunk_checker_failure_retains_an_exact_replayable_artifact" $ withRoot $ \tmp -> do
    let retained = tmp </> "retained-counterexample.json"
    deliveryMachine True retained 0 [Act, Act] `shouldThrow` independentModel
    loaded <- loadArtifact retained
    a <- either (fail . show) pure loaded
    artifactVersion a `shouldBe` 4
    (expectedOf a).disposition `shouldBe` DInvariantFailure
    result <- replayed a (tmp </> "retained-replay")
    result.disposition `shouldBe` DInvariantFailure
    case result.failure of
      Just (FInvariant _) -> pure ()
      other -> expectationFailure ("expected an invariant failure, got " <> show other)

-- ---------------------------------------------------------------------------
-- Generated examples

generatedActions :: [Text]
generatedActions = ["step", "restart", "redeliver-old", "redeliver-current"]

-- | @_run_generated_actions@.
runActions :: ReadinessWorld -> ReadinessTimeline -> Text -> Text -> [Text] -> IO ReadinessTimeline
runActions rw = \t old current -> foldM (act old current) t
 where
  act old current t = \case
    "step" -> do
      more <- pending t
      when more (() <$ step t)
      pure t
    "restart" -> crash t "generated_authority_lifecycle_cut" >> restart rw
    "redeliver-old" -> redeliverWhenIdle t old
    "redeliver-current" -> redeliverWhenIdle t current
    other -> fail ("unknown generated readiness action " <> show other)
  redeliverWhenIdle t delivery = do
    more <- pending t
    unless more (() <$ deliverWebhook t delivery)
    pure t

authorityExample :: Integer -> Text -> [Text] -> [Text] -> IO ()
authorityExample seed path before after =
  generated ("readiness-authority-lifecycle-" <> path <> "-v2") "readiness-authority-lifecycle-v4.json" seed $ \run -> do
    let rw = run.world
    t0 <- timeline rw
    old <- cleanGreen t0 False
    drain t0
    initial <- state t0
    initial .: "expected" .: "ready" `shouldBe` Bool True

    setPr t0 authorityHead (if path == "draft_resume" then "draft" else path)
    green t0 authorityHead
    current0 <- emitWebhook t0 "pull_request" (if path == "closed" then "closed" else "synchronize")
    _ <- deliverWebhook t0 current0
    t1 <- runActions rw t0 old current0 before
    drain t1

    current <- state t1
    let expected = current .: "expected"
        published = current .: "actual" .: "readiness_published"
    currentDelivery <- case path of
      "active" -> do
        expected .: "disposition" `shouldBe` String "ready"
        published `shouldBe` Bool True
        pure current0
      "closed" -> do
        expected .: "disposition" `shouldBe` String "terminal"
        published `shouldBe` Bool False
        pure current0
      _ -> do
        expected .: "disposition" `shouldBe` String "human_wait"
        expected .: "blockers" `shouldBe` Array [String "pull_request_draft"]
        published `shouldBe` Bool False
        setPr t1 authorityHead "active"
        resumed <- emitWebhook t1 "pull_request" "ready_for_review"
        _ <- deliverWebhook t1 resumed
        pure resumed

    t2 <- runActions rw t1 old currentDelivery after
    final <- (.value) <$> converge t2
    let finalExpected = final .: "expected"
        provider = final .: "provider"
        effects = items (provider .: "effects")
        generations = if path == "draft_resume" then 3 else 2
    finalExpected .: "violations" `shouldBe` Array []
    finalExpected .: "generation" `shouldBe` Int generations
    forM_ effects $ \effect -> effect .: "head" `shouldBe` effect .: "provider_authority_at_acceptance" .: "head"
    length (nub [effect .: "operation" | effect <- effects]) `shouldBe` length effects
    length (items (final .: "facts" .: "admitted_observations")) `shouldBe` fromInteger generations
    if path == "closed"
      then do
        finalExpected .: "disposition" `shouldBe` String "terminal"
        final .: "actual" .: "readiness_published" `shouldBe` Bool False
        final .: "host" .: "snapshot" .: "phase" `shouldBe` String "terminal"
        provider .: "accepted_by_kind" .: "readiness" `shouldBe` Int 1
      else do
        finalExpected .: "disposition" `shouldBe` String "ready"
        final .: "actual" .: "readiness_published" `shouldBe` Bool True
        final .: "host" .: "snapshot" .: "head" `shouldBe` String authorityHead
        provider .: "accepted_by_kind" .: "readiness" `shouldBe` Int 2

    a <- artifact rw run.scenarioId
    (originOf a).seed `shouldBe` seed
    dimensions <- replayConverged run a
    Set.fromList ["authority_movement", "fair_convergence", "checker_activation", "exact_replay"] `shouldSatisfy` (`Set.isSubsetOf` dimensions)
    when (path /= "active") $ dimensions `shouldSatisfy` Set.member "lifecycle_movement"
    when ("restart" `elem` before || "restart" `elem` after) $ dimensions `shouldSatisfy` Set.member "crash_reconstruction"

timerExample :: Integer -> Text -> Text -> Bool -> Bool -> IO ()
timerExample seed path cut lost redeliver =
  generated ("readiness-reminder-timer-" <> path <> "-v1") "readiness-reminder-timer-v4.json" seed $ \run -> do
    let rw = run.world
    t0 <- timeline rw
    initialDelivery <- cleanGreen t0 False
    drain t0
    incarnation <- case path of
      "new_head" -> do
        setPr t0 authorityHead "active"
        green t0 authorityHead
        movedDelivery <- emitWebhook t0 "pull_request" "synchronize"
        _ <- deliverWebhook t0 movedDelivery
        drain t0
        pure (2 :: Int)
      "draft_resume" -> do
        setPr t0 headSha "draft"
        draft <- emitWebhook t0 "pull_request" "converted_to_draft"
        _ <- deliverWebhook t0 draft
        drain t0
        setPr t0 headSha "active"
        resumed <- emitWebhook t0 "pull_request" "ready_for_review"
        _ <- deliverWebhook t0 resumed
        drain t0
        pure 2
      "closed" -> do
        setPr t0 headSha "closed"
        closedDelivery <- emitWebhook t0 "pull_request" "closed"
        _ <- deliverWebhook t0 closedDelivery
        drain t0
        pure 1
      _ -> pure 1

    when redeliver (() <$ deliverWebhook t0 initialDelivery)
    when lost (loseEffectResponse t0 "reminder")
    t1 <-
      if cut == "before_due"
        then do
          crash t0 "generated_timer_before_due"
          t <- restart rw
          drain t
          pure t
        else pure t0

    _ <- advanceTime t1 reminderDelay
    t2 <-
      if cut == "after_due"
        then crash t1 "generated_timer_after_due" >> restart rw
        else pure t1

    t3 <-
      if path /= "closed"
        then do
          let reminders s = intAt (s .: "provider" .: "accepted_by_kind" .: "reminder")
          accepted <- runUntil t2 "generated reminder accepted" (\s -> reminders s == 1)
          reminders accepted.value `shouldBe` 1
          if cut == "after_acceptance"
            then crash t2 "generated_timer_after_acceptance" >> restart rw
            else pure t2
        else pure t2

    final <- (.value) <$> converge t3
    let provider = final .: "provider"
        reminderEffects = [effect | effect <- items (provider .: "effects"), effect .: "kind" == String "reminder"]
        timers = items (final .: "facts" .: "timers")
        statuses = [timer .: "status" | timer <- timers]
    final .: "expected" .: "violations" `shouldBe` Array []
    length reminderEffects `shouldBe` (if path == "closed" then 0 else 1)
    length (nub [effect .: "operation" | effect <- reminderEffects]) `shouldBe` length reminderEffects
    forM_ (items (final .: "timer_custody" .: "operations")) $ \operation ->
      operation .: "acknowledged" `shouldBe` Bool True
    if path == "closed"
      then do
        statuses `shouldBe` [String "canceled"]
        final .: "actual" .: "readiness_published" `shouldBe` Bool False
      else do
        let expectedTimer = "timer:github:44:31:pr:7:i" <> tshow incarnation <> ":s0"
        map (.: "operation") reminderEffects `shouldBe` [String ("reminder:" <> expectedTimer)]
        length (filter (== String "acknowledged") statuses) `shouldBe` 1
        length (filter (== String "scheduled") statuses) `shouldBe` 1
        final .: "actual" .: "readiness_published" `shouldBe` Bool True
        when lost $ intAt (provider .: "lookup_recoveries") `shouldSatisfy` (>= 1)

    a <- artifact rw run.scenarioId
    dimensions <- replayConverged run a
    Set.fromList ["crash_reconstruction", "fair_convergence", "checker_activation", "exact_replay"] `shouldSatisfy` (`Set.isSubsetOf` dimensions)
    when (path /= "closed") $ dimensions `shouldSatisfy` Set.member "timer_lifecycle"
    when (path `elem` ["new_head", "draft_resume", "closed"]) $ dimensions `shouldSatisfy` Set.member "authority_movement"
    when (path `elem` ["draft_resume", "closed"]) $ dimensions `shouldSatisfy` Set.member "lifecycle_movement"
    when lost $ dimensions `shouldSatisfy` Set.member "provider_response_loss"
    when redeliver $ dimensions `shouldSatisfy` Set.member "duplicate_delivery"

-- | The schedules upstream's own World refuses: a crash right after the Git
-- ref is accepted, with no response fault. After the restart the host never
-- discloses progress for the moved head, and the independent model fails the
-- next boundary (@ready_parity@ and @progress_disclosed@ false). Upstream's
-- five Hypothesis examples never draw this schedule; the reference World
-- fails it identically (same failure, same artifact bytes, see the
-- @git-after_acceptance-unrecovered@ World interop scenario), so the Haskell
-- campaign asserts the reference's verdict: a retained, exactly replayable
-- invariant failure.
unrecoveredAfterAcceptance :: Bool -> Text -> Bool
unrecoveredAfterAcceptance lost cut = not lost && cut == "after_acceptance"

gitRefusal :: Integer -> Bool -> Text -> Bool -> IO ()
gitRefusal seed lost cut redeliver = withRoot $ \tmp -> do
  let retained = tmp </> "retained-git-counterexample.json"
  gitExample retained seed lost cut redeliver `shouldThrow` independentModel
  loaded <- loadArtifact retained
  a <- either (fail . show) pure loaded
  (expectedOf a).disposition `shouldBe` DInvariantFailure
  result <- replayed a (tmp </> "retained-replay")
  result.disposition `shouldBe` DInvariantFailure

gitExample :: FilePath -> Integer -> Bool -> Text -> Bool -> IO ()
gitExample retained seed lost cut redeliver =
  generatedAt ("readiness-v5-git-publication-" <> cut <> "-v1") retained seed $ \run -> do
    let rw = run.world
        comment = 501 :: Integer
        publication = "push:comment:" <> tshow comment <> ":" <> headSha <> ":i1"
    t0 <- timeline rw
    _ <- cleanGreen t0 False
    drain t0

    _ <- setHumanComment t0 comment "change" "author"
    delivery <- emitWebhook t0 "issue_comment" "created"
    _ <- setAgentTerminal t0 ("conversation:owner/repo:pr:7:delivery:" <> delivery) "conversation_change" "changed" 1
    _ <- setAgentTerminal t0 ("mutation:owner/repo:pr:7:" <> publication) "coding" "changed" 1
    when lost (faultGitPublication t0 publication "ref_cas" 1)
    t1 <-
      if cut == "before_delivery"
        then do
          crash t0 "generated_git_before_delivery"
          t <- restart rw
          drain t
          pure t
        else pure t0

    _ <- deliverWebhook t1 delivery
    let publications s = items (s .: "provider" .: "git_publications")
    accepted <- runUntil t1 "generated Git ref accepted" (\s -> length (publications s) == 1)
    newHead <- case publications accepted.value of
      published : _ | String h <- published .: "result_head" -> pure h
      other -> fail ("no accepted Git publication: " <> show other)
    t2 <-
      if cut == "after_acceptance"
        then crash t1 "generated_git_after_acceptance" >> restart rw
        else pure t1
    drain t2

    green t2 newHead
    headDelivery <- emitWebhook t2 "pull_request" "synchronize"
    _ <- deliverWebhook t2 headDelivery
    drain t2
    when redeliver (() <$ deliverWebhook t2 delivery)
    t3 <-
      if cut == "after_head"
        then do
          crash t2 "generated_git_after_head"
          t <- restart rw
          drain t
          pure t
        else pure t2

    when lost $ do
      _ <- setHumanComment t3 502 ("recover:" <> publication) "author"
      recovery <- emitWebhook t3 "issue_comment" "created"
      _ <- setAgentTerminal t3 ("conversation:owner/repo:pr:7:delivery:" <> recovery) "conversation_recover" "clear" 1
      () <$ deliverWebhook t3 recovery

    final <- (.value) <$> converge t3
    let provider = final .: "provider"
        published = items (provider .: "git_publications")
        custody = final .: "git_custody"
    final .: "expected" .: "violations" `shouldBe` Array []
    final .: "expected" .: "ready" `shouldBe` Bool True
    final .: "actual" .: "readiness_published" `shouldBe` Bool True
    length published `shouldBe` 1
    forM_ published $ \p -> do
      p .: "operation" `shouldBe` String publication
      p .: "response_lost" `shouldBe` Bool lost
      p .: "recovered" `shouldBe` Bool lost
    map (.: "operation") (items (custody .: "requests")) `shouldBe` replicate (if lost then 2 else 1) (String publication)
    map (.: "variant") (items (custody .: "terminals")) `shouldBe` map String (if lost then ["FaultM", "Pushed"] else ["Pushed"])
    length [call | call <- items (provider .: "agent_call_log"), call .: "kind" == String "coding"] `shouldBe` 1

    a <- artifact rw run.scenarioId
    dimensions <- replayConverged run a
    Set.fromList ["conversation_effect", "coding_effect", "git_mutation", "fair_convergence", "checker_activation", "exact_replay"]
      `shouldSatisfy` (`Set.isSubsetOf` dimensions)
    when lost $ Set.fromList ["provider_response_loss", "git_ambiguity_recovery"] `shouldSatisfy` (`Set.isSubsetOf` dimensions)
    when (cut /= "none") $ dimensions `shouldSatisfy` Set.member "crash_reconstruction"
    when redeliver $ dimensions `shouldSatisfy` Set.member "duplicate_delivery"

-- ---------------------------------------------------------------------------
-- The delivery recovery state machine (@_DeliveryRecoveryMachine@)

-- | A generated rule: 'Act' runs @execute_one_disclosed_action@ while work
-- is pending and @redeliver_after_quiescence@ otherwise (their
-- preconditions partition the states); 'Restart' is @restart_generation@.
data Action = Act | Restart
  deriving stock (Eq, Show)

-- | The three seed-drawn branches: response lost, crash before the first
-- step, redeliver at finish.
type Branches = (Bool, Bool, Bool)

-- | The first seed drawing each branch combination.
branchSeeds :: IO (Map.Map Branches Integer)
branchSeeds = go 0 Map.empty
 where
  go seed found
    | Map.size found == 8 || seed > 256 = pure found
    | otherwise = do
        branches <- withRoot $ \root -> do
          rw <- newReadinessWorld (root </> "live") defaultBudget (Just seed)
          (`finally` closeWorld rw) $ do
            (lost, crashFirst, redeliver, _) <- drawBranches rw
            pure (lost, crashFirst, redeliver)
        go (seed + 1) (Map.insertWith (\_ old -> old) branches seed found)

drawBranches :: ReadinessWorld -> IO (Bool, Bool, Bool, Text)
drawBranches rw = do
  lost <- (== 1) <$> inWorld rw (World.chooseIndex FaultChoice 2)
  crashFirst <- (== 1) <$> inWorld rw (World.chooseIndex EventOrderChoice 2)
  redeliver <- (== 1) <$> inWorld rw (World.chooseIndex WorkloadChoice 2)
  scenarioId <- inWorld rw (World.chooseIdentifier "scenario")
  pure (lost, crashFirst, redeliver, scenarioId)

-- | One run of the machine: @start(seed)@, the invariant, each rule with
-- the invariant after it, and the teardown's convergence and replay.
deliveryMachine :: Bool -> FilePath -> Integer -> [Action] -> IO ()
deliveryMachine forceFailure retained seed actions =
  generatedAt "readiness-generated-counterexample-v4" retained seed $ \run -> do
    let rw = run.world
    (lost, crashFirst, redeliverAtFinish, scenarioId) <- drawBranches rw
    writeIORef run.scenario scenarioId
    current <- newIORef =<< timeline rw
    let restartGeneration cut = do
          t <- readIORef current
          crash t cut
          writeIORef current =<< restart rw
        invariant = do
          s <- readIORef current >>= state
          intAt (s .: "provider" .: "accepted_by_kind" .: "readiness") `shouldSatisfy` (<= 1)
          length (items (s .: "facts" .: "admitted_observations")) `shouldSatisfy` (<= 1)
          s .: "expected" .: "violations" `shouldBe` Array []
    delivery <-
      if forceFailure
        then do
          t <- readIORef current
          d <- emitWebhook t "issue_comment" "created"
          _ <- deliverWebhook t d
          pure d
        else do
          t <- readIORef current
          d <- cleanGreen t lost
          when crashFirst (restartGeneration "generated_before_first_host_step")
          pure d
    invariant
    forM_ actions $ \action -> do
      t <- readIORef current
      more <- pending t
      case action of
        Act
          | forceFailure -> when more (() <$ step t)
          | more -> () <$ step t
          | otherwise -> () <$ deliverWebhook t delivery
        Restart
          | forceFailure -> pure ()
          | otherwise -> restartGeneration "generated_between_host_steps"
      invariant
    unless forceFailure $ do
      t <- readIORef current
      drain t
      when redeliverAtFinish (() <$ deliverWebhook t delivery)
      final <- (.value) <$> converge t
      let provider = final .: "provider"
      final .: "expected" .: "ready" `shouldBe` Bool True
      final .: "actual" .: "readiness_published" `shouldBe` Bool True
      provider .: "accepted_by_kind" .: "readiness" `shouldBe` Int 1
      final .: "facts" .: "admitted_observations" `shouldBe` Array [String ("github-delivery:" <> delivery)]
      when lost $ intAt (provider .: "lookup_recoveries") `shouldSatisfy` (>= 1)
      a <- artifact rw scenarioId
      let origin = originOf a
      origin.seed `shouldBe` seed
      origin.draws `shouldBe` Map.fromList [("event_order", 1), ("fault", 1), ("identifier:scenario", 1), ("workload", 1)]
      _ <- replayConverged run a
      pure ()

-- ---------------------------------------------------------------------------
-- Shared machinery

data Run = Run
  { root :: FilePath
  , world :: ReadinessWorld
  , scenario :: IORef Text
  , scenarioId :: Text
  , close :: IO ()
  }

-- | A generated example whose failures retain under
-- @dist-newstyle/readiness-artifacts/@ (upstream:
-- @.hypothesis/readiness-artifacts/@).
generated :: Text -> FilePath -> Integer -> (Run -> IO ()) -> IO ()
generated scenarioId failureFile seed body = do
  path <- retainedPath failureFile
  generatedAt scenarioId path seed body

generatedAt :: Text -> FilePath -> Integer -> (Run -> IO ()) -> IO ()
generatedAt scenarioId failurePath seed body = withRoot $ \root -> do
  rw <- newReadinessWorld (root </> "live") defaultBudget (Just seed)
  scenario <- newIORef scenarioId
  closed <- newIORef False
  let close = readIORef closed >>= \done -> unless done (writeIORef closed True >> closeWorld rw)
      run = Run {root, world = rw, scenario, scenarioId, close}
      retainOn :: DstFailure -> IO ()
      retainOn failure = do
        when (retainable failure) $ do
          sid <- readIORef scenario
          retainFailure rw sid failurePath (root </> "failure-replay")
        throwIO failure
  (body run `catch` retainOn) `finally` close

retainable :: DstFailure -> Bool
retainable = \case
  BudgetExhausted _ _ -> True
  InvariantViolation _ -> True
  _ -> False

retainedPath :: FilePath -> IO FilePath
retainedPath name = do
  repo <- repoRoot
  pure (repo </> "dist-newstyle" </> "readiness-artifacts" </> name)

-- | @_retain_failure_artifact@: write the exact failed artifact and check
-- that it replays its failure. A retention problem is reported as a note
-- and never replaces the primary failure.
retainFailure :: ReadinessWorld -> Text -> FilePath -> FilePath -> IO ()
retainFailure rw scenarioId failurePath replayRoot = do
  ending <- inWorld rw World.disposition
  when (ending `elem` [Just DBudgetExhausted, Just DInvariantFailure]) $ do
    outcome <- try $ do
      a <- artifact rw scenarioId
      encoded <- either (fail . T.unpack) pure (encodeArtifact a)
      createDirectoryIfMissing True (takeDirectory failurePath)
      BS.writeFile failurePath (encoded <> "\n")
      result <- replayed a replayRoot
      unless (Just result.disposition == ending && result.failure /= Nothing) $
        fail "retained readiness counterexample did not replay its exact failure"
      pure (expectedOf a).journalDigest
    case outcome of
      Right digest -> hPutStrLn stderr ("retained exact readiness DST counterexample at " <> failurePath <> " (" <> T.unpack digest <> ")")
      Left (problem :: SomeException) ->
        hPutStrLn stderr ("secondary readiness counterexample retention failure: " <> displayException problem)

-- | Close the World, replay the artifact, require a converged exact replay
-- with the artifact's operation count, and return the covered dimensions.
replayConverged :: Run -> AnyArtifact -> IO (Set Text)
replayConverged run a = do
  artifactVersion a `shouldBe` 4
  let operations = case a of
        ArtifactV4 v4 -> length v4.operations
        _ -> 0
  run.close
  result <- replayed a (run.root </> "replay")
  result.disposition `shouldBe` DConverged
  result.failure `shouldBe` Nothing
  result.operations `shouldBe` toInteger operations
  coveredDimensions a result

-- | @_covered_dimensions@.
coveredDimensions :: AnyArtifact -> ReplayResult -> IO (Set Text)
coveredDimensions a result = case collectReadinessCoverage [CoverageRun a (Just result)] of
  Left problem -> fail (show problem)
  Right report -> do
    blocked report
      `shouldBe` Set.fromList ["ci_rerun_repair", "agent_terminal_fault_cuts", "stale_rate_limited_reads", "history_dispatch_fault_cuts"]
    pure (covered report)

state :: ReadinessTimeline -> IO Json
state t = (.value) <$> observe t

expectedOf :: AnyArtifact -> ScenarioExpected
expectedOf = \case
  ArtifactV4 a -> a.expected
  other -> error ("not a version-4 artifact: " <> show other)

originOf :: AnyArtifact -> ChoiceProvenance
originOf = \case
  ArtifactV4 a | Just origin <- a.origin -> origin
  other -> error ("no choice provenance: " <> show other)

-- | @.get(key, 0)@ of an integer member.
intAt :: Json -> Integer
intAt = \case
  Int n -> n
  _ -> 0

independentModel :: DstFailure -> Bool
independentModel = \case
  InvariantViolation message -> "independent-model" `T.isInfixOf` message
  _ -> False

actionsLabel :: [Text] -> Text
actionsLabel = \case
  [] -> "none"
  actions -> T.intercalate "," actions

-- | Run one example, naming it in any failure (upstream's @event(...)@).
labelled :: [Text] -> IO () -> IO ()
labelled parts example =
  example `catch` \(problem :: SomeException) -> do
    hPutStrLn stderr ("falsifying example: " <> T.unpack (T.intercalate " " parts))
    throwIO problem

tshow :: (Show a) => a -> Text
tshow = T.pack . show
