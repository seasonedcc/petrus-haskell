-- | Bounded public-Pi one-model-phase Activity adapter
-- (@petrus.agenticus.runtime.pi_model_phase@).
--
-- The adapter is the Agent-as-a-Net @model_phase@ Activity for one direct
-- API-key provider. Each call materializes one read-only credential lease,
-- runs the verbatim @pi_model_phase_helper.mjs@ once under the system
-- @node@ in a private mode-0700 root (one @start@ frame in, one terminal
-- frame out, tools declared but never executed), validates the exact public
-- assistant message and transcript extension, admits the result through the
-- connection fence, releases the lease, and only then publishes the private
-- assistant and Continuation payloads.
--
-- The reference's structural protocols (Continuation storage, custody,
-- helper clients and factories) are records of operations here.
module Petrus.Agenticus.Runtime.PiModelPhase
  ( -- * Bounds
    maxTranscriptBytes
  , maxOutputBytes
  , maxMessages
  , maxFrameBytes
    -- * Payloads and publications
  , PiModelPhaseContinuationPayloadV1 (transcriptJson)
  , mkPiModelPhaseContinuationPayloadV1
  , PiModelPhaseOutputPayloadV1 (assistantJson)
  , mkPiModelPhaseOutputPayloadV1
  , payloadSchemaVersion
  , PiModelPhasePublication (outputReference, continuationReference)
  , mkPiModelPhasePublication
  , PiModelPhaseOperations (..)
  , PiModelPhaseCustody (..)
  , piModelPhaseCustody
    -- * Configuration
  , PiModelPhaseConfig (..)
  , piModelPhaseConfig
  , newPiModelPhaseConfig
    -- * Helper clients
  , PhaseCandidate (..)
  , PhaseClient (..)
  , PhaseClientArgs (..)
  , PhaseFactory (..)
  , subprocessPhaseFactory
  , PhaseSubprocessClient
  , newPhaseSubprocessClient
  , phaseSubprocessClient
  , phaseSubprocessExited
  , piModelPhaseHelperPath
    -- * The adapter
  , PiModelPhaseAdapter
  , newPiModelPhaseAdapter
  , modelPhaseAdapterActivity
  , probeModelPhase
  , modelPhaseNode
  ) where

import Petrus.Agenticus.Runtime.PiModelPhase.Internal
