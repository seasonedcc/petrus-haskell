-- | The host-local process territory (upstream @LocalProcessEnvironment@).
--
-- Each lease is a private temporary directory; commands run in their own
-- session (process group) with only the explicit command environment, and
-- private files live in @0700@ directories beside (never inside) the
-- workspace, manipulated only through descriptor-relative, no-follow calls.
module Petrus.Motus.Execution.Providers.Local
  ( LocalProcessEnvironment
  , LocalConfig (..)
  , defaultLocalConfig
  , newLocalProcessEnvironment
  , newLocalProcessEnvironmentWith
  , localProvider
  , localCapabilities
  , provision
    -- * Inspection (tests and diagnostics)
  , localTerritory
  , localPrivateRoot
  , localHasActiveCommand
  , localSetRemoveTree
  ) where

import Control.Concurrent (MVar, newMVar, withMVar)
import Control.Exception (IOException, SomeException, bracket, finally, fromException, mask, onException, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.IORef
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Petrus.Motus.Execution
import Petrus.Motus.Execution.Archive (extractWorkspaceArchive, workspaceArchive)
import Petrus.Motus.Execution.Internal.Common
import Petrus.Motus.Execution.Internal.PosixPath (ioErrno, lstatMaybe, pathLexists, toRawPath)
import Petrus.Posix.At
  ( FileStat (..)
  , Follow (..)
  , createExclusiveAt
  , fdStat
  , listDirectoryFd
  , mkdirAt
  , openAt
  , openDirectoryAt
  , permissionBits
  , removeDirectoryAt
  , statAt
  , unlinkAt
  )
import Petrus.Posix.At qualified as At
import Petrus.Posix.File (fsyncFd)
import Petrus.Motus.Execution.Internal.Process
import Petrus.Motus.Execution.Internal.PyText (pyStrRepr)
import System.Posix.Files.ByteString (isDirectory)
import System.Directory (doesPathExist, getTemporaryDirectory, removeDirectoryRecursive)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files.ByteString (removeLink, setFdMode)
import System.Posix.IO.ByteString (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, fdReadBuf, fdWriteBuf)
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
import System.Posix.Types (Fd)
import System.Posix.User (getRealUserID)
import Foreign.Ptr (castPtr)
import Data.ByteString.Unsafe qualified as BU
import Data.ByteString.Internal qualified as BI

-- | Bounds that upstream reads from module globals (tests patch them).
data LocalConfig = LocalConfig
  { configMaxPrivateFiles :: Int
  , configMaxPrivateTotalBytes :: Int
  }

defaultLocalConfig :: LocalConfig
defaultLocalConfig = LocalConfig maxPrivateFilesPerAttachment maxPrivateFileTotalBytes

data PrivateRecord = PrivateRecord
  { recordReference :: PrivateFileRef
  , recordRoot :: FilePath
  , recordBytes :: Int
  , recordPresent :: Bool
  , recordVerifiedAbsent :: Bool
  }

data LocalState = LocalState
  { stateLeases :: Map Text EnvironmentLease
  , stateTerritories :: Map Text FilePath
  , stateSpecs :: Map Text Text
  , stateAttachments :: Map Text ExecutionAttachment
  , stateProcesses :: Map Text Running
  , stateLaunching :: Set Text
  , statePrivateFiles :: Map Text (Map Text PrivateRecord)
  , statePrivateCleaned :: Set (Text, Text)
  }

data LocalProcessEnvironment = LocalProcessEnvironment
  { localInstanceId :: Text
  , localConfig :: LocalConfig
  , localLock :: MVar ()
  , localState :: IORef LocalState
  , localRemoveTree :: IORef (FilePath -> IO ())
  }

providerLabel :: Text
providerLabel = "local-process"

localCapabilities :: Set Capability
localCapabilities =
  Set.fromList [capCommandCancellation, capExplicitEnvironment, capPrivateFileTransfer, capProcessGroup, capWorkspace]

newLocalProcessEnvironment :: IO LocalProcessEnvironment
newLocalProcessEnvironment = newLocalProcessEnvironmentWith defaultLocalConfig

newLocalProcessEnvironmentWith :: LocalConfig -> IO LocalProcessEnvironment
newLocalProcessEnvironmentWith config = do
  instanceId <- newUuid4
  lock <- newMVar ()
  state <- newIORef (LocalState Map.empty Map.empty Map.empty Map.empty Map.empty Set.empty Map.empty Set.empty)
  remover <- newIORef removeDirectoryRecursive
  pure (LocalProcessEnvironment instanceId config lock state remover)

-- | Replace @shutil.rmtree@ for territory removal (fault injection).
localSetRemoveTree :: LocalProcessEnvironment -> (FilePath -> IO ()) -> IO ()
localSetRemoveTree env = writeIORef (localRemoveTree env)

localTerritory :: LocalProcessEnvironment -> Text -> IO (Maybe FilePath)
localTerritory env lease = Map.lookup lease . stateTerritories <$> readIORef (localState env)

-- | The private root directory of one imported file.
localPrivateRoot :: LocalProcessEnvironment -> Text -> Text -> IO (Maybe FilePath)
localPrivateRoot env lease fileId =
  fmap recordRoot . (Map.lookup fileId <=< Map.lookup lease) . statePrivateFiles <$> readIORef (localState env)
  where
    (<=<) f g x = g x >>= f

localHasActiveCommand :: LocalProcessEnvironment -> Text -> IO Bool
localHasActiveCommand env lease = Map.member lease . stateProcesses <$> readIORef (localState env)

localProvider :: LocalProcessEnvironment -> EnvironmentProvider
localProvider env =
  EnvironmentProvider
    { providerName = providerLabel
    , providerCapabilities = localCapabilities
    , providerCreate = create env
    , providerLookup = lookupLease env
    , providerAttach = attach env
    , providerExecute = execute env
    , providerExport = export env
    , providerCancel = cancel env
    , providerReconcile = reconcile env
    , providerDestroy = destroy env
    , providerPrivateFiles =
        Just
          PrivateFileTransfer
            { importPrivateFile = importFile env
            , exportPrivateFile = exportFile env
            , deletePrivateFile = deleteFile env
            , cleanupPrivateFiles = cleanupFiles env
            }
    }

-- | Compatibility spelling for private CV10 consumers; use 'providerCreate'.
provision :: LocalProcessEnvironment -> Text -> EnvironmentSpec -> IO EnvironmentLease
provision = create

locked :: LocalProcessEnvironment -> IO a -> IO a
locked env = withMVar (localLock env) . const

getState :: LocalProcessEnvironment -> IO LocalState
getState = readIORef . localState

modifyState :: LocalProcessEnvironment -> (LocalState -> LocalState) -> IO ()
modifyState env = modifyIORef' (localState env)

lookupLease :: LocalProcessEnvironment -> Text -> IO (Maybe EnvironmentLease)
lookupLease env operation = Map.lookup operation . stateLeases <$> getState env

create :: LocalProcessEnvironment -> Text -> EnvironmentSpec -> IO EnvironmentLease
create env operation spec = locked env $ do
  checkOperationId operation
  when (isJust (specImage spec)) (throwExecution ValueError "local process environments do not accept an image")
  requireSupportedCapabilities localCapabilities spec
  existing <- lookupLease env operation
  case existing of
    Just lease -> do
      specs <- stateSpecs <$> getState env
      when (Map.lookup operation specs /= Just (specFingerprint spec)) $
        throwExecution ValueError "operation id collides with a materially different environment spec"
      pure lease
    Nothing -> do
      temporary <- getTemporaryDirectory
      territory <- createTempDirectory temporary "impetus-execution-"
      suffix <- newUuid4
      lease <-
        either throwIO pure $
          mkEnvironmentLease operation providerLabel (localInstanceId env <> ":" <> suffix) localCapabilities Ready
      modifyState env $ \s ->
        s
          { stateLeases = Map.insert operation lease (stateLeases s)
          , stateTerritories = Map.insert (leaseId lease) territory (stateTerritories s)
          , stateSpecs = Map.insert operation (specFingerprint spec) (stateSpecs s)
          }
      pure lease

busy :: LocalState -> Text -> Bool
busy s lease = Set.member lease (stateLaunching s) || Map.member lease (stateProcesses s)

attach :: LocalProcessEnvironment -> EnvironmentLease -> ByteString -> Text -> IO ExecutionAttachment
attach env lease archive digest = locked env $ do
  current <- lookupLease env (leaseOperationId lease)
  when (leaseProvider lease /= providerLabel || current /= Just lease) $
    throwExecution ValueError "attachment lease is not a current local-process territory"
  s <- getState env
  when (busy s (leaseId lease)) $
    throwExecution RuntimeError "local-process territory still has an active command"
  forM_ (Map.lookup (leaseId lease) (stateAttachments s)) $ \prior -> do
    cleaned <- cleanupLocked env prior
    unless (privateCleanupVerified cleaned) $
      throwExecution RuntimeError "prior attachment private-file cleanup could not be verified"
  territory <- territoryOf env (leaseId lease)
  let workspace = territory <> "/workspace"
  exists <- doesPathExist workspace
  when exists (removeDirectoryRecursive workspace)
  extractWorkspaceArchive archive workspace
  identifier <- newUuid4
  attachment <- either throwIO pure (mkExecutionAttachment identifier lease digest workspace)
  modifyState env $ \st -> st {stateAttachments = Map.insert (leaseId lease) attachment (stateAttachments st)}
  pure attachment

territoryOf :: LocalProcessEnvironment -> Text -> IO FilePath
territoryOf env lease =
  Map.lookup lease . stateTerritories <$> getState env >>= \case
    Just territory -> pure territory
    Nothing -> throwExecution KeyError (T.pack (pyStrRepr (T.unpack lease)))

privateResult :: ExecutionAttachment -> CleanupDisposition -> Int -> Text -> PrivateFileCleanupResult
privateResult attachment disposition removed detail =
  either (error . show) id $
    mkPrivateFileCleanupResult
      (attachmentId attachment)
      (leaseProvenance (attachmentLease attachment))
      disposition
      removed
      detail
      False

-- | Raises 'ValueError' for a stale/foreign attachment and 'RuntimeError'
-- for a busy territory.
privateAttachmentLocked :: LocalProcessEnvironment -> ExecutionAttachment -> IO ()
privateAttachmentLocked env attachment = do
  let lease = attachmentLease attachment
  current <- lookupLease env (leaseOperationId lease)
  s <- getState env
  when
    ( leaseProvider lease /= providerLabel
        || current /= Just lease
        || not (Set.member capPrivateFileTransfer (leaseCapabilities lease))
        || Map.lookup (leaseId lease) (stateAttachments s) /= Just attachment
    )
    (throwExecution ValueError "private-file attachment is not current")
  when (busy s (leaseId lease)) $
    throwExecution RuntimeError "private-file operation requires an idle territory"

privateAttachmentOk :: LocalProcessEnvironment -> ExecutionAttachment -> IO Bool
privateAttachmentOk env attachment =
  try (privateAttachmentLocked env attachment) >>= \case
    Right () -> pure True
    Left (failure :: ExecutionError)
      | errorKind failure `elem` [ValueError, RuntimeError] -> pure False
      | otherwise -> throwIO failure

-- | A territory-relative name (its UTF-8 bytes on disk).
raw :: Text -> FilePath
raw = T.unpack

-- | The @stat@ fields compared to detect a change during an export (all
-- but the access time, which the read itself may update).
statIdentity :: FileStat -> [Int64]
statIdentity info =
  [ statDevice info
  , statInode info
  , statMode info
  , statUid info
  , statLinkCount info
  , statSize info
  , statModifySeconds info
  , statModifyNanoseconds info
  , statChangeSeconds info
  , statChangeNanoseconds info
  ]

ownedDirectory :: Fd -> IO Bool
ownedDirectory fd = do
  info <- fdStat fd
  uid <- getRealUserID
  pure (At.isDirectory info && permissionBits info == 0o700 && statUid info == fromIntegral uid)

ownedFile :: FileStat -> IO Bool
ownedFile info = do
  uid <- getRealUserID
  pure (At.isRegularFile info && permissionBits info == 0o600 && statUid info == fromIntegral uid && statLinkCount info == 1)

-- | Open @territory/private/<file_id>@ without following links and check
-- every directory's ownership invariant.
withPrivateTree :: LocalProcessEnvironment -> Text -> Text -> (Fd -> Fd -> IO a) -> IO a
withPrivateTree env lease fileId action = do
  territoryPath <- territoryOf env lease
  bracket (openDirectoryAt Nothing territoryPath) closeFd $ \territory ->
    bracket (openDirectoryAt (Just territory) "private") closeFd $ \private ->
      bracket (openDirectoryAt (Just private) (raw fileId)) closeFd $ \root -> do
        owned <- and <$> mapM ownedDirectory [territory, private, root]
        unless owned (throwExecution RuntimeError "private-file directory invariant failed")
        action private root

discardPrivatePath :: FilePath -> IO Bool
discardPrivatePath root = do
  rawRoot <- toRawPath root
  lstatMaybe rawRoot >>= \case
    Nothing -> pure True
    Just status -> do
      removed <- try (if isDirectory status then removeDirectoryRecursive root else removeLink rawRoot)
      case removed of
        Left (_ :: IOException) -> pure False
        Right () -> not <$> pathLexists rawRoot

createPrivateFileLocked :: LocalProcessEnvironment -> ExecutionAttachment -> Text -> PrivateFile -> IO FilePath
createPrivateFileLocked env attachment fileId value = do
  territoryPath <- territoryOf env (leaseId (attachmentLease attachment))
  let rootPath = territoryPath <> "/private/" <> T.unpack fileId
  descriptors <- newIORef []
  let opened fd = modifyIORef' descriptors (fd :) >> pure fd
      closeAll = readIORef descriptors >>= mapM_ (\fd -> try (closeFd fd) :: IO (Either IOException ())) >> writeIORef descriptors []
      body = do
        territory <- opened =<< openDirectoryAt Nothing territoryPath
        ownedDirectory territory >>= \ok -> unless ok (throwExecution RuntimeError "private-file territory invariant failed")
        made <- try (mkdirAt (Just territory) "private" 0o700)
        case made of
          Left (failure :: IOException) | ioErrno failure /= 17 -> throwIO failure
          _ -> pure ()
        private <- opened =<< openDirectoryAt (Just territory) "private"
        setFdMode private 0o700
        ownedDirectory private >>= \ok -> unless ok (throwExecution RuntimeError "private-file directory invariant failed")
        mkdirAt (Just private) (raw fileId) 0o700
        root <- opened =<< openDirectoryAt (Just private) (raw fileId)
        setFdMode root 0o700
        ownedDirectory root >>= \ok -> unless ok (throwExecution RuntimeError "private-file root invariant failed")
        leaf <-
          opened
            =<< createExclusiveAt (Just root) (raw (privateFileName value)) 0o600
        setFdMode leaf 0o600
        writeAll leaf (privateFileContent value)
        fsyncFd leaf
        info <- fdStat leaf
        ownedFile info >>= \ok -> unless ok (throwExecution RuntimeError "private-file leaf invariant failed")
        pure rootPath
  result <- try body
  closeAll
  case result of
    Right path -> pure path
    Left (_ :: SomeException) -> do
      cleaned <- discardPrivatePath rootPath
      throwExecution
        RuntimeError
        (if cleaned then "private file import failed" else "private file import failed and cleanup could not be verified")

writeAll :: Fd -> ByteString -> IO ()
writeAll fd bytes = unless (B.null bytes) $ do
  written <- BU.unsafeUseAsCStringLen bytes $ \(ptr, len) -> fdWriteBuf fd (castPtr ptr) (fromIntegral len)
  when (written <= 0) (throwExecution OSError "private file write made no progress")
  writeAll fd (B.drop (fromIntegral written) bytes)

recordLocked :: LocalProcessEnvironment -> ExecutionAttachment -> PrivateFileRef -> IO (Maybe PrivateRecord)
recordLocked env attachment reference
  | refAttachmentId reference /= attachmentId attachment
      || provenanceIdentity (refProvenance reference) /= leaseIdentity (attachmentLease attachment) =
      pure Nothing
  | otherwise = do
      s <- getState env
      pure $ case Map.lookup (refFileId reference) =<< Map.lookup (leaseId (attachmentLease attachment)) (statePrivateFiles s) of
        Just record | recordReference record == reference -> Just record
        _ -> Nothing

putRecord :: LocalProcessEnvironment -> Text -> PrivateRecord -> IO ()
putRecord env lease record =
  modifyState env $ \s ->
    s
      { statePrivateFiles =
          Map.insertWith Map.union lease (Map.singleton (refFileId (recordReference record)) record) (statePrivateFiles s)
      }

importFile :: LocalProcessEnvironment -> ExecutionAttachment -> PrivateFile -> IO PrivateFileRef
importFile env attachment value = locked env $ do
  privateAttachmentLocked env attachment
  let lease = leaseId (attachmentLease attachment)
  s <- getState env
  let records = Map.findWithDefault Map.empty lease (statePrivateFiles s)
      active =
        [ r
        | r <- Map.elems records
        , recordPresent r
        , refAttachmentId (recordReference r) == attachmentId attachment
        ]
      config = localConfig env
  when
    ( length active >= configMaxPrivateFiles config
        || sum (map recordBytes active) + B.length (privateFileContent value) > configMaxPrivateTotalBytes config
    )
    (throwExecution ValueError "private file attachment bounds would be exceeded")
  fileId <- uuidHex
  root <- createPrivateFileLocked env attachment fileId value
  reference <-
    either throwIO pure $
      mkPrivateFileRef fileId (privateFileName value) (attachmentId attachment) (leaseProvenance (attachmentLease attachment))
  putRecord env lease (PrivateRecord reference root (B.length (privateFileContent value)) True False)
  modifyState env $ \st -> st {statePrivateCleaned = Set.delete (lease, attachmentId attachment) (statePrivateCleaned st)}
  pure reference

readPrivateFileLocked :: LocalProcessEnvironment -> ExecutionAttachment -> PrivateRecord -> IO ByteString
readPrivateFileLocked env attachment record = do
  unless (recordPresent record) unverified
  let reference = recordReference record
  outcome <- try $ withPrivateTree env (leaseId (attachmentLease attachment)) (refFileId reference) $ \_ root ->
    bracket
      (openAt (Just root) (raw (refName reference)) ReadOnly defaultFileFlags {nofollow = True, cloexec = True})
      closeFd
      $ \fd -> do
        before <- fdStat fd
        owned <- ownedFile before
        when (not owned || statSize before > fromIntegral maxPrivateFileBytes) $
          throwExecution RuntimeError "private-file leaf invariant failed"
        let readLoop retained acc
              | retained > maxPrivateFileBytes = pure (reverse acc)
              | otherwise = do
                  chunk <- readChunk fd (min 65536 (maxPrivateFileBytes + 1 - retained))
                  if B.null chunk then pure (reverse acc) else readLoop (retained + B.length chunk) (chunk : acc)
        chunks <- readLoop 0 []
        after <- fdStat fd
        let content = B.concat chunks
        when
          (statIdentity before /= statIdentity after || fromIntegral (B.length content) /= statSize after || B.length content > maxPrivateFileBytes)
          (throwExecution RuntimeError "private file changed during export")
        pure content
  case outcome of
    Right content -> pure content
    Left (failure :: SomeException)
      | isRuntimeOrOs failure -> unverified
      | otherwise -> throwIO failure
  where
    unverified :: IO a
    unverified = throwExecution RuntimeError "private file export could not be verified"
    isRuntimeOrOs failure = case fromException failure of
      Just e -> errorKind e `elem` [RuntimeError, OSError]
      Nothing -> isJust (fromException failure :: Maybe IOException)

readChunk :: Fd -> Int -> IO ByteString
readChunk fd size =
  BI.createAndTrim size $ \ptr -> fromIntegral <$> fdReadBuf fd ptr (fromIntegral size)

exportFile :: LocalProcessEnvironment -> ExecutionAttachment -> PrivateFileRef -> IO PrivateFile
exportFile env attachment reference = locked env $ do
  privateAttachmentLocked env attachment
  recordLocked env attachment reference >>= \case
    Nothing -> throwExecution ValueError "private file reference is not registered to the current attachment"
    Just record -> do
      content <- readPrivateFileLocked env attachment record
      either throwIO pure (mkPrivateFile (refName reference) content)

deleteRecordLocked :: LocalProcessEnvironment -> ExecutionAttachment -> PrivateRecord -> IO (CleanupDisposition, Int)
deleteRecordLocked env attachment record
  | not (recordPresent record) =
      pure (if recordVerifiedAbsent record then NotCreated else Unverified, 0)
  | otherwise = do
      let reference = recordReference record
          lease = leaseId (attachmentLease attachment)
      invariantRef <- newIORef False
      removedRef <- newIORef 0
      attempt <- try $ withPrivateTree env lease (refFileId reference) $ \private root -> do
        info <- statAt (Just root) (raw (refName reference)) NoFollowLinks
        writeIORef invariantRef =<< ownedFile info
        unlinkAt (Just root) (raw (refName reference))
        writeIORef removedRef 1
        remaining <- length <$> listDirectoryFd root
        if remaining /= 0
          then writeIORef invariantRef False
          else removeDirectoryAt (Just private) (raw (refFileId reference))
      case attempt of
        Left (_ :: SomeException) -> writeIORef invariantRef False
        Right () -> pure ()
      rawRoot <- toRawPath (recordRoot record)
      absentNow <- not <$> pathLexists rawRoot
      absent <- if absentNow then pure True else discardPrivatePath (recordRoot record)
      invariant <- readIORef invariantRef
      removed <- readIORef removedRef
      let updated = record {recordPresent = not absent, recordVerifiedAbsent = invariant && absent}
      putRecord env lease updated
      pure (if recordVerifiedAbsent updated then Clean else Unverified, removed)

deleteFile :: LocalProcessEnvironment -> ExecutionAttachment -> PrivateFileRef -> IO PrivateFileCleanupResult
deleteFile env attachment reference = locked env $ do
  ok <- privateAttachmentOk env attachment
  if not ok
    then pure (privateResult attachment Unverified 0 "private-file attachment is stale, foreign, or active")
    else
      recordLocked env attachment reference >>= \case
        Nothing -> pure (privateResult attachment Unverified 0 "private file reference is not registered")
        Just record -> do
          (disposition, removed) <- deleteRecordLocked env attachment record
          pure (privateResult attachment disposition removed "")

removePrivateParentLocked :: LocalProcessEnvironment -> ExecutionAttachment -> IO Bool
removePrivateParentLocked env attachment = do
  territoryPath <- territoryOf env (leaseId (attachmentLease attachment))
  rawTerritory <- toRawPath territoryPath
  outcome <- try $ bracket (openDirectoryAt Nothing territoryPath) closeFd $ \territory -> do
    opened <- try (openDirectoryAt (Just territory) "private")
    case opened of
      Left (failure :: IOException)
        | ioErrno failure == 2 -> pure True
        | otherwise -> throwIO failure
      Right private -> do
        removable <-
          ( do
              owned <- ownedDirectory private
              entries <- length <$> listDirectoryFd private
              pure (owned && entries == 0)
            )
            `finally` closeFd private
        if not removable
          then pure False
          else do
            removeDirectoryAt (Just territory) "private"
            not <$> pathLexists (rawTerritory <> "/private")
  case outcome of
    Right ok -> pure ok
    Left (_ :: IOException) -> pure False

cleanupLocked :: LocalProcessEnvironment -> ExecutionAttachment -> IO PrivateFileCleanupResult
cleanupLocked env attachment = do
  ok <- privateAttachmentOk env attachment
  if not ok
    then pure (privateResult attachment Unverified 0 "private-file attachment is stale, foreign, or active")
    else do
      let lease = leaseId (attachmentLease attachment)
          key = (lease, attachmentId attachment)
      s <- getState env
      if Set.member key (statePrivateCleaned s)
        then pure (privateResult attachment NotCreated 0 "")
        else do
          let records =
                [ r
                | r <- Map.elems (Map.findWithDefault Map.empty lease (statePrivateFiles s))
                , refAttachmentId (recordReference r) == attachmentId attachment
                ]
          outcomes <- forM records (deleteRecordLocked env attachment)
          let removed = sum (map snd outcomes)
              recordsVerified = all ((`elem` [Clean, NotCreated]) . fst) outcomes
          parentAbsent <- removePrivateParentLocked env attachment
          (verifiedParent, parentGone) <-
            if parentAbsent
              then pure (True, True)
              else do
                territory <- territoryOf env lease
                discarded <- discardPrivatePath (territory <> "/private")
                pure (False, discarded)
          let verified = recordsVerified && verifiedParent && parentGone
          when verified $ modifyState env $ \st -> st {statePrivateCleaned = Set.insert key (statePrivateCleaned st)}
          let disposition
                | verified && removed > 0 = Clean
                | verified = NotCreated
                | otherwise = Unverified
          pure (privateResult attachment disposition removed "")

cleanupFiles :: LocalProcessEnvironment -> ExecutionAttachment -> IO PrivateFileCleanupResult
cleanupFiles env attachment = locked env (cleanupLocked env attachment)

privateBindingsLocked :: LocalProcessEnvironment -> ExecutionAttachment -> Command -> IO [(Text, Text)]
privateBindingsLocked env attachment command
  | null (commandPrivateRoots command) = pure []
  | otherwise = do
      privateAttachmentLocked env attachment
      forM (commandPrivateRoots command) $ \(name, reference) -> do
        record <- recordLocked env attachment reference
        case record of
          Just r | recordPresent r -> do
            _ <- readPrivateFileLocked env attachment r
            pure (name, T.pack (recordRoot r))
          _ -> throwExecution ValueError "command private root is not registered to the current attachment"

redact :: [(Text, Text)] -> ByteString -> ByteString
redact roots value = foldl replace value roots
  where
    replace bytes (_, root) = replaceAll (TE.encodeUtf8 root) "[PRIVATE_ROOT]" bytes
    replaceAll needle replacement haystack
      | B.null needle = haystack
      | otherwise =
          let (before, rest) = B.breakSubstring needle haystack
           in if B.null rest
                then before
                else before <> replacement <> replaceAll needle replacement (B.drop (B.length needle) rest)

validateExecutionLocked :: LocalProcessEnvironment -> ExecutionAttachment -> IO ()
validateExecutionLocked env attachment = do
  let lease = attachmentLease attachment
  current <- lookupLease env (leaseOperationId lease)
  when (leaseProvider lease /= providerLabel || current /= Just lease) $
    throwExecution ValueError "execution attachment is not owned by this local-process provider"
  s <- getState env
  when (busy s (leaseId lease)) $
    throwExecution RuntimeError "local-process territory already has an active command"

execute :: LocalProcessEnvironment -> ExecutionAttachment -> Command -> IO CommandResult
execute env attachment command = do
  let lease = attachmentLease attachment
      provenance = leaseProvenance lease
  locked env (validateExecutionLocked env attachment)
  current <- maybe (pure True) id (commandIsCurrent command)
  if not current
    then either throwIO pure (mkCommandResult (-15) "" "" False True False provenance)
    else do
      (running, bindings) <- locked env $ do
        validateExecutionLocked env attachment
        bindings <- privateBindingsLocked env attachment command
        let environment = mergeEnvironment (commandEnvironment command) bindings
        modifyState env $ \s -> s {stateLaunching = Set.insert (leaseId lease) (stateLaunching s)}
        let launch = do
              cwd <- checkedHostCwd (attachmentWorkspace attachment) (commandCwd command)
              let (program, arguments) = case commandArgv command of
                    first : rest -> (first, rest)
                    [] -> ("", [])
              executable <- resolveExecutable environment program
              spawnCaptured
                SpawnSpec
                  { spawnArgv = executable : map T.unpack arguments
                  , spawnCwd = Just cwd
                  , spawnEnv = Just [(T.unpack k, T.unpack v) | (k, v) <- environment]
                  , spawnNewSession = True
                  , spawnStdin = Nothing
                  , spawnRetain = commandOutputLimit command
                  }
        running <-
          mask $ \restore -> do
            r <- restore launch `onException` clearLaunching lease
            modifyState env $ \s ->
              s
                { stateProcesses = Map.insert (leaseId lease) r (stateProcesses s)
                , stateLaunching = Set.delete (leaseId lease) (stateLaunching s)
                }
            pure r
        pure (running, bindings)
      let signalGroup signal = do
            exited <- pollExit running
            when (isNothing exited) $
              (try (signalProcessGroup signal (runningPid running)) :: IO (Either IOException ())) >> pure ()
      ( do
          (capture, timedOut, superseded, overflow) <- collect running command (signalGroup sigTERM) (signalGroup sigKILL)
          code <- maybe (-9) id <$> pollExit running
          let (out, err, truncated) = boundedResult (commandOutputLimit command) overflow capture
          either throwIO pure $
            mkCommandResult code (redact bindings out) (redact bindings err) timedOut superseded truncated provenance
        )
        `finally` locked env (modifyState env (\s -> s {stateProcesses = Map.delete (leaseId lease) (stateProcesses s)}))
  where
    clearLaunching lease = modifyState env $ \s -> s {stateLaunching = Set.delete (leaseId lease) (stateLaunching s)}

-- | @dict(command.environment); update(bindings)@.
mergeEnvironment :: [(Text, Text)] -> [(Text, Text)] -> [(Text, Text)]
mergeEnvironment base bindings =
  [(k, maybe v id (lookup k bindings)) | (k, v) <- base] <> [(k, v) | (k, v) <- bindings, isNothing (lookup k base)]

export :: LocalProcessEnvironment -> ExecutionAttachment -> IO ByteString
export env attachment = locked env $ do
  current <- lookupLease env (leaseOperationId (attachmentLease attachment))
  when (current /= Just (attachmentLease attachment)) $
    throwExecution ValueError "execution attachment is no longer current"
  workspaceArchive (attachmentWorkspace attachment)

cancel :: LocalProcessEnvironment -> EnvironmentLease -> Text -> IO ()
cancel env lease _reason = locked env $ do
  current <- lookupLease env (leaseOperationId lease)
  case current of
    Just found | leaseIdentity found == leaseIdentity lease -> do
      s <- getState env
      forM_ (Map.lookup (leaseId lease) (stateProcesses s)) $ \running -> do
        exited <- pollExit running
        when (isNothing exited) (signalProcessGroup sigTERM (runningPid running))
    _ -> pure ()

destroy :: LocalProcessEnvironment -> EnvironmentLease -> IO CleanupResult
destroy env lease = locked env $ do
  let identity = leaseIdentity lease
      result disposition = CleanupResult identity disposition
  if leaseProvider lease /= providerLabel
    then pure (result Unverified "lease belongs to a different provider")
    else do
      current <- lookupLease env (leaseOperationId lease)
      s <- getState env
      case current of
        Nothing -> do
          let owned = (localInstanceId env <> ":") `T.isPrefixOf` leaseId lease
          pure $
            if owned && not (Map.member (leaseId lease) (stateTerritories s))
              then result NotCreated "no lease exists in the owning local adapter"
              else result Unverified "local lease is not observable"
        Just found
          | leaseIdentity found /= identity -> pure (result Unverified "operation resolves to a different local lease")
          | otherwise -> do
              terminated <- case Map.lookup (leaseId lease) (stateProcesses s) of
                Nothing -> pure True
                Just running ->
                  pollExit running >>= \case
                    Just _ -> pure True
                    Nothing -> do
                      outcome <- try $ do
                        signalProcessGroup sigTERM (runningPid running)
                        waitExitWithin running (Just 0.5) >>= \case
                          Just _ -> pure True
                          Nothing -> do
                            signalProcessGroup sigKILL (runningPid running)
                            isJust <$> waitExitWithin running (Just 1)
                      pure (either (\(_ :: SomeException) -> False) id outcome)
              if not terminated
                then pure (result Unverified "local command termination could not be verified")
                else do
                  modifyState env $ \st -> st {stateProcesses = Map.delete (leaseId lease) (stateProcesses st)}
                  let territory = Map.lookup (leaseId lease) (stateTerritories s)
                  remover <- readIORef (localRemoveTree env)
                  removal <- try (mapM_ remover territory)
                  case removal of
                    Left (_ :: SomeException) -> pure (result Unverified "local workspace removal could not be verified")
                    Right () -> do
                      remains <- maybe (pure False) doesPathExist territory
                      if remains
                        then pure (result Unverified "local workspace remains after destroy")
                        else do
                          modifyState env $ \st ->
                            st
                              { stateTerritories = Map.delete (leaseId lease) (stateTerritories st)
                              , stateAttachments = Map.delete (leaseId lease) (stateAttachments st)
                              , statePrivateFiles = Map.delete (leaseId lease) (statePrivateFiles st)
                              , statePrivateCleaned = Set.filter ((/= leaseId lease) . fst) (statePrivateCleaned st)
                              , stateLeases = Map.delete (leaseOperationId lease) (stateLeases st)
                              , stateSpecs = Map.delete (leaseOperationId lease) (stateSpecs st)
                              }
                          pure (result Clean "")

reconcile :: LocalProcessEnvironment -> Text -> IO ReconcileResult
reconcile env operation =
  lookupLease env operation >>= \case
    Nothing -> pure (retryableResult "no local lease")
    Just lease -> pure (uncertainResult (Just lease) "local process completion is not durably recorded")
