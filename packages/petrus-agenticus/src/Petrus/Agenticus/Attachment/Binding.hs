-- | Provider-neutral Episode Attachment binding and settlement evidence
-- (@petrus.agenticus.attachment.binding@).
--
-- An 'AttachmentBinding' is the narrow lifecycle one Episode Attachment
-- epoch holds over its execution territory: cancel, export one bounded
-- archive, and settle. The outer coordinates and settlement evidence are
-- provider-neutral, so an honestly provider-managed binding (a host whose
-- provider owns loop, tools and placement) implements the same record with
-- no Motus lease at all; only the capability-scoped Hands path and retained
-- custody require the concrete 'MotusAttachmentBinding'.
--
-- The reference's protocol is structural (any object with the methods);
-- here it is a record of operations, and 'motusBinding' is the one way to
-- build it over an exact Motus lease. The record keeps that 'MotusAttachmentBinding'
-- reachable ('motus') because retained custody needs exactly that binding
-- (@isinstance(binding, MotusAttachmentBinding)@ upstream).
module Petrus.Agenticus.Attachment.Binding
  ( motusBindingKind
    -- * Coordinates
  , AttachmentCoordinates (episodeId, attachmentId, attachmentEpoch)
  , mkAttachmentCoordinates
    -- * Settlement evidence
  , BindingSettlement (bindingKind, disposition, verified, detail)
  , mkBindingSettlement
  , validBindingKind
    -- * The binding protocol
  , AttachmentBinding (..)
    -- * Motus bindings
  , MotusAttachmentBinding
  , motusBinding
  , newMotusAttachmentBinding
  , openMotusBinding
  , reclaimExactMotusBinding
  , bindingProvider
  , bindingLeaseIdentity
  , bindingLease
  , bindingExecution
  , bindingCleanupResult
  , bindingExecute
  , bindingCancel
  , bindingExportArchive
  , bindingSettle
  , bindingRelease
  , bindingQuiesce
  , withBindingOperation
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.Char (isAsciiLower, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Error
import Petrus.Agenticus.Internal.Exception
import Petrus.Agenticus.Internal.Validate (isTrimmed, utf8Length)
import Petrus.Motus.Execution
  ( CleanupResult (..)
  , Command
  , CommandResult
  , EnvironmentLease
  , EnvironmentProvider (..)
  , EnvironmentSpec
  , ExecutionAttachment
  , LeaseIdentity
  , LeaseState (..)
  , attachmentLease
  , cleanupDispositionText
  , cleanupVerified
  , identityOperationId
  , leaseIdentity
  , leaseState
  , provenanceIdentity
  , resultOutputTruncated
  , resultProvenance
  , resultSuperseded
  , resultTimedOut
  )

motusBindingKind :: Text
motusBindingKind = "motus-territory"

maxIdentityBytes, maxDetailBytes :: Int
maxIdentityBytes = 256
maxDetailBytes = 256

identity :: Text -> Text -> Either AgenticusError Text
identity name value
  | T.null value || not (isTrimmed value) || utf8Length value > maxIdentityBytes || T.any (< ' ') value =
      Left (valueError (name <> " must be a bounded non-empty identity string"))
  | otherwise = Right value

-- | @[a-z][a-z0-9-]{0,63}@.
validBindingKind :: Text -> Bool
validBindingKind value = case T.uncons value of
  Just (first, rest) ->
    isAsciiLower first && T.length rest <= 63 && T.all (\c -> isAsciiLower c || isDigit c || c == '-') rest
  Nothing -> False

-- ---------------------------------------------------------------------------
-- Coordinates

-- | The exact current coordinates an Effect fence construction needs:
-- identity only.
data AttachmentCoordinates = AttachmentCoordinates
  { episodeId :: Text
  , attachmentId :: Text
  , attachmentEpoch :: Integer
  }
  deriving stock (Eq, Ord, Show)

mkAttachmentCoordinates :: Text -> Text -> Integer -> Either AgenticusError AttachmentCoordinates
mkAttachmentCoordinates episode attachment epoch = do
  e <- identity "coordinates episode_id" episode
  a <- identity "coordinates attachment_id" attachment
  when (epoch <= 0) $ Left (valueError "coordinates attachment_epoch must be a positive integer")
  Right (AttachmentCoordinates e a epoch)

-- ---------------------------------------------------------------------------
-- Settlement

-- | Independently consumable, fail-closed settlement evidence of one
-- binding. 'verified' is the only gate an Episode Attachment trusts.
data BindingSettlement = BindingSettlement
  { bindingKind :: Text
  , disposition :: Text
  , verified :: Bool
  , detail :: Text
  }
  deriving stock (Eq)

-- | The detail is secret-safe but host-only: it is left out of 'Show' as
-- the reference leaves it out of @repr@.
instance Show BindingSettlement where
  showsPrec d s =
    showParen (d > 10) $
      showString "BindingSettlement {bindingKind = "
        . shows s.bindingKind
        . showString ", disposition = "
        . shows s.disposition
        . showString ", verified = "
        . shows s.verified
        . showString "}"

-- | @BindingSettlement(binding_kind, disposition, verified, detail)@.
mkBindingSettlement :: Text -> Text -> Bool -> Text -> Either AgenticusError BindingSettlement
mkBindingSettlement kind disposition' verified' detail' = do
  unless (validBindingKind kind) $ Left (valueError "binding kind must be a bounded lowercase token")
  unless (validBindingKind disposition') $ Left (valueError "binding kind must be a bounded lowercase token")
  when (utf8Length detail' > maxDetailBytes || T.any (< ' ') detail') $
    Left (valueError "settlement detail must be a bounded string without control characters")
  Right (BindingSettlement kind disposition' verified' detail')

-- ---------------------------------------------------------------------------
-- The protocol

-- | The narrow lifecycle one Episode Attachment epoch holds over territory.
data AttachmentBinding = AttachmentBinding
  { kind :: Text
  , cancel :: Text -> IO ()
  , exportArchive :: IO ByteString
  , settle :: IO BindingSettlement
  , motus :: Maybe MotusAttachmentBinding
  -- ^ The exact Motus binding behind these operations, when there is one.
  }

-- ---------------------------------------------------------------------------
-- Motus

-- | A concrete binding over one exact public Motus territory lease.
data MotusAttachmentBinding = MotusAttachmentBinding
  { provider :: EnvironmentProvider
  , lease :: EnvironmentLease
  , execution :: ExecutionAttachment
  , baseArchive :: ByteString
  , discardOutput :: TVar Bool
  , cleanup :: TVar (Maybe CleanupResult)
  , released :: TVar Bool
  , admissionOpen :: TVar Bool
  , active :: TVar Int
  , depths :: TVar (Map ThreadId Int)
  }

-- | The binding as the provider-neutral protocol.
motusBinding :: MotusAttachmentBinding -> AttachmentBinding
motusBinding b =
  AttachmentBinding
    { kind = motusBindingKind
    , cancel = bindingCancel b
    , exportArchive = bindingExportArchive b
    , settle = bindingSettle b
    , motus = Just b
    }

-- | @MotusAttachmentBinding(provider, lease, execution, base_archive)@.
newMotusAttachmentBinding :: EnvironmentProvider -> EnvironmentLease -> ExecutionAttachment -> ByteString -> IO MotusAttachmentBinding
newMotusAttachmentBinding provider' lease' execution' archive = do
  when (leaseIdentity (attachmentLease execution') /= leaseIdentity lease') $
    throwAgenticus MotusBindingError "execution attachment does not belong to the bound lease"
  MotusAttachmentBinding provider' lease' execution' archive
    <$> newTVarIO False
    <*> newTVarIO Nothing
    <*> newTVarIO False
    <*> newTVarIO True
    <*> newTVarIO 0
    <*> newTVarIO Map.empty

-- | @MotusAttachmentBinding.open@: bind lookup-first — reuse the
-- operation's lease or create it, then attach. A failed attach destroys
-- the claimed lease; the provider's failure text never escapes.
openMotusBinding :: EnvironmentProvider -> Text -> EnvironmentSpec -> ByteString -> Text -> IO MotusAttachmentBinding
openMotusBinding provider' operationId spec archive inputDigest = do
  lease' <- providerLookup provider' operationId >>= maybe (providerCreate provider' operationId spec) pure
  trySync (providerAttach provider' lease' archive inputDigest) >>= \case
    Right execution' -> newMotusAttachmentBinding provider' lease' execution' archive
    Left _ -> do
      cleaned <- trySync (providerDestroy provider' lease')
      case cleaned of
        Right result
          | result.cleanupIdentity == leaseIdentity lease' && cleanupVerified result ->
              throwAgenticus MotusBindingError "Motus attachment failed after verified cleanup"
        _ -> throwAgenticus MotusBindingError "Motus attachment failed and cleanup could not be verified"

-- | @MotusAttachmentBinding._reclaim_exact@: attach only to one exact
-- retained lease; never create a replacement.
reclaimExactMotusBinding :: EnvironmentProvider -> LeaseIdentity -> ByteString -> Text -> IO MotusAttachmentBinding
reclaimExactMotusBinding provider' expected archive inputDigest = do
  lease' <-
    providerLookup provider' (identityOperationId expected)
      >>= maybe (throwAgenticus MotusBindingError "retained Motus lease is absent") pure
  when (leaseIdentity lease' /= expected) $
    throwAgenticus MotusBindingError "retained Motus lease identity conflicts with provider lookup"
  when (leaseState lease' /= Ready) $ throwAgenticus MotusBindingError "retained Motus lease is not ready"
  trySync (providerAttach provider' lease' archive inputDigest) >>= \case
    Right execution' -> newMotusAttachmentBinding provider' lease' execution' archive
    Left _ -> throwAgenticus MotusBindingError "retained Motus lease attachment failed"

ensureOwned :: MotusAttachmentBinding -> IO ()
ensureOwned b = do
  isReleased <- readTVarIO b.released
  when isReleased $ throwAgenticus MotusBindingError "Motus binding authority was released to host custody"

bindingProvider :: MotusAttachmentBinding -> IO EnvironmentProvider
bindingProvider b = ensureOwned b >> pure b.provider

bindingLeaseIdentity :: MotusAttachmentBinding -> LeaseIdentity
bindingLeaseIdentity b = leaseIdentity b.lease

-- | The exact bound lease (the reference reaches it as
-- @binding.execution.lease@).
bindingLease :: MotusAttachmentBinding -> EnvironmentLease
bindingLease b = b.lease

bindingExecution :: MotusAttachmentBinding -> IO ExecutionAttachment
bindingExecution b = ensureOwned b >> pure b.execution

-- | The consumed Motus cleanup evidence, for host inspection only.
bindingCleanupResult :: MotusAttachmentBinding -> IO (Maybe CleanupResult)
bindingCleanupResult b = readTVarIO b.cleanup

-- | Borrow this binding's provider authority until one operation is
-- complete. Re-entrant on the same thread, as the reference's
-- thread-local depth is.
withBindingOperation :: MotusAttachmentBinding -> IO a -> IO a
withBindingOperation b action = do
  me <- myThreadId
  nested <- atomically $ do
    depth <- Map.findWithDefault 0 me <$> readTVar b.depths
    if depth > 0
      then modifyTVar' b.depths (Map.insert me (depth + 1)) >> pure True
      else pure False
  if nested
    then action `finally` atomically (modifyTVar' b.depths (Map.adjust (subtract 1) me))
    else do
      admitted <- atomically $ do
        isReleased <- readTVar b.released
        isOpen <- readTVar b.admissionOpen
        if isReleased
          then pure (Left "Motus binding authority was released to host custody")
          else
            if not isOpen
              then pure (Left "Motus binding operation admission is closed")
              else do
                modifyTVar' b.active (+ 1)
                modifyTVar' b.depths (Map.insert me 1)
                pure (Right ())
      either (throwAgenticus MotusBindingError) pure admitted
      action `finally` atomically (modifyTVar' b.depths (Map.delete me) >> modifyTVar' b.active (subtract 1))

-- | Run one bounded command, provenance-fenced to the exact lease. A timed
-- out, superseded, or truncated command poisons the export: the settled
-- archive is then the base archive.
bindingExecute :: MotusAttachmentBinding -> Command -> IO CommandResult
bindingExecute b command = do
  result <- withBindingOperation b (providerExecute b.provider b.execution command)
  when (provenanceIdentity (resultProvenance result) /= leaseIdentity b.lease) $
    throwAgenticus MotusBindingError "command result provenance does not match the bound lease"
  when (resultTimedOut result || resultSuperseded result || resultOutputTruncated result) $
    atomically (writeTVar b.discardOutput True)
  pure result

bindingCancel :: MotusAttachmentBinding -> Text -> IO ()
bindingCancel b reason = do
  ensureOwned b
  atomically (writeTVar b.discardOutput True)
  providerCancel b.provider b.lease reason

bindingExportArchive :: MotusAttachmentBinding -> IO ByteString
bindingExportArchive b = do
  ensureOwned b
  discard <- readTVarIO b.discardOutput
  if discard then pure b.baseArchive else providerExport b.provider b.execution

-- | Destroy the exact lease and consume its fail-closed cleanup evidence.
bindingSettle :: MotusAttachmentBinding -> IO BindingSettlement
bindingSettle b = do
  ensureOwned b
  result <- providerDestroy b.provider b.lease
  if result.cleanupIdentity /= leaseIdentity b.lease
    then
      throwLeft $
        mkBindingSettlement motusBindingKind "unverified" False "cleanup evidence names a different lease identity"
    else do
      atomically (writeTVar b.cleanup (Just result))
      throwLeft $
        mkBindingSettlement
          motusBindingKind
          (cleanupDispositionText result.cleanupDisposition)
          (cleanupVerified result)
          "provider cleanup evidence consumed"

-- | @_release@: irrevocably close this binding before host custody accepts
-- its lease. Requires quiesced operation admission.
bindingRelease :: MotusAttachmentBinding -> (EnvironmentLease -> IO ()) -> IO LeaseIdentity
bindingRelease b accept = do
  outcome <- atomically $ do
    isReleased <- readTVar b.released
    isOpen <- readTVar b.admissionOpen
    count <- readTVar b.active
    if isReleased
      then pure (Left "Motus binding authority was released to host custody")
      else
        if isOpen || count /= 0
          then pure (Left "Motus binding release requires quiesced operation admission")
          else writeTVar b.released True >> pure (Right ())
  either (throwAgenticus MotusBindingError) pure outcome
  accept b.lease
  pure (leaseIdentity b.lease)

-- | @_quiesce(timeout)@: close operation admission and wait for every
-- borrowed provider operation; 'False' when the timeout elapses first.
bindingQuiesce :: MotusAttachmentBinding -> Double -> IO Bool
bindingQuiesce b timeout = do
  when (isNaN timeout || timeout < 0) $
    throwAgenticus ValueError "Motus binding quiescence timeout must be non-negative"
  ensureOwned b
  atomically (writeTVar b.admissionOpen False)
  expired <- registerDelay (fromInteger (min (toInteger (maxBound :: Int)) (ceiling (timeout * 1e6))))
  atomically $ do
    count <- readTVar b.active
    if count == 0
      then pure True
      else readTVar expired >>= \case
        True -> pure False
        False -> retry
