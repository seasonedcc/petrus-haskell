-- | Private filesystem materialization and cleanup evidence
-- (@petrus.agenticus.connection.materialization@).
--
-- One opaque state blob lives at @<root>/<attachment_id>.state@ under a
-- private (@0700@), non-symlink root.  Files are created exclusively with
-- @O_NOFOLLOW@ and mode @0600@, re-checked by @(st_dev, st_ino)@ between
-- @lstat@ and @open@, and cleaned up cooperatively by zero-overwriting before
-- unlinking.  Cleanup evidence never claims physical erasure.
module Petrus.Agenticus.Connection.Materialization
  ( -- * Evidence
    CleanupEvidence (..)
  , CleanupSummary (..)
    -- * Materialized state
  , MaterializedState
  , materializedState
  , materializedAttachmentId
  , materializedPath
  , materializedErased
  , readMaterialized
  , readMaterializedScrubbed
  , replaceMaterialized
  , renderMaterializedState
    -- * The materializer
  , PrivateFileMaterializer
  , newPrivateFileMaterializer
  , materializerRoot
  , materializeState
  , readState
  , readStateScrubbed
  , replaceState
  , cleanup
  , summarize
  , statePath
  , validateAttachmentId
  ) where

import Control.Exception (IOException, evaluate, mask, onException, throwIO, try)
import Control.Monad (unless, when)
import Data.Bits ((.&.))
import Data.ByteArray (ScrubbedBytes)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Unsafe qualified as BU
import Data.Text (Text)
import Data.Text qualified as T
import Foreign.Ptr (Ptr, plusPtr)
import Data.Word (Word8)
import Petrus.Agenticus.Connection.Key (eraseBuffer)
import Petrus.Agenticus.Error
import Petrus.Json.Python (pythonStrRepr)
import System.Directory (createDirectoryIfMissing, doesPathExist)
import System.FilePath ((</>))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , removeLink
  , setFdMode
  , setFileMode
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (..)
  , closeFd
  , defaultFileFlags
  , fdReadBuf
  , fdWriteBuf
  , openFd
  )
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

-- | Secret-free evidence for one cooperative local cleanup attempt.
data CleanupEvidence = CleanupEvidence
  { attachmentId :: Text
  , removed :: Bool
  , alreadyAbsent :: Bool
  , bytesOverwritten :: Integer
  , physicalErasureGuaranteed :: Bool
  , securityViolation :: Bool
  }
  deriving stock (Eq, Show)

-- | Aggregate cleanup evidence without materialization paths or contents.
data CleanupSummary = CleanupSummary
  { attempted :: Int
  , removed :: Int
  , alreadyAbsent :: Int
  , unresolved :: Int
  , securityViolations :: Int
  , physicalErasureGuaranteed :: Bool
  }
  deriving stock (Eq, Show)

-- | Materialize one opaque state blob under a private, non-symlink root.
newtype PrivateFileMaterializer = PrivateFileMaterializer FilePath

-- | One private opaque-state file; its 'Show' instance omits its path and
-- bytes.
data MaterializedState = MaterializedState
  { materializer :: PrivateFileMaterializer
  , attachmentId :: Text
  }

instance Show MaterializedState where
  show _ = "MaterializedState(<private>)"

-- | A handle on the state file of an attachment (used to rebuild views of
-- live leases after a restart).
materializedState :: PrivateFileMaterializer -> Text -> MaterializedState
materializedState materializer attachmentId = MaterializedState {materializer, attachmentId}

materializedAttachmentId :: MaterializedState -> Text
materializedAttachmentId state = state.attachmentId

-- | The private path, for the selected provider runtime only.
materializedPath :: MaterializedState -> FilePath
materializedPath state = statePath state.materializer state.attachmentId

-- | Whether the file is gone (@lstat@ finds nothing).
materializedErased :: MaterializedState -> IO Bool
materializedErased state = do
  outcome <- try (getSymbolicLinkStatus (materializedPath state))
  case outcome of
    Left (failure :: IOException)
      | isDoesNotExistError failure -> pure True
      | otherwise -> throwIO failure
    Right _ -> pure False

readMaterialized :: MaterializedState -> IO ByteString
readMaterialized state = readState state.materializer state.attachmentId

readMaterializedScrubbed :: MaterializedState -> IO ScrubbedBytes
readMaterializedScrubbed state = readStateScrubbed state.materializer state.attachmentId

replaceMaterialized :: MaterializedState -> ByteString -> IO ()
replaceMaterialized state = replaceState state.materializer state.attachmentId

-- | Upstream's @repr@: @MaterializedState(<erased>)@ or
-- @MaterializedState(<materialized>)@.
renderMaterializedState :: MaterializedState -> IO Text
renderMaterializedState state = do
  erased <- materializedErased state
  pure ("MaterializedState(<" <> (if erased then "erased" else "materialized") <> ">)")

materializerRoot :: PrivateFileMaterializer -> FilePath
materializerRoot (PrivateFileMaterializer root) = root

-- | @PrivateFileMaterializer(root)@: create the root @0700@ when absent and
-- refuse a symlinked, non-directory, or permissive root.
newPrivateFileMaterializer :: FilePath -> IO PrivateFileMaterializer
newPrivateFileMaterializer root = do
  linked <- isSymlink root
  when linked (securityError "materialization root must not be a symlink")
  exists <- doesPathExist root
  unless exists $ do
    createDirectoryIfMissing True root
    setFileMode root 0o700
  let materializer = PrivateFileMaterializer root
  assertRoot materializer
  pure materializer

-- | Create the private state file exclusively and write the plaintext.
materializeState :: PrivateFileMaterializer -> Text -> ScrubbedBytes -> IO MaterializedState
materializeState materializer attachmentId plaintext = do
  throwLeft (validateAttachmentId attachmentId)
  assertRoot materializer
  let path = statePath materializer attachmentId
  opened <- try (openFd path WriteOnly defaultFileFlags {exclusive = True, nofollow = True, creat = Just 0o600})
  descriptor <- case opened of
    Left (failure :: IOException)
      | isAlreadyExistsError failure ->
          securityError
            ("materialization target for attachment " <> pythonStrRepr attachmentId <> " already exists or is a symlink")
      | otherwise -> throwIO failure
    Right fd -> pure fd
  ( do
      setFdMode descriptor 0o600
      BA.withByteArray plaintext $ \pointer -> writeAll descriptor pointer (BA.length plaintext)
      fileSynchronise descriptor
    )
    `finallyClose` descriptor
  pure (materializedState materializer attachmentId)

-- | The state file's bytes.
readState :: PrivateFileMaterializer -> Text -> IO ByteString
readState materializer attachmentId = readStateScrubbed materializer attachmentId >>= evaluate . BA.convert

-- | The state file's bytes in an erasable buffer.
readStateScrubbed :: PrivateFileMaterializer -> Text -> IO ScrubbedBytes
readStateScrubbed materializer attachmentId = do
  descriptor <- openPrivateFile materializer attachmentId ReadOnly defaultFileFlags
  readAll descriptor `finallyClose` descriptor

-- | Overwrite the state file with the runtime's returned state.
replaceState :: PrivateFileMaterializer -> Text -> ByteString -> IO ()
replaceState materializer attachmentId opaqueState = do
  when (B.null opaqueState) (throwIO (valueError "returned opaque state must be non-empty bytes"))
  descriptor <- openPrivateFile materializer attachmentId WriteOnly defaultFileFlags {trunc = True}
  ( do
      BU.unsafeUseAsCStringLen opaqueState $ \(pointer, size) -> writeAll descriptor (castPointer pointer) size
      fileSynchronise descriptor
    )
    `finallyClose` descriptor
  where
    castPointer :: Ptr a -> Ptr Word8
    castPointer pointer = pointer `plusPtr` 0

-- | Zero-overwrite and unlink one state file; never raises for filesystem
-- shapes, which become 'securityViolation' evidence instead.
cleanup :: PrivateFileMaterializer -> Text -> IO CleanupEvidence
cleanup materializer attachmentId = do
  throwLeft (validateAttachmentId attachmentId)
  let path = statePath materializer attachmentId
      evidence removed alreadyAbsent overwritten violation =
        CleanupEvidence
          { attachmentId
          , removed
          , alreadyAbsent
          , bytesOverwritten = overwritten
          , physicalErasureGuaranteed = False
          , securityViolation = violation
          }
  status <- try (getSymbolicLinkStatus path)
  case status of
    Left (failure :: IOException)
      | isDoesNotExistError failure -> pure (evidence False True 0 False)
      | otherwise -> throwIO failure
    Right metadata
      | isSymbolicLink metadata -> do
          removeLink path
          pure (evidence True False 0 True)
      | not (isRegularFile metadata) -> pure (evidence False False 0 True)
      | otherwise -> do
          let overwritten = fromIntegral (fileSize metadata) :: Int
          outcome <- try $ do
            descriptor <- openFd path WriteOnly defaultFileFlags {nofollow = True}
            zeroFill descriptor overwritten `finallyClose` descriptor
            removeLink path
          pure $ case outcome of
            Left (_ :: IOException) -> evidence False False 0 True
            Right () -> evidence True False (toInteger overwritten) False

-- | Clean up every attachment and aggregate the evidence.
summarize :: PrivateFileMaterializer -> [Text] -> IO CleanupSummary
summarize materializer attachmentIds = do
  evidence <- mapM (cleanup materializer) attachmentIds
  let count predicate = length (filter predicate evidence)
  pure
    CleanupSummary
      { attempted = length evidence
      , removed = count (.removed)
      , alreadyAbsent = count (.alreadyAbsent)
      , unresolved = count (\item -> not item.removed && not item.alreadyAbsent)
      , securityViolations = count (.securityViolation)
      , physicalErasureGuaranteed = False
      }

-- | @<root>/<attachment_id>.state@.
statePath :: PrivateFileMaterializer -> Text -> FilePath
statePath (PrivateFileMaterializer root) attachmentId = root </> (T.unpack attachmentId <> ".state")

-- | Lowercase letters, digits, and hyphens only.
validateAttachmentId :: Text -> Either AgenticusError ()
validateAttachmentId attachmentId
  | T.null attachmentId || T.any (`notElem` allowed) attachmentId =
      Left (valueError "attachment identity must contain only lowercase letters, digits, and hyphens")
  | otherwise = Right ()
  where
    allowed = ['a' .. 'z'] <> ['0' .. '9'] <> "-"

openPrivateFile :: PrivateFileMaterializer -> Text -> OpenMode -> OpenFileFlags -> IO Fd
openPrivateFile materializer attachmentId mode flags = do
  throwLeft (validateAttachmentId attachmentId)
  assertRoot materializer
  let path = statePath materializer attachmentId
      subject = "materialization for attachment " <> pythonStrRepr attachmentId
  status <- try (getSymbolicLinkStatus path)
  metadata <- case status of
    Left (failure :: IOException)
      | isDoesNotExistError failure -> throwAgenticus MaterializationError (subject <> " is absent")
      | otherwise -> throwIO failure
    Right metadata -> pure metadata
  when (isSymbolicLink metadata) (securityError (subject <> " is a symlink"))
  unless (isRegularFile metadata) (securityError (subject <> " is not a file"))
  unless (permissionBits metadata == 0o600) (securityError (subject <> " has unsafe mode"))
  descriptor <- openFd path mode flags {nofollow = True}
  opened <- getFdStatus descriptor `onException` closeFd descriptor
  unless (isRegularFile opened && sameFile opened metadata) $ do
    closeFd descriptor
    securityError (subject <> " changed during open")
  pure descriptor
  where
    sameFile a b = deviceID a == deviceID b && fileID a == fileID b

assertRoot :: PrivateFileMaterializer -> IO ()
assertRoot (PrivateFileMaterializer root) = do
  status <- try (getSymbolicLinkStatus root)
  metadata <- case status of
    Left (failure :: IOException)
      | isDoesNotExistError failure -> securityError "materialization root is absent"
      | otherwise -> throwIO failure
    Right metadata -> pure metadata
  when (isSymbolicLink metadata) (securityError "materialization root must not be a symlink")
  unless (isDirectory metadata) (securityError "materialization root must be a directory")
  unless (permissionBits metadata == 0o700) (securityError "materialization root must have mode 0700")

securityError :: Text -> IO a
securityError = throwAgenticus MaterializationSecurityError

-- | @stat.S_IMODE@.
permissionBits :: FileStatus -> FileMode
permissionBits metadata = fileMode metadata .&. 0o7777

isSymlink :: FilePath -> IO Bool
isSymlink path = do
  status <- try (getSymbolicLinkStatus path)
  pure $ case status of
    Left (_ :: IOException) -> False
    Right metadata -> isSymbolicLink metadata

finallyClose :: IO a -> Fd -> IO a
finallyClose action descriptor = mask $ \restore -> do
  result <- restore action `onException` closeFd descriptor
  closeFd descriptor
  pure result

writeAll :: Fd -> Ptr Word8 -> Int -> IO ()
writeAll descriptor pointer remaining
  | remaining <= 0 = pure ()
  | otherwise = do
      written <- fromIntegral <$> fdWriteBuf descriptor pointer (fromIntegral remaining)
      writeAll descriptor (pointer `plusPtr` written) (remaining - written)

-- | Read the whole file into a fresh erasable buffer, erasing every
-- intermediate buffer.
readAll :: Fd -> IO ScrubbedBytes
readAll descriptor = go []
  where
    chunk = 65536
    go chunks = do
      (count, block) <-
        BA.allocRet chunk $ \pointer -> fromIntegral <$> fdReadBuf descriptor pointer (fromIntegral chunk)
      if count == 0
        then do
          eraseBuffer (block :: ScrubbedBytes)
          joined <- evaluate (BA.concat (reverse chunks) :: ScrubbedBytes)
          mapM_ eraseBuffer chunks
          pure joined
        else do
          piece <- evaluate (BA.take count block)
          eraseBuffer block
          go (piece : chunks)

-- | Overwrite @size@ bytes from the start with zeroes in blocks of at most
-- 64 KiB, then fsync.
zeroFill :: Fd -> Int -> IO ()
zeroFill descriptor size = do
  let blockSize = min (max size 1) 65536
  let block = BA.zero blockSize :: ScrubbedBytes
  BA.withByteArray block $ \pointer ->
    let loop remaining
          | remaining <= 0 = pure ()
          | otherwise = do
              written <- fromIntegral <$> fdWriteBuf descriptor pointer (fromIntegral (min remaining blockSize))
              loop (remaining - written)
     in loop size
  fileSynchronise descriptor
