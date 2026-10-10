-- | One Agenticus Episode bound to one attachment identity and territory
-- (@petrus.agenticus.attachment.episode@).
--
-- The attachment owns the shared 'Barrier' that every Hands call and every
-- attachment transition take. The epoch transition always runs in this
-- order:
--
-- 1. close admission;
-- 2. drain current calls;
-- 3. discard every stage;
-- 4. export one bounded workspace archive;
-- 5. destroy the bound territory;
-- 6. consume its settlement evidence.
--
-- An unverified settlement leaves custody uncertain and fail-closed: new
-- gateways, succession and release are all refused until a retry verifies.
module Petrus.Agenticus.Attachment.Episode
  ( -- * Result admission through a connection fence
    ConnectionAdmissionSource (..)
  , custodyAdmissionSource
  , custodyResultAdmission
    -- * Evidence
  , AttachmentSettlement (attachmentId, epoch, stagesDiscarded, archive, archiveDigest, settlement)
  , mkAttachmentSettlement
  , AttachmentRelease (attachmentId, epoch, stagesDiscarded, archive, archiveDigest, territory)
  , mkAttachmentRelease
  , ReleaseAdmission (..)
    -- * The attachment
  , EpisodeOptions (..)
  , episodeOptions
  , EpisodeAttachment
  , newEpisodeAttachment
  , episodeId
  , episodeSnapshot
  , handsDescriptor
  , territoryDescriptor
  , episodeAttachmentId
  , episodeEpoch
  , episodeBinding
  , episodeBarrier
  , episodeDeadline
  , custodyUncertain
  , settled
  , lastSettlement
  , coordinates
  , grants
  , gateway
  , cancel
  , settle
  , releaseTo
  , retrySettlement
  , successor
  , fenceSnapshot
  ) where

import Control.Exception (SomeAsyncException, SomeException, finally, fromException, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Petrus.Agenticus.Attachment.Binding
import Petrus.Agenticus.Catalog.Descriptor (CapabilityDescriptor, DescriptorKind (..))
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot, snapshotDescriptor)
import Petrus.Agenticus.Connection.Custody (AgentConnectionCustody, AttachmentFence, admitResult)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Gateway
  ( Barrier
  , CallFence
  , CallFenceSource (..)
  , GatewayConfig (..)
  , HandsAdapter
  , HandsGateway
  , ResultAdmission (..)
  , TargetCurrency
  , cleanupStages
  , drain
  , gatewayConfig
  , mkCallFence
  , newBarrier
  , newHandsGateway
  , withBarrier
  )
import Petrus.Agenticus.Hands.Grants (GrantLedger, closeGrant, newGrantLedger)
import Petrus.Agenticus.Internal.Validate (hasControl, isTrimmed, utf8Length)
import Petrus.Agenticus.Thread.Identity (EpisodeId, LifecycleId (lifecycleIdText))
import Petrus.Motus.Execution (LeaseIdentity)
import Petrus.Motus.Execution.Archive (maxWorkspaceArchiveBytes)

maxIdentityBytes :: Int
maxIdentityBytes = 256

sha256Hex :: ByteString -> Text
sha256Hex bytes = T.pack (show (hash bytes :: Digest SHA256))

-- | Rethrow asynchronous exceptions; hand synchronous ones to the handler.
catchSync :: IO a -> (SomeException -> IO a) -> IO a
catchSync action handler =
  try action >>= \case
    Right value -> pure value
    Left e
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | otherwise -> handler e

-- ---------------------------------------------------------------------------
-- Result admission

-- | The DS2 admission seam: a fenced custody reference, never key material.
newtype ConnectionAdmissionSource = ConnectionAdmissionSource
  { admit :: AttachmentFence -> Text -> IO ()
  -- ^ fence, operation id; a synchronous exception refuses admission.
  }

-- | Admission through the connection custody ledger.
custodyAdmissionSource :: AgentConnectionCustody -> ConnectionAdmissionSource
custodyAdmissionSource custody = ConnectionAdmissionSource (\fence operation -> () <$ admitResult custody fence operation)

-- | @CustodyResultAdmission(custody, fence)@: a stale, revoked or removed
-- connection fence makes admission return 'False', which the gateway renders
-- as the safe @authority@ category.
custodyResultAdmission :: ConnectionAdmissionSource -> AttachmentFence -> ResultAdmission
custodyResultAdmission source fence =
  ResultAdmission (\callId -> (True <$ source.admit fence callId) `catchSync` const (pure False))

-- ---------------------------------------------------------------------------
-- Evidence

-- | Evidence of one ordered epoch settlement for the host to consume.
data AttachmentSettlement = AttachmentSettlement
  { attachmentId :: Text
  , epoch :: Integer
  , stagesDiscarded :: Int
  , archive :: ByteString
  , archiveDigest :: Text
  , settlement :: BindingSettlement
  }
  deriving stock (Eq)

-- | The archive is evidence, not something to print.
instance Show AttachmentSettlement where
  showsPrec d s =
    showParen (d > 10) $
      showString "AttachmentSettlement "
        . showsPrec 11 s.attachmentId
        . showChar ' '
        . showsPrec 11 s.epoch
        . showChar ' '
        . showsPrec 11 s.stagesDiscarded
        . showChar ' '
        . showsPrec 11 s.archiveDigest
        . showChar ' '
        . showsPrec 11 s.settlement

mkAttachmentSettlement :: Text -> Integer -> Int -> ByteString -> Text -> BindingSettlement -> Either AgenticusError AttachmentSettlement
mkAttachmentSettlement attachment epoch' stages archive' digest evidence = do
  when (epoch' <= 0) $ Left (valueError "settlement epoch must be a positive integer")
  when (stages < 0) $ Left (valueError "settlement stages_discarded must be a non-negative integer")
  when (digest /= sha256Hex archive') $ Left (valueError "settlement archive digest must match the exported archive")
  Right (AttachmentSettlement attachment epoch' stages archive' digest evidence)

-- | Evidence that one closed Attachment transferred an exact lease to its
-- host.
data AttachmentRelease = AttachmentRelease
  { attachmentId :: Text
  , epoch :: Integer
  , stagesDiscarded :: Int
  , archive :: ByteString
  , archiveDigest :: Text
  , territory :: LeaseIdentity
  }
  deriving stock (Eq)

instance Show AttachmentRelease where
  showsPrec d r =
    showParen (d > 10) $
      showString "AttachmentRelease "
        . showsPrec 11 r.attachmentId
        . showChar ' '
        . showsPrec 11 r.epoch
        . showChar ' '
        . showsPrec 11 r.stagesDiscarded
        . showChar ' '
        . showsPrec 11 r.archiveDigest
        . showChar ' '
        . showsPrec 11 r.territory

mkAttachmentRelease :: Text -> Integer -> Int -> ByteString -> Text -> LeaseIdentity -> Either AgenticusError AttachmentRelease
mkAttachmentRelease attachment epoch' stages archive' digest territory' = do
  when (epoch' <= 0) $ Left (valueError "release epoch must be a positive integer")
  when (stages < 0) $ Left (valueError "release stages_discarded must be a non-negative integer")
  when (digest /= sha256Hex archive') $ Left (valueError "release archive digest must match the exported archive")
  Right (AttachmentRelease attachment epoch' stages archive' digest territory')

-- | The host custody that accepts a released lease (the reference's
-- @_ReleaseAdmission@ protocol): binding, coordinates, stages discarded and
-- the exported archive in; the exact accepted territory out.
newtype ReleaseAdmission = ReleaseAdmission
  { acceptRelease :: MotusAttachmentBinding -> AttachmentCoordinates -> Int -> ByteString -> IO LeaseIdentity
  }

-- ---------------------------------------------------------------------------
-- The attachment

-- | The optional constructor arguments.
data EpisodeOptions = EpisodeOptions
  { attachmentEpoch :: Integer
  , admission :: Maybe ResultAdmission
  , target :: Maybe TargetCurrency
  , clock :: IO Double
  }

-- | @attachment_epoch=1@, no admission, no target currency, the monotonic
-- clock.
episodeOptions :: EpisodeOptions
episodeOptions = EpisodeOptions 1 Nothing Nothing getMonotonicTime

data State = State
  { gateways :: [HandsGateway]
  , open :: Bool
  , aborted :: Bool
  , cancelled :: Bool
  , settlement :: Maybe AttachmentSettlement
  , release :: Maybe AttachmentRelease
  , uncertain :: Bool
  , settling :: Bool
  }

data EpisodeAttachment = EpisodeAttachment
  { episodeId :: EpisodeId
  , snapshot :: ResolutionSnapshot
  , handsDescriptor :: CapabilityDescriptor
  , territoryDescriptor :: CapabilityDescriptor
  , binding :: AttachmentBinding
  , attachmentId :: Text
  , deadline :: Double
  , options :: EpisodeOptions
  , barrier :: Barrier
  , ledger :: GrantLedger
  , state :: IORef State
  }

-- | @EpisodeAttachment(episode_id=..., snapshot=..., binding=...,
-- attachment_id=..., deadline=..., ...)@.
newEpisodeAttachment :: EpisodeId -> ResolutionSnapshot -> AttachmentBinding -> Text -> Double -> EpisodeOptions -> IO EpisodeAttachment
newEpisodeAttachment episode snapshot' binding' attachment deadline' opts = do
  (hands, territory') <- case (snapshotDescriptor KindHands snapshot', snapshotDescriptor KindTerritory snapshot') of
    (Just h, Just t) -> pure (h, t)
    _ -> throwAgenticus ValueError "resolution snapshot must select Hands and Territory descriptors"
  when
    ( T.null attachment
        || not (isTrimmed attachment)
        || utf8Length attachment > maxIdentityBytes
        || hasControl attachment
    )
    $ throwAgenticus ValueError "attachment_id must be a bounded non-empty identity string"
  when (isNaN deadline' || isInfinite deadline') $
    throwAgenticus ValueError "episode attachment deadline must be a finite number"
  when (opts.attachmentEpoch <= 0) $
    throwAgenticus ValueError "episode attachment epoch must be a positive integer"
  when (T.null binding'.kind) $
    throwAgenticus TypeError "episode attachment binding must implement the binding protocol"
  case mkBindingSettlement binding'.kind "unverified" False "" of
    Left _ -> throwAgenticus TypeError "episode attachment binding kind must satisfy the binding protocol"
    Right _ -> pure ()
  barrier' <- newBarrier
  ledger' <- newGrantLedger attachment opts.attachmentEpoch
  state' <- newIORef (State [] True False False Nothing Nothing False False)
  pure (EpisodeAttachment episode snapshot' hands territory' binding' attachment deadline' opts barrier' ledger' state')

episodeId :: EpisodeAttachment -> EpisodeId
episodeId a = a.episodeId

episodeSnapshot :: EpisodeAttachment -> ResolutionSnapshot
episodeSnapshot a = a.snapshot

handsDescriptor, territoryDescriptor :: EpisodeAttachment -> CapabilityDescriptor
handsDescriptor a = a.handsDescriptor
territoryDescriptor a = a.territoryDescriptor

episodeAttachmentId :: EpisodeAttachment -> Text
episodeAttachmentId a = a.attachmentId

episodeEpoch :: EpisodeAttachment -> Integer
episodeEpoch a = a.options.attachmentEpoch

episodeBinding :: EpisodeAttachment -> AttachmentBinding
episodeBinding a = a.binding

-- | The one barrier Hands calls and attachment transition share.
episodeBarrier :: EpisodeAttachment -> Barrier
episodeBarrier a = a.barrier

episodeDeadline :: EpisodeAttachment -> Double
episodeDeadline a = a.deadline

locked :: EpisodeAttachment -> (State -> IO b) -> IO b
locked a f = withBarrier a.barrier (readIORef a.state >>= f)

modify' :: EpisodeAttachment -> (State -> State) -> IO ()
modify' a f = withBarrier a.barrier (modifyIORef' a.state f)

custodyUncertain :: EpisodeAttachment -> IO Bool
custodyUncertain a = locked a (pure . (.uncertain))

-- | Whether the current epoch has independently verified settlement.
settled :: EpisodeAttachment -> IO Bool
settled a = locked a (pure . maybe False (\s -> s.settlement.verified) . (.settlement))

lastSettlement :: EpisodeAttachment -> IO (Maybe AttachmentSettlement)
lastSettlement a = locked a (pure . (.settlement))

-- | The current DS7-consumable Episode/attachment coordinates.
coordinates :: EpisodeAttachment -> IO AttachmentCoordinates
coordinates a =
  either throwIO pure (mkAttachmentCoordinates (lifecycleIdText a.episodeId) a.attachmentId (episodeEpoch a))

-- | The current epoch's grant ledger; grants never survive replacement.
grants :: EpisodeAttachment -> GrantLedger
grants a = a.ledger

-- | Open one Hands gateway bound to the current epoch and shared barrier.
gateway :: EpisodeAttachment -> HandsAdapter -> Int -> IO HandsGateway
gateway a adapter maxEvidence' = locked a $ \s -> do
  when s.uncertain $ throwAgenticus UncertainCustodyError "uncertain custody blocks new gateways"
  unless s.open $ throwAgenticus EpisodeAttachmentError "attachment admission is closed"
  let fence = CallFenceSource (fenceSnapshot a (episodeEpoch a))
  gw <-
    newHandsGateway
      (gatewayConfig (lifecycleIdText a.episodeId) adapter a.ledger fence a.barrier)
        { admission = a.options.admission
        , target = a.options.target
        , clock = a.options.clock
        , maxEvidence = maxEvidence'
        }
  modifyIORef' a.state (\st -> st {gateways = st.gateways <> [gw]})
  pure gw

-- | Abort current calls fail-closed and cancel the bound territory.
cancel :: EpisodeAttachment -> Text -> IO ()
cancel a reason = locked a $ \s -> do
  when s.settling $ throwAgenticus EpisodeAttachmentError "attachment settlement is already in progress"
  when (maybe False (const True) s.settlement || not s.open) $
    throwAgenticus EpisodeAttachmentError "attachment is already settled"
  unless s.cancelled $ do
    modifyIORef' a.state (\st -> st {aborted = True})
    a.binding.cancel reason `catchSync` const (throwAgenticus EpisodeAttachmentError "attachment cancellation failed")
    modifyIORef' a.state (\st -> st {cancelled = True})

-- | Drain every gateway, discard every stage and export one bounded archive.
drainAndExport :: [HandsGateway] -> Double -> Text -> IO ByteString -> IO (Int, ByteString)
drainAndExport gws timeout what exportArchive' = do
  forM_ gws $ \gw -> do
    drained <- drain gw timeout
    unless drained $ throwAgenticus EpisodeAttachmentError ("current calls did not drain before " <> what)
  stages <- sum <$> forM gws cleanupStages
  archive' <- exportArchive'
  when (B.length archive' > maxWorkspaceArchiveBytes) $
    throwAgenticus EpisodeAttachmentError "attachment archive exceeds the public Motus workspace archive bound"
  pure (stages, archive')

-- | Consume the binding's settlement, keeping only kind, disposition and
-- verification (never the detail); a failure is unverified evidence.
consumeSettlement :: EpisodeAttachment -> IO (Either BindingSettlement BindingSettlement)
consumeSettlement a =
  ( do
      evidence <- a.binding.settle
      either throwIO (pure . Right) (mkBindingSettlement evidence.bindingKind evidence.disposition evidence.verified "")
  )
    `catchSync` \_ ->
      either throwIO (pure . Left) (mkBindingSettlement a.binding.kind "unverified" False "binding settlement failed")

recordSettlement :: EpisodeAttachment -> Int -> ByteString -> BindingSettlement -> IO AttachmentSettlement
recordSettlement a stages archive' evidence =
  either throwIO pure (mkAttachmentSettlement a.attachmentId (episodeEpoch a) stages archive' (sha256Hex archive') evidence)

-- | Run the ordered transition for the current epoch and consume evidence
-- (@settle(drain_timeout=30.0)@). An unverified settlement leaves
-- fail-closed uncertain custody; it is returned, not raised, because the
-- evidence itself is what the host must consume.
settle :: EpisodeAttachment -> Double -> IO AttachmentSettlement
settle a drainTimeout = do
  gws <- locked a $ \s -> do
    when s.uncertain $ throwAgenticus UncertainCustodyError "retry settlement instead of settling again"
    when (isJust' s.settlement || isJust' s.release) $
      throwAgenticus EpisodeAttachmentError "attachment epoch is already settled"
    when s.settling $ throwAgenticus EpisodeAttachmentError "attachment settlement is already in progress"
    modifyIORef' a.state (\st -> st {settling = True, open = False})
    pure s.gateways
  ( do
      (stages, archive') <- drainAndExport gws drainTimeout "settlement" a.binding.exportArchive
      consumeSettlement a >>= \case
        Left failed -> do
          record <- recordSettlement a stages archive' failed
          withBarrier a.barrier $ do
            closeGrant a.ledger
            modifyIORef' a.state (\st -> st {settlement = Just record, uncertain = True})
          throwAgenticus EpisodeAttachmentError "attachment binding settlement failed"
        Right evidence -> do
          record <- recordSettlement a stages archive' evidence
          withBarrier a.barrier $ do
            closeGrant a.ledger
            modifyIORef' a.state (\st -> st {settlement = Just record, uncertain = not evidence.verified})
          pure record
    )
    `finally` modify' a (\st -> st {settling = False})

-- | Close this Attachment and transfer its exact Motus lease to durable host
-- custody (the reference's @_release_to@).
releaseTo :: EpisodeAttachment -> ReleaseAdmission -> Double -> IO AttachmentRelease
releaseTo a admission' drainTimeout = do
  (gws, motusBinding', coords) <- locked a $ \s -> do
    when s.uncertain $ throwAgenticus UncertainCustodyError "uncertain custody blocks attachment release"
    when (isJust' s.settlement || isJust' s.release || not s.open) $
      throwAgenticus EpisodeAttachmentError "attachment is already settled or released"
    when s.settling $ throwAgenticus EpisodeAttachmentError "attachment settlement is already in progress"
    motus' <- maybe (throwAgenticus EpisodeAttachmentError "retained custody currently requires an exact Motus binding") pure a.binding.motus
    modifyIORef' a.state (\st -> st {settling = True, open = False})
    coords <- coordinates a
    pure (s.gateways, motus', coords)
  ( ( do
        quiesced <- bindingQuiesce motusBinding' drainTimeout
        unless quiesced $ throwAgenticus EpisodeAttachmentError "runtime operations did not drain before release"
        (stages, archive') <- drainAndExport gws drainTimeout "release" (bindingExportArchive motusBinding')
        territory' <- admission'.acceptRelease motusBinding' coords stages archive'
        when (territory' /= bindingLeaseIdentity motusBinding') $
          throwAgenticus EpisodeAttachmentError "host custody accepted a different territory identity"
        record <-
          either throwIO pure $
            mkAttachmentRelease a.attachmentId (episodeEpoch a) stages archive' (sha256Hex archive') territory'
        withBarrier a.barrier $ do
          closeGrant a.ledger
          modifyIORef' a.state (\st -> st {release = Just record})
        pure record
    )
      `catchSync` \_ -> do
        withBarrier a.barrier $ do
          closeGrant a.ledger
          modifyIORef' a.state (\st -> st {uncertain = True})
        throwAgenticus EpisodeAttachmentError "attachment release to host custody failed"
    )
    `finally` modify' a (\st -> st {settling = False})

-- | Retry only the destroy/consume step of an uncertain settlement.
retrySettlement :: EpisodeAttachment -> IO AttachmentSettlement
retrySettlement a = do
  record <- locked a $ \s -> do
    record <- case s.settlement of
      Just r | s.uncertain -> pure r
      _ -> throwAgenticus EpisodeAttachmentError "retry requires a prior unverified settlement"
    when s.settling $ throwAgenticus EpisodeAttachmentError "attachment settlement is already in progress"
    modifyIORef' a.state (\st -> st {settling = True})
    pure record
  ( consumeSettlement a >>= \case
      Left failed -> do
        updated <- recordSettlement a record.stagesDiscarded record.archive failed
        modify' a (\st -> st {settlement = Just updated, uncertain = True})
        throwAgenticus EpisodeAttachmentError "attachment binding settlement failed"
      Right evidence -> do
        updated <- recordSettlement a record.stagesDiscarded record.archive evidence
        modify' a (\st -> st {settlement = Just updated, uncertain = not evidence.verified})
        pure updated
    )
    `finally` modify' a (\st -> st {settling = False})

-- | Construct a new Episode attachment at the next epoch after this one
-- settles with verified evidence. Thread lineage cannot be proven here: the
-- DS3 host owns the assertion that both Episodes belong to the same Thread.
successor
  :: EpisodeAttachment
  -> EpisodeId
  -> ResolutionSnapshot
  -> AttachmentBinding
  -> Text
  -> Double
  -> Maybe ResultAdmission
  -> Maybe TargetCurrency
  -> IO EpisodeAttachment
successor a episode snapshot' binding' attachment deadline' admission' target' = do
  nextEpoch <- locked a $ \s -> do
    when s.uncertain $ throwAgenticus UncertainCustodyError "unverified cleanup blocks attachment succession"
    let verified = maybe False (\r -> r.settlement.verified) s.settlement
    when (s.open || not verified) $
      throwAgenticus EpisodeAttachmentError "succession requires verified settlement of the prior attachment"
    when (episode == a.episodeId) $ throwAgenticus EpisodeAttachmentError "successor requires a different EpisodeId"
    when (attachment == a.attachmentId) $
      throwAgenticus EpisodeAttachmentError "successor requires a different attachment_id"
    pure (episodeEpoch a + 1)
  newEpisodeAttachment
    episode
    snapshot'
    binding'
    attachment
    deadline'
    EpisodeOptions {attachmentEpoch = nextEpoch, admission = admission', target = target', clock = a.options.clock}

-- | The call fence for one exact attachment epoch; stale epochs read closed.
fenceSnapshot :: EpisodeAttachment -> Integer -> IO CallFence
fenceSnapshot a epoch' = locked a $ \s ->
  either throwIO pure $
    mkCallFence (episodeEpoch a == epoch' && s.open && not s.uncertain) s.aborted a.deadline

isJust' :: Maybe x -> Bool
isJust' = maybe False (const True)
