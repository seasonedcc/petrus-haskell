{-# LANGUAGE MultiWayIf #-}

-- | @tests/unit/host/test_v5_rerun.py@: the provider-backed V5 rerun gate.
module RerunSpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_)
import Data.IORef
import Data.Text (Text)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.GitHub.Models
  ( ActionsRunSnapshot (..)
  , CommentReference (..)
  , PublicationResult (..)
  , PublicationStatus (..)
  , RerunIssue (..)
  , RerunRefused (..)
  , boundary
  )
import Hamsterdan.Host.Python (RuntimeError (..))
import Hamsterdan.Host.V5.Claim (CurrentClaim (..))
import Hamsterdan.Host.V5.Rerun
import Hamsterdan.Readiness.NetV5.Gating (Variant (..))
import Hamsterdan.Contracts.Codec (validate)
import Petrus.Json (Json (..))
import Test.Hspec

claim1 :: CurrentClaim
claim1 = CurrentClaim PhaseRunning 1 "h1" "b1" "p1"

reference :: CommentReference
reference = CommentReference 1 "https://example.test/c/1"

mem :: [(Text, Json)]
mem = [("baton", String "ladder")]

indicted, newer :: ActionsRunSnapshot
indicted = ActionsRunSnapshot 5 "h1" "ci.yml" 1 "completed" (Just "failure") []
newer = ActionsRunSnapshot 7 "h1" "ci.yml" 2 "completed" (Just "failure") []

data Mode = Requested | Existing | Refused | Boundary | Unknown | Capability | Unclassified
  deriving stock (Eq)

data Call = Held Integer Text Text | Issue Integer Integer Integer Text
  deriving stock (Eq, Show)

data FakeBroker = FakeBroker {calls :: IORef [Call], broker :: RerunBroker}

newBroker :: Mode -> Bool -> Bool -> IO FakeBroker
newBroker mode found lookupError = do
  calls <- newIORef []
  let cut = (9, 1)
      issued r = RerunIssue r (fst cut) (snd cut)
  pure
    FakeBroker
      { calls
      , broker =
          RerunBroker
            { held = \runId head' operation -> do
                modifyIORef' calls (++ [Held runId head' operation])
                if
                  | lookupError -> throwIO (boundary "comment listing unavailable")
                  | found -> pure (Just (PublicationResult PublicationExisting (Just reference) True False))
                  | otherwise -> pure Nothing
            , issue = \run epoch operation -> do
                modifyIORef' calls (++ [Issue run.id run.attempt epoch operation])
                case mode of
                  Existing -> pure (issued (PublicationResult PublicationExisting (Just reference) True False))
                  Refused -> throwIO (RerunRefused "rerun request does not belong to the configured repository and exact head")
                  Boundary -> throwIO (boundary "GitHub did not prove rerun broker publication")
                  Unknown -> throwIO (RuntimeError "provider returned an unclassifiable terminal")
                  Capability -> pure (issued (PublicationResult PublicationCapabilityUnavailable Nothing False False))
                  Unclassified -> pure (issued (PublicationResult (PublicationUnclassified "banana") (Just reference) True False))
                  Requested -> pure (issued (PublicationResult PublicationRequested (Just reference) True False))
            }
      }

fake :: Mode -> IO FakeBroker
fake mode = newBroker mode False False

req :: RerunReq
req =
  RerunReq
    { fingerprint = "lin:fp1"
    , fp = "fp1"
    , op = "rerun:lin:fp1"
    , head = "h1"
    , base = "b1"
    , policy = "p1"
    , incarnation = 1
    , runId = 5
    , attempt = 1
    , mem
    }

gateWith :: FakeBroker -> CurrentClaim -> [ActionsRunSnapshot] -> V5RerunGate
gateWith b c rs = V5RerunGate {broker = b.broker, runs = \_ -> pure rs, claim = pure c}

gate :: FakeBroker -> V5RerunGate
gate b = gateWith b claim1 [newer, indicted]

unreadableClaim :: IO CurrentClaim
unreadableClaim = throwIO (boundary "claim unreadable")

unreadableRuns :: RunsReader
unreadableRuns _ = throwIO (boundary "workflow runs unavailable")

landed :: Variant -> IO RerunLanded
landed v = do
  v.name `shouldBe` "RerunLanded"
  either (fail . show) pure (validate @RerunLanded v.fields)

assertFault :: Variant -> Expectation
assertFault v = do
  v.name `shouldBe` "RerunFault"
  out <- either (fail . show) pure (validate @RerunFault v.fields)
  (out.fingerprint, out.op, out.fp) `shouldBe` ("lin:fp1", "rerun:lin:fp1", "fp1")
  (out.head, out.base, out.policy, out.incarnation) `shouldBe` ("h1", "b1", "p1", 1)
  (out.runId, out.attempt) `shouldBe` (5, 1)
  out.mem `shouldBe` mem

assertMoved :: Variant -> Expectation
assertMoved v = do
  v.name `shouldBe` "RerunMoved"
  out <- either (fail . show) pure (validate @RerunMoved v.fields)
  (out.fp, out.head, out.base, out.policy, out.incarnation) `shouldBe` ("fp1", "h1", "b1", "p1", 1)
  (out.fingerprint, out.op, out.mem) `shouldBe` ("lin:fp1", "rerun:lin:fp1", mem)

noIssue :: FakeBroker -> Expectation
noIssue b = readIORef b.calls >>= (`shouldBe` []) . filter (\case Issue {} -> True; _ -> False)

spec :: Spec
spec = describe "test_v5_rerun" $ describe "TestRerunGate" $ do
  it "test_a_rerun_lands_with_the_brokers_final_read_as_its_cut" $ do
    b <- fake Requested
    out <- landed =<< rerunGate (gate b) req
    out.disposition `shouldBe` DispositionRequested
    (out.runId, out.attempt) `shouldBe` (5, 1)
    (out.cutRunId, out.cutAttempt) `shouldBe` (9, 1)
    out.mem `shouldBe` mem
    readIORef b.calls >>= (`shouldBe` [Held 5 "h1" "rerun:lin:fp1", Issue 5 1 1 "rerun:lin:fp1"])
  it "test_an_already_held_rerun_reconciles_landed_before_any_read" $ do
    b <- newBroker Requested True False
    out <- landed =<< rerunGate (V5RerunGate b.broker unreadableRuns unreadableClaim) req
    out.disposition `shouldBe` DispositionExisting
    (out.runId, out.attempt) `shouldBe` (5, 1)
    (out.cutRunId, out.cutAttempt) `shouldBe` (5, 1)
    out.mem `shouldBe` mem
    readIORef b.calls >>= (`shouldBe` [Held 5 "h1" "rerun:lin:fp1"])
  let drifts =
        [ ("phase=quiescent", CurrentClaim PhaseQuiescent 1 "h1" "b1" "p1")
        , ("incarnation=2", CurrentClaim PhaseRunning 2 "h1" "b1" "p1")
        , ("head=h2", CurrentClaim PhaseRunning 1 "h2" "b1" "p1")
        , ("base=b2", CurrentClaim PhaseRunning 1 "h1" "b2" "p1")
        , ("policy=p2", CurrentClaim PhaseRunning 1 "h1" "b1" "p2")
        ]
  forM_ drifts $ \(label, observed) ->
    it ("test_any_moved_claim_field_refuses_the_request[" <> label <> "]") $ do
      b <- fake Requested
      assertMoved =<< rerunGate (gateWith b observed [newer, indicted]) req
      noIssue b
  it "test_a_vanished_indicted_run_classifies_moved" $ do
    b <- fake Requested
    assertMoved =<< rerunGate (gateWith b claim1 [newer]) req
    noIssue b
  it "test_the_brokers_own_currency_refusal_classifies_moved" $ do
    b <- fake Refused
    assertMoved =<< rerunGate (gate b) req
  it "test_a_race_found_existing_request_reconciles_landed" $ do
    b <- fake Existing
    out <- landed =<< rerunGate (gate b) req
    out.disposition `shouldBe` DispositionExisting
    (out.cutRunId, out.cutAttempt) `shouldBe` (5, 1)
  it "test_a_lookup_failure_fails_closed" $ do
    b <- newBroker Requested False True
    assertFault =<< rerunGate (gate b) req
  it "test_an_unreadable_claim_fails_closed" $ do
    b <- fake Requested
    assertFault =<< rerunGate (V5RerunGate b.broker (\_ -> pure [indicted]) unreadableClaim) req
    noIssue b
  it "test_a_runs_read_failure_fails_closed" $ do
    b <- fake Requested
    assertFault =<< rerunGate (V5RerunGate b.broker unreadableRuns (pure claim1)) req
    noIssue b
  it "test_an_issuance_boundary_failure_fails_closed" $ do
    b <- fake Boundary
    assertFault =<< rerunGate (gate b) req
  it "test_an_unknown_terminal_fails_closed" $ do
    b <- fake Unknown
    assertFault =<< rerunGate (gate b) req
  it "test_a_capability_denial_fails_closed" $ do
    b <- fake Capability
    assertFault =<< rerunGate (gate b) req
  it "test_an_unrecognized_returned_status_fails_closed" $ do
    b <- fake Unclassified
    assertFault =<< rerunGate (gate b) req
