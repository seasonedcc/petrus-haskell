{-# LANGUAGE RecordWildCards #-}

-- | Production Agent Connection authority, custody, and stale-writer fencing
-- (@petrus.agenticus.connection.custody@).
--
-- Every operation is a pure transform of the current 'StorageSnapshot'
-- (@StorageSnapshot -> Either AgenticusError (Change a)@, with the host clock
-- read once per attempt where the reference reads it) published through one
-- bounded compare-and-swap loop that appends exactly one secret-free
-- 'AuditRecord'.  Operation identities are idempotency keys: a reused one is
-- refused with @OperationConflict@ and reconciled through 'lookupOperation'.
module Petrus.Agenticus.Connection.Custody
  ( -- * Enumerations
    LeaseMode (..)
  , leaseModeText
  , parseLeaseMode
  , ConnectionStatus (..)
  , connectionStatusText
  , parseConnectionStatus
    -- * Opaque provider state
  , OpaqueState
  , newOpaqueState
  , opaqueStateFromBuffer
  , opaqueStateErased
  , eraseOpaqueState
  , renderOpaqueState
    -- * Values
  , ConnectionIdentity (connectionId, provider, accountFingerprint, profile)
  , mkConnectionIdentity
  , ConnectionView (..)
  , AttachmentFence (..)
  , Materialization (..)
  , OperationView (..)
  , PublicationResult (..)
  , ReleaseResult (..)
  , RenewalResult (..)
  , HostRemoval (..)
  , RevocationResult (..)
  , ErasureResult (..)
  , RecoveryResult (..)
  , AdmissionResult (..)
    -- * Custody
  , AgentConnectionCustody
  , agentConnectionCustody
  , withCustodyLogger
  , enrollHost
  , removeHost
  , authorize
  , materialize
  , activate
  , renew
  , checkpoint
  , release
  , rotate
  , revoke
  , erase
  , admitResult
  , admitEffect
  , lookupConnection
  , recover
  , lookupOperation
  , auditRecords
  , closeCustody
    -- * Pieces shared with restart recovery and tests
  , fenceOf
  , derivedIdentity
  , casAttempts
  ) where

import Prelude hiding (sequence)

import Control.Exception (SomeException, evaluate, finally, onException, throwIO, try)
import Control.Monad (foldM, unless, when)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Agenticus.Connection.Key
import Petrus.Agenticus.Connection.Materialization
  ( CleanupEvidence
  , CleanupSummary
  , MaterializedState
  , PrivateFileMaterializer
  , materializeState
  , readMaterializedScrubbed
  )
import Petrus.Agenticus.Connection.Materialization qualified as Files
import Petrus.Agenticus.Connection.Storage
import Petrus.Agenticus.Error
import Petrus.Json.Python (pythonStrRepr)
import Petrus.Agenticus.Internal.Validate (checkedText, maxTextBytes, sha256Hex)

-- ---------------------------------------------------------------------------
-- Enumerations

data LeaseMode = LeaseRead | LeaseRefresh
  deriving stock (Eq, Ord, Show, Enum, Bounded)

leaseModeText :: LeaseMode -> Text
leaseModeText = \case
  LeaseRead -> "read"
  LeaseRefresh -> "refresh"

parseLeaseMode :: Text -> Maybe LeaseMode
parseLeaseMode text = find ((== text) . leaseModeText) [minBound .. maxBound]

data ConnectionStatus
  = StatusReady
  | StatusRefreshing
  | StatusRevoked
  | StatusErasurePending
  | StatusReauthorizationRequired
  deriving stock (Eq, Ord, Show, Enum, Bounded)

connectionStatusText :: ConnectionStatus -> Text
connectionStatusText = \case
  StatusReady -> "ready"
  StatusRefreshing -> "refreshing"
  StatusRevoked -> "revoked"
  StatusErasurePending -> "erasure_pending"
  StatusReauthorizationRequired -> "reauthorization_required"

parseConnectionStatus :: Text -> Maybe ConnectionStatus
parseConnectionStatus text = find ((== text) . connectionStatusText) [minBound .. maxBound]

-- ---------------------------------------------------------------------------
-- Opaque state

-- | An erasable provider-native state buffer whose 'Show' is redacted.
data OpaqueState = OpaqueState
  { content :: ScrubbedBytes
  , erasedFlag :: IORef Bool
  }

instance Show OpaqueState where
  show _ = "OpaqueState(<redacted>)"

-- | @OpaqueState(content)@: copy non-empty bytes into an erasable buffer.
newOpaqueState :: ByteString -> IO OpaqueState
newOpaqueState bytes = opaqueStateFromBuffer (BA.convert bytes)

-- | Take ownership of an erasable buffer.
opaqueStateFromBuffer :: ScrubbedBytes -> IO OpaqueState
opaqueStateFromBuffer buffer = do
  when (BA.null buffer) $ throwIO (valueError "opaque Agent Connection state must be non-empty bytes")
  OpaqueState buffer <$> newIORef False

opaqueStateErased :: OpaqueState -> IO Bool
opaqueStateErased state = readIORef state.erasedFlag

eraseOpaqueState :: OpaqueState -> IO ()
eraseOpaqueState state = do
  eraseBuffer state.content
  writeIORef state.erasedFlag True

-- | Upstream's @repr@: @OpaqueState(<present>)@ or @OpaqueState(<erased>)@.
renderOpaqueState :: OpaqueState -> IO Text
renderOpaqueState state = do
  erased <- opaqueStateErased state
  pure ("OpaqueState(<" <> (if erased then "erased" else "present") <> ">)")

borrow :: OpaqueState -> IO ScrubbedBytes
borrow state = do
  erased <- opaqueStateErased state
  when erased $ throwAgenticus CustodyError "opaque Agent Connection state has been erased"
  pure state.content

-- ---------------------------------------------------------------------------
-- Values

-- | Stable logical connection identity and nonsecret provider metadata.
data ConnectionIdentity = ConnectionIdentity
  { connectionId :: Text
  , provider :: Text
  , accountFingerprint :: Text
  , profile :: Text
  }
  deriving stock (Eq, Ord, Show)

mkConnectionIdentity :: Text -> Text -> Text -> Text -> Either AgenticusError ConnectionIdentity
mkConnectionIdentity connectionId provider accountFingerprint profile = do
  identityText connectionId "connection"
  identityText provider "provider"
  identityText accountFingerprint "account fingerprint"
  identityText profile "profile"
  pure ConnectionIdentity {..}

data ConnectionView = ConnectionView
  { identity :: ConnectionIdentity
  , status :: ConnectionStatus
  , authorityEpoch :: Integer
  , stateVersion :: Integer
  , stateDigest :: Maybe Text
  }
  deriving stock (Eq, Show)

data AttachmentFence = AttachmentFence
  { attachmentId :: Text
  , leaseId :: Text
  , connectionId :: Text
  , hostId :: Text
  , hostEpoch :: Integer
  , authorityEpoch :: Integer
  , baseVersion :: Integer
  }
  deriving stock (Eq, Ord, Show)

data Materialization = Materialization
  { fence :: AttachmentFence
  , mode :: LeaseMode
  , expiresAt :: Double
  , home :: MaterializedState
  }

-- | Upstream's @repr@, which names the attachment but never the path.
instance Show Materialization where
  show materialization =
    T.unpack $
      "Materialization(attachment_id="
        <> pythonStrRepr materialization.fence.attachmentId
        <> ", connection_id="
        <> pythonStrRepr materialization.fence.connectionId
        <> ", host_id="
        <> pythonStrRepr materialization.fence.hostId
        <> ", mode="
        <> pythonStrRepr (leaseModeText materialization.mode)
        <> ", home="
        <> T.pack (show materialization.home)
        <> ")"

data OperationView = OperationView
  { operationId :: Text
  , eventKind :: Text
  , connectionId :: Maybe Text
  , hostId :: Maybe Text
  , leaseId :: Maybe Text
  , details :: AuditDetails
  }
  deriving stock (Eq, Show)

data PublicationResult = PublicationResult
  { operationId :: Text
  , connection :: ConnectionView
  , cleanup :: CleanupEvidence
  }
  deriving stock (Eq, Show)

data ReleaseResult = ReleaseResult
  { operationId :: Text
  , cleanup :: CleanupEvidence
  }
  deriving stock (Eq, Show)

data RenewalResult = RenewalResult
  { operationId :: Text
  , expiresAt :: Double
  }
  deriving stock (Eq, Show)

data HostRemoval = HostRemoval
  { operationId :: Text
  , hostId :: Text
  , canceledLeases :: Int
  , cleanup :: CleanupSummary
  , offlineErasureLimit :: Bool
  }
  deriving stock (Eq, Show)

data RevocationResult = RevocationResult
  { operationId :: Text
  , connection :: ConnectionView
  , cleanup :: CleanupSummary
  , providerRevocation :: Text
  , offlineErasureLimit :: Bool
  }
  deriving stock (Eq, Show)

data ErasureResult = ErasureResult
  { operationId :: Text
  , connection :: ConnectionView
  , keyErasure :: KeyErasureEvidence
  , cleanup :: CleanupSummary
  , physicalMediaErasureGuaranteed :: Bool
  }
  deriving stock (Eq, Show)

data RecoveryResult = RecoveryResult
  { operationId :: Text
  , expiredLeases :: Int
  , ambiguousConnections :: [Text]
  , cleanup :: CleanupSummary
  }
  deriving stock (Eq, Show)

data AdmissionResult = AdmissionResult
  { operationId :: Text
  , purpose :: Text
  , attachmentId :: Text
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Custody

-- | Installation-neutral custody machinery over host storage, keys, and
-- files.
data AgentConnectionCustody = AgentConnectionCustody
  { storage :: ConnectionStorage
  , keys :: KeyOperations
  , materializer :: PrivateFileMaterializer
  , clock :: IO Double
  , logger :: Text -> IO ()
  }

-- | @AgentConnectionCustody(storage, keys, materializer, clock=clock)@; the
-- operation log is discarded until 'withCustodyLogger' installs a sink.
agentConnectionCustody :: ConnectionStorage -> KeyOperations -> PrivateFileMaterializer -> IO Double -> AgentConnectionCustody
agentConnectionCustody storage keys materializer clock =
  AgentConnectionCustody {storage, keys, materializer, clock, logger = \_ -> pure ()}

-- | Route the INFO line upstream sends to the
-- @petrus.agenticus.connection.custody@ logger
-- (@"%s operation=%s connection=%s host=%s lease=%s"@).
withCustodyLogger :: (Text -> IO ()) -> AgentConnectionCustody -> AgentConnectionCustody
withCustodyLogger sink AgentConnectionCustody {..} = AgentConnectionCustody {logger = sink, ..}

-- | The bounded number of compare-and-swap attempts per operation.
casAttempts :: Int
casAttempts = 8

enrollHost :: AgentConnectionCustody -> Text -> Text -> IO ()
enrollHost custody hostId operationId = do
  throwLeft (identityText hostId "host")
  _ <- commit custody operationId "host.enrolled" noSubjects {hostIdOf = Just hostId} $
    withNow custody $ \now snapshot -> do
      (reconciled, expiredIds, ambiguous) <- reconcileExpired snapshot now
      let hosts = hostsMap reconciled
          epoch = maybe 1 (\current -> current.enrollmentEpoch + 1) (Map.lookup hostId hosts)
          affected = activeLeases reconciled now (\lease -> lease.hostId == hostId)
          replaced = replaceHosts reconciled (Map.insert hostId (StoredHost hostId epoch True) hosts)
      (updated, newlyAmbiguous) <- settleReleasedRefreshes (releaseLeases replaced affected "host_reenrolled") affected
      pure
        Change
          { snapshot = updated
          , value = ()
          , details =
              [ ("enrollment_epoch", AuditInt epoch)
              , ("canceled_leases", count affected)
              , ("expired_leases", count expiredIds)
              , ("ambiguous_connections", count (Set.toList (Set.fromList (ambiguous <> newlyAmbiguous))))
              ]
          , cleanupIds = expiredIds <> map (.attachmentId) affected
          }
  pure ()

removeHost :: AgentConnectionCustody -> Text -> Text -> IO HostRemoval
removeHost custody hostId operationId = do
  throwLeft (identityText hostId "host")
  (canceledLeases, cleanup) <- commit custody operationId "host.removed" noSubjects {hostIdOf = Just hostId} $
    withNow custody $ \now snapshot -> do
      (reconciled, expiredIds, _) <- reconcileExpired snapshot now
      host <- activeHost reconciled hostId
      let retired = StoredHost {hostId, enrollmentEpoch = host.enrollmentEpoch + 1, active = False}
          affected = activeLeases reconciled now (\lease -> lease.hostId == hostId)
          replaced = replaceHosts reconciled (Map.insert hostId retired (hostsMap reconciled))
      (updated, ambiguous) <- settleReleasedRefreshes (releaseLeases replaced affected "host_removed") affected
      pure
        Change
          { snapshot = updated
          , value = length affected
          , details =
              [ ("canceled_leases", count affected)
              , ("ambiguous_connections", count ambiguous)
              , ("offline_erasure_limit", AuditBool True)
              ]
          , cleanupIds = expiredIds <> map (.attachmentId) affected
          }
  pure HostRemoval {operationId, hostId, canceledLeases, cleanup, offlineErasureLimit = True}

authorize :: AgentConnectionCustody -> ConnectionIdentity -> OpaqueState -> Text -> IO ConnectionView
authorize custody identity opaqueState operationId = do
  throwLeft (operationIdentity operationId)
  initial <- loadValidated custody
  let connectionId = identity.connectionId
      current = Map.lookup connectionId (connectionsMap initial)
  (authorityEpoch, stateVersion, eventKind) <- case current of
    Nothing -> pure (1, 1, "connection.authorized")
    Just stored -> do
      when (stored.status /= "reauthorization_required") $ do
        eraseOpaqueState opaqueState
        throwAgenticus CustodyError ("connection " <> pythonStrRepr connectionId <> " is already authorized")
      unless (identityMatches stored identity) $ do
        eraseOpaqueState opaqueState
        throwAgenticus
          CustodyError
          ("connection " <> pythonStrRepr connectionId <> " cannot be rebound to different provider authority")
      pure (stored.authorityEpoch + 1, stored.stateVersion + 1, "connection.reauthorized")
  encrypted <- seal custody connectionId authorityEpoch stateVersion opaqueState
  fst <$> commit custody operationId eventKind noSubjects {connectionIdOf = Just connectionId} (pureTransform (change connectionId current authorityEpoch stateVersion encrypted))
  where
    change connectionId current authorityEpoch stateVersion encrypted snapshot = do
      unless (sameConnectionGeneration (Map.lookup connectionId (connectionsMap snapshot)) current) $
        Left (AgenticusError StorageContention ("connection " <> pythonStrRepr connectionId <> " changed during authorization"))
      let stored =
            StoredConnection
              { connectionId
              , provider = identity.provider
              , accountFingerprint = identity.accountFingerprint
              , profile = identity.profile
              , status = "ready"
              , authorityEpoch
              , stateVersion
              , encryptedState = Just encrypted
              , stateDigest = Just (sha256Hex encrypted)
              }
      view <- viewOf stored
      pure
        Change
          { snapshot = replaceConnection snapshot stored
          , value = view
          , details = [("authority_epoch", AuditInt authorityEpoch), ("state_version", AuditInt stateVersion)]
          , cleanupIds = []
          }

materialize :: AgentConnectionCustody -> Text -> Text -> LeaseMode -> Double -> Text -> IO Materialization
materialize custody connectionId hostId mode ttl operationId = do
  throwLeft (identityText connectionId "connection")
  throwLeft (identityText hostId "host")
  throwLeft (positiveTtl ttl)
  throwLeft (operationIdentity operationId)
  let leaseId = derivedIdentity "lease-" operationId
      attachmentId = derivedIdentity "attachment-" operationId
  now <- currentTime custody
  expiresAt <- throwLeft (finiteTime (now + ttl) "materialization lease expiry")
  reconcileExpiredBefore custody operationId now
  ((connection, lease), _) <-
    commit
      custody
      operationId
      "materialization.acquired"
      Subjects {connectionIdOf = Just connectionId, hostIdOf = Just hostId, leaseIdOf = Just leaseId}
      $ pureTransform
      $ \snapshot -> do
        (reconciled, expiredIds, ambiguous) <- reconcileExpired snapshot now
        host <- activeHost reconciled hostId
        connection <- connectionOf reconciled connectionId
        requireMaterializable connection
        let active = activeLeases reconciled now (\lease -> lease.connectionId == connectionId)
        when (mode == LeaseRefresh && not (null active)) $
          Left
            ( AgenticusError
                LeaseConflict
                ("connection " <> pythonStrRepr connectionId <> " cannot grant refresh custody while materializations are active")
            )
        let lease =
              StoredLease
                { leaseId
                , attachmentId
                , connectionId
                , hostId
                , hostEpoch = host.enrollmentEpoch
                , mode = leaseModeText mode
                , authorityEpoch = connection.authorityEpoch
                , baseVersion = connection.stateVersion
                , expiresAt
                , activated = False
                , released = False
                , releaseReason = Nothing
                }
            withLease = replaceLeases reconciled (Map.insert leaseId lease (leasesMap reconciled))
            updated
              | mode == LeaseRefresh = replaceConnection withLease (withStatus "refreshing" connection)
              | otherwise = withLease
        pure
          Change
            { snapshot = updated
            , value = (connection, lease)
            , details =
                [ ("mode", AuditStr (leaseModeText mode))
                , ("authority_epoch", AuditInt connection.authorityEpoch)
                , ("base_version", AuditInt connection.stateVersion)
                , ("expired_leases", count expiredIds)
                , ("ambiguous_connections", count ambiguous)
                ]
            , cleanupIds = expiredIds
            }
  encrypted <- case connection.encryptedState of
    Nothing -> do
      abortMaterialization custody lease operationId
      throwAgenticus ReauthorizationRequired ("connection " <> pythonStrRepr connectionId <> " requires explicit reauthorization")
    Just encrypted -> pure encrypted
  home <-
    ( do
        context <- throwLeft (mkKeyContext connectionId connection.authorityEpoch connection.stateVersion)
        plaintext <- custody.keys.open context encrypted >>= evaluate
        materializeState custody.materializer attachmentId plaintext `finally` eraseBuffer plaintext
    )
      `onException` abortMaterialization custody lease operationId
  pure Materialization {fence = fenceOf lease, mode, expiresAt, home}

activate :: AgentConnectionCustody -> Materialization -> Text -> IO ()
activate custody materialization operationId = do
  when (materialization.mode /= LeaseRefresh) $
    throwAgenticus CustodyError "only refresh custody can enter provider-mutation state"
  let fence = materialization.fence
  _ <- commit custody operationId "materialization.activated" (fenceSubjects fence) $
    withNow custody $ \now snapshot -> do
      lease <- requireCurrentLease snapshot fence now LeaseRefresh
      pure
        Change
          { snapshot = replaceLeases snapshot (Map.insert lease.leaseId (markActivated lease) (leasesMap snapshot))
          , value = ()
          , details = [("authority_epoch", AuditInt fence.authorityEpoch)]
          , cleanupIds = []
          }
  pure ()

renew :: AgentConnectionCustody -> Materialization -> Double -> Text -> IO RenewalResult
renew custody materialization ttl operationId = do
  throwLeft (positiveTtl ttl)
  let fence = materialization.fence
  (expiresAt, _) <- commit custody operationId "materialization.renewed" (fenceSubjects fence) $
    withNow custody $ \now snapshot -> do
      expiresAt <- finiteTime (now + ttl) "materialization lease expiry"
      _ <- activeHost snapshot fence.hostId
      lease <- requireCurrentLease snapshot fence now materialization.mode
      pure
        Change
          { snapshot = replaceLeases snapshot (Map.insert lease.leaseId (withExpiry expiresAt lease) (leasesMap snapshot))
          , value = expiresAt
          , details = [("expires_at", AuditFloat expiresAt)]
          , cleanupIds = []
          }
  pure RenewalResult {operationId, expiresAt}

checkpoint :: AgentConnectionCustody -> Materialization -> Text -> IO PublicationResult
checkpoint custody materialization operationId = do
  throwLeft (operationIdentity operationId)
  let fence = materialization.fence
  ( do
      initial <- loadValidated custody
      now <- currentTime custody
      initialLease <- throwLeft (requireCurrentLease initial fence now LeaseRefresh)
      unless initialLease.activated $
        throwAgenticus CustodyError "refresh custody must be activated before publishing provider state"
      returned <- readMaterializedScrubbed materialization.home
      when (BA.null returned) $ throwAgenticus CustodyError "provider returned empty opaque state"
      let nextVersion = fence.baseVersion + 1
      encrypted <- sealBuffer custody fence.connectionId fence.authorityEpoch nextVersion returned
      (connection, _) <- commit custody operationId "materialization.checkpointed" (fenceSubjects fence) $
        withNow custody $ \current snapshot -> do
          lease <- requireCurrentLease snapshot fence current LeaseRefresh
          stored <- connectionOf snapshot fence.connectionId
          when
            ( not lease.activated
                || stored.authorityEpoch /= fence.authorityEpoch
                || stored.stateVersion /= fence.baseVersion
                || stored.status /= "refreshing"
            )
            $ Left (staleCustody fence)
          let accepted = acceptState nextVersion encrypted stored
              leases = Map.insert lease.leaseId (releasedWith "checkpointed" lease) (leasesMap snapshot)
          view <- viewOf accepted
          pure
            Change
              { snapshot = replaceConnection (replaceLeases snapshot leases) accepted
              , value = view
              , details = [("base_version", AuditInt fence.baseVersion), ("accepted_version", AuditInt nextVersion)]
              , cleanupIds = []
              }
      cleanup <- Files.cleanup custody.materializer fence.attachmentId
      pure PublicationResult {operationId, connection, cleanup}
    )
    `finally` Files.cleanup custody.materializer fence.attachmentId

release :: AgentConnectionCustody -> Materialization -> Text -> IO ReleaseResult
release custody materialization operationId = do
  let fence = materialization.fence
      modeText = leaseModeText materialization.mode
  outcome <- try $ commit custody operationId "materialization.released" (fenceSubjects fence) $
    withNow custody $ \now snapshot -> do
      (reconciled, expiredIds, _) <- reconcileExpired snapshot now
      lease <- case Map.lookup fence.leaseId (leasesMap reconciled) of
        Just lease | leaseMatches lease fence && lease.mode == modeText -> Right lease
        _ -> Left (staleCustody fence)
      if lease.released
        then
          pure
            Change
              { snapshot = reconciled
              , value = ()
              , details = [("already_settled", AuditBool True), ("mode", AuditStr modeText)]
              , cleanupIds = expiredIds
              }
        else do
          _ <- requireCurrentLease reconciled fence now materialization.mode
          (updated, ambiguous) <- settleReleasedRefreshes (releaseLeases reconciled [lease] "released") [lease]
          pure
            Change
              { snapshot = updated
              , value = ()
              , details = [("mode", AuditStr modeText), ("ambiguous_refresh", AuditBool (not (null ambiguous)))]
              , cleanupIds = expiredIds
              }
  cleanup <- Files.cleanup custody.materializer fence.attachmentId
  case outcome of
    Left (failure :: SomeException) -> throwIO failure
    Right _ -> pure ReleaseResult {operationId, cleanup}

rotate :: AgentConnectionCustody -> Text -> OpaqueState -> Text -> IO ConnectionView
rotate custody connectionId opaqueState operationId =
  replaceAuthority custody connectionId opaqueState operationId "connection.rotated"

revoke :: AgentConnectionCustody -> Text -> Text -> IO RevocationResult
revoke custody connectionId operationId = do
  throwLeft (identityText connectionId "connection")
  (connection, cleanup) <- commit custody operationId "connection.revoked" noSubjects {connectionIdOf = Just connectionId} $
    pureTransform $ \snapshot -> do
      stored <- connectionOf snapshot connectionId
      when (stored.status `elem` ["revoked", "erasure_pending"]) $ Left (reauthorizationRequired connectionId)
      let unsettled = unsettledLeases snapshot connectionId
          revoked = withEpoch (stored.authorityEpoch + 1) (withStatus "revoked" stored)
      view <- viewOf revoked
      pure
        Change
          { snapshot = replaceConnection (releaseLeases snapshot unsettled "connection_revoked") revoked
          , value = view
          , details =
              [ ("authority_epoch", AuditInt (stored.authorityEpoch + 1))
              , ("canceled_leases", count unsettled)
              , ("provider_revocation", AuditStr "not_claimed")
              , ("offline_erasure_limit", AuditBool True)
              ]
          , cleanupIds = map (.attachmentId) unsettled
          }
  pure
    RevocationResult {operationId, connection, cleanup, providerRevocation = "not_claimed", offlineErasureLimit = True}

erase :: AgentConnectionCustody -> Text -> Text -> IO ErasureResult
erase custody connectionId operationId = do
  throwLeft (identityText connectionId "connection")
  throwLeft (operationIdentity operationId)
  let pendingOperation = derivedIdentity "prepare-" operationId
      subjects = noSubjects {connectionIdOf = Just connectionId}
  current <- loadValidated custody >>= \snapshot -> throwLeft (connectionOf snapshot connectionId)
  if current.status == "revoked"
    then do
      _ <- commit custody pendingOperation "connection.erasure_started" subjects $
        pureTransform $ \snapshot -> do
          stored <- connectionOf snapshot connectionId
          when (stored.status /= "revoked") $
            Left (AgenticusError CustodyError ("connection " <> pythonStrRepr connectionId <> " is not revoked"))
          pure
            Change
              { snapshot = replaceConnection snapshot (withStatus "erasure_pending" stored)
              , value = ()
              , details = [("state_version", AuditInt stored.stateVersion)]
              , cleanupIds = []
              }
      pure ()
    else
      when (current.status /= "erasure_pending") $
        throwAgenticus CustodyError ("connection " <> pythonStrRepr connectionId <> " must be revoked before erasure")
  keyErasure <- custody.keys.erase connectionId
  (connection, cleanup) <- commit custody operationId "connection.erased" subjects $
    pureTransform $ \snapshot -> do
      stored <- connectionOf snapshot connectionId
      when (stored.status /= "erasure_pending") $
        Left (AgenticusError CustodyError ("connection " <> pythonStrRepr connectionId <> " is not awaiting erasure"))
      let active = unsettledLeases snapshot connectionId
          erased = eraseState (withStatus "reauthorization_required" stored)
      view <- viewOf erased
      pure
        Change
          { snapshot = replaceConnection (releaseLeases snapshot active "connection_erased") erased
          , value = view
          , details =
              [ ("state_version", AuditInt (stored.stateVersion + 1))
              , ("key_erased", AuditBool keyErasure.erased)
              , ("physical_media_erasure_guaranteed", AuditBool False)
              ]
          , cleanupIds = map (.attachmentId) active
          }
  pure ErasureResult {operationId, connection, keyErasure, cleanup, physicalMediaErasureGuaranteed = False}

-- | Admit a runtime result for a still-current attachment.
admitResult :: AgentConnectionCustody -> AttachmentFence -> Text -> IO AdmissionResult
admitResult custody fence operationId = admit custody fence operationId "result"

-- | Admit an external effect for a still-current attachment.
admitEffect :: AgentConnectionCustody -> AttachmentFence -> Text -> IO AdmissionResult
admitEffect custody fence operationId = admit custody fence operationId "effect"

-- | @custody.connection(connection_id)@.
lookupConnection :: AgentConnectionCustody -> Text -> IO ConnectionView
lookupConnection custody connectionId = do
  throwLeft (identityText connectionId "connection")
  snapshot <- loadValidated custody
  throwLeft (connectionOf snapshot connectionId >>= viewOf)

recover :: AgentConnectionCustody -> Text -> IO RecoveryResult
recover custody operationId = do
  ((expiredLeases, ambiguousConnections), cleanup) <- commit custody operationId "installation.recovered" noSubjects $
    withNow custody $ \now snapshot -> do
      (updated, expiredIds, ambiguous) <- reconcileExpired snapshot now
      pure
        Change
          { snapshot = updated
          , value = (length expiredIds, ambiguous)
          , details = [("expired_leases", count expiredIds), ("ambiguous_connections", count ambiguous)]
          , cleanupIds = [lease.attachmentId | lease <- updated.leases, lease.released]
          }
  pure RecoveryResult {operationId, expiredLeases, ambiguousConnections, cleanup}

lookupOperation :: AgentConnectionCustody -> Text -> IO (Maybe OperationView)
lookupOperation custody operationId = do
  throwLeft (operationIdentity operationId)
  snapshot <- loadValidated custody
  pure (operationView <$> find (\record -> record.operationId == operationId) snapshot.audit)

auditRecords :: AgentConnectionCustody -> IO [AuditRecord]
auditRecords custody = (.audit) <$> loadValidated custody

-- | Close storage only; live views intentionally survive to model a process
-- crash.
closeCustody :: AgentConnectionCustody -> IO ()
closeCustody custody = custody.storage.close

-- ---------------------------------------------------------------------------
-- Operations shared by several entry points

admit :: AgentConnectionCustody -> AttachmentFence -> Text -> Text -> IO AdmissionResult
admit custody fence operationId purpose =
  fmap fst $ commit custody operationId ("attachment." <> purpose <> ".admitted") (fenceSubjects fence) $
    withNow custody $ \now snapshot -> do
      unless (attachmentIsCurrent snapshot fence now) $
        Left
          (AgenticusError StaleAttachment (purpose <> " rejected: attachment " <> pythonStrRepr fence.attachmentId <> " is stale"))
      pure
        Change
          { snapshot
          , value = AdmissionResult {operationId, purpose, attachmentId = fence.attachmentId}
          , details = [("authority_epoch", AuditInt fence.authorityEpoch)]
          , cleanupIds = []
          }

replaceAuthority :: AgentConnectionCustody -> Text -> OpaqueState -> Text -> Text -> IO ConnectionView
replaceAuthority custody connectionId opaqueState operationId eventKind = do
  throwLeft (identityText connectionId "connection")
  initial <- loadValidated custody
  current <- throwLeft (connectionOf initial connectionId)
  when (current.status `notElem` ["ready", "refreshing"]) $ do
    eraseOpaqueState opaqueState
    throwLeft (Left (reauthorizationRequired connectionId))
  let authorityEpoch = current.authorityEpoch + 1
      stateVersion = current.stateVersion + 1
  encrypted <- seal custody connectionId authorityEpoch stateVersion opaqueState
  fmap fst $ commit custody operationId eventKind noSubjects {connectionIdOf = Just connectionId} $
    pureTransform $ \snapshot -> do
      stored <- connectionOf snapshot connectionId
      unless (sameConnectionGeneration (Just stored) (Just current)) $
        Left (AgenticusError StaleCustody ("connection " <> pythonStrRepr connectionId <> " changed during rotation"))
      let unsettled = unsettledLeases snapshot connectionId
          rotated = withEpoch authorityEpoch (withStatus "ready" (acceptState stateVersion encrypted stored))
      view <- viewOf rotated
      pure
        Change
          { snapshot = replaceConnection (releaseLeases snapshot unsettled "authority_rotated") rotated
          , value = view
          , details =
              [ ("authority_epoch", AuditInt authorityEpoch)
              , ("state_version", AuditInt stateVersion)
              , ("canceled_leases", count unsettled)
              ]
          , cleanupIds = map (.attachmentId) unsettled
          }

reconcileExpiredBefore :: AgentConnectionCustody -> Text -> Double -> IO ()
reconcileExpiredBefore custody parentOperationId now = do
  snapshot <- loadValidated custody
  when (any (\lease -> not lease.released && lease.expiresAt <= now) snapshot.leases) $ do
    _ <- commit custody (derivedIdentity "reconcile-" parentOperationId) "materialization.reconciled" noSubjects $
      pureTransform $ \current -> do
        (updated, expiredIds, ambiguous) <- reconcileExpired current now
        pure
          Change
            { snapshot = updated
            , value = ()
            , details = [("expired_leases", count expiredIds), ("ambiguous_connections", count ambiguous)]
            , cleanupIds = expiredIds
            }
    pure ()

abortMaterialization :: AgentConnectionCustody -> StoredLease -> Text -> IO ()
abortMaterialization custody lease parentOperationId = do
  _ <-
    commit
      custody
      (derivedIdentity "abort-" parentOperationId)
      "materialization.failed"
      Subjects {connectionIdOf = Just lease.connectionId, hostIdOf = Just lease.hostId, leaseIdOf = Just lease.leaseId}
      $ pureTransform
      $ \snapshot -> case Map.lookup lease.leaseId (leasesMap snapshot) of
        Just current | not current.released -> do
          (updated, ambiguous) <- settleReleasedRefreshes (releaseLeases snapshot [current] "materialization_failed") [current]
          pure
            Change
              { snapshot = updated
              , value = ()
              , details = [("ambiguous_refresh", AuditBool (not (null ambiguous)))]
              , cleanupIds = [current.attachmentId]
              }
        _ -> pure Change {snapshot, value = (), details = [("already_settled", AuditBool True)], cleanupIds = []}
  pure ()

seal :: AgentConnectionCustody -> Text -> Integer -> Integer -> OpaqueState -> IO ByteString
seal custody connectionId authorityEpoch stateVersion state =
  ( do
      context <- throwLeft (mkKeyContext connectionId authorityEpoch stateVersion)
      plaintext <- borrow state
      -- Force the ciphertext before the plaintext is zeroed: a host may
      -- return a lazily computed value.
      custody.keys.seal context plaintext >>= evaluate
  )
    `finally` eraseOpaqueState state

sealBuffer :: AgentConnectionCustody -> Text -> Integer -> Integer -> ScrubbedBytes -> IO ByteString
sealBuffer custody connectionId authorityEpoch stateVersion state =
  ( do
      context <- throwLeft (mkKeyContext connectionId authorityEpoch stateVersion)
      custody.keys.seal context state >>= evaluate
  )
    `finally` eraseBuffer state

-- | @_load@: the storage's snapshot, validated unless the storage vouches
-- for it ('trustedLoad').
loadValidated :: AgentConnectionCustody -> IO StorageSnapshot
loadValidated custody = case custody.storage.trustedLoad of
  Just trusted -> validatedSnapshot <$> trusted
  Nothing -> custody.storage.load >>= validateSnapshotIO

currentTime :: AgentConnectionCustody -> IO Double
currentTime custody = custody.clock >>= throwLeft . (`finiteTime` "custody clock")

-- ---------------------------------------------------------------------------
-- The commit loop

data Change a = Change
  { snapshot :: StorageSnapshot
  , value :: a
  , details :: [(Text, AuditValue)]
  -- ^ In upstream's dict insertion order; sorted when recorded.
  , cleanupIds :: [Text]
  }

type Transform a = StorageSnapshot -> IO (Change a)

-- | A transform that does not read the clock.
pureTransform :: (StorageSnapshot -> Either AgenticusError (Change a)) -> Transform a
pureTransform transform = throwLeft . transform

-- | A transform that reads the clock first, once per attempt.
withNow :: AgentConnectionCustody -> (Double -> StorageSnapshot -> Either AgenticusError (Change a)) -> Transform a
withNow custody transform snapshot = do
  now <- currentTime custody
  throwLeft (transform now snapshot)

data Subjects = Subjects
  { connectionIdOf :: Maybe Text
  , hostIdOf :: Maybe Text
  , leaseIdOf :: Maybe Text
  }

noSubjects :: Subjects
noSubjects = Subjects Nothing Nothing Nothing

fenceSubjects :: AttachmentFence -> Subjects
fenceSubjects fence = Subjects (Just fence.connectionId) (Just fence.hostId) (Just fence.leaseId)

-- | @_commit@: up to 'casAttempts' load/transform/CAS rounds; on success,
-- clean up the change's attachments and log one secret-free line.
commit :: AgentConnectionCustody -> Text -> Text -> Subjects -> Transform a -> IO (a, CleanupSummary)
commit custody operationId eventKind subjects transform = do
  throwLeft (operationIdentity operationId)
  attempt casAttempts
  where
    attempt remaining
      | remaining <= 0 =
          throwAgenticus
            StorageContention
            ("operation " <> pythonStrRepr operationId <> " could not publish after bounded CAS retries")
      | otherwise = do
          snapshot <- loadValidated custody
          when (any (\record -> record.operationId == operationId) snapshot.audit) $
            throwAgenticus
              OperationConflict
              ("operation " <> pythonStrRepr operationId <> " is already published; reconcile it through lookup_operation")
          change <- transform snapshot
          details <- throwLeft (auditDetails change.details)
          let record =
                AuditRecord
                  { sequence = toInteger (length snapshot.audit) + 1
                  , operationId
                  , eventKind
                  , connectionId = subjects.connectionIdOf
                  , hostId = subjects.hostIdOf
                  , leaseId = subjects.leaseIdOf
                  , details
                  }
              replacement = appendRecord (snapshot.revision + 1) record change.snapshot
          published <- custody.storage.compareAndSwap snapshot.revision replacement
          if published
            then do
              cleanup <- Files.summarize custody.materializer (ordNub change.cleanupIds)
              custody.logger
                ( T.unwords
                    [ eventKind
                    , "operation=" <> operationId
                    , "connection=" <> orDash subjects.connectionIdOf
                    , "host=" <> orDash subjects.hostIdOf
                    , "lease=" <> orDash subjects.leaseIdOf
                    ]
                )
              pure (change.value, cleanup)
            else attempt (remaining - 1)
    orDash = \case
      Just value | not (T.null value) -> value
      _ -> "-"

appendRecord :: Integer -> AuditRecord -> StorageSnapshot -> StorageSnapshot
appendRecord revision record StorageSnapshot {hosts, connections, leases, audit} =
  StorageSnapshot {revision, hosts, connections, leases, audit = audit <> [record]}

-- | @_audit_details@: refuse names that look like secrets, then sort.
auditDetails :: [(Text, AuditValue)] -> Either AgenticusError AuditDetails
auditDetails details = do
  case find unsafe (map fst details) of
    Just name -> Left (valueError ("audit detail " <> pythonStrRepr name <> " is not safe metadata"))
    Nothing -> pure ()
  pure (Map.toAscList (Map.fromList details))
  where
    unsafe name = any (`T.isInfixOf` T.toLower name) ["token", "secret", "password", "home", "key_material"]

-- ---------------------------------------------------------------------------
-- Pure helpers (upstream's module-level functions)

identityText :: Text -> Text -> Either AgenticusError ()
identityText value name =
  () <$ checkedText maxTextBytes failure value
  where
    failure = valueError (name <> " identity must be a trimmed string of at most " <> T.pack (show maxTextBytes) <> " UTF-8 bytes")

operationIdentity :: Text -> Either AgenticusError ()
operationIdentity value = identityText value "operation"

positiveTtl :: Double -> Either AgenticusError ()
positiveTtl ttl = do
  checked <- finiteTime ttl "materialization lease ttl"
  when (checked <= 0) $ Left (valueError "materialization lease ttl must be positive")

finiteTime :: Double -> Text -> Either AgenticusError Double
finiteTime value name
  | isNaN value || isInfinite value = Left (valueError (name <> " must be a finite number"))
  | otherwise = Right value

-- | @prefix + sha256(operation_id).hexdigest()[:32]@.
derivedIdentity :: Text -> Text -> Text
derivedIdentity prefix operationId = prefix <> T.take 32 (sha256Hex (TE.encodeUtf8 operationId))

count :: [a] -> AuditValue
count = AuditInt . toInteger . length

hostsMap :: StorageSnapshot -> Map Text StoredHost
hostsMap snapshot = Map.fromList [(host.hostId, host) | host <- snapshot.hosts]

connectionsMap :: StorageSnapshot -> Map Text StoredConnection
connectionsMap snapshot = Map.fromList [(connection.connectionId, connection) | connection <- snapshot.connections]

leasesMap :: StorageSnapshot -> Map Text StoredLease
leasesMap snapshot = Map.fromList [(lease.leaseId, lease) | lease <- snapshot.leases]

replaceHosts :: StorageSnapshot -> Map Text StoredHost -> StorageSnapshot
replaceHosts StorageSnapshot {..} replacement = StorageSnapshot {hosts = Map.elems replacement, ..}

replaceConnection :: StorageSnapshot -> StoredConnection -> StorageSnapshot
replaceConnection snapshot connection = withConnections (Map.elems (Map.insert connection.connectionId connection (connectionsMap snapshot))) snapshot

withConnections :: [StoredConnection] -> StorageSnapshot -> StorageSnapshot
withConnections replacement StorageSnapshot {..} = StorageSnapshot {connections = replacement, ..}

replaceLeases :: StorageSnapshot -> Map Text StoredLease -> StorageSnapshot
replaceLeases StorageSnapshot {..} replacement = StorageSnapshot {leases = Map.elems replacement, ..}

activeHost :: StorageSnapshot -> Text -> Either AgenticusError StoredHost
activeHost snapshot hostId = case Map.lookup hostId (hostsMap snapshot) of
  Just host | host.active -> Right host
  _ -> Left (AgenticusError HostNotEnrolled ("host " <> pythonStrRepr hostId <> " is not enrolled"))

connectionOf :: StorageSnapshot -> Text -> Either AgenticusError StoredConnection
connectionOf snapshot connectionId = case Map.lookup connectionId (connectionsMap snapshot) of
  Just connection -> Right connection
  Nothing -> Left (AgenticusError CustodyError ("connection " <> pythonStrRepr connectionId <> " does not exist"))

activeLeases :: StorageSnapshot -> Double -> (StoredLease -> Bool) -> [StoredLease]
activeLeases snapshot now selected =
  [lease | lease <- snapshot.leases, not lease.released, lease.expiresAt > now, selected lease]

unsettledLeases :: StorageSnapshot -> Text -> [StoredLease]
unsettledLeases snapshot connectionId =
  [lease | lease <- snapshot.leases, lease.connectionId == connectionId, not lease.released]

releaseLeases :: StorageSnapshot -> [StoredLease] -> Text -> StorageSnapshot
releaseLeases snapshot selected reason
  | null selected = snapshot
  | otherwise =
      replaceLeases snapshot (foldl (\leases lease -> Map.insert lease.leaseId (releasedWith reason lease) leases) (leasesMap snapshot) selected)

settleReleasedRefreshes :: StorageSnapshot -> [StoredLease] -> Either AgenticusError (StorageSnapshot, [Text])
settleReleasedRefreshes snapshot released = do
  let refreshed = Set.toAscList (Set.fromList [lease.connectionId | lease <- released, lease.mode == "refresh"])
      ambiguous = Set.toAscList (Set.fromList [lease.connectionId | lease <- released, lease.activated])
      settle updated connectionId = do
        connection <- connectionOf updated connectionId
        if connection.status /= "refreshing"
          then Right updated
          else
            let isAmbiguous = connectionId `elem` ambiguous
                replacement
                  | isAmbiguous =
                      eraseState' (withEpoch (connection.authorityEpoch + 1) (withStatus "reauthorization_required" connection))
                  | otherwise = withStatus "ready" connection
             in Right (replaceConnection updated replacement)
  updated <- foldM settle snapshot refreshed
  pure (updated, ambiguous)
  where
    eraseState' StoredConnection {..} = StoredConnection {encryptedState = Nothing, stateDigest = Nothing, ..}

reconcileExpired :: StorageSnapshot -> Double -> Either AgenticusError (StorageSnapshot, [Text], [Text])
reconcileExpired snapshot now = do
  let expired = [lease | lease <- snapshot.leases, not lease.released, lease.expiresAt <= now]
  (updated, ambiguous) <- settleReleasedRefreshes (releaseLeases snapshot expired "expired") expired
  pure (updated, map (.attachmentId) expired, ambiguous)

requireMaterializable :: StoredConnection -> Either AgenticusError ()
requireMaterializable connection = case parseConnectionStatus connection.status of
  Nothing ->
    Left (valueError (pythonStrRepr connection.status <> " is not a valid ConnectionStatus"))
  Just status
    | status `elem` [StatusRevoked, StatusErasurePending, StatusReauthorizationRequired] ->
        Left (reauthorizationRequired connection.connectionId)
    | status == StatusRefreshing ->
        Left (AgenticusError LeaseConflict ("connection " <> pythonStrRepr connection.connectionId <> " already has refresh custody"))
    | Nothing <- connection.encryptedState -> Left (reauthorizationRequired connection.connectionId)
    | otherwise -> Right ()

requireCurrentLease :: StorageSnapshot -> AttachmentFence -> Double -> LeaseMode -> Either AgenticusError StoredLease
requireCurrentLease snapshot fence now mode =
  case (Map.lookup fence.leaseId (leasesMap snapshot), Map.lookup fence.hostId (hostsMap snapshot)) of
    (Just lease, Just host)
      | host.active
      , host.enrollmentEpoch == fence.hostEpoch
      , not lease.released
      , lease.expiresAt > now
      , lease.mode == leaseModeText mode
      , leaseMatches lease fence ->
          Right lease
    _ -> Left (staleCustody fence)

leaseMatches :: StoredLease -> AttachmentFence -> Bool
leaseMatches lease fence =
  lease.attachmentId == fence.attachmentId
    && lease.connectionId == fence.connectionId
    && lease.hostId == fence.hostId
    && lease.hostEpoch == fence.hostEpoch
    && lease.authorityEpoch == fence.authorityEpoch
    && lease.baseVersion == fence.baseVersion

attachmentIsCurrent :: StorageSnapshot -> AttachmentFence -> Double -> Bool
attachmentIsCurrent snapshot fence now = case Map.lookup fence.leaseId (leasesMap snapshot) >>= parseLeaseMode . (.mode) of
  Nothing -> False
  Just mode -> case (requireCurrentLease snapshot fence now mode, connectionOf snapshot fence.connectionId) of
    (Right lease, Right connection) ->
      leaseMatches lease fence
        && connection.status `elem` ["ready", "refreshing"]
        && connection.authorityEpoch == fence.authorityEpoch
        && connection.stateVersion == fence.baseVersion
    _ -> False

-- | The attachment fence a stored lease grants.
fenceOf :: StoredLease -> AttachmentFence
fenceOf lease =
  AttachmentFence
    { attachmentId = lease.attachmentId
    , leaseId = lease.leaseId
    , connectionId = lease.connectionId
    , hostId = lease.hostId
    , hostEpoch = lease.hostEpoch
    , authorityEpoch = lease.authorityEpoch
    , baseVersion = lease.baseVersion
    }

viewOf :: StoredConnection -> Either AgenticusError ConnectionView
viewOf connection = do
  identity <- mkConnectionIdentity connection.connectionId connection.provider connection.accountFingerprint connection.profile
  status <- maybe (Left (valueError (pythonStrRepr connection.status <> " is not a valid ConnectionStatus"))) Right (parseConnectionStatus connection.status)
  pure
    ConnectionView
      { identity
      , status
      , authorityEpoch = connection.authorityEpoch
      , stateVersion = connection.stateVersion
      , stateDigest = connection.stateDigest
      }

sameConnectionGeneration :: Maybe StoredConnection -> Maybe StoredConnection -> Bool
sameConnectionGeneration left right = case (left, right) of
  (Just a, Just b) ->
    a.connectionId == b.connectionId
      && a.status == b.status
      && a.authorityEpoch == b.authorityEpoch
      && a.stateVersion == b.stateVersion
      && a.stateDigest == b.stateDigest
  (Nothing, Nothing) -> True
  _ -> False

identityMatches :: StoredConnection -> ConnectionIdentity -> Bool
identityMatches connection identity =
  connection.connectionId == identity.connectionId
    && connection.provider == identity.provider
    && connection.accountFingerprint == identity.accountFingerprint
    && connection.profile == identity.profile

operationView :: AuditRecord -> OperationView
operationView record =
  OperationView
    { operationId = record.operationId
    , eventKind = record.eventKind
    , connectionId = record.connectionId
    , hostId = record.hostId
    , leaseId = record.leaseId
    , details = record.details
    }

staleCustody :: AttachmentFence -> AgenticusError
staleCustody fence =
  AgenticusError StaleCustody ("lease is no longer current for connection " <> pythonStrRepr fence.connectionId)

reauthorizationRequired :: Text -> AgenticusError
reauthorizationRequired connectionId =
  AgenticusError ReauthorizationRequired ("connection " <> pythonStrRepr connectionId <> " requires explicit reauthorization")

-- Record rewrites (@dataclasses.replace@).

withStatus :: Text -> StoredConnection -> StoredConnection
withStatus replacement StoredConnection {..} = StoredConnection {status = replacement, ..}

withEpoch :: Integer -> StoredConnection -> StoredConnection
withEpoch replacement StoredConnection {..} = StoredConnection {authorityEpoch = replacement, ..}

acceptState :: Integer -> ByteString -> StoredConnection -> StoredConnection
acceptState version encrypted StoredConnection {..} =
  StoredConnection
    { status = "ready"
    , stateVersion = version
    , encryptedState = Just encrypted
    , stateDigest = Just (sha256Hex encrypted)
    , ..
    }

eraseState :: StoredConnection -> StoredConnection
eraseState StoredConnection {..} =
  StoredConnection {stateVersion = stateVersion + 1, encryptedState = Nothing, stateDigest = Nothing, ..}

markActivated :: StoredLease -> StoredLease
markActivated StoredLease {..} = StoredLease {activated = True, ..}

withExpiry :: Double -> StoredLease -> StoredLease
withExpiry replacement StoredLease {..} = StoredLease {expiresAt = replacement, ..}

releasedWith :: Text -> StoredLease -> StoredLease
releasedWith reason StoredLease {..} = StoredLease {released = True, releaseReason = Just reason, ..}

-- | @tuple(dict.fromkeys(values))@: first occurrences, in order.
ordNub :: [Text] -> [Text]
ordNub = go Set.empty
  where
    go _ [] = []
    go seen (value : rest)
      | value `Set.member` seen = go seen rest
      | otherwise = value : go (Set.insert value seen) rest
