-- | Provider-backed rerun gate for the V5 topology (@host/v5/rerun.py@).
--
-- The gate executes ONE same-head whole-run rerun request against the
-- 'RerunBroker' surface and classifies its outcome: lookup-first
-- reconciliation before any fence or read; a full claim fence; proven
-- pre-effect movement (a vanished indicted run, the broker's currency
-- refusal) as Moved; and every unproven outcome as Fault, which retains
-- the exact request. The ladder has no blocked rung by design.
module Hamsterdan.Host.V5.Rerun
  ( RerunBroker (..)
  , rerunBroker
  , RunsReader
  , V5RerunGate (..)
  , rerunGate
  ) where

import Data.List (find)
import Data.Text (Text)
import Hamsterdan.Contracts.ReadinessV5
import Hamsterdan.GitHub.Effects (CommentRerunBroker)
import Hamsterdan.GitHub.Effects qualified as Effects
import Hamsterdan.GitHub.Models (ActionsRunSnapshot (..), PublicationResult (..), RerunIssue (..))
import Hamsterdan.Host.Errors (Caught (..), catchGate, caughtReason)
import Hamsterdan.Host.V5.Claim (ClaimReader, CurrentClaim (..))
import Hamsterdan.Readiness.NetV5.Gating (Variant, variantOf)
import Petrus.Json.PythonText (pythonStrRepr)

-- | The @CommentRerunBroker@ surface the gate binds to.
data RerunBroker = RerunBroker
  { held :: Integer -> Text -> Text -> IO (Maybe PublicationResult)
  -- ^ @held(run_id, head, operation)@
  , issue :: ActionsRunSnapshot -> Integer -> Text -> IO RerunIssue
  -- ^ @issue(run, epoch=, operation=)@
  }

rerunBroker :: CommentRerunBroker -> RerunBroker
rerunBroker broker = RerunBroker {held = Effects.held broker, issue = Effects.issue broker}

-- | The provider's current runs for a head.
type RunsReader = Text -> IO [ActionsRunSnapshot]

-- | @V5RerunGate(broker, runs, claim)@.
data V5RerunGate = V5RerunGate
  { broker :: RerunBroker
  , runs :: RunsReader
  , claim :: ClaimReader
  }

data Step a = Done Variant | Go a

rerunGate :: V5RerunGate -> RerunReq -> IO Variant
rerunGate g work = do
  let existing =
        variantOf
          RerunLanded
            { fingerprint = work.fingerprint
            , op = work.op
            , runId = work.runId
            , attempt = work.attempt
            , disposition = DispositionExisting
            , cutRunId = work.runId
            , cutAttempt = work.attempt
            , mem = work.mem
            }
      moved =
        variantOf
          RerunMoved
            { fingerprint = work.fingerprint
            , fp = work.fp
            , head = work.head
            , base = work.base
            , policy = work.policy
            , incarnation = work.incarnation
            , op = work.op
            , mem = work.mem
            }
      fault reason =
        variantOf
          RerunFault
            { fingerprint = work.fingerprint
            , op = work.op
            , reason
            , fp = work.fp
            , head = work.head
            , base = work.base
            , policy = work.policy
            , incarnation = work.incarnation
            , runId = work.runId
            , attempt = work.attempt
            , mem = work.mem
            }
      faulted :: forall a. Caught -> IO (Step a)
      faulted = pure . Done . fault . caughtReason
      expected = CurrentClaim "running" work.incarnation work.head work.base work.policy
  first <-
    catchGate
      ( do
          found <- g.broker.held work.runId work.head work.op
          case found of
            Just _ -> pure (Done existing)
            Nothing -> Go <$> g.claim
      )
      faulted
  case first of
    Done terminal -> pure terminal
    Go current
      | current /= expected -> pure moved
      | otherwise -> do
          listed <- catchGate (Go <$> g.runs work.head) faulted
          case listed of
            Done terminal -> pure terminal
            Go reported -> case find (\candidate -> candidate.id == work.runId) reported of
              Nothing -> pure moved
              Just run -> do
                issued <-
                  catchGate (Go <$> g.broker.issue run work.incarnation work.op) $ \case
                    CaughtRerunRefused _ -> pure (Done moved)
                    other -> faulted other
                pure $ case issued of
                  Done terminal -> terminal
                  Go answer
                    | not answer.result.capabilityAvailable -> fault "the provider proved it cannot publish the rerun request"
                    | answer.result.status == "existing" -> existing
                    | answer.result.status /= "requested" ->
                        fault ("unclassified rerun status " <> pythonStrRepr answer.result.status)
                    | otherwise ->
                        variantOf
                          RerunLanded
                            { fingerprint = work.fingerprint
                            , op = work.op
                            , runId = work.runId
                            , attempt = work.attempt
                            , disposition = DispositionRequested
                            , cutRunId = answer.cutRunId
                            , cutAttempt = answer.cutAttempt
                            , mem = work.mem
                            }
