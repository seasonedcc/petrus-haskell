-- | Private single-host custody for intentionally retained Motus territories
-- (@petrus.agenticus.attachment._retention@).
--
-- Activity and Worker never receive this surface. One host state root
-- durably owns three obligations: release, exact-lease reclaim, and eventual
-- destruction.
--
-- The ledger is a mode-0600 SQLite file with one live writer, fenced by an
-- exclusive @flock@ on @.<name>.writer.lock@. It uses the reference's exact
-- DDL text and column order, so either implementation can open the other's
-- file.
module Petrus.Agenticus.Attachment.Retention
  ( TerritoryCustodyPhase (..)
  , phaseText
  , TerritoryCustodyRecord (..)
  , SqliteTerritoryCustody
  , custodyPath
  , openTerritoryCustody
  , openTerritoryCustodyWith
  , ReleaseTicket
  , beginRelease
  , release
  , reclaim
  , recover
  , retire
  , lookupCustody
  , records
  , closeTerritoryCustody
    -- * Row decoding and wire text (for differential checks)
  , decodeCustodyRow
  , salvagePhase
  , createTableSql
  , createIndexSql
  ) where

import Control.Concurrent.MVar
import Control.Exception (SomeException, catch, onException, throwIO, try)
import Control.Monad (forM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Petrus.Agenticus.Attachment.Binding
import Petrus.Agenticus.Attachment.Episode
import Petrus.Agenticus.Catalog.Descriptor (DescriptorKind (..))
import Petrus.Agenticus.Catalog.Resolution (ResolutionSnapshot, snapshotDescriptor)
import Petrus.Agenticus.Error
import Petrus.Agenticus.Hands.Gateway (ResultAdmission, TargetCurrency)
import Petrus.Agenticus.Internal.Exception
import Petrus.Agenticus.Internal.Sqlite
import Petrus.Agenticus.Internal.WriterFence
import Petrus.Agenticus.Internal.Validate (hasControl, isTrimmed, sha256Hex, utf8Length)
import Petrus.Agenticus.Thread.Identity (EpisodeId, lifecycleIdText)
import Petrus.Json (Json (..))
import Petrus.Json qualified as J
import Petrus.Motus.Execution hiding (ErrorKind (..))
import Petrus.Motus.Execution.Archive (maxWorkspaceArchiveBytes)
import System.FilePath (takeDirectory)
import System.Posix.Directory qualified as Dir
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as PIO
import System.Posix.Types (FileMode)
import System.Posix.User (getEffectiveUserID)
import System.Directory (createDirectoryIfMissing, doesPathExist)

-- ---------------------------------------------------------------------------
-- Phases and records

data TerritoryCustodyPhase
  = Releasing
  | Retained
  | Claiming
  | Attached
  | Retiring
  | Retired
  | Quarantined
  deriving stock (Eq, Ord, Show, Enum, Bounded)

phaseText :: TerritoryCustodyPhase -> Text
phaseText = \case
  Releasing -> "releasing"
  Retained -> "retained"
  Claiming -> "claiming"
  Attached -> "attached"
  Retiring -> "retiring"
  Retired -> "retired"
  Quarantined -> "quarantined"

parsePhase :: Text -> Maybe TerritoryCustodyPhase
parsePhase value = lookup value [(phaseText p, p) | p <- [minBound .. maxBound]]

parseCleanup :: Text -> Maybe CleanupDisposition
parseCleanup value = lookup value [(cleanupDispositionText d, d) | d <- [minBound .. maxBound]]

-- | One durable custody row. Only the ledger builds these: every record
-- comes out of the closed-state validation in 'decodeRow'.
data TerritoryCustodyRecord = TerritoryCustodyRecord
  { custodyId :: Text
  , ownerId :: Text
  , generation :: Integer
  , phase :: TerritoryCustodyPhase
  , source :: AttachmentCoordinates
  , lease :: EnvironmentLease
  , retainUntil :: Double
  , archive :: Maybe ByteString
  , archiveDigest :: Maybe Text
  , targetEpisodeId :: Maybe Text
  , targetAttachmentId :: Maybe Text
  , targetEpoch :: Maybe Integer
  , cleanup :: Maybe CleanupDisposition
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Validation (the reference's @_text@ / @_exact_int@ family)

-- | Why decoding a row failed. The reference raises 'StorageError' for some
-- closed-state violations and @ValueError@/@TypeError@/@JSONDecodeError@
-- for the rest. '_decode' turns the latter into one "malformed" storage
-- error, and salvage tells them apart.
data DecodeFailure
  = Malformed
  | Storage Text

isBounded :: Text -> Bool
isBounded value =
  not (T.null value) && isTrimmed value && utf8Length value <= 256 && not (hasControl value)

-- | @_text@ as a validation of public arguments: @ValueError@.
requireText :: Text -> Text -> IO ()
requireText name value =
  unless (isBounded value) $ throwAgenticus ValueError (name <> " must be bounded non-empty text")

columnText :: SqlValue -> Either DecodeFailure Text
columnText = \case
  SQLText value | isBounded value -> Right value
  _ -> Left Malformed

columnInt :: SqlValue -> Either DecodeFailure Integer
columnInt = \case
  SQLInteger value -> Right (toInteger value)
  _ -> Left Malformed

columnNumber :: SqlValue -> Either DecodeFailure Double
columnNumber = \case
  SQLInteger value -> Right (fromIntegral value)
  SQLFloat value -> Right value
  _ -> Left Malformed

optional :: (SqlValue -> Either DecodeFailure a) -> SqlValue -> Either DecodeFailure (Maybe a)
optional decode = \case
  SQLNull -> Right Nothing
  value -> Just <$> decode value

columnBytes :: SqlValue -> Either DecodeFailure ByteString
columnBytes = \case
  SQLBlob value -> Right value
  _ -> Left Malformed

-- | @_decode_validated@ followed by @TerritoryCustodyRecord.__post_init__@,
-- in the reference's order.
decodeRow :: [SqlValue] -> Either DecodeFailure TerritoryCustodyRecord
decodeRow row
  | length row /= 18 = Left Malformed
  | otherwise = do
      let at i = row !! i
      capabilityText <- columnText (at 10)
      capabilities <- case J.parseJson J.surrogateRefusingLoads (TE.encodeUtf8 capabilityText) of
        Left _ -> Left Malformed
        Right (Array items) | Just values <- traverse stringItem items -> Right values
        Right _ -> Left (Storage "territory custody capabilities are malformed")
      custody <- columnText (at 0)
      owner <- columnText (at 1)
      generation' <- columnInt (at 2)
      phase' <- columnText (at 3) >>= maybe (Left Malformed) Right . parsePhase
      sourceEpisode <- columnText (at 4)
      sourceAttachment <- columnText (at 5)
      sourceEpoch <- columnInt (at 6)
      source' <- either (const (Left Malformed)) Right (mkAttachmentCoordinates sourceEpisode sourceAttachment sourceEpoch)
      operation <- columnText (at 7)
      provider' <- columnText (at 8)
      leaseId' <- columnText (at 9)
      lease' <-
        either (const (Left Malformed)) Right $
          mkEnvironmentLease operation provider' leaseId' (Set.fromList (map Capability capabilities)) Ready
      retainUntil' <- columnNumber (at 11)
      archive' <- optional columnBytes (at 12)
      digest <- optional columnText (at 13)
      targetEpisode <- optional columnText (at 14)
      targetAttachment <- optional columnText (at 15)
      targetEpoch' <- optional columnInt (at 16)
      cleanup' <- optional (\v -> columnText v >>= maybe (Left Malformed) Right . parseCleanup) (at 17)
      let record =
            TerritoryCustodyRecord
              custody
              owner
              generation'
              phase'
              source'
              lease'
              retainUntil'
              archive'
              digest
              targetEpisode
              targetAttachment
              targetEpoch'
              cleanup'
      validateRecord record
  where
    stringItem = \case
      String value -> Just value
      _ -> Nothing

validateRecord :: TerritoryCustodyRecord -> Either DecodeFailure TerritoryCustodyRecord
validateRecord r = do
  when (r.generation <= 0) $ Left Malformed
  when (isNaN r.retainUntil || isInfinite r.retainUntil) $ Left Malformed
  case r.archive of
    Just bytes -> do
      when (B.length bytes > maxWorkspaceArchiveBytes) $ Left Malformed
      when (r.archiveDigest /= Just (sha256Hex bytes)) $
        Left (Storage "retained territory archive digest does not match its bytes")
    Nothing ->
      when (isJust r.archiveDigest) $ Left (Storage "retained territory archive digest has no bytes")
  let present = [isJust r.targetEpisodeId, isJust r.targetAttachmentId, isJust r.targetEpoch]
  when (or present && not (and present)) $
    Left (Storage "retained territory target coordinates are partial")
  case r.targetEpoch of
    Just target
      | isJust r.targetEpisodeId && target <= r.source.attachmentEpoch ->
          Left (Storage "territory target epoch must advance the source epoch")
    _ -> pure ()
  when (r.phase `elem` [Retained, Claiming] && isNothing r.archive) $
    Left (Storage "retained territory phase requires a durable archive")
  pure r

-- | @_decode@: closed-state violations keep their message; everything else
-- is "malformed".
decodeOrThrow :: [SqlValue] -> IO TerritoryCustodyRecord
decodeOrThrow = either throwIO pure . decodeCustodyRow

-- | @SqliteTerritoryCustody._decode@ over one @SELECT *@ row.
decodeCustodyRow :: [SqlValue] -> Either AgenticusError TerritoryCustodyRecord
decodeCustodyRow row = case decodeRow row of
  Right record -> Right record
  Left (Storage message) -> Left (AgenticusError StorageError message)
  Left Malformed -> Left (AgenticusError StorageError "territory custody record is malformed")

-- | The phase @_salvage_corrupt@ moves a row to.
salvagePhase :: [SqlValue] -> TerritoryCustodyPhase
salvagePhase row = maybe Quarantined (const Retiring) (salvageableIdentity row)

-- | Whether the destruction identity of a row is intact (salvage keeps
-- these rows retirable); the custody id when it is.
salvageableIdentity :: [SqlValue] -> Maybe Text
salvageableIdentity row
  | length row /= 18 = Nothing
  | otherwise = either (const Nothing) Just $ do
      let at i = row !! i
      custody <- columnText (at 0)
      _ <- columnText (at 1)
      generation' <- columnInt (at 2)
      when (generation' <= 0) $ Left Malformed
      episode <- columnText (at 4)
      attachment <- columnText (at 5)
      epoch' <- columnInt (at 6)
      _ <- either (const (Left Malformed)) Right (mkAttachmentCoordinates episode attachment epoch')
      operation <- columnText (at 7)
      provider' <- columnText (at 8)
      leaseId' <- columnText (at 9)
      _ <- either (const (Left Malformed)) Right (mkLeaseIdentity operation provider' leaseId')
      pure custody

-- ---------------------------------------------------------------------------
-- SQL (verbatim from the reference)

createTableSql :: Text
createTableSql =
  "CREATE TABLE IF NOT EXISTS territory_custody (\n\
  \                    custody_id TEXT PRIMARY KEY, owner_id TEXT NOT NULL,\n\
  \                    generation INTEGER NOT NULL, phase TEXT NOT NULL,\n\
  \                    source_episode TEXT NOT NULL, source_attachment TEXT NOT NULL,\n\
  \                    source_epoch INTEGER NOT NULL, operation_id TEXT NOT NULL,\n\
  \                    provider TEXT NOT NULL, lease_id TEXT NOT NULL,\n\
  \                    capabilities TEXT NOT NULL, retain_until REAL NOT NULL,\n\
  \                    archive BLOB, archive_digest TEXT,\n\
  \                    target_episode TEXT, target_attachment TEXT, target_epoch INTEGER,\n\
  \                    cleanup TEXT)"

createIndexSql :: Text
createIndexSql =
  "CREATE UNIQUE INDEX IF NOT EXISTS one_live_territory_operation\n\
  \                   ON territory_custody(provider, operation_id) WHERE phase <> 'retired'"

insertReleaseSql :: Text
insertReleaseSql =
  "INSERT INTO territory_custody\n\
  \                       (custody_id, owner_id, generation, phase, source_episode, source_attachment,\n\
  \                        source_epoch, operation_id, provider, lease_id, capabilities, retain_until)\n\
  \                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)\n\
  \                       ON CONFLICT(custody_id) DO UPDATE SET owner_id=excluded.owner_id,\n\
  \                        generation=excluded.generation, phase=excluded.phase,\n\
  \                        source_episode=excluded.source_episode, source_attachment=excluded.source_attachment,\n\
  \                        source_epoch=excluded.source_epoch, operation_id=excluded.operation_id,\n\
  \                        provider=excluded.provider, lease_id=excluded.lease_id,\n\
  \                        capabilities=excluded.capabilities, retain_until=excluded.retain_until,\n\
  \                        archive=NULL, archive_digest=NULL, target_episode=NULL,\n\
  \                        target_attachment=NULL, target_epoch=NULL, cleanup=NULL"

claimSql :: Text
claimSql =
  "UPDATE territory_custody SET phase=?, target_episode=?,\n\
  \                   target_attachment=?, target_epoch=? WHERE custody_id=? AND phase=?"

recoverSql :: Text
recoverSql =
  "UPDATE territory_custody SET phase=? WHERE phase IN (?, ?, ?)\n\
  \                   OR (phase=? AND retain_until<=?)"

retiredSql :: Text
retiredSql =
  "UPDATE territory_custody SET phase=?, archive=NULL,\n\
  \                   archive_digest=NULL, cleanup=? WHERE custody_id=? AND phase=?"

acceptSql :: Text
acceptSql =
  "UPDATE territory_custody SET phase=?, archive=?, archive_digest=?\n\
  \                   WHERE custody_id=? AND generation=? AND phase=?"

setPhaseSql :: Text
setPhaseSql = "UPDATE territory_custody SET phase=? WHERE custody_id=? AND phase=?"

setPhaseRawSql :: Text
setPhaseRawSql =
  "UPDATE territory_custody SET phase=?, capabilities='[]', retain_until=0,\n\
  \               archive=NULL, archive_digest=NULL, target_episode=NULL,\n\
  \               target_attachment=NULL, target_epoch=NULL, cleanup=NULL WHERE custody_id=?"

quarantineSql :: Text
quarantineSql = "UPDATE territory_custody SET phase=? WHERE custody_id=?"

selectOneSql :: Text
selectOneSql = "SELECT * FROM territory_custody WHERE custody_id=?"

selectAllSql :: Text
selectAllSql = "SELECT * FROM territory_custody ORDER BY custody_id"

-- ---------------------------------------------------------------------------
-- The ledger

-- | A mode-0600, single-writer custody ledger for one local host state root.
data SqliteTerritoryCustody = SqliteTerritoryCustody
  { path :: FilePath
  , clock :: IO Double
  , fence :: WriterFence
  , lock :: MVar ()
  , database :: Database
  }

custodyPath :: SqliteTerritoryCustody -> FilePath
custodyPath c = c.path

-- | @SqliteTerritoryCustody(path)@ with the wall clock.
openTerritoryCustody :: FilePath -> IO SqliteTerritoryCustody
openTerritoryCustody path' = openTerritoryCustodyWith path' (realToFrac <$> getPOSIXTime)

-- | @SqliteTerritoryCustody(path, clock=...)@.
openTerritoryCustodyWith :: FilePath -> IO Double -> IO SqliteTerritoryCustody
openTerritoryCustodyWith path' clock' = do
  preparePath path'
  fence' <- openWriterFence fenceTexts path'
  lock' <- newMVar ()
  ( do
      db <- openDatabase path'
      ( do
          Files.setFileMode path' 0o600
          execute_ db "PRAGMA journal_mode = DELETE"
          execute_ db "PRAGMA synchronous = FULL"
          execute_ db "PRAGMA secure_delete = ON"
          execute_ db createTableSql
          execute_ db createIndexSql
          pure (SqliteTerritoryCustody path' clock' fence' lock' db)
        )
        `onException` closeDatabase db
    )
    `onException` closeFence fence'

withLock :: SqliteTerritoryCustody -> IO a -> IO a
withLock c action = withMVar c.lock (const action)

-- | Transfer authority for exactly one release of one durable intent.
data ReleaseTicket = ReleaseTicket
  { ledger :: SqliteTerritoryCustody
  , expected :: TerritoryCustodyRecord
  , used :: IORef Bool
  }

ticketAdmission :: ReleaseTicket -> ReleaseAdmission
ticketAdmission t = ReleaseAdmission $ \binding coords _stages archive' -> do
  wasUsed <- readIORef t.used
  when wasUsed $ throwAgenticus StorageError "territory release ticket was already consumed"
  when (coords /= t.expected.source || bindingLeaseIdentity binding /= leaseIdentity t.expected.lease) $
    throwAgenticus StorageError "territory release does not match durable transfer intent"
  writeIORef t.used True
  bindingRelease binding (\lease' -> acceptRelease' t.ledger t.expected lease' archive')

-- | Write transfer intent before the host closes an Episode Attachment.
beginRelease :: SqliteTerritoryCustody -> Text -> Text -> EpisodeAttachment -> Double -> IO ReleaseTicket
beginRelease c custody owner attachment retainUntil' = do
  ensureFence c.fence
  requireText "territory custody id" custody
  requireText "territory custody owner" owner
  now <- c.clock
  when (isNaN retainUntil' || isInfinite retainUntil' || retainUntil' <= now) $
    throwAgenticus ValueError "territory retention expiry must be finite and in the future"
  binding <-
    maybe (throwAgenticus TypeError "territory retention requires an exact Motus binding") pure (episodeBinding attachment).motus
  execution <- bindingExecution binding
  let lease' = attachmentLease execution
  source' <- coordinates attachment
  withLock c $ do
    current <- lookupUnlocked c custody
    generation' <- case current of
      Nothing -> pure 1
      Just r
        | r.phase == Attached
            && r.ownerId == owner
            && r.targetEpisodeId == Just source'.episodeId
            && r.targetAttachmentId == Just source'.attachmentId
            && r.targetEpoch == Just source'.attachmentEpoch
            && leaseIdentity r.lease == leaseIdentity lease' ->
            pure (r.generation + 1)
      _ -> throwAgenticus StorageError "territory custody id is not releasable by this Attachment"
    let capabilities = Array [String (capabilityKey cap) | cap <- Set.toAscList (leaseCapabilities lease')]
        compact = J.defaultDumps {J.itemSeparator = Just ",", J.keySeparator = ":"}
    capabilityJson <- either (const (throwAgenticus ValueError "capabilities are not serializable")) pure (J.dumpsText compact capabilities)
    write
      c
      insertReleaseSql
      [ SQLText custody
      , SQLText owner
      , SQLInteger (fromInteger generation')
      , SQLText (phaseText Releasing)
      , SQLText source'.episodeId
      , SQLText source'.attachmentId
      , SQLInteger (fromInteger source'.attachmentEpoch)
      , SQLText (leaseOperationId lease')
      , SQLText (leaseProvider lease')
      , SQLText (leaseId lease')
      , SQLText capabilityJson
      , SQLFloat retainUntil'
      ]
      Nothing
      `catch` \(failure :: AgenticusError) ->
        if failure.errorClass == OtherError "IntegrityError"
          then throwAgenticus StorageError "territory operation already has a live custody obligation"
          else throwIO failure
    expected' <- requiredUnlocked c custody
    ReleaseTicket c expected' <$> newIORef False

-- | Begin a release and close the Attachment into it.
release :: SqliteTerritoryCustody -> Text -> Text -> EpisodeAttachment -> Double -> Double -> IO AttachmentRelease
release c custody owner attachment retainUntil' drainTimeout = do
  ticket <- beginRelease c custody owner attachment retainUntil'
  releaseTo attachment (ticketAdmission ticket) drainTimeout

-- | Reclaim only the exact retained lease into a distinct Attachment.
reclaim
  :: SqliteTerritoryCustody
  -> Text
  -> Text
  -> EnvironmentProvider
  -> EpisodeId
  -> ResolutionSnapshot
  -> Text
  -> Double
  -> Maybe ResultAdmission
  -> Maybe TargetCurrency
  -> IO EpisodeAttachment
reclaim c custody owner provider' episode snapshot attachmentId' deadline admission' target' = do
  ensureFence c.fence
  requireText "territory target attachment" attachmentId'
  when (isNothing (snapshotDescriptor KindHands snapshot) || isNothing (snapshotDescriptor KindTerritory snapshot)) $
    throwAgenticus ValueError "territory reclaim snapshot must select Hands and Territory descriptors"
  when (isNaN deadline || isInfinite deadline) $ throwAgenticus ValueError "territory reclaim deadline must be finite"
  (current, nextEpoch) <- withLock c $ do
    row <- selectOne c selectOneSql [SQLText custody]
    raw <- maybe (throwAgenticus StorageError "territory custody record is absent") pure row
    current <- case decodeRow raw of
      Right record -> pure record
      Left _ -> (salvageCorrupt c raw >> decodeOrThrow raw)
    when (current.ownerId /= owner || current.phase /= Retained) $
      throwAgenticus StorageError "territory custody is not retained by this owner"
    when (lifecycleIdText episode == current.source.episodeId || attachmentId' == current.source.attachmentId) $
      throwAgenticus ValueError "territory reclaim requires a distinct Episode and attachment identity"
    now <- c.clock
    when (current.retainUntil <= now) $ do
      setPhase c custody Retained Retiring
      throwAgenticus StorageError "territory custody expired before reclaim"
    observed <- providerLookup provider' (leaseOperationId current.lease)
    case observed of
      Just found | leaseState found == Ready -> do
        when (leaseIdentity found /= leaseIdentity current.lease) $ do
          setPhase c custody Retained Retiring
          throwAgenticus StorageError "retained territory identity conflicts with provider lookup"
      _ -> do
        setPhase c custody Retained Retiring
        throwAgenticus StorageError "retained territory is absent or not ready"
    let nextEpoch = current.source.attachmentEpoch + 1
    write
      c
      claimSql
      [ SQLText (phaseText Claiming)
      , SQLText (lifecycleIdText episode)
      , SQLText attachmentId'
      , SQLInteger (fromInteger nextEpoch)
      , SQLText custody
      , SQLText (phaseText Retained)
      ]
      (Just 1)
    pure (current, nextEpoch)
  (archive', digest) <- case (current.archive, current.archiveDigest) of
    (Just a, Just d) -> pure (a, d)
    _ -> throwAgenticus StorageError "retained territory phase requires a durable archive"
  attachment <-
    ( do
        binding <- reclaimExactMotusBinding provider' (leaseIdentity current.lease) archive' digest
        newEpisodeAttachment
          episode
          snapshot
          (motusBinding binding)
          attachmentId'
          deadline
          episodeOptions {attachmentEpoch = nextEpoch, admission = admission', target = target'}
      )
      `onSyncException` withLock c (setPhase c custody Claiming Retiring)
  withLock c (setPhase c custody Claiming Attached)
  pure attachment

-- | Fence ambiguous active/releasing custody and expire retained records.
recover :: SqliteTerritoryCustody -> IO [TerritoryCustodyRecord]
recover c = do
  ensureFence c.fence
  withLock c $ do
    now <- c.clock
    write
      c
      recoverSql
      [ SQLText (phaseText Retiring)
      , SQLText (phaseText Releasing)
      , SQLText (phaseText Claiming)
      , SQLText (phaseText Attached)
      , SQLText (phaseText Retained)
      , SQLFloat now
      ]
      Nothing
    rows <- selectAll c selectAllSql []
    forM rows $ \row -> case decodeRow row of
      Right record -> pure record
      Left _ ->
        salvageCorrupt c row >>= \case
          Quarantined -> throwAgenticus StorageError "malformed territory identity was quarantined"
          _ -> do
            updated <- selectOne c selectOneSql [head' row]
            maybe (throwAgenticus StorageError "territory custody record is absent") decodeOrThrow updated
  where
    head' = \case
      value : _ -> value
      [] -> SQLNull

-- | Destroy only the exact recorded lease and retain a bounded tombstone.
retire :: SqliteTerritoryCustody -> Text -> Text -> EnvironmentProvider -> IO TerritoryCustodyRecord
retire c custody owner provider' = do
  ensureFence c.fence
  step <- withLock c $ do
    current0 <- requiredUnlocked c custody
    when (current0.ownerId /= owner) $ throwAgenticus StorageError "territory custody belongs to a different owner"
    if current0.phase == Retired
      then pure (Left current0)
      else do
        current <-
          if current0.phase == Retained
            then setPhase c custody Retained Retiring >> requiredUnlocked c custody
            else pure current0
        when (current.phase /= Retiring) $ throwAgenticus StorageError "territory custody is not safe to retire"
        observed <- providerLookup provider' (leaseOperationId current.lease)
        case observed of
          Just found
            | leaseIdentity found /= leaseIdentity current.lease ->
                throwAgenticus StorageError "territory retirement refuses a foreign current lease"
          _ -> pure ()
        pure (Right (current, maybe current.lease id observed))
  case step of
    Left done -> pure done
    Right (current, lease') -> do
      result <- providerDestroy provider' lease'
      if result.cleanupIdentity /= leaseIdentity current.lease || not (cleanupVerified result)
        then withLock c (requiredUnlocked c custody)
        else withLock c $ do
          write
            c
            retiredSql
            [ SQLText (phaseText Retired)
            , SQLText (cleanupDispositionText result.cleanupDisposition)
            , SQLText custody
            , SQLText (phaseText Retiring)
            ]
            (Just 1)
          requiredUnlocked c custody

lookupCustody :: SqliteTerritoryCustody -> Text -> IO (Maybe TerritoryCustodyRecord)
lookupCustody c custody = do
  ensureFence c.fence
  requireText "territory custody id" custody
  withLock c (selectOne c selectOneSql [SQLText custody]) >>= traverse decodeOrThrow

records :: SqliteTerritoryCustody -> IO [TerritoryCustodyRecord]
records c = do
  ensureFence c.fence
  withLock c (selectAll c selectAllSql []) >>= traverse decodeOrThrow

closeTerritoryCustody :: SqliteTerritoryCustody -> IO ()
closeTerritoryCustody c = do
  open' <- fenceHeld c.fence
  when open' $ withLock c (closeDatabase c.database)
  closeFence c.fence

-- ---------------------------------------------------------------------------
-- Internals

lookupUnlocked :: SqliteTerritoryCustody -> Text -> IO (Maybe TerritoryCustodyRecord)
lookupUnlocked c custody = do
  ensureFence c.fence
  requireText "territory custody id" custody
  selectOne c selectOneSql [SQLText custody] >>= traverse decodeOrThrow

requiredUnlocked :: SqliteTerritoryCustody -> Text -> IO TerritoryCustodyRecord
requiredUnlocked c custody =
  lookupUnlocked c custody >>= maybe (throwAgenticus StorageError "territory custody record is absent") pure

acceptRelease' :: SqliteTerritoryCustody -> TerritoryCustodyRecord -> EnvironmentLease -> ByteString -> IO ()
acceptRelease' c expected' lease' archive' = do
  when (lease' /= expected'.lease || B.length archive' > maxWorkspaceArchiveBytes) $
    throwAgenticus StorageError "territory release differs from durable transfer intent"
  let digest = sha256Hex archive'
  withLock c $ do
    now <- c.clock
    when (expected'.retainUntil <= now) $ do
      setPhase c expected'.custodyId Releasing Retiring
      throwAgenticus StorageError "territory retention expired during release"
    write
      c
      acceptSql
      [ SQLText (phaseText Retained)
      , SQLBlob archive'
      , SQLText digest
      , SQLText expected'.custodyId
      , SQLInteger (fromInteger expected'.generation)
      , SQLText (phaseText Releasing)
      ]
      (Just 1)

setPhase :: SqliteTerritoryCustody -> Text -> TerritoryCustodyPhase -> TerritoryCustodyPhase -> IO ()
setPhase c custody expected' phase' =
  write c setPhaseSql [SQLText (phaseText phase'), SQLText custody, SQLText (phaseText expected')] (Just 1)

-- | @_salvage_corrupt@: an intact destruction identity becomes a clean
-- retirable obligation; anything else is quarantined and never reaches a
-- provider.
salvageCorrupt :: SqliteTerritoryCustody -> [SqlValue] -> IO TerritoryCustodyPhase
salvageCorrupt c row = case salvageableIdentity row of
  Nothing -> do
    let key = case row of
          value : _ -> value
          [] -> SQLNull
    write c quarantineSql [SQLText (phaseText Quarantined), key] (Just 1)
    pure Quarantined
  Just custody -> do
    write c setPhaseRawSql [SQLText (phaseText Retiring), SQLText custody] (Just 1)
    pure Retiring

-- | @_write@: one immediate transaction with an optional exact row count.
write :: SqliteTerritoryCustody -> Text -> [SqlValue] -> Maybe Int -> IO ()
write c sql parameters expectedRows = do
  execute_ c.database "BEGIN IMMEDIATE"
  ( do
      runSql c.database sql parameters
      changed <- changedRows c.database
      case expectedRows of
        Just n | changed /= n -> throwAgenticus StorageError "territory custody write lost its expected state"
        _ -> pure ()
      execute_ c.database "COMMIT"
    )
    `onException` rollback
  where
    rollback = do
      active <- inTransaction c.database
      when active $ execute_ c.database "ROLLBACK"

selectOne :: SqliteTerritoryCustody -> Text -> [SqlValue] -> IO (Maybe [SqlValue])
selectOne c = queryRow c.database

selectAll :: SqliteTerritoryCustody -> Text -> [SqlValue] -> IO [[SqlValue]]
selectAll c = queryRows c.database

onSyncException :: IO a -> IO () -> IO a
onSyncException action handler =
  try action >>= \case
    Right value -> pure value
    Left (e :: SomeException)
      | isAsync e -> throwIO e
      | otherwise -> handler >> throwIO e

-- ---------------------------------------------------------------------------
-- Path security

security :: Text -> IO a
security = throwAgenticus StorageSecurityError

-- | @_prepare_path@: an owned mode-0700 parent and an owned regular
-- mode-0600 file, neither a symlink.
preparePath :: FilePath -> IO ()
preparePath path' = do
  let parent = takeDirectory path'
  uid <- getEffectiveUserID
  isLink parent >>= \link -> when link $ security "territory custody parent must not be a symlink"
  exists <- doesPathExist parent
  unless exists $ do
    createDirectoryIfMissing True (takeDirectory parent)
    Dir.createDirectory parent 0o700
    Files.setFileMode parent 0o700
  parentStatus <- Files.getSymbolicLinkStatus parent
  unless
    ( Files.isDirectory parentStatus
        && permissionBits parentStatus == 0o700
        && Files.fileOwner parentStatus == uid
    )
    $ security "territory custody parent must be an owned mode-0700 directory"
  isLink path' >>= \link -> when link $ security "territory custody file must not be a symlink"
  fileExists <- doesPathExist path'
  unless fileExists $ do
    fd <- PIO.openFd path' PIO.WriteOnly PIO.defaultFileFlags {PIO.creat = Just 0o600, PIO.exclusive = True, PIO.nofollow = True}
    PIO.closeFd fd
  status <- Files.getSymbolicLinkStatus path'
  unless
    ( Files.isRegularFile status
        && permissionBits status == 0o600
        && Files.fileOwner status == uid
    )
    $ security "territory custody file must be owned regular mode-0600"

isLink :: FilePath -> IO Bool
isLink target =
  (Files.isSymbolicLink <$> Files.getSymbolicLinkStatus target)
    `catch` \(_ :: IOError) -> pure False

permissionBits :: Files.FileStatus -> FileMode
permissionBits status = Files.fileMode status `Files.intersectFileModes` 0o7777

-- ---------------------------------------------------------------------------
-- Writer fence

fenceTexts :: FenceTexts
fenceTexts =
  FenceTexts
    { unavailable = Nothing
    , notOwned = "territory custody writer fence must be owned regular mode-0600"
    , live = "territory custody already has a live writer"
    , unlockable = "territory custody writer fence could not be locked"
    , closed = "territory custody writer is closed"
    , forked = "territory custody cannot be used across fork"
    }
