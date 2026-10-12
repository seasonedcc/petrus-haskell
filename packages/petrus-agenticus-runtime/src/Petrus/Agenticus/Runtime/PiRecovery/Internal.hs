-- | The implementation of "Petrus.Agenticus.Runtime.PiRecovery". Besides its public
-- interface it exports what the tests and the differential corpus reach:
-- helpers exposed for the differential corpus.
--
-- Not a stable interface: other code imports "Petrus.Agenticus.Runtime.PiRecovery".
module Petrus.Agenticus.Runtime.PiRecovery.Internal
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
    -- * Helpers exposed for the differential corpus
  , pyIntBase16
  ) where

import Control.Concurrent.MVar
import Prelude hiding (sequence)
import Control.Exception (SomeException, fromException, onException, throwIO, try)
import Control.Monad (forM, unless, void, when)
import Data.Char (GeneralCategory (..), generalCategory, isHexDigit, isSpace)
import Data.IORef
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Petrus.Agenticus.Internal.Exception
import Petrus.Json.Repr (pythonReprFloat)
import Petrus.Agenticus.Error
import Petrus.Json.Python (pythonBytesRepr, pythonStrRepr)
import Petrus.Agenticus.Internal.Sqlite
import Petrus.Agenticus.Internal.WriterFence
import Petrus.Agenticus.Internal.Validate (checkedText)
import Petrus.Agenticus.Runtime.Operation
  ( RuntimeCleanupDisposition (..)
  , RuntimeOperation (..)
  , RuntimeOperationCleanup
  , mkRuntimeOperationCleanup
  , runtimeProtocolError
  , runtimeProtocolErrorCode
  )
import Petrus.Agenticus.Runtime.Pi
  ( PiRuntimeAdapter
  , PiRuntimeConfig
  , PiRuntimeInvocation (..)
  , adapterConfig
  , evictPi
  , piDurableFingerprint
  , piRuntimeOperation
  , receiptPi
  , startPi
  )
import Petrus.Agenticus.Runtime.Result (RuntimeTurnSettlement, mkRuntimeTurnSettlement, safeTerminationCode)
import Petrus.Agenticus.Thread.Identity (EpisodeId, LifecycleId (..), TurnId, mkEpisodeId, mkTurnId)
import Petrus.Agenticus.Thread.Lifecycle (CancellationDisposition (..), StrEnum (..), TurnOutcome (..), parseStrEnum)
import System.Directory (createDirectoryIfMissing, doesPathExist)
import System.FilePath (takeDirectory)
import System.Posix.Directory qualified as Dir
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as PIO
import System.Posix.Types (FileMode)
import System.Posix.User (getEffectiveUserID)

-- ---------------------------------------------------------------------------
-- Records

data PiOperationPhase = PhaseExecuting | PhaseSettled
  deriving stock (Eq, Show, Enum, Bounded)

phaseText :: PiOperationPhase -> Text
phaseText = \case
  PhaseExecuting -> "executing"
  PhaseSettled -> "settled"

-- | @_text(value, name, maximum=512)@.
recoveryText :: Text -> Int -> Text -> Either AgenticusError Text
recoveryText name bound = checkedText bound (valueError (name <> " must be bounded non-empty text"))

-- | Secret-free durable operation identity, terminal refs, and cleanup state.
data PiOperationRecord = PiOperationRecord
  { operationId :: Text
  , fingerprint :: Text
  , episodeId :: EpisodeId
  , turnId :: TurnId
  , sequence :: Integer
  , phase :: PiOperationPhase
  , outcome :: Maybe TurnOutcome
  , acceptedAppends :: Maybe Integer
  , terminationCode :: Maybe Text
  , outputReference :: Maybe Text
  , continuationReference :: Maybe Text
  , cleanup :: RuntimeCleanupDisposition
  , cleanupCode :: Text
  , acknowledged :: Bool
  }
  deriving stock (Eq, Show)

-- | A fresh executing record with the reference's defaults.
executingRecord :: Text -> Text -> EpisodeId -> TurnId -> Integer -> PiOperationRecord
executingRecord operationId fingerprint episodeId turnId sequence =
  PiOperationRecord
    { operationId
    , fingerprint
    , episodeId
    , turnId
    , sequence
    , phase = PhaseExecuting
    , outcome = Nothing
    , acceptedAppends = Nothing
    , terminationCode = Nothing
    , outputReference = Nothing
    , continuationReference = Nothing
    , cleanup = RuntimeCleanupUnverified
    , cleanupCode = "cleanup-uncertain"
    , acknowledged = False
    }

-- | @PiOperationRecord.__post_init__@.
mkPiOperationRecord :: PiOperationRecord -> Either AgenticusError PiOperationRecord
mkPiOperationRecord r = do
  _ <- recoveryText "Pi operation" 256 r.operationId
  unless (T.length r.fingerprint == 64 && pyIntBase16 r.fingerprint) $
    Left (valueError "Pi operation fingerprint must be SHA-256")
  when (r.sequence <= 0) $ Left (valueError "Pi operation sequence must be positive")
  _ <- safeTerminationCode r.cleanupCode
  case r.phase of
    PhaseExecuting ->
      when
        ( isJust r.outcome
            || isJust r.acceptedAppends
            || isJust r.terminationCode
            || isJust r.outputReference
            || isJust r.continuationReference
            || r.cleanup /= RuntimeCleanupUnverified
            || r.cleanupCode /= "cleanup-uncertain"
            || r.acknowledged
        )
        $ Left (valueError "executing Pi operation cannot contain terminal state")
    PhaseSettled -> void (recordSettlement r)
  pure r

-- | @record.settlement()@.
recordSettlement :: PiOperationRecord -> Either AgenticusError RuntimeTurnSettlement
recordSettlement r = case (r.phase, r.outcome, r.acceptedAppends, r.terminationCode) of
  (PhaseExecuting, _, _, _) -> Left (runtimeProtocolError "operation-active")
  (PhaseSettled, Just outcome, Just appends, Just code) ->
    mkRuntimeTurnSettlement r.episodeId r.turnId outcome appends code r.outputReference r.continuationReference
  _ -> Left (valueError "settled Pi operation requires complete terminal state")

-- | @record.cleanup_evidence()@.
recordCleanupEvidence :: PiOperationRecord -> Either AgenticusError RuntimeOperationCleanup
recordCleanupEvidence r = mkRuntimeOperationCleanup r.operationId r.cleanup r.cleanupCode False

-- | Whether CPython's @int(value, 16)@ accepts the text: surrounding
-- whitespace, one sign, an optional @0x@ prefix, and hexadecimal digits
-- (any Unicode decimal digit counts) separated by single underscores.
pyIntBase16 :: Text -> Bool
pyIntBase16 raw =
  let stripped = T.dropAround isSpace raw
      unsigned = maybe stripped snd (T.uncons stripped >>= \(c, rest) -> if c `elem` ['+', '-'] then Just (c, rest) else Nothing)
      (prefixed, body) = case T.take 2 unsigned of
        p | T.toLower p == "0x" -> (True, T.drop 2 unsigned)
        _ -> (False, unsigned)
      groups = T.splitOn "_" body
      digit c = isHexDigit c || generalCategory c == DecimalNumber
      leadingUnderscore = prefixed && T.isPrefixOf "_" body
      groups' = if leadingUnderscore then drop 1 groups else groups
   in not (T.null body)
        && not (null groups')
        && all (\g -> not (T.null g) && T.all digit g) groups'

-- ---------------------------------------------------------------------------
-- Ledgers

-- | @PiOperationLedger@: the durable operations the recovered runtime needs.
data PiOperationLedger = PiOperationLedger
  { recover :: IO [PiOperationRecord]
  , admit :: Text -> Text -> EpisodeId -> TurnId -> IO PiOperationRecord
  , lookup :: Text -> IO (Maybe PiOperationRecord)
  , records :: IO [PiOperationRecord]
  , settle :: Text -> RuntimeTurnSettlement -> IO PiOperationRecord
  , upgradeCleanup :: Text -> RuntimeOperationCleanup -> IO PiOperationRecord
  , acknowledge :: Text -> IO PiOperationRecord
  , watermark :: IO Integer
  , close :: IO ()
  }

-- | Private SQLite ledger with one fail-loud, process-fenced writer.
data SqlitePiOperationLedger = SqlitePiOperationLedger
  { path :: FilePath
  , fence :: WriterFence
  , lock :: MVar ()
  , database :: Database
  , closed :: IORef Bool
  }

ledgerPath :: SqlitePiOperationLedger -> FilePath
ledgerPath l = l.path

sqlitePiOperationLedger :: SqlitePiOperationLedger -> PiOperationLedger
sqlitePiOperationLedger l =
  PiOperationLedger
    { recover = ledgerRecover l
    , admit = ledgerAdmit l
    , lookup = ledgerLookup l
    , records = ledgerRecords l
    , settle = ledgerSettle l
    , upgradeCleanup = ledgerUpgradeCleanup l
    , acknowledge = ledgerAcknowledge l
    , watermark = ledgerWatermark l
    , close = ledgerClose l
    }

-- | The reference's exact @CREATE TABLE@ text, whitespace included.
createTableSql :: Text
createTableSql =
  T.intercalate
    "\n"
    [ "CREATE TABLE IF NOT EXISTS pi_operations ("
    , "                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,"
    , "                    operation_id TEXT NOT NULL UNIQUE, fingerprint TEXT NOT NULL,"
    , "                    episode_id TEXT NOT NULL, turn_id TEXT NOT NULL, phase TEXT NOT NULL,"
    , "                    outcome TEXT, accepted_appends INTEGER, termination_code TEXT,"
    , "                    output_reference TEXT, continuation_reference TEXT,"
    , "                    cleanup TEXT NOT NULL, cleanup_code TEXT NOT NULL,"
    , "                    acknowledged INTEGER NOT NULL CHECK (acknowledged IN (0, 1)))"
    ]

recoverSql, insertSql, settleSql, upgradeSql, acknowledgeSql, lookupSql, recordsSql, executingSql :: Text
recoverSql =
  T.intercalate
    "\n"
    [ "UPDATE pi_operations SET phase = ?, outcome = ?, accepted_appends = 0,"
    , "                       termination_code = ?, output_reference = NULL, continuation_reference = NULL,"
    , "                       cleanup = ?, cleanup_code = ?, acknowledged = 0 WHERE phase = ?"
    ]
insertSql =
  T.intercalate
    "\n"
    [ "INSERT INTO pi_operations"
    , "                   (operation_id, fingerprint, episode_id, turn_id, phase, cleanup, cleanup_code, acknowledged)"
    , "                   VALUES (?, ?, ?, ?, ?, ?, ?, 0)"
    ]
settleSql =
  T.intercalate
    "\n"
    [ "UPDATE pi_operations SET phase = ?, outcome = ?, accepted_appends = ?, termination_code = ?,"
    , "                   output_reference = ?, continuation_reference = ? WHERE operation_id = ? AND phase = ?"
    ]
upgradeSql = "UPDATE pi_operations SET cleanup = ?, cleanup_code = ? WHERE operation_id = ?"
acknowledgeSql = "UPDATE pi_operations SET acknowledged = 1 WHERE operation_id = ? AND acknowledged = 0"
lookupSql = "SELECT * FROM pi_operations WHERE operation_id = ?"
recordsSql = "SELECT * FROM pi_operations ORDER BY sequence"
executingSql = "SELECT operation_id FROM pi_operations WHERE phase = ? ORDER BY sequence"

-- | @SqlitePiOperationLedger(path)@.
openSqlitePiOperationLedger :: FilePath -> IO SqlitePiOperationLedger
openSqlitePiOperationLedger path = do
  preparePath path
  fence <- openWriterFence fenceTexts path
  lock <- newMVar ()
  closed <- newIORef False
  ( do
      db <- openDatabase path
      ( do
          Files.setFileMode path 0o600
          execute_ db "PRAGMA journal_mode = DELETE"
          execute_ db "PRAGMA synchronous = FULL"
          execute_ db createTableSql
          pure SqlitePiOperationLedger {path, fence, lock, database = db, closed}
        )
        `onException` closeDatabase db
    )
    `onException` closeFence fence

withLock :: SqlitePiOperationLedger -> IO a -> IO a
withLock l action = withMVar l.lock (const action)

-- | Fence every operation whose prior process may have crossed the provider.
ledgerRecover :: SqlitePiOperationLedger -> IO [PiOperationRecord]
ledgerRecover l = do
  ensureFence l.fence
  withLock l $ do
    rows <- selectAll l executingSql [SQLText (phaseText PhaseExecuting)]
    let operationIds = [pyStr value | value : _ <- rows]
    unless (null operationIds) $
      write
        l
        recoverSql
        [ SQLText (phaseText PhaseSettled)
        , SQLText (enumText TurnIndeterminate)
        , SQLText "restart-indeterminate"
        , SQLText (enumText RuntimeCleanupUnverified)
        , SQLText "cleanup-uncertain"
        , SQLText (phaseText PhaseExecuting)
        ]
        (Just (length operationIds))
    forM operationIds (required l)

ledgerAdmit :: SqlitePiOperationLedger -> Text -> Text -> EpisodeId -> TurnId -> IO PiOperationRecord
ledgerAdmit l operationId fingerprint episodeId turnId = do
  ensureFence l.fence
  candidate <- throwLeft (mkPiOperationRecord (executingRecord operationId fingerprint episodeId turnId 1))
  withLock l $
    lookupUnlocked l operationId >>= \case
      Just existing -> pure existing
      Nothing -> do
        write
          l
          insertSql
          [ SQLText candidate.operationId
          , SQLText candidate.fingerprint
          , SQLText (lifecycleIdText episodeId)
          , SQLText (lifecycleIdText turnId)
          , SQLText (phaseText PhaseExecuting)
          , SQLText (enumText RuntimeCleanupUnverified)
          , SQLText "cleanup-uncertain"
          ]
          (Just 1)
        required l operationId

ledgerLookup :: SqlitePiOperationLedger -> Text -> IO (Maybe PiOperationRecord)
ledgerLookup l operationId = withLock l (lookupUnlocked l operationId)

lookupUnlocked :: SqlitePiOperationLedger -> Text -> IO (Maybe PiOperationRecord)
lookupUnlocked l operationId = do
  ensureFence l.fence
  _ <- throwLeft (recoveryText "Pi operation" 256 operationId)
  row <- selectOne l lookupSql [SQLText operationId]
  traverse decode row

ledgerRecords :: SqlitePiOperationLedger -> IO [PiOperationRecord]
ledgerRecords l = do
  ensureFence l.fence
  rows <- withLock l (selectAll l recordsSql [])
  decoded <- traverse decode rows
  when (map (.sequence) decoded /= [1 .. toInteger (length decoded)]) $
    throwAgenticus StorageError "Pi operation ledger sequence is not dense"
  pure decoded

ledgerSettle :: SqlitePiOperationLedger -> Text -> RuntimeTurnSettlement -> IO PiOperationRecord
ledgerSettle l operationId settlement = do
  ensureFence l.fence
  withLock l $ do
    current <- required l operationId
    when ((current.episodeId, current.turnId) /= (settlement.episodeId, settlement.turnId)) $
      throwIO (runtimeProtocolError "operation-conflict")
    case current.phase of
      PhaseSettled -> do
        existing <- throwLeft (recordSettlement current)
        when (existing /= settlement) $ throwIO (runtimeProtocolError "operation-conflict")
        pure current
      PhaseExecuting -> do
        write
          l
          settleSql
          [ SQLText (phaseText PhaseSettled)
          , SQLText (enumText settlement.outcome)
          , SQLInteger (fromInteger settlement.acceptedAppends)
          , SQLText settlement.terminationCode
          , maybe SQLNull SQLText settlement.outputReference
          , maybe SQLNull SQLText settlement.continuationReference
          , SQLText operationId
          , SQLText (phaseText PhaseExecuting)
          ]
          (Just 1)
        required l operationId

ledgerUpgradeCleanup :: SqlitePiOperationLedger -> Text -> RuntimeOperationCleanup -> IO PiOperationRecord
ledgerUpgradeCleanup l operationId evidence = do
  ensureFence l.fence
  when (evidence.operationId /= operationId) $ throwIO (runtimeProtocolError "operation-conflict")
  withLock l $ do
    current <- required l operationId
    when (current.phase /= PhaseSettled) $ throwIO (runtimeProtocolError "operation-active")
    existing <- throwLeft (recordCleanupEvidence current)
    if
      | current.cleanup /= RuntimeCleanupUnverified
          || evidence.disposition `notElem` [RuntimeCleanupClean, RuntimeCleanupNotCreated] -> do
          when (existing /= evidence) $ throwIO (runtimeProtocolError "operation-conflict")
          pure current
      | otherwise -> do
          write
            l
            upgradeSql
            [SQLText (enumText evidence.disposition), SQLText evidence.code, SQLText operationId]
            (Just 1)
          required l operationId

ledgerAcknowledge :: SqlitePiOperationLedger -> Text -> IO PiOperationRecord
ledgerAcknowledge l operationId = do
  ensureFence l.fence
  withLock l $ do
    current <- required l operationId
    when (current.phase /= PhaseSettled) $ throwIO (runtimeProtocolError "operation-active")
    unless current.acknowledged $ write l acknowledgeSql [SQLText operationId] (Just 1)
    required l operationId

ledgerWatermark :: SqlitePiOperationLedger -> IO Integer
ledgerWatermark l = do
  ensureFence l.fence
  go 0 <$> ledgerRecords l
  where
    go mark = \case
      r : rest | r.phase == PhaseSettled && r.acknowledged -> go r.sequence rest
      _ -> mark

ledgerClose :: SqlitePiOperationLedger -> IO ()
ledgerClose l = do
  withLock l $ do
    wasClosed <- atomicModifyIORef' l.closed (True,)
    unless wasClosed $ closeDatabase l.database
  closeFence l.fence

required :: SqlitePiOperationLedger -> Text -> IO PiOperationRecord
required l operationId =
  lookupUnlocked l operationId >>= maybe (throwIO (runtimeProtocolError "operation-absent")) pure

-- | @_write@: one immediate transaction with an exact row count.
write :: SqlitePiOperationLedger -> Text -> [SqlValue] -> Maybe Int -> IO ()
write l sql parameters expectedRows = do
  control "BEGIN IMMEDIATE"
  ( do
      runSql l.database sql parameters
      changed <- changedRows l.database
      case expectedRows of
        Just n | changed /= n -> throwAgenticus StorageError "Pi operation ledger write lost its expected state"
        _ -> pure ()
      control "COMMIT"
    )
    `onException` rollback
  where
    control statement = runSql l.database statement []
    rollback = do
      active <- inTransaction l.database
      when active $ control "ROLLBACK"

-- Statements run through the connection's prepared-statement cache, as
-- CPython's @sqlite3@ keeps the reference's. Callers hold the ledger's lock.
selectOne :: SqlitePiOperationLedger -> Text -> [SqlValue] -> IO (Maybe [SqlValue])
selectOne l = queryRow l.database

selectAll :: SqlitePiOperationLedger -> Text -> [SqlValue] -> IO [[SqlValue]]
selectAll l = queryRows l.database

-- | @str(value)@ of a column value.
pyStr :: SqlValue -> Text
pyStr = \case
  SQLText t -> t
  SQLInteger n -> T.pack (show n)
  SQLFloat x -> T.pack (pythonReprFloat x)
  SQLNull -> "None"
  SQLBlob b -> pythonBytesRepr b

-- | @_decode(row)@.
decode :: [SqlValue] -> IO PiOperationRecord
decode row = case row of
  [sequence', operationId, fingerprint, episode, turn, phase', outcome', appends, code, output, continuation, cleanup', cleanupCode, acknowledged'] -> do
    episodeId <- throwLeft (mkEpisodeId (pyStr episode))
    turnId <- throwLeft (mkTurnId (pyStr turn))
    phase <- enumValue "PiOperationPhase" (pyStr phase')
    outcome <- case outcome' of
      SQLNull -> pure Nothing
      value -> Just <$> enumValue "TurnOutcome" (pyStr value)
    cleanup <- enumValue "RuntimeCleanupDisposition" (pyStr cleanup')
    sequence <- integer "sequence" sequence'
    acceptedAppends <- case appends of
      SQLNull -> pure Nothing
      -- A REAL cell reaches the reference's record as a float: an integral
      -- one compares equal to that integer, and any other fails the
      -- record's own checks exactly as an out-of-range integer does.
      SQLFloat x
        | not (isNaN x) && x == fromInteger (round x) -> pure (Just (round x))
        | otherwise -> pure (Just (-1))
      value -> Just <$> integer "accepted_appends" value
    throwLeft . mkPiOperationRecord $
      PiOperationRecord
        { operationId = pyStr operationId
        , fingerprint = pyStr fingerprint
        , episodeId
        , turnId
        , sequence
        , phase
        , outcome
        , acceptedAppends
        , terminationCode = optional code
        , outputReference = optional output
        , continuationReference = optional continuation
        , cleanup
        , cleanupCode = pyStr cleanupCode
        , acknowledged = truthy acknowledged'
        }
  _ -> throwAgenticus StorageError "Pi operation ledger row has an unexpected shape"
  where
    optional = \case
      SQLNull -> Nothing
      value -> Just (pyStr value)
    integer name = \case
      SQLInteger n -> pure (toInteger (n :: Int64))
      _ -> throwIO (valueError ("Pi operation " <> name <> " must be an integer column"))
    truthy = \case
      SQLInteger n -> n /= 0
      SQLFloat x -> x /= 0
      SQLText t -> not (T.null t)
      SQLBlob b -> b /= mempty
      SQLNull -> False

-- | @Cls(value)@ for a @StrEnum@-like class.
class Parseable a where
  parseValue :: Text -> Maybe a

instance Parseable PiOperationPhase where
  parseValue t = Prelude.lookup t [(phaseText p, p) | p <- [minBound .. maxBound]]

instance Parseable TurnOutcome where
  parseValue = parseStrEnum

instance Parseable RuntimeCleanupDisposition where
  parseValue = parseStrEnum

enumValue :: (Parseable a) => Text -> Text -> IO a
enumValue cls value =
  maybe (throwIO (valueError (pythonStrRepr value <> " is not a valid " <> cls))) pure (parseValue value)

-- ---------------------------------------------------------------------------
-- Path security

security :: Text -> IO a
security = throwAgenticus StorageSecurityError

-- | @_prepare_path@: an owned mode-0700 parent and an owned regular
-- mode-0600 file, neither a symlink.
preparePath :: FilePath -> IO ()
preparePath path = do
  let parent = takeDirectory path
  uid <- getEffectiveUserID
  isLink parent >>= \link -> when link $ security "Pi ledger parent must not be a symlink"
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
    $ security "Pi ledger parent must be an owned mode-0700 directory"
  isLink path >>= \link -> when link $ security "Pi ledger file must not be a symlink"
  fileExists <- doesPathExist path
  unless fileExists $ do
    fd <- PIO.openFd path PIO.WriteOnly PIO.defaultFileFlags {PIO.creat = Just 0o600, PIO.exclusive = True, PIO.nofollow = True}
    PIO.closeFd fd
  status <- Files.getSymbolicLinkStatus path
  unless
    ( Files.isRegularFile status
        && permissionBits status == 0o600
        && Files.fileOwner status == uid
    )
    $ security "Pi ledger file must be owned regular mode-0600"

isLink :: FilePath -> IO Bool
isLink target =
  (Files.isSymbolicLink <$> Files.getSymbolicLinkStatus target)
    `catchIO` pure False
  where
    catchIO action fallback = try action >>= either (\(_ :: IOError) -> fallback) pure

permissionBits :: Files.FileStatus -> FileMode
permissionBits status = Files.fileMode status `Files.intersectFileModes` 0o7777

-- ---------------------------------------------------------------------------
-- Writer fence

fenceTexts :: FenceTexts
fenceTexts =
  FenceTexts
    { unavailable = Just "Pi ledger writer fence is unavailable"
    , notOwned = "Pi ledger writer fence must be owned regular mode-0600"
    , live = "Pi operation ledger already has a live writer"
    , unlockable = "Pi ledger writer fence could not be locked"
    , closed = "Pi operation ledger writer is closed"
    , forked = "Pi operation ledger cannot be used across fork"
    }

-- ---------------------------------------------------------------------------
-- Operations

-- | The adapter operations the recovered runtime uses. The reference's tests
-- reassign @adapter.start@ and @adapter.receipt@; a test builds this record
-- with replaced fields instead.
data PiAdapterSurface = PiAdapterSurface
  { adapter :: PiRuntimeAdapter
  , config :: PiRuntimeConfig
  , start :: PiRuntimeInvocation -> IO RuntimeOperation
  , receipt :: Text -> IO (Maybe RuntimeTurnSettlement)
  , evict :: Text -> IO Bool
  }

piAdapterSurface :: PiRuntimeAdapter -> PiAdapterSurface
piAdapterSurface a =
  PiAdapterSurface
    { adapter = a
    , config = adapterConfig a
    , start = fmap piRuntimeOperation . startPi a
    , receipt = receiptPi a
    , evict = evictPi a
    }

-- | One handle from 'startRecovered'. Handles compare by identity, as the
-- reference's @is@ does.
data PiRecoveredOperation = PiRecoveredOperation
  { identity :: IORef ()
  , operation :: RuntimeOperation
  , closedFlag :: IO Bool
  }

instance Eq PiRecoveredOperation where
  a == b = a.identity == b.identity

recoveredOperation :: PiRecoveredOperation -> RuntimeOperation
recoveredOperation o = o.operation

recoveredOperationId :: PiRecoveredOperation -> Text
recoveredOperationId o = o.operation.operationId

waitTimeoutValid :: Maybe Double -> IO ()
waitTimeoutValid = \case
  Just t | not (t > 0 && not (isInfinite t)) -> throwIO (valueError "Pi wait timeout must be positive and finite")
  _ -> pure ()

-- | @_ReplayOperation(record)@: a settled result, without adapter access.
replayOperation :: PiOperationRecord -> IO PiRecoveredOperation
replayOperation record = do
  identity <- newIORef ()
  lock <- newMVar ()
  closedRef <- newIORef Nothing
  let guarded :: IO a -> IO a
      guarded action = withMVar lock (const action)
  pure
    PiRecoveredOperation
      { identity
      , closedFlag = isJust <$> readIORef closedRef
      , operation =
          RuntimeOperation
            { operationId = record.operationId
            , wait = \bound -> do
                waitTimeoutValid bound
                guarded $ do
                  wasClosed <- isJust <$> readIORef closedRef
                  when wasClosed $ throwIO (runtimeProtocolError "operation-closed")
                  throwLeft (recordSettlement record)
            , cancel = \reason -> do
                _ <- throwLeft (recoveryText "Pi cancellation reason" 512 reason)
                guarded (pure CancellationTooLate)
            , close = guarded $
                readIORef closedRef >>= \case
                  Just evidence -> pure evidence
                  Nothing -> do
                    evidence <- throwLeft (recordCleanupEvidence record)
                    writeIORef closedRef (Just evidence)
                    pure evidence
            }
      }

-- | @_DurableOperation(inner, ledger, receipt)@: persist the settlement on
-- wait and before cleanup on close.
durableOperation :: RuntimeOperation -> PiOperationLedger -> (Text -> IO (Maybe RuntimeTurnSettlement)) -> IO PiRecoveredOperation
durableOperation inner ledger receipt = do
  identity <- newIORef ()
  lock <- newMVar ()
  closedRef <- newIORef Nothing
  let guarded :: IO a -> IO a
      guarded action = withMVar lock (const action)
      operationId = inner.operationId
  pure
    PiRecoveredOperation
      { identity
      , closedFlag = isJust <$> readIORef closedRef
      , operation =
          RuntimeOperation
            { operationId
            , wait = \bound -> guarded $ do
                wasClosed <- isJust <$> readIORef closedRef
                when wasClosed $ throwIO (runtimeProtocolError "operation-closed")
                result <- inner.wait bound
                _ <- ledger.settle operationId result
                pure result
            , cancel = inner.cancel
            , close = guarded $
                readIORef closedRef >>= \case
                  Just evidence -> pure evidence
                  Nothing -> do
                    natural <- receipt operationId
                    mapM_ (void . ledger.settle operationId) natural
                    evidence <- inner.close
                    result <-
                      receipt operationId >>= \case
                        Just result -> pure result
                        Nothing -> do
                          record <- ledger.lookup operationId >>= maybe (throwIO (runtimeProtocolError "operation-absent")) pure
                          throwLeft
                            (mkRuntimeTurnSettlement record.episodeId record.turnId TurnIndeterminate 0 "close-indeterminate" Nothing Nothing)
                    _ <- ledger.settle operationId result
                    _ <- ledger.upgradeCleanup operationId evidence
                    writeIORef closedRef (Just evidence)
                    pure evidence
            }
      }

-- ---------------------------------------------------------------------------
-- The recovered runtime

-- | Single-process Pi adapter facade with durable ambiguous-work recovery.
data PiRecoveredRuntime = PiRecoveredRuntime
  { surface :: PiAdapterSurface
  , ledger :: PiOperationLedger
  , lock :: MVar ()
  , live :: IORef [(Text, PiRecoveredOperation)]
  , recovered :: [RuntimeTurnSettlement]
  }

-- | @PiRecoveredRuntime(adapter, ledger)@.
newPiRecoveredRuntime :: PiRuntimeAdapter -> PiOperationLedger -> IO PiRecoveredRuntime
newPiRecoveredRuntime = newPiRecoveredRuntimeWith . piAdapterSurface

newPiRecoveredRuntimeWith :: PiAdapterSurface -> PiOperationLedger -> IO PiRecoveredRuntime
newPiRecoveredRuntimeWith surface ledger = do
  lock <- newMVar ()
  live <- newIORef []
  recoveredRecords <- ledger.recover
  existing <- ledger.records
  when (any (\r -> r.phase == PhaseExecuting) existing) $ throwIO (runtimeProtocolError "recovery-state-invalid")
  recovered <- traverse (throwLeft . recordSettlement) recoveredRecords
  pure PiRecoveredRuntime {surface, ledger, lock, live, recovered}

-- | @recovered_settlements@.
recoveredSettlements :: PiRecoveredRuntime -> [RuntimeTurnSettlement]
recoveredSettlements r = r.recovered

recoveredAdapter :: PiRecoveredRuntime -> PiRuntimeAdapter
recoveredAdapter r = r.surface.adapter

-- | @start(invocation)@: admit durably before dispatch; replay settled work.
startRecovered :: PiRecoveredRuntime -> PiRuntimeInvocation -> IO PiRecoveredOperation
startRecovered r inv = do
  let config = r.surface.config
  fingerprint <- throwLeft (piDurableFingerprint config inv)
  withMVar r.lock $ \_ -> do
    record <- r.ledger.admit inv.operationId fingerprint inv.episodeId inv.turnId
    when (record.fingerprint /= fingerprint) $ throwIO (runtimeProtocolError "operation-conflict")
    existing <- Prelude.lookup inv.operationId <$> readIORef r.live
    case existing of
      Just operation -> pure operation
      Nothing
        | record.phase == PhaseSettled -> replayOperation record
        | otherwise -> do
            started <- try (r.surface.start inv)
            inner <- case started of
              Right inner -> pure inner
              Left (failure :: SomeException)
                | isAsync failure -> throwIO failure
                | otherwise -> do
                let code = fromException failure >>= runtimeProtocolErrorCode
                    failedCode = fromMaybe "runtime-start-failed" code
                failed <- throwLeft (mkRuntimeTurnSettlement inv.episodeId inv.turnId TurnFailed 0 failedCode Nothing Nothing)
                _ <- r.ledger.settle inv.operationId failed
                notCreated <- throwLeft (mkRuntimeOperationCleanup inv.operationId RuntimeCleanupNotCreated "client-not-created" False)
                _ <- r.ledger.upgradeCleanup inv.operationId notCreated
                maybe (throwIO (runtimeProtocolError "runtime-start-failed")) (const (throwIO failure)) code
            operation <- durableOperation inner r.ledger r.surface.receipt
            modifyIORef' r.live (<> [(inv.operationId, operation)])
            pure operation

-- | @acknowledge(operation_id)@.
acknowledgeRecovered :: PiRecoveredRuntime -> Text -> IO PiOperationRecord
acknowledgeRecovered r = r.ledger.acknowledge

-- | @evict()@: drop closed handles at or below the acknowledged watermark.
evictRecovered :: PiRecoveredRuntime -> IO [Text]
evictRecovered r = do
  mark <- r.ledger.watermark
  withMVar r.lock $ \_ -> do
    known <- readIORef r.live
    fmap concat . forM known $ \(operationId, operation) -> do
      record <- r.ledger.lookup operationId
      isClosed <- operation.closedFlag
      case record of
        Just found
          | found.acknowledged && found.sequence <= mark && isClosed -> do
              evicted <- r.surface.evict operationId
              if evicted
                then modifyIORef' r.live (filter ((/= operationId) . fst)) >> pure [operationId]
                else pure []
        _ -> pure []
