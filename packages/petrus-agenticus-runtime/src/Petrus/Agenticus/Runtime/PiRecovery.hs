-- | Single-writer durable recovery boundary for native Pi operations
-- (@petrus.agenticus.runtime.pi_recovery@).
--
-- This boundary prevents blind redispatch after a crash; it cannot make an
-- external provider call exactly once. One process must exclusively own a
-- ledger: 'openSqlitePiOperationLedger' takes a nonblocking exclusive
-- @flock@ on @.<name>.writer.lock@ beside the database, and the database
-- carries the reference's exact @pi_operations@ table.
module Petrus.Agenticus.Runtime.PiRecovery
  ( -- * Records
    PiOperationPhase (..)
  , phaseText
  , PiOperationRecord (..)
  , mkPiOperationRecord
  , executingRecord
  , recordSettlement
  , recordCleanupEvidence
    -- * Ledgers
  , PiOperationLedger (..)
  , SqlitePiOperationLedger
  , openSqlitePiOperationLedger
  , sqlitePiOperationLedger
  , ledgerPath
  , ledgerRecover
  , ledgerAdmit
  , ledgerLookup
  , ledgerRecords
  , ledgerSettle
  , ledgerUpgradeCleanup
  , ledgerAcknowledge
  , ledgerWatermark
  , ledgerClose
  , createTableSql
    -- * The recovered runtime
  , PiAdapterSurface (..)
  , piAdapterSurface
  , PiRecoveredOperation
  , recoveredOperation
  , recoveredOperationId
  , PiRecoveredRuntime
  , newPiRecoveredRuntime
  , newPiRecoveredRuntimeWith
  , recoveredSettlements
  , recoveredAdapter
  , startRecovered
  , acknowledgeRecovered
  , evictRecovered
  ) where

import Petrus.Agenticus.Runtime.PiRecovery.Internal
