-- | The application-owned Pi 0.83.0 A5 low-level-loop runtime
-- (@petrus.agenticus.runtime.pi_application@).
--
-- Unlike the native Pi adapter, the application owns a bounded JSON
-- transcript and the helper performs exactly one low-level @runAgentLoop@
-- invocation. The verbatim @pi_application_helper.mjs@ runs under the
-- system @node@ in a private mode-0700 root and speaks newline-delimited
-- JSON: one @start@ frame, @ready@, any number of @tool_call@ frames
-- (answered through the Episode's 'HandsGateway') or @guard_blocked@ frames
-- (a closed write, answered by a synthetic write rejection), and one
-- terminal @complete@ (the transcript delta) or @failed@ frame. A result is
-- published only after the operation claims publication against the
-- current grant, deadline and territory lease, and custody admits it
-- through the connection fence.
--
-- As in "Petrus.Agenticus.Runtime.Pi", the reference's structural protocols
-- (continuation and step storage, connection custody, helper clients and
-- factories) are records of operations.
module Petrus.Agenticus.Runtime.PiApplication
  ( -- * Pins
    piApplicationCodingAgentVersion
  , piApplicationAgentCoreVersion
  , piApplicationAiVersion
  , piApplicationSourceCommit
    -- * Descriptors
  , piApplicationContinuationDescriptor
  , piApplicationProgram
  , piApplicationProgramCapabilities
  , piApplicationContinuationCapabilities
  , piApplicationConnectionCapabilities
  , piApplicationHands
    -- * Payloads
  , applicationTranscript
  , PiApplicationContinuationPayloadV1 (workingDirectoryBinding, transcriptJson)
  , mkPiApplicationContinuationPayloadV1
  , PiApplicationStepPayloadV1 (profile, results, finalText)
  , mkPiApplicationStepPayloadV1
  , applicationPayloadSchemaVersion
  , PiApplicationContinuationOperations (..)
  , PiApplicationTurnOperations (..)
  , PiApplicationContinuationCodec
  , piApplicationContinuationCodec
  , applicationCodecStore
  , applicationCodecLoad
    -- * Configuration and invocations
  , PiApplicationRuntimeConfig (..)
  , piApplicationRuntimeConfig
  , newPiApplicationRuntimeConfig
  , renderPiApplicationRuntimeConfig
  , PiApplicationRuntimeInvocation (..)
  , newPiApplicationRuntimeInvocation
  , renderPiApplicationRuntimeInvocation
    -- * Connection custody
  , PiApplicationConnectionCustody (..)
  , applicationCustody
    -- * Helper clients
  , ApplicationCandidate (..)
  , ApplicationClient (..)
  , ApplicationClientArgs (..)
  , ApplicationFactory (..)
  , applicationSubprocessFactory
  , ApplicationSubprocessOptions (..)
  , applicationSubprocessOptions
  , ApplicationSubprocessClient
  , newApplicationSubprocessClient
  , newApplicationSubprocessClientWith
  , applicationSubprocessClient
  , piApplicationHelperPath
    -- * Operations
  , PiApplicationOperation
  , applicationOperationId
  , waitApplicationOperation
  , cancelApplicationOperation
  , closeApplicationOperation
  , applicationRuntimeOperation
    -- * The adapter
  , PiApplicationRuntimeAdapter
  , newPiApplicationRuntimeAdapter
  , ApplicationAdapterOptions (..)
  , applicationAdapterOptions
  , newPiApplicationRuntimeAdapterWith
  , applicationAdapterConfig
  , applicationAdapterDescriptor
  , applicationAdapterTerritory
  , applicationAdapterProgram
  , applicationAdapterContinuationDescriptor
  , renderPiApplicationRuntimeAdapter
  , ApplicationProbePaths (..)
  , applicationProbePaths
  , probeApplication
  , startApplication
  ) where

import Petrus.Agenticus.Runtime.PiApplication.Internal
