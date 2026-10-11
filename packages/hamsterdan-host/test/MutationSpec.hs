-- | @tests/unit/host/test_v5_mutation.py@: the provider-backed V5
-- mutation/git gate.
module MutationSpec (spec) where

import Control.Exception (SomeException, throwIO, toException)
import Control.Monad (forM_)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Hamsterdan.Agents.Protocol hiding (Correlation)
import Hamsterdan.Contracts.Codec (Contract, dump, validate)
import Hamsterdan.Contracts.ReadinessV5 (DeclinedM (..), FaultM (..), MovedM (..), MutWork (..), Phase (..), Pushed (..))
import Hamsterdan.GitHub.Models (boundary)
import Hamsterdan.Host.GitPublish
  ( GitPublishError (..)
  , GitPublishResult (..)
  , GitReconciliation (..), OperationDisposition (..)
  , PublicationCategory (..)
  )
import Hamsterdan.Host.Python (RuntimeError (..), ValueError (..))
import Hamsterdan.Host.V5.Claim (CurrentClaim (..))
import Hamsterdan.Host.V5.Mutation
import Hamsterdan.Readiness.NetV5.Gating (Variant (..))
import Petrus.Json (Json (..))
import ReviewSpec (stubAgentRunner)
import Test.Hspec

headSha, baseSha, newHead :: Text
headSha = T.replicate 40 "a"
baseSha = T.replicate 40 "b"
newHead = T.replicate 40 "c"

claim0 :: CurrentClaim
claim0 = CurrentClaim PhaseRunning 3 headSha baseSha "policy-1"

work0 :: MutWork
work0 =
  MutWork
    { op = "change"
    , opKey = "push:comment:9:" <> headSha <> ":i3"
    , head = headSha
    , base = baseSha
    , policy = "policy-1"
    , incarnation = 3
    , lineage = ""
    , kind = "change"
    , instruction = "rename the config key"
    , runId = 0
    , attempt = 0
    }

movedPolicy :: CurrentClaim
movedPolicy = CurrentClaim PhaseRunning 3 headSha baseSha "policy-2"

-- | @replace(WORK, op=, kind=, instruction=, lineage=, run_id=, attempt=)@.
workWith :: Text -> Text -> Text -> Text -> Integer -> Integer -> MutWork
workWith op kind instruction lineage runId attempt =
  MutWork op work0.opKey headSha baseSha "policy-1" 3 lineage kind instruction runId attempt

-- | @replace(changed(request), status=status, diff="", changed_files=[])@.
noChange :: Text -> CodingRequest -> CodingResult
noChange status r = CodingResult r.kind r.repository r.pullRequest r.epoch r.head r.base r.ref status "not_attempted" "" [] [] "Apply requested change"

changed :: CodingRequest -> CodingResult
changed r =
  CodingResult
    { kind = r.kind
    , repository = r.repository
    , pullRequest = r.pullRequest
    , epoch = r.epoch
    , head = r.head
    , base = r.base
    , ref = r.ref
    , status = "changed"
    , reproductionStatus = "not_attempted"
    , diff = "diff --git a/a b/a\n"
    , changedFiles = ["a"]
    , validationEvidence = []
    , proposedCommitMessage = "Apply requested change"
    }

-- | One recorded @Runner.code@ call.
data RunnerCall = RunnerCall
  { url :: Text
  , request :: CodingRequest
  , operation :: Text
  , attempt :: Integer
  , current :: Maybe Bool
  }

data Runner = Runner {calls :: IORef [RunnerCall], runner :: AgentRunner}

-- | @Runner(outcome, consult_current=)@: 'Nothing' returns 'changed'.
newRunner :: Maybe (Either SomeException CodingResult) -> Bool -> IO Runner
newRunner outcome consultCurrent = do
  calls <- newIORef []
  pure
    Runner
      { calls
      , runner =
          stubAgentRunner
            { code = \url request inv -> do
                current <-
                  if consultCurrent
                    then maybe (fail "is_current is None") (fmap Just) inv.isCurrent
                    else pure Nothing
                modifyIORef' calls (++ [RunnerCall url request inv.operation inv.attempt current])
                case outcome of
                  Nothing -> pure (changed request)
                  Just (Left e) -> throwIO e
                  Just (Right r) -> pure r
            }
      }

returning :: CodingResult -> IO Runner
returning r = newRunner (Just (Right r)) False

raising :: AgentProtocolError -> IO Runner
raising e = newRunner (Just (Left (toException e))) False

data PublisherCall
  = Reconcile Text Text Text Text Bool
  | Publish CodingResult Text Text Text Text Bool

data Publisher = Publisher {calls :: IORef [PublisherCall], publisher :: MutationPublisher}

absent :: Either SomeException GitReconciliation
absent = Right (GitReconciliation OperationAbsent headSha "" [])

existing :: Either SomeException GitReconciliation
existing = Right (GitReconciliation OperationExisting newHead newHead [headSha])

published :: Either SomeException GitPublishResult
published = Right (GitPublishResult newHead False)

-- | @Publisher(reconciliation=, publication=)@; reconciliations are
-- consumed in order, the last one repeating.
newPublisher :: [Either SomeException GitReconciliation] -> Either SomeException GitPublishResult -> IO Publisher
newPublisher reconciliations publication = do
  calls <- newIORef []
  queue <- newIORef reconciliations
  pure
    Publisher
      { calls
      , publisher =
          MutationPublisher
            { reconcile = \operation digest expected base mergeBase -> do
                modifyIORef' calls (++ [Reconcile operation digest expected base mergeBase])
                outcome <-
                  atomicModifyIORef' queue $ \case
                    [x] -> ([x], x)
                    x : xs -> (xs, x)
                    [] -> ([], absent)
                either throwIO pure outcome
            , publish = \result operation digest expected base mergeBase -> do
                modifyIORef' calls (++ [Publish result operation digest expected base mergeBase])
                either throwIO pure publication
            }
      }

defaultPublisher :: IO Publisher
defaultPublisher = newPublisher [absent] published

-- | @gate(runner, publisher, claims)@: each read takes the next claim.
gate :: Runner -> Publisher -> [IO CurrentClaim] -> IO V5MutationGate
gate r p observed = do
  queue <- newIORef observed
  let readClaim =
        atomicModifyIORef' queue (\case [] -> ([], Nothing); x : xs -> (xs, Just x))
          >>= maybe (fail "StopIteration") id
  pure
    V5MutationGate
      { repository = "owner/repo"
      , pullRequest = 7
      , runner = r.runner
      , publisher = p.publisher
      , publicCloneUrl = "https://example.test/owner/repo.git"
      , claim = readClaim
      }

claims :: [CurrentClaim] -> [IO CurrentClaim]
claims = map pure

decode :: forall a. (Contract a) => Text -> Variant -> IO a
decode name v = do
  v.name `shouldBe` name
  either (fail . show) pure (validate @a v.fields)

assertFault :: Variant -> Expectation
assertFault v = do
  out <- decode @FaultM "FaultM" v
  (out.op, out.opKey, out.head, out.base, out.policy) `shouldBe` (work0.op, work0.opKey, work0.head, work0.base, work0.policy)
  (out.kind, out.instruction, out.runId, out.attempt) `shouldBe` (work0.kind, work0.instruction, work0.runId, work0.attempt)

declinedCategory :: Variant -> IO Text
declinedCategory v = (.category) <$> decode @DeclinedM "DeclinedM" v

request0 :: IO CodingRequest
request0 = mutationRequest "owner/repo" 7 work0

isReconcile :: PublisherCall -> Bool
isReconcile = \case Reconcile {} -> True; _ -> False

enumText :: (Contract a) => a -> Text
enumText c = case dump c of String t -> t; other -> T.pack (show other)

unreadable :: IO CurrentClaim
unreadable = throwIO (boundary "claim unavailable")

spec :: Spec
spec = describe "test_v5_mutation" $ do
  describe "TestMutationGate" $ do
    it "test_existing_commit_reconciles_before_claim_or_agent" $ do
      r <- newRunner Nothing False
      p <- newPublisher [existing] published
      out <- gitGate <$> gate r p [] >>= ($ work0) >>= decode @Pushed "Pushed"
      out `shouldBe` Pushed work0.op work0.opKey headSha newHead 3 ""
      readIORef r.calls >>= (`shouldBe` 0) . length
      readIORef p.calls >>= (`shouldBe` [True]) . map isReconcile

    forM_
      [ ("phase", CurrentClaim PhaseQuiescent 3 headSha baseSha "policy-1")
      , ("incarnation", CurrentClaim PhaseRunning 4 headSha baseSha "policy-1")
      , ("head", CurrentClaim PhaseRunning 3 newHead baseSha "policy-1")
      , ("base", CurrentClaim PhaseRunning 3 headSha (T.replicate 40 "d") "policy-1")
      , ("policy", movedPolicy)
      ]
      $ \(label, observed) ->
        it ("test_any_pre_agent_claim_movement_returns_the_full_observation[" <> label <> "]") $ do
          r <- newRunner Nothing False
          p <- defaultPublisher
          g <- gate r p (claims [observed])
          out <- gitGate g work0 >>= decode @MovedM "MovedM"
          let phase = observed.phase
          out
            `shouldBe` MovedM
              work0.op
              work0.opKey
              headSha
              3
              observed.head
              observed.base
              observed.policy
              observed.incarnation
              phase
          readIORef r.calls >>= (`shouldBe` 0) . length

    it "test_claim_movement_during_agent_wins_over_a_clean_decline" $ do
      request <- request0
      r <- returning (noChange "unable" request)
      p <- defaultPublisher
      g <- gate r p (claims [claim0, movedPolicy])
      out <- gitGate g work0 >>= decode @MovedM "MovedM"
      out.observedPolicy `shouldBe` "policy-2"

    forM_ ["unchanged", "unable", "banana"] $ \status ->
      it ("test_agent_no_change_is_a_clean_decline_after_the_second_fence[" <> T.unpack status <> "]") $ do
        request <- request0
        r <- returning (noChange status request)
        p <- defaultPublisher
        g <- gate r p (claims [claim0, claim0])
        category <- declinedCategory =<< gitGate g work0
        category `shouldBe` (if status `elem` ["unchanged", "unable"] then status else "output_schema")

    forM_ [minBound .. maxBound :: AgentResultCategory] $ \category ->
      it ("test_classified_agent_protocol_outcomes_decline[" <> T.unpack (enumText category) <> "]") $ do
        r <- raising (protocolError "classified") {resultCategory = Just category}
        p <- defaultPublisher
        g <- gate r p (claims [claim0, claim0])
        out <- declinedCategory =<< gitGate g work0
        out `shouldBe` enumText category

    forM_
      [ ("timeout", (protocolError "timeout") {timedOut = True}, "timed_out")
      , ("canceled", (protocolError "canceled") {canceled = True}, "canceled")
      , ("cleanup", (protocolError "cleanup") {cleanupCategory = Just CleanupUnverified}, "cleanup_unverified")
      , ("protocol", protocolError "protocol", "protocol")
      ]
      $ \(label, err, expected) ->
        it ("test_other_agent_protocol_outcomes_decline[" <> label <> "]") $ do
          r <- raising err
          p <- defaultPublisher
          g <- gate r p (claims [claim0, claim0])
          category <- declinedCategory =<< gitGate g work0
          category `shouldBe` expected

    it "test_unreadable_claim_before_or_after_agent_fails_closed" $ do
      r <- newRunner Nothing False
      p <- defaultPublisher
      g <- gate r p (repeat unreadable)
      assertFault =<< gitGate g {publicCloneUrl = "https://example.test/repo.git"} work0
      r' <- newRunner Nothing False
      p' <- defaultPublisher
      g' <- gate r' p' [pure claim0, unreadable]
      assertFault =<< gitGate g' work0

    it "test_success_uses_distinct_global_agent_and_provider_identities" $ do
      r <- newRunner Nothing True
      p <- defaultPublisher
      g <- gate r p (claims [claim0, claim0, claim0])
      out <- gitGate g work0 >>= decode @Pushed "Pushed"
      out `shouldBe` Pushed work0.op work0.opKey headSha newHead 3 ""
      [call] <- readIORef r.calls
      call.url `shouldBe` "https://example.test/owner/repo.git"
      call.operation `shouldBe` ("mutation:owner/repo:pr:7:" <> work0.opKey)
      (call.attempt, call.current) `shouldBe` (1, Just True)
      call.request.kind `shouldBe` "change"
      map Object call.request.selectedWork `shouldBe` [Object [("kind", String "change"), ("request", String "rename the config key")]]
      calls <- readIORef p.calls
      reconcileDigest : _ <- pure [d | Reconcile _ d _ _ _ <- calls]
      [(operation, digest)] <- pure [(o, d) | Publish _ o d _ _ _ <- calls]
      operation `shouldBe` work0.opKey
      digest `shouldBe` reconcileDigest

    forM_
      [ (Correlation, "CORRELATION", "DeclinedM")
      , (PatchAdmission, "PATCH_ADMISSION", "DeclinedM")
      , (CurrentAuthority, "CURRENT_AUTHORITY", "MovedM")
      , (Idempotency, "IDEMPOTENCY", "FaultM")
      , (RepositoryRef, "REPOSITORY_REF", "FaultM")
      , (GitOperation, "GIT_OPERATION", "FaultM")
      , (ObjectWriteFailure, "OBJECT_WRITE", "FaultM")
      , (BoundaryUnavailable, "BOUNDARY_UNAVAILABLE", "FaultM")
      ]
      $ \(category, label, terminal) ->
        it ("test_publication_categories_have_closed_terminals[" <> label <> "]") $ do
          r <- newRunner Nothing False
          p <- newPublisher [absent] (Left (toException (GitPublishError category "classified")))
          g <- gate r p (claims [claim0, claim0, claim0])
          out <- gitGate g work0
          out.name `shouldBe` terminal

    it "test_ambiguous_ref_cas_reconciles_before_failing_closed" $ do
      r <- newRunner Nothing False
      p <- newPublisher [absent, existing] (Left (toException (GitPublishError RefCas "unproven")))
      g <- gate r p (claims [claim0, claim0])
      out <- gitGate g work0 >>= decode @Pushed "Pushed"
      out.newHead `shouldBe` newHead

      r' <- newRunner Nothing False
      p' <- newPublisher [absent, Right (GitReconciliation OperationAbsent newHead "" [])] (Left (toException (GitPublishError RefCas "unproven")))
      g' <- gate r' p' (claims [claim0, claim0])
      assertFault =<< gitGate g' work0

    it "test_raw_publication_boundary_failure_remains_recoverable" $ do
      r <- newRunner Nothing False
      p <- newPublisher [absent] (Left (toException (boundary "PR projection unavailable")))
      g <- gate r p (claims [claim0, claim0])
      assertFault =<< gitGate g work0

    it "test_unexpected_runner_failure_remains_an_activity_failure" $ do
      r <- newRunner (Just (Left (toException (RuntimeError "bug")))) False
      p <- defaultPublisher
      g <- gate r p (claims [claim0, claim0])
      gitGate g work0 `shouldThrow` (\(RuntimeError m) -> m == "bug")

  describe "TestCodingProjection" $ do
    forM_ ["change", "update_base", "resolve_conflict"] $ \kind ->
      it ("test_human_work_preserves_its_kind_and_instruction[" <> T.unpack kind <> "]") $ do
        request <- mutationRequest "owner/repo" 7 (workWith kind kind work0.instruction "" 0 0)
        request.kind `shouldBe` "change"
        map Object request.selectedWork `shouldBe` [Object [("kind", String kind), ("request", String work0.instruction)]]
        (length request.failureEvidence, request.fingerprint, length request.lineage) `shouldBe` (0, "", 0)
        request.mergeBase `shouldBe` (kind /= "change")

    it "test_repair_projects_exact_failure_evidence_and_budget_lineage" $ do
      request <-
        mutationRequest
          "owner/repo"
          7
          (workWith "repair:L1:fp1" "repair" "" "L1" 42 2)
      request.kind `shouldBe` "repair"
      length request.selectedWork `shouldBe` 0
      map Object request.failureEvidence
        `shouldBe` [ Object
                       [ ("head", String headSha)
                       , ("run_id", Int 42)
                       , ("attempt", Int 2)
                       , ("conclusion", String "failure")
                       , ("fingerprint", String "fp1")
                       ]
                   ]
      request.fingerprint `shouldBe` "fp1"
      map Object request.lineage
        `shouldBe` [Object [("kind", String "repair_budget"), ("lineage", String "L1"), ("operation", String "repair:L1:fp1")]]

    forM_
      ( zip
          [0 :: Int ..]
          [ workWith "repair:wrong:fp1" "repair" "" "L1" 1 1
          , workWith "repair:L1:" "repair" "" "L1" 1 1
          , workWith "repair:L1:fp1" "repair" work0.instruction "L1" 1 1
          , workWith "repair:L1:fp1" "repair" "" "L1" 0 1
          ]
      )
      $ \(i, work) ->
        it ("test_malformed_repair_payload_is_an_internal_contract_failure[work" <> show i <> "]") $
          mutationRequest "owner/repo" 7 work `shouldThrow` (\(ValueError m) -> "repair" `T.isInfixOf` m)

  -- Not an upstream case: the provider identity (ref and payload digest)
  -- pinned to the values the Python reference computes for the same work.
  describe "reference_bytes" $
    forM_
      [ (work0, "c5cb5cf2bf0ef7331fedc11f64275d6c88d11bd7244eb4b9449d00c3b5002e31")
      , (workWith "repair:L1:fp1" "repair" "" "L1" 42 2, "cc3d3b490b50676305aaf3cfd67bacce62dc009a36701634d574ee1c70552da9")
      , (workWith "update_base" "update_base" work0.instruction "" 0 0, "2535af540aeecab3371c7c24698c7df5527a2a7979d6d2ebb3014e58d6c9b45d")
      ]
      $ \(work, expected) ->
        it ("ref_and_payload_digest_match_python[" <> T.unpack work.kind <> "]") $ do
          request <- mutationRequest "owner/repo" 7 work
          request.ref `shouldBe` "hamsterdan/mutation/46aea5f6f5f75cfcfe7b45d6516030c1"
          r <- newRunner Nothing False
          p <- newPublisher [existing] published
          g <- gate r p []
          _ <- gitGate g work
          calls <- readIORef p.calls
          [d | Reconcile _ d _ _ _ <- calls] `shouldBe` [expected]
