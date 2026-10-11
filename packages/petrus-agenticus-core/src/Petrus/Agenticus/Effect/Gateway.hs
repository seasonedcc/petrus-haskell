-- | Lookup-first host gateway for provider-neutral external Effects
-- (@petrus.agenticus.effect.gateway@).
--
-- Workspace mutation belongs to Agenticus Hands.  This gateway accepts only
-- a host-approved external Effect proposal and never retries one provider
-- execution inside the same call: every uncertain response is reconciled by
-- lookup first.
--
-- The reference's protocols are records of 'IO' functions here.  A provider
-- call that throws a synchronous exception is treated like the reference's
-- @except Exception@; asynchronous exceptions and 'ExitCode' (the analogues
-- of @KeyboardInterrupt@ and @SystemExit@) propagate.  The reference's
-- \"wrong return type\" branches cannot arise: the types rule them out.
module Petrus.Agenticus.Effect.Gateway
  ( EffectAdapter (..)
  , EffectFenceSource (..)
  , EffectGateway (..)
  , effectGateway
  , execute
  , executeJson
  ) where

import Control.Exception (Exception (..), SomeException, evaluate, throwIO, try)
import Petrus.Agenticus.Effect.Model
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Exception
import Petrus.Json (Json)
import System.Exit (ExitCode)

-- | Host adapter that owns provider lookup and native conditional mutation.
data EffectAdapter = EffectAdapter
  { lookup :: EffectProposal -> IO LookupResult
  , execute :: EffectProposal -> EffectPayload -> EffectFence -> IO EffectReceipt
  -- ^ Execute once, enforcing the provider's native target-head condition
  -- from the fence.
  }

-- | Host authority that refreshes all current fence coordinates together.
newtype EffectFenceSource = EffectFenceSource
  { current :: EffectProposal -> IO EffectFence
  }

-- | Correlate approval, lookup, fresh fences, one execution, and digest-only
-- evidence.
data EffectGateway = EffectGateway
  { adapter :: EffectAdapter
  , fences :: EffectFenceSource
  }

effectGateway :: EffectAdapter -> EffectFenceSource -> EffectGateway
effectGateway = EffectGateway

-- | @EffectGateway.execute(proposal, payload, approval)@ for a decoded JSON
-- payload: the approval is checked first, then the payload is admitted
-- (raising the reference's @TypeError@s), then its digest.
executeJson :: EffectGateway -> EffectProposal -> Json -> EffectDecision -> IO EffectDecision
executeJson gateway proposal payload approval = do
  _ <- throwLeft (approvalFence proposal approval)
  strict <- throwLeft (payloadFromJson payload)
  execute gateway proposal strict approval

-- | Execute at most once after lookup and fresh fences; reconcile
-- uncertainty without blind retry.  Raises @TypeError@ for a non-approval,
-- @ValueError@ for an approval or payload that does not match the proposal;
-- both before any provider call.
execute :: EffectGateway -> EffectProposal -> EffectPayload -> EffectDecision -> IO EffectDecision
execute gateway proposal payload approval = do
  fence <- throwLeft (approvalFence proposal approval)
  if digestPayload payload /= proposal.payloadDigest
    then throwAgenticus ValueError "effect payload digest does not match the proposal"
    else do
      first <- lookupOnce gateway proposal
      case first of
        LookupSafeToRetry -> do
          fresh <- attempt (gateway.fences.current proposal)
          case fresh of
            Nothing -> pure (outcome proposal fence RecoveredSafeToRetry)
            Just currentFence
              | currentFence /= fence -> pure (outcome proposal fence RecoveredSuperseded)
              | otherwise -> executeOnce gateway proposal payload fence
        resolved -> pure (classify proposal fence resolved)

approvalFence :: EffectProposal -> EffectDecision -> Either AgenticusError EffectFence
approvalFence proposal approval = case approval.fence of
  Just fence
    | approval.kind == DecisionApprove ->
        if approval.proposalId /= proposal.proposalId || approval.proposalDigest /= proposal.digest
          then Left (valueError "effect approval does not match the proposal")
          else Right fence
  _ -> Left (typeError "effect gateway requires an approved EffectDecision")

executeOnce :: EffectGateway -> EffectProposal -> EffectPayload -> EffectFence -> IO EffectDecision
executeOnce gateway proposal payload fence = do
  answer <- attempt (gateway.adapter.execute proposal payload fence)
  case answer of
    Just receipt
      | correlates receipt proposal -> pure (outcome proposal fence (DirectExecution receipt.receiptDigest))
    _ -> classify proposal fence <$> lookupOnce gateway proposal

-- | @_lookup_decision@ and @_recover@ share one classification once a
-- lookup is not (or no longer) a licence to execute.
classify :: EffectProposal -> EffectFence -> LookupResult -> EffectDecision
classify proposal fence = \case
  LookupApplied receipt
    | correlates receipt proposal -> outcome proposal fence (RecoveredApplied receipt.receiptDigest)
    | otherwise -> outcome proposal fence RecoveredIndeterminate
  LookupSuperseded -> outcome proposal fence RecoveredSuperseded
  LookupSafeToRetry -> outcome proposal fence RecoveredSafeToRetry
  LookupIndeterminate -> outcome proposal fence RecoveredIndeterminate

lookupOnce :: EffectGateway -> EffectProposal -> IO LookupResult
lookupOnce gateway proposal = maybe LookupIndeterminate id <$> attempt (gateway.adapter.lookup proposal)

-- | @_outcome@: evidence over the approved fence, whose coordinates equal
-- the proposal's (the approval check established that).
outcome :: EffectProposal -> EffectFence -> EvidenceOutcome -> EffectDecision
outcome proposal fence result =
  case mkEffectEvidence proposal.proposalId proposal.digest proposal.payloadDigest proposal.target fence (outcomeRecovery result) (outcomeReceiptDigest result) of
    Right evidence -> concluded evidence
    Left failure -> error ("effect gateway built invalid evidence: " <> show failure)

-- | Run a provider call; a synchronous failure becomes 'Nothing'.
attempt :: IO a -> IO (Maybe a)
attempt action = do
  result <- try (action >>= evaluate)
  case result of
    Right value -> pure (Just value)
    Left (failure :: SomeException)
      | isAsync failure -> throwIO failure
      | Just (_ :: ExitCode) <- fromException failure -> throwIO failure
      | otherwise -> pure Nothing
