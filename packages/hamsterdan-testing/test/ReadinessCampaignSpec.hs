-- | @tests/integration/testing/test_readiness_campaign.py@: generated
-- readiness campaigns over the deterministic World.
--
-- Upstream draws its examples with Hypothesis (@derandomize=True@, so a
-- fixed seed; a handful of examples per test plus explicit @\@example@
-- cases). Here, by the same method:
--
-- * the authority lifecycle is a Hedgehog property over upstream's
--   strategies, with its @max_examples@ and its explicit examples;
-- * the delivery recovery machine is a Hedgehog state machine
--   ('Gen.sequential' / 'executeSequential') of up to
--   @stateful_step_count@ rules, its seed drawn as @\@initialize@ draws it
--   and its invariant checked after every rule;
-- * the timer and Git campaigns are Hedgehog properties over upstream's
--   strategies with its @max_examples@ and explicit examples, plus an
--   exhaustive enumeration of every generated dimension except the seed.
--
-- Every Hedgehog run uses a fixed seed and shrinks a failure; each example
-- is a fresh World in a fresh directory, and a BudgetExhausted or
-- InvariantViolation retains the exact failed artifact before the failure
-- propagates, as upstream's @_retain_failure_artifact@ does (so the last
-- retained artifact is the shrunk case's). A failing property's report
-- names the Hedgehog seed and shrink path that rerun the shrunk case.
module ReadinessCampaignSpec (spec) where

import Control.Exception (Exception (..), SomeException, catch, finally, throwIO, try)
import Control.Monad (foldM, forM_, unless, when)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Kind (Type)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Hamsterdan.Testing.World hiding (PullRequest (..))
import Hamsterdan.Testing.Readiness (AuthorityClaim (..), CheckStatus)
import Hamsterdan.Testing.World.Contract (defaultBudget, events, headSha, reminderDelay)
import Hamsterdan.Testing.World.Coverage (CoverageRun (..), blocked, collectReadinessCoverage, covered)
import Hamsterdan.Testing.World.Scenarios (cleanGreen, drain, green, setPr)
import Hedgehog (Callback (..), Command (..), FunctorB (..), Gen, LabelName, MonadTest, Property, TraversableB (..), assert, evalIO, forAll, label, property, (===))
import Hedgehog qualified as H
import Hedgehog.Gen qualified as Gen
import Hedgehog.Internal.Config (UseColor (..))
import Hedgehog.Internal.Property (Property (..))
import Hedgehog.Internal.Report (Report (..), Result (..), renderResult)
import Hedgehog.Internal.Runner (checkReport)
import Hedgehog.Internal.Seed qualified as Seed
import Hedgehog.Range qualified as Range
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
import System.Directory (canonicalizePath, createDirectoryIfMissing, getTemporaryDirectory, removePathForcibly)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (createTempDirectory)
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

  describe "test_generated_authority_lifecycle_schedules_replay_exactly" $ do
    it "the explicit examples (@example)" $
      forM_ ["active", "draft_resume", "closed"] $ \path ->
        labelled ["authority", "0", path, "none", "none"] (authorityExample 0 path [] [])
    it "max_examples=6 generated examples (Hedgehog, fixed seed)" $
      hedgehog 6 . H.withTests 6 . property $ do
        seed <- forAll worldSeed
        path <- forAll (Gen.element ["active", "draft_resume", "closed"])
        before <- forAll (Gen.list (Range.constant 0 1) (Gen.element generatedActions))
        after <- forAll (Gen.list (Range.constant 0 1) (Gen.element generatedActions))
        label (event "authority_path" path)
        label (event "authority_before" (actionsLabel before))
        label (event "authority_after" (actionsLabel after))
        evalIO (authorityExample seed path before after)

  describe "test_generated_reminder_timer_recovery_schedules_replay_exactly" $ do
    it "the explicit examples (@example)" $
      forM_
        [ (0, "stable", "before_due", False, False)
        , (1, "new_head", "after_due", False, True)
        , (2, "draft_resume", "after_acceptance", True, True)
        , (3, "closed", "after_due", False, True)
        ]
        timer
    it "max_examples=5 generated examples (Hedgehog, fixed seed)" $
      hedgehog 5 . H.withTests 5 . property $ do
        seed <- forAll worldSeed
        path <- forAll (Gen.element ["stable", "new_head", "draft_resume", "closed"])
        cut <- forAll (Gen.element ["before_due", "after_due", "after_acceptance"])
        lost <- forAll Gen.bool
        redeliver <- forAll Gen.bool
        unless (path /= "closed" || (cut /= "after_acceptance" && not lost)) H.discard
        label (event "timer_path" path)
        label (event "timer_crash_cut" cut)
        label (event "timer_response_lost" (tshow lost))
        label (event "timer_redeliver" (tshow redeliver))
        evalIO (timer (seed, path, cut, lost, redeliver))
    it "every path, cut, loss and redelivery (enumeration)" $ do
      let examples =
            [ (path, cut, lost, redeliver)
            | path <- ["stable", "new_head", "draft_resume", "closed"]
            , cut <- ["before_due", "after_due", "after_acceptance"]
            , lost <- [False, True]
            , redeliver <- [False, True]
            , path /= "closed" || (cut /= "after_acceptance" && not lost)
            ]
      length examples `shouldBe` 40
      forM_ (zip [0 ..] examples) $ \(seed, (path, cut, lost, redeliver)) -> timer (seed, path, cut, lost, redeliver)

  describe "test_generated_v5_git_publication_recovery_schedules_replay_exactly" $ do
    it "the explicit examples (@example)" $
      forM_
        [ (0, False, "before_delivery", False)
        , (1, True, "after_acceptance", True)
        , (2, True, "after_head", False)
        , (3, False, "none", True)
        ]
        git
    it "max_examples=5 generated examples (Hedgehog, fixed seed)" $
      hedgehog 5 . H.withTests 5 . property $ do
        seed <- forAll worldSeed
        lost <- forAll Gen.bool
        cut <- forAll (Gen.element ["none", "before_delivery", "after_acceptance", "after_head"])
        redeliver <- forAll Gen.bool
        label (event "git_response_lost" (tshow lost))
        label (event "git_crash_cut" cut)
        label (event "git_redeliver" (tshow redeliver))
        evalIO (git (seed, lost, cut, redeliver))
    it "every loss, cut and redelivery (enumeration)" $ do
      let examples =
            [ (lost, cut, redeliver)
            | lost <- [False, True]
            , cut <- ["none", "before_delivery", "after_acceptance", "after_head"]
            , redeliver <- [False, True]
            ]
      forM_ (zip [0 ..] examples) $ \(seed, (lost, cut, redeliver)) -> git (seed, lost, cut, redeliver)

  describe "test_generated_delivery_recovery_schedules_replay_exactly" $ do
    it "max_examples=12 machines of up to stateful_step_count=5 rules (Hedgehog state machine, fixed seed)" $ do
      retained <- retainedPath "readiness-counterexample-v4.json"
      withSlot $ \slot -> hedgehog 12 (deliveryProperty slot False retained 12 5)

  it "every rendered readiness command parses back to itself (Hedgehog, fixed seed)" $
    hedgehog 7 . H.withTests 300 . property $ do
      typed <- forAll genCommand
      parseCommand (renderCommand typed) === Right typed

  it "test_shrunk_checker_failure_retains_an_exact_replayable_artifact" $ withRoot $ \tmp -> do
    let retained = tmp </> "retained-counterexample.json"
    report <- withSlot $ \slot -> do
      report <- checkFixed 2 (deliveryProperty slot True retained 2 2)
      failures <- readIORef slot.failures
      case failures of
        primary : _ -> primary `shouldSatisfy` independentModel
        [] -> expectationFailure "the forced machine raised no DST failure"
      pure report
    case report.reportStatus of
      Failed _ -> pure ()
      other -> expectationFailure ("the forced machine must fail, got " <> show other)
    loaded <- loadArtifact retained
    a <- either (fail . show) pure loaded
    artifactVersion a `shouldBe` 4
    (expectedOf a).disposition `shouldBe` DInvariantFailure
    result <- replayed a (tmp </> "retained-replay")
    result.disposition `shouldBe` DInvariantFailure
    case result.failure of
      Just (FInvariant _) -> pure ()
      other -> expectationFailure ("expected an invariant failure, got " <> show other)
 where
  timer (seed, path, cut, lost, redeliver) =
    labelled ["timer", tshow seed, path, cut, tshow lost, tshow redeliver] (timerExample seed path cut lost redeliver)
  git (seed, lost, cut, redeliver) =
    labelled ["git", tshow seed, tshow lost, cut, tshow redeliver] $
      if unrecoveredAfterAcceptance lost cut
        then gitRefusal seed lost cut redeliver
        else retainedPath "readiness-v5-git-publication-v4.json" >>= \retained -> gitExample retained seed lost cut redeliver

-- ---------------------------------------------------------------------------
-- Hedgehog

-- | @st.integers(min_value=0, max_value=2**53 - 1)@.
worldSeed :: Gen Integer
worldSeed = Gen.integral (Range.constant 0 (2 ^ (53 :: Int) - 1))

-- | Check a property from a fixed seed (upstream's @derandomize=True@).
checkFixed :: Word64 -> Property -> IO (Report Result)
checkFixed seed (Property config test) = checkReport config 0 (Seed.from seed) test (\_ -> pure ())

-- | Check a property from a fixed seed and fail with Hedgehog's report of the
-- shrunk case, which names the seed and shrink path that rerun it.
hedgehog :: Word64 -> Property -> Expectation
hedgehog seed prop = do
  report <- checkFixed seed prop
  case report.reportStatus of
    OK -> pure ()
    _ -> renderResult DisableColor Nothing report >>= expectationFailure

-- | Upstream's @event(f"{name}={value}")@.
event :: Text -> Text -> LabelName
event name value = fromString (T.unpack (name <> "=" <> value))

-- | A readiness command 'parseCommand' accepts.
genCommand :: Gen ReadinessCommand
genCommand =
  Gen.choice
    [ SetPullRequest <$> genClaim
    , SetCi <$> genSha <*> (nub <$> Gen.list (Range.linear 0 6) genName) <*> Gen.list (Range.linear 0 6) genCheck
    , SetReview <$> genSha <*> Gen.enumBounded <*> Gen.list (Range.linear 0 4) (String <$> genName)
    , HumanReview <$> genName <*> genSha <*> genPositive <*> Gen.enumBounded
    , ResolveThread <$> genName <*> genName <*> Gen.bool
    , HumanComment <$> genPositive <*> genName <*> Gen.choice [pure "change", ("recover:" <>) <$> genName]
    , AgentTerminal <$> genName <*> genPositive <*> Gen.enumBounded <*> Gen.enumBounded
    , do
        eventName <- Gen.element (Set.toList events)
        action <- genName
        delivery <- genDelivery
        pure (EmitWebhook delivery eventName (eventName <> ":" <> action))
    , DeliverWebhook <$> genDelivery
    , RevealEffect <$> genName
    , AdvanceTime <$> Gen.integral (Range.linear 1 2000000)
    , Gen.element [HostCustodyOne, HostActivityOne, HostDriveOne, HostReconcileOne]
    ]
 where
  genPositive = Gen.integral (Range.linear 1 1000000)
  genHex n = Gen.text (Range.singleton n) (Gen.element ("0123456789abcdef" :: String))
  genSha = genHex 40
  genName = T.cons <$> Gen.alpha <*> Gen.text (Range.linear 0 12) (Gen.element ("abzXYZ059_.:-" :: String))
  genDelivery = deliveryUuid <$> Gen.integral (Range.linear 1 100000)
  genClaim =
    AuthorityClaim
      <$> genPositive
      <*> genPositive
      <*> genPositive
      <*> genSha
      <*> genSha
      <*> genHex 64
      <*> Gen.enumBounded
      <*> Gen.bool
      <*> Gen.bool
      <*> Gen.bool
  genCheck = do
    name <- genName
    run <- genPositive
    attempt <- genPositive
    status <- Gen.enumBounded @_ @CheckStatus
    pure CiCheck {name, run, attempt, status}

-- ---------------------------------------------------------------------------
-- Generated examples

-- | One of @_run_generated_actions@'s actions.
data GeneratedAction = ActStep | ActRestart | ActRedeliverOld | ActRedeliverCurrent
  deriving stock (Eq, Show, Bounded, Enum)

-- | Upstream's spelling, which the labels carry.
actionName :: GeneratedAction -> Text
actionName = \case
  ActStep -> "step"
  ActRestart -> "restart"
  ActRedeliverOld -> "redeliver-old"
  ActRedeliverCurrent -> "redeliver-current"

-- | Upstream's @st.sampled_from@ list, in its order.
generatedActions :: [GeneratedAction]
generatedActions = [minBound .. maxBound]

-- | @_run_generated_actions@.
runActions :: ReadinessWorld -> ReadinessTimeline -> Text -> Text -> [GeneratedAction] -> IO ReadinessTimeline
runActions rw = \t old current -> foldM (act old current) t
 where
  act old current t = \case
    ActStep -> do
      more <- pending t
      when more (() <$ step t)
      pure t
    ActRestart -> crash t "generated_authority_lifecycle_cut" >> restart rw
    ActRedeliverOld -> redeliverWhenIdle t old
    ActRedeliverCurrent -> redeliverWhenIdle t current
  redeliverWhenIdle t delivery = do
    more <- pending t
    unless more (() <$ submit t (DeliverWebhook delivery))
    pure t

authorityExample :: Integer -> Text -> [GeneratedAction] -> [GeneratedAction] -> IO ()
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
    when (ActRestart `elem` before || ActRestart `elem` after) $ dimensions `shouldSatisfy` Set.member "crash_reconstruction"

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

-- | A rule. 'Act' is @execute_one_disclosed_action@ while work is pending
-- and @redeliver_after_quiescence@ otherwise: their preconditions read the
-- live timeline and partition its states, so exactly one of them is enabled
-- at every step, and choosing 'Act' is choosing that one. 'Restart' is
-- @restart_generation@. In the forced-failure machine 'Act' is
-- @trigger_replayable_checker_failure@ (a step while work is pending), the
-- only rule upstream enables there.
data Rule (v :: Type -> Type) = Act | Restart
  deriving stock (Eq, Show)

instance FunctorB Rule where
  bmap _ = \case
    Act -> Act
    Restart -> Restart

instance TraversableB Rule where
  btraverse _ = \case
    Act -> pure Act
    Restart -> pure Restart

-- | The machine's model. Every rule is always available (the live
-- timeline, not the model, decides what 'Act' does), so it carries nothing.
data Model (v :: Type -> Type) = Model

-- | The machine a run drives, and what outlives it: the DST failures each
-- run raised (newest first) and the machine to close before the next run.
data Slot = Slot
  { current :: IORef (Maybe Machine)
  , failures :: IORef [DstFailure]
  }

withSlot :: (Slot -> IO a) -> IO a
withSlot use = do
  slot <- Slot <$> newIORef Nothing <*> newIORef []
  use slot `finally` (readIORef slot.current >>= mapM_ closeMachine)

-- | One machine: upstream's @_DeliveryRecoveryMachine@ instance.
data Machine = Machine
  { slot :: Slot
  , forceFailure :: Bool
  , failurePath :: FilePath
  , seed :: Integer
  , run :: Run
  , timelineRef :: IORef ReadinessTimeline
  , delivery :: Text
  , lost :: Bool
  , redeliverAtFinish :: Bool
  , retained :: IORef Bool
  , directory :: FilePath
  }

-- | The property: draw @start@'s seed and up to @steps@ rules, then run
-- them on a fresh machine with the invariant after @start@ and after every
-- rule, and the teardown's convergence and replay. Everything is drawn
-- before anything runs, so a shrunk case reruns from a fresh World.
deliveryProperty :: Slot -> Bool -> FilePath -> Int -> Int -> Property
deliveryProperty slot force failurePath examples steps = H.withTests (fromIntegral examples) . property $ do
  seed <- forAll worldSeed
  actions <- forAll (Gen.sequential (Range.constant 1 steps) Model (if force then [rule slot Act] else [rule slot Act, rule slot Restart]))
  machine <- evalIO (startMachine slot force failurePath seed)
  label (event "response_lost" (tshow machine.lost))
  label (event "redeliver_at_finish" (tshow machine.redeliverAtFinish))
  invariant =<< evalIO (observeMachine machine)
  H.executeSequential Model actions
  evalIO (finishMachine machine)

rule :: Slot -> Rule v -> Command Gen (H.PropertyT IO) Model
rule slot chosen =
  Command
    { commandGen = \_ -> Just (pure (coerceRule chosen))
    , commandExecute = \input -> evalIO $ do
        machine <- readIORef slot.current >>= maybe (fail "generated readiness machine is not initialized") pure
        runRule machine (coerceRule input)
    , commandCallbacks = [Ensure (\_ _ _ observed -> invariant observed)]
    }
 where
  coerceRule :: Rule a -> Rule b
  coerceRule = \case
    Act -> Act
    Restart -> Restart

-- | Run one rule and observe the timeline after it.
runRule :: Machine -> Rule v -> IO Json
runRule machine chosen = do
  t <- readIORef machine.timelineRef
  more <- pending t
  case chosen of
    Act
      | machine.forceFailure -> when more (() <$ capture machine (step t))
      | more -> () <$ capture machine (step t)
      | otherwise -> () <$ capture machine (submit t (DeliverWebhook machine.delivery))
    Restart -> restartGeneration machine "generated_between_host_steps"
  observeMachine machine

-- | @independent_safety_holds_at_each_generated_boundary@.
invariant :: (MonadTest m) => Json -> m ()
invariant s = do
  assert (intAt (s .: "provider" .: "accepted_by_kind" .: "readiness") <= 1)
  assert (length (items (s .: "facts" .: "admitted_observations")) <= 1)
  s .: "expected" .: "violations" === Array []

observeMachine :: Machine -> IO Json
observeMachine machine = readIORef machine.timelineRef >>= capture machine . state

-- | @start(seed)@ on a fresh World in a fresh directory, closing the
-- previous run's machine first.
startMachine :: Slot -> Bool -> FilePath -> Integer -> IO Machine
startMachine slot force failurePath seed = do
  readIORef slot.current >>= mapM_ closeMachine
  writeIORef slot.current Nothing
  directory <- canonicalizePath =<< (getTemporaryDirectory >>= \tmp -> createTempDirectory tmp "hamsterdan-readiness-campaign-")
  rw <- newReadinessWorld (directory </> "live") defaultBudget (Just seed)
  (lost, crashFirst, redeliverAtFinish, scenarioId) <- drawBranches rw
  scenario <- newIORef scenarioId
  closed <- newIORef False
  timelineRef <- newIORef =<< timeline rw
  retained <- newIORef False
  let close = readIORef closed >>= \done -> unless done (writeIORef closed True >> closeWorld rw)
      run = Run {root = directory, world = rw, scenario, scenarioId, close}
      machineWith delivery = Machine {slot, forceFailure = force, failurePath, seed, run, timelineRef, delivery, lost, redeliverAtFinish, retained, directory}
      pendingMachine = machineWith ""
  writeIORef slot.current (Just pendingMachine)
  t <- readIORef timelineRef
  delivery <-
    capture pendingMachine $
      if force
        then do
          d <- emitWebhook t "issue_comment" "created"
          _ <- deliverWebhook t d
          pure d
        else cleanGreen t lost
  let machine = machineWith delivery
  writeIORef slot.current (Just machine)
  when (crashFirst && not force) $ restartGeneration machine "generated_before_first_host_step"
  pure machine

restartGeneration :: Machine -> Text -> IO ()
restartGeneration machine cut = capture machine $ do
  t <- readIORef machine.timelineRef
  crash t cut
  writeIORef machine.timelineRef =<< restart machine.run.world

-- | The teardown: drain, redeliver at finish, converge, and replay the
-- artifact exactly (nothing more for the forced-failure machine).
finishMachine :: Machine -> IO ()
finishMachine machine = unless machine.forceFailure $ do
  t <- readIORef machine.timelineRef
  capture machine (drain t)
  when machine.redeliverAtFinish (() <$ capture machine (submit t (DeliverWebhook machine.delivery)))
  final <- (.value) <$> capture machine (converge t)
  let provider = final .: "provider"
  final .: "expected" .: "ready" `shouldBe` Bool True
  final .: "actual" .: "readiness_published" `shouldBe` Bool True
  provider .: "accepted_by_kind" .: "readiness" `shouldBe` Int 1
  final .: "facts" .: "admitted_observations" `shouldBe` Array [String ("github-delivery:" <> machine.delivery)]
  when machine.lost $ intAt (provider .: "lookup_recoveries") `shouldSatisfy` (>= 1)
  a <- artifact machine.run.world machine.run.scenarioId
  let origin = originOf a
  origin.seed `shouldBe` machine.seed
  origin.draws `shouldBe` Map.fromList [("event_order", 1), ("fault", 1), ("identifier:scenario", 1), ("workload", 1)]
  _ <- replayConverged machine.run a
  pure ()

closeMachine :: Machine -> IO ()
closeMachine machine = machine.run.close `finally` removePathForcibly machine.directory

-- | @_capture_failure@: record the failure, retain the exact failed
-- artifact once, and let the failure propagate.
capture :: Machine -> IO a -> IO a
capture machine operation =
  operation `catch` \(failure :: DstFailure) -> do
    modifyIORef' machine.slot.failures (failure :)
    done <- readIORef machine.retained
    when (retainable failure && not done) $ do
      writeIORef machine.retained True
      retainFailure machine.run.world machine.run.scenarioId machine.failurePath (machine.directory </> "failure-replay")
    throwIO failure

drawBranches :: ReadinessWorld -> IO (Bool, Bool, Bool, Text)
drawBranches rw = do
  lost <- (== 1) <$> inWorld rw (World.chooseIndex FaultChoice 2)
  crashFirst <- (== 1) <$> inWorld rw (World.chooseIndex EventOrderChoice 2)
  redeliver <- (== 1) <$> inWorld rw (World.chooseIndex WorkloadChoice 2)
  scenarioId <- inWorld rw (World.chooseIdentifier "scenario")
  pure (lost, crashFirst, redeliver, scenarioId)

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

actionsLabel :: [GeneratedAction] -> Text
actionsLabel = \case
  [] -> "none"
  actions -> T.intercalate "," (map actionName actions)

-- | Run one example, naming it in any failure (upstream's @event(...)@).
labelled :: [Text] -> IO () -> IO ()
labelled parts example =
  example `catch` \(problem :: SomeException) -> do
    hPutStrLn stderr ("falsifying example: " <> T.unpack (T.intercalate " " parts))
    throwIO problem

tshow :: (Show a) => a -> Text
tshow = T.pack . show
