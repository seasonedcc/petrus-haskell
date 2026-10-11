-- | The exact Pi 0.83.0 native A2/A4 runtime over a private JSONL Node
-- bridge (@petrus.agenticus.runtime.pi@).
--
-- The adapter materializes one Agent Connection lease, starts the verbatim
-- @pi_helper.mjs@ under the system @node@ in a private mode-0700 root, and
-- speaks its newline-delimited JSON protocol: one @start@ frame, @ready@,
-- any number of @tool_call@ frames answered through the Episode's
-- 'HandsGateway', and one terminal @complete@ or @failed@ frame. A result is
-- published only after the operation claims publication against the current
-- grant, deadline and territory lease, and custody admits it through the
-- connection fence. Native subscription auth is checkpointed back into
-- custody only after the helper and its private root are proven gone.
--
-- The reference's structural protocols (continuation and turn storage,
-- connection custody, helper clients and factories) are records of
-- operations here. 'hostConnectionCustody' adapts the real
-- 'AgentConnectionCustody'.
module Petrus.Agenticus.Runtime.Pi
  ( -- * Pins and catalogs
    piSdkVersion
  , piSdkSourceCommit
  , piAiVersion
  , piSourceCommit
  , piSdkSource
  , piAiSource
  , piCcPatchVersion
  , piCcPatchSourceCommit
  , piCcPatchSource
  , piApiKeyCatalog
  , piSubscriptionCatalog
  , piCcPatchSubscriptionCatalog
    -- * Descriptors
  , piContinuationDescriptor
  , piProgram
  , piProgramCapabilities
  , piContinuationCapabilities
  , piConnectionCapabilities
  , piSubscriptionConnectionCapabilities
  , piCcPatchConnectionCapabilities
  , piCollocatedHands
  , piCapabilityScopedHands
  , piLocalTerritory
  , piGondolinTerritory
  , piE2bTerritory
  , piToolSchemas
    -- * Continuation payloads
  , PiContinuationPayloadV1 (sessionId, workingDirectoryBinding, sessionJsonl)
  , mkPiContinuationPayloadV1
  , payloadSchemaVersion
  , PiContinuationOperations (..)
  , PiTurnOperations (..)
  , PiContinuationCodec
  , piContinuationCodec
  , codecStore
  , codecLoad
    -- * Configuration and invocations
  , PiRuntimeConfig (..)
  , piRuntimeConfig
  , newPiRuntimeConfig
  , renderPiRuntimeConfig
  , PiRuntimeInvocation (..)
  , newPiRuntimeInvocation
  , renderPiRuntimeInvocation
  , piDurableWorkFingerprint
  , piDurableFingerprint
    -- * Connection custody
    -- * Helper clients
  , PiCandidate (..)
  , PiHelperResult (..)
  , PiHelperClient (..)
  , PiHelperArgs (..)
  , PiHelperFactory (..)
  , subprocessFactory
  , SubprocessClient
  , SubprocessOptions (..)
  , subprocessOptions
  , newSubprocessClient
  , newSubprocessClientWith
  , subprocessClient
  , subprocessStartFrame
  , piHelperPath
    -- * Operations
  , PiOperation
  , piOperationId
  , piOperationReceipt
  , piOperationClosed
  , waitPiOperation
  , cancelPiOperation
  , closePiOperation
  , piRuntimeOperation
    -- * The adapter
  , PiRuntimeAdapter
  , newPiRuntimeAdapter
  , PiAdapterOptions (..)
  , piAdapterOptions
  , newPiRuntimeAdapterWith
  , adapterConfig
  , adapterDescriptor
  , adapterHands
  , adapterTerritory
  , adapterProgram
  , adapterContinuationDescriptor
  , adapterRuntimeCapabilities
  , renderPiRuntimeAdapter
  , probe
  , ProbePaths (..)
  , probePaths
  , enableScriptedConformance
  , startPi
  , evictPi
  , receiptPi
  ) where

import Petrus.Agenticus.Runtime.Pi.Internal
