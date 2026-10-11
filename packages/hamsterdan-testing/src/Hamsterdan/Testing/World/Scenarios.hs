{-# LANGUAGE MultiWayIf #-}

-- | The named World scenarios @differential/world_reference.py@ authors
-- through the reference's World: the Timeline call sequences of
-- @test_readiness_world.py@, each campaign's @\@example@ cases of
-- @test_readiness_campaign.py@, and the coverage fixture of
-- @test_readiness_coverage.py@, with their assertions left out.
--
-- The interop spec authors each one in both languages and compares the
-- artifact bytes; the benchmark times authoring and replay.
module Hamsterdan.Testing.World.Scenarios
  ( Scenario (..)
  , scenarios
  , authorScenario
  , cleanGreen
  , green
  , setPr
  , drain
  , moved
  , limited
  ) where

import Control.Exception (throwIO, try)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Testing.World
import Hamsterdan.Testing.World.Contract (baseSha, defaultBudget, headSha, readinessPolicyDigest, reminderDelay, withProfileResource)
import Petrus.Json (Json (..))
import Petrus.Testing.Dst (ApplyResult (..), BudgetV4, DstFailure (..), Observation (..), encodeArtifact)
import Petrus.Testing.Dst.World qualified as World
import System.FilePath ((</>))

-- | One named scenario: its seed, its budget, and the body, which returns
-- the scenario id of the artifact it retains.
data Scenario = Scenario
  { name :: Text
  , seed :: Maybe Integer
  , budget :: BudgetV4
  , body :: ReadinessWorld -> IO Text
  }

moved :: Text
moved = T.replicate 40 "c"

setPr :: ReadinessTimeline -> Text -> Text -> IO ()
setPr t h lifecycle = () <$ setPullRequest t (activePullRequest h) {lifecycle}

green :: ReadinessTimeline -> Text -> IO ()
green t h = do
  _ <- setCi t h ["build"] [("build", "success")]
  () <$ setReview t h "clear" []

-- | @clean_green(timeline, response_lost=...)@: the delivery id.
cleanGreen :: ReadinessTimeline -> Bool -> IO Text
cleanGreen t responseLost = do
  setPr t headSha "active"
  green t headSha
  delivery <- emitWebhook t "pull_request" "synchronize"
  when responseLost (loseEffectResponse t "readiness")
  _ <- deliverWebhook t delivery
  pure delivery

drain :: ReadinessTimeline -> IO ()
drain t = do
  more <- pending t
  when more (step t >> drain t)

-- | Step the World itself (@world.world.step()@) while work is pending.
drainWorld :: ReadinessWorld -> IO ()
drainWorld rw = do
  remaining <- inWorld rw World.pendingCount
  when (remaining > 0) (inWorld rw World.step >> drainWorld rw)

-- | Run, keeping a refusal of the expected kind.
refused :: (DstFailure -> Bool) -> IO a -> IO ()
refused expected action =
  try action >>= \case
    Right _ -> pure ()
    Left failure
      | expected failure -> pure ()
      | otherwise -> throwIO failure

isInvariant, isBudget :: DstFailure -> Bool
isInvariant = \case
  InvariantViolation _ -> True
  _ -> False
isBudget = \case
  BudgetExhausted _ _ -> True
  _ -> False

field :: Text -> Json -> Json
field key value = value .: key

publications :: Observation -> [Json]
publications o = case o.value .: "provider" .: "git_publications" of
  Array xs -> xs
  _ -> []

readinessAmbiguity :: ReadinessWorld -> IO Text
readinessAmbiguity rw = do
  t <- timeline rw
  _ <- cleanGreen t True
  _ <- runUntil t "accepted" (\s -> s .: "provider" .: "response_losses" == Array [String "readiness"])
  crash t "after_readiness_terminal_before_projection"
  _ <- restart rw >>= converge
  pure "hamsterdan-readiness-ambiguity-restart-v1"

reminderAmbiguity :: ReadinessWorld -> IO Text
reminderAmbiguity rw = do
  t <- timeline rw
  _ <- cleanGreen t False
  drain t
  _ <- observe t
  loseEffectResponse t "reminder"
  _ <- advanceTime t reminderDelay
  _ <- runUntil t "accepted" (\s -> s .: "provider" .: "response_losses" == Array [String "reminder"])
  crash t "after_reminder_acceptance_before_projection"
  _ <- restart rw >>= converge
  pure "hamsterdan-readiness-reminder-ambiguity-restart-v1"

gitAmbiguity :: ReadinessWorld -> IO Text
gitAmbiguity rw = do
  t <- timeline rw
  _ <- cleanGreen t False
  drain t
  _ <- setHumanComment t 501 "change" "author"
  delivery <- emitWebhook t "issue_comment" "created"
  _ <- setAgentTerminal t ("conversation:owner/repo:pr:7:delivery:" <> delivery) "conversation_change" "changed" 1
  let publication = "push:comment:501:" <> headSha <> ":i1"
  _ <- setAgentTerminal t ("mutation:owner/repo:pr:7:" <> publication) "coding" "changed" 1
  faultGitPublication t publication "ref_cas" 1
  _ <- deliverWebhook t delivery
  accepted <- runUntil t "accepted" (\s -> length (arr' (s .: "provider" .: "git_publications")) == 1)
  let newHead = textOf (field "result_head" (head' (publications accepted)))
  crash t "after_git_ref_acceptance_before_recovery"
  t2 <- restart rw
  drain t2
  green t2 newHead
  _ <- emitWebhook t2 "pull_request" "synchronize" >>= deliverWebhook t2
  drain t2
  _ <- setHumanComment t2 502 ("recover:" <> publication) "author"
  recovery <- emitWebhook t2 "issue_comment" "created"
  _ <- setAgentTerminal t2 ("conversation:owner/repo:pr:7:delivery:" <> recovery) "conversation_recover" "clear" 1
  _ <- deliverWebhook t2 recovery
  _ <- converge t2
  pure "hamsterdan-v5-git-ambiguity-restart-v1"

disposedCustody :: ReadinessWorld -> IO Text
disposedCustody rw = do
  t <- timeline rw
  _ <- cleanGreen t False
  drainWorld rw
  _ <- emitWebhook t "issue_comment" "created" >>= deliverWebhook t
  refused isInvariant (inWorld rw World.step)
  pure "disposed-custody-invariant-v3"

resourceExhaustion :: ReadinessWorld -> IO Text
resourceExhaustion rw = do
  t <- timeline rw
  refused isBudget (setPr t moved "active")
  pure "readiness-profile-resource-exhaustion-v4"

droppedGenerationExhaustion :: ReadinessWorld -> IO Text
droppedGenerationExhaustion rw = do
  t <- timeline rw
  refused isBudget (crash t "dropped-generation-resource-bound")
  pure "readiness-dropped-generation-resource-exhaustion-v4"

duplicateDelivery :: ReadinessWorld -> IO Text
duplicateDelivery rw = do
  t <- timeline rw
  _ <- advanceTime t 7
  delivery <- cleanGreen t False
  drainWorld rw
  _ <- deliverWebhook t delivery
  _ <- converge t
  pure "readiness-duplicate-delivery-v1"

coverageDuplicateDelivery :: ReadinessWorld -> IO Text
coverageDuplicateDelivery rw = do
  t <- timeline rw
  delivery <- cleanGreen t False
  drain t
  _ <- deliverWebhook t delivery
  _ <- converge t
  pure "coverage-duplicate-delivery-v1"

authority :: Text -> ReadinessWorld -> IO Text
authority path rw = do
  t <- timeline rw
  _ <- cleanGreen t False
  drain t
  _ <- observe t
  setPr t moved (if path == "draft_resume" then "draft" else path)
  green t moved
  current <- emitWebhook t "pull_request" (if path == "closed" then "closed" else "synchronize")
  _ <- deliverWebhook t current
  drain t
  _ <- observe t
  when (path == "draft_resume") $ do
    setPr t moved "active"
    () <$ (emitWebhook t "pull_request" "ready_for_review" >>= deliverWebhook t)
  _ <- converge t
  pure ("readiness-authority-lifecycle-" <> path <> "-v2")

timer :: Text -> Text -> Bool -> Bool -> ReadinessWorld -> IO Text
timer path crashCut responseLost redeliver rw = do
  t0 <- timeline rw
  initial <- cleanGreen t0 False
  drain t0
  if
    | path == "new_head" -> do
        setPr t0 moved "active"
        green t0 moved
        _ <- emitWebhook t0 "pull_request" "synchronize" >>= deliverWebhook t0
        drain t0
    | path == "draft_resume" -> do
        setPr t0 headSha "draft"
        _ <- emitWebhook t0 "pull_request" "converted_to_draft" >>= deliverWebhook t0
        drain t0
        setPr t0 headSha "active"
        _ <- emitWebhook t0 "pull_request" "ready_for_review" >>= deliverWebhook t0
        drain t0
    | path == "closed" -> do
        setPr t0 headSha "closed"
        _ <- emitWebhook t0 "pull_request" "closed" >>= deliverWebhook t0
        drain t0
    | otherwise -> pure ()
  when redeliver (() <$ deliverWebhook t0 initial)
  when responseLost (loseEffectResponse t0 "reminder")
  t1 <-
    if crashCut == "before_due"
      then do
        crash t0 "generated_timer_before_due"
        t <- restart rw
        drain t
        pure t
      else pure t0
  _ <- advanceTime t1 reminderDelay
  t2 <-
    if crashCut == "after_due"
      then crash t1 "generated_timer_after_due" >> restart rw
      else pure t1
  t3 <-
    if path /= "closed"
      then do
        _ <- runUntil t2 "accepted" (\s -> s .: "provider" .: "accepted_by_kind" .: "reminder" == Int 1)
        if crashCut == "after_acceptance"
          then crash t2 "generated_timer_after_acceptance" >> restart rw
          else pure t2
      else pure t2
  _ <- converge t3
  pure ("readiness-reminder-timer-" <> path <> "-v1")

git :: Bool -> Text -> Bool -> ReadinessWorld -> IO Text
git responseLost crashCut redeliver rw = do
  t0 <- timeline rw
  _ <- cleanGreen t0 False
  drain t0
  _ <- setHumanComment t0 501 "change" "author"
  delivery <- emitWebhook t0 "issue_comment" "created"
  let publication = "push:comment:501:" <> headSha <> ":i1"
  _ <- setAgentTerminal t0 ("conversation:owner/repo:pr:7:delivery:" <> delivery) "conversation_change" "changed" 1
  _ <- setAgentTerminal t0 ("mutation:owner/repo:pr:7:" <> publication) "coding" "changed" 1
  when responseLost (faultGitPublication t0 publication "ref_cas" 1)
  t1 <-
    if crashCut == "before_delivery"
      then do
        crash t0 "generated_git_before_delivery"
        t <- restart rw
        drain t
        pure t
      else pure t0
  _ <- deliverWebhook t1 delivery
  accepted <- runUntil t1 "accepted" (\s -> length (arr' (s .: "provider" .: "git_publications")) == 1)
  let newHead = textOf (field "result_head" (head' (publications accepted)))
  t2 <-
    if crashCut == "after_acceptance"
      then crash t1 "generated_git_after_acceptance" >> restart rw
      else pure t1
  drain t2
  green t2 newHead
  _ <- emitWebhook t2 "pull_request" "synchronize" >>= deliverWebhook t2
  drain t2
  when redeliver (() <$ deliverWebhook t2 delivery)
  t3 <-
    if crashCut == "after_head"
      then do
        crash t2 "generated_git_after_head"
        t <- restart rw
        drain t
        pure t
      else pure t2
  when responseLost $ do
    _ <- setHumanComment t3 502 ("recover:" <> publication) "author"
    recovery <- emitWebhook t3 "issue_comment" "created"
    _ <- setAgentTerminal t3 ("conversation:owner/repo:pr:7:delivery:" <> recovery) "conversation_recover" "clear" 1
    () <$ deliverWebhook t3 recovery
  _ <- converge t3
  pure ("readiness-v5-git-publication-" <> crashCut <> "-v1")

arr' :: Json -> [Json]
arr' = \case
  Array xs -> xs
  _ -> []

head' :: [Json] -> Json
head' = \case
  x : _ -> x
  [] -> Null

textOf :: Json -> Text
textOf = \case
  String s -> s
  _ -> ""

-- | The default budget with one profile resource limit changed.
limited :: Text -> Integer -> BudgetV4
limited name value = withProfileResource name value defaultBudget

-- | Every scenario, in the reference driver's order.
scenarios :: [Scenario]
scenarios =
  [ Scenario "readiness-ambiguity" Nothing defaultBudget readinessAmbiguity
  , Scenario "reminder-ambiguity" Nothing defaultBudget reminderAmbiguity
  , Scenario "git-ambiguity" Nothing defaultBudget gitAmbiguity
  , Scenario "disposed-custody" Nothing defaultBudget disposedCustody
  , Scenario "resource-exhaustion" Nothing (limited "retained.provider.authorities" 1) resourceExhaustion
  , Scenario "dropped-generation-exhaustion" Nothing (limited "retained.profile.dropped_generations" 0) droppedGenerationExhaustion
  , Scenario "duplicate-delivery" Nothing defaultBudget duplicateDelivery
  , Scenario "coverage-duplicate-delivery" Nothing defaultBudget coverageDuplicateDelivery
  , Scenario "authority-active" (Just 0) defaultBudget (authority "active")
  , Scenario "authority-draft_resume" (Just 0) defaultBudget (authority "draft_resume")
  , Scenario "authority-closed" (Just 0) defaultBudget (authority "closed")
  , Scenario "timer-stable" (Just 0) defaultBudget (timer "stable" "before_due" False False)
  , Scenario "timer-new_head" (Just 1) defaultBudget (timer "new_head" "after_due" False True)
  , Scenario "timer-draft_resume" (Just 2) defaultBudget (timer "draft_resume" "after_acceptance" True True)
  , Scenario "timer-closed" (Just 3) defaultBudget (timer "closed" "after_due" False True)
  , Scenario "git-before_delivery" (Just 0) defaultBudget (git False "before_delivery" False)
  , Scenario "git-after_acceptance" (Just 1) defaultBudget (git True "after_acceptance" True)
  , Scenario "git-after_head" (Just 2) defaultBudget (git True "after_head" False)
  , Scenario "git-none" (Just 3) defaultBudget (git False "none" True)
  ]

-- | Author one scenario under a root: the artifact's @encode_artifact@
-- bytes.
authorScenario :: Scenario -> FilePath -> IO ByteString
authorScenario s root = do
  rw <- newReadinessWorld (root </> "live") s.budget s.seed
  scenarioId <- s.body rw
  a <- artifact rw scenarioId
  closeWorld rw
  either (throwIO . userError . T.unpack) pure (encodeArtifact a)

_unusedResult :: ApplyResult -> Json
_unusedResult r = r.value

_unusedBase :: (Text, Text)
_unusedBase = (baseSha, readinessPolicyDigest)
