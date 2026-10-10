-- | Small process-local operation handle shared by Agent Runtime profiles
-- (@petrus.agenticus.runtime.operation@).
module Petrus.Agenticus.Runtime.Operation
  ( -- * Cleanup evidence
    RuntimeCleanupDisposition (..)
  , cleanupDispositionText
  , RuntimeOperationCleanup (operationId, disposition, code, physicalErasureGuaranteed)
  , mkRuntimeOperationCleanup
  , cleanupVerified
    -- * Protocol errors
  , runtimeProtocolError
  , runtimeProtocolErrorCode
    -- * Operations
  , RuntimeOperation (..)
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Shape
import Petrus.Agenticus.Internal.Validate
import Petrus.Agenticus.Runtime.Result
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition)

operationIdentity :: Text -> Either AgenticusError Text
operationIdentity value
  | isBoundedText maxTextBytes value = Right value
  | otherwise = Left (valueError "runtime operation identity must be a bounded non-empty text value")

data RuntimeCleanupDisposition
  = RuntimeCleanupClean
  | RuntimeCleanupNotCreated
  | RuntimeCleanupUnverified
  deriving stock (Eq, Show, Enum, Bounded)

instance StrEnum RuntimeCleanupDisposition where
  enumText = \case
    RuntimeCleanupClean -> "clean"
    RuntimeCleanupNotCreated -> "not-created"
    RuntimeCleanupUnverified -> "unverified"

cleanupDispositionText :: RuntimeCleanupDisposition -> Text
cleanupDispositionText = enumText

-- | Secret-free local/runtime cleanup evidence for one operation handle.
data RuntimeOperationCleanup = RuntimeOperationCleanup
  { operationId :: Text
  , disposition :: RuntimeCleanupDisposition
  , code :: Text
  , physicalErasureGuaranteed :: Bool
  }
  deriving stock (Eq, Show)

-- | @RuntimeOperationCleanup(operation_id, disposition, code,
-- physical_erasure_guaranteed)@.
mkRuntimeOperationCleanup
  :: Text -> RuntimeCleanupDisposition -> Text -> Bool -> Either AgenticusError RuntimeOperationCleanup
mkRuntimeOperationCleanup i d c erased = do
  i' <- operationIdentity i
  c' <- safeTerminationCode c
  pure (RuntimeOperationCleanup i' d c' erased)

-- | @cleanup.verified@: the operation's resources are proven absent.
cleanupVerified :: RuntimeOperationCleanup -> Bool
cleanupVerified c = c.disposition `elem` [RuntimeCleanupClean, RuntimeCleanupNotCreated]

-- | @RuntimeProtocolError(code)@: a safe machine-coded runtime protocol
-- failure without raw provider output, message
-- @"runtime protocol error: {code}"@.  An unsafe code yields the
-- @ValueError@ upstream's constructor raises instead.
runtimeProtocolError :: Text -> AgenticusError
runtimeProtocolError c = case safeTerminationCode c of
  Right code -> agenticusError RuntimeProtocolError ("runtime protocol error: " <> code)
  Left refusal -> refusal

-- | @error.code@ of a 'runtimeProtocolError'.
runtimeProtocolErrorCode :: AgenticusError -> Maybe Text
runtimeProtocolErrorCode e
  | e.errorClass == RuntimeProtocolError = T.stripPrefix "runtime protocol error: " e.errorMessage
  | otherwise = Nothing

-- | Cancellation and cleanup for one already-started profile-specific
-- operation (upstream's structural @RuntimeOperation@ Protocol).
--
-- * 'wait' throws an 'AgenticusError' of class @TimeoutError@ without
--   changing operation state when its bound (seconds; 'Nothing' waits
--   forever) expires; it may then be called again.  After terminal
--   settlement every wait returns the same immutable result.  After 'close',
--   waiting throws @'runtimeProtocolError' "operation-closed"@.
--
-- * 'cancel' is idempotent through the exact 'CancellationDisposition'.
--
-- * 'close' does not imply cancellation: it is legal only after settlement or
--   after cancellation was requested, and otherwise throws
--   @'runtimeProtocolError' "operation-active"@.  Repeated close returns the
--   same immutable cleanup evidence.  Cancellation cleanup that cannot prove
--   absence returns 'RuntimeCleanupUnverified' rather than manufacturing
--   settlement.
data RuntimeOperation = RuntimeOperation
  { operationId :: Text
  , wait :: Maybe Double -> IO RuntimeTurnSettlement
  , cancel :: Text -> IO CancellationDisposition
  , close :: IO RuntimeOperationCleanup
  }
