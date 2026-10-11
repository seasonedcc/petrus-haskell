-- | The exact Amp A1 provider-managed runtime lane
-- (@petrus.agenticus.runtime.amp@).
--
-- Amp owns its agent loop, thread service, tools and Orb placement.
-- Agenticus owns only the Episode/Turn lifecycle candidate, the logical
-- connection fence, the provider-managed attachment, and opaque
-- Continuation and output custody references.
--
-- Upstream's @sdk_execute@ is an async iterator of SDK events; here it is
-- an 'AmpExecute' returning an 'AmpEventStream' of pulls plus the two
-- finalizers upstream calls (@athrow(CancelledError())@ and @aclose()@).
-- The official execute ('officialExecute') hosts the Python SDK in the
-- @amp_sidecar.py@ data file; the probe's monkeypatch points are the
-- fields of 'AmpProbeHooks'.
module Petrus.Agenticus.Runtime.Amp
  ( -- * Pins
    ampSdkVersion
  , ampCliVersion
  , ampSdkSource
  , ampCliSource
    -- * Descriptors
  , ampContinuationDescriptor
  , ampProgram
  , ampProgramCapabilities
  , ampContinuationCapabilities
  , ampConnectionCapabilities
  , ampProviderManagedHands
  , ampProviderManagedTerritory
    -- * Continuations
  , AmpContinuationPayloadV1
  , payloadThreadId
  , payloadSchemaVersion
  , mkAmpContinuationPayloadV1
  , ampPayloadToData
  , ampPayloadFromData
  , AmpContinuationOperations (..)
  , AmpTurnOperations (..)
  , AmpContinuationCodec
  , ampContinuationCodec
  , ampCodecStore
  , ampCodecLoad
    -- * Configuration and invocations
  , AmpRuntimeConfig (..)
  , ampRuntimeConfig
  , newAmpRuntimeConfig
  , AmpRuntimeInvocation (..)
  , newAmpRuntimeInvocation
  , renderAmpRuntimeInvocation
    -- * SDK streams
  , AmpEvent (..)
  , AmpRaise (..)
  , jsonEvent
  , AmpEventStream (..)
  , AmpExecute
  , AmpSidecar (..)
  , SidecarPool
  , newSidecarPool
  , closeSidecarPool
  , withSidecarPool
  , defaultSidecarPool
  , sidecarPoolPids
  , ampSidecar
  , ampSidecarPath
  , officialExecute
    -- * The provider-managed binding
  , AmpProviderManagedBinding
  , newAmpProviderManagedBinding
  , ampAttachmentBinding
  , ampBindingKind
    -- * Operations
  , AmpOperation
  , ampOperationId
  , ampRuntimeOperation
  , waitAmpOperation
  , cancelAmpOperation
  , closeAmpOperation
    -- * The adapter
  , AmpProbeHooks (..)
  , officialProbeHooks
  , resolveAmpCli
  , AmpAdapterOptions (..)
  , ampAdapterOptions
  , AmpRuntimeAdapter
  , newAmpRuntimeAdapter
  , renderAmpRuntimeAdapter
  , probeAmp
  , startAmp
  ) where

import Petrus.Agenticus.Runtime.Amp.Internal
