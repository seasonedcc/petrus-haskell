-- | Petrus-owned composition for one Pi A2 Local host lifecycle
-- (@petrus.agenticus.runtime.pi_a2_host@).
--
-- The host owns Agent Connection custody, the Motus territory, the Episode
-- Attachment and Hands, native Continuation bodies, durable operation
-- recovery, and ordered teardown. The supported product surface is the
-- explicitly scripted runtime-conformance composition
-- ('composePiA2ScriptedRuntime'). Exact external Pi and provider execution
-- through 'composePiA2Runtime' remains experimental and qualification-only.
-- Probe and durable replay run before authority is requested.
--
-- The durable operation ledger is secret-free. Provider output and native Pi
-- session JSONL live in a separate private body store (@bodies.sqlite3@,
-- with the reference's exact @pi_a2_bodies@ table) and become loadable only
-- after aggregate runtime, Attachment, and territory cleanup is verified.
module Petrus.Agenticus.Runtime.PiA2Host
  ( -- * Configuration
    PiA2RuntimeHostConfig (..)
  , piA2RuntimeHostConfig
  , newPiA2RuntimeHostConfig
  , PiA2RuntimePolicy (capabilities, writablePaths, maxToolCalls, writableRoots)
  , mkPiA2RuntimePolicy
  , PiA2RuntimeStart (..)
  , newPiA2RuntimeStart
  , piA2DurableFingerprint
  , PiA2DirectAuthority (connection, keyOperations, supplyApiKey)
  , mkPiA2DirectAuthority
    -- * Scripted conformance
  , PiA2ScriptedCall (method, paramsJson, expectedOk)
  , mkPiA2ScriptedCall
  , PiA2ScriptedTurn (..)
  , piA2ScriptedTurn
  , mkPiA2ScriptedTurn
  , PiA2ScriptedReadiness (..)
  , scriptedSupportLabel
  , scriptedSession
  , piA2ScriptedFactory
    -- * Operations
  , PiA2Operation
  , piA2OperationId
  , piA2RuntimeOperation
  , waitPiA2
  , cancelPiA2
  , closePiA2
    -- * The host
  , PiA2RuntimeHost
  , composePiA2Runtime
  , composePiA2ScriptedRuntime
  , composePiA2RuntimeWith
  , composePiA2ScriptedClientRuntime
  , composePiA2ScriptedClientRuntimeWith
  , PiA2HostHooks (..)
  , noPiA2HostHooks
  , hostDescriptor
  , hostSnapshot
  , hostConfig
  , hostRecoveredSettlements
  , hostAuthorityRequested
  , probeHost
  , scriptedReadiness
  , startHost
  , loadOutput
  , loadWorkspaceArchive
  , acknowledgeHost
  , closeHost
    -- * The body store
  , BodyStore
  , bodyTableSql
  , bodyStorePublish
  , bodyStoreVerified
  , bodyStoreClose
  ) where

import Petrus.Agenticus.Runtime.PiA2Host.Internal
